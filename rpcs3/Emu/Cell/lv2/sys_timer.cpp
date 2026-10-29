#include "stdafx.h"
#include "sys_timer.h"

#include "Emu/IdManager.h"
#include "Emu/Cell/ErrorCodes.h"
#include "Emu/Cell/PPUThread.h"
#include "Emu/Cell/timers.hpp"

#include "util/asm.hpp"
#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/RSX/rsx_profiler.h"
#include "Emu/RSX/gcm_printing.h"
#include "Emu/RSX/RSXThread.h"
#include "sys_event.h"
#include "sys_process.h"

#include <thread>
#include <deque>

LOG_CHANNEL(sys_timer);

#ifdef ARMSX3_IOS
extern atomic_t<u64> g_rsx_ev_attempt;
extern atomic_t<u64> g_rsx_ev_dropped;
extern atomic_t<u64> g_rsx_ev_busy_spin;
extern atomic_t<u64> g_rsx_ev_again;
extern atomic_t<u32> g_rsx_q_id;
extern atomic_t<u32> g_rsx_q_pending;
extern atomic_t<u32> g_rsx_q_waiter;
extern atomic_t<u32> g_rsx_queue103_phase;
extern atomic_t<u64> g_rsx_queue103_started_us;
extern atomic_t<u64> g_rsx_queue103_seq;
extern atomic_t<u64> g_rsx_queue103_last_us;

namespace
{
	template <usz N>
	void ios_nfsmw_copy_dwords(std::array<u32, N>& out, u32 address)
	{
		out.fill(0);

		std::array<be_t<u32>, N> raw{};
		if (!vm::try_access(address, raw.data(), sizeof(raw), false))
		{
			return;
		}

		for (usz i = 0; i < N; i++)
		{
			out[i] = raw[i];
		}
	}

	template <usz N>
	void ios_nfsmw_append_dwords(std::string& out, const char* name, const std::array<u32, N>& words)
	{
		fmt::append(out, "%s=[", name);
		for (usz i = 0; i < N; i++)
		{
			fmt::append(out, "%s%08x", i ? "," : "", words[i]);
		}
		out += "]";
	}

	std::string ios_nfsmw_fifo_method_tail()
	{
		constexpr u32 keep = 24;
		const u32 end = rsx::prof::g_fifo_ring_pos;
		const u32 begin = end > keep ? end - keep : 0;
		std::string out;

		for (u32 i = begin; i < end; i++)
		{
			const auto& r = rsx::prof::g_fifo_ring[i % rsx::prof::fifo_ring_size];
			if (!r.reg && !r.arg)
			{
				continue;
			}

			std::string scratch;
			const auto name = rsx::get_method_name(r.reg, scratch);
			fmt::append(out, "%s%04x:%s%s=%08x", out.empty() ? "" : " | ",
				r.reg << 2, name.first, name.second, r.arg);
		}

		return out;
	}
}
#endif

struct lv2_timer_thread
{
	shared_mutex mutex;
	std::deque<shared_ptr<lv2_timer>> timers;

	lv2_timer_thread();
	void operator()();

	//SAVESTATE_INIT_POS(46); // FREE SAVESTATE_INIT_POS number

	static constexpr auto thread_name = "Timer Thread"sv;
};

lv2_timer::lv2_timer(utils::serial& ar)
	: lv2_obj(1)
	, state(ar.pop<u32>())
	, port(lv2_event_queue::load_ptr(ar, port, "timer"))
	, source(ar)
	, data1(ar)
	, data2(ar)
	, expire(ar.pop<u64>())
	, period(ar.pop<u64>())
{
}

void lv2_timer::save(utils::serial& ar)
{
	USING_SERIALIZATION_VERSION(lv2_sync);
	ar(state), lv2_event_queue::save_ptr(ar, port.get()), ar(source, data1, data2, expire, period);
}

u64 lv2_timer::check(u64 _now) noexcept
{
	while (true)
	{
		const u32 _state = +state;

		if (_state == SYS_TIMER_STATE_RUN)
		{
			u64 next = expire;

			// If aborting, perform the last accurate check for event
			if (_now >= next)
			{
				lv2_obj::notify_all_t notify;

				std::lock_guard lock(mutex);
				return check_unlocked(_now);
			}

			return (next - _now);
		}

		break;
	}

	return umax;
}

