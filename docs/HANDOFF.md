# MonetUI 交接文档（换开发平台用）

> 写于 2026-10-24 22:30，跟着 `36b7280` 这个提交；**2026-10-25 追加了"拦截族 + 战斗中 buff"这一轮的收档（见第 3.5 节）**。
> 读者：接手这个仓库的 AI agent（Codex）或未来的自己。
> 先读顺序：**本文件 → `AGENTS.md`（硬规则）→ `TODO.md`（待办）→ `MonetUI.md`（设计/决策，147KB，别整篇塞进上下文，按标题查）**。

---

## 0. 一分钟接上

| 事 | 值 |
|---|---|
| 仓库 | `C:\Users\EastHillGu\Documents\wowaddonsdev\MonetUI`（2026-10-26 转正：原 `MonetUI-refactor` 改名为 `MonetUI`，旧版封存在 `MonetUI-archive`） |
| 游戏 | `C:\Users\EastHillGu\Documents\Blizzards\World of Warcraft\_retail_\Wow.exe`（客户端 12.1.5.70575） |
| 插件安装目录 | `...\_retail_\Interface\AddOns\MonetUI`（由 `tools/deploy-retail.ps1` 从仓库拷过去） |
| 客户端日志 | `...\_retail_\Logs\`（`taint.log` 是污染日志，`EditMode.log` 是编辑模式布局的二进制转储） |
| 版本 | `MonetUI.toc` 0.12.0，`## Interface: 16001`（部署脚本会按客户端改写） |
| 当前 HEAD | `36b7280`（2026-10-24 22:17），比 `origin/main` 领先 48 个提交 |
| 远端 | `origin` = github.com/easthillgu/MonetUI，**私有备份**。**在游戏上线并通过初步测试之前一律不 push**（作者定的，见 `TODO.md` 末尾） |
| 参考插件（只读） | `../Andromeda`、`../EllesmereUI-v9.4`（Ellesmere 是**这个客户端**的实机皮肤代码，优先级最高） |

改完一轮的标准动作：

```
node tools/api-audit.js          # 撞 docs/api 快照（HARD 项退出码 1）
node tools/audit-taint.js        # 秘值/taint 机械闸门（BLOCKER≠0 退出码 1；HIGH=人工复核清单）
powershell -File tools/deploy-retail.ps1
node tools/sync-check.js         # 仓库 vs 已安装副本（退出码 0 = 游戏加载的就是这份代码）
# 游戏内 /reload（有 wuxian MCP 时用 tools.wuxian.reload）
```

> **`node tools/sync-check.js`（2026-10-26 新增）**：逐文件 MD5 比对仓库与
> `Interface/AddOns/MonetUI`，分三类报 —— MISSING（新文件没部署，客户端根本不会加载）/
> STALE（改过没部署）/ EXTRA（旧部署残留）。**"改了但游戏里看不到"这类事故先跑它**，
> 比翻日志快。toc 的 `## Interface` 由部署脚本改写，比对时已排除。

> **`wuxian check` 的路径陷阱（2026-10-26 记）**：`check({target="MonetUI"})` 查的是**游戏里的
> 已安装副本**（`Interface/AddOns/MonetUI`），不是仓库。想在校验**当前源码**（部署之前）就把
> `target` 写成仓库绝对路径（`...\MonetUI`），否则审的是上一版。按 addon 名跑时
> 还会多一条 `toc-interface`（部署脚本会改 `## Interface`），那不是缺陷。

`wuxian check`（有 MCP 时）等价于"客户端侧的语法 + 未解析名字 + 受保护调用"体检，**0 error 才算改完**；`api-audit.js` 离线也能跑，是它拦住了大部分"名字写错/事件名不存在"的错；`audit-taint.js` 是 2026-10-25 新增的**commit 前 taint 自查**（规则 = `.opencode/skills/wow-secret-value-taint-audit/SKILL.md`，已审行用 `-- TAINT-OK: <原因>` 行内豁免，两边规则变更要同步）。

---

## 1. 项目是什么

给 **魔兽世界无限（WoW Forever / 本仓客户端 12.1.5）** 做的一套莫奈风格整合 UI：

- 配色由当前区域环境色实时推导（`Libs/LibMonetColor-1.0`，缺失时优雅降级）；
- 全部 UI 自绘（材质走 `tools/regen-textures.js` / GIMP / SVG，不引外部贴图、不引第三方库，避免 GPL 污染）；
- 模块化：`Modules/*` 每个模块可单独开关，关掉**完整还原**暴雪原样；
- 每个数值都要过 `Utils/Secrets.lua`（这个客户端会把很多值标成"机密值"，直接算术/比较会抛错）。

模块清单见 `README.md`；模块的结构性说明见 `MonetUI.md` 第五节。

---

## 2. 当前状态（做到哪了）

**总体**：15 个模块全部实装、默认开启。**2026-10-26 这一轮的功能改动已实机验收通过**（见 3.24），
剩下的活是排错型（污染 / 已知小问题），不是加功能阶段。这一阶段的主要敌人是**污染（taint）**，见第 4 节。

| 模块 | 状态 | 备注 |
|---|---|---|
| Core / Config | 可用 | 模块注册、主题管线、`/mui` 命令、滚轮配置面板 |
| UnitFrames / GroupFrames | 可用 | 单位框、小队/团队框（**暴雪的团队/小队框我们已完全不再碰**，要藏请玩家在编辑模式里设"可见性=隐藏"）；施法条是一张**三角火花贴图**，顶端精确顶在能量条下沿（见 3.14/3.15） |
| ActionBars | 可用 | 1–8 号自绘安全按钮 + **收养**暴雪 `PetActionButton1..10`（宠物条）与 `StanceButton1..10`（姿态条）；冷却/拖放/翻页实测通过 |
| Cooldown | 可用 | 只处理**我们自己的**冷却框；暴雪的「冷却管理器」4 块 HUD 帧被它收掉 |
| BuffFrame | 可用 | 自绘 buff/proc/debuff 三行；战斗中切到引擎 `AuraContainer` 兜底 |
| Minimap | 可用 | 矩形遮罩 + 面板 + 三个集群按钮；**集群不动，只搬 `Minimap` 帧**（见 3.1） |
| QuestTracker | 可用 | 自绘追踪框 + 压制暴雪追踪框（alpha 0） |
| Nameplates | 可用（实机验收 2026-10-26） | 细条血条 / 施法条 / **不显示光环**；**当前目标是金色边 + 1.1 倍**（见 3.12） |
| Bags | 可用（实机验收 2026-10-26） | 分类背包；**连按 B 不会再冒出暴雪背包**（见 3.21/3.22） |
| InfoBar | 可用（实机验收 2026-10-26） | 底边经验线 + 三角标记（尖端顶在线的上沿，见 3.15） |
| Tooltip | 可用（实机验收 2026-10-26） | 三摆法（跟随 / 小地图右上角 / 暴雪默认）、1px 主题边、边缘翻转、Alt 常显 ID；见 3.13/3.18/3.19 |
| Cursor / Toast / Durability | 可用 | 纯装饰 / 提示类，实机过过一遍 |
| CombatText（战斗辅助） | 可用（实机验 2026-10-27） | 默认用暴雪数字；进出战斗剑+盾提示已验；**区域偏移功能已撤销**（涉及机密值，见 3.25） |
| ~~BagFrame（旧排列式背包）~~ | **已于 2026-10-26 移除** | 两套背包只留 `Bags`（见 3.21） |
| Skins | 可用 | 暴雪窗口美化；**只做窗口装饰，不碰里面的按钮/页签脚本** |

---

## 3. 这一轮（2026-10-24）修了什么

一句话：**把"进编辑模式必报 `oldR`、姓名板成片报机密值、HUD 出现重复物"这一串，从根上按"污染链"全部拔掉了。**

### 3.1 编辑模式 `oldR` 报错（最贵的一条）

症状（进**和**退编辑模式都报，二分关模块也查不出来）：

```
CompactUnitFrame.lua:699: attempt to compare local 'oldR'
  (a secret number value, while execution tainted by 'MonetUI')
  → RefreshPartyFrames / EditModeFrameSetup
```

真正原因：`Modules/Minimap/Minimap.lua` 里有一段 `MarkClusterMoved()`，覆写了

```lua
MinimapCluster.IsInDefaultPosition = function() return false end
```

它存在的理由是**正当的**：我们把 `MinimapCluster` 搬到屏幕右下角后，编辑模式算右侧动作条缩放上限
`GetRightActionBarTopLimit = MinimapCluster:IsInDefaultPosition() and (MinimapCluster:GetBottom()-10) or UIParent:GetTop()`
会算出负数（实测 availableSpace = -101.5 → `MultiBarRight:SetScale(-0.18)` 报错）。

但**覆写方法 = 把这个方法槽写成 MonetUI 的东西**，于是 `EnterEditMode → EditModeFrameSetup` 整条
调用栈都被记成"以 MonetUI 的名义执行"，暴雪自己接着在 `RefreshPartyFrames` 里比较机密血量颜色就炸了。

**正解（`e099cc4`）**：集群一个字节都不动（位置/尺寸/方法），只把 `Minimap` 这个**帧本身**搬进我们的
`MonetUIMinimapHolder`，摆到右下角；矩形遮罩/面板/覆盖层/三个按钮都挂在 `Minimap` 上，行为不变。
编辑模式看到的永远是暴雪默认布局，不需要我们提供任何答案。这是 Ellesmere 在本客户端的做法。

> 结论（已写进 `AGENTS.md`）：**绝不覆写暴雪的方法去"骗"编辑模式**；凡是编辑模式会读的值/方法，
> 数据也不能替玩家写（`systemInfo.isInDefaultPosition` 同样是脏值）。

### 3.2 姓名板成片报机密值（`c09867e`）

```
CompactUnitFrame.lua:1211  compare 'maxHealth' (secret, tainted by 'MonetUI')
CompactUnitFrame.lua:668   index a table that cannot be indexed with secret keys
CastingBarFrame.lua:344    boolean test on 'notInterruptible' (secret)
NamePlateAuras.lua:366     boolean test on 'isFullUpdate' (secret)
```

原因：`hooksecurefunc(NamePlateDriverFrame, "UpdateNamePlateOptions", ...)` —— 全仓最后一处
"给暴雪方法槽挂我们函数"。**驱动框一脏，它建出来的每一块姓名板都脏**。改成轮询
`C_NamePlate.GetNamePlateSize()`（2 秒限一次）。修完 10 分钟 0 报错、`taint.log` 全空。

> 口诀：**只要那东西是暴雪用来"生产"其它帧的（驱动 / 池 / 管理器），碰它一次，产物全脏。**

### 3.3 其他污染源（同批）

| 提交 | 内容 |
|---|---|
| `af05939` | 皮肤引擎里 `hooksecurefunc(PanelTemplates_SelectTab/DeselectTab)` → 改轮询页签选中态 |
| `99009c3` `0ba783a` `34a6efb` | 暴雪小队/团队框：先去字段/HookScript，再去 `Hide()`，最后**完全放手**（任何接触都会让成员框的机密值比较炸） |
| `f91ade1` | 最后一批脚本钩子（下拉菜单 / 提示框 / 小地图配置 / pin / 小地图按钮）→ 全轮询 |

### 3.4 HUD 重复物（`6db19dc` `ef0158c` `0ff4a4a`）

| 症状 | 真身 | 处理 |
|---|---|---|
| 玩家框下方一排带冷却的图标 | 暴雪 12.x 的「冷却管理器」：`EssentialCooldownViewer` / `UtilityCooldownViewer` / `BuffIconCooldownViewer` / `BuffBarCooldownViewer`（`Blizzard_CooldownViewer`，LoD） | Cooldown 模块里收掉（轮询等包加载 + ShowWatch） |
| 自绘任务追踪旁边还有一块「所有目标」 | `ObjectiveTrackerFrame`（LoD 包 `Blizzard_ObjectiveTracker`） | 多重时机压制；**alpha 0 + 关鼠标**，不要 `Hide()`（会和它自己的 `Show()` 打架 → 一闪一闪） |

顺带修了 `Widget:PollWatch` 的一个底层坑：它原本**一个框体只能挂一个回调**，而四个模块都拿
`UIParent` 当锚点（`Skins/System`、`Nameplates`、`Cooldown`、`QuestTracker`）—— 后注册的把先注册的
**静默顶掉**。现在同一框体支持多回调。

### 3.5 Buff / Debuff（`36b7280`）

| 症状 | 原因 | 修法 |
|---|---|---|
| 图标上的时间像"加密字符" | `Cooldown:GetCooldownTimes()` 给**毫秒**，`GetTime()` 是**秒**；`start+duration` 直接减出 ≈568 天，再套颜色码，在 8px 下就是乱码 | `/1000`，并加"剩余 > 30 天就当读不到"的保险 |
| debuff 明明在、屏幕上看不见 | debuff 行锚在 proc 行下面，而 proc 行空时被压成 `0×0` 且隐藏 → `GetLeft()` 返回 nil，整行没有矩形 | debuff 行按**实际行高累加**自己算落点 |
| 暴雪 BuffFrame/DebuffFrame | 原来写 `OnShow` 脚本槽 + `UnregisterAllEvents`（污染 + 打架） | 改 `SetAlpha(0)` + `EnableMouse(false)` |

---

## 3.5 2026-10-25 这一轮：拦截族收档 + 战斗中 buff 空白

一句话：**`ADDON_ACTION_BLOCKED UNKNOWN()` 不是一类东西，是两类；两类都已拔掉，且"战斗中玩家 buff 空白"与其中一类同源。**

### 3.5.1 族 A —— 对机密值做布尔测试（taint.log 有栈，可读）
`taintLog=2` 抓到的 2.6MB / 6465 条里 99% 发源 `Groups.lua:520/521 UpdateRange`（← `:882` 高频驱动），
其余零星 `UpdateState` :379/380、`UpdateHealthText` :448/449、`SyncSelection` :580（`UnitIsUnit` 机密）、
`UnitFrames UpdateCast`（`notInterruptible`）。

**修法（模式固定，本仓以后统一这么做）**：真值测试之前先做**值级** `Secrets.IsSecret`；
`issecretvalue` 读取本身不触发拦截，只有对机密值做 `if v then` 才炸。机密时**直接落回
"被拦后回退默认"的逐位一致分支**，行为零变化。

### 3.5.2 族 B —— 自建引擎 AuraContainer 的渲染驱动（taint.log 0 条，双盲）
我们 `CreateFrame("AuraContainer", ...)` 造的战斗容器，一 Show 引擎就在"MonetUI 的污染上下文"里
逐个按钮被拦；条数量级与按钮批次吻合（×2/×15/×29）。它**不写 taint.log**（旗子开着实测 0 字节），
也不经过 `Secrets.Bool` —— 所以只能靠 `Secrets.BoolBlocks()` 自证账本 + 开关式二分来判。

**修法**：整条路线停用（实现已删，判例写在 `BuffFrame.lua` 文件头注释，git 历史可回滚）。

### 3.5.3 战斗中玩家 buff 空白（玩家可见的 bug）
引擎容器两条死路都试过：换肤 → 战斗中**新 proc 只有鼠标提示、没有图标**（引擎不能往插件替换过的
图标/冷却对象写新光环）；不换肤 → 连已有光环都不画（该模板按钮离开 `initializeFrame` 就没图标）。
另外容器创建后立刻 `Hide()`，引擎的刷新驱动从未跑过，单靠 `Show()` 不会补。

**修法（当前实现）**：战斗中把**暴雪原生** `BuffFrame / DebuffFrame / TempEnchantFrame` 的 alpha
拉回 1（`SuppressBlizzard` 按 `combatMode` 切 0/1），客户端自己画自己更新，proc 即时上屏；
脱战 alpha 归 0，自绘行回来。**实机验收：脱战自绘、战斗中可见、proc 即时、0 拦截。**

**为什么"战斗中套我们自己的皮肤"曾经做不到（2026-10-25 一期结论，二期已绕开）**：
`C_UnitAuras.GetAuraDataByIndex` 在战斗中对我们整个插件抛
`Auras cannot be accessed when secret while tainted by 'MonetUI'` —— **硬禁读**，不是"字段加密"。
所以自绘网格没有数据源；但**引擎 AuraContainer 的按钮**仍可由客户端灌机密数据，
插件只需要在 `initializeFrame` 里把"接数据的对象"（图标纹理 / 冷却 / 层数字体）交给引擎。

**二期做法（ArcAuras 纪律，2026-10-25）**：战斗显示回到引擎容器 + 我们的皮肤。
- 容器在登录/脱战时建好并 `SetEnabled(true)`；脱战隐藏，进战斗 Show（Show 合法，已实测）；
- `StyleAuraButton` 改成**必需件先注册**（SetIcon / SetDurationCooldown / SetApplicationCount），
  装饰件（边框 / 时长文本 / 染色）排在注册之后、各自 pcall —— 任何装饰失败都不再连累图标
  （一期"战斗中新 proc 只有提示没有图标"的真因就是旧顺序里任一文本建不出就 `return`）；
- 机密期不建颜色曲线（`C_CurveUtil` 会被拒），退回冷却自带数字；
- 引擎容器建不出来时自动退回暴雪原生框（alpha 1）兜底。

### 3.5.5 主题切换不要重建容器（2026-10-25 下午判例）
症状：换主题后进战斗，`ADDON_ACTION_BLOCKED UNKNOWN()` 一直冒（×11 一次、整场不停），
**只有 `/reload` 能清**。

原因：换主题曾经靠"重建容器"来换边框色。但帧销毁不了——旧容器只是被 `Hide`，仍
`SetEnabled(true)` 由引擎驱动；它的按钮被我们的 `initializeFrame` 碰过，于是战斗中引擎每次
写它们都被记成 MonetUI → 连环拦截。

现做法：**主题切换不重建容器**（颜色保持创建时那一套，`/reload` 后跟新主题）；
**战斗中绝不创建容器**（创建会得到空容器且产生拦截），只在脱战补建。

### 3.5.4 顺带的
- `Utils/Secrets.lua` 增 `Secrets.BoolBlocks()`：`Bool()` 失败路径自记 `debugstack`（200 条、重载清零）。
  **诊断这类拦截只认它**，别再等 taint.log。
- `QuestTracker` 的压制动作（alpha / 鼠标 / 子树静音）统一加战斗闸，脱战 1 秒 ticker 补做——
  战斗中碰追踪框子树会被拦（×29 形态）。
- **仍开着**：暴雪小队/团队框与自绘框重复——编辑模式关可见性保存、重载后仍显示，判为 16001
  客户端 EditMode 可见性接线断；三条选项（共存 / 关自绘 / 带风险自动藏）待作者拍板。

---

## 3.6 2026-10-26：P4 长函数拆分收尾（纯重构，行为零变化）

一句话：**review 开出来的 8 个长函数全部拆完**，每个函数一个 commit，ActionBars 与 UnitFrames
里那些 100+ 行的"装配 + 事件 + 写属性"混在一起的块，现在都能一眼看出责任边界。

| 函数 | 行数 | 抽出的子件 |
|---|---|---|
| `ActionBars.BuildButton` | 126 → 62 | `EnsureFlyoutMixin`（托盘接口）、`EnsureButtonTooltip`（HoverWatch 提示） |
| `ActionBars.SkinButton` | 79 → 11 | `BuildButtonIcon` / `Fonts` / `Cooldown` / `Feedback` |
| `ActionBars.AdoptBar` | 100 → 63 | `EnsureAdoptedEntry`（记忆化记录）、`AdoptScaleBase`、`WriteAdoptLayout`（受保护写） |
| `ActionBars.CreateBar` | 123 → 71 | `BuildPetBar`（整段宠物条收养）＋删掉一段**永远走不到**的自绘宠物条分支 |
| `UnitFrames.CreateUnitFrame` | 137 → 48 | `BuildUnitBars` / `BuildUnitTexts` / `FinishUnitFrame` |
| `UnitFrames.StyleAuraButton` | 159 → 52 | `EnsureAuraBorder` / `Icon` / `Cooldown` / `Texts`（此前已拆） |
| `Groups.StyleButton` | ~130 → 14 | `StyleHealthBars` / `Overlay` / `PowerBar` / `Texts` / `RoleIcon`（`48224d4`） |
| `Nameplates.DressDebuffButton` | ~128 | `Build` / `Reapply`（`001a49f`） |

**这轮的唯一"非 move-only"**：`CreateBar` 里第二个 `if def.pet then` 是死代码 —— 函数开头
`if def.pet then return BuildPetBar(...) end` 已无条件返回，那段"自绘 `type="pet"` 安全按钮"
（收养方案之前的老路）永远不会执行，已删净（`8b43996`）。

**新增的验收手法（可复用）**：拆完用 diff 做机械核对 —— 把 `git diff -U0` 的增删行去掉注释
与函数头后比对，**新增语句只应是那几条调用，删除语句必须全部在新增里复现**。这次
`CreateUnitFrame` 的核对结果就是"ONLY ADDED: 3 个调用 / ONLY DELETED: 空"。

**待实机回归**（本轮改的是动作条与单位框的创建路径，登录时就会跑）：
动作条 1–8 施法/翻页/拖放、宠物条收养 + 自动施法环、单位框（玩家/目标/目标的目标/焦点）
血条与文本位置、进出编辑模式、`/reload` 后无新增 BLOCKED。

---

## 3.7 2026-10-26：昨天的改动"没生效" —— 一次**错误归因**与更正

作者报"昨天的修改似乎没有读取到"。我先用 `wuxian history` 查到"最后保留的版本 v23 = 10-25 16:11、
里面没有 `Auras.lua` / `CastBar.lua`"，当场写下"16:11 之后的 8 个提交从未部署"。
**这条结论是错的，已作废**（`e66a4e5` 里写的那段不要再用）。

为什么错：`wuxian history` 的版本**只由热装载（`load` / `checkpoint`）产生**，普通的
`deploy-retail.ps1` + `/reload` 根本不建版本。拿"没有新版本"推"没有部署"，是把缺证据当反证。

2026-10-26 复核出来的真事实（三条都能重跑）：

| 事实 | 取法 | 意义 |
|---|---|---|
| 昨天 `deploy-retail.ps1` 跑了 60+ 次，最后一次 **21:15:13** | 昨天会话导出的 shell 调用时间戳 | 最后一个提交 21:17:35 只是把 21:15 已部署的工作树内容记录进 git，没有遗漏 |
| 客户端整晚**没重启**：`Logs/General.log` 是一段连续时间轴 **10-25 15:42:29 → 21:18:56**（0 次时间回退） | 该日志每次启动重写 | 15:42 之后的一切改动全靠 `/reload` 生效 |
| **新增文件确实被加载**：`CastBar.lua`（18:48 新建）漏声明 `Shared` 导致 `CreateCastBar` 第 48 行 nil，实机在 18:54 以"头像模块失效"报出来 | 用户 18:54 反馈；那一行在 `CastBar.lua` 内部 | 本客户端 `/reload` **会**重读 `.toc` 并加载新增文件（"新文件必须整启动"只对 wuxian `load` 成立） |

所以"改了看不到"这次**不是**部署链的问题，要继续查就必须落到**具体哪一项行为**上，再沿那条链取证。

仍然保留的防呆：`node tools/sync-check.js` —— 逐文件 MD5 比对仓库 ↔ 已安装副本，分
MISSING（新文件没部署）/ STALE（改过没部署）/ EXTRA（旧部署残留）三类，不同步退出码 1；
**commit 后、开游戏前各跑一次**。本次跑它顺手清掉了游戏目录里 25 个 `Assets/Textures.bak/*.tga`
残留（仓库已无这些文件、游戏不引用）。

---

## 3.8 2026-10-26：姿态条不见了（`8d4ab87`）

**现象**：德鲁伊 21 级实机，形态条（熊/猫/旅行…）整条看不见，也点不到。

**取证**（`wuxian run` 探针）：`NumShapeshiftForms=3`；`StanceBar` `shown=true` /
`mouse=true` / **`alpha=0`** / `Marked(parked)=true`；三个 `StanceButton` 与容器都在
（30×30，785..849 ×95），`GetAlpha()=1` —— 数据、布局、按钮全好好的，只是外壳被压透明。

**根因**：`AdoptAll()` 在 `ADOPT_BLIZZARD_BARS == false` 的分支里调 `GhostBar("StanceBar")`。
而**姿态条从来没有自绘替代品**（宠物条有 `BuildPetBar` 收养 `PetActionButton1..10`，
姿态条没有），所以"给已接管条让路"的这刀落在了唯一一条没被接管、却是玩家唯一能点的条上。
`git log -S` 追到 2026-10-24 的 `8b2c943` / `de78e4b`，**一直存在，不是昨天的回归**。

**修法**：删掉那个调用（连同只被它用过的 `GhostBar` 函数）—— 姿态条交回暴雪原生显示，
玩家想挪/藏就在编辑模式里调（那是玩家操作，不算插件污染）。

**为什么留着它安全**：它的壳只有 **94×30**（宠物条那个才是 1303×1193、必须关鼠标），
默认位置正好在 3 号条左边、同一行；我们**一行字段都不往它写、一个方法都不调**。
实机对照：改后 alpha=1、三格可见、可点。

### 3.8 后续：姿态条改成「收养」（`816c320`）

原生姿态条能用但长得跟我们的条不一样（30×30、暴雪美术）。照宠物条那条**已验证**的路子
把它接管过来：`BuildStanceBar` / `AdoptStanceButtons` / `ReleaseStance` / `SkinAdoptedButton`。

- **收养的按钮**：`_G["StanceButton"..i]`（`SetParent` 到 `MonetUIBarStance`、`SetSize` 到
  `ButtonSize()`、`SetScale(1)`、换皮）。施法 / 选中态 / 冷却 / 图标全走暴雪
  `StanceButtonMixin_OnClick → StanceBar:Select → CastShapeshiftForm`，和我们自己写的按钮无关。
