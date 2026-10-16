# MonetUI 代码审查报告 — 2026-10-15

审查目标：依据无限工坊（WuxianWorkshop）内置 API 手册（manual 2026.10.11.3）审查全部代码的合法性，
并基于既有代码整理出优化方向。

## 0. 审查方式

| 手段 | 覆盖 |
|---|---|
| 无限工坊 `check` 静态检查（30 个文件，`live=false`） | 语法 / 缺失 API / 受限事件 / 保护函数 / secret 用法 / .toc |
| `api_search` 核验存疑 API | `ADDON_RESTRICTION_STATE_CHANGED`、`C_Secrets.HasSecretRestrictions`、`GetMinimapShape` |
| 人工通读 | Core、Utils 全部、.toc、Minimap、关键行抽验 |
| 两个并行深读 | ActionBars / Nameplates / UnitFrames / LAB；Config / InfoBar / Skins×7 / Cooldown / BuffFrame / BagFrame / QuestTracker |

**当时游戏未在线**（link offline），因此 live 校验与实机验证未做，见 §6 验证清单。

`check` 结果：**0 错误、1 警告（GetMinimapShape 全局写入，有意为之）、22 个未解析全局**——
22 个全部是经 `_G[name]` 守卫访问的暴雪按需加载框架（QuestLogFrame、FriendsFrame 等），
属安全模式，实机可用 `/mui skins diagnose` 确认。

---

## 1. 合法性结论（逐条硬规则）

| # | 规则 | 结论 |
|---|---|---|
| 1 | Lua 5.1（无 `//`、`goto`、位运算、`table.unpack`、`utf8/os/io/require`） | ✅ 全仓库合规（`EventBus.lua:94` 用的是 `unpack`） |
| 2 | 保密值（secret values）不做算术/比较/格式化/concat | ✅ 主体合规：InfoBar 六块、Cooldown、BuffFrame、UnitFrames 主路径全部经 `Secrets.Number/Bool/Measure/SetBar`；**4 处漏网见 §3-B** |
| 3 | 事件注册 | ✅ 全仓库**无** `COMBAT_LOG_EVENT_UNFILTERED`；事件经 EventBus pcall 兜底。✅ `ADDON_RESTRICTION_STATE_CHANGED` 已核验：手册存在、`call: ok`。⚠️ 2 个事件名待实机确认（§3-E） |
| 4 | 保护函数 / 战斗安全 | ⚠️ 主体合规（InfoBar `OpenPanel` 三重守卫、LAB 战斗守卫到位），**4 处缺口见 §3-D** |
| 5 | 暴雪框架裸名访问需守卫 | ✅ 22 个 unresolved 全部 `_G[name]` + `if frame then` 守卫，缺帧安全降级 |
| 6 | 全局写入 | 仅 `Minimap.lua:61 GetMinimapShape`（注释说明有意为之），`check` 唯一警告 |
| 7 | .toc / 文件清单 | ✅ check 未报缺文件或 Interface 错误 |
| — | `C_Secrets.HasSecretRestrictions`（Secrets.lua 依赖） | ✅ 已核验存在、`call: ok` |
| — | `GetMinimapShape` | ⚠️ 手册查无此项——本客户端可能已无人读取它（无害），见 §4 |

**总体结论：项目在 API 合法性上是干净的**（0 静态错误、无 CLEU、无 5.1 违规、暴雪框架守卫完整）；
发现的问题集中在**运行期缺陷**（2 个 P0，已修复）、**模块开关/战斗安全**与**性能整理**。

---

## 2. 本次已修复（P0）

### 2.1 `Utils/EventBus.lua:62` — pcall 参数求值顺序导致启动链死亡
原代码 `pcall(frame.RegisterEvent, EnsureFrame(), event)`：Lua 先求值 `frame.RegisterEvent`，
此刻 upvalue `frame` 还是 nil → **在 pcall 之外**抛 "attempt to index a nil value"，
`EnsureFrame()` 永远不会执行。首次注册（Widget.lua:261）即崩，且 `Core.lua:556`（ADDON_LOADED）
再次崩 → Core chunk 中止 → `PLAYER_LOGIN` 不注册、`ns:StartModules()` 不执行、
`_G.MonetUI = ns` 不赋值 → **整个插件启动链死亡**。

修复：先 `local f = EnsureFrame()` 再 pcall；同时内部事件（`MONETUI_*`）不再被当 WoW 事件注册
（否则修好后每次加载会打印多条红色 Report 噪音）。

