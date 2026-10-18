# MonetUI

> 为**魔兽世界无限（WoW Forever）**打造的一套**莫奈印象派风格**整合 UI —— 界面配色由**当前区域的环境色**实时推导，随区域切换平滑变化。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#-协议)
![Interface](https://img.shields.io/badge/Interface-16001-orange.svg)
![Version](https://img.shields.io/badge/version-0.10.0-informational.svg)
![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72.svg)
![Status](https://img.shields.io/badge/status-待实机验证-yellow.svg)

它不是一个静态配色表，而是随着「你所在的地图」实时推导界面颜色：环境互补色 + 明度曲线钳制 + 色相域细分，输出一组协调、耐看的 Monet 主题色。

---

## ✨ 特性

- **环境驱动配色** —— 接入 [`LibMonetColor-1.0`](#-依赖) 后颜色由当前区域环境色实时推导，而非静态色表；库缺失时优雅降级为内置默认配色。
- **模块松耦合** —— 模块之间只通过 `Utils/EventBus.lua` 通信，互不直接依赖；每个模块都能单独开关，关掉即**完整回退**到暴雪原样。
- **自绘材质** —— 21 组矢量 UI 材质（关闭钮三态 / 勾选框 / 状态条 / 图标 / 角饰）由 `tools/make-ui-textures.ps1` 生成，不引外部贴图。
- **无限客户端优先** —— 单位数值一律过保密值查询（`Utils/Secrets.lua`）；`Interface 16001`，Lua 5.1，不使用 5.2+ 特性。
- **永不抛错** —— 访问暴雪帧一律存在性 / `pcall` 防护；失败一次性告警，不刷屏。

## 🧩 模块

| 模块 | 说明 |
|------|------|
| **UnitFrames** | 玩家 / 目标 / 焦点 / 宠物单位框架：血条、能量、名字、等级、提示，连击点小格；可拖动并保存位置。 |
| **Cooldown** | 冷却数字 / 充能 / 快捷键字体美化，技能可用状态着色。 |
| **BuffFrame** | 自绘增益 / 减益网格，按时长排序。 |
| **Minimap** | 小地图矩形化（256×190），去掉坐标与时钟，配主题面板。 |
| **Bags** | 分类背包（含账号银行页切片）。旧排列式 `BagFrame` 保留，待其实机验证通过后退役。 |
| **QuestTracker** | 任务追踪主题边框 + 标题栏拖动 + 位置保存。 |
| **ActionBars** | 1–8 号自绘动作条（基于 `LibActionButton-1.0`），接管宠物 / 姿态条，隐藏暴雪动作条与背包条。 |
| **Nameplates** | 挂在暴雪姓名板底座上的细条姓名板：血条 / 名字等级 / 百分比 / 施法条 / 借用暴雪减益 / 仇恨与目标描边。 |
| **InfoBar** | 贴屏幕边缘的整幅细条 + 6 个数据块（金钱 / 耐久 / 货币 / 延迟帧率内存 / 专精 / 好友），悬停淡入、战斗呼吸、宠物对战自动隐藏。 |
| **Skins** | 暴雪窗口美化：任务、世界地图、角色、收藏、社交、交易（邮件 / 商贩 / 拍卖 / 专业）、系统、Forever，统一铺 Monet 底板 / 边框 / 字体；可逐窗口开关。 |

## 📦 安装

1. 把整个 `MonetUI` 文件夹放进客户端的 `Interface/AddOns/` 下。
2. **完整重启客户端** —— 新增文件不会被热加载。
3. 游戏内输入 `/mui` 看用法，`/mui status` 看模块与主题状态。

配置面板在暴雪界面设置里（`Esc → 界面`），设置存于 `MonetUIDB`。

## 🔗 依赖

- **硬依赖：无** —— `LibStub` 已内嵌在 `Libs/` 下，不需要额外安装任何库。
- **随包**：`LibMonetColor-1.0`、`MonetColorMapData-1.0`（自家仓库 [monetcolors](https://github.com/easthillgu/monetcolors) 的产物）、`LibActionButton-1.0`。
- **可选**：`CallbackHandler-1.0`、`LibCustomGlow-1.0`（缺失时动作条高亮静默降级）。

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
├── Utils/               Math Secrets Media EventBus Color Widget Skin
├── Config/              SimpleConfig 配置面板
├── Modules/             各功能模块（见上表）
├── Libs/                随包库 + NOTICE.md（第三方许可清单）
├── Assets/              字体 / 自绘材质 / 图标
├── docs/                开发记录、布局与材质预览页
└── tools/               材质与遮罩生成脚本
```

## ⚠️ 状态

**Phase 1/2 —— 离线验证通过，待实机验收。**

- `wuxian check` 全绿：**0 error**；仅 2 个 warning，均为有意为之（矩形化小地图覆写 `GetMinimapShape`）。
- 待验收：自绘材质接线、信息栏、`load` / `try` 热加载。
- 逐项进度与验收清单见 [`MonetUI.md`](MonetUI.md) 与 [`TODO.md`](TODO.md)；客户端约定见 [`AGENTS.md`](AGENTS.md)。

## 📄 协议

- **MonetUI 自身代码**：[MIT](LICENSE)。
- **随包第三方组件**保留各自许可：`LibStub`（公有领域）、`LibActionButton-1.0`（BSD-3-Clause，仅改三行）。完整清单与改动说明见 [`Libs/NOTICE.md`](Libs/NOTICE.md)。
- **随包字体**各自授权：FusionPixel 的 OFL 声明见 `Assets/Fonts/OFL-FusionPixel.txt`。

---

> 魔兽世界无限（WoW Forever） / Interface 16001 / Lua 5.1
