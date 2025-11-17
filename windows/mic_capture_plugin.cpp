#include "mic_capture_plugin.h"

#define NOMINMAX
#include <windows.h>
#undef max
#undef min
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <VersionHelpers.h>
#include <comdef.h>
#include <propkey.h>
#include <propvarutil.h>

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

// REFTIMES_PER_SEC is 10,000,000 (100 nanoseconds per second)
#ifndef REFTIMES_PER_SEC
#define REFTIMES_PER_SEC 10000000
#endif

namespace audio_capture {

// Custom StreamHandler implementation
template <typename T>
class StreamHandlerFunctions : public flutter::StreamHandler<T> {
 public:
  using OnListenHandler = std::function<std::unique_ptr<flutter::StreamHandlerError<T>>(
      const T* arguments,
      std::unique_ptr<flutter::EventSink<T>>&& events)>;
  using OnCancelHandler = std::function<std::unique_ptr<flutter::StreamHandlerError<T>>(
      const T* arguments)>;

  StreamHandlerFunctions(OnListenHandler on_listen, OnCancelHandler on_cancel)
      : on_listen_(std::move(on_listen)), on_cancel_(std::move(on_cancel)) {}

  virtual ~StreamHandlerFunctions() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<T>> OnListenInternal(
      const T* arguments,
      std::unique_ptr<flutter::EventSink<T>>&& events) override {
    return on_listen_(arguments, std::move(events));
  }

  std::unique_ptr<flutter::StreamHandlerError<T>> OnCancelInternal(
      const T* arguments) override {
    return on_cancel_(arguments);
  }

 private:
  OnListenHandler on_listen_;
  OnCancelHandler on_cancel_;
};

namespace {

constexpr char kMethodChannelName[] = "com.mic_audio_transcriber/mic_capture";
constexpr char kEventChannelName[] = "com.mic_audio_transcriber/mic_stream";
constexpr char kStatusEventChannelName[] = "com.mic_audio_transcriber/mic_status";
constexpr char kDecibelEventChannelName[] = "com.mic_audio_transcriber/mic_decibel";

constexpr int kDefaultSampleRate = 16000;
constexpr int kDefaultChannels = 1;
constexpr int kDefaultBitsPerSample = 16;
constexpr float kDefaultGainBoost = 2.5f;
constexpr float kDefaultInputVolume = 1.0f;

}  // namespace

// static
void MicCapturePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<MicCapturePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MicCapturePlugin::MicCapturePlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar),
      is_capturing_(false),
      should_stop_(false),
      sample_rate_(kDefaultSampleRate),
      channels_(kDefaultChannels),
      bits_per_sample_(kDefaultBitsPerSample),
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
      std::make_unique<StreamHandlerFunctions<flutter::EncodableValue>>(
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
      std::make_unique<StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(mutex_);
            status_event_sink_ = std::move(events);
            SendStatusUpdate(is_capturing_, current_device_name_);
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
      std::make_unique<StreamHandlerFunctions<flutter::EncodableValue>>(
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

MicCapturePlugin::~MicCapturePlugin() {
  StopCapture();
}

void MicCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("requestPermissions") == 0) {
    // On Windows, permissions are typically handled by the system
    result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("hasInputDevice") == 0) {
    bool has_device = HasInputDevice();
    result->Success(flutter::EncodableValue(has_device));
  } else if (method_call.method_name().compare("getAvailableInputDevices") == 0) {
    auto devices = GetAvailableInputDevices();
    result->Success(flutter::EncodableValue(devices));
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

void MicCapturePlugin::ApplyGainBoostAndConvertToMono(
    const int16_t* input, int16_t* output, size_t frame_count,
    int input_channels, float gain_boost) {
  const float max_value = 32767.0f;
  const float min_value = -32768.0f;

  if (input_channels == 1) {
    // Mono: just apply gain boost
    for (size_t i = 0; i < frame_count; ++i) {
      float sample = static_cast<float>(input[i]) * gain_boost;
      float clamped_sample = (std::min)(max_value, sample);
      sample = (std::max)(min_value, clamped_sample);
      output[i] = static_cast<int16_t>(sample);
    }
  } else {
    // Stereo: convert to mono and apply gain boost
    for (size_t i = 0; i < frame_count; ++i) {
      float left = static_cast<float>(input[i * 2]);
      float right = static_cast<float>(input[i * 2 + 1]);
      float mono = (left + right) / 2.0f * gain_boost;
      float clamped_mono = (std::min)(max_value, mono);
      mono = (std::max)(min_value, clamped_mono);
      output[i] = static_cast<int16_t>(mono);
    }
  }
}

double MicCapturePlugin::CalculateDecibel(const int16_t* samples,
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
  double clamped_decibel = (std::min)(0.0, decibel);
  return (std::max)(-120.0, clamped_decibel);
}

void MicCapturePlugin::SendStatusUpdate(bool is_active,
                                        const std::string& device_name) {
  try {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_event_sink_) {
      flutter::EncodableMap status_map;
      status_map[flutter::EncodableValue("isActive")] = flutter::EncodableValue(is_active);
      
      // Get current timestamp in seconds
      auto now = std::chrono::system_clock::now();
      auto duration = now.time_since_epoch();
      auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
      double timestamp = static_cast<double>(milliseconds) / 1000.0;
      
      status_map[flutter::EncodableValue("timestamp")] = flutter::EncodableValue(timestamp);
      
      if (!device_name.empty()) {
        status_map[flutter::EncodableValue("deviceName")] = flutter::EncodableValue(device_name);
      }
      
      status_event_sink_->Success(flutter::EncodableValue(status_map));
    }
  } catch (...) {
    // Silently ignore errors to prevent crash
  }
}

void MicCapturePlugin::SendDecibelUpdate(double decibel) {
  try {
    std::lock_guard<std::mutex> lock(mutex_);
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
  } catch (...) {
    // Silently ignore errors to prevent crash
  }
}

std::string MicCapturePlugin::GetCurrentDeviceName() {
  if (!device_) {
    return "Default Microphone";
  }

  IPropertyStore* props = nullptr;
  HRESULT hr = device_->OpenPropertyStore(STGM_READ, &props);
  if (FAILED(hr)) {
    return "Default Microphone";
  }

  PROPVARIANT varName;
  PropVariantInit(&varName);
  hr = props->GetValue(PKEY_Device_FriendlyName, &varName);
  props->Release();

  std::string device_name = "Default Microphone";
  if (SUCCEEDED(hr) && varName.vt == VT_LPWSTR) {
    // Convert wide string to narrow string
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, varName.pwszVal, -1, nullptr, 0, nullptr, nullptr);
    if (size_needed > 0) {
      std::vector<char> buffer(size_needed);
      WideCharToMultiByte(CP_UTF8, 0, varName.pwszVal, -1, buffer.data(), size_needed, nullptr, nullptr);
      device_name = std::string(buffer.data());
    }
  }
  PropVariantClear(&varName);

  return device_name;
}