- **布局**：`BAR_DEFS` 里 `BarStance`（`stance = true`）锚在 **`Bar3` 正上方、左对齐**
  （`BOTTOMLEFT → Bar3.TOPLEFT`，y=2），按钮**左对齐**往右排（`(i-1)*step`）；容器宽度只算
  **可见的形态数**，藏起来的 N+1..10 挂在框外更右边。`RefreshLayout` 对这条走
  `AdoptStanceButtons` 而**不是** `LayoutBar`（左下排布是给自绘按钮的）。
- **宠物条位置**：`BarPet` 锚在 **1 号条下方、右对齐**（`TOPRIGHT → Bar1.BOTTOMRIGHT`，y=-2），
  右端与 1 号条齐平。
- **宠物条"悬停高亮"**（`SetupHoverOnly`）：平时 `SetAlpha(0.3)`、悬停 `SetAlpha(1)`
  （2026-10-26 起；见 3.9，原来是 0）。用 alpha **不用 Hide** —— alpha 不为 0 的帧在客户端眼里
  仍是"显示着"的，鼠标进得来（`EnableMouse(true)` 开在**我们自己的**容器上），也不会和
  `[pet]` 状态驱动的 Show/Hide 互相顶（顶的结果是"一闪一闪"）。判定走 `Widget:HoverWatch`
  （0.1 秒轮询），**绝不往暴雪的受保护按钮挂 OnEnter**。配置面板「动作条」里有对应勾
  （`actionBars.petHover`，默认开），姿态条同一套（`actionBars.stanceHover`）。
- **形态数**：`GetNumShapeshiftForms()`（本客户端只有复数名，单数版不存在）。>N 的格子 `Hide`；
  =0（猎人/牧师这种没有姿态条的）就不显示我们的条，并把按钮与外壳还给暴雪。
- **外壳**：`StanceBar` 只 `SetAlpha(0)` + 关鼠标，**事件一条都不卸载** —— 图标 / 选中态 / 冷却
  都是它自己的 `UpdateState` 在刷（`StanceBarMixin:UpdateState` → `UpdateShownButtons`）。
  代价与宠物条同类：它的 `SetShown` 会对已搬家的受保护按钮被拒，日志多几条 BLOCKED
  （只进日志、不弹窗、功能正常）。`UpdateGridLayout` 动的是**容器**，容器还在外壳里，不影响我们。
- **两条退路**（`M:Apply` / `M:SetEnabled(false)`）：玩家关掉自绘动作条、或这个职业形态数为 0 时
  `ReleaseStance` 把按钮 `SetParent` 回 `StanceBarButtonContainerN`、外壳 alpha/鼠标放开 —— 否则
  按钮留在我们藏起来的框体里，原生姿态条就成一条**空壳**，玩家直接没法变形态。
- **三处循环要用 `IsAdopted(bar)` 绕开**（宠物 + 姿态共用）：`UpdateCooldowns`（`PaintCooldown`
  用的是自绘槽位公式，对收养条算出来是负数 → `GetActionCooldown` 读不到，只剩 `Clear()`，
  等于把原生冷却圈擦掉）、`SetClickOptions`（暴雪按钮身上有 `.bar = StanceBar/PetActionBar`，
  我们那套会去 `Execute` 一条**没有** `mui-keydown` 片段的受保护条）、`ReassignBindings` /
  `ClearBindings`（收养条的键位本来就绑在暴雪命令上，再包一层会把整条调用链记成我们的）。

**为什么收养，而不是像 ElvUI 那样自建 `StanceButtonTemplate` 按钮**：自建要求"我们自己造的受保护
按钮点下去能施法"，而这正是本客户端踩过的坑（自绘 `type="pet"` 按钮属性全对、层级也压过所有条、
0 拦截，点击毫无反应 —— 客户端根本不处理）。收养拿到的施法路径与已验证的宠物条逐位相同；
Ellesmere 在本客户端也是收养（`EllesmereUIActionBars.lua:3136` "Stance bar: reuse StanceButton1-N"）。

**待玩家复核**（自动化点不了：注入鼠标不生效，`GetCursorPosition()` 返回常数）：
点一下三个形态是否都能变、`/reload` 后位置是否还在 3 号条左边、`taint.log` 有没有新的
"blocked in combat because of taint from MonetUI"。

### 3.9 2026-10-26：悬停显隐三项 + 宠物条空槽底色（`08ce74e`）

玩家三条要求 + 一个缺陷，一次做完：

| 位置 | 行为 | 配置键 |
| --- | --- | --- |
| 宠物**单位框** | 悬停或"宠物被选中"（是当前**目标**或**焦点**）→ alpha 1，否则 alpha 0 | `unitFrames.petHover` |
| 宠物**动作条** | 平时 alpha **0.3**、悬停 1（原来是 0） | `actionBars.petHover` |
| **姿态条** | 平时 alpha **0.3**、悬停 1（原来没有悬停） | `actionBars.stanceHover` |

- 宠物单位框：显隐**还是** `visibility` 状态驱动（`SecureUnitButton` 战斗里不能 Show/Hide），
  这里只动 alpha；alpha 0 的帧客户端仍算"显示着"，鼠标进得来，不会把自己锁死。
  "选中"只能用轮询（`UnitIsUnit` 是 `SecretWhenUnitComparisonRestricted` 返回 → 一律过
  `Secrets.Bool`），悬停用 `Widget:HoverWatch`（0.1s）、选中用 `Widget:PollWatch`（0.2s）。
  写在 `UnitFrames.lua` 的 `ApplyPetHover` / `SetPetAlpha` / `PetSelected`，`M:Apply` 与
  `M:Initialize` 各调一次（改勾立即生效，不用 /reload）。
- 两条动作条：`HOVER_IDLE_ALPHA = 0.3`，姿态条在 `M:Apply` 的 stance 分支里也调 `SetupHoverOnly`，
  `BAR_DEFS.BarStance` 补 `hover = true`。
- **回调是常驻登记的**（`bar.hoverReady`），所以加了 `bar.hoverOnly` 开关：配置里关掉悬停后
  回调仍在跑，没有这个开关的话鼠标一进出又会被拉回 0.3（关掉=常显 1）。
- **宠物条空槽（8..10 格）**：暴雪的 `SlotBackground` / `NormalTexture` 被 `SkinAdoptedButton`
  关掉之后，没有动作的格子整格透明 —— 玩家原话"空白按钮看不到"。补一块和自绘槽位同色的 well
  （纯黑 0.25，见 `RefreshRing`），`BACKGROUND/-8` 垫在图标下面（暴雪图标是 `BACKGROUND/0`，
  有图标时被完全盖住），记在 `Mark(btn, "adoptedWell")`。

实机核对（重载后探针）：`MonetUIBarPet alpha=0.302`、`MonetUIBarStance alpha=0.302`、
`MonetUIPetFrame alpha=0`（未悬停未选中）、`PetActionButton8` 的 well 区域 `shown=true`、26×26、
`BACKGROUND` 层（1px 内缩，和自绘槽位逐像素同源）。

**同一轮里被这条配置路径带出来的两个修复**：

- `9014767`：改任何单位框颜色 → `M:Apply` 遍历所有框调 `UpdatePowerColor`，而 `targettarget`
  从 2026-10-25 起没有能量条 → 最后一行 `frame.power:SetStatusBarColor` 抛
  `attempt to index field 'power' (a nil value)`，Apply 后半段（含 `UpdateAll`）整段不执行。
  改法：进函数取局部 `bar`，没有就早退（配置面板改颜色走的正是这条路）。
- `0a37c33`：`UnitIsUnit` 是 `SecretWhenUnitComparisonRestricted`，受限时布尔测试会被客户端
  拦成 `ADDON_ACTION_BLOCKED UNKNOWN()`。第一版走 `Secrets.Bool(is, false)` → 被拦时落回 false，
  战斗里宠物当目标时血条会凭空消失。改为自己 pcall 真值测试：**读不出来就当"选中"**（宁可多显示
  一条框，也不要丢信息）。

**待玩家复核**：鼠标扫过宠物动作条 / 姿态条是否变清晰、宠物框悬停或把宠物设为目标是否浮现、
宠物条 8..10 格是否和 1–8 号条的空槽长得一样。

### 3.10 2026-10-26：点姿态放出"动作条第 1 格"（覆盖层，`f88e902` + `0c98550`）

玩家报："鼠标点了姿态，实际是动作条 1 的技能"。量出来的几何：姿态条 **888,121 28×28**
（当时只有 1 个形态），而 **bar4 的拖放接住器** 是 **887,121 358×28、level 70**（姿态按钮 67）
且 `IsMouseEnabled() = true` —— 点姿态的每一格都被它吃掉。

- **根因 1（`f88e902`，DragDrop）**：接住器的 10Hz 轮询写成
  `if not frame:IsShown() then ... return end`。接住器建出来是 `EnableMouse(false)`，但模板自带的
  事件会在装载时把它打开；**显示着的条**下一拍就被 `holding=false ~= nil` 修正回 false，
  **隐藏的条（bar4..8）因为早退永远没人修正**，于是停在 mouse=true —— 而它们恰好和姿态条同 y。
  改法：每一拍都算出期望状态 `条显示着 且 手里拿着东西`，和当前状态不同就写过去（含关掉）；
  `IsShown` 走 `Secrets.Bool`，读不出来按"没显示"（= 关鼠标，更安全）。
- **根因 2（`0c98550`，ActionBars）**：姿态条默认锚 `Bar3`，但「显示动作条数量」开到 4 组时
  `Bar4` 会长在**同一个 y**，两条直接叠死。新增 `SyncStanceAnchor()`：按 `BarCount()` 把默认
  `relativeTo` 算成 `Bar<最高索引>`；`M:Apply` 与 `M:RefreshLayout` 排布前各调一次。
  另外 `M:Apply` 的 stance 分支补了一次 `PositionBar` —— 面板改条数只走 Apply，不补这一下
  def 变了而帧不动（实测 3→4 组时 y 仍是 121）。

实机核对：8 只接住器 `mouse=false / holding=false`；姿态条 888,121（3 组，= Bar3 顶）；
临时 4 组 → 姿态条 151（= Bar4 顶）、bar4 在 121；改回 3 组 → 121。**待玩家点一下形态确认不再放技能**，
并顺手确认拖放落位仍然正常（接住器只在"条显示着 + 手里有东西"时才开鼠标）。

**教训**：凡是"挂在别的条矩形上的覆盖层"，它的鼠标状态必须**无条件每拍结算**，
不能因为宿主隐藏就早退 —— 覆盖层是独立框体，不会跟着宿主一起失效。

### 3.11 2026-10-26：转正成 MonetUI + 子模块 xml 清单

两件事一起做，纯结构，**没有任何 Lua 逻辑改动**（`.lua` 一个字节没动）：

1. **转正**：`wowaddonsdev\MonetUI-refactor` → `wowaddonsdev\MonetUI`（就是这个仓库，174 个提交、
   游戏里装的那一份）；原来的 `MonetUI`（停在 `cb7d932`）改名 **`MonetUI-archive`** 留存，不再开发。
   游戏侧无需动作：安装目录本来就叫 `Interface\AddOns\MonetUI`，`sync-check` 仍然同步。
2. **加载清单改成 xml**：`MonetUI.toc` 从 60+ 行 `.lua` 变成"每组一份 xml"：
   `Libs/Libs.xml`、`Utils/Utils.xml`、`Config/Config.xml`、以及 `Modules/` 下 14 份
   （`UnitFrames` / `ActionBars` / `Minimap` / `InfoBar` / `Skins` 是多文件组，其余是单文件模块
   —— 单文件模块仍**直接列 `.lua`**，不再多套一层 xml）。组内顺序 = `<Script file>` 的先后，
   组间顺序 = toc 的先后，两级合起来和改动前的加载顺序**逐一对应**（51 个 `.lua` 全部仍被引用）。
   每个 xml 头部写了这组"是什么 + 为什么是这个顺序"（例如 `UnitFrames.lua` 必须先建 `M.frames`、
   `InfoBar/XP.lua` 必须最后拿那条经验衬线），改顺序时不用再猜。

验证：19 份 xml 逐个 `[xml]` 解析通过；`node tools/api-audit.js` 0 hard（`toc: 0 problem(s)`）；
`wuxian check(live:false)` **0 error / 5 warning**（就是那 5 条已知基线：4× `PickupAction/PlaceAction`
受保护 + `toc-interface`），并且 `not-loaded` 只剩 `tools/api-audit-selftest/Broken.lua`
——说明客户端侧确实是顺着 toc → xml → `.lua` 找文件的。
版本号 `0.11.0` → `0.12.0`。**待实机 `/reload` 确认模块全开**（`x/17 个模块`）。

### 3.12 2026-10-26：姓名板去光环 + 当前目标金色/放大

玩家要求：姓名板**不再显示 buff / debuff**；**当前目标放大 1.1 倍、边框变金色**。

- **去光环（`Nameplates.lua` 净删 ~300 行）**：整套"借用暴雪 AurasFrame"的机器全拆了
  （`BuildDebuffDressing` / `ReapplyDebuffDressing` / `DressDebuffButton` / `DressDebuffList` /
  那条 `PollWatch` 补扫 / `AnchorDebuffs` / `TryBorrowAuras` / `HandBackAuras` 以及
  `HideBlizzardPlate` 里的 `SetParent(auras → plate)` 分支），Core 的 `showDebuffs` / `auraGap`
  默认值、设置面板的「显示减益光环（借用暴雪）」勾选框一并删掉。
  **为什么这样删就够了**：我们对暴雪 `UnitFrame` 只做 `SetAlpha(0)`（不能 Hide，C++ 点击区锚在它上面），
  `AurasFrame` 是它的子帧 —— 以前正是"连带透明所以必须 SetParent 出来"才看得见；不借了，它就跟着
  alpha 0 一起消失。**副作用是好的**：最大的两块污染面（改父 + 给暴雪光环按钮换皮）整个不存在了，
  `NAME_PLATE_UNIT_REMOVED` 也不再有"光环列表挂在旧 base 上把两族锚点连起来"的隐患。
- **当前目标标记**：`UpdateBorder` 里算一次 `UnitIsUnit(unit,"target")`（过 `Secrets.Bool`，
  **默认值是上一次的判定**而不是 `false`，否则机密期每次刷新都会把牌子缩回 1.0、金边闪一下），
  目标 → `TARGET_GOLD = {1.00, 0.84, 0.28}` + `plate:SetScale(1.1)`，非目标 → 缩回 1.0。
  金色**不跟主题走**（它回答"这是我的目标"，不是"什么威胁"）；**仇恨色优先级更高**：
  `3`(红) / `2·1`(琥珀) 仍然盖过金色，只在该单位不是威胁目标时显示金边。
  设置面板那一项改名「当前目标：金色描边 + 放大 1.1 倍」（键仍是 `highlightTarget`）。
  `Added()` 里把 `plate.isTarget / targetScale` 清空 —— 同一个 base 会被池子换给另一只。

验证：`api-audit` 0 hard、`wuxian check(live:false)` **0 error / 5 warning**（同基线）。
**待实机看**：① 姓名板确实一个光环都不显示（连自己的 proc 也没有）；② 切目标时金边 + 1.1x 跟得上，
战斗中（机密期）不闪；③ 1.1 倍只是视觉，暴雪点击区没跟着放大，最外圈 10% 仍然点不到。

### 3.13 2026-10-26：鼠标提示重做（位置修缺陷 + 精简版 Andromeda 内容增强）

参考 `Andromeda/modules/tooltip/`（10 个文件、约 60 KB）重写 `Modules/Tooltip.lua`。
**结论先说**：它的**挂法**在我们这台客户端上一条都用不了，只能用"自建驱动帧"重做。

**为什么不能照抄它的挂法**
- `TooltipDataProcessor`（它 `tooltip.lua:456`、`style.lua:117` 的主路径）在 1.60.1.70450 **不存在**
  （`docs/api` 快照 + API 手册双查零命中）。
- 它剩下全是 `hooksecurefunc` / `HookScript`（`id.lua` 11 处、`style.lua` 十余处）—— 写暴雪框的
  方法槽 / 脚本槽，AGENTS 的污染模型明令禁止（`GameTooltip` 也一样，`SharedTooltip_SetBackdropStyle`
  我们都没敢 hook，见 `Modules/Skins/System.lua:285`）。
- 它的 `KindOf()` 用的 `GetPrimaryTooltipData` / `GetTooltipData` 也不在快照里；只有
  `Enum.TooltipDataType`（28 项）和 `TOOLTIP_DATA_UPDATE` 存在，后者是"稀疏/缓存解析完成"，不是"填了内容"。

**保留（这次实现的）**
1. **位置**（顺手修掉上一轮审计列出的缺陷）：跟随光标改成**每帧**（以前是 0.2 s 的 `PollWatch`
   + `ShowWatch` 双轮询，结果每次悬停先在暴雪锚点闪一下、移动时 5 fps 阶梯）；贴到右/上边缘
   **翻到光标另一侧**再顶回屏幕内；偏移改物理像素（`Media:Mult`）；`SetClampedToScreen(true)` 兜底。
   还删掉了 `Apply()` 里"取消跟随就把正在看的提示框 Hide 掉"那一记。
   **摆法做成三选一**（设置键 `anchor`，默认 `cursor`）：`cursor` 跟随鼠标 / `minimap` 提示框的
   **右下角对齐小地图面板 `MonetUIMinimapPanel` 的右上角**（贴在地图上沿、右边缘齐平；长得顶出屏幕
   顶边就改挂面板下方；小地图模块关掉/面板隐藏时自动退回跟随）/ `off` 暴雪默认位置。
   老存档只有布尔 `follow`：`true`→`cursor`、`false`→`off`，由 `ResolveMode()` 迁移，不丢设置。
2. **单位提示补一行「目标: 谁」** —— Andromeda `TOOLTIP:GetTarget` 的等价物，不碰 inspect、不扫团队。
3. **Alt 显示 ID** —— 单位 = GUID 里的 `Creature-/Vehicle-` 编号、物品 = 链接里的 itemID、
   法术 = `GetSpell` 的 spellID（Andromeda `id.lua` 的内容，但改成"显示"而不是挂 11 个钩子）。

**砍掉（以及理由）**
| Andromeda 功能 | 不做的原因 |
|---|---|
| 专精 / 装等（`specilvl.lua` 17 KB） | 要 `NotifyInspect` 发网络包 + 缓存 + 队列，17 KB 换一行数字，性价比最低 |
| 名字重涂 / 公会 / 头衔 / 服务器后缀 | 和客户端自己的名字行打架，且要处理 4 种 realm relationship |
| 等级行改写（职业 / 生物类型 / PVP / 死亡） | 本客户端 tooltip 是数据行驱动（`Enum.TooltipDataLineType` 51 项），改写会被下一次重绘覆盖 |
| 团队标记图标、TargetedBy、挂载来源、成就 / 图标 / 超链接 / M+ / 盟约 | 场景太窄或依赖不存在的 C_*；M+/盟约本客户端根本没有 |
| `style.lua` 整套外观 | 我们已有 `Modules/Skins/System.lua` 的 tooltip 皮肤包（九宫格染色 + ItemRefTooltip） |
| ItemRefTooltip 拖动 / 关闭钮（`itemref.lua`） | 只在聊天物品链接窗口上划算，和本次目标无关，留待以后 |

**实现要点（无钩子怎么保证正确）**
- 一个**自建**驱动帧（我们的框，`OnUpdate` 不污染任何暴雪框），每帧看 `GameTooltip:IsVisible()`；
  隐藏时直接 return（零开销）。显示**上升沿**那一帧就摆位 + 补内容。
- 幂等靠 `ns:Mark` 旁表记三个签名：`tipPre`（补前）/ `tipPost`（补后）/ `tipNoAdd`（本次显示别再补）。
  内容变了（换目标、Shift 比对、按下 Alt —— Alt 也进签名）才重补。
- **防闪**：如果同一份内容下我们加的行又不见了，说明引擎按数据重绘了整个框 → 记 `tipNoAdd`，
  本次显示不再补（否则每 0.05 s 加一行，提示框会一直长/一直闪）。
- 机密值全过 `Plain()` / `Secrets.Number` / `Secrets.Bool`：战斗中身份是机密时**宁可少一行**，
  不写 "目标: ???"。`UnitGUID` / `UnitName` / `UnitClassBase` 都是机密标记 API。

闸门：`api-audit` 0 hard（`NumLines` 是唯一 INFO：FrameXML 方法，快照不覆盖，Andromeda 也用）、
`audit-taint` 0/0/0、`wuxian check(live:false)` 0 error / 5 warning（基线）。
**待实机看**：① 悬停时不再有"先出现在按钮右边再跳过来"的闪；② 拖鼠标跟手；③ 屏幕右/上边缘翻转；
④ 单位提示多出「目标」行、Att+悬停出 ID 行；⑤ 提示框没有"越加越长 / 反复闪"的迹象（`tipNoAdd` 生效）；
⑥ 战斗中不报错、不显示错值。

### 3.14 2026-10-26：施法条红三角压到能量条上（锚点方向错了）

玩家报："玩家施法条的红色三角顶部位置错了，压在了能量条上"。

- **根因是锚点方向**：`CastBar.lua` 把三角（一个 `▲` FontString）按 **BOTTOM** 锚在 2px 高的
  `cast` 框底部 → 字身**向上**长。字体行高天生大于 2px（`SetFont(..., 2)` 不等于 2px 行高），
  3.13 那轮把字体换成 PingFangPixel + `OUTLINE` 之后行高和墨迹又各涨了一圈 → 顶端越过
  `CAST_GAP = 1` 的间隙，直接压在能量条下沿。
- **修法**：改成 **TOP 锚**（三角从 cast 框顶部**往下**长，顶端永远只是"贴着"能量条下沿），
  三处一起改 —— 创建时、`OnUpdate` 每帧扫动时、以及机密时间戳那条"钉在左端"的兜底路径。
  同时 `CAST_GAP` 从 1（UI 单位）改成 **2 物理像素**（`* Media:Mult()`，OUTLINE 会在字身外再扩 1px），
  并按 `GetStringHeight()`（pcall 探测）把 cast 框高撑到真实字身高度，不再"框 2px、三角 5px"。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
deploy 117 + sync-check 同步。**待实机看**：施法/引导时三角顶端在能量条下沿之下、不再压上去，
扫过整条时不抖；目标框同样。如果还想再离远一点，只改 `CAST_GAP` 一个数。

### 3.15 2026-10-26：三角改成手绘贴图（尖端精确顶住），施法条与经验线共用

3.14 只是把锚点方向掰正了，但**字形里的三角**永远受字体支配：行高、墨迹高度、抗锯齿都不由我们定，
换个字体就又漂一次。玩家要求"精确地把尖尖顶在条上"，所以干脆**不用字体画三角**：

- 新增两张 SVG（Inkscape 手绘，`tools/svg/`）：`monet_spark_up.svg` / `monet_spark_down.svg`。
  画布 **16×8**（两个维度都是 2 的幂），纯白染色模具，`node tools/svg-to-tga.js` 导出
  `Assets/Textures/monet_spark_{up,down}.tga`。
- **布局契约（写在两个 SVG 的头部注释里）**：三角的**尖端那一行就是画布边缘** ——
  up 的尖在第 0 行、down 的尖在最后一行。于是"把贴图那条边锚在条上"就等于"尖端精确顶住"，
  再也不用算字体高度。**改图时不许在尖端那侧留白**；要间隙就改代码里的 `CAST_GAP`。
- 尖端做成 2 单位宽**平头**：16→8 缩一半后正好落成 1 个实心像素。纯数学尖点在 4px 高的小图上
  会被 AA 摊成半透明，看着像"没顶到"。
- 施法条（`Modules/UnitFrames/CastBar.lua`）：FontString → `CreateTexture`，
  `SPARK_W/H = 8×4` 物理像素，`CAST_GAP = 0`（尖端正好顶在能量条下沿），**TOP 锚**；
  颜色从 `SetTextColor` 换成 `SetVertexColor`（红 / 主题中性色）。
- 经验线（`Modules/InfoBar/XP.lua`）：同样的字体三角毛病，`▼` FontString → `monet_spark_down` 贴图，
  `MARKER` 语义从"字号"改成"宽度"（8 宽 × 4 高）；**尖端顶在经验条的上沿**（`Px(LINE)`，
  那条 1px 衬线的顶边）—— 三角整个骑在线上，进度色一点不被盖住；
  三处 `SetTextColor`（常态 / 白热 / 升级闪）换成 `SetVertexColor`。
- 材质合规：`tools/audit-pixels.js` 的 `STENCIL` 名单登记这两张（纯白模具，色相 0），
  `Media.texture` 注册 `monet_spark_up` / `monet_spark_down`。像素审计实测两图各
  `半覆盖 28 / 孤立 0 / 软边 6 / 色相 0 / 非纯白衬底 0`（软边是斜边的 AA，符合判据）。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
`audit-pixels` 0/35 未通过、deploy 119 文件（+2 张 TGA）+ sync-check 同步。
**待实机看**：施法条三角尖端与能量条下沿严丝合缝（`CAST_GAP = 0` 时是"顶住"，要 1px 缝就改 1）、
扫动时不上下跳；经验线三角尖端顶在经验线上沿、涨经验滑动时跟得上、白热/升级闪烁仍是顶点色。

### 3.16 2026-10-26：目标框左下角"一直在"的施法三角（收尾事件被门控掉了）

玩家报："目标框架左下角有个施法条的三角一直都在"。

