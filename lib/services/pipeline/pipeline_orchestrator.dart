import 'package:nota/models/note.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/pipeline/correction_service.dart';
import 'package:nota/services/pipeline/note_service.dart';
import 'package:nota/services/pipeline/speaker_diarization_service.dart';
import 'package:nota/services/pipeline/summary_service.dart';
import 'package:nota/services/pipeline/translation_service.dart';
import 'package:nota/services/pipeline/transcription_service.dart';

/// 流水线步骤枚举。
///
/// 定义端到端笔记生成流水线的各个阶段，按依赖顺序排列：
/// 转写 → 声纹区分 → 纠错 → 翻译 → 纪要 → 笔记整理。
enum PipelineStep {
  /// ASR 语音转写（流水线基础，失败则终止后续步骤）。
  transcription,

  /// 说话人声纹区分（可选，失败跳过）。
  speakerDiarization,

  /// LLM 文本纠错（可选，失败后翻译使用原文）。
  correction,

  /// LLM 翻译（可选，失败后继续纪要）。
  translation,

  /// LLM 会议纪要生成（可选，失败后继续笔记）。
  summary,

  /// LLM 笔记整理（可选，流水线最后一步）。
  noteOrganize,
}

/// 流水线配置。
///
/// 控制各步骤的开关与参数。未显式传 [PipelineConfig] 时，
/// [PipelineOrchestrator.runFullPipeline] 使用 [defaultConfig]。
class PipelineConfig {
  /// ASR 转写配置，null 表示使用 [TranscriptionService] 默认配置。
  final AsrConfig? transcribeConfig;

  /// 是否执行声纹区分。
  final bool enableSpeakerDiarization;

  /// 是否执行 LLM 纠错。
  final bool enableCorrection;

  /// 是否执行 LLM 翻译。
  final bool enableTranslation;

  /// 翻译目标语言代码（如 'en' / 'zh'）。
  final String translationTargetLang;

  /// 是否生成会议纪要。
  final bool enableSummary;

  /// 是否整理结构化笔记。
  final bool enableNoteOrganize;

  const PipelineConfig({
    this.transcribeConfig,
    this.enableSpeakerDiarization = true,
    this.enableCorrection = true,
    this.enableTranslation = false,
    this.translationTargetLang = 'en',
    this.enableSummary = true,
    this.enableNoteOrganize = true,
  });

  /// 默认配置（全部步骤开启，翻译除外）。
  static const PipelineConfig defaultConfig = PipelineConfig();
}

/// 流水线执行结果。
///
/// 汇总一次 [PipelineOrchestrator.runFullPipeline] / [runStep] 的全部产出：
/// - [segments] 为最新的转写片段（含纠错 / 译文 / 说话人等增量字段）；
/// - [notes] 为纪要与笔记整理生成的 [Note] 列表；
/// - [errors] 记录失败步骤及其错误信息（空 Map 表示全步骤成功）；
/// - [completedSteps] 记录成功完成的步骤集合。
class PipelineResult {
  final String sessionId;

  /// 转写片段（随各步骤推进逐步更新为最新状态）。
  final List<TranscriptSegment> segments;

  /// 生成的笔记列表（纪要 + 笔记整理）。
  final List<Note> notes;

  /// 各步骤错误信息，空 Map 表示全部已执行步骤成功。
  final Map<PipelineStep, String> errors;

  /// 已成功完成的步骤集合。
  final Set<PipelineStep> completedSteps;

  const PipelineResult({
    required this.sessionId,
    this.segments = const [],
    this.notes = const [],
    this.errors = const {},
    this.completedSteps = const {},
  });

  /// 是否全部已执行步骤均成功（无错误）。
  bool get isSuccess => errors.isEmpty;

  PipelineResult copyWith({
    String? sessionId,
    List<TranscriptSegment>? segments,
    List<Note>? notes,
    Map<PipelineStep, String>? errors,
    Set<PipelineStep>? completedSteps,
  }) {
    return PipelineResult(
      sessionId: sessionId ?? this.sessionId,
      segments: segments ?? this.segments,
      notes: notes ?? this.notes,
      errors: errors ?? this.errors,
      completedSteps: completedSteps ?? this.completedSteps,
    );
  }
}

/// 端到端流水线编排器（单例）。
///
/// 串联"录音 → 转写 → 声纹区分 → 纠错 → 翻译 → 纪要 → 笔记"全流程，
/// 按 [PipelineConfig] 依次调度各子服务，聚合结果为 [PipelineResult]。
///
/// 错误处理策略（某步失败不必然中断后续）：
/// - 转写失败：终止整个流水线（转写是所有后续步骤的基础）；
/// - 声纹区分失败：跳过，继续纠错；
/// - 纠错失败：继续翻译（使用 ASR 原文）；
/// - 翻译失败：继续纪要；
/// - 纪要失败：继续笔记整理；
/// - 笔记整理失败：记录错误。
class PipelineOrchestrator {
  PipelineOrchestrator._();
  static final PipelineOrchestrator _instance = PipelineOrchestrator._();
  factory PipelineOrchestrator() => _instance;

