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
- 区域环境取色数据（mapID -> HSL），由 `gen_map_env.ps1` 从游戏截图取色管线
  自动生成，勿手改；供 LibMonetColor 的默认环境采样器惰性查找。

## 为什么把它放进包里

（原来的 LibActionButton-1.0 已经移除：动作条改成完全自建，不再依赖任何动作条库。
  2026-10-22 起 `Modules/ActionBars/ActionBars.lua` 直接用客户端的
  `SecureActionButtonTemplate` + `actionpage` 属性自绘按钮，
  库文件与本节一并删除。）

