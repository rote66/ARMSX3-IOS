#include "armsx3_ios_core.h"

#include "Crypto/key_vault.h"
#include "Crypto/unpkg.h"
#include "Crypto/unself.h"
#include "Emu/Audio/Null/NullAudioBackend.h"
#include "Emu/Cell/Modules/cellMsgDialog.h"
#include "Emu/Cell/Modules/cellSaveData.h"
#include "Emu/Cell/Modules/cellSysutil.h"
#include "Emu/Cell/Modules/sceNpTrophy.h"
#include "Emu/IdManager.h"
#include "Emu/Io/KeyboardHandler.h"
#include "Emu/Io/Null/NullKeyboardHandler.h"
#include "Emu/Io/Null/NullMouseHandler.h"
#include "Emu/Io/Null/null_camera_handler.h"
#include "Emu/Io/Null/null_music_handler.h"
#include "Emu/Io/pad_config.h"
#include "Emu/Io/pad_types.h"
#include "Emu/RSX/GSFrameBase.h"
#include "Emu/RSX/Null/NullGSRender.h"
#include "Emu/RSX/Overlays/overlay_manager.h"
#include "Emu/RSX/Overlays/overlay_save_dialog.h"
#include "Emu/RSX/Overlays/overlay_trophy_notification.h"
#include "Emu/RSX/RSXThread.h"
#include "Emu/RSX/VK/VKGSRender.h"
#include "Emu/System.h"
#include "Emu/VFS.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Emu/vfs_config.h"
#include "Input/pad_thread.h"
#include "Input/virtual_pad_handler.h"
#include "Loader/PUP.h"
#include "Loader/TAR.h"
#include "Utilities/File.h"
#include "Utilities/Config.h"
#include "Utilities/JIT.h"
#include "Utilities/StrFmt.h"
#include "Utilities/Thread.h"
#include "util/fixed_typemap.hpp"
#include "util/logs.hpp"
#include "util/serialization.hpp"
#include "util/video_provider.h"
#include "Emu/Audio/audio_device_enumerator.h"

#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <filesystem>
#include <libkern/OSCacheControl.h>
#include <mutex>
#include <optional>
#include <pthread.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

extern std::string g_android_executable_dir;
extern std::string g_android_config_dir;
extern std::string g_android_cache_dir;

std::string g_input_config_override;
cfg_input_configurations g_cfg_input_configs;

LOG_CHANNEL(armsx3_ios_log, "IOS");

