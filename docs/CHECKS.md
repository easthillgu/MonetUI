# 检查清单与探针（平台无关）

> 以前这些流程是 opencode 的自定义命令（`.opencode/commands/check.md` / `verify.md`），
> 换平台后把可执行的部分写成这里，agent 照做即可。

---

## A. 改完代码（离线，必做）

```powershell
# 1) 改了哪些文件
git status --short

# 2) 离线闸门：C_* 名字 / 事件名 / Enum 值 是否对得上本客户端快照（HARD 项 = 退出码 1）
node tools/api-audit.js

# 3) **必须**：Lua 语法 + 未解析名字 + 受保护调用（`live:false` 也行，不需要游戏）
#    2026-11-06 判例：离线三条闸门（api-audit / audit-locals / audit-taint）**都只做文本匹配、
#    不解析 Lua 语法** —— 我给 Skin.lua 少吃一个 `end`、给 Collections.lua 用了不存在的全局 `Widget`，
#    三条全绿、直接部署 ⇒ `Skin` 整块不加载、17/21 模块、五个模块连锁失败。
#    **这一条是唯一会做语法解析的闸门**：部署前必跑，0 error 才算完。
#    **传仓库绝对路径**：按 addon 名查的是"已安装副本"，审不到还没部署的源码
#    tools.wuxian.check({ target = "C:\\Users\\EastHillGu\\Documents\\wowaddonsdev\\MonetUI", live = false })
#    （按名字跑会多一条 toc-interface 警告：部署脚本才会把 ## Interface 改成客户端号，不是缺陷）

# 4) Scheduler 订阅回调签名闸门（2026-11-07 Cursor 拖尾判例）
#    Scheduler 只投一个 elapsed；从 SetScript("OnUpdate") 迁移过来的回调若留着
#    (self, elapsed) / (_, elapsed)，`elapsed` 恒 nil ⇒ 计时永不前进 ⇒ 功能静默死亡（零报错）。
#    R1 形参必须 ≤1；R2 冒号方法（function M:Tick）不许裸名传给 Scheduler。
node tools/scheduler-callback-probe.js

# 5) 外部驱动账行为闸门（碰过 Scheduler:Profile / 外部 OnUpdate 驱动时跑）
#    这批驱动只在干活时挂 SetScript，不进订阅表 —— 壳写错同样是"/mui perf 里什么都没有"。
#    断言：实参不被改写 / 不吞错 / 真记账 / 排序正确 / PrintStats 不抛。
lua tools/external-ledger-probe.lua

# 6) 画面观感诊断闸门（碰过 Modules/Tools/Tweaks.lua 或"画面发灰/发白"报障时跑）
#    风险全在格式化：客户端把 default 回成 number / 根本不回 default / 没有这个 CVar，
#    三种形态下 %d、%.2f、字符串比较都可能当场抛错 —— 这条命令崩了就等于没有诊断。
lua tools/tweaks-vision-probe.lua
```

改了材质还要跑：

```powershell
node tools/audit-pixels.js     # 2 的幂 / 纯白衬底 / 染色模具无色相
```

> **能力事实（11-03 审查实测）**：Andromeda 参考件那族贴图是 TGA **type 10（RLE 压缩 32bpp）**
> （`statusbar-stripes-thin.tga` 头字节逐字节核过：type=10、64×32、32bpp），本仓现有解码链按未压缩
> 顺序读（只实际吃得下 type 2，遇 type 10 会静默读乱）。以后比对参考件用
> `tools/compare-andromeda-close.js`（:35 起自带 type 2/10 × 24/32bpp 解码），
> **不要手改 `tools/audit-pixels.js`**。

改了**品质色**（`Utils/Skin.lua` 的 `Skin:QualityColor` / `QUALITY_FALLBACK`）还要跑：

