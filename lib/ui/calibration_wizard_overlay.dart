import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 标定向导结果（均为截图图像像素坐标，调用方再按缩放比换算）
class CalibrationResult {
  /// 浏览器「得分」输入框
  final Offset? scoreField;

  /// 浏览器「提交分数」按钮
  final Offset? submitButton;

  /// 学生答案区域
  final Rect? answerRegion;

  const CalibrationResult({
    this.scoreField,
    this.submitButton,
    this.answerRegion,
  });
}

enum _StepKind { scoreField, submitButton, answerRegion }

/// 引导式标定：在**同一次**全屏截图上依次标定
/// 「得分框」→「提交按钮」→「学生答案区域」。
///
/// - 前两步为单击取点，点完**自动跳到下一步**；
/// - 最后一步为拖拽框选，松手即视为完成；
/// - 全部完成后底部出现【重新标定】【确认标定】两个按钮。
class CalibrationWizardOverlay extends StatefulWidget {
  final Uint8List screenshotPng;

  /// 是否需要标定「提交分数」按钮（仅开启自动提交时）
  final bool needSubmitButton;

  const CalibrationWizardOverlay({
    super.key,
    required this.screenshotPng,
    required this.needSubmitButton,
  });

  static Future<CalibrationResult?> show(
    BuildContext context,
    Uint8List png, {
    required bool needSubmitButton,
  }) {
    return Navigator.of(context, rootNavigator: true).push<CalibrationResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CalibrationWizardOverlay(
          screenshotPng: png,
          needSubmitButton: needSubmitButton,
        ),
      ),
    );
  }

  @override
  State<CalibrationWizardOverlay> createState() =>
      _CalibrationWizardOverlayState();
}

class _CalibrationWizardOverlayState extends State<CalibrationWizardOverlay> {
  ui.Image? _decoded;
  Size _imageSize = Size.zero;

  int _step = 0;
  bool _finished = false;

  Offset? _scoreField; // 图像坐标
  Offset? _submitButton; // 图像坐标
  Offset? _answerStart; // 组件坐标
  Offset? _answerCurrent; // 组件坐标
  Offset? _hover; // 准星（组件坐标）

  late final List<_StepKind> _steps = <_StepKind>[
    _StepKind.scoreField,
    if (widget.needSubmitButton) _StepKind.submitButton,
    _StepKind.answerRegion,
  ];

