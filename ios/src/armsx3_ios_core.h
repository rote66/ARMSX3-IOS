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
bool armsx3_ios_settings_editable(void);
const char* armsx3_ios_settings_json(const char* path);
bool armsx3_ios_set_setting_json(const char* path, const char* json_value);
void armsx3_ios_pause(void);
void armsx3_ios_resume(void);
bool armsx3_ios_stop(void);
int armsx3_ios_state(void);

bool armsx3_ios_set_pad(int port, uint32_t digital1, uint32_t digital2,
	uint8_t left_x, uint8_t left_y, uint8_t right_x, uint8_t right_y,
	uint8_t left_trigger, uint8_t right_trigger);
bool armsx3_ios_performance_overlay_enabled(void);
bool armsx3_ios_set_performance_overlay_enabled(bool enabled);
bool armsx3_ios_save_state_slot(unsigned int slot, bool resume_after_save);
bool armsx3_ios_load_state_slot(unsigned int slot);
bool armsx3_ios_has_state_slot(unsigned int slot);
bool armsx3_ios_delete_state_slot(unsigned int slot);
bool armsx3_ios_restart(void);
int armsx3_ios_step_resolution(int direction);
bool armsx3_ios_request_screenshot(void);

const char* armsx3_ios_patches_json(const char* serial);
bool armsx3_ios_patch_set_enabled(const char* hash, const char* description,
	const char* serial, const char* app_version, bool enabled);

const char* armsx3_ios_log_path(void);
const char* armsx3_ios_boot_log_path(void);
const char* armsx3_ios_firmware_version(void);

#ifdef __cplusplus
}
#endif
