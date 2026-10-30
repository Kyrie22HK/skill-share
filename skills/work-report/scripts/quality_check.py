#!/usr/bin/env python3
"""报告/导览的共享壳和内容结构检查；不代替浏览器或事实审读。仅用标准库。"""
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import re


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.nodes = []
        self.styles = []
        self.scripts = []
        self.capture = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.nodes.append((tag, attrs))
        if tag == 'style':
            self.styles.append('')
            self.capture = self.styles
        elif tag == 'script':
            kind = attrs.get('type', '').lower()
            if kind in ('', 'text/javascript', 'application/javascript', 'module'):
                self.scripts.append('')
                self.capture = self.scripts

    def handle_endtag(self, tag):
        if tag in ('style', 'script'):
            self.capture = None

    def handle_data(self, data):
        if self.capture is not None:
            self.capture[-1] += data

    def has_class(self, *names):
        return any(set(names) <= set(attrs.get('class', '').split()) for _, attrs in self.nodes)


def check_quality(path, profile):
    text = Path(path).read_text(encoding='utf-8')
    doc = Document(text)
    shell = Document(Path(__file__).resolve().with_name('shell_template.html').read_text(encoding='utf-8'))
    errors = []
    if not doc.styles or doc.styles[0].strip() != shell.styles[0].strip():
        errors.append('共享壳 CSS 与权威模板不一致：用当前 assemble.py 重新组装，不手写或覆盖主题')
    if [s.strip() for s in doc.scripts] != [s.strip() for s in shell.scripts]:
        errors.append('共享壳可执行 JS 与权威模板不一致：不能删除交互或另写替代壳')
    if profile == 'report' and len(doc.styles) != 1:
        errors.append('报告应只使用共享壳样式；内容排版使用既有组件，不另加全局样式')
    if profile == 'tour':
        for css in doc.styles[1:]:
            clean = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
            for selector in re.findall(r'([^{}]+)\{', clean):
                if selector.strip().startswith('@media'):
                    continue
                for part in selector.split(','):
                    if not re.match(r'\s*(?:\.tour-[\w-]+|\.hero\b|\.read-path[\w-]*\b|a\.ref\b)', part):
                        errors.append('导览扩展 CSS 需限定在 .tour-* / .hero / .read-path* / a.ref 内：' + part.strip())
    ids = [a['id'] for _, a in doc.nodes if a.get('id')]
    duplicate = [name for name, count in Counter(ids).items() if count > 1]
    if duplicate:
        errors.append('重复 id：' + ', '.join(duplicate))
    for tag, attrs in doc.nodes:
        if tag == 'a' and attrs.get('href', '').startswith('#'):
            target = attrs['href'][1:]
            if target and target not in ids:
                errors.append('正文/目录引用无目标：#' + target)
        for key in ('src', 'poster', 'srcset'):
            value = attrs.get(key)
            if value and not value.startswith('data:'):
                errors.append(f'{tag} 的 {key} 依赖外部/本地资源，不能单文件交付')
        if tag == 'link' and attrs.get('href') and set(attrs.get('rel', '').split()) & {'stylesheet', 'preload', 'icon'}:
            errors.append('link 引用了外部资源，需内嵌')
        if tag in ('iframe', 'object', 'embed'):
            errors.append('存在外部嵌入对象，需改为自包含证据')
        if tag == 'image':
            href = attrs.get('href') or attrs.get('xlink:href')
            if href and not href.startswith('data:'):
                errors.append('SVG image 依赖外部图片')
    for css in doc.styles:
        if re.search(r'@import\b|url\(\s*[\"\x27]?(?!data:|#)[^\s\"\x27)]', css, re.I):
            errors.append('CSS 含外部资源或 @import，需内嵌')
    if sum(tag == 'h1' for tag, _ in doc.nodes) != 1:
        errors.append('应有且仅有一个主标题 h1')
    if not any(tag == 'h2' for tag, _ in doc.nodes):
        errors.append('缺少可导航的正文章节')
    if not doc.has_class('wrap') or not doc.has_class('side-toc'):
        errors.append('缺少共享壳主体或目录')
    if profile == 'report' and not doc.has_class('card', 'verdict'):
        errors.append('缺概要结论卡 .card.verdict：先完成内容编排，不能只把 Markdown 逐段转 HTML')
    if profile == 'tour' and not (doc.has_class('hero') or doc.has_class('tour-hero')):
        errors.append('导览缺 Hero 总览（.hero 或 .tour-hero），需包含事实和阅读路径')
    return errors
