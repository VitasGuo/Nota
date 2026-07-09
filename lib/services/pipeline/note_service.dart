import 'package:nota/models/note.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/note_storage.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 笔记整理服务（单例）。
///
/// 通过 LLM 将转写文本或任意文本整理为结构化 Markdown 笔记。
/// - [generateNote]：从录音会话转写生成笔记并持久化到 [NoteStorage]。
/// - [organizeText]：直接整理任意文本为笔记（不持久化，由调用方决定）。
///
/// 笔记整理 LLM 引擎通过 [LlmTaskRouter] 按 [LlmTaskType.noteOrganize]
/// 路由获取（本地引擎待 Task 11 实现，当前默认走云端）。
class NoteService {
  NoteService._();
  static final NoteService _instance = NoteService._();
  factory NoteService() => _instance;

  /// 笔记整理系统提示词。
  ///
  /// 约束 LLM 输出格式：第一行标题、第二行分类、第三行标签、第四行起正文。
  static const String _systemPrompt =
      '你是一个笔记整理助手。将用户提供的文本整理为结构化的 Markdown 笔记。输出要求：\n'
      '1) 第一行以 `# ` 开头作为笔记标题\n'
      '2) 第二行写 `分类: {分类名}`\n'
      '3) 第三行写 `标签: {标签1}, {标签2}`\n'
      '4) 从第四行开始为正文，使用 Markdown 格式（标题/列表/引用/代码块等）\n'
      '5) 提取关键信息，去除口语化内容\n'
      '6) 保持信息完整，不臆造\n'
      '7) 如有待办事项，用 - [ ] 格式';

  /// 从会话转写生成笔记并持久化。
  ///
  /// 流程：
  /// 1. 按 [sessionId] 获取全部转写段落（优先 correctedText，无则用 originalText）。
  /// 2. 拼接为完整文本，连同会话标题作为上下文交给 LLM 整理。
  /// 3. 解析 LLM 输出为标题 / 分类 / 标签 / 正文，构造 [Note] 并写入 [NoteStorage]。
  ///
  /// [onToken] 流式回调每个生成的 token；[onProgress] 回调进度（0.0-1.0）。
  /// 返回已持久化的 [Note]（含自增 id）。
  Future<Note> generateNote(
    String sessionId, {
    void Function(String)? onToken,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.0);

    // 1. 获取转写段落
    final List<TranscriptSegment> segments =
        await TranscriptStorage().getSegments(sessionId);
    if (segments.isEmpty) {
      throw StateError('会话 $sessionId 无转写段落，无法生成笔记');
    }
    // 优先使用纠错文本，回退原文
    final fullText = segments
        .map((s) => (s.correctedText?.isNotEmpty ?? false)
            ? s.correctedText!
            : s.originalText)
        .join('\n');

    // 2. 获取会话标题作为上下文（提升整理质量）
    final session = await RecordingStorage().getSession(sessionId);
    final sessionTitle = session?.title;

    onProgress?.call(0.1);

    // 3. 获取笔记整理 LLM 引擎
    final engine = await LlmTaskRouter().getEngine(LlmTaskType.noteOrganize);
    if (engine == null) {
      throw StateError('笔记整理 LLM 引擎不可用（本地引擎尚未实现，请在设置中切换为云端引擎）');
    }

    onProgress?.call(0.2);

    // 4. 构建 prompt 并调用 LLM 生成
    final userPrompt = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? '请整理以下内容为笔记（会话标题：$sessionTitle）：\n\n$fullText'
        : '请整理以下内容为笔记：\n\n$fullText';

    final output = await _generate(
      engine,
      systemPrompt: _systemPrompt,
      userPrompt: userPrompt,
      onToken: onToken,
    );

    onProgress?.call(1.0);

    // 5. 解析输出并构造 Note
    final parsed = _parseNoteOutput(output);
    final now = DateTime.now();
    final note = Note(
      sessionId: sessionId,
      title: parsed.title,
      content: parsed.content,
      type: NoteType.note,
      tags: parsed.tags,
      category: parsed.category,
      createdAt: now,
      updatedAt: now,
    );

    // 6. 持久化
    await NoteStorage().insertNote(note);
    return note;
  }

