# MonetUI

> 为**魔兽世界无限（WoW Forever）**打造的一套**莫奈印象派风格**整合 UI —— 界面配色按**区域离线采样的环境色**查表，再由莫奈规则**实时派生**四档主题色，随区域切换平滑变化。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#-协议)
![Interface](https://img.shields.io/badge/Interface-16001-orange.svg)
![Version](https://img.shields.io/badge/version-0.12.0-informational.svg)
![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72.svg)
![Status](https://img.shields.io/badge/status-1.60_实机已验-brightgreen.svg)

配色的两半各管一段：**环境色离线采样**（游戏截图按区域提取，存成一张 `mapID → 环境 HSL` 的表），**主题色运行期实时派生**（拿你所在的地图 ID 查表 → 莫奈规则算出边缘 / 环境 / 高亮 / 中性四档 → 亮度阶梯定位 → 广播重涂）。运行期**不读任何贴图像素**（这个客户端也没有可用的像素读取 API），所以换区域时既不用等截图分析、也不会卡一下。查不到的区域沿 `C_Map` 的父链继承上一层（大陆 / 世界）的派生色，父链也断时退回中性灰兜底 —— 配置面板的「区域配色」一行会写明当前用的是哪一档。

---

## ✨ 特性

- **区域驱动配色** —— 接入 [`LibMonetColor-1.0`](#-依赖) 后，颜色 = 当前地图 ID 查**离线采样的区域环境色** → 莫奈规则**运行期实时派生**四档 → 亮度阶梯定位。未覆盖的区域沿 `C_Map` 父链继承大陆 / 世界层的派生色，父链也断时退回中性灰兜底（面板「区域配色」一行会写明是哪一档）；库缺失时优雅降级为内置默认配色。
- **模块松耦合** —— 模块之间只通过 `Utils/EventBus.lua` 通信，互不直接依赖；每个模块都能单独开关，关掉即**完整回退**到暴雪原样。
- **自绘材质** —— 35 张自绘 UI 贴图（关闭钮三态 / 勾选框 / 状态条 / 图标 / 角饰 / 织纹 / 三角火花），结构性的走脚本（`tools/regen-textures.js`）、可改的走 SVG（`tools/svg/*.svg`）、笔触走 GIMP，不引外部贴图。
- **无限客户端优先** —— 单位数值一律过保密值查询（`Utils/Secrets.lua`）；`Interface 16001`，Lua 5.1，不使用 5.2+ 特性。
- **永不抛错** —— 访问暴雪帧一律存在性 / `pcall` 防护；失败一次性告警，不刷屏。

## 🧩 模块

| 模块 | 说明 |
|------|------|
| **UnitFrames** | 玩家 / 目标 / 焦点 / 宠物单位框架：血条、能量、名字、等级、提示，连击点小格；可拖动并保存位置。 |
| **GroupFrames** | 小队（自己 + 1–4）/ 团队（8 组 × 5 人）框架：暴雪安全头 + Monet 皮肤，职业色血条、能量、名字、职责图标、距离淡出、当前目标高亮边框、点击选中 / 右键菜单；可拖动并保存位置，默认接管暴雪自带的小队 / 团队框。 |
| **Cooldown** | 冷却数字 / 充能 / 快捷键字体美化，技能可用状态着色。 |
| **BuffFrame** | 自绘增益 / 减益网格，按时长排序。 |
| **Minimap** | 小地图矩形化（256×190），去掉坐标与时钟，配主题面板。 |
| **Bags** | 分类背包（含账号银行页切片）：全自绘，接管暴雪背包框（开背包时把我们的窗口顶上来），支持搜索 / 分类 / 整理。 |
| **QuestTracker** | 任务追踪主题边框 + 标题栏拖动 + 位置保存。 |
| **ActionBars** | 1–8 号自绘动作条（**不依赖任何动作条库**：按钮用客户端的 `SecureActionButtonTemplate` + `actionpage` 属性自绘，施法 / 翻页 / 载具条全部由客户端判定），接管宠物 / 姿态条，隐藏暴雪动作条与背包条。宠物条的「自动施法」提示用自绘的像素环替掉暴雪那圈旋转的蚂蚁。 |
| **Nameplates** | 挂在暴雪姓名板底座上的细条姓名板：血条 / 名字等级 / 百分比 / 施法条 / 仇恨描边。**当前目标＝金色描边 + 放大 1.1 倍**（固定信号，不随主题变；仇恨色优先级更高）；**不显示增益 / 减益**（2026-10-26 起，光环交回玩家单位框与暴雪原生）。 |
| **InfoBar** | 贴屏幕边缘的整幅细条 + 6 个数据块（金钱 / 耐久 / 货币 / 延迟帧率内存 / 专精 / 好友），悬停淡入、战斗呼吸、宠物对战自动隐藏；底边衬线就是经验条（进度＝线的长度，进度头一枚 ▲，涨经验时三角滑过去并白热、升级时闪两下，悬停三角才弹具体数值），满级后同一条线改显示当前监视的声望、颜色随关系走。 |
| **Skins** | 暴雪窗口美化：任务、世界地图、角色、收藏、社交、交易（邮件 / 商贩 / 拍卖 / 专业）、系统、Forever，统一铺 Monet 底板 / 边框 / 字体；可逐窗口开关。 |
| **Tooltip** | 鼠标提示：**摆法三选一** —— 跟随鼠标（贴屏幕右/上边缘自动翻边）／**右下角对齐小地图面板右上角**／暴雪默认位置；单位提示补一行「目标: 谁」；按住 **Alt** 显示 ID（NPC / 物品 / 法术）。外观（边框 / 底色 / 字体）在 Skins 的「鼠标提示边框」里，默认开。 |
| **Cursor** | 光标拖尾（快速移动时跟出一条主题色笔迹，停下自己淡没）+ 速度星芒（快速甩动时出现十字光）。全部用 `Line` 自绘，不引任何贴图，两个效果各自可关。 |
| **Toast** | 通知横幅：屏幕顶部一条主题化提示，一次一条、排队播完，底边细线随停留时间排空。只接两件本项目真的缺的事——新邮件（小地图邮件图标默认隐藏）和背包满。 |
| **Durability** | 装备耐久警告：最低的那件跌破阈值时用横幅提醒一次，修好或换装回到阈值以上才重新武装。 |
| **CombatText** | 战斗辅助：默认用**暴雪自己的**浮动战斗文字（机密值原因，我们的数字拿不到明文，自己的三类降为可选、默认关）；进出战斗有醒目提示（自绘剑 + 盾 + 大字，参考 Andromeda）；战斗数字显示区域可偏移五档（只写暴雪的纯几何表，遇机密值整段放弃）。 |

## 📦 安装

1. 把整个 `MonetUI` 文件夹放进客户端的 `Interface/AddOns/` 下。
2. **完整重启客户端** —— 新增文件不会被热加载。
3. 游戏内输入 `/mui` 看用法，`/mui status` 看模块与主题状态。

配置面板在暴雪界面设置里（`Esc → 界面`），设置存于 `MonetUIDB`。

## 🔗 依赖

- **硬依赖：无** —— `LibStub` 已内嵌在 `Libs/` 下，不需要额外安装任何库。
- **随包**：`LibMonetColor-1.0`（配色引擎）、`LibMonetColor-Anim-1.0`（状态染色层）、`MonetColorMapData-1.0`（14 个区域的实测环境色，自家仓库 [monetcolors](https://github.com/easthillgu/monetcolors) 的生成产物，**不要手改**）。
- **随包的派生数据**：`MonetColorMapEnvOverride.lua`（本仓算出的 3 条大陆 / 世界层父链色，运行时走引擎的 `RegisterMapEnv` override 通道注册）—— 数值由该层成员区的实测色取**圆均值**派生，不是新采的样，所以**不写回生成文件**；`RegisterMapEnv` 自带 `ClearCache + Refresh`，而本文件在 `Libs` 组、`Core.lua` 之前加载 —— 那一刻还没有人订阅引擎回调，所以这几次刷新只重算缓存，不会播一次多余的重涂。
- **动作条不依赖任何动作条库**：按钮用客户端自己的 `SecureActionButtonTemplate` + `actionpage` 属性自绘，施法、翻页、载具 / 变形 / 覆盖条全部由客户端判定。

> ⚠️ **不要**同时启用独立的 `LibMonetColor-1.0` 插件。同 `MAJOR` 由 `LibStub` 按 `MINOR` 仲裁（`Libs/LibStub/LibStub.lua:15-18`：先注册且 `MINOR` 不低于对方的一份拿到库表），落选的那份在 `LibMonetColor-1.0.lua:29-33` 的 `if not LMC then return end` 处**静默退出** —— 不报错、不崩，但两份的区域色数据不同步时，真正生效的是哪一份取决于加载顺序。本体已内嵌该引擎，重复启用只会让其中一份白加载。

## ⌨️ 命令

| 命令 | 作用 |
|------|------|
| `/mui status` | 显示模块与主题状态 |
| `/mui theme` | 按当前区域重查环境色、重新派生四档并广播重涂（不做任何像素取样） |
| `/mui <模块> on\|off` | 单独开关模块（模块名见上表，小写） |
| `/mui skins diagnose` | 探测本客户端缺失的对象名（`nameplates` / `infobar` 同样支持） |
| `/mui infobar diagnose` | 信息栏自检 |
| `/mui reset` | 恢复默认设置（需 `/reload`） |
| `/mui enable` / `disable` | 启用 / 禁用本体（禁用需 `/reload`） |

`/monetui` 亦可。

## 🗂️ 目录结构

```
MonetUI/
├── MonetUI.toc          入口清单：只列各组 xml + 单文件模块（顺序即加载顺序）
├── Core.lua             SavedVariables / 模块注册与生命周期 / 主题管线 / 斜杠命令
├── LICENSE / THIRD-PARTY-NOTICES.txt   自身 MIT + 随包第三方与字体的许可清单
├── Libs/                随包库 + NOTICE.md（第三方许可清单）+ Libs.xml
├── Utils/               基础工具（Math Secrets Media EventBus Color Widget Layout Mover Skin）+ Utils.xml
├── Config/              设置面板（SimpleConfig）+ Config.xml
├── Modules/             各功能模块（见上表），每个模块一份同名 xml 清单
├── Assets/              字体 / 自绘材质 / 图标
├── docs/                开发记录、布局与材质预览页
└── tools/               材质/遮罩生成脚本 + API 审核（`api-audit.js`）
```

**一个子模块 = 一份 xml 清单**：`MonetUI.toc` 不再逐个列 `.lua`，而是列
`Libs/Libs.xml`、`Utils/Utils.xml`、`Config/Config.xml` 和 `Modules/<模块>/<模块>.xml`；
组内加载顺序写在 xml 的 `<Script file>` 里，组间顺序就是 toc 里的排列。单文件模块（`Tooltip`
`Cursor` `Toast` `Durability` `CombatText`）直接在 toc 里列 `.lua`。要加减文件就改对应 xml ——
顺序和"这一组是干什么的、为什么是这个先后"都写在各 xml 头部的注释里。

> 仓库只跟踪**发行集**（`.toc` / 各 xml 列出的文件 + `Assets/` + `Libs/`）。`tools/`、`docs/`、`AGENTS.md` 等开发资料按 `.gitignore` 不入库 —— 克隆下来是可直接用的插件，不是完整开发环境。静态审核与材质生成器的用法写在各脚本头部注释里。

## ⚠️ 状态

**2026-11-05（《无限》1.60 开服日）已在交付客户端上实机复验：`1.60.1 · build 70790 · Interface 16001 · zhCN`。**
更早的 12.1.5 验收记录现在只是历史证据；下面写的都是 1.60 实测。

- 登录：`已加载 20/20 个模块`、`界面美化已启用（46 个窗口）`、`/mui report` 四段（环境 / 角色 / 位置 / 受限）都对。
- 只读诊断全跑过：`/mui compat`（58 项，与假设不符 6 项已逐条处置）、`/mui skins diagnose`
  （**277 存在 / 64 缺失**，缺的不全是缺陷：GameRule 关掉的面板、别的客户端的名字、以及窗口还没开）、
  `/mui restrict`、`/mui blocks`、`/mui perf`。
- 功能项：背包分类窗 + 品质边框 + 等级数字 + **空格可掉落**（拖放实测）；银行与背包**同屏并存不重叠**；
  人物页签 / 好友 / 社交窗 / 任务详情 / 技能书 / 传承三页按 1.60 实名涂到位。
- 干净基线（关掉同机 QoL 套件 + 重载，且**在战斗中**）：`ERR / BLOCKED` 零条，`/mui blocks` 账本空。

**v0.12.0 已知限制（都是取舍，不是坏掉的功能）**：

- **点信息栏 / 微菜单不能打开暴雪面板**。1.60 上唯一合法的两条路我们都试过：调暴雪 Lua 全局会把整段面板链
  记到插件名下（一屏红字），用安全模板转发会把我们逐拍排版的框标成受保护（菜单展不开）。
  微菜单因此只保留三行：背包（我们自己的窗）/ 地图（`C_Map.OpenWorldMap`）/ 设置（`Settings.OpenToCategory`）。
- **银行默认接管暴雪银行框**（只留我们的窗，2026-11-06 起）。我们的银行空格自 11-06 起是**真容器槽**
  （拖放三向已实测：背↔银、背内互拖）。要买栏位 / 换银行包这类必须回到暴雪那块面做的事，
  用 `/mui bags bank off`（或面板里的「放开暴雪」钮）；想让两套并存就 `/mui bags hidebliz off`。
- 同机插件会抢东西：`RurutiaSuite` 的"小地图按钮收纳"会把我们的命中层搬走（本版已改成挂自己的容器），
  `DungeonsForeverSpell` 一类会让暴雪动作条报 `SetCooldown`。这类拦截**可能记到 MonetUI 名下**，
  出问题请先跑 `/mui report`，并在关掉其它插件后复现一次。
- `/mui perf` 的逐路耗时在这一版恒为 0（`GetTime` 粒度不够，客户端另有高精度计时器，待接入）。

- 逐项进度、验收清单与客户端约定记在**本地**开发文档（`AGENTS.md`、`MonetUI.md`、`TODO.md`、`docs/`，按 `.gitignore` 不入库）。

## 📄 协议

- **MonetUI 自身代码**：[MIT](LICENSE)。
- **随包第三方组件**保留各自许可：`LibStub`（公有领域）。逐条清单见 [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt)（发行时随包分发），细节见 [`Libs/NOTICE.md`](Libs/NOTICE.md) 与 [`Assets/Fonts/NOTICE.md`](Assets/Fonts/NOTICE.md)。
- **随包字体**各自授权（随包只有三份，`Assets/Fonts/` 实测）：正文小字轨 `Pingfangpixel.ttf`
  （点阵苹方，**作者 2026-11-01 已授权我们再分发 ⇒ 公开 Release 不需要替换**，条款见
  `Assets/Fonts/NOTICE.md`）、正文大字 `LXGWWenKai-Regular.ttf`（SIL OFL 1.1，随包附全文）、
  倒计时数字 `super-effective.ttf`（CC BY-SA 3.0，需署名）。像素轨替代候选（Fusion / Ark Pixel）
  与朱雀仿宋放在 `Assets-src/Fonts/`，**不进包**；`roadway.ttf` 无授权声明、代码不引用、不分发。

---

> 魔兽世界无限（WoW Forever） / Interface 16001 / Lua 5.1
