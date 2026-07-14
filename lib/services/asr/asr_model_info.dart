/// ASR 模型信息（用于本地模型管理）。
///
/// 描述一个可下载的本地 ASR 模型：显示名、下载地址、大小、语言、是否支持热词。
/// 由 AsrModelManager（Task 8.2）消费，用于模型下载 / 切换 / 删除 UI。
///
/// 下载方式（按优先级）：
/// - **ModelScope 下载**（国内首选）：[modelscopeRepo] 非空时，从魔搭社区
///   （modelscope.cn）逐文件下载 [modelscopeFiles]。国内网络最友好。
/// - **HF 单文件下载**：[hfRepo] 非空时，从 hf-mirror.com 逐文件下载
///   [hfFiles]。国内网络友好，无需解压。
/// - **tar.bz2 归档下载**（回退）：以上均为空时，从 [downloadUrl] 下载
///   tar.bz2 压缩包并解压。下载源为 GitHub，国内可能超时。
class AsrModelInfo {
  /// 模型唯一标识，作为本地存储目录名与配置引用键。
  final String id;

  /// 用户可见的显示名。
  final String displayName;

  /// tar.bz2 归档下载地址（GitHub 源，国内可能超时）。
  ///
  /// 当 [hfRepo] 为空时使用此地址下载并解压。
  final String downloadUrl;

  /// 模型大小（字节），用于下载前展示与空间校验。
  final int sizeBytes;

  /// 支持语言（zh / en / multi）。
  final String language;

  /// 是否支持热词 boosting（如 Paraformer 原生支持，Whisper 不支持）。
  final bool supportsHotwords;

  /// 模型描述（可选）。
  final String? description;

  /// HuggingFace 仓库路径（如 `csukuangfj/sherpa-onnx-paraformer-zh-2023-03-28`）。
  ///
  /// 非空时优先从 `hf-mirror.com` 逐文件下载 [hfFiles]，国内网络友好。
  /// 为空时回退到 [downloadUrl] 的 tar.bz2 归档下载。
  final String? hfRepo;

  /// HF 仓库中需要下载的文件列表（如 `['model.int8.onnx', 'tokens.txt']`）。
  ///
  /// 仅当 [hfRepo] 非空时有效。下载后直接放入模型目录，无需解压。
  final List<String> hfFiles;

  /// ModelScope（魔搭社区）模型 ID（如 `xiaowangge/sherpa-onnx-sense-voice-small`）。
  ///
  /// 非空时优先从 `modelscope.cn` 逐文件下载 [modelscopeFiles]，国内网络最友好。
  /// 下载 URL 格式：
  /// `https://www.modelscope.cn/api/v1/models/{modelscopeRepo}/repo?Revision=master&FilePath={file}`
  final String? modelscopeRepo;

  /// ModelScope 仓库中需要下载的文件列表（如 `['model_q8.onnx', 'tokens.txt']`）。
  ///
  /// 仅当 [modelscopeRepo] 非空时有效。下载后直接放入模型目录，无需解压。
  final List<String> modelscopeFiles;

  const AsrModelInfo({
    required this.id,
    required this.displayName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.language,
    required this.supportsHotwords,
    this.description,
    this.hfRepo,
    this.hfFiles = const [],
    this.modelscopeRepo,
    this.modelscopeFiles = const [],
  });

  /// 模型大小（MB），便于 UI 展示。
  double get sizeMb => sizeBytes / (1024 * 1024);

  /// 是否使用 ModelScope 下载方式（[modelscopeRepo] 非空且 [modelscopeFiles] 非空）。
  bool get useModelScopeDownload =>
      modelscopeRepo != null && modelscopeFiles.isNotEmpty;

  /// 是否使用 HF 单文件下载方式（[hfRepo] 非空且 [hfFiles] 非空）。
  bool get useHfDownload => hfRepo != null && hfFiles.isNotEmpty;

  @override
  String toString() => 'AsrModelInfo($id, $displayName, ${sizeMb.toStringAsFixed(0)}MB)';
}

