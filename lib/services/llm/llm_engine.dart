/// LLM 引擎类型。
///
/// - [local]：本地 llama.cpp 引擎（离线可用，GGUF 模型）
/// - [cloud]：云端 OpenAI 兼容 API（复用 ai_router_module）
enum LlmEngineType { local, cloud }

/// LLM 任务类型（按功能路由）。
///
/// 每个功能可独立配置使用哪个引擎与模型，见 [LlmTaskRouter]。
/// 新增功能只需在此追加枚举值，路由层与配置层自动适配。
enum LlmTaskType {
  /// 翻译（中→英 / 英→中）。
  translation,

  /// 会议纪要生成（议题 / 决议 / 待办 / 关键信息）。
  summary,

  /// 笔记整理（标题 / 分类 / 标签 / 结构化 Markdown 正文）。
  noteOrganize,

  /// 转写文本纠错（参考热词词表修正专有名词 / 术语 / 人名）。
  correction,
}

/// LLM 引擎配置。
///
/// 同时承载本地与云端引擎所需的全部参数：
/// 本地引擎关注 [modelName]（GGUF 模型 id）；
/// 云端引擎关注 [providerName] / [modelName] / [customUrl]。
class LlmConfig {
  /// 引擎类型，决定其余字段的语义。
  final LlmEngineType engineType;

  /// 云端提供商名（见 AiProviders），本地引擎忽略。
  final String? providerName;

  /// 模型名：本地为 GGUF 模型 id，云端为 API 模型名。
  final String? modelName;

  /// 自定义 API 地址，覆盖提供商默认 baseUrl（本地/自定义场景）。
  final String? customUrl;

  /// 最大生成 token 数。
  final int maxTokens;

  /// 采样温度（0.0-2.0），越低输出越确定，越高越发散。
  final double temperature;

  const LlmConfig({
    required this.engineType,
    this.providerName,
    this.modelName,
    this.customUrl,
    this.maxTokens = 4096,
    this.temperature = 0.3,
  });

  /// 序列化为 JSON 字符串，持久化到 SharedPreferences。
  Map<String, dynamic> toJson() => {
        'engineType': engineType.name,
        'providerName': providerName,
        'modelName': modelName,
        'customUrl': customUrl,
        'maxTokens': maxTokens,
        'temperature': temperature,
      };

  /// 从 JSON 反序列化。
  factory LlmConfig.fromJson(Map<String, dynamic> json) {
    return LlmConfig(
      engineType: LlmEngineType.values.byName(json['engineType'] as String),
      providerName: json['providerName'] as String?,
      modelName: json['modelName'] as String?,
      customUrl: json['customUrl'] as String?,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 4096,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.3,
    );
  }

  /// 创建一份副本，仅覆盖传入的字段。
  LlmConfig copyWith({
    LlmEngineType? engineType,
    String? providerName,
    String? modelName,
    String? customUrl,
    int? maxTokens,
    double? temperature,
  }) {
    return LlmConfig(
      engineType: engineType ?? this.engineType,
      providerName: providerName ?? this.providerName,
      modelName: modelName ?? this.modelName,
      customUrl: customUrl ?? this.customUrl,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
    );
  }
}

/// LLM 引擎抽象接口。
///
/// 统一本地（llama.cpp via FFI）与云端（OpenAI 兼容 /chat/completions）
/// 文本生成调用契约。具体实现见 LocalLlmEngine（Task 11）与
/// CloudLlmEngine（Task 12）。
abstract class LlmEngine {
  /// 引擎类型。
  LlmEngineType get engineType;

  /// 是否已就绪（模型已加载 / API 已配置）。
  bool get isReady;

  /// 初始化引擎。
  ///
  /// 本地引擎加载 GGUF 模型文件，云端引擎校验配置。
  /// 重复调用应安全（幂等）。
  Future<void> init(LlmConfig config);

  /// 生成文本（通用）。
  ///
  /// - [systemPrompt] 系统提示，设定模型角色与行为约束。
  /// - [userPrompt] 用户输入。
  /// - [onToken] 流式 token 回调，每生成一个 token 触发一次（可选）。
  /// - [onComplete] 完成回调，返回完整文本。
  /// - [onError] 错误回调。
  /// - [enableThinking] 是否启用思考模式（默认 false）。简单任务（翻译、
  ///   纠错）应关闭以加速生成；复杂任务（纪要、笔记整理）可开启。
  ///
  /// 调用方应在 [onComplete] 或 [onError] 之一被触发后视为本次生成结束。
  Future<void> generate({
    required String systemPrompt,
    required String userPrompt,
    void Function(String token)? onToken,
    required void Function(String fullText) onComplete,
    required void Function(String error) onError,
    bool enableThinking = false,
  });

  /// 释放资源（模型句柄、网络连接等）。
  Future<void> dispose();
}
