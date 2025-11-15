import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_capture_platform_interface.dart';

/// An implementation of [AudioCapturePlatform] that uses method channels.
class MethodChannelAudioCapture extends AudioCapturePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('audio_capture');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
