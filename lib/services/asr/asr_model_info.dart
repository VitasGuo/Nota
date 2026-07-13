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

// ============================================================================
// GGUF ASR 模型（基于 llama.cpp mtmd 接口，如 Qwen3-ASR）
// ============================================================================

/// GGUF 模型单文件描述（主模型或 mmproj 投影器）。
class GgufModelFile {
  /// 本地存储文件名（如 `Qwen3-ASR-1.7B-Q8_0.gguf`）。
  final String filename;

  /// 下载地址。空表示仅支持本地导入（无在线下载源）。
  final String? downloadUrl;

  /// 预期大小（字节，用于下载进度展示与校验；0 = 不校验大小）。
  final int sizeBytes;

  const GgufModelFile({
    required this.filename,
    this.downloadUrl,
    this.sizeBytes = 0,
  });

  double get sizeMb => sizeBytes / (1024 * 1024);
}

/// GGUF ASR 模型信息（基于 llama.cpp mtmd 接口，如 Qwen3-ASR）。
///
/// 与 sherpa-onnx 模型不同，GGUF ASR 模型由多个独立 .gguf 文件组成：
/// - [mainFile]：主模型 GGUF（含 LLM 权重，qwen3vl 架构）
/// - [mmprojFile]：音频投影器 GGUF（含音频编码器，将 PCM 映射到 token 嵌入空间）
///
/// 下载/导入时需同时获取两文件；校验时需检查两文件的 GGUF magic header。
///
/// 注意：handy-computer/Qwen3-ASR-1.7B-gguf 的 Q6_K 等量化版本使用
/// `qwen3_asr` 架构（transcribe.cpp 专用），**不兼容** llama.cpp mtmd
/// （mtmd 仅识别 `qwen3vl` 架构）。故本清单只引用 ggml-org 官方仓库
/// （architecture=qwen3vl，含 mmproj 文件）。
class GgufAsrModelInfo {
  final String id;
  final String displayName;
  final String language;
  final String? description;

  /// 主模型文件（LLM 权重，qwen3vl 架构）。
  final GgufModelFile mainFile;

  /// 音频投影器文件（音频编码器权重）。
  final GgufModelFile mmprojFile;

  const GgufAsrModelInfo({
    required this.id,
    required this.displayName,
    required this.mainFile,
    required this.mmprojFile,
    this.language = 'multi',
    this.description,
  });

  /// 主模型 + mmproj 总大小（字节）。
  int get totalSizeBytes => mainFile.sizeBytes + mmprojFile.sizeBytes;

  double get totalSizeMb => totalSizeBytes / (1024 * 1024);

  @override
  String toString() =>
      'GgufAsrModelInfo($id, $displayName, ${totalSizeMb.toStringAsFixed(0)}MB)';
}

/// 预置 GGUF ASR 模型清单。
///
/// 集中维护 NOTA 支持的基于 llama.cpp mtmd 的 GGUF ASR 模型。
/// 与 [AsrModels]（sherpa-onnx）分开管理，因模型结构与下载/校验逻辑不同。
class GgufAsrModels {
  GgufAsrModels._();

  /// 魔搭社区（ModelScope）API 前缀（国内网络最友好）。
  ///
  /// 使用魔搭替代 huggingface.co 直连，避免国内访问超时。
  /// URL 格式：`{prefix}/{repo}/repo?Revision=master&FilePath={file}`
  static const String _modelScope = 'https://www.modelscope.cn/api/v1/models';

