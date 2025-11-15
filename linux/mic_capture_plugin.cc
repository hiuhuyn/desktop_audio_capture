#include "include/audio_capture/mic_capture_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <glib-object.h>
#include <glib.h>
#include <pulse/error.h>
#include <pulse/simple.h>
#include <pulse/pulseaudio.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr char kMethodChannelName[] = "com.mic_audio_transcriber/mic_capture";
constexpr char kEventChannelName[] = "com.mic_audio_transcriber/mic_stream";

constexpr int kDefaultSampleRate = 16000;
constexpr int kDefaultChannels = 1;
constexpr int kDefaultBitsPerSample = 16;
constexpr float kDefaultGainBoost = 2.5f;
constexpr float kDefaultInputVolume = 1.0f;
constexpr size_t kBufferSizeFrames = 4096;

struct AudioChunkPayload {
  AudioChunkPayload(MicCapturePlugin* plugin, GBytes* bytes)
      : plugin(plugin), bytes(bytes) {}

  MicCapturePlugin* plugin;
  GBytes* bytes;
};

struct CaptureThreadContext {
  MicCapturePlugin* plugin;
  pa_simple* stream;
  size_t chunk_size;
  int sample_rate;
  int channels;
  int bits_per_sample;
  float gain_boost;
  float input_volume;
};

gboolean EmitAudioOnMainThread(gpointer user_data);
gpointer CaptureThread(gpointer user_data);

}  // namespace

struct _MicCapturePlugin {
  GObject parent_instance;

  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  GMainContext* main_context;

  GMutex lock;
  gint should_stop;
  gboolean is_capturing;
  gboolean has_listener;

  GThread* capture_thread;
};

G_DEFINE_TYPE(MicCapturePlugin, mic_capture_plugin, G_TYPE_OBJECT)

