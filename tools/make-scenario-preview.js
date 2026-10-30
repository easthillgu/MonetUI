/**
 * Scenario preview — MonetUI as it stands today, painted at 2560x1440.
 *
 * The page is 1:1 with the game: at 1440p MonetUI pins uiScale so 1 UI unit is
 * exactly one physical pixel (Utils/Media.lua scalePresets[1440] -> 1 px/unit),
 * so every number below is a direct copy of the code, not a "looks about right".
 *
 * Where each number comes from:
 *   Core.lua DEFAULTS.unitFrames       player/target/targettarget/pet anchors, 160-160-60-60, health 4
 *   UnitFrames.lua                     border 1, separator 1, power 1, TEXT_GAP 3, name 10 / level 10
 *                                      target aura 18x14, gap 22, 8 per row (ComputeAuraLayout)
 *                                      cast spark 4x2, 1px under the power bar
 *   Groups.lua                         party width 110, health 18, power 4, spacing 2, BORDER 1 -> 25 tall
 *   BuffFrame.lua                      28px buffs, gap 4, TOPLEFT 33,-33, timer 12px
 *   ActionBars.lua                     bars 28px / spacing 2 / 12 per bar, Bar1 BOTTOM (0,24),
 *                                      pet bar BOTTOMRIGHT of Bar3 TOPRIGHT (0,2)
 *   Nameplates.lua                     plate 120x12, name 12 + TEXT_GAP 3, cast 13 + gap 4, debuffs above
 *   QuestTracker.lua                   264 wide, PAD 8, HEADER 18, LINE 12, LINE_GAP 2, ENTRY_GAP 8
 *   Minimap.lua                        256x190 map, panel +4 (264x198), gap 33, round 6, zone text 12
 *   Buttons.lua                        badges 20x20 with the 4:3 plate (20x15) at the map corners
 *   InfoBar.lua                        strip 14 tall / 2px border, blocks 12px + 16 padding, gap 2
 *   XP.lua                             XP is the bottom 2px hairline + an 8px triangle at 65%
 *
 * Theme = LibMonetColor computed for mapID 1413 (The Barrens, h47 s.298 l.395):
 *   edge rgb(134,143,175) a .80, ambient*0.35 rgb(33,38,37), highlight rgb(166,169,160),
 *   neutral rgb(122,121,117).  Unit-frame borders are repainted by LibMonetColor-Anim while in
 *   combat (lightness +.08, saturation +.10, alpha x1.10) -> rgb(151,161,199) a .88.
 *
 * Scene, spell icons and the minimap render are stand-ins drawn by
 * tools/make-scenario-assets.js; everything else uses the addon's own textures.
 *
 * Usage: node tools/make-scenario-preview.js
 *        (then screenshot with headless Chrome, see docs/mockup/README-preview.md)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, 'docs', 'mockup', 'preview-scenario-2560x1440.html');

// ------------------------------------------------------------------ helpers

const rgba = (rgb, a) => `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;

const C = {
  edge: [134, 143, 175],
  edgeA: 0.8,
  combatEdge: [151, 161, 199],
  combatEdgeA: 0.88,
  ambient: [33, 38, 37],
  highlight: [166, 169, 160],
  neutral: [122, 121, 117],
  resource: [51, 128, 230],
  danger: [230, 51, 51],
  health: [51, 204, 51],
  // class colours (Blizzard's own)
  hunter: [171, 212, 115],
  warrior: [199, 156, 110],
  priest: [255, 255, 255],
  rogue: [255, 245, 105],
  // hostile NPC fill (UnitSelectionColor)
  hostile: [219, 51, 51],
  friendly: [79, 166, 89],
};

// gradient tail -> head, as Widget:BarGradient applies it (tail .6 -> head 1)
const barBg = (rgb) =>
  `linear-gradient(90deg, rgba(0,0,0,.40), rgba(0,0,0,0)), rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;

// The bar ground: Widget:BarWeave tiles monet_stripe_weave at 1 texel = 1 physical pixel
// (64px tile), tinted neutral at alpha 0.85.  The PNG is pre-tinted by make-scenario-assets,
// so opacity 0.85 here is the vertex alpha.
function weave() {
  return "url('scenario/monet_stripe_weave_bar.png')";
}

function healthBar(w, h, pct, colors) {
  const lost = colors.lost === 'black' ? 'rgba(0,0,0,.92)' : rgba(C.danger, colors.lostAlpha || 0.95);
  return `<div class="hb" style="width:${w}px;height:${h}px;background:${lost};">
    <div class="weave" style="background-image:${weave()};"></div>
    <div class="fill" style="width:${pct}%;background:${barBg(colors.fill)};background-size:${w}px 100%;"></div>
  </div>`;
}

function powerBar(w, h, pct, rgb, withWeave = true) {
  return `<div class="pb" style="width:${w}px;height:${h}px;">
    ${withWeave ? `<div class="weave" style="background-image:${weave()};"></div>` : ''}
    <div class="fill" style="width:${pct}%;background:${barBg(rgb)};background-size:${w}px 100%;"></div>
  </div>`;
}

// one slim unit frame: border 1 / health / 1px separator / power / border 1
function unitFrame(o) {
  const inner = o.w - 2;
  const hh = o.hh || 4;
  const ph = o.ph || 1;
  const hgt = 2 + hh + 1 + ph;
  const text = o.text || '';
  return `
  <div class="uf" style="left:${o.x}px;top:${o.y}px;width:${o.w}px;height:${hgt}px;">
    ${healthBar(inner, hh, o.hp, { fill: o.fill, lost: o.lost, lostAlpha: o.lostAlpha })}
    <div class="sep" style="top:${1 + hh}px;width:${inner}px;"></div>
    ${powerBar(inner, ph, o.power || 0, o.powerColor || C.resource)}
    ${o.aura ? o.aura : ''}
    ${o.spark ? o.spark : ''}
  </div>
  ${text}`;
}

// --------------------------------------------------------------- page parts

const bg = `background:url('scenario/barrens-bg.png') center/2560px 1440px no-repeat;`;

// --- info bar --------------------------------------------------------------
function infoBar() {
  const block = (t) => `<div class="ib-block">${t}</div>`;
  return `
  <div class="infobar">
    <div class="ib-left">
      ${block('12g 34s 56c')}${block('87%')}${block('荣誉点数 3')}
    </div>
    <div class="ib-right">
      ${block('12 / 34')}${block('野兽控制')}${block('43ms · 60 FPS · 21.4M')}
    </div>
    <div class="xp-fill" style="width:65%"></div>
    <div class="xp-mark" style="left:1664px;">▼</div>
  </div>`;
}

// --- unit frames -----------------------------------------------------------
// Core.lua: player CENTER/CENTER (0,-180) -> y = 720 + 180 = 900 at 1440p
//           target LEFT of player RIGHT (40,40) -> y = 900 - 40 = 860
//           targettarget LEFT of target RIGHT (6,0), pet RIGHT of player LEFT (-6,0)
function unitFrames() {
  const playerText = `
  <div class="uftext" style="left:1200px;top:881px;width:160px;">
    <span class="nm hunter">Monet</span><span class="hpx">549 / 610</span><span class="lvl">Lv17</span>
  </div>`;
  const targetText = `
  <div class="uftext" style="left:1400px;top:841px;width:160px;">
    <span class="nm edge">草原狮</span><span class="hpx" style="color:rgb(241,96,64)">11%</span><span class="lvl">Lv13</span>
  </div>`;
  const ttText = `
  <div class="uftext center" style="left:1566px;top:841px;width:60px;">
    <span class="nm edge">野猪</span>
  </div>`;

  // player spark: 4x2 triangle, 60% through a cast, travelling right -> left
  const spark = `<div class="spark" style="left:${Math.round((158) * 0.40)}px;top:9px;"></div>`;

  return [
    playerText,
    unitFrame({ x: 1200, y: 896, w: 160, hp: 90, fill: C.highlight, lost: 'black', power: 34, spark }),
    unitFrame({ x: 1400, y: 856, w: 160, hp: 11, fill: C.hostile, lost: 'danger', power: 0 }),
    unitFrame({ x: 1566, y: 856, w: 60, hp: 84, fill: C.friendly, lost: 'danger', power: 0 }),
    unitFrame({ x: 1134, y: 896, w: 60, hp: 84, fill: C.highlight, lost: 'black', power: 0 }),
    targetText,
    ttText,
    // Hunter's Mark: native AuraContainer, 18x14, bottom-left 22 above the target frame
    `<div class="taura" style="left:1400px;top:820px;"><img src="scenario/icon_hunter_mark.png" alt=""></div>`,
  ].join('\n');
}

// --- party -----------------------------------------------------------------
function party() {
  const rows = [
    { name: 'Monet', pct: 90, power: 34, cls: C.hunter, role: 'dps', leader: false },
    { name: 'Kargath', pct: 72, power: 60, cls: C.warrior, role: 'tank', leader: true },
    { name: 'Waterlily', pct: 100, power: 78, cls: C.priest, role: 'heal', leader: false },
    { name: 'Shade', pct: 64, power: 82, cls: C.rogue, role: 'dps', leader: false },
  ];
  const top = 614;   // anchor CENTER at UIParent (0, +40) -> 680; anchor is 5*25+4*2 = 133 tall,
                     // buttons stack from its TOP, so the four visible rows start at 613.5
  const out = rows.map((r, i) => {
    const y = top + i * 27;
    return `
    <div class="pframe" style="left:895px;top:${y}px;">
      ${healthBar(108, 18, r.pct, { fill: C.edge, lost: 'danger', lostAlpha: 0.85 })}
      <div class="psep"></div>
      ${powerBar(108, 4, r.power, r.cls, false)}
      <div class="pname">${r.name}</div>
      <img class="prole" src="scenario/monet_role_${r.role}${r.leader ? '_hl' : ''}.png" alt="">
    </div>`;
  }).join('\n');
  return out;
}

// --- buffs -----------------------------------------------------------------
function buffs() {
  const list = [
    { icon: 'hawk', timer: '30m' },
    { icon: 'fortitude', timer: '5m' },
  ];
  return list.map((b, i) => `
    <div class="buff" style="left:${33 + i * 32}px;top:33px;">
      <img src="scenario/icon_${b.icon}.png" alt="">
      <span class="t">${b.timer}</span>
    </div>`).join('\n');
}

// --- quest tracker ---------------------------------------------------------
function questTracker() {
  return `
  <div class="quest">
    <div class="qhead">任务追踪</div>
    <div class="qtitle" style="top:18px;">猎杀草原狮</div>
    <div class="qobj" style="top:30px;">击杀草原狮</div>
    <div class="qtitle" style="top:52px;">野猪人的威胁</div>
    <div class="qobj" style="top:64px;">杀死野猪人 (3/8)</div>
  </div>`;
}

// --- minimap ---------------------------------------------------------------
function minimap() {
  return `
  <div class="mm-panel"></div>
  <div class="mm"><img src="scenario/minimap.png" alt=""></div>
  <div class="mm-zone">贫瘠之地</div>
  <div class="mm-btn" style="left:2271px;top:1382px;">
    <img class="mm-badge" src="scenario/monet_map_tracking_edge.png" alt="">
  </div>
  <div class="mm-btn" style="left:2499px;top:1215px;">
    <img class="mm-badge" src="scenario/monet_map_compartment_edge.png" alt="">
  </div>`;
}

// --- action bars -----------------------------------------------------------
function button(o) {
  const cd = o.cd
    ? `<div class="cd" style="background:conic-gradient(rgba(4,6,10,.66) ${o.cdDeg}deg, rgba(4,6,10,0) 0);">
         <span class="cdt ${o.cdSec < 10 ? 'tight' : ''}">${o.cd}</span></div>`
    : '';
  const count = o.count ? `<span class="cnt">${o.count}</span>` : '';
  const key = o.key ? `<span class="hk">${o.key}</span>` : '';
  const icon = o.icon
    ? `<img class="ic" src="scenario/icon_${o.icon}.png" alt="">`
    : '';
  return `<div class="ab">
    <div class="well"></div>
    <div class="weave"></div>
    ${icon}
    <div class="sheen"></div>
    ${cd}${count}${key}
  </div>`;
}

function actionBars() {
  const LEFT = 1101;
  const tops = [1388, 1358, 1328];
  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '='];

  const row1 = ['hunter_mark', 'arcane_shot', 'serpent_sting', 'concussive', 'immolation',
    'mend_pet', 'revive_pet', 'eagle_eye', 'raptor', 'wing_clip', 'call_pet', 'dismiss_pet'];
  const row2 = ['hearth', 'skin', 'leather', 'cook', 'bandage', 'fish', 'bread', 'water',
    null, null, null, null];
  const row3 = [null, null, null, null, null, null, null, null, null, null, null, null];

  const rows = [row1, row2, row3];
  let out = '';
  rows.forEach((row, r) => {
    row.forEach((icon, i) => {
      const o = {
        icon,
        key: r === 0 ? keys[i] : null,
        count: icon === 'bandage' ? '8' : icon === 'bread' ? '20' : icon === 'water' ? '12' : null,
        cd: icon === 'immolation' ? '18' : null,
        cdDeg: icon === 'immolation' ? 216 : null,
        cdSec: icon === 'immolation' ? 18 : null,
      };
      const x = LEFT + i * 30;
      out += button(o).replace('<div class="ab">',
        `<div class="ab" style="left:${x}px;top:${tops[r]}px;">`);
    });
  });
  return out;
}

function petBar() {
  const icons = ['pet_attack', 'pet_follow', 'pet_stay', 'pet_passive', 'pet_defensive',
    'pet_assist', 'pet_growl', 'pet_bite', 'pet_charge', null];
  const LEFT = 1143;
  const TOP = 1298;
  return icons.map((icon, i) => {
    const x = LEFT + i * 32;
    const img = icon ? `<img class="ic" src="scenario/icon_${icon}.png" alt="">` : '';
    return `<div class="pbtn" style="left:${x}px;top:${TOP}px;">${img}</div>`;
  }).join('\n');
}

// --- nameplate / world -----------------------------------------------------
function nameplate() {
  return `
  <div class="np-debuff" style="left:560px;top:827px;"><img src="scenario/icon_hunter_mark.png" alt=""></div>
  <div class="np-text" style="left:560px;top:845px;">
    <span class="nm white">草原狮</span><span class="lvl">Lv13</span>
  </div>
  <div class="np" style="left:560px;top:860px;">
    <div class="fill" style="width:11%;background:${barBg(C.hostile)};background-size:118px 100%;"></div>
    <span class="np-pct">11%</span>
  </div>
  <div class="dmg" style="left:700px;top:846px;">35</div>`;
}

// --- chat ------------------------------------------------------------------
function chat() {
  return `
  <div class="chat">
    <div><span class="ch1">[1. 综合]</span> <span class="who">Monet</span>：这头狮子血不多了，收掉它</div>
    <div><span class="ch2">[小队]</span> <span class="who">Kargath</span>：稳一点，我拉住了</div>
    <div><span class="ch2">[小队]</span> <span class="who">Waterlily</span>：盾给你上好了</div>
    <div><span class="ch1">[1. 综合]</span> 你获得了 35 点经验。</div>
    <div><span class="chs">[系统]</span> MonetUI 已加载。输入 /mui 打开设置。</div>
  </div>`;
}

// ------------------------------------------------------------------- page

const css = `
@font-face {
  font-family: 'PingFangPixel';
  src: url('../../Assets/Fonts/Pingfangpixel.ttf') format('truetype');
  font-display: block;
}
@font-face {
  font-family: 'SuperEffective';
  src: url('../../Assets/Fonts/super-effective.ttf') format('truetype');
  font-display: block;
}
:root {
  --edge: 134,143,175;
  --edge-a: .80;
  --combat: 151,161,199;
  --ambient: 33,38,37;
  --hl: 166,169,160;
  --neutral: 122,121,117;
  --danger: 230,51,51;
}
* { box-sizing: border-box; }
html, body {
  margin: 0; padding: 0; width: 2560px; height: 1440px; overflow: hidden;
  background: #1a0f08;
  font-family: 'PingFangPixel', 'Microsoft YaHei UI', sans-serif;
  -webkit-font-smoothing: none;
  text-rendering: geometricPrecision;
  color: #e8e6e1;
}
.stage { position: relative; width: 2560px; height: 1440px; overflow: hidden; transform: translateZ(0); }
.scene { position: absolute; inset: 0; ${bg} }

/* ------------------------------------------------------------- info bar -- */
.infobar {
  position: absolute; left: 0; top: 0; width: 2560px; height: 14px;
  background: rgba(var(--ambient), .50);
  z-index: 40;
}
.infobar::before {
  content: ''; position: absolute; inset: 0; border: 2px solid rgba(var(--danger), .78);
  pointer-events: none; z-index: 1;
}
.ib-left, .ib-right { position: absolute; top: 0; height: 14px; display: flex; align-items: center; z-index: 3; }
.ib-left { left: 0; }
.ib-right { right: 0; }
.ib-block {
  display: flex; align-items: center; justify-content: center;
  height: 14px; padding: 0 8px 3px; min-width: 56px;
  text-align: center; font-size: 12px; line-height: 12px; color: rgb(var(--hl));
  text-shadow: 0 1px 0 rgba(0,0,0,.75);
  margin-right: 2px; position: relative;
}
/* 1px x 8px divider in the 2px gap (InfoBar:Relayout).  Only between neighbours,
   so the first block on each side never shows one. */
