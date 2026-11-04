# MonetUI 开发计划

> **创建日期**: 2026-10-13
> **最后更新**: 2026-10-24（污染链收尾：编辑模式 `oldR` / 姓名板机密值 / HUD 重复物 / buff 时间乱码；
> 详见 `docs/HANDOFF.md`，硬规则见 `AGENTS.md`。上一版 2026-10-18：圆角面板 + `monet_round_edge` 九宫格 —— 该方案 2026-10-31 已放弃并删除）
> **当前阶段**: Phase 1/2 — 八个模块已实现并通过 `wuxian check`，待游戏内 `load`/`try` 验证
> **目标**: 为魔兽世界无限 (WoW Forever) 打造一套莫奈风格整合 UI 插件

---

## 一、项目定位

MonetUI 是一套**整合 UI 插件**，以**莫奈印象派色彩**为核心设计语言，为 WoW Forever 提供：

- 区域驱动的主题系统：**环境色离线采样**（按区域从游戏截图提取，存成 `mapID → 环境 HSL` 表）+ **四档主题色运行期实时派生**（莫奈规则 + 亮度阶梯），随区域切换刷新；运行期不读任何贴图像素
- 模块化 UI 组件（单位框架、冷却、Buff、小地图等）
- 精简依赖、低复杂度的代码架构

**设计原则**：
1. **依赖精简** — 无外部必需依赖：`LibStub` 与色彩三件套（引擎 / 状态染色 / 区域色数据）全部内嵌在 `Libs/`；动作条自建，不引入动作条库
2. **模块松耦合** — 模块间通过 EventBus 通信，不直接依赖
3. **私有 API** — 公共工具封装在 Utils 中，避免重复代码
4. **优雅降级** — MonetColor 缺失时使用内置默认配色；区域没有环境色记录时沿 `C_Map` 父链继承大陆 / 世界层的派生色，父链也断时退回中性灰兜底（配置面板「区域配色」一行会写明当前用的是哪一档）
5. **Lua 5.1 兼容** — 不使用 5.2+ 特性（`//`、`goto`、`bit32`、`table.unpack`）

---

## 二、当前状态

### 已完成

| 任务 | 状态 | 说明 |
|------|------|------|
| 目录结构创建 | 完成 | 19 个源文件，15 个目录 |
| Utils 层 | 完成 | Widget/Color/EventBus/Math/Secrets/Media/Skin |
| 命名空间共享 | 完成 | 统一使用插件私有表 `ns`（`...` 第二个返回值） |
| Core.lua | 完成 | SavedVariables + 模块注册/生命周期 + 主题管线 + 斜杠命令 |
| Config 面板 | 完成 | SimpleConfig.lua，绑定 MonetUIDB，实时生效；内容区可滚动（滚轮 + 右侧滑块） |
| UnitFrames | 完成 | 玩家/目标/焦点/宠物，血条/能量/名字/等级/提示，连击点小格（盗贼/德鲁伊），可拖动并保存位置 |
| Cooldown | 完成 | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 |
| BuffFrame | 完成 | 自绘增益/减益网格，按时长排序，可读性守卫 |
| Minimap | 完成 | 矩形化 256×190 + 去坐标/时钟 + 主题面板 + 顶部区域名 + 暴雪集群按钮逐项接管 |
| ~~BagFrame~~ | **已移除**（2026-10-26） | 旧排列式背包，与 `Bags` 抢暴雪 `ContainerFrame` 的显隐；两套只留 `Bags` |
| QuestTracker | 完成 | 主题边框（圆角九宫格边纹）+ 标题栏拖动 + 位置保存 + 默认锚在小地图面板右上角（宽 264 = 面板宽） |
| ActionBars | 完成 | 1–8 号自绘动作条（**无库**：SecureActionButtonTemplate + actionpage）+ 接管宠物/姿态条 + 隐藏暴雪动作条/背包条 |
| Nameplates | 完成 | 挂在暴雪姓名板底座上的细条姓名板：血条/名字等级/百分比/施法条/借用暴雪减益/仇恨与目标描边；CVar 接管 + 点击区同步 + 完整回退 |
| Skins | 完成 | 界面美化：给暴雪窗口（任务、世界地图、角色、收藏、成就、社交、邮件/商贩/拍卖/专业、拾取/弹窗/菜单/设置等）统一铺 Monet 底板 / 边框 / 字体；可逐窗口开关，模块关闭可完整回退 |
| InfoBar | 完成 | 信息栏：贴顶边（可切底边）的整幅细条 + 6 个数据块（金钱 / 耐久 / 货币 / 延迟帧率内存 / 专精 / 好友），默认悬停淡入、战斗呼吸闪烁、宠物对战自动隐藏；`/mui infobar diagnose` 自检 |
| Forever 保密值适配 | 完成 | Utils/Secrets.lua，全部单位数值访问先查询 |
| Lua 5.1 兼容性检查 | 完成 | 无 5.2+ 特性 |
| wuxian check 语法验证 | 完成 | 31 个 Lua 文件，0 error / 2 warning（均为有意：覆写 `GetMinimapShape` ×2，矩形化小地图的设计使然）；参考插件来的 API 未入手册项与改名的全局均已消除 |
| 自绘 UI 材质接入 | 完成 | 24 组材质（关闭钮三态 / 窗口控件 / 图标 / Role / 装饰 / 状态条 / 边纹）由 `tools/regen-textures.js` 生成（包里只装 TGA，PNG 仅供网页预览、不进包，自校验）；关闭钮、勾选框、状态条填充已换自绘贴图（`Skin:SwapArt` / `barfill`），网页预览 `docs/texture-preview.html` |
| 安装到游戏 AddOns | 完成 | 2026-10-16 重新同步 85 个文件（旧快照已备份 Temp）；新增文件需**完整重启客户端** |

### 待完成

| 任务 | 优先级 | 说明 |
|------|--------|------|
| **姓名板驱散色探测（本轮重点）** | **P0** | **唯一目的**：确定这个客户端的 debuff 驱散色是**顶点色**还是**烘在贴图里**，据此决定姓名板 debuff 边框要不要再做逐图标颜色映射。<br>**怎么跑**：`/mui nameplates diagnose`，只看两行 —— `已修饰的 debuff 按钮：N 个` 和 `边框颜色：驱散色 A 个 / 主题色 B 个`。<br>**结果判读**：<br>① **A > 0** → 顶点色读得到，1px 边框已按驱散类型着色。**探测结束，本轮工作完成**，不需要任何后续。<br>② **A = 0 且 B > 0** → 颜色烘在贴图里，现在整排 debuff 边框统一为主题色，**驱散类型信息已丢失**。两条路二选一：(a) 接受 —— 视觉统一，类型靠图标本身识别；(b) 做映射 —— 读 `stock:GetAtlas()` / `GetTexture()` 的返回值，硬编码一张「贴图/驱动 → 离散类型色」的表。**选 (b) 前必须先截图确认观感**，因为映射表会随客户端更新失效。<br>③ **N = 0** → `DebuffListFrame` 这个名字在这个客户端不对，整套没跑。此时改用 `wuxian.inspect`（`mouse=true` 对着一个 debuff 图标）看 `AurasFrame` 的真实子结构，再回来改名字。<br>**注意**：这一条不是「验收」，是**决定后续方向的探测** —— 结果不同，后面的工作量差一个数量级（(a) 零， (b) 一张映射表 + 回归测试） |
| 本轮四项改动实机验收 | P0 | 全部离线完成，**零运行时验证**：① `Media:Mult()` 补回 `768/physH` → 1080p 下所有边框细 29%，观感偏细就调 `thickness` 默认值，**不要**回退公式；② `UI_SCALE_CHANGED` + 登录后 1s/4s 补两遍 → 拉缩放滑块后已存在与新建的边框宽度是否一致；③ 目标光环 B 方案（原生 `AuraContainer`）→ 目标 buff/debuff 出不出、能否点图标换目标、buff 是否叠在 debuff 之上、失败时聊天框第一条警告说哪一步断；④ 姓名板 debuff reskin → 图标裁边、边框细度、像素字体、冷却扫圈 |
| 自绘材质接线游戏内验收 | P0 | 关钮三态 / 勾选框 / 状态条已接线；完整重启后 `/verify` + 逐窗口目检。未接线（备用）：窗口最小化/最大化钮、翻页箭头、角饰 |
| 材质细节打磨（下次继续） | P1 | 生成器已迁移到 `tools/regen-textures.js`；审查工具：`tools/make-review-sheet.js`（contact sheet）+ `tools/tga-dump.js`（单张像素/剖面转储）。**已修**：`corner` 弧尖裁切、透明像素纯黑、`barfill` 下半幅纯黑、`brush_stroke` 双色被压没、两种织纹无孔、role 三图标语义色与形状。**本轮对齐参考插件 EllesmereUI**：barfill 改平色 + 运行期渐变、加发丝线、透明 RGB 改纯白哑光、role 图标改灰度按状态染色。**待办**：① **切 RLE**（已实测：611 KB→60 KB，26/26 逐字节回环一致，零像素变化；唯一要改的是材质规范里"类型 2（未压缩）"那一条，等拍板）；② `Color:RoleTint` 的染色规则是**暂定**的（队长/助理染色、其余单色），且三张 role 图标在代码里**只注册未接线**；③ `Widget:Hairline` 已就位但还没有调用点；④ `win_*` / `arrow_*` / `plus` / `minus` / `chevron_*` / `search` / `radio` 同样只注册未接线；⑤ 圆角方案已于 2026-10-31 放弃（见 `docs/HANDOFF.md` 8.5.1 收口）；⑥ 全部纹理需游戏内实机确认（像素与规范已过，未验证客户端缩放与 `SetGradient` 叠加后的观感） |
| wuxian load 热加载验证 | P0 | 需游戏运行（当前离线） |
| 信息栏游戏内验收 | P0 | 先 `/mui infobar diagnose` 读 PROBED 与耐久签名实测结果，再逐块 snap；验证悬停淡入 / 战斗呼吸 / 宠物对战隐藏 / 模块关掉即时还原 |
| 游戏内视觉验收 | P0 | 三地图验证 + 暴雪框架接管是否产生 taint |
| MonetColor Phase 2 联调 | P0 | 环境采样器（引擎侧） |
| 队伍/团队框架 | P1 | RaidFrames（当前仅单人单位） |
| 备用能量条（真 `AltPower`，载具/任务/首领）、DK 符文、其他职业资源 | P3 | 暴雪 `PlayerFrame.powerBarAlt` 目前跟着 `PlayerFrame` 一起被隐藏，尚无替代；圣能/气/碎片/充能/精华在 Forever 版本不存在，不做；见「连击点」一节 |
| 聊天框美化 | P2 | 见模块清单 |
| 压力测试 | P1 | 10 万次 API 调用 |
| 发布 v1.0.0 | P2 | 文档 + 打包 |

---

## 三、目录结构

```
MonetUI/
├── MonetUI.toc                 # 插件入口清单
├── Core.lua                    # 核心：模块注册 + MonetColor 接入 + 事件监听
├── Utils/                      # 公共工具（私有 API，全部挂在 ns 上）
│   ├── Math.lua                # 数学工具 + 数字/时间格式化
│   ├── Secrets.lua             # Forever 保密值处理层
│   ├── Media.lua               # 字体/纹理注册表
│   ├── EventBus.lua            # 事件总线（按需注册，含单位事件）
│   ├── Color.lua               # 颜色接入层（MonetColor 封装 + 降级）
│   ├── Widget.lua              # 控件工厂 + 主题注册表
│   └── Skin.lua                # 暴雪窗口皮肤原语（剥皮/底板/控件/文本，可回滚）
├── Modules/                    # 功能模块
│   ├── UnitFrames/             # 单位框架
│   ├── Cooldown/               # 冷却计时
│   ├── BuffFrame/              # Buff 框架
│   ├── Minimap/                # 小地图
│   ├── Bags/                   # 分类背包（取代已移除的 BagFrame）
│   ├── QuestTracker/           # 任务追踪
│   ├── ActionBars/             # 动作条（1–8 号自绘 + 接管宠物/姿态条）
│   ├── Nameplates/             # 姓名板（暴雪底座 + 自绘细条）
│   ├── InfoBar/                # 信息栏（贴边细条 + 6 个数据块）
│   │   ├── InfoBar.lua         # 引擎：容器 / 排版 / 淡入呼吸动画 / 自检
│   │   └── Blocks.lua          # 数据块：金钱 / 耐久 / 货币 / 系统 / 专精 / 好友
│   └── Skins/                  # 界面美化（暴雪窗口皮肤引擎 + 分窗口皮肤）
│       ├── Skins.lua           # 引擎：注册表 / 生命周期 / 完整回退 / 全局字体
│       ├── Quest.lua           # 任务日志 + 任务 / 对话窗口
│       ├── WorldMap.lua        # 世界地图 + 地图内任务面板
│       ├── Character.lua       # 角色界面 + 观察
│       ├── Collections.lua     # 收藏 / 成就 / 冒险指南
│       ├── Social.lua          # 好友 / 社区 / 公会 / 日历
│       ├── Trade.lua           # 邮件 / 商贩 / 训练师 / 拍卖 / 专业 / 银行
│       └── System.lua          # 拾取 / 弹窗 / 游戏菜单 / 设置 / 插件列表 / 菜单 / 提示
├── Config/
│   └── SimpleConfig.lua        # 轻量配置面板（无 Ace3）
├── Assets/
│   ├── Textures/
│   │   ├── minimap_rect_mask.tga      # 小地图矩形遮罩（256×256，四角圆角 4，脚本生成）
│   │   └── monet_*.tga                # 自绘 UI 材质 24 组（关闭钮/窗口/图标/Role/装饰/状态条/边纹；只有 TGA）
│   └── Fonts/                  # 字体资源（全部为像素字体）
│       ├── fusion-pixel-12.ttf # Fusion Pixel 12px — 所有文本（SIL OFL，网格 = em/12）
│       ├── OFL-FusionPixel.txt # Fusion Pixel 授权全文
│       ├── super-effective.ttf # 冷却字体 — 冷却计时数字（ASCII 像素字）
│       ├── Pingfangpixel.ttf   # 遗留保留（已无引用，回滚用）
│       └── roadway.ttf         # 遗留保留（已无引用，回滚用）
├── tools/
│   ├── regen-textures.js       # 生成全部自绘材质（node-canvas/Cairo 精确矢量；TGA 进包，PNG 只写进 gitignore 的 docs/texture-preview/）
│   ├── gimp-brush-stroke.py    # 油画笔触：GIMP 3.2 的画笔引擎（Oils/Bristles 笔刷）画的，逐点盖章
│   ├── gimp-icons.py           # 手绘感图标的画法样本（对比用，默认不进包）
│   ├── svg/                    # 手写矢量源码（可在 Inkscape 里直接打开改）
│   ├── svg-to-tga.js           # SVG → 项目格式 TGA（Inkscape 出 PNG 中转 + 补纯白衬底 + 尺寸校验）
│   ├── tga-post.js             # GIMP/任意来源的 PNG → 项目格式 TGA（未压缩 32bit）+ 补纯白衬底
│   ├── make-review-sheet.js    # 材质审查表：25 张 TGA 解码后按整数倍最近邻铺成 contact sheet（深色/浅色/棋盘），一屏看完
│   ├── tga-dump.js             # 单张 TGA 的 ASCII 像素转储（--bak 读旧稿 / --rgb 看颜色 / --cross 看中线剖面）
│   ├── estimate-rle.js         # 估算改 RLE 压缩能省多少字节（含逐字节回环校验，不写文件）
│   ├── analyze-ref-barfill.js  # 参考插件 EllesmereUI 的 21 张 bar fill 纹理剖面分析（只读）
│   ├── make-variant-sheet.js  # 三套变体并排对比表（按字节判重，只给有差异的纹理排版；含 18px 实显格）
│   ├── make-variant-index.js  # 把上一步的分页 PNG 拼成一个 HTML 索引，方便一次看完
│   ├── audit-pixels.js        # 像素级审计：半覆盖像素 / 软边直边 / 孤立像素，带 STRICT 与 NO_SOFT_EDGE 验收标准表
│   ├── make-pixel-grid-sheet.js # 像素网格检视表：整数倍最近邻放大 + 源像素边界网格线，肉眼确认边有没有压在像素上
│   ├── test-mult.js           # Mult() / SnapUnit() 离线自测：边框宽度是否恒定 + 吸附是否落在网格上 + 退化输入是否退回 1；带源码断言防公式漂移
│   ├── make-preview.mjs        # 把 docs/mockup 的设计稿渲染成同名 PNG（静态服务 + 无头 Edge/CDP）
│   └── deprecated/             # 旧 PowerShell 生成脚本（已由 regen-textures.js 取代，仅存档）
└── Libs/
    ├── LibStub/                # LibStub 库
    ├── LibMonetColor-1.0/      # 色彩引擎库
    ├── LibMonetColor-Anim-1.0/ # 状态染色层（战斗 / 低血 / 休息的边框色）
    ├── MonetColorMapData-1.0/  # 区域环境色数据（实测表 + 派生父层 override）
    │   ├── MonetColorMapData-1.0.lua       # 14 区实测色（生成物，禁止手改）
    │   └── MonetColorMapEnvOverride.lua    # 3 条大陆 / 世界层派生行（运行时 override 通道）
    └── NOTICE.md               # 随包库的来源与许可说明
```

---

## 四、技术架构

### 4.1 依赖策略

```
必需: LibStub（已内嵌，无外部安装项）
随包: LibMonetColor-1.0（配色引擎）、LibMonetColor-Anim-1.0（状态染色层）、MonetColorMapData-1.0（区域环境色 + 派生父层）
      —— 任一缺失只降级为内置默认配色，不报错
不引入: Ace3, CallbackHandler, Masque, SharedMedia, oUF, cargBags, LibActionButton
```

> 动作条**不依赖任何动作条库**：`Modules/ActionBars/ActionBars.lua` 直接用客户端的
> `SecureActionButtonTemplate` + `actionpage` 属性自绘按钮，施法 / 翻页 / 载具条
> 全部由客户端判定（见该文件头部注释）。

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