bool MicCapturePlugin::IsBluetoothDevice() {
  // Check device name for Bluetooth keywords
  std::string device_name = GetCurrentDeviceName();
  
  // Convert to lowercase safely
  for (size_t i = 0; i < device_name.length(); ++i) {
    device_name[i] = static_cast<char>(::tolower(static_cast<unsigned char>(device_name[i])));
  }
  
  const char* bluetooth_keywords[] = {
    "bluetooth", "airpods", "beats", "jabra", "sony", "bose", "jbl"
  };
  
  for (size_t i = 0; i < sizeof(bluetooth_keywords) / sizeof(bluetooth_keywords[0]); ++i) {
    if (device_name.find(bluetooth_keywords[i]) != std::string::npos) {
      return true;
    }
  }
  
  return false;
}

void MicCapturePlugin::CleanupExistingCapture() {
  std::lock_guard<std::mutex> lock(mutex_);
  
  if (is_capturing_ && capture_thread_.joinable()) {
    should_stop_ = true;
    mutex_.unlock();
    
    capture_thread_.join();
    
    mutex_.lock();
    is_capturing_ = false;
  }
  
  current_device_name_.clear();
  
  // Small delay for cleanup to complete
  std::this_thread::sleep_for(std::chrono::milliseconds(500));
}

