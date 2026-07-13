# NOTA 进度

## 项目目标
NOTA - Note with ASR，私人 AI 笔记软件。基于 Flutter，集成 ai_router_module 统一管理多 AI 平台，聚焦"录音 → 转写 → 笔记"场景。派生自 xiaop v1.4.1（AI 情感陪伴助手），继承其多 AI 提供商、主题等基础设施，后续将向笔记 + 语音识别（ASR）方向演进。

## 当前版本: v0.9.7

## 版本历史

### v0.9.7 (2026-07-14) - Qwen3-0.6B 本地翻译 + 下载源全面迁移魔搭 + whisper magic 修复
- **目标**：① 新增 Qwen3-0.6B 作为本地文本 LLM 模型（非 ASR），打通翻译走本地 llama.cpp 路径；② 修复 whisper.cpp ggml 模型 magic header 校验失败（字节序问题）；③ 所有模型下载源尽可能迁移到魔搭社区（ModelScope），国内网络最友好
- **Qwen3-0.6B 本地文本 LLM**（`llm_model_info.dart` + `settings_screen.dart`）
  - GgufLlmModels.available 新增 Qwen3-0.6B（Q8_0，639MB，ChatML 模板，魔搭 `qwen/Qwen3-0.6B-GGUF` 下载源）
  - 设置页 LLM 配置"本地"分支：替换过时的"开发中"提示为真正的本地模型选择 UI（已下载列表 RadioListTile + 下载/导入/删除入口），用户可为翻译/纪要/纠错/笔记整理各自选本地模型
  - 翻译走本地 llama.cpp 架构已打通（v0.6.0 LocalLlmEngine + LlmTaskRouter local 分支），本版本补齐设置页 UI，用户可在"LLM 按功能配置"→翻译→本地→选 Qwen3-0.6B
  - LocalLlmEngine 对 ChatML 模板自动追加 /no_think（翻译低温度 0.1 + thinking off 符合要求）
- **whisper.cpp ggml magic header 修复**（`asr_model_manager.dart`，traps.md #46）
  - 根因：ggml 格式 magic 为 uint32 `0x67676d6c`，小端序存储，文件首 4 字节为 `[0x6c, 0x6d, 0x67, 0x67]`，原代码误用 ASCII 顺序 `[0x67, 0x67, 0x6d, 0x6c]`
  - 修复：`_whisperGgmlMagic` 改为 `[0x6c, 0x6d, 0x67, 0x67]`
- **下载源迁移魔搭**（`asr_model_info.dart` + `llm_model_info.dart`）
  - GGUF ASR（Qwen3-ASR 1.7B/0.6B）：hf-mirror → 魔搭 `ggml-org/Qwen3-ASR-*-GGUF`
  - GGUF 文本 LLM（Qwen2.5-1.5B/3B + Llama-3.2-3B）：hf-mirror → 魔搭 `Qwen/Qwen2.5-*-GGUF` + `unsloth/Llama-3.2-3B-Instruct-GGUF`
  - sherpa-onnx paraformer-zh：hf-mirror（csukuangfj HF 仓库）→ 魔搭 `pengzhendong/sherpa-onnx-paraformer-zh`
  - 保留 hf-mirror：whisper.cpp ggml 模型（魔搭无标准版 tiny/small/large-v3-turbo）
  - 保留 GitHub tar.bz2：sherpa-onnx whisper-medium/large-v3-turbo（魔搭文件名不同 encoder/decoder 分离结构，非首选引擎）
- **验证**：`flutter analyze`（10 个 info，0 error/warning）；`flutter build apk --release` → 成功（66.2s，137.7MB）；版本号 0.9.6+1 → 0.9.7+1
- **v0.9.7 增量修复**（翻译 UI 提示 + whisper 403 处理，traps.md #47）
  - `recording_screen.dart` 翻译状态三态 UI：新增 `_translatingIndices` Set 跟踪翻译中段落（含模型加载阶段）；`_buildSegmentCard` 翻译区域三态显示——翻译中（CircularProgressIndicator + "正在翻译..."）/ 流式译文 / 失败（⚠ 前缀 + errorContainer 红色背景）；`_translateSegment` 添加 SnackBar 错误提示 + finally 清理状态。解决用户"录音界面怎么知道本地 GGUF 正在加载"的疑问
  - `asr_model_manager.dart` downloadWhisperModel 403 错误处理：try-catch 包裹 _dio.download，捕获 403/302（hf-mirror Xet CDN 被墙）时删除残留文件并抛出友好提示（引导下载魔搭源或手动导入）
  - `asr_model_info.dart` WhisperModels 新增 `whisper-large-v3`（魔搭源 `LLM-Research/whisper-large-v3-ggml`，ggml-model.bin，3.1GB）作为 hf-mirror 403 时的备选下载源
- **待真机测试**：whisper.cpp 模型下载（magic header 校验 + 403 是否出现 + 魔搭 large-v3 备选是否可用）+ Qwen3-0.6B 本地翻译效果（录音界面翻译状态提示是否正常）+ 魔搭下载速度

### v0.9.6 (2026-07-14) - 引入 whisper.cpp 作为默认本地 ASR 引擎
- **目标**：解决 Qwen3-ASR（llama.cpp mtmd 接口）同步 FFI 闪退问题，引入 whisper.cpp 作为专用 ASR 引擎替代 llama.cpp mtmd，whisper.cpp 移动端成熟稳定且质量优。llama.cpp 保留用于本地文本 LLM 推理（翻译/纠错/纪要，未来跑 Qwen3 0.6B）
- **架构决策**：whisper.cpp（ggml .bin 模型）专门做 ASR，llama.cpp（GGUF）专门做文本 LLM；sherpa-onnx 保留作为稳定备选 ASR。引擎优先级改为 whisper > sherpa > gguf > cloud（默认 whisper）
- **whisper.cpp Android 交叉编译**（`tool/whisper-build/`）
  - NDK r29 + CMake 4.1.2 + Ninja 1.10.2，arm64-v8a，`-DBUILD_SHARED_LIBS=OFF` 静态链接 ggml
  - 符号冲突解决：`--whole-archive` 强制包含静态库 + version script (`whisper.exports`) 只导出 `whisper_*` 符号，隐藏 ggml 符号避免与 llama.cpp 的 libggml.so 冲突
  - C wrapper 简化 FFI：`whisper_simple_init/transcribe/free` 3 个函数封装复杂 `whisper_full_params` 结构体
  - 产物 `libwhisper_android.so` 2.09MB，strip 后 134 个 whisper_* + 3 个 whisper_simple_* 导出符号
- **Dart FFI 绑定 + 引擎封装**（`lib/services/asr/`）
  - `whisper_ffi.dart`：WhisperFfi 单例，绑定 3 个 whisper_simple_* 函数，返回 `List<({String text, double startSec, double endSec})>`
  - `whisper_engine.dart`：WhisperEngine 高层封装，load/transcribe/dispose API
  - `whisper_isolate_worker.dart`：持久化 worker Isolate（WhisperIsolateWorker），`load`/`transcribe`/`dispose` Map 消息 + SendPort 通信，worker 内复用同一模型实例。whisper_full 是阻塞调用，必须移到 worker Isolate 避免主线程 ANR（与 IsolateAsrWorker 模式一致）
  - `realtime_asr_engine.dart`：新增 WhisperRealtimeAsrEngine（第 4 个实时 ASR 引擎实现），VAD 分段 → 串行队列 → WhisperIsolateWorker.transcribe → onFinal 回调
- **whisper.cpp ggml 模型管理**（`asr_model_info.dart` + `asr_model_manager.dart`）
  - 新增 WhisperModelInfo / WhisperModels 类，预置 3 个模型：
    - whisper-tiny（ggml-tiny.bin，39MB，英文，测试用）
    - whisper-small（ggml-small.bin，466MB，多语言，中文首选）
    - whisper-large-v3-turbo（ggml-large-v3-turbo-q5_0.bin，547MB，多语言，质量最优）
  - 下载源 `https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/{filename}`（国内网络友好）
  - AsrModelManager 新增 whisper 模型管理方法：downloadWhisperModel / importWhisperModel / validateWhisperModelFile（ggml magic header `[0x67,0x67,0x6d,0x6c]` 校验）/ isWhisperModelDownloaded / getWhisperModelPath / deleteWhisperModel
- **引擎选择逻辑 + 设置页 UI**（`recording_screen.dart` + `settings_screen.dart`）
  - 默认引擎偏好从 `sherpa` 改为 `whisper`
  - 引擎尝试顺序：gguf→[gguf,whisper,sherpa]、sherpa→[sherpa,whisper,gguf]、默认→[whisper,sherpa,gguf]
  - 设置页新增 whisper.cpp 模型管理区块（已下载列表 + 下载/导入/删除 UI）
  - 本地 ASR 引擎下拉框从 2 项改为 3 项（whisper/sherpa/gguf）
- **验证**：`flutter analyze`（6 个既有 info，0 error/warning）；`flutter build apk --release` → 成功（60.1s，137.4MB）；版本号 0.9.5+1 → 0.9.6+1
- **待真机测试**：whisper.cpp 实时转写稳定性 + ggml-small 模型中文识别准确率 + VAD 分段准确性 + magic header 校验是否通过

### v0.9.5 (2026-07-14) - LLM 任务差异化配置 + 全代码审查修复
- **目标**：工具型应用按任务差异化配置 LLM 温度/maxTokens/thinking，优化 prompt 防发散；全代码审查修复 11 个真问题
- **LLM 任务差异化配置**（`llm_task_router.dart`）
  - `_defaultConfig` 按 LlmTaskType 区分：translation=0.1/1024（简单任务低温度短输出）、correction=0.1/4096（低温度保留原文长度）、summary/noteOrganize=0.4/4096（中温度允许归纳）
  - 原 4 个任务统一 0.3/4096 无法适配工具型应用"翻译求稳、纪要求归纳"的差异
- **Prompt 强化约束**（`recording_screen.dart` + `translation_service.dart` + `correction_service.dart`）
  - 实时翻译 prompt 加 5 条严格规则：只输出译文正文/保留段落结构/数字专名代码 URL 保留/忠于原文不增删/流畅自然
  - 批量翻译 prompt（TranslationService）同步加规则 + 每条规则 \n 分隔（原拼接成一行 LLM 难解析）
  - 纠错 prompt 加"保持原文行数与顺序、不增删字数、不重写句子"约束
  - translation_service 源语言检测从 zh/en 扩展到 8 种（ja/ko/ru/zh/en），与 recording_screen 的 _targetLanguages 对齐
