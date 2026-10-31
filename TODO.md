# 待办

## 🐞 2026-10-31 战斗/登录相关的背包问题（已修，剩登录复验）

- [x] 战斗里 `/reload` → 背包只有标题、弹「界面行为失效」：`InCombatLockdown()` 登录当拍假 false +
      空窗口指纹不变不重建 + 停车延后在脱战当拍二次延后（`37a19df`，HANDOFF 8.20）
- [x] 暴雪背包脱战后没停车（`alpha=1`，会和我们同屏）：延后回调换新 tick 判断（同一提交）
- [x] 登录时分类背包自动打开：登录先 `Hide()` 暴雪背包并把守卫基线设成"关"（`3e93d5c`，HANDOFF 8.21）
- [ ] **登录复验**：重开客户端后确认分类背包是关着的、按 `B` 只出现我们这一套
      （客户端在验证前退出，探针还没跑）

## 🎨 2026-10-31 视觉语言收口（docs/DESIGN-LANGUAGE.md）

**已落地**
- [x] `docs/DESIGN-LANGUAGE.md`：透明度阶梯 / 颜色槽纪律 / 字号四档 / 点缀四语法 / 与 Aurora 的取舍
- [x] 三个决策拍板并落地：a 通用文字 `neutral`（`highlight` 只给 hover/选中/焦点/自身血条）、
      b 标题线默认关逐窗口开（`TimeManager` 已开，`ruleTop = 26`）、c 阅读型窗口独立一档 `0.965`
- [x] 任务追踪头部两个小按钮"安静化"（平时 0.55、悬停 1）
- [x] 主菜单大字用 `bright`；颜色键收成 `Widget:PaletteColor` 一张表
- [x] 游戏菜单 11 个匿名按钮换皮（按子控件遍历 + `M:HookShow` 补扫）
- [x] 血量颜色设置重排：组名成行 + 12×12 实色块（`UnitFrames:PreviewColor` 与实机同一套函数）

**下一批（按性价比）**
- [x] 标题线逐窗口开（第一批 6 个，实机确认）：好友 / 帮助 / 拾取 / 收藏 / 冒险指南 / 试衣间
      （`b0c1868`；FriendsFrame 实机截图确认线压在标题下方、edge 色 @0.45、1px）。
- [ ] 标题线第二批（窗口要 NPC 或特定入口才能开，留待）：交易 / 邮件 / 拍卖 / 银行 / 任务日志 / 幻化；
      跳过的（标题是空的 1px 区域）：角色 / 检查 / 宏 —— 这几个别硬开，线会落错。
- [x] 背包窗口标题线：已用 `Widget:Rule`（手绘笔触下划线）覆盖，不需要再加发丝线。
- [x] 阶梯表进 `docs/CHECKS.md`：已加「C2 视觉语言验收」一节。
- [x] `Skin:Button` hover 边框用 `highlight`：保持（决策 a 明确合规）。

## 🎨 2026-10-31 视觉语言收口（docs/DESIGN-LANGUAGE.md）

**已落地**
- [x] `docs/DESIGN-LANGUAGE.md`：透明度阶梯 / 颜色槽纪律 / 字号四档 / 点缀四语法 / 与 Aurora 的取舍
- [x] 任务/剧情窗口 `bgAlpha 0.95 → 0.96`（统一到"常规窗口"一档，5 处）
- [x] 任务追踪头部两个小按钮"安静化"（平时 0.55、悬停 1）
- [x] `Widget:BarWeaveDensity` + `Widget:HeaderRule`（标题线，默认关，见下）

**待裁决（需要作者拍板，见 DESIGN-LANGUAGE §7）**
- [ ] a. 通用按钮/静态文字：`neutral`（推荐，任何职业同一副样子）还是让 `highlight`（职业色）渗透？
- [ ] b. 标题线要不要逐窗口开：`M:Dress("X", { window = true, rule = true })`，标题矩形比字形小的窗口要配 `ruleTop`
- [ ] c. 阅读型窗口（任务日志/剧情/书信）要不要单独一档 0.965~0.97

**下一批（按性价比）**
- [x] 游戏菜单 `GameMenuFrame` 的 11 个按钮：12.x 是匿名 + 按需创建的，名单一个都不命中 → 改按子控件遍历
      + `M:HookShow` 补扫（HANDOFF 8.19，实机 44 个红 atlas 区域全部 alpha 0）
- [ ] 背包窗口标题 / 每个背包小标题加"标题线"（我们自己的框，`ruleTop` 好用）
- [ ] 其余 Blizzard 窗口的标题线：按 `TimeManager` 的流程逐个截图确认后开 `rule = true`
- [ ] 把 `docs/DESIGN-LANGUAGE.md` 的阶梯表补进 `docs/CHECKS.md` 的验收清单

## 🔧 2026-10-30 按 review 计划执行（docs/PLAN-refactor-2026-10-29.md）

> 基线提交 `32ac509`（上一轮未提交的皮肤层 + BossFrames 初稿 + BLP 直角版）。
> 之后 17 个提交，每项独立、可单独 revert。三道离线闸门每步都跑：`api-audit` 0 HARD、
> `audit-taint` 0/0/0、`wuxian check(live:false)` **0 error**（基线那 1 条 BossFrames 已清）。

