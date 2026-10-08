#!/bin/bash
# 功能线（worktree）管家。一条「线」＝ 一个功能 ＝ 一个 Claude Code 会话 ＝ <WT_ROOT>/wt/<线名>/ 下的一到多个 git worktree
#   （每个仓库分支 feat/<线名> 自该仓库的基线分支）+ 线自己的 .wt.env（目录 / 端口）+ 状态卡 <WT_CARDS>/<线名>.md。
# 各仓库主目录留给集成线（main）：只做合并、回归、刷板、更新总账。项目配置见同目录 wt.conf。
#
# 用法：
#   wt.sh new <线名> [--repos <短名,短名>] "<一句话目标>"   开线（缺省拉 WT_DEFAULT_REPOS）
#   wt.sh start <线名>          会话起手简报：目录、分支状态、端口、持锁、全部锁、用锁规则、状态卡全文
#   wt.sh list                  所有线一览（分支领先 / 落后基线、未提交文件数、持锁）+ 集成线状态
#   wt.sh env <线名>            打印该线的 .wt.env
#   wt.sh rm <线名> [--force]   收线：未提交 / 未合并进基线 / 还持锁的拒绝；状态卡移入 _done/
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WT_CONF=${WT_CONF:-$HERE/wt.conf}
[[ -f $WT_CONF ]] || { echo "wt: 找不到配置 $WT_CONF（照 wt.conf.example 写一份）" >&2; exit 1; }
WT_CONF_DIR=$(cd "$(dirname "$WT_CONF")" && pwd)
# shellcheck source=/dev/null
source "$WT_CONF"
WTROOT=$WT_ROOT/wt
LOCKDIR=${LOCK_DIR:-$WT_ROOT/.locks}
mkdir -p "$WTROOT" "$WT_CARDS"