-- 有 MonetColor: 拿当前 mapID 查「离线按区域采样的环境色」表 → 莫奈规则运行期实时派生四档
-- 无 MonetColor: 使用内置 Andromeda 风格默认配色
```

**环境色不是实时取出来的**：本客户端没有任何可用的贴图像素读取 API（`GetTexPixel` 不存在，
`Region:GetVertexColor` / `FontString:GetTextColor` 全标机密），所以环境色由兄弟仓 monetcolors
离线从游戏截图按区域提取（39 张截图 / 14 个区域），随包成 `MonetColorMapData-1.0`；**运行期只查表 + 派生**，
换区域不等分析、也不会卡一下。

引擎解析序（`LibMonetColor-1.0.lua:580-611`），一个区域最终落在哪一档由 `GetMapEnv` 的 `source` 写明：

| 档 | 来源 | 现状 |
|----|------|------|
| `override` | `RegisterMapEnv` 运行时注册的派生行 | 3 条：卡利姆多 1414 / 东部王国 1415 / 艾泽拉斯 947，色由该层成员区实测色取**圆均值**算出，不改生成文件本体（`Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua`，在 `Core.lua` 之前加载） |
| `data` | 随包实测表 | 14 条（`MonetColorMapData-1.0.lua`，AUTO-GENERATED，禁止手改） |
| `parent:data` / `parent:override` | 沿 `C_Map` 父链继承祖先层（深度上限 5） | 新手区 / 首都多数走这条，落到同大陆调子 |
| `fallback` | 无彩灰 `{0, 0, 0.5}` | 父链也断时；实机银月城 2393 目前仍在这一档 —— 它的父层归属（是否挂在东部王国 1415 下）离线没有表可查，实机核上父链后就会继承 1415 的派生色 |

覆盖率有数字了，不再靠感觉：`node tools/map-env-coverage.js`（只读脚本，不进发行包）按引擎同一条解析序
把仓库已记录的 29 个 mapID 分成三档 —— **有色 17 / 走父链 9 / 落兜底 3**。口径注意：这是**已记录清单**，
不是全量地图表（离线拿不到 1.60 的 UiMap 表），脚本里的父层关系标 `ASSUMED`；全量三档要实机跑
`C_Map.GetMapChildrenInfo(947, nil, true)` 导出 `{ mapID, name, parentMapID }` 再喂 `--dump`。

配置面板主题组新增**「区域配色」一行**：当前区域名 + `panel / hover / lost / fill` 四档实色块（透明度照
`SURFACE_STEPS`），落 `fallback` 时在下方写明「这个区域没有环境色记录 · 四档走兜底灰」—— 这是玩家唯一能
感知「这个区没采到色」的入口；引擎未接入或地图 ID 读不到（受限窗口）也各有一句。

**签名三色（edge / ambient / highlight）+ neutral 全部来自引擎**；health / resource / danger 由 UI 自己管，
不做「Monet 化」。

**边框颜色已经预留走 MonetColor**：单位框架、小地图面板、动作条、Buff 按钮、配置面板等所有边框都经
`Widget:Theme()` 注册，刷新时读 `Color:GetBorder()`（背景读 `Color:GetAmbient()`）。所以引擎换色**不需要改任何
模块代码** —— 只要 `Color:Refresh()` 后再广播 `MONETUI_THEME_CHANGED`，`Widget:RefreshThemes()` 就会把所有
已注册控件重新染色。

刷新时机：

| 时机 | 触发 |
|------|------|
| 登录 / 区域变化 / 手动 `/mui theme` | Core 监听 `ZONE_CHANGED*`、`PLAYER_ENTERING_WORLD` → `ns.RefreshTheme()` |
| 引擎主动通知（切换配置档、引擎侧刷新） | Core 订阅 LibMonetColor 的 `OnThemeColorsChanged` 回调 → `ns.RefreshTheme("monet")` |

回调订阅做了**形态探测**：LibMonetColor 可能带 `CallbackHandler-1.0`，也可能走它内置的回退注册表，两者的
`RegisterCallback` 调用形状不同（`LMC:RegisterCallback(事件, fn)` vs `LMC.events:RegisterCallback(键, fn)`）。
Core 先探测、两路都试且都 `pcall`；都拿不到时静默跳过，**区域事件刷新仍是兜底**。订阅状态见
`/mui status` 的 `回调: 已订阅 / 未订阅`。

**边框色槽可切换（配置面板「边框颜色」）**：边框取哪个引擎色槽由用户选择，存于 `MonetUIDB.theme.borderKey`
（默认 `edge`）：

| 值 | 含义 |
|----|------|
| `edge` | 边缘色（Monet 签名，默认） |
| `ambient` | 环境色 |
| `highlight` | 高亮色 |
| `neutral` | 中性灰 |

`Widget:Theme` 通过 `Color:GetBorderKey()` 决定色相；单个控件仍可用
`Widget:Theme(frame, { borderKey = "highlight" })` 单独覆盖。**只有色相跟着色槽走，透明度固定用 edge 的**，
所以选到半透明的 `ambient` 也不会让边框淡到看不见。改这一项后走 `RefreshTheme`，全部边框（含动作条按钮描边、
Buff 边框）即时生效。

#### 4.3.1 状态染色层（LibMonetColor-Anim-1.0）接入

引擎侧新增了独立的**状态染色层** `LibMonetColor-Anim-1.0`：它把**玩家状态**（战斗中 / 休息 /
低血 / PvP / 载具 / 死亡）翻译成颜色修饰，并由**一个共享 ticker** 驱动所有闪烁动画（战斗进入闪烁、
战斗增亮、持续脉搏、低血红与加速脉搏、脱战降亮、休息冷调）。单位框架不再自己判断状态。

接入方式（`Modules/UnitFrames/UnitFrames.lua`）：

| 位置 | 做法 |
|------|------|
| 注册 | `Anim:RegisterColorSink(fn, { base = function() return Color:GetBorderKey() end, pulse = true })`，每个框架一个 sink |
| 落色 | 回调把颜色存进 `frame.monetColor`，再走 `Widget:SetBorderState(frame, ...)`（沿用现有"活状态覆盖"通道，主题刷新不会冲掉） |
| 悬停 / 仇恨 | 优先级更高：进入时置 `frame.monetBorderOverride = true`，库的重绘被跳过；退出时 `RestoreDynamicBorder()` 把库的颜色还回来 |
| 模块关闭 | `M:SetEnabled(false)` 同时 `SetEnabled(false)` 掉所有 sink，ticker 随之停表 |

**边界**：状态层只判定**玩家**状态，不判定目标 / 队伍 / 敌方的血量——目标框的"低血"提示仍由 UI 自己负责。
色槽跟随用户的「边框颜色」设置（`base` 传函数，每次重绘重新解析）。
`LibMonetColor-Anim-1.0` 是**新增文件**，首次加载需要重启客户端；缺库时 `ns:GetAnim()` 返回 nil，
单位框架自动退回"主题色槽"行为，不影响其它模块。

#### 4.3.2 美术色白名单（2026-10-27 立）

5+3 槽位管的是**界面构件**（边框、底、文字、条）。**插画件 / 语义徽记**例外 —— 它们靠固定的
美术色传达含义，跟着主题漂移反而认不出来。凡用白名单色，**必须**在定义处写明用途，并且贴图仍是
中性模具（灰阶 / 纯白，色相 = 0，`tools/audit-pixels.js` 的 STENCIL 名单强制）。

| 用途 | 颜色 | 位置 | 理由 |
|------|------|------|------|
| 背包任务物品琥珀 | `QUEST_COLOR = (0.80, 0.80, 0.00)` | `Modules/Bags/Bags.lua` | 任务品边框，玩家靠"琥珀边"一眼认任务（Andromeda 同款语义） |
| 背包任务标记 `!` | `(1.00, 0.82, 0.00)` | `Modules/Bags/Bags.lua` | 同上，金色是任务信号的载体 |
| 施法火花内芯（红） | `SPARK_FILL = (1.00, 0.18, 0.10)` | `Modules/UnitFrames/CastBar.lua` | 危险红：施法条已无填充条，红色三角是"正在施法/可断"的唯一信号 |
| 施法火花描边 | `SPARK_EDGE = (0.10, 0.03, 0.03)` | `Modules/UnitFrames/CastBar.lua` | 近黑暖灰描边：3px 总高的东西没有描边就糊进条底；不可断施法两层一起转中性灰 |
| 进出战斗提示 · 剑 | 金 `(0.92, 0.70, 0.28)` / 青蓝 `(0.45, 0.78, 0.90)` | `Modules/CombatText.lua` | 插画件；主题签名槽是边框用的低饱和色，染大块剑刃会发灰（实机验过） |
| 进出战斗提示 · 盾 | 与大字同语义：danger / health / 暖金 | `Modules/CombatText.lua` | 盾 = 状态主角，红（危险）/ 绿（安全）/ 金（进入战斗） |

**判定口径**：问"这个颜色去掉，玩家会不会看不出功能含义？"——会，就进白名单；不会（纯装饰），就该走槽。
**白名单不是免死金牌**：新色要在这里加一行 + 在代码里写用途注释，否则按违规处理。

### 4.4 Lua 5.1 兼容清单

| 禁止 | 替代 |
|------|------|
| `//` 整数除法 | `math.floor(a / b)` |
| `goto` | 函数重构 |
| `bit32` 库 | 位运算用 `math.fmod` 或查表 |
| `table.unpack` | `unpack` |
| `table.pack` | 手动构造表 |
| `coroutine.close` | 不使用 |

### 4.5 命名空间与跨文件共享

WoW 会**丢弃** .toc 内每个文件的返回值，因此各文件不能通过 `return X` 互相传递模块。
WoW 为同一插件的所有文件传入相同的 `...`：

```lua
local ADDON_NAME, ns = ...   -- ns 是整个插件共享的私有表（所有文件同一个）
```

- 每个 Utils 文件把自己挂到 `ns` 上（`ns.Color`、`ns.Widget`、`ns.Secrets`、`ns.Media`、`ns.Math`、`ns.EventBus`）
- Core.lua 在 `ns` 上增加模块注册表与生命周期方法
- 模块通过 `ns:Register(name, module)` 注册，通过 `ns:GetModule(name)` 取用
- `_G.MonetUI = ns` 仅作为调试用别名

**这是本项目最容易出错的地方**：之前版本用 `return X` 传递，导致 `Utils/Widget.lua` 里的
`local Color = Color` 解析成全局 `Color`（nil），一旦调用 `Widget:ApplyBorder` 就会报错。

### 4.6 Forever 保密值处理层（Utils/Secrets.lua）

"无限" 客户端在**战斗 / PvP / Boss / 聊天锁闭**等状态下会向插件返回 `<secret>` 值。
对保密值做**算术、比较、真值判断、拼接、格式化**会直接抛错：

```
attempt to perform arithmetic on a secret number value
```

规则：

1. 控件可以安全接收保密值（如 `StatusBar:SetValue(secret)`），**血条照常填充**
2. 任何要"读数字/比较/格式化"的地方，必须先询问 `C_Secrets.Should*BeSecret(...)`
3. 查询失败或 API 缺失时**一律当作保密**处理（宁可不显示，不可报错）
4. 不受限时行为与普通客户端完全一致

```lua
if Secrets.CanMeasureHealth("player") then
    local cur = Secrets.Number(UnitHealth("player"))  -- 安全取数
    ...
else
    frame.healthText:Hide()   -- 只显示血条，不显示数字
end
Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit))  -- 内部 pcall
```

> **绝不注册** `COMBAT_LOG_EVENT_UNFILTERED`（12.0+ 已移除且受限）。
> EventBus 采用**按需注册**，不再预注册固定事件列表。

---

## 五、模块清单与优先级

| 优先级 | 模块 | 功能 | 状态 | 参考 |
|--------|------|------|------|------|
| **P0** | UnitFrames | 玩家/目标/目标的目标/焦点/宠物框架，血条能量条、连击点（盗贼/德鲁伊）、名字等级、拖动保存 | ✅ 已实现 | Andromeda, EllesmereUI |
| **P0** | Cooldown | 冷却数字/充能/快捷键字体美化 + 技能可用状态着色 | ✅ 已实现 | EllesmereUICooldownManager |
| **P1** | BuffFrame | 自绘 Buff/Debuff 网格，按时长排序，可读性守卫 | ✅ 已实现 | EllesmereUIAuraBuffReminders |
| **P1** | Minimap | 矩形小地图（256×190）、去圆形边框/指南针、主题面板、顶部区域名、暴雪集群按钮逐项接管 | ✅ 已实现 | EllesmereUIMinimap, Andromeda |
| **P1** | BagFrame | 背包排列整合 + 主题边框 + 标题字体 | ✅ 已实现 | EllesmereUIBags |
| **P2** | QuestTracker | 主题边框 + 标题栏拖动 + 位置保存 | ✅ 已实现 | EllesmereUIQuestTracker |
| **P2** | ActionBars | 1–8 号自绘动作条（**无库**：SecureActionButtonTemplate + actionpage 驱动、安全翻页、原按键沿用）+ 接管宠物/姿态条 + 隐藏暴雪动作条与背包条 | ✅ 已实现 | EllesmereUIActionBars, Andromeda |
| **P2** | Chat | 聊天框美化 | 待建 | EllesmereUIChat |
| **P2** | Nameplates | 姓名板美化（暴雪底座 + 自绘细条、CVar 接管、借用暴雪减益、施法条、仇恨/目标描边） | ✅ 已实现 | EllesmereUINameplates, ForeverUI, Andromeda |
| **P2** | Skins | 界面美化：暴雪窗口（任务/地图/角色/收藏/社交/交易/系统）统一铺 Monet 底板、边框与字体；逐窗口开关、模块可完整回退 | ✅ 已实现 | EllesmereUIBlizzardSkin, Andromeda, ForeverUI, ElvUI Skins |
| **P2** | InfoBar | 信息栏：贴顶边（可切底边）的整幅细条 + 6 个数据块（金钱/耐久/货币/系统/专精/好友），悬停淡入、战斗呼吸闪烁、宠物对战自动隐藏 | ✅ 已实现 | Andromeda `modules/infobar/`（只借结构与取值） |
| **P3** | RaidFrames | 团队框架（队伍/团队） | 待建 | EllesmereUIRaidFrames |
| **P3** | ResourceBars | 资源条（备用能量 `AltPower`、符文等剩余资源显示） | 待建 | EllesmereUIResourceBars |

### 布局锚点（照搬 Andromeda，`UI_GAP = 33`）

| 元素 | 锚点 | 坐标 | 尺寸（宽 × 高） |
|------|------|------|------|
| player | `CENTER` / UIParent `CENTER` | `(0, -180)` | 160 × 6 |
| target | `LEFT` / player `RIGHT` | `(40, 40)` | 160 × 6 |
| targettarget | `LEFT` / target `RIGHT` | `(6, 0)` | 60 × 6 |
| pet | `RIGHT` / player `LEFT` | `(-6, 0)` | 60 × 6 |
| focus | `RIGHT` / player `LEFT` | `(-100, -40)` | 60 × 6 |
| 连击点 | `TOPLEFT` / player `BOTTOMLEFT` | `(0, -3)` | 玩家框宽 × 3，5 格（见下） |
| 小地图 | `BOTTOMRIGHT` / UIParent `BOTTOMRIGHT` | `(-33, 33)` | 256 宽 × 190 高（面板 264 × 198） |
| 增益 Buff | `TOPLEFT` / UIParent `TOPLEFT` | `(33, -33)`，每行 8 个 | 图标 34 × 34 |
| 减益 Debuff | `TOPLEFT` / Buff容器 `BOTTOMLEFT` | `(0, -8)` | 图标 34 × 34 |

> 坐标与 Andromeda 完全一致（含 `focus` 的 `-100`：由于单位框已细条化到 60 宽，不再需要外推）。
> 每个单位的 `width` / `health` / `power` 都存在 `MonetUIDB.unitFrames[unit]`，可直接调数值微调。
> 单位框位置也存同一张表，拖动后按**相对锚点**保存（拖 player 时依赖它的框会自动跟随）。

#### 个单位框高度构成

```
总高 = 边框 1 + 血条 2 + 间隔 1 + 能量条 1 + 边框 1 = 6
```

血条贴顶、能量条贴底（与 Andromeda 的 `Health` / `Power` 锚点一致）；`间隔` 对应 Andromeda 的
`C.MULT`（1440p 下约为 1）。数值均可在 `MonetUIDB.unitFrames` 调整。

> **为什么血条是 2 而不是 Andromeda 的 4**：Andromeda 会执行
> `UIParent:SetScale(clamp(768 / 屏幕高, 0.4, 1.15))`（1440p 约 **0.53**，见其 `core/uiscale.lua`），
> 它的整个坐标系比我们小一半左右 —— 配置里写的 4 实际只画到约 2。MonetUI 不缩放 UIParent
> （`Frame:SetScale` 是受保护方法，缩 UIParent 等于连暴雪 UI 一起缩），所以取 Andromeda 的 50%。

#### 血条着色

血条由两层组成：底层一张铺满的贴图表示**损失**掉的部分，上层 `StatusBar` 只填到当前值，
因此底层只在掉血的那一段露出来。**两层都不需要读任何单位数值**，所以战斗中客户端把血量变成
`<secret>` 时着色依然正确（只有百分比数字要读值，读不到就不显示数字）。

| 单位 | 当前血量（`fillColor`） | 损失部分（`lostColor`） |
|------|------------------------|------------------------|
| player / pet | `highlight` — Monet 高亮奶油色 | `black` — 读作背景 |
| target / focus / targettarget | `class` — 职业色（NPC 用阵营反应色） | `danger` — 读作已造成的伤害 |

`fillColor = "class"` 用 `UnitSelectionColor(unit)` 取色：一次调用同时给出玩家职业色与 NPC 的
反应色，而且**不返回保密值**（不像 `UnitClass` 需要先用 `Secrets.CanReadIdentity` 守卫）。

血量数字按百分比着色（`textColorByPercent`，4 个定点插值：绿 → 黄 → 橙 → 红）——不用红绿直接
线性插值（中间会发褐），对色盲也更友好。

`fillColor` / `lostColor` / `textColorByPercent` / `powerColor` / `smoothBars` / `classPower` /
`classPowerHeight` / `classPowerGap` 都存在 `MonetUIDB.unitFrames`，改值即可换风格；配置面板「单位框架」
一栏有对应的下拉与勾选框。

##### 能量条分色

每次刷新都用 `UnitPowerType(unit)` 重新取一次类型（变身 / 姿态 / 载具 / 遭遇战机制都会换能量），
返回的 token（`MANA` / `RAGE` / `ENERGY` / `RUNIC_POWER` …）查 `POWER_COLOR` 表上色；表里没有的
类型退回到 `UnitPowerType` 一并返回的客户端自带颜色，再退回主题的资源色。`powerColor = "theme"`
可以关掉分色、统一用主题色。用 `UNIT_DISPLAYPOWER` 事件驱动，切换形态时立刻换色。

##### 死亡 / 掉线变灰

`UnitIsDeadOrGhost` 或 `UnitIsConnected` 为假时，对血条与能量条调用
`StatusBar:SetStatusBarDesaturated(true)`。**变灰由客户端完成**（`Enum.SecretAspect.Desaturation`），
我们只传一个自己算出来的布尔值，不读任何单位数值，所以战斗中数值被隐藏时同样有效。
另外，单位死亡后血量归零、整条都露出「损失」贴图，而那张贴图是普通纹理、客户端不会替我们褪色，
所以死亡时把它的顶点色单独改成中性灰，尸体的条才不会还是一整条红。
驱动事件：`PLAYER_DEAD` / `PLAYER_ALIVE` / `PLAYER_UNGHOST` / `UNIT_CONNECTION`。

##### 数值平滑

血条与能量条的 `SetMinMaxValues` / `SetValue` 都会带上
`Enum.StatusBarInterpolation.ExponentialEaseOut`，让条子缓动到新值而不是瞬间跳变 —— 插值在客户端
内部完成（`Enum.SecretAspect.BarValue`），因此**机密值也能走平滑路径**。`smoothBars = false` 关闭。
`Utils/Secrets.lua` 在加载时查一次该枚举，查不到就退回不带插值的旧调用。

##### 连击点（classPower）

暴雪把玩家的连击点画在 `PlayerFrame.classPowerBar` 里，备用能量条画在 `PlayerFrame.powerBarAlt` 里。
这两个都是 `PlayerFrame` 的**子框体**，`SuppressBlizzard` 一 Hide 父框体就一起消失了 —— 也就是说，
不做替代的话盗贼会只剩那条能量条、**连击点完全看不到**。本模块因此在玩家框体下方补了一排小格
（`CLASS_POWER` 表）：

| 职业 | 资源 | 能量类型 | 默认格数 |
|------|------|----------|----------|
| ROGUE | 连击点 | `ComboPoints` | 5 |
| DRUID | 连击点 | `ComboPoints` | 5（仅猫形态：`UnitPowerType == ENERGY`） |

> Forever 版本**没有**圣能 / 气 / 灵魂碎片 / 奥术充能 / 精华这些资源，所以 `CLASS_POWER` 只列盗贼与
> 德鲁伊；机制本身是通用表，将来该版本补了别的资源再加一行即可。

- **几何**：格子条 = 单位框宽度 × `classPowerHeight`（默认 3），挂在玩家框 `BOTTOMLEFT` 下方
  `classPowerGap`（默认 3）处，格与格之间也留 `classPowerGap`；颜色查 `POWER_COLOR.COMBO_POINTS`。
- **保密值安全**：每格是一个 `StatusBar`，范围写成 `(i-1, i)`，把原始点数（可能是 `<secret>`）直接丢给
  `SetValue`，由客户端自己裁剪 —— 我们这边**不做任何比较或减法**。只有「满了变红」要同时读到当前值与
  上限，读不到就保持普通颜色。
- 格数取 `UnitPowerMax(unit, power)`；该值被隐藏时**不重排**（沿用上次读到的格数，首次用表里的默认值），
  避免机密值一出现整排格子跳动。防御性上限 10 格。
- 上限为 0（德鲁伊非猫形态、或该单位确实没有连击点）时整排隐藏；`UNIT_DISPLAYPOWER` 驱动德鲁伊形态切换，
  `UNIT_POWER_UPDATE` 用事件带回来的 token 过滤（能量每秒跳十次，只有 `COMBO_POINTS` 的事件才刷新），
  `UNIT_MAXPOWER` 处理天赋改变上限；死亡/掉线时和血条一样 `SetStatusBarDesaturated` 变灰。
- 配置面板「单位框架」一栏的 **连击点（盗贼 / 德鲁伊）** 下拉：`关闭` / `2–5 px`（一个下拉同时管开关与高度）。

**尚未覆盖**（现阶段不做）：死亡骑士符文、其他职业资源（该版本不存在），以及「充能连击点」高亮
（`GetUnitChargedPowerPoints`）。另外 `PlayerFrame.powerBarAlt`（真正的备用能量条：载具 / 任务 / 遭遇战
给的那条）目前也仍只是跟着暴雪框体一起被隐藏，**没有替代实现**。

#### 文字位置（参考 Andromeda 的 tag 锚点，全部在条**上方** 3px）

| 单位 | 左上方 | 右上方 | 居中上方 |
|------|--------|--------|----------|
| player | 名字 + 等级 | 血量 `当前 / 最大` | — |
| target | 血量 `当前 / 最大` | 名字 + 等级 | — |
| targettarget | — | — | 名字 |
| focus | — | — | 名字 |
| pet | — | — | —（无文字，同 Andromeda） |

- **名字显示（2026-10-27 玩家定的 70% 规则，现行）**：名字最多占名牌/框宽 **70%**，超了就
  **逐档缩小字号**（1px 一档），**绝不截断** —— 统一入口 `Widget:FitText`
  （`Utils/Widget.lua`；机密名/机密宽度走它的"不测不缩"分支，原样按基础字号显示）。
  三个调用点：`Nameplates.UpdateText`（限额还要扣 level 段实测宽防挤）、
  `UnitFrames.UpdateName`（再扣 level/血量文字）、`Groups` 的 `FitName`（固定盒子
  `nameBoxW` 兜底）。旧的按字数截断（`Math:AbbrName` + `Math:Shorten`，2026-10-18 立的
  "玩家/目标 8 拉丁 10"那套）**停用**：设置（`nameCap`/`nameLength`/`truncate`）保留
  但不再读，改字号粒度能保住完整名字。

#### 小地图矩形化

形状只有一套（`/mui minimap diagnose` 报几何）：

| 画布 | 遮罩 | 可见区 | 机制 |
|------|------|--------|------|
| 256 × 256 | `Assets/Textures/minimap_rect_mask.tga` | 中间 190 高 | 画面不重绘，靠遮罩裁一条带出来 |

遮罩资源是**自绘**（`tools/regen-textures.js` 生成：上下各 33px 全透明、中间 190px 不透明，
四角按 6 UI 单位切出圆角，写完会把文件解码回来逐像素校验），`SetHitRectInsets` 同步收缩点击区。

**为什么用遮罩，而不是把画布直接设成 256×190**：非正方形 `SetSize` 在 WoW 里是把正方渲染
**拉伸**，不是"横向多看一圈" —— WoWInterface 老帖里把 184×88 的小地图调成矩形后地图被拉长、
草药点与实际位置对不上；同帖和 Reddit 的结论都是"矩形只能靠遮罩裁"；ElvUI-WindTools 的
`RectangleMinimap`（生产实现）也从不改画布、只换遮罩。那一档实测前就先删掉了（2026-10-21，
见变更记录）：与其留一条"可能纵向压扁 26%"的路，不如只维护一套不会变形的几何。

