# skill-share

团队共享的 Claude Code Agent Skills 仓库：把日常打磨出来的可复用工作规范（skill）集中存放、统一维护。**本仓库是每个 skill 的唯一权威版本**——本地不要保留独立副本，改进直接改仓库。

## 使用方式

克隆仓库后，把需要的 skill 逐个软链到用户级 skills 目录（软链方式下 `git pull` 即完成更新，不会出现本地旧版滞留）：

```bash
git clone git@192.168.8.250:skill-share/skill-share.git
cd skill-share
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/work-report" ~/.claude/skills/work-report
# 需要哪个链哪个；之后在任意项目的 session 中输入 /work-report 即可使用
```

更新：在 clone 目录 `git pull` 即可，所有软链过的 skill 立刻生效；改进 skill 也是直接改 clone 里的文件（改完即全局生效，验证后提交）。

> Windows 环境软链可能不可用，请改用复制安装（`cp -r skills/<名称> ~/.claude/skills/`），更新时重新复制。

## Skill 清单

| 名称 | 用途 | 负责人 |
|------|------|--------|
| ai-workspace-setup | 为新项目搭建 `_ai_workspace` AI 协作工作区（跨 session 记忆框架） | kyrie |
| work-report | 撰写双版（md+html）工作报告，自带壳模板/组装/自检脚本流水线 | kyrie |
| project-tour | 制作单文件自包含 HTML 项目导览，给新接手者建立系统认知 | kyrie |
| skill-intake | 制作新 skill 或把存量 skill 标准化后入库（含质量保护红线） | kyrie |

新增 skill 见 [CONTRIBUTING.md](CONTRIBUTING.md)。
