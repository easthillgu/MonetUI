# 新增一条断言（A7）六步模板 —— 照 A6 的落地抄

> **草稿**。A6（"regen / 限制解除派发当拍直接写受保护对象"）是最近一次完整落地，它把
> 「一句可判定的话 → 类名 → 窗口旗 → 去重规则 → 坏样例 → 文档与三次回归」走了一遍，
> 所以拿它当模板最省事。下文每一节都标了 A6 的实际落点，抄的时候把 `A7` / `<flag>` /
> `<名字>` 换掉即可。
>
> 硬约束不变：**不改发行码、不放宽断言、不加 git 写操作**。新断言红了先定性，
> 只有"离线证据撑得住"才判红，撑不住的降 `warn` 并在 `why` 里写清缺什么。

---

## 第 0 步（不写码）：把断言压成一句可判定的话

先答三问，答不上来就先别动手 —— 否则后面会写出一条"看着像断言、其实在猜"的账。

1. **判据从哪来？** 本仓只有三份离线证据：
   - 客户端文档快照 `docs/api` 的 `fl.pm`（受保护的方法）/ `fl.r`（受限）→ 够判红；
   - `world-data` 的逐对象 `prot` 位（XML `protected="true"` 或 inherits 碰到 `Secure*`）→ 够判红；
   - 事件时序（AGENTS 的实机探针，如"regen 派发当拍 `InCombatLockdown()` 仍 true"）→ 够判红；
   - 其余（"我觉得客户端会拒"）→ **只能 warn**。
2. **修法是什么？** 修法不同就得单独成类。A6 立类就是因为它不是"补守卫"而是"挪一拍"。
   反例：A2i（继承型保护）/ A2n（prot=0 的普通框）证据不足，所以是黄不是红。
3. **去重键是什么？** `对象 + 操作 + 文件:行 + 那一拍的窗口`。缺一项就会出现
   "同一个问题被压成一行"或"两种修法的问题被合成一行"。

产物：类名（`A7`）、等级（`red`/`warn`）、一句标题、一句 `why`（写给三天后复现的人看）。

---

## 第 1 步 `report.lua`：登记类名与断言号