.ib-block + .ib-block::before {
  content: ''; position: absolute; left: -1px; top: 3px;
  width: 1px; height: 8px; background: rgba(var(--edge), .55);
}
.xp-fill, .xp-rested {
  position: absolute; left: 0; bottom: 0; height: 2px; z-index: 2;
}
.xp-rested { background: rgba(51,128,230,.35); }
.xp-fill { background: rgb(51,128,230); }
.xp-mark {
  position: absolute; bottom: 0; font-size: 8px; line-height: 8px; color: rgb(51,128,230);
  transform: translateX(-4px); z-index: 4; text-shadow: 0 0 4px rgba(20,60,120,.9);
}

/* ---------------------------------------------------------- unit frames -- */
.uf {
  position: absolute; border: 1px solid rgba(var(--combat), var(--combat-a));
  background: rgba(var(--ambient), .90);
  z-index: 20;
}
.uf .hb, .uf .pb { position: absolute; left: 1px; overflow: hidden; }
.uf .hb { top: 1px; }
.uf .pb { bottom: 1px; }
.hb .fill, .pb .fill { position: absolute; left: 0; top: 0; bottom: 0; background-repeat: no-repeat; }
.hb .weave, .pb .weave {
  position: absolute; inset: 0;
  background-repeat: repeat;
  background-size: 64px 64px;
  background-position: 0 -1px;   /* BarWeave starts one texel into the tile */
  opacity: .85;                  /* BarWeave vertex alpha */
}
.uf .sep {
  position: absolute; left: 1px; height: 1px; background: rgba(var(--edge), .55);
}
.uftext {
  position: absolute; height: 12px; display: flex; align-items: flex-end;
  font-size: 10px; line-height: 12px; white-space: nowrap; z-index: 21;
}
.uftext .nm { color: rgb(var(--edge)); text-shadow: 1px 1px 0 rgba(0,0,0,.9); }
.uftext .nm.hunter { color: rgb(171,212,115); }
.uftext .nm.edge { color: rgb(var(--edge)); }
.uftext .hpx { margin-left: auto; color: rgb(136,223,103); text-shadow: 1px 1px 0 rgba(0,0,0,.9); }
.uftext .lvl { margin-left: 2px; color: rgb(var(--neutral)); text-shadow: 1px 1px 0 rgba(0,0,0,.9); }
.uftext.center { justify-content: center; }
.uftext.center .nm { text-align: center; }

