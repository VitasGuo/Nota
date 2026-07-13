# NOTA 踩坑记录（#1-#13 继承自 xiaop v1.4.1，#14+ 为 NOTA 迁移新增）

## #1 Android 闪退 - ClassNotFoundException
- **现象**: `java.lang.ClassNotFoundException: Didn't find class "com.vitasguo.xiao_p.MainActivity"`
- **根因**: 从 Stock-King 复制后，Kotlin 源码目录仍是旧包名 `com.vitasguo.stock_king`，build.gradle.kts 改了 namespace 但源码没改
- **解决**: 创建 `android/app/src/main/kotlin/com/vitasguo/xiao_p/MainActivity.kt`，删除旧目录

## #2 LM Studio 连接超时
- **现象**: 手机连接 LM Studio 超时，PC 可以访问
- **根因**: LM Studio 绑定在链路本地地址 `169.254.83.107`，手机无法访问；需要 `lms server start --bind 0.0.0.0` 监听所有接口
- **解决**: 命令行启动 LM Studio 绑定 `0.0.0.0`，APP 中 LM Studio 不再预填默认 IP，由用户自行填写局域网地址

## #3 流式输出乱码
- **现象**: 中文回复出现乱码
- **根因**: SSE 流式返回的字节流中，中文 UTF-8 多字节字符被 chunk 截断
- **解决**: 用 `utf8.decode(chunk, allowMalformed: true)` + `leftover` 缓存不完整行

## #4 自定义人格切换预设后丢失
- **现象**: 保存自定义人格后，切换到预设再切回来，自定义人格消失
- **根因**: 人格只存了一个 `current` key，切换预设直接覆盖
- **解决**: 新增 `companion_list` key 存储所有保存的人格列表，切换只改 current 不删 list

## #5 界面卡死
- **现象**: 发送消息后界面冻结，无法点击
- **根因**: 联网搜索阻塞主线程 + 每个 token 都触发 setState 全量重建
- **解决**: 搜索加 5 秒超时；onToken 回调加 50ms 节流

## #6 Android 禁止 HTTP 明文流量
- **现象**: LM Studio 用 `http://` 被系统拦截
- **根因**: Android 9+ 默认 `cleartextTrafficPermitted=false`
- **解决**: 添加 `res/xml/network_security_config.xml`，AndroidManifest 引用

## #7 消息保存丢失
- **现象**: 对话列表有记录但进入后看不到消息内容
- **根因**: 流式 onComplete 回调中用 `widget.conversationId`，widget dispose 后引用无效导致保存静默失败
- **解决**: 流式开始前用 `final convId = widget.conversationId` 提前捕获，回调中用 `convId`

## #8 PowerShell 替换破坏 UTF-8 文件
- **现象**: 用 PowerShell `-replace` 替换中文字符串后文件乱码，Flutter 编译报错
- **根因**: PowerShell 的 `-replace` 运算符对 Unicode 处理有问题，会截断多字节字符
- **解决**: 用 Dart/Flutter 的 edit 工具逐文件替换，不要用 PowerShell 批量替换含中文的代码文件

## #9 expressions 包版本号错误导致 pub get 失败
- **现象**: `Because xiao_p depends on expressions ^5.0.0 which doesn't match any versions, version solving failed.`
- **根因**: pubspec.yaml 写了 `expressions: ^5.0.0`，但 pub.dev 上 expressions 包最新版本是 0.2.5+3（版本号体系不同，不是 5.x 大版本）
- **解决**: 改为 `expressions: ^0.2.5+3`，API（`Expression.parse()` + `ExpressionEvaluator().eval()`）完全兼容

## #10 工具系统接线断裂导致 agent 无法调用工具
- **现象**: 工具插件文件全部创建完成，但 AI 始终不调用工具，表现为"只能 chat 不能 work"
- **根因**: 4 个接线点断裂：① `tool_registry.dart` 的 `registerBuiltin()` 方法体为空（只有注释）；② `main.dart` 未调用 `registerBuiltin()`；③ `chat_service.dart` 引用已删除的 `_toolDefinitions` 且未 import `tool_registry.dart`（编译错误）；④ `expressions` 版本号错误导致 pub get 失败
- **解决**: 逐一修复 4 个断裂点：填充 registerBuiltin、main 中注册、chat_service 改用 `ToolRegistry().getEnabledSchemas()`、expressions 版本改为 ^0.2.5+3

## #11 工具系统被联网搜索开关禁用
- **现象**: 工具系统接线全部修复，日志显示 `schemasCount=7`（7个工具注册成功），但 AI 仍不调用工具
- **根因**: Agent Loop 条件为 `provider.supportsToolUse && webSearchEnabled && enabledSchemas.isNotEmpty`，其中 `webSearchEnabled` 是"联网搜索"开关，用户关闭后整个工具系统被禁用。工具系统不应由"联网搜索"开关单独控制
- **解决**: Agent Loop 条件改为 `provider.supportsToolUse && enabledSchemas.isNotEmpty`，不再依赖 `webSearchEnabled`。路径 B（规则搜索）仍由 `webSearchEnabled` 控制

## #12 Log.d 使用 dart:developer 在 flutter run 控制台不可见
- **现象**: `Log.d()` 调用了但 flutter run 控制台看不到任何输出
- **根因**: `dart:developer` 的 `dev.log()` 输出到 Dart DevTools 日志面板，不会出现在 flutter run 的 stderr/stdout 控制台中
- **解决**: 改用 `debugPrint()`，输出以 `I/flutter` 格式出现在控制台

## #13 Gradle 下载 dl.google.com 超时导致编译失败
- **现象**: `Could not download protos-32.0.1.jar` / `Read timed out` / `BUILD FAILED in 6m`
- **根因**: geolocator_android 依赖需要从 `dl.google.com` 下载 Android tools 库，国内被墙
- **解决**: 在 `android/build.gradle.kts` 和 `android/settings.gradle.kts` 中添加阿里云镜像仓库（`maven.aliyun.com/repository/google` 等）作为首选

---

## #14 ai_router_module import 路径需精确映射（不能简单前缀替换）
- **现象**: 集成 ai_router_module 后，若按"将 `package:ai_router/` 替换为 `package:nota/`"简单前缀替换，flutter analyze 报 `Target of URI doesn't exist: 'package:nota/services/ai_providers.dart'`
- **根因**: ai_router 的 services 文件（ai_providers / api_key_service / ai_router_service）复制到 `lib/services/llm/` 子目录，而非 `lib/services/`。简单前缀替换得到 `package:nota/services/ai_providers.dart`，但文件实际在 `lib/services/llm/ai_providers.dart`，路径不匹配
- **解决**: 精确映射——先替换 `package:ai_router/services/`→`package:nota/services/llm/`（services 路径补 `llm/` 段），再替换剩余 `package:ai_router/`→`package:nota/`（providers / presentation 等保持原相对结构）

