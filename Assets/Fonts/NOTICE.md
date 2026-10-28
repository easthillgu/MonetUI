# 字体来源与授权

`Assets/Fonts/` 里每个字体文件的出处与授权，取自文件内嵌的 `name` 表（copyright / license / vendor 字段），逐条对照过，不凭印象。**新增字体必须在这里补一行**，否则一律视为不得分发。

| 文件 | 字体 | 版权 / 作者 | 授权 | 用在何处 |
|---|---|---|---|---|
| `LXGWWenKai-Regular.ttf` | LXGW WenKai（霞鹜文楷）v1.530 | © 2021-2026 LXGW（https://github.com/lxgw/LxgwWenKai） | **SIL OFL 1.1**，全文见 `OFL-LXGWWenKai.txt` | **主字体 `M.font.pixel` / `M.font.wenkai` / `M.font.pingfang`**（2026-10-28 起）。CJK 覆盖远超游戏数据所需；OFL 允许随插件分发 |
| `fusion-pixel-12.ttf` | Fusion Pixel 12px Prop zh-Hans | © 2022 TakWolf（https://fusion-pixel-font.takwolf.com） | **SIL OFL 1.1**，全文见 `OFL-FusionPixel.txt` | 备用（保留在仓里，未接线） |
| `super-effective.ttf` | Super Effective v1.0 | © The Ender 2012（FontStruct） | **CC BY-SA 3.0**（http://creativecommons.org/licenses/by-sa/3.0/）—— 使用需署名，字体文件本身须以同协议分发 | 冷却数字 `M.font.cooldown` |
| `Pingfangpixel.ttf` | 点阵苹方 | © 2015 DynaComware；PingFang 为 Apple Inc. 商标 | **无授权声明**（文件内无 license 字段） | **小字轨**（2026-10-28 起，<12px：光环时长/层数/名牌小字——楷体小字号 + 抗锯齿实机发虚，点阵苹方硬边正对口；大字轨是霞鹜文楷）。**无授权字体不得随公开发行包分发，转公开前必须处理** |
| `roadway.ttf` | Roadway | © 2005 Keith Bates / K-Type Freebie | **无授权声明**（文件内无 license 字段；K-Type Freebie 的条款以官网当时说明为准） | 未使用 |

## 结论与待办

- **在用**的是双轨制（2026-10-28 定，按字号换挡，漏斗 `Media:FontFor` / `Media:FlagsFor` /
  `Media:EffectiveFlags`）：**≥12px** `LXGWWenKai-Regular.ttf`（霞鹜文楷，OFL，抗锯齿）；
  **<12px** `Pingfangpixel.ttf`（点阵苹方，硬边 `OUTLINE, MONOCHROME`——楷体小字号 + AA
  实机发虚）；倒计时数字 `super-effective.ttf`。
- **授权状态**：大字轨干净（OFL）；**小字轨的点阵苹方仍无授权**，私有包可用，
  **转公开 / 发 Release 前必须处理**（候选：方舟像素 Ark Pixel 12px 一类 OFL 像素字，
  或接受小字改用 fusion-pixel-12 并承担生僻字掉 □ 的代价——小字号用不到生僻字的话后者可行）。
- 渲染口径（2026-10-28 起）：大字轨文楷 + `OUTLINE`（抗锯齿）；小字轨点阵苹方 +
  `OUTLINE, MONOCHROME`（硬边）。实机验收：12px 以上看楷体 AA 是否舒展，12px 以下看
  点阵苹方硬边是否清晰（光环时长/层数/名牌小字）。

## 参考

- SIL OFL 1.1 全文：https://openfontlicense.org/
- CC BY-SA 3.0 全文：https://creativecommons.org/licenses/by-sa/3.0/legalcode
