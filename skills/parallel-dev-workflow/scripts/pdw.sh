#!/bin/bash
# 并行开发任务管家。一次调用 skill ＝ 一轮任务：init 建集成线（任务）→ device add 登记设备锁 → line new 开功能线
# → 开发中随时加线 / 加减设备 → 各线合并后 line rm → 全部收完 close 关闭集成线（归档并清理），本轮结束。
#
# 任务：
#   pdw.sh init <任务名> --repo <短名>=<路径>[@<基线分支>] [--repo …] [--root <根目录>] [--archive <归档目录>]
#               [--port <变量>=<基数>[:<步长>]] [--env '<变量>=<模板>'] [--hardlink <短名>:<相对路径>] [--post-new '<命令>']
#                                     在 <根>（缺省为当前目录）建 .pdw/：配置、任务卡、设备登记、锁、脚本副本
#   pdw.sh status                     本轮总览：设备与锁、各线分支状态、集成线各仓库状态
#   pdw.sh close [--force]            关闭集成线：还有线没收、还有别人持锁就拒绝；归档（缺省 <根>/.pdw-archive/）并清理
# 设备：
#   pdw.sh device add <名> --idle <分钟> [--desc "<说明>"] [--ip <IP>] [--baseline "<放锁前要回到的状态>"]
#   pdw.sh device rm <名> [--force]    下线设备（被持锁或有人排队就拒绝）
#   pdw.sh device list
# 功能线：
#   pdw.sh line new <线名> [--repos <短名,短名>] "<一句话目标>"   开线：各仓库 worktree + .line.env + 状态卡
#   pdw.sh line start <线名>          功能线会话起手简报（目录、分支、端口、锁、用锁规则、状态卡）
#   pdw.sh line list
#   pdw.sh line env <线名>
#   pdw.sh line rm <线名> [--force]   收线：未提交 / 未合并进基线 / 还持锁的拒绝；状态卡移入 cards/_done/
#
# <线名> 只许小写字母数字连字符；分支一律 feat/<线名>；线目录 <根>/wt/<线名>/。
set -euo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
die() { echo "pdw: $*" >&2; exit 1; }
now() { date '+%m-%d %H:%M'; }