## #15 ai_providers / api_key_service 集成后重复文件导致两套 AiProviderConfig 类型
- **现象**: 集成后 `lib/services/ai_providers.dart`（xiaop 旧版）与 `lib/services/llm/ai_providers.dart`（ai_router 新版）并存；api_key_service.dart 同理。两套 `AiProviderConfig` 属不同 library 即不同类型，新 `ai_config_provider` 用新版而 xiaop 代码引用旧版，潜藏类型冲突
- **根因**: xiaop 原有 `lib/services/ai_providers.dart` + `lib/services/api_key_service.dart`；ai_router 版本复制到 `lib/services/llm/`，任务说"覆盖"但目标路径不同，实际未覆盖旧版，形成重复
- **解决**: 新版是旧版严格超集（旧版所有字段 / 枚举值 / getter / 方法均保留，新增 tongyi/jimeng 枚举、isImageSupported/isVideoSupported/isTtsSupported 多模态字段、getByType 方法、getAllApiKeys 方法）。删除旧版两文件，将 `chat_service.dart` / `memory_extractor.dart` / `settings_screen.dart` / `translate_tool.dart` 的 import 重定向到 `package:nota/services/llm/` 版本

---

## #16 并行任务覆盖 lib/models/transcript.dart 导致 TranscriptSegment 类型冲突
- **现象**: `flutter analyze` 报 `The method 'toMap' isn't defined for the type 'TranscriptSegment'`（transcript_storage.dart:16/25）+ `The getter 'fromMap' isn't defined`（transcript_storage.dart:39）+ `return_of_invalid_type`
- **根因**: Task 18（存储层）与 Task 7（ASR 引擎）并行开发，两任务都向 `lib/models/transcript.dart` 写入 TranscriptSegment 定义，后写入的 Task 7 简化版（`Duration startTime`/`String text`/`String? speaker`/无 toMap）覆盖了 Task 18 存储版（`double startTime`/`String originalText`/`String? speakerId`/有 toMap/fromMap）。transcript_storage.dart import 的是被覆盖后的简化版，故 toMap/fromMap 未定义
- **解决**: 将 transcript.dart 重写为**统一模型**——保留 Task 18 存储字段（id/sessionId/double 秒时间戳/originalText/correctedText/translation + toMap/fromMap），并添加兼容 getter 供 asr_engine.dart 使用：`text`→originalText、`speaker`→speakerId、`startDuration`/`endDuration`（Duration 视图）、`startMs`/`endMs`、`hasSpeaker`、`toString`。asr_engine.dart 仅将 TranscriptSegment 作类型引用（返回值/回调参数），不访问具体字段，故不破坏其编译。后续 Task 8/9 具体 ASR 引擎实现时按 double 秒 API 构造 TranscriptSegment

---

## #17 DualTrackRecorder 早返回处局部变量遮蔽 getter 导致编译错误
- **现象**: `flutter analyze` 报 5 个 error：`return_of_invalid_type` + `referenced_before_declaration`（micPath/speakerPath）+ `read_potentially_unassigned_final`（dual_track_recorder.dart:22）
- **根因**: `DualTrackRecorder.start()` 早返回守卫 `if (_isRecording) return (micPath: micPath, speakerPath: speakerPath);` 中的 `micPath`/`speakerPath` 本意引用实例 getter（`String? get micPath`），但方法体后文声明了同名局部变量 `final micPath = await micFuture;`。Dart 中局部变量声明会**在整个作用域内**遮蔽外层同名标识符（含 getter），即使声明行在引用之后，因此早返回处的 `micPath` 解析为尚未赋值的局部 final 变量
- **解决**: 早返回处显式写 `this.micPath` / `this.speakerPath` 绕过局部遮蔽，直接访问实例 getter。规律：返回 record 类型时若字段名与实例 getter 同名、且方法内又有同名局部变量，必须用 `this.` 限定

---

## #19 DataManager 模型目录路径与 AsrModelManager 不一致，存储统计"ASR 模型"恒为 0
- **现象**: Task 21d 数据管理界面调用 `DataManager.getStorageUsage()` 后，"ASR 模型"分类占用恒显示 0 B，即便已通过 AsrModelManager 下载了数百 MB 的模型
- **根因**: `lib/services/storage/data_manager.dart:549` 的 `_modelsRootPath()` 返回 `{applicationDocuments}/models`，而 `lib/services/asr/asr_model_manager.dart:26` 的模型根目录名为 `asr_models`（`_modelsRootName = 'asr_models'`，路径 `{applicationDocuments}/asr_models/`）。两个服务对同一概念（本地 ASR 模型存储）使用了不同的目录名，DataManager 扫描 `models/`（不存在），故 `scanModelCache()`/`getStorageUsage().modelsSize` 恒为 0；同理 `cleanModelCache()` 删除的也是不存在的 `models/` 目录
- **解决**: 待后续在服务层统一目录名（建议 DataManager._modelsRootPath 改用 `asr_models` 与 AsrModelManager 对齐，或 AsrModelManager 暴露 modelsDir 供 DataManager 复用）。Task 21d 界面按任务约束"不改 services/"，直接透传 getStorageUsage() 结果，待服务层修复后界面自动显示正确值

---

## #18 笔记界面导航：未注册 GoRouter 路由 + TranscriptScreen 未实现
- **现象**: Task 21 要求 NoteListScreen 点击卡片跳 NoteDetailScreen、NoteDetailScreen"查看转写"跳 TranscriptScreen，但 app_router.dart 仅有 `/` 和 `/settings` 两条路由，且 TranscriptScreen 类尚未创建
- **根因**: 任务约束"不修改 pubspec.yaml 和现有文件"，故不能在 app_router.dart 中注册 `/notes/:id` 与 `/transcripts/:id` 路由；GoRouter 的 `context.push('/unregistered/path')` 会抛 FlutterError（路由表无匹配），运行时崩溃。TranscriptScreen（`lib/presentation/transcripts/`）属规划目录，未实现
- **解决**:
  - 笔记列表→详情：改用 `Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => NoteDetailScreen(noteId: id)))`，绕过 GoRouter 路由表，全屏压栈（rootNavigator 确保覆盖在 StatefulShellRoute 之上）
  - 转写跳转：暂以 SnackBar 提示"转写界面开发中"，待 TranscriptScreen 实现并在 app_router 注册 `/transcripts/:sessionId` 后改为 `context.push`
  - 规律：在 GoRouter 应用中，若目标页未注册路由且无法修改路由表，用 Navigator.push 是安全的回退方案；后续接线时统一迁移到 GoRouter 声明式路由

---

## #20 HotwordStorage 缺少 updateEntry，词条编辑需 delete + insert 等价实现
- **现象**: Task 21b 热词词库界面需"点击词条弹出编辑对话框修改词/权重"，但 `HotwordStorage` 仅有 `insertEntry / getEntries / getAllEntries / deleteEntry`，无 `updateEntry`，无法直接更新单条词条
- **根因**: `lib/services/storage/hotword_storage.dart` 的词条 API 设计时遗漏了 update（分组有 updateGroup，词条却没有对应 updateEntry）。Task 21b 约束"不修改 models/ 和 services/ 下的文件"，故无法补齐 updateEntry
- **解决**: 在 `lib/presentation/hotwords/hotword_screen.dart` 的 `_showEditEntryDialog` 中用 `deleteEntry(id) + insertEntry(新词条)` 等价实现编辑。副作用：词条 id 与 createdAt 会更新（排序在末尾），但词文本/权重/groupId 语义正确。后续若放宽约束，建议在 HotwordStorage 补 `updateEntry(HotwordEntry)`（`db.update('hotwords', entry.toMap(), where: 'id = ?', whereArgs: [entry.id])`），再将界面切回直接 update