namespace
{
std::atomic<bool> g_initialized{false};
std::atomic<bool> g_initializing{false};
std::atomic<void*> g_metal_view{nullptr};
std::atomic<int> g_surface_width{0};
std::atomic<int> g_surface_height{0};
std::atomic<double> g_refresh_rate{60.0};
std::atomic<u64> g_surface_epoch{0};
std::atomic<armsx3_ios_event_callback> g_event_callback{nullptr};
std::array<std::shared_ptr<Pad>, CELL_PAD_MAX_PORT_NUM> g_virtual_pads;
std::mutex g_pad_mutex;
std::mutex g_lifecycle_mutex;
std::string g_settings_json;
std::string g_log_path;
std::string g_firmware_version;

void emit_event(armsx3_ios_event event, std::string_view message);
cfg::_base* find_cfg_node_ios(cfg::_base* root, std::string_view path);
bool cfg_is_editable_ios(const cfg::_base* node);
void emit_cfg_json_ios(const cfg::_base* node, std::string& out);
std::string decode_setting_json_value(std::string_view value);
bool save_global_settings_locked();

int boot_path_locked(const std::string& path)
{
	if (path.empty()) return static_cast<int>(game_boot_result::invalid_file_or_folder);
	if (!Emu.IsStopped(true))
	{
		Emu.Kill();
		for (int elapsed = 0; !Emu.IsStopped(true) && elapsed < 10000; elapsed += 20)
			std::this_thread::sleep_for(std::chrono::milliseconds(20));
	}
	Emu.SetForceBoot(true);
	return static_cast<int>(Emu.BootGame(path, "", false, cfg_mode::custom));
}

extern "C" bool armsx3_ios_install_package(const char* path)
{
	if (!path || !*path || !g_initialized.load(std::memory_order_acquire)) return false;
	std::lock_guard lock(g_lifecycle_mutex);
	if (!Emu.IsStopped(true))
	{
		emit_event(ARMSX3_IOS_EVENT_ERROR, "Stop emulation before installing a PKG");
		return false;
	}

	fs::file file(path);
	if (!file)
	{
		emit_event(ARMSX3_IOS_EVENT_ERROR, "Unable to open PKG");
		return false;
	}

	std::deque<package_reader> readers;
	readers.emplace_back(path, std::move(file));
	if (!readers.front().is_valid())
	{
		emit_event(ARMSX3_IOS_EVENT_ERROR, "Invalid PKG");
		return false;
	}

	emit_event(ARMSX3_IOS_EVENT_STATUS, "Installing PKG...");
	std::deque<std::string> bootable_paths;
	const package_install_result result = package_reader::extract_data(readers, bootable_paths, false);
	if (result.error == package_install_result::error_type::no_error)
	{
		emit_event(ARMSX3_IOS_EVENT_STATUS, "PKG installed");
		return true;
	}

	if (result.error == package_install_result::error_type::app_version)
	{
		std::string message = "PKG update rejected";
		if (!result.version.expected.empty())
			message += fmt::format(": expected {}, installed {}", result.version.expected,
				result.version.installed.empty() ? "none" : result.version.installed);
		else
			message += ": base game is not installed";
		emit_event(ARMSX3_IOS_EVENT_ERROR, message);
		return false;
	}

	emit_event(ARMSX3_IOS_EVENT_ERROR, "PKG installation failed");
	return false;
}

cfg::_base* find_cfg_node_ios(cfg::_base* root, std::string_view path)
{
	if (!root) return nullptr;
	if (path.empty()) return root;

	usz offset = 0;
	while (offset <= path.size())
	{
		const usz delimiter = path.find("@@", offset);
		const std::string_view name = delimiter == std::string_view::npos
			? path.substr(offset)
			: path.substr(offset, delimiter - offset);

		if (!name.empty())
		{
			auto* parent = dynamic_cast<cfg::node*>(root);
			if (!parent) return nullptr;

			cfg::_base* child = nullptr;
			for (cfg::_base* candidate : parent->get_nodes())
			{
				if (candidate->get_name() == name)
				{
					child = candidate;
					break;
				}
			}
			if (!child) return nullptr;
			root = child;
		}

		if (delimiter == std::string_view::npos) break;
		offset = delimiter + 2;
	}

	return root;
}

void json_append_escaped_ios(std::string& out, std::string_view value)
{
	out += '"';
	for (const char c : value)
	{
		switch (c)
		{
		case '"': out += "\\\""; break;
		case '\\': out += "\\\\"; break;
		case '\n': out += "\\n"; break;
		case '\r': out += "\\r"; break;
		case '\t': out += "\\t"; break;
		default:
			if (static_cast<unsigned char>(c) < 0x20)
				fmt::append(out, "\\u%04x", static_cast<unsigned>(static_cast<unsigned char>(c)));
			else
				out += c;
			break;
		}
	}
	out += '"';
}

bool cfg_is_float_ios(const cfg::_base* node)
{
	const std::string min = node->min_to_string();
	return min.find('.') != std::string::npos;
}

bool cfg_is_editable_ios(const cfg::_base* node)
{
	switch (node->get_type())
	{
	case cfg::type::node:
	case cfg::type::_bool:
	case cfg::type::_enum:
	case cfg::type::_int:
	case cfg::type::uint:
	case cfg::type::uint128:
	case cfg::type::string:
		return true;
	default:
		return false;
	}
}

const char* cfg_type_name_ios(const cfg::_base* node)
{
	switch (node->get_type())
	{
	case cfg::type::_bool: return "bool";
	case cfg::type::_enum: return "enum";
	case cfg::type::_int: return cfg_is_float_ios(node) ? "float" : "int";
	case cfg::type::uint: return "uint";
	default: return "string";
	}
}

void emit_cfg_json_ios(const cfg::_base* node, std::string& out)
{
	if (node->get_type() == cfg::type::node)
	{
		out += '{';
		bool first = true;
		for (const cfg::_base* child : static_cast<const cfg::node*>(node)->get_nodes())
		{
			if (!cfg_is_editable_ios(child)) continue;
			if (!first) out += ',';
			first = false;
			json_append_escaped_ios(out, child->get_name());
			out += ':';
			emit_cfg_json_ios(child, out);
		}
		out += '}';
		return;
	}

	const bool is_bool = node->get_type() == cfg::type::_bool;
	out += "{\"type\":";
	json_append_escaped_ios(out, cfg_type_name_ios(node));
	out += ",\"value\":";
	if (is_bool)
		out += node->to_string() == "true" ? "true" : "false";
	else
		json_append_escaped_ios(out, node->to_string());

	out += ",\"default\":";
	if (is_bool)
		out += node->def_to_string() == "true" ? "true" : "false";
	else
		json_append_escaped_ios(out, node->def_to_string());

	if (node->get_type() == cfg::type::_enum)
	{
		out += ",\"variants\":[";
		bool first = true;
		for (const std::string& variant : node->to_list())
		{
			if (!first) out += ',';
			first = false;
			json_append_escaped_ios(out, variant);
		}
		out += ']';
	}

	if (const std::string min = node->min_to_string(); !min.empty())
	{
		out += ",\"min\":";
		json_append_escaped_ios(out, min);
		out += ",\"max\":";
		json_append_escaped_ios(out, node->max_to_string());
	}

	out += '}';
}

std::string decode_setting_json_value(std::string_view value)
{
	std::string decoded;
	if (value.size() < 2 || value.front() != '"' || value.back() != '"')
	{
		decoded.assign(value);
		return decoded;
	}

	decoded.reserve(value.size() - 2);
	for (usz index = 1; index + 1 < value.size(); index++)
	{
		if (value[index] == '\\' && index + 2 < value.size())
		{
			switch (value[++index])
			{
			case 'n': decoded += '\n'; break;
			case 'r': decoded += '\r'; break;
			case 't': decoded += '\t'; break;
			case '"': decoded += '"'; break;
			case '\\': decoded += '\\'; break;
			default: decoded += value[index]; break;
			}
		}
		else
		{
			decoded += value[index];
		}
	}
	return decoded;
}

bool save_global_settings_locked()
{
	if (!g_initialized.load(std::memory_order_acquire) || !Emu.IsStopped(true)) return false;
	Emulator::SaveSettings(g_cfg.to_string(), {});
	emit_event(ARMSX3_IOS_EVENT_STATUS, "Settings saved");
	return true;
}

} // namespace