### 2.2 `Modules/ActionBars/ActionBars.lua:666` — pcall 只接一个返回值
原代码 `local button = pcall(CreateFrame, ...)`，成功时 `button = true`，
下一行 `button:SetPoint` 对布尔值取索引 → 必然报错。连带影响（修复前）：
1. `CreateLeaveVehicle` 抛错中断 `M:Build` → `M:Apply` 中 `SetBarShown/AdoptAll/ParkBlizzard/ReassignBindings/applied=true` 全未执行（自绘条不显示、暴雪条不隐藏）；
2. `built=true` 已置位，重试路径只能靠脱战 `PLAYER_REGEN_ENABLED`；每次脱战再抛一次错；
3. 屏幕残留一个无状态驱动的空方框。

修复：`local okButton, button = pcall(...)` + `if not okButton or not button then`。

**修复后复跑 `check`：0 错误，警告同前（仅 GetMinimapShape）。**

---

## 3. 待修复清单（按优先级）

### A. 模块开关不生效 / 状态不还原（P1）
| 位置 | 问题 | 建议 |
|---|---|---|
| `BuffFrame.lua:236-241`（已抽验） | 事件回调直接 `M:Update()`，**无 `M.active` 守卫**：关闭模块后下一次 `UNIT_AURA`/主题变化会把容器重新显示出来 | 每个回调首行 `if not M.active then return end` |
| `BuffFrame.lua:206-222 + 246-254` | `SuppressBlizzard`（UnregisterAllEvents + 覆盖 OnShow + Hide）**不可逆**，`SetEnabled(false)` 只藏自绘容器 → 关闭后 Buff 彻底不显示，且无提示 | 关闭时打印「执行 /reload 恢复」或还原暴雪框 |
| `Cooldown.lua:135-143`（已抽验） | `RefreshAll` 无 `M.active` 守卫：关闭后下一次 `ACTIONBAR_UPDATE_USABLE` 立刻重新上色 | 同上加守卫；`SetEnabled(false)` 提示字体需 /reload |
| `UnitFrames.lua:781-786` | `SetEnabled(false)` 只藏自绘框，**暴雪框已被压制且事件被清空**，不还原 → 同时失去两套框 | `SetEnabled` 按需调 `SuppressBlizzard(enabled and hideBlizzard)` |
| `Skins.lua:239-244`（已抽验） | `HookShow` 无幂等：`HookScript` 每次追加 handler，皮肤随 QUEST_LOG_UPDATE / 任意 ADDON_LOADED / 换图**无限累积** | 加 `frame.__monetOnShowHooked` 标志 |

### B. 保密值漏网（P1）
| 位置 | 问题 | 建议 |
|---|---|---|
| `UnitFrames.lua:397` | `UnitPowerType(unit) ~= def.requirePower` 对可能为 secret 的第一返回值裸比较（同文件 :248 自己有 `Secrets.IsSecret` 守卫） | `local pt = Secrets.Number(UnitPowerType(unit))` 再比 |
| `Nameplates.lua:574` | `startMS or 0` 真值测试发生在 pcall **之前**，secret 施法时间会 raise | `Secrets.Number(startMS)` 后再传，或复用 `Secrets.SetBar` |
| `Nameplates.lua:609-611` | `UnitIsDeadOrGhost/UnitIsConnected` 裸调用，未走本模块 `Query()`（:210） | 包 `Query(...)`，与 :244/:274 风格对齐 |
| `UnitFrames.lua:248/:166/:475` 等 | 单位 API 裸调用无 pcall，与 Nameplates 的 `Query()` 风格不一致 | 统一引入 Query 包装（P1 低） |

### C. 第三方库 LibActionButton-1.0（vendored，P1）
| 位置 | 问题 | 建议 |
|---|---|---|
| `LAB:1246-1312` | 约 35 个 `RegisterEvent` **裸调无 pcall**：任一该 build 没有的事件（`GAME_PAD_ACTIVE_CHANGED`、`LOSS_OF_CONTROL_*`、`SPELL_FLYOUT_UPDATE`…）即 raise，且留下**半初始化状态**（`InitializeEvents` 永不重跑）→ 按钮能创建但永不响应事件 | 在 ActionBars 侧给库打补丁：逐条 pcall 注册 |
| `LAB:1952-2017` | 冷却/充能返回值裸算术与比较（`expirationTime - currentTime`、`charges < maxCharges`…），受限状态冷却值为 secret 时每次事件 raise（OnEvent 无 pcall，直接冒泡） | 对 `ACTIONBAR_UPDATE_COOLDOWN` 做限制期跳过，或本地补丁走 `Secrets` |

