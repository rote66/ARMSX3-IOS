#pragma once

#include <util/types.hpp>
#include <source_location>
#include "../RSXThread.h"

namespace rsx
{
	class eng_lock
	{
		rsx::thread* pthr;

	public:
		eng_lock(rsx::thread* target, std::source_location loc = std::source_location::current())
			:pthr(target)
		{
			if (pthr->is_current_thread())
			{
				pthr = nullptr;
			}
			else
			{
				pthr->pause(loc.line());
			}
		}

		~eng_lock()
		{
			if (pthr) pthr->unpause();
		}
	};
}
