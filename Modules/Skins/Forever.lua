-- Modules/Skins/Forever.lua
-- WoW Forever 专属窗口：复古查找组（LFGParentFrame）、传承进度（LegacySystemFrame）、微菜单（MicroMenu）——零售 UI 没有，普通皮肤包够不到。
-- 帧名取自本客户端的实机皮肤代码（EllesmereUI 的 *Forever 文件），并全部登记进各面板的 frames 名单，可用 `/mui skins diagnose` 复核。

local ADDON_NAME, ns = ...

local M       = ns.Skins
local Skin    = ns.Skin
local Widget  = ns.Widget
local Secrets = ns.Secrets
local Color   = ns.Color
local Mark    = function(o, k, v) return ns:Mark(o, k, v) end
local Marked  = function(o, k) return ns:Marked(o, k) end

--- 战斗中为真。**优先问 Core 的 `ns:InCombat()`**：本客户端先派发 PLAYER_REGEN_*、之后才翻
--- `InCombatLockdown()`，而 `ns:AfterCombat` 的排空就跑在那次派发里（微按钮换皮就是排队的）。
local function InCombat()
    if type(ns.InCombat) == "function" then return ns:InCombat() end
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

-- The two Forever windows carry gold "side tabs" (LFG 的列表/浏览/谁在找, 传承进度的三个页签): the ornate gold frame and glow go, the icon stays.
local function SideTab(tab)
    if not tab then return end
    if tab.Background then Skin:Fade(tab.Background) end
    if tab.TabGlow then Skin:Fade(tab.TabGlow) end
    Skin:FadeButtonArt(tab)
end

local function SideTabs(parentPath, names)
    for i = 1, #names do
        -- 成员访问也走点路径：这样每一个页签都被记进账本，写错的名字会在 diagnose 冒出来。
        SideTab(Skin:Need(parentPath .. "." .. names[i]))
    end
end

local LFG_VIEWS = {
    "LFGBrowseFrame", "LFGListingFrame", "LFGWhoListFrame",
    "LFGListingFrameCategoryView", "LFGListingFrameActivityView",
    "LFGListingFrameLockedView",
}
local LFG_BUTTONS = {
    "LFGBrowseFrameSendMessageButton", "LFGBrowseFrameGroupInviteButton",
    "LFGListingFrameBackButton", "LFGListingFramePostButton",
    -- 浏览页的辅助按钮 / 顶栏下拉 / 父框关闭：全部按全局实名登记，写错就在 diagnose 冒 ✗。
    "LFGBrowseFrameRefreshButton", "LFGBrowseFrameOptionsButton",
    "LFGParentFrameCloseButton",
}
local LFG_TOP_TABS = { "LFGParentFrameTab1", "LFGParentFrameTab2", "LFGParentFrameTab3" }
local LFG_DROPDOWNS = { "LFGBrowseFrameCategoryDropdown", "LFGBrowseFrameActivityDropdown" }
local LFG_SIDE_TABS = { "ListingTab", "BrowsingTab", "WhoListingTab" }

-- QueueStatusButton 是排队状态那枚小眼睛的宿主：属于 Blizzard_QueueStatusFrame，不是本面板的
-- LoD 门管；这里登记只为让 diagnose 能扫到，读不到就落空一行 —— **只进账本，不换肤**。
local LFG_QUEUE = { "QueueStatusButton" }