extern "C" bool armsx3_ios_settings_editable()
{
	return g_initialized.load(std::memory_order_acquire) && Emu.IsStopped(true);
}

extern "C" const char* armsx3_ios_settings_json(const char* path)
{
	if (!g_initialized.load(std::memory_order_acquire)) return "";
	std::lock_guard lock(g_lifecycle_mutex);
	cfg::_base* root = find_cfg_node_ios(&g_cfg, path ? std::string_view(path) : std::string_view{});
	if (!root) return "";
	g_settings_json.clear();
	g_settings_json.reserve(64 * 1024);
	emit_cfg_json_ios(root, g_settings_json);
	return g_settings_json.c_str();
}

extern "C" bool armsx3_ios_set_setting_json(const char* path, const char* json_value)
{
	if (!path || !*path || !json_value) return false;
	std::lock_guard lock(g_lifecycle_mutex);
	if (!g_initialized.load(std::memory_order_acquire) || !Emu.IsStopped(true)) return false;

	cfg::_base* node = find_cfg_node_ios(&g_cfg, path);
	if (!node || !cfg_is_editable_ios(node) || node->get_type() == cfg::type::node) return false;
	const std::string decoded = decode_setting_json_value(json_value);
#if defined(ARCH_ARM64)
	if (std::string_view(path) == "Core@@SPU Decoder" && decoded == "Recompiler (ASMJIT)") return false;
#endif
	if (!node->from_string(decoded, false)) return false;
	return save_global_settings_locked();
}