  final TranscriptionService _transcriptionService = TranscriptionService();
  final CorrectionService _correctionService = CorrectionService();
  final TranslationService _translationService = TranslationService();
  final SummaryService _summaryService = SummaryService();
  final NoteService _noteService = NoteService();

  /// 一键执行完整流水线。
  ///
  /// 按 [config]（null 用 [PipelineConfig.defaultConfig]）依次执行各步骤：
  /// 1. 转写（基础，失败则终止）
  /// 2. 声纹区分（可选，失败跳过）
  /// 3. 纠错（可选，失败用原文继续）
  /// 4. 翻译（可选，失败继续纪要）
  /// 5. 纪要（可选，失败继续笔记）
  /// 6. 笔记整理（可选，失败记录错误）
  ///
  /// 每步通过 [onStepProgress] 回调 (step, 0.0-1.0) 进度，
  /// 通过 [onLog] 回调日志信息。某步失败时记录到 [PipelineResult.errors]，
  /// 并按上述策略决定是否继续后续步骤。
  Future<PipelineResult> runFullPipeline(
    String sessionId, {
    PipelineConfig? config,
    void Function(PipelineStep step, double progress)? onStepProgress,
    void Function(String message)? onLog,
  }) async {
    final cfg = config ?? PipelineConfig.defaultConfig;
    final segments = <TranscriptSegment>[];
    final notes = <Note>[];
    final errors = <PipelineStep, String>{};
    final completed = <PipelineStep>{};

    void log(String msg) => onLog?.call(msg);

    // —— 1. 转写（基础步骤，失败则终止整个流水线）——
    log('开始转写…');
    try {
      final result = await _transcribe(sessionId, cfg, (p) {
        onStepProgress?.call(PipelineStep.transcription, p);
      });
      segments
        ..clear()
        ..addAll(result);
      completed.add(PipelineStep.transcription);
      onStepProgress?.call(PipelineStep.transcription, 1.0);
      log('转写完成，共 ${segments.length} 段');
    } catch (e) {
      errors[PipelineStep.transcription] = e.toString();
      onStepProgress?.call(PipelineStep.transcription, 1.0);
      log('转写失败，终止流水线：$e');
      return PipelineResult(
        sessionId: sessionId,
        segments: segments,
        notes: notes,
        errors: errors,
        completedSteps: completed,
      );
    }

    // —— 2. 声纹区分（可选，失败跳过继续纠错）——
    if (cfg.enableSpeakerDiarization) {
      log('开始声纹区分…');
      final result = await _diarize(sessionId, (p) {
        onStepProgress?.call(PipelineStep.speakerDiarization, p);
      });
      if (result != null) {
        segments
          ..clear()
          ..addAll(result);
        completed.add(PipelineStep.speakerDiarization);
        log('声纹区分完成');
      } else {
        errors[PipelineStep.speakerDiarization] = '声纹区分失败或服务不可用，已跳过';
        log('声纹区分失败，跳过');
      }
      onStepProgress?.call(PipelineStep.speakerDiarization, 1.0);
    }

    // —— 3. 纠错（可选，失败后翻译使用原文）——
    if (cfg.enableCorrection) {
      log('开始纠错…');
      try {
        final result = await _correct(sessionId, (p) {
          onStepProgress?.call(PipelineStep.correction, p);
        });
        segments
          ..clear()
          ..addAll(result);
        completed.add(PipelineStep.correction);
        onStepProgress?.call(PipelineStep.correction, 1.0);
        log('纠错完成');
      } catch (e) {
        errors[PipelineStep.correction] = e.toString();
        onStepProgress?.call(PipelineStep.correction, 1.0);
        log('纠错失败，后续使用原文：$e');
      }
    }

    // —— 4. 翻译（可选，失败后继续纪要）——
    if (cfg.enableTranslation) {
      log('开始翻译（目标语言：${cfg.translationTargetLang}）…');
      try {
        final result = await _translate(sessionId, cfg, (p) {
          onStepProgress?.call(PipelineStep.translation, p);
        });
        segments
          ..clear()
          ..addAll(result);
        completed.add(PipelineStep.translation);
        onStepProgress?.call(PipelineStep.translation, 1.0);
        log('翻译完成');
      } catch (e) {
        errors[PipelineStep.translation] = e.toString();
        onStepProgress?.call(PipelineStep.translation, 1.0);
        log('翻译失败，继续后续步骤：$e');
      }
    }

    // —— 5. 纪要（可选，失败后继续笔记）——
    if (cfg.enableSummary) {
      log('开始生成纪要…');
      try {
        final note = await _summarize(sessionId, (p) {
          onStepProgress?.call(PipelineStep.summary, p);
        });
        notes.add(note);
        completed.add(PipelineStep.summary);
        onStepProgress?.call(PipelineStep.summary, 1.0);
        log('纪要生成完成');
      } catch (e) {
        errors[PipelineStep.summary] = e.toString();
        onStepProgress?.call(PipelineStep.summary, 1.0);
        log('纪要生成失败，继续笔记整理：$e');
      }
    }

    // —— 6. 笔记整理（可选，流水线最后一步）——
    if (cfg.enableNoteOrganize) {
      log('开始整理笔记…');
      try {
        final note = await _organizeNote(sessionId, (p) {
          onStepProgress?.call(PipelineStep.noteOrganize, p);
        });
        notes.add(note);
        completed.add(PipelineStep.noteOrganize);
        onStepProgress?.call(PipelineStep.noteOrganize, 1.0);
        log('笔记整理完成');
      } catch (e) {
        errors[PipelineStep.noteOrganize] = e.toString();
        onStepProgress?.call(PipelineStep.noteOrganize, 1.0);
        log('笔记整理失败：$e');
      }
    }

    return PipelineResult(
      sessionId: sessionId,
      segments: segments,
      notes: notes,
      errors: errors,
      completedSteps: completed,
    );
  }

