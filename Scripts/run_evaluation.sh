#!/usr/bin/env bash
# 一键执行：生成图片 → Vision OCR 采证 → 计算准确率并生成报告
set -euo pipefail

cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-/Users/admin/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3}"
if ! "$PYTHON" -c 'import PIL' >/dev/null 2>&1; then
  PYTHON="python3"
fi

echo "==> 1/3 生成 30 张测试名片图片与 OCR 夹具"
"$PYTHON" Scripts/generate_fixtures.py

echo "==> 2/3 图片 → Vision OCR → 字段抽取"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift test --disable-sandbox --filter EvaluationEvidenceTests

echo "==> 3/3 计算指标并生成报告"
python3 Scripts/evaluate.py "$@"
