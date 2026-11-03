-- Utils/SkinTemplates.lua
-- 模板层：**先认出"这是什么控件"，再交给对应的皮肤件**。
--
-- 为什么需要它：`Modules/Skins/Skins.lua` 的深扫（SkinButtonsIn / SkinScrollsIn / SkinSlidersIn）
-- 只认 Button / CheckButton / RadioButton / ScrollFrame / Slider。于是**已登记窗口里**那几类
-- 控件一直是暴雪原样，最显眼的三类：
--   * `MoneyFrameTemplate`（金币）—— 每个带钱的窗口都有（交易 / 银行 / 拍卖 / 邮件 / 修理）；
--   * `EditBox` —— 搜索框 / 输入框（实机 1.60 有 118 个）；
--   * `ColoredProgressBarTemplate` —— 1.60 的名望条 / 技能条底座。
--
-- 识别一律**按结构特征**（对象类型 + 模板自己留下的字段），**不按帧名列表**：本客户端
-- 12.x 起大量控件是匿名 + 按需创建的，名单永远追不上；而结构是模板给的，稳定得多。
--
-- 纪律（AGENTS.md，违反任何一条都会换来 ADDON_ACTION_BLOCKED / 机密值算术抛错）：
--   * 不往暴雪框体 / 贴图 / 字体串写字段 —— 簿记一律走 `ns:Mark` 旁表；
--   * 不写脚本槽 / 方法槽（没有 HookScript、没有 hooksecurefunc）；
--   * 不 SetParent / SetShown / Hide 暴雪框；皮肤只做"淡掉原美术 + 挂我们自己的子框体"；
--   * forbidden 对象上连 `GetObjectType` 都会抛，所以每一次读都 pcall。

local ADDON_NAME, ns = ...

local Skin   = ns.Skin

local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

-- ---------------------------------------------------------------------------
-- 识别
-- ---------------------------------------------------------------------------

--- 带图标的按钮（奖励格 / 装备格）不能被 Button 皮肤淡掉原美术。
--- 以前这是 `Modules/Skins/Skins.lua` 的局部函数；挪到这里是因为模板层也要用它，
--- 而 Utils 在 Modules 之前加载（反向依赖会拿到 nil）。
function Skin:LooksLikeItemButton(button)
    if not button then return false end
    return button.icon or button.Icon or button.iconTexture or button.IconTexture
        or button.itemButton or button.ItemButton
end

--- 这个对象是什么控件？
--- @return "money"|"coloredbar"|"scroll"|"slider"|"editbox"|"checkbox"|"radio"|"button"|"scrollbox"|"nineslice"|"selectable"|"templatelist"|"moneyinput"|"propertybutton"|nil
---         nil = 不认识，或者根本读不出来（forbidden 对象）
function Skin:Recognize(obj)
    if not obj then return nil end
    
    -- 第一层：查模板数据库（TemplateRecognizer.lua 的 Skin:RecognizeEnhanced）
    -- 数据库覆盖 387 个模板，包括 Aurora 的 26 个 SharedXML 皮肤文件目标
    if self.RecognizeEnhanced then
        local enhancedKind = self:RecognizeEnhanced(obj)
        if enhancedKind then return enhancedKind end
    end
    
    -- 第二层：回退到原有结构指纹
    local okKind, kind = pcall(obj.GetObjectType, obj)
    if not okKind or type(kind) ~= "string" then return nil end

    if kind == "Frame" then
        -- MoneyFrameTemplate 会写 `moneyType`（实机 1.60：38 个框带这个字段）。
        local okMoney, moneyType = pcall(function() return obj.moneyType end)
        if okMoney and moneyType ~= nil then return "money" end

        -- ColoredProgressBarTemplate：**1.60 上它是 Frame，不是 StatusBar**。
        -- 它没有 SetStatusBarTexture / SetStatusBarColor，按 StatusBar 写会直接抛
        -- "SetStatusBarTexture is not a function"（Aurora 同款注释 + docs/AURORA-COVERAGE.md §3）。
        -- Fill / Mask 由 ColoredProgressBarMixin 驱动，是可靠指纹。
        local okFill, fill = pcall(function() return obj.Fill end)
        local okMask, mask = pcall(function() return obj.Mask end)
        if okFill and okMask and fill ~= nil and mask ~= nil then return "coloredbar" end
        return nil
    end

    if kind == "ScrollFrame" then return "scroll" end
    if kind == "Slider"      then return "slider" end
    if kind == "EditBox"     then return "editbox" end
    if kind == "CheckButton" then return "checkbox" end
    if kind == "RadioButton" then return "radio" end
    if kind == "Button"      then return "button" end
    return nil
end

--- 按识别结果套皮肤。`kind` 省略时自己认。
--- 所有分支都返回传入的对象（链式用），不认识就返回 nil。
function Skin:SkinControl(obj, kind, opts)
    if not obj then return nil end
    kind = kind or self:Recognize(obj)
    if not kind then return nil end

    if kind == "button" then
        if self:LooksLikeItemButton(obj) then return obj end
        return self:Button(obj, opts)
    elseif kind == "checkbox" then
        return self:CheckButton(obj, opts)
    elseif kind == "radio" then
        return self:RadioButton(obj, opts)
    elseif kind == "scroll" then
        return self:ScrollFrame(obj)
    elseif kind == "slider" then
        return self:Slider(obj)
    elseif kind == "editbox" then
        return self:EditBox(obj)
    elseif kind == "money" then
        return self:Money(obj)
    elseif kind == "coloredbar" then
        return self:ColoredBar(obj)
    -- 新增类型（来自模板数据库）
    elseif kind == "scrollbox" then
        -- ScrollBox 框架：暂时回退到 scroll 处理
        return self:ScrollFrame(obj)
    elseif kind == "nineslice" then
        -- NineSlice 面板：由 Skin:Strip 处理，这里只返回对象
        return obj
    elseif kind == "selectable" then
        -- SelectableButton：暂时回退到 button 处理
        return self:Button(obj, opts)
    elseif kind == "templatelist" then
        -- TemplatedList 框架：暂不处理，返回对象
        return obj
    elseif kind == "moneyinput" then
        -- MoneyInputFrame：暂时回退到 editbox 处理
        return self:EditBox(obj)
    elseif kind == "propertybutton" then
        -- PropertyButton（设置 UI 控件）：暂不处理，返回对象
        return obj
    elseif kind == "closebutton" then
        -- 关闭按钮：回退到 button 处理
        return self:Button(obj, opts)
    end
    return obj