**P0 已完成（全部代码项）**
- [x] 0.1 堆叠数改用字符串（`GetActionDisplayCount` 返回 string，以前判 number 所以从没显示）
- [x] 0.2 `showHotkey` / `showCount` / `showMacro` 三个开关接线（以前全仓无读取点）
- [x] 0.3 暴雪经验条改 alpha 0 接管 + `InfoBar` 装饰新增 `remove` 钩子还原
- [x] 0.4 `Bags` 的 `RestoreDragged` 前置声明 + 降级补扫一次性注销
- [x] 0.5 `Bags` 压守卫让开战斗、`EnableMouse` 加 pcall、间隔 0.05→0.2
- [x] 0.6 追踪按钮父框改 alpha 0 接管并还原；修徽章还原读错字段
- [x] 0.7 **不再覆写暴雪 `Minimap` 的 `OnMouseUp`**（覆盖层本来就独占左右键）
- [x] 0.8 `Color:RoleTint` 过 `Secrets.Bool`
- [x] 0.9/0.10 `Mover`：机密缩放守卫 + 受保护框战斗内排队
- [x] 0.11 `/mui reset` 就地清空 + 补默认值 + 二次确认
- [x] 0.12 登录主题刷新失败不再挡住 `StartModules`
- [x] 0.13 `EventBus` 派发前快照 + 注销即退引擎注册
- [x] 0.14 复核：`ButtonMaterial` 无条件 `HookScript("OnSizeChanged")` 属实（会套到暴雪按钮上），已改名字门控 + 轮询
- [x] 0.15/0.17 BossFrames 改 `SecureUnitButtonTemplate`（`*type1=target` / `*type2=togglemenu`）+ 导出 Groups 样式件
- [x] 0.16 姓名板仇恨状态机密时保留上次判定（战斗中红边不再闪灭）
- [x] 0.18 裸测 `IsShown()` 全部过 `Secrets.Bool`
- [x] 0.19 `UnitClassBase` 先判机密再给 `ClassColor`
- [ ] 0.20 **取证**：`Blizzard.lua` 的 `OnShow + Hide` 压制方式是否仍必要（要开游戏跑 `taintLog=2`）

**P1 已完成（净删约 640 行）**
- [x] 1.1/1.2 `Cooldown`：旧钩子路径（`OnCooldownStart` / `OnSetHideCountdownNumbers` / `EnsureHooks`）
      + 对自建按钮从未生效的图标染色（`TINT` / `IsUsable` / `InRange` / `UpdateState`）
- [x] 1.3 `BuffFrame` 的 `RebuildCombatAuras`（零调用，且违反"绝不重建容器"判例）
- [x] 1.4 `ActionBars.BuildButton` 的宠物条死分支 + `InstallDrag` 的 `isPet`
- [x] 1.5/1.6 旧"接管整条暴雪条"路径 282 行 + `ADOPT_EVENTS`（13 个事件指向 no-op）
- [x] 顺手修：`PetBar` 的自动施法像素环被 `STYLE_ADOPTED_BARS=false` 静默关掉了 —— 已恢复
- [x] 1.7 `Trade.lua` 重复文件头、`HookPin`→`TrackPin`、死 `SetHover`、`QuestTracker` 重复注册、`luac.out`
- [x] 1.8 过时注释（HookScript / actionpage / RegisterActionUIButton）、版本号、`%dxxd`、`Media` 文档错位

**P2 部分完成**
- [x] 2.2 `HoverWatch`/`ShowWatch` 多监听 + 三表弱键 + 统一 `Unwatch`
- [x] 2.4 `Media:Mult` 缓存（`UI_SCALE_CHANGED` / `DISPLAY_SIZE_CHANGED` 失效）
- [x] 2.7 `EventBus` 混用 `Register`/`RegisterUnit` 的防御
- [ ] 2.1 统一 OnUpdate 调度器（约 52 处驱动）
- [ ] 2.3 `ns.Mark` 下沉到 Utils，删 20 份包装
- [ ] 2.5 `FitText` 闭包 / `SetBorderState` 临时表 / `ROUND_SLICE` 单一来源
- [ ] 2.6 `Skin.tinters` / `Skin.added` 注销句柄；`ScanScrollArrows` 限频

**P3–P7 未开始**（配置面板拆分、ActionBars 拆分、皮肤声明式、单位框共享件、资产决策）

**必须实机复核的清单（这一轮改动都在这几条上）**
1. 动作条：堆叠数字（可堆叠药水/材料）、热键/宏名开关、宠物条像素环（右键开自动施法）。
2. 小地图：左键打标记 / 右键菜单 / 中键追踪菜单（0.7 删了脚本覆写）；追踪按钮开关来回切。
3. 信息栏：暴雪经验条不再闪；关掉 InfoBar 模块后暴雪经验条回来。
4. 背包：拖过的窗口位置；QuestTracker 出现后背包贴回正确位置；战斗中开背包无 BLOCKED。
5. 姓名板：战斗中红边不闪灭、脱战后正常消失；目标金边/放大。
6. 首领框（BossFrames）：有首领目标时出现、左键选中、右键菜单。
7. 按钮三态：悬停高亮 / 按下 / 禁用变暗同时生效（HoverWatch 多监听）。
8. `/mui reset` 现在要 `/mui reset confirm`。
9. `Logs/taint.log` 与 `ADDON_ACTION_BLOCKED` 计数对比基线。

**已知遗留（本轮未动）**
- `test-mult.js` 3 条、`test-skin-lua.js` 42 条断言在**基线就是红的**（和本轮改动无关），
  说明这两个静态测试已经跟当前代码脱节，需要单独一轮对齐。
- `Assets/Textures/monet_barfill_gradient.blp` 是未跟踪的孤儿贴图（没有 TGA 源、Media 也没注册）。


## 📦 交付状态（2026-10-29 收口）

- **交付分支 `square-blp@44a4334`（直角版 BLP）**：四处 `Widget:Theme` 去掉 `round`、遮罩 `rx=0`、
  32 张 BLP 重出为 `enc=3 alphaDepth=8 alphaType=8 mips=1`。已部署到 `WOWFOREVER` 客户端,
  待实机确认:直角 / 图标透明 / 遮罩裁切 / 斜纹。
- `main@6e233ed` = **r=8 圆角留档**（背景改 9-slice 的正解 + 遮罩 rx=6 + 填充生成器改有符号距离），
  视觉未通过,未交付;要重试从该提交起。
- **BLP 头必须自查**:raw3 带透明 = `enc=3 alphaDepth=8 alphaType=8 mips=1`。
  `wow-blp-web` 默认写 `alphaType=0`,客户端会把整张图当不透明（图标变实心方块、遮罩不裁切）。
