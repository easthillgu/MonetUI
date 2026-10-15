# MonetUI 开发计划

> **创建日期**: 2026-10-13
> **最后更新**: 2026-10-15（新增界面美化模块 Skins，v0.9.0；暴雪窗口统一走 Monet 材质 / 色彩）
> **当前阶段**: Phase 1/2 — 八个模块已实现并通过 `wuxian check`，待游戏内 `load`/`try` 验证
> **目标**: 为魔兽世界无限 (WoW Forever) 打造一套莫奈风格整合 UI 插件

---

## 一、项目定位

MonetUI 是一套**整合 UI 插件**，以**莫奈印象派色彩**为核心设计语言，为 WoW Forever 提供：

- 自适应环境色彩的动态主题系统
- 模块化 UI 组件（单位框架、冷却、Buff、小地图等）
- 精简依赖、低复杂度的代码架构

**设计原则**：
1. **依赖精简** — 仅依赖 LibStub（必需）+ LibMonetColor（可选）+ LibActionButton（随包，动作条用）
2. **模块松耦合** — 模块间通过 EventBus 通信，不直接依赖
3. **私有 API** — 公共工具封装在 Utils 中，避免重复代码
4. **优雅降级** — MonetColor 缺失时使用内置默认配色
5. **Lua 5.1 兼容** — 不使用 5.2+ 特性（`//`、`goto`、`bit32`、`table.unpack`）

---

## 二、当前状态

### 已完成

| 任务 | 状态 | 说明 |
|------|------|------|
| 目录结构创建 | 完成 | 19 个源文件，15 个目录 |
| Utils 层 | 完成 | Widget/Color/EventBus/Math/Secrets/Media/Skin |
| 命名空间共享 | 完成 | 统一使用插件私有表 `ns`（`...` 第二个返回值） |
| Core.lua | 完成 | SavedVariables + 模块注册/生命周期 + 主题管线 + 斜杠命令 |
| Config 面板 | 完成 | SimpleConfig.lua，绑定 MonetUIDB，实时生效 |
| UnitFrames | 完成 | 玩家/目标/焦点/宠物，血条/能量/名字/等级/提示，连击点小格（盗贼/德鲁伊），可拖动并保存位置 |
| Cooldown | 完成 | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 |
| BuffFrame | 完成 | 自绘增益/减益网格，按时长排序，可读性守卫 |
| Minimap | 完成 | 矩形化 256×190 + 去坐标/时钟 + 主题面板 |
| BagFrame | 完成 | 背包排列整合 + 主题边框 |
| QuestTracker | 完成 | 主题边框 + 标题栏拖动 + 位置保存 |
| ActionBars | 完成 | 1–8 号自绘动作条（LibActionButton-1.0）+ 接管宠物/姿态条 + 隐藏暴雪动作条/背包条 |
| Nameplates | 完成 | 挂在暴雪姓名板底座上的细条姓名板：血条/名字等级/百分比/施法条/借用暴雪减益/仇恨与目标描边；CVar 接管 + 点击区同步 + 完整回退 |
| Skins | 完成 | 界面美化：给暴雪窗口（任务、世界地图、角色、收藏、成就、社交、邮件/商贩/拍卖/专业、拾取/弹窗/菜单/设置等）统一铺 Monet 底板 / 边框 / 字体；可逐窗口开关，模块关闭可完整回退 |
| Forever 保密值适配 | 完成 | Utils/Secrets.lua，全部单位数值访问先查询 |
| Lua 5.1 兼容性检查 | 完成 | 无 5.2+ 特性 |
| wuxian check 语法验证 | 完成 | 0 error / 1 warning（有意：覆写 `GetMinimapShape`）；参考插件来的 API 未入手册项已全部消除 |
| 安装到游戏 AddOns | 完成 | 含 Assets/Fonts 共 30.8 MB / 30 个文件已同步 |

### 待完成

| 任务 | 优先级 | 说明 |
|------|--------|------|
| wuxian load 热加载验证 | P0 | 需游戏运行（当前离线） |
| 游戏内视觉验收 | P0 | 三地图验证 + 暴雪框架接管是否产生 taint |
| MonetColor Phase 2 联调 | P0 | 环境采样器（引擎侧） |
| 队伍/团队框架 | P1 | RaidFrames（当前仅单人单位） |
| 备用能量条（真 `AltPower`，载具/任务/首领）、DK 符文、其他职业资源 | P3 | 暴雪 `PlayerFrame.powerBarAlt` 目前跟着 `PlayerFrame` 一起被隐藏，尚无替代；圣能/气/碎片/充能/精华在 Forever 版本不存在，不做；见「连击点」一节 |
| 聊天框美化 | P2 | 见模块清单 |
| 压力测试 | P1 | 10 万次 API 调用 |
| 发布 v1.0.0 | P2 | 文档 + 打包 |

---

## 三、目录结构

```
MonetUI/
├── MonetUI.toc                 # 插件入口清单
├── Core.lua                    # 核心：模块注册 + MonetColor 接入 + 事件监听
├── Utils/                      # 公共工具（私有 API，全部挂在 ns 上）
│   ├── Math.lua                # 数学工具 + 数字/时间格式化
│   ├── Secrets.lua             # Forever 保密值处理层
│   ├── Media.lua               # 字体/纹理注册表
│   ├── EventBus.lua            # 事件总线（按需注册，含单位事件）
│   ├── Color.lua               # 颜色接入层（MonetColor 封装 + 降级）
│   ├── Widget.lua              # 控件工厂 + 主题注册表
│   └── Skin.lua                # 暴雪窗口皮肤原语（剥皮/底板/控件/文本，可回滚）
├── Modules/                    # 功能模块
│   ├── UnitFrames/             # 单位框架
│   ├── Cooldown/               # 冷却计时
│   ├── BuffFrame/              # Buff 框架
│   ├── Minimap/                # 小地图
│   ├── BagFrame/               # 背包
│   ├── QuestTracker/           # 任务追踪
│   ├── ActionBars/             # 动作条（1–8 号自绘 + 接管宠物/姿态条）
│   ├── Nameplates/             # 姓名板（暴雪底座 + 自绘细条）
│   └── Skins/                  # 界面美化（暴雪窗口皮肤引擎 + 分窗口皮肤）
│       ├── Skins.lua           # 引擎：注册表 / 生命周期 / 完整回退 / 全局字体
│       ├── Quest.lua           # 任务日志 + 任务 / 对话窗口
│       ├── WorldMap.lua        # 世界地图 + 地图内任务面板
│       ├── Character.lua       # 角色界面 + 观察
│       ├── Collections.lua     # 收藏 / 成就 / 冒险指南
│       ├── Social.lua          # 好友 / 社区 / 公会 / 日历
│       ├── Trade.lua           # 邮件 / 商贩 / 训练师 / 拍卖 / 专业 / 银行
│       └── System.lua          # 拾取 / 弹窗 / 游戏菜单 / 设置 / 插件列表 / 菜单 / 提示
├── Config/
│   └── SimpleConfig.lua        # 轻量配置面板（无 Ace3）
├── Assets/
│   ├── Textures/
│   │   └── minimap-rect-mask.tga  # 小地图矩形遮罩（256×256，脚本生成）
│   └── Fonts/                  # 字体资源
│       ├── Pingfangpixel.ttf   # 中文像素字体 — 所有中文文本
│       ├── combat.ttf          # 战斗字体 — 仅数字（伤害/治疗数值）
│       ├── super-effective.ttf # 冷却字体 — 冷却计时数字
│       └── roadway.ttf         # 标题字体 — 标题/装饰
├── tools/
│   └── make-minimap-mask.ps1   # 生成小地图矩形遮罩（自绘，不含第三方素材）
└── Libs/
    ├── LibStub/                # LibStub 库
    ├── LibMonetColor-1.0/      # 色彩引擎库
    ├── LibActionButton-1.0/    # 动作按钮库（BSD-3，见 Libs/NOTICE.md）
    └── NOTICE.md               # 随包库的来源与许可说明
```

---

## 四、技术架构

### 4.1 依赖策略

```
必需: LibStub
可选: LibMonetColor-1.0 (有 fallback)
随包: LibActionButton-1.0 (BSD-3-Clause；仅动作条模块使用，缺失时退回暴雪默认动作条)
不引入: Ace3, CallbackHandler, Masque, SharedMedia, oUF, cargBags
```

> `CallbackHandler-1.0` 没有被随包：LibActionButton 内部对它是**可选**依赖，缺失时退化成
> 空实现（见 `Libs/NOTICE.md`），因此 MonetUI 不需要额外带一个库来满足它。

### 4.2 模块间通信

```
Module A ←→ EventBus ←→ Module B
```

- 模块不直接引用其他模块
- 通过 EventBus 发布/订阅事件
- Core 统一管理模块生命周期

### 4.3 颜色接入层

```lua
-- Utils/Color.lua 封装 MonetColor
local LMC = LibStub("LibMonetColor-1.0", true)

-- 有 MonetColor: 动态获取环境色
-- 无 MonetColor: 使用内置 Andromeda 风格默认配色
```

**签名三色（edge / ambient / highlight）+ neutral 全部来自引擎**；health / resource / danger 由 UI 自己管，
不做「Monet 化」。

