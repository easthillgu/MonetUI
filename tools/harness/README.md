# tools/harness —— 离线行为 harness

11-05 开服前没有实机环境，而仓里其它闸门（`api-audit` / `audit-locals` / `audit-taint` /
`test-skin-lua` / `test-mult`）全是**源码正则静态检查**：它们能证明"这个名字文档里有"，
证明不了"换皮循环真的跑过 / 机密值真的被守卫 / 受限窗口真的没写受保护框"。
这一套用 FrameXML 转储 + 客户端 API 文档建出一个**可执行的世界**，把发行代码真跑一遍。

## 一条命令

```bash
node tools/harness/run.js              # 五类断言 + 台账；有红 exit 1
node tools/harness/run.js --selftest   # 再加载 samples/ 的坏样例，证明断言**确实会红**
node tools/harness/run.js --secrets    # 机密值常开（默认只在六类受限窗口里开）
node tools/harness/run.js --max=30     # 每类多列几条明细
```

退出码：`0` 没有红 · `1` 有红（产品缺陷）· `2` 假绿自检失败（harness 自己的问题）·
`3` harness 崩溃（Lua 报错）· `4` 找不到 Lua 解释器（设 `MONETUI_LUA` 或装 5.4）。

当前基线（2026-11-04，Camelot 转储）：红 **4 处 / 9 次**（银行两条产品崩溃，见下节）、
警告 2148、已放手 0、信息 1702，实例化 62117 个暴雪对象（10072 个有全局名），加载 61 份文件；
`--selftest` exit 0（每类断言都有坏样例打红，含 A6）。

## 银行路径（11-04 接入）

以前 `BANKFRAME_*` 与 `HandleCommand` 在 harness 里**零命中**，银行那条线一行都没跑过 ——
那种情况下的 `red=0` 是假绿。现在：

- **桩**：`C_Bank` 共 11 个（新增 9，含要求的 7 个），元数照 `docs/api` 快照逐条对齐；
  `FetchNumPurchasedBankTabs` / `FetchMaxNumBankTabs` → number，`CanUseBank` / `CanViewBank` /
  `AreAnyBankTypesViewable` / `DoesBankTypeSupportAutoDeposit` → bool，
  `AutoDepositItemsIntoBank` / `CloseBankFrame` → 无返回（只记调用次数），
  `FetchViewableBankTypes` → table。受限环境数值/布尔走机密机制（`api.Secret`），
  这样 `Secrets.Number/Bool` 的守卫才会真的经过。
- **有货的银行容器**：`C_Container.GetContainerNumSlots` 对 `-1` 与 `6` 各返 8，
  `GetContainerItemInfo` 在这些格子里给物品 —— 否则 Scan 全是空格、`bankDrawn=0`、
  `ParkBlizzardBank` 的判据永不成立，条件停车等于没测。槽数保持普通数字（机密化会让 Scan 直接放弃）。
- **阶段**：每个受限窗口 + 自由阶段各跑一轮 `bank-open[<tag>]` → `bank-cmd[<tag>]`
  （公开入口 `HandleCommand("bank")`）→ `bank-close[<tag>]`（`BANKFRAME_CLOSED`）→
  `bank-off[<tag>]`（`HandleCommand("bank off")`）。报告的 meta 行会打每阶段
  "银行窗 建/显 + BankFrame α/mouse"，那就是"银行路径跑到哪一步"的实测值。
- **覆盖面补洞**：`EventBus '<事件>': …` 的失败原先没有任何匹配规则（它只打第一条，之后静默），
  现在记 `A0p`；否则事件回调里的抛错完全进不了账。

**当前卡住银行覆盖的两条产品崩溃**（harness 只报告，不改发行码）：

