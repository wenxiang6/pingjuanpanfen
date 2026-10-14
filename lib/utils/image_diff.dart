import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 计算两张图片的**平均像素差**（0~255，越小越相似）。
///
/// 会把两张图缩放到 [sampleSize]×[sampleSize] 再逐像素比较，
/// 既能容忍轻微噪声，又能反映整体内容变化；解码失败返回 null。
double? averagePixelDifference(
  Uint8List a,
  Uint8List b, {
  int sampleSize = 64,
}) {
  final ia = img.decodeImage(a);
  final ib = img.decodeImage(b);
  if (ia == null || ib == null) return null;

  final sa = img.copyResize(ia, width: sampleSize, height: sampleSize);
  final sb = img.copyResize(ib, width: sampleSize, height: sampleSize);

  var total = 0.0;
  for (var y = 0; y < sampleSize; y++) {
    for (var x = 0; x < sampleSize; x++) {
      final pa = sa.getPixel(x, y);
      final pb = sb.getPixel(x, y);
      total += (pa.r - pb.r).abs() +
          (pa.g - pb.g).abs() +
          (pa.b - pb.b).abs();
    }
  }
  return total / (sampleSize * sampleSize * 3);
}
