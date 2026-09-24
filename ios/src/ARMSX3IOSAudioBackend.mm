#include "ARMSX3IOSAudioBackend.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <chrono>
#include <cstring>

LOG_CHANNEL(IOSAudio, "iOS Audio");

ARMSX3IOSAudioBackend::ARMSX3IOSAudioBackend()
	: AudioBackend()
{
}

ARMSX3IOSAudioBackend::~ARMSX3IOSAudioBackend()
{
	Close();
}

bool ARMSX3IOSAudioBackend::Open(std::string_view, AudioFreq freq, AudioSampleSize sample_size,
	AudioChannelCnt ch_cnt, audio_channel_layout layout)
{
	Close();

	AVAudioSession* session = AVAudioSession.sharedInstance;
	NSError* session_error = nil;
	if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&session_error])
	{
		IOSAudio.error("AVAudioSession setCategory failed: %s", session_error.localizedDescription.UTF8String ?: "unknown");
	}
	session_error = nil;
	[session setPreferredSampleRate:static_cast<double>(freq) error:&session_error];
	if (session_error)
		IOSAudio.warning("AVAudioSession preferred sample rate failed: %s", session_error.localizedDescription.UTF8String ?: "unknown");
	session_error = nil;
	[session setPreferredIOBufferDuration:0.010 error:&session_error];
	if (session_error)
		IOSAudio.warning("AVAudioSession preferred buffer duration failed: %s", session_error.localizedDescription.UTF8String ?: "unknown");
	session_error = nil;
	if (![session setActive:YES error:&session_error])
	{
		IOSAudio.error("AVAudioSession activation failed: %s", session_error.localizedDescription.UTF8String ?: "unknown");
		return false;
	}

	// iPhone/iPad system output is exposed to the app as stereo. RPCS3's mixer owns
	// surround -> stereo downmixing, so advertise two output channels here rather than
	// relying on RemoteIO to reinterpret a 5.1/7.1 interleaved stream.
	constexpr u32 output_channels = 2;
	m_sampling_rate = freq;
	m_sample_size = sample_size;
	setup_channel_layout(static_cast<u32>(ch_cnt), output_channels, layout, IOSAudio);
	m_bytes_per_frame = get_channels() * get_sample_size();
	if (!m_bytes_per_frame)
	{
		IOSAudio.error("Invalid frame size");
		return false;
	}

	AudioComponentDescription desc{};
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;

	AudioComponent component = AudioComponentFindNext(nullptr, &desc);
	if (!component)
	{
		IOSAudio.error("RemoteIO AudioComponent was not found");
		return false;
	}

	OSStatus status = AudioComponentInstanceNew(component, &m_unit);
	if (status != noErr || !m_unit)
	{
		IOSAudio.error("AudioComponentInstanceNew(RemoteIO) failed: 0x%x", static_cast<u32>(status));
		m_unit = nullptr;
		return false;
	}

	UInt32 enable_output = 1;
	status = AudioUnitSetProperty(m_unit, kAudioOutputUnitProperty_EnableIO,
		kAudioUnitScope_Output, 0, &enable_output, sizeof(enable_output));
	if (status != noErr)
	{
		IOSAudio.error("RemoteIO enable output failed: 0x%x", static_cast<u32>(status));
		Close();
		return false;
	}

	AudioStreamBasicDescription format{};
	format.mSampleRate = static_cast<Float64>(get_sampling_rate());
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = sample_size == AudioSampleSize::FLOAT
		? kAudioFormatFlagsNativeFloatPacked
		: (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian);
	format.mBytesPerPacket = m_bytes_per_frame;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = m_bytes_per_frame;
	format.mChannelsPerFrame = get_channels();
	format.mBitsPerChannel = get_sample_size() * 8;

	status = AudioUnitSetProperty(m_unit, kAudioUnitProperty_StreamFormat,
		kAudioUnitScope_Input, 0, &format, sizeof(format));
	if (status != noErr)
	{
		IOSAudio.error("RemoteIO stream format failed: 0x%x (%u Hz, %u ch, %u-bit)",
			static_cast<u32>(status), get_sampling_rate(), get_channels(), get_sample_size() * 8);
		Close();
		return false;
	}

	AURenderCallbackStruct callback{};
	callback.inputProc = &ARMSX3IOSAudioBackend::render_callback;
	callback.inputProcRefCon = this;
	status = AudioUnitSetProperty(m_unit, kAudioUnitProperty_SetRenderCallback,
		kAudioUnitScope_Input, 0, &callback, sizeof(callback));
	if (status != noErr)
	{
		IOSAudio.error("RemoteIO render callback install failed: 0x%x", static_cast<u32>(status));
		Close();
		return false;
	}

	UInt32 max_frames = 4096;
	AudioUnitSetProperty(m_unit, kAudioUnitProperty_MaximumFramesPerSlice,
		kAudioUnitScope_Global, 0, &max_frames, sizeof(max_frames));

	status = AudioUnitInitialize(m_unit);
	if (status != noErr)
	{
		IOSAudio.error("AudioUnitInitialize(RemoteIO) failed: 0x%x", static_cast<u32>(status));
		Close();
		return false;
	}

	AudioStreamBasicDescription actual{};
	UInt32 actual_size = sizeof(actual);
	if (AudioUnitGetProperty(m_unit, kAudioUnitProperty_StreamFormat,
		kAudioUnitScope_Input, 0, &actual, &actual_size) == noErr)
	{
		IOSAudio.notice("RemoteIO client format: %.0f Hz, %u ch, %u bits, flags=0x%x, bytes/frame=%u",
			actual.mSampleRate, actual.mChannelsPerFrame, actual.mBitsPerChannel,
			static_cast<u32>(actual.mFormatFlags), actual.mBytesPerFrame);
	}

	NSMutableArray<NSString*>* route_names = [NSMutableArray array];
	for (AVAudioSessionPortDescription* output in session.currentRoute.outputs)
		[route_names addObject:[NSString stringWithFormat:@"%@/%@", output.portType ?: @"?", output.portName ?: @"?"]];
	NSString* routes = route_names.count ? [route_names componentsJoinedByString:@", "] : @"none";
	IOSAudio.notice("AVAudioSession active: rate=%.0f buffer=%.2fms volume=%.2f route=%s",
		session.sampleRate, session.IOBufferDuration * 1000.0, session.outputVolume, routes.UTF8String);

	m_last_frame.fill(0);
	m_render_buffer.fill(0);
	m_playing = false;
	m_started = false;
	m_first_render_logged.store(false, std::memory_order_release);
	m_first_signal_logged.store(false, std::memory_order_release);
	IOSAudio.notice("RemoteIO opened: %u Hz, %u channels, %s", get_sampling_rate(), get_channels(),
		sample_size == AudioSampleSize::FLOAT ? "f32" : "s16");
	return true;
}