namespace
{
void emit_event(armsx3_ios_event event, std::string_view message = {})
{
	if (const auto callback = g_event_callback.load(std::memory_order_acquire))
	{
		const std::string copy(message);
		callback(static_cast<int>(event), copy.c_str());
	}
}

std::string directory_path(std::string path)
{
	if (!path.empty() && path.back() != '/')
	{
		path += '/';
	}
	return path;
}

class IOSGraphicsFrame final : public GSFrameBase
{
public:
	void close() override {}
	void reset() override {}
	bool shown() override { return g_metal_view.load(std::memory_order_acquire) != nullptr; }
	void hide() override {}
	void show() override {}
	void toggle_fullscreen() override {}
	void delete_context(draw_context_t) override {}
	draw_context_t make_context() override { return nullptr; }
	void set_current(draw_context_t) override {}
	void flip(draw_context_t, bool) override {}
	int client_width() override { return std::max(1, g_surface_width.load()); }
	int client_height() override { return std::max(1, g_surface_height.load()); }
	f64 client_display_rate() override { return g_refresh_rate.load(); }
	bool has_alpha() override { return false; }
	display_handle_t handle() const override { return g_metal_view.load(std::memory_order_acquire); }
	u64 display_epoch() const override { return g_surface_epoch.load(); }
	bool can_consume_frame() const override { return false; }
	void present_frame(std::vector<u8>&&, u32, u32, u32, bool) const override {}
	void take_screenshot(std::vector<u8>&&, u32, u32, bool) override {}
	void update_title(double) override {}
};

class IOSMessageDialog final : public MsgDialogBase
{
public:
	void Create(const std::string& msg, const std::string& title) override
	{
		emit_event(ARMSX3_IOS_EVENT_STATUS, title.empty() ? msg : title + ": " + msg);
		state = MsgDialogState::Open;
	}
	void Close(bool success) override
	{
		state = MsgDialogState::Close;
		if (on_close) on_close(success ? CELL_MSGDIALOG_BUTTON_OK : CELL_MSGDIALOG_BUTTON_ESCAPE);
	}
	void SetMsg(const std::string& msg) override { emit_event(ARMSX3_IOS_EVENT_STATUS, msg); }
	void ProgressBarSetMsg(u32, const std::string& msg) override { SetMsg(msg); }
	void ProgressBarReset(u32) override {}
	void ProgressBarInc(u32, u32) override {}
	void ProgressBarSetValue(u32, u32) override {}
	void ProgressBarSetLimit(u32, u32) override {}
};

class IOSSaveDialog final : public SaveDialogBase
{
public:
	s32 ShowSaveDataList(const std::string& base_dir, std::vector<SaveDataEntry>& entries,
		s32 focused, u32 op, vm::ptr<CellSaveDataListSet> list_set, bool enable_overlay) override
	{
		if (auto manager = g_fxo->try_get<rsx::overlays::display_manager>())
		{
			return manager->create<rsx::overlays::save_dialog>()->show(
				base_dir, entries, focused, op, list_set, enable_overlay);
		}
		return -2;
	}
};

class IOSTrophyNotification final : public TrophyNotificationBase
{
public:
	s32 ShowTrophyNotification(const SceNpTrophyDetails& trophy,
		const std::vector<uchar>& icon) override
	{
		if (auto manager = g_fxo->try_get<rsx::overlays::display_manager>())
		{
			auto popup = std::make_shared<rsx::overlays::trophy_notification>();
			return manager->add(popup, false)->show(trophy, icon);
		}
		return 0;
	}
};

bool initialize_virtual_pad(const std::shared_ptr<Pad>& pad)
{
	const u32 status = pad->m_player_id == 0 ? CELL_PAD_STATUS_CONNECTED : 0;
	pad->Init(status,
		CELL_PAD_CAPABILITY_PS3_CONFORMITY | CELL_PAD_CAPABILITY_PRESS_MODE |
		CELL_PAD_CAPABILITY_HP_ANALOG_STICK | CELL_PAD_CAPABILITY_ACTUATOR |
		CELL_PAD_CAPABILITY_SENSOR_MODE,
		CELL_PAD_DEV_TYPE_STANDARD, CELL_PAD_PCLASS_TYPE_STANDARD, 0, 0, 0, 50);

	for (const auto [offset, code] : std::array<std::pair<u32, u32>, 17>{
		std::pair{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_UP},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_DOWN},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_LEFT},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_RIGHT},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_CROSS},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_SQUARE},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_CIRCLE},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_TRIANGLE},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_L1},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_L2},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_L3},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_R1},
		{CELL_PAD_BTN_OFFSET_DIGITAL2, CELL_PAD_CTRL_R2},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_R3},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_START},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_SELECT},
		{CELL_PAD_BTN_OFFSET_DIGITAL1, CELL_PAD_CTRL_PS}})
	{
		pad->m_buttons.emplace_back(offset, std::vector<std::set<u32>>{}, code);
	}

	pad->m_sticks[0] = AnalogStick(CELL_PAD_BTN_OFFSET_ANALOG_LEFT_X, {}, {});
	pad->m_sticks[1] = AnalogStick(CELL_PAD_BTN_OFFSET_ANALOG_LEFT_Y, {}, {});
	pad->m_sticks[2] = AnalogStick(CELL_PAD_BTN_OFFSET_ANALOG_RIGHT_X, {}, {});
	pad->m_sticks[3] = AnalogStick(CELL_PAD_BTN_OFFSET_ANALOG_RIGHT_Y, {}, {});
	pad->m_sensors[0] = AnalogSensor(CELL_PAD_BTN_OFFSET_SENSOR_X, 0, 0, 0, DEFAULT_MOTION_X);
	pad->m_sensors[1] = AnalogSensor(CELL_PAD_BTN_OFFSET_SENSOR_Y, 0, 0, 0, DEFAULT_MOTION_Y);
	pad->m_sensors[2] = AnalogSensor(CELL_PAD_BTN_OFFSET_SENSOR_Z, 0, 0, 0, DEFAULT_MOTION_Z);
	pad->m_sensors[3] = AnalogSensor(CELL_PAD_BTN_OFFSET_SENSOR_G, 0, 0, 0, DEFAULT_MOTION_G);
	pad->m_vibrate_motors[0] = VibrateMotor(true);
	pad->m_vibrate_motors[1] = VibrateMotor(false);

	if (pad->m_player_id < g_virtual_pads.size())
	{
		std::lock_guard lock(g_pad_mutex);
		g_virtual_pads[pad->m_player_id] = pad;
	}
	return true;
}

