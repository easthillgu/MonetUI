# MonetUI 重构计划(根据原仓 docs/CODE-REVIEW-2026-10-24.md)

- 工作副本:本仓(MonetUI-refactor,同级行)是**重构专用副本**,原 MonetUI 目录保持 cb7d932 不动。
- 基线:cb7d932
- 来源报告:原仓 docs/CODE-REVIEW-2026-10-24.md
- 硬约束:全程遵守 AGENTS.md 污染模型(ns:Mark 旁表、不 hook 暴雪帧、安全片段/宠物收养约束);
  每阶段闸门 = `tools.wuxian.check`(离线 live:false)0 错 0 警 → 在线时 reload + 功能清单 → 独立 commit。

## 对 review 的修正(已核对)

1. BORDER 定义实为 **2 处**(Groups:26、Nameplates:28)+ Minimap 独立 `BORDER_PX=1`(语义不同,不并)。
2. review #4 "血条损失部分背景"三处同构**属实,但语义有差**:UnitFrames:1662-1664 / Groups:197-200
   是白底(`SetColorTexture(1,1,1,1)`)后染色;Nameplates:296-298 是直接黑底
   (`SetVertexColor(0,0,0,1)`)。共用 helper **必须参数化底色**。
3. 拆文件耦合度(review 未量化,决定 P5 成本):UnitFrames / ActionBars 各 100+ 顶层 local 的
   upvalue 网格,**不能按行号直接切**:
   - UF Auras(876-1514):14 imports / 7 exports;ClassPower 9/3;CastBar 8/2;Blizzard压制 6/1
   - AB CreateBar:22 imports;Adopt:21;SkinButton:14;BuildButton:13
   - 走既有先例(Minimap/Buttons.lua):子文件把表挂到模块 M 上(`ns:GetModule("Minimap").buttons = B`),
     共享 live 状态收进内部表;纯常量(TARGET_AURA_*、VISIBILITY_* 等)整块就近搬家,减少前缀改写。

## 已确认排除项(review 第三节,不再动)

- UnitFrames.lua:1401-1514 注释掉的 A 方案(回滚保留)
- Widget 的 HoverWatch/ShowWatch/PollWatch(33 处在用)
- SimpleConfig 控件工厂(数据驱动已到位)
- CombatText.lua:273 的 PLAYER_REGEN_ENABLED 是状态复位,不是延迟队列,不迁 AfterCombat

---

## P1 · AfterCombat 战斗延迟队列(review #1)—— ✅ 完成(e912caa / 085df1a)

**实际结果**:
- `ns:AfterCombat(key, fn, mode?)`:Core.lua。不在战斗当场 pcall 执行;战斗中 `pending[key]=fn`
  (按 key 去重、最新者胜);`PLAYER_REGEN_ENABLED` 排空,pcall 失败者留队列等下次脱战重试,
  每 key 失败只提示一次(成功后清提示位)。`mode="regen"` = 无论如何等下一次脱战才执行,
  供"排空函数执行中又自排"的场景防立即重入(Minimap 的 Skin 失败自重排)。
- 已迁移 7 模块:UnitFrames(enabled + auras 两路)、Groups(groupframes-state,DesiredState
  读实时开关)、Nameplates(plate-size)、Minimap(自有 wants 表保留,注册改走 regen 模式)、
  BuffFrame(auras)、ActionBars(apply/bindings/adopt/layout 五标记,freshDirty 为死代码一并删,
  PLAYER_REGEN_ENABLED 处理器整个删除)、Forever(skins-micromenu)。
- **核实后不迁**(原计划 8 处,两处实为纯状态刷新而非延迟队列):InfoBar:516(战斗脉冲色)、
  CombatText:273(战斗进出场状态)。
- 净变化 126+/109−;离线 check 0 错误,warning 与原仓基线完全一致(4 条既有 PlaceAction/
  PickupAction 设计警告 + toc-interface 为目标路径未注册导致的误报)。
- 待实机验证(见下方验证清单):进/出战斗各模块补做是否生效、无 ADDON_ACTION_BLOCKED 新增。

## P2 · 热身小改动(review #6 #7 + #8,各自独立 commit)

1. commit `refactor(widget): BORDER/TEXT_GAP 收进常量表` —— ✅ 完成(385387e)
   - Widget.BORDER=1 / Widget.TEXT_GAP=3;Groups/Nameplates/UnitFrames/ActionBars 改引。
   - **bgAlpha 不并入**:实查 0.9/0.92/0.85/0.55/0.6/0.25 是按表面语义各异的值,合并会改视觉。
   - 实机验证通过:reload 后探针 Widget.BORDER=1/TEXT_GAP=3,日志 0 ERR/0 BLOCKED/0 WARN。
2. commit `refactor(unitframes): FrameChrome 单返回值` —— ✅ 完成(48544dc)
   - UnitFrames.lua FrameChrome() 返回 `Shared("border") or 1` 单值(第二个返回值 0 早已无人用)。
