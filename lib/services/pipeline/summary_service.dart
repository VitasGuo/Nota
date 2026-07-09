import 'package:nota/models/note.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/note_storage.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 会议纪要生成服务（单例）。
///
/// 通过 [LlmTaskRouter] 获取 summary 任务的 [LlmEngine]，将转写文本喂入
/// 模型流式生成结构化 Markdown 纪要，并持久化为 [Note]（type=summary）。
///
/// 流程：加载转写段落 → 拼接为带说话人/时间戳的文本 → 调用 LLM 流式生成
/// → 存为 Note 返回。引擎实例由本服务持有并在生成结束后释放。
class SummaryService {
  SummaryService._();
  static final SummaryService _instance = SummaryService._();
  factory SummaryService() => _instance;

  final TranscriptStorage _transcriptStorage = TranscriptStorage();
  final NoteStorage _noteStorage = NoteStorage();
  final RecordingStorage _recordingStorage = RecordingStorage();
  final LlmTaskRouter _taskRouter = LlmTaskRouter();

  /// 纪要生成的系统提示词（固定模板）。
  static const String _systemPrompt = '''你是一个专业的会议纪要生成助手。根据用户提供的会议转写文本，生成结构化的会议纪要。输出格式为 Markdown，包含以下章节：

## 会议主题
（简述会议主题）

## 议题
- 议题1
- 议题2

## 决议
- 决议1
- 决议2

## 待办事项
- [ ] 任务1（负责人）
- [ ] 任务2（负责人）

## 关键信息
- 关键数据/日期/人名等

规则：1) 忠于原文，不臆造 2) 待办事项用 - [ ] 格式 3) 如有说话人标签，标注谁说的 4) 简洁清晰''';

  /// 为指定会话生成会议纪要。
  ///
  /// - [sessionId] 录音会话 id。
  /// - [onToken] 流式 token 回调，每生成一个 token 触发一次。
  /// - [onProgress] 进度回调，取值 0.0 ~ 1.0：
  ///   0.0 开始 → 0.05 转写已加载 → 0.05~0.9 流式生成 → 0.95 生成完成 → 1.0 已存库。
  ///
  /// 返回持久化后的 [Note]（含 id）。转写为空或引擎不可用时抛 [StateError]。
  Future<Note> generateSummary(
    String sessionId, {
    void Function(String token)? onToken,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.0);

    // 1. 加载转写段落（getSegments 已按 start_time 升序）
    final segments = await _transcriptStorage.getSegments(sessionId);
    if (segments.isEmpty) {
      throw StateError('会话 $sessionId 无转写段落，无法生成纪要');
    }

    // 2. 加载会话信息（标题 / 开始时间），缺失则回退默认值
    final session = await _recordingStorage.getSession(sessionId);
    final sessionTitle = session?.title ?? '未命名会话';
    final sessionStart = session?.startTime ?? DateTime.now();

    // 3. 拼接转写文本：[HH:mm:ss] 说话人: 文本
    final transcriptText = _buildTranscriptText(segments);
    onProgress?.call(0.05);

    // 4. 构造 userPrompt
    final userPrompt = '会议标题：$sessionTitle\n'
        '会议时间：${_formatDateTime(sessionStart)}\n\n'
        '转写内容：\n$transcriptText';

    // 5. 获取 summary 任务的 LLM 引擎
    final engine = await _taskRouter.getEngine(LlmTaskType.summary);
    if (engine == null) {
      throw StateError('summary 任务的 LLM 引擎不可用（本地引擎未实现）');
    }

    // 6. 流式生成：onToken 实时透传，onProgress 按累计字符数饱和估算
    //    预期输出长度按输入文本 1/3 估算（纪要通常短于原文），下限 200 字符。
    var expectedChars = transcriptText.length ~/ 3;
    if (expectedChars < 200) expectedChars = 200;

    final received = StringBuffer();
    double lastReported = 0.05;
    String markdown = '';
    String? errorMsg;

    try {
      await engine.generate(
        systemPrompt: _systemPrompt,
        userPrompt: userPrompt,
        onToken: (token) {
          received.write(token);
          onToken?.call(token);
          // 进度：0.05 ~ 0.9 之间随累计字符数饱和上升，封顶 0.899
          double ratio = received.length / expectedChars;
          if (ratio > 0.999) ratio = 0.999;
          final p = 0.05 + 0.85 * ratio;
          if (p - lastReported >= 0.005) {
            lastReported = p;
            onProgress?.call(p);
          }
        },
        onComplete: (fullText) {
          markdown = fullText;
        },
        onError: (error) {
          errorMsg = error;
        },
      );
    } finally {
      // 引擎由路由器按次新建，生成结束后释放其底层资源（HTTP 连接等）
      await engine.dispose();
    }

    if (errorMsg != null) {
      throw StateError('纪要生成失败：$errorMsg');
    }

    onProgress?.call(0.95);

    // 7. 持久化为 Note（type=summary）
    final now = DateTime.now();
    final note = Note(
      sessionId: sessionId,
      title: '$sessionTitle - 纪要',
      content: markdown,
      type: NoteType.summary,
      createdAt: now,
      updatedAt: now,
    );
    final id = await _noteStorage.insertNote(note);

    onProgress?.call(1.0);
    return note.copyWith(id: id);
  }

  /// 拼接转写段落为完整文本。
  ///
  /// 优先使用 [TranscriptSegment.correctedText]（如非空），否则用 originalText。
  /// 格式：`[HH:mm:ss] 说话人: 文本`，无说话人时省略说话人段。
  String _buildTranscriptText(List<TranscriptSegment> segments) {
    final buf = StringBuffer();
    for (final seg in segments) {
      final ts = _formatTimestamp(seg.startTime);
      final text =
          (seg.correctedText != null && seg.correctedText!.isNotEmpty)
              ? seg.correctedText!
              : seg.originalText;
      final line = seg.hasSpeaker
          ? '[$ts] ${seg.speakerId}: $text'
          : '[$ts] $text';
      buf.writeln(line);
    }
    return buf.toString().trimRight();
  }

  /// 秒（double）→ HH:mm:ss。
  String _formatTimestamp(double seconds) {
    final total = seconds.round();
    final h = (total ~/ 3600).toString().padLeft(2, '0');
    final m = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// DateTime → yyyy-MM-dd HH:mm:ss（用于 prompt 中的会议时间）。
  String _formatDateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