- **全代码审查修复 11 个真问题**（2 份并行子代理审查报告）
  - **H1 getEngine 并发竞态**（`llm_task_router.dart`）：多个调用方并发 getEngine 同一 taskType 时无去重，本地引擎会重复加载 GB 级模型 OOM → 加 `_pendingFutures` Map 缓存创建中 Future，复用同一 Future 去重
  - **H2 `<think>` 标签过滤缺失**（`summary_service.dart` + `note_service.dart`）：enableThinking=true 时云端模型输出 `<think>...</think>` 思考内容污染纪要/笔记 → 加 `_stripThinkTags` 过滤完整与未闭合标签
  - **H3 CloudLlmEngine 忽略 enableThinking**（`cloud_llm_engine.dart`）：请求体无思考控制字段 → 加 `enable_thinking` 字段（Qwen3 DashScope/DeepSeek R1 等 OpenAI 兼容 API 支持，不支持的 provider 忽略）
  - **M3 `/no_think` 对非 ChatML 模板干扰**（`local_llm_engine.dart`）：Llama3/generic 模板不支持 Qwen3 控制 token，追加会被当普通文本 → 仅对 ChatTemplateType.chatml 追加 `/no_think`
  - **M5 llamaBackendFree 全局影响**（`llama_cpp_engine.dart`）：多 LocalLlmEngine 实例时其一 dispose 调 llamaBackendFree 破坏其他实例 → `_backendInitialized` 改静态字段，dispose 不释放 backend，新增静态 `disposeBackend()` 供 app 退出统一释放
  - **H1 disposeAll 从未调用**（`main.dart`）：LlmTaskRouter.disposeAll 定义但无调用点，GB 级模型热重启累积 → NotaApp.dispose + didChangeAppLifecycleState(detached) 双保险 fire-and-forget 调用
  - **H2 _cancelRecording 未 await stop**（`recording_screen.dart`）：`_asrEngine?.stop()` 未 await，删除 session 时 ASR 仍可能在写孤儿段落 → 改 `await _asrEngine?.stop()`
  - **M1 TextEditingController 未 dispose**（`transcript_screen.dart`）：_editSpeakerLabel 的 controller 在 showDialog 后未 dispose → try/finally 包裹 dispose
  - **M2 DualTrackRecorder.dispose 漏 speakerRecorder**（`dual_track_recorder.dart` + `speaker_recorder.dart`）：仅 dispose micRecorder → SpeakerRecorder 补空 dispose 占位，DualTrackRecorder 调用
  - **M3 AsrModelManager 无 dispose**（`asr_model_manager.dart`）：Dio 实例未 close → 补 `dispose() { _dio.close(); }`
  - **M4/M5 unawaited 标注缺失**（`recording_screen.dart`）：insertSegment/updateTranslation/_translateSegment fire-and-forget 未 unawaited → 4 处加 `unawaited(...)`
  - **L1 correction_service._generate 模式不一致**（`correction_service.dart`）：用 Completer 未 await engine.generate（C5 旧模式残留）→ 改为 `await + 外部 result/error 变量` 模式，与 summary/note 一致；移除冗余 `dart:async` import
- **验证**：`flutter analyze`（14 文件）→ No issues found!；`flutter build apk --release` → 成功（108.3s，135.6MB）；版本号 0.9.4+1 → 0.9.5+1

### v0.9.4 (2026-07-14) - ASR 引擎下拉框溢出修复 + 翻译关闭 thinking 模式
- **目标**：修复本地 ASR 引擎下拉框文字溢出 + 翻译任务关闭 thinking 模式加速生成
- **ASR 引擎下拉框溢出修复**（`settings_screen.dart`）
  - DropdownButtonFormField 加 `isExpanded: true` + `helperMaxLines: 2`
  - DropdownMenuItem 文字缩短为"sherpa-onnx（稳定）"/"GGUF ASR（质量优）"，加 `overflow: TextOverflow.ellipsis`
- **翻译关闭 thinking 模式**（`llm_engine.dart` + `local_llm_engine.dart` + `cloud_llm_engine.dart`）
  - 根因：ornith-1.0-9b 等支持思考模式的模型默认生成 `<think>` 内容，翻译等简单任务浪费大量 token
  - LlmEngine.generate 接口新增 `enableThinking` 参数（默认 false）
  - LocalLlmEngine `_buildPrompt` 在 `enableThinking=false` 时于 user 内容末尾追加 `/no_think`，抑制 `<think>` 输出
  - CloudLlmEngine 同步加参数保持接口一致（云端不处理，透传）
  - 所有现有调用方（翻译/纠错/纪要/笔记整理）均使用默认值 false，即默认关闭 thinking
- **验证**：`flutter analyze`（5 文件）→ No issues found!；`flutter build apk --debug` → 成功（41.4s）；版本号 0.9.3+1 → 0.9.4+1

### v0.9.3 (2026-07-14) - 翻译互译模式 + 录音中可切换翻译
- **目标**：新增中英互译模式（自动检测原文语言双向翻译）+ 允许录音中随时开关翻译
- **互译模式**（`recording_screen.dart`）
  - 目标语言列表首位新增"自动（中英互译）"选项
  - 新增 `_buildTranslationPrompt` 方法：互译模式 prompt 让 LLM 检测原文是中文翻译为英语、是英语翻译为中文，其他语言保持原文；普通模式 prompt 不变
- **录音中可切换翻译**（`recording_screen.dart`）
  - 去掉 Switch 的 `onChanged: _isRecording ? null` 限制，录音中也可开关翻译
  - 录音中开启翻译时自动补译已有但未翻译的段落（遍历 `_segments`，对 `_partialTranslations[i] == null` 的段落调用 `_translateSegment`）
  - 去掉 DropdownButton 的录音中禁用限制，录音中也可切换目标语言
- **验证**：`flutter analyze` → No issues found!；`flutter build apk --debug` → 成功（13.1s）；版本号 0.9.2+1 → 0.9.3+1

### v0.9.2 (2026-07-14) - 录音界面翻译目标语言选择
- **目标**：录音界面翻译按钮旁加目标语言下拉框，让用户选择翻译到哪种语言
- **改动**（`recording_screen.dart`）
  - 新增 `_translationTargetLang` 状态字段（默认"中文"），持久化到 SharedPreferences key `translation_target_lang`
  - initState 加载持久化的目标语言
  - `_translateSegment` 的 systemPrompt 改用动态 `_translationTargetLang`（原硬编码"中文"）
  - 翻译开关 UI 下方原"翻译"文字替换为目标语言下拉框（DropdownButton），支持中文/英语/日语/韩语/法语/德语/西班牙语/俄语 8 种语言
  - 录音中禁止切换语言（`onChanged: _isRecording ? null`），避免中途切换导致译文不一致
  - 翻译开启时语言文字高亮 primary 色，关闭时灰色
- **验证**：`flutter analyze` → No issues found!；`flutter build apk --debug` → 成功（20.0s）；版本号 0.9.1+1 → 0.9.2+1

### v0.9.1 (2026-07-14) - ASR 引擎选择 UI + 代码审查修复
- **目标**：解决 Qwen ASR 闪退问题（用户可选择引擎避免自动选 GGUF 闪退）+ 修复代码审查报告中的真问题
- **ASR 引擎选择 UI**（`settings_screen.dart` + `recording_screen.dart`）
  - 设置页 ASR 配置区新增"本地 ASR 引擎"下拉选择：sherpa-onnx（默认稳定）/ GGUF ASR（Qwen3-ASR 质量优）。SharedPreferences key: `asr_local_engine_pref`
  - recording_screen `_initAsrEngine` 改为读取用户偏好决定引擎顺序，偏好引擎模型未下载时自动回退另一种引擎
  - 解决"下载 Qwen 0.6B 后仍用 Paraformer"问题：用户需在设置页手动选 GGUF ASR 才会优先使用
  - 解决"Qwen ASR 闪退"问题：默认 sherpa-onnx 避免同步 FFI 阻塞闪退
- **代码审查修复**（3 个真问题）
  - **C1 修复**（`llm_task_router.dart`）：`getEngine()` 每次新建引擎不释放 → 改为按 taskType 缓存引擎实例，`setConfig` 时 dispose 旧引擎清除缓存，新增 `disposeAll()` 供 app 退出时调用
  - **C3 修复**（`llm_model_manager.dart:83`）：`return validateGgufFile(path)` 缺 await → `return await validateGgufFile(path)`，此前所有文件都跳过 GGUF magic 校验
  - **H11 假阳性**（`hotword_screen.dart:737`）：审查说 `initialValue` 不存在应改 `value`，但实际 Flutter 3.33+ 中 `value` 已废弃，`initialValue` 才是正确参数。保持原代码不改
- **LM Studio needsApiKey 改回 true**（`ai_providers.dart`）：v0.9.0 误改为 false，LM Studio 支持配置 API Key 鉴权
- **验证**：`flutter analyze`（6 文件）→ 0 issues；`flutter build apk --debug` → 成功（42.9s）；版本号 0.9.0+1 → 0.9.1+1

### v0.9.0 (2026-07-10) - AI Router 模型选择优化 + 恢复 GGUF ASR 优先级
- **目标**：解决 AI Router 中 LM Studio/自定义接口模型名输入框多余、LLM 按功能配置选这两个提供商后无法选模型体验割裂的问题；恢复 GGUF ASR 优先级（用户下载了 Qwen3-ASR 0.6B 期望优先使用）
- **问题 1：AI Router 模型选择优化**
  - **删 Model 输入框**（`ai_router_screen.dart`）：LM Studio/自定义接口的"模型名"输入框删除，因测试连接时自动获取模型列表。移除 `_modelController`/`_saveModel`/`_buildModelField`/`_modelKey` 相关代码
  - **持久化 fetchedModels**（`ai_router_service.dart`）：新增 `saveFetchedModels`/`getFetchedModels` 方法，测试连接成功后把获取到的模型列表持久化到 SharedPreferences（key: `ai_router_models_<provider>`），供 LLM 按功能配置页读取
  - **AiConfigSelector 改造**（`ai_config_selector.dart`）：从 ConsumerWidget 改为 ConsumerStatefulWidget。模型列表数据源 = 预设 `availableModels` + `getFetchedModels`（去重合并）。合并后仍为空时显示文本输入框让用户手动输入模型名
  - **LM Studio needsApiKey 改 false**（`ai_providers.dart`）：LM Studio 默认无鉴权，`needsApiKey` 从 `true` 改为 `false`，测试连接不再要求填 API Key
  - **testConnection 去掉 model 依赖**（`ai_router_service.dart`）：回退探活 `/chat/completions` 不再传 model 字段（LM Studio 会用默认加载的模型）
  - **_buildCloudLlmConfig 传 customUrl**（`settings_screen.dart`）：切换到 LM Studio/自定义提供商时，从 SharedPreferences 读取 AI Router 保存的 URL 设入 `LlmConfig.customUrl`，确保 CloudLlmEngine 有 baseUrl 可用。同时加 `aiRouterRoute` 参数允许跳转配置
