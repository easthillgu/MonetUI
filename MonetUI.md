# MonetUI 开发计划

> **创建日期**: 2026-10-13
> **最后更新**: 2026-10-13（字体资源就位，Phase 0 完成）
> **当前阶段**: Phase 0 — 框架搭建完成，字体资源就位，准备游戏内验证
> **目标**: 为魔兽世界无限 (WoW Forever) 打造一套莫奈风格整合 UI 插件

---

## 一、项目定位

MonetUI 是一套**整合 UI 插件**，以**莫奈印象派色彩**为核心设计语言，为 WoW Forever 提供：

- 自适应环境色彩的动态主题系统
- 模块化 UI 组件（单位框架、冷却、Buff、小地图等）
- 精简依赖、低复杂度的代码架构

**设计原则**：
1. **依赖精简** — 仅依赖 LibStub（必需）+ LibMonetColor（可选）+ CallbackHandler（可选）
2. **模块松耦合** — 模块间通过 EventBus 通信，不直接依赖
3. **私有 API** — 公共工具封装在 Utils 中，避免重复代码
4. **优雅降级** — MonetColor 缺失时使用内置默认配色
5. **Lua 5.1 兼容** — 不使用 5.2+ 特性（`//`、`goto`、`bit32`、`table.unpack`）

---

## 二、当前状态

### 已完成

| 任务 | 状态 | 说明 |
|------|------|------|
| 目录结构创建 | 完成 | 16 个文件，14 个目录 |
| Utils 层 | 完成 | Widget/Color/EventBus/Math |
| Core.lua | 完成 | 模块注册 + MonetColor 接入 + 事件监听 |
| Config 框架 | 完成 | SimpleConfig.lua（`/monetui` 或 `/mui`） |
| 模块占位 | 完成 | 6 个模块（UnitFrames/Cooldown/BuffFrame/Minimap/BagFrame/QuestTracker） |
| require 路径修复 | 完成 | `require("Utils.Color")` → 全局表引用 |
| Lua 5.1 兼容性检查 | 完成 | 无 5.2+ 特性 |
| wuxian check 语法验证 | 完成 | 无错误 |
| 安装到游戏 AddOns | 完成 | `Interface/AddOns/MonetUI/` |

### 待完成

| 任务 | 优先级 | 说明 |
|------|--------|------|
| wuxian load 热加载验证 | P0 | 验证运行时行为 |
| UnitFrames 完整实现 | P0 | PlayerFrame + TargetFrame |
| Cooldown 完整实现 | P0 | 冷却数字 + 触发监控 |
| MonetColor Phase 2 联调 | P0 | 环境采样器 + 色彩接入 |
| BuffFrame | P1 | 基础过滤 + 排序 |
| Minimap | P1 | 边框美化 |
| BagFrame | P1 | 基础整合 |
| QuestTracker | P2 | 任务追踪美化 |
| 配置面板完善 | P2 | 保存设置 + 实时预览 |
| 游戏内视觉验收 | P0 | 三地图验证 |
| 压力测试 | P1 | 10 万次 API 调用 |

---

## 三、目录结构

```
MonetUI/
├── MonetUI.toc                 # 插件入口清单
├── Core.lua                    # 核心：模块注册 + MonetColor 接入 + 事件监听
├── Utils/                      # 公共工具（私有 API）
│   ├── Widget.lua              # 控件工厂
│   ├── Color.lua               # 颜色接入层（MonetColor 封装）
│   ├── EventBus.lua            # 事件总线
│   └── Math.lua                # 数学工具
├── Modules/                    # 功能模块
│   ├── UnitFrames/             # 单位框架
│   ├── Cooldown/               # 冷却计时
│   ├── BuffFrame/              # Buff 框架
│   ├── Minimap/                # 小地图
│   ├── BagFrame/               # 背包
│   └── QuestTracker/           # 任务追踪
├── Config/
│   └── SimpleConfig.lua        # 轻量配置面板（无 Ace3）
├── Assets/
│   ├── Textures/               # 纹理资源
│   └── Fonts/                  # 字体资源
│       ├── Pingfangpixel.ttf   # 中文像素字体 — 所有中文文本
│       ├── combat.ttf          # 战斗字体 — 仅数字（伤害/治疗数值）
│       ├── super-effective.ttf # 冷却字体 — 冷却计时数字
│       └── roadeway.ttf        # Buff 半高字体 — 持续时间数字
└── Libs/
    ├── LibStub/                # LibStub 库
    └── LibMonetColor-1.0/      # 色彩引擎库
```

---

## 四、技术架构

### 4.1 依赖策略

```
必需: LibStub
可选: CallbackHandler-1.0 (有 fallback)
可选: LibMonetColor-1.0 (有 fallback)
不引入: Ace3, Masque, SharedMedia, oUF, cargBags
```

### 4.2 模块间通信

```
Module A ←→ EventBus ←→ Module B
```

- 模块不直接引用其他模块
- 通过 EventBus 发布/订阅事件
- Core 统一管理模块生命周期

### 4.3 颜色接入层

```lua
-- Utils/Color.lua 封装 MonetColor
local LMC = LibStub("LibMonetColor-1.0", true)

-- 有 MonetColor: 动态获取环境色
-- 无 MonetColor: 使用内置 Andromeda 风格默认配色
```

### 4.4 Lua 5.1 兼容清单

