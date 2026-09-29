#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*armsx3_ios_event_callback)(int event, const char* message);

void armsx3_ios_diagnostic_log(const char* message);
void armsx3_ios_set_diagnostic_log_path(const char* path);

enum armsx3_ios_event
{
	ARMSX3_IOS_EVENT_STATUS = 0,
	ARMSX3_IOS_EVENT_ERROR = 1,
	ARMSX3_IOS_EVENT_RUNNING = 2,
	ARMSX3_IOS_EVENT_STOPPED = 3,
	ARMSX3_IOS_EVENT_PAUSED = 4,
	ARMSX3_IOS_EVENT_RESUMED = 5,
	ARMSX3_IOS_EVENT_PROGRESS = 6,
	ARMSX3_IOS_EVENT_PROGRESS_END = 7,
};

bool armsx3_ios_initialize(const char* root_dir, void* metal_view,
	armsx3_ios_event_callback callback);
bool armsx3_ios_is_initialized(void);
void armsx3_ios_set_surface(void* metal_view, int pixel_width, int pixel_height,
	double refresh_rate);
bool armsx3_ios_jit_authorized(void);
bool armsx3_ios_jit_test(void);

int armsx3_ios_boot(const char* path);
int armsx3_ios_boot_firmware(void);
bool armsx3_ios_can_boot_firmware(void);
bool armsx3_ios_install_firmware(const char* path);
bool armsx3_ios_install_package(const char* path);
bool armsx3_ios_install_packages(const char* const* paths, size_t count);
bool armsx3_ios_game_locked(const char* game_path);
bool armsx3_ios_install_rap_for_game(const char* rap_path, const char* game_path);
bool armsx3_ios_extract_package_to(const char* path, const char* destination);
bool armsx3_ios_settings_editable(void);
unsigned int armsx3_ios_auto_llvm_workers(void);
unsigned int armsx3_ios_max_llvm_workers(void);
const char* armsx3_ios_settings_json(const char* path);
bool armsx3_ios_set_setting_json(const char* path, const char* json_value);
bool armsx3_ios_set_setting_json_live(const char* path, const char* json_value);
void armsx3_ios_capture_frame(void);
const char* armsx3_ios_game_info_json(const char* path);
const char* armsx3_ios_game_settings_json(const char* serial, const char* path);
bool armsx3_ios_set_game_setting_json(const char* serial, const char* path, const char* json_value);
bool armsx3_ios_set_game_setting_json_live(const char* serial, const char* path, const char* json_value);
bool armsx3_ios_reset_game_settings(const char* serial);
bool armsx3_ios_reset_global_settings(void);
const char* armsx3_ios_game_config_text(const char* serial);
bool armsx3_ios_import_game_config_text(const char* serial, const char* text);
const char* armsx3_ios_rpcn_get_config(void);
void armsx3_ios_rpcn_set_config(const char* host, const char* npid, const char* password, const char* token);
const char* armsx3_ios_rpcn_status(void);
const char* armsx3_ios_rpcn_add_host(const char* desc, const char* host);
const char* armsx3_ios_rpcn_del_host(const char* desc, const char* host);
void armsx3_ios_rpcn_reset_hosts(void);
void armsx3_ios_rpcn_set_ipv6(bool enabled);
const char* armsx3_ios_rpcn_create_account(const char* npid, const char* password, const char* online_name, const char* email);
const char* armsx3_ios_rpcn_resend_token(const char* npid, const char* password);
const char* armsx3_ios_rpcn_send_reset_token(const char* npid, const char* email);
const char* armsx3_ios_rpcn_reset_password(const char* npid, const char* token, const char* password);
const char* armsx3_ios_rpcn_test_login(void);
const char* armsx3_ios_rpcn_add_friend(const char* npid);
const char* armsx3_ios_rpcn_remove_friend(const char* npid);
const char* armsx3_ios_rpcn_get_friends(void);
const char* armsx3_ios_rpcn_delete_trophies(void);
void armsx3_ios_pause(void);
void armsx3_ios_resume(void);
bool armsx3_ios_stop(void);
int armsx3_ios_state(void);
bool armsx3_ios_game_active(void);
bool armsx3_ios_is_paused(void);
const char* armsx3_ios_current_title(void);
const char* armsx3_ios_current_title_id(void);
const char* armsx3_ios_current_trophy_name(void);
double armsx3_ios_current_fps(void);

bool armsx3_ios_set_pad(int port, uint32_t digital1, uint32_t digital2,
	uint8_t left_x, uint8_t left_y, uint8_t right_x, uint8_t right_y,
	uint8_t left_trigger, uint8_t right_trigger);
uint16_t armsx3_ios_pad_rumble(int port);
void armsx3_ios_set_render_position(bool portrait_top, uint32_t top_inset_px);
bool armsx3_ios_portrait_render_top(void);
bool armsx3_ios_performance_overlay_enabled(void);
bool armsx3_ios_set_performance_overlay_enabled(bool enabled);
bool armsx3_ios_set_performance_overlay_live(bool enabled);
int armsx3_ios_performance_overlay_detail(void);
bool armsx3_ios_set_performance_overlay_detail_live(int detail);
int armsx3_ios_performance_overlay_position(void);
bool armsx3_ios_set_performance_overlay_position(int position);
const char* armsx3_ios_performance_overlay_color(void);
bool armsx3_ios_set_performance_overlay_color(const char* rgba_hex);
bool armsx3_ios_save_state_slot(unsigned int slot, bool resume_after_save);
bool armsx3_ios_load_state_slot(unsigned int slot);
bool armsx3_ios_has_state_slot(unsigned int slot);
bool armsx3_ios_delete_state_slot(unsigned int slot);
int armsx3_ios_import_state_to_free_slot(const char* path);
bool armsx3_ios_restart(void);
bool armsx3_ios_swap_disc(const char* path);
int armsx3_ios_step_resolution(int direction);
bool armsx3_ios_request_screenshot(void);

const char* armsx3_ios_patches_json(const char* serial);
bool armsx3_ios_patch_set_enabled(const char* hash, const char* description,
	const char* serial, const char* app_version, bool enabled);

const char* armsx3_ios_log_path(void);
const char* armsx3_ios_boot_log_path(void);
const char* armsx3_ios_firmware_version(void);
const char* armsx3_ios_core_version(void);

#ifdef __cplusplus
}
#endif