void ARMSX3IOSAudioBackend::Close()
{
	if (!m_unit)
	{
		std::lock_guard lock(m_cb_mutex);
		m_playing = false;
		m_started = false;
		return;
	}

	if (m_started)
	{
		AudioOutputUnitStop(m_unit);
		m_started = false;
	}

	// AudioOutputUnitStop joins the render path before teardown. Only then take the
	// callback mutex and invalidate state used by the realtime callback.
	AudioUnitUninitialize(m_unit);
	AudioComponentInstanceDispose(m_unit);
	m_unit = nullptr;

	std::lock_guard lock(m_cb_mutex);
	m_playing = false;
	m_last_frame.fill(0);
	m_bytes_per_frame = 0;
}

f64 ARMSX3IOSAudioBackend::GetCallbackFrameLen()
{
	AVAudioSession* session = AVAudioSession.sharedInstance;
	const NSTimeInterval duration = session.IOBufferDuration;
	return duration > 0.0 ? static_cast<f64>(duration) : 0.01;
}

void ARMSX3IOSAudioBackend::Play()
{
	if (!m_unit || m_started)
	{
		if (m_started)
		{
			std::lock_guard lock(m_cb_mutex);
			m_playing = true;
		}
		return;
	}

	{
		std::lock_guard lock(m_cb_mutex);
		m_playing = true;
	}

	const OSStatus status = AudioOutputUnitStart(m_unit);
	if (status != noErr)
	{
		IOSAudio.error("AudioOutputUnitStart failed: 0x%x", static_cast<u32>(status));
		std::lock_guard lock(m_cb_mutex);
		m_playing = false;
		return;
	}

	m_started = true;
	IOSAudio.notice("RemoteIO playback started");
}

void ARMSX3IOSAudioBackend::Pause()
{
	if (!m_unit) return;

	if (m_started)
	{
		const OSStatus status = AudioOutputUnitStop(m_unit);
		if (status != noErr)
			IOSAudio.error("AudioOutputUnitStop failed: 0x%x", static_cast<u32>(status));
		m_started = false;
	}

	std::lock_guard lock(m_cb_mutex);
	m_playing = false;
	m_last_frame.fill(0);
}

