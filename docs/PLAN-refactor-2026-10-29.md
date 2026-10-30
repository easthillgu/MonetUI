# MonetUI 重构计划（2026-10-29）

承接 `docs/REVIEW-2026-10-29.md`。本计划只定义阶段、顺序、每步的验收与回滚，不含实际改动。

## 原则（沿用项目约定）

- **一个修复点一个 commit**，中文标题写清"为什么"（HANDOFF 第 8 节）。
- **行为零变化的重构**（move-only、去死代码）与**行为变化的修复**分开提交，便于回滚。
- **先验证再删除**：删任何代码前必须全仓 grep 零引用 + 游戏内功能确认。
- **不 push**（上线前不推远端，见 TODO.md）。
- 每阶段结束跑完整闸门（见第 6 节），并 `node tools/sync-check.js`。
- 大文件拆分必须**机械核对**：删的行 = 新文件的行（去掉注释与调用点改名后）。

## 阶段总览

| 阶段 | 内容 | 性质 | 风险 | 需游戏 | 估时（粗） |
|---|---|---|---|---|---|
| P0 | 高优先级 bug 与违约修复 | 修复 | 低–中 | 部分 | 1–2 天 |
| P1 | 死代码与无效功能清理 | 删除 | 低–中 | 是 | 1 天 |
| P2 | 基础设施：Watch / 调度器 / Mark / Mult | 重构 | 中 | 是 | 2–3 天 |
| P3 | 配置面板拆分与 schema 单一来源 | 重构 | 中 | 是 | 3–4 天 |
| P4 | ActionBars 拆分与 `ns.AB` | 重构 | 高 | 是（必须） | 3–4 天 |
| P5 | 皮肤层声明式帧清单 | 重构 | 中 | 是 | 2–3 天 |
| P6 | 单位框 / 姓名板：性能修复、共享件、生命周期骨架、Groups 拆分、BossFrames | 重构 | 中–高 | 是 | 4–6 天 |
| P7 | 资产与依赖收尾（字体授权等） | 决策 | — | 否 | 视作者决定 |

P0 → P1 必须按序。P2 是 P3–P6 的前置（它们都用到统一的 Watch / Mark）。P4 与 P6 风险最高，放在基础设施稳定之后。

---

## P0 · 高优先级修复（先做，每条独立 commit）

