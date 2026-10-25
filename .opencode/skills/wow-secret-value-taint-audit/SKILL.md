---
name: wow-secret-value-taint-audit
description: 审查魔兽世界插件 Lua 代码中因"秘密值(Secret Values)"与"污染(Taint)"导致的报错、UI 污染与战斗状态失效风险。当用户报来 tainted / secret 错误、审计 UnitHealth / C_UnitAuras / SetCooldown / COMBAT_LOG 等敏感 API 用法、要求 commit 前 taint 自查，或适配《至暗之夜》秘密值机制时使用。只做"检测 + 降级 + 安全写法 + 原生桥接"，绝不提供绕过手段。以 MonetUI 项目约定（AGENTS.md 污染模型）与本客户端（WoW Forever 16001）实机事实为准。
---

# WoW Secret Value / Taint Audit（MonetUI 项目版）

本 skill 审查《魔兽世界》插件代码，找出所有可能触发**秘密值污染(taint)**、**Lua 报错**、
**UI 生产中止**的位置，并给出可执行的修复方案。**本 skill 不绕过暴雪限制，只做安全降级与
原生桥接。** 三条实机踩出来的完整案例链直接支持本手册（见"实机案例"），遇到同族症状先对表。

## 何时使用

- 用户提供插件目录 / `.lua` 文件 / 报错片段，要求检查是否会触发污染或报错。
- 报错中出现 `secret` / `tainted` / `restricted` / `SetCooldown` / `UnitAura` /
  `index a table that cannot be accessed while tainted` / `ADDON_ACTION_BLOCKED` 等关键字。
- 单位框体 / 队伍团队框架 / Buff·Debuff / 冷却 / 姓名板 / 动作条模块的适配审查。
- commit 前自查：`node tools/audit-taint.js`（启发式扫描，BLOCKER 清零才算过闸）。

## 绝对红线（触发即拒，先说明原因）

1. **只检测与降级，绝不绕过。** 不提供反推秘密值（数学还原血量/CD/剩余时间）、私有锚点探测、
   战斗聊天同步、插件间同步战斗数值等手段 —— 必然报错且有封号先例。
2. **默认假设战斗数值不可读。** 战斗中来自单位的血量/法力/冷却/光环时长/单位身份，
   先当作可能被加密（条件性秘值），必须守卫后才消费。
3. **不依赖完整 `COMBAT_LOG_EVENT_UNFILTERED` 做实时战斗判断**（本客户端它是受限事件，
   `try`/`run` 一律不许注册）。

---

## 一、本客户端事实校准（先读，覆盖 retail 记忆）

本客户端是 **WoW Forever 16001（Interface 120105，Lua 5.1）**，非标准零售。以下事实以
实机为准；查 API 一律走 `docs/api/` 本地快照（`node tools/api-lookup.js <名字>`），
`hated-wow` MCP 只是 retail 补充，**效力低于快照**。

1. **`issecretvalue(v)` 存在且是唯一通用判定**。判定机密只在值级做。
2. **`IsAnchoringSecret` 在本客户端不存在**（快照无此全局、实机 `nil`）。锚点守卫改用
   `issecretvalue` + `C_Secrets.*` 谓词族（`ShouldUnitHealthMaxBeSecret(unit)` 等已实测可查）。
3. **"nil ≠ secret"**：脱战后 `UnitThreatSituation` 等 API 返回的普通 nil 表示"没有该信息"，
   按 0/无处理；只有 `issecretvalue` 为真才保留上次状态。否则红边之类的状态会永远挂着。
4. **秘值参与的取值选择禁止 `and/or` 真值链** —— `a and b or c` 在 `a` 为真时会**真值测试 b**；
   只要 b 可能是秘布尔/秘值，必抛 `boolean test`。一律改显式 `if`。哪怕值不会被自己消费（案 B）。
5. **冷却**：旧接口 `SetCooldown(start, duration)` / `SetCooldownFromExpirationTime` 弃用
   （受限环境报 `Secret values are only allowed during untainted execution`）。正确链：
   `GetActionCooldown(slot).isActive`（NeverSecret 判活）+ `C_ActionBar.GetActionCooldownDuration(slot)`
   返回 LuaDurationObject → `cd:SetCooldownFromDurationObject(dur)`（受保护方法，但参数是引擎
   自己的对象，实测可用）。**别用 `C_ActionBar.RegisterActionUIButton`**（客户端回写引擎冷却框，
   参数是机密值，受限时必报 SetCooldown 秘值错）。
