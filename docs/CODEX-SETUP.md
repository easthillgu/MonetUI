# 从 opencode 迁到 Codex：环境与记忆文件准备

> 写于 2026-10-24。目标：换平台后**零上下文丢失**地继续开发。
> 本仓里"记忆"分三层：`AGENTS.md`（硬规则，Codex 会自动读）→ `docs/HANDOFF.md`（状态与来龙去脉）→ `TODO.md` / `MonetUI.md`（待办与设计）。

---

## 1. Codex 会自己读什么

Codex CLI 启动时按目录层级收集 `AGENTS.md`（仓库根 + 子目录），把内容拼进系统提示。
所以本仓的 **`AGENTS.md` 就是主记忆文件**，不需要额外复制。

`AGENTS.md` 里现在包含：

- 验证流程（`wuxian check`、`api-audit.js`、`/verify` 实机清单）
- 安全边界（参考插件只读、资源自绘、受保护帧、state driver）
- **污染（taint）模型**（本客户端最贵的一课，含三条实例：编辑模式 / 姓名板驱动 / HUD 帧）
- 安全按钮（自绘动作条）的硬约束
- 代码风格与材质制作规范
- 交接指针（`docs/HANDOFF.md`、`TODO.md`）

**不要**把它压缩成短版：那些"看起来啰嗦"的段落，每一条都对应一次实机事故。

---

## 2. `~/.codex/config.toml` 参考片段

> 版本差异：下面按 2025-2026 的 Codex CLI 写法（`[mcp_servers.*]`）。装好后用 `codex mcp list` 核对；
> 也可以直接 `codex mcp add wuxian -- <命令> mcp` 让它自己写。

```toml
# 模型与审批（按你订阅的模型改）
model = "gpt-5-codex"
approval_policy = "on-request"          # 危险动作（写仓库外、跑长命令）先问
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
# 允许改动的根目录（仓库 + 部署目标），参考插件不在里面 = 天然只读
writable_roots = [
  "C:\\Users\\EastHillGu\\Documents\\wowaddonsdev\\MonetUI",
  "C:\\Users\\EastHillGu\\Documents\\Blizzards\\World of Warcraft\\_retail_\\Interface\\AddOns\\MonetUI",
]
network_access = true

# ---- MCP：游戏实机桥（wuxian）----
[mcp_servers.wuxian]
command = "C:\\Users\\EastHillGu\\AppData\\Local\\WuxianWorkshop.App\\current\\wuxian.exe"
args = ["mcp"]
env = { WUXIAN_LOG = "C:\\Users\\EastHillGu\\AppData\\Local\\WuxianWorkshop\\logs\\mcp.log" }
startup_timeout_sec = 30
tool_timeout_sec = 120

# ---- MCP：暴雪 UI 源码 / API 资料（补充用，优先级低于 docs/api）----
[mcp_servers.hated-wow]
command = "npx"
args = ["-y", "hated-wow-mcp"]
startup_timeout_sec = 60
```

要点：

- **`wuxian` 是实机桥**：`status` / `check` / `reload` / `run` / `try` / `logs` / `snap` / `inspect`。
  游戏必须在线（在世界里、没最小化）；`link.state` 不是 `online` 就先让玩家处理。
- **`hated-wow` 只作补充**（正式服数据）；**本客户端 API 一律以 `docs/api/` 快照为准**
  （`node tools/api-lookup.js <名字>`，正文 `docs/api/MANUAL.md`）。
- opencode 的 `opencode.json` 里还有两条"编辑参考插件 = deny"的权限；Codex 没有等价项，
  靠 `writable_roots`（参考插件不在可写根里）+ 自觉：**`../Andromeda`、`../EllesmereUI-v9.4` 只读**。
- **不要给 Codex 开"自动 push"**：本仓规定游戏上线前不推远端（见 `TODO.md` 末尾）。

---

## 3. 没接上 wuxian MCP 时的降级流程