**边框颜色已经预留走 MonetColor**：单位框架、小地图面板、动作条、Buff 按钮、配置面板等所有边框都经
`Widget:Theme()` 注册，刷新时读 `Color:GetBorder()`（背景读 `Color:GetAmbient()`）。所以引擎换色**不需要改任何
模块代码** —— 只要 `Color:Refresh()` 后再广播 `MONETUI_THEME_CHANGED`，`Widget:RefreshThemes()` 就会把所有
已注册控件重新染色。

刷新时机：

| 时机 | 触发 |
|------|------|
| 登录 / 区域变化 / 手动 `/mui theme` | Core 监听 `ZONE_CHANGED*`、`PLAYER_ENTERING_WORLD` → `ns.RefreshTheme()` |
| 引擎主动通知（切换配置档、引擎侧刷新） | Core 订阅 LibMonetColor 的 `OnThemeColorsChanged` 回调 → `ns.RefreshTheme("monet")` |

回调订阅做了**形态探测**：LibMonetColor 可能带 `CallbackHandler-1.0`，也可能走它内置的回退注册表，两者的
`RegisterCallback` 调用形状不同（`LMC:RegisterCallback(事件, fn)` vs `LMC.events:RegisterCallback(键, fn)`）。
Core 先探测、两路都试且都 `pcall`；都拿不到时静默跳过，**区域事件刷新仍是兜底**。订阅状态见
`/mui status` 的 `回调: 已订阅 / 未订阅`。

**边框色槽可切换（配置面板「边框颜色」）**：边框取哪个引擎色槽由用户选择，存于 `MonetUIDB.theme.borderKey`
（默认 `edge`）：

| 值 | 含义 |
|----|------|
| `edge` | 边缘色（Monet 签名，默认） |
| `ambient` | 环境色 |
| `highlight` | 高亮色 |
| `neutral` | 中性灰 |

`Widget:Theme` 通过 `Color:GetBorderKey()` 决定色相；单个控件仍可用
`Widget:Theme(frame, { borderKey = "highlight" })` 单独覆盖。**只有色相跟着色槽走，透明度固定用 edge 的**，
所以选到半透明的 `ambient` 也不会让边框淡到看不见。改这一项后走 `RefreshTheme`，全部边框（含动作条按钮描边、
Buff 边框）即时生效。

### 4.4 Lua 5.1 兼容清单

| 禁止 | 替代 |
|------|------|
| `//` 整数除法 | `math.floor(a / b)` |
| `goto` | 函数重构 |
| `bit32` 库 | 位运算用 `math.fmod` 或查表 |
| `table.unpack` | `unpack` |
| `table.pack` | 手动构造表 |
| `coroutine.close` | 不使用 |

### 4.5 命名空间与跨文件共享

WoW 会**丢弃** .toc 内每个文件的返回值，因此各文件不能通过 `return X` 互相传递模块。
WoW 为同一插件的所有文件传入相同的 `...`：

```lua
local ADDON_NAME, ns = ...   -- ns 是整个插件共享的私有表（所有文件同一个）
```

- 每个 Utils 文件把自己挂到 `ns` 上（`ns.Color`、`ns.Widget`、`ns.Secrets`、`ns.Media`、`ns.Math`、`ns.EventBus`）
- Core.lua 在 `ns` 上增加模块注册表与生命周期方法
- 模块通过 `ns:Register(name, module)` 注册，通过 `ns:GetModule(name)` 取用
- `_G.MonetUI = ns` 仅作为调试用别名

**这是本项目最容易出错的地方**：之前版本用 `return X` 传递，导致 `Utils/Widget.lua` 里的
`local Color = Color` 解析成全局 `Color`（nil），一旦调用 `Widget:ApplyBorder` 就会报错。

### 4.6 Forever 保密值处理层（Utils/Secrets.lua）

"无限" 客户端在**战斗 / PvP / Boss / 聊天锁闭**等状态下会向插件返回 `<secret>` 值。
对保密值做**算术、比较、真值判断、拼接、格式化**会直接抛错：

```
attempt to perform arithmetic on a secret number value
```

规则：

1. 控件可以安全接收保密值（如 `StatusBar:SetValue(secret)`），**血条照常填充**
2. 任何要"读数字/比较/格式化"的地方，必须先询问 `C_Secrets.Should*BeSecret(...)`
3. 查询失败或 API 缺失时**一律当作保密**处理（宁可不显示，不可报错）
4. 不受限时行为与普通客户端完全一致

```lua
if Secrets.CanMeasureHealth("player") then
    local cur = Secrets.Number(UnitHealth("player"))  -- 安全取数
    ...
else
    frame.healthText:Hide()   -- 只显示血条，不显示数字
end
Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit))  -- 内部 pcall
```

> **绝不注册** `COMBAT_LOG_EVENT_UNFILTERED`（12.0+ 已移除且受限）。
> EventBus 采用**按需注册**，不再预注册固定事件列表。

---

## 五、模块清单与优先级

| 优先级 | 模块 | 功能 | 状态 | 参考 |
|--------|------|------|------|------|
| **P0** | UnitFrames | 玩家/目标/目标的目标/焦点/宠物框架，血条能量条、连击点（盗贼/德鲁伊）、名字等级、拖动保存 | ✅ 已实现 | Andromeda, EllesmereUI |
| **P0** | Cooldown | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 | ✅ 已实现 | EllesmereUICooldownManager |
| **P1** | BuffFrame | 自绘 Buff/Debuff 网格，按时长排序，可读性守卫 | ✅ 已实现 | EllesmereUIAuraBuffReminders |
| **P1** | Minimap | 矩形小地图（256×190）、去圆形边框/指南针、主题面板 | ✅ 已实现 | EllesmereUIMinimap, Andromeda |
| **P1** | BagFrame | 背包排列整合 + 主题边框 + 标题字体 | ✅ 已实现 | EllesmereUIBags |
| **P2** | QuestTracker | 主题边框 + 标题栏拖动 + 位置保存 | ✅ 已实现 | EllesmereUIQuestTracker |
| **P2** | ActionBars | 1–8 号自绘动作条（LibActionButton 驱动、安全翻页、原按键沿用）+ 接管宠物/姿态条 + 隐藏暴雪动作条与背包条 | ✅ 已实现 | EllesmereUIActionBars, Andromeda |
| **P2** | Chat | 聊天框美化 | 待建 | EllesmereUIChat |
| **P2** | Nameplates | 姓名板美化（暴雪底座 + 自绘细条、CVar 接管、借用暴雪减益、施法条、仇恨/目标描边） | ✅ 已实现 | EllesmereUINameplates, ForeverUI, Andromeda |
| **P2** | Skins | 界面美化：暴雪窗口（任务/地图/角色/收藏/社交/交易/系统）统一铺 Monet 底板、边框与字体；逐窗口开关、模块可完整回退 | ✅ 已实现 | EllesmereUIBlizzardSkin, Andromeda, ForeverUI, ElvUI Skins |
| **P3** | RaidFrames | 团队框架（队伍/团队） | 待建 | EllesmereUIRaidFrames |
| **P3** | ResourceBars | 资源条（备用能量 `AltPower`、符文等剩余资源显示） | 待建 | EllesmereUIResourceBars |

### 布局锚点（照搬 Andromeda，`UI_GAP = 33`）

| 元素 | 锚点 | 坐标 | 尺寸（宽 × 高） |
|------|------|------|------|
| player | `CENTER` / UIParent `CENTER` | `(0, -180)` | 160 × 6 |
| target | `LEFT` / player `RIGHT` | `(40, 40)` | 160 × 6 |
| targettarget | `LEFT` / target `RIGHT` | `(6, 0)` | 60 × 6 |
| pet | `RIGHT` / player `LEFT` | `(-6, 0)` | 60 × 6 |
| focus | `RIGHT` / player `LEFT` | `(-100, -40)` | 60 × 6 |
| 连击点 | `TOPLEFT` / player `BOTTOMLEFT` | `(0, -3)` | 玩家框宽 × 3，5 格（见下） |
| 小地图 | `BOTTOMRIGHT` / UIParent `BOTTOMRIGHT` | `(-33, 33)` | 256 宽 × 190 高（面板 264 × 198） |
| 增益 Buff | `TOPLEFT` / UIParent `TOPLEFT` | `(33, -33)`，每行 8 个 | 图标 34 × 34 |
| 减益 Debuff | `TOPLEFT` / Buff容器 `BOTTOMLEFT` | `(0, -8)` | 图标 34 × 34 |

> 坐标与 Andromeda 完全一致（含 `focus` 的 `-100`：由于单位框已细条化到 60 宽，不再需要外推）。
> 每个单位的 `width` / `health` / `power` 都存在 `MonetUIDB.unitFrames[unit]`，可直接调数值微调。
> 单位框位置也存同一张表，拖动后按**相对锚点**保存（拖 player 时依赖它的框会自动跟随）。

#### 个单位框高度构成

```
总高 = 边框 1 + 血条 2 + 间隔 1 + 能量条 1 + 边框 1 = 6
```

血条贴顶、能量条贴底（与 Andromeda 的 `Health` / `Power` 锚点一致）；`间隔` 对应 Andromeda 的
`C.MULT`（1440p 下约为 1）。数值均可在 `MonetUIDB.unitFrames` 调整。

> **为什么血条是 2 而不是 Andromeda 的 4**：Andromeda 会执行
> `UIParent:SetScale(clamp(768 / 屏幕高, 0.4, 1.15))`（1440p 约 **0.53**，见其 `core/uiscale.lua`），
> 它的整个坐标系比我们小一半左右 —— 配置里写的 4 实际只画到约 2。MonetUI 不缩放 UIParent
> （`Frame:SetScale` 是受保护方法，缩 UIParent 等于连暴雪 UI 一起缩），所以取 Andromeda 的 50%。