6. **`Cooldown:GetCooldownTimes()` 返回毫秒，`GetTime()` 是秒**。混算把 6 分钟画成 `568d`。
   凡拿 cooldown 时间先想单位；剩余 > 30 天当读不到兜底。
7. **机密标记分层**（快照标注）：`C_Spell.GetSpellCooldown` → 机密[SecretWhenCooldownsRestricted]
   且"允许污染代码传机密"（可以传给引擎接口，不能自己算）；`C_UnitAuras.GetAuraDataBySlot` →
   机密[SecretWhenUnitAuraRestricted]（战斗/受限时段数不可读）；DurationObject 接口本身非机密。
   9'. **身份类文本（UnitName 等）标着"允许污染代码传机密"时，机密串要原样 SetText 进显示
   控件**（机密值可展示、不可读）。战斗身份文本的解法不是"过滤掉留白"，而是按值三档：
   明文 → 截断 + 职业色；机密串 → 原样显示 + 底色退中性；读不到 → label。
   （实机判例：名牌显示战斗中的名字，就是机密串 SetText；案翻案见 PLAN 2026-10-25。）
   9''. **UnitIsUnit 的结果是机密[SecretWhenUnitComparisonRestricted]**（实机探针：战斗中
   返回机密布尔，真值测试即炸）——"两个单位是不是同一个"在战斗中是闭锁信息，无明文旁路
   （UnitGUID 同标机密）。需要它做分支时：明文窗判定 + `ns:Mark` 缓存，秘值窗保留上次
   明文判定，无历史明文就落回名字直显路径。（>☆< 自指案 tail，SEL 2026-10-25。）
8. **战斗内测试才算数**。条件性秘值只在副本/战斗/团队框架下变秘密。主城/非战斗测试通过 ≠ 安全。

---

## 二、AGENTS.md 污染模型速查（硬规则，违反即缺陷）

按"键"判污染：普通(Lua)上下文往暴雪对象写过任何东西，之后暴雪自己跑在那个对象上的代码
全部以我们名义执行，战斗中被拒。

| 禁止 | 正解 |
|---|---|
| 往暴雪框体/贴图/字体写 `frame.__monetXxx = ...` | `ns:Mark(obj, key, value)`（Core.lua，弱键旁表）；自己的框体也走它 |
| 往受保护按钮写属性 `button.statehidden = true` | `SetAttributeNoHandler(button, "statehidden", true)`（安全写）；不响应鼠标用 `EnableMouse(false)` |
| `SetParent` 暴雪的动作条/条/集群 | 全部换到常隐框体（脱战做），Restore 放回 UIParent |
| `SetScale` / `ignoreFramePositionManager` 写在受保护条上 | 不做；编辑模式会算出 SetScale(0) 直接炸 |
| `HookScript` / `hooksecurefunc` 挂暴雪框/方法（界面美化） | 轮询：`Widget:HoverWatch` / `Widget:ShowWatch` / `Widget:PollWatch`；OnShow 重涂用 `M:HookShow` |
| 收暴雪 HUD 用 `Hide()` | `SetAlpha(0)` + 子树 `EnableMouse(false)`（alpha 0 不触发它的 Show 逻辑，拉锯消失） |
| 战斗中 secure 单位按钮 Show/Hide/SetShown | `visibility` state driver（`[@target,exists] show; hide`），任何代码路径不再直控 |
| 覆写/替写暴雪"数据"骗编辑模式 | 别让编辑模式需要我们的答案（例：小地图只把 `Minimap` 帧搬走，集群留默认位置） |

**生产者零容忍**：暴雪用来"生产"其它帧的东西（驱动/池/管理器/ApplyFrameOptions 等），
**一概不碰、不在我们的执行里调用** —— 碰一次，产物全脏（案 A）。`hooksecurefunc` 拼"改完
再改回来"也不行。

**受限窗生产**：凡暴雪通过 `securecallfunction` 调我们回调的引擎链（如 AuraContainer 的
`initializeFrame`），回调里**每一次 Create* 都要 pcall + 失败早退**，回调本体整体 pcall ——
单颗按钮任何异常穿出 securecall，会把整批（batchSize=10）全带走（案 C）。

**self-cast 链等秘值流向**：`secure 代码会读到的属性`必须由安全片段写（state driver →
`_onstate-*` → `ChildUpdate` → `_childupdate-*`），Lua 写 `action` 属性必弹"只对暴雪 UI 开放"。

---

## 三、实机案例（对表用：症状 → 根因 → 修法）

