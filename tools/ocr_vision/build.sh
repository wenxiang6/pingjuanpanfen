#!/usr/bin/env bash
# 编译本地 OCR 命令行程序（macOS Vision 框架，无需第三方依赖）。
# 产物：tools/ocr_vision/bin/ocr_vision
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$DIR/bin"
mkdir -p "$OUT_DIR"

echo "编译中...（需要 Xcode / Command Line Tools）"
swiftc -O "$DIR/main.swift" \
  -o "$OUT_DIR/ocr_vision" \
  -framework Vision \
  -framework AppKit

echo "完成：$OUT_DIR/ocr_vision"
echo "把它填到程序的「本地 OCR 程序路径」即可。"
