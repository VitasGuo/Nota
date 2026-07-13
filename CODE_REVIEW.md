# NOTA 代码审查报告

**项目**: NOTA - Note with ASR (v0.9.0+1)
**审查范围**: 55 Dart 文件 + Android 原生代码 + 配置文件
**审查方式**: 只读静态审查，未修改任何代码
**审查日期**: 2026-07-13

---

## 严重 (Critical) — 需优先修复

### C1. LLM 引擎每次调用都新建且不释放 (内存泄漏 + 性能灾难)

**文件**: `lib/services/llm/llm_task_router.dart:68-79`

`getEngine()` 每次调用都创建并初始化一个全新的 `LlmEngine`。对本地引擎意味着每次加载数 GB 的 GGUF 模型，且返回的引擎从不 dispose。这是严重的内存泄漏和性能问题。

### C2. RealtimeAsrEngine 无 VAD 模式内存无限增长

**文件**: `lib/services/asr/realtime_asr_engine.dart:361-374`

无 VAD 模式下 PCM 数据通过 `buf.addAll(bytes)` 无限累积，无上限。1 小时录音约 115MB，会耗尽内存。

### C3. GGUF 验证函数缺少 `await` (静默通过)

**文件**: `lib/services/llm/llm_model_manager.dart:83`

`validateGgufFile(path)` 返回 `Future<bool>` 但调用处未 `await`，返回的是 Future 对象（truthy），导致**所有存在的文件都通过校验**，损坏或非 GGUF 文件被静默接受。

### C4. Theme 全局可变状态 + getter 副作用

**文件**: `lib/core/theme.dart:7-8, :220`

`accentColor`/`accentLight` 是可变静态字段；`getTheme()` 调用 `_setBrightness` 修改全局亮度状态，仅仅是读取主题就改变了 app 全局状态。

### C5. summary_service 的回调竞态条件

**文件**: `lib/services/pipeline/summary_service.dart:116-122`

`engine.generate()` 使用回调但未用 `Completer` 桥接，`onError` 可能在 `generate()` 返回后才触发，导致结果不一致。同文件 correction_service 和 note_service 正确使用了 `Completer`。

### C6. MediaProjection Token 在 Android 14+ 会静默失败

**文件**: `android/app/src/main/kotlin/com/vitasguo/nota/MainActivity.kt:108`

Android 14 (API 34) 要求 MediaProjection token 必须立即消费，不能存储复用。代码将 `mediaProjection` 存入字段后续使用，在新设备上会静默失败。

---

## 高 (High) — 建议尽快修复

### H1. SpeakerRecorder.cancel() 永远不会删除文件

**文件**: `lib/services/audio/speaker_recorder.dart:72-80`

`stop()` 将 `_currentPath` 置 null，随后 `cancel()` 中的文件删除判断成为死代码。

### H2. DualTrackRecorder.dispose() 未释放 SpeakerRecorder

**文件**: `lib/services/audio/dual_track_recorder.dart:68-70`

只 dispose 了 mic，`_speakerRecorder` 未释放，原生资源泄漏。

### H3. 数据库 singleton 非线程安全

**文件**: `lib/services/storage/database_helper.dart:20-23`

`_db ??= await _initDb()` 存在 TOCTOU 竞态，并发调用可能打开两个数据库连接。

### H4. togglePin / incrementSessionCount 无事务保护 (读-写竞态)

**文件**: `lib/services/storage/note_storage.dart:57-63`、`lib/services/storage/recording_storage.dart:87-93`、`lib/services/storage/speaker_storage.dart:59-67`

先读后写无事务，并发调用会导致操作丢失。`incrementSessionCount` 应使用 `UPDATE speakers SET session_count = session_count + 1`。

### H5. CloudLlmEngine 重复 init 泄漏 Dio 连接

**文件**: `lib/services/llm/cloud_llm_engine.dart:17,37-54`

`init()` 每次创建新 `Dio()` 但不关闭旧实例。

### H6. LlamaCppEngine.dispose 释放全局后端影响所有引擎

**文件**: `lib/services/llm/llama_cpp_engine.dart:407-409`

`llamaBackendFree()` 是进程全局操作，dispose 一个引擎会破坏其他正在使用的引擎。

### H7. 录音停止后 `_asrEngine?.stop()` 未 await

**文件**: `lib/presentation/recording/recording_screen.dart:913`

stop 返回 Future 但未 await，引擎可能仍在写入时目录就被删除。

### H8. Release 构建使用 debug 签名

**文件**: `android/app/build.gradle.kts:37`

`signingConfig = signingConfigs.getByName("debug")`，发布 APK 可被伪造，无法上架 Play Store。

### H9. busy-wait 轮询等待转写完成

**文件**: `lib/services/asr/realtime_asr_engine.dart:223-225, :388-390, :634-636`

三个引擎实现都用 `while + 50ms delay` 轮询，浪费 CPU。应改用 `Completer`。

### H10. 数据导出将整个音频文件加载到内存

**文件**: `lib/services/storage/data_manager.dart:248,341`

`entity.readAsBytes()` 对大 WAV 文件会导致 OOM。

### H11. hotword_screen.dart 使用不存在的 initialValue 参数

**文件**: `lib/presentation/hotwords/hotword_screen.dart:737`