bool MicCapturePlugin::OpenWASAPIStreamWithRetry(
    int sample_rate, int channels, int bits_per_sample, bool is_bluetooth,
    void** out_audio_client, void** out_capture_client,
    std::string* error_message) {
  const int max_retries = is_bluetooth ? 5 : 3;
  const double initial_wait = is_bluetooth ? 1.5 : 0.3;
  // ĐÚNG - Khởi tạo array riêng
  const double* retry_delays;
  const double bluetooth_delays[] = {0.5, 1.0, 1.5, 2.0, 2.5};
  const double normal_delays[] = {0.3, 0.6, 1.0, 0.0, 0.0};
  retry_delays = is_bluetooth ? bluetooth_delays : normal_delays;
  
  // Initial wait for device to be ready
  std::this_thread::sleep_for(
      std::chrono::milliseconds(static_cast<int>(initial_wait * 1000)));
  
  for (int attempt = 1; attempt <= max_retries; ++attempt) {
    // Initialize COM (allow RPC_E_CHANGED_MODE if already initialized)
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool com_initialized_this_attempt = (hr == S_OK);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to initialize COM";
      }
      return false;
    }

    // Get default audio endpoint (eCapture for microphone)
    IMMDeviceEnumerator* enumerator = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator),
                          reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) {
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to create device enumerator";
      }
      return false;
    }

    hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device_);
    enumerator->Release();
    if (FAILED(hr)) {
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to get default audio endpoint";
      }
      return false;
    }

    // Activate IAudioClient
    hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(&audio_client_));
    if (FAILED(hr)) {
      device_->Release();
      device_ = nullptr;
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to activate IAudioClient";
      }
      return false;
    }

    // Get mix format - use original format for initialization
    WAVEFORMATEX* device_format = nullptr;
    hr = audio_client_->GetMixFormat(&device_format);
    if (FAILED(hr)) {
      audio_client_->Release();
      audio_client_ = nullptr;
      device_->Release();
      device_ = nullptr;
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to get mix format";
      }
      return false;
    }

    // Store device format for use in capture thread
    // We'll use the device's native format and convert in the thread
    mix_format_ = device_format;

    // Initialize audio client for capture with device's native format
    REFERENCE_TIME hnsRequestedDuration = REFTIMES_PER_SEC;
    hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                    hnsRequestedDuration, 0, mix_format_, nullptr);
    if (FAILED(hr)) {
      CoTaskMemFree(mix_format_);
      mix_format_ = nullptr;
      audio_client_->Release();
      audio_client_ = nullptr;
      device_->Release();
      device_ = nullptr;
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to initialize audio client";
      }
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
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to get buffer size";
      }
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
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to get IAudioCaptureClient";
      }
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
      if (com_initialized_this_attempt) {
        CoUninitialize();
      }
      if (attempt < max_retries && retry_delays[attempt - 1] > 0.0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(retry_delays[attempt - 1] * 1000)));
        continue;
      }
      if (error_message) {
        *error_message = "Failed to start audio client";
      }
      return false;
    }

    // Success - track that we initialized COM
    com_initialized_ = com_initialized_this_attempt;
    *out_audio_client = audio_client_;
    *out_capture_client = capture_client_;
    return true;
  }
  
  if (error_message) {
    *error_message = "Failed to open WASAPI stream after retries";
  }
  return false;
}

bool MicCapturePlugin::HasInputDevice() {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool com_initialized = (hr == S_OK);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    return false;
  }

  IMMDeviceEnumerator* enumerator = nullptr;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) {
    if (com_initialized) {
      CoUninitialize();
    }
    return false;
  }

  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  enumerator->Release();

  bool has_device = SUCCEEDED(hr) && device != nullptr;
  if (device) {
    device->Release();
  }
  if (com_initialized) {
    CoUninitialize();
  }

  return has_device;
}

std::vector<flutter::EncodableValue> MicCapturePlugin::GetAvailableInputDevices() {
  std::vector<flutter::EncodableValue> device_list;
  
  // Get default device info
  std::string device_name = GetCurrentDeviceName();
  bool is_bluetooth = IsBluetoothDevice();
  
  flutter::EncodableMap device_map;
  device_map[flutter::EncodableValue("id")] = flutter::EncodableValue("default");
  device_map[flutter::EncodableValue("name")] = flutter::EncodableValue(device_name);
  device_map[flutter::EncodableValue("type")] = 
      flutter::EncodableValue(is_bluetooth ? "bluetooth" : "external");
  device_map[flutter::EncodableValue("channelCount")] = flutter::EncodableValue(1);
  device_map[flutter::EncodableValue("isDefault")] = flutter::EncodableValue(true);
  
  device_list.push_back(flutter::EncodableValue(device_map));
  
  return device_list;
}