```powershell
node tools/quality-color-probe.js   # 品质色单一真值源闸门（源码级 + Lua 探针），退出码 0 才算完
node tools/slot-info-probe.js       # 装备格「等级数字 + 冷却遮罩」接线闸门（18 项，退出码 0 才算完）
node tools/report-probe.js          # /mui report 行为闸门（30 项：段落齐 / 机密值不拼进输出 / 账本落盘 / DB 断、战斗中不崩）
node tools/whatsnew-probe.js        # 更新提示行为闸门（15 项：只打一次 / 可重看 / 无记录不编内容 / 拿不到版本不崩）
node tools/capability-probe.js      # N4 能力表行为闸门（16 项：三态不塌值 / 受限窗口不造框 / 一辈子只造一次 / 列表无副作用）
node tools/bank-parity-probe.js     # 银行与背包并存接线闸门（37 项：命名空间/不猜索引/停车纪律/越权边界）
node tools/micromenu-entries-probe.js # 微菜单入口闸门（13 项：GetScript/安全模板/SetAttribute 零出现 · 入口只留纯 C_* 动作行 · 判据命令读 GetNumPoints）
node tools/infobar-secure-click-probe.js # 信息栏越权闸门（10 项：OpenPanel 已删 / 暴雪 Lua 全局零调用 / 这里禁止出现安全模板（锚定家族判例）/ 唯一 onClick 只开我们自己的窗）

# 12.1.5（_retail_ / 120105）观感预验趟：docs/PRECHECK-RETAIL-120105.md
#   部署必须带参数：powershell -File tools/deploy-retail.ps1 -Dest "…\_retail_" -Interface 120105
#   校验：node tools/sync-check.js --dest "…\_retail_"（裸跑只查 _forever_）
#   定位：只验几何/排版/文本/性能量级/加载链；机密值·受限六类·安全按钮·银行索引·真名一律不算数
```

> **这条闸门够不到的东西（11-03 本车道实跑：入口 4 项 + 探针 48 断言全绿）**：它断言的是**接线与形状**
> （六档字面量只允许在 `Utils/Skin.lua` 出现、Bags 不再有 `QUALITY_COLOR`、色块统一命名字段 `{r,g,b}`、
> `tipPrev` 机密守卫）。**订正本条早前那句"跑的是 `api_stub.lua` 的假 `GetItemQualityColor`"**（写错了）：
> 探针头注明写"为什么不 use `tools/harness/api_stub.lua`（那是 harness 道正在改的文件）"，它**自供假 `C_Item`**
> 并把发行码那段编进 chunk 跑 —— 成功支**是被走到的**，但用的三个数是编的 ⇒ **客户端真返回什么颜色，它一个字节也拿不到**。
> 另：**走 `api_stub` 的 harness 跑连成功支都进不去**（stub 返回一张表，真实返回三个 number + 字符串）⇒
> 那条路径看到的品质色**必然是旧兜底六档**，别当"客户端色已比对"（判据与行号证据 HANDOFF 8.29 **判例⑤**）。
> "1.60 上客户端色 == 旧手调六档"只能实机眼看，判据在 C2 品质色条（账见 HANDOFF 8.29.1 A10 / 判例④⑤）。

---

## B. 部署 + 实机（有 wuxian MCP 时）

```
tools.wuxian.status()                              # link.state 必须是 online
powershell -File tools/deploy-retail.ps1           # 拷文件 + 按客户端改写 toc 的 Interface
node tools/sync-check.js                           # 必须 "in sync"（否则游戏加载的是旧代码）
tools.wuxian.check({target="MonetUI", live=true})  # 再确认一次
tools.wuxian.reload({reason="一句话说明这次改了什么"})   # 弹按钮，玩家点
tools.wuxian.logs({since=0, limit=300})            # 看 ERR / BLOCKED
tools.wuxian.snap({region={0,0,400,200}})          # 截图核对视觉
```

