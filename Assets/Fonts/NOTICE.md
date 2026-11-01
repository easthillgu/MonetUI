# 字体来源与授权

`Assets/Fonts/` 里每个字体文件的出处与授权，取自文件内嵌的 `name` 表（copyright / license / vendor 字段），逐条对照过，不凭印象。**新增字体必须在这里补一行**，否则一律视为不得分发。

**两个目录分工**（2026-11-01 定）：`Assets/Fonts/` = **随包分发**（`tools/deploy-retail.ps1` 用
`robocopy /MIR` 镜像整个 `Assets/`，所以放进这里就会进玩家手上的包）；`Assets-src/Fonts/` =
候选 / 未接线的字体，**进 git 但不进包**。判断标准只有一条：`Media.font` 里有键指向它，才留在
`Assets/Fonts/`。

| 文件 | 字体 | 版权 / 作者 | 授权 | 用在何处 |
|---|---|---|---|---|
| `LXGWWenKai-Regular.ttf` | LXGW WenKai（霞鹜文楷）v1.530 | © 2021-2026 LXGW（https://github.com/lxgw/LxgwWenKai） | **SIL OFL 1.1**，全文见 `OFL-LXGWWenKai.txt` | **`M.font.wenkai`**（2026-11-01 起：键与字体一一对应，`pixel` 已改指点阵苹方，`pingfang` 键删除）。当前无调用点，但旧存档值会走它，所以保留。CJK 覆盖远超游戏数据所需；OFL 允许随插件分发 |
| `Pingfangpixel.ttf` | 点阵苹方 | © 2015 DynaComware；PingFang 为 Apple Inc. 商标 | **无授权声明**（文件内无 license 字段） | **`M.font.pixel`（正文默认）+ 小字轨**（<12px 一律走它）。2026-11-01 起 `pixel` 键改指本文件（原先名不副实指向文楷），任务追踪 / Toast / 战斗文字 / 信息栏 / 单位框正文 / 名牌小字 / 光环时长都走它。**无授权字体不得随公开发行包分发，转公开前必须处理** |
| `super-effective.ttf` | Super Effective v1.0 | © The Ender 2012（FontStruct） | **CC BY-SA 3.0**（http://creativecommons.org/licenses/by-sa/3.0/）—— 使用需署名，字体文件本身须以同协议分发 | 倒计时数字 `M.font.cooldown`（任何字号都用它自己） |

### 已移出分发目录（在 `Assets-src/Fonts/`，进 git 不进包）

| 文件 | 字体 | 版权 / 作者 | 授权 | 为什么留仓 |
|---|---|---|---|---|
| `fusion-pixel-12.ttf` | Fusion Pixel 12px Prop zh-Hans（release 2026.10.25，2026-11-01 更新） | © 2022 TakWolf（https://fusion-pixel-font.takwolf.com） | **SIL OFL 1.1**，全文见 `OFL-FusionPixel.txt` | **点阵苹方的 OFL 替代候选**，见下面「授权状态」待办 |
| `ark-pixel-12.ttf` | Ark Pixel 12px Prop zh-Hans（release 2026.10.25，2026-11-01 新增） | © 2021 TakWolf（https://github.com/TakWolf/ark-pixel-font） | 声称 **SIL OFL 1.1**，但 ⚠️ **随仓的 `OFL-ArkPixel.txt` 是 Fusion 那份的复制**（头部写 "Fusion Pixel Font"、年份 2022），**不能当作用户方授权依据**，接线前要先换成 ark 仓库的原文 | 同上（像素轨替代候选） |
| `zhuque-fangsong.ttf` | 朱雀仿宋 Zhuque Fangsong v0.212（technical preview） | © 2023 浙江璇玑信息科技 / JadeFoci（https://github.com/TrionesType/zhuque） | **SIL OFL 1.1**（内嵌 name 表实测 + 仓库 LICENSE.txt，见 `OFL-ZhuqueFangsong.txt`） | 开源仿宋候选（面板标题 / 日志文体）；笔画细，小字号需实机验 |
| `roadway.ttf` | Roadway | © 2005 Keith Bates / K-Type Freebie | **无授权声明**（文件内无 license 字段；K-Type Freebie 的条款以官网当时说明为准） | 未使用（57 KB，`MonetUI.md` 记为"遗留保留，回滚用"；旧存档值 `roadway` 经 `GetFontKey` 归一到 `pixel`，不需要文件本体） |

## 结论与待办

- **键与字体一一对应**（2026-11-01 定，玩家要求"要指向清晰"）：`pixel` = 点阵苹方（正文默认）、
  `wenkai` = 霞鹜文楷、`cooldown` = Super Effective。已删的键：`pingfang`（与 `pixel` 重复）、
  `supereff`（与 `cooldown` 同文件，当初为省事写的缩写）、`thin`（nfdcsCN16，实机效果不好且
  需要额外维护 10px 下限与 FontFor 特例，字体文件已删除）。
- **换挡规则**（漏斗 `Media:FontFor` / `Media:FlagsFor` / `Media:EffectiveFlags`）：
  `cooldown` 任何字号都用它自己；其它键 **<12px** 一律落到 `Pingfangpixel.ttf`
  （硬边 `OUTLINE, MONOCHROME`——文楷小字号 + AA 实机发虚），**≥12px** 才按key解析。
  所以"双轨"现在只对 `wenkai` 有意义；正文走 `pixel`，12px 上下都是点阵苹方。
- **授权状态（风险已升级，读这条要留意）**：点阵苹方**从"只作小字轨"变成了正文默认字体**
  （任务追踪 / Toast / 战斗文字 / 信息栏 / 单位框正文 / 名牌小字 / 光环时长都走它），
  而它**至今无授权声明**。私有包可用，但**转公开 / 发 Release 前必须替换**，
  候选是 `Assets-src/Fonts/` 里的两个 OFL 像素字（`ark-pixel-12` / `fusion-pixel-12`）；
  替换成本比只做小字轨时高得多——正文里有大量中文，需先确认 CJK 覆盖率，
  否则生僻字会掉 □。
- 渲染口径：`pixel` / 小字轨 = `OUTLINE, MONOCHROME`（硬边）；`wenkai` ≥12px = `OUTLINE`
  （抗锯齿）。实机验收：12px 以上看文楷 AA 是否舒展，12px 以下看点阵是否清晰。

## 参考

- SIL OFL 1.1 全文：https://openfontlicense.org/
- CC BY-SA 3.0 全文：https://creativecommons.org/licenses/by-sa/3.0/legalcode
