import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'log_service.dart';

/// DeepSeek OpenAI 兼容接口的共用请求管道
class DeepSeekClient {
  DeepSeekClient._();

  static const baseUrl = 'https://api.deepseek.com';
  static const endpoint = '$baseUrl/chat/completions';

  /// 默认请求超时（视觉识别等）
  static const defaultTimeout = Duration(seconds: 60);

  /// POST /chat/completions，返回已解析的 JSON map。
  /// 请求体与响应会写入 [LogService]，方便在界面底部查看。
  /// 开了 thinking 的请求（如判分）耗时长，可通过 [timeout] 单独放宽。
  static Future<Map<String, dynamic>> chat({
    required String apiKey,
    required Map<String, dynamic> body,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    if (apiKey.trim().isEmpty) {
      throw ApiException('未配置 DeepSeek API Key');
    }

    LogService.instance.add('→ AI 请求 (${body['model']})', prettyBody(body));

    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(effectiveTimeout);
    } on SocketException catch (e) {
      final msg = '网络异常，请检查网络连接：${e.message}';
      LogService.instance.add('✗ AI 请求失败', msg);
      throw ApiException(msg);
    } on HttpException catch (e) {
      final msg = 'HTTP 异常：${e.message}';
      LogService.instance.add('✗ AI 请求失败', msg);
      throw ApiException(msg);
    } on TimeoutException {
      final msg = '请求超时（${effectiveTimeout.inSeconds}s），请稍后重试';
      LogService.instance.add('✗ AI 请求失败', msg);
      throw ApiException(msg);
    } on Exception catch (e) {
      final msg = '请求失败：$e';
      LogService.instance.add('✗ AI 请求失败', msg);
      throw ApiException(msg);
    }

    final ok = resp.statusCode >= 200 && resp.statusCode < 300;
    LogService.instance.add(
      ok ? '← AI 响应' : '✗ AI 响应错误',
      'HTTP ${resp.statusCode}\n${prettyJsonText(resp.body)}',
    );

    return handleResponse(resp);
  }

  static Map<String, dynamic> handleResponse(http.Response resp) {
    if (resp.statusCode == 429) {
      throw ApiException('请求过于频繁，已被限流（429），请稍后重试');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(
        'DeepSeek 接口错误 HTTP ${resp.statusCode}：${snippet(resp.body)}',
      );
    }
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException('响应不是合法 JSON：$e');
    }
  }

  static String extractMessageContent(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ApiException('响应缺少 choices 字段');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw ApiException('响应缺少 message 字段');
    }
    final content = message['content'];
    if (content is! String || content.isEmpty) {
      throw ApiException('响应 content 为空');
    }
    return content;
  }

  static String snippet(String body) {
    final t = body.trim();
    return t.length <= 200 ? t : '${t.substring(0, 200)}…';
  }

  static String mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/png';
  }

  // ---------- 日志用的可读化处理 ----------

  /// 请求体转可读文本（格式化 JSON + 省略 base64 图片）
  static String prettyBody(Map<String, dynamic> body) {
    try {
      return maskDataUrls(const JsonEncoder.withIndent('  ').convert(body));
    } catch (_) {
      return maskDataUrls(body.toString());
    }
  }

  /// 响应文本转可读文本
  static String prettyJsonText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '(空响应)';
    try {
      final decoded = jsonDecode(trimmed);
      return maskDataUrls(const JsonEncoder.withIndent('  ').convert(decoded));
    } catch (_) {
      return maskDataUrls(
        trimmed.length > 4000 ? '${trimmed.substring(0, 4000)}…' : trimmed,
      );
    }
  }

  /// 把 data:image/...;base64,XXXX 替换成占位，避免日志被超长 base64 淹没
  static String maskDataUrls(String text) {
    return text.replaceAllMapped(
      RegExp(r'data:image/[a-zA-Z]+;base64,[A-Za-z0-9+/=]+'),
      (m) => 'data:image/...;base64,(已省略 ${m.group(0)!.length} 字符)',
    );
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => 'ApiException: $message';
}
