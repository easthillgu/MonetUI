# MonetUI 交接文档（换开发平台用）

> 写于 2026-10-24 22:30，跟着 `36b7280` 这个提交；**2026-10-25 追加了"拦截族 + 战斗中 buff"这一轮的收档（见第 3.5 节）**。
> 读者：接手这个仓库的 AI agent（Codex）或未来的自己。
> 先读顺序：**本文件 → `AGENTS.md`（硬规则）→ `TODO.md`（待办）→ `MonetUI.md`（设计/决策，147KB，别整篇塞进上下文，按标题查）**。

---

## 0. 一分钟接上

| 事 | 值 |
|---|---|
| 仓库 | `C:\Users\EastHillGu\Documents\wowaddonsdev\MonetUI` |
| 游戏 | `C:\Users\EastHillGu\Documents\Blizzards\World of Warcraft\_retail_\Wow.exe`（客户端 12.1.5.70575） |
| 插件安装目录 | `...\_retail_\Interface\AddOns\MonetUI`（由 `tools/deploy-retail.ps1` 从仓库拷过去） |
| 客户端日志 | `...\_retail_\Logs\`（`taint.log` 是污染日志，`EditMode.log` 是编辑模式布局的二进制转储） |
| 版本 | `MonetUI.toc` 0.11.0，`## Interface: 16001`（部署脚本会按客户端改写） |
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
> `target` 写成仓库绝对路径（`...\MonetUI-refactor`），否则审的是上一版。按 addon 名跑时
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
| ActionBars | 可用 | 1–8 号自绘安全按钮 + **收养**暴雪 `PetActionButton1..10` 做宠物条；冷却/拖放/翻页实测通过 |
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
- [ ] 动作条：1–8 号条施法/翻页/拖放；宠物条左右键/冷却/自动施法
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
| `Modules/ActionBars/ActionBars.lua` | 8 条自绘安全按钮 + 宠物条收养 + 拖放接住器 | `action` 等点击属性只能由**安全片段**写；`PickupAction/PlaceAction` 必须脱战 |
| `Modules/Cooldown/Cooldown.lua` | 冷却数字渲染 + 暴雪冷却管理器收掉 | 只处理我们自己的冷却框；`GetCooldownTimes` 是毫秒 |
| `Modules/BuffFrame/BuffFrame.lua` | buff/proc/debuff 三行 + 战斗中引擎兜底 | 行位置按行高算，别锚空行 |
| `Modules/Nameplates/Nameplates.lua` | 姓名板细条 | 绝不 hook 驱动框 |
| `Modules/Minimap/*` | 矩形小地图、按钮、pin、微型菜单 | 集群不动，只搬 `Minimap`；`GetMinimapShape` 是我们给第三方提供的约定全局 |
| `Modules/QuestTracker/QuestTracker.lua` | 自绘追踪 + 压制暴雪追踪 | 暴雪追踪是 LoD + 会换对象 |
| `Modules/UnitFrames/*` | 单位框 / 小队团队 | 暴雪的 Group 框**完全别碰** |
| `Modules/Skins/*` | 暴雪窗口美化（含 `Forever.lua` 客户端专属） | 不给里面的按钮/页签挂钩子 |
| `Config/SimpleConfig.lua` | 配置面板（滚轮滚动） | — |
| `tools/` | 部署、API 审计、材质生成、像素审计、taint 闸门 | 材质改完必须 `node tools/audit-pixels.js`；commit 前跑 `node tools/audit-taint.js`；**部署后跑 `node tools/sync-check.js`**（仓库↔已安装副本，MISSING/STALE/EXTRA） |
| `docs/api/` | 本客户端 API 快照（**效力高于 hated-wow MCP**） | `node tools/api-lookup.js <名字>` |
| `.opencode/skills/` | 项目级 agent skill | `wow-secret-value-taint-audit`（秘值/taint 审查，含三起实机案情档案）与 `wow-petbar-autocast-pixel-glow` |

> 另：宠物动作条"自动施法"像素环的完整实现要点（参数、`Widget:PixelGlow`、为什么要替掉暴雪的
> `AutoCastOverlay.Shine`）在 **`.opencode/skills/wow-petbar-autocast-pixel-glow/SKILL.md`**。
> Codex 不会自动加载它，需要时直接读这个文件。

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
