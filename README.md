# NOTA - Note with ASR

基于 Flutter 的私人 AI 笔记软件，集成 ai_router_module 统一管理多 AI 平台。派生自 xiaop v1.4.1（AI 情感陪伴助手），继承其多 AI 提供商、主题等基础设施，聚焦"录音 → 转写 → 笔记"场景。

> 当前为 v0.9.7：新增 Qwen3-0.6B 作为本地文本 LLM 模型，翻译可走本地 llama.cpp 离线推理；修复 whisper.cpp ggml magic header 字节序校验失败（小端序 `[0x6c,0x6d,0x67,0x67]`）；所有模型下载源尽可能迁移到魔搭社区（ModelScope），国内网络最友好。继承 v0.9.6 whisper.cpp 作为默认本地 ASR 引擎（替代 llama.cpp mtmd 接口闪退问题），whisper.cpp 专门做 ASR，llama.cpp（GGUF）专门做文本 LLM（翻译/纠错/纪要），sherpa-onnx 保留作为稳定备选 ASR。引擎优先级：whisper > sherpa > gguf > cloud（默认 whisper）。翻译走本地 llama.cpp 架构已打通（v0.6.0 LocalLlmEngine + LlmTaskRouter local 分支），v0.9.7 补齐设置页 UI——用户可在"LLM 按功能配置"→翻译→本地→选 Qwen3-0.6B（639MB，魔搭下载），LocalLlmEngine 对 ChatML 模板自动追加 /no_think（翻译低温度 0.1 + thinking off）。继承 v0.9.5 工具型应用按 LLM 任务差异化配置——翻译/纠错（低温度 0.1 + 短输出 + 关闭 thinking）求稳不发散，纪要/笔记整理（中温度 0.4 + 开启 thinking）允许归纳推理。Prompt 加严格格式约束。LlmTaskRouter 引擎缓存 + 并发去重防止 OOM；`<think>` 标签过滤防污染纪要/笔记；llama.cpp backend 静态化管理。录音时麦克风 PCM16 流 → VAD 分段 → 本地 ASR 实时转写（用户可选 whisper.cpp/sherpa-onnx/GGUF Qwen3-ASR）→ 文字逐句显示，可选实时翻译（本地 llama.cpp 或云端 LLM 流式）。含 ASR 引擎、LLM 引擎（云端 SSE + 本地 llama.cpp FFI）、声纹识别、热词词库、数据管理、完整界面 7 分区。继承自 xiaop v1.4.1。

## 功能范围

### 已实现（继承自 ai_router_module）
- 多 AI 提供商统一管理（ai_router_module v2.0.0：13 个内置提供商，含文本/图像/视频/语音/本地/自定义）
  - AI Router 管理页：API Key 集中存储、连接测试、模型获取
  - AiConfig 状态管理：按 provider 独立持久化 model/url，切换互不覆盖
  - 模型选择器组件：可嵌入任意页面
- 深色/浅色主题 + 5 种主题色
- 设置页（AI 提供商配置、连通测试、上下文长度、主题、关于）

### 已实现（NOTA 业务 - Task 18/18b 数据存储层 v0.3.0）
- SQLite 持久化（sqflite，`nota.db` v1，6 张表：sessions/transcripts/notes/speakers/hotword_groups/hotwords）
- 数据模型（`lib/models/`）：RecordingSession / TranscriptSegment + Transcript / Note / SpeakerProfile / HotwordGroup + HotwordEntry
- 存储类（`lib/services/storage/`，均单例）：
  - RecordingStorage：会话 CRUD + 会话目录管理（`recordings/{YYYYMMDD_HHmmss}_{title}/`）
  - TranscriptStorage：转写段落 CRUD + 批量插入 + 单字段更新（纠错/译文/说话人）
  - NoteStorage：笔记 CRUD + 搜索（title/content/tags）+ 按分类/标签查询
  - SpeakerStorage：声纹 CRUD + 跨会话余弦相似度匹配（findBestMatch）
  - HotwordStorage：热词分组/词条 CRUD + 级联删除 + 文本导入导出
  - DataManager：统一数据管理器，覆盖导入（音频/MD/热词/说话人）/ 导出（会话zip/笔记MD/热词txt/全量备份）/ 级联删除 / 孤立文件清理 / 模型缓存清理 / 存储用量统计

### 已实现（NOTA 业务 - Task 7/10/9b/12b 引擎抽象接口 v0.3.0）
- ASR 引擎抽象接口（`lib/services/asr/`）：
  - AsrEngine 抽象类（init/transcribe/dispose，支持 onProgress + onSegment 流式回调）
  - AsrEngineType 枚举（local/cloud）+ AsrConfig 配置类
  - AsrModelInfo + 预置模型清单（SenseVoice 多语言 / Whisper Medium/Large v3 Turbo / Paraformer 中文，v0.8.0 新增 ModelScope 下载源）
  - HotwordDictionary 热词中介（getAllWords / getWeightedWords / getHotwordTextForPrompt）
- LLM 引擎抽象接口（`lib/services/llm/`）：
  - LlmEngine 抽象类（init/generate/dispose，支持 onToken 流式 + onComplete/onError 回调）
  - LlmEngineType 枚举（local/cloud）+ LlmTaskType 枚举（translation/summary/noteOrganize/correction）+ LlmConfig 配置类
  - LlmTaskRouter 按功能路由器（SharedPreferences 持久化，每个 LlmTaskType 独立配置引擎+模型）