3. commit `refactor(simpleconfig): LayoutCursor 光标式布局` —— ✅ 完成(23d2996)
   - 机械变换(配对分析验证):104 处合并 `row(N)` + 3 处行尾留白独立 `row(4)` +
     14 处分组起点 `row = LayoutCursor(0)` + 14 处结算读 `-row.y + 4`。
   - helper = setmetatable + `__call`(Lua 5.1),`row.h` 取当前行 y 并前进;`row.y` 纯读。
   - 全区零裸 y 残留;行尾 LF 保持;离线 check 0 错误。
   - 变换脚本 bug 两处(独立前进行误删 / 带结算读的重置漏记)在断言层拦下,恢复后重跑。

### BLOCKED 调查记录(2026-10-25 初次收案)—— ⚠️ 结论已被推翻,案情见下段

初收案依"taint.log 零字节 + diff 零条受保护调用"判定周期性 `UNKNOWN()` 为已知代价、
非本轮引入。稍后实机取证推翻:同一会话继续正常游玩即爆出姓名板/CUF/施法条 ERR
全家桶,"零字节"只是当时没触到污染动作。周期性 AOAB 与本回归属两个独立问题
(周期条见下"遗留";本回归见"姓名板 taint 回归案情")。

### 姓名板 taint 回归案情(2026-10-25 01:07–01:45,哨兵备份 taint.log 实机取证)

**症状**:`CompactUnitFrame.lua:1211`(maxHealth 秘密比较,一分钟 6500 块滚屏)、
`CastingBarFrame.lua:331/:344`、`Blizzard_NamePlateAuras.lua:247/:366` —— 全部
"execution tainted by 'MonetUI'",栈内**无一帧 MonetUI**:暴雪自己的事件处理跑在
"我们的执行环境"里(整条生产链被标脏的下游效应)。

**根因**:触发器 = `ADDON_RESTRICTION_STATE_CHANGED → MONETUI_RESTRICTION_CHANGED →
M:UpdateAll()`;链条 = 被过滤牌 → `Nameplates:RestoreBlizzardPlate()`(:623)→
`pcall(base.ApplyFrameOptions)` → `NamePlateBase:68 → CompactUnitFrame:SetUpFrame →
UpdateMaxHealth / UpdateHealPrediction` → 秘值比较被拦 → 整条 compact 单位帧生产链
当场标脏,之后暴雪事件处理逐条爆。

**四版四次复现(所有"挑时机"方案全部失败,所以才收"生产者零容忍")**:
1. `a9f1e41` Combat + `HealthSecret("player")` 门:reload→PLAYER_REGEN_ENABLED 排空时
   秘值仍活(脱战事件**早于**禁限解除),排队的那次照样打进生产者(01:21:49);
2. `f039bf2` 排空闭包内再查 + Core 认 `fn==false` 留队重试:player 探针 false、
   姓名板单位机密 —— **单位级探针不可信**(01:24:27);
3. `c9ab91c` Core 按引擎事件记账 `ns.Restricted` + 全局级 `ShouldAurasBeSecret` 兜底:
   旗帜与探针全放行,Blizzard 链内仍读到机密(01:29:14);
4. `df9efb6` **不挑时机:生产者一概不打**。`RestoreBlizzardPlate` 只留 `SetAlpha(1)`/`Show`
   (普通受保护项,被拒只进 BLOCKED 日志);锚点重排由游戏下次 SetUnit/更新时自带补齐。
   **验证:reload 后 taint.log 全程 0 字节、ERR 0 条 —— 案情结。**

**沉淀(AGENTS.md 污染模型的补充条目)**:
- 暴雪单位帧生产者(`ApplyFrameOptions` / `SetUpFrame` 一族)在受限期**从我们上下文
  一次都不能调**,没有"探针显示没秘值"的中间档 —— 该客户端秘值存活窗口探针测不全:
  player 明文与姓名板机密可同刻并存,引擎事件旗帜与全局探针关闭后链内仍读到。
- `PLAYER_REGEN_ENABLED` **早于**禁限解除,不是"秘值已死"的安全点;
  `ADDON_RESTRICTION_STATE_CHANGED`(激活前先发/停用后发,载荷 type+state)也只够记账,
  不够精确判窗。Core 留了 `ns.Restricted` 旗帜作未来通用判据。
- `ns:AfterCombat` 附加语义:队内 fn 返回 false = "未就绪、留队重试、不提示,error
  语义不变"(Core.lua:403-407)。

**本轮遗留(不属回归案情,独立已知代价项)**:
- `TargetFrameToT:Show()` 家族 AOAB(reload 后 13 条 / 7 分钟,每 2-3 分钟一条,只进日志):
  根因是 UnitFrames:SuppressBlizzard 用 `Hide()` + `SetScript("OnShow", Hide)` 挂槽——
  正是 AGENTS.md 点名不要的写法,暴雪每次目标变化 `Show` 回来都被拦。
  修法现成(AGENTS 正解:alpha 0 + 关鼠标 + 不 Hide),登记 TODO 下轮做。
- WoWBridge / WuxianKit / !WuxianWorkshop 自身的 taint 记录,与本插件无关。
3. commit `refactor(simpleconfig): LayoutCursor 光标式布局`
   - `local row = LayoutCursor(yStart)`;107 处 `y = y - N` 机械替换,增删行不再手工记账。
   - 逻辑风险 0,diff 大;验证:实机打开设置面板逐页目检(位置应逐像素不变)。

