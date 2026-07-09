import 'dart:async';

import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/hotword_dictionary.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 转写纠错服务（单例）。
///
/// 使用 LLM + 热词词表对 ASR 结果做专有名词 / 术语 / 人名纠错。
/// 通过 [LlmTaskRouter] 路由到 correction 任务配置的引擎，
/// 热词词表由 [HotwordDictionary] 提供，纠错结果写回 [TranscriptStorage]。
class CorrectionService {
  CorrectionService._();
  static final CorrectionService _instance = CorrectionService._();
  factory CorrectionService() => _instance;

  final LlmTaskRouter _router = LlmTaskRouter();
  final HotwordDictionary _hotwordDict = HotwordDictionary();
  final TranscriptStorage _storage = TranscriptStorage();

  /// 纠错系统提示词。
  static const String _systemPrompt =
      '你是一个专业的语音转文字纠错助手。以下是一段语音转写文本，可能包含专有名词、人名、术语的识别错误。请参考提供的热词词表进行纠错。规则：'
      '1) 只修正明显的识别错误，不改原意 2) 保持原文语言（中文转写保持中文，英文保持英文）'
      '3) 只输出纠错后的文本，每行对应原文的一行，不加额外说明';

  /// 纠错整个会话的转写文本。
  ///
  /// 从 [TranscriptStorage] 读取 [sessionId] 下全部 segments，拼接后一次性
  /// 送入 LLM 纠错，再按行序对应回写每个 segment 的 correctedText。
  ///
  /// - [onToken] 流式 token 回调（透传自引擎）。
  /// - [onProgress] 进度回调，0.0 开始 / 1.0 完成。
  ///
  /// 返回纠错后的 segments 列表（已写回数据库）。
  Future<List<TranscriptSegment>> correctSession(
    String sessionId, {
    void Function(String)? onToken,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.0);

    final segments = await _storage.getSegments(sessionId);
    if (segments.isEmpty) {
      onProgress?.call(1.0);
      return segments;
    }

    final hotwords = await _hotwordDict.getHotwordTextForPrompt();
    final userPrompt = _buildUserPrompt(segments, hotwords);

    final engine = await _router.getEngine(LlmTaskType.correction);
    if (engine == null) {
      throw StateError('纠错引擎未就绪（本地引擎尚未实现，请在设置中切换为云端引擎）');
    }

    try {
      final fullText =
          await _generate(engine, _systemPrompt, userPrompt, onToken);

      // 解析 LLM 返回的纠错文本，按行序对应回写
      final correctedLines = _parseCorrectedLines(fullText, segments.length);
      for (var i = 0; i < segments.length && i < correctedLines.length; i++) {
        final seg = segments[i];
        final corrected = correctedLines[i];
        await _storage.updateCorrectedText(seg.id!, corrected);
        // 同步更新内存对象，供调用方直接使用
        segments[i] = seg.copyWith(correctedText: corrected);
      }

      onProgress?.call(1.0);
      return segments;
    } finally {
      await engine.dispose();
    }
  }

  /// 纠错单段转写文本，返回纠错后的字符串。
  ///
  /// 不写回数据库，仅返回纠错结果，调用方自行决定是否持久化。
  Future<String> correctSegment(
    TranscriptSegment segment, {
    void Function(String)? onToken,
  }) async {
    final hotwords = await _hotwordDict.getHotwordTextForPrompt();
    final userPrompt = _buildUserPrompt([segment], hotwords);

    final engine = await _router.getEngine(LlmTaskType.correction);
    if (engine == null) {
      throw StateError('纠错引擎未就绪（本地引擎尚未实现，请在设置中切换为云端引擎）');
    }

    try {
      final fullText =
          await _generate(engine, _systemPrompt, userPrompt, onToken);
      final lines = _parseCorrectedLines(fullText, 1);
      return lines.isNotEmpty ? lines.first : segment.originalText;
    } finally {
      await engine.dispose();
    }
  }

  /// 构建 user prompt。
  ///
  /// 格式：热词参考词表（非空时）+ 按行带序号拼接的转写文本。
  String _buildUserPrompt(
    List<TranscriptSegment> segments,
    String hotwords,
  ) {
    final buffer = StringBuffer();
    if (hotwords.isNotEmpty) {
      buffer.write('热词参考词表：\n');
      buffer.write(hotwords);
      buffer.write('\n\n');
    }
    buffer.write('请纠错以下转写文本（每行一条，保持行号对应）：\n');
    for (var i = 0; i < segments.length; i++) {
      buffer.write('${i + 1}. ${segments[i].originalText}');
      if (i < segments.length - 1) buffer.write('\n');
    }
    return buffer.toString();
  }

  /// 调用引擎生成，将回调式 API 转为 Future。
  Future<String> _generate(
    LlmEngine engine,
    String systemPrompt,
    String userPrompt,
    void Function(String)? onToken,
  ) {
    final completer = Completer<String>();
    engine.generate(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      onToken: onToken,
      onComplete: (fullText) {
        if (!completer.isCompleted) completer.complete(fullText);
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(Exception('LLM 纠错失败：$error'));
        }
      },
    );
    return completer.future;
  }

  /// 解析 LLM 返回的纠错文本为行列表。
  ///
  /// LLM 可能返回 `1. xxx` 或纯文本 `xxx` 两种格式，统一去除行首序号前缀。
  /// [expectedCount] 期望行数，超出部分截断。
  List<String> _parseCorrectedLines(String text, int expectedCount) {
    final lines = text.split('\n');
    final result = <String>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // 去除行首 "N." / "N、" / "N)" 序号前缀
      final stripped = line.replaceFirst(RegExp(r'^\d+\s*[.、)]\s*'), '');
      result.add(stripped);
    }
    if (result.length > expectedCount) {
      result.removeRange(expectedCount, result.length);
    }
    return result;
  }
}
