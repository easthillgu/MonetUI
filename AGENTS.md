# MonetUI 项目约定

WoW Forever 客户端插件（Interface 16001，Lua 5.1）。以下为硬性约定，违反即为缺陷。

## 交接（先读这两份）

- **`docs/HANDOFF.md`** —— 项目做到哪了、2026-10-24 这一轮修了什么（带 commit）、仍开着的问题、
  客户端行为速查、验证清单、代码地图。**接手先读它。**
- **`docs/CODEX-SETUP.md`** —— 换开发平台（opencode → Codex）时的环境配置、MCP 挂法、降级流程。
- 设计/决策长文在 `MonetUI.md`（147KB，按标题查，别整篇读）；待办在 `TODO.md`。
- 本仓 `docs/`、`tools/`、`*.md` 被 `.gitignore` 排除（git 只跟踪插件源码），换机/换平台要**整目录拷贝**。

## 验证（减错核心）

- 有 wuxian MCP 时：`check` → `deploy-retail.ps1` → `reload` → `run`/`try` 探针 → `logs` → `snap`。
  **没有 MCP 时**：`node tools/api-audit.js` 是唯一的离线闸门（HARD 项必须清零），其余按
  `docs/HANDOFF.md` 6.2 的手动流程走（`/console scriptErrors 1` → `/reload` → 读红字/`Logs/taint.log`）。
  返回游戏数据时**先 `issecretvalue` 再 `tostring`**，否则机密值会让 `table.concat` 直接抛 `invalid value (secret)`。

- 每次改完 Lua/TOC：跑 `tools.wuxian.check`（离线用 `live: false`），0 错误 0 警告才算完成。
- 帧名/对象名永不凭记忆、也不照抄参考插件：一律 `_G` 护卫查找 + 登记进面板 `frames` 名单，实机用 `/mui skins diagnose` 复核。
- 客户端 API 以 `docs/api/` 里的本地快照为准（`node tools/api-lookup.js <名字>`；正文见 `docs/api/MANUAL.md`）。快照抓自 <https://wuxianwow.com/api/>，就是本客户端的 `Blizzard_APIDocumentationGenerated`：名字、参数、返回、机密/受保护标记都查它，效力**高于** `hated-wow` MCP（后者是正式服数据，只当补充；查暴雪插件 Lua 实现仍可用它）。快照没更新时 `node tools/api-fetch.js` 重新抓。
- 改到 `C_*` 名字 / 事件名 / `Enum.X.Y` 值时另跑 `node tools/api-audit.js`：默认对撞 `docs/api` 的本地快照（HARD 项退出码 1；`--gethe` 才走旧的 `Gethe/wow-ui-source` 转储）。它同时给 CHECK（受保护全局，要在 `InCombatLockdown` 之外）、SOFT（实参个数、旧全局）、INFO（会返回机密值的 API 清单 + 文档外方法名 + TOC 指令校验）。`wuxian check` 对未知名字只给 `unresolved` note，判不死，所以这一层不能省。
- 游戏在线时走 `/verify` 实机清单（小地图还原、威胁发光、新皮肤帧名）。

## 安全边界

- 参考插件 Andromeda / EllesmereUI **只读**（opencode.json 已 deny edit），仅作学习素材。
- 资源全部自绘，不引外部贴图与第三方库（防 GPL 污染）。
- 访问 Blizzard 帧做存在性 / pcall 防护；失败一次性 print 警告，不刷屏。
- secure 元素（微按钮等）战斗中禁改：`InCombatLockdown()` 防护 + `PLAYER_REGEN_ENABLED` 一次性重试。
- **安全单位按钮（`SecureUnitButtonTemplate`）的显隐只能交给 `visibility` state driver**（`[@target,exists] show; hide` 等），任何代码路径都不要再 `Show/Hide/SetShown` —— 战斗中必被拒（`ADDON_ACTION_BLOCKED MonetUITargetFrame:Hide()`），`UNIT_*` 事件驱动的刷新路径尤其容易漏。
- 秘密值：数值上下文用 `Secrets.Number` 包裹，受限时保留上次状态。但**"nil" 不等于"机密"**：`UnitThreatSituation` 这类 API 脱战后返回的是普通 nil（表示没有该信息），必须按"0/无"处理，只有 `issecretvalue` 为真才保留上次状态 —— 否则红边之类的状态会永远挂着。
- **布尔值同理，且必须"值级前置"**：对机密值做真值测试（`if v then`）会被客户端拦成
  `ADDON_ACTION_BLOCKED UNKNOWN()`；而 `issecretvalue`(**读取**本身)不触发拦截。
  **本仓已把这层做进唯一漏斗 `Secrets.Bool`**（2026-10-25）：机密值直接落回 `default`
  （= 以前被拦后的回退值，逐位一致），非机密才真值测试 —— 所以调用点直接写
  `Secrets.Bool(v, 默认)` 即可，不要再手工拼 `IsSecret` 分支。
  真正需要**分支逻辑**的地方（例如"机密时走另一条路径"）才显式写
  `if Secrets.IsSecret(v) then ... else ... end`。
  诊断这类拦截**只认** `Secrets.BoolBlocks()`（失败路径自记 `debugstack`）——本客户端
  taint.log 对"布尔测试被拦"会记、对 `ADDON_ACTION_BLOCKED` 却**零记录**（旗子开着实测 0 字节）。