- **问题 2：恢复 GGUF ASR 优先级**
  - v0.8.1 因 GGUF ASR 同步 FFI 闪退风险把 sherpa-onnx 提到优先。但用户下载 Qwen3-ASR 0.6B 说明想用（质量更优）。0.6B 模型小推理快，samples 长度保护已加（traps.md #37），恢复 GGUF ASR > sherpa-onnx > 云端优先级。GGUF ASR 内部优先选 0.6B（轻量低延迟）
- **验证**：`flutter analyze`（6 文件）→ 3 个 info（deprecation 提示，不影响编译）；`flutter build apk --debug` → 成功（58.6s）；版本号 0.8.2+1 → 0.9.0+1
- **待真机测试**：GGUF ASR 0.6B 实时转写是否正常 + LM Studio 选模型是否正常 + 自定义接口模型获取

### v0.8.1 (2026-07-10) - 修复录音启动失败 + 闪退问题
- **目标**：修复"bad state: already been listened to"启动失败 + 录音说话后闪退两个阻断性 bug
- **根因 1：Stream 重复订阅**（`lib/presentation/recording/recording_screen.dart`）
  - `_micRecorder.startStream()` 返回 single-subscription stream，`_asrEngine.start()` 内部 `listen()` 订阅一次后，界面 `_streamSub = stream.listen()` 再次订阅 → 抛 `StateError: already been listened to`
  - 修复：`.asBroadcastStream()` 转广播流；调整订阅顺序（界面先 listen 再引擎 start，确保不丢首包）
- **根因 2：启动失败后状态未清理**
  - catch 块仅显示 SnackBar，未停止 ASR 引擎/麦克风流 → `_isStreaming=true` 残留，再次点击报"流式录音已在进行中"
  - 修复：catch 块增加 `_asrEngine?.stop()` + `_micRecorder.stopStream()` + `_streamSub?.cancel()` 清理
- **根因 3：GGUF ASR 同步 FFI 阻塞主线程导致闪退**
  - `LlamaCppEngine.transcribeAudio` 是同步 FFI 调用（1-3s/段），在主 isolate 执行会阻塞 UI 线程，Android 可能 ANR/crash
  - 修复：调整引擎优先级——sherpa-onnx ASR（SenseVoice > Paraformer，ONNX 运行时移动端成熟稳定）优先于 GGUF ASR（Qwen3-ASR，质量优但同步阻塞风险）
  - 同时在两个 `_processQueue` 中增加 samples 长度保护（< 1600 样本 = 0.1s 跳过），避免过短音频段触发原生库 crash
- **验证**：`flutter analyze`（2 文件）→ No issues found!（2.2s）；`flutter build apk --debug` → 成功（19.2s）；版本号 0.8.0+1 → 0.8.1+1
- **待真机测试**：Paraformer 实时转写是否正常 + VAD 分段准确性 + 停止录音后 WAV 备份完整性

### v0.8.0 (2026-07-10) - ModelScope 下载源 + SenseVoice 多语言模型
- **目标**：解决国内用户从 GitHub/HF 下载 ASR 模型超时的问题，新增魔搭社区（ModelScope）下载源 + SenseVoice Small 多语言模型（中英日韩粤），让国内用户能开箱即用完成离线实时转写
- **背景**：v0.6.0 的 GGUF ASR 模型（Qwen3-ASR ~2.4GB）从 hf-mirror.com 下载仍不稳定；sherpa-onnx ASR 模型（Whisper/Paraformer）下载源为 GitHub releases，国内 Dioexception 失败。用户反馈"录音功能也提示没有 vad 模型，必须想办法内置一个小规模模型确保功能能打通"，并建议从魔搭社区下载（国内网络最友好）
- **ModelScope 下载源新增**（`lib/services/asr/asr_model_info.dart` + `asr_model_manager.dart`）
  - `AsrModelInfo` 新增 `modelscopeRepo`（魔搭模型 ID，如 `xiaowangge/sherpa-onnx-sense-voice-small`）+ `modelscopeFiles`（需下载的文件列表）字段 + `useModelScopeDownload` getter
  - `AsrModelManager.downloadModel` 新增 ModelScope 分支（优先于 HF 分支），新增 `_downloadFromModelScope` 方法：逐文件下载，URL 格式 `https://www.modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={file}`，API 返回 302 重定向 Dio 自动跟随，进度按 `info.sizeBytes` 加权计算
  - Dio BaseOptions 新增 `receiveTimeout: Duration(minutes: 30)` 支持大文件下载（~239MB）
- **SenseVoice Small 模型新增**（`lib/services/asr/asr_model_info.dart`）
  - 新增到 `AsrModels.available` 列表首位（id `sensevoice-zh`，~239MB，从魔搭社区 `xiaowangge/sherpa-onnx-sense-voice-small` 下载 `model_q8.onnx` + `tokens.txt`）
  - 阿里多语言语音识别模型（Q8 量化版），支持中英日韩粤 5 种语言，国内网络最友好，推荐首选
- **SherpaRealtimeAsrEngine 支持 SenseVoice**（`lib/services/asr/realtime_asr_engine.dart`）
  - `_buildRecognizerConfig` 新增 SenseVoice 分支：用 `OfflineSenseVoiceModelConfig`（model + language + useInverseTextNormalization: true），language 经 `_senseVoiceLanguage` 映射（zh/en/yue/ja/ko，其他返回 auto 自动检测）
  - 更新类文档注释：SherpaRealtimeAsrEngine 现支持三类模型（SenseVoice 首选 / Paraformer 回退 / Whisper）
- **录音界面模型选择优先级更新**（`lib/presentation/recording/recording_screen.dart`）
  - `_initAsrEngine()` 4 级优先级：GGUF ASR > sherpa-onnx ASR（SenseVoice > Paraformer > 其他）> 云端 ASR > 抛错
  - 错误提示更新为"请在设置中下载 SenseVoice 模型（~239MB，从魔搭社区下载，国内首选）"
- **验证**：`flutter analyze`（4 个修改文件）→ No issues found!（2.4s）；`flutter build apk --debug` → 构建成功（19.6s）；版本号 0.7.0+1 → 0.8.0+1
- **待真机测试**：ModelScope 下载实际成功率 + SenseVoice 转写延迟/准确率 + VAD 准确性 + 翻译流式

### v0.6.0 (2026-07-09) - realtime-asr-upgrade 实时 ASR 升级
- **目标**：实现本地 ASR 实时转写（Qwen3-ASR via llama.cpp mtmd）+ 录音界面重构为实时转写笔记 + LocalLlmEngine 打通本地 LLM 路由
- **Task 6 RealtimeAsrEngine 实时 ASR 引擎**（`lib/services/asr/realtime_asr_engine.dart`，~515 行）
  - 抽象接口 `RealtimeAsrEngine`（init/start/stop/dispose + onSpeechStart/onFinal/onError 回调）
  - `LocalRealtimeAsrEngine`：VadDetector 分段 → 串行队列 → LlamaCppEngine.transcribeAudio → onFinal 回调 TranscriptSegment
  - `CloudRealtimeAsrEngine`：VAD 分段 → 写临时 WAV → CloudAsrEngine.transcribe → onFinal；支持无 VAD 整段上传模式
  - `VadConfig` 参数封装（threshold/minSilenceDuration/minSpeechDuration/maxSpeechDuration/windowSize）
  - 架构：转写异步串行队列（_pending + _transcribing），VAD 同步喂入快速不阻塞音频流；onPartial 未实现（Qwen3-ASR 整段推理无 token 级流式），UI 用 onSpeechStart 显示"正在转写..."占位
  - 验证：`flutter analyze` → No issues found!

- **Task 7 Qwen3-ASR GGUF 模型管理**（修改 `asr_model_info.dart` + `asr_model_manager.dart`）
  - 关键发现：handy-computer/Qwen3-ASR-1.7B-gguf 的 Q6_K 用 `qwen3_asr` 架构（transcribe.cpp 专用）**不兼容** llama.cpp mtmd（仅识别 `qwen3vl` 架构），故改用 ggml-org 官方仓库（含 mmproj 文件）
  - `GgufModelFile` / `GgufAsrModelInfo` / `GgufAsrModels` 类：预置 Qwen3-ASR-1.7B（~2.4GB）+ 0.6B（~1.0GB）Q8_0 模型，下载源为 ggml-org 官方经 hf-mirror.com 镜像
  - AsrModelManager 新增 GGUF 管理：`downloadGgufModel`（双文件顺序下载 + 加权进度 + 阶段回调）/ `importGgufModel`（file_picker 双选）/ `validateGgufFile`（magic header 校验）/ `isGgufModelDownloaded` / `getGgufModelPaths` / `deleteGgufModel`
  - 验证：`flutter analyze` → No issues found!

- **Task 8/9 RecordingScreen 重构 + 实时转写持久化**（`lib/presentation/recording/recording_screen.dart`，~900 行完全重写）
  - 从旧版录音控制台重构为实时转写笔记界面（ConsumerStatefulWidget）
  - 主体为转写文本展示区（ListView + 段落卡片含时间戳+原文+流式译文），底部紧凑控制栏（计时器+录音按钮+翻译开关）
  - `_initAsrEngine()`：优先级——本地 GGUF ASR > 云端 ASR > 抛错；GGUF ASR 模型 id 无持久化设置项，通过 `getDownloadedGgufModels()` 动态检测，优先选 1.7B
  - `_startRecording()`：初始化 ASR → 配置回调 → 创建会话 → 启动麦克风流 + ASR → 订阅流累积 PCM（用于停止时写 WAV 备份）
  - `_onAsrFinal()`：段落加入列表 + **即时写入 TranscriptStorage**（不等停止后批量写，崩溃前已持久化的段落保留在 SQLite）+ 自动滚动 + 可选实时翻译
  - `_translateSegment()`：LlmTaskRouter.getEngine(LlmTaskType.translation) → 流式 generate → 译文在原文下方灰底容器显示 → 持久化 updateTranslation
  - `_writePcmBufferToWav()`：停止时将 PCM 缓冲写为 WAV 备份（44 字节 header + PCM16）
  - `_cancelRecording()`：确认对话框 → 停止录音 → 删除会话与转写数据 → 返回
  - 移除旧版三模式选择（mic/speaker/dual），简化为纯麦克风流式
  - 验证：`flutter analyze` → No issues found!

