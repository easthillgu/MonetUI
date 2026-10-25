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

**AuraContainer 生产波案(2026-10-25 02:12–02:45, 实机探针定性)**:
- 症状:`MathUtil.lua:24 / Backdrop.lua:342 "index a table that cannot be accessed while
  tainted"` 1+9 成簇、每几分钟一对;本地 FOUR 个引擎 AuraContainer(UF target buffs/debuffs
  + BuffFrame 战斗 `MonetUICombat{Buff,Debuff}Frame`)池生产中止。
- 取证:池审计 `MonetUICombatBuffFrame kids=20 styled=10 missing=11..20`(整批 batchSize=10
  失格)、`MonetUICombatDebuffFrame styled=0`(唯一批全灭);失格按钮连 `GetChildren` 都被拒
  (ApplyAccessRestrictions 落地)。triggers:第一脱战窗生产的批 OK,受限窗生产的批全挂;
  `:AddAuraGroup(` 全客户端仅我们调用 → 出错池四舍五入就是这四个。
- 根因:我们的 `initializeFrame` 回调(StyleAuraButton / BuffFrame lambda)里 **六处未包
  pcall 的 Create**(`button:CreateTexture` / `CreateFrame("Frame",…,"BackdropTemplate")` /
  `CreateFrame("Cooldown",…)` / `cd:CreateFontString`×2)在受限窗被引擎整体拒绝 → 抛出穿出
  securecall → 生产批次连锁死亡(每带 10 个按钮 × 若干重试 = 错误波);池永远凑不满,战斗
  buff/debuff 行退化。
- 修(3453b10):StyleAuraButton 六处 Create 全 pcall + 失败早退,batch 回调整体 pcall;
  受限窗按钮样式失格(引擎外观兜底),脱战窗照常整样式。
- 关联改判:UF注释"战斗中建容器=空容器"与"引擎按钮之后写region被拒"现象重新归类为
  本案同源(受限窗平台行为一致)。

**本轮回归第二波(2026-10-25 01:51–02:30, c2abb3e reload 后续查)**:
- 早期 `MathUtil.lua:24` ×10 成簇红字:当时判"CauseCounter 闭包族、待[详情]全栈"——
  后续已并入上面的 AuraContainer 生产波案(同一 secure 委托链的另一种 C 封印读失败)。
- `UnitFrames.lua:734 boolean test on field '?'` 红字: `CastInfo` 里
  `channel and result[8] or result[9]` 的 and/or 真值链 —— channel=true 时 Lua 会**真值测试
  result[8]**(受限时是秘布尔),必抛。NP 同款(:709)。修=显式 if 选槽(96c7482)。
  教训: **秘值参与的取值选择禁止 `and/or` 真值链**,哪怕值不会被自己消费。
- taint.log 02:01–02:05 ~4.5万行 = taintLog=2 详细模式把 `Secrets.Bool`(Groups UpdateRange
  经 GROUP_ROSTER_UPDATE 全量刷 ×16 按钮 ×2 处)的**设计内 pcall 拦截**逐次记栈放大;
  功能无损,关 taintLog 即归零。候选优化:RefreshAll 限流。

**收工交接(2026-10-25 深夜)**:taintLog 已关回 0、哨兵已停。下回接手清单:
1. 部署已到位但 **3453b10 尚未 reload 验证**:先点 reload,再正常玩一轮,验收 = MathUtil/Backdrop
   ×10 错误波绝迹 + 池审计(buffs styled=20/debuffs styled=10)恢复 + 战斗 buff/debuff 行正常出图。
   池审计探针:`MonetUICombatBuffFrame` / `MonetUICombatDebuffFrame` kids × `ns:Marked(k,"borderHost")`。
2. **白板 NPC 名牌**仍是未结尾巴(df9efb6 会话首发):复现瞬间跑名牌探针
   (C_NamePlate.GetNamePlates → ours/uf alpha、blizzardHidden、name/level 文本状态) + snap。
3. 回归全结后按 P3.3 遗留目检 → P4(StyleAuraButton 最先)→ P5 → P6。
4. taintLog 哨兵法(需要时重启):`%TEMP%\opencode\taint-sentinel.ps1` 直拷
   `Logs/taint.log`,600ms 一次,分析用 `%TEMP%\opencode\taint.log`。

