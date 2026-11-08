# Libs — third-party code shipped with MonetUI

MonetUI本身完全自写，只有下面这些文件来自他人，按各自许可随包分发。

## LibStub (`Libs/LibStub/LibStub.lua`)

- 作者：Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke
- 许可：Public Domain（文件头部已注明）
- 未做修改。

## LibMonetColor-1.0 (`Libs/LibMonetColor-1.0/`)

- 自家仓库 `monetcolors` 的产物，非第三方。

## LibMonetColor-Anim-1.0 (`Libs/LibMonetColor-Anim-1.0/`)

- 自家仓库 `monetcolors` 的产物，非第三方（引擎侧的状态染色层：战斗 / 低血 / 休息的判定）。

## MonetColorMapData-1.0 (`Libs/MonetColorMapData-1.0/`)

- 同为自家仓库 `monetcolors` 的产物，非第三方。
- 区域环境取色数据（mapID -> HSL），链条为 monetcolors 仓的
  `extract_game_palette_v1.ps1`（游戏截图 + wuxianwow/trip 照片）→ `data/game_palette_v1.json`
  → `gen_map_env.ps1`，自动生成，勿手改；供 LibMonetColor 的默认环境采样器惰性查找。
- 同目录另有两层运行时覆盖层，同为自家产物、非第三方：`MonetColorMapEnvOverride.lua`
  （3 条大陆 / 世界层父链派生色）与 `MonetColorMapEnvAtlas.lua`（17 区官方地图美术贴图环境色），
  都通过引擎的 `RegisterMapEnv` 注册，优先级高于数据模块；加载顺序见 `Libs.xml`。

## 为什么把它放进包里

（原来的 LibActionButton-1.0 已经移除：动作条改成完全自建，不再依赖任何动作条库。
  2026-10-22 起 `Modules/ActionBars/ActionBars.lua` 直接用客户端的
  `SecureActionButtonTemplate` + `actionpage` 属性自绘按钮，
  库文件与本节一并删除。）

