#include <libusb.h>

#include <cstdlib>
#include <cstring>

// iOS applications cannot enumerate arbitrary USB devices through IOKit.  The
// emulator still links its emulated USB stack, so provide an empty host backend
// instead of pretending that desktop libusb is usable on iPhoneOS.
int LIBUSB_CALL libusb_init(libusb_context** ctx)
{
	if (ctx) *ctx = nullptr;
	return LIBUSB_SUCCESS;
}

int LIBUSB_CALL libusb_init_context(libusb_context** ctx, const libusb_init_option[], int)
{
	return libusb_init(ctx);
}

void LIBUSB_CALL libusb_exit(libusb_context*) {}
int LIBUSB_CALLV libusb_set_option(libusb_context*, libusb_option, ...) { return LIBUSB_SUCCESS; }
int LIBUSB_CALL libusb_has_capability(uint32_t) { return 0; }

const char* LIBUSB_CALL libusb_error_name(int error_code)
{
	switch (error_code)
	{
	case LIBUSB_SUCCESS: return "LIBUSB_SUCCESS";
	case LIBUSB_ERROR_NOT_SUPPORTED: return "LIBUSB_ERROR_NOT_SUPPORTED";
	case LIBUSB_ERROR_NO_DEVICE: return "LIBUSB_ERROR_NO_DEVICE";
	default: return "LIBUSB_ERROR_OTHER";
	}
}

ssize_t LIBUSB_CALL libusb_get_device_list(libusb_context*, libusb_device*** list)
{
	if (list)
	{
		*list = static_cast<libusb_device**>(std::calloc(1, sizeof(libusb_device*)));
	}
	return 0;
}

void LIBUSB_CALL libusb_free_device_list(libusb_device** list, int) { std::free(list); }
libusb_device* LIBUSB_CALL libusb_ref_device(libusb_device* dev) { return dev; }
void LIBUSB_CALL libusb_unref_device(libusb_device*) {}
uint8_t LIBUSB_CALL libusb_get_port_number(libusb_device*) { return 0; }
uint8_t LIBUSB_CALL libusb_get_device_address(libusb_device*) { return 0; }
int LIBUSB_CALL libusb_get_device_descriptor(libusb_device*, libusb_device_descriptor*) { return LIBUSB_ERROR_NO_DEVICE; }

int LIBUSB_CALL libusb_open(libusb_device*, libusb_device_handle** handle)
{
	if (handle) *handle = nullptr;
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

void LIBUSB_CALL libusb_close(libusb_device_handle*) {}
int LIBUSB_CALL libusb_get_configuration(libusb_device_handle*, int*) { return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_set_configuration(libusb_device_handle*, int) { return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_claim_interface(libusb_device_handle*, int) { return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_release_interface(libusb_device_handle*, int) { return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_set_auto_detach_kernel_driver(libusb_device_handle*, int) { return LIBUSB_ERROR_NOT_SUPPORTED; }

int LIBUSB_CALL libusb_control_transfer(libusb_device_handle*, uint8_t, uint8_t,
	uint16_t, uint16_t, unsigned char*, uint16_t, unsigned int)
{
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

libusb_transfer* LIBUSB_CALL libusb_alloc_transfer(int iso_packets)
{
	const size_t size = sizeof(libusb_transfer) +
		static_cast<size_t>(iso_packets > 0 ? iso_packets : 0) * sizeof(libusb_iso_packet_descriptor);
	auto* transfer = static_cast<libusb_transfer*>(std::calloc(1, size));
	if (transfer) transfer->num_iso_packets = iso_packets;
	return transfer;
}

int LIBUSB_CALL libusb_submit_transfer(libusb_transfer*) { return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_cancel_transfer(libusb_transfer*) { return LIBUSB_ERROR_NOT_SUPPORTED; }

void LIBUSB_CALL libusb_free_transfer(libusb_transfer* transfer)
{
	if (transfer && (transfer->flags & LIBUSB_TRANSFER_FREE_BUFFER))
	{
		std::free(transfer->buffer);
	}
	std::free(transfer);
}

int LIBUSB_CALL libusb_hotplug_register_callback(libusb_context*, int, int, int, int, int,
	libusb_hotplug_callback_fn, void*, libusb_hotplug_callback_handle* handle)
{
	if (handle) *handle = 0;
	return LIBUSB_ERROR_NOT_SUPPORTED;
}

void LIBUSB_CALL libusb_hotplug_deregister_callback(libusb_context*, libusb_hotplug_callback_handle) {}
int LIBUSB_CALL libusb_handle_events_timeout_completed(libusb_context*, timeval*, int*) { return LIBUSB_SUCCESS; }
