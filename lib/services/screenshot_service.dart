import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_screenshot/desktop_screenshot.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/validator.dart' as v;

/// 区域截图服务（README §4.4）
///
/// 流程：全屏截图 → UI 框选矩形 → 本服务裁剪 → 保存 PNG 到应用支持目录。
class ScreenshotService {
  ScreenshotService._();
  static final ScreenshotService instance = ScreenshotService._();

  final _capturer = DesktopScreenshot();

  /// 截取整个屏幕，返回 PNG 字节。
  /// macOS 未授权「屏幕录制」时会抛 [ScreenshotException]。
  Future<Uint8List> captureFullScreen() async {
    try {
      final bytes = await _capturer.getScreenshot();
      if (bytes == null || bytes.isEmpty) {
        throw ScreenshotException(
          '全屏截图失败。macOS 请在「系统设置 → 隐私与安全性 → 屏幕录制」中授权本应用。',
        );
      }
      return bytes;
    } catch (e) {
      if (e is ScreenshotException) rethrow;
      throw ScreenshotException('全屏截图失败：$e');
    }
  }

  /// 从全屏图中裁剪出矩形区域（屏幕像素坐标），返回 PNG 字节（不落盘）
  Uint8List cropToPng({
    required Uint8List fullPng,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw ScreenshotException('框选区域无效');
    }

    final decoded = img.decodeImage(fullPng);
    if (decoded == null) {
      throw ScreenshotException('截图解码失败');
    }

    final clampedX = x.clamp(0, decoded.width - 1);
    final clampedY = y.clamp(0, decoded.height - 1);
    final clampedW = width.clamp(1, decoded.width - clampedX);
    final clampedH = height.clamp(1, decoded.height - clampedY);

    final cropped = img.copyCrop(
      decoded,
      x: clampedX,
      y: clampedY,
      width: clampedW,
      height: clampedH,
    );
    return Uint8List.fromList(img.encodePng(cropped));
  }

  /// 从全屏图中裁剪出 [rect]（屏幕像素坐标），保存为 PNG。
  /// 返回保存后的绝对路径。
  Future<String> cropAndSave({
    required Uint8List fullPng,
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    final pngBytes = cropToPng(
      fullPng: fullPng,
      x: x,
      y: y,
      width: width,
      height: height,
    );
    return saveScreenshotPng(pngBytes);
  }

  /// 保存 PNG 字节到应用支持目录的 screenshots 子目录
  /// （文件名：时间戳 + 随机后缀）
  Future<String> saveScreenshotPng(Uint8List pngBytes) async {
    final dir = await screenshotDir();
    final path = p.join(dir.path, v.screenshotFileName());
    await File(path).writeAsBytes(pngBytes, flush: true);
    return path;
  }

  Future<Directory> screenshotDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'screenshots'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 清空历史截图（配置面板手动触发）
  Future<int> clearAllScreenshots() async {
    final dir = await screenshotDir();
    var count = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        await entity.delete();
        count++;
      }
    }
    return count;
  }
}

class ScreenshotException implements Exception {
  final String message;
  ScreenshotException(this.message);

  @override
  String toString() => 'ScreenshotException: $message';
}