### 已实现（NOTA 业务 - Task 8/9 ASR 引擎实现 v0.4.0 + Task 6/7 实时 ASR v0.6.0）
- LocalAsrEngine（`lib/services/asr/local_asr_engine.dart`）：基于 sherpa-onnx OfflineRecognizer，支持 SenseVoice（多语言，v0.8.0 新增）/ Whisper（中英文）/ Paraformer（中文，支持热词 boosting）模型；流式 onSegment 回调逐段输出；AsrModelManager 管理模型下载/激活/删除（Dio 流式下载 + 目录管理，v0.8.0 新增 ModelScope 下载源）；含 Android arm64 原生库
- CloudAsrEngine（`lib/services/asr/cloud_asr_engine.dart`）：OpenAI Whisper API 兼容格式（multipart/form-data 上传音频文件），云端转写
- RealtimeAsrEngine（`lib/services/asr/realtime_asr_engine.dart`，v0.6.0，v0.8.0 新增 SherpaRealtimeAsrEngine，v0.9.6 新增 WhisperRealtimeAsrEngine）：实时 ASR 引擎抽象 + 四个实现
  - WhisperRealtimeAsrEngine（v0.9.6，默认推荐）：VAD 分段 → 串行队列 → WhisperIsolateWorker.transcribe（whisper.cpp ggml 模型，持久化 worker Isolate 避免同步 FFI 阻塞主线程）→ onFinal 回调 TranscriptSegment
  - LocalRealtimeAsrEngine：VadDetector 分段 → 串行队列 → LlamaCppEngine.transcribeAudio（Qwen3-ASR via llama.cpp mtmd）→ onFinal 回调 TranscriptSegment
  - SherpaRealtimeAsrEngine（v0.8.0）：VAD 分段 → sherpa-onnx OfflineRecognizer 逐段转写，支持三类模型（SenseVoice 首选 / Paraformer 回退 / Whisper）
  - CloudRealtimeAsrEngine：VAD 分段 → 写临时 WAV → CloudAsrEngine.transcribe → onFinal；支持无 VAD 整段上传模式
  - 架构：转写异步串行队列，VAD 同步喂入快速不阻塞音频流；onPartial 未实现（整段推理无 token 级流式），UI 用 onSpeechStart 显示"正在转写..."占位
  - 引擎优先级（v0.9.6）：whisper.cpp > sherpa-onnx ASR（SenseVoice > Paraformer）> GGUF ASR > 云端 ASR（默认 whisper，用户可在设置页切换）
- Qwen3-ASR GGUF 模型管理（v0.6.0）：AsrModelManager 新增 GGUF 双文件（主模型 + mmproj）下载/导入/校验。预置 Qwen3-ASR-1.7B（~2.4GB）+ 0.6B（~1.0GB）Q8_0，下载源 ggml-org 官方仓库经 hf-mirror.com 镜像。关键：handy-computer Q6_K 用 `qwen3_asr` 架构不兼容 llama.cpp mtmd，必须用 ggml-org 的 `qwen3vl` 架构版本（traps.md #33）
- whisper.cpp ASR 引擎（v0.9.6，默认推荐）：引入 whisper.cpp 作为专用 ASR 引擎替代 llama.cpp mtmd 接口。`libwhisper_android.so`（2.09MB，arm64-v8a）静态链接 ggml + version script 隐藏 ggml 符号避免与 llama.cpp 的 libggml.so 冲突；C wrapper（`whisper_simple_init/transcribe/free`）简化复杂 `whisper_full_params` 结构体供 Dart FFI 绑定。WhisperIsolateWorker 持久化 worker Isolate 封装，`whisper_full` 阻塞调用移到 worker 避免主线程 ANR。预置 3 个 ggml .bin 模型（tiny 39MB 英文测试 / small 466MB 多语言中文首选 / large-v3-turbo 547MB 质量最优），下载源 hf-mirror.com。AsrModelManager 新增 whisper 模型管理（下载/导入/校验/删除），ggml magic header `[0x67,0x67,0x6d,0x6c]` 校验文件有效性

### 已实现（NOTA 业务 - Task 12 LLM 引擎实现 v0.4.0 + Task 10 LocalLlmEngine v0.6.0）
- CloudLlmEngine（`lib/services/llm/cloud_llm_engine.dart`）：基于 ai_router_module，调用 OpenAI 兼容 /chat/completions，SSE 流式解析（onToken 逐 token 回调 + onComplete/onError），复用 ApiKeyService 三级 Key 解析链
- LlmTaskRouter 按功能独立路由（translation/summary/noteOrganize/correction 各自配引擎+模型，SharedPreferences 持久化）；本地分支已打通（v0.6.0）
- LocalLlmEngine（`lib/services/llm/local_llm_engine.dart`，v0.6.0）：基于 LlamaCppEngine（llama.cpp FFI），implements LlmEngine。init 按 config.modelName 经 LlmModelManager 定位 GGUF → load；generate 按 ChatTemplateType（ChatML/Llama-3/Generic）构建 chat prompt → 同步流式生成 → 映射 onToken/onComplete/onError
- LlmModelManager（`lib/services/llm/llm_model_manager.dart`，v0.6.0）：GGUF 文本 LLM 模型管理（Dio 下载 + file_picker 导入 + magic 校验 + 自定义模型扫描），模型根目录 `{docsDir}/llm_models/`
- 预置模型：Qwen2.5-1.5B/3B-Instruct Q5_K_M（中文友好）+ Llama-3.2-3B-Instruct Q4_K_M（英文友好），下载源 hf-mirror.com

