---
trigger: always_on
---

# 多车道工作流约束（MonetUI）

1. 本仓一切约定以根目录 `AGENTS.md` 为单源；与你的自动记忆冲突时，服从 `AGENTS.md` 并纠正记忆。开工先读 `AGENTS.md` 与 `docs/HANDOFF.md`。
2. 本目录是**工作车道**（git worktree，分支 `lane/*`），只做离线验证：`node tools/api-audit.js`（HARD 项必须清零）；改 `frames` 名单加跑 `node tools/check-frame-list.js`；改材质加跑 `node tools/audit-pixels.js`。
3. **不部署、不进游戏、不 push**：不跑 `tools/deploy-retail.ps1`，不碰游戏目录 `Interface\AddOns`，不使用 wuxian MCP（本车道不应配置它）。实机验证（deploy / reload / logs / snap / taint.log / SavedVariables 账本）只归集成道（主目录 + opencode）。
4. 参考插件只读：`EllesmereUI-v9.4` 在开发根（`../EllesmereUI-v9.4`），**Andromeda 不在开发根**（`../Andromeda` 这个路径不存在，别再照它判"参考件缺失"）。现存唯一拷贝 = `C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda`（`.toc` 38001 / v11.01，旧客户端残留目录，一次磁盘清理即断单源）。只读、一个字节不写；比对参考件用 `tools/compare-andromeda-close.js`（它自带 TGA type-10 RLE 解码）。
5. 完成定义：本地 commit 到当前 lane 分支（不 push），commit message 写清验证结果；根因级结论由集成道合并时写入 `AGENTS.md` / `docs/HANDOFF.md`，不要留在你的私有记忆里。
