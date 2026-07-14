// lib/services/llm/llama_cpp_ffi.dart
//
// llama.cpp C API 的 Dart FFI 绑定（仅文本 LLM 推理）。
//
// 覆盖：
// - llama backend / model / context / batch / decode / logits
// - llama sampler chain / greedy / sample
// - llama vocab / tokenize / token_to_piece / is_eog
//
// 原生库来源：llama.cpp 交叉编译为 Android arm64-v8a .so（见 process.md v0.4.3 基础设施）
// - libllama.so：llama_* 函数（依赖 libggml.so → libggml-cpu.so → libggml-base.so）
//
// 类型名保持 snake_case 以匹配 C 头文件命名（FFI 绑定惯例），便于与 llama.h 对照。

// ignore_for_file: camel_case_types

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ============================================================================
// 1. 不透明类型（Opaque）—— C 中前向声明的 struct，Dart 侧只需指针
// ============================================================================

final class llama_model extends Opaque {}
final class llama_context extends Opaque {}
final class llama_vocab extends Opaque {}
final class llama_sampler extends Opaque {}
final class llama_memory_i extends Opaque {}

// ============================================================================
// 2. 枚举常量（C enum 在 Dart FFI 中用 int 表示）
// ============================================================================

// enum llama_split_mode
const int kLlamaSplitModeNone = 0;
const int kLlamaSplitModeLayer = 1;
const int kLlamaSplitModeRow = 2;
const int kLlamaSplitModeTensor = 3;

// enum llama_flash_attn_type
const int kLlamaFlashAttnTypeAuto = -1;
const int kLlamaFlashAttnTypeDisabled = 0;
const int kLlamaFlashAttnTypeEnabled = 1;

// enum llama_rope_scaling_type
const int kLlamaRopeScalingTypeUnspecified = -1;
const int kLlamaRopeScalingTypeNone = 0;
const int kLlamaRopeScalingTypeLinear = 1;
const int kLlamaRopeScalingTypeYarn = 2;
const int kLlamaRopeScalingTypeLongrope = 3;

// enum llama_pooling_type
const int kLlamaPoolingTypeUnspecified = -1;
const int kLlamaPoolingTypeNone = 0;
const int kLlamaPoolingTypeMean = 1;
const int kLlamaPoolingTypeCls = 2;
const int kLlamaPoolingTypeLast = 3;
const int kLlamaPoolingTypeRank = 4;

// enum llama_attention_type
const int kLlamaAttentionTypeUnspecified = -1;
const int kLlamaAttentionTypeCausal = 0;
const int kLlamaAttentionTypeNonCausal = 1;

// enum llama_context_type
const int kLlamaContextTypeDefault = 0;
const int kLlamaContextTypeMtp = 1;

// ============================================================================
// 3. 回调函数类型
// ============================================================================

// typedef bool (*llama_progress_callback)(float progress, void * user_data);
typedef llama_progress_callback_native
    = Bool Function(Float progress, Pointer<Void> userData);

// typedef bool (*ggml_abort_callback)(void * data);
typedef ggml_abort_callback_native
    = Bool Function(Pointer<Void> data);

// ============================================================================
// 4. Struct 定义——精确匹配 C 内存布局（Dart FFI 自动处理 alignment/padding）
// ============================================================================

/// llama_batch —— 按值传递的批次结构体（llama_decode / llama_batch_init / llama_batch_free）
///
/// ```c
/// typedef struct llama_batch {
///     int32_t n_tokens;
///     llama_token  *  token;      // int32_t *
///     float        *  embd;
///     llama_pos    *  pos;        // int32_t *
///     int32_t      *  n_seq_id;
///     llama_seq_id ** seq_id;     // int32_t **
///     int8_t       *  logits;
/// } llama_batch;
/// ```
final class llama_batch extends Struct {
  @Int32()
  external int nTokens;

  external Pointer<Int32> token;

  external Pointer<Float> embd;

