-- Utils/Layout.lua
-- 全局贴底基线（UI 单位）。所有"贴着屏幕底"的元素共用这一个数，底边才是真的齐：
--   * 第一动作条（Modules/ActionBars）—— 24 原本就是它用的值，这里只是把它提出来；
--   * 小地图（Modules/Minimap，对齐的是可见面板的底边，内部会实测补偿遮罩/画布的偏差）；
--   * 聊天框（Modules/Skins/Social，对齐 ChatFrame1 的底边）。
-- 改这一个数，三处一起动，不用再各调各的近似值。

local ADDON_NAME, ns = ...

ns.Layout = {
    -- 31 = 小地图遮罩下裁(33) − 面板内边(2)：画布底正好贴屏幕底，遮罩才是严格 1:1
    -- （被屏幕切过的画布会按可见高度重算遮罩，露出面板底色，见 Modules/Minimap/Minimap.lua 头部）。
    bottom = 31,
}