  /// 预置 GGUF ASR 模型清单。
  ///
  /// - Qwen3-ASR-1.7B：高质量，多语言，总 ~2.36GB（主 2.02GB + mmproj 339MB）
  /// - Qwen3-ASR-0.6B：轻量级，多语言，总 ~971MB（主 767MB + mmproj 204MB）
  static const List<GgufAsrModelInfo> available = [
    GgufAsrModelInfo(
      id: 'qwen3-asr-1.7b',
      displayName: 'Qwen3-ASR 1.7B (Q8_0, 实时本地转写, ~2.4GB)',
      language: 'multi',
      description: 'Qwen3-ASR 1.7B Q8_0 量化模型，基于 llama.cpp mtmd 接口实时转写，'
          '支持中英日韩等 30+ 语言，质量最优',
      mainFile: GgufModelFile(
        filename: 'Qwen3-ASR-1.7B-Q8_0.gguf',
        downloadUrl:
            '$_modelScope/ggml-org/Qwen3-ASR-1.7B-GGUF/repo?Revision=master&FilePath=Qwen3-ASR-1.7B-Q8_0.gguf',
        sizeBytes: 2165034944,
      ),
      mmprojFile: GgufModelFile(
        filename: 'mmproj-Qwen3-ASR-1.7B-Q8_0.gguf',
        downloadUrl:
            '$_modelScope/ggml-org/Qwen3-ASR-1.7B-GGUF/repo?Revision=master&FilePath=mmproj-Qwen3-ASR-1.7B-Q8_0.gguf',
        sizeBytes: 355709344,
      ),
    ),
    GgufAsrModelInfo(
      id: 'qwen3-asr-0.6b',
      displayName: 'Qwen3-ASR 0.6B (Q8_0, 轻量本地转写, ~1.0GB)',
      language: 'multi',
      description: 'Qwen3-ASR 0.6B Q8_0 量化模型，体积更小速度更快，'
          '适合存储空间受限或追求低延迟的设备',
      mainFile: GgufModelFile(
        filename: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        downloadUrl:
            '$_modelScope/ggml-org/Qwen3-ASR-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-ASR-0.6B-Q8_0.gguf',
        sizeBytes: 804749248,
      ),
      mmprojFile: GgufModelFile(
        filename: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        downloadUrl:
            '$_modelScope/ggml-org/Qwen3-ASR-0.6B-GGUF/repo?Revision=master&FilePath=mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        sizeBytes: 214392480,
      ),
    ),
  ];

  /// 按 id 查询 GGUF ASR 模型信息，未找到返回 null。
  static GgufAsrModelInfo? getById(String id) {
    for (final m in available) {
      if (m.id == id) return m;
    }
    return null;
  }
}

// ============================================================================
// whisper.cpp ASR 模型（ggml .bin 格式，非 GGUF）
// ============================================================================

/// whisper.cpp ASR 模型信息（基于 whisper.cpp 原生 ggml 格式）。
///
/// 与 [GgufAsrModelInfo]（llama.cpp mtmd，GGUF 双文件）不同，whisper.cpp
/// 使用自有 ggml 格式（.bin 单文件），针对 CPU 推理优化，移动端成熟稳定。
///
/// 模型格式特点：
/// - 单文件 .bin（无需 mmproj，音频编码器内置在主模型中）
/// - 采样率固定 16000Hz（与 NOTA PCM16 16kHz 标准一致）
/// - 不支持热词 boosting（whisper.cpp 无此能力）
///
/// 下载源：https://huggingface.co/ggerganov/whisper.cpp
/// 国内通过 hf-mirror.com 镜像下载。
class WhisperModelInfo {
  /// 模型唯一标识，作为本地存储目录名。
  final String id;

  /// 用户可见的显示名。
  final String displayName;

  /// 模型文件名（如 `ggml-small.bin`）。
  final String filename;

  /// 下载地址（hf-mirror.com 镜像）。
  final String downloadUrl;

  /// 模型大小（字节）。
  final int sizeBytes;

  /// 支持语言（zh / en / multi）。
  final String language;

  /// 模型描述。
  final String? description;

  const WhisperModelInfo({
    required this.id,
    required this.displayName,
    required this.filename,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.language,
    this.description,
  });

  /// 模型大小（MB）。
  double get sizeMb => sizeBytes / (1024 * 1024);

  @override
  String toString() =>
      'WhisperModelInfo($id, $displayName, ${sizeMb.toStringAsFixed(0)}MB)';
}

