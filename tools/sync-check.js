#!/usr/bin/env node
/**
 * Is the installed copy the one you are editing?
 *
 * The trap this exists for (2026-10-26): the game folder was deployed at
 * 2026-10-25 16:11 and never again, so five commits made later that evening
 * ("Auras.lua / CastBar.lua" did not exist in the installed copy at all) were
 * simply not there when the client loaded.  Everything looked fine offline:
 * `git status` clean, `api-audit` clean, `wuxian check` clean -- because check
 * on an addon NAME looks at the installed copy, not at this repo.
 *
 * Run it after `deploy-retail.ps1` (must be "in sync") and before a play test
 * (a stale copy explains "my changes do not show up" without any error).
 *
 * Usage:
 *   node tools/sync-check.js                 # default delivery install (_forever_)
 *   node tools/sync-check.js --dest "D:\WoW\_forever_"
 *   node tools/sync-check.js --quiet         # exit code only
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const repo = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const quiet = args.includes('--quiet');
const destAt = args.indexOf('--dest');
const dest = destAt >= 0
    ? path.resolve(args[destAt + 1] || '')
    : 'C:\\Users\\EastHillGu\\Documents\\Blizzards\\WOWFOREVER\\World of Warcraft\\_forever_';

const DIRS = ['Assets', 'Libs', 'Utils', 'Config', 'Modules'];
// Init.lua is loaded from the repo root by the TOC (before Core.lua); keep it in
// the deploy/sync manifest or the installed copy silently misses the bootstrap.
const FILES = ['MonetUI.toc', 'Init.lua', 'Core.lua', 'LICENSE', 'THIRD-PARTY-NOTICES.txt'];
const installed = path.join(dest, 'Interface', 'AddOns', 'MonetUI');

const hash = (file) => crypto.createHash('md5').update(fs.readFileSync(file)).digest('hex');
const rel = (base, file) => path.relative(base, file).split(path.sep).join('/');

function walk(dir, out = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full, out);
        else out.push(full);
    }
    return out;
}

if (!fs.existsSync(installed)) {
    console.log(`NOT DEPLOYED: ${installed} does not exist.`);
    console.log('Run: powershell -File tools/deploy-retail.ps1');
    process.exit(2);
}

// The deployed toc differs by design: the deploy rewrites ## Interface.
const stripInterface = (text) => text.replace(/^## Interface:\s*\d+/m, '## Interface: <deployed>');
// 行尾不算内容差异：本仓混用 CRLF/LF，部署落盘的行尾和源文件不一定一致，
// 逐字节比会把"刚部署完"的文件报成 STALE（实机误报过 UnitFrames.xml）。
const stripEol = (text) => text.replace(/\r\n/g, '\n');
// 2026-11-03 又抓到一例同族误报：`LICENSE` 没有扩展名，落到上面那条“逐字节比”的路里，而 git 的
// 文本归一化让 worktree 里是 CRLF、仓库 blob 与已部署副本是 LF —— 内容完全一致却永久报 STALE
// （实测 1088 vs 1067 字节 = 21 个 CR；`git hash-object 已部署副本` 等于 HEAD，说明部署副本没变）。
// ⇒ 无扩展名的已知文本文件名也走 stripEol，别拿字节数当内容。
const BARE_TEXT_NAMES = /^(LICENSE|NOTICE|COPYING|README|CHANGELOG|AUTHORS|THANKS)$/i;
const isText = (name) => /\.(lua|xml|toc|md|txt|js)$/i.test(name) || BARE_TEXT_NAMES.test(path.basename(name));

const repoFiles = new Map();
for (const dir of DIRS) {
    const from = path.join(repo, dir);
    if (!fs.existsSync(from)) continue;
    for (const file of walk(from)) repoFiles.set(rel(repo, file), file);
}
for (const file of FILES) {
    const full = path.join(repo, file);
    if (fs.existsSync(full)) repoFiles.set(file, full);
}

const installedFiles = new Map();
for (const file of walk(installed)) installedFiles.set(rel(installed, file), file);

const missing = [];   // in repo, not installed (new file never deployed)
const stale = [];     // both sides, content differs (edited after the last deploy)
const extra = [];     // installed, not in repo (leftover from an older deploy)

for (const [name, file] of repoFiles) {
    const there = installedFiles.get(name);
    if (!there) { missing.push(name); continue; }
    let same;
    if (isText(name)) {
        const a = stripEol(fs.readFileSync(file, 'utf8'));
        const b = stripEol(fs.readFileSync(there, 'utf8'));
        same = /\.toc$/i.test(name) ? stripInterface(a) === stripInterface(b) : a === b;
    } else {
        const a = fs.statSync(file);
        const b = fs.statSync(there);
        same = a.size === b.size && hash(file) === hash(there);
    }
    if (!same) stale.push(name);
}
for (const name of installedFiles.keys()) if (!repoFiles.has(name)) extra.push(name);

const sync = missing.length === 0 && stale.length === 0 && extra.length === 0;

if (!quiet) {
    const show = (label, list, hint) => {
        if (!list.length) return;
        console.log(`\n${label} (${list.length}) ${hint}`);
        for (const name of list.sort()) console.log('  ' + name);
    };
    console.log(`repo      : ${repo}`);
    console.log(`installed : ${installed}`);
    show('MISSING in game copy', missing, '-- new files the client will not load');
    show('STALE in game copy', stale, '-- edited here, never deployed');
    show('EXTRA in game copy', extra, '-- leftovers from an older deploy (harmless, but they are not in this repo)');
    console.log(sync
        ? '\nin sync: the client loads exactly this repo.'
        // 脚本名是历史遗留：tools/deploy-retail.ps1 的默认目标就是上面这行 installed（_forever_，16001）。
        : '\nOUT OF SYNC: run  powershell -File tools/deploy-retail.ps1'
            + '   (that name is legacy -- it deploys to the _forever_ path above)'
            + '   then /reload in game.');
}

process.exit(sync ? 0 : 1);
