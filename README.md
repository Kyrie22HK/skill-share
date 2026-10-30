# skill-share

团队共享的 Agent Skills 仓库（Claude Code / Codex）：把日常打磨出来的可复用工作规范（skill）集中存放、统一维护。**本仓库是每个 skill 的唯一权威版本**——本地不要保留独立副本，改进直接改仓库。

## 使用方式

克隆仓库后，把需要的 skill 逐个软链到用户级 skills 目录（软链方式下 `git pull` 即完成更新，不会出现本地旧版滞留）：

```bash
git clone git@192.168.8.250:skill-share/skill-share.git
cd skill-share
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/work-report" ~/.claude/skills/work-report
# 需要哪个链哪个；之后在任意项目的 session 中输入 /work-report 即可使用
```

Codex 使用用户级技能目录软链（在仓库根执行；先核对同名项，不强制覆盖）：

```bash
mkdir -p ~/.agents/skills
for skill in skills/*; do
  name="$(basename "$skill")"
  if [ -e "$HOME/.agents/skills/$name" ] || [ -L "$HOME/.agents/skills/$name" ]; then
    printf '已存在，请核对：%s\n' "$HOME/.agents/skills/$name"
  else
    ln -s "$(pwd)/$skill" "$HOME/.agents/skills/$name"
  fi
done
```

在 Codex 中用 `$work-report`、`$project-tour` 等指定技能，或直接描述任务。若技能列表尚未刷新，重启会话；也可显式读取仓库内相应 `SKILL.md`。目录发现与软链支持见 [官方技能文档](https://learn.chatgpt.com/docs/build-skills)。调用时从 SKILL.md 的真实路径定位附属脚本，不从项目工作目录猜路径。

Claude / Codex 共用同一份规格、脚本和质量要求，不维护两套正文。客户端的记忆、目标模式、会话通信与浏览器能力按实际工具核验；可读取、被发现和实跑通过是三个不同层级。

报告和导览必须使用共享壳与内容组件，先对照既有优质样本，再完成结构检查、真实浏览器和视觉审读。`selfcheck.py --profile report|tour` 检查结构与壳；已有 Chrome 的 POSIX 环境可用 `browser_check.py --html <成品> --out <证据目录>` 保存三种视口的截图、交互和视频结果。浏览器检查不能替代内容事实和视觉质量判断；详见 [排版与实跑验收](skills/work-report/排版与实跑验收.md)。

更新：在 clone 目录 `git pull` 即可，所有软链过的 skill 立刻生效；改进 skill 也是直接改 clone 里的文件（改完即全局生效，验证后提交）。

> Windows 环境软链可能不可用，可复制到相应客户端的技能目录，更新时重新复制并核对版本。

## Skill 清单

| 名称 | 用途 | 负责人 |
|------|------|--------|
| [claude-to-codex-workspace](skills/claude-to-codex-workspace/SKILL.md) | 将现有 Claude 工作区适配为 Codex，保留任务接续、项目边界和证据，附迁移模式与验收清单 | kyrie |
| ai-workspace-setup | 为新项目搭建 `_ai_workspace` AI 协作工作区（跨 session 记忆框架） | kyrie |
| work-report | 撰写双版（md+html）工作报告，自带共享壳、组装、结构检查与浏览器实跑流水线 | kyrie |
| project-tour | 制作单文件自包含 HTML 项目导览，给新接手者建立系统认知 | kyrie |
| skill-intake | 制作新 skill 或把存量 skill 标准化后入库（含质量保护红线） | kyrie |
| test-process-table-conversion-tool | 把公司软件测试流程表（Excel）转换为结构化分步测试用例表 | kyrie |
| leader | 把一句话的想法拆成适配实际客户端的目标任务书，含防作弊验收与断点续跑 | kyrie |
| parallel-dev-workflow | 一轮多会话并行开发任务：问清功能与设备 → 建集成线、设备锁、功能线（一线一会话一 worktree）→ 运行中加线 / 加减设备 → 全部收线后关闭集成线；自带 pdw.sh / lock.sh 与自检 | kyrie |

新增 skill 见 [CONTRIBUTING.md](CONTRIBUTING.md)。
