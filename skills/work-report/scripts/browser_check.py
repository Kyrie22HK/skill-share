#!/usr/bin/env python3
"""用已有 Chrome 实测报告/导览的布局、图片、目录、灯箱与视频，保存 JSON 和截图。
用法：browser_check.py --html <成品.html> --out <证据目录> [--viewport 1600x1000]
仅依赖 Python 标准库与本地 Chrome（POSIX remote-debugging-pipe）。不安装依赖，不使用已有浏览器资料。
HTTP(S) 请求阻断；只打开指定本地文件。浏览器沙箱受宿主限制时可显式加 --no-sandbox，仍使用独立临时 profile。
机器检查不能代替事实审读和视觉判断。退出 0=所列机器断言通过，1=有失败，2=环境/调用错误。
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import sys
import subprocess
import tempfile
import time


class Chrome:
    def __init__(self, out, browser=None, no_sandbox=False):
        if os.name != 'posix':
            raise RuntimeError('此脚本使用 POSIX 管道；当前系统请用客户端浏览器工具完成同等验收')
        browser = browser or shutil.which('google-chrome') or shutil.which('chromium') or shutil.which('chromium-browser')
        if not browser:
            raise RuntimeError('未找到已有 Chrome/Chromium；请提供 --browser，或使用当前客户端浏览器工具，不自动安装')
        self.profile = tempfile.TemporaryDirectory(prefix='report-cdp-')
        self.log = open(out / 'chrome.stderr.log', 'wb')
        cr, pw = os.pipe()
        pr, cw = os.pipe()
        def setup():
            os.dup2(cr, 3)
            os.dup2(cw, 4)
        self.proc = subprocess.Popen([
            browser, '--headless=new', *(['--no-sandbox'] if no_sandbox else []),
            '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check',
            '--disable-background-networking', '--disable-component-update',
            '--disable-sync', '--remote-debugging-pipe',
            '--user-data-dir=' + self.profile.name, 'about:blank'
        ], pass_fds=tuple(set([cr, cw, 3, 4])), preexec_fn=setup,
            stdout=self.log, stderr=self.log)
        os.close(cr)
        os.close(cw)
        self.write, self.read = pw, pr
        self.buf, self.ident, self.events = b'', 0, []
        self.session = None
        self.version = self.call('Browser.getVersion')
        target = self.call('Target.createTarget', {'url': 'about:blank'})['targetId']
        self.session = self.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
        for domain in ['Page', 'Runtime', 'Log', 'Network']:
            self.call(domain + '.enable')
        self.call('Network.setBlockedURLs', {'urls': ['http://*', 'https://*']})

    def call(self, method, params=None, timeout=20):
        self.ident += 1
        ident = self.ident
        msg = {'id': ident, 'method': method, 'params': params or {}}
        if self.session:
            msg['sessionId'] = self.session
        os.write(self.write, json.dumps(msg).encode() + b'\0')
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if b'\0' not in self.buf:
                ready, _, _ = select.select([self.read], [], [], max(0, until - time.monotonic()))
                if not ready:
                    break
                data = os.read(self.read, 1024 * 1024)
                if not data:
                    raise RuntimeError('Chrome pipe closed; inspect chrome.stderr.log')
                self.buf += data
                continue
            raw, self.buf = self.buf.split(b'\0', 1)
            if not raw:
                continue
            result = json.loads(raw)
            if result.get('id') == ident:
                if 'error' in result:
                    raise RuntimeError(result['error'])
                return result.get('result', {})
            self.events.append(result)
        raise TimeoutError(method)

    def js(self, expression):
        r = self.call('Runtime.evaluate', {'expression': expression, 'returnByValue': True, 'awaitPromise': True})
        if 'exceptionDetails' in r:
            raise RuntimeError(r['exceptionDetails'])
        return r.get('result', {}).get('value')

    def shot(self, path):
        r = self.call('Page.captureScreenshot', {'format': 'png', 'captureBeyondViewport': False})
        path.write_bytes(base64.b64decode(r['data']))

    def click(self, selector, index=0):
        lookup = 'document.querySelectorAll(' + json.dumps(selector) + ')[' + str(index) + ']'
        self.js('(' + lookup + ').scrollIntoView({block:"center",inline:"nearest",behavior:"instant"})')
        time.sleep(.15)
        pt = self.js('(()=>{const r=(' + lookup + ').getBoundingClientRect();return {x:Math.max(1,Math.min(innerWidth-2,r.left+r.width/2)),y:Math.max(1,Math.min(innerHeight-2,r.top+r.height/2))}})()')
        self.click_point(pt['x'], pt['y'])
        return pt

    def click_point(self, x, y):
        for kind in ['mousePressed', 'mouseReleased']:
            self.call('Input.dispatchMouseEvent', {'type': kind, 'x': x, 'y': y, 'button': 'left', 'clickCount': 1})
        time.sleep(.25)

    def key(self, key):
        self.call('Input.dispatchKeyEvent', {'type': 'keyDown', 'key': key, 'code': key, 'windowsVirtualKeyCode': 27 if key == 'Escape' else 9})
        self.call('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': key, 'code': key})
        time.sleep(.15)

    def wait_top(self, timeout=5):
        start = time.monotonic()
        while time.monotonic() - start < timeout:
            value = self.js('scrollY')
            if value == 0:
                return {'afterY': value, 'waitSeconds': round(time.monotonic() - start, 3)}
            time.sleep(.1)
        return {'afterY': self.js('scrollY'), 'waitSeconds': round(time.monotonic() - start, 3)}

    def close(self):
        try:
            self.call('Browser.close', timeout=3)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        os.close(self.write)
        os.close(self.read)
        self.log.close()
        self.profile.cleanup()


METRICS = r'''(()=>{
const rect=e=>{const r=e.getBoundingClientRect();return {x:Math.round(r.x),y:Math.round(r.y+scrollY),w:Math.round(r.width),h:Math.round(r.height)}};
const label=e=>(e.innerText||e.textContent||'').trim().replace(/\s+/g,' ').slice(0,180);
const all=[...document.querySelectorAll('main *, .wrap *')];
return {title:document.title,viewport:{w:innerWidth,h:innerHeight},document:{w:document.documentElement.scrollWidth,h:document.documentElement.scrollHeight},
bodyFont:getComputedStyle(document.body).fontFamily,bodySize:getComputedStyle(document.body).fontSize,
tocVisible:getComputedStyle(document.querySelector('.side-toc')).display!=='none',
toc:[...document.querySelectorAll('.side-toc a')].map(e=>({text:label(e),href:e.getAttribute('href'),exists:!!document.querySelector(e.getAttribute('href'))})),
headings:[...document.querySelectorAll('h1,h2,h3')].map(e=>({tag:e.tagName,id:e.id,text:label(e),rect:rect(e)})),
figures:[...document.querySelectorAll('figure')].map(e=>({text:label(e.querySelector('figcaption')||e),rect:rect(e),svg:!!e.querySelector('svg')})),
tables:[...document.querySelectorAll('.wrap table')].map(e=>({rows:e.rows.length,columns:e.rows[0]?.cells.length,rect:rect(e),text:label(e)})),
images:[...document.querySelectorAll('.wrap img')].map(e=>({alt:e.alt,loaded:e.complete&&e.naturalWidth>0,naturalWidth:e.naturalWidth,naturalHeight:e.naturalHeight,rect:rect(e)})),
videos:[...document.querySelectorAll('video')].map(e=>({readyState:e.readyState,error:e.error?.message||null,src:e.getAttribute('src')?.slice(0,60)})),
details:[...document.querySelectorAll('details')].map(e=>({text:label(e.querySelector('summary')),open:e.open})),
overflow:all.filter(e=>{const r=e.getBoundingClientRect();if(!r.width||!r.height)return false; const p=e.closest('.scroll,pre'); if(p&&p!==e)return false;return r.right>innerWidth+2||r.left< -2}).slice(0,35).map(e=>({tag:e.tagName,class:e.className?.baseVal??e.className,text:label(e).slice(0,90),rect:rect(e)})),
localScroll:[...document.querySelectorAll('.scroll,pre')].filter(e=>e.scrollWidth>e.clientWidth+2).map(e=>({tag:e.tagName,class:e.className,clientWidth:e.clientWidth,scrollWidth:e.scrollWidth,rect:rect(e)}))};})()'''


def lb_state(c):
    return c.js('(()=>{const e=document.querySelector("#lb"),s=e.querySelector(".lb-stage");const r=s.getBoundingClientRect();return {open:e.classList.contains("open"),pct:e.querySelector(".pct").textContent,transform:s.style.transform,bodyOverflow:document.body.style.overflow,stage:{x:r.x,y:r.y,w:r.width,h:r.height},svgWidths:[...s.querySelectorAll("svg")].map(x=>x.getBoundingClientRect().width)}})()')


def audit(c, path, dest, width, height):
    dest.mkdir(parents=True, exist_ok=True)
    start_event = len(c.events)
    c.call('Emulation.setDeviceMetricsOverride', {'width': width, 'height': height, 'deviceScaleFactor': 1, 'mobile': False})
    c.call('Page.navigate', {'url': path.as_uri()})
    for _ in range(50):
        if c.js('document.readyState') == 'complete' and c.js('location.href') == path.as_uri():
            break
        time.sleep(.1)
    if c.js('location.href') != path.as_uri():
        raise RuntimeError('页面未成功导航到指定文件')
    c.js('document.fonts.ready.then(()=>true)')
    c.js('Promise.all([...document.images].map(i=>i.decode().catch(()=>null))).then(()=>true)')
    time.sleep(.2)
    result = {'input': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'metrics': c.js(METRICS), 'interactions': {}}
    c.shot(dest / '01-top.png')
    c.js('scrollTo({top:innerHeight*.78,behavior:"instant"})')
    time.sleep(.2)
    c.shot(dest / '02-continuation.png')
    c.js('scrollTo({top:document.documentElement.scrollHeight*.5,behavior:"instant"})')
    time.sleep(.2)
    c.shot(dest / '03-middle.png')
    ints = result['interactions']
    if result['metrics']['tocVisible']:
        index = min(3, len(result['metrics']['toc']) - 1)
        href = result['metrics']['toc'][index]['href']
        point = c.click('.side-toc a', index)
        time.sleep(1.1)
        ints['toc'] = {'clicked': href, 'point': point, 'after': c.js('({hash:location.hash,scrollY,active:[...document.querySelectorAll(".side-toc a.active")].map(e=>e.getAttribute("href")),targetTop:document.querySelector(' + json.dumps(href) + ').getBoundingClientRect().top})')}
        c.shot(dest / '04-toc-target.png')
    else:
        ints['toc'] = {'status': 'not available at this viewport; CSS hides sidebar and there is no mobile replacement'}
    c.js('scrollTo({top:document.documentElement.scrollHeight*.65,behavior:"instant"})')
    time.sleep(.2)
    ints['progress'] = c.js('({scrollY,progressStyle:document.querySelector("#prog").style.width,backtopVisible:getComputedStyle(document.querySelector("#backtop")).opacity})')
    c.click('#backtop')
    ints['backtop'] = c.wait_top()
    n = c.js('document.querySelectorAll(".wrap .zoomable").length')
    ints['lightboxTargets'] = n
    if n:
        c.js('document.querySelector(".wrap .zoomable").scrollIntoView({block:"center",behavior:"instant"})')
        time.sleep(.2)
        c.shot(dest / '05-figure.png')
        c.click('.wrap .zoomable')
        ints['lightboxOpen'] = lb_state(c)
        c.shot(dest / '06-lightbox-100.png')
        c.click('#lb [data-act="plus"]')
        ints['lightboxPlus'] = lb_state(c)
        c.shot(dest / '07-lightbox-125.png')
        c.click('#lb [data-act="minus"]')
        ints['lightboxMinus'] = lb_state(c)
        c.call('Input.dispatchMouseEvent', {'type': 'mouseWheel', 'x': width / 2, 'y': height / 2, 'deltaX': 0, 'deltaY': -100})
        time.sleep(.2)
        ints['lightboxWheel'] = lb_state(c)
        c.click('#lb [data-act="reset"]')
        ints['lightboxReset'] = lb_state(c)
        c.key('Escape')
        ints['lightboxEscape'] = lb_state(c)
        c.click('.wrap .zoomable')
        c.click('#lb [data-act="close"]')
        ints['lightboxCloseButton'] = lb_state(c)
        c.click('.wrap .zoomable')
        c.click_point(8, height / 2)
        ints['lightboxBackdrop'] = lb_state(c)
        if ints['lightboxBackdrop']['open']:
            c.key('Escape')
        # The last target checks a different image/diagram and its loading state.
        if n > 1:
            c.click('.wrap .zoomable', n - 1)
            ints['lastTargetOpen'] = lb_state(c)
            c.shot(dest / '08-last-lightbox.png')
            c.key('Escape')
    count = c.js('document.querySelectorAll("details").length')
    if count:
        before = c.js('document.querySelector("details").open')
        c.click('details summary')
        after = c.js('document.querySelector("details").open')
        ints['details'] = {'before': before, 'after': after}
        c.shot(dest / '09-details-toggle.png')
        c.click('details summary')
    else:
        ints['details'] = {'status': 'not present'}
    ints['videos'] = []
    for vi in range(c.js('document.querySelectorAll("video").length')):
        video = 'document.querySelectorAll("video")[' + str(vi) + ']'
        c.js(video + '.scrollIntoView({block:"center",behavior:"instant"})')
        time.sleep(.3)
        playback = c.js('(async()=>{const v=' + video + ';v.muted=true;try{await v.play();const start=v.currentTime;await new Promise(r=>setTimeout(r,1200));const end=v.currentTime;const result={start,end,advanced:end!==start,width:v.videoWidth,height:v.videoHeight,readyState:v.readyState,error:v.error?.message||null};v.pause();return result}catch(e){return {advanced:false,error:String(e)}}})()')
        ints['videos'].append(playback)
        c.shot(dest / ('video-' + str(vi + 1) + '.png'))
    c.js('scrollTo({top:document.documentElement.scrollHeight,behavior:"instant"})')
    time.sleep(.2)
    c.shot(dest / '10-bottom.png')
    result['events'] = [e for e in c.events[start_event:] if e.get('method') in ['Runtime.exceptionThrown', 'Log.entryAdded', 'Network.loadingFailed']]
    failures = []
    if result['metrics']['document']['w'] > width + 2:
        failures.append('全页横向溢出')
    if any(not i['loaded'] for i in result['metrics']['images']):
        failures.append('图片加载失败')
    if any(e.get('method') == 'Runtime.exceptionThrown' for e in result['events']):
        failures.append('页面 JavaScript 异常')
    if ints['backtop']['afterY'] != 0:
        failures.append('回到顶部未完成')
    if result['metrics']['tocVisible'] and ints['toc']['clicked'] not in ints['toc']['after']['active']:
        failures.append('目录点击后 scroll-spy 未高亮目标')
    if n:
        if not ints['lightboxOpen']['open'] or not ints.get('lastTargetOpen', ints['lightboxOpen'])['open']:
            failures.append('灯箱未打开')
        if ints['lightboxPlus']['pct'] == ints['lightboxOpen']['pct'] or ints['lightboxWheel']['pct'] == ints['lightboxMinus']['pct']:
            failures.append('灯箱缩放未生效')
        if ints['lightboxReset']['pct'] != '100%':
            failures.append('灯箱复位失败')
        for key in ['lightboxEscape', 'lightboxCloseButton', 'lightboxBackdrop']:
            if ints[key]['open']:
                failures.append(key + ' 未关闭')
    if count and ints['details']['before'] == ints['details']['after']:
        failures.append('折叠区未切换')
    if any(not v['advanced'] or not v.get('width') for v in ints['videos']):
        failures.append('视频未实际解码并推进播放')
    result['failures'] = failures
    result['passed'] = not failures
    (dest / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True, help='截图和 JSON 证据目录')
    parser.add_argument('--html', type=Path, action='append', required=True, help='成品 HTML，可重复指定')
    parser.add_argument('--browser', help='已有 Chrome/Chromium 可执行路径')
    parser.add_argument('--no-sandbox', action='store_true', help='仅在宿主不能运行 Chrome 沙箱时显式使用')
    parser.add_argument('--viewport', action='append', help='WIDTHxHEIGHT; repeat for several sizes. Defaults: 1600x1000, 1024x900, 390x844.')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not all(p.is_file() for p in args.html):
        parser.error('所有 --html 必须为已存在的本地文件')
    c = Chrome(out, args.browser, args.no_sandbox)
    all_results = {'browser': c.version, 'mode': 'headless local Chrome, CDP real mouse/key input, HTTP(S) blocked, isolated temporary profile', 'results': []}
    try:
        inputs = args.html
        viewports = [tuple(map(int, s.lower().split('x'))) for s in args.viewport] if args.viewport else [(1600, 1000), (1024, 900), (390, 844)]
        for path in inputs:
            name = path.stem
            for width, height in viewports:
                print('Audit', name, width, height, flush=True)
                res = audit(c, path.resolve(), out / name / str(width), width, height)
                all_results['results'].append(res)
                (out / 'results.json').write_text(json.dumps(all_results, ensure_ascii=False, indent=2))
    finally:
        c.close()
    all_results['passed'] = all(r['passed'] for r in all_results['results'])
    (out / 'results.json').write_text(json.dumps(all_results, ensure_ascii=False, indent=2))
    print('PASS' if all_results['passed'] else 'FAIL', out / 'results.json', flush=True)
    return 0 if all_results['passed'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, TimeoutError) as exc:
        print('浏览器检查未完成：' + str(exc), file=sys.stderr)
        sys.exit(2)