### D. 战斗安全（P1）
| 位置 | 问题 | 建议 |
|---|---|---|
| `BuffFrame.lua:206+` | 模块可在战斗中开启 → `Initialize` 战斗中对暴雪框 `UnregisterAllEvents/SetScript/Hide` + CreateFrame | `InCombatLockdown()` 时延迟到 `PLAYER_REGEN_ENABLED` |
| `ActionBars.lua:1044-1059` | `RestoreBlizzard` 战斗中 `SetParent(UIParent)` 会被拒（pcall 静默失败）→ 模块认为已关、暴雪条回不来 | 置 `restoreDirty`，在已有的 REGEN_ENABLED 处理器补跑 |
| `System.lua:126-132` | `hooksecurefunc("UIDropDownMenu_CreateFrames", ...)`：① 未判 `hooksecurefunc` 存在；② 回调不判 `M.active` → 关皮肤后新下拉仍被染色（钩子不可卸载） | `_G.hooksecurefunc` 守卫 + 回调首行 `if not M.active` |
| `QuestTracker.lua:54` / `BagFrame.lua:29` | 拖拽/重排无战斗判断 | 首行 `InCombatLockdown()` 守卫 + 脱战补跑（项目文档已有此约定） |

### E. 需实机核验（P1-验证）
| 项 | 说明 |
|---|---|
| `InfoBar.lua:456` `CALENDAR_UPDATE_PENDING_INVITES` | 事件名未验证（API 手册离线时未查）；注册前只守卫了 `C_Calendar.GetNumPendingInvites` 存在 |
| `Blocks.lua:435` `ACTIVE_TALENT_GROUP_CHANGED` | 手册未见记载，若缺失只会在日志打一行错误并静默降级 |
| `Blocks.lua:101-113` 耐久签名探测 | 只验「不报错」不验「有值」：若签名是 `(unit, slot)` 会**永久误判**成 slot 模式且 diagnose 还报「已实测」 | 探测时校验返回值非 nil |

---

## 4. 优化整理（P2）

### 4.1 性能
1. **换图触发 3 遍全量刷新**：`Core.lua:573-575` ZONE_CHANGED 三兄弟各 fire 主题刷新 → ActionBars `UpdateAll`（96 按钮 × UpdateConfig+字体）、Nameplates 全板、Widget 全量重染各跑 3 遍。→ 模块内同帧去抖（`C_Timer.After(0, ...)` 合并），或把主题响应缩窄为只刷颜色。
2. **OnUpdate 轮询应改 `C_Timer`**（全仓库 0 处 C_Timer）：`Blocks.lua:314`（系统块每秒刷新）、`BuffFrame.lua:194`（0.25s 节流）→ `C_Timer.NewTicker/NewAfter`。（InfoBar.lua:100 的动画 OnUpdate 自停，合规。）
3. **InfoBar `Relayout`**：每次 `SetText` 都全栏 ClearAllPoints+SetPoint（system 块每秒一次）→ 宽度未变时跳过（记 `lastWidth`）。
4. **Cooldown 每次事件遍历 96 按钮**且 `SetVertexColor` 无条件下推 → 缓存 `__monetTint`，颜色未变跳过；`ACTIONBAR_UPDATE_COOLDOWN` 只需刷样式。
5. **Nameplates 血量事件路由太粗**：`UNIT_HEALTH` 跑完整 `UpdatePlate`（ShouldShow 过滤链+文本+施法）→ 直接路由 `UpdateHealth`；:622 与 :600 重复查 `UnitHealth/Max` → 取一次共用。
6. **Skins `ADDON_LOADED` 对任意插件全量 `ApplyAll()`**（20+ 面板 × GetRegions 遍历）→ 过滤 `Blizzard_` 前缀或 0.1s 去抖；`PLAYER_ENTERING_WORLD` 同理。
7. **`BagFrame.lua:74`**：`BAG_UPDATE`（超高频）每次 13 次 `_G` 查找 → 已 skin 的快路径返回。
8. **`Blocks.lua:262-294`**：内存统计每次遍历全部插件建名表 → 名列表会话内不变，首次缓存。
9. **ActionBars `ADOPT_EVENTS`**：`UNIT_PET/UNIT_FLAGS` 全单位广播触发 AdoptAll（SetScale+SetPoint+数十 SetTexCoord/SetFont）→ 改 `RegisterUnit(..., "player")`；`PET_BAR_UPDATE_*`、`PLAYER_TARGET_CHANGED` 与条位置无关，可删。
10. **LAB 实例钩子约 288 个**（96 按钮 × Border Show/Hide + HotKey SetText），每次 Update 触发 RefreshRing → 改脏标记批量刷（可选）。