void set_callbacks()
{
	EmuCallbacks callbacks{};
	callbacks.call_from_main_thread = [](std::function<void()> fn, atomic_t<u32>* wake_up)
	{
		fn();
		if (wake_up)
		{
			*wake_up = true;
			wake_up->notify_one();
		}
	};
	callbacks.on_run = [](bool) { emit_event(ARMSX3_IOS_EVENT_RUNNING); };
	callbacks.on_pause = [] { emit_event(ARMSX3_IOS_EVENT_PAUSED); };
	callbacks.on_resume = [] { emit_event(ARMSX3_IOS_EVENT_RESUMED); };
	callbacks.on_stop = [] { emit_event(ARMSX3_IOS_EVENT_STOPPED); };
	callbacks.on_ready = [] {};
	callbacks.on_missing_fw = [] { emit_event(ARMSX3_IOS_EVENT_ERROR, "PS3 firmware is not installed"); };
	callbacks.on_emulation_stop_no_response = [](std::shared_ptr<atomic_t<bool>>, int seconds)
	{
		emit_event(ARMSX3_IOS_EVENT_ERROR,
			fmt::format("Emulation has not stopped after %d seconds", seconds));
	};
	callbacks.on_save_state_progress = [](auto...) {};
	callbacks.enable_disc_eject = [](bool) {};
	callbacks.enable_disc_insert = [](bool) {};
	callbacks.try_to_quit = [](bool, std::function<void()> on_exit)
	{
		if (on_exit) on_exit();
		return true;
	};
	callbacks.handle_taskbar_progress = [](s32, s32) {};
	callbacks.init_kb_handler = []
	{
		ensure(g_fxo->init<KeyboardHandlerBase, NullKeyboardHandler>(Emu.DeserialManager()));
	};
	callbacks.init_mouse_handler = []
	{
		ensure(g_fxo->init<MouseHandlerBase, NullMouseHandler>(Emu.DeserialManager()));
	};
	callbacks.init_pad_handler = [](std::string_view)
	{
		ensure(g_fxo->init<named_thread<pad_thread>>(nullptr, nullptr, ""));
	};
	callbacks.update_emu_settings = [] {};
	callbacks.save_emu_settings = [] { Emulator::SaveSettings(g_cfg.to_string(), Emu.GetTitleID()); };
	callbacks.close_gs_frame = [] {};
	callbacks.get_gs_frame = [] { return std::make_unique<IOSGraphicsFrame>(); };
	callbacks.get_camera_handler = [] { return std::make_shared<null_camera_handler>(); };
	callbacks.get_music_handler = [] { return std::make_shared<null_music_handler>(); };
	callbacks.init_gs_render = [](utils::serial* ar)
	{
		if (g_cfg.video.renderer == video_renderer::vulkan)
			g_fxo->init<rsx::thread, named_thread<VKGSRender>>(ar);
		else
			g_fxo->init<rsx::thread, named_thread<NullGSRender>>(ar);
	};
	callbacks.get_audio = []() -> std::shared_ptr<AudioBackend>
	{
		return std::make_shared<NullAudioBackend>();
	};
	callbacks.get_audio_enumerator = [](u64) { return std::shared_ptr<audio_device_enumerator>{}; };
	callbacks.get_msg_dialog = [] { return std::make_shared<IOSMessageDialog>(); };
	callbacks.get_osk_dialog = [] { return std::shared_ptr<OskDialogBase>{}; };
	callbacks.get_save_dialog = [] { return std::make_unique<IOSSaveDialog>(); };
	callbacks.get_sendmessage_dialog = [] { return std::shared_ptr<SendMessageDialogBase>{}; };
	callbacks.get_recvmessage_dialog = [] { return std::shared_ptr<RecvMessageDialogBase>{}; };
	callbacks.get_trophy_notification_dialog = [] { return std::make_unique<IOSTrophyNotification>(); };
	callbacks.get_localized_string = [](localized_string_id, const char*) { return std::string{}; };
	callbacks.get_localized_u32string = [](localized_string_id, const char*) { return std::u32string{}; };
	callbacks.get_localized_setting = [](const cfg::_base*, u32) { return std::string{}; };
	callbacks.get_photo_path = [](std::string_view) { return std::string{}; };
	callbacks.play_sound = [](const std::string&, std::optional<f32>) {};
	callbacks.get_image_info = [](const std::string&, std::string&, s32&, s32&, s32&) { return false; };
	callbacks.get_scaled_image = [](const std::string&, s32, s32, s32&, s32&, u8*, bool) { return false; };
	callbacks.resolve_path = [](std::string_view path) { return std::string(path); };
	callbacks.resolve_path_may_not_exist = [](std::string_view path) { return std::string(path); };
	callbacks.get_font_dirs = [] { return std::vector<std::string>{}; };
	callbacks.on_install_pkgs = [](const std::vector<std::string>& pkgs, bool optical)
	{
		for (const auto& pkg : pkgs)
			if (!rpcs3::utils::install_pkg(pkg, optical)) return false;
		return true;
	};
	callbacks.add_breakpoint = [](u32) {};
	callbacks.display_sleep_control_supported = [] { return false; };
	callbacks.enable_display_sleep = [](bool) {};
	callbacks.check_microphone_permissions = [] {};
	callbacks.make_video_source = [] { return std::unique_ptr<video_source>{}; };
	callbacks.enable_gamemode = [](bool) {};
	callbacks.get_database_config = [](const std::string&) { return std::string{}; };
	Emu.SetCallbacks(std::move(callbacks));
}
} // namespace

