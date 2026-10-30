// Every name in a M:Panel `frames` list must be reachable from code, otherwise the list is decoration.
// The list exists so `/mui skins diagnose` probes Blizzard globals and reports which ones the skin
// actually reaches; a name listed but never looked up in Lua means diagnose claims coverage the skin
// does not have, which is worse than not listing it.
//
// Names built at runtime (`_G["StaticPopup" .. index .. "Button1"]`, `_G[name .. "CloseButton"]`)
// are legitimately unreachable by static scan, so they are declared in ALLOW_DYNAMIC with the reason.
//
// Run: node tools/check-frame-list.js
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const luaFiles = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (['.git', 'tools', 'docs', 'Assets', 'Libs'].includes(e.name)) continue;
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (/\.lua$/.test(e.name)) luaFiles.push(p);
  }
})(root);

const skinsFiles = luaFiles.filter(f => f.includes(path.join('Modules', 'Skins')));

// Reached only through string concatenation at runtime. Keep this list short and justified —
// a name added here is one static analysis can never check again.
const ALLOW_DYNAMIC = new Map(Object.entries({
  // System.lua builds the four static popups and their buttons as "StaticPopup"..index and
  // "StaticPopup"..index.."Button1" etc.
  StaticPopup1: 'System.lua 拼接 "StaticPopup"..index',
  StaticPopup2: 'System.lua 拼接 "StaticPopup"..index',
  StaticPopup3: 'System.lua 拼接 "StaticPopup"..index',
  StaticPopup4: 'System.lua 拼接 "StaticPopup"..index',
  StaticPopup1Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup1Button2: 'System.lua 拼接 "StaticPopup"..index.."Button2"',
  StaticPopup2Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup3Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup4Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  // System.lua / Trade.lua: M:SkinWindow falls back to _G[frame:GetName().."CloseButton"]
  LootFrameCloseButton: 'M:SkinWindow 的 _G[name.."CloseButton"] 回退路径',
  SettingsPanelCloseButton: 'M:SkinWindow 的 _G[name.."CloseButton"] 回退路径',
  TradeFrameCloseButton: 'M:SkinWindow 的 _G[name.."CloseButton"] 回退路径',
  // System.lua: SkinAddonList does frame.AddonListScrollFrame or frame.ScrollFrame
  AddonListScrollFrame: 'System.lua 的 frame.AddonListScrollFrame',
  LootFrameScrollFrame: 'System.lua 的 frame.LootFrameScrollFrame',
  // Forever.lua: LFGParentFrame members reached as frame.<name>, not _G.<name>
  LFGParentFrameCloseButton: 'Forever.lua 的 frame.CloseButton 成员访问',
  LFGBrowseFrameCategoryDropdown: 'Forever.lua 的成员访问',
  LFGBrowseFrameActivityDropdown: 'Forever.lua 的成员访问',
}));

const declared = new Map();   // name -> {file, line}
for (const f of skinsFiles) {
  const src = fs.readFileSync(f, 'utf8');
  const lines = src.split('\n');
  lines.forEach((line, i) => {
    if (!/frames\s*=\s*\{/.test(line)) return;
    // collect the block until the matching close
    let depth = 0, started = false;
    for (let j = i; j < lines.length; j++) {
      for (const ch of lines[j]) {
        if (ch === '{') { depth++; started = true; }
        else if (ch === '}') depth--;
      }
      for (const n of lines[j].matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) {
        if (!declared.has(n[1])) {
          declared.set(n[1], { file: path.relative(root, f), line: j + 1 });
        }
      }
      if (started && depth === 0) break;
    }
  });
}

console.log(`M:Panel frames 名单：${declared.size} 个全局名，取自 ${skinsFiles.length} 个皮肤文件\n`);

const orphan = [];
for (const [name, where] of declared) {
  if (ALLOW_DYNAMIC.has(name)) continue;
  const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Reachable if the name appears anywhere as a quoted string OUTSIDE its own frames block,
  // or as a _G member. A name only ever written inside frames = {...} is unreachable.
  let reachable = new RegExp(`_G\\.${esc}\\b`).test(
    luaFiles.map(f => fs.readFileSync(f, 'utf8')).join('\n'));

  if (!reachable) {
    for (const f of skinsFiles) {
      const src = fs.readFileSync(f, 'utf8').split('\n');
      let i = 0;
      while (i < src.length) {
        if (!/frames\s*=\s*\{/.test(src[i])) {
          if (new RegExp(`["']${esc}["']`).test(src[i])) { reachable = true; break; }
          i++;
          continue;
        }
        let depth = 0, started = false, j = i;
        const block = [];
        for (; j < src.length; j++) {
          for (const ch of src[j]) {
            if (ch === '{') { depth++; started = true; }
            else if (ch === '}') depth--;
          }
          block.push(src[j]);
          if (started && depth === 0) break;
        }
        for (let k = i; k <= j; k++) {
          if (!/frames\s*=\s*\{/.test(src[k]) && new RegExp(`["']${esc}["']`).test(src[k])) {
            reachable = true; break;
          }
        }
        if (reachable) break;
        i = j + 1;
      }
      if (reachable) break;
    }
  }
  if (!reachable) orphan.push(`${name}   (${where.file}:${where.line})`);
}

console.log(`其中 ${ALLOW_DYNAMIC.size} 个走运行期拼接，已在 ALLOW_DYNAMIC 登记理由。`);
if (orphan.length) {
  console.log('\n【只在 frames 名单里、代码从不取用】—— diagnose 会报告它们存在，皮肤其实没碰：');
  orphan.forEach(o => console.log('  ' + o));
  console.log('\n' + orphan.length + ' 个。要么接上皮肤，要么从名单里删掉。');
  process.exit(1);
} else {
  console.log('全部有实际取用路径 —— frames 名单与代码一致。');
}