.spark {
  position: absolute; width: 0; height: 0;
  border-left: 2px solid transparent; border-right: 2px solid transparent;
  border-bottom: 2px solid #ff2b2b;
  filter: drop-shadow(0 0 2px rgba(255,40,40,.9));
  z-index: 22;
}
.taura {
  position: absolute; width: 18px; height: 14px;
  box-shadow: 0 0 0 1px rgba(var(--edge), .8);   /* border sits OUTSIDE the 18x14 button */
  background: rgba(0,0,0,.5); z-index: 22;
}
.taura img { position: absolute; inset: 0; width: 18px; height: 14px; object-fit: cover; }

/* ---------------------------------------------------------------- party -- */
.pframe {
  position: absolute; width: 110px; height: 25px;
  border: 1px solid rgba(var(--combat), var(--combat-a));
  background: rgba(var(--ambient), .90);
  z-index: 20;
}
.pframe .hb { position: absolute; left: 1px; top: 1px; overflow: hidden; }
.pframe .pb { position: absolute; left: 1px; bottom: 1px; overflow: hidden; }
.pframe .psep { position: absolute; left: 1px; top: 19px; width: 108px; height: 1px; background: rgba(var(--edge), .55); }
.pname {
  position: absolute; left: 4px; right: 12px; top: 5px; height: 13px;
  font-size: 10px; line-height: 13px; color: #fff; white-space: nowrap; overflow: hidden;
  text-shadow: 1px 1px 0 rgba(0,0,0,.95);
}
.prole {
  position: absolute; right: -1px; top: -1px; width: 9px; height: 9px;
}

