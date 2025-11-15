import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'audio_capture_method_channel.dart';

abstract class AudioCapturePlatform extends PlatformInterface {
  /// Constructs a AudioCapturePlatform.
  AudioCapturePlatform() : super(token: _token);

  static final Object _token = Object();

  static AudioCapturePlatform _instance = MethodChannelAudioCapture();

  /// The default instance of [AudioCapturePlatform] to use.
  ///
  /// Defaults to [MethodChannelAudioCapture].
  static AudioCapturePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AudioCapturePlatform] when
  /// they register themselves.
  static set instance(AudioCapturePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
