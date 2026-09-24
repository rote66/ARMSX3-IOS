#include "util/types.hpp"
#include "util/sysinfo.hpp"
#include "JIT.h"
#include "StrFmt.h"
#include "File.h"
#include "util/logs.hpp"
#include "util/vm.hpp"
#include "util/asm.hpp"
#include "util/v128.hpp"
#include "util/simd.hpp"

#ifdef __linux__
#include <unistd.h>
#define CAN_OVERCOMMIT
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mutex>
#endif

#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
extern "C" void armsx3_ios_diagnostic_log(const char* message);
#endif

LOG_CHANNEL(jit_log, "JIT");

void jit_announce(uptr func, usz size, std::string_view name)
{
#ifdef __linux__
#if 0
	static const struct tmp_perf_map
	{
		std::string name{fmt::format("/tmp/perf-%d.map", getpid())};
		fs::file data{name, fs::rewrite + fs::append};

		tmp_perf_map() = default;
		tmp_perf_map(const tmp_perf_map&) = delete;
		tmp_perf_map& operator=(const tmp_perf_map&) = delete;

		~tmp_perf_map()
		{
			fs::remove_file(name);
		}
	} s_map;

	if (size && name.size())
	{
		s_map.data.write(fmt::format("%x %x %s\n", func, size, name));
	}

	if (!func && !size && !name.size())
	{
		fs::remove_file(s_map.name);
		return;
	}
#endif
#endif

	if (!size)
	{
		jit_log.error("Empty function announced: %s (%p)", name, func);
		return;
	}

	// If directory ASMJIT doesn't exist, nothing will be written
	static constexpr u64 c_dump_size = 0x1'0000'0000;
	static constexpr u64 c_index_size = c_dump_size / 16;
	static atomic_t<u64> g_index_off = 0;
	static atomic_t<u64> g_data_off = c_index_size;

	static void* g_asm = []() -> void*
	{
		fs::remove_all(fs::get_cache_dir() + "/ASMJIT/", false);

		fs::file objs(fmt::format("%s/ASMJIT/.objects", fs::get_cache_dir()), fs::read + fs::rewrite);

		if (!objs || !objs.trunc(c_dump_size))
		{
			return nullptr;
		}

		return utils::memory_map_fd(objs.get_handle(), c_dump_size, utils::protection::rw);
	}();

	if (g_asm && size < c_index_size)
	{
		struct entry
		{
			u64 addr; // RPCS3 process address
			u32 size; // Function size
			u32 off; // Function offset
		};

		// Write index entry at the beginning of file, and data + NTS name at fixed offset
		const u64 index_off = g_index_off.fetch_add(1);
		const u64 size_all = size + name.size() + 1;
		const u64 data_off = g_data_off.fetch_add(size_all);

		// If either index or data area is exhausted, nothing will be written
		if (index_off < c_index_size / sizeof(entry) && data_off + size_all < c_dump_size)
		{
			entry& index = static_cast<entry*>(g_asm)[index_off];

			std::memcpy(static_cast<char*>(g_asm) + data_off, reinterpret_cast<char*>(func), size);
			std::memcpy(static_cast<char*>(g_asm) + data_off + size, name.data(), name.size());
			index.size = static_cast<u32>(size);
			index.off = static_cast<u32>(data_off);
			atomic_storage<u64>::store(index.addr, func);
		}
	}

	if (g_asm && !name.empty() && name[0] != '_')
	{
		// Save some objects separately
		fs::file dump(fmt::format("%s/ASMJIT/%s", fs::get_cache_dir(), name), fs::rewrite);

		if (dump)
		{
			dump.write(reinterpret_cast<uchar*>(func), size);
		}
	}
}

struct jit_memory_arena
{
	u8* base{};
	usz segment_size{};
	bool map_jit{};
};

#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
static atomic_t<bool> s_ios_jit_execution_ready{false};
extern "C" bool armsx3_ios_jit_authorized();
#endif

