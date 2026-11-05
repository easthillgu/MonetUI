# MonetUI 交接文档（换开发平台用）

> 写于 2026-10-24 22:30，跟着 `36b7280` 这个提交；**2026-10-25 追加了"拦截族 + 战斗中 buff"这一轮的收档（见第 3.5 节）**。
> **2026-11-02 更新**：交付目标改为本机实际游戏目录 `_forever_`（1.60）；12.1.5（`_retail_`）**不再保留**，
> 本文所有"12.1.5 实测"结论均为历史证据，只有 1.60 复验通过才算数。上线后开发计划见
> `C:\Users\EastHillGu\.opencode\plan\wowforever-post-launch-plan.md`。
> 读者：接手这个仓库的 AI agent（Codex）或未来的自己。
> 先读顺序：**本文件 → `AGENTS.md`（硬规则）→ `TODO.md`（待办）→ `docs/DESIGN-LANGUAGE.md`（视觉语言/配色阶梯）→ `MonetUI.md`（设计/决策，147KB，别整篇塞进上下文，按标题查）**。

---

## 0. 一分钟接上

| 事 | 值 |
|---|---|
| 仓库 | `C:\Users\EastHillGu\Documents\wowaddonsdev\MonetUI`（2026-10-26 转正：原 `MonetUI-refactor` 改名为 `MonetUI`，旧版封存在 `MonetUI-archive`） |
| 游戏 | `C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_forever_\Wow.exe`（2026-11-02 作者确认的交付目录；`_retail_` 那套 12.1.5 **不再保留**，12.1.5 结论只当历史证据） |
| 插件安装目录 | `...\WOWFOREVER\World of Warcraft\_forever_\Interface\AddOns\MonetUI`（由 `tools/deploy-retail.ps1` 从仓库拷过去，裸跑就是这里；同目录还装着 Aurora，两者重叠面见 `docs/AURORA-COVERAGE.md`） |
| 客户端日志 | `...\_forever_\Logs\`（`taint.log` 是污染日志，`EditMode.log` 是编辑模式布局的二进制转储） |
| 版本 | `MonetUI.toc` 0.12.0，`## Interface: 16001`（部署脚本会按客户端改写） |
| 当前 HEAD | `cd1f6d7`（2026-11-03），按本地记录的 `origin/main` 领先 **103** 个提交（未 fetch 核过，上线前一律不 push）。**11-03 各道改动全部未提交**：25 个已跟踪文件被改 + 9 个新文件未跟踪，且都在**同一棵 detached HEAD 的 worktree 工作区**里（`git branch` = `* (no branch)`），主目录那份 `main` 是干净旧态 —— 详见 8.29 部署态基线与"先开分支再提交"那条 |
| 远端 | `origin` = github.com/easthillgu/MonetUI，**私有备份**。**在游戏上线并通过初步测试之前一律不 push**（作者定的，见 `TODO.md` 末尾） |
| 参考插件（只读） | `../EllesmereUI-v9.4`（开发根在位，是**这个客户端**的实机皮肤代码，优先级最高）；**Andromeda 不在开发根** —— `../Andromeda` 这个路径不存在（11-03 核实），现存唯一拷贝 = `C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda`（`.toc` 38001 / v11.01，旧客户端残留目录）。比对走 `tools/compare-andromeda-close.js`，不手抠字节 |

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

模块清单见 `README.md`；模块的结构性说明见 `MonetUI.md` 第五节；视觉语言与配色阶梯见 `docs/DESIGN-LANGUAGE.md`。

---

## 2. 当前状态（做到哪了）

**最后更新：2026-11-04 深夜。开服日 = 2026-11-05（《无限》1.60 公测）。**

### 2.0 交付位置与口径（先读这条，别在错的地方找）

- 一切交付在 worktree `~/.qoder-cn/worktrees/app/02efb0/MonetUI`，分支 **`lane/prelaunch-1105`**，
  **36 个提交全在 11-04 这一天**（起点 `8e7dd88`，最新 `f2a2e1d`）。主仓
  `~/Documents/wowaddonsdev/MonetUI` 停在 `cd1f6d7`，**是一份静默过期的旧副本**——别拿它判断现状。
- **不 push**（作者 11-04 定）：`origin` 只作私有备份，仓库保持 private，转公开由作者手动且在
  上线+初步测试之后。README 的 `status` 徽章已改成「待 1.60 实机复验」。
- 两份部署都 `in sync`：交付目标 `_forever_`(16001) + 预验支 `_retail_`(120105)。
  重部署：交付侧 `powershell -File tools/deploy-retail.ps1`（裸跑就是 `_forever_`）；
  **预验支必须同时给 `-Dest "…\_retail_" -Interface 120105`**，裸跑会把交付 toc 改掉。
- 未入库文档（`docs/*` 与 `*.md` 被 `.gitignore` 排除，只活在 worktree）有**仓外快照**：
  `~/Documents/wowaddonsdev/MonetUI-prelaunch-1104/`（含 MANIFEST + SHA1）。worktree 被清时按原路径复活，别放回主仓。

### 2.1 11-04 这一天做了什么（36 个提交的族谱）

| 族 | 内容 | 证据 |
|---|---|---|
| 离线验证链 | harness 逐对象受保护判据（prot 位 = XML `protected` + Secure 前缀 + inherits 闭包）；A6 断言类 + 坏样例；`run.js` 红 **12 处/56 次 → 0**；`--selftest` 6/6 | `2c42812` `b9c3fc2` |
| 真缺陷修复 | `ns:AfterCombat` 排空**挪一拍**（脱战派发当拍 `InCombatLockdown` 仍为真 → 写安全头被拒） | `961de45` |
| 物品信息 | 背包/银行**品质边框 + 物品等级数字 + 冷却遮罩**（数字来源只有 `C_Item.GetItemInfo` 第 4 返回；`GetInventoryItem*` / `Pickup*` 全族在本客户端**不存在**） | `9946450` |
| 银行 | 与背包**并存不重叠**（窗口键/位置/✕ 按 `bank:` 分模式）、主页候选索引 `-1/-2/-3` 试探、包裹管理折叠面板（只放无 `[受限]` 标记的动作） | `f3464cf` `a698992` |
| **拖放（作者实机报的 P0）** | 「能拖不能放」根因 = 空格是占位壳；背包侧空格改**真 ItemButton**（≤84 格），并把身份按模板契约喂全（`SetBagID` 属性链 + `UpdateExtended`）⇒ 作者确认**三向掉落可用**；**银行侧未接**，故接管默认 off（两套并存是预期） | `0a2dcaa` `dae030a` |
| 诊断能力 | `/mui bags probe`（银行索引逐索引明细 + 接管判读）、`/mui bags layout`（窗矩形 + 两两重叠 + 空位窗自检）、`/mui report`（环境/设置差异/提示历史/台账/同机插件）、`Skin:WarnRing` | `a1d5008` `31b2fa7` `a814d9b` |
| 闸门入库 | `slot-info-probe` 18/0、`bank-parity-probe` 29→37/0、`report-probe` 30/0（它抓到一个 `table.concat(...,1,6)` 的真崩溃）、`frame-name-existence`（声明层对撞，只给线索） | `5a979e7` `1499f8a` `c773812` |
| 两轮第三方研究 | TweaksForever（QoL，GPL）与 RurutiaSuite（工具箱，**All Rights Reserved**）⇒ 只取机制；吸收清单 #28–#39；负面做法升进 AGENTS（**绝不替换暴雪全局函数**、别调布局缓存函数） | `101e49a` `f2a2e1d` |
| 拍板收口 | §5 十五项全部有结论：13=C（死注释块加"勿照抄"）、14=已办（分支+提交）、15=B（共存）、5=C+快照、8=C（不动材质常数）、9=B（✕ 维持 0.125） | `d8b12a7` `2283345` |
| 同机插件普查 | 开服日**冲突地图**：`EnhanceQoLMover` 目录条目 `defaultEnabled = true` 且 `hooksecurefunc(frame,"SetPoint")` 事后重钉 ⇒"窗口位置改了又跳回去"**先判它**，别当我们的布局 bug；背包/单位框/资源条默认关。许可普查：EQOL 全家 / Lueur / QuestEcho / 163UI **未声明许可** ⇒ 按全权保留，只取机制 | `ad15543`（`docs/ANALYSIS-INSTALLED-ADDONS.md`） |
| 今晚新能力 | `WhatsNew`（版本更新一次性提示，`/mui whatsnew` 可重看；无记录**不编内容**）+ **N4 运行期能力表 `Compat:Capability`**（三态不塌值 / 受限窗口不造实例 / cache 命中 / `/mui compat caps`） | `7d74bbd` `5d1346b` |
| 探针家族 | 每条新能力都配**行为**探针（不是只 grep 源码）：report 30/0（抓到一个 `table.concat` 真崩溃）、whatsnew 15/0、capability 16/0、bank-parity 37/0、slot-info 18/0 | 同上 |

**模块数**：18 → **20**（11-04 深夜新增 `Report`、`WhatsNew`），启动行应显示 `已加载 20/20 个模块`——
**这是第一个判据**：任何"背包没窗、按钮没字"先看这一行（11-04 有过一次我部署了编译不过的
`Bags.lua`，模块整个没加载，症状是"按 B 没反应"）。

### 2.2 今天**没有**实机证据的东西（明天必须看）

11-03 的 15 个视觉提交 + 11-04 的银行/等级数字/折叠面板/`/mui report` 全部只经离线闸门与
12.1.5 预验（预验记录在 `docs/PRECHECK-RETAIL-120105.md`：P2.4 接管可逆、P2.14 自动存入只动
打了标记的物品=非缺陷、P2.21 拖放可用）。**harness 不调斜杠命令、替身世界没有真实布局**，
所以观感、掉落、report 输出这三类只有明早算数 → 按 `docs/VERIFY-1.60-CHECKLIST.md` 的
**R1.0（`/mui report`）→ R1.1–R1.7 → R7.5–R7.11（含 R7.8 银行主页索引、R7.8b 拖放、`bagID字段`）**。

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
- ~~**仍开着**：暴雪小队/团队框与自绘框重复~~ —— **已解决（2026-11-02 核实代码）**：
  `Groups.lua` 的 `SetBlizzardHidden`（`groupFrames.hideBlizzard`，默认 `true`）对
  `CompactPartyFrame` / `PartyFrame` / `CompactRaidFrameContainer` / `CompactRaidFrameManager`
  做**饿事件 + alpha 0 + 关鼠标**（不 Hide / 不 SetParent / 不写字段），自绘 GroupFrames 开着时自动藏暴雪框；
  LoD 晚到由 `ReparkBlizzardGroups` 三时机补做。作者要"共存"就把 `hideBlizzard` 关掉，退回完全放手。

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

> **2026-11-03 补：整个模块已删除（`48d9c70`）。** 下面这段"进出战斗提示"的设计与贴图
> 现在由 `Modules/Toast.lua` 的横幅承担（`Toast:Notify(head, text, { icon, tint, hold })`，
> 开关 `toast.combatAlert`）；浮动数字、CVar 接管、`MonetUICombatAlert` 自绘框与私有
> OnUpdate driver 全部移除。本节其余内容是历史记录，不再代表现状。

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
- [ ] 未动的模块各看一眼：Bags、InfoBar、Tooltip、Cursor、Toast、Durability、Skins 各窗口

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
>
> **`.toc` 里只允许 `#` 单行注释**（2026-11-02 实机判例，`37872e3`）：客户端把 toc 的**每一行都当成一个
> 文件名**，所以 `<!-- ... -->`（尤其跨行）会被拆成路径去打开，红字长这样 ——
> `MonetUI.toc:47 Couldn't open Interface/AddOns/MonetUI/信息条 / 小地图面板要压在暗角之上（…）。 -->`
> 报错信息就是注释正文，一眼看不出是语法问题。要写说明只在行首加 `#`，**一行写完别折行**；
> xml 清单里照旧用 `<!-- -->`（那才是真 XML 解析器）。同一份口径在 `AGENTS.md`「代码风格」那条后面。

---

## 8. 约定（作者定的，别自作主张）

- **不 push 远端**（游戏上线 + 初步测试前）；`origin` 只作私有备份，仓库必须保持 private。
- **参考插件只读**：`../EllesmereUI-v9.4`（开发根在位）与 Andromeda 只能读，不能改、不抄大段代码。
  **Andromeda 不在开发根**（`../Andromeda` 不存在，别再照它判"参考件缺失"），现存唯一拷贝 =
  `C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda`；
  比对用 `tools/compare-andromeda-close.js`（自带 TGA type-10 RLE 解码）。
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

> **2026-10-31 收口：圆角方案放弃，遗留全部删除。** `Widget:RoundBorder` / `PickRoundEdge` /
> `LayoutRoundBorder`、`ApplyBackdrop` 的 `opts.round` 分支、`Refresh` 的圆角上色块 —— 10-29 去掉
> `round = true` 之后这套就再没有调用点，这次连代码一起清掉。四张材质（`monet_round_edge{,_thin,_thick}`
> + `monet_round_fill`，源 TGA 与交付 BLP）连同 Media 键、生成器（`regen-textures.js` 的 `ROUND_EDGES`
> / `drawRoundEdge` / `drawRoundFill`）、`audit-pixels.js` 的 STENCIL / NO_SOFT_EDGE 名单、
> `test-mult.js` 的选环自测一并删除。面板从此只有直角 `SetBackdrop` 一条路径；
> 上面"要重试从 `6e233ed` 起"仍然有效，但那算**重新立项**，不是恢复。

#### 交付：直角版 BLP

- 分支 `square-blp`，`44a4334`（基线 `6288692`）：四处 `Widget:Theme` 去掉 `round = true`，
  遮罩回 `rx=0`，32 张 BLP 全部按 `alphaType=8` 重出。
- 门禁：`audit-pixels` 未通过 **0/32**、`luac -p` 5 个改动文件全过、mip0 与 TGA **逐像素一致**。
- 部署目标：`...\WOWFOREVER\World of Warcraft\_forever_\Interface\AddOns\MonetUI`。
  2026-11-02 起 `tools/deploy-retail.ps1` 的默认 `-Dest` 就是 `_forever_`、`-Interface` 16001，裸跑即可。

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

（**条件订正 2026-11-05**：这条只在 12.1.5 / 或 `taintLog` 没开时成立。《无限》1.60 · 70790 实测：
`C_CVar.SetCVar("taintLog","2")` 之后 BLOCKED **会写** taint.log，见 §8.38 末尾的订正段。）
开关关闭时本客户端对 `ADDON_ACTION_BLOCKED` 不写 taint.log，所以这一族还要靠我们自己记栈：
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
落盘在 `_retail_/WTF/Account/039124100/SavedVariables/MonetUI.lua`（1.60 那套对应
`_forever_/WTF/Account/<账号>/SavedVariables/MonetUI.lua`）。
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
| `panel` | 10 | `ambient` | 窗口底衬 |
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

## 8.20 2026-10-31 战斗里 /reload：背包只有标题、没有图标（+ 弹「界面行为失效」）

**玩家报的**：背包默认是开着的；战斗中 reload 之后背包只剩标题、没有物品图标，并弹「插件导致界面行为失效」。

**三个根因（同一个场景叠出来的）**

1. **`InCombatLockdown()` 在登录/重载当拍会给假的 false**。`AcquireButton` 靠它判"是不是战斗"，
   于是那一拍会去建**受保护的** `ContainerFrameItemButtonTemplate`、`ParkBlizzardBags` 也会对
   暴雪背包的受保护子按钮 `EnableMouse` —— 两者都会弹「界面行为失效」。
   改成文件里唯一的 `InCombat()`：`InCombatLockdown() or UnitAffectingCombat("player")`（后者兜住那一段）。
2. **战斗里 0 个格子是设计内**（模板按钮战斗里出生天生带污染，Ellesmere 同结论），
   但**脱战后没人补**：刷新靠 BAG_UPDATE + 0.5s 的"内容指纹轮询"，而**空窗口和满窗口的指纹一模一样**
   → 指纹没变 → 不重建 → 永远停在"只有标题"。
   补 `PLAYER_REGEN_ENABLED` 收尾：清 `bagSig/bankSig` + 重建已打开的窗口。
3. **停车延后在脱战当拍又判断成"还在战斗"**（HANDOFF 3.26 那个老毛病：`PLAYER_REGEN_ENABLED`
   派发时 `InCombatLockdown` / `UnitAffectingCombat` 还是旧值）→ 二次延后到"下一次脱战" = **永不 park**，
   玩家按 B 会看到暴雪背包和我们那套同屏。改成延后回调里换一个**新 tick** 再判断
   （`C_Timer.After(0, ...)`）。

**我自己引入又修掉的一个坑（教训）**：第一版把 `InCombat()` 写在 `local Secrets = ns.Secrets`
**之前**，函数体里的 `Secrets` 就成了全局（nil）——每次调用抛 `attempt to index global 'Secrets'`，
于是物品按钮一个都建不出来、暴雪背包也停不了车。`audit-locals` **抓不到这种**（它查未使用/遮蔽，
不查"引用了还没声明的 local"）。**新增 helper 一律放在它引用的 local 之后**；Lua 只有运行到才报错，
静态闸门给不了保险。

**实机验证（12.1.5.70688，玩家配合打的怪）**

| 场景 | 结果 |
|---|---|
| 战斗中 reload 后立刻探 | `shells=0`（设计内）、`blocked=0`、`errors=0` ← 不再弹框 |
| 脱战（什么都不做） | `totalShells=90`，7 个窗口自动补满 |
| 暴雪背包停车 | `ContainerFrameCombinedBags alpha=0 mouse=false`、`ContainerFrame1 alpha=0` |
| 最终态 | `windows=7 totalShells=91`、0 错误 0 blocked |

## 8.21 2026-10-31 分类背包登录时自动打开（玩家：不要默认打开）

**症状**：每次进游戏，分类背包都是开着的。

**真因**：客户端会把"上次退出时开着的"暴雪背包在登录后恢复成 `shown`。我们那套分类窗口的
打开信号**只有**这条边沿（本客户端 BAG_OPEN/BAG_CLOSED 不发，见 §592 的探针记录），守卫就把
"登录后本来就开着"误判成"玩家按了 B"，于是每次都弹我们的窗口。

**修法**（`Modules/Bags/Bags.lua` 的 `Initialize`）：登录时先看暴雪背包是不是 shown ——
不是战斗就 `Hide()` 掉（停车已经让它们不可见，这一步是为了让**状态**也回到"关"），
然后把守卫基线 `bagsVisualOpen` 设成"关"，这样第一次按 B 才是真正的 0→1 边沿。
战斗里关不掉（父框里有受保护子按钮）时基线设成"开"，避免一登录就弹窗。

## 8.22 2026-10-31 清理日志：删除圆角 9-slice 遗留 + 注释瘦身

两件事都是**零行为改动**的清理，闸门全绿。

### 8.22.1 圆角 9-slice 方案放弃，遗留全部删除

方案本身在 2026-10-29（分支 `square-blp`，`44a4334`）就已经把最后一个 `round = true` 调用点
拿掉了 —— 此后 `Widget:RoundBorder` 一整套是**死代码**，只是没人删。这一轮把它连同材质一起收口
（详见 8.5.1 末尾的补充说明）。

| 位置 | 删了什么 |
|---|---|
| `Utils/Widget.lua` | `ROUND_EDGES` / `ROUND_TEX` / `ROUND_SLICE`、`PickRoundEdge`、`LayoutRoundBorder`、`Widget:RoundBorder`；`ApplyBackdrop` 里的 `if opts.round then … else` 双路径收成单一直角路径；`Refresh` 里给圆角件上色的那一块（2065 → 1890 行） |
| `Utils/Media.lua` | 4 个键 `monet_round_{fill,edge,edge_thin,edge_thick}` + 23 行说明；顺手修好三处悬空指针（minimap 遮罩改成指向 SVG 源 `tools/svg/minimap_rect_mask.svg` 与 `rx=0`） |
| `Assets-src/Textures`、`Assets/Textures` | 4 张 TGA + 4 张 BLP（其中 3 张 BLP 在这之前已经不在工作树里了） |
| `tools/regen-textures.js` | `ROUND_EDGES`、`ringPolyline`、`distToSegments`、`drawRoundFill`、`drawRoundEdge` 及各自的 draw/size 映射（1085 → 907 行） |
| `tools/audit-pixels.js` | `NO_SOFT_EDGE` 里的 4 个圆角名、`STENCIL` 里的 3 个（现 STENCIL 21 张；`AGENTS.md` 原来写的 28 是更早的陈数，已改成 21） |
| `tools/test-mult.js` | 整个「圆角边框选环」测试段（262 → 203 行） |
| `tools/gen-minimap-mask-ab.js` | A/B 对比图里的 9-slice 边框换成两行 `strokeRect`（近似 `Color.edge`），只影响这张对比图 |
| `tools/make-scenario-assets.js`、`make-pixel-grid-sheet.js`、`make-full-preview.js`、`analyze-monet-linewidth.js`、`make-variant-index.js`、`docs/texture-preview-data.js` | 圆角相关的条目/说明 |
| `AGENTS.md`、`MonetUI.md`、`docs/HANDOFF.md` | 「圆角边框是自绘 9-slice」那条约定改成"方案已放弃"，资源表里的圆角行删除。**带日期的决策记录（`MonetUI.md` 1202/1208/1220、`tools/deprecated/`）保留**——那是历史，不是现状 |

**下次有人再提圆角**：先回答"引擎 `edgeFile` 渲染碎线这个问题解决了没有"。没解决就还得自绘，
而自绘那一套已经试过、实测放弃了。

### 8.22.2 注释瘦身（12 个文件）

`Modules/ActionBars/{ActionBars,Blizzard,DragDrop,PetBar,Secure}.lua`、
`Modules/Cooldown/Cooldown.lua`、`Modules/UnitFrames/{Auras,CastBar,ClassPower,Groups,UnitFrames}.lua`、
`Utils/Widget.lua`。只删"复述代码在做什么"和"记录本次任务改了什么"的注释；
**判例、客户端行为口径、机密值/污染纪律一律留下** —— 那些是踩坑换来的，不在代码里。

### 8.22.3 闸门结果（全部离线，本车道不进游戏）

| 闸门 | 结果 |
|---|---|
| `luac -p`（12 个被改的 Lua 文件） | OK |
| `node tools/api-audit.js` | `result: no hard finding.`，退出码 0 |
| `node tools/audit-pixels.js` | 未通过 0 / 32；非纯白衬底 0 |
| `node tools/test-mult.js` | 全部通过 |
| `node tools/gen-minimap-mask-ab.js` | 正常出图 |

**清日志时顺手抓到的键名缺陷（已修）**：`Modules/UnitFrames/BossFrames.lua:120` 原来写
`media:Texture("monet_role_healer")`，而 `Utils/Media.lua:295` 注册的键是 `monet_role_heal`。
**它不报错、只是图标空白** —— `Media:Texture` 对未知键静默回退 `blank`（`Utils/Media.lua:352`），
和皮肤层当年 `Color:Get` 回退 `edge` 是同一类"静默兜底掩盖键名错"。
已扫过全仓：所有字面量 `Media:Texture("…")` 的键现在都在注册表里；动态键（键来自变量）只剩 7 处 ——
`Minimap/Buttons.lua:170`、`Groups.lua:418`、`Skin.lua:886/1136`、`Widget.lua:717/853/865`。

**同源的另一处**（首领框职责图标没染色）已在 8.23 一并补齐，顺带挖出 `Color:RoleTint` 从未生效过。

## 8.23 2026-10-31 role 图标补齐：RoleTint 三个 API 名全错，染色从未生效

**症状（推断，未实机）**：小队 / 团队框里的队长、助理，职责图标颜色和普通成员一样 —— 灰阶模具的
原色，没有走高亮槽。

**真因**（`Utils/Color.lua:301` 原来那一行）：

```lua
local ROLE_MARKS = { "IsGroupLeader", "IsRaidLeader", "IsGroupAssistant" }
```

**这三个名字本客户端一个都没有。** 1.60 快照里实际存在的是
`UnitIsGroupLeader(unit, partyCategory?)` / `UnitIsGroupAssistant(unit)` / `UnitIsRaidOfficer(unit?)`
（`node tools/api-lookup.js <名字>`；`IsRaidLeader` / `UnitIsRaidLeader` 都不存在，
"助理/军官"这一档在本客户端叫 **RaidOfficer**）。而 `Color:RoleTint` 的取法是
`local api = _G[ROLE_MARKS[i]]; if type(api) == "function" then …` —— 错名让 `_G[...]` 恒为 nil，
循环一次都不进，`marked` 恒 false，函数**恒返回 1,1,1**。

**为什么所有闸门都是绿的**：`api-audit` 扫的是代码里写出来的名字（`_G.X` / `C_X.Y(...)` /
`Enum.X.Y`），**查不到"存在字符串表里、运行期才 `_G[...]` 取"的名字**；`wuxian check` 同理。
错名的后果又不是报错，而是"静默走默认分支" —— 和 `Media:Texture` 未知键回退 `blank`（8.22.3）、
皮肤层 `Color:Get` 未知键回退 `edge`（AGENTS「颜色键只有一张表」条）是**同一类**：
静默兜底把拼写错误变成"看起来正常但没有效果"。

**修法**：

| 位置 | 改动 |
|---|---|
| `Utils/Color.lua:301` | `ROLE_MARKS` 换成 `{ "UnitIsGroupLeader", "UnitIsGroupAssistant", "UnitIsRaidOfficer" }`，并把"名字必须带 Unit 前缀 / 本客户端没有 RaidLeader / 这三个都是 SecretWhenUnitIdentityRestricted"写成注释；删掉那句已经过期的 `TENTATIVE: no call site consumes this yet`（现在有两个消费点） |
| `Utils/Color.lua:323` | **返回值个数也是坑**：原来 `if marked then return self:GetHighlight() end` —— `unpackColor` 是**四个**返回值（带 a），于是"队长/助理"这条路返回 4 个、"普通成员"返回 3 个。调用点若写 `SetVertexColor(RoleTint(unit))`，第 4 个返回值就成了 alpha，而**顶点色 alpha 与 `GetAlpha()` 是同一个存储**（AGENTS「客户端行为细则」）—— 图标会跟着主题高亮的 a 变淡。改成截断到 RGB（与 `GetSurface` 同一口径：不透明度归调用点决定） |
| `Modules/UnitFrames/BossFrames.lua:112-133` | 职责图标那段重写成"先选键、再 `SetTexture` + `SetVertexColor(color:RoleTint(unit))`"，和 Groups 同一口径；顺手把手写的 `not secrets.IsSecret(role)` 换成 `secrets.CanRead(role)`（AGENTS：新代码不要再自己手写 issecretvalue 分支）。**首领没有职责时仍然整块 Hide**，不跟 Groups 那样退回 dps 图标 —— 首领框上画一个"输出"图标是编造信息 |
| `Modules/UnitFrames/Groups.lua:404-422` | `UpdateRole` 原来直接 `role == "TANK"` 比较：受限时 `UnitGroupRolesAssigned` 返回**机密串**（`type()` 照样是 `"string"`），比较会抛 —— 正是 AGENTS 2026-10-26 那条判例。加 `Secrets.CanRead(role)` 前置，机密时保持 dps 默认键 |

**验证**：`luac -p` 三个文件全过；`node tools/api-audit.js` → no hard finding，退出码 0；
三个新名字逐个用 `api-lookup` 对过快照（签名 + 机密标记都在）。
**染色本身要实机才看得出来**（要一个队长 + 一个助理在场），本车道不进游戏 —— 归集成道的 `/verify`。

**教训（可复用）**：
① 凡是"名字存在表里、运行期 `_G[name]` 取"的写法，加名字时必须逐个
`node tools/api-lookup.js` 核一遍；闸门扫不到这类名字，错名的表现是**静默失效**而不是报错。
② 一个函数的**返回值个数**要恒定：分支里一个 `return 4 个`、另一个 `return 3 个`，
在 `f(g(...))` 这种直接透传的调用点上就会把多出来的那个塞进不该塞的参数位（这里是 alpha）。
Color 的口径是"RGB 三件套，不透明度归调用点"，`unpackColor` 的第四个返回值只在该显式取用时才传下去。

## 8.24 2026-11-01 role 三枚模具按 8px 判据重画：E 盾 + C 十字 + H 并列双匕首

**为什么重画**：role 图标实显只有 **8–9px**（小队/团队框右上角
`Modules/UnitFrames/Groups.lua:284`，首领框复用同一套皮肤函数）。旧三枚
（斜盾 / 药瓶 / 单把斜剑）量下来 dps 在 8×8 只有 **3 格满墨**（64 格里），基本等于
看不见；成套三枚的最小区分度 48.8。

**过程**（台架全在本地，仓库后动）：`%TEMP%\mui-role-ab` 搭 A/B 台架
（`gen-roles.js` 渲染+测量、`build-sheet.js` 接触表、`build-page.js` 验收页），
先 A–E 五族整套量过给决策页；选定 **E 宽盾 + C 圆角十字** 之后，dps 按要求改做
"双匕首"，F/G/H/I 四个变体再量一轮、更新验收页，点名 H 才动仓库。

**判据（可复用）**：8px 下只看三个数 —— ① 8×8 降采样后满墨/半墨/空格数
（满墨多=清楚，半墨多=一团灰）；② 成套三枚两两互差（64 格平均 |Δalpha|，越高越好认）；
③ 硬规矩色相 0、alpha=0 纯白衬底。64px 大图只用来确认字形没画歪。
**dps 的生死线是和同族十字的互差**：任何带横杠/斜杠的变体都会被读成十字
（上一轮 E 的宽护手剑对十字 47.9；这一轮 F/G 交叉匕首 55.4 / 54.4，同一种撞车）。

**双匕首四变体实测**（8px 满/糊 · 覆盖 · 与 C 十字互差 · 成套最小对）：

| 变体 | 8px 满/糊 | 覆盖 | 与十字互差 | 成套最小对 |
|---|---|---|---|---|
| F 交叉（护手 0.32s） | 10/13 | 47.2% | 55.4 | 55.4 |
| G V 形（±0.50 rad） | 10/11 | 41.3% | 54.4 | 54.4 |
| **H 并列（±0.50s，中缝 2 格）** | **12/12** | **68.1%** | **101.6** | **69.6** |
| I 交叉无护手（护手 0.17s） | 12/11 | 48.6% | 56.4 | 56.4 |
| 参照：现役 dps | 3/10 | 33% | —（成套 48.8） | 48.8 |

**定 H 的理由**：四个里唯一"两把"在 8px 还活着的（放大 6 倍是两条竖杠、中缝 2 格 ——
第一版 dx 0.44 / 护手 0.34 中缝不足 1 格，并成一坨、半墨 22）；与十字互差 101.6 是
全矩阵最高的一对；成套最小对 69.6 与整族 E 的 69.7 打平。代价：64px 大图偏"双柱"、
细丝占比 13.1% 是四者最高 —— 8–9px 实显下看不见这个代价。
**否掉 F/G**：8px 都并成一坨斜灰，与十字互差 55.4 / 54.4。**I 是次选**（64px 下最
"匕首"），但交叉斜杠在 8px 输给十字的区分度，好看和认得出二选一。

**交付**：`tools/regen-textures.js` 三个画法重写 —— `drawRoleTank` 宽盾
（w 0.90s / 高 1.80s、常规渐变芯亮边暗）、`drawRoleHeal` 圆角十字（新 helper
`roundedPoly` + `PLUS_PTS`，臂半宽 0.24s / 圆角 0.20s）、`drawRoleDps` 并列双匕首
（新 helper `daggerPath`，刃半宽 0.24s / 护手 0.28s / 间距 ±0.50s）；旧的斜盾/药瓶/
斜剑画法删除。`node tools/regen-textures.js standard monet_role_<tank|heal|dps>`
重出 TGA 并同步 BLP（带完整 mip 链）。

