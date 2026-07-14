// lib/services/llm/llama_cpp_engine.dart
//
// GGUF 文本 LLM 推理引擎封装，基于 LlamaCppFfi。
//
// 用于文本生成（翻译/纠错/摘要）：load + generate 流式生成。
//
// 线程安全：当前为同步实现，FFI 调用在调用线程执行。

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:nota/services/llm/llama_cpp_ffi.dart';

/// GGUF 文本 LLM 推理引擎。
///
/// 封装 llama.cpp C API，提供文本生成推理（load + generate）。
class LlamaCppEngine {
  LlamaCppEngine() : _ffi = LlamaCppFfi();

  final LlamaCppFfi _ffi;

  // 原生资源句柄
  Pointer<llama_model>? _model;
  Pointer<llama_context>? _ctx;
  Pointer<llama_vocab>? _vocab;
  Pointer<llama_sampler>? _sampler;

  /// llama.cpp backend 是进程级全局资源，多个 LlamaCppEngine 实例共享。
  /// 用静态标志避免重复 init，dispose 时也不释放（仅 app 退出时由
  /// [disposeBackend] 静态方法统一释放），防止一个实例 dispose 破坏其他实例。
  static bool _backendInitialized = false;
  bool _isTextModelLoaded = false;
  bool _disposed = false;

  // --- 状态查询 ---

  bool get isLoaded => _isTextModelLoaded;
  bool get isTextModelLoaded => _isTextModelLoaded;
  bool get isDisposed => _disposed;

  /// 获取模型描述（如 "Qwen3 1.7B Q6_K"）
  String get modelDesc {
    if (_model == null) return '<not loaded>';
    final buf = malloc<Uint8>(256);
    try {
      final len = _ffi.llamaModelDesc(_model!, buf.cast<Utf8>(), 256);
      if (len <= 0) return '<unknown>';
      return buf.cast<Utf8>().toDartString(length: len);
    } finally {
      malloc.free(buf);
    }
  }

  /// 获取上下文长度
  int get nCtx {
    if (_ctx == null) return 0;
    return _ffi.llamaNCtx(_ctx!);
  }

  // --- 内部初始化 ---

  void _ensureBackend() {
    if (!_backendInitialized) {
      _ffi.llamaBackendInit();
      _backendInitialized = true;
      _staticFfi = _ffi; // 记录供 disposeBackend 使用
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('LlamaCppEngine has been disposed');
    }
  }

  // ========================================================================
  // 文本 LLM 推理
  // ========================================================================

  /// 加载 GGUF 文本模型。
  ///
  /// [modelPath] GGUF 文件路径
  /// [nCtx] 上下文长度（默认 2048）
  /// [nThreads] 推理线程数（默认 4）
  Future<void> load(String modelPath,
      {int nCtx = 2048, int nThreads = 4}) async {
    _ensureNotDisposed();
    if (_isTextModelLoaded) {
      throw StateError('文本模型已加载，请先 dispose 再重新加载');
    }

    _ensureBackend();

    // 模型参数
    final modelParams = _ffi.llamaModelDefaultParams();
    modelParams.nGpuLayers = 0; // CPU only（移动端无 GPU offload）
    modelParams.useMmap = true;
    modelParams.vocabOnly = false;

    final modelPathC = modelPath.toNativeUtf8();
    try {
      _model = _ffi.llamaModelLoadFromFile(modelPathC, modelParams);
      if (_model == null || _model!.address == 0) {
        throw StateError('模型加载失败: $modelPath');
      }
    } finally {
      malloc.free(modelPathC);
    }

    _vocab = _ffi.llamaModelGetVocab(_model!);

    // 上下文参数
    final ctxParams = _ffi.llamaContextDefaultParams();
    ctxParams.nCtx = nCtx;
    ctxParams.nBatch = nCtx;
    ctxParams.nThreads = nThreads;
    ctxParams.nThreadsBatch = nThreads;
    ctxParams.embeddings = false;

    _ctx = _ffi.llamaInitFromModel(_model!, ctxParams);
    if (_ctx == null || _ctx!.address == 0) {
      _ffi.llamaModelFree(_model!);
      _model = null;
      _vocab = null;
      throw StateError('上下文创建失败: $modelPath');
    }

    // 采样器：贪心采样（简单高效，适合笔记/转写场景）
    _sampler = _ffi.llamaSamplerInitGreedy();

    _isTextModelLoaded = true;
  }

  /// 流式生成文本。
  ///
  /// [prompt] 输入提示词
  /// [onToken] 每生成一个 token 的回调
  /// [maxTokens] 最大生成 token 数（默认 512）
  /// [addBos] 是否添加 BOS token（默认 true）
  ///
  /// 返回完整生成的文本。
  String generate(String prompt,
      {void Function(String token)? onToken, int maxTokens = 512, bool addBos = true}) {
    _ensureNotDisposed();
    if (!_isTextModelLoaded) {
      throw StateError('文本模型未加载，请先调用 load()');
    }

    final result = StringBuffer();

    // 1. tokenize prompt
    final tokens = _tokenize(prompt, addSpecial: addBos);
    if (tokens.isEmpty) return '';

    // 2. 清空 KV cache
    _ffi.llamaMemorySeqRm(_ctx!, 0, 0, -1);

    // 3. prompt processing: decode 全部 prompt token
    _decodeTokens(tokens, logitsLast: false);

    // 4. 逐 token 生成
    for (int i = 0; i < maxTokens; i++) {
      final newToken = _ffi.llamaSamplerSample(_sampler!, _ctx!, -1);
      if (_ffi.llamaVocabIsEog(_vocab!, newToken)) break;

      final piece = _tokenToPiece(newToken);
      if (piece.isNotEmpty) {
        result.write(piece);
        onToken?.call(piece);
      }

      // decode 新 token
      _decodeTokens([newToken], logitsLast: true);
    }

    return result.toString();
  }