- 待办:
  1. 把 `tools/` 三处改动同步到 Debian（`tools/tga-to-blp.js` 的 alphaType、`tools/regen-textures.js`
     的填充公式、`tools/svg/minimap_rect_mask.svg` 的 rx=0）—— `tools/` 不进库,只能手工带。
  2. 实机确认后由作者决定是否合并到 main / 推送（runbook:上线前不 push）。
  3. 可选加固:把 `alphaType=8` 的检查加进 `tools/sync-check.js`,让门禁自动拦住同类回归。

## ⏭ 下一轮队列（2026-10-26 起，压缩上下文后的接续点）

> 承接 `docs/PLAN-refactor.md` P5' 与 `docs/CODE-REVIEW-2026-10-24.md` 第 2/3 条。
> A 段全部离线可做；B 段要开游戏；C 段等你拍板。

**A. 文件拆分收尾（P5'）** —— 一块一个 commit、`move-only`、机械 diff 核对、拆完三道闸门 + `sync-check`

1. ✅ `UnitFrames/ClassPower.lua`（146 行 move-only，`f72ec5e`）：主文件 1186 → 1044；
   接口 `M.classpower.*`，资源色表经 `M.POWER_COLOR` 共享。
2. ✅ `UnitFrames/Blizzard.lua`（89 行 move-only，`4fd510d`）：主文件 1044 → 958；
   仍是 `M:SuppressBlizzard` / `M:HideBlizzardCastBars` 两个方法，调用点零改动。
3. ✅ `ActionBars/Secure.lua`（安全片段生成与注入 —— 全仓最敏感的一段，`f98ccf3`）：
   146 行 move-only，主文件 1780 → 1677；接口 `M.secure.*`（ON_STATE_PAGE / VISIBILITY_MAIN /
   VISIBILITY_OTHER / FULL_PAGE / EXIT_SNIPPET / InstallPageChild / InstallSecureInit /
   PushSecureInit / PushPageToChildren / SetUseOnKeyDown）。状态驱动条件串随片段一起搬
   （它们是 RegisterStateDriver 注入的半边）；`SlotFor`/`SlotOf`（槽位算术）留在主文件。
   机械核对：删的 100 行 = 77 原样 + 10 调用点改名 + 1 注释指向 + 12 空行，零意外改动。
   实机回归通过（2026-10-28）：施法 / 翻页 / 拖放 / 宠物条自动施法环。
4. ✅ `ActionBars/DragDrop.lua`（122 行 move-only，`528b388`）：主文件 2416 → 2297；
   接口 `M.dragdrop.EnsureDropCatcher`，`SlotOf` 经 `M.SlotOf` 共享。**已部署待实机验**（拖放）。
5. ✅ `ActionBars/PetBar.lua`（宠物条收养 + 自动施法环，`3e3bd40`）：290 行 move-only，
   主文件 2264 → 2029。输入 = 主文件尾导出的 9 个共享件（`ButtonSize`/`Spacing`/`PositionBar`/
   `SkinAdoptedButton`/`STYLE_ADOPTED_BARS`/`ResolveContainer`/`bars`/`adopted`/`PET_DEF`，同名别名接走
   所以搬走的函数体一行没改）；输出 = `M.petbar.BuildPetBar/SyncPetGlow/SyncPetGlowNow/TeardownPetGlow`。
   机械核对：删的 245 行只有 5 行不是原样（5 处调用点改名）。闸门全绿。**已部署待实机验**。
   ✅ 顺手账已清（2026-10-28，`e4e50cd`）：`RefreshPetContent` 全仓零调用点（自绘宠物条
   拆掉后的遗留），单独 commit 删除 58 行，实机 0 报错。
6. ✅ `ActionBars/Blizzard.lua`（暴雪条压制/收养/归还的"压制/归还"这一半，`61b5842`）：
   284 行 move-only，主文件 2519 → 2264；接口 `M.blizzard.Park/ParkBag/Restore`，
   `M:ParkBlizzard` / `M:RestoreBlizzard` 搬到新文件（仍是模块方法，调用点零改）。
   机械核对：删掉的 263 行只有 3 行没原样出现（1 行注释指路 + 2 处调用点改名）。
   闸门全绿（check 0 错 5 警基线、api-audit 无 HARD、taint 0/0/0、sync-check 同步）。**已部署待实机验**。
   注：剩下"收养/归还"（`AdoptBar`/`ReleaseBar` 那一套）仍留在主文件 —— 它和宠物/姿态两条的
   换皮、排布缠在一起，等 `PetBar.lua` 拆完再定归宿。
7. ✅ 已拆：`UnitFrames/Auras.lua`（`fbf7bd4`）、`UnitFrames/CastBar.lua`（`6d685bf`）

**A2. 实机回归结果（2026-10-26，德鲁伊 21 级）**

- ✅ 施法条红三角 / 进战斗 / 进出编辑模式：用户确认 OK，本会话 0 ERR / 0 BLOCKED，
  `errors` 档案当天 0 新增，`taint.log` 未被写。
- ✅ **姿态条不见了 → 已修**（`8d4ab87`）：`AdoptAll()` 把没被接管的 `StanceBar` 压成了
  alpha 0（10-24 起就有），删掉那记 `GhostBar` 即恢复原生显示。详见 `docs/HANDOFF.md` 3.8。
- ✅ **姿态条改成"收养"**（`816c320`）：`StanceButton1..10` 搬进自己的 `MonetUIBarStance`、
  与宠物条同一套换皮，施法走原生 `CastShapeshiftForm`。位置：3 号条正上方、左对齐。
  宠物条移到 1 号条下方、右对齐，并**悬停才显示**（`74a8ad6`，配置面板可关）。
  ✅ **三形态实机点击已验**（2026-10-28 玩家确认）：施法正常。
- ✅ **悬停显隐三项 + 宠物条空槽底色**（`08ce74e`）：宠物单位框"悬停/选中才显示"、宠物条与姿态条
  "平时 alpha 0.3 / 悬停 1"、收养按钮补空槽 well；三项都进设置菜单。探针已核对
  `MonetUIBarPet/BarStance alpha=0.302`、`MonetUIPetFrame alpha=0`、`PetActionButton8` well `shown=true`。
  ✅ **实机效果已验**（2026-10-28 玩家确认）。
