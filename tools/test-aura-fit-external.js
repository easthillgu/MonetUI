/**
 * 光环补扫 ticker 的 "external" 销账自测（离线，静态驱动 + 内存变异自检）
 *
 * 钉住三件事：
 *   1) BuffFrame 上样式走 `ns.AuraButtonStyle(button, kind, spec)` —— **只三个参、不传 owner**，
 *      按 Auras.lua `FitGroup` 里 `owner or "external"` 的约定全落进 "external" 那一组；
 *   2) BuffFrame 在自己的生命周期边界上成对销/建这一组，并且**没有**接进 `HideContainer`
 *      （那只收它脱战自绘的 proc/debuff 行，接在那里等于在按钮正要显示的那一刻停补扫）；
 *   3) 全仓扫登记点/销账点，跑 `HasAuraFitWork` 的状态机镜像：任何"可能被挂上"的组都必须
 *      有销账路径 —— 少一条，那条 1 秒 ticker 就永不可取消。
 *
 * `--selftest` 那一段是咬合力证明：在**内存里**把销账站点抹掉/接错位置/给样式调用加第 4 参，
 * 对应断言必须翻红。源码文件一个字节都不改（变异只在 overrides 里）。
 *
 * 用法：node tools/test-aura-fit-external.js [--selftest]
 * 判不了的（实机边界是否被走到、Cancel 是否成功、起停次数）在第 6 段逐条明写，不为绿改断言。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const AURAS = path.join(ROOT, 'Modules', 'UnitFrames', 'Auras.lua');
const BUFFFRAME = path.join(ROOT, 'Modules', 'BuffFrame', 'BuffFrame.lua');
const UNITFRAMES = path.join(ROOT, 'Modules', 'UnitFrames', 'UnitFrames.lua');

let ok = 0, bad = 0;
let mode = 'run';          // 'run' = 真断言；'mutant' = 变异自检，只数翻红条数
let mutantFails = 0;
function t(name, pass, detail) {
  if (mode === 'mutant') { if (!pass) mutantFails++; return; }
  if (pass) ok++; else bad++;
  console.log(`${pass ? '[OK]  ' : '[FAIL]'} ${name}${detail ? '  —— ' + detail : ''}`);
}

// ---- 注释剥离：`--[==[ … ]==]` 里那段被注释掉的 A 方案代码不能当真代码数 ----
function stripComments(src) {
  const out = [];
  let i = 0;
  const blank = (s) => s.replace(/[^\n]/g, ' ');
  while (i < src.length) {
    if (src[i] === '-' && src[i + 1] === '-') {
      const m = /^--\[(=*)\[/.exec(src.slice(i));
      if (m) {
        const close = ']' + m[1] + ']';
        const end = src.indexOf(close, i + m[0].length);
        const stop = end < 0 ? src.length : end + close.length;
        out.push(blank(src.slice(i, stop))); i = stop; continue;
      }
      let end = src.indexOf('\n', i); if (end < 0) end = src.length;
      out.push(blank(src.slice(i, end))); i = end; continue;
    }
    if (src[i] === '"' || src[i] === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== src[i]) { if (src[j] === '\\') j++; j++; }
      out.push(src.slice(i, Math.min(j + 1, src.length))); i = j + 1; continue;
    }
    out.push(src[i]); i++;
  }
  return out.join('');
}

const srcCache = new Map();
const overrides = new Map(); // 变异只进这里，磁盘上的源码不动
function srcOf(p) {
  if (overrides.has(p)) return overrides.get(p);
  if (!srcCache.has(p)) {
    if (!fs.existsSync(p)) { console.error(`读不到文件：${p}`); process.exit(2); }
    const raw = fs.readFileSync(p, 'utf8');
    const s = stripComments(raw);
    // 自检：剥注释不许改行数，否则下面报的 文件:行号 全是假的
    const a = raw.split('\n').length, b = s.split('\n').length;
    if (a !== b) { console.error(`stripComments 把 ${p} 的行数从 ${a} 改成 ${b}，先修它再谈断言`); process.exit(2); }
    srcCache.set(p, s);
  }
  return srcCache.get(p);
}

const lineOf = (src, idx) => src.slice(0, idx).split('\n').length;

// ---- 顶层函数区间：列 0 的 `function`/`local function` 头，到下一个列 0 非空行（`end`）----
// 这几个文件里顶层函数都是列 0 起、`end` 列 0 收，闭包和注释全部缩进在里面（注释已被剥成空白）。
function topFunctions(src) {
  const lines = src.split('\n');
  const list = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^(?:local\s+)?function\s+([\w.:]+)\s*\(([^)]*)\)/.exec(lines[i]);
    if (!m) continue;
    let j = i + 1;
    while (j < lines.length && !/^\S/.test(lines[j])) j++;
    list.push({ name: m[1], params: m[2].split(',').map((s) => s.trim()).filter(Boolean),
      head: i + 1, tail: Math.min(j + 1, lines.length), body: lines.slice(i, j + 1).join('\n') });
  }
  return list;
}
function fnAt(fns, line) {
  let best = null;
  for (const f of fns) {
    if (line >= f.head && line <= f.tail && (!best || f.tail - f.head < best.tail - best.head)) best = f;
  }
  return best;
}

// ---- 顶层实参切分：从 `(` 起扫到配对的 `)`，只在 depth==0 切逗号 ----
function parseArgs(src, openIdx) {
  if (src[openIdx] !== '(') return null;
  let depth = 0, i = openIdx + 1, cur = '', args = [];
  while (i < src.length) {
    const ch = src[i];
    if (ch === '"' || ch === "'") {
      const q = ch; cur += q; i++;
      while (i < src.length && src[i] !== q) {
        if (src[i] === '\\') { cur += src[i] + (src[i + 1] || ''); i += 2; continue; }
        cur += src[i]; i++;
      }
      cur += (src[i] || ''); i++; continue;
    }
    if (ch === '{' || ch === '(' || ch === '[') depth++;
    else if (ch === '}' || ch === ')' || ch === ']') {
      if (depth === 0 && ch === ')') { args.push(cur.trim()); return args; }
      depth--;
    } else if (ch === ',' && depth === 0) { args.push(cur.trim()); cur = ''; i++; continue; }
    cur += ch; i++;
  }
  return null;
}

// 直接调用点 `X.name(` / `name(`（跳过函数定义本身），外加 `pcall(name, a, b, c)` 形态
function calls(src, fnName) {
  const hits = [];
  const re = new RegExp(`(?:[\\w.:]+\\.)?\\b${fnName}\\s*\\(`, 'g');
  let m;
  while ((m = re.exec(src))) {
    const before = src.slice(Math.max(0, m.index - 20), m.index);
    if (/(?:local\s+)?function\s+$/.test(before)) continue; // 定义不是调用
    hits.push({ line: lineOf(src, m.index), args: parseArgs(src, m.index + m[0].length - 1) });
  }
  const re2 = new RegExp(`pcall\\(\\s*${fnName}\\s*,`, 'g');
  while ((m = re2.exec(src))) {
    const all = parseArgs(src, src.indexOf('(', m.index));
    if (all) hits.push({ line: lineOf(src, m.index), args: all.slice(1) }); // 去掉首参（函数本身）
  }
  return hits;
}

const litStr = (a) => ((a || '').trim().match(/^["']([^"']+)["']$/) || [, null])[1];
const litBool = (a) => (a === 'true' ? true : a === 'false' ? false : null);

// 账本实现自身的函数：它们内部的调用是**透传**，不算生命周期边界
const PLUMBING = new Set(['FitGroup', 'HasAuraFitWork', 'RunAuraFit', 'SyncAuraFitTicker',
  'SetFitGroupMounted', 'SetAuraFitMounted', 'ReleaseFitGroup', 'StyleAuraButton', 'SetExternalAuraFit']);

const TARGET_GROUPS = (() => {
  const m = /local TARGET_GROUPS = \{([^}]*)\}/.exec(srcOf(AURAS));
  return (m ? m[1] : '').split(',').map((s) => s.trim()).map(litStr).filter(Boolean);
})();

// ===================== [1] Auras.lua：账本自身的规则 =====================
function checkAurasRules() {
  console.log('\n[1] Auras.lua —— fitGroups 的分组与起停规则');
  const auras = srcOf(AURAS);
  t('FitGroup 把省略的 owner 归到 "external"', /local key = owner or "external"/.test(auras));
  t('新建组默认 mounted = true（没人销账就永远为真）', /g = \{\s*mounted = true/.test(auras));
  t('HasAuraFitWork 只认 mounted 且按钮非空的组', /g\.mounted and next\(g\.buttons\) ~= nil/.test(auras));
  t('SetAuraFitMounted 收 (on, owner)，owner 省略 = TARGET_GROUPS',
    /local function SetAuraFitMounted\(on, owner\)/.test(auras)
    && /if owner then\s+SetFitGroupMounted\(owner, on\)/.test(auras));
  t('TARGET_GROUPS 可解析', TARGET_GROUPS.length > 0, TARGET_GROUPS.join(', '));
  t('销账只标 mounted、不删条目（引擎按钮 initializeFrame 一个按钮只进一次）',
    /g\.mounted = on and true or false/.test(auras)
    && !/SetFitGroupMounted[\s\S]{0,160}?fitGroups\[[^\]]+\]\s*=\s*nil/.test(auras));
  t('ticker 不重复建（`if fitTicker then return end` 是那条门）', /if fitTicker then return end/.test(auras));
  t('摘 ticker 先置 nil 再 Cancel，且 pcall 包住', /fitTicker = nil[\s\S]{0,90}?pcall\(stale\.Cancel, stale\)/.test(auras));
  t('登记处会 SyncAuraFitTicker（组挂上时 ticker 才起）',
    /group\.buttons\[button\] = true[\s\S]{0,240}?SyncAuraFitTicker\(\)/.test(auras));
}

// ===================== [2] 样式调用不传 owner =====================
function checkStyleCalls() {
  console.log('\n[2] BuffFrame —— 样式调用只三个参（⇒ 全落进 "external"）');
  const buff = srcOf(BUFFFRAME);
  const styleCalls = calls(buff, 'AuraButtonStyle');
  t('找到 BuffFrame 的 AuraButtonStyle 调用点', styleCalls.length > 0, `${styleCalls.length} 处`);
  styleCalls.forEach((c) => {
    const n = c.args ? c.args.length : -1;
    t(`BuffFrame.lua:${c.line} 实参 = 3（button, kind, spec）`, n === 3,
      n < 0 ? '括号没配对' : `实到 ${n} 个：${c.args.map((a) => a.replace(/\s+/g, ' ').slice(0, 16)).join(' | ')}`);
    t(`BuffFrame.lua:${c.line} 第 4 参（owner）不存在`, n <= 3, c.args && c.args[3] ? `传了 ${c.args[3]}` : '');
  });
}

// ===================== [3] BuffFrame 的销/建边界 =====================
function checkBoundaries() {
  console.log('\n[3] BuffFrame —— 生命周期边界上的成对销/建');
  const buff = srcOf(BUFFFRAME);
  t('helper 带类型前置 + pcall + 字面 "external"',
    /local function SetExternalAuraFit\(on\)[\s\S]{0,240}?type\(ns\.AuraFitMounted\) ~= "function"[\s\S]{0,140}?pcall\(ns\.AuraFitMounted,\s*on and true or false,\s*"external"\)/.test(buff));
  const buffFns = topFunctions(buff);
  const fit = calls(buff, 'SetExternalAuraFit').map((c) => ({ ...c, fn: fnAt(buffFns, c.line) }));
  const ups = fit.filter((c) => c.args && c.args[0] === 'true');
  const downs = fit.filter((c) => c.args && c.args[0] === 'false');
  t('挂回 ≥1 处', ups.length > 0, ups.map((c) => `${c.line}(${c.fn && c.fn.name})`).join(' '));
  t('销账 ≥1 处', downs.length > 0, downs.map((c) => `${c.line}(${c.fn && c.fn.name})`).join(' '));
  t('容器成型那一路（EnsureCombatAuras 成功支）挂回', ups.some((c) => c.fn && c.fn.name === 'EnsureCombatAuras'));
  t('模块开启那一路（M:SetEnabled 的 enabled 支）挂回', ups.some((c) => c.fn && c.fn.name === 'M:SetEnabled'));
  t('模块关闭那一路（M:SetEnabled 的 else 支）销账', downs.some((c) => c.fn && c.fn.name === 'M:SetEnabled'));
  const failedBranch = downs.filter((c) => c.fn && c.fn.name === 'EnsureCombatAuras');
  t('建容器失败那一路（退回暴雪原生框）也销账',
    failedBranch.some((c) => /pcall\(buffs\.Hide, buffs\)/.test(buff.split('\n').slice(c.fn.head - 1, c.line).join('\n'))),
    failedBranch.map((c) => c.line).join(' ') || 'EnsureCombatAuras 里没有 false 站点');
  const hc = buff.split('\n').findIndex((l) => /^local function HideContainer/.test(l));
  t('销账**没有**接进 HideContainer（它只收自绘的 proc/debuff 行）',
    hc >= 0 && !/SetExternalAuraFit/.test(buff.split('\n').slice(hc, hc + 8).join('\n')));
  t('没往暴雪对象写字段、没挂 HookScript',
    !/SetExternalAuraFit[\s\S]{0,140}?\.(aura|auraInstanceID|monet\w+)\s*=/.test(buff)
    && !/HookScript|hooksecurefunc/.test(fit.map((c) => (buff.split('\n')[c.line - 1] || '') + '\n').join('')));
}

// ===================== [4] UnitFrames 的对称性 =====================
function checkUnitFrames() {
  console.log('\n[4] UnitFrames —— 目标框两组的对照组');
  t('M:SetEnabled 调 SetFitMounted（owner 省略 = 目标框两组）',
    /M\.auras\.SetFitMounted\(enabled and true or false\)/.test(srcOf(UNITFRAMES)));
}

// ===================== [5] 全仓镜像：谁能把 ticker 钉住 =====================
function luaFilesUnder(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'Libs' || e.name === 'tools') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) luaFilesUnder(p, acc);
    else if (e.name.endsWith('.lua')) acc.push(p);
  }
  return acc;
}

// owner 写成变量时：先看它是不是所在顶层函数的形参（再取该函数调用点同位置的字面量），
// 其次看它是不是 `for _, X in ipairs(TARGET_GROUPS)` 的循环变量；都不成立就报"不可证"。
function resolveOwner(src, fn, ident) {
  if (!fn) return null;
  const idx = fn.params.indexOf(ident);
  if (idx >= 0) {
    const found = [];
    calls(src, fn.name).forEach((c) => { const lit = litStr(c.args && c.args[idx]); if (lit) found.push(lit); });
    return found.length ? [...new Set(found)] : null;
  }
  if (new RegExp(`for[^=\n]*,\\s*${ident}\\s+in ipairs\\(TARGET_GROUPS\\)`).test(fn.body)) return TARGET_GROUPS;
  return null;
}

function buildMirror() {
  const groups = new Map(); // owner -> { register: [], unmount: [], nominal: [] }
  const note = (owner, kind, where) => {
    if (!groups.has(owner)) groups.set(owner, { register: [], unmount: [], nominal: [] });
    const st = groups.get(owner);
    (st[kind] || (st[kind] = [])).push(where);
  };
  TARGET_GROUPS.forEach((g) => note(g, 'nominal', 'TARGET_GROUPS 声明'));
  const unpinned = new Set(); // 没有登记点的组不算被钉住

  for (const file of luaFilesUnder(ROOT, [])) {
    const src = srcOf(file);
    const fns = topFunctions(src);
    const rel = path.relative(ROOT, file).replace(/\\/g, '/');

    // ① 登记点：StyleAuraButton / AuraButtonStyle —— 第 4 参是 owner，省略 = "external"
    for (const fnName of ['AuraButtonStyle', 'StyleAuraButton']) {
      for (const c of calls(src, fnName)) {
        const fn = fnAt(fns, c.line);
        if (fn && PLUMBING.has(fn.name)) continue; // 账本自身内部
        const ownerArg = c.args && c.args[3];
        if (!ownerArg) { note('external', 'register', `${rel}:${c.line} ${fnName}() 省略 owner`); continue; }
        const lit = litStr(ownerArg);
        if (lit) { note(lit, 'register', `${rel}:${c.line} ${fnName}()`); continue; }
        const r = resolveOwner(src, fn, ownerArg.trim());
        if (r) r.forEach((o) => note(o, 'register', `${rel}:${c.line} ${fnName}(${ownerArg}) ← ${fn.name}() 调用点实参`));
        else console.log(`  [不可证] ${rel}:${c.line} ${fnName} 的 owner 是变量 ${ownerArg}，静态定不了组名`);
      }
    }
    // ② 挂/销：AuraFitMounted / SetFitMounted —— (on, owner)，owner 省略 = TARGET_GROUPS
    for (const fnName of ['AuraFitMounted', 'SetFitMounted', 'SetExternalAuraFit']) {
      for (const c of calls(src, fnName)) {
        const fn = fnAt(fns, c.line);
        if (fn && PLUMBING.has(fn.name)) {
          if (mode === 'run') console.log(`  [透传] ${rel}:${c.line} 在 ${fn.name}() 体内，不计入边界`);
          continue;
        }
        const on = litBool(c.args && c.args[0]);
        let owners;
        if (fnName === 'SetExternalAuraFit') owners = ['external']; // helper 把组名写死在体内
        else {
          const ownerArg = c.args && c.args[1];
          if (ownerArg && litStr(ownerArg)) owners = [litStr(ownerArg)];
          else if (ownerArg) {
            const r = resolveOwner(src, fn, ownerArg.trim());
            owners = r || [];
            if (!r && mode === 'run') console.log(`  [不可证] ${rel}:${c.line} ${fnName} 的 owner 是变量 ${ownerArg}`);
          } else owners = TARGET_GROUPS;
        }
        owners.forEach((o) => {
          if (on === true) note(o, 'register', `${rel}:${c.line} ${fnName}(true)`);
          if (on === false) note(o, 'unmount', `${rel}:${c.line} ${fnName}(false)`);
          if (on === null) { note(o, 'register', `${rel}:${c.line} 条件站点`); note(o, 'unmount', `${rel}:${c.line} 条件站点`); }
        });
      }
    }
    // ③ 扔容器 = 销账
    for (const c of calls(src, 'ReleaseFitGroup')) {
      const fn = fnAt(fns, c.line);
      if (fn && PLUMBING.has(fn.name)) continue;
      const lit = litStr(c.args && c.args[0]);
      const owners = lit ? [lit] : (resolveOwner(src, fn, (c.args && c.args[0] || '').trim()) || []);
      owners.forEach((o) => note(o, 'unmount', `${rel}:${c.line} ReleaseFitGroup(容器扔掉)`));
    }
  }
  return groups;
}

function checkMirror() {
  console.log('\n[5] 全仓镜像 HasAuraFitWork —— 每个可能被挂上的组都要有销账路径');
  const groups = buildMirror();
  for (const [name, st] of groups) {
    const canMount = (st.register.length || 0) > 0 || (st.nominal.length || 0) > 0;
    const unmount = st.unmount.length || 0;
    const pinned = canMount && unmount === 0;
    if (!pinned) unpinnedAdd(name);
    t(`组 "${name}"：登记 ${(st.register || []).length} 点（名义 ${(st.nominal || []).length}）/ 销账 ${unmount} 点 ⇒ ticker ${pinned ? '会被钉死' : '可停'}`,
      !pinned, [...(st.register || []), ...(st.unmount || [])].filter(Boolean).join(' ; '));
  }
  t('镜像覆盖到 TARGET_GROUPS 全部组名 + "external"',
    TARGET_GROUPS.every((g) => groups.has(g)) && groups.has('external'), [...groups.keys()].join(', '));
  return groups;
}
let canStopGroups = [];
function unpinnedAdd(name) { canStopGroups.push(name); }

// ===================== [6] 离线不可证 =====================
function reportUnknown() {
  console.log('\n[6] 离线不可证（留给实机）');
  console.log('  · 这些边界在实机是否真被走到：M:SetEnabled(false) / EnsureCombatAuras 成功支与失败支');
  console.log('  · C_Timer ticker 的 Cancel() 是否成功、起停次数是否真的归零');
  console.log('  · 关 BuffFrame 时目标框两组仍在场 ⇒ ticker 继续跑（设计如此，不是漏），要游戏内确认观感');
  console.log('  · 重新开启后时长字体是否还补得回来（条目只标退场、未删）');
  console.log('  · /mui buffframe probe 只数 GetChildren 个数，覆盖不到这一条');
}

// ===================== 变异自检：证明上面那些断言真的会咬人 =====================
function selftest() {
  console.log('\n[7] 咬合力自检（内存变异，源码不动）');
  const clean = srcOf(BUFFFRAME);
  const mutants = [
    { name: 'M1 抹掉 BuffFrame 全部两处销账（状态机该报钉死）',
      file: BUFFFRAME, src: clean.split('SetExternalAuraFit(false)').join('-- MUT'),
      run: checkMirror, expect: 'external 被报成钉死',
      after: () => canStopGroups.indexOf('external') < 0 },
    { name: 'M2 只抹掉建容器失败支那条销账',
      file: BUFFFRAME, src: clean.replace('SetExternalAuraFit(false)\n        return false', '-- MUT\n        return false'),
      run: checkBoundaries, expect: '失败支那条翻红', after: null },
    { name: 'M3 只抹掉 M:SetEnabled 关闭支那条销账',
      file: BUFFFRAME, src: clean.replace('SetExternalAuraFit(false)\n    end', '-- MUT\n    end'),
      run: checkBoundaries, expect: '模块关闭支那条翻红', after: null },
    { name: 'M4 把销账接进 HideContainer（旧注释给错的方位）',
      file: BUFFFRAME, src: clean.replace('    container:Hide()', '    container:Hide()\n    SetExternalAuraFit(false)'),
      run: checkBoundaries, expect: '"没有接进 HideContainer" 翻红', after: null },
    { name: 'M5 给 ns.AuraButtonStyle 调用补第 4 参 "external"',
      file: BUFFFRAME, src: clean.replace('ns.AuraButtonStyle(button, kind, {', 'ns.AuraButtonStyle(button, kind, "external", {'),
      run: checkStyleCalls, expect: '"实参 = 3" 与"第 4 参不存在"翻红', after: null },
    { name: 'M6 摘掉 helper 的类型前置（模块没加载就抛错）',
      file: BUFFFRAME, src: clean.replace('if type(ns.AuraFitMounted) ~= "function" then return end', ''),
      run: checkBoundaries, expect: 'helper 那条翻红', after: null },
  ];
  for (const mu of mutants) {
    if (mu.src === clean) { t(`  ${mu.name}`, false, '变异没落地（模式串没匹配上，这条自检是空的）'); continue; }
    overrides.set(mu.file, mu.src);
    canStopGroups = [];
    mutantFails = 0;
    mode = 'mutant';
    mu.run();
    mode = 'run';
    const flipped = mutantFails > 0;
    t(`  ${mu.name} ⇒ ${mu.expect}`, flipped, `翻红 ${mutantFails} 条`);
    if (mu.after) t(`  ${mu.name} ⇒ 状态机结论（${mu.expect}）`, mu.after(), `可停的组：${canStopGroups.join(', ') || '(无)'}`);
    overrides.delete(mu.file);
  }
}

checkAurasRules();
checkStyleCalls();
checkBoundaries();
checkUnitFrames();
checkMirror();
reportUnknown();
if (process.argv.includes('--selftest')) selftest();

console.log('\n' + (bad === 0 ? `全部通过（${ok} 项）` : `${bad} 项未通过（通过 ${ok}）`));
process.exit(bad === 0 ? 0 : 1);
