import 'package:nota/services/storage/hotword_storage.dart';

/// 外挂热词词库管理。
///
/// 作为 ASR 与 LLM 之间的热词中介层：
/// - ASR 转写时通过 [getAllWords] / [getWeightedWords] 获取热词列表，
///   传入支持 boosting 的本地模型（如 Paraformer）。
/// - LLM 纠错 / 纪要 / 笔记整理时通过 [getHotwordTextForPrompt] 获取
///   热词文本，注入 prompt 作为专有名词 / 术语参考词表。
///
/// 数据由 [HotwordStorage] 持久化（SQLite），本类只负责读取与格式化，
/// 不直接操作数据库。单例，全局共享。
class HotwordDictionary {
  HotwordDictionary._();
  static final HotwordDictionary _instance = HotwordDictionary._();
  factory HotwordDictionary() => _instance;

  final HotwordStorage _storage = HotwordStorage();

  /// 获取所有热词（扁平列表，用于 ASR 注入）。
  ///
  /// 遍历所有分组下的全部词条，返回词列表（不去重，保留重复以隐式加权）。
  Future<List<String>> getAllWords() async {
    final entries = await _storage.getAllEntries();
    return entries.map((e) => e.word).toList();
  }

  /// 获取热词带权重（用于支持 boosting 的模型）。
  ///
  /// 返回 (词, 权重) 键值对列表，权重越高模型越倾向识别该词。
  Future<List<MapEntry<String, double>>> getWeightedWords() async {
    final entries = await _storage.getAllEntries();
    return entries.map((e) => MapEntry(e.word, e.weight)).toList();
  }

  /// 获取热词文本（用于注入 LLM prompt 纠错）。
  ///
  /// 拼接为参考词表格式，热词为空时返回空串（调用方据此判断是否注入）。
  Future<String> getHotwordTextForPrompt() async {
    final words = await getAllWords();
    if (words.isEmpty) return '';
    return '以下是专有名词/术语词表，请参考纠错：\n${words.join('、')}';
  }
}