1. `Modules/Bags/Bags.lua:671` —— `((isBank and "银行 · ") .. "")`：非银行窗时 `isBank=false`，
   `false .. ""` 直接抛 `attempt to concatenate a boolean value`。后果不止银行：**背包窗同样建不出来**，
   而且框已经建出、只是没登记进 `windows[key]`，下一次重建就变成
   `CreateFrame: MonetUIBagWindow_free already exists`（本次 6 次就是这么来的）。
   修法：`((isBank and "银行 · ") or "")`。
2. `Modules/Bags/Bags.lua:1336` —— `local function LayoutBankTools()` 把 :945 的**前置声明遮蔽**成
   新的 local，于是 `Rebuild` 里 :1002 的 upvalue 永远是 nil（`attempt to call a nil value`）。
   后果：`Rebuild("bank")` 在建完窗之后必抛，`ParkBlizzardBank` 永远到不了 —— 报告里
   `H:bank-not-parked`（银行窗有货但 `BankFrame α=1`）就是它。
   修法：改成 `LayoutBankTools = function()`（与 `EnsureBankTools` / `ParkBlizzardBank` 一致）。

这两条修掉之前，"银行阶段红数"只能说明崩溃本身；修掉之后重跑，自由/受限都应为 **0 红**，
并且 meta 行应出现 `α=0`（条件停车生效）。

## 它证明什么 / 不证明什么

**能证明**：加载期与首次 Apply 不抛错；六类受限窗口里每一刀写入暴雪对象都在守卫之内；
没有往暴雪对象写字段 / 挂钩子；挂过背板的容器有效 α > 0；`Skin:Need` 的命中/缺席台账。

**不能证明**（离线边界，别拿它当实机结论）：
- 世界只来自 **XML 声明**（`framexml-source/`，Camelot 优先、LoD 单列）。Blizzard 的 `.lua`
  里 `CreateFrame` 造出来的全局不在世界里 —— 名字"查不到出身"不等于客户端没有。
- 受保护性是**文档 + XML 的静态证据**（见下），不是 `Frame:IsProtected()` 的实机答案。
- 视觉效果、鼠标手感、真实 taint 传播、战斗中的服务端行为，一律验不了。

## 派生表：重生与入库

| 产物 | 生成器 | 入库现状 |
|---|---|---|
| `world-data.lua`（1.5 MB） | `node tools/harness/build-world.js` | 已被 `b9c3fc2` 入库（派生表，本可不必） |
| `engine-api.lua`（1.3 MB） | `node tools/harness/build-engine.js` | 同上 |

两张都是**派生表**：源在 `framexml-source/` 与 `docs/api/`，所以入不入库不影响正确性。
现状是都已入库；要收掉的话见文末的 `.gitignore` 行，**别半路撤**（别人的基线会对不上）。

`run.js` 每次启动会核 mtime：**产物缺失、或比生成器旧 ⇒ 现场重生**，所以日常只记一条命令。
换客户端分支、重新抓了 `docs/api` 快照这类"源变了但生成器没变"的场合手工加 `--regen`（别指望
mtime 能看出目录里的增删）。源的实体路径在 `build-world.js` / `build-engine.js` 头部。

## 文件

- `run.js` —— 唯一入口（找 Lua、核派生表、透传参数）。
- `run.lua` —— 世界启动、事件/刷新/主题/OnShow/α 各阶段驱动、五类断言、样例自检、缺席名字分档。
- `api_stub.lua` —— 客户端 API 与控件替身；**所有判红/记账的漏斗都在这里**（`need` / `deny` /
  `runScript` / `HookScript`）。
- `frames.lua` —— 把 world-data 按名惰性实例化成替身对象（含逐对象 `protected` 继承）。
- `report.lua` —— 台账（同 key 只留第一次现场、累计次数）、渲染、断言归并。
- `samples/` —— 六份**故意写坏**的样例，只给 `--selftest` 用；不进发行目录、不挂 xml/toc。
- `quality-color-probe.lua` —— 色彩道自己的探针，不归本 harness 管，别改。

## 判据与等级

