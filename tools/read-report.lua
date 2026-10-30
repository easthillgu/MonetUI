-- tools/read-report.lua
-- 读 SavedVariables 里的诊断账本（`/mui colors` → colorReport、`/mui compat` → compatReport）。
-- 为什么要它：聊天框只留最后十几行，多行结论一定被顶掉（HANDOFF 8.13.6①"结果只认账本"）,
-- 而落盘比 /reload 晚 1–2 分钟 —— 这个脚本就是"过一会儿自己再看一次"的那条路。
-- 用法：lua tools/read-report.lua "<WTF>/Account/<账号>/SavedVariables/MonetUI.lua" [报告名]
--   报告名默认全部（colorReport / compatReport 都印）；数据是纯表，所以 load 进一个空 env 就跑完了。

local path = arg[1]
if not path then
    print("用法：lua tools/read-report.lua <SavedVariables/MonetUI.lua> [colorReport|compatReport]")
    os.exit(2)
end

local env = {}
local chunk, err = loadfile(path, "t", env)
if not chunk then
    print("读不了：" .. tostring(err))
    os.exit(1)
end
local ok, runErr = pcall(chunk)
if not ok then
    print("执行存档失败（多半是里面混了函数或被截断）：" .. tostring(runErr))
    os.exit(1)
end

local db = rawget(env, "MonetUIDB")
if type(db) ~= "table" then
    print("这份存档里没有 MonetUIDB（插件从没存过盘？）")
    os.exit(1)
end

local function pad(s, w)
    s = tostring(s)
    if #s >= w then return s:sub(1, w) end
    return s .. string.rep(" ", w - #s)
end

local wanted = arg[2]

local function showColor(r)
    print(string.format("colorReport  %s | %s | %s",
        pad(r.when or "?", 19), pad(r.client or "?", 28), pad(r.source or "?", 8)))
    print(string.format("  区域 %s mapID=%s 来源=%s 档位=%s 阈值=%s 过线 %s/%s",
        tostring(r.zone or "?"), tostring(r.mapID or "?"), tostring(r.envSource or "?"),
        r.steps and (table.concat((function()
            local out = {}
            for _, key in ipairs(r.keys or { "panel", "lost", "weave", "fill" }) do
                out[#out + 1] = key .. "=" .. tostring(r.steps[key])
            end
            return out
        end)(), "/")) or "?",
        tostring(r.min or "?"), tostring(r.passed or "?"), tostring(r.checked or "?")))
    if type(r.cr) == "table" then
        local keys = {}
        for k in pairs(r.cr) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            print(string.format("  %-10s %s", keys[i], tostring(r.cr[keys[i]])))
        end
    end
    if type(r.colors) == "table" then
        local keys = {}
        for k in pairs(r.colors) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            local c = r.colors[keys[i]]
            print(string.format("  %-6s r=%.3f g=%.3f b=%.3f  L*=%s",
                keys[i], c.r or 0, c.g or 0, c.b or 0, tostring(r.levels and r.levels[keys[i]] or "?")))
        end
    end
end

local function showCompat(r)
    print(string.format("compatReport %s | %s | %d 项，与假设不符 %s",
        pad(r.when or "?", 19), pad(r.client or "?", 28), tonumber(r.total) or -1, tostring(r.odd)))
    if type(r.rows) == "table" then
        for i = 1, #r.rows do
            local row = r.rows[i]
            if type(row) == "table" then
                print("  " .. table.concat((function()
                    local out = {}
                    for j = 1, #row do out[j] = tostring(row[j]) end
                    return out
                end)(), " | "))
            end
        end
    end
end

local printed = 0
if (not wanted or wanted == "colorReport") and type(db.colorReport) == "table" then
    showColor(db.colorReport)
    printed = printed + 1
end
if (not wanted or wanted == "compatReport") and type(db.compatReport) == "table" then
    showCompat(db.compatReport)
    printed = printed + 1
end
if printed == 0 then
    print("存档里没有" .. (wanted or "colorReport / compatReport") .. "：命令跑过吗？落盘要等 1–2 分钟。")
    print("现有的顶层键： " .. table.concat((function()
        local out = {}
        for k in pairs(db) do out[#out + 1] = k end
        table.sort(out)
        return out
    end)(), ", "))
end