#### 血条着色

血条由两层组成：底层一张铺满的贴图表示**损失**掉的部分，上层 `StatusBar` 只填到当前值，
因此底层只在掉血的那一段露出来。**两层都不需要读任何单位数值**，所以战斗中客户端把血量变成
`<secret>` 时着色依然正确（只有百分比数字要读值，读不到就不显示数字）。

| 单位 | 当前血量（`fillColor`） | 损失部分（`lostColor`） |
|------|------------------------|------------------------|
| player / pet | `highlight` — Monet 高亮奶油色 | `black` — 读作背景 |
| target / focus / targettarget | `class` — 职业色（NPC 用阵营反应色） | `danger` — 读作已造成的伤害 |

`fillColor = "class"` 用 `UnitSelectionColor(unit)` 取色：一次调用同时给出玩家职业色与 NPC 的
反应色，而且**不返回保密值**（不像 `UnitClass` 需要先用 `Secrets.CanReadIdentity` 守卫）。

血量数字按百分比着色（`textColorByPercent`，4 个定点插值：绿 → 黄 → 橙 → 红）——不用红绿直接
线性插值（中间会发褐），对色盲也更友好。

`fillColor` / `lostColor` / `textColorByPercent` / `powerColor` / `smoothBars` / `classPower` /
`classPowerHeight` / `classPowerGap` 都存在 `MonetUIDB.unitFrames`，改值即可换风格；配置面板「单位框架」
一栏有对应的下拉与勾选框。

##### 能量条分色

每次刷新都用 `UnitPowerType(unit)` 重新取一次类型（变身 / 姿态 / 载具 / 遭遇战机制都会换能量），
返回的 token（`MANA` / `RAGE` / `ENERGY` / `RUNIC_POWER` …）查 `POWER_COLOR` 表上色；表里没有的
类型退回到 `UnitPowerType` 一并返回的客户端自带颜色，再退回主题的资源色。`powerColor = "theme"`
可以关掉分色、统一用主题色。用 `UNIT_DISPLAYPOWER` 事件驱动，切换形态时立刻换色。

##### 死亡 / 掉线变灰

`UnitIsDeadOrGhost` 或 `UnitIsConnected` 为假时，对血条与能量条调用
`StatusBar:SetStatusBarDesaturated(true)`。**变灰由客户端完成**（`Enum.SecretAspect.Desaturation`），
我们只传一个自己算出来的布尔值，不读任何单位数值，所以战斗中数值被隐藏时同样有效。
另外，单位死亡后血量归零、整条都露出「损失」贴图，而那张贴图是普通纹理、客户端不会替我们褪色，
所以死亡时把它的顶点色单独改成中性灰，尸体的条才不会还是一整条红。
驱动事件：`PLAYER_DEAD` / `PLAYER_ALIVE` / `PLAYER_UNGHOST` / `UNIT_CONNECTION`。

##### 数值平滑

血条与能量条的 `SetMinMaxValues` / `SetValue` 都会带上
`Enum.StatusBarInterpolation.ExponentialEaseOut`，让条子缓动到新值而不是瞬间跳变 —— 插值在客户端
内部完成（`Enum.SecretAspect.BarValue`），因此**机密值也能走平滑路径**。`smoothBars = false` 关闭。
`Utils/Secrets.lua` 在加载时查一次该枚举，查不到就退回不带插值的旧调用。

##### 连击点（classPower）

暴雪把玩家的连击点画在 `PlayerFrame.classPowerBar` 里，备用能量条画在 `PlayerFrame.powerBarAlt` 里。
这两个都是 `PlayerFrame` 的**子框体**，`SuppressBlizzard` 一 Hide 父框体就一起消失了 —— 也就是说，
不做替代的话盗贼会只剩那条能量条、**连击点完全看不到**。本模块因此在玩家框体下方补了一排小格
（`CLASS_POWER` 表）：

| 职业 | 资源 | 能量类型 | 默认格数 |
|------|------|----------|----------|
| ROGUE | 连击点 | `ComboPoints` | 5 |
| DRUID | 连击点 | `ComboPoints` | 5（仅猫形态：`UnitPowerType == ENERGY`） |

> Forever 版本**没有**圣能 / 气 / 灵魂碎片 / 奥术充能 / 精华这些资源，所以 `CLASS_POWER` 只列盗贼与
> 德鲁伊；机制本身是通用表，将来该版本补了别的资源再加一行即可。

- **几何**：格子条 = 单位框宽度 × `classPowerHeight`（默认 3），挂在玩家框 `BOTTOMLEFT` 下方
  `classPowerGap`（默认 3）处，格与格之间也留 `classPowerGap`；颜色查 `POWER_COLOR.COMBO_POINTS`。
- **保密值安全**：每格是一个 `StatusBar`，范围写成 `(i-1, i)`，把原始点数（可能是 `<secret>`）直接丢给
  `SetValue`，由客户端自己裁剪 —— 我们这边**不做任何比较或减法**。只有「满了变红」要同时读到当前值与
  上限，读不到就保持普通颜色。
- 格数取 `UnitPowerMax(unit, power)`；该值被隐藏时**不重排**（沿用上次读到的格数，首次用表里的默认值），
  避免机密值一出现整排格子跳动。防御性上限 10 格。
- 上限为 0（德鲁伊非猫形态、或该单位确实没有连击点）时整排隐藏；`UNIT_DISPLAYPOWER` 驱动德鲁伊形态切换，
  `UNIT_POWER_UPDATE` 用事件带回来的 token 过滤（能量每秒跳十次，只有 `COMBO_POINTS` 的事件才刷新），
  `UNIT_MAXPOWER` 处理天赋改变上限；死亡/掉线时和血条一样 `SetStatusBarDesaturated` 变灰。
- 配置面板「单位框架」一栏的 **连击点（盗贼 / 德鲁伊）** 下拉：`关闭` / `2–5 px`（一个下拉同时管开关与高度）。

**尚未覆盖**（现阶段不做）：死亡骑士符文、其他职业资源（该版本不存在），以及「充能连击点」高亮
（`GetUnitChargedPowerPoints`）。另外 `PlayerFrame.powerBarAlt`（真正的备用能量条：载具 / 任务 / 遭遇战
给的那条）目前也仍只是跟着暴雪框体一起被隐藏，**没有替代实现**。

#### 文字位置（参考 Andromeda 的 tag 锚点，全部在条**上方** 3px）

| 单位 | 左上方 | 右上方 | 居中上方 |
|------|--------|--------|----------|
| player | 名字 + 等级 | 血量 `当前 / 最大` | — |
| target | 血量 `当前 / 最大` | 名字 + 等级 | — |
| targettarget | — | — | 名字 |
| focus | — | — | 名字 |
| pet | — | — | —（无文字，同 Andromeda） |

#### 小地图矩形化

圆形画布仍是 256 × 256，用 `Assets/Textures/minimap-rect-mask.tga` 做遮罩（**自绘资源**，
由 `tools/make-minimap-mask.ps1` 生成：上下各 33px 全透明黑、中间 190px 不透明白，脚本写完后
会把文件解码回来校验一遍），上下各裁 33px，得到 256 宽 × 190 高的可见区域；`SetHitRectInsets`
同步收缩点击区，并把 `GetMinimapShape` 覆写为 `SQUARE`，让第三方小地图按钮按矩形排布。
小地图**不显示坐标与时钟**；暴雪圆形边框/指南针/背板全部隐藏，由主题面板（264 × 198）替代。

预览图：`docs/mockup/layout-2560x1440.png`（源文件 `docs/mockup/layout-2560x1440.html`）。

### 动作条（ActionBars）

#### 主流做法：藏掉暴雪的条，自己在安全模板上画

Bartender4、Dominos、ElvUI、Andromeda 都是同一个套路：**不驱动暴雪自带的按钮**，而是
把默认动作条移出屏幕，自己在客户端的**安全模板**上新建按钮。原因很实际：

- 暴雪的按钮绑死在编辑模式（Edit Mode）、固定几何和它自己的翻页状态上，外面 `SetPoint` /
  `SetSize` 之后随时会被暴雪的排版改回去；
- `SecureActionButtonTemplate` 的按钮由客户端自己施法，战斗中不失效，也不会因为插件代码
  碰了它而"污染"（taint）暴雪 UI；
- 翻页（载具 / 覆盖 / 附身 / 变形 / 额外动作条）在安全环境里只换几个属性，Lua 完全不参与。

只有 Masque 这类纯美化插件会反其道而行：不建按钮，只给暴雪按钮换贴图。MonetUI 选前者。

#### 实现：LibActionButton-1.0

按钮来自 **LibActionButton-1.0**（`Libs/LibActionButton-1.0/`，BSD-3-Clause，见
`Libs/NOTICE.md`），与 Bartender4 / ElvUI / Andromeda 用的是同一个库。MonetUI 只写
"怎么用"和"长什么样"：

