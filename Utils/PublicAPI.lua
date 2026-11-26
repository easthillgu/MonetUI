-- 跨插件美化公共接口：在 MonetUI 加载完成后通过 MonetUI.API 调用。

local ADDON_NAME, ns = ...

local Skin = ns.Skin
local Widget = ns.Widget
local Secrets = ns.Secrets
local API = {}
ns.API = API

API.VERSION = 1

-- 外部参数先做值级守卫，机密选项不得进入内部比较或表索引。
local function CanRead(value)
    return Secrets ~= nil and type(Secrets.CanRead) == "function" and Secrets.CanRead(value)
end

local function OptionalString(value)
    if not CanRead(value) then return false end
    return value == nil or type(value) == "string"
end

local function ColorValue(value)
    if not CanRead(value) then return false end
    if value == nil or type(value) == "string" then return true end
    if type(value) ~= "table" then return false end
    local r, g, b, a = rawget(value, "r"), rawget(value, "g"), rawget(value, "b"), rawget(value, "a")
    return type(r) == "number" and CanRead(r)
        and type(g) == "number" and CanRead(g)
        and type(b) == "number" and CanRead(b)
        and CanRead(a) and (a == nil or type(a) == "number")
end

local function PositiveNumber(value, optional)
    if not CanRead(value) then return false end
    if value == nil then return optional == true end
    return type(value) == "number" and value > 0
end

local function CopyOption(value, seen)
    if not CanRead(value) then return nil, false end
    if type(value) ~= "table" then return value, true end
    if type(rawget(value, "GetObjectType")) == "function" then return value, true end
    if seen[value] then return seen[value], true end
    local copy = {}
    seen[value] = copy
    local key, item = next(value)
    while true do
        if not CanRead(key) then return nil, false end
        if key == nil then return copy, true end
        local copied, ok = CopyOption(item, seen)
        if not ok then return nil, false end
        copy[key] = copied
        key, item = next(value, key)
    end
end

local function OptionsValue(value)
    if not CanRead(value) then return nil end
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    local copy, ok = CopyOption(value, {})
    if not ok then return nil end
    return copy
end

local function ErrorReason(reason)
    if not CanRead(reason) then return "MonetUI API operation failed" end
    local ok, text = pcall(tostring, reason)
    if ok and CanRead(text) then return text end
    return "MonetUI API operation failed"
end

--- 返回公共接口当前是否可用。
function API:IsAvailable()
    return Skin ~= nil and Widget ~= nil and Secrets ~= nil
end

--- 返回当前是否允许修改美化对象。
function API:CanSkin()
    if not self:IsAvailable() then return false end
    if type(ns.IsRestricted) ~= "function" then return true end
    return not ns:IsRestricted()
end

--- 解析框体对象或全局点路径，并登记命名目标的查找账本。
function API:Resolve(target)
    if not self:IsAvailable() or not CanRead(target) then return nil end
    if type(target) == "string" then
        if target == "" or type(ns.ResolveObject) ~= "function" then return nil end
        local ok, obj = pcall(Skin.Need, Skin, target)
        if ok then return obj end
        return nil
    end
    return target
end

local function ObjectKind(obj)
    if type(obj) ~= "table" and type(obj) ~= "userdata" then return nil end
    local ok, method = pcall(function() return obj.GetObjectType end)
    if not ok or type(method) ~= "function" then return nil end
    local called, kind = pcall(method, obj)
    if not called or not CanRead(kind) or kind == nil then return nil end
    return kind
end

local function Prepare(target, expected)
    local api = ns.API
    if not api or not api:IsAvailable() then return nil, "MonetUI API is not ready" end
    if not api:CanSkin() then return nil, "UI is restricted" end
    local obj = api:Resolve(target)
    if obj == nil then return nil, "Target not found" end
    local kind = ObjectKind(obj)
    if kind == nil then return nil, "Target is not a UI object" end
    if expected and kind ~= expected then return nil, "Target must be a " .. expected end
    return obj
end

local function Parent(target)
    local host, err = Prepare(target, "Frame")
    if not host then
        if err == "Target not found" then err = "Parent not found" end
        return nil, err
    end
    return host
end

local function ApplySkin(target, method, expected, ...)
    local obj, err = Prepare(target, expected)
    if not obj then return nil, err end
    local ok, result = pcall(Skin[method], Skin, obj, ...)
    if not ok then return nil, ErrorReason(result) end
    if result == nil then return nil, "Skin operation did not apply" end
    return obj
end

local function ApplyWidget(target, method, ...)
    local obj, err = Prepare(target)
    if not obj then return nil, err end
    local ok, result = pcall(Widget[method], Widget, obj, ...)
    if not ok then return nil, ErrorReason(result) end
    if result == nil then return nil, "Widget operation did not apply" end
    return obj
end

--- 创建带 Monet 背板的普通框体或按钮。
function API:CreateFrame(parent, width, height, kind)
    if not self:CanSkin() then return nil, "UI is restricted" end
    if not CanRead(kind) then return nil, "Secret frame kind" end
    if kind == nil then kind = "Frame" end
    if kind ~= "Frame" and kind ~= "Button" then return nil, "Unsupported frame kind" end
    if not PositiveNumber(width) then return nil, "Width must be a positive number" end
    if not PositiveNumber(height, true) then return nil, "Height must be a positive number" end
    local host, err = Parent(parent)
    if not host then return nil, err end
    local ok, frame = pcall(Widget.CreateFrame, Widget, nil, host, width, height, "BackdropTemplate", kind)
    if not ok then return nil, ErrorReason(frame) end
    if frame == nil then return nil, "Frame could not be created" end
    return frame