写入判据有两份，`api_stub.lua` 里并联使用，明细行会写清是哪一份：
1. **文档**：`docs/api` 的 `fl.pm`（受保护的方法）—— 来自本客户端
   `Blizzard_APIDocumentationGenerated`，比手抄清单硬；
2. **替身清单** `PROTECTED_OP` —— 从 AGENTS 判例抄的（文档没标 pm 的那批）。

"受保护"是**逐对象**的（客户端真值是 `Frame:IsProtected()`）：只有 `world-data` 里 `prot=1`
的（XML `protected="true"` 或 inherits 链碰到 `Secure*`）才算，普通暴雪框（`CharacterFrame` /
`Minimap` 一类）在受限窗口里被写是合法的。

| 级 | 含义 | 处置 |
|---|---|---|
| `red` | 产品缺陷，离线证据撑得住（文档 pm / XML prot / 事件时序） | 上线前必须逐条修或改判据 |
| `warn` | 证据不足或需实机复核（A2i 继承型保护 / A2n 普通框 / A4s / A4h / A3s / A2r / A0b） | 记账，实机复核 |
| `guarded` | 产品自己 `pcall` 住了，但那一刀确实被拒 | 不判红，但它是"守卫成功"的证据 |
| `info` | 台账（如 A5 缺席名字清单） | 上线首日目标清单 |

## 机密值开关

默认机密值只在六类受限窗口里打开（`api.world.secrets`）。`--secrets` 让它**常开**：
`C_Secrets.HasSecretRestrictions` 恒真、`Unit*` / `C_*` 的标量返回一律走 `api.Secret()`，
于是 `Secrets.Bool/Number` 的落回、"保留上次状态"、`type()` 判不出来的机密串在**普通路径**
上也会真的经过一次。实测（2026-11-04）：红仍 4 处 / 4 次（同两条 Groups 写入），
说明机密分支没有把别处打炸 —— 但这是**替身级**结论，`canaccessvalue` 的真实执法仍要实机。

## A6 的历史与现状（A6 本身 0 红；当前红在断言一的银行崩溃）

11-04 的产品侧修复（仅 `Core.lua`）：`FlushAfterCombat` 拆成 `FlushNow` + 延迟层（排空用
`C_Timer.After(0, …)` 挪到新 tick，那一 tick 里再问一次 `ns:IsRestricted()`，仍在别的窗口就
整队留着）；补 `MONETUI_RESTRICTION_CHANGED` 的排空；`ns:AfterCombat` 的当场执行分支加原生
标志前置。于是原先那两刀（`Groups.lua:1145` / `:297`，阶段 `leave:Combat`）不再被拒，红清零。

**A6 仍然有效**，只是对准的形状换了：Core 的延迟层只管它自己的队列，**模块在自己的
`PLAYER_REGEN_ENABLED` 处理里直接写受保护框**依旧非法（那一拍 `InCombatLockdown()` 还是
true）。`samples/bad-aftercombat-write.lua` 现在就是按这个形状写的（`EventBus` 注册、
派发当拍对 `PlayerFrame:SetPoint`），自检里稳定打红 —— 所以"Core 修好了"不等于"这类问题
离线不可测了"，别再把它降级。

同一条写入若同时被 `Core.lua:410` 的 pcall 吞掉后 print，那条只记 `A0p` 黄（"同一条写入已在
断言二记"），不重复记红：一条写入配两条红会把真正独立的那几条埋掉。

## harness 自身覆盖面（不是产品缺陷）