**验证**：`node tools/audit-pixels.js` **32/32 PASS**（role 三张孤立 0 / 色相 0 /
衬底 0；半覆盖 tank 1152 / heal 1350 / dps 1804，软边 1/0/4 —— role 不在
NO_SOFT_EDGE 名单，曲线抗锯齿允许）。另做逐像素验收（台架 `verify-delivered.js`）：
交付 TGA 对台架 H 族渲染**可见像素差 0、alpha 差 0、alpha=0 全纯白衬底**。
（比对时 alpha=0 的 RGB 不参与：PNG 读回经 canvas 预乘会丢掉透明像素的 RGB，
那是读回artifact，不是交付缺陷。）

Media 键不变（`monet_role_tank/heal/dps`），STENCIL 名单不变（21 张），
调用点不变（8.23 的 Groups / BossFrames 两处）。台架与验收页只在
`%TEMP%\mui-role-ab` 和可视化目录 `monetui-role-ab.html`，不进 repo。

## 8.25 2026-11-03 姓名板压制：BetterNamePlates 的钩子方案（**只记录，未改代码**）

**背景**：`Nameplates` 现在用私有 `guardDriver`（`Modules/Nameplates/Nameplates.lua:747-764`）每 0.25s 对
所有已接管的板子重跑 `KeepBlizzardHidden`：
`uf:Show()`（若被藏）→ `uf:SetAlpha(0)` → `FadeBlizzardSiblings`（每拍 `{ base:GetChildren() }` 建表 +
逐子框 `SetAlpha` 写入）。原因是牌成为当前目标时暴雪自己的高亮代码把 `UnitFrame` alpha 顶回 1
（2026-10-28 实测 `blizzardHidden=true, ufAlpha=1.00`），而且没有可靠事件。
常态下这 4 次/秒几乎全是"把已经是 0 的 alpha 再写一遍"。

**参考实现（BetterNamePlates，含 Camelot 分支 = 本客户端同族）**：

- 抑制只用 `UnitFrame:SetAlpha(0)`，**不轮询**：接管时给该实例挂一次
  `hooksecurefunc(unitFrame, "SetAlpha", ...)`（`Runtime.lua:2046-2084`），回调里
  `if state.suppressed and unitFrame:GetAlpha() ~= 0 then unitFrame:SetAlpha(0) end`。
  目标高亮把 alpha 顶回 1 时，钩子在同一调用栈里立刻压回 0 —— 所以根本不存在"没有事件的复位"。
- 状态放**弱键表**（`Runtime.lua:41` `blizzardFrameStates`），记录接管前的**原 alpha**并在交还时还原
  （`Runtime.lua:2122-2124, 2138`），不硬编码 1，因此不破坏暴雪的距离淡出。
- **从不** `Show()` / `Hide()` / `SetParent` / `SetScale` 暴雪的姓名板框，也没有 sibling 遍历。
- 它的 OnUpdate（`Runtime.lua:2692-2710`）只管 hover（0.15s）与旧版施法文字，且**没有板子时会卸掉脚本**
  （`Runtime.lua:69-79`）。
- 生命周期走事件：`NAME_PLATE_UNIT_ADDED/REMOVED`、`PLAYER_ENTERING_WORLD`、
  `PLAYER_LEAVING_WORLD`（归还池化框），启动时用 `C_NamePlate.GetNamePlates()` 补一遍
  （`Runtime.lua:2979-2988`）。

**可借鉴的具体点**：

| MonetUI 现状 | 参考做法 | 价值 |
|---|---|---|
| 每拍 `uf:Show()` | 从不 Show（等游戏下一次 SetUnit/更新自己补） | 进本 9 条 `ADDON_ACTION_BLOCKED` 就来自这两处（见本文件 2026-11-02 那条注释） |
| 交还时 `SetAlpha(1)` | 还原接管前的原值 | 不破坏暴雪 0.6 距离淡出 |
| 0.25s 全量写 | 实例钩子按需写 + 读后写 | 常态写入/GC 归零 |
| 私有 OnUpdate | 无 | 少一个常驻帧 |

**为什么先不改（风险，必须交叉佐证）**：

1. `hooksecurefunc(unitFrame, "SetAlpha")` 钩的是**产物实例**，不是驱动/池 —— 与
   `NamePlateDriverFrame:UpdateNamePlateOptions`（生产者）不同类，但本客户端的污染是**按调用链**算的：
   钩子一跑，之后同一链上的暴雪代码就算 MonetUI 的执行环境。姓名板链有机密比较前科
   （`maxHealth` / `notInterruptible` / `isFullUpdate`），必须实机跑 `taint.log` 才能定。
2. **BetterNamePlates 自己也有那个禁用写法**：`Runtime.lua:2753-2763` 对
   `NamePlateDriverFrame:UpdateNamePlateOptions` 挂了 hook（刷友好 CVar）——
   它的 suppression 路径可参考，**那一行不可照抄**。
3. 它不做 sibling 淡出。我们注释里的 `base` 同级容器（`BuffListFrame` 一族、`SetIgnoreParentAlpha`）
   在 1.60 是否真实存在需要一次性探针确认（打印 `base:GetChildren()` 的名字 + alpha）：
   若它们其实是 `UnitFrame` 子框，`FadeBlizzardSiblings` 可以整段删除；若不是，保留低频兜底。

**待做（顺序）**：

1. 再挖 2–3 个插件交叉佐证钩子安全性（Plater / ElvUI / NDui / SilverNamePlates 之类），
   重点看它们有没有对姓名板 `UnitFrame` 挂方法钩子、以及有没有在 1.60 同族客户端上长期运行。
   —— **已完成（任务 #11，11-03）**：五家写法带行号入档、结论"钩子方案现阶段不可采纳"，见 **8.26.8**。
2. 安全半步（离线可做、零污染）：去掉每拍 `Show()`、读后写、缓存子框表、0.25s → 0.5s、
   并入 `Utils/Scheduler`。
   —— **已落地（`7108581`，逐条见 8.27.1）**；0.25s→0.5s 一项经 8.26.8 评估**暂缓**（不是待办可选项）。
3. 钩子半步：只在交叉佐证通过后做，并配 `taint.log` 实机验收。
   —— 交叉佐证**未通过**（8.26.8）：现阶段不做；上线日先跑 8.26.8 的六条探针，④ 是关键判据。

## 8.26 2026-11-03 交叉佐证：hook 到底能不能替掉轮询（三样本，**未改代码**）

接 8.25 待做第 1 条。第二个样本是 **BlizzThreatPlates-Forever**（`.toc` 写 `## Interface: 16001`，
13100 行，**直接活在暴雪原生姓名板上**，不自建牌 —— 比 BetterNamePlates 更贴我们的场景）。
下面所有行号：`BTP` = `../BlizzThreatPlates-Forever`，`BNP` = `../BetterNamePlates`。

### 8.26.1 三样本合起来的根因修正（要回写 AGENTS.md 的那句）

8.25 里"钩的是产物实例还是生产者"这个分类**不是决定性的**。真正的判据只有一条：

> **`[受限]` API 不允许出现在暴雪自己的调用链里** —— 既不能在 hook 回调体内，
> 也不能在事件派发栈里；要调就 `C_Timer.After(0, …)` 顶到新 tick + `not InCombatLockdown()`。

- 我们那次 `hooksecurefunc(driver, "UpdateNamePlateOptions", …)`（`c09867e` 删掉）之所以炸，
  是**钩子体里调了 `C_NamePlate.SetNamePlateSize`**，而快照给它标了 `[受限]`
  （`docs/api` ← `nameplatedocumentation.lua`；`node tools/api-lookup.js SetNamePlateSize` 可复核）。
- 同一个函数，BTP 照用不误（`BTP/NameplateDimensions.lua:77-88`），三条纪律齐备：
  ①不在钩内 ②事件 → `ScheduleRefresh`（:117-127）→ `C_Timer.After(0, Run)` ③`not InCombatLockdown()`。
  设计原话在 :113-115：*"Finish after Blizzard's event handlers have laid out the plates,
  **without hooking methods on its pooled UnitFrames or nameplate driver.**"*
- BNP 那两个钩（`BNP/Runtime.lua:2065-2079` 钩 `unitFrame.SetAlpha`、:2746-2763 钩驱动方法）没炸，
  是因为**体内只调非受限方法**（`Frame:SetAlpha` 快照无限制标记、还额外标 `[允许污染代码传机密]`；
  `C_CVar.SetCVar` 也非受限，且战斗时只记 `friendlyCVarPending` 延后，:2735-2738）。

### 8.26.2 BTP 的钩子分布：装暴雪东西的只有 8 处，且体内零受限调用

| 类别 | 处数 | 证据 |
|---|---|---|
| 钩**暴雪全局更新函数** | 4 | `CompactUnitFrame_UpdateHealth`（`BTP/MobNameSize.lua:207`）、`_UpdateName`（:213）、`_UpdateHealthColor`（`Threat.lua:243`）、`_UpdateLevel`（`ATDStyle.lua:996`） |
| 钩**暴雪控件方法** | 4 | `selectedBorder` 的 `SetAlpha` / `Show` / `SetShown`（`NameplateBorders.lua:185, 192`、`ATDStyle.lua:478-486`） |
| 钩自建对象 | 6 | `NameplateBorders.lua:306`、`ComboPoints.lua:549` |

`SetScript` 195 处、`RegisterEvent` 108 处**全在自建框**（搜 `plate:SetScript` / `UnitFrame:SetScript` /
`castBar:SetScript` 零命中）；`HookScript` 37 处里只有 1 组打在暴雪框上（`RaidTargetFrame`，
`NameplateAttachments.lua:259-261`）。**没钩过 `NamePlateDriverFrame`。**

钩子体里最终只调 `SetFont` / `SetTextHeight` / `ClearAllPoints` / `SetPoint` / `SetWidth` /
`SetJustifyH` / `SetAlpha` / `SetShown` / `SetStatusBarColor` —— **一个 `C_*` 受限调用都没有**。
字体这条链确实**没有 OnUpdate**（`MobNameSize.lua:233-264` 只有事件 + `C_Timer.After(0)`）。

它另外两件事是"钩子敢用"的前置条件，我们现在一件都没有：

- **身份收敛**（`MobNameSize.lua:137-165`）：`CompactUnitFrame_UpdateName` 是姓名板**与小队/团队框共用**
  的函数，所以钩子体第一关是 `IsForbidden()` + `unit:match("^nameplate%d+$")` + 显式拒 `partyN/raidN`
  （:152-154）+ `plate.UnitFrame == frame` 回指校验（:164）。不收敛 = "改姓名字号顺手改了玩家小队框"。
- **挂钩前先判函数存在**：`if hooksecurefunc and CompactUnitFrame_UpdateHealthColor then`（`Threat.lua:242`）。

### 8.26.3 BTP 划了一条比 BNP 更严的线（这条决定我们采不采纳钩子）

`BTP/NameplateAttachments.lua:149-151` 原话：

> *"Secure AuraButtons must remain script-free: **even hooks installed during initialization make
> Blizzard's later SetShown(secret) fail.** Only our ordinary sample Frames may publish visibility
> through script handlers."*

同一处把 `HookScript` 关进 `previewOnly` 分支（:152）—— **真实 AuraButton 一个钩子都不装**。
这是第三方在**我们踩过的同一个对象**（AuraButton 的 shown 由机密载荷驱动，见 AGENTS"战斗光环硬禁读"
与 `__monetAuraHook` 判例）上独立得到的结论。

于是 8.26.1 那条判据要补一个限定：**边界不是"体内调不调受限 API"，还包括"被钩的那个方法会不会
以机密载荷被暴雪自己调用"**。`SetShown(secret)` / 机密 alpha 那一类，连钩子都不能存在。
BNP 钩 `unitFrame.SetAlpha`、BTP 钩 `selectedBorder.SetAlpha` 都没炸 —— 但按 BTP 自己的论证，
这一档属于"载荷暂时不机密"的**运气**，不是设计。→ **8.25 的钩子方案不能无条件采纳，仍需 `taint.log` 实机。**

### 8.26.4 "hook 替掉轮询"的答案是分档，不是替代

BTP 并没有把轮询删掉：威胁这条是**事件 + 轮询并存**（`UNIT_THREAT_SITUATION_UPDATE` /
`UNIT_THREAT_LIST_UPDATE`，`Threat.lua:260-261`；0.10s OnUpdate :5/:305；差分 0.25s
`ThreatDifferential.lua:342`），而 `Threat.lua:107` 注释 *"Clear first: Blizzard's update calls our
hook again"* 说明**钩子会重入、时序要轮询兜**。它 `ThreatPercentage.lua:110` 还专门写
"不要再开第二个轮询" —— 作者把轮询当稀缺资源在管。

| 状态类型 | 该用 | 依据 |
|---|---|---|
| "暴雪重算之后补一刀"（字体、血条色、文本对齐） | **钩暴雪全局更新函数**（体内非受限 + 身份收敛） | `MobNameSize.lua:207-215`、`Threat.lua:227-244` |
| "只有玩家改设置才会变"（牌子尺寸） | **事件 + `C_Timer.After(0)` 合并**，不钩不轮询 | `NameplateDimensions.lua:113-155` |
| 让暴雪自己顶（尺寸档位 / 样式 / 亮度 / 信息位域） | **CVar**，写不动就排队 | `Core.lua:956`、`NameplateStyles.lua:208`、`Options.lua:874` |
| 高频读值（威胁百分比） | 事件 + 低频轮询 | `Threat.lua:5`、`ThreatDifferential.lua:342` |
| 悬停 / 可读性 / 选中 | 只能轮询或事件（本客户端无 `MouseIsOver`） | 我们的 `HoverWatch` / `PollWatch` |
| 会被机密载荷驱动的方法（`SetShown` / 某些 `SetAlpha`） | **不装钩** | `NameplateAttachments.lua:149-151` |

### 8.26.5 两家共有的反例：往暴雪对象写字段（别学，也别拿"它没事"当依据）

BNP：`basePlate.BetterNamePlatesView = view`（`Runtime.lua:868`）。
BTP：`hb.btpHealthAlignment`（`MobNameSize.lua:130`）、`bar.btpThreatColored`（`Threat.lua:101`）、
`frame.btpATDOverlay`（`ATDStyle.lua:428`）、`widget.btpATDOriginalAlpha` / `btpATDLevelShowHooked`
（:470/:477）、`plate.btpTargetNameFront`（`TargetNames.lua:151`）。
BTP 甚至**双轨混用**：同一个"是否已装钩"的语义，`NameplateAttachments.lua:248` 用旁表 `hooked[frame]`，
`ATDStyle.lua:477` 用暴雪控件字段 —— 作者自己没把它当原则。
两家全文的 `taint` 都只出现在注释里（`Core.lua:388`、`NativeCCFallback.lua:48`），
**都没有 `issecurevariable` 逐键自检、没有拦截计数**。我们是**有实测判例**的一方
（`__monetAuraHook` 那个键 false → `CompactUnitFrame_OnUpdate` 报 `maxHealth`、10 秒刷屏），
所以"它们这么写也没炸"证据强度低于我们自己的账本，`ns:Mark` 旁表这条不动摇。

### 8.26.6 顺手挖到的三条工具级线索（都可在离线先落一半）

1. **`SimpleFrameScriptObjectAPI:CanBeAccessedInContext` 是本客户端正规 API**
   （`docs/api` ← `SimpleFrameScriptObjectAPIDocumentation.lua:45`，索引 `FUNCTIONS_INDEX.md:5961`）。
   BTP 优先问它、`IsForbidden` 只当退路，理由写在 `NameplateAttachments.lua:158-166`：
   *"temporary aura restrictions do not necessarily set the ordinary forbidden flag."*
   → 我们的 `Widget:Readable` / `VisibilityOf` 现在只认"调 `IsVisible` 抛不抛"，**判定档位比客户端给的弱**；
   这也接上"读不出来的框挂进轮询永久空转"那笔账。我们仓里只有扫描脚本认识这个名字
   （`.opencode/skills/wow-secret-value-guard-audit/scripts/scan-secret-guards.cjs:136`），Lua 侧一个都没用。
2. **CVar 能不能写，客户端给了正规问法**：`C_CVar.GetCVarInfo(name)` 返回
   `value, defaultValue, isStoredServerAccount, isStoredServerCharacter, isLockedFromUser, isSecure, isReadOnly`
   （`CVarDocumentation.lua:91-100`），而 `C_CVar.SetCVar` 的文档要求写着 `RequiresNonSecureCVar = true`（:131-136）。
   → **待测风险**：`Modules/Nameplates/Nameplates.lua:61-68` 那 8 个 `nameplateShow*` / `nameplateMaxDistance`
   由 `WriteCVar`（:76-79）**无条件写 + pcall 吞结果**。若其中有 `isSecure`，对应设置项就是**长期空转、
   一行红字都不响**。BTP 的写法可照：`Core.lua:149` 先 `tonumber(GetCVar(name)) ~= tonumber(value)` 再写。
3. **`CVAR_UPDATE` 是"值已变"的通知，不是触发器**：进出战斗本身不会发它，要它发得先有人写。
   → 上一轮讨论的"进战斗显示姓名板 / 出战斗隐藏"**不能靠 CVar 实现**：
   `isSecure` 的 CVar 插件根本写不了（与战斗无关），非 secure 的"战斗中禁写"那一类，
   进战斗那一拍也已经没有安全落点（`PLAYER_REGEN_DISABLED` 派发当拍原始标志可能是旧值，见 AGENTS）。
   **正解仍是我们自己的压制**：脱战 `Widget:Mute`（α0 + 关鼠标，绝不 `Hide`，命中测试锚在暴雪血条上，
   见 `Modules/Nameplates/Nameplates.lua:729-730`）+ 停止喂牌；进战斗 Unmute + 开始画。

### 8.26.7 待做（覆盖 8.25 的三步，顺序按风险从低到高）

> 2026-11-03 状态：**第 1 条已落地 `7108581`**（逐条见 8.27.1），第 3 条的 `probe cvar` 已建好待实机跑，
> 第 2 条未动；**第 4 条（钩子半步）有终判 —— 交叉佐证五家已跑完（任务 #11），现阶段不采纳，见 8.26.8**。

1. **零风险、离线可做**（把 8.25 第 2 步和 8.26.6 合并）：守卫去掉每拍 `Show()`、改"读后写"、
   无可见牌时整条驱动停摆（现在 `M.active` 只是 OnUpdate 内部早退，帧还每帧醒）、并入 `Utils/Scheduler`；
   `Widget:Readable` 先问 `CanBeAccessedInContext`；`WriteCVar` 加 `GetCVarInfo` 守卫 + 先读后写 + 失败记账。
2. **尺寸链改造**：2 秒轮询（`Nameplates.lua:189-201`）→ 事件（`CVAR_UPDATE` 按 `^nameplate` 过滤 /
   `NAME_PLATE_UNIT_ADDED` / `UNIT_FACTION` 带机密守卫 / `PLAYER_TARGET_CHANGED` / `UI_SCALE_CHANGED` /
   `DISPLAY_SIZE_CHANGED`）→ 合并一次 → `C_Timer.After(0)` → 才允许 `[受限]` 调用。**零钩子、零空转拍。**
3. **实机探针**（客户端开着时）：`/mui nameplates probe cvar` 打那 8 个 CVar 的
   `isSecure / isReadOnly / isLockedFromUser / defaultValue / 当前值` + `SetCVar` 的 pcall 返回 +
   `CVAR_UPDATE` 自记计数；顺带按 8.25 第 3 条打印 `base:GetChildren()` 的真实名字，决定
   `FadeBlizzardSiblings` 能不能整段删。
4. **钩子半步（只在探针 + `taint.log` 之后）**：若采纳，装的是**暴雪全局更新函数**
   （`CompactUnitFrame_UpdateName` / `_UpdateHealth`），体内只调非受限方法 + 带 8.26.2 的身份收敛；
   **不装在任何"机密载荷会经过的方法"上**（`SetShown` / AuraButton 一类，见 8.26.3）。

### 8.26.8 2026-11-03 任务 #11 终判：五家交叉佐证完毕 —— **钩子方案现阶段不可换，轮询保留**（只记录，未改代码）

**总结论（作者拍板的"先再挖 2–3 家再定"到此回答：证据不够，需实机）**：
`hooksecurefunc(unitFrame, "SetAlpha")`（BNP 式）**盖不住 base 同级 sibling 的回压** —— sibling 存在是我们
自己的实机判例（`Modules/Nameplates/Nameplates.lua:513-517`：每块牌 base 上有 1 个匿名 StatusBar+Frame 容器、
随距离衰减 α0.60 可见，有减益时暴雪还**动态再建** BuffListFrame 一族容器），钩子只装在产物层 `UnitFrame`
一个对象上，sibling 的回压没有任何东西挡 —— **轮询删不干净**。另一半：**"钩方法槽 = 写过该框"对后续
CompactUnitFrame 更新是否标脏，离线判不了**（本仓判例：`CompactUnitFrame.lua:1211 maxHealth`、`:668 机密键索引`，
都是"框被写过"之后暴雪自己的代码以 MonetUI 名义跑出的错）。⇒ **不改代码**，判定材料补齐要等实机（见文末探针）。

**五家样本写法（行号本车道 11-03 全部只读抽查过；两家 frameworks 的驱动钩是"反例旁证"，不是实证）**：

| 样本 | 抑制/驱动写法 | 关键行 | 定性 |
|---|---|---|---|
| BetterNamePlates | 钩**产物层** `unitFrame.SetAlpha`、体内读后写回、弱键旁表记原 α；全程不 Show/Hide/SetParent 暴雪框 | `Runtime.lua:2046-2084`（钩+回写 `:2076-2077`）、`:41`（弱表） | suppression 路径可参考；**它另钩了驱动方法** `UpdateNamePlateOptions`（`:2753-2763`，本仓禁用写法）→ **不可照抄** |
| NDui（oUF 系） | 每块牌 `NAME_PLATE_UNIT_ADDED` 时**饿事件**（`UnregisterAllEvents`），**零 alpha 写入**；钩驱动方法 `UpdateNamePlateSize`、体内只写自家框 + 战斗门 | 饿事件 `Libs/oUF/blizzard.lua:18-75`、`:152-155`（`handleFrame(frame.UnitFrame)`）；钩 `Modules/UFs/Nameplates.lua:65`、门 `:41`（`InCombatLockdown() then return`） | "饿事件"是第三条路（不改 alpha）；钩驱动**长期存活 = 旁证**：AGENTS"驱动一碰产物全脏"口诀**不是物理定律**，取决于体内写什么 —— 记成旁证，别记成实证 |
| ElvUI（oUF 系） | **全自绘** + CVar 管暴雪可见性（`nameplateShow*` 全家）；只有驱动级部件才 `Hide()`+饿事件；钩 `SetupClassNameplateBars` 带 `IsForbidden` 门 | CVar 群 `ElvUI/Game/Shared/Modules/Nameplates/Nameplates.lua:179-222`；`HideClassNameplateBar :1016-1021`；钩 `:1103`（体内 `:1024` 判 Forbidden） | 同旁证；**它 Hide 的只有 class-power 条**（非产物 UnitFrame），与 AGENTS"产物不 Hide"不冲突 |
| Platynator | 把暴雪 `UnitFrame` **`SetParent` 进常隐框** + `UnregisterAllEvents`；直接 `NamePlateDriverFrame:UnregisterEvent`；体内调**受限** `C_NamePlate.SetNamePlateSize` | `Display/Initialize.lua:880-886`、`:91`、`:684` | **反面样本**（三条全踩本仓红线）；"它还在跑"只能证明拦截进日志不弹窗，不证明干净 —— 口径同 8.26.5 |
| oUF 系挂回 base | 把 `WidgetContainer` / `SoftTargetFrame` **重挂回 nameplate（base 层）**（暴雪自己的 widget 槽是 UnitFrame 的子件） | NDui `Libs/oUF/ouf.lua:1075-1077`；ElvUI `…Shared/oUF/ouf.lua:981-983` 邻段（`SetParent(self.blizzPlate)` 在 `ElvUI/…/Nameplates.lua:872-877`） | 反例：动暴雪框的**父子拓扑**比动 alpha 更重；我们不做 |
| 五家共同点 | **无人对 nameplate `SetName` 改名**（全仓 grep 零命中） | — | 改名这条红线没有先例背书 |

**新线索① hit-test API —— 本车道已离线核过一半（1.60 快照在，判据可先行）**：NDui `Libs/oUF/private.lua:83`
只是 **Forever 分支的判定行**（`Forever = interface >= 16000 and interface < 20000`，调用点不在那，交办行号订正）；
真正的用法：NDui `Libs/oUF/ouf.lua:1090-1091`（裸调）、ElvUI fork `ouf.lua:981-983`（`if nameplate.SetAllHitTestPoints
then` **存在性守卫**）、Platynator `Initialize.lua:555`。
**离线核对结果（主仓 `docs/api` 快照，客户端 1.60.1.70634）**：`ClearAllHitTestPoints` / `SetAllHitTestPoints` /
`SetHitTestPoints` / `GetHitTestPoints` / `CanChangeHitTestPoints` 全在 `frameapinameplatedocumentation.lua`
（文档原文："Clears the anchor points that determine where the mouse interacts with the nameplate"）——
**1.60 存在这条不用赌**；配套 `C_NamePlateManager.GetNamePlateHitTestInsets` / `SetNamePlateHitTestInsets`
（后者标 **[受限]**，只能在非受限窗口调）。若实机验证成立，这可能是我们"**不敢 `Hide` 又要不误选**"的正解
（AGENTS：C++ 命中区锚在暴雪血条上，`SetAlpha(0)` 不影响命中 —— hit-test 点恰好就是那条 C++ 机制的正规接口）。
**上线日验证**：①假人牌被我们接管后 `nameplate:GetHitTestPoints()` 能否读到、②`ClearAllHitTestPoints` +
`SetAllHitTestPoints(自家框)` 之后点原血条位置是否不再选中、③整程 `taint.log` 是否仍空。
**新线索② sibling 名单无第二样本 —— "grep 零命中"要订正**：五家目录 grep `BuffListFrame` 并非零命中 ——
BTP `NativeCCFallback.lua:132` 有 1 处，但那是它压暴雪**原生 CC 列表**时枚举 `AurasFrame` 的槽名
（`CrowdControlListFrame/LossOfControlFrame/DebuffListFrame/BuffListFrame`），**不是姓名板 base 同级容器**的样本。
⇒ 结论不变：**姓名板 sibling 名单五家都没碰过**（BNP 明确不 fade sibling，NDui/ElvUI 饿事件绕开），
名单只能靠我们自己实机打印（探针④）。

**先确认、不当待办**：8.25"待做第 2 条"与 TODO 第 15 条里"零污染半步"的**删每拍 `Show()` / 读后写 /
迁 `Utils/Scheduler` 已落地 `7108581`**（本车道核过：commit 存在、是 `cd1f6d7` 祖先、标题
*"nameplates: 落实 8.26.7 第 1 档（零风险那半步），未动钩子方案"*，逐项明细在 8.27.1 表）。
**只剩 0.25s→0.5s 一项，且调研会话建议暂不动**：`PLAYER_TARGET_CHANGED` 已即时补刀
（`Nameplates.lua:1090-1096`，切目标当拍 `KeepBlizzardHidden`），放宽间隔只省读次数、代价是最多多 0.25s 的
回潮窗 ⇒ **等账本证明常态零写再议**，不排上线前待办。两处旧文（8.25 待做第 2 条、TODO 15）已按此订正。

**上线日姓名板探针（归验证清单，CHECKS C2.1 同名条目）**：
① `taintLog=2` 打一整本，`Logs/taint.log` **必须全空**（盯 `CompactUnitFrame:1211`/`:668` 两判例位）；
② `ADDON_ACTION_BLOCKED` 计数对比基线（进本那 9 条应归零 —— `7108581` 删 `Show()` 的预期收益）；
③ `/mui nameplates probe cvar`（8 个 `nameplateShow*`/`maxDistance` 谁被 `isSecure` 锁）；
④ 打印 `base:GetChildren()` **真名+alpha**（定 `FadeBlizzardSiblings` 存废）——**关键判据**：只有给出
稳定名单且 ①② 干净，才允许考虑试 BNP 式钩子分支；
⑤ 假人切目标 **≤1 拍不回潮**（验 8.26.8 的"sibling 回压钩子盖不住"判定）+ 关模块后 0.60 距离淡出还原；
⑥ `/mui restrict` 暂停框清单（姓名板框不应常驻其上）。

## 8.27 2026-11-03 第 1 档落地（`7108581`）+ 第四样本：EnhanceQoLUnitFrames 怎么藏暴雪队伍框

### 8.27.1 已落地：8.26.7 第 1 条（零风险那半步），钩子方案一行都没动

只碰 `Modules/Nameplates/Nameplates.lua` 与 `Utils/Widget.lua`（266+/34-），commit `7108581`。逐条与**失败方向**：

| 位置 | 改了什么 | 为什么这样改 |
|---|---|---|
| `Nameplates.lua:876-905` | 私有 `guardDriver`（自己的 OnUpdate + `M.active` 内部早退）→ 订进 `Utils/Scheduler`，`M:SyncGuard()` 按"有几块牌压着"起停 | 原来没有可见牌时**帧还每帧醒**；现在最后一块 `blizzardHidden` 牌交就整条 `Unregister`，master frame 自己隐 |
| `KeepBlizzardHidden`（:853） | **删掉每拍 `uf:Show()`** | 那一句没有战斗门，进本 9 条 `ADDON_ACTION_BLOCKED` 就来自它（8.25 表第 1 行）。alpha 0 的框**本来就一直算显示**，`Show` 只是给暴雪顶回来的机会 |
| `AlphaOf` / `NeedsFade`（:493 / :505） | 常态读后写；**读不出来照旧写** | 保守方向选"多写一次"而不是"少压一次"：读不到多半正在战斗，当成"不用写"等于把 2026-10-28 判例（当前目标 `blizzardHidden=true` 但 `ufAlpha=1.00`，和自绘牌同屏）放回来 |
| `FadeBlizzardSiblings`（:522） | ① `{ base:GetChildren() }` 里白建的第二张表删掉；②只把**真的写过**的 sibling 记进 `siblingAlpha` | 顺带修一个潜伏 bug：旧代码每拍无条件 `siblingFaded[c]=true`，交还时把整棵树顶回 alpha **1** —— 等于**抹掉暴雪实测 0.60 的距离淡出**（与 8.25 表第 2 行同一条病） |
| `HideBlizzardPlate` / `RestoreBlizzardPlate`（:550 / :588） | 接管前把 `UnitFrame` 的原 alpha 记在**我们自绘牌**的 `plate.blizzardAlpha` 上，交还还原它，不再硬编码 1 | 8.25 表第 2 行。字段只写我们自己的对象（AGENTS「绝不往暴雪对象写字段」） |
| `WriteCVar`（:124） | 先 `C_CVar.GetCVarInfo` 问 `isSecure / isReadOnly / isLockedFromUser` → 拒写并记账；先读后写；写完复验；每种失败原因每个 CVar 只 print 一次 | 8.26.6 第 2 条那笔"长期空转、一行红字都不响"。原来是无条件写 + `pcall` 吞结果 |
| `M:ProbeCVars`（:1218）+ `HandleCommand` | `/mui nameplates probe cvar`（另认 `/mui nameplates cvar`） | 离线判不了：快照只给签名，**当前值 / 当前客户端的锁定状态**只有实机有。按「短命令」规矩不做 `/run` |
| `Widget.lua:94-131` | `ContextAccess` 前置：`CanBeAccessedInContext` → `IsForbidden` → 才退回"`IsVisible` 抛不抛"；告警按两种原因分别归因；`Visible()` 也先问一次 | 8.26.6 第 1 条。**临时光环限制不置 ordinary forbidden 旗**，老判据对那种框一直答"可读"、回调每拍照跑。它的返回带 `[机密[SecretReturnsForAspect]]` → **只有拿到非机密 boolean 才改判**，问不出来不动老结论（误判方向是"静默少换肤/永久空转"，两边都不许猜） |

