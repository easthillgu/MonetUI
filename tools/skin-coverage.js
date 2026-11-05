// tools/skin-coverage.js
// 覆盖率审计（只读，不进发行包）：从 1.60 FrameXML 源枚举"顶层暴雪窗口"，
// 再和 MonetUI 皮肤层引用的名字对撞，报**哪些暴雪窗口我们没美化**。
//
// 为什么需要它：`frame-name-existence.js` 走的是反方向（我们的名单 → XML 声明层），
// 只能告诉我们"名单里的名字 XML 有没有"，答不了"暴雪有但我们没做的窗"。
// 这个脚本补那一面：以暴雪窗口为全集，看我们的覆盖缺口。
//
// 判据（启发式，给线索不当闸门）：
//   顶层窗口 = `<Frame/Button/...>` 且 name 是 PascalCase、不含 Template、不是成员路径（无点）、
//              parent 是 UIParent 类、且有 frameStrata 或 (hidden+enableMouse)。
//   再剔掉明显不是"面板"的：strata 是 TOOLTIP，或名字以 Tooltip/Button/Underlay/Overlay/
//              Display/Status/Alerts/Container/Manager/Cursor/Blur/Background/Backdrop/Tab 结尾。
//   "覆盖到" = 该窗口名出现在我们任一皮肤文件的字符串/常量里（M:Dress / M:Panel frames / Need）。
//
// ⚠ 和 frame-name-existence 同一口径：XML 声明层查得到 ≠ 客户端一定这样，运行期造的窗这里看不到；
//   这份缺口清单是"候选没做的窗"，要逐个实机确认（很多是 2 级号根本进不去的内容窗）。
//
// 用法：
//   node tools/skin-coverage.js --source <framexml-source/Interface/AddOns 路径>
//   node tools/skin-coverage.js --source ... --show-not-skinned   # 只列缺口
//   node tools/skin-coverage.js --source ... --show-skipped       # 连被启发式剔掉的也列

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const argVal = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const SRC = argVal('--source');
if (!SRC || !fs.existsSync(SRC)) {
  console.error('需要 --source <FrameXML 的 Interface/AddOns 目录>（本车道没有 framexml 源）。');
  process.exit(2);
}

const TAG = /<(Frame|Button|CheckButton|Slider|DropDownButton|ScrollFrame|EditBox)\b([^>]*)\/?>/g;
const attr = (s, n) => { const m = s.match(new RegExp('\\b' + n + '="([^"]*)"')); return m ? m[1] : null; };
const NON_WINDOW_SUFFIX = /(?:Tooltip|Button|Underlay|Overlay|Display|Status|Alerts|Container|Manager|Cursor|Blur|Background|Backdrop|Tab|Template)$/;

function walk(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith('.xml')) acc.push(p);
  }
  return acc;
}

// ---- 暴雪候选顶层窗口 ----
const windows = new Map(); // name -> { addon, strata }
for (const f of walk(SRC, [])) {
  const addon = path.relative(SRC, f).split(path.sep)[0];
  const txt = fs.readFileSync(f, 'utf8');
  let m;
  while ((m = TAG.exec(txt))) {
    const a = m[2];
    const name = attr(a, 'name');
    if (!name || name.includes('Template') || name.includes('.')) continue;
    if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) continue;
    const parent = attr(a, 'parent');
    if (!(parent === 'UIParent' || parent === 'UIParentLoadAddOnBlurFrame' || parent === 'PARENT')) continue;
    const strata = attr(a, 'frameStrata');
    const hidden = attr(a, 'hidden');
    const mouse = attr(a, 'enableMouse');
    if (!(strata || (hidden === 'true' && mouse === 'true'))) continue;
    if (strata === 'TOOLTIP') continue;
    if (NON_WINDOW_SUFFIX.test(name)) continue;
    if (!windows.has(name)) windows.set(name, { addon, strata: strata || '' });
  }
}

