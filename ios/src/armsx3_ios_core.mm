#include "armsx3_ios_core.h"

#include "Crypto/key_vault.h"
#include "Crypto/unpkg.h"
#include "Crypto/unself.h"
#include "Emu/Audio/Null/NullAudioBackend.h"
#include "Emu/Audio/Null/null_enumerator.h"
#include "ARMSX3IOSAudioBackend.h"
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
#include "Emu/RSX/Overlays/overlay_perf_metrics.h"
#include "Emu/RSX/Overlays/overlay_save_dialog.h"
#include "Emu/RSX/Overlays/overlay_trophy_notification.h"
#include "Emu/RSX/RSXThread.h"
#include "Emu/RSX/VK/VKGSRender.h"
#include "Emu/System.h"
#include "Emu/savestate_utils.hpp"
#include "Emu/localized_string_id.h"
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
#include "Utilities/bin_patch.h"
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
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <libkern/OSCacheControl.h>
#include <mutex>
#include <optional>
#include <pthread.h>
#include <sstream>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

extern std::string g_android_executable_dir;
extern std::string g_android_config_dir;
extern std::string g_android_cache_dir;
extern atomic_t<bool> g_user_asked_for_screenshot;

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
std::string g_boot_log_path;
std::string g_firmware_version;
std::string g_patch_json;
std::optional<bool> g_firmware_saved_llvm_precompilation;
std::optional<ppu_decoder_type> g_firmware_saved_ppu_decoder;
std::optional<spu_decoder_type> g_firmware_saved_spu_decoder;

std::string json_quote(std::string_view v)
{
	std::string out = "\"";
	for (char c : v)
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
				out += fmt::format("\\u%04x", static_cast<unsigned char>(c));
			else
				out += c;
		}
	}
	return out + "\"";
}

std::string ios_slot_dir(std::string_view title)
{
	return fs::get_config_dir() + "/savestates/" + std::string(title) + "/armsx3_slots/";
}

std::string ios_slot_find(std::string_view title, unsigned int slot)
{
	if (title.empty() || slot >= 10) return {};
	const std::string base = ios_slot_dir(title) + "slot" + std::to_string(slot) + ".SAVESTAT";
	for (std::string_view ext : {".zst", ".gz", ""})
	{
		std::string path = base + std::string(ext);
		if (fs::is_file(path)) return path;
	}
	return {};
}

bool ios_slot_capture(unsigned int slot, const std::string& title, const std::string& boot)
{
	const std::string newest = get_savestate_file(title, boot, 1);
	if (!fs::is_file(newest))
	{
		armsx3_ios_log.error("savestate slot %u: newest state missing at '%s'", slot, newest);
		return false;
	}
	const std::string dir = ios_slot_dir(title);
	if (!fs::create_path(dir) && fs::g_tls_error != fs::error::exist)
	{
		armsx3_ios_log.error("savestate slot %u: cannot create '%s': %s", slot, dir, fs::g_tls_error);
		return false;
	}
	constexpr std::string_view stem = ".SAVESTAT";
	const usz pos = newest.rfind(stem);
	const std::string suffix = pos == umax ? std::string{} : newest.substr(pos + stem.size());
	const std::string dest = dir + "slot" + std::to_string(slot) + std::string(stem) + suffix;
	for (std::string_view ext : {".zst", ".gz", ""})
	{
		std::string old = dir + "slot" + std::to_string(slot) + std::string(stem) + std::string(ext);
		if (old != dest && fs::is_file(old)) fs::remove_file(old);
	}
	if (!fs::copy_file(newest, dest, true))
	{
		armsx3_ios_log.error("savestate slot %u: copy '%s' -> '%s' failed: %s", slot, newest, dest, fs::g_tls_error);
		return false;
	}
	armsx3_ios_log.success("savestate slot %u saved to '%s'", slot, dest);
	return true;
}

const patch_engine::patch_map& cached_patch_db()
{
	static std::mutex mutex;
	static patch_engine::patch_map db;
	static u64 cached_size = 0;
	static s64 cached_mtime = 0;
	static bool loaded = false;
	std::lock_guard lock(mutex);

	const std::string path = patch_engine::get_patches_path() + "patch.yml";
	fs::stat_t info{};
	const bool exists = fs::get_stat(path, info);
	if (loaded && exists && info.size == cached_size && info.mtime == cached_mtime)
		return db;

	db.clear();
	std::stringstream log;
	patch_engine::load(db, path, {}, false, &log);
	cached_size = exists ? info.size : 0;
	cached_mtime = exists ? info.mtime : 0;
	loaded = true;
	return db;
}

