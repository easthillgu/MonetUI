/**
 * Scenario preview assets (docs/mockup/scenario/*.png)
 *
 * The preview needs art the addon itself does not ship: a Barrens scene, the
 * spell icons the client draws from its own CASC files, and a minimap render.
 * None of that is available offline, so this script draws stand-ins:
 *
 *   barrens-bg.png   2560x1440  painterly Barrens (mesas / dry grass / acacia),
 *                              plus a lion and a boar silhouette so the nameplate
 *                              and the damage number have something to sit on
 *   minimap.png      256x190    abstract Barrens map (roads, ridges, quest dots)
 *   icon_*.png       64x64      one flat-shaded glyph per action-bar slot
 *
 * Everything is deterministic (seeded RNG), so re-running produces the same art.
 *
 * Usage: node tools/make-scenario-assets.js
 */

const fs = require('fs');
const path = require('path');
const { createCanvas } = require('@napi-rs/canvas');

const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, 'docs', 'mockup', 'scenario');
fs.mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------- utilities

function rng(seed) {
  let s = seed >>> 0;
  return function () {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function rgb(r, g, b, a = 1) {
  return `rgba(${Math.round(r)},${Math.round(g)},${Math.round(b)},${a})`;
}

function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const type = b.readUInt8(2);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const topLeft = (b.readUInt8(17) & 0x20) !== 0;
  let o = 18;
  const px = new Uint8Array(w * h * 4);
  if (type === 2) {
    for (let i = 0; i < w * h; i++) {
      const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
      const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
      const idx = (row * w + (i % w)) * 4;
      px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
    }
  } else if (type === 10) {
    let pos = 0, row = topLeft ? 0 : h - 1, col = 0;
    while (pos < w * h) {
      const header = b[o++];
      const count = (header & 0x7f) + 1;
      if (header & 0x80) {
        const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
        for (let i = 0; i < count; i++) {
          const idx = (row * w + col) * 4;
          px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
          if (++col >= w) { col = 0; topLeft ? row++ : row--; }
        }
      } else {
        for (let i = 0; i < count; i++) {
          const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
          const idx = (row * w + col) * 4;
          px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
          if (++col >= w) { col = 0; topLeft ? row++ : row--; }
        }
      }
      pos += count;
    }
  } else {
    throw new Error('unsupported TGA type ' + type + ' in ' + file);
  }
  return { w, h, px };
}

function tgaToPng(name) {
  const dec = decodeTGA(path.join(ROOT, 'Assets', 'Textures', name + '.tga'));
  const c = createCanvas(dec.w, dec.h);
  const cx = c.getContext('2d');
  const id = cx.createImageData(dec.w, dec.h);
  id.data.set(dec.px);
  cx.putImageData(id, 0, 0);
  fs.writeFileSync(path.join(OUT, name + '.png'), c.toBuffer('image/png'));
  return { w: dec.w, h: dec.h };
}

/**
 * The game tints these stencils with SetVertexColor (texture x colour, both
 * multiplied), so a preview has to bake the same product: an <img> cannot be
 * tinted, and CSS masks proved unreliable in headless Chrome.
 */
function tintedTexture(name, rgb, suffix) {
  const dec = decodeTGA(path.join(ROOT, 'Assets', 'Textures', name + '.tga'));
  const c = createCanvas(dec.w, dec.h);
  const cx = c.getContext('2d');
  const id = cx.createImageData(dec.w, dec.h);
  for (let i = 0; i < dec.w * dec.h; i++) {
    id.data[i * 4 + 0] = Math.round(dec.px[i * 4 + 0] * rgb[0] / 255);
    id.data[i * 4 + 1] = Math.round(dec.px[i * 4 + 1] * rgb[1] / 255);
    id.data[i * 4 + 2] = Math.round(dec.px[i * 4 + 2] * rgb[2] / 255);
    id.data[i * 4 + 3] = dec.px[i * 4 + 3];
  }
  cx.putImageData(id, 0, 0);
  fs.writeFileSync(path.join(OUT, name + '_' + suffix + '.png'), c.toBuffer('image/png'));
}

// ------------------------------------------------------------------ texture

const TEXTURES = [
  'monet_canvas_weave', 'monet_barfill', 'monet_diagonal_weave',
  'monet_map_tracking', 'monet_map_compartment', 'monet_map_difficulty',
  'monet_role_tank', 'monet_role_heal', 'monet_role_dps',
];
for (const t of TEXTURES) tgaToPng(t);

// baked vertex colours the modules apply at runtime
const EDGE_RGB = [134, 143, 175];
const HL_RGB = [166, 169, 160];
const NEUTRAL_RGB = [122, 121, 117];
tintedTexture('monet_role_tank', HL_RGB, 'hl');       // leader gets the highlight slot
tintedTexture('monet_map_tracking', EDGE_RGB, 'edge');
tintedTexture('monet_map_compartment', EDGE_RGB, 'edge');
// BarWeave tints the stripe with the neutral slot at alpha 0.8; bake both here so the
// preview can use the real texture instead of re-inventing the hatch in CSS.
tintedTexture('monet_stripe_weave', NEUTRAL_RGB, 'bar');

// ------------------------------------------------------------------ barrens

function drawSky(ctx, W, H) {
  const sky = ctx.createLinearGradient(0, 0, 0, 820);
  sky.addColorStop(0.00, '#8fb6bd');
  sky.addColorStop(0.30, '#a8c9c6');
  sky.addColorStop(0.62, '#c9d7c4');
  sky.addColorStop(0.82, '#e3d5b4');
  sky.addColorStop(1.00, '#edcf9f');
  ctx.fillStyle = sky;
  ctx.fillRect(0, 0, W, 860);

  // low sun, upper right, the light the whole scene leans on
  const sun = ctx.createRadialGradient(1830, 300, 20, 1830, 300, 760);
  sun.addColorStop(0.00, 'rgba(255,246,214,.62)');
  sun.addColorStop(0.22, 'rgba(255,236,190,.28)');
  sun.addColorStop(0.55, 'rgba(255,225,170,.10)');
  sun.addColorStop(1.00, 'rgba(255,220,160,0)');
  ctx.fillStyle = sun;
  ctx.fillRect(0, 0, W, 900);
}

function mesa(ctx, x, baseY, w, h, color, alpha) {
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.moveTo(x, baseY);
  ctx.lineTo(x + w * 0.06, baseY - h * 0.42);
  ctx.quadraticCurveTo(x + w * 0.10, baseY - h * 0.62, x + w * 0.20, baseY - h * 0.66);
  ctx.lineTo(x + w * 0.30, baseY - h * 0.96);
  ctx.quadraticCurveTo(x + w * 0.34, baseY - h * 1.04, x + w * 0.44, baseY - h * 1.02);
  ctx.lineTo(x + w * 0.66, baseY - h * 1.02);
  ctx.quadraticCurveTo(x + w * 0.70, baseY - h * 1.04, x + w * 0.73, baseY - h * 0.94);
  ctx.lineTo(x + w * 0.84, baseY - h * 0.60);
  ctx.quadraticCurveTo(x + w * 0.90, baseY - h * 0.48, x + w * 0.94, baseY - h * 0.40);
  ctx.lineTo(x + w, baseY);
  ctx.closePath();
  ctx.fill();

  // lit rim on the sun side
  ctx.globalAlpha = alpha * 0.55;
  ctx.fillStyle = 'rgba(255,214,166,.55)';
  ctx.beginPath();
  ctx.moveTo(x + w * 0.70, baseY - h * 0.98);
  ctx.lineTo(x + w * 0.73, baseY - h * 0.94);
  ctx.lineTo(x + w * 0.84, baseY - h * 0.60);
  ctx.lineTo(x + w * 0.90, baseY - h * 0.48);
  ctx.lineTo(x + w * 0.80, baseY - h * 0.62);
  ctx.lineTo(x + w * 0.74, baseY - h * 0.94);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

function drawMesas(ctx) {
  // far ridge: hazy rust, almost part of the sky
  mesa(ctx, -40, 800, 420, 210, '#c08769', 0.55);
  mesa(ctx, 330, 800, 520, 150, '#bd8466', 0.5);
  mesa(ctx, 760, 800, 380, 230, '#c48b6b', 0.55);
  mesa(ctx, 1100, 800, 620, 130, '#c08a6c', 0.45);
  mesa(ctx, 1660, 800, 460, 200, '#c98f6e', 0.6);
  mesa(ctx, 2080, 800, 560, 250, '#c08466', 0.55);

  // middle ridge
  mesa(ctx, -80, 866, 520, 150, '#a96246', 0.85);
  mesa(ctx, 520, 866, 430, 105, '#a45f43', 0.8);
  mesa(ctx, 980, 866, 360, 150, '#ad6647', 0.85);
  mesa(ctx, 1420, 866, 600, 120, '#a05a3f', 0.8);
  mesa(ctx, 1980, 866, 500, 180, '#aa6446', 0.9);
  mesa(ctx, 2380, 866, 300, 240, '#a05c40', 0.85);

  // near outcrops framing the scene
  mesa(ctx, -120, 990, 470, 300, '#7f4229', 0.95);
  mesa(ctx, 2260, 1000, 460, 330, '#7c3f27', 0.95);
}

function drawHaze(ctx, W) {
  const haze = ctx.createLinearGradient(0, 620, 0, 880);
  haze.addColorStop(0.0, 'rgba(238,214,178,0)');
  haze.addColorStop(0.45, 'rgba(238,214,178,.42)');
  haze.addColorStop(0.7, 'rgba(230,198,158,.22)');
  haze.addColorStop(1.0, 'rgba(230,198,158,0)');
  ctx.fillStyle = haze;
  ctx.fillRect(0, 620, W, 260);
}

function drawGround(ctx, W, H) {
  const g = ctx.createLinearGradient(0, 800, 0, H);
  g.addColorStop(0.00, '#9b4f2c');
  g.addColorStop(0.18, '#8d4526');
  g.addColorStop(0.55, '#743a20');
  g.addColorStop(1.00, '#532515');
  ctx.fillStyle = g;
  ctx.fillRect(0, 790, W, H - 790);

  const rand = rng(20261021);

  // broad patches: sunlit sand, darker scrub
  for (let i = 0; i < 110; i++) {
    const x = rand() * W;
    const y = 820 + rand() * (H - 820);
    const w = 180 + rand() * 520;
    const h = 20 + rand() * 70;
    const light = rand() > 0.45;
    ctx.globalAlpha = 0.05 + rand() * 0.10;
    ctx.fillStyle = light ? '#d18b52' : '#4f2414';
    ctx.beginPath();
    ctx.ellipse(x, y, w, h, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;

  // the sun sits to the right: a soft warm wash across that half of the plain
  const wash = ctx.createLinearGradient(1500, 900, 2560, 1200);
  wash.addColorStop(0, 'rgba(232,160,96,0)');
  wash.addColorStop(1, 'rgba(232,160,96,.20)');
  ctx.fillStyle = wash;
  ctx.fillRect(1500, 820, 1060, 620);

  // grass: short strokes, denser and taller toward the camera
  for (let i = 0; i < 8200; i++) {
    const y = 840 + Math.pow(rand(), 0.72) * (H - 830);
    const x = rand() * W;
    const depth = (y - 840) / (H - 840);          // 0 far, 1 near
    const len = 4 + depth * 22 * rand();
    const lean = (rand() - 0.5) * 10;
    const v = rand();
    ctx.strokeStyle = v > 0.72
      ? `rgba(168,119,58,${0.20 + depth * 0.35})`
      : v > 0.36
        ? `rgba(104,78,36,${0.22 + depth * 0.35})`
        : `rgba(70,48,26,${0.18 + depth * 0.30})`;
    ctx.lineWidth = 0.7 + depth * 1.5;
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.quadraticCurveTo(x + lean * 0.4, y - len * 0.6, x + lean, y - len);
    ctx.stroke();
  }

  // scattered rocks
  for (let i = 0; i < 70; i++) {
    const y = 880 + Math.pow(rand(), 0.7) * (H - 880);
    const depth = (y - 880) / (H - 880);
    const x = rand() * W;
    const w = 4 + depth * 36 * rand();
    const h = w * (0.4 + rand() * 0.35);
    ctx.globalAlpha = 0.5 + depth * 0.4;
    ctx.fillStyle = rand() > 0.5 ? '#6b3a24' : '#7d4a2e';
    ctx.beginPath();
    ctx.ellipse(x, y, w, h, rand() * 0.4 - 0.2, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha *= 0.5;
    ctx.fillStyle = 'rgba(232,180,126,.55)';
    ctx.beginPath();
    ctx.ellipse(x - w * 0.2, y - h * 0.55, w * 0.55, h * 0.35, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  // low scrub: dark clumps scattered through the mid-ground
  for (let i = 0; i < 90; i++) {
    const y = 850 + Math.pow(rand(), 0.8) * (H - 860);
    const depth = (y - 850) / (H - 850);
    const x = rand() * W;
    const r = 7 + depth * 30 * rand();
    ctx.globalAlpha = 0.22 + depth * 0.30;
    ctx.fillStyle = rand() > 0.5 ? '#4b3a1d' : '#3b2c16';
    for (let j = 0; j < 6; j++) {
      ctx.beginPath();
      ctx.ellipse(x + (rand() - 0.5) * r * 1.5, y + (rand() - 0.5) * r * 0.4,
        r * (0.25 + rand() * 0.35), r * (0.10 + rand() * 0.16), 0, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }
}

function acacia(ctx, x, baseY, h, color, rand, alpha = 1) {
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = color;

  // trunk: two curves meeting at the canopy
  ctx.beginPath();
  ctx.moveTo(x - h * 0.035, baseY);
  ctx.quadraticCurveTo(x - h * 0.02, baseY - h * 0.35, x - h * 0.01, baseY - h * 0.55);
  ctx.lineTo(x + h * 0.02, baseY - h * 0.55);
  ctx.quadraticCurveTo(x + h * 0.03, baseY - h * 0.3, x + h * 0.055, baseY);
  ctx.closePath();
  ctx.fill();

  // branches
  ctx.lineWidth = Math.max(2, h * 0.014);
  ctx.strokeStyle = color;
  for (let i = 0; i < 4; i++) {
    const dir = i % 2 === 0 ? 1 : -1;
    ctx.beginPath();
    ctx.moveTo(x, baseY - h * (0.5 + i * 0.03));
    ctx.quadraticCurveTo(
      x + dir * h * (0.08 + rand() * 0.06),
      baseY - h * (0.68 + i * 0.02),
      x + dir * h * (0.16 + rand() * 0.10),
      baseY - h * (0.80 + rand() * 0.05));
    ctx.stroke();
  }

  // umbrella canopy: stacked flat ellipses
  for (let i = 0; i < 7; i++) {
    const cx = x + (rand() - 0.5) * h * 0.42;
    const cy = baseY - h * (0.84 + rand() * 0.10);
    const w = h * (0.16 + rand() * 0.16);
    const hh = h * (0.035 + rand() * 0.03);
    ctx.beginPath();
    ctx.ellipse(cx, cy, w, hh, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.restore();
}

function drawTrees(ctx, W) {
  const rand = rng(7788);
  // horizon scrub, tiny and hazy
  for (let i = 0; i < 26; i++) {
    const x = rand() * W;
    const h = 40 + rand() * 50;
    acacia(ctx, x, 800 + rand() * 20, h, '#71402a', rand, 0.22 + rand() * 0.12);
  }
  // mid-ground acacias
  acacia(ctx, 2080, 985, 330, '#4a2a1c', rand, 0.92);
  acacia(ctx, 2210, 1015, 240, '#43251a', rand, 0.9);
  acacia(ctx, 150, 1040, 300, '#472719', rand, 0.9);
  acacia(ctx, 330, 1090, 200, '#3f2217', rand, 0.85);
}

function beast(ctx, x, y, s, color, kind, rand, alpha) {
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = color;
  ctx.translate(x, y);
  ctx.scale(s, s);

  if (kind === 'lion') {
    // body
    ctx.beginPath();
    ctx.ellipse(34, -38, 72, 30, -0.03, 0, Math.PI * 2);
    ctx.fill();
    // chest / shoulder
    ctx.beginPath();
    ctx.ellipse(98, -44, 31, 35, 0, 0, Math.PI * 2);
    ctx.fill();
    // mane
    ctx.beginPath();
    ctx.arc(110, -58, 38, 0, Math.PI * 2);
    ctx.fill();
    // head
    ctx.beginPath();
    ctx.ellipse(136, -60, 21, 18, -0.10, 0, Math.PI * 2);
    ctx.fill();
    // muzzle
    ctx.beginPath();
    ctx.ellipse(152, -53, 12, 9, 0.10, 0, Math.PI * 2);
    ctx.fill();
    // ears
    ctx.beginPath();
    ctx.arc(124, -82, 6.5, 0, Math.PI * 2);
    ctx.fill();
    // front legs
    ctx.fillRect(96, -30, 11, 42);
    ctx.fillRect(114, -27, 10, 39);
    // back legs
    ctx.fillRect(-20, -28, 13, 40);
    ctx.fillRect(2, -25, 12, 37);
    // tail
    ctx.strokeStyle = color;
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.moveTo(-34, -52);
    ctx.quadraticCurveTo(-68, -64, -70, -88);
    ctx.stroke();
    ctx.beginPath();
    ctx.ellipse(-70, -91, 5, 8, 0.3, 0, Math.PI * 2);
    ctx.fill();
  } else {
    // boar, facing left
    ctx.beginPath();
    ctx.ellipse(-10, -30, 58, 30, 0.03, 0, Math.PI * 2);
    ctx.fill();
    // shoulder hump
    ctx.beginPath();
    ctx.ellipse(-44, -44, 26, 24, 0, 0, Math.PI * 2);
    ctx.fill();
    // head
    ctx.beginPath();
    ctx.ellipse(-70, -34, 28, 21, 0.12, 0, Math.PI * 2);
    ctx.fill();
    // snout
    ctx.beginPath();
    ctx.ellipse(-94, -28, 14, 11, 0.2, 0, Math.PI * 2);
    ctx.fill();
    // tusk
    ctx.strokeStyle = 'rgba(236,222,196,.75)';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(-96, -22);
    ctx.quadraticCurveTo(-106, -26, -104, -36);
    ctx.stroke();
    // ear
    ctx.beginPath();
    ctx.moveTo(-56, -52);
    ctx.lineTo(-46, -66);
    ctx.lineTo(-40, -50);
    ctx.closePath();
    ctx.fill();
    // legs
    ctx.fillRect(-46, -12, 11, 26);
    ctx.fillRect(-28, -10, 10, 24);
    ctx.fillRect(6, -12, 11, 26);
    ctx.fillRect(24, -10, 10, 24);
    // tail
    ctx.strokeStyle = color;
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(46, -40);
    ctx.quadraticCurveTo(60, -46, 58, -58);
    ctx.stroke();
  }
  ctx.restore();
}

function drawBeasts(ctx) {
  const rand = rng(4242);

  // dust kicked up around the fight
  for (let i = 0; i < 90; i++) {
    const x = 520 + rand() * 470;
    const y = 980 + rand() * 90;
    const r = 6 + rand() * 30;
    ctx.globalAlpha = 0.05 + rand() * 0.06;
    ctx.fillStyle = '#d9a06a';
    ctx.beginPath();
    ctx.ellipse(x, y, r, r * 0.55, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;

  beast(ctx, 560, 1012, 1.0, '#4d2a19', 'lion', rand, 0.82);
  beast(ctx, 890, 1050, 0.86, '#3d2417', 'boar', rand, 0.86);
}

function drawDust(ctx, W, H) {
  const rand = rng(9911);
  for (let i = 0; i < 520; i++) {
    const x = rand() * W;
    const y = 700 + rand() * (H - 700);
    const a = 0.03 + rand() * 0.07;
    ctx.fillStyle = `rgba(255,224,178,${a})`;
    ctx.beginPath();
    ctx.arc(x, y, 0.6 + rand() * 1.8, 0, Math.PI * 2);
    ctx.fill();
  }
}

function drawVignette(ctx, W, H) {
  // warm grade + vignette; keeps the UI edges readable
  const v = ctx.createRadialGradient(W * 0.5, H * 0.48, H * 0.35, W * 0.5, H * 0.48, H * 0.95);
  v.addColorStop(0, 'rgba(20,8,4,0)');
  v.addColorStop(0.72, 'rgba(20,8,4,.20)');
  v.addColorStop(1, 'rgba(12,4,2,.58)');
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, W, H);

  const top = ctx.createLinearGradient(0, 0, 0, 200);
  top.addColorStop(0, 'rgba(10,14,18,.45)');
  top.addColorStop(1, 'rgba(10,14,18,0)');
  ctx.fillStyle = top;
  ctx.fillRect(0, 0, W, 200);
}

function makeBackground() {
  const W = 2560, H = 1440;
  const c = createCanvas(W, H);
  const ctx = c.getContext('2d');

  drawSky(ctx, W, H);
  drawMesas(ctx);
  drawHaze(ctx, W);
  drawGround(ctx, W, H);
  drawTrees(ctx, W);
  drawBeasts(ctx);
  drawDust(ctx, W, H);
  drawVignette(ctx, W, H);

  fs.writeFileSync(path.join(OUT, 'barrens-bg.png'), c.toBuffer('image/png'));
}

// ------------------------------------------------------------------ minimap

function makeMinimap() {
  const W = 256, H = 190;
  const c = createCanvas(W, H);
  const ctx = c.getContext('2d');
  const rand = rng(31337);

  // base desert
  const base = ctx.createLinearGradient(0, 0, W, H);
  base.addColorStop(0, '#c08c58');
  base.addColorStop(0.55, '#b97f4b');
  base.addColorStop(1, '#a86c3e');
  ctx.fillStyle = base;
  ctx.fillRect(0, 0, W, H);

  // terrain blotches
  for (let i = 0; i < 90; i++) {
    const x = rand() * W, y = rand() * H;
    const r = 10 + rand() * 46;
    ctx.globalAlpha = 0.05 + rand() * 0.10;
    ctx.fillStyle = rand() > 0.5 ? '#d8a86e' : '#8d5530';
    ctx.beginPath();
    ctx.ellipse(x, y, r, r * 0.7, rand() * 3, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;

  // northern ridge (mesa line)
  ctx.fillStyle = 'rgba(120,72,40,.55)';
  ctx.beginPath();
  ctx.moveTo(0, 22);
  for (let x = 0; x <= W; x += 16) {
    ctx.lineTo(x, 22 + Math.sin(x * 0.06) * 9 + rand() * 6);
  }
  ctx.lineTo(W, 0); ctx.lineTo(0, 0);
  ctx.closePath();
  ctx.fill();

  // oasis / water, bottom-left
  ctx.fillStyle = 'rgba(74,122,120,.72)';
  ctx.beginPath();
  ctx.ellipse(42, 168, 58, 34, -0.3, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = 'rgba(120,168,158,.35)';
  ctx.beginPath();
  ctx.ellipse(34, 162, 32, 16, -0.3, 0, Math.PI * 2);
  ctx.fill();

  // roads
  ctx.strokeStyle = 'rgba(226,193,145,.55)';
  ctx.lineWidth = 7;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(6, 120);
  ctx.bezierCurveTo(70, 108, 96, 82, 150, 86);
  ctx.bezierCurveTo(196, 90, 214, 116, 250, 112);
  ctx.stroke();
  ctx.strokeStyle = 'rgba(226,193,145,.42)';
  ctx.lineWidth = 5;
  ctx.beginPath();
  ctx.moveTo(128, 188);
  ctx.bezierCurveTo(132, 150, 148, 130, 152, 88);
  ctx.stroke();

  // scrub dots
  for (let i = 0; i < 60; i++) {
    const x = rand() * W, y = 30 + rand() * (H - 40);
    ctx.fillStyle = `rgba(70,84,42,${0.18 + rand() * 0.22})`;
    ctx.beginPath();
    ctx.arc(x, y, 1.5 + rand() * 3, 0, Math.PI * 2);
    ctx.fill();
  }

  // quest dots and an enemy dot
  const dots = [
    { x: 176, y: 56, c: '#f2d24b' },
    { x: 208, y: 132, c: '#f2d24b' },
    { x: 92, y: 44, c: '#f2d24b' },
    { x: 150, y: 108, c: '#d94333' },
  ];
  for (const d of dots) {
    ctx.fillStyle = 'rgba(0,0,0,.55)';
    ctx.beginPath(); ctx.arc(d.x, d.y + 1, 4.4, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = d.c;
    ctx.beginPath(); ctx.arc(d.x, d.y, 3.6, 0, Math.PI * 2); ctx.fill();
  }

  // player arrow, centre
  ctx.save();
  ctx.translate(128, 95);
  ctx.rotate(-0.5);
  ctx.beginPath();
  ctx.moveTo(0, -10);
  ctx.lineTo(7, 7);
  ctx.lineTo(0, 3);
  ctx.lineTo(-7, 7);
  ctx.closePath();
  ctx.fillStyle = '#f7f3e6';
  ctx.strokeStyle = 'rgba(20,16,10,.7)';
  ctx.lineWidth = 2;
  ctx.fill();
  ctx.stroke();
  ctx.restore();

  // circular-ish falloff so it reads as a map window, not a picture
  const v = ctx.createRadialGradient(W / 2, H / 2, 70, W / 2, H / 2, 170);
  v.addColorStop(0, 'rgba(0,0,0,0)');
  v.addColorStop(1, 'rgba(30,16,8,.35)');
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, W, H);

  fs.writeFileSync(path.join(OUT, 'minimap.png'), c.toBuffer('image/png'));
}

// -------------------------------------------------------------------- icons

function iconCanvas(bg1, bg2) {
  const S = 64;
  const c = createCanvas(S, S);
  const ctx = c.getContext('2d');
  const g = ctx.createLinearGradient(0, 0, 0, S);
  g.addColorStop(0, bg1);
  g.addColorStop(1, bg2);
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, S, S);

  // painterly brush noise, same trick the action buttons' weave gives in game
  const rand = rng(S + bg1.length * 17 + bg2.length * 31);
  for (let i = 0; i < 70; i++) {
    ctx.globalAlpha = 0.03 + rand() * 0.05;
    ctx.fillStyle = rand() > 0.5 ? '#ffffff' : '#000000';
    ctx.beginPath();
    ctx.ellipse(rand() * S, rand() * S, 6 + rand() * 18, 2 + rand() * 6, rand() * 3, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;

  // inset shadow ring so 26px icons keep a readable edge
  const ring = ctx.createRadialGradient(S / 2, S / 2, S * 0.30, S / 2, S / 2, S * 0.72);
  ring.addColorStop(0, 'rgba(0,0,0,0)');
  ring.addColorStop(1, 'rgba(0,0,0,.42)');
  ctx.fillStyle = ring;
  ctx.fillRect(0, 0, S, S);
  return { c, ctx, S };
}

function glyph(ctx, kind) {
  ctx.save();
  ctx.translate(32, 32);
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';

  const white = '#fdfbf3';
  const stroke = (w, color) => { ctx.lineWidth = w; ctx.strokeStyle = color; };

  switch (kind) {
    case 'mark': // hunter's mark: reticle + arrow
      stroke(4, white);
      ctx.beginPath(); ctx.arc(0, 0, 15, 0, Math.PI * 2); ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(0, -24); ctx.lineTo(0, -14);
      ctx.moveTo(0, 14); ctx.lineTo(0, 24);
      ctx.moveTo(-24, 0); ctx.lineTo(-14, 0);
      ctx.moveTo(14, 0); ctx.lineTo(24, 0);
      ctx.stroke();
      ctx.fillStyle = '#e8543c';
      ctx.beginPath(); ctx.arc(0, 0, 5, 0, Math.PI * 2); ctx.fill();
      break;

    case 'arcane': // arcane shot: arrow + spark burst
      stroke(5, white);
      ctx.beginPath(); ctx.moveTo(-20, 20); ctx.lineTo(14, -14); ctx.stroke();
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.moveTo(22, -22); ctx.lineTo(8, -18); ctx.lineTo(18, -8); ctx.closePath(); ctx.fill();
      stroke(3, '#e7b7ff');
      for (let i = 0; i < 5; i++) {
        const a = -2.2 + i * 0.42;
        ctx.beginPath();
        ctx.moveTo(Math.cos(a) * 8, Math.sin(a) * 8);
        ctx.lineTo(Math.cos(a) * 20, Math.sin(a) * 20);
        ctx.stroke();
      }
      break;

    case 'serpent': // serpent sting: fang
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-10, -22);
      ctx.quadraticCurveTo(14, -6, 6, 22);
      ctx.quadraticCurveTo(-2, 6, -10, -22);
      ctx.fill();
      ctx.fillStyle = '#9ee06a';
      ctx.beginPath();
      ctx.ellipse(-4, 2, 4, 7, 0.3, 0, Math.PI * 2);
      ctx.fill();
      break;

    case 'concussive': // shock rings
      stroke(4, white);
      for (let r = 7; r <= 21; r += 7) {
        ctx.beginPath(); ctx.arc(0, 0, r, -0.6, Math.PI * 1.6); ctx.stroke();
      }
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.arc(0, 0, 4, 0, Math.PI * 2); ctx.fill();
      break;

    case 'trap': // immolation trap: flame in a ring
      ctx.fillStyle = '#ffce6b';
      ctx.beginPath();
      ctx.moveTo(0, -24);
      ctx.quadraticCurveTo(16, -6, 10, 8);
      ctx.quadraticCurveTo(4, 20, -4, 20);
      ctx.quadraticCurveTo(-18, 18, -12, -2);
      ctx.quadraticCurveTo(-8, -10, 0, -24);
      ctx.fill();
      ctx.fillStyle = '#fff3cf';
      ctx.beginPath(); ctx.ellipse(0, 8, 5, 8, 0, 0, Math.PI * 2); ctx.fill();
      break;

    case 'mend': // mend pet: paw + cross
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 8, 12, 10, 0, 0, Math.PI * 2); ctx.fill();
      for (const [px, py, r] of [[-13, -2, 5], [-5, -9, 5], [4, -9, 5], [12, -1, 5]]) {
        ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2); ctx.fill();
      }
      stroke(5, '#8ce08a');
      ctx.beginPath(); ctx.moveTo(0, -26); ctx.lineTo(0, -14); ctx.moveTo(-6, -20); ctx.lineTo(6, -20); ctx.stroke();
      break;

    case 'revive': // revive pet: paw + plus
      ctx.strokeStyle = white; ctx.lineWidth = 4;
      ctx.beginPath(); ctx.ellipse(0, 9, 12, 9, 0, 0, Math.PI * 2); ctx.stroke();
      for (const [px, py, r] of [[-12, -3, 3.4], [-4, -10, 3.4], [5, -10, 3.4], [12, -2, 3.4]]) {
        ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2); ctx.stroke();
      }
      stroke(4, '#8ce0c8');
      ctx.beginPath(); ctx.moveTo(12, -24); ctx.lineTo(24, -12); ctx.moveTo(24, -24); ctx.lineTo(12, -12); ctx.stroke();
      break;

    case 'eye': // eagle eye
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-24, 0);
      ctx.quadraticCurveTo(0, -20, 24, 0);
      ctx.quadraticCurveTo(0, 20, -24, 0);
      ctx.fill();
      ctx.fillStyle = '#2b6f8a';
      ctx.beginPath(); ctx.arc(0, 0, 7, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#101820';
      ctx.beginPath(); ctx.arc(0, 0, 3.4, 0, Math.PI * 2); ctx.fill();
      break;

    case 'raptor': // raptor strike: three claw slashes
      stroke(5, white);
      for (let i = -1; i <= 1; i++) {
        ctx.beginPath();
        ctx.moveTo(-14 + i * 11, -20);
        ctx.quadraticCurveTo(-4 + i * 11, 0, -10 + i * 11, 20);
        ctx.stroke();
      }
      break;

    case 'trip': // wing clip / snare: boot + rope
      ctx.fillStyle = white;
      ctx.fillRect(-6, -20, 12, 24);
      ctx.beginPath(); ctx.ellipse(4, 8, 14, 7, 0, 0, Math.PI * 2); ctx.fill();
      stroke(3, '#d8c49a');
      ctx.beginPath(); ctx.arc(0, -6, 15, 0.4, Math.PI * 1.7); ctx.stroke();
      break;

    case 'call': // call pet: whistle
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.moveTo(-22, 4); ctx.lineTo(2, -6); ctx.lineTo(2, 12); ctx.lineTo(-22, 10); ctx.closePath(); ctx.fill();
      ctx.fillRect(0, -2, 20, 8);
      stroke(2.4, '#8a5a2e');
      ctx.beginPath(); ctx.moveTo(14, 6); ctx.lineTo(14, 16); ctx.stroke();
      break;

    case 'dismiss': // dismiss pet: paw with a slash
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 8, 11, 9, 0, 0, Math.PI * 2); ctx.fill();
      for (const [px, py, r] of [[-12, -2, 4.6], [-4, -9, 4.6], [5, -9, 4.6], [12, -1, 4.6]]) {
        ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2); ctx.fill();
      }
      stroke(4, '#e2564a');
      ctx.beginPath(); ctx.moveTo(-20, -22); ctx.lineTo(20, 22); ctx.stroke();
      break;

    case 'hearth': // hearthstone: stone with glow
      ctx.fillStyle = '#9fd2e8';
      ctx.beginPath(); ctx.ellipse(0, 2, 14, 19, 0.2, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#e7fbff';
      ctx.beginPath(); ctx.ellipse(-3, -4, 5, 9, 0.2, 0, Math.PI * 2); ctx.fill();
      stroke(2.6, '#4a93b8');
      ctx.beginPath(); ctx.arc(0, 2, 23, 0.6, Math.PI * 1.5); ctx.stroke();
      break;

    case 'skin': // skinning knife
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.moveTo(-18, 16); ctx.lineTo(10, -22); ctx.lineTo(16, -16); ctx.lineTo(-12, 20); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#7b4a24';
      ctx.fillRect(-24, 12, 12, 8);
      break;

    case 'leather': // leatherworking: hide
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-18, -18); ctx.quadraticCurveTo(0, -10, 18, -18);
      ctx.quadraticCurveTo(12, 0, 18, 18);
      ctx.quadraticCurveTo(0, 10, -18, 18);
      ctx.quadraticCurveTo(-12, 0, -18, -18);
      ctx.fill();
      stroke(2.4, '#8a5a2e');
      ctx.beginPath(); ctx.arc(0, 0, 6, 0, Math.PI * 2); ctx.stroke();
      break;

    case 'cook': // cooking pot
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 6, 20, 14, 0, 0, Math.PI * 2); ctx.fill();
      ctx.fillRect(-20, 0, 40, 7);
      stroke(2.6, '#c98a52');
      ctx.beginPath(); ctx.arc(0, -4, 6, Math.PI, 0); ctx.stroke();
      break;

    case 'bandage': // first aid
      ctx.save(); ctx.rotate(-0.6);
      ctx.fillStyle = white;
      ctx.fillRect(-20, -8, 40, 16);
      ctx.fillStyle = '#e05a4f';
      ctx.fillRect(-4, -8, 8, 16);
      ctx.restore();
      break;

    case 'fish': // fishing rod
      stroke(3.4, '#d9b477');
      ctx.beginPath(); ctx.moveTo(-20, 22); ctx.lineTo(16, -22); ctx.stroke();
      stroke(1.6, '#9fd2e8');
      ctx.beginPath(); ctx.moveTo(16, -22); ctx.lineTo(20, 8); ctx.stroke();
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.arc(20, 10, 3.4, 0, Math.PI * 2); ctx.fill();
      break;

    case 'bread': // food
      ctx.fillStyle = '#e8c07a';
      ctx.beginPath(); ctx.ellipse(0, 2, 20, 13, 0, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#f7e2b0';
      ctx.beginPath(); ctx.ellipse(-3, -3, 11, 6, 0, 0, Math.PI * 2); ctx.fill();
      break;

    case 'water': // drink
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-9, -20); ctx.lineTo(9, -20); ctx.lineTo(7, 14);
      ctx.quadraticCurveTo(0, 22, -7, 14); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#6ab8e8';
      ctx.beginPath(); ctx.ellipse(0, 6, 8, 8, 0, 0, Math.PI * 2); ctx.fill();
      break;

    case 'attack': // pet attack: crossed swords
      stroke(4.4, white);
      ctx.beginPath(); ctx.moveTo(-17, -17); ctx.lineTo(17, 17); ctx.moveTo(17, -17); ctx.lineTo(-17, 17); ctx.stroke();
      ctx.fillStyle = '#c9c1b0';
      ctx.fillRect(-21, -21, 8, 8);
      ctx.fillRect(13, -21, 8, 8);
      break;

    case 'follow': // follow: footprints
      ctx.fillStyle = white;
      for (const [x, y, s] of [[-10, -12, 1], [8, -2, 1], [-6, 12, 0.8]]) {
        ctx.beginPath(); ctx.ellipse(x, y, 7 * s, 10 * s, 0.3, 0, Math.PI * 2); ctx.fill();
      }
      break;

    case 'stay': // stay: flat hand
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 6, 13, 11, 0, 0, Math.PI * 2); ctx.fill();
      for (let i = 0; i < 4; i++) {
        ctx.fillRect(-11 + i * 7, -20 + Math.abs(i - 1.5) * 2, 5, 22);
      }
      ctx.fillRect(-18, 0, 6, 12);
      break;

    case 'passive': // paw with a shield (passive stance)
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 9, 11, 8, 0, 0, Math.PI * 2); ctx.fill();
      for (const [px, py] of [[-11, 0], [-4, -7], [4, -7], [11, 0]]) {
        ctx.beginPath(); ctx.arc(px, py, 4, 0, Math.PI * 2); ctx.fill();
      }
      stroke(3, '#9ad0ff');
      ctx.beginPath(); ctx.moveTo(0, -25); ctx.lineTo(14, -19); ctx.lineTo(12, -2); ctx.lineTo(0, 5); ctx.lineTo(-12, -2); ctx.lineTo(-14, -19); ctx.closePath(); ctx.stroke();
      break;

    case 'defensive': // shield stance
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(0, -22); ctx.lineTo(17, -15); ctx.lineTo(15, 4);
      ctx.quadraticCurveTo(8, 16, 0, 22);
      ctx.quadraticCurveTo(-8, 16, -15, 4);
      ctx.lineTo(-17, -15);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = '#3c6e3c';
      ctx.fillRect(-2, -12, 4, 24);
      break;

    case 'assist': // assist stance: two arrows
      stroke(4, white);
      ctx.beginPath(); ctx.moveTo(-18, 10); ctx.lineTo(12, -14); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(2, -18); ctx.lineTo(16, -18); ctx.lineTo(16, -4); ctx.stroke();
      break;

    case 'growl': // growl: roaring muzzle
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.ellipse(0, 0, 22, 16, 0, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#6b1f1a';
      ctx.beginPath(); ctx.ellipse(0, 2, 13, 8, 0, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = white;
      for (let i = -1; i <= 1; i++) {
        ctx.beginPath();
        ctx.moveTo(i * 8 - 3, -10); ctx.lineTo(i * 8, -3); ctx.lineTo(i * 8 + 3, -10);
        ctx.closePath(); ctx.fill();
      }
      break;

    case 'bite': // bite: teeth
      ctx.fillStyle = white;
      for (let i = 0; i < 4; i++) {
        const x = -18 + i * 12;
        ctx.beginPath(); ctx.moveTo(x, -14); ctx.lineTo(x + 9, -14); ctx.lineTo(x + 4.5, 2); ctx.closePath(); ctx.fill();
        ctx.beginPath(); ctx.moveTo(x, 14); ctx.lineTo(x + 9, 14); ctx.lineTo(x + 4.5, -2); ctx.closePath(); ctx.fill();
      }
      break;

    case 'charge': // boar charge: horn / speed lines
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-20, 14);
      ctx.quadraticCurveTo(-4, -20, 22, -14);
      ctx.quadraticCurveTo(2, -6, -8, 16);
      ctx.closePath();
      ctx.fill();
      stroke(3, '#ffd27a');
      ctx.beginPath(); ctx.moveTo(-22, 2); ctx.lineTo(-10, 2); ctx.moveTo(-22, -6); ctx.lineTo(-8, -6); ctx.stroke();
      break;

    case 'hawk': // aspect of the hawk: wing
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(-24, 12);
      ctx.quadraticCurveTo(-8, -18, 8, -22);
      ctx.quadraticCurveTo(2, -8, 6, 2);
      ctx.quadraticCurveTo(16, -4, 24, -2);
      ctx.quadraticCurveTo(18, 14, 4, 20);
      ctx.quadraticCurveTo(-8, 22, -24, 12);
      ctx.fill();
      stroke(2.2, '#c9a06a');
      ctx.beginPath(); ctx.moveTo(-16, 10); ctx.lineTo(12, -2); ctx.stroke();
      break;

    case 'fortitude': // power word: fortitude
      ctx.fillStyle = white;
      ctx.beginPath();
      ctx.moveTo(0, -22); ctx.lineTo(16, -16); ctx.lineTo(14, 4);
      ctx.quadraticCurveTo(8, 16, 0, 22);
      ctx.quadraticCurveTo(-8, 16, -14, 4);
      ctx.lineTo(-16, -16);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = '#c9a24a';
      ctx.fillRect(-2.5, -12, 5, 22);
      ctx.fillRect(-10, -4, 20, 5);
      break;

    default:
      ctx.fillStyle = white;
      ctx.beginPath(); ctx.arc(0, 0, 14, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}

const ICONS = [
  ['hunter_mark', 'mark', '#6d1a16', '#2b0b0a'],
  ['arcane_shot', 'arcane', '#4a2a7a', '#1c0f36'],
  ['serpent_sting', 'serpent', '#2f5a1e', '#12260d'],
  ['concussive', 'concussive', '#40506b', '#1b2434'],
  ['immolation', 'trap', '#7a3a12', '#331606'],
  ['mend_pet', 'mend', '#245a2a', '#0d260f'],
  ['revive_pet', 'revive', '#1f4f52', '#0b2426'],
  ['eagle_eye', 'eye', '#24566b', '#0d2634'],
  ['raptor', 'raptor', '#5c3a1c', '#231408'],
  ['wing_clip', 'trip', '#4a4436', '#1d1a14'],
  ['call_pet', 'call', '#4f3a22', '#1c140b'],
  ['dismiss_pet', 'dismiss', '#3a2a2a', '#150f0f'],

  ['hearth', 'hearth', '#1d3f5c', '#0a1a26'],
  ['skin', 'skin', '#4a3a2a', '#191410'],
  ['leather', 'leather', '#5c4226', '#22170c'],
  ['cook', 'cook', '#5a2e1a', '#21100a'],
  ['bandage', 'bandage', '#5c2a2a', '#200e0e'],
  ['fish', 'fish', '#22404a', '#0c1a1e'],
  ['bread', 'bread', '#5a4a24', '#201a0c'],
  ['water', 'water', '#1e3a5c', '#0a1624'],

  ['pet_attack', 'attack', '#7a1e18', '#2a0b09'],
  ['pet_follow', 'follow', '#4a4a2a', '#191908'],
  ['pet_stay', 'stay', '#3a3a2a', '#141410'],
  ['pet_passive', 'passive', '#2a3a5c', '#0e1424'],
  ['pet_defensive', 'defensive', '#4a3a1e', '#1a140a'],
  ['pet_assist', 'assist', '#5c3a1e', '#22140a'],
  ['pet_growl', 'growl', '#5c1e1e', '#221010'],
  ['pet_bite', 'bite', '#4a2a1a', '#1a0f0a'],
  ['pet_charge', 'charge', '#5c4020', '#21160b'],
];

function makeIcons() {
  for (const [name, kind, bg1, bg2] of ICONS) {
    const { c, ctx } = iconCanvas(bg1, bg2);
    glyph(ctx, kind);
    fs.writeFileSync(path.join(OUT, 'icon_' + name + '.png'), c.toBuffer('image/png'));
  }
}

makeBackground();
makeMinimap();
makeIcons();
console.log('scenario assets ->', OUT);