/// 预置 whisper.cpp 模型清单。
///
/// 集中维护 NOTA 支持的 whisper.cpp ggml 模型。与 [AsrModels]（sherpa-onnx）
/// 和 [GgufAsrModels]（llama.cpp mtmd）分开管理，因模型格式与加载方式不同。
///
/// 引擎实现：[WhisperRealtimeAsrEngine] + [WhisperIsolateWorker] + [WhisperEngine]，
/// 加载 libwhisper_android.so（C wrapper 见 tool/whisper-build/whisper_wrapper.c）。
class WhisperModels {
  WhisperModels._();

  /// HF 镜像前缀（国内网络友好，但 Xet 文件可能 302 到被墙的 CDN）。
  static const String _hfMirror = 'https://hf-mirror.com';

  /// 魔搭社区 API 前缀（国内网络最友好，whisper-large-v3 备选源）。
  static const String _modelScope = 'https://www.modelscope.cn/api/v1/models';

  /// 预置 whisper.cpp ggml 模型清单。
  ///
  /// 按推荐度排序：
  /// - ggml-small.bin（~466MB，多语言，中文最小可用，推荐首选，hf-mirror 源）
  /// - ggml-large-v3-turbo-q5_0.bin（~547MB，多语言，质量最优，hf-mirror 源）
  /// - ggml-tiny.bin（~39MB，英文，测试用，体积最小，hf-mirror 源）
  /// - whisper-large-v3（~3.1GB，多语言，魔搭源，hf-mirror 403 时的备选）
  ///
  /// 注意：hf-mirror 对 Xet 存储文件会 302 重定向到 cas-bridge.xethub.hf.co
  /// （国内被墙返回 403）。tiny/small/large-v3-turbo 均走 hf-mirror，如遇 403
  /// 请改用魔搭源的 large-v3，或手动下载后导入（traps.md #47）。
  static const List<WhisperModelInfo> available = [
    WhisperModelInfo(
      id: 'whisper-small',
      displayName: 'Whisper Small (466MB, 多语言, 中文首选)',
      filename: 'ggml-small.bin',
      downloadUrl: '$_hfMirror/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
      sizeBytes: 466 * 1024 * 1024,
      language: 'multi',
      description: 'whisper.cpp Small 模型，支持中文，体积与质量均衡，推荐首选',
    ),
    WhisperModelInfo(
      id: 'whisper-large-v3-turbo',
      displayName: 'Whisper Large v3 Turbo Q5 (547MB, 多语言, 质量最优)',
      filename: 'ggml-large-v3-turbo-q5_0.bin',
      downloadUrl:
          '$_hfMirror/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
      sizeBytes: 547 * 1024 * 1024,
      language: 'multi',
      description: 'whisper.cpp Large v3 Turbo Q5_0 量化版，质量最优，'
          '存储空间充裕时首选',
    ),
    WhisperModelInfo(
      id: 'whisper-tiny',
      displayName: 'Whisper Tiny (39MB, 英文, 测试用)',
      filename: 'ggml-tiny.bin',
      downloadUrl: '$_hfMirror/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
      sizeBytes: 39 * 1024 * 1024,
      language: 'en',
      description: 'whisper.cpp 最小模型，仅英文，用于测试引擎是否正常工作',
    ),
    WhisperModelInfo(
      id: 'whisper-large-v3',
      displayName: 'Whisper Large v3 (3.1GB, 多语言, 魔搭源, 备选)',
      filename: 'ggml-model.bin',
      downloadUrl:
          '$_modelScope/LLM-Research/whisper-large-v3-ggml/repo?Revision=master&FilePath=ggml-model.bin',
      sizeBytes: 3100 * 1024 * 1024,
      language: 'multi',
      description: 'whisper.cpp Large v3 全精度模型（魔搭下载源），体积较大。'
          '当 hf-mirror 下载 tiny/small/turbo 遇 403 时可用此模型',
    ),
  ];

  /// 按 id 查询 whisper.cpp 模型信息，未找到返回 null。
  static WhisperModelInfo? getById(String id) {
    for (final m in available) {
      if (m.id == id) return m;
    }
    return null;
  }
}