void restore_firmware_runtime_overrides()
{
	if (g_firmware_saved_llvm_precompilation)
	{
		g_cfg.core.llvm_precompilation.set(*g_firmware_saved_llvm_precompilation);
		armsx3_ios_diagnostic_log(fmt::format("firmware LLVM precompilation override restored=%d",
			*g_firmware_saved_llvm_precompilation ? 1 : 0).c_str());
		g_firmware_saved_llvm_precompilation.reset();
	}

	if (g_firmware_saved_ppu_decoder)
	{
		g_cfg.core.ppu_decoder.set(*g_firmware_saved_ppu_decoder);
		armsx3_ios_diagnostic_log(fmt::format("firmware PPU decoder override restored=%s",
			g_cfg.core.ppu_decoder.to_string()).c_str());
		g_firmware_saved_ppu_decoder.reset();
	}

	if (g_firmware_saved_spu_decoder)
	{
		g_cfg.core.spu_decoder.set(*g_firmware_saved_spu_decoder);
		armsx3_ios_diagnostic_log(fmt::format("firmware SPU decoder override restored=%s",
			g_cfg.core.spu_decoder.to_string()).c_str());
		g_firmware_saved_spu_decoder.reset();
	}
}

void emit_event(armsx3_ios_event event, std::string_view message);
cfg::_base* find_cfg_node_ios(cfg::_base* root, std::string_view path);
bool cfg_is_editable_ios(const cfg::_base* node);
void emit_cfg_json_ios(const cfg::_base* node, std::string& out);
std::string decode_setting_json_value(std::string_view value);
bool save_global_settings_locked();