**配色案落地（2026-10-25,用户口述 + 两轮范围澄清）**:
- 范围澄清轮一("**2 对 3 全覆盖**")与轮二:改动只覆盖**血条颜色**,单位限定
  **玩家 / 队伍 / 团队 / ToT**;**目标框完全不动**;**能量条颜色不改**(不在范围)。
- 实施:
  1. 血条填充 = `monetcolor.edge` 的 RGB 反相(玩家 UnitFrames:FillColor +
     ToT 同源;小队/团队 Groups:UpdateState GetPrimary→GetEdge 反相)。
     "边框=主题反色"结论:LibMonetColor 的 edge 本身就是环境色 HSL 反相
     (ComputeEdgeColor 补色+亮度镜像 0.18..0.82),框体边框现状就走
     edge → 猜想成立,边框零改动。
  2. 空槽 = 暗色织纹底(玩家/团/队/ToT:LostColor→GetNeutral×0.32;
     Groups lost 同款 alpha 1,替换原 danger 红空槽)。BarWeave 发丝线
     叠底之上,既有的织纹资产生效,无需新材质。
  3. ToT:不画能量条与分隔线,血条吸收两行(health+1+power),框体总高不变;
     `frame.power=nil` + UpdatePower 短路nil守卫,UpdateBarLook/SetShown 全有守卫。
  4. ToT 名字自指(目标是玩家自己):`>☆<`,☆ 中国红 #DE2910
     (`>|cffde2910☆|r<`,底色 edge),绕过 AbbrName/Shorten。
- 验证:audit-taint 0 BLOCKER / api-audit 无 HARD / wuxian check 0 错 0 警
  / 已部署。**实机目检待 reload**:血条反色是否与 edge 观感互补、暗织纹
  空槽可读性、ToT 占满后分隔线消失痕迹、自指 >☆< 的字号/字形(☆ 可能走
  回退字体,像素字体可能没有该字形)。

**战斗名字案(2026-10-25,实机:副本里目标/ToT 框体只显示固定"目标/目标的目标")**:
- 根因:UF `UpdateName` 用 `Secrets.CanReadIdentity` 谓词总闸;本客户端战斗窗口该谓词
  (`C_Secrets.ShouldUnitIdentityBeSecret`)误报受限 → 整个名字读取被拦死,退化成 frame.label。
  同窗口**名牌读得到名字**(Nameplates:807 是值级路径)——真实性对照即定案。
- 修(对齐 skill 档"值级判定、谓词不作门槛"):UpdateName 改名牌同款——`pcall(UnitName)`
  读值,`Secrets.IsSecret(name)` 值级守卫,明文才截断上屏;`UnitClass` 同款守卫(读不到
  退 edge 底色)。顺带 `>☆<` 自指分支提前到名字读取之前(UnitIsUnit pcall 包裹),
  机密窗口不依赖名字可读。
- **案翻案(实机探针 7afecfb 后)"未成功"**:探针实证战斗窗口 UnitName 返回的就是
  **机密字符串**(unitName_secret=true,identityPredicate=true 一致;名牌 plate_name_secret
  =true)——名牌显示名字是因为**机密串原样 SetText 进显示控件**(快照:UnitName 标
  "允许污染代码传机密",机密值可展示、不可读)。二版:明文→截断+职业色;机密串→原样
  SetText 显示(不截断/不派生),底色退主题 neutral;读不到→label。Groups.UpdateName
  同案防御:读到机密不覆盖明文缓存(绝不让 DisplayName 的 string.find 碰机密值)。
  判例入档:**战斗中身份类文本的正确解 = 机密串直进显示控件**,不是过滤掉。
- **案二续(ToT 自指,"未成功")**:探针实证战斗中 `UnitIsUnit("targettarget","player")`
  返回**机密布尔**(机密[SecretWhenUnitComparisonRestricted];真值测试连探针都炸,
  正是 UpdateName 的炸点、>☆< 一直没接上的根因)。三版:判定移明文窗 —— pcall+
  `Secrets.Bool(isSelf, 缓存)` 守卫,结果 `ns:Mark(frame,"selfMark")` 旁表缓存
  (框体不写字段),秘值窗**保留上次明文判定**,战斗中新切目标(无历史明文)落回
  名字直显路径。判例 9'' 入 skill 档:**单位对比结果在战斗中是闭锁信息,无明文旁路**。
