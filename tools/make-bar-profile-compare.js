/**
 * 条体剖面对比：现状 vs 「顶高光」候选（美术提升 ④）。
 * 用法：node tools/make-bar-profile-compare.js
 * 输出：docs/texture-preview/bar-profile-compare.png
 */
const fs = require("fs");
const path = require("path");
const { createCanvas, GlobalFonts, loadImage } = require("@napi-rs/canvas");
const ROOT = path.join(__dirname, "..");
const OUT = path.join(ROOT, "docs", "texture-preview", "bar-profile-compare.png");
GlobalFonts.registerFromPath(path.join(ROOT, "Assets", "Fonts", "LXGWWenKai-Regular.ttf"), "LXGW");
const FONT = "LXGW";

const W = 1080, H = 720;
const canvas = createCanvas(W, H);
const ctx = canvas.getContext("2d");
const MUTED = "#9fa79e", BRIGHT = "#e8e4d6", GOLD = "#d9b66a";

async function main() {
  const grad = await loadImage(path.join(ROOT, "docs", "scratch", "monet_barfill_gradient.png"));
  const thin = await loadImage(path.join(ROOT, "docs", "scratch", "monet_barfill_thin.png"));
  ctx.fillStyle = "#0d1210"; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = BRIGHT; ctx.font = `bold 28px ${FONT}`; ctx.fillText("条体剖面 — 现状 vs 顶高光候选", 36, 46);
  ctx.fillStyle = MUTED; ctx.font = `14px ${FONT}`; ctx.fillText("取样自仓库现役 TGA；候选只翻转 gradient 剖面方向，thin 不动 · 2026-11-20", 36, 74);
  ctx.fillStyle = "rgba(255,255,255,.1)"; ctx.fillRect(36, 90, W - 72, 1);

  // 剖面数值：现状 gradient 顶→底（regen-textures.js 的 reverse 后）
  const cur = [124,126,126,129,131,131,132,132,133,134,137,139,139,141,144,144,147,149,149,152,155,156,156,157,161,161,167,167,167,170,173,173,175,178,178,181,183,186,186,189,189,192,192,195,197,198,198,200,200,203,205,205,205,206,205,205,197,189,152,141];
  const flip = cur.slice().reverse();

  function bar(x, y, w, h, values, tint) {
    ctx.fillStyle = "rgba(33,38,37,.9)"; ctx.fillRect(x, y, w, h);
    for (let row = 0; row < h; row++) {
      const idx = Math.min(values.length - 1, Math.round(row / Math.max(1, h - 1) * (values.length - 1)));
      const v = values[idx] / 255 * tint;
      ctx.fillStyle = `rgb(${Math.round(v)},${Math.round(v * .98)},${Math.round(v * .92)})`;
      ctx.fillRect(x, y + row, w, 1);
    }
    ctx.strokeStyle = "rgba(134,143,175,.5)"; ctx.lineWidth = 1; ctx.strokeRect(x + .5, y + .5, w - 1, h - 1);
  }
  function label(text, x, y, color = MUTED) { ctx.fillStyle = color; ctx.font = `15px ${FONT}`; ctx.fillText(text, x, y); }

  label("现状 gradient（顶最暗 → 中下亮 → 底缘压暗）", 36, 126);
  label("候选：顶高光（翻转剖面）", 556, 126, GOLD);
  bar(36, 142, 480, 28, cur, 1);
  bar(556, 142, 480, 28, flip, 1);
  label("现状 thin（单向：上亮下暗，≤6px 用）", 36, 204);
  ctx.drawImage(thin, 36, 218, 480, 6);
  ctx.drawImage(thin, 36, 232, 480, 4);
  label("thin 已单向，候选不动它", 556, 204, GOLD);

  // 数值折线
  function plot(values, x, y, w, h, color) {
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.beginPath();
    for (let i = 0; i < values.length; i++) {
      const px = x + i / (values.length - 1) * w;
      const py = y + h - (values[i] - 110) / 100 * h;
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.stroke();
  }
  label("亮度剖面（顶 → 底）", 36, 286);
  plot(cur, 36, 300, 480, 90, "#8fc7e8");
  plot(flip, 556, 300, 480, 90, GOLD);
  ctx.fillStyle = MUTED; ctx.font = `13px ${FONT}`;
  ctx.fillText("蓝=现状 · 金=候选。提案说「顶高光/主体/底余辉」，现状实测顶最暗；若翻转让顶最亮，血条体积感会更像受光面。", 36, 420);
  ctx.fillText("两种都算「三段剖面」，都不违反平板纪律；选中哪版再改 regen-textures.js 并重出 TGA→BLP。", 36, 446);
  ctx.fillText("注：Widget:BarGradient 无调用点，不存在贴图剖面 × 运行期渐变的双层相乘。", 36, 472);

  fs.writeFileSync(OUT, canvas.toBuffer("image/png"));
  console.log("wrote", OUT, canvas.width + "x" + canvas.height);
}
main().catch(e => { console.error(e); process.exit(1); });