- **多返回值桩**（同上，明细行会标"不影响断言"的就不必修）：
  - `C_Item.GetItemInfo` → 只返回 nil（`Bags.lua:234` 期望 10 个返回）→ 有 fallback，不影响断言；**建议修**（名字/品质/classID 分支目前没跑）。
  - `C_Container.GetContainerItemInfo` → nil（`Bags.lua:344` 显式按空槽处理）→ 不影响断言；**建议修**（`BuildItem` / `AssignCategory` 没跑）。
  - `UnitClass` 全局 → 只 2 个返回（`Blocks.lua:345` 读第 4 个 `classID`）→ 不影响断言；建议补 `classID`。
  - `GetSpecializationInfo` → 第 5 个返回给的是数字 `1`（产品按 `DAMAGER/TANK/HEALER` 字符串比）→ 不影响断言；建议给 `"DAMAGER"`。
  - `GetInventoryItemQuality` → nil，产品无调用点 → 不影响。
- **helper 缺口 5 项**（FrameXML 有、替身没给）：`RegisterStateDriver` / `RegisterAttributeDriver` /
  `UnregisterStateDriver`（**高**：安全单位按钮显隐只许走 visibility driver，桩不实现等于离线验不了
  条件串写错）、`SharedTooltip_SetBackdropStyle`（中：tooltip 背景分支没跑）、
  `UpdateMicroButtons`（低：微按钮刷新循环没跑）。
- **缺席名字三档**（"读了但世界里没有"）：LoD 包 / 运行期按父名生成 / **查不到出身**。
  2026-11-04 实测 393 项落在"查不到出身"——它们是拼写错、GameRule 关掉、或 Lua 运行期建帧的
  真实盲区，`--max` 可以列全（前缀 `? `）。

## 如何新增一类断言（A7）

> 模板就是现成的：**A6** 是照下面六步落的（`api_stub.lua` 的 `deny` 里分类、`run.lua` 的
> `inFlushWindow` 标窗口、`report.lua` 的 `CLASS_ASSERT`、`samples/bad-aftercombat-write.lua`、
> `EXPECT` 一行、这份文档一节）。要加下一条就照着抄。
> **逐行可抄的版本见 [TEMPLATE-A7.md](TEMPLATE-A7.md)**（判据三选一、窗口旗、去重与降级、
> 坏样例、三次回归、检查表）。

1. `report.lua` 的 `CLASS_ASSERT` 里给 `A7` 分配断言号，并在 `ASSERT_TITLE` 写一行标题。
2. 在**漏斗处**记账：`add("A7", level, key, detail)`。`key` 必须带"去重判据"
   （对象 + 操作 + `文件:行` + 那一拍的窗口），否则同一个问题会被压成一行、或者不同修法的
   问题被合成一行。**先记账再 error**（`deny()` 的规矩），否则 pcall 一吞就丢账。
3. 触发点在两处之一：`api_stub.lua`（替身侧：`need` / `runScript` / `HookScript` / 方法表包装），
   或 `run.lua`（驱动侧：`eventSweep` / `runRefreshers` / `themeSwitches` / `onShowPass` /
   `alphaAudit`）。驱动侧回调必须是**稳定引用**。
4. 加一份 `samples/bad-<名字>.lua`（故意违反，注册成模块让 `runRefreshers` 走到它），
   在 `run.lua` CLI 的 `known` 名单登记，并在尾部 `EXPECT` 表里写"这个样例必须打红 A7"。
5. `node tools/harness/run.js --selftest` 必须 exit 0，并且原来的红数不因新断言而变。
6. **断言不可迁就代码**：红了先定性 —— 真缺陷（留红）/ 判据缺离线证据（降 `warn` 并在
   `why` 里写清缺什么）/ 桩错（修桩，不要改产品）。不许为了让 harness 变绿放宽断言。

## 入库建议（`.gitignore` 由集成道维护，这里只给行）

两张派生表已经入库（`b9c3fc2`）。若决定改为"只本地生成"，加：

```
# harness 派生产物：源在 framexml-source/ 与 docs/api/，run.js 缺/过期自动重生
tools/harness/world-data.lua
tools/harness/engine-api.lua
```

其余（`run.js` / `run.lua` / `api_stub.lua` / `frames.lua` / `report.lua` /
`build-world.js` / `build-engine.js` / `samples/*.lua` / 本文件）都应入库。