# MonetUI 开发计划

> **创建日期**: 2026-10-13
> **最后更新**: 2026-10-15（Phase 1 + Phase 2 模块实现完成，等待游戏内验证）
> **当前阶段**: Phase 1/2 — 六个模块已实现并通过 `wuxian check`，待游戏内 `load`/`try` 验证
> **目标**: 为魔兽世界无限 (WoW Forever) 打造一套莫奈风格整合 UI 插件

---

## 一、项目定位

MonetUI 是一套**整合 UI 插件**，以**莫奈印象派色彩**为核心设计语言，为 WoW Forever 提供：

- 自适应环境色彩的动态主题系统
- 模块化 UI 组件（单位框架、冷却、Buff、小地图等）
- 精简依赖、低复杂度的代码架构

**设计原则**：
1. **依赖精简** — 仅依赖 LibStub（必需）+ LibMonetColor（可选）+ CallbackHandler（可选）
2. **模块松耦合** — 模块间通过 EventBus 通信，不直接依赖
3. **私有 API** — 公共工具封装在 Utils 中，避免重复代码
4. **优雅降级** — MonetColor 缺失时使用内置默认配色
5. **Lua 5.1 兼容** — 不使用 5.2+ 特性（`//`、`goto`、`bit32`、`table.unpack`）

---

## 二、当前状态

### 已完成

| 任务 | 状态 | 说明 |
|------|------|------|
| 目录结构创建 | 完成 | 18 个源文件，14 个目录 |
| Utils 层 | 完成 | Widget/Color/EventBus/Math/Secrets/Media |
| 命名空间共享 | 完成 | 统一使用插件私有表 `ns`（`...` 第二个返回值） |
| Core.lua | 完成 | SavedVariables + 模块注册/生命周期 + 主题管线 + 斜杠命令 |
| Config 面板 | 完成 | SimpleConfig.lua，绑定 MonetUIDB，实时生效 |
| UnitFrames | 完成 | 玩家/目标/焦点/宠物，血条/能量/名字/等级/提示，可拖动并保存位置 |
| Cooldown | 完成 | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 |
| BuffFrame | 完成 | 自绘增益/减益网格，按时长排序，可读性守卫 |
| Minimap | 完成 | 边框染色 + 坐标 + 时钟 + 面板 |
| BagFrame | 完成 | 背包排列整合 + 主题边框 |
| QuestTracker | 完成 | 主题边框 + 标题栏拖动 + 位置保存 |
| Forever 保密值适配 | 完成 | Utils/Secrets.lua，全部单位数值访问先查询 |
| Lua 5.1 兼容性检查 | 完成 | 无 5.2+ 特性 |
| wuxian check 语法验证 | 完成 | 0 error / 0 warning |
| 安装到游戏 AddOns | 完成 | 含 Assets/Fonts 共 30.6 MB 已同步 |

### 待完成

| 任务 | 优先级 | 说明 |
|------|--------|------|
| wuxian load 热加载验证 | P0 | 需游戏运行（当前离线） |
| 游戏内视觉验收 | P0 | 三地图验证 + 暴雪框架接管是否产生 taint |
| MonetColor Phase 2 联调 | P0 | 环境采样器（引擎侧） |
| 队伍/团队框架 | P1 | RaidFrames（当前仅单人单位） |
| 聊天框 / 姓名板 / 动作条美化 | P2 | 见模块清单 |
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
│   └── Widget.lua              # 控件工厂 + 主题注册表
├── Modules/                    # 功能模块
│   ├── UnitFrames/             # 单位框架
│   ├── Cooldown/               # 冷却计时
│   ├── BuffFrame/              # Buff 框架
│   ├── Minimap/                # 小地图
│   ├── BagFrame/               # 背包
│   ├── QuestTracker/           # 任务追踪
│   └── ActionBars/             # 动作条（暂只隐藏暴雪默认动作条/背包条）
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
    └── LibMonetColor-1.0/      # 色彩引擎库
