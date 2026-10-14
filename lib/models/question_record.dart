/// 单题实体模型，对应 SQLite 表 exam_question_records
class QuestionRecord {
  final int? id;
  final String question;
  final String studentAnswer;
  final String standardAnswer;
  final double totalScore;
  final double aiScore;
  final double teacherScore;
  final String screenshotPath;
  final String ocrSource;
  final String createTime;

  const QuestionRecord({
    this.id,
    this.question = '',
    this.studentAnswer = '',
    this.standardAnswer = '',
    this.totalScore = 0,
    this.aiScore = 0,
    this.teacherScore = 0,
    this.screenshotPath = '',
    this.ocrSource = '',
    this.createTime = '',
  });

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'question': question,
      'student_answer': studentAnswer,
      'standard_answer': standardAnswer,
      'total_score': totalScore,
      'ai_score': aiScore,
      'teacher_score': teacherScore,
      'screenshot_path': screenshotPath,
      'ocr_source': ocrSource,
      'create_time': createTime,
    };
  }

  factory QuestionRecord.fromMap(Map<String, Object?> map) {
    return QuestionRecord(
      id: map['id'] as int?,
      question: (map['question'] as String?) ?? '',
      studentAnswer: (map['student_answer'] as String?) ?? '',
      standardAnswer: (map['standard_answer'] as String?) ?? '',
      totalScore: (map['total_score'] as num?)?.toDouble() ?? 0,
      aiScore: (map['ai_score'] as num?)?.toDouble() ?? 0,
      teacherScore: (map['teacher_score'] as num?)?.toDouble() ?? 0,
      screenshotPath: (map['screenshot_path'] as String?) ?? '',
      ocrSource: (map['ocr_source'] as String?) ?? '',
      createTime: (map['create_time'] as String?) ?? '',
    );
  }

  QuestionRecord copyWith({
    int? id,
    String? question,
    String? studentAnswer,
    String? standardAnswer,
    double? totalScore,
    double? aiScore,
    double? teacherScore,
    String? screenshotPath,
    String? ocrSource,
    String? createTime,
  }) {
    return QuestionRecord(
      id: id ?? this.id,
      question: question ?? this.question,
      studentAnswer: studentAnswer ?? this.studentAnswer,
      standardAnswer: standardAnswer ?? this.standardAnswer,
      totalScore: totalScore ?? this.totalScore,
      aiScore: aiScore ?? this.aiScore,
      teacherScore: teacherScore ?? this.teacherScore,
      screenshotPath: screenshotPath ?? this.screenshotPath,
      ocrSource: ocrSource ?? this.ocrSource,
      createTime: createTime ?? this.createTime,
    );
  }

  /// 单题 JSON（固定 6 个 key，与需求文档 §3.1 对齐）
  Map<String, Object?> toUiJson() {
    return {
      '题目': question,
      '学生答案': studentAnswer,
      '标准答案': standardAnswer,
      '该题的总分': totalScore,
      'ai给的分数': aiScore,
      '老师给的分数': teacherScore,
    };
  }
}

/// OCR 来源标记
abstract final class OcrSource {
  static const localPaddle = 'local_paddle';
  static const deepseekVl = 'deepseek_vl';
}