- ✅ 拖放 / 姿态翻页已验（2026-10-28，Secure.lua 拆分回归一并过）；切主题后光环边框颜色也已验
  （2026-10-28，`/reload` 后跟新主题，符合容器不重建的预期）。
- ✅ **转正 + xml 加载清单**（2026-10-26，见 HANDOFF 3.11）—— 实机验收通过：启动 `17/17 个模块`，
  说明 toc → xml → `.lua` 这条链每份清单都被客户端读到了。仓库已改名 `MonetUI`，旧版留 `MonetUI-archive`。
- ✅ **姓名板去光环 + 目标金色/1.1 倍**（2026-10-26，见 HANDOFF 3.12）—— 实机验收通过：
  牌子不显示任何光环；切目标金边 + 放大跟得上。（点击区没放大是刻意的，玩家没提意见。）
- ✅ **鼠标提示重做**（2026-10-26，见 HANDOFF 3.13/3.17/3.18/3.19）—— 实机验收通过：
  每帧跟随、三摆法（跟随 / 小地图右上角 / 暴雪默认）、1px 主题色边框、右/上边缘翻转、
  **按住 Alt 一直显示 ID**、位置不乱跳。
- ✅ **施法条三角 / 经验线三角改手绘贴图**（2026-10-26，见 HANDOFF 3.14/3.15）—— 实机验收通过：
  施法条尖端顶在能量条下沿、经验线尖端顶在线的上沿。
- ✅ **连按 B 两套背包同时出现**（2026-10-26，见 HANDOFF 3.22）—— 实机验收通过。
- ✅ **Pawprint 观感对比**（2026-10-26）：外部插件，只为对照，结论是"我们的自绘风格可以，不跟换"。
- ⏸ **`ADDON_ACTION_BLOCKED MonetUI UNKNOWN()`（暂缓，玩家 2026-10-26 说先不管）**：
  两次记录的时间戳形状完全一致 —— 重载后约 14 秒第一条，再过 10 秒「5 more times」共 6 条
  （06:21:41/06:21:51 与 06:30:52/06:31:02），无伴随 Lua 错误。`taintLog=2` 下
  `Logs\taint.log` 写 **0 字节**（AGENTS 记过：本客户端对 `ADDON_ACTION_BLOCKED` 零记录），
  所以只剩两条路：装 `ADDON_ACTION_BLOCKED` 事件钩子取 `debugstack`（已试装，需在重现窗口内、
  期间不能 `/reload`，否则钩子随 Lua 状态消失），或配置级二分（`ns:DB().modules` 逐组关 → 重载）。
  嫌疑面：最近两个 commit 碰过的 `SetPetAlpha`/`ApplyPetHover`（安全单位框）、`SetupHoverOnly`、
  `PositionBar` 的姿态分支、catcher 的 `EnableMouse` 轮询、姿态条 `RegisterStateDriver`。
  另注：该会话启动打印是 `16/17 个模块`，重现那次是 `17/17`，中间有模块迟到初始化，也可能相关。
  恢复调查时从这里接着走。

**B. 需开游戏（攒着一起验）**

- ◑ **战斗辅助改向（2026-10-27，见 HANDOFF 3.25）**：进出战斗剑+盾+大字提示与主题配色已实机
  验（迁移 v6/v7 生效、动画跑完、构图配色正确、重载后 0 错、`taint.log` 零 MonetUI 记录）。
  **战斗数字区域偏移功能已撤销** —— 实机证明往 `CombatText.textLocations` 写值会污染暴雪的
  机密比较（`CombatText.lua:364`），按"涉及机密值则不改"整段移除（SCHEMA 7 删 `area` 键）。
- ✅ 两天改动一次性回归（2026-10-28 收口）：动作条施法/翻页/拖放、宠物条自动施法环、
  单位框血条与文本、进出编辑模式——全部实机验过；`Logs/taint.log` 收尾查证见下。
  ~~姓名板减益~~ **功能取消**（2026-10-28 玩家拍板：姓名板不显示减益维持现状，不再验）。
- ✅ `BuffListFrame`（冰冻陷阱那类减益）钉在牌子右端 —— **已修**（2026-10-28）：根因是暴雪
  姓名板没被压干净（两层：base 级 sibling 容器漏网 + 目标高亮把 UnitFrame alpha 重设回 1
  后无人回压），详见 HANDOFF 3.28。
- ✅ 姿态条外观已统一（`816c320` 收养 `StanceButton1..N`），代价同宠物条（每 reload 几条
  `StanceButton*:SetShown` BLOCKED 噪音，只进日志）。

**C. 等拍板**

- ⏳ 暴雪队伍/团队框重复：A 共存 / B 关自绘 Groups / C 自动藏（C 有污染风险）。
- ⏳ SpellFlyout 弹出托盘：鼠标点击只能看，选项必须走快捷键（客户端限制，已实测）。

**D. 素材交付（2026-10-28）**

- ✅ 31 张纹理全部出 BLP2（raw3）+ **完整 mip 链**（此前 `mipmaps:false` 是交付缺陷）、逐级白衬底修正、
  滤波 triangle、剔除 raw3 用不到的 1024B 调色板块；TGA 源迁到 `Assets-src/Textures`（进 git、不发行），
  `Assets/Textures` 只剩 BLP（进游戏）。对照页：`node tools/make-blp-compare.js`
  → `docs/texture-preview/blp-compare.html`。
- ✅ 清理死素材 6 张（`monet_canvas_weave` / `diagonal_weave` / `minus` / `plus` / `search` /
  `win_restore`）：文件 + Media 注册键 + regen 生成器 + audit 判定名单一并移除；3 个 `*_blp` 别名键与
  `Widget.lua` 的 `blpKey` 死字段也删了。
