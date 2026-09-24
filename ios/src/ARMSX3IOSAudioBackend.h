#pragma once

#include "Emu/Audio/AudioBackend.h"

#include <AudioUnit/AudioUnit.h>
#include <array>
#include <atomic>

class ARMSX3IOSAudioBackend final : public AudioBackend
{
public:
	ARMSX3IOSAudioBackend();
	~ARMSX3IOSAudioBackend() override;

	ARMSX3IOSAudioBackend(const ARMSX3IOSAudioBackend&) = delete;
	ARMSX3IOSAudioBackend& operator=(const ARMSX3IOSAudioBackend&) = delete;

	std::string_view GetName() const override { return std::string_view{"iOS Audio"}; }
	bool Initialized() override { return true; }
	bool Operational() override { return m_unit != nullptr; }

	bool Open(std::string_view dev_id, AudioFreq freq, AudioSampleSize sample_size,
		AudioChannelCnt ch_cnt, audio_channel_layout layout) override;
	void Close() override;

	f64 GetCallbackFrameLen() override;
	void Play() override;
	void Pause() override;

private:
	static OSStatus render_callback(void* ref_con, AudioUnitRenderActionFlags* flags,
		const AudioTimeStamp* timestamp, UInt32 bus_number, UInt32 frame_count,
		AudioBufferList* io_data);
	OSStatus render(UInt32 frame_count, AudioBufferList* io_data);

	AudioUnit m_unit = nullptr;
	std::array<u8, sizeof(f32) * static_cast<u32>(AudioChannelCnt::SURROUND_7_1)> m_last_frame{};
	std::array<u8, 4096 * sizeof(f32) * 2> m_render_buffer{};
	u32 m_bytes_per_frame = 0;
	bool m_started = false;
	std::atomic<bool> m_first_render_logged{false};
	std::atomic<bool> m_first_signal_logged{false};
};