```

---

## 四、技术架构

### 4.1 依赖策略

```
必需: LibStub
可选: CallbackHandler-1.0 (有 fallback)
可选: LibMonetColor-1.0 (有 fallback)
不引入: Ace3, Masque, SharedMedia, oUF, cargBags
```

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
| **P0** | UnitFrames | 玩家/目标/目标的目标/焦点/宠物框架，血条能量条、名字等级、拖动保存 | ✅ 已实现 | Andromeda, EllesmereUI |
| **P0** | Cooldown | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 | ✅ 已实现 | EllesmereUICooldownManager |
| **P1** | BuffFrame | 自绘 Buff/Debuff 网格，按时长排序，可读性守卫 | ✅ 已实现 | EllesmereUIAuraBuffReminders |
| **P1** | Minimap | 矩形小地图（256×190）、去圆形边框/指南针、主题面板 | ✅ 已实现 | EllesmereUIMinimap, Andromeda |
| **P1** | BagFrame | 背包排列整合 + 主题边框 + 标题字体 | ✅ 已实现 | EllesmereUIBags |
| **P2** | QuestTracker | 主题边框 + 标题栏拖动 + 位置保存 | ✅ 已实现 | EllesmereUIQuestTracker |
| **P2** | ActionBars | 隐藏暴雪默认动作条与背包条（自绘动作条待建） | 🚧 占位 | EllesmereUIActionBars, Andromeda |
| **P2** | Chat | 聊天框美化 | 待建 | EllesmereUIChat |
| **P2** | Nameplates | 姓名板美化 | 待建 | EllesmereUINameplates |
| **P3** | RaidFrames | 团队框架（队伍/团队） | 待建 | EllesmereUIRaidFrames |
| **P3** | ResourceBars | 资源条 | 待建 | EllesmereUIResourceBars |

### 布局锚点（照搬 Andromeda，`UI_GAP = 33`）

| 元素 | 锚点 | 坐标 | 尺寸（宽 × 高） |
|------|------|------|------|
| player | `CENTER` / UIParent `CENTER` | `(0, -180)` | 160 × 6 |
| target | `LEFT` / player `RIGHT` | `(40, 40)` | 160 × 6 |
| targettarget | `LEFT` / target `RIGHT` | `(6, 0)` | 60 × 6 |
| pet | `RIGHT` / player `LEFT` | `(-6, 0)` | 60 × 6 |
| focus | `RIGHT` / player `LEFT` | `(-100, -40)` | 60 × 6 |
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

`fillColor` / `lostColor` / `textColorByPercent` / `powerColor` / `smoothBars` 都存在
`MonetUIDB.unitFrames`，改值即可换风格；配置面板「单位框架」一栏有对应的下拉与勾选框。

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
| 布局坐标与尺寸数值 | 参考 **Andromeda**（GPL-3.0）的 `modules/unitframe/unitframe.lua`、`gui/configs.lua` 与 `core/uiscale.lua`。布局思路与数字本身不受版权保护，且已按 MonetUI 的 1:1 坐标系重新取值（血条高度即取其实际厚度的约 50%） |
| 小地图矩形遮罩 | 起初拷贝了 Andromeda 的 `rectangle-mask.blp`；现已**改为自绘**（`tools/make-minimap-mask.ps1` 生成并自校验） |

> Andromeda 以 **GPL-3.0** 发布，而 GPL 具有传染性：若 MonetUI 的分发中包含 Andromeda
> 受版权保护的**代码**，MonetUI 亦须以 GPL-3.0 发布并附源码。因此 MonetUI 的 Lua 全部独立
> 重写，只借鉴**布局思路与数值**（不受版权保护），并且不引用 Andromeda 的任何代码；素材方面
> 唯二的文件级拷贝是小地图遮罩（已换成自绘）与 4 个字体（已确认不涉及版权）。

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
- [x] 与 MonetColor 联调（`Color:Refresh` + 区域变化刷新）
- [ ] 游戏内验证（需游戏运行）

### Phase 2: 功能模块开发 ✅
- [x] BuffFrame（P1）
- [x] Minimap（P1）— 矩形化 256×190
- [x] BagFrame（P1）
- [x] QuestTracker（P2）
- [x] ActionBars（P2，占位）— 隐藏暴雪默认动作条与背包条
- [ ] 游戏内视觉验收（需游戏运行）

### Phase 3: 完善与发布
- [x] 配置面板完善（绑定 MonetUIDB，实时生效）
- [x] 单位框架新增：能量条按类型分色、死亡/掉线变灰、数值平滑过渡（配置面板可选）
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
| 2026-10-15 | 不主动接 LibMonetColor 的 CallbackHandler 回调 | 有/无 CallbackHandler 时注册签名不一致，改为监听自身区域事件刷新 |
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

---

## 九、关键资产索引

| 资产 | 路径/位置 | 说明 |
|------|-----------|------|
| MonetColor 引擎 | `monetcolors\LibMonetColor-1.0.lua` | 色彩计算引擎 |
| MonetColor 测试 | `monetcolors\test_phase1.lua` | 45 个单元测试 |
| Andromeda 参考 | `wowaddonsdev\Andromeda\` | UI 设计参考 |
| EllesmereUI 参考 | `wowaddonsdev\EllesmereUI-v9.4\` | 模块实现参考 |
| ForeverUI 参考 | `wowaddonsdev\ForeverUI-0.4.24\` | 轻量实现参考 |
| wuxian MCP | 已连接 | 游戏内调试工具 |
| PortableGit | `wowaddonsdev\PortableGit\` | 版本管理 |