**这套做法的代价**：被裁的两条 33px 带子里什么都看不见。引擎 blip 画在 Minimap 自己的渲染里、
吃遮罩，不用管；第三方 pin（HBD）是独立 frame、不吃遮罩，落进带子会浮在面板外 —— 由
`Modules/Minimap/Pins.lua` 压掉（见下节）。

**客户端会把遮罩换回去**：`rotateMinimap` 一改，`MinimapClusterMixin:UpdateMinimapConfig`
（`Blizzard_Minimap/Camelot/Minimap.lua:31`）就会 `minimap:SetMaskTexture(圆形图集)` 并把
container / backdrop / compass 的尺寸设回默认。模块 `hooksecurefunc` 了这个方法，把重套皮排到
下一帧（不在客户端自己的调用栈里改帧）；`Restore()` 调它时用 `restoring` 旗跳过，战斗中走
`Queue("skin")`。`/mui minimap diagnose` 会报这个钩子是否装上了。

##### 遮罩带子里的第三方 pin（`Modules/Minimap/Pins.lua`）

`mask` 档的可见区只有中间 190 高，但 `HereBeDragons-Pins-2.0` 的 pin 是挂在 `Minimap` 上的
独立 frame，**不吃 Minimap 的遮罩**；HBD 按画布 256 算位置（`minimapHeight = GetHeight()/2 = 128`、
边界系数 0.9），所以 pin 会落在离中心 **95–115** 的地方 —— 正好浮在面板外。WindTools 的
`RectangleMinimap` 为此写了一整段补丁，我们按同一思路做了一版：

- 只在模块开着时生效；模块一关就把压下去的 alpha 全部放回去。
- `LibStub("HereBeDragons-Pins-2.0", true)` 取库，**没装 HBD 就整段空转**（不注册事件、不装钩子）。
- 发现 pin 两条路：hook 公开入口 `AddMinimapIcon{World,Map}`（新 pin 立刻接上）+ 扫一遍
  `minimapPins` / `activeMinimapPins`（已有 pin，以及 HBD 比我们晚加载的情况）。
- 判据用 pin 自己的锚点：HBD 锚成 `CENTER ← Minimap:CENTER`，`GetPoint(1)` 的 `offsetY` 就是
  离地图中心的距离；超过 `VisibleHalfHeight()`（95）就压 alpha，回到带子里按**压之前的原值**
  放回去（不是硬写 1）。读不到位置时保持原状，宁可多一个 pin，也不要一次读失败把 pin 全压掉。
- 压 alpha 而不是 `Hide()`：HBD 每次更新都先 `Show()` 再 `SetPoint()`，Hide 会被它推翻；
  同时 hook `SetPoint` / `Show` 重算、hook `SetAlpha` 挡住别的插件在带子里把它淡回来。
- `/mui minimap diagnose` 报 HBD 有没有接上、当前压掉几个 / 活动几个。

不做的：非 HBD 的自绘 pin（没有统一入口，只能各家各写）。

##### 客户端的 HybridMinimap（`Blizzard_HybridMinimap`）

不是第三方插件，是客户端自带的 LoD：在"没有小地图地表贴图"的地图里，`Blizzard_Minimap`
在 `PLAYER_ENTERING_WORLD` 里按 `C_Minimap.ShouldUseHybridMinimap()` 决定
`HybridMinimap_LoadUI()` + `HybridMinimap:Enable()`，之后小地图不再用引擎渲染，改用世界地图的
`MapCanvas` 平铺（`Blizzard_HybridMinimap.lua`：按 `C_Minimap.GetViewRadius()` 算缩放、
按 `C_Map.GetPlayerMapPosition` 跟人走，`SetDrawGroundTextures(false)`、
`SetIgnoreRotateMinimap(true)`）。

它跟我们打架的只有一块遮罩：XML 里 `HybridMinimap` 自带 `CircleMask`
（`TempPortraitAlphaMask`，锚在帧内缩 3），`OnLoad` 里 `MapCanvas:SetMaskTexture(self.CircleMask)`
—— 圆画在矩形面板里，四角会被啃掉。

做法照 BasicMinimap：**改 `CircleMask` 这块遮罩自己的贴图**，不另建一块 —— 同一个对象
同时罩着 `HybridMinimap.Background`（黑底）和 `MapCanvas`（地图美术），换一次两边一起变；
自建一块只套得住画布，地图画到边界外（站在地图边缘时）角上会露出面板。具体是：

- 换成 `minimap_rect_mask`；
- BasicMinimap 接受 XML 的"帧内缩 3"，我们把它临时 `SetAllPoints` 撑满整帧（可见带贴边），
  还原时按快照把贴图与锚点都放回去；
- 换完 `SetUseMaskTexture(false→true)` 抖一次，让画布把遮罩重新挂到贴图上（BasicMinimap 同款，
  只 `SetTexture` 有客户端不刷新的记录）。

- 它是按需加载的：`ADDON_LOADED` 里认 `Blizzard_HybridMinimap`，落地即接管；`Skin()` 每次再补
  一遍（形状切换、模块重开）。
- 不提供开关：跟皮肤一起进退；模块没开时客户端保留自己的圆形遮罩。
- 帧层级不用管：`HybridMinimap` 是 `BACKGROUND` / 固定 100、`setAllPoints` 到 `Minimap`，
  在面板之上、在小地图（`LOW`）和覆盖层之下；它的 `MapCanvas` 又不能点（`OnLoad` 里三个
  `SetShould*OnClick(false)` + 滚轮 NONE），所以左键打标记 / 滚轮缩放不受影响。
- `/mui minimap diagnose` 报它有没有加载、是不是被我们接管了。

**可见带必须自带圆角**：被裁掉的那 33 上 + 33 下，正是圆小地图时代"圆弧废料"所在的地方 ——
把画布裁成一条直上直下的矩形，四角就成了硬切口，圆形小地图的痕迹全丢。半径 4 在 256 宽的地图上
根本读不出来（看渲染图和看直切口没区别），所以用 6：读得出"圆角"，又不至于把地图啃成椭圆。
可见带距面板每边 4，面板边框（环宽 2）永远露在带外，这个半径只决定地图自己的角，不会碰面板的弧。
面板本体走 `Widget:Theme(panel, { thickness = 2 })`：直角 `SetBackdrop` 边框（圆角 9-slice 方案 2026-10-31 已删除）
，环宽 2 UI 单位。边框与地图四角都是方的，两者对齐。
面板对齐可见区下沿再往下 4：可见区是画布中间那条，不是画布本身。

**任务 / 考古 blob 的圆环要收掉**：暴雪给任务区域、考古点画的那圈 "blob ring" 是按圆画的，
套在矩形地图上会在蓝色任务区域里露出一圈圆形的"华夫饼"纹。模块激活时把
`Minimap:SetArchBlobRingScalar(0)` / `Minimap:SetQuestBlobRingScalar(0)` 归零
（Ellesmere 是 `isCircle and 1 or 0`，Andromeda 直接 0），关模块时按默认值 1 放回。
alpha 不动：环的尺寸已经是 0，没必要碰；手册里只有 `Set*` 没有 getter，所以还原值是 1
而不是快照。`SetTaskBlobRingScalar` 两家参考都没动，这里跟着不动。

预览图：`docs/mockup/layout-2560x1440.png`（源文件 `docs/mockup/layout-2560x1440.html`）。

##### 集群按钮接管（2026-10-20 补）

方形面板和暴雪原样按钮混在一起是最难看的地方，所以暴雪的集群按钮**逐项接管**：默认全部藏起来，
配置面板里每一项都能单独开回去。做法与 EllesmereUI 一致（见 `docs/MINIMAP-GAP-ANALYSIS-2026-10-19.md`）：

| 开关 | 对象（`_G` 找不到就跳过） | 说明 |
|------|------|------|
| `hideZoneText` | `MinimapCluster.ZoneTextButton` | 暴雪的区域文字（点击可开世界地图），我们自建一条 |
| `hideClock` | `TimeManagerClockButton` / `GameTimeFrame` | 时钟；本客户端两者都可能不在 |
| `hideMail` | `MinimapCluster.IndicatorFrame.MailFrame` | 新邮件角标 |
| `hideTracking` | `MinimapCluster.Tracking.Button` | 追踪按钮（`mapTracking` 开着时它被搬进地图，这项不再生效） |
| `hideZoom` | `…MinimapContainer.Minimap.ZoomIn/ZoomOut` | 缩放 +/− |
| `hideDifficulty` | `MiniMapInstanceDifficulty` | 副本难度 |
| `hideCrafting` | `…IndicatorFrame.CraftingOrderFrame` | 制造订单 |
| `hideLanding` | `ExpansionLandingPageMinimapButton` | 资料片着陆页 |
| `hideCompartment` | `AddonCompartmentFrame` | 插件收纳（`mapCompartment` 开着时它被搬进地图，这项不再生效） |
| `hidePromo` | `MinimapBackdrop.ExternalEventURLButton` | 活动链接 |
| `hideCompass` | `MinimapCompassTexture` 等贴图 | 罗盘与圆形底板（只压 alpha，不隐藏） |

关键细节：

- **罗盘只压 alpha，不隐藏**。暴雪的 `MinimapBackdrop` 是**父帧**，隐藏它会让
  `MinimapCompassTexture:GetRotation()` 停摆 —— 第三方战斗工具正是靠它读玩家朝向。
  所以贴图 `SetAlpha(0)`、父帧照常显示。
- **按钮会"复活"**：暴雪在换区域 / 过场 / 载入后会重新 `Show` 这些按钮，所以每个被藏的按钮都挂
  一次 `hooksecurefunc(btn, "Show")` 按回去。
- **战斗中 `Hide()` 会被无声拒绝**（连报错都没有），所以先记 `pending`，`PLAYER_REGEN_ENABLED` 补做。
- **方形四角是死区**：暴雪的 `Minimap` 命中区是圆的，方形皮肤下四角够不到。模块铺了一层与**可见区**
  等大的透明帧（`MonetUIMinimapOverlay`），滚轮缩放、悬停（区域名）、左键打标记都归它。
  打标记必须自己来：暴雪的 `MinimapMixin:OnClick` 只在点击落在**圆内**时才 `PingLocation`
  （那个判断是给圆形小地图写的），方形皮肤下四角会被判成"点在圆外"而什么也不做 —— 覆盖层照抄它
  那套坐标换算，自己调 `PingLocation`；同时把 `Minimap` 的 `OnMouseUp` 换成只放行中键的版本，
  免得暴雪那条路再打一次标记。
- **遮罩还原**：帧体没有"读遮罩"的接口，还原时优先请客户端自己设回去
  （`MinimapCluster:UpdateMinimapConfig()`，它知道自己的图集），退路才是 `ui-hud-minimap-frame-generic-mask`。
- **`GetMinimapShape` 本客户端根本没有**（手册与暴雪源码里都查不到），所以只在它真的存在时才覆写，
  免得凭空造一个没人读的全局；关闭模块时把原值放回去。它并非没人读：HBD 的 pin 代码会
  `minimap_shapes[GetMinimapShape()]`，`"SQUARE"` 让它按矩形边界算 pin。代价：可见地图只有
  256×190，落在被裁带子里的第三方 pin 会浮在面板外（引擎 blip 吃遮罩，不受影响；HBD 那一层见
  `TODO.md` "未决"）。

##### 地图内的三个按钮（`Modules/Minimap/Buttons.lua`）

| 按钮 | 位置 | 实现 |
|------|------|------|
| 追踪 | 内部左下 | **暴雪自己的** `MinimapCluster.Tracking.Button` 搬进来（菜单、追踪状态仍由客户端管） |
| 难度 | 内部左上 | 我们自建（这个客户端**没有**小地图难度框：`Camelot` 的 `CreateInstanceDifficultyFrame` 是故意留空的） |
| 插件收纳 | 内部右上 | **暴雪自己的** `AddonCompartmentFrame` 搬进来（插件列表仍由客户端管） |

- **图标是自绘的**（`tools/svg/monet_map_{tracking,compartment,difficulty}.svg`，Inkscape 手写矢量 →
  `tools/svg-to-tga.js` 导出），材质是**中性灰底 + 白色描边**的染色模具（运行期用顶点色染：
  追踪 / 收纳=主题边框色、难度=副本难度色 —— 史诗=危险色 / 英雄=资源色 / 普通=生命色，
  按 `GetInstanceInfo()` 的难度名判断）。
- **比例是宽:高 = 4:3（横长）**：材质画布 64×64（2 的幂，规范要求），**徽章本体占中间的 64×48**，
  运行时画成 20×20 → 徽章正好 20×15 = 4:3。徽章**就是材质本身**（描边 + 半透明底 + 符号都在贴图里），
  所以三个按钮的"框"是同一套材质；不再另铺一层 `Widget:Theme` 底板（那样会出现双层边框）。
  悬停时沿用本色只提亮 1.4 倍（难度徽章不能因为悬停就丢掉难度色）。
- **搬进来的代价**：`SetParent` / `SetSize` 在战斗里可能被无声拒绝，所以每次套用都重新摆一遍；
  关闭模块时按快照把父级、锚点、尺寸原样放回去。
- 难度牌子上挂个提示（难度名 + 人数），光一个盾牌色块看不出是哪个难度。

##### 区域名：悬停才显示

区域名不再占面板的标题条，而是**画在地图内部**（中间靠上，12px 像素字体 + 1px 阴影），
**鼠标悬停小地图时出现，移开就藏**。内容取自 `GetMinimapZoneText()`，退路是
`C_Map.GetBestMapForUnit` + `C_Map.GetMapInfo`；战区 / 冲突区域时按 `C_PvP.GetZonePVPInfo()`
染成危险色。没有自建时钟（时间仍走暴雪的开关项）。

##### 右键微型菜单（`Modules/Minimap/MicroMenu.lua`）

右键小地图**非按钮区**弹出一列游戏面板快捷入口（角色 / 法术 / 背包 / 任务 / 成就 / 好友 / 地图 /
日历 / 收藏 / 副本 / 设置），面板用统一的 Monet 材质（圆角平边框 + 像素字体）。

- 菜单**贴着地图左上角向左下展开**（地图本来就在屏幕右下角，往左展开一定完整可见，
  不用去猜鼠标屏幕坐标的换算）。
- 入口全部"存在才显示"：这些开关函数在暴雪代码里（API 手册没收），运行时探测 `_G`，
  客户端上缺哪个就不画哪一行。
- 右键本来是暴雪的"在地图上打标记"，所以模块把 `Minimap` 的 `OnMouseUp` 换成只放行中键的
  版本（还原时放回去），否则右键会一边弹菜单一边在地图上留下一个标记。

##### 配置项（`MonetUIDB.minimap`）

| 键 | 默认 | 说明 |
|----|------|------|
| `zoneText` | `true` | 悬停小地图时显示区域名（画在地图内部） |
| `zonePvPColor` | `true` | 战区时区域名染成危险色 |
| `scrollZoom` | `true` | 方形地图上滚轮缩放（上=放大，下=缩小） |
| `microMenu` | `true` | 右键小地图弹出微型游戏菜单 |
| `mapTracking` | `true` | 地图内的追踪按钮（左下） |
| `mapDifficulty` | `true` | 地图内的难度指示（左上） |
| `mapCompartment` | `true` | 地图内的插件收纳按钮（右上） |
| `border` | `2` | 面板边框粗细（1 / 2 / 3） |
| `gap` | `33` | 集群贴到屏幕右下角的间距 |
| `zoom` | `-1` | 记住的缩放级别（-1 = 没记过） |
| `hide*` | 全 `true` | 上表每一个集群按钮一个开关 |

`/mui minimap diagnose` 会逐条报这些帧名在本客户端存不存在。

### 动作条（ActionBars）

#### 主流做法：藏掉暴雪的条，自己在安全模板上画

Bartender4、Dominos、ElvUI、Andromeda 都是同一个套路：**不驱动暴雪自带的按钮**，而是
把默认动作条移出屏幕，自己在客户端的**安全模板**上新建按钮。原因很实际：

- 暴雪的按钮绑死在编辑模式（Edit Mode）、固定几何和它自己的翻页状态上，外面 `SetPoint` /
  `SetSize` 之后随时会被暴雪的排版改回去；
- `SecureActionButtonTemplate` 的按钮由客户端自己施法，战斗中不失效，也不会因为插件代码
  碰了它而"污染"（taint）暴雪 UI；
- 翻页（载具 / 覆盖 / 附身 / 变形 / 额外动作条）在安全环境里只换几个属性，Lua 完全不参与。

只有 Masque 这类纯美化插件会反其道而行：不建按钮，只给暴雪按钮换贴图。MonetUI 选前者。

#### 实现：完全自建（不依赖动作条库）

按钮直接用客户端的 **安全模板** 自建（`LibActionButton-1.0` 已于 2026-10-22 移除，
`Libs/` 下不再有它，`.toc` 里也没有了）。关键在客户端这一侧的两个机制：

- `SecureActionButtonTemplate` —— 按钮由**客户端**施法，战斗中不失效，插件碰它也不会污染暴雪 UI；
- `actionpage` 属性 —— 客户端按"页号"算槽位：`slot = GetID() + (page - 1) * 12`。
  翻页（载具 / 覆盖 / 附身 / 变形 / 额外动作条）只改这一个属性，Lua 完全不参与。

MonetUI 只写"怎么用"和"长什么样"：

| 关注点 | 做法 |
|--------|------|
| 头框体 | 每条条一个 `SecureHandlerStateTemplate` 框体，`_onstate-page` 片段把状态驱动算出的新页号写进条自己的 `actionpage` 属性 |
| 按钮 | `CreateFrame("CheckButton", 名字, 条, "SecureActionButtonTemplate", index)` —— 第 5 个参数就是 id；再设 `type=action`、`useparent-actionpage=true`、`RegisterForClicks("AnyUp","LeftButtonDown","RightButtonDown")` |
| 翻页 | `RegisterStateDriver(frame, "page", …)`；1 号条挂完整条件串（`[vehicleui]16;[overridebar]18;[shapeshift]17;[bonusbar:n]…`），2–8 号条挂**常量页号**（6/5/3/4/13/14/15） |
| 页号竞态 | 状态驱动每 0.2 秒才结算一次，事件和结算之间会差半拍，所以另有一个 0.2 秒的看门狗读 `actionpage`，变了就重画图标 |
| 显隐 | 1 号条 `[petbattle] hide; show`（同暴雪 MainActionBar）；2–8 号条在载具/覆盖/附身/变形/宠物对战时让位 |
| 按键 | 玩家的旧按键原样沿用：`ClearOverrideBindings` + `SetOverrideBindingClick(frame, false, key, 按钮名)`，键名从暴雪绑定名（`ACTIONBUTTON<i>`、`MULTIACTIONBAR1BUTTON<i>`…）反查；战斗中只打标记，`PLAYER_REGEN_ENABLED` 后再补 |
| 图标 | `C_ActionBar.GetActionTexture(slot)` → 文件 ID（**不是**秘密值），直接 `icon:SetTexture` |
| 冷却 | `C_ActionBar.RegisterActionUIButton(按钮, 槽位, 冷却框)` 把按钮与槽位登记给客户端，扫描与倒计时由客户端画（换页时先 Unregister 再 Register） |
| 数量 / 宏名 | `C_ActionBar.GetActionDisplayCount(slot)`（受限时是秘密值，拿不到就不显示）/ `C_ActionBar.GetActionText(slot)` |
| 外观 | 图标内缩 1px，露出的那一圈底色就是描边；暴雪的空槽方框/装备绿光/闪光/新技能提示全部不画；冷却、射程着色、自动施法光圈等仍由客户端驱动 |
| 字体 | 快捷键 / 数量 / 宏名都用像素字体（12px），快捷键缩写成 `s1` / `MU`；冷却数字走 `Widget:StyleCooldownText` |
| 下车按钮 | 自建一个（暴雪的下车按钮长在已被藏起来的主菜单条上），可见性交给 `[canexitvehicle]` / `[mounted]` 状态驱动，点击时飞行中请求提前落地、否则下车 |

冷却、堆叠数量、可用性着色、射程、拖放与 `UPDATE_BINDINGS` 都由客户端或事件驱动，
所以模块**没有轮询**（只有一个 0.2 秒的页号看门狗），只在主题或设置变化时刷一遍外观。

#### 宠物条 / 姿态条：接管，但不重画

这两条条不做自绘（重画要重新实现暴雪的一整套图标/自动施法/形态逻辑）。做法是：把暴雪的
`PetActionBarFrame`（外层容器，没有就退回 `PetActionBar`）/ `StanceBar` 从被藏起来的父框体里
**搬出来**、按 `buttonSize` **等比缩放**、放到存档里的位置，再把图标裁切与字体调成 MonetUI 的
样子。图标更新、自动施法光圈、当前形态环、冷却全部还是暴雪自己的代码在管，因此永远不会失同步。

> 搬的是**最外层**那个框体：暴雪显隐宠物的做法可能是 Hide 外层容器、也可能是 Hide 里面的条，
> 搬外层两种情况都还归它管；只搬内层的话，暴雪一 Hide 外层，我们的条就留在屏幕上了。

> 代价：暴雪在宠物变化、编辑模式换布局时会重排这两条条，MonetUI 只能在**战斗外**把它们放
> 回去（`PET_BAR_UPDATE` / `UNIT_PET` / `UPDATE_SHAPESHIFT_FORMS` 等事件 + `PLAYER_REGEN_ENABLED`
> 补做）。战斗中如果正好发生重排，位置会在战斗结束后恢复。

#### 暴雪框体：藏，不销毁

