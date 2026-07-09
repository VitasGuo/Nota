import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// 麦克风录音器
/// 支持两种模式：
/// - 文件模式（[start]/[stop]）：输出 16kHz 单声道 WAV（批量转写用）
/// - 流式模式（[startStream]/[stopStream]）：输出 16kHz 单声道 PCM16 字节流
///   （实时 VAD/ASR 用，无 WAV 头，直接喂入 [VadDetector.feedPcm16]）
class MicRecorder {
  final _recorder = AudioRecorder();

  bool _isRecording = false;
  String? _currentPath;

  /// 流式录音状态（与文件模式互斥）。
  bool _isStreaming = false;

  bool get isRecording => _isRecording;
  String? get currentPath => _currentPath;

  /// 是否正在流式录音。
  bool get isStreaming => _isStreaming;

  /// 请求麦克风权限
  Future<bool> requestPermission() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    return status.isGranted;
  }

  /// 开始录音
  /// [sessionDir] 会话目录路径
  /// 返回录音文件路径
  Future<String?> start(String sessionDir) async {
    if (_isRecording) return _currentPath;

    final hasPermission = await requestPermission();
    if (!hasPermission) return null;

    final path = p.join(sessionDir, 'mic.wav');
    _currentPath = path;

    // 确保目录存在
    final dir = Directory(sessionDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 256000,
        sampleRate: 16000, // 16kHz - ASR 标准
        numChannels: 1, // 单声道
      ),
      path: path,
    );

    _isRecording = true;
    return path;
  }

  /// 停止录音
  Future<String?> stop() async {
    if (!_isRecording) return null;
    final path = await _recorder.stop();
    _isRecording = false;
    _currentPath = null;
    return path;
  }

  /// 取消录音（删除文件）
  Future<void> cancel() async {
    if (_isRecording) {
      await _recorder.stop();
      _isRecording = false;
    }
    if (_currentPath != null) {
      final file = File(_currentPath!);
      if (file.existsSync()) {
        file.deleteSync();
      }
      _currentPath = null;
    }
  }

  /// 开始流式录音，返回 PCM16 字节流。
  ///
  /// - 16kHz / 单声道 / PCM16（无 WAV 头，纯裸流）
  /// - 与文件模式 [start] 互斥：流式进行中调用 [start] 会抛 [StateError]
  /// - 权限未授予时抛 [StateError]
  ///
  /// 调用方应在订阅结束时调用 [stopStream] 释放资源；record 6.2.1 的
  /// [AudioRecorder.stop] 会关闭底层流，订阅将收到 done 事件。
  Stream<Uint8List> startStream() async* {
    if (_isRecording) {
      throw StateError('文件录音进行中，不可同时启动流式录音');
    }
    if (_isStreaming) {
      throw StateError('流式录音已在进行中');
    }

    final hasPermission = await requestPermission();
    if (!hasPermission) {
      throw StateError('麦克风权限未授予，无法启动流式录音');
    }

    _isStreaming = true;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits, // 裸 PCM16，无 WAV 头
        bitRate: 256000,
        sampleRate: 16000, // 16kHz - ASR/VAD 标准
        numChannels: 1, // 单声道
      ),
    );
    try {
      yield* stream;
    } finally {
      // 流关闭（订阅取消或底层结束）后复位状态
      _isStreaming = false;
    }
  }

  /// 停止流式录音。
  ///
  /// 调用 [AudioRecorder.stop] 关闭底层流，订阅者将收到 done 事件。
  Future<void> stopStream() async {
    if (!_isStreaming) return;
    await _recorder.stop();
    _isStreaming = false;
  }

  /// 释放资源
  Future<void> dispose() async {
    await _recorder.dispose();
  }
}