| 步 | 条目（见 REVIEW H 号） | 做法 | 验收 |
|---|---|---|---|
| 0.1 | H1 堆叠数 | `ActionBars.lua:566-575`：`GetActionDisplayCount` 返回 string，改为非机密时直接 `SetText`，判断 `count ~= "" and count ~= "1"`；受限时保留原行为（空） | 游戏内：可堆叠物品/药水显示数字；战斗中不报错 |
| 0.2 | H2 三个开关 | 给 `showHotkey` / `showCount` / `showMacro` 接上读取点（`ActionBars` 的热键文字、堆叠文字、宏名 FontString 的 `Show/Hide`）；若决定不做则从面板删除 | 面板勾选后动作条立即变化 |
| 0.3 | H3 XP.lua Hide | `HideBlizzardXP`：改 `SetAlpha(0)` + `EnableMouse(false)`；用 `ns:Mark` 记原 alpha/鼠标；`ShowWatch` 只做 alpha 复位而非 Hide；`SetEnabled(false)` 还原 | 游戏内：经验条不闪烁；关模块后暴雪经验条回来；`taint.log` 无新增 |
| 0.4 | H5 Bags RestoreDragged | 前置声明 `local RestoreDragged`；`PollWatch` 回调触发一次后 `Unwatch`（先实现 P2.2 的注销，或此处临时用一次性标记）；`GUARD_INTERVAL` 0.05→0.2 | 拖动背包后位置正确；无 pcall 吞错；`UIParent` 上不再有常驻回调 |
| 0.5 | H12 Bags EnableMouse 守卫 | `Bags.lua:620/667` 加 `InCombatLockdown` 跳过，`PLAYER_REGEN_ENABLED` 补做（参考 QuestTracker.lua:363） | 战斗中无 BLOCKED 新增 |
| 0.6 | H13 Minimap Buttons Hide | `Buttons.lua:245-246` 改 alpha 0 + 关鼠标，`Restore` 还原；修 `:383` 的 `frame.monetBadge` 旧字段改为 `Marked` | 追踪按钮还原正常；徽章可被隐藏 |
| 0.7 | H4 Minimap OnMouseUp | 删 `minimap:SetScript("OnMouseUp")`（:640），把左右键分派放到 `blocker`（:552）的 OnMouseUp 里；`Restore` 不再需要还原脚本 | **实机**：左键 ping、右键菜单、中键；`Restore` 后一切回到暴雪默认 |
| 0.8 | H6 Color:186 | `if ok and v` → `Secrets.Bool(v, false)`；或直接删 `RoleTint`（无调用） | `audit-taint` 0 |
| 0.9 | H9 Mover.Rect | `GetEffectiveScale()` 结果经 `Secrets.Number`，机密时返回上次值 | `audit-taint` 0 |
| 0.10 | H10 Mover.ApplyOne | 受保护框走 `ns:AfterCombat` 排队 | 战斗中拖动小地图不报错 |
| 0.11 | H7 `/mui reset` | `wipe` 后立即 `MergeDefaults(db, DEFAULTS)`；加二次确认（`StaticPopup` 或 `/mui reset confirm`） | 重置后面板可开、所有模块状态正常 |
| 0.12 | H11 login 隔离 | `RefreshTheme("login")` 包 pcall，失败打印一次警告，`StartModules` 必须执行 | 人为注入错误时模块仍启动 |
| 0.13 | H15 EventBus 派发 | `Dispatch` 派发前复制回调列表；`Unregister` 只标记，派发后清理 | 单测或实机：派发中注销不跳过其他回调 |
| 0.14 | H8 复核 | 先核对 `Widget.lua` 全部 `HookScript`/`hooksecurefunc`（不只 OnSizeChanged），确认子代理报的 :923 是否存在 | 复核结论写入 REVIEW 文档 |
| 0.15 | BossFrames 阻断（H19） | `TargetUnit` 改为 SecureUnitButtonTemplate 或删除该文件（见 REVIEW 第七节第 2 条，需作者决定）；提交前 `wuxian check` 0 error | 0 error |
| 0.16 | Nameplates 红边闪灭（H16） | `Nameplates.lua:665` 改为 `Secrets.IsSecret` 判断：机密时保留 `plate.threatStatus`，非机密才更新（与同文件 :652 的 `isTarget` 写法一致）；非机密且 nil 时按 0 处理，不保留 | 战斗中红边不再闪灭；脱战后红边能正确消失 |
| 0.17 | BossFrames 样式导出（H18） | 在 `Groups.lua` 显式导出 `M.StyleButton = StyleButton`（以及 `NameCap`、`UpdateHealthText` 等 Boss 需要的件）；`BossFrames` 的 `StyleReady()` 改为显式检查这些导出 | Boss 框走完整皮肤（role / lost / incoming 出现，文字刷新） |
| 0.18 | IsShown 裸测（H22） | `Groups.lua:642、667、676、1124`、`BossFrames.lua:296、440`、`Nameplates.lua:691` 改为 `Secrets.Bool(f:IsShown(), false)` | `audit-taint` 0；无新增拦截 |
| 0.19 | 机密类型守卫（H23） | `Groups.lua:339-341` 的 `UnitClassBase` 先过 `IsSecret`，同 `UnitFrames.lua:466` 写法 | 无 `ClassColor` 报错 |
| 0.20 | Blizzard 压制取证（H20）—— **门禁，不直接改** | 开 `taintLog=2`，在"默认压制开 / 关"两种设置下各跑一次战斗进出，比对 `taint.log` 与 `ADDON_ACTION_BLOCKED` 计数。结论写入 REVIEW 第七节第 4 条，再决定是否进入 P6 的改造 | 有结论，不改代码 |

**P0 出口条件**：`api-audit` HARD=0、`audit-taint` BLOCKER=0、`wuxian check` 0 error、`sync-check` 0、实机过 0.1/0.2/0.3/0.4/0.7 五项。

---

## P1 · 死代码与无效功能清理

