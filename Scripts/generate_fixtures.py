#!/usr/bin/env python3
"""
generate_fixtures.py — 根据 ground_truth.json 生成 30 张测试名片图片 + OCR 夹具。

产物：
  Fixtures/Images/TC01.png ... TC30.png   名片照片（含背景/轻微旋转/噪声变体）
  Fixtures/OCR/TC01.json ... TC30.json    OCR 夹具（text/confidence/bbox）
  Fixtures/Images/layout.json             生成参数（角度、行信息），便于复现

依赖 Pillow（本机可用路径见脚本注释）。
用法（使用带 Pillow 的 Python）：
  /Users/admin/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
      Scripts/generate_fixtures.py
"""

from __future__ import annotations

import json
import math
import os
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
GT_PATH = ROOT / "ground_truth.json"
IMAGES_DIR = ROOT / "Fixtures" / "Images"
OCR_DIR = ROOT / "Fixtures" / "OCR"

CANVAS_W, CANVAS_H = 1600, 1000
CARD_W, CARD_H = 1320, 780
CARD_RADIUS = 28
OUTPUT_SCALE = 2
ACCENT = (20, 112, 107)
CARD_FILL = (250, 249, 246)
CARD_BORDER = (224, 221, 214)
TEXT_COLOR = (32, 34, 33)
SECONDARY_COLOR = (78, 82, 80)

CJK_FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
LATIN_FONT_PATH = "/System/Library/Fonts/Supplementary/Arial.ttf"

# 版式变体：旋转角度 / 噪声 / 竖排
VARIANT_RULES = {
    "TC07": {"angle": 0.0, "vertical": True},
    "TC30": {"angle": 4.0, "noise": True},
    "TC24": {"angle": -2.5},
    "TC09": {"angle": 1.5},
    "TC16": {"angle": -1.2},
    "TC25": {"angle": 1.0},
    "TC19": {"angle": -0.8},
}


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    # Hiragino Sans GB.ttc: index 0 = W3(细), index 1 = W6(粗)
    index = 1 if bold else 0
    try:
        return ImageFont.truetype(CJK_FONT_PATH, size=size, index=index)
    except Exception:
        for candidate in (
            "/System/Library/Fonts/STHeiti Medium.ttc" if bold else "/System/Library/Fonts/STHeiti Light.ttc",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        ):
            try:
                return ImageFont.truetype(candidate, size=size)
            except Exception:
                continue
    return ImageFont.load_default()


def font_for_text(text: str, size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """纯 ASCII 行改用 Arial，避免中文字体的拉丁字形在 OCR 中形近混淆。"""
    return load_font(size, bold=bold)


def text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont) -> float:
    return draw.textlength(text, font=font)


def wrap_line(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: float,
) -> list[str]:
    """按可用宽度折行：英文按词、中文按字。"""
    text = text.strip()
    if not text:
        return []
    tokens: list[str] = []
    buf = ""
    for ch in text:
        if ch.isascii() and not ch.isspace():
            buf += ch
            continue
        if buf:
            tokens.append(buf)
            buf = ""
        if ch.isspace():
            if tokens and tokens[-1] != " ":
                tokens.append(" ")
            continue
        tokens.append(ch)
    if buf:
        tokens.append(buf)

    lines: list[str] = []
    current = ""
    for token in tokens:
        trial = current + token
        if text_width(draw, trial, font) <= max_width or not current:
            current = trial
        else:
            lines.append(current.strip())
            current = token
    if current.strip():
        lines.append(current.strip())
    return lines


def make_background(rng: random.Random) -> Image.Image:
    width, height = CANVAS_W, CANVAS_H
    top = (236, 232, 224)
    bottom = (205, 200, 190)
    image = Image.new("RGB", (width, height), top)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / max(1, height - 1)
        color = tuple(
            int(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)
        )
        draw.line([(0, y), (width, y)], fill=color)

    # 桌面细节：极浅的纹理线与噪点
    for _ in range(220):
        x = rng.randint(0, width)
        y = rng.randint(0, height)
        length = rng.randint(30, 180)
        delta = rng.randint(-8, 8)
        draw.line(
            [(x, y), (min(width, x + length), y + delta)],
            fill=(200, 196, 187),
            width=1,
        )
    return image