-- 暴雪的角色图标走图集（atlas）：LFGBROWSE_GROUPDATA_ATLASES 那张表是 Browse.lua 的
-- **local**，外面根本拿不到；行模板又是 ScrollBox 复用的，直接改表 = 下一次滚回来又被
-- 暴雪的 SetAtlas 顶回去。可行的入口只有"逐贴图看 atlas 名，命中就 SetTexture 换成我们的文件图"。
--
-- **不 hooksecurefunc 暴雪方法、不 HookScript 暴雪框**（AGENTS：写过一次 = 这个框之后
-- 全被记在 MonetUI 名下）。走轮询：`Widget:PollWatch` 只在框可见时按拍跑，隐藏时一秒都不多花。
-- 换过一次之后贴图 GetAtlas 会返回 nil —— 下次扫描自然跳过；暴雪复用行重新贴 atlas 时命中，
-- 我们再换回来。所以不需要旁表标记，也不要往贴图写字段。
local ROLE_ATLASES = {
    ["groupfinder-icon-role-large-tank"] = "monet_role_tank",
    ["groupfinder-icon-role-large-heal"] = "monet_role_heal",
    ["groupfinder-icon-role-large-dps"]  = "monet_role_dps",
    ["groupfinder-icon-role-micro-tank"] = "monet_role_tank",
    ["groupfinder-icon-role-micro-heal"] = "monet_role_heal",
    ["groupfinder-icon-role-micro-dps"]  = "monet_role_dps",
    -- 复古组队窗**列表自己**那三颗圆形职责钮：glyph 画在 85×85 的 `UI-LFG-RoleIcon-*`
    -- 图集里（64×64 那两张是通用光泽/底，没有 atlas），金圈则是同族的 `-Background`。
    -- 换成我们自己的职责剪影；换完标 `art`，后面的美术褪色遍历就不会再压掉它。
    ["UI-LFG-RoleIcon-Tank"]   = "monet_role_tank",
    ["UI-LFG-RoleIcon-Healer"] = "monet_role_heal",
    ["UI-LFG-RoleIcon-DPS"]    = "monet_role_dps",
    -- 向导 / 队长：`UI-LFG-RoleIcon-Leader` 是「新手友好」钮那颗 84×84，
    -- `groupfinder-icon-leader` 是浏览行里每支队伍前面的小队长徽记（实机 ×5）。
    ["UI-LFG-RoleIcon-Leader"] = "monet_role_leader",
    ["groupfinder-icon-leader"] = "monet_role_leader",
}
local ROLE_GLYPH_ATLAS = {
    ["UI-LFG-RoleIcon-Tank"] = true, ["UI-LFG-RoleIcon-Healer"] = true,
    ["UI-LFG-RoleIcon-DPS"] = true, ["UI-LFG-RoleIcon-Leader"] = true,
}

-- 深度上限：LFGParentFrame → LFGBrowseFrame → ScrollBox → row → DataDisplay → Enumerate → IconN
-- 已经 6 层；再深就到 Tooltip / VoiceChat 那种"我们的手够不着"的子树，收手。
local LFG_WALK_MAX_DEPTH = 7

local function SwapRoleAtlas(tex)
    if not tex or type(tex.GetAtlas) ~= "function" then return end
    if type(tex.SetTexture) ~= "function" then return end
    local okA, atlas = pcall(tex.GetAtlas, tex)
    if not okA or type(atlas) ~= "string" then return end
    local key = ROLE_ATLASES[atlas]
    if not key then return end
    local Media = ns.Media
    if not Media or type(Media.Texture) ~= "function" then return end
    local path = Media:Texture(key)
    if type(path) ~= "string" then return end
    -- SetTexture 会把图集整段清掉，之后 GetAtlas 返回 nil —— 下一次轮询直接跳过；
    -- 暴雪复用行、重新 SetAtlas 之后我们才再换一次。
    if pcall(tex.SetTexture, tex, path) then
        if type(tex.SetTexCoord) == "function" then pcall(tex.SetTexCoord, tex, 0, 1, 0, 1) end
        -- **自己压过的那张要复活**：`SetTexture` **不带 alpha** —— 我们的美术褪色遍历
        -- （force 那一趟会走到隐藏页上的职责图集）若先把这张压成 α0，换图之后它仍然是 α0，
        -- 图标看着"没了"（11-14 实机回归）。只在带 `hidden` 标记时复活 —— 那是我们自己压的；
        -- 别的 alpha 一律不动（暴雪自己压暗的图不能被我们点亮）。
        if Marked(tex, "hidden") then
            Mark(tex, "hidden", nil)
            pcall(tex.SetAlpha, tex, 1)
        end
        -- 换上去的就是我们的图：标 `art` 让 `Skin:Fade` / `Strip` / 下面那趟美术褪色
        -- 一律跳过（否则 85×85 的职责图标会被当成"暴雪美术"压掉）。
        Mark(tex, "art", true)
        if ROLE_GLYPH_ATLAS[atlas] then
            pcall(tex.SetSize, tex, 52, 52)
            local r, g, b = Color:GetBorder()
            pcall(tex.SetVertexColor, tex, r, g, b)
        end
    end
end

