-- Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua
-- MonetColorMapData 的**运行时补充行**（大陆层 / 世界层），经 LibMonetColor 的 override 通道注册。
-- 生成：node tools/map-env-derive.js --emit Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua
-- 数据源：monetcolors data/game_palette_v1.json（14 个区域 39 张截图的已提取环境色）—— 本仓只读它，不回写。
--
-- 和 MonetColorMapData-1.0.lua（AUTO-GENERATED，手改会被下一次生成覆盖）的分工：
--   生成文件 = 逐区**提取**色；本文件 = 父层**派生**色（成员区 env 的圆均值 + 算术均值）。
--   引擎解析序 override -> data -> C_Map 父链 -> fallback（LibMonetColor:580-611），
--   所以父层行只作为**别人的祖先**被查到，绝不顶掉任何一条实测区域色。
--
-- 已知未核项：成员归属按经典大陆划分，1.60 的 parentMapID 没有离线数据源，待实机核
--   （tools/map-env-coverage.js --dump 能吃实机导出的父链表）。

-- mapID -> { name, h, s, l }；数值口径与生成文件一致（h [0,360]、s l [0,1]）。
local OVERRIDE = {
    [947] = { name = '艾泽拉斯', h = 81.5, s = 0.385, l = 0.339 }, -- 派生自 25 个成员区（色相集中度 0.513）
    [1414] = { name = '卡利姆多', h = 65.3, s = 0.443, l = 0.316 }, -- 派生自 13 个成员区（色相集中度 0.612）
    [1415] = { name = '东部王国', h = 111.2, s = 0.34, l = 0.36 }, -- 派生自 11 个成员区（色相集中度 0.578）
}

-- 取引擎实例：Libs.xml 里本文件排在 LibMonetColor-1.0 之后，正常一定拿得到。查法照引擎
-- 自己的双通道（LibStub 表 → 全局别名 _G.LibMonetColor，见 LibMonetColor:542-557 与 :1143），
-- 所以离线 tooling 里 dofile 也接得上；都拿不到（别人裁掉了引擎 / 加载序被改）就整文件
-- 静默跳过，行为退回「没有父层行」。
local LibStub = _G.LibStub
local LMC
if type(LibStub) == "table" then
    local ok, lib = pcall(LibStub, "LibMonetColor-1.0", true)
    if ok and type(lib) == "table" then LMC = lib end
end
if type(LMC) ~= "table" then LMC = _G.LibMonetColor end
if not (LMC and type(LMC.RegisterMapEnv) == "function") then return end

-- 一条一行：RegisterMapEnv 自己会 ClearCache + Refresh（LibMonetColor:819-841）。
-- 本文件在 Libs 组、Core 之前加载，那一刻还没有人订阅引擎回调，所以这几次刷新
-- 只是重算一遍缓存，不会广播重涂。
for mapID, entry in pairs(OVERRIDE) do
    LMC:RegisterMapEnv(mapID, entry.h, entry.s, entry.l, entry.name)
end

