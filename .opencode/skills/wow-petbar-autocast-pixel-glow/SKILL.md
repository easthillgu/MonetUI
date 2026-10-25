---
name: "wow-petbar-autocast-pixel-glow"
description: "宠物动作条『自动施法』提示：把暴雪的旋转蚂蚁（AutoCastOverlay.Shine）换成自绘的像素环（MonetUI 已实现，Widget:PixelGlow）。当用户要求宠物动作条/自动施法按钮加 glow、去光效、替换闪光动画时调用。"
---

# 宠物动作条自动施法 Pixel Glow（MonetUI 版）

> **本仓库已经实现**（自绘方案，不引第三方库）：
> `Utils/Widget.lua` 的 `Widget:PixelGlow` / `Widget:StopPixelGlow` 负责画环，
> `Modules/ActionBars/ActionBars.lua` 的 `SyncPetGlow` 负责跟状态、摁掉暴雪的蚂蚁。
> 本文同时记录通用（ElvUI + LibCustomGlow）教程里**在本客户端不成立**的地方，避免照抄。

## 何时使用

- 用户要求给宠物动作条的「自动施法」按钮加发光 / glow 效果
- 用户要求去掉原版那圈转动的闪光
- 用户想调整像素环的样子（方块大小、间距、圈数、跑一圈几秒、颜色）

## 本客户端实情（WoW Forever / Interface 16001，源码已核对）

### 1. 原版闪光不是 `AutoCastShine`

暴雪源码里 `AutoCastShine` / `AutoCastShine_AutoCastStart` **0 命中**。本客户端宠物条的自动施法提示
是按钮上的 `AutoCastOverlay`（`AutoCastOverlayTemplate` + `AutoCastOverlayMixin`）：

| 部件 | 内容 | 处理 |
|---|---|---|
| `overlay.Shine` | Texture，atlas `UI-HUD-ActionBar-PetAutoCast-Ants`，`Rotation -360° / 4s` 循环 | **要替换的就是它** |
| `overlay.Mask` | MaskTexture `UI-HUD-ActionBar-PetAutoCast-Mask`，裁 Shine 的边缘（45-8 = 37 的窗口） | 留着不管 |
| `overlay.Corners` | Texture `UI-HUD-ActionBar-PetAutoCast-Corners`（"可自动施法"角标） | **必须保留** |

驱动链路（`Blizzard_UIPanelTemplates/Mainline/AutoCastTemplates.lua`）：

```lua
function AutoCastOverlayMixin:ShowAutoCastEnabled(isEnabled)
    self.autoCastEnabled = isEnabled
    self:UpdateShineAnim()          -- -> Shine.Anim:Play() + Shine:SetShown(true)
end
```

`Blizzard_ActionBar/Shared/PetActionBar.lua:399` 每次刷新按钮状态都会重置它：

```lua
self.AutoCastOverlay:SetShown(autoCastAllowed)
self.AutoCastOverlay:ShowAutoCastEnabled(autoCastEnabled)
```

→ 所以「藏一次 Shine」不够，**每次刷新后都要再压一次**。本仓库的做法是把 mixin 方法本身换掉（见下）。

### 2. `GetPetActionInfo` 的返回值顺序

```
name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID, checksRange, inRange
```

`autoCastEnabled` 是**第 6 个**（`autoCastAllowed` 是第 5 个，两个别搞混）。

### 3. MonetUI 的宠物条是「接管暴雪自己的条」，不是自绘

- `Modules/ActionBars/ActionBars.lua`，`ADOPTED_DEFS` 里的 `key = "BarPet"`：
  `containers = { "PetActionBarFrame", "PetActionBar" }`，`pattern = "PetActionButton%d"`，`count = 10`，
  外加 `glow = "autoCast"` 标记这条要画像素环。
- 本客户端没有 `PetActionBarFrame`，实际命中的是全局 `PetActionBar`（现代 `EditModeActionBarTemplate`），
  按钮就是 `_G.PetActionButton1..10`（暴雪 `ActionBar.lua` 按 `buttonName = "PetActionButton"..i` 建的）。
- 接管逻辑在 `AdoptBar()`：只搬容器、缩放、裁图标、按键字体；**图标刷新、冷却、可用性、自动施法状态全都还是暴雪自己的代码在管**。
- **没有** ElvUI 那种 `ACTIONBAR:UpdatePetBar()` / `ACTIONBAR:CreatePetBar()`，别照抄通用教程里的函数名。
- 模块句柄是 `ns:GetModule("ActionBars")`（不是 `F:GetModule('ActionBar')`）。

## 已实现的做法（自绘，不引第三方库）

### 画环：`Utils/Widget.lua`

```lua
Widget:PixelGlow(frame, opts)   -- 开启 / 更新
Widget:StopPixelGlow(frame)     -- 停掉
```

- 环是**一串纯色小方块**沿正方形边框跑（`SquarePoint` 把边长距离映射成 x/y），头亮尾淡，ADD 混合。
- 不带任何贴图：`Media.texture.blank`（`Interface\Buttons\WHITE8X8`）纯白方块 + `SetVertexColor` 上色。
- 画在框体自己的 **ARTWORK** 层：图标之上、按键提示之下。
- 一个共享驱动 `pixelGlowDriver` 跑所有环，**没有环时自己睡下**；框体被藏（宠物条收起）时自动收摊。
- 粗细按**物理像素**算：`像素 = px * Media:Mult() / scale`。
  `scale` 是框体父链上的缩放（宠物条被缩到自绘按钮的大小），所以换 UI 缩放、换按钮大小都是同一个粗细。
- 颜色走主题的 `highlight` 槽；框体登记进 `themed`（`kind = "pixelglow"`），主题一变 `Widget:RefreshThemes` 就回来重上色。

