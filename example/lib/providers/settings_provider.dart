import 'package:flutter/material.dart';
import 'package:desktop_audio_capture/config/mic_audio_config.dart';
import 'package:desktop_audio_capture/config/system_adudio_config.dart';

class SettingsProvider with ChangeNotifier {
  // Mic settings
  int _micSampleRate = 16000;
  int _micChannels = 1;
  double _micGainBoost = 2.5;
  double _micInputVolume = 1.0;

  // System settings
  int _systemSampleRate = 16000;
  int _systemChannels = 1;

  // Getters
  int get micSampleRate => _micSampleRate;
  int get micChannels => _micChannels;
  double get micGainBoost => _micGainBoost;
  double get micInputVolume => _micInputVolume;
  int get systemSampleRate => _systemSampleRate;
  int get systemChannels => _systemChannels;

  // Mic settings
  void setMicSampleRate(int value) {
    _micSampleRate = value;
    notifyListeners();
  }

  void setMicChannels(int value) {
    _micChannels = value;
    notifyListeners();
  }

  void setMicGainBoost(double value) {
    _micGainBoost = value;
    notifyListeners();
  }

  void setMicInputVolume(double value) {
    _micInputVolume = value;
    notifyListeners();
  }

  MicAudioConfig getMicConfig() {
    return MicAudioConfig(
      sampleRate: _micSampleRate,
      channels: _micChannels,
      gainBoost: _micGainBoost,
      inputVolume: _micInputVolume,
    );
  }

  // System settings
  void setSystemSampleRate(int value) {
    _systemSampleRate = value;
    notifyListeners();
  }

  void setSystemChannels(int value) {
    _systemChannels = value;
    notifyListeners();
  }

  SystemAudioConfig getSystemConfig() {
    return SystemAudioConfig(
      sampleRate: _systemSampleRate,
      channels: _systemChannels,
    );
  }
}

