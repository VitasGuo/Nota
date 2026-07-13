// whisper_wrapper.c — 简化 whisper.cpp C API 供 Dart FFI 调用
//
// 提供 3 个简化函数 + 1 个结构体，避免在 Dart 侧定义复杂的
// whisper_full_params（含回调指针、嵌套结构体等）。
//
// 通信协议：
// 1. whisper_simple_init(model_path) → ctx 指针
// 2. whisper_simple_transcribe(ctx, samples, n, lang, threads, segs, max) → 段数
// 3. whisper_simple_free(ctx)

#include <whisper.h>
#include <stdbool.h>

// 简化的转写段结构体（Dart FFI 可直接映射）
typedef struct {
    const char* text;   // 段文本（指向 ctx 内部内存，ctx free 后失效）
    int64_t t0;         // 起始时间（厘秒 = 10ms）
    int64_t t1;         // 结束时间（厘秒 = 10ms）
} whisper_simple_segment;

// 初始化模型（CPU only）
struct whisper_context* whisper_simple_init(const char* model_path) {
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = false;
    return whisper_init_from_file_with_params(model_path, cparams);
}

// 转写音频段
// 返回段数（>0=成功，<0=失败）
int whisper_simple_transcribe(
    struct whisper_context* ctx,
    const float* samples,
    int n_samples,
    const char* language,       // "auto"/"zh"/"en"/"ja"/"ko" 等
    int n_threads,
    whisper_simple_segment* out_segments,
    int max_segments
) {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = n_threads;
    params.language = language;
    params.translate = false;
    params.no_timestamps = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.no_context = true;
    params.single_segment = false;
    params.suppress_blank = true;

    int ret = whisper_full(ctx, params, samples, n_samples);
    if (ret != 0) return -ret;

    int n_segments = whisper_full_n_segments(ctx);
    if (n_segments > max_segments) n_segments = max_segments;

    for (int i = 0; i < n_segments; i++) {
        out_segments[i].text = whisper_full_get_segment_text(ctx, i);
        out_segments[i].t0 = whisper_full_get_segment_t0(ctx, i);
        out_segments[i].t1 = whisper_full_get_segment_t1(ctx, i);
    }

    return n_segments;
}

// 释放模型
void whisper_simple_free(struct whisper_context* ctx) {
    whisper_free(ctx);
}