| 关注点 | 做法 |
|--------|------|
| 头框体 | 每条条一个 `SecureHandlerStateTemplate` 框体，`_onstate-page` 片段把新页号 `control:ChildUpdate` 给每个按钮 |
| 翻页 | `RegisterStateDriver(frame, "page", …)`；1 号条挂完整条件串（`[vehicleui]16;[overridebar]18;[shapeshift]17;[bonusbar:n]…`），2–8 号条挂**常量页号**（6/5/3/4/13/14/15） |
| 状态表 | 每个按钮 `SetState(0..18, "action", slot)`：状态 0 是"翻页驱动缺失"时的兜底（1 号条停在第一页），1–18 是驱动换页时要查的表 |
| 显隐 | 1 号条 `[petbattle] hide; show`（同暴雪 MainMenuBar）；2–8 号条在载具/覆盖/附身/变形/宠物对战时让位 |
| 按键 | 玩家的旧按键原样沿用：`ClearOverrideBindings` + `SetOverrideBindingClick(frame, false, key, 按钮名)`，键名从暴雪绑定名（`ACTIONBUTTON<i>`、`MULTIACTIONBAR1BUTTON<i>`…）反查；战斗中只打标记，`PLAYER_REGEN_ENABLED` 后再补 |
| 点击时机 | 读 `ActionButtonUseKeyDown`（`C_CVar.GetCVarBool`）传给库，决定按下即施法还是抬起施法；`CVAR_UPDATE` 时刷新 |
| 外观 | 图标内缩 1px + `SetTexCoord(0.08, 0.92, …)`，露出的那一圈底色就是描边；暴雪的空槽方框/装备绿光/闪光/新技能提示全部关掉；冷却、射程着色、自动施法光圈等仍由库与客户端驱动 |
| 描边语义 | 库用 `Border` 的显隐表达"这件装备在身"，`hooksecurefunc(border, "Show"/"Hide")` 把描边换成主题高亮色（不额外轮询） |
| 字体 | `UpdateConfig` 传入像素字体与显式字号（快捷键 10 / 数量 11 / 宏名 10），不依赖库的全局字体；快捷键用 `SetText` 钩子缩写成 `s1` / `MU`（用 `SetFormattedText` 回写，不会自我递归） |
| 冷却数字 | `Widget:StyleCooldownText` 套用 `cooldown` 字体 |
| 下车按钮 | 自建一个（暴雪的下车按钮长在已被藏起来的主菜单条上），可见性交给 `[canexitvehicle]` / `[mounted]` 状态驱动，点击时飞行中请求提前落地、否则下车 |

库自己处理冷却、堆叠数量、可用性着色、射程、拖放与 `UPDATE_BINDINGS`，所以模块**没有轮询**，
只在主题或设置变化时刷一遍 `UpdateConfig`。

#### 宠物条 / 姿态条：接管，但不重画

这两条条不做自绘（重画要重新实现暴雪的一整套图标/自动施法/形态逻辑）。做法是：把暴雪的
`PetActionBarFrame`（外层容器，没有就退回 `PetActionBar`）/ `StanceBar` 从被藏起来的父框体里
**搬出来**、按 `buttonSize` **等比缩放**、放到存档里的位置，再把图标裁切与字体调成 MonetUI 的
样子。图标更新、自动施法光圈、当前形态环、冷却全部还是暴雪自己的代码在管，因此永远不会失同步。

> 搬的是**最外层**那个框体：暴雪显隐宠物的做法可能是 Hide 外层容器、也可能是 Hide 里面的条，
> 搬外层两种情况都还归它管；只搬内层的话，暴雪一 Hide 外层，我们的条就留在屏幕上了。

> 代价：暴雪在宠物变化、编辑模式换布局时会重排这两条条，MonetUI 只能在**战斗外**把它们放
> 回去（`PET_BAR_UPDATE` / `UNIT_PET` / `UPDATE_SHAPESHIFT_FORMS` 等事件 + `PLAYER_REGEN_ENABLED`
> 补做）。战斗中如果正好发生重排，位置会在战斗结束后恢复。

#### 暴雪框体：藏，不销毁

被收起来的是 `MainMenuBar`、`MultiBar*`、`OverrideActionBar`、`PossessActionBar` 以及背包条
（`BagsBar` / `MainMenuBarBackpackButton`）：`SetParent(隐藏框体)` + 保留事件。按钮本身仍在，
所以：

- 玩家的旧按键、宏、`/cast` 都不受影响；
- 自绘动作条万一建不出来（库缺失 / 安全模板缺失），模块会**放弃接管并打印提示**，暴雪的
  动作条原样回到屏幕上，而不是让玩家失去全部技能。

#### 配置项（`MonetUIDB.actionBars`）

| 键 | 默认 | 说明 |
|----|------|------|
| `ownBars` | `true` | 自绘 1–8 号动作条并接管宠物/姿态条；关掉就完全回到暴雪 |
| `hideBlizzard` | `true` | 隐藏暴雪默认动作条（`ownBars` 关掉时仍然生效） |
| `hideBagBar` | `true` | 隐藏暴雪背包条 |
| `barCount` | `3` | 显示几组动作条（1–8）；默认只显示 1/2/3 |
| `buttonSize` | `28` | 按钮边长 |
| `spacing` | `2` | 按钮间距 |
| `showHotkey` / `showCount` / `showMacro` | `true` | 快捷键 / 堆叠数量 / 宏名 |
| `positions` | `{}` | 按条覆盖 `BAR_DEFS` 里的首跑锚点（`point` / `relativeTo` / `relativePoint` / `x` / `y`） |

#### 已知限制

- **暂时不能拖动**。位置来自 `BAR_DEFS` 的首跑锚点：1/2/3 号条在底部居中往上叠，宠物条
  （右对齐）与姿态条（左对齐）占 3 号条上面那一行，4–8 号条继续往上叠（默认 `barCount = 3`，
  也就是默认只看到 1/2/3 加宠物/姿态）。想改就写
  `MonetUIDB.actionBars.positions["Bar2"] = { point = "BOTTOM", relativeTo = "Bar1",
  relativePoint = "TOP", x = 0, y = 2 }`。动作条上按钮全是安全按钮，把拖动做进按钮会
  抢掉"从条上拿起技能"的手感，所以拖动（含 `/mui` 里的解锁开关）留给下一版。
- 2–8 号条锚在 1 号条/其它条上，所以它们会跟着 1 号条走；这也是为什么拖动必须做在条框体上。
- 暴雪在**编辑模式**里会重新摆它自己的条，宠物条与姿态条的位置会在离开战斗后被我们抢回来。

### 姓名板（Nameplates）

#### 路线：站在暴雪姓名板之上，而不是另起炉灶

狂暴/ElvUI/Plater/Andromeda 的通用做法有两种：oUF 那套**自建整个姓名板框架**，或者像 ForeverUI 那样
**复用暴雪已经发下来的姓名板底座**。MonetUI 选后者，且不带 oUF：

- 客户端在世界上给每个有名字的单位发一个 **base 框体**（`C_NamePlate.GetNamePlateForUnit(unit)`）。
  这个框体负责**跟随单位、受击/血条位置、鼠标点击/选目标、软目标图标**等一整套逻辑；
- 模块把自绘的细条 `SetParent(base)` 并居中挂上去，再把 base 的子框体 `base.UnitFrame`
  （暴雪自己的那块板）`Hide` 掉——只隐藏，不销毁，随时可以还原；
- 于是定位、点击、单位进出视野全部还是暴雪在管，我们只管"长什么样"。

> 为什么不用 oUF：oUF 提供的是"从零搭一个单位框架"的骨架，而姓名板真正难的部分（底座定位、
> 点击、池化复用）客户端已经免费给了，自建等于把暴雪已经做好的部分再实现一遍。

#### 保密值安全（与 4.6 同一套规则）

姓名板在**战斗/PvP/Boss** 中正是最需要显示的时候，也正好是数值变成 `<secret>` 的时候。做法与单位框架一致：

| 数据 | 处理 |
|------|------|
| 血量 / 上限 | 原始值直接交给 `Secrets.SetBar`（控件接受 `<secret>`），血条照常填充；**百分比数字**先过 `Secrets.Number`，读不到就留空 |
| 施法名称 / 图标 | 直接 `FontString:SetText` / `Texture:SetTexture`（接受 `<secret>`） |
| 施法进度 | 一个只计算 `GetTime() * 1000`（我方普通数）的 OnUpdate 交给 `SetValue`，客户端拿它去和保密的首尾时间比对；**倒计时数字**只在结束时间可读时才生成 |
| 仇恨 | `UnitThreatSituation` 可能保密，过 `Secrets.Number`；读不到就保留主题色描边 |
| 等级 / 分类 / 名称 | `Secrets.Number` / `Secrets.IsSecret` 守卫；名称可保密时**整体显示不截断**（截断要读长度） |
| 减益光环 | **完全不读**：把 base 的 `UnitFrame.AurasFrame` 抢过来挂到自己的板上，游戏继续往里画 debuff（ForeverUI 技巧） |

`type(v) == "nil"` 在保密值上是合法且稳定的（返回底层类型），模块用它判断"是否正在施法"。
**绝不注册** `COMBAT_LOG_EVENT_UNFILTERED`；面板事件全部按单位用 `RegisterUnitEvent(event, "nameplateN")`
挂在板上，只有屏幕上的板才付出代价。

#### CVar 接管（谁能拿到姓名板）

"哪些单位有姓名板"是**客户端 CVar** 决定的，插件改不了，所以模块去**拨这些 CVar**，并在关闭模块时
**原样还回**（关掉时把每次读到的旧值逐个写回，不残留）：

