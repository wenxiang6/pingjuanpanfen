import 'dart:convert';
import 'dart:io';

import 'deepseek_client.dart';

/// DeepSeek 多模态视觉识别服务（README §4.2）
///
/// 模型：deepseek-flash（Vision）
/// 图片以 base64 data URL 内嵌，仅在教师确认后调用。
class DeepSeekVlService {
  DeepSeekVlService._();
  static final DeepSeekVlService instance = DeepSeekVlService._();

  static const defaultModel = 'deepseek-flash';

  /// 识别截图中的「题目」与「学生答案」
  Future<VlRecognitionResult> recognize({
    required String apiKey,
    required String imagePath,
    String model = defaultModel,
  }) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw ApiException('截图文件不存在：$imagePath');
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw ApiException('截图文件为空：$imagePath');
    }
    final b64 = base64Encode(bytes);
    final mime = DeepSeekClient.mimeFromPath(imagePath);

    final body = {
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  '识别图中学生的作答内容（手写答案），严格输出 JSON，不要输出其他内容。'
                  '格式：{"学生答案":"学生作答内容"}'
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mime;base64,$b64',
                'detail': 'original',
              },
            },
          ],
        }
      ],
      'thinking': {'type': 'disabled'},
      'response_format': {'type': 'json_object'},
      'max_tokens': 1024,
      'stream': false,
    };

    final json = await DeepSeekClient.chat(
      apiKey: apiKey,
      body: body,
      // 图片 base64 较大，上传 + 识别较慢
      timeout: const Duration(seconds: 90),
    );
    final content = DeepSeekClient.extractMessageContent(json);
    return VlRecognitionResult.parse(content);
  }
}

/// 视觉识别结果
class VlRecognitionResult {
  final String question;
  final String studentAnswer;

  const VlRecognitionResult({
    required this.question,
    required this.studentAnswer,
  });

  factory VlRecognitionResult.parse(String content) {
    final map = _tryParseJsonObject(content);
    if (map == null) {
      // 模型没按 JSON 返回时，把全文放进题目框，人工再拆
      return VlRecognitionResult(question: content.trim(), studentAnswer: '');
    }
    final question = (map['题目'] ?? map['question'] ?? '').toString();
    final answer =
        (map['学生答案'] ?? map['studentAnswer'] ?? map['student_answer'] ?? '')
            .toString();
    return VlRecognitionResult(
      question: question,
      studentAnswer: answer,
    );
  }

  static Map<String, dynamic>? _tryParseJsonObject(String text) {
    var s = text.trim();
    if (s.startsWith('```')) {
      s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
      s = s.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(s.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }
}