1. `node tools/api-audit.js`（离线闸门，HARD 项必须清零）。
2. `powershell -File tools/deploy-retail.ps1`（拷到 `Interface\AddOns\MonetUI` 并改写 toc 的 Interface）。
3. 请玩家：游戏内 `/console scriptErrors 1` → `/reload` → 复现 → 把聊天框红字/截图发回来。
4. 深挖污染：`/console taintLog 2` → `/reload` → 退出后读
   `...\_retail_\Logs\taint.log`（**CVar 只在加载时生效**，运行中改无效）。
5. 让玩家在游戏里跑一行诊断（可复制粘贴）：

```lua
/dump issecurevariable(_G.MinimapCluster, "IsInDefaultPosition"), issecurevariable(_G.ObjectiveTrackerFrame, "foo")
```

---

## 4. 平台差异清单（迁移时容易踩）

| opencode 里有的 | Codex 里怎么补 |
|---|---|
| `opencode.json` 的 `permissions`（deny 参考插件编辑） | `writable_roots` 限定 + 口头规则（已写进 `AGENTS.md`） |
| `references`（把参考插件挂成可读目录） | 直接把绝对路径写进任务描述；Codex 有整机读权限 |
| `tool_output` 限制（800 行 / 30KB） | 无等价；自己 grep 定位、别整文件读（147KB 的 `MonetUI.md` 尤其） |
| `/check`、`/verify` 自定义命令（`.opencode/command/`） | 用 `AGENTS.md` 里的命令行替代；或写 `docs/CHECKS.md` 让 agent 照着跑 |
| `context-mode` MCP（大输出走沙箱） | 无等价；用 `node -e` / `powershell` 过滤后再看 |

> `.opencode/` 目录保留着（gitignore），里面的自定义命令可以当"流程备忘"读，不依赖它也能干活。

---

## 5. 新平台第一次对话建议直接贴这段

```
读 AGENTS.md 和 docs/HANDOFF.md，按 HANDOFF 第 9 节的顺序继续。
本轮只做一件事：进/出编辑模式 3 次做回归（oldR 与 ADDON_ACTION_BLOCKED 应都为 0），
有 wuxian MCP 就用 check/reload/logs/snap，没有就让我手动复现并给你贴日志。
改完只做本地 commit，不要 push。
```

---

## 6. 记忆文件的维护约定

- **每次修完一个"根因级"问题**：在 `AGENTS.md` 的对应小节补一条（一句话结论 + 一句为什么），
  在 `docs/HANDOFF.md` 的"这一轮修了什么"里加行（带 commit 号）。
- **每次开新坑**：`TODO.md` 加"未决"，做完挪到"已决"并写清验证方式。
- `docs/`、`tools/`、`*.md` 都被 `.gitignore` 排除（作者有意：git 只跟踪插件源码），
  所以这些文档**不会进版本库**，换机/换平台要**整目录拷贝**（含 `.git`）。
- **技能的权威副本在 `~/.qoder-cn/skills/<名字>/`（CLI 实际加载的那份）**，仓库里的
  `.opencode/skills/<名字>/` 只是本机镜像、而且被 `.gitignore:33` 排除 —— 换机不会跟着走。
  同步时**三个文件一起拷**，别只拷脚本（SKILL.md 与 references 每次都会跟着改，只拷 cjs 会出现
  "文档写 80 条 / 脚本报 208 条"这种对不上的情况，2026-10-30 就踩过一次）：

  ```
  cp -f ~/.qoder-cn/skills/wow-secret-value-guard-audit/SKILL.md                     .opencode/skills/wow-secret-value-guard-audit/SKILL.md
  cp -f ~/.qoder-cn/skills/wow-secret-value-guard-audit/references/guard-and-attribution.md .opencode/skills/wow-secret-value-guard-audit/references/
  cp -f ~/.qoder-cn/skills/wow-secret-value-guard-audit/scripts/scan-secret-guards.cjs     .opencode/skills/wow-secret-value-guard-audit/scripts/
  ```
  拷完用 `Get-FileHash` 逐个核对三份一致，再跑一次全仓扫描（基线：50 个 .lua、
  `NEEDS-LOOK 80 / SUSPECT 0`；数字明显变大就说明装的是旧版）。