  _StepKind get _currentKind => _steps[_step];

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.screenshotPng);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _decoded = frame.image;
      _imageSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    });
  }

  // ---------- 坐标换算 ----------

  double _fitScale(Size box) {
    if (_imageSize == Size.zero) return 1;
    final sx = box.width / _imageSize.width;
    final sy = box.height / _imageSize.height;
    return sx < sy ? sx : sy;
  }

  Rect _imageRect(Size box) {
    final s = _fitScale(box);
    final w = _imageSize.width * s;
    final h = _imageSize.height * s;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Offset _toImage(Offset p, Size box) {
    final s = _fitScale(box);
    final r = _imageRect(box);
    return Offset((p.dx - r.left) / s, (p.dy - r.top) / s);
  }

  Offset _toWidget(Offset p, Size box) {
    final s = _fitScale(box);
    final r = _imageRect(box);
    return Offset(r.left + p.dx * s, r.top + p.dy * s);
  }

  /// 已框选的答题区（组件坐标）
  Rect? get _answerRegionWidget {
    final a = _answerStart;
    final b = _answerCurrent;
    if (a == null || b == null) return null;
    final r = Rect.fromPoints(a, b);
    if (r.width < 2 || r.height < 2) return null;
    return r;
  }

  // ---------- 交互 ----------

  String _hintFor(_StepKind kind) {
    switch (kind) {
      case _StepKind.scoreField:
        return '请单击浏览器里的「得分」输入框';
      case _StepKind.submitButton:
        return '请单击浏览器里的「提交分数」按钮';
      case _StepKind.answerRegion:
        return '请拖拽框选学生的答案区域';
    }
  }

  void _handleTap(Offset local, Size box) {
    final img = _toImage(local, box);
    setState(() {
      if (_currentKind == _StepKind.scoreField) {
        _scoreField = img;
      } else if (_currentKind == _StepKind.submitButton) {
        _submitButton = img;
      }
    });
    _advanceAfterTap();
  }

  /// 点选完成后自动进入下一步（最后一步是框选，不在此处理）
  void _advanceAfterTap() {
    if (_step >= _steps.length - 1) return;
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _step++);
    });
  }

  void _finishRegion() {
    if (_answerRegionWidget == null) return;
    setState(() => _finished = true);
  }

  void _restart() {
    setState(() {
      _step = 0;
      _finished = false;
      _scoreField = null;
      _submitButton = null;
      _answerStart = null;
      _answerCurrent = null;
    });
  }

  bool get _isComplete =>
      _scoreField != null &&
      _answerRegionWidget != null &&
      (!widget.needSubmitButton || _submitButton != null);

  void _confirm(Size box) {
    final region = _answerRegionWidget;
    if (_scoreField == null || region == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先完成三步标定')),
      );
      return;
    }
    Navigator.of(context).pop(
      CalibrationResult(
        scoreField: _scoreField,
        submitButton: _submitButton,
        answerRegion: Rect.fromPoints(
          _toImage(region.topLeft, box),
          _toImage(region.bottomRight, box),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final box = Size(constraints.maxWidth, constraints.maxHeight);
              final regionStep =
                  _currentKind == _StepKind.answerRegion && !_finished;
              return MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: (e) => setState(() => _hover = e.localPosition),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (_decoded != null)
                      CustomPaint(
                        painter: _ScreenshotPainter(
                          image: _decoded!,
                          scale: _fitScale(box),
                        ),
                      )
                    else
                      const Center(child: CircularProgressIndicator()),

                    // 已框选 / 正在框选的答案区域
                    if (_answerRegionWidget case final r?)
                      Positioned.fromRect(
                        rect: r,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.greenAccent.withValues(alpha: 0.18),
                              border: Border.all(
                                color: Colors.greenAccent,
                                width: 2,
                              ),
                            ),
                            child: const Align(
                              alignment: Alignment.topLeft,
                              child: _Tag(text: '学生答案区域', color: Colors.green),
                            ),
                          ),
                        ),
                      ),

                    // 已标定的得分框 / 提交按钮
                    if (_scoreField != null)
                      _marker(box, _scoreField!, '得分框', Colors.cyan),
                    if (_submitButton != null)
                      _marker(box, _submitButton!, '提交按钮', Colors.orange),

                    // 鼠标准星
                    if (_hover != null) ...<Widget>[
                      Positioned(
                        left: _hover!.dx - 1,
                        top: 0,
                        child: Container(
                          width: 2,
                          height: box.height,
                          color: Colors.white24,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: _hover!.dy - 1,
                        child: Container(
                          width: box.width,
                          height: 2,
                          color: Colors.white24,
                        ),
                      ),
                    ],

                    // 手势层
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (!_finished && !regionStep)
                          ? (d) => _handleTap(d.localPosition, box)
                          : null,
                      onPanStart: regionStep
                          ? (d) => setState(() {
                                _answerStart = d.localPosition;
                                _answerCurrent = d.localPosition;
                              })
                          : null,
                      onPanUpdate: regionStep
                          ? (d) =>
                              setState(() => _answerCurrent = d.localPosition)
                          : null,
                      onPanEnd: regionStep ? (_) => _finishRegion() : null,
                    ),

                    _buildTopHint(),
                    _buildBottomBar(box),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _marker(Size box, Offset imagePoint, String text, Color color) {
    final p = _toWidget(imagePoint, box);
    return Positioned(
      left: p.dx - 7,
      top: p.dy - 7,
      child: IgnorePointer(
        child: Row(
          children: <Widget>[
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
            const SizedBox(width: 6),
            _Tag(text: text, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHint() {
    final text = _finished
        ? '标定完成 · 可「确认标定」，或「重新标定」重来'
        : '第 ${_step + 1}/${_steps.length} 步 · ${_hintFor(_currentKind)}';
    return Positioned(
      top: 20,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Column(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '单击 / 拖拽以定位 · Esc 取消',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(Size box) {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  '取消 (Esc)',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
              if (_finished) ...<Widget>[
                OutlinedButton(
                  onPressed: _restart,
                  child: const Text('重新标定'),
                ),
                FilledButton(
                  onPressed: _isComplete ? () => _confirm(box) : null,
                  child: const Text('确认标定'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;

  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class _ScreenshotPainter extends CustomPainter {
  final ui.Image image;
  final double scale;

  _ScreenshotPainter({required this.image, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width * scale;
    final h = image.height * scale;
    final dx = (size.width - w) / 2;
    final dy = (size.height - h) / 2;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(dx, dy, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _ScreenshotPainter old) =>
      old.image != image || old.scale != scale;
}
