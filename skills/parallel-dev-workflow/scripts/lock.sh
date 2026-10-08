#!/bin/bash
# 设备锁（租约制）。设备在本轮任务里登记：pdw.sh device add / rm（登记在 .pdw/devices/）。
#
# 为什么是租约而不是进程级 flock：一条线拿到板子后会连着做「投板 → 冒烟 → 看日志」好几条命令，
# 中间没有常驻进程能攥住 fd；所以锁是一个文件，记持有线、用途、到期时刻，由会话和（接入了 need_lock 的）工具共同遵守。
#
# 用法：
#   lock.sh take <设备> "<用途>" [--ttl 30m] [--wait] [--force]
#                                        拿锁。被占就失败；--wait 进先来先得队列，轮到自己才拿；
#                                        持有者已过期也不自动抢——过期不等于不用，先问持有线，确认后 --force
#   lock.sh hold <设备> --next <N>m "<原因>" [--long]
#                                        暂时离开设备但很快还要用：登记预估空档，租约续到 N + 余量，
#                                        status 显示「闲置·预计 N 分钟后再用」。N ≥ 该设备的阈值即拒绝——该回基线放锁
#   lock.sh release <设备>|--all [--force]  放锁（只放自己这条线持有的）；有人排队时提示队首
#   lock.sh check <设备>                 当前线是否持有且未过期：0 是 / 1 否（脚本内部用）
#   lock.sh touch <设备>                 记「最近使用」并续租、清闲置标记（need_lock 每次放行时调）
#   lock.sh status                       全部设备：谁持有、使用中还是闲置、还剩多久、排队、过期标红
#   lock.sh run <设备>[,<设备>…] "<用途>" -- <命令…>   排队拿到即跑、跑完即放（单条命令的快路径）
#   lock.sh renew <设备> [--ttl 30m]     续期
#   lock.sh whoami                       当前线名
#
# 离开设备时的规则：不是一不用就让，而是每次离开时预估下次要用还要多久——
#   预估空档 ≥ 阈值（登记设备时按归还成本定）就回基线放锁；没一会就要用的 hold 着并登记预估，等锁的线据此决定等还是先干别的。
#
# 「当前线」＝ PDW_LINE（.line.env 导出；按目录向上找），找不到就是 main（集成线）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/pdw_env.sh"
pdw_need_task
ME=$PDW_LINE
LOCKDIR=$PDW_STATE/locks
mkdir -p "$LOCKDIR"

die() { echo "lock: $*" >&2; exit 1; }

# 解析时长：30m / 2h / 90s / 纯数字（秒）
ttl_secs() {
    local t=$1
    case $t in
        *h) echo $(( ${t%h} * 3600 )) ;;
        *m) echo $(( ${t%m} * 60 )) ;;
        *s) echo "${t%s}" ;;
        *)  echo "$t" ;;
    esac
}

# 设备表：.pdw/devices/<名>，idle_max= 为闲置留锁上限（分钟）
RESOURCES=($(dev_list)); declare -A IDLE_MAX=()
for _r in "${RESOURCES[@]}"; do IDLE_MAX[$_r]=$(dev_field "$_r" idle_max); done
DEFAULT_TTL=$(ttl_secs "${LOCK_DEFAULT_TTL:-30m}")
IDLE_MARGIN=${LOCK_IDLE_MARGIN:-10}

valid_res() { local r; for r in "${RESOURCES[@]}"; do [[ $r == "$1" ]] && return 0; done; return 1; }

# 读锁文件字段
rd() { sed -n "s/^$2=//p" "$LOCKDIR/$1" 2>/dev/null; }
held_by() { rd "$1" owner; }
expired() {                       # 0=已过期
    local until; until=$(rd "$1" until); [[ -n $until ]] && (( $(date +%s) > until ))
}