`DropdownButtonFormField` 没有 `initialValue` 参数，正确参数是 `value`。

---

## 中 (Medium) — 应规划修复

| 编号 | 文件:行 | 问题 |
|------|---------|------|
| M1 | `lib/models/note.dart:89` | `jsonDecode(map['tags'])` 无 null 检查，空值或空字符串会崩溃 |
| M2 | `lib/models/speaker_profile.dart:63` | 同上，`embedding` 字段 `jsonDecode` 无防御 |
| M3 | `lib/services/storage/database_helper.dart:111` | 外键声明但未启用 `PRAGMA foreign_keys = ON`，外键约束无效 |
| M4 | 多个 model `fromMap` | 无 try-catch 的 `as String`/`as int` 强制类型转换，脏数据会崩溃 |
| M5 | `lib/services/asr/realtime_asr_engine.dart:444-445` | 临时目录未清理，`nota_cloud_asr_*` 会累积 |
| M6 | `lib/services/asr/asr_model_manager.dart` 多处 | `if (!dir.existsSync()) dir.createSync()` TOCTOU 竞态 |
| M7 | `lib/services/audio/mic_recorder.dart:50-53` | `existsSync()`/`createSync()` 同步调用阻塞事件循环 |
| M8 | `lib/services/pipeline/note_service.dart:107` | `insertNote` 返回的 id 被丢弃，返回的 Note 无有效 id |
| M9 | `lib/services/pipeline/pipeline_orchestrator.dart:206-209` | `segments.clear().addAll()` 可能丢失前序步骤添加的元数据 |
| M10 | `lib/presentation/settings/ai_router_screen.dart:390` | URL 每次按键都写 SharedPreferences，无 debounce |
| M11 | `lib/presentation/notes/note_detail_screen.dart:496-513` | 编辑器每个字符都触发 `setState` + Markdown 重解析，大文档卡顿 |
| M12 | `lib/presentation/speakers/speaker_screen.dart:49-63` | N+1 查询模式，每个 session 循环 `getSegments` |
| M13 | `lib/presentation/recording/recording_screen.dart:77` | `_pcmBuffer` 无上限增长，长时间录音 OOM |
| M14 | `lib/services/llm/local_llm_engine.dart:128-143` | 用户输入直接拼接 prompt，无 prompt injection 防护 |
| M15 | `lib/services/pipeline/correction_service.dart:24-27` | 系统 prompt 规则间缺换行，LLM 可能误解析 |
| M16 | `lib/services/storage/note_storage.dart:95` | LIKE 模式中 tag 含 `%`/`_` 会被当通配符，逻辑 bug |

---

## 低 (Low) — 改善建议

| 编号 | 文件:行 | 问题 |
|------|---------|------|
| L1 | 所有 model 类 | 缺少 `==`/`hashCode` 覆写，集合操作和 diff 依赖引用比较 |
| L2 | 所有 `copyWith` 方法 | 使用 `x ?? this.x` 模式，无法将 nullable 字段显式设为 null |
| L3 | `lib/main.dart:45-47` | onboarding 标志无条件设为 true，首次启动后永远跳过引导 |
| L4 | `lib/main.dart:24-27` | `sherpa_onnx.initBindings()` 失败被静默吞掉，后续 ASR/VAD 会莫名失败 |
| L5 | 多个文件 | `_formatDate`/`_sanitizeName` 等工具函数重复定义，应提取到共享工具类 |
| L6 | `lib/presentation/transcripts/transcript_screen.dart:143-233` | 长操作期间 widget dispose 后进度对话框泄漏 |
| L7 | `lib/services/llm/ai_router_service.dart:34,123` | 每次 RPC 创建新 Dio 实例，无法复用连接 |
| L8 | `lib/services/llm/llm_engine.dart:71` | `LlmEngineType.values.byName()` 存储值不匹配时抛 `RangeError`，应用 `tryParse` |
| L9 | `lib/presentation/notes/note_detail_screen.dart:139` | `_viewTranscript` 是未完成的死代码桩 |
| L10 | `lib/services/storage/hotword_storage.dart:105` | `importFromText` 用 `lastIndexOf(',')` 分割，含逗号的词会被截断 |
| L11 | `android/app/src/main/AndroidManifest.xml` | 声明了 `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` 但未见用途，增加攻击面 |
| L12 | `android/app/src/main/kotlin/.../MainActivity.kt:91` | `startActivityForResult` 已废弃，应迁移到 Activity Result API |

---

## 统计总览

| 级别 | 数量 | 说明 |
|------|------|------|
| **Critical** | 6 | 内存泄漏、数据验证缺失、全局状态竞态、Android 兼容性 |
| **High** | 11 | 资源释放、线程安全、签名配置、UI 逻辑错误 |
| **Medium** | 16 | 防御性编码、性能、数据一致性 |
| **Low** | 12 | 代码质量、重复代码、废弃 API |
| **合计** | **45** | |

---

## 最需优先处理的 3 个问题

1. **C1** — `LlmTaskRouter.getEngine()` 每次新建引擎不释放（内存爆炸）
2. **C3** — `validateGgufFile` 缺 `await`（所有模型文件都跳过校验）
3. **H7** — `_asrEngine?.stop()` 未 await（录音停止后删文件崩溃）
