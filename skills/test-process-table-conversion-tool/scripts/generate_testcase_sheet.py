"""
测试流程表 → 测试用例表 生成器

从源测试流程表 Excel 提炼功能需求后，用本模块生成结构化、
带分步操作的测试用例表。

模块用法：
    from generate_testcase_sheet import (
        create_testcase_sheet,
        create_summary_sheet,
        add_sheet_to_source,
        save_standalone,
    )

命令行用法（可选，仅自测提示）：
    python generate_testcase_sheet.py --source <source.xlsx> --output <output_dir>
"""
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
import argparse
import os
import shutil
from datetime import datetime


# ============================================================
# 颜色 / 样式常量
# ============================================================
HEADER_FILL = PatternFill("solid", start_color="4472C4")
HEADER_FONT = Font(name="Arial", bold=True, color="FFFFFF", size=11)
HEADER_ALIGN = Alignment(horizontal="center", vertical="center", wrap_text=True)

THIN_BORDER = Border(
    left=Side(style="thin", color="808080"),
    right=Side(style="thin", color="808080"),
    top=Side(style="thin", color="808080"),
    bottom=Side(style="thin", color="808080"),
)

DATA_FONT = Font(name="Arial", size=10)
DATA_ALIGN = Alignment(horizontal="left", vertical="top", wrap_text=True)
CENTER_ALIGN = Alignment(horizontal="center", vertical="center", wrap_text=True)

CATEGORY_FILLS = {
    "面板基本功能":     PatternFill("solid", start_color="D6E4F0"),
    "独立功能":         PatternFill("solid", start_color="FFF2CC"),
    "功能描述综合测试": PatternFill("solid", start_color="FCE4EC"),
}
MENU_FILL = PatternFill("solid", start_color="E2EFDA")  # 各菜单类别统一绿色


# ============================================================
# 表格构建
# ============================================================

def create_testcase_sheet(ws, test_cases, project_name="项目", start_row=1):
    """把格式化的测试用例表写入 *ws*。

    参数
    ----
    ws : openpyxl.Worksheet
    test_cases : list[dict]
        每个 dict 必须含键：category, item, purpose, preconditions,
        steps, expected。
    project_name : str
        用于标题行。
    start_row : int
        起始写入行（默认 1）。

    返回
    ----
    int —— 最后一行数据之后的第一个空行行号。
    """
    total = len(test_cases)

    # --- 标题 ---
    ws.merge_cells(start_row=start_row, start_column=1,
                   end_row=start_row, end_column=9)
    t = ws.cell(row=start_row, column=1,
                value=f"{project_name} 软件测试用例表")
    t.font = Font(name="Arial", bold=True, size=14, color="1F4E79")
    t.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[start_row].height = 35

    # --- 信息行 ---
    info_r = start_row + 1
    ws.merge_cells(start_row=info_r, start_column=1,
                   end_row=info_r, end_column=9)
    i = ws.cell(row=info_r, column=1,
                value=f"测试用例总数: {total}    生成日期: {datetime.now():%Y-%m-%d}")
    i.font = Font(name="Arial", size=10, color="808080")
    i.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[info_r].height = 22

    # --- 表头 ---
    headers = ["用例编号", "测试分类", "测试项目", "测试目的",
               "前置条件", "测试步骤", "预期结果", "测试结果", "备注"]
    hdr_r = start_row + 2
    for ci, h in enumerate(headers, 1):
        c = ws.cell(row=hdr_r, column=ci, value=h)
        c.font = HEADER_FONT
        c.fill = HEADER_FILL
        c.alignment = HEADER_ALIGN
        c.border = THIN_BORDER
    ws.row_dimensions[hdr_r].height = 30

    # --- 数据行 ---
    cur = hdr_r + 1
    for idx, tc in enumerate(test_cases, 1):
        tc_id = f"TC-{idx:03d}"
        vals = [
            tc_id,
            tc.get("category", ""),
            tc.get("item", ""),
            tc.get("purpose", ""),
            tc.get("preconditions", ""),
            tc.get("steps", ""),
            tc.get("expected", ""),
            "",   # 测试结果（留空）
            "",   # 备注（留空）
        ]
        cat = tc.get("category", "")

        for ci, v in enumerate(vals, 1):
            c = ws.cell(row=cur, column=ci, value=v)
            c.font = DATA_FONT
            c.border = THIN_BORDER
            c.alignment = CENTER_ALIGN if ci in (1, 2, 8, 9) else DATA_ALIGN
            # 分类底色
            if ci == 2 and cat in CATEGORY_FILLS:
                c.fill = CATEGORY_FILLS[cat]
            elif ci == 2 and ("菜单" in cat or "按键" in cat):
                c.fill = MENU_FILL

        # 按步骤/前置条件/预期结果的行数自适应行高
        max_lines = 1
        for k in ("preconditions", "steps", "expected"):
            v = tc.get(k, "")
            if v:
                max_lines = max(max_lines, v.count("\n") + 1)
        ws.row_dimensions[cur].height = max(25, min(max_lines * 15 + 5, 200))
        cur += 1

    # --- 列宽 ---
    for col, w in [("A", 10), ("B", 18), ("C", 28), ("D", 28),
                   ("E", 30), ("F", 50), ("G", 35), ("H", 12), ("I", 15)]:
        ws.column_dimensions[col].width = w

    # --- 冻结与打印版式 ---
    ws.freeze_panes = f"A{hdr_r + 1}"
    ws.print_options.horizontalCentered = True
    ws.page_setup.orientation = "landscape"
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    for side, margin in [("left", 0.3), ("right", 0.3), ("top", 0.5), ("bottom", 0.5)]:
        setattr(ws.page_margins, side, margin)

    return cur  # 第一个空行