# ---------------- init（不需要已有任务）----------------
cmd_init() {
    local task=${1:-}; [[ -n $task && $task != --* ]] || die "pdw.sh init <任务名> --repo <短名>=<路径>[@<基线>] …"; shift
    local root=$PWD repos=() ports=() envs=() hls=() post="" archive=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --root) root=$2; shift 2 ;;
            --archive) archive=$2; shift 2 ;;
            --repo) repos+=("$2"); shift 2 ;;
            --port) ports+=("$2"); shift 2 ;;
            --env) envs+=("$2"); shift 2 ;;
            --hardlink) hls+=("$2"); shift 2 ;;
            --post-new) post=$2; shift 2 ;;
            *) die "未知参数 $1" ;;
        esac
    done
    root=$(cd "$root" && pwd)
    [[ -z $archive || $archive == /* ]] || archive=$root/$archive
    [[ ! -e $root/.pdw ]] || die "$root 已有进行中的任务（.pdw/）。先 pdw.sh close，或换根目录"
    (( ${#repos[@]} )) || die "至少给一个 --repo <短名>=<路径>[@<基线分支>]"
    local r name path base var lines=()
    for r in "${repos[@]}"; do
        name=${r%%=*}; path=${r#*=}; base=""
        [[ $path == *@* ]] && { base=${path##*@}; path=${path%@*}; }
        [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || die "仓库短名只许小写字母数字连字符：$name"
        [[ $path == /* ]] || path=$root/$path
        path=$(cd "$path" 2>/dev/null && pwd) || die "仓库路径不存在：${r#*=}"
        git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || die "$path 不是 git 仓库"
        [[ -n $base ]] || base=$(git -C "$path" branch --show-current)
        git -C "$path" rev-parse --verify -q "$base" >/dev/null || die "仓库 $name 没有基线分支 $base"
        var=$(echo "${name}_DIR" | tr 'a-z-' 'A-Z_')
        lines+=("    \"$name:$path:$base:$var\"")
    done
    mkdir -p "$root/.pdw/devices" "$root/.pdw/locks" "$root/.pdw/cards/_done" "$root/.pdw/bin" "$root/wt"
    cp "$SELF/pdw.sh" "$SELF/lock.sh" "$SELF/pdw_env.sh" "$root/.pdw/bin/"
    chmod +x "$root/.pdw/bin/"*.sh
    {
        echo "# 本轮并行开发任务的配置（pdw.sh init 生成于 $(date '+%F %T')；可手改，改完对新开的线生效）"
        echo "PDW_TASK='$task'"
        echo "PDW_SINCE='$(date '+%F %T')'"
        echo "# 仓库：<短名>:<主目录>:<基线分支>:<线环境里指向它的变量名>（主目录即集成线的工作目录）"
        echo "PDW_REPOS=("; printf '%s\n' "${lines[@]}"; echo ")"
        echo "PDW_DEFAULT_REPOS=$(echo "${repos[0]%%=*}")"
        echo "# 端口按线号错开：<变量>:<基数>:<步长>"
        echo "PDW_PORTS=("; for r in "${ports[@]:-}"; do [[ -n $r ]] || continue; name=${r%%=*}; base=${r#*=}; [[ $base == *:* ]] || base=$base:10; echo "    \"$name:$base\""; done; echo ")"
        echo "# 线环境的其他变量（开线时展开，可用 \$PDW_DIR \$PDW_LINE \$PDW_SEQ）"
        echo "PDW_EXTRA_ENV=("; for r in "${envs[@]:-}"; do [[ -n $r ]] && printf "    %q\n" "$r"; done; echo ")"
        echo "# 新 worktree 里从主目录硬链接拷一份的大目录：<短名>:<相对路径>"
        echo "PDW_HARDLINK_DIRS=("; for r in "${hls[@]:-}"; do [[ -n $r ]] && echo "    \"$r\""; done; echo ")"
        printf 'PDW_POST_NEW=%q\n' "$post"
        echo "# 关闭一轮时归档到哪个目录（空＝<根>/.pdw-archive；项目有自己的工作区 / 文档目录时用 init --archive 指过去）"
        echo "PDW_ARCHIVE_DIR='$archive'"
        echo "LOCK_DEFAULT_TTL=30m"
        echo "LOCK_IDLE_MARGIN=10"
    } >"$root/.pdw/conf.sh"
    cat >"$root/.pdw/task.md" <<EOF
# 并行开发任务：$task

> 集成线的任务卡（本轮总账）。开始 $(now)。根目录 \`$root\`。功能线不改本卡；集成线合并、收线时更新。
> 工具：\`.pdw/bin/pdw.sh\`（任务 / 设备 / 线）、\`.pdw/bin/lock.sh\`（设备锁）。全部收线后 \`pdw.sh close\` 关闭本轮。

## 目标（用户原话）
-

## 功能清单与开线研判
| 功能 | 一句话目标 | 涉及仓库 | 交叠文件 | 研判（开线 / 串行 / 子代理 / 不做） |
|---|---|---|---|---|

## 设备
（pdw.sh device add 登记；下方事件里有增减记录）

## 合并顺序与冲突预判
-

## 合并记录
-

## 摩擦与经验（收口时汇总）
-

## 事件（脚本自动追加）
- $(now) 开始任务 $task；仓库：$(printf '%s ' "${repos[@]}")
EOF
    # 根目录本身在某个 git 仓库里：把任务目录加进该仓库的本地忽略（不改受跟踪的 .gitignore）
    local top; top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n $top ]]; then
        local ex; ex=$(git -C "$root" rev-parse --git-path info/exclude)
        [[ $ex == /* ]] || ex=$root/$ex
        for r in .pdw/ .pdw-archive/ wt/; do grep -qxF "$r" "$ex" 2>/dev/null || echo "$r" >>"$ex"; done
        echo "   （根目录在 git 仓库 $top 里：.pdw/ .pdw-archive/ wt/ 已加进它的本地忽略 info/exclude）"
    fi
    echo "== 任务「$task」已建：$root/.pdw/"
    echo "   下一步：登记设备 $root/.pdw/bin/pdw.sh device add <名> --idle <分钟> --baseline \"…\"；开线 … line new <线名> \"<目标>\""
}

# ---------------- 以下都需要进行中的任务 ----------------
load_task() {
    source "$SELF/pdw_env.sh"
    pdw_need_task
    WTROOT=$PDW_ROOT/wt; CARDS=$PDW_STATE/cards; LOCKDIR=$PDW_STATE/locks
    mkdir -p "$WTROOT" "$CARDS/_done"
}
event() { echo "- $(now) $*" >>"$PDW_STATE/task.md"; }
name_ok() { [[ $1 =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "名字只许小写字母数字连字符、2–31 个字符：$1"; }
repo_get() { local e; for e in "${PDW_REPOS[@]}"; do [[ ${e%%:*} == "$1" ]] && { echo "$e" | cut -d: -f"$2"; return 0; }; done; return 1; }
repo_names() { local e; for e in "${PDW_REPOS[@]}"; do echo "${e%%:*}"; done; }
line_repos() { sed -n 's/^export PDW_REPOS_IN=//p' "$WTROOT/$1/.line.env" | tr ',' ' '; }
dirty_count() { git -C "$1" status --porcelain | wc -l; }
branch_line() {
    local ab
    ab=$(git -C "$1" rev-list --left-right --count "$2...HEAD" 2>/dev/null | awk '{print "落后"$1" 领先"$2}' || true)
    echo "$(git -C "$1" branch --show-current)（${ab:-无基线}，未提交 $(dirty_count "$1") 个文件）"
}
locks_of() {
    local f
    for f in "$LOCKDIR"/*; do
        [[ -f $f && $(basename "$f") != .* ]] || continue
        [[ $(sed -n 's/^owner=//p' "$f") == "$1" ]] && printf '%s ' "$(basename "$f")"
    done
    return 0
}
lines_active() { local d; for d in "$WTROOT"/*/; do [[ -f $d/.line.env ]] && basename "$d"; done; return 0; }

# ---------------- device ----------------
cmd_device() {
    local sub=${1:-}; shift || true
    case $sub in
        add)
            local n=${1:-}; shift || true; name_ok "$n"
            local idle="" desc="" ip="" bl=""
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --idle) idle=$2; shift 2 ;; --desc) desc=$2; shift 2 ;;
                    --ip) ip=$2; shift 2 ;; --baseline) bl=$2; shift 2 ;;
                    *) die "未知参数 $1" ;;
                esac
            done
            [[ $idle =~ ^[0-9]+$ ]] || die "要给 --idle <分钟>：闲置留锁上限，按归还成本定（板子回基线约 1 分钟→10；手机要卸包清绑定→20；无归还成本的工具→5）"
            local f=$PDW_STATE/devices/$n
            local verb=登记; [[ -f $f ]] && verb=更新
            printf 'idle_max=%s\ndesc=%s\nip=%s\nbaseline=%s\n' "$idle" "$desc" "$ip" "$bl" >"$f"
            event "${verb}设备 $n（闲置上限 ${idle} 分钟${desc:+；$desc}${ip:+；$ip}${bl:+；基线：$bl}）"
            echo "== 设备 $n 已${verb}（闲置上限 $idle 分钟）" ;;
        rm)
            local n=${1:-} force=${2:-}; [[ -f $PDW_STATE/devices/$n ]] || die "没有登记设备 $n"
            if [[ $force != --force ]]; then
                [[ ! -f $LOCKDIR/$n ]] || die "设备 $n 正被 $(sed -n 's/^owner=//p' "$LOCKDIR/$n") 持有，先等它放锁（或 --force）"
                [[ -z $(ls -A "$LOCKDIR/$n.q" 2>/dev/null) ]] || die "设备 $n 有人在排队，先协调（或 --force）"
            fi
            rm -f "$PDW_STATE/devices/$n" "$LOCKDIR/$n"; rm -rf "$LOCKDIR/$n.q"
            event "下线设备 $n"; echo "== 设备 $n 已下线" ;;
        list|"")
            local d
            for d in $(dev_list); do
                printf '%-14s 闲置上限 %3s 分钟  %s%s%s\n' "$d" "$(dev_field "$d" idle_max)" "$(dev_field "$d" desc)" \
                    "$( [[ -n $(dev_field "$d" ip) ]] && echo "  IP $(dev_field "$d" ip)")" \
                    "$( [[ -n $(dev_field "$d" baseline) ]] && echo "  基线：$(dev_field "$d" baseline)")"
            done ;;
        *) die "pdw.sh device add|rm|list" ;;
    esac
}

