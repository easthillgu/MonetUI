# 上线后第一周（2026-11-06 起）——按"触发条件"排，不是按工作量排

来源：开服日 11-05 的两批实机复验（`docs/HANDOFF.md` §8.34–§8.42）与 `docs/VERIFY-1.60-CHECKLIST.md`。
**每一条都写清"什么时候才能做"** —— 开服日没做的，多半是当时的观测条件不具备，不是被忘掉。

## 一、要满级号 / 要 NPC 才能判的（皮肤台账剩下的 64 条在这里收口）

| 触发条件 | 要做的事 | 依据 |
|---|---|---|
| ~~站到**银行 NPC** 前、银行框开着~~ **✅ 2026-11-06 已完成（HANDOFF §8.57）** | ~~`/mui bags probe` 读逐索引行 → 定性 #25 的银行主页索引语义~~ ⇒ 定性结论：`-1` = **Keyring 钥匙扣**、银行存储 = `6..14`（`CharacterBankTab_1..9`）、索引与物理格子 1:1；银行空格已接真槽位，三向拖放实机通过 | §8.57 |
| 同上（银行框开着） | R7.5–R7.11 剩下的三项：**等级数字**、**单套观感**（`/mui bags hidebliz on` 之后看两列是否干净）、**折叠面板**。~~拖放三向~~ + `bagID字段` 已于 11-06 实机通过（§8.57：背→银槽27 / 银槽27→背槽8 / 背→背槽10） | `docs/VERIFY-1.60-CHECKLIST.md`、§8.57 |
| 开到**拍卖师 / 训练师 / 专业导师** | 重跑 `/mui skins diagnose`，判 `auction`(17) / `trainer`(4) / `professions` 剩余项是"没出生"还是"名字错"；要改名先 `/mui compat find <片段>` 扫实名 | §8.40 ③ |
| 能**观察别人**（右键玩家头像） | `inspect`(6) 同一判法 | §8.40 ③ |
| 打孔 / 幻化 / 制造订单 / 日历各自开一次 | `socket`(3) / `transmog`(2) / `craftorders`(2) / `calendar`(3) | §8.40 ③ |
| 开一次**取色窗**（聊天颜色 / 名条颜色） | `colorpicker`(4)：上次扫到的实名只有 `ColorPickerFrame` + `ColorPickerSoftCursor`，按钮是开窗后才建 ⇒ 现在就能判 | §8.40 ③ |
| 开一次**频道设置弹窗** | `chat` 剩 5 条（`ChatChannelManagerPopup*` / `EditChannelPopup`） | §8.40 ③ |
| 等级够开**宏面板 / 飞行图 / 传承** | `macros`(4)、`flightmap`(2)、`legacy` 的实机观感（B 批已把那段"从没跑过的代码"接上，第一次真跑到） | §8.41 |

## 二、不依赖观测条件，排期就能做

- **#26** 追踪器补「任务专用物品」可点钮（`SecureActionButtonTemplate` + 属性，不直调受保护全局）。
  ⚠ 做完 #43 的安全载体之后再动它，别在追踪器上再试第三种写法。
- **#41** 皮肤点名：A/B 两批已落（名单 374 → 283，台账 176 → 64 缺失），剩下的全部进上面那张表 —— 
  **口径不变：改名字要"实机 find 实名 + 窗口真开过仍 ✗"两样齐**，只有一样就写"待实机"。
- **#42** `Utils/Scheduler.lua` 的计时源换 `debugprofilestop`（1.60 实测存在、毫秒带四位小数），
  让 `/mui perf` 真能排序找最贵的一路。改动在每拍热路径上，要小步 + 战斗内外各验一遍。
- **#43** "点一格开面板"的合法载体。**已收口（11-06）：微菜单那一半完成并转正（HANDOFF §8.63），
  信息栏那一半判定为机制互斥、明确不做（AGENTS 已写死判据，§8.64）** —— 剩下的只是复验/微调，不要再开第三条写法。
  已经实测清楚的约束：
  ① 调暴雪 Lua 全局 = 一屏红字（id 1441）；
  ② 安全模板锚到"我们要重排版的框" = 框被标成受保护、`SetPoint` 静默丢弃
     （`IsProtected()=true` + `GetNumPoints()=0`）⇒ 载体必须**一次建好、之后只换属性不换锚点**；
  ③ 本客户端只有 `C_Map.OpenWorldMap` / `C_Calendar.OpenCalendar` /
     `C_TradeSkillUI.OpenTradeSkill` / `C_SettingsUtil.OpenSettingsPanel` 这几个纯 C_* 开口；
  ④ **代点写法已钉死**（两条都会静默失效）：委托属性名是 `clickbutton`（不是 `click`），
     并且必须 `RegisterForClicks("AnyDown","AnyUp")`（本机 `ActionButtonUseKeyDown=1`，只注册 Up 会被算成"释放"）；
  ⑤ **不是所有暴雪按钮都吃脚本化点击**：`MainMenuMicroButton`（游戏菜单）放行值全对仍零反应 ⇒ 那颗放弃；
     实测能代点的有 **10 个**：角色 / 专业 / 法术书 / 天赋 / 任务日志 / 公会 / 查找队伍 / 收藏 / 帮助 / 商店
     （`LegacyMicroButton` 在 18 级 `IsEnabled()=false`，高等级要复验）。
  ⇒ 信息栏那一格不要另起第三种写法，直接复用 `MicroMenuSecure.lua` 的形状（一次建 + 活锚点 + 属性单换）；
     **也不要在信息栏的重排路径上重试**（§8.37 就炸在那儿）。