### 已实现（NOTA 业务 - Task 13-17 笔记流水线 v0.4.0）
- TranscriptionService（`lib/services/pipeline/transcription_service.dart`）：音频 → 文本，调用 AsrEngine，注入热词，长音频分段处理
- SpeakerDiarizationService（`lib/services/pipeline/speaker_diarization_service.dart`）：sherpa-onnx SpeakerEmbeddingExtractor 提取声纹 + 层次聚类区分说话人 + 跨会话匹配（SpeakerStorage.findBestMatch 余弦相似度）
- CorrectionService（`lib/services/pipeline/correction_service.dart`）：LLM + 热词词表对 ASR 结果做专有名词/术语纠错
- TranslationService（`lib/services/pipeline/translation_service.dart`）：LLM 翻译（可选，默认关闭）
- SummaryService（`lib/services/pipeline/summary_service.dart`）：LLM 生成结构化纪要 Markdown（议题/决议/待办/关键信息）
- NoteService（`lib/services/pipeline/note_service.dart`）：LLM 整理结构化笔记（标题/标签/分类/正文 Markdown）
- PipelineOrchestrator（`lib/services/pipeline/pipeline_orchestrator.dart`）：单例编排器，串联 6 步端到端流程，支持 runFullPipeline 一键执行 / runStep 分步执行，onStepProgress + onLog 回调

### 已实现（NOTA 业务 - Task 19-20 声纹识别 v0.4.0）
- sherpa-onnx SpeakerEmbeddingExtractor 提取每段音频声纹向量
- 层次聚类区分不同说话人（speaker_0 / speaker_1 ...）
- 跨会话匹配：新录音自动匹配已入库说话人（SpeakerStorage.findBestMatch 余弦相似度，超阈值返回最佳匹配）
- 声纹库持久化（speakers 表，embedding 存 JSON TEXT）

### 已实现（NOTA 业务 - Task 21-22 完整界面 v0.4.0 + Task 8 录音界面重构 v0.6.0）
- 实时转写录音界面（`presentation/recording/`，v0.6.0 重构）：主体为实时转写文本展示区（ListView 段落卡片含时间戳+原文+流式译文），底部紧凑控制栏（计时器+录音按钮+翻译开关）。录音时麦克风 PCM16 流 → VAD 分段 → Qwen3-ASR 本地转写 → 文字逐句实时显示，可选实时翻译。每段转写完成即时写入 TranscriptStorage（崩溃不丢失已转写段落）。停止后弹窗：查看转写/一键整理笔记
- 转写界面（`presentation/transcripts/`）：带时间戳、说话人标签、原文/纠错/译文对照
- 笔记列表 + 详情（`presentation/notes/`）：搜索、分类筛选、置顶、卡片式布局；Markdown 渲染（标题/列表/表格/引用块/代码块）、可交互 checklist、编辑/预览分屏、导出 .md
- 热词管理（`presentation/hotwords/`）：分组卡片 + 词条 CRUD + 批量导入导出 + 权重编辑
- 说话人管理（`presentation/speakers/`）：声纹库列表、标签编辑、关联会话查看、删除
- 数据管理（`presentation/data/`）：存储用量统计、导入（音频/MD/热词/说话人）、导出（会话zip/笔记MD/热词txt/全量备份）、清理缓存
- 设置（`presentation/settings/`）：6 分区——ASR 入口（跳转 `AsrSettingsScreen` 子页面，含引擎配置/模型下载/whisper/GGUF 管理）/ LLM 按功能配置 / API Key 管理 / 录音配置 / 管理入口（热词/说话人/数据）/ 外观 / 关于

### 已实现（NOTA 业务 - Task 4-6 音频采集 v0.3.0）
- 双轨同步录音（`lib/services/audio/`）：mic 麦克风 + speaker 扬声器内录，各自输出 16kHz 单声道 WAV（ASR 标准输入）
  - MicRecorder：基于 `record` 6.2.1（AudioRecorder + RecordConfig），permission_handler 请求 RECORD_AUDIO，输出 mic.wav
  - SpeakerRecorder：Android 10+ AudioPlaybackCaptureConfiguration 扬声器内录（MediaProjection 授权 + 原生 MethodChannel `nota/audio_capture`），低于 Android 10 不可用；Android 14+ 需前台服务（待补齐）
  - DualTrackRecorder：Future.wait 并行启动 mic + speaker，任一成功即进入录音态，互不阻塞