落点：`CLASS_ASSERT` [report.lua:36](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/report.lua#L36)
（A6 就是加在这一行），头注释 [report.lua:12-22](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/report.lua#L12)。

```lua
-- 头注释（紧挨 A6 那一段）：
--      A7 是"……（一句话说清是什么、为什么离线判得了、修法和其他类差在哪）"。

local CLASS_ASSERT = {
    ...
    A2 = 2, A2c = 2, A2i = 2, A2r = 2, A2n = 2, A6 = 2, A7 = 2, A1b = 2,  -- ← 新加 A7
}
```

验收：跑一次 `run.js`，`A7` 的行会并进它挂的那条断言（上面例子是"断言二"），
不会掉进"其它（类 …）"。

---

## 第 2 步 `api_stub.lua`：分类点 + 窗口旗（只有"时序型"断言才需要旗）

**2a. 如果这条断言只在某个时序成立**，先在 `api.world` 里加一个默认 false 的旗，
落点 [api_stub.lua:214](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/api_stub.lua#L214)：

```lua
flushWindow = false,  -- 正处在 Core.AfterCombat 的排空窗口里（run.lua 在派发 regen / 限制解除时置位）
<flag>       = false,  -- A7 的窗口：……（谁置位、什么时候清）
```

**2b. 在 `deny()` 的分类处加分支**，落点
[api_stub.lua:296-302](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/api_stub.lua#L296)：

```lua
local cls
if inherited then cls = "A2i"              -- 自建子件、保护只从父框继承（黄）
elseif api.world.flushWindow then cls = "A6" -- 排空时序（红）
elseif api.world.<flag> then cls = "A7"      -- ← 新
else cls = "A2" end
```

顺序有讲究：**证据最弱的先收掉**（继承型只到猜测 → A2i）。分类之后 `why` 要加一句，
落点 [api_stub.lua:315-330](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/api_stub.lua#L315)：

```lua
why = string.format("%s · 判据：%s",
    cls == "A7" and "<一句话：现象 + 为什么离线判得了 + 修法>"
        or (cls == "A6" and "…" or (…)), evidence),
```

**2c. 先记账再抛**（[api_stub.lua:331](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/api_stub.lua#L331) 的
`error(...)` 在 `add(...)` 之后）—— 顺序反了，任何 `pcall` 都能把这条账吞掉。

> 若 A7 不是"某一刀被拒"，而是"某个调用根本不该出现"（如 A2r 的 `fl.r` 受限方法），
> 那就别动 `deny()`，在对应的漏斗分支里直接 `add("A7", ...)` 即可（见 `need` 与
> `gateMethodTable` 的现有写法）。

---

## 第 3 步 `run.lua`：置位/驱动

**时序型**：仿 `inFlushWindow`，落点
[run.lua:585](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L585)：

```lua
local function inFlushWindow(fn)          -- A6 版：派发抛错也要把旗子放回去
    api.world.flushWindow = true
    local ok, err = pcall(fn)
    api.world.flushWindow = false
    if not ok then error(err, 0) end
end

local function in<Flag>Window(fn)         -- A7 版
    api.world.<flag> = true
    local ok, err = pcall(fn)
    api.world.<flag> = false
    if not ok then error(err, 0) end
end
```

调用点就是**会触发那个时序的那次派发**，落点
[run.lua:629](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L629) /
[run.lua:636](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L636)：

```lua
in<Flag>Window(function() api:Dispatch("<事件名>") end)
```

**驱动型**（不是时序窗口，而是"每个阶段都该成立"的检查）放在
`eventSweep` / `runRefreshers` / `themeSwitches` / `onShowPass` / `alphaAudit` 里；
回调必须是**模块级稳定函数**，不在 Apply 里现造闭包。

---

## 第 4 步 去重与降级：一条写入只配一条红

新类最常见的事故不是漏判，而是**同一条毛病记了三遍**，把真正独立的那几条埋掉。两条规矩：

1. **同一条写入被 `pcall` 吞掉后 print**：`run.lua` 的 `reportLine` 已经有去重，
   落点 [run.lua:246](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L246)：
   ```lua
   local dup = d and (d.cls == "A6" or d.cls == "A7" or d.cls == "A2i")   -- ← 把 A7 加进来
       and d.frame and line:find(tostring(d.frame), 1, true) ~= nil
   ```
2. **同一条写入打断了刷新路径**（`runScript` 的 A0）：落点
   [api_stub.lua:2025](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/api_stub.lua#L2025)：
   ```lua
   if blocked and d and (d.cls == "A2i" or d.cls == "A6" or d.cls == "A7") then
       cls, level = "A0b", "warn"
   end
   ```
   降成黄的前提是**根因那条已经记在断言二**；如果 A7 的根因也是黄，那更不能升级。

去重键里 `cls` 与窗口旗都要在：A6 的 key 是 `cls:frame:op:file:line:win`，
同一个操作在"平时没守卫"和"排空拍"下必须分开（修法不同）。

---

## 第 5 步 坏样例 + 假绿自检

**5a. 样例** `samples/bad-<名字>.lua`（A6 的：
[bad-aftercombat-write.lua](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/samples/bad-aftercombat-write.lua)）：

```lua
-- tools/harness/samples/bad-<名字>.lua
-- 故意写坏：<做什么、为什么会被判 A7>。
-- 正确写法：<修法一句话>。期望：断言 <N> 记 A7 <红/黄>。
local ADDON_NAME, ns = ...

local M = {}
ns:Register("HarnessSample<名字>", M)

function M:Apply()
    -- 注册成模块 ⇒ runRefreshers 每个阶段都会走到它（这是样例能被打红的前提）
    <故意违反 A7 的动作>
end
```

要点：样例只放 `tools/harness/`，**不进发行目录、不挂 xml/toc**；动作要能被打到，
不能依赖只在实机才出现的状态。**样例必须对准"仍然非法"的形状** —— 产品把旧形状修掉之后，
样例就不再是坏代码，自检会 exit 2（MISS）。A6 已经栽过一次：Core 11-04 把 `FlushAfterCombat`
挪进 `C_Timer.After(0, …)` 后，原来"经 `ns:AfterCombat` 排队"的样例就失效了，改成"模块自己
在 `PLAYER_REGEN_ENABLED` 处理里直接写受保护框"才重新打红。**MISS 是信号，不是去放宽断言。**

**5b. 登记两处**，落点
[run.lua:849](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L849) /
[run.lua:889](file:///C:/Users/EastHillGu/.qoder-cn/worktrees/app/02efb0/MonetUI/tools/harness/run.lua#L889)：

```lua
local known = {
    "bad-write-blizzard-field.lua", ..., "bad-aftercombat-write.lua",
    "bad-<名字>.lua",                                    -- ← 新
}

local EXPECT = {
    ...
    { "A6", "bad-aftercombat-write", "断言二：regen 派发当拍直接写受保护框" },
    { "A7", "bad-<名字>", "断言 <N>：<标题>" },            -- ← 新
}
```

**5c. 验收**：`node tools/harness/run.js --selftest` 必须 **exit 0**，且新样例一行是 `OK`。
打不红 = harness 自己坏了，先修 harness，不许改断言迁就样例。

---

## 第 6 步 文档 + 三次回归

- README：级表补一行（`warn`/`red` 各在哪些类）、"harness 自身覆盖面"若因此变化要同步、
  当前红表若被 A7 改了要重写（A6 落地时 README 的"当前 4 条红"先改成"当前 2 条红"；
  产品修掉后又要改成"当前 0 条红 —— A6 的历史与现状"，并写清"Core 修的是旧形状，
  A6 的样例已重新对准仍非法的形状，不许降级"）。
- 三次回归，**每一处数字变化都要能解释**：

```bash
node tools/harness/run.js                 # 默认：红/黄/guarded/info 各多少
node tools/harness/run.js --selftest      # 必须 exit 0，新样例 OK
node tools/harness/run.js --secrets       # 机密常开时不得崩、不得凭空多红
```

- 反模式清单（踩过就别再踩）：
  - ❌ 为了让红变绿去放宽断言 / 摘掉样例；
  - ❌ 把"证据不足"的判据写成红（该降 `warn` 并写清缺什么）；
  - ❌ 窗口旗不复位（派发抛错后整段测试停在错误的锁定态 —— 冒号调点号函数那次就是这样）；
  - ❌ 只加 `add()` 不加 `EXPECT`，于是没人证明它真的会红（假绿）；
  - ❌ 改发行码"顺手"修掉样例的问题。

---

## 一页检查表

- [ ] 第 0 步：一句话可判定、判据来自三份离线证据之一、修法与其他类不同、去重键四要素齐
- [ ] `report.lua`：`CLASS_ASSERT` + 头注释
- [ ] `api_stub.lua`：窗口旗（如需）/ 分类分支 / `why` / 先记账再抛
- [ ] `run.lua`：置位 helper + 调用点（或驱动位置、稳定回调）
- [ ] 去重：`reportLine` dup 名单 + `runScript` A0b 名单
- [ ] `samples/bad-<名字>.lua` + `known` + `EXPECT`
- [ ] `--selftest` exit 0 且 `OK`
- [ ] README（级表 / 当前红 / 覆盖面）
- [ ] 三次回归数字可解释，发行码零改动