  external Pointer<Int32> pos;

  external Pointer<Int32> nSeqId;

  external Pointer<Pointer<Int32>> seqId;

  external Pointer<Int8> logits;
}

/// llama_sampler_chain_params —— 仅含 1 个 bool
///
/// ```c
/// typedef struct llama_sampler_chain_params {
///     bool no_perf;
/// } llama_sampler_chain_params;
/// ```
final class llama_sampler_chain_params extends Struct {
  @Bool()
  external bool noPerf;
}

/// llama_model_params —— 模型加载参数（通过 llama_model_default_params() 获取默认值）
///
/// ```c
/// struct llama_model_params {
///     ggml_backend_dev_t * devices;
///     const struct llama_model_tensor_buft_override * tensor_buft_overrides;
///     int32_t n_gpu_layers;
///     enum llama_split_mode split_mode;
///     int32_t main_gpu;
///     const float * tensor_split;
///     llama_progress_callback progress_callback;
///     void * progress_callback_user_data;
///     const struct llama_model_kv_override * kv_overrides;
///     bool vocab_only, use_mmap, use_direct_io, use_mlock, check_tensors, use_extra_bufts, no_host, no_alloc;
/// };
/// ```
final class llama_model_params extends Struct {
  external Pointer<Pointer<Void>> devices;

  external Pointer<Void> tensorBuftOverrides;

  @Int32()
  external int nGpuLayers;

  @Int32()
  external int splitMode;

  @Int32()
  external int mainGpu;

  external Pointer<Float> tensorSplit;

  external Pointer<NativeFunction<llama_progress_callback_native>>
      progressCallback;

  external Pointer<Void> progressCallbackUserData;

  external Pointer<Void> kvOverrides;

  @Bool()
  external bool vocabOnly;

  @Bool()
  external bool useMmap;

  @Bool()
  external bool useDirectIo;

  @Bool()
  external bool useMlock;

  @Bool()
  external bool checkTensors;

  @Bool()
  external bool useExtraBufts;

  @Bool()
  external bool noHost;

  @Bool()
  external bool noAlloc;
}

/// llama_context_params —— 上下文参数（通过 llama_context_default_params() 获取默认值）
///
/// ```c
/// struct llama_context_params {
///     uint32_t n_ctx, n_batch, n_ubatch, n_seq_max, n_rs_seq, n_outputs_max;
///     int32_t n_threads, n_threads_batch;
///     enum llama_context_type ctx_type;
///     enum llama_rope_scaling_type rope_scaling_type;
///     enum llama_pooling_type pooling_type;
///     enum llama_attention_type attention_type;
///     enum llama_flash_attn_type flash_attn_type;
///     float rope_freq_base, rope_freq_scale, yarn_ext_factor, yarn_attn_factor, yarn_beta_fast, yarn_beta_slow;
///     uint32_t yarn_orig_ctx;
///     float defrag_thold;
///     ggml_backend_sched_eval_callback cb_eval;
///     void * cb_eval_user_data;
///     enum ggml_type type_k, type_v;
///     ggml_abort_callback abort_callback;
///     void * abort_callback_data;
///     bool embeddings, offload_kqv, no_perf, op_offload, swa_full, kv_unified;
///     struct llama_sampler_seq_config * samplers;
///     size_t n_samplers;
///     struct llama_context * ctx_other;
/// };
/// ```
final class llama_context_params extends Struct {
  @Uint32()
  external int nCtx;

  @Uint32()
  external int nBatch;

  @Uint32()
  external int nUbatch;

  @Uint32()
  external int nSeqMax;

  @Uint32()
  external int nRsSeq;

  @Uint32()
  external int nOutputsMax;

  @Int32()
  external int nThreads;

  @Int32()
  external int nThreadsBatch;

  @Int32()
  external int ctxType;

  @Int32()
  external int ropeScalingType;

  @Int32()
  external int poolingType;

  @Int32()
  external int attentionType;

