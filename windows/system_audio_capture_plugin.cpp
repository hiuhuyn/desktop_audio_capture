#include "system_audio_capture_plugin.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <VersionHelpers.h>
#include <comdef.h>

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <sstream>
#include <thread>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

namespace audio_capture {

namespace {

constexpr char kMethodChannelName[] = "com.system_audio_transcriber/audio_capture";
constexpr char kEventChannelName[] = "com.system_audio_transcriber/audio_stream";
constexpr char kStatusEventChannelName[] = "com.system_audio_transcriber/audio_status";
constexpr char kDecibelEventChannelName[] = "com.system_audio_transcriber/audio_decibel";

constexpr int kDefaultSampleRate = 16000;
constexpr int kDefaultChannels = 1;
constexpr int kDefaultBitsPerSample = 16;
constexpr int kDefaultChunkDurationMs = 1000;
constexpr float kDefaultGainBoost = 2.5f;
constexpr float kDefaultInputVolume = 1.0f;

}  // namespace

// static
void SystemAudioCapturePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<SystemAudioCapturePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

SystemAudioCapturePlugin::SystemAudioCapturePlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar),
      is_capturing_(false),
      should_stop_(false),
      sample_rate_(kDefaultSampleRate),
      channels_(kDefaultChannels),
      bits_per_sample_(kDefaultBitsPerSample),
      chunk_duration_ms_(kDefaultChunkDurationMs),
      gain_boost_(kDefaultGainBoost),
      input_volume_(kDefaultInputVolume),
      audio_client_(nullptr),
      capture_client_(nullptr),
      device_(nullptr),
      mix_format_(nullptr),
      buffer_frame_count_(0),
      com_initialized_(false) {
  // Create method channel
  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
      [this](const auto &call, auto result) {
        this->HandleMethodCall(call, std::move(result));
      });

  // Create event channels
  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), kEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            event_sink_.reset();
            return nullptr;
          }));

  status_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), kStatusEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  status_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            status_event_sink_ = std::move(events);
            SendStatusUpdate(is_capturing_);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            status_event_sink_.reset();
            return nullptr;
          }));

  decibel_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), kDecibelEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  decibel_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            decibel_event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            decibel_event_sink_.reset();
            return nullptr;
          }));
}

SystemAudioCapturePlugin::~SystemAudioCapturePlugin() {
  StopCapture();
}

void SystemAudioCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("requestPermissions") == 0) {
    // On Windows, permissions are typically handled by the system
    result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("startCapture") == 0) {
    const flutter::EncodableMap* args = nullptr;
    if (method_call.arguments() && 
        std::holds_alternative<flutter::EncodableMap>(*method_call.arguments())) {
      args = &std::get<flutter::EncodableMap>(*method_call.arguments());
    }
    bool started = StartCapture(args);
    result->Success(flutter::EncodableValue(started));
  } else if (method_call.method_name().compare("stopCapture") == 0) {
    bool stopped = StopCapture();
    result->Success(flutter::EncodableValue(stopped));
  } else {
    result->NotImplemented();
  }
}

void SystemAudioCapturePlugin::ApplyGainBoostAndConvertToMono(
    const int16_t* input, int16_t* output, size_t frame_count,
    int input_channels, float gain_boost) {
  const float max_value = 32767.0f;
  const float min_value = -32768.0f;

  if (input_channels == 1) {
    // Mono: just apply gain boost
    for (size_t i = 0; i < frame_count; ++i) {
      float sample = static_cast<float>(input[i]) * gain_boost;
      sample = std::max(min_value, std::min(max_value, sample));
      output[i] = static_cast<int16_t>(sample);
    }
  } else {
    // Stereo: convert to mono and apply gain boost
    for (size_t i = 0; i < frame_count; ++i) {
      float left = static_cast<float>(input[i * 2]);
      float right = static_cast<float>(input[i * 2 + 1]);
      float mono = (left + right) / 2.0f * gain_boost;
      mono = std::max(min_value, std::min(max_value, mono));
      output[i] = static_cast<int16_t>(mono);
    }
  }
}

double SystemAudioCapturePlugin::CalculateDecibel(const int16_t* samples,
                                                   size_t sample_count) {
  if (sample_count == 0) {
    return -120.0;
  }

  // Calculate RMS (Root Mean Square)
  double sum_of_squares = 0.0;
  for (size_t i = 0; i < sample_count; ++i) {
    double value = static_cast<double>(samples[i]);
    sum_of_squares += value * value;
  }
  double mean_square = sum_of_squares / static_cast<double>(sample_count);
  double rms = sqrt(mean_square);

  // Calculate decibel: dB = 20 * log10(RMS / max_value)
  const double max_value = 32767.0;
  if (rms <= 0.0) {
    return -120.0;  // Avoid log(0)
  }

  double decibel = 20.0 * log10(rms / max_value);

  // Clamp to reasonable range (-120 dB to 0 dB)
  return std::max(-120.0, std::min(0.0, decibel));
}

