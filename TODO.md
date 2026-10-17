# 待办

## ✅ 2026-10-18 修复批次（离线验证完成，待实机复核）

1. ✅ `Utils/EventBus.lua` — `Unregister`/`UnregisterAll` 递减 `unitSets` 引用计数；归零收缩 `RegisterUnitEvent` 过滤集，全空则整体注销并清 `registered`（新增 `ResyncUnitFilter`）。
2. ✅ `Modules/Bags/Bags.lua` — 删除从未接线的 `pool`/`ReleaseButtons`（按钮本就按 `win.buttons` 每窗缓存复用，无泄漏）与未用常量 `BAG_BACKPACK`/`ACCOUNT_TABS`（切片 2 账号银行页 bagID 15–23 用时再加）；`AcquireButton` 展平。
3. ✅ `Modules/Nameplates/Nameplates.lua` — `UpdateHealth` 5 处 unit 调用全部过 `Query`；查询失败跳过 `SetBar`（保留上次状态，防 nil 把范围打到 0–100）；断连查询失败按"已连接"处理（`Bool(nil,true)` 原会错算为断连）。
4. ✅ `Utils/Skin.lua` — CloseButton 改冒号调用（hated-wow 证据：暴雪 2871 个实装 Lua 文件点号调用 0 处）；删只写不读的 `__monetThumbHover`；`Skin.added` 逐点核对**全部有缓存守卫、开关不重复登记，判定无缺陷未改**。
5. ✅ `Core.lua`/`Config/SimpleConfig.lua` — 删死配置 `theme.tintBlizzard`；面板 `MODULE_ORDER`/`MODULE_LABEL` 补 `Bags`（分类背包）；`UnitSetting` 改 `~= nil`（`false` 可存）；OnHide 挂钩加 `__monetHideHook` 幂等守卫。

## 工具

- ✅ hated-wow-mcp 已接入 `opencode.json`（20 工具）：forever API 索引随包可用；Blizzard UI 源码已同步（4481 文件/349 包）。分工：**wuxian 管实机，hated-wow 管离线查证**。
- 游戏数据（FileDataID/图集）未建；需要时先开浏览器访问 wago.tools 过反爬，再 `npx -y hated-wow-mcp sync game-data`。

## 实机验证清单（游戏上线后）

- 材质：MULT 边框恒 1 物理像素；柔影方向（渐变反了会像外发光）；呼吸节奏；角饰/笔触位置。
- 背包：`/mui bags` 平铺、银行页、tooltip 品质光晕、品质边框（灰/粗糙归暗、任务琥珀）。
- 任务追踪：256 宽换行、3 行硬切、折叠按钮、暴雪追踪器压制；`GetQuestObjectives` 字段（进度不显示回报字段名）。
- 本批修复：反复开关皮肤模块确认 `added` 无重复；受限状态姓名板血条保留上次值；配置面板"分类背包"勾选框生效；多开配置面板关闭无异常。
- 小控件：滚动条拇指材质/悬停提亮；滑条（首个实例出现时）。

## 未决

- `Minimap.lua` 2 处 `global-write` 警告（`GetMinimapShape` 故意写全局）是否处理。
- Bags 实机验证通过后退役旧 `BagFrame` 模块（面板同步移除其条目）。
- `Skin:Divider` 零调用孤儿函数（调查中发现，不在批准清单，未动）。

## 备注

- 注释清理前基线备份：`%TEMP%\opencode\comment-cleanup-backup`（29 文件，可逐文件回滚）。
- 仓库约定：游戏正式上线且初步测试通过前，不向远端推送。
