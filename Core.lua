-- MonetUI Core.lua
-- Core entry point: initialization + module management + MonetColor integration

local ADDON_NAME, ns = ...

-- ============================================================================
-- Libraries
-- ============================================================================

local LibStub = LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

-- ============================================================================
-- Private State
-- ============================================================================

local modules = {}
local initialized = false

-- ============================================================================
-- Module Registry
-- ============================================================================

function ns:Register(name, moduleTable)
    assert(type(name) == "string", "Module name must be a string")
    assert(type(moduleTable) == "table", "Module must be a table")
    modules[name] = moduleTable
end

function ns:GetModule(name)
    return modules[name]
end

function ns:HasMonetColor()
    return LMC ~= nil
end

function ns:Run()
    if initialized then return end
    initialized = true

    for name, module in pairs(modules) do
        if module.Initialize then
            local ok, err = pcall(module.Initialize, module)
            if not ok then
                print("|cFFFF6B6B[MonetUI]|r Module '" .. name .. "' failed: " .. tostring(err))
            end
        end
    end
end

-- ============================================================================
-- Event Frame
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        ns:Run()
    end
end)

-- ============================================================================
-- Public API
-- ============================================================================

-- Global access
_G.MonetUI = ns

print("|cFF88AAFF[MonetUI]|r Core loaded. MonetColor: " .. (LMC and "|cFF00FF00found|r" or "|cFFFF6B6Bnot found|r"))
