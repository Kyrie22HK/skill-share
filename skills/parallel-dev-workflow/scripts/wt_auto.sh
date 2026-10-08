# 并行开发工作流公共头：被 wt.sh / lock.sh 以及项目里所有动硬件的工具 source。
#
# 做三件事：
#  1. 加载项目配置 wt.conf（缺省与本文件同目录；环境变量 WT_CONF 可另指）。
#  2. 自动识别「当前线」：从 $PWD 向上找 .wt.env（wt.sh new 生成，放在 <WT_ROOT>/wt/<线名>/），找到就 source，
#     于是各仓库目录变量、端口、构建输出目录都指向这条线自己的；找不到＝集成线（main），变量保持项目工具的原默认值。
#     已显式设置的变量不覆盖（.wt.env 里全是 ${VAR:-…} 写法）。
#  3. 提供 need_lock <资源>：动硬件前检查当前线是否持有该资源的锁，没有就拒绝并给出拿锁命令；持有就记一次使用并续租。
#     LOCK_BYPASS=1 可越过（单人单线的应急场合，会打一行提醒）。
#
# 用法（项目工具脚本开头、变量默认值之前）：
#   TOOLS="$(cd "$(dirname "$0")" && pwd)"; source "$TOOLS/wt_auto.sh"
#   ...要改板子 / 装机的分支里：need_lock "$(board_res_of_ip "$BOARD_IP")"   或   need_lock phone-android

WT_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT_CONF=${WT_CONF:-$WT_TOOLS/wt.conf}
[[ -f $WT_CONF ]] || { echo "wt_auto: 找不到配置 $WT_CONF（照 wt.conf.example 写一份）" >&2; return 1 2>/dev/null || exit 1; }
WT_CONF_DIR=$(cd "$(dirname "$WT_CONF")" && pwd)
# shellcheck source=/dev/null
source "$WT_CONF"
WT_LOCKDIR=${LOCK_DIR:-$WT_ROOT/.locks}

_wt_find_env() {
    local d=${PWD}
    while [[ $d != / ]]; do
        [[ -f $d/.wt.env ]] && { echo "$d/.wt.env"; return 0; }
        d=$(dirname "$d")
    done
    return 1
}

if [[ -z ${WT_NAME:-} ]]; then
    _wt_env_file=$(_wt_find_env) && source "$_wt_env_file"
fi
export WT_NAME=${WT_NAME:-main}

# 板子 IP → 资源名（按 wt.conf 的 LOCK_IP_MAP；查不到给 board-<IP>，need_lock 会因资源不存在而拒绝）
board_res_of_ip() {
    local m
    for m in "${LOCK_IP_MAP[@]:-}"; do [[ ${m%%=*} == "$1" ]] && { echo "${m#*=}"; return 0; }; done
    echo "board-$1"
}

need_lock() {
    local res=$1
    if [[ ${LOCK_BYPASS:-} == 1 ]]; then echo "⚠ LOCK_BYPASS=1：跳过 $res 锁检查（当前线 $WT_NAME）" >&2; return 0; fi
    # 放行时顺手记「最近使用」并续租、清闲置标记：用着的锁不会因为租约到点被标过期
    if "$WT_TOOLS/lock.sh" check "$res"; then "$WT_TOOLS/lock.sh" touch "$res" >/dev/null 2>&1; return 0; fi
    echo "⛔ 当前线 $WT_NAME 没有持有 $res 的锁。先拿锁：" >&2
    echo "     $WT_TOOLS/lock.sh take $res \"<用途>\" [--ttl 30m] [--wait]      看谁在用：lock.sh status" >&2
    exit 3
}