void SystemAudioCapturePlugin::SendStatusUpdate(bool is_active) {
  if (status_event_sink_) {
    flutter::EncodableMap status_map;
    status_map[flutter::EncodableValue("isActive")] = flutter::EncodableValue(is_active);
    
    // Get current timestamp in seconds
    auto now = std::chrono::system_clock::now();
    auto duration = now.time_since_epoch();
    auto seconds = std::chrono::duration_cast<std::chrono::seconds>(duration).count();
    auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
    double timestamp = static_cast<double>(milliseconds) / 1000.0;
    
    status_map[flutter::EncodableValue("timestamp")] = flutter::EncodableValue(timestamp);
    status_event_sink_->Success(flutter::EncodableValue(status_map));
  }
}

void SystemAudioCapturePlugin::SendDecibelUpdate(double decibel) {
  if (decibel_event_sink_) {
    flutter::EncodableMap decibel_map;
    decibel_map[flutter::EncodableValue("decibel")] = flutter::EncodableValue(decibel);
    
    // Get current timestamp in seconds
    auto now = std::chrono::system_clock::now();
    auto duration = now.time_since_epoch();
    auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
    double timestamp = static_cast<double>(milliseconds) / 1000.0;
    
    decibel_map[flutter::EncodableValue("timestamp")] = flutter::EncodableValue(timestamp);
    decibel_event_sink_->Success(flutter::EncodableValue(decibel_map));
  }
}

bool SystemAudioCapturePlugin::StartCapture(const flutter::EncodableMap* args) {
  std::lock_guard<std::mutex> lock(mutex_);
  
  if (is_capturing_) {
    return false;
  }

  // Parse arguments
  if (args) {
    auto it = args->find(flutter::EncodableValue("sampleRate"));
    if (it != args->end() && std::holds_alternative<int32_t>(it->second)) {
      sample_rate_ = std::get<int32_t>(it->second);
    }

    it = args->find(flutter::EncodableValue("channels"));
    if (it != args->end() && std::holds_alternative<int32_t>(it->second)) {
      channels_ = std::get<int32_t>(it->second);
    }

    it = args->find(flutter::EncodableValue("bitsPerSample"));
    if (it != args->end() && std::holds_alternative<int32_t>(it->second)) {
      bits_per_sample_ = std::get<int32_t>(it->second);
    }

    it = args->find(flutter::EncodableValue("chunkDurationMs"));
    if (it != args->end() && std::holds_alternative<int32_t>(it->second)) {
      chunk_duration_ms_ = std::get<int32_t>(it->second);
    }

    it = args->find(flutter::EncodableValue("gainBoost"));
    if (it != args->end() && std::holds_alternative<double>(it->second)) {
      gain_boost_ = static_cast<float>(std::get<double>(it->second));
    }

    it = args->find(flutter::EncodableValue("inputVolume"));
    if (it != args->end() && std::holds_alternative<double>(it->second)) {
      input_volume_ = static_cast<float>(std::get<double>(it->second));
    }
  }

  // Clamp values
  sample_rate_ = std::max(sample_rate_, 8000);
  channels_ = std::max(1, std::min(channels_, 2));
  bits_per_sample_ = 16;
  chunk_duration_ms_ = std::max(chunk_duration_ms_, 10);
  gain_boost_ = std::max(0.1f, std::min(10.0f, gain_boost_));
  input_volume_ = std::max(0.0f, std::min(1.0f, input_volume_));

  // Initialize COM (allow RPC_E_CHANGED_MODE if already initialized)
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    return false;
  }
  com_initialized_ = (hr == S_OK);  // Only true if we initialized it

  // Get default audio endpoint (eRender for loopback)
  IMMDeviceEnumerator* enumerator = nullptr;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) {
    CoUninitialize();
    return false;
  }

  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
  enumerator->Release();
  if (FAILED(hr)) {
    CoUninitialize();
    return false;
  }

  // Activate IAudioClient
  hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                         reinterpret_cast<void**>(&audio_client_));
  if (FAILED(hr)) {
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  // Get mix format
  hr = audio_client_->GetMixFormat(&mix_format_);
  if (FAILED(hr)) {
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  // Modify format to match our requirements
  mix_format_->wFormatTag = WAVE_FORMAT_PCM;
  mix_format_->nChannels = static_cast<WORD>(channels_);
  mix_format_->nSamplesPerSec = sample_rate_;
  mix_format_->wBitsPerSample = 16;
  mix_format_->nBlockAlign = mix_format_->nChannels * mix_format_->wBitsPerSample / 8;
  mix_format_->nAvgBytesPerSec = mix_format_->nSamplesPerSec * mix_format_->nBlockAlign;
  mix_format_->cbSize = 0;

  // Initialize audio client for loopback
  REFERENCE_TIME hnsRequestedDuration = REFTIMES_PER_SEC;
  hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_LOOPBACK,
                                  hnsRequestedDuration, 0, mix_format_, nullptr);
  if (FAILED(hr)) {
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  // Get buffer size
  hr = audio_client_->GetBufferSize(&buffer_frame_count_);
  if (FAILED(hr)) {
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  // Get IAudioCaptureClient
  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient),
                                 reinterpret_cast<void**>(&capture_client_));
  if (FAILED(hr)) {
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  // Start capture
  hr = audio_client_->Start();
  if (FAILED(hr)) {
    capture_client_->Release();
    capture_client_ = nullptr;
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    CoUninitialize();
    return false;
  }

  should_stop_ = false;
  is_capturing_ = true;
  
  // Start capture thread
  capture_thread_ = std::thread(&SystemAudioCapturePlugin::CaptureThread, this);
  
  SendStatusUpdate(true);
  
  return true;
}

bool SystemAudioCapturePlugin::StopCapture() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!is_capturing_) {
      return false;
    }
    should_stop_ = true;
  }

  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    is_capturing_ = false;
    
    // Cleanup WASAPI resources
    if (audio_client_) {
      audio_client_->Stop();
    }
    
    if (capture_client_) {
      capture_client_->Release();
      capture_client_ = nullptr;
    }
    
    if (mix_format_) {
      CoTaskMemFree(mix_format_);
      mix_format_ = nullptr;
    }
    
    if (audio_client_) {
      audio_client_->Release();
      audio_client_ = nullptr;
    }
    
    if (device_) {
      device_->Release();
      device_ = nullptr;
    }
    
    // Only uninitialize COM if we initialized it
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
  }

  SendStatusUpdate(false);
  
  return true;
}

