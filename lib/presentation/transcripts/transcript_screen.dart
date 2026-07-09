import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:nota/core/theme.dart';
import 'package:nota/models/note.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/pipeline/correction_service.dart';
import 'package:nota/services/pipeline/note_service.dart';
import 'package:nota/services/pipeline/pipeline_orchestrator.dart';
import 'package:nota/services/pipeline/summary_service.dart';
import 'package:nota/services/pipeline/transcription_service.dart';
import 'package:nota/services/pipeline/translation_service.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/speaker_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 纠错查看模式。
enum _ViewMode { original, corrected, compare }

/// 长时间操作的回调签名。
///
/// 参数依次为：进度回调（0.0-1.0）、状态文案回调、流式 token 回调（可空）。
typedef _OperationAction = Future<void> Function(
  void Function(double) onProgress,
  void Function(String) onStatus,
  void Function(String)? onToken,
);

/// 转写文本界面。
///
/// 展示带时间戳的逐句转写，支持说话人标签编辑、纠错前后对比，
/// 以及转写 / 纠错 / 翻译 / 生成纪要 / 整理笔记等单步操作。
class TranscriptScreen extends StatefulWidget {
  /// 录音会话 ID。
  final String sessionId;

  /// 是否在界面加载后自动触发"一键整理"全流水线。
  ///
  /// 由录音界面"一键整理"入口传入，避免用户手动逐步执行。
  final bool autoOrganize;

  const TranscriptScreen({
    super.key,
    required this.sessionId,
    this.autoOrganize = false,
  });