| 配置项 | CVar |
|--------|------|
| `showFriendly` | `nameplateShowFriends` |
| `showEnemy` | `nameplateShowEnemies` |
| `showNPC` | `nameplateShowFriendlyNpcs` |
| `showMinor` | `nameplateShowEnemyMinus` |
| `showTotems` | `nameplateShowEnemyTotems` / `nameplateShowFriendlyTotems` |
| `showSelf` | `nameplateShowSelf` |
| `viewDistance` | `nameplateMaxDistance` |

`hideCritters` / `hideDead` 是在 CVar 之上**再加一层插件侧过滤**：被过滤掉的单位会把暴雪那块板
**还原回去**（见下），而不是留一块空地。

> 敌对/友方/友方 NPC 的分类不看 CVar，而是 `UnitIsFriend("player", unit)` + `UnitIsPlayer`：敌对的
> **玩家和 NPC 都归到 `showEnemy`**（否则"敌方开关"管不到怪物，只剩玩家）；友方 NPC 单独用
> `showNPC`（对应客户端的友好 NPC CVar）。

#### 点击区同步（`forcePlateSize`）

暴雪姓名板的**可点击区域**默认比一条细条大得多，还会和隔壁板的区域重叠——"看着点前面的板，实际选到
后面的单位"。模块在应用设置时把暴雪的框体尺寸**对齐到自己画的框**：

- **只用文档化的** `C_NamePlate.SetNamePlateSize`：`api_search` 实测该命名空间的 `siblings`
  只有 `GetNamePlateForUnit` / `GetNamePlateSize` / `GetNamePlates`，没有按阵营的 setter；
  而且本模块对所有板用的是**同一套宽高**，按阵营分设本就多余。曾参考其他插件看到
  `SetNamePlateEnemySize/FriendlySize`，查手册确认本客户端没有，已**从代码里删掉**；
- 首次接管前用 `GetNamePlateSize` 记下旧尺寸，关闭模块时还原；
- 战斗中 `InCombatLockdown()` 是受保护状态，改不了，先记 `sizePending`，`PLAYER_REGEN_ENABLED` 补做；
- hook `NamePlateDriverFrame.UpdateNamePlateOptions`（同样特性探测）——暴雪在设置/CVar 变化时会重排，
  重排后把我们的尺寸**再盖回去**。

#### 完整回退

关掉模块（配置面板勾选框或 `/mui Nameplates off`）是一次**真的交还**，不需要重载：

1. 每块板：`RestoreBlizzardPlate` 把 `UnitFrame` 显示回来、`AurasFrame` 的父级还给暴雪、
   再调一次 `ApplyFrameOptions` 让游戏自己重排；
2. 所有拨过的 CVar 写回旧值；
3. 姓名板点击区尺寸还原成接管前的值。

再次打开则从头应用（`Apply`），配置面板的每一项改完即时 `RefreshNameplates → M:Apply()`。

#### 配置项（`MonetUIDB.nameplates`）

| 键 | 默认 | 说明 |
|----|------|------|
| `showEnemy` / `showFriendly` / `showNPC` | `true` / `false` / `false` | 敌方（玩家+NPC）/ 友方玩家 / 友方 NPC |
| `showMinor` / `showTotems` / `showSelf` | `true` / `true` / `false` | minus 敌人 / 图腾 / 自己 |
| `hideCritters` / `hideDead` | `true` / `false` | 过滤小动物 / 死亡单位 |
| `viewDistance` | `60` | `nameplateMaxDistance` |
| `width` / `height` | `120` / `12` | 血条框尺寸 |
| `nameSize` | `11` | 名字/等级字号（百分比与施法文字小 1px） |
| `showName` / `showLevel` / `showPercent` | `true` | 名称 / 等级+精英标记 / 血量百分比 |
| `truncate` / `nameLength` | `true` / `16` | 名称截断与长度 |
| `showCast` / `castHeight` | `true` / `13` | 施法条与高度（带图标） |
| `showThreat` / `highlightTarget` | `true` | 仇恨描边（红/橙）/ 当前目标描边高亮 |
| `showDebuffs` / `auraGap` | `true` / `4` | 借用暴雪减益列表与间距 |
| `classColor` | `true` | 职业/阵营着色（`UnitSelectionColor`，被抢的单位转灰） |
| `smooth` | `true` | 血条数值平滑过渡（同单位框架） |
| `forcePlateSize` | `true` | 把暴雪点击区对齐到绘制的框 |

#### 尚未覆盖（本版不做）

名字牌模式（只显示名字）、姓名板**堆叠/间距** CVar、目标板的职业资源、以及对姓名板的**拖动**
（板的位置由暴雪决定并始终贴着单位头顶）。

### 界面美化（Skins）

#### 为什么加这一层

在姓名板之前，MonetUI 只美化了"战斗 HUD"（单位框、动作条、背包、Buff、小地图、追踪），而玩家停留时间
最长的**暴雪原生窗口**（任务、世界地图、角色、收藏、社交、邮件/商贩/拍卖、弹窗/设置）依旧是原版外观 ——
于是整套 UI 风格是断的。这一层把那些窗口也拉进同一套 Monet 材质与配色。

参考实现（Andromeda / EllesmereUIBlizzardSkin / ElvUI Skins / ForeverUI）的做法分两种：

| 路线 | 代表 | 做法 |
|------|------|------|
| **皮肤引擎 + 逐窗口皮肤** | ElvUI（约 135 个文件）、Andromeda（三注册表 + 90+ 文件）、EllesmereUI（`WSkin.RegisterWindow` + 45 个 window pack） | 抹掉原画（`StripTextures`）→ 铺底（`CreateBackdrop`）+ 重做控件（`Handle*/Reskin*`）→ `hooksecurefunc` 追动态更新；颜色统一取一个调色中枢 |
| **只做 HUD，不碰暴雪窗口** | ForeverUI | 刻意不动世界地图 / 角色界面 / 任务日志，只把背包/聊天/小地图/冷却换皮 |

MonetUI 取两者之间：**做引擎 + 分窗口皮肤（ElvUI 路线）**，但**不复制任何一份 Andromeda/ElvUI 代码**，
且因为已经有 `Utils/Color.lua` + `Utils/Widget.lua` + `Utils/Media.lua` 这套统一底色，皮肤代码量远小于
ElvUI（它们要自己维持一套主题，我们只是接进去）。

#### 分层

```
Modules/Skins/Skins.lua      引擎：注册表 + 生命周期 + 完整回退 + 全局字体
Modules/Skins/*.lua          分窗口皮肤（Quest / WorldMap / Character / Collections / Social / Trade / System）
Utils/Skin.lua               皮肤原语（剥皮、底板、按钮/页签/滚动条/复选框/下拉/编辑框/图标、字体/着色）
```

- 每个窗口在文件加载时 `Skins:Panel(key, { group, label, apply, default })` 登记；`apply` 必须**幂等**。
- 引擎在 `PLAYER_LOGIN` 应用一次，`ADDON_LOADED`（暴雪窗口按需加载）与 `PLAYER_ENTERING_WORLD`
  （编辑模式/读条可能重建）各再应用一次；已在用的窗口因幂等而几乎零成本。
- `MONETUI_THEME_CHANGED` 时皮肤自己注册的"补色"闭包（`Skin:OnTheme`）与普通 `Widget:Theme` 一起刷新。

#### 与既有主题管线的关系（这就是"材质 / 色彩统一"）

皮肤**不新造一套配色**，而是复用现有管线：

1. 底板 / 边框一律 `Skin:Panel(frame)` → `Widget:Theme`，于是边框色相自动跟随
   `Color:GetBorderKey()`（配置面板「边框颜色」那一个下拉即可给**所有**窗口换框色）；
2. 文本一律 `Skin:Font` → `Media:Font` + `Widget:ColorText`，与其它模块同一字体、同一色槽；
3. 我们额外画的条/拇指/下划线（`Skin:OnTheme` 注册）同样读 `Color:GetBorder()`；
4. **语义色不动**：品质色、职业色、血/资源/危险色保持原样，只"Monet 化"底板/边框/页签/字体这些
   *chrome* —— 与 4.3 的"health / resource / danger 不做 Monet 化"一致。

#### 安全与可逆（对齐 ActionBars / Nameplates 的既有原则）

- **只改贴图，不动脚本/父级**：整层**从不**对暴雪框体 `SetScript` / `SetParent` / `SetShown` / `Hide`。
  剥皮只是把原画 `SetAlpha(0)`、底板是挂一个**属于我们自己的**子框体；暴雪按钮的悬停反馈用
  `HookScript`（保留原有脚本）实现。
- **可回滚**：每次对暴雪对象的改动都记一条还原闭包（`Skin:Record`），我们自建的框体只做显隐
  （`Skin:Track`）。关掉模块（`/mui Skins off` 或配置勾选框）时 `Skin:Rollback` + `HideAdded`
  **即时还原、无需重载**，再打开则重新应用。
- **不误伤图标**：剥皮只作用于**框体自身的区域**（`frame:GetRegions()`），不递归进子按钮；批量美化子按钮
  时用 `SkinButtonsIn`，**跳过带 `icon` 字段的物品按钮**（任务奖励、坐骑/宠物/幻化条目、动作技能行等）。
- **受限值无关**：这些窗口都在非战斗场景操作，皮肤本身不读任何单位数值，因此不新增保密值风险；
  仍然不注册任何受限事件。

#### 逐窗口开关