- **Task 10 LocalLlmEngine 实现**（3 个新文件 + 1 个修改）
  - `lib/services/llm/llm_model_info.dart`：GgufLlmModelFile / GgufLlmModelInfo / ChatTemplateType 枚举 / GgufLlmModels 预置清单（Qwen2.5-1.5B/3B-Instruct Q5_K_M + Llama-3.2-3B-Instruct Q4_K_M，下载源 hf-mirror.com）
  - `lib/services/llm/llm_model_manager.dart`：LlmModelManager 单例（Dio 下载 + file_picker 导入 + magic 校验 + 自定义模型扫描），模型根目录 `{docsDir}/llm_models/`
  - `lib/services/llm/local_llm_engine.dart`：LocalLlmEngine implements LlmEngine，包装 LlamaCppEngine。init 按 config.modelName 经 LlmModelManager 定位 GGUF → load；generate 按 ChatTemplateType（ChatML/Llama-3/Generic）构建 chat prompt → LlamaCppEngine.generate 同步流式 → 映射 onToken/onComplete/onError。性能说明：同步 FFI 调用用 `Future(...)` 放入事件队列，但 token 在 generate 返回前全部经 onToken 发出（UI 在 generate 完成后渲染），真正逐 token 异步流式需后续 Isolate 优化
  - 修改 `lib/services/llm/llm_task_router.dart`：getEngine 本地分支从"返回 null + TODO"改为"LocalLlmEngine + init + return"，打通本地 LLM 路由
  - 验证：`flutter analyze` → No issues found!

- **Task 11 端到端集成验证**
  - `flutter analyze` 全项目通过（3 个既有 info 在 ai_config_selector.dart，非本次引入，无 error/warning）
  - `flutter build apk --debug` 构建成功（48.3s）
  - 版本号 0.5.0+1 → 0.6.0+1
  - 真机测试待执行：AI Router 数据持久化 + 实时 ASR 延迟 + VAD 准确性 + 翻译流式 + 本地 LLM 推理

### v0.4.3 基础设施 (2026-07-09) - Task 2.2-2.5 交叉编译 llama.cpp 为 Android arm64 共享库
- **目标**：为 LocalLlmEngine（llama.cpp FFI，Task 11）+ Qwen3-ASR 音频输入（mtmd 接口）准备 Android arm64-v8a 原生库，供 Dart FFI 调用。项目根目录已有 `Qwen3-ASR-1.7B-Q6_K.gguf` 模型
- **环境**：NDK r29 (29.0.14206865) + SDK CMake 3.22.1（含 ninja）+ Clang 21 + Git 2.53。`ANDROID_NDK*` 环境变量未设，但 NDK 实际在 `%LOCALAPPDATA%\Android\Sdk\ndk\29.0.14206865`，toolchain 路径 `build/cmake/android.toolchain.cmake`
- **源码获取**（traps.md #30）：gitclone.com 卡死、kkgithub.com 返回 504、GitHub 直连 30s 无数据；最终用 **gh-proxy.com 镜像下载 master.zip**（34.93MB）+ .NET `[System.IO.Compression.ZipFile]::ExtractToDirectory` 解压 + robocopy /MIR 整理到 `SOLO/llama.cpp`（顺带清掉中断克隆的 .git 残骸）
- **CMake 配置**（`build-android-arm64/`）：`-G Ninja -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_CURL=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=OFF`
  - 关键点：①新版用 `BUILD_SHARED_LIBS`（非旧版 `LLAMA_SHARED`，后者被 CMake 警告未使用，traps.md #31）；②`LLAMA_BUILD_MTMD=ON + LLAMA_BUILD_TOOLS=OFF` 单独构建 libmtmd（不构建 CLI）；③`LLAMA_BUILD_APP=OFF` 必须显式关闭，否则 app/download.cpp 编译失败 `arg.h not found`（traps.md #32）；④`GGML_BACKEND_DL=OFF` 让 CPU 后端生成独立 libggml-cpu.so；⑤`GGML_NATIVE=OFF` 交叉编译禁用本机指令集探测
- **编译**：`cmake --build . --config Release -j`，共 274 目标。首次失败在 app/download.cpp（LLAMA_BUILD_APP 未关），加 `-DLLAMA_BUILD_APP=OFF` 重新配置后增量编译 30 目标成功，BUILD_EXIT=0。mtmd 编译含 `models/qwen3a.cpp`（Qwen3-ASR 支持）
- **产物**（build-android-arm64/bin/，6 个 .so 未 strip）：libllama.so 33.67MB / libmtmd.so 11.42MB / libggml.so 4.71MB / libggml-base.so 7.53MB / libggml-cpu.so 4.38MB / libllama-common.so 62.75MB
  - 依赖链（llvm-readelf -d 确认）：libmtmd.so → libllama.so → libggml.so → libggml-cpu.so → libggml-base.so → 系统库(libm/libdl/libc)。libllama-common.so 不在 mtmd 依赖链（CLI 工具用），**排除**
- **放置 + strip**：5 个必需 .so 经 NDK 自带 `llvm-strip --strip-debug`（保留 .dynsym 动态符号供 FFI，仅去 .debug_* 段）后复制到 `android/app/src/main/jniLibs/arm64-v8a/`：
  | 文件 | strip 前 | strip 后 |
  |---|---|---|
  | libllama.so | 33.67 MB | 3.37 MB |
  | libmtmd.so | 11.42 MB | 1.15 MB |
  | libggml-base.so | 7.53 MB | 1.28 MB |
  | libggml-cpu.so | 4.38 MB | 0.92 MB |
  | libggml.so | 4.71 MB | 0.89 MB |
  | **总计** | 61.71 MB | **7.61 MB** |
- **验证**：strip 后 libmtmd.so NEEDED 依赖完整（4 自有 .so + 3 系统库）+ SONAME 正确；libllama.so 3.37MB 符合"几 MB"预期
- **约束遵守**：未修改任何 NOTA Dart/Kotlin 源码，仅在 jniLibs 放置 .so；编译在 `SOLO/llama.cpp` 进行；pubspec 版本未升（约束"不改源码"）
- **后续**：Task 2.6+ Dart FFI 绑定 libmtmd.so（Qwen3-ASR 音频输入 mtmd 接口）+ LocalLlmEngine 实现

### v0.4.3 (2026-07-09)
- **Task 5.2-5.4 VAD 语音活动检测 + MicRecorder 流式改造**：为实时 ASR 铺设基础设施（麦克风 PCM16 流 → VAD 分段 → 后续送 ASR）。本次仅实现采集与检测层，未接入实时 ASR 转写链路
  - **Task 5.4 MicRecorder 流式改造**（`lib/services/audio/mic_recorder.dart`）：
    - 保留文件模式 [start]/[stop] 不变（批量转写仍用 WAV）
    - 新增 `startStream() async*`：返回 `Stream<Uint8List>` PCM16 裸流（16kHz 单声道 `AudioEncoder.pcm16bits`，无 WAV 头），用 record 6.2.1 的 `AudioRecorder.startStream(RecordConfig)` → `yield*` 转发
    - 新增 `stopStream()`：调 `AudioRecorder.stop` 关闭底层流，订阅者收到 done
    - 流式与文件模式互斥守卫（`_isStreaming` / `_isRecording`），权限未授予抛 StateError；`startStream` 用 `try/finally` 确保流关闭后复位 `_isStreaming`
    - 新增 `import 'dart:typed_data'`（Uint8List）
  - **Task 5.2 VadDetector 封装**（新建 `lib/services/asr/vad_detector.dart`）：
    - 顶层工具函数 `convertPcm16ToFloat32(Uint8List) → Float32List`：小端有符号 16-bit / 32768.0 归一化，奇数字节丢弃尾部
    - `VadDetector` 类：构造接收 `modelPath`（silero_vad.onnx 路径）+ 回调 + 参数（threshold 0.5 / minSilenceDuration 0.8 / minSpeechDuration 0.25 / maxSpeechDuration 30.0 / windowSize 512 / sampleRate 16000），内部持 `sherpa_onnx.VoiceActivityDetector`
    - `feedPcm16(Uint8List)` → 转换 → `acceptWaveform` → `_poll()`
    - `_poll()`：边沿检测（`isDetected()` false→true 触发 `onSpeechStart`）+ 循环 `front`/`pop` 取出 SpeechSegment 触发 `onSpeechEnd(startSample, samples, startSec, endSec)`
    - `flush()`：调 `vad.flush()` 强制输出尾部语音段 + `_poll`；`dispose()`：`vad.free()` 释放原生资源，`_disposed` 守卫防重复释放
    - 用 `as sherpa_onnx` 前缀导入（与 local_asr_engine.dart 风格一致）
  - **Task 5.3 VAD 模型管理**（`lib/services/asr/asr_model_info.dart` + `asr_model_manager.dart`）：
    - asr_model_info.dart：新增 `AsrModels.vadModel` 常量（id `silero-vad`，下载地址 `github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`，~2MB）+ `vadModelId` 常量。**不加入 `available` 列表**（VAD 非 ASR 转写模型，独立管理，避免污染设置页 ASR 模型选择 UI）
    - asr_model_manager.dart：新增 `getVadModelDir()`（`{docsDir}/asr_models/vad/`）、`getVadModelPath()`（`{docsDir}/asr_models/vad/silero_vad.onnx`）、`isVadModelDownloaded()`（直接探测 .onnx 存在，无 tokens.txt）
    - `isModelDownloaded` / `downloadModel` / `deleteModel` 均增加 `modelId == AsrModels.vadModelId` 分支：VAD 单文件直接 Dio 下载落盘（非归档解压），删除整 `vad/` 目录
    - 新增私有 `_downloadVadModel({onProgress})`：幂等（已下载跳过）+ 清理残留 + Dio 直下 .onnx
  - **main.dart 补 sherpa.initBindings()**（`lib/main.dart`）：
    - 在 `WidgetsFlutterBinding.ensureInitialized()` + SystemChrome 后、数据库初始化前，新增 `sherpa_onnx.initBindings()` 同步调用（try/catch 失败不阻塞启动）
    - 关键决策：`initBindings` 是顶层 **void** 函数（非 Future），按源码实际签名同步调用（无 await，避免 `await_only_futures` lint）；用 `as sherpa_onnx` 前缀与 local_asr_engine.dart 一致。LocalAsrEngine.init 内部已有幂等 `_bindingsInitialized` 调用，main 中提前调用使 VAD 可在 ASR 引擎未 init 时独立使用
  - **验证**：`flutter analyze lib/services/asr/vad_detector.dart lib/services/audio/mic_recorder.dart lib/services/asr/asr_model_manager.dart lib/services/asr/asr_model_info.dart lib/main.dart` → `No issues found!`（0 errors / 0 warnings，17.8s）
  - **版本号**：pubspec.yaml 0.4.3+1 → 0.5.0+1（新增 VAD+流式功能，minor bump）
  - **已知未完成**：VAD 分段结果尚未接入实时 ASR 转写链路（onSpeechEnd 回调的 samples 待送 LocalAsrEngine 流式转写）；silero_vad.onnx 实际下载与端到端实时识别需物理设备验证