- **根因是收尾事件丢了**：`M:UpdateUnit()` 开头统一 `if not IsShown() then return end`。
  目标框的显隐是 `visibility` 驱动做的（不经过 Lua），所以"目标消失 / 切走那一刻结束的那次施法"
  的 `UNIT_SPELLCAST_STOP` 恰好在框隐藏时到达 → 直接早退 → `cast` 框停在显示状态。
  下次目标出现，父框一显示，子帧跟着显示 —— 三角就"一直都在"。
  机密时间那条路径还会把它钉在左端（`spark:SetPoint(... TOPLEFT, 0, 0)`），所以位置正好是**左下角**。
- **修法**：
  1. `UpdateUnit` 把 `cast` 这一支提到门控**之前**：框显示着才 `UpdateCast`（查数据刷新），
     隐藏着就 `HideCast`（只收状态、不查数据）。
  2. `RefreshUnit` 补两次施法条对齐：单位不存在时 `HideCast`（这块框马上会被换给别的单位），
     存在时 `UpdateCast`（切目标 / 登录 / 换区域按"现在真的在打什么"摆回来，不依赖下一次施法事件）。
     顺手补上了"中途接手的施法一直不显示"这个伴随缺陷。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
deploy 119 + sync-check 同步。**待实机看**：切目标 / 目标死亡 / 目标是引导法术时，
三角不会留在左下角；新目标开始读条时施法条正常出现。

### 3.17 2026-10-26：提示框边框改 1px + "位置乱跑"

玩家两条反馈：① 鼠标提示边框改成 1px；② 提示位置会乱跑，怀疑有 bug。

**① 1px 边框**：暴雪的 `GameTooltip.NineSlice` 是**厚边贴图**，`SetBorderColor` 只能改颜色、
改不了粗细（这也是一直以来"鼠标提示边框"在这个客户端只能改色的原因）。做法：
- `PlateTooltip()`：在提示框**底下**垫一块 `SetAllPoints` 的 1px 背板（`Widget:Theme(plate,
  { thickness = 1, bgAlpha = 0.95 })`，frame level = 提示框 − 1，`EnableMouse(false)`），
  GameTooltip 和 ItemRefTooltip 都套；`Skin:Track` 登记，美化关掉时随 `HideAdded` 收走。
- `PaintNine()` 看到 `tooltipPlate` 标记就把暴雪那层刷成**全透明**（边框 + 底色 alpha 0），
  尺寸/排版仍由 NineSlice 算 —— 所以文字位置、padding 都不变，只是视觉换成我们的细边。
- 颜色照旧跟主题（`Widget:Theme` 会随 `MONETUI_THEME_CHANGED` 重染）。

**② 位置乱跑**：查下来有两个"两套写手"的结构问题，都在本次拆掉：
- `Frame:SetClampedToScreen(true)`（我们自己在 `Install` 里设的）会由引擎在布局时再挪一次位置，
  和每帧写的锚点互相拉；已删掉，改成 `PlaceCursor` 自己夹进屏幕。
- 翻边判断原来依赖**提示框宽高**（"右边放不下就翻左边"），而宽高会被内容改变（Shift 对比、
  我们追加的 ID 行、暴雪换样式）→ 鼠标停在临界位置时会在两侧之间横跳。
  改成**只看光标离边缘多远**（`EDGE_W = 420` / `EDGE_H = 320` UI 单位），与宽高无关，因此
  内容怎么变都不会改变翻边决策；光标进入右侧/下侧边缘带才翻。
- 顺带：位置去重键保留（光标 + 尺寸 + scale），静止悬停仍然零写入。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
deploy 119 + sync-check 同步。**待实机看**：边框是 1 物理像素（不是原来那圈厚边）、颜色跟主题；
提示框跟着鼠标时**不再左右/上下横跳**，贴右边缘翻到左边、贴下边缘翻到上方，两种都只翻一次。

### 3.18 2026-10-26：提示框边框上主题色 + Alt 的 ID 行"只闪一次"

玩家两条反馈：① 边框要上主题色；② 按住 Alt 只出一次 ID 提示，然后就看不着了。

**① 边框上主题色**：3.17 只把 NineSlice 的**顶点色**刷成透明，实机上暴雪那圈厚边还会漏出来
（贴图自带的边不吃顶点 alpha 的那部分），把我们的 1px 细边压在下面。这次：
- `PaintNine()` 的透明分支连 `nine:SetAlpha(0)` 一起做（整壳隐藏，rollback 时还原原 alpha）；
- 背板 `Widget:Theme(plate, { thickness = 1, bgAlpha = 0.95, borderAlpha = 1 })` —— 边框色走
  `Color:GetBorderKey()`（默认 `edge`，主题一变就跟着重染），不透明、1 物理像素。

**② Alt 的 ID 行只闪一次（根因）**：本客户端的 `GameTooltip` 是**数据行驱动**的 ——
动作条冷却 / 信息栏 / 单位框都会不停重填整个框，我们以前用 `AddLine` 追加的行下一拍就被抹掉。
`Enrich` 的防闪逻辑（`tipPre`/`tipPost`/`tipNoAdd`）在这种情况下会认定"引擎在重绘"，
于是本次显示不再补 —— 表现就是"按一下 Alt 闪一下，然后再也看不到"。
**改法**：附加信息不再塞进暴雪框，改成**我们自己的小框** `MonetUITooltipExtra`：
- 和提示框同一套外观（1px 主题色边 + 近黑底），`TOOLTIP` 层，`EnableMouse(false)`；
- 挂在提示框**下沿**（屏幕底部放不下就挂上沿，只看几何，不会来回）；
- 宽度跟着提示框走；行内容 = 「目标: 谁」（`enrich` 开关）+「NPC/物品/法术 ID」（`idsByAlt` 开关）；
- 文字只在签名变化时重写（换目标 / 按 Alt / 换物品），其余每拍只做对齐。
顺带把"目标行"也搬进这个框 —— 它之前有同样的被抹问题，只是不爱被注意到。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
deploy 119 + sync-check 同步。**待实机看**：提示框边框是**主题色**的 1px 细边（不是白色厚边）；
按住 Alt 期间 ID 一直显示、松开就消失、再按又出现；换目标时「目标」行跟着换。

### 3.19 2026-10-26：提示框边框第 3 版——画在提示框自己身上（终版）

玩家反馈"边框还是没有"，要求"用任务追踪那种边框即可"。前两版都没显示出来，根因是
**在这台客户端上 `SetBackdrop` 的 `edgeFile` 不可靠**（AGENTS 里早就记过：edgeFile 只吃 BLP，
TGA/WHITE8X8 会渲染成一排虚线；子框上这条更明显）。

任务追踪的边框其实就是 `Widget:Theme` 的 1px 主题边 + 暗底（`Modules/QuestTracker/QuestTracker.lua:445`
`Widget:Theme(tracker, { thickness = 1, bgAlpha = 0.92 })`）。提示框不是我们的框、也没有
`BackdropTemplate`，所以用**等价的最稳画法**：

- 在 `GameTooltip` / `ItemRefTooltip` **自己身上**建 5 张我们的贴图（`PaintTooltipPlate`）：
  `bg`（BACKGROUND 子层 -8、`SetAllPoints`、暗底 `ambient*0.35 @0.95`）+ `top/bottom/left/right`
  （BORDER 层、各锚一条边、粗细 = 1 物理像素 = `Media:Mult()`）；
- 颜色 `Color:GetBorder()`（主题边框槽，默认 `edge`），`Skin:OnTheme` 里重染；
- 都在 ARTWORK（文字）下面，贴图不收鼠标事件；
- NineSlice 仍整套隐藏（`PaintNine` 的透明分支，含 `SetAlpha(0)`），厚边不再漏出来；
- 关掉「鼠标提示边框」时 `Skin:Record` 把这 5 张贴图 Hide 并清 Mark。

**下次别再走的两条路**：① 子框 + `Widget:Theme`（edgeFile 不渲染）；② 只把 NineSlice 顶点色刷透明
（厚边仍有残留）。想改边框粗细只改 `PaintTooltipPlate` 里的 `px`。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）、
deploy 119 + sync-check 同步。**待实机看**：四周是 1 物理像素主题色细边（与任务追踪同色）、
换主题跟着变；`ItemRefTooltip` 同样。

### 3.20 2026-10-26：`invalid value (secret)` —— 机密单位令牌进了 table.concat

实机报错（Count: 3）：`Modules/Tooltip.lua:359: invalid value (secret) at index 1 in table for 'concat'`，
栈 `concat ← Enrich ← Tick`。

- **根因**：受限时 `GameTooltip:GetUnit()` 把 **unit 令牌**也标成机密，而我们的
  `TooltipUnit()` 只判了 `type(unit) == "string"` —— **机密串的类型照样是 string**，于是它被塞进
  签名数组第 1 项，`table.concat` 当场抛。`CollectLines` 里 `unit .. "target"` 其实也抛，
  只是那条被 pcall 吞掉（表现为"目标行有时不出现"），签名这行没 pcall 就冒出来了。
- **修法**：`TooltipUnit()` 补 `Secrets.IsSecret(unit)` → 机密令牌当"读不到"返回 nil（少一行）；
  新增 `SafeSig(parts)`：签名拼接前把任何机密值换成 `"?"` 再 `table.concat`。
  `Tick` 是每帧驱动，这里抛一次就是每帧一条报错，所以这层兜底必须留。
- AGENTS「安全边界」补了一条规矩：**判完类型必须再过 `issecretvalue`** 才能进 concat / format。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning（基线）。
**待实机看**：战斗中悬停单位不再刷这条；脱战后「目标」行照常出现。

### 3.21 2026-10-26：退役 `BagFrame`（两套背包只留 `Bags`）

玩家要求："背包模块做了 2 个，留下分类背包，去掉另一个。"

- **删掉**：`Modules/BagFrame/`（`BagFrame.lua` + `BagFrame.xml`），toc 里的那行、
  `Core.lua` DEFAULTS.modules 的 `BagFrame = true`、设置面板的模块顺序与标签条目。
- **为什么可以直接删**：`BagFrame` 只是把暴雪原生容器**排成一行 + 加主题边框**（美术层），
  而 `Bags` 是完整替代 —— 它自己画分类窗口，并且 **接管暴雪背包**：
  `HideBlizzardBags()` 藏掉 `ContainerFrame1..13` / `ContainerFrameCombinedBags`，
  `HookBlizzardBags()` 在暴雪 `Show` 时把我们的窗口顶上来（`C_Timer.After(0)` 延后一帧，
  避免它自己建格子时拿到 nil）。两套一起开只会互相抢 `ContainerFrame` 的显隐，删掉靠后的那个是唯一正解。
- 保留的历史价值：`BagFrame` 曾经往暴雪 `ContainerFrame` 上挂 `OnShow`（写脚本槽 = 污染），
  是 `PLAN-refactor.md:203` 那个"真违规一例"的来源；这条教训留在文档里，
  `.opencode/skills/wow-secret-value-taint-audit/SKILL.md` 的判例也标注了"该模块已移除"。
- 存档里可能残留 `MonetUIDB.modules.BagFrame`：没人读它，无害。

闸门：`api-audit` 0 hard（toc 列的文件全部存在）、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning、
deploy（文件数从 119 降到 117）+ sync-check 同步。**待实机看**：`/mui status` 里不再有 BagFrame、
背包键（B）/ 背包钮仍能打开分类背包。

### 3.22 2026-10-26：连续按 B 会"两套背包一起出来"

玩家报：连续按 B，分类背包和暴雪原生背包同时出现。

- **根因（两个叠加）**：
  1. 老实现用 `Widget:ShowWatch` 的**上升沿**拦暴雪的背包框，而它是 **0.2 秒轮询** ——
     两次 B 压在一个间隔里，上升沿直接漏掉；
  2. 更关键的是**只藏一次**：`Intercept` 里藏完就切自己的窗口，之后暴雪那边
     （合并框 + 5 个包是一串调用、还有 `BAG_UPDATE` 后的重刷）**还会再 Show 回来**，
     没人管 → 我们的窗口开着、暴雪的框也留着 = 两套一起出来。
- **修法**：把"藏暴雪背包框"从**一次动作**改成**持续不变量**：
  - `SweepBlizzardBags()`：扫一遍 `ContainerFrame1..13` + `ContainerFrameCombinedBags`，见显示就藏；
  - `StartBlizzardGuard()`：自建帧每 **0.05 秒**跑一次（模块没开就直接 return），
    扫到就藏；并且把"扫到东西"当成玩家按了一次 B（`M:Toggle()`）——
    暴雪一旦被我们藏掉，它自己就认为"背包是关的"，所以**下一次 Show 必然是玩家按键**；
  - `TOGGLE_DEBOUNCE = 0.12`：挡住我们刚藏完那一小段里暴雪的"回光返照"，免得自己切来切去；
  - `bankOpen` 标记：银行窗口开着时暴雪自己也会开背包框，这时**只藏、不切换**我们的窗口；
  - `M:Toggle()` 的**关闭分支不再 `HideBlizzardBags(false)`**（那一步会把暴雪的框 Show 回来，
    守卫下一拍又当成按键再切一次 = 自己弹自己）；"还框"只在 `SetEnabled(false)` 做；
  - `BANKFRAME_CLOSED` 里的 `HideBlizzardBags(false)` 同样删掉。
- 顺带：删掉 `HookBlizzardBags()` 与 `ShowWatch` 注册（守卫每次扫的都是 `_G` 实时查表，
  迟到的 `ContainerFrame` 也能被扫到，不需要"补钩"）。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning、
deploy 117 + sync-check 同步。**待实机看**：连按 B 十几次不会出现"两套同时"；
正常按一次 B 开、再按一次关；开着银行翻背包时不会自己关掉；关掉模块后暴雪背包照常能开。

### 3.23 2026-10-26：提示框条目配色 —— **已按玩家要求回退**（`853d38f` revert `37e87c0`）

当天早些时候试过"把提示框条目文字按色相桶映射到 Monet 主题色"（`TintLines` + `MonetColor`：
红→danger、金→primary、绿→health、蓝→resource、白灰→highlight/neutral，第一行品质色不动）。
玩家看过后要求回退，已整体还原：`Modules/Tooltip.lua` 的两处调用与两个函数、`tooltip.tint` 默认值、
面板那一项、README/HANDOFF 的说明全部撤销。

- 回退方式：`git checkout 37e87c0~1 -- <文件>` + 手工删掉 `Core.lua` 里那一行（Core 有玩家未提交的
  WIP，直接 `git revert` 会因工作区脏而中止），剩下 `tint` 键在存档里没人读，无害。
- 需要时照着 `37e87c0` 的 diff 可以原样捡回来；配套结论仍成立：
  本客户端没有 `TooltipDataProcessor`，只能在 0.05s 驱动里扫，颜色写在文本转义码里的行改不到。

闸门：`api-audit` 0 hard、`audit-taint` 0/0/0、`wuxian check` 0 error / 5 warning、deploy 117 + sync-check 同步。

### 3.24 2026-10-26：本轮**实机验收全部通过**

玩家逐项看过并确认（"都通过"）：

| 项 | 结果 |
|---|---|
| 姓名板一个光环都不显示（3.12） | ✅ |
| 当前目标金色描边 + 放大 1.1 倍（3.12） | ✅ |
| 提示框三摆法（跟随 / 小地图右上角 / 暴雪默认）（3.13） | ✅ |
| 提示框 1px 主题色边框（3.19 的贴图方案） | ✅ |
| 贴屏幕右/上边缘翻转、位置不再乱跳（3.17） | ✅ |
| 按住 Alt 一直显示 ID（3.18 的自建小框） | ✅ |
| 施法条三角尖端顶在能量条下沿（3.14/3.15） | ✅ |
| 经验线三角尖端顶在条的上沿（3.15 后续） | ✅ |
| 连按 B 不再两套背包同时出现（3.22） | ✅ |
| Pawprint 观感对比（外部插件，仅作参照） | ✅ |

> 仍开着、但都不是本轮改动引入的：`ADDON_ACTION_BLOCKED MonetUI UNKNOWN()`（玩家说先不管）、
> P5' 的 `ActionBars/Secure.lua` 拆分、字体授权债（发行前换 OFL 字体）、
> `BuffListFrame` 那条被暴雪 `ApplyFrameOptions` 钉在牌子右端的已知小问题。

---

### 3.25 2026-10-27：战斗辅助改向 —— 默认用暴雪的数字 + 进出战斗醒目提示

玩家定的方向（原话）："战斗辅助模块由于机密值问题，默认使用暴雪的，只需要增加进入战斗和
脱离战斗的醒目提示，参考 andromeda 的实现，增加必要的图形；战斗数字区域尝试更改，如果也涉及
机密值，则不改。"

**为什么默认回到暴雪的**：`C_CombatText.GetCurrentEventInfo()` 在本客户端标着
`SecretReturns`（本地 API 快照，1.60.1.70450）。我们自己画数字时拿不到明文 ——
`FormatAmount` 一律返回 nil，整条不画，等于"开了也没效果"。所以 `damage / heal / avoid`
三个默认翻成 `false`（自己的数字降级为**可选**，开了才接管暴雪对应 CVar、关掉还原）；
`SCHEMA` 5 → 6，`Migrate` 的 v6 块强制翻位 + 删掉作废的 `combat` 键。

**进出战斗醒目提示（新增，`alert` 默认开）**：

- 参考 Andromeda `modules/combat/combat-alert.lua` 的编排（来自 ElvUI_WindTools）：
  两把剑从画面上角滑入交叉 → 盾从中心压上交点 → 大字升起，淡出时剑向外漂、盾放大、字上飘。
  我们简化成**手动 OnUpdate 补间**（项目里没有 AnimationGroup 先例，不引新模式），
  连环进出战斗排队播（最多 3 条，超了丢最老的）。
- 贴图自绘：`tools/svg/monet_combat_{sword,shield}.svg`（Inkscape 可改）→
  `node tools/svg-to-tga.js` 导出 2 张新 TGA（其余 TGA 字节不变）。
  无色相灰阶模具，运行期 `SetVertexColor` 染主题色（盾=primary，剑=highlight，
  大字=danger/health），已加进 `tools/audit-pixels.js` 的 STENCIL（0/37 通过）。
- 只吃 `PLAYER_REGEN_*` 事件 —— 纯事件载荷，不碰任何战斗数据，**无机密值问题**。
- 提示开着时压掉暴雪自己的进出战斗小字（`floatingCombatTextCombatState_v2`），
  避免两份；关掉提示就还原。这条沿用模块原有的 CVar 存档/还原机制。

**战斗数字区域（已撤销 —— 实机证明"确实涉及机密值"）**：

- 当初判断"暴雪数字锚在 `CombatText.textLocations`（一张纯几何表），不读战斗数据，改它
  不碰机密值"。**实机打脸**：暴雪 `CombatText.lua:364` 在战斗中拿**机密的** `lowestMessage`
  与 `self.textLocations.startY` 做比较 —— 我们只要往这张表写过值，暴雪读该字段的那一段
  执行就被记成"tainted by 'MonetUI'"，机密比较直接抛
  `attempt to compare local 'lowestMessage' (a secret number value, while execution tainted by 'MonetUI')`。
- **判定**：写 `textLocations` = 污染暴雪的机密比较 → 按玩家规矩"涉及机密值则不改"，
  **整段功能撤销**（`SCHEMA` 6 → 7，`Migrate` v7 删掉作废的 `area` 键）。撤销范围：
  `CombatText.lua` 的 `AREA_PRESETS`/`ScreenScale`/`ApplyArea`/区域轮询、`Core.lua` 默认值、
  `SimpleConfig.lua` 区域下拉。
- **教训**：这客户端里"纯数据表"也会被机密比较读到 —— 只要暴雪在**机密上下文**里读我们
  写过的字段，就算污染。判断"碰一样东西安不安全"要看**暴雪在哪读它**，不是看它本身存什么。

**面板**：段名 "自身战斗文字" → "战斗辅助"；提示复选框 + 三个"自己的数字"复选框
（标注"可选，默认关"）+ 说明（区域下拉已随功能移除）。

**实机验证（2026-10-27，12.1.5.70575）**：

- ✅ schema 迁移：v6（combat 键删）与 v7（area 键删）均生效，探针 `schema=7 / area=nil`。
- ✅ 提示帧正常播放：`PLAYER_REGEN_*` 触发 `Play` 跑完整段补间（shown→false，末帧收尾）。
- ✅ 美术 + 配色：手动复刻峰值构图截图确认两剑交叉 + 盾 + 大字，主题色正确
  （剑=highlight 银灰、盾=primary 蓝灰、字=danger 红）。
- ✅ 撤销后 `textLocations` 恢复暴雪原值（384/609）且不再被写；重载后 0 ERR / 0 BLOCKED /
  0 WARN；`taint.log` 零 MonetUI 记录。
- ✅ 玩家的「浮动战斗文字」已打开（`enableFloatingCombatText=true`，暴雪数字正常显示）。

**顺带修的 Tooltip 机密报错**（本轮实机新暴露）：本客户端 `ScriptRegion:GetWidth/GetHeight/GetBottom`
与 `FontString:GetStringWidth/GetStringHeight` 全部标着 **`SecretWhenAnchoringSecret`**
（`docs/api` 快照实证）—— 不是"值本身机密"，而是**锚定链摸到机密几何就跟着机密**。
- 第一处（×91 刷屏）：`PlaceCursor`/`PlaceMinimap`/`UpdateBox` 裸读**提示框**尺寸，
  战斗中悬停时是机密值。修法：读完先 `issecretvalue`，机密就降级（宽高按 0 只跟随光标 /
  跳过宽度同步 / 固定挂下方）。
- 第二处（漏网，Count 1）：`UpdateBox` 里 `fs:GetStringWidth()/GetStringHeight()` ——
  小框锚在 GameTooltip 上，**锚定链**把机密传给了我们自己 FontString 的测量值（`Tooltip.lua:274`
  `attempt to compare local 'w' (a secret number value ...)`）。修法：机密时该行不参与
  `widest`（框宽保留上一次）、行高退回字号，且**一行都没测到明文就跳过 `SetSize`**（布局不塌不崩）。
- 排查口径：**测量任何帧之前先想"它的锚定链通到哪"** —— 通到 GameTooltip / 战斗单位框这类
  几何可能机密的帧，`GetWidth` 一族就会返回机密值。全仓已扫：其余测量点的链都是
  UIParent / 我们自己的帧（InfoBar/QuestTracker/UnitFrames/Minimap 等），安全。

> 实机踩点：负 fileID（-4733 / -36）是本客户端贴图的正常内部 ID，不是加载失败；
> `wuxian` ping ~0.74s，`try` 触发→抓图总延迟逼近 1.5s 动画末尾，抓峰值要用确定性
> 手动复刻帧，别赌时机。

### 3.26 2026-10-27（下午）—— 设计审查 + UI 细节整改 + **战斗状态读法**（本轮最贵的一课）

#### 3.26.1 战斗状态：`PLAYER_REGEN_*` 派发当拍，`InCombatLockdown()` 还是**旧值**

实机探针（在 `PLAYER_REGEN_DISABLED` 回调里打印）：

```
combat = "false"      ← 人已经在打怪，回调里读标志却是 false
active = "true" / setting = "true:true" / refresh = "true"（手动调用不报错）
```

**结论**：本客户端**先把事件派给插件、之后才翻战斗标志**。凡是"在 `PLAYER_REGEN_*` 回调里读
`InCombatLockdown()` 判断现在是否战斗"的写法，拿到的都是**上一拍的状态**。

- **修法**：`Core.lua` 在文件加载时（早于所有模块）注册 regen 事件，维护 `combatState`，
  并暴露 **`ns:InCombat()`**；`ns:AfterCombat` 的"当场可跑就当场跑"判定也改用它。
  `PLAYER_ENTERING_WORLD` 时用实时标志定初值（登录 / 重载可能就在战斗里，事件不补发）。
- **全仓扫描结果**：22 处 `PLAYER_REGEN_*` 注册点、36 处 `InCombatLockdown` 调用，
  真正受影响的只有两处：
  - `InfoBar` 的战斗脉冲（见 3.26.2，**这就是"闪烁看不见"的真正原因**）；
  - `Core:AfterCombat` 的当场执行判定（`ENABLED` 当拍读到 true → 本该当场做的事被排到
    "下一次脱战"；`DISABLED` 当拍读到 false → 可能把受保护操作当成脱战跑）。
  其余 34 处都在 `OnUpdate` / 点击回调 / 直接调用 / `C_Timer.After` 里，读到的是实时值，安全。

#### 3.26.2 InfoBar 战斗脉冲：状态修好之后，还要**画得出来**

脉冲（`combatPulse`）是"边框呼吸发红"，但即使状态正确也看不见：

| 边 | 原来为什么看不见 |
|----|------------------|
| 底边 | 被 **XP 进度线**盖掉一半 —— XP 的根框是 `bar` 的**子框**（`XP.lua:422`），子框永远画在父框贴图之上 |
| 顶边 | 信息栏贴着屏幕最上沿，2px 边框只有 1px 落在可见区 |
| 左右 | 2px 细线又贴屏幕左右边缘 |

**修法**：新增**脉冲覆盖层** `pulseFrame`（`bar` 的子框，帧级 `bar+4`，压在 XP 根框 `+2` 之上），
只画 4 条 2px 边，颜色/alpha 由 `ApplyColors()` 每拍写；脉冲一停整层 `Hide`。
相位 `PULSE = 1.6` 次/秒、alpha `0.35 ↔ 1.00` 正弦。

#### 3.26.3 施法火花：3px 总高、红芯 + 描边、"先画大再缩小"

- 玩家要求"总共 3px 高、红色和边框都要、可以先画大再缩小"。
- 源图 `monet_spark_up/down` 从 **16×8 提到 64×32**（矢量源，4 倍超采样），界面里缩到
  **6×3** 显示 —— 3px 高的东西必须靠下采样才有干净边缘。
