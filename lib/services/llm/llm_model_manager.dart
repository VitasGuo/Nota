// lib/services/llm/llm_model_manager.dart
//
// GGUF 文本 LLM 模型管理器（单例）。
//
// 负责 GGUF 文本 LLM 模型的下载、导入、校验、删除与路径查询：
// - 模型根目录：`{applicationDocuments}/llm_models/`
// - 单个模型目录：`{llm_models}/{modelId}/`
// - 预置清单见 [GgufLlmModels.available]，也支持导入任意本地 .gguf 文件
//
// 与 [AsrModelManager] 的 GGUF 管理模式一致，但文本 LLM 为单文件（无 mmproj）。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/services/llm/llm_model_info.dart';

/// GGUF 文本 LLM 模型管理器（单例）。
class LlmModelManager {
  LlmModelManager._();
  static final LlmModelManager _instance = LlmModelManager._();
  factory LlmModelManager() => _instance;

  /// 模型根目录名。
  static const String _modelsRootName = 'llm_models';

  /// GGUF 文件 magic header：`GGUF`（4 字节）。
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

  final Dio _dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 30)),
  );

  /// 返回模型根目录 `{docsDir}/llm_models/`，不存在则创建。
  Future<Directory> getModelsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _modelsRootName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 返回单个模型目录 `{docsDir}/llm_models/{modelId}/`，不存在则创建。
  Future<Directory> getModelDir(String modelId) async {
    final root = await getModelsDir();
    final dir = Directory(p.join(root.path, modelId));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 校验文件是否为有效 GGUF（检查首 4 字节 magic header）。
  Future<bool> validateGgufFile(String path) async {
    final f = File(path);
    if (!f.existsSync()) return false;

    final raf = await f.open();
    try {
      final bytes = await raf.read(4);
      if (bytes.length < 4) return false;
      for (int i = 0; i < 4; i++) {
        if (bytes[i] != _ggufMagic[i]) return false;
      }
      return true;
    } finally {
      await raf.close();
    }
  }

  /// 检查预置模型是否已下载（文件存在 + magic 合法）。
  Future<bool> isModelDownloaded(String modelId) async {
    final info = GgufLlmModels.getById(modelId);
    if (info == null) return false;

    final dir = await getModelDir(modelId);
    final path = p.join(dir.path, info.file.filename);
    if (!File(path).existsSync()) return false;
    return await validateGgufFile(path);
  }

  /// 返回已下载的预置模型清单。
  Future<List<GgufLlmModelInfo>> getDownloadedModels() async {
    final result = <GgufLlmModelInfo>[];
    for (final m in GgufLlmModels.available) {
      if (await isModelDownloaded(m.id)) {
        result.add(m);
      }
    }
    return result;
  }

  /// 返回模型文件的本地路径。
  ///
  /// 调用前应确保 [isModelDownloaded] 返回 true。
  Future<String> getModelPath(String modelId) async {
    final info = GgufLlmModels.getById(modelId);
    if (info == null) {
      throw ArgumentError('未知的 LLM 模型 id: $modelId');
    }
    final dir = await getModelDir(modelId);
    return p.join(dir.path, info.file.filename);
  }

  /// 下载预置模型。
  ///
  /// [modelId] 来自 [GgufLlmModels.available] 的 id。
  /// [onProgress] 回调下载进度（0.0-1.0）。
  Future<void> downloadModel(
    String modelId, {
    void Function(double)? onProgress,
  }) async {
    final info = GgufLlmModels.getById(modelId);
    if (info == null) {
      throw ArgumentError('未知的 LLM 模型 id: $modelId');
    }
    if (info.file.downloadUrl == null) {
      throw StateError('模型 $modelId 无下载地址，请改用本地导入');
    }

    if (await isModelDownloaded(modelId)) return;

    final dir = await getModelDir(modelId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    final outPath = p.join(dir.path, info.file.filename);
    await _dio.download(
      info.file.downloadUrl!,
      outPath,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );

    if (!await validateGgufFile(outPath)) {
      throw StateError('下载文件 GGUF 校验失败: ${info.file.filename}');
    }
  }

  /// 从本地文件导入 GGUF 文本 LLM 模型。
  ///
  /// 弹出文件选择器，用户选择一个 .gguf 文件，
  /// 复制到 `{docsDir}/llm_models/{modelId}/` 并校验 magic header。
  ///
  /// - [modelId] 目标模型 id。若为预置模型 id，用预置文件名；
  ///   否则用源文件名作为目标文件名（自定义导入）。
  /// 返回 true 表示导入成功，false 表示用户取消选择。
  Future<bool> importModel(String modelId) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 GGUF 文本 LLM 模型文件',
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );
    if (result == null || result.files.isEmpty) return false;
    final srcPath = result.files.single.path!;

    if (!await validateGgufFile(srcPath)) {
      throw StateError('所选文件不是有效 GGUF（magic header 校验失败）');
    }

    final dir = await getModelDir(modelId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    // 预置模型用预置文件名，自定义导入用源文件名
    final info = GgufLlmModels.getById(modelId);
    final filename = info?.file.filename ?? p.basename(srcPath);
    final dstPath = p.join(dir.path, filename);
    await File(srcPath).copy(dstPath);

    return true;
  }

  /// 导入自定义模型（非预置清单），返回自动生成的 modelId。
  ///
  /// modelId 基于文件名生成（去扩展名），如 `qwen2.5-1.5b-instruct-q5_k_m`。
  /// 若与预置 id 冲突则追加 `_custom` 后缀。
  Future<String> importCustomModel() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 GGUF 文本 LLM 模型文件',
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );
    if (result == null || result.files.isEmpty) {
      throw StateError('用户取消选择');
    }
    final srcPath = result.files.single.path!;

    if (!await validateGgufFile(srcPath)) {
      throw StateError('所选文件不是有效 GGUF（magic header 校验失败）');
    }

    // 基于文件名生成 modelId
    final basename = p.basenameWithoutExtension(srcPath);
    var modelId = basename;
    if (GgufLlmModels.getById(modelId) != null) {
      modelId = '${modelId}_custom';
    }

    final dir = await getModelDir(modelId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    final dstPath = p.join(dir.path, p.basename(srcPath));
    await File(srcPath).copy(dstPath);

    return modelId;
  }

  /// 返回自定义导入的模型清单（扫描 llm_models/ 下不在预置清单中的目录）。
  ///
  /// 返回 (modelId, 路径) 列表，供 UI 选择。
  Future<List<({String modelId, String path, String filename})>>
      getCustomModels() async {
    final root = await getModelsDir();
    final result = <({String modelId, String path, String filename})>[];

    if (!root.existsSync()) return result;

    final presetIds = GgufLlmModels.available.map((m) => m.id).toSet();
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final modelId = p.basename(entry.path);
      if (presetIds.contains(modelId)) continue;

      // 查找目录下的 .gguf 文件
      for (final f in entry.listSync()) {
        if (f is File && f.path.endsWith('.gguf')) {
          result.add((
            modelId: modelId,
            path: f.path,
            filename: p.basename(f.path),
          ));
          break; // 每个目录只取第一个 .gguf
        }
      }
    }
    return result;
  }

  /// 删除模型（删除模型目录）。
  Future<void> deleteModel(String modelId) async {
    final dir = await getModelDir(modelId);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 释放 Dio 资源。
  Future<void> dispose() async {
    _dio.close();
  }
}
