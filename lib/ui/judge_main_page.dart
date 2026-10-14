import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../models/question_record.dart';
import '../services/deepseek_judge_service.dart';
import '../services/deepseek_vl_service.dart';
import '../services/log_service.dart';
import '../services/mac_input_service.dart';
import '../services/network_service.dart';
import '../services/paddle_ocr_service.dart';
import '../services/screenshot_service.dart';
import '../services/sqlite_service.dart';
import '../utils/image_diff.dart';
import '../utils/validator.dart' as v;
import 'calibration_wizard_overlay.dart';
import 'point_picker_overlay.dart';
import 'region_select_overlay.dart';

/// 主竖长 UI 页面：串联截图、OCR、AI 判分与本地存储。
class JudgeMainPage extends StatefulWidget {
  const JudgeMainPage({super.key});

  @override
  State<JudgeMainPage> createState() => _JudgeMainPageState();
}

class _JudgeMainPageState extends State<JudgeMainPage> {
  // ---------- 表单 ----------
  final _question = TextEditingController();
  final _studentAnswer = TextEditingController();
  final _standardAnswer = TextEditingController();
  final _totalScore = TextEditingController();
  final _teacherScore = TextEditingController();

  // ---------- 配置 ----------
  final _apiKey = TextEditingController();
  final _paddlePath = TextEditingController();
  final _vlModel = TextEditingController();
  final _judgeModel = TextEditingController();
  bool _configExpanded = false;
  bool _obscureKey = true;

  // ---------- 运行时状态 ----------
  double _aiScore = 0;
  String _screenshotPath = '';
  String _ocrSource = '';
  bool _online = false;
  bool _alwaysOnTop = true;
  bool _capturing = false;
  bool _ocrBusy = false;
  bool _vlBusy = false;
  bool _judgeBusy = false;
  bool _saving = false;
  bool _automating = false;

  // ---------- 连续批阅 ----------
  /// 连续批阅进行中（可被【停止】打断）
  bool _batchRunning = false;
  /// 已批阅的题数（不含当前题）
  int _processedCount = 0;
  /// 上一题的答案区截图，用于检测页面是否已刷新到下一题
  Uint8List? _lastAnswerPng;

  /// 提交后检测页面刷新的轮询间隔（秒，可在界面上滑动调节，1~20）
  int _refreshIntervalSeconds = 2;

  /// 填入分数后等待多久再点击【提交分数】（秒，可在界面上滑动调节，1~10）
  int _submitDelaySeconds = 1;

  Duration get _refreshPollInterval =>
      Duration(seconds: _refreshIntervalSeconds);

  /// 最多轮询次数：按约 60s 总超时折算，且限制在 3~60 次
  int get _refreshMaxPolls {
    final n = (60 / _refreshIntervalSeconds).ceil();
    if (n < 3) return 3;
    if (n > 60) return 60;
    return n;
  }

  /// 与上一题截图差异大于该值 → 认为已换题
  static const double _changedThreshold = 6.0;
  /// 相邻两帧差异小于该值 → 认为页面已稳定
  static const double _stableThreshold = 3.0;

  // ---------- 自动化 ----------
  /// 自动提交分数开关（默认关闭，便于逐步测试）
  bool _autoSubmitting = false;
  /// 「学生答案区域」在屏幕逻辑坐标下的矩形
  Rect? _answerRegion;
  /// 浏览器「得分」输入框的逻辑坐标
  Offset? _scoreFieldPoint;
  /// 浏览器「提交分数」按钮的逻辑坐标
  Offset? _submitButtonPoint;
  /// 自动识别方式：local（本地 PaddleOCR）/ vision（DeepSeek 视觉）
  String _recognizeMode = 'local';

  static const String _kAutomationConfigKey = 'automation_config';

  Timer? _netTimer;
  final Map<String, DateTime> _lastClickAt = <String, DateTime>{};