/// 预置 ASR 模型列表。
///
/// 集中维护 NOTA 支持的本地 ASR 模型清单，UI 与配置层通过 [getById] 查询。
/// 新增模型只需在此追加 [AsrModelInfo] 条目。
class AsrModels {
  AsrModels._();

  /// 预置可用模型。
  ///
  /// - SenseVoice Small：多语言（中英日韩粤），~239MB，从魔搭社区下载，国内首选
  /// - Whisper Medium：多语言，769M，质量与速度均衡
  /// - Whisper Large v3 Turbo：多语言，809M，速度更快质量更好
  /// - Paraformer 中文：220M，原生支持热词 boosting，中文场景首选
  static const List<AsrModelInfo> available = [
    AsrModelInfo(
      id: 'sensevoice-zh',
      displayName: 'SenseVoice Small (多语言, 中英日韩粤, ~239MB)',
      downloadUrl: '', // 仅通过 ModelScope 下载
      sizeBytes: 239 * 1024 * 1024 + 316 * 1024, // model_q8.onnx (~239MB) + tokens.txt (~316KB)
      language: 'multi',
      supportsHotwords: false,
      description: '阿里 SenseVoice 多语言语音识别模型（Q8 量化版），支持中英日韩粤 5 种语言。'
          '从魔搭社区（ModelScope）下载，国内网络最友好，推荐首选',
      modelscopeRepo: 'xiaowangge/sherpa-onnx-sense-voice-small',
      modelscopeFiles: ['model_q8.onnx', 'tokens.txt'],
    ),
    AsrModelInfo(
      id: 'whisper-medium',
      displayName: 'Whisper Medium (769M, 多语言)',
      downloadUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-medium.tar.bz2',
      sizeBytes: 769 * 1024 * 1024,
      language: 'multi',
      supportsHotwords: false,
      description: 'OpenAI Whisper 中等模型，支持多语言',
    ),
    AsrModelInfo(
      id: 'whisper-large-v3-turbo',
      displayName: 'Whisper Large v3 Turbo (809M, 多语言)',
      downloadUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-large-v3-turbo.tar.bz2',
      sizeBytes: 809 * 1024 * 1024,
      language: 'multi',
      supportsHotwords: false,
      description: 'Whisper Turbo 版，速度更快质量更好',
    ),
    AsrModelInfo(
      id: 'paraformer-zh',
      displayName: 'Paraformer 中文 int8 (支持热词, ~213MB)',
      downloadUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-paraformer-zh.tar.bz2',
      sizeBytes: 223461591, // model.int8.onnx (223385835) + tokens.txt (75756)
      language: 'zh',
      supportsHotwords: true,
      description: '阿里 Paraformer 中文模型 int8 量化版，原生支持热词 boosting。'
          '从魔搭社区（ModelScope）下载，国内网络最友好',
      modelscopeRepo: 'pengzhendong/sherpa-onnx-paraformer-zh',
      modelscopeFiles: ['model.int8.onnx', 'tokens.txt'],
    ),
  ];

  /// 按 id 查询模型信息，未找到返回 null。
  static AsrModelInfo? getById(String id) {
    for (final m in available) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// VAD 语音活动检测模型（silero_vad.onnx，单文件，非归档）。
  ///
  /// 不在 [available] 列表中——VAD 非 ASR 转写模型，独立管理（下载/存储
  /// 路径与转写模型不同：单 .onnx 文件，无 tokens.txt，存储于
  /// `asr_models/vad/`）。由 [AsrModelManager] 的 VAD 专用方法消费。
  static const AsrModelInfo vadModel = AsrModelInfo(
    id: 'silero-vad',
    displayName: 'Silero VAD (语音活动检测, ~2MB)',
    downloadUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
    sizeBytes: 2 * 1024 * 1024,
    language: 'multi',
    supportsHotwords: false,
    description: 'Silero VAD 模型，用于语音活动检测分段（实时 ASR 前置）',
  );

  /// VAD 模型 id（与 [vadModel.id] 一致，供 [AsrModelManager] 分支判断）。
  static const String vadModelId = 'silero-vad';
}
