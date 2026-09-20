#pragma once

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#include <cstddef>
#include <cstdint>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

extern "C" bool armsx3_ios_legacy_jit_write_protect(int enabled) noexcept;

namespace armsx3::ios
{
enum class jit_write_protect_backend
{
	pthread_api,
	os_thread_api,
	aprr,
	sprr,
	unavailable,
};

template <std::size_t N>
static inline void jit_boot_log(const char (&message)[N]) noexcept
{
	(void)::write(STDERR_FILENO, message, N - 1);
}

struct jit_write_protect_api
{
	using toggle_fn = void (*)(int);
	using restrict_fn = void (*)();

	toggle_fn toggle{};
	restrict_fn to_rw{};
	restrict_fn to_rx{};
	jit_write_protect_backend backend{jit_write_protect_backend::unavailable};
};

static inline const jit_write_protect_api& get_jit_write_protect_api() noexcept
{
	static const jit_write_protect_api api = []() noexcept
	{
		jit_write_protect_api result{};
		result.toggle = reinterpret_cast<jit_write_protect_api::toggle_fn>(
			dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
		if (result.toggle)
		{
			result.backend = jit_write_protect_backend::pthread_api;
			jit_boot_log("[ARMSX3_BOOT] jit write protect backend=pthread\n");
			return result;
		}

		result.to_rw = reinterpret_cast<jit_write_protect_api::restrict_fn>(
			dlsym(RTLD_DEFAULT, "os_thread_self_restrict_rwx_to_rw"));
		result.to_rx = reinterpret_cast<jit_write_protect_api::restrict_fn>(
			dlsym(RTLD_DEFAULT, "os_thread_self_restrict_rwx_to_rx"));
		if (result.to_rw && result.to_rx)
		{
			result.backend = jit_write_protect_backend::os_thread_api;
			jit_boot_log("[ARMSX3_BOOT] jit write protect backend=os_thread\n");
			return result;
		}

#if defined(__aarch64__)
		// On iOS 15 pthread_jit_write_protect_np is not exported. MAP_JIT is
		// nevertheless protected by a per-thread Apple permission register.
		// The arm64 commpage publishes both the register values and a capability
		// byte selecting the register generation: 1 = APRR, 2/3 = SPRR.
		constexpr std::uintptr_t aprr_support_address = 0x0fffffc10cull;
		constexpr std::uintptr_t aprr_jit_rw_address = 0x0fffffc110ull;
		constexpr std::uintptr_t aprr_jit_rx_address = 0x0fffffc118ull;
		const auto support = *reinterpret_cast<volatile const std::uint8_t*>(aprr_support_address);
		const auto rw = *reinterpret_cast<volatile const std::uint64_t*>(aprr_jit_rw_address);
		const auto rx = *reinterpret_cast<volatile const std::uint64_t*>(aprr_jit_rx_address);
		if (support == 1 && rw && rx && rw != rx)
		{
			result.backend = jit_write_protect_backend::aprr;
			jit_boot_log("[ARMSX3_BOOT] jit write protect backend=aprr\n");
			return result;
		}
		if ((support == 2 || support == 3) && rw && rx && rw != rx)
		{
			result.backend = jit_write_protect_backend::sprr;
			jit_boot_log("[ARMSX3_BOOT] jit write protect backend=sprr\n");
			return result;
		}
#endif

		jit_boot_log("[ARMSX3_BOOT] jit write protect backend=unavailable\n");
		return result;
	}();

	return api;
}
} // namespace armsx3::ios

static inline void armsx3_ios_jit_write_protect(int enabled) noexcept
{
	if (armsx3_ios_legacy_jit_write_protect(enabled))
	{
		return;
	}

	const auto& api = armsx3::ios::get_jit_write_protect_api();
	switch (api.backend)
	{
	case armsx3::ios::jit_write_protect_backend::pthread_api:
		api.toggle(enabled);
		break;
	case armsx3::ios::jit_write_protect_backend::os_thread_api:
		(enabled ? api.to_rx : api.to_rw)();
		break;
	case armsx3::ios::jit_write_protect_backend::aprr:
	{
#if defined(__aarch64__)
		constexpr std::uintptr_t aprr_jit_rw_address = 0x0fffffc110ull;
		constexpr std::uintptr_t aprr_jit_rx_address = 0x0fffffc118ull;
		const auto address = enabled ? aprr_jit_rx_address : aprr_jit_rw_address;
		const auto value = *reinterpret_cast<volatile const std::uint64_t*>(address);
		__asm__ volatile("msr S3_4_C15_C2_7, %0\n\tisb sy" :: "r"(value) : "memory");
#endif
		break;
	}
	case armsx3::ios::jit_write_protect_backend::sprr:
	{
#if defined(__aarch64__)
		constexpr std::uintptr_t aprr_jit_rw_address = 0x0fffffc110ull;
		constexpr std::uintptr_t aprr_jit_rx_address = 0x0fffffc118ull;
		const auto address = enabled ? aprr_jit_rx_address : aprr_jit_rw_address;
		const auto value = *reinterpret_cast<volatile const std::uint64_t*>(address);
		__asm__ volatile("msr S3_6_C15_C1_5, %0\n\tisb sy" :: "r"(value) : "memory");
#endif
		break;
	}
	case armsx3::ios::jit_write_protect_backend::unavailable:
		break;
	}
}

#define pthread_jit_write_protect_np armsx3_ios_jit_write_protect
#endif