die() { echo "wt: $*" >&2; exit 1; }
name_ok() { [[ $1 =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "线名只许小写字母数字连字符（如 app-dialog、ios-add）：$1"; }
wtdir() { echo "$WTROOT/$1"; }
card()  { echo "$WT_CARDS/$1.md"; }
envf()  { echo "$WTROOT/$1/.wt.env"; }

# 仓库表：WT_REPOS 每行 <短名>:<主目录>:<基线分支>:<变量名>
repo_get() {                 # 短名 字段号(2 主目录 / 3 基线 / 4 变量名)
    local e
    for e in "${WT_REPOS[@]}"; do [[ ${e%%:*} == "$1" ]] && { echo "$e" | cut -d: -f"$2"; return 0; }; done
    return 1
}
repo_names() { local e; for e in "${WT_REPOS[@]}"; do echo "${e%%:*}"; done; }
line_repos() { sed -n 's/^export WT_REPOS_IN=//p' "$(envf "$1")" | tr ',' ' '; }

dirty_count() { git -C "$1" status --porcelain | wc -l; }
branch_line() {              # repo base
    local repo=$1 base=$2 br ab
    br=$(git -C "$repo" branch --show-current)
    ab=$(git -C "$repo" rev-list --left-right --count "$base...HEAD" 2>/dev/null | awk '{print "落后"$1" 领先"$2}' || true)
    echo "$br（${ab:-无基线}，未提交 $(dirty_count "$repo") 个文件）"
}
locks_of() {                 # 线名 → 它持有的资源
    local f
    for f in "$LOCKDIR"/*; do
        [[ -f $f && $(basename "$f") != .* ]] || continue
        [[ $(sed -n 's/^owner=//p' "$f") == "$1" ]] && printf '%s ' "$(basename "$f")"
    done
    return 0
}

# ---------- new ----------
cmd_new() {
    local name=${1:-}; [[ -n $name ]] || die "wt.sh new <线名> [--repos a,b] \"<目标>\""; shift
    name_ok "$name"
    local repos=$WT_DEFAULT_REPOS goal=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repos) repos=$2; shift ;;
            *) goal=$1 ;;
        esac; shift
    done
    [[ -n $goal ]] || die "要给一句话目标（写进状态卡）"
    local d; d=$(wtdir "$name")
    [[ ! -e $d ]] || die "线 $name 已存在：$d"
    local r dir base sel=()
    IFS=, read -ra sel <<<"$repos"
    for r in "${sel[@]}"; do
        dir=$(repo_get "$r" 2) || die "wt.conf 里没有仓库短名 $r（有：$(repo_names | tr '\n' ' ')）"
        git -C "$dir" show-ref --quiet "refs/heads/feat/$name" && die "仓库 $r 已有分支 feat/$name"
    done

    local seq; seq=$(( $(cat "$WTROOT/.seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" >"$WTROOT/.seq"
    mkdir -p "$d"
    echo "== 开线 $name（#$seq，仓库 ${sel[*]}）"
    local h hp
    for r in "${sel[@]}"; do
        dir=$(repo_get "$r" 2); base=$(repo_get "$r" 3)
        echo "-- $r：worktree $d/$(basename "$dir") ← $base"
        git -C "$dir" worktree add -q -b "feat/$name" "$d/$(basename "$dir")" "$base"
        for h in "${WT_HARDLINK_DIRS[@]:-}"; do
            [[ ${h%%:*} == "$r" ]] || continue
            hp=${h#*:}
            if [[ -d $dir/$hp ]]; then
                cp -al "$dir/$hp" "$d/$(basename "$dir")/$hp"
                echo "   $hp 硬链接树已就位"
            else
                echo "   ⚠ 主目录没有 $hp，线内需自行安装"
            fi
        done
    done

    # .wt.env：全部 ${VAR:-…} 写法，显式设置的不覆盖
    local e var val
    {
        echo "# 线 $name 的环境（wt.sh new 生成于 $(date '+%F %T')；工具按目录向上找到本文件即自动生效）"
        echo "export WT_NAME=$name"
        echo "export WT_SEQ=$seq"
        echo "export WT_REPOS_IN=$(IFS=,; echo "${sel[*]}")"
        echo "export WT_DIR=$d"
        for e in "${WT_REPOS[@]}"; do
            r=${e%%:*}; dir=$(repo_get "$r" 2); var=$(repo_get "$r" 4)
            if [[ " ${sel[*]} " == *" $r "* ]]; then val=$d/$(basename "$dir"); else val=$dir; fi
            echo "export $var=\${$var:-$val}"
            [[ " ${sel[*]} " == *" $r "* ]] || echo "# ↑ 本线不改仓库 $r：$var 指主目录，只供只读对账"
        done
        for e in "${WT_PORTS[@]:-}"; do
            [[ -n $e ]] || continue
            IFS=: read -r var val step <<<"$e"
            echo "export $var=\${$var:-$((val + step * seq))}"
        done
        for e in "${WT_EXTRA_ENV[@]:-}"; do
            [[ -n $e ]] || continue
            var=${e%%=*}
            val=$(WT_DIR=$d WT_NAME=$name WT_SEQ=$seq eval "echo \"${e#*=}\"")
            echo "export $var=\${$var:-$val}"
        done
    } >"$(envf "$name")"

    local branches=""
    for r in "${sel[@]}"; do branches+="$r: feat/$name ← $(repo_get "$r" 3)；"; done
    if [[ -f $WT_CONF_DIR/wt-card.md ]]; then
        sed -e "s|{{NAME}}|$name|g" -e "s|{{GOAL}}|$goal|g" -e "s|{{DATE}}|$(date '+%F %H:%M')|g" \
            -e "s|{{REPOS}}|${sel[*]}|g" -e "s|{{BRANCHES}}|$branches|g" "$WT_CONF_DIR/wt-card.md" >"$(card "$name")"
    else
        cat >"$(card "$name")" <<EOF
# 线 $name — $goal

> 状态卡：这条线自己的接续点。会话起手跑 \`wt.sh start $name\` 读它；收尾覆盖式更新它。**不改总账**（集成线合并时统一登记）。
> 开线 $(date '+%F %H:%M')，仓库 **${sel[*]}**，目录 \`wt/$name/\`，分支 $branches

## 目标与边界
- 目标：$goal
- 只改：（列出本线会碰的文件 / 模块；与别的线交叠的文件在这里声明）
- 不改：共享件（协议文档、公共头、启动脚本等）除非本线就是「共享改动线」

## 现在做到哪
- （开线，尚未动手）

## 卡点 / 待用户定
- 无

## 下一步
1.

## 硬件记录（拿了什么锁、改了什么持久状态、放锁前是否回到基线）
-

## 合并前清单
- [ ] 本线改动在线内编译通过
- [ ] 真机 / 真板验过（拿锁 → 验 → 放锁前回基线）
- [ ] 证据卷完善（验的什么、判据、结果、用的版本），路径写在这里
- [ ] 状态卡「现在做到哪」写成可交接的样子
EOF
    fi
    if [[ -n ${WT_POST_NEW:-} ]]; then echo "-- 开线后命令：$WT_POST_NEW"; (cd "$d" && bash -c "$WT_POST_NEW"); fi
    echo "== 线 $name 就位"
    echo "   目录     $d"
    echo "   状态卡   $(card "$name")"
    echo "   起手     新开一个 Claude Code 会话，说「启动线 $name」（会话里跑 wt.sh start $name）"
}

# ---------- start ----------
cmd_start() {
    local name=${1:-}; [[ -n $name ]] || die "wt.sh start <线名>"
    local d; d=$(wtdir "$name"); [[ -d $d ]] || die "没有线 $name（wt.sh list 看有哪些）"
    local r dir in
    echo "════════ 线 $name 起手简报  $(date '+%F %T') ════════"
    echo "工作目录（会话里先 cd 到这里，工具即自动按本线环境跑）：  $d"
    in=" $(line_repos "$name") "
    for r in $(repo_names); do
        dir=$(repo_get "$r" 2)
        if [[ $in == *" $r "* ]]; then printf '%-10s %s\n' "$r" "$(branch_line "$d/$(basename "$dir")" "$(repo_get "$r" 3)")"
        else printf '%-10s %s\n' "$r" "本线不改；变量指主目录，只读"; fi
    done
    echo "线环境     $(grep '^export' "$(envf "$name")" | grep -v 'WT_NAME\|WT_DIR' | sed 's/^export //; s/\${[A-Z_]*:-\(.*\)}$/\1/' | tr '\n' ' ')"
    local l; l=$(locks_of "$name"); echo "持锁       ${l:-（无）}"
    echo "全部锁："; (cd "$d" && "$HERE/lock.sh" status | sed 's/^/   /')
    echo "用锁规则   动硬件前 lock.sh take（被占就 --wait 排队，先来先得）；每次离开硬件时预估下次要用还要多久："
    echo "           空档 ≥ 该资源阈值就回基线放锁，没一会就要用的 lock.sh hold <res> --next <N>m \"<原因>\"；"
    echo "           别人的锁过期不等于不用，先发消息问，确认后才 take --force"
    echo "──────── 状态卡 $(card "$name") ────────"
    cat "$(card "$name")"
}

# ---------- list ----------
cmd_list() {
    local d name r dir in parts
    for d in "$WTROOT"/*/; do
        [[ -f $d/.wt.env ]] || continue
        name=$(basename "$d"); in=" $(line_repos "$name") "; parts=""
        for r in $(repo_names); do
            [[ $in == *" $r "* ]] || continue
            dir=$(repo_get "$r" 2)
            parts+="$r $(branch_line "$d$(basename "$dir")" "$(repo_get "$r" 3)")；"
        done
        printf '%-16s %s 持锁 %s\n' "$name" "$parts" "$(locks_of "$name")"
    done
    parts=""
    for r in $(repo_names); do
        dir=$(repo_get "$r" 2)
        parts+="$r $(branch_line "$dir" "origin/$(repo_get "$r" 3)")；"
    done
    echo "集成线 main：$parts持锁 $(locks_of main)"
}

# ---------- env ----------
cmd_env() { local name=${1:-}; [[ -f $(envf "$name") ]] || die "没有线 $name"; cat "$(envf "$name")"; }

# ---------- rm ----------
cmd_rm() {
    local name=${1:-}; shift || true; local force=${1:-}
    local d; d=$(wtdir "$name"); [[ -d $d ]] || die "没有线 $name"
    local r dir wt base
    for r in $(line_repos "$name"); do
        dir=$(repo_get "$r" 2); base=$(repo_get "$r" 3); wt=$d/$(basename "$dir")
        [[ -d $wt ]] || continue
        if [[ $force != --force ]]; then
            [[ $(dirty_count "$wt") == 0 ]] || die "$wt 有未提交改动，先提交或 --force"
            [[ $(git -C "$wt" rev-list --count "$base..HEAD") == 0 ]] || die "$wt 的 feat/$name 有未合并进 $base 的提交，先合并或 --force"
        fi
    done
    local l; l=$(locks_of "$name"); [[ -z $l ]] || die "线 $name 还持有锁：$l，先 lock.sh release"
    for r in $(line_repos "$name"); do
        dir=$(repo_get "$r" 2); wt=$d/$(basename "$dir")
        [[ -d $wt ]] && git -C "$dir" worktree remove --force "$wt"
    done
    rm -rf "$d"
    mkdir -p "$WT_CARDS/_done"; [[ -f $(card "$name") ]] && mv "$(card "$name")" "$WT_CARDS/_done/${name}_$(date +%Y%m%d).md"
    echo "线 $name 已收（各仓库分支 feat/$name 保留，状态卡移到 _done/）"
}

sub=${1:-}; shift || true
case $sub in
    new|start|list|env|rm) "cmd_$sub" "$@" ;;
    *) sed -n '2,12p' "$0"; exit 1 ;;
esac
