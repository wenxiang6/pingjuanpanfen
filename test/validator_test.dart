import 'package:flutter_test/flutter_test.dart';
import 'package:judge_assistant/utils/validator.dart' as v;

void main() {
  group('clampScore', () {
    test('限制在 [0, totalScore] 区间内', () {
      expect(v.clampScore(12, 10), 10);
      expect(v.clampScore(-3, 10), 0);
      expect(v.clampScore(5, 10), 5);
    });

    test('总分为 0 或非法时上限按 0 处理', () {
      expect(v.clampScore(5, 0), 0);
      expect(v.clampScore(5, -1), 0);
      expect(v.clampScore(5, double.nan), 0);
    });

    test('分数为 null 或 NaN 时返回 0', () {
      expect(v.clampScore(null, 10), 0);
      expect(v.clampScore(double.nan, 10), 0);
    });
  });

  group('parseScore', () {
    test('解析合法数字', () {
      expect(v.parseScore('8.5'), 8.5);
      expect(v.parseScore(' 10 '), 10);
    });

    test('空或非法输入返回 null', () {
      expect(v.parseScore(''), isNull);
      expect(v.parseScore(null), isNull);
      expect(v.parseScore('abc'), isNull);
    });
  });

  group('isValidScore', () {
    test('落在区间内为 true', () {
      expect(v.isValidScore(0, 10), isTrue);
      expect(v.isValidScore(10, 10), isTrue);
    });

    test('落在区间外为 false', () {
      expect(v.isValidScore(11, 10), isFalse);
      expect(v.isValidScore(-1, 10), isFalse);
      expect(v.isValidScore(null, 10), isFalse);
    });
  });

  group('parseAiScore', () {
    test('兼容 number 与 string 两种形态', () {
      expect(v.parseAiScore(8), 8.0);
      expect(v.parseAiScore('7.5'), 7.5);
      expect(v.parseAiScore(null), isNull);
      expect(v.parseAiScore('x'), isNull);
    });
  });

  group('maskApiKey', () {
    test('脱敏只保留前 4 位', () {
      expect(v.maskApiKey('sk-1234567890'), 'sk-1****');
      expect(v.maskApiKey('abc'), '****');
      expect(v.maskApiKey(''), '');
    });
  });

  group('screenshotFileName', () {
    test('形如 shot_<时间戳>_<6位后缀>.png', () {
      final name = v.screenshotFileName(now: DateTime(2026, 1, 1));
      expect(name.startsWith('shot_'), isTrue);
      expect(name.endsWith('.png'), isTrue);
      final parts = name.substring(0, name.length - 4).split('_');
      expect(parts.length, 3);
      expect(parts[2].length, 6);
    });

    test('同一时间戳下后缀不同（随机而非派生）', () {
      final a = v.screenshotFileName(now: DateTime(2026, 1, 1));
      final b = v.screenshotFileName(now: DateTime(2026, 1, 1));
      expect(a, isNot(equals(b)));
    });
  });

  group('isoNow', () {
    test('返回 ISO-8601 字符串', () {
      final s = v.isoNow(now: DateTime(2026, 1, 1, 9, 30));
      expect(s, startsWith('2026-01-01T09:30'));
    });
  });
}
