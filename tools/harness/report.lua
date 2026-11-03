-- tools/harness/report.lua
-- 台账：替身与 run.lua 往这里记，最后由 run.js 打成人读报告 + 退出码。
--
-- 记账原则（和 api_stub.lua 一致）：
--   * **先记账再抛**，所以谁的 pcall 都吞不掉一条红；
--   * 同 key 只留第一次的现场（栈、文件、行），但累计次数 —— 一次 Apply 里同一个写入
--     可能重复几百次，人要看的是"几处、各处几次"；
--   * `guarded` 是被调用方自己 pcall 包住的那些：**不判红**，只统计。它们是"知道会拒、
--     主动放手"的正常路径；一旦哪天守卫被删掉，同一条账就升成 red，这就是断言二的价值。
--
-- 五类断言 ↔ 类名：
--   一 加载期 / 首次 Apply 出错          A0（脚本抛错）A0p（被 print 吞掉的失败）A1s
--      A0b 是"被继承型保护（A2i）打断的脚本"：同一条猜测不配两条红，停在水位以下。
--   二 受限状态下未守卫的暴雪写入        A2（red=未守卫，guarded=已放手）A2c A1b
--      A2i 是"保护只从父框继承来的自建子件"：离线没有这条判据的证据，记黄不记红，留给实机。
--      A2r 是"文档标 fl.r（受限，只能安全代码调）的 C_ 方法被本插件调到"：只有一文档快照一份
--      证据，够列清单、不够判红，同样留黄给上线首日点名复核。
--   三 往暴雪对象写字段 / 挂钩子         A3 A3h A3s
--   四 α 继承把带背板的容器打到 0        A4（红=收敛后仍为 0）A4t（动画中间态，只记黄）
--   五 Skin:Need 命中 / 缺席             A5（✗ 清单，不算 FAIL，是上线首日目标清单）

local Report = {}

local LEVELS = { red = 1, warn = 2, guarded = 3, info = 4 }

-- 类名 -> 断言编号（渲染时按断言分组）
local CLASS_ASSERT = {
    A0 = 1, A0p = 1, A0b = 1, A1s = 1, A1t = 1,
    A2 = 2, A2c = 2, A2i = 2, A2r = 2, A1b = 2,
    A3 = 3, A3h = 3, A3s = 3,
    A4 = 4, A4t = 4,
    A5 = 5,
    -- run.lua 自己的账
    L = 1, X = 1,
}
local ASSERT_TITLE = {
    "断言一：加载与首次 Apply 不得抛错",
    "断言二：受限窗口内不得有未守卫的暴雪写入",
    "断言三：不得往暴雪对象写字段 / 挂钩子",
    "断言四：带背板的容器有效 α 必须 > 0",
    "断言五：Skin:Need 命中 / 缺席台账",
}

function Report.New()
    local rep = { rows = {}, keys = {}, counters = {}, phases = {}, currentPhase = "-" }
    return setmetatable(rep, { __index = Report })
end

function Report.Phase(self, name)
    self.currentPhase = name
    self.phases[name] = (self.phases[name] or 0) + 1
end

