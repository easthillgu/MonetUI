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

**总体**：15 个模块全部实装、默认开启，正在做**实机排错**（不是加功能阶段）。这一阶段的主要敌人是**污染（taint）**，见第 4 节。

| 模块 | 状态 | 备注 |
|---|---|---|
| Core / Config | 可用 | 模块注册、主题管线、`/mui` 命令、滚轮配置面板 |
| UnitFrames / GroupFrames | 可用 | 单位框、小队/团队框（**暴雪的团队/小队框我们已完全不再碰**，要藏请玩家在编辑模式里设"可见性=隐藏"） |
| ActionBars | 可用 | 1–8 号自绘安全按钮 + **收养**暴雪 `PetActionButton1..10`（宠物条）与 `StanceButton1..10`（姿态条）；冷却/拖放/翻页实测通过 |
| Cooldown | 可用 | 只处理**我们自己的**冷却框；暴雪的「冷却管理器」4 块 HUD 帧被它收掉 |
| BuffFrame | 可用 | 自绘 buff/proc/debuff 三行；战斗中切到引擎 `AuraContainer` 兜底 |
| Minimap | 可用 | 矩形遮罩 + 面板 + 三个集群按钮；**集群不动，只搬 `Minimap` 帧**（见 3.1） |
| QuestTracker | 可用 | 自绘追踪框 + 压制暴雪追踪框（alpha 0） |
| Nameplates | 可用 | 细条血条/施法条/借用暴雪减益 |
| Bags / InfoBar / Tooltip / Cursor / Toast / Durability / CombatText | 可用，**本轮未动** | 需要一次实机过一遍（见第 6 节的验证清单） |
| BagFrame（旧排列式背包） | 待退役 | Bags 验证通过后删模块 + 配置面板条目 |
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

## 9. 建议的下一步（按价值排序）

1. **实机回归这一轮的 P4 拆分**（动作条 + 单位框的创建路径全都动过）：
   动作条 1–8 施法/翻页/拖放、宠物条（收养十按钮 + 自动施法像素环 + 冷却转圈）、
   **姿态条（收养 `StanceButton1..3`：点形态能不能变、位置是否贴在 3 号条左边、`/reload` 后不变）**、
   单位框（玩家/目标/目标的目标/焦点）血条与文本位置、进出编辑模式、`/reload` 后无新增 BLOCKED。
2. **回归一遍编辑模式**（改动最密集的地方），确认 `oldR` 与 BLOCKED 都不再出现。
3. **P5 剩余文件拆分**：Auras/CastBar 试水已通过，按同一模式拆
   `UnitFrames` 的 Blizzard/ClassPower、`ActionBars` 的 Secure/DragDrop/PetBar/暴雪条处置
   （注意：子文件用到的共享局部表必须显式挂到 `M` 上，否则静默失败）。
4. **小队/团队框**：确认自绘的正常、暴雪的那套按需在编辑模式里隐藏（我们不再代劳）。
5. **SpellFlyout（技能弹出托盘）**：鼠标点选项必报 `ADDON_ACTION_FORBIDDEN CastSpellByID()`，
   快捷键正常。要么接受"鼠标点不展开、只提示一次"，要么自绘托盘（工作量中等）。
6. 未动模块的实机过一遍（Bags/BagFrame 退役、InfoBar、Tooltip、Cursor、Toast、Durability、CombatText）。
7. 想降噪的话：宠物条每次重载 10 条 `PetActionButton*:SetShown` BLOCKED（不改更稳，见 AGENTS）。
8. 上线前：push 到 origin，README 里的 `status` 徽章改成正式版。
