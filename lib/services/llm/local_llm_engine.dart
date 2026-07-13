// lib/services/llm/local_llm_engine.dart
//
// 本地 LLM 引擎（基于 LlamaCppEngine，implements LlmEngine）。
//
// 将 llama.cpp 的同步 FFI 推理包装为符合 [LlmEngine] 接口的异步调用，
// 供 [LlmTaskRouter] 在 [LlmEngineType.local] 路由分支返回。
//
// 工作流程：
// 1. [init] 根据 config.modelName（模型 id）经 [LlmModelManager] 定位 GGUF 文件 →
//    [LlamaCppEngine.load] 加载模型（预置模型用推荐 nCtx/nThreads，自定义导入用默认值）
// 2. [generate] 按 [ChatTemplateType] 构建 chat prompt → [LlamaCppEngine.generate]
//    同步流式生成 → 映射到 [onToken]/[onComplete]/[onError]
// 3. [dispose] 释放 [LlamaCppEngine] 原生资源
//
// 性能说明：[LlamaCppEngine.generate] 为同步 FFI 调用，执行期间阻塞事件循环，
// 故 [generate] 用 `Future(...)` 将其放入事件队列，但 token 仍会在 generate 返回前
// 全部经 onToken 回调发出（UI 在 generate 完成后一次性渲染累积 token）。
// 真正的逐 token 异步流式需后续在 FFI 层用 Isolate 或暴露单步生成 API 优化。

import 'package:nota/services/llm/llama_cpp_engine.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_model_info.dart';
import 'package:nota/services/llm/llm_model_manager.dart';

/// 本地 LLM 引擎（llama.cpp FFI）。
///
/// 实现 [LlmEngine] 接口，加载 GGUF 文本 LLM 模型进行离线推理。
/// 支持 [GgufLlmModels.available] 预置模型与 [LlmModelManager.importCustomModel]
/// 导入的自定义模型（自定义模型默认使用 ChatML 模板）。
class LocalLlmEngine extends LlmEngine {
  LocalLlmEngine() : _llama = LlamaCppEngine();

  final LlamaCppEngine _llama;
  LlmConfig? _config;
  ChatTemplateType _chatTemplate = ChatTemplateType.chatml;
  bool _isReady = false;

  @override
  LlmEngineType get engineType => LlmEngineType.local;

  @override
  bool get isReady => _isReady;

  /// 模型描述（如 "Qwen3 0.6B Q8_0"），加载前返回空字符串。
  String get modelDesc => _llama.isLoaded ? _llama.modelDesc : '';

  @override
  Future<void> init(LlmConfig config) async {
    // 幂等：相同模型已加载则直接返回
    if (_isReady && _config?.modelName == config.modelName) return;

    // 切换模型：先释放旧资源
    if (_llama.isLoaded) {
      _llama.dispose();
      _isReady = false;
    }

    if (config.modelName == null || config.modelName!.isEmpty) {
      throw StateError('本地 LLM 引擎需要 modelName（模型 id）');
    }

    final modelId = config.modelName!;
    final manager = LlmModelManager();
    final info = GgufLlmModels.getById(modelId);

    String modelPath;
    int nCtx;
    int nThreads;

    if (info != null) {
      // 预置模型
      if (!await manager.isModelDownloaded(modelId)) {
        throw StateError('模型 $modelId 尚未下载，请先下载模型');
      }
      modelPath = await manager.getModelPath(modelId);
      nCtx = info.recommendedNCtx;
      nThreads = info.recommendedNThreads;
      _chatTemplate = info.chatTemplate;
    } else {
      // 自定义导入模型
      final customModels = await manager.getCustomModels();
      final custom = customModels.where((m) => m.modelId == modelId).toList();
      if (custom.isEmpty) {
        throw StateError('模型 $modelId 未找到，请先导入模型');
      }
      modelPath = custom.first.path;
      nCtx = 2048;
      nThreads = 4;
      _chatTemplate = ChatTemplateType.chatml; // 自定义模型默认 ChatML
    }

    await _llama.load(modelPath, nCtx: nCtx, nThreads: nThreads);

    _config = config;
    _isReady = true;
  }

  @override
  Future<void> generate({
    required String systemPrompt,
    required String userPrompt,
    void Function(String token)? onToken,
    required void Function(String fullText) onComplete,
    required void Function(String error) onError,
    bool enableThinking = false,
  }) async {
    if (!_isReady || _config == null) {
      onError('本地 LLM 引擎未初始化');
      return;
    }

    try {
      final prompt = _buildPrompt(systemPrompt, userPrompt, enableThinking);
      final maxTokens = _config!.maxTokens;

      // 同步 FFI 调用放入事件队列，避免立即阻塞当前事件循环。
      // 注意：generate 执行期间事件循环不处理其他事件，onToken 回调
      // 在 generate 返回前全部触发，UI 在 generate 完成后渲染。
      final result = await Future(() => _llama.generate(
            prompt,
            onToken: onToken,
            maxTokens: maxTokens,
          ));

      onComplete(result);
    } catch (e) {
      onError(e.toString());
    }
  }

  /// 按 [_chatTemplate] 构建 chat prompt。
  ///
  /// [enableThinking] 为 false 时（默认），仅对 ChatML 模板（Qwen3 系列约定）
  /// 在 user 内容末尾追加 `/no_think`，抑制 Qwen3 / ornith 等支持思考模式的
  /// 模型的 `<think>` 输出，加速简单任务。Llama3 / generic 模板不支持该控制
  /// token，追加会被当作普通文本干扰模型，故不追加。
  String _buildPrompt(String system, String user, bool enableThinking) {
    final supportsNoThink = _chatTemplate == ChatTemplateType.chatml;
    final userContent = (!enableThinking && supportsNoThink)
        ? '$user /no_think'
        : user;
    switch (_chatTemplate) {
      case ChatTemplateType.chatml:
        return '<|im_start|>system\n$system<|im_end|>\n'
            '<|im_start|>user\n$userContent<|im_end|>\n'
            '<|im_start|>assistant\n';
      case ChatTemplateType.llama3:
        return '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
            '$system<|eot_id|>'
            '<|start_header_id|>user<|end_header_id|>\n\n'
            '$userContent<|eot_id|>'
            '<|start_header_id|>assistant<|end_header_id|>\n\n';
      case ChatTemplateType.generic:
        return 'System: $system\n\nUser: $userContent\n\nAssistant: ';
    }
  }

  @override
  Future<void> dispose() async {
    _llama.dispose();
    _isReady = false;
    _config = null;
  }
}