- 排查同构风险:全仓谓词总闸仅余 `CanMeasureHealth`(UF :653 与名牌 :790 同构、此前
  实机血量百分比窗口正常)——不动,观察。
- 闸门:taint 0 BLOCKER / api-audit 无 HARD / check 0 错 0 警;已部署 + reload 请求已发。
  **实机验证**:战斗中选怪 → 目标/ToT 框体显示真名;**顺手看名牌血量百分比在战斗中
  是否本来就正常**(若同样空白,则 `CanMeasureHealth` 是下一个同构案)。
- **作者拍板(2026-10-25)**:战斗中**不强制** `>☆<` **(后被二定拍板取代,见下)** —— 战斗中首次锁定 ToT=自身且无历史
  明文判定时显示真名,接受现行行为(信息模型边界)。判定缓存只在明文窗生效,三版设计定稿。
- **二定拍板(2026-10-25,终版,推翻上面的"缓存"语义)**:`>☆<` **明文可用才显示 —— 只在
  `UnitIsUnit` 返回明文布尔且为真时显示;判定是机密(战斗窗)就显示真名**(机密串直显,
  能量名路径原样接管)。实现:k 掉 `ns:Mark("selfMark")` 缓存与"保留上次明文判定",
  判断区只剩 `pcall(UnitIsUnit)` + `Secrets.IsSecret(isSelf)` 值级守卫。三版作废,四版
  定稿。skill 档判例 9'' 同步改写(删缓存语义,改"明文判定可用才显示")。

**加密污染审查轮(2026-10-25,skill 档全流程:机械扫描→敏感点人工复核→修复→收档)**:
- 机械闸门复扫:`audit-taint.js` 0 BLOCKER(与基线一致,近三轮 UnitIsUnit/名字改动没引入
  新档);`api-audit.js` 无 HARD;check 0 错(5 条 note = 既有受保护全局清单,PlaceAction
  有 InCombatLockdown 守门)。
- **真违规一例(已修)——`BagFrame.lua:57`**:对暴雪 `ContainerFrame` 直接
  `HookScript("OnShow", ArrangeBags)`。`M:HookShow` 的实现注释正好写着红线原因(往暴雪框体
  脚本槽写函数=标脏,之后暴雪在包裹框上的代码全部记 MonetUI 名下),排查才发现 BagFrame
  自己绕开了这个入口。修:`Widget:ShowWatch` 轮询(旁表+0.2s 轮询 IsVisible,零框体写,
  隐藏→显示瞬间重排一次,行为等价)。
- **22 条 HIGH 逐条人工复盘**(计数与改动前一致,逐文件定性):全是
  (a)自建对象上的 HookScript/`__field` 写(SimpleConfig 面板、自建动作按钮、MonetUI 冷却框、
  MonetUIMinimapDifficulty、微型菜单行、小地图遮罩、自建单位框、buffContainer 节流计数、
  M 模块表的幂等门控、Skins 注册表记录)或 (b)ActionBars 三条**注释文本**误报
  (SETSHOWN-SECURE 把"记录被拦调用链"的文档行当代码)。各行内 `-- TAINT-OK: <原因>`
  收档,21 条豁免 + 1 条真修。
- **基线首次全清**:`0 BLOCKER / 0 HIGH / 0 SOFT`(45 文件)。此后扫描器再报 HIGH=新增
  待审,不达标不带病 commit。skill 档 7 节(闸门用法)同步更新基线描述。
- 复盘中间还确认:`Secrets.SetBar` 三段 pcall 回退(0,100 百分比兜底 + 失败保留上次值)
  符合 Plat;`Ask` fail-safe 语义(缺 API/抛错/受限→按"更严"方向退化)正确;Groups
  `not IsSecret(value) and not value` 的短路次序正确(IsSecret 为真时不评估 `not value`)。