/* ---------------------------------------------------------------- buffs -- */
.buff {
  position: absolute; width: 28px; height: 28px;
  border: 1px solid rgba(var(--edge), var(--edge-a));
  background: rgba(var(--ambient), .60);
  z-index: 20;
}
.buff img { position: absolute; inset: 0; width: 26px; height: 26px; object-fit: cover; }
.buff .t {
  position: absolute; left: 0; right: 0; top: -1px; text-align: center;
  font-size: 12px; line-height: 12px; color: #fff299;
  text-shadow: 1px 1px 0 rgba(0,0,0,.9);
}

/* --------------------------------------------------------- quest tracker -- */
.quest {
  position: absolute; left: 2263px; top: 33px; width: 264px; height: 86px;
  background: rgba(var(--ambient), .92);
  border: 2px solid rgba(var(--edge), var(--edge-a));
  border-radius: 6px;
  z-index: 30;
}
.qhead { position: absolute; left: 8px; top: 3px; font-size: 12px; line-height: 12px; color: rgb(var(--edge)); }
.qtitle { position: absolute; left: 8px; font-size: 12px; line-height: 12px; color: rgb(217,191,89); }
.qobj { position: absolute; left: 8px; font-size: 12px; line-height: 12px; color: rgb(var(--neutral)); }