- **字符串同理，而且 `type()` 判不出来**（2026-10-26 判例）：受限时 `GameTooltip:GetUnit()` 会把
  **unit 令牌本身**标成机密，而机密串的 `type(x)` 照样是 `"string"`——只判类型就放行，
  接着 `unit .. "target"` / `table.concat` 直接抛 `invalid value (secret)`（实机就这样刷了 3 条）。
  **规矩：凡是"从游戏拿到、之后要进 concat / format / 比较"的值（unit 令牌、name、guid、link），
  判完类型必须再过一次 `issecretvalue`**，宁可少显示一行。

## 污染（taint）模型 —— 本客户端最贵的一课

症状：`ADDON_ACTION_BLOCKED`（会弹「插件导致界面行为失效」）、`SetPoint ... anchor family connection`、
`attempt to compare ... (a secret number value, while execution tainted by 'MonetUI')`。
它们几乎都不是"那行代码写错了"，而是**我们把暴雪的受保护对象标脏了**。

- **绝不往暴雪的框体 / 贴图 / 字体串上写字段**（`frame.__monetXxx = ...`）。本客户端按"键"判污染：
  写过一次，这个对象之后跑的暴雪代码全部以我们的名义执行。一律走 `ns:Mark(obj, key, value)` /
  `ns:Marked(obj, key)`（Core.lua，**以对象为弱键的旁表**），我们自己的框体也一样处理，省得判断。
- **绝不往受保护按钮写属性**（`SetAttributeNoHandler(button, "statehidden", true)`）：
  按钮会因此卡在"显示"状态，暴雪自己的 `UpdateShownButtons → SetShown` 战斗中被拒，
  而 alpha 0 的按钮**照样收 OnEnter**（`ActionButton.lua:1391 → UpdateAction → SetAttribute`），
  于是鼠标每扫过一次就刷一屏拦截。要让它不响应鼠标就用 `EnableMouse(false)`（不受保护、也不写字段）。
- **绝不 `SetParent` 暴雪的动作条**。被换过父的受保护框，之后暴雪自己的
  `EditModeManagerFrame:UpdateBottomActionBarPositions → ClearAllPoints/SetPoint` 全部被拒；
  而且**别处干净也会中招** —— 污染会跟着调用链走一圈（一条脏条的 OnEvent → UpdateVisibility →
  重排所有条）。收起暴雪动作条只用：`SetAlpha(0)` + 整棵子树 `EnableMouse(false)` + `Show` 后压回 alpha。
- **绝不 `SetScale` / 写 `ignoreFramePositionManager` 这类字段**在受保护的条/按钮上：
  同样会把它们标脏，连锁同上。
- 诊断两板斧：
  1. `issecurevariable(obj, "字段")` 逐键扫，找出我们留下的脏键（`false` 就是脏）；
  2. `C_CVar.SetCVar("taintLog", "2")` → 客户端写 `<游戏目录>/Logs/taint.log`，
     里面有被拦调用的**完整栈**和"blocked in combat because of taint from MonetUI"的归属。
     读完记得关回 0（详细模式有开销）。
- 结算顺序：先修"往暴雪对象写东西"，再看 `issecurevariable` 是否全干净，最后才看弹窗是否消失。
  只删自己代码里的"清理"动作是不够的 —— 键一旦脏了，**同一次会话里不会自己变干净**（要重载）。
- **界面美化只做窗口装饰，不给里面的按钮/页签挂任何脚本钩子**（`HookScript` / `hooksecurefunc`）：
  HookScript 往框体的脚本槽写我们的函数、hooksecurefunc 改它的方法槽，两者都等于"写过这个框"，
  之后这个框自己的脚本（例如法术书图标的 `OnIconEnter → ClearOnBarHighlightMarks`）就跑在
  "被 MonetUI 污染"的执行里，把 `ON_BAR_HIGHLIGHT_MARKS` 这类**全局表**写脏 —— 所有动作按钮的
  高亮/显隐更新随之被拒（这就是那串 `PetActionButton*:SetShown` / `MainActionBar:ClearAllPoints`）。
  悬停/按下/面板重涂一律走轮询：`Widget:HoverWatch`、`Widget:ShowWatch`、`Widget:PollWatch`
  （本客户端**没有** `MouseIsOver` / `GetMouseFocus`，用 `frame:IsMouseOver()`）。