OSStatus ARMSX3IOSAudioBackend::render_callback(void* ref_con, AudioUnitRenderActionFlags*,
	const AudioTimeStamp*, UInt32, UInt32 frame_count, AudioBufferList* io_data)
{
	return static_cast<ARMSX3IOSAudioBackend*>(ref_con)->render(frame_count, io_data);
}

OSStatus ARMSX3IOSAudioBackend::render(UInt32 frame_count, AudioBufferList* io_data)
{
	if (!io_data || io_data->mNumberBuffers == 0)
		return noErr;

	if (!m_bytes_per_frame)
	{
		for (UInt32 i = 0; i < io_data->mNumberBuffers; ++i)
			if (io_data->mBuffers[i].mData) std::memset(io_data->mBuffers[i].mData, 0, io_data->mBuffers[i].mDataByteSize);
		return noErr;
	}

	if (!m_first_render_logged.exchange(true, std::memory_order_acq_rel))
	{
		IOSAudio.notice("RemoteIO first render: frames=%u buffers=%u b0_channels=%u b0_bytes=%u",
			frame_count, io_data->mNumberBuffers, io_data->mBuffers[0].mNumberChannels,
			io_data->mBuffers[0].mDataByteSize);
	}

	const u64 wanted64 = static_cast<u64>(frame_count) * m_bytes_per_frame;
	const u32 requested = static_cast<u32>(std::min<u64>(wanted64, m_render_buffer.size()));
	const bool direct_interleaved = io_data->mNumberBuffers == 1 && io_data->mBuffers[0].mData &&
		io_data->mBuffers[0].mNumberChannels == get_channels() && io_data->mBuffers[0].mDataByteSize >= requested;
	u8* const dst = direct_interleaved ? static_cast<u8*>(io_data->mBuffers[0].mData) : m_render_buffer.data();
	u32 written = 0;

	std::unique_lock lock(m_cb_mutex, std::defer_lock);
	if (m_bytes_per_frame && lock.try_lock_for(std::chrono::microseconds{50}) &&
		m_write_callback && m_playing)
	{
		written = std::min(m_write_callback(requested, dst), requested);
		written -= written % m_bytes_per_frame;
		if (written >= m_bytes_per_frame)
		{
			std::memcpy(m_last_frame.data(), dst + written - m_bytes_per_frame, m_bytes_per_frame);
		}
	}

	if (written < requested && m_playing)
		m_underruns++;

	for (u32 offset = written; offset < requested; offset += m_bytes_per_frame)
	{
		const u32 copy = std::min(m_bytes_per_frame, requested - offset);
		std::memcpy(dst + offset, m_last_frame.data(), copy);
	}


	if (!m_first_signal_logged.load(std::memory_order_acquire) && written)
	{
		bool nonzero = false;
		for (u32 i = 0; i < written; ++i)
		{
			if (dst[i] != 0) { nonzero = true; break; }
		}
		if (nonzero && !m_first_signal_logged.exchange(true, std::memory_order_acq_rel))
			IOSAudio.notice("RemoteIO received first non-zero PCM block (%u/%u bytes)", written, requested);
	}

	if (direct_interleaved)
	{
		AudioBuffer& buffer = io_data->mBuffers[0];
		if (buffer.mDataByteSize > requested)
			std::memset(dst + requested, 0, buffer.mDataByteSize - requested);
		return noErr;
	}

	// RemoteIO can still expose non-interleaved hardware buffers on some routes even
	// when the client side is interleaved. Deinterleave the already-rendered RPCS3 PCM
	// without allocating in the realtime callback.
	const u32 bytes_per_sample = get_sample_size();
	u32 first_channel = 0;
	for (UInt32 bi = 0; bi < io_data->mNumberBuffers; ++bi)
	{
		AudioBuffer& buffer = io_data->mBuffers[bi];
		if (!buffer.mData) continue;
		u8* out = static_cast<u8*>(buffer.mData);
		const u32 buffer_channels = std::max<UInt32>(1, buffer.mNumberChannels);
		const u32 frames_to_copy = std::min<u32>(frame_count,
			buffer.mDataByteSize / (buffer_channels * bytes_per_sample));
		for (u32 frame = 0; frame < frames_to_copy; ++frame)
		{
			for (u32 ch = 0; ch < buffer_channels; ++ch)
			{
				const u32 src_ch = first_channel + ch;
				if (src_ch >= get_channels()) break;
				std::memcpy(out + (frame * buffer_channels + ch) * bytes_per_sample,
					dst + (frame * get_channels() + src_ch) * bytes_per_sample, bytes_per_sample);
			}
		}
		first_channel += buffer_channels;
	}

	return noErr;
}