闸门（离线）：`api-audit` HARD 全清、`audit-taint` 0 BLOCKER（剩 1 条 HIGH 是 DevTools 里既有的
`hooksecurefunc("ChatEdit_InsertLink")`，与本档无关）、`audit-locals` 53/53、`check-frame-list` 373 一致、`luac -p` 通过。

**仍未验（客户端开着时一趟跑完）**：

1. `/mui nameplates probe cvar` → 那 8 个 `nameplateShow*` / `nameplateMaxDistance` 里到底几个 `isSecure`
   （决定 `viewDistance` 这类设置项是不是本来就在空转）。
2. 进本打一轮：`taint.log` 空 + 那 9 条 `ADDON_ACTION_BLOCKED` 消失。
3. 关模块 → 暴雪牌还原成**接管前那个值**（0.6 距离淡出还在），不是 1。
4. 打印 `base:GetChildren()` 的真名 → 决定 `FadeBlizzardSiblings` 整段能不能删（8.25 第 3 条，现在还留着）。
5. `/mui restrict` 末尾"轮询被暂停的框"清单 + `/mui skins diagnose` 的 ✗ 账：确认新判据没把本来能换肤的框
   误判成不可访问 —— **这条误判不报错，只能靠账本看**。

### 8.27.2 第四样本：EnhanceQoLUnitFrames（同客户端自绘组框）—— 队伍框隐藏方式

8.26 挖的是姓名板，这次是**队伍框**，来自游戏目录里装着的那套（只读，未改一行、未导代码）。
`GAMEDIR` = `C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_forever_\Interface\AddOns`，
`EQUF` = `GAMEDIR/EnhanceQoLUnitFrames`，`EQOL` = `GAMEDIR/EnhanceQoL`。
选它不选 ElvUI / NDui 的理由：`.toc` 写 `## Interface: 16001` + `## X-EQOL-Flavor: forever`，
**正跑在交付客户端上**，而且自绘 party / raid / mt / ma 四种组框，与我们的场景一对一。

它的隐藏五步（`EQUF/UF_GroupFrames_Camelot.lua:6259-6317`；`EQOL/General/functions.lua:1250-1298`
是同一份 helper 的第二份拷贝）：`UnregisterAllEvents` → 能 Hide 就 `Hide()`、不能就 `SetAlpha(0)`
→ `SetParent(常隐框)` → 给该框的 `Show` / `SetShown` 挂 `hooksecurefunc` 反拉锯
→ 团队框再补一刀 `CompactRaidFrameManager_SetSetting("IsShown", "0")`（:6314）。
目标名单：`PartyFrame` / `CompactPartyFrame` / `CompactPartyFrameTitle` / `CompactRaidFrameContainer`。

**可借鉴三条**：

| # | 它的做法 | 我们的现状与动作 |
|---|---|---|
| 1 | 写之前**逐框**问 `IsProtected()`（:6272-6274），只有"战斗中 **且** 这个框受保护"才退回 alpha | `Groups.lua:940 MuteOne` 是整个受限窗口一刀切 `return` —— **非受保护的子件在战斗里也白白跳过**，只能等脱战补扫（实机 ×984 那批的成因之一）。改成逐框判能少掉一批补做。**但**快照 `ScriptRegion:IsProtected() → isProtected, isProtectedExplicitly` 带 `[机密[SecretReturnsForAspect]]` → 必须 `Secrets.Bool(frame:IsProtected(), true)`（默认按"受保护"保守跳过）；直接 `if frame:IsProtected() then` 就是 AGENTS 那刀 `UNKNOWN()` |
| 2 | 用**暴雪设置面板自己那条开关**关掉团队框：`CompactRaidFrameManager_SetSetting("IsShown","0")` | 这是 8.26.4 表第 3 行"让暴雪自己顶"在 FrameXML 层的对应物：状态写进**暴雪自己的表**，它之后的显隐逻辑读到的是"玩家选了关" → **没有拉锯、没有逐框写、没有子树鼠标残留**。若成立，比我们整套 `Starve + AlphaTree + MuteTree` 都便宜。两条前提：①调暴雪全局函数 = 该函数体内以 MonetUI 名义执行，它内部 Show/Hide 管理器属受保护项 → **只能在非受限窗口调**；②本地快照 `docs/api/FUNCTIONS.md` grep `RaidFrame` / `PartyFrame` **零命中**（客户端没给任何 `C_*` 门），所以这个 global 在 1.60 存不存在、调完进不进拦截日志**只能实机探针**。→ 待做 `/mui groups probe`：`CompactRaidFrameManager_SetSetting` 是否存在 + 调用后 `CompactRaidFrameContainer` 的 `IsShown()/GetAlpha()` + 拦截计数 |
| 3 | `DisableBlizzardFrames` 第一行 `if not GF.CanUseSecureGroupHeaders() then return end`（:6297）：**确认自己顶替得了才去藏** | 我们 `SetBlizzardHidden(cfg, partyActive, raidActive)`（`Groups.lua:1045`）已是等价判据 → 不动代码，把这条当口径依据存档 |

**反例（第四家往暴雪对象写字段的；同时确认我们现有规矩的方向对）**：

- `Hide()` + `hooksecurefunc(frame,"Show")` 反拉锯，外加 `CompactPartyFrameTitle:HookScript("OnShow", → Hide)`
  （`EQUF/UnitFrameRuntime.lua:129-132`）。**它需要那些钩子，正是因为它选了 Hide** —— 我们「收暴雪 HUD 用
  `SetAlpha(0)` 不 `Hide()`」那条把这一整类消掉了，不是巧合。
- 往暴雪框写 `frame._eqolHidden` / `_eqolAlphaHidden` / `_eqolHiddenHooks` → 8.26.5 的字段反例添第四家
  （BNP、BTP、EQoL），`ns:Mark` 旁表这条继续不动摇。
- 全文**没有** `EnableBlizzardFrames`：**单向压制**，玩家关掉组框功能只能 `/reload` 才拿回暴雪的框。
  我们 `UnparkGroup`（`Groups.lua:1020`）有归还路径（`Starve` 那半截确实也要重载，代码里已明写在 print 上）。
- `PLAYER_REGEN_ENABLED` 派发当拍直接重跑被延后的动作（`EQUF/UF_GroupFrames_Camelot.lua:36544-36557`），
  **没有** `C_Timer.After(0)` → 正是 AGENTS 记的"要脱两次战才生效"：它 `hideFrameLocked` 里第一句就问
  `InCombatLockdown()`，那一拍标志还是旧值 `true`，于是动作又排回队列。**我们的 `ns:AfterCombat` 已避开，别照它改回去。**
- 钩子体内**裸用**机密返回：`hooksecurefunc("TextStatusBar_UpdateTextStringWithValues", …)` 里
  `fmt(..., UnitHealth(unit), UnitHealthMax(unit), unit)`（`EQUF/HealthText.lua:204-219`），一个 `issecretvalue` 都没有。
  那两个值一旦是机密，`string.format` 直接 `invalid value (secret)` —— 而且**抛在暴雪自己的更新链里**，归属记它名下。
  → 给 8.26.1 那条判据补一刀：**"体内不调 `[受限]` API"还不够，体内读到的每个值都要过守卫**。
- 它 `hooksecurefunc` 打在暴雪全局函数上的共 3 个（`PlayerFrame_UpdateStatus` / `PlayerFrame_UpdatePlayerRestLoop` /
  `TextStatusBar_UpdateTextStringWithValues`），`HookScript` 10 组打在暴雪框上，**长期活在本客户端** ——
  这是 8.26.4"钩暴雪全局更新函数"那一档**跑得起来**的第四份证据。但它钩子体内 `Hide()` 一个战斗门都没加，
  这类拦截只能靠"只进日志、不弹窗"忍着，**不是干净**，别拿"它没事"当依据（AGENTS 已定过这条口径）。

### 8.27.3 待做（接 8.26.7 / 8.27，按风险从低到高）

1. 8.26.7 第 1 条**已落地 `7108581`**；第 2 条（尺寸链事件化）与第 4 条（钩子半步要 `taint.log`）仍未动，计划不变。
   注意行号已随 8.27.1 位移：尺寸那条现在是 `Nameplates.lua:267-286`（`M:HookDriver` 里的 `Widget:PollWatch`）。
2. **新增（组框）**：`/mui groups probe` 验 `CompactRaidFrameManager_SetSetting("IsShown","0")`（8.27.2 第 2 条）。
   **若它成立，姓名板一侧值得回头问同族问题** —— 先 `node tools/api-lookup.js C_NamePlate` 把那个命名空间整个过一遍，
   找有没有暴雪自己的"显隐开关"能替掉我们的逐框压制（要找的是**开关**，不是尺寸/距离那几个 `[受限]` setter）。
3. **新增（组框）**：`Groups.lua:940 MuteOne` 的 `Restricted()` 一刀切改成逐框 `Secrets.Bool(frame:IsProtected(), true)`。
   验收只看一个数：`/mui restrict` 的拦截计数**下降**；持平或上升就是判据用错，回滚。

## 8.26 2026-11-03 close 材质重绘（参照 Andromeda `ui-close.blp`）

**参考件**：`_classic_titan_\Interface\AddOns\Andromeda\assets\textures\ui-close.blp`，
32×32，字形 bbox `4..27`（跨度 24/32 = **75%**），笔画水平 run = **8px** ⇒ 垂向厚 `8÷√2÷32` = **占比 0.177**
（旧记"≈5.7px = 17.8%"是同数四舍五入，以后一律用 0.177；
11-03 审查逐像素实测订正，**本行原文写的是"笔画 ≈4px（12.5%）"，记错了，见本节末订正块**），
圆头 + 四边全抗锯齿，质心正好落在画布中心（15.50, 15.50）。

**旧 MonetUI close**（64×64，glyphgen 导入）：bbox `16..48`（33px，奇数）、笔画 ≈5px（7.8%）、
质心偏 +0.5px。显示到 32px 时比参考件细一圈，而且跨度是奇数 —— 翻转/旋转时会差 1px。

**新实现**（`tools/regen-textures.js` 的 `drawCloseX`，三态共用几何）：

- `CLOSE_GLYPH_SPAN = 0.75`、`CLOSE_GLYPH_STROKE = 0.125`，端点半径扣掉一笔给圆头；
- 64×64 结果：bbox `7..56`（50px，78%）、笔画 8px（12.5%）、质心 `31.49, 31.47`（画布中心 31.5）✅；
- 用同一公式画 32×32 会得到 bbox `4..27`，与参考件逐像素重合 —— **订正（11-03）：这句只对前四项
  （bbox / 跨度 24÷32=75% / 质心 (15.50,15.50) / 四边对称）+ alphaMax 255 成立**；笔画不重合（见下订正块）。
- 颜色仍按视觉档取 `CLOSE.{normal,hover,push}`：standard = 白（染色）/ `#e8c078`（hover，刻意不染）/
  `#acacac`（push）。

**对照图**：`%TEMP%\opencode\close-compare.png`（三家都按 32px 实际显示尺寸渲染后 8× 放大）。
**验收**：`node tools/audit-pixels.js` 34 张全 PASS（白色衬底 0 违规、STENCIL 色相 0）。

> 备注：close 此前由仓库外的 `tools/../glyphgen` 导入，源已不在仓库里；现在回到脚本生成，
> 以后改 close 只改 `drawCloseX` 一处。`AGENTS.md` 里"现役 9 张 SVG"已降为 6 张。

**11-03 审查逐像素实测订正（会话 `4b077830`；本节的"参考件数字"被外部对比推翻）**：

- **参考件笔画（审查收工后的最终口径）**：同一口径"α≥128 手臂行连续段"实测 `ui-close.blp`（32×32）水平 run =
  **8px** ⇒ 垂向笔画厚 = `8 ÷ √2 ÷ 32` = **0.177**（对比页 `andromeda-close-compare.html` 记 0.177；本节早先
  先记的"≈5.7px = 17.8%"是同一个数的四舍五入，**以后一律用 0.177 / 0.125 这两个占比算比率**）。
  **不是本节原文写的"≈4px（12.5%）"**。
- **比率方向（口径写死，免得来回翻）**：`0.177 ÷ 0.125 = 1.416` ⇒ **参考件比我们粗 ≈41%**（集成道口径 41%，
  取整；严格按比值是 41.6%）；等价 `1 − 0.125 ÷ 0.177 = 0.706` ⇒ **我们比参考件细 ≈29%**。**撤回**：11-03 集成道转发过"细 35–40%"，
  那是口径不准的数，按本条订正。**11-03 收工 grep 实测（订正本节先前那句"0 命中"，它写早了）**：docs 三本里
  "细 35–40%" 的 **as-fact 形态 0 处**；`grep -rn "35[-–~]40" docs/*.md` 共 **5 处命中** = 本节这一条、
  8.29.1 A8、8.29.2-B1 结果段、CHECKS C2.1 close 条、PRELAUNCH 拍板第 9 条，**全部是本轮写的"作废/撤回"标注本身**
  （行号会随编辑漂，故按节位记）。
- **"旧 4px"是怎么进正文的（来源链，审查已收工、结论落定）**：① **更早的一处 = 生成脚本自己的注释**
  `tools/regen-textures.js` 的图标字形头注段（**11-04 起一律按锚定位：锚 `图标字形几何` / `这段头注是旧口径`；
  本道旧记的 `:222` 现在落在 `:219`–`:226` 这一段，`AGENTS.md` 那条同理落 `:404` 起 —— 该文件两轮插行、行号必漂**）就把 `ui-checkbox-tick` / `ui-close` / `ui-arrow-up`
  三个字形合并写成"笔画 ≈ 4px（画布的 12.5%）、字形撑到 ≈ 28/32（87%）"，`AGENTS.md`（旧 `:395`，**现 `:404` 起那条**）是它的转写（同句、同三个字形），
  close 那一格**从未单独测过**；close 专属块（锚 `参照 Andromeda \`ui-close.blp\``，旧记 `:324` / `:328`，**现 :330–:345 段**）又重复了一遍"参考件实测…笔画 ≈4px（12.5%）"，
  直到该块尾部（现 `:340` 一带）才有 11-03 的质疑注释；② 加上我们自己常数 `CLOSE_GLYPH_STROKE = 0.125` 在 32px 上正好 = 4px，
  两边数字"对得上"就再没人去量；③ 唯一"验收"是本仓自产的 `audit-pixels`，它管格式纪律（2 的幂 / 白衬底 / 色相），
  **从不比对参考件笔画** ⇒ 自校验闭环（8.29.2-B1 点名的正是这一型）。实物解码推翻后，`tools/regen-textures.js` 的
  close 注释块（本道原记 `:329-336`，**该文件今日在飞改、行号已漂 ⇒ 一律按锚定位**）已按实测写注释
  （常数 `0.125` **仍未动**，"拍板前别动常数"）。**旧口径今日残留的确切处数只写在 PRELAUNCH 第 9 条 ④ 末条**
  （11-03 傍晚二次 grep，含"worktree 已被别道改为订正形态"这条变化），本处不重复列数，免得两处各一套。
  **AGENTS.md 本道禁改、也从未改。**
- **我们侧（三个 run 数分清，别混用）**：同一"α≥128 手臂/中心行连续段"口径下，**按常数画的 32px 源图 run = 5**；
  **交付件（64px TGA 降到 32 显示）run = 6**（对比页 `runsMid`：参考 `12..19` = 8 格，我们 `13..18` = 6 格）；
  64px mip0 上 run = 12（= 占比 0.125 × √2 × 64 的抗锯齿取整）。中心行交叠段 **8 vs 6** 是**交付件 vs 参考件**的对比。
- **比率口径分叉（如实记，避免日后再出一个第三种数）**：① **常数/占比口径** `0.177 ÷ 0.125 = 1.416` ⇒ 粗 ≈41% /
  细 ≈29% ——**比率一律用这一对**（交办口径，也是 PRELAUNCH 第 9 条写死的）；② **交付件实测 run 口径** `8 ÷ 6`
  ⇒ 粗 33% / 细 25%。两数差来自抗锯齿 + α≥128 阈值取整，**run 数只作旁证**，不许与占比混算成第三个数。
- **"与参考件逐像素重合"只对 bbox / 跨度 75% / 质心 / 四边对称 / alphaMax 255 成立，不成立的是
  笔画已贴合 —— 旧毛病"比参考件细一圈"没修掉，只是对齐了 bbox。**（另记：跨度 75% 是 32px 样本上的数，
  64px mip0 上我们是 `7..56` = **78.1%**，对比页两栏都有，别把 78.1 当"跨度也重合"的证据。）
- 这正是 8.29.2-B1 点名的"自校验闭环不算外部验证"被抓现行：`audit-pixels` 管格式纪律，
  从不比对参考件笔画。已按同类项入 **8.29.1 A 表 A8**。
- **审查收工 · 六档几何表已落地（不再是"将追加"）**：`andromeda-close-compare.html` 第 3 节给了
  "垂直笔画厚 = 占比 × 显示物理直径"的 6 档 × 2 缩放 = **12 种显示直径**推算（钮径 18/20/22/24/28/32 UI px，
  @1x/@2x；我们 / 参考两列：18@1 = **2.25** vs 3.18、24@1 = **3.00** vs 4.24、32@2 = **8.00** vs 11.31，全部 12 档
  见对比页）。**临界**：我们笔画进亚像素的条件是显示物理直径 **< 8px**（= 1 ÷ 0.125），参考件同判据 **5.66px**；
  实际最小那档 18px@1 的显示物理直径是 **18px**（笔画 2.25px），**12 种全部高于临界** ⇒ 对比页判 **不存在亚像素线**，"发虚是插值把细线抹软了"
  这一候选**在几何层被排除**，粗细差是**恒定比例**（任何一档都是 0.125∶0.177），不是"某档破线"。
- **几何算不出、只能实机看的那一列（对比页原文口径）**：mip 选择、双线性软化、圆帽端点、DXT5 量化 ——
  外加本仓**先例项**"×2 缩放下 1px 描边的奇偶/软化"（同型判例见 8.26 的 `AbsRectUnits` 吸附那条 11-02 实机案）。
  ⇒ 上线日动作压到最小：**24px@1 并排看一眼**（判据与三档判定进 PRELAUNCH 拍板第 9 条）。
- **⑤ 11-04 集成道裁定：两个口径并存、都不作废，引用必须标口径**（本账据此收口，**"新冲突待拍板"这个标记撤销**）：
  ① **常数占比口径** `0.177 ÷ 0.125 = 1.416` ⇒ 粗 ≈41% / 细 ≈29% —— **拍板表第 9 条按它出选项**（要动的就是那两个常数）；
  ② **像素口径**（α≥128 连续段实测）run 8 vs run 6 ⇒ 粗 33% / 细 25% —— **观感叙述按它**。
  两者不打架有**实测**根据、不是推算：交付件实测 run 恒等于设计常数的 **1.5×**（32px 画 4px → run 6；64 mip0 画 8px → run 12，
  两侧同 1.5×，因为 α≥128 把抗锯齿的半透明边一起吃进来了）⇒ `0.125 × 1.5 = 0.133` 折回常数轴正好对上，
  所以像素口径的差值**天然小于**常数口径，不是谁算错。单源已写进 `AGENTS.md`「图标字形按画布比例」条与
  `tools/regen-textures.js` 头注段（锚 `这段头注是旧口径`；**该文件与 AGENTS 本轮归集成道，本道不再编辑，只对齐口径**），
  PRELAUNCH 第 9 条与本账 C2.1 已同步。**剩下的只是一条规矩**：以后引用比率必须写清哪一个口径，不许再产出第三个数。
- **并发改动入账 + 新冲突（11-03 傍晚本道复核发现；11-04 集成道裁定收口，见下条⑤）**：`AGENTS.md`（旧 `:395` → **现 `:404` 起**，
  该文件在飞改）与 `tools/regen-textures.js` 的头注段 / close 段（**一律按锚：`图标字形几何`、`参照 Andromeda \`ui-close.blp\``**；
  旧记 `:218-229` / `:330-345` / 常数行 `:347` 已再漂一次）已被**改写为"引旧口径＋订正"形态**；四个常数 11-04 复核**一字未动**
  = `CLOSE_GLYPH_SPAN = 0.75` / `CLOSE_GLYPH_STROKE = 0.125` / `period = 8` / `ramp`（现值 `:346` / `:347` / `:782` / `:783`；
  集成道自报的 `:335` / `:336` / `:771` / `:772` 与 `:742–:750` / `:763–:766` / `:328–:336` 均已漂 ~11 行 ⇒ **行号只当线索，锚才是键**。
  旧"笔画 ≈ 4px（12.5%）"现在都带"记错了 / 那是我们自己的设计常数"的限定 ⇒ **本道上一轮回报的"禁改区 3 处 as-fact"已作废，
  现值见 PRELAUNCH 第 9 条 ④ 末条实测计数**。**改写当时带出一个新冲突（"必须拍板前钉掉"），11-04 已由集成道裁定收口 ⇒ 见上面⑤，下文①②③④保留为过程账**：
  ① 他们写的 headline 比率是 **run 口径**（"参考件粗约 **33%**、我们细约 **25%**" = `8 ÷ 6`，交付件实测），
  而 docs（8.26 订正块 / CHECKS C2.1 / PRELAUNCH 第 9 条）写死的是 **常数占比口径**（`0.177 ÷ 0.125 = 1.416` ⇒ **41% / 29%**，
  交办口径）。两个数**都对，但对象不同**：41/29 = 设计常数之比（拍板"要不要把常数提到 0.177"用的就是它），
  33/25 = 出图后实测 run 之比（抗锯齿 + α≥128 阈值让它比常数差小一档）。⇒ **建议措词（改 AGENTS/regen 归集成道）**：
  把那两句 headline 后各加半句"**（run 口径旁证；常数占比口径 = 粗 41% / 细 29%，账见 `docs/HANDOFF.md` 8.26 订正块）**"，
  别让上线日出现"两个官方比率"。
  ② 同一个"占比"在他们文里被用了两次（水平 run/画布 = 参考件 25% / 交付件 18.8%，与垂向/画布 = 17.7% / 13.3%）
  ⇒ 本账一律写**垂向占比**（0.177 / 0.125），水平 run/画布一律叫"run 占比"，不叫"笔画占比"。
  ③ `17.8%`（regen `:347` 注释）与 `17.7%`（AGENTS `:406`）是同一个数 `8÷√2÷32 = 0.1768` 的两种舍入 ⇒ **本账统一写 0.177**。
  ④ **对 ④ 几何表的影响（已核，结论不变）**：若按交付件实测垂向占比 **0.133** 而非常数 0.125 重算，
  临界从"显示物理直径 <8px"变 **<7.5px**、18px@1 笔画从 2.25px 变 **2.4px** ⇒ **12 档仍全部高于临界**，
  "发虚被排除 / 差值恒定比例 / 三档可不管"三条判定**一条都不动**（两种口径都算过）。

## 8.28 2026-11-03 补档：11-03 的 15 个视觉 commit（判据从 commit message 入档）

**为什么补这一节**：`4de90ad → cd1f6d7` 这 15 个 commit 全部落在 8.27 之后，此前只有 commit
message 里有验收判据，HANDOFF 一字未提 —— 换道/换机就只剩 git log 可挖。本节按主题归五组，
每条记「做了什么 / 为什么 / 涉及窗口 / **实机判据**」；**实机打勾清单在 `docs/CHECKS.md` C2.1**，
两处同源，改判据要一起改。

**客户端口径（统一声明）**：本批的"实机测得"数字（✕ 全量 53/21/32、`RedButton-Exit*` 四态是
"深底plate+X"、四个 `Get*Texture` 方法拒绝点号调用、`UnitClass` 盗贼 classID=4 等）按项目口径
一律记 **12.1.5 实测 / 历史证据，1.60 待复验**；TemplateDB 的 387/32/5 是**离线抽取**计数
（Gethe `forever` 分支 FrameXML，1.60 同族），不关客户端。commit 自述"实机未验"的条目
（`b0a0ecd` 明写）不冒充历史证据，以实机跑过为准。

### 8.28.1 ✕ / close 材质线（`3f2ba5f` `5f84a93` `5bc814e` `1d488c6` `b0a0ecd` `45f5e73`）

- **`3f2ba5f`** close 三态参照 Andromeda `ui-close.blp` 重绘（跨度 75%、笔画 12.5%〔**12.5% 是我们的常数
  `CLOSE_GLYPH_STROKE`；参考件实测占比 0.177，两者不同，见 8.26 订正块**〕、圆头全抗锯齿，
  唯一源 `tools/regen-textures.js` 的 `drawCloseX`）。**完整过程与测量在本文件第二节标题撞号的
  "8.26 close 材质重绘"那节**（该节即记此 commit，判据：32px 实显笔画不再比参考件细、翻转/旋转不
  差 1px —— 旧版 33px 奇跨度会差；`audit-pixels` 34 张 PASS）。**订正（11-03 `4b077830` 实测）：
  前半句不过关 —— 我们 run 5 vs 参考件 run 8，"细一圈"没修掉（只对齐了 bbox）；后半句（1px）
  按 bbox 对齐成立、待实机确认。判据本身按 8.26 订正块 + 拍板清单第 8 条走。**
- **`5f84a93`** 换第四态（DisabledTexture → `monet_close_push`，刻意不染）：症状"一些关闭按钮多了
  个方块"。12.1.5 实测 `RedButton-Exit` / `-Disabled` / `-exit-pressed` 全是"深色圆底 plate 上坐 X"，
  四态漏任何一态就是 plate 挨着我们的裸字形。**判据：任何面板的 ✕ 在禁用瞬间不出现深色方块。**
- **`5bc814e`** 全量统一 ✕：按**字形签名**（`RedButton-Exit*` atlas）识别关闭按钮（`Skin:CloseButtonByArt`，
  并入 5 步全量扫描），不靠名字表 —— 12.x 有匿名框、有名字不带 CloseButton 的框，名单永远追不上。
  12.1.5 实测基线：**53 只 ✕、21 只已换、32 只暴雪原样**（账号商店 / 商城 / 频道 / PVE / 团队信息 /
  马厩 / 模型预览 / 教程 / StaticPopup1–4 / 秒表 等未换皮窗口）。幂等免费获得：换完后 atlas 消失，
  下一拍自动跳过；`SwapArt` 对已换纹理早退。**`RedButton-MiniCondense`（最小化减号）刻意不匹配** ——
  换掉它等于把"收起"变"关闭"。**判据：上面那 32 只全部变细金 ✕；减号钮保持原样。**
- **`1d488c6`** 背包总控窗 ✕ 改走 `Skin:CloseButton`（`monet_close_{normal,hover,push}`，描边色随主题、
  OnTheme 重染）。**判据：`MonetUIBagWindow_<分类>` 的 ✕ 与其它已美化窗口右上角同一种东西，换主题跟着变。**
- **`b0a0ecd`** 总控窗加 ✕ = `CloseAllBags`（作者拍板：只总控窗有）：黏性选总控（当前总控还显示就继续当，
  物品在分类间移动 ✕ 不跳；空了才顺延，「剩余空间」补位窗不当总控）；关整套前先把仍 `IsShown` 的暴雪
  背包 `Hide` 一次 —— 停车只压 alpha 从不 Hide，不收这一刀守卫边沿停在"开"，玩家要**按两下 B** 才重开。
  战斗中不碰暴雪框，只收我们的窗。**判据：点 ✕ 整套关闭；随后按一次 B 即重开；✕ 不跳窗。**
  **commit 自述实机未验**（观感 + 边沿），待集成道部署后复核。
- **`45f5e73`** InfoBar 属性面板保持暴雪红圆钮的根因：工厂只造框、皮肤留给调用点 —— 两处调用点记得补
  （SimpleConfig / Bags），InfoBar 没补。修类别不修实例：`Widget:CloseButton` 内嵌 `Skin:CloseButton`
  （幂等：`SwapArt` 早退 + 主题钩 `Mark` 守卫，显式调用点可留）。AGENTS 已记"控件工厂自带皮肤"。
  **判据：InfoBar 属性面板（标题"属性"）的 ✕ 是细金三态。**

### 8.28.2 箭头与滚动条线（`44f0253` `ff1bd7c` `28187aa`）

- **`44f0253`** 四张箭头贴图（`monet_chevron_{up,down}`、`monet_arrow_{left,right}`）本是同一个 V 画了
  四遍 → 唯一源 `monet_chevron_up` + `Widget:Arrow(tex, dir)` 代码转向：上下 = 4 参 `SetTexCoord` 双镜像
  180°（逐像素无重采样）；左右 = `Texture:SetRotation(±π/2)`（本客户端没有 8 参 SetTexCoord，两客户端
  都有 SetRotation）。删除的三张退出 Media / `audit-pixels` / 预览工具 / `import-glyphgen` 映射。**文件名
  不改名**的原因进了 AGENTS「客户端行为细则」：文件索引是客户端启动时建的，改名后 `GetFileIDFromPath`
  对新名返回 nil —— 当前会话里等于贴图丢失。`ARROW_ROT` 的符号约定当时照抄 Ellesmere（它的基准字形
  朝左），**方向在下一条才修正**。**判据：所有箭头来源只有一张朝上的图；改名试验已回滚，现名不变。**
- **`ff1bd7c`** 日志症状：`Skin.lua:1339: bad argument #1 to '?' (Usage: local texture =
  self:GetDisabledTexture())` 刷屏。12.1.5 实测 `Get{Normal,Pushed,Highlight,Disabled}Texture` **四个方法
  都拒绝点号调用**（`CharacterFrameCloseButton` 与新造的 `UIPanelCloseButton` 各验一遍），所以旧的三处
  点号写法本来就是错的 —— 两种结局都坏：要么抛，要么 `x.M and x.M()` 守卫把整个换图静默吞掉。新唯一
  漏斗 `Skin:TexOf(obj, getter)`（解析方法 + self 调 + pcall，取不到返回 nil），`Skin:CloseButton` /
  `Skin:ScrollBar` / `Skin:PageArrow` 统一走它。同条修左右箭头反向：Ellesmere 基准朝左、我们朝上，**两套
  符号是镜像**（朝左图 -π/2 得 up、+π/2 得 down；朝上图相反）。**判据：红字里不再有 `bad argument ...
  GetDisabledTexture`；页签/翻页箭头左右不反。**