- **绝不覆写暴雪的方法去"骗"编辑模式**（这条栽得最狠）：编辑模式进入时在**同一条调用栈**里
  做完 `EditModeFrameSetup`（摆动作条 → 摆状态条 → … → `RefreshPartyFrames`），链上只要读过
  一个"被我们写过的值/方法"，**后面整段都算 MonetUI 的执行环境**。实机症状：进/退编辑模式必报
  `CompactUnitFrame.lua:699: attempt to compare local 'oldR' (a secret number value, while
  execution tainted by 'MonetUI')`，二分关模块也查不出来（关错了对象）。
  具体案例：`MinimapCluster.IsInDefaultPosition`（我们搬了小地图就得它答 false，否则
  `GetRightActionBarTopLimit` 算出负的 availableSpace → `MultiBarRight:SetScale(-0.18)` 报错）。
  **正解**：别让编辑模式需要我们的答案 —— 集群留在暴雪默认位置，只把 `Minimap` 帧搬进自己的
  框体（Ellesmere 在本客户端就是这么做的），矩形遮罩/面板/覆盖层都挂在 `Minimap` 上照旧工作。
  同理：`systemInfo.isInDefaultPosition` 这类"数据"也不能替玩家写，读到的脏值一样会污染整条链。
- **`Cooldown:GetCooldownTimes()` 返回的是**毫秒**，`GetTime()` 是秒**。混着算的结果不是"差一点"，
  而是把 6 分钟的 buff 画成 `568d`，再套上颜色码（`|cffbebfb3` + 数字 + `|r`…）在 8px 的字号下
  看起来就像"时间被加密了"。凡是拿到 cooldown 时间的地方先想单位；另外加一道"剩余 > 30 天就当读不到"的保险。
- **空容器被压成 0×0 之后，`GetLeft()` 返回 nil**：任何锚在它下面的行都会跟着没有矩形（实机：
  两行 buff 之间的 proc 行为空时，debuff 整行 `shown=true` 却什么也不画）。行位置要按**实际行高累加**
  算，别把一行锚在"可能为空"的另一行上。
- **收暴雪的 HUD 帧：用 `SetAlpha(0)` + `EnableMouse(false)`，不要 `Hide()`**。
  `Hide()` 会被暴雪自己的 `Show()` 顶回来（"一有更新就 Show 一次"），我们补一刀它顶一刀 ——
  屏幕上就是"一闪一闪、时而可见"（实机：任务追踪框）。alpha 0 的框**一直算显示着**，
  不触发它的 Show 逻辑，拉锯就没了（暴雪动作条 MainActionBar 也是这个结论）。
  另外这类帧常在 **LoD 包**里：登录时还不存在，而且包加载时会把框**换成一个新对象**——
  "藏一次 + 盯 OnShow"永远漏，要在 ADDON_LOADED / PLAYER_ENTERING_WORLD / 换区域 /
  每次数据刷新各补一次（`ns:Mark` 守卫，重复调用只是一次表查询），再加一个低频兜底。
- **同一个坑的第二例：`NamePlateDriverFrame:UpdateNamePlateOptions`**。以前用
  `hooksecurefunc(driver, "UpdateNamePlateOptions", ...)` 来"改完牌子尺寸再改回来"，
  驱动框一脏，**它建出来的每一块姓名板都脏**，接着就是姓名板那一串：
  `CompactUnitFrame.lua:1211 maxHealth` / `:668 机密键索引` / `CastingBarFrame.lua:344
  notInterruptible` / `Blizzard_NamePlateAuras.lua:366 isFullUpdate`，外加重载瞬间十几条
  `ADDON_ACTION_BLOCKED MonetUI UNKNOWN()`。改成轮询 `C_NamePlate.GetNamePlateSize()` 后
  10 分钟 0 报错、`taint.log` 全空。判定口诀：**只要那东西是暴雪用来"生产"其它帧的
  （驱动 / 池 / 管理器），碰它一次，产物全脏**。
- **同一个坑的第三例：自建 `CreateFrame("AuraContainer", ...)`**（2026-10-25 定案）。
  容器是我们造的，引擎在它上面跑的渲染就全记在 MonetUI 名下：战斗里一 `Show`，逐个按钮
  被拦（×2 / ×15 / ×29 与按钮批次量级吻合），而且**这类拦截不进 taint.log**。更糟的是
  按钮换肤（`SetIcon` / `SetDurationCooldown` / `SetApplicationCount` 换成自建子帧）后，
  战斗中**新触发的 proc 只有鼠标提示、没有图标**；完全不换肤则这套模板的按钮一个都画不出来。
  **结论**：玩家光环的战斗显示交给**暴雪原生** `BuffFrame / DebuffFrame / TempEnchantFrame`
  （`SuppressBlizzard` 按 combatMode 切 alpha 0/1），别再自建 AuraContainer 顶班。
  判定口诀同上一条：**引擎的生产件，不要用我们的手去造、去改**。
- **战斗光环是"硬禁读"，不是"字段加密"**（2026-10-25 插件上下文实测）：
  `C_UnitAuras.GetAuraDataByIndex` 在 `ShouldAurasBeSecret()` 为真时对**整个插件**抛出
  `Auras cannot be accessed when secret while tainted by 'MonetUI'` —— 拿不到 aura 表，
  所以**不存在"先 `IsSecret` 判断再自绘"**这条路（那是"字段加密"才有的写法）。
