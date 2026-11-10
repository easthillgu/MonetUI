#!/usr/bin/env node
'use strict';

// 发布版剥离（只给 .github/workflows/release.yml 用，跑在 checkout 出来的工作区上）。
//
// 仓库与本地部署永远是 dev：
//   * MonetUI.toc 的 `## X-Dev-Build: dev` 让 Core.lua 打开 ns.dev（诊断命令 + 自检提示）；
//   * Modules/Tools/Tools.xml 里带 DEV-ONLY 行尾标记的两行照常加载 DevTools / Report；
//   * tools/ 本身列在 .pkgmeta 的 ignore 里，这份脚本不会进发布包。
//
// 发版时本脚本把 TOC 标记改成 release、从 XML 摘掉那两行；.pkgmeta 再把两个文件
// 物理排除出 zip。三处合起来 = 发布版看不到、跑不了、也不含 dev 专属文件。
// 幂等防呆：只允许从 dev 状态剥离，重复执行会报错退出，不会悄悄改坏。

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TOC = path.join(ROOT, 'MonetUI.toc');
const XML = path.join(ROOT, 'Modules', 'Tools', 'Tools.xml');
const PKGMETA = path.join(ROOT, '.pkgmeta');
const TOOLS_DIR = path.join(ROOT, 'Modules', 'Tools');

const DEV_FLAG = '## X-Dev-Build: dev';
const RELEASE_FLAG = '## X-Dev-Build: release';
const DEV_FILES = ['DevTools.lua', 'Report.lua'];
const DEV_LINE = /<Script\b[^>]*\/?>[\t ]*<!--\s*DEV-ONLY\s*-->/;

function fail(msg) { throw new Error(msg); }
function read(p) { return fs.readFileSync(p, 'utf8'); }
function count(haystack, needle) { return haystack.split(needle).length - 1; }

function stripText(tocSrc, xmlSrc) {
    if (count(tocSrc, DEV_FLAG) !== 1) {
        fail('TOC 里 "' + DEV_FLAG + '" 应恰好出现 1 次（可能已经剥离过）');
    }
    if (tocSrc.indexOf(RELEASE_FLAG) >= 0) fail('TOC 已经是 release 状态');
    const toc = tocSrc.replace(DEV_FLAG, RELEASE_FLAG);

    const nl = xmlSrc.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    const lines = xmlSrc.split(/\r?\n/);
    const kept = [];
    const dropped = [];
    for (const line of lines) {
        if (/<Script\b/.test(line) && DEV_LINE.test(line)) dropped.push(line.trim());
        else kept.push(line);
    }
    if (dropped.length !== DEV_FILES.length) {
        fail('Tools.xml 应摘掉 ' + DEV_FILES.length + ' 行 DEV-ONLY，实际 ' + dropped.length);
    }
    for (const f of DEV_FILES) {
        if (!dropped.some(l => l.indexOf('file="' + f + '"') >= 0)) {
            fail('DEV-ONLY 行里缺 ' + f);
        }
        if (kept.some(l => /<Script\b/.test(l) && l.indexOf('file="' + f + '"') >= 0)) {
            fail('剥离后 Tools.xml 仍引用 ' + f);
        }
    }
    return { toc: toc, xml: kept.join(nl), dropped: dropped };
}

// 仓库 / 本地部署必须保持 dev 状态；顺带确认 .pkgmeta 真的排除了两份 dev 文件。
function verifyDevState() {
    const toc = read(TOC);
    const xml = read(XML);
    const pkg = read(PKGMETA);
    if (count(toc, DEV_FLAG) !== 1) fail('TOC 缺 "' + DEV_FLAG + '"（本地不该是 release）');
    if (toc.indexOf(RELEASE_FLAG) >= 0) fail('TOC 同时带 dev / release 标记');
    const tagged = xml.split(/\r?\n/).filter(l => /<Script\b/.test(l) && DEV_LINE.test(l));
    if (tagged.length !== DEV_FILES.length) {
        fail('Tools.xml 应有 ' + DEV_FILES.length + ' 行 DEV-ONLY Script，实际 ' + tagged.length);
    }
    for (const f of DEV_FILES) {
        if (!fs.existsSync(path.join(TOOLS_DIR, f))) fail('dev 文件丢失：' + f);
        const entry = 'Modules/Tools/' + f;
        if (pkg.indexOf(entry) < 0) fail('.pkgmeta ignore 缺 ' + entry);
    }
    return true;
}

function selfTest() {
    const tocSrc = read(TOC);
    const xmlSrc = read(XML);
    const out = stripText(tocSrc, xmlSrc);
    if (out.toc.indexOf(RELEASE_FLAG) < 0 || out.toc.indexOf(DEV_FLAG) >= 0) {
        fail('自检：TOC 标记没换干净');
    }
    if (DEV_LINE.test(out.xml)) fail('自检：XML 仍带 DEV-ONLY Script 行');
    for (const f of DEV_FILES) {
        if (out.xml.indexOf('file="' + f + '"') >= 0) fail('自检：XML 仍引用 ' + f);
    }
    for (const keep of ['Cursor.lua', 'WhatsNew.lua', 'Tweaks.lua']) {
        if (out.xml.indexOf('file="' + keep + '"') < 0) fail('自检：误删了玩家向文件 ' + keep);
    }
    if (xmlSrc.indexOf('\r\n') >= 0 && out.xml.indexOf('\r\n') < 0) {
        fail('自检：XML 换行符被改坏');
    }
    let guarded = false;
    try { stripText(out.toc, out.xml); } catch (e) { guarded = true; }
    if (!guarded) fail('自检：重复剥离没有防呆');
    console.log('[strip-dev] SELF TEST OK（dev -> release，2 行摘除，玩家向文件保留，重复剥离被拦）');
}

function stripInPlace() {
    verifyDevState();
    const out = stripText(read(TOC), read(XML));
    fs.writeFileSync(TOC, out.toc);
    fs.writeFileSync(XML, out.xml);
    console.log('[strip-dev] MonetUI.toc: X-Dev-Build dev -> release');
    console.log('[strip-dev] Tools.xml: 摘除 ' + out.dropped.length + ' 行 ' + out.dropped.join(' | '));
    console.log('[strip-dev] .pkgmeta 会把 DevTools.lua / Report.lua 排除出 zip');
}

const mode = process.argv[2] || 'strip';
try {
    if (mode === '--check') { verifyDevState(); console.log('[strip-dev] CHECK OK（本地/仓库保持 dev）'); }
    else if (mode === '--self-test') selfTest();
    else if (mode === 'strip') stripInPlace();
    else fail('用法: node tools/strip-dev.js [--check|--self-test]');
} catch (e) {
    console.error('[strip-dev] FAIL: ' + e.message);
    process.exit(1);
}