  // ========================================================================
  // 资源释放
  // ========================================================================

  /// 释放所有资源。
  void dispose() {
    if (_disposed) return;

    if (_sampler != null) {
      _ffi.llamaSamplerFree(_sampler!);
      _sampler = null;
    }
    if (_ctx != null) {
      _ffi.llamaFree(_ctx!);
      _ctx = null;
    }
    if (_model != null) {
      _ffi.llamaModelFree(_model!);
      _model = null;
    }
    _vocab = null;

    // 注意：不在此处释放 backend。llama.cpp backend 是进程级全局资源，
    // 多个 LlamaCppEngine 实例共享，单实例 dispose 释放会破坏其他实例。
    // backend 释放由 [disposeBackend] 静态方法在 app 退出时统一调用。

    _isTextModelLoaded = false;
    _disposed = true;
  }

  /// 释放进程级 llama.cpp backend（仅在 app 退出时调用）。
  ///
  /// 多个 LlamaCppEngine 实例共享同一 backend，单实例 [dispose] 不释放 backend，
  /// 避免一个实例释放破坏其他仍在使用的实例。app 退出时调用此静态方法统一释放。
  static void disposeBackend() {
    if (_backendInitialized) {
      // 用全局 FFI 绑定调用（_ffi 是实例字段，但 backend free 是全局操作，
      // 任意一个未 dispose 的实例的 _ffi 都可调用）
      // 这里通过创建临时实例拿不到 _ffi，故用顶层函数方式。
      // 实际上 _ffi 是实例字段，但所有实例的 _ffi 指向同一份绑定，
      // 这里借用任一实例调用即可。为简化，用静态字段记录上次使用的 ffi。
      _staticFfi?.llamaBackendFree();
      _backendInitialized = false;
    }
  }

  /// 静态 FFI 引用，供 [disposeBackend] 使用（首次 init 时记录）。
  static LlamaCppFfi? _staticFfi;

  // ========================================================================
  // 内部工具方法
  // ========================================================================

  /// 文本 → token 数组（两次调用模式：先查长度再分配）
  List<int> _tokenize(String text, {bool addSpecial = true}) {
    final textC = text.toNativeUtf8();
    try {
      // 第一次调用：获取所需 token 数（返回负数 = 所需数量）
      final nRequired = _ffi.llamaTokenize(
          _vocab!, textC, textC.length, nullptr, 0, addSpecial, true);
      if (nRequired <= 0) return [];

      // 分配 buffer
      final tokensBuf = malloc<Int32>(nRequired);
      try {
        // 第二次调用：实际 tokenize
        final nTokens = _ffi.llamaTokenize(_vocab!, textC, textC.length,
            tokensBuf, nRequired, addSpecial, true);
        if (nTokens <= 0) return [];

        // 复制到 Dart List
        return tokensBuf.asTypedList(nTokens).toList();
      } finally {
        malloc.free(tokensBuf);
      }
    } finally {
      malloc.free(textC);
    }
  }

  /// token → 文本片段（两次调用模式：先查长度再分配）
  String _tokenToPiece(int token) {
    // 第一次调用：获取所需字节数（返回负数 = 所需数量）
    final nRequired = _ffi.llamaTokenToPiece(
        _vocab!, token, nullptr, 0, 0, true);
    if (nRequired >= 0) return ''; // 0 = 空 token

    final bufSize = -nRequired;
    final buf = malloc<Uint8>(bufSize);
    try {
      // 第二次调用：实际转换
      final nBytes = _ffi.llamaTokenToPiece(
          _vocab!, token, buf.cast<Utf8>(), bufSize, 0, true);
      if (nBytes <= 0) return '';
      return buf.cast<Utf8>().toDartString(length: nBytes);
    } finally {
      malloc.free(buf);
    }
  }

  /// decode 一组 token（用 llama_batch_get_one 构建批次）
  void _decodeTokens(List<int> tokens, {bool logitsLast = true}) {
    if (tokens.isEmpty) return;

    // 分配 C 内存存放 token 数组
    final tokensC = malloc<Int32>(tokens.length);
    for (int i = 0; i < tokens.length; i++) {
      tokensC[i] = tokens[i];
    }

    try {
      // 构建批次（token 指针指向 tokensC）
      final batch = _ffi.llamaBatchGetOne(tokensC, tokens.length);

      // decode
      final ret = _ffi.llamaDecode(_ctx!, batch);
      if (ret != 0) {
        throw StateError('llama_decode 失败: ret=$ret (0=ok, 1=KV full, 2=aborted, -1=invalid batch)');
      }
    } finally {
      malloc.free(tokensC);
    }
  }
}