# 改写锁文件的若干字段（其余原样保留）；先写临时文件再 mv 原子替换，读的人看不到半截文件
set_fields() {                    # res key=value…（值为空即删掉该字段）
    local res=$1; shift
    local tmp; tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX")
    local kv k line keep=()
    for kv in "$@"; do keep+=("${kv%%=*}"); done
    if [[ -f $LOCKDIR/$res ]]; then
        while IFS= read -r line; do
            k=${line%%=*}
            [[ " ${keep[*]} " == *" $k "* ]] || echo "$line"
        done <"$LOCKDIR/$res" >"$tmp"
    fi
    for kv in "$@"; do [[ -n ${kv#*=} ]] && echo "$kv" >>"$tmp"; done
    mv -f "$tmp" "$LOCKDIR/$res"
}

write_lock() {                    # res purpose ttl：新拿锁，整份重写
    local res=$1 purpose=$2 ttl=$3 now; now=$(date +%s)
    local tmp; tmp=$(mktemp "$LOCKDIR/.tmp.XXXXXX")
    printf '%s\n' "owner=$ME" "purpose=$purpose" "since=$now" "until=$((now + ttl))" "used=$now" \
        "pid=$PPID" "host=$(hostname)" >"$tmp"
    mv -f "$tmp" "$LOCKDIR/$res"
}

# 原子占坑：mkdir 当自旋锁保护「读-判-写」。5 s 拿不到：互斥目录超过 30 s 没动＝上一个持有者死在半路，清掉重来；否则报错
with_mutex() {
    local i m=$LOCKDIR/.mutex
    for ((i = 0; ; i++)); do
        mkdir "$m" 2>/dev/null && break
        if (( i >= 50 )); then
            if (( $(date +%s) - $(stat -c %Y "$m" 2>/dev/null || date +%s) > 30 )); then rmdir "$m" 2>/dev/null; i=0; continue; fi
            die "互斥目录 $m 被占 5 s 未放（有别的 lock.sh 正在写？）"
        fi
        sleep 0.1
    done
    "$@"; local rc=$?
    rmdir "$m" 2>/dev/null
    return $rc
}

# ---- 先来先得队列 ----
qdir() { echo "$LOCKDIR/$1.q"; }
prune_queue() {                   # 排队进程已不在（Ctrl-C、会话关了）的队位清掉
    local f pid
    for f in "$(qdir "$1")"/*; do
        [[ -f $f ]] || continue
        pid=${f##*_}
        kill -0 "$pid" 2>/dev/null || rm -f "$f"
    done
}
queue_list() { ls -1 "$(qdir "$1")" 2>/dev/null | sort; }
qfield() { sed -n "s/^$3=//p" "$(qdir "$1")/$2" 2>/dev/null; }

try_take() {                      # res purpose ttl force myq → 0 拿到 / 1 被占 / 2 已过期待 --force / 3 有人排在前面
    local res=$1 purpose=$2 ttl=$3 force=$4 myq=$5 owner head
    owner=$(held_by "$res")
    if [[ -n $owner && $owner != "$ME" ]]; then
        expired "$res" || return 1
        [[ $force == yes ]] || return 2
    fi
    if [[ $owner != "$ME" ]]; then
        prune_queue "$res"
        head=$(queue_list "$res" | head -1)
        [[ -z $head || $head == "$myq" ]] || return 3
    fi
    write_lock "$res" "$purpose" "$ttl"
    [[ -n $myq ]] && rm -f "$(qdir "$res")/$myq"
    return 0
}

cmd_take() {
    local res=${1:-}; shift || true
    valid_res "$res" || die "未登记的设备 $res（已登记：${RESOURCES[*]:-无}；登记用 pdw.sh device add）"
    local purpose=${1:-}; [[ -n $purpose && $purpose != --* ]] || die "要写用途：lock.sh take $res \"<用途>\""
    shift
    local ttl=$DEFAULT_TTL wait=no force=no
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ttl) ttl=$(ttl_secs "$2"); shift 2 ;;
            --wait) wait=yes; shift ;;
            --force) force=yes; shift ;;
            *) die "未知参数 $1" ;;
        esac
    done
    local myq=""
    if [[ $wait == yes ]]; then
        mkdir -p "$(qdir "$res")"
        myq="$(date +%s%N)_$$"
        printf 'line=%s\npurpose=%s\n' "$ME" "$purpose" >"$(qdir "$res")/$myq"
        trap "rm -f '$(qdir "$res")/$myq'" EXIT     # 设陷阱时就展开：退出时局部变量已不在
        trap 'exit 130' INT TERM
    fi
    local n=0 rc o p u left pos msg
    while true; do
        with_mutex try_take "$res" "$purpose" "$ttl" "$force" "$myq"; rc=$?
        if (( rc == 0 )); then
            echo "🔒 $res ← $ME（$purpose，$((ttl / 60)) 分钟）"
            local bl; bl=$(dev_field "$res" baseline); [[ -n $bl ]] && echo "   放锁前回到基线：$bl"
            return 0
        fi
        o=$(held_by "$res"); p=$(rd "$res" purpose); u=$(rd "$res" until)
        left=$(( (${u:-0} - $(date +%s)) / 60 ))
        case $rc in
            1) msg="$res 被 $o 持有：$p（剩 ${left} 分钟$( [[ $(rd "$res" idle) == 1 ]] && echo "，闲置中：$(rd "$res" why)")）" ;;
            2) msg="$res 的持有者 $o 已过期 $(( ($(date +%s) - ${u:-0} + 59) / 60 )) 分钟（$p）。过期不等于不用：先问持有线，确认不用了再 lock.sh take $res \"…\" --force" ;;
            3) pos=$(queue_list "$res" | grep -n "^$myq\$" | cut -d: -f1)
               msg="$res 有 $(queue_list "$res" | wc -l) 个在排队，队首 $(qfield "$res" "$(queue_list "$res" | head -1)" line)$( [[ -n $pos ]] && echo "，你排第 $pos")" ;;
        esac
        if [[ $wait == no ]]; then
            echo "❌ $msg。排队等：lock.sh take $res \"…\" --wait" >&2
            return 1
        fi
        (( n % 6 == 0 )) && echo "⏳ $msg；10 s 后再看…" >&2
        n=$((n + 1)); sleep 10
    done
}

cmd_hold() {
    local res=${1:-}; shift || true; valid_res "$res" || die "未知资源 $res"
    [[ $(held_by "$res") == "$ME" ]] || die "$res 不是你（$ME）持有的"
    local next="" why="" long=no
    while [[ $# -gt 0 ]]; do
        case $1 in
            --next) next=$(( $(ttl_secs "$2") / 60 )); shift 2 ;;
            --long) long=yes; shift ;;
            *) why=$1; shift ;;
        esac
    done
    [[ -n $next && -n $why ]] || die "lock.sh hold $res --next <N>m \"<原因：回来要做什么>\""
    local max=${IDLE_MAX[$res]:-10}
    if (( next >= max )) && [[ $long != yes ]]; then
        die "预计空档 ${next} 分钟 ≥ $res 的阈值 ${max} 分钟：按约定回基线后 lock.sh release $res。确要留着（回基线代价远大于别人等的代价）加 --long，原因里写清"
    fi
    local now; now=$(date +%s)
    with_mutex set_fields "$res" "idle=1" "next=$((now + next * 60))" "why=$why" "until=$((now + (next + IDLE_MARGIN) * 60))"
    echo "⏸ $res 闲置留锁：预计 ${next} 分钟后再用（$why），租约到 $(date -d @$((now + (next + IDLE_MARGIN) * 60)) '+%H:%M')"
    prune_queue "$res"
    local q; q=$(queue_list "$res" | wc -l)
    (( q > 0 )) && echo "⚠ 有 $q 个在排队等 $res（队首 $(qfield "$res" "$(queue_list "$res" | head -1)" line)），留锁前想想他们" >&2
    return 0
}

cmd_touch() {                     # 静默：不是自己的就什么也不做
    local res=${1:-}; valid_res "$res" || return 0
    [[ $(held_by "$res") == "$ME" ]] || return 0
    local now u; now=$(date +%s); u=$(rd "$res" until)
    (( ${u:-0} < now + DEFAULT_TTL )) && u=$((now + DEFAULT_TTL))
    with_mutex set_fields "$res" "used=$now" "idle=" "next=" "why=" "until=$u"
    return 0
}

cmd_release() {
    local res=${1:-}; shift || true
    local force=no; [[ ${1:-} == --force ]] && force=yes
    [[ -n $res ]] || die "lock.sh release <res>|--all [--force]"
    local list=("$res"); [[ $res == --all ]] && list=("${RESOURCES[@]}")
    local r o head
    for r in "${list[@]}"; do
        o=$(held_by "$r"); [[ -n $o ]] || continue
        if [[ $o != "$ME" && $force != yes ]]; then
            [[ $res == --all ]] || echo "⚠ $r 是 $o 持有的，不是你（$ME）；确认对方已不用再加 --force" >&2
            continue
        fi
        rm -f "$LOCKDIR/$r"; echo "🔓 $r 已放（原持有 $o）"
        prune_queue "$r"; head=$(queue_list "$r" | head -1)
        [[ -n $head ]] && echo "   队首 $(qfield "$r" "$head" line)（$(qfield "$r" "$head" purpose)）10 s 内会拿到"
    done
    return 0
}

cmd_check() {
    local res=${1:-}; valid_res "$res" || die "未知资源 $res"
    [[ $(held_by "$res") == "$ME" ]] && ! expired "$res"
}

cmd_renew() {
    local res=${1:-}; shift || true; valid_res "$res" || die "未知资源 $res"
    [[ $(held_by "$res") == "$ME" ]] || die "$res 不是你（$ME）持有的"
    local ttl=$DEFAULT_TTL; [[ ${1:-} == --ttl ]] && ttl=$(ttl_secs "$2")
    with_mutex set_fields "$res" "until=$(( $(date +%s) + ttl ))"
    echo "🔒 $res 续到 $((ttl / 60)) 分钟后"
}

cmd_status() {
    local r o p u s used left state mark now f n; now=$(date +%s)
    (( ${#RESOURCES[@]} )) || { echo "（本轮还没有登记设备：pdw.sh device add <名> --idle <分钟> …）"; return 0; }
    printf '%-14s %-12s %-8s %s\n' 设备 持有者 剩余 状态·用途
    for r in "${RESOURCES[@]}"; do
        o=$(held_by "$r")
        if [[ -z $o ]]; then
            printf '%-14s %-12s\n' "$r" "（空闲）"
        else
            p=$(rd "$r" purpose); u=$(rd "$r" until); s=$(rd "$r" since); used=$(rd "$r" used)
            left=$(( (u - now) / 60 )); mark=""
            if [[ $(rd "$r" idle) == 1 ]]; then
                state="⏸闲置·预计 $(( ($(rd "$r" next) - now) / 60 )) 分钟后再用：$(rd "$r" why)｜"
            else
                state="使用中$( [[ -n $used ]] && echo "·最近 $(( (now - used) / 60 )) 分钟前")｜"
            fi
            (( u < now )) && mark=" ⛔已过期 $(( (now - u + 59) / 60 )) 分钟（先问持有线，确认不用再 take --force）"
            [[ $o == "$ME" ]] && o="$o*"
            printf '%-14s %-12s %-8s %s%s（自 %s）%s\n' "$r" "$o" "${left}m" "$state" "$p" "$(date -d @"$s" '+%H:%M')" "$mark"
        fi
        prune_queue "$r"
        n=0
        for f in $(queue_list "$r"); do
            n=$((n + 1))
            printf '%-14s   排队 %d：%s（%s，已等 %d 分钟）\n' "" "$n" "$(qfield "$r" "$f" line)" "$(qfield "$r" "$f" purpose)" $(( (now - ${f%%_*} / 1000000000) / 60 ))
        done
    done
    echo "（* = 当前线 $ME；离开设备时：预计空档 ≥ 阈值就回基线放锁，否则 lock.sh hold <设备> --next <N>m \"<原因>\"）"
}

cmd_run() {
    local reslist=${1:-}; shift || true
    local purpose=${1:-}; shift || true
    [[ ${1:-} == -- ]] || die "lock.sh run <res,res> \"<用途>\" -- <命令…>"; shift
    local taken=() r
    IFS=, read -ra rs <<<"$reslist"
    for r in "${rs[@]}"; do ( cmd_take "$r" "$purpose" --wait ) || exit 1; taken+=("$r"); done
    "$@"; local rc=$?
    for r in "${taken[@]}"; do cmd_release "$r" >/dev/null; done
    return $rc
}

sub=${1:-}; shift || true
case $sub in
    take|hold|touch|release|check|renew|status|run) "cmd_$sub" "$@" ;;
    whoami) echo "$ME" ;;
    *) sed -n '2,24p' "$0"; exit 1 ;;
esac