- **战斗显示的可行解法**：让**引擎 AuraContainer** 顶班（客户端自己读机密数据），插件只在
  `initializeFrame` 里把"接数据的对象"（`SetIcon` / `SetDurationCooldown` /
  `SetApplicationCount`）交给它。三条纪律（ArcAuras 实践，二〇二六年十月实机验证）：
  ①容器只在装载窗口或脱战时创建（战斗里建出来是空的）；②**必需件先注册、装饰件各自 pcall**，
  任何装饰失败都不能连累 `SetIcon`（否则就是"按钮能悬停、没有图标"）；③机密期不建颜色曲线
  （`C_CurveUtil` 会被拒），时长退回冷却自带数字。兜底：容器建不出来时用暴雪原生 Buff 框。
- **绝不"重建"引擎容器来换主题**（2026-10-25 判例，代价最贵的一条之一）：重建会留下
  **上一世代**的容器——我们只 `Hide`/`ClearAllPoints`，帧本身销毁不了，而它仍然
  `SetEnabled(true)` 被引擎驱动。那批按钮被我们的 `initializeFrame` 碰过，于是战斗里
  引擎每次写它们都被记成 MonetUI → 连环`ADDON_ACTION_BLOCKED UNKNOWN()`（实机 ×11 一次、
  整场不停），**只有重载才能清掉**。正解：主题切换**不重建**容器，边框颜色保持创建时那一套，
  `/reload` 后跟新主题；并且**战斗中绝不创建容器**（创建也会失败并产生拦截）。
- **"借用模式"必须连事件一起收掉**（2026-10-25 判例，`ADDON_ACTION_BLOCKED UNKNOWN()`
  每场战斗进出各 +1 的真凶）：`SuppressBlizzard` 当年为 A 方案（借 TargetFrame 的光环）
  给 `TargetFrame` 留了"只 alpha 0、事件照跑"的特例。A 方案废弃后这个特例没人清——
  它自己的代码从此跑在"被 MonetUI 写过"的上下文里，**每次进出战斗都被拦一条**。
  排查路径（可复用）：拦截时间线（`PLAYER_REGEN_*` + 事件时间戳）→ 配置级二分
  （把 `ns:DB().modules` 全置 false 后重载，逐组打开）→ 锁到模块后读代码找"只做了一半"
  的压制。**结论：任何被我们碰过的暴雪框，要么完全放手，要么连事件一起收掉，不要留半套。**

## 安全按钮（自绘动作条）的额外约束

- **点击会读到的属性也必须由安全片段写**，不只是 `action`：
  `type` / `typerelease` / `checkselfcast` / `checkfocuscast` / `checkmouseovercast` / `useOnKeyDown`。
  Lua 写进去的是脏值，客户端照用，但整条执行被记成我们的 → 同一次点击里暴雪的安全调用
  （`CastPetAction → PetActionBar:UpdateShownButtons → SetShown`、`UseAction → MainActionBar:ClearAllPoints`）
  全部被拒。本仓用 `_childupdate-mui-kind` / `_childupdate-mui-keydown` + `ChildUpdate` 写。
- **本客户端没有通用安全按钮的 `type="pet"`，也没有 `SecureHandlerClickTemplate`**：
  自建宠物按钮怎么点都不会施法（实测：属性全对、位置不重叠、层级压过所有条、**0 拦截**，
  但点击无任何反应 → 客户端根本不处理该 type）。**宠物条必须"收养"暴雪的 `PetActionButton1..10`**
  （`SetParent` 到自己的条、`SetSize`/`SetPoint` 摆格子），施法/冷却/自动施法/右键切换全原生。
  参考：EllesmereUIActionBars.lua:3150-3175、ElvUI `ActionBars/PetBar.lua`（两者都是收养，
  只是换皮方式不同）。
- 收养宠物按钮的**已知代价**：暴雪外壳的 `PetActionBar:Update → UpdateShownButtons` 会对这 10 个
  已搬家的受保护按钮 `SetShown`，每次重载刷 10 条 `PetActionButton*:SetShown` 的 BLOCKED
  （只进日志、不弹窗、功能正常）。**不要**为了消掉它去 `UnregisterAllEvents()` 外壳 ——
  实测那样按钮不再更新（冷却圈不转、图标不刷新）。
- 宠物按钮的**冷却**要自己驱动：本客户端没有全局 `PetActionBar_UpdateCooldowns`，
  用 `PetActionBar:UpdateCooldowns()` 每 0.5 秒刷一次（不要用 `Update`，它会连带
  `UpdateShownButtons`）。
- 收养按钮的换皮：图标 `ClearAllPoints` + 内缩 1px 再裁 8%；边框画在**按钮上方**的
  `BackdropTemplate` 子框体（垫在下面的会被铺满整格的图标盖掉）。

- **条与条可能几何重叠**：同层级时**创建更早的按钮 z 序更靠前**，会把后建的条整条吃掉
  （实机：宠物条被 4 号条 10 个按钮盖住，点谁都没反应）。新条要么换位置，要么把
  `frame:SetFrameLevel` 抬到别的条之上（本仓宠物条 = 66，普通条 = 60/61，接住器 = 70）。