## P3 · 小构件上提(review #4)—— ✅ 3.1/3.2 完成,3.3 待做

1. commit `refactor(groups): 四边框构建骨架收敛` —— ✅ 完成(fcc361d)
   - `BuildEdges(host, drawLayer, subLevel)` + `SizeEdges(edges, thickness)`;
     plain/select 两路不再复制"建 4 条贴图 + 锚四边"与量尺寸代码。
2. commit `refactor(widget): Widget:LostBarBG(bar,r,g,b,subLevel)` —— ✅ 完成(505e173)
   - 三处(UF/Groups/NP)血条损失底统一;底色走 `SetVertexColor` 保顶点色语义
     (UF/Groups 血量换色、NP 死亡灰化都要动态改,烧死 texel 会堵死 —— 黑 texel × 灰 = 黑)。
   - Note: 这两步部署后未及 reload,回归案情爆发(见上案情),验证顺延到案情后一起过。
3. commit `refactor(widget/math): Widget:TintIconBorder + Math:Shorten 名字截断收敛` —— ✅ 完成(c2abb3e)
   - helper:Backdrop 目标 → ApplyBorder(几何一起重建);纯贴图 → 白 texel + SetVertexColor
     (NP 色带从 SetColorTexture 烧色改顶点色,之后主题_changed 可重复重涂,初始仍带驱散色)。
   - UF TintAuraButton / NP DressDebuffButton 已接入。
   - Groups 删字节切 Truncate,`Math:Shorten(raw, cap, true)`(**顺手修 CJK 坏字形 bug**);
     省略号 `…`→`...` 的视觉差接受(与 UF 同源),实机目检确认。
   - 实机目检:团队框名字截断、名牌 debuff 边框颜色(驱散色/主题色)、光环按钮边框。
4. 事件注册骨架不单开:与 P1 迁移一起消化(评估后如仍有大块重复再说)。

## P4 · 长函数拆分(review #5,一个函数一个 commit)

按子件抽 `EnsureXxx(frame)`:

- [ ] UnitFrames `StyleAuraButton`(~159 行)
- [ ] Groups `StyleButton`(~130)
- [ ] Nameplates `DressDebuffButton`(~128)
- [ ] ActionBars `BuildButton`(~128)
- [ ] UnitFrames `CreateUnitFrame`(~126)
- [ ] ActionBars `CreateBar`(~124)
- [ ] ActionBars `AdoptBar`(~107)
- [ ] ActionBars `SkinButton`(~81)

## P5 · 文件拆分(本轮只试水一个,review #2 部分)

**范围:只拆 UnitFrames 的 Auras 试水**(639 行,最大最独立)。其余(UF 其余三个 +
ActionBars 四个)视试水结果下一轮再定。

1. commit `refactor(unitframes): 拆出 Modules/UnitFrames/Auras.lua(.toc 同步)`
   - 主文件先挂共享表(模式照 Minimap/Buttons:`ns:GetModule("UnitFrames")` 取 M,Auras 子文件挂 `M.auras`);
   - 14 个 imports:ns/Mark/Marked/Widget/Media/M/frames/Shared/TARGET_AURA_* ×5 —— 常量整块
     搬去子文件,`frames`/`Setting`/`Shared` 走 M 内部表;
   - 7 个 exports(StyleAuraButton、Ensure/Rebuild/Restore/Stack/Borrow TargetAuras、
     HookAuraRelayout)挂回 M,主文件改经 M 调用;
   - **Move-only**:不碰 `--[==[ ]==]` 注释块,不改行为。
2. 实机验证:目标/焦点光环重排、堆叠、借用、THEME_CHANGED 重刷、进出编辑模式无 oldR 报错。
3. 试水通过 → HANDOFF/TODO 记剩余拆分计划(UF Blizzard/ClassPower/CastBar、
   AB Secure/DragDrop/PetBar/Blizzard处置 = P5')。

## P6 · 收尾

- [ ] `node tools/api-audit.js` 确认 HARD 仍 0
- [ ] 更新 docs/HANDOFF.md 代码地图与"本轮做了什么"
- [ ] TODO.md 勾掉已完成、登记 P5 剩余拆分

## 验证清单(每阶段共用)

- 离线:`tools.wuxian.check`(live:false)0 错 0 警。
- 在线(MCP):deploy-retail.ps1 → reload → 探针/日志 → snap:
  - UF:目标/焦点/宠物框渲染、施法条、光环(排序/堆叠/借用/边框)
  - AB:施法(UNIT_SPELLCAST_SUCCEEDED)、冷却圈、宠物条收养+自动施法像素环、右键切换、
    拖放接住、进出编辑模式 0 报错
  - 通用:`/mui skins diagnose`、Logs/taint.log 为空、无新增 ADDON_ACTION_BLOCKED
    (AGENTS.md 列出的"已知代价"项除外)
- 每步可回滚:小 commit、不顺手改无关代码。
