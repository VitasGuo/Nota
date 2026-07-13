// lib/services/asr/whisper_ffi.dart
//
// whisper.cpp 的 Dart FFI 绑定。
//
// 绑定 libwhisper_android.so 中的简化 API（whisper_simple_*），
// 避免在 Dart 侧定义复杂的 whisper_full_params 结构体。
//
// .so 编译方式见 tool/whisper-build/CMakeLists.txt

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// whisper_simple_segment 的 Dart 映射。
///
/// 对应 C 结构体：
/// ```c
/// typedef struct {
///     const char* text;   // 段文本（指向 ctx 内部内存，ctx free 后失效）
///     int64_t t0;         // 起始时间（厘秒 = 10ms）
///     int64_t t1;         // 结束时间（厘秒 = 10ms）
/// } whisper_simple_segment;
/// ```
final class WhisperSimpleSegment extends Struct {
  external Pointer<Utf8> text;
  @Int64() external int t0;
  @Int64() external int t1;
}

/// whisper.cpp FFI 绑定。
///
/// 加载 libwhisper_android.so 并绑定 3 个简化函数。
/// 单例：全局只加载一次 .so。
class WhisperFfi {
  WhisperFfi._() {
    _lib = DynamicLibrary.open('libwhisper_android.so');
    _init = _lib.lookupFunction<
        Pointer<NativeType> Function(Pointer<Utf8>),
        Pointer<NativeType> Function(Pointer<Utf8>)>('whisper_simple_init');
    _transcribe = _lib.lookupFunction<
        Int32 Function(
          Pointer<NativeType>,
          Pointer<Float>,
          Int32,
          Pointer<Utf8>,
          Int32,
          Pointer<WhisperSimpleSegment>,
          Int32,
        ),
        int Function(
          Pointer<NativeType>,
          Pointer<Float>,
          int,
          Pointer<Utf8>,
          int,
          Pointer<WhisperSimpleSegment>,
          int,
        )>('whisper_simple_transcribe');
    _free = _lib.lookupFunction<
        Void Function(Pointer<NativeType>),
        void Function(Pointer<NativeType>)>('whisper_simple_free');
  }

  static final WhisperFfi instance = WhisperFfi._();

  late final DynamicLibrary _lib;
  late final Pointer<NativeType> Function(Pointer<Utf8>) _init;
  late final int Function(
    Pointer<NativeType>,
    Pointer<Float>,
    int,
    Pointer<Utf8>,
    int,
    Pointer<WhisperSimpleSegment>,
    int,
  ) _transcribe;
  late final void Function(Pointer<NativeType>) _free;

  /// 加载模型。返回不透明上下文指针（null 表示失败）。
  Pointer<NativeType> init(String modelPath) {
    final pathC = modelPath.toNativeUtf8();
    try {
      return _init(pathC);
    } finally {
      malloc.free(pathC);
    }
  }

  /// 转写音频。
  ///
  /// [ctx] 模型上下文
  /// [samples] PCM F32 16kHz 单声道
  /// [language] 语言代码（"auto"/"zh"/"en"/"ja"/"ko" 等）
  /// [nThreads] 推理线程数
  ///
  /// 返回转写段列表（text + t0 + t1）。段文本指针在 ctx free 后失效，
  /// 调用方应立即复制文本。
  List<({String text, double startSec, double endSec})> transcribe(
    Pointer<NativeType> ctx,
    Float32List samples,
    String language,
    int nThreads,
  ) {
    // 分配 PCM 数据
    final samplesPtr = malloc<Float>(samples.length);
    samplesPtr.asTypedList(samples.length).setAll(0, samples);

    // 分配语言字符串
    final langC = language.toNativeUtf8();

    // 分配段输出缓冲（最多 64 段）
    const maxSegments = 64;
    final segPtr = malloc<WhisperSimpleSegment>(maxSegments);

    try {
      final n = _transcribe(
        ctx,
        samplesPtr,
        samples.length,
        langC,
        nThreads,
        segPtr,
        maxSegments,
      );

      if (n < 0) {
        throw StateError('whisper_simple_transcribe 失败: ret=$n');
      }

      // 立即复制结果（text 指针在 ctx free 后失效）
      final result = <({String text, double startSec, double endSec})>[];
      for (int i = 0; i < n; i++) {
        final seg = segPtr[i];
        final text = seg.text.toDartString();
        // t0/t1 单位是厘秒（10ms），转换为秒
        result.add((
          text: text,
          startSec: seg.t0 / 100.0,
          endSec: seg.t1 / 100.0,
        ));
      }
      return result;
    } finally {
      malloc.free(samplesPtr);
      malloc.free(langC);
      malloc.free(segPtr);
    }
  }

  /// 释放模型上下文。
  void free(Pointer<NativeType> ctx) {
    _free(ctx);
  }
}