- **#28** 共存归因做成产品能力：模块注册表声明 `conflicts / needs`，被接管时自静默并在
  `/mui report` 出一行"**谁在动受保护框**"（读 `Logs/taint.log` 或现场 `issecurevariable`，只读、不碰别人的框）。
  开服日已经拿到第一例硬数据：`RurutiaSuite/Modules/MinimapCollector` 按 `_G.Minimap` 子树收养按钮，
  把我们的命中层搬成 `0×0`（右键 / 滚轮 / 悬停三条一起哑、零红字）；10:00 之后 taint.log 里
  `tainted by RurutiaSuite` 3898 条、`TweaksForever` 3、`OpenMap` 2，**栈里出现 MonetUI 的行 = 0**。

## 三、发布与仓库（作者手动，不由车道执行）

- 远端 `origin` 仍是**私有备份**：本周不 push、不发 Release，除非你决定转公开。
  转公开等于正式发布，需要你自己手动做，并复核仓库仍是 private 直到那一刻。
- 转公开前要核对的两件事：① `Assets/Fonts/NOTICE.md` 与**随包的 `THIRD-PARTY-NOTICES.txt`**
  口径一致（11-05 已订正：点阵苹方作者已授权再分发，随包只有三份字体，候选件不进包）；
  ② README 的 `Status` 徽章已改成"1.60 实机已验"，玩家可见的限制清单在 README「⚠️ 状态」一节里。
- `docs/` 是否入 git：§5 第 5 条已拍 C（不入），靠仓外快照
  `C:/Users/EastHillGu/Documents/wowaddonsdev/MonetUI-prelaunch-1104/` 兜底 —— 若要改主意，
  动作是把这几行加进 `.gitignore` 白名单并单独一笔提交。

## 三·五、待实机欠账（2026-11-06 起，作者说"先放着，处理别的"）

代码已入库、已部署、闸门全绿，但**只有实机能判**，别当"已验"：

| # | 要验的事 | 判据（客观数字，不看"看着正常"） | 状态 |
|---|---|---|---|
| W1 | `bank:free` 标题行两颗钮（`一键存入` / `栏位管理`） | `/mui bags layout` 读两行 `标题钮…：显示=true · 鼠标=true · 父=bank:free`；点「一键存入」必须有回执行（调用=成功/失败 + 画出 N→M）；点「栏位管理」⇒ `BankFrame` 变 `alpha=1 · 鼠标=true` | 未验 |
| W2 | 单行口径下的「背 → 银第一行」拖放 | 银行 `6` 件数 +1、背包对应索引 −1、且**新占用槽号 = 你落的那一格**（首格 `slot=27`） | 未验（上一趟实测到的是反方向：银→背） |
| W3 | 空仓库时标题行保留（`keepTitle`） | 银行 48/48 满或数据没跟上时，`bank:free` 仍显示、高度 = `TITLE_H+PAD`、两颗钮可点 | 未验 |
| W4 | `hidebliz off` 的持久化（默认值是 `true` 之后新引入的风险） | `/mui bags hidebliz off` ⇒ `接管=false · alpha=1`；**再重载一次**仍 `alpha=1`（写的是显式 `false`，不是删键） | 未验 |

## 四、验收节奏（别一次性做完）

每完成一项就：`luac -p` → `api-audit` → `audit-taint` → `audit-locals` → `check-frame-list` →
七条探针 → `harness/run.js`（+ `--selftest`）→ 双部署 + `sync-check` → **本地 commit**，
然后**只有改到实机才观测的那一条**才算"过"。改了 Lua 却只看闸门绿，等于没验（开服日两次都是
离线闸门把我救回来的，反过来说：闸门绿不覆盖的那条路径，必须显式说"没有证据"）。