---

## #21 Flutter 3.32+ 弃用 Radio.groupValue/onChanged，analyze 报 deprecated_member_use
- **现象**: Task 22 设置页本地 ASR 模型列表用 `Radio<String>(value:, groupValue:, onChanged:)` 做单选，`flutter analyze` 报 2 个 info：`'groupValue' is deprecated... Use a RadioGroup ancestor` / `'onChanged' is deprecated... Use RadioGroup to handle value change instead`（deprecated after v3.32.0-0.0.pre）
- **根因**: 项目 Flutter 3.41.x（Dart SDK ^3.11.0），已过 3.32 弃用门槛。新版 Radio 不再自带 groupValue/onChanged，改为要求上层用 `RadioGroup<T>` 祖先组件统一管理选中值与变更回调
- **解决**: 改用图标式选择——leading 为 `Icon(active ? Icons.check_circle : Icons.radio_button_unchecked)`，ListTile `onTap` 直接切换选中值，完全避开弃用 API。`flutter analyze lib\presentation\settings\settings_screen.dart` 由此降到 0 issues。规律：本工程 Flutter 版本较新，新写 UI 若需单选优先用 RadioGroup 祖先或图标式选择，勿直接用 Radio.groupValue/onChanged；DropdownButton 的 `value:` 未弃用可继续用

---

## #22 DatabaseHelper 单例访问方式：工厂构造而非 .instance 静态 getter
- **现象**: Task 23 任务描述要求在 main.dart 调用 `await DatabaseHelper.instance.database;` 触发 schema 创建，但 `flutter analyze` 会报 `The getter 'instance' isn't defined for the type 'DatabaseHelper'`
- **根因**: `lib/services/storage/database_helper.dart` 的单例实现是标准 Dart 工厂构造模式——`DatabaseHelper._()` 私有构造 + `static final _instance` + `factory DatabaseHelper() => _instance`，**没有** `static DatabaseHelper get instance` getter。任务描述按常见命名习惯写了 `.instance`，但源码实际只暴露工厂构造 `DatabaseHelper()`。同项目内 `AsrModelManager`、`SpeakerDiarizationService`、各 Storage 类均采用相同工厂构造单例模式，均无 `.instance` getter
- **解决**: 用工厂构造访问：`await DatabaseHelper().database;`。规律：本工程单例统一用工厂构造 `ClassName()` 访问（而非 `ClassName.instance`），调用前务必以源码 API 为准，勿照搬任务描述中的访问写法

---

## #23 recording_screen 用未注册的 GoRouter 路由跳转 TranscriptScreen，运行时崩溃
- **现象**: Task 24 调用链审查发现，录音结束后点击"转写"或"一键整理"，`context.push('/transcripts/$sessionId')` 抛 FlutterError（无匹配路由），App 崩溃
- **根因**: `lib/presentation/recording/recording_screen.dart:269/278` 用 `context.push('/transcripts/$sessionId')` 跳转，但 `lib/routes/app_router.dart` 仅注册了 `/`、`/notes`、`/settings`、`/about` 四条路由，**未注册** `/transcripts/:sessionId`。TranscriptScreen 虽已实现，但从录音界面无法到达。代码 268 行有 TODO 注释"TranscriptScreen 实现后由路由注册 /transcripts/:id"，但 TranscriptScreen 实现后未补注册。`flutter analyze` 无法捕获（路由匹配是运行时字符串解析，非编译期检查）
- **解决**: 二选一——①在 app_router.dart 顶层 routes 追加 `GoRoute(path: '/transcripts/:sessionId', parentNavigatorKey: _rootNavigatorKey, builder: (c, s) => TranscriptScreen(sessionId: s.pathParameters['sessionId']!))`；②参照 traps.md #18 规律，recording_screen 改用 `Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => TranscriptScreen(sessionId: sessionId)))`。注意 speaker_screen.dart:437 已用方案②正确跳转，可作参照
- **【v0.4.2 已修复】** 采用方案②：recording_screen.dart 两处 `context.push` 改为 `Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => TranscriptScreen(sessionId: sessionId[, autoOrganize: true])))`，添加 TranscriptScreen import，移除废弃 TODO 注释

---

## #24 PipelineOrchestrator 从未被 UI 调用，"一键整理"全流水线未接线
- **现象**: Task 24 调用链审查发现，`PipelineOrchestrator.runFullPipeline` / `runStep` 在全项目仅被自身文件引用（doc 注释 + 类定义），**无任何 presentation 层代码调用**。"一键整理"按钮（recording_screen:278 `action=organize`）的意图无法触达编排器
- **根因**: 两处断裂——①`recording_screen.dart:278` 传 `?action=organize` 查询参数，但 `TranscriptScreen` 构造函数仅接收 `sessionId`，**不读取路由查询参数**，`action=organize` 被静默丢弃；②TranscriptScreen 的 PopupMenu 只暴露单步操作（转写/纠错/翻译/纪要/笔记），无"一键整理"入口调用 `PipelineOrchestrator().runFullPipeline(...)`。编排器逻辑本身正确（错误处理策略、依赖注入、步骤顺序均无问题），但与 UI 断线
- **解决**: 在 TranscriptScreen 中①读取 `action=organize` 查询参数（若走 GoRouter 注册路由，用 `state.uri.queryParameters['action']`；若 Navigator.push，改传构造参数 `autoOrganize: true`），命中时自动调用 `PipelineOrchestrator().runFullPipeline(sessionId, onStepProgress:..., onLog:...)`；②或在 PopupMenu / AppBar 增加"一键整理"按钮直接调用 runFullPipeline。当前可用单步序列（转写→纠错→翻译→纪要→笔记）手动等效模拟全流程，但非一键
- **【v0.4.2 已修复】** 双管齐下：①TranscriptScreen 新增 `autoOrganize` 构造参数（录音"一键整理"入口 Navigator.push 时传 true），initState 用 `addPostFrameCallback` 首帧后自动触发 `_onRunFullPipeline`；②AppBar PopupMenu 新增"一键整理"项（首位 + PopupMenuDivider）手动触发。`_onRunFullPipeline` 调用 `PipelineOrchestrator().runFullPipeline(sessionId, config: PipelineConfig.defaultConfig, onStepProgress, onLog)`，进度对话框展示步骤名+整体进度+日志，完成后刷新数据并 SnackBar 汇总成功/失败步数

---