def render_card(card: Image.Image, sample: dict, rng: random.Random) -> tuple[Image.Image, list[dict]]:
    """在透明卡片上绘制内容，返回（卡片图, OCR 行信息）。"""
    draw = ImageDraw.Draw(card)
    layout = []

    variant = VARIANT_RULES.get(sample["id"], {})
    vertical = bool(variant.get("vertical"))
    raw_lines = [line for line in sample["raw_text"].split("\n") if line.strip()]

    pad_x, pad_top = 90, 62
    max_text_width = CARD_W - pad_x * 2

    if vertical:
        # 竖排异形版式：每行文字变成一列，逐字向下排列；超高自动折到下一列。
        font = load_font(38, bold=True)
        column_gap = 58
        char_step = 44
        max_y = CARD_H - 70
        column = 0
        y = pad_top
        for raw in raw_lines:
            x = pad_x + column * column_gap
            column_started = False
            for ch in raw:
                if y + char_step > max_y:
                    column += 1
                    x = pad_x + column * column_gap
                    y = pad_top
                draw.text((x, y), ch, font=font, fill=TEXT_COLOR)
                layout.append(
                    {
                        "text": ch,
                        "x": x,
                        "y": y,
                        "w": char_step,
                        "h": char_step,
                        "column": column,
                    }
                )
                y += char_step
                column_started = True
            if column_started:
                y = pad_top
                column += 1
        return card, layout

    # 横排版式：公司名大号，其它行按层级缩小；自动选择不溢出的字号档位。
    size_tiers = [
        (42, 34, 26),
        (40, 32, 24),
    ]
    layout = []
    render_ops = []
    y = pad_top

    for company_size, name_size, contact_size in size_tiers:
        layout.clear()
        render_ops.clear()
        y = pad_top
        for index, raw in enumerate(raw_lines):
            if index == 0:
                font = load_font(company_size, bold=True)
                color = TEXT_COLOR
                line_gap = 16
            elif index == 1:
                font = load_font(name_size, bold=True)
                color = TEXT_COLOR
                line_gap = 14
            else:
                font = load_font(contact_size)
                color = SECONDARY_COLOR
                line_gap = 10

            for part in wrap_line(draw, raw, font, max_text_width):
                line_height = int(font.size * 1.28)
                render_ops.append((part, pad_x, y, font, color))
                layout.append(
                    {
                        "text": part,
                        "x": pad_x,
                        "y": y,
                        "w": text_width(draw, part, font),
                        "h": line_height,
                    }
                )
                y += line_height
            y += line_gap

        if y <= CARD_H - 46:
            break

    for text, x, y_pos, font, color in render_ops:
        draw.text((x, y_pos), text, font=font, fill=color)


    return card, layout


