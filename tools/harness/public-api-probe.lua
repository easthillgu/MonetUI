local function Eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Truth(value, label)
    assert(value, label or "value is false")
end

local function Frame(kind)
    return { GetObjectType = function() return kind or "Frame" end }
end

local target, parent, fontString = Frame("Button"), Frame(), Frame("FontString")
local checkButton, editBox, scrollFrame, slider = Frame("CheckButton"), Frame("EditBox"), Frame("ScrollFrame"), Frame("Slider")
local restricted = false
local calls = {}
local secretValues = { secret = true }
local ns = {
    Secrets = {
        IsSecret = function(value) return secretValues[value] == true end,
        CanRead = function(value) return secretValues[value] ~= true end,
    },
}

local function Record(name, result)
    return function(_, object, ...)
        calls[#calls + 1] = { name = name, object = object, args = { ... } }
        if object and object.failMethod == name then error(object.failReason or "mock failure") end
        if object and object.nilMethod == name then return nil end
        return result or object
    end
end

ns.Skin = {
    IsScriptObject = function(_, object)
        return type(object) == "table" and type(object.GetObjectType) == "function"
    end,
    Panel = Record("Panel"),
    Need = function(_, path)
        if path == "ExternalFrame" then return target end
        if path == "ExternalFrame.Child" then return parent end
    end,
    Button = Record("Button"),
    CheckButton = Record("CheckButton"),
    Dropdown = Record("Dropdown"),
    EditBox = Record("EditBox"),
    ScrollFrame = Record("ScrollFrame"),
    Slider = Record("Slider"),
    Font = Record("Font"),
    ColorText = Record("ColorText"),
    Strip = Record("Strip"),
    HidePortraits = Record("HidePortraits"),
    RefreshThemes = Record("SkinRefresh"),
}
ns.Widget = {
    Theme = Record("Theme"),
    RefreshThemes = Record("WidgetRefresh"),
    CreateFrame = function(_, name, host, width, height, template, kind)
        calls[#calls + 1] = { name = "CreateFrame", args = { name, host, width, height, template, kind } }
        if host.nilFactory then return nil end
        return Frame(kind)
    end,
    Bar = function(_, host, width, height, textureKey)
        calls[#calls + 1] = { name = "Bar", args = { host, width, height, textureKey } }
        if host.nilFactory then return nil end
        return Frame("StatusBar")
    end,
    CloseButton = function(_, host, size)
        calls[#calls + 1] = { name = "CloseButton", args = { host, size } }
        if host.nilFactory then return nil end
        return Frame("Button")
    end,
}

assert(loadfile("Utils/PublicAPI.lua"))("MonetUI", ns)
local API = ns.API
Truth(API, "API namespace missing")
Eq(API.VERSION, 1, "API version")
Truth(API:IsAvailable(), "API should be available")
Truth(API:CanSkin(), "API should allow skinning before Core is ready")

ns.ResolveObject = function(path)
    if path == "ExternalFrame" then return target end
    if path == "ExternalFrame.Child" then return parent end
end
ns.IsRestricted = function() return restricted end
_G.ExternalFrame = target
_G.ExternalFrame.Child = parent

Eq(API:Resolve("ExternalFrame"), target, "global resolve")
Eq(API:Resolve("ExternalFrame.Child"), parent, "path resolve")
Eq(API:Resolve("Missing"), nil, "missing resolve")
Eq(API:Resolve("secret"), nil, "secret resolve")
local secretNumber, secretBoolean, secretTable = 17, true, {}
secretValues[secretNumber], secretValues[secretBoolean], secretValues[secretTable] = true, true, true
Eq(API:Resolve(secretNumber), nil, "secret number resolve")
Eq(API:Resolve(secretBoolean), nil, "secret boolean resolve")
Eq(API:Resolve(secretTable), nil, "secret table resolve")

Eq(API:Panel(target, { thickness = 2 }), target, "panel return")
Eq(calls[#calls].name, "Panel", "panel dispatch")
Eq(API:Button(target), target, "button return")
Eq(API:CheckButton(checkButton), checkButton, "check return")
Eq(API:Dropdown(target), target, "dropdown return")
Eq(API:EditBox(editBox), editBox, "editbox return")
Eq(API:ScrollFrame(scrollFrame), scrollFrame, "scroll return")
Eq(API:Slider(slider), slider, "slider return")
Eq(API:Theme(target, { bgAlpha = 0.8 }), target, "theme return")
Eq(API:Font(fontString, 12, "pixel", nil, "edge"), fontString, "font return")
Eq(calls[#calls].args[1], 12, "font size")
Eq(calls[#calls].args[2], "pixel", "font key")
Eq(calls[#calls].args[4], "edge", "font color")
Eq(API:Text(fontString, "neutral"), fontString, "text return")
Eq(API:Text(fontString, { r = 0.2, g = 0.3, b = 0.4, a = 0.5 }), fontString, "RGBA text return")

local before = #calls
restricted = true
local value, err = API:Button(target)
Eq(value, nil, "restricted return")
Eq(err, "UI is restricted", "restricted error")
Eq(#calls, before, "restricted call must not dispatch")
value, err = API:CreateFrame(parent, 100)
Eq(value, nil, "restricted frame return")
Eq(err, "UI is restricted", "restricted frame error")
value, err = API:Bar(parent, 100)
Eq(value, nil, "restricted bar return")
Eq(err, "UI is restricted", "restricted bar error")
value, err = API:CloseButton(parent)
Eq(value, nil, "restricted close return")
Eq(err, "UI is restricted", "restricted close error")
value, err = API:Refresh()
Eq(value, nil, "restricted refresh return")
Eq(err, "UI is restricted", "restricted refresh error")
Eq(#calls, before, "restricted factories and refresh must not dispatch")
restricted = false

value, err = API:Button({})
Eq(value, nil, "non-object return")
Eq(err, "Target is not a UI object", "non-object error")

calls = {}
local shared = { r = 0.2, g = 0.3, b = 0.4 }
local panelOpts = { thickness = 2, state = shared }
Eq(API:Panel(target, panelOpts), target, "nested options return")
local passed = calls[#calls].args[1]
Truth(passed ~= panelOpts, "options table must be copied")
Truth(passed.state ~= shared, "nested options table must be copied")
passed.state.r = 0.9
Eq(shared.r, 0.2, "caller options must not be mutated")
local cyclic = {}; cyclic.self = cyclic
Eq(API:Panel(target, cyclic), target, "cyclic options return")
value, err = API:Panel(target, { state = { r = secretNumber } })
Eq(value, nil, "nested secret return")
Eq(err, "Invalid panel options", "nested secret error")
value, err = API:Theme(target, { borderKey = secretNumber })
Eq(value, nil, "secret option key return")
Eq(err, "Invalid theme options", "secret option key error")
value, err = API:Font(fontString, 12, secretNumber)
Eq(value, nil, "secret font key return")
Eq(err, "Invalid font options", "secret font key error")
value, err = API:Text(fontString, { r = secretNumber, g = 0, b = 0 })
Eq(value, nil, "secret color component return")
Eq(err, "Invalid text color", "secret color component error")
value, err = API:Panel(target, { [secretBoolean] = true })
Eq(value, nil, "secret option table key return")
Eq(err, "Invalid panel options", "secret option table key error")
local guarded = setmetatable({}, { __index = function() error("metamethod must not run") end })
Eq(API:Panel(target, guarded), target, "option metatable isolation")
value, err = API:CreateFrame(parent, secretNumber)
Eq(value, nil, "secret width return")
Eq(err, "Width must be a positive number", "secret width error")
value, err = API:CreateFrame(parent, 10, secretBoolean)
Eq(value, nil, "secret height return")
Eq(err, "Height must be a positive number", "secret height error")
value, err = API:CreateFrame(parent, 10, nil, secretTable)
Eq(value, nil, "secret frame kind return")
Eq(err, "Secret frame kind", "secret frame kind error")
value, err = API:Bar(parent, 100, 12, secretNumber)
Eq(value, nil, "secret texture key return")
Eq(err, "Invalid texture key", "secret texture key error")
value, err = API:Dress(target, secretBoolean)
Eq(value, nil, "secret dress kind return")
Eq(err, "Secret kind", "secret dress kind error")
value, err = API:Dress(target, {}, {})
Eq(value, nil, "ambiguous dress return")
Eq(err, "Ambiguous dress options", "ambiguous dress error")

calls = {}
Eq(API:Dress(target), target, "window return")
Eq(calls[1].name, "Strip", "window strip order")
Eq(calls[2].name, "Panel", "window panel order")
Eq(calls[3].name, "HidePortraits", "window portrait order")
calls = {}
Eq(API:Dress(target, { strip = false, panel = false, portrait = false }), target, "window options")
Eq(#calls, 0, "disabled window steps")
Eq(API:Dress(checkButton, "CHECKBUTTON", {}), checkButton, "control alias")
Eq(calls[#calls].name, "CheckButton", "control alias dispatch")
value, err = API:Dress(target, "unknown")
Eq(value, nil, "unknown kind return")
Eq(err, "Unsupported dress kind", "unknown kind error")

calls = {}
local created = API:CreateFrame(parent, 120, nil, "Button")
Truth(created, "frame factory failed")
Eq(calls[1].args[2], parent, "frame parent")
Eq(calls[1].args[3], 120, "frame width")
Eq(calls[1].args[4], nil, "frame height")
Eq(calls[1].args[5], "BackdropTemplate", "frame template")
Eq(calls[1].args[6], "Button", "frame kind")
value, err = API:CreateFrame(parent, 0)
Eq(value, nil, "invalid width return")
Eq(err, "Width must be a positive number", "invalid width error")
value, err = API:CreateFrame(parent, 10, nil, "SecureUnitButton")
Eq(err, "Unsupported frame kind", "secure template rejected")

local bar = API:Bar(parent, 100, 12)
Truth(bar, "bar factory failed")
local close = API:CloseButton(parent, 24)
Truth(close, "close factory failed")

calls = {}
Eq(API:Refresh(), true, "refresh return")
Eq(calls[1].name, "WidgetRefresh", "widget refresh order")
Eq(calls[2].name, "SkinRefresh", "skin refresh order")

local broken = Frame("Button")
broken.failMethod = "Button"
value, err = API:Button(broken)
Eq(value, nil, "failure return")
Truth(err and err:find("mock failure", 1, true), "failure reason missing")

value, err = API:Font(target, 12)
Eq(value, nil, "wrong font target return")
Eq(err, "Target must be a FontString", "wrong font target error")
value, err = API:Text(target, "neutral")
Eq(value, nil, "wrong text target return")
Eq(err, "Target must be a FontString", "wrong text target error")
value, err = API:Button(parent)
Eq(value, nil, "wrong button target return")
Eq(err, "Target must be a Button", "wrong button target error")
value, err = API:CreateFrame(fontString, 100)
Eq(value, nil, "wrong frame parent return")
Eq(err, "Target must be a Frame", "wrong frame parent error")
local unreadable = setmetatable({}, { __index = function() error("object metamethod must not escape") end })
value, err = API:Panel(unreadable)
Eq(value, nil, "unreadable object return")
Eq(err, "Target is not a UI object", "unreadable object error")

local silent = Frame("Button")
silent.nilMethod = "Panel"
value, err = API:Panel(silent)
Eq(value, nil, "nil skin return")
Eq(err, "Skin operation did not apply", "nil skin error")
silent.nilMethod = nil
silent.failMethod = "Panel"
value, err = API:Dress(silent)
Eq(value, nil, "throwing dress panel return")
Truth(err and err:find("mock failure", 1, true), "throwing dress panel error missing")
silent.failMethod = nil
silent.nilMethod = "Panel"
value, err = API:Dress(silent)
Eq(value, nil, "failed dress panel return")
Eq(err, "Panel could not be applied", "failed dress panel error")
silent.nilMethod = nil

local nilParent = Frame(); nilParent.nilFactory = true
value, err = API:CreateFrame(nilParent, 100)
Eq(value, nil, "nil frame factory return")
Eq(err, "Frame could not be created", "nil frame factory error")
value, err = API:Bar(nilParent, 100)
Eq(value, nil, "nil bar factory return")
Eq(err, "Bar could not be created", "nil bar factory error")
value, err = API:CloseButton(nilParent)
Eq(value, nil, "nil close factory return")
Eq(err, "Close button could not be created", "nil close factory error")

broken.failReason = secretNumber
value, err = API:Button(broken)
Eq(value, nil, "secret error return")
Eq(err, "MonetUI API operation failed", "secret error must not be stringified")
broken.failReason = setmetatable({}, { __tostring = function() error("error metamethod must not escape") end })
value, err = API:Button(broken)
Eq(value, nil, "unreadable error return")
Eq(err, "MonetUI API operation failed", "error stringification must be contained")

print("PASS public API: readiness, guards, dispatch, factories, dressing and refresh")
