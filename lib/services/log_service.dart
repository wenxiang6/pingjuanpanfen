import 'package:flutter/foundation.dart';

/// 一条日志
class LogEntry {
  final DateTime time;
  final String tag;
  final String message;

  LogEntry({required this.tag, required this.message, DateTime? time})
      : time = time ?? DateTime.now();

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// 内存日志服务（用于在界面上查看发给 AI 的内容、识别结果等）。
///
/// 只保留最近 [maxEntries] 条，进程内有效、不落盘。
class LogService extends ChangeNotifier {
  LogService._();
  static final LogService instance = LogService._();

  static const int maxEntries = 300;

  final List<LogEntry> _entries = <LogEntry>[];

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  void add(String tag, String message) {
    _entries.add(LogEntry(tag: tag, message: message));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 导出为可复制的纯文本
  String asText() {
    final buffer = StringBuffer();
    for (final e in _entries) {
      buffer.writeln('[${e.timeText}] ${e.tag}');
      buffer.writeln(e.message);
      buffer.writeln('—' * 20);
    }
    return buffer.toString();
  }
}