| 步 | 内容 | 前置验证 | 验收 |
|---|---|---|---|
| 1.1 | `Cooldown.lua` 312–373（`OnCooldownStart`、`OnSetHide…`、`EnsureHooks`、`externalHide`） | 全仓 grep 零引用 | 冷却圈正常 |
| 1.2 | `Cooldown.lua` 486–552（对自建按钮空转段，含 4 个事件与 `TINT`） | 确认自建按钮无 `.action` / `.Count` 字段；`RefreshAll` 无外部调用 | 冷却仍正常 |
| 1.3 | `BuffFrame.lua` `RebuildCombatAuras`（~449） | grep 零引用 | buff 显示正常 |
| 1.4 | `ActionBars.lua` `BuildButton` 的 `def.pet` 分支（717–751）与 `InstallDrag` 的 `isPet` | 确认 `CreateBar` 的 `if def.pet then return BuildPetBar` 先于它 | 宠物条、普通条施法正常 |
| 1.5 | `ActionBars.lua` ~1230–1534（ADOPT 旧路径，含 `ReleaseBar` 的 SetScale/EnableMouse） | **先**确认 `ADOPT_BLIZZARD_BARS=false` 与 `STYLE_ADOPTED_BARS=false` 在所有分支都保持 false；再查 `PetBar.lua:194` 之后的依赖分支；**删前在游戏里 `/reload` 验一遍宠物条 / 姿态条** | 宠物条、姿态条、普通 8 条全部可用；`/reload` 后无新增 BLOCKED |
| 1.6 | `ADOPT_EVENTS`（13 个事件）指向 no-op `AdoptAll` 的部分 | 同 1.5 | 无功能变化 |
| 1.7 | `luac.out`（仓库根）删除；`Trade.lua` 文件头重复、`Pins.lua` `HookPin`、`Buttons.lua:173` 的死 `SetHover`、`QuestTracker` 重复注册 | grep 零引用 | 无 |
| 1.8 | 注释修正：`Skins.lua:3`、`Utils/Skin.lua:4`、`ActionBars.lua:10/13`、`Core.lua:11` 版本号、`Core.lua:818` 格式串、`Media.lua:61-91` 错位文档 | — | 无 |

**P1 出口条件**：总删减约 500 行，闸门全绿，宠物条/姿态条/普通条实机过一遍。

---

## P2 · 基础设施（P3–P6 的前置）

### 2.1 统一 OnUpdate 调度器
- 新建 `Utils/Scheduler.lua`：一个共享驱动帧，按"任务 → 间隔 → 回调"登记，支持 `Schedule(key, interval, fn)` / `Cancel(key)`；内部用一个累加器按最小间隔分发。
- 迁移顺序（每处独立 commit）：`Widget.lua` 的 hover/show/poll 三驱动 → `Skin.lua` 的 tab/arrow/crop/scrollthumb → `Cooldown.lua` 驱动 → `ActionBars` 的 pageWatcher/petCD/parkDriver → `CombatText`/`Toast`/`XP`/`Tooltip` 的动画驱动（动画类保留逐帧，不迁）。
- **不迁**：`LibMonetColor-Anim`（库）、需要逐帧的 Cursor / Tooltip 跟随 / 施法条 / 经验线。
- 验收：`OnUpdate` 数量从约 52 降到个位数（逐帧类）；空闲时 CPU 占用可测（`/run print(GetTime())` 无关，用 `debugprofilestop` 对比）。

### 2.2 Watch 系统改造（`Utils/Widget.lua`）
- `HoverWatch`：同一框多回调（同 PollWatch 的改法）。
- 三个 Watch 增加 `Unwatch(frame, fn?)`；表改为 `setmetatable({}, {__mode="k"})`（弱键）。
- `PollWatch` 增加 `interval` 参数（默认 0.2）；回调内 `pcall` 失败改走 `EventBus` 报告一次（同一回调只报一次）。
- `Cooldown.lua:615` 超过 60 次后的 return 改为可注销。
- 验收：`Unwatch` 后回调不再触发；弱键下框体销毁后表项被回收（`collectgarbage("count")` 对比）。

### 2.3 `ns.Mark` / `Marked` 下沉
- 在 `Utils/Secrets.lua`（或新建 `Utils/Guard.lua`）导出 `Mark/Marked` 纯函数；`Core.lua` 只保留 `ns:Mark` 转发。
- 逐文件替换 `local Mark = function(o,k,v) return ns:Mark(o,k,v) end`（约 20 处），每批一个 commit。
- 验收：`grep "return ns:Mark"` 仅剩 Core 一处；Utils 不再依赖 Core。