被收起来的是 `MainMenuBar`、`MultiBar*`、`OverrideActionBar`、`PossessActionBar` 以及背包条
（`BagsBar` / `MainMenuBarBackpackButton`）：`SetParent(隐藏框体)` + 保留事件。按钮本身仍在，
所以：

- 玩家的旧按键、宏、`/cast` 都不受影响；
- 自绘动作条万一建不出来（库缺失 / 安全模板缺失），模块会**放弃接管并打印提示**，暴雪的
  动作条原样回到屏幕上，而不是让玩家失去全部技能。

#### 配置项（`MonetUIDB.actionBars`）

| 键 | 默认 | 说明 |
|----|------|------|
| `ownBars` | `true` | 自绘 1–8 号动作条并接管宠物/姿态条；关掉就完全回到暴雪 |
| `hideBlizzard` | `true` | 隐藏暴雪默认动作条（`ownBars` 关掉时仍然生效） |
| `hideBagBar` | `true` | 隐藏暴雪背包条 |
| `barCount` | `3` | 显示几组动作条（1–8）；默认只显示 1/2/3 |
| `buttonSize` | `28` | 按钮边长 |
| `spacing` | `2` | 按钮间距 |
| `showHotkey` / `showCount` / `showMacro` | `true` | 快捷键 / 堆叠数量 / 宏名 |
| `positions` | `{}` | 按条覆盖 `BAR_DEFS` 里的首跑锚点（`point` / `relativeTo` / `relativePoint` / `x` / `y`） |

#### 已知限制

- **暂时不能拖动**。位置来自 `BAR_DEFS` 的首跑锚点：1/2/3 号条在底部居中往上叠，宠物条
  （右对齐）与姿态条（左对齐）占 3 号条上面那一行，4–8 号条继续往上叠（默认 `barCount = 3`，
  也就是默认只看到 1/2/3 加宠物/姿态）。想改就写
  `MonetUIDB.actionBars.positions["Bar2"] = { point = "BOTTOM", relativeTo = "Bar1",
  relativePoint = "TOP", x = 0, y = 2 }`。动作条上按钮全是安全按钮，把拖动做进按钮会
  抢掉"从条上拿起技能"的手感，所以拖动（含 `/mui` 里的解锁开关）留给下一版。
- 2–8 号条锚在 1 号条/其它条上，所以它们会跟着 1 号条走；这也是为什么拖动必须做在条框体上。
- 暴雪在**编辑模式**里会重新摆它自己的条，宠物条与姿态条的位置会在离开战斗后被我们抢回来。

### 姓名板（Nameplates）

#### 路线：站在暴雪姓名板之上，而不是另起炉灶

狂暴/ElvUI/Plater/Andromeda 的通用做法有两种：oUF 那套**自建整个姓名板框架**，或者像 ForeverUI 那样
**复用暴雪已经发下来的姓名板底座**。MonetUI 选后者，且不带 oUF：

- 客户端在世界上给每个有名字的单位发一个 **base 框体**（`C_NamePlate.GetNamePlateForUnit(unit)`）。
  这个框体负责**跟随单位、受击/血条位置、鼠标点击/选目标、软目标图标**等一整套逻辑；
- 模块把自绘的细条 `SetParent(base)` 并居中挂上去，再把 base 的子框体 `base.UnitFrame`
  （暴雪自己的那块板）`Hide` 掉——只隐藏，不销毁，随时可以还原；
- 于是定位、点击、单位进出视野全部还是暴雪在管，我们只管"长什么样"。

> 为什么不用 oUF：oUF 提供的是"从零搭一个单位框架"的骨架，而姓名板真正难的部分（底座定位、
> 点击、池化复用）客户端已经免费给了，自建等于把暴雪已经做好的部分再实现一遍。

#### 保密值安全（与 4.6 同一套规则）

姓名板在**战斗/PvP/Boss** 中正是最需要显示的时候，也正好是数值变成 `<secret>` 的时候。做法与单位框架一致：

| 数据 | 处理 |
|------|------|
| 血量 / 上限 | 原始值直接交给 `Secrets.SetBar`（控件接受 `<secret>`），血条照常填充；**百分比数字**先过 `Secrets.Number`，读不到就留空 |
| 施法名称 / 图标 | 直接 `FontString:SetText` / `Texture:SetTexture`（接受 `<secret>`） |
| 施法进度 | 一个只计算 `GetTime() * 1000`（我方普通数）的 OnUpdate 交给 `SetValue`，客户端拿它去和保密的首尾时间比对；**倒计时数字**只在结束时间可读时才生成 |
| 仇恨 | `UnitThreatSituation` 可能保密，过 `Secrets.Number`；读不到就保留主题色描边 |
| 等级 / 分类 / 名称 | `Secrets.Number` / `Secrets.IsSecret` 守卫；名称可保密时**整体显示不截断**（截断要读长度） |
| 减益光环 | **完全不读**：把 base 的 `UnitFrame.AurasFrame` 抢过来挂到自己的板上，游戏继续往里画 debuff（ForeverUI 技巧） |

`type(v) == "nil"` 在保密值上是合法且稳定的（返回底层类型），模块用它判断"是否正在施法"。
**绝不注册** `COMBAT_LOG_EVENT_UNFILTERED`；面板事件全部按单位用 `RegisterUnitEvent(event, "nameplateN")`
挂在板上，只有屏幕上的板才付出代价。

#### CVar 接管（谁能拿到姓名板）

"哪些单位有姓名板"是**客户端 CVar** 决定的，插件改不了，所以模块去**拨这些 CVar**，并在关闭模块时
**原样还回**（关掉时把每次读到的旧值逐个写回，不残留）：

| 配置项 | CVar |
|--------|------|
| `showFriendly` | `nameplateShowFriends` |
| `showEnemy` | `nameplateShowEnemies` |
| `showNPC` | `nameplateShowFriendlyNpcs` |
| `showMinor` | `nameplateShowEnemyMinus` |
| `showTotems` | `nameplateShowEnemyTotems` / `nameplateShowFriendlyTotems` |
| `showSelf` | `nameplateShowSelf` |
| `viewDistance` | `nameplateMaxDistance` |

`hideCritters` / `hideDead` 是在 CVar 之上**再加一层插件侧过滤**：被过滤掉的单位会把暴雪那块板
**还原回去**（见下），而不是留一块空地。

> 敌对/友方/友方 NPC 的分类不看 CVar，而是 `UnitIsFriend("player", unit)` + `UnitIsPlayer`：敌对的
> **玩家和 NPC 都归到 `showEnemy`**（否则"敌方开关"管不到怪物，只剩玩家）；友方 NPC 单独用
> `showNPC`（对应客户端的友好 NPC CVar）。

#### 点击区同步（`forcePlateSize`）

暴雪姓名板的**可点击区域**默认比一条细条大得多，还会和隔壁板的区域重叠——"看着点前面的板，实际选到
后面的单位"。模块在应用设置时把暴雪的框体尺寸**对齐到自己画的框**：

- **只用文档化的** `C_NamePlate.SetNamePlateSize`：`api_search` 实测该命名空间的 `siblings`
  只有 `GetNamePlateForUnit` / `GetNamePlateSize` / `GetNamePlates`，没有按阵营的 setter；
  而且本模块对所有板用的是**同一套宽高**，按阵营分设本就多余。曾参考其他插件看到
  `SetNamePlateEnemySize/FriendlySize`，**手册未收录**，且本模块对所有板用同一套宽高、本就用不上，
  已**从代码里删掉**；
- 首次接管前用 `GetNamePlateSize` 记下旧尺寸，关闭模块时还原；
- 战斗中 `InCombatLockdown()` 是受保护状态，改不了，先记 `sizePending`，`PLAYER_REGEN_ENABLED` 补做；
- hook `NamePlateDriverFrame.UpdateNamePlateOptions`（同样特性探测）——暴雪在设置/CVar 变化时会重排，
  重排后把我们的尺寸**再盖回去**。

#### 完整回退

关掉模块（配置面板勾选框或 `/mui Nameplates off`）是一次**真的交还**，不需要重载：

1. 每块板：`RestoreBlizzardPlate` 把 `UnitFrame` 显示回来、`AurasFrame` 的父级还给暴雪、
   再调一次 `ApplyFrameOptions` 让游戏自己重排；
2. 所有拨过的 CVar 写回旧值；
3. 姓名板点击区尺寸还原成接管前的值。

再次打开则从头应用（`Apply`），配置面板的每一项改完即时 `RefreshNameplates → M:Apply()`。

#### 配置项（`MonetUIDB.nameplates`）

| 键 | 默认 | 说明 |
|----|------|------|
| `showEnemy` / `showFriendly` / `showNPC` | `true` / `false` / `false` | 敌方（玩家+NPC）/ 友方玩家 / 友方 NPC |
| `showMinor` / `showTotems` / `showSelf` | `true` / `true` / `false` | minus 敌人 / 图腾 / 自己 |
| `hideCritters` / `hideDead` | `true` / `false` | 过滤小动物 / 死亡单位 |
| `viewDistance` | `60` | `nameplateMaxDistance` |
| `width` / `height` | `120` / `12` | 血条框尺寸 |
| `nameSize` | `10` | 名字/等级字号（2026-10-27 从 12 降到 10，暴雪名牌名是 9.6 号；百分比与施法文字小 1px） |
| `showName` / `showLevel` / `showPercent` | `true` | 名称 / 等级+精英标记 / 血量百分比 |
| `truncate` / `nameLength` | `true` / `16` | **已停用**（2026-10-28 起）：新规则走 `Widget:FitText` 的 70% 缩字（见 §四「单位框架 · 文字位置」名字显示条），设置保留只为收纳旧档 |
| `showCast` / `castHeight` | `true` / `13` | 施法条与高度（带图标） |
| `showThreat` / `highlightTarget` | `true` | 仇恨描边（红/橙）/ 当前目标描边高亮 |
| `showDebuffs` / `auraGap` | `true` / `4` | 借用暴雪减益列表与间距 |
| `classColor` | `true` | 职业/阵营着色（`UnitSelectionColor`，被抢的单位转灰） |
| `smooth` | `true` | 血条数值平滑过渡（同单位框架） |
| `forcePlateSize` | `true` | 把暴雪点击区对齐到绘制的框 |

#### 尚未覆盖（本版不做）

名字牌模式（只显示名字）、姓名板**堆叠/间距** CVar、目标板的职业资源、以及对姓名板的**拖动**
（板的位置由暴雪决定并始终贴着单位头顶）。

### 界面美化（Skins）

#### 为什么加这一层

在姓名板之前，MonetUI 只美化了"战斗 HUD"（单位框、动作条、背包、Buff、小地图、追踪），而玩家停留时间
最长的**暴雪原生窗口**（任务、世界地图、角色、收藏、社交、邮件/商贩/拍卖、弹窗/设置）依旧是原版外观 ——
于是整套 UI 风格是断的。这一层把那些窗口也拉进同一套 Monet 材质与配色。

参考实现（Andromeda / EllesmereUIBlizzardSkin / ElvUI Skins / ForeverUI）的做法分两种：

| 路线 | 代表 | 做法 |
|------|------|------|
| **皮肤引擎 + 逐窗口皮肤** | ElvUI（约 135 个文件）、Andromeda（三注册表 + 90+ 文件）、EllesmereUI（`WSkin.RegisterWindow` + 45 个 window pack） | 抹掉原画（`StripTextures`）→ 铺底（`CreateBackdrop`）+ 重做控件（`Handle*/Reskin*`）→ `hooksecurefunc` 追动态更新；颜色统一取一个调色中枢 |
| **只做 HUD，不碰暴雪窗口** | ForeverUI | 刻意不动世界地图 / 角色界面 / 任务日志，只把背包/聊天/小地图/冷却换皮 |

MonetUI 取两者之间：**做引擎 + 分窗口皮肤（ElvUI 路线）**，但**不复制任何一份 Andromeda/ElvUI 代码**，
且因为已经有 `Utils/Color.lua` + `Utils/Widget.lua` + `Utils/Media.lua` 这套统一底色，皮肤代码量远小于
ElvUI（它们要自己维持一套主题，我们只是接进去）。

#### 分层

```
Modules/Skins/Skins.lua      引擎：注册表 + 生命周期 + 完整回退 + 全局字体
Modules/Skins/*.lua          分窗口皮肤（Quest / WorldMap / Character / Collections / Social / Trade / System）
Utils/Skin.lua               皮肤原语（剥皮、底板、按钮/页签/滚动条/复选框/下拉/编辑框/图标、字体/着色）
```

- 每个窗口在文件加载时 `Skins:Panel(key, { group, label, apply, default })` 登记；`apply` 必须**幂等**。
- 引擎在 `PLAYER_LOGIN` 应用一次，`ADDON_LOADED`（暴雪窗口按需加载）与 `PLAYER_ENTERING_WORLD`
  （编辑模式/读条可能重建）各再应用一次；已在用的窗口因幂等而几乎零成本。
- `MONETUI_THEME_CHANGED` 时皮肤自己注册的"补色"闭包（`Skin:OnTheme`）与普通 `Widget:Theme` 一起刷新。

#### 与既有主题管线的关系（这就是"材质 / 色彩统一"）

皮肤**不新造一套配色**，而是复用现有管线：

1. 底板 / 边框一律 `Skin:Panel(frame)` → `Widget:Theme`，于是边框色相自动跟随
   `Color:GetBorderKey()`（配置面板「边框颜色」那一个下拉即可给**所有**窗口换框色）；
2. 文本一律 `Skin:Font` → `Media:Font` + `Widget:ColorText`，与其它模块同一字体、同一色槽；
3. 我们额外画的条/拇指/下划线（`Skin:OnTheme` 注册）同样读 `Color:GetBorder()`；
4. **语义色不动**：品质色、职业色、血/资源/危险色保持原样，只"Monet 化"底板/边框/页签/字体这些
   *chrome* —— 与 4.3 的"health / resource / danger 不做 Monet 化"一致。

#### 安全与可逆（对齐 ActionBars / Nameplates 的既有原则）

- **只改贴图，不动脚本/父级**：整层**从不**对暴雪框体 `SetScript` / `SetParent` / `SetShown` / `Hide`。
  剥皮只是把原画 `SetAlpha(0)`、底板是挂一个**属于我们自己的**子框体；暴雪按钮的悬停反馈用
  `HookScript`（保留原有脚本）实现。
- **可回滚**：每次对暴雪对象的改动都记一条还原闭包（`Skin:Record`），我们自建的框体只做显隐
  （`Skin:Track`）。关掉模块（`/mui Skins off` 或配置勾选框）时 `Skin:Rollback` + `HideAdded`
  **即时还原、无需重载**，再打开则重新应用。
- **不误伤图标**：剥皮只作用于**框体自身的区域**（`frame:GetRegions()`），不递归进子按钮；批量美化子按钮
  时用 `SkinButtonsIn`，**跳过带 `icon` 字段的物品按钮**（任务奖励、坐骑/宠物/幻化条目、动作技能行等）。
- **受限值无关**：这些窗口都在非战斗场景操作，皮肤本身不读任何单位数值，因此不新增保密值风险；
  仍然不注册任何受限事件。

#### 逐窗口开关

每个窗口是一个开关，存于 `MonetUIDB.skins.panels[key]`（缺省用各自登记时的 `default`）。窗口分组
（任务 / 地图 / 角色 / 收藏 / 社交 / 交易 / 系统）与开关一起呈现在配置面板「界面美化」一栏。**开启**
即时生效；**关闭**某一窗口后其暴雪原画要下次 `/reload` 才完全回来（与 ElvUI/Andromeda 的皮肤一致），
面板里有提示。

默认开启：任务日志、任务/对话窗口、世界地图、角色界面、观察、收藏、成就、冒险指南、好友/查询、社区、
公会、日历、邮箱、商贩、训练师、拍卖行、专业/制造、银行、拾取/掷骰、确认弹窗、游戏菜单、设置面板、
插件列表。默认关闭（较激进）：**下拉菜单**、**鼠标提示边框**。

#### 全局字体

`MonetUIDB.skins.font`（`off` / `pixel`）：开启后替换暴雪**共享字体对象**
（`GameFontNormal*` / `GameFontHighlight*` / `NumberFontNormal*` 等）的字体，让原生静态文本也统一到
像素字体。**默认 `pixel`**（全像素目标）：保留旧存档值 `roadway` / `number` / `combat` 会自动归一到
`pixel`。字体渲染统一走 `Media.fontFlags = "MONOCHROME"`（关抗锯齿、无 OUTLINE），字号经
`Media:SnapSize()` 吸附到 12px 网格（12 / 24）。**关闭需重载**（与逐窗口开关同理）。

#### 已知限制（本版不做 / 需游戏内调）

- 各暴雪窗口的**内部条目**（任务正文、奖励物品、列表行）刻意不动，所以它们仍是原版字体与间距；
  想让正文也统一，开「统一字体（全局）」。
- 暴雪窗口的**框架名 / 子控件名在不同版本会变**：皮肤全部经 `_G[name]` 取用并对缺失静默跳过，
  所以某版本缺了一个名字只会少美化那一个控件，不会报错 —— 代价是**静默失效**。
  这已不再靠猜：每个窗口把"期望存在的暴雪对象"登记在自己的 `frames` 清单里，
  **`/mui skins diagnose`** 逐条与当前客户端比对并打印 found/missing，
  按打印出的缺失名单一次性补名字即可（`/mui nameplates diagnose` 对本模块同理）。
  默认关闭的「统一字体」不隶属任何窗口，单独成组核对它那 25 个共享字体对象 ——
  否则名字错了要等玩家开了开关才发现"开了也没变化"。
  走 `module:HandleCommand(rest)` 通用转发，`Core` 不知道任何具体子命令。
- **下拉菜单**与**编辑模式（Edit Mode）**自带的弹层样式未覆盖。

### 信息栏（InfoBar）

贴**顶边**（可切到底边）的一整幅细条，默认高 14px，默认**悬停淡入**：
平时只露出 0.25 不透明度的底板，鼠标移上去文字才浮现（底板升到 0.5）、移开再淡出；
关掉「悬停淡入」则始终以 0.65 底板 + 全不透明文字常显。
进战斗时边缘按 `danger` 色呼吸闪烁，日历有**待处理邀请**时转黄；
宠物对战开启时整条隐藏。横条 `BACKGROUND` 层级（与本插件其它自建面板一致），
永远不会盖住游戏 UI —— 顶边默认位置也不会压到小地图（Minimap 模块已把它移到右下角）。

#### 6 个数据块（每个可单独开关）

| 块 | 显示 | 数据来源 | 本客户端实测 |
|----|------|----------|--------------|
| `gold` 金钱 | 当前金额；悬停显示本次会话收入 / 支出 / 净额；左键开角色面板 | `GetMoney` + `PLAYER_MONEY` | ✅ 但 **`GetMoneyString` 不存在** → 金额格式化在本插件内自己写 |
| `durability` 耐久 | 10 个可耐久槽位的平均百分比 | `GetInventoryItemDurability` + `UPDATE_INVENTORY_DURABILITY` | ⚠️ 手册写的是 `(slot)`，零售是 `(unit, slot)` → **运行期两种都试**，以不抛 Usage 错的为准，结果打印进 diagnose |
| `currency` 货币 | 背包里显示的货币（最多 2 种） | `C_CurrencyInfo.GetCurrencyListInfo` + `CURRENCY_DISPLAY_UPDATE` | ✅ 但零售的 `isWatched` 字段本客户端**没有**，改用 `CurrencyInfo.isShowInBackpack` 等价替代 |
| `system` 系统 | `延迟 · FPS · 插件内存`（每秒刷新，内存每 5 秒重算一次） | `GetNetStats` / `GetFramerate` / `C_AddOns.GetNumAddOns` + `GetAddOnMemoryUsage` | ✅ `GetNetStats` 第三个返回值是**数字**（不是列表）；计数与取名在 `C_AddOns` 命名空间下，**裸全局 `GetNumAddOns` / `GetAddOnName` 不是本客户端全局** |
| `spec` 专精 | 当前专精名；悬停列出全部专精与职责；左键开天赋/专精面板 | `C_SpecializationInfo.GetSpecialization` / `GetSpecializationInfo` | ✅ 命名空间从全局改到了 `C_SpecializationInfo.` |
| `friends` 好友 | 在线 / 总数；左键开好友列表 | `C_FriendList.GetNumFriends` / `GetNumOnlineFriends` + `FRIENDLIST_UPDATE` | ⚠️ 两个都标 `RequiresFriendList`，列表未加载时读作 0；**刻意不列具体好友名** —— 本客户端 `GetFriendInfo` 的参数是 name 而非零售的 index，猜不得 |

**取不到数据就把自己藏起来**：`SetText("")` 会隐藏该块并重新排版，
所以某个数据源在这台客户端上失效时，代价是**少一个数字**，而不是条上留一个空洞或打印一条错误。
整块 updater 抛错时只报一次（`block.reported`），不会每来一个事件刷一次屏。

#### 关键取舍

- **不用 `RegisterStateDriver`**（手册未收录）：宠物对战隐藏改用
  `PET_BATTLE_OPENING_START` / `PET_BATTLE_CLOSE` 两个事件显隐，效果等价。
- **悬停判定用「进入 / 离开计数」**：从条本体走到数据块会先触发条的 `OnLeave`，
  只看一次 OnLeave 会在光标明明还在条上时把整条淡出。
- **淡入与呼吸闪烁共用一个 `OnUpdate`**：文字 alpha、底板 alpha、闪烁相位三者驱动全部绘制，
  静止时 `SetScript("OnUpdate", nil)` 自动停表。
- **主题刷新后补回动画 alpha**：`Widget:RefreshThemes` 会按注册时的 `bgAlpha` 整体平铺，
  本模块的 `MONETUI_THEME_CHANGED` 监听在它之后（工具层文件期注册、模块登录期注册），
  负责把动画值重新盖上去。