- ✅ 照 Andromeda 的画法重画一轮（2026-10-28）：斜纹（渐变剖面）、图标字形几何（笔画 12.5% / 字形 88%）、
  role 三张（实心剪影 + 渐变 + 内压暗）、关闭钮三态（SVG 加粗）、小地图三徽章（加粗简化）。
  前后对照：`docs/texture-preview/glyphs-before-after.png`、`svg-glyphs-before-after.png`。
  审计侧同步修了一处误报：45° 粗笔画交汇处的零星半透明像素不再判"软边未对齐"（改为中段多数发虚才算）。
- ⏳ **待实机验收**：BLP 与 TGA 在本客户端是否显示一致（尤其 9-slice 边框、`IconTexture` 图标、
  小地图矩形遮罩 1:1 映射）——现在游戏里只有 BLP，这条验完才算收口。
- ⏳ **待拍板**：是否给低风险贴图单独换 DXT5 省体积（TGA 1159KB / BLP 1548KB → DXT5 423KB，但
  21/31 张 mip0 最大色差 >16，发丝线/笔触会明显受损）。

## ✅ 2026-10-26 P4 长函数拆分收尾（纯重构，离线验收，待实机回归）

> 来龙去脉写在 `docs/HANDOFF.md` 3.6 节与 `docs/PLAN-refactor.md` P4 节；一个函数一个 commit。

1. ✅ `ActionBars.BuildButton` 126 → 62（`4780b91`，`EnsureFlyoutMixin` / `EnsureButtonTooltip`）。
2. ✅ `ActionBars.SkinButton` 79 → 11（`9f19c8c`，Icon / Fonts / Cooldown / Feedback 四个子件）。
3. ✅ `ActionBars.AdoptBar` 100 → 63（`d616e35`，记录 / 量基准 / 受保护写三段）。
4. ✅ `ActionBars.CreateBar` 123 → 71（`f7fe0a7` 抽 `BuildPetBar`）+ 删死代码（`8b43996`）。
5. ✅ `UnitFrames.CreateUnitFrame` 137 → 48（`e2283e9`，Bars / Texts / Finish 三段）。
6. ⏳ **实机回归**：动作条施法/翻页/拖放、宠物条自动施法环、单位框血条与文本、进出编辑模式。
7. ✅ 记：`wuxian check` 按 addon 名查的是**已安装副本**，校验源码要传仓库路径（HANDOFF 第 0 节）。

## ✅ 2026-10-26 "昨天的修改没读取到"（归因已更正）

> 详见 `docs/HANDOFF.md` 3.7 节（含三条可重跑的取证）。

1. ✅ **先修正自己的误判**：当天上午据 `wuxian history` 最后版本 v23 = 10-25 16:11 写下
   "昨天 16:11 后 8 个提交从未部署"——**错的**。`wuxian history` 只记录 `load`/`checkpoint`，
   普通部署 + `/reload` 不建版本。
2. ✅ **真实取证**：昨天 `deploy-retail.ps1` 最后一次 **21:15:13**；`Logs/General.log` 是
   10-25 **15:42:29 → 21:18:56** 一段连续时间轴（整晚没重启）；新增的 `CastBar.lua` 的 nil
   报错在 18:54 实机出现 → 新文件确实被 `/reload` 加载。
3. ✅ **仍然是好工具**：`node tools/sync-check.js`（MISSING / STALE / EXTRA，不同步退出码 1），
   已写进 CHECKS.md 的 B 段与 HANDOFF 第 0 节标准动作。
4. ⏳ **待用户指出具体现象**："哪一项行为/哪一个像素还是旧的"——拿到具体项再沿
   `sync-check` → `/reload` 后 `logs` → 该模块探针 追，不再笼统归因部署。
5. ⏳ 下次开游戏是一次性验证**两天全部改动**（昨天 8 个提交 + 今天 P4 的 5 个提交），
   出错按"先二分模块、再看 taint.log"的老路走。

## ✅ 2026-10-24 污染链收尾批次（已实机验证，全是本地 commit，未推远端）

> 来龙去脉写在 `docs/HANDOFF.md` 第 3 节；硬规则沉淀进 `AGENTS.md`。

1. ✅ **编辑模式 `oldR` 报错**（`e099cc4`）—— 根因是小地图模块覆写 `MinimapCluster.IsInDefaultPosition`
   骗编辑模式，整条 `EnterEditMode` 栈被记成 MonetUI。现在集群一个字节不动，只把 `Minimap` 帧搬进
   `MonetUIMinimapHolder`（Ellesmere 在本客户端的做法）。
2. ✅ **姓名板成片机密值报错**（`c09867e`）—— 去掉 `hooksecurefunc(NamePlateDriverFrame, "UpdateNamePlateOptions")`，
   改轮询 `C_NamePlate.GetNamePlateSize()`；驱动一脏，它建的每块牌子都脏。
3. ✅ **页签全局钩子**（`af05939`）、**暴雪小队/团队框完全不再碰**（`99009c3`/`0ba783a`/`34a6efb`）、
   **最后一批脚本钩子**（`f91ade1`）。
4. ✅ **`Widget:PollWatch` 一个框只能挂一个回调**（`6db19dc`）—— 四个模块都挤在 `UIParent` 上，
   后注册的静默顶掉先注册的；已改成多回调。
5. ✅ **暴雪冷却管理器**（`Essential/Utility/BuffIcon/BuffBar` CooldownViewer）收掉（`6db19dc`）。
6. ✅ **暴雪任务追踪框**压制：LoD 晚到 + 加载时换对象 → 多时机补藏（`ef0158c`）；
   `Hide()` 会和它自己的 `Show()` 打架（一闪一闪）→ 改 `alpha 0 + 关鼠标`（`0ff4a4a`）。
7. ✅ **buff/debuff 时间显示像乱码**（`36b7280`）—— `GetCooldownTimes()` 是**毫秒**、`GetTime()` 是**秒**，
   算出 568 天；已修 + 加"剩余 > 30 天当读不到"保险。
8. ✅ **debuff 整行隐形**（`36b7280`）—— debuff 行锚在空的 proc 行（0×0）上，`GetLeft()` 返 nil；
   改成按实际行高自己算落点。