- **拖放落点不要用"左下角 + 间距"推算**：`GetLeft()/GetBottom()` 返回的已经是屏幕（UIParent 缩放后）
  坐标，再乘一次缩放就整体偏移。逐按钮 `GetLeft/GetBottom/GetWidth/GetHeight` 命中即可。
  宠物条的槽位是宠物技能 1..10，**不是动作条槽位**，所以宠物条**不能装** `PlaceAction` 接住器。



## 代码风格

- 皮肤包用 `M:Panel(key, { ... })` 注册；窗口统一 `M:SkinWindow`。
- **加载清单是 xml，不直接在 toc 里列 `.lua`**（2026-10-26 起）：`MonetUI.toc` 只列各组 xml
  （`Libs/Libs.xml`、`Utils/Utils.xml`、`Config/Config.xml`、`Modules/<模块>/<模块>.xml`）与单文件模块的 `.lua`。
  **新增 `.lua` 必须挂进对应 xml 的 `<Script file>`，并放在正确的先后位置** —— 漏挂不会报错，
  客户端直接不加载（`wuxian check` 会以 `not-loaded` 提示）。组内顺序 = xml 内的次序，
  组间顺序 = toc 内的次序；动顺序时顺手更新该 xml 头部的注释。
- OnShow 重涂一律走 `M:HookShow`（引擎带幂等守卫），调用处勿自行 `HookScript("OnShow")`。
- 高频事件用 `M:Debounce`；LoD 窗口在面板声明 `addons = { ... }` 门控。
- 小步改动、可回滚；不顺手重构无关代码。
- **多行文本替换一律用 `split(/\r?\n/)` + `splice`，严禁 `string.replace()` 做多行匹配。** 本仓文件混用 CRLF 与 LF，源码里写死的 `\n` 字面量跟 CRLF 文件比不上，`replace()` 静默失配，报错信息还只说"未找到"，看不出是行尾问题。写回时先探测原行尾（`raw.includes('\r\n')`），切片用 `split(/\r?\n/)`，拼接用同一个 `eol`。

## 材质制作规范

- 尺寸必须为 2 的幂次方（32/64/128/256），非正方形需补白到最近幂次。
- 优先输出 TGA 格式（32bit RGBA），BLP 作为备选。
- 图标类材质建议 64x64，边框/背景建议 256x256。
- 命名规范：小写下划线，如 `icon_shield_gold.tga`。
- 透明靠 Alpha=0，且 **Alpha=0 的像素 RGB 必须是纯白 (255,255,255) 衬底，永不用纯黑**。客户端建 mip / 滤波时会把边缘颜色拖进可见区，黑衬底会让每个图标镶一圈黑边；白衬底乘任何染色正好等于那个染色。
- **染色模具必须无色相**：凡是被 `SetVertexColor` / `SetBackdropBorderColor` 上色的贴图，只能用纯白或纯灰。引擎是 贴图 × 顶点色**相乘**，`#fffcf6` 染完是 `borderColor × (1, .988, .965)` —— 蓝少 3.5%，边框这种几百像素长的色带一眼看得出来；烘了金色的按下态碰上蓝色主题会变成浑浊的蓝褐。
- 刻意保留美术色、不许顺手拉平的只有四张：`monet_close_hover`（`Skin:CloseButton` 刻意不染色，金色即 hover 信号）、`monet_win_maximize`（金色标题栏 = "这是个窗口"）、`monet_brush_stroke` 与 `monet_corner`（只调 alpha，奶油/赭石双色是核心）。
- 上面两条由 `tools/audit-pixels.js` 强制（`STENCIL` 名单 28 张 + 全局白衬底检查），改生成器后必须重跑；`Assets/Textures.bak` 是现成的反例库，拿它跑一遍能验证规则没失效。
- **要"手绘感"的材质交给 GIMP**（`C:\Users\EastHillGu\Documents\GreenAPPS\GIMPPortable`，GIMP 3.2 自带 Oils / Bristles / Acrylic / Charcoal 等真实颜料笔刷）。脚本逐像素画不出鬃毛痕与颜料洇边。现役：`monet_brush_stroke` = `tools/gimp-brush-stroke.py`（画布 256×16，五个 Monet 色做五遍颜料，笔触点自己盖章）。流程：GIMP 出 PNG → `node tools/tga-post.js <png> <tga>`（转成项目格式的未压缩 32bit TGA + 补纯白衬底；GIMP 的 TGA 导出默认是 RLE，格式对不上）→ `node tools/audit-pixels.js` 验收。注意 GIMP 3 的 API：`Gimp.*` 命名空间（没有旧版 `gimpfu.pdb`）；颜色分量必须 **0..1 浮点**（传 0..255 会被夹成纯白），**而且是线性分量**（画笔上下文吃线性的，喂 sRGB 会整体提亮：`#214447` → `rgb(100,139,142)`；浅色几乎不变、越暗越明显，所以 `monet_brush_stroke` 曾经把"干笔暗边"整个洗没了，要先 `srgb_to_linear()`）；画笔"硬度"是 0..1、"间距/不透明度"是 0..100；`edit_stroke_item()` 在这个版本只画路径首尾两点，所以要自己逐点盖章。
- **要"能自己画/能自己改"的材质走 SVG**（Inkscape 1.4.3，`C:\Users\EastHillGu\Documents\GreenAPPS\Inkscape\bin\inkscape.com`）。源码放在 `tools/svg/*.svg`（**手写矢量**，可以在 Inkscape 里直接打开改），导出走 `node tools/svg-to-tga.js`（Inkscape 出 PNG → 项目格式 TGA + 补白衬底 + 校验画布是 2 的幂）。现役 9 张：`minimap_rect_mask`、`monet_close_{normal,hover,push}`、`monet_map_{tracking,compartment,difficulty}`、`monet_spark_{up,down}`（施法条火花 / 经验线三角，**尖端画在贴图边缘**，位置靠锚点精确控制）。**规矩：有 SVG 的以 SVG 为准** —— 生成器（`tools/regen-textures.js`）里不再画同名纹理，否则两套源码会互相覆盖。像素质量与脚本版等价（对照表 `%TEMP%\opencode\svg-compare.png`），SVG 的优势是**源码可读可改**。
- 三条路线按材质分工：**结构性的**（9-slice 边纹、遮罩、发丝线）必须像素级精确 → 脚本；**要软、要洇的**（笔触）→ GIMP；**要自己画/改的**（图标）→ SVG。GIMP 画小图标会更差：笔刷的抗锯齿在 11–24px 的显示尺寸下会糊（对照表 `%TEMP%\opencode\icon-compare.png`）。