### 2.4 Media:Mult 缓存
- `Media.lua:101-136`：缓存结果，在 `UI_SCALE_CHANGED` / `DISPLAY_SIZE_CHANGED` 时失效；去掉每次的 `pcall`，改为一次性探测。
- 验收：`test-mult.js` 仍通过（它校验公式与源码一致）；`Cursor` 逐帧路径耗时下降（可用 `debugprofilestop` 测）。

### 2.5 FitText / SetBorderState / 常量化
- `Widget.lua:376-416` `FitText`：闭包提到模块级；只在字号变化时 `SetFont`。
- `Widget.lua:523-571`、`:675-725`：`ipairs({...})` 与 `({tl=…})[key]` 提为文件级常量；`ROUND_SLICE` 与 `ROUND_EDGES.slice` 合并为单一来源。
- 验收：`test-skin-lua.js` 通过；圆角边框视觉不变（实机对照截图）。

### 2.6 Skin.lua 的表清理
- `Skin.tinters` / `Skin.added` 增加 `Release(frame)`；`OnTheme` 返回注销句柄；模块关闭时调用。
- `ScanScrollArrows`：只扫已知 ScrollBox，限次数，分帧；`ScrollArrowButton` 补 `Record` / `Track`，关 Skins 时还原。
- 验收：关 Skins 后滚动条箭头恢复暴雪原样。

### 2.7 EventBus 注册面
- `UnregisterEvent` 在最后一个回调注销时调用；`UnregisterAll` 同步退引擎注册。
- 单位事件与普通事件分表，禁止混用同名。
- 验收：`Unregister` 后 `GetFrameEvents`（若可用）或计数确认无残留。

---

## P3 · 配置面板拆分与单一来源

### 3.1 模块清单单一来源
- 新建 `Config/Modules.lua`：`MODULES = { {key, label, default, group}, ... }`，同时给面板与 `DEFAULTS.modules` / `MODULE_ORDER` 使用；补齐 Cursor、Toast、Durability、CombatText、BossFrames、GroupFrames。
- `IsModuleEnabled` 不再 `~= false` 兜底，改读 `MODULES`。
- 验收：面板开关与 DB 键一一对应；新装与老存档模块状态不变。

### 3.2 Bind 与路径校验
- 新建 `Config/Widgets.lua`：`Bind(path, { apply = fn })`，构建时断言 `path` 在 `DEFAULTS` 中存在，缺失则一次性 print。
- 将 7 种 getter/setter 统一为 `Bind`（逐组迁移，每组一个 commit）。
- 验收：故意改一个键名时，启动即出现一次警告。

### 3.3 `SimpleConfig:Build` 拆分
- 新建 `Config/Frame.lua`：面板外壳、`BeginSection/EndSection`（自动结算 `bodyHeight`，删掉手写的 `sec.bodyHeight = -row.y + 4`）、滚动条、`relayout`。
- 新建 `Config/Pages/*.lua`：主题、模块、冷却、小地图、单位框架、团队、首领、动作条、姓名板、美化、提示、通知、耐久、战斗文字、信息栏，每页一个文件，调用 `Config:AddPage{key, title, expanded, build(ctx)}`。
- 依赖模块存在的页（小地图、美化、信息栏）用 `when` 控制。
- 顺序：先 Widgets + Frame，再逐页迁移；**每迁一页删一段 `Build` 里的代码，并单独 commit**。
- 行为不变约束：文案、行高、默认展开、`row(h)` 数值完全不改。
- 验收：每页迁移前后截图对比（折叠态与展开态）；`ns:DB()` 快照前后一致（每个控件写入的键与值）；`/mui` 逐页展开操作无报错。

### 3.4 Toggle 刷新
- `MakeCheckbox` 加 refresher 列表（与 `dropdowns` 并列），打开面板时统一刷新。
- 验收：`/mui reset` 与别处改配置后，打开面板勾选正确。

### 3.5 迁移机制
- `Core.lua` 的 `Migrate` 改为有序表 `MIGRATIONS[n] = function(db) ... end`，`ns.Migrate(db, from, to)` 逐个 `pcall`，成功才写 `schema`；全新库直接写 `SCHEMA`，不跑迁移。
- 新建 `tools/test-migrate.js`：用老存档夹具（JSON）离线跑迁移，断言结果。
- 验收：test-migrate 通过；全新库与老库迁移后的 DB 与改造前一致（同一夹具比对）。