### 4.2 可维护性（「整理」）
1. **Skins 七文件的四段式样板**（`SkinWindow + Tabs + Controls(Strip/Panel/ButtonsIn/ScrollsIn)`）重复 ≥4 处（Character/Collections/Trade/WorldMap）→ 在 `Skins.lua` 抽 `M:SkinPanelGroup(list, opts)` 与 `M:ControlsByKind(list)`（EditBox/Dropdown 分发在 Collections:77 与 Trade:66 逐字重复）。
2. **`frames` 清单与代码里的名字是两份手工维护的副本**（如 Quest.lua:15-24 vs :99-120）→ 让 `M:Panel` 接收「名字→用途」单一数据源，`Diagnose` 与 apply 共用。
3. **模块关闭的用户体验不统一**：Skins 有 /reload 提示，BuffFrame/BagFrame/QuestTracker/Cooldown 没有 → 统一策略（或都做可逆还原）。
4. `QuestTracker.lua:71-78` `SavePosition` 整表替换 `db.questTracker = {...}`，未来加字段会被抹掉 → 字段级写入。
5. `Social.lua:34` `WhoFrame or FriendsFrame` 缺失时对 FriendsFrame 双重贴板语义混乱 → `if not _G.WhoFrame then return end`。
6. `Trade.lua:11-14` 对 MailFrame 的子帧（Inbox/SendMail）也各贴背板 → 父子双背板叠加，只贴父框。
7. `System.lua:30-43` `StaticPopup1..4` 写死 → 遍历 `_G` 中 `^StaticPopup%d+$`。
8. `ActionBars.lua:315` `SetPoint` 失败被 pcall 静默吞 → 仿 Minimap 的一次性 `minimapWarned` 提示。
9. `Minimap.lua:61` 全局写入建议保存原值并在 `SetEnabled(false)` 还原（连同 mask/HitRectInsets 恢复——目前「关闭模块」只关背板）；手册查无 `GetMinimapShape`，本客户端可能已不读取它，实机可确认是否为死代码。
10. `Skins.lua:172-179` `M:Controls` 的 pcall 吞错无打印 → 失败 `ns:Print` 一次带控件名。

---

## 5. 合规亮点（建议保持）

- EventBus **懒注册 + pcall 兜底**，绝不盲注册固定列表，无 CLEU——是全项目的核心安全设计。
- `Secrets` 封装层（Number/Bool/Measure/SetBar/SetCooldown）覆盖面广，InfoBar 六块**全部**经 `Secrets.Number` 后才做算术，连击点 pip 直喂原值的做法很漂亮。
- 暴雪框架全部 `_G[name]` 守卫 + `ns.ResolvePath` + `/mui skins diagnose` 可诊断闭环。
- InfoBar `OpenPanel`（`_G` 查找 + 类型判断 + `InCombatLockdown` + pcall）是战斗安全范本。
- 按钮池/边框只建一次、皮肤开启走 `BeginRecord`/关闭走 `Rollback` 的回滚机制、`.toc` 分层清晰。
- 注释与文档质量高（Core.lua 的默认值注释、MonetUI.md）。

---

## 6. 游戏上线后的验证清单

1. 启动后 `/mui status` 应显示「已加载 N/N 个模块」；**不应**再出现 `Core.lua:556` 或 `Widget.lua:261` 的加载错误（§2.1 修复前必现）。
2. 游戏在线后请跑：`check`（`live=true`，实机核对 22 个未解析名字）→ `load` → `try`（看 ok/errors/blocked）→ `logs ERR,BLOCKED`。
3. `/mui skins diagnose` 确认 22 个暴雪框架在本客户端的实际存在性。
4. 观察日志中 `EventBus` 的红色 Report 行，确认 §3-E 的两个事件名。
5. 战斗中开关 BuffFrame / ActionBars，验证 §3-D 的延迟方案。
6. 战斗（受限状态）下确认血条数字、冷却显示不产生 "secret" 报错。

---

## 7. 本次变更记录

| 文件 | 变更 |
|---|---|
| `Utils/EventBus.lua` | P0 修复：pcall 求值顺序 + 内部 `MONETUI_*` 事件不再注册为 WoW 事件 |
| `Modules/ActionBars/ActionBars.lua` | P0 修复：`CreateLeaveVehicle` 的 pcall 返回值接取 |
| `docs/CODE-REVIEW-2026-10-15.md` | 本报告 |

git 状态：上述改动**未提交**（审查前工作树干净，基线 `614cecc`），便于用 `git diff` 复核后再提交。
P1/P2 各项均**只记录未改动**，等待确认后分批处理。