### 已实现（NOTA 业务 - Task 5.2-5.4 VAD 语音活动检测 + 流式采集 v0.5.0）
- MicRecorder 流式模式（`lib/services/audio/mic_recorder.dart`）：新增 `startStream()` 返回 `Stream<Uint8List>` PCM16 裸流（16kHz 单声道 `AudioEncoder.pcm16bits`，无 WAV 头），保留原文件模式 [start]/[stop] 不变；流式与文件模式互斥，供实时 VAD/ASR 消费
- VadDetector 封装（`lib/services/asr/vad_detector.dart`）：基于 sherpa-onnx Silero VAD 的队列式检测器。`feedPcm16(Uint8List)` 喂入 PCM16 字节流（自动转 Float32 → acceptWaveform），`_poll()` 边沿检测触发 `onSpeechStart` + 循环 front/pop 取出 SpeechSegment 触发 `onSpeechEnd(startSample, samples, startSec, endSec)`；`flush()` 刷出尾部语音段，`dispose()` 释放原生资源。含 `convertPcm16ToFloat32` 工具函数
- VAD 模型管理（`lib/services/asr/asr_model_manager.dart` + `asr_model_info.dart`）：silero_vad.onnx（~2MB，单文件非归档）独立管理——`getVadModelPath()` 返回 `{docsDir}/asr_models/vad/silero_vad.onnx`，`isVadModelDownloaded()` 直接探测 .onnx 存在（无 tokens.txt），`downloadModel`/`deleteModel` 对 VAD id 走单文件 Dio 直下/删 `vad/` 目录分支
- main.dart 启动初始化（`lib/main.dart`）：`WidgetsFlutterBinding.ensureInitialized()` 后调用 `sherpa_onnx.initBindings()` 加载原生 libsherpa-onnx-c-api（VAD + ASR 共用，失败不阻塞启动）

### 已实现（NOTA 业务 - Task 23 主框架与导航 v0.3.0）
- 三 tab 底部导航（`lib/routes/app_router.dart`）：StatefulShellRoute.indexedStack 3 branch——录音（`/` → RecordingScreen）/ 笔记（`/notes` → NoteListScreen）/ 设置（`/settings` → SettingsScreen），BottomNavigationBar 等宽 + selectedItemColor 用 AppTheme.accentColor；保留 `/about` 顶层路由
- 启动初始化（`lib/main.dart`）：runApp 前触发 `DatabaseHelper().database` 预建 schema（try/catch 失败不阻塞启动）；保留 ProviderScope + NotaApp + themeModeProvider/ThemeService 结构
- HomeScreen 不再作为 tab（文件保留但路由不再引用）

### 规划中（NOTA 业务方向）
- LocalLlmEngine 异步流式优化：当前 generate 为同步 FFI 调用（token 在 generate 返回前全部经 onToken 发出，UI 在完成后渲染），真正逐 token 异步流式需后续在 FFI 层用 Isolate 或暴露单步生成 API
- 设置页 LLM 模型管理 UI：LlmModelManager 已实现下载/导入/删除，设置页对应 UI（模型列表/下载进度/导入入口）待补充
- Android 14+ 前台服务（SpeakerRecorder）：MediaProjection 在 Android 14+ 需 mediaProjection 类型前台服务才能获取，当前未实现

## 目标用户

需要私人 AI 笔记、语音记录、知识管理的用户。

## 技术栈

- **框架**: Flutter 3.41.x（Dart SDK ^3.11.0）
- **状态管理**: Riverpod
- **路由**: GoRouter
- **网络**: Dio
- **持久化**: SharedPreferences + SQLite（sqflite）
- **AI**: OpenAI 兼容 API（ai_router_module 统一管理）

## 目录结构

