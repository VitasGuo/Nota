import 'dart:async';

import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/hotword_dictionary.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 翻译服务（单例）。
///
/// 通过 LLM 将转写文本翻译为目标语言（默认英文）。
/// - [translateSession]：翻译整个会话的全部 segments，逐条回写数据库
/// - [translateText]：翻译单段文本，仅返回译文
///
/// 依赖 [LlmTaskRouter] 路由到 translation 任务的 [LlmEngine]，
/// 依赖 [HotwordDictionary] 注入热词参考词表以保持专有名词一致。
class TranslationService {
  TranslationService._();
  static final TranslationService _instance = TranslationService._();
  factory TranslationService() => _instance;

  final LlmTaskRouter _router = LlmTaskRouter();
  final TranscriptStorage _storage = TranscriptStorage();
  final HotwordDictionary _hotwordDict = HotwordDictionary();

  /// 语言代码到中文名映射（用于 prompt 文案）。
  static const Map<String, String> _langNames = {
    'zh': '中文',
    'en': '英文',
  };

  /// 检测文本源语言：包含大量中文字符则视为 zh，否则为 en。
  ///
  /// 判定阈值：中文字符占比 > 30% 视为中文。
  String _detectSourceLang(String text) {
    if (text.isEmpty) return 'en';
    final chineseChars = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
    final ratio = chineseChars / text.length;
    return ratio > 0.3 ? 'zh' : 'en';
  }

  /// 获取语言中文名（未知代码原样返回）。
  String _langName(String code) => _langNames[code] ?? code;

  /// 构建 system prompt。
  String _buildSystemPrompt(String sourceLang, String targetLang) {
    return '你是一个专业翻译。将用户提供的文本从${_langName(sourceLang)}翻译为${_langName(targetLang)}。'
        '规则：1) 保持专有名词/术语不变（参考热词词表）'
        '2) 保持原文语气和语义 '
        '3) 只输出翻译结果，不加解释 '
        '4) 每行对应原文的一行';
  }

  /// 构建 user prompt（含热词参考）。
  ///
  /// 热词词表为空时省略对应段落，避免注入空参考。
  String _buildUserPrompt(String hotwords, String text) {
    final buffer = StringBuffer();
    if (hotwords.isNotEmpty) {
      buffer.writeln('热词参考词表：');
      buffer.writeln(hotwords);
      buffer.writeln();
    }
    buffer.writeln('请翻译以下文本（每行一条，保持行号对应）：');
    buffer.write(text);
    return buffer.toString();
  }

  /// 调用 LLM 引擎生成翻译，将回调式 API 封装为 Future。
  ///
  /// 从 [LlmTaskRouter] 获取 translation 任务的引擎（可能为 null，
  /// 本地引擎未实现时返回 null），流式接收 token 并在完成后返回完整译文。
  /// 使用后释放引擎资源。
  Future<String> _generateTranslation({
    required String systemPrompt,
    required String userPrompt,
    void Function(String)? onToken,
  }) async {
    final engine = await _router.getEngine(LlmTaskType.translation);
    if (engine == null) {
      throw StateError('翻译引擎未配置或不可用（本地引擎尚未实现）');
    }

    final completer = Completer<String>();

    try {
      await engine.generate(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        onToken: (token) {
          onToken?.call(token);
        },
        onComplete: (fullText) {
          if (!completer.isCompleted) completer.complete(fullText);
        },
        onError: (error) {
          if (!completer.isCompleted) {
            completer.completeError(Exception('翻译生成失败：$error'));
          }
        },
      );

      final result = await completer.future;
      return result.trim();
    } finally {
      await engine.dispose();
    }
  }

  /// 翻译整个会话的所有 segments。
  ///
  /// - [sessionId] 录音会话 ID
  /// - [targetLang] 目标语言代码（默认 'en'）
  /// - [onToken] 流式 token 回调，每生成一个 token 触发一次
  /// - [onProgress] 进度回调（0.0-1.0）
  ///
  /// 流程：获取 segments → 拼接原文检测源语言 → 源语言等于目标语言直接返回 →
  /// 获取热词 + 构建 prompt → 调用 LLM 流式生成 → 按行解析对应 segments →
  /// 逐条回写数据库 → 返回更新后的 segments 列表。
  ///
  /// LLM 返回行数与 segments 数不一致时的处理：
  /// - 行数少于段数：超出索引的段译文留空
  /// - 行数多于段数：最后一段合并剩余所有行（空格连接）
  Future<List<TranscriptSegment>> translateSession(
    String sessionId, {
    String targetLang = 'en',
    void Function(String)? onToken,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.0);

    // 1. 获取全部 segments（按 startTime 升序）
    final segments = await _storage.getSegments(sessionId);
    if (segments.isEmpty) {
      onProgress?.call(1.0);
      return segments;
    }

    // 2. 拼接原文（每段一行）并检测源语言
    final sourceText = segments.map((s) => s.originalText).join('\n');
    final sourceLang = _detectSourceLang(sourceText);

    // 3. 源语言等于目标语言，无需翻译
    if (sourceLang == targetLang) {
      onProgress?.call(1.0);
      return segments;
    }

    // 4. 获取热词参考词表
    final hotwords = await _hotwordDict.getHotwordTextForPrompt();

    // 5. 构建 prompt
    final systemPrompt = _buildSystemPrompt(sourceLang, targetLang);
    final userPrompt = _buildUserPrompt(hotwords, sourceText);

    onProgress?.call(0.1);

    // 6. 调用 LLM 流式生成（onToken 透传给调用方）
    final translatedText = await _generateTranslation(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      onToken: onToken,
    );

    onProgress?.call(0.9);

    // 7. 按行分割，对应 segments 逐条回写数据库
    final lines = translatedText.split('\n');
    final updatedSegments = <TranscriptSegment>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      String translation;
      if (i < lines.length) {
        if (i == segments.length - 1 && lines.length > segments.length) {
          // 最后一段合并剩余所有行（LLM 可能拆分了某段译文）
          translation = lines.sublist(i).join(' ').trim();
        } else {
          translation = lines[i].trim();
        }
      } else {
        // LLM 返回行数不足，该段无译文
        translation = '';
      }

      if (translation.isNotEmpty && seg.id != null) {
        await _storage.updateTranslation(seg.id!, translation);
      }
      updatedSegments.add(seg.copyWith(translation: translation));

      // 进度：0.9 → 1.0 在 DB 回写阶段线性插值
      onProgress?.call(0.9 + 0.1 * (i + 1) / segments.length);
    }

    return updatedSegments;
  }

  /// 翻译单段文本。
  ///
  /// - [text] 待翻译文本
  /// - [targetLang] 目标语言代码（默认 'en'）
  /// - [onToken] 流式 token 回调
  ///
  /// 返回翻译后的文本字符串。空文本或源语言等于目标语言时原样返回。
  Future<String> translateText(
    String text, {
    String targetLang = 'en',
    void Function(String)? onToken,
  }) async {
    if (text.isEmpty) return '';

    final sourceLang = _detectSourceLang(text);
    if (sourceLang == targetLang) return text;

    final hotwords = await _hotwordDict.getHotwordTextForPrompt();
    final systemPrompt = _buildSystemPrompt(sourceLang, targetLang);
    final userPrompt = _buildUserPrompt(hotwords, text);

    return _generateTranslation(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      onToken: onToken,
    );
  }
}
