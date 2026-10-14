import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg;

/// CoreGraphics 的 CGPoint（屏幕坐标，double x/y）
final class _CGPoint extends Struct {
  @Double()
  external double x;

  @Double()
  external double y;
}

typedef _CreateMouseEventNative = Pointer<Void> Function(
    Pointer<Void> source, Uint32 type, _CGPoint point, Uint32 button);
typedef _CreateMouseEventDart = Pointer<Void> Function(
    Pointer<Void> source, int type, _CGPoint point, int button);

typedef _CreateKeyEventNative = Pointer<Void> Function(
    Pointer<Void> source, Uint16 keyCode, Bool keyDown);
typedef _CreateKeyEventDart = Pointer<Void> Function(
    Pointer<Void> source, int keyCode, bool keyDown);

typedef _SetUnicodeNative = Void Function(
    Pointer<Void> event, UnsignedLong length, Pointer<Uint16> chars);
typedef _SetUnicodeDart = void Function(
    Pointer<Void> event, int length, Pointer<Uint16> chars);

typedef _SetFlagsNative = Void Function(Pointer<Void> event, Uint64 flags);
typedef _SetFlagsDart = void Function(Pointer<Void> event, int flags);

typedef _PostNative = Void Function(Uint32 tap, Pointer<Void> event);
typedef _PostDart = void Function(int tap, Pointer<Void> event);

typedef _ReleaseNative = Void Function(Pointer<Void> cf);
typedef _ReleaseDart = void Function(Pointer<Void> cf);

typedef _IsTrustedNative = Bool Function();
typedef _IsTrustedDart = bool Function();

/// macOS 输入模拟服务：基于 CoreGraphics 的 CGEvent 发送鼠标点击与键盘输入。
///
/// 需要系统「辅助功能（Accessibility）」权限，否则事件会被系统丢弃。
/// 非 macOS 平台调用会抛 [MacInputException]。
class MacInputService {
  MacInputService._();
  static final MacInputService instance = MacInputService._();