### 3.6 斜杠命令表
- `Core.lua:836-917` 的 `HandleSlash` if/elseif 链改为 `COMMANDS[name] = { fn, help }`，帮助文本自动生成。
- 验收：`/mui help` 输出与改造前一致（文本对比）。

---

## P4 · ActionBars 拆分（风险最高，最后做）

前置：P1 完成（死代码已删，文件已瘦身）；P2.1 完成（调度器可用于 pageWatcher / petCD / parkDriver）。

### 4.1 `ns.AB` 共享表替代 `M.xxx` 快照
- 主文件最先定义 `ns.AB = {}`，所有子文件通过 `local AB = ns.AB` 取用，**不在加载时快照 `M.xxx`**。
- 每个子文件的依赖通过 `AB.require("secure")` 显式获取；缺失时一次性报警（而不是静默 `if not M then return`）。
- 验收：xml 中调换一个 `<Script>` 顺序会立即报警。

### 4.2 按职责拆分（每步一个文件、一个 commit、机械核对）
| 步 | 新文件 | 来源行（当前） | 备注 |
|---|---|---|---|
| 4.2a | `ActionBars/Defs.lua` | 1–325 | 常量与 `BAR_DEFS`，纯数据 |
| 4.2b | `ActionBars/Refresh.lua` | 326–592 | `PaintCooldown`、`UpdateButtonContent`；加脏检查（P4.3） |
| 4.2c | `ActionBars/Button.lua` | 419–774 | `BuildButton`、`SkinButton` 的子件 |
| 4.2d | `ActionBars/Layout.lua` | 776–854 | `LayoutBar`、`PositionBar` |
| 4.2e | `ActionBars/Stance.lua` | 856–1069 | 姿态/收养皮肤（与 PetBar 的共享件走 `ns.AB`） |
| 4.2f | `ActionBars/Create.lua` | 1071–1228 | `CreateBar` |
| 4.2g | `ActionBars/Bindings.lua` | 1546–1584 | 键位 |
| 4.2h | `ActionBars/Events.lua` | 1586–1896 | 事件与 `Apply` |

机械核对：`git diff -U0` 删除的语句必须全部在新增里复现，只允许调用点改名与注释指路。

### 4.3 脏检查与热路径
- `UpdateButtonContent`：缓存上次 texture / count / text / usable，不变则不写；跳过未显示的条。
- `CooldownsSecret()` 提到循环外。
- `RefreshRings` 只在主题变更时执行（监听 `MONETUI_THEME_CHANGED`）。
- 删除 `ACTIONBAR_UPDATE_USABLE` / `SPELLS_CHANGED` 的重复登记（H14）。
- 删除自建对象上的 pcall（4.4 节）。

### 4.4 去掉热路径上对自建对象的 pcall
- `ActionBars.lua:557-587`、`391-402`、`443-447`：自建 FontString/Texture 的 SetText/Show/Hide 直接调用。
- `BuffFrame.lua:368`：`initializeFrame` 的整段大 pcall 拆为"必需件先注册、装饰件各自 pcall"（AGENTS 的 ArcAuras 纪律）。
- 验收：`grep pcall` 在 ActionBars 下降；实机无新增报错。

### 4.5 P4 实机回归（必做，全部勾完才算收口）
- 1–8 号条施法、翻页（载具/潜行/形态）、拖放（接住器）、键位显示。
- 宠物条：自动施法环、冷却转圈、8–10 格空槽底色、悬停显隐。
- 姿态条：三形态点击、悬停显隐、`/reload` 后位置不变。
- 进出战斗、进出编辑模式、`/reload` 后无新增 BLOCKED（对比 taint.log）。

---

## P5 · 皮肤层声明式帧清单