```
lib/
├── main.dart
├── core/               # 主题（theme.dart）
├── models/             # ★ 数据模型（Task 18 v0.3.0）
│   ├── recording_session.dart    # 录音会话 + RecordingSource 枚举
│   ├── transcript.dart           # TranscriptSegment（统一模型）+ Transcript 聚合
│   ├── note.dart                 # 笔记 + NoteType 枚举
│   ├── speaker_profile.dart      # 说话人声纹档案
│   └── hotword.dart              # 热词分组 + 词条
├── services/
│   ├── llm/            # ★ ai_router_module 集成层 + LLM 引擎（抽象 + 云端 + 本地实现）
│   │   ├── ai_providers.dart      # 13 个提供商配置定义
│   │   ├── api_key_service.dart   # API Key 存储（preset→saved→default 解析链）
│   │   ├── ai_router_service.dart # 连接测试 + 模型获取
│   │   ├── llm_engine.dart        # LlmEngine 抽象 + LlmEngineType/LlmTaskType/LlmConfig
│   │   ├── cloud_llm_engine.dart  # ★ CloudLlmEngine（ai_router_module，SSE 流式）
│   │   ├── local_llm_engine.dart  # ★ LocalLlmEngine（llama.cpp FFI，ChatML/Llama-3 prompt 模板，v0.6.0）
│   │   ├── llama_cpp_engine.dart  # ★ LlamaCppEngine（通用 GGUF 推理：文本生成 + ASR 音频转写，v0.4.3）
│   │   ├── llama_cpp_ffi.dart     # ★ llama.cpp + mtmd C API 的 Dart FFI 绑定（v0.4.3）
│   │   ├── llm_model_info.dart    # ★ GGUF 文本 LLM 预置模型清单 + ChatTemplateType 枚举（v0.6.0）
│   │   ├── llm_model_manager.dart # ★ GGUF 文本 LLM 模型管理（下载/导入/校验/删除，v0.6.0）
│   │   └── llm_task_router.dart   # 按功能路由（translation/summary/noteOrganize/correction，本地+云端）
│   ├── audio/          # ★ 音频采集模块（mic_recorder / speaker_recorder / dual_track_recorder）
│   ├── asr/            # ★ ASR 引擎（抽象接口 + 本地/云端实现 + 实时 ASR + VAD + 热词管理）
│   │   ├── asr_engine.dart         # AsrEngine 抽象 + AsrEngineType/AsrConfig
│   │   ├── asr_model_info.dart     # AsrModelInfo + 预置模型清单 + GgufAsrModels（Qwen3-ASR GGUF，v0.6.0）+ WhisperModels（whisper.cpp ggml，v0.9.6）
│   │   ├── asr_model_manager.dart  # ★ 模型下载/激活/删除 + GGUF 双文件管理（v0.6.0）+ whisper ggml 模型管理（v0.9.6）
│   │   ├── local_asr_engine.dart   # ★ LocalAsrEngine（sherpa-onnx OfflineRecognizer）
│   │   ├── cloud_asr_engine.dart   # ★ CloudAsrEngine（OpenAI Whisper API）
│   │   ├── realtime_asr_engine.dart# ★ RealtimeAsrEngine 抽象 + Local/Sherpa/Whisper/Cloud 四实现（v0.6.0+，v0.9.6 新增 Whisper）
│   │   ├── whisper_ffi.dart        # ★ whisper.cpp C wrapper 的 Dart FFI 绑定（whisper_simple_*，v0.9.6）
│   │   ├── whisper_engine.dart     # ★ WhisperEngine 高层封装（load/transcribe/dispose，v0.9.6）
│   │   ├── whisper_isolate_worker.dart # ★ WhisperIsolateWorker 持久化 worker Isolate（v0.9.6）
│   │   ├── isolate_asr_worker.dart # ★ IsolateAsrWorker 持久化 worker Isolate（llama.cpp GGUF ASR，v0.9.6）
│   │   ├── vad_detector.dart       # ★ VadDetector（sherpa-onnx Silero VAD 队列式封装 + PCM16→Float32）
│   │   └── hotword_dictionary.dart # 外挂热词词库中介（ASR 注入 / LLM 纠错参考）
│   ├── pipeline/       # ★ 笔记流水线（转写→声纹→纠错→翻译→纪要→笔记，v0.4.0）
│   │   ├── transcription_service.dart       # 音频→文本（调 AsrEngine，注入热词）
│   │   ├── speaker_diarization_service.dart # 声纹提取+层次聚类+跨会话匹配
│   │   ├── correction_service.dart          # LLM + 热词词表纠错
│   │   ├── translation_service.dart         # LLM 翻译（可选）
│   │   ├── summary_service.dart             # LLM 生成结构化纪要 Markdown
│   │   ├── note_service.dart                # LLM 整理结构化笔记
│   │   └── pipeline_orchestrator.dart       # 单例编排器（一键/分步执行）
│   └── storage/        # ★ 存储模块（Task 18/18b v0.3.0）
│       ├── database_helper.dart   # SQLite 单例 + nota.db v1 + 6 表 schema
│       ├── recording_storage.dart # 会话 CRUD + 会话目录管理
│       ├── transcript_storage.dart# 转写段落 CRUD + 批量插入
│       ├── note_storage.dart      # 笔记 CRUD + 搜索 + 分类/标签查询
│       ├── speaker_storage.dart   # 声纹 CRUD + 余弦相似度匹配
│       ├── hotword_storage.dart   # 热词 CRUD + 级联删除 + 导入导出
│       └── data_manager.dart      # 统一数据管理器（导入/导出/删除/清理/统计）
├── providers/          # Riverpod 状态（ai_config_provider）
├── routes/             # GoRouter 路由（录音 + 笔记 + 设置 + 关于）
└── presentation/       # 界面
    ├── home/           # 首页（占位，已不再作为 tab，文件保留）
    ├── recording/      # ★ 录音界面（底部导航 tab 1）
    ├── transcripts/    # ★ 转写界面（时间戳/说话人/原文-纠错-译文对照）
    ├── notes/          # ★ 笔记列表 + 详情（Task 21 v0.3.0）
    ├── hotwords/       # ★ 热词词库管理（Task 21b v0.3.0）
    ├── speakers/       # ★ 说话人管理（声纹库列表/标签编辑/删除）
    ├── data/           # ★ 数据管理（Task 21d v0.3.0）
    ├── settings/       # ★ 设置（6 分区 + ASR 子页面）+ 关于 + AI Router 管理页
    └── widgets/        # 通用组件（ai_config_selector 模型选择器）
```

> 标注 ★ 的为本版本已实现；标注 ▶ 的为规划中（当前无）。

## 核心数据流（AI 配置）

```
应用 UI
  │  watch(aiConfigProvider) ──► AiConfig(provider/model/customUrl/contextLength)
  │                                   │ effectiveModel / effectiveUrl（空则回退提供商默认）
  ▼                                   ▼
ApiKeyService.getEffectiveApiKey(provider) ──► 实际 Key
  │  解析链: presetApiKey → 用户保存 → defaultApiKey
  ▼
AiRouterService.testConnection / fetchModels（customUrl 优先于 defaultBaseUrl）
  ▼
OpenAI 兼容接口 (GET /models → POST /chat/completions)
```

## 核心数据流（存储层）

```
录音会话 ──► RecordingStorage.insertSession ──► sessions 表
                │ createSessionDir → recordings/{YYYYMMDD_HHmmss}_{title}/
                ▼
ASR 转写 ──► TranscriptStorage.insertSegments ──► transcripts 表（session_id 关联）
                │ updateCorrectedText / updateTranslation / updateSpeakerId
                ▼
LLM 整理 ──► NoteStorage.insertNote ──► notes 表（session_id 关联，tags 存 JSON）
                │ searchNotes / getNotesByTag / getNotesByCategory
声纹识别 ──► SpeakerStorage.findBestMatch(余弦相似度) ──► speakers 表（embedding 存 JSON）
热词词库 ──► HotwordStorage.getAllEntries ──► hotwords 表（group_id 关联 hotword_groups）
                │ exportAsText / importFromText
```

