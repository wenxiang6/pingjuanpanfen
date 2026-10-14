import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全屏框选遮罩：展示已截取的全屏图，拖拽选择矩形区域。
///
/// 关闭时返回图像像素坐标系下的 [Rect]（非逻辑像素），取消返回 null。
class RegionSelectOverlay extends StatefulWidget {
  final Uint8List screenshotPng;

  const RegionSelectOverlay({super.key, required this.screenshotPng});

  /// 弹出全屏框选，返回像素坐标矩形或 null
  static Future<ui.Rect?> show(BuildContext context, Uint8List png) {
    return Navigator.of(context, rootNavigator: true).push<ui.Rect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RegionSelectOverlay(screenshotPng: png),
      ),
    );
  }

  @override
  State<RegionSelectOverlay> createState() => _RegionSelectOverlayState();
}

class _RegionSelectOverlayState extends State<RegionSelectOverlay> {
  ui.Image? _decoded;
  Size _imageSize = Size.zero;

  /// 选区（组件坐标系）
  Offset? _start;
  Offset? _current;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.screenshotPng);
    final frame = await codec.getNextFrame();
    setState(() {
      _decoded = frame.image;
      _imageSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    });
  }

  ui.Rect? _selectionInWidget() {
    if (_start == null || _current == null) return null;
    return ui.Rect.fromPoints(_start!, _current!);
  }

  /// 把组件坐标选区映射为图像像素坐标
  ui.Rect? _selectionInImage(Size boxSize) {
    final sel = _selectionInWidget();
    if (sel == null || sel.width < 2 || sel.height < 2) return null;
    if (_imageSize == Size.zero) return null;

    final scale = _fitScale(boxSize);
    final dx = (boxSize.width - _imageSize.width * scale) / 2;
    final dy = (boxSize.height - _imageSize.height * scale) / 2;

    final left = (sel.left - dx) / scale;
    final top = (sel.top - dy) / scale;
    final right = (sel.right - dx) / scale;
    final bottom = (sel.bottom - dy) / scale;

    final imageRect = ui.Rect.fromLTRB(left, top, right, bottom);
    final bounds = ui.Rect.fromLTWH(0, 0, _imageSize.width, _imageSize.height);
    return imageRect.intersect(bounds);
  }

  double _fitScale(Size boxSize) {
    if (_imageSize == Size.zero) return 1;
    return (boxSize.width / _imageSize.width)
        .clamp(0.0, double.infinity)
        .toDouble()
        .compareTo(boxSize.height / _imageSize.height) > 0
        ? boxSize.height / _imageSize.height
        : boxSize.width / _imageSize.width;
  }

  void _confirm(Size boxSize) {
    final rect = _selectionInImage(boxSize);
    if (rect == null || rect.width < 2 || rect.height < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先拖拽框选学生答案区域')),
      );
      return;
    }
    Navigator.of(context).pop(rect);
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
              final boxSize = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                fit: StackFit.expand,
                children: [
                  // 背景截图
                  if (_decoded != null)
                    CustomPaint(
                      painter: _ScreenshotPainter(
                        image: _decoded!,
                        fit: _fitScale(boxSize),
                      ),
                    )
                  else
                    const Center(child: CircularProgressIndicator()),

                  // 暗化 + 选区高亮
                  if (_selectionInWidget() case final sel?)
                    CustomPaint(
                      painter: _MaskPainter(sel),
                    ),

                  // 手势
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) {
                      setState(() {
                        _start = d.localPosition;
                        _current = d.localPosition;
                      });
                    },
                    onPanUpdate: (d) {
                      setState(() => _current = d.localPosition);
                    },
                    onPanEnd: (_) {
                      setState(() {});
                    },
                    onDoubleTap: () => _confirm(boxSize),
                  ),

                  // 顶部提示
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '拖拽框选学生答案区域 · 双击或点击「确定」截取 · Esc 取消',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),

                  // 底部按钮
                  Positioned(
                    bottom: 24,
                    right: 24,
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text(
                            '取消 (Esc)',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => _confirm(boxSize),
                          child: const Text('确定截取'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ScreenshotPainter extends CustomPainter {
  final ui.Image image;
  final double fit;

  _ScreenshotPainter({required this.image, required this.fit});

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width * fit;
    final h = image.height * fit;
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
      old.image != image || old.fit != fit;
}

class _MaskPainter extends CustomPainter {
  final Rect selection;

  _MaskPainter(this.selection);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    // 四周暗化
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(selection),
      ),
      dim,
    );

    final border = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(selection, border);
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) => old.selection != selection;
}