### v0.4.3 (2026-07-09)
- **Task 1 修复 AI Router 自定义接口数据持久化 bug**（`lib/presentation/settings/ai_router_screen.dart`，traps.md #27）
  - **Bug 现象**：用户在 AI Router 页面填写自定义接口 URL/Model/API Key 后①无法测试连接（数据未保存就测试，按钮禁用）②退出再进入后填写信息全部丢失
  - **根因**：`_ProviderCard`（StatefulWidget）的 `_urlController`/`_modelController` 仅内存 TextEditingController 无持久化逻辑，`initState` 总用 `provider.defaultBaseUrl`/`defaultModel` 初始化不读已保存值；API Key 保存依赖 `onSubmitted`（回车键），直接点测试按钮则 key 未保存；`_canTest()` 检查 `widget.apiKey`（已保存状态）而非输入框当前值，导致未保存时按钮禁用。AiConfigNotifier 虽有按 provider 持久化 model/url 机制（`_keyModel`/`_keyUrl`）但 AiRouterScreen 未使用
  - **修复内容**（仅改 ai_router_screen.dart，不改 services/ 和 providers/）：
    - URL/Model 持久化：新增 `_urlKey`/`_modelKey` getter（key `ai_router_url_${provider.type.name}` / `ai_router_model_${provider.type.name}`），`initState` 调 `_loadSavedValues()` 异步从 SharedPreferences 读取已保存值覆盖默认值；URL/Model 输入框增 `onChanged` 回调直接 `_saveUrl`/`_saveModel` 持久化（直写 SharedPreferences 不触发 rebuild，无需 debounce）
    - API Key 持久化改进：保留 `onSubmitted`（回车立即保存），新增 `onChanged` 500ms debounce 自动保存（经 `widget.onSetKey` 走 provider 触发 rebuild 故 debounce）；`_doTest()` 前 `await widget.onSetKey(...)` 确保测试前已持久化
    - `_doTest()` 测试前自动保存：showUrlAndModel 时先 `await _saveUrl`/`_saveModel`，needsApiKey 且非内置 key 时先 `await widget.onSetKey`，再执行 `widget.onTest`（测试本身用 apiKeyOverride 直传输入值，持久化为退出后保留）
    - `_canTest()` 改用 `_apiKeyController.text.trim()` 判断（输入框当前值）替代 `widget.apiKey`（已保存状态），用户输入未保存也可测试
    - `onSetKey` 字段类型 `ValueChanged<String>`（void）→ `Future<void> Function(String)` 以支持 `_doTest` 中 await（确定保存完成后再测试，避免 setKey 清除 testResults 与 testProvider 设置 testResults 的竞态）；sync 回调中的 fire-and-forget 调用用 `unawaited()`（dart:async）避免 unawaited_futures lint
  - **验证**：`flutter analyze lib\presentation\settings\ai_router_screen.dart` 通过，No issues found（0 errors / 0 warnings）
  - **版本号**：pubspec.yaml 0.4.2+1 → 0.4.3+1

### v0.4.1 (2026-07-09)
- **Task 24b.3 修复 record 包版本冲突 + Kotlin 编译错误**：解除 `flutter build apk --debug` 构建阻断（traps.md #25 + #26），APK 构建首次成功
  - **record 包升级（traps.md #25 修复）**：pubspec.yaml `record: ^5.1.0` → `record: ^6.0.0`（解析到 6.2.1）
    - record 5.2.1 → 6.2.1；record_linux 0.7.2 → 1.3.1（与 record_platform_interface 1.6.0 兼容）；record_platform_interface 保持 1.6.0
    - record 6.x 无 AudioRecorder/RecordConfig API 破坏性变更（仅 additive），mic_recorder.dart 零修改
    - record 7.x 要求 Dart 3.12，项目 ^3.11.0 不满足，不可用
    - 6.0.0 起 record_darwin 拆分为 record_ios + record_macos；uuid/fixnum 传递依赖移除
  - **MainActivity.kt Kotlin 编译错误修复（traps.md #26，被 #25 掩盖的遗留 bug）**：
    - line 108-111：`getMediaProjection()` 返回 `MediaProjection?` 加 null 检查（throw 被 try-catch 优雅处理）
    - line 125：移除不存在的 `setCaptureMode(CAPTURE_MODE_ALL)`（API 幻觉，addMatchingUsage 已覆盖）
    - line 262-263：`sampleRate`/`byteRate` 传 `writeInt32LE(Long)` 加 `.toLong()`（Kotlin 不自动 Int→Long）
  - **版本号**：pubspec.yaml 0.4.0+1 → 0.4.1+1
  - **验证**：`flutter pub get` ✓ → `flutter analyze` ✓（4 issues 均既有遗留：transcript_screen unused_import + ai_config_selector 3 info）→ `flutter clean` + `flutter build apk --debug` ✓ **首次构建成功**（`√ Built build\app\outputs\flutter-apk\app-debug.apk`，23.7s）
  - **发现**：构建编译顺序 kernel_snapshot(Dart) → compileDebugKotlin(Kotlin)，kernel 失败会掩盖 Kotlin 错误；曾遇到 kernel 缓存陈旧导致 `_onRunFullPipeline` 幻影错误，`flutter clean` 解决

### v0.3.0 (2026-07-09)
- **Task 24b 修复 Task 24 发现的 2 个集成断点**（路由崩溃 + 编排器未接线）
  - **Task 24b.1 录音→转写路由断点修复**（`lib/presentation/recording/recording_screen.dart`）：
    - 录音结束 BottomSheet 两处 `context.push('/transcripts/$sessionId')` / `context.push('/transcripts/$sessionId?action=organize')` 运行时崩溃（app_router.dart 未注册 `/transcripts/:id` 路由，traps.md #23）
    - 改用 `Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(...))` 直达 TranscriptScreen，与 speaker_screen.dart:437 已验证模式一致（traps.md #18 规律）；"一键整理"入口传 `autoOrganize: true` 构造参数
    - 添加 `import 'package:nota/presentation/transcripts/transcript_screen.dart';`；移除废弃 TODO 注释
  - **Task 24b.2 PipelineOrchestrator 接线到 UI**（`lib/presentation/transcripts/transcript_screen.dart`）：
    - TranscriptScreen 新增可选参数 `autoOrganize`（bool，默认 false）；initState 检测为 true 时用 `WidgetsBinding.instance.addPostFrameCallback` 首帧后自动触发全流水线（确保 context/Scaffold 就绪）
    - 新增 `_onRunFullPipeline()`：调用 `PipelineOrchestrator().runFullPipeline(sessionId, config: PipelineConfig.defaultConfig, onStepProgress, onLog)`，用 `PipelineConfig.defaultConfig`（翻译关闭，其余 5 步开启）
    - 进度对话框（不可关闭 PopScope）：LinearProgressIndicator 整体进度（按 config 启用步骤数归一化：已完成步数+当前步进度 / 总步数）+ 当前步骤名+百分比（转写/声纹区分/纠错/翻译/纪要/笔记，经 `_pipelineStepName` 映射）+ 日志区（onLog 追加，reverse 滚动）
    - 完成后 `_loadData()` 刷新段落列表与笔记；result.isSuccess 时 SnackBar 报成功（含完成步数），否则报失败步骤明细（保留已完成步骤结果，编排器错误传播策略不变）
    - AppBar PopupMenu 新增"一键整理"项（首位 + PopupMenuDivider 分隔），onSelected 接线 `_onRunFullPipeline`
    - 添加 `import 'package:nota/services/pipeline/pipeline_orchestrator.dart';`
  - **验证**：`flutter analyze lib\presentation\recording\recording_screen.dart lib\presentation\transcripts\transcript_screen.dart` 通过，No issues found（0 errors / 0 warnings）
  - 版本号 0.4.1+1 → 0.4.2+1