9. ✅ 暴雪 `BuffFrame/DebuffFrame` 的收起方式改 `alpha 0 + 关鼠标`（原写法写脚本槽 + 注销事件 = 污染）。
10. ✅ **`ADDON_ACTION_BLOCKED UNKNOWN()` 族根治**（2026-10-25）—— 实测是两类：①对机密值做布尔测试
    （发源 `Groups.lua:520/521`，另 `UpdateState`/`UpdateHealthText`/`SyncSelection`/`UpdateCast`），
    改**值级 `Secrets.IsSecret` 前置**；②**自建引擎 AuraContainer** 的渲染驱动被拦（×2/×15/×29 = 按钮批次），
    整条路线停用。诊断只认新增的 `Secrets.BoolBlocks()` 自证账本（taint.log 对这类零记录）。
11. ✅ **战斗中玩家 buff 空白**（2026-10-25）—— 引擎容器两条死路（换肤→新 proc 无图标；不换肤→全空白），
    战斗中改用**暴雪原生 Buff/Debuff/TempEnchant 框**（alpha 0/1 切换），proc 即时上屏；实机验收通过。
12. ⏳ **暴雪小队/团队框与自绘框重复**（2026-10-25）—— 编辑模式关可见性保存后重载仍显示，
    判为 16001 客户端 EditMode 可见性接线断；选项 A 共存 / B 关自绘 Groups / C 带风险自动藏（不推荐），**待作者拍板**。

## ✅ 2026-10-18 修复批次（离线验证完成，待实机复核）

1. ✅ `Utils/EventBus.lua` — `Unregister`/`UnregisterAll` 递减 `unitSets` 引用计数；归零收缩 `RegisterUnitEvent` 过滤集，全空则整体注销并清 `registered`（新增 `ResyncUnitFilter`）。
2. ✅ `Modules/Bags/Bags.lua` — 删除从未接线的 `pool`/`ReleaseButtons`（按钮本就按 `win.buttons` 每窗缓存复用，无泄漏）与未用常量 `BAG_BACKPACK`/`ACCOUNT_TABS`（切片 2 账号银行页 bagID 15–23 用时再加）；`AcquireButton` 展平。
3. ✅ `Modules/Nameplates/Nameplates.lua` — `UpdateHealth` 5 处 unit 调用全部过 `Query`；查询失败跳过 `SetBar`（保留上次状态，防 nil 把范围打到 0–100）；断连查询失败按"已连接"处理（`Bool(nil,true)` 原会错算为断连）。
4. ✅ `Utils/Skin.lua` — CloseButton 改冒号调用（hated-wow 证据：暴雪 2871 个实装 Lua 文件点号调用 0 处）；删只写不读的 `__monetThumbHover`；`Skin.added` 逐点核对**全部有缓存守卫、开关不重复登记，判定无缺陷未改**。
5. ✅ `Core.lua`/`Config/SimpleConfig.lua` — 删死配置 `theme.tintBlizzard`；面板 `MODULE_ORDER`/`MODULE_LABEL` 补 `Bags`（分类背包）；`UnitSetting` 改 `~= nil`（`false` 可存）；OnHide 挂钩加 `__monetHideHook` 幂等守卫。

## 工具

- ✅ hated-wow-mcp 已接入 `opencode.json`（20 工具）：forever API 索引随包可用；Blizzard UI 源码已同步（4481 文件/349 包）。分工：**wuxian 管实机，hated-wow 管离线查证**。
- 游戏数据（FileDataID/图集）未建；需要时先开浏览器访问 wago.tools 过反爬，再 `npx -y hated-wow-mcp sync game-data`。

## 实机验证清单（游戏上线后）

- 材质：MULT 边框恒 1 物理像素；柔影方向（渐变反了会像外发光）；呼吸节奏；角饰/笔触位置。
- 背包：`/mui bags` 平铺、银行页、tooltip 品质光晕、品质边框（灰/粗糙归暗、任务琥珀）。
- 任务追踪：256 宽换行、3 行硬切、折叠按钮、暴雪追踪器压制；`GetQuestObjectives` 字段（进度不显示回报字段名）。
- 本批修复：反复开关皮肤模块确认 `added` 无重复；受限状态姓名板血条保留上次值；配置面板"分类背包"勾选框生效；多开配置面板关闭无异常。
- 小控件：滚动条拇指材质/悬停提亮；滑条（首个实例出现时）。
- **UI 缩放（2026-10-20）**：`/mui scale` 报"1 UI 单位 = N 物理像素"，N 必须是整数
  （1080p/1440p 期望 1、4K 期望 2）；若 1440p 的首选值 0.5333 被客户端夹成 0.65，
  面板会退回 1.066667（2 像素/单位），要确认实际生效的是哪一档。拉一次游戏的缩放滑块，
  应当自动切成"跟随游戏设置"且不再抢。
- **小地图形状（2026-10-21 只留遮罩一套）**：可见带与面板四边对齐（每边 4）；上下被裁的
  33px 带子里不出现任何东西；把设置里的 `rotateMinimap` 切一次，形状**保持矩形**
  （`/mui minimap diagnose` 的"客户端重设遮罩的钩子"一行应为已安装）；装了 HBD 系插件时，
  带子里的 pin 不再浮在面板外（diagnose 的"第三方 pin"一行应报 HBD 已接入），地图内靠近
  上下边缘的 pin 仍正常显示；若 diagnose 报 `HybridMinimap 已加载`，地图应仍是矩形
  （四角不该被啃成圆）；有任务区域的图上，蓝色区域里不该再出现圆形的"华夫饼"环（blob ring）。
- **单位框（2026-10-20）**：生命条 4px 后的观感；条的**缺失段与能量条空段**能看出织纹
  （1–2 物理像素的织纹本来就只是"细缝线"，别当渲染错误）；圆角面板（小地图 / 任务追踪）
  的边框宽度与其它平边框一致（钉住缩放后应为 0 差）。

## 已决