bool MicCapturePlugin::StartCapture(const flutter::EncodableMap* args) {
  // Always cleanup any existing capture first
  CleanupExistingCapture();
  
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

    it = args->find(flutter::EncodableValue("bitDepth"));
    if (it != args->end() && std::holds_alternative<int32_t>(it->second)) {
      bits_per_sample_ = std::get<int32_t>(it->second);
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
  sample_rate_ = (std::max)(sample_rate_, 8000);
  int min_channels = (std::min)(channels_, 2);
  channels_ = (std::max)(1, min_channels);
  bits_per_sample_ = 16;  // Force 16-bit
  float min_gain = (std::min)(10.0f, gain_boost_);
  gain_boost_ = (std::max)(0.1f, min_gain);
  float min_volume = (std::min)(1.0f, input_volume_);
  input_volume_ = (std::max)(0.0f, min_volume);

  // Detect if device is Bluetooth
  bool is_bluetooth = IsBluetoothDevice();
  
  std::string error_message;
  if (!OpenWASAPIStreamWithRetry(sample_rate_, channels_, bits_per_sample_,
                                 is_bluetooth, 
                                 reinterpret_cast<void**>(&audio_client_), 
                                 reinterpret_cast<void**>(&capture_client_),
                                 &error_message)) {
    // Log error
    return false;
  }

  // Get device name (device_ is already set by OpenWASAPIStreamWithRetry)
  current_device_name_ = GetCurrentDeviceName();
  
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (is_capturing_) {
      return false;
    }
    should_stop_ = false;
    is_capturing_ = true;
  }

  // Start capture thread
  capture_thread_ = std::thread(&MicCapturePlugin::CaptureThread, this);
  
  // Wait a bit to ensure thread has started
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  
  SendStatusUpdate(true, current_device_name_);
  
  return true;
}

bool MicCapturePlugin::StopCapture() {
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
    current_device_name_.clear();
    
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

  // Wait a bit to ensure thread has fully stopped
  std::this_thread::sleep_for(std::chrono::milliseconds(100));

  SendStatusUpdate(false);
  
  return true;
}