> **sync-check 自身的坑（11-03 集成道修复，"工具字段会骗人"判例，与 `status.addons_dir` 同族）**：
> `isText()` 原先只认扩展名，**无扩展名的 `LICENSE` 落到逐字节比**那条路，而 git 的 CRLF↔LF 文本归一化
> 使 worktree 副本与部署副本**字节不同、内容相同** ⇒ **永久假 STALE**（实测 1088 vs 1067 = 21 个 CR；
> `git hash-object 部署副本` = `HEAD:` blob）。修复 = 无扩展名已知文本名也走 stripEol
> （`tools/sync-check.js:58-66` 含原始注释与 2026-11-03 案文；`node --check` 过；修后 LICENSE 从 STALE
> 列消失，**11→10**）。**同族坑仓里注释过一次**（逐字节比把刚部署完的文件报 STALE、实机误报过
> `UnitFrames.xml`），当时只补扩展名清单、没盖到无扩展名文件。
> **判据口径**：① 判"部署产物是哪批代码"用**内容比对**（`git hash-object` vs `HEAD:<同路径>`），
> **mtime 无判据价值**（robocopy 保留源 mtime，11-03 定案不记）；② `_retail_` 里 MonetUI 与 `_forever_`
> 副本**同版本号 0.12.0**，不能用来判新旧 —— 要判就比内容。

> **新增文件或改了 `.toc`**：本客户端实测 `/reload` **会**重读 `.toc` 并加载新增文件
> （2026-10-25 18:48 新建的 `CastBar.lua` 里的 nil 报错当晚 18:54 就实机报出来了），
> 所以 `/reload` 够用；**别被 `wuxian load` 文档里"新文件要整启动"那句误导** —— 那说的是热装载
> （`load`）一条路。反过来，`wuxian history` 的版本号**只记 `load`/`checkpoint`**，
> 拿"没有新版本"当"没部署"的证据是错的（2026-10-26 踩过一次，见 HANDOFF 3.7）。

**没有 MCP 时**：`deploy-retail.ps1` 之后让玩家 `/console scriptErrors 1` → `/reload` → 复现 → 贴红字/截图。

---

## C. 每轮回归清单（当前阶段）

进/出编辑模式与姓名板是**这一阶段的高危区**，每轮都要过：

- [ ] 进编辑模式 3 次 + 退出 3 次：无 `oldR`、无 `ADDON_ACTION_BLOCKED`（`wuxian logs`）
- [ ] 打有读条的怪：无 `maxHealth` / `notInterruptible` / `isFullUpdate` / 机密键索引
- [ ] buff/debuff：有时长的显示正常数字（`6m` / `45`），**proc 行为空时 debuff 行仍在**
- [ ] 小地图：位置/尺寸/矩形遮罩/面板/三个按钮/四角打标记/右键菜单/滚轮缩放；
      编辑模式里拖小地图不会带走我们的显示
- [ ] 任务追踪：只有自绘那一块（接任务 / 换地图 / 重载后各看一次）
- [ ] 动作条 1–8 号：施法 / 翻页 / 拖放；宠物条左右键 / 冷却 / 自动施法
- [ ] 单位框（玩家 / 目标 / 目标的目标 / 焦点）：血条、名字与等级/百分比位置、
      目标的目标**没有能量条也没有分隔线**、施法条
- [ ] 无新增 `taint.log`（见 D-5）

> 2026-10-26 P4 拆分动过动作条与单位框的**创建路径**（登录时就会跑），上面两条是本轮的回归重点。

---

## C2. 视觉语言验收（`docs/DESIGN-LANGUAGE.md`）

> **本段验收的判据前提（11-03）**：先确认部署产物是预期的那批代码 —— 用**内容比对**
> （`git hash-object` 已部署文件 vs `HEAD:<同路径>`），**不看 mtime、不看版本号**（判例见 B 段与
> HANDOFF 8.29"工具/数据源陷阱判例"第②③条）。

改完美化 / 换主题 / 换客户端后，逐条对：