- **打开暴雪面板一律 `_G[名字]` + `InCombatLockdown` + pcall**：
  `ToggleCharacter` / `ToggleFriends` / `ToggleTalentFrame` 都不在手册里，缺了只是点不动。
- **金额、延迟、帧率、耐久、货币数量、好友数全部先过 `Secrets.Number`**，读不到就留空。
- 块宽度**按文字自适应**（`GetStringWidth + 16`，下限 40），文字变了会立刻重新排版。

配置项在「信息栏」分组：贴边（顶/底）、高度（12/14/16/18）、悬停淡入、战斗呼吸闪烁、6 个块的开关。
模块开关与配置变更都**即时生效、无需重载**。

#### 自检

`/mui infobar diagnose` 打印三段：`PROBED` 里 20 个函数的存在 / 缺失、
耐久签名的实测结果（`slot` 还是 `unit, slot`，尚未探测时会说明怎么触发）、
以及 6 个块各自的状态（配置关闭 / 未构建 / 已隐藏无数据 / 显示中）与可见计数。
同样走 `module:HandleCommand(rest)` 通用转发。

### 字体资源

| 字体 | 文件 | 用途 | 来源 |
|------|------|------|------|
| 正文字体 | `Pingfangpixel.ttf` | 所有自绘文本 + 暴雪共享字体对象（全局统一字体开启时） | 点阵苹方（DynaComware），**无授权声明 / 不可再分发**；cmap 覆盖 20945/20992 CJK |
| 冷却字体 | `super-effective.ttf` | 动作条冷却计时数字（仅 ASCII 数字） | Super Effective（真·矩形轮廓像素字） |
| 备用 | `fusion-pixel-12.ttf` | 目前无引用（`Media.font.pixel` 已指向 PingFangPixel），回滚用 | Fusion Pixel Font 12px proportional zh-Hans，SIL OFL 1.1；覆盖 19317/20992 CJK |
| 遗留（无引用） | `roadway.ttf` | 保留作回滚，代码中已无任何引用 | 原随 Andromeda `assets/fonts/` 复制而来 |

> **全像素约定（2026-10-15 起）**
> - `fusion-pixel-12.ttf` 是真正的轮廓像素字（GDI+ 轮廓分析 0 贝塞尔点、纯矩形段），设计网格 =
>   em/12 → **字号为 12 的整数倍（12 / 24）才对齐网格**，所以全项目字号只用 12 和 24
>   （`Media:SnapSize()` 统一吸附）。
> - 渲染标志统一 `Media.fontFlags = "MONOCHROME"`：网格上无副作用，脱网格时把灰边压成硬阶跃；
>   **全项目不再使用 `OUTLINE`**（1px 描边会糊掉像素方块）。
> - 授权：OFL 全文见 `Assets/Fonts/OFL-FusionPixel.txt`，无 GPL 污染。
> - 字体路径在 `Utils/Media.lua` 里由 `ADDON_NAME` 拼出，因此**安装目录必须叫 `MonetUI`**。
> - 取证/预览页：`docs/font-pixel-test.html`（光栅放大对比各字体是否真像素）。

> **2026-10-26 回切：字库覆盖优先于「像素感」**
> - 玩家反馈 `fusion-pixel-12` 有□占位。实测 cmap：Fusion Pixel 只映射 19317/20992 个 CJK 码位
>   （缺 1675，生僻人名 / 物品 / 地名会掉方框），PingFangPixel 20945/20992。本插件自己渲染的
>   794 个非 ASCII 字符两种字体都齐 —— 掉方框的是**游戏数据**里的字。
> - `Media.font.pixel` / `pingfang` → `Assets/Fonts/Pingfangpixel.ttf`；`Media.fontFlags` 与
>   `Media.outlineFlags` → `"OUTLINE, MONOCHROME"`（1px 描边 + 关抗锯齿：描边和字身都是硬边）。
> - 代价：PingFangPixel 是矢量字（贝塞尔轮廓，内嵌点阵位图游戏不读），所以**不再是"像素字"**；
>   `Media:SnapSize()` 的 12 步长从"网格硬约束"退化成"字号一致性约定"，行为保留。
> - 授权债：PingFangPixel 无可分发授权，**公开发行前必须换回 OFL 字体**（见 `Assets/Fonts/NOTICE.md`）。

### 参考与致谢

MonetUI 的**代码与素材均为独立实现**：没有引入 oUF 等第三方框架，UI 控件、事件总线、
保密值处理、模块注册、拖动保存都是本项目自己写的。

以下第三方内容需要说明：

| 内容 | 说明 |
|------|------|
| 4 个字体文件（`Assets/Fonts/`） | 第三方字体；按**用户确认**不涉及版权问题，继续保留 |
| `Libs/LibActionButton-1.0/` | **BSD-3-Clause** 第三方库（作者 nevcairiel），取自 Andromeda 随包的 forever 适配版。MonetUI 只做了 3 处改动，全部标有 `MonetUI change:`：库名改为 `LibActionButton-1.0-MonetUI`、静态引用的 LibCustomGlow 改为标准 LibStub 查找、缺 CallbackHandler 时用内联空实现。BSD-3 与 GPL-3 不冲突（BSD 代码既可作为 GPL 项目的一部分，也可被独立项目使用），所以它不会把 MonetUI 拖进 GPL。许可原文见 `Libs/LibActionButton-1.0/LICENSE.txt` |
| 布局坐标与尺寸数值 | 参考 **Andromeda**（GPL-3.0）的 `modules/unitframe/unitframe.lua`、`gui/configs.lua` 与 `core/uiscale.lua`。布局思路与数字本身不受版权保护，且已按 MonetUI 的 1:1 坐标系重新取值（血条高度即取其实际厚度的约 50%） |
| 界面美化（Skins）思路 | 参考 **EllesmereUIBlizzardSkin**（window engine + 逐窗口 pack）、**Andromeda**（theme 注册表 + 逐面板 reskin）、**ElvUI Skins**（sink 注册 + `StripTextures`/backdrop）与 **ForeverUI**（刻意只做 HUD）。只借鉴**分层与接口用法**，Lua 全部独立实现，未拷贝任一份代码 |
| 信息栏（InfoBar）结构 | 参考 **Andromeda**（GPL-3.0）`modules/infobar/` 的**结构与取值**：一条贴边横条 + 按左右两侧累加偏移排布的数据块、默认高 14、悬停淡入的 0.25/0.5 与战斗闪烁。数据块的 API 选择、读取方式与全部实现代码为本项目独立编写（且该参考在本客户端本就不可用：`RegisterStateDriver`/`GetMoneyString`/`ToggleCharacter` 均不在本客户端手册内） |
| 动作条架构 | 参考 Andromeda（GPL-3.0）`modules/actionbar/` 的**结构与取值**：header + `_onstate-page` + `RegisterStateDriver` 的分工、每页 12 槽的编号方式、`fullPage` 条件串与各条固定页号、"重定位暴雪框体"而非销毁。这些是接口用法与配置值，不含 Andromeda 的代码 |
| 矩形遮罩（小地图） | 起初拷贝了 Andromeda 的 `rectangle-mask.blp`；现已**改为自绘**（`tools/regen-textures.js` 生成并逐像素自校验） |
| 自绘 UI 材质（24 组 TGA，另出 PNG 预览副本） | 全部由 `tools/regen-textures.js` 程序化绘制（node-canvas/Cairo 精确矢量），`docs/texture-preview.html` 网页预览；不含任何第三方位图。**两条铁律**（`audit-pixels.js` 强制）：① 透明像素 RGB 一律纯白衬底，永不用纯黑；② 染色模具（被 `SetVertexColor` / `SetBackdropBorderColor` 上色的 21 张）必须无色相 —— 引擎是相乘，`#fffcf6` 会让主题色蓝少 3.5%。仅 `brush_stroke`（奶油芯/赭金侧影）、`corner`、`close_hover`（hover 信号）、`win_maximize`（金色标题栏）四张刻意保留美术色 |

> Andromeda 以 **GPL-3.0** 发布，而 GPL 具有传染性：若 MonetUI 的分发中包含 Andromeda
> 受版权保护的**代码**，MonetUI 亦须以 GPL-3.0 发布并附源码。因此 MonetUI 的 Lua 全部独立
> 重写，只借鉴**布局思路、接口用法与数值**（不受版权保护），不含 Andromeda 的任何代码。
> 文件级的分发只有两类：4 个字体（已确认不涉及版权）与 BSD-3 的 `Libs/LibActionButton-1.0/`
> （按许可允许再分发，且与 GPL 不冲突）；小地图遮罩已换成自绘。

---

## 六、开发计划

### Phase 0: 框架搭建 ✅
- [x] 创建目录结构
- [x] 编写 Utils 层（Math/Secrets/Media/EventBus/Color/Widget）
- [x] 编写 Core.lua 核心入口
- [x] 编写 Config 配置框架
- [x] 编写各模块占位文件
- [x] 嵌入 LibStub 和 LibMonetColor
- [x] 修复 require 路径问题
- [x] Lua 5.1 兼容性检查
- [x] wuxian check 语法验证
- [ ] wuxian load 热加载验证（需游戏运行）

### Phase 1: 核心模块开发 ✅
- [x] UnitFrames 单位框架（P0）— 玩家/目标/焦点/宠物、保密值适配、拖动保存
- [x] UnitFrames 细条化（160/160/60/60 × 8，文字移至条上方，锚点照搬 Andromeda）
- [x] Cooldown 冷却计时（P0）— 数字/充能字体 + 技能状态着色
- [x] 与 MonetColor 联调（`Color:Refresh` + 区域变化刷新 + `OnThemeColorsChanged` 回调订阅，见 4.3）
- [ ] 游戏内验证（需游戏运行）

### Phase 2: 功能模块开发 ✅
- [x] BuffFrame（P1）
- [x] Minimap（P1）— 矩形化 256×190
- [x] BagFrame（P1）
- [x] QuestTracker（P2）
- [x] ActionBars（P2）— 1–8 号自绘动作条（LibActionButton-1.0）+ 接管宠物/姿态条 + 隐藏暴雪动作条与背包条
- [x] Nameplates（P2）— 暴雪底座 + 自绘细条、CVar 接管、借用暴雪减益、施法条、仇恨/目标描边、点击区同步
- [x] Skins（P2）— 界面美化：皮肤引擎（Utils/Skin.lua + Modules/Skins/）+ 分窗口皮肤（任务/地图/角色/收藏/社交/交易/系统）
- [ ] 游戏内视觉验收（需游戏运行）

### Phase 3: 完善与发布
- [x] 配置面板完善（绑定 MonetUIDB，实时生效）
- [x] 单位框架新增：能量条按类型分色、死亡/掉线变灰、数值平滑过渡（配置面板可选）
- [x] 单位框架新增：连击点小格（盗贼 / 德鲁伊）+ 「连击点（盗贼 / 德鲁伊）」配置下拉
- [x] 主题预留：所有边框经 `Widget:Theme` → `Color:GetBorder()`（色槽可选，配置项「边框颜色」），并订阅引擎 `OnThemeColorsChanged` 即时换色
- [ ] 游戏内视觉验收
- [ ] 压力测试
- [x] 文档编写（MonetUI.md）
- [ ] 发布 v1.0.0

---

## 七、验收标准

