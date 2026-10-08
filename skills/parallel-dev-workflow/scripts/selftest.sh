#!/bin/bash
# 自检：在临时目录里造两个 git 仓库和一份 wt.conf，跑通「开线 → 按目录识别当前线 → 用锁语义 → 收线」。
# 不碰任何真实项目；约 40 秒（排队用例要等轮询）。用法：bash selftest.sh   退出码 0 = 全过
set -u
SRC=$(cd "$(dirname "$0")" && pwd)
SB=$(mktemp -d /tmp/pdw-selftest.XXXXXX)
BG=()
cleanup() { local p; for p in "${BG[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done; rm -rf "$SB"; }
trap cleanup EXIT
unset WT_NAME WT_CONF LOCK_DIR LOCK_BYPASS APP_DIR FW_DIR SINK_PORT RUNDIR 2>/dev/null

pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
ng() { echo "  ❌ $1"; fail=$((fail + 1)); }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ng "$d"; fi; }

R=$SB/root; T=$R/_ai_workspace/demo/tools
mkdir -p "$T"
cp "$SRC/wt.sh" "$SRC/lock.sh" "$SRC/wt_auto.sh" "$T/"; chmod +x "$T"/*.sh
for n in AppRepo FwRepo; do
    git init -q "$R/$n"; git -C "$R/$n" symbolic-ref HEAD refs/heads/main
    git -C "$R/$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
mkdir -p "$R/AppRepo/node_modules/x"; echo 1 >"$R/AppRepo/node_modules/x/f"
echo node_modules/ >"$R/AppRepo/.git/info/exclude"
cat >"$T/wt.conf" <<'EOF'
WT_ROOT=$(cd "$WT_CONF_DIR/../../.." && pwd)
WT_CARDS=$(cd "$WT_CONF_DIR/.." && pwd)/wt
WT_REPOS=( "app:$WT_ROOT/AppRepo:main:APP_DIR" "fw:$WT_ROOT/FwRepo:main:FW_DIR" )
WT_DEFAULT_REPOS=app
WT_HARDLINK_DIRS=( "app:node_modules" )
WT_PORTS=( "SINK_PORT:8765:10" )
WT_EXTRA_ENV=( 'RUNDIR=/tmp/demo-$WT_NAME' )
WT_POST_NEW=''
LOCK_RESOURCES=( "board-a:10:主板" "phone-a:20:手机" )
LOCK_IP_MAP=( "10.0.0.2=board-a" )
LOCK_DEFAULT_TTL=30m
LOCK_IDLE_MARGIN=10
EOF
W=$T/wt.sh; L=$T/lock.sh
in_line() { local d=$1; shift; (cd "$d" && "$@"); }
field() { sed -n "s/^$2=//p" "$R/.locks/$1"; }

echo "== 开线与线环境"
chk "wt.sh new l1（缺省仓库 app）" "$W" new l1 "演示线一"
chk "l1 的 app worktree 在 feat/l1 上" test "$(git -C "$R/wt/l1/AppRepo" branch --show-current)" = feat/l1
chk "node_modules 是硬链接树（与主目录同 inode）" test "$(stat -c %i "$R/wt/l1/AppRepo/node_modules/x/f")" = "$(stat -c %i "$R/AppRepo/node_modules/x/f")"
E=$R/wt/l1/.wt.env
chk ".wt.env：APP_DIR 指 worktree" grep -q "APP_DIR=\${APP_DIR:-$R/wt/l1/AppRepo}" "$E"
chk ".wt.env：本线没拉的 FW_DIR 指主目录" grep -q "FW_DIR=\${FW_DIR:-$R/FwRepo}" "$E"
chk ".wt.env：端口按线号错开（8765+10×1）" grep -q 'SINK_PORT=${SINK_PORT:-8775}' "$E"
chk ".wt.env：其他变量已展开" grep -q 'RUNDIR=${RUNDIR:-/tmp/demo-l1}' "$E"
chk "状态卡已生成" test -f "$R/_ai_workspace/demo/wt/l1.md"
chk "wt.sh new l2 --repos app,fw（两个仓库）" "$W" new l2 --repos app,fw "演示线二"
chk "l2 的 fw worktree 在 feat/l2 上" test "$(git -C "$R/wt/l2/FwRepo" branch --show-current)" = feat/l2
chk "同名线重复开被拒" bash -c "! '$W' new l1 x"
chk "按目录识别当前线：l1 目录里是 l1" test "$(in_line "$R/wt/l1/AppRepo" "$L" whoami)" = l1
chk "按目录识别当前线：外层是 main" test "$(in_line "$R" "$L" whoami)" = main
chk "板子 IP 映射到资源名" test "$(cd "$R" && bash -c "source '$T/wt_auto.sh'; board_res_of_ip 10.0.0.2")" = board-a

echo "== 先来先得排队（约 25 秒）"
in_line "$R/wt/l1" "$L" take board-a "l1 用" >/dev/null
chk "被占时不带 --wait 拿锁失败" bash -c "! (cd '$R/wt/l2' && '$L' take board-a 'l2 不等')"
(cd "$R/wt/l2" && exec "$L" take board-a "l2 排队" --wait >/dev/null 2>&1) & BG+=($!); sleep 1.2
(cd "$R" && exec "$L" take board-a "main 排队" --wait >/dev/null 2>&1) & BG+=($!); sleep 1.2
chk "status 列出两个队位" test "$(in_line "$R" "$L" status | grep -c '排队 [12]：')" = 2
chk "放锁瞬间不带 --wait 的第三方不插队" bash -c "cd '$R/wt/l1' && '$L' release board-a >/dev/null && ! '$L' take board-a 'l1 想插队'"
sleep 11
chk "持有者放锁后队首 l2 拿到" test "$(field board-a owner)" = l2
in_line "$R/wt/l2" "$L" release board-a >/dev/null; sleep 11
chk "再放锁后第二位 main 拿到" test "$(field board-a owner)" = main

echo "== 闲置留锁与自动续租"
chk "预计空档 ≥ 阈值（15 ≥ 10）hold 被拒" bash -c "! (cd '$R' && '$L' hold board-a --next 15m '等很久')"
chk "预计空档 < 阈值 hold 成功" in_line "$R" "$L" hold board-a --next 5m "编完回来"
chk "status 显示闲置与预估" bash -c "cd '$R' && '$L' status | grep -q '闲置·预计'"
(cd "$R" && bash -c "source '$T/wt_auto.sh'; need_lock board-a") >/dev/null 2>&1
chk "need_lock 放行后清掉闲置标记" test -z "$(field board-a idle)"
chk "need_lock 无锁时拒绝（退出码 3）" bash -c "cd '$R/wt/l1' && (source '$T/wt_auto.sh' && need_lock phone-a); test \$? -eq 3"
in_line "$R" "$L" release board-a >/dev/null

echo "== 过期须 --force、排队进程死了队位自动清"
in_line "$R/wt/l1" "$L" take phone-a "l1 短租" --ttl 1s >/dev/null; sleep 2
chk "持有者过期也不能直接拿" bash -c "! (cd '$R/wt/l2' && '$L' take phone-a 'l2 想要')"
chk "确认后 --force 拿到" in_line "$R/wt/l2" "$L" take phone-a "l2 确认后" --force
(cd "$R/wt/l1" && exec "$L" take phone-a "l1 排队后被杀" --wait >/dev/null 2>&1) & QP=$!; BG+=($QP); sleep 1.2
kill -9 "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; sleep 0.3
in_line "$R" "$L" status >/dev/null
chk "排队进程被杀后队位已清" test "$(ls "$R/.locks/phone-a.q" 2>/dev/null | wc -l)" = 0
chk "lock.sh run 拿到即跑、跑完即放" bash -c "cd '$R' && '$L' run board-a 'main 单条' -- true && test ! -f '$R/.locks/board-a'"
in_line "$R/wt/l2" "$L" release phone-a >/dev/null

echo "== 收线"
chk "wt.sh list 可用" "$W" list
chk "无改动的 l1 可收" "$W" rm l1
chk "l1 状态卡移入 _done/" bash -c "ls '$R/_ai_workspace/demo/wt/_done/' | grep -q '^l1_'"
git -C "$R/wt/l2/AppRepo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "l2 改动"
chk "有未合并提交的 l2 被拒" bash -c "! '$W' rm l2"
git -C "$R/AppRepo" merge -q --ff-only feat/l2
chk "合并进基线后 l2 可收" "$W" rm l2
chk "worktree 已移除" test ! -d "$R/wt/l2"

echo "== 结果：通过 $pass，失败 $fail"
(( fail == 0 ))