def compose_image(sample: dict, rng: random.Random) -> tuple[Image.Image, list[dict], float]:
    variant = VARIANT_RULES.get(sample["id"], {})
    angle = float(variant.get("angle", 0.0))

    background = make_background(rng)

    card = Image.new("RGBA", (CARD_W, CARD_H), (0, 0, 0, 0))
    card_draw = ImageDraw.Draw(card)
    card_draw.rounded_rectangle(
        [0, 0, CARD_W - 1, CARD_H - 1],
        radius=CARD_RADIUS,
        fill=CARD_FILL + (255,),
        outline=CARD_BORDER + (255,),
        width=2,
    )
    card, layout = render_card(card, sample, rng)

    if variant.get("noise"):
        noise = Image.effect_noise((CANVAS_W, CANVAS_H), 26).convert("L")
        background = Image.composite(
            background,
            background.point(lambda value: max(0, value - 12)),
            noise.point(lambda value: 40 if value > 170 else 0),
        )

    # 阴影
    shadow = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    card_x = (CANVAS_W - CARD_W) // 2
    card_y = (CANVAS_H - CARD_H) // 2
    shadow_draw.rounded_rectangle(
        [card_x + 18, card_y + 26, card_x + CARD_W + 18, card_y + CARD_H + 26],
        radius=CARD_RADIUS,
        fill=(0, 0, 0, 85),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    background = Image.alpha_composite(background.convert("RGBA"), shadow)

    if abs(angle) > 0.01:
        rotated = card.rotate(angle, expand=True, resample=Image.BICUBIC)
        paste_x = (CANVAS_W - rotated.width) // 2
        paste_y = (CANVAS_H - rotated.height) // 2
        background.alpha_composite(rotated, (paste_x, paste_y))
    else:
        background.alpha_composite(card, (card_x, card_y))

    return background.convert("RGB"), layout, angle


def bbox_to_normalized(item: dict, angle: float) -> list[float]:
    """把卡片坐标系里的文字位置换算成整图归一化 bbox（原点左下）。"""
    card_origin_x = (CANVAS_W - CARD_W) / 2
    card_origin_y = (CANVAS_H - CARD_H) / 2
    x = card_origin_x + item["x"]
    y_top = card_origin_y + item["y"]
    w = item["w"]
    h = item["h"]

    if abs(angle) > 0.01:
        # 旋转后整卡中心不变，按中心旋转文字中心点近似（夹具用于 Mock，非精确标注）。
        theta = math.radians(angle)
        cx = x + w / 2 - CANVAS_W / 2
        cy = y_top + h / 2 - CANVAS_H / 2
        rx = cx * math.cos(theta) - cy * math.sin(theta)
        ry = cx * math.sin(theta) + cy * math.cos(theta)
        x = CANVAS_W / 2 + rx - w / 2
        y_top = CANVAS_H / 2 + ry - h / 2

    x_norm = max(0.0, min(1.0, x / CANVAS_W))
    w_norm = max(0.0, min(1.0 - x_norm, w / CANVAS_W))
    y_bottom_norm = max(0.0, min(1.0, 1.0 - (y_top + h) / CANVAS_H))
    h_norm = max(0.0, min(1.0 - y_bottom_norm, h / CANVAS_H))
    return [round(x_norm, 4), round(y_bottom_norm, 4), round(w_norm, 4), round(h_norm, 4)]


def build_ocr_fixture(sample: dict, layout: list[dict], angle: float) -> dict:
    rng = random.Random(sample["id"])
    lines = []
    for item in layout:
        confidence = round(rng.uniform(0.88, 0.99), 3)
        lines.append(
            {
                "text": item["text"],
                "confidence": confidence,
                "bbox": bbox_to_normalized(item, angle),
            }
        )
    return {
        "id": sample["id"],
        "scenario": sample["scenario"],
        "image": f"Fixtures/Images/{sample['id']}.png",
        "lines": lines,
    }


def main() -> None:
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    OCR_DIR.mkdir(parents=True, exist_ok=True)

    samples = json.loads(GT_PATH.read_text(encoding="utf-8"))
    layout_manifest = {}

    for sample in samples:
        rng = random.Random(sample["id"])
        image, layout, angle = compose_image(sample, rng)
        image_path = IMAGES_DIR / f"{sample['id']}.png"
        image.save(image_path, format="PNG", optimize=True)

        fixture = build_ocr_fixture(sample, layout, angle)
        (OCR_DIR / f"{sample['id']}.json").write_text(
            json.dumps(fixture, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        layout_manifest[sample["id"]] = {
            "scenario": sample["scenario"],
            "angle": angle,
            "lines": len(fixture["lines"]),
            "image": str(image_path.relative_to(ROOT)),
        }

    (IMAGES_DIR / "layout.json").write_text(
        json.dumps(layout_manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(f"✅ 已生成 {len(samples)} 张测试名片图片 → {IMAGES_DIR}")
    print(f"✅ 已生成 {len(samples)} 个 OCR 夹具 → {OCR_DIR}")


if __name__ == "__main__":
    main()
