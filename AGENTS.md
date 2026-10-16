# MonetUI 项目约定

WoW Forever 客户端插件（Interface 16001，Lua 5.1）。以下为硬性约定，违反即为缺陷。

## 验证（减错核心）

- 每次改完 Lua/TOC：跑 `tools.wuxian.check`（离线用 `live: false`），0 错误 0 警告才算完成。
- 帧名/对象名永不凭记忆、也不照抄参考插件：一律 `_G` 护卫查找 + 登记进面板 `frames` 名单，实机用 `/mui skins diagnose` 复核。
- 客户端 API 以 wuxian `api_search` / `api_get`（官方手册）为准，不凭旧知识下结论。
- 游戏在线时走 `/verify` 实机清单（小地图还原、威胁发光、新皮肤帧名）。

## 安全边界

- 参考插件 Andromeda / EllesmereUI **只读**（opencode.json 已 deny edit），仅作学习素材。
- 资源全部自绘，不引外部贴图与第三方库（防 GPL 污染）。
- 访问 Blizzard 帧做存在性 / pcall 防护；失败一次性 print 警告，不刷屏。
- secure 元素（微按钮等）战斗中禁改：`InCombatLockdown()` 防护 + `PLAYER_REGEN_ENABLED` 一次性重试。
- 秘密值：数值上下文用 `Secrets.Number` 包裹，受限时保留上次状态。

## 代码风格

- 皮肤包用 `M:Panel(key, { ... })` 注册；窗口统一 `M:SkinWindow`。
- OnShow 重涂一律走 `M:HookShow`（引擎带幂等守卫），调用处勿自行 `HookScript("OnShow")`。
- 高频事件用 `M:Debounce`；LoD 窗口在面板声明 `addons = { ... }` 门控。
- 小步改动、可回滚；不顺手重构无关代码。

## 工作习惯

- 挖参考插件派 `explore` 子代理，只取结论进主上下文。
- 大段输出先 `grep` 定位、再定点 `read`（offset/limit 分页），避免整文件读入。
- 重复流程用 `/check`、`/verify` 命令，不重新口头描述。
