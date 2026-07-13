import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:nota/core/theme.dart';
import 'package:nota/routes/app_router.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/database_helper.dart';

final themeModeProvider = StateProvider<AppThemeMode>((ref) => AppThemeMode.dark);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // 初始化 sherpa-onnx 原生绑定（VAD + ASR 共用）。
  // initBindings() 为同步 void 函数（加载 libsherpa-onnx-c-api.so），
  // 必须在任何 sherpa 对象创建前调用一次。失败不阻塞启动（仅打印警告），
  // 后续 LocalAsrEngine.init / VadDetector 构造会再次尝试。
  try {
    sherpa_onnx.initBindings();
  } catch (e) {
    debugPrint('sherpa-onnx initBindings failed: $e');
  }

  // 启动初始化：数据库 schema 预创建。失败不阻塞启动（仅打印警告）。
  //
  // AsrModelManager / SpeakerDiarizationService 均无公开 init 方法
  //（前者按需创建模型目录、后者懒加载 extractor 且依赖模型已下载），
  // 故此处不主动调用，留待实际使用时按需初始化。
  try {
    await DatabaseHelper().database;
  } catch (e) {
    debugPrint('⚠️ 数据库初始化失败（不阻塞启动）：$e');
  }

  final savedTheme = await ThemeService.getThemeMode();
  await ThemeService.loadAccentColor();
  final prefs = await SharedPreferences.getInstance();
  final hasOnboarded = prefs.getBool('onboarded') ?? false;

  if (!hasOnboarded) {
    await prefs.setBool('onboarded', true);
  }

  runApp(ProviderScope(
    overrides: [themeModeProvider.overrideWith((ref) => savedTheme)],
    child: NotaApp(startOnHome: hasOnboarded),
  ));
}

class NotaApp extends ConsumerStatefulWidget {
  final bool startOnHome;
  const NotaApp({super.key, required this.startOnHome});

  @override
  ConsumerState<NotaApp> createState() => _NotaAppState();
}

class _NotaAppState extends ConsumerState<NotaApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 释放 LLM 引擎缓存（含本地 GB 级 GGUF 模型 + llama.cpp backend）。
    // fire-and-forget：进程退出时 Dart VM 会被回收，原生资源由 OS 清理，
    // 但热重启场景下需显式释放避免内存累积。
    unawaited(LlmTaskRouter().disposeAll());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // app 进入 detached（即将退出）：尽力释放 LLM 引擎缓存。
    // detached 后进程可能被立即杀死，异步释放可能未完成，但原生资源
    //（llama.cpp backend）的 FFI 调用是同步的，关键释放能完成。
    if (state == AppLifecycleState.detached) {
      unawaited(LlmTaskRouter().disposeAll());
    }
  }

  @override
  void didChangePlatformBrightness() {
    // 系统深浅色变化时，跟随系统模式需触发重建以应用新亮度
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'NOTA',
      debugShowCheckedModeBanner: false,
      theme: ThemeService.getTheme(themeMode),
      routerConfig: appRouter,
    );
  }
}