- 设计：`M:Panel(key, { controls = { buttons = {...}, tabs = {...}, scrolls = {...} } })`，帧名只写一次。
- `Diagnose` 从 `controls` 自动生成清单（替代手写 `frames={}`）。
- 迁移顺序：`Trade.lua`（重复最多，先做）→ `Social.lua` → `Collections.lua` → `Quest.lua` → `System.lua` → `Skins.lua` 其余。每个文件一个 commit。
- 同时修：`Social.lua:33-41` 逐子帧 `HookShow` 改为一次登记；`Quest.lua` 的 `BrightenTree` 加 pcall；`Quest.lua:206` 的模块判断改为运行时读取。
- 验收：每个皮肤文件迁移后，`/mui skins diagnose` 输出的帧清单与迁移前一致（文本对比）；`test-skin-lua.js` 通过。

---

## P6 · 单位框 / 姓名板共享件

前置：REVIEW 4.8 节的补做审查已完成。P0.16、0.17、0.18 必须先落地（它们是 P6 的正确性前提）。

### 6.1 性能（先做，风险低）
- **H17**：`Groups.lua:1229-1233` 的 10 个 `UNIT_*` 改 `EventBus:RegisterUnit(event, unit, cb)`。注意 Groups 是**按组员单位**分发的，需要为每个 `partyN/raidN` 登记，或保留全局注册但在 `UpdateUnit` 入口先查 `byUnit` 做早退（后者改动更小，先用它）。
- `Groups.lua:678-684`：`UpdateState` 与 `UpdateHealthText` 共享一次 `UnitIsDeadOrGhost / UnitIsConnected / UnitHealthMax` 结果，由调用方传入。
- `Groups.lua:989-1000`：每秒递归遍历 4 棵树的 ticker 改为"只在组员变化时跑一次"，或改用 `ns.Scheduler`（P2.1）。
- `BossFrames.lua:437`：`UNIT_TARGET` 改 `PLAYER_TARGET_CHANGED`（语义同样是"目标变了"，且不再全局触发）。
- `Nameplates.lua:851`：每块牌子 17 次 `RegisterUnitEvent` 收拢成一个分发表；`:691 / :746` 的 `KeepBlizzardHidden` 去掉事件与 0.25 秒守卫的重复调用。
- 验收：`debugprofilestop` 对比团队满员时单次 UNIT_HEALTH 的耗时；实机无错误。

### 6.2 共享件抽取
- `Secrets.SetUnitBar(bar, unit, kind, smooth)`：统一血条 / 能量条写入与"无能量则隐藏"（`UnitFrames` 513/549/554、`Groups` 367/381/384、`BossFrames` 84/88、`Nameplates` 565）。
- `UnitStatus(unit)`：一次求值死亡 / 离线 / 幽灵（`Groups` 423–435 与 505–513、`UnitFrames` 270、`Nameplates` 573）。
- `InRangeAlpha(frame, unit)`：距离淡出（`Groups` 571–596 与 `BossFrames` 145–153）。
- `NameStyle(unit)`：名字三档（`UnitFrames` 426–483、`Groups` 388–399、`BossFrames` 101–110、`Nameplates` 626–638）。
- `ThreatColor(status)`：仇恨颜色（`UnitFrames` 627–650、`Nameplates` 663–682）。
- `Widget:LostBarBG(bar)`（三处血条背景）、`Widget:TintIconBorder(btn)`（光环边框重涂）、四边 1px 边框构建器（合并 `Groups.lua:83-103` 与 `:131-152`）、`Math:Shorten`（名字截断，合并 `Groups.lua:68-78` 与 `UnitFrames.lua:56-58`）。
- 验收：每抽一个件一个 commit；抽取前后截图对比。

### 6.3 生命周期骨架
- `RegisterEvents / Apply / SetEnabled / InCombat` 四处的共同骨架（`Groups` 1215–1293、`BossFrames` 384–466、`UnitFrames` 966–1063、`Nameplates` 878–1010）抽成 `ns:UnitModuleBase(M, spec)`，各模块只声明事件表与刷新函数。
- 定时器四处（`Groups` 989 / 1119、`BossFrames` 293、`Nameplates` 705）统一到 P2.1 的调度器。
- 验收：四个模块的 `SetEnabled(false)` 还原行为逐项对照。

### 6.4 文件拆分
- `Groups.lua`（主 chunk 95 个局部）按边界拆：`GroupStyle`（80–335）、`GroupUpdate`（338–660）、`Headers`（700–780）、`BlizzardSuppress`（782–1001，依赖最少，**先拆**）、`Module`（1003–1295）。拆法同 P4：`ns.Group` 共享表，机械核对。
- `UnitFrames.lua`、`Nameplates.lua` 局部变量数 63 / 59，等 6.2 抽取后再评估。