// ---- MonetUI 皮肤层引用的名字（字符串字面量 + 大写常量表成员）----
const skinsDir = path.join(ROOT, 'Modules', 'Skins');
const referenced = new Set();
for (const f of fs.readdirSync(skinsDir)) {
  if (!f.endsWith('.lua')) continue;
  const txt = fs.readFileSync(path.join(skinsDir, f), 'utf8');
  for (const s of txt.matchAll(/["']([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9_]*)*)["']/g)) referenced.add(s[1]);
  // 点路径的窗口头也算（QuestMapFrame.DetailsFrame 覆盖 QuestMapFrame）
  for (const s of txt.matchAll(/["']([A-Z][A-Za-z0-9]*)\./g)) referenced.add(s[1]);
}

// ---- 对撞 ----
// 策展排除：这些不是"窗口美化"该管的（别的模块已接管 / HUD 常驻件 / 开发或几乎不显示的框）。
// 命中就从"缺口"里挪到"已管/非窗"，让缺口清单只剩真正可做的候选。
const HANDLED_OTHER = new Set([
  // ActionBars 模块（park/收养，不是窗美化）
  'MultiBar5','MultiBar6','MultiBar7','MultiBarBottomLeft','MultiBarBottomRight','MultiBarLeft','MultiBarRight',
  'MultiCastActionBarFrame','PetActionBar','PossessActionBar','StanceBar','OverrideActionBar',
  // Minimap 模块
  'MinimapCluster',
  // UnitFrames / 团队 / 提示（不是窗）
  'PlayerFrame','PartyFrame','EncounterBar','RaidParentFrame','RaidWarningFrame','PrivateRaidBossEmoteFrameAnchor',
  'CompactRaidFrameContainer','CompactRaidFrameManager',
  // Bags 模块
  'ContainerFrameCombinedBags',
]);
const HUD_NOT_WINDOW = new Set([
  'PingFrame','PingListenerFrame','SuperTrackedFrame','QuestTimerFrame','StatusUIFrame','TimerTracker',
  'ZoneTextFrame','SubZoneTextFrame','LossOfControlFrame','DeadlyDebuffFrame','ExternalDefensivesFrame',
  'CoinPickupFrame','MotionSicknessFrame','RatingMenuFrame','UIWidgetCenterDisplayFrame',
  'GamepadPersistentInputLegend','GamepadRadial','GamepadReticle','GamepadActionBarEditFrame',
  'DurabilityFrame','AutoFollowStatus','ArrowCalloutFrameManager',
]);
const DEV_OR_RARE = new Set([
  'EventTrace','CustomizationDebugFrame','PreLoadFrame','MovePadFrame','TutorialPointerFrame',
  'NPETutorialPointerFrame','SplashFrame','NamePlatesTutorial','DeclensionFrame','QuickKeybindFrame',
  'BehavioralMessagingDetails','ExpansionLandingPage','ClassTrialThanksForPlayingDialog',
  'ExpansionTrialThanksForPlayingDialog','ExpansionTrialCheckPointDialog','PlayerChoiceTimeRemaining',
]);

const skinned = [], notSkinned = [], otherHandled = [];
for (const [name, info] of [...windows.entries()].sort()) {
  if (referenced.has(name)) skinned.push({ name, ...info });
  else if (HANDLED_OTHER.has(name) || HUD_NOT_WINDOW.has(name) || DEV_OR_RARE.has(name)) otherHandled.push({ name, ...info });
  else notSkinned.push({ name, ...info });
}

const pct = Math.round(skinned.length / windows.size * 100);
console.log(`暴雪顶层窗口候选 ${windows.size} 个 · Skins 已美化 ${skinned.length} (${pct}%) · 其它模块/HUD/开发件 ${otherHandled.length} · 真缺口 ${notSkinned.length}`);
console.log(`（启发式；真缺口里仍含"2 级号进不去的内容窗"，要逐个实机确认）\n`);

if (!args.includes('--show-skipped')) {
  console.log('== 真缺口：Skins 没美化、且不是别的模块该管的暴雪窗口（按插件目录分组）==');
  const byAddon = new Map();
  for (const w of notSkinned) {
    if (!byAddon.has(w.addon)) byAddon.set(w.addon, []);
    byAddon.get(w.addon).push(w.name);
  }
  for (const [addon, names] of [...byAddon.entries()].sort()) {
    console.log(`  [${addon}] ${names.join(', ')}`);
  }
} else {
  console.log('== 已美化到 ==');
  console.log('  ' + skinned.map(w => w.name).join(', '));
  console.log('\n== 其它模块/HUD/开发件（从缺口里挪走的）==');
  console.log('  ' + otherHandled.map(w => w.name).join(', '));
}
