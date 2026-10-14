import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全屏单击取点遮罩：展示全屏截图，单击选择一点，
/// 关闭时返回图像像素坐标系下的 [ui.Offset]，取消返回 null。
class PointPickerOverlay extends StatefulWidget {
  final Uint8List screenshotPng;
  final String hint;

  const PointPickerOverlay({
    super.key,
    required this.screenshotPng,
    required this.hint,
  });

  /// 弹出全屏取点，返回像素坐标或 null
  static Future<ui.Offset?> show(
    BuildContext context,
    Uint8List png,
    String hint,
  ) {
    return Navigator.of(context, rootNavigator: true).push<ui.Offset>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PointPickerOverlay(screenshotPng: png, hint: hint),
      ),
    );
  }

  @override
  State<PointPickerOverlay> createState() => _PointPickerOverlayState();
}

class _PointPickerOverlayState extends State<PointPickerOverlay> {
  ui.Image? _decoded;
  Size _imageSize = Size.zero;
  Offset? _point;

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

  double _fitScale(Size boxSize) {
    if (_imageSize == Size.zero) return 1;
    final sx = boxSize.width / _imageSize.width;
    final sy = boxSize.height / _imageSize.height;
    return sx < sy ? sx : sy;
  }

  /// 把组件坐标点映射为图像像素坐标
  Offset? _pointInImage(Size boxSize) {
    final p = _point;
    if (p == null || _imageSize == Size.zero) return null;
    final scale = _fitScale(boxSize);
    final dx = (boxSize.width - _imageSize.width * scale) / 2;
    final dy = (boxSize.height - _imageSize.height * scale) / 2;
    final x = (p.dx - dx) / scale;
    final y = (p.dy - dy) / scale;
    if (x < 0 || y < 0 || x > _imageSize.width || y > _imageSize.height) {
      return null;
    }
    return Offset(x, y);
  }

  void _confirm(Size boxSize) {
    final p = _pointInImage(boxSize);
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先单击要标定的位置')),
      );
      return;
    }
    Navigator.of(context).pop(p);
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
              final scale = _fitScale(boxSize);

              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (_decoded != null)
                    CustomPaint(
                      painter: _PointScreenshotPainter(
                        image: _decoded!,
                        scale: scale,
                      ),
                    )
                  else
                    const Center(child: CircularProgressIndicator()),

                  // 十字准星
                  if (_point != null)
                    Positioned(
                      left: _point!.dx - 1,
                      top: _point!.dy - 12,
                      child: Column(
                        children: <Widget>[
                          Container(width: 2, height: 24, color: Colors.redAccent),
                        ],
                      ),
                    ),
                  if (_point != null)
                    Positioned(
                      left: _point!.dx - 12,
                      top: _point!.dy - 1,
                      child: Row(
                        children: <Widget>[
                          Container(width: 24, height: 2, color: Colors.redAccent),
                        ],
                      ),
                    ),

                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => setState(() => _point = d.localPosition),
                  ),

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
                        child: Text(
                          '${widget.hint} · 单击定位 · Esc 取消',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    bottom: 24,
                    right: 24,
                    child: Row(
                      children: <Widget>[
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
                          child: const Text('确定此点'),
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

class _PointScreenshotPainter extends CustomPainter {
  final ui.Image image;
  final double scale;

  _PointScreenshotPainter({required this.image, required this.scale});

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
  bool shouldRepaint(covariant _PointScreenshotPainter old) =>
      old.image != image || old.scale != scale;
}