- [ ] **透明度阶梯**只出现这些值（多了 0.955 之类的散点 = 违规）：
  `0.98` 菜单 · `0.97` 对话框 · `0.965` 阅读型窗口（任务日志/剧情/书信） · `0.96` 常规窗口 ·
  `0.92` HUD 面板 · `0.9` 控件底 · `0.85` 小地图/条底 · `0.7` 小按钮 · `0.55` 托盘 · `0.25` 槽位 · `0` 纯色
- [ ] **颜色槽纪律**：`highlight`（职业色）只出现在 hover 边框 / 选中边 / 焦点 / 玩家自身血条；
  通用静态文字、普通按钮字、NPC 名字兜底 = `neutral`；大号按钮大字 = `bright`。
  自查：`Widget:Font(..., "highlight")` / `ColorText(..., "highlight")` 只允许在 hover 回调里。
- [ ] **字号只有四档** 10 / 12 / 15 / 24；间距只走 2 的倍数，位置全过 `Media:SnapUnit`。
- [ ] **颜色键只有一张表** `Widget:PaletteColor`；新增一档只改那里（`Skin:ColorText` 用 `Color:Get`
  会静默回退 edge，见 AGENTS「客户端行为细则」）。
- [ ] **品质色只有一个真值源**（11-03 收口，`Utils/Skin.lua:1526-1616`；账见 HANDOFF 8.29.1 A10）：
  口径 = **先问客户端** `C_Item.GetItemQualityColor`，问不到（无 `C_Item` / 读不出 / 越界）才落 `QUALITY_FALLBACK`
  那六个手调数（**逐位等于改动前**）。实机判据（1.60 第一条，也是这次改动的唯一收益所在）：
  **同一件史诗装（q=3）在 ①背包格品质边 ②商人窗格品质边 ③鼠标提示里的品质文字色 三处是同一个颜色**；
  灰 / 白（0 / 1）照旧**素边不上色**；商人翻页、交易换物品后 **0.5s 驱动帧内**跟上（不必 `/reload`）。
  任何一处与其它两处不同 = 那里没走 `Skin:QualityColor`（`grep -rn "QualityColor" Modules Utils` 应只命中
  `Utils/Skin.lua` 定义 + `Modules/Bags/Bags.lua` 取用）。**离线闸门判不了颜色本身**（A 段那条只断言接线），
  归因入口：无专用命令，靠截图对比 —— 别拿 `quality-color-probe` 绿灯当"客户端色一致"的证据。
- [ ] **主菜单**：11 个按钮无暴雪红石头（`128-RedButton-*` 全 alpha 0）、文字 `bright`；
- [ ] **标题线**：已开 **8 个窗口**（2026-11-03 按代码核数，`rule = true` 共 7 个 Dress 位、
  TimeManager 一位带两窗）：`CollectionsJournal` / `EncounterJournal` / `DressUpFrame` / `FriendsFrame` /
  `LootFrame` / `TimeManagerFrame` / `StopwatchFrame`（后两位同一 spec，`ruleTop = 26`，线不穿字形）/
  `HelpFrame`；其余窗口逐个截图确认后再 `rule = true`，标题矩形比字形小的配 `ruleTop`。
- [ ] **inset**：`inset = true` 已接 **43 个 Dress 位**（`grep -c "inset = true" Modules/Skins/*.lua`）；
  开着的窗口看内容区内衬是否 Monet 底衬，不再露暴雪原 inset 板。
- [ ] **血量颜色面板**：两组各一行组名 + `血条` / `空槽（损失部分）` 两个下拉 + 12×12 色块；
  色块颜色 == 条上颜色（`UnitFrames:PreviewColor`）。
- [ ] **背包**：登录不默认打开；战斗里 `/reload` 后脱战自动补齐图标；暴雪背包 `alpha=0` 不与我们同屏。

---

## C2.1 11-03 批次实机验收（`docs/HANDOFF.md` 8.28，15 个视觉 commit）