u64 lv2_timer::check_unlocked(u64 _now) noexcept
{
	const u64 next = expire;

	if (_now < next || state != SYS_TIMER_STATE_RUN)
	{
		return umax;
	}

	if (port)
	{
		port->send(source, data1, data2, next);
	}

	if (period)
	{
		// Set next expiration time and check again
		const u64 expire0 = utils::add_saturate<u64>(next, period);
		expire.release(expire0);
		return utils::sub_saturate<u64>(expire0, _now);
	}

	// Stop after oneshot
	state.release(SYS_TIMER_STATE_STOP);
	return umax;
}

lv2_timer_thread::lv2_timer_thread()
{
	Emu.PostponeInitCode([this]()
	{
		idm::select<lv2_obj, lv2_timer>([&](u32 id, lv2_timer&)
		{
			timers.emplace_back(idm::get_unlocked<lv2_obj, lv2_timer>(id));
		});
	});
}

void lv2_timer_thread::operator()()
{
	u64 sleep_time = 0;

	while (true)
	{
		if (sleep_time != umax)
		{
			// Scale time
			sleep_time = std::min(sleep_time, u64{umax} / 100) * 100 / g_cfg.core.clocks_scale;
		}

		thread_ctrl::wait_for(sleep_time);

		if (thread_ctrl::state() == thread_state::aborting)
		{
			break;
		}

		sleep_time = umax;

		if (Emu.IsPausedOrReady())
		{
			sleep_time = 10000;
			continue;
		}

		const u64 _now = get_guest_system_time();

		reader_lock lock(mutex);

		for (const auto& timer : timers)
		{
			while (lv2_obj::check(timer))
			{
				if (thread_ctrl::state() == thread_state::aborting)
				{
					break;
				}

				if (const u64 advised_sleep_time = timer->check(_now))
				{
					if (sleep_time > advised_sleep_time)
					{
						sleep_time = advised_sleep_time;
					}

					break;
				}
			}
		}
	}
}

error_code sys_timer_create(ppu_thread& ppu, vm::ptr<u32> timer_id)
{
	ppu.state += cpu_flag::wait;

	sys_timer.warning("sys_timer_create(timer_id=*0x%x)", timer_id);

	if (auto ptr = idm::make_ptr<lv2_obj, lv2_timer>())
	{
		auto& thread = g_fxo->get<named_thread<lv2_timer_thread>>();
		{
			std::lock_guard lock(thread.mutex);

			// Theoretically could have been destroyed by sys_timer_destroy by now
			if (auto it = std::find(thread.timers.begin(), thread.timers.end(), ptr); it == thread.timers.end())
			{
				thread.timers.emplace_back(std::move(ptr));
			}
		}

		ppu.check_state();
		*timer_id = idm::last_id();
		return CELL_OK;
	}

	return CELL_EAGAIN;
}

