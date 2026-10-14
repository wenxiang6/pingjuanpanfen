import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/question_record.dart';
import '../utils/validator.dart';

/// SQLite 本地存储服务（需求 §2.5 / §3.2）
class SqliteService {
  SqliteService._();
  static final SqliteService instance = SqliteService._();

  Database? _db;

  /// 数据库文件默认放在应用支持目录
  Future<String> get dbFilePath async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'judge_assistant.db');
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    sqfliteFfiInit();
    final path = await dbFilePath;
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE IF NOT EXISTS exam_question_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  question TEXT,
  student_answer TEXT,
  standard_answer TEXT,
  total_score REAL,
  ai_score REAL,
  teacher_score REAL,
  screenshot_path TEXT,
  ocr_source TEXT,
  create_time TEXT
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS app_config (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  config_key TEXT UNIQUE,
  config_value TEXT
);
''');
        },
      ),
    );
    _db = db;
    return db;
  }

  // ---------- 阅卷记录 ----------

  Future<int> insertRecord(QuestionRecord record) async {
    final db = await database;
    final data = Map<String, Object?>.from(record.toMap())
      ..remove('id')
      ..['create_time'] = record.createTime.isEmpty ? isoNow() : record.createTime;
    return db.insert('exam_question_records', data);
  }

  Future<List<QuestionRecord>> getAllRecords() async {
    final db = await database;
    final rows = await db.query(
      'exam_question_records',
      orderBy: 'id DESC',
    );
    return rows.map(QuestionRecord.fromMap).toList();
  }

  Future<int> deleteRecord(int id) async {
    final db = await database;
    return db.delete('exam_question_records', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAllRecords() async {
    final db = await database;
    await db.delete('exam_question_records');
  }

  // ---------- 配置 ----------

  /// 配置 key 常量
  static const kApiKey = 'deepseek_api_key';
  static const kPaddleOcrPath = 'paddle_ocr_path';
  static const kVlModel = 'deepseek_vl_model';
  static const kJudgeModel = 'deepseek_judge_model';

  static const defaultVlModel = 'deepseek-flash';
  static const defaultJudgeModel = 'deepseek-v4-pro';

  Future<String?> getConfig(String key) async {
    final db = await database;
    final rows = await db.query(
      'app_config',
      columns: ['config_value'],
      where: 'config_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['config_value'] as String?;
  }

  Future<void> setConfig(String key, String value) async {
    final db = await database;
    await db.insert(
      'app_config',
      {'config_key': key, 'config_value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setConfigs(Map<String, String> values) async {
    for (final entry in values.entries) {
      await setConfig(entry.key, entry.value);
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