### v0.3.0 (2026-07-09)
- **Task 24 端到端集成测试验证**（可自动化验证，非 true E2E）：Android 构建验证 + 流水线调用链静态审查
  - **Android 构建验证**：`flutter build apk --debug` **失败**。根因：pubspec.lock 中 `record` 5.2.1 传递依赖 `record_linux` 0.7.2 与 `record_platform_interface` 1.6.0 源码级不兼容（旧版 record_linux 未实现新版接口要求的 `startStream`/`hasPermission` 新签名），`compileFlutterBuildDebug` 类型检查失败，BUILD FAILED in 52s。属第三方依赖版本冲突，非 lib/ 代码问题（`flutter analyze lib/` 仍通过，3 info 均为 ai_config_selector.dart 既有遗留）。详见 traps.md #25，待后续任务修复（建议 `flutter pub upgrade record` 升级到 7.x 并适配 mic_recorder.dart）
  - **流水线调用链静态审查**（6 条链逐一核对源码 API 匹配）：
    - 录音链：✓ recording_screen → MicRecorder/SpeakerRecorder/DualTrackRecorder API 完全匹配；RecordingSession 创建+insertSession+stop 后 updateSession(copyWith) 闭环正确。**断点**：录音后"转写"/"一键整理"用 `context.push('/transcripts/$sessionId')` 跳转未注册路由，运行时崩溃（traps.md #23）
    - 转写链：✓ TranscriptionService.transcribeSession → RecordingStorage.getSession 取音频路径 → 本地引擎注入 HotwordDictionary.getAllWords → LocalAsrEngine/CloudAsrEngine.transcribe → TranscriptStorage.insertSegments 持久化，全链 API 匹配
    - 声纹链：✓ SpeakerDiarizationService.processSession(sessionId, onProgress) 与编排器调用匹配；sherpa_onnx SpeakerEmbeddingExtractor + 层次聚类 + SpeakerStorage.findBestMatch 跨会话匹配 + updateSpeakerId 回写，全链完整
    - LLM 链：✓ Correction/Translation/Summary/Note 四服务 → LlmTaskRouter.getEngine(taskType) → CloudLlmEngine.generate(SSE 流式)；LocalLlmEngine 未实现返回 null，服务抛 StateError 优雅降级；prompt 模板+结果解析+持久化均完整
    - 编排链：⚠ PipelineOrchestrator.runFullPipeline 内部逻辑正确（6 步顺序+错误处理策略+依赖注入无误），**但从未被任何 UI 调用**，"一键整理"未接线（traps.md #24）
    - 界面调用链：✓ TranscriptScreen 5 个单步操作（转写/纠错/翻译/纪要/笔记）调用各服务签名完全匹配；speaker_screen 经 Navigator.push 正确到达 TranscriptScreen；note 界面 → NoteStorage API 匹配（analyze 佐证）。**断点**：recording_screen → TranscriptScreen 经 GoRouter 未注册路由崩溃
  - **true E2E 测试**：需物理设备 + 已下载 ASR 模型 + 云端 API Key，当前环境无法执行。手动测试步骤清单见验证报告
  - **发现的问题**：3 个（traps.md #23 路由断点 / #24 编排器未接线 / #25 构建依赖冲突），均记录未修复（本任务为验证，修复由后续任务处理）
- **Task 23 主框架与导航**：实现 NOTA 三 tab 底部导航 + 启动初始化
  - **app_router.dart 改造**：StatefulShellRoute.indexedStack 由 2 branch（Home + Settings）改为 3 branch：
    - `/` → RecordingScreen（label '录音'，icon mic_outlined/mic）
    - `/notes` → NoteListScreen（label '笔记'，icon note_outlined/note）
    - `/settings` → SettingsScreen（label '设置'，icon settings_outlined/settings）
    - 保留 `/about` 顶层路由（parentNavigatorKey: _rootNavigatorKey）
    - BottomNavigationBar 3 item 等宽（type: fixed），selectedItemColor 用 AppTheme.accentColor
    - 移除 HomeScreen import（文件保留不删，但路由不再指向它作为 tab，已确认全项目无其他引用）
  - **main.dart 启动初始化**：在 main() 中 runApp 前新增 `await DatabaseHelper().database`（触发 nota.db v1 schema 创建），用 try/catch 包裹，失败仅 debugPrint 警告不阻塞启动
    - API 纠正：任务描述写 `DatabaseHelper.instance.database`，但源码实际是工厂构造 `DatabaseHelper()` + `.database` getter，无 `instance` 静态 getter（见 traps.md #22）
    - AsrModelManager / SpeakerDiarizationService 均无公开 init 方法（前者按需创建模型目录、后者懒加载 extractor 且依赖模型已下载），按"若无 init 则跳过"原则不主动调用
    - 保留 themeModeProvider / ThemeService / ProviderScope / NotaApp 结构不变
  - **验证**：`flutter analyze lib\main.dart lib\routes\app_router.dart` 通过，0 issues；全项目 `flutter analyze` 仅 3 个 info（均在 ai_config_selector.dart，属既有遗留，非本次引入），0 errors / 0 warnings
- **Task 22 设置界面改造 SettingsScreen**：重写 `lib/presentation/settings/settings_screen.dart`，由旧"单一 AI 提供商 + 外观 + 关于"重构为 7 分区
  - **ASR 引擎配置区**：SegmentedButton 切换本地/云端；本地模式展示已下载模型列表（AsrModelManager.getDownloadedModels，图标式点选激活 + 删除确认）+ 未下载模型 ExpansionTile 下载列表（Dio 流式进度 + 首次下载自动激活）；云端模式 baseUrl/apiKey(obscured)/modelName 三输入框（各自 save 图标持久化）；语言下拉 zh/en/multi。AsrConfig 无内置序列化且不可改 services/，故在设置页内联 `_asrConfigToJson/_asrConfigFromJson` 持久化到 SharedPreferences（key `asr_config`，hotwords 运行时注入不持久化）
  - **LLM 按功能配置区**（核心）：4 个 LlmTaskType（translation/summary/noteOrganize/correction）各一个 ExpansionTile，独立配置引擎+提供商+模型+高级参数。SegmentedButton 切本地/云端；云端复用 AiConfigSelector（supportedProviderTypes 排除纯文生图 tongyi/jimeng，onProviderChanged 切换时重置 modelName 为提供商默认）；本地显示"本地 LLM 引擎尚在开发中"提示（LocalLlmEngine 未实现）；高级参数可展开调 maxTokens(512-8192 Slider) / temperature(0-2 Slider)。配置经 LlmTaskRouter.setConfig 持久化
  - **API Key 管理入口**：ListTile 跳 AiRouterScreen（Navigator.push rootNavigator，AiRouterScreen 未注册 GoRouter 路由，沿用 traps.md #18 规律）
  - **录音配置区**：默认录音源下拉 mic/speaker/dual（持久化 key `recording_source`）+ 采样率 16kHz 只读说明（ASR 标准）
  - **管理入口区**：热词→HotwordScreen / 说话人→SpeakerScreen / 数据→DataManagementScreen（均 Navigator.push，三界面由并行子代理创建，已就绪）
  - **外观区**（沿用原实现）：深浅色 + 5 主题色
  - **关于区**：package_info_plus 读版本号 + MIT 协议，点击跳 /about（AboutScreen 已注册路由）
  - 移除旧"AI 提供商"全局配置区（provider/url/model/apikey/连通测试/上下文长度）——被按功能 LLM 配置 + AiRouterScreen 取代；aiConfigProvider 仅本文件引用，移除其 UI 不影响其他模块
  - **验证**：`flutter analyze lib\presentation\settings\settings_screen.dart` 通过，0 issues（Radio 弃用改图标式选择，见 traps.md #21）
- **Task 21b 热词词库界面**：实现热词分组/词条可视化管理（`lib/presentation/hotwords/hotword_screen.dart`）
  - HotwordScreen（StatefulWidget + setState + FutureBuilder 式手动 _isLoading，与 NoteListScreen 风格一致）
  - AppBar 右侧 PopupMenu：批量导入 / 导出全部 / 新建分组
  - 分组卡片（Card + 自定义可展开头，非 ExpansionTile 以便右侧放 PopupMenu）：折叠箭头 + folder 图标 + 分组名 + 词条数 + 右侧 PopupMenu（重命名 / 删除[确认弹窗，提示将级联删除词条数]）
  - 展开后词条列表：ListTile（tag 图标 + 词文本 + 权重 chip"×1.0"，权重≠1.0 时高亮 accent 色）+ Dismissible 右滑删除（无确认，删除后 SnackBar 反馈，失败自动重载恢复）+ 点击编辑对话框（词/权重，权重 double.tryParse 校验 + clamp 1.0-10.0）+ 底部"添加词条"TextButton
  - 词条编辑：HotwordStorage 未提供 updateEntry，用 delete + insert 等价实现（见 traps.md #20）
  - 批量导入对话框（_ImportDialog StatefulWidget）：DropdownButtonFormField 选目标分组（含"➕ 新建分组"项，选新建时显示名称输入框）+ 多行 TextField 粘贴文本 + ValueListenableBuilder 实时显示识别条数（解析逻辑复用 HotwordStorage.importFromText 的"词,权重"格式）
  - 导出：FilePicker.getDirectoryPath 选目录 → DataManager.exportHotwordsAsText 落盘 hotwords.txt；用户取消则中止，getDirectoryPath 异常时回退到应用文档目录 exports/
  - 空状态：无分组时 library_books 图标 + 引导文案 + "新建分组"FilledButton
  - **验证**：`flutter analyze lib/presentation/hotwords/hotword_screen.dart` 通过，0 errors / 0 warnings / 0 info
- **Task 21d 数据管理界面**：实现 DataManagementScreen（`lib/presentation/data/data_management_screen.dart`）
  - 四大分区：存储用量统计 / 导入 / 导出 / 清理缓存（StatefulWidget + FutureBuilder + setState）
  - 存储统计卡片：FutureBuilder 调 DataManager.getStorageUsage()，显示总占用（30px 粗体大字）+ 三分类（会话音频/ASR 模型/缓存）LinearProgressIndicator 占比条（色点 + 标签 + formatBytes 字节数 + ClipRRect 圆角进度条）
  - 导入区 4 项 ListTile：导入音频（file_picker FileType.custom wav/mp3/m4a → importAudioFile）/ 导入笔记 .md（→ importNotesFromMarkdown）/ 导入热词 .txt（→ importHotwordsFromText）/ 导入说话人配置 json（→ importSpeakerConfig），每项 SnackBar 反馈结果与数量
  - 导出区 4 项 ListTile：按会话导出 zip（会话选择对话框 → exportSessionAsZip）/ 导出笔记 .md（笔记选择对话框 → exportNoteAsMarkdown，传 noteId 字符串）/ 导出热词（exportHotwordsAsText）/ 全量备份（exportAllAsBackup），导出到 {docsDir}/exports/，SnackBar 显示保存路径
  - 清理区：扫描孤立文件（scanOrphanFiles + 本地 _dirSize 递归估算可清理字节，因 DataManager 未暴露按路径计大小公开方法）→ ListTile 显示可清理大小 → 确认对话框 → 执行清理（cleanOrphanFiles）→ SnackBar 显示已释放空间
  - 长操作统一 _runWithProgress：弹不可关闭 PopScope 进度对话框（CircularProgressIndicator + 文案），完成后关闭并按结果 SnackBar 反馈成功/失败（task 返回成功消息字符串，catch 异常转失败消息）
  - 导出"打开目录"按钮未实现：open_file 包未在 pubspec 且任务约束不改 pubspec，仅 SnackBar 展示完整路径（任务允许"如可能"）
  - 已知限制：DataManager._modelsRootPath 扫描 `models/` 目录，而 AsrModelManager 实际用 `asr_models/`，导致存储统计的"ASR 模型"分类读数恒为 0（详见 traps.md #19）
  - **验证**：`flutter analyze lib/presentation/data/data_management_screen.dart` 通过，No issues found