# ---------------- line ----------------
line_new() {
    local name=${1:-}; [[ -n $name ]] || die "pdw.sh line new <线名> [--repos a,b] \"<目标>\""; shift
    name_ok "$name"
    local repos=$PDW_DEFAULT_REPOS goal=""
    while [[ $# -gt 0 ]]; do
        case $1 in --repos) repos=$2; shift ;; *) goal=$1 ;; esac; shift
    done
    [[ -n $goal ]] || die "要给一句话目标（写进状态卡）"
    local d=$WTROOT/$name
    [[ ! -e $d ]] || die "线 $name 已存在：$d"
    local r dir base sel=()
    IFS=, read -ra sel <<<"$repos"
    for r in "${sel[@]}"; do
        dir=$(repo_get "$r" 2) || die "本轮没有仓库短名 $r（有：$(repo_names | tr '\n' ' ')）"
        git -C "$dir" show-ref --quiet "refs/heads/feat/$name" && die "仓库 $r 已有分支 feat/$name（上一轮遗留？先删分支或换线名）"
    done
    local seq; seq=$(( $(cat "$PDW_STATE/seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" >"$PDW_STATE/seq"
    mkdir -p "$d"
    echo "== 开线 $name（#$seq，仓库 ${sel[*]}）"
    local h
    for r in "${sel[@]}"; do
        dir=$(repo_get "$r" 2); base=$(repo_get "$r" 3)
        echo "-- $r：worktree $d/$(basename "$dir") ← $base"
        git -C "$dir" worktree add -q -b "feat/$name" "$d/$(basename "$dir")" "$base"
        for h in "${PDW_HARDLINK_DIRS[@]:-}"; do
            [[ -n $h && ${h%%:*} == "$r" ]] || continue
            if [[ -d $dir/${h#*:} ]]; then cp -al "$dir/${h#*:}" "$d/$(basename "$dir")/${h#*:}"; echo "   ${h#*:} 硬链接树已就位"
            else echo "   ⚠ 主目录没有 ${h#*:}，线内需自行安装"; fi
        done
    done
    local e var val step
    {
        echo "# 线 $name 的环境（pdw.sh line new 生成于 $(date '+%F %T')；工具按目录向上找到本文件即自动生效）"
        echo "export PDW_LINE=$name"
        echo "export PDW_SEQ=$seq"
        echo "export PDW_REPOS_IN=$(IFS=,; echo "${sel[*]}")"
        echo "export PDW_DIR=$d"
        for e in "${PDW_REPOS[@]}"; do
            r=${e%%:*}; dir=$(repo_get "$r" 2); var=$(repo_get "$r" 4)
            if [[ " ${sel[*]} " == *" $r "* ]]; then val=$d/$(basename "$dir"); else val=$dir; fi
            echo "export $var=\${$var:-$val}"
        done
        for e in "${PDW_PORTS[@]:-}"; do
            [[ -n $e ]] || continue
            IFS=: read -r var val step <<<"$e"
            echo "export $var=\${$var:-$((val + step * seq))}"
        done
        for e in "${PDW_EXTRA_ENV[@]:-}"; do
            [[ -n $e ]] || continue
            var=${e%%=*}
            val=$(PDW_DIR=$d PDW_LINE=$name PDW_SEQ=$seq eval "echo \"${e#*=}\"")
            echo "export $var=\${$var:-$val}"
        done
    } >"$d/.line.env"
    local branches=""
    for r in "${sel[@]}"; do branches+="$r：feat/$name ← $(repo_get "$r" 3)；"; done
    cat >"$CARDS/$name.md" <<EOF
# 线 $name — $goal

> 状态卡：这条线的接续点。会话起手 \`$PDW_BIN/pdw.sh line start $name\`；收尾覆盖式更新本卡。**功能线不改任务卡 task.md**（集成线合并时登记）。
> 开线 $(now)，仓库 ${sel[*]}，目录 \`$d\`，分支 $branches

## 目标与边界
- 目标：$goal
- 用户原话：
- 只改：（本线会碰的文件 / 模块；与在跑的线交叠的写明谁先合）
- 不改：（共享件：协议 / 公共头 / 启动脚本等，除非本线就是负责它的线）
- 验收判据：（落在「真的做到了」上，不落在「看起来都正常」上）
- 要用的设备：

## 现在做到哪
- （开线，尚未动手）

## 卡点 / 待用户定
- 无

## 下一步
1.

## 设备记录（拿了什么锁、改了什么持久状态、放锁前是否回到基线）
-

## 合并前清单（P 编号见 skill 原则表）
- [ ] 线内编译通过
- [ ] 真机 / 真板验过，测量条件与产品路径一致（工具参数取产品值）〔P3〕
- [ ] 证据写清验的什么、判据、结果、用的版本；每条判定（冒烟、计数、日志引文）有落盘原件〔P1〕，路径：
- [ ] 放锁前设备回到基线并逐项回读（自动回连、自动加入的网络、临时开关、用户可调配置）〔P4〕
- [ ] 本卡「现在做到哪」写成可交接的样子；锁全放〔P12〕
EOF
    if [[ -n ${PDW_POST_NEW:-} ]]; then echo "-- 开线后命令：$PDW_POST_NEW"; (cd "$d" && bash -c "$PDW_POST_NEW"); fi
    event "开线 $name（${sel[*]}）：$goal"
    echo "== 线 $name 就位：目录 $d，状态卡 $CARDS/$name.md"
    echo "   起手：新开一个 Claude Code 会话，说「启动线 $name」（会话里跑 $PDW_BIN/pdw.sh line start $name）"
}

line_start() {
    local name=${1:-}; [[ -n $name ]] || die "pdw.sh line start <线名>"
    local d=$WTROOT/$name; [[ -f $d/.line.env ]] || die "本轮没有线 $name（pdw.sh line list 看有哪些）"
    local r dir in
    echo "════════ 任务「$PDW_TASK」· 线 $name 起手简报  $(date '+%F %T') ════════"
    echo "工作目录（先 cd 到这里，工具即按本线环境跑）：  $d"
    in=" $(line_repos "$name") "
    for r in $(repo_names); do
        dir=$(repo_get "$r" 2)
        if [[ $in == *" $r "* ]]; then printf '%-10s %s\n' "$r" "$(branch_line "$d/$(basename "$dir")" "$(repo_get "$r" 3)")"
        else printf '%-10s %s\n' "$r" "本线不改；变量指主目录，只读"; fi
    done
    echo "线环境     $(grep '^export' "$d/.line.env" | grep -v 'PDW_LINE=\|PDW_DIR=' | sed 's/^export //; s/\${[A-Z_]*:-\(.*\)}$/\1/' | tr '\n' ' ')"
    local l; l=$(locks_of "$name"); echo "持锁       ${l:-（无）}"
    echo "设备与锁："; (cd "$d" && "$PDW_BIN/lock.sh" status | sed 's/^/   /')
    echo "用锁规则   动设备前 lock.sh take（被占就 --wait 排队，先来先得）；每次离开设备时预估下次要用还要多久："
    echo "           空档 ≥ 该设备阈值就回基线放锁，没一会就要用的 lock.sh hold <设备> --next <N>m \"<原因>\"；"
    echo "           别人的锁过期不等于不用，先发消息问，确认后才 take --force"
    echo "──────── 状态卡 $CARDS/$name.md ────────"
    cat "$CARDS/$name.md"
}

line_list() {
    local name r dir in parts any=no
    for name in $(lines_active); do
        any=yes; in=" $(line_repos "$name") "; parts=""
        for r in $(repo_names); do
            [[ $in == *" $r "* ]] || continue
            dir=$(repo_get "$r" 2)
            parts+="$r $(branch_line "$WTROOT/$name/$(basename "$dir")" "$(repo_get "$r" 3)")；"
        done
        printf '%-16s %s 持锁 %s\n' "$name" "$parts" "$(locks_of "$name")"
    done
    [[ $any == yes ]] || echo "（本轮没有在跑的功能线）"
}

line_rm() {
    local name=${1:-}; shift || true; local force=${1:-}
    local d=$WTROOT/$name; [[ -f $d/.line.env ]] || die "本轮没有线 $name"
    local r dir wt base
    for r in $(line_repos "$name"); do
        dir=$(repo_get "$r" 2); base=$(repo_get "$r" 3); wt=$d/$(basename "$dir")
        [[ -d $wt ]] || continue
        if [[ $force != --force ]]; then
            [[ $(dirty_count "$wt") == 0 ]] || die "$wt 有未提交改动，先提交或 --force（放弃改动）"
            [[ $(git -C "$wt" rev-list --count "$base..HEAD") == 0 ]] || die "$wt 的 feat/$name 有未合并进 $base 的提交，先合并或 --force（放弃）"
        fi
    done
    local l; l=$(locks_of "$name"); [[ -z $l ]] || die "线 $name 还持有锁：$l，先 lock.sh release"
    for r in $(line_repos "$name"); do
        dir=$(repo_get "$r" 2); wt=$d/$(basename "$dir")
        [[ -d $wt ]] && git -C "$dir" worktree remove --force "$wt"
    done
    rm -rf "$d"
    [[ -f $CARDS/$name.md ]] && mv "$CARDS/$name.md" "$CARDS/_done/$name.md"
    event "收线 $name${force:+（--force）}"
    echo "== 线 $name 已收（各仓库分支 feat/$name 保留，状态卡移到 cards/_done/）"
}

cmd_line() {
    local sub=${1:-}; shift || true
    case $sub in
        new) line_new "$@" ;; start) line_start "$@" ;; list|"") line_list ;;
        env) [[ -f $WTROOT/${1:-}/.line.env ]] || die "本轮没有线 ${1:-}"; cat "$WTROOT/$1/.line.env" ;;
        rm) line_rm "$@" ;;
        *) die "pdw.sh line new|start|list|env|rm" ;;
    esac
}

# ---------------- status / close ----------------
cmd_status() {
    local r dir
    echo "════════ 并行开发任务「$PDW_TASK」（开始 $PDW_SINCE，根 $PDW_ROOT）════════"
    echo "── 设备与锁"; "$PDW_BIN/lock.sh" status | sed 's/^/   /'
    echo "── 功能线"; line_list | sed 's/^/   /'
    echo "── 集成线（各仓库主目录）"
    for r in $(repo_names); do
        dir=$(repo_get "$r" 2)
        printf '   %-10s %s  %s\n' "$r" "$dir" "$(branch_line "$dir" "$(repo_get "$r" 3)")"
    done
    echo "── 收线进度：已收 $(ls "$CARDS/_done" | wc -l) 条，在跑 $(lines_active | wc -l) 条（全部收完后 pdw.sh close）"
}

cmd_close() {
    local force=${1:-} active held f o
    active=$(lines_active | tr '\n' ' ')
    [[ -z ${active// /} ]] || die "还有线没收：$active。逐条合并后 pdw.sh line rm <线名>（放弃的线 line rm <线名> --force）"
    held=""
    for f in "$LOCKDIR"/*; do
        [[ -f $f && $(basename "$f") != .* ]] || continue
        o=$(sed -n 's/^owner=//p' "$f")
        [[ $o == main ]] || held+="$(basename "$f")←$o "
    done
    [[ -z $held || $force == --force ]] || die "还有锁被别的身份持有：$held（确认无人在用再 --force）"
    local stamp; stamp=$(date +%Y%m%d-%H%M)
    local arch=${PDW_ARCHIVE_DIR:-$PDW_ROOT/.pdw-archive}/${stamp}_$PDW_TASK
    event "关闭集成线：本轮结束（已收 $(ls "$CARDS/_done" | wc -l) 条线）"
    mkdir -p "$arch"
    cp -a "$PDW_STATE/task.md" "$PDW_STATE/conf.sh" "$PDW_STATE/devices" "$arch/"
    cp -a "$CARDS/_done" "$arch/cards"
    rm -rf "$PDW_STATE"
    rmdir "$PDW_ROOT/wt" 2>/dev/null || true
    echo "== 任务「$PDW_TASK」已关闭：任务卡、线状态卡、设备登记归档到 $arch"
    echo "   锁与线目录已清理；各仓库的 feat/* 分支保留（需要时自行删）。下一轮并行开发重新调用 skill，pdw.sh init。"
}

sub=${1:-}; shift || true
case $sub in
    init) cmd_init "$@" ;;
    status) load_task; cmd_status ;;
    close) load_task; cmd_close "$@" ;;
    device) load_task; cmd_device "$@" ;;
    line) load_task; cmd_line "$@" ;;
    *) sed -n '2,24p' "$0"; exit 1 ;;
esac