- ✅ 2026-10-20 **方形四角死区**（`docs/MINIMAP-GAP-ANALYSIS-2026-10-19.md` P0-2）—— 覆盖层
  `MonetUIMinimapOverlay` 铺满**可见区**（不是整个 256×256 画布：上下那两条已被遮罩裁掉，
  落在那儿的位置地图上并不显示）：滚轮缩放、悬停（区域名）都够得到四个角。
  **左键也由它接管**：暴雪的 `MinimapMixin:OnClick` 只在点击落在**圆内**时才 `PingLocation`
  （那个判断是给圆形小地图写的），方形皮肤下四角会被判成"点在圆外"而什么也不做；覆盖层照抄
  它那套坐标换算，自己调 `PingLocation`，四角也能打标记。为了不让暴雪那条路再打一次标记，
  `Minimap` 的 `OnMouseUp` 被换成只放行中键的版本（还原时放回原脚本）。
- ✅ 2026-10-20 **`GetMinimapShape` 全局写**（`Minimap.lua` 2 条 `global-write` 警告，原"未决"项）
  —— **决定：保留，但改成"存在才覆写"**。
  证据：客户端 API 手册（2026.10.17.1）与暴雪 4481 个实装源文件里都查不到 `GetMinimapShape`
  —— 本客户端（Interface 16001）**根本没有**这个全局；平时没人读（装了 HBD 系插件的 pin
  代码时才有人读，见下）。
  现在只在 `type(_G.GetMinimapShape) == "function"` 时才覆写，关闭模块时把原值放回去。
  那两条 `global-write` 是**静态**告警（代码里确实有写全局的语句），不是运行时行为，在 16001 上是惰性的。
  保留的理由：万一第三方插件自己定义了这个全局（零售小地图插件常这么做给别的插件用），
  方形的答案能让那些按钮落在矩形里而不是圆外。
  代价与注意：我们报的是 "SQUARE"，而可见地图是 256×190 —— 第三方按钮若落在
  遮罩被裁掉的带子里就看不见（顺带一提：HBD 的 pin 代码**确实读**这个全局，
  `minimap_shapes["SQUARE"]` 让它按矩形边界算位置）。
- ✅ 2026-10-21 **小地图形状只留一套（遮罩裁剪），`resize` 档已删除** —— 不再有
  `MonetUIDB.minimap.shape`：画布固定 256×256 + `minimap_rect_mask` 裁掉上下各 33，
  可见 256×190。`Core.SCHEMA` 升到 5，老库里的 `shape` 键被清掉。
  理由：外部证据表明**非正方形 `SetSize` 是把正方渲染拉伸**（WoWInterface 老帖里 184×88
  的小地图被拉长、草药点对不上；Reddit 同结论；ElvUI-WindTools 的 `RectangleMinimap`
  从不改画布、只换遮罩）。既然拉伸无法在本客户端排除，就不留一条"可能纵向压扁 26%"的
  代码路径。代价是上下各 33px 的世界信息看不见：引擎 blip 吃遮罩、不用管；HBD 的 pin
  由 `Pins.lua` 压掉（见下）；任务/考古的 blob ring 由 scalar 0 收掉（见下）。
- ✅ 2026-10-21 **`UpdateMinimapConfig` 钩子** —— 客户端每次改小地图形态都会走它
  （`Blizzard_Minimap/Camelot/Minimap.lua:31`：`rotateMinimap` 的 CVar 回调注册在
  96-99 行），里面 `minimap:SetMaskTexture(圆形图集)`，并把 container / backdrop /
  compass `SetSize` 回默认 —— 我们的矩形遮罩会被换掉，要等下次换区域才恢复。
  现在 `hooksecurefunc(MinimapCluster, "UpdateMinimapConfig")` 把重套皮排到下一帧
  （不在客户端自己的调用栈里改帧），`Restore()` 调它时用 `restoring` 旗跳过；
  战斗中照旧走 `Queue("skin")`。`/mui minimap diagnose` 新增该钩子的安装状态。
- ✅ 2026-10-21 **`mask` 档的第三方 pin 裁剪（`Modules/Minimap/Pins.lua`，新文件）** ——
  HBD 的 pin 挂在 `Minimap` 上、不吃遮罩，按画布 256 算位置（半高 128、边界 0.9），
  所以会落在离中心 95–115 的带子里、浮在面板外。
  做法：`LibStub("HereBeDragons-Pins-2.0", true)`（没装就整段空转）；hook
  `AddMinimapIcon{World,Map}` + 扫 `minimapPins`/`activeMinimapPins` 发现 pin；
  判据用 `GetPoint(1)` 的 `offsetY`（HBD 锚成 CENTER←Minimap:CENTER）对
  `VisibleHalfHeight()`=95；压 alpha 而不是 `Hide()`（HBD 每次先 Show 再 SetPoint，
  Hide 会被推翻），并 hook `SetPoint`/`Show` 重算、hook `SetAlpha` 挡住别人淡回来。
  原 alpha 只记第一次、放回原值；关模块时全部还原。
  `/mui minimap diagnose` 报 HBD 是否接入、压掉几个 / 活动几个。
  证据：WindTools `RectangleMinimap` 同款问题的补丁；HBD 源码 `drawMinimapPin`
  （`minimapWidth/Height = GetWidth()/2`、`minimap_shapes["SQUARE"]`、`floatOnEdge` 归一化）。
- ✅ 2026-10-21 **客户端 HybridMinimap 的矩形遮罩** —— `Blizzard_HybridMinimap` 是客户端
  自带的 LoD（`C_Minimap.ShouldUseHybridMinimap()` 为真的地图里，小地图改用世界地图的
  MapCanvas 平铺，见 `Blizzard_Minimap/Mainline/Minimap.lua:236` 的 PLAYER_ENTERING_WORLD
  分支），它给画布套的是圆形 `CircleMask`（XML `parentKey="CircleMask"`，`OnLoad` 里
  `MapCanvas:SetMaskTexture`）；皮肤开着时换成我们的矩形遮罩（`minimap_rect_mask`），
  关模块换回 `hybrid.CircleMask`。
  没有开关 —— 客户端机制，跟皮肤一起进退；帧层级不冲突（BACKGROUND/固定 100，面板之上、
  小地图 LOW 与覆盖层之下），画布本身禁用了点击/滚轮，所以只动遮罩。
  `ADDON_LOADED` 认包名即时接管，`Skin()` 每次补一遍，`diagnose` 报加载/接管状态。