可调参数（`opts`）：`side`（环的边长）、`scale`、`pixel`（方块几物理像素，默认 2）、`spacing`（间距，默认 3）、
`count`（方块数，默认 7）、`period`（跑一圈几秒，默认 3.5）、`alpha` / `headAlpha`、`r,g,b`。

### 跟状态 + 摁掉暴雪：`Modules/ActionBars/ActionBars.lua`

```lua
--- 摁掉暴雪的旋转蚂蚁：把 mixin 方法换成空的，暴雪再怎么刷新都点不亮它。
local function SuppressAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    if not overlay then return end
    if not overlay.monetShineSuppressed then
        overlay.monetShineSuppressed = true
        if type(overlay.UpdateShineAnim) == "function" then
            overlay.monetShineUpdate = overlay.UpdateShineAnim
            overlay.UpdateShineAnim = function() end
        end
    end
    local shine = overlay.Shine
    if shine then
        if shine.Anim then pcall(shine.Anim.Stop, shine.Anim) end
        shine:Hide()
    end
end
```

- `SyncPetGlow(def, entry)`：逐槽位 `GetPetActionInfo(index)` 取第 6 个返回值（`autoCastEnabled`），
  开着就 `Widget:PixelGlow`，关着就 `Widget:StopPixelGlow`。
- **两种形态**：`static = not M.own` ——「自绘动作条」开着时是沿边框跑的动画环，关着时宠物条交还暴雪，
  提示改成**静态的一圈**（`opts.pitch` 点距 4px、`opts.ringAlpha` 0.85，等距铺满，不吃每帧开销）。
- 环的边长跟着暴雪的 `overlay.Mask` 走（那圈蚂蚁就画在这块 37 单位的遮罩里），
  遮罩不在就按按钮宽度推（`(entry.base or 30) + 7`）。
- **状态事件单独跟**（`PET_GLOW_EVENTS` = `PET_BAR_UPDATE` / `PET_BAR_UPDATE_USABLE` / `PET_UI_UPDATE` / `UNIT_PET`）：
  `AdoptAll` 战斗里不动（要搬受保护的框体），但像素环只是往按钮上加几个方块，战斗中开关自动施法也得立刻跟上。
- **还原路径**：`ReleaseBar()` 只把缩放还成 1；**模块整个停用**时才走 `TeardownPetGlow()`
  （拆环 + `RestoreAutoCastShine`），否则玩家会永久失去原版提示。

## 关键注意点

- **不要动 `overlay.Corners`**：那是"这个技能可以自动施法"的角标，和发光无关。
  通用教程里的 `petAutoCastableTexture` 在本客户端对应 `AutoCastOverlay.Corners`。
- **Start / Stop 必须成对**。
- **只挂在按钮本体**（`petActionButton`），不要挂 `button.icon` 之类的子纹理，否则发光区域会偏到图标内部。
- **战斗中**：像素发光和 `AutoCastOverlay`（普通 Frame / Texture）都不是受保护对象，可以开关；
  但别碰按钮的 secure 属性、别在战斗中改受保护的框体（`InCombatLockdown()` 防护 + `PLAYER_REGEN_ENABLED` 重试）。
- **10 个槽位各画各的**，同一个 key / 同一套参数即可（每个按钮自己存自己的环）。
- **`autoCastEnabled` 用 `Secrets.Bool()` 取**（`Secrets.Number` 同理）：本客户端在受限状态下会藏值，
  直接 `if enabled then` 会炸。

## 验收

1. `tools.wuxian.check`（离线 `live: false`）：0 错误 0 警告才算完成。
2. 实机（游戏在线时）：
   - 带宠物 → 宠物条按钮 **右键** 打开自动施法 → 应看到像素方块沿图标边缘跑，**没有**旋转蚂蚁；
   - `Corners` 角标仍在（"可自动施法"提示没丢）；
   - 再右键关掉 → 方块立刻消失，不残留；
   - 战斗中开关自动施法 → 方块立刻跟上；
   - 切主题 → 颜色跟着变；
   - 关掉「自绘动作条」→ 宠物条交还暴雪，提示变成**静态**的一圈像素；
   - 停用 ActionBars 模块 → 环全拆掉，暴雪的旋转蚂蚁回来。

## 附：通用（ElvUI + LibCustomGlow）教程里在本仓库不成立的地方

| 通用写法 | 本仓库实情 |
|---|---|
| `button.AutoCastShine` / `AutoCastShine_AutoCastStart()` | 不存在；改用 `button.AutoCastOverlay` 的 `Shine` 部件 |
| `ACTIONBAR:UpdatePetBar()` / `ACTIONBAR:CreatePetBar()` | 不存在；入口是 `Modules/ActionBars/ActionBars.lua` 的 `AdoptBar()` |
| `F:GetModule('ActionBar')`、`local F, C, L = unpack(select(2, ...))` | `ns:GetModule("ActionBars")`；`ns` 是私有命名空间 |
| 主题色 `C.r / C.g / C.b` | `ns.Color:GetHighlight()`（返回 r, g, b, a） |
| `LibStub("LibCustomGlow-1.0", true)` + `PixelGlow_Start` | 仓库里**没有**这个库；本仓库自绘（`Widget:PixelGlow`）。若真要用库，签名是
  `PixelGlow_Start(r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)`、`PixelGlow_Stop(r, key)`（ElvUI / NDui 的 fork） |
| "不同 frame 共用同一 key 会互相踩踏" | LibCustomGlow 的 glow 存在目标 frame 自己身上（`r["_PixelGlow"..key]`），跨按钮安全；key 只需 Start / Stop 一致 |
| `PetActionBarFrame` | 本客户端只有 `PetActionBar`；`PetActionButton1..10` 仍在 |