## #25 record_linux 0.7.2 与 record_platform_interface 1.6.0 版本不兼容导致 APK 构建失败
- **现象**: Task 24 执行 `flutter build apk --debug` 失败：`record_linux-0.7.2/lib/record_linux.dart:12:7: Error: The non-abstract class 'RecordLinux' is missing implementations for these members: - RecordMethodChannelPlatformInterface.startStream` + `hasPermission` 签名不匹配。`compileFlutterBuildDebug` 失败，BUILD FAILED in 52s
- **根因**: `pubspec.lock` 中 `record` 5.2.1 传递依赖解析出 `record_linux` 0.7.2（旧版单体实现，未实现 `startStream`）与 `record_platform_interface` 1.6.0（新版，要求 `startStream` 抽象方法 + `hasPermission` 新签名），二者源码级不兼容。`flutter pub get` 能通过（约束层面无冲突），但 `flutter build` 编译全平台 kernel snapshot（含 record_linux 的 Dart 代码）时类型检查失败。注意：`flutter analyze lib/` 仍通过（仅分析 lib/ 目录，不编译 pub cache 中的平台实现），故此前各 Task 的 analyze 通过记录有效，此为构建期才暴露的依赖问题
- **解决**: Task 24b.3 已修复。采用方案①升级 record：pubspec.yaml `record: ^5.1.0` → `record: ^6.0.0`（解析到 6.2.1）。record 6.2.1 专门更新传递依赖，将 record_linux 从 0.7.2 带到 1.3.1（与 record_platform_interface 1.6.0 兼容），record_platform_interface 保持 1.6.0 不变。record 5.x→6.x **无 AudioRecorder/RecordConfig API 破坏性变更**（6.x 仅 additive：background recording、AudioInterruptionMode、broadcast streams），mic_recorder.dart 零修改。注意：record 7.x 要求 Flutter 3.44/Dart 3.12，项目 Dart ^3.11.0 不满足，**不可用 7.x**。6.0.0 起 record_darwin 被拆分为 record_ios + record_macos，uuid/fixnum 传递依赖被移除

---

## #26 MainActivity.kt Kotlin 编译错误（被 record_linux 错误掩盖，修复 #25 后暴露）
- **现象**: Task 24b.3 修复 record_linux 后重新 `flutter build apk --debug`，kernel_snapshot 通过但 `compileDebugKotlin` 失败，5 个错误：
  - `MainActivity.kt:110:42 Argument type mismatch: actual type is 'MediaProjection?', but 'MediaProjection' was expected`
  - `MainActivity.kt:125:14 Unresolved reference 'setCaptureMode'`
  - `MainActivity.kt:125:63 Unresolved reference 'CAPTURE_MODE_ALL'`
  - `MainActivity.kt:260:27 Argument type mismatch: actual type is 'Int', but 'Long' was expected`
  - `MainActivity.kt:261:27 Argument type mismatch: actual type is 'Int', but 'Long' was expected`
- **根因**: 三类问题，均为 SpeakerRecorder 原生代码（Task 5 实现）的遗留 bug，此前被 record_linux 编译错误掩盖（kernel_snapshot 先失败，Kotlin 编译未执行到）：
  ① `getMediaProjection()` 返回 `MediaProjection?`（Kotlin 可空类型），但 `startRecordingWithProjection(projection: MediaProjection)` 参数为非空类型，直接传递可空值类型不匹配（`android/app/src/main/kotlin/com/vitasguo/nota/MainActivity.kt:108`）
  ② `AudioPlaybackCaptureConfiguration.Builder` 不存在 `setCaptureMode()` 方法，`AudioPlaybackCaptureConfiguration` 也不存在 `CAPTURE_MODE_ALL` 常量——这是对 Android API 的错误引用（API 幻觉）。Builder 仅有 `addMatchingUsage` / `addMatchingUid` / `excludeUsage` / `excludeUid` 方法，`addMatchingUsage(USAGE_MEDIA)` + `addMatchingUsage(USAGE_GAME)` 已充分指定捕获范围（`MainActivity.kt:125`）
  ③ `writeInt32LE(out: FileOutputStream, v: Long)` 期望 `Long`，但 `sampleRate`（Int=16000）和 `byteRate`（Int=sampleRate*channels*bitsPerSample/8）是 `Int` 类型变量，Kotlin 不自动将 Int 变量提升为 Long（字面量如 `16` 会自动适配，但变量不会）（`MainActivity.kt:260-261`）
- **解决**: 三处修复（`MainActivity.kt`）：
  ① line 108-111：`getMediaProjection()` 返回值加 null 检查，null 时 throw IllegalStateException（被已有 try-catch 优雅捕获，返回 PROJECTION_FAILED 错误）
  ② line 125：移除 `.setCaptureMode(AudioPlaybackCaptureConfiguration.CAPTURE_MODE_ALL)` 整行（API 不存在，addMatchingUsage 已覆盖功能）
  ③ line 262-263：`sampleRate` 和 `byteRate` 调用 `writeInt32LE` 时加 `.toLong()` 显式转换
- **规律**: `flutter build` 编译顺序为 kernel_snapshot（Dart）→ compileDebugKotlin（Kotlin）。若 kernel 阶段失败，Kotlin 阶段不会执行，原生代码的编译错误会被掩盖。修复 Dart 层依赖问题后必须重新 build 验证，不可假设"kernel 通过即构建通过"

---

## #27 AI Router 自定义接口 URL/Model/API Key 不持久化，退出丢失 + 无法测试
- **现象**: 用户在 AI Router 页面（`lib/presentation/settings/ai_router_screen.dart`）填写自定义接口 URL/Model/API Key 后：①点"测试连接"按钮无反应（按钮 disabled），数据未保存无法测试；②退出页面再进入，填写的 URL/Model/API Key 全部丢失恢复默认
- **根因**: `_ProviderCard`（StatefulWidget）三处缺陷：
  ① `_urlController`/`_modelController` 仅内存 TextEditingController，`initState`（ai_router_screen.dart:234-236 原始行）总用 `provider.defaultBaseUrl`/`defaultModel` 初始化，不读已保存值；UI 无任何持久化回调。AiConfigNotifier 虽有按 provider 持久化 model/url 机制（`_keyModel`/`_keyUrl`，key `ai_model_$provider`/`ai_url_$provider`），但 AiRouterScreen 完全未使用
  ② API Key 输入框仅 `onSubmitted`（回车键）触发 `widget.onSetKey` 保存，用户直接点"测试连接"按钮则 key 未保存
  ③ `_canTest()`（ai_router_screen.dart:328-337 原始行）检查 `widget.apiKey.isEmpty`（已保存的 provider 状态）判断是否可测试，而非 `_apiKeyController.text`（输入框当前值）。用户输入 key 未按回车保存时 `widget.apiKey` 仍为空 → `_canTest()` 返回 false → 测试按钮 disabled
