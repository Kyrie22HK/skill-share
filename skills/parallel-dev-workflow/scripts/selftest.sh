#!/bin/bash
# 自检：在临时目录里造两个 git 仓库，跑通一整轮并行开发任务——
# init → 登记设备 → 开线 → 按目录识别当前线 → 用锁语义 → 中途加线 / 加设备 / 下线设备 → 收线 → close 归档 → 再开一轮（指定归档目录）并关闭。
# 不碰任何真实项目；约 40 秒（排队用例要等轮询）。用法：bash selftest.sh   退出码 0 = 全过
set -u
SRC=$(cd "$(dirname "$0")" && pwd)
SB=$(mktemp -d /tmp/pdw-selftest.XXXXXX)
BG=()
cleanup() { local p; for p in "${BG[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done; rm -rf "$SB"; }
trap cleanup EXIT
unset PDW_LINE PDW_ROOT LOCK_BYPASS APP_DIR FW_DIR SINK_PORT RUNDIR 2>/dev/null

pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
ng() { echo "  ❌ $1"; fail=$((fail + 1)); }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ng "$d"; fi; }

R=$SB/proj
mkdir -p "$R"
for n in app fw; do
    git init -q "$R/$n"; git -C "$R/$n" symbolic-ref HEAD refs/heads/main
    git -C "$R/$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
mkdir -p "$R/app/node_modules/x"; echo 1 >"$R/app/node_modules/x/f"; echo node_modules/ >"$R/app/.git/info/exclude"
P0=$SRC/pdw.sh
in_dir() { local d=$1; shift; (cd "$d" && "$@"); }

echo "== 开一轮任务"
chk "init（两仓库、端口、环境变量、硬链接目录）" in_dir "$R" "$P0" init demo --repo app=app@main --repo fw=fw \
    --port SINK_PORT=8765:10 --env 'RUNDIR=/tmp/demo-$PDW_LINE' --hardlink app:node_modules
P=$R/.pdw/bin/pdw.sh; L=$R/.pdw/bin/lock.sh
chk "脚本副本就位（.pdw/bin）" test -x "$P" -a -x "$L" -a -f "$R/.pdw/bin/pdw_env.sh"
chk "任务卡生成" grep -q '并行开发任务：demo' "$R/.pdw/task.md"
chk "同一根目录不能重复 init" bash -c "! (cd '$R' && '$P0' init again --repo app=app)"
chk "登记设备 board-a（阈值 10，带 IP 与基线）" in_dir "$R" "$P" device add board-a --idle 10 --desc 主板 --ip 10.0.0.2 --baseline "主线固件、默认密码"
chk "登记设备 phone-a（阈值 20）" in_dir "$R" "$P" device add phone-a --idle 20 --desc 测试手机
chk "登记设备缺 --idle 被拒" bash -c "! (cd '$R' && '$P' device add bad)"
chk "设备事件记进任务卡" grep -q '登记设备 board-a' "$R/.pdw/task.md"

echo "== 开线与线环境"
chk "line new l1（缺省仓库 app）" in_dir "$R" "$P" line new l1 "演示线一"
chk "l1 的 app worktree 在 feat/l1 上" test "$(git -C "$R/wt/l1/app" branch --show-current)" = feat/l1
chk "node_modules 是硬链接树（同 inode）" test "$(stat -c %i "$R/wt/l1/app/node_modules/x/f")" = "$(stat -c %i "$R/app/node_modules/x/f")"
E=$R/wt/l1/.line.env
chk ".line.env：APP_DIR 指 worktree" grep -q "APP_DIR=\${APP_DIR:-$R/wt/l1/app}" "$E"
chk ".line.env：没拉的 FW_DIR 指主目录" grep -q "FW_DIR=\${FW_DIR:-$R/fw}" "$E"
chk ".line.env：端口按线号错开（8765+10×1）" grep -q 'SINK_PORT=${SINK_PORT:-8775}' "$E"
chk ".line.env：模板变量已展开" grep -q 'RUNDIR=${RUNDIR:-/tmp/demo-l1}' "$E"
chk "状态卡生成" test -f "$R/.pdw/cards/l1.md"
chk "line new l2 --repos app,fw" in_dir "$R" "$P" line new l2 --repos app,fw "演示线二"
chk "按目录识别当前线：l1 目录里是 l1" test "$(in_dir "$R/wt/l1/app" "$L" whoami)" = l1
chk "按目录识别当前线：根目录是 main" test "$(in_dir "$R" "$L" whoami)" = main
chk "板子 IP 映射到设备名" test "$(cd "$R" && bash -c "source '$R/.pdw/bin/pdw_env.sh'; board_res_of_ip 10.0.0.2")" = board-a
chk "未登记的设备拿锁被拒" bash -c "! (cd '$R' && '$L' take nosuch 'x')"
chk "line start 起手简报可用" bash -c "cd '$R' && '$P' line start l1 | grep -q '用锁规则'"