## 核心数据流（笔记流水线，v0.4.0）

```
录音 (Mic/Speaker/DualTrack)
  → RecordingStorage (sessions 表 + recordings/ 目录)
  → TranscriptionService → AsrEngine (Local sherpa-onnx / Cloud Whisper API) → TranscriptStorage (transcripts 表)
  → SpeakerDiarizationService (声纹提取 + 层次聚类 + 跨会话匹配) → SpeakerStorage (speakers 表)
  → CorrectionService (LLM + 热词词表纠错) → correctedText
  → TranslationService (LLM 翻译，可选) → translation
  → SummaryService (LLM 生成结构化纪要 Markdown) → NoteStorage (notes 表, type=summary)
  → NoteService (LLM 整理结构化笔记) → NoteStorage (notes 表, type=note)
```

> PipelineOrchestrator 单例编排上述 6 步，支持 runFullPipeline 一键执行 / runStep 分步执行，onStepProgress + onLog 回调；错误传播策略见"关键设计决策"。

## 核心数据流（实时 ASR 转写，v0.6.0，v0.8.0 新增 SenseVoice，v0.9.6 新增 whisper.cpp）

```
麦克风 PCM16 流 (MicRecorder.startStream, 16kHz 单声道)
  → VadDetector.feedPcm16 (sherpa-onnx Silero VAD 队列式分段)
  → onSpeechEnd(samples, startSec, endSec) → 入 _pending 队列
  → 串行 _processQueue (按引擎优先级选择其一):
      ├─ WhisperRealtimeAsrEngine: WhisperIsolateWorker.transcribe (whisper.cpp ggml 模型，worker Isolate) → 文本 [v0.9.6 默认]
      ├─ SherpaRealtimeAsrEngine: sherpa-onnx OfflineRecognizer (SenseVoice 首选 / Paraformer / Whisper) → 文本
      ├─ LocalRealtimeAsrEngine: IsolateAsrWorker → LlamaCppEngine.transcribeAudio (Qwen3-ASR GGUF via mtmd，worker Isolate) → 文本
      └─ CloudRealtimeAsrEngine: 写临时 WAV → CloudAsrEngine.transcribe → 合并文本
  → onFinal(TranscriptSegment) → RecordingScreen:
      ├─ UI: 段落卡片加入列表 + 自动滚动
      ├─ 持久化: TranscriptStorage.insertSegment (即写即存，崩溃不丢失)
      └─ 可选实时翻译: LlmTaskRouter.getEngine(translation) → 流式 generate → 译文显示 + updateTranslation 持久化
  → 停止: MicRecorder.stopStream + AsrEngine.stop (等待队列清空) + 写 WAV 备份 + 更新 session.endTime
```

> 架构亮点：VAD 同步分段不阻塞音频流，转写异步串行处理；onPartial 未实现（整段推理无 token 级流式），UI 用 onSpeechStart 显示"正在转写..."占位。引擎优先级（v0.9.6）：whisper.cpp > sherpa-onnx ASR（SenseVoice > Paraformer）> GGUF ASR > 云端 ASR（默认 whisper，用户可在设置页切换）。whisper.cpp 与 llama.cpp GGUF ASR 均用持久化 worker Isolate 避免同步 FFI 阻塞主线程。

## 关键设计决策

