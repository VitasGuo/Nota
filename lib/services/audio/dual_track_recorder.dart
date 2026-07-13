import 'package:nota/services/audio/mic_recorder.dart';
import 'package:nota/services/audio/speaker_recorder.dart';

/// 双轨同步录音器
/// 同时采集 mic + speaker 两路音频
class DualTrackRecorder {
  final MicRecorder _micRecorder = MicRecorder();
  final SpeakerRecorder _speakerRecorder = SpeakerRecorder();

  bool _isRecording = false;
  DateTime? _startTime;

  bool get isRecording => _isRecording;
  String? get micPath => _micRecorder.currentPath;
  String? get speakerPath => _speakerRecorder.currentPath;
  DateTime? get startTime => _startTime;

  /// 开始双轨录音
  /// 返回 (micPath, speakerPath)，如果某路失败对应值为 null
  Future<({String? micPath, String? speakerPath})> start(
      String sessionDir) async {
    if (_isRecording) {
      return (micPath: this.micPath, speakerPath: this.speakerPath);
    }

    _startTime = DateTime.now();

    // 并行启动两路录音
    final micFuture = _micRecorder.start(sessionDir);
    final speakerFuture = _speakerRecorder.start(sessionDir);

    final micPath = await micFuture;
    final speakerPath = await speakerFuture;

    // 至少一路成功才算开始录音
    if (micPath != null || speakerPath != null) {
      _isRecording = true;
    } else {
      _startTime = null;
    }

    return (micPath: micPath, speakerPath: speakerPath);
  }

  /// 停止双轨录音
  Future<void> stop() async {
    if (!_isRecording) return;

    await Future.wait([
      _micRecorder.stop(),
      _speakerRecorder.stop(),
    ]);

    _isRecording = false;
  }

  /// 取消
  Future<void> cancel() async {
    await Future.wait([
      _micRecorder.cancel(),
      _speakerRecorder.cancel(),
    ]);
    _isRecording = false;
    _startTime = null;
  }

  /// 释放资源
  Future<void> dispose() async {
    await _micRecorder.dispose();
    await _speakerRecorder.dispose();
  }
}
