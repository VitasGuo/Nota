// lib/services/llm/llm_model_info.dart
//
// GGUF 文本 LLM 模型信息与预置清单。
//
// 用于 [LlmModelManager] 的下载/导入/切换，供 [LocalLlmEngine] 加载推理。
// 预置模型聚焦移动端可运行的小型 instruct 模型（1.5B-3B，Q4/Q5 量化），
// 中文场景推荐 Qwen2.5 系列，英文场景推荐 Llama-3.2 系列。

/// 单个 GGUF 文本 LLM 模型文件描述。
class GgufLlmModelFile {
  /// 文件名（含扩展名），如 `qwen2.5-1.5b-instruct-q5_k_m.gguf`。
  final String filename;

  /// 下载地址（null 表示仅支持本地导入，无在线下载源）。
  final String? downloadUrl;

  /// 文件大小（字节），用于进度计算与存储统计。
  final int sizeBytes;

  const GgufLlmModelFile({
    required this.filename,
    this.downloadUrl,
    required this.sizeBytes,
  });

  /// 可读大小（MB）。
  String get sizeMb => (sizeBytes / (1024 * 1024)).toStringAsFixed(0);
}

/// GGUF 文本 LLM 模型信息。
class GgufLlmModelInfo {
  /// 模型 id（唯一标识，用于持久化配置与目录命名）。
  final String id;

  /// 显示名称。
  final String displayName;

  /// 模型文件（文本 LLM 为单文件，无 mmproj）。
  final GgufLlmModelFile file;

  /// 推荐上下文长度（影响内存占用）。
  final int recommendedNCtx;

  /// 推荐线程数（移动端建议 2-4）。
  final int recommendedNThreads;

  /// Chat 模板类型（决定 prompt 格式）。
  final ChatTemplateType chatTemplate;

  /// 描述（显示给用户）。
  final String description;

  const GgufLlmModelInfo({
    required this.id,
    required this.displayName,
    required this.file,
    this.recommendedNCtx = 2048,
    this.recommendedNThreads = 4,
    this.chatTemplate = ChatTemplateType.chatml,
    required this.description,
  });

  /// 总大小（字节）。
  int get totalSizeBytes => file.sizeBytes;
}

/// Chat 模板类型。
///
/// 不同模型家族使用不同的 chat 格式，[LocalLlmEngine] 据此构建 prompt。
enum ChatTemplateType {
  /// ChatML（Qwen2/3 系列、Yi 等使用）。
  /// `<|im_start|>{role}\n{content}<|im_end|>`
  chatml,

  /// Llama-3 格式（Llama-3.1/3.2 系列）。
  /// `<|start_header_id|>{role}<|end_header_id|>\n\n{content}<|eot_id|>`
  llama3,

  /// 通用 ChatML 兼容格式（fallback）。
  generic,
}

/// 预置 GGUF 文本 LLM 模型清单。
///
/// 下载源统一经 hf-mirror.com 镜像（国内网络友好）。
/// 用户也可通过 [LlmModelManager.importModel] 导入本地任意 GGUF 文件。
class GgufLlmModels {
  GgufLlmModels._();

  /// HuggingFace 国内镜像。
  static const String hfMirror = 'https://hf-mirror.com';

  /// 预置模型列表。
  static const List<GgufLlmModelInfo> available = [
    GgufLlmModelInfo(
      id: 'qwen2.5-1.5b-instruct',
      displayName: 'Qwen2.5-1.5B-Instruct (Q5_K_M)',
      file: GgufLlmModelFile(
        filename: 'qwen2.5-1.5b-instruct-q5_k_m.gguf',
        downloadUrl:
            '$hfMirror/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q5_k_m.gguf',
        sizeBytes: 1143141184, // ~1.06GB
      ),
      recommendedNCtx: 2048,
      recommendedNThreads: 4,
      chatTemplate: ChatTemplateType.chatml,
      description: '轻量中文友好模型，适合翻译与简单纪要。约 1.1GB。',
    ),
    GgufLlmModelInfo(
      id: 'qwen2.5-3b-instruct',
      displayName: 'Qwen2.5-3B-Instruct (Q5_K_M)',
      file: GgufLlmModelFile(
        filename: 'qwen2.5-3b-instruct-q5_k_m.gguf',
        downloadUrl:
            '$hfMirror/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q5_k_m.gguf',
        sizeBytes: 2280161280, // ~2.12GB
      ),
      recommendedNCtx: 2048,
      recommendedNThreads: 4,
      chatTemplate: ChatTemplateType.chatml,
      description: '更强中文能力，适合笔记整理与复杂纪要。约 2.2GB。',
    ),
    GgufLlmModelInfo(
      id: 'llama-3.2-3b-instruct',
      displayName: 'Llama-3.2-3B-Instruct (Q4_K_M)',
      file: GgufLlmModelFile(
        filename: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
        downloadUrl:
            '$hfMirror/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
        sizeBytes: 2019371904, // ~1.88GB
      ),
      recommendedNCtx: 2048,
      recommendedNThreads: 4,
      chatTemplate: ChatTemplateType.llama3,
      description: '英文友好模型，适合英文翻译与笔记。约 2.0GB。',
    ),
  ];

  /// 按 id 查询预置模型。
  static GgufLlmModelInfo? getById(String id) {
    for (final m in available) {
      if (m.id == id) return m;
    }
    return null;
  }
}