  @Int32()
  external int flashAttnType;

  @Float()
  external double ropeFreqBase;

  @Float()
  external double ropeFreqScale;

  @Float()
  external double yarnExtFactor;

  @Float()
  external double yarnAttnFactor;

  @Float()
  external double yarnBetaFast;

  @Float()
  external double yarnBetaSlow;

  @Uint32()
  external int yarnOrigCtx;

  @Float()
  external double defragThold;

  external Pointer<Void> cbEval; // ggml_backend_sched_eval_callback

  external Pointer<Void> cbEvalUserData;

  @Int32()
  external int typeK; // enum ggml_type

  @Int32()
  external int typeV; // enum ggml_type

  external Pointer<NativeFunction<ggml_abort_callback_native>>
      abortCallback;

  external Pointer<Void> abortCallbackData;

  @Bool()
  external bool embeddings;

  @Bool()
  external bool offloadKqv;

  @Bool()
  external bool noPerf;

  @Bool()
  external bool opOffload;

  @Bool()
  external bool swaFull;

  @Bool()
  external bool kvUnified;

  external Pointer<Void> samplers; // struct llama_sampler_seq_config *

  @IntPtr()
  external int nSamplers; // size_t

  external Pointer<llama_context> ctxOther;
}

// ============================================================================
// 5. C/Dart 函数签名 typedef
// ============================================================================

// --- llama backend ---

typedef _llama_backend_init_native = Void Function();
typedef _llama_backend_init_dart = void Function();

typedef _llama_backend_free_native = Void Function();
typedef _llama_backend_free_dart = void Function();

// --- model params ---

typedef _llama_model_default_params_native
    = llama_model_params Function();
typedef _llama_model_default_params_dart
    = llama_model_params Function();

typedef _llama_model_load_from_file_native
    = Pointer<llama_model> Function(Pointer<Utf8> pathModel, llama_model_params params);
typedef _llama_model_load_from_file_dart
    = Pointer<llama_model> Function(Pointer<Utf8> pathModel, llama_model_params params);

typedef _llama_model_free_native = Void Function(Pointer<llama_model> model);
typedef _llama_model_free_dart = void Function(Pointer<llama_model> model);

typedef _llama_model_get_vocab_native
    = Pointer<llama_vocab> Function(Pointer<llama_model> model);
typedef _llama_model_get_vocab_dart
    = Pointer<llama_vocab> Function(Pointer<llama_model> model);

typedef _llama_model_n_ctx_train_native
    = Int32 Function(Pointer<llama_model> model);
typedef _llama_model_n_ctx_train_dart
    = int Function(Pointer<llama_model> model);

typedef _llama_model_n_embd_native
    = Int32 Function(Pointer<llama_model> model);
typedef _llama_model_n_embd_dart
    = int Function(Pointer<llama_model> model);

typedef _llama_model_n_embd_inp_native
    = Int32 Function(Pointer<llama_model> model);
typedef _llama_model_n_embd_inp_dart
    = int Function(Pointer<llama_model> model);

typedef _llama_model_desc_native
    = Int32 Function(Pointer<llama_model> model, Pointer<Utf8> buf, IntPtr bufSize);
typedef _llama_model_desc_dart
    = int Function(Pointer<llama_model> model, Pointer<Utf8> buf, int bufSize);

// --- context params ---

typedef _llama_context_default_params_native
    = llama_context_params Function();
typedef _llama_context_default_params_dart
    = llama_context_params Function();

typedef _llama_init_from_model_native
    = Pointer<llama_context> Function(Pointer<llama_model> model, llama_context_params params);
typedef _llama_init_from_model_dart
    = Pointer<llama_context> Function(Pointer<llama_model> model, llama_context_params params);

typedef _llama_free_native = Void Function(Pointer<llama_context> ctx);
typedef _llama_free_dart = void Function(Pointer<llama_context> ctx);

