import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/cloud_llm_engine.dart';
import 'package:nota/services/llm/llama_cpp_engine.dart';
import 'package:nota/services/llm/local_llm_engine.dart';

/// 按功能配置的 LLM 任务路由器。
///
/// 每个 [LlmTaskType] 可独立配置使用哪个引擎（本地 / 云端）和模型，
/// 配置持久化到 SharedPreferences（key: `llm_task_<taskType>`）。
/// 流水线各步骤通过 [getEngine] 获取对应功能的 [LlmEngine] 实例。
///
/// 引擎实例按 taskType 缓存，避免每次调用都重新加载模型（本地引擎
/// 加载 GB 级 GGUF 模型耗时数秒）。配置变更时自动 dispose 旧引擎
/// 并清除缓存，下次 [getEngine] 重新创建。
///
/// 单例，全局共享同一份配置缓存。
class LlmTaskRouter {
  LlmTaskRouter._();
  static final LlmTaskRouter _instance = LlmTaskRouter._();
  factory LlmTaskRouter() => _instance;

  /// SharedPreferences key 前缀。
  static const String _keyPrefix = 'llm_task_';

  /// 引擎实例缓存（按 taskType）。
  final Map<LlmTaskType, LlmEngine> _engineCache = {};

  /// 引擎创建中的 Future（按 taskType），用于并发去重。
  ///
  /// 多个调用方并发 [getEngine] 同一 taskType 时，复用同一个创建 Future，
  /// 避免重复加载模型（本地引擎加载 GB 级 GGUF 模型耗时数秒，并发加载会 OOM）。
  final Map<LlmTaskType, Future<LlmEngine?>> _pendingFutures = {};

  /// 获取某个功能的 LLM 配置。
  Future<LlmConfig> getConfig(LlmTaskType taskType) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix${taskType.name}';
    final json = prefs.getString(key);
    if (json == null) return _defaultConfig(taskType);
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return LlmConfig.fromJson(map);
    } catch (_) {
      return _defaultConfig(taskType);
    }
  }

  /// 设置某个功能的 LLM 配置。
  ///
  /// 配置变更时自动 dispose 缓存的旧引擎并清除缓存条目，
  /// 下次 [getEngine] 会用新配置重新创建引擎。
  Future<void> setConfig(LlmTaskType taskType, LlmConfig config) async {
    // 若有 pending 的创建 Future，等待其完成（避免旧配置引擎在 setConfig
    // 后被缓存到 _engineCache，导致下次 getEngine 返回旧配置引擎）
    final pending = _pendingFutures[taskType];
    if (pending != null) {
      await pending;
    }

    // 配置变更：dispose 旧引擎并清除缓存
    final oldEngine = _engineCache.remove(taskType);
    await oldEngine?.dispose();

    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix${taskType.name}';
    final json = jsonEncode(config.toJson());
    await prefs.setString(key, json);
  }

  /// 按任务类型返回默认配置。
  ///
  /// 工具型应用按任务差异化配置 temperature/maxTokens：
  /// - 翻译/纠错：低温度（0.1）求稳定确定输出；maxTokens 1024/4096
  ///   （翻译输出短，纠错需保留原文长度所以留足空间）
  /// - 纪要/笔记整理：中温度（0.4）允许适度组织与归纳；maxTokens 4096
  ///   支持较长结构化输出
  LlmConfig _defaultConfig(LlmTaskType taskType) {
    switch (taskType) {
      case LlmTaskType.translation:
        return const LlmConfig(
          engineType: LlmEngineType.cloud,
          maxTokens: 1024,
          temperature: 0.1,
        );
      case LlmTaskType.correction:
        return const LlmConfig(
          engineType: LlmEngineType.cloud,
          maxTokens: 4096,
          temperature: 0.1,
        );
      case LlmTaskType.summary:
      case LlmTaskType.noteOrganize:
        return const LlmConfig(
          engineType: LlmEngineType.cloud,
          maxTokens: 4096,
          temperature: 0.4,
        );
    }
  }

  /// 获取对应功能的 [LlmEngine] 实例（带缓存 + 并发去重）。
  ///
  /// 首次调用时创建并初始化引擎，后续调用直接返回缓存实例。
  /// 配置变更（[setConfig]）后缓存自动失效，下次调用重新创建。
  ///
  /// 并发调用同一 taskType 时，复用同一个创建 Future（[_pendingFutures]），
  /// 避免重复加载模型导致 OOM（本地引擎加载 GB 级 GGUF 模型耗时数秒）。
  ///
  /// 选择本地引擎但模型未下载/导入时，init 抛出 [StateError]，
  /// 调用方应捕获并提示用户去设置页配置。
  Future<LlmEngine?> getEngine(LlmTaskType taskType) async {
    // 1. 缓存命中且引擎仍就绪：直接返回
    final cached = _engineCache[taskType];
    if (cached != null && cached.isReady) return cached;

    // 2. 缓存失效：dispose 旧引擎并清除缓存条目
    if (cached != null && !cached.isReady) {
      await cached.dispose();
      _engineCache.remove(taskType);
    }

    // 3. 复用 pending 的创建 Future（并发去重）
    final pending = _pendingFutures[taskType];
    if (pending != null) return pending;

    // 4. 创建新引擎
    final future = _createAndCacheEngine(taskType);
    _pendingFutures[taskType] = future;
    try {
      return await future;
    } finally {
      _pendingFutures.remove(taskType);
    }
  }

  /// 创建并初始化引擎，缓存后返回。仅由 [getEngine] 内部调用。
  Future<LlmEngine?> _createAndCacheEngine(LlmTaskType taskType) async {
    final config = await getConfig(taskType);
    final LlmEngine engine;
    if (config.engineType == LlmEngineType.cloud) {
      engine = CloudLlmEngine();
    } else {
      engine = LocalLlmEngine();
    }
    await engine.init(config);
    _engineCache[taskType] = engine;
    return engine;
  }

  /// 释放所有缓存的引擎（app 退出时调用）。
  Future<void> disposeAll() async {
    // 等待所有 pending 完成后再 dispose（避免 dispose 仍在创建中的引擎）
    for (final pending in _pendingFutures.values) {
      await pending;
    }
    _pendingFutures.clear();

    for (final engine in _engineCache.values) {
      await engine.dispose();
    }
    _engineCache.clear();

    // 释放 llama.cpp 进程级 backend（仅 app 退出时调用）
    LlamaCppEngine.disposeBackend();
  }
}