- **Task 21 笔记界面**：实现笔记列表 + 详情两个界面（`lib/presentation/notes/`）
  - `note_list_screen.dart`：NoteListScreen（StatefulWidget）
    - 顶部搜索栏（350ms 防抖，调 NoteStorage.searchNotes，匹配 title/content/tags）
    - 分类筛选 FilterChip：全部 / 笔记（NoteType.note）/ 纪要（NoteType.summary）
    - 笔记卡片列表：左侧分类色条（笔记=蓝 #4A90D9 / 纪要=绿 #52A373 / 待办=橙 #E0A23C）+ 标题 + 分类标签 + 创建时间 + 正文预览（去 Markdown 标记截前 100 字）+ 标签 chips
    - 排序：isPinned 置顶在前，其余 createdAt 倒序（在 NoteStorage.getNotes 的 updated_at DESC 基础上 Dart 侧二次排序）
    - 点击卡片 → Navigator.push 跳 NoteDetailScreen（rootNavigator 全屏，未注册路由故用 Navigator 而非 GoRouter，详见 traps.md #18）
    - 长按卡片 → BottomSheet 菜单：置顶/取消置顶（togglePin）、导出为 .md（写应用文档目录 exports/）、删除（确认对话框 → deleteNote）
    - 空状态：暂无笔记 + 引导文字（区分无笔记 / 无搜索结果两种文案）
  - `note_detail_screen.dart`：NoteDetailScreen（StatefulWidget，接收 noteId）
    - Markdown 渲染（flutter_markdown 0.6.18）：标题/列表/表格/引用块/代码块/加粗/斜体/分隔线，自定义 MarkdownStyleSheet（blockquote 左色条 + 代码块圆角背景 + 表格边框，随深浅色适配）
    - 可交互 checklist：按行解析 `- [ ]`/`- [x]`（支持 `-`/`*`/`+` 与缩进），checklist 行渲染为 InkWell + Checkbox Icon，点击切换 `[ ]`↔`[x]` 并调 NoteStorage.updateNote 持久化（updatedAt 刷新）；非 checklist 行分组用 MarkdownBody 渲染，已勾选项加 lineThrough + 次要色
    - 编辑模式切换：AppBar 右上角 edit/visibility 图标；编辑模式上下分屏（Expanded flex 2:3 = 编辑区 40% + 预览区 60%），TextField 实时编辑 Markdown 源码 + 下方 MarkdownBody 实时预览，退出编辑时若内容变化自动持久化
    - 导出：导出为 .md（写应用文档目录 exports/{title}.md）+ 复制到剪贴板（Clipboard.setData），均含 SnackBar 反馈
    - 关联跳转：sessionId 非空时菜单显示"查看转写"项（TranscriptScreen 未实现，点击提示"转写界面开发中"，详见 traps.md #18）
  - **验证**：`flutter analyze lib/presentation/notes/` 通过，0 issues
- **Task 17 流水线编排器**：实现 PipelineOrchestrator 单例，串联"录音→转写→声纹区分→纠错→翻译→纪要→笔记"端到端全流程
  - `lib/services/pipeline/pipeline_orchestrator.dart`：PipelineOrchestrator 单例 + PipelineStep 枚举 + PipelineConfig + PipelineResult
    - **PipelineStep 枚举**：transcription / speakerDiarization / correction / translation / summary / noteOrganize（按依赖顺序）
    - **PipelineConfig**：transcribeConfig(AsrConfig?) / enableSpeakerDiarization(true) / enableCorrection(true) / enableTranslation(false) / translationTargetLang('en') / enableSummary(true) / enableNoteOrganize(true)，含 defaultConfig 静态常量
    - **PipelineResult**：sessionId + segments(List<TranscriptSegment>) + notes(List<Note>) + errors(Map<PipelineStep,String>) + completedSteps(Set<PipelineStep>) + isSuccess getter + copyWith
    - **runFullPipeline**：按 config 依次执行 6 步，每步通过 onStepProgress(step, 0.0-1.0) 回调进度、onLog 回调日志；某步失败记录到 errors 并按策略决定是否继续
    - **runStep**：分步执行单个步骤，返回 PipelineResult（段落类步骤填充 segments，笔记类步骤填充 notes）
    - **错误处理策略**：转写失败→终止流水线（基础步骤）；声纹失败→跳过继续纠错；纠错失败→继续翻译用原文；翻译失败→继续纪要；纪要失败→继续笔记；笔记失败→记录错误
    - **私有委托方法**：_transcribe→TranscriptionService / _diarize→SpeakerDiarizationService(try-catch 返回 null 跳过) / _correct→CorrectionService / _translate→TranslationService / _summarize→SummaryService / _organizeNote→NoteService
    - 依赖 SpeakerDiarizationService（Task 17b 并行实现，已就绪，processSession 接口匹配）
  - **验证**：`flutter analyze lib/services/pipeline/pipeline_orchestrator.dart` 通过，0 issues
- **Task 18b 统一数据管理器**：实现 DataManager 单例，覆盖文件导入/导出/删除/清理/统计全生命周期
  - `lib/services/storage/data_manager.dart`：DataManager 单例 + StorageUsage 辅助类
    - **导入**：importAudioFile（外部音频→会话目录+SQLite记录）/ importNotesFromMarkdown（.md→Note，首行 `# 标题` 提取）/ importHotwordsFromText（.txt→新建分组+批量词条）/ importSpeakerConfig（JSON→SpeakerProfile，embedding 支持数组或 JSON 字符串）
    - **导出**：exportSessionAsZip（会话目录文件+转写JSON+笔记MD+元信息→zip）/ exportNoteAsMarkdown（Note→.md）/ exportHotwordsAsText（→hotwords.txt）/ exportAllAsBackup（全部会话+笔记+热词→backup_{timestamp}.zip）
    - **级联删除**：cascadeDeleteSession（删目录文件→删转写→删笔记 SQL→删会话记录，返回文件数）
    - **存储清理**：scanOrphanFiles（recordings/ 下无 DB 记录的目录）/ cleanOrphanFiles / scanModelCache（models/ 目录）/ cleanModelCache
    - **用量统计**：getStorageUsage（sessionsSize+modelsSize+cacheSize→StorageUsage，含 formatBytes 静态方法 B/KB/MB/GB 格式化）
    - 依赖 archive 3.6.1（Archive+ArchiveFile+ZipEncoder）、path_provider（models/cache 目录）、sqflite（getDatabasesPath 定位 recordings 根目录，与 RecordingStorage 一致）
  - **验证**：`flutter analyze lib/services/storage/data_manager.dart` 通过，0 errors, 0 warnings
- **Task 18 数据存储层**：实现 SQLite 持久化基础，为录音/转写/笔记/声纹/热词提供统一存储
  - **数据模型（lib/models/）**：5 个模型文件
    - `recording_session.dart`：RecordingSession + RecordingSource 枚举（id/title/时间/来源/音频路径/置顶），toMap/fromMap/encode/decode
    - `transcript.dart`：TranscriptSegment（统一模型，含存储字段 id/sessionId/double 秒时间戳/originalText/correctedText/translation + 兼容 ASR 引擎的 getter text/speaker/startDuration/startMs/hasSpeaker）+ Transcript 聚合类
    - `note.dart`：Note + NoteType 枚举，tags 存为 JSON 文本
    - `speaker_profile.dart`：SpeakerProfile，embedding 存为 JSON 文本
    - `hotword.dart`：HotwordGroup + HotwordEntry（weight 1.0-10.0）
  - **数据库（lib/services/storage/database_helper.dart）**：单例 + sqflite，nota.db v1，6 张表（sessions/transcripts/notes/speakers/hotword_groups/hotwords），batch 建表，预留 onUpgrade 迁移
  - **存储类（5 个，均单例）**：
    - `recording_storage.dart`：会话 CRUD + togglePin/updateTitle + 会话目录创建（recordings/{YYYYMMDD_HHmmss}_{title}/，非法字符替换）
    - `transcript_storage.dart`：段落 CRUD + 批量插入（batch）+ 按 sessionId 查询排序 + 单字段更新（纠错/译文/说话人）
    - `note_storage.dart`：笔记 CRUD + togglePin + 搜索（title/content/tags LIKE）+ 按分类/标签查询（tags JSON LIKE 近似匹配）
    - `speaker_storage.dart`：声纹 CRUD + incrementSessionCount + findBestMatch（余弦相似度 a·b/(|a|·|b|)，超阈值返回最佳匹配）
    - `hotword_storage.dart`：分组/词条 CRUD + 级联删除（batch）+ exportAsText（权重非 1.0 写 "词,权重"）+ importFromText（解析每行词或 "词,权重"，批量导入）
  - **类型冲突修复**：lib/models/transcript.dart 被并行 Task 7 写入简化版 TranscriptSegment（Duration 时间/text 字段/无 toMap），与存储层不兼容。重写为统一模型：保留 Task 18 存储字段 + 添加兼容 getter 供 asr_engine.dart 使用（详见 traps.md #16）
- **Task 7 ASR 引擎抽象接口**：定义本地/云端 ASR 统一调用契约
  - `lib/services/asr/asr_engine.dart`：AsrEngineType 枚举（local/cloud）+ AsrConfig 配置类（engineType/modelName/language/baseUrl/apiKey/hotwords/enableTimestamps，含 copyWith）+ AsrEngine 抽象类（engineType/isReady getter + init/transcribe/dispose，transcribe 支持 onProgress + onSegment 流式回调，返回 List<TranscriptSegment>）
  - `lib/services/asr/asr_model_info.dart`：AsrModelInfo 数据类（id/displayName/downloadUrl/sizeBytes/language/supportsHotwords/description + sizeMb getter）+ AsrModels 预置模型清单（whisper-medium 769M / whisper-large-v3-turbo 809M / paraformer-zh 220M 支持热词，getById 查询）
  - TranscriptSegment 数据类由 Task 18 统一实现（见上），asr_engine.dart 仅作类型引用