echo "== 先来先得排队（约 25 秒）"
in_dir "$R/wt/l1" "$L" take board-a "l1 用" >/dev/null
chk "拿锁时提示归还基线" bash -c "cd '$R/wt/l1' && '$L' release board-a >/dev/null && '$L' take board-a 'l1 用' | grep -q '基线：主线固件'"
chk "被占时不带 --wait 拿锁失败" bash -c "! (cd '$R/wt/l2' && '$L' take board-a 'l2 不等')"
(cd "$R/wt/l2" && exec "$L" take board-a "l2 排队" --wait >/dev/null 2>&1) & BG+=($!); sleep 1.2
(cd "$R" && exec "$L" take board-a "main 排队" --wait >/dev/null 2>&1) & BG+=($!); sleep 1.2
chk "status 列出两个队位" test "$(in_dir "$R" "$L" status | grep -c '排队 [12]：')" = 2
chk "放锁瞬间不带 --wait 的第三方不插队" bash -c "cd '$R/wt/l1' && '$L' release board-a >/dev/null && ! '$L' take board-a 'l1 想插队'"
sleep 11
chk "持有者放锁后队首 l2 拿到" test "$(sed -n 's/^owner=//p' "$R/.pdw/locks/board-a")" = l2
chk "被持锁的设备不能下线" bash -c "! (cd '$R' && '$P' device rm board-a)"
in_dir "$R/wt/l2" "$L" release board-a >/dev/null; sleep 11
chk "再放锁后第二位 main 拿到" test "$(sed -n 's/^owner=//p' "$R/.pdw/locks/board-a")" = main

echo "== 闲置留锁、自动续租、过期、死进程队位"
chk "预计空档 ≥ 阈值（15 ≥ 10）hold 被拒" bash -c "! (cd '$R' && '$L' hold board-a --next 15m '等很久')"
chk "预计空档 < 阈值 hold 成功" in_dir "$R" "$L" hold board-a --next 5m "编完回来"
chk "status 显示闲置与预估" bash -c "cd '$R' && '$L' status | grep -q '闲置·预计'"
(cd "$R" && bash -c "source '$R/.pdw/bin/pdw_env.sh'; need_lock board-a") >/dev/null 2>&1
chk "need_lock 放行后清掉闲置标记" test -z "$(sed -n 's/^idle=//p' "$R/.pdw/locks/board-a")"
chk "need_lock 无锁时拒绝（退出码 3）" bash -c "cd '$R/wt/l1' && (source '$R/.pdw/bin/pdw_env.sh' && need_lock phone-a); test \$? -eq 3"
in_dir "$R" "$L" release board-a >/dev/null
in_dir "$R/wt/l1" "$L" take phone-a "l1 短租" --ttl 1s >/dev/null; sleep 2
chk "持有者过期也不能直接拿" bash -c "! (cd '$R/wt/l2' && '$L' take phone-a 'l2 想要')"
chk "确认后 --force 拿到" in_dir "$R/wt/l2" "$L" take phone-a "l2 确认后" --force
(cd "$R/wt/l1" && exec "$L" take phone-a "l1 排队后被杀" --wait >/dev/null 2>&1) & QP=$!; BG+=($QP); sleep 1.2
kill -9 "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; sleep 0.3
in_dir "$R" "$L" status >/dev/null
chk "排队进程被杀后队位已清" test "$(ls "$R/.pdw/locks/phone-a.q" 2>/dev/null | wc -l)" = 0
chk "lock.sh run 拿到即跑、跑完即放" bash -c "cd '$R' && '$L' run board-a 'main 单条' -- true && test ! -f '$R/.pdw/locks/board-a'"
in_dir "$R/wt/l2" "$L" release phone-a >/dev/null

echo "== 开发中加线、加设备、下线设备"
chk "中途加线 l3" in_dir "$R" "$P" line new l3 "中途加的线"
chk "中途加设备 mac（阈值 10）" in_dir "$R" "$P" device add mac --idle 10 --desc 打包机
chk "新设备立即可拿锁" bash -c "cd '$R/wt/l3' && '$L' take mac 'l3 打包' && '$L' release mac"
chk "下线空闲设备" in_dir "$R" "$P" device rm mac
chk "下线后不能再拿锁" bash -c "! (cd '$R' && '$L' take mac 'x')"

echo "== 收线与关闭集成线"
chk "还有线在跑时 close 被拒" bash -c "! (cd '$R' && '$P' close)"
chk "无改动的 l1 可收" in_dir "$R" "$P" line rm l1
git -C "$R/wt/l2/app" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "l2 改动"
chk "有未合并提交的 l2 被拒" bash -c "! (cd '$R' && '$P' line rm l2)"
git -C "$R/app" merge -q --ff-only feat/l2
chk "合并进基线后 l2 可收" in_dir "$R" "$P" line rm l2
chk "放弃的线 l3 用 --force 收" in_dir "$R" "$P" line rm l3 --force
chk "status 可用" in_dir "$R" "$P" status
chk "全部收完后 close 成功" in_dir "$R" "$P" close
chk ".pdw 已清理" test ! -e "$R/.pdw"
chk "归档里有任务卡与三张线状态卡" bash -c "ls '$R'/.pdw-archive/*_demo/task.md && test \$(ls '$R'/.pdw-archive/*_demo/cards | wc -l) = 3"
chk "关闭后没有任务，命令给出提示" bash -c "cd '$R' && '$P0' status 2>&1 | grep -q '没有进行中的并行开发任务'"
chk "关闭后可以再开一轮（--archive 指定归档目录）" in_dir "$R" "$P0" init round2 --repo app=app --archive notes/rounds
chk "conf 记下归档目录（相对根目录解析成绝对路径）" grep -qxF "PDW_ARCHIVE_DIR='$R/notes/rounds'" "$R/.pdw/conf.sh"
chk "round2 无线无锁，close 成功" in_dir "$R" "$P" close
chk "归档落到指定目录、不进 .pdw-archive" bash -c "ls '$R'/notes/rounds/*_round2/task.md && ! ls -d '$R'/.pdw-archive/*_round2"

echo "== 结果：通过 $pass，失败 $fail"
(( fail == 0 ))
