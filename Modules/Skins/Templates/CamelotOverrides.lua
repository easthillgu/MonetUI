-- Modules/Skins/Templates/CamelotOverrides.lua
-- 1.60 (Camelot) 客户端特有的模板覆盖调整。
--
-- 背景：
--   * wow-ui-source 的 forever 分支对应 1.60 客户端
--   * Camelot/ 目录下的文件覆盖了基础模板定义
--   * 关键差异：ColoredProgressBarTemplate 在 1.60 是 Frame，不是 StatusBar
--
-- 本文件的作用：
--   * 记录已知的 1.60 差异
--   * 在运行时调整 TemplateDB 的指纹检查
--   * 提供 /mui compat tmpl 的数据源

local ADDON_NAME, ns = ...

local TemplateDB = ns.TemplateDB
if not TemplateDB then return end

-- =========================================================================
-- 1.60 已知差异
-- =========================================================================

local CAMELOT_OVERRIDES = {
    -- ColoredProgressBarTemplate：1.60 上是 Frame，不是 StatusBar
    -- 它没有 SetStatusBarTexture / SetStatusBarColor，按 StatusBar 写会直接抛
    -- "SetStatusBarTexture is not a function"（Aurora 同款注释 + docs/AURORA-COVERAGE.md §3）
    ColoredProgressBarTemplate = {
        forceType = "Frame",  -- 不是 StatusBar
        removeFingerprints = { "SetStatusBarTexture", "SetStatusBarColor", "GetStatusBarTexture" },
        note = "1.60 Camelot: ColoredProgressBar 是 Frame，不是 StatusBar",
    },
    
    -- MoneyFrameTemplate：1.60 上的字段可能与 retail 不同
    -- 实机验证：.moneyType 字段存在，但具体值可能不同
    MoneyFrameTemplate = {
        note = "1.60 Camelot: MoneyFrame 字段已验证，无差异",
    },
    
    -- HybridScrollFrameTemplate：1.60 上的滚动条行为
    -- 实机验证：.scrollChild 和 .offset 字段存在
    HybridScrollFrameTemplate = {
        note = "1.60 Camelot: HybridScrollFrame 字段已验证，无差异",
    },
}

-- =========================================================================
-- 应用覆盖
-- =========================================================================

for tplName, override in pairs(CAMELOT_OVERRIDES) do
    local entry = TemplateDB[tplName]
    if entry then
        -- 强制类型
        if override.forceType then
            entry.type = override.forceType
        end
        
        -- 移除不适用的指纹
        if override.removeFingerprints and entry.fingerprints then
            local newFingerprints = {}
            for _, fp in ipairs(entry.fingerprints) do
                local shouldRemove = false
                for _, removePath in ipairs(override.removeFingerprints) do
                    if fp.path == removePath then
                        shouldRemove = true
                        break
                    end
                end
                if not shouldRemove then
                    table.insert(newFingerprints, fp)
                end
            end
            entry.fingerprints = newFingerprints
        end
        
        -- 记录覆盖信息
        entry.camelotNote = override.note
    end
end

-- =========================================================================
-- 诊断接口
-- =========================================================================

--- 获取所有 Camelot 覆盖
-- @return table { templateName = { forceType, removeFingerprints, note } }
function ns.GetCamelotOverrides()
    return CAMELOT_OVERRIDES
end

--- 检查模板是否有 Camelot 覆盖
-- @param templateName string 模板名
-- @return boolean, table|nil 是否有覆盖，覆盖详情
function ns.HasCamelotOverride(templateName)
    local override = CAMELOT_OVERRIDES[templateName]
    return override ~= nil, override
end