> 口径：本批数字均在 12.1.5 测得，属**历史证据**——1.60 上逐条复验后才算数。
> 证据账与降级清单见 `docs/HANDOFF.md` **8.29**（A 表＝注释口径，B 节＝✕ 比例自校验缺口 +
> 上线日视觉验收第一优先级 + 无第二样本名单残项 —— 三个残项 11-03 已在主仓 `framexml-source/`
> forever 分支 FrameXML 离线对账命中（对账源身份与逐名结论见 **8.29.2-B3.1**），上线日只对账
**运行期存在性**：VanillaStyle 整包载没载、Classic 还是 Mainline 子目录）。
> 归因入口四个：`/mui skins diagnose`（Need 账本 ✗/✓）、`/mui compat`（客户端差异与 GameRule）、
> `/mui blocks`（机密布尔/事件失败账本）、`/mui restrict`（六类受限窗口 + 被暂停的轮询框）。

- [ ] **全屏 ✕ 统一**（`5bc814e`）：逐窗打开 账号商店 / 商城 / 频道 / 副本 Journal / 团队信息 / 马厩 /
  模型预览 / 教程 / StaticPopup1–4 / 秒表 —— 关闭钮全是细金 `monet_close_*`。
  **基线：12.1.5 全量扫 53 只、21 只已换、32 只仍暴雪原样；通过 = 这 32 只清零。**
  归因：`/mui skins diagnose`（该框有没有被扫到/读到）。
- [ ] **最小化钮不换**（`5bc814e`）：`RedButton-MiniCondense`（减号）保持暴雪原样；收起钮变成 ✕ =
  `CloseButtonByArt` 匹配过宽。归因：截图 + 读 `Utils/Skin.lua` 的排除名单。
- [ ] **✕ 四态无杂方块**（`5f84a93`）：normal / hover / push / **disabled** 四态都是 monet 材质；
  任何一态出现深色方块（暴雪 plate）= 有一态没换。重点看"当下不能关"的面板。归因：`/mui skins diagnose`。
- [ ] **close 字形比例**（`3f2ba5f`）：**11-03 审查收工 · 实物解码实测**。几何四项（bbox `4..27` / 跨度 75% /
  质心 / 四边对称 + alphaMax 255）在 32px 样本上与参考件重合成立；**笔画不成立** —— 占比 **我们 0.125（常数）
  vs 参考件 0.177（= 水平 run 8 ÷ √2 ÷ 32）**，即**参考件粗 ≈41%、我们细 ≈29%**（"细 35–40%"作废；
  **比率两口径并存，11-04 集成道已裁定收口，不是待拍板的矛盾**：① **常数占比口径** `0.177 ÷ 0.125 = 1.416` ⇒ **41% / 29%**
  —— **拍板表第 9 条按它出选项**（要动的就是那两个常数）；② **像素口径**（α≥128 连续段实测）`8 ÷ 6` ⇒ **33% / 25%**
  —— **观感叙述按它**。两者不打架有实测根据：交付件实测 run 恒为设计常数的 **1.5×**（32px 画 4px → run 6；64 mip0 画 8px → run 12），
  ⇒ `0.125 × 1.5 = 0.133` 折回常数轴正好对上，所以像素口径的差天然小于常数口径。**引用时必须标是哪一个口径，不许再出第三个数**
  （单源在 `AGENTS.md`「图标字形按画布比例」条与 `tools/regen-textures.js` 头注段，两处 11-04 起归集成道，本道只对齐不编辑；
  完整账见 HANDOFF 8.26 订正块⑤）。
  同 32px 画布的 run 实测：参考 8 / 我们交付件 6 / 按常数画的源图 5，`runsMid` 12..19 vs 13..18 —— **run 数是像素口径的输入，不是"旁证"，不许与占比混算成第三个数**。账见 HANDOFF 8.26 订正块 / 8.29.1 A8。**六档几何表已判定：12 种显示直径
  （18/20/22/24/28/32 × 1×/2×）全部高于亚像素临界（我们 <8px、参考件 5.66px；最小那档 18px@1 我们仍 2.25px）
  ⇒ 对比页判"不存在亚像素线"，"发虚是被插值抹软"这一候选**在几何层排除**，差值是恒定比例**。
  所以本条实机只剩一个动作：**24px@1 与参考件并排看一眼**（三档遍看降为顺手看）；是否加粗 = PRELAUNCH 拍板第 9 条
  （该表第 8 条是斜纹周期；早前误写"第 8 条"已订正），**几何算不出的四项**（mip 选择 / 双线性软化 / 圆帽端点 /
  DXT5 量化，加本仓 ×2 下 1px 描边奇偶先例）只能实机定。翻转/旋转不差 1px 仍要看。归因（离线）：
  `node tools/audit-pixels.js` + `%TEMP%\opencode\close-compare.png` +
  `docs/texture-preview/andromeda-close-compare.html`（**收工版含第 3 节"线宽→物理像素"六档表与临界判定；
  纯几何推算，非实机渲染**）。