- [ ] 插件可在 WoW 中加载无报错 **（待游戏运行验证）**
- [x] 模块可独立开关（`/mui <模块> on|off` + 配置面板）
- [x] MonetColor 缺失时优雅降级（内置调色板）
- [x] 配置面板可保存设置（MonetUIDB）
- [ ] 内存占用 < 5MB
- [x] 代码无重复（通过 Utils 复用）
- [x] Lua 5.1 兼容（`wuxian check` 0 error / 1 intended warning：覆写 `GetMinimapShape`）
- [x] Forever 保密值安全（所有单位数值读取先查询 C_Secrets）
- [x] 不注册受限事件（无 CLEU）
- [x] 姓名板可完整回退（关闭模块 / 过滤单位：暴雪姓名板、CVar、点击区尺寸全部还原）
- [x] 界面美化（Skins）可逐窗口开关；关闭模块即时完整回退（暴雪原画 / 字体 / 底板全部还原，无需重载）

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
| 2026-10-15 | 跨文件共享改用插件 `ns` 命名空间 | .toc 文件返回值被丢弃，`return X` 方案是坏代码 |
| 2026-10-15 | 目标客户端 Interface = 16001 ("camelot") | 无限客户端 API 手册推算值 |
| 2026-10-15 | 全部单位数值访问走 Utils/Secrets.lua | 客户端在受限状态返回 `<secret>`，直接运算会报错 |
| 2026-10-15 | EventBus 改为按需注册事件 | 固定事件表会注册受限/未知事件导致报错；且绝不能注册 CLEU |
| 2026-10-15 | 使用现代命名空间 API（C_Spell/C_ActionBar/C_Container/C_UnitAuras） | 客户端手册中无 UnitAura/GetSpellInfo 等旧全局 |
| 2026-10-15 | 主动订阅 LibMonetColor 的 `OnThemeColorsChanged`（做注册形态探测：CallbackHandler / 内置回退两路都试、都 pcall） | 原决定因两种注册签名不一致而放弃回调；探测后两路都能接上，边框与血条可随引擎换色**即时**刷新；区域事件刷新保留为兜底 |
| 2026-10-15 | 接管暴雪框架采用 oUF 式 UnregisterAllEvents + Hide | 业界通行做法；配置项可关闭（`hideBlizzard`） |
| 2026-10-15 | 单位框细条化 = Andromeda 几何（血 4 / 能量 1 / 间隔 1 + 1px 边框） | 尺寸存入 `MonetUIDB.unitFrames`，方便后续微调 |
| 2026-10-15 | 单位框文字全部置于条上方 3px | 照搬 Andromeda tag 锚点（`BOTTOM*` → `TOP*`, 0, 3） |
| 2026-10-15 | focus 偏移改回 Andromeda 的 `-100` | 单位框已细条化到 60 宽，不再需要外推 |
| 2026-10-15 | 小地图矩形化用遮罩纹理（256×256 裁上下各 33px → 256×190） | 与 Andromeda 的 `rectangle-mask` 同法，保持圆形画布不动 |
| 2026-10-15 | 隐藏暴雪动作条/背包条用「重定位到隐藏父框」而非销毁 | 按键仍然可用，且不动 Blizzard 的动作条逻辑 |
| 2026-10-15 | 新增 targettarget 单位框（60×6，居中名字） | 照搬 Andromeda `Positions.tot` = target `RIGHT` +(6,0) |
| 2026-10-15 | 单位框拖动后按依赖顺序重排（player→target→targettarget） | 链式锚点（目标的的目标挂在目标上）也要跟随移动 |
| 2026-10-15 | 小地图去掉坐标与时钟 | 右下角位置紧凑，用户不需要这两项文本 |
| 2026-10-15 | 血条高度 4 → 2（= Andromeda 实际厚度的约 50%） | Andromeda 会 `UIParent:SetScale(clamp(768/屏幕高, .4, 1.15))`（1440p≈0.53），照抄 4 会厚近一倍 |
| 2026-10-15 | 血条着色 = 底层「损失」贴图 + 上层 StatusBar 填充 | 两层都不读单位数值，受限状态下着色依然正确（保密值安全） |
| 2026-10-15 | 玩家/宠物：当前=高亮、损失=黑；目标/焦点/目标的目标：当前=`UnitSelectionColor`、损失=danger | 一次调用即得职业色（玩家）/反应色（NPC），且不返回保密值，无需身份守卫 |
| 2026-10-15 | 血量数字按百分比 4 定点插值着色（绿→黄→橙→红） | 避免红绿直接线性插值经过脏褐色，对色盲也更友好 |
| 2026-10-15 | 新增 `SCHEMA` 迁移，默认值语义变化时显式覆盖旧存档 | `MergeDefaults` 只补缺失键，改了数值的老存档不会自动更新 |
| 2026-10-15 | 小地图遮罩改为自绘（`tools/make-minimap-mask.ps1`） | 去掉对 Andromeda `rectangle-mask.blp` 的文件级拷贝，规避 GPL 传染 |
| 2026-10-15 | 素材策略：只借鉴布局思路与数值，不做文件级拷贝 | Andromeda 为 GPL-3.0；小地图遮罩已自绘，4 个字体经确认不涉及版权 |
| 2026-10-15 | 字体文件保留（`Assets/Fonts/` 4 个） | 用户确认字体不涉及版权问题，无需替换 |
| 2026-10-15 | 血条/能量条用 `Enum.StatusBarInterpolation.ExponentialEaseOut` 平滑 | 插值在客户端内部完成（`SecretAspect.BarValue`），机密值同样可走平滑路径 |
| 2026-10-15 | 死亡/掉线用 `StatusBar:SetStatusBarDesaturated` 变灰 | 变灰由客户端完成（`SecretAspect.Desaturation`），不需要读数值 |
| 2026-10-15 | 能量条按 `UnitPowerType` 分色，自带 `POWER_COLOR` 表 | 旧实现依赖未文档化的全局 `PowerBarColor`；自建表可调且不产生全局依赖 |
| 2026-10-15 | 配置面板血条风格用**自绘下拉**，不用 `UIDropDownMenu`/`MenuUtil` | 暴雪菜单框架不在文档化 API 内且各版本不同；自绘可套用 Monet 主题、零模板依赖 |
| 2026-10-15 | 动作条走"藏掉暴雪、自建安全按钮"路线（Bartender4/Dominos/ElvUI/Andromeda 同路），只有 Masque 那种纯美化才去改暴雪按钮 | 暴雪按钮绑死编辑模式与自己的排版，外部改动会被改回；安全模板按钮由客户端施法，战斗中不失效 |
| 2026-10-15 | 按钮用**随包的 LibActionButton-1.0**（BSD-3）而不是自己手写 | 手写要覆盖拖放、冷却、堆叠、射程、可用性、按键、翻页等一大堆边界情况；BSD-3 与 GPL 不冲突，不会带来许可问题 |
| 2026-10-15 | 翻页放在安全环境里（header + `_onstate-page` + `RegisterStateDriver`），固定条挂常量页号 | 载具/覆盖/变形换页是客户端行为，Lua 插手既不安全也不及时 |
| 2026-10-15 | 按键用 `SetOverrideBindingClick` 指到自绘按钮，沿用暴雪的绑定名 | 玩家的旧按键设置零迁移；暴雪按钮仍在（只是藏起来），覆盖绑定优先，失效也只是回到暴雪行为 |
| 2026-10-15 | 宠物/姿态条**接管但不重画**（搬出父框体 + 等比缩放 + 裁图标） | 重画要重新实现暴雪的图标/自动施法/形态逻辑；只搬家则永远不失同步，代价是暴雪重排后要在战斗外放回去 |
| 2026-10-15 | 自绘动作条建不出来时**放弃接管并保留暴雪动作条**，同时打印提示 | 宁可不好看，也不能让玩家一下子失去全部技能 |
| 2026-10-15 | 堆叠数量的显隐自己管（`Count:Hide/Show`） | 库里对 Count 只 `SetText` 不控制显隐，配置项能随时开关而不需要重载 |
| 2026-10-15 | 快捷键缩写成 `s1` / `MU` 等（`SetText` 钩子 + `SetFormattedText` 回写） | 完整键名（如 `SHIFT-1`）会顶出 28px 按钮；用 `SetFormattedText` 回写可避开自我递归 |
| 2026-10-15 | 宠物/姿态条搬**最外层容器**（`PetActionBarFrame`，退回 `PetActionBar`） | 暴雪可能 Hide 外层也可能 Hide 内层；搬外层时两种做法都还归它管，不会留下一条"停尸"的宠物条 |
| 2026-10-15 | 动作条这一版**不做拖动**，位置交由默认锚点 + `positions` 覆盖 | 按钮都是安全按钮，把拖动挂到按钮上会抢掉"从条上拿起技能"；解锁模式（条框体留边、拖动条本身）留给下一版 |
| 2026-10-15 | 默认布局：`barCount = 3`，1/2/3 底部居中往上叠；宠物条右对齐、姿态条左对齐放在 3 号条上方那一行；4–8 号条继续往上叠但默认隐藏 | 玩家指定的布局：底部三条 + 宠物/姿态一行，其余按需往上加，不占屏幕 |
| 2026-10-15 | 盗贼/德鲁伊的连击点自己做（`CLASS_POWER` 表 + 一格一个 `StatusBar`），不接暴雪的 `PlayerFrame.classPowerBar` | 暴雪的连击点是 `PlayerFrame` 的**子框体**，`SuppressBlizzard` 一 Hide 父框体就一起消失；接暴雪显示等于被它的接管逻辑牵着走，自己画完全可控 |
| 2026-10-15 | 连击点用「一格一点的细条」而不是第二条能量条 | 连击点本身是**离散**资源：暴雪默认、Andromeda/oUF 的 ClassPower 都用点阵；细条表达不了「几点」 |
| 2026-10-15 | 每格 `StatusBar` 范围写 `(i-1, i)`，把原始点数直接交给 `SetValue` | 裁剪由客户端完成，我们不做比较/减法 —— 数值是 `<secret>` 时依然能正确点亮（见 4.6） |
| 2026-10-15 | 上限读不到时沿用上次格数（首次用职业默认值），不重排 | 机密值出现/消失时整排格子弹跳比格数略不准更糟 |
| 2026-10-15 | 死亡骑士符文与「充能连击点」高亮本版不做 | 符文是冷却驱动（参考实现读 `GetRuneCooldown`）且有血液/冰霜/邪恶分色；先把盗贼这类「点数型」资源做扎实，符文留给 P3 ResourceBars |
| 2026-10-15 | `CLASS_POWER` 只列盗贼与德鲁伊 | Forever 版本没有圣能/气/灵魂碎片/奥术充能/精华这些职业资源，写了也是死代码；表结构是通用的，该版本将来补了再加一行即可 |
| 2026-10-15 | 配置面板高度改为按内容自适应（`panel:SetHeight(math.abs(y) + 78)`），提示行改挂面板底部 | 行数只增不减，硬编码 800 已经装不下（最后几行与提示会跑到面板外） |
| 2026-10-15 | 边框颜色改为**可选引擎色槽**（`theme.borderKey`，默认 `edge`），`Widget:Theme` 支持 `borderKey` 按控件覆盖 | 预留「边框用哪个 MonetColor 色槽」的可能；集中成一个配置项，模块零改动即可整体换色；透明度仍取 edge 的，避免选 ambient 后边框淡到看不见 |
| 2026-10-15 | 姓名板挂在**暴雪姓名板底座**（`C_NamePlate.GetNamePlateForUnit`）上，不自建、不引入 oUF | 底座已经免费提供跟随/点击/选目标/软目标/池化复用；oUF 要重做这些，收益为负 |
| 2026-10-15 | 藏掉暴雪姓名板用 `UnitFrame:Hide()`，**不销毁** | 关闭模块或被过滤的单位要能原样还原（`ApplyFrameOptions` + 显示回来） |
| 2026-10-15 | 减益光环**借用暴雪**：把 `UnitFrame.AurasFrame` 重挂到自己板上，不读 `C_UnitAuras` | 受限状态下插件读不到光环，而暴雪自己的板仍能画；只借位置，不借数据（ForeverUI 技巧） |
| 2026-10-15 | "显示哪些单位"通过**拨客户端 CVar**（`nameplateShow*` / `nameplateMaxDistance`），并在关闭时原样写回 | 有没有姓名板是客户端决定，插件无法事后加板；记下旧值逐个还原，不残留 |
| 2026-10-15 | 敌对分类 = `UnitIsFriend("player", u)` 为假（**敌对玩家与敌对 NPC 都算**），友方 NPC 单独一档 | 只按 `UnitIsPlayer` 分会把"敌方开关"错配到友好 NPC，反而管不到怪物 |
| 2026-10-15 | 点击区尺寸**只用文档化的** `C_NamePlate.SetNamePlateSize`（特性探测 + pcall），并从代码里**删掉**曾从参考插件看来的 `SetNamePlateEnemySize/FriendlySize`；hook `NamePlateDriverFrame.UpdateNamePlateOptions` 重盖 | `api_search` 给出的 `siblings` 只有 `GetNamePlateForUnit/GetNamePlateSize/GetNamePlates`，**未收录**按阵营 setter；真正的原因是我们对所有板用同一套宽高，那两个本就用不上。注意手册并不完整（缺 `GetMoneyString`、`GetGuildInfo` 等常见 API），**"未收录"≠"不存在"**，所以结论靠的是"用不上"而非"不存在"。参考插件的对象不能当本客户端的依据 |
| 2026-10-15 | 战斗中不改点击区尺寸，记 `sizePending` 到 `PLAYER_REGEN_ENABLED` 补做 | `InCombatLockdown` 下改姓名板尺寸是受保护操作，会失败甚至报错 |
| 2026-10-15 | 施法条填充用**只算 `GetTime()*1000`** 的 OnUpdate 交给 `SetValue`，倒计时文字仅在结束时间可读时生成 | 填充的裁剪由客户端完成（保密值也可），文字要真算术，读不到就留空（见 4.6） |
| 2026-10-15 | 姓名板整体走 `Widget:Font/Bar/CreateFrame` + `Widget:Theme`，边框在 `MONETUI_THEME_CHANGED` 后按仇恨/目标重刷 | 与其它模块同一套主题管线；主题监听器先跑，模块后跑，同 tick 内边框覆盖胜出 |
| 2026-10-15 | 新增界面美化层 `Skins`：走"皮肤引擎 + 逐窗口皮肤"路线（ElvUI/Andromeda/Ellesmere 同路），而不是 ForeverUI 的"只做 HUD" | 玩家点名要统一任务/世界地图/角色等原生窗口；已有 Color/Widget/Media 底色，接入成本远低于 ElvUI |
| 2026-10-15 | 皮肤**只剥贴图、加自建子框体**，绝不对暴雪框体 `SetScript`/`SetParent`/`Hide` | 避免污染受保护 UI、保留编辑模式布局与暴雪脚本；与动作条"藏而不销毁"、姓名板"藏底座"同一克制原则 |
| 2026-10-15 | 每次改动暴雪对象都记**还原闭包**，自建框体只做显隐 | 模块关闭要能**即时完整回退、无需重载**（对齐姓名板的回退标准） |
| 2026-10-15 | 批量美化按钮时用 `icon` 字段**跳过物品按钮** | 剥皮会抹掉奖励/坐骑/幻化/技能图标；只挑 chrome 按钮重做 |
| 2026-10-15 | 皮肤复用 `Widget:Theme` + `Color:GetBorderKey()` + `Media:Font`，不新造主题 | 一个「边框颜色」下拉即可给所有窗口换框色 —— 这就是"材质/色彩统一" |
| 2026-10-15 | 全局字体替换（暴雪共享字体对象）默认**关闭**，做成显式选项 | 一次影响所有窗口文字，较激进；交给玩家选，且关闭需重载 |
| 2026-10-15 | 下拉菜单/提示边框默认关闭，菜单只染 backdrop 不剥皮 | 菜单背景靠 backdrop 而非区域贴图，剥皮会变透明；菜单框架是版本相关的非文档 API |
| 2026-10-15 | **参考插件的暴雪对象名与函数名一律不采信**：Skins 的窗口/控件名全部按现代暴雪 UI 自写，经 `_G[name]` 防御取用，取不到就静默跳过 | Andromeda 等参考是过期版本、在 Forever 上本就不工作；它的"正确对象"对我们没有约束力。名字错的代价是**静默失效**而非报错，所以更要在客户端上实测 —— 见下一行的 `diagnose` 自检 |
| 2026-10-15 | 新增 `ns.ResolvePath(path)` 共享探测 + 斜杠自检：`/mui skins diagnose` 逐条核对每个皮肤期望的暴雪对象，`/mui nameplates diagnose` 同理 | 把"名字可能不对"从担忧变成可执行的事实清单：打印 found/missing 一次，缺的名字照单补即可。斜杠命令走 `module:HandleCommand(rest)` 通用转发，不给 `Core` 加硬编码分支 |
| 2026-10-15 | 手册优先于参考插件：新用到的 API 先 `api_search`/`api_get` 核对（含 `siblings` 成员表与 `SecretArguments` 限制），拿不准就留特性探测 + pcall，最后用 `diagnose` 在真机上验 | `wuxian check` 的 `api-unknown` warning 就是这类"抄来的名字"的报警器，据此清零了姓名板 8 处。**但手册本身不完整**（`GetMoneyString`/`GetGuildInfo`/`RegisterStateDriver` 等常见 API 都查不到），所以"手册没有"只是一条弱证据，落点必须是真机探测 |
| 2026-10-15 | 新增信息栏 `InfoBar`，沿用"引擎层 + 数据块层"结构（`InfoBar.lua` 容器/排版/动画/自检，`Blocks.lua` 按 key 注册 6 个块） | 与 Skins 的"引擎 + 分窗口"同构：块可单独开关，某个数据源失效只塌自己，不牵连整条 |
| 2026-10-15 | 信息栏**不使用 `RegisterStateDriver`**，宠物对战隐藏改用 `PET_BATTLE_OPENING_START` / `PET_BATTLE_CLOSE` 事件 | 手册未收录 `RegisterStateDriver`；事件方案在任何客户端都成立，不需要"状态驱动"这层间接 |
| 2026-10-15 | 数据块**取不到数据就自隐藏**（`SetText("")` → 隐藏该块 + 重排版），整块 updater 抛错只报一次 | 这台客户端"手册没有 / 参数不同"已被反复证实；宁可少显示一个数字，也不要在条上留空洞、更不能刷屏报错 |
| 2026-10-15 | 耐久签名**运行期探测**：先 `pcall(fn, slot)`，不抛 Usage 错就用，否则再试 `pcall(fn, "player", slot)` | 手册写 `(slot)`、零售是 `(unit, slot)`，而"参数"正是参考插件最不可信的部分；抛错而不是返回 nil，是这次能靠 pcall 判定的**前提**，结论打印进 diagnose |
| 2026-10-15 | 货币的"已跟踪"标记用 `CurrencyInfo.isShowInBackpack`，不做零售的 `isWatched` | 本客户端 `CurrencyInfo` 结构里没有 `isWatched` 字段；`isShowInBackpack`（背包栏旁显示的那种货币）语义等价 |
| 2026-10-15 | 插件内存自己累加（`C_AddOns.GetNumAddOns` + `GetAddOnName` + `GetAddOnMemoryUsage`），没有合计接口就不假装有 | 没有"总内存"API。**更要紧的是计数与取名都在 `C_AddOns` 命名空间**：裸全局 `GetNumAddOns`/`GetAddOnName` 不是本客户端全局，是 `wuxian check` 的 `moved` 警告抓出来的 |
| 2026-10-15 | **`api_get` 会静默模糊匹配，不能当"这个名字可用"的证据**；改名的全局以 `wuxian check` 的 `moved` 警告为准 | 查 `GetNumAddOns` 得到 `FOUND`，实际对应的是 `C_AddOns.GetNumAddOns` —— 两条工具链各覆盖一半，缺一就会把"换过名的全局"当成"没换名" |
| 2026-10-15 | 信息栏默认贴顶边、默认**悬停淡入**；悬停判定用「进入/离开计数」而不是单次 `OnLeave` | 顶边避开底部动作条（Minimap 模块已把小地图移到右下角，顶边整条是空的）。条本体与数据块之间移动时父 `OnLeave` 会先于子 `OnEnter`，单次判定会把光标仍在条上的整条误淡出 |
| 2026-10-16 | 自绘 UI 材质 21 组：GDI+ **精确矢量**（零抖动）+ 奶白芯/赭金侧影双色；TGA 给游戏、PNG 给预览页，同一生成器输出并 MD5 自校验 | 游戏不认 PNG；双色侧影让任何主题色乘上去都比芯暗一档，染到哪个色槽都和谐。大糊光晕已全部去除，辨识度靠剪影与侧影 |
| 2026-10-16 | 关闭钮/勾选框接入自绘贴图走 `Skin:SwapArt`（记原 atlas/路径/texcoord/alpha 供回滚），`Skin:Fade` 跳过 `__monetArt`；世界地图与拾取窗的关闭钮从 `Skin:Button` 名单移除改走 `Skin:CloseButton` | 关钮此前被文字钮皮肤淡成空底板（无 ✕）；SwapArt 统一"换图 + 可回滚 + 幂等"，后续窗口控件接线复用同一条路 |
| 2026-10-16 | 状态条填充默认改 `monet_barfill`（纵向白渐变：顶亮底沉），姓名板两处显式引用同步；旧 `statusbar` 键保留作后备 | 渐变是相对量，乘任何职业色/主题色都保留体积感；2px 细条与 12px 姓名板同样成立 |
| 2026-10-16 | `Skin:Track` 只在 `recording` 期间登记 | 建给暴雪窗口的子板随皮肤模块隐藏/恢复；自家配置面板的不在回滚表里，模块关掉它也不塌 |
| 2026-10-16 | 全字体切换到 **Fusion Pixel 12px**（`fusion-pixel-12.ttf`，SIL OFL 1.1，随包 `Assets/Fonts/OFL-FusionPixel.txt`）；删除 `combat.ttf`（全项目零引用），`Pingfangpixel` / `roadway` 留盘作回滚但代码不再引用 | 取证结论（`docs/font-pixel-test.html` + GDI+ 轮廓分析）：PingFang Pixel 的 `glyf` 是平滑贝塞尔+斜线段、内嵌 `bdat/bloc` 位图渲染器游戏不读 → 进游戏渲染并不像素；Fusion Pixel 轮廓 **0 贝塞尔点、纯矩形段**，是真像素字 |
| 2026-10-16 | 字号统一吸附 12px 网格（`Media:SnapSize()`，全项目只用 12 / 24），姓名板字号下拉随之移除 | Fusion Pixel 设计网格 = em/12，只有 12 的整数倍才让一个设计像素 = 一个屏幕像素；字号选项在网格约束下全部渲染成 12，留着是骗人的控件 |
| 2026-10-16 | 渲染标志统一 `Media.fontFlags = "MONOCHROME"`，全项目移除 `OUTLINE` | MONOCHROME 关抗锯齿：网格上无副作用，脱网格时把灰边压成硬阶跃（比描边更像像素）；1px 描边会把像素方块糊成一片 |
| 2026-10-26 | **回切正文到 `Pingfangpixel.ttf`**，`Media.fontFlags` / `outlineFlags` 改 `"OUTLINE, MONOCHROME"`（1px 描边 + 关抗锯齿）；`fusion-pixel-12` 降为备用 | 字库覆盖优先：Fusion Pixel 缺 1675 个 CJK 码位（游戏数据里的生僻字掉□），PingFangPixel 只缺 47 个；代价是不再是"像素字"，所以用 OUTLINE 保住 12px 下的可读性。授权债记在 `Assets/Fonts/NOTICE.md`：公开发行前必须换 OFL 字体 |
| 2026-10-16 | `skins.font` 默认 `off` → `pixel`，下拉只剩「关闭 / 像素字体」，旧存档 `roadway`/`number`/`combat` 经 `GetFontKey` 归一到 pixel | 全像素目标下默认值决定暴雪窗口是否也是像素字；Blizzard 共享字体对象**保留原生字号不吸附**（它们的排版绑死字号），只换字体与标志 |
| 2026-10-17 | 冷却倒计时改由插件自绘文字：单位自动缩放（复用 `Math:DurationText`，≥60s→分、≥1h→时、≥24h→天，与光环时长同格式器），剩余 ≤ 紧急阈值（默认 5 秒，面板可调 3/5/8/10）时 danger 红 + 字号 12→18（并以按钮宽度 60% 封顶防溢出）；`hooksecurefunc` 挂 Cooldown 控件共享方法表的 `SetCooldown`（捕获到期时间）与 `SetHideCountdownNumbers`（记录外部显隐意图），另有 0.5s 轮询接管"没看到起点"的冷却 | `SetCooldown` 参数与 `GetCooldownTimes` 在受限状态是**机密值**，插件不能对它做算术；但已捕获的到期时间是普通数、`GetTime` 也普通 → "脱战开的冷却进战后照常走我们的格式"，只有战斗中新开的技能降级回暴雪自己的数字——宁可降级也不猜数 |
| 2026-10-17 | 冷却文字画在 cooldown 的**子框体**里而不是 region；模块开关/面板改动走 `ApplyDisplay()` 立即重绘；动作条两处样式调用改走 `Cooldown:StyleCooldown`，模块缺席时退回原 `StyleCooldownText` | 子框体避开 `Widget:StyleCooldownText` 重刷（会把字号刷回 12、颜色刷回白色，与紧急放大打架）；共享方法表让暴雪按钮与 LibActionButton 按钮同一条路，`ActionButton1Cooldown` 缺席时用探测帧兜底装钩 |
| 2026-10-17 | Buff/Debuff 改**行宽预算制**：增益 28px、减益 36px（减益明显更大），每行个数由 316px 行宽预算反推（`PerRow(size)`，不写死），满行时增益行（10×32−4）与减益行（8×40−4）**宽度严格相等 316px** | 旧实现是 34px + 每行 8 个的死网格，两种尺寸没法共存；316 是 32 与 40 的公倍数减 4，让"减益更大 + 满行右缘对齐"两个诉求同时成立，且全是整数像素不破 12px 网格的下缘 |
| 2026-10-18 | 材质包只装 TGA：删掉 `Assets/Textures` 下 24 个 `.png` 副本（素材目录 750 KB → 373 KB），生成器改成把 PNG 写到 gitignore 的 `docs/texture-preview/`，预览页与设计稿的贴图 URL 跟着改 | 游戏不读 PNG，一份图标存两份只是让插件包白白大一倍。PNG 仍要生成：浏览器解不了 TGA，`docs/texture-preview.html` 和设计稿的 CSS 背景都靠它，自校验的 PNG 往返抽查也依赖它 —— 但它是构建产物，不该进仓库也不该进包 |
| 2026-10-18 | 材质改名对齐规范：`monet-*` 连字符 → `monet_*` 下划线（25 个 .tga / 24 个 .png 同步改名），生成器 id、`Utils/Media.lua` 的贴图键与路径、设计稿里真实引用的贴图 URL、文档全部跟着改 | 对齐"小写下划线"的材质命名规范。改名会改变生成器里程序化笔触的随机种子（种子含名字长度），三个纹理类材质（brush-stroke / canvas-weave / diagonal-weave）的斑驳会重排一次，字形与几何不变；Media 键名与磁盘文件已交叉校验，无悬空引用 |
| 2026-10-18 | 落地边框划分与几处文本/锚点约定：信息条描边 1→2 物理 px；光环图标内缩 `Media:Mult()` 让 1px 描边露出（冷却滑动同步内缩）；单位框名字改为「缩写 + 截断」；任务追踪宽 256→264（对齐小地图面板）并默认锚在面板右上角 | 描边划分照设计稿（单位框/光环/动作条 1px，信息条/小地图/任务追踪 2px；聊天框保持 2px）。名字截断取 Andromeda 的 name tag 数值：先 `AbbrNameString` 后 `ShortenString`，按字符而非字节（否则切半个汉字），中文 8/5、拉丁 10/8；名字保密时整段跳过（截断要读长度，与 Nameplates 同一约定）。任务追踪用两个锚点（`RIGHT` 跟面板、`TOP` 钉屏幕）而不是单个 `TOPRIGHT`：小地图缩放/移动时右边缘跟着走，顶部仍与 buff 容器同高（33 = `AURA_GAP`） |
| 2026-10-18 | 小地图遮罩改为**圆角**（半径 4 UI 单位），并新增自绘九宫格边纹 `monet_round_edge`：`Widget:Theme` 增加 `round = true`，小地图面板与任务追踪窗口改用"画出来的圆角边框" | 设计稿里这两处要做成小圆弧角。半径 4 不是审美值：边纹（外弧 3、环宽 2）的内沿只剩半径 1，而地图离面板边 4 UI 单位，半径 4 刚好切掉会被弧盖住的 3 个像素、不吃地图内容。任务追踪**没用**遮罩：遮罩按帧尺寸 1:1 作用、半径会随窗口高度拉伸，九宫格边纹才是四角切片 + 四边拉伸，窗口长多高都对 |
| 2026-10-18 | 材质生成器从 PowerShell GDI+ **迁移到 `tools/regen-textures.js`（@napi-rs/canvas / Cairo）**，25 张 TGA 全量重生并替换；旧脚本归档到 `tools/deprecated/` | 旧 GDI+ 逐像素脚本有线条不直、圆弧不圆、宽度不准的老问题；Cairo 是亚像素精度矢量渲染，线宽与圆弧是数学级精确。`@napi-rs/canvas` 自带预编译二进制，无需 node-gyp 编译链（`canvas` 包在本机安装超时）。输出统一走同一份 TGA 写入器与规范校验 |
| 2026-10-18 | TGA 写入器 descriptor 固定 **`0x08`（8 位 alpha + BOTTOM-LEFT origin）并保留行翻转**，与项目既有 24 个文件一致 | 迁移初版写成 `0x20`（TOP-LEFT）却又翻转了行数据，双重否定导致整幅图上下颠倒 —— 现象是 chevron 上下反、check 看着要"180° 翻转"、corner 跑到左下角。根因是一个 bug 而不是几何错误。旧文件实测全是 `0x08`，新生成器必须同约定，否则客户端与预览页读出的朝向不一致 |
| 2026-10-18 | 线宽规范收敛为常量：`LINE_WIDTH.icon = 2px`（图标/勾/X/箭头/窗口控件）、`plusMinus = 4px`、`border = 1px`；`monet_corner` 改为 **16×16、1px 线宽、半径 4** | 对齐 Andromeda 实测：`button-circle-border` 64×64 约 2px、`statusbar-stripes-thin` 1px、`ui-checkbox-tick` 约 2px。corner 原 64×64 画布上画 2px 弧，缩到 16px 显示后不足 1px 几乎不可见；16×16 画布 1:1 映射才能看清。弧线端点必须精确贴 `(0, s/2)` 与 `(s/2, 0)`，四角靠 `SetTexCoord` 镜像 |
| 2026-10-18 | `minimap_rect_mask` 重写为**正确的 alpha 遮罩**：256×256 画布、中间 190px 全不透明（y 33–222）、上下各 33px alpha=0、可见四角圆角 4；不是径向渐变 | 初版误画成径向渐变压暗边缘，而 `SetMaskTexture` 读的是 alpha 通道 —— 方形遮罩无法裁出矩形。Andromeda 的 BLP 实测 `width=256 height=256`，矩形是靠"中间 190px 不透明带 + 上下透明"实现的，代码里 `holder 256×190` + `SetHitRectInsets(0,0,33,33)` 与之配套。像素验证：可见行恰为 `y[33,222]` = 190px，边界 alpha 0/255 精确切换 |
| 2026-10-18 | 补回旧脚本的 `Fill-TransparentRgb`：`saveTGA` 写入前先算不透明像素平均 RGB，把所有 alpha=0 像素的 RGB 填成该值 | 迁移时漏了这一步，逐像素审计发现 22 个文件的透明区全是纯黑 (0,0,0)，违反材质规范。客户端生成 mip / 双线性过滤时会把黑色拖进可见边缘，64px 图标缩到 16–22px 时最明显。修复后重跑"无纯黑透明像素"审计：0 个 |
| 2026-10-19 | `monet_round_edge` 改回 **2px 满 alpha 环**：`lineWidth = 2`、中心线圆角半径 2（外弧 = 3）、中心线整体内缩 `lineWidth/2` | 迁移初版把中心线压在画布边界上且只画 1px，笔触有一半在外面被裁掉 —— 直边实测只有 128 alpha（50%）而四角是 255，同一根边框一半亮一半暗。几何必须对上 `Widget.lua` 的两个常量：`ROUND_INSET = 2` 决定环宽（环画在内侧会被 2px insets 的背景整个盖掉），`ROUND_SLICE = 3` 决定外弧半径（必须完整落在 9-slice 采样的最外 3×3 角块内）。修复后直边 max alpha = 255 |
| 2026-10-19 | `monet_corner` 圆弧圆心从 `(radius - lw/2)` 移到 `(radius)`，两端不再有笔触被画布边界裁掉 | 圆弧两端原本正好压在 x=0 / y=0 上，butt 端帽有一半在画布外，端点只剩 50% alpha（128），四个镜像角会出现"弧尖发虚"。现在笔触横截面完整落在像素内，bbox 仍是 x[0,3] y[0,3] |
| 2026-10-19 | 新增 `tools/make-review-sheet.js`：解码全部 TGA，按整数倍最近邻铺成 contact sheet（深色 / 浅色 / 棋盘三张）；配套 `tools/tga-dump.js`（单张 ASCII 像素转储，`--bak` 读旧稿、`--rgb` 看颜色、`--cross` 看中线剖面） | 对比页只适合"新旧二选一"，看不出线宽和抗锯齿质量。contact sheet 一屏看完 25 张：棋盘底看 alpha 边缘、深色底看实际观感。`tga-dump` 的 `--cross` 尤其关键 —— 材质被非等比拉伸时，整图看不出问题，剖面一眼就露馅（旧稿 barfill 的黑、织纹没孔，都是剖面/统计查出来的，不是看图看出来的） |
| 2026-10-19 | `monet_barfill` 重画为**整幅不透明的近白渐变**（255 → 209），删掉原来的 `rgba(0,0,0,...)` 停靠点 | 迁移初版底部那个黑停靠点是错的：这个材质同时走 ADD（ButtonMaterial / Skin 滑块 / 动作条，`SetVertexColor` 的 alpha 在 ADD 下等于不透明度）和普通 alpha 混合（姓名板血条/施法条、`Widget:Bar`）。在透明底上"颜色自身的不透明度"乘出来是**不透明黑** —— 实测 16 行里第 8–15 行 RGB 全是 (0,0,0)，即姓名板血条下半条直接画成黑色。ADD 下 RGB=0 只是"不发光"，两种混合的结论完全不同，所以这个材质不能有黑 |
| 2026-10-19 | `monet_brush_stroke` 的赭金侧影改成**按每列半厚度比例上色**（两侧 30% 赭金、中间奶白芯），不再用 1px 描边 | `Widget:Rule` 拿 256×32 的画布只画 9px 高，纵向只剩 ~0.28 倍。1px 描边缩完是 0.28px，等于没有 —— 实测两侧的黄几乎看不见，而 docstring 承诺的是"cream-core / ochre-rim two-tone"。改成比例上色后，画布压到多矮双色关系都不变。顺带把两端从 4.8px 收到 1.1px，spindle 才真的"尖细" |
| 2026-10-19 | 两种织纹重画：线宽必须**小于垂直间距的一半**，孔才算存在 | 迁移初版 `diagonal_weave` 线宽 = size×0.08 配步距 size/8 —— 斜线的垂直间距是 `step/√2` 不是 `step`，实际单方向覆盖率 90%，两方向叠完 **4096 个像素一个透明的都没有**：织纹的"孔"没了，铺在按钮上是一层均匀白膜。`canvas_weave` 同理（步距 4px / 线宽 2.56px）。现在 canvas 步距 8 线宽 2（56% 透明）、diagonal 线宽 = step/√2/2（12.5% 透明），孔回来了 |
| 2026-10-19 | role 三图标改成**近白芯 + 语义色侧影**（tank 钢蓝 `#4a7fb5` / heal 苔绿 `#5aa06a` / dps 砖红 `#c05a4a`），用径向渐变而非描边 | `Utils/Media.lua` 一直写着"三张 role 图标带语义色、禁止 `SetVertexColor`"，但生成器一直画成纯近白 —— 注释与实现矛盾，且因为禁止染色，这批图标既没有语义色也染不出来。描边方案在 64px 图标上只有 2px 宽，缩到实际显示的 16–22px 后看不出色相，所以用径向渐变让色相铺满整个面。色相取低饱和"颜料色"而非 UI 纯 RGB：整套 Monet 是奶白+赭金的古典调，纯蓝绿红会像贴上去的图钉 |
| 2026-10-19 | `monet_role_heal` 重画为**杆 + 正弦蛇**，砍掉翅膀 | 原来的"权杖 + S 形蛇 + 一对翅膀"全是同样粗细的 2px 线，缩到 16–22px 后糊成一个伸手的小人；去掉翅膀后用 bezier 拧出的两个钩子又像"挂着两个钩子的棍子"。改用等间距采样正弦（横穿竖杆两次）+ 蛇粗过杆，缩到小尺寸仍认得出是缠绕的蛇 |
| 2026-10-19 | **横向装饰的分工定死**：`monet_brush_stroke`（手绘笔触）只用于 `Modules/Bags/Bags.lua:317` 的背包分类窗口标题下划线，**不再扩展到别处**；所有"分隔线"需求一律走 `monet_hairline` + `Widget:Hairline` | 两种材质解决的是不同问题：笔触是**装饰**（有奶白芯 + 赭金侧影、有两端 taper，一眼就要看出是手绘的），发丝线是**结构**（1px、无起伏、安静）。让笔触去干分隔的活会在信息栏那种窄条区域显得吵，而且它两端的 taper 会让分隔看起来像没画完；反过来让发丝线当装饰则寡淡无味。`Widget:Rule` 已经通用化（`frame`/`anchor` 都是参数 + `__monetRule` 幂等），但"能用"不等于"该用" |
| 2026-10-19 | **姓名板 debuff 图标改用 B1**：`DressDebuffButton` / `DressDebuffList` 给借来的 `DebuffListFrame` 子帧做完整 reskin（图标裁边 + 1px 边框 + 冷却 + 字体）。**不做过滤**，暴雪的 `AurasFrame` 继续负责画什么 | 原先姓名板只把 `AurasFrame` 重挂到自己的板上设两个锚点（`AnchorDebuffs`），**图标本身一点样式都没动** —— 同一块板上半截是 1px 主题边框 + 渐变的 Monet 血条，紧挨着一排暴雪原味 debuff（厚驱散色边框、系统字体）。**明确不做过滤**：`candidateFilters` 是 Lua 对 `auraData.isStealable` 的比较，而敌方单位在评级 PvP 里光环数据是机密的 —— 那里 `isStealable ~= true` 对每个 buff 都成立，整组会静默变空（EllesmereUI 在 `EUI_Nameplates_AuraContainers.lua:949-956` 记录了这条，所以它把过滤全改成 C 侧字符串）。我们借暴雪现成的帧，天然绕开这个坑。**边框一律替换**：先读暴雪边框的 `GetVertexColor`（驱散类型的颜色编码），读到就用同一颜色画 1px；读不到或读出纯白（颜色烘在贴图里）就退回主题边框色。**这一条是刻意的取舍** —— 宁可丢掉个别客户端的驱散色，也不要一排厚薄不一。图标只 `SetTexCoord` 裁边（和施法图标同比例 0.08），**绝不 `SetTexture`**。冷却关描边、保留扫圈。字号按按钮高度 `×0.42` 推。全部不依赖暴雪内部成员名：名字优先、几何判据兜底，每步 pcall。`/mui nameplates diagnose` 打印已修饰按钮数 + **驱散色/主题色各多少个**（后者全满就说明这个客户端读不到驱散色） |
| 2026-10-19 | **目标光环改用 B 方案：暴雪原生 `AuraContainer`**（`AddAuraGroup` + `initializeFrame`）；A 方案（借 TargetFrame 的光环子帧）整段 `--[==[ ]==]` 注释保留，调用点同步改写 | A 方案改的是**暴雪自己的子帧**：`StackTargetAuras` 每次都要把它从 `TargetFrame` 手里抢回来，靠 `hooksecurefunc(TargetFrame_Update/UpdateAuras/SetUnit)` 兜底；而且它读不到 `C_UnitAuras`，只是指望 TargetFrame 继续替我们画。B 方案让暴雪自己画 —— 池化、排序、机密值处理、战斗中可变，全归引擎。三条实机约束（都来自 `EllesmereUI_AuraKit.lua`，同一客户端已验证）：① `AuraContainer` 属 LoD 插件 `Blizzard_AuraContainer`，必须 `LoadAddOn` 才能 `CreateFrame`；② 容器必须**先给可渲染矩形** `SetSize(1,1)`，否则引擎那轮 run-when-visible 的 OnUpdate 永远不跑第一次布局；③ `initializeFrame` 里必须**先建区域、上样式，最后才注册**，因为每个 `Set*` 注册都立刻触发 `UpdateAuraDisplay -> SetText()`，字体没设的 FontString 直接报错。另：**引擎按钮默认可点**，必须 `SetMouseClickEnabled(false)`，否则图标夹在光标和血条之间会吃掉换目标的点击。本客户端有两代 setter（`SetFlowLayout*` / `SetAuraLayout*`），每个都按新名优先、旧名兜底 |
| 2026-10-19 | **染色模具全面去色相**：`PALETTE` 新增 `stencil: #ffffff`，圆角环 / 全部字形图 / 两种织纹 / 关闭钮三态的笔触全部改用它；关闭钮 push 态由金色改为**同亮度的纯灰**；`audit-pixels.js` 的判据由「离纯白多远」换成 `hueShift`（色相偏离）+ `STENCIL` 名单（23 张），另加全局白衬底检查（Alpha=0 必须纯白，不限名单）；四张美术图显式豁免 | 起因是圆角环：`Widget:Refresh` 拿 `SetBackdropBorderColor` 染它，和平边框（`WHITE8X8`，纯白）**同一个调用**，而引擎是 贴图 × 顶点色**相乘**，于是 `#fffcf6` 染完是 `borderColor × (1, 0.988, 0.965)` —— 蓝少 3.5%，同一屏里两根同色边框不是一个色。 顺着这条线扫完全部 28 张才发现不是孤例：**织纹**被 `Widget:ButtonMaterial` 的 `SetVertexColor(r,g,b)` 染，**`monet_check`** 被 `Skin:CheckButton` 染，**关闭钮的 normal 和 push** 都被 `Skin:CloseButton` 染 —— 三者全是 `#fffcf6`。 其中 push 最糟：它烘的是金色 `#b8823a`，染完等于 `borderColor × (0.72, 0.51, 0.23)`，即「主题边框色被拉向棕色再压暗两倍」—— 主题换成蓝色，按下的 X 就是一团浑浊的蓝褐。改成同亮度的纯灰（取原金色的 Rec.709 亮度：136/172/177/112，逐变体不同，保证 push < hover 的明暗排序不变），状态信号保住，色相污染归零。 **保留的（各有理由，注释写在 `Media.lua` 和 `audit-pixels.js` 里）**：`close_hover`（`Skin:CloseButton` 明说 highlight 不染色，金色就是 hover 信号本身）、`win_maximize` 的金色标题栏（结构语义：「这是个窗口」）、`brush_stroke` 与 `corner`（只调 alpha，奶油/赭石双色是核心美术）、`role_*`（纯灰度是既定决策，色相是状态信号）、`minimap_rect_mask`（不上色的遮罩）。 判据从「离纯白多远」改成**色相偏离**（三通道两两之差取最大）是有意的：role 图标是纯灰的，明度差 90+ 撑的是立体感，用旧判据会误判；而 `#fffcf6` 这种「几乎纯白但带一点暖」的正好被抓出来。反例验证用 `Assets/Textures.bak` 跑过，24/25 FAIL，拦得住 | 
| 2026-10-19 | **圆角边框改为三张环宽可选**：`monet_round_edge` / `_thin` / `_thick`（环宽 2/1/3 纹素，外弧 3/2/4），`Widget:Theme` 用 `PickRoundEdge` 按 `thickness * Mult()` 选最近的一张 | 环是**烘在纹理里**的，而 9-slice 把最外 `edgeSize` 个纹素 1:1 映射成 UI 单位 —— 环宽只能是**整数 UI 单位**。钉死 2 纹素就等于钉死 2×uiScale 物理px，于是小地图/任务追踪这两块圆角面板在任何非 100% 缩放下都会跟其余所有框（平边框，恒定 N 物理px）漂开。贴图存不下半个纹素，只能多出几张环宽不同的图取最近的一个，把误差压到半个纹素（0.5×uiScale 物理px）以内。三张覆盖 `thickness × Mult() ≤ 3`，即 thickness=2 时 uiScale ≥ 0.667 —— 现有两个调用点都是 thickness=2，WoW 缩放下限 0.64 压线也命中 |
| 2026-10-19 | **像素网格改用 `Mult() = 1 / tonumber(C_CVar.GetCVar("uiScale"))`**，新增 `Media:SnapUnit()` 与 `Widget:Size/Width/Height`（工厂层统一吸附） | 目标定为**整物理像素**：1 个网格单位 = 恰好 1 个物理px，任何缩放下都不变。这**不是** ElvUI/Andromeda 的网格 —— 它们用 `768/屏高`，一个「逻辑像素」在 1080p 是 0.711 物理px，做的是分辨率归一化。两个参考没法直接抄，因为分母来源在本客户端都不可用：`UIParent:GetEffectiveScale()` 被标 `SecretReturnsForAspect`（秘密值，算不了，`Secrets.Number` 返回 nil）；`UIParent:GetHeight()/physH` 只在 UIParent 铺满屏幕时等于 1/scale，而 ElvUI（`PixelPerfect.lua:79` 连尺寸一起改）和 Andromeda（`uiscale.lua:19`）都会动它。读 uiScale CVar 不需要占有 UIParent：不抢玩家的滑块、不会被别的插件投票改变，只要监听 `UI_SCALE_CHANGED`。实测（`tools/test-mult.js`，带源码断言防止公式漂移）：thickness=1/2 的边框在 uiScale 0.64/0.71/0.80/1.0/1.15/1.25 六档下折回物理像素**恒为 1.000000 / 2.000000** |
| 2026-10-19 | **像素级对齐**：所有轴对齐几何（矩形、直线、直边）改走 `pxRect` / `pxHLine` / `pxVLine` / `pxStrokeRect` 吸附到整数像素边界；抗锯齿只留给真正的曲线。覆盖 `plus` / `minus` / `win_maximize` / `win_minimize` / `win_restore` / 箭头箭杆 / 剑的护手与剑柄 / 权杖竖杆 | 抗锯齿对曲线是对的，对**本该对齐的直边**是错的：`fillRect(30.5, ...)` 会让左右两列像素各拿到半个覆盖，渲染出来是一条 50% 灰的发虚边。吸附之后落在像素边界上，天然无 AA，每个像素都是满 alpha。做法是"先吸附边界、再回填厚度"而不是"吸附中心" —— 后者会让 3px 的臂偏出中心半像素，一组对称图形就不对称了。混合图形（箭头=直杆+曲箭头、剑=直护手+曲剑刃）必须拆成两笔画，把直边从曲线路径里摘出来 |
| 2026-10-19 | 新增 `tools/audit-pixels.js`：查半覆盖像素、软边直边、孤立像素（描边断点），并带**验收标准表**（`STRICT` 纯矩形纹理半覆盖必须为 0；`NO_SOFT_EDGE` 含直边的纹理软边必须为 0；所有纹理孤立像素必须为 0） | 光报数字没有意义 —— "半覆盖 508"没人知道该不该紧张。标准表把及格线写进工具里，曲线纹理（圆/弧/切线）不在表内，因为曲线的切点本来就该有半覆盖。另外 `tools/make-pixel-grid-sheet.js` 出像素网格检视表：整数倍最近邻放大 + 在每个源像素边界画网格线，边压在网格线上就是像素级干净，跑偏就会看到灰阶毛边 |
| 2026-10-19 | **采用 `crisp` 锐利变体**（26 张全量替换 `Assets/Textures`）。定义：图标线宽 3px / 加减 5px、图标占画布 106%、role 灰度侧影 `#787878`、关闭钮三态 白→`#f2cb8a`→`#b8823a`，织纹用**标准档**（步距 8 / 线 2 / α .35，斜纹线宽 = step/√2/2） | 四套并排对比后选的。决定性依据是**对比表里那张 18px 实显格**：放大看 3px 与 2px 差别不大，但按真实显示尺寸缩一次再看，2px 在 16–22px 区间明显发虚（`plus`/`minus`/`win_minimize` 最先垮）。反过来织纹**不能**跟着加粗 —— `bold` 的 3px 线在 18px 下互相叠成一片白，织纹结构全丢。所以线宽取重、织纹取标，两条轴本就独立，混搭成立。换回任何一套只需 `node tools/regen-textures.js <变体名>`（已验证安装前 `Assets/Textures` 与 `standard` 变体逐字节相同，回退无损） |
| 2026-10-19 | 生成器加**变体机制**：`VARIANTS` 表定义五套（`standard` 标准 / `crisp` 锐利 / `heavy` 浓重 / `bold` 厚重 / `fine` 精细），只在"视觉重量"一个维度上分档 —— 线宽、图标占画布比例、织纹密度、role 灰度对比、关闭钮三态色。`node tools/regen-textures.js` 出全套到临时目录对比，`node tools/regen-textures.js <变体>` 才落到 `Assets/Textures` | 色板底色、圆角几何、描边宽度**故意不做成变量**：前两者被 `Widget.lua` 的 `ROUND_INSET=2`/`ROUND_SLICE=3` 钉死，改了 9-slice 会整体错位。把"哪些是自由变量"和"哪些是契约"分开写死，免得以后为了调观感去碰耦合值。对比表每行除了放大图还画一格**按真实显示尺寸（18px）缩放后再最近邻放大**的实显效果 —— 小图标能不能认出来是在那个尺寸上决定的，只看 2 倍放大图会做出错误判断。`heavy` 是选完 `crisp` 后补的一档，往最重处探边界：图标占比反而收小到 0.94，因为 4px 笔触压在 106% 的图形上会把转折糊成一团，收小一圈刚好留出呼吸 |
| 2026-10-19 | 对齐参考插件 EllesmereUI：`monet_barfill` 改成**平的**基色，明暗改由运行期 `SetGradient` 按条轴算出（新增 `Widget:BarGradient` / `Widget:TopLight`） | 之前把竖向渐变烘进 16×16 纹理，等于把明暗**绑死在一个条高上** —— 同一个文件要同时服务 10px 的血条和 40px 的滚动条 thumb，拉高就变成一条长渐变而不是横截面体积。参考插件的做法（`EllesmereUIUnitFrames.lua:1337` `ApplyBarGradient`）是"纹理只管材质、几何负责明暗"，好处是任何条高、任何轴向都成立。画布保持 16×16 方形：正方形不携带方向信息，横条竖条通用。**关键约束**：`SetStatusBarTexture` 会新建纹理对象、梯度随旧对象一起没了，所以每个换纹理的地方都必须重新推导（`Nameplates.Layout` 两处） |
| 2026-10-19 | 透明像素的 RGB 统一改成**纯白哑光 (255,255,255)**，不再填"不透明像素平均色" | 我们的材质全部是 `SetVertexColor` 可染色的近白，而染色是乘法：纯白哑光乘任何色调都精确得到该色调本身，平均色则会带进一点偏色残留。参考插件同一判断 —— 所有可染色遮罩（`rounded/*`、`basics/ring_*`）的 alpha=0 像素都恰好是 `(255,255,255)`（white matte），而纯黑/平均色只出现在预染色的美术上。防滤波黑边的动机与"禁止纯黑"一致，但目标值更可预测 |
| 2026-10-19 | 新增发丝线材质 `monet_hairline`（256×1，整幅一行满 alpha）+ `Widget:Hairline` | 参考插件把极细线做成独立素材而不是从边框图里抠：`thin-line-top` 是单行 α255 其余全透明，最细的 `pixels-overshield-line` 只有 **2×32**。我们原先只有 `monet_brush_stroke`（手绘笔触下划线），缺一条"安静的 1px 线"。纹理不携带方向：贴图被拉多高那一行就铺多高，所以 `SetHeight(1)` 才是发丝，拉高自然变成分隔带 |
| 2026-10-19 | role 三图标从"烘焙语义色 + 禁止染色"改为**刻意无色的灰度图**（R==G==B，芯 255→边 168），色相全部交给 `Color:RoleTint(unit)` | 上一轮先做成"近白芯 + 语义色侧影"，这轮按参考插件 `icons/roles` 的思路推翻：他们的 leader/assist 是 16×16 **纯灰度**、刻意无色以便按状态染色。语义色烘进纹理就得为每个状态各出一套；灰度一张图服务所有状态。**染色规则（暂定，可能二次调整）**：只有该玩家是队长或助理（`IsGroupLeader` / `IsRaidLeader` / `IsGroupAssistant`）时用 `Color:GetHighlight()` 染色，否则纯白单色。颜色标的是**角色分工**而不是职业 —— 不是队长的坦克和别的坦克长得一模一样。形状靠明度渐变撑住，所以去掉色相后仍然可读 |
| 2026-10-20 | 单位框边框改由**引擎的状态染色层**（`LibMonetColor-Anim-1.0`）驱动，UI 只负责落色 | 战斗/低血/休息的判定收进库：口径统一、不必每个框架各写一遍；库自带一个共享 ticker（查表波形、15 fps、空闲停表），UI 侧零 `OnUpdate`。悬停/仇恨仍由 UI 掌握，通过 `monetBorderOverride` 门控，退出时把库的颜色还回来 |
| 2026-10-20 | `monet_brush_stroke` 重画为**油画笔触**，并把**笔触的作者从脚本换成 GIMP**（`tools/gimp-brush-stroke.py`） | 脚本版（node-canvas 逐像素）能画准五个色块与两端淡出，但画不出**鬃毛痕**与**颜料洇边** —— 笔触这种"手绘感"的东西，逐像素循环只能近似。改用 GIMP 3.2 的真实画笔引擎（自带 Oils / Bristles / Acrylic / Charcoal 笔刷）：五遍颜料（暗边→赭金→浅金→暖白→奶白芯）各用一支笔刷沿同一条起伏路径盖章，边缘是颜料自己洇出来的，芯上留鬃毛痕。**踩到的坑**：① GIMP 3 的 TGA 导出默认是 **RLE（type 10）**，而项目里所有材质都是未压缩的 type 2 → 改成 GIMP 出 PNG、`tools/tga-post.js` 转格式并补纯白衬底；② GIMP 3 的 Python API 是 `Gimp.*` 命名空间（没有旧版 `gimpfu.pdb`），颜色分量必须 **0..1 浮点**（传 0..255 会被夹成纯白）；③ 画笔"硬度"是 0..1、"间距/不透明度"是 0..100，两套量纲混用会画出一层几乎透明的雾；④ `edit_stroke_item()` 在这个版本**只画路径的首尾两点**（点列路径 / 两点路径 / PAINT_METHOD 全试过），所以改成**自己逐点盖章**（每个位置一条 0.01 长的小路径 = 一个笔触点）；⑤ 默认图像精度是 `U8_NON_LINEAR`（= sRGB）✓ 颜色可以直接给 sRGB 值。对照图见 `%TEMP%\opencode\brush-compare.png` |
| 2026-10-20 | 材质改**三条画图路线**并存：脚本（结构件）/ GIMP（要软要洇）/ SVG（要自己画或改） | 起因是"手绘感"与"可编辑源码"两个诉求：脚本逐像素画不出鬃毛痕与颜料洇边（→ GIMP），但脚本里的圆角是一个数、改一下要重跑并对着代码调（→ SVG 可以直接在 Inkscape 里打开手改）。**分工**：① **结构性**（9-slice 边纹 / 遮罩 / 发丝线）必须像素级精确 → 脚本；② **要软要洇**（笔触）→ GIMP；③ **图标** → SVG。**GIMP 画小图标会更差**（实测：笔刷的抗锯齿在 11–24px 显示尺寸下糊成一团，逐点盖章拼不出闭合形状）—— 对照图 `%TEMP%\opencode\icon-compare.png`；SVG 版与脚本版**像素等价**，优势只在源码可读可改 —— 对照图 `%TEMP%\opencode\svg-compare.png`。现役 7 张走 SVG（`minimap_rect_mask` / `monet_close_{normal,hover,push}` / `monet_map_{tracking,compartment,difficulty}`，源码在 `tools/svg/`），**规矩：有 SVG 的以 SVG 为准**，生成器里不再画同名纹理，免得两套源码互相覆盖 |
| 2026-10-20 | 小地图遮罩 `minimap_rect_mask` 的可见带圆角 **4 → 6** | 圆小地图时代，画布四角的"圆弧废料"是这套皮肤的性格来源；把画布裁成一条 190 高的带，四角就成了硬切口。半径 4 在 256 宽的地图上**根本读不出来**（渲染图上看和直切口没区别），于是圆形小地图的痕迹全丢。6 在这个尺度上读得出"圆角"，又不至于把地图啃成椭圆（10 就过了）。顺带把 `Media.lua` 里那段**说错的**理由改掉：它当时说"半径 4 正好切掉面板边框盖住的那些像素"—— 实际不成立，可见带距面板每边 4、边框环宽 2，带子根本够不着边框，这个半径只决定地图自己的角 |
| 2026-10-20 | 地图内三个按钮的图标改成 **4:3（宽:高）横长徽章**，且**徽章就是材质本身** | 之前是"3:4 竖长底板 + 一个 11×11 的正方形图标"—— 比例方向弄反了（要的是宽 4 高 3），而且正方形图标浮在矩形底板里，既不是 4:3 也不好看。现在材质画布 64×64、徽章本体占中间的 **64×48 = 4:3**，运行时画成 20×20 → 徽章正好 20×15。描边与半透明底都进了贴图，所以**不再另铺 `Widget:Theme` 底板**（否则双层边框），改成用顶点色整体染色；贴图是"中性灰底 + 白色描边"的模具（已进 `audit-pixels.js` 的 STENCIL 名单，色相偏离必须为 0） |
| 2026-10-20 | 单位框生命条高度 **2 → 4**（player / target / targettarget / focus / pet 全改），宽度与能量条不变 | 回到 Andromeda 的配置值（`gui/configs.lua`：HealthHeight = 4 / PowerHeight = 1 / 宽度 160-160-60-60-60）。此前减半是因为 Andromeda 会 rescale UIParent 而 MonetUI 画 1:1，减半才是同样的**物理**厚度；现在生命条要露出底下的织纹，2 单位（≈3 物理px）不够看。数据库 schema 升到 3，迁移里把 `health`/`power` 显式推成新值（`MergeDefaults` 只补缺失的键，老存档里的 2 不会自己变），玩家拖过的位置不动 |
| 2026-10-20 | 单位框条的**背景**改织纹（新增 `Widget:BarWeave`），**填充保持平色** | 填充的体积是 `SetGradient` 现算的渐变（`Widget:BarGradient`），织纹和它会打架，所以填充一个字不动；底子换成和按钮同一块画布平纹（`monet_canvas_weave`）。织纹是 64×64、2 纹素宽 8 纹素步距，而条只有 2–4 单位高：整张贴图压下去会被 mip/filter 抹成一片死灰，所以用 `SetTexCoord` 开一个**只取条自身高度**的窗口，窗口高度按**物理像素**算（`Media:Mult()` 是 1 物理px 的 UI 单位数），一个纹素正好落在一个物理像素上。窗口永远从布料的同一行开始（织纹每 8 行一循环），1px 的能量条和 4px 的生命条看到同一相位。织纹层用 sublevel 0 建在 `lost` 之后 → 盖住缺失段、仍在填充之下（填充的贴图在更高的绘制层），这是 Andromeda 血条元素同样的做法 |
| 2026-10-20 | **UI 缩放按分辨率固定**：`Media.scalePresets`（1080p → 0.711111 / 1440p → 0.533333 / 4K → 0.711111）+ `Core.ApplyAutoScale` 在登录时写进 `uiScale` CVar，配置面板可切"跟随游戏" | 插件里的尺寸全是 UI 单位写的，1 单位不落在整数物理像素上，4 单位的条、12 单位的字就骑在像素边上、看着发软。`uiScale = 768 × 每单位像素数 / 屏高`，取整不取整——值必须精确，否则又骑线。**这个客户端的缩放滑块下限是 0.65**（`Graphics.lua:925`），1440p 的首选值 0.5333 可能被夹掉，所以每档都备了下一个候选（2 像素/单位），写完立刻读回验证。副作用：顺带把圆角边框的亚像素漂移消了 —— `test-mult.js` 里"圆角 vs 平边框"的差只有在 `uiScale == 768/physH` 时才是 0，而现在钉住的正是那个值。玩家自己拖了滑块就交还控制权（`UI_SCALE_CHANGED` 里发现 CVar 与我们写进去的不一致就切"跟随游戏"）。`/mui scale` 报当前模式、固定值与"1 UI 单位 = N 物理像素" |
| 2026-10-20 | 小地图形状分两档：`shape = "resize"`（默认，画布直接 256×190，引擎按新视口重绘）/ `"mask"`（老方案，正方画布 + 遮罩裁掉上下 33，作回退） | 老方案是"正方画布 + 遮罩裁一条 190 高的带"，地图画面不重绘、只是被遮罩裁了；引擎那层追踪点（blip —— `MinimapFrame:UpdateBlips` / `SetQuestBlob*` / `C_Minimap.GetTrackingFilter`）不在被裁的画布里，只要它不走遮罩那条渲染通道，就会漏到那两条 33px 的带子里，而那两条带子落在面板外（面板 198 高 < 画布 256），点会直接浮在屏幕上。改成让引擎按 256×190 的视口重绘就没有"画到外面"的地方了。留一档遮罩方案是因为这个客户端是定制引擎（camelot），万一重绘出来的地图变形，切回去即可；两条路的可见区在屏幕上位置一致（下沿离屏底 51px），切换不跳位。`resize` 下客户端的圆形遮罩换成 `WHITE8X8`（正方遮罩套到矩形画布会被拉成椭圆、切掉地图四角） |
| 2026-10-20 | 单位框模块清掉一批"只报出处不解释原因"的注释；`tools/test-mult.js` 增加固定表自检 | 注释要回答**为什么**，不能只回答"抄谁的"——数值来自哪里写在 `Core.DEFAULTS` 的注释里就够，代码里重复一遍反而会漂（这轮就有 `or 4` 旁边的 "Andromeda's configured health bar height"）。自检新增：断言 1080p/1440p/4K 的钉死值确实让 1 单位 = 整数物理像素，改表改飘会直接失败 |
| 2026-10-21 | 小地图形状**默认翻回 `mask`**（正方画布 + 遮罩裁上下各 33），`resize` 降为备用档；`Core.SCHEMA` 升到 4，老库的 `shape` 显式推成新默认 | 非正方形 `SetSize` 在 WoW 里是**把正方渲染拉伸**，不是"横向多看一圈"：WoWInterface 老帖里 184×88 的小地图被拉长、草药点与实际位置对不上，同帖和 Reddit 的结论都是"矩形只能靠遮罩裁"；ElvUI-WindTools 的 `RectangleMinimap`（生产实现）也从不改画布、只换遮罩。原先默认 `resize` 的理由是"怕引擎 blip 漏出被裁的带子"，但 blip 是引擎画在 Minimap 自己的渲染里的（`UpdateBlips` 是 C 方法，Lua 侧无实现），吃 Minimap 的遮罩；真正不吃遮罩的是 HBD 那类独立 pin frame（见 `TODO.md` 未决） |
| 2026-10-21 | 新增 `hooksecurefunc(MinimapCluster, "UpdateMinimapConfig")`：客户端重设小地图形态后**下一帧重套皮肤** | `rotateMinimap` 一改，客户端的 `UpdateMinimapConfig`（`Blizzard_Minimap/Camelot/Minimap.lua:31`，回调注册在 96-99 行）就把 `minimap:SetMaskTexture` 换回圆形图集、container/backdrop/compass 尺寸设回默认 —— 我们只在换区域时重套皮，所以切一次旋转小地图，矩形就被圆形遮罩套成椭圆、四角被切，直到下次过图。现在钩子里排 `C_Timer.After(0)` 重套（不在客户端自己的调用栈里改帧），`Restore()` 调它时用 `restoring` 旗跳过，战斗中走 `Queue("skin")`。`/mui minimap diagnose` 多一行报钩子是否装上 |
| 2026-10-21 | 新增 `Modules/Minimap/Pins.lua`：把 HBD 的 pin 在 `mask` 档被裁的带子里**压掉 alpha**，离开后按原值放回 | `mask` 档可见区只有 190 高，但 HBD 的 pin 是挂在 `Minimap` 上的独立 frame、不吃遮罩，并且按画布 256 算位置（`minimapWidth/Height = GetWidth()/2`、矩形边界系数 0.9），pin 会落在离中心 95–115 的地方——正好浮在面板外。WindTools 的 `RectangleMinimap` 为此写了一整段补丁（hook `activeMinimapPins` + 每个 pin 的 `SetAlpha/Show/SetPoint`），我们按同一思路做了更省的一版：hook HBD 公开入口 `AddMinimapIcon*` 即时接入新 pin，再扫 `minimapPins`/`activeMinimapPins` 兜住已有 pin；判据直接读 `GetPoint(1)` 的 `offsetY`（HBD 锚成 `CENTER ← Minimap:CENTER`），比 `GetCenter` 相减少一次缩放换算；压 alpha 而不是 `Hide()`，因为 HBD 每次都先 `Show()` 再 `SetPoint()`；原 alpha 只记第一次、还原写回原值（不是硬写 1），关模块时全部还原。没装 HBD 就整段空转 |
| 2026-10-21 | 矩形小地图下收掉暴雪的 blob ring：`Minimap:SetArchBlobRingScalar(0)` / `SetQuestBlobRingScalar(0)`，关模块时放回默认 1 | 任务区域 / 考古点的"blob ring"是按圆画的，套在矩形地图上会在蓝色任务区域里露出一圈圆形"华夫饼"纹（BasicMinimap 的注释原话）。两家参考都这么做：Ellesmere `isCircle and 1 or 0`、Andromeda 直接 0。只动 scalar 不动 alpha——环的尺寸已经是 0；手册里只有 `Set*` 没有 getter，所以还原值是默认的 1 而不是快照。`SetTaskBlobRingScalar` 两家都没动，这里也不动 |
| 2026-10-21 | `Modules/Minimap/Minimap.lua` 接管客户端 LoD `Blizzard_HybridMinimap` 的 `MapCanvas` 遮罩：皮肤开着时换成矩形（`minimap_rect_mask`），关模块时换回它自己的 `CircleMask` | 这个包是客户端自带的（不是第三方插件），`ShouldUseHybridMinimap()` 为真的地图里小地图改用世界地图 `MapCanvas` 平铺；XML 的 `OnLoad` 给画布套的是 `CircleMask`（圆形、内缩 3），在矩形面板里会把地图四角啃成圆的。做法与 BasicMinimap 一致：**改 `CircleMask` 这块遮罩自己的贴图**，而不是另建一块——同一个对象还罩着 `HybridMinimap.Background`（黑底），只换画布的遮罩，地图画到边界外时角上会露出面板；顺带把"内缩 3"临时撑满整帧（可见带贴边），还原时贴图与锚点都按快照放回。换完 `SetUseMaskTexture(false→true)` 抖一次确保画布重新挂遮罩。帧层级不冲突（`BACKGROUND`/固定 100，面板之上、小地图 `LOW` 与覆盖层之下），画布本身又禁用了点击/滚轮，所以只动遮罩。`ADDON_LOADED` 认包名即时接管，`Skin()` 每次补一遍，`diagnose` 报加载/接管状态 |
| 2026-10-21 | 删除小地图形状的 `resize` 档，只留"正方画布 + 遮罩裁带"；配置面板的"地图形状"下拉移除，`Core.SCHEMA` 升到 5 清掉 `minimap.shape` | 两档里只有遮罩这一档能确认不拉伸（画面根本不重绘）；`resize` 是把正方渲染拉伸的那条路，留着的唯一价值是"对照"，而对照本身会让人误以为它可以当成品用。删掉之后代码只有一条路径：`SetMaskTexture(minimapRect)` + `SetSize(256,256)` + `SetHitRectInsets(0,0,33,33)`；`MASK_CROP` 也改成 `(MASK_CANVAS - MAP_HEIGHT)/2` 由常量推出来，不会再和 190 各写一份。老存档的 `shape` 键一次性清掉，免得以后有人以为它还有用 |

