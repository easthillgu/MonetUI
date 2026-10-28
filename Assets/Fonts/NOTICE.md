# 字体来源与授权

`Assets/Fonts/` 里每个字体文件的出处与授权，取自文件内嵌的 `name` 表（copyright / license / vendor 字段），逐条对照过，不凭印象。**新增字体必须在这里补一行**，否则一律视为不得分发。

| 文件 | 字体 | 版权 / 作者 | 授权 | 用在何处 |
|---|---|---|---|---|
| `LXGWWenKai-Regular.ttf` | LXGW WenKai（霞鹜文楷）v1.530 | © 2021-2026 LXGW（https://github.com/lxgw/LxgwWenKai） | **SIL OFL 1.1**，全文见 `OFL-LXGWWenKai.txt` | **主字体 `M.font.pixel` / `M.font.wenkai` / `M.font.pingfang`**（2026-10-28 起）。CJK 覆盖远超游戏数据所需；OFL 允许随插件分发 |
| `fusion-pixel-12.ttf` | Fusion Pixel 12px Prop zh-Hans | © 2022 TakWolf（https://fusion-pixel-font.takwolf.com） | **SIL OFL 1.1**，全文见 `OFL-FusionPixel.txt` | 备用（保留在仓里，未接线） |
| `super-effective.ttf` | Super Effective v1.0 | © The Ender 2012（FontStruct） | **CC BY-SA 3.0**（http://creativecommons.org/licenses/by-sa/3.0/）—— 使用需署名，字体文件本身须以同协议分发 | 冷却数字 `M.font.cooldown` |
| ~~`Pingfangpixel.ttf`~~ | 点阵苹方 | © 2015 DynaComware；PingFang 为 Apple Inc. 商标 | **无授权声明**（文件内无 license 字段） | **已移除**（2026-10-28）：无授权字体不得随发行包分发，由霞鹜文楷接替 |
| `roadway.ttf` | Roadway | © 2005 Keith Bates / K-Type Freebie | **无授权声明**（文件内无 license 字段；K-Type Freebie 的条款以官网当时说明为准） | 未使用 |

## 结论与待办

- **在用**的是 `LXGWWenKai-Regular.ttf`（正文 + 数字）与 `super-effective.ttf`（倒计时数字）。
  **2026-10-28 起授权阻塞项解除**：主字体换成 OFL 的霞鹜文楷，无授权的点阵苹方已从仓里删除
  （git 历史可回溯）。换字只动了 `Utils/Media.lua` 的 `Media.font` 一项，调用点未碰。
- 渲染口径不变：矢量字 + `OUTLINE, MONOCHROME`（1px 描边 + 关抗锯齿），12px 下边缘是硬的。
  楷体字形与点阵苹方观感不同（笔画有粗细变化），实机验收看小字号（8–14px 光环时长/层数）
  是否还清晰。

## 参考

- SIL OFL 1.1 全文：https://openfontlicense.org/
- CC BY-SA 3.0 全文：https://creativecommons.org/licenses/by-sa/3.0/legalcode
