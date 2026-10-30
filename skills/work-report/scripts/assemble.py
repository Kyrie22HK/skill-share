#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装报告 HTML：壳模板 + 内容片段 → 单文件自包含报告。
用法: assemble.py <content_fragment.html> <output.html>
片段文件首部以注释行携带元信息：
  <!--TITLE: ... -->
  <!--TOCTITLE: ... -->
  <!--TOC-->            （其后每行一条，至 <!--/TOC-->；pt:xxx 表示分组标签，其余为 "锚点|文字"）
其余为正文内容（h1 起）。
"""
import argparse, re, io
from html import escape
from pathlib import Path

def main(frag_path, out_path):
    src = io.open(frag_path, encoding='utf-8').read()
    title_match = re.search(r'<!--TITLE:\s*(.*?)\s*-->', src)
    toc_title_match = re.search(r'<!--TOCTITLE:\s*(.*?)\s*-->', src)
    m = re.search(r'<!--TOC-->\n(.*?)<!--/TOC-->\n?', src, re.S)
    if not title_match or not toc_title_match or not m:
        raise ValueError('内容片段缺 TITLE / TOCTITLE / TOC 元信息，格式见本脚本头注释')
    title = escape(title_match.group(1))
    toctitle = escape(toc_title_match.group(1))
    toc_lines = []
    for ln in m.group(1).strip().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith('pt:'):
            toc_lines.append('  <div class="pt">%s</div>' % escape(ln[3:].strip()))
        else:
            anchor, label = ln.split('|', 1)
            anchor = anchor.strip()
            if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', anchor):
                raise ValueError('目录锚点须字母开头，只含字母/数字/下划线/连字符：' + anchor)
            toc_lines.append('  <a href="#%s">%s</a>' % (anchor, escape(label.strip())))
    content = src[m.end():].strip('\n')
    content = re.sub(r'<!--(TITLE|TOCTITLE):.*?-->\n?', '', content)
    if re.search(r'<(?:html|head|body)\b', content, re.I):
        raise ValueError('正文应为内容片段，不能再嵌完整 HTML 壳')
    tpl = io.open(TPL, encoding='utf-8').read()
    out = (tpl.replace('{{TITLE}}', title)
              .replace('{{TOCTITLE}}', toctitle)
              .replace('{{TOC}}', '\n'.join(toc_lines))
              .replace('{{CONTENT}}', content))
    io.open(out_path, 'w', encoding='utf-8').write(out)
    print('wrote %s (%d bytes)' % (out_path, len(out.encode('utf-8'))))

TPL = Path(__file__).resolve().with_name('shell_template.html')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fragment')
    parser.add_argument('output')
    args = parser.parse_args()
    try:
        main(args.fragment, args.output)
    except (ValueError, OSError) as exc:
        parser.exit(2, '组装失败：%s\n' % exc)