/* -------------------------------------------------------------- minimap -- */
.mm-panel {
  position: absolute; left: 2263px; top: 1209px; width: 264px; height: 198px;
  background: rgba(var(--ambient), .35);
  border: 2px solid rgba(var(--edge), var(--edge-a));
  border-radius: 6px; z-index: 30;
}
.mm {
  position: absolute; left: 2267px; top: 1213px; width: 256px; height: 190px;
  overflow: hidden; border-radius: 4px; z-index: 31;
}
.mm img { width: 256px; height: 190px; display: block; }
.mm-zone {
  position: absolute; left: 2267px; top: 1219px; width: 256px;
  text-align: center; font-size: 12px; line-height: 12px; color: rgb(var(--edge));
  text-shadow: 1px 1px 2px #000; z-index: 33;
}
.mm-btn { position: absolute; width: 20px; height: 15px; z-index: 33; }
.mm-badge {
  position: absolute; left: 0; top: -2.5px; width: 20px; height: 20px;
}

/* ------------------------------------------------------------ actionbars -- */
.ab {
  position: absolute; width: 28px; height: 28px;
  border: 1px solid rgba(var(--edge), .9);
  border-radius: 1px;
  background: rgba(var(--neutral), .45);
  overflow: hidden; z-index: 30;
}
.ab .well { position: absolute; inset: 0; }
.ab .weave {
  position: absolute; inset: 0; opacity: .75;
  background: url('scenario/monet_stripe_weave.png') 0 0 / 64px 64px repeat;
}
.ab .ic { position: absolute; inset: 0; width: 26px; height: 26px; object-fit: cover; overflow: hidden; }
.ab .sheen {
  position: absolute; inset: 0; opacity: .16; mix-blend-mode: plus-lighter;
  background: url('scenario/monet_barfill.png') center/100% 100% no-repeat;
}
.ab .hk {
  position: absolute; left: 2px; top: 0; font-size: 12px; line-height: 12px;
  color: #fff; text-shadow: 1px 1px 0 rgba(0,0,0,.9);
}
.ab .cnt {
  position: absolute; right: 2px; bottom: 0; font-size: 12px; line-height: 12px;
  color: #fff; text-shadow: 1px 1px 0 rgba(0,0,0,.9);
}
.ab .cd { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
.ab .cdt {
  font-family: 'SuperEffective', 'PingFangPixel', sans-serif; font-size: 12px; color: #fff;
  text-shadow: 1px 1px 0 rgba(0,0,0,.9);
}
.ab .cdt.tight { color: #ff5555; }

.pbtn {
  position: absolute; width: 28px; height: 28px;
  border: 1px solid rgba(196,196,196,.40);
  background: rgba(14,14,17,.55);
  overflow: hidden; z-index: 30;
}
.pbtn .ic { width: 28px; height: 28px; display: block; }

/* ------------------------------------------------------------ nameplate -- */
.np {
  position: absolute; width: 120px; height: 12px;
  border: 1px solid rgb(242,179,64);
  background: rgba(0,0,0,.92);
  overflow: hidden; z-index: 24;
}
.np .fill { position: absolute; left: 0; top: 0; bottom: 0; }
.np .weave { position: absolute; inset: 0; }
.np-pct {
  position: absolute; right: 3px; top: 0; font-size: 12px; line-height: 10px;
  color: #fff; text-shadow: 1px 1px 0 #000;
}
.np-text {
  position: absolute; width: 120px; height: 12px; display: flex; align-items: flex-end;
  font-size: 12px; line-height: 12px; z-index: 24;
}
.np-text .nm.white { color: #fff; text-shadow: 1px 1px 0 #000; }
.np-text .lvl { margin-left: auto; color: rgb(var(--neutral)); text-shadow: 1px 1px 0 #000; }
.np-debuff {
  position: absolute; width: 18px; height: 14px;
  box-shadow: 0 0 0 1px rgba(var(--edge), .9);
  background: rgba(0,0,0,.5); z-index: 24;
}
.np-debuff img { position: absolute; inset: 0; width: 18px; height: 14px; object-fit: cover; }
.dmg {
  position: absolute; font-size: 28px; line-height: 28px; color: #fff1d6;
  text-shadow: 2px 2px 0 rgba(12,4,20,.95), 0 0 10px rgba(255,240,200,.35);
  z-index: 25;
}

/* ------------------------------------------------------------------ chat -- */
.chat {
  position: absolute; left: 20px; top: 1236px; width: 430px; height: 176px;
  background: rgba(var(--ambient), .35);
  border: 1px solid rgba(var(--edge), var(--edge-a));
  padding: 6px 8px; font-size: 12px; line-height: 20px;
  color: #cfcabf; z-index: 25;
  display: flex; flex-direction: column; justify-content: flex-end;
}
.chat div { white-space: nowrap; }
.chat .ch1 { color: #ffd47a; }
.chat .ch2 { color: #7ad0ff; }
.chat .chs { color: #9fd08c; }
.chat .who { color: #ffe9a8; }
`;

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>MonetUI 场景预览 2560x1440</title>
<style>${css}</style>
</head>
<body>
<div class="stage">
  <div class="scene"></div>
  ${infoBar()}
  ${unitFrames()}
  ${party()}
  ${buffs()}
  ${questTracker()}
  ${minimap()}
  ${actionBars()}
  ${petBar()}
  ${nameplate()}
  ${chat()}
</div>
</body>
</html>
`;

fs.writeFileSync(OUT, html, 'utf8');
console.log('wrote', OUT, '(' + html.length + ' bytes)');




