# 多 harness 并行工作流（opencode / Qoder CN / WorkBuddy）

> 写于 2026-10-31。目标：三家 harness 同机为 MonetUI 干活，**代码用 worktree 隔离、规则用单源文件统一、
> 独占资源收归集成道串行**，工作质量互不渗透。与 `docs/CODEX-SETUP.md`（单平台迁移）互补。

---

## 1. 车道布局

```
wowaddonsdev\
├── MonetUI\                    ← 集成道 = opencode（main 分支）
│                                  独占：wuxian MCP、deploy-retail.ps1、实机验证、合并权、
│                                  AGENTS.md / HANDOFF.md 的修改权
├── MonetUI-lane-qoder\         ← Qoder CN 车道（worktree，分支 lane/qoder-<任务>）
└── MonetUI-lane-workbuddy\     ← WorkBuddy 车道（worktree，分支 lane/wb-<任务>）
```

- 一个任务 = 一条分支 = 一个 harness。任务按**目录所有权**切分（如 Qoder 领 `Modules/X`、
  WorkBuddy 领 `tools/` 材质链），同一模块不并行。
- **绝不允许两个 harness 同时开同一个目录**（写文件没有锁，互相覆盖）。

## 2. 建车道

```powershell
powershell -File tools\make-lane.ps1 -Name qoder -Task <任务slug>
powershell -File tools\make-lane.ps1 -Name wb    -Task <任务slug>
```

脚本做三件事（细节在脚本头注释）：`git worktree add` → 拷贝未跟踪的记忆文件
（`AGENTS.md` / `TODO.md` / `MonetUI.md`，.gitignore 把它们排除，worktree 里天然没有）→
junction 只读共享件（`docs\api`、`tools\node_modules`、`Assets\Textures.bak`）。

## 3. 各家配置要点

### opencode（集成道，主目录）

- 现状即所需：`opencode.json` 已 deny 编辑参考插件；wuxian / context-mode 只挂这边。
- 额外职责：合并 lane 分支、跑全部闸门、部署与实机验证、**独家**更新
  `AGENTS.md` / `docs/HANDOFF.md` / `TODO.md`（避免两边同时改交接文档）。

### Qoder CN（车道）

- 软规则：`.qoder/rules/00-multilane.md`（Always Apply，随 git 进 worktree，已入库）。
- 硬边界：官方口径"记忆/规则**不是强制策略**"——用权限配置/Hooks 禁跑
  `tools/deploy-retail.ps1`、禁写主目录与游戏目录。
- MCP：只给 hated-wow / anysearch 一类查询型；**不配 wuxian**。
- auto-memory 是项目级的，车道各留各的，不共享；结论回单源（见 §5）。

### WorkBuddy（车道）

- 硬边界：`~/.workbuddy/settings.json` 的沙箱**写路径白名单只加该车道目录**
  （主目录、参考插件、游戏目录都不在名单里 = 物理只读）。这是三家里最强的强制层，务必配。
- MCP：`~/.workbuddy/mcp.json` **不配 wuxian**。
- 软规则：把下面这段放进 WorkBuddy 的项目规则（或首次对话贴给它，并要求写入工作区记忆）：

```text
本目录是 MonetUI 的工作车道（git worktree）。规则：
1) 一切约定以根目录 AGENTS.md 为单源，与你的记忆冲突时服从 AGENTS.md 并纠正记忆；
   开工先读 AGENTS.md 和 docs/HANDOFF.md。
2) 只做离线验证：node tools/api-audit.js（HARD 清零）；改材质另跑 node tools/audit-pixels.js。
3) 不部署、不进游戏、不 push：不跑 deploy-retail.ps1，不碰 Interface\AddOns，不用 wuxian MCP。
4) 参考插件 ../Andromeda、../EllesmereUI-v9.4 只读。
5) 完成 = 本地 commit 到 lane 分支 + commit message 写清验证结果；
   根因级结论留给集成道写入 AGENTS.md/HANDOFF.md，不要写进你的用户级 MEMORY.md。
```

- 记忆纪律（官方自己也这么建议）：**方法论归规则/技能，不归记忆**。用户级 `MEMORY.md`
  是全项目共享的 4000 字符/会话额度，别塞 MonetUI 专属结论；云端画像只读且会过时，
  车道里不要把临时结论当"用户偏好"说给它。

## 4. 独占资源表（冲突后果 → 规则）

| 资源 | 交叉的后果 | 规则 |
|---|---|---|
| 游戏客户端 + wuxian MCP | 两边同时 reload/run，探针结果互相顶掉 | 只有集成道配 wuxian；车道离线闸门 |
| `deploy-retail.ps1` 目标目录 | 实机跑的不知道是谁的代码 | 只在集成道、合并后部署一次 |
| SavedVariables 账本（compatReport 等） | 落盘比 reload 晚 1–2 分钟，B 读到 A 的上一趟 | 实机验证串行 |
| `Logs/taint.log` | 污染归因混在一起 | 归因排查期间只允许集成道进游戏 |
| context-mode 知识库 | 机器级单库，多 harness 混写串会话 | 只挂集成道 |
| code-review-graph 索引 | 按 repo root 分 | worktree 各自独立，无冲突，不用管 |

## 5. 防"记忆交叉污染"的纪律

- **结论只回单源**：任何车道挖出的根因级结论，合并时由集成道写进 `AGENTS.md` /
  `docs/HANDOFF.md`（带 commit 号），不许滞留在 Qoder auto-memory / WorkBuddy 记忆 /
  opencode context-mode 里当"只有某一家知道的事实"。
- 三家共读同一份 `AGENTS.md`（opencode、Qoder 原生支持；WorkBuddy 靠 §3 的适配规则指过去）。
  规则文件**永远单源**，不出现"Qoder 版规则"与"WorkBuddy 版规则"分叉。
- 技能权威副本在 `~/.qoder-cn/skills/`，同步按 `docs/CODEX-SETUP.md` §6（三文件齐拷 + hash 核对）。

## 6. 合并漏斗（单向）

1. 车道完成：本地 commit 到 `lane/*` 分支（message 含验证结果），通知集成道。
2. 集成道 `git merge lane/<name>-<task>`。
3. 闸门：`node tools/api-audit.js`（HARD=0）→ `wuxian check`（0 错 0 警）→
   `node tools/check-frame-list.js`（动了 frames 名单时）→ `node tools/audit-pixels.js`（动了材质时）。
4. `tools/deploy-retail.ps1` 部署一次 → `reload` → `/verify` 实机清单 → 读 `logs`。
5. 通过才落 main；更新 `HANDOFF.md` / `TODO.md`（只在集成道改）。
6. 清理：`git worktree remove ..\MonetUI-lane-<name>` + `git branch -d lane/<name>-<task>`。
   注意 junction 目录（docs\api 等）删除 worktree 前先 `rmdir` 掉链接本身，别删穿到主目录。

**不 push**：远端只作私有备份，上线前不推（见 AGENTS.md 工作习惯）。