- **`28187aa`** 12.x 两族新滚动条家族从未被换过：`MinimalScrollBar`（stepper 用
  `MinimalScrollBarStepperScriptsMixin`，atlas `minimal-scrollbar-arrow-{top,bottom}`）与 `WowTrimScrollBar`
  （stepper 是 `scrollbar.Back/Forward`，atlas `UI-ScrollBar-Scroll{Up,Down,Left,Right}Button-*`）。两族的
  箭头都画在**单一 region `button.Texture`** 上，mixin 每次按钮状态变化都 `SetAtlas` 重设 —— 换纹理无效。
  做法沿用 ScrollBox 那一套：原 region 压 alpha 0 + 我们自己的箭头盖上去（mixin 只 SetAtlas 从不碰 alpha，
  压一次就住）。方向**不从几何猜**（Back/Forward 只表示减/增，不说明轴向），读按钮自己的 art key
  （`upTexture`/`normalTexture` 的值拼出 Up/Down/Left/Right，对照 `Blizzard_SharedXML/Shared/Scroll/*.xml`
  全键集核过）。同趟两个顺手修：①旧 `Skin:ScrollBar` 箭头循环跳过没有 normal 纹理的按钮（原来 Strip 完
  `SwapArt(nil)` = 把箭头弄丢）；②覆盖件按按钮**短边**定尺寸并居中（stepper 18×16，V 拉伸 12% 肉眼可见）。
  `SCROLL_ARROW_ATLAS` 补 trim 与左右名（全量扫描兜底）；`Skin:Stepper` 与 `Skin:ScrollArrowButton` 共用
  `scrollArrow` 标记，一个按钮只画一次。**判据：任意滚动条四向箭头是细金 chevron、悬停/按下后不被
  atlas 顶回暴雪原样、不缺失。**

### 8.28.3 模板数据库与诊断命令线（`3b12ba7` `23d27d2` `78c98ab`）

- **`3b12ba7`** 补 `Modules/Skins/Templates/README.md`：给 `6925adf` 已落地的数据库子系统写使用文档
  （387 模板、32 条 skinAs 映射、指纹匹配顺序 = 增强查找优先再结构指纹、唯一 Camelot override
  `ColoredProgressBarTemplate` 在 1.60 是带 `.Fill/.Mask` 的 Frame 不是 StatusBar、再生流程
  `tools/extract-templates.js` + `test-template-db.js`）。**当时描述的 `/mui skins templates` 并不存在**
  （`Skins:HandleCommand` 只认 diagnose/layers），文档先记了目标接口。
- **`23d27d2`** 把命令接上：无参 = 总数 / 映射数 / Camelot override 数 + 类型与 skinAs 分布（排序稳定）；
  带片段 = 模板名或 skinAs 匹配（"这个控件会被认成什么型"聊天里直接问）；两条路径**都只读
  `ns.TemplateDB`，不碰任何框、不改任何识别**，数据库缺失时（加载序回归）只提示。`/mui` help 补一行。
  另一头：被 gitignore 的 framexml-source 检出目录正在被 `audit-locals` / `audit-taint` 扫（2931 文件 /
  50 BLOCKER 全是暴雪自己的代码），两个闸门像 `api-audit` 一样跳过它 —— 回到 59 lua、0 BLOCKER。
- **`78c98ab`** 统计修正（这条决定识别覆盖率天花板）：**387 条定义、只有 32 条进运行表**（其余在生成
  文件里注释保留），而 32 条里**只有 5 条带 `fingerprints`** —— `Skin:MatchFingerprints` 对无指纹条目
  直接返回 false，所以 `LookupTemplate` 现在最多命中 `ColoredProgressBar` / `BasicHybridScrollFrame` /
  `SelectableButton` / `TemplatedList` / `MoneyDisplayFrame` 这 5 个。命令输出改为「总数 / 带指纹 / 已映射 /
  Camelot override」四个数 + 存在不可匹配条目时告警；README 样例改成实测分布（Frame 13 / Button 8 /
  EditBox、ScrollFrame、Slider 各 3 / CheckButton 2；skinAs：scroll 4、editbox、money 3…）。
  **扩大覆盖的正路是给 `tools/extract-templates.js` 补指纹规则，不是加 skinAs 映射。**
  （2026-11-03 本车道 `grep -c '^T\[' TemplateDB.lua` = 32、`fingerprints` 块 = 5，与 commit 口径一致。）

### 8.28.4 颜色纪律与信息栏归类（`c58fae9` `cd1f6d7`）

- **`c58fae9`** 提示框法术层级反了（正文比标题亮）。两个独立原因：①`RecolorSpellTitle` 原来取
  `Color:GetNeutral()` —— 和正文归一同一个灰，标题永远压不过正文；改取 `Color:GetHighlight()`
  （0.95/0.93/0.84）并**显式传 alpha 1**（GetHighlight 自带的 a=0.50 是冲刷强度，三参 `SetTextColor`
  会把它强顶成 1）。②正文灰度归一漏了普通说明文：「静态黄」判定带（`|r-g| < 0.08` 且 `r,g≥0.75`、
  `b≤0.45`）只命中 `YELLOW_FONT_COLOR`，而 12.1.5 实测 `NORMAL_FONT_COLOR` = (1, 0.82, 0)（r-g=0.18 出带）、
  `LIGHTYELLOW_FONT_COLOR` = (1, 1, 0.6)（b 超帽）—— "使用:"类说明行正是这两个颜色画的。**判定带刻意
  不放宽**：更松的"暖黄"测试会连神器金 (1, 0.9, 0.41) 这类有信息量的颜色一起压平。**判据：悬停法术图标
  = 标题奶油亮、正文（含"使用:"行）灰；金色/神器色行不被误灰。**