void MicCapturePlugin::CaptureThread() {
  try {
    if (!mix_format_ || !capture_client_) {
      return;
    }

    // Use actual format from device
    const UINT32 frame_size = mix_format_->nBlockAlign;
    const WORD actual_channels = mix_format_->nChannels;
    const WORD actual_bits_per_sample = mix_format_->wBitsPerSample;
    
    // Debug log format info (chỉ dùng để debug)
    // OutputDebugStringA(("Format: " + std::to_string(actual_channels) + " channels, " + 
    //                     std::to_string(actual_bits_per_sample) + " bits\n").c_str());
    
    // Fixed chunk size in frames (4096 frames)
    const size_t chunk_size_frames = 4096;
    const size_t chunk_size_bytes = chunk_size_frames * frame_size;
    const size_t output_frame_count = chunk_size_frames;
    
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

        // FIX 1: Xử lý silent flag nhưng vẫn release buffer
        bool is_silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        
        // FIX 2: Chỉ xử lý khi có data thực sự và không silent
        if (!is_silent && data != nullptr && num_frames > 0) {
          const size_t data_size = num_frames * frame_size;
          size_t data_offset = 0;
          
          // Process data in chunks
          while (data_offset < data_size && !should_stop_) {
            // Calculate how much space is left in buffer
            const size_t space_available = raw_buffer.size() - raw_buffer_pos;
            const size_t data_remaining = data_size - data_offset;
            const size_t copy_size = (std::min)(space_available, data_remaining);
            
            // Copy data to raw buffer
            if (copy_size > 0) {
              memcpy(raw_buffer.data() + raw_buffer_pos, 
                     reinterpret_cast<const uint8_t*>(data) + data_offset, 
                     copy_size);
              raw_buffer_pos += copy_size;
              data_offset += copy_size;
            }

            // Process chunk when we have enough data
            if (raw_buffer_pos >= chunk_size_bytes) {
              // Convert from device format to 16-bit PCM
              std::vector<int16_t> converted_samples;
              const size_t input_frame_count = chunk_size_bytes / frame_size;
              const size_t total_samples = input_frame_count * actual_channels;
              converted_samples.resize(total_samples);
              
              bool conversion_success = false;
              
              // FIX 3: Thêm WAVE_FORMAT_EXTENSIBLE support
              if (actual_bits_per_sample == 16 && 
                  (mix_format_->wFormatTag == WAVE_FORMAT_PCM || 
                   mix_format_->wFormatTag == WAVE_FORMAT_EXTENSIBLE)) {
                // Already 16-bit PCM, convert to int16_t array
                const int16_t* raw_samples = reinterpret_cast<const int16_t*>(raw_buffer.data());
                converted_samples.assign(raw_samples, raw_samples + total_samples);
                conversion_success = true;
              } else if (actual_bits_per_sample == 32 && 
                         (mix_format_->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
                          mix_format_->wFormatTag == WAVE_FORMAT_EXTENSIBLE)) {
                // 32-bit float, convert to 16-bit PCM
                const float* float_samples = reinterpret_cast<const float*>(raw_buffer.data());
                for (size_t i = 0; i < total_samples; ++i) {
                  // Clamp float value to [-1.0, 1.0] and convert to int16
                  float sample = float_samples[i];
                  if (sample > 1.0f) sample = 1.0f;
                  if (sample < -1.0f) sample = -1.0f;
                  converted_samples[i] = static_cast<int16_t>(sample * 32767.0f);
                }
                conversion_success = true;
              } else if (actual_bits_per_sample == 24) {
                // FIX 4: Thêm support cho 24-bit
                const uint8_t* raw_bytes = raw_buffer.data();
                for (size_t i = 0; i < total_samples; ++i) {
                  size_t byte_offset = i * 3;
                  // Read 24-bit as signed integer (little endian)
                  int32_t sample24 = (static_cast<int32_t>(raw_bytes[byte_offset]) |
                                     (static_cast<int32_t>(raw_bytes[byte_offset + 1]) << 8) |
                                     (static_cast<int32_t>(raw_bytes[byte_offset + 2]) << 16));
                  // Sign extend from 24-bit to 32-bit
                  if (sample24 & 0x800000) {
                    sample24 |= 0xFF000000;
                  }
                  // Convert to 16-bit
                  converted_samples[i] = static_cast<int16_t>(sample24 >> 8);
                }
                conversion_success = true;
              }
              
              // FIX 5: Log và skip nếu conversion thất bại
              if (!conversion_success) {
                // OutputDebugStringA("Unsupported audio format, skipping chunk\n");
                raw_buffer_pos = 0;
                continue;
              }
              
              // FIX 6: Kiểm tra input_volume_ trước khi áp dụng
              if (input_volume_ > 0.0f && input_volume_ < 1.0f) {
                for (size_t i = 0; i < total_samples; ++i) {
                  converted_samples[i] = static_cast<int16_t>(
                      static_cast<float>(converted_samples[i]) * input_volume_);
                }
              }

              // Convert to mono and apply gain boost
              const size_t frames_to_process = converted_samples.size() / actual_channels;
              const size_t output_frames = (std::min)(frames_to_process, output_frame_count);

              ApplyGainBoostAndConvertToMono(converted_samples.data(), output_buffer.data(),
                                              output_frames,
                                              actual_channels, gain_boost_);

              // Calculate decibel
              double decibel = CalculateDecibel(output_buffer.data(), output_frames);

              // Send audio data
              try {
                std::lock_guard<std::mutex> lock(mutex_);
                if (event_sink_) {
                  const size_t output_bytes = output_frames * sizeof(int16_t);
                  std::vector<uint8_t> audio_data(
                      reinterpret_cast<uint8_t*>(output_buffer.data()),
                      reinterpret_cast<uint8_t*>(output_buffer.data()) + output_bytes);
                  event_sink_->Success(flutter::EncodableValue(audio_data));
                }
              } catch (...) {
                // Silently ignore errors to prevent crash
              }

              // Send decibel data
              SendDecibelUpdate(decibel);

              // FIX 7: Đảm bảo reset buffer position đúng cách
              if (raw_buffer_pos > chunk_size_bytes) {
                const size_t remaining = raw_buffer_pos - chunk_size_bytes;
                memmove(raw_buffer.data(), raw_buffer.data() + chunk_size_bytes, remaining);
                raw_buffer_pos = remaining;
              } else {
                raw_buffer_pos = 0;
              }
            }
          }
        }

        // FIX 8: Luôn release buffer, kể cả khi silent
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
  } catch (...) {
    // Catch any exceptions to prevent abort
    std::lock_guard<std::mutex> lock(mutex_);
    is_capturing_ = false;
  }
}

}  // namespace audio_capture