  @override
  State<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<TranscriptScreen> {
  final TranscriptStorage _transcriptStorage = TranscriptStorage();
  final SpeakerStorage _speakerStorage = SpeakerStorage();
  final RecordingStorage _recordingStorage = RecordingStorage();
  final TranscriptionService _transcriptionService = TranscriptionService();
  final CorrectionService _correctionService = CorrectionService();
  final TranslationService _translationService = TranslationService();
  final SummaryService _summaryService = SummaryService();
  final NoteService _noteService = NoteService();

  List<TranscriptSegment> _segments = [];
  String _sessionTitle = '转写详情';
  bool _loading = true;
  _ViewMode _viewMode = _ViewMode.corrected;

  /// 说话人标签缓存：speakerId → 用户可读标签。
  final Map<String, String> _speakerLabels = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    // 由录音"一键整理"入口进入时，首帧后自动触发全流水线
    if (widget.autoOrganize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onRunFullPipeline();
      });
    }
  }

  /// 加载会话标题 + 转写段落 + 说话人标签。
  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final session = await _recordingStorage.getSession(widget.sessionId);
      final segments = await _transcriptStorage.getSegments(widget.sessionId);

      // 预加载所有说话人标签
      _speakerLabels.clear();
      final speakerIds = segments
          .where((s) => s.hasSpeaker)
          .map((s) => s.speakerId!)
          .toSet();
      for (final id in speakerIds) {
        final sp = await _speakerStorage.getSpeaker(id);
        if (sp != null && sp.label != null && sp.label!.isNotEmpty) {
          _speakerLabels[id] = sp.label!;
        }
      }

      if (mounted) {
        setState(() {
          _sessionTitle =
              (session != null && session.title.isNotEmpty)
                  ? session.title
                  : '转写详情';
          _segments = segments;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('加载失败：$e');
      }
    }
  }

  /// 是否存在纠错文本（决定是否显示查看模式切换）。
  bool get _hasCorrected => _segments.any(
      (s) => s.correctedText != null && s.correctedText!.isNotEmpty);

  /// 时间戳格式化 [mm:ss]。
  String _formatTimestamp(double seconds) {
    final total = seconds.round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '[$m:$s]';
  }

  // ============================================================
  // 操作：转写 / 纠错 / 翻译 / 生成纪要 / 整理笔记
  // ============================================================

  /// 运行长时间操作并展示进度对话框。
  ///
  /// 对话框包含进度条、状态文案与可选的流式文本区域。
  /// 操作完成后自动刷新数据。返回 true 表示成功，false 表示失败。
  Future<bool> _runOperation({
    required String title,
    required _OperationAction action,
  }) async {
    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>('准备中…');
    final streamNotifier = ValueNotifier<String>('');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (_, value, _) => LinearProgressIndicator(
                      value: value > 0 && value < 1 ? value : null,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: statusNotifier,
                    builder: (_, value, _) => Text(
                      value,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: streamNotifier,
                    builder: (_, value, _) {
                      if (value.isEmpty) return const SizedBox.shrink();
                      return Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: Text(
                            value,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      await action(
        (p) => progressNotifier.value = p,
        (s) => statusNotifier.value = s,
        (t) => streamNotifier.value += t,
      );
      if (mounted) {
        Navigator.of(context).pop();
        await _loadData();
        return true;
      }
      return false;
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showError('操作失败：$e');
      }
      return false;
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
      streamNotifier.dispose();
    }
  }

  /// 转写：调用 TranscriptionService.transcribeSession。
  Future<void> _onTranscribe() async {
    final ok = await _runOperation(
      title: '转写中',
      action: (onProgress, onStatus, onToken) async {
        onStatus('正在转写音频…');
        await _transcriptionService.transcribeSession(
          widget.sessionId,
          onProgress: (p) {
            onProgress(p);
            onStatus('正在转写… ${(p * 100).toInt()}%');
          },
          onSegment: (seg) {
            onStatus('已转写段落：${seg.originalText.characters.take(20)}…');
          },
        );
      },
    );
    if (ok && mounted) _showSuccess('转写完成');
  }

  /// 纠错：调用 CorrectionService.correctSession，流式展示 token。
  Future<void> _onCorrect() async {
    final ok = await _runOperation(
      title: '纠错中',
      action: (onProgress, onStatus, onToken) async {
        onStatus('正在加载转写文本…');
        await _correctionService.correctSession(
          widget.sessionId,
          onToken: onToken,
          onProgress: (p) {
            onProgress(p);
            onStatus(p < 1.0 ? 'LLM 纠错生成中…' : '正在写入数据库…');
          },
        );
      },
    );
    if (ok && mounted) {
      setState(() => _viewMode = _ViewMode.corrected);
      _showSuccess('纠错完成');
    }
  }

  /// 翻译：调用 TranslationService.translateSession。
  Future<void> _onTranslate() async {
    final ok = await _runOperation(
      title: '翻译中',
      action: (onProgress, onStatus, onToken) async {
        onStatus('正在翻译…');
        await _translationService.translateSession(
          widget.sessionId,
          onToken: onToken,
          onProgress: (p) {
            onProgress(p);
            onStatus('翻译进度… ${(p * 100).toInt()}%');
          },
        );
      },
    );
    if (ok && mounted) _showSuccess('翻译完成');
  }

  /// 生成纪要：调用 SummaryService.generateSummary，完成后展示纪要预览。
  Future<void> _onGenerateSummary() async {
    Note? note;
    final ok = await _runOperation(
      title: '生成纪要中',
      action: (onProgress, onStatus, onToken) async {
        onStatus('正在生成纪要…');
        note = await _summaryService.generateSummary(
          widget.sessionId,
          onToken: onToken,
          onProgress: (p) {
            onProgress(p);
            onStatus('纪要生成中… ${(p * 100).toInt()}%');
          },
        );
      },
    );
    if (ok && mounted && note != null) {
      _showNotePreview(note!);
    }
  }

  /// 整理笔记：调用 NoteService.generateNote，完成后展示笔记预览。
  Future<void> _onGenerateNote() async {
    Note? note;
    final ok = await _runOperation(
      title: '整理笔记中',
      action: (onProgress, onStatus, onToken) async {
        onStatus('正在整理笔记…');
        note = await _noteService.generateNote(
          widget.sessionId,
          onToken: onToken,
          onProgress: (p) {
            onProgress(p);
            onStatus('笔记整理中… ${(p * 100).toInt()}%');
          },
        );
      },
    );
    if (ok && mounted && note != null) {
      _showNotePreview(note!);
    }
  }

  /// 一键整理：调用 [PipelineOrchestrator.runFullPipeline] 串联执行
  /// 转写 → 声纹 → 纠错 → 翻译 → 纪要 → 笔记全流程。
  ///
  /// 进度对话框展示当前步骤名、整体进度与日志；流水线某步失败时
  /// 编排器按既定策略保留已完成步骤结果并继续，最终汇总成功/失败
  /// 计数反馈给用户。
  Future<void> _onRunFullPipeline() async {
    const config = PipelineConfig.defaultConfig;
    final orchestrator = PipelineOrchestrator();

    // 按 config 计算启用步骤总数，用于整体进度归一化
    final enabledSteps = <PipelineStep>[
      PipelineStep.transcription,
      if (config.enableSpeakerDiarization) PipelineStep.speakerDiarization,
      if (config.enableCorrection) PipelineStep.correction,
      if (config.enableTranslation) PipelineStep.translation,
      if (config.enableSummary) PipelineStep.summary,
      if (config.enableNoteOrganize) PipelineStep.noteOrganize,
    ];
    final totalSteps = enabledSteps.length;

    final stepNameNotifier = ValueNotifier<String>('准备中…');
    final progressNotifier = ValueNotifier<double>(0.0);
    final logNotifier = ValueNotifier<String>('');
    final completedSteps = <PipelineStep>{};

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('一键整理中'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (_, value, _) => LinearProgressIndicator(
                      value: value > 0 && value < 1 ? value : null,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: stepNameNotifier,
                    builder: (_, value, _) => Text(
                      value,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: logNotifier,
                    builder: (_, value, _) {
                      if (value.isEmpty) return const SizedBox.shrink();
                      return Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: Text(
                            value,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      final result = await orchestrator.runFullPipeline(
        widget.sessionId,
        config: config,
        onStepProgress: (step, p) {
          if (p >= 1.0) completedSteps.add(step);
          final overall =
              (completedSteps.length + (p >= 1.0 ? 0.0 : p)) / totalSteps;
          progressNotifier.value = overall.clamp(0.0, 1.0);
          stepNameNotifier.value =
              '${_pipelineStepName(step)}… ${(p * 100).toInt()}%';
        },
        onLog: (msg) => logNotifier.value += '$msg\n',
      );
      if (mounted) {
        Navigator.of(context).pop();
        await _loadData();
        if (result.isSuccess) {
          _showSuccess('一键整理完成（${result.completedSteps.length}/$totalSteps 步）');
        } else {
          final failed = result.errors.entries
              .map((e) => '${_pipelineStepName(e.key)}：${e.value}')
              .join('\n');
          _showError(
            '完成 ${result.completedSteps.length}/$totalSteps 步，失败步骤：\n$failed',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showError('一键整理失败：$e');
      }
    } finally {
      stepNameNotifier.dispose();
      progressNotifier.dispose();
      logNotifier.dispose();
    }
  }

  /// 流水线步骤的可读名称（用于进度对话框与错误汇总）。
  String _pipelineStepName(PipelineStep step) {
    switch (step) {
      case PipelineStep.transcription:
        return '转写';
      case PipelineStep.speakerDiarization:
        return '声纹区分';
      case PipelineStep.correction:
        return '纠错';
      case PipelineStep.translation:
        return '翻译';
      case PipelineStep.summary:
        return '纪要';
      case PipelineStep.noteOrganize:
        return '笔记';
    }
  }

  // ============================================================
  // 说话人标签编辑
  // ============================================================

  /// 点击说话人标签 → 弹出编辑对话框。
  ///
  /// 确认后调用 SpeakerStorage.updateLabel 更新标签 +
  /// TranscriptStorage.updateSpeakerId 重新声明段落归属，刷新 UI。
  Future<void> _editSpeakerLabel(TranscriptSegment segment) async {
    if (!segment.hasSpeaker || segment.id == null) return;

    final speakerId = segment.speakerId!;
    final currentLabel = _speakerLabels[speakerId] ?? speakerId;
    final controller = TextEditingController(text: currentLabel);

    final newLabel = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('编辑说话人'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '说话人名称',
              hintText: '请输入新的说话人标签',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );

    if (newLabel == null || newLabel.isEmpty || !mounted) return;

    try {
      await _speakerStorage.updateLabel(speakerId, newLabel);
      await _transcriptStorage.updateSpeakerId(segment.id!, speakerId);
      if (mounted) {
        setState(() => _speakerLabels[speakerId] = newLabel);
        _showSuccess('已更新说话人标签');
      }
    } catch (e) {
      if (mounted) _showError('更新失败：$e');
    }
  }

  // ============================================================
  // 笔记预览对话框（纪要 / 笔记完成后展示）
  // ============================================================

  void _showNotePreview(Note note) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(note.title),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Text(
                note.content,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // SnackBar 反馈
  // ============================================================

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.accentColor,
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // UI 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(_sessionTitle),
        actions: [
          PopupMenuButton<String>(
            tooltip: '操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'organize':
                  _onRunFullPipeline();
                case 'transcribe':
                  _onTranscribe();
                case 'correct':
                  _onCorrect();
                case 'translate':
                  _onTranslate();
                case 'summary':
                  _onGenerateSummary();
                case 'note':
                  _onGenerateNote();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'organize',
                child: Text('一键整理'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'transcribe', child: Text('转写')),
              const PopupMenuItem(value: 'correct', child: Text('纠错')),
              const PopupMenuItem(value: 'translate', child: Text('翻译')),
              const PopupMenuItem(value: 'summary', child: Text('生成纪要')),
              const PopupMenuItem(value: 'note', child: Text('整理笔记')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _segments.isEmpty
              ? _buildEmptyState()
              : _buildSegmentList(),
    );
  }

  /// 空状态：提示无内容 + 开始转写按钮。
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.article_outlined,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无转写内容',
            style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _onTranscribe,
            icon: const Icon(Icons.mic),
            label: const Text('开始转写'),
          ),
        ],
      ),
    );
  }

  /// 段落列表 + 查看模式切换。
  Widget _buildSegmentList() {
    return Column(
      children: [
        if (_hasCorrected) _buildViewModeToggle(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: _segments.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) =>
                _buildSegmentCard(_segments[index]),
          ),
        ),
      ],
    );
  }

  /// 查看模式切换（原文 / 纠错后 / 对比）。
  Widget _buildViewModeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SegmentedButton<_ViewMode>(
        segments: const [
          ButtonSegment(value: _ViewMode.original, label: Text('原文')),
          ButtonSegment(value: _ViewMode.corrected, label: Text('纠错后')),
          ButtonSegment(value: _ViewMode.compare, label: Text('对比')),
        ],
        selected: {_viewMode},
        onSelectionChanged: (set) => setState(() => _viewMode = set.first),
      ),
    );
  }

  /// 单段转写卡片。
  Widget _buildSegmentCard(TranscriptSegment segment) {
    final hasCorrected =
        segment.correctedText != null && segment.correctedText!.isNotEmpty;
    final hasTranslation =
        segment.translation != null && segment.translation!.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 时间戳 + 说话人标签
            Row(
              children: [
                Text(
                  _formatTimestamp(segment.startTime),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                if (segment.hasSpeaker) _buildSpeakerChip(segment),
              ],
            ),
            const SizedBox(height: 8),
            // 文本内容（根据查看模式）
            _buildSegmentText(segment, hasCorrected),
            // 译文（斜体）
            if (hasTranslation) ...[
              const SizedBox(height: 6),
              Text(
                segment.translation!,
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 说话人标签 Chip（可点击编辑）。
  Widget _buildSpeakerChip(TranscriptSegment segment) {
    final speakerId = segment.speakerId!;
    final label = _speakerLabels[speakerId] ?? speakerId;
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.person, size: 16),
      onPressed: () => _editSpeakerLabel(segment),
      visualDensity: VisualDensity.compact,
    );
  }

  /// 根据查看模式渲染段落的文本部分。
  Widget _buildSegmentText(TranscriptSegment segment, bool hasCorrected) {
    switch (_viewMode) {
      case _ViewMode.original:
        return Text(
          segment.originalText,
          style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        );
      case _ViewMode.corrected:
        // 有纠错用纠错文本，无则回退原文
        return Text(
          hasCorrected ? segment.correctedText! : segment.originalText,
          style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        );
      case _ViewMode.compare:
        if (!hasCorrected) {
          return Text(
            segment.originalText,
            style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
          );
        }
        // 对比：纠错后为主，原文灰色删除线
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              segment.correctedText!,
              style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              segment.originalText,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
                decoration: TextDecoration.lineThrough,
                decorationColor: AppTheme.textSecondary,
              ),
            ),
          ],
        );
    }
  }
}
