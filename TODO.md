# 待办（2026-10-17 收尾基线）

## 明日修复候选（全仓注释清理时发现，均未改动）

1. `Utils/EventBus.lua` — `Unregister`/`UnregisterAll` 不减 `unitSets` 引用计数，之后 `RegisterUnit` 会带着已无人监听的 unit 重复注册过滤器（泄漏）。
2. `Modules/Bags/Bags.lua` — `pool`/`ReleaseButtons` 是死代码（没人往 pool 里回收，按钮只增不减）；`BAG_BACKPACK`/`ACCOUNT_TABS` 未使用（账号银行页扫描属背包切片 2）。
3. `Modules/Nameplates/Nameplates.lua` — `UpdateHealth` 裸调 `UnitHealth`/`UnitHealthMax`/`UnitIsDeadOrGhost`/`UnitIsConnected`，与本文件 `Query()`（pcall）防战斗拒绝的约定不一致。
4. `Utils/Skin.lua` — `Skin.added` 反复开关模块只增不清；`__monetThumbHover` 只写不读（死标志）；CloseButton 里 `GetHighlightTexture` 用点号调用，与 544/546 行"点号判断+冒号调用"写法不一致（配置面板实测可用，疑似客户端容忍 nil self——修前先实机确认）。
5. `Core.lua` / `Config/SimpleConfig.lua` — `theme.tintBlizzard` 默认值全仓无读取点（死配置）；面板 `MODULE_ORDER`/`MODULE_LABEL` 缺 `Bags` 条目（背包只能 `/mui bags` 开关）；`UnitSetting` 的 `if value then` 会跳过存为 `false` 的值；面板 OnHide 的 `CloseDropdown` HookScript 每建下拉叠加一次（幂等，影响小）。

## 实机验证清单（游戏上线后）

- 材质：MULT 边框在当前缩放下是否恒为 1 物理像素；柔影方向（4 条渐变 min/max 若反了会像"外发光"）；呼吸节奏；角饰/笔触位置。
- 背包：`/mui bags` 平铺、银行页、tooltip 品质光晕（有 backdrop 才生效）、品质边框（灰/粗糙归暗、任务琥珀）。
- 任务追踪：256 宽换行、3 行硬切、折叠按钮、暴雪追踪器压制；`GetQuestObjectives` 实际字段名（若进度数字不显示，回报字段名即可修）。
- 小控件：滚动条拇指材质与悬停提亮；滑条（首个实例出现时）。

## 备注

- 注释清理前的完整基线备份：`%TEMP%\opencode\comment-cleanup-backup`（29 个文件，可逐文件回滚）。
- 仓库约定：游戏正式上线且初步测试通过前，不向远端推送。