- ✅ 2026-10-21 **矩形下收掉 blob ring** —— `Minimap:SetArchBlobRingScalar(0)` /
  `SetQuestBlobRingScalar(0)`；关模块时放回默认值 1。
  理由：任务区域 / 考古点的 "blob ring" 按圆画，矩形地图上会在蓝色任务区域里露出一圈
  圆形"华夫饼"纹（BasicMinimap 注释原话）。参考实现：Ellesmere
  `EllesmereUIMinimap.lua:4519-4523` 是 `isCircle and 1 or 0`；Andromeda
  `modules/map/minimap.lua:21-22` 直接 0。
  只动 scalar、不动 alpha：环的尺寸已经是 0；手册里只有 `Set*`、没有 getter，
  所以还原值是默认的 1（不是快照）。`SetTaskBlobRingScalar` 两家都没动，这里也不动。
- ✅ 2026-10-20 **UI 缩放按分辨率固定** —— `Media.scalePresets`（1080p → 0.711111 /
  1440p → 0.533333 / 4K → 0.711111），`Core.ApplyAutoScale` 在登录时写进 `uiScale` CVar，
  配置面板可切"跟随游戏设置"。
  理由：插件里的尺寸全是 UI 单位写的，1 单位不落在整数物理像素上，4 单位的条、12 单位的字
  就骑在像素边上、看着发软；`uiScale = 768 × 每单位像素数 / 屏高`，值必须精确，取整就又骑线。
  这个客户端的缩放滑块下限是 0.65（`Graphics.lua:925`），1440p 的首选值 0.5333 可能被夹掉，
  所以每档都备了下一个候选（2 像素/单位），写完立刻读回验证。
  附带好处：圆角边框与平边框的物理宽度差（原先最多半个纹素）在钉住的缩放下正好是 0。
  玩家自己拖了滑块就交还控制权。

## 未决

- ~~Bags 实机验证通过后退役旧 `BagFrame` 模块~~ ✅ 2026-10-26 `3.21` 已删（模块目录 / toc / 面板条目）。
- `Skin:Divider` 零调用孤儿函数（调查中发现，不在批准清单，未动）。
- **技能弹出托盘（SpellFlyout）鼠标点选必报 `ADDON_ACTION_FORBIDDEN CastSpellByID()`**（快捷键正常）。
  原因：托盘挂到我们的按钮上后，暴雪会用脏上下文给托盘按钮写属性。要么接受"鼠标点不展开、只提示一次"，
  要么自绘托盘（中等工作量）。**待决策。**
- **暴雪小队/团队框现在完全由玩家自己在编辑模式里隐藏**（我们任何接触都会让成员框比较机密值抛 `oldR`）。
  若玩家反馈"团队框重复"，先确认编辑模式里那两项的"可见性"。
- 宠物条每次重载留 10 条 `PetActionButton*:SetShown` BLOCKED（只进日志、不弹窗；卸载外壳事件会让图标/冷却不更新，
  所以**接受**）。同类噪音还有偶发的 `MainActionBar:SetPointBase/ClearAllPointsBase`。
- **编辑模式布局曾被抓到被重置**（`Logs/EditMode.log`：账号数据 buffSize 2489 → 78，发生在 2026-10-24 21:19 前后）。
  与代码里能找到的改动无直接因果；若玩家发现"界面布局突然全乱"，先看这条。
- 本轮未动的模块需要一次实机过：Bags、InfoBar、Tooltip、Cursor、Toast、Durability、CombatText、Skins 各窗口。

## 备注

### 2026-10-27 下午遗留（下一次接手先看）

- ✅ **名字"最多占 70%、超了缩字号"已接线**（2026-10-28）：`Widget:FitText` 接到
  `Nameplates.UpdateText` / `UnitFrames.UpdateName` / `Groups`（FitName，按钮存
  `nameSize`/`nameBoxW`），旧截断（`Shorten`/`AbbrName`/`nameLength`）全部停用。
  接线时抓到 FitText 真 bug：自动宽度字串被 `fs:GetWidth()` 误钳 → 永缩一档
  （玩家名 10 显示成 9）；已改为显式传 `boxWidth`（详见 HANDOFF 3.26.6）。
- ✅ **四项实机已验**（2026-10-28）：施法火花 3px 双层、小地图区域名 24px、
  背包数量白字（全窗都在显示）、InfoBar 战斗脉冲（红线呼吸 0.93↔0.99）。
- ✅ **待复核闭环**（2026-10-28 复查）：名牌 8 号超限瞬态 = 旧版 GetWidth 误钳 bug 的产物，
  修钳后不可复现（当前视野名牌全部 ∈ 限额）。**新发现**：像素字体宽度有量化悬崖 ——
  `银月大使帕拉·晨歌`（9 字形）：10→100.0 / 9→92.5 / **8→85.0 / 7→65.8**，84 限额下 8 号差
  1px 就会跳到 7 号（8→7 无中间档；7 与 6 宽度相同 = 字体分辨率地板）。FitText 行为符合
  "超过就缩字号"的规则；若玩家嫌长名跳档太狠，候选微调：限宽允差 +1px 或换 0.5px 步进。
- ~~📝 `MonetUI.md` §9 与现状不符，待订正~~ **已订正**（2026-10-28，`95aa983`）：§9 明暗行
  （插画件例外）、26/26 → 37/37、SVG 现役 9 张、§4.3.2 火花白名单改 SPARK_FILL/SPARK_EDGE、
  名字 70% 规则成条、姓名板 nameSize 默认 11→10 与 truncate 行"已停用"。
- 注释清理前基线备份：`%TEMP%\opencode\comment-cleanup-backup`（29 文件，可逐文件回滚）。
- 仓库约定：游戏正式上线且初步测试通过前，不向远端推送。
