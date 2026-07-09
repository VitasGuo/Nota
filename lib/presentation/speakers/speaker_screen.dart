import 'package:flutter/material.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/models/recording_session.dart';
import 'package:nota/models/speaker_profile.dart';
import 'package:nota/presentation/transcripts/transcript_screen.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/speaker_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 说话人管理界面（Task 21c）。
///
/// 展示声纹库中所有已建档说话人，支持：
/// - 编辑说话人标签名（[SpeakerStorage.updateLabel]）
/// - 查看关联会话列表（按 speakerId 扫描 transcripts 去重得到会话 id）
/// - 删除说话人档案（[SpeakerStorage.deleteSpeaker]，仅删档案，
///   转写中的 speaker_id 保留）
///
/// 关联会话数通过遍历全部会话转写段落聚合得到，因 [SpeakerProfile.sessionCount]
/// 在分离流程中未递增，不能作为展示依据。
class SpeakerScreen extends StatefulWidget {
  const SpeakerScreen({super.key});

  @override
  State<SpeakerScreen> createState() => _SpeakerScreenState();
}

/// 说话人卡片操作项。
enum _SpeakerAction { editLabel, viewSessions, delete }

class _SpeakerScreenState extends State<SpeakerScreen> {
  final SpeakerStorage _speakerStorage = SpeakerStorage();
  final RecordingStorage _recordingStorage = RecordingStorage();
  final TranscriptStorage _transcriptStorage = TranscriptStorage();

  List<SpeakerProfile> _speakers = [];
  /// speakerId → 关联会话 id 集合（扫描 transcripts 去重得到）。
  final Map<String, Set<String>> _speakerSessions = {};
  /// sessionId → 会话对象，供关联会话列表快速取标题/时间。
  final Map<String, RecordingSession> _sessionsById = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final speakers = await _speakerStorage.getSpeakers();
      final sessions = await _recordingStorage.getSessions();
      final sessionsById = <String, RecordingSession>{
        for (final s in sessions) s.id: s,
      };
      final speakerSessions = <String, Set<String>>{};
      for (final s in sessions) {
        final segs = await _transcriptStorage.getSegments(s.id);
        for (final seg in segs) {
          final sid = seg.speakerId;
          if (sid == null || sid.isEmpty) continue;
          speakerSessions.putIfAbsent(sid, () => <String>{}).add(s.id);
        }
      }
      if (mounted) {
        setState(() {
          _speakers = speakers;
          _sessionsById
            ..clear()
            ..addAll(sessionsById);
          _speakerSessions
            ..clear()
            ..addAll(speakerSessions);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack('加载失败：$e');
      }
    }
  }

  Future<void> _editLabel(SpeakerProfile speaker) async {
    final controller = TextEditingController(text: speaker.label ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑说话人标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入说话人名称，如「张三」'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    if (result.isEmpty) {
      _showSnack('标签名不能为空');
      return;
    }
    if (result == speaker.label) return;
    await _speakerStorage.updateLabel(speaker.speakerId, result);
    _showSnack('已更新标签');
    _loadData();
  }

  void _viewSessions(SpeakerProfile speaker) {
    final sessionIds = _speakerSessions[speaker.speakerId] ?? <String>{};
    final sessions = sessionIds
        .map((id) => _sessionsById[id])
        .whereType<RecordingSession>()
        .toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => _SpeakerSessionsScreen(
          speakerLabel: speaker.label ?? speaker.speakerId,
          sessions: sessions,
        ),
      ),
    );
  }

  Future<void> _deleteSpeaker(SpeakerProfile speaker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除说话人档案'),
        content: Text(
          '将删除「${speaker.label ?? speaker.speakerId}」的声纹档案。\n\n'
          '仅删除声纹档案，不会删除已转写的会话内容，但转写中的 speaker_id 将保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (speaker.id == null) {
      _showSnack('无法删除：缺少档案 id');
      return;
    }
    await _speakerStorage.deleteSpeaker(speaker.id!);
    _showSnack('已删除声纹档案');
    _loadData();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('说话人管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadData,
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _speakers.isEmpty
                ? _buildEmpty()
                : _buildList(),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.record_voice_over_outlined,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '尚无已知说话人',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '录音后可在转写页面为说话人打标签',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _speakers.length,
      itemBuilder: (ctx, i) => _buildSpeakerCard(_speakers[i]),
    );
  }

  Widget _buildSpeakerCard(SpeakerProfile speaker) {
    final label = speaker.label ?? '未命名说话人';
    final sessionCount = _speakerSessions[speaker.speakerId]?.length ?? 0;
    final avatarColor = _avatarColor(speaker.speakerId);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _viewSessions(speaker),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: avatarColor,
                child: Text(
                  _avatarInitial(label),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.mic_outlined,
                            size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          '关联 $sessionCount 个会话',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '创建于 ${_formatDate(speaker.createdAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_SpeakerAction>(
                icon: Icon(Icons.more_vert, color: AppTheme.textSecondary),
                onSelected: (action) {
                  switch (action) {
                    case _SpeakerAction.editLabel:
                      _editLabel(speaker);
                    case _SpeakerAction.viewSessions:
                      _viewSessions(speaker);
                    case _SpeakerAction.delete:
                      _deleteSpeaker(speaker);
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: _SpeakerAction.editLabel,
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 20),
                        SizedBox(width: 8),
                        Text('编辑标签'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _SpeakerAction.viewSessions,
                    child: Row(
                      children: [
                        Icon(Icons.list_alt_outlined, size: 20),
                        SizedBox(width: 8),
                        Text('查看关联会话'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _SpeakerAction.delete,
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline,
                            size: 20, color: Colors.redAccent),
                        SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 说话人头像背景色：按 speakerId 哈希从主题协调色板中取色，便于区分。
  Color _avatarColor(String speakerId) {
    const palette = [
      Color(0xFF9B8EC4),
      Color(0xFFE8A0BF),
      Color(0xFF4A90D9),
      Color(0xFF52A373),
      Color(0xFFE0A23C),
      Color(0xFFD9655A),
    ];
    return palette[speakerId.hashCode.abs() % palette.length];
  }

  String _avatarInitial(String label) {
    if (label.isEmpty) return '?';
    return label[0];
  }

  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// 说话人关联会话列表页。
///
/// 接收父页面已聚合好的会话列表，按开始时间倒序展示，点击进入 [TranscriptScreen]。
class _SpeakerSessionsScreen extends StatelessWidget {
  final String speakerLabel;
  final List<RecordingSession> sessions;

  const _SpeakerSessionsScreen({
    required this.speakerLabel,
    required this.sessions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('说话人：$speakerLabel')),
      body: SafeArea(
        child: sessions.isEmpty
            ? _buildEmpty()
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: sessions.length,
                itemBuilder: (ctx, i) => _buildSessionCard(context, sessions[i]),
              ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '该说话人暂无关联会话',
            style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(BuildContext context, RecordingSession session) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => TranscriptScreen(sessionId: session.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mic_outlined, size: 16, color: AppTheme.accentColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      session.title.isEmpty ? '（无标题）' : session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _formatDate(session.startTime),
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
