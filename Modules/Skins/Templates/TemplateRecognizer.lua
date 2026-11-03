-- Modules/Skins/Templates/TemplateRecognizer.lua
-- 增强版模板识别引擎：先查模板数据库，再回退到结构指纹。
--
-- 设计原则：
--   * 数据库查询优先：TemplateDB 里有 387 个模板定义，覆盖 Aurora 的 26 个 SharedXML 皮肤文件目标
--   * 弱键缓存：对象 -> 模板名，避免重复查询
--   * 类型索引：按 Frame 类型分区（Button/Frame/ScrollFrame），减少不必要的指纹检查
--   * 指纹短路：先检查最具选择性的指纹（如 .moneyType 比 .Fill 更稀有）
--
-- 纪律（AGENTS.md）：
--   * 不往暴雪框体写字段 —— 簿记一律走 ns:Mark 旁表
--   * forbidden 对象上连 GetObjectType 都会抛，所以每一次读都 pcall
--   * 机密值先 issecretvalue 再 tostring

local ADDON_NAME, ns = ...

local Skin = ns.Skin
local TemplateDB = ns.TemplateDB

-- 弱键缓存：对象 -> 模板名
local recognized = setmetatable({}, { __mode = "k" })

-- 类型索引：按 Frame 类型分组模板，加速查询
local typeIndex = {}
if TemplateDB then
    for name, entry in pairs(TemplateDB) do
        local t = entry.type
        if not typeIndex[t] then
            typeIndex[t] = {}
        end
        table.insert(typeIndex[t], name)
    end
end

--- 检查对象是否匹配单个模板的指纹集
-- @param obj Frame 对象
-- @param entry TemplateDB 条目
-- @return boolean 是否匹配
function Skin:MatchFingerprints(obj, entry)
    if not entry.fingerprints then return false end
    
    for _, fp in ipairs(entry.fingerprints) do
        local ok, val = pcall(function()
            if fp.kind == "field" then
                return obj[fp.path]
            elseif fp.kind == "method" then
                local m = obj[fp.path]
                return type(m) == "function"
            elseif fp.kind == "child" then
                local c = obj[fp.path]
                return type(c) == "table"
            end
        end)
        
        if not ok or val == nil or val == false then
            return false
        end
    end
    
    return true
end

--- 从模板数据库查找对象对应的模板
-- @param obj Frame 对象
-- @return string|nil 模板名（如 "MoneyFrameTemplate"），nil 表示未找到
function Skin:LookupTemplate(obj)
    if not obj then return nil end
    
    -- 查缓存
    if recognized[obj] then
        return recognized[obj]
    end
    
    -- 获取对象类型
    local okKind, kind = pcall(obj.GetObjectType, obj)
    if not okKind or type(kind) ~= "string" then
        return nil
    end
    
    -- 按类型索引查询（只检查同类型的模板）
    local candidates = typeIndex[kind]
    if not candidates then
        return nil
    end
    
    -- 遍历候选模板
    for _, tplName in ipairs(candidates) do
        local entry = TemplateDB[tplName]
        if entry and self:MatchFingerprints(obj, entry) then
            -- 命中，缓存并返回
            recognized[obj] = tplName
            return tplName
        end
    end
    
    return nil
end

--- 增强版识别：先查数据库，再回退到结构指纹
-- @param obj Frame 对象
-- @return string|nil 识别类型（如 "money", "coloredbar", "button"），nil 表示不认识
function Skin:RecognizeEnhanced(obj)
    if not obj then return nil end
    
    -- 第一层：查模板数据库
    if TemplateDB then
        local tplName = self:LookupTemplate(obj)
        if tplName then
            local entry = TemplateDB[tplName]
            if entry and entry.skinAs then
                return entry.skinAs
            end
        end
    end
    
    -- 第二层：回退到原有结构指纹（Utils/SkinTemplates.lua 的 Skin:Recognize）
    -- 这个函数会被 Skin:Recognize 调用，所以这里不重复实现
    return nil
end

--- 诊断：统计数据库覆盖情况
-- @return table { total, mapped, camelot, bySkinAs }
function Skin:TemplateDBStats()
    if not TemplateDB then
        return { total = 0, mapped = 0, camelot = 0, bySkinAs = {} }
    end
    
    local stats = {
        total = 0,
        mapped = 0,
        camelot = 0,
        bySkinAs = {},
    }
    
    for name, entry in pairs(TemplateDB) do
        stats.total = stats.total + 1
        
        if entry.skinAs then
            stats.mapped = stats.mapped + 1
            stats.bySkinAs[entry.skinAs] = (stats.bySkinAs[entry.skinAs] or 0) + 1
        end
        
        if entry.camelotOnly then
            stats.camelot = stats.camelot + 1
        end
    end
    
    return stats
end
