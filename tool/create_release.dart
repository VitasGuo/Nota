// tool/create_release.dart
//
// 创建 GitHub Release 并上传 release APK。
// 从 GCM (git credential fill) 提取 token，调用 GitHub REST API。
//
// 用法：dart run tool/create_release.dart

import 'dart:convert';
import 'dart:io';

const repo = 'VitasGuo/Nota';
const tag = 'v0.8.1';
const releaseName = 'v0.8.1 - Note with ASR 私人 AI 笔记软件';
const apkPath = 'build/app/outputs/flutter-apk/app-release.apk';

const releaseNotes = '''# NOTA v0.8.1 - Note with ASR

基于 Flutter 的私人 AI 笔记软件，集成 ai_router_module 统一管理多 AI 平台，聚焦"录音-转写-笔记"场景。

## 核心功能
- 实时 ASR 转写：麦克风 PCM16 流 -> VAD 分段 -> 本地 ASR 实时转写
- 三引擎架构：sherpa-onnx (SenseVoice/Paraformer/Whisper) + Qwen3-ASR GGUF (llama.cpp mtmd) + 云端 Whisper API
- ModelScope (魔搭社区) 下载源：国内网络最友好的模型下载方式
- LLM 引擎：云端 SSE 流式 + 本地 llama.cpp FFI GGUF 推理
- SQLite 持久化 + 完整导入导出
- 完整界面：实时转写录音/转写/笔记/热词/说话人/数据管理/设置 7 分区

## v0.8.1 修复
- 修复 stream 重复订阅导致"already been listened to"启动失败
- 修复启动失败后状态残留无法重试
- 修复 GGUF ASR 同步 FFI 阻塞主线程导致闪退
- 调整引擎优先级：sherpa-onnx (SenseVoice > Paraformer) > GGUF ASR > 云端

## 使用方法
1. 安装 app-release.apk
2. 在设置中下载 ASR 模型（推荐 SenseVoice ~239MB，从魔搭社区下载）
3. 开始录音，实时转写

## License
MIT
''';

Future<String> getToken() async {
  final process = await Process.start('git', ['credential', 'fill']);
  process.stdin.writeln('protocol=https');
  process.stdin.writeln('host=github.com');
  process.stdin.writeln('');
  await process.stdin.close();

  final output = await process.stdout.transform(systemEncoding.decoder).join();
  final err = await process.stderr.transform(systemEncoding.decoder).join();
  final exitCode = await process.exitCode;

  for (final line in output.split('\n')) {
    if (line.startsWith('password=')) {
      return line.substring(9).trim();
    }
  }
  throw Exception('获取 token 失败 (exit=$exitCode)\nSTDOUT: $output\nSTDERR: $err');
}

Future<int> createRelease(String token) async {
  final client = HttpClient();
  final request = await client.postUrl(
    Uri.parse('https://api.github.com/repos/$repo/releases'),
  );
  request.headers.set('Authorization', 'Bearer $token');
  request.headers.set('Accept', 'application/vnd.github+json');
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode({
    'tag_name': tag,
    'name': releaseName,
    'body': releaseNotes,
    'draft': false,
    'prerelease': false,
  }));

  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();

  if (response.statusCode != 201) {
    throw Exception('创建 release 失败: ${response.statusCode}\n$body');
  }

  final json = jsonDecode(body) as Map<String, dynamic>;
  final id = json['id'] as int;
  print('Release 创建成功: id=$id, html_url=${json['html_url']}');
  client.close();
  return id;
}

Future<void> uploadAsset(String token, int releaseId) async {
  final file = File(apkPath);
  if (!await file.exists()) {
    throw Exception('APK 文件不存在: $apkPath');
  }
  final fileSize = await file.length();
  print('上传 APK: $apkPath (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)...');

  final client = HttpClient();
  final request = await client.postUrl(
    Uri.parse('https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=app-release.apk'),
  );
  request.headers.set('Authorization', 'Bearer $token');
  request.headers.set('Accept', 'application/vnd.github+json');
  request.headers.contentType = ContentType.parse('application/vnd.android.package-archive');
  request.headers.contentLength = fileSize;

  await request.addStream(file.openRead());
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();

  if (response.statusCode != 201) {
    throw Exception('上传 APK 失败: ${response.statusCode}\n$body');
  }

  final json = jsonDecode(body) as Map<String, dynamic>;
  print('APK 上传成功: ${json['browser_download_url']}');
  client.close();
}

void main() async {
  try {
    stdout.writeln('1. 从 GCM 获取 token...');
    final token = await getToken();
    stdout.writeln('   Token 获取成功 (长度: ${token.length})');

    stdout.writeln('2. 创建 GitHub Release $tag...');
    final releaseId = await createRelease(token);

    stdout.writeln('3. 上传 release APK...');
    await uploadAsset(token, releaseId);

    stdout.writeln('\n完成! Release 已发布: https://github.com/$repo/releases/tag/$tag');
  } catch (e) {
    stderr.writeln('错误: $e');
    exit(1);
  }
}