--- 记一条。cls 类名，level 见 LEVELS，key 去重键，detail 现场。
function Report.Add(self, cls, level, key, detail)
    if not level then level = "red" end
    local c = self.counters[cls]
    if not c then c = { red = 0, warn = 0, guarded = 0, info = 0, n = 0 }; self.counters[cls] = c end
    c[level] = (c[level] or 0) + 1
    c.n = c.n + 1
    local slot = self.keys[key]
    if slot then
        slot.n = slot.n + 1
        return slot
    end
    local row = {
        cls = cls, level = level, key = key, n = 1,
        phase = self.currentPhase,
        detail = detail or {},
    }
    self.keys[key] = row
    self.rows[#self.rows + 1] = row
    return row
end

--- 某类某级别的条数（去重后的"处"数）与累计次数
function Report.Split(self, cls, level)
    local places, times = 0, 0
    for _, row in ipairs(self.rows) do
        if row.cls == cls and row.level == level then
            places = places + 1
            times = times + row.n
        end
    end
    return places, times
end

local function shortPath(p)
    if type(p) ~= "string" then return "?" end
    p = p:gsub("\\", "/")
    local i = p:find("MonetUI/", 1, true)
    if i then p = p:sub(i + 8) end
    i = p:find("/harness/", 1, true)
    if i then p = p:sub(i + 9) end
    return p
end

local function where(row)
    local d = row.detail or {}
    local f, l = d.file or d.atFile, d.line or d.atLine
    if f then return string.format("%s:%s", shortPath(tostring(f)), tostring(l or "?")) end
    return tostring(row.phase or "?")
end

--- 汇总：返回 { checks, reds, warns, guardeds, infos, fails = reds>0 }
function Report.Summary(self)
    local reds, warns, guardeds, infos = 0, 0, 0, 0
    for _, row in ipairs(self.rows) do
        if row.level == "red" then reds = reds + row.n
        elseif row.level == "warn" then warns = warns + row.n
        elseif row.level == "guarded" then guardeds = guardeds + row.n
        else infos = infos + row.n end
    end
    return {
        reds = reds, warns = warns, guarded = guardeds, infos = infos,
        places = #self.rows,
        fails = reds > 0,
    }
end

--- 每个断言类：{ assert = n, classes = {cls...}, redPlaces, redTimes, guardPlaces, ... }
function Report.ByAssert(self)
    local out = {}
    for cls in pairs(self.counters) do
        local n = CLASS_ASSERT[cls] or 0
        out[n] = out[n] or { assert = n, classes = {}, redP = 0, redT = 0, warnP = 0, guardP = 0, infoP = 0 }
        local bucket = out[n]
        bucket.classes[#bucket.classes + 1] = cls
        local c = self.counters[cls]
        for _, row in ipairs(self.rows) do
            if row.cls == cls then
                if row.level == "red" then bucket.redP = bucket.redP + 1; bucket.redT = bucket.redT + row.n
                elseif row.level == "warn" then bucket.warnP = bucket.warnP + 1
                elseif row.level == "guarded" then bucket.guardP = bucket.guardP + 1
                else bucket.infoP = bucket.infoP + 1 end
            end
        end
    end
    table.sort(out, function(a, b) return a.assert < b.assert end)
    return out
end

--- 渲染成人读文本。opts { max = 每组最多列几条, gaps = api 的覆盖面台账 }
function Report.Render(self, opts)
    opts = opts or {}
    local max = opts.max or 12
    local out = {}
    local function push(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

    local s = self:Summary()
    push("== MonetUI 离线 harness 台账 ==")
    if opts.meta then
        for _, line in ipairs(opts.meta) do push("%s", line) end
    end
    push("")

    for _, bucket in ipairs(self:ByAssert()) do
        local title = ASSERT_TITLE[bucket.assert] or ("其它（类 " .. table.concat(bucket.classes, ",") .. "）")
        local verdict
        if bucket.redP > 0 then verdict = "FAIL"
        elseif bucket.assert == 5 then verdict = "清单"
        else verdict = "PASS" end
        push("[%s] %s", verdict, title)
        push("      红 %d 处 / 累计 %d 次 · 警告 %d 处 · 已放手(guarded) %d 处 · 信息 %d 处",
            bucket.redP, bucket.redT, bucket.warnP, bucket.guardP, bucket.infoP)
        -- 明细：红优先，然后警告
        local order = { "red", "warn" }
        for _, want in ipairs(order) do
            local shown, total = 0, 0
            for _, row in ipairs(self.rows) do
                if row.level == want and CLASS_ASSERT[row.cls] == bucket.assert then total = total + 1 end
            end
            for _, row in ipairs(self.rows) do
                if row.level == want and CLASS_ASSERT[row.cls] == bucket.assert then
                    if shown < max then
                        shown = shown + 1
                        local d = row.detail or {}
                        -- 断言二的每一刀都要能自证：光给框名看不出"凭什么算受保护写入"，
                        -- 所以把 op 与判据来源（文档 fl.pm 的类型 / 替身手抄清单）一起打出来。
                        local what = tostring(d.frame or d.msg or d.field or d.op or d.path or "")
                        if d.op and d.frame then
                            what = string.format("%s:%s() ← 判据 %s", d.frame, d.op, tostring(d.evidence or "?"))
                        end
                        push("      %-8s %-14s ×%-4d %s  [%s]",
                            row.cls, want, row.n, where(row), what)
                    end
                end
            end
            if total > shown then
                push("      …另有 %d 条同类（tools/harness/report.lua max 可调）", total - shown)
            end
        end
        push("")
    end

    ---------------------------------------------------------------- harness 覆盖面
    local gaps = opts.gaps
    if gaps then
        push("== harness 自身覆盖面（不是产品缺陷，但决定了离线结论的可信边界）==")
        local function countDump(title, tbl, limit)
            local n = 0
            for _ in pairs(tbl or {}) do n = n + 1 end
            if n == 0 then return end
            push("  %s：%d 项", title, n)
            local list = {}
            for k, v in pairs(tbl or {}) do list[#list + 1] = { k, type(v) == "table" and (v.n or 1) or v } end
            table.sort(list, function(a, b) return tostring(a[1]) < tostring(b[1]) end)
            for i = 1, math.min(limit or 8, #list) do
                push("    ×%-5d %s", tonumber(list[i][2]) or 0, tostring(list[i][1]))
            end
            if #list > (limit or 8) then push("    …另有 %d 项", #list - (limit or 8)) end
        end
        countDump("客户端有这个名字、替身只给了空实现（C_* / Widget 方法 / 全局）", gaps.stubGaps)
        countDump("文档里也查不到的方法名（真客户端同样给 nil）", gaps.gapMethods)
        countDump("文档里没有的 API（真客户端会给 nil）", gaps.unknownApi)
        countDump("Enum 里查不到的类型", gaps.enumGaps)
        countDump("FrameXML 确有此名、替身没给的 helper / 常量（相应分支离线没跑过）", gaps.helperGaps)
        countDump("读了但这个世界里没有的暴雪名字（与断言五的 ✗ 同账）", gaps.unknownGlobals)
        push("")
    end

    ---------------------------------------------------------------- 结论
    push("== 结论 ==")
    push("红 %d 处（累计 %d 次）· 警告 %d 处 · 已放手 %d 处 · 信息 %d 处 · 台账共 %d 个去重键",
        (function() local p = 0 for _, b in ipairs(self:ByAssert()) do p = p + b.redP end return p end)(),
        s.reds, s.warns, s.guarded, s.infos, s.places)
    push(s.fails and "总体：FAIL —— 有未守卫的红，上线前必须逐条处置。"
        or "总体：PASS —— 本次执行范围内没有红（覆盖面见上面 harness 自身一节）。")
    return table.concat(out, "\n")
end

return Report
