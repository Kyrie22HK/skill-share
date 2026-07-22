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
import sys, re, io

def main(frag_path, out_path):
    src = io.open(frag_path, encoding='utf-8').read()
    title = re.search(r'<!--TITLE:\s*(.*?)\s*-->', src).group(1)
    toctitle = re.search(r'<!--TOCTITLE:\s*(.*?)\s*-->', src).group(1)
    m = re.search(r'<!--TOC-->\n(.*?)<!--/TOC-->\n?', src, re.S)
    toc_lines = []
    for ln in m.group(1).strip().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith('pt:'):
            toc_lines.append('  <div class="pt">%s</div>' % ln[3:].strip())
        else:
            anchor, label = ln.split('|', 1)
            toc_lines.append('  <a href="#%s">%s</a>' % (anchor.strip(), label.strip()))
    content = src[m.end():].strip('\n')
    content = re.sub(r'<!--(TITLE|TOCTITLE):.*?-->\n?', '', content)
    tpl = io.open(TPL, encoding='utf-8').read()
    out = (tpl.replace('{{TITLE}}', title)
              .replace('{{TOCTITLE}}', toctitle)
              .replace('{{TOC}}', '\n'.join(toc_lines))
              .replace('{{CONTENT}}', content))
    io.open(out_path, 'w', encoding='utf-8').write(out)
    print('wrote %s (%d bytes)' % (out_path, len(out.encode('utf-8'))))

TPL = __file__.rsplit('/', 1)[0] + '/shell_template.html'

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
