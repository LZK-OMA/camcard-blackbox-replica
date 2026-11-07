#!/usr/bin/env python3
"""
md_to_docx.py — 将本项目的 Markdown 报告转换为排版良好的 Word 文档，
再由 LibreOffice Kit 导出 PDF。

支持：标题、段落、表格（含对齐）、代码块、引用、列表、图片（含图注）、分隔线。

用法：
  python3 Scripts/md_to_docx.py \
      --input Reports/CamCard_Replication_Report.md \
      --output .build/report/CamCard_Replication_Report.docx
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Inches, Pt, RGBColor

CJK_FONT = "PingFang SC"
CODE_FONT = "Menlo"
ACCENT = RGBColor(0x14, 0x60, 0x5C)
BODY = RGBColor(0x20, 0x22, 0x21)
MUTED = RGBColor(0x6B, 0x70, 0x6D)
CODE_BG = "F2F3F0"
TABLE_HEAD_BG = "E8F0EE"


def set_run_font(run, size: float | None = None, bold: bool | None = None,
                 color: RGBColor | None = None, font_name: str = CJK_FONT) -> None:
    run.font.name = font_name
    run._element.rPr.rFonts.set(qn("w:eastAsia"), font_name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = color


def set_cell_shading(cell, fill: str) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    tc_pr.append(shd)


def set_paragraph_bottom_border(paragraph, color: str = "D5D8D3", size: int = 6) -> None:
    p_pr = paragraph._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), str(size))
    bottom.set(qn("w:space"), "1")
    bottom.set(qn("w:color"), color)
    borders.append(bottom)
    p_pr.append(borders)


def add_page_number_footer(section, title: str) -> None:
    footer = section.footer
    paragraph = footer.paragraphs[0]
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = paragraph.add_run(f"{title}   第 ")
    set_run_font(run, size=8.5, color=MUTED)
    _add_field(paragraph, "PAGE")
    run = paragraph.add_run(" 页 / 共 ")
    set_run_font(run, size=8.5, color=MUTED)
    _add_field(paragraph, "NUMPAGES")
    run = paragraph.add_run(" 页")
    set_run_font(run, size=8.5, color=MUTED)


def _add_field(paragraph, field_code: str) -> None:
    run = paragraph.add_run()
    fld_char_begin = OxmlElement("w:fldChar")
    fld_char_begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = f" {field_code} "
    fld_char_end = OxmlElement("w:fldChar")
    fld_char_end.set(qn("w:fldCharType"), "end")
    run._r.append(fld_char_begin)
    run._r.append(instr)
    run._r.append(fld_char_end)
    set_run_font(run, size=8.5, color=MUTED)


def add_header(section, text: str) -> None:
    header = section.header
    paragraph = header.paragraphs[0]
    paragraph.text = ""
    run = paragraph.add_run(text)
    set_run_font(run, size=8.5, color=MUTED)


INLINE_PATTERN = re.compile(r"(\*\*.+?\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))")


def add_inline_runs(paragraph, text: str, size: float = 10.5,
                    color: RGBColor = BODY, bold_all: bool = False) -> None:
    """解析 **bold**、`code`、[text](url) 三种行内格式。"""
    position = 0
    for match in INLINE_PATTERN.finditer(text):
        if match.start() > position:
            run = paragraph.add_run(text[position:match.start()])
            set_run_font(run, size=size, bold=bold_all, color=color)
        token = match.group(0)
        if token.startswith("**") and token.endswith("**"):
            run = paragraph.add_run(token[2:-2])
            set_run_font(run, size=size, bold=True, color=color)
        elif token.startswith("`") and token.endswith("`"):
            run = paragraph.add_run(token[1:-1])
            set_run_font(run, size=size - 0.5, color=RGBColor(0x3C, 0x4A, 0x47), font_name=CODE_FONT)
        else:
            link_match = re.match(r"\[([^\]]+)\]\(([^)]+)\)", token)
            label = link_match.group(1) if link_match else token
            run = paragraph.add_run(label)
            set_run_font(run, size=size, bold=bold_all, color=color)
        position = match.end()
    if position < len(text):
        run = paragraph.add_run(text[position:])
        set_run_font(run, size=size, bold=bold_all, color=color)


def add_heading(document, text: str, level: int) -> None:
    paragraph = document.add_paragraph()
    paragraph.paragraph_format.space_before = Pt(14 if level <= 2 else 10)
    paragraph.paragraph_format.space_after = Pt(6)
    paragraph.paragraph_format.keep_with_next = True
    size = {1: 18.5, 2: 15.5, 3: 13, 4: 11.5}.get(level, 11)
    run = paragraph.add_run(text)
    set_run_font(run, size=size, bold=True, color=ACCENT)

    if level <= 2:
        set_paragraph_bottom_border(paragraph, color="CFE0DB", size=8)
    # 便于生成书签 / 大纲（Word 导航）
    paragraph.style = document.styles["Heading 2"] if level >= 2 else document.styles["Heading 1"]
    for r in paragraph.runs:
        set_run_font(r, size=size, bold=True, color=ACCENT)


def add_code_block(document, lines: list[str]) -> None:
    for line in lines:
        paragraph = document.add_paragraph()
        paragraph.paragraph_format.space_after = Pt(0)
        paragraph.paragraph_format.space_before = Pt(0)
        paragraph.paragraph_format.left_indent = Cm(0.25)
        paragraph.paragraph_format.line_spacing = 1.0
        run = paragraph.add_run(line if line else " ")
        set_run_font(run, size=8.5, color=RGBColor(0x33, 0x3A, 0x38), font_name=CODE_FONT)
        p_pr = paragraph._p.get_or_add_pPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), CODE_BG)
        p_pr.append(shd)


def add_image(document, path: Path, alt: str, base_dir: Path) -> None:
    resolved = (base_dir / path).resolve()
    if not resolved.exists():
        run = document.add_paragraph().add_run(f"[图片缺失：{path}]")
        set_run_font(run, size=9, color=RGBColor(0xB0, 0x30, 0x30))
        return

    from PIL import Image as PILImage

    with PILImage.open(resolved) as image:
        pixel_width, pixel_height = image.size
    aspect = pixel_width / pixel_height if pixel_height else 1.0
    max_width_in, max_height_in = 6.1, 7.6
    width_in = max_width_in
    height_in = width_in / aspect
    if height_in > max_height_in:
        height_in = max_height_in
        width_in = height_in * aspect

    paragraph = document.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.paragraph_format.space_before = Pt(6)
    run = paragraph.add_run()
    run.add_picture(str(resolved), width=Inches(width_in))
    if alt:
        caption = document.add_paragraph()
        caption.alignment = WD_ALIGN_PARAGRAPH.CENTER
        caption.paragraph_format.space_after = Pt(10)
        cap_run = caption.add_run(alt)
        set_run_font(cap_run, size=8.5, color=MUTED)


def add_blockquote(document, lines: list[str]) -> None:
    text = " ".join(line.strip().lstrip(">").strip() for line in lines).strip()
    paragraph = document.add_paragraph()
    paragraph.paragraph_format.left_indent = Cm(0.5)
    paragraph.paragraph_format.space_before = Pt(4)
    paragraph.paragraph_format.space_after = Pt(6)
    add_inline_runs(paragraph, text, size=9.5, color=RGBColor(0x55, 0x5B, 0x58))


def add_bullet(document, text: str, ordered: bool, number: int = 1) -> None:
    paragraph = document.add_paragraph()
    paragraph.paragraph_format.left_indent = Cm(0.6)
    paragraph.paragraph_format.first_line_indent = Cm(-0.3)
    paragraph.paragraph_format.space_after = Pt(3)
    prefix = f"{number}. " if ordered else "• "
    run = paragraph.add_run(prefix)
    set_run_font(run, size=10.5, color=ACCENT if not ordered else MUTED)
    add_inline_runs(paragraph, text, size=10.5)


def split_table_row(line: str) -> list[str]:
    cells = line.strip().strip("|").split("|")
    return [cell.strip() for cell in cells]


def add_table(document, rows: list[list[str]], aligns: list[str]) -> None:
    if not rows:
        return
    column_count = max(len(row) for row in rows)
    normalized = [row + [""] * (column_count - len(row)) for row in rows]
    table = document.add_table(rows=len(normalized), cols=column_count)
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = True

    for row_index, row in enumerate(normalized):
        for column_index, cell_text in enumerate(row):
            cell = table.cell(row_index, column_index)
            cell.text = ""
            paragraph = cell.paragraphs[0]
            paragraph.paragraph_format.space_after = Pt(1)
            paragraph.paragraph_format.space_before = Pt(1)
            alignment = aligns[column_index] if column_index < len(aligns) else "left"
            if alignment == "right":
                paragraph.alignment = WD_ALIGN_PARAGRAPH.RIGHT
            elif alignment == "center":
                paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
            clean = re.sub(r"\*\*|`", "", cell_text)
            run = paragraph.add_run(clean)
            set_run_font(
                run,
                size=8.0,
                bold=(row_index == 0),
                color=ACCENT if row_index == 0 else BODY,
            )
            if row_index == 0:
                set_cell_shading(cell, TABLE_HEAD_BG)

    # 按内容长度分配列宽（可用宽度约 6.45 英寸），减少等宽导致的过度折行
    available_width = 6.45
    weights = []
    for column_index in range(column_count):
        lengths = [
            max(1, len(re.sub(r"\*\*|`", "", row[column_index])))
            for row in normalized
        ]
        average = sum(lengths) / len(lengths)
        weights.append(max(1.0, average ** 0.62))
    total_weight = sum(weights)
    table.autofit = False
    for column_index, weight in enumerate(weights):
        width_in = max(0.55, available_width * weight / total_weight)
        for row in table.rows:
            row.cells[column_index].width = Inches(width_in)

    # 表格后留白
    spacer = document.add_paragraph()
    spacer.paragraph_format.space_after = Pt(6)


def parse_alignments(separator: str) -> list[str]:
    aligns = []
    for cell in split_table_row(separator):
        stripped = cell.strip()
        if stripped.startswith(":") and stripped.endswith(":"):
            aligns.append("center")
        elif stripped.endswith(":"):
            aligns.append("right")
        else:
            aligns.append("left")
    return aligns


def convert(md_path: Path, output_path: Path) -> None:
    lines = md_path.read_text(encoding="utf-8").splitlines()
    base_dir = md_path.parent

    document = Document()
    document.core_properties.title = "名片全能王（CamCard）功能切片 100% 黑盒复刻 · 项目验收与工程实践报告"
    document.core_properties.subject = "SDD + AI IDE 移动应用工程实践"
    document.core_properties.author = "移动应用开发课程作业"

    section = document.sections[0]
    section.page_width = Cm(21.0)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.2)
    section.bottom_margin = Cm(2.0)
    section.left_margin = Cm(2.2)
    section.right_margin = Cm(2.2)

    normal = document.styles["Normal"]
    normal.font.name = CJK_FONT
    normal.font.size = Pt(10.5)
    normal.font.color.rgb = BODY
    normal.paragraph_format.line_spacing = 1.3
    normal.paragraph_format.space_after = Pt(6)
    normal._element.rPr.rFonts.set(qn("w:eastAsia"), CJK_FONT)

    add_header(section, "CamCard 功能切片 100% 黑盒复刻 · 项目验收报告")
    add_page_number_footer(section, "CamCard 项目报告")

    index = 0
    total = len(lines)
    while index < total:
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            index += 1
            continue

        if stripped.startswith("```"):
            code_lines = []
            index += 1
            while index < total and not lines[index].strip().startswith("```"):
                code_lines.append(lines[index])
                index += 1
            index += 1
            add_code_block(document, code_lines)
            continue

        if stripped.startswith("|"):
            table_lines = []
            while index < total and lines[index].strip().startswith("|"):
                table_lines.append(lines[index].strip())
                index += 1
            if len(table_lines) >= 2 and re.match(r"^\|?[\s:\-|]+\|?$", table_lines[1]):
                rows = [split_table_row(table_lines[0])]
                aligns = parse_alignments(table_lines[1])
                for row_line in table_lines[2:]:
                    rows.append(split_table_row(row_line))
                add_table(document, rows, aligns)
            else:
                for row_line in table_lines:
                    body = document.add_paragraph()
                    add_inline_runs(body, row_line.strip("|"))
            continue

        heading_match = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading_match:
            level = len(heading_match.group(1))
            add_heading(document, heading_match.group(2).strip(), level)
            index += 1
            continue

        image_match = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)$", stripped)
        if image_match:
            add_image(document, Path(image_match.group(2)), image_match.group(1), base_dir)
            index += 1
            continue

        if stripped == "---":
            paragraph = document.add_paragraph()
            paragraph.paragraph_format.space_before = Pt(2)
            paragraph.paragraph_format.space_after = Pt(8)
            set_paragraph_bottom_border(paragraph)
            index += 1
            continue

        if stripped.startswith(">"):
            quote_lines = []
            while index < total and lines[index].strip().startswith(">"):
                quote_lines.append(lines[index])
                index += 1
            add_blockquote(document, quote_lines)
            continue

        list_match = re.match(r"^\s*([-*])\s+(.*)$", line)
        if list_match:
            add_bullet(document, list_match.group(2), ordered=False)
            index += 1
            continue

        ordered_match = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if ordered_match:
            add_bullet(document, ordered_match.group(2), ordered=True, number=int(ordered_match.group(1)))
            index += 1
            continue

        paragraph_lines = [stripped]
        index += 1
        while index < total:
            candidate = lines[index]
            candidate_stripped = candidate.strip()
            if not candidate_stripped:
                break
            if (
                candidate_stripped.startswith(("```", "|", "#", ">", "!["))
                or candidate_stripped == "---"
                or re.match(r"^\s*[-*]\s+", candidate)
                or re.match(r"^\s*\d+\.\s+", candidate)
            ):
                break
            paragraph_lines.append(candidate_stripped)
            index += 1
        paragraph = document.add_paragraph()
        add_inline_runs(paragraph, " ".join(paragraph_lines), size=10.5)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    document.save(output_path)
    print(f"saved {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    convert(Path(args.input), Path(args.output))


if __name__ == "__main__":
    main()