local function WalkSwapRole(frame, depth)
    if not frame or depth > LFG_WALK_MAX_DEPTH then return end
    -- 不可见 / 读不出可见性 = forbidden 对象，整棵子树放手。
    -- `IsVisible()` 在本客户端可能回**机密布尔**，裸真值测试会被拦成 UNKNOWN() ⇒ 一律过 Secrets.Bool。
    local okV, visible = pcall(function() return frame:IsVisible() end)
    if not okV or not Secrets.Bool(visible, false) then return end

    if type(frame.GetRegions) == "function" then
        local okR, regions = pcall(function() return { frame:GetRegions() } end)
        if okR and type(regions) == "table" then
            for i = 1, #regions do SwapRoleAtlas(regions[i]) end
        end
    end
    if type(frame.GetChildren) == "function" then
        local okC, kids = pcall(function() return { frame:GetChildren() } end)
        if okC and type(kids) == "table" then
            for i = 1, #kids do WalkSwapRole(kids[i], depth + 1) end
        end
    end
end

-- --- 复古组队窗的内部件（11-14 实机补）---------------------------------------
-- 作者报「只美化到了 close 按钮」：账本 24 个名字全部命中、面板确实 Apply 过，
-- 但可见的暴雪美术全挂在**孙级匿名子框**里 —— `LFGParentFrame` 自己 regs=0，
-- `LFGListingFrame` 自己那 2 张 region 压掉了，它下面 18 个子帧（458×535 金属窗框、
-- 454×102 职责条底、450×414 内容底、4 行 418×67 分类按钮…）一张都没被碰过。
-- 根因：`Skin:Strip` 只压宿主自己的 region，`M:SkinButtonsIn` 默认 depth=1。
--
-- 口径参照只读参考件 `EllesmereUIBlizzardSkin_GroupFinderForever.lua`（`LFG_FADE` /
-- `BorderContent`）：分类行的 `groupfinder-button-dungeons` 等**横幅是内容图，留着**，
-- 要剥的是同族三层 `groupfinder-button-cover*` 金框 + 金属窗框 + 内容底 + 侧页签金圈。
-- 做法与 `Social.lua` 名册窗同族：**轮询 + 自建子框体**，不 HookScript / hooksecurefunc、
-- 不往暴雪对象写字段；`FadeHold` 每趟复写 α0（暴雪会把贴图抬回来）。
local LFG_ART = {
    "^groupfinder%-button%-cover",
    "^groupfinder%-background", "^groupfinder%-roles%-background", "^groupfinder%-stat%-stonebg",
    "^common%-insideframe", "^common%-framedivider",
    "^common%-button%-", "^common%-dropdown%-",
    "^ui%-frame%-", "^_ui%-frame%-", "^!ui%-frame%-",
    "^gamepad%-uiframemetal", "^toptilestreaks",
    -- **只收职责钮的"金圈底"，不收 glyph**：`UI-LFG-RoleIcon-Tank-Background` 是那圈金边，
    -- 而 `UI-LFG-RoleIcon-Tank` 本身**就是那个职责图标**（要换成我们自己的）。
    -- 曾经用 `^ui%-lfg%-roleicon%-` 一把收掉两样 ⇒ 图标本体被压成 α0，
    -- 而换图只在可见页跑（`SetTexture` 不带 alpha），窗口打开时图标再也回不来（11-14 回归）。
    "^ui%-lfg%-roleicon%-.*%-background$",
}
local function IsLfgArt(atlas)
    if type(atlas) ~= "string" then return false end
    local low = atlas:lower()
    for i = 1, #LFG_ART do
        if low:find(LFG_ART[i]) then return true end
    end
    return false
end

local function Num(obj, method, fallback)
    if not obj or type(obj[method]) ~= "function" then return fallback or 0 end
    local ok, v = pcall(obj[method], obj)
    if ok and type(v) == "number" then return v end
    return fallback or 0
end
local function RegionsOf(obj)
    if not obj or type(obj.GetRegions) ~= "function" then return nil end
    local ok, r = pcall(function() return { obj:GetRegions() } end)
    return (ok and type(r) == "table") and r or nil
end
local function ChildrenOf(obj)
    if not obj or type(obj.GetChildren) ~= "function" then return nil end
    local ok, r = pcall(function() return { obj:GetChildren() } end)
    return (ok and type(r) == "table") and r or nil
end

