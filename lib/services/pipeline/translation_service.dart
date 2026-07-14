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
    'ja': '日文',
    'ko': '韩文',
    'fr': '法文',
    'de': '德文',
    'es': '西班牙文',
    'ru': '俄文',
  };

  /// 检测文本源语言：按字符 Unicode 范围统计占比，取最高者。
  ///
  /// 覆盖 8 种语言：中文 / 英文 / 日文 / 韩文 / 法德西俄用拉丁字母统一
  /// 判为 'en'（西文中翻译方向通常一致，不细分）。默认 'en'。
  String _detectSourceLang(String text) {
    if (text.isEmpty) return 'en';
    final cjk = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
    final hiragana = RegExp(r'[\u3040-\u309f\u30a0-\u30ff]').allMatches(text).length;
    final hangul = RegExp(r'[\uac00-\ud7af]').allMatches(text).length;
    final cyrillic = RegExp(r'[\u0400-\u04ff]').allMatches(text).length;

    // 优先级：日文（含假名）> 韩文 > 俄文 > 中文（汉字占比 > 30%）
    // 中日韩文可能混用汉字，但假名/韩文独占字符是更强信号
    if (hiragana > 0) return 'ja';
    if (hangul > 0) return 'ko';
    if (cyrillic > 0) return 'ru';
    if (cjk / text.length > 0.3) return 'zh';
    return 'en';
  }

  /// 获取语言中文名（未知代码原样返回）。
  String _langName(String code) => _langNames[code] ?? code;

  /// 构建 system prompt。
  ///
  /// 工具型翻译任务要求输出确定、忠实、零发散，prompt 显式约束：
  /// - 仅输出译文正文，禁止解释/前后缀/思考过程
  /// - 每行对应原文一行，保留段落结构
  /// - 数字/专有名词/术语参考热词词表保持一致
  String _buildSystemPrompt(String sourceLang, String targetLang) {
    return '你是专业翻译引擎（非对话助手）。任务：将用户提供的文本从${_langName(sourceLang)}翻译为${_langName(targetLang)}。\n'
        '规则：\n'
        '1) 保持专有名词/术语不变（参考热词词表）\n'
        '2) 保持原文语气和语义\n'
        '3) 只输出翻译结果正文，不加解释、注释、引号或任何前后缀\n'
        '4) 禁止任何对话式回复——不得出现"好的"、"以下是翻译"、"我来帮你"等寒暄或元话语，'
        '输出的第一个字必须是译文的第一个字\n'
        '5) 每行对应原文的一行，保留段落结构\n'
        '6) 数字、人名、代码、URL 保持原样不翻译\n'
        '7) 忠于原文，不增删信息，不意译发挥';
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
  /// 从 [LlmTaskRouter] 获取 translation 任务的引擎（按 taskType 缓存，
  /// 不在此处 dispose）。流式接收 token 并在完成后返回完整译文。
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

    await engine.generate(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      enableThinking: false, // 翻译是简单任务，关闭思考模式加速生成
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