- **解决**: 仅改 `lib/presentation/settings/ai_router_screen.dart`（不改 services/ 和 providers/）：
  ① URL/Model 持久化：新增 `_urlKey`/`_modelKey`（key `ai_router_url_${provider.type.name}` / `ai_router_model_${provider.type.name}`，与 AiConfigNotifier 的 `ai_url_`/`ai_model_` 命名空间隔离，因 AiRouterScreen 用于探活配置独立持久化）；`initState` 调 `_loadSavedValues()` 异步从 SharedPreferences 读取已保存值覆盖默认值；URL/Model 输入框增 `onChanged` 直接触发 `_saveUrl`/`_saveModel`（直写 SharedPreferences 不经 provider 不触发 rebuild，无需 debounce）
  ② API Key 持久化：保留 `onSubmitted`，新增 `onChanged` 500ms debounce 自动保存（经 `widget.onSetKey` 走 provider 触发 rebuild 故需 debounce 平滑）；`_doTest()` 前 `await widget.onSetKey(...)` 确保测试前已持久化
  ③ `_doTest()` 测试前自动保存：showUrlAndModel 时先 `await _saveUrl`/`_saveModel`，needsApiKey 且非内置 key 时先 `await widget.onSetKey`，再执行 `widget.onTest`（测试本身用 apiKeyOverride 直传输入值，持久化为退出后保留）
  ④ `_canTest()` 改用 `_apiKeyController.text.trim()` 判断输入框当前值替代 `widget.apiKey`（已保存状态），用户输入未保存也可测试
  ⑤ `onSetKey` 字段类型 `ValueChanged<String>`（void）→ `Future<void> Function(String)` 以支持 `_doTest` 中 `await`（确定保存完成后再测试，避免 setKey 清除 testResults 与 testProvider 设置 testResults 的竞态）；sync 回调中 fire-and-forget 调用用 `unawaited()`（dart:async）避免 unawaited_futures lint
  - **规律**: StatefulWidget 内的 TextEditingController 若需跨会话保留，必须显式持久化到 SharedPreferences/SQLite，`initState` 不能仅依赖默认值；`_canTest` 等按钮启用判断应基于输入框当前值（`controller.text`）而非已保存状态（`widget.xxx`），否则"输入未保存"时按钮误禁用；`Future<void> Function` 类型的回调在 async 方法中应 await 以保证操作顺序确定性（避免状态竞态）

---

## #30 国内 GitHub 镜像 git clone llama.cpp 不稳定，gh-proxy.com 下载 ZIP 方式成功
- **现象**: 交叉编译需获取 llama.cpp 源码，三种 git clone 方式均失败：①`gitclone.com/github.com/ggml-org/llama.cpp.git --depth 1` 卡死（60s+ 无数据下载，`.git` 仅 1.99MB 残骸，`HEAD=ref: refs/heads/.invalid`，`objects` 仅 1 个文件，残留 `shallow.lock`）；②`kkgithub.com` 镜像返回 `fatal: ... error: 504`；③GitHub 官方直连 30s 内 `llama.zip` 文件未创建
- **根因**: 国内网络对 GitHub git 协议（443）及各类镜像代理稳定性差——gitclone.com 代理转发慢/卡死、kkgithub.com 网关超时、GitHub 直连被墙。git clone 残骸（HEAD=.invalid + shallow.lock）不可恢复，必须重新获取
- **解决**: 改用 **gh-proxy.com 镜像下载 ZIP**：`curl.exe -L --silent -o llama.zip "https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/archive/refs/heads/master.zip"`（34.93MB，约 0.15MB/s 慢但成功）。解压用 .NET `[System.IO.Compression.ZipFile]::ExtractToDirectory("llama.zip","llama_extract")`（比 PowerShell `Expand-Archive` 快），整理用 `robocopy /MIR "llama_extract\llama.cpp-master" "llama.cpp"`（顺带清掉 git clone 残骸 .git）。规律：国内获取 GitHub 大仓库优先 gh-proxy.com 等 https 代理下载 ZIP，而非 git clone 协议；多镜像轮询（gh-proxy.com / mirror.ghproxy.com / ghfast.top）提高成功率；git clone 中断残骸（HEAD=.invalid）不可恢复需重新获取

---

## #31 llama.cpp 新版用 BUILD_SHARED_LIBS，旧版 LLAMA_SHARED 选项已废弃
- **现象**: 按任务描述传 `-DLLAMA_SHARED=ON` 配置 CMake，配置成功但末尾警告 `Manually-specified variables were not used by the project: LLAMA_SHARED`，担心共享库未启用
- **根因**: llama.cpp 新版（2026 master，ggml 0.15.3）顶层 `CMakeLists.txt:62` 用标准 CMake 选项 `option(BUILD_SHARED_LIBS "build shared libraries" ${BUILD_SHARED_LIBS_DEFAULT})`（默认 ON，非 MINGW/EMSCRIPTEN），**已移除** 旧版自定义 `LLAMA_SHARED` 选项。任务描述沿用旧版文档写法。ggml 子目录同样用 `BUILD_SHARED_LIBS`（`ggml/CMakeLists.txt:85`）。实际共享库已正确生成（libllama.so/libmtmd.so 等）
- **解决**: 用 `-DBUILD_SHARED_LIBS=ON`（标准选项）。`LLAMA_SHARED=ON` 可保留（CMake 忽略未知选项仅警告，无害）但无作用。规律：第三方库交叉编译时以源码 CMakeLists.txt 实际 `option()` 定义为准，勿照搬可能过时的任务/文档描述；遇 "Manually-specified variables were not used" 警告时查源码确认正确选项名

---

## #32 LLAMA_BUILD_APP 默认 ON 导致 app/download.cpp 编译失败（arg.h not found）
- **现象**: `cmake --build` 编译到约 220/274 时失败：`C:/Users/VitasGuo/Documents/SOLO/llama.cpp/app/download.cpp:1:10: fatal error: 'arg.h' file not found`，ninja 停止，BUILD_EXIT=1
- **根因**: llama.cpp 顶层 `CMakeLists.txt:111` `option(LLAMA_BUILD_APP "llama: build the unified binary" ${LLAMA_STANDALONE})`，standalone 构建时默认 ON，触发 `add_subdirectory(app)`（221-223行）构建桌面 GUI 应用 llama-app。`app/download.cpp` `#include "arg.h"`（arg.h 在 common/），但 app 目标 include 路径配置缺失导致找不到。我们只需 .so 库（mtmd/llama/ggml），不需要桌面 app
- **解决**: 配置时显式 `-DLLAMA_BUILD_APP=OFF`。交叉编译 Android 时建议一并关闭所有非库目标：`-DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF`，仅保留 `-DLLAMA_BUILD_MTMD=ON`（standalone libmtmd）。规律：交叉编译第三方库给移动端时，默认 standalone 会拉起大量桌面/CLI 目标，必须逐个 `-DXXX_BUILD_*=OFF` 关闭只留所需库目标，否则易因桌面专属依赖缺失而编译失败

---

