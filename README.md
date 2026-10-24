# MonetUI

> 为**魔兽世界无限（WoW Forever）**打造的一套**莫奈印象派风格**整合 UI —— 界面配色由**当前区域的环境色**实时推导，随区域切换平滑变化。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#-协议)
![Interface](https://img.shields.io/badge/Interface-16001-orange.svg)
![Version](https://img.shields.io/badge/version-0.11.0-informational.svg)
![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72.svg)
![Status](https://img.shields.io/badge/status-待实机验证-yellow.svg)

它不是一个静态配色表，而是随着「你所在的地图」实时推导界面颜色：环境互补色 + 明度曲线钳制 + 色相域细分，输出一组协调、耐看的 Monet 主题色。

---

## ✨ 特性

- **环境驱动配色** —— 接入 [`LibMonetColor-1.0`](#-依赖) 后颜色由当前区域环境色实时推导，而非静态色表；库缺失时优雅降级为内置默认配色。
- **模块松耦合** —— 模块之间只通过 `Utils/EventBus.lua` 通信，互不直接依赖；每个模块都能单独开关，关掉即**完整回退**到暴雪原样。
- **自绘材质** —— 33 张自绘 UI 贴图（关闭钮三态 / 勾选框 / 状态条 / 图标 / 角饰 / 织纹），结构性的走脚本（`tools/regen-textures.js`）、可改的走 SVG（`tools/svg/*.svg`）、笔触走 GIMP，不引外部贴图。
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
| **Bags** | 分类背包（含账号银行页切片）。旧排列式 `BagFrame` 保留，待其实机验证通过后退役。 |
| **QuestTracker** | 任务追踪主题边框 + 标题栏拖动 + 位置保存。 |
| **ActionBars** | 1–8 号自绘动作条（**不依赖任何动作条库**：按钮用客户端的 `SecureActionButtonTemplate` + `actionpage` 属性自绘，施法 / 翻页 / 载具条全部由客户端判定），接管宠物 / 姿态条，隐藏暴雪动作条与背包条。宠物条的「自动施法」提示用自绘的像素环替掉暴雪那圈旋转的蚂蚁。 |
| **Nameplates** | 挂在暴雪姓名板底座上的细条姓名板：血条 / 名字等级 / 百分比 / 施法条 / 借用暴雪减益 / 仇恨与目标描边。 |
| **InfoBar** | 贴屏幕边缘的整幅细条 + 6 个数据块（金钱 / 耐久 / 货币 / 延迟帧率内存 / 专精 / 好友），悬停淡入、战斗呼吸、宠物对战自动隐藏；底边衬线就是经验条（进度＝线的长度，进度头一枚 ▲，涨经验时三角滑过去并白热、升级时闪两下，悬停三角才弹具体数值），满级后同一条线改显示当前监视的声望、颜色随关系走。 |
| **Skins** | 暴雪窗口美化：任务、世界地图、角色、收藏、社交、交易（邮件 / 商贩 / 拍卖 / 专业）、系统、Forever，统一铺 Monet 底板 / 边框 / 字体；可逐窗口开关。 |
| **Tooltip** | 鼠标提示位置：一个开关让所有提示框（物品 / 技能 / 角色 / 光环 / 动作条…）跟着鼠标走，关掉则停在暴雪默认的右下角锚点。外观（边框 / 底色 / 字体）在 Skins 的「鼠标提示边框」里，默认开。 |
| **Cursor** | 光标拖尾（快速移动时跟出一条主题色笔迹，停下自己淡没）+ 速度星芒（快速甩动时出现十字光）。全部用 `Line` 自绘，不引任何贴图，两个效果各自可关。 |
| **Toast** | 通知横幅：屏幕顶部一条主题化提示，一次一条、排队播完，底边细线随停留时间排空。只接两件本项目真的缺的事——新邮件（小地图邮件图标默认隐藏）和背包满。 |

## 📦 安装

1. 把整个 `MonetUI` 文件夹放进客户端的 `Interface/AddOns/` 下。
2. **完整重启客户端** —— 新增文件不会被热加载。
3. 游戏内输入 `/mui` 看用法，`/mui status` 看模块与主题状态。

配置面板在暴雪界面设置里（`Esc → 界面`），设置存于 `MonetUIDB`。

## 🔗 依赖

- **硬依赖：无** —— `LibStub` 已内嵌在 `Libs/` 下，不需要额外安装任何库。
- **随包**：`LibMonetColor-1.0`、`MonetColorMapData-1.0`（自家仓库 [monetcolors](https://github.com/easthillgu/monetcolors) 的产物）。
- **动作条不依赖任何动作条库**：按钮用客户端自己的 `SecureActionButtonTemplate` + `actionpage` 属性自绘，施法、翻页、载具 / 变形 / 覆盖条全部由客户端判定。

> ⚠️ **不要**同时启用独立的 `LibMonetColor-1.0` 插件 —— MonetUI 已内嵌同一版本，同 `MAJOR` 二次注册会直接退出。

## ⌨️ 命令

| 命令 | 作用 |
|------|------|
| `/mui status` | 显示模块与主题状态 |
| `/mui theme` | 重新采样环境色彩 |
| `/mui <模块> on\|off` | 单独开关模块（模块名见上表，小写） |
| `/mui skins diagnose` | 探测本客户端缺失的对象名（`nameplates` / `infobar` 同样支持） |
| `/mui infobar diagnose` | 信息栏自检 |
| `/mui reset` | 恢复默认设置（需 `/reload`） |
| `/mui enable` / `disable` | 启用 / 禁用本体（禁用需 `/reload`） |

`/monetui` 亦可。

## 🗂️ 目录结构

```
MonetUI/
├── MonetUI.toc          入口清单
├── Core.lua             SavedVariables / 模块注册与生命周期 / 主题管线 / 斜杠命令
├── Utils/               Math Secrets Media EventBus Color Widget Mover Skin
├── Config/              SimpleConfig 配置面板
├── Modules/             各功能模块（见上表）
├── Libs/                随包库 + NOTICE.md（第三方许可清单）
├── Assets/              字体 / 自绘材质 / 图标
├── docs/                开发记录、布局与材质预览页
└── tools/               材质/遮罩生成脚本 + API 审核（`api-audit.js`）
```

> 仓库只跟踪**发行集**（`.toc` 列出的文件 + `Assets/` + `Libs/`）。`tools/`、`docs/`、`AGENTS.md` 等开发资料按 `.gitignore` 不入库 —— 克隆下来是可直接用的插件，不是完整开发环境。静态审核与材质生成器的用法写在各脚本头部注释里。

## ⚠️ 状态

**离线验证通过，待实机验收。**

- `wuxian check`（离线）全绿：**0 error / 0 warning**。
- 静态 API 审核 `tools/api-audit.js`：**0 hard**，8 条 soft 均为 `InCombatLockdown`（文档已改为 `C_RestrictedActions.InCombatLockdown`）。
- 待验收：自绘材质接线、信息栏、`load` / `try` 热加载、小队 / 团队框架战斗内刷新。
- 逐项进度、验收清单与客户端约定记在**本地**开发文档（`AGENTS.md`、`MonetUI.md`、`TODO.md`，按 `.gitignore` 不入库）。

## 📄 协议

- **MonetUI 自身代码**：[MIT](LICENSE)。
- **随包第三方组件**保留各自许可：`LibStub`（公有领域）。完整清单见 [`Libs/NOTICE.md`](Libs/NOTICE.md)。
- **随包字体**各自授权：FusionPixel 为 SIL OFL 1.1（全文 `Assets/Fonts/OFL-FusionPixel.txt`）、Super Effective 为 CC BY-SA 3.0；逐条来源见 [`Assets/Fonts/NOTICE.md`](Assets/Fonts/NOTICE.md)。

---

> 魔兽世界无限（WoW Forever） / Interface 16001 / Lua 5.1