---

## 九、关键资产索引

### 材质制作规范（生成器强制）

| 条目 | 现状 |
|------|------|
| 尺寸 | **2 的幂**（`tools/regen-textures.js` 的 `SIZES` + 生成后校验）：图标 64×64、笔触 256×16、发丝线 256×1、遮罩 256×256、九宫格边纹与 corner 16×16。9-slice 边纹不按"边框建议 256×256"取大尺寸 —— 客户端只采样它最外圈 `edgeSize`（3）个像素，中间整段是拉伸用的，做大只白占显存（客户端自带的 `UI-Tooltip-Border` 也是 64×64、角 16）。**笔触 256×16**：`Widget:Rule` 只把它画 9px 高，画布是显示高度的 1.8 倍采样（32px 时是 3.5 倍，纯过采样，压到多矮都糊） |
| 格式 | 只装 **TGA 32bit RGBA**：类型 2（未压缩），descriptor `0x08`（8 位 alpha + BOTTOM-LEFT origin）；不产 BLP，也不在 `Assets/` 放 PNG。PNG 副本只写进 gitignore 的 `docs/texture-preview/` 给浏览器预览 |
| 透明 | 只靠 **Alpha=0**，不做颜色键；透明像素的 RGB 填成**纯白哑光 (255,255,255)**，不留黑也不填平均色 —— 客户端生成 mip / 双线性过滤时会把边缘像素的颜色拖进可见区，纯黑会在每个图标周围描一圈灰边；我们的材质全是 `SetVertexColor` 可染色的近白，染色是乘法，纯白哑光乘任何色调都精确得到该色调本身 |
| 纯黑 | 没有任何 alpha=255 的纯黑像素；且透明区 RGB 也不为纯黑（逐像素审计实测 0 个） |
| 命名 | `monet_*` 小写 + **下划线**（如 `monet_barfill.tga`），文件名、生成器 id、`Utils/Media.lua` 的贴图键三者同名；改名要同时改这三处 |
| 明暗 | 条/面的明暗**不烘进纹理**：`monet_barfill` 等仍是平色基材，体积由运行期 `Widget:BarGradient`（沿条轴）/ `Widget:TopLight`（横截面）算出 —— 把渐变烘进固定尺寸纹理等于绑死一个条高（理由见 2026-10-19 决策）。**例外（2026-10-27 起）：插画件例外** —— 进出战斗的剑/盾按"灰阶明暗 = 形体感的载体"烘进贴图（斜面渐变、 fuller/铆钉/盾钉的高光），它们是唯一形体、没有"其它条高"要服务；染色的只是语义层（进/出的金与青蓝）。详见 HANDOFF 3.25/3.26 |
| 像素对齐 | 轴对齐几何一律走 `pxRect` / `pxHLine` / `pxVLine` / `pxStrokeRect`，**边吸附到整数像素边界**，抗锯齿只留给曲线。验收用 `tools/audit-pixels.js`：`STRICT` 表（纯矩形纹理）半覆盖像素必须为 0、`NO_SOFT_EDGE` 表（含直边的纹理）软边直边必须为 0、所有纹理孤立像素（描边断点）必须为 0；另有 `STENCIL` 染色模具名单 + 全局白衬底检查。当前实测 **37/37 通过**（含剑/盾等烘了灰阶明暗的插画件） |
| SVG | **产** SVG 材质（2026-10-20 起三条路线并存）：结构性的走脚本、要软要洇的走 GIMP、**要自己画/自己改的走 SVG**（Inkscape 手写矢量 → `tools/svg-to-tga.js` 导出）。现役 9 张：`minimap_rect_mask` / `monet_close_{normal,hover,push}` / `monet_map_{tracking,compartment,difficulty}` / `monet_spark_{up,down}`，源码在 `tools/svg/`。**规矩：有 SVG 的以 SVG 为准** —— 生成器（`tools/regen-textures.js`）里不再画同名纹理，否则两套源码互相覆盖 |
| 线宽 | 由**变体**决定（`tools/regen-textures.js` 的 `VARIANTS[*].lineWidth`），当前采用 **`crisp` 锐利**：`icon = 3px`（勾/X/箭头/V 形/窗口控件/搜索）、`plusMinus = 5px`、`hairline = 1px`。**不是**变体的：`corner` 的 1px 线。原因见决策记录：对比表带 18px 实显格，3px 在实际显示尺寸下明显比 2px 实，而 2px 在 16–22px 区间偏虚 |
| 自校验 | 生成后由 `tools/compare-textures.js` 做像素对比，`tools/gen-compare-html.js` 出并排预览页；另查尺寸幂次、BPP、descriptor、文件大小、纯黑透明像素 |