typedef _llama_n_ctx_native = Uint32 Function(Pointer<llama_context> ctx);
typedef _llama_n_ctx_dart = int Function(Pointer<llama_context> ctx);

typedef _llama_synchronize_native = Void Function(Pointer<llama_context> ctx);
typedef _llama_synchronize_dart = void Function(Pointer<llama_context> ctx);

typedef _llama_set_n_threads_native
    = Void Function(Pointer<llama_context> ctx, Int32 nThreads, Int32 nThreadsBatch);
typedef _llama_set_n_threads_dart
    = void Function(Pointer<llama_context> ctx, int nThreads, int nThreadsBatch);

typedef _llama_set_causal_attn_native
    = Void Function(Pointer<llama_context> ctx, Bool causalAttn);
typedef _llama_set_causal_attn_dart
    = void Function(Pointer<llama_context> ctx, bool causalAttn);

// --- batch ---

typedef _llama_batch_init_native
    = llama_batch Function(Int32 nTokens, Int32 embd, Int32 nSeqMax);
typedef _llama_batch_init_dart
    = llama_batch Function(int nTokens, int embd, int nSeqMax);

typedef _llama_batch_free_native = Void Function(llama_batch batch);
typedef _llama_batch_free_dart = void Function(llama_batch batch);

typedef _llama_batch_get_one_native
    = llama_batch Function(Pointer<Int32> tokens, Int32 nTokens);
typedef _llama_batch_get_one_dart
    = llama_batch Function(Pointer<Int32> tokens, int nTokens);

// --- decode / logits ---

typedef _llama_decode_native
    = Int32 Function(Pointer<llama_context> ctx, llama_batch batch);
typedef _llama_decode_dart
    = int Function(Pointer<llama_context> ctx, llama_batch batch);

typedef _llama_get_logits_native
    = Pointer<Float> Function(Pointer<llama_context> ctx);
typedef _llama_get_logits_dart
    = Pointer<Float> Function(Pointer<llama_context> ctx);

typedef _llama_get_logits_ith_native
    = Pointer<Float> Function(Pointer<llama_context> ctx, Int32 i);
typedef _llama_get_logits_ith_dart
    = Pointer<Float> Function(Pointer<llama_context> ctx, int i);

// --- memory / KV cache ---

typedef _llama_memory_seq_rm_native
    = Bool Function(Pointer<llama_context> ctx, Int32 seqId, Int32 p0, Int32 p1);
typedef _llama_memory_seq_rm_dart
    = bool Function(Pointer<llama_context> ctx, int seqId, int p0, int p1);

typedef _llama_memory_seq_cp_native
    = Void Function(Pointer<llama_context> ctx, Int32 src, Int32 dst);
typedef _llama_memory_seq_cp_dart
    = void Function(Pointer<llama_context> ctx, int src, int dst);

// --- vocab / tokenize ---

typedef _llama_vocab_n_tokens_native
    = Int32 Function(Pointer<llama_vocab> vocab);
typedef _llama_vocab_n_tokens_dart
    = int Function(Pointer<llama_vocab> vocab);

typedef _llama_vocab_is_eog_native
    = Bool Function(Pointer<llama_vocab> vocab, Int32 token);
typedef _llama_vocab_is_eog_dart
    = bool Function(Pointer<llama_vocab> vocab, int token);

typedef _llama_tokenize_native = Int32 Function(
    Pointer<llama_vocab> vocab,
    Pointer<Utf8> text,
    Int32 textLen,
    Pointer<Int32> tokens,
    Int32 nTokensMax,
    Bool addSpecial,
    Bool parseSpecial);
typedef _llama_tokenize_dart = int Function(
    Pointer<llama_vocab> vocab,
    Pointer<Utf8> text,
    int textLen,
    Pointer<Int32> tokens,
    int nTokensMax,
    bool addSpecial,
    bool parseSpecial);