end

-- ---------------------------------------------------------------------------
-- 两类以前完全没铺的控件
-- ---------------------------------------------------------------------------

--- 金币框（`MoneyFrameTemplate`）。
---
--- 实机结构（1.60 探针：自己 `CreateFrame("Frame", nil, UIParent, "MoneyFrameTemplate")`
--- 造实例再读的）：Frame 下三枚 Button `<名字>CopperButton / SilverButton / GoldButton`，
--- 每枚按钮 = **1 张无名贴图**（硬币）+ 1 个 `<按钮名>Text` 的 FontString（`.Text` 字段），
--- **没有 NormalTexture、没有 `.Icon`**。
---
--- 所以这里**不能走 Skin:Button**：那会把按钮的贴图 Strip 掉，硬币图标一起淡没。
--- 只做两件事：裁硬币图标、换字号。**绝不给面额按钮挂子框体** —— Aurora 的 TAINT-SAFE
--- 注释写明：给按钮加子贴图 / SetPoint 会把它的几何标脏，随后 `MoneyFrame_Update` 对
--- `GetTextWidth() + iconWidth` 做算术，在机密值环境下直接抛
--- "attempt to perform arithmetic on a secret number value"。裁切只改 texcoord，不动尺寸。
function Skin:Money(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return frame end

    local function denom(button)
        if not button or Marked(button, "moneyDenom") then return end
        local okKind, kind = pcall(button.GetObjectType, button)
        if not okKind or kind ~= "Button" then return end
        local text = button.Text
        if not text then return end       -- 没有数值字体串 = 不是面额按钮
        Mark(button, "moneyDenom", true)
        for _, region in next, { button:GetRegions() } do
            local ok, rkind = pcall(region.GetObjectType, region)
            if ok and rkind == "Texture" then
                self:CropIcon(region, 0.07, 0.93, 0.07, 0.93)
            end
        end
        self:Font(text, 12, "pixel", nil, "neutral")
    end

    local kids = { frame:GetChildren() }
    for i = 1, #kids do
        local child = kids[i]
        denom(child)
        -- 备用币种框（`SmallAlternateCurrencyFrameTemplate`）再嵌一层 Item1..3
        if child and type(child.GetChildren) == "function" then
            for _, grand in next, { child:GetChildren() } do denom(grand) end
        end
    end
    return frame
end

--- 1.60 的 ColoredProgressBarTemplate（名望 / 技能条底座）。
--- Fill / Mask 归 mixin，一个字节都不碰；只淡掉其余 chrome 贴图 + 挂我们的底衬。
function Skin:ColoredBar(frame)
    if not frame or Marked(frame, "coloredBar") then return frame end
    Mark(frame, "coloredBar", true)

    local keepFill, keepMask = frame.Fill, frame.Mask
    local okBar, barTexture = pcall(function()
        return frame.GetStatusBarTexture and frame:GetStatusBarTexture() or nil
    end)
    if not okBar then barTexture = nil end

    for _, region in next, { frame:GetRegions() } do
        local ok, rkind = pcall(region.GetObjectType, region)
        -- 有些继承这个模板的条声明成 <StatusBar>（Camelot 的 SkillsBarTemplate），
        -- 那时 bar 贴图是一张普通 region —— 一起保住，否则条就空了。
        if ok and rkind == "Texture" and region ~= keepFill and region ~= keepMask
           and region ~= barTexture then
            self:Fade(region)
        end
    end

    self:Panel(frame, { bgAlpha = 0.9 })
    return frame
end

-- ---------------------------------------------------------------------------
-- 深扫的补充：把上面这几类也铺进已登记的窗口
-- ---------------------------------------------------------------------------

--- 递归把 `editbox` / `money` / `coloredbar` 认一遍并套皮肤。
---
--- 为什么不并进 SkinButtonsIn：那三个函数是"每 0.2 秒跑一遍"的热路径（SweepDeep 的
--- PollWatch），多一趟 3 层递归就是给每个可见窗口每拍多一倍遍历。这几类控件都是**静态的**
--- （不会每帧变），所以调用方用 2 秒间隔单独登记即可。
---
--- 已经铺过的直接跳过（旁表标记），重复调用只花一次查表。
function Skin:ExtrasIn(frame, opts, depth)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    depth = depth or 0

    for _, child in next, { frame:GetChildren() } do
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind then
            if kind == "EditBox" then
                if not Marked(child, "extras") then
                    Mark(child, "extras", true)
                    pcall(self.EditBox, self, child)
                end
            elseif kind == "Frame" then
                local sub = self:Recognize(child)
                if sub == "money" then
                    pcall(self.Money, self, child)
                elseif sub == "coloredbar" then
                    pcall(self.ColoredBar, self, child)
                end
            end
        end
        if depth < 3 then
            pcall(self.ExtrasIn, self, child, opts, depth + 1)
        end
    end
end