- [ ] **背包总控窗 ✕**（`b0a0ecd` `1d488c6`）：✕ 只在总控窗、点一下关整套、随后**按一次 B 即重开**
  （按两下 = 停车边沿回归）；物品在分类间移动 ✕ 不跳窗；✕ 材质与其它窗口同款、换主题跟主题染色。
  归因：`/mui restrict`（战斗里关背包）+ `/mui blocks`。**commit 自述实机未验，本条首跑重点。**
- [ ] **InfoBar 属性面板 ✕**（`45f5e73`）：点开信息栏"属性"面板，右上角是细金三态、不是暴雪红圆钮。
  归因：`/mui skins diagnose`。
- [ ] **箭头单源与方向**（`44f0253` `ff1bd7c`）：商人 / 邮件 / 拾取 / 物品文本翻页箭头与滚动条上下，
  全部细金 chevron（唯一源 `monet_chevron_up`）；**左右不反**（历史缺陷，`ARROW_ROT` 符号）、
  **不缺箭头**（Strip 无补=箭头消失）。归因：`/mui skins diagnose`。
- [ ] **12.x stepper 滚动条**（`28187aa`）：用 `MinimalScrollBar` / `WowTrimScrollBar` 的窗口（编辑模式
  列表、新版下拉列表）上下钮是 monet 箭头，且**悬停/按下后被暴雪 mixin 的 SetAtlas 顶不回来**；
  覆盖件无形变（18×16 钮上 V 不拉伸）。归因：`/mui skins diagnose` + `/mui blocks`。
- [ ] **纹理漏斗无红字**（`ff1bd7c`）：全天日志里不再出现 `Skin.lua: … bad argument … GetDisabledTexture`
  一类点号调用报错。归因：`/console scriptErrors 1` 或 `wuxian logs`。
- [ ] **Tooltip 法术层级**（`c58fae9`）：悬停法术图标 = 标题奶油亮（highlight）、正文含"使用:"行灰
  （neutral）；神器金 (1,0.9,0.41) 类信息色**不被误灰**。归因：`/mui compat`（对照颜色键只有
  `Widget:PaletteColor` 一张表的口径）。
- [ ] **信息栏归类**（`cd1f6d7`）：盗贼角色属性面板归 **physical**、不是 tank（12.1.5 历史证据：
  classID=4）；面板打开后数字跟 2 秒刷新走、归类字样**不**跟着重算。归因：`/mui blocks`（受限窗口里
  role/属性是机密，重算只会把对的换错）。
- [ ] **LFG 角色图标**（`4de90ad`）：副本查找面板与排队微钮的角色图形是 `monet_role_*` 灰阶；
  **滚动列表复用行之后再看一次**（暴雪会重贴 atlas）。整排 ✗ 时先 `/mui compat` 末段查 1.60 GameRule
  是否禁用副本查找，**别先改名单**。
