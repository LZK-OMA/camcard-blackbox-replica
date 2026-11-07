#!/usr/bin/env python3
"""
plot_metrics.py — 从 Fixtures/Results/metrics.json 生成报告用图表。

产物：
  Reports/charts/field_accuracy.png   抽取层 vs 端到端 字段准确率对比
  Reports/charts/error_breakdown.png  端到端字段错误归因

依赖 Pillow（使用带 Pillow 的 Python 解释器运行）。
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
METRICS_PATH = ROOT / "Fixtures/Results/metrics.json"
CHARTS_DIR = ROOT / "Reports/charts"
FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, size=size, index=1 if bold else 0)


def draw_field_accuracy(metrics: dict) -> Path:
    labels = ["姓名", "公司", "职位", "手机", "电话", "邮箱", "网址", "地址"]
    keys = ["name", "company", "jobTitle", "mobile", "phone", "email", "website", "address"]
    baseline = [metrics["baseline"]["fields"][key]["exact_rate"] * 100 for key in keys]
    e2e = [metrics["endToEnd"]["fields"][key]["exact_rate"] * 100 for key in keys]

    width, height = 1120, 620
    image = Image.new("RGB", (width, height), (250, 250, 247))
    draw = ImageDraw.Draw(image)

    left, top, right, bottom = 110, 132, 1070, 520
    draw.line([(left, top), (left, bottom)], fill=(90, 90, 90), width=2)
    draw.line([(left, bottom), (right, bottom)], fill=(90, 90, 90), width=2)

    for value in [80, 85, 90, 95, 100]:
        y = bottom - (value - 80) / 20 * (bottom - top)
        draw.line([(left, y), (right, y)], fill=(225, 224, 218), width=1)
        draw.text((54, y - 9), f"{value}%", font=font(16), fill=(110, 110, 110))

    threshold_y = bottom - (95 - 80) / 20 * (bottom - top)
    draw.line([(left, threshold_y), (right, threshold_y)], fill=(205, 80, 60), width=2)

    draw.text((left, 24), "30 张名片：抽取层 vs 端到端 字段准确率", font=font(26, True), fill=(30, 30, 30))

    legend_y = 66
    draw.rounded_rectangle([left, legend_y, left + 22, legend_y + 14], radius=3, fill=(120, 170, 160))
    draw.text((left + 32, legend_y - 4), "抽取层（Ground Truth 文本 → 字段）", font=font(15), fill=(80, 80, 80))
    draw.rounded_rectangle([left + 330, legend_y, left + 352, legend_y + 14], radius=3, fill=(20, 112, 107))
    draw.text((left + 362, legend_y - 4), "端到端（图片 → OCR → 字段）", font=font(15), fill=(80, 80, 80))
    draw.line([(left + 700, legend_y + 8), (left + 745, legend_y + 8)], fill=(205, 80, 60), width=2)
    draw.text((left + 755, legend_y - 4), "95% 验收门槛", font=font(15), fill=(150, 60, 45))

    group_width = (right - left) / len(labels)
    bar_width = 26
    for index, label in enumerate(labels):
        center_x = left + group_width * (index + 0.5)
        for offset, values, color in (
            (-bar_width - 4, baseline, (120, 170, 160)),
            (6, e2e, (20, 112, 107)),
        ):
            value = values[index]
            bar_height = (value - 80) / 20 * (bottom - top)
            x0 = center_x + offset
            draw.rounded_rectangle(
                [x0, bottom - bar_height, x0 + bar_width, bottom],
                radius=4,
                fill=color,
            )
            draw.text(
                (x0 + 3, bottom - bar_height - 20),
                f"{value:.0f}",
                font=font(12),
                fill=(70, 70, 70),
            )
        draw.text((center_x - 18, bottom + 12), label, font=font(18), fill=(60, 60, 60))

    output = CHARTS_DIR / "field_accuracy.png"
    image.save(output, optimize=True)
    return output


def draw_error_breakdown(metrics: dict) -> Path:
    errors = metrics.get("endToEndErrors", [])
    reasons: dict[str, int] = {}
    for error in errors:
        reasons[error["reason"]] = reasons.get(error["reason"], 0) + 1

    width, height = 1000, 340
    image = Image.new("RGB", (width, height), (250, 250, 247))
    draw = ImageDraw.Draw(image)
    draw.text(
        (40, 24),
        f"端到端 {len(errors)} 处字段错误的归因（全部来自 OCR 层）",
        font=font(24, True),
        fill=(30, 30, 30),
    )

    max_value = max(reasons.values()) if reasons else 1
    y = 104
    for reason, count in reasons.items():
        bar_width = int(count / max_value * 560)
        draw.rounded_rectangle([300, y, 300 + bar_width, y + 44], radius=8, fill=(20, 112, 107))
        draw.text((40, y + 10), reason, font=font(20), fill=(50, 50, 50))
        draw.text((300 + bar_width + 14, y + 10), f"{count} 处", font=font(20, True), fill=(30, 30, 30))
        y += 74

    draw.text(
        (40, height - 42),
        "竖排 TC07 占 7 处；形近字替换占 4 处（i/l/j、0/O）。",
        font=font(15),
        fill=(120, 120, 120),
    )
    output = CHARTS_DIR / "error_breakdown.png"
    image.save(output, optimize=True)
    return output


def main() -> None:
    CHARTS_DIR.mkdir(parents=True, exist_ok=True)
    metrics = json.loads(METRICS_PATH.read_text(encoding="utf-8"))
    print("saved", draw_field_accuracy(metrics))
    print("saved", draw_error_breakdown(metrics))


if __name__ == "__main__":
    main()
