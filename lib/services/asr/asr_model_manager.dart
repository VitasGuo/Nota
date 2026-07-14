import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/services/asr/asr_model_info.dart';

/// 本地 ASR 模型管理器（单例）。
///
/// 负责 sherpa-onnx 模型文件与 VAD 模型的下载、加载、切换与删除：
/// - 模型根目录：`{applicationDocuments}/asr_models/`
/// - 单个模型目录：`{asr_models}/{modelId}/`
/// - 下载源与元信息来自 [AsrModels.available] 预置清单。
///
/// 解压后的归档通常含一层顶层目录（如 `sherpa-onnx-sense-voice-small/`），
/// 故通过 [getActiveModelPath] 返回实际包含 `tokens.txt` 的子目录路径，
/// 供 [LocalAsrEngine] 定位具体模型文件。
class AsrModelManager {
  AsrModelManager._();
  static final AsrModelManager _instance = AsrModelManager._();
  factory AsrModelManager() => _instance;

  /// 模型根目录名。
  static const String _modelsRootName = 'asr_models';

  /// VAD 模型子目录名（位于 asr_models/ 下）。
  static const String _vadDirName = 'vad';

  /// VAD 模型文件名。
  static const String _vadFileName = 'silero_vad.onnx';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30), // 大文件下载（~239MB）
    ),
  );

  /// 返回模型根目录 `{docsDir}/asr_models/`，不存在则创建。
  Future<Directory> getModelsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _modelsRootName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 返回单个模型目录 `{docsDir}/asr_models/{modelId}/`，不存在则创建。
  Future<Directory> getModelDir(String modelId) async {
    final root = await getModelsDir();
    final dir = Directory(p.join(root.path, modelId));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 返回 VAD 模型目录 `{docsDir}/asr_models/vad/`，不存在则创建。
  Future<Directory> getVadModelDir() async {
    final root = await getModelsDir();
    final dir = Directory(p.join(root.path, _vadDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 返回 VAD 模型文件路径 `{docsDir}/asr_models/vad/silero_vad.onnx`。
  ///
  /// 供 [VadDetector] 构造时传入。若文件不存在且 assets 内置了 VAD 模型，
  /// 自动从 assets 释放到目标路径（首次调用时）。
  Future<String> getVadModelPath() async {
    final dir = await getVadModelDir();
    final path = p.join(dir.path, _vadFileName);
    // 自动从 assets 释放内置 VAD 模型
    if (!File(path).existsSync()) {
      await _ensureVadModelFromAssets(path);
    }
    return path;
  }

  /// 检查 VAD 模型是否已下载：直接探测 .onnx 文件存在（无 tokens.txt）。
  ///
  /// 若文件不存在但 assets 内置了 VAD 模型，自动释放并返回 true。
  Future<bool> isVadModelDownloaded() async {
    final path = await getVadModelPath();
    return File(path).existsSync();
  }

  /// 从 app assets 释放内置 VAD 模型到目标路径。
  ///
  /// VAD 模型（silero_vad.onnx，~2.2MB）已内置到 `assets/models/silero_vad.onnx`，
  /// 首次调用时复制到 `{docsDir}/asr_models/vad/silero_vad.onnx`，
  /// 避免用户因网络问题（GitHub 下载被墙）无法使用实时录音功能。
  ///
  /// 若 assets 中无此文件（如降级构建），静默失败，调用方可回退到网络下载。
  Future<void> _ensureVadModelFromAssets(String targetPath) async {
    try {
      final bytes = await rootBundle.load('assets/models/silero_vad.onnx');
      final file = File(targetPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    } catch (e) {
      // assets 中无内置 VAD 模型，静默失败
    }
  }

  /// 检查模型是否已下载。
  ///
  /// - VAD 模型（[AsrModels.vadModelId]）：直接探测 .onnx 文件存在
  ///   （silero-vad 为单文件，无 tokens.txt）
  /// - ASR 转写模型：目录存在且同时包含 `tokens.txt` 与至少一个 `.onnx` 文件
  Future<bool> isModelDownloaded(String modelId) async {
    if (modelId == AsrModels.vadModelId) {
      return isVadModelDownloaded();
    }

    final dir = await getModelDir(modelId);
    if (!dir.existsSync()) return false;

    final tokensFile = _findFile(dir, 'tokens.txt');
    if (tokensFile == null) return false;

    return _findOnnxFiles(dir).isNotEmpty;
  }

  /// 返回已下载的预置模型清单。
  ///
  /// 对照 [AsrModels.available] 逐项检查本地是否存在。
  Future<List<AsrModelInfo>> getDownloadedModels() async {
    final result = <AsrModelInfo>[];
    for (final m in AsrModels.available) {
      if (await isModelDownloaded(m.id)) {
        result.add(m);
      }
    }
    return result;
  }

  /// 下载模型。
  ///
  /// - VAD 模型（[AsrModels.vadModelId]）：优先从 app assets 释放内置 VAD
  ///   模型（~2.2MB），assets 不可用时回退到网络下载
  /// - ASR 转写模型（HF 单文件方式）：[AsrModelInfo.useHfDownload] 为 true 时，
  ///   从 hf-mirror.com 逐文件下载（国内网络友好，无需解压）
  /// - ASR 转写模型（tar.bz2 归档方式）：[AsrModelInfo.useHfDownload] 为 false 时，
  ///   从 GitHub 下载 tar.bz2 压缩包并用 archive 包流式解压到模型目录
  /// - [onProgress] 回调下载进度（0.0-1.0）
  ///
  /// v1 为简单实现：不支持断点续传，中断后重新下载会覆盖旧文件。
  Future<void> downloadModel(
    String modelId, {
    void Function(double)? onProgress,
  }) async {
    // VAD 模型：单文件直接下载，不走归档解压
    if (modelId == AsrModels.vadModelId) {
      await _downloadVadModel(onProgress: onProgress);
      return;
    }

    final info = AsrModels.getById(modelId);
    if (info == null) {
      throw ArgumentError('未知的模型 id: $modelId');
    }

    // 已下载则跳过
    if (await isModelDownloaded(modelId)) return;

    final modelDir = await getModelDir(modelId);

    // 清理可能残留的旧文件，避免新旧混合
    if (modelDir.existsSync()) {
      await modelDir.delete(recursive: true);
    }
    await modelDir.create(recursive: true);

    if (info.useModelScopeDownload) {
      // ModelScope 下载（魔搭社区，国内网络最友好）
      await _downloadFromModelScope(info, modelDir, onProgress);
      return;
    }

    if (info.useHfDownload) {
      // HF 单文件下载（hf-mirror.com 镜像，国内网络友好）
      await _downloadFromHfMirror(info, modelDir, onProgress);
      return;
    }

    // tar.bz2 归档下载 + 解压（GitHub 源，国内可能超时）
    final ext = _archiveExt(info.downloadUrl);
    final tempDir = await Directory.systemTemp.createTemp('nota_asr_');
    final archivePath = p.join(tempDir.path, '$modelId$ext');

    try {
      await _dio.download(
        info.downloadUrl,
        archivePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );
      // 流式解压到模型目录（extractFileToDisk 支持 tar.bz2 / tar.gz / zip）
      await extractFileToDisk(archivePath, modelDir.path);
    } finally {
      // 清理临时文件与目录
      final f = File(archivePath);
      if (f.existsSync()) {
        try {
          await f.delete();
        } catch (_) {}
      }
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 从魔搭社区（ModelScope）逐文件下载模型（国内首选下载方式）。
  ///
  /// [info.modelscopeRepo] 为 ModelScope 模型 ID（如
  /// `xiaowangge/sherpa-onnx-sense-voice-small`），
  /// [info.modelscopeFiles] 为需要下载的文件列表（如
  /// `['model_q8.onnx', 'tokens.txt']`）。
  ///
  /// 下载 URL 格式：
  /// `https://www.modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={file}`
  /// ModelScope API 返回 302 重定向到实际文件存储 URL，Dio 自动跟随。
  /// 每个文件直接下载到 [modelDir]，无需解压。进度按 [info.sizeBytes] 加权。
  Future<void> _downloadFromModelScope(
    AsrModelInfo info,
    Directory modelDir,
    void Function(double)? onProgress,
  ) async {
    const baseUrl = 'https://www.modelscope.cn/api/v1/models';
    final totalSize = info.sizeBytes;
    var downloadedBytes = 0;

    for (final fileName in info.modelscopeFiles) {
      final url =
          '$baseUrl/${info.modelscopeRepo}/repo?Revision=master&FilePath=$fileName';
      final outPath = p.join(modelDir.path, fileName);
      final fileStartBytes = downloadedBytes;

      await _dio.download(
        url,
        outPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            final current = fileStartBytes + received;
            onProgress((current / totalSize).clamp(0.0, 1.0));
          }
        },
      );

      // 累加实际下载文件大小
      downloadedBytes = fileStartBytes + await File(outPath).length();
    }

    onProgress?.call(1.0);
  }

  /// 从 hf-mirror.com 逐文件下载 sherpa-onnx 模型（HF 单文件方式）。
  ///
  /// [info.hfRepo] 为 HF 仓库路径（如 `csukuangfj/sherpa-onnx-paraformer-zh-2023-03-28`），
  /// [info.hfFiles] 为需要下载的文件列表（如 `['model.int8.onnx', 'tokens.txt']`）。
  ///
  /// 下载 URL 格式：`https://hf-mirror.com/{hfRepo}/resolve/main/{fileName}`
  /// 每个文件直接下载到 [modelDir]，无需解压。进度按 [info.sizeBytes] 加权。
  Future<void> _downloadFromHfMirror(
    AsrModelInfo info,
    Directory modelDir,
    void Function(double)? onProgress,
  ) async {
    const hfMirror = 'https://hf-mirror.com';
    final totalSize = info.sizeBytes;
    var downloadedBytes = 0;

    for (final fileName in info.hfFiles) {
      final url = '$hfMirror/${info.hfRepo}/resolve/main/$fileName';
      final outPath = p.join(modelDir.path, fileName);
      final fileStartBytes = downloadedBytes;

      await _dio.download(
        url,
        outPath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            final current = fileStartBytes + received;
            onProgress((current / totalSize).clamp(0.0, 1.0));
          }
        },
      );

      // 累加实际下载文件大小（total 仅在回调作用域内可用）
      downloadedBytes = fileStartBytes + await File(outPath).length();
    }

    onProgress?.call(1.0);
  }

  /// 删除模型。
  ///
  /// - VAD 模型：删除 `asr_models/vad/` 目录（含 .onnx 文件）
  /// - ASR 转写模型：删除模型目录
  Future<void> deleteModel(String modelId) async {
    if (modelId == AsrModels.vadModelId) {
      final dir = await getVadModelDir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      return;
    }
    final dir = await getModelDir(modelId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 下载 VAD 模型（silero_vad.onnx 单文件，直接落盘到 [getVadModelPath]）。
  ///
  /// 优先从 app assets 释放内置 VAD 模型（~2.2MB，已打包进 APK），
  /// assets 不可用时回退到网络下载（GitHub 源，国内可能失败）。
  Future<void> _downloadVadModel({
    void Function(double)? onProgress,
  }) async {
    if (await isVadModelDownloaded()) return;

    final dir = await getVadModelDir();
    final outPath = p.join(dir.path, _vadFileName);

    // 优先从 assets 释放（内置模型，无需网络）
    await _ensureVadModelFromAssets(outPath);
    if (File(outPath).existsSync()) {
      onProgress?.call(1.0);
      return;
    }

    // 回退：网络下载（GitHub 源）
    final info = AsrModels.vadModel;
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    await _dio.download(
      info.downloadUrl,
      outPath,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );
  }

  /// 返回模型文件所在目录路径。
  ///
  /// 归档解压后通常含一层顶层目录（如 `sherpa-onnx-sense-voice-small/`），
  /// 本方法定位实际包含 `tokens.txt` 的目录并返回其绝对路径；
  /// 若未找到子目录则回退到 [getModelDir] 返回的目录。
  Future<String> getActiveModelPath(String modelId) async {
    final dir = await getModelDir(modelId);
    final inner = _findModelSubdir(dir);
    return inner?.path ?? dir.path;
  }

  // —— 内部辅助 ——

  /// 根据下载地址推断归档扩展名。
  String _archiveExt(String url) {
    if (url.endsWith('.tar.bz2')) return '.tar.bz2';
    if (url.endsWith('.tbz')) return '.tbz';
    if (url.endsWith('.tar.gz')) return '.tar.gz';
    if (url.endsWith('.tgz')) return '.tgz';
    if (url.endsWith('.tar.xz')) return '.tar.xz';
    if (url.endsWith('.zip')) return '.zip';
    return '.tar.bz2';
  }

  /// 在 [dir] 及其一级子目录中查找名为 [name] 的文件。
  File? _findFile(Directory dir, String name) {
    if (!dir.existsSync()) return null;

    final direct = File(p.join(dir.path, name));
    if (direct.existsSync()) return direct;

    for (final sub in dir.listSync()) {
      if (sub is Directory) {
        final f = File(p.join(sub.path, name));
        if (f.existsSync()) return f;
      }
    }
    return null;
  }

  /// 递归查找目录下所有 `.onnx` 文件。
  List<File> _findOnnxFiles(Directory dir) {
    final result = <File>[];
    if (!dir.existsSync()) return result;

    for (final e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.onnx')) {
        result.add(e);
      }
    }
    return result;
  }

  /// 查找包含 `tokens.txt` 的目录（模型实际根目录）。
  ///
  /// 优先检查 [dir] 本身，其次一级子目录。
  Directory? _findModelSubdir(Directory dir) {
    if (!dir.existsSync()) return null;

    final direct = File(p.join(dir.path, 'tokens.txt'));
    if (direct.existsSync()) return dir;

    for (final sub in dir.listSync()) {
      if (sub is Directory) {
        final f = File(p.join(sub.path, 'tokens.txt'));
        if (f.existsSync()) return sub;
      }
    }
    return null;
  }

  /// 释放 Dio 资源（app 退出时调用）。
  void dispose() {
    _dio.close();
  }
}