每个窗口是一个开关，存于 `MonetUIDB.skins.panels[key]`（缺省用各自登记时的 `default`）。窗口分组
（任务 / 地图 / 角色 / 收藏 / 社交 / 交易 / 系统）与开关一起呈现在配置面板「界面美化」一栏。**开启**
即时生效；**关闭**某一窗口后其暴雪原画要下次 `/reload` 才完全回来（与 ElvUI/Andromeda 的皮肤一致），
面板里有提示。

默认开启：任务日志、任务/对话窗口、世界地图、角色界面、观察、收藏、成就、冒险指南、好友/查询、社区、
公会、日历、邮箱、商贩、训练师、拍卖行、专业/制造、银行、拾取/掷骰、确认弹窗、游戏菜单、设置面板、
插件列表。默认关闭（较激进）：**下拉菜单**、**统一字体（全局）**、**鼠标提示边框**。

#### 全局字体（可选）

`MonetUIDB.skins.font`（`off` / `pixel` / `roadway` / `number`）：开启后替换暴雪**共享字体对象**
（`GameFontNormal*` / `GameFontHighlight*` / `NumberFontNormal*` 等）的字体，让原生静态文本也统一。
默认 `off`：它一次影响所有窗口文字，交由玩家显式选择；**关闭需重载**（与逐窗口开关同理）。

#### 已知限制（本版不做 / 需游戏内调）

- 各暴雪窗口的**内部条目**（任务正文、奖励物品、列表行）刻意不动，所以它们仍是原版字体与间距；
  想让正文也统一，开「统一字体（全局）」。
- 暴雪窗口的**框架名 / 子控件名在不同版本会变**：皮肤全部经 `_G[name]` 取用并对缺失静默跳过，
  所以某版本缺了一个名字只会少美化那一个控件，不会报错 —— 代价是**静默失效**。
  这已不再靠猜：每个窗口把"期望存在的暴雪对象"登记在自己的 `frames` 清单里，
  **`/mui skins diagnose`** 逐条与当前客户端比对并打印 found/missing，
  按打印出的缺失名单一次性补名字即可（`/mui nameplates diagnose` 对本模块同理）。
  走 `module:HandleCommand(rest)` 通用转发，`Core` 不知道任何具体子命令。
- **下拉菜单**与**编辑模式（Edit Mode）**自带的弹层样式未覆盖。

### 字体资源

| 字体 | 文件 | 用途 | 来源 |
|------|------|------|------|
| 中文像素字体 | `Pingfangpixel.ttf` | 所有中文文本 | 第三方字体，随 Andromeda 的 `assets/fonts/` 一并提供 |
| 战斗字体 | `combat.ttf` | 仅数字（伤害/治疗数值） | 同上 |
| 冷却字体 | `super-effective.ttf` | 动作条冷却计时数字 | 同上 |
| 标题字体 | `roadway.ttf` | 标题/装饰（配置面板标题、任务追踪标题、背包标题） | 同上 |

> 以上 4 个字体按**用户确认**可继续使用（不涉及版权问题），继续随包分发，文件名与路径保持不变。
> 字体路径在 `Utils/Media.lua` 里由 `ADDON_NAME` 拼出，因此**安装目录必须叫 `MonetUI`**。
> Buff/Debuff 图标上的持续时间数字使用 `pixel` 字体（中文友好），不使用 `combat`。

### 参考与致谢

MonetUI 的**代码与素材均为独立实现**：没有引入 oUF 等第三方框架，UI 控件、事件总线、
保密值处理、模块注册、拖动保存都是本项目自己写的。

以下第三方内容需要说明：

| 内容 | 说明 |
|------|------|
| 4 个字体文件（`Assets/Fonts/`） | 第三方字体；按**用户确认**不涉及版权问题，继续保留 |
| `Libs/LibActionButton-1.0/` | **BSD-3-Clause** 第三方库（作者 nevcairiel），取自 Andromeda 随包的 forever 适配版。MonetUI 只做了 3 处改动，全部标有 `MonetUI change:`：库名改为 `LibActionButton-1.0-MonetUI`、静态引用的 LibCustomGlow 改为标准 LibStub 查找、缺 CallbackHandler 时用内联空实现。BSD-3 与 GPL-3 不冲突（BSD 代码既可作为 GPL 项目的一部分，也可被独立项目使用），所以它不会把 MonetUI 拖进 GPL。许可原文见 `Libs/LibActionButton-1.0/LICENSE.txt` |
| 布局坐标与尺寸数值 | 参考 **Andromeda**（GPL-3.0）的 `modules/unitframe/unitframe.lua`、`gui/configs.lua` 与 `core/uiscale.lua`。布局思路与数字本身不受版权保护，且已按 MonetUI 的 1:1 坐标系重新取值（血条高度即取其实际厚度的约 50%） |
| 界面美化（Skins）思路 | 参考 **EllesmereUIBlizzardSkin**（window engine + 逐窗口 pack）、**Andromeda**（theme 注册表 + 逐面板 reskin）、**ElvUI Skins**（sink 注册 + `StripTextures`/backdrop）与 **ForeverUI**（刻意只做 HUD）。只借鉴**分层与接口用法**，Lua 全部独立实现，未拷贝任一份代码 |
| 动作条架构 | 参考 Andromeda（GPL-3.0）`modules/actionbar/` 的**结构与取值**：header + `_onstate-page` + `RegisterStateDriver` 的分工、每页 12 槽的编号方式、`fullPage` 条件串与各条固定页号、"重定位暴雪框体"而非销毁。这些是接口用法与配置值，不含 Andromeda 的代码 |
| 小地图矩形遮罩 | 起初拷贝了 Andromeda 的 `rectangle-mask.blp`；现已**改为自绘**（`tools/make-minimap-mask.ps1` 生成并自校验） |

> Andromeda 以 **GPL-3.0** 发布，而 GPL 具有传染性：若 MonetUI 的分发中包含 Andromeda
> 受版权保护的**代码**，MonetUI 亦须以 GPL-3.0 发布并附源码。因此 MonetUI 的 Lua 全部独立
> 重写，只借鉴**布局思路、接口用法与数值**（不受版权保护），不含 Andromeda 的任何代码。
> 文件级的分发只有两类：4 个字体（已确认不涉及版权）与 BSD-3 的 `Libs/LibActionButton-1.0/`
> （按许可允许再分发，且与 GPL 不冲突）；小地图遮罩已换成自绘。

---

## 六、开发计划

### Phase 0: 框架搭建 ✅
- [x] 创建目录结构
- [x] 编写 Utils 层（Math/Secrets/Media/EventBus/Color/Widget）
- [x] 编写 Core.lua 核心入口
- [x] 编写 Config 配置框架
- [x] 编写各模块占位文件
- [x] 嵌入 LibStub 和 LibMonetColor
- [x] 修复 require 路径问题
- [x] Lua 5.1 兼容性检查
- [x] wuxian check 语法验证
- [ ] wuxian load 热加载验证（需游戏运行）

### Phase 1: 核心模块开发 ✅
- [x] UnitFrames 单位框架（P0）— 玩家/目标/焦点/宠物、保密值适配、拖动保存
- [x] UnitFrames 细条化（160/160/60/60 × 8，文字移至条上方，锚点照搬 Andromeda）
- [x] Cooldown 冷却计时（P0）— 数字/充能字体 + 技能状态着色
- [x] 与 MonetColor 联调（`Color:Refresh` + 区域变化刷新 + `OnThemeColorsChanged` 回调订阅，见 4.3）
- [ ] 游戏内验证（需游戏运行）

### Phase 2: 功能模块开发 ✅
- [x] BuffFrame（P1）
- [x] Minimap（P1）— 矩形化 256×190
- [x] BagFrame（P1）
- [x] QuestTracker（P2）
- [x] ActionBars（P2）— 1–8 号自绘动作条（LibActionButton-1.0）+ 接管宠物/姿态条 + 隐藏暴雪动作条与背包条
- [x] Nameplates（P2）— 暴雪底座 + 自绘细条、CVar 接管、借用暴雪减益、施法条、仇恨/目标描边、点击区同步
- [x] Skins（P2）— 界面美化：皮肤引擎（Utils/Skin.lua + Modules/Skins/）+ 分窗口皮肤（任务/地图/角色/收藏/社交/交易/系统）
- [ ] 游戏内视觉验收（需游戏运行）

### Phase 3: 完善与发布
- [x] 配置面板完善（绑定 MonetUIDB，实时生效）
- [x] 单位框架新增：能量条按类型分色、死亡/掉线变灰、数值平滑过渡（配置面板可选）
- [x] 单位框架新增：连击点小格（盗贼 / 德鲁伊）+ 「连击点（盗贼 / 德鲁伊）」配置下拉
- [x] 主题预留：所有边框经 `Widget:Theme` → `Color:GetBorder()`（色槽可选，配置项「边框颜色」），并订阅引擎 `OnThemeColorsChanged` 即时换色
- [ ] 游戏内视觉验收
- [ ] 压力测试
- [x] 文档编写（MonetUI.md）
- [ ] 发布 v1.0.0

---

## 七、验收标准

- [ ] 插件可在 WoW 中加载无报错 **（待游戏运行验证）**
- [x] 模块可独立开关（`/mui <模块> on|off` + 配置面板）
- [x] MonetColor 缺失时优雅降级（内置调色板）
- [x] 配置面板可保存设置（MonetUIDB）
- [ ] 内存占用 < 5MB
- [x] 代码无重复（通过 Utils 复用）
- [x] Lua 5.1 兼容（`wuxian check` 0 error / 1 intended warning：覆写 `GetMinimapShape`）
- [x] Forever 保密值安全（所有单位数值读取先查询 C_Secrets）
- [x] 不注册受限事件（无 CLEU）
- [x] 姓名板可完整回退（关闭模块 / 过滤单位：暴雪姓名板、CVar、点击区尺寸全部还原）
- [x] 界面美化（Skins）可逐窗口开关；关闭模块即时完整回退（暴雪原画 / 字体 / 底板全部还原，无需重载）