def create_summary_sheet(ws, summary_data):
    """创建功能提炼汇总表。

    参数
    ----
    ws : openpyxl.Worksheet
    summary_data : list[dict]
        每个 dict 含：category, item, description。
    """
    ws.merge_cells("A1:D1")
    t = ws.cell(row=1, column=1, value="功能提炼汇总")
    t.font = Font(name="Arial", bold=True, size=14, color="1F4E79")
    t.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 35

    for ci, h in enumerate(["序号", "功能分类", "功能项", "功能描述/测试要点"], 1):
        c = ws.cell(row=3, column=ci, value=h)
        c.font = HEADER_FONT; c.fill = HEADER_FILL
        c.alignment = HEADER_ALIGN; c.border = THIN_BORDER
    ws.row_dimensions[3].height = 28

    for idx, item in enumerate(summary_data, 1):
        r = 3 + idx
        for ci, v in enumerate([idx, item.get("category", ""),
                                item.get("item", ""),
                                item.get("description", "")], 1):
            c = ws.cell(row=r, column=ci, value=v)
            c.font = DATA_FONT; c.border = THIN_BORDER
            c.alignment = DATA_ALIGN if ci >= 3 else CENTER_ALIGN
        desc = item.get("description", "") or ""
        lc = max(desc.count("\n") + 1, 1)
        ws.row_dimensions[r].height = max(25, min(lc * 15 + 5, 80))

    ws.column_dimensions["A"].width = 8
    ws.column_dimensions["B"].width = 18
    ws.column_dimensions["C"].width = 22
    ws.column_dimensions["D"].width = 80
    ws.freeze_panes = "A4"
    ws.page_setup.orientation = "landscape"


# ============================================================
# 文件级操作
# ============================================================

def add_sheet_to_source(source_path, test_cases, project_name,
                        sheet_name="测试用例表"):
    """向源工作簿追加测试用例子表。

    源文件被占用（PermissionError）时，改存 `-含测试用例` 后缀副本。

    返回 (saved_path, was_locked)。
    """
    base, ext = os.path.splitext(source_path)
    tmp = f"{base}_temp{ext}"
    shutil.copy2(source_path, tmp)
    wb = openpyxl.load_workbook(tmp)
    if sheet_name in wb.sheetnames:
        del wb[sheet_name]
    ws = wb.create_sheet(sheet_name)
    create_testcase_sheet(ws, test_cases, project_name)
    wb.save(tmp)

    try:
        shutil.copy2(tmp, source_path)
        os.remove(tmp)
        return source_path, False
    except PermissionError:
        alt = f"{base}-含测试用例{ext}"
        shutil.copy2(tmp, alt)
        os.remove(tmp)
        return alt, True


def save_standalone(output_dir, file_name, test_cases, summary_data,
                    project_name):
    """生成独立的测试用例工作簿。

    含两个子表："测试用例表" 与 "功能提炼汇总"。
    output_dir 必须是已存在的目录（不自建目录，输出位置收敛）。
    """
    if not os.path.isdir(output_dir):
        raise ValueError(f"输出目录不存在: {output_dir}（请指定已存在的目录，本工具不自建目录）")
    fp = os.path.join(output_dir, file_name)
    wb = openpyxl.Workbook()

    ws1 = wb.active
    ws1.title = "测试用例表"
    create_testcase_sheet(ws1, test_cases, project_name)

    ws2 = wb.create_sheet("功能提炼汇总")
    create_summary_sheet(ws2, summary_data)

    wb.save(fp)
    return fp


# ============================================================
# 命令行入口（仅自测提示）
# ============================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="测试流程表 → 测试用例表")
    parser.add_argument("--source", required=True,
                        help="源 Excel 路径")
    parser.add_argument("--output", default=None,
                        help="独立输出目录（默认：与源文件同目录）")
    parser.add_argument("--project", default="项目",
                        help="标题用项目名")
    args = parser.parse_args()
    print(f"Source: {args.source}")
    print(f"Project: {args.project}")
    print(
        "本文件是库脚本。请 import create_testcase_sheet / "
        "create_summary_sheet / add_sheet_to_source / save_standalone "
        "并传入你的测试用例列表调用。"
    )