### 案 A · 名牌 taint 案（commit df9efb6）
- 症状：`ADDON_ACTION_BLOCKED MonetUITargetFrame/NamePlateDriverFrame...`、`SetPoint anchor
  family connection`、白色底片名牌（生产累计失败）。
- 根因：`RestoreBlizzardPlate → base.ApplyFrameOptions`（暴雪生产者）在秘值窗口从我们上下文
  调用；四版四次复现证明"挑时机"不可行。
- 修法+教训：**生产者一概不打**；还原只留 `SetAlpha(1)` / `Show`。凡暴雪用来生产其它帧的东西，
  不碰、挂钩、不在我们执行里调。

### 案 B · CastInfo 真值链案（commit 96c7482）
- 症状：`UnitFrames.lua:734 boolean test on field '?'`（NP :709 同款）。
- 根因：`channel and result[8] or result[9]` —— channel=true 时真值测试秘布尔 `result[8]`，必抛。
- 修法+教训：显式 if 选槽；**秘值参与的取值选择禁止 and/or 真值链**，哪怕值不为自己消费。
  `tools/audit-taint.js` 的 ANDOR 规则盯的就是这个形。

### 案 C · AuraContainer 生产波案（commit 3453b10）
- 症状：`MathUtil.lua:24 / Backdrop.lua:342 "index a table that cannot be accessed while
  tainted"` ×10 成簇、每几分钟成对；战斗 buff/debuff 行退化。
- 取证：池审计探针（`ns:Marked(kid,"borderHost")`）→ buff 池 20 槽 = 前 10 完整（脱战窗生产）、
  11–20 整批失格（连 `GetChildren` 都被拒，ApplyAccessRestrictions 落地）；debuff 池 0/10。
- 根因：我们的 `initializeFrame` 回调里六处裸 `Create`（`CreateTexture` / `CreateFrame(
  "BackdropTemplate")` / `CreateFrame("Cooldown")` / `CreateFontString`×2）在受限窗被引擎
  整体拒绝 → 抛出穿出 securecall → 整批连同其余 9 个按钮死亡。
- 修法+教训：六处 Create 全 pcall + 失败早退（样式失格交引擎外观）；两个 initializeFrame lambda
  整体 pcall。**受限窗生产的批次必然被拒，这是平台常态按失格兜底，不是要"找时机"修的 bug**。

### 关联判定（不修项）
- taintLog=2 下 `Groups UpdateRange` 数千条记录 = 秘值窗口设计内 pcall 拦截被详细模式放大，
  功能无损不修。**先看 taintLog 开关是不是自己忘关**再定性。

---

## 四、诊断工具箱

```
/console scriptErrors 1        # 开红字弹窗；/reload 复现；读完关 0
C_CVar.SetCVar("taintLog", 2)  # 写 <游戏目录>/Logs/taint.log（完整栈 + 归属）；
                               # 读完必须关回 0（详细模式有开销）
issecurevariable(obj, "key")   # 逐键扫我们留下的脏键（false = 脏）
```

wuxian MCP 在线时的 probe 套路（`try` 执行、`logs` 拉红字、`snap` 截屏）:

```lua
-- 池审计：styled 数 = 初始化回调完整跑完的按钮数（缺失即该批死在中途）
local ns = _G.MonetUI
local f = _G.MonetUICombatBuffFrame
local okc, kids = pcall(function() return { f:GetChildren() } end)
local styled = 0
for _, c in ipairs(kids) do if ns:Marked(c, "borderHost") then styled = styled + 1 end end
return f:GetName() .. " styled=" .. styled .. "/" .. #kids
```

- 失格按钮连 `GetChildren` 都被拒 → 受限窗生产必然失格（案 C 形态），按失格兜底。
- 错误"×10 成簇"优先怀疑生产批次死亡（securecall 抛出放大），不是 10 处独立 bug。
- runtime 报错先确认插件已是最新部署（`type(_G.MonetUI.Widget.TintIconBorder)` 作载入探针）。

---

## 五、审查工作流（agent 执行步骤）

1. **机械扫描**：`node tools/audit-taint.js`（本仓 Lua 全扫；BLOCKER/HIGH/SOFT 分级，
   支持 `-- TAINT-OK:` 注释豁免）。先清 BLOCKER。
2. **定位敏感调用点**（扫描器看不全的人工补）：`issecretvalue`、`C_Secrets.*`、`UnitHealth`、
   `UnitHealthMax`、`UnitPower`、`C_UnitAuras.*`、`C_Spell.GetSpellCooldown`、
   `GetSpellCharges`、`SetCooldown*`、`GetCooldownTimes`、`COMBAT_LOG*`。
