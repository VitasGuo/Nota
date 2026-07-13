// lib/services/asr/whisper_engine.dart
//
// whisper.cpp 高层封装：在 [WhisperFfi] 之上提供 load/transcribe/dispose API。
//
// 设计：
// - [load] 加载模型到内存，持有不透明上下文指针
// - [transcribe] 输入 PCM F32 16kHz 单声道，返回拼接后的完整文本
//   （段内时间戳由 VAD 提供，这里只取文本）
// - [dispose] 释放模型上下文，幂等
//
// 注意：[transcribe] 是同步 FFI 调用（whisper_full 阻塞 1-3s），
// 必须在 worker Isolate 中调用，不可在主 isolate 直接使用（traps.md #37/#45）。
// 见 [WhisperIsolateWorker]。

import 'dart:ffi';
import 'dart:typed_data';

import 'package:nota/services/asr/whisper_ffi.dart';

/// whisper.cpp 引擎封装。
///
/// 加载 whisper.cpp ggml 模型（.bin 格式，非 GGUF）并执行转写。
/// 单实例对应一个模型，不可并发调用 [transcribe]（whisper_full 非线程安全）。
///
/// 模型格式：whisper.cpp 使用 ggml 自有格式（.bin），与 llama.cpp 的 GGUF
/// 不同。下载源：https://huggingface.co/ggerganov/whisper.cpp
///
/// 采样率：whisper.cpp 固定 16000Hz，与 NOTA 的 PCM16 16kHz 标准一致，
/// 无需重采样。VAD 输出的 Float32 样本可直接传入。
class WhisperEngine {
  Pointer<NativeType>? _ctx;
  bool _disposed = false;

  /// 语言代码（"auto" / "zh" / "en" / "ja" / "ko" 等，whisper.cpp 支持）。
  final String language;

  /// 推理线程数（建议 2-4，移动端 4 已足够）。
  final int nThreads;

  WhisperEngine({this.language = 'auto', this.nThreads = 4});

  /// 模型是否已加载（[load] 成功且未 [dispose]）。
  bool get isLoaded => _ctx != null && !_disposed;

  /// 加载 whisper.cpp ggml 模型。
  ///
  /// [modelPath] 模型文件路径（如 `ggml-small.bin`）
  ///
  /// 失败抛 [StateError]（whisper_simple_init 返回 null 指针）。
  void load(String modelPath) {
    if (_disposed) throw StateError('WhisperEngine 已释放');
    if (_ctx != null) return;

    final ctx = WhisperFfi.instance.init(modelPath);
    if (ctx == Pointer<NativeType>.fromAddress(0)) {
      throw StateError('whisper_simple_init 失败：无法加载模型 $modelPath');
    }
    _ctx = ctx;
  }

  /// 转写音频段，返回拼接后的完整文本。
  ///
  /// [samples] PCM F32 单声道 16kHz，归一化到 [-1.0, 1.0]
  /// （与 [VadDetector] 输出的 Float32 格式一致）。
  ///
  /// 返回所有段文本拼接结果（空格分隔）。若模型返回 0 段返回空字符串。
  ///
  /// 异常：FFI 层失败抛 [StateError]。
  String transcribe(Float32List samples) {
    if (_disposed || _ctx == null) {
      throw StateError('WhisperEngine 未加载或已释放');
    }

    final segments = WhisperFfi.instance.transcribe(
      _ctx!,
      samples,
      language,
      nThreads,
    );

    if (segments.isEmpty) return '';
    // 拼接段文本（whisper 段内自带标点，简单空格连接即可）
    // 中文场景下 whisper.cpp 输出已含标点，无需额外加空格
    return segments.map((s) => s.text).join('').trim();
  }

  /// 释放模型上下文。幂等。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) {
      WhisperFfi.instance.free(ctx);
    }
  }
}