- **ai_router_module 作为统一 LLM 层**：`lib/services/llm/` 集中管理多 AI 平台配置、Key、连接测试；AiConfig 按 provider 独立持久化 model/url，切换互不覆盖。新版 ai_providers 是 xiaop 旧版超集（新增 tongyi/jimeng + 多模态能力标志 + getByType）
- **模块瘦身**：NOTA 是录音→转写→笔记应用，不需要对话/人格/记忆/TTS/工具/搜索/STT 模块。v0.2.0 已删除 xiaop 的 chat/personality/memory/tools/stt/tts/web_search 全部业务模块及对应 models/providers/widgets，仅保留 AI 配置基础设施与设置/首页骨架
- **目录结构前瞻**：v0.2.0 即先建立 audio/asr/pipeline/storage、recording/transcripts/notes 等业务目录并写入 README 规划，为后续开发提供明确落点；v0.4.0 全部目录已填充实现
- **存储层单例 + SQLite（v0.3.0）**：DatabaseHelper 单例管理 nota.db（v1，6 表），5 个存储类均单例依赖 DatabaseHelper。时间存 ISO 8601 TEXT 或 REAL 秒，bool 存 INTEGER 0/1，List（tags/embedding）存 JSON TEXT。TranscriptSegment 为统一模型：存储字段（double 秒 / originalText / speakerId + toMap/fromMap）+ 兼容 ASR 引擎的 getter（text / speaker / startDuration），避免并行任务类型冲突（见 traps.md #16）
- **双轨录音架构（v0.3.0）**：mic（用户语音）+ speaker（系统/其他 App 播放音频）双路并行采集，各自输出 16kHz 单声道 WAV。mic 走 `record` 包（跨平台），speaker 走 Android 原生 AudioPlaybackCaptureConfiguration（需 Android 10+ + MediaProjection 用户授权，经 MethodChannel `nota/audio_capture` 调用）。DualTrackRecorder 并行启动两路、任一成功即视为录音中、互不阻塞；WAV 头先占位写入、停止后用 RandomAccessFile 回填 RIFF/data 大小
- **sherpa_onnx 作为统一 ASR + 声纹引擎（v0.4.0）**：同一原生库同时承担 OfflineRecognizer 转写（Whisper/Paraformer）+ SpeakerEmbeddingExtractor 声纹提取，减少依赖体积；含 Android arm64 原生库。LocalAsrEngine 负责转写，SpeakerDiarizationService 负责声纹，两者共享 sherpa_onnx 包但独立实例化
- **LlmTaskRouter 按功能独立路由（v0.4.0，v0.9.5 差异化默认配置 + thinking 策略）**：翻译/纪要/笔记/纠错 4 个 LlmTaskType 各自独立配置引擎类型 + 提供商 + 模型 + 高级参数（maxTokens/temperature），SharedPreferences 持久化（key `llm_task_<taskType>`）。流水线执行到某步时读取该功能的配置路由到对应引擎，避免单一模型兼顾所有任务的质量妥协。v0.9.5 按工具型应用特性细化默认配置：translation=0.1/1024（低温度短输出求稳）、correction=0.1/4096（低温度保留原文长度）、summary/noteOrganize=0.4/4096（中温度允许归纳）；thinking 策略——简单任务（翻译/纠错）传 `enableThinking: false`（LocalLlmEngine 追加 `/no_think`，CloudLlmEngine 传 `enable_thinking: false`），复杂任务（纪要/笔记整理）传 `true`。引擎实例按 taskType 缓存（`_engineCache`）+ 并发去重（`_pendingFutures` 缓存创建中 Future，防多调用方并发重复加载 GB 级模型 OOM）；`disposeAll()` 在 NotaApp.dispose + detached 生命周期双保险调用，末尾调 `LlamaCppEngine.disposeBackend()` 统一释放 llama.cpp 全局 backend（traps.md #42/#43）
- **PipelineOrchestrator 错误传播策略（v0.4.0）**：转写失败→终止流水线（基础步骤，无文本则后续无意义）；声纹失败→跳过继续纠错（非阻塞，纠错可用原文）；纠错失败→继续翻译用原文；翻译失败→继续纪要；纪要失败→继续笔记；笔记失败→记录错误。每步失败记入 PipelineResult.errors，completedSteps 仅记成功步骤，isSuccess 仅在无 errors 时为 true
- **16kHz 单声道 PCM WAV 作为 ASR 标准输入格式（v0.4.0）**：MicRecorder（record 包 AudioEncoder.wav + 16kHz + 单声道）与 SpeakerRecorder（Android 原生 AudioRecord 16kHz 单声道 PCM16）均输出该格式， sherpa-onnx OfflineRecognizer 与 OpenAI Whisper API 均直接消费；非该格式的导入音频由 DataManager.importAudioFile 统一归档到会话目录，转写时由 TranscriptionService 适配
- **热词双重用途（v0.4.0）**：同一份 HotwordStorage 词库服务两条路径——(1) Paraformer 模型原生热词 boosting（LocalAsrEngine 转写时通过 HotwordDictionary.getWeightedWords 注入，提升专有名词识别率）；(2) LLM 纠错参考词表（CorrectionService 通过 HotwordDictionary.getHotwordTextForPrompt 拼接为 prompt 注入，指示 LLM 参考词表对转写文本中专有名词/术语纠错）。Whisper 模型不支持 boosting，仅走路径 (2)
- **VAD 队列式检测 + PCM16 流式采集（v0.5.0）**：实时 ASR 前置基础设施采用「MicRecorder.startStream() PCM16 裸流 → VadDetector.feedPcm16() → sherpa-onnx VoiceActivityDetector 队列轮询 → onSpeechEnd 分段回调」架构。MicRecorder 双模式（文件 WAV / 流式 PCM16）互斥，流式模式用 record 6.2.1 `AudioEncoder.pcm16bits` 输出无头裸流（区别于文件模式 WAV）。VadDetector 封装 sherpa-onnx 队列式 VAD（非回调式）：feedPcm16 内部转 Float32 → acceptWaveform → _poll 边沿检测（isDetected false→true 触发 onSpeechStart）+ front/pop 出队触发 onSpeechEnd。VAD 模型（silero_vad.onnx，单文件 ~2MB）与 ASR 转写模型（归档 + tokens.txt）形态不同，AsrModelManager 在 isModelDownloaded/downloadModel/deleteModel 内按 modelId 分支处理，保持调用方接口统一。`sherpa_onnx.initBindings()` 在 main.dart 启动时同步调用一次（VAD + ASR 共用原生库）
- **实时 ASR 串行队列架构（v0.6.0）**：RealtimeAsrEngine 采用「VAD 同步分段（快速不阻塞音频流）→ 每段入 _pending 队列 → 串行 _processQueue 调用 transcribeAudio（1-3s/段）→ onFinal 回调」架构。LocalRealtimeAsrEngine 用 LlamaCppEngine.transcribeAudio（Qwen3-ASR via llama.cpp mtmd 接口），CloudRealtimeAsrEngine 写临时 WAV + CloudAsrEngine.transcribe。onPartial 未实现（Qwen3-ASR 整段推理无 token 级流式），UI 用 onSpeechStart 显示"正在转写..."占位。GGUF ASR 模型为双文件（主模型 + mmproj），AsrModelManager.downloadGgufModel 顺序下载 + 加权进度 + 阶段回调。关键：handy-computer Q6_K 用 `qwen3_asr` 架构不兼容 llama.cpp mtmd（仅识别 `qwen3vl`），必须用 ggml-org 官方仓库版本（traps.md #33）
- **ModelScope 下载源 + SenseVoice 多语言模型（v0.8.0）**：解决国内用户从 GitHub/HF 下载 ASR 模型超时问题。AsrModelInfo 新增 `modelscopeRepo`/`modelscopeFiles` 字段，AsrModelManager.downloadModel 优先走 ModelScope 分支（URL 格式 `https://www.modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={file}`，API 返回 302 重定向 Dio 自动跟随）。新增 SenseVoice Small 模型（id `sensevoice-zh`，~239MB，从魔搭社区 `xiaowangge/sherpa-onnx-sense-voice-small` 下载，支持中英日韩粤 5 语言，Q8 量化），作为国内用户首选——体积小（239MB vs Qwen3-ASR 2.4GB）、下载稳定（魔搭 vs hf-mirror）、多语言覆盖广。SherpaRealtimeAsrEngine._buildRecognizerConfig 新增 SenseVoice 分支用 `OfflineSenseVoiceModelConfig`（useInverseTextNormalization: true 启用逆文本归一化）。引擎优先级：GGUF ASR > sherpa-onnx ASR（SenseVoice > Paraformer）> 云端 ASR。Dio receiveTimeout 提升至 30 分钟支持大文件下载
- **LocalLlmEngine + LlamaCppEngine 双用途（v0.6.0）**：LlamaCppEngine 同时服务于文本 LLM 推理（load + generate 流式生成）与 ASR 音频转写（loadAsrModel + transcribeAudio，基于 Qwen3-ASR mtmd 接口），两种模式共享 llama.cpp backend + model + context 基础设施。LocalLlmEngine implements LlmEngine，包装 LlamaCppEngine 的文本模式：init 按 config.modelName 经 LlmModelManager 定位 GGUF → load；generate 按 ChatTemplateType（ChatML/Llama-3/Generic）构建 chat prompt → 同步流式生成。LlmModelManager 管理 GGUF 文本 LLM 模型（预置 Qwen2.5-1.5B/3B + Llama-3.2-3B，下载源 hf-mirror.com + file_picker 本地导入 + magic 校验）。性能限制：generate 为同步 FFI 调用，token 在返回前全部经 onToken 发出（UI 完成后渲染），真正异步流式需后续 Isolate 优化
- **whisper.cpp 专用 ASR 引擎（v0.9.6）**：解决 Qwen3-ASR（llama.cpp mtmd 接口）同步 FFI 闪退问题，引入 whisper.cpp 作为专用 ASR 引擎。架构分层：whisper.cpp（ggml .bin 模型）专门做 ASR，llama.cpp（GGUF）专门做文本 LLM，sherpa-onnx 保留作为稳定备选 ASR。whisper.cpp Android 交叉编译关键决策：①`-DBUILD_SHARED_LIBS=OFF` 静态链接 ggml 到 libwhisper_android.so（2.09MB），避免单独 libggml.so 与 llama.cpp 的 libggml.so 符号冲突；②version script (`whisper.exports`) 只导出 `whisper_*` + `whisper_simple_*` 符号，隐藏 ggml 内部符号；③C wrapper（`whisper_simple_init/transcribe/free`）封装复杂 `whisper_full_params` 结构体（含回调指针、嵌套结构体），Dart FFI 侧只需绑定 3 个简单签名。WhisperIsolateWorker 持久化 worker Isolate 模式：`whisper_full` 是阻塞调用，必须移到 worker Isolate 避免主线程 ANR；worker 内复用同一模型实例（load/transcribe/dispose Map 消息 + SendPort 通信，与 IsolateAsrWorker 模式一致）。whisper.cpp 采样率 `WHISPER_SAMPLE_RATE = 16000` 与 NOTA 16kHz PCM16 标准一致；时间戳 `whisper_full_get_segment_t0/t1` 返回厘秒（10ms），需 `/ 100.0` 转秒。预置 3 个 ggml 模型（tiny 39MB / small 466MB / large-v3-turbo 547MB），下载源 hf-mirror.com，ggml magic header `[0x67,0x67,0x6d,0x6c]`（"ggml" ASCII）校验文件有效性。引擎优先级改为 whisper > sherpa > gguf > cloud（默认 whisper，用户可在设置页切换）

## 安装与构建

### 环境要求

- Flutter 3.41.x（Dart SDK ^3.11.0）
- Android SDK

### 步骤

```bash
# 国内网络建议先设置镜像（PowerShell）
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"

flutter pub get
flutter run          # Debug
flutter build apk --release
```

### LM Studio 本地连接

```bash
lms server start --bind 0.0.0.0
```

APP 设置中填入 PC 局域网 IP：`http://<IP>:1234/v1`。

## 派生关系

- **派生自**: xiaop v1.4.1（AI 情感陪伴助手）
- **集成**: ai_router_module v2.0.0（统一 AI 平台管理）
- 包名 `com.vitasguo.nota`，应用名 NOTA

## 开源协议

MIT License — 详见 [LICENSE](LICENSE)