## #28 sherpa_onnx initBindings 是顶层 void 函数（非 Future，非 SherpaOnnx.initBindings）
- **现象**: Task 5.2-5.4 需在 main.dart 调用 `initBindings()` 初始化 sherpa-onnx 原生绑定。任务描述写 `await SherpaOnnx.initBindings();`，但若照搬会①找不到 `SherpaOnnx` 类（顶层函数无类前缀）②`await` void 函数触发 `await_only_futures` lint
- **根因**: `sherpa_onnx-1.13.4/lib/sherpa_onnx.dart:99` 定义 `void initBindings([String? p])`——**顶层函数**（非类的静态方法），返回 **void**（非 Future）。它内部调用 `SherpaOnnxBindings.init(_dylib)` 同步加载 `libsherpa-onnx-c-api.so`。`_dylib` 是顶层 `final`，在 import 时即 eager 求值（`DynamicLibrary.open`），可能抛 `ArgumentError`/`MissingAssetException`。同项目 `local_asr_engine.dart:81` 已用 `sherpa_onnx.initBindings();` 同步调用（配合 `_bindingsInitialized` 幂等守卫）
- **解决**: 在 main.dart 中按源码实际签名调用：
  ```dart
  import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
  try {
    sherpa_onnx.initBindings();  // 同步 void，无 await，无 SherpaOnnx. 前缀
  } catch (e) {
    debugPrint('sherpa-onnx initBindings failed: $e');
  }
  ```
  用 `as sherpa_onnx` 前缀与 local_asr_engine.dart 风格一致。规律：第三方包 API 调用方式以 pub cache 源码为准（任务描述可能基于旧版本或臆测），尤其 `init`/`setup` 类函数需确认返回类型（void / Future）与归属（顶层 / 静态方法 / 实例方法）；`await` 仅用于 Future，对 void 函数会触发 lint

---

## #29 VAD 模型（silero_vad.onnx）与 ASR 转写模型存储结构不同，需 AsrModelManager 分支处理
- **现象**: Task 5.3 要求 AsrModelManager 管理 silero-vad 模型，但 VAD 模型是单个 .onnx 文件（~2MB，无 tokens.txt、无归档），而现有 `downloadModel` 流程假设归档（tar.bz2/zip）+ `extractFileToDisk` 解压，`isModelDownloaded` 假设 tokens.txt + .onnx 共存，`getModelDir` 路径为 `asr_models/{modelId}/`。直接复用会①下载 .onnx 当归档解压失败②isModelDownloaded 因无 tokens.txt 恒返回 false③存储路径不符任务要求 `asr_models/vad/silero_vad.onnx`
- **根因**: `asr_model_manager.dart` 原设计仅服务 ASR 转写模型（Whisper/Paraformer，归档包含 tokens.txt + model.onnx + encoder/decoder）。VAD 模型（silero_vad.onnx）是不同形态：单文件、无 tokens、无归档、独立子目录 `vad/`
- **解决**: 在 AsrModels（asr_model_info.dart）新增 `static const vadModel`（**不加入 `available` 列表**，避免污染设置页 ASR 模型选择 UI）+ `static const vadModelId = 'silero-vad'`。在 AsrModelManager 新增 VAD 专用方法 `getVadModelDir()`/`getVadModelPath()`/`isVadModelDownloaded()`，并在 `isModelDownloaded`/`downloadModel`/`deleteModel` 顶部加 `if (modelId == AsrModels.vadModelId)` 分支：VAD 走单文件 Dio 直下（`_downloadVadModel`）+ .onnx 存在探测 + 删 `vad/` 目录。规律：当新增模型形态与现有管理流程不兼容（归档 vs 单文件 / tokens.txt 依赖 vs 无依赖），优先在公共方法内分支而非另起一套 API，保持调用方接口统一（`downloadModel(id)`/`isModelDownloaded(id)`/`deleteModel(id)` 适配所有模型形态）；预置清单常量按用途分组（`available` 仅 ASR 转写模型，`vadModel` 独立常量）

---

## #33 handy-computer Qwen3-ASR Q6_K 用 qwen3_asr 架构，不兼容 llama.cpp mtmd（仅识别 qwen3vl 架构）
- **现象**: 用户指定使用 `C:\Users\VitasGuo\.lmstudio\models\handy-computer\Qwen3-ASR-1.7B-gguf\Qwen3-ASR-1.7B-Q6_K.gguf` 作为内置本地 ASR 模型。但该模型经 llama.cpp mtmd 接口加载时，`mtmd_support_audio` 返回 false（模型不支持音频输入），转写失败
- **根因**: handy-computer 仓库的 Qwen3-ASR GGUF 量化版使用 `qwen3_asr` 架构（专供 transcribe.cpp CLI 工具使用），而 llama.cpp 的 mtmd（multimodal）接口仅识别 `qwen3vl` 架构的 GGUF 文件。两套架构的音频投影器（mmproj）实现不同，`qwen3_asr` 架构的模型无法通过 mtmd 的 `mtmd_init_from_file` + `mtmd_bitmap_init_from_audio` 路径加载
- **解决**: 改用 ggml-org 官方仓库的 Q8_0 量化版本（架构为 `qwen3vl`，含配套 mmproj 文件）：
  - 主模型：`Qwen3-ASR-1.7B-Q8_0.gguf`（~2.02GB）
  - 音频投影器：`mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`（~339MB）
  - 下载源：`https://hf-mirror.com/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/`
  - 0.6B 版本同理（主模型 ~767MB + mmproj ~204MB）
  - 在 `asr_model_info.dart` 的 `GgufAsrModels.available` 中预置这两个模型，注释说明架构差异
  - 规律：GGUF 模型的 `arch` 元数据决定兼容的推理路径（llama.cpp mtmd vs transcribe.cpp），下载第三方量化版前需确认 arch 字段；官方 ggml-org 仓库的 GGUF 通常兼容 llama.cpp 最新接口

---

## #34 国内 GitHub/HF 下载 ASR 模型超时，改用魔搭社区（ModelScope）下载源
- **现象**: v0.6.0 的 GGUF ASR 模型（Qwen3-ASR ~2.4GB）从 hf-mirror.com 下载仍不稳定；sherpa-onnx ASR 模型（Whisper/Paraformer）下载源为 GitHub releases（`github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/...`），国内 Dio 下载报 `DioException`（连接超时/读取超时）。用户反馈"下载好像也下载不下来，提示下载失败 dioexception"，录音功能因缺少 VAD 模型（实际 VAD 已内置但 ASR 模型下载失败导致引擎不可用）无法使用
- **根因**: 国内网络对 GitHub（含 releases 大文件下载）及 hf-mirror.com 镜像稳定性差，大文件（数百 MB ~ GB 级）下载易超时。原 AsrModelManager 仅支持两种下载源：①HF 镜像（hf-mirror.com，`_downloadFromHfMirror`）；②tar.bz2 归档（GitHub releases，`_downloadFromArchive`），均依赖境外网络
- **解决**: 新增 ModelScope（魔搭社区）下载源——阿里达摩院运营的国内模型托管平台，国内访问稳定。在 `AsrModelInfo` 新增 `modelscopeRepo`（魔搭模型 ID）+ `modelscopeFiles`（文件列表）字段 + `useModelScopeDownload` getter。`AsrModelManager.downloadModel` 新增 ModelScope 分支（优先于 HF 分支），`_downloadFromModelScope` 逐文件下载：
  - URL 格式：`https://www.modelscope.cn/api/v1/models/{modelscopeRepo}/repo?Revision=master&FilePath={fileName}`
  - API 返回 302 重定向到实际文件存储 URL，Dio 自动跟随
  - 进度按 `info.sizeBytes` 加权计算（多文件累积），用 `await File(outPath).length()` 获取实际下载字节数（避免 `onReceiveProgress` 回调的 `total` 作用域问题，同 #27 修复经验）
  - Dio BaseOptions 新增 `receiveTimeout: Duration(minutes: 30)` 支持大文件下载
  - 规律：国内分发模型优先接入魔搭社区（ModelScope）作为下载源，URL API 格式统一（`/api/v1/models/{repo}/repo?Revision=master&FilePath={file}`），302 重定向由 HTTP 客户端自动处理无需手动解析