- 观察(不修项):Nameplates `Update` Border 的威胁状态 `Secrets.Number or 0` 在战斗窗
  秘值时退回主题底色而不保留上次状态(UF 侧 :1648 是保留式的);视觉降级非炸点,与
  "nil≠secret"判例半符 —— 有意保留(名牌威胁红边战斗中的体感损失远小于状态机扰动),登记即可。

**分类背包右键案(2026-10-25,用户:"分类包裹内物品无法右键使用")**:
- 实机排查:图标/tooltip 正常 → rec 映射通;日志 0 条 FORBIDDEN → UseContainerItem 没被拒;
  快照+探针确认 `C_Container.UseContainerItem` 存在 → 唯一断点 = Button **默认只收左键**,
  Bags.lua 全文零 `RegisterForClicks`,右键根本到不了 OnClick(调用没发生,不是被拒)。
- 修(参考 EllesmereUIBags.lua:3135 的物品按钮同款):`AcquireButton` 加
  `btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")` + `RegisterForDrag("LeftButton")`
  (OnDragStart/OnReceiveDrag 脚本早已写了但从未注册拖拽,一并补)。
- 闸门:taint 0/0/0(基线保持全清);api-audit 无 HARD;check 0 错。部署 + reload 已发,
  待实机右键复测。

**分类背包收养改写(2026-10-25 第二波,用户复测:"右键点击物品,提示被禁用")**:
- 病因定性:右键确实发生但 `UseContainerItem` 从**我们的执行栈**被调 → 弹"MonetUI 已被禁用"
  (与动作条 action 属性同键模型:**调用链上下文**定了越权,API 本身不保护)。
- 改 EllesmereUIBags_Grid.lua:70-128 / :2238-2291 / :3133 的收养路线:
  - `AcquireButton` → **壳框(BackdropTemplate,`shell:SetID(bag)`) + `CreateFrame("ItemButton",
    nil, shell, "ContainerFrameItemButtonTemplate")`(`btn:SetID(slot)`)**,OnClick/左键抓取/
    拖放/右键使用全走暴雪模板原生上下文;_orders/book 里的 rec/边框状态全入 `ns:Mark` 旁表,
    模板按钮上零自定义字段(Ellesmere "Weak-keyed state" 同款)。
  - **模板按钮战斗中不能出生**(出生即被污染,进本第一次右键就 FORBIDDEN;
    EllesmereUIBags_Grid.lua:72-76 同一结论):`AcquireButton` 在 `InCombatLockdown()` 返回
    nil,`FillWindow` 跳过该名额,脱战后 BAG_UPDATE 自然重排补齐。
  - 视觉分工:Monet 边框/压纹走壳,任务 `!` 与冷却框挂按钮,图标/计数交给模板本体
    (`SetItemButtonTexture` / `SetItemButtonCount` / `SetItemButtonDesaturated` —— FrameXML
    全局,快照查不到但实机存在,`api-lookup` 判不了)。
- **图标"黑方块/斜纹"两连案(用户:"分类背包格子中看不到图标")**:
  - 一修:模板自带美术压平(暗色槽底 `NormalTexture`/`IconBorder` alpha 0、
    `NewItemTexture`/`BattlepayItemTexture`/`flash` 隐藏、`IconMask` 从 icon 蒙列表摘除)
    —— 抄 Ellesmere `ns.SkinItemButton`(:2238-2291,"Methods only",不写模板属性)。
    实机 snap:压平后仍只有一格出图。
  - 探针(暴力解约束对照组)锁定出图四要素:`RemoveMaskTexture` + `SetVertexColor(1,1,1,1)`
    + `SetTexCoord(0,1,0,1)` + `SetDrawLayer("OVERLAY", 7)` → 做成幂等
    **`FlattenSlotArt(btn)`**,`AcquireButton` 建钮时 + `UpdateButton` 每次重绘后都跑
    (SetItemButton* 会把蒙版/顶点色重新带回来)。