  /// 直接整理任意文本为笔记（不持久化）。
  ///
  /// 不依赖录音会话，返回未持久化的 [Note]（sessionId 为空串），
  /// 由调用方决定是否通过 [NoteStorage.insertNote] 写入。
  /// [onToken] 流式回调每个生成的 token。
  Future<Note> organizeText(
    String text, {
    void Function(String)? onToken,
  }) async {
    final engine = await LlmTaskRouter().getEngine(LlmTaskType.noteOrganize);
    if (engine == null) {
      throw StateError('笔记整理 LLM 引擎不可用（本地引擎尚未实现，请在设置中切换为云端引擎）');
    }

    final output = await _generate(
      engine,
      systemPrompt: _systemPrompt,
      userPrompt: '请整理以下内容为笔记：\n\n$text',
      onToken: onToken,
    );

    final parsed = _parseNoteOutput(output);
    final now = DateTime.now();
    return Note(
      sessionId: '',
      title: parsed.title,
      content: parsed.content,
      type: NoteType.note,
      tags: parsed.tags,
      category: parsed.category,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 调用 LLM 引擎生成完整文本。
  ///
  /// 统一封装 [LlmEngine.generate] 的流式回调与错误处理：
  /// [onToken] 透传给调用方，[onComplete] 捕获完整文本，
  /// [onError] 捕获错误并在 await 结束后抛出（避免在回调内抛出无法传播）。
  Future<String> _generate(
    LlmEngine engine, {
    required String systemPrompt,
    required String userPrompt,
    void Function(String)? onToken,
  }) async {
    final buffer = StringBuffer();
    String? result;
    String? error;

    await engine.generate(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      onToken: (token) {
        buffer.write(token);
        onToken?.call(token);
      },
      onComplete: (fullText) {
        result = fullText;
      },
      onError: (e) {
        error = e;
      },
    );

    if (error != null) {
      throw Exception('LLM 生成失败：$error');
    }
    // 优先用 onComplete 的完整文本，回退到流式累积的 buffer
    return result ?? buffer.toString();
  }

  /// 解析 LLM 输出为标题 / 分类 / 标签 / 正文。
  ///
  /// 逐行扫描：
  /// - 首个以 `# ` 开头的行 → 标题（去除 `# ` 前缀）。
  /// - 匹配 `分类: xxx` 或 `category: xxx` 的行 → 分类（支持中英文冒号）。
  /// - 匹配 `标签: xxx, yyy` 或 `tags: xxx, yyy` 的行 → 标签列表（逗号分隔，支持中英文逗号）。
  /// - 其余行归入正文。
  _NoteParseResult _parseNoteOutput(String output) {
    final lines = output.split('\n');
    String? title;
    String? category;
    var tags = <String>[];
    final contentLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      // 标题：首个 `# ` 开头的行（`## ` 等子标题不会被误匹配）
      if (title == null && trimmed.startsWith('# ')) {
        title = trimmed.substring(2).trim();
        continue;
      }
      // 分类：行首 `分类:` / `category:`（支持中英文冒号，忽略大小写）
      final catMatch = RegExp(
        r'^(?:分类|category)\s*[:：]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (catMatch != null) {
        category = catMatch.group(1)!.trim();
        continue;
      }
      // 标签：行首 `标签:` / `tags:`（支持中英文冒号，逗号分隔）
      final tagMatch = RegExp(
        r'^(?:标签|tags)\s*[:：]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (tagMatch != null) {
        final tagStr = tagMatch.group(1)!.trim();
        tags = tagStr
            .split(RegExp(r'[,，]'))
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();
        continue;
      }
      // 其余为正文
      contentLines.add(line);
    }

    return _NoteParseResult(
      title: (title != null && title.isNotEmpty) ? title : '未命名笔记',
      category: category,
      tags: tags,
      content: contentLines.join('\n').trim(),
    );
  }
}

/// LLM 输出解析结果（文件私有）。
class _NoteParseResult {
  final String title;
  final String? category;
  final List<String> tags;
  final String content;

  const _NoteParseResult({
    required this.title,
    required this.category,
    required this.tags,
    required this.content,
  });
}