- 双层染色：**描边**（整枚 6×3，近黑暖灰 `0.10/0.03/0.03`）+ **红芯**（4×2，`1.00/0.18/0.10`），
  整枚 alpha 呼吸 `0.72↔1.00`（约 1 秒一轮）；不可断施法两层一起转中性灰。
- XP 那条三角（`monet_spark_down`）同步升级尺寸，显示尺寸由 `XP.lua` 自定，观感不变。

#### 3.26.4 其它 UI 整改（本轮）

| 位置 | 改动 | 为什么 |
|------|------|--------|
| 背包物品数量 | **自绘白字**（OVERLAY 9），1 个不显示、>999 显示 `999+`、走 `Secrets.Number` | 模板 `SetItemButtonCount` 的计数被 `FlattenSlotArt` 抬到 OVERLAY 7 的图标整个盖住 |
| 背包任务标 `!` | 12px + **`THICKOUTLINE`** | 像素字没有 BOLD，粗描边就是加粗档（实机三版对比：OUTLINE 太细、叠印糊成一坨） |
| 小地图区域名 | 12px → **24px** + `THICKOUTLINE`，并**限宽**到可见宽 −12 | 悬停才显示，要够醒目；不限宽长地名会顶出地图边缘 |
| 姓名板名字 | 默认 12 → **10**（`SCHEMA` 7→8 + v8 迁移只降"还是旧默认 12"的库） | 暴雪自己的名牌名是 9.6 号，我们用 12 反而更大 |
| `/mui` 面板 | 标题左侧挂 24×24 `monet_addon_icon`（睡莲） | 玩家要求；整图烘焙彩色，只调 alpha 不染色 |
| 进出战斗提示 | 进入=**红剑+金盾**、离开=**青蓝剑+绿盾**（盾 0.82 半透明、剑 200px）；剑压盾前 / 盾压剑前；滑入 105→150、入场 0.35→0.28s、到位 +16% 过冲、盾从上方 26px 压下 +18% 过冲 | 玩家三轮反馈：加色 → 进出有别 → 红剑金盾 + 动作更明显 |

#### 3.26.5 设计规范审查（`MonetUI.md`）

- 新增 **§4.3.2 美术色白名单**：背包任务琥珀/任务标金、施法火花内芯/外晕、进出战斗剑盾的美术色，
  并写明判定口径（"去掉这个颜色玩家会不会看不出功能含义"）。
- 审查结论：全仓 110 处颜色调用里 107 处走 `Color:Get*`；字体全部经 `SnapSize`；
  37 张 TGA 全部过 `audit-pixels`（37/37 PASS）；无硬编码贴图路径；暴雪帧上无 `HookScript`。
- **仍待更新**：`MonetUI.md` §9 还写着"明暗不烘进纹理""不产 SVG 材质""26/26 通过"，
  与现状（剑/盾烘灰阶明暗、9 张 SVG 源、37/37）不符 —— 下次改文档时一并订正。

#### 3.26.6 收尾状态（2026-10-28 更新）

- ~~名字 70% 规则只落了一半~~ → **已接线完成**（2026-10-28）：`Widget:FitText` 接到
  `Nameplates.UpdateText`（先定 level 段再算名字限额，level 段比剩余 30% 宽时再收一档）、
  `UnitFrames.UpdateName`（限额 = 70% 框宽，再扣 level/血量文字实测宽）、`Groups.DisplayName`
  （FitName 帮手 + 按钮上存 `nameSize`/`nameBoxW`）。旧的按字数截断全部停用（设置保留不读）。
- **接线时抓到的 FitText 真 bug**（实机判例）：自动宽度的 FontString（只锚一个点的名牌/
  单位框名字）被内部"钳到 fs:GetWidth() 保险"打中 —— 自动宽度下 GetWidth 跟着文本走，
  把限额压到文本自身宽度，`width > maxWidth` 同源浮点毛刺一翻就**虚假缩一档**（玩家名
  10 号永远显示成 9）。修法：钳制逻辑改为调用方显式传 `boxWidth`（Groups 的 SetSize 固定
  盒子传 `button.nameBoxW`），自动宽度的调用点不传。
- **实机已验**（2026-10-28）：InfoBar 脉冲（战斗中红线 0.93→0.99 呼吸、截图红线清晰）、
  背包数量白字（消耗品 6/17/21 等全部显示）、施法火花（6×3、红芯+暗描边、呼吸中）、
  小地图区域名 24px、玩家框名字 10 号恢复、名牌长名缩字（9 号 82≤84）。
- ~~**待复核**（当时链接断了，仅一块反例）~~ → **已闭环（2026-10-28）**：8 号超限瞬态是
  旧版误钳 bug 的产物，修钳后不可复现；当前视野名牌全部在限额内（10 号）。
  顺带实测**像素字体宽度量化悬崖**：`银月大使帕拉·晨歌`（9 字形）
  10→100.0 / 9→92.5 / **8→85.0 / 7→65.8 / 6→65.8** —— 8 号差 1px 就直接落 7 号
  （7=6 是字体分辨率地板）。 FitText 按规则正确工作；如果嫌"长名 8→7 跳档太狠"，
  候选微调：限宽允差 ±1px / 0.5px 步进（玩家没抱怨前不动）。

#### 3.27 背包两轮：更新触发补强 + 暴雪框预停车（2026-10-28，`51e07b2`）

**更新不及时**（玩家报"邮件/商人后窗口停在旧内容"）：

- 三层触发：① 事件补强（`ITEM_COUNT_CHANGED` / `LOOT_READY` /
  `UNIT_INVENTORY_CHANGED(player)` / `PLAYERBANKSLOTS_CHANGED`→银行直达、
  `PLAYER_ENTERING_WORLD` 强制重扫）；② 公开 `M:Refresh()` + `/mui bags refresh`；
  ③ 开窗期 **0.5s 签名轮询**（每槽 `itemID×数量` 指纹，变了才重建）——"及时"最终不赌
  事件派发。
- **资源口径（探针实测）**：`CURSOR_CHANGED` 本客户端 **×298 高频刷**，挂进 Mark 等于
  窗口开着时每次光标变化全量重建 → **已移除**；`BAG_UPDATE_COOLDOWN` ×184（只管冷却，
  不注册是对的）。驱动器帧级合并（比 qianwen 参考代码的 0.1s `C_Timer.NewTimer` 紧），
  `pending`/`pendingBank` 双通道。
- qianwen 参考代码的死代码：`PLAYERREAGENTBANKSLOTS_CHANGED`、`NUM_BAG_SLOTS`
  本客户端**都不存在**（照抄会 nil 报错）。

**两套同屏根治（预停车 + 边沿检测）**：

- **实机探针定案**：按 B 开背包，`BAG_OPEN`/`BAG_CLOSED`/`BAG_UPDATE` **全部不发**
  （事件在快照里存在但这条路径不派发）——"开背包"在事件层是静默的，`IsShown` 边沿是
  唯一信号，事件驱动方案作废。
- 旧方案（守卫见到显示的就 `Hide()`）两代价：Show→Hide 之间有可见闪帧；暴雪更新逻辑
  再 Show 回来跟守卫打拉锯。
- **新方案**：Initialize 即**常驻停车**——alpha 0 + 全子树禁鼠标（`parked` 弱键旁表记账，
  含 `mouseSet` 防重复）。暴雪 Show 照样成功但不可见不收鼠标；**没有 Hide 这一刀，拉锯
  不存在**。`SetAlpha`/`EnableMouse` 非受保护调用，战斗中可用，不写字段。
- 守卫改**边沿检测**：上升沿 = 开我们的窗（`Toggle(true)`）、下降沿 = 关（`Toggle(false)`），
  **不再 toggle**（回光返照反复切的根）；`bankOpen` 期间边沿让给银行路径；漂移回压
  （alpha/鼠标被暴雪重设就补一刀）。
- **晚生子框判例**：开背包时暴雪**现建** ItemButton（树从几框涨到 187 子框、85 个鼠标
  开着）→ tooltip 冒出来。**alpha 沿树继承但鼠标状态不继承** → 扫描器对显示着的框每拍
  整树补禁（不显示收不到鼠标事件，不用管）。实测 mouseOn=0。
- `BlizzardBagFrames` 补了 `BackpackTokenFrame`。
- 实机验证：按 B 只出我们的窗（零闪帧）、再按 B 关、悬停无 tooltip、点击穿透、
  全程 **0 BLOCKED**。
- 附带发现：任务/对话窗口开着时按 B 会被吞（零事件零反应）——不是插件问题，测背包
  前先关 NPC 对话框。

### 3.28 姓名板：暴雪牌压制补全（2026-10-28，`7d012f4`）

玩家报"暴雪姓名板没藏掉、和自绘的同屏，右侧减益列还在"。探针实锤**两层根因**：

1. **base 级 sibling 容器漏网**：压制只盖 `base.UnitFrame`（alpha 0），但 base 上还有
   同级容器（StatusBar+Frame 一族，alpha 1.00，随 base 的距离衰减 alpha 0.60 可见），
   有减益时暴雪还**动态再建**容器（BuffListFrame 一族）。alpha 沿树继承救不了它们。
   修：`HideBlizzardPlate` 压暗 base **全部子框**（除自绘牌）；`KeepBlizzardHidden`
   每拍整树回压；`RestoreBlizzardPlate` 全部放回。`SetAlpha` 非 `Hide`，C++ 点击区
   （锚在血条/名字上）不受影响。
2. **目标高亮回压缺口**：牌子成为**当前目标**时暴雪把 UnitFrame alpha 重设回 1
   （base 同到 1.0），我们的回压只在事件驱动的 `UpdatePlate` 里 —— 暴雪抢先后无人再压
   （探针：假人牌 `blizzardHidden=true` 但 `ufAlpha=1.00`）。修：`PLAYER_TARGET_CHANGED`
   即时回压 + **0.25s 低频守卫**扫全部已接管牌整树回压。

- 误判记录：base 上的 StatusBar+Frame 匿名子框一度被当成"暴雪施法条"，实为**我们的
  自绘牌**（血条 StatusBar + 施法框结构吻合）——探针时先数结构再下结论。
- 实机：压住了（目标牌不再亮、减益列消失）。`BuffListFrame` 已知问题随之闭环。
- 排查手法沉淀：`_G.MonetUI = ns`（Core.lua:977）——探针可以直接 `ns:GetModule("Nameplates")`
  读模块内部状态（`Marked(base,"plate")` / `M:ShouldShow` / 设置表），比纯 `_G` 猜快得多。

---


## 4. 污染（taint）模型 —— 这个客户端最贵的一课

完整版在 `AGENTS.md` 的「污染（taint）模型」一节，这里只列**判断用的最短版本**：

1. 本客户端按**键**判污染：插件只要往暴雪对象上**写过一个 Lua 字段 / 脚本槽 / 方法槽**，
   这个对象之后跑的暴雪代码就全算"以 MonetUI 的名义执行"。
2. 于是要么**暴雪自己的调用被拒**（`ADDON_ACTION_BLOCKED`），要么**机密值比较直接抛错**
   （`attempt to compare ... (a secret number value, while execution tainted by 'MonetUI')`）。
3. 污染会**跟着调用链往下走一圈**：同一条 `EnterEditMode`/`OnEvent` 栈里，我们那一段之后的所有
   暴雪代码都是脏的 —— 所以"改一个小地方，报错出现在完全不相干的模块里"是常态。
4. 所以：**簿记一律走旁表**（`ns:Mark(obj, key, value)` / `ns:Marked(obj, key)`，在 `Core.lua`，
   以对象为弱键）；**不写字段、不挂脚本、不 hook 方法**，要"跟随状态"就轮询
   （`Widget:HoverWatch` / `ShowWatch` / `PollWatch`，本客户端没有 `MouseIsOver`/`GetMouseFocus`，
   用 `frame:IsMouseOver()`）。
5. 诊断两板斧：
   - `issecurevariable(obj, "字段")` 逐键扫，`false` 就是脏键（**只有重载能变干净**）；
   - `C_CVar.SetCVar("taintLog","2")` → 重载 → 客户端写 `<游戏目录>/Logs/taint.log`，
     里面有被拦调用的完整栈和归属。**注意它只在加载时按 CVar 决定是否打开**，运行中改 CVar 无效；
     读完关回 `0`（有开销）。

---

## 5. 这个客户端的行为速查（12.1.5.70575）

| 事实 | 影响 |
|---|---|
| 没有 `MouseIsOver` / `GetMouseFocus` | hover 一律 `frame:IsMouseOver()` + 轮询 |
| 没有 `PetActionBar_UpdateCooldowns` 全局 | 宠物条冷却用 `PetActionBar:UpdateCooldowns()` 每 0.5s 驱动 |
| 没有通用安全按钮的 `type="pet"` / `SecureHandlerClickTemplate` | 宠物条**必须收养**暴雪 `PetActionButton1..10`（实测自绘 `type=pet` 点了没反应，0 拦截） |
| `Cooldown:GetCooldownTimes()` 返回**毫秒** | 和 `GetTime()` 混算会得出 568 天那种鬼数字 |
| 0×0 的框体 `GetLeft()` 返回 nil | 锚在"可能为空"的行上 → 整行隐形 |
| 战斗中光环数据会被标密，`C_UnitAuras.GetAuraDataByIndex` 直接抛 | BuffFrame 战斗中切到引擎 `AuraContainer`（**必须在脱战时建好**） |
| `NamePlateDriverFrame:UpdateNamePlateOptions` 是姓名的"生产入口" | 不能 hook（见 3.2） |
| 编辑模式读 `MinimapCluster:IsInDefaultPosition()` 和 `:GetBottom()` | 不能改、不能搬集群（见 3.1） |
| 暴雪 HUD 帧（任务追踪、冷却管理器、BuffFrame…）多在 **LoD 包**里，且加载时可能**换一个新的框对象** | "藏一次 + 盯 OnShow"必漏；要 `ADDON_LOADED`/进世界/换区域/数据刷新各补一次，并加低频兜底 |
| `SetAlpha(0)` 的框"仍然算显示"，`Hide()` 会被暴雪的 `Show()` 顶回来 | 收 HUD 用 alpha，不用 Hide（否则一闪一闪） |
| 暴雪花在屏幕上的**动作条 / 团队框 / 小地图集群**都是受保护的 | 只 alpha / 关鼠标；`SetParent`、`SetScale`、写字段都会引发连锁 BLOCKED |
| 已知无害噪音 | 每次重载 10 条 `PetActionButton*:SetShown` BLOCKED；偶发 `MainActionBar:SetPointBase/ClearAllPointsBase`（都是我们换父/改 alpha 的代价，不弹窗、功能正常） |

---

## 6. 验什么、怎么验

### 6.1 有 wuxian MCP 时（opencode 时代就是这么干的）

```
tools.wuxian.status()                     # link.state 必须 online（游戏在世界里、没最小化）
tools.wuxian.check({target="MonetUI", live=true})   # 0 error 才继续
powershell -File tools/deploy-retail.ps1
tools.wuxian.reload({reason="..."})       # 弹出重载按钮，玩家点
tools.wuxian.run({code="..."})            # 在游戏里跑 Lua，返回 values
tools.wuxian.logs({since=0, limit=300})   # ERR / BLOCKED / RELOAD / RUN
tools.wuxian.snap({region={0,0,400,200}}) # 截图（region 是客户端像素）
tools.wuxian.try({code="...", events="..."})  # 一次动作 + 收 2 秒内的一切
```

常用探针（**返回值里只要有可能是机密值，就必须先 `issecretvalue` 再 tostring**，否则
`table.concat` 会报 `invalid value (secret)`）：

```lua
-- 脏键扫描
local function scan(o, label)
  local bad = {}
  for k in pairs(o) do
    if type(k) == "string" then
      local ok, secure = pcall(_G.issecurevariable, o, k)
      if ok and secure == false then bad[#bad+1] = k end
    end
  end
  return label .. (#bad == 0 and " clean" or (" DIRTY: " .. table.concat(bad, ",")))
end
-- 安全 tostring
local function V(v)
  if v == nil then return "nil" end
  local ok, sec = pcall(_G.issecretvalue, v)
  if ok and sec then return "<SECRET>" end
  return tostring(v)
end
```

### 6.2 没有 MCP 时（Codex 侧的手动版）

1. `node tools/api-audit.js` —— 离线能做的第一道闸（HARD 项 = 名字/事件/枚举对不上客户端快照）。
2. 拷贝：`robocopy` 仓库到 `Interface\AddOns\MonetUI`（`tools/deploy-retail.ps1` 就是干这个 + 改 toc 的 Interface）。
3. 游戏内 `/console scriptErrors 1`，`/reload`。
4. 看报错：`/dump` 手打探针；或退出后读 `Logs\taint.log`、聊天框里的红字。
5. 截图对比：游戏内 `PrintScreen`，或让玩家发图。

### 6.3 本轮之后最该过的实机清单

- [ ] 进/出编辑模式 3 次：无 `oldR`、无 `ADDON_ACTION_BLOCKED`（**已验过一轮，回归也要看**）
- [ ] 有队友时：自绘小队框正常；暴雪的若露出来，玩家自己在编辑模式里设隐藏
- [ ] 姓名板：打有读条/有 debuff 的怪 5 分钟，无 `maxHealth` / `notInterruptible` / `isFullUpdate`
- [ ] buff/debuff：有时长的 buff 显示 `6m`/`45` 这类正常读数；**proc 行为空时 debuff 行仍在**
- [ ] 小地图：位置/尺寸/矩形遮罩/面板/三个按钮/四角打标记/右键菜单/滚轮缩放；**编辑模式里拖小地图不再影响我们的位置**
- [ ] 任务追踪：只剩自绘那一块（换地图、接任务、重载后再看）
- [ ] 动作条：1–8 号条施法/翻页/拖放；宠物条左右键/冷却/自动施法；姿态条三个形态能点、位置贴 3 号条、`/reload` 后不变
- [ ] 未动的模块各看一眼：Bags、InfoBar、Tooltip、Cursor、Toast、Durability、CombatText、Skins 各窗口

---

## 7. 代码地图（改动前先看这里）

| 路径 | 职责 | 雷区 |
|---|---|---|
| `Core.lua` | SavedVariables、模块注册/生命周期、主题管线、`ns:Mark/Marked`、`/mui` 命令 | `_G.MonetUI = ns`（831 行），模块用 `ns:Register(name, M)` |
| `Utils/Secrets.lua` | 机密值层：`Number` / `Bool` / `SetBar` / `CanReadAuras` / `Measure` | 所有暴雪数值先过它，别自己 `tonumber` |
| `Utils/Widget.lua` | 建帧 / 主题 / 字体 / 冷却 / `HoverWatch`·`ShowWatch`·`PollWatch` | `PollWatch` 现在一个框多回调；轮询锚点用**各自的帧**，别都挤 `UIParent` |
| `Utils/Skin.lua` | 窗口装饰引擎、`CropIcon`、页签 | 只装饰，不挂脚本 |
| `Utils/EventBus.lua` | 事件总线（懒注册） | 回调第一个参数是事件名 |
| `Utils/Mover.lua` | 位置/吸附/战斗锁 | 战斗里不要挪受保护帧 |
| `Utils/Compat.lua` | 客户端能力自查（`/mui compat`）：跨客户端的假设清单 | 表里每条是**假设**不是结论；换客户端先跑它，别把 retail 的实测当 1.60 的 |
| `Modules/ActionBars/ActionBars.lua` | 8 条自绘安全按钮 + 宠物条/姿态条收养 + 拖放接住器 | `action` 等点击属性只能由**安全片段**写；`PickupAction/PlaceAction` 必须脱战；收养来的条（`IsAdopted`）不进图标/冷却/绑定/布局那几套循环 |
| `Modules/Cooldown/Cooldown.lua` | 冷却数字渲染 + 暴雪冷却管理器收掉 | 只处理我们自己的冷却框；`GetCooldownTimes` 是毫秒 |
| `Modules/BuffFrame/BuffFrame.lua` | buff/proc/debuff 三行 + 战斗中引擎兜底 | 行位置按行高算，别锚空行 |
| `Modules/Nameplates/Nameplates.lua` | 姓名板细条 | 绝不 hook 驱动框 |
| `Modules/Minimap/*` | 矩形小地图、按钮、pin、微型菜单 | 集群不动，只搬 `Minimap`；`GetMinimapShape` 是我们给第三方提供的约定全局 |
| `Modules/QuestTracker/QuestTracker.lua` | 自绘追踪 + 压制暴雪追踪 | 暴雪追踪是 LoD + 会换对象 |
| `Modules/UnitFrames/*` | 单位框 / 小队团队 | 暴雪的 Group 框**完全别碰** |

> `Modules/UnitFrames/` 已按子系统拆开（都是 move-only，2026-10-25/26）：
> `UnitFrames.lua`（主文件，配置/建框/刷新/事件）+ `Auras.lua`（`M.auras.*`）+
> `CastBar.lua`（`M.castbar.*`）+ `ClassPower.lua`（`M.classpower.*`）+
> `Blizzard.lua`（方法仍是 `M:SuppressBlizzard` / `M:HideBlizzardCastBars`）+ `Groups.lua`。
> **子文件要用主文件的局部函数，必须显式挂在 `M` 上**（漏一个 = 初始化静默失败、整模块的框全没）。
| `Modules/Skins/*` | 暴雪窗口美化（含 `Forever.lua` 客户端专属） | 不给里面的按钮/页签挂钩子 |
| `Config/SimpleConfig.lua` | 配置面板（滚轮滚动） | — |
| `tools/` | 部署、API 审计、材质生成、像素审计、taint 闸门 | 材质改完必须 `node tools/audit-pixels.js`；commit 前跑 `node tools/audit-taint.js`；**部署后跑 `node tools/sync-check.js`**（仓库↔已安装副本，MISSING/STALE/EXTRA） |
| `docs/api/` | 本客户端 API 快照（**效力高于 hated-wow MCP**） | `node tools/api-lookup.js <名字>` |
| `.opencode/skills/` | 项目级 agent skill | `wow-secret-value-taint-audit`（秘值/taint 审查，含三起实机案情档案）与 `wow-petbar-autocast-pixel-glow` |

> 另：宠物动作条"自动施法"像素环的完整实现要点（参数、`Widget:PixelGlow`、为什么要替掉暴雪的
> `AutoCastOverlay.Shine`）在 **`.opencode/skills/wow-petbar-autocast-pixel-glow/SKILL.md`**。
> Codex 不会自动加载它，需要时直接读这个文件。

> **加载结构（2026-10-26 起）**：`MonetUI.toc` 不再逐个列 `.lua`，只列**每个子模块的一份 xml 清单**
> （`Libs/Libs.xml`、`Utils/Utils.xml`、`Config/Config.xml`、`Modules/<模块>/<模块>.xml`；
> 单文件模块如 `Modules/Tooltip.lua` 直接在 toc 里列）。组内加载顺序写在 xml 的 `<Script file>` 里，
> 组间顺序 = toc 里的顺序。**加文件就加到对应 xml**，别只在某处 `dofile`；`wuxian check` 会顺着
> toc → xml 找文件，漏挂会报 `not-loaded` 而不是静默跳过。改这块之后照例跑
> `node tools/api-audit.js`（会校验 toc 列的 xml 是否存在）+ `wuxian check`。

---

## 8. 约定（作者定的，别自作主张）

- **不 push 远端**（游戏上线 + 初步测试前）；`origin` 只作私有备份，仓库必须保持 private。
- **参考插件只读**：`../Andromeda`、`../EllesmereUI-v9.4` 只能读，不能改、不抄大段代码。
- **资源全部自绘**，不引外部贴图 / 第三方库（防 GPL 污染）。
- 小步改动、可回滚；不顺手重构无关代码；每个修复点单独 commit（中文标题，写清"为什么"）。
- 多行文本替换用 `split(/\r?\n/)` + `splice`，**不要** `string.replace()` 做多行匹配（本仓混用 CRLF/LF）。
- 大段输出先 grep 定位再定点读，别把 147KB 的 `MonetUI.md` 整篇塞进上下文。

---

## 8.5 2026-10-28 素材线 + 圆角（本轮收档）

**这一轮只动了素材与视图层，没碰任何 game API 调用。**

### 素材目录变了（重要）

```
Assets-src/Textures/*.tga   源：进 git、**不发行**（audit-pixels / regen / svg-to-tga 的输入）
Assets/Textures/*.blp       交付：进游戏（由源同步生成）
```

- 游戏目录里**只有 BLP**，消除"引擎读哪个格式"的歧义。`tools/deploy-retail.ps1` 不用改（只拷 `Assets`）。
- `node tools/regen-textures.js standard` 与 `node tools/svg-to-tga.js` 都会**自动同步 BLP**；
  单张手转：`node tools/tga-to-blp.js <tga>`（源目录里的 TGA 默认输出到 `Assets/Textures`）。
- BLP 三条硬要求（`tools/tga-to-blp.js` 内置）：完整 **mip 链**、mip 逐级**白衬底修正**、
  剔除 raw3 用不到的 1024B 调色板块。滤波用 `triangle`（唯一不过冲的）。
- 清理：删了 6 张死素材（canvas_weave / diagonal_weave / minus / plus / search / win_restore）
  与 3 个 `*_blp` 别名键、`Widget.lua` 的 `blpKey` 死字段。

### 素材画法重做（照参考插件 Andromeda）

- **斜纹**（`monet_stripe_weave`）：4px 周期、剖面 `255→129→0→129`、覆盖率 50%（原来是单像素点阵 17.5%）。
- **图标字形**：笔画 = 画布 × 0.115、字形占 88%（原来固定 2px / 55%）；`check`/`chevron`/`arrow`/
  `radio`/`win_*` 全部重画；role 三张改成**实心剪影 + 径向渐变 + 内沿压暗**（heal 改十字、dps 改并排双匕首）；
  关闭钮三态与小地图三徽章（SVG）加粗简化。