[[noreturn]] void report_fatal_error(std::string_view text, bool, bool)
{
	emit_event(ARMSX3_IOS_EVENT_ERROR, text);
	armsx3_ios_log.fatal("%s", text);
	std::abort();
}

void qt_events_aware_op(int repeat_duration_ms, std::function<bool()> operation)
{
	while (!operation())
	{
		if (repeat_duration_ms > 0)
			std::this_thread::sleep_for(std::chrono::milliseconds(repeat_duration_ms));
		else
			std::this_thread::yield();
	}
}

extern "C" bool armsx3_ios_initialize(const char* root_dir, void* metal_view,
	armsx3_ios_event_callback callback)
{
	armsx3_ios_diagnostic_log("core.initialize entered");
	if (!root_dir || !metal_view)
	{
		armsx3_ios_diagnostic_log("core.initialize rejected invalid arguments");
		return false;
	}
	if (g_initialized.load(std::memory_order_acquire)) return true;
	if (g_initializing.exchange(true, std::memory_order_acq_rel)) return false;

	g_event_callback.store(callback, std::memory_order_release);
	armsx3_ios_set_surface(metal_view, 1, 1, 60.0);

	const std::string root = directory_path(root_dir);
	armsx3_ios_diagnostic_log("core paths begin");
	g_android_executable_dir = root;
	g_android_config_dir = root + "config/";
	g_android_cache_dir = root + "cache/";
	std::filesystem::create_directories(g_android_config_dir);
	std::filesystem::create_directories(g_android_cache_dir);
	std::filesystem::create_directories(root + "logs/");
	g_log_path = fs::get_log_dir() + "ARMSX3.log";
	armsx3_ios_diagnostic_log("core paths ready");

	armsx3_ios_diagnostic_log("core thread runtime begin");
	static_cast<void>(named_thread("", [](int) {}));
	armsx3_ios_diagnostic_log("core thread runtime ready");
	static std::unique_ptr<logs::listener> log_file = logs::make_file_listener(g_log_path, 64 * 1024 * 1024);
	logs::set_init({});
	armsx3_ios_diagnostic_log("core logging ready");

	virtual_pad_handler::set_on_connect_cb(initialize_virtual_pad);
	set_callbacks();
	armsx3_ios_diagnostic_log("core callbacks ready");
	Emu.SetHasGui(false);
	Emu.SetUsr("00000001");
	Emu.SetSupportedRenderers({video_renderer::null, video_renderer::vulkan});
	Emu.SetDefaultRenderer(video_renderer::vulkan);
	Emu.SetDefaultGraphicsAdapter("Default");
	armsx3_ios_diagnostic_log("Emu.Init begin");
	Emu.Init();
	armsx3_ios_diagnostic_log("Emu.Init passed");

	g_cfg_input.player1.handler.set(pad_handler::virtual_pad);
	g_cfg_input.player1.device.from_string("Virtual");
	for (usz index = 1; index < g_cfg_input.player.size(); index++)
	{
		g_cfg_input.player[index]->handler.set(pad_handler::virtual_pad);
		g_cfg_input.player[index]->device.from_string("Virtual");
	}
	g_cfg_input.save("", g_cfg_input_configs.default_config);
	g_firmware_version = utils::get_firmware_version();
	g_initialized.store(true, std::memory_order_release);
	g_initializing.store(false, std::memory_order_release);
	emit_event(ARMSX3_IOS_EVENT_STATUS, "Core initialized");
	armsx3_ios_diagnostic_log("core.initialize passed");
	return true;
}

