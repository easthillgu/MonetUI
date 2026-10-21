# 字体来源与授权

`Assets/Fonts/` 里每个字体文件的出处与授权，取自文件内嵌的 `name` 表（copyright / license / vendor 字段），逐条对照过，不凭印象。**新增字体必须在这里补一行**，否则一律视为不得分发。

| 文件 | 字体 | 版权 / 作者 | 授权 | 用在何处 |
|---|---|---|---|---|
| `fusion-pixel-12.ttf` | Fusion Pixel 12px Prop zh-Hans | © 2022 TakWolf（https://fusion-pixel-font.takwolf.com） | **SIL OFL 1.1**，全文见 `OFL-FusionPixel.txt` | 主字体 `M.font.pixel`（标题 / 正文） |
| `super-effective.ttf` | Super Effective v1.0 | © The Ender 2012（FontStruct） | **CC BY-SA 3.0**（http://creativecommons.org/licenses/by-sa/3.0/）—— 使用需署名，字体文件本身须以同协议分发 | 冷却数字 `M.font.cooldown` |
| `Pingfangpixel.ttf` | 点阵苹方 | © 2015 DynaComware（DynaComware Shanghai / Hong Kong / Taiwan）；PingFang 为 Apple Inc. 商标 | **无授权声明**（文件内无 license 字段）。苹方系苹果授权字体，衍生成品不得再分发 | 未使用（`Utils/Media.lua` 未引用） |
| `roadway.ttf` | Roadway | © 2005 Keith Bates / K-Type Freebie | **无授权声明**（文件内无 license 字段；K-Type Freebie 的条款以官网当时说明为准） | 未使用 |

## 结论与待办

- 目前只有 `fusion-pixel-12.ttf` 与 `super-effective.ttf` 真正在用。两个在用字体都有明确授权：前者 OFL，后者 CC BY-SA 3.0 —— **发行包里必须同时带上 `OFL-FusionPixel.txt` 与本文件**（CC BY-SA 要求署名）。
- `Pingfangpixel.ttf`（29 MB）与 `roadway.ttf` 未被引用，且都没有可再分发的授权。当前仓库为私有备份，风险可控；**仓库转公开（含 GitHub Release / 网盘分发）前必须先移除这两份，并清理 git 历史**，否则等于分发苹果授权字体。
- 若以后确实要换字体，优先选 OFL 或 Apache-2.0 的像素字体，并在上表补一行。

## 参考

- SIL OFL 1.1 全文：https://openfontlicense.org/
- CC BY-SA 3.0 全文：https://creativecommons.org/licenses/by-sa/3.0/legalcode