--- 我们自己的一块板（`BackdropTemplate` 子框体），按 key 幂等挂在宿主上。
--- 关鼠标 —— 绝不吃掉分类行 / 侧页签的点击。
local function OwnPlate(host, key, opts)
    local plate = Marked(host, key)
    if plate then return plate end
    local ok, f = pcall(CreateFrame, "Frame", nil, host, "BackdropTemplate")
    if not ok or not f then return nil end
    -- **留白**：板往里退 2，相邻条目之间就出现一条缝（板贴满时整列会连成一整块灰）。
    -- 只退我们自己的板，暴雪的锚点一个都不动。
    local pad = (opts and opts.inset) or 4
    pcall(f.SetPoint, f, "TOPLEFT", host, "TOPLEFT", pad, -pad)
    pcall(f.SetPoint, f, "BOTTOMRIGHT", host, "BOTTOMRIGHT", -pad, pad)
    pcall(f.EnableMouse, f, false)
    Widget:Theme(f, opts)
    Mark(host, key, f)
    -- 板**自己也带标记**：公共遍历（`Skin:WalkFrames`）走到它时直接 `stop`，
    -- 不必再靠"父帧的引用"去认（那样每层都要多查两次旁表）。
    Mark(f, "ownPlate", true)
    return f
end

--- 分类行（418×67 匿名 Button）：横幅留着，只补 1px 方边 + hover 抬亮。
--- 板标成 `controlBg`，`Skin:HoverHighlight` 就认得出它（内部走 Widget:SetHoverLift，
--- 只写我们自己的板，不碰暴雪的 region）。
local function DressLfgRow(btn)
    if not btn or Marked(btn, "lfgRow") then return end
    Mark(btn, "lfgRow", true)
    OwnPlate(btn, "controlBg", { thickness = 1, bgAlpha = 0.16, borderAlpha = 0.75 })
    pcall(Skin.HoverHighlight, Skin, btn)
end

--- 圆形职责钮：glyph 已由 `SwapRoleAtlas` 换成我们的（并标 art），这里补方边 + hover。
local function DressLfgRoleButton(btn)
    if not btn or Marked(btn, "lfgRole") then return end
    Mark(btn, "lfgRole", true)
    OwnPlate(btn, "controlBg", { thickness = 1, bgAlpha = 0.20, borderAlpha = 0.75 })
    pcall(Skin.HoverHighlight, Skin, btn)
end

--- 组队窗整棵子树的补涂（公共遍历 `Skin:WalkFrames`）。
--- `force` = 静态美术那一趟：三个页可能都还藏着，但它们的窗框 / 底板此刻已经建好，
--- 先压掉，切页时就不会闪一下暴雪原样。轮询那趟仍按可见性走，省掉隐藏页的开销。
--- `carry` 承担"职责钮子树"这个分支状态（那颗 67×67 的装饰子帧是匿名的，只能靠继承认）。
local function LfgArtWalk(root, force)
    Skin:WalkFrames(root, { depth = 5, visibleOnly = not force }, function(host, atlases, name, carry)
        -- 我们自己的板（`OwnPlate` 的 `ownPlate` / `Skin:Panel` 的 `skinPlate`）：整棵跳过，
        -- 别把自己的 1px 边当暴雪美术压掉。
        if Marked(host, "skinPlate") or Marked(host, "ownPlate") then return "stop" end
        local isRole = carry or (name and name:find("RoleButton", 1, true)) or nil
        local kind = select(2, pcall(host.GetObjectType, host)) or "?"

        -- 逐张 region 处理（`FadeHold` 要贴图对象本身）：atlas 命中名单的，
        -- 或者职责钮子树里那两张**无 atlas** 的 64×64 装饰（只按尺寸收，别处不误伤）。
        for _, reg in ipairs(RegionsOf(host) or {}) do
            local okK, rk = pcall(reg.GetObjectType, reg)
            if okK and rk == "Texture" and not Marked(reg, "art") then
                local okA, atlas = pcall(reg.GetAtlas, reg)
                local hasAtlas = okA and type(atlas) == "string"
                local fade = hasAtlas and IsLfgArt(atlas)
                if not fade and not hasAtlas and isRole and Num(reg, "GetWidth", 0) >= 60 then
                    fade = true
                end
                if fade then Skin:FadeHold(reg) end
            end
        end

        -- 分类行 / 职责钮补板；职责钮里那颗 24×24 复选框**不**走 Skin:CheckButton ——
        -- 那会给每颗都铺一块方板，实机多出三个小方框（11-14 截图判例）。
        if kind == "Button" and not isRole then
            local w, h = Num(host, "GetWidth", 0), Num(host, "GetHeight", 0)
            if w >= 250 and h >= 24 and h <= 110 then DressLfgRow(host) end
        elseif kind == "Button" and isRole then
            DressLfgRoleButton(host)
        end
        return isRole
    end)
end