3. **逐点判定**：返回值是否经 `issecretvalue` / `C_Secrets` 谓词守卫后才参与
   算术/比较/拼接/表键/文本/冷却接口？取值选择是否用了 and/or 真值链？
4. **污染侧检查**：暴雪对象上有没有写字段 / SetParent / SetScale / HookScript /
   hooksecurefunc / Hide / SetShown / 战斗中改 secure 元素？
5. **生产链检查**：我们的回调是否会穿出 securecall（裸 Create、未 pcall 的任何语句）？
   我们是否碰了生产者（ApplyFrameOptions、驱动、池、管理器）？
6. **分级**（见下一节）+ **给修复补丁**（安全写法模板下面有）。
7. **列出可保留功能**：纯样式（材质/颜色/字体/布局）不动，避免用户误删。
8. **复测指引**：`/console scriptErrors 1` → `/reload` → 副本/战斗内复测（主城无效）。

---

## 六、安全写法模板（MonetUI 现行约定版）

### 1. 秘值守卫读数（nil ≠ secret）

```lua
local function safeUnitNumber(v)
    if v == nil then return nil end                 -- 普通 nil = 没有该信息，不是机密
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local hp  = safeUnitNumber(UnitHealth("target"))
local max = safeUnitNumber(UnitHealthMax("target"))
if hp and max and max > 0 then
    frame.bar:SetValue(hp / max)
else
    frame.txt:SetText("")   -- 降级：留白/占位，绝不显示 "secret" 字样
end
```

- 展示有白名单：数值**可以送进引擎展示**（`Secrets.Number` 包裹受支持的控件，受限环境保留
  上次状态），那不是"读"。算术/比较/拼接/表键一律不行。

### 2. 冷却走 DurationObject

```lua
local info = GetActionCooldown(slot)            -- isActive = NeverSecret
if info and info.isActive then
    local ok, dur = pcall(C_ActionBar.GetActionCooldownDuration, slot)
    if ok and dur then
        cd:SetCooldownFromDurationObject(dur)   -- "可能无返回"，记得 pcall
    end
else
    cd:Clear()
end
```

### 3. 光环遍历

```lua
-- 候选读取走引擎 AuraContainer（战斗/受限时段自动退化），自己读时逐字段守卫：
local ok, data = pcall(C_UnitAuras.GetAuraDataBySlot, unit, slot)
if ok and data then
    local value = data.duration                     -- 受限时是秘值
    if value == nil or not issecretvalue(value) then
        -- 才能参与剩余时间判断/计算
    end
end
```

### 4. and/or 真值链 → 显式 if

```lua
-- 坏：result[8] 可能是秘布尔，真值测试必抛（channel 为真时 a and b or c 会真值测试 b）
local v = channel and result[8] or result[9]

-- 好：
local v = result[9]
if channel and not (issecretvalue(result[8])) then
    v = result[8]
end
```

### 5. 锚点守卫（本客户端版，无 IsAnchoringSecret）

```lua
-- 任何可能带着秘值进 SetPoint 的量，先守卫；生产者对象绝不 SetParent。
if issecretvalue and issecretvalue(offset) then
    return  -- 脱秘值窗口，保留上一次布局
end
child:SetPoint("CENTER", parent, "CENTER", 0, offset)
```

### 6. 受限窗口的取值选择

```lua
if info ~= nil then
    if issecretvalue(info.isActive) then
        -- 受限：不区分，保留上次状态
    elseif info.isActive then
        enabled = true
    end
end
```

### 7. 闸门用法（提交前）

```
node tools/audit-taint.js          # BLOCKER 必须为 0（exit 0）才能 commit
node tools/audit-taint.js --strict # HIGH 也计入退出码（严格模式）
```

- 当下基线：**0 BLOCKER**；22 条 HIGH 是静态剥离不了"我们自己对象 vs 暴雪对象"的人工
  复核清单 —— **改完代码新增的 HIGH 每条都要人工定性**，已审行用 `-- TAINT-OK: <原因>`
  行内豁免（规则变更两边同步改）。

---

## 七、按模块的专项审查清单

### SpawnProfilesUnitFrame / TargetFrame / Groups（本仓：Modules/UnitFrames）
- [ ] 血量百分比自算是否全链守卫（含 `hp/max`、阈值判断）；没守卫就交给原生状态文字。
- [ ] `CastInfo` 类双槽取值是否走显式 if（案 B 形）。
- [ ] 光环显示是否走引擎 AuraContainer 承接（战斗/受限时段自动退化）；
      `initializeFrame` 回调里 Create* 是否全 pcall + 早退（案 C 形）。
