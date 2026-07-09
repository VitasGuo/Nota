import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:nota/models/speaker_profile.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_model_manager.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/speaker_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 说话人分离服务（单例）。
///
/// 基于 sherpa-onnx speaker embedding 实现会议场景的说话人区分，
/// 并通过 [SpeakerStorage] 完成跨会话声纹匹配。
///
/// 工作流程（[processSession]）：
/// 1. 从 [TranscriptStorage] 读取会话全部转写段落（含起止时间）；
/// 2. 从 [RecordingStorage] 定位音频文件，读取整段 WAV；
/// 3. 按 segment 的 [startTime, endTime] 切片，逐段提取声纹向量；
/// 4. 对向量做层次聚类（余弦相似度 >= [_matchThreshold] 视为同一说话人）；
/// 5. 每个聚类计算代表向量，与 [SpeakerStorage.findBestMatch] 比对：
///    - 命中已知说话人：复用其 speakerId 与 label；
///    - 未命中：创建新 [SpeakerProfile]（label = "说话人 N"）并入库；
/// 6. 将 speakerId 回写至每条 segment（[TranscriptStorage.updateSpeakerId]）；
/// 7. 返回更新后的段落列表。
///
/// 模型管理：speaker embedding 模型（3D-Speaker ER-SATD 等）通过
/// [AsrModelManager] 管理目录，模型 id 固定为 [_speakerModelId]
/// （= "speaker-embedding-zh"）。该模型仅含单个 .onnx 文件、无 tokens.txt，
/// 故下载状态以目录内是否存在 .onnx 文件为准。
class SpeakerDiarizationService {
  SpeakerDiarizationService._();
  static final SpeakerDiarizationService _instance =
      SpeakerDiarizationService._();
  factory SpeakerDiarizationService() => _instance;

  /// speaker embedding 模型 id（对应 AsrModels 预留条目）。
  static const String _speakerModelId = 'speaker-embedding-zh';

  /// 聚类 / 跨会话匹配的余弦相似度阈值。
  static const double _matchThreshold = 0.7;

  /// 过短片段（秒）不提取声纹，避免向量不可靠。
  static const double _minSegmentSeconds = 0.3;

  final RecordingStorage _recordingStorage = RecordingStorage();
  final TranscriptStorage _transcriptStorage = TranscriptStorage();
  final SpeakerStorage _speakerStorage = SpeakerStorage();
  final AsrModelManager _modelManager = AsrModelManager();

  bool _bindingsInitialized = false;
  sherpa_onnx.SpeakerEmbeddingExtractor? _extractor;

  /// 处理整个会话：提取声纹 → 聚类 → 跨会话匹配 → 回写 speakerId。
  ///
  /// [onProgress] 进度回调（0.0-1.0），主要反映声纹提取进度。
  /// 返回更新 speakerId 后的段落列表（重新查询自存储层）。
  Future<List<TranscriptSegment>> processSession(
    String sessionId, {
    void Function(double)? onProgress,
  }) async {
    final segments = await _transcriptStorage.getSegments(sessionId);
    if (segments.isEmpty) return segments;

    final audioPath = await _resolveAudioPath(sessionId);
    final wave = sherpa_onnx.readWave(audioPath);
    if (wave.samples.isEmpty) {
      throw StateError('音频读取失败或为空: $audioPath');
    }

    await _ensureExtractor();
    final sampleRate = wave.sampleRate;
    final totalSamples = wave.samples.length;

    // 逐段提取声纹向量：segmentIndex -> embedding
    final embeddings = <int, List<double>>{};
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final duration = seg.endTime - seg.startTime;
      if (duration < _minSegmentSeconds) continue; // 片段过短，跳过

      final startSample = (seg.startTime * sampleRate).round();
      var endSample = (seg.endTime * sampleRate).round();
      if (startSample >= totalSamples) continue;
      if (endSample > totalSamples) endSample = totalSamples;
      if (endSample <= startSample) continue;

      final slice = Float32List.fromList(
        wave.samples.sublist(startSample, endSample),
      );
      final emb = _computeEmbedding(slice, sampleRate);
      if (emb.isNotEmpty) {
        embeddings[i] = emb;
      }

      onProgress?.call((i + 1) / segments.length * 0.9);
    }

    // 聚类：得到每个有效 embedding 的 cluster index
    final orderedIndices = embeddings.keys.toList()..sort();
    final orderedEmbeddings =
        orderedIndices.map((k) => embeddings[k]!).toList();
    final clusterIds = clusterSpeakers(orderedEmbeddings);