typedef _llama_token_to_piece_native = Int32 Function(
    Pointer<llama_vocab> vocab,
    Int32 token,
    Pointer<Utf8> buf,
    Int32 length,
    Int32 lstrip,
    Bool special);
typedef _llama_token_to_piece_dart = int Function(
    Pointer<llama_vocab> vocab,
    int token,
    Pointer<Utf8> buf,
    int length,
    int lstrip,
    bool special);

// --- sampler ---

typedef _llama_sampler_chain_default_params_native
    = llama_sampler_chain_params Function();
typedef _llama_sampler_chain_default_params_dart
    = llama_sampler_chain_params Function();

typedef _llama_sampler_chain_init_native
    = Pointer<llama_sampler> Function(llama_sampler_chain_params params);
typedef _llama_sampler_chain_init_dart
    = Pointer<llama_sampler> Function(llama_sampler_chain_params params);

typedef _llama_sampler_free_native
    = Void Function(Pointer<llama_sampler> smpl);
typedef _llama_sampler_free_dart
    = void Function(Pointer<llama_sampler> smpl);

typedef _llama_sampler_init_greedy_native
    = Pointer<llama_sampler> Function();
typedef _llama_sampler_init_greedy_dart
    = Pointer<llama_sampler> Function();

typedef _llama_sampler_sample_native
    = Int32 Function(Pointer<llama_sampler> smpl, Pointer<llama_context> ctx, Int32 idx);
typedef _llama_sampler_sample_dart
    = int Function(Pointer<llama_sampler> smpl, Pointer<llama_context> ctx, int idx);

// ============================================================================
// 6. LlamaCppFfi —— DynamicLibrary 加载 + 函数绑定
// ============================================================================

/// llama.cpp C API 的 Dart FFI 绑定（仅文本 LLM 推理）。
///
/// 加载 jniLibs 中的 libllama.so，查找所有需要的 C 函数。
/// 使用方式：
/// ```dart
/// final ffi = LlamaCppFfi();
/// ffi.llamaBackendInit();
/// ```
class LlamaCppFfi {
  LlamaCppFfi._(this._llamaLib);

  static LlamaCppFfi? _instance;

  /// 单例访问。首次调用时加载原生库。
  factory LlamaCppFfi() {
    _instance ??= _load();
    return _instance!;
  }

  final DynamicLibrary _llamaLib;

  static LlamaCppFfi _load() {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError(
          'LlamaCppFfi 仅支持 Android/Linux/Windows/macOS，当前平台: ${Platform.operatingSystem}');
    }

    // 先加载底层依赖，再加载上层库。
    // Android jniLibs 中的 .so 会被打包到 APK 的 lib/{abi}/ 目录，
    // DynamicLibrary.open 在应用 nativeLibraryDir 中查找。
    // dlopen 会自动加载 NEEDED 依赖，但显式加载可确保顺序 + 获取句柄。
    DynamicLibrary llamaLib;

    if (Platform.isAndroid) {
      // Android：先加载底层 ggml 库（避免依赖查找失败），再加载 libllama.so
      // 依赖链：libllama.so → libggml.so → libggml-cpu.so → libggml-base.so
      try {
        DynamicLibrary.open('libggml-base.so');
        DynamicLibrary.open('libggml-cpu.so');
        DynamicLibrary.open('libggml.so');
      } catch (e) {
        // 底层库可能已被自动加载，忽略错误
      }
      llamaLib = DynamicLibrary.open('libllama.so');
    } else if (Platform.isLinux) {
      llamaLib = DynamicLibrary.open('libllama.so');
    } else if (Platform.isWindows) {
      llamaLib = DynamicLibrary.open('llama.dll');
    } else {
      // macOS
      llamaLib = DynamicLibrary.open('libllama.dylib');
    }