---

## 八、决策记录

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-10-13 | 不引入 Ace3 | 减少依赖，自制轻量配置面板 |
| 2026-10-13 | 不引入 Masque | 直接控制纹理和颜色 |
| 2026-10-13 | 模块间通过 EventBus 通信 | 松耦合，便于维护 |
| 2026-10-13 | MonetColor 可选依赖 | 缺失时优雅降级 |
| 2026-10-13 | 不引入 oUF | 自制简化版单位框架，减少依赖 |
| 2026-10-13 | Lua 5.1 兼容 | WoW 客户端使用 Lua 5.1 |
| 2026-10-13 | require 改为全局表引用 | WoW .toc 加载机制不支持 require |
| 2026-10-13 | 字体分工：Pingfangpixel=中文文本，combat=仅数字 | 避免战斗字体渲染中文时的像素风格不一致 |
| 2026-10-13 | 字体来源 Andromeda assets/fonts/ | 已复制到 MonetUI/Assets/Fonts/ |
| 2026-10-15 | 跨文件共享改用插件 `ns` 命名空间 | .toc 文件返回值被丢弃，`return X` 方案是坏代码 |
| 2026-10-15 | 目标客户端 Interface = 16001 ("camelot") | 无限客户端 API 手册推算值 |
| 2026-10-15 | 全部单位数值访问走 Utils/Secrets.lua | 客户端在受限状态返回 `<secret>`，直接运算会报错 |
| 2026-10-15 | EventBus 改为按需注册事件 | 固定事件表会注册受限/未知事件导致报错；且绝不能注册 CLEU |
| 2026-10-15 | 使用现代命名空间 API（C_Spell/C_ActionBar/C_Container/C_UnitAuras） | 客户端手册中无 UnitAura/GetSpellInfo 等旧全局 |
| 2026-10-15 | 主动订阅 LibMonetColor 的 `OnThemeColorsChanged`（做注册形态探测：CallbackHandler / 内置回退两路都试、都 pcall） | 原决定因两种注册签名不一致而放弃回调；探测后两路都能接上，边框与血条可随引擎换色**即时**刷新；区域事件刷新保留为兜底 |
| 2026-10-15 | 接管暴雪框架采用 oUF 式 UnregisterAllEvents + Hide | 业界通行做法；配置项可关闭（`hideBlizzard`） |
| 2026-10-15 | 单位框细条化 = Andromeda 几何（血 4 / 能量 1 / 间隔 1 + 1px 边框） | 尺寸存入 `MonetUIDB.unitFrames`，方便后续微调 |
| 2026-10-15 | 单位框文字全部置于条上方 3px | 照搬 Andromeda tag 锚点（`BOTTOM*` → `TOP*`, 0, 3） |
| 2026-10-15 | focus 偏移改回 Andromeda 的 `-100` | 单位框已细条化到 60 宽，不再需要外推 |
| 2026-10-15 | 小地图矩形化用遮罩纹理（256×256 裁上下各 33px → 256×190） | 与 Andromeda 的 `rectangle-mask` 同法，保持圆形画布不动 |
| 2026-10-15 | 隐藏暴雪动作条/背包条用「重定位到隐藏父框」而非销毁 | 按键仍然可用，且不动 Blizzard 的动作条逻辑 |
| 2026-10-15 | 新增 targettarget 单位框（60×6，居中名字） | 照搬 Andromeda `Positions.tot` = target `RIGHT` +(6,0) |
| 2026-10-15 | 单位框拖动后按依赖顺序重排（player→target→targettarget） | 链式锚点（目标的的目标挂在目标上）也要跟随移动 |
| 2026-10-15 | 小地图去掉坐标与时钟 | 右下角位置紧凑，用户不需要这两项文本 |
| 2026-10-15 | 血条高度 4 → 2（= Andromeda 实际厚度的约 50%） | Andromeda 会 `UIParent:SetScale(clamp(768/屏幕高, .4, 1.15))`（1440p≈0.53），照抄 4 会厚近一倍 |
| 2026-10-15 | 血条着色 = 底层「损失」贴图 + 上层 StatusBar 填充 | 两层都不读单位数值，受限状态下着色依然正确（保密值安全） |
| 2026-10-15 | 玩家/宠物：当前=高亮、损失=黑；目标/焦点/目标的目标：当前=`UnitSelectionColor`、损失=danger | 一次调用即得职业色（玩家）/反应色（NPC），且不返回保密值，无需身份守卫 |
| 2026-10-15 | 血量数字按百分比 4 定点插值着色（绿→黄→橙→红） | 避免红绿直接线性插值经过脏褐色，对色盲也更友好 |
| 2026-10-15 | 新增 `SCHEMA` 迁移，默认值语义变化时显式覆盖旧存档 | `MergeDefaults` 只补缺失键，改了数值的老存档不会自动更新 |
| 2026-10-15 | 小地图遮罩改为自绘（`tools/make-minimap-mask.ps1`） | 去掉对 Andromeda `rectangle-mask.blp` 的文件级拷贝，规避 GPL 传染 |
| 2026-10-15 | 素材策略：只借鉴布局思路与数值，不做文件级拷贝 | Andromeda 为 GPL-3.0；小地图遮罩已自绘，4 个字体经确认不涉及版权 |
| 2026-10-15 | 字体文件保留（`Assets/Fonts/` 4 个） | 用户确认字体不涉及版权问题，无需替换 |
| 2026-10-15 | 血条/能量条用 `Enum.StatusBarInterpolation.ExponentialEaseOut` 平滑 | 插值在客户端内部完成（`SecretAspect.BarValue`），机密值同样可走平滑路径 |
| 2026-10-15 | 死亡/掉线用 `StatusBar:SetStatusBarDesaturated` 变灰 | 变灰由客户端完成（`SecretAspect.Desaturation`），不需要读数值 |
| 2026-10-15 | 能量条按 `UnitPowerType` 分色，自带 `POWER_COLOR` 表 | 旧实现依赖未文档化的全局 `PowerBarColor`；自建表可调且不产生全局依赖 |
| 2026-10-15 | 配置面板血条风格用**自绘下拉**，不用 `UIDropDownMenu`/`MenuUtil` | 暴雪菜单框架不在文档化 API 内且各版本不同；自绘可套用 Monet 主题、零模板依赖 |
| 2026-10-15 | 动作条走"藏掉暴雪、自建安全按钮"路线（Bartender4/Dominos/ElvUI/Andromeda 同路），只有 Masque 那种纯美化才去改暴雪按钮 | 暴雪按钮绑死编辑模式与自己的排版，外部改动会被改回；安全模板按钮由客户端施法，战斗中不失效 |
| 2026-10-15 | 按钮用**随包的 LibActionButton-1.0**（BSD-3）而不是自己手写 | 手写要覆盖拖放、冷却、堆叠、射程、可用性、按键、翻页等一大堆边界情况；BSD-3 与 GPL 不冲突，不会带来许可问题 |
| 2026-10-15 | 翻页放在安全环境里（header + `_onstate-page` + `RegisterStateDriver`），固定条挂常量页号 | 载具/覆盖/变形换页是客户端行为，Lua 插手既不安全也不及时 |
| 2026-10-15 | 按键用 `SetOverrideBindingClick` 指到自绘按钮，沿用暴雪的绑定名 | 玩家的旧按键设置零迁移；暴雪按钮仍在（只是藏起来），覆盖绑定优先，失效也只是回到暴雪行为 |
| 2026-10-15 | 宠物/姿态条**接管但不重画**（搬出父框体 + 等比缩放 + 裁图标） | 重画要重新实现暴雪的图标/自动施法/形态逻辑；只搬家则永远不失同步，代价是暴雪重排后要在战斗外放回去 |
| 2026-10-15 | 自绘动作条建不出来时**放弃接管并保留暴雪动作条**，同时打印提示 | 宁可不好看，也不能让玩家一下子失去全部技能 |
| 2026-10-15 | 堆叠数量的显隐自己管（`Count:Hide/Show`） | 库里对 Count 只 `SetText` 不控制显隐，配置项能随时开关而不需要重载 |
| 2026-10-15 | 快捷键缩写成 `s1` / `MU` 等（`SetText` 钩子 + `SetFormattedText` 回写） | 完整键名（如 `SHIFT-1`）会顶出 28px 按钮；用 `SetFormattedText` 回写可避开自我递归 |
| 2026-10-15 | 宠物/姿态条搬**最外层容器**（`PetActionBarFrame`，退回 `PetActionBar`） | 暴雪可能 Hide 外层也可能 Hide 内层；搬外层时两种做法都还归它管，不会留下一条"停尸"的宠物条 |
| 2026-10-15 | 动作条这一版**不做拖动**，位置交由默认锚点 + `positions` 覆盖 | 按钮都是安全按钮，把拖动挂到按钮上会抢掉"从条上拿起技能"；解锁模式（条框体留边、拖动条本身）留给下一版 |
| 2026-10-15 | 默认布局：`barCount = 3`，1/2/3 底部居中往上叠；宠物条右对齐、姿态条左对齐放在 3 号条上方那一行；4–8 号条继续往上叠但默认隐藏 | 玩家指定的布局：底部三条 + 宠物/姿态一行，其余按需往上加，不占屏幕 |
| 2026-10-15 | 盗贼/德鲁伊的连击点自己做（`CLASS_POWER` 表 + 一格一个 `StatusBar`），不接暴雪的 `PlayerFrame.classPowerBar` | 暴雪的连击点是 `PlayerFrame` 的**子框体**，`SuppressBlizzard` 一 Hide 父框体就一起消失；接暴雪显示等于被它的接管逻辑牵着走，自己画完全可控 |
| 2026-10-15 | 连击点用「一格一点的细条」而不是第二条能量条 | 连击点本身是**离散**资源：暴雪默认、Andromeda/oUF 的 ClassPower 都用点阵；细条表达不了「几点」 |
| 2026-10-15 | 每格 `StatusBar` 范围写 `(i-1, i)`，把原始点数直接交给 `SetValue` | 裁剪由客户端完成，我们不做比较/减法 —— 数值是 `<secret>` 时依然能正确点亮（见 4.6） |
| 2026-10-15 | 上限读不到时沿用上次格数（首次用职业默认值），不重排 | 机密值出现/消失时整排格子弹跳比格数略不准更糟 |
| 2026-10-15 | 死亡骑士符文与「充能连击点」高亮本版不做 | 符文是冷却驱动（参考实现读 `GetRuneCooldown`）且有血液/冰霜/邪恶分色；先把盗贼这类「点数型」资源做扎实，符文留给 P3 ResourceBars |
| 2026-10-15 | `CLASS_POWER` 只列盗贼与德鲁伊 | Forever 版本没有圣能/气/灵魂碎片/奥术充能/精华这些职业资源，写了也是死代码；表结构是通用的，该版本将来补了再加一行即可 |
| 2026-10-15 | 配置面板高度改为按内容自适应（`panel:SetHeight(math.abs(y) + 78)`），提示行改挂面板底部 | 行数只增不减，硬编码 800 已经装不下（最后几行与提示会跑到面板外） |
| 2026-10-15 | 边框颜色改为**可选引擎色槽**（`theme.borderKey`，默认 `edge`），`Widget:Theme` 支持 `borderKey` 按控件覆盖 | 预留「边框用哪个 MonetColor 色槽」的可能；集中成一个配置项，模块零改动即可整体换色；透明度仍取 edge 的，避免选 ambient 后边框淡到看不见 |
| 2026-10-15 | 姓名板挂在**暴雪姓名板底座**（`C_NamePlate.GetNamePlateForUnit`）上，不自建、不引入 oUF | 底座已经免费提供跟随/点击/选目标/软目标/池化复用；oUF 要重做这些，收益为负 |
| 2026-10-15 | 藏掉暴雪姓名板用 `UnitFrame:Hide()`，**不销毁** | 关闭模块或被过滤的单位要能原样还原（`ApplyFrameOptions` + 显示回来） |
| 2026-10-15 | 减益光环**借用暴雪**：把 `UnitFrame.AurasFrame` 重挂到自己板上，不读 `C_UnitAuras` | 受限状态下插件读不到光环，而暴雪自己的板仍能画；只借位置，不借数据（ForeverUI 技巧） |
| 2026-10-15 | "显示哪些单位"通过**拨客户端 CVar**（`nameplateShow*` / `nameplateMaxDistance`），并在关闭时原样写回 | 有没有姓名板是客户端决定，插件无法事后加板；记下旧值逐个还原，不残留 |
| 2026-10-15 | 敌对分类 = `UnitIsFriend("player", u)` 为假（**敌对玩家与敌对 NPC 都算**），友方 NPC 单独一档 | 只按 `UnitIsPlayer` 分会把"敌方开关"错配到友好 NPC，反而管不到怪物 |
| 2026-10-15 | 点击区尺寸**只用文档化的** `C_NamePlate.SetNamePlateSize`（特性探测 + pcall），并从代码里**删掉**曾从参考插件看来的 `SetNamePlateEnemySize/FriendlySize`；hook `NamePlateDriverFrame.UpdateNamePlateOptions` 重盖 | `api_search` 实测该命名空间 `siblings` 只有 `GetNamePlateForUnit/GetNamePlateSize/GetNamePlates`，**没有**按阵营 setter；本模块对所有板用同一套宽高，那两个本就冗余。参考插件的对象不能当本客户端的依据 |
| 2026-10-15 | 战斗中不改点击区尺寸，记 `sizePending` 到 `PLAYER_REGEN_ENABLED` 补做 | `InCombatLockdown` 下改姓名板尺寸是受保护操作，会失败甚至报错 |
| 2026-10-15 | 施法条填充用**只算 `GetTime()*1000`** 的 OnUpdate 交给 `SetValue`，倒计时文字仅在结束时间可读时生成 | 填充的裁剪由客户端完成（保密值也可），文字要真算术，读不到就留空（见 4.6） |
| 2026-10-15 | 姓名板整体走 `Widget:Font/Bar/CreateFrame` + `Widget:Theme`，边框在 `MONETUI_THEME_CHANGED` 后按仇恨/目标重刷 | 与其它模块同一套主题管线；主题监听器先跑，模块后跑，同 tick 内边框覆盖胜出 |
| 2026-10-15 | 新增界面美化层 `Skins`：走"皮肤引擎 + 逐窗口皮肤"路线（ElvUI/Andromeda/Ellesmere 同路），而不是 ForeverUI 的"只做 HUD" | 玩家点名要统一任务/世界地图/角色等原生窗口；已有 Color/Widget/Media 底色，接入成本远低于 ElvUI |
| 2026-10-15 | 皮肤**只剥贴图、加自建子框体**，绝不对暴雪框体 `SetScript`/`SetParent`/`Hide` | 避免污染受保护 UI、保留编辑模式布局与暴雪脚本；与动作条"藏而不销毁"、姓名板"藏底座"同一克制原则 |
| 2026-10-15 | 每次改动暴雪对象都记**还原闭包**，自建框体只做显隐 | 模块关闭要能**即时完整回退、无需重载**（对齐姓名板的回退标准） |
| 2026-10-15 | 批量美化按钮时用 `icon` 字段**跳过物品按钮** | 剥皮会抹掉奖励/坐骑/幻化/技能图标；只挑 chrome 按钮重做 |
| 2026-10-15 | 皮肤复用 `Widget:Theme` + `Color:GetBorderKey()` + `Media:Font`，不新造主题 | 一个「边框颜色」下拉即可给所有窗口换框色 —— 这就是"材质/色彩统一" |
| 2026-10-15 | 全局字体替换（暴雪共享字体对象）默认**关闭**，做成显式选项 | 一次影响所有窗口文字，较激进；交给玩家选，且关闭需重载 |
| 2026-10-15 | 下拉菜单/提示边框默认关闭，菜单只染 backdrop 不剥皮 | 菜单背景靠 backdrop 而非区域贴图，剥皮会变透明；菜单框架是版本相关的非文档 API |
| 2026-10-15 | **参考插件的暴雪对象名与函数名一律不采信**：Skins 的窗口/控件名全部按现代暴雪 UI 自写，经 `_G[name]` 防御取用，取不到就静默跳过 | Andromeda 等参考是过期版本、在 Forever 上本就不工作；它的"正确对象"对我们没有约束力。名字错的代价是**静默失效**而非报错，所以更要在客户端上实测 —— 见下一行的 `diagnose` 自检 |
| 2026-10-15 | 新增 `ns.ResolvePath(path)` 共享探测 + 斜杠自检：`/mui skins diagnose` 逐条核对每个皮肤期望的暴雪对象，`/mui nameplates diagnose` 同理 | 把"名字可能不对"从担忧变成可执行的事实清单：打印 found/missing 一次，缺的名字照单补即可。斜杠命令走 `module:HandleCommand(rest)` 通用转发，不给 `Core` 加硬编码分支 |
| 2026-10-15 | 手册优先于参考插件：新用到的 API 先 `api_search`/`api_get` 核对（含 `siblings` 成员表与 `SecretArguments` 限制），拿不准就留特性探测 + pcall | `wuxian check` 的 `api-unknown` warning 就是这类"抄来的名字"的报警器；本次据此清零了姓名板 8 处 |

---

## 九、关键资产索引

| 资产 | 路径/位置 | 说明 |
|------|-----------|------|
| MonetColor 引擎 | `monetcolors\LibMonetColor-1.0.lua` | 色彩计算引擎 |
| MonetColor 测试 | `monetcolors\test_phase1.lua` | 45 个单元测试 |
| Andromeda 参考 | `wowaddonsdev\Andromeda\` | UI 设计参考 |
| Andromeda forever 参考 | `wowaddonsdev\Andromedaforever\` | 动作条（`modules\actionbar\`）架构与取值参考 |
| LibActionButton-1.0 | `MonetUI\Libs\LibActionButton-1.0\` | 动作按钮库（BSD-3），随包 |
| EllesmereUI 参考 | `wowaddonsdev\EllesmereUI-v9.4\` | 模块实现参考 |
| ForeverUI 参考 | `wowaddonsdev\ForeverUI-0.4.24\` | 轻量实现参考 |
| wuxian MCP | 已连接 | 游戏内调试工具 |
| PortableGit | `wowaddonsdev\PortableGit\` | 版本管理 |
