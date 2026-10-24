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

# 3) 有 wuxian MCP 时（0 error 0 warning 才算完）
#    tools.wuxian.check({ target = "MonetUI", live = false })
```

改了材质还要跑：

```powershell
node tools/audit-pixels.js     # 2 的幂 / 纯白衬底 / 染色模具无色相
```

---

## B. 部署 + 实机（有 wuxian MCP 时）

```
tools.wuxian.status()                              # link.state 必须是 online
powershell -File tools/deploy-retail.ps1           # 拷文件 + 按客户端改写 toc 的 Interface
tools.wuxian.check({target="MonetUI", live=true})  # 再确认一次
tools.wuxian.reload({reason="一句话说明这次改了什么"})   # 弹按钮，玩家点
tools.wuxian.logs({since=0, limit=300})            # 看 ERR / BLOCKED
tools.wuxian.snap({region={0,0,400,200}})          # 截图核对视觉
```

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
- [ ] 无新增 `taint.log`（见 D-5）

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
文件：`C:\Users\EastHillGu\Documents\Blizzards\World of Warcraft\_retail_\Logs\taint.log`
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