- **`cd1f6d7`** 信息栏统计块把盗贼归成 tank。根因是 `SPEC_CATEGORY` 手抄表的 classID 是**假设不是实测**：
  注释写"1.60 只有经典九职业"、把潜行者记成 3；12.1.5 实测 `UnitClass("player")` → 潜行者/ROGUE/**classID 4**，
  于是查到德鲁伊行、spec 2 = "tank"（ outlaw 恰是 spec 2）。classID 跨客户端不共享、专精顺序也不共享，
  任何手抄表都会再错过一次 → **表删掉**，归类改由客户端自己报：`GetSpecializationInfo` 第 5 返回是 `role`
  （TANK→防御行），其余按主属性分 caster/physical（int 为 str/agi/int 最高 → 施法者，治疗落这里，符合
  作者要的"防御 / 施法 / 其余"三分）；role 读不到主属性照样判，**最坏 "physical"，不会再出 "盗贼=tank"**。
  查询只走 `C_SpecializationInfo`（1.60 与 12.1.5 都有该命名空间；全局 `GetSpecialization(Info)` 在 1.60
  不存在，`api-audit` 的 [moved] 说的）。时机按作者要求：进世界算一次 + 点开面板时再算一次，**不跟 2 秒
  刷新重算**（受限窗口里 role 与属性都是机密值，重算只会把对的换成错的）。实测：role=DAMAGER、
  agi 140 > int 54 → physical。**判据：盗贼属性面板归类为 physical；`/mui blocks` 无新增机密布尔拦截。**

### 8.28.5 LFG 面板登记与角色 atlas 换图（`4de90ad`）

按 LFG 研究清单落地，**只做登记和换图，点击 / 右键 / 事件全部留空**：

- 实名清单 `LFG_TOP_TABS` / `LFG_DROPDOWNS` / `LFG_QUEUE` 新增，`LFG_BUTTONS` 补刷新 / 选项 / 父框关闭
  三颗；都走 `M:Dress(as=tab|dropdown|button|fade)`，`Skin:Need` 记账，`/mui skins diagnose` 可复核。
- 角色 atlas 换图：`groupfinder-icon-role-large-{tank,heal,dps}` 与 `micro-*` 换成 `monet_role_*` 灰阶文件图。
  `LFGBROWSE_GROUPDATA_ATLASES` 是 Browse.lua 的 local（外面拿不到），ScrollBox 复用行会重新贴 atlas，
  不是一次换完永久生效 → 做法 = `Widget:PollWatch(LFGParentFrame, 2)` 每秒扫子树，`GetAtlas` 命中就
  `SetTexture` + `SetTexCoord` 归位；`SetTexture` 之后 `GetAtlas` 返回 nil，下一拍自动跳过。全程 pcall、
  不 `hooksecurefunc`、不 `HookScript`、不往暴雪贴图写字段（AGENTS：写过 = 这个框之后全归 MonetUI）。
- `QueueStatusButton`（排队眼睛的宿主，属 `Blizzard_QueueStatusFrame`）**登记口径已订正**：原 `4de90ad`
  写"只登记 `as=fade`"——独立审查发现 `DRESSERS.fade` 实际调 `Skin:Fade` **把框压成 α0**，排队眼睛直接
  消失，与注释意图正好相反。现实现 = **只过 `Skin:Need` 进账本、不换肤**
  （`Modules/Skins/Forever.lua:138-146`，实现会话已交，五道闸门全绿：api-audit no hard / audit-locals
  55 文件全过 / audit-taint 0/0/0 / test-skin-lua + test-mult 全绿 / check-frame-list 385 一致）。
  该处注释原写"2026-11-05 独立审查必改项"系**日期笔误**，集成道 11-03 当天已直接改成 11-03（记一笔：
  这是集成道改的，不是并发改动；入档一律按 11-03）。

**判据：副本查找面板的角色图标（列表滚动复用行之后再看一次）是我们的灰阶三枚；该面板各帧在
`/mui skins diagnose` 里 ✗/✓ 有账。** 注意框名两客户端都从未实机验过（§9 第 8 条原话）—— 若整排 ✗，
**1.60 先查 GameRule 有没有禁用副本查找，再动名单**（AGENTS 换客户端口径）。

### 8.28.6 文档配套：DESIGN-LANGUAGE 防丢与 git 归属

- **权威副本与拷贝现状**：`docs/DESIGN-LANGUAGE.md`（180 行，2026-11-02 定稿：透明度阶梯 / 颜色槽纪律 /
  字号四档 / 点缀四语法）**未被 git 跟踪**（`.gitignore:45` 的 `docs/*` 排除，`git check-ignore` 可复核）；
  **权威副本在集成道** `C:/Users/EastHillGu/Documents/wowaddonsdev/MonetUI/docs/DESIGN-LANGUAGE.md`，
  各车道靠**手工拷贝**带文件。本车道 2026-11-03 与权威副本 `diff` 一致（180 行零差异）。换机/换平台
  把它连同 `docs/` 整目录一起拷，否则随车道丢。
- **待作者拍板（本车道不拍板）**：DESIGN-LANGUAGE.md 要不要进 git。现状纠正一句：本仓并非"docs 全不入
  git"—— `git ls-files docs/` 显示 HANDOFF / CHECKS / CODEX-SETUP / MULTI-HARNESS / 两份 PLAN / REVIEW 共
  7 份已经靠 .gitignore 例外名单在跟踪，**漏网的只有 DESIGN-LANGUAGE（与 AURORA-COVERAGE、
  TEMPLATE-DB-IMPLEMENTATION）**。**利**：判据进版本控制、随 commit 走车道，不再手工拷、不再怕丢；
  **弊**：docs 不入库的本意是文档 churn 不污染插件源码史（AGENTS"git 只跟踪插件源码"），例外名单再加
  名字等于把这条线往回挪。**最小方案 = 例外名单补一行**；不通过则维持手工拷贝并接受丢失风险。
  **（2026-11-03 已收敛：三份文档的白名单补丁与取舍见 8.28.8，本段留作过程记录。）**
  另 AGENTS.md 第 16 行"本仓 docs/、tools/、*.md 被 .gitignore 排除"与上述 git 事实不符（7 份已跟踪），
  口径修订归作者 / 集成道，不由各车道自行改；`.gitignore:36` 注释写"四份交接文档"、实际例外是 **7 行**，
  同一族措辞落后于事实。
- **交接口径（给项目经理）**：新建的 `docs/PRELAUNCH-RUN-1105.md` 同样落在 `docs/*` 排除里（例外名单没有
  它），`git add docs/` 收不到 —— 入档要么补例外行（与上面拍板项 5 一并处理），要么 `git add -f`，要么
  并入 HANDOFF / CHECKS 已跟踪文件。本车道按纪律未动 `.gitignore`、未做任何 git 写。
- **编号撞车提醒**：本节所在文件里有**两个"8.26"**——交叉佐证钩子线（带 8.26.1–8.26.7 小节）与
  close 材质重绘（无小节，AGENTS.md 第 408 行"见 HANDOFF 8.26"指的是**后者**，其余 `8.26.x` 引用都指
  前者）。未重编号（动了会互指错），请项目经理合并本档时一并处理：建议 close 材质节改挂 8.28.1 的
  材料或改号，AGENTS 408 行的指向随之核对。

### 8.28.7 环境事实：开发根的 Andromeda 参考件已缺席（2026-11-03 逐路径核实）

**核实结果（修正交办时的说法）**：

- `C:/Users/EastHillGu/Documents/wowaddonsdev/Andromeda`（即各处写的 `../Andromeda`）**确实不在了**：
  AGENTS.md 第 109 行"参考插件 Andromeda / EllesmereUI 只读（opencode.json 已 deny edit）"、
  `docs/MULTI-HARNESS.md:63`、主仓 `opencode.json:5` 与 `:57` 的权限项，现在都指向不存在的路径。
  开发根现存：`EllesmereUI-v9.4` / `BetterNamePlates` / `BlizzThreatPlates-Forever` / `Elvui` / `NDui` /
  `FreeUI` / `Platynator` / `AishCore` / `monetcolors` / `wow-forever-api`。
- **但 Andromeda 本体还活着**，残存于旧客户端目录
  `…\WOWFOREVER\World of Warcraft\_classic_titan_\Interface\AddOns\Andromeda`（`.toc` = `Interface: 38001`），
  `assets/textures/ui-close.blp` 与 `statusbar-stripes-thin.tga` 均在位。`3f2ba5f` 当年的测量就是从这条
  游戏路径取的 —— 所以这两批判据**今日仍可离线复核**，丢的不是"复测源"，只是"开发根那份拷贝"。

**受影响的批判据（数字本身都已入档，不怕丢）**：

1. **close 三态比例**（`3f2ba5f`，照 `ui-close.blp`）：bbox `4..27` / 跨度 75% / 笔画 12.5% / 圆头全抗锯齿 /
   质心居中 —— 已记在本文件"8.26 close 材质重绘"节与 AGENTS「图标字形按画布比例」。
   **11-03 实测回话（`4b077830`）：12.5% 是**我们**的笔画比；参考件水平 run = 8px（垂向占比 **0.177**，旧记 17.8% 同数），
   "笔画贴合/逐像素重合"对笔画不成立 —— 详见 8.26 订正块与 8.29.1 A8。**
2. **45° 斜纹剖面**（2026-10-28，照 `statusbar-stripes-thin`）：亮纹 2 纹素 → 垂直厚度 2/√2、α 加权占空
   27.3%（旧版 50.3% 读成雾）、参考件周期 ≈6 在 64 图上实测断 43 像素 —— 已记在 AGENTS「45° 斜纹必须带
   半像素过渡」。
   **11-03 实测订正（`4b077830`，口径混用）：27.3% / 周期 6.3 那组数 = 2026-10-31 对零售版截图的测量，
   不是本机实物 —— 本机 `statusbar-stripes-thin.tga`（64×32，type 10 RLE，现有解码链不收、审查在只读
   工具里补了解码）实测周期 4、剖面 [255,129,0,129]、占空 50.3%（与 `tools/regen-textures.js` 斜纹注释里那句"我们（周期 4）50.3%"逐位相同 —— **11-04 按锚定位：锚 `差别全在密度`；旧记 `:744` / 集成道自报 `:763` 均已漂**）
   "我们（周期 4）50.3%"逐位相同）；`thick.tga`（256×32）占空 42.3%、无硬剖面。现设计 S1（周期 8 /
   37.5%）方向上背离本机实物 —— 是否回到周期 4 = **待作者拍板**（PRELAUNCH 拍板清单第 8 条），入档见 8.29.1 A9。**

**风险定级**：`_classic_titan_` 属旧客户端残留，按项目"12.1.5 不保留"口径随时可能在某次磁盘清理被删；
一旦删掉，这两条材质判据就成**单一来源且离线不可复核**（现役生成参数 `CLOSE_GLYPH_SPAN/STROKE` 虽在
`tools/regen-textures.js` 里，但"为什么是这两个数"的证据没了）。标记：**复测源在位但悬（挂旧客户端），
上线日实机看材质兜底**；原"取回 vs 自定案"的待拍板写法已被下方集成道最终订正收敛为
**必做 = 改路径指向、可选 = 取回/自定案**（PRELAUNCH 待拍板第 7 条随之改）。

**11-03 集成道最终订正（性质 = 路径指错，不是"参考件已丢 / 不可复核"）**：独立审查会话"ANDROMEDA 不在
本机、离线不可复核"的那一条被正式推翻 —— `../Andromeda` 只是**相对开发根不存在**，实物一直在这台机器上：
`C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda`
（`.toc` 逐行实测：`## Interface: 38001` / `## Author: fafaraway (adapted for 3.80.1)` / `## Version: 11.01`；
资产注册锚点 `core/media.lua:9` = `statusbar-stripes-thin`、`:26` = `ui-close`，与 `3f2ba5f` close 重绘和
2026-10-28 斜纹两条批判据的测量来源对得上）。于是：

- 材质比例类判据（close 跨度 75% / 笔画 12.5% / 质心 31.5；斜纹剖面）**现在可离线复核**，不再归"不可复核"；
  参考件对交付贴图的**像素对比由审查会话 `4b077830` 做完并收工**（**11-03 已落地**：8.29.2-B1 的"自校验"结论
  据此升级为**外部验证**，几何表见 8.26 订正块末条与 PRELAUNCH 拍板第 9 条 ④）。
  **收工回话推翻的恰恰是手边记的两个"参考件数字"**（close 笔画、斜纹 27.3%），
  见 8.26 订正块、8.28.7 两条订正与 8.29.1 A8/A9；其余项（bbox / 跨度 / 质心 / 四边对称 / alphaMax）对比成立。
- 残余风险只剩**单一来源**：实物挂在旧客户端目录，`_classic_titan_` 一次清理即断证据链。
- 处置收敛为两档：**必做** = 把 `AGENTS.md:109`、`docs/MULTI-HARNESS.md:63`、主仓 `opencode.json:5`/`:57`
  三处（四个行位）`../Andromeda` 指向改成上面的绝对路径（`:109` 最终措词见 8.28.8-B 第 2 条）；
  **可选** = 取回开发根拷贝、或把两条比例写进 `docs/DESIGN-LANGUAGE.md` 自定案后删除外部指向。

**建议改法（AGENTS.md 按纪律由集成道维护，本车道一字未动）**：
`AGENTS.md:109` 补一句"`../Andromeda` 开发根缺席，现存唯一拷贝 = `_classic_titan_…AddOns/Andromeda`（只读）"
或删指；`:381` 与 `:394` 两处"照 Andromeda X 重画"各补现存绝对路径；`opencode.json:5` / `:57` 删除或改指
现存路径；`docs/MULTI-HARNESS.md:63` 同步（该文件不在本车道交付清单，未动）。

**docs 拷贝核对（本轮）**：`docs/DESIGN-LANGUAGE.md`（180 行）、`docs/AURORA-COVERAGE.md`（261 行）、
`docs/TEMPLATE-DB-IMPLEMENTATION.md`（195 行）与本车道从主仓拷入版本 `diff -q` 实测**零差异**（2026-11-03）。
后两份同样不在 .gitignore 例外名单 —— 与 DESIGN-LANGUAGE 共命运，拍板见 8.28.6。

### 8.28.8 文档入库白名单最小补丁 + AGENTS.md 待订正（11-03 按集成道实测事实收敛）

**事实基座（集成道 11-03 实测，与本车道前两轮 `git ls-files docs/` / `git check-ignore -v` 结果一致）**：
`docs/*` 是"整目录排除 + 逐文件 `!` 白名单"而非 docs 全不进库；已入库 7 份（CHECKS / CODEX-SETUP /
HANDOFF / MULTI-HARNESS / PLAN-refactor×2 / REVIEW-2026-10-29）；`.gitignore:44` 注释写明结构原因
（"不能写成整目录 `docs/`——那会让下面的 `!` 全部失效"）；`tools/*` 同构（闸门脚本 `!tools/**/*.js`
自 2026-10-30 入库）；`*.md` 全局排除另有 4 个例外（README、两份 NOTICE、.qoder/rules）。
被 `docs/*` 吃掉的三份判据文档（DESIGN-LANGUAGE / AURORA-COVERAGE / TEMPLATE-DB-IMPLEMENTATION）
连 `--untracked-files=all` 都不显示 —— 只能靠例外名单或 `git add -f` 入档。

**A. 白名单最小补丁提案（不动 `.gitignore`，交集成道落）**：在 `.gitignore` 的 docs 例外段（`:46-52` 之后）追加

    !docs/DESIGN-LANGUAGE.md
    !docs/AURORA-COVERAGE.md
    !docs/TEMPLATE-DB-IMPLEMENTATION.md

理由：三份都是**上线后维护要用的判据/素材来源**，不是过程产物 —— C2/C2.1 视觉验收以
DESIGN-LANGUAGE 为依据；8.28.3 模板账本（387/32/5 与扩指纹路线）以 TEMPLATE-DB-IMPLEMENTATION 为底稿；
Aurora 移植覆盖面（26 个 SharedXML 目标）以 AURORA-COVERAGE 为对照。api 快照、texture-preview 产物、
评审表维持排除不动。**若作者收窄，最小闭环 = 只放 DESIGN-LANGUAGE**（CHECKS 直接引用的那份）。
附带效果：本文件（HANDOFF 8.28.6 末段）与 PRELAUNCH 提到的"`docs/PRELAUNCH-RUN-1105.md` 也被 `docs/*`
吃掉"同属这一族，是否入档随本条一并拍板（它是单周执行单，过程属性更强，本车道倾向不入）。

**B. AGENTS.md 待订正记录（本车道未动一字，行号按当前 11-03 版文）**：

1. **`AGENTS.md:16`**：现文"本仓 `docs/`、`tools/`、`*.md` 被 `.gitignore` 排除（git 只跟踪插件源码），
   换机/换平台要整目录拷贝"**与 git 事实不符**（7 份 docs、`tools/**/*.js` 闸门脚本、README/NOTICE 均已
   跟踪）。建议改为："`docs/*` 与 `tools/*` 采用整目录排除 + 逐文件 `!` 白名单，已入库清单见
   `.gitignore:36-52`；未入白名单的 docs 内容（api 快照、texture-preview、判据文档等）换机仍需整目录拷贝。"
2. **`AGENTS.md:109`**：现文把 `../Andromeda` 当在位参考件 —— 开发根该目录已缺席（同失效的还有
   `docs/MULTI-HARNESS.md:63` 与 `opencode.json:5`/`:57` 的指向；`EllesmereUI-v9.4` 仍在、跨目录可读正常）。
   **11-03 集成道定性质：参考件路径不存在（路径指错），不是丢件** —— 实物一直在
   `_classic_titan_…AddOns/Andromeda`（toc 38001 / v11.01 / fafaraway classic-titan 适配套），
   `core/media.lua:9`=斜纹、`:26`=close 就是两条批判据的原始测量来源；材质比例类判据**据此拷贝可离线复核**，
   像素对比已由审查会话 `4b077830` 收工落地（close 笔画与斜纹剖面两处旧记录被实物推翻，见 8.26 / 8.28.7 订正）。**最终措词**（交集成道改 `:109`，一行方案）：
   "参考插件 EllesmereUI-v9.4（开发根）与 Andromeda 均只读；`../Andromeda` 路径不存在，实物 =
   `C:/Users/EastHillGu/Documents/Blizzards/WOWFOREVER/World of Warcraft/_classic_titan_/Interface/AddOns/Andromeda`
   （Interface 38001 / v11.01 / classic-titan 适配套，只读），材质比例类判据（close 跨度/笔画/质心、45° 斜纹剖面）
   可据此拷贝离线复核"。同步改指（必做）：`docs/MULTI-HARNESS.md:63`、主仓 `opencode.json:5` 与 `:57` 的
   `../Andromeda` 全部换成同一绝对路径。**已撤回的审查表述**：①"Andromeda 不在本机 / 离线不可复核"；
   ②close 比例归因 `cd1f6d7`/`5bc814e`（来源 commit 实为 `3f2ba5f` 重绘；`cd1f6d7`/`5bc814e` 是换图与
   全量统一一族、其判据不引用 Andromeda）。**可选**：取回开发根拷贝，或把两条比例写进
   `docs/DESIGN-LANGUAGE.md` 自定案后删除外部指向（PRELAUNCH 待拍板第 7 条已按此降级）。

## 8.29 2026-11-03 上线前证据台账：哪些结论没有 1.60 实机支撑

**背景**：独立审查（会话 4b077830）+ 集成道交办合并的产物。前提事实：本批 15 个 commit（`4de90ad`→`cd1f6d7`）
**零次在 1.60 上跑过**（交付客户端 11-05 才开服），而代码注释与文档里大量"实测/实机"字样没带客户端标签 ——
按 AGENTS 口径（12.1.5 = 历史证据、新结论只标 1.60）逐条降级入账。**A 表的代码注释修改全部由集成道执行**
（多位同事正在并发改 `Utils/Skin.lua` / `Utils/Widget.lua` / `Modules/InfoBar/Blocks.lua` /
`Modules/Tooltip/Tooltip.lua`，本车道一字不碰源码，只出这本账）。

**先钉死一个真相，防止一刀切改成"离线推断"**：`c58fae9` 的 commit 自述明写 *"Verification is visual --
the game is up on retail"* —— 11-03 当晚 **12.1.5 是开着的**，`ff1bd7c` / `5bc814e` / `44f0253` 的测量都发生在
在线 12.1.5 上。所以 A 表的应改口径统一是 **"12.1.5 实测 / 历史证据，待 1.60 复验"**，不是"离线推断"；
反过来，把 1.60 上从没跑过的事写成"两边都验过"才是本表要抓的那类错（A5）。commit 自述"实机未验"的条目
（`b0a0ecd` 观感/边沿）入"未验"账（C2.1 已列首跑重点），不冒充历史证据。
**结论一句（11-03 集成道定稿）**：这 15 个视觉 commit 不是"完全未验"，而是**"在已停用的客户端上验过"** ——
风险类型从"没见过效果"变成**"跨客户端行为差异"**：1.60 上第一趟要防的是"同一行代码在另一个构建里表现不同"
（字形尺寸感、atlas 缺席、GameRule 关框），而不是"效果未知不敢开"。这决定上线日验收的组织方式：
按"12.1.5 已验判据 → 1.60 复验"成对打勾（A 表新列就是这本账），不是从零盲验。

**零实机证据与工具/数据源陷阱判例（11-03，集成道三个只读工具实测入账；同日定案：每条带可复核锚）**：
本车道 8.29 此前**没有**这张证据表（`grep 铁证|零实机` 全档 0 命中）——"第四条"沿用集成道车道的编号，
**他账本的前三条原文不在本档**，要合成完整四条请集成道发来。本道落地的是（锚注规则：仓内文件给
`文件:行`；外部工具实演记录无仓内锚，标注出处；跨档行号以"原话锚"抗位移）：

- **④（新入账，两条互证）**：`wuxian.errors` 返回 `available:false`（原话 *"no SavedVariables of
  !WuxianWorkshop yet —— the client writes them at logout or /reload"*）+ `doctor` 的唯一 unknown =
  `WTF\Account` 无 AddOns.txt（角色登录后才写）—— 两者都只能由"**该客户端从未登录过角色**"产生。
  锚：工具输出无仓内文件，出处 = 集成道 11-03 实演记录；同族落盘机制仓内锚 `Core.lua:1090`
  （"探针全量落盘比 /reload 晚 1–2 分钟"）。
- **上线日防误读警告**：第一趟**必须跑过 `/reload` 或正常退出游戏**，否则 `errors`/`logs` 拿不到东西 ——
  **"工具没数据"不等于"没报错"**。
- **陷阱判例①（工具字段会骗人）**：`status.addons_dir` 在游戏未运行时写 `_retail_` 是**陈旧回退字段**
  （同屏实测 `game.found:false` / `link.state:offline`）；权威是 `doctor`（`game_dir` = `_forever_`、
  1.60.1.70753 cn/wowf、Interface 16001 按版本号推算；Workshop 4 文件 + WoWBridge 27 文件均装在
  `_forever_`、版本一致、字体信箱 4096 槽 + proc.ttf 在位、无旧残留）与 `addons`（列目录即
  `_forever_\Interface\AddOns`，MonetUI 0.12.0 current:true、history 30 版）⇒ **验路径跑 `doctor`，
  别拿 `status.addons_dir` 当真**；计划"阶段 1 前置"已满足。锚：`docs/PRELAUNCH-RUN-1105.md`
  D-1 第 5 项（原话锚"必做·开机跑一次 wuxian.doctor"）与"已解除（11-03，曾列阻塞）"段。
- **陷阱判例②（数据源分不清新旧）**：`_retail_\Interface\AddOns\MonetUI` 存在且与 `_forever_` 副本
  **版本号同为 0.12.0** ⇒ 版本号判不了新旧；**11-03 定案：mtime 也不记**（robocopy 保留源 mtime，
  对"产物是哪批代码"没有判据价值）—— 硬方法 = `git hash-object <已部署文件>` 对 `HEAD:<同路径>` 比内容。
  本道 11-03 复核命中：LICENSE / MonetUI.toc / Core.lua / `Modules/Skins/Skins.lua` / `Utils/Scheduler.lua`
  **五采样点全部 SAME-as-HEAD ⇒ `_forever_` 现存副本 = `cd1f6d7` 的部署态**（已部署 LICENSE 1067 字节 =
  仓库 blob；worktree 1088 = 多 21 个 CR 的文本归一化、非内容差）。另 `status.content.packs.api =
  2026.10.27.1`（bundled；在线更新超时失败）可作 **API 快照心日期**。锚：`docs/PRELAUNCH-RUN-1105.md`
  §2"部署态基线"块（原话锚"上线日部署产物 = cd1f6d7 + 今日各线改动"）。
- **陷阱判例③（比对逻辑自身的坑，集成道 11-03 修复）**：`tools/sync-check.js` 的 `isText()` 只认扩展名，
  **无扩展名的 `LICENSE` 落到"逐字节比"分支** —— git 的 CRLF↔LF 归一化让 worktree 副本与部署副本
  **字节不同、内容相同** ⇒ **永久假 STALE**（1088 vs 1067 = 21 CR；实跑输出里 LICENSE 在列，修后 11→10）。
  同族坑仓里**注释过一次**（逐字节比把刚部署完的文件报 STALE、实机误报过 `UnitFrames.xml`），当时只补了
  扩展名清单、没盖到无扩展名文件。修复在 `tools/sync-check.js:58-66`（含案文注释；`node --check` 过，
  本道复核）。与判例①同族：**都是"看起来一致、其实口径不同"**。
- **陷阱判例④（11-03 下午，两条离线闸门各自够不到的东西）**：① `node tools/quality-color-probe.js` 全绿
  （本轮实跑：源码级 4 项 + Lua 探针 48 断言，0 失败）**不等于客户端给的品质色和旧手调六档一致** —— 该闸门
  断言的是"形状/接线/单一真值源"，`tools/` 在它的 SKIP_DIRS 里、也从不真调用 `C_Item`，拿不到返回值；
  **（本句"从不真调用 `C_Item`"措词不准 —— 探针自供假 API 并真走那条分支，准确口径见判例⑤②，11-03 傍晚订正）**
  数值对不对只有实机眼看（判据 = CHECKS C2 品质色条）。② `tools/test-aura-fit-external.js` [5] 报
  `monetTargetBuffs` / `monetTargetDebuffs` / `变量:owner` 三条 FAIL，**是镜像扫描范围的限制不是代码缺口** ——
  它的销账点扫描只过 `BuffFrame.lua` + `UnitFrames.lua`（test `:210-211`），没扫 `Auras.lua` 内部，而目标框
  两组的 false 就在 `Modules/UnitFrames/Auras.lua:835`（owner 省略 = 那两组）。⇒ **闸门红/绿都要先读它在断言什么**。
- **陷阱判例⑤（11-03 傍晚，harness 与探针各测什么 —— 集成道交办 + 本道按行号复核，含对本道上一条的订正）**：
  ① **`tools/harness/api_stub.lua` 的 `C_Item.GetItemQualityColor` 形状是错的**（锚 = `GetItemQualityColor = function(q) return { r = 0.55`；
  本轮两次读取间该块从 `:2180` 漂到 `:2185` ⇒ **`tools/harness/` 正被 harness 道在飞改（`?? tools/harness/`），行号一律不可靠，按锚定位**）：
  stub **返回一张表**，真实签名是 `→ colorRGBR, colorRGBG, colorRGBB, qualityString`（**三个 number + 一个字符串**，主仓 `docs/api/FUNCTIONS.md:2700`）。
  发行码那侧解的是 `Utils/Skin.lua` 的 `local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)`（现 `:1569`，该文件在 M 列会漂）
  + 其后三个 `type(...) == "number"` 判定（现 `:1577`）
  ⇒ 拿到表时 `r` 是表、`g`/`b` 是 nil，判定不通过，**必然落到 `QUALITY_FALLBACK`**。⇒ **凡经 `tools/harness/run.lua`
  （锚 = `dofile(join(root, "tools/harness/api_stub.lua"))`）加载模块的离线冒烟跑，品质色永远只见旧兜底六档**；
  从这条路径得到的"颜色看起来对"**不构成"客户端色已比对"的任何证据。** 修 stub 形状归 harness 道（本道一字不碰 `tools/`）。
  ② **但"断言全绿是假象"这句要分对象**：`tools/harness/quality-color-probe.lua` **不加载 api_stub**（探针头注 `:24`
  写明"为什么不 use api_stub.lua：那是 harness 道正在改的文件"），它自己塞假 `C_Item` 并把发行码那段编进
  chunk 跑（`:92`，成功支用 `return 0.2, 0.4, 0.6` 这类**三个数**的假值，`:187`/`:192`；`:155` 还专门把"返回一张表"
  当成兜底用例断言）⇒ 成功支在探针里**是被走到的**，探针的绿证明"接线 + 形状 + 兜底路径"，**不证明客户端数值**
  （假数本来就是编的）。**订正判例④ ①里本道写的"从不真调用 `C_Item`"**：准确说法是"调用的是自供假 API，拿不到客户端返回值"。
  ③ **harness 能测 / 不能测的边界（上线日口径，写死）**：能测 = 模块能否加载、接线是否只走一个出口、答不上来时是否落兜底；
  不能测 = 客户端返回的实际 RGB、memo 引用稳定性在真机是否被别的写入破坏、以及"客户端色 == 旧手调六档"这一条本轮改动的全部收益所在。
  ④ **交叉引用边界（新记）**：本 worktree **没有 `docs/api/`**（`ls docs/api` 报 No such file；该目录被 `.gitignore:45 docs/*`
  排除、不在 6 个白名单例外里）⇒ 凡引用 `docs/api/FUNCTIONS.md:行号` 的行（含 A10、判例⑤）**只在主仓侧可核**，
  换机/换 worktree 需整目录拷贝才能复现。

### 8.29.1 A 表：宣称"11-03 实测/实机"的扫描清单（.lua 注释与 docs 同账）

扫法：`git log -p --format="@@%h" 4de90ad~1..cd1f6d7 -- '*.lua'` 的新增行过
`实测|实机|踩过|红字|测量`，再映射当前工作树行号。**行数以当前 worktree 为准，并发修改会位移 ——
定位以"原话锚"为准。**

| # | 文件:行 | 原话（锚） | 应改口径 | **真在 12.1.5 验过？（证据，不猜）** | 证据类型 |
|---|---|---|---|---|---|
| A1 | `Utils/Skin.lua:1142` | "2026-11-03 实测 53 只里 32 只还是暴雪原样" | 标 **12.1.5 实测（历史证据）**；"待 1.60 复验"就是这个数要重新数 —— C2.1"32 只清零"硬账的基线 | **验过** —— `5bc814e` 正文首行 *"Measured on the live client: 53 close buttons, 21 carrying our monet_close_*"* | **commit 自述**（`5bc814e` 正文，逐字在） |
| A2 | `Utils/Skin.lua:1375` | "…= self:Get…)`（2026-11-03 实机红字）" | 标 12.1.5 历史证据；`TexOf` 漏斗本身两客户端都无害（取不到返回 nil），但"四个方法都拒点号"这一**事实**要在 1.60 重测一次才算 | **验过** —— `ff1bd7c` 正文 *"…this client rejects a nil self on widget methods. Measured on a live…"* | **commit 自述**（`ff1bd7c` 正文） |
| A3 | `Utils/Widget.lua:1272` | "2026-11-03 实机踩过一次"（Ellesmere 数值照抄致左右反） | 标 12.1.5 历史证据；`SetRotation` 方向约定在 1.60 待复验（两客户端都有该方法，符号未验） | **验过（间接证据）** —— 注释自述 + 同晚 `c58fae9` *"the game is up on retail"*；该 commit 正文没有独立 Measured 句，`44f0253` 正文反而是条件句 *"If the live arrows ever come out mirrored, flip…"*（1.60 侧待验） | **commit 自述（间接）** —— 事件本体只有注释自供，硬证据是同晚 `c58fae9` 的在线自述，非该测量本身的记录 |
| A4 | `Modules/InfoBar/Blocks.lua:541` | "实机一测就翻车：`UnitClass("player")` → 潜行者/ROGUE/**classID=4**" | 标 12.1.5 实测（`c58fae9` 自述当晚 retail 在线）；classID 跨客户端**不共享**（AGENTS 原话），1.60 上盗贼归类必须重测一次 | **验过** —— `cd1f6d7` 正文 *"Measured on the live client: … rogue as …"* + *"Verified live: role=DAMAGER, agi 140 >"* | **commit 自述**（`cd1f6d7` 正文两句都在） |
| A5 | `Modules/InfoBar/Blocks.lua:671` | "1.60 与零售 12.1.5 都有这个命名空间（**实机两边都验过**）" | **本表唯一的口径错误行**：1.60 未开过服，"两边都验过"应降级为"12.1.5 实机验过 + 1.60 文档（`docs/api` 快照有该命名空间）"，上线日随 `/mui compat` 补验 | **12.1.5 侧验过（同日 `cd1f6d7` 证据）；1.60 侧 = 纯离线推断**（只有 `docs/api` 快照）—— 全表唯一带"离线"半句的行，错在把它写成"验过" | 12.1.5 侧 **commit 自述**（`cd1f6d7`）；"两边都验过"这半句 = **仅注释宣称**（正是本列要抓的） |
| A5b | `Modules/InfoBar/Blocks.lua:674`（A5 同段第二句） | "返回序：specId, name, description, icon, **role**, …（**两个客户端一致**）" | 与 A5 同类：跨客户端一致性目前只有 12.1.5 侧证据 ⇒ 改标"12.1.5 实测序，1.60 待 `/mui compat` 一并核"。**11-03 傍晚补行**：该句不含 `实测/实机/踩过/红字/测量` 任一关键词，**被本表原扫描正则漏掉**（补扫 = 窗口新增行过 `两个客户端 / 两边都 / 1\.60 与零售 / 跨客户端`，命中 2 行 = A5 + 本行，全仓 `.lua` 唯一） | **12.1.5 侧验过**（同 `cd1f6d7`）；"两个客户端一致" = 跨客户端外推 | **commit 自述**（12.1.5 侧 `cd1f6d7`）+ **仅注释宣称**（一致性那半句） |
| A6 | `Modules/Tooltip/Tooltip.lua:465` | "2026-11-03 前这里写的是 `Color:GetNeutral()` —— 实机读成…" | 标 12.1.5 历史证据 | **验过** —— `c58fae9` 正文 *"Verification is visual -- the game is up on retail, so /reload and hover a spell"* | **commit 自述**（`c58fae9` 正文） |
| A7 | `Modules/Tooltip/Tooltip.lua:523` | "（**本客户端**全局常量实测）：`NORMAL_FONT_COLOR` (1, 0.82, 0)…" | "本客户端"是 8.13.5 要退役的写法，改标 **12.1.5 实测**；这两个常量的**数值**在 1.60 可能不同 → 直接决定黄带容差匹配命中不命中，上线日第一趟重测 | **验过** —— `c58fae9` 正文 *"Measured global constants on this client"* | **commit 自述**（`c58fae9` 正文） |
| A8† | `docs/HANDOFF.md 8.26`（参考件行 + "逐像素重合"行） | "笔画 ≈4px（12.5%）… 与参考件逐像素重合" | **被外部实测推翻**：参考件 run = **8px**（垂向 ≈5.7px / **17.8%**）；我们按常数画的 32px 源图 run = 5、**交付件（TGA 降到 32）run = 6**（`runsMid` 12..19 vs 13..18），中心行交叠 8 vs 6 —— "细一圈"没修掉、只对齐了 bbox。"逐像素重合"只对 bbox/跨度/质心/四边对称（+alphaMax 255）成立。已就地订正 8.26 / 8.28.1 / 8.28.7。**11-03 审查收工**：占比定数 **我们 0.125 / 参考件 0.177**（= 8÷√2÷32；比率方向 粗≈41% / 细≈29%，"细 35–40%"作废），六档×两缩放 12 种显示直径全高于亚像素临界（我们 <8px、参考件 5.66px）⇒ 判**不存在亚像素线**，三档判定 = **按几何可不管**，实机只剩 24px@1 并排看一眼 | 错在**自校验闭环**（`audit-pixels` 从不比对参考件笔画）；推翻证据 = 审查 `4b077830` 逐像素实测（外部、已落地） | —（非客户端宣称，三类口径不适用；推翻源 = 离线逐像素实测） |
| A9† | `docs/HANDOFF.md 8.28.7` 第 2 条 + `tools/regen-textures.js` 斜纹注释（**11-04 按锚：`差别全在密度`**；旧记 `:744/:746`、集成道自报 `:763` 均已漂，行号只当线索） | "α 加权占空 **参考件 27.3%** / 周期 ≈6.3" | **同一数字、错的对象**：27.3% / 6.3 = **2026-10-31 对零售版截图的测量**，不是本机实物。本机 `statusbar-stripes-thin.tga`（64×32，type 10 RLE）实测周期 4、剖面 [255,129,0,129]、占空 **50.3%**（与注释"我们（周期 4）50.3%"逐位相同）；`thick.tga` 42.3% 无硬剖面 ⇒ S1（周期 8 / 37.5%）**背离本机实物**。注释修改由集成道执行（本车道一字不碰 tools/），**11-04 复核：该段已随 `b9c3fc2` 入库**，生成器常数一字未动；回不回周期 4 = **待作者拍板**（PRELAUNCH 第 8 条） | 错在**口径混用**（截图测量写成参考件测量）；推翻证据 = `4b077830` 本机实物实测（自带 RLE 解码，`tools/compare-andromeda-close.js`） | —（非客户端宣称，三类口径不适用；推翻源 = 本机实物逐字节/逐像素实测） |
| A10‡ | `Utils/Skin.lua:1526-1537`（口径块）+ `:1543` `QUALITY_FALLBACK` + `:1568-1569` `pcall(C_Item.GetItemQualityColor, q)` + `:1604` `Skin:QualityColor` + `:1621-1624`（`QualityOf` 头注）+ `Modules/Bags/Bags.lua:369-371` | "先问客户端要色" / "**实机探针全 nil**…`C_Item.GetItemQualityByID` … **实机验证 q=2 直接解出**" / "Bags.lua:369 那一份自己的手调表**已删掉**" | 标 **12.1.5 实机判例**（`QualityOf` 头注明写"本客户端（WOWFOREVER 12.1.5）"）。1.60 侧要验的**不是 API 在不在**（`docs/api/FUNCTIONS.md:2700` 离线已确认 `C_Item.GetItemQualityColor(quality) → colorRGBR/G/B/qualityString` 在 1.60 索引里；全局那三个同样缺席，但 `docs/api` 是 API 文档索引、**缺席≠不存在**，见 8.29.2 口径），而是**客户端给的颜色与旧手调六档是否一致**——这次改动的全部收益就压在这一条上。**⚠ 反驳交办口径**：交接说色彩道"将把 Bags.lua:369 改走同一访问器"，工作树现状是**已经改完**（Bags 手调表已删、`Bags.lua:380 return Skin:QualityColor(...)`）——**未提交**，属今日在飞改动，别当未来时记账。验收子项（三处同色）落 CHECKS C2 | **半验**：`C_Item.*` 可用性 = 注释自述的 12.1.5 实机；"客户端色 == 旧手调值"**从未比对过**（旧写法各算各的，本来也无可比性）⇒ 1.60 第一趟必须眼看 | **仅注释宣称** + 离线闸门（`node tools/quality-color-probe.js` 本轮实跑 48 断言 / 入口 4 项全过，见判例④订正后口径：它自供假 `C_Item` 能走到成功支、但数值是编的；**判例⑤**：走 `api_stub` 的 harness 跑连成功支都进不去，只见兜底六档）；未提交 ⇒ **无 commit 自述可用**。**11-03 集成道确认**：品质色**全仓只剩一处真值源 = `Skin:QualityColor`**（交办结论，与本道 grep 一致）。 |
| A11‡ | `Modules/UnitFrames/Auras.lua:565`/`:693`/`:696`（三条 11-01 实机判例）+ `:580-603` `SyncAuraFitTicker`/`SetFitGroupMounted` + `:713-718` 导出契约 + `Modules/BuffFrame/BuffFrame.lua:249-263`（`SetExternalAuraFit` 注释）+ 调用点 `:462/:470/:668/:683` | "实机 2026-11-01：60 个字体串就是这么改掉的" / "实机 2026-11-01：目标框 8 个 buff 的时长一直是 ARKai_T@17 默认字体" / "实测一次刷出 40 多条「轮询读不到可见性」" | 三条标 **12.1.5 历史证据**；旧写法（每按钮 PollWatch）已被中央 1s ticker 取代，1.60 上"遍历子件 + `SetFont` 都读得动"这条**前提本身要重验**（依赖 pcall 在 1.60 也成功）。**⚠ 反驳交办口径**："目前没有任何人调 `ns.AuraFitMounted(false,'external')`"在工作树里**已不成立** —— BuffFrame 自建 helper 并在四条生命周期边界上成对销/建（:462 建容器失败支销、:470 成功支建、:668 模块开启建、:683 模块关闭销），`tools/test-aura-fit-external.js` [3] 全绿、[5] 里 `external` 组判"可停"。**真实边界见下方 P1 段** | **12.1.5 侧验过（日期式注释自述，无同日 commit 正文可挂）**；1.60 侧 0 证据，且机制**整体未提交** | **仅注释宣称**（三条 11-01 判例）+ 离线测试（`node tools/test-aura-fit-external.js` **11-04 重跑 = 全部通过（26 项）**，本车道亲手复现命中；早前记的"23 过 / 3 失"是**测试镜像没扫到 `Auras.lua` 内部那一版的快照**，已修、非代码缺口）；机制**已提交 `8e7dd88`、未部署**（部署态仍是 `cd1f6d7`） ⇒ "12.1.5 实机"那三条仍是**仅注释宣称**，`8e7dd88` 的自述只到"离线闸门全绿" |

**新列小结（11-03，证据逐条从 commit 正文取）**：**A1–A7 共 7/7 行都在 12.1.5 真验过，纯离线推断的行为 0**；
唯一"离线"半句藏在 A5 的 1.60 侧（写成了"验过"，正是本表要抓的错）。所以 A 表整体是**跨客户端复验账**，
不是"补做验证"账 —— 上线日每行只需"对着 12.1.5 结论看一眼 1.60 是否一致"。
**11-03 傍晚补行 A5b**（同段"两个客户端一致"，因无关键词被原正则漏抓）⇒ `.lua` 侧共 **8 行**，判级与 A5 同型；
可执行改写见本节末**返工单**。
**† A8/A9 为 11-03 审查逐像素实测后补的同类行**：对象是本车道自己的 docs 记录（非 .lua 注释、与客户端无关），
末列记"错误来源 + 推翻证据"而非"12.1.5 验过？"；两行共同的错型是**把自校验/别处口径的数字当成参考件实测**，
不进上线日复验账，进的是拍板账（PRELAUNCH 第 8 条）。

**证据类型列口径（11-03 定稿，逐行按硬证据填、拿不到留空）**：只认 `commit 自述` / `日志时间戳` /
`仅注释宣称` 三种；**"12.1.5 实测"这个结论只允许从前两种推，不许从注释自供推**（注释正是本表要审的对象）。
本轮没有对过游戏 Logs ⇒ **`日志时间戳` 0 行**；A1/A2/A4/A5(1.60 侧除外)/A5b(12.1.5 侧)/A6/A7 = commit 自述（正文原句本轮
`git log -1 --format=%b` 逐条复核在）；**A3 特殊**：事件本体只有注释自供，同晚 `c58fae9` 在线自述算**间接**
⇒ 严格口径为 **7 直接（含补行 A5b）+ 1 间接、0 行"仅注释宣称"成立的行**；A5 的"两边都验过"与 A5b 的"两个客户端一致"
= 仅注释宣称（记在行内，这正是它们的错）。A8/A9 非客户端宣称，标 —。

**‡ A10/A11 与本表其余行的来源不同（11-04 已解除 ‡，按下述边界改判）**：本表扫法只看**已提交**范围
（`4de90ad~1..cd1f6d7`），这两行当时来自**11-03 下午工作树的未提交改动**（`git status` 里 `Utils/Skin.lua`、
`Modules/Bags/Bags.lua`、`Modules/UnitFrames/Auras.lua`、`Modules/BuffFrame/BuffFrame.lua` 均在 M 列；新闸门
`tools/quality-color-probe.js`、`tools/test-aura-fit-external.js` 在 ?? 列）⇒ 当时上限只到"仅注释宣称 + 离线闸门"。
**11-04 作者授权提交后（拍板第 14 条；本轮三笔 = `8e7dd88` 源码 / `b9c3fc2` tools+harness / `302164d` docs+README，
`302164d` 是最后一笔 —— 此后的订正（含 `AGENTS.md` 全文）仍只在工作树，见 ④ 末条）**：源码侧随 **`8e7dd88`**、
两份闸门随 **`b9c3fc2`** 入分支 **`lane/prelaunch-1105`**、docs 与 README 措辞随 **`302164d`** ⇒ **‡ 解除、可挂 hash**。**但改判只到这一层**：`8e7dd88` 的自述是"插件源码批次（离线闸门全绿）"，
它**不自述任何客户端实机** ⇒ 表里"12.1.5 实测"那类结论仍只能由**原批次 commit 正文**支撑（`cd1f6d7` / `ff1bd7c` /
`5bc814e` / `c58fae9`），不许因为"现在有了 hash"就把注释自述升级成 commit 自述。
**A11 的 P1 覆盖边界（上线日性能对比口径，必读）**：
① **`_forever_` 现存部署态 = `cd1f6d7`，里面没有这套账本机制**（机制**已提交**：随 `8e7dd88` 入分支 `lane/prelaunch-1105`，
11-04 本车道复核 `git show HEAD:Modules/UnitFrames/Auras.lua | grep -c AuraFitMounted` = **5** —— 注意**分支 HEAD ≠ 部署态**，
游戏里那份仍是 `cd1f6d7`）⇒ **"P1 已修"的准确口径 = 已提交、未部署、未实机复验（未 push）**。上线日的 OnUpdate/ticker 对比
**拿它做"改后"基线**（代码已在包里），前提是先跑 D-1 那条裸跑部署、`sync-check` in sync 且**部署后**重跑才算数；
**部署前游戏里那份 `cd1f6d7` 才是"改前"**。对比文字写死为"**离线断言 26/26 已过，运行期收益待 1.60 首趟量**"，
不写"已修好省了多少 OnUpdate"。
② 目标框两组（`monetTargetBuffs`/`monetTargetDebuffs`）的销账在 `Auras.lua:835`（`showTargetAuras` 关）+
`Modules/UnitFrames/UnitFrames.lua:1172`（模块开关），"external"组四处边界见 A11 行 —— 但**这几条路径实机是否真被走到、
`C_Timer ticker` 的 `Cancel()` 是否成功，全部离线不可证**（`tools/test-aura-fit-external.js` [6] 自己列了这份名单）。
③ 复核方法只有两条现役命令：`/mui perf`（调度器总账：逐路耗时 / 失败计数 / 被暂停的轮询框）与
`/mui buffframe probe` —— **后者只数 `GetChildren` 个数，覆盖不到 ticker 起停**（test :240 原话），别拿它当"P1 已生效"的证据。
④ 关闭 BuffFrame 后若目标框两组仍在场，ticker 继续跑**是设计不是漏**（test [6] 第 3 条）；对比时先确认模块开关状态。

**PLAN 侧欠的一笔**（本车道不代笔，`docs/PLAN-refactor*.md` 归集成道）：品质色"单一真值源收口"属架构整合成果，
应在 PLAN 的成果条里记一行（`Skin:QualityColor` 为唯一出口、Bags 手调表已删、色块形状统一为命名字段 `{r,g,b}`）；
本车道已在 A10 与 CHECKS C2 落账，**避免两处各写一份数字**。

**不入账的相邻行**（核查过，非实测宣称）：`Utils/Widget.lua` 的"实机若发现左右反了…"（条件句 ——
**11-03 傍晚复核：这行现已不在树上**，`git show HEAD:Utils/Widget.lua` 与本道工作树都查无此句；
它是 `44f0253` 加入、同窗口 `ff1bd7c` 又删掉的 ⇒ 不列为待返工行，只作扫描过程记录）；
`Modules/Bags/Bags.lua`、`Modules/Skins/Forever.lua` 该批新增行里无实测式表述。docs 侧本账只命中
HANDOFF 8.28.8 一句"`diff -q` 实测（2026-11-03）"—— 那是**离线文件比对**，不是游戏实机，口径无需降级。
文档车道自己写的 8.28/C2.1 已全部带"12.1.5 历史证据"标签，本表对它们无返工。

**A 表原话返工单（11-03 傍晚 · 交集成道执行；本道一字不碰 `.lua`，只出文本）**

> **定稿口径句 = "12.1.5 实测（历史证据），待 1.60 复验"**。用法：每行**只替换那一行**（多数原行是长注释的
> 中间行，上下行接续别动、缩进照原行）；**"原话锚"是定位主键**（`grep -n "锚" <文件>` 全仓唯一命中，行号会随并发漂）。
> 本单**不改任何技术结论**，只给证据补上"是在哪个客户端验的"。**A5/A5b 是降级**（把跨客户端外推写成待验）。

| # | 文件:行（现工作树） | 原话锚（grep 主键） | 建议改写（整句，可直接粘） | 一句话理由 |
|---|---|---|---|---|
| A1 | `Utils/Skin.lua:1142` | `53 只里 32 只` | `-- 12.1.5 实测 53 只里 32 只还是暴雪原样（历史证据，`5bc814e` 正文）；1.60 上这个数要重数才算，待 1.60 复验。见 Skin:CloseButtonByArt。` | 这个数是 C2.1"32 只清零"的**基线**，不标客户端就分不清 1.60 上"还剩几只"是跟谁比 |
| A2 | `Utils/Skin.lua:1375` | `2026-11-03 实机红字` | `-- = self:Get...)`（12.1.5 实机红字 = 历史证据，`ff1bd7c` 正文；1.60 是否同样拒点号待复验），而且不是所有方法都这么响 —— `GetDisabledTexture`` | 漏斗本身两客户端都无害，但"点号被拒"这条**事实**只在 12.1.5 观测过 |
| A3 | `Utils/Widget.lua:1272` | `2026-11-03 实机踩过一次` | `-- 12.1.5 实机踩过一次（历史证据；硬证据只是同晚 `c58fae9` 自述 retail 在线 = **间接**）：最初把 Ellesmere 那组数值（它是**基图朝左**）原样抄过来，` | 事件本体只有注释自供，标"间接"防止 1.60 侧被当成已验 |
| A4 | `Modules/InfoBar/Blocks.lua:541` | `实机一测就翻车` | `-- 的**猜测**排的。12.1.5 实机一测就翻车（历史证据，`cd1f6d7` 正文；classID 跨客户端不共享，1.60 上盗贼归类待复验）：`UnitClass("player")` 返回 `潜行者 / ROGUE / classID=4`，` | 盗贼验收项（CHECKS A4）就锚在这句上，1.60 的 classID 必须重测 |
| A5 | `Modules/InfoBar/Blocks.lua:671` | `实机两边都验过` | `--- 入口取 `C_SpecializationInfo`：12.1.5 实机验过这个命名空间（`cd1f6d7` 正文），1.60 侧目前只有离线依据（`docs/api` 快照收录该命名空间）—— **待 1.60 复验，上线日随 `/mui compat` 补**，` | **全表唯一把"离线推断"写成"验过"的行**：1.60 从未开过服 |
| A5b | `Modules/InfoBar/Blocks.lua:674` | `两个客户端一致` | `--- 返回序：specId, name, description, icon, **role**, ...（12.1.5 实测序；1.60 与上一句一并 `/mui compat` 核）。` | 同段第二句的跨客户端断言，因无关键词被原扫描正则漏抓（本轮补行） |
| A6 | `Modules/Tooltip/Tooltip.lua:465` | `和正文同一个灰，实机读成` | `--- 2026-11-03 前这里写的是 `Color:GetNeutral()` —— 和正文同一个灰，12.1.5 实机读成` | 视觉结论来自 retail 在线（`c58fae9`），1.60 要重看标题/正文层级 |
| A7 | `Modules/Tooltip/Tooltip.lua:523` | `本客户端全局常量实测` | `-- （12.1.5 实测的全局常量 = 历史证据；1.60 上这两个数值要重测，黄带容差是否命中取决于它）：`NORMAL_FONT_COLOR` (1, 0.82, 0) —— r-g = 0.18，掉出窄带；` | "本客户端"正是 8.13.5 要退役的写法，且这两个数直接决定容差匹配命中 |

**可选随动（同段同类裸日期 / "本客户端"写法，改不改由集成道定；均在 A 表扫描窗口外，本道不并入硬账）**：
`Blocks.lua:538` 锚 `**不写职业表**（2026-11-03 修）` → 补"在 12.1.5 上修"；`Tooltip.lua:469` 锚
`（实机 2026-11-01：` → `（12.1.5 实机 2026-11-01：`（`08d9c582`）；`Blocks.lua:535` 锚 `本客户端所有 Unit*/Get*`
→ `12.1.5 客户端所有 Unit*/Get*`（`6925adf5`）；`Utils/Widget.lua:176` 锚 `实机 2026-11-01：`（`66226eb8`）同型。

**范围边界（先说清，免得被当成"全仓统一改口径"）**：本单硬账 = 上面 **8 行**。`本客户端` 这个写法在发行 `.lua`
里实测共 **116 处**（其中 **20 处**同句含"实测/实机/测量"，`grep -rn 本客户端 --include=*.lua Modules Utils Core.lua`
本轮实跑），那是 8.13.5 的退役工程、要单开一道，**不并进上线前这趟**；A10/A11 两行的注释也随未提交改动在动，
返工单不覆盖它们，避免与色彩道/P1 道双写。

**扫描口径补记（为什么是 8 行而不是 7 行）**：原扫法 = 窗口 `4de90ad~1..cd1f6d7`（15 个 commit，`git log --format=%h`
逐条复核全在 11-03）新增行过 `实测|实机|踩过|红字|测量`，命中 8 句 = A1–A7 + 一句条件句；条件句"实机若发现左右反了…"
已于同窗口 `ff1bd7c` 删除（`git show HEAD:Utils/Widget.lua` 与工作树均查无此句），故不构成返工行。
**第二轮补扫**换关键词 `两个客户端|两边都|1\.60 与零售|跨客户端`，全仓 `.lua` 新增行只多命中 A5b 一句 ⇒ 总数 **8**。

**返工单执行回执（11-04 · 集成道执行，本车道逐行 grep 复核，不采信转述）**

- **8 行全部落地**（A1–A7 + A5b，注释级、口径统一），随 **`8e7dd88`** 入分支 **`lane/prelaunch-1105`**（`git log --oneline -1` = `302164d`，三笔 `8e7dd88` / `b9c3fc2` / `302164d`，**不 push、仓保持 private**）。本车道复核命中（**行号按现在实读，返工单里那些行号已漂 1–3 行**）：`Utils/Skin.lua:1142`（A1）/ `:1376`（A2，原记 1375）/ `Utils/Widget.lua:1272`（A3）/ `Blocks.lua:541`（A4）/ `:671`（A5）/ `:675`（A5b，原记 674）/ `Tooltip.lua:465`（A6）/ `:523`（A7）。
- **旧短语清零复核**：`实机两边都验过` / `两个客户端一致` / `本客户端全局常量实测` 在发行 `.lua` 三句各 **0 命中**（本车道 `grep -rl --include=*.lua Modules Utils Core.lua Config` 实跑）。
- **闸门**：`luac -p` 五文件过 / `api-audit` 无 HARD / `audit-locals` 56 过 / `audit-taint` 61 文件 0 BLOCKER / `check-frame-list` 一致（ALLOW_DYNAMIC 7）/ `audit-pixels` 0/31 失 / `test-aura-fit-external` **26/26**（本车道 11-04 亲手重跑复现"全部通过（26 项）"）。**状态口径 = 离线闸门全绿，实机验证待 1.60 首趟（11-05）**。
- **"可选随动 4 行"未做 —— 一半理由成立、一半不成立，按实测记**：① `实机 2026-11-01：` 一族确实是**一批**（本车道 `grep -rl --include=*.lua` 实数 **8 个文件**：Bags / Cooldown / Skins/System / Tooltip / UnitFrames{Auras, BossFrames, UnitFrames} / Utils/Widget；集成道报的"10 个"本轮未复现，差 2 个文件，不阻断结论）⇒ 属 8.13.5"本客户端退役"批次，**不并进上线趟，接受跳过**；② 但交办里"`Modules/InfoBar/Blocks.lua:538` 的锚 `不写职业表**（2026-11-03 修）` grep 0 命中、锚已过期"这一条**与实测不符**：该句**就在 `Blocks.lua:538`**（`-- 坦克 / 法系 / 物理 三档的判定 —— **不写职业表**（2026-11-03 修）。`），补"在 12.1.5 上修"这半句仍然可做。**教训入账**：随动条目也必须各自给**唯一且可 grep 的锚**，否则"可选"会变成"默认跳过"，还会在回执里长出一条不成立的理由。
- 本车道不动 `.lua` 补这一句（发布前 48 小时不制造第六个写者）；要补就随下一笔 docs/注释提交一起做，**由集成道执行**。

### 8.29.2 B 节：单一来源的材质判据 + 上线日视觉验收第一优先级

**B1 复测源现状（订正审查前提）**：开发根 `../Andromeda` 确已缺席；但 2026-11-03 本车道复核，
`_classic_titan_…AddOns/Andromeda/assets/textures/ui-close.blp` 与 `statusbar-stripes-thin.tga` **仍在位**
（`3f2ba5f` 当年就是从这条路径测的）。所以准确说法是"**单一来源且悬**（挂旧客户端目录，一次磁盘清理即断）"，
不是"已断"。而审查的**知识论判定成立且要点名**：现有唯一"验收"是本仓自产的 `audit-pixels`（管 2 的幂 /
白衬底 / 色相 —— 格式纪律），✕ 的几何比例（跨度 75% / 笔画 12.5% / 质心 31.5 / "32×32 与参考件逐像素重合"）
属**自校验闭环，不算外部验证**。**11-03 审查收工后本条已闭环**：该"逐像素重合"事后只对 bbox / 跨度 / 质心 /
四边对称 / alphaMax 成立，**笔画那一半被实物推翻**（我们 0.125 vs 参考件 0.177），几何表与比率口径见 8.26 订正块。
**11-03 补（收工口径）**：参考件对交付贴图的逐像素对比已由审查会话 `4b077830` **做完并收工** —— 本条"自校验"
判定**已升级为外部验证**，且外部验证的结果正是推翻笔画那一半（见上）；上线日视觉验收（B2）不因此取消。
**11-03 结果（审查会话收工，两笔已回 + 几何表落地）**：对比回话推翻了手边记的两个"参考件数字"——
✕ 笔画（8.26 订正块 / A8）与斜纹剖面（8.28.7 第 2 条 / A9），两个都是记错口径、被实物实测推翻；几何四项
（bbox / 跨度 / 质心 / 四边对称）重合成立。**收工新增**：① 占比定数 **我们 0.125 / 参考件 0.177**（比率方向
按 8.26 订正块写死：参考件粗 ≈41%、我们细 ≈29%；**"细 35–40%"作废**）；② 六档 × 两缩放的 12 种显示直径
**全部高于亚像素临界**（我们临界 = 显示物理直径 <8px，参考件 5.66px）⇒ 对比页判"不存在亚像素线"，
**粗细差是恒定比例**，不是某一档破线；③ 因此 8.29.2-B1 的"自校验"判定**已升级为外部验证**（对比源 =
参考件实物解码，本仓自产闸门不再是唯一证据）。B2 上线日视觉验收**不取消**，但动作可以压小：**24px@1
并排看一眼**即可（mip 选择 / 双线性软化 / 圆帽端点 / DXT5 量化 + 本仓 ×2 下 1px 描边奇偶先例，几何算不出，
只能实机看）。

**B2 上线日视觉验收第一优先级（可操作条）**：`5bc814e` 把这套自校验过的字形推给了全屏 53+ 只暴雪 ✕，
比例一旦偏（18–24px 钮上过大/过小、染色后发虚）就满屏可见。开服第一趟按三档尺寸各看一处：
InfoBar 属性面板（自建钮）/ 背包总控窗 / 原 32 只暴雪 ✕ 任取两件（StaticPopup、秒表、商城）。
**通过 = 字形一眼认 ✕、不吃满点击区、染主题色后不虚**。
**11-03 审查收工补（本条动作压小，判据不变）**：上面括号里"18–24px 钮上…染色后发虚"这一候选解释**已被几何层排除**
—— 六档钮径 × 两缩放共 12 种显示直径全部高于临界（我们笔画进亚像素要显示物理直径 <8px，最小那档 18px@1 也有
2.25px），差的是**恒定比例**（0.125 vs 0.177），不是某一档破线。⇒ 上线日第一趟压成**一个动作：24px@1 与参考件
并排看一眼**；三档遍看降为"顺手看"。仍要实机才定的四项：mip 选择、双线性软化、圆帽端点、DXT5 量化（加本仓
"×2 缩放下 1px 描边奇偶/软化"先例项）。**hotfix 归因树与"一眼不对即 hotfix"的门槛不变**。不过时归因树：

- **比例不对**（偏大/偏小/偏细偏粗）→ **只改贴图**：`tools/regen-textures.js` 的 `drawCloseX` 两个常数
  （`CLOSE_GLYPH_SPAN` / `CLOSE_GLYPH_STROKE`）→ `node tools/regen-textures.js standard` 同名重出
  TGA+BLP → `audit-pixels` → 部署（**同名重出**不触"改名要重启"的文件索引坑，AGENTS 客户端行为细则）
  —— 全量扫描保留，不动；
- **误伤**（非关闭对象被换、最小化减号变 ✕、页签被当关闭钮）→ **收 `5bc814e`**：摘掉 5 步全量扫描里的
  `Skin:CloseButtonByArt` 调用（一行），退回"只穿我们自己的窗"，32 只暴雪原样暂与细金 ✕ 并存 —— 两画风
  并存是作者不要的观感，但比误伤可控；
- **两者皆有** → 先收全量扫描保平安，再慢调比例，调完重新放开。

**B3 无第二样本名单残项**（缺席 = **静默 no-op**，不报错、不红字，只能对账；1.60 找不到真名用
`/mui compat find <片段>` 扫，别改代码猜）：

| 残项 | 出处 | 上线日动作 |
|---|---|---|
| `groupfinder-icon-role-large-{tank,heal,dps}` atlas 名 | `4de90ad`（只在 12.1.5 侧验过命中） | LFG 面板开一次 + `/mui skins diagnose` 看该帧账 |
| Stepper 的 `UI-ScrollBar-Scroll*Button-*` atlas 与 `button.upTexture`/`normalTexture` art key | `28187aa`（方向判定的全部依据 = key 名拼出 Up/Down/Left/Right） | 任意 12.x 滚动条看方向；key 不存在 = 方向拿不到 = 静默不画 |
| `LFGParentFrameTab3` | `4de90ad` 的 `LFG_TOP_TABS` 实名清单 | diagnose 账本该行 ✗/✓；整排 ✗ 先查 GameRule（AGENTS 换客户端口径） |

**B3.1 正式离线对账源：主仓 `framexml-source`（11-03 建账，三个残项逐名核完）**

**入库声明用得上身份信息（本车道实测）**：绝对路径
`C:/Users/EastHillGu/Documents/wowaddonsdev/MonetUI/framexml-source`（**主仓目录里，worktree 不带**——
已核 `02efb0` worktree 无此目录）；它自己是一份独立的 `git clone https://github.com/Gethe/wow-ui-source.git`，
**分支 `forever`**、HEAD `aff0d8c`（提交说明 *"1.60.1 (70707)"*，2026-11-02）、`version.txt = 1.60.1.70707`、
`Interface/AddOns` 共 **349 个包**。主仓 `.gitignore:62` 把 `framexml-source/` 整目录排除、**git 跟踪 0 个文件** ——
它**不会随 worktree 清理消失**（本就不在 worktree 里），会被清掉的唯一场景是**主仓**跑 `git clean -fdx`
（`-x` 连 ignored 一起删）。重建成本低：一条 clone + checkout forever。
**版本口径**：转储 build **70707**，我们 `docs/api` 快照抓自 **70634** —— 差 3 个 build 的同分支转储，
FrameXML 名/模板这种慢变量够用，但**"两边都有"的结论仍以 70634 快照为准、以实机为终判**。