    // segmentIndex -> embedding 序号
    final segIdxToEmbIdx = <int, int>{};
    for (var i = 0; i < orderedIndices.length; i++) {
      segIdxToEmbIdx[orderedIndices[i]] = i;
    }

    // cluster -> 代表向量（成员均值）
    final clusterMembers = <int, List<List<double>>>{};
    for (var i = 0; i < orderedIndices.length; i++) {
      clusterMembers.putIfAbsent(clusterIds[i], () => []).add(orderedEmbeddings[i]);
    }
    final clusterCentroids = <int, List<double>>{};
    for (final entry in clusterMembers.entries) {
      clusterCentroids[entry.key] = _meanEmbedding(entry.value);
    }

    // 跨会话匹配：cluster -> SpeakerProfile
    final existingSpeakers = await _speakerStorage.getSpeakers();
    var nextSpeakerNum = _nextSpeakerNumber(existingSpeakers);
    final clusterToSpeaker = <int, SpeakerProfile>{};
    for (final cid in clusterCentroids.keys) {
      final centroid = clusterCentroids[cid]!;
      final matched =
          await _speakerStorage.findBestMatch(centroid, _matchThreshold);
      if (matched != null) {
        clusterToSpeaker[cid] = matched;
      } else {
        final newId = 'speaker_$nextSpeakerNum';
        final profile = SpeakerProfile(
          speakerId: newId,
          label: '说话人 $nextSpeakerNum',
          embedding: centroid,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await _speakerStorage.insertSpeaker(profile);
        clusterToSpeaker[cid] = profile;
        nextSpeakerNum++;
      }
    }

    // 回写每条 segment 的 speakerId（无向量的段落携带前序 speakerId）
    String? lastSpeakerId;
    for (var i = 0; i < segments.length; i++) {
      String? speakerId;
      final embIdx = segIdxToEmbIdx[i];
      if (embIdx != null) {
        speakerId = clusterToSpeaker[clusterIds[embIdx]]?.speakerId;
        lastSpeakerId = speakerId;
      } else {
        speakerId = lastSpeakerId;
      }
      final segId = segments[i].id;
      if (speakerId != null && segId != null) {
        await _transcriptStorage.updateSpeakerId(segId, speakerId);
      }
    }

    onProgress?.call(1.0);
    return _transcriptStorage.getSegments(sessionId);
  }

  /// 提取音频片段的声纹向量。
  ///
  /// [audioPath] WAV 文件路径（16kHz 单声道）。
  /// [startTime] / [endTime] 可选，指定则只截取该时段切片，否则使用整段音频。
  /// 返回向量（维度由模型决定，通常 192 或 256）；提取失败返回空列表。
  Future<List<double>> extractEmbedding(
    String audioPath, {
    double? startTime,
    double? endTime,
  }) async {
    final file = File(audioPath);
    if (!file.existsSync()) {
      throw FileSystemException('音频文件不存在', audioPath);
    }
    await _ensureExtractor();

    final wave = sherpa_onnx.readWave(audioPath);
    if (wave.samples.isEmpty) {
      throw StateError('音频读取失败或为空: $audioPath');
    }

    Float32List samples;
    if (startTime != null && endTime != null) {
      final sr = wave.sampleRate;
      final total = wave.samples.length;
      var s = (startTime * sr).round();
      var e = (endTime * sr).round();
      if (s < 0) s = 0;
      if (e > total) e = total;
      if (e <= s) return [];
      samples = Float32List.fromList(wave.samples.sublist(s, e));
    } else {
      samples = wave.samples;
    }

    return _computeEmbedding(samples, wave.sampleRate);
  }