- **审计口径同步修**：45° 粗笔画交汇处的零星半透明像素不再判"软边未对齐"（改为中段多数发虚才算），
  并用一张人为错位的测试图确认真实错位仍会被抓住。

### 圆角（新功能，实机未验）

- `edgeFile` 在本引擎不可用，圆角是**自绘 9-slice**：4 角（原尺寸）+ 4 边（拉伸）+ 4 块
  `monet_round_fill` 填充压在下层补方底。实现：`Widget:RoundBorder`（Utils/Widget.lua），
  染色并入 `Widget:Refresh`。
- 圆角纹理 32×32、外弧 8、角部**曲率线性渐变**（欧拉螺线，G2 连续）。曲率剖面：圆弧 0→0.50 阶跃、
  超椭圆 0.01→0.36、螺线 0.01→0.24。切片 `slice = 8`，`Widget.lua` 的 `ROUND_EDGES` 与
  `tools/regen-textures.js` 必须同步。
- 接入：小地图面板、任务追踪、配置面板、微型菜单（`round = true`）。

### 待实机验收（下次开工先做这三条）—— 2026-10-29 已验，结论见 8.5.1

1. **圆角**：1× / 1.25× UI 缩放下四角是否仍对齐（1 纹素 = 1 UI 单元的映射）、
   小地图面板圆角与矩形遮罩之间那圈缝、Config 面板 2px 环的观感。
2. **BLP 与 TGA 显示一致**：9-slice 边框、`IconTexture` 图标、小地图遮罩 1:1。
3. **图标可读性**：`/mui` 里 check/radio/箭头/role 在实机尺寸下的辨识度（离线对照见
   `docs/texture-preview/glyphs-before-after.png`、`svg-glyphs-before-after.png`）。

### 本轮 commit

`d5c242d` 素材迁移+重出+重画 · `7d207e3` 注册键清理 · `5ca1f54` 规范文档 ·
`7f42c5b` 圆角功能+资产 · `14b0d83` 圆角文档

### 8.5.1 2026-10-29 实机结论：BLP 的 `alphaType` 是元凶，圆角改回直角

**一句话**：第 2 条（BLP 与 TGA 显示一致）**不过**，但问题不在像素、在一个头字段；第 1 条（圆角）
判定"视觉不通过"，交付改为**直角版 BLP**；第 3 条（图标可读性）随 alpha 修复一并解决。

#### 元凶：BLP2 头的 `alphaType = 0`

`wow-blp-web 0.7.2` 给 raw3 **固定写 `alphaType=0`**（`alphaBits`/`hasAlpha` 选项对 raw3 无效，
四种组合实测头字节一模一样）。这个客户端的加载器认这个字段：`alphaType=0` = **无 alpha**，
整张图按不透明画。于是四个"互不相干"的缺陷是同一个原因：

| 实机现象 | 真相 |
|---|---|
| 图标 / 关闭钮全是实心小方块 | 透明区被当不透明 |
| 小地图是正方形、"遮罩失效" | 遮罩透明区失效，上下两条带没被裁掉 |
| 圆角处一小块方块 | 圆环弧**外**的透明区变实心 |
| 动作条"不是清晰斜纹" | 斜纹的 alpha 明暗被抹平，只剩白底 |

取证：同机真实素材 `NDui/Media/bgTex.blp`、`Andromeda/assets/textures/bag/bag-config.blp` 的无压缩
BLP 都是 `enc=3 alphaDepth=8 **alphaType=8**`；我们 32 张全是 `alphaType=0`。修法：`tools/tga-to-blp.js`
编码后强制写 `alphaDepth=8 / alphaType=8`（只对 raw3），输出里会打印 `alphaType=8`。

> **纪律**：转换器"成功"不等于客户端能画。任何新增/重出的 BLP，先看头 4 个字节
> —— raw3 带透明必须是 `enc=3 / alphaDepth=8 / alphaType=8 / mips=1`。

#### 圆角：必须做成 9-slice 背景，不是"补块"

- `SetBackdrop` 的方底角点落在 8 半径外弧的**外面**；任何"填充块"只能画在弧内，**几何上盖不住**方角。
  旧实现（`monet_round_fill` 当补块）方向就是错的，公式还写成了 1px 描边（用了无符号距离）。
- 正解：方底内缩到 slice(8)，外面那圈由 4 块实心圆角 + 4 条背景色边条补齐，三者不重叠。
  该实现留在 `main@6e233ed`（含遮罩 `rx=6`、填充生成器改有符号距离），**未交付**，仅留档；
  要重试圆角从那个提交起。

#### 交付：直角版 BLP

- 分支 `square-blp`，`44a4334`（基线 `6288692`）：四处 `Widget:Theme` 去掉 `round = true`，
  遮罩回 `rx=0`，32 张 BLP 全部按 `alphaType=8` 重出。
- 门禁：`audit-pixels` 未通过 **0/32**、`luac -p` 5 个改动文件全过、mip0 与 TGA **逐像素一致**。
- 部署目标：`...\Blizzards\WOWFOREVER\World of Warcraft\_retail_\Interface\AddOns\MonetUI`。
  `tools/deploy-retail.ps1` 的默认 `-Dest` 指向旧的 `Blizzards\World of Warcraft`，**必须显式传 `-Dest`**。

#### `tools/` 已入库（2026-10-30 起）

以前 `.gitignore` 排除了整个 `tools/`，闸门脚本与材质生成器只活在某一台机器上——换机/重装即丢。
现在改成**只排除生成物**，脚本全部入库（54 个文件，约 500 KB）：

```
tools/*
!tools/*/            # 允许进子目录
!tools/**/*.js  !tools/**/*.mjs  !tools/**/*.ps1
!tools/**/*.py  !tools/**/*.svg  !tools/**/*.html  !tools/**/*.lua
```

于是 `api-audit.js` / `audit-taint.js` / `audit-locals.js` / `sync-check.js` /
`api-fetch.js` / `regen-textures.js` / `tga-to-blp.js` / `svg-to-tga.js` /
`deploy-retail.ps1` / `tools/svg/*.svg` 都跟着仓库走。
上面 1–3 三条"必须手工同步"的历史遗留因此作废。

仍然不进库的：`node_modules/`、`*.json`（`package.json` 例外除外，见下）、
`docs/api/` 快照、`docs/texture-preview/` 预览、`.opencode/`。

> `package.json` / `package-lock.json` 被 `*.json` 排除，但它们是 `tools/` 的运行前提
> （`@napi-rs/canvas`、`wow-blp-web`）—— 换机 `npm install` 需要它们，必要时单独白名单。

---

## 8.6 2026-10-30：条填充材质（剖面烤进贴图）+ 按 review 计划收掉 P0/P1

### 8.6.1 条填充：两张剖面贴图，按条高自动选

**结论先说**：状态条的填充不再是"扁平材质 + 运行期 `SetGradient`"，改成**剖面烤进贴图**；
细条另有对称之外的"上亮下暗"版本。开关只有一个：`Utils/Widget.lua` 的 `THIN_BAR_MAX`。

| 贴图 | 剖面 | 用在哪 |
|---|---|---|
| `monet_barfill_gradient` | 单向：顶 124 → 中下 205 → 底缘收边 141 | 条高 > 6px（玩家/目标/焦点血条、姓名板施法条…） |
| `monet_barfill_thin` | 单向：顶 240 → 底 112，指数 0.40（亮区占大头，暗只压底缘） | 条高 ≤ 6px（姓名板血条、能量条、职业资源） |

- 两张都是 **64×64、纯灰、无 alpha**，竖轴（v）由 StatusBar 映射到条高，所以任何高度都是同一条剖面。
- `Widget:BarFillTexture(height)` 是唯一的选择点；姓名板每次重排按当前高度重设，面板改高度立即生效。
- **走这两条路径时不要再叠 `Widget:BarGradient`**：运行时渐变会和贴图相乘，等于双倍压暗。
  传 `textureKey = "monet_barfill"` 才回到老路子（扁平材质 + 运行期渐变）。
- 两张图都在 `tools/regen-textures.js` 里（gradient 的 64 行剖面按实测值固化成常量，
  重出素材不会漂）：改完跑 `node tools/regen-textures.js standard monet_barfill_thin`。
- `audit-pixels.js` 两张都 PASS（色相 0 / 衬底 0 / 孤立 0）。
- **回退**：`THIN_BAR_MAX = 0` 全部回到单向剖面；再把 `Widget:BarFillTexture` 改成返回
  `"monet_barfill"` 就回到"扁平 + 运行期渐变"的老视觉。

### 8.6.2 P0/P1 收档（29 + 5 个提交，每项可单独 revert）

按 `docs/REVIEW-2026-10-29.md` / `docs/PLAN-refactor-2026-10-29.md` 执行，逐项清单在 `TODO.md`。
闸门全程：`api-audit` 0 HARD、`audit-taint` 0/0/0、`wuxian check(live:false)` **0 error**
（原基线那 1 条 `BossFrames.lua:246 TargetUnit` 已清）。

值得记住的几条：

1. **`C_ActionBar.GetActionDisplayCount` 返回 string**，以前判 `number` 所以动作条堆叠数从来没显示过；
   机密串的 `type()` 照样是 `"string"`，判完类型必须再过 `issecretvalue`。
2. **`showHotkey` / `showCount` / `showMacro` 三个配置键全仓没有读取点**（面板勾了不生效），已接线。
3. **暴雪经验条 / 追踪按钮父框**都从 `Hide()` 改成 `alpha 0 + EnableMouse(false)`（AGENTS 的 HUD 规则），
   并补了 `InfoBar` 装饰的 `remove` 钩子，关模块时还原。
4. **不再覆写暴雪 `Minimap` 的 `OnMouseUp`**：覆盖层本来就独占左右键。
5. **BossFrames 必须用 `SecureUnitButtonTemplate`**（`*type1=target` / `*type2=togglemenu`）；
   它原本依赖的 `Groups.StyleButton` 是文件局部函数，从没导出 → `StyleReady()` 永远为假。两处都已修。
6. **姓名板仇恨状态**：机密时保留上次判定，普通 nil 按 0 —— 否则战斗中红边一直闪灭。
7. **宠物条自动施法像素环**曾被 `STYLE_ADOPTED_BARS=false` 静默关掉（那开关出自 10-24 的旧判决），已恢复。
8. **`/mui reset` 现在要 `/mui reset confirm`**，并且就地清空 + 补默认值（以前重置后开面板报 `index nil`）。

### 8.6.3 还没做 / 仍需实机

- P2.1 统一 OnUpdate 调度器、P2.3 `ns.Mark` 下沉、P2.5 `FitText`/`SetBorderColor` 常量、
  P2.6 `Skin.tinters` 注销句柄；P3（配置面板拆分）、P4（ActionBars 拆分）、P5、P6、P7。
- **P0.20 待取证**：`Modules/UnitFrames/Blizzard.lua` 对 `PlayerFrame/TargetFrame/…` 的
  `SetScript("OnShow", Hide)` + `Hide()` 压制方式，是否仍是 10-25 消除 `UNKNOWN()` 的必要手段
  （要开 `taintLog=2` 跑一次战斗进出对比）。
- 实机清单见 `TODO.md` 的"必须实机复核"一节（9 条）。

### 8.6.4 宠物条收尾（2026-10-30 定稿，全部实机核对过）

**外观参数**（`Modules/ActionBars/PetBar.lua`，改这几个数即可）：

| 项 | 值 |
|---|---|
| 条高 | `PET_HEIGHT_RATIO = 0.75`（按钮 28×21，宽度不变） |
| 图标裁切 | `0.1 / 0.9 / 0.13 / 0.87`（照 Andromeda `bars/pet-bar.lua:33`），竖向再按 0.75 压一次 → 不拉伸 |
| 像素环 | `count 6`、`pixel 4`、`spacing 4`、`period 1` 秒、颜色 `0.35 / 1.0 / 0.45`（绿） |
| 自动施法信号 | **只**用像素环（边框回归主题，不再染 highlight） |
| 当前生效宠物动作 | 自绘金色蒙版 `(1, 0.8, 0, 0.35)`（替掉被压掉的暴雪 `CheckedTexture`） |
| 「可自动施法」角标 | 12×12、右下 +2/−2、整幅贴图（照 `pet-bar.lua:19-21`） |
| 暴雪美术层 | `FadeAdoptedArt` 压掉 11 层（含 `SlotArt`、`CheckedTexture`），2 秒一次低权重压兜底 |

**这一轮修的三个坑**（都是实机证据）：

1. **图标"裁不动"**：不是 `SetTexCoord` 失效，是 `ActionButtonTemplate` 的 `.icon` 被
   `IconMask`（atlas `UI-HUD-ActionBar-IconFrame-Mask`，`SmallActionButtonMixin_OnLoad` 固定
   45×45）套着 —— 裁切改了采样区，那圈"图标框"照旧画出来，而且比我们 28px 的按钮还大。
   现在 `Texture:RemoveMaskTexture` 摘掉（摘不掉就把遮罩缩到按钮大小兜底）。
2. **`PetAutoCastEnabled` 取错值**：`pcall` 后数了 6 个占位符，拿到的是 **spellID** 而不是
   `autoCastEnabled`（正确顺序 name, texture, isToken, isActive, allowed, enabled）——
   所以"有 spellID 就发光"。改成 `PetActionState` 一并返回 `isActive / allowed / enabled`。
3. **暴雪经验条又冒出来**：`SetAlpha(0)` 接管本身对，但兜底用了 `ShowWatch`（**沿触发**）——
   暴雪把 alpha 写回 1 时框一直显示着、沿不触发。改成 1 秒一次的低频重压
   （`ReinforceBlizzardXP`，幂等、按全局名查、模块关掉就停）。

**新增闸门**：`tools/audit-locals.js` —— 扫全仓"裸调用但本文件没定义"的 local
（Mark/Marked/Media/Widget/Color/Secrets/EventBus/Mover/Skin/Math）。起因是
`PetBar.lua` 用了主文件的 `local Mark` → `PetBar.lua:83: attempt to call a nil value`，
整个 ActionBars 模块初始化失败、暴雪默认动作条冒出来，而 `wuxian check` 与 `api-audit`
都判不出这类错。已用"故意删掉那行"验证它会报错。

**推送状态**：截至 2026-10-30 收尾时本机到 `github.com:443` 的 git 连接被重置/超时
（`Test-NetConnection` 通、`git ls-remote` 不通；`gh` 未安装；`~/.ssh` 无密钥；
本机 8080 不是可用代理）。所以**这一轮 300+ 个提交只在本地**。联网后二选一：

```powershell
# A. 只备份分支（最安全，main 不动）
git push -u origin square-blp

# B. 把 main 快进到 square-blp 再推（square-blp 是 main 的超集，可 ff）
git checkout main
git merge --ff-only square-blp
git push origin main
git checkout square-blp
```

推送前照 AGENTS 的规矩确认远端仍是 **private**（转公开要等游戏上线且初步测试通过）。

---

## 8.7 2026-10-30 姓名板：机密值前置审查（`Modules/Nameplates/Nameplates.lua`）

按 `.opencode/skills/wow-secret-value-guard-audit` 跑一轮（定位器：`scan-secret-guards.cjs Modules/Nameplates`），
人工复核后改了 6 处。**这一轮没有实机证据**（游戏没开，`wuxian check` 需要游戏目录），
全是静态判定；实机回归请连着 8.6.2 一起做。

| # | 位置 | 原写法（会被拦） | 现在 |
|---|---|---|---|
| 1 | `UpdateHealth` 血量 | `hp ~= nil and hpMax ~= nil` | 先 `IsSecret` 判，机密走 `SetBar` 透传 |
| 2 | `UpdateHealth` 连接态 | `if connected == nil then` | `not IsSecret(connected) and connected == nil` |
| 3 | `UpdateCast` 施法条上下限 | `startMS or 0` / `endMS or 1` | 零值兜底只对非机密做，机密原样给 widget |
| 4 | `CastTick` | `if not plate.castEndMS then`（每帧真值测试机密） | 改存"有条在走"的普通布尔 `plate.castActive` |
| 5 | `UpdateText` 等级段宽度 | `if levelW > 0` | 加 `type` + `IsSecret` 两道（`GetStringWidth` 会变机密） |
| 6 | `Added` / `Removed` 令牌入口 | 直接 `plates[unit]` | `type(unit) ~= "string" or IsSecret(unit)` 前置 |
| 7 | `ApplyPlateSize` 保存原尺寸 | `savedPlateSize = { w, h }` | 机密不存（否则 Restore 只能原样传一串读不出的值） |

要点：**1 和 3 是本轮 ×8 的同族形态** —— 值本身是机密（pcall 成功、不是 nil），
`~= nil` / `or` 这类看起来"无害"的兜底判断就是被拦的那一句。4 是隐匿型：`castEndMS` 存的是
**原始 endMS**，机密时 `CastTick` 每帧真值测试一次，量级大且只进日志、不弹窗。

定位器残留（用 `~/.qoder-cn/skills/` 那份复跑，快照做生产者过滤器后全仓 80 条）：姓名板只剩 1 条
`:74` `OnOff(value)` ← 值来自 `GetCVar`（CVar 不机密），**不必改代码**。
（早先装的旧版脚本还会多报 `opaque` / `enabled and true or false` 这类自家人；旧版没有"名字在不在快照里"
这层过滤，所以 208 条噪音 —— 见 `docs/CODEX-SETUP.md` 6 节的同步规矩。）

闸门：`luac -p` 0、`api-audit` no hard finding、`audit-taint` 0/0/0、`audit-locals` 全过；
`check-frame-list` 仍报 21 个（`skins/System|Trade|WorldMap` 的帧名）——**改动前就是 21 个**，
属于 8.6 那批皮肤 WIP，与本次无关。

### 8.7.1 同一轮的另外三处（全仓扫描的 SUSPECT 归零）

- `Modules/Tooltip.lua` Alt 法术 ID：`if ok and spellID ~= nil` 写在 `Secrets.Number(spellID)` **之前**
  —— 受限时 `GetSpell` 返回的是机密数字，这句比较就是被拦调用（pcall 的 `ok` 是普通值，被 pcall 的
  返回值不是）。改成 `local n = ok and Secrets.Number(spellID) or nil`。
- `Modules/InfoBar/Blocks.lua` 已关注货币：`not info.isHeader and info.isShowInBackpack` 是两次
  机密布尔真值测试（`UNKNOWN()` 一族），改走 `Secrets.Bool`；`name` 的 `IsSecret` 保持原位。
- `Modules/InfoBar/XP.lua` 暴雪经验条低频回压：`alpha > 0.01`（`GetAlpha` 会返回机密数）改成
  `keep = ok and not IsSecret(alpha) and alpha ~= nil and alpha <= 0.01`，顺序即语义；
  同一段里的 `IsMouseEnabled` 结果也过 `Secrets.Bool`（帧的鼠标状态读回来同样可能机密）。

> 判例补充：本仓 `Utils/Tooltip` 一侧已有 `Plain()` 兜底（`nil` 与机密都返回 nil），所以
> 它下游的 `name ~= ""` / `if classFile` 是**安全的**，扫描器报出来的是误报（它看不见 `Plain`）。
> 反过来说：**凡是把"取值"和"判空"写在同一句里的地方，都要先想一遍这句是否在机密值上执行。**

## 8.8 2026-10-30 美化层功能收口：一个确认漏斗 + 一个上身入口 + 一个静音原语

这一轮不加新皮肤，把"同一件事在七八个文件里各写一遍、还各写歪"的三处并成一份。

### 8.8.1 对象确认：`Skin:Need` + 一本账（`Utils/Skin.lua`）

- `Skin.targets[scope][path] = { hits, misses }` 是全仓**唯一**的"这个名字存不存在"的账；
  `Skin.With(scope, fn)` 把 fn 里的 Need 记到 scope 名下；`Skin:Need(path)` 过 `ns.ResolveObject`。
- `Core.lua` 里那份只回 bool 的 `ns.ResolvePath` 删了（没有调用点，留着就会有人继续用它绕开账本）。
- 之前只查名字不记账的地方全部改为过 Need：`M:Apply` 的名单、`Skins` 各面板的 `Skin:Need` 点路径、
  以及三个**非皮肤模块**的诊断（Minimap / InfoBar / Nameplates 的探针现在也进同一本账，
  用 `Skin.With("minimap", ...)` 之类的作用域包住循环）。
- `/mui skins diagnose` 只有一个读法：优先读真账本（`Skin:Report()`），只从没跑过的面板才退回声明名单。

### 8.8.2 上身方式：`M:Dress(spec, opts)`（`Modules/Skins/Skins.lua`）

以前每个皮肤文件手抄那五行"剥原美术 → 挂底衬 → 窗口件 → 深扫 → 显示时补扫"，**顺序还各写各的**：
先挂底衬再 Strip 的把自己的底衬剥掉了，忘补扫的 ScrollBox 把手永远是暴雪 atlas。现在：

- `M:Dress` 是本仓唯一的"美化一个对象"入口；`opts` = `window` / `panel` / `strip` / `noStrip` /
  `noPanel` / `deep` / `lazy` / `control` / `as` / `tabs|buttons|scrolls`。
- `M:SweepDeep` 负责懒建内容：先扫一遍直接子控件，再按**可见性**用 `Widget:PollWatch` 补扫
  （标签页/列表的行是在帧已经显示着的时候建出来的，OnShow 那一刻它们还不存在）。
  登记用 `Mark(frame, "deepSweep")` 去重 —— `M:Apply` 会被三个事件反复触发，不去重就是每触发一次多一条轮询。
- `opts.as` 走 `DRESSERS` 表（tab / button / scroll / slider / dropdown / editbox / fade），
  只处理单个控件、不碰窗口装饰。

### 8.8.3 藏暴雪 HUD：`Widget:Mute` / `Widget:Unmute`（`Utils/Widget.lua`）

五份手抄（BuffFrame、QuestTracker、Tooltip、宠物条壳、姿态条壳、暴雪条 Park）并成一份。
三条纪律不变：`SetAlpha(0)` + 子树 `EnableMouse(false)`，**绝不 Hide**（会和暴雪的 Show 拉锯成闪烁）、
不写字段 / 不卸事件 / 不换父。`opts = { depth, alpha, combat }`：

- `depth = 0` 只根框（光环按钮要留鼠标）、`2` 默认、`math.huge` 整棵树（追踪框的任务块按钮池）。
- `combat` 默认**跳过**（返回 false）；暴雪动作条的 Park / Restore 那两条传 `combat = "write"`。
- 战斗判定从 `_G.InCombatLockdown()` 换成 `ns:InCombat()` —— regen 事件派发当拍前者还是旧值（Core 的注释）。
- 子树鼠标用**两个**旁表键：`muiMouseHeld`（我处理过）+ `muiMousePrior`（它本来就开着）。
  合成一个键并把"本来没开"存成 `false` 是本轮 review 抓出来的缺陷：那次 `false` 既会被下一轮的
  `== nil` 判成"已处理"、又不会被还原分支清掉，于是暴雪复用池化按钮、把鼠标重新打开之后**再也没人关回去**
  （实机症状就是当年那条"原始目标追踪还能点击"）。
- 顺带修掉两个原来就有的漏：`ActionBars.Blizzard.Restore` 还原时不分子树鼠标（一次搬家后永远关着）、
  `Tooltip` 的状态栏重新显示后鼠标仍是关的。
- `Widget:IsMuted(frame)` 给"被战斗挡住、要等脱战"的调用方判断还有没有活干：
  QuestTracker 关掉模块时 1 秒 ticker 已经停了，所以 `M:SetEnabled` 走 `ns:AfterCombat`，
  靠 `SuppressBlizzard` 返回 false 把它留在队列里（否则战斗里关模块，暴雪那块会一直隐形挂着）。

### 8.8.4 闸门：`tools/check-frame-list.js` 重写（这一轮的证明层）

它核对"面板 `frames` 名单 ↔ 代码里真的有取用"。v1 读不懂新的名单形状（const 表 + 点路径），
v2 认三种：直接取用（`Skin:Need("A.B")`）、const 表被真实代码引用、窗口装饰的 `CloseButton` 隐式回退。
`ALLOW_DYNAMIC`（"我宣布它运行期拼出来，别查了"）从 17 个减到 **7 个** —— 只剩 `StaticPopup1..4Button*`
和两个 LFG 成员名；其余全部由 `isReached()` 真查出来，不许停在这里当免检牌。

- 修 v2 自己的两个坑：花括号扫描遇到 `} })` 时 `depth` 会穿到负数，`=== 0` 永远不成立 →
  frames 范围吞掉整文件（52 个假孤儿）；注释剥离按多行正则会吃掉引号之间的中文注释 →
  必须**逐行**先去注释、再把字符串置空，只用于"这是不是一次真取用"的判定。
- 它抓到的是**真漂移**，不是工具噪音：内存里写的 close 按钮名、一个早已不存在的 hook 名、
  `ScrollFrame` 裸名 vs 点路径不一致、一个只有名单没有代码的深扫名，外加 `skins/Trade.lua`
  里遗留的一整块重复面板（已删）。
- 单个名字为什么算"取用到了"：`node tools/check-frame-list.js <Name>` 逐规则打证据。

### 8.8.5 闸门结果（本机，无游戏）

`luac -p` 全过（`tools/api-audit-selftest/Broken.lua` 是故意的语法错误样本，扫描要排除它）；
`node tools/check-frame-list.js` → 171 个名字 / 7 个 ALLOW_DYNAMIC / 名单与代码一致（8.7 里那句
"仍报 21 个"作废）；`node tools/api-audit.js` → `result: no hard finding`（INFO 是原有的：
`ResolveMode`、`CanExitVehicle`、`EnumerateFrames`）。