- **Task 10 LLM 引擎抽象接口**：定义本地/云端 LLM 统一调用契约
  - `lib/services/llm/llm_engine.dart`：LlmEngineType 枚举（local/cloud）+ LlmTaskType 枚举（translation/summary/noteOrganize/correction）+ LlmConfig 配置类（engineType/providerName/modelName/customUrl/maxTokens/temperature，含 toJson/fromJson/copyWith）+ LlmEngine 抽象类（engineType/isReady getter + init/generate/dispose，generate 支持 onToken 流式 + onComplete + onError 回调）
- **Task 9b 热词管理服务接口**：外挂热词词库中介层
  - `lib/services/asr/hotword_dictionary.dart`：HotwordDictionary 单例，依赖 HotwordStorage（Task 18 已创建），提供 getAllWords（扁平词列表，ASR 注入）/ getWeightedWords（带权重键值对，boosting 模型）/ getHotwordTextForPrompt（拼接为 LLM 纠错参考词表文本）
- **Task 12b LLM 任务路由器接口**：按功能独立配置 LLM 引擎与模型
  - `lib/services/llm/llm_task_router.dart`：LlmTaskRouter 单例，getConfig/setConfig 读写 SharedPreferences（key: `llm_task_<taskType>`，JSON 序列化 LlmConfig），_defaultConfig 默认走云端（maxTokens=4096, temperature=0.3），getEngine 暂返回 null + TODO 注释（待 Task 11/12 引擎实现后补充 LocalLlmEngine / CloudLlmEngine 路由）
- **验证**：`flutter analyze` 通过，无 error / 无 warning，仅 3 个 info 级 lint（ai_config_selector.dart 既有 deprecated value + unnecessary_underscores，非本次引入）

- **Task 4 麦克风录音 MicRecorder**：`lib/services/audio/mic_recorder.dart`
  - 基于 `record` 5.2.1（^5.1.0）的 `AudioRecorder` + `RecordConfig` API（5.x 起 Record 类改为 AudioRecorder，配置走 RecordConfig 常量）
  - 输出 16kHz / 单声道 / WAV（AudioEncoder.wav + bitRate 256000），ASR 标准输入
  - permission_handler 请求 RECORD_AUDIO；start(sessionDir)→mic.wav，stop 返回路径，cancel 删文件，dispose 释放
- **Task 5 扬声器内录 SpeakerRecorder**：Dart + Android 原生双端
  - Dart 端 `lib/services/audio/speaker_recorder.dart`：MethodChannel `nota/audio_capture`，isAvailable/start/stop/cancel，低于 Android 10 返回 false
  - Kotlin 端 `android/app/src/main/kotlin/com/vitasguo/nota/MainActivity.kt`：MethodChannel 三方法（startCapture/stopCapture/isCaptureAvailable）+ MediaProjection 授权（onActivityResult）+ AudioPlaybackCaptureConfiguration（USAGE_MEDIA+USAGE_GAME，CAPTURE_MODE_ALL）+ AudioRecord 录制线程 + WAV 写入（先占位 header，停止后 RandomAccessFile 回填 RIFF/data 大小）
  - AndroidManifest 新增 FOREGROUND_SERVICE + FOREGROUND_SERVICE_MEDIA_PLAYBACK 权限
  - 已知限制：Android 14+ MediaProjection 需前台服务（mediaProjection 类型），当前未实现，待后续补齐
- **Task 6 双轨录音 DualTrackRecorder**：`lib/services/audio/dual_track_recorder.dart`
  - 组合 MicRecorder + SpeakerRecorder，Future.wait 并行启动，任一成功即 _isRecording=true
  - 早返回守卫需用 `this.micPath`/`this.speakerPath` 绕过局部变量遮蔽（见 traps.md #17）
- **音频模块验证**：`flutter analyze lib/services/audio/` 0 issues；全项目 analyze 无 error，剩余 7 个 warning/info 均在既有其他模块（hotword/hotword_dictionary/llm_task_router/note/ai_config_selector，非音频任务引入）

### v0.2.0 (2026-07-09)
- **模块瘦身**：移除 xiaop 遗留的对话/人格/记忆/TTS/工具/搜索/STT 模块，NOTA 聚焦录音→转写→笔记
  - 删除目录：`presentation/chat/`、`presentation/personality/`、`presentation/memory/`、`services/tools/`
  - 删除 services：chat_service / personality_service / memory_service / memory_extractor / tts_service / stt_service / web_search_service
  - 删除 models：chat_message / companion / conversation / memory_entry
  - 删除 providers：companion_providers
  - 删除 widgets：chat_bubble / companion_avatar / voice_button（均仅被已删除页面使用）
  - 清理废弃代码：`core/dio_client.dart`、`utils/logger.dart`（原被已删除模块使用，瘦身后无引用）
- **清理引用**：
  - `main.dart`：移除 ToolRegistry import 与 `registerBuiltin()` 调用；类名 XiaoPApp→NotaApp；MaterialApp title '小P'→'NOTA'
  - `routes/app_router.dart`：移除 chat/personality/memory 路由与对话 tab，保留主页/设置/关于
  - `presentation/home/home_screen.dart`：移除 companion/avatar/人格/记忆入口，改为 NOTA 占位首页
  - `presentation/settings/settings_screen.dart`：移除工具管理、TTS、联网搜索相关 UI 与逻辑（保留 AI 配置/连通测试/上下文长度/主题/关于）
  - `presentation/settings/about_screen.dart`：更新为 NOTA 定位（名称/描述/功能特性/技术栈），移除已删除模块的 feature 描述
- **清理 pubspec.yaml**：移除 `speech_to_text` / `flutter_tts` / `expressions` / `geolocator` 四个不再需要的依赖（及 19 个传递依赖）；版本号 0.1.0+1 → 0.2.0+1
- **建立 NOTA 目录结构**：新建 `services/audio`、`services/asr`、`services/pipeline`、`services/storage`、`presentation/recording`、`presentation/transcripts`、`presentation/notes` 七个规划目录（`services/llm` 已存在）
- **验证**：`flutter pub get` 通过（剩余 78 依赖）+ `flutter analyze` 通过，仅 3 个 info 级 lint（ai_config_selector.dart 既有的 deprecated `value` + unnecessary_underscores，非本次引入），无 error / 无 warning

### v0.1.0 (2026-07-09)
- **项目初始化脚手架**：从 xiaop v1.4.1 派生，重命名为 NOTA
  - pubspec: name `xiao_p`→`nota`，description 改为 NOTA 笔记定位，version 重置为 `0.1.0+1`
  - Android 包名 `com.vitasguo.xiao_p`→`com.vitasguo.nota`：build.gradle.kts 的 namespace/applicationId、MainActivity.kt 移动到 `kotlin/com/vitasguo/nota/` 并改 package 声明、AndroidManifest label 改为 "NOTA"
  - 全局 import 路径 `package:xiao_p/`→`package:nota/`（28 个 dart 文件，用 .NET UTF8 no-Bom 方法替换，规避 PowerShell 编码问题，见 traps.md #8）
- **集成 ai_router_module v2.0.0**：作为统一 LLM 层
  - 新增 `lib/services/llm/` 目录，放入 ai_providers.dart / ai_router_service.dart / api_key_service.dart（ai_router 版本，覆盖 xiaop 旧版）
  - 覆盖 `lib/providers/ai_config_provider.dart`（ai_router 版本，AiConfig 按 provider 独立持久化 model/url）
  - 新增 `lib/presentation/settings/ai_router_screen.dart`（AI Router 管理页）+ `lib/presentation/widgets/ai_config_selector.dart`（模型选择器组件）
  - import 精确映射：`package:ai_router/services/`→`package:nota/services/llm/`，其余 `package:ai_router/`→`package:nota/`（见 traps.md #14）
  - 去重：删除 xiaop 旧版 `lib/services/ai_providers.dart` + `lib/services/api_key_service.dart`，4 个引用文件重定向到 llm/ 版本（新版是旧版超集，见 traps.md #15）
- **验证**：`flutter pub get`（97 依赖，用 Flutter 中国镜像）+ `flutter analyze` 通过，仅 3 个 info 级 lint（ai_config_selector.dart 既有的 deprecated `value` + unnecessary_underscores，非迁移引入），无编译错误

## 已知问题
- ai_router_module 自带的 `ai_config_selector.dart` 有 2 处 deprecated `DropdownButtonFormField.value`（Flutter 3.33+ 弃用，建议改 `initialValue`）+ 1 处 unnecessary_underscores，属范围外既有问题（traps.md 无变更）
- Task 18/18b 数据存储层 + Task 7/10/9b/12b 接口层 + Task 4-6 音频采集模块 + Task 17 流水线编排器 + Task 21 笔记界面 + Task 21d 数据管理界面已完成（v0.3.0）；ASR 引擎实现（Task 8-9）/ LLM 引擎实现（Task 11-12）模块待开发
- DataManager 模型目录 `models/` 与 AsrModelManager 实际目录 `asr_models/` 不一致，导致存储统计"ASR 模型"分类恒为 0（详见 traps.md #19，待服务层统一）
- `lib/services/asr/hotword_dictionary.dart` 与 `lib/models/hotword.dart` 有 unused import 警告、`lib/services/llm/llm_task_router.dart` 有 unused local variable 警告（属其他并行任务遗留，非音频任务引入）
- SpeakerRecorder 在 Android 14+ 需前台服务（mediaProjection 类型）才能获取 MediaProjection，当前未实现前台服务，待后续补齐
- Task 24 验证发现 3 个问题：①recording_screen 用未注册的 GoRouter 路由跳转 TranscriptScreen，运行时崩溃（traps.md #23，**v0.4.2 已修复**）；②PipelineOrchestrator 从未被 UI 调用，"一键整理"全流水线未接线（traps.md #24，**v0.4.2 已修复**）；③record_linux 0.7.2 与 record_platform_interface 1.6.0 版本不兼容导致 APK 构建失败（traps.md #25，**v0.4.1 已修复**）；④修复 #25 后暴露 MainActivity.kt Kotlin 编译错误（traps.md #26，**v0.4.1 已修复**）
- Task 24 验证补充：ASR 引擎实现（LocalAsrEngine/CloudAsrEngine）、LLM 云端引擎（CloudLlmEngine）、流水线各服务（Transcription/SpeakerDiarization/Correction/Translation/Summary/Note）均已实现且 API 调用链完整无断引用（与 README 中"ASR/LLM 引擎具体实现待开发"的旧描述不符，README 待后续同步更新）