| 禁止 | 替代 |
|------|------|
| `//` 整数除法 | `math.floor(a / b)` |
| `goto` | 函数重构 |
| `bit32` 库 | 位运算用 `math.fmod` 或查表 |
| `table.unpack` | `unpack` |
| `table.pack` | 手动构造表 |
| `coroutine.close` | 不使用 |

---

## 五、模块清单与优先级

| 优先级 | 模块 | 功能 | 状态 | 参考 |
|--------|------|------|------|------|
| **P0** | UnitFrames | 单位框架（玩家/目标/焦点/队伍） | 框架已建 | Andromeda, EllesmereUI |
| **P0** | Cooldown | 冷却计时数字/框架 | 框架已建 | EllesmereUICooldownManager |
| **P1** | BuffFrame | Buff/Debuff 框架 | 框架已建 | EllesmereUIAuraBuffReminders |
| **P1** | Minimap | 小地图美化 | 框架已建 | EllesmereUIMinimap |
| **P1** | BagFrame | 背包整合 | 框架已建 | EllesmereUIBags |
| **P2** | QuestTracker | 任务追踪美化 | 框架已建 | EllesmereUIQuestTracker |
| **P2** | Chat | 聊天框美化 | 待建 | EllesmereUIChat |
| **P2** | Nameplates | 姓名板美化 | 待建 | EllesmereUINameplates |
| **P3** | RaidFrames | 团队框架 | 待建 | EllesmereUIRaidFrames |
| **P3** | ResourceBars | 资源条 | 待建 | EllesmereUIResourceBars |
| **P3** | ActionBars | 动作条美化 | 待建 | EllesmereUIActionBars |

### 字体资源

| 字体 | 文件 | 用途 | 来源 |
|------|------|------|------|
| 中文像素字体 | `Pingfangpixel.ttf` | 所有中文文本 | Andromeda |
| 战斗字体 | `combat.ttf` | 仅数字（伤害/治疗数值） | Andromeda |
| 冷却字体 | `super-effective.ttf` | 冷却计时数字 | Andromeda |
| Buff 半高字体 | `roadway.ttf` | 持续时间数字 | Andromeda |

---

## 六、开发计划

### Phase 0: 框架搭建 ✅ 当前阶段
- [x] 创建目录结构
- [x] 编写 Utils 层（Widget/Color/EventBus/Math）
- [x] 编写 Core.lua 核心入口
- [x] 编写 Config 配置框架
- [x] 编写各模块占位文件
- [x] 嵌入 LibStub 和 LibMonetColor
- [x] 修复 require 路径问题
- [x] Lua 5.1 兼容性检查
- [x] wuxian check 语法验证
- [x] wuxian check 语法验证
- [ ] wuxian load 热加载验证

### Phase 1: 核心模块开发
- [ ] UnitFrames 单位框架（P0）
- [ ] Cooldown 冷却计时（P0）
- [ ] 与 MonetColor 联调

### Phase 2: 功能模块开发
- [ ] BuffFrame（P1）
- [ ] Minimap（P1）
- [ ] BagFrame（P1）
- [ ] QuestTracker（P2）

### Phase 3: 完善与发布
- [ ] 配置面板完善
- [ ] 游戏内视觉验收
- [ ] 压力测试
- [ ] 文档编写
- [ ] 发布 v1.0.0

---

## 七、验收标准

- [ ] 插件可在 WoW 中加载无报错
- [ ] 模块可独立开关
- [ ] MonetColor 缺失时优雅降级
- [ ] 配置面板可保存设置
- [ ] 内存占用 < 5MB
- [ ] 代码无重复（通过 Utils 复用）
- [ ] Lua 5.1 兼容

---

## 八、决策记录

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-10-13 | 不引入 Ace3 | 减少依赖，自制轻量配置面板 |
| 2026-10-13 | 不引入 Masque | 直接控制纹理和颜色 |
| 2026-10-13 | 模块间通过 EventBus 通信 | 松耦合，便于维护 |
| 2026-10-13 | MonetColor 可选依赖 | 缺失时优雅降级 |
| 2026-10-13 | 不引入 oUF | 自制简化版单位框架，减少依赖 |
| 2026-10-13 | Lua 5.1 兼容 | WoW 客户端使用 Lua 5.1 |
| 2026-10-13 | require 改为全局表引用 | WoW .toc 加载机制不支持 require |
| 2026-10-13 | 字体分工：Pingfangpixel=中文文本，combat=仅数字 | 避免战斗字体渲染中文时的像素风格不一致 |
| 2026-10-13 | 字体来源 Andromeda assets/fonts/ | 已复制到 MonetUI/Assets/Fonts/ |

---

## 九、关键资产索引

| 资产 | 路径/位置 | 说明 |
|------|-----------|------|
| MonetColor 引擎 | `monetcolors\LibMonetColor-1.0.lua` | 色彩计算引擎 |
| MonetColor 测试 | `monetcolors\test_phase1.lua` | 45 个单元测试 |
| Andromeda 参考 | `wowaddonsdev\Andromeda\` | UI 设计参考 |
| EllesmereUI 参考 | `wowaddonsdev\EllesmereUI-v9.4\` | 模块实现参考 |
| ForeverUI 参考 | `wowaddonsdev\ForeverUI-0.4.24\` | 轻量实现参考 |
| wuxian MCP | 已连接 | 游戏内调试工具 |
| PortableGit | `wowaddonsdev\PortableGit\` | 版本管理 |
