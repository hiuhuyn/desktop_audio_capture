//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <desktop_audio_capture/audio_capture_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) desktop_audio_capture_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AudioCapturePlugin");
  audio_capture_plugin_register_with_registrar(desktop_audio_capture_registrar);
}
