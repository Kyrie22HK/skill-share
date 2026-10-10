#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""报告 HTML 交付前自检（skill 第七节）。
用法: selfcheck.py <report.html> [...]
检查项：
 1. 标签配平 svg/table/details/pre/figure/div/h2/h3/tr/td/th/ul/ol/li
 2. TOC↔id 对应；id 不得数字开头
 3. SVG 文本溢出估算（中文≈字号px/字，拉丁数字≈0.55×字号，middle 两侧各留6px）
 4. 无 TODO/FIXME/{{}} 占位；SVG 文本无裸 &
 5. code 元素 overflow-wrap（模板 CSS 全局已保证，验证样式存在）
 6. figure.diagram 结构：svg 必须由 <div class="scroll"> 包裹（灯箱 JS 只绑定 figure.diagram .scroll）
 7. 内嵌视频（scripts/embed_video.py 生成）：每个 <video> 有封面、data-src 指向存在的数据块、不用 src="data:"；
    figure.video 有 figcaption；单段 ≤ 4 MB、合计 > 8 MB 警告 / > 16 MB 报错；壳含 hydrateVideo
"""
import sys, re, io, unicodedata

TAGS = ['svg','table','details','pre','figure','div','h2','h3','tr','td','th','ul','ol','li','video']

def text_width(s, fs):
    w = 0.0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ('W', 'F'):
            w += fs
        elif ch == ' ':
            w += fs * 0.28
        else:
            w += fs * 0.55
    return w

def check(path):
    html = io.open(path, encoding='utf-8').read()
    errs, warns = [], []

    # 视频数据块（base64）先摘出来：其中可能碰巧出现 TODO 之类字样，其余各项只查摘除后的正文
    blobs = {}
    def take(m):
        blobs[m.group(1)] = len(re.sub(r'\s+', '', m.group(2)))
        return ''
    html = re.sub(r'<script type="application/octet-stream" id="([^"]+)"[^>]*>(.*?)</script>', take, html, flags=re.S)

    # 1 标签配平
    for t in TAGS:
        opens = len(re.findall(r'<%s(?=[\s/>])' % t, html))
        closes = len(re.findall(r'</%s>' % t, html))
        self_close = len(re.findall(r'<%s(?=[\s/>])[^>]*/>' % t, html))
        if opens - self_close != closes:
            errs.append('标签不配平 <%s>: open=%d close=%d selfclose=%d' % (t, opens, closes, self_close))

    # 2 TOC↔id
    toc = re.search(r'<nav class="side-toc".*?</nav>', html, re.S)
    if not toc:
        errs.append('缺 side-toc')
    else:
        anchors = re.findall(r'href="#([^"]+)"', toc.group(0))
        ids = set(re.findall(r'id="([^"]+)"', html))
        for a in anchors:
            if a not in ids:
                errs.append('TOC 锚点 #%s 无对应 id' % a)
        for a in anchors:
            if a and a[0].isdigit():
                errs.append('id 数字开头: %s（scroll-spy 会崩）' % a)
    if 'id="prog"' not in html: errs.append('缺进度条 #prog')
    if 'openLB' not in html: errs.append('缺灯箱脚本')
    if '<img' in html and 'imgwrap' not in html:
        errs.append('含 <img> 但壳无 img 灯箱接入（imgwrap）——壳版本过旧，用当前 shell_template.html 重组装')

    # 3 SVG 文本溢出估算：text 锚点落在某 rect 内则按锚定方式检查
    for si, svg in enumerate(re.findall(r'<svg.*?</svg>', html, re.S)):
        vb = re.search(r'viewBox="[\d.\s-]*?([\d.]+)\s+([\d.]+)"', svg)
        vbw = float(vb.group(1)) if vb else None
        rects = []
        for rm in re.finditer(r'<rect\b[^>]*>', svg):
            r = rm.group(0)
            def attr(name, default=None):
                m = re.search(r'%s="([-\d.]+)"' % name, r)
                return float(m.group(1)) if m else default
            x, y, w, h = attr('x', 0), attr('y', 0), attr('width'), attr('height')
            if w is not None and h is not None:
                rects.append((x, y, w, h))
        for tm in re.finditer(r'<text\b([^>]*)>(.*?)</text>', svg, re.S):
            attrs, inner = tm.group(1), tm.group(2)
            content = re.sub(r'<[^>]+>', '', inner)
            content = content.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
            if not content.strip():
                continue
            mx = re.search(r'\bx="([-\d.]+)"', attrs)
            my = re.search(r'\by="([-\d.]+)"', attrs)
            if not mx or not my:
                continue
            tx, ty = float(mx.group(1)), float(my.group(1))
            mfs = re.search(r'font-size="([\d.]+)"', attrs)
            fs = float(mfs.group(1)) if mfs else 14.0
            anchor = 'middle' if 'text-anchor="middle"' in attrs else ('end' if 'text-anchor="end"' in attrs else 'start')
            # tspan 分行取最宽行
            lines = re.findall(r'<tspan[^>]*>(.*?)</tspan>', inner, re.S) or [content]
            wmax = max(text_width(re.sub(r'<[^>]+>', '', l).replace('&amp;','&').replace('&lt;','<').replace('&gt;','>'), fs) for l in lines)
            # 找包含锚点的最小 rect
            host = None
            for (x, y, w, h) in rects:
                if x <= tx <= x + w and y <= ty <= y + h:
                    if host is None or w * h < host[2] * host[3]:
                        host = (x, y, w, h)
            if host:
                x, y, w, h = host
                if anchor == 'middle':
                    over = wmax - (w - 12)
                elif anchor == 'end':
                    over = (x + 6) - (tx - wmax)
                else:
                    over = (tx + wmax) - (x + w - 6)
                if over > 0:
                    msg = 'SVG#%d 文本溢出宿主框: "%s…" est=%.0fpx rect_w=%.0f anchor=%s over=%.0fpx' % \
                          (si + 1, content.strip()[:18], wmax, w, anchor, over)
                    (warns if over <= w * 0.05 else errs).append(msg)
            elif vbw:
                if anchor == 'middle':
                    fit = (tx - wmax/2 >= 0) and (tx + wmax/2 <= vbw)
                elif anchor == 'end':
                    fit = tx - wmax >= 0
                else:
                    fit = tx + wmax <= vbw
                if not fit:
                    errs.append('SVG#%d 文本出画布: "%s…" est=%.0fpx x=%.0f vbw=%.0f anchor=%s' %
                                (si + 1, content.strip()[:18], wmax, tx, vbw, anchor))
        # 4b SVG 裸 &
        for m in re.finditer(r'&(?!amp;|lt;|gt;|quot;|#)', svg):
            errs.append('SVG#%d 有裸 & (pos %d)' % (si + 1, m.start()))

    # 4 占位符
    for pat, name in [(r'TODO', 'TODO'), (r'FIXME', 'FIXME'), (r'\{\{[A-Z]+\}\}', '{{}}占位')]:
        if re.search(pat, html):
            errs.append('残留占位: %s' % name)

    # 5 code overflow-wrap
    if 'overflow-wrap:break-word' not in html:
        errs.append('code 缺 overflow-wrap:break-word')

    # 6 figure.diagram 结构：svg 必须由 div.scroll 包裹（灯箱 JS 只绑定 figure.diagram .scroll）
    for fi, fig in enumerate(re.findall(r'<figure class="diagram"[^>]*>.*?</figure>', html, re.S)):
        if '<svg' in fig and not re.search(r'<div class="scroll"[^>]*>\s*<svg', fig, re.S):
            errs.append('figure.diagram#%d 的 svg 缺 <div class="scroll"> 包裹（灯箱/横滚/悬浮提示全失效）' % (fi + 1))

    # 7 内嵌视频
    vids = re.findall(r'<video\b[^>]*>', html)
    for vi, v in enumerate(vids):
        if 'src="data:' in v:
            errs.append('video#%d 用了 src="data:…"（Safari 不稳）：改用 embed_video.py 生成的数据块 + data-src' % (vi + 1))
        if 'poster="' not in v:
            errs.append('video#%d 缺 poster 封面' % (vi + 1))
        m = re.search(r'data-src="([^"]+)"', v)
        if m and m.group(1) not in blobs:
            errs.append('video#%d data-src="%s" 找不到对应数据块' % (vi + 1, m.group(1)))
        if m and m.group(1)[:1].isdigit():
            errs.append('video#%d 的 id 数字开头：%s' % (vi + 1, m.group(1)))
    for fi, fig in enumerate(re.findall(r'<figure class="video"[^>]*>.*?</figure>', html, re.S)):
        if '<figcaption' not in fig:
            errs.append('figure.video#%d 缺 figcaption' % (fi + 1))
    if vids and 'hydrateVideo' not in html:
        errs.append('含 <video> 但壳无视频接入脚本（hydrateVideo）——用当前 shell_template.html 重组装')
    total = 0
    for k, n in blobs.items():
        size = n * 3 // 4
        total += size
        if size > 4 * 1048576:
            errs.append('视频数据块 %s 约 %.1f MB，超过单段 4 MB' % (k, size / 1048576))
    if total > 16 * 1048576:
        errs.append('内嵌视频合计约 %.1f MB，超过 16 MB 上限' % (total / 1048576))
    elif total > 8 * 1048576:
        warns.append('内嵌视频合计约 %.1f MB，超过 8 MB 建议值' % (total / 1048576))

    tag = 'PASS' if not errs else 'FAIL'
    print('[%s] %s' % (tag, path))
    for e in errs:
        print('   ✗ ' + e)
    for w in warns:
        print('   ⚠ ' + w)
    return not errs

if __name__ == '__main__':
    ok = all([check(p) for p in sys.argv[1:]])
    sys.exit(0 if ok else 1)
