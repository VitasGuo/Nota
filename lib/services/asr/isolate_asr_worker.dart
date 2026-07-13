// lib/services/asr/isolate_asr_worker.dart
//
// 持久化 worker Isolate 封装：在独立 Isolate 中执行 llama.cpp ASR 推理，
// 避免同步 FFI 调用阻塞主 isolate 导致 ANR/crash（traps.md #37/#45）。
//
// 工作流程：
// 1. [spawn] 启动 worker Isolate，在 worker 内加载 GGUF ASR 模型
// 2. [transcribe] 通过 SendPort 发送音频段到 worker，await 结果
// 3. [dispose] 发送退出命令，worker 释放模型并退出
//
// 通信协议（Map 消息）：
// - 主→worker：{'cmd': 'load'|'transcribe'|'dispose', ...}
// - worker→主：{'loaded': bool} / {'id': int, 'text': String} /
//   {'id': int, 'error': String} / {'disposed': true}

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nota/services/llm/llama_cpp_engine.dart';

/// 在独立 Isolate 中运行 llama.cpp ASR 推理的持久化 worker。
///
/// 解决 [LlamaCppEngine.transcribeAudio] 同步 FFI 阻塞主线程的问题：
/// 将模型加载和推理移到 worker Isolate，主 Isolate 仅通过 SendPort
/// 发送音频段并 await 结果，不阻塞 UI 线程。
///
/// 生命周期：[spawn]（加载模型）→ 多次 [transcribe] → [dispose]（释放）。
/// worker Isolate 在 [spawn] 时创建，[dispose] 时销毁，期间复用同一份
/// 模型（避免每次转写重新加载 GB 级模型）。
class IsolateAsrWorker {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  StreamSubscription? _sub;
  bool _disposed = false;
  bool _ready = false;

  int _nextId = 0;
  final Map<int, Completer<String>> _pending = {};

  /// 启动 worker Isolate 并加载 ASR 模型。
  ///
  /// [mainPath] 主模型 GGUF 路径
  /// [mmprojPath] 音频投影器 GGUF 路径
  /// [nCtx] 上下文长度（默认 4096）
  /// [nThreads] 推理线程数（默认 4）
  ///
  /// 返回后 worker 已就绪，可调用 [transcribe]。
  Future<void> spawn(
    String mainPath,
    String mmprojPath, {
    int nCtx = 4096,
    int nThreads = 4,
  }) async {
    if (_disposed) throw StateError('IsolateAsrWorker 已释放');
    if (_isolate != null) throw StateError('worker 已启动');

    _fromWorker = ReceivePort();
    _isolate = await Isolate.spawn(
      _workerEntry,
      _fromWorker!.sendPort,
      debugName: 'asr-worker',
    );

    final readyCompleter = Completer<void>();

    _sub = _fromWorker!.listen((msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        return;
      }
      if (msg is Map) {
        if (msg.containsKey('loaded')) {
          if (msg['loaded'] == true) {
            _ready = true;
            readyCompleter.complete();
          } else {
            readyCompleter.completeError(
              StateError('ASR 模型加载失败: ${msg['error']}'),
            );
          }
          return;
        }
        final id = msg['id'];
        if (id is int) {
          final c = _pending.remove(id);
          if (c != null) {
            if (msg.containsKey('error')) {
              c.completeError(StateError('${msg['error']}'));
            } else {
              c.complete(msg['text'] ?? '');
            }
          }
        }
      }
    });

    // 等待 worker 发回它的 SendPort
    while (_toWorker == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    // 发送加载命令
    _toWorker!.send({
      'cmd': 'load',
      'mainPath': mainPath,
      'mmprojPath': mmprojPath,
      'nCtx': nCtx,
      'nThreads': nThreads,
    });

    await readyCompleter.future;
  }

  /// worker 是否已就绪（模型已加载）。
  bool get isReady => _ready && !_disposed;

  /// 转写音频段。
  ///
  /// [samples] PCM F32 单声道 16kHz 音频数据（归一化到 [-1.0, 1.0]）
  /// 返回转写文本。
  Future<String> transcribe(Float32List samples) async {
    if (_disposed || _toWorker == null || !_ready) {
      throw StateError('worker 未启动或已释放');
    }

    final id = _nextId++;
    final completer = Completer<String>();
    _pending[id] = completer;

    _toWorker!.send({
      'cmd': 'transcribe',
      'id': id,
      'samples': samples,
    });

    return completer.future;
  }

  /// 释放 worker Isolate。
  ///
  /// 发送 dispose 命令让 worker 释放模型，然后关闭 Isolate。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;

    // 通知所有 pending 请求失败
    for (final c in _pending.values) {
      c.completeError(StateError('worker 已释放'));
    }
    _pending.clear();

    _toWorker?.send({'cmd': 'dispose'});
    // 给 worker 时间清理模型资源
    await Future<void>.delayed(const Duration(milliseconds: 100));

    _sub?.cancel();
    _fromWorker?.close();
    _isolate?.kill(priority: Isolate.immediate);

    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _sub = null;
  }

  /// worker Isolate 入口。
  ///
  /// 在独立 Isolate 中运行，接收主 Isolate 的命令并执行 llama.cpp ASR 推理。
  /// 模型在 'load' 命令时加载，后续 'transcribe' 命令复用同一模型实例。
  static void _workerEntry(SendPort toMain) {
    final fromMain = ReceivePort();
    toMain.send(fromMain.sendPort);

    LlamaCppEngine? engine;

    fromMain.listen((msg) {
      if (msg is! Map) return;

      switch (msg['cmd']) {
        case 'load':
          _handleLoad(toMain, msg, (e) => engine = e);
        case 'transcribe':
          _handleTranscribe(toMain, msg, () => engine);
        case 'dispose':
          engine?.dispose();
          fromMain.close();
          Isolate.exit();
      }
    });
  }

  /// 处理 'load' 命令：在 worker 内创建 LlamaCppEngine 并加载 ASR 模型。
  static void _handleLoad(
    SendPort toMain,
    Map msg,
    void Function(LlamaCppEngine) setEngine,
  ) {
    try {
      final engine = LlamaCppEngine();
      engine
          .loadAsrModel(
            msg['mainPath'] as String,
            msg['mmprojPath'] as String,
            nCtx: msg['nCtx'] as int,
            nThreads: msg['nThreads'] as int,
          )
          .then((_) {
        setEngine(engine);
        toMain.send({'loaded': true});
      }).catchError((e) {
        toMain.send({'loaded': false, 'error': e.toString()});
      });
    } catch (e) {
      toMain.send({'loaded': false, 'error': e.toString()});
    }
  }

  /// 处理 'transcribe' 命令：调用 engine.transcribeAudio 并返回结果。
  static void _handleTranscribe(
    SendPort toMain,
    Map msg,
    LlamaCppEngine? Function() getEngine,
  ) {
    final engine = getEngine();
    if (engine == null || !engine.isAsrModelLoaded) {
      toMain.send({'id': msg['id'], 'error': '模型未加载'});
      return;
    }
    try {
      final samples = msg['samples'] as Float32List;
      final text = engine.transcribeAudio(samples);
      toMain.send({'id': msg['id'], 'text': text});
    } catch (e) {
      toMain.send({'id': msg['id'], 'error': e.toString()});
    }
  }
}