| 资产 | 路径/位置 | 说明 |
|------|-----------|------|
| MonetColor 引擎 | `monetcolors\LibMonetColor-1.0.lua` | 色彩计算引擎 |
| MonetColor 测试 | `monetcolors\test_phase1.lua` | 45 个单元测试 |
| Andromeda 参考 | `wowaddonsdev\Andromeda\` | UI 设计参考 |
| Andromeda forever 参考 | `wowaddonsdev\Andromedaforever\` | 动作条（`modules\actionbar\`）架构与取值参考 |
| LibActionButton-1.0 | `MonetUI\Libs\LibActionButton-1.0\` | 动作按钮库（BSD-3），随包 |
| EllesmereUI 参考 | `wowaddonsdev\EllesmereUI-v9.4\` | 模块实现参考 |
| ForeverUI 参考 | `wowaddonsdev\ForeverUI-0.4.24\` | 轻量实现参考 |
| wuxian MCP | 已连接 | 游戏内调试工具 |
| PortableGit | `wowaddonsdev\PortableGit\` | 版本管理 |
| 自绘 UI 材质 | `Assets/Textures/monet_*.tga`（24 组，包内只有 TGA） | `tools/regen-textures.js` 生成并自校验；**`monet_brush_stroke` 例外** —— 笔触改由 GIMP 的画笔引擎画（`tools/gimp-brush-stroke.py`，真实颜料笔刷才有鬃毛痕与洇边），走 PNG → `tools/tga-post.js` 转格式 + 补白衬底；`docs/texture-preview.html` 预览；接线处：`Skin:SwapArt`（关闭钮/勾选框）、`Widget:Bar` 默认 `barfill` |
| 矩形小地图遮罩 | `Assets/Textures/minimap_rect_mask.tga` | 源码 `tools/svg/minimap_rect_mask.svg`（`node tools/svg-to-tga.js` 导出）；直角 `rx=0` —— 曾试过 rx=6 的圆角版，随圆角方案一起撤回；接线处：`Minimap:SetMaskTexture` |
