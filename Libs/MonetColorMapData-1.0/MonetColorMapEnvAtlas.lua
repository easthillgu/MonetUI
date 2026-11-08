-- Libs/MonetColorMapData-1.0/MonetColorMapEnvAtlas.lua
-- 由 wuxianwow atlas 官方区域地图贴图提取的「区域环境色」覆盖层（全部 17 区域）。
-- 生成: python3 gen_atlas_env.py (源 color_lib_v2.json)
-- 数据源: wuxianwow.com/data/maps/<id>.webp (17 区域官方地图美术贴图)
--   像素分析: 步长16量化 + 明暗[l∈0.05,0.95]/灰度[s≥0.015]过滤 -> 过滤后均值RGB的HSL
--
-- 覆盖机制: RegisterMapEnv 为最高优先级覆盖层，会顶掉 MonetColorMapData-1.0.lua 中同名区域的实测值。
-- 色源优先级（2026-11-08 拍板）：官方地图贴图 > wuxianwow/trip > 自己的游戏截图。
-- 3D trip 出图（2026-11-08 下午，见 HANDOFF §8.68）：站点与 /mcp 端点经本地代理可达，
--   MCP trip 只给链接不渲染图片；用户开启浏览器控制后用 WorkBuddy 内置浏览器渲染 WebGL 场景，
--   按「风景模式 → 快门 → 保存原图」补全 7 个原先走 game 色的区。贴图层仍是最高优先级、
--   覆盖 17 区不变；补拍只影响未被贴图覆盖的区域。幽暗城 1458 的 trip 取点落在洛丹伦废墟
--   地表而非地下城内部，语义不符，有意保留 game 色。出图账见 monetcolors/data/trip_sources.json。
-- 地图美术是风格化土黄色调(h 32-51 高度一致)。
--   按指令，原游戏截图核定的 6 个区域(灰谷/菲拉斯的绿、泽风岛的粉等)也已统一改用地图贴图色源升级。
--   升级对照(旧截图值 -> 新地图贴图值)见文末注释，以便回溯。
-- 生成时间: 2026-11-08  注册区域数: 17

-- 取引擎实例：同 MonetColorMapEnvOverride.lua 的双通道查法
local LibStub = _G.LibStub
local LMC
if type(LibStub) == 'table' then
    local ok, lib = pcall(LibStub, 'LibMonetColor-1.0', true)
    if ok and type(lib) == 'table' then LMC = lib end
end
if type(LMC) ~= 'table' then LMC = _G.LibMonetColor end
if not (LMC and type(LMC.RegisterMapEnv) == 'function') then return end

-- mapID -> { name, h, s, l }；数值口径与生成文件一致（h [0,360]、s l [0,1]）。
local ATLAS_ENV = {
    [1411] = { name = '杜隆塔尔', h = 35.1, s = 0.431, l = 0.386 },
    [1412] = { name = '莫高雷', h = 43.3, s = 0.494, l = 0.410 },
    [1413] = { name = '贫瘠之地', h = 38.7, s = 0.560, l = 0.381 },
    [1438] = { name = '泰达希尔', h = 42.6, s = 0.408, l = 0.373 },
    [1439] = { name = '黑海岸', h = 42.5, s = 0.447, l = 0.379 },
    [1440] = { name = '灰谷', h = 45.1, s = 0.577, l = 0.353 },
    [1441] = { name = '千针石林', h = 36.3, s = 0.528, l = 0.435 },
    [1442] = { name = '石爪山脉', h = 32.8, s = 0.575, l = 0.369 },
    [1443] = { name = '凄凉之地', h = 39.8, s = 0.319, l = 0.418 },
    [1444] = { name = '菲拉斯', h = 44.0, s = 0.472, l = 0.341 },
    [1445] = { name = '尘泥沼泽', h = 38.0, s = 0.435, l = 0.379 },
    [1446] = { name = '塔纳利斯', h = 35.9, s = 0.371, l = 0.438 },
    [1447] = { name = '艾萨拉', h = 35.2, s = 0.430, l = 0.366 },
    [1448] = { name = '费伍德森林', h = 39.4, s = 0.537, l = 0.360 },
    [1449] = { name = '安戈洛环形山', h = 45.3, s = 0.570, l = 0.322 },
    [1450] = { name = '月光林地', h = 51.4, s = 0.358, l = 0.345 },
    [2521] = { name = '泽风岛', h = 42.6, s = 0.273, l = 0.431 },
}

for mapID, entry in pairs(ATLAS_ENV) do
    LMC:RegisterMapEnv(mapID, entry.h, entry.s, entry.l, entry.name)
end

--[[ 升级对照(旧游戏截图 h,s,l -> 新官方地图贴图 h,s,l):
  [1413] 贫瘠之地: (47.0, 0.298, 0.395) -> (38.7, 0.560, 0.381)
  [1440] 灰谷: (149.4, 0.539, 0.256) -> (45.1, 0.577, 0.353)
  [1441] 千针石林: (25.4, 0.39, 0.403) -> (36.3, 0.528, 0.435)
  [1444] 菲拉斯: (111.5, 0.418, 0.18) -> (44.0, 0.472, 0.341)
  [1446] 塔纳利斯: (12.3, 0.322, 0.42) -> (35.9, 0.371, 0.438)
  [2521] 泽风岛: (331.8, 0.139, 0.408) -> (42.6, 0.273, 0.431)
]]