    return LlamaCppFfi._(llamaLib);
  }

  // --- llama backend ---

  late final void Function() llamaBackendInit = _llamaLib
      .lookupFunction<_llama_backend_init_native, _llama_backend_init_dart>(
          'llama_backend_init');

  late final void Function() llamaBackendFree = _llamaLib
      .lookupFunction<_llama_backend_free_native, _llama_backend_free_dart>(
          'llama_backend_free');

  // --- model params ---

  late final llama_model_params Function() llamaModelDefaultParams =
      _llamaLib.lookupFunction<_llama_model_default_params_native,
              _llama_model_default_params_dart>(
          'llama_model_default_params');

  late final Pointer<llama_model> Function(Pointer<Utf8>, llama_model_params)
      llamaModelLoadFromFile = _llamaLib.lookupFunction<
              _llama_model_load_from_file_native,
              _llama_model_load_from_file_dart>(
          'llama_model_load_from_file');

  late final void Function(Pointer<llama_model>) llamaModelFree = _llamaLib
      .lookupFunction<_llama_model_free_native, _llama_model_free_dart>(
          'llama_model_free');

  late final Pointer<llama_vocab> Function(Pointer<llama_model>)
      llamaModelGetVocab = _llamaLib.lookupFunction<
              _llama_model_get_vocab_native, _llama_model_get_vocab_dart>(
          'llama_model_get_vocab');

  late final int Function(Pointer<llama_model>) llamaModelNCtxTrain =
      _llamaLib.lookupFunction<_llama_model_n_ctx_train_native,
              _llama_model_n_ctx_train_dart>('llama_model_n_ctx_train');

  late final int Function(Pointer<llama_model>) llamaModelNEmbd = _llamaLib
      .lookupFunction<_llama_model_n_embd_native, _llama_model_n_embd_dart>(
          'llama_model_n_embd');

  late final int Function(Pointer<llama_model>) llamaModelNEmbdInp =
      _llamaLib.lookupFunction<_llama_model_n_embd_inp_native,
              _llama_model_n_embd_inp_dart>('llama_model_n_embd_inp');

  late final int Function(Pointer<llama_model>, Pointer<Utf8>, int)
      llamaModelDesc = _llamaLib.lookupFunction<_llama_model_desc_native,
              _llama_model_desc_dart>('llama_model_desc');

  // --- context params ---

  late final llama_context_params Function() llamaContextDefaultParams =
      _llamaLib.lookupFunction<_llama_context_default_params_native,
              _llama_context_default_params_dart>(
          'llama_context_default_params');

  late final Pointer<llama_context> Function(
          Pointer<llama_model>, llama_context_params) llamaInitFromModel =
      _llamaLib.lookupFunction<_llama_init_from_model_native,
              _llama_init_from_model_dart>('llama_init_from_model');

  late final void Function(Pointer<llama_context>) llamaFree = _llamaLib
      .lookupFunction<_llama_free_native, _llama_free_dart>('llama_free');

  late final int Function(Pointer<llama_context>) llamaNCtx = _llamaLib
      .lookupFunction<_llama_n_ctx_native, _llama_n_ctx_dart>('llama_n_ctx');

  late final void Function(Pointer<llama_context>) llamaSynchronize =
      _llamaLib.lookupFunction<_llama_synchronize_native,
              _llama_synchronize_dart>('llama_synchronize');

  late final void Function(Pointer<llama_context>, int, int)
      llamaSetNThreads = _llamaLib.lookupFunction<_llama_set_n_threads_native,
              _llama_set_n_threads_dart>('llama_set_n_threads');

  late final void Function(Pointer<llama_context>, bool) llamaSetCausalAttn =
      _llamaLib.lookupFunction<_llama_set_causal_attn_native,
              _llama_set_causal_attn_dart>('llama_set_causal_attn');

  // --- batch ---

  late final llama_batch Function(int, int, int) llamaBatchInit = _llamaLib
      .lookupFunction<_llama_batch_init_native, _llama_batch_init_dart>(
          'llama_batch_init');

  late final void Function(llama_batch) llamaBatchFree = _llamaLib
      .lookupFunction<_llama_batch_free_native, _llama_batch_free_dart>(
          'llama_batch_free');

  late final llama_batch Function(Pointer<Int32>, int) llamaBatchGetOne =
      _llamaLib.lookupFunction<_llama_batch_get_one_native,
              _llama_batch_get_one_dart>('llama_batch_get_one');

  // --- decode / logits ---

  late final int Function(Pointer<llama_context>, llama_batch) llamaDecode =
      _llamaLib.lookupFunction<_llama_decode_native, _llama_decode_dart>(
          'llama_decode');

  late final Pointer<Float> Function(Pointer<llama_context>) llamaGetLogits =
      _llamaLib.lookupFunction<_llama_get_logits_native,
              _llama_get_logits_dart>('llama_get_logits');

  late final Pointer<Float> Function(Pointer<llama_context>, int)
      llamaGetLogitsIth = _llamaLib.lookupFunction<_llama_get_logits_ith_native,
              _llama_get_logits_ith_dart>('llama_get_logits_ith');

  // --- memory / KV cache ---

  late final bool Function(Pointer<llama_context>, int, int, int)
      llamaMemorySeqRm = _llamaLib.lookupFunction<_llama_memory_seq_rm_native,
              _llama_memory_seq_rm_dart>('llama_memory_seq_rm');

  late final void Function(Pointer<llama_context>, int, int)
      llamaMemorySeqCp = _llamaLib.lookupFunction<_llama_memory_seq_cp_native,
              _llama_memory_seq_cp_dart>('llama_memory_seq_cp');

  // --- vocab / tokenize ---

  late final int Function(Pointer<llama_vocab>) llamaVocabNTokens = _llamaLib
      .lookupFunction<_llama_vocab_n_tokens_native,
              _llama_vocab_n_tokens_dart>('llama_vocab_n_tokens');

  late final bool Function(Pointer<llama_vocab>, int) llamaVocabIsEog =
      _llamaLib.lookupFunction<_llama_vocab_is_eog_native,
              _llama_vocab_is_eog_dart>('llama_vocab_is_eog');

  late final int Function(Pointer<llama_vocab>, Pointer<Utf8>, int,
          Pointer<Int32>, int, bool, bool) llamaTokenize =
      _llamaLib.lookupFunction<_llama_tokenize_native, _llama_tokenize_dart>(
          'llama_tokenize');

  late final int Function(
          Pointer<llama_vocab>, int, Pointer<Utf8>, int, int, bool)
      llamaTokenToPiece = _llamaLib.lookupFunction<_llama_token_to_piece_native,
              _llama_token_to_piece_dart>('llama_token_to_piece');

  // --- sampler ---

  late final llama_sampler_chain_params Function()
      llamaSamplerChainDefaultParams = _llamaLib.lookupFunction<
              _llama_sampler_chain_default_params_native,
              _llama_sampler_chain_default_params_dart>(
          'llama_sampler_chain_default_params');

  late final Pointer<llama_sampler> Function(llama_sampler_chain_params)
      llamaSamplerChainInit = _llamaLib.lookupFunction<
              _llama_sampler_chain_init_native,
              _llama_sampler_chain_init_dart>('llama_sampler_chain_init');

  late final void Function(Pointer<llama_sampler>) llamaSamplerFree =
      _llamaLib.lookupFunction<_llama_sampler_free_native,
              _llama_sampler_free_dart>('llama_sampler_free');

  late final Pointer<llama_sampler> Function() llamaSamplerInitGreedy =
      _llamaLib.lookupFunction<_llama_sampler_init_greedy_native,
              _llama_sampler_init_greedy_dart>('llama_sampler_init_greedy');

  late final int Function(Pointer<llama_sampler>, Pointer<llama_context>, int)
      llamaSamplerSample = _llamaLib.lookupFunction<_llama_sampler_sample_native,
              _llama_sampler_sample_dart>('llama_sampler_sample');
}