  /// 层次聚类：将余弦相似度 >= [_matchThreshold] 的向量归为同一说话人。
  ///
  /// 采用平均链接凝聚式层次聚类：
  /// 1. 每个向量初始自成一簇；
  /// 2. 反复寻找簇间最大平均相似度，>= 阈值则合并；
  /// 3. 直到没有簇对相似度达标。
  ///
  /// 返回与 [embeddings] 等长的 cluster index 列表（从 0 递增）。
  List<int> clusterSpeakers(List<List<double>> embeddings) {
    final n = embeddings.length;
    if (n == 0) return [];

    // 初始：每个向量自成一簇，记录成员下标
    final clusters = <List<int>>[
      for (var i = 0; i < n; i++) [i],
    ];

    // 反复合并最相似的簇
    while (clusters.length > 1) {
      double bestScore = -1.0;
      int bestA = -1;
      int bestB = -1;
      for (var a = 0; a < clusters.length; a++) {
        for (var b = a + 1; b < clusters.length; b++) {
          final score = _clusterSimilarity(
            embeddings,
            clusters[a],
            clusters[b],
          );
          if (score > bestScore) {
            bestScore = score;
            bestA = a;
            bestB = b;
          }
        }
      }
      if (bestA < 0 || bestScore < _matchThreshold) break;
      // 合并 b 到 a
      clusters[bestA].addAll(clusters[bestB]);
      clusters.removeAt(bestB);
    }

    // 生成每个原始向量的 cluster index
    final result = List<int>.filled(n, -1);
    for (var cid = 0; cid < clusters.length; cid++) {
      for (final idx in clusters[cid]) {
        result[idx] = cid;
      }
    }
    return result;
  }

  /// 释放底层 extractor（进程退出前可调用，通常无需手动调用）。
  void dispose() {
    _extractor?.free();
    _extractor = null;
  }

  // —— 内部辅助 ——

  /// 解析会话音频文件路径（优先 mic，回退 speaker）。
  Future<String> _resolveAudioPath(String sessionId) async {
    final session = await _recordingStorage.getSession(sessionId);
    if (session == null) {
      throw StateError('会话不存在: $sessionId');
    }
    final path = session.micAudioPath ?? session.speakerAudioPath;
    if (path == null || path.isEmpty) {
      throw StateError('会话 $sessionId 无可用音频文件');
    }
    if (!File(path).existsSync()) {
      throw FileSystemException('音频文件不存在', path);
    }
    return path;
  }

  /// 确保声纹提取器已初始化（幂等）。
  Future<void> _ensureExtractor() async {
    if (_extractor != null) return;

    final dir = await _modelManager.getModelDir(_speakerModelId);
    final onnxPath = _findOnnxFile(dir.path);
    if (onnxPath == null) {
      throw StateError(
        'speaker embedding 模型 $_speakerModelId 未下载，请先下载模型',
      );
    }

    if (!_bindingsInitialized) {
      sherpa_onnx.initBindings();
      _bindingsInitialized = true;
    }

    _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
      config: sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model: onnxPath,
        numThreads: 2,
        debug: false,
      ),
    );
  }

  /// 对音频切片计算声纹向量，失败返回空列表。
  List<double> _computeEmbedding(Float32List samples, int sampleRate) {
    final extractor = _extractor;
    if (extractor == null) return [];

    final stream = extractor.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      stream.inputFinished();
      if (!extractor.isReady(stream)) return [];
      final emb = extractor.compute(stream);
      return List<double>.from(emb);
    } finally {
      stream.free();
    }
  }

  /// 在 [dirPath] 及其一级子目录中查找首个 `.onnx` 文件。
  String? _findOnnxFile(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.onnx')) {
        return e.path;
      }
    }
    for (final sub in dir.listSync()) {
      if (sub is Directory) {
        for (final e in sub.listSync()) {
          if (e is File && e.path.endsWith('.onnx')) {
            return e.path;
          }
        }
      }
    }
    return null;
  }

  /// 两簇间的平均链接相似度（成员两两余弦相似度的均值）。
  double _clusterSimilarity(
    List<List<double>> embeddings,
    List<int> a,
    List<int> b,
  ) {
    double sum = 0.0;
    var count = 0;
    for (final i in a) {
      for (final j in b) {
        sum += _cosineSimilarity(embeddings[i], embeddings[j]);
        count++;
      }
    }
    return count == 0 ? 0.0 : sum / count;
  }

  /// 计算一组向量的均值向量。
  List<double> _meanEmbedding(List<List<double>> vecs) {
    if (vecs.isEmpty) return [];
    final dim = vecs.first.length;
    final sum = List<double>.filled(dim, 0.0);
    for (final v in vecs) {
      for (var i = 0; i < dim; i++) {
        sum[i] += v[i];
      }
    }
    return [for (final s in sum) s / vecs.length];
  }

  /// 余弦相似度：a·b / (|a|·|b|)。
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  /// 从已有 speaker_id（形如 speaker_N）中推算下一个可用编号。
  int _nextSpeakerNumber(List<SpeakerProfile> existing) {
    var max = -1;
    final re = RegExp(r'^speaker_(\d+)$');
    for (final sp in existing) {
      final m = re.firstMatch(sp.speakerId);
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? -1;
        if (n > max) max = n;
      }
    }
    return max + 1;
  }
}