-- --- 搜索 / 过滤 / 下拉 / 滚动（11-14 实机补）---------------------------------
-- `WhoFrameEditBox` 已由 `M:SweepTemplates` 接走（放大镜留着）；两个具名下拉由
-- `M:Dress(LFG_DROPDOWNS)` 接走 —— 但 `Skin:Dropdown` 只是 `Skin:Button` 的别名，
-- `Strip` 把 `common-dropdown-a-button`（小箭头）一起压成 α0，下拉看着像普通按钮。
-- 另有三颗没点名：`GroupRoleButtonsRoleDropdown` / `VoiceChatDropdown` /
-- `ActivityView.PlayStyleDropdown`（最后一颗**没有全局名**，只能走字段路径），
-- 以及 WhoList 里两颗匿名按钮（36×36 搜索、110×18 过滤）。
-- ⇒ 两件事：① 给所有下拉补我们自己的 V 形；② 按 atlas 结构认出没点名的那些。
local LFG_DROPDOWN_PATHS = {
    "LFGBrowseFrameCategoryDropdown",
    "LFGBrowseFrameActivityDropdown",
    "LFGListingFrameGroupRoleButtonsRoleDropdown",
    "LFGListingFrameActivityViewVoiceChatDropdown",
    "LFGListingFrameActivityView.PlayStyleDropdown",
}
local function ResolveLfgPath(path)
    local node = _G
    for part in path:gmatch("[^%.]+") do
        if type(node) ~= "table" and type(node) ~= "userdata" then return nil end
        local ok, child = pcall(function() return node[part] end)
        if not ok then return nil end
        node = child
        if node == nil then return nil end
    end
    return node
end

--- 下拉的小 V 形：`Strip` 压掉了暴雪那颗，补我们自己的。
--- 与 `Skin:Stepper` 同一套口径（自建 Texture + `art` 标记 + 主题边框色）。
local function LfgDropdownArrow(btn)
    if not btn or Marked(btn, "lfgArrow") then return end
    local ok, tex = pcall(btn.CreateTexture, btn, nil, "OVERLAY", nil, 7)
    if not ok or not tex then return end
    Mark(btn, "lfgArrow", true)
    pcall(tex.SetSize, tex, 12, 12)
    pcall(tex.SetPoint, tex, "RIGHT", btn, "RIGHT", -6, 0)
    pcall(tex.SetTexture, tex, ns.Media:Texture("monet_chevron_up"))
    pcall(Widget.Arrow, Widget, tex, "down")
    Mark(tex, "art", true)
    local r, g, b = Color:GetBorder()
    if r then pcall(tex.SetVertexColor, tex, r, g, b) end
end

local function LfgDressDropdown(btn)
    if not btn then return end
    -- 已接过 `Skin:Button` 的下拉（controlBg 在）不必重跑，箭头照样补。
    if not Marked(btn, "controlBg") then pcall(Skin.Dropdown, Skin, btn) end
    LfgDropdownArrow(btn)
end

--- 匿名控件的结构认脸：**只认 atlas**，不猜名字（AGENTS：帧名永不凭记忆）。
local function LfgControlWalk(host, depth)
    if not host or depth > 4 or not Widget:Readable(host) then return end
    if Marked(host, "skinPlate") or Marked(host, "controlBg")
        or Marked(host, "lfgRow") or Marked(host, "lfgRole") or Marked(host, "lfgCtl") then return end
    local kind = select(2, pcall(host.GetObjectType, host)) or "?"
    if kind == "Button" then
        local isDropdown, isSearch = false, false
        for _, r in ipairs(RegionsOf(host) or {}) do
            local okA, a = pcall(r.GetAtlas, r)
            if okA and type(a) == "string" then
                local low = a:lower()
                if low:find("^common%-dropdown%-") then isDropdown = true end
                if low:find("icon%-search", 1, true) then isSearch = true end
            end
        end
        if isDropdown then
            Mark(host, "lfgCtl", true)
            LfgDressDropdown(host)
        elseif isSearch then
            -- 放大镜是功能图标：**不走** `Skin:Button`（它的 Strip 会把放大镜一起压掉）。
            -- 只铺板 + hover；`LfgArtWalk` 已经把 `common-button-*` 那三张框压掉了。
            Mark(host, "lfgCtl", true)
            pcall(Skin.ControlBg, Skin, host, { thickness = 1, bgAlpha = 0.35 })
            pcall(Skin.HoverHighlight, Skin, host)
        end
        return
    end
    for _, kid in ipairs(ChildrenOf(host) or {}) do
        LfgControlWalk(kid, depth + 1)
    end