static const jit_memory_arena& get_jit_memory_arena()
{
	// Reserve the JIT arena (magic static). Desktop keeps the original 2 GiB
	// layout. iOS cannot reliably create a 2 GiB MAP_JIT mapping, so keep code
	// and data contiguous but try progressively smaller layouts. The iOS global
	// asmjit runtime below shares this arena as well: on iOS 15/Dopamine a first
	// MAP_JIT mapping succeeds while a second MAP_JIT mapping can fail even at
	// only 16 MiB.
	static const jit_memory_arena s_arena = []() -> jit_memory_arena
	{
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
		struct candidate
		{
			usz segment_size;
			const char* success;
			const char* failure;
		};

		// Total arena sizes from 512 MiB down to the already proven 16 MiB
		// MAP_JIT size. Code and data each receive one half.
		constexpr candidate candidates[] =
		{
			{0x10000000, "jit arena=512m", "jit arena=512m failed"},
			{0x08000000, "jit arena=256m", "jit arena=256m failed"},
			{0x04000000, "jit arena=128m", "jit arena=128m failed"},
			{0x02000000, "jit arena=64m",  "jit arena=64m failed"},
			{0x01000000, "jit arena=32m",  "jit arena=32m failed"},
			{0x00800000, "jit arena=16m",  "jit arena=16m failed"},
		};

		for (const auto& entry : candidates)
		{
			if (void* ptr = utils::memory_reserve(entry.segment_size * 2, true))
			{
				armsx3_ios_diagnostic_log(entry.success);
				return {static_cast<u8*>(ptr), entry.segment_size, true};
			}

			armsx3_ios_diagnostic_log(entry.failure);
		}

		// TrollStore-safe entitlements on iOS 15 may intentionally reject MAP_JIT
		// at process launch. Global RPCS3 initializers still need storage for the
		// generated trampolines, but they do not execute them before main(). Keep a
		// normal RW bootstrap arena and promote its used code range after UIKit has
		// started. This avoids making dynamic-codesigning a launch-time requirement.
		for (const auto& entry : candidates)
		{
			if (void* ptr = utils::memory_reserve(entry.segment_size * 2, false))
			{
				if (entry.segment_size == 0x10000000)
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=512m");
				else if (entry.segment_size == 0x08000000)
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=256m");
				else if (entry.segment_size == 0x04000000)
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=128m");
				else if (entry.segment_size == 0x02000000)
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=64m");
				else if (entry.segment_size == 0x01000000)
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=32m");
				else
					armsx3_ios_diagnostic_log("jit bootstrap rw arena=16m");
				return {static_cast<u8*>(ptr), entry.segment_size, false};
			}
		}

		armsx3_ios_diagnostic_log("jit arena allocation failed");
		return {};
#else
		constexpr usz segment_size = 0x40000000;
		void* ptr = utils::memory_reserve(segment_size * 2, true);
#ifdef CAN_OVERCOMMIT
		utils::memory_commit(ptr, segment_size * 2);
		utils::memory_protect(ptr, segment_size, utils::protection::wx);
#endif
		return {static_cast<u8*>(ptr), segment_size, true};
#endif
	}();

	return s_arena;
}

static u8* get_jit_memory(bool exec)
{
	const auto& arena = get_jit_memory_arena();
	ensure(arena.base && arena.segment_size);
	return arena.base + (exec ? 0 : arena.segment_size);
}

static usz get_jit_segment_size()
{
	return ensure(get_jit_memory_arena().segment_size);
}

// Allocation counters for the code/data subranges.
static atomic_t<u64> s_code_pos{0}, s_data_pos{0};

#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
extern "C" bool armsx3_ios_legacy_jit_write_protect(int enabled) noexcept
{
	const auto& arena = get_jit_memory_arena();
	if (arena.map_jit)
	{
		return false;
	}

	// Ordinary anonymous mappings have process-wide page permissions. Toggling
	// the complete shared arena RW while another PPU/SPU thread is executing old
	// code from it races immediately into SIGBUS. Legacy mode therefore never
	// changes existing executable pages here. New executable allocations are
	// page-aligned while execution is active and are sealed individually by
	// jit_runtime::finalize_code() after all writes/relocations are complete.
	(void)enabled;
	return true;
}
#endif

// Snapshot of code generated before main()
static std::vector<u8> s_code_init, s_data_init;

