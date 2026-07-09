import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/cloud_asr_engine.dart';
import 'package:nota/services/asr/hotword_dictionary.dart';
import 'package:nota/services/asr/local_asr_engine.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 转写服务（单例）。
///
/// 作为 ASR 引擎与存储层之间的调度中介，职责：
/// - 根据 [AsrConfig] 选择并初始化本地 / 云端 ASR 引擎；
/// - 本地引擎自动从 [HotwordDictionary] 注入热词到 [AsrConfig.hotwords]；
/// - 调用引擎转写音频，将返回的 [TranscriptSegment] 填充 sessionId 后
///   通过 [TranscriptStorage] 批量持久化；
/// - 透传进度（0.0-1.0）与分段回调供 UI 流式展示。
///
/// 主入口：[transcribeSession]（按会话转写）/ [transcribeAudio]（按文件转写）。
class TranscriptionService {
  TranscriptionService._();
  static final TranscriptionService _instance = TranscriptionService._();
  factory TranscriptionService() => _instance;

  final RecordingStorage _recordingStorage = RecordingStorage();
  final TranscriptStorage _transcriptStorage = TranscriptStorage();
  final HotwordDictionary _hotwordDictionary = HotwordDictionary();

  /// 转写指定会话的音频。
  ///
  /// 流程：
  /// 1. 从 [RecordingStorage] 获取会话，定位音频路径
  ///    （优先 micAudioPath，回退 speakerAudioPath）；
  /// 2. 委托 [transcribeAudio] 完成引擎创建、热词注入、转写与持久化。
  ///
  /// - [asrConfig] ASR 配置，为 null 时使用默认配置（本地 + 中文）。
  /// - [onProgress] 进度回调（0.0-1.0），透传自 ASR 引擎。
  /// - [onSegment] 分段回调，每转写完一段触发一次（已填充 sessionId）。
  ///
  /// 抛出 [StateError]：会话不存在或无可用音频文件时。
  Future<List<TranscriptSegment>> transcribeSession(
    String sessionId, {
    AsrConfig? asrConfig,
    void Function(double progress)? onProgress,
    void Function(TranscriptSegment segment)? onSegment,
  }) async {
    final session = await _recordingStorage.getSession(sessionId);
    if (session == null) {
      throw StateError('会话不存在: $sessionId');
    }

    final audioPath = session.micAudioPath ?? session.speakerAudioPath;
    if (audioPath == null || audioPath.isEmpty) {
      throw StateError('会话 $sessionId 无可用音频文件');
    }

    return transcribeAudio(
      audioPath,
      sessionId,
      config: asrConfig,
      onProgress: onProgress,
      onSegment: onSegment,
    );
  }

  /// 直接转写音频文件（不依赖会话记录）。
  ///
  /// 与 [transcribeSession] 共享引擎创建、热词注入、持久化逻辑，
  /// 区别在于音频路径由调用方显式提供，[sessionId] 用于关联持久化结果。
  ///
  /// - [audioPath] 音频文件绝对路径（WAV 16kHz 单声道为标准输入）。
  /// - [sessionId] 用于关联转写结果的会话 id。
  /// - [config] ASR 配置，为 null 时使用 [_defaultConfig]。
  /// - [onProgress] / [onSegment] 同 [transcribeSession]。
  Future<List<TranscriptSegment>> transcribeAudio(
    String audioPath,
    String sessionId, {
    AsrConfig? config,
    void Function(double progress)? onProgress,
    void Function(TranscriptSegment segment)? onSegment,
  }) async {
    var effectiveConfig = config ?? _defaultConfig();

    // 本地引擎：从热词词库获取热词注入 AsrConfig.hotwords
    if (effectiveConfig.engineType == AsrEngineType.local) {
      final hotwords = await _hotwordDictionary.getAllWords();
      if (hotwords.isNotEmpty) {
        effectiveConfig = effectiveConfig.copyWith(hotwords: hotwords);
      }
    }

    final engine = await _createEngine(effectiveConfig);
    try {
      // ASR 引擎返回的 segment sessionId 为空字符串，此处填充实际 sessionId
      // 进度回调直接透传给调用方
      final segments = await engine.transcribe(
        audioPath,
        onProgress: onProgress,
        onSegment: onSegment == null
            ? null
            : (seg) => onSegment(seg.copyWith(sessionId: sessionId)),
      );

      // 填充 sessionId 后持久化
      final persisted = segments
          .map((seg) => seg.copyWith(sessionId: sessionId))
          .toList();
      await _transcriptStorage.insertSegments(persisted);

      return persisted;
    } finally {
      // 本地引擎为全局单例，不释放；云端引擎每次新建，用完释放
      if (engine is CloudAsrEngine) {
        await engine.dispose();
      }
    }
  }

  /// 根据 [config.engineType] 创建并初始化对应 ASR 引擎。
  ///
  /// - [AsrEngineType.local]：返回 [LocalAsrEngine] 单例（init 幂等，同模型不重复加载）；
  /// - [AsrEngineType.cloud]：新建 [CloudAsrEngine] 实例。
  Future<AsrEngine> _createEngine(AsrConfig config) async {
    final AsrEngine engine;
    switch (config.engineType) {
      case AsrEngineType.local:
        engine = LocalAsrEngine();
      case AsrEngineType.cloud:
        engine = CloudAsrEngine();
    }
    await engine.init(config);
    return engine;
  }

  /// 默认 ASR 配置：本地引擎 + Paraformer 中文模型（原生支持热词）。
  AsrConfig _defaultConfig() {
    return const AsrConfig(
      engineType: AsrEngineType.local,
      modelName: 'paraformer-zh',
      language: 'zh',
    );
  }
}