---

## #35 sherpa-onnx SenseVoice 模型配置：OfflineSenseVoiceModelConfig + useInverseTextNormalization
- **现象**: v0.8.0 新增 SenseVoice Small 模型支持，需在 `SherpaRealtimeAsrEngine._buildRecognizerConfig` 中配置。SenseVoice 与 Whisper/Paraformer 的 sherpa-onnx 配置方式不同，需用独立的 `OfflineSenseVoiceModelConfig`
- **根因**: sherpa-onnx 1.13.4 对不同 ASR 模型架构提供独立的 Config 类：Whisper 用 `OfflineWhisperModelConfig`，Paraformer 用 `OfflineParaformerModelConfig`，SenseVoice 用 `OfflineSenseVoiceModelConfig`。SenseVoice 模型只需单文件 `model_q8.onnx` + `tokens.txt`（无 encoder/decoder 分离），支持语言参数（zh/en/yue/ja/ko/auto）与逆文本归一化（ITN，将"一二三"转为"123"等）
- **解决**: 在 `_buildRecognizerConfig` 新增 SenseVoice 分支（`info.id.startsWith('sensevoice')`）：
  ```dart
  modelConfig = sherpa_onnx.OfflineModelConfig(
    senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
      model: modelPath,           // model_q8.onnx 路径
      language: _senseVoiceLanguage(language),  // zh/en/yue/ja/ko，其他返回 auto
      useInverseTextNormalization: true,  // 启用逆文本归一化
    ),
    tokens: tokensPath,
    numThreads: 2,
    debug: false,
  );
  ```
  - `_senseVoiceLanguage` 映射：zh→zh / en→en / yue→yue / ja→ja / ko→ko / 其他→auto（自动检测）
  - 模型文件定位：`_findModelFile(modelDirPath, 'model')` ?? `_findFirstOnnx(modelDirPath)` 兼容不同命名
  - 规律：sherpa-onnx 对每种 ASR 架构有独立 Config 类，新增模型支持时查 sherpa_onnx Dart 包源码确认对应 Config 类型与必填字段；SenseVoice 的 `useInverseTextNormalization: true` 默认开启 ITN 提升文本可读性

---

## #36 Stream 重复订阅 — "bad state: already been listened to"
- **现象**: 点击录音报 `StateError: bad state: Stream has already been listened to`，启动失败。再次点击报"流式录音已在进行中"
- **根因**: `recording_screen.dart` 的 `_startRecording` 中，`_micRecorder.startStream()` 返回 single-subscription stream（`async*` 生成器默认）。`_asrEngine.start(stream)` 内部 `audioStream.listen()` 订阅一次后，界面 `_streamSub = stream.listen()` 再次订阅 → Dart single-subscription stream 不允许重复订阅。且 catch 块仅显示 SnackBar 未清理状态，`_micRecorder._isStreaming=true` 残留导致再次点击报"流式录音已在进行中"
- **解决**:
  - `final stream = _micRecorder.startStream().asBroadcastStream();` 转广播流，允许多订阅者
  - 调整订阅顺序：界面先 `stream.listen()`（累积 PCM），再 `_asrEngine.start(stream)`，确保不丢首包
  - catch 块增加清理：`_asrEngine?.stop()` + `_micRecorder.stopStream()` + `_streamSub?.cancel()`，失败后可重试
  - 规律：Dart `async*` 生成器返回 single-subscription stream，多个消费者必须 `.asBroadcastStream()` 或用 `StreamController.broadcast()` 转发；启动失败时必须清理已申请的资源（引擎、流、订阅），否则状态残留阻断重试

---

## #37 GGUF ASR (llama.cpp) 同步 FFI 阻塞主线程导致闪退
- **现象**: 下载 Qwen3-ASR 0.6B 后录音，说话即闪退（无 Dart 异常，原生 crash）
- **根因**: `LlamaCppEngine.transcribeAudio` 是纯同步 FFI 调用（`mtmd_tokenize` → `mtmd_helper_eval_chunks` → 逐 token `llama_decode`），在主 isolate 执行，每段 1-3 秒。VAD 检测到语音段 → `_processQueue` 调用 `transcribeAudio` → 阻塞主线程 → Android ANR/crash。且过短的音频段（< 0.1s）传入 `mtmd_bitmap_init_from_audio` 可能触发原生 crash
- **解决**:
  - 调整引擎优先级：sherpa-onnx ASR（ONNX 运行时移动端成熟）优先于 GGUF ASR（llama.cpp 同步阻塞风险）。用户已下载 Paraformer 时优先使用，GGUF ASR 降为回退方案
  - 两个 `_processQueue` 增加 `if (seg.samples.length < 1600) continue;`（0.1s @ 16kHz），跳过过短音频段
  - 规律：移动端 FFI 同步调用 > 1s 有 ANR 风险，应放入 Isolate（但 llama.cpp 原生指针不跨 Isolate，需 per-isolate 加载模型，内存开销大）；务实方案是优先用更轻量的原生库（sherpa-onnx ONNX）替代重量级 FFI（llama.cpp GGUF），质量与稳定性权衡

---

## #38 AI Router 获取的模型列表需持久化供 LLM 按功能配置页选择
- **现象**: AI Router 页面测试连接成功后能获取到 LM Studio/自定义接口的模型列表（显示为 Chip），但 LLM 按功能配置页选了这两个提供商后没有模型可选（下拉框为空），体验割裂。且 AI Router 的"模型名"输入框多余（测试连接已能自动获取模型）
- **根因**: `AiConfigSelector` 的模型下拉只读 `provider.availableModels`（预设列表），LM Studio/自定义的 `availableModels` 为空 `[]`。AI Router 页面获取的 `fetchedModels` 仅存在内存 state（`_AiRouterState`），未持久化，LLM 配置页无法读取
- **解决**:
  - `AiRouterService` 新增 `saveFetchedModels`/`getFetchedModels`（SharedPreferences key: `ai_router_models_<provider>`），测试连接成功后持久化模型列表
  - `AiConfigSelector` 改为 ConsumerStatefulWidget，模型数据源 = 预设 `availableModels` + `getFetchedModels`（去重合并）。合并后仍为空时显示文本输入框
  - 删除 AI Router 页面的"模型名"输入框（`_modelController`/`_buildModelField`/`_saveModel`）
  - `testConnection` 回退探活去掉 model 字段（LM Studio 用默认加载的模型）
  - LM Studio `needsApiKey` 改 `false`（默认无鉴权）
  - 规律：跨页面共享的动态数据（如 API 获取的模型列表）必须持久化，不能仅存于页面 state；UI 选择器应同时支持预设列表 + 动态获取 + 手动输入三种数据源

---

