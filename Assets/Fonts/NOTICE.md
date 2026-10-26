# 字体来源与授权

`Assets/Fonts/` 里每个字体文件的出处与授权，取自文件内嵌的 `name` 表（copyright / license / vendor 字段），逐条对照过，不凭印象。**新增字体必须在这里补一行**，否则一律视为不得分发。

| 文件 | 字体 | 版权 / 作者 | 授权 | 用在何处 |
|---|---|---|---|---|
| `fusion-pixel-12.ttf` | Fusion Pixel 12px Prop zh-Hans | © 2022 TakWolf（https://fusion-pixel-font.takwolf.com） | **SIL OFL 1.1**，全文见 `OFL-FusionPixel.txt` | **备用**（2026-10-26 起主字体改用 PingFangPixel）。仍是全仓最"干净"的一份：真像素字、OFL、可分发。cmap 覆盖 19317/20992 个 CJK 码位 |
| `super-effective.ttf` | Super Effective v1.0 | © The Ender 2012（FontStruct） | **CC BY-SA 3.0**（http://creativecommons.org/licenses/by-sa/3.0/）—— 使用需署名，字体文件本身须以同协议分发 | 冷却数字 `M.font.cooldown` |
| `Pingfangpixel.ttf` | 点阵苹方 | © 2015 DynaComware（DynaComware Shanghai / Hong Kong / Taiwan）；PingFang 为 Apple Inc. 商标 | **无授权声明**（文件内无 license 字段）。苹方系苹果授权字体，衍生成品不得再分发 | **主字体 `M.font.pixel` / `M.font.pingfang`**（2026-10-26 起因 `fusion-pixel-12` 缺生僻字换上来）。cmap 覆盖 20945/20992 个 CJK 码位 |
| `roadway.ttf` | Roadway | © 2005 Keith Bates / K-Type Freebie | **无授权声明**（文件内无 license 字段；K-Type Freebie 的条款以官网当时说明为准） | 未使用 |

## 结论与待办

- 目前**在用**的是 `Pingfangpixel.ttf`（正文 + 数字）与 `super-effective.ttf`（倒计时数字）。
  **前者没有可分发授权**：仓库现在是私有备份，风险可控；**转公开 / 发 Release / 发网盘之前必须先换字**
  （首选 OFL 的像素中文字体，例如 方舟像素 Ark Pixel 12px，或退回 `fusion-pixel-12`，
  代价是生僻字掉 □）。换字只动 `Utils/Media.lua` 的 `Media.font` 一项 + `Media.fontFlags`，其余调用点不用碰。
- `Assets/Fonts/NOTICE.md` 里"新增字体必须补一行"的规矩不变：没有可分发授权的字体，一律不得随发行包出去。
- 2026-10-16 那轮之所以从 PingFangPixel 换到 Fusion Pixel，是因为**后者才是真像素字**（纯矩形轮廓、
  em/12 网格；PingFang 的 `glyf` 是贝塞尔 + 内嵌点阵位图，游戏不读位图表，所以渲染出来是矢量字）。
  2026-10-26 又换回来，原因是**字库覆盖**优先于"像素感"：Fusion Pixel 缺 1675 个 CJK 码位，
  游戏数据里的生僻字（人名 / 物品 / 地名）会显示成 □。现在的折中是：矢量字 + `OUTLINE, MONOCHROME`
  （1px 描边 + 关抗锯齿），12px 下边缘仍然是硬的。

## 参考

- SIL OFL 1.1 全文：https://openfontlicense.org/
- CC BY-SA 3.0 全文：https://creativecommons.org/licenses/by-sa/3.0/legalcode
