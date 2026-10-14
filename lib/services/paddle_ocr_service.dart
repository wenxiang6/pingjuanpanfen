import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log_service.dart';

/// 本地离线 OCR 子进程服务（协议见 README §4.3）。
///
/// 只要可执行程序遵循下面的协议即可，具体实现不限：
///   <本地 OCR 程序> --image "图片绝对路径" --lang ch
/// stdout 输出 JSON：
///   {"code":0,"message":"ok","full_text":"...","lines":["..."]}
///
/// 仓库自带一个 macOS 原生实现 `tools/ocr_vision`（基于系统 Vision 框架，
/// 无需第三方依赖）；也可换成 PaddleOCR 等其它实现。
class PaddleOcrService {
  PaddleOcrService._();
  static final PaddleOcrService instance = PaddleOcrService._();

  static const timeout = Duration(seconds: 60);

  Future<OcrResult> recognize({
    required String ocrBinaryPath,
    required String imagePath,
  }) async {
    if (ocrBinaryPath.trim().isEmpty) {
      throw OcrException('未配置本地 OCR 程序路径');
    }
    final binary = File(ocrBinaryPath);
    if (!binary.existsSync()) {
      throw OcrException('本地 OCR 程序不存在：$ocrBinaryPath');
    }
    final image = File(imagePath);
    if (!image.existsSync()) {
      throw OcrException('截图文件不存在：$imagePath');
    }

    LogService.instance.add(
      '→ 本地 OCR',
      '$ocrBinaryPath --image $imagePath --lang ch',
    );

    ProcessResult result;
    try {
      result = await Process.run(
        ocrBinaryPath,
        <String>['--image', imagePath, '--lang', 'ch'],
      ).timeout(timeout);
    } on TimeoutException {
      final msg = '本地 OCR 执行超时（${timeout.inSeconds}s）';
      LogService.instance.add('✗ 本地 OCR', msg);
      throw OcrException(msg);
    } on ProcessException catch (e) {
      final msg = '本地 OCR 调用失败：${e.message}';
      LogService.instance.add('✗ 本地 OCR', msg);
      throw OcrException(msg);
    } on Exception catch (e) {
      final msg = '本地 OCR 调用失败：$e';
      LogService.instance.add('✗ 本地 OCR', msg);
      throw OcrException(msg);
    }

    final stdoutText = result.stdout.toString();
    final stderrText = result.stderr.toString();

    if (result.exitCode != 0) {
      final detail =
          stderrText.trim().isEmpty ? stdoutText.trim() : stderrText.trim();
      LogService.instance.add('✗ 本地 OCR', '退出码 ${result.exitCode}：$detail');
      throw OcrException('本地 OCR 退出码 ${result.exitCode}：$detail');
    }

    LogService.instance.add('← 本地 OCR 输出', stdoutText.trim());

    return OcrResult.parse(stdoutText);
  }
}

/// OCR 输出结果
class OcrResult {
  final String fullText;
  final List<String> lines;

  const OcrResult({required this.fullText, required this.lines});

  factory OcrResult.parse(String stdoutText) {
    final trimmed = stdoutText.trim();
    if (trimmed.isEmpty) {
      throw OcrException('本地 OCR 无输出');
    }

    // 兼容：进程可能额外打印日志，截取首个 {...} JSON 块
    final jsonStr = _extractJson(trimmed);
    Map<String, dynamic> map;
    try {
      map = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      throw OcrException('本地 OCR 输出不是合法 JSON：$e');
    }

    final code = map['code'];
    if (code is! num || code != 0) {
      final msg = map['message']?.toString() ?? '未知错误';
      throw OcrException('本地 OCR 返回失败 code=$code：$msg');
    }

    final fullText = map['full_text']?.toString() ?? '';
    final linesRaw = map['lines'];
    final lines = <String>[
      if (linesRaw is List)
        ...linesRaw.map((e) => e.toString())
      else if (fullText.isNotEmpty)
        ...const LineSplitter().convert(fullText),
    ];

    return OcrResult(fullText: fullText, lines: lines);
  }

  static String _extractJson(String input) {
    final start = input.indexOf('{');
    final end = input.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw OcrException('本地 OCR 输出中找不到 JSON：$input');
    }
    return input.substring(start, end + 1);
  }
}

class OcrException implements Exception {
  final String message;
  OcrException(this.message);

  @override
  String toString() => 'OcrException: $message';
}