### 6.5 BossFrames
- 点击改 SecureUnitButtonTemplate（H19，已在 P0.15 处理，或由 6.5 完成）；删掉 `ToggleDropDownMenu`（右键菜单改由 `SecureUnitButtonTemplate` 的 `unit` 属性交给暴雪）。
- 恢复路径：`hideBlizzard=false` 时调用 `UnparkBoss`（对应 Groups 的 `UnparkGroup`，H21）。
- 重建时复用旧帧或销毁后清理 Mover 条目，防止泄漏（H21）。
- 验收：Boss 战中点击选中、右键菜单、关闭压制后暴雪 Boss 框恢复。

### 6.6 Blizzard 压制（依赖 P0.20 取证结论）
- 若取证显示 `OnShow + Hide` 必须保留：在 REVIEW 中标注"有意例外"，不改代码。
- 若可以改：改为 alpha 0 + `EnableMouse(false)`，压制状态用 `Mark` 记录，`SetEnabled(false)` 还原；`HideBlizzardCastBars` 同样处理。
- 验收：`taint.log` 对比 P0.20 的基线，`ADDON_ACTION_BLOCKED` 计数不高于基线。

---

## P7 · 资产与依赖（作者决策）

- **Blizzard 压制方式**（REVIEW 第七节第 4 条，依赖 P0.20 取证）：保留 OnShow + Hide（标注为有意例外），还是改为 alpha 0。
- **Pingfangpixel.ttf**（29 MB，授权不明）：三选一 ① 获取授权后保留；② 替换为有授权的小字号字体（如 fusion-pixel-12，已在仓库且 OFL）；③ 删除，<12px 统一用 WenKai + AA。需作者拍板。
- **LXGWWenKai-Regular.ttf**（24.7 MB）：OFL，保留；可考虑子集化（只保留 GB2312 常用字）以减小体积，需确认覆盖率。
- `Media.font.pixel` 的历史别名 `pingfang` 与 `pixel` 指向同一文件，可在 P2 的 Media 清理中合并。
- `tools/` 目录的门禁脚本：考虑把 `api-audit`、`audit-taint`、`sync-check` 的关键检查挪进仓库可提交的位置（或在 `.gitignore` 里为其开白名单），否则换机即丢失。需作者决定。

---

## 六、验证闸门（每阶段出口统一执行）

| 闸门 | 命令 | 通过标准 |
|---|---|---|
| API 审计 | `node tools/api-audit.js` | HARD = 0 |
| Taint 审计 | `node tools/audit-taint.js` | BLOCKER = 0，HIGH 人工复核 |
| 皮肤静态测试 | `node tools/test-skin-lua.js` | 全部通过 |
| 乘数测试 | `node tools/test-mult.js` | 全部通过 |
| 迁移测试（P3 起） | `node tools/test-migrate.js` | 全部通过 |
| 像素审计（动素材时） | `node tools/audit-pixels.js` | 0 未通过 |
| 客户端静态检查 | `wuxian check(live:false)` | 0 error；warning 不新增（基线 5） |
| 部署 | `powershell -File tools/deploy-retail.ps1` | 成功 |
| 同步校验 | `node tools/sync-check.js` | 退出码 0 |
| 实机 | `/console scriptErrors 1` → `/reload` → 读 `taint.log` 与 `ADDON_ACTION_BLOCKED` | 无新增；逐项过 HANDOFF 6.3 清单 |

## 七、回滚策略

- 每个步骤一个 commit，`git revert <sha>` 即可回滚，不跨步骤打包。
- P4 每个子文件拆分前打 tag（如 `pre-ab-split`），拆坏可整体回到 tag。
- 删除类 commit（P1）单独成批，便于一次性回退。
- 实机出现新 BLOCKED 时，先 `git bisect` 在本计划的 commit 之间二分，不要凭记忆猜。

## 八、进度追踪

建议在 `TODO.md` 新增 "重构计划 2026-10-29" 一节，把每个步骤号（如 0.4、P1.5）作为勾选项，完成后补 commit sha。本计划本身不进库（`docs/` 被忽略，`docs/PLAN-refactor*.md` 需要时加入白名单）。