namespace {

bool CheckMicSupport() {
  pa_simple* stream = nullptr;
  pa_sample_spec spec;
  spec.rate = kDefaultSampleRate;
  spec.channels = static_cast<uint8_t>(kDefaultChannels);
  spec.format = PA_SAMPLE_S16LE;

  pa_buffer_attr attr;
  attr.maxlength = static_cast<uint32_t>(-1);
  attr.tlength = static_cast<uint32_t>(-1);
  attr.prebuf = static_cast<uint32_t>(-1);
  attr.minreq = static_cast<uint32_t>(-1);
  attr.fragsize = static_cast<uint32_t>(-1);

  int error = 0;
  // Try to open default source (microphone)
  stream = pa_simple_new(nullptr, "Voxa", PA_STREAM_RECORD, nullptr,
                         "Mic Check", &spec, nullptr, &attr, &error);

  if (stream == nullptr) {
    return false;
  }

  pa_simple_free(stream);
  return true;
}

size_t CalculateChunkSize(int sample_rate, int channels, int bits_per_sample) {
  const int bytes_per_sample = std::max(bits_per_sample / 8, 1);
  const size_t frame_size = static_cast<size_t>(channels) * bytes_per_sample;
  return kBufferSizeFrames * frame_size;
}

bool OpenPulseStream(int sample_rate, int channels, int bits_per_sample,
                     size_t chunk_size, pa_simple** out_stream,
                     std::string* error_message) {
  pa_sample_spec spec;
  spec.rate = sample_rate;
  spec.channels = static_cast<uint8_t>(channels);
  if (bits_per_sample == 16) {
    spec.format = PA_SAMPLE_S16LE;
  } else {
    spec.format = PA_SAMPLE_S16LE;
  }

  pa_buffer_attr attr;
  attr.maxlength = static_cast<uint32_t>(chunk_size * 4);
  attr.tlength = static_cast<uint32_t>(-1);
  attr.prebuf = static_cast<uint32_t>(-1);
  attr.minreq = static_cast<uint32_t>(-1);
  attr.fragsize = static_cast<uint32_t>(chunk_size);

  int error = 0;
  // Use nullptr to get default source (microphone)
  pa_simple* stream = pa_simple_new(nullptr, "Voxa", PA_STREAM_RECORD, nullptr,
                                     "Mic Capture", &spec, nullptr, &attr, &error);

  if (stream == nullptr) {
    if (error_message != nullptr) {
      *error_message = pa_strerror(error);
    }
    return false;
  }

  *out_stream = stream;
  return true;
}

void ApplyGainBoostAndConvertToMono(const int16_t* input, int16_t* output,
                                    size_t frame_count, int input_channels,
                                    float gain_boost) {
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

gboolean EmitAudioOnMainThread(gpointer user_data) {
  std::unique_ptr<AudioChunkPayload> payload(
      static_cast<AudioChunkPayload*>(user_data));
  MicCapturePlugin* plugin = payload->plugin;

  gsize length = 0;
  const guint8* data =
      static_cast<const guint8*>(g_bytes_get_data(payload->bytes, &length));

  g_mutex_lock(&plugin->lock);
  const gboolean can_emit =
      plugin->event_channel != nullptr && plugin->has_listener;
  g_mutex_unlock(&plugin->lock);

  if (can_emit && length > 0) {
    g_autoptr(FlValue) value = fl_value_new_uint8_list(data, length);
    g_autoptr(GError) error = nullptr;

    if (!fl_event_channel_send(plugin->event_channel, value, nullptr, &error)) {
      g_warning("Failed to send audio chunk: %s",
                error != nullptr ? error->message : "unknown error");
    }
  }

  g_bytes_unref(payload->bytes);
  g_object_unref(plugin);

  return G_SOURCE_REMOVE;
}

gpointer CaptureThread(gpointer user_data) {
  std::unique_ptr<CaptureThreadContext> context(
      static_cast<CaptureThreadContext*>(user_data));
  MicCapturePlugin* plugin = context->plugin;

  // Read raw audio from PulseAudio
  const size_t raw_chunk_size = CalculateChunkSize(
      context->sample_rate, context->channels, context->bits_per_sample);
  std::vector<uint8_t> raw_buffer(raw_chunk_size);

  // Output buffer for processed audio (mono)
  const size_t output_frame_count = kBufferSizeFrames;
  std::vector<int16_t> output_buffer(output_frame_count);

  while (!g_atomic_int_get(&plugin->should_stop)) {
    int error = 0;
    if (pa_simple_read(context->stream, raw_buffer.data(), raw_buffer.size(),
                       &error) < 0) {
      g_warning("PulseAudio read error: %s", pa_strerror(error));
      break;
    }

    if (g_atomic_int_get(&plugin->should_stop)) {
      break;
    }

    // Apply input volume
    if (context->input_volume < 1.0f) {
      int16_t* samples = reinterpret_cast<int16_t*>(raw_buffer.data());
      const size_t sample_count = raw_buffer.size() / sizeof(int16_t);
      for (size_t i = 0; i < sample_count; ++i) {
        samples[i] = static_cast<int16_t>(
            static_cast<float>(samples[i]) * context->input_volume);
      }
    }

    // Convert to mono and apply gain boost
    const int16_t* input_samples =
        reinterpret_cast<const int16_t*>(raw_buffer.data());
    const size_t input_frame_count =
        raw_buffer.size() / (sizeof(int16_t) * context->channels);
    const size_t frames_to_process =
        std::min(input_frame_count, output_frame_count);

    ApplyGainBoostAndConvertToMono(input_samples, output_buffer.data(),
                                    frames_to_process, context->channels,
                                    context->gain_boost);

    // Create output bytes
    const size_t output_bytes = frames_to_process * sizeof(int16_t);
    GBytes* bytes = g_bytes_new(output_buffer.data(), output_bytes);
    auto* payload = new AudioChunkPayload(plugin, bytes);
    g_object_ref(plugin);

    g_main_context_invoke_full(plugin->main_context, G_PRIORITY_DEFAULT,
                               EmitAudioOnMainThread, payload, nullptr);
  }

  pa_simple_free(context->stream);

  g_mutex_lock(&plugin->lock);
  plugin->is_capturing = FALSE;
  plugin->capture_thread = nullptr;
  g_mutex_unlock(&plugin->lock);

  g_object_unref(plugin);
  return nullptr;
}

static FlMethodErrorResponse* OnListenHandler(FlEventChannel* channel,
                                              FlValue* arguments,
                                              gpointer user_data) {
  MicCapturePlugin* plugin = MIC_CAPTURE_PLUGIN(user_data);
  (void)channel;
  (void)arguments;
  g_mutex_lock(&plugin->lock);
  plugin->has_listener = TRUE;
  g_mutex_unlock(&plugin->lock);
  return nullptr;
}

static FlMethodErrorResponse* OnCancelHandler(FlEventChannel* channel,
                                              FlValue* arguments,
                                              gpointer user_data) {
  MicCapturePlugin* plugin = MIC_CAPTURE_PLUGIN(user_data);
  (void)channel;
  (void)arguments;
  g_mutex_lock(&plugin->lock);
  plugin->has_listener = FALSE;
  g_mutex_unlock(&plugin->lock);
  return nullptr;
}

bool StartCapture(MicCapturePlugin* plugin, FlValue* args) {
  int sample_rate = kDefaultSampleRate;
  int channels = kDefaultChannels;
  int bits_per_sample = kDefaultBitsPerSample;
  float gain_boost = kDefaultGainBoost;
  float input_volume = kDefaultInputVolume;

  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = nullptr;

    value = fl_value_lookup_string(args, "sampleRate");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
      sample_rate = fl_value_get_int(value);
    }

    value = fl_value_lookup_string(args, "channels");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
      channels = fl_value_get_int(value);
    }