end

--- 浏览页两颗小功能钮：原图标被 `Skin:Button` 的 Strip 压掉，补我们自己的。
--- 与 `LfgDropdownArrow` 同一套（自建 Texture + `art` 标记 + 主题边框色）。
local LFG_TINY_ICONS = {
    { name = "LFGBrowseFrameRefreshButton", key = "monet_refresh", size = 18 },
    { name = "LFGBrowseFrameOptionsButton", key = "monet_options", size = 12 },
}
local function LfgTinyIcons()
    for i = 1, #LFG_TINY_ICONS do
        local info = LFG_TINY_ICONS[i]
        local btn = rawget(_G, info.name)
        if btn and not Marked(btn, "lfgTiny") then
            local ok, tex = pcall(btn.CreateTexture, btn, nil, "OVERLAY", nil, 7)
            if ok and tex then
                Mark(btn, "lfgTiny", true)
                pcall(tex.SetSize, tex, info.size, info.size)
                pcall(tex.SetPoint, tex, "CENTER")
                pcall(tex.SetTexture, tex, ns.Media:Texture(info.key))
                Mark(tex, "art", true)
                local r, g, b = Color:GetBorder()
                if r then pcall(tex.SetVertexColor, tex, r, g, b) end
            end
        end
    end
end

local function LfgControlsPass(parent)
    for i = 1, #LFG_DROPDOWN_PATHS do
        LfgDressDropdown(ResolveLfgPath(LFG_DROPDOWN_PATHS[i]))
    end
    LfgControlWalk(parent, 0)
    LfgTinyIcons()
    -- ScrollBox / 细把手 / 上下步进钮：三个页都会懒建，每趟补一次（各换肤器自带幂等标记）。
    pcall(M.SkinScrollsIn, M, parent)
end

--- 侧页签：与角色界面（`CharacterFrameModeTab*`）**同一套**（11-14 作者口径）。
--- 上一版是"自建方板 + 选中环 + 图标明暗"，那是我们自己发明的样式；现在统一走
--- `Skin:SideTabArt`：金框 / 悬停金框 / 圆形遮罩褪掉，选中态换成我们的**矩形** barfill 盒子
--- （画在图标之下，不糊图标）。图标本身保持暴雪原样 —— 角色界面那边也是这样。
--- 选中态由暴雪自己切（`common-sidetab-selected` 那张纹理本来就是"选中才画"），
--- 所以这里**不需要**再用 view 可见性去推选中态（上一版那套也一并撤掉）。
local function LfgSideTabPass(parent)
    for i = 1, #LFG_SIDE_TABS do
        local tab = parent[LFG_SIDE_TABS[i]]
        if tab then pcall(Skin.SideTabArt, Skin, tab, 1) end
    end
end

-- 稳定引用 —— PollWatch / ShowWatch 按函数身份去重，闭包每次新建 = 每一拍都多挂一条轮询。
local function LfgRepaint()
    if not M.active then return end
    -- 轮询不在任何面板 Apply 的作用域里，自己套一层 Skin.With，账本才记在 "lfg" 名下。
    Skin.With("lfg", function()
        local parent = Skin:Need("LFGParentFrame")
        if not parent then return end
        -- 轮询里的抛错不在任何 Apply 的 pcall 保护下，而且每 2 秒一次：自己吞，并借
        -- WarnOnce 把名字报出来（受限框读 GetChildren 就会被拒）。
        local ok, err = pcall(function()
            WalkSwapRole(parent, 0)        -- 先换职责图集（并标 art），再褪色
            LfgArtWalk(parent, true)
            LfgSideTabPass(parent)
            LfgControlsPass(parent)
        end)
        if not ok then
            Skin:WarnOnce("lfgRepaint", ("复古组队窗复涂失败: %s"):format(tostring(err)))
        end
    end)
end

--- 分类行的横幅是**内容图**：`Skin:Button` 的 `Strip` 会把它连同金框一起压掉。
--- 按 atlas 认脸 —— 只放行 `groupfinder-button-<内容>`（dungeons / questing / battlegrounds /
--- custom-pve），同族的 `groupfinder-button-cover*`（金框）照压。
--- 这条是**兜底**：`M:Controls` 那趟在 Apply 时跑，而分类行是开页时才懒建的，
--- 所以多数时候碰不到；但只要有一次 Apply 落在开页之后，横幅就会没了（11-14 的同类隐患）。
local function LfgKeepBanner(region)
    local okA, atlas = pcall(region.GetAtlas, region)
    if not okA or type(atlas) ~= "string" then return false end
    local low = atlas:lower()
    return low:find("^groupfinder%-button%-") ~= nil and low:find("cover", 1, true) == nil
