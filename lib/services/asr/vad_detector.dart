import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// PCM16 字节流（小端有符号 16-bit）→ Float32 归一化样本（[-1.0, 1.0)）。
///
/// sherpa-onnx VAD 的 [sherpa_onnx.VoiceActivityDetector.acceptWaveform]
/// 接收 Float32List 归一化样本，故从 [MicRecorder.startStream] 拿到的
/// PCM16 字节流需先经此转换。
///
/// 奇数长度字节会丢弃尾部 1 字节（不完整的样本）。
Float32List convertPcm16ToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final result = Float32List(sampleCount);
  final byteData = ByteData.sublistView(bytes);
  for (int i = 0; i < sampleCount; i++) {
    // 小端有符号 16-bit → [-32768, 32767] → 归一化到 [-1.0, 1.0)
    result[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return result;
}

/// 语音活动检测封装（基于 sherpa-onnx Silero VAD）。
///
/// 队列式检测器：调用方通过 [feedPcm16] 喂入 PCM16 字节流（来自
/// [MicRecorder.startStream]），内部转换为 Float32 后调用
/// [sherpa_onnx.VoiceActivityDetector.acceptWaveform]，并轮询输出队列：
/// - 语音开始边沿（false→true）：触发 [onSpeechStart]
/// - 完整语音段出队：触发 [onSpeechEnd]，携带起始样本索引、Float32 样本、
///   起止秒数
///
/// 典型用法：
/// ```dart
/// final vad = VadDetector(modelPath: vadPath, onSpeechEnd: (s, samples, st, ed) {
///   // 送 ASR 转写 samples
/// });
/// await for (final chunk in micRecorder.startStream()) {
///   vad.feedPcm16(chunk);
/// }
/// vad.flush();
/// vad.dispose();
/// ```
///
/// 默认参数（Silero VAD 推荐值）：
/// - threshold 0.5：语音/非语音判定阈值
/// - minSilenceDuration 0.8s：判定语音结束所需的最短静音时长
/// - minSpeechDuration 0.25s：判定语音开始所需的最短语音时长
/// - maxSpeechDuration 30.0s：单段语音上限，超过强制分段
/// - windowSize 512：VAD 处理窗口样本数（16kHz 对应 32ms）
/// - sampleRate 16000：与 [MicRecorder] 一致
class VadDetector {
  VadDetector({
    required String modelPath,
    this.onSpeechStart,
    this.onSpeechEnd,
    double threshold = 0.5,
    double minSilenceDuration = 0.8,
    double minSpeechDuration = 0.25,
    double maxSpeechDuration = 30.0,
    int windowSize = 512,
    int sampleRate = 16000,
    int numThreads = 1,
    double bufferSizeInSeconds = 60.0,
  }) {
    final config = sherpa_onnx.VadModelConfig(
      sileroVad: sherpa_onnx.SileroVadModelConfig(
        model: modelPath,
        threshold: threshold,
        minSilenceDuration: minSilenceDuration,
        minSpeechDuration: minSpeechDuration,
        maxSpeechDuration: maxSpeechDuration,
        windowSize: windowSize,
      ),
      sampleRate: sampleRate,
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );
    _vad = sherpa_onnx.VoiceActivityDetector(
      config: config,
      bufferSizeInSeconds: bufferSizeInSeconds,
    );
    _sampleRate = sampleRate;
  }

  /// 语音开始回调（非语音→语音边沿触发）。
  final void Function()? onSpeechStart;

  /// 语音结束回调。
  ///
  /// - [startSample]：该语音段起始样本索引（相对累计喂入的样本数）
  /// - [samples]：该语音段的 Float32 归一化样本
  /// - [startSec]：起始秒 = startSample / sampleRate
  /// - [endSec]：结束秒 = (startSample + samples.length) / sampleRate
  final void Function(
    int startSample,
    Float32List samples,
    double startSec,
    double endSec,
  )? onSpeechEnd;

  late final sherpa_onnx.VoiceActivityDetector _vad;
  late final int _sampleRate;

  /// 当前是否处于语音检测态（用于边沿检测）。
  bool _wasDetected = false;

  /// 是否已释放。
  bool _disposed = false;

  /// 喂入 PCM16 字节流并轮询输出语音段。
  ///
  /// 自动将 PCM16 转为 Float32 → [sherpa_onnx.VoiceActivityDetector.acceptWaveform]
  /// → 触发 [_poll]。
  void feedPcm16(Uint8List bytes) {
    if (_disposed) return;
    final samples = convertPcm16ToFloat32(bytes);
    if (samples.isEmpty) return;
    _vad.acceptWaveform(samples);
    _poll();
  }

  /// 轮询 VAD 输出队列，触发边沿与分段回调。
  ///
  /// 边沿检测：[sherpa_onnx.VoiceActivityDetector.isDetected] false→true 时
  /// 触发 [onSpeechStart]；true→false 不单独回调（语音段出队即代表结束）。
  /// 分段出队：[sherpa_onnx.VoiceActivityDetector.isEmpty] 为 false 时循环
  /// 取 [front] / [pop]，每段触发 [onSpeechEnd]。
  void _poll() {
    // 边沿检测：语音开始
    final isDetected = _vad.isDetected();
    if (isDetected && !_wasDetected) {
      onSpeechStart?.call();
    }
    _wasDetected = isDetected;

    // 取出所有已完成的语音段
    while (!_vad.isEmpty()) {
      final segment = _vad.front();
      _vad.pop();
      if (segment.samples.isEmpty) continue;
      final startSample = segment.start;
      final startSec = startSample / _sampleRate;
      final endSec = (startSample + segment.samples.length) / _sampleRate;
      onSpeechEnd?.call(startSample, segment.samples, startSec, endSec);
    }
  }

  /// 刷出残余语音段。
  ///
  /// 调用 [sherpa_onnx.VoiceActivityDetector.flush] 强制输出尾部未结束的
  /// 语音段（若仍在语音态），随后 [_poll] 取出。通常在录音停止前调用。
  void flush() {
    if (_disposed) return;
    _vad.flush();
    _poll();
  }

  /// 释放原生资源。释放后不可再使用。
  void dispose() {
    if (_disposed) return;
    _vad.free();
    _disposed = true;
  }
}