  bool get _anyBusy =>
      _capturing || _ocrBusy || _vlBusy || _judgeBusy || _saving || _automating;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _refreshNetwork();
    _netTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshNetwork(),
    );
  }

  @override
  void dispose() {
    _netTimer?.cancel();
    for (final c in <TextEditingController>[
      _question,
      _studentAnswer,
      _standardAnswer,
      _totalScore,
      _teacherScore,
      _apiKey,
      _paddlePath,
      _vlModel,
      _judgeModel,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ==================== 配置 ====================

  Future<void> _loadConfig() async {
    try {
      final apiKey =
          await SqliteService.instance.getConfig(SqliteService.kApiKey) ?? '';
      final paddle =
          await SqliteService.instance.getConfig(SqliteService.kPaddleOcrPath) ??
              '';
      final vl =
          await SqliteService.instance.getConfig(SqliteService.kVlModel) ??
              SqliteService.defaultVlModel;
      final judge =
          await SqliteService.instance.getConfig(SqliteService.kJudgeModel) ??
              SqliteService.defaultJudgeModel;
      final automation =
          await SqliteService.instance.getConfig(_kAutomationConfigKey);
      if (!mounted) return;
      setState(() {
        _apiKey.text = apiKey;
        _paddlePath.text = paddle;
        _vlModel.text = vl;
        _judgeModel.text = judge;
      });
      _applyAutomationConfig(automation);
    } catch (e) {
      if (!mounted) return;
      _showError('加载配置失败', e);
    }
  }

  void _applyAutomationConfig(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final region = map['answer_region'];
      if (region is Map) {
        _answerRegion = Rect.fromLTWH(
          (region['l'] as num).toDouble(),
          (region['t'] as num).toDouble(),
          (region['w'] as num).toDouble(),
          (region['h'] as num).toDouble(),
        );
      }
      final score = map['score_field'];
      if (score is Map) {
        _scoreFieldPoint = Offset(
          (score['x'] as num).toDouble(),
          (score['y'] as num).toDouble(),
        );
      }
      final submit = map['submit_button'];
      if (submit is Map) {
        _submitButtonPoint = Offset(
          (submit['x'] as num).toDouble(),
          (submit['y'] as num).toDouble(),
        );
      }
      if (map['auto_submit'] is bool) {
        _autoSubmitting = map['auto_submit'] as bool;
      }
      if (map['recognize'] is String) {
        _recognizeMode = map['recognize'] as String;
      }
      if (map['refresh_interval_seconds'] is num) {
        final v = (map['refresh_interval_seconds'] as num).toInt();
        _refreshIntervalSeconds = v < 1 ? 1 : (v > 20 ? 20 : v);
      }
      if (map['submit_delay_seconds'] is num) {
        final v = (map['submit_delay_seconds'] as num).toInt();
        _submitDelaySeconds = v < 1 ? 1 : (v > 10 ? 10 : v);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // 配置损坏时忽略，等待重新标定
    }
  }

  Future<void> _saveAutomationConfig() async {
    final map = <String, dynamic>{
      if (_answerRegion != null)
        'answer_region': <String, double>{
          'l': _answerRegion!.left,
          't': _answerRegion!.top,
          'w': _answerRegion!.width,
          'h': _answerRegion!.height,
        },
      if (_scoreFieldPoint != null)
        'score_field': <String, double>{
          'x': _scoreFieldPoint!.dx,
          'y': _scoreFieldPoint!.dy,
        },
      if (_submitButtonPoint != null)
        'submit_button': <String, double>{
          'x': _submitButtonPoint!.dx,
          'y': _submitButtonPoint!.dy,
        },
      'auto_submit': _autoSubmitting,
      'recognize': _recognizeMode,
      'refresh_interval_seconds': _refreshIntervalSeconds,
      'submit_delay_seconds': _submitDelaySeconds,
    };
    await SqliteService.instance
        .setConfig(_kAutomationConfigKey, jsonEncode(map));
  }

  Future<void> _saveConfig() async {
    try {
      await SqliteService.instance.setConfigs(<String, String>{
        SqliteService.kApiKey: _apiKey.text.trim(),
        SqliteService.kPaddleOcrPath: _paddlePath.text.trim(),
        SqliteService.kVlModel: _vlModel.text.trim().isEmpty
            ? SqliteService.defaultVlModel
            : _vlModel.text.trim(),
        SqliteService.kJudgeModel: _judgeModel.text.trim().isEmpty
            ? SqliteService.defaultJudgeModel
            : _judgeModel.text.trim(),
      });
      if (!mounted) return;
      setState(() {});
      _toast('配置已保存');
    } catch (e) {
      if (!mounted) return;
      _showError('保存配置失败', e);
    }
  }

  // ==================== 网络 ====================

  Future<void> _refreshNetwork() async {
    final online = await NetworkService.instance.checkOnline();
    if (!mounted) return;
    if (online != _online) setState(() => _online = online);
  }

  // ==================== 通用工具 ====================

  bool _debounce(String key,
      [Duration gap = const Duration(milliseconds: 300)]) {
    final now = DateTime.now();
    final last = _lastClickAt[key];
    if (last != null && now.difference(last) < gap) return false;
    _lastClickAt[key] = now;
    return true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  String _humanize(Object e) {
    var s = e.toString();
    final key = _apiKey.text.trim();
    if (key.isNotEmpty && s.contains(key)) {
      s = s.replaceAll(key, v.maskApiKey(key));
    }
    return s;
  }

  void _showError(String title, Object e) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(_humanize(e))),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String content) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  String _formatScore(double s) {
    if (s == s.roundToDouble()) return s.toStringAsFixed(0);
    return s.toString();
  }

  /// 隐藏主窗口 → 截取整屏 → 铺满主显示器显示遮罩 → 执行 [action] → 恢复窗口。
  /// [action] 收到全屏 PNG 与显示器缩放比（像素 / 逻辑像素）。
  Future<T?> _withScreenOverlay<T>(
    Future<T?> Function(Uint8List png, double scale) action,
  ) async {
    Rect? savedBounds;
    try {
      savedBounds = await windowManager.getBounds();
      await windowManager.setOpacity(0);
      await Future<void>.delayed(const Duration(milliseconds: 260));

      final png = await ScreenshotService.instance.captureFullScreen();

      final display = await screenRetriever.getPrimaryDisplay();
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      await windowManager.setBounds(
        Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height),
      );
      await windowManager.setOpacity(1);

      if (!mounted) return null;
      final scale = (display.scaleFactor ?? 1).toDouble();
      final result = await action(png, scale);

      await windowManager.setBounds(savedBounds);
      savedBounds = null;
      return result;
    } catch (e) {
      if (savedBounds != null) {
        try {
          await windowManager.setBounds(savedBounds);
        } catch (_) {}
      }
      try {
        await windowManager.setOpacity(1);
      } catch (_) {}
      rethrow;
    }
  }

  // ==================== 框选截图 ====================

  Future<void> _captureRegion() async {
    if (_anyBusy) return;
    if (!_debounce('capture')) return;
    setState(() => _capturing = true);
    try {
      final path = await _withScreenOverlay<String?>((png, scale) async {
        final rect = await RegionSelectOverlay.show(context, png);
        if (rect == null) return null;
        return ScreenshotService.instance.cropAndSave(
          fullPng: png,
          x: rect.left.round(),
          y: rect.top.round(),
          width: rect.width.round(),
          height: rect.height.round(),
        );
      });
      if (!mounted) return;
      setState(() {
        if (path != null) _screenshotPath = path;
        _capturing = false;
      });
      if (path != null) _toast('截图已保存');
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      _showError('截图失败', e);
    }
  }

  // ==================== 自动化标定 ====================

  /// 标定「学生答案区域」（保存为屏幕逻辑坐标）
  Future<void> _calibrateAnswerRegion() async {
    if (_anyBusy) return;
    setState(() => _capturing = true);
    try {
      final region = await _withScreenOverlay<Rect?>((png, scale) async {
        final r = await RegionSelectOverlay.show(context, png);
        if (r == null) return null;
        return Rect.fromLTWH(
          r.left / scale,
          r.top / scale,
          r.width / scale,
          r.height / scale,
        );
      });
      if (!mounted) return;
      setState(() {
        if (region != null) _answerRegion = region;
        _capturing = false;
      });
      if (region != null) {
        await _saveAutomationConfig();
        _toast('学生答案区域已标定');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      _showError('标定学生答案区域失败', e);
    }
  }

  /// 标定「得分框」或「提交分数」按钮的位置（保存为屏幕逻辑坐标）
  Future<void> _calibratePoint({required bool forScoreField}) async {
    if (_anyBusy) return;
    setState(() => _capturing = true);
    try {
      final point = await _withScreenOverlay<Offset?>((png, scale) async {
        final p = await PointPickerOverlay.show(
          context,
          png,
          forScoreField ? '请单击浏览器中的「得分」输入框' : '请单击浏览器中的「提交分数」按钮',
        );
        if (p == null) return null;
        return Offset(p.dx / scale, p.dy / scale);
      });
      if (!mounted) return;
      setState(() {
        if (point != null) {
          if (forScoreField) {
            _scoreFieldPoint = point;
          } else {
            _submitButtonPoint = point;
          }
        }
        _capturing = false;
      });
      if (point != null) {
        await _saveAutomationConfig();
        _toast(forScoreField ? '得分框位置已标定' : '提交按钮位置已标定');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _capturing = false);
      _showError('标定位置失败', e);
    }
  }

  // ==================== 自动阅卷 ====================

  /// 清除已保存的标定坐标
  Future<void> _clearCalibration() async {
    if (_anyBusy) return;
    final ok = await _confirm(
      '清除标定',
      '将清除已保存的学生答案区域、得分框、提交按钮坐标，是否继续？',
    );
    if (!mounted) return;
    if (!ok) return;
    setState(() {
      _answerRegion = null;
      _scoreFieldPoint = null;
      _submitButtonPoint = null;
    });
    await _saveAutomationConfig();
    if (!mounted) return;
    _toast('标定已清除');
  }

  /// 检查关键坐标是否已标定：已标定则直接返回 true（不重复标定）；
  /// 未标定才进入引导式标定向导（一次全屏截图，逐步点选/框选）。
  Future<bool> _ensureCalibrated() async {
    final needSubmit = _autoSubmitting;
    final complete = _answerRegion != null &&
        _scoreFieldPoint != null &&
        (!needSubmit || _submitButtonPoint != null);
    if (complete) return true;
    if (_anyBusy) return false;

    setState(() => _capturing = true);
    double usedScale = 1;
    try {
      final result =
          await _withScreenOverlay<CalibrationResult?>((png, scale) async {
        usedScale = scale;
        return CalibrationWizardOverlay.show(
          context,
          png,
          needSubmitButton: needSubmit,
        );
      });
      if (!mounted) return false;
      setState(() => _capturing = false);
      if (result == null) return false;

      final s = usedScale;
      setState(() {
        if (result.scoreField != null) {
          _scoreFieldPoint =
              Offset(result.scoreField!.dx / s, result.scoreField!.dy / s);
        }
        if (result.submitButton != null) {
          _submitButtonPoint =
              Offset(result.submitButton!.dx / s, result.submitButton!.dy / s);
        }
        if (result.answerRegion != null) {
          final r = result.answerRegion!;
          _answerRegion = Rect.fromLTWH(
            r.left / s,
            r.top / s,
            r.width / s,
            r.height / s,
          );
        }
      });
      await _saveAutomationConfig();
      return _answerRegion != null &&
          _scoreFieldPoint != null &&
          (!needSubmit || _submitButtonPoint != null);
    } catch (e) {
      if (!mounted) return false;
      setState(() => _capturing = false);
      _showError('标定失败', e);
      return false;
    }
  }

  /// 点【开始】自动处理当前这一题：
  /// 按标定区域截图 → 识别 → 判分 → 模拟填分到浏览器 →（可选）自动提交 → 落库。
  Future<void> _startAutomation() async {
    if (_anyBusy) return;
    if (!_debounce('auto')) return;
    if (!_online) {
      _toast('当前网络不可用');
      return;
    }
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先在配置面板填写 DeepSeek API Key');
      return;
    }
    final total = v.parseScore(_totalScore.text);
    if (total == null || total <= 0) {
      _toast('请先填写有效的「该题的总分」');
      return;
    }
    if (_standardAnswer.text.trim().isEmpty) {
      _toast('请先填写「标准答案」');
      return;
    }

    // 本地 OCR 未配置时，提供改用视觉识别的入口
    if (_recognizeMode == 'local' && _paddlePath.text.trim().isEmpty) {
      final useVision = await _confirm(
        '未配置本地 OCR',
        '识别方式是「本地OCR」，但还没配置本地 OCR 程序路径。\n\n'
            '· 点【取消】→ 到配置面板填写程序路径后重试（仓库自带 '
            'tools/ocr_vision/bin/ocr_vision，可先编译再用）；\n'
            '· 点【确认】→ 本次改用「视觉」识别（会将截图上传 DeepSeek）。',
      );
      if (!mounted) return;
      if (!useVision) return;
      setState(() => _recognizeMode = 'vision');
      await _saveAutomationConfig();
    }

    // 已标定则直接阅卷；未标定才进入引导式标定
    if (!await _ensureCalibrated()) return;
    if (!mounted) return;

    if (MacInputService.instance.isSupported &&
        !MacInputService.instance.hasAccessibilityPermission) {
      await _confirm(
        '需要「辅助功能」权限',
        '自动填写分数需要 macOS 的「辅助功能」权限。\n'
            '请到「系统设置 → 隐私与安全性 → 辅助功能」中勾选本应用后重试。',
      );
      return;
    }

    setState(() {
      _automating = true;
      _batchRunning = _autoSubmitting;
      _processedCount = 0;
    });
    var stoppedByUser = false;
    var refreshTimeout = false;
    try {
      await _processOneQuestion(total);
      // 连续批阅：阅卷系统会自动跳到下一题，等页面刷新后再处理下一题
      while (_batchRunning) {
        final advanced = await _waitForPageRefresh();
        if (!mounted) return;
        if (!_batchRunning) {
          stoppedByUser = true;
          break;
        }
        if (!advanced) {
          refreshTimeout = true;
          break;
        }
        setState(() {
          _processedCount++;
          _clearForm();
        });
        await _processOneQuestion(total);
      }
      if (!mounted) return;
      final count = _processedCount + 1;
      if (refreshTimeout) {
        _toast('检测不到页面刷新，已停止连续批阅（共批 $count 题）');
      } else if (stoppedByUser) {
        _toast('已停止连续批阅（共批 $count 题）');
      } else if (_autoSubmitting) {
        _toast('连续批阅结束（共批 $count 题）');
      } else {
        _toast('自动阅卷完成：已填分（未提交）');
      }
    } catch (e) {
      if (mounted) _showError('自动阅卷失败', e);
    } finally {
      // 截图阶段可能把窗口设为不可见，这里确保恢复
      try {
        await windowManager.setOpacity(1);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _automating = false;
          _batchRunning = false;
        });
      }
    }
  }

  /// 停止连续批阅（当前题处理完后结束）
  void _stopBatch() {
    if (!_batchRunning) return;
    setState(() => _batchRunning = false);
    _toast('已请求停止，本題处理完后结束');
  }

  /// 处理当前这一题：截图 → 识别 → 判分 → 填分（含可选提交）→ 落库。
  Future<void> _processOneQuestion(double total) async {
    // 1) 按标定区域截图（先隐藏本窗口，避免入镜）
    await windowManager.setOpacity(0);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final full = await ScreenshotService.instance.captureFullScreen();
    await windowManager.setOpacity(1);

    final display = await screenRetriever.getPrimaryDisplay();
    final scale = (display.scaleFactor ?? 1).toDouble();
    final region = _answerRegion!;
    final bytes = ScreenshotService.instance.cropToPng(
      fullPng: full,
      x: (region.left * scale).round(),
      y: (region.top * scale).round(),
      width: (region.width * scale).round(),
      height: (region.height * scale).round(),
    );
    _lastAnswerPng = bytes;
    final path = await ScreenshotService.instance.saveScreenshotPng(bytes);
    if (!mounted) return;
    setState(() => _screenshotPath = path);

    // 2) 识别（试卷没有「题目」，识别结果直接作为学生答案）
    if (_recognizeMode == 'vision') {
      final res = await DeepSeekVlService.instance.recognize(
        apiKey: _apiKey.text.trim(),
        imagePath: path,
        model: _vlModel.text.trim().isEmpty
            ? DeepSeekVlService.defaultModel
            : _vlModel.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _studentAnswer.text = res.studentAnswer.trim().isEmpty
            ? res.question
            : res.studentAnswer;
        _question.text = '';
        _ocrSource = OcrSource.deepseekVl;
      });
    } else {
      if (_paddlePath.text.trim().isEmpty) {
        throw OcrException('未配置本地 OCR 程序路径');
      }
      final res = await PaddleOcrService.instance.recognize(
        ocrBinaryPath: _paddlePath.text.trim(),
        imagePath: path,
      );
      if (!mounted) return;
      setState(() {
        _studentAnswer.text = res.fullText;
        _question.text = '';
        _ocrSource = OcrSource.localPaddle;
      });
    }

    // 3) 判分
    final judge = await DeepSeekJudgeService.instance.judge(
      apiKey: _apiKey.text.trim(),
      question: _question.text,
      studentAnswer: _studentAnswer.text,
      standardAnswer: _standardAnswer.text,
      totalScore: total,
      model: _judgeModel.text.trim().isEmpty
          ? DeepSeekJudgeService.defaultModel
          : _judgeModel.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _aiScore = judge.score;
      _teacherScore.text = _formatScore(judge.score);
    });

    // 4) 把分数写回浏览器「得分」框（模拟点击 + 键盘输入），并按开关自动提交
    await _writeScoreToBrowser(judge.score);

    // 5) 落库
    await SqliteService.instance.insertRecord(
      QuestionRecord(
        question: _question.text,
        studentAnswer: _studentAnswer.text,
        standardAnswer: _standardAnswer.text,
        totalScore: total,
        aiScore: judge.score,
        teacherScore: v.parseScore(_teacherScore.text) ?? judge.score,
        screenshotPath: path,
        ocrSource: _ocrSource,
        createTime: v.isoNow(),
      ),
    );
  }

  /// 提交后等待页面自动跳到下一题：
  /// 按 [_refreshPollInterval] 轮询截图，答案区与上一题差异明显、
  /// 且随后连续两帧稳定时，认为新题已加载完成。
  Future<bool> _waitForPageRefresh() async {
    final baseline = _lastAnswerPng;
    final region = _answerRegion;
    if (baseline == null || region == null) return false;

    await Future<void>.delayed(_refreshPollInterval);
    Uint8List? last;
    for (var i = 0; i < _refreshMaxPolls; i++) {
      if (!mounted || !_batchRunning) return false;

      Uint8List shot;
      try {
        final full = await ScreenshotService.instance.captureFullScreen();
        final display = await screenRetriever.getPrimaryDisplay();
        final scale = (display.scaleFactor ?? 1).toDouble();
        shot = ScreenshotService.instance.cropToPng(
          fullPng: full,
          x: (region.left * scale).round(),
          y: (region.top * scale).round(),
          width: (region.width * scale).round(),
          height: (region.height * scale).round(),
        );
      } catch (_) {
        return false;
      }

      final vsBaseline = averagePixelDifference(baseline, shot) ?? 0;
      final vsLast =
          last == null ? 0.0 : (averagePixelDifference(last, shot) ?? 0);

      if (vsBaseline > _changedThreshold &&
          last != null &&
          vsLast < _stableThreshold) {
        LogService.instance.add(
          '↻ 页面已刷新',
          '与上一题差异 ${vsBaseline.toStringAsFixed(1)}、相邻帧差异 ${vsLast.toStringAsFixed(1)}',
        );
        return true;
      }
      last = shot;
      await Future<void>.delayed(_refreshPollInterval);
    }
    return false;
  }

  // ==================== 本地 OCR ====================

  Future<void> _localOcr() async {
    if (_anyBusy) return;
    if (!_debounce('ocr')) return;
    if (_screenshotPath.isEmpty) {
      _toast('请先框选截图');
      return;
    }
    if (_paddlePath.text.trim().isEmpty) {
      _toast('请先在配置面板填写本地 OCR 程序路径');
      return;
    }

    setState(() => _ocrBusy = true);
    try {
      final result = await PaddleOcrService.instance.recognize(
        ocrBinaryPath: _paddlePath.text.trim(),
        imagePath: _screenshotPath,
      );
      if (!mounted) return;
      setState(() {
        // 试卷没有「题目」，识别结果直接作为学生答案；题目留空
        _studentAnswer.text = result.fullText;
        _question.text = '';
        _ocrSource = OcrSource.localPaddle;
        _ocrBusy = false;
      });
      _toast('本地 OCR 完成');
    } catch (e) {
      if (!mounted) return;
      setState(() => _ocrBusy = false);
      _showError('本地 OCR 失败', e);
    }
  }

  // ==================== DeepSeek 视觉重识别 ====================

  Future<void> _vlRecognize() async {
    if (_anyBusy) return;
    if (!_debounce('vl')) return;
    if (!_online) {
      _toast('当前网络不可用');
      return;
    }
    if (_screenshotPath.isEmpty) {
      _toast('请先框选截图');
      return;
    }
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先在配置面板填写 DeepSeek API Key');
      return;
    }

    final ok = await _confirm(
      '确认上传截图',
      '本次操作会将当前截图上传至 DeepSeek 服务器进行识别，是否继续？',
    );
    if (!mounted) return;
    if (!ok) return;

    setState(() => _vlBusy = true);
    try {
      final res = await DeepSeekVlService.instance.recognize(
        apiKey: _apiKey.text.trim(),
        imagePath: _screenshotPath,
        model: _vlModel.text.trim().isEmpty
            ? DeepSeekVlService.defaultModel
            : _vlModel.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        // 试卷没有「题目」，识别结果直接作为学生答案；题目留空
        _studentAnswer.text = res.studentAnswer.trim().isEmpty
            ? res.question
            : res.studentAnswer;
        _question.text = '';
        _ocrSource = OcrSource.deepseekVl;
        _vlBusy = false;
      });
      _toast('DeepSeek 视觉识别完成');
    } catch (e) {
      if (!mounted) return;
      setState(() => _vlBusy = false);
      _showError('视觉识别失败', e);
    }
  }

  // ==================== AI 判分 ====================

  Future<void> _judge() async {
    if (_anyBusy) return;
    if (!_debounce('judge')) return;
    if (!_online) {
      _toast('当前网络不可用');
      return;
    }
    if (_apiKey.text.trim().isEmpty) {
      _toast('请先在配置面板填写 DeepSeek API Key');
      return;
    }
    final total = v.parseScore(_totalScore.text);
    if (total == null || total <= 0) {
      _toast('请先填写有效的「该题的总分」');
      return;
    }

    setState(() => _judgeBusy = true);
    try {
      final res = await DeepSeekJudgeService.instance.judge(
        apiKey: _apiKey.text.trim(),
        question: _question.text,
        studentAnswer: _studentAnswer.text,
        standardAnswer: _standardAnswer.text,
        totalScore: total,
        model: _judgeModel.text.trim().isEmpty
            ? DeepSeekJudgeService.defaultModel
            : _judgeModel.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _aiScore = res.score;
        // 老师给的分数默认填充 AI 分数，教师可自由修改
        _teacherScore.text = _formatScore(res.score);
      });
      _toast('AI 判分完成：${_formatScore(res.score)} 分');
      // 判分后自动把分数填回浏览器「得分」框
      await _writeScoreAfterJudge(res.score);
      if (!mounted) return;
      setState(() => _judgeBusy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _judgeBusy = false);
      _showError('AI 判分失败', e);
    }
  }

  /// 模拟点击「得分」框 → 清空 → 键盘输入分数；若开启自动提交再点提交按钮。
  Future<bool> _writeScoreToBrowser(double score) async {
    final input = MacInputService.instance;
    final point = _scoreFieldPoint!;
    final text = _formatScore(score);
    LogService.instance.add(
      '→ 模拟填分',
      '双击得分框 (${point.dx.round()}, ${point.dy.round()}) 并输入「$text」'
      '${_autoSubmitting ? '，随后提交' : ''}',
    );

    // 输入前后截取得分框附近小区域，用于确认数字是否真的写进去了
    final before = await _captureAround(point);
    // 点两次：第一次只激活浏览器窗口，第二次才真正把光标落到输入框
    // （否则紧接着的 Cmd+A 会变成"全选整个网页"）
    await input.click(point.dx, point.dy, taps: 2);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // 清掉可能仍处于按下状态的修饰键（避免数字被当成 Cmd+数字 快捷键）
    await input.releaseModifiers();
    await input.selectAllAndClear();
    // 用剪贴板粘贴输入分数：不受键盘布局 / Unicode 注入限制，网页输入框几乎必成
    await Clipboard.setData(ClipboardData(text: text));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await input.paste();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final after = await _captureAround(point);

    var verified = true;
    if (before != null && after != null) {
      final diff = averagePixelDifference(before, after) ?? 0;
      verified = diff > 1.0;
      LogService.instance.add(
        verified ? '✓ 填分校验' : '⚠ 填分校验',
        '得分框区域像素变化 ${diff.toStringAsFixed(2)}'
            '（${verified ? '数字已写入' : '几乎无变化，可能没写进去'}）',
      );
    }

    if (_autoSubmitting && _submitButtonPoint != null) {
      // 按「提交延迟」等待一段时间再点提交（模拟人工节奏）
      await Future<void>.delayed(Duration(seconds: _submitDelaySeconds));
      LogService.instance.add(
        '→ 提交分数',
        '等待 ${_submitDelaySeconds}s 后点击提交按钮 '
            '(${_submitButtonPoint!.dx.round()}, ${_submitButtonPoint!.dy.round()})',
      );
      await input.click(_submitButtonPoint!.dx, _submitButtonPoint!.dy);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return verified;
  }

  /// 截取以屏幕逻辑坐标 [point] 为中心的一小块区域（用于校验输入是否生效）
  Future<Uint8List?> _captureAround(Offset point) async {
    const double halfW = 90;
    const double halfH = 28;
    try {
      final full = await ScreenshotService.instance.captureFullScreen();
      final display = await screenRetriever.getPrimaryDisplay();
      final scale = (display.scaleFactor ?? 1).toDouble();
      return ScreenshotService.instance.cropToPng(
        fullPng: full,
        x: ((point.dx - halfW) * scale).round(),
        y: ((point.dy - halfH) * scale).round(),
        width: (halfW * 2 * scale).round(),
        height: (halfH * 2 * scale).round(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 手动【AI 判分】后的自动填分：前置条件不满足时给提示而不是抛错。
  Future<void> _writeScoreAfterJudge(double score) async {
    if (_scoreFieldPoint == null) {
      _toast('已判分；未标定「得分框」，未填入浏览器');
      return;
    }
    if (_autoSubmitting && _submitButtonPoint == null) {
      _toast('已判分；已开启自动提交但未标定「提交按钮」');
      return;
    }
    if (MacInputService.instance.isSupported &&
        !MacInputService.instance.hasAccessibilityPermission) {
      _toast('已判分；缺少「辅助功能」权限，未自动填入');
      return;
    }
    try {
      final ok = await _writeScoreToBrowser(score);
      if (!mounted) return;
      _toast(ok
          ? (_autoSubmitting ? '已判分并填入「得分」框、已提交' : '已判分并填入「得分」框')
          : '已判分，但得分框未检测到变化，请检查标定位置与「辅助功能」权限');
    } catch (e) {
      if (!mounted) return;
      _showError('自动填分失败', e);
    }
  }

  // ==================== 保存 / 下一题 ====================

  Future<void> _save() async {
    if (_saving) return;
    if (!_debounce('save')) return;
    setState(() => _saving = true);
    try {
      final record = QuestionRecord(
        question: _question.text,
        studentAnswer: _studentAnswer.text,
        standardAnswer: _standardAnswer.text,
        totalScore: v.parseScore(_totalScore.text) ?? 0,
        aiScore: _aiScore,
        teacherScore: v.parseScore(_teacherScore.text) ?? 0,
        screenshotPath: _screenshotPath,
        ocrSource: _ocrSource,
        createTime: v.isoNow(),
      );
      final id = await SqliteService.instance.insertRecord(record);
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('已保存本题（记录 #$id）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError('保存失败', e);
    }
  }

  bool get _hasUnsavedInput =>
      _question.text.trim().isNotEmpty ||
      _studentAnswer.text.trim().isNotEmpty ||
      _standardAnswer.text.trim().isNotEmpty ||
      _totalScore.text.trim().isNotEmpty ||
      _teacherScore.text.trim().isNotEmpty ||
      _screenshotPath.isNotEmpty;

  Future<void> _nextQuestion() async {
    if (_anyBusy) return;
    if (_hasUnsavedInput) {
      final ok = await _confirm('放弃当前内容？', '当前表单仍有内容未保存，确认清空进入下一题？');
      if (!mounted) return;
      if (!ok) return;
    }
    setState(_clearForm);
    _toast('已清空，等待下一题');
  }

  void _clearForm() {
    _question.clear();
    _studentAnswer.clear();
    _teacherScore.clear();
    _aiScore = 0;
    _screenshotPath = '';
    _ocrSource = '';
    // 保留【标准答案】与【该题的总分】：同一份试卷每题一致，一次录入即可复用
  }

  Future<void> _toggleAlwaysOnTop() async {
    _alwaysOnTop = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(_alwaysOnTop);
    if (!mounted) return;
    setState(() {});
  }

  // ==================== 构建 UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅卷辅助小助手', style: TextStyle(fontSize: 16)),
        toolbarHeight: 44,
        actions: <Widget>[
          IconButton(
            tooltip: _online ? '网络正常（点击刷新）' : '网络不可用（点击重试）',
            icon: Icon(
              _online ? Icons.wifi : Icons.wifi_off,
              color: _online ? Colors.green : Colors.redAccent,
            ),
            onPressed: () async {
              await NetworkService.instance.checkOnline(force: true);
              await _refreshNetwork();
            },
          ),
          IconButton(
            tooltip: _alwaysOnTop ? '取消置顶' : '窗口置顶',
            icon: Icon(
              _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
            ),
            onPressed: _toggleAlwaysOnTop,
          ),
          IconButton(
            tooltip: '最小化',
            icon: const Icon(Icons.remove),
            onPressed: () => windowManager.minimize(),
          ),
        ],
      ),
      body: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildAutomationPanel(),
              const SizedBox(height: 10),
              _buildPreview(),
              const SizedBox(height: 10),
              _buildActionRow(),
              const SizedBox(height: 4),
              _labeledField('题目', _question, initialHeight: 72),
              _labeledField('学生答案', _studentAnswer, initialHeight: 120),
              _labeledField('标准答案（教师录入）', _standardAnswer,
                  initialHeight: 84),
              _labeledNumberField('该题的总分', _totalScore),
              const SizedBox(height: 8),
              _buildJudgeButton(),
              const SizedBox(height: 8),
              _buildAiScoreBox(),
              const SizedBox(height: 8),
              _labeledNumberField('老师给的分数（最终成绩）', _teacherScore),
              const SizedBox(height: 8),
              _buildSaveRow(),
              const SizedBox(height: 12),
              _buildConfigPanel(),
              const SizedBox(height: 12),
              _buildLogPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutomationPanel() {
    final theme = Theme.of(context);
    final regionReady = _answerRegion != null;
    final scoreReady = _scoreFieldPoint != null;
    final submitReady = _submitButtonPoint != null;
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _batchRunning
                      ? FilledButton.icon(
                          onPressed: _stopBatch,
                          icon: const Icon(Icons.stop, size: 18),
                          label: Text('停止（已批 ${_processedCount + 1} 题）'),
                        )
                      : FilledButton.icon(
                          onPressed: _anyBusy ? null : _startAutomation,
                          icon: _automating
                              ? const _MiniSpinner()
                              : const Icon(Icons.play_arrow, size: 18),
                          label: const Text('开始自动阅卷'),
                        ),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('连续批阅', style: TextStyle(fontSize: 11)),
                    Switch(
                      value: _autoSubmitting,
                      onChanged: _anyBusy
                          ? null
                          : (val) {
                              setState(() => _autoSubmitting = val);
                              _saveAutomationConfig();
                            },
                    ),
                  ],
                ),
              ],
            ),
            Text(
              _autoSubmitting
                  ? '已开启：判分后自动填分并提交，自动翻到下一题连续批阅'
                  : '已关闭：只处理当前题，填分但不提交、不翻页',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: <Widget>[
                Text('刷新间隔', style: theme.textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: _refreshIntervalSeconds.toDouble(),
                    min: 1,
                    max: 20,
                    divisions: 19,
                    label: '$_refreshIntervalSeconds 秒',
                    onChanged: _anyBusy
                        ? null
                        : (val) => setState(
                              () => _refreshIntervalSeconds = val.round(),
                            ),
                    onChangeEnd: (_) => _saveAutomationConfig(),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${_refreshIntervalSeconds}s',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Text('提交延迟', style: theme.textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: _submitDelaySeconds.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: '$_submitDelaySeconds 秒',
                    onChanged: _anyBusy
                        ? null
                        : (val) => setState(
                              () => _submitDelaySeconds = val.round(),
                            ),
                    onChangeEnd: (_) => _saveAutomationConfig(),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${_submitDelaySeconds}s',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Text('识别方式：', style: theme.textTheme.bodySmall),
                const SizedBox(width: 6),
                SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(value: 'local', label: Text('本地OCR')),
                    ButtonSegment<String>(value: 'vision', label: Text('视觉')),
                  ],
                  selected: <String>{_recognizeMode},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStatePropertyAll<TextStyle>(
                      TextStyle(fontSize: 12),
                    ),
                  ),
                  onSelectionChanged: _anyBusy
                      ? null
                      : (selection) {
                          setState(() => _recognizeMode = selection.first);
                          _saveAutomationConfig();
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '标定：学生答案区域 ${regionReady ? "✓" : "—"} · '
              '得分框 ${scoreReady ? "✓" : "—"} · '
              '提交按钮 ${submitReady ? "✓" : "—"}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _anyBusy ? null : _calibrateAnswerRegion,
                  child: const Text('标定学生答案区域', style: TextStyle(fontSize: 12)),
                ),
                OutlinedButton(
                  onPressed: _anyBusy
                      ? null
                      : () => _calibratePoint(forScoreField: true),
                  child: const Text('标定得分框', style: TextStyle(fontSize: 12)),
                ),
                OutlinedButton(
                  onPressed: _anyBusy
                      ? null
                      : () => _calibratePoint(forScoreField: false),
                  child: const Text('标定提交按钮', style: TextStyle(fontSize: 12)),
                ),
                OutlinedButton(
                  onPressed: _anyBusy ? null : _clearCalibration,
                  child: const Text('清除标定', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final path = _screenshotPath;
    final hasImage = path.isNotEmpty && File(path).existsSync();
    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.file(File(path), fit: BoxFit.contain)
          : Center(
              child: Text(
                _capturing ? '正在截图…' : '尚未截图，点击【框选截图】选取学生答案区域',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _anyBusy ? null : _captureRegion,
            icon: _capturing
                ? const _MiniSpinner()
                : const Icon(Icons.crop, size: 16),
            label: const Text('框选截图', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            onPressed:
                _anyBusy || _screenshotPath.isEmpty ? null : _localOcr,
            icon: _ocrBusy
                ? const _MiniSpinner()
                : const Icon(Icons.text_snippet_outlined, size: 16),
            label: const Text('本地 OCR', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _anyBusy || !_online || _screenshotPath.isEmpty
                ? null
                : _vlRecognize,
            icon: _vlBusy
                ? const _MiniSpinner()
                : const Icon(Icons.visibility_outlined, size: 16),
            label: const Text('视觉重识别', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _buildJudgeButton() {
    return FilledButton.icon(
      onPressed: _anyBusy || !_online ? null : _judge,
      icon: _judgeBusy
          ? const _MiniSpinner()
          : const Icon(Icons.auto_awesome, size: 18),
      label: const Text('AI 判分'),
    );
  }

  Widget _buildAiScoreBox() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          const Text('AI 给的分数'),
          Text(
            _formatScore(_aiScore),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            onPressed: _anyBusy ? null : _save,
            icon: _saving
                ? const _MiniSpinner()
                : const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存本题'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _anyBusy ? null : _nextQuestion,
            icon: const Icon(Icons.skip_next, size: 18),
            label: const Text('下一题'),
          ),
        ),
      ],
    );
  }

  Widget _buildLogPanel() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text('日志', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          '记录发给 AI 的内容与识别结果（最近 ${LogService.maxEntries} 条）',
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: <Widget>[
          ListenableBuilder(
            listenable: LogService.instance,
            builder: (context, _) {
              final entries = LogService.instance.entries;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '共 ${entries.length} 条',
                        style: theme.textTheme.bodySmall,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _copyLogs,
                        child: const Text('复制', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () => LogService.instance.clear(),
                        child: const Text('清空', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 220,
                    child: entries.isEmpty
                        ? const Center(
                            child: Text(
                              '暂无日志',
                              style: TextStyle(fontSize: 12),
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry =
                                  entries[entries.length - 1 - index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: SelectableText(
                                  '[${entry.timeText}] ${entry.tag}\n${entry.message}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    height: 1.3,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: LogService.instance.asText()));
    if (!mounted) return;
    _toast('日志已复制到剪贴板');
  }

  Widget _buildConfigPanel() {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: _configExpanded,
        onExpansionChanged: (v) => _configExpanded = v,
        title: const Text('配置', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          'API Key：${_apiKey.text.trim().isEmpty ? '未设置' : v.maskApiKey(_apiKey.text.trim())}',
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: <Widget>[
          TextField(
            controller: _apiKey,
            obscureText: _obscureKey,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'DeepSeek API Key',
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _paddlePath,
            decoration: const InputDecoration(
              labelText: '本地 OCR 程序路径',
              hintText: 'tools/ocr_vision/bin/ocr_vision',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _vlModel,
            decoration: const InputDecoration(
              labelText: '视觉识别模型名',
              hintText: 'deepseek-flash',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _judgeModel,
            decoration: const InputDecoration(
              labelText: '判分模型名',
              hintText: 'deepseek-v4-pro',
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: _saveConfig,
                  child: const Text('保存配置'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _clearScreenshots,
                  child: const Text('清理截图'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _clearScreenshots() async {
    final ok = await _confirm('清理历史截图', '将删除 screenshots 目录下的所有截图，是否继续？');
    if (!mounted) return;
    if (!ok) return;
    try {
      final count = await ScreenshotService.instance.clearAllScreenshots();
      if (!mounted) return;
      _toast('已清理 $count 个截图文件');
    } catch (e) {
      if (!mounted) return;
      _showError('清理截图失败', e);
    }
  }

  Widget _labeledField(
    String label,
    TextEditingController controller, {
    double initialHeight = 84,
  }) {
    return _ResizableField(
      label: label,
      controller: controller,
      initialHeight: initialHeight,
    );
  }

  Widget _labeledNumberField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// 按钮内的小号加载指示器
class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

/// 可拖拽调整高度的多行文本框（拖动下方横条即可拉长/缩短）。
class _ResizableField extends StatefulWidget {
  const _ResizableField({
    required this.label,
    required this.controller,
    this.initialHeight = 84,
  });

  static const double minHeight = 56;
  static const double maxHeight = 480;

  final String label;
  final TextEditingController controller;
  final double initialHeight;

  @override
  State<_ResizableField> createState() => _ResizableFieldState();
}

class _ResizableFieldState extends State<_ResizableField> {
  late double _height = widget.initialHeight;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _height = (_height + details.delta.dy)
          .clamp(_ResizableField.minHeight, _ResizableField.maxHeight)
          .toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: _height,
            child: TextField(
              controller: widget.controller,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                labelText: widget.label,
                alignLabelWithHint: true,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: _onDragUpdate,
              child: Tooltip(
                message: '上下拖动调整高度',
                child: SizedBox(
                  height: 18,
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