| 残项 | 结论 | 证据（文件:行，均在上述 `Interface/AddOns` 之下） |
|---|---|---|
| `groupfinder-icon-role-large-{tank,heal,dps}` | **确在，双处** | ① `Blizzard_GroupFinder_VanillaStyle/Blizzard_LFGVanilla_Browse.lua:14-16`（`TANK/HEALER/DAMAGER` 三映射）；② **`Blizzard_UIPanelTemplates/Camelot/UIPanelTemplatesOverrides.xml:8/:19/:30`**（`TankIcon/HealerIcon/DamagerIcon` 三只 `atlas=` —— **这正是 `4de90ad` 换图的对象**，Camelot 覆盖层，不依赖 VanillaStyle 包） |
| Stepper 的 `UI-ScrollBar-Scroll*Button-*` 与 `button.upTexture` art key | **确在，四方向全** | `Blizzard_SharedXML/Shared/Scroll/TrimScrollBar.xml:123/144`（竖排 `upTexture`/`downTexture` = `ScrollUp/DownButton-Up/-Down`）、`:263/:284`（横排 `ScrollLeft/RightButton-*` 同键）；`MinimalScrollBar.xml:107-110/:123-125`（`minimal-scrollbar-arrow-{top,bottom}{,-over,-down}` 三态齐）；`returntobottom` 一支在 `Blizzard_ChatFrameBase/Mainline/FloatingChatFrame.xml:530/:550-552`（聊天框滚到底钮，**不在 MinimalScrollBar 本体**） |
| `LFGParentFrameTab3` | **确在但限定**（字面名找不到、同物在） | 定义 = `Blizzard_GroupFinder_VanillaStyle/Mainline/Blizzard_LFGVanilla_ParentFrame.xml:68`：`<Button name="$parentTab3" parentKey="Tab3" id="3">`，`$parent` = 同包 `Classic/…ParentFrame.xml:22` 的 `LFGParentFrame` ⇒ 运行期全局名正是 `LFGParentFrameTab3`；处理函数 `Blizzard_LFGVanilla_ParentFrame.lua:162`。**Tab1/Tab2 定义在 Classic xml:36/:66，Tab3 只在 Mainline** —— 子目录二选一（见下行） |
| （抽查副产品）`LFG_DROPDOWNS` 两个下拉 | **确在，字面 grep 0 命中是假阴性** | `Classic/Blizzard_LFGVanilla_Browse.xml:414/:422` 写作 `name="$parentCategoryDropdown"` / `"$parentActivityDropdown"`（`$parent`=`LFGBrowseFrame`，同文件有定义）⇒ 拼出的全局名与 `Forever.lua:45` 名单一致。**教训入档：FrameXML 用 `$parent` 拼接全局名，字面名 grep 不中 ≠ 缺席，要反查 `$parent` 宿主**（`/mui compat find` 的离线版同理） |

**离线判不了、必须实机的名单**（转储只证"名字被 Blizzard 代码使用"，不证"运行期存在"）：
① `Blizzard_GroupFinder_VanillaStyle` **整包**是否在 1.60 的加载清单里（349 包在转储 ≠ 客户端都加载，
GameRule/配置可关）；② 加载的话取 **Classic 还是 Mainline** 子目录（`LFGParentFrameTab3` 的定义只在
Mainline —— 若跑 Classic，Tab3 整排缺席是**正常行为**，别当换肤 bug 查）；③ 转储里找不到的**动态拼名**
（`$parent..i` 循环造出的行/按钮）本来就无静态字面量可核 —— 只能 `/mui compat find <片段>`；
④ 材质 atlas 名确在 ≠ **纹理内容**一致（build 70707 vs 70634、以及暴雪随时可改图集）—— 观感仍要实机。
**⇒ B3 三行的"上线日动作"从"核名字"收窄为"核对账①②"**：名字这半截已经不用赌了。