## #39 LlmTaskRouter.getEngine() 每次新建引擎不释放 — 内存泄漏 + 性能灾难
- **现象**: 代码审查 C1 指出：`getEngine()` 每次调用都 `new CloudLlmEngine()` / `new LocalLlmEngine()` 并 `init()`，返回的引擎从不 dispose。本地引擎每次加载 GB 级 GGUF 模型，内存泄漏严重
- **根因**: `llm_task_router.dart:68-79` 无缓存机制，每次 getEngine 都新建实例。调用方（如 `recording_screen._translateSegment`）用完不 dispose（也不应该 dispose，因为不知道是否还有其他调用方在用）
- **解决**: 引擎实例按 taskType 缓存到 `_engineCache` Map。`getEngine` 先查缓存（`isReady` 时直接返回），未命中才新建。`setConfig` 时 dispose 旧引擎清除缓存。新增 `disposeAll()` 供 app 退出时调用。规律：重量级资源（模型加载、网络连接池）应按 key 缓存复用，配置变更时才重建

---

## #40 validateGgufFile 缺 await — 所有 GGUF 文件静默通过校验
- **现象**: 代码审查 C3 指出：`isModelDownloaded` 中 `return validateGgufFile(path)` 缺 await，返回的是 Future 对象（truthy），导致所有存在的文件都通过校验，损坏或非 GGUF 文件被静默接受
- **根因**: `llm_model_manager.dart:83` — `validateGgufFile` 返回 `Future<bool>`，但 `return validateGgufFile(path)` 没有 await，返回 Future 对象本身（永远是 truthy）而非 bool 结果
- **解决**: 改为 `return await validateGgufFile(path);`。规律：async 函数中调用返回 Future 的方法必须 await 才能拿到实际返回值，否则返回的是 Future 对象本身

---

## #41 ornith/Qwen3 等模型默认 thinking 模式 — 简单任务（翻译）浪费大量 token
- **现象**: 用户选 LM Studio 的 ornith-1.0-9b 做翻译，后台一直吐 token 但很慢。翻译这种简单任务不需要思考过程
- **根因**: ornith-1.0-9b / Qwen3 等模型支持思考模式，默认生成 `<think>...</think>` 内容。LocalLlmEngine `_buildPrompt` 没有抑制 thinking，模型在翻译前先输出大段思考内容，浪费 token 和时间
- **解决**: LlmEngine.generate 接口新增 `enableThinking` 参数（默认 false）。LocalLlmEngine `_buildPrompt` 在 `enableThinking=false` 时于 user 内容末尾追加 `/no_think`（Qwen3 系列约定的开关），抑制 `<think>` 输出。规律：支持思考模式的模型在简单任务（翻译/纠错/提取）中应显式关闭 thinking，仅复杂任务（纪要/整理）才开启

---

## #42 LlmTaskRouter.getEngine 并发竞态 — 重复加载 GB 级模型 OOM
- **现象**: 代码审查 H1 指出，多个调用方并发调用 `getEngine(LlmTaskType.translation)` 时（如实时录音翻译 + UI 后台补译），会触发多次本地引擎 `new LocalLlmEngine() + init()`，重复加载 GGUF 模型（GB 级）导致内存爆炸 OOM
- **根因**: `llm_task_router.dart` 的 `getEngine()` 仅缓存 `LlmEngine` 实例（`_engineCache[taskType]`），但未缓存创建中的 Future。当多个调用方在同一 taskType 的引擎尚未 init 完成时并发调用，缓存未命中（`cached == null || !cached.isReady`），每个调用方都启动一个新的 init 流程，最终多个引擎实例并存
- **解决**: 引入 `Map<LlmTaskType, Future<LlmEngine?>> _pendingFutures` 缓存创建中的 Future。`getEngine` 流程改为：①查 `_engineCache` 命中且 `isReady` 直接返回；②缓存失效则 dispose+remove；③查 `_pendingFutures` 命中则复用同一 Future（await 同一 Future 自然去重）；④未命中才新建 Future（`_createAndCacheEngine`），存入 `_pendingFutures`，try 块 await 后 finally 移除。`disposeAll` 先 await 所有 pending Future 完成再 dispose 引擎。规律：重量级资源（模型加载、网络连接池）的异步初始化不仅要缓存实例，还要缓存"创建中的 Future"防止并发竞态重复加载

---

## #43 llamaBackendFree 全局影响 — 多实例 dispose 破坏其他实例
- **现象**: 代码审查 M5 指出，多 LocalLlmEngine 实例并存时（如 translation + summary 两个 taskType 各持一个 LocalLlmEngine），其一 dispose 调用 `llamaBackendFree()` 会释放全局 backend，另一实例的后续推理崩溃（段错误/无效句柄）
- **根因**: `llama_cpp_engine.dart` 的 `_backendInitialized` 是实例字段，但 llama.cpp 的 backend 是进程级单例（`llamaBackendInit` / `llamaBackendFree` 操作全局状态）。每个 LocalLlmEngine 实例独立追踪 `_backendInitialized`，A 实例 dispose 时调 `llamaBackendFree()` 释放全局 backend，B 实例仍持有指向已释放 backend 的 model/context 指针
- **解决**: `_backendInitialized` 改为 `static` 字段（进程级追踪），新增 `static LlamaCppFfi? _staticFfi` 持有 FFI 引用。`_ensureBackend()` 检查静态字段，仅首次调用时 init。实例 `dispose()` 不再调 `llamaBackendFree()`（仅释放 model/context）。新增 `static void disposeBackend()` 供 app 退出时统一释放（`LlmTaskRouter.disposeAll` 末尾调 `LlamaCppEngine.disposeBackend()`）。规律：FFI 绑定的原生库若使用进程级全局状态（如 backend/scheduler），Dart 侧必须用 static 字段追踪，单实例 dispose 不能释放全局资源，应由 app 生命周期统一管理

---

## #44 云端模型 enableThinking=true 输出 `<think>` 标签污染纪要/笔记
- **现象**: 代码审查 H2 指出，纪要/笔记任务开启 enableThinking=true 后，Qwen3/DeepSeek R1 等云端模型在 Markdown 正文前输出 `<think>思考过程...</think>` 内容，被 SummaryService/NoteService 当作纪要正文存入数据库，用户看到带思考标签的污染笔记
- **根因**: v0.9.5 区分任务 thinking 策略（纪要/笔记整理=true，翻译/纠错=false），但 SummaryService/NoteService 的 `onComplete` 回调直接存储 LLM 完整输出，未过滤 `<think>` 标签。云端 OpenAI 兼容 API 的 `enable_thinking` 字段仅控制是否生成思考内容，无法消除已生成的标签
- **解决**: SummaryService 和 NoteService 各新增 `_stripThinkTags(String) → String` 方法，过滤两种情况：①完整 `<think>...</think>` 标签（`RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false)`）；②未闭合的 `<think>...` 尾部标签（`RegExp(r'<think>[\s\S]*$', caseSensitive: false)`，防止 LLM 中断时残留）。`onComplete(fullText)` 回调中 `markdown = _stripThinkTags(fullText)` 后再存库。NoteService 的两处 `_parseNoteOutput(output)` 调用也包一层 `_stripThinkTags`。规律：开启 thinking 模式的 LLM 任务，下游解析必须过滤 `<think>` 标签（完整 + 未闭合两种情况），不能假设 LLM 总是输出格式良好的闭合标签
