import 'dart:convert';

import '../utils/validator.dart' as v;
import 'deepseek_client.dart';
import 'log_service.dart';

/// DeepSeek 文本判分服务（README §4.2）
///
/// 每题独立请求，不携带历史上下文；返回分数强制 clamp 到 [0, totalScore]。
class DeepSeekJudgeService {
  DeepSeekJudgeService._();
  static final DeepSeekJudgeService instance = DeepSeekJudgeService._();

  static const defaultModel = 'deepseek-v4-pro';

  Future<JudgeResult> judge({
    required String apiKey,
    required String question,
    required String studentAnswer,
    required String standardAnswer,
    required double totalScore,
    String model = defaultModel,
  }) async {
    if (totalScore <= 0) {
      throw ApiException('请先填写「该题的总分」');
    }

    final userPrompt = StringBuffer()
      ..writeln('题目：${question.trim().isEmpty ? '（无）' : question}')
      ..writeln('学生答案：$studentAnswer')
      ..writeln('标准答案：$standardAnswer')
      ..writeln('该题总分：$totalScore')
      ..writeln()
      ..writeln('评分步骤：')
      ..writeln('1) 只从「标准答案」里拆出得分要点，每个要点是一个具体的原因、要素或结论；'
          '严禁把标准答案中没有的内容、或题干 / 现象本身当作要点；')
      ..writeln('2) 逐条判断学生答案是否命中：命中＝用任何说法表达了该要点的具体含义'
          '（近义表达也算）；要点由「结论＋成因」组成时，只要结论答到就算命中、'
          '成因说错不扣；只笼统提现象不算命中；')
      ..writeln('3) 按命中要点数占总要点数的比例算分，最终**必须取整**'
          '（四舍五入到整数，不能输出小数）；')
      ..writeln('4) 已命中的要点不因答案里另有错误而被扣掉；')
      ..writeln('5) 学生在同一主题语境下省略关键词的表述，按其指向的主题理解'
          '（例如题目问雪线高低时，学生写“西坡高”即“西坡雪线高”）。')
      ..writeln()
      ..writeln('简明作答，不要长篇推理，不要反复验算。')
      ..writeln('严格输出 JSON，不要输出其他内容：')
      ..writeln('{"score": <0 到 $totalScore 之间的整数>, "reason": "<逐条命中说明，简明>"}');

    final body = {
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': '你是严格的阅卷老师，只输出 JSON，不要输出其他内容。'
              '判分基于语义、而非关键词重合。要点只能来自「标准答案」原文，'
              '严禁把标准答案中没有的内容、或题干 / 现象本身'
              '（如“XX 很丰富”“存在差异”）当作得分要点。'
              '逐条判断学生答案是否命中：学生用任何说法表达了该要点的具体含义就算命中'
              '（近义表达也算）；若要点由「结论＋成因」组成，只要结论答到就算命中，'
              '成因 / 机制说错不扣；只笼统提到现象、没给出要点要求的具体结论 / 要素则不算命中。'
              '已命中的要点不因答案里另有错误而被扣掉；不得自行补充标准答案之外的得分点。',
        },
        {'role': 'user', 'content': userPrompt.toString()},
      ],
      // 判分需要推理：开启 thinking 能显著提升判断质量与一致性
      // （实测同一份答案，关闭 thinking 容易给出偏低的分数）。
      // 注意：JSON Output 仅支持非思考模式，因此这里不用 response_format，
      // 改为在提示词里约束 JSON 输出；解析端对前后多余文字有兜底。
      'thinking': {'type': 'enabled'},
      // 降低思考力度：默认 high 会想太多（实测单题 60s+、思考 5000+ tokens），
      // low 后约 5~17s，判分结果与 high 基本一致
      'reasoning_effort': 'low',
      'max_tokens': 4096,
      'stream': false,
    };

    final json = await DeepSeekClient.chat(
      apiKey: apiKey,
      body: body,
      // 判分开启 thinking，响应较慢，放宽超时
      timeout: const Duration(seconds: 120),
    );
    final content = DeepSeekClient.extractMessageContent(json);
    final result = JudgeResult.parse(content, totalScore: totalScore);
    LogService.instance.add(
      '✔ 判分结果',
      'score=${result.score}（该题总分 $totalScore）\n理由：${result.reason}',
    );
    return result;
  }
}

class JudgeResult {
  final double score;
  final String reason;

  const JudgeResult({required this.score, required this.reason});

  factory JudgeResult.parse(String content, {required double totalScore}) {
    final map = _tryParseJsonObject(content);
    if (map == null) {
      // 尝试从纯文本里抓一个数字
      final n = RegExp(r'-?\d+(\.\d+)?').firstMatch(content)?.group(0);
      final parsed = n == null ? null : double.tryParse(n);
      if (parsed == null) {
        throw ApiException('无法解析 AI 返回的分数：${DeepSeekClient.snippet(content)}');
      }
      return JudgeResult(
        score: v.clampScore(parsed, totalScore),
        reason: content.trim(),
      );
    }

    final rawScore = map['score'] ?? map['分数'] ?? map['ai给的分数'];
    final parsed = v.parseAiScore(rawScore);
    if (parsed == null) {
      throw ApiException('AI 返回缺少 score 字段：${DeepSeekClient.snippet(content)}');
    }
    final reason = (map['reason'] ?? map['理由'] ?? '').toString();
    return JudgeResult(
      score: v.clampScore(parsed, totalScore),
      reason: reason,
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
