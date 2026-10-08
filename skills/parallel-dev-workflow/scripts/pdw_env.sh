# 并行开发任务公共头：被 pdw.sh / lock.sh 以及（可选）项目里动设备的工具 source。
#
# 一轮并行开发任务的全部状态在 <根>/.pdw/ 下：
#   conf.sh          仓库、端口、线环境（pdw.sh init 生成，可手改）
#   task.md          集成线的任务卡（目标、功能、设备、线、合并记录、事件）
#   devices/<名>     设备登记：idle_max= desc= ip= baseline=
#   locks/<名>       设备锁（租约）；locks/<名>.q/ 排队
#   cards/<线>.md    功能线状态卡；收线后移入 cards/_done/
#   bin/             本轮用的脚本副本（pdw.sh lock.sh pdw_env.sh）
# 功能线目录 <根>/wt/<线名>/：.line.env + 各仓库的 git worktree（分支 feat/<线名>）。
#
# 本文件做三件事：
#  1. 找到进行中的任务：脚本在 .pdw/bin/ 里就取上一级；否则从 $PWD 向上找 .pdw/conf.sh（PDW_ROOT 可显式指定根）。
#  2. 识别「当前线」：从 $PWD 向上找 .line.env，找到就 source（仓库目录变量、端口都指向这条线）；找不到＝集成线 main。
#     已显式设置的变量不覆盖（.line.env 全是 ${VAR:-…} 写法）。
#  3. 提供 need_lock <设备> 与 board_res_of_ip <IP>：项目工具在改设备前调用，没持锁就拒绝；持锁就记一次使用并续租。
#     LOCK_BYPASS=1 可越过（应急，会打提醒）。
#
# 项目工具可选接入（没接入时锁靠会话自觉遵守）：
#   [ -f "<根>/.pdw/bin/pdw_env.sh" ] && source "<根>/.pdw/bin/pdw_env.sh" && need_lock <设备名>

_pdw_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PDW_STATE=""
if [[ -n ${PDW_ROOT:-} && -f $PDW_ROOT/.pdw/conf.sh ]]; then
    PDW_STATE=$PDW_ROOT/.pdw
elif [[ -f $_pdw_here/../conf.sh ]]; then
    PDW_STATE=$(cd "$_pdw_here/.." && pwd)
else
    _d=$PWD
    while [[ $_d != / ]]; do
        [[ -f $_d/.pdw/conf.sh ]] && { PDW_STATE=$_d/.pdw; break; }
        _d=$(dirname "$_d")
    done
fi
if [[ -n $PDW_STATE ]]; then
    PDW_ROOT=$(cd "$PDW_STATE/.." && pwd)
    # shellcheck source=/dev/null
    source "$PDW_STATE/conf.sh"
fi
PDW_BIN=$PDW_STATE/bin

pdw_need_task() {
    [[ -n $PDW_STATE ]] && return 0
    echo "pdw: 当前目录往上没有进行中的并行开发任务（找不到 .pdw/conf.sh）。新开一轮：pdw.sh init" >&2
    exit 1
}

if [[ -z ${PDW_LINE:-} ]]; then
    _d=$PWD
    while [[ $_d != / ]]; do
        [[ -f $_d/.line.env ]] && { source "$_d/.line.env"; break; }
        _d=$(dirname "$_d")
    done
fi
export PDW_LINE=${PDW_LINE:-main}

# 设备登记的字段
dev_field() { sed -n "s/^$2=//p" "$PDW_STATE/devices/$1" 2>/dev/null; }
dev_list() { ls -1 "$PDW_STATE/devices" 2>/dev/null; }

# 板子 IP → 设备名（按设备登记的 ip=）；查不到给 board-<IP>，need_lock 会因设备不存在而拒绝
board_res_of_ip() {
    local d
    for d in $(dev_list); do [[ $(dev_field "$d" ip) == "$1" ]] && { echo "$d"; return 0; }; done
    echo "board-$1"
}

need_lock() {
    local res=$1
    if [[ ${LOCK_BYPASS:-} == 1 ]]; then echo "⚠ LOCK_BYPASS=1：跳过 $res 锁检查（当前线 $PDW_LINE）" >&2; return 0; fi
    [[ -n $PDW_STATE ]] || return 0             # 没有进行中的任务：不拦
    # 放行时顺手记「最近使用」并续租、清闲置标记：用着的锁不会因为租约到点被标过期
    if "$PDW_BIN/lock.sh" check "$res"; then "$PDW_BIN/lock.sh" touch "$res" >/dev/null 2>&1; return 0; fi
    echo "⛔ 当前线 $PDW_LINE 没有持有 $res 的锁。先拿锁：" >&2
    echo "     $PDW_BIN/lock.sh take $res \"<用途>\" [--wait]      看谁在用：$PDW_BIN/lock.sh status" >&2
    exit 3
}
