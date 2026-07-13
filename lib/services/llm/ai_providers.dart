/// AI 提供商配置定义。
///
/// 统一描述各 AI 平台的元信息：默认地址、默认模型、可用模型列表、
/// 是否需要 API Key、是否支持 Function Calling、是否支持图像/视频/语音等。
/// 既是 [AiRouterService] 连接测试的数据源，也是 UI 选择器的选项来源。
enum AiProviderType {
  sensenova,
  deepseek,
  qwen,
  kimi,
  zhipu,
  mimo,
  ernie,
  hunyuan,
  doubao,
  // 多模态（图像/视频）
  tongyi, // 通义万相（文生图）
  jimeng, // 即梦（文生图）
  // 本地 / 自定义
  lmstudio,
  custom,
}

class AiProviderConfig {
  final AiProviderType type;
  final String displayName;

  /// 默认 API 地址（本地/自定义提供商可为空，由用户填写）
  final String defaultBaseUrl;
  final String defaultModel;
  final List<String> availableModels;

  /// 内置预设 Key（开箱即用，用户无需配置）
  final String? presetApiKey;

  /// 默认兜底 Key（用户未配置时使用，区别于 presetApiKey 的语义）
  final String? defaultApiKey;

  // —— 能力标志 ——
  final bool isImageSupported;
  final bool isVideoSupported;
  final bool isTtsSupported;

  // —— 配置行为标志 ——
  /// 是否为自定义接口（用户完全自填 URL/Model/Key）
  final bool isCustom;

  /// 是否需要 API Key（本地无鉴权模型可设 false）
  final bool needsApiKey;

  /// 是否在 UI 中展示 URL 与 Model 输入框（本地/自定义提供商）
  final bool showUrlAndModel;

  /// 是否支持 Function Calling（工具调用）
  final bool supportsToolUse;

  const AiProviderConfig({
    required this.type,
    required this.displayName,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.availableModels,
    this.presetApiKey,
    this.defaultApiKey,
    this.isImageSupported = false,
    this.isVideoSupported = false,
    this.isTtsSupported = false,
    this.isCustom = false,
    this.needsApiKey = true,
    this.showUrlAndModel = false,
    this.supportsToolUse = false,
  });

  bool get hasPresetKey => presetApiKey != null && presetApiKey!.isNotEmpty;
  bool get hasDefaultKey => defaultApiKey != null && defaultApiKey!.isNotEmpty;
}

class AiProviders {
  static const List<AiProviderConfig> all = [
    sensenova,
    deepseek,
    qwen,
    kimi,
    zhipu,
    mimo,
    ernie,
    hunyuan,
    doubao,
    tongyi,
    jimeng,
    lmstudio,
    custom,
  ];

  static const sensenova = AiProviderConfig(
    type: AiProviderType.sensenova,
    displayName: 'SenseNova',
    defaultBaseUrl: 'https://token.sensenova.cn/v1',
    defaultModel: 'deepseek-v4-flash',
    availableModels: [
      'deepseek-v4-flash',
      'deepseek-v4-pro',
      'sensenova-6.7-flash-lite',
      'sensenova-u1-fast',
    ],
    isImageSupported: true,
    isVideoSupported: true,
  );

  static const deepseek = AiProviderConfig(
    type: AiProviderType.deepseek,
    displayName: 'DeepSeek',
    defaultBaseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-v4-flash',
    availableModels: [
      'deepseek-v4-flash',
      'deepseek-v4-pro',
    ],
    supportsToolUse: true,
  );

  static const qwen = AiProviderConfig(
    type: AiProviderType.qwen,
    displayName: '通义千问 Qwen',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen3.7-max',
    availableModels: [
      'qwen3.7-max',
      'qwen3.7-plus',
      'qwen3.6-flash',
    ],
    supportsToolUse: true,
  );

  static const kimi = AiProviderConfig(
    type: AiProviderType.kimi,
    displayName: 'Kimi (月之暗面)',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-k2.5',
    availableModels: [
      'kimi-k2.5',
      'kimi-k2',
    ],
    supportsToolUse: true,
  );

  static const zhipu = AiProviderConfig(
    type: AiProviderType.zhipu,
    displayName: '智谱AI (GLM)',
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-5.2',
    availableModels: [
      'glm-5.2',
      'glm-4.7',
      'glm-4.7-flash',
      'glm-4.5-air',
    ],
    supportsToolUse: true,
  );

  static const mimo = AiProviderConfig(
    type: AiProviderType.mimo,
    displayName: '小米MiMo',
    defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5-flash',
    availableModels: [
      'mimo-v2.5',
      'mimo-v2.5-pro',
      'mimo-v2.5-flash',
    ],
    isTtsSupported: true,
  );

  static const ernie = AiProviderConfig(
    type: AiProviderType.ernie,
    displayName: '文心一言 ERNIE',
    defaultBaseUrl: 'https://qianfan.baidubce.com/v2',
    defaultModel: 'ernie-4.5-turbo-8k',
    availableModels: [
      'ernie-4.5-turbo-8k',
      'ernie-4.0-turbo-8k',
      'ernie-speed-128k',
    ],
    supportsToolUse: true,
  );

  static const hunyuan = AiProviderConfig(
    type: AiProviderType.hunyuan,
    displayName: '腾讯混元 Hunyuan',
    defaultBaseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
    defaultModel: 'hunyuan-turbo',
    availableModels: [
      'hunyuan-turbo',
      'hunyuan-pro',
      'hunyuan-large',
    ],
    supportsToolUse: true,
  );

  static const doubao = AiProviderConfig(
    type: AiProviderType.doubao,
    displayName: '字节豆包 Doubao',
    defaultBaseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-1.5-pro-32k',
    availableModels: [
      'doubao-1.5-pro-32k',
      'doubao-1.5-pro-256k',
      'doubao-1.5-lite-32k',
    ],
    supportsToolUse: true,
  );

  /// 通义万相（文生图）
  static const tongyi = AiProviderConfig(
    type: AiProviderType.tongyi,
    displayName: '通义万相 (文生图)',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'wanx2.1-t2i',
    availableModels: [
      'wanx2.1-t2i',
      'wanx2.1-imageedit',
    ],
    isImageSupported: true,
  );

  /// 即梦（文生图）
  static const jimeng = AiProviderConfig(
    type: AiProviderType.jimeng,
    displayName: '即梦 (文生图)',
    defaultBaseUrl: 'https://jimeng.jianying.com/api/v1',
    defaultModel: 'jimeng-2.0',
    availableModels: ['jimeng-2.0'],
    isImageSupported: true,
  );

  /// LM Studio（本地推理，默认无鉴权，但支持配置 API Key）
  static const lmstudio = AiProviderConfig(
    type: AiProviderType.lmstudio,
    displayName: 'LM Studio (本地)',
    defaultBaseUrl: '',
    defaultModel: '',
    availableModels: [],
    needsApiKey: true,
    showUrlAndModel: true,
    supportsToolUse: true,
  );

  /// 自定义 OpenAI 兼容接口
  static const custom = AiProviderConfig(
    type: AiProviderType.custom,
    displayName: '自定义接口',
    defaultBaseUrl: '',
    defaultModel: '',
    availableModels: [],
    isCustom: true,
    showUrlAndModel: true,
  );

  static AiProviderConfig? getByName(String name) {
    for (final p in all) {
      if (p.type.name == name) return p;
    }
    return null;
  }

  static AiProviderConfig? getByType(AiProviderType type) {
    for (final p in all) {
      if (p.type == type) return p;
    }
    return null;
  }
}