template <atomic_t<u64>& Ctr, bool Exec, utils::protection Prot>
static u8* add_jit_memory(usz size, usz align)
{
	// Select code/data subrange from the contiguous arena.
	u8* pointer = get_jit_memory(Exec);
	const usz segment_size = get_jit_segment_size();

	if (!size && !align) [[unlikely]]
	{
		// Return subrange info
		return pointer;
	}

	if (!size && align == 1)
	{
		// Return memory top address
		return pointer + (Ctr.load() & 0xffff'ffff);
	}

	u64 olda, newa;

	// Simple allocation by incrementing pointer to the next free data
	const u64 pos = Ctr.atomic_op([&](u64& ctr) -> u64
	{
		const u64 _pos = utils::align(ctr & 0xffff'ffff, align);
		const u64 _new = utils::align(_pos + size, align);

		if (_new > segment_size) [[unlikely]]
		{
			// Sorry, we failed, and further attempts should fail too.
			ctr |= segment_size;
			return -1;
		}

		// Last allocation is stored in highest bits
		olda = ctr >> 32;
		newa = olda;

		// Check the necessity to commit more memory
		if (_new > olda) [[unlikely]]
		{
			newa = utils::align(_new, 0x200000);
		}

		ctr += _new - (ctr & 0xffff'ffff);
		return _pos;
	});

	if (pos == umax) [[unlikely]]
	{
		jit_log.error("Out of JIT %s memory (size=0x%x, align=0x%x, capacity=0x%x)", Exec ? "code" : "data", size, align, segment_size);
		return nullptr;
	}

	if (olda != newa) [[unlikely]]
	{
#ifndef CAN_OVERCOMMIT
		// Apple arm64 reserves this arena as RW from the initial mmap because 16 KiB
		// pages cannot safely start as PROT_NONE here. The data half therefore needs
		// no permission transition at all. On iOS 15, redundantly mprotecting a large
		// MAP_JIT subrange RW -> RW can fail in pmap_enter with a resource shortage
		// during pre-main SPU dispatcher initialization. Executable allocations still
		// need the RW -> WX transition below.
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
		if constexpr (Prot != utils::protection::rw)
		{
			const auto& arena = get_jit_memory_arena();
			// MAP_JIT mappings need their executable pages committed immediately.
			// The ordinary bootstrap mapping must remain RW until prepare_execution()
			// is called after app launch. Once promoted, later code growth is made
			// executable page-by-page.
			if (arena.map_jit)
			{
				if (!utils::try_memory_commit(pointer + olda, newa - olda, Prot))
				{
					jit_log.error("Failed to make iOS JIT code executable (size=0x%x)", newa - olda);
					return nullptr;
				}
			}
		}
#else
		// Commit more memory.
		utils::memory_commit(pointer + olda, newa - olda, Prot);
#endif
#endif
		// Acknowledge committed memory
		Ctr.atomic_op([&](u64& ctr)
		{
			if ((ctr >> 32) < newa)
			{
				ctr += (newa - (ctr >> 32)) << 32;
			}
		});
	}

	ensure(pointer + pos >= get_jit_memory(Exec));
	ensure(pointer + pos < get_jit_memory(Exec) + segment_size);

	return pointer + pos;
}

const asmjit::Environment& jit_runtime_base::environment() const noexcept
{
	static const asmjit::Environment g_env = asmjit::Environment::host();

	return g_env;
}

void* jit_runtime_base::_add(asmjit::CodeHolder* code, usz align) noexcept
{
	ensure(!code->flatten());
	ensure(!code->resolveUnresolvedLinks());
	usz codeSize = code->codeSize();
	if (!codeSize)
		return nullptr;

	auto p = ensure(this->_alloc(codeSize, align));
	ensure(!code->relocateToBase(uptr(p)));

	{
		// We manage rw <-> rx transitions manually on Apple
		// because it's easier to keep track of when and where we need to toggle W^X
#if !(defined(ARCH_ARM64) && defined(__APPLE__))
		asmjit::VirtMem::ProtectJitReadWriteScope rwScope(p, codeSize);
#endif

		for (asmjit::Section* section : code->_sections)
		{
			if (section->offset() + section->bufferSize() > utils::align<usz>(codeSize, align))
			{
				fmt::throw_exception("CodeHolder section exceeds range: Section->offset: 0x%x, Section->bufferSize: 0x%x, alloted-memory=0x%x", section->offset(), section->bufferSize(), utils::align<usz>(codeSize, align));
			}

			std::memcpy(p + section->offset(), section->data(), section->bufferSize());
		}
	}

#if defined(ARCH_ARM64)
	// Instruction-cache maintenance for freshly copied code (trampolines, branch
	// patchpoints). Nothing flushed these before; another core could fetch stale
	// icache contents for this range.
	asmjit::VirtMem::flushInstructionCache(p, codeSize);
#endif

	if (!jit_runtime::finalize_code(p, codeSize))
	{
		return nullptr;
	}

	return p;
}

jit_runtime::jit_runtime()
{
}

jit_runtime::~jit_runtime()
{
}

uchar* jit_runtime::_alloc(usz size, usz align) noexcept
{
	return jit_runtime::alloc(size, align, true);
}

u8* jit_runtime::alloc(usz size, usz align, bool exec) noexcept
{
#if defined(__APPLE__)
	static std::mutex s_alloc_lock;
	std::lock_guard lock(s_alloc_lock);
#endif

	if (exec)
	{
	#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
		const auto& arena = get_jit_memory_arena();
		if (!arena.map_jit && s_ios_jit_execution_ready.load() && size)
		{
			// Once the bootstrap prefix is RX, never allocate new writable code in
			// the tail of an executable page. Each runtime code object starts on a
			// fresh page which remains RW until finalize_code() seals it RX.
			align = std::max<usz>(align, utils::get_page_size());
		}
	#endif
		return add_jit_memory<s_code_pos, true, utils::protection::wx>(size, align);
	}
	else
	{
		return add_jit_memory<s_data_pos, false, utils::protection::rw>(size, align);
	}
}

u8* jit_runtime::peek(bool exec) noexcept
{
	if (exec)
	{
		return add_jit_memory<s_code_pos, true, utils::protection::wx>(0, 1);
	}
	else
	{
		return add_jit_memory<s_data_pos, false, utils::protection::rw>(0, 1);
	}
}

bool jit_runtime::prepare_execution() noexcept
{
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
	if (!armsx3_ios_jit_authorized())
	{
		armsx3_ios_diagnostic_log("jit execution prepare: CS_DEBUGGED=0");
		return false;
	}

	const auto& arena = get_jit_memory_arena();
	if (!arena.base || !arena.segment_size)
	{
		armsx3_ios_diagnostic_log("jit execution prepare: no arena");
		return false;
	}

	if (arena.map_jit)
	{
		s_ios_jit_execution_ready.store(true);
		armsx3_ios_diagnostic_log("jit execution prepare: map_jit ready");
		return true;
	}

	const usz used = utils::align<usz>(s_code_pos.load() & 0xffff'ffff,
		static_cast<usz>(utils::get_page_size()));
	if (!used)
	{
		armsx3_ios_diagnostic_log("jit execution prepare: no code");
		return false;
	}

	asmjit::VirtMem::flushInstructionCache(arena.base, used);
	if (!utils::try_memory_commit(arena.base, used, utils::protection::rx))
	{
		armsx3_ios_diagnostic_log("jit execution prepare: legacy RX failed");
		return false;
	}

	s_ios_jit_execution_ready.store(true);
	armsx3_ios_diagnostic_log("jit execution prepare: legacy RX ready");
	return true;
#else
	return true;
#endif
}

bool jit_runtime::finalize_code(void* ptr, usz size) noexcept
{
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
	if (!ptr || !size)
	{
		return true;
	}

	const auto& arena = get_jit_memory_arena();
	if (arena.map_jit || !s_ios_jit_execution_ready.load())
	{
		return true;
	}

	const usz page_size = utils::get_page_size();
	const uptr begin = reinterpret_cast<uptr>(ptr) & ~(static_cast<uptr>(page_size) - 1);
	const uptr end = utils::align<uptr>(reinterpret_cast<uptr>(ptr) + size, page_size);

	asmjit::VirtMem::flushInstructionCache(ptr, size);
	if (!utils::try_memory_commit(reinterpret_cast<void*>(begin), end - begin, utils::protection::rx))
	{
		armsx3_ios_diagnostic_log("jit legacy page seal RX failed");
		return false;
	}
#else
	(void)ptr;
	(void)size;
#endif

	return true;
}

void jit_runtime::initialize()
{
	if (!s_code_init.empty() || !s_data_init.empty())
	{
		return;
	}

	// Create code/data snapshot
	s_code_init.resize(s_code_pos & 0xffff'ffff);
	std::memcpy(s_code_init.data(), alloc(0, 0, true), s_code_init.size());
	s_data_init.resize(s_data_pos & 0xffff'ffff);
	std::memcpy(s_data_init.data(), alloc(0, 0, false), s_data_init.size());
}

void jit_runtime::finalize() noexcept
{
#ifdef __APPLE__
	pthread_jit_write_protect_np(false);
#endif
	const usz segment_size = get_jit_segment_size();
	u8* const arena_base = get_jit_memory(true);
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
	const bool was_execution_ready = s_ios_jit_execution_ready.exchange(false);
	const bool map_jit = get_jit_memory_arena().map_jit;
	const u64 code_state = s_code_pos.load();
	const u64 data_state = s_data_pos.load();
	armsx3_ios_diagnostic_log(fmt::format(
		"jit finalize: arena=%uMB code_used=%uMB code_committed=%uMB data_used=%uMB data_committed=%uMB",
		static_cast<u32>((segment_size * 2) >> 20),
		static_cast<u32>((code_state & 0xffff'ffff) >> 20), static_cast<u32>((code_state >> 32) >> 20),
		static_cast<u32>((data_state & 0xffff'ffff) >> 20), static_cast<u32>((data_state >> 32) >> 20)).c_str());
#endif

	// Reset JIT memory
#ifdef CAN_OVERCOMMIT
	utils::memory_reset(arena_base, segment_size * 2, true);
	utils::memory_protect(arena_base, segment_size, utils::protection::wx);
#else
	// The iOS MAP_JIT arena starts RW and data allocations intentionally do not
	// issue a redundant mprotect(RW). Preserve that invariant across resets.
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
	utils::memory_reset(arena_base, segment_size * 2, utils::protection::rw, map_jit);
	armsx3_ios_diagnostic_log("jit finalize: arena reset without prefetch");
#else
	utils::memory_decommit(arena_base, segment_size * 2, true);
#endif
#endif

	s_code_pos = 0;
	s_data_pos = 0;

	// Restore code/data snapshot
	u8* const code_ptr = alloc(s_code_init.size(), 1, true);
	std::memcpy(code_ptr, s_code_init.data(), s_code_init.size());
	std::memcpy(alloc(s_data_init.size(), 1, false), s_data_init.data(), s_data_init.size());

#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
	if (was_execution_ready && !prepare_execution())
	{
		armsx3_ios_diagnostic_log("jit execution restore failed");
	}
#endif

#ifdef __APPLE__
	pthread_jit_write_protect_np(true);
#endif
#ifdef ARCH_ARM64
	// The restored range is executable code rewritten in place: perform real
	// instruction-cache maintenance for it (ISB/DSB alone cleans nothing).
	if (code_ptr && !s_code_init.empty())
	{
		asmjit::VirtMem::flushInstructionCache(code_ptr, s_code_init.size());
	}
#endif
}

jit_runtime_base& asmjit::get_global_runtime()
{
#if !(defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE)
	// 16 MiB for internal needs
	static constexpr u64 size = 1024 * 1024 * 16;
#endif

	struct custom_runtime final : jit_runtime_base
	{
		custom_runtime() noexcept
		{
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
			// iOS 15 may reject a second MAP_JIT mapping. Global trampolines and
			// the main LLVM/asmjit runtime therefore share jit_runtime's single
			// contiguous MAP_JIT arena.
			armsx3_ios_diagnostic_log("global jit runtime=shared arena");
#else
			ensure(m_pos.raw() = static_cast<uchar*>(utils::memory_reserve(size, true)));

			// Initialize "end" pointer
			m_max = m_pos + size;

			// Make memory writable + executable
			utils::memory_commit(m_pos, size, utils::protection::wx);
#endif
		}

		uchar* _alloc(usz size, usz align) noexcept override
		{
#if defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE
			return jit_runtime::alloc(size, align, true);
#else
			return m_pos.atomic_op([&](uchar*& pos) -> uchar*
			{
				const auto r = reinterpret_cast<uchar*>(utils::align(uptr(pos), align));

				if (r >= pos && r + size > pos && r + size <= m_max)
				{
					pos = r + size;
					return r;
				}

				return nullptr;
			});
#endif
		}

	private:
#if !(defined(__APPLE__) && defined(ARCH_ARM64) && TARGET_OS_IPHONE)
		atomic_t<uchar*> m_pos{};

		uchar* m_max{};
#endif
	};

	// Magic static
	static custom_runtime g_rt;
	return g_rt;
}

asmjit::inline_runtime::inline_runtime(uchar* data, usz size)
	: m_data(data)
	, m_size(size)
{
}

uchar* asmjit::inline_runtime::_alloc(usz size, usz align) noexcept
{
	ensure(align <= 4096);

	return size <= m_size ? m_data : nullptr;
}

asmjit::inline_runtime::~inline_runtime()
{
	utils::memory_protect(m_data, m_size, utils::protection::rx);
}

#if defined(ARCH_X64)
asmjit::simd_builder::simd_builder(CodeHolder* ch) noexcept
	: native_asm(ch)
{
	_init(0);
	consts[~v128()] = this->newLabel();
}

asmjit::simd_builder::~simd_builder()
{
}

void asmjit::simd_builder::_init(uint new_vsize)
{
	if ((!new_vsize && utils::has_avx512_icl()) || new_vsize == 64)
	{
		v0 = x86::zmm0;
		v1 = x86::zmm1;
		v2 = x86::zmm2;
		v3 = x86::zmm3;
		v4 = x86::zmm4;
		v5 = x86::zmm5;
		vsize = 64;
	}
	else if ((!new_vsize && utils::has_avx2()) || new_vsize == 32)
	{
		v0 = x86::ymm0;
		v1 = x86::ymm1;
		v2 = x86::ymm2;
		v3 = x86::ymm3;
		v4 = x86::ymm4;
		v5 = x86::ymm5;
		vsize = 32;
	}
	else
	{
		v0 = x86::xmm0;
		v1 = x86::xmm1;
		v2 = x86::xmm2;
		v3 = x86::xmm3;
		v4 = x86::xmm4;
		v5 = x86::xmm5;
		vsize = new_vsize ? new_vsize : 16;
	}

	if (utils::has_avx512())
	{
		if (!new_vsize)
			vmask = -1;
	}
	else
	{
		vmask = 0;
	}
}

void asmjit::simd_builder::operator()() noexcept
{
	for (auto&& [x, y] : consts)
	{
		this->align(AlignMode::kData, 16);
		this->bind(y);
		this->embed(&x, 16);
	}
}

void asmjit::simd_builder::vec_cleanup_ret()
{
	if (utils::has_avx() && vsize > 16)
		this->vzeroupper();
	this->ret();
}

void asmjit::simd_builder::vec_set_all_zeros(const Operand& v)
{
	x86::Xmm reg(v.id());
	if (utils::has_avx())
		this->vpxor(reg, reg, reg);
	else
		this->xorps(reg, reg);
}

void asmjit::simd_builder::vec_set_all_ones(const Operand& v)
{
	x86::Xmm reg(v.id());
	if (x86::Zmm zr(v.id()); zr == v)
		this->vpternlogd(zr, zr, zr, 0xff);
	else if (x86::Ymm yr(v.id()); yr == v)
		this->vpcmpeqd(yr, yr, yr);
	else if (utils::has_avx())
		this->vpcmpeqd(reg, reg, reg);
	else
		this->pcmpeqd(reg, reg);
}

void asmjit::simd_builder::vec_set_const(const Operand& v, const v128& val)
{
	if (!val._u)
		return vec_set_all_zeros(v);
	if (!~val._u)
		return vec_set_all_ones(v);
	else
	{
		Label co = consts[val];
		if (!co.isValid())
			co = consts[val] = this->newLabel();
		if (x86::Zmm zr(v.id()); zr == v)
			this->vbroadcasti32x4(zr, x86::oword_ptr(co));
		else if (x86::Ymm yr(v.id()); yr == v)
			this->vbroadcasti128(yr, x86::oword_ptr(co));
		else if (utils::has_avx())
			this->vmovaps(x86::Xmm(v.id()), x86::oword_ptr(co));
		else
			this->movaps(x86::Xmm(v.id()), x86::oword_ptr(co));
	}
}

void asmjit::simd_builder::vec_clobbering_test(u32 esize, const Operand& v, const Operand& rhs)
{
	if (esize == 64)
	{
		this->emit(x86::Inst::kIdVptestmd, x86::k0, v, rhs);
		this->ktestw(x86::k0, x86::k0);
	}
	else if (esize == 32)
	{
		this->emit(x86::Inst::kIdVptest, v, rhs);
	}
	else if (esize == 16 && utils::has_avx())
	{
		this->emit(x86::Inst::kIdVptest, v, rhs);
	}
	else if (esize == 16 && utils::has_sse41())
	{
		this->emit(x86::Inst::kIdPtest, v, rhs);
	}
	else
	{
		if (v != rhs)
			this->emit(x86::Inst::kIdPand, v, rhs);
		if (esize == 16)
			this->emit(x86::Inst::kIdPacksswb, v, v);
		this->emit(x86::Inst::kIdMovq, x86::rax, v);
		if (esize == 16 || esize == 8)
			this->test(x86::rax, x86::rax);
		else if (esize == 4)
			this->test(x86::eax, x86::eax);
		else if (esize == 2)
			this->test(x86::ax, x86::ax);
		else if (esize == 1)
			this->test(x86::al, x86::al);
		else
			fmt::throw_exception("Unimplemented");
	}
}

void asmjit::simd_builder::vec_broadcast_gpr(u32 esize, const Operand& v, const x86::Gp& r)
{
	if (esize == 2)
	{
		if (utils::has_avx512())
			this->emit(x86::Inst::kIdVpbroadcastw, v, r.r32());
		else if (utils::has_avx())
		{
			this->emit(x86::Inst::kIdVmovd, v, r.r32());
			if (utils::has_avx2())
				this->emit(x86::Inst::kIdVpbroadcastw, v, v);
			else
			{
				this->emit(x86::Inst::kIdVpunpcklwd, v, v, v);
				this->emit(x86::Inst::kIdVpshufd, v, v, Imm(0));
			}
		}
		else
		{
			this->emit(x86::Inst::kIdMovd, v, r.r32());
			this->emit(x86::Inst::kIdPunpcklwd, v, v);
			this->emit(x86::Inst::kIdPshufd, v, v, Imm(0));
		}
	}
	else if (esize == 4)
	{
		if (utils::has_avx512())
			this->emit(x86::Inst::kIdVpbroadcastd, v, r.r32());
		else if (utils::has_avx())
		{
			this->emit(x86::Inst::kIdVmovd, v, r.r32());
			if (utils::has_avx2())
				this->emit(x86::Inst::kIdVpbroadcastd, v, v);
			else
				this->emit(x86::Inst::kIdVpshufd, v, v, Imm(0));
		}
		else
		{
			this->emit(x86::Inst::kIdMovd, v, r.r32());
			this->emit(x86::Inst::kIdPshufd, v, v, Imm(0));
		}
	}
	else
	{
		fmt::throw_exception("Unimplemented");
	}
}

asmjit::x86::Mem asmjit::simd_builder::ptr_scale_for_vec(u32 esize, const x86::Gp& base, const x86::Gp& index)
{
	switch (ensure(esize))
	{
	case 1: return x86::ptr(base, index, 0, 0);
	case 2: return x86::ptr(base, index, 1, 0);
	case 4: return x86::ptr(base, index, 2, 0);
	case 8: return x86::ptr(base, index, 3, 0);
	default: fmt::throw_exception("Bad esize");
	}
}

void asmjit::simd_builder::vec_load_unaligned(u32 esize, const Operand& v, const x86::Mem& src)
{
	ensure(std::has_single_bit(esize));
	ensure(std::has_single_bit(vsize));

	if (esize == 2)
	{
		ensure(vsize >= 2);
		if (vsize == 2)
			vec_set_all_zeros(v);
		if (vsize == 2 && utils::has_avx())
			this->emit(x86::Inst::kIdVpinsrw, x86::Xmm(v.id()), x86::Xmm(v.id()), src, Imm(0));
		else if (vsize == 2)
			this->emit(x86::Inst::kIdPinsrw, v, src, Imm(0));
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu16, v, src);
		else
			return vec_load_unaligned(vsize, v, src);
	}
	else if (esize == 4)
	{
		ensure(vsize >= 4);
		if (vsize == 4 && utils::has_avx())
			this->emit(x86::Inst::kIdVmovd, x86::Xmm(v.id()), src);
		else if (vsize == 4)
			this->emit(x86::Inst::kIdMovd, v, src);
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu32, v, src);
		else
			return vec_load_unaligned(vsize, v, src);
	}
	else if (esize == 8)
	{
		ensure(vsize >= 8);
		if (vsize == 8 && utils::has_avx())
			this->emit(x86::Inst::kIdVmovq, x86::Xmm(v.id()), src);
		else if (vsize == 8)
			this->emit(x86::Inst::kIdMovq, v, src);
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu64, v, src);
		else
			return vec_load_unaligned(vsize, v, src);
	}
	else if (esize >= 16)
	{
		ensure(vsize >= 16);
		if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu64, v, src); // Not really needed
		else if (utils::has_avx())
			this->emit(x86::Inst::kIdVmovdqu, v, src);
		else
			this->emit(x86::Inst::kIdMovups, v, src);
	}
	else
	{
		fmt::throw_exception("Unimplemented");
	}
}

void asmjit::simd_builder::vec_store_unaligned(u32 esize, const Operand& v, const x86::Mem& dst)
{
	ensure(std::has_single_bit(esize));
	ensure(std::has_single_bit(vsize));

	if (esize == 2)
	{
		ensure(vsize >= 2);
		if (vsize == 2 && utils::has_avx())
			this->emit(x86::Inst::kIdVpextrw, dst, x86::Xmm(v.id()), Imm(0));
		else if (vsize == 2 && utils::has_sse41())
			this->emit(x86::Inst::kIdPextrw, dst, v, Imm(0));
		else if (vsize == 2)
			this->push(x86::rax), this->pextrw(x86::eax, x86::Xmm(v.id()), 0), this->mov(dst, x86::ax), this->pop(x86::rax);
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu16, dst, v);
		else
			return vec_store_unaligned(vsize, v, dst);
	}
	else if (esize == 4)
	{
		ensure(vsize >= 4);
		if (vsize == 4 && utils::has_avx())
			this->emit(x86::Inst::kIdVmovd, dst, x86::Xmm(v.id()));
		else if (vsize == 4)
			this->emit(x86::Inst::kIdMovd, dst, v);
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu32, dst, v);
		else
			return vec_store_unaligned(vsize, v, dst);
	}
	else if (esize == 8)
	{
		ensure(vsize >= 8);
		if (vsize == 8 && utils::has_avx())
			this->emit(x86::Inst::kIdVmovq, dst, x86::Xmm(v.id()));
		else if (vsize == 8)
			this->emit(x86::Inst::kIdMovq, dst, v);
		else if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu64, dst, v);
		else
			return vec_store_unaligned(vsize, v, dst);
	}
	else if (esize >= 16)
	{
		ensure(vsize >= 16);
		if ((vmask && vmask < 8) || vsize >= 64)
			this->emit(x86::Inst::kIdVmovdqu64, dst, v); // Not really needed
		else if (utils::has_avx())
			this->emit(x86::Inst::kIdVmovdqu, dst, v);
		else
			this->emit(x86::Inst::kIdMovups, dst, v);
	}
	else
	{
		fmt::throw_exception("Unimplemented");
	}
}

void asmjit::simd_builder::_vec_binary_op(x86::Inst::Id sse_op, x86::Inst::Id vex_op, x86::Inst::Id evex_op, const Operand& dst, const Operand& lhs, const Operand& rhs)
{
	if (utils::has_avx())
	{
		if (evex_op != x86::Inst::kIdNone && (vex_op == x86::Inst::kIdNone || this->_extraReg.isReg() || vsize >= 64))
		{
			this->evex().emit(evex_op, dst, lhs, rhs);
		}
		else
		{
			this->emit(vex_op, dst, lhs, rhs);
		}
	}
	else if (dst == lhs)
	{
		this->emit(sse_op, dst, rhs);
	}
	else if (dst == rhs)
	{
		fmt::throw_exception("Unimplemented");
	}
	else
	{
		this->emit(x86::Inst::kIdMovaps, dst, lhs);
		this->emit(sse_op, dst, rhs);
	}
}

void asmjit::simd_builder::vec_umin(u32 esize, const Operand& dst, const Operand& lhs, const Operand& rhs)
{
	using enum x86::Inst::Id;
	if (esize == 2)
	{
		if (utils::has_sse41())
			return _vec_binary_op(kIdPminuw, kIdVpminuw, kIdVpminuw, dst, lhs, rhs);
	}
	else if (esize == 4)
	{
		if (utils::has_sse41())
			return _vec_binary_op(kIdPminud, kIdVpminud, kIdVpminud, dst, lhs, rhs);
	}

	fmt::throw_exception("Unimplemented");
}

void asmjit::simd_builder::vec_umax(u32 esize, const Operand& dst, const Operand& lhs, const Operand& rhs)
{
	using enum x86::Inst::Id;
	if (esize == 2)
	{
		if (utils::has_sse41())
			return _vec_binary_op(kIdPmaxuw, kIdVpmaxuw, kIdVpmaxuw, dst, lhs, rhs);
	}
	else if (esize == 4)
	{
		if (utils::has_sse41())
			return _vec_binary_op(kIdPmaxud, kIdVpmaxud, kIdVpmaxud, dst, lhs, rhs);
	}

	fmt::throw_exception("Unimplemented");
}

void asmjit::simd_builder::vec_cmp_eq(u32 esize, const Operand& dst, const Operand& lhs, const Operand& rhs)
{
	using enum x86::Inst::Id;
	if (esize == 2)
	{
		if (vsize == 64)
		{
			this->evex().emit(kIdVpcmpeqw, x86::k0, lhs, rhs);
			this->evex().emit(kIdVpmovm2w, dst, x86::k0);
		}
		else
		{
			_vec_binary_op(kIdPcmpeqw, kIdVpcmpeqw, kIdNone, dst, lhs, rhs);
		}
	}
	else if (esize == 4)
	{
		if (vsize == 64)
		{
			this->evex().emit(kIdVpcmpeqd, x86::k0, lhs, rhs);
			this->evex().emit(kIdVpmovm2d, dst, x86::k0);
		}
		else
		{
			_vec_binary_op(kIdPcmpeqd, kIdVpcmpeqd, kIdNone, dst, lhs, rhs);
		}
	}
	else
	{
		fmt::throw_exception("Unimplemented");
	}
}

void asmjit::simd_builder::vec_extract_high(u32, const Operand& dst, const Operand& src)
{
	if (vsize == 32)
		this->vextracti32x8(x86::Ymm(dst.id()), x86::Zmm(src.id()), 1);
	else if (vsize == 16)
		this->vextracti128(x86::Xmm(dst.id()), x86::Ymm(src.id()), 1);
	else
	{
		if (utils::has_avx())
			this->vpsrldq(x86::Xmm(dst.id()), x86::Xmm(src.id()), vsize);
		else
		{
			this->movdqa(x86::Xmm(dst.id()), x86::Xmm(src.id()));
			this->psrldq(x86::Xmm(dst.id()), vsize);
		}
	}
}

void asmjit::simd_builder::vec_extract_gpr(u32 esize, const x86::Gp& dst, const Operand& src)
{
	if (esize == 8 && utils::has_avx())
		this->vmovq(dst.r64(), x86::Xmm(src.id()));
	else if (esize == 8)
		this->movq(dst.r64(), x86::Xmm(src.id()));
	else if (esize == 4 && utils::has_avx())
		this->vmovd(dst.r32(), x86::Xmm(src.id()));
	else if (esize == 4)
		this->movd(dst.r32(), x86::Xmm(src.id()));
	else if (esize == 2 && utils::has_avx())
		this->vpextrw(dst.r32(), x86::Xmm(src.id()), 0);
	else if (esize == 2)
		this->pextrw(dst.r32(), x86::Xmm(src.id()), 0);
	else
		fmt::throw_exception("Unimplemented");
}

#endif /* X86 */