  static const int _kHidEventTap = 0;
  static const int _kMouseMoved = 5;
  static const int _kLeftMouseDown = 1;
  static const int _kLeftMouseUp = 2;
  static const int _kFlagCommand = 1 << 20;
  static const int _keyCodeA = 0;
  static const int _keyCodeDelete = 51;
  static const int _keyCodeCommand = 55;
  static const int _keyCodeEscape = 53;
  static const int _keyCodeV = 9;

  Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)? _createMouse;
  Pointer<Void> Function(Pointer<Void>, int, bool)? _createKey;
  void Function(Pointer<Void>, int, Pointer<Uint16>)? _setUnicode;
  void Function(Pointer<Void>, int)? _setFlags;
  void Function(int, Pointer<Void>)? _post;
  void Function(Pointer<Void>)? _release;
  bool Function()? _isTrusted;

  bool get isSupported => Platform.isMacOS;

  bool _ensureLoaded() {
    if (!Platform.isMacOS) return false;
    if (_post != null) return true;
    try {
      final cg = _openFirst(<String>[
        '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices',
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      ]);
      final cf = _openFirst(<String>[
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      ]);
      if (cg == null || cf == null) return false;

      _createMouse = cg.lookupFunction<_CreateMouseEventNative,
          _CreateMouseEventDart>('CGEventCreateMouseEvent');
      _createKey =
          cg.lookupFunction<_CreateKeyEventNative, _CreateKeyEventDart>(
              'CGEventCreateKeyboardEvent');
      _setUnicode =
          cg.lookupFunction<_SetUnicodeNative, _SetUnicodeDart>(
              'CGEventKeyboardSetUnicodeString');
      _setFlags = cg.lookupFunction<_SetFlagsNative, _SetFlagsDart>(
          'CGEventSetFlags');
      _post = cg.lookupFunction<_PostNative, _PostDart>('CGEventPost');
      _release = cf.lookupFunction<_ReleaseNative, _ReleaseDart>('CFRelease');
      _isTrusted = cg.lookupFunction<_IsTrustedNative, _IsTrustedDart>(
          'AXIsProcessTrusted');
      return true;
    } catch (_) {
      _post = null;
      return false;
    }
  }

  static DynamicLibrary? _openFirst(List<String> candidates) {
    for (final path in candidates) {
      try {
        return DynamicLibrary.open(path);
      } catch (_) {
        // 尝试下一个候选路径
      }
    }
    return null;
  }

  /// 是否已获得「辅助功能」权限
  bool get hasAccessibilityPermission {
    if (!_ensureLoaded()) return false;
    try {
      return _isTrusted?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 在屏幕逻辑坐标 (x, y) 处点击左键。
  ///
  /// [taps] > 1 时连续点击多次：macOS 下**非活动窗口的第一次点击只用于激活窗口**，
  /// 事件不会传给控件，因此聚焦输入框这类操作需要点两次
  /// （第一次激活浏览器，第二次才真正点到输入框）。
  Future<void> click(double x, double y, {int taps = 1}) async {
    if (!_ensureLoaded()) {
      throw MacInputException(isSupported
          ? '无法加载系统输入接口（CGEvent）'
          : '当前平台不支持模拟输入（仅 macOS）');
    }
    final point = pkg.calloc<_CGPoint>();
    point.ref.x = x;
    point.ref.y = y;
    try {
      for (var i = 0; i < taps; i++) {
        _emitMouse(_kMouseMoved, point.ref);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        _emitMouse(_kLeftMouseDown, point.ref);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        _emitMouse(_kLeftMouseUp, point.ref);
        if (i < taps - 1) {
          // 间隔取长一些，避免两次点击被识别成双击
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      pkg.calloc.free(point);
    }
  }

  void _emitMouse(int type, _CGPoint point) {
    final createMouse = _createMouse;
    final post = _post;
    final release = _release;
    if (createMouse == null || post == null || release == null) return;
    final event = createMouse(nullptr, type, point, 0);
    if (event == nullptr) return;
    post(_kHidEventTap, event);
    release(event);
  }

  /// 发送单键（可选修饰键 flags，如 Cmd）
  void keyPress(int keyCode, {int flags = 0}) {
    _emitKey(keyCode, true, flags);
    _emitKey(keyCode, false, flags);
  }

  /// 发送组合键：真实按下修饰键 → 按键 → 真实抬起修饰键。
  ///
  /// 只给按键事件设置 flags、而不真实按下/抬起修饰键，会让系统认为
  /// 修饰键一直按着（例如 Cmd 粘住），后续输入会被解释成快捷键
  /// （如 Cmd+4 变成切换标签页）。
  Future<void> keyCombo({
    required int modifierKeyCode,
    required int keyCode,
    int flags = _kFlagCommand,
  }) async {
    _emitKey(modifierKeyCode, true, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _emitKey(keyCode, true, flags);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _emitKey(keyCode, false, flags);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _emitKey(modifierKeyCode, false, 0);
  }

  /// 确保没有修饰键处于按下状态（发送一次 Esc，并让 flags 归零）
  Future<void> releaseModifiers() async {
    keyPress(_keyCodeEscape);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }

  /// 全选并清除当前输入框内容（Cmd+A → Delete）
  Future<void> selectAllAndClear() async {
    await keyCombo(modifierKeyCode: _keyCodeCommand, keyCode: _keyCodeA);
    await Future<void>.delayed(const Duration(milliseconds: 80));    keyPress(_keyCodeDelete);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  /// 常见字符的 macOS 虚拟键码（US 布局），用于发送"真实按键"事件。
  static const Map<String, int> _charKeyCodes = <String, int>{
    '0': 29,
    '1': 18,
    '2': 19,
    '3': 20,
    '4': 21,
    '5': 23,
    '6': 22,
    '7': 26,
    '8': 28,
    '9': 25,
    '.': 47,
    '-': 27,
  };

  /// 发送 Cmd+V（粘贴）。调用方需先把要输入的内容写入系统剪贴板。
  Future<void> paste() async {
    await keyCombo(modifierKeyCode: _keyCodeCommand, keyCode: _keyCodeV);
  }

  /// 逐字符输入文本。
  ///
  /// 数字、小数点、负号等使用**真实按键事件**（keycode）——Chrome 等应用会忽略
  /// 通过 `CGEventKeyboardSetUnicodeString` 注入的文本，但对真实按键响应正常；
  /// 其余字符才回退到 Unicode 注入。
  Future<void> typeText(String text) async {
    if (!_ensureLoaded()) {
      throw MacInputException('当前平台不支持模拟输入（仅 macOS）');
    }
    for (final char in text.split('')) {
      final keyCode = _charKeyCodes[char];
      if (keyCode != null) {
        _emitKey(keyCode, true, 0);
        _emitKey(keyCode, false, 0);
      } else {
        _emitUnicodeChar(char);
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
  }

  void _emitUnicodeChar(String char) {
    final units = char.codeUnits;
    final ptr = pkg.calloc<Uint16>(units.length);
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    _emitKeyWithText(true, ptr, units.length);
    _emitKeyWithText(false, ptr, units.length);
    pkg.calloc.free(ptr);
  }


  void _emitKey(int keyCode, bool down, int flags) {
    if (!_ensureLoaded()) return;
    final createKey = _createKey;
    final post = _post;
    final release = _release;
    if (createKey == null || post == null || release == null) return;
    final event = createKey(nullptr, keyCode, down);
    if (event == nullptr) return;
    if (flags != 0) _setFlags?.call(event, flags);
    post(_kHidEventTap, event);
    release(event);
  }

  void _emitKeyWithText(bool down, Pointer<Uint16> chars, int length) {
    final createKey = _createKey;
    final setUnicode = _setUnicode;
    final post = _post;
    final release = _release;
    if (createKey == null ||
        setUnicode == null ||
        post == null ||
        release == null) {
      return;
    }
    final event = createKey(nullptr, 0, down);
    if (event == nullptr) return;
    setUnicode(event, length, chars);
    post(_kHidEventTap, event);
    release(event);
  }
}

class MacInputException implements Exception {
  final String message;
  MacInputException(this.message);

  @override
  String toString() => 'MacInputException: $message';
}