- **真正根因(btn 出生即隐藏,三症状一次破):** 父链探针(逐层 IsShown/IsVisible)实锤
  `icon vis=false` 而 btn `shown=false` —— 模板按钮出生即隐藏,我们的 UpdateButton 只
  `shell:Show()`,从没 `btn:Show()`;因果链一次覆盖三个症状:图标黑(钮藏)、**tooltip 失联**
  (钮藏 → OnEnter 不触发)、品质框可见(画在壳上)。**探针教训:之前几轮
  `select(1, pcall(f, ...))` 取到的是 pcall 成功布尔而非返回值,"btn_shown=true"全是假象,
  读返回值必须 `select(2, ...)`。**
- 终修:`UpdateButton` 有物品 `btn:Show()`;空槽 `btn:Hide()`(自建按钮非暴雪生成的受保护
  按钮,Show/Hide 不受战斗限制)。
- **用户实机复测通过**:图标全部显示 ✅ / tooltip 恢复 ✅ / 右键使用+左键拖拽 ✅;
  闸门:taint 0/0/0、api-audit 无 HARD、check 0 错 5 警(基线对齐)。
- 已知取舍:锁定物品的原生去饱和(`SetItemButtonDesaturated(true)` 灰化被 FlattenSlotArt
  白顶点覆盖,只剩壳 alpha 0.4 暗化)——保留点亮路径,下一轮单独处理。

**回归验证轮(2026-10-25,名字案 OK 后的实机收量)**:
- ✅ **3453b10 生产波案验收通过**:600+ 条日志 0 条 MathUtil/Backdrop/taint/secret 家族;
  `MonetUICombatBuffFrame` 池审计 **styled=20/20**(此前 10/20 第二批全灭)。
- ✅ ToT 几何:血条高 6、`frame.power=nil`、无分隔线 —— 配色案落地正确。
- ⚠️ `MonetUICombatDebuffFrame` 池审计 styled=0/10:受限窗生产的整批失格(设计内,受限窗
  样式交引擎外观兜底);下轮围绕 debuff 行出图/边框观感收尾,不算回归缺陷。
- ⚠️ BLOCKED 日志 320 条/17.5 分钟/40 时刻持续生长,`MonetUI UNKNOWN()`:taintLog=2 抓栈
  定性 = `Secrets.lua:83/89 Bool()` 秘值布尔 pcall 拦截(2961 条同类"boolean test on
  secret blocked")——设计内拦截 + 详细日志放大(Groups UpdateRange 族的常态),弹窗无、
  功能无碍,taintLog 已关回 0。登记:高频 `Secrets.Bool` 秘值窗守卫是未来限流/合并判定的
  候选,不属回归缺陷。

**新任务完成:skill 合并 + taint 闸门工具(2026-10-25,接上节交接后)**:
- `tools/audit-taint.js` —— commit 前 taint 机械闸门。规则 15 条(BLOCKER/HIGH/SOFT 三级):
  and/or 秘值真值链(案 96c7482 形)、裸 Create in initializeFrame(案 3453b10 形)、旧冷却接口、
  raw 字段写、SetParent/HookScript/SetScale/Hide 暴雪框、secure 按钮直控、COMBAT_LOG、
  GetCooldownTimes(IsAnchoringSecret 证否的反向提醒)。注释行不扫;`-- TAINT-OK: <原因>` 行内豁免。
  **基线:0 BLOCKER / 22 HIGH(静态分不清自家对象 vs 暴雪对象的人工复核清单,已逐条定性)/ 0 SOFT。**
- `.opencode/skills/wow-secret-value-taint-audit/SKILL.md` —— 两份 Desktop 草稿合并:
  draft2 骨架 + draft1 参考仓库清单;实机修正三处(IsAnchoringSecret 证否 → issecretvalue +
  C_Secrets 谓词;API 签名以 docs/api 快照为准;案 A/B/C 链段 + AGENTS 污染模型速查表入档)。
  opencode 项目级 skill 自动发现/触发已验证。
- 顺手归位:petbar skill 从 `.opencode/skill/`(单数,非文档发现路径)挪进 `.opencode/skills/`。
- 本轮关联 Lua 改动:仅 13 行 `-- TAINT-OK` 注释(BuffFrame 7 / ActionBars 3 / Bags 2 /
  Cooldown 1),无逻辑变化;`wuxian check` 0 错 0 警,已部署。

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
