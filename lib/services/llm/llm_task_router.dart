import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/cloud_llm_engine.dart';
import 'package:nota/services/llm/local_llm_engine.dart';

/// 按功能配置的 LLM 任务路由器。
///
/// 每个 [LlmTaskType] 可独立配置使用哪个引擎（本地 / 云端）和模型，
/// 配置持久化到 SharedPreferences（key: `llm_task_<taskType>`）。
/// 流水线各步骤通过 [getEngine] 获取对应功能的 [LlmEngine] 实例。
///
/// 单例，全局共享同一份配置缓存。
class LlmTaskRouter {
  LlmTaskRouter._();
  static final LlmTaskRouter _instance = LlmTaskRouter._();
  factory LlmTaskRouter() => _instance;

  /// SharedPreferences key 前缀。
  static const String _keyPrefix = 'llm_task_';

  /// 获取某个功能的 LLM 配置。
  ///
  /// 未显式配置时返回 [_defaultConfig]（云端，maxTokens=4096，temperature=0.3）。
  Future<LlmConfig> getConfig(LlmTaskType taskType) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix${taskType.name}';
    final json = prefs.getString(key);
    if (json == null) return _defaultConfig(taskType);
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return LlmConfig.fromJson(map);
    } catch (_) {
      // 配置解析失败（格式损坏 / 版本不兼容）时回退默认
      return _defaultConfig(taskType);
    }
  }

  /// 设置某个功能的 LLM 配置。
  Future<void> setConfig(LlmTaskType taskType, LlmConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyPrefix${taskType.name}';
    final json = jsonEncode(config.toJson());
    await prefs.setString(key, json);
  }

  /// 默认配置：全部走云端。
  ///
  /// 首次使用时所有功能均默认走云端（maxTokens=4096，temperature=0.3），
  /// 用户可在设置页为每个功能独立切换为本地引擎或调整参数。
  LlmConfig _defaultConfig(LlmTaskType taskType) {
    return const LlmConfig(
      engineType: LlmEngineType.cloud,
      maxTokens: 4096,
      temperature: 0.3,
    );
  }

  /// 获取对应功能的 [LlmEngine] 实例。
  ///
  /// 根据 [getConfig] 返回的 [LlmConfig.engineType] 路由到
  /// [LocalLlmEngine] 或 [CloudLlmEngine]。
  ///
  /// 本地引擎（llama.cpp FFI）与云端引擎均已实现。
  /// 选择本地引擎但模型未下载/导入时，init 抛出 [StateError]，
  /// 调用方应捕获并提示用户去设置页配置。
  Future<LlmEngine?> getEngine(LlmTaskType taskType) async {
    final config = await getConfig(taskType);
    if (config.engineType == LlmEngineType.cloud) {
      final engine = CloudLlmEngine();
      await engine.init(config);
      return engine;
    }
    // 本地引擎（llama.cpp FFI，基于 LlamaCppEngine）
    final engine = LocalLlmEngine();
    await engine.init(config);
    return engine;
  }
}
