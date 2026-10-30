#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一段录屏 / 演示视频做成可内嵌进报告 HTML 的片段（skill 第二节「视觉证据内嵌」的视频版）。
用法: embed_video.py <输入视频> <输出前缀> --caption "视频 N　说明" [选项]
选项:
  --id ID          片段里的视频 id（缺省取输出前缀的文件名，前面补 vid-；不得数字开头）
  --ss 秒          从第几秒开始截（缺省 0）
  --t 秒           截多长（缺省到结尾；演示一般 5–15 s 足够）
  --box 像素       长边上限（缺省 960；只缩不放，宽高取偶数）
  --fps 帧率       输出帧率（缺省 30；纯界面演示可降到 24 / 20 省体积）
  --crf 值         H.264 质量（缺省 30，数值越大越小越糊；界面录屏 28–32 合适）
  --speed 倍数     播放速度（缺省 1；0.5＝半速，界面过渡这类一闪而过的动画放慢看；图注里注明）
  --poster-at 秒   封面取第几秒（相对截取后的片段，缺省 0.5）
产物:
  <前缀>.mp4         转码后的演示视频（H.264 / yuv420p / faststart / 无音轨），留在证据目录，不作为 md 附件引用
  <前缀>.poster.jpg  封面
  <前缀>.frag.html   粘进内容片段的 HTML：figure.video（含 base64 封面）+ 视频数据块
                     <script type="application/octet-stream" id="…">；壳模板的脚本在视频接近视口时把它转成 Blob 地址播放
体积：单段转码后建议 ≤ 2 MB（超 4 MB 本工具报错退出，selfcheck 同样拦）；整份报告视频合计建议 ≤ 8 MB。
"""
import argparse, base64, os, re, subprocess, sys

WARN_BYTES = 2 * 1024 * 1024
MAX_BYTES = 4 * 1024 * 1024


def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        sys.exit('ffmpeg 失败：\n' + ' '.join(cmd) + '\n' + r.stderr[-1500:])
    return r


def probe(path):
    r = run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
             'stream=width,height:format=duration', '-of', 'default=nw=1', path])
    kv = dict(l.split('=', 1) for l in r.stdout.split() if '=' in l)
    return int(kv.get('width', 0)), int(kv.get('height', 0)), float(kv.get('duration', 0) or 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('src')
    ap.add_argument('out_prefix')
    ap.add_argument('--caption', required=True)
    ap.add_argument('--id')
    ap.add_argument('--ss', type=float, default=0.0)
    ap.add_argument('--t', type=float)
    ap.add_argument('--box', type=int, default=960)
    ap.add_argument('--fps', type=int, default=30)
    ap.add_argument('--crf', type=int, default=30)
    ap.add_argument('--poster-at', type=float, default=0.5)
    ap.add_argument('--speed', type=float, default=1.0)
    a = ap.parse_args()

    vid = a.id or 'vid-' + re.sub(r'[^A-Za-z0-9_-]+', '-', os.path.basename(a.out_prefix)).strip('-')
    if not re.match(r'^[A-Za-z][A-Za-z0-9_-]*$', vid):
        sys.exit('--id 须字母开头、只含字母数字 - _：%s' % vid)
    mp4, poster, frag = a.out_prefix + '.mp4', a.out_prefix + '.poster.jpg', a.out_prefix + '.frag.html'
    os.makedirs(os.path.dirname(os.path.abspath(mp4)), exist_ok=True)

    box = a.box
    # 只缩不放：横屏按宽、竖屏按高限到 box，另一边 -2 保持比例且取偶数
    vf = ("fps=%d,scale='if(gt(iw,ih),min(%d,iw),-2)':'if(gt(iw,ih),-2,min(%d,ih))'" % (a.fps, box, box))
    if a.speed != 1.0:
        if a.speed <= 0:
            sys.exit('--speed 须大于 0')
        vf = 'setpts=PTS/%g,' % a.speed + vf
    cmd = ['ffmpeg', '-y', '-v', 'error']
    if a.ss:
        cmd += ['-ss', str(a.ss)]
    cmd += ['-i', a.src]
    if a.t:
        cmd += ['-t', str(a.t)]
    cmd += ['-an', '-vf', vf, '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.1', '-pix_fmt', 'yuv420p',
            '-preset', 'slow', '-crf', str(a.crf), '-movflags', '+faststart', mp4]
    run(cmd)
    w, h, dur = probe(mp4)
    run(['ffmpeg', '-y', '-v', 'error', '-ss', str(min(a.poster_at, max(dur - 0.1, 0))), '-i', mp4,
         '-frames:v', '1', '-q:v', '4', poster])

    size = os.path.getsize(mp4)
    if size > MAX_BYTES:
        sys.exit('转码后 %.2f MB，超过单段上限 4 MB：缩短 --t、调大 --crf 或调小 --box / --fps' % (size / 1048576))

    b64 = base64.b64encode(open(mp4, 'rb').read()).decode()
    poster_b64 = base64.b64encode(open(poster, 'rb').read()).decode()
    lines = '\n'.join(b64[i:i + 4096] for i in range(0, len(b64), 4096))
    cap = a.caption.replace('&', '&amp;').replace('<', '&lt;')
    html = ('<figure class="video">\n'
            '  <video controls muted playsinline loop preload="metadata" width="%d" height="%d" '
            'poster="data:image/jpeg;base64,%s" data-src="%s"></video>\n'
            '  <figcaption>%s</figcaption>\n'
            '</figure>\n'
            '<script type="application/octet-stream" id="%s" data-mime="video/mp4">\n%s\n</script>\n'
            % (w, h, poster_b64, vid, cap, vid, lines))
    open(frag, 'w', encoding='utf-8').write(html)

    print('视频   %s  %dx%d  %.1f s  %.2f MB%s' % (mp4, w, h, dur, size / 1048576,
          '  ⚠ 超过 2 MB 建议值' if size > WARN_BYTES else ''))
    print('封面   %s' % poster)
    print('片段   %s（id=%s，内嵌后约 %.2f MB）' % (frag, vid, len(html.encode()) / 1048576))
    print('md 版  ▶ %s（视频见 HTML 版）；转码原件留在证据目录' % a.caption)


if __name__ == '__main__':
    main()