### 插件列表图标（`Assets\Textures\monet_addon_icon.tga`）

- **机制**：`.toc` 的 `## IconTexture:` → 客户端 `Blizzard_AddOnList/AddonList.lua:390` 用 `C_AddOns.GetAddOnMetadata(addonIndex, "IconTexture")` 取到，再以内联 `CreateSimpleTextureMarkup(iconTexture, 20, 20)` 画在插件名前面 —— **实际只显示 20×20**，所以构图必须"一眼认得出"（本图：深绿池水上一朵粉白睡莲）。128×128 足够（参考 Ellesmere 64×64、Platynator 128×128）。
- **流水线**（三个本地工具，缺一不可）：
  1. `powershell -File tools/gimp-render.ps1 -Script tools/gimp-addon-icon.py -Out $env:TEMP\monet_addon_icon_bg.png` —— 跑 GIMP 的 Python-Fu，产出**背景**（水+天空+叶，不透明）与**前景**（只有花，带 alpha）两张 PNG。该壳负责"盯着输出文件出现就收摊"，因为 GIMP 3.2 的批处理跑完不会自己退出。
  2. `node tools/icon-post.js --bg <bg.png> --fg <fg.png> --out <out.png> --size=128` —— 背景重柔化（2.4px）、花轻柔化（0.9px），叠画布颗粒与织纹，再缩到 128。
  3. `node tools/tga-post.js <out.png> Assets\Textures\monet_addon_icon.tga` —— 转项目格式的未压缩 32bit TGA（type 2）。
- **GIMP 3.2 的四个坑**（都写在 `tools/gimp-addon-icon.py` 头部）：
  - 画笔上下文吃的是**线性**分量，直接喂 sRGB 会整体提亮（`#214447` → `rgb(100,139,142)`），画面糊成粉白 —— 必须先 `srgb_to_linear()`；
  - `edit_stroke_item()` **只画路径的首尾两点**（多点路径实测只落首尾），所以要"自己盖章"：一个路径塞 N 条 0.01 长的两点子路径，一次画全；
  - 盖章点攒在字典里 → **出图顺序是字典序**（谁先画全看运气），所以按画面元素分层，层序 = 创建序；
  - `Gimp.ImageBaseType` 只有 `RGB` / `GRAY`，没有 `RGBA`；图有没有 alpha 取决于层（画在 `RGBA_IMAGE` 的层上，导出 PNG 就带透明）。

## 动作条（自绘安全按钮）—— 本客户端的硬约束

**能不能施法只看一件事：`action` 属性是谁写的。**

- 按钮必须 `SetID(0)` + `type=action` + `typerelease=actionrelease` + `RegisterForClicks("AnyDown","AnyUp")`，
  槽位只来自 `action` 属性（`CalculateAction` 的 path 2）。
- **`action` 只能由安全片段写**：`RegisterStateDriver(bar, "page", 条件)` → 条的 `_onstate-page` 片段 →
  `self:ChildUpdate("mui-page", page)` → 每个按钮的 `_childupdate-mui-page` 片段
  `self:SetAttribute("action", i + (page-1)*12)`。`_onstate-page` 用 `SetAttributeNoHandler` 装。
- **禁止用 Lua 写 `action` / `actionpage`**：值会变"脏"，客户端拿它调 `UseAction`（受保护全局）就判
  插件越权 → 每次点击弹「MonetUI 已被禁用，因为该功能只对暴雪的 UI 开放」。实机对照：同一个按钮，
  Lua 写 → 必弹窗；片段写 → 正常施法（`UNIT_SPELLCAST_SUCCEEDED player:185358`，日志 0 条 FORBIDDEN）。