    value = fl_value_lookup_string(args, "bitDepth");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
      bits_per_sample = fl_value_get_int(value);
    }

    value = fl_value_lookup_string(args, "gainBoost");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
      gain_boost = fl_value_get_float(value);
      gain_boost = std::max(0.1f, std::min(10.0f, gain_boost));
    }

    value = fl_value_lookup_string(args, "inputVolume");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
      input_volume = fl_value_get_float(value);
      input_volume = std::max(0.0f, std::min(1.0f, input_volume));
    }
  }

  // Clamp values
  sample_rate = std::max(sample_rate, 8000);
  channels = std::max(1, std::min(channels, 2));
  bits_per_sample = 16;  // Force 16-bit
  gain_boost = std::max(0.1f, std::min(10.0f, gain_boost));
  input_volume = std::max(0.0f, std::min(1.0f, input_volume));

  size_t chunk_size =
      CalculateChunkSize(sample_rate, channels, bits_per_sample);

  pa_simple* stream = nullptr;
  std::string error_message;

  if (!OpenPulseStream(sample_rate, channels, bits_per_sample, chunk_size,
                       &stream, &error_message)) {
    g_warning("Failed to open PulseAudio stream: %s", error_message.c_str());
    return false;
  }

  g_mutex_lock(&plugin->lock);
  if (plugin->is_capturing) {
    g_mutex_unlock(&plugin->lock);
    pa_simple_free(stream);
    return false;
  }

  g_atomic_int_set(&plugin->should_stop, 0);
  plugin->is_capturing = TRUE;

  auto* context = new CaptureThreadContext{
      plugin, stream, chunk_size, sample_rate, channels,
      bits_per_sample, gain_boost, input_volume};

  g_object_ref(plugin);
  plugin->capture_thread =
      g_thread_new("voxa-mic-capture", CaptureThread, context);
  g_mutex_unlock(&plugin->lock);

  if (plugin->capture_thread == nullptr) {
    g_warning("Failed to create capture thread");
    g_mutex_lock(&plugin->lock);
    plugin->is_capturing = FALSE;
    g_mutex_unlock(&plugin->lock);
    pa_simple_free(stream);
    g_object_unref(plugin);
    delete context;
    return false;
  }

  return true;
}