extern "C" bool armsx3_ios_is_initialized()
{
	return g_initialized.load(std::memory_order_acquire);
}

extern "C" void armsx3_ios_set_surface(void* metal_view, int width, int height, double refresh_rate)
{
	void* previous = g_metal_view.exchange(metal_view, std::memory_order_acq_rel);
	if (previous != metal_view) g_surface_epoch.fetch_add(1);
	if (width > 0) g_surface_width.store(width);
	if (height > 0) g_surface_height.store(height);
	if (refresh_rate > 0) g_refresh_rate.store(refresh_rate);
}

extern "C" bool armsx3_ios_jit_test()
{
#if defined(__aarch64__)
	if (!armsx3_ios_jit_authorized())
	{
		armsx3_ios_diagnostic_log("jit test skipped: CS_DEBUGGED=0");
		return false;
	}

	armsx3_ios_diagnostic_log("jit shared arena test begin");
	u8* memory = nullptr;
	const u32 code[] = {0x52800540u, 0xd65f03c0u}; // mov w0, #42; ret
	{
		jit_write_guard guard;
		memory = jit_runtime::alloc(sizeof(code), alignof(u32), true);
		if (!memory)
		{
			armsx3_ios_diagnostic_log("jit shared arena allocation failed");
			return false;
		}
		std::memcpy(memory, code, sizeof(code));
		sys_icache_invalidate(memory, sizeof(code));
	}
	armsx3_ios_diagnostic_log("jit shared arena allocation passed");
	if (!jit_runtime::prepare_execution())
	{
		armsx3_ios_diagnostic_log("jit execution activation failed");
		return false;
	}
	armsx3_ios_diagnostic_log("jit execution activation passed");
	armsx3_ios_diagnostic_log("jit code execution begin");
	const int result = reinterpret_cast<int (*)()>(memory)();
	armsx3_ios_diagnostic_log("jit code execution returned");
	return result == 42;
#else
	return false;
#endif
}

extern "C" bool armsx3_ios_jit_authorized()
{
#if defined(__aarch64__)
	u32 cs_flags = 0;
	const int result = csops(getpid(), 0, &cs_flags, sizeof(cs_flags));
	const bool debugged = result == 0 && (cs_flags & 0x10000000u) != 0;
	char message[96]{};
	std::snprintf(message, sizeof(message), "jit csops=%d flags=0x%08x CS_DEBUGGED=%d",
		result, cs_flags, debugged ? 1 : 0);
	armsx3_ios_diagnostic_log(message);
	return debugged;
#else
	return false;
#endif
}

extern "C" int armsx3_ios_boot(const char* path)
{
	if (!path || !*path) return static_cast<int>(game_boot_result::invalid_file_or_folder);
	if (!g_initialized.load(std::memory_order_acquire)) return static_cast<int>(game_boot_result::generic_error);
	std::lock_guard lock(g_lifecycle_mutex);
	return boot_path_locked(path);
}

extern "C" bool armsx3_ios_can_boot_firmware()
{
	if (!g_initialized.load(std::memory_order_acquire)) return false;
	return fs::is_file(g_cfg_vfs.get_dev_flash() + "vsh/module/vsh.self");
}