end

--- 应用主题背板与边框。
function API:Theme(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid theme options" end
    return ApplyWidget(target, "Theme", opts)
end

--- 添加面板背板。
function API:Panel(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid panel options" end
    return ApplySkin(target, "Panel", nil, opts)
end

--- 美化按钮。
function API:Button(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid button options" end
    return ApplySkin(target, "Button", "Button", opts)
end

--- 美化复选框。
function API:CheckButton(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid check button options" end
    return ApplySkin(target, "CheckButton", "CheckButton", opts)
end

--- 美化下拉按钮。
function API:Dropdown(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid dropdown options" end
    return ApplySkin(target, "Dropdown", "Button", opts)
end

--- 美化输入框。
function API:EditBox(target, opts)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid edit box options" end
    return ApplySkin(target, "EditBox", "EditBox", opts)
end

--- 美化滚动框的滚动条。
function API:ScrollFrame(target)
    return ApplySkin(target, "ScrollFrame", "ScrollFrame")
end

--- 美化滑块。
function API:Slider(target)
    return ApplySkin(target, "Slider", "Slider")
end

--- 应用字体、字号与文字色。
function API:Font(target, size, fontKey, flags, colorKey)
    if not PositiveNumber(size) then return nil, "Font size must be a positive number" end
    if not OptionalString(fontKey) or not OptionalString(flags) or not ColorValue(colorKey) then
        return nil, "Invalid font options"
    end
    return ApplySkin(target, "Font", "FontString", size, fontKey, flags, colorKey)
end

--- 应用命名文字色或显式 RGBA 表。
function API:Text(target, colorKey)
    if not ColorValue(colorKey) then return nil, "Invalid text color" end
    return ApplySkin(target, "ColorText", "FontString", colorKey)
end

--- 创建主题状态条。
function API:Bar(parent, width, height, textureKey)
    if not self:CanSkin() then return nil, "UI is restricted" end
    if not PositiveNumber(width) then return nil, "Width must be a positive number" end
    if not PositiveNumber(height, true) then return nil, "Height must be a positive number" end
    if not OptionalString(textureKey) then return nil, "Invalid texture key" end
    local host, err = Parent(parent)
    if not host then return nil, err end
    local ok, bar = pcall(Widget.Bar, Widget, host, width, height, textureKey)
    if not ok then return nil, ErrorReason(bar) end
    if bar == nil then return nil, "Bar could not be created" end
    return bar
end

--- 创建主题关闭按钮。
function API:CloseButton(parent, size)
    if not self:CanSkin() then return nil, "UI is restricted" end
    if not PositiveNumber(size, true) then return nil, "Size must be a positive number" end
    local host, err = Parent(parent)
    if not host then return nil, err end
    local ok, button = pcall(Widget.CloseButton, Widget, host, size)
    if not ok then return nil, ErrorReason(button) end
    if button == nil then return nil, "Close button could not be created" end
    return button
end

local CONTROL_KINDS = {
    button = { "Button", "Button" },
    check = { "CheckButton", "CheckButton" },
    checkbutton = { "CheckButton", "CheckButton" },
    dropdown = { "Dropdown", "Button" },
    editbox = { "EditBox", "EditBox" },
    scroll = { "ScrollFrame", "ScrollFrame" },
    scrollframe = { "ScrollFrame", "ScrollFrame" },
    slider = { "Slider", "Slider" },
}

--- 美化单个窗口或控件；window 支持 strip、panel、portrait 开关。
function API:Dress(target, kind, opts)
    if not CanRead(kind) then return nil, "Secret kind" end
    if type(kind) == "table" then
        if not CanRead(opts) then return nil, "Secret dress options" end
        if opts ~= nil then return nil, "Ambiguous dress options" end
        opts, kind = kind, "window"
    end
    if kind == nil then kind = "window" end
    if type(kind) ~= "string" then return nil, "Dress kind must be a string" end
    kind = string.lower(kind)
    opts = OptionsValue(opts)
    if not opts then return nil, "Invalid dress options" end

    local control = CONTROL_KINDS[kind]
    if control then return ApplySkin(target, control[1], control[2], opts) end
    if kind ~= "window" then return nil, "Unsupported dress kind" end

    local obj, err = Prepare(target)
    if not obj then return nil, err end
    local strip, panel = opts.strip, opts.panel
    if strip == true then strip = {} end
    if panel == true then panel = {} end
    local ok, reason = pcall(function()
        if strip ~= false then Skin:Strip(obj, strip) end
        if panel ~= false then
            if Skin:Panel(obj, panel) == nil then error("Panel could not be applied", 0) end
        end
        if opts.portrait ~= false then Skin:HidePortraits(obj) end
    end)
    if not ok then return nil, ErrorReason(reason) end
    return obj
end

--- 重绘已登记的主题对象。
function API:Refresh()
    if not self:CanSkin() then return nil, "UI is restricted" end
    local ok, reason = pcall(function()
        Widget:RefreshThemes()
        Skin:RefreshThemes()
    end)
    if not ok then return nil, ErrorReason(reason) end
    return true
end