bool StopCapture(MicCapturePlugin* plugin) {
  g_mutex_lock(&plugin->lock);
  if (!plugin->is_capturing) {
    g_mutex_unlock(&plugin->lock);
    return false;
  }
  g_atomic_int_set(&plugin->should_stop, 1);
  GThread* thread = plugin->capture_thread;
  g_mutex_unlock(&plugin->lock);

  if (thread != nullptr) {
    g_thread_join(thread);
  }

  g_mutex_lock(&plugin->lock);
  plugin->capture_thread = nullptr;
  plugin->is_capturing = FALSE;
  g_mutex_unlock(&plugin->lock);

  return true;
}

void HandleMethodCall(MicCapturePlugin* plugin, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "isSupported") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "checkMicSupport") == 0) {
    const bool supported = CheckMicSupport();
    g_autoptr(FlValue) result = fl_value_new_bool(supported);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "requestPermissions") == 0) {
    // On Linux, permissions are typically handled by the system
    // PulseAudio will handle access automatically
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "startCapture") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const bool started = StartCapture(plugin, args);
    g_autoptr(FlValue) result = fl_value_new_bool(started);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "stopCapture") == 0) {
    const bool stopped = StopCapture(plugin);
    g_autoptr(FlValue) result = fl_value_new_bool(stopped);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send method call response: %s", error->message);
  }
}

static void MethodCallHandler(FlMethodChannel* channel,
                               FlMethodCall* method_call,
                               gpointer user_data) {
  MicCapturePlugin* plugin = MIC_CAPTURE_PLUGIN(user_data);
  HandleMethodCall(plugin, method_call);
}

}  // namespace

static void mic_capture_plugin_dispose(GObject* object) {
  MicCapturePlugin* plugin = MIC_CAPTURE_PLUGIN(object);

  StopCapture(plugin);

  if (plugin->method_channel != nullptr) {
    g_clear_object(&plugin->method_channel);
  }

  if (plugin->event_channel != nullptr) {
    g_clear_object(&plugin->event_channel);
  }

  if (plugin->main_context != nullptr) {
    g_main_context_unref(plugin->main_context);
    plugin->main_context = nullptr;
  }

  g_mutex_clear(&plugin->lock);

  G_OBJECT_CLASS(mic_capture_plugin_parent_class)->dispose(object);
}

static void mic_capture_plugin_class_init(MicCapturePluginClass* klass) {
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = mic_capture_plugin_dispose;
}

static void mic_capture_plugin_init(MicCapturePlugin* plugin) {
  g_mutex_init(&plugin->lock);
  plugin->main_context = g_main_context_ref_thread_default();
  plugin->is_capturing = FALSE;
  plugin->has_listener = FALSE;
  plugin->method_channel = nullptr;
  plugin->event_channel = nullptr;
  plugin->capture_thread = nullptr;
  g_atomic_int_set(&plugin->should_stop, 0);
}

void mic_capture_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  mic_capture_plugin_register_with_messenger(messenger);
}

void mic_capture_plugin_register_with_messenger(FlBinaryMessenger* messenger) {
  MicCapturePlugin* plugin = MIC_CAPTURE_PLUGIN(
      g_object_new(mic_capture_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  plugin->method_channel = fl_method_channel_new(
      messenger, kMethodChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->method_channel,
                                            MethodCallHandler, g_object_ref(plugin),
                                            g_object_unref);

  plugin->event_channel = fl_event_channel_new(messenger, kEventChannelName,
                                                 FL_METHOD_CODEC(codec));

  fl_event_channel_set_stream_handlers(plugin->event_channel, OnListenHandler,
                                        OnCancelHandler, g_object_ref(plugin),
                                        g_object_unref);

  g_object_unref(plugin);
}