- **冷却别用 `C_ActionBar.RegisterActionUIButton`**：客户端回写我们的冷却框，参数是机密值，受限环境必报
  `SetCooldown ... Secret values are only allowed during untainted execution`（Ellesmere 也写了它对自建
  按钮 "paints NOTHING，别再追"）。正确做法：`GetActionCooldown(slot).isActive`（NeverSecret）+
  `GetActionCooldownDuration(slot)` 的 duration 对象 → `cd:SetCooldownFromDurationObject(dur)`。
  读之前先 `issecretvalue`；secret 值一律不比较、不做算术（`Cooldown:GetCooldownTimes` 在受限环境返回 secret）。
- 战斗中也要刷图标/冷却：`UpdateAll` **不要**用 `InCombatLockdown()` 早退——只有挪框体的 `RefreshLayout` 需要；
  否则载具换页、冷却起转全冻住。冷却事件单独走轻量路径（只重画冷却框，不重扫 96 个按钮）。
- **受保护框体（暴雪的动作条 / 动作按钮）一个都别碰**：`EnableMouse` / `SetScale` / `SetParent` /
  `hooksecurefunc(frame,"Show"/"Hide")` 都会被记成 `ADDON_ACTION_BLOCKED`（如 `MultiBarBottomRight:SetPointBase()`、
  `ActionButton5:SetShown()`），`SetParent` 还会让编辑模式算出 `SetScale(0)` 直接报错。
  结论：**全部 `SetParent(常隐框体)`**（`SetScale` / `EnableMouse` / `hooksecurefunc` 一律不要；
  改父在脱战做，`Restore` 再放回 `UIParent`）；按钮用 `UnregisterAllEvents` + `SetAttributeNoHandler("statehidden", true)`
  让暴雪自己 `SetShown(false)`。注意 `MainActionBar` 也必须换父 —— 见本节末尾那条。
- 拖出/拖入用 `PickupAction` / `PlaceAction`（同属受保护全局），必须 `InCombatLockdown()` 守门，战斗外可用。
- 参考实现（只读）：`EllesmereUI-v9.4/EllesmereUIActionBars/EllesmereUIActionBars.lua`
  （`:2868` 片段生成、`:2932` `_onstate-page`、`:2188-2279` 按钮属性、`:943` 冷却、`:1850` 暴雪条处置）、
  `EUI_ActionBars_Events.lua:994`（`RegisterActionUIButton` 的结论）。
- **`MainActionBar` 必须换父，光 `SetAlpha(0)` 不够**：12.1.5 上它即使 alpha 0、层级比我们的条低，
  仍会把自己矩形（默认 786..1348 × 45..90）内的**鼠标事件全部吃掉** —— 落在这一带的动作条
  （bar2 整条 y 61..89）点击/拖放都收不到任何事件；bar1 只有上半截被压所以"要对准才生效"。
  诊断法：把那条临时 `SetPoint` 挪到 y=200，接住器立刻恢复 → 就说明是它在吃事件。
  修法：和其余条一样 `SetParent(常隐框体)`（`vis=false` 后不再占那片屏幕区域）。
- **换父的已知代价（不要再当新 bug 查）**：8 条暴雪条换父后，暴雪自己的布局代码在 UI 重载 /
  少数战斗转场时仍想重排它们，于是日志里出现 `ADDON_ACTION_BLOCKED MonetUI MainActionBar:SetPointBase()`
  / `MainActionBar:ClearAllPointsBase()` / `MultiBarBottomRight:SetFrameStrata()`。同理，宠物 / 姿态条
  外壳我们是**脱战**写 `SetScale` / `EnableMouse(false)` 的，被写过的框会带上污染，之后暴雪自己的
  `SetShown` 被拒并归到 MonetUI 名下（`PetActionBar:SetShownBase()`、`MultiBar*ButtonContainerN:SetShown()`）。
  这些是 BLOCKED（只进日志、不弹窗、功能正常），换成"不换父 / 不缩放 / 不关壳鼠标"的代价更大
  （鼠标事件被吃 / 按钮尺寸对不上 / 1303×1193 吃掉屏幕中央）。**唯一属于我们的非法调用是单位框架
  战斗中 `Show/Hide` 安全单位按钮** —— 那条已改成 `visibility` state driver（见下）。
