import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 扬声器内录器（Android 10+）
/// 通过 AudioPlaybackCaptureConfiguration 捕获系统/其他 App 播放音频
class SpeakerRecorder {
  static const _channel = MethodChannel('nota/audio_capture');

  bool _isRecording = false;
  String? _currentPath;

  bool get isRecording => _isRecording;
  String? get currentPath => _currentPath;

  /// 检查设备是否支持扬声器内录（Android 10+）
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isCaptureAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 开始内录
  /// [sessionDir] 会话目录路径
  /// 返回录音文件路径，如果用户拒绝授权返回 null
  Future<String?> start(String sessionDir) async {
    if (_isRecording) return _currentPath;

    final dir = Directory(sessionDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final outputPath = p.join(sessionDir, 'speaker.wav');
    _currentPath = outputPath;

    try {
      final result = await _channel.invokeMethod<bool>('startCapture', {
        'outputPath': outputPath,
      });
      if (result == true) {
        _isRecording = true;
        return outputPath;
      }
      _currentPath = null;
      return null;
    } catch (_) {
      _currentPath = null;
      return null;
    }
  }

  /// 停止内录
  Future<String?> stop() async {
    if (!_isRecording) return null;
    try {
      final path = await _channel.invokeMethod<String>('stopCapture');
      _isRecording = false;
      _currentPath = null;
      return path;
    } catch (_) {
      _isRecording = false;
      _currentPath = null;
      return null;
    }
  }

  /// 取消
  Future<void> cancel() async {
    if (_isRecording) {
      await stop();
    }
    if (_currentPath != null) {
      final file = File(_currentPath!);
      if (file.existsSync()) file.deleteSync();
      _currentPath = null;
    }
  }
}