void SystemAudioCapturePlugin::CaptureThread() {
  // Safety check
  if (!mix_format_ || !capture_client_) {
    return;
  }

  const UINT32 frame_size = mix_format_->nBlockAlign;
  const size_t chunk_size_bytes = (sample_rate_ * chunk_duration_ms_ / 1000) * frame_size;
  const size_t output_frame_count = chunk_size_bytes / (sizeof(int16_t) * channels_);
  
  std::vector<uint8_t> raw_buffer(chunk_size_bytes);
  std::vector<int16_t> output_buffer(output_frame_count);
  size_t raw_buffer_pos = 0;

  while (!should_stop_) {
    UINT32 num_frames_available = 0;
    HRESULT hr = capture_client_->GetNextPacketSize(&num_frames_available);
    
    if (FAILED(hr)) {
      break;
    }

    while (num_frames_available > 0 && !should_stop_) {
      BYTE* data = nullptr;
      UINT32 num_frames = 0;
      DWORD flags = 0;
      UINT64 device_position = 0;
      UINT64 qpc_position = 0;

      hr = capture_client_->GetBuffer(&data, &num_frames, &flags,
                                      &device_position, &qpc_position);
      
      if (FAILED(hr)) {
        break;
      }

      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        data = nullptr;
      }

      if (data != nullptr && num_frames > 0) {
        const size_t data_size = num_frames * frame_size;
        
        // Copy data to raw buffer
        if (raw_buffer_pos + data_size <= raw_buffer.size()) {
          memcpy(raw_buffer.data() + raw_buffer_pos, data, data_size);
          raw_buffer_pos += data_size;
        }

        // Process chunk when we have enough data
        if (raw_buffer_pos >= chunk_size_bytes) {
          // Apply input volume
          if (input_volume_ < 1.0f) {
            int16_t* samples = reinterpret_cast<int16_t*>(raw_buffer.data());
            const size_t sample_count = chunk_size_bytes / sizeof(int16_t);
            for (size_t i = 0; i < sample_count; ++i) {
              samples[i] = static_cast<int16_t>(
                  static_cast<float>(samples[i]) * input_volume_);
            }
          }

          // Convert to mono and apply gain boost
          const int16_t* input_samples =
              reinterpret_cast<const int16_t*>(raw_buffer.data());
          const size_t input_frame_count =
              chunk_size_bytes / (sizeof(int16_t) * mix_format_->nChannels);
          const size_t frames_to_process =
              std::min(input_frame_count, output_frame_count);

          ApplyGainBoostAndConvertToMono(input_samples, output_buffer.data(),
                                          frames_to_process,
                                          mix_format_->nChannels, gain_boost_);

          // Calculate decibel
          double decibel = CalculateDecibel(output_buffer.data(), frames_to_process);

          // Send audio data
          {
            std::lock_guard<std::mutex> lock(mutex_);
            if (event_sink_) {
              const size_t output_bytes = frames_to_process * sizeof(int16_t);
              std::vector<uint8_t> audio_data(
                  reinterpret_cast<uint8_t*>(output_buffer.data()),
                  reinterpret_cast<uint8_t*>(output_buffer.data()) + output_bytes);
              event_sink_->Success(flutter::EncodableValue(audio_data));
            }

            // Send decibel data
            if (decibel_event_sink_) {
              SendDecibelUpdate(decibel);
            }
          }

          raw_buffer_pos = 0;
        }
      }

      hr = capture_client_->ReleaseBuffer(num_frames);
      if (FAILED(hr)) {
        break;
      }

      hr = capture_client_->GetNextPacketSize(&num_frames_available);
      if (FAILED(hr)) {
        break;
      }
    }

    // Small sleep to prevent busy loop
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

}  // namespace audio_capture