extern "C" int armsx3_ios_boot_firmware()
{
	if (!g_initialized.load(std::memory_order_acquire))
		return static_cast<int>(game_boot_result::generic_error);

	std::lock_guard lock(g_lifecycle_mutex);
	const std::string vsh_path = g_cfg_vfs.get_dev_flash() + "vsh/module/vsh.self";
	if (!fs::is_file(vsh_path))
		return static_cast<int>(game_boot_result::invalid_file_or_folder);
	return boot_path_locked(vsh_path);
}

extern "C" bool armsx3_ios_install_firmware(const char* path)
{
	if (!path || !g_initialized.load(std::memory_order_acquire)) return false;
	fs::file file(path);
	if (!file) return false;
	pup_object pup(std::move(file));
	if (static_cast<pup_error>(pup) != pup_error::ok) return false;
	fs::file updates_file = pup.get_file(0x300);
	if (!updates_file) return false;
	tar_object updates(updates_file);
	auto names = updates.get_filenames();
	names.erase(std::remove_if(names.begin(), names.end(), [](const std::string& name)
	{
		return !name.starts_with("dev_flash_");
	}), names.end());
	if (names.empty()) return false;
	vfs::mount("/dev_flash", g_cfg_vfs.get_dev_flash());

	for (usz index = 0; index < names.size(); index++)
	{
		emit_event(ARMSX3_IOS_EVENT_STATUS,
			fmt::format("Installing firmware %d/%d", index + 1, names.size()));
		auto stream = updates.get_file(names[index]);
		if (stream->m_file_handler)
			stream->m_file_handler->handle_file_op(*stream, 0, stream->get_size(umax), nullptr);
		fs::file update = fs::make_stream(std::move(stream->data));
		SCEDecrypter decrypter(update);
		decrypter.LoadHeaders();
		decrypter.LoadMetadata(SCEPKG_ERK, SCEPKG_RIV);
		decrypter.DecryptData();
		auto files = decrypter.MakeFile();
		if (files.size() < 3 || !tar_object(files[2]).extract()) return false;
	}
	g_firmware_version = utils::get_firmware_version();
	emit_event(ARMSX3_IOS_EVENT_STATUS, "Firmware installed");
	return true;
}

extern "C" void armsx3_ios_pause() { if (g_initialized.load(std::memory_order_acquire)) Emu.Pause(); }
extern "C" void armsx3_ios_resume() { if (g_initialized.load(std::memory_order_acquire)) Emu.Resume(); }
extern "C" void armsx3_ios_stop()
{
	if (!g_initialized.load(std::memory_order_acquire)) return;
	std::lock_guard lock(g_lifecycle_mutex);
	Emu.Kill();
}
extern "C" int armsx3_ios_state() { return static_cast<int>(Emu.GetStatus(false)); }

extern "C" bool armsx3_ios_set_pad(int port, uint32_t digital1, uint32_t digital2,
	uint8_t left_x, uint8_t left_y, uint8_t right_x, uint8_t right_y,
	uint8_t left_trigger, uint8_t right_trigger)
{
	if (port < 0 || static_cast<usz>(port) >= g_virtual_pads.size()) return false;
	std::shared_ptr<Pad> pad;
	{
		std::lock_guard lock(g_pad_mutex);
		pad = g_virtual_pads[port];
	}
	if (!pad) return false;
	pad->m_port_status |= CELL_PAD_STATUS_CONNECTED;
	for (auto& button : pad->m_buttons)
	{
		const u32 bits = button.m_offset == CELL_PAD_BTN_OFFSET_DIGITAL1 ? digital1 : digital2;
		button.m_pressed = (bits & button.m_outKeyCode) != 0;
		button.m_value = button.m_pressed ? 255 : 0;
		if (button.m_outKeyCode == CELL_PAD_CTRL_L2) button.m_value = left_trigger;
		if (button.m_outKeyCode == CELL_PAD_CTRL_R2) button.m_value = right_trigger;
	}
	pad->m_sticks[0].m_value = left_x;
	pad->m_sticks[1].m_value = left_y;
	pad->m_sticks[2].m_value = right_x;
	pad->m_sticks[3].m_value = right_y;
	return true;
}

extern "C" const char* armsx3_ios_log_path() { return g_log_path.c_str(); }
extern "C" const char* armsx3_ios_firmware_version() { return g_firmware_version.c_str(); }