**TemplateDB 抽核（13 个模板名，本车道按"凭记忆风险"挑选）**：`ColoredProgressBarTemplate`（
`Blizzard_SharedXML/Camelot/ProgressBars/ColoredProgressBar.xml`）/ `BasicHybridScrollFrameTemplate`
（`Blizzard_SharedXML/HybridScrollFrame.xml`）/ `UIPanelScrollBarTemplate`（`SecureScrollTemplates.xml`）/
`SelectableButtonTemplate` / `TemplatedListTemplate` / `PagedListTemplate` / `SpinnerTemplate` /
`SearchBoxTemplate`（`Shared/InputBox/InputBoxTemplates.xml`）/ `CharacterFrameTabButtonTemplate`
（`Blizzard_FrameXML/Cata/CharacterFrameTemplates.xml`）/ `UIPanelDialogTemplate` / `MoneyDisplayFrameTemplate`
+ `LargeMoneyInputBoxTemplate`（`Blizzard_MoneyFrame/Shared/`）/ `LFGBrowseFrame` —— **13/13 确在**，
五个带指纹模板的名字全部对得上；`CharacterFrameTabButtonTemplate` 在 **Cata/** 子目录这一条记下来
（子目录二选一的又一实例）。全量核对没做（要求就是抽查）。

**B4** AGENTS.md 两处待订正（`:16` gitignore 口径、`:109` Andromeda 存在性）的**最终措词**已给在 **8.28.8-B**，
此处不重复；审查的"Andromeda 不在本机"表述经集成道 11-03 定性质为**参考件路径不存在（路径指错）**——
实物在 `_classic_titan_…AddOns/Andromeda`，材质比例判据可离线复核（详见 8.28.7 最终订正段）。

**B5 排队状态对账的重叠风险（11-03 新增，配 8.28.5 的 QueueStatusButton 订正）**：
`Modules/Skins/System.lua:38` 与 `:66` 对 `QueueStatusFrame` 做 `Dress{panel}`，而 `Modules/Skins/Forever.lua`
的 `QueueStatus*` 清单是"只过 `Skin:Need` 进账本、不换肤"（订正后口径）—— 两条线的意图重叠且覆盖面
**不等价**：panel 换肤走的 `Strip` 只淡**框自身**的 region，够不到子按钮里的图标纹理。上线日实机把
"**排队眼睛（`QueueStatusButton`）可见、可点 + `QueueStatusFrame` 面板边框正常**"归为**同一条对账项**
（CHECKS C2.1 已并入一条）。归因口径：眼睛消失 = `Skin:Fade` 类回归（8.28.5 判例复发）；
面板边框没变化 = `Need` 账本只登记不换肤、属正常，对照 `/mui skins diagnose` 账本即可分开这两种。

## 8.30 第三方插件研究：TweaksForever（QoL 套件）与 MonetUI 的吸收边界

11-04 晚按作者要求做了一轮完整研究，结论文档在 **`docs/ANALYSIS-TWEAKSFOREVER.md`**
（两个只读子代理通读 73 文件 / 20 945 行 + 集成道对本仓现状逐条核验；它全程只读，一个字节未写）。

三条最值钱的定性判断，写在这里免得以后重新推：
1. **许可是硬边界**：它 GPL-3.0-or-later，我们 MIT ⇒ 只取机制，代码全自写；
   `Data/ClassSpells.lua`（CMaNGOS 衍生训练师表）与 `Data/CampBenefits.lua`（抄法术描述文本）
   **碰不得**；它的 `media/*.tga` 违反我们"资源全部自绘"。
2. **它踩的正是我们禁止的**：`HookScript` 暴雪框 10+ 处、`hooksecurefunc("ShowUIPanel")` 这种
   全局面板路径、往暴雪对象 `SetText/SetPoint/SetScale/Hide`、从 Lua 直调
   `AcceptQuest/CompleteQuest/GetQuestReward/BuyTrainerService/LootSlot`（它自己的注释承认
   Forever **没有 secure snippets、`loadstring_untainted` 为 nil**，和我们同一环境）——
   ⇒ 这类"全自动接交任务"迟早爆「界面行为失效」，我们不做。
3. **它免费送我们两条情报**：① 不要调用 `UpdateContainerFrameAnchors` / `GetBagSize` /
   `ContainerFrameUtil_EnumerateContainerFrames` —— 它们生成**缓存表**，我们一调整条链被判污染；
   ② 原生设置树只用 `Settings.RegisterAddOnSetting`，别用 `Settings.CreateCheckbox`
   （tainted 布局会弄坏暴雪自己的设置搜索）。

已吸收：`/mui report` 诊断包（`a814d9b`，见 §8.32 待写或见文档）+ `Skin:WarnRing`。
待吸收已建任务 #28–#32（自静默注册表 / XP 速率归因 / 错误按类型静音 / 任务区域预言机 / 版本差提示）。

## 8.31 已知功能缺口：任务追踪器不画「任务专用物品」可点钮（11-04 作者拍板 = 上线后补）

**现状**：我们的追踪器替代暴雪那套，`Modules/QuestTracker/QuestTracker.lua:340-365` 对
`ObjectiveTrackerFrame` 走 `Widget:Mute(…, { depth = math.huge })`（alpha 0 + 整棵子树关鼠标，绝不 Hide）。
自己的行只画文字 + 折叠箭头 —— 全文件搜 `ItemButton|UseItem|PickupItem` **零命中**。

**丢掉的是什么**（证据在本地 1.60 FrameXML，不凭记忆）：
`Blizzard_ObjectiveTrackerShared.xml:4` 定义 `QuestObjectiveItemButtonTemplate`（`mixin="QuestObjectiveItemButtonMixin"`，
`<OnClick method="OnClick"/>`）；`Blizzard_ObjectiveTrackerShared.lua:94-104` 的点击体是
`UseQuestLogSpecialItem(questLogIndex)`，修改键点击 = `ChatFrameUtil.InsertLink(link)`；
`SetUp(questLogIndex)` 靠 `GetQuestLogSpecialItemInfo` 决定显示；`Blizzard_BonusObjectiveTracker.lua:347`
和 `ObjectiveTracker.lua:122-136` 说明它参与 SmartNavigation 左右跳格。
⇒ 带"任务专用物品"的任务，在 MonetUI 下追踪器里**没有**点一下使用的入口，只能去背包点。

**为什么今晚不做**（作者选的 C，不是漏掉）：21 点后重写追踪器行布局（图标进来要把文字右移）= 拿一整块未验面上线；
这条是局部不便，不是全局坏。明天首趟只要求"遇到一个这种任务时记下任务名与影响面"。

**做的那天要注意**：`UseQuestLogSpecialItem` / `GetQuestLogSpecialItemInfo` 在 1.60 的 **API 文档快照**里查不到
（快照 1.60.1.70634 且不覆盖这族旧全局），但 1.60 FrameXML 在调 ⇒ 运行时存在；这类旧全局通常**受保护**，
战斗里调用会被拒 → 必须带战斗门 + `ns:AfterCombat` 重试（判据同源那条另见 §8.29 与本文件"能不能碰"那节）。
排期与 #25（银行侧真槽位）同一批。

## 8.32 第三方插件研究：RurutiaSuite（工具箱 + 平台层）与 MonetUI 的吸收清单

11-04 深夜第二轮研究，结论在 **`docs/ANALYSIS-RURUTIASUITE.md`**（三个只读子代理分头通读
293 文件 / 42 459 行 + 集成道逐条核验；对方全程只读，一个字节未写）。

与 TweaksForever 的差别很重要：**它不是整套 UI，是"挂在 ElvUI / NDui / Ellesmere 上做增强"的工具箱**，
所以值钱的地方在平台层而不是功能清单。三条最该抄思路的：

1. **稀疏默认值 + 存盘剥默认**（`Core/Database.lua:84-118,136-152`）⇒ SavedVariables 只存差异。
   我们 `Core.lua:288` 的 `MergeDefaults` 是整树深拷进存档 —— 换成稀疏后，本仓反复提的
   "账本落盘比 /reload 晚 1–2 分钟"整类丢写风险直接降级（丢的只是差异，默认值仍从代码取）。任务 #33。
2. **能力矩阵按 Interface 区间 + 助手返回行为而非布尔**（`Core/Build.lua:32-139`、
   `Core/Compat.lua:27-39`：`GetPrimarySecureClickEvents()` 直接给出该用哪套点击事件）
   ⇒ 把我们"同一句话在 16001 与 12.1.5 相反"的老痛从散落的 `if` 变成一张表。任务 #34。
3. **让位注册表**（`UI/SkinProvider.lua:88-247`，其中 `EllesmereUI` 那条注册了但 `Apply` 恒 false，
   注释写"选到不等于真有桥"）⇒ 与 #28 合流，比"alpha 停掉别人的框"体面且可解释。

负面结论一条已升进 AGENTS：**绝不替换暴雪全局函数**（它加宽商人格就是换 `_G.GetMerchantNumItems` +
`MAPPED_GLOBALS`，`MerchantExpansion.lua:286-300`，虽有配对还原，但替换期间暴雪全部调用点都在我们环境里跑）。
另外它 `frame.page = ` 往暴雪框写状态、`Hide()` 暴雪框、从 Lua 直调 `AcceptQuest`/`RunMacroText` ——
全是我们禁的；**它做对的部分**是 `RaidMarker`：全程 `SecureActionButtonTemplate` + `macrotext` 属性 +
按 `IsInCombat` 门控（`View.lua:112,151`），正是 #26 该走的路。

许可：`X-License: All Rights Reserved`（非 GPL，无任何授予）⇒ 代码/数据/媒体/文案一概不复用；
它的地图遮罩、区域等级、消耗品目录、手册文案、音效、自带字体都是"内容即功能"，我们要做得自抽 DB2 自写。

排期：#33–#39（默认值模型 / 能力矩阵 / 差异刷新与自装配驱动 / 姓名板 per-token 目标监视 /
配置导出导入 / 预算任务器 / CVar 面板）。**开服前不落地任何一条**（距开服 <8 小时，这些动的正是
启动与配置路径 —— 白天每个 P0 的成因形状就是这个）。

## 8.33 同机插件普查（开服日归因底座）：EnhanceQoL / OpenMap / Lueur / QuestEcho / DungeonsForever / Polestar

结论在 **`docs/ANALYSIS-INSTALLED-ADDONS.md`**（两个只读子代理 + 集成道对高风险结论逐条复核；全程只读）。

**最重要的一条是冲突地图，不是功能清单**：`EnhanceQoLMover` 的目录条目 **`defaultEnabled = true`**
（`EnhanceQoLMover/frames_Camelot.lua:69,76,88…`），并用 **`hooksecurefunc(frame, "SetPoint", …)`**
把暴雪窗口事后重钉回它自己存的值（`EnhanceQoLMover/Init.lua:1193-1200`）。
⇒ 明天任何"我们的窗口位置改了又跳回去"**先判它**，别当 Mover/布局的 bug 查。
其余默认值也逐个看了：背包/玩家目标框/资源条**默认关**（不冲突），Tooltip 锚点与姓名板颜色按功能开。
判归属的只读探针全部记在文档 §1 末尾（`type(_G.EnhanceQoL)=="table"`、
`GetAddOnEnableState("EnhanceQoLMover")`、`EnhanceQoL.Bags.IsEnabled()`、
`C_Frame.Exists("EQOLUFPlayerFrame")`、`ContainerFrame1:GetParent() ~= UIParent`）
—— 建议下一步做 M1：把这些接管状态并进 `/mui report`，开服当天一条命令看清"哪块不是我们的"。

**许可普查**（决定能吸收什么）：EnhanceQoL 全家 / Lueur / 163UI_Info / QuestEcho / RurutiaSuite
**都没声明许可** ⇒ 按默认全权保留处理，只有机制可用；`DungeonsForever` 明文 All Rights Reserved；
`Polestar` GPL-3.0-only；`OpenMap` MIT（代码，地图美术属暴雪）。数据表一律不搬，要数据自己抽 DB2。

**它替我们证明这台客户端能容什么**（§2，都是可复用的判据）：`pcall(C_Map.SetUserWaypoint,
UiMapPoint.CreateFromCoordinates(...))` 可用；`C_MapExplorationInfo.GetExploredMapTextures` 返回真数据
（我们此前"地图 API 部分受限"的判断要下调）；`C_NamePlate.GetNamePlateForUnit("softinteract")` 可用；
`Minimap:SetUsingSoftCursor` + `C_TooltipInfo.GetMinimapMouseover` 造光标逐格扫小地图可行；
`issecretvalue` 在读点 gate 是普遍做法（**连 GUID 都可能是密值**）。
反例也记了：EQOL 自己有处未 gate 的 `UnitHealth/UnitHealthMax` 直接 format（`HealthText.lua:204-219`）。

## 8.34 2026-11-05 开服日 1.60 首趟实机（客户端：`1.60.1 · build 70790 · Interface 16001 · zhCN`）

这一趟只跑只读命令 + 作者手动按 C/B/M。全部结论标 `1.60 实测`。

**三条昨晚的修复在真机上成立**（日志原文逐条对上）：

- 姓名板 3 项 `isSecure` CVar 聚合成**一行**（`nameplateShowEnemyMinus` / `nameplateShowEnemyTotems` /
  `nameplateMaxDistance`），不再刷三遍；细账入口 `/mui nameplates cvars`。
- 加载横幅 `已加载 19/19 个模块（另 1 个已在设置中关闭）` —— 上一趟的"19/20"是 Atmosphere 被玩家关掉，不是加载失败；
  `/mui report` 的「设置差异」独立确认：`模块 Atmosphere = true（默认 false）`（= 这一版默认关、玩家打开，方向别读反）。
- **微菜单 P0 消失**（`4a458d1`：`GetScript("OnClick")` 取暴雪脚本自调 → 改 `SecureActionButtonTemplate` + `type="click"`）。
  判据不是"没看见红字"而是两条：重载后 `logs ERR,BLOCKED` 窗口内**零新增 MonetUI 条目**
  （唯一残留 `TextStatusBar.lua:110 … tainted by 'MonetUI'` 发生在重载**之前**），且 `/mui blocks` 账本为空。

**`/mui compat`：58 项，与假设不符 6 项**（`/mui compat bad` 的原文，逐条处置）：

| 行 | 1.60 实测 | 处置 |
|---|---|---|
| `canaccessobject` | 无 | 与 12.1.5 一致。`Secrets.CanRead` 走 `canaccessvalue`，一个字节不用改（§8.13.6 那条继续成立） |
| `TempEnchantFrame` | 无 | 与 12.1.5 一致 ⇒ `Modules/BuffFrame/BuffFrame.lua` 压制清单里那条**在两个客户端上都是空枪**，名字留作历史，注释已写明 |
| `LFGParentFrame` | **有（08:01 单点证据）** | Forever 专属查找组框真存在 ⇒ `Modules/Skins/Forever.lua` 那块皮肤从"候选"升级为"必验"（名字来自 Ellesmere，两客户端都没验过 —— §8.13.4 第 6 条）。"有"的会话口径见本节末尾订正 |
| `LegacySystemFrame` | **有（同上，会话相关）** | 同上（传承进度）。A 批复验那一趟它已经是 `0/6 全缺` —— 见本节末尾的口径订正 |
| `AeLootDisabled` | **生效** | 服务器关掉了组队拾取框架 → 拾取相关面板不归我们管，别去"修"（§8.13.4 差集第 ② 类） |
| `EncounterJournalDisabled` | **生效** | **`[encounterjournal] 0/8 缺失`不是名字写错，是整块面板被 GameRule 关了** —— AGENTS 那条"1.60 上框读不到的第一嫌疑人是 GameRule"首趟就命中。`/mui report` 的 `[dressDrop:encounterjournal] 跳过 1 个非框体条目：EncounterJournal` 是同一条的另一面（面板被禁时全局只剩 Mixin 表） |

其余前提一次性确认（1.60 实测）：`/run` 脚本通道**可用**、`UserScriptsDisabled` 未生效（但随时可能变，诊断照旧走 `/mui` 子命令）；
`MouseIsOver` / `GetMouseFocus` **无** ⇒ 三条 Watch 轮询是必须的，不是风格选择；
`PetActionBar_UpdateCooldowns` **无** ⇒ AGENTS 那条"用 `PetActionBar:UpdateCooldowns()` 自己驱动"在 1.60 同样成立；
`C_RestrictedActions` 3/3 齐、`Enum.AddOnRestrictionType` 6/6 齐 ⇒ `ns:IsRestricted()` 六类完整可用；
GameRule 18 条里 16 条未生效 ⇒ **§8.13.6 那句"这台服务器没关任何暴雪面板"在 1.60 上反过来**（有 2 条）。

**`/mui skins diagnose`：合计 245 存在 / 198 缺失 —— 这个数字首趟不能当缺陷账。**
按 §8.13.4 第 3 步，拍卖 / 收藏 / 专业 / 训练师 / 法术书 / 任务日志 / 检查 / 日历 / 宏 / 飞行图 / 幻化 / 打孔 /
订单 / 公会这一批窗**一扇都没开过**，整排 ✗ 是"面板还没出生"而不是"名字写错"；LoD 包（`Blizzard_Collections` 等）
同属这一类。⇒ 二趟必须先逐窗打开再跑，差集才可用于改名/摘名字。

**`/mui bags probe`（在杜隆塔尔，不在银行 NPC 前）**：主页候选 `-1:32 -2:0 -3:0`、随身包 `0:20 1:6`、
标签页 `6..14` **全 0**、`C_Bank(Character) 已购 0 / 上限 9 · 能用 true · 能看 true`、
`WarbandBankFrame ✗`（预期）、接管=false → 银行两套并存符合当前设计。
⇒ **#25 要的"银行主页索引语义"这一趟取不到**：不在银行 NPC 前、银行框没开，6..14 报 0 槽无法区分
"没买标签页"和"索引根本不映射"。这一条必须站着银行再跑一次。

**`/mui report` 聊天框只留前 15 行**（提示历史 112 行把后面的「美化台账」「同机插件」挤掉了）——
不是缺陷（账本全量在 `MonetUIDB.reportBundle`），但**读法要写死**：想看后两段用 `/mui report full` 或直接读 SavedVariables。

**`/mui restrict` 一趟干净**：六类限制全部"账本空 / 实时空"、`IsRestricted` 否、**轮询被暂停的框 = 0**
（上一轮那台 `ScrollFrame（无名）` 全程空转的毛病没有复现）。

**`/mui perf` 的耗时档在 1.60 上全是 0 —— 这条是仪表的锅，不是负载的功劳。**
`调度器：在册 3 · 累计调用 18083 · 累计耗时 0 · 失败 0`，逐路也全是 `累计 0.000s · 峰值 0.000s`。
根因 `Utils/Scheduler.lua:53` 的注释自己写了：`GetTime` 精度不够量一帧内的差值，所以这套数字**只配排序**，
而 1.60 实测连排序都排不出来（每个回调的耗时 < 一次 GetTime 的粒度 → 恒等 0）。
**仪表本身有解**：1.60 实测 `type(debugprofilestop) = function`、返回毫秒且带小数四位
（`83597232.4398` ≈ 23 小时开机），换成它就能逐路归因。⇒ 记成待办，**开服日不动调度器**（改动落在每拍热路径上）。

## 8.35 2026-11-05 皮肤死名 → 1.60 实名账（A 批，作者问"现在修还是等后面一起"→ 现在修）

**判据口径**：每条改动都要两样东西 —— ① 实机 `/mui compat find <片段>`（走 ~19800 个框，`EnumerateFrames` + 逐层 `GetChildren`）
给的**实名清单**；② 离线 `framexml-source`（1.60.1.70707）里那个包的 `.toc` 门控（`AllowLoadGameType` / `[ExcludeLoadGameType camelot]`）
说明**为什么是这个名字**。只有其中一样，就写"待实机"，不改代码（§8.13.4 差集第 ③ 类不许靠记忆）。

| 面板 | 死名（1.60 实测不存在） | 实名 / 新做法 |
|---|---|---|
| character | `CharacterFrameTab1/2/3` | `CharacterFrameTabIndicators`（+ `…LeftTabButton` / `…RightTabButton`，都是容器子件）⇒ 只点容器名，整棵子树 `deep` 扫。**后果说清楚**：这三行一直是空枪，角色页签从收口起没被涂过 |
| friends | `FriendsFrameTab2/Tab5`、`FriendsFrameAddIgnoreButton`、`FriendsFrameBroadcastButton`、`FriendsFrameListScrollFrame` | 页签只有 **1 / 3 / 4**；按钮剩 `SendMessage` / `AddFriend`；列表是 `parentKey="ScrollBox"`(WowScrollBoxList) + `parentKey="ScrollBar"`(MinimalScrollBar) 的**无名子件** ⇒ 滚动区交给 `deep`，死名从名单里摘掉 |
| who | `WhoFrame`、`WhoFrameWhoButton/AddFriendButton/GroupInviteButton`、`WhoListScrollFrame` | 独立查询窗在 1.60 已折进好友第 4 页，全客户端只剩 `WhoFrameEditBox` + `…ClearButton` 两个实名 ⇒ 只涂这两只 |
| （新增） | —— | **`SocialUIFrame`**：1.60 把好友/公会/社区/黑名单合并进它（`Blizzard_SocialUI/Mainline/SocialUI.xml:3` 继承 `PortraitFrameTemplate`；实机有 `SocialUIFrame` + `…CloseButton` + `…Inset`），而我们**一个字节都没涂** ⇒ 两扇窗都 Dress（`FriendsFrame` 同名也还在，哪扇被 O 打开取决于玩家设置） |
| micromenu（皮肤） | `SocialsMicroButton`、`PVPMicroButton` | 全客户端微按钮一共 17 个命中：Character/Profession/PlayerSpells/Achievement/QuestLog/Guild/LFD/Collections/EJ/Store/MainMenu/Help/Housing/Spellbook/Talent/Legacy + 容器 `MicroButtonAndBagsBar` |
| micromenu（模块入口） | `BagMicroButton`、`MapMicroButton`、`CalendarMicroButton`、`GJMicroButton` | 这几行以前**静默消失**（`TargetButtonFor` 取不到 ⇒ 行不建）。现在：背包 → `ns:GetModule("Bags"):Toggle(true)`（我们自己的窗）；地图 → `C_Map.OpenWorldMap`（文档标 **[受限]** ⇒ 前置 `ns:IsRestricted()`）；日历 → 没有合法出口，**继续不建这一行**（宁缺一行，不调 `ToggleCalendar`） |
| quest（人物/任务文本） | `QuestDetailText` 等 7 条 `[_]` 名 | **A 批没动**：这 7 条要开着任务窗才能扫实名，属 B 批（下一段） |

**同批清掉的设计债**：`MicroMenu.lua` 的 ENTRIES 里那六个 `action = function() … _G.ToggleXxx() … end` 字段
在 `4a458d1`（P0 修）之后**已经不再是任何路径**（`SafeActionFor` 只认 `luaAction`），但字段还挂在表上 ——
读代码的人会以为"按钮不在还有兜底"，而那条兜底正是弹「界面行为失效」的写法。字段连同文件头那句
"动作优先直接调按钮自己的 OnClick" 一起删掉。

**新闸门**：`node tools/micromenu-entries-probe.js`（12 项）钉住这一类缺陷不再回来：A 组 = 安全转发三件套 +
`GetScript` 全文零出现 + 15 个暴雪 Lua 全局零调用；B 组 = 六颗死名不得回到源码、十三颗实名不得漏；
C 组 = `target` 与 `luaAction` 互斥、两者都无 ⇒ 不建行、[受限] API 前面必须有 `ns:IsRestricted()` 门。
**为什么不能拿 `run.js red=0` 当这条的证据**：`grep MicroMenu tools/harness/run.lua` = 0 命中，harness 根本不派微菜单阶段（A 批的 friends/character 那几路**是**被 `Skins:ApplyAll` 驱动的， micromenu 那一路只由这条探针 + 实机覆盖）。

**A 批台账复验（作者重载后 `/mui skins diagnose`）—— 三组 ✗ 行整行消失**，都变成"对象存在，其中 0 个不是框体"的 ⚠：

| 组 | 复验前 | 复验后 |
|---|---|---|
| `[character]` | 5 存在 / **3 缺失** | **6 存在 / 0 缺失**（页签改走 `CharacterFrameTabIndicators` 之后本体可取） |
| `[friends]` | 6 存在 / **10 缺失** | **9 存在 / 0 缺失**（死名摘掉，`SocialUIFrame` + `WhoFrameEditBox` 进账） |
| `[micromenu]` | 19 存在 / **2 缺失** | **19 存在 / 0 缺失**（只剩 `UpdateMicroButtons` 那条"命中但不是框体"的 ⚠ —— 它本来就不是框） |

`/mui skins diagnose bad` 全仓只剩三条非框体命中（`UpdateMicroButtons` / `SharedTooltip_SetBackdropStyle` /
`TradePlayerInputMoneyFrame`），都是记账用的函数或 Mixin，没有一处被当 parent 交给 `CreateFrame`。
合计 `257 存在 / 200 缺失` → `253 存在 / 177 缺失`：**缺失 −23 是摘死名**，存在 −4 是 LoD 会话差异（下面那条口径）。

**口径订正（复验时发现，影响 §8.34 那张表的两行"有"）**：
`/mui compat` 的"暴雪框体 有/无"和 `/mui skins diagnose` 的 ✓/✗ **都是会话内的快照，不是永久事实** ——
LoD 包（`Blizzard_LegacySystem` / `Blizzard_Collections` / `Blizzard_AchievementUI` …）只在**本会话真开过那扇窗**之后
才把框建出来，`/reload` 之后又回到"无"。同一条 `LegacySystemFrame`：08:01 那趟报 **有**，
A 批复验那趟（重载后没开传承窗）在 `[legacy]` 里已经是 **0/6 全缺**。⇒ 以后写"某框 有"必须带
**"本会话（开过 X 窗）"**，只有 `UserScriptsDisabled` / GameRule 那一类是每次登录都在的。
`LFGParentFrame` 的"有"目前只有 08:01 一趟单点证据；`[lfg]` 那 24 个对象存在是名单里其它子件命中，
**不等于** parent 在这一刻存在 —— 二趟要单独看这一行。

## 8.36 2026-11-05 开服第 2 条 P0：信息栏"点一格开一个面板"把暴雪 Lua 面板链拉进我们的执行环境

作者按 A 批复验台账时，日志里先冒出来的是这一条（不是皮肤）。**完整栈（id 1441，1.60.1 build 70790）**：

```
TextStatusBar.lua:110 attempt to compare a secret number value (execution tainted by 'MonetUI')
 ← ShowStatusBarText ← CharacterFrame.lua:729 ← [Camelot]CharacterFrame.lua:25
 ← [C]:ShowUIPanel ← UIParentPanelManager.lua:900/335/498 ← SetUIPanel
 ← [C]:pcall
 ← MonetUI/Modules/InfoBar/InfoBar.lua:255 in function 'OpenPanel'
 ← MonetUI/Modules/InfoBar/Blocks.lua:78            ← 玩家点了一下金钱数字
```

**根因一句话**：`M:OpenPanel(globalName)` 按名字取**暴雪的 FrameXML 全局**（`ToggleCharacter` /
`ToggleTalentFrame` / `ToggleFriends` / `ToggleQuestLog`）再 `pcall` 调用它。这和微菜单那条 P0
（`4a458d1`）**同型**，只是换了一个模块——AGENTS 已经写了"暴雪 Lua 全局一律不碰"，我修微菜单时
只改了那一处，没有把同一条禁令扫遍全仓（`grep -rn "OpenPanel"` 当时不在我的清单上）。
后面 8 条 `ADDON_ACTION_BLOCKED MonetUI UNKNOWN()`（id 1502/1512，`/mui blocks` 账本为空）
**高度可疑是同一条脏链的下游**（机密值测试以我们的名义被拦），但这条要复验后才能算结论。

**修法（和安全按钮那一套完全一致）**：`secureClick = <暴雪那颗微按钮的实名>`，格子内造一层
`SecureActionButtonTemplate` 接住器，`type="click"` + `click=那颗按钮`，由客户端在受限环境里代点。
四个目标全部有实名证据（§8.35 的 17 个命中）：金钱格 / 耐久格 → `CharacterMicroButton`、
专精格 → `TalentMicroButton`、好友格 → `GuildMicroButton`、任务格 → `QuestLogMicroButton`。
`M:OpenPanel` 整个函数删除（留着就是"通用入口"，下一个人一定用它）。

**第一版又踩了一个新坑，而且是 harness 抓的（66 条红）**：我直接把**格子本体**做成
`SecureActionButtonTemplate`。结果 `Relayout` 每拍在格子上 `ClearAllPoints/SetPoint`
（`InfoBar.lua:287`）变成"对安全框做受保护布局写入"，`restricted:Combat` ×10 + `restricted:Encounter` ×56。
⇒ 正解是**两层**：格子本体保持普通 `BackdropTemplate`（布局随便写），上面盖一层安全接住器，
只在造框那一刻 `SetAllPoints(frame)` 一次，之后排版不再碰它。**顺带的第二个坑**：接住器压住格子以后
鼠标归它，`OnEnter/OnLeave` 再挂本体就永远不触发（提示框会整个消失）⇒ 悬停挂到真正收鼠标的那一层。

**这两条都是"离线闸门这次真驱动到了"的样本**（对照 §8.35 那条"harness 不派微菜单阶段"）：
信息栏在 harness 里有 `alpha[restricted:*]` 阶段，所以改错了当场红。新增闸门
`node tools/infobar-secure-click-probe.js`（14 项）钉三组：A = `OpenPanel` 不存在 +
两个文件里 12 个暴雪 Lua 全局零出现；B = 本体必须普通框 / 接住器一次 `SetAllPoints` /
有目标时不挂我们自己的 `OnClick` / 悬停挂在收鼠标的那层；C = 五个目标都在 1.60 实名集合里，
且查找过 `Skin:Need`（缺席 ⇒ 账本一行 ✗，不是静默）。

## 8.37 2026-11-05 §8.36 的修法**在真机上也不成立**：锚定家族把信息栏整条标成受保护

作者重载后点了金钱 / 耐久 / 好友 / 任务四格（专精格 2 级还没开放，点不了）。两件事同时发生：

- **好了**：`TextStatusBar.lua:110 … tainted by 'MonetUI'` 一条都没有（`logs ERR` 在该窗口内零新增），
  `/mui blocks` 账本仍为空 ⇒ §8.36 那条 P0 的根因（调暴雪 Lua 全局）确实被堵住。
- **坏了**：紧随其后是一整批 `ADDON_ACTION_BLOCKED MonetUI Button:ClearAllPoints() / :SetPoint() /
  :SetWidth() / :SetShown()`，**每 10 秒 60–120 条**，持续十几分钟不停。

**归因（不靠猜，三条实测）**：
① `/mui restrict` → `当前受限：无`，`/run` 现场再问 `InCombatLockdown()` → `false` ⇒ **不是战斗/受限窗口拒的**，
`ns:IsRestricted()` 这类守门对这种拒绝完全无效；
② `Frame:IsProtected()` 现场读 → `MonetUIInfoBar=true`（同批 `MonetUIBar1=true` 是动作条安全模板，本来就该是）
⇒ 我们那条**普通**信息栏被标成受保护了，唯一的变化就是格子上多了个 `SetAllPoints(frame)` 的安全接住器
—— **锚定家族把格子连同父链一起传染成受保护**；
③ 被拒的四个方法正好对上信息栏排版三件套（`SetText`→`SetWidth`、`Relayout`→`ClearAllPoints`/`SetPoint`、
分隔线→`SetShown`），且日志里是匿名的 `Button`（格子没有名字）⇒ 是信息栏的格子，不是别的模块。
（**已订正，见 §8.38 末尾**：当时 `taintLog` 已被我关回 0，所以文件里没有这一批；开采集时 1.60 会写）
和 AGENTS 里那条旧记录一致），所以拿不到栈，只能这样三角定位。

**处置**：信息栏回到"格子本体 = 普通 `BackdropTemplate`、没有安全接住器、`secureClick` 字段整个撤掉"，
"点一格开暴雪面板"这个动作**今天下线**（任务 **#43**）。数字、悬停提示、属性面板（我们自己的窗）都不受影响。
教训已升格成 AGENTS 一条：**安全模板控件不能锚到"之后还要排版"的框上**（被拒那一拍的归属见 taint.log 原文，判据用 `IsProtected()` + `GetNumPoints()` 两个数）。

**闸门改口**（`tools/infobar-secure-click-probe.js`，10 项）：B 组现在钉的是"这里不许再出现
`SecureActionButtonTemplate` / `SetAllPoints(frame)` / `secureClick` 字段"，C 组钉
"唯一的 `onClick` 只能开我们自己的属性面板 + `/mui infobar diagnose` 名单里不再列那四颗微按钮（没有取用路径 = 假账）"。
两次失败的写法都写进探针头注，免得下一个人把第三次当"改进"。

**同型风险（还没测到，必须测）**：`Modules/Minimap/MicroMenu.lua` 的微菜单行是
`SecureActionButtonTemplate` + `row:SetPoint(..., frame, ...)`，而 `frame:SetHeight()`（`:148`）和
`frame:SetPoint()`（`:197/199`）**每次打开都会写** ⇒ 理论上和 §8.37 同一个坑。
这一趟 `MonetUIMinimapMicroMenu` 还是"缺席"（菜单没被打开过，`Build` 是懒的），**没有实测证据**。
⇒ 复验动作：`/reload` 后展开一次微菜单，我立刻读 `logs BLOCKED` + 现场读 `IsProtected()`。
如果确认被传染，退路是把那几行也回成普通按钮并接受"微菜单不代点暴雪面板"（**不再赌**）。

## 8.38 2026-11-05 微菜单同型确认：安全模板把面板传染成受保护，而且是**静默**失败

作者报「右键小地图展不开，没有出菜单」。新命令 `/mui minimap menu` 的实机读数（1.60.1 · 70790）：

```
微菜单：15 个入口定义 · 可安全转发 13 · 纯 C_* 动作 2 · 建不出行 无
面板：已建 · 受保护=true · 行 15 颗（其中受保护 13）· 高度 269.0 · 当前 shown=false
设置 microMenu=true ⇒ 右键会走到这里
```

现场再读一次（`/run` 只读取数）：`points=0 · rect 读不出 · strata=DIALOG · shown=false`。

**三条判读；① 当场被我推翻，先把推翻写清楚，免得下一个人照 ① 去查命中区**：

① ~~「右键事件进到了我们这里」~~ —— **错，公开收回**。判据原本是「读数里写着『面板：已建』，而只有
   `Build()` 会留下它」；但我自己的 `Probe` 里就写着 `if not frame then Build() end` ⇒「已建」很可能
   只是我这次读数造的。而 `Build()` **不设锚点**（锚点由 `Toggle` 设），撤回安全模板之后（`/reload` ×2
   实测 `受保护=false`、3 行 0 颗受保护）**`GetNumPoints()` 仍然是 0** ⇒ 真正的事实是 **`Toggle` 一次都没跑到**，
   右键根本没落进我们的处理函数 ⇒ 本次「展不开」的原因还没找到（下一趟判据：光标悬在小地图上时用
   `EnumerateFrames` 列出压在遮罩之上的框，看谁吃了这次点击）。
   ⇒ **探针纪律加一条：诊断命令不许产生它正在判定的状态**（Probe 造面板 = 污染自己的判据）。

**仍然成立的两条（但都不是本次「展不开」的解释）**：
② 面板被 13 行 `SecureActionButtonTemplate` 所在的**锚定家族传染**成受保护
⇒ 之后我们对它做 `SetPoint/SetHeight` 就会被丢（信息栏 §8.37 是同一机制，那一例会记日志）。
（本例的 `GetNumPoints()=0` 来自 `Toggle` 压根没跑，不能拿来当「写入被吞」的证据）
③ 这一批当时在聊天框与 logs 游标里都看不到 `ADDON_ACTION_BLOCKED` 的采集条目，**原因是我把 `taintLog` 关回了 0**
（不是这台机器不记）。订正后的口径见本节末尾与 §8.37；判据仍然是那两个数：
**`Frame:IsProtected()` + `Frame:GetNumPoints()`** —— 所以在实机问「展不开」之前先跑那条命令，不要去猜命中区。

**taint.log 口径订正（同一小时内第二次自纠，作者贴出的条目逼出来的）**：作者 10:26 贴的那段
「Message: / Time: / Count: / Stack: / Locals:」是 **taint.log 的条目格式**，说明这台机器**会写**这个文件；
回头读 `Logs/taint.log`：08:51 那一批（信息栏锚定家族那次）确实在里面，915 KB / 11818 行，原文是
「**An action was blocked in combat because of taint from MonetUI - Button:ClearAllPoints()**」+ 我们的完整栈
（`InfoBar.lua:287 Relayout` → `Blocks.lua:294`）。⇒ 三条后果：
① §8.37 那句「这台机器对 BLOCKED 零记录」**作废**，真实原因是我读完就把 `taintLog` 关回 0；
② §8.37 那句「与战斗无关」也**作废** —— 日志原文写的是 `in combat`，我读到的 `当前受限：无` 是**事后**那一拍，
   不能倒推被拒那一拍（这条尤其重要：它意味着当时确有受限窗口在生效，`ns:IsRestricted()` 的读法本身没错，
   错在我拿一个时刻的读数去否定另一个时刻的事件）；
③ 10:26 那串 `ActionButton.lua:891 SetCooldown … untainted execution` 现在**还没有归属**
   （它发生在 taint.log 停止写入之后；栈里只有 `Blizzard_ActionBar` 的帧，聊天框同时把一批 BLOCKED 记给了
   同机的 `DungeonsForeverSpell`），已重新开 `taintLog=2` 采集，等它再发生时用文件判。
⇒ **AGENTS 已改**：`taint.log` 那条「12.1.5 实测零记录」降级成「仅在那台客户端 + 开关关闭的条件下观测到」，
   并写进规矩：**报「某类日志不存在」之前，必须先确认采集开关的状态**。

**处置**：微菜单入口只剩有纯 `C_*` 开口的三行 —— 背包（我们自己的 `Bags:Toggle`）、
地图（`C_Map.OpenWorldMap`，[受限] ⇒ `ns:IsRestricted()` 前置）、设置（`Settings.OpenToCategory`）。
`SecureActionButtonTemplate` / `SetAttribute` / `TargetButtonFor` 在本文件里**整体不存在**，
`buttons =` 名单也删掉。代价写进代码注释：**角色/法术/任务/成就/好友/收藏/副本/职业/寻找组/住房/商店/帮助
这 12 行本客户端没有 C 侧开窗 API**（`docs/api` 快照里 `Open` 动词只有
`C_Map.OpenWorldMap` / `C_Calendar.OpenCalendar` / `C_TradeSkillUI.OpenTradeSkill` /
`C_SettingsUtil.OpenSettingsPanel`），而调暴雪 Lua 全局是被禁止的 P0 写法 ⇒ 走 **#43** 找独立安全载体。

**闸门**：`tools/micromenu-entries-probe.js` 重写（13 项）。A 组现在钉的是"这里一个 `GetScript` /
一个 `SecureActionButtonTemplate` / 一个 `SetAttribute` 都不许出现"，B 组钉"入口 ≤6 行、每行自带
`luaAction`、没有 `buttons =` 名单"，C 组钉"判据命令在位且读 `GetNumPoints`"。
三次失败（抠脚本自调 / 本体做安全框 / 接住器传染）都写进探针头注。
**harness 不派微菜单阶段** ⇒ 这条路径的证据只有探针 + `/mui minimap menu` 实机读数两样。

## 8.39 2026-11-05 §8.38 那个洞补上了：遮罩被同机收纳器搬走，命中区塌成 0×0（零报错）

作者报障后我按 §8.38 里定的下一步做了一次**悬停读数**（光标放在小地图上、不点）：

```
EnumerateFrames 扫 15908 个框，那个点上命中的 27 个里只有两个 M（收鼠标）：
  19) Minimap @LOW/2 M          ← 暴雪的地图本体
  （MonetUIMinimapOverlay 根本不在清单里）
矩形实测：
  MonetUIMinimapOverlay  [0,0 0x0]      shown=true  parent=RurutiaSuiteMinimapCollector
  Minimap                [1842,0 256x256]           parent=MonetUIMinimapHolder
  MonetUIMinimapHolder   [0,0 0x0]
  MonetUIMinimapPanel    [1840,31 260x194]
```

**真因**（读 `RurutiaSuite/Modules/MinimapCollector/Core.lua` 实证，只读）：它按 `_G.Minimap` 的
**子树**递归遍历（`Core.lua:169-171`），逐个过白名单 `Adapter:CanCollect`（`:373`），
命中的就 `SetParent(panel)` + `SetSize/SetScale` + `ClearAllPoints` + 重新锚到自己的面板（`:390/404`）。
我们的遮罩因为正是 `Minimap` 的孩子 ⇒ 被当成"一个没认出来的小地图按钮"收走了，
于是命中区塌成 **0×0 在屏幕原点**：右键微型菜单、滚轮缩放、悬停区域名**三条一起哑**，
而且当时聊天框与 logs 游标里看不到条目（**因为 `taintLog` 被我关回 0**，不是这台机器不记 —— 见 §8.38 订正）。

**修法（作者选 A）**：`Modules/Minimap/Minimap.lua` 的 `EnsureBlocker` ——
遮罩父级从 `minimap` 改成**我们自己的 `holder`**，锚点照旧相对 `minimap`
（跨父锚定对普通框没限制，几何完全等价）；它按 Minimap 子树遍历，我们从此不在候选里 = **一次搬家永久躲开，不拉锯**。
另加一行兜底：每次排版比一次 `blocker:GetParent() ~= parent`，不对就 `SetParent` 拉回来
（正常路径只是一次比较）。AGENTS 同步加一条硬规矩 + **报障判据两件套**
（`EnumerateFrames` 列不到我们的遮罩 → 命中区不在那儿；`GetParent():GetName()` 是别人的框 → 被搬走了），
因为这类问题**不产生红字**，看日志会得出"没问题"的错误结论。

## 8.40 2026-11-05 B 批：逐窗开过之后的 176 条缺失，分诊成三档（#41 的输入）

**口径**：改代码要两样齐 —— ① 实机 `/mui compat find <片段>` 给的实名；② `/mui skins diagnose` 在**那个窗真开过**之后仍然报 ✗。
只有其中一样 = 不动。
（今晚我还试过用离线 `framexml-source` 按 game-type 分桶来批量定性，**那个脚本判错了**：
桶的正则不认 Windows 反斜杠路径，`Camelot/` 与 `Mainline/` 全落进同一个桶，于是"加载面有"只剩 8 条、
`QuestLogFrame` 这类"只在另一个变体里"的名字被归成"全无"。临时文件 `dead-audit.js` / `dead-audit2.txt` 已删，
**不进仓、不当证据** —— 这类"跑得出数但桶分错了"的仪表比没有仪表更危险，见 `feedback-green-gates-must-cover-the-path`。）

**总数**：`277 存在 / 176 缺失`（开窗前 253/177；开窗带出 +24 存在）。

### ① 今晚就扫到实名 ⇒ 可以改名（8 条，三组）

| 组 | 我们的死名 | 1.60 实名（`/mui compat find` 原文） |
|---|---|---|
| questlog | `QuestLogFrame` + `QuestLogDetailFrame` / `…DetailScrollFrame` / `FrameAbandonButton` / `FrameCancelButton` / `FrameTrackButton` / `FrameShareButton` / `QuestLogListScrollFrame`（12 条里 8 条有对应） | **`QuestLogPopupDetailFrame`** 一族：`…FrameAbandonButton` / `…FrameCloseButton` / `…FrameInset` / `…FrameScrollFrame` / `…FrameShareButton` / `…FrameTrackButton`（走 19040 个框，全 UI 只有这 9 个含 questlog） |
| playerspells | `PlayerSpellsCloseButton`、`PlayerSpellsSearchBox`、`PlayerSpellsTab1..4` | `PlayerSpellsFrame`、**`PlayerSpellsFrameCloseButton`**、**`PlayerSpellsFrameClearButton`**（+ `PlayerSpellsMicroButton`）。`SpellBookFrame` 不存在（只有 `SpellbookMicroButton`）⇒ 这组的页签/搜索框属 ② |
| chat | `ChatFrame1..4ScrollFrame`（4 条） | 全 UI 含 `chatframe1` 的 18 个实名里**没有** `…ScrollFrame`：聊天滚动条是运行期 `ScrollBar` 子件 ⇒ 正确动作是**摘掉点名**（面板已 `deep = true`，控件本来就被涂到了），不是改名 |

### ② 架构档：那些控件在 1.60 根本没有全局名（约 90 条）⇒ 摘点名，不改名

共同证据：`/mui compat find` 扫过、实名不存在，而窗口本体存在；控件是 `ScrollBox`(WowScrollBoxList) +
`MinimalScrollBar` + `TabSystem` 这类**运行期子件**或 `parentKey`。今晚已经用过两次这个模式并且见效：
`CharacterFrameTabIndicators`（改成只点容器 + 深扫）与 friends（摘 5 条点名 + `SocialUIFrame` 深扫），
两组台账都从 ✗ 变成"0 缺失"。

| 组 | 条数 | 1.60 的真实形态 |
|---|---|---|
| editmode 各对话框按钮 | 10 | 按钮是对话框框体的 `parentKey` 子件，无全局名 |
| collections 筛选/搜索/第 6 页签 | 9 | `TabSystemTemplate` + 无名 `SearchEditBox`；`CampsitesJournal` 本客户端无 |
| guild 名册滚动 ×9 | 9 | 名册在 `SocialUIFrame` 内，`GuildFrame` 整个不存在（实名只有 `GuildControlUI*`、`Communities*`） |
| questframe / gossip 文本与按钮 | 12+8 | `QuestDetailText` 一类是 `FontString`（不是框），`GossipGreetingButton1..8` 是运行期建的 |
| mail 翻页/滚动/按钮 | 8 | 现代邮箱用 `MailFrame` 内的 `ScrollBox`，无 `MailListScrollFrame`/翻页键 |
| achievements 容器/筛选/搜索 | 4 | `AchievementFrame` 存在，子件走 `TabSystem`/`HyperText` |
| merchant / loot | 4 / 4 | 需要 NPC 与真实掉落才能判，暂列 ③ 也可以（商人那四个键 1.60 改名成 `MerchantFrame` 的 parentKey） |
| colorpicker | 4 | 取色窗的 okay/cancel 只有开窗后才建；`/mui compat find ColorPicker` 只回 `ColorPickerFrame` + `ColorPickerSoftCursor` ⇒ 待开取色窗再判 |
| legacy 两页 / macros 两编辑框 / flightmap / addonlist | 2/2/2/6 | 都是 `parentKey` 或共用控件名（`FlightMapFrame.CloseButton` ⇒ 该写点路径 `FlightMapFrame.CloseButton`，我们已经支持点路径） |

⇒ **这一档的动作 = 从面板 `frames` 名单里摘掉点名**（保留窗口名与 `Window.Key` 点路径），
让台账从 176 降到能真正指导改动的量级；摘的时候逐组确认 `deep = true` 覆盖到了控件，
否则就是丢覆盖（AGENTS：名单里有名字而代码没取用路径 = 缺陷，反之"有路径但名字不存在"是噪声）。

### ③ 还不能判：窗口/包根本没加载过（34 条）

`auction`(17) / `trainer`(4) / `inspect`(6) / `socket`(3) / `transmog`(2) / `craftorders`(2) / `calendar`(3) ——
父框 `0 存在`，LoD 没载或本等级用不到（2 级号开不了拍卖/训练师/打孔/幻化）。
`bank` 的 `WarbandBankFrame` 是**预期不存在**（§8.34 已记），不算缺失。

## 8.41 2026-11-05 B 批落地（作者选 B = ①改名 + ②摘噪一起做）

**结果**：`M:Panel frames` 名单 **374 → 283 个名字**（-91），`/mui skins diagnose` 那些"永远消不掉的 ✗"
从根上少掉一截；harness 台账同步收窄（`info 1695 → 1609`、去重键 `493 → 407`）—— 这两个数字就是
"少做了 91 次注定落空的查找"的证据，而不是"我删了东西所以看起来干净"。

**① 改实名（有 `/mui compat find` 原文）**

| 组 | 改动 |
|---|---|
| questlog | 窗口 `QuestLogFrame` → **`QuestLogPopupDetailFrame`**（+ `deep`），按钮三颗换成 `…FrameAbandonButton` / `…FrameShareButton` / `…FrameTrackButton`，滚动区 `…FrameScrollFrame` |
| playerspells | 只留 **`PlayerSpellsFrame`** + `PlayerSpellsFrameCloseButton` / `PlayerSpellsFrameClearButton`（`SpellBookFrame` 与四个页签、两个搜索框都没有实名） |
| legacy | **两行假 ✗ 其实是"一段从没跑过的代码"**：`RewardTrackPage` / `ChallengesPage` 是 `LegacySystemFrame` 的 parentKey（`Blizzard_LegacySystem.xml:40-41`），裸名 `Need` 永远拿不到 ⇒ `M:Controls` 循环一次都没执行过。改成点路径 `LegacySystemFrame.RewardTrackPage` / `.ChallengesPage`，并把漏掉的第三块 `.TreePage` 一起补上 |

**② 摘掉无实名证据的点名**（每组都在代码里写了理由 + §8.40 的档位）：collections 筛选 5 + 搜索 2、
achievements 容器/筛选/搜索 4、macros 编辑区 2、mail 收件箱按钮 5 + 滚动区 3 拼法、merchant 3 颗 + 滚动区、
loot 翻页 2 + 滚动区 2 拼法、editmode 对话框按钮 10（两种拼法都是照参考件猜的）、
addonlist 6、guild 名册滚动 9 拼法、communities 页签 3、chat 滚动区 4、timemanager 旧全局名 1。
摘的同时把对应窗口补上 `deep = true`（loot / mail / merchant / gossip / editmode 对话框 / addonlist / professions），
**避免"摘名字 = 丢覆盖"** —— 这是 §8.40 ② 那条纪律的执行细节。

**跨客户端的取舍写死**：`GuildFrame` / `TradeSkillFrame` / `EncounterJournal` 这类"零售有、1.60 没有"的名字
**保留**（`_retail_` 还在作预验支），注释里写明"这一行 ✗ 在 1.60 属预期"。
不为一个客户端删另一个客户端的名字，也不许把它伪装成"已适配"。

**没做完的（③，要开窗/要 NPC 才能判）**：auction 17、trainer 4、inspect 6、socket 3、transmog 2、
craftorders 2、calendar 3、colorpicker 4（要开取色窗）、merchant/loot 的剩余项要真 NPC 与掉落。
`#41` 保持 pending，输入已换成"③ 那批 + 二趟开窗复验"。

**闸门**：luac 六文件 / `check-frame-list`（283 名全部有取用路径）/ `api-audit` 无 HARD /
`audit-taint` 0-0-0 / `audit-locals` / 七条行为探针 / `harness red=0`。
待实机：作者 `/reload` 后重跑 `/mui skins diagnose`，看任务详情窗、技能书面板、传承三页是否真的被涂到
（legacy 那一处是**第一次**被执行到，观感变化最直接）。

## 8.42 2026-11-05 10:26 那串 `SetCooldown` 报错的归属：**不是我们**（taint.log 全量统计）

作者贴出的那条（`ActionButton.lua:891 bad argument #1 to 'SetCooldown' … Secret values are only allowed
during untainted execution`，Count 21）发生在 `taint.log` 停止写入之后，所以先重开采集（`taintLog=2`）再统计。
`_forever_/Logs/taint.log` 今天 10:00 之后的归属分布：

| 归属 | 条数 |
|---|---|
| `tainted by RurutiaSuite` | **3898** |
| `tainted by TweaksForever` | 3 |
| `tainted by OpenMap` | 2 |
| 10:2x 之后栈里出现 `MonetUI` 的行 | **0** |

典型一条（10:31:03）完整链：`ChannelFrame:ToggleVoiceSettings → SettingsPanel:Open → LoadAddOn →
RurutiaSuite/Core/Runtime/Events.lua:38 → …MerchantExpansion.lua:633 OnMerchantUpdate →
MerchantFrame.lua:406`，客户端写的是「Execution tainted by **RurutiaSuite** while reading global
MerchantItem19MoneyFrame」—— 它 hook 了暴雪的 `OnMerchantUpdate`（正是 §8.33 负面清单里那条），
于是商人格子的整段更新以它的名义执行；`SetCooldown` 那一串同一来源。
**`DungeonsForeverSpell MainActionBar:SetPointBase()` 那批 BLOCKED 也是别家**（聊天框自己就把名字写出来了）。

**这条对发布的意义**：开服日玩家报"技能冷却不转 / 界面行为失效"时，真凶大概率是同机的 QoL 套件。
所以 #20/#28 那件事现在有硬内容可做：`/mui report` 增加一行"**谁在动受保护框**"
（读同一份 `taint.log` 或现场 `issecurevariable`，只读、不碰别人的框），让玩家和都能自己看见归属，
而不是把账算到 MonetUI 头上。等作者点头再做，不塞进今天的收尾。

## 8.43 2026-11-05 子帧探测第一批产出（探针修好之后才有的三类结论）

**用法**：`/mui skins layers <窗口名> [片段]` —— 片段过滤走 `label + 图集 + 状态` 的拼接键，
所以 `scrollbar` / `id:` / `metal` 这类都能当"按家族切片"用，不需要新参数。

**① 新式滚动条的"轨"是空白（已修，`6f3cd41`）**：`QuestFrame` 过滤 `scrollbar` 数出
`minimal-scrollbar-track ×3 + minimal-scrollbar-arrow ×2`。把手和步进钮早已有
`Skin:ScrollThumb` / `Skin:Stepper` / `Skin:ScrollArrowButton`，唯独 `Track.Begin/End/Middle`
三张 atlas 没人管 ⇒ 暴雪 8px 青蓝凹槽坐在我们的细线风里。补法见该提交（剥 atlas + 居中 1px
`monet_hairline` + 边框色 α0.35 + 悬停随把手一起提亮）。**离线绿不算证据**（桩框架有没有真造出
`.Track` 没验证），实机看家族计数是否掉下来。

**② 仪表口径修完才看清真实规模**：QuestFrame 的"还看得见"从虚高的 **300 → 69**
（168 件属于没显示的手柄/隐藏容器），SocialUIFrame **491 → 162**。之前那种数拿去做决定会一路做错。

**③ 剩下的两大类"要拍板"而不是"要修"**（我没自动动）：
- **列表行美术**：`friends-card-selected ×6 / friends-card-battlenet ×3 / friends-card-disabled ×3`、
  `common-button-tertiary ×14 / common-button-list ×8` —— 好友列表的行底与选中态是 atlas，
  换掉等于做一套"我们的行高亮"（设计取向：保留暴雪行底还是压成我们的 well）。
- **肖像**：探针看到的 `QuestFramePortrait RTPortrait1 62x62` 是**圆图本体**，不是椭圆遮罩 ⇒
  压成方形得换美术（方形框 + 我们的四角），不是 `SetTexCoord` 能解决的。
- ⚠ 顺手记一条**仪表边界**（我自己差点踩）：`/mui compat find` 只枚举**框**，
  所以它报"帧名含 frameportrait 只有 1 个"时，真实情况是 `QuestFramePortrait` / `SocialUIFramePortrait` /
  `CharacterFramePortrait` **都在**（现场 `type(_G[n..'Portrait'])` = table），只是它们是**贴图不是框**。
  ⇒ 判"某个名字不存在"之前，先说清这个工具看的是哪一层（贴图/字体要另走 `GetRegions`，就是 layers 探针）。

## 8.44 2026-11-05 子帧探测第二批：轨修好了，但**滚动条箭头是我们自己压掉又没补的**（缺陷，不是取向）

`/reload` 后同一对探针的复验：

- **轨（作者批准的 A 类）确认生效**：`QuestFrame` 过滤 `scrollbar` 的家族表从 `minimal-scrollbar-track ×3 + arrow ×2`
  变成 **只剩 `minimal-scrollbar-arrow ×2`**，三张 track atlas 全部 `α0.00 已剥掉`；
  `QuestFrame 看得见 69 → 64`。⇒ 那条"离线绿不算证据"现在有实机证据了。
- **箭头是新发现的自己的缺陷**：`/mui skins arrows` 全量 15306 框 / 命中 400 ——
  **`我们的箭头 0`**，而逐条写着 `键=minimal-scrollbar-arrow-top(up) · 无我们的图 · 暴雪层 α=0.00`
  （宿主：`QuestProgressScrollFrame`、`SocialUIFrame`）。
  ⇒ 暴雪的箭头图**被压成 α0 却没有放我们的 V 形上去**：滚动条上下箭头现在是"看不见但存在"的状态。
  最可能的链路（下一步验）：`deep` 扫的 `Skin:Strip(regions=true)` 直接压了步进钮的 region，
  而 `Skin:Stepper` / `Skin:ScrollArrowButton` 这两条"压图 + 补图"的正经路径**根本没被叫到**
  —— 它们才会 `Mark(button,'scrollArrow')` 并建我们自己的 chevron。
  这正是 AGENTS 里"FadeButtonArt 压掉却没有东西补上"那一族的第三种形态（前两种：Skin:Slider 漏 Strip、
  Stepper 误用 Strip）。
- **修法（下一步）**：① 让深扫在遇到 `Texture` 为 `minimal-scrollbar-arrow-*` 匿名步进钮时走
  `Skin:ScrollArrowButton`（它已支持"按 region atlas 认方向"）；② 或者在 `Skin:Strip` 里**别压这类 atlas**
  （把它列进"必须成对处理"的名单：压了就要求补图）。二者取其一，①更靠近现有代码；②
  更防未来。先看 `arrows` 探针在改动后 `我们的箭头` 是否从 0 变成 >0 —— 那就是这条的验收判据。
- **肖像（作者拍板：改方形 + 对齐到外框以内）待做**，注意实测：`QuestFramePortrait` /
  `SocialUIFramePortrait` / `CharacterFramePortrait` 都是**贴图不是框**（`/mui compat find` 看不见它们，
  见 §8.43 ③），所以取用只能靠全局名或 `frame.Portrait` 成员；圆图本体是 `RTPortrait1 62x62`，
  要方形得**裁贴图**（内接方框 `0.15..0.85`）而不是拉伸或换坐标。

## 8.45 2026-11-05 作者外出期间我接管客户端做的事（Computer Use 自己 /reload + 截图）

**做了什么**（每笔都是：改 → 闸门 → 双部署 → `sync-check` → 我自己 `/reload` → 复跑探针）：

1. `c1af78f` 肖像上收窗口档 `Skin:SquarePortrait`（裁内接方框 `0.15..0.85` + 只在真越界时按窗口矩形收回来），
   `M:SkinWindow` 一处调用（`noPortrait` 可关），角色窗那份本地实现删除 ⇒ 一个动作一个入口。
   取用走 `Skin:Need` 漏斗（不是 `_G`），缺席会是账本一行 ✗。
2. `e8c1e80` 箭头补图分流挪到 `Skin:Button` 入口 —— 上一笔的 `IsObjectType("Button")` 只修了一半：
   重载后复跑 `arrows` 仍是 0，现场读 7 只步进钮发现 **2 只 `marked=true` 且 region 已有我们的贴图**、
   5 只没标记 ⇒ 真因是**时机**（`ScanScrollArrows` 只在登录后 +1s/+4s 各扫一次，列表滚动条是懒建的）。
   入口分流后不依赖扫描时机。

**新发现的仪表缺陷（任务 #44，重要）**：`/mui skins arrows` 的"我们的箭头"计数**认不出我们自己的贴图**
—— 我们的 BLP 加载后 `GetTexture()` 返回**负数纹理 ID**（实测 `-1627`），而探针在找路径字符串里的
`monet_` 片段 ⇒ 明明补好了图却数成 0。这和 §8.38 那条是同族：**汇总继承分类器的口径，分类器瞎了整张表就骗人**。
⇒ 在 #44 修好之前，`arrows` 的"我们的箭头 0"**不能当证据**；判补没补要看 `Marked(button,'scrollArrow')`
或 region 纹理 ID 是否为负。

**截图核对到的（1355×767，1.60.1 · 70790）**：小地图方形面板、动作条 3 组、任务追踪条、聊天窗暗底、
右上信息栏都在位；`已加载 20/20 个模块`、`界面美化已启用（46 个窗口）`；
`logs ERR/BLOCKED` 自 2420 起**零条**（聊天框里那几行红是战斗日志文本，不是报错）。

**我没做完 / 需要他回来一起看的**：
- 肖像方形的**观感**：重载会把窗都关掉，我按 `J` 开出来的是"回收物品"窗（不是任务日志），
  已 Escape 关掉并停止盲点 UI ⇒ 肖像需要开着角色/任务窗截图才判得了。
- 箭头补图后的实际观感（V 形是否出现、位置是否居中）同样需要一扇带滚动条的窗。
- `friends-card-*` / `common-button-*`（社交窗列表行底 162 件里的主要家族）还没动。

## 8.46 2026-11-05 我独立跑完的那一趟：肖像与箭头都有数了（含 Computer Use 的输入边界）

**先记一条工具事实（下次别再试鼠标）**：这个客户端**忽略注入的鼠标事件** —— 点 wuxian 重载确认框的
"允许重载 / 取消"两次都没生效（`logs` 自 2495 起零条新输出 ⇒ 确实没重载），点小地图也没开世界地图；
而**键盘注入是通的**：`Return → 打字 /reload → Return` 直接成功，`i` 开角色面板也成功。
⇒ 重载走键盘，别去点确认框；需要点具体控件的活（银行 NPC、频道弹窗）留给玩家手。

**肖像（作者指令：改方形 + 对齐到外框以内）—— 实测通过**：
`/reload` 后开角色窗，现场读数
`frame L16.0 top1084.0` vs `portrait L20.0 top1080.0 62x62`、
`texcoord = 0.15,0.15,0.15,0.85,0.85,0.15,0.85,0.85` ⇒ 裁到内接方框 ✓、左右各内缩 4 ✓、正方 ✓。
但**同一组数在上一笔之前是** `texcoord=0..1`、`L11 / top1091`（左溢 5、顶溢 7）而 `Marked(por,'portraitSquared')=true`
⇒ 一次性裁会被暴雪 Show 时的 `SetPortraitTexture` 重置回去（`43a9fe8` 改成 `Widget:ShowWatch` 每次显示重涂）。
`bc494c2` 又把它从"所有窗口自动"改成"按面板点名"：自动版让 harness 的"读了但这个世界里没有的名字"
从 2118 warn 冲到 **3702** —— 46 扇窗里绝大多数没有 `XxxPortrait`，我自己把今天削掉的噪声造回来了。

**箭头（#44 的真相）—— 实测通过**：现场数（不靠那个瞎掉的计数器）：
**步进钮总数 236 · 已补我们的 V 形 226 · 未补 10**（那 10 只在从未被扫到/没开过的窗里）。
对照修之前：`ScanScrollArrows` 只在登录后 +1s/+4s 扫，而列表滚动条懒建 ⇒ 晚出现的箭头只被
`Skin:Button` 的 `FadeButtonArt` 压掉、没人补图。`e8c1e80` 把分流放到 `Skin:Button` 入口后成对处理。
⇒ `#44` 仍然开着：`/mui skins arrows` 的"我们的箭头"计数认不出我们的贴图（BLP 加载后
`GetTexture()` 返回负数 ID，实测 `-1627`），所以它报 0 时**不能当证据** —— 这一条差点让我以为修复失败。

**这趟的日志状态**：`已加载 20/20 个模块`、`界面美化已启用（46 个窗口）`，`logs ERR/BLOCKED` 全程零新增。

## 8.47 2026-11-05 箭头这一族追到第四层，还剩一层没通（#45）

一天之内同一个症状（"箭头看不见"）拆出**四个独立成因**，每个都是实机读数逼出来的：

1. `ScanScrollArrows` 只在登录后 +1s/+4s 扫，而列表滚动条**懒建** ⇒ 晚出现的箭头没人管（`e8c1e80` 把分流放进 `Skin:Button` 入口）。
2. 类型精确比较 `GetObjectType() == "Button"` 漏掉 **`EventButton`** ⇒ 扫描与两条探针都看不见它们（`e83e573`，含 `FindAnonClose` 那处**真换肤缺口**）。
3. 探针认不出我们的贴图：我们的箭头是 BLP，`GetTexture()` 回**数字 ID**（实测 -1627），`ReadPath` 只认字符串 ⇒
   "我们的箭头 0"是假数（`b5094da` 前后修好，判据改成"路径命中 或 `Marked(reg,'art')`"）。
   修完立刻见到真数：**命中 400 · 我们的箭头 142 · 已压 0 376**。
4. 方向键的存法有两种：Lua 字段 `button.upTexture` 与**安全属性** `GetAttribute("upTexture")`
   （`CharacterStatsPaneScrollBox` / `ChatFrame1` 那批只存属性）⇒ `9f4c196` 补了第二条腿。

**还剩一层没通（#45，已开任务）**：补完第 4 条腿再跑，那批仍然是
`无我们的图 · 原层 α=0.00` ⇒ 说明 `Skin:Button` 入口**根本没被调用到它们**（不在任何被扫子树里），
而把 α 压成 0 的是别的路径（最可能是对滚动条父框的 `Strip` 级联）。
下一步三条：① 读这些按钮的父链，确认它们挂在我们扫过的哪个框下面；② 在 `Strip`/`Fade` 里临时记一次
`debugstack` 到账本，跑一遍找出确切调用点再摘掉；③ 大概率正解 = 让 `Skin:ScrollBar` 直接按**属性**认方向，
不依赖字段，也不依赖子树扫描覆盖到它。
**验收判据**：这批从"无我们的图"变成有我们的图，同时"暴雪层 仍可见"不升（不能靠"不压了"蒙过去）。

**我这一趟自己的两次自伤，也记在这里当反面教材**：
- `IsButtonObj` 被 `insertAfter` 插进 `ReadAtlas` **函数体内部**（锚点选了下一句的签名）⇒
  外层调到 nil、pcall 吞掉错误，探针从命中 400 掉到 0，luac / audit-locals / harness 全绿抓不到（`b5094da` 修回）。
  ⇒ 往函数外插代码，锚点要用"上一行的完整语句"，不能用"下一句的签名"。
- 肖像做成"所有窗口自动猜 `<窗口名>Portrait`"⇒ harness 的未知名字 warn 从 2118 冲到 3702，
  等于把今天削掉的噪声自己造回来（`bc494c2` 改成按面板点名）。

## 8.48 2026-11-05 #45 结案：不是换肤缺陷，是认脸的第二个洞（自建贴图缺 `art` 标记）

补完"方向键存在安全属性"那条腿（`9f4c196`）之后 `arrows` 仍报那批"无我们的图"，所以我没有继续改换肤代码，
而是**把一只按钮名下的贴图全列出来**：

```
host=ChatFrame1 | R1 Texture tex=8069102 a=0 | R2 Texture tex=-1627 a=1
```

⇒ 暴雪原图被压（正常）+ **我们的 V 形一直在、α=1**。所谓"没人补图"根本不存在 ——
是 `Stepper` / `ScrollArrowButton` 自建的那张贴图**没打 `art` 标记**，而我们的 BLP 加载后
`GetTexture()` 回的是**数字 ID**（不是路径字符串），于是"路径里找 `monet_`"这条腿永远判不到。

**改法**（`af0b11d`）：两处建箭头贴图都补 `Mark(our, "art", true)` —— 认脸的单一事实来源是**标记**，
不给探针加"负数 ID 算我们的"这种特例（加了就会有两套判据）。

**实机复跑 `arrows`**：`我们的箭头 142 → 317`，那批变成
`1 张 rot=0.000 uv正 α=1.00`（up）/ `uv双翻=180°`（down）—— 方向也是对的；
`暴雪层 仍可见` 仍是 **58 没升**（满足 #45 定的验收判据：不许靠"不压了"蒙过去）。
剩下的"无我们的图"行是 `键=-(-)` 那批（`MainActionBar` 的贴图、`DropDownList*ExpandArrow`），
它们不是滚动条步进钮，不该动。

**这一族的最终教训（写进探针纪律）**：当"缺陷"和"仪表"都能解释同一个读数时，
**先花一次成本把对象本身列出来**（这里是一条 `GetRegions` 遍历），别在换肤代码上继续叠改动 ——
今天这条要是继续"修"，就会去给探针加特例、或者把已经正常的代码再改一遍。

## 8.49 2026-11-05 肖像"改了方形还是圆"：裁切档位 + 1px 方框（作者选 C，未提交前先看实机）

现场读数（`/mui skins layers` 与肖像专项）里 `CharacterFramePortrait` / `QuestFramePortrait` 已经是
`tc=0.15..0.85 [已裁方]`，但玩家眼睛看到的仍是**圆**。原因不在裁切有没有做，而在**图集里的圆没占满画布**：
`RTPortrait1` 的圆四周留了一圈透明，裁到内接正方形正好把透明留在四角 —— 露出窗体底色，视觉上就是圆。

**改法（`Utils/Skin.lua` 的 `Skin:SquarePortrait`，作者选 C 的两半）**：
① 裁切档从 0.15 收到 **0.22**（`PORTRAIT_CROP` 常量，注释写清是现场读数逼出来的，不是几何推算）；
② 肖像**描一圈 1px 方框**，让"方形"这个信号由我们的边框给出，不再靠脸本身的轮廓。

**为什么方框不是我们的背板框**（下次有人想"统一用 `NewBackdropFrame`"，先读这段）：
肖像是 **贴图不是框**，贴图不能挂子框体 —— 任何子框都画在父框的贴图之上，会把脸整张盖掉。
所以四条边直接做成**同一个父框的 region**（`OVERLAY` 高 sublevel，`monet_hairline` 染色，
`Mark(tex,'art')` 让认脸把它算成我们的图），只占 1px 边、不遮内容；边框色跟着 `Color:GetBorder()`，
并注册一次 `OnTheme`（换主题要跟着别的边框走，肖像自己不会重画）。

幂等靠 `Marked(por,'portraitRing')`；这一圈和裁切都放在**每次显示重涂**的 `applyOnce` 里
（11-05 实测：暴雪的 `SetPortraitTexture` 在窗口 Show 时会把 texcoord 顶回 0..1）。

离线闸门：`api-audit` 无 HARD、`audit-taint` 0/0/0、`audit-locals` 全过、`harness` 红 0
（对象数 62257 → 62291，就是这十几条边）。**观感必须实机看**：裁到 0.22 会不会把额头裁没了，
只有开角色面板（I）/ 任务 NPC 对话框才能判。

## 8.50 2026-11-05 #43 全量安全载体（MicroMenuSecure）实机撞墙，押回上线后：三条硬约束

作者选 A（独立安全载体，右键弹 12 行代点原生微按钮）。写了 `Modules/Minimap/MicroMenuSecure.lua`
（默认关 `microMenuSecure=false`），逐条实机验，**没跑通**，记录三条真实拦路石（上线后重做先读这段，别重趟）：

1. **代点目标必须 `IsVisible`，而它住的 `MicroMenu` 正是我们要藏的**（架构级冲突，真凶）。
   引擎 `HandleAttributeClick` 对 `type="click"` 有 `clickButton:IsVisible()` 守卫：目标不可见就什么都不做
   （`/mui` 探针：`row.type=click`、`row.click=CharacterMicroButton`、行 shown/enabled 全对，但点了没反应）。
   而 `CharacterMicroButton` 的父 `MicroMenu` 被 `hideMicroMenu`（默认 true）藏了 ⇒ `IsVisible=false`。
   试过 `ensureVisible()`（建时 + Toggle 时 `MicroMenuContainer`/`MicroMenu` `Show()+SetAlpha(0)`，
   IsVisible 只看 shown 不看 alpha）：探针实测 `MicroMenuContainer shown=true` 但 `MicroMenu shown=false` ——
   我们的 `Show()` 被 `hideMicroMenu` 的静音逻辑**重新藏掉**（AGENTS 的"和暴雪 Show/Hide 拉锯"现场）。
   ⇒ 上线后要么**不复用 MicroMenu**（另找一组常驻可见的触发件），要么让 `microMenuSecure` 开着时
   `hideMicroMenu` 改成 alpha 0 而非 hidden，且解决拉锯（谁最后写谁赢）。

2. **安全片段环境取不到暴雪帧**：片段里 `self:SetAttribute('click', CharacterMicroButton)`（裸名）和
   `_G['CharacterMicroButton']` 两种写法回读都 `click=nil`（`MonetUISnippetProbe` 实测）。
   ⇒ `click` 的帧引用只能 Lua 写；而 Lua 写的是脏值，**在 ForceTaint_Strong 开发者模式下没法干净验证引擎认不认**。

3. **workshop 是 developer 模式 + ForceTaint_Strong**：`/run` 造的框被强制标脏，
   `MonetUITestCarrier:Hide()` 报的是 `*** ForceTaint_Strong ***` 归属，不是 MonetUI。
   ⇒ 今天所有 `/run` 可行性探针（含"脱战 SetPoint 落地"）都在脏环境里出的数，**不能当 A 可行/不可行的结论**。
   上线后要在**非强污点**环境重测。

已交付且能用的不受影响：4 行右键菜单（背包/地图/日历/设置）+ `SetWidth` 修好的弹框 + 肖像隐藏。
载体代码留着（默认关、不参与右键），但**当前是坏的**（透明 + 点不开），上线后按上面三条重做或直接删。

## 8.51 2026-11-05 A 档覆盖率补（skin-coverage 工具 + 天赋/法术页）+ 一条"不是我们的 bug"判例

**新工具 `tools/skin-coverage.js`**：作者问"能否从客户端读各暴雪界面、查有没有美化到"。
`frame-name-existence.js` 是反方向（我们的名单→XML），答不了"暴雪有但我们没做的窗"。这个补那一面：
从 FrameXML 源枚举顶层窗口（parent=UIParent 类 + 有 strata 或 hidden+mouse，剔 Template/成员路径/非窗后缀），
和 `Modules/Skins/*.lua` 引用的名字对撞，再策展剔掉"别的模块已管/HUD/开发件"。
加 `--emit-candidates` + `--live`（读实机 `_G`/EnumerateFrames 存在名单）把缺口分成
"此刻真存在"与"没加载"。本车道实测：候选 233 · 已美化 42(18%) · 其它模块/HUD/开发 56 · 真缺口 135，
其中**此刻真存在 45**（其余 90 是 LoD 内容窗）。按类补了 A 档 5 批 32 个窗（好友/聊天/社区/商店/杂项）。

**天赋/法术页（`PlayerSpellsFrame`）两处补**：
- 肖像：`PlayerSpellsFramePortrait` + CircleMask 补 `portrait=true` 隐藏（同其余窗口）。
- **羊皮纸 / 天赋背景**：`spellbook-page-*`（法术页正文）和 `talent-background`/`Talents-Background`/
  `Talents-inner-frame`/`talents-heroclass-backplate`（天赋页）挂在**匿名子帧**上 —— `Strip` 只处理一个框
  自己的 region、`deep` 只扫子按钮，两条都够不到。新增 `Skin:FadeAtlasBackdrop(frame, patterns)`：
  按 atlas 模式**递归**压认得出的背景，复用 `Fade`（幂等、可回滚），**只压背景、绝不碰图标/动画遮罩**
  （AGENTS 功能图标豁免同纪律）。接进 `SkinPlayerSpells`：Apply 剥一次 + `M:HookShow` 开窗重涂。实机确认羊皮纸剥掉。

**判例：tab 图标"先有后没"= 暴雪侧，不是我们的美化（作者一开始怀疑误剥，A/B 证伪）**：
- 探针：页签所有贴图 `ourHidden=nil`（我们一张没压过）；未选中页签图标 `tex=nil`（暴雪根本没赋图）；
  未选中页签形状 α=0.40（暴雪自己对未选中态的变暗）。
- **决定性 A/B**：把 playerspells 面板整个关掉（`panels.playerspells=false`）+ 重载，纯暴雪原样下
  tab 图标**照样"第一次能看到、之后消失"** ⇒ 现象与我们的皮肤无关，是暴雪页签自己的时序/行为。
- 教训复用（`feedback-green-gates-must-cover-the-path`）：**"看着像我们剥的"必须用 A/B（关我们的皮肤）证伪**，
  别在皮肤代码上继续叠改动 —— 这条要是没做 A/B，就会去给页签图标加豁免、或把已经正常的代码再改一遍。
- 已把面板恢复默认（开）。

## 8.52 2026-11-05 #33 配置稀疏落盘（PLAYER_LOGOUT 剥默认值）

**问题**：`LoadDatabase` 里 `MergeDefaults(db, DEFAULTS)` 把每个默认值直接烘进持久化的 `MonetUIDB`
⇒ ① SavedVariables 存了全量默认；② 以后改 `DEFAULTS` 里某个值**传不到老玩家**（MergeDefaults 只补
`dst[key]==nil` 的缺失键，老库里已烘死旧值）。

**改法（低风险，读取点零改动）**：内存里 `ns:DB()` 仍是补满的全量（所有 `db.xxx` 读法不变），
只在 `PLAYER_LOGOUT` 落盘前 `StripDefaults(MonetUIDB, DEFAULTS)` 就地删掉等于默认值的键。
`StripDefaults` 只对"默认值也是表"的键递归下钻、且只遍历 DEFAULTS 的键：
- 空默认表（`bags.positions` / `mover.locks`）下钻剥不到任何键 ⇒ 玩家拖出来的位置/锁自动保留；
- 诊断账本（colorReport / layerReport / perfReport / compatReport）和 `schema` 不在 DEFAULTS 顶层 ⇒ 绝不误删。

**实机验证**（账号 039124100）：部署后连重载两次（第一次载入新代码、第二次 `PLAYER_LOGOUT` 才跑 strip），
WTF 文件里 `iconSize=34`/`UnitFrames=true`/`snapRange=6`/`alertSeconds=5` 等默认键 grep=0（已剥），
`schema=9` + 三个 report 仍在；运行期 `ns:DB().bags.iconSize` 照样读到 34（MergeDefaults 补回）。
**时序坑记牢**：`/reload` 的 `PLAYER_LOGOUT` 由**当前运行的旧代码**触发，所以部署后要看效果得重载两次。

**没解决、也不属于本任务**：文件仍 ~400KB，大头是诊断账本（layerReport 1500 行等），那是故意落盘供
从 WTF 读的，不是配置默认。要瘦身得单独动账本的落盘策略（另议）。

## 9. 下一步（2026-11-04 深夜重写；旧版第 9 条"上线前 push + 徽章改正式版"已作废）


### 9.1 明早开服首趟（唯一优先级，别在此之前加任何新功能）

**首趟已跑（11-05，结果与逐条处置在 §8.34）**：第 1 步 ✓（19/19 + 关闭项归因清楚）；
R1.0/R1.1 ✓；`skins diagnose` ✓ 但**只算预扫**（窗没开，198 条 ✗ 里大头是"没出生"）；
`blocks` ✓ 空；R7.8 银行索引 ✗ **取不到**（不在银行 NPC 前）；微菜单 P0 复验 ✓ 消失。

**二趟（接着跑，顺序有意义）**：

1. 逐窗打开一遍（拍卖 / 收藏 / 专业 / 训练师 / 法术书 / 任务日志 / 检查 / 日历 / 宏 / 飞行图 / 幻化 /
   打孔 / 订单 / 公会 / **传承 LegacySystemFrame** / **查找组 LFGParentFrame**），再跑
   `/mui skins diagnose` —— 差集才配拿去改名（任务 #41 的输入）。
2. **站到银行 NPC 前开银行**跑 `/mui bags probe`，读逐索引行定性 #25 的索引语义；
   同时跑 R7.5–R7.11（等级数字、两列并存观感、`bagID字段` 是否 nil、拖放三向）。
3. R2–R6 视觉项按 `docs/VERIFY-1.60-CHECKLIST.md` 逐条走过。
4. `/mui compat tmpl` 单独一趟（模板 7 项首趟没探，`ActionBarButtonTemplate` 会自带 6 条报错）。

三条"预期不是缺陷"（首趟已按这个口径判过）：银行**两套并存**（接管默认 off，#25 没做完之前不许开）；
`WarbandBankFrame` 在台账里是 ✗（本客户端没这框）；`EncounterJournal` / `AeLoot` 两块 ✗ 归 GameRule（1.60 实测生效）。

**开服日上午已收口的三条（每条都有两个以上独立数字，不靠"看着正常"）**：

| 项 | 客观判据（1.60.1 · 70790 实机） |
|---|---|
| 微菜单 P0（直调暴雪 Lua 全局） | `logs ERR` 在重载后窗口内**零新增**、`/mui blocks` 账本空 |
| 信息栏"点一格开面板"下线 | 现场 `MonetUIInfoBar:IsProtected()=false`、9 个子件 **0 个受保护**；`logs BLOCKED` 零新增 |
| 遮罩被同机收纳器搬走（§8.39） | `MonetUIMinimapOverlay [1842,33 256x190] parent=MonetUIMinimapHolder points=2`（修前 `[0,0 0x0] parent=RurutiaSuiteMinimapCollector`）；`MonetUIMinimapMicroMenu [1778,160 56x65] points=1`（修前 `points=0`） |

**还没做完的（按依赖排）**：#25 要**站到银行 NPC 前**开银行才能取到索引语义；
#41 B 批要**逐窗开过**（拍卖/收藏/专业/训练师/任务日志/检查/日历/宏/飞行图/幻化/打孔/订单/公会/传承/LFG）；
#42 `/mui perf` 计时换 `debugprofilestop`；#43 点一格开面板的合法载体；#28 共存声明与自静默。

### 9.2 开服后第一批（任务板已建，按序）

| 任务 | 内容 | 为什么排这个位置 |
|---|---|---|
| **#25** | 银行侧空格做真槽位（先用 `/mui bags probe` 逐索引行定性"6..12 各报 98 槽"的语义）→ 放开 `activeMode=="bags"` 那道门 → 三向掉落实测 → 才允许把 `hideBlizzardBank` 默认改 on | 银行观感完整性的唯一阻塞项；索引语义没定性就绑槽位 = 把拖放绑错格 |
| **#26** | 追踪器「任务专用物品」可点钮（照 RurutiaSuite `RaidMarker` 的合法路线：`SecureActionButtonTemplate` + 属性，不直调受保护全局） | 玩家日常会撞；路线已被两份第三方样本反证过 |
| **#33 / #34** | 稀疏默认值 + 存盘剥默认；能力矩阵按 Interface 区间 + 助手返回行为 | 一次性解掉"落盘晚 1–2 分钟丢写"和"同一句话两客户端相反"两类老痛 |
| **#35 / #38** | 差异刷新 + 自装配共享驱动；按帧预算的协程任务器 | 纯性能，行为等价 |
| **#36 / #29 / #30 / #32 / #39** | 姓名板目标监视池、XP 速率、错误按类型静音、版本差提示、CVar 面板 | 单点收益，互不阻塞 |
| **#37** | 配置导出/导入（确定性编解码 + 只导差异 + 事务回滚，白名单自生成） | 公开发行后玩家互传配置的刚需，依赖 #33 |

### 9.3 仍然开着的旧问题（不新增，只登记）

- SpellFlyout：鼠标点选项必报 `CastSpellByID()` FORBIDDEN，快捷键路径正常 —— 要么接受"只提示一次"，要么自绘托盘。
- `_retail_` 那份旧 MonetUI 拷贝与 `MonetUI.rar`：现在它已升级成**预验支**（120105，带 WoWBridge，可登录），
  先别删；`docs/PRECHECK-RETAIL-120105.md` 是它的用途说明。
- 宠物条每次重载 10 条 `PetActionButton*:SetShown` BLOCKED：已知代价，不改更稳（AGENTS 动作条节）。
- `docs/` 是否入 git：§5 第 5 条已拍 C（不入），靠仓外快照兜底 —— 若哪天改主意，动作是把
  `!docs/PRELAUNCH-RUN-1105.md` 等几行加进 `.gitignore` 白名单并单独一笔提交。