- [ ] **排队眼睛一条账**（订正口径，见 HANDOFF 8.28.5 与 8.29.2-B5）：`QueueStatusButton` **可见、可点**
  （它只过 `Skin:Need` 进账本、不换肤——若 α0/消失 = `Fade` 类回归复发）＋ **`QueueStatusFrame` 面板边框
  正常**（`System.lua:38/:66` 的 `Dress{panel}` 与 Forever 名单意图重叠，`Strip` 够不到子按钮图标）。
  这两个半句**归为同一条对账项**：眼睛没了查 `Utils/Skin.lua` 的 fade 分派；面板没变查 diagnose 账本（只登记
  不换肤属正常）。
- [ ] **模板账本**（`78c98ab` `23d27d2`）：`/mui skins templates` 四个数 = **387 定义 / 32 运行 /
  5 带指纹 / Camelot override**（离线 `grep -c '^T\[' TemplateDB.lua` 已复核 32、指纹块 5）；
  带片段查询能答"这个控件被认成什么型"。此命令只读账本，不开任何框。
- [ ] **名单一致**（离线，随批复跑）：`node tools/check-frame-list.js` = **385 个名字 / 12 个皮肤文件 /
  7 个 ALLOW_DYNAMIC**，全部有取用路径（2026-11-03 本车道实跑输出）。
- [ ] **姓名板探针六条**（`7108581` + 钩子终判，判据全文 HANDOFF **8.26.8**）：① `taintLog=2` 打一整本，
  `Logs/taint.log` 必须全空（盯 `CompactUnitFrame:1211`/`:668`）；② `ADDON_ACTION_BLOCKED` 计数对比基线
  （进本 9 条应归零）；③ `/mui nameplates probe cvar`；④ 打印 `base:GetChildren()` 真名+alpha
  （定 `FadeBlizzardSiblings` 存废）——**关键判据：④ 名单稳定且 ①② 干净才允许重议 BNP 式钩子**；
  ⑤ 假人切目标 ≤1 拍不回潮 + 关模块后 0.60 距离淡出还原；⑥ `/mui restrict` 暂停清单里姓名板框不常驻。
- [ ] **光环补扫 ticker 起停（P1，11-04 状态 = 已提交 `8e7dd88`、未部署、未实机）**：账见 HANDOFF 8.29.1 **A11** + 其 P1 段。口径先立住：
  **机制已随 `8e7dd88` 入分支 `lane/prelaunch-1105`（本轮三笔 = `8e7dd88` 源码 / `b9c3fc2` tools+harness / `302164d` docs+README，未 push），但 `_forever_` 现部署态仍是 `cd1f6d7`、里面没有它**；
  离线侧 `node tools/test-aura-fit-external.js` = **26/26 全过**（11-04 集成道重跑 + 本车道复现）。⇒ 上线日 OnUpdate/ticker 对比
  **拿它做"改后"基线**（前提：先跑 D-1 那条裸跑部署、`sync-check` in sync 且**部署后**重跑才算数；**部署前那份 `cd1f6d7` = "改前"**），
  对比文字写"**离线断言 26/26 已过，运行期收益待 1.60 首趟量**"，不写"已修好省了多少"。实机四条：
  ① 关 BuffFrame 模块（配置里关）→ `/mui perf` 账本里那条 1s 补扫**不再计活**；再开 → 恢复；
  ② 战斗中把目标换成有 buff 的单位、脱战后换目标：时长字体仍是 Monet 字号（12.1.5 判例"60 个字体串改掉"在 1.60 要重看）；
  ③ 关掉"显示目标光环"开关 → 两组退场、ticker 应摘（`Auras.lua:835`）；④ 目标框与 BuffFrame **都**关掉后不再有空转记录。
  归因：`/mui perf`（**唯一**能看起停的现役命令）；`/mui buffframe probe` 只数 `GetChildren` 个数，**覆盖不到这条**。