int boot_path_locked(const std::string& path)
{
	if (path.empty()) return static_cast<int>(game_boot_result::invalid_file_or_folder);

	std::string boot_path = path;
	while (boot_path.size() > 1 && boot_path.ends_with('/'))
		boot_path.pop_back();

	armsx3_ios_diagnostic_log(fmt::format("boot begin state=%d path=%s",
		static_cast<int>(Emu.GetStatus(false)), boot_path).c_str());

	// The startup JIT canary promotes the bootstrap arena once, but BootGame may
	// run after a JIT reset/restore. Re-check immediately before any PPU/SPU code
	// can execute so a missing executable transition becomes a normal boot error
	// instead of an unlogged protection fault.
	if (!jit_runtime::prepare_execution())
	{
		armsx3_ios_diagnostic_log("boot rejected: JIT execution is not ready");
		emit_event(ARMSX3_IOS_EVENT_ERROR, "JIT execution is not ready");
		return static_cast<int>(game_boot_result::generic_error);
	}
	armsx3_ios_diagnostic_log("boot JIT ready");

	if (!Emu.IsStopped(true))
	{
		armsx3_ios_diagnostic_log("boot stopping previous VM");
		Emu.Kill();
		for (int elapsed = 0; !Emu.IsStopped(true) && elapsed < 10000; elapsed += 20)
			std::this_thread::sleep_for(std::chrono::milliseconds(20));
		if (!Emu.IsStopped(true))
		{
			armsx3_ios_diagnostic_log("boot rejected: previous VM did not stop");
			return static_cast<int>(game_boot_result::still_running);
		}
	}

	if (fs::is_file(boot_path))
	{
		fs::file probe(boot_path);
		char byte = 0;
		if (!probe)
		{
			armsx3_ios_diagnostic_log("boot rejected: target cannot be opened");
			return static_cast<int>(game_boot_result::invalid_file_or_folder);
		}
		const bool head_ok = probe.read_at(0, &byte, 1) == 1;
		const u64 size = probe.size();
		const bool body_ok = size <= 32769 || probe.read_at(32769, &byte, 1) == 1;
		if (!head_ok || !body_ok)
		{
			armsx3_ios_diagnostic_log(fmt::format(
				"boot rejected: target unreadable size=%d head=%d body=%d",
				static_cast<int>(size), head_ok ? 1 : 0, body_ok ? 1 : 0).c_str());
			return static_cast<int>(game_boot_result::invalid_file_or_folder);
		}
		armsx3_ios_diagnostic_log(fmt::format("boot target readable size=%d",
			static_cast<int>(size)).c_str());
	}

	Emu.SetForceBoot(true);
	armsx3_ios_diagnostic_log("BootGame enter");
	const auto result = Emu.BootGame(boot_path, "", false, cfg_mode::custom);
	armsx3_ios_diagnostic_log(fmt::format("BootGame returned result=%d",
		static_cast<int>(result)).c_str());
	return static_cast<int>(result);
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

extern "C" bool armsx3_ios_performance_overlay_enabled(void)
{
	return g_initialized.load(std::memory_order_acquire) && g_cfg.video.perf_overlay.enabled.get();
}

extern "C" bool armsx3_ios_set_performance_overlay_enabled(bool enabled)
{
	if (!g_initialized.load(std::memory_order_acquire)) return false;
	const bool running = !Emu.IsStopped();
	{
		std::lock_guard lock(g_lifecycle_mutex);
		if (!g_cfg.video.perf_overlay.enabled.from_string(enabled ? "true" : "false", running))
			return false;
		Emulator::SaveSettings(g_cfg.to_string(), {});
	}
	if (running)
		rsx::overlays::reset_performance_overlay();
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
	if (std::string_view(path) == "Video@@Shader Mode" &&
		(decoded == "Async Recompiler with Shader Interpreter" || decoded == "Shader Interpreter only"))
	{
		// The interpreter requires 64 combined fragment samplers. Apple A-series
		// Metal exposes only 16 fragment sampler slots, so MoltenVK cannot compile
		// that ubershader. Keep the iOS configuration on the regular async recompiler.
		if (!node->from_string("Async Recompiler (multi-threaded)", false)) return false;
		return save_global_settings_locked();
	}
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
	void take_screenshot(std::vector<u8>&& data, u32 width, u32 height, bool is_bgra) override
	{
		if (data.size() < static_cast<usz>(width) * height * 4 || !width || !height) return;
		NSMutableData *rgba = [NSMutableData dataWithLength:static_cast<NSUInteger>(width) * height * 4];
		u8 *dst = static_cast<u8 *>(rgba.mutableBytes);
		for (usz i = 0; i < static_cast<usz>(width) * height; i++)
		{
			const u8 *src = data.data() + i * 4;
			dst[i * 4 + 0] = is_bgra ? src[2] : src[0];
			dst[i * 4 + 1] = src[1];
			dst[i * 4 + 2] = is_bgra ? src[0] : src[2];
			dst[i * 4 + 3] = src[3];
		}
		CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
		CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
		CGImageRef cg = CGImageCreate(width, height, 8, 32, width * 4, color_space,
			static_cast<CGBitmapInfo>(kCGImageAlphaLast | kCGBitmapByteOrder32Big), provider, nullptr, false, kCGRenderingIntentDefault);
		UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
		NSData *png = image ? UIImagePNGRepresentation(image) : nil;
		if (cg) CGImageRelease(cg);
		if (provider) CGDataProviderRelease(provider);
		if (color_space) CGColorSpaceRelease(color_space);
		if (!png.length) return;
		NSString *documents = NSProcessInfo.processInfo.environment[@"ARMSX3_DOCUMENTS_DIR"];
		if (!documents.length) return;
		NSString *dir = [documents stringByAppendingPathComponent:@"Screenshots"];
		[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
		NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
		NSString *name = [NSString stringWithFormat:@"ARMSX3-%@.png", [formatter stringFromDate:NSDate.date]];
		NSString *path = [dir stringByAppendingPathComponent:name];
		if ([png writeToFile:path atomically:YES])
			emit_event(ARMSX3_IOS_EVENT_STATUS, fmt::format("Screenshot saved: {}", name.UTF8String));
	}
	void update_title(double) override {}
};

class IOSMessageDialog final : public MsgDialogBase
{
private:
	u32 m_progress_value = 0;
	u32 m_progress_limit = 100;

	void emit_progress() const
	{
		emit_event(ARMSX3_IOS_EVENT_PROGRESS,
			fmt::format("{}:{}", m_progress_value, std::max<u32>(m_progress_limit, 1)));
	}

public:
	void Create(const std::string& msg, const std::string& title) override
	{
		emit_event(ARMSX3_IOS_EVENT_STATUS, title.empty() || title == msg ? msg : title + ": " + msg);
		state = MsgDialogState::Open;
	}
	void Close(bool success) override
	{
		(void)success;
		state = MsgDialogState::Close;
		emit_event(ARMSX3_IOS_EVENT_PROGRESS_END, {});
	}
	void SetMsg(const std::string& msg) override { emit_event(ARMSX3_IOS_EVENT_STATUS, msg); }
	void ProgressBarSetMsg(u32, const std::string& msg) override { SetMsg(msg); }
	void ProgressBarReset(u32) override { m_progress_value = 0; emit_progress(); }
	void ProgressBarInc(u32, u32 delta) override { m_progress_value += delta; emit_progress(); }
	void ProgressBarSetValue(u32, u32 value) override { m_progress_value = value; emit_progress(); }
	void ProgressBarSetLimit(u32, u32 limit) override { m_progress_limit = std::max<u32>(limit, 1); emit_progress(); }
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

struct ios_main_callback_dispatcher
{
	std::mutex mutex;
	std::condition_variable cv;
	std::deque<std::function<void()>> queue;
	bool started = false;

	void post(std::function<void()> callback)
	{
		std::unique_lock lock(mutex);
		if (!started)
		{
			started = true;
			std::thread([this]
			{
				pthread_setname_np("Main Callbacks");
				for (;;)
				{
					std::function<void()> next;
					{
						std::unique_lock queue_lock(mutex);
						cv.wait(queue_lock, [this] { return !queue.empty(); });
						next = std::move(queue.front());
						queue.pop_front();
					}
					next();
				}
			}).detach();
		}

		queue.push_back(std::move(callback));
		cv.notify_one();
	}
};

ios_main_callback_dispatcher g_ios_main_callbacks;

void set_callbacks()
{
	EmuCallbacks callbacks{};
	callbacks.call_from_main_thread = [](std::function<void()> fn, atomic_t<u32>* wake_up)
	{
		if (wake_up)
		{
			fn();
			*wake_up = true;
			wake_up->notify_one();
			return;
		}

		g_ios_main_callbacks.post(std::move(fn));
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
		if (g_cfg.audio.renderer == audio_renderer::null)
			return std::make_shared<NullAudioBackend>();
		return std::make_shared<ARMSX3IOSAudioBackend>();
	};
	callbacks.get_audio_enumerator = [](u64) { return std::make_shared<null_enumerator>(); };
	callbacks.get_msg_dialog = [] { return std::make_shared<IOSMessageDialog>(); };
	callbacks.get_osk_dialog = [] { return std::shared_ptr<OskDialogBase>{}; };
	callbacks.get_save_dialog = [] { return std::make_unique<IOSSaveDialog>(); };
	callbacks.get_sendmessage_dialog = [] { return std::shared_ptr<SendMessageDialogBase>{}; };
	callbacks.get_recvmessage_dialog = [] { return std::shared_ptr<RecvMessageDialogBase>{}; };
	callbacks.get_trophy_notification_dialog = [] { return std::make_unique<IOSTrophyNotification>(); };
	callbacks.get_localized_string = [](localized_string_id id, const char* args) -> std::string
	{
		switch (id)
		{
		case localized_string_id::PROGRESS_DIALOG_PROGRESS: return "进度";
		case localized_string_id::PROGRESS_DIALOG_PROGRESS_ANALYZING: return "正在分析";
		case localized_string_id::PROGRESS_DIALOG_REMAINING: return "剩余";
		case localized_string_id::PROGRESS_DIALOG_DONE: return "完成";
		case localized_string_id::PROGRESS_DIALOG_FILE: return "文件";
		case localized_string_id::PROGRESS_DIALOG_MODULE: return "模块";
		case localized_string_id::PROGRESS_DIALOG_OF: return "/";
		case localized_string_id::PROGRESS_DIALOG_PLEASE_WAIT: return "请稍候";
		case localized_string_id::PROGRESS_DIALOG_STOPPING_PLEASE_WAIT: return "正在停止，请稍候";
		case localized_string_id::PROGRESS_DIALOG_SAVESTATE_PLEASE_WAIT: return "正在处理存档，请稍候";
		case localized_string_id::PROGRESS_DIALOG_SCANNING_PPU_EXECUTABLE: return "正在扫描 PPU 可执行文件";
		case localized_string_id::PROGRESS_DIALOG_ANALYZING_PPU_EXECUTABLE: return "正在分析 PPU 可执行文件";
		case localized_string_id::PROGRESS_DIALOG_SCANNING_PPU_MODULES: return "正在扫描 PPU 模块";
		case localized_string_id::PROGRESS_DIALOG_LOADING_PPU_MODULES: return "正在加载 PPU 模块";
		case localized_string_id::PROGRESS_DIALOG_COMPILING_PPU_MODULES: return "正在编译 PPU 模块";
		case localized_string_id::PROGRESS_DIALOG_LINKING_PPU_MODULES: return "正在链接 PPU 模块";
		case localized_string_id::PROGRESS_DIALOG_APPLYING_PPU_CODE: return "正在应用 PPU 代码";
		case localized_string_id::PROGRESS_DIALOG_BUILDING_SPU_CACHE: return "正在构建 SPU 缓存";
		default: return args ? args : "";
		}
	};
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
	armsx3_ios_diagnostic_log(fmt::format("fatal: %s", text).c_str());
	armsx3_ios_log.fatal("%s", text);
	logs::listener::sync_all();
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

	std::string logs_dir = root + "logs/";
	if (const char* documents = std::getenv("ARMSX3_DOCUMENTS_DIR"); documents && *documents)
		logs_dir = directory_path(documents) + "Logs/";
	std::filesystem::create_directories(logs_dir);
	g_log_path = logs_dir + "ARMSX3.log";
	g_boot_log_path = logs_dir + "ARMSX3-boot.log";
	armsx3_ios_set_diagnostic_log_path(g_boot_log_path.c_str());
	armsx3_ios_diagnostic_log(fmt::format("persistent logs ready core=%s boot=%s",
		g_log_path, g_boot_log_path).c_str());

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

	// ASMJIT is not available on this ARM64 mobile target. A stale config copied
	// from another build must not be allowed to reach the SPU bootstrap path.
	if (g_cfg.core.spu_decoder == spu_decoder_type::asmjit)
	{
		g_cfg.core.spu_decoder.set(spu_decoder_type::llvm);
		armsx3_ios_diagnostic_log("SPU decoder corrected from ASMJIT to LLVM");
	}
	g_cfg.core.llvm_cpu.from_string("");

	if (g_cfg.video.shadermode == shader_mode::async_with_interpreter ||
		g_cfg.video.shadermode == shader_mode::interpreter_only)
	{
		g_cfg.video.shadermode.set(shader_mode::async_recompiler);
		Emulator::SaveSettings(g_cfg.to_string(), {});
		armsx3_ios_diagnostic_log("shader mode corrected to Async Recompiler for iOS MoltenVK sampler limit");
	}

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
	restore_firmware_runtime_overrides();
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

	// Booting VSH is the worst case for eager LLVM precompilation on iOS: RPCS3 scans
	// dev_flash and compiles a large collection of firmware SPRX modules before the XMB
	// gets a chance to draw a frame. On a 4 GB A-series device that turns a healthy boot
	// into a long black screen and repeatedly pushes LLVM to its mobile memory limits.
	//
	// RPCS3 already supports the intended alternative: with LLVM Precompilation disabled,
	// the PPU still uses the LLVM recompiler and caches code, but extra modules are compiled
	// only when they are actually loaded. Apply that policy only to the firmware session;
	// normal game boots keep the user's setting.
	if (!g_firmware_saved_llvm_precompilation)
		g_firmware_saved_llvm_precompilation = static_cast<bool>(g_cfg.core.llvm_precompilation);
	if (!g_firmware_saved_ppu_decoder)
		g_firmware_saved_ppu_decoder = g_cfg.core.ppu_decoder.get();
	if (!g_firmware_saved_spu_decoder)
		g_firmware_saved_spu_decoder = g_cfg.core.spu_decoder.get();
	g_cfg.core.llvm_precompilation.set(false);
	g_cfg.core.ppu_decoder.set(ppu_decoder_type::_static);
	g_cfg.core.spu_decoder.set(spu_decoder_type::_static);
	armsx3_ios_diagnostic_log("firmware boot: static PPU + static SPU interpreters + LLVM precompilation override requested");

	const int result = boot_path_locked(vsh_path);
	if (result != static_cast<int>(game_boot_result::no_errors))
		restore_firmware_runtime_overrides();
	return result;
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
extern "C" bool armsx3_ios_stop()
{
	if (!g_initialized.load(std::memory_order_acquire)) return true;
	std::lock_guard lock(g_lifecycle_mutex);
	Emu.Kill();
	for (int elapsed = 0; !Emu.IsStopped(true) && elapsed < 10000; elapsed += 20)
		std::this_thread::sleep_for(std::chrono::milliseconds(20));
	const bool stopped = Emu.IsStopped(true);
	if (stopped)
	{
		restore_firmware_runtime_overrides();
	}
	else
	{
		armsx3_ios_diagnostic_log(fmt::format("stop timed out state=%d",
			static_cast<int>(Emu.GetStatus(false))).c_str());
		emit_event(ARMSX3_IOS_EVENT_ERROR, "Emulation did not finish stopping");
	}
	return stopped;
}
extern "C" int armsx3_ios_state() { return static_cast<int>(Emu.GetStatus(false)); }

extern "C" bool armsx3_ios_save_state_slot(unsigned int slot, bool resume_after_save)
{
	if (slot >= 10 || (!Emu.IsRunning() && !Emu.IsPaused())) return false;
	const std::string title = Emu.GetTitleID();
	const std::string boot = Emu.GetBoot();
	if (title.empty()) return false;
	Emu.CallFromMainThread([slot, title, boot, resume_after_save]()
	{
		Emu.after_kill_callback = [slot, title, boot, resume_after_save]()
		{
			ios_slot_capture(slot, title, boot);
			if (resume_after_save) Emu.Restart(true, false);
		};
		if (resume_after_save) Emu.SetContinuousMode(true);
		Emu.Kill(false, true);
	});
	return true;
}

extern "C" bool armsx3_ios_load_state_slot(unsigned int slot)
{
	if (slot >= 10) return false;
	const std::string path = ios_slot_find(Emu.GetTitleID(), slot);
	if (path.empty()) return false;
	Emu.CallFromMainThread([path]()
	{
		Emu.SetContinuousMode(true);
		Emu.after_kill_callback = [path]()
		{
			const game_boot_result result = Emu.BootGame(path, "", true);
			if (result != game_boot_result::no_errors)
				armsx3_ios_log.error("savestate load failed '%s': %s", path, fmt::format("%s", result));
		};
		Emu.Kill(false, false);
	});
	return true;
}

extern "C" bool armsx3_ios_has_state_slot(unsigned int slot)
{
	return slot < 10 && !ios_slot_find(Emu.GetTitleID(), slot).empty();
}

extern "C" bool armsx3_ios_delete_state_slot(unsigned int slot)
{
	if (slot >= 10) return false;
	const std::string title = Emu.GetTitleID();
	const std::string path = ios_slot_find(title, slot);
	if (path.empty() || !fs::remove_file(path)) return false;
	const std::string thumb = ios_slot_dir(title) + "slot" + std::to_string(slot) + ".thumb";
	if (fs::is_file(thumb)) fs::remove_file(thumb);
	return true;
}

extern "C" bool armsx3_ios_restart()
{
	if (!Emu.IsRunning() && !Emu.IsPaused()) return false;
	Emu.CallFromMainThread([]()
	{
		Emu.SetContinuousMode(true);
		Emu.Restart(true);
	});
	return true;
}

extern "C" int armsx3_ios_step_resolution(int direction)
{
	if (direction == 0) return static_cast<int>(g_cfg.video.resolution_scale_percent);
	const int current = static_cast<int>(g_cfg.video.resolution_scale_percent);
	const int current_step = std::clamp((current + 50) / 100, 1, 8);
	const int next = std::clamp(current_step + (direction > 0 ? 1 : -1), 1, 8) * 100;
	g_cfg.video.resolution_scale_percent.set(next);
	Emulator::SaveSettings(g_cfg.to_string(), Emu.GetTitleID());
	emit_event(ARMSX3_IOS_EVENT_STATUS, fmt::format("Resolution {}x", next / 100));
	return next;
}

extern "C" bool armsx3_ios_request_screenshot()
{
	if (!Emu.IsRunning() && !Emu.IsPaused()) return false;
	g_user_asked_for_screenshot = true;
	return true;
}

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

extern "C" const char* armsx3_ios_patches_json(const char* serial_raw)
{
	const std::string serial = serial_raw ? serial_raw : "";
	const patch_engine::patch_map& db = cached_patch_db();
	const patch_engine::patch_map enabled = patch_engine::load_config();

	std::string out = "[";
	bool first = true;
	for (const auto& [hash, container] : db)
	{
		for (const auto& [description, info] : container.patch_info_map)
		{
			bool applies = serial.empty();
			std::string app_version = "all";
			std::string game_title;
			for (const auto& [title, serials] : info.titles)
			{
				for (const auto& [ser, versions] : serials)
				{
					const bool hit = !serial.empty() && ser == serial;
					if (hit || serial.empty())
						if (game_title.empty()) game_title = title;
					if (hit)
					{
						applies = true;
						game_title = title;
						if (!versions.empty()) app_version = versions.begin()->first;
					}
				}
			}
			if (!applies) continue;

			bool is_on = false;
			if (auto it = enabled.find(hash); it != enabled.end())
			{
				if (auto p = it->second.patch_info_map.find(description); p != it->second.patch_info_map.end())
				{
					for (const auto& [title, serials] : p->second.titles)
						for (const auto& [ser, versions] : serials)
						{
							if (!serial.empty() && ser != serial && ser != patch_key::all) continue;
							for (const auto& [ver, values] : versions)
								if (values.enabled) is_on = true;
						}
				}
			}

			if (!first) out += ',';
			first = false;
			out += "{\"hash\":" + json_quote(hash)
				+ ",\"name\":" + json_quote(description)
				+ ",\"author\":" + json_quote(info.author)
				+ ",\"notes\":" + json_quote(info.notes)
				+ ",\"version\":" + json_quote(info.patch_version)
				+ ",\"appVersion\":" + json_quote(app_version)
				+ ",\"game\":" + json_quote(game_title)
				+ ",\"enabled\":" + (is_on ? "true" : "false") + "}";
		}
	}
	out += ']';
	{
		std::lock_guard lock(g_lifecycle_mutex);
		g_patch_json = std::move(out);
		return g_patch_json.c_str();
	}
}

extern "C" bool armsx3_ios_patch_set_enabled(const char* hash_raw, const char* description_raw,
	const char* serial_raw, const char* app_version_raw, bool enabled_value)
{
	if (!hash_raw || !description_raw) return false;
	const std::string hash = hash_raw;
	const std::string description = description_raw;
	const std::string serial = serial_raw ? serial_raw : "";
	const std::string app_version = app_version_raw ? app_version_raw : "all";
	const patch_engine::patch_map& db = cached_patch_db();
	patch_engine::patch_map config = patch_engine::load_config();

	auto h = db.find(hash);
	if (h == db.end()) return false;
	auto p = h->second.patch_info_map.find(description);
	if (p == h->second.patch_info_map.end()) return false;

	auto& entry = config[hash];
	entry.hash = hash;
	entry.version = h->second.version;
	auto& info = entry.patch_info_map[description];
	info = p->second;

	bool touched = false;
	for (auto& [title, serials] : info.titles)
		for (auto& [ser, versions] : serials)
			for (auto& [ver, values] : versions)
			{
				if (ser == serial || serial.empty() || ser == patch_key::all)
				{
					if (app_version == "all" || ver == app_version || ser == patch_key::all)
					{
						values.enabled = enabled_value;
						touched = true;
					}
				}
			}
	if (!touched && !serial.empty()) return false;
	patch_engine::save_config(config);
	return true;
}

extern "C" const char* armsx3_ios_log_path() { return g_log_path.c_str(); }
extern "C" const char* armsx3_ios_boot_log_path() { return g_boot_log_path.c_str(); }
extern "C" const char* armsx3_ios_firmware_version() { return g_firmware_version.c_str(); }