**实机没做**：`/mui skins diagnose` 要看的是账本里 `misses` 是否为 0（尤其 8.8.2 那批点路径），
以及追踪框/宠物条/姿态条/光环压制在战斗内外的表现。见第 9 节 1、2 条。

## 8.9 2026-10-30 收尾：距离变暗事件化 + 拦截账本 + 探针

### 8.9.1 动作条「超出距离变暗」改吃事件载荷

实机 ×8 `ADDON_ACTION_BLOCKED UNKNOWN()` 的嫌疑点落在 `IsOutOfRange`：`raw == nil` 写在
`issecretvalue` **之前** —— 受限环境里这一句本身就是"对机密值做比较"。

- 判定顺序改成 `IsSecret` 最前，机密一律**保留上次判定**（不猜）。
- 更根本的改法：`ACTION_RANGE_CHECK_UPDATE` 的载荷 `(slot, isInRange, checksRange)` 就是答案，
  直接结算这一格，**不再回头读** `C_ActionBar.IsActionInRange`（战斗里读回来仍是机密值，
  等于战斗中永不更新）。一次换目标能推几十条，所以攒 **0.1 秒**一起结算
  （`FlushRanges` / `QueueRanges` / `QueueRangeFor`，整条重算与逐槽分开记账）。
- `EnableActionRangeCheck` 一开就是整场逐帧算一格，所以只给**真正画出来的槽**开
  （`EnsureRangeCheck`），模块停用整批归还（`ReleaseRangeChecks`）。
- 没有目标时不动：这时敌对技能普遍报"不在范围"，一律变暗会把整条压灰（暴雪自己也不这样）。

### 8.9.2 `/mui blocks` —— 机密布尔被拦的归因账本

本客户端对 `ADDON_ACTION_BLOCKED` **不写 taint.log**，所以这一族只认我们自己记的栈：
`Secrets.Bool` 的失败路径存 `debugstack`，`/mui blocks` 按栈首行去重打前 8 个调用点与次数，
`/mui blocks full` 打最早一条的完整栈。**只覆盖 `Secrets.Bool`** —— 引擎容器 / 半套压制那类
仍然要靠关模块二分。

### 8.9.3 探针：`/mui actionbars probe pet|art|overlay|range [off]`

| 子命令 | 打印什么 |
|---|---|
| `pet` | `GetPetActionInfo` 逐格 7 个返回值（哪一位变了就说明它是那个状态；自动施法曾经数错过） |
| `art` | 按钮上 18 个美术字段的存在性 + `GetRegions()` 的**真实名字**（字段名与纹理名不一定同名） |
| `overlay` | `AutoCastOverlay` 的 `Shine` / `Corners` / `Mask` + `Shine.Anim` / alpha（蚂蚁、角标、像素环靠它定） |
| `range` | 临时挂 `ACTION_RANGE_CHECK_UPDATE`，打印三个载荷在战斗内外是否机密 |

实机结论一条：**本客户端没有 `button.AutoCastable`**（`probe art` 确认），"可自动施法"角标
一直挂在 `AutoCastOverlay.Corners` 上 —— `PetBar.StyleAutoCastCorner` 不再去找那一位。

### 8.9.4 顺手三处

- `Groups.lua`：小队框的 incoming / absorb 条用的是未注册的 `"barfill"` 键，实际没材质；
  改成 `"monet_barfill"`（8.6.1 换材质时漏改）。
- `tools/sync-check.js`：文本类（lua/xml/toc/md/txt/js）先归一 `\r\n → \n` 再比 ——
  本仓混用 CRLF/LF，逐字节比会把"刚部署完"的文件报成 STALE（实机误报过 `UnitFrames.xml`）。
  toc 的 `## Interface` 仍按部署改写排除。
- `PetBar.lua` 注释按探针结论订正（事件不能卸的原因照旧）。

### 8.9.5 本机实机状态（2026-10-30 首次跑 8.8 的收口）

| 项 | 值 |
|---|---|
| 模块 | `17/17` 已加载、全部 enabled |
| 日志 | 启动至今 **0 ERR / 0 BLOCKED**（只有 INFO/OUT/RUN） |
| `Secrets.BoolBlocks()` | **0 条**（`/mui blocks` 账本为空） |
| 名字账本 `Skin.targets` | 183 命中 / **148 缺失** |

那 148 条**不能直接当缺陷读**，得拆开看（本机实测的分法）：

- **127 条 = 根对象根本不存在**（`TrainerFrame` / `InspectFrame` / `WarbandBankFrame` …）：
  这些是 LoD 面板或本会话**没打开过**的窗口，`Skin:Need` 在 Apply 时就查了，自然落空。
- **15 条 = 根在、子路径写错**（真缺陷）：`LootFrame.LootFrameScrollFrame`、
  `QuestMapFrame.QuestLog`、`WorldMapFrame.{ZoomInButton,ZoomOutButton,CloseButton,TitleText,
  MaximizeMinimizeFrame.*}`；另有 `LootFramePrevPageButton` / `LootFrameScrollFrame` /
  `LootFrameNextPageButton` 被当成**全局名**查（本客户端它们是 `LootFrame` 的子件）。

**所以 diagnose 的正确读法是**：先把没开过的面板逐个打开（世界地图 / 交易 / 拾取 / 训练师 /
银行 / 角色信息），再跑 `/mui skins diagnose` —— 那时还报缺失的才是名字写错。
这条已经写进第 9 节第 1 项。

## 8.10 2026-10-30 实机第一轮：三类报错各自的根（retail 12.1.5）

首次把 8.8 的收口跑进 12.1.5，控制台给出三类新报错，逐条根因如下（都已修，闸门全绿）。

### 8.10.1 「名字在但不是框体」→ CreateFrame Usage ×11 面板

11 个面板（inspect/playerspells/collections/chat/guild/calendar/trainer/auction/professions/bank）
整片 Apply 失败在 `Skin.lua:390 Usage: CreateFrame(...)`：`Skin:Need` 命中的对象**不是 ScriptObject
**（命中的是全局函数/数字之类的同名东西），被当成 parent 传进 CreateFrame。一处抛错就把整个面板的
Apply 打断 —— 这就是"一个控件炸了带走整面板"。

- `Skin:IsScriptObject(obj)`（Utils/Skin.lua）：nil / table-or-userdata / `GetObjectType` 过 pcall；
  `NewBackdropFrame`、`Skin:Panel`、`Skin:ControlBg` 都先问它，parent 不可用时**返回 nil**而不是抛。
- `Skin:Need` 加第三种结果：命中但不是框体 → `led.shape = "notObject"`，`Skin:ReportScope` 单列一节
  `⚠ N 个对象存在，其中 M 个不是框体` + 逐条路径。**名字写错从此是可查的账，不是静默跳过。**
- `M:Dress` 逐步 pcall（`dressOne(frame, what, fn)`）：某个控件的某一步失败只记一行
  `美化 <框名> 的「<步骤>」这步失败: <err>`，其余步骤和其余对象照做。

### 8.10.2 forbidden 对象的 `GetRegions` → 交易框剥原美术被拒

`trade` 面板失败在 `bad argument #1 to ? (Attempt to access forbidden object … self:GetRegions())`：
`Skin:Strip` 里裸调 `frame:GetRegions()`。现在 `BACKDROP_PIECES` 的字段读和 regions 枚举都过 pcall ——
**剥不掉就只剥不掉**，不再连累同一个面板的底衬和子控件。

### 8.10.3 轮询读不到可见性 → 一个框刷 2087 条

`Widget.lua:206: calling 'IsVisible' on bad self … Count 2087`：三个轮询驱动（hover 0.1s / show 0.2s /
poll 0.2s）每拍对表里每个框读一次可见性，而本客户端有 **forbidden 对象**（被接管的安全框、战斗中临时
受限的受保护框），对它们调 `IsVisible` 直接抛。2087 条 ≈ 同一个框被读了 7 分钟。

- `Visible(frame)` 先 pcall，返回 `(shown, readable)`；读不出来时**只警告一次**并报名字
  （`GetName` → 父框名 + "的子框" → 无名框；名字先过 `Secrets.IsSecret` 再 tostring）。
- `VisibilityOf` 带暂停：读不出来就把这个框挂起 `PAUSE_RETRY = 5` 秒，期间一次都不碰，期满真读一次，
  可读即自动恢复。**为什么不摘条目**：模块那边靠旁表标记去重（`deepSweep` / `showHook` /
  `reassertHooked` / `adoptedWatch`…），条目没了标记还在，这个框之后就永远没人管了；而"读不到"
  多半是战斗中临时受限，脱战本该继续被照看。
- 暂停期间三个驱动都**不跑回调**（hover 用空监听表 `idleList` 推进状态）。理由：那些回调全是往这个
  框写东西，跑了也只会被客户端拒 —— 等于把一条报错换成一条拦截。

### 8.10.4 加载横幅带客户端身份

`ns:ClientIdentity()`（Core.lua）打印 `版本 · build · Interface`，两个客户端（零售 12.1.5 /
无限 1.60）交替验证时，日志里认不出是哪一版就没法定位 —— `GetBuildInfo` 返回值个数按版本不一样，
逐位取、取不到给 `?`。

### 8.10.5 闸门（本机，无游戏 MCP）

`luac -p` 全仓通过（排除 `tools/api-audit-selftest/Broken.lua` 这个故意的反例）；
`api-audit` **no hard finding**；`audit-taint` 53 个文件 0 BLOCKER / 0 HIGH / 0 SOFT；
`audit-locals` 49 个文件全过；`check-frame-list` 167 个名字全部有取用路径（7 个 ALLOW_DYNAMIC）。

**实机待办**：重部署后看横幅 `客户端：…`、`美化 … 这步失败`、`轮询读不到可见性：<框名>` 三类新行，
并把 `/mui skins diagnose` 的"命中但不是框体"名单贴回来 —— 那批名字要按真名订正，不是靠加 ALLOW_DYNAMIC 过关。

## 8.11 2026-10-30 接入无限图鉴 MCP：两处手工守卫换成客户端正规 API

`wuxianwow`（无限图鉴，https://wuxianwow.com/mcp）接成 Qoder 用户级连接器（免登录，49 个工具）。
其中 `addon_api` 就是 `docs/api/` 那份手册的在线版（1.60.1.70634 的 `Blizzard_APIDocumentationGenerated`），
除函数/事件/枚举外还带手册小节（`topic` = taint / secret / protected / secure-templates / forever-api）
和 `call: ok|limited|protected` 分级。先拿我们实机实测过的名字验它的可信度：`MouseIsOver`、`GetMouseFocus`
都是 not_found（与「本客户端这两个全局是 nil」一致），`issecretvalue` 正常返回签名与 `SecretArguments`。
**但它不收录暴雪框体名**（`WorldMapFrame` 查 `kind=table` 为空）—— 所以 `frames` 名单和「这个框在不在」
仍然只有实机能证；它能证的是函数 / 事件 / 枚举 / 结构这一层。

### 8.11.1 受限窗口不止战斗：`C_RestrictedActions`（Core.lua）

机密值手册点明限制触发条件由 `C_RestrictedActions` 暴露，六类：`Enum.AddOnRestrictionType` =
Combat 0 / Encounter 1 / ChallengeMode 2 / PvPMatch 3 / **Map 4** / **Chat 5**；状态 = Inactive 0 /
Activating 1 / Active 2；事件 `ADDON_RESTRICTION_STATE_CHANGED(type, state)`。两条口径要紧：

- 事件在限制**生效之前**、**解除之后**发 → `Activating` 就该按「已经不自由」处理；
- **派发期间 `IsAddOnRestrictionActive` 恒为 false** → 状态必须按事件载荷自己记，不能在回调里问 API。

本仓以前只盯 `PLAYER_REGEN_*`（等于只看 Combat 这一类），Map / Chat 是盲区 —— 这和 8.10.3 那个
「框中途变 forbidden、读不了」是同一族现象。新增：

- `ns:IsRestricted()`：战斗中 **或** 任一类限制活着；客户端没有这套 API 时退回 `ns:InCombat()`，
  逐位保持旧行为（`restrictionKnown` 只在真拿到 API/事件后才置位，所以不会拿空表当「一切自由」）。
- `ns:Restrictions()`：当前哪几类活着（诊断读它）。
- `ns.Restricted`（旗）+ 内部事件 `MONETUI_RESTRICTION_CHANGED`：状态换边时由 `NotifyRestriction`
  统一推。**这一层本来就在文件末尾另有一份**（`activeTypes` 只按数字类型记账、还直接拿
  `Enum.AddOnRestrictionState.Inactive` 裸比较，别的构建没有这个枚举就会抛）—— 已并成本仓唯一一本账，
  四个老订阅方（ActionBars / BuffFrame / Nameplates / UnitFrames）不用改。
- `ns:AfterCombat` 的「当场就能做」判据由 `not InCombat` 收紧成 `not IsRestricted`；队列排空除了
  `PLAYER_REGEN_ENABLED`，**非战斗类限制结束时也排一次**（否则 Map / Chat 窗口里排入的动作要压到下次脱战）。
- 自查命令：`/mui restrict`（四个函数在不在、枚举在不在、当前哪几类活着、`canaccessvalue` 可用否）。

### 8.11.2 读值前置：`Secrets.CanRead(v)`（Utils/Secrets.lua）

客户端的正规问题是 `canaccessvalue(value)` —— 「**我这个调用上下文**能不能读/运算这个值」，
比 `issecretvalue`（「它是不是机密」）更准：非机密但当前读不了的值它也说 false。同类还有
`canaccesstable`（能不能索引机密表）、`canaccesssecrets`、`canaccessallvalues`，四个都标 `call: ok`（插件可调）。

- 新增 `Secrets.CanRead(value)`：有 `canaccessvalue` 就用（pcall，抛了按「读不到」处理），
  没有则退回 `not issecretvalue` —— 调用点不需要知道差异；`nil` 先判可读（AGENTS「nil 不等于机密」那条不变）。
- `Secrets.Number` / `Secrets.Bool` 的门改走 `CanRead`：这两个是全仓唯一漏斗，30+ 调用点自动受益。

### 8.11.3 轮询暂停改成事件驱动恢复（Utils/Widget.lua）

8.10.3 的 `VisibilityOf` 是固定 5 秒复检；现在 Widget 订阅 `MONETUI_RESTRICTION_CHANGED`，限制状态
一换边就把 `pausedUntil` 清空，下一拍每个挂起的框各真读一次 —— 脱战 / 关掉地图即刻恢复，不用干等复检点。
接法只能是"订阅事件"：`Utils.xml` 在 `Core.lua` **之前**加载，Widget 运行的时候 Core 的接口还不存在
（第一版写成 `ns.OnRestrictionChange(fn)`，既用点号调了个冒号方法、又赶在定义之前，静默挂空 —— 已改）。

### 8.11.4 闸门、顺带发现与待验

`luac -p` 全仓过；`api-audit` **no hard finding**（`ADDON_RESTRICTION_STATE_CHANGED`、
`C_RestrictedActions.*`、`Enum.AddOnRestrictionType` 都能在本地快照核到，说明在线手册与快照同源）；
`audit-taint` 0 BLOCKER / 0 HIGH / 0 SOFT；`audit-locals` 49 文件过；`check-frame-list` 名单一致。

**顺带发现（下一件活）**：`api-audit` 现在提示 `InCombatLockdown x29 -> documented as
C_RestrictedActions.InCombatLockdown` —— 全仓 29 处裸 `InCombatLockdown()` 里，凡是「判能不能碰暴雪对象」的
都应换成 `ns:IsRestricted()`；纯 CVar / 布局类的调用保持原样。

实机待验（retail 12.1.5 与 Forever 1.60 各一次）：

1. `/mui restrict` 的输出（尤其四个 `C_RestrictedActions.*` 在不在、`canaccessvalue` 在不在）；
2. 进战斗 / 开地图前后，`轮询读不到可见性：<框名>` 那条是否随限制换边立刻恢复（不再等 5 秒）；
3. `Secrets.CanRead` 换上后血量 / 能量 / 名字 / 施法条显示没有回退（若 `canaccessvalue` 对普通值误报
   false，症状会是「东西整体不更新」，那时把 `Bool` / `Number` 的门退回 `IsSecret` 单独提交）。

## 8.12 2026-10-30 实机第二轮：retail 12.1.5 上把 8.11 三条验完（Computer Use 直接驱动客户端）

这轮不需要作者贴输出：Computer Use 接管客户端，`/reload` → `/mui ...` → 截图 → 裁聊天区放大 3 倍读。
**读聊天的规矩**：1365×768 的原图聊天字太小，一律 `tools` 外的 `%TEMP%\mui-crop.ps1 -In -Out -X -Y -W -H -Scale 3`
裁出来再 `Read`；聊天框只留最后十几行，**多行栈一定会被顶掉**（见 8.12.2 的教训）。

### 8.12.1 六类限制：实机确认（Core.lua）

`/mui restrict` 在 12.1.5（build 120105）上：

- `C_RestrictedActions.InCombatLockdown` / `IsAddOnRestrictionActive` / `GetAddOnRestrictionState` /
  `CheckAllowProtectedFunctions` **四个都有**；`Enum.AddOnRestrictionType` 有，六个成员全解析得出。
- `canaccessvalue` **有** → `Secrets.CanRead` 走的是正规前置，不是退回 `not issecretvalue`。
- 空闲时六类全部 `账本 空 / 实时 空`；**打开世界地图**时 `当前受限：Map（战斗中 否 · IsRestricted 是）`
  且 `Map: 账本 活 / 实时 活` —— 这条是本轮唯一想要的证据：**非战斗类限制是真的会活**，
  以前全仓只盯 `InCombatLockdown()` 确实等于只看六分之一。两次观测（自动开 / 手动开）都一致。
- 顺带：本客户端**没有** `C_WorldMap`（`attempt to index a nil value`），开地图只能走 `WorldMapFrame` 那条。
- 换上 `CanRead` 后血量 / 能量 / 名字 / 施法条**没有回退**（HUD、动作条、45 个窗口照常），
  8.11.4 担心的"整体不更新"没有出现 → 这道门保持现状。

### 8.12.2 forbidden 对象：从"无名框"查到 `SweepDeep`（Utils/Widget.lua + Modules/Skins/Skins.lua）

8.10.3 的暂停做到了"一个框只报一条"，但报的是**无名框**，查不下去。这轮把归因做完了，三步：

1. **判据先纠正**：`GetName` 读不出来 ≠ forbidden。暴雪大量控件本来就是匿名 `CreateFrame`，
   `GetName` 老老实实返回 nil、框体完全可读。第一版按"读不到名字"报 forbidden，指错了对象。
   现在 `Forbidden()` 只认 `IsVisible` 抛不抛（那才是驱动每拍真正撞的刀），
   `FrameLabel` 在没名字时退到 `父框 的子框` → `对象类型（无名）`，"无名框"三个字不再出现在账本里。
2. **登记点记账**：`Origin(src, frame)` 在 `HoverWatch` / `ShowWatch` / `PollWatch` 各自第一次收这个框时
   取一次 `debugstack(3, 1, 1)`（**只一行**），存进弱表；`Visible` 的告警和 `Widget:PrintStalled` 都带上它。
   为什么必须在登记那一刻：驱动循环每拍都是同一个 OnUpdate，栈里没有任何线索；而框一旦变 forbidden
   连名字都读不出来。`/mui restrict` 末尾新增"轮询被暂停的框"清单（`pausedUntil` 这本账一直在，
   聊天被 NPC 对话顶掉也能重看）—— 就是它把凶手点出来的：
   `1. ScrollFrame（无名） · 登记点 poll · Modules/Skins/Skins.lua:268: in function 'SweepDeep'`。
3. **源头收口**：`M:SweepDeep` 现在先过 `Widget:Readable(frame)`，读不出来的框**不挂常驻轮询**、
   只 `Skin:WarnOnce` 一条（保持暴雪原样，下次 Apply 能读了再补）。
   `Skin:ScanScrollArrows` 同样：`EnumerateFrames` 会把这个客户端**所有**帧交给我们，
   其中就有被引擎接管的安全框 —— 全量扫描的入口必须先问可读，不能指望下游的 pcall。

结果：`/mui restrict` 的暂停清单是 `（没有）`，加载期不再出现"轮询读不到可见性"。

### 8.12.3 `/mui skins diagnose bad`：命中但不是框体（Utils/Skin.lua）

全量 diagnose 几百行，这一类恰恰会被顶出聊天框，所以新开一个只报它的入口
（`M:Diagnose(onlyBad)` → `Skin:ReportBad`）。同时 `Skin:Need` 把第三种结果记成
`notObject:<类型>`（`function` / `table` / `Mixin 表`），报告里跟着报名字 ——
分不清"我们本来就在探一个函数"和"真名写错了"，这一类清单就没法看。

12.1.5 实机三条：

- `[micromenu] UpdateMicroButtons（函数）`、`[tooltip] SharedTooltip_SetBackdropStyle（函数）`
  —— **不是缺陷**：这两处本来就是"这个客户端还有没有这个全局函数"的存在性探针
  （`Forever.lua:144` / `System.lua:243`），标出类型后一眼可辨，不用改代码。
- `[trade] TradePlayerInputMoneyFrame（Mixin 表）` —— **真名写错了**：它是个 Mixin 表，不是活框体，
  所以 `M:Dress(TRADE_MONEY_FRAMES, ...)` 里这一半从来没被美化过。
  实机另探：`TradePlayerMoneyFrame` = nil、`TradeRecipientMoneyFrame` = table（那个是对的）。
  玩家侧金额框的真名**还没取到**（想列 `TradePlayer*` 全局的那条 `/run` 被客户端当未知命令拒了，
  当时角色正跑任务线，就没继续往里敲键）。**留给下一件活**：开一次交易面板，
  从 `TradeFrame` 的子控件里取真名（`/mui skins diagnose bad` 掉一条才算修完）。

### 8.12.4 闸门

`luac -p` 全过；`api-audit` **no hard finding**；`audit-taint` 0 / 0 / 0；`audit-locals` 49 文件过；
`check-frame-list` 名单一致。部署走 `tools/deploy-retail.ps1`（119 文件，`## Interface: 120105`）。

## 8.13 2026-10-30 Forever 1.60 适配准备（离线：wuxianwow MCP 的 addon_api + docs/api 快照）

### 8.13.1 快照刷新与版本差

- `node tools/api-fetch.js`：本地快照从 **1.60.1.70450**（10-15 编译 / 10-26 抓）刷到
  **1.60.1.70634**（10-26 编译）。站点数据已到 1.60.1.70707，但 API 手册页还在 70634
  （`addon_api` 不传参数就返回概况与版本号，先核对它再决定要不要重抓）。
- 70450 → 70634 的文档差集一共 6 条：`C_GameRules.SetForeverExperiencePreset` 拆成
  `...PreLogin` / `...PostLogin`，另加 `C_PetInfo.*` 两条与一个 `SETTINGS_HEADER_TEXT_UPDATE` 事件。
  **我们一条都没用到** → 过去两周没有名字在我们脚下改过。
- 对着 70634 重跑闸门：`api-audit` **0 HARD**（全仓 `C_*` / 事件 / `Enum.*` 都在 Forever 文档里）、
  `audit-taint` 0/0/0、`audit-locals` 50 文件过、`check-frame-list` 167 个名字与代码一致。
- **口径**：这一层只证明"名字在无限客户端的 API 文档里"，**不证明"1.60 的暴雪框体叫这个名字"** ——
  快照里没有框体名单（`TradeRecipientMoneyFrame` 这类只能实机取）。框体结论一律待实机。

### 8.13.2 手册里会改变适配做法的几条（`addon_api` 的 topic 节，逐条摘）

- **安全模板整组都在**：camelot 加载 `Blizzard_RestrictedAddOnEnvironment`，里面列了
  `SecureActionButtonTemplate` / `SecureUnitButtonTemplate` / `SecureHandlerStateTemplate` /
  `SecureHandlerClickTemplate` / `SecureAuraButtonTemplate` / `SecureFrameTemplate` 等 22 个。
  而 AGENTS 写的是"本客户端**没有** `SecureHandlerClickTemplate`"—— 那是 **retail 12.1.5 的实测**。
  换到 1.60 有可能能直接挂安全处理器（接住器、悬停钩子那几处"只能轮询"的写法就有得简化），
  **但要先证再改**：`/mui compat` 的模板一节 + 一个真点得动的实验，不要看到文档就动手。
- **GameRule 能整体关掉一块暴雪面板**（约 150 项，枚举编号不在文档里，登录后用
  `C_GameRules.IsGameRuleActive` 读）：与界面直接相关的有 `EditModeDisabled`、
  `ObjectiveTrackerDisabled`、`BagsUIDisabled`、`CompactRaidFrameManagerDisabled`、
  `PersonalResourceDisplayDisabled`、`PlayerCastBarDisabled` / `TargetCastBarDisabled` /
  `NameplateCastBarDisabled`、`WorldMapTrackingPinDisabled`、`MaximizeWorldMapDisabled`、
  `CollectionsPanelDisabled`、`EncounterJournalDisabled`、`TalentsPanelDisabled`、`AeLootDisabled`。
  → **在 1.60 上"某个暴雪框读不到"的第一嫌疑人是规则把它关了，不是我们名字写错**；
  模块该交时就交还（那条框本来就不该出现），别照 diagnose 的 ✗ 去"修名字"。