- **姿态条（德鲁伊形态 / 死骑灵气 / 战士姿态）现在也"收养"了**（2026-10-26 `8d4ab87` 先把它
  从 `GhostBar` 里救回来，`816c320` 再照宠物条的做法接管）：`BuildStanceBar` /
  `AdoptStanceButtons` 把 `StanceButton1..10` `SetParent` 到 `MonetUIBarStance` 并换皮，施法走
  原生 `StanceButtonMixin_OnClick → StanceBar:Select → CastShapeshiftForm`。
  - **壳（`StanceBar`）只 `SetAlpha(0)` + 关鼠标，事件一条都不卸载** —— 图标 / 选中态 / 冷却都是它
    自己的 `UpdateState` 在刷（它的 `UpdateGridLayout` 动的是**容器**，不是我们搬走的按钮）。
  - **不要自建 `StanceButtonTemplate` 按钮**（ElvUI 的做法）：那要求"我们自己造的受保护按钮点下去
    能施法"，正是本客户端踩过的坑（自绘 `type="pet"` 按钮属性全对、0 拦截、点击无反应）。
  - **两条退路必须把按钮还回去**（`ReleaseStance`）：玩家关掉自绘条、或 `GetNumShapeshiftForms()==0`
    —— 否则按钮留在我们藏起来的框体里，原生姿态条成了空壳，玩家没法变形态。
  - **收编位置**：姿态条在 3 号条**正上方、左对齐**（按钮左对齐）；宠物条在 1 号条**下方、右对齐**，
    且两条都**平时 alpha 0.3、悬停 1**（`SetupHoverOnly`；帧仍算"显示"所以鼠标进得来；
    **不要用 Hide**，那会和 `[pet]` / 姿态的 visibility 状态驱动互相顶成"一闪一闪"；判定走
    `Widget:HoverWatch` 轮询，绝不往暴雪受保护按钮挂 `OnEnter`）。回调是常驻登记的，所以配置里
    关掉悬停要连 `bar.hoverOnly` 开关一起关 —— 否则鼠标一进出又会被拉回 0.3。
  - **收养按钮的空槽底色**：暴雪的 `SlotBackground` / `NormalTexture` 被 `SkinAdoptedButton` 关掉，
    没有动作的格子会整格透明（宠物条 8..10），玩家看到的就是"空白按钮不见了"。补一块和自绘槽位
    同色的 well（纯黑 0.25）在 `BACKGROUND/-8`（暴雪图标是 `BACKGROUND/0`，有图标时被盖住）。
  - **宠物单位框**：悬停或"宠物被选中"（是当前目标/焦点）才 alpha 1，其余 alpha 0
    （`UnitFrames.lua` 的 `ApplyPetHover`）。显隐仍归 `visibility` 驱动，只动 alpha；
    `UnitIsUnit` 是机密返回，必须过 `Secrets.Bool`；选中没有事件可挂，只能轮询。
  - **收养来的条（宠物 / 姿态）不进我们那几套循环**：`IsAdopted(bar)` 守 `UpdateCooldowns`
    （自绘槽位公式对它们算出负数 → 只剩 `Clear()`，把原生冷却圈擦掉）、`SetClickOptions`
    （暴雪按钮带 `.bar` 字段，会去 `Execute` 一条没有 `mui-keydown` 片段的受保护条）、
    `ReassignBindings` / `ClearBindings`（键位本来就绑在暴雪命令上）。
  - `GetNumShapeshiftForms` **只有复数名**（单数 `GetNumShapeshiftForm` 本客户端不存在）。
  - 口诀不变：**给"已接管条"让路的隐藏动作，千万别落到没被接管的那条上**。
- **拖放落点**：普通 `Frame` 收不到 `OnReceiveDrag`（实机 0 次；`IsMouseEnabled` 也开着、`GetMouseFoci`
  也显示它在最上层）。可行做法是用 `ActionBarButtonTemplate` 建一个"只在 `GetCursorInfo()` 有货时才
  开鼠标"的透明接住器，**`OnMouseUp`** 里按光标坐标算出目标格再 `PlaceAction(slot)`。
  **它的鼠标状态必须无条件每拍结算**（`条显示着 and 手里有东西`），不能"宿主隐藏就早退"：
  接住器是挂在条矩形上的独立框体，宿主隐藏时它不会自己失效，模板事件还会把它鼠标打开 ——
  实机就是 bar4 的接住器（level 70）一直 mouse=true，压在同 y 的姿态条上，点姿态放出"动作条第 1 格"。
  同理：**我们的条之间不能同 y 重叠**，姿态条的默认锚点按当前条数算（`SyncStanceAnchor`）。
- **弹出托盘（SpellFlyout）：鼠标点开只能看，选项必须用快捷键点。** 我们的按钮需要补
  `GetPopupDirection` / `TogglePopup` / `popupCrossAxisSize` 三样（缺一个就报
  `SpellFlyout.lua:260` / `:350` / `Flyout.lua:322`）。但托盘一旦挂到插件按钮上，
  `SpellFlyout:Toggle` 会用**脏上下文**给托盘按钮 `SetAttribute` 写法术 ID，点选时
  `CastSpellByID` 被判越权（`ADDON_ACTION_FORBIDDEN MonetUI CastSpellByID()`）；把托盘父级换成
  `UIParent` 也**无效**（脏在属性里，不在父链上）。结论：鼠标点击不展开、只提示一次；
  快捷键走暴雪自己的 ActionButton，展开的托盘选项可以正常点（实机确认）。

## 工作习惯

- 挖参考插件派 `explore` 子代理，只取结论进主上下文。
- 大段输出先 `grep` 定位、再定点 `read`（offset/limit 分页），避免整文件读入。
- 重复流程用 `/check`、`/verify` 命令，不重新口头描述。
- 远端 `origin`（github.com/easthillgu/MonetUI）只作**私有备份**：仓库必须保持 private，推送前确认没有被改回公开；转公开（等同于正式发布）等游戏上线且初步测试通过后由作者手动操作。