- [ ] **运行时表天花板**（`78c98ab` 留档）：`LookupTemplate` 目前最多命中 5 个带指纹模板
  （ColoredProgressBar / BasicHybridScrollFrame / SelectableButton / TemplatedList / MoneyDisplayFrame）；
  识别不上不算 bug，扩覆盖的活是 `tools/extract-templates.js` 补指纹规则。

---

## D. 常用探针（粘进游戏或 `tools.wuxian.run`）

> 铁律：**任何可能机密的值，先 `issecretvalue` 再 `tostring`**；否则 `table.concat` 会抛
> `invalid value (secret)`（这本身也是一条有用的线索）。

**1）安全 tostring**

```lua
local function V(v)
  if v == nil then return "nil" end
  local ok, sec = pcall(_G.issecretvalue, v)
  if ok and sec then return "<SECRET>" end
  return tostring(v)
end
```

**2）脏键扫描（污染第一板斧）**

```lua
local function scan(o, label)
  if type(o) ~= "table" then return label .. "=" .. type(o) end
  local bad = {}
  for k in pairs(o) do
    if type(k) == "string" then
      local ok, secure = pcall(_G.issecurevariable, o, k)
      if ok and secure == false then bad[#bad+1] = k end
    end
  end
  return label .. (#bad == 0 and " clean" or (" DIRTY: " .. table.concat(bad, ",")))
end
return table.concat({
  scan(_G.MinimapCluster, "MinimapCluster"),
  scan(_G.ObjectiveTrackerFrame, "ObjectiveTrackerFrame"),
  scan(_G.NamePlateDriverFrame, "NamePlateDriverFrame"),
}, "\n")
```

**3）玩家光环 dump（buff/debuff 排查）**

```lua
local out = {}
local function V(v) local ok,s=pcall(_G.issecretvalue,v); return (ok and s) and "<SECRET>" or tostring(v) end
for _, f in ipairs({ "HELPFUL", "HARMFUL" }) do
  for i = 1, 30 do
    local ok, a = pcall(_G.C_UnitAuras.GetAuraDataByIndex, "player", i, f)
    if not ok or not a then break end
    out[#out+1] = string.format("%s%d %s dur=%s exp=%s", f, i, V(a.name), V(a.duration), V(a.expirationTime))
  end
end
return table.concat(out, "\n")
```

**4）右侧可见帧清单（找"多出来/对不齐"的框）**

```lua
local found = {}
for k, v in pairs(_G) do
  if type(k)=="string" and type(v)=="table" and v.IsVisible and v.GetWidth then
    local okV, vis = pcall(v.IsVisible, v)
    local okW, w = pcall(v.GetWidth, v)
    local okL, l = pcall(v.GetLeft, v)
    if okV and vis and okW and okL and type(w)=="number" and type(l)=="number" and w > 120 and l > 1400 then
      found[#found+1] = string.format("%s L=%.0f W=%.0f", k, l, w)
    end
  end
end
table.sort(found)
return table.concat(found, "\n")
```

**5）污染日志（第二板斧）**

```lua
-- 只在**加载时**生效：设完必须 /reload
pcall(_G.C_CVar.SetCVar, "taintLog", "2")
```
读完关回：
```lua
pcall(_G.C_CVar.SetCVar, "taintLog", "0")
```
文件：`C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_forever_\Logs\taint.log`
（0 字节 = 这一整段会话没有任何污染事件，是"真干净"而不是"没触发"。）

---

## E. 材质预览（改了贴图时）

```powershell
node tools/regen-textures.js            # 结构性材质（脚本）
node tools/svg-to-tga.js docs/...       # SVG 版（Inkscape → PNG → TGA）
node tools/tga-post.js <png> <tga>      # GIMP 出的图转项目格式（未压缩 32bit TGA + 白衬底）
node tools/audit-pixels.js              # 验收（STENCIL 名单 + 全局白衬底）
start docs\texture-preview.html         # 浏览器里并排比对
```

规则见 `AGENTS.md` 的「材质制作规范」；有 SVG 的以 SVG 为准，不要在生成器里重复画同名纹理。