- **`/run` 可能整条被禁**：`C_AddOns.GetScriptsDisallowedForBeta()` 为真时 `/run`、`/script` 直接拒，
  另有 GameRule `UserScriptsDisabled` 与 `UserAddonsDisabled`（后者能把第三方插件整体关掉）。
  → 所有诊断**必须**是 `/mui <模块> ...` 子命令；贴 `/run` 长语句这条路在 Beta/正式版上随时会断
  （作者定的"别发长 /run"原来还有这一层原因）。
- **机密值语义**（站点按 1.60.1.70338 实测写明）：对机密值做运算、与同类型比较、取长度、当表键、
  判布尔、交给 `math.*` / `string.upper` → **直接 Lua 报错**；而原样交给 `SetText`
  （`SecretArguments = AllowedWhenTainted`）、拼接、`string.format`、存进表都是允许的。
  六类限制（`Enum.AddOnRestrictionType` 的 Combat/Encounter/ChallengeMode/PvPMatch/Map/Chat）与事件
  `ADDON_RESTRICTION_STATE_CHANGED` 就写在这一节里 → **8.11 那层不是 retail 专属**，1.60 同样要跑
  （老构建没有 `C_RestrictedActions` 时我们退回 `InCombatLockdown`，行为不变）。
  结论：`Secrets.Bool/Number/CanRead` 的口径不用改。
- **配额与脚本节流**：`LimitedLuaResources` 机制在但当前 `Enabled = false`（每插件 10000 帧 /
  40000 贴图 / 5000 FontString）；CVar `luaScriptBucketThrottleEnabled` 系列限制每秒脚本时间，
  **受限状态下阈值更低**（`...MaxMsPerSecondRestricted` / `...BurstRestricted`）。
  我们有三个轮询驱动（hover 0.1s / show 0.2s / poll 0.2s）+ 一堆低频兜底 ——
  1.60 上若"轮询像没跑"，先看这几个 CVar，再怀疑逻辑。
- **TOC**：exe 认 `## AllowLoadGameType`，无限对应的游戏类型标签是 **`camelot`**；
  差异文件按规则可以叫 `MonetUI_Camelot.toc`（站点也没实测，**同时保留无后缀 TOC**）。
  `## Interface: 16001` 本身是推算值（主×10000 + 次×100 + 修订），登录后用
  `select(4, GetBuildInfo())` 落实；`checkAddonVersion` 不匹配只标"过期"，不阻止加载。
  CVar `enableDeprecationAddons` 会挂上 18 个 `Blizzard_Deprecated*` 兼容层 ——
  我们 `SOFT deprecated shim = 0`，别为了"兼容"顺手捡旧全局。
- **无限专属**（万一以后要碰）：`C_GameRules.GetForeverExperiencePreset` / `IsSDHDToggleEnabled` /
  `AccountHasSDEnabled`、GameMode `standard|wf|wfhc`、传承 `Constants.LegacyConsts.*`、
  `PLAYER_CAMPING` 是**登出倒计时**不是篝火（本构建没有露营 Lua 接口）。

### 8.13.3 新工具：`/mui compat`（Utils/Compat.lua，Core.lua 挂命令）

64 项能力自查，一行一条；`/mui compat bad` 只留"与我们的假设不符"的那几条。分五组 + GameRule 一节：
身份与脚本通道 / 机密值与受限窗口 / 鼠标与遍历 / 安全模板（真造一个才作数）/
**"暴雪框体：名字只在 12.1.5 验过，Forever 必须复核"**。每条都写着"为什么在意"，
所以这张表同时就是**待重验清单**：换一个客户端跑一次，哪几条结论跨不过去直接摊开。

- **不套 `Skin:Need`**：那本账的语义是"取不到 = 名字写错"，而这里**"不存在"本身就是答案**
  （`MouseIsOver`、`PetActionBar_UpdateCooldowns` 我们正因为没有才改了做法）。
  解析仍走同一个漏斗 `ns.ResolveObject`，每一项都 pcall；条目支持三种探法：
  点路径存在性 / `probe`（自己给结论，如"六类枚举齐不齐"）/ `tmpl`（`CreateFrame` 试继承）。
- 模板那组的口径：客户端对不存在的模板要么报错、要么**静默忽略**，忽略会误报"有" →
  模板结论只当线索，最终以"点得动 / 施得出法"为准。
- 离线拿本机 `lua` 解释器 + 假 `_G` 跑过一遍（分支、格式、`bad` 过滤都对，64 项 / 2 项不符时输出 4 行）。
- `Enum.GameRule` 不在快照里（站点写明编号未收录）→ `api-audit` 加了一张**带出处的豁免表**
  `CLIENT_ENUMS_NO_DUMP`，把它降级成 INFO 一行。规矩同 `DEPRECATED_SHIMS`：**加条目必须给证据**，
  不是给"过关口子"。

**已完成**：2026-10-30 在 retail 12.1.5 上跑过基线，见 8.13.6。Forever 那一趟和它做差集。

### 8.13.4 Forever 首趟流程（只记不改）

1. 部署：`powershell -File tools/deploy-retail.ps1 -Dest "C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_cn_beta_" -Interface 16001`
   → `node tools/sync-check.js --dest "...\_cn_beta_"` 必须报 in sync。
   那台客户端的 `Interface\AddOns` 里已经有 `!WuxianWorkshop` / `WoWBridge` / `163UI_Info`
   （`addon_strategy.txt` 是 `[]`，没有加载限制）—— **只加 MonetUI 目录，别人的一个字节都不碰**。
2. 上线第一屏：加载横幅（`客户端：1.60.1.xxxx · build … · Interface 16001`，16001 是不是推算值就看这行）、
   `/console scriptErrors 1`，然后四条诊断：`/mui compat tmpl`（全量 + 模板，65 项）→
   `/mui compat bad`（只看与假设不符的）→ `/mui restrict`（六类 API + 被暂停的框）→ `/mui blocks`。
   **compat 的结果不要指望聊天框**：65 行一定被顶掉，去读
   `<客户端>/WTF/Account/<账号>/SavedVariables/MonetUI.lua` 里的 `compatReport`
   （写入比 `/reload` 晚 1–2 分钟，见 8.13.6）。
   暴雪框体那组对不上的，用 `/mui compat find <片段>` 扫真名（12.1.5 实测一次能走 15895 个框）。
3. **先把没打开过的面板都开一次**（世界地图 / 交易 / 拾取 / 银行 / 角色 / 天赋 / 传承 / LFG / 微菜单），
   再跑 `/mui skins diagnose` 与 `/mui skins diagnose bad` —— 顺序反了，缺的是"面板还没建"而不是"名字写错"。
4. 红字看完开 taint：`/run C_CVar.SetCVar("taintLog","2")`（**如果 /run 被禁就用配置面板或
   WTF 里手改**），读 `<客户端>/Logs/taint.log`，读完关回 0。
5. 差集分三类处置：①**名字变了** → 改 `frames` 名单（过 `check-frame-list`）；
   ②**GameRule 把面板关了** → 模块交还，这不算缺陷，别去"修"；
   ③**客户端真没有这功能** → 按 8.13.2 的模板/接口清单换做法。
   一趟只记账不重构，攒齐了再动（小步可回滚）。
6. Forever 专属窗口（`LFGParentFrame` / `LegacySystemFrame` / `MicroMenu`）的名字来自
   Ellesmere 的 Forever 皮肤文件，**在两个客户端上都还没验过** —— 首趟必看 `/mui compat bad`
   与这三块的 diagnose。

### 8.13.5 "本客户端"这个写法要退役

AGENTS 与本文里大量"本客户端有/没有 X"混指两个客户端（retail 12.1.5 与《无限》1.60 / camelot）。
本轮已确认至少一条是** retail 的结论**（`SecureHandlerClickTemplate` 不存在），而 1.60 的文档相反。
今后新写的结论一律带客户端标签（`12.1.5 实测` / `1.60 文档` / `1.60 实测`），
只有一句话证据的假设进 `Utils/Compat.lua` 的 WATCH 表，不进 AGENTS。

### 8.13.6 retail 12.1.5 基线（2026-10-30 实测：`/mui compat tmpl` 65 项 / 5 项不符）

客户端横幅：`12.1.5 · build 70575 · Interface 120105`。Forever 那一趟跑同一条命令，差集就是适配清单。
（`when = 2026-10-30 19:56:06` 那一趟是**最终 shipped 构建**跑的，下面 5 条以它为准。）

**读结果只认账本，别指望聊天框。** 65 行远超聊天框十几行的留存，所以 `Compat:Print` 把全量写进
`MonetUIDB.compatReport`（`{client, when, total, odd, rows}`，每行 `{组, 名字, 结论, 不符?, 附注}`），
落盘在 `_retail_/WTF/Account/039124100/SavedVariables/MonetUI.lua`。
**坑：写入比 `/reload` 晚 1–2 分钟**（实测 19:48 重载 → 19:50 才落盘），reload 完立刻读会读到上一趟的。

5 项与假设不符（Forever 上逐条看它们会不会反过来）：

| 行 | 12.1.5 | 结论 |
| --- | --- | --- |
| `canaccessobject` | 无 | 文档里有、客户端没装。`Secrets.CanRead` 用的是 `canaccessvalue`，不受影响 |
| `SecureHandlerClickTemplate` | 无（`SetBindingClick` 方法缺） | **AGENTS 那条"本客户端没有它"到此证完**：第一趟只用 `CreateFrame` 试，客户端静默忽略 → 误报"有"，差点把 AGENTS 改错。模板探法因此加了 `method` |
| `SecureHandlerInputTemplate` | 造不出来 | `CreateFrame` 直接失败，是这组里最硬的一条"没有" |
| `CompactUnitFrameTemplate` | 无（`SetupUnit` 方法缺） | 模板名或方法名有一个不对；我们并不用它，只当 Forever 的线索 |
| `TempEnchantFrame` | 无 | **`Modules/BuffFrame/BuffFrame.lua:557` 的压制清单里是一条空枪**。`/mui compat find Enchant` 全 UI 只有 4 个交易附魔框（`TradePlayerEnchantInset` 等），12.1.5 没有独立的临时附魔框。名字留作 Forever 候选，注释已写明 |

`SecureHandlerStateTemplate` 基线第一趟报的是"方法缺"，**那是我的方法名猜错**（`SetBindingHold`）：
我们自绘条的 `_onstate-page` 一直在用这套片段，功能上它就是存在。已经去掉那个 method，
现在这行是"有 · 名字被接受"。教训写进 `TemplateExists` 的注释：**只有有把握的方法名才配 `method`**。

这一趟顺手改掉的东西（都是实机才暴露的）：

- **模板探法有副作用**：`ActionBarButtonTemplate` 造出来会自己跑 OnLoad，12.1.5 实测报
  6 条 `ActionButton.lua:540 RegisterActionUIButton` 参数错。所以模板一组**默认不探**，
  只有 `/mui compat tmpl` 明确要时才探，`/mui compat` 末尾会提示"模板 N 项没探"。
- **`EnumerateFrames` 的口径**：12.1.5 实测它把**所有**框（含子框）都吐出来（一次扫到 15895 个），
  但只按它给的名字找会漏 → `find` 现在两条腿走：`EnumerateFrames` 取根 + 逐层 `GetChildren` 下钻，
  用 `done` 表去重，上限 40000 个框 / 深度 12。
- `C_RestrictedActions` 里**没有** `InCombatLockdown`（它是全局）：探针原来把它算进"4 项齐不齐"，
  于是一年到头报"缺一个"。改成 3 项，全局那条单列。
- `C_AddOns.GetScriptsDisallowedForBeta` 在 12.1.5 **存在**（我原来假设"没有"）→ 探"函数在不在"没意义，
  改成探**值**：`/run 脚本通道 = 可用`。Forever 上这一行才是真问题（`UserScriptsDisabled`）。
- 加载横幅 `客户端：` 那行的 Interface 号是空的：`GetBuildInfo` 的返回值位次按版本不一样
  （12.1.5 第 4 个才是 120105，第 5 个是构建号，第 6 个是空串）。`ns:ClientIdentity` 改成
  **认数不认位**：哪个返回值满足 `floor(v/100) == 主版本*100 + 次版本`，谁就是 Interface 号。
- GameRule 一节：12.1.5 上 18 条里 17 条"没生效"、`AeLootDisabled` 这条枚举里根本没有 →
  **这台服务器没关任何暴雪面板**，这一趟不用担心 GameRule；Forever 上这节才是重头。

## 8.14 2026-10-30 配色线：R-05 编号空间核完 + 单位框架"掉血 vs 背景"实测归因

用户报的现象：**单位框架的损失血量颜色和背景看上去分不开**。这一节把"是不是 MonetColor 库的锅"拆开——
答案是**库的编号没问题、数据有覆盖洞、对比度是消费层（我们）欠的一层**，三件事各有各的修法。

### 8.14.1 R-05：mapID 编号空间 = 对得上（这半不用再等实机）

`Libs/MonetColorMapData-1.0` 里的 14 个 mapID 逐个对过无限图鉴 atlas（`mcp__wuxianwow__atlas`，
数据源是 **1.60 客户端自己的 UiMap / AreaTable DB2**，标签算 `1.60 文档 + 派生`）：

1413 贫瘠之地 / 1417 阿拉希高地 / 1420 提瑞斯法林地 / 1421 银松森林 / 1424 希尔斯布莱德丘陵 /
1429 艾尔文森林 / 1436 西部荒野 / 1440 灰谷 / 1441 千针石林 / 1444 菲拉斯 / 1446 塔纳利斯 /
1454 奥格瑞玛 / 1458 幽暗城 / 2521 泽风岛 —— **号与名全部命中**，`千针石林(含闪光平原)` 那种合并名
之外没有一处名字漂移。父链三层也全是真 UiMapID：区域 → **1414 卡利姆多 / 1415 东部王国** → **947 艾泽拉斯**
（泽风岛 2521 的 parent 直接是 947，不是大陆）。

→ R-05 里"失配会静默退化成冷蓝 fallback"的**编号错位**这一半可以排除。剩下的只是"当下这个 mapID
命中了哪一级规则"，客户端开着时一条 `/mui status` 读 `来源`（`data` / `parent:data` / `override` / `fallback`）
就结掉——这一趟**没做**（Wow.exe 没在跑）。

### 8.14.2 真问题是覆盖率：联盟新号一路跑在 fallback 上

atlas 统计（`1.60`）：**区域图 50 张 + 首都 6 座**，数据表只写了 **12 区域 + 2 首都**，部落向。缺口里最扎眼的：

| 缺什么 | mapID | 后果 |
|--------|-------|------|
| 四个新手区（杜隆塔尔 / 莫高雷 / 泰达希尔 / 丹莫罗） | 1411 / 1412 / 1438 / 1426 | 部落新号 5–10 级、联盟新号 1–10 级全程无主题 |
| 联盟首都（暴风城 / 铁炉堡 / 达纳苏斯）+ 雷霆崖 | 1453 / 1455 / 1457 / 1456 | 主城是"界面读得最多"的地方，联盟只有幽暗城与奥格瑞玛有数据 |
| 1.60 新增区（海加尔山 / 辛德拉 / 河林） | 2482 / 2652 / 2548 | 新内容区全 fallback |
| **大陆层与世界层的行** | 1414 / 1415 / 947 | **父链拿不到任何东西**，未覆盖区直接落到硬编码冷蓝 |

所以"配色不对"的抱怨里有一部分**不是配色坏了，是根本没配色**（fallback 冷蓝 + 我们那串手工乘数）。
两条补法都在 monetcolors 仓：①截图重跑 `tools/gen_map_env.ps1` 逐区补（正经路线，要游戏截图）；
②**先加 1414 / 1415 / 947 三行父链兜底**，色由该层成员区的已提取色取圆均值**派生**（来源要写明是派生，
不是提取）——不改一行代码就能让未覆盖区落在同陆调子上。这条性价比最高，等下次同步数据时一起做。

### 8.14.3 实测：空槽和面板**等亮**，只剩纹理差别

离线复算（`lua` 直接 `dofile` 那两个 lib 文件，用库自己的 `RGBToLab` + WCAG CR；
脚本在 `%TEMP%/mui-color-analysis.lua`，可重跑）。现状算法 =
空槽 `neutral × 0.32`（`UnitFrames.lua` LostColor）对面板底 `ambient × 0.35`（`Widget.lua:1089`）：

| 区域 | envL | 空槽 L\* | 面板 L\* | 空/板 CR | 血条 L\* | 血/空 CR |
|------|------|---------|---------|---------|---------|---------|
| 菲拉斯 | 0.180 | 12.9 | 4.3 | **1.19** | 23.9 | 1.39 |
| 幽暗城 | 0.220 | 13.2 | 5.8 | **1.17** | 23.9 | 1.37 |
| 艾尔文森林 | 0.206 | 13.3 | 5.8 | **1.17** | 24.8 | 1.42 |
| 灰谷 | 0.256 | 13.8 | 6.7 | **1.17** | 37.0 | 2.17 |
| 奥格瑞玛 | 0.234 | 13.3 | 7.4 | **1.13** | 25.7 | 1.46 |
| 银松森林 | 0.241 | 13.7 | 7.3 | **1.15** | 28.6 | 1.60 |
| 提瑞斯法林地 | 0.322 | 14.7 | 10.8 | **1.10** | 39.9 | 2.36 |
| 希尔斯布莱德丘陵 | 0.323 | 14.6 | 11.5 | **1.08** | 39.7 | 2.35 |
| 贫瘠之地 | 0.395 | 15.5 | 14.6 | **1.02** | 47.4 | 3.05 |
| 阿拉希高地 | 0.400 | 15.6 | 14.9 | **1.02** | 49.1 | 3.24 |
| 千针石林 | 0.403 | 15.4 | 15.1 | **1.01** | 45.5 | 2.85 |
| 塔纳利斯 | 0.420 | 15.5 | 15.6 | **1.00** | 45.8 | 2.87 |
| 泽风岛 | 0.408 | 15.2 | 14.8 | **1.01** | 46.1 | 2.92 |
| 西部荒野 | 0.474 | 16.4 | 16.8 | **1.01** | 62.3 | 4.97 |
| 回退（无数据 / 室内） | 0.500 | 16.3 | 18.3 | 1.06 | 57.3 | 4.22 |

三条结论：

1. **CR 1.00–1.19 = 视觉上"没有差别"**（WCAG 里 1.0 就是完全等亮）。空槽与面板都随 envL 线性移动，
   斜分别 0.096 / 0.35，交点在 **envL ≈ 0.441** —— 亮区域（西部荒野、千针石林、塔纳利斯、泽风岛）
   正好压在交点上，所以"亮地方最看不清"不是错觉。
2. **常数乘数救不了**：要让空槽比面板高 14 个 L\*，所需乘数横跨 **0.173（菲拉斯）–0.299（回退）**，
   差一倍。现在写死的 `0.32 / 0.35` 只是碰巧在暗区域还行。
3. **血条填充 `1 − edge` 是第二个根**：L\* 从 23.9 一路跑到 62.3，**越亮的区域血条越亮**，跟"要压过背景"
   的需求方向反的。作者已定（2026-10-30）：**保留 edge 的色相，按 L\* 重新定位亮度**，不改回固定语义槽。

现状唯一"还看得出空槽"的东西是 `BarWeave` 的织纹（CR 1.63–1.85，很弱但它在）——
而小队/团队格因为 8.14.4①那个 subLevel 写反，连织纹都压住了，所以团框比玩家框更糊。

### 8.14.4 顺手挖出来的三处缺陷（都在消费层，不是 lib）

1. **`Modules/UnitFrames/Groups.lua:173`**：`Widget:LostBarBG(button.health, 1, 1, 1, 1)` 最后那个参数是
   subLevel **1**，把空血纹理画在 `BarWeave`（sublevel 0）**之上**，和该函数注释"垫在织纹之下"相反
   → 团队/小队空格子是死平的一块。
2. **`Modules/UnitFrames/BossFrames.lua:180`**：传了 `bg = { 0.06, 0.06, 0.06 }` 并注释"对比度增强"，
   但 `Widget:Refresh` 从不读 `opts.bg`（背景只有 `Color:GetAmbient() × 0.35` 一条路）—— 这段是**死代码**，
   首领框的对比度从没被增强过。要么让 Widget 认这个键，要么删调用点。
3. **`UnitFrames.lua` FillColor / LostColor**：`player` 与 `targettarget` 分支**硬覆盖**用户的
   `fillColor` / `lostColor` 设置——配置面板里改了没反应。

### 8.14.5 分工与顺序（已拍板）

库欠的是**工具层**，不是策略层——"5+3"冻结决策里 Health/Resource/Danger 明确不 Monet 化，
所以条内对比度归 UI 自己管；但库恰好是**唯一已有 Lab/L\* 数学**的地方（`RGBToLab` / `DeltaE`），
 MonetUI 全仓**没有任何亮度/对比度函数**。据此分四步：

1. ~~实机跑 `/mui status` 结掉 R-05~~ → 编号空间已离线排除（8.14.1），`来源` 字段留到客户端开着再读，
   **不阻塞**后面三步。
2. **monetcolors 1.2.0**（纯加法）：`LMC.ContrastRatio(c1, c2)` 与 `LMC.AtLightness(r,g,b,L*)`。
   按该仓规矩走：先 `LibMonetColor-1.0-API.md` 再实现、`MINOR` 进位 + `.toc ## Version` + `CHANGELOG.md`
   两处同时改、6 个测试文件全绿。这正好是决策日志 **R-04**（"WCAG 校验不内置，可能改为独立工具函数"）
   预留的那个口子，不是新发明。
3. **MonetUI `Color:Refresh()` 里算一次 `theme.surface = { panel, lost, fill, weave }`** 并缓存
   （`GetCurrent*` 保持 O(1) 读表，是该仓的性能红线），ΔL\* 数字集中一处；调用点全部改吃这四层，
   并让 8.14.4③ 的用户设置重新生效。
4. **`/mui colors`** 一行 print + `MonetUIDB.colorReport` 账本（长输出只认账本，见 8.13.6①）验收。

同步 lib 时顺手把数据表头部那三行**过期出处**（`gen_map_env.ps1` / `game_palette_v1.json` 的路径与
"generated 2026-10-16"）重跑生成，别手改。

### 8.14.6 这一轮做完的（2026-10-30，代码已进仓，**尚未部署**）

**① monetcolors 1.2.0（本地提交 `d8fa044`，未 push）**：`LMC.ContrastRatio` / `LMC.AtLightness`
按"文档先行"落地，`MINOR 10002 → 10003`（老副本必须先被 `NewLibrary` 拒掉才能升级），
`.toc ## Version` + `CHANGELOG.md` 同步，新增 `tests/test_color_tools.lua` 24 项（全仓 155 项）。
两个函数都**保守回退**：读不懂的颜色 `ContrastRatio` 返回 1（"没有对比"）、`AtLightness` 返回中性灰，
绝不返回一个看着合理的数。
**vendor 同步已完成**：`Libs/LibMonetColor-1.0/LibMonetColor-1.0.lua` 与
`Libs/MonetColorMapData-1.0/MonetColorMapData-1.0.lua` 用 `cp` 从开发仓复制，diff 为 0。

**② MonetUI 的四级亮度阶梯**（`Utils/Color.lua`）：`Color:Refresh()` 每次重算一遍
`computeSurface(theme)` 并缓存，`Color:GetSurface(key) -> r,g,b` 是 O(1) 读表（性能红线守住），
`Color:Surface()` 给诊断用。阶梯按 **CIE L\*** 定死，色相仍由引擎给：

| 档 | 目标 L\* | 色相来源 | 用在哪 |
|---|---|---|---|
| `panel` | 10 | `ambient` | 窗口底衬 + 圆角填充块 |
| `lost` | 28 | `neutral` | 掉血空槽、条底（`bar.bg`） |
| `weave` | 40 | `neutral` | `BarWeave` 发丝织纹 |
| `fill` | 46 | `edge` 的 RGB 反相 | 玩家/宠物/目标的目标/队伍格的血条填充 |

**离线实测**（`lua` 直接 dofile vendor 副本 + `Utils/Color.lua`，逐区域跑 14 张地图）：
最坏的一组对比度 `panel↔lost` **1.69**、`lost↔weave` **1.54**、`lost↔fill` **1.91**、
`panel↔fill` **3.26**；四档 L\* 稳定落在 9.8–10.2 / 27.8–28.2 / 39.8–40.2 / 45.8–46.2
（8.14.3 的旧状态是 1.00–1.19 且随区域翻转）。关 Monet（`theme.useMonetColor=false`）走
`FALLBACK` 调色板同样吃到阶梯。引擎副本没有工具函数时**逐位退回旧的固定乘数**
（ambient×0.35 / neutral×0.32 / neutral / 1−edge），行为与升级前一致，`cr` 会是空表。

**③ 三处 collateral 缺陷**：
- `Groups.lua` 的 `LostBarBG(..., subLevel = 1)` 把空槽平涂**盖在织纹之上**（注释写的"垫在织纹之下"
  与 subLevel 的方向相反）→ 去掉那个 1，`Widget:LostBarBG` 的文档同步纠正：三处一律默认 0，
  织纹同为 BACKGROUND/0 且创建在后，天然压在 lost 上面。
- `BossFrames.lua` 两处传 `bg = { 0.06, 0.06, 0.06 }`，而 `Widget:Theme` 根本没有这个键 —— 死参数删掉，
  底板改由阶梯的 `panel` 档 + `bgAlpha = 1.0` 承担。
