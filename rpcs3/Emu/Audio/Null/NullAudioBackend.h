#pragma once

#include "Emu/Audio/AudioBackend.h"

class NullAudioBackend final : public AudioBackend
{
public:
	NullAudioBackend() {}
	~NullAudioBackend() {}

	std::string_view GetName() const override { return "Null"sv; }

	bool Open(std::string_view /* dev_id */, AudioFreq freq, AudioSampleSize sample_size, AudioChannelCnt ch_cnt, audio_channel_layout layout) override
	{
		Close();

		// A null backend still participates in the mixer. Keep the same format/layout
		// invariants as a real backend instead of leaving AudioBackend's default
		// `automatic` layout behind. The latter eventually reaches downmix(), where 0 is
		// not a concrete channel layout and used to terminate cellAudio during shutdown.
		m_sampling_rate = freq;
		m_sample_size = sample_size;
		m_channels = static_cast<u32>(ch_cnt);
		m_layout = layout == audio_channel_layout::automatic ? default_layout(m_channels) : layout;

		if (default_layout_channel_count(m_layout) > m_channels)
		{
			m_layout = default_layout(m_channels);
		}

		m_channels = layout_channel_count(m_channels, m_layout);
		return true;
	}
	void Close() override { m_playing = false; }

	f64 GetCallbackFrameLen() override { return 0.01; };

	void Play() override { m_playing = true; }
	void Pause() override { m_playing = false; }
	bool IsPlaying() override { return m_playing; }

private:
	bool m_playing = false;
};