error_code sys_timer_destroy(ppu_thread& ppu, u32 timer_id)
{
	ppu.state += cpu_flag::wait;

	sys_timer.warning("sys_timer_destroy(timer_id=0x%x)", timer_id);

	auto timer = idm::withdraw<lv2_obj, lv2_timer>(timer_id, [&](lv2_timer& timer) -> CellError
	{
		if (reader_lock lock(timer.mutex); lv2_obj::check(timer.port))
		{
			return CELL_EISCONN;
		}

		timer.exists--;
		return {};
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	if (timer.ret)
	{
		return timer.ret;
	}

	auto& thread = g_fxo->get<named_thread<lv2_timer_thread>>();
	std::lock_guard lock(thread.mutex);

	if (auto it = std::find(thread.timers.begin(), thread.timers.end(), timer.ptr); it != thread.timers.end())
	{
		thread.timers.erase(it);
	}

	return CELL_OK;
}

error_code sys_timer_get_information(ppu_thread& ppu, u32 timer_id, vm::ptr<sys_timer_information_t> info)
{
	ppu.state += cpu_flag::wait;

	sys_timer.trace("sys_timer_get_information(timer_id=0x%x, info=*0x%x)", timer_id, info);

	sys_timer_information_t _info{};
	const u64 now = get_guest_system_time();

	const auto timer = idm::check<lv2_obj, lv2_timer>(timer_id, [&](lv2_timer& timer)
	{
		std::lock_guard lock(timer.mutex);

		timer.check_unlocked(now);
		timer.get_information(_info);
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	ppu.check_state();
	std::memcpy(info.get_ptr(), &_info, info.size());
	return CELL_OK;
}

error_code _sys_timer_start(ppu_thread& ppu, u32 timer_id, u64 base_time, u64 period)
{
	ppu.state += cpu_flag::wait;

	(period ? sys_timer.warning : sys_timer.trace)("_sys_timer_start(timer_id=0x%x, base_time=0x%llx, period=0x%llx)", timer_id, base_time, period);

	const u64 start_time = get_guest_system_time();

	if (period && period < 100)
	{
		// Invalid periodic timer
		return CELL_EINVAL;
	}

	const auto timer = idm::check<lv2_obj, lv2_timer>(timer_id, [&](lv2_timer& timer) -> CellError
	{
		std::lock_guard lock(timer.mutex);

		// LV2 Disassembly: Simple nullptr check (assignment test, do not use lv2_obj::check here)
		if (!timer.port)
		{
			return CELL_ENOTCONN;
		}

		timer.check_unlocked(start_time);
		if (timer.state != SYS_TIMER_STATE_STOP)
		{
			return CELL_EBUSY;
		}

		if (!period && start_time >= base_time)
		{
			// Invalid oneshot
			return CELL_ETIMEDOUT;
		}

		const u64 expire = period == 0 ? base_time : // oneshot
			base_time == 0 ? utils::add_saturate(start_time, period) : // periodic timer with no base (using start time as base)
			start_time < utils::add_saturate(base_time, period) ? utils::add_saturate(base_time, period) : // periodic with base time over start time
			[&]() -> u64 // periodic timer base before start time (align to be at least a period over start time)
			{
				// Optimized from a loop in LV2:
				// do
				// {
				// 	  base_time += period;
				// }
				// while (base_time < start_time);

				const u64 start_time_with_base_time_reminder = utils::add_saturate(start_time - start_time % period, base_time % period);

				return utils::add_saturate(start_time_with_base_time_reminder, start_time_with_base_time_reminder < start_time ? period : 0);
			}();

		timer.expire = expire;
		timer.period = period;
		timer.state  = SYS_TIMER_STATE_RUN;
		return {};
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	if (timer.ret)
	{
		if (timer.ret == CELL_ETIMEDOUT)
		{
			return not_an_error(timer.ret);
		}

		return timer.ret;
	}

	g_fxo->get<named_thread<lv2_timer_thread>>()([]{});

	return CELL_OK;
}

error_code sys_timer_stop(ppu_thread& ppu, u32 timer_id)
{
	ppu.state += cpu_flag::wait;

	sys_timer.trace("sys_timer_stop()");

	const auto timer = idm::check<lv2_obj, lv2_timer>(timer_id, [now = get_guest_system_time(), notify = lv2_obj::notify_all_t()](lv2_timer& timer)
	{
		std::lock_guard lock(timer.mutex);
		timer.check_unlocked(now);
		timer.state = SYS_TIMER_STATE_STOP;
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	return CELL_OK;
}

error_code sys_timer_connect_event_queue(ppu_thread& ppu, u32 timer_id, u32 queue_id, u64 name, u64 data1, u64 data2)
{
	ppu.state += cpu_flag::wait;

	sys_timer.warning("sys_timer_connect_event_queue(timer_id=0x%x, queue_id=0x%x, name=0x%llx, data1=0x%llx, data2=0x%llx)", timer_id, queue_id, name, data1, data2);

	const auto timer = idm::check<lv2_obj, lv2_timer>(timer_id, [&](lv2_timer& timer) -> CellError
	{
		auto found = idm::get_unlocked<lv2_obj, lv2_event_queue>(queue_id);

		if (!found)
		{
			return CELL_ESRCH;
		}

		std::lock_guard lock(timer.mutex);

		if (lv2_obj::check(timer.port))
		{
			return CELL_EISCONN;
		}

		// Connect event queue
		timer.port   = found;
		timer.source = name ? name : (u64{process_getpid() + 0u} << 32) | u64{timer_id};
		timer.data1  = data1;
		timer.data2  = data2;
		return {};
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	if (timer.ret)
	{
		return timer.ret;
	}

	return CELL_OK;
}

error_code sys_timer_disconnect_event_queue(ppu_thread& ppu, u32 timer_id)
{
	ppu.state += cpu_flag::wait;

	sys_timer.warning("sys_timer_disconnect_event_queue(timer_id=0x%x)", timer_id);

	const auto timer = idm::check<lv2_obj, lv2_timer>(timer_id, [now = get_guest_system_time(), notify = lv2_obj::notify_all_t()](lv2_timer& timer) -> CellError
	{
		std::lock_guard lock(timer.mutex);

		timer.check_unlocked(now);
		timer.state = SYS_TIMER_STATE_STOP;

		if (!lv2_obj::check(timer.port))
		{
			return CELL_ENOTCONN;
		}

		timer.port.reset();
		return {};
	});

	if (!timer)
	{
		return CELL_ESRCH;
	}

	if (timer.ret)
	{
		return timer.ret;
	}

	return CELL_OK;
}

error_code sys_timer_sleep(ppu_thread& ppu, u32 sleep_time)
{
	ppu.state += cpu_flag::wait;

	sys_timer.trace("sys_timer_sleep(sleep_time=%d)", sleep_time);

	return sys_timer_usleep(ppu, sleep_time * u64{1000000});
}

// See ppu_watch_arm in PPUThread.cpp. A guest poll loop sleeps between reads, so this is where
// the address it is polling passes through kernel code, and the only place it can be picked up
// without a hook in the interpreter's load path.
extern void ppu_watch_arm(const ppu_thread& ppu);

error_code sys_timer_usleep(ppu_thread& ppu, u64 sleep_time)
{
	ppu.state += cpu_flag::wait;

	sys_timer.trace("sys_timer_usleep(sleep_time=0x%llx)", sleep_time);

	ppu_watch_arm(ppu);

#ifdef ARMSX3_IOS
	// NFSMW debug's long-standing render stall waits in exactly this guest loop while
	// a GCM completion value is one generation behind. The broad pre-upstream probes
	// were intentionally not restored after rebasing. This is the final Build 84 probe
	// only: after an unchanged pair has persisted for one second, snapshot the fixed
	// double-buffered FIFO window plus the method ring that already exists in the RSX
	// profiler. No extra logging or guest-memory reads occur on normal short waits.
	if (ppu.cia == 0x00f71938 && ppu.lr == 0x00f71900 && sleep_time == 0x1e) [[unlikely]]
	{
		// Arm the existing RSX profiler as soon as NFSMW enters its FinishEntry poll, not
		// one second later when the persistent snapshot fires. The request is only a flag;
		// RSX itself consumes it and binds the profiler on its own thread. That leaves enough
		// lead time to classify a later multi-second render stall without globally enabling
		// profiling for other games.
		rsx::prof::request_forced_enable();

		const u32 target = static_cast<u32>(ppu.gpr[4]);
		const u32 done = static_cast<u32>(ppu.gpr[5]);
		const u64 pair = (u64{target} << 32) | done;
		const u64 now = get_system_time();
		static u64 s_last_pair = umax;
		static u64 s_pair_since_us = 0;
		static u64 s_last_seen_us = 0;
		static u64 s_logged_pair = umax;

		const bool new_episode = !s_last_seen_us || now < s_last_seen_us || now - s_last_seen_us > 100000;
		s_last_seen_us = now;

		if (new_episode || s_last_pair != pair)
		{
			s_last_pair = pair;
			s_pair_since_us = now;
			s_logged_pair = umax;
		}

		if (s_logged_pair != pair && s_pair_since_us && now >= s_pair_since_us &&
			now - s_pair_since_us >= 1000000)
		{
			s_logged_pair = pair;

			std::array<u32, 8> fifo_a{};
			std::array<u32, 8> fifo_b{};
			std::array<u32, 4> gcm_ctrl{};
			std::array<u32, 16> fifo_ring70{};
			std::array<u32, 36> fifo_b_pre{};
			std::array<u32, 24> fifo_low_180{};
			ios_nfsmw_copy_dwords(fifo_a, 0x30101064);
			ios_nfsmw_copy_dwords(fifo_b, 0x30500864);
			ios_nfsmw_copy_dwords(gcm_ctrl, 0x40100040);
			ios_nfsmw_copy_dwords(fifo_ring70, 0x30100070);
			ios_nfsmw_copy_dwords(fifo_b_pre, 0x305007e0);
			ios_nfsmw_copy_dwords(fifo_low_180, 0x30100180);

			std::string probe;
			ios_nfsmw_append_dwords(probe, "A", fifo_a);
			probe += " ";
			ios_nfsmw_append_dwords(probe, "B", fifo_b);
			probe += " ";
			ios_nfsmw_append_dwords(probe, "ctrl", gcm_ctrl);
			probe += " ";
			ios_nfsmw_append_dwords(probe, "ring70", fifo_ring70);
			probe += " ";
			ios_nfsmw_append_dwords(probe, "Bpre7e0", fifo_b_pre);
			probe += " ";
			ios_nfsmw_append_dwords(probe, "Low180", fifo_low_180);

			const std::string methods = ios_nfsmw_fifo_method_tail();
			std::string fifo_debug = "<no-rsx>";
			u32 device_400 = 0;
			u32 device_030 = 0;
			u32 label_400 = 0;
			u32 label_030 = 0;

			if (auto* rsx = rsx::get_current_renderer())
			{
				if (rsx->fifo_ctrl)
				{
					fifo_debug = rsx->fifo_ctrl->debug_snapshot();
				}

				if (rsx->device_addr)
				{
					device_400 = vm::read32(rsx->device_addr + 0x400);
					device_030 = vm::read32(rsx->device_addr + 0x30);
				}

				if (rsx->label_addr)
				{
					label_400 = vm::read32(rsx->label_addr + 0x400);
					label_030 = vm::read32(rsx->label_addr + 0x30);
				}
			}

			const u32 queue103_phase = +g_rsx_queue103_phase;
			const u64 queue103_started = +g_rsx_queue103_started_us;
			const u64 queue103_active_us = queue103_phase && queue103_started && now >= queue103_started
				? now - queue103_started : 0;

			u32 ext_lock = 0;
			u32 ext_ack = 0;
			u32 ext_site = 0;
			u64 ext_active_us = 0;
			if (const auto rsx = rsx::get_current_renderer())
			{
				ext_lock = +rsx->external_interrupt_lock;
				ext_ack = +rsx->external_interrupt_ack;
				ext_site = +rsx->external_interrupt_site;
				const u64 ext_started = +rsx->external_interrupt_since_us;
				ext_active_us = ext_lock && ext_started && now >= ext_started ? now - ext_started : 0;
			}

			sys_timer.error(
				"iOS NFSMW FinishEntry persistent wait: target=%u done=%u delta=%u wait_ms=%llu r30=0x%llx r31=0x%llx producer_probe=[%s] fifo_methods=[%s] fifo_debug=[%s] sema=[dev400=%08x dev030=%08x label400=%08x label030=%08x] queue103=[phase=%u seq=%llu active_us=%llu last_us=%llu] rsxev=[attempt=%llu dropped=%llu busy=%llu again=%llu q=0x%x pending=%u waiter=%u] extpause=[lock=%u ack=%u site=%u active_us=%llu]",
				target, done, target - done, (now - s_pair_since_us) / 1000,
				ppu.gpr[30], ppu.gpr[31], probe, methods, fifo_debug,
				device_400, device_030, label_400, label_030,
				queue103_phase, +g_rsx_queue103_seq, queue103_active_us, +g_rsx_queue103_last_us,
				+g_rsx_ev_attempt, +g_rsx_ev_dropped, +g_rsx_ev_busy_spin, +g_rsx_ev_again,
				+g_rsx_q_id, +g_rsx_q_pending, +g_rsx_q_waiter,
				ext_lock, ext_ack, ext_site, ext_active_us);
		}
	}
#endif

	if (sleep_time)
	{
		const s64 add_time = g_cfg.core.usleep_addend;

		// Over/underflow checks
		if (add_time >= 0)
		{
			sleep_time = utils::add_saturate<u64>(sleep_time, add_time);
		}
		else
		{
			sleep_time = std::max<u64>(1, utils::sub_saturate<u64>(sleep_time, -add_time));
		}

		lv2_obj::sleep(ppu, g_cfg.core.sleep_timers_accuracy < sleep_timers_accuracy_level::_usleep ? sleep_time : 0);

		if (!lv2_obj::wait_timeout(sleep_time, &ppu, true, true))
		{
			ppu.state += cpu_flag::again;
		}
	}
	else
	{
		std::this_thread::yield();
	}

	return CELL_OK;
}