end

local function SkinLFG()
    M:Dress("LFGParentFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })

    -- The animated eye in the portrait slot is a button of its own: alpha it away AND take the mouse, so the idle 64px region cannot swallow clicks.
    local eye = Skin:Need("LFGParentFramePortrait")
    if eye then
        Skin:Fade(eye)
        if eye.EnableMouse then eye:EnableMouse(false) end
    end

    -- The three views repaint themselves when swapped in, so each carries its own fill/border art: strip every view, not just the parent.
    M:Controls(LFG_VIEWS, function(view)
        Skin:Strip(view)
        M:SkinButtonsIn(view, { keep = LfgKeepBanner }, 1)
    end)
    M:Dress(LFG_BUTTONS, { as = "button" })
    M:Dress(LFG_TOP_TABS, { as = "tab" })
    M:Dress(LFG_DROPDOWNS, { as = "dropdown" })
    -- 队列眼睛的宿主框：不做换肤（属于 Blizzard_QueueStatusFrame、有自己的动画），
    -- 只过 Need 让它进账本，方便 `/mui skins diagnose` 一眼看到能不能读到。
    -- （2026-11-03 独立审查必改项：原先这里写的是 M:Dress(LFG_QUEUE, { as = "fade" })，
    --  而 DRESSERS.fade 实际会调 Skin:Fade 把框压成 alpha 0 —— 排队眼睛直接消失，
    --  与注释正好相反；去掉换肤调用，只保留账本登记。）
    for i = 1, #LFG_QUEUE do
        Skin:Need(LFG_QUEUE[i])
    end
    SideTabs("LFGParentFrame", LFG_SIDE_TABS)

    -- 内部件复涂：进面板先扫一次，之后 PollWatch 每 2 秒复检（暴雪会重贴 atlas / 抬回
    -- alpha / 切页时懒建行），ShowWatch 让"刚打开窗口"那一拍不必等满 2 秒。
    -- 两个驱动都按这个稳定引用去重；回调里所有写入都只落我们自己的板或 Texture 的 alpha。
    LfgRepaint()
    local parent = Skin:Need("LFGParentFrame")
    if parent and Widget:Readable(parent) then
        Widget:PollWatch(parent, LfgRepaint, 2)
        Widget:ShowWatch(parent, LfgRepaint)
    end
end

M:Panel("lfg", {
    label = "查找组（复古）",
    group = "窗口",
    apply = SkinLFG,
    -- LoD gate: this pack waits for the vanilla-style group finder addon instead of re-skinning on every addon load.
    addons = { Blizzard_GroupFinder_VanillaStyle = true },
    frames = {
        "LFGParentFrame", "LFGParentFramePortrait",
        "LFGParentFrame.ListingTab", "LFGParentFrame.BrowsingTab", "LFGParentFrame.WhoListingTab",
        LFG_VIEWS, LFG_BUTTONS, LFG_TOP_TABS, LFG_DROPDOWNS, LFG_QUEUE,
    },
})

local LEGACY_SIDE_TABS = { "LegacyRewardTrackTab", "LegacyChallengeTab", "LegacyTreeTab" }
-- **实名来源（11-05 补）**：三块页面是 `LegacySystemFrame` 的 **parentKey 子件**，没有全局名 ——
-- `framexml-source/Blizzard_LegacySystem/Blizzard_LegacySystem.xml:40-42`：
-- `parentKey="RewardTrackPage"` / `"ChallengesPage"` / `"TreePage"`（还漏了第三块，一并补上）。
-- 原来点的是裸名 `RewardTrackPage` / `ChallengesPage` ⇒ 台账上两行永远 ✗，而且这段 `M:Controls`
-- 其实一个字节都没涂过（`Need` 拿不到 ⇒ 循环体一次都不跑）。取用路径改成点路径。
local LEGACY_PAGES     = { "LegacySystemFrame.RewardTrackPage", "LegacySystemFrame.ChallengesPage",
                           "LegacySystemFrame.TreePage" }

local function SkinLegacySystem()
    M:Dress("LegacySystemFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })
    SideTabs("LegacySystemFrame", LEGACY_SIDE_TABS)

    M:Controls(LEGACY_PAGES, function(page)
        Skin:Strip(page)
        M:SkinButtonsIn(page)
        M:SkinScrollsIn(page)
    end)
end

M:Panel("legacy", {
    label = "传承进度",
    group = "窗口",
    apply = SkinLegacySystem,
    addons = { Blizzard_LegacySystem = true },
    frames = {
        "LegacySystemFrame",
        "LegacySystemFrame.LegacyRewardTrackTab", "LegacySystemFrame.LegacyChallengeTab",
        "LegacySystemFrame.LegacyTreeTab",
        LEGACY_PAGES,
    },
})

-- **1.60 实测（开服日 11-05，`/mui compat find MicroButton` 走 19804 个框，全客户端一共 17 个命中）**：
-- 底栏 15 颗 = Achievement / Character / Collections / EJ / Guild / Help / Housing / LFD / Legacy /
-- MainMenu / PlayerSpells / Profession / QuestLog / Spellbook / Store / Talent（+ 容器 `MicroButtonAndBagsBar`）。
-- `SocialsMicroButton` 与 `PVPMicroButton` **不存在**（好友/社区/PVP 合并进 `SocialUIFrame`，
-- 名字是 `SocialUIFrame*`；PVP 那一档整个折掉了）—— 这两行是空枪，从收口起那两颗"按钮"没被涂过，
-- 因为它们压根不在。删掉，别让台账上永远挂着两行消不掉的 ✗。
local MICRO_BUTTONS = {
    "CharacterMicroButton", "ProfessionMicroButton", "PlayerSpellsMicroButton",
    "AchievementMicroButton", "QuestLogMicroButton", "GuildMicroButton",
    "LFDMicroButton", "CollectionsMicroButton", "EJMicroButton",
    "StoreMicroButton", "MainMenuMicroButton", "HelpMicroButton",
    "HousingMicroButton",
    -- Forever 保留、零售改名或折掉的那几颗：
    "SpellbookMicroButton", "TalentMicroButton", "LegacyMicroButton",
}

local function SkinOneMicroButton(name)
    local button = Skin:Need(name)
    if not button then return end
    -- The icon texture stays; only the button's own sprite edges go.
    Skin:FadeButtonArt(button)
end

local function SkinMicroMenuCore()
    for i = 1, #MICRO_BUTTONS do
        SkinOneMicroButton(MICRO_BUTTONS[i])
    end

    -- Forever's MicroMenu keeps a Blizzard container strip; fade it by alpha only -- the container is Edit-Mode-owned and must never be hidden.
    local menu = Skin:Need("MicroMenu")
    if menu then
        if menu.BackgroundArt then Skin:Fade(menu.BackgroundArt) end
        if menu.BorderArt then Skin:Fade(menu.BorderArt) end
    end
end

local microHooked = false

local function SkinMicroMenu()
    -- Micro buttons are secure: never touch them in combat; ns:AfterCombat defers the
    -- repaint to combat end instead of failing silently.
    if InCombat() then
        ns:AfterCombat("skins-micromenu", function()
            if M.active then Skin.With("micromenu", SkinMicroMenuCore) end
        end)
        return
    end

    SkinMicroMenuCore()

    -- UpdateMicroButtons can fire several times per frame; one debounced repaint absorbs each burst.
    if not microHooked and Skin:Need("UpdateMicroButtons") then
        -- 不 hooksecurefunc("UpdateMicroButtons")（全局函数钩子，会污染调用链）：
        -- 改成每 1 秒轮询一次（Debounce 内部本来就合并）。
        microHooked = true
        local repaint = M:Debounce(function()
            if InCombat() then return end
            -- 轮询回调不在任何面板的作用域里，自己套一层，账本才不会把这 19 个名字记到 "_" 名下。
            Skin.With("micromenu", function()
                for i = 1, #MICRO_BUTTONS do
                    SkinOneMicroButton(MICRO_BUTTONS[i])
                end
            end)
        end)
        if ns.Widget and ns.Widget.PollWatch then
            local driver = Skin:Need("UIParent")
            if driver then ns.Widget:PollWatch(driver, repaint) end
        end
    end
end

M:Panel("micromenu", {
    label = "微菜单按钮",
    group = "窗口",
    apply = SkinMicroMenu,
    -- 每个微按钮都在查找时记了账，所以直接把 MICRO_BUTTONS 摊进声明名单：一处定义，别处不再抄。
    frames = { "MicroMenu", MICRO_BUTTONS },
})
