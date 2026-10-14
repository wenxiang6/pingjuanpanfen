/// 分数校验与通用工具
library;

import 'dart:math';

/// 截图文件名随机后缀使用的密码学安全随机源
final _secureRandom = Random.secure();

/// 将分数强制限制在 [0, totalScore] 区间内。
/// totalScore 非法（<=0 或 NaN）时按 0 处理上限。
double clampScore(num? score, num? totalScore) {
  final maxScore = (totalScore == null || totalScore.isNaN || totalScore < 0)
      ? 0.0
      : totalScore.toDouble();
  if (score == null || score.isNaN) return 0.0;
  final value = score.toDouble();
  if (value < 0) return 0.0;
  if (value > maxScore) return maxScore;
  return value;
}

/// 解析用户在数字输入框中输入的分数。
/// 空/非法返回 null，由调用方决定是否提示。
double? parseScore(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return double.tryParse(trimmed);
}

/// 校验分数是否落在合法区间（需求 §6.6）
bool isValidScore(num? score, num? totalScore) {
  if (score == null || score.isNaN) return false;
  final maxScore = (totalScore == null || totalScore.isNaN || totalScore < 0)
      ? 0.0
      : totalScore.toDouble();
  return score >= 0 && score <= maxScore;
}

/// 解析 AI 返回 JSON 中的 score 字段。
/// 兼容 number 与 string 两种形态。
double? parseAiScore(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

/// API Key 脱敏：只保留前 4 位
String maskApiKey(String key) {
  if (key.isEmpty) return '';
  if (key.length <= 4) return '****';
  return '${key.substring(0, 4)}****';
}

/// 生成截图文件名：时间戳 + 随机后缀，避免可预测路径
String screenshotFileName({DateTime? now}) {
  final t = now ?? DateTime.now();
  final ts = t.microsecondsSinceEpoch;
  // 6 位十六进制随机后缀（24 bit），用密码学安全随机源，
  // 不用时间戳派生，避免路径可预测被外部程序批量读取。
  final suffix =
      _secureRandom.nextInt(1 << 24).toRadixString(16).padLeft(6, '0');
  return 'shot_${ts}_$suffix.png';
}

/// ISO-8601 时间戳
String isoNow({DateTime? now}) {
  return (now ?? DateTime.now()).toIso8601String();
}