- **8.14.4③（用户设置被硬覆盖）改成"样式 + 默认值"**：`fillColor` 新增 `"inverse"`、`lostColor`
  新增 `"weave"`，`FillColor`/`LostColor` 里 player/targettarget 的硬顶分支删掉。
  默认值跟着改（`Core.lua` `DEFAULTS.unitFrames`）：player / pet / targettarget = `inverse` + `weave`，
  target / focus 仍是 `class` + `danger`。
  **配置面板的分组也跟着改了**：原来 `SELF = {player, pet}` / `OTHER = {target, focus, targettarget}`
  和"反相对"（player + pet + targettarget）不重合，一个下拉写整组会串色 → 现在是
  `INVERSE = {player, pet, targettarget}` 与 `TARGET_LIKE = {target, focus}`，各配"血条 + 损失部分"两行
  （共 4 行；`LayoutCursor` 只前进，bodyHeight 自动跟着长）。
  **存档迁移 SCHEMA 8 → 9**：只把还写着旧默认值的 player/pet/targettarget 换成新样式，
  玩家真选过的一个不动。

**④ `/mui colors`**：一行阶梯（每档用**它自己的颜色**显示"档名 + L\*"）+ 四组 CR 逐行判定 +
一行汇总，并且**无条件**写 `MonetUIDB.colorReport`（client / when / source / profile / mapID / zone /
envSource / steps / levels / colors / cr / rows / min / passed / checked）。判不过的那一趟最需要留在
WTF 里，所以落账在打印之前。阈值 `COLOR_CR_MIN = 1.4`（织纹是发丝布纹，需要的分离比"状态变化"小；
实测最坏 1.54，有余量）。工具函数缺失时印红字说明"退回固定乘数"，不印 0。
和 8.14.5④ 的偏差：验收不是一行而是 6 行 —— 聊天框装得下，但**结论仍然只认账本**。

**还没做的**：
- ~~**部署与实机验收**~~ → 已做，见 **8.14.7**（四档 L\* 与四组 CR 全部命中，观感确认仍归作者）。
  上线后跑
  `/mui colors` → 读 `MonetUIDB.colorReport` → 再看玩家/目标/队伍框的观感。
- 其它还在自己乘 ambient/neutral 的调用点没并进阶梯：`Modules/Skins/System.lua`（4 处底衬）、
  `Modules/InfoBar.lua`、`Utils/Skin.lua`、`Config/SimpleConfig.lua`、`Modules/Nameplates`、
  `Modules/UnitFrames/CastBar.lua`。它们各自有语义（阴影、名牌、下拉框），不是"抄一遍乘数"那么
  简单，等有实机反馈再逐条并。
- 1.2.0 的 push 仍等作者指示（monetcolors 仓库同样只做私有备份）。

### 8.14.7 实机验收：阶梯成立（2026-10-30，retail 12.1.5 · build 70575 · Interface 120105）

部署后 `/reload` + `/mui colors`，读 `MonetUIDB.colorReport`（`when = 21:56:39`）：

| 档 | 目标 L\* | 实机 L\* | RGB |
|---|---|---|---|
| panel | 10 | 10.21 | 0.109 / 0.109 / 0.109 |
| lost | 28 | 27.97 | 0.267 / 0.256 / 0.256 |
| weave | 40 | 40.13 | 0.383 / 0.367 / 0.367 |
| fill | 46 | 45.88 | 0.468 / 0.418 / 0.368 |

CR 四组 **4/4 过线**（阈值 1.4）：面板↔空槽 1.697 / 空槽↔织纹 1.563 / 空槽↔填充 1.932 /
面板↔填充 3.279。和 8.14.6 的离线探针逐位对上 —— 阶梯不是"算出来好看"，是实机同一个数。
读法用 `node tools/read-report.lua "<游戏目录>/WTF/Account/<账号>/SavedVariables/MonetUI.lua" colorReport`
（新加的离线工具，同一份能读 `compatReport`）。

**R-05 的实机答案：是覆盖率，不是编号空间。** 账本里 `mapID = 2393`（银月城）、`zone = nil`、
`envSource = "fallback"` —— `MonetColorMapData` 现役只有 14 个 ID（1413…1458 + 2521），2393 不在里面。
这印证 8.14.2 的判断：编号空间对得上（都是 C_Map 的 mapID），缺的是**表里只有 14 个区域**，
表外一律走兜底配色，`GetMapEnv` 连区域名都给不出来。**要紧的副产品**：兜底档照样 4/4 过线，
说明阶梯不依赖区域命中 —— 覆盖率是"配色像不像那个地方"的问题，不是"读不读得清"的问题。

**实机暴露并修掉的一个缺陷**（`Utils/Skin.lua`）：加载日志里四条
`美化 QuestLogFrameTab1/2、InspectFrameTab1/2 的「as=tab」这步失败: Skin.lua:729: attempt to call a nil value`。
根因不是名字写错 —— 这四个在 12.1.5 上**是一张表、不是框体**（页签系统换成了 TabInfo），
`tab:CreateTexture` 因此是 nil。`Skin:Need` 本来就把这种命中记成账本里的 `notObject:table` 那行 ✗，
是 `Skin:Tab` 没在入口收口，把账本里的有效信息冲成 4 条红字。现在 `Skin:Tab` 先过
`self:IsScriptObject(tab)`，不是脚本对象就直接原样返回（同文件里 `WatchTab` / `OnTheme`
两条语句挤在同一行也拆开了 —— 语法上合法，读起来像少了一个分隔）。

**一条关于"怎么验"的教训（这一轮白跑了十几分钟）**：截图 OCR **不能当结论证据**。
窄聊天栏会把 `|cff…|r` 折行成字面量，我把汇总行的"全量已存 MonetUIDB.colorReport"读成了
"MonetUIDB 读不到，账本没落成"，据此去查一个不存在的 `ns:DB()` 缺陷；而 `["schema"] = 9` 已经在
WTF 里、`compatReport` 用同一个 `pcall(ns:DB)` 写法成功落盘过，这两条本可以当场否掉我的读法。
**结论仍然只认账本，而且连"一行"也不该从截图读** —— 作者把日志贴出来那次才是有效证据。
Computer Use 这边另有两个坑：窗口客户区尺寸会在 1355×767 / 1365×768 之间跳（截图坐标要按当次
返回的 width/height 换算），以及**地图全屏时会把聊天框整个盖住**、`Escape` 关不掉它 ——
要回 HUD 用 `/reload` 比按 Escape 可靠。

**还开着的**：观感确认（玩家 / 宠物 / 目标的目标血条 + 队伍格空槽 + 配置面板四个新下拉能不能真改色）
归作者；其它还在自己乘 ambient/neutral 的调用点同 8.14.6 未动；两个仓库的 push 都等指示。

## 8.15 2026-10-31 把 Aurora（12.1.5.2）当"1.60 事实库"读了一遍，落地两个控件原语

**为什么读它**：Aurora 是唯一一个把 `Aurora.toc` 同时挂上 `16001` + `[AllowLoadGameType camelot]`
的成熟美化插件（393 个 Lua / 49.5k 行 / **233 个 Forever 皮肤文件 / 142 个暴雪插件**），
它的清单是拿本客户端自己的 TOC 生成的 —— 等于一份免费的 1.60 暴雪 UI 目录。

**产出 1：`docs/AURORA-COVERAGE.md`**（对照表，不是代码）
142 个插件逐条对到我们的 45 个面板，标 ✅/◐/✗/–，末尾给 P1 的 12 个优先项与 §3 的
**Camelot 覆盖 11 文件**清单。三条口径写在开头：文件在 ≠ 能打开（GameRule）、状态是推断（要过
`/mui skins diagnose`）、Aurora 另有 144 个插件一个皮肤都没写（当"1.60 存在哪些暴雪插件"的底表用）。

**产出 2：两个控件原语**（`Utils/Widget.lua`）

- `Widget:Shape(tex, kind, opts)` —— **顶点偏移画形状**，不引材质文件。不新开区域、不改尺寸、
  不改锚点（对"自己按文字高度排版"的框是硬要求）。`up/down/left/right/diamond`，先涂纯白再上
  顶点色（换主题只重设颜色）。尺寸读不出来（含机密）就挂轮询等它出现，画好即注销。
  首个消费者：任务追踪头部的折叠三角（原来是 `+` / `–` 文字）。
- `Widget:StatusBar(bar, opts)` —— 接管**暴雪自建**的条：换我们的剖面 + 语义色表
  （`assets = { [原 atlas/路径] = 颜色 }`），并每 0.2 秒**复检**填充有没有被暴雪换回去。
  首个消费者：新面板 `mirrortimer`（呼吸 / 疲劳 / 溺水条，颜色保留暴雪自己的）。

**两条偏离 Aurora 的决定（重要，别回头改）**

1. **它们是双钩（`hooksecurefunc(bar,"SetStatusBarTexture"/"SetStatusBarColor")`），我们是轮询。**
   第一版按 Aurora 写了钩子，`node tools/audit-taint.js` 直接判两条 `[HOOK-PROTECTED]` HIGH ——
   往暴雪框的方法槽写函数等于"写过这个框"，正是 AGENTS.md taint 模型禁止的那类。改成
   `Widget:PollWatch` 复检，代价是最长 0.2 秒会看到暴雪自己的填充，换回来的是零污染。
2. **比对填充时用"引擎回报的写法"**（第一次 `SetStatusBarTexture` 之后 `GetTexture()` 读回来记进
   `rec.texPath`，之后只跟它比）。拿传进去的字符串比，斜杠 / 扩展名一不同就永远不等 ——
   那就是每隔一拍重建一次贴图对象。

**顺带确认的 1.60 事实**（都已用 `node tools/api-lookup.js` 对过本地快照）：
`SetVertexOffset` / `SetHorizTile` / `SetTexelSnappingBias` / `canaccesssecrets` 都在；
`IsForbidden` 与 `GetNumMaskTextures` 是 `[SecretReturnsForAspect]`（Aurora 在这两处没守卫，
我们不要学）；`Blizzard_SharedXML\Camelot\ProgressBars\ColoredProgressBar.lua` 里那个
`ColoredProgressBarTemplate` 在 1.60 是 **Frame 不是 StatusBar**（`Widget:StatusBar` 已按此收口）。

**验证**：`node tools/api-audit.js` 0 HARD；`audit-taint` 0/0/0；`audit-locals` 全通过；
`check-frame-list` 名单一致；三个改动文件过 luaparse（5.1）语法。

**实机走了一遍（12.1.5.70688，2026-10-31）**，四条结果：

1. `Widget:Shape` 画的三角**实机成立**（截图确认是 ▲，不是麻花）：顶点偏移在 9×9 上也干净。
   隔离测试（64×64 三方块：灰方块 / 三角 / 菱形）确认三组数字都对，菱形那组 Aurora 的偏移可用。
2. **`Widget:Icon` 只给尺寸、不给锚点** —— 我第一版直接 `Widget:Icon(btn, 9)` 就用，
   贴图 `GetLeft()` 全 nil、屏幕上一个像素都没有，而 `GetVertexColor` 照样读得到（"看着设好了"）。
   以后凡是 `Widget:Icon` 出来要显示的，都自己补 `SetPoint`。
3. **`Texture:GetTexture()` 在本客户端返回 fileDataID（数字），不是路径串**：
   `Interface\Buttons\WHITE8X8` → `130871`，我们的 `monet_barfill_gradient` → **`-473`**（fine 档是 `-474`），
   暴雪的 `Interface\TargetingFrame\UI-StatusBar` → `137012`。所以"填充是不是我们的"必须按**引擎回报的值**
   比，而且数字也得认（`BarAsset` 已改成 string|number 都收）。
   实机功能测试：把填充换成 Blizzard 的 137012 → 计时框显示后一拍内变回 `-473`（复检生效）。
4. 重载时日志里那两条 `ADDON_ACTION_BLOCKED MonetUI UNKNOWN()` **不是这一轮引入的**：
   `tools.wuxian.errors` 的累计签名里这条已经有 **4017 次**（另有 759 条 forbidden-IsVisible），
   属于长期开着的那个问题；`/mui blocks` 账本为空（不是 `Secrets.Bool` 路径）。

**还开着的**：`tools.wuxian.check` 的实跑（这次游戏在线跑过了：0 error，20 条 warning 全是既有的
`MouseIsOver`/`GetMouseFocus`/`PetActionBar_UpdateCooldowns` 之类"本客户端没有的名字"）。
呼吸条要在水里才会真的显示，**颜色是不是暴雪那套（蓝/紫/橙）只有下水才验得到**，留给作者。


## 8.16 2026-10-31 现代菜单（右键菜单 / 上下文菜单 / 下拉本体）接管

面板 `menus` 从 opt-in 改成**默认开**，改名为「菜单 / 右键菜单」（`Modules/Skins/System.lua` 的
`SkinMenus` 里新增 `WatchModernMenus`）。覆盖的不只是右键菜单：`MenuUtil.CreateContextMenu` 出来的
一切都走这条路，UnitPopup 只是它的一个调用者。

**机制**：菜单没有名字、也没有"打开"事件，所以照本仓规矩 **轮询 + 旁表** ——
每 0.1 秒 `Menu.GetManager():GetOpenMenu()`，把没涂过的补一遍。
**没有** hook `MenuManager.OpenMenu` / `CompositorMixin.AttachTexture`（ElvUI 那套）：
`tools/audit-taint.js` 会把 hooksecurefunc 判成 `HOOK-PROTECTED` HIGH。

**实机硬约束（12.1.5，2026-10-31 验证，这条最要紧）**：12.x 的菜单对象是 `assertsafe` 包起来的 ——
- `menu:CreateTexture()` / `menu:CreateFontString()` **返回 nil**，同时把
  `Use of function 'CreateTexture' is disallowed` **打到屏幕上**（玩家看得见，不是静默失败）；
- 菜单里 FontString 的 `SetFont` 同样被拒（字体不变）。
所以第一版"给菜单加 4 条 1px 边 + 换字体"直接变成一屏报错，截图里整块都是错误框。
**能做的只有两件**：改**已有 region 的颜色**（`SetColorTexture/SetVertexColor/SetAlpha` 都放行），
和挂一个**我们自己的子框体**（`CreateFrame` 是全局，不在 assertsafe 名单里）。

**层级（实测）**：menu 501、元素按钮 521 → 子框体取 `menu:GetFrameLevel()` 就画在按钮**下面**、
在暴雪底衬**上面**，所以底板+边框挂子框体、按钮照常在上面。建完把暴雪那块
`common-dropdown-bg` 的 alpha 置 0（**必须等底板建起来再置 0**，否则菜单整体看不见）。
这条还有一个好处：底板是不透明的，它本来就盖住了暴雪底衬，所以"藏底衬"晚一拍（≤0.1 秒）也**看不见**，
只是干净；第一次开新菜单帧时底板还没建，那一拍才是暴雪原样。

**字体不用换**：菜单 FontString 挂 `GameFontHighlight` 一类 font object，早被"统一字体"面板换过了
（实机读到 `LXGWWenKai-Regular.ttf` 15px）。所以这里只补 `SetTextColor`。

**12.1.5 的结构备忘**（写皮肤时直接照这个）：
`menu` 自身只有 1 个 region = `common-dropdown-bg`（ARTWORK，alpha 0.93）；
子级 = 0x0 内容锚 + MinimalScrollBar（`minimal-scrollbar-*` atlas）+ 标题 Frame + 元素 Button（521）；
元素 Button = 一块**白色** BACKGROUND 贴图（染顶点色即可）+ 一个 FontString。

**验证**：`UnitPopup_OpenMenu("SELF")`（注意：`GetOpenMenu()` 只在**同一拍**读得到，分两次 `try` 会拿到 nil）
→ 9 个按钮，`plate=true`、`bodyAlpha=0`，截图确认是"我们的面板 + 1px 边 + 金色分组标题"；
池化复用也验了（关掉再开一个 88×63 的两项菜单，同样带上底板）；0 Lua 错误、0 blocked。
探测期间曾把 `scriptErrors` CVar 置 0 看英文报错，**已恢复为 1**。

## 8.17 2026-10-31 修：血条"损失部分 = 高亮红"看着没生效（织纹盖住了空槽色）

**玩家报的**："损失血量设置成高亮红，是无效的"。

**先证明设置链路本身是通的**（否则会去改错地方）：直接写库 + `/mui theme`（= UpdateAll → UpdateBarLook），
逐帧读 `healthLost:GetVertexColor()`：

```
set danger → Player 0.90/0.20/0.20 | Target 0.90/0.20/0.20 | Targettarget 0.90/0.20/0.20 | Focus 0.90/0.20/0.20
```

四个单位都变了，说明 `Setting → LostColor → SetVertexColor` 没问题。**变的是纹理色，屏幕上却没变红。**

**真因**：逐层读血条自己的 region（实机）：

```
r1 填充   ARTWORK    tex=-474 (monet_barfill_thin)
r2 空槽色 BACKGROUND tex=nil   ← healthLost（SetColorTexture）
r4 织纹   BACKGROUND tex=-501  alpha=0.85   ← Widget:BarWeave，创建在 lost 之后
```

`Widget:BarWeave` 的 45° 布纹是 **BACKGROUND、建在空槽色之后**，所以它**盖在空槽上面**，
alpha 0.85 的灰布纹把高亮红压成"灰褐布纹"——小红线只在 4px 周期的缝里露一点，8px 高的条上基本看不出来，
玩家看到的就是"没生效"。默认的"暗织纹"样式本来就是靠这层布纹做质感，所以这个问题只在**选实色**时暴露。

**修法**（`Modules/UnitFrames/UnitFrames.lua` + `Utils/Widget.lua`）：

1. `Widget:BarWeaveDensity(bar, alpha)`：织纹浓度记在 `Mark(bar, "weaveDensity")` 上，
   `BarWeave` 每次重涂时读它（主题刷新 / SyncBarFill 都会反复调 BarWeave，靠参数传会被顶回默认值）。
2. `UpdateHealthColor` 与 `UpdateDesaturation` **两个入口都要调** `ApplyWeaveDensity(frame)`——
   建框那一次读到的可能是默认值（库还没合并完），之后真正反复跑的是 `UpdateDesaturation`
   （血量事件 / Apply / 主题刷新都过它）。只挂建框那一次，玩家改完设置会一直停在 0.85。
3. 样式：`lostColor == "weave"` 保持 0.85，实色样式（danger / light / black / theme25）压到 **0.15**。

**真正的坑（比上面两条更值钱，记牢）**：本客户端 **`GetAlpha()` 和顶点色的 alpha 是同一个存储** ——
实机实测 `SetAlpha(0.25)` 之后 `GetVertexColor()` 的 a 也变成 0.25；反过来
`SetVertexColor(r,g,b,0.9)` 之后 `GetAlpha()` 也变成 0.9。所以"调淡织纹"**不能用 SetAlpha**：
下一次 `Widget:BarWeave` 的 `SetVertexColor(...,0.85)` 会把区域 alpha 一起顶回去。
第一版就是踩这个：`Mark` 记下 0.15、屏幕上还是 0.85，两头都对不上（`/mui lost` 打出 `织纹 0.85 → 0.85　mark=0.15`）。
以后凡是"既有 SetAlpha 又有 SetVertexColor"的贴图，都要按同一个旋钮想。

**怎么验**：`/mui lost`（新命令）逐单位打「样式 / 空槽色 / 织纹 alpha（前后）/ mark / frame.unit」。
实测：暗织纹 → 0.85，高亮红 → 0.15，来回切换都跟着走。

**顺带记两条**：玩家自身的 `health:GetValue()` 在本客户端是 **secret**（`/run` 里读出来是 `<secret>`），
所以别想用 `SetValue` 造"掉血"来看空槽；`MonetUITargetFrame` 用 `inspect` 探会抛
`'for' limit must be a number`（受保护框上的机密计数），要读坐标就手算
（UIParent 1200 ui 高、屏幕 1440 → ×1.2，y 从底往上）。

## 8.18 2026-10-31 视觉语言收口（docs/DESIGN-LANGUAGE.md + 三处小改）

**思路先落地成文档**：`docs/DESIGN-LANGUAGE.md`。核心是把"凭手感"变成可检查的四条：
1. **三层结构**：底（`Skin:Panel`）/ 内容（`DRESSERS`）/ 点缀（四种线 + `Widget:Shape`），多一层就算错；
2. **透明度阶梯**：0.98 菜单 / 0.97 对话框 / 0.96 常规窗口 / 0.92 HUD 面板 / 0.9 控件底 / 0.85 小地图 /
   0.7 小按钮 / 0.55 托盘 / 0.25 槽位 / 0 —— 新代码只能取表里的值，不许再发明 0.955；
3. **颜色槽纪律**：`edge` 结构线、`ambient` 底、`highlight` **只给 hover/选中/焦点/自身血条**、
   `neutral` 文字、`health/resource/danger` 语义专用；表面只认 `panel/lost/weave/fill` 四级，不许再乘系数；
4. **字号四档** 10/12/15/24，间距只走 2 的倍数，全部经 `Media:SnapUnit`。

**三处代码改动**
- 任务/剧情/地图窗口 `bgAlpha 0.95 → 0.96`（5 处），"常规窗口"只剩一个值。
- 任务追踪头部两个小按钮：平时 alpha 0.55、悬停 1（`QuietButton`）——头上那两个 chrome 不再抢任务文字。
- `Widget:HeaderRule`（标题下 1px 发丝线）+ `Widget:BarWeaveDensity`（织纹浓度，8.17 用）。

**两个新踩的坑（写给以后）**
1. **`SweepDeep` 会把不认识的 region 当暴雪美术 SetAlpha(0)**。标题线第一版线宽/位置全对
   （实机 `204x1`），但顶点 alpha 读出来 0 —— 因为 `window + deep` 的面板之后还会深扫一遍。
   给自绘 region 打 `Mark(tex, "art", true)`，`Skin:Fade` 见到它就跳过。
2. **按"标题底边"锚线，可能穿字**。标题的 FontString 矩形常常比字形小（时钟窗口的 `TitleText` 就是），
   底边正好落在"时钟"两字中间。所以 `HeaderRule` 保留两种锚法：默认按标题底边（坐标无关、最省事），
   需要时给 `ruleTop = 26` 走固定偏移（一定在标题下面，但要逐窗口调）。
   **因此 `opts.rule` 默认关**，逐窗口实机确认过再开 —— 一次全开等于赌 30 个窗口的标题矩形。

**没验完的**：游戏菜单 `GameMenuFrame` 的按钮（见 8.19，已修）。

## 8.19 2026-10-31 游戏菜单 11 个按钮的暴雪红石头（不是 3 个，是全部）

**实机截图**：主菜单 11 个按钮全是 `128-RedButton-Left/Right/Center + Highlight` 三件套 atlas，
alpha 1，面板本身已经换皮了 —— 只有按钮没动。

**真因**：12.x 的主菜单按钮是**匿名 + 按需创建**的（`GameMenuButtonSettings` 这类全局名已经没有了），
所以 `M:Dress("GameMenuFrame", { buttons = GAMEMENU_BUTTONS })` 那份名单**一个都命中不了**；
而且这些按钮要等菜单第一次打开时才建出来，登录时那趟 Apply 也抓不到。

**修法**（`Modules/Skins/System.lua`）：`DressMenuButtons(frame)` 按 `GetChildren()` 遍历（幂等，
`Skin:Button`/`ControlBg` 都有旁表标记），并在 `M:HookShow` 里再补一遍（走 `Widget:ShowWatch` 轮询，
不写暴雪脚本槽）。代价：菜单打开后最多 0.2 秒还是暴雪原样（第一次）；之后同一批按钮对象已换好。

**逐按钮验证**（实机 12.1.5）：11 个按钮 × 4 个 RedButton 区域 = 44 个，`stillVisible = 0`
（全部 alpha 0.00），文字 `0.51/0.49/0.49`（= 主题 neutral）、按钮底板是我们 1px 边。
截图确认：无红、无双层边、无残留 atlas。

## 9. 建议的下一步（按价值排序）

1. **实机回归 P0/P1 的改动面**（`docs/HANDOFF.md` 8.6.2 + `TODO.md` 的 9 条清单）：
   动作条堆叠数/三个开关、宠物条像素环、小地图三种鼠标操作、经验条不闪、背包位置、
   姓名板红边与细条剖面、首领框点击、按钮悬停三态、`/mui reset confirm`。
   顺带按 8.9.5 的读法把名字账本清一遍：**先把没打开过的面板都开一次**（世界地图 / 交易 /
   拾取 / 训练师 / 银行 / 角色信息）再跑 `/mui skins diagnose`，修掉那 15 条子路径漂移。
2. **回归一遍编辑模式**（改动最密集的地方），确认 `oldR` 与 BLOCKED 都不再出现。
3. **P5 剩余文件拆分**：Auras/CastBar 试水已通过，按同一模式拆
   `UnitFrames` 的 Blizzard/ClassPower、`ActionBars` 的 Secure/DragDrop/PetBar/暴雪条处置
   （注意：子文件用到的共享局部表必须显式挂到 `M` 上，否则静默失败）。
4. **小队/团队框**：确认自绘的正常、暴雪的那套按需在编辑模式里隐藏（我们不再代劳）。
5. **SpellFlyout（技能弹出托盘）**：鼠标点选项必报 `ADDON_ACTION_FORBIDDEN CastSpellByID()`，
   快捷键正常。要么接受"鼠标点不展开、只提示一次"，要么自绘托盘（工作量中等）。
6. 未动模块的实机过一遍（Bags、InfoBar、Tooltip、Cursor、Toast、Durability、CombatText）。
7. 想降噪的话：宠物条每次重载 10 条 `PetActionButton*:SetShown` BLOCKED（不改更稳，见 AGENTS）。
8. **Forever 1.60 首趟（只记不改，见 8.13.4）**：先在 12.1.5 上跑 `/mui compat` 存基线，再部署到
   `_cn_beta_`（`-Interface 16001`）跑第二次，两份差集 = 适配清单；三条 Forever 专属窗口（LFG / 传承 / 微菜单）
   的名字在两个客户端上都还没验过。
9. 上线前：push 到 origin，README 里的 `status` 徽章改成正式版。
