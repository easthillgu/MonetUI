-- Utils/Layout.lua
-- 全局贴底基线（UI 单位）。所有"贴着屏幕底"的元素共用这一个数，底边才是真的齐：
--   * 第一动作条（Modules/ActionBars）—— 24 原本就是它用的值，这里只是把它提出来；
--   * 小地图（Modules/Minimap，对齐的是可见面板的底边，内部会实测补偿遮罩/画布的偏差）；
--   * 聊天框（Init.lua 在启动前置阶段把暴雪编辑模式布局的 ChatFrame 底边对齐到本值；
--     Modules/Skins/Social 只美化外观、只对齐高度，不碰位置 —— 见 HANDOFF §3.1 / §8.80）。
-- 2026-11-10：旧注释写「Social 对齐 ChatFrame1 底边」早已失效（贴底因 taint 判例移除），
-- 真实对齐改由 Init.lua 完成。本值由 Init.lua 的 SETUP.bottom 在加载期写回，这里是兜底默认；
-- 要改基线请改 Init.lua 的 SETUP.bottom，别只改这里。

local ADDON_NAME, ns = ...

ns.Layout = {
    -- 31 = 小地图遮罩下裁(33) − 面板内边(2)：画布底正好贴屏幕底，遮罩才是严格 1:1
    -- （被屏幕切过的画布会按可见高度重算遮罩，露出面板底色，见 Modules/Minimap/Minimap.lua 头部）。
    bottom = 31,
}
