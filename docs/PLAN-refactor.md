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
2. commit `refactor(unitframes): FrameChrome 单返回值`(UnitFrames:196,唯调用点 :1636)
3. commit `refactor(simpleconfig): LayoutCursor 光标式布局`
   - `local row = LayoutCursor(yStart)`;107 处 `y = y - N` 机械替换,增删行不再手工记账。
   - 逻辑风险 0,diff 大;验证:实机打开设置面板逐页目检(位置应逐像素不变)。

## P3 · 小构件上提(review #4)

1. commit `refactor(groups): PlainBorder 与 EnsureSelectBorder 合并为带参边框构建器`(单文件内,最安全先做)
2. commit `refactor(widget): Widget:LostBarBG(bar, baseColor)` 三处统一(带底色参数)
3. commit `refactor(widget/math): Widget:TintIconBorder + Math:Shorten 名字截断收敛`
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