- [ ] SuppressBlizzard 家族不得用 `Hide()`/`SetScript("OnShow", Hide)`（TargetFrameToT 遗留）。

### Nameplates（Modules/Nameplates）
- [ ] 还原路径绝不调用暴雪生产者（ApplyFrameOptions 等），只 alpha/Show。
- [ ] 借来的 AurasFrame 借用稳定性：SetParent 有 pcall + 每次重挂前守卫。
- [ ] 点击区（C++ 命中测试）不被我们破坏 —— 藏名牌用 alpha 0 不用 Hide。

### BuffFrame（Modules/BuffFrame）
- [ ] 受限环境兜底靠引擎 AuraContainer；自绘层全部守卫后消费。
- [ ] `MonetUICombat{Buff,Debuff}Frame` 的池健康（案 C 的探针可复用）。
- [ ] 池审计恢复验证进部署验收清单。

### ActionBar / Cooldown
- [ ] `SetCooldown`/`SetCooldownFromExpirationTime` 全清；DurationObject 链全覆盖。
- [ ] 拖放（PickupAction/PlaceAction）有 `InCombatLockdown()` 守门。
- [ ] 暴雪条的处置完全按换父三件套（不 SetParent/SetScale/hook）。

### Minimap / Chat / 字体（纯样式）
- [ ] 不受秘值影响的样式保留；确认没有战斗判断混入。

---

## 八、严重度分级（BLOCKER / HIGH / MEDIUM / LOW）

- **BLOCKER**：秘值直接参与算术/比较/真值链/表键/旧冷却接口；裸 Create 出现在 securecall
  生产回调里；往暴雪对象写我们自己字段。几乎必报错或污染 → 立即修。
- **HIGH**：碰生产者/驱动/池/管理器；战斗判断依赖可能加密的值；战斗中改 secure 元素。
  → 改走生产者旁路/状态 driver/仅展示降级。
- **MEDIUM**：条件性秘值路径未加战斗内守卫（主城测试正常，战斗会炸）→ 加 `issecretvalue`
  + `C_Secrets` 谓词双守卫。
- **LOW**：纯样式层 → 保留，只需提示"无需改动"。

---

## 九、输出格式

1. **风险摘要**：整体健康度一句话 + 各级数量。先跑 `node tools/audit-taint.js` 的结果编号进来。
2. **问题列表**：`文件:行号 | 命中 API/规则 | 危险类型 | 严重度`。
3. **修复建议**：可直接粘贴的补丁（用上面模板），每案独立 commit 提示（本仓小步可回滚）。
4. **可保留的安全功能**：明确列出纯样式层。
5. **复测指引**：`scriptErrors` + 战斗内复测最小步骤；taintLog 记得关回 0。

---

## 十、参考仓库（学习降级思路，均只读）

- Gethe/wow-ui-source：暴雪原生 AuraContainer / AuraButton / 冷却管理器 / 单位框体状态
  文字写法（retail 镜像；本仓以 `docs/api` 快照为准，参考仓库做机制理解）
- ElvUI：外观层优先、数值判断交给原生；宠物条收养写法（ActionBars/PetBar.lua）
- sinstones/Plater：受限数据下的高可读姓名板
- DeadlyBossMods/DBM-Core、BigWigsMods/BigWigs：避开战斗日志的团队事件做法
- WeakAuras/WeakAuras2：不硬适配的官方态度（判断层与显示层分离）
- BetterAddons/wow-addon-development-guide：12.0+ 秘密值模型与污染机制综述

本项目内参考（AGENTS.md 已列）：有两个本地只读参考插件可对比实现 ——
`Andromeda`（unitframe 威胁/edge-glow、模块结构）、`EllesmereUI-v9.4`（本客户端实机
皮肤、WindowPacks、宠物条收养 EllesmereUIActionBars.lua:3150-3175）。

---

## 十一、安装方式

1. 项目级：本文件已在 `.opencode/skills/wow-secret-value-taint-audit/SKILL.md`（opencode
   自动发现项目 `.opencode/skills/`，靠 frontmatter description 触发）。
2. 全局级：拷到 `~/.config/opencode/skills/wow-secret-value-taint-audit/`。
3. 携手工具：`tools/audit-taint.js` 是本 skill 的机械执行器（commit 前闸门），规则变更
   两边同步改。

> 遇到红线请求：拒绝该部分，转而引导用户走"检测 + 降级 + 原生桥接"路线达成同等观感。