  /// 分步执行单个步骤。
  ///
  /// 只执行指定 [step]，返回包含该步骤产出的 [PipelineResult]：
  /// - 段落类步骤（转写 / 声纹 / 纠错 / 翻译）→ 填充 [PipelineResult.segments]；
  /// - 笔记类步骤（纪要 / 笔记整理）→ 填充 [PipelineResult.notes]。
  ///
  /// [onProgress] 回调该步骤的 0.0-1.0 进度。失败时错误记入 [PipelineResult.errors]。
  Future<PipelineResult> runStep(
    String sessionId,
    PipelineStep step, {
    void Function(double progress)? onProgress,
  }) async {
    final errors = <PipelineStep, String>{};
    final completed = <PipelineStep>{};
    final segments = <TranscriptSegment>[];
    final notes = <Note>[];

    try {
      switch (step) {
        case PipelineStep.transcription:
          segments.addAll(await _transcribe(
            sessionId,
            PipelineConfig.defaultConfig,
            onProgress,
          ));
        case PipelineStep.speakerDiarization:
          final result = await _diarize(sessionId, onProgress);
          if (result != null) {
            segments.addAll(result);
          } else {
            errors[step] = '声纹区分失败或服务不可用，已跳过';
          }
        case PipelineStep.correction:
          segments.addAll(await _correct(sessionId, onProgress));
        case PipelineStep.translation:
          segments.addAll(await _translate(
            sessionId,
            PipelineConfig.defaultConfig,
            onProgress,
          ));
        case PipelineStep.summary:
          notes.add(await _summarize(sessionId, onProgress));
        case PipelineStep.noteOrganize:
          notes.add(await _organizeNote(sessionId, onProgress));
      }
      completed.add(step);
    } catch (e) {
      errors[step] = e.toString();
    }

    return PipelineResult(
      sessionId: sessionId,
      segments: segments,
      notes: notes,
      errors: errors,
      completedSteps: completed,
    );
  }

  // —— 私有步骤实现 ——

  /// 转写：委托 [TranscriptionService.transcribeSession]。
  Future<List<TranscriptSegment>> _transcribe(
    String sessionId,
    PipelineConfig config,
    void Function(double)? onProgress,
  ) {
    return _transcriptionService.transcribeSession(
      sessionId,
      asrConfig: config.transcribeConfig,
      onProgress: onProgress,
    );
  }

  /// 声纹区分：委托 [SpeakerDiarizationService.processSession]。
  ///
  /// SpeakerDiarizationService 正在并行实现（Task 17b），可能尚未就绪，
  /// 失败时返回 null 表示跳过该步骤（不向调用方抛异常）。
  Future<List<TranscriptSegment>?> _diarize(
    String sessionId,
    void Function(double)? onProgress,
  ) async {
    try {
      return SpeakerDiarizationService().processSession(
        sessionId,
        onProgress: onProgress,
      );
    } catch (_) {
      return null;
    }
  }

  /// 纠错：委托 [CorrectionService.correctSession]。
  Future<List<TranscriptSegment>> _correct(
    String sessionId,
    void Function(double)? onProgress,
  ) {
    return _correctionService.correctSession(
      sessionId,
      onProgress: onProgress,
    );
  }

  /// 翻译：委托 [TranslationService.translateSession]。
  Future<List<TranscriptSegment>> _translate(
    String sessionId,
    PipelineConfig config,
    void Function(double)? onProgress,
  ) {
    return _translationService.translateSession(
      sessionId,
      targetLang: config.translationTargetLang,
      onProgress: onProgress,
    );
  }

  /// 纪要：委托 [SummaryService.generateSummary]。
  Future<Note> _summarize(
    String sessionId,
    void Function(double)? onProgress,
  ) {
    return _summaryService.generateSummary(
      sessionId,
      onProgress: onProgress,
    );
  }

  /// 笔记整理：委托 [NoteService.generateNote]。
  Future<Note> _organizeNote(
    String sessionId,
    void Function(double)? onProgress,
  ) {
    return _noteService.generateNote(
      sessionId,
      onProgress: onProgress,
    );
  }
}
