/**
 * 装饰加强候选对比图 — 当前实施版 vs 四套更有层次的方案。
 * 材质全部取自仓库现役资产（stripe / brush / corner），渐变遮罩在 Canvas 里模拟，
 * 对应 Lua 侧的实现路径写在每张候选的说明里。
 * 用法：node tools/make-decoration-enhance.js
 * 输出：docs/texture-preview/decoration-enhance.png
 */
const fs = require("fs");
const path = require("path");
const { createCanvas, GlobalFonts, loadImage } = require("@napi-rs/canvas");

const ROOT = path.join(__dirname, "..");
const OUT = path.join(ROOT, "docs", "texture-preview", "decoration-enhance.png");
GlobalFonts.registerFromPath(path.join(ROOT, "Assets", "Fonts", "LXGWWenKai-Regular.ttf"), "LXGW");
const FONT = "LXGW";

const W = 1320, H = 1320;
const canvas = createCanvas(W, H);
const ctx = canvas.getContext("2d");

const EDGE = "rgba(134,143,175,.82)";
const AMBIENT = "rgba(33,38,37,.92)";
const BRIGHT = "#e8e4d6";
const MUTED = "#9fa79e";
const GOLD = "#d9b66a";
const HILITE = "#8fc7e8";

async function main() {
  const stripe = await loadImage(path.join(ROOT, "docs", "scratch", "monet_stripe_weave.png"));
  const brush = await loadImage(path.join(ROOT, "docs", "texture-preview", "monet_brush_stroke.png"));
  const corner = await loadImage(path.join(ROOT, "docs", "texture-preview", "monet_corner.png"));

  ctx.fillStyle = "#0d1210"; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = BRIGHT; ctx.font = `bold 32px ${FONT}`;
  ctx.fillText("MonetUI 装饰加强 — 当前 vs 四套方案", 40, 50);
  ctx.fillStyle = MUTED; ctx.font = `15px ${FONT}`;
  ctx.fillText("全部用仓库现役材质 · 渐变在出图里模拟、实现路径写在候选下 · 未改游戏代码 · 2026-11-20", 40, 80);
  ctx.fillStyle = "rgba(255,255,255,.10)"; ctx.fillRect(40, 96, W - 80, 1);

  const pat = ctx.createPattern(stripe, "repeat");
  const CW = 600, GAP = 24, L = 40, R = L + CW + GAP;
  let y = 116;

  // ---- helpers ----------------------------------------------------------------
  function panel(x, top, w, h, title) {
    ctx.fillStyle = AMBIENT; ctx.fillRect(x, top, w, h);
    ctx.strokeStyle = EDGE; ctx.lineWidth = 1; ctx.strokeRect(x + .5, top + .5, w - 1, h - 1);
    ctx.fillStyle = BRIGHT; ctx.font = `bold 17px ${FONT}`; ctx.fillText(title, x + 14, top + 27);
    ctx.fillStyle = "rgba(134,143,175,.35)"; ctx.fillRect(x + 12, top + 38, w - 24, 1);
  }
  function well(x, top, w, h) {
    ctx.fillStyle = "rgba(0,0,0,.28)"; ctx.fillRect(x, top, w, h);
    ctx.strokeStyle = "rgba(134,143,175,.28)"; ctx.lineWidth = 1; ctx.strokeRect(x + .5, top + .5, w - 1, h - 1);
  }
  function drawWeave(x, top, w, h, alpha) {
    if (!alpha) return;
    ctx.save(); ctx.globalAlpha = alpha; ctx.fillStyle = pat; ctx.fillRect(x, top, w, h); ctx.restore();
  }
  // 局部渐变斜纹：先画织纹到临时画布，再用 destination-in 做水平渐隐，最后贴回主画布
  function drawFadeWeave(x, top, w, h, alpha) {
    const t = createCanvas(w, h), c = t.getContext("2d");
    c.globalAlpha = alpha; c.fillStyle = c.createPattern(stripe, "repeat"); c.fillRect(0, 0, w, h);
    c.globalCompositeOperation = "destination-in";
    const g = c.createLinearGradient(0, 0, w, 0);
    g.addColorStop(0, "rgba(0,0,0,1)"); g.addColorStop(.55, "rgba(0,0,0,.55)"); g.addColorStop(1, "rgba(0,0,0,0)");
    c.fillStyle = g; c.fillRect(0, 0, w, h);
    ctx.drawImage(t, x, top);
  }
  // 双层经纬：45° 织纹 + 镜像织纹，两轴同密度
  function drawCrossWeave(x, top, w, h, a1, a2) {
    drawWeave(x, top, w, h, a1);
    const t = createCanvas(w, h), c = t.getContext("2d");
    c.globalAlpha = a2; c.translate(w, 0); c.scale(-1, 1);
    c.fillStyle = c.createPattern(stripe, "repeat"); c.fillRect(0, 0, w, h);
    ctx.drawImage(t, x, top);
  }
  function drawBrush(x, top, w, alpha, stretch) {
    ctx.save(); ctx.globalAlpha = alpha;
    if (stretch) ctx.drawImage(brush, x, top, w, 14);
    else {
      // S4：一条连续笔刷，横向撑满但用渐变遮罩做左浓右淡（不是平铺成几截）。
      const t = createCanvas(w, 16), c = t.getContext("2d");
      c.drawImage(brush, 0, 0, w, 16);
      c.globalCompositeOperation = "destination-in";
      const g = c.createLinearGradient(0, 0, w, 0);
      g.addColorStop(0, "rgba(0,0,0,1)"); g.addColorStop(.7, "rgba(0,0,0,.55)"); g.addColorStop(1, "rgba(0,0,0,.12)");
      c.fillStyle = g; c.fillRect(0, 0, w, 16);
      ctx.drawImage(t, x, top);
    }
    ctx.restore();
  }
  function tiny(text, x, ty, color = MUTED, size = 13) {
    ctx.fillStyle = color; ctx.font = `${size}px ${FONT}`; ctx.fillText(text, x, ty);
  }
  function head(no, name, note, accent) {
    ctx.fillStyle = accent || GOLD; ctx.font = `bold 21px ${FONT}`;
    ctx.fillText(`${no}  ${name}`, L, y + 20);
    ctx.fillStyle = MUTED; ctx.font = `14px ${FONT}`; ctx.fillText(note, R, y + 20);
    y += 32; ctx.fillStyle = "rgba(255,255,255,.07)"; ctx.fillRect(L, y, W - 80, 1); y += 12;
  }
  function labels(a, b) { tiny("当前", L, y + 13); tiny(b, R, y + 13, HILITE); y += 20; }
  function foot(text) { tiny(text, L, y + 8, MUTED, 13); y += 28; }

  // ---- S1 任务凹槽 -------------------------------------------------------------
  head("S1", "局部渐变织纹（推荐）", "斜纹从左上浓到右下淡 · 成本 S / 需烘一张 fade 贴图", HILITE);
  labels("A1 当前：整块均匀斜纹", "S1：一角受光、其余留净");
  panel(L, y, CW, 158, "任务详情"); well(L + 14, y + 48, CW - 28, 96);
  drawWeave(L + 14, y + 48, CW - 28, 96, .10);
  tiny("击败 8 只鬣狗", L + 26, y + 76); tiny("与纳格兰商人交谈", L + 26, y + 106);
  panel(R, y, CW, 158, "任务详情"); well(R + 14, y + 48, CW - 28, 96);
  drawFadeWeave(R + 14, y + 48, CW - 28, 96, .30);
  tiny("击败 8 只鬣狗", R + 26, y + 76); tiny("与纳格兰商人交谈", R + 26, y + 106);
  y += 178;
  foot("实现：生成 monet_weave_fade（斜纹 × 横向 alpha 渐变烘进一张图，走 audit-pixels）→ Skin:Panel{weaveFade} 一个 region。");

  // ---- S2 银行分区头 -----------------------------------------------------------
  head("S2", "双层经纬织物", "45° + 镜像两层错开 · 成本 M / 多一个 region", HILITE);
  labels("A2 当前：单层斜纹 0.14", "S2：经纬交叠，像帆布");
  panel(L, y, CW, 158, "银行"); well(L + 14, y + 48, CW - 28, 34);
  drawWeave(L + 14, y + 48, CW - 28, 34, .14); tiny("背包", L + 26, y + 70);
  ctx.fillStyle = "rgba(255,255,255,.06)";
  for (let i = 0; i < 24; i++) ctx.fillRect(L + 18 + (i % 8) * 68, y + 92 + Math.floor(i / 8) * 18, 60, 14);
  panel(R, y, CW, 158, "银行"); well(R + 14, y + 48, CW - 28, 34);
  drawCrossWeave(R + 14, y + 48, CW - 28, 34, .10, .07); tiny("背包", R + 26, y + 70);
  ctx.fillStyle = "rgba(255,255,255,.06)";
  for (let i = 0; i < 24; i++) ctx.fillRect(R + 18 + (i % 8) * 68, y + 92 + Math.floor(i / 8) * 18, 60, 14);
  y += 178;
  foot("实现：Skin:Panel{weaveCross} 再挂一层镜像斜纹（复用 Widget:BarWeave 的 texcoord 口径，改 u 方向）。");

  // ---- S3 收藏空区 -------------------------------------------------------------
  head("S3", "淡织纹 + 笔触收边", "极淡底纹 + 上沿一笔，空列表不空 · 成本 S / 一屏一条笔刷", HILITE);
  labels("A3 当前：整块均匀斜纹 0.08", "S3：织纹打底、笔触压边");
  panel(L, y, CW, 158, "收藏 · 坐骑"); well(L + 14, y + 48, CW - 28, 96);
  drawWeave(L + 14, y + 48, CW - 28, 96, .08);
  tiny("（空列表）", L + CW / 2 - 40, y + 100, "#6c726d");
  panel(R, y, CW, 158, "收藏 · 坐骑"); well(R + 14, y + 48, CW - 28, 96);
  drawWeave(R + 14, y + 48, CW - 28, 96, .05);
  drawBrush(R + 16, y + 46, CW - 32, .5, true);
  tiny("（空列表）", R + CW / 2 - 40, y + 100, "#6c726d");
  y += 178;
  foot("实现：Well{weave=0.05} + 一条 Widget:Rule 挂内容区上沿；笔刷美术色不染、只调 alpha。");

  // ---- S4 配置标题笔刷 ---------------------------------------------------------
  head("S4", "笔刷渐隐（必做）", "现在是均匀一笔拉满、没有笔锋 · 成本 S / 改锚定+渐隐", HILITE);
  labels("A4 当前：一笔均匀拉宽", "S4：一笔连续、左浓右淡");
  panel(L, y, CW, 148, "界面设置", true);
  tiny("MonetUI", L + 16, y + 26, BRIGHT, 17);
  drawBrush(L + 16, y + 42, CW - 32, .9, true);
  tiny("常规      缩放 · 主题 · 字号", L + 20, y + 88);
  panel(R, y, CW, 148, "界面设置", true);
  tiny("MonetUI", R + 16, y + 26, BRIGHT, 17);
  drawBrush(R + 16, y + 42, CW - 32, .9, false);
  tiny("常规      缩放 · 主题 · 字号", R + 20, y + 88);
  y += 168;
  foot("实现：Widget:Rule 加 opts.fade，渲染时叠一条 alpha 渐变遮罩（或烘一张 monet_brush_fade），一笔连续、左浓右淡。");

  // ---- 角花说明 ---------------------------------------------------------------
  tiny("角花 monet_corner（保留美术色、只调 alpha）维持现状；本轮不加新角饰，避免一屏元素过多。", L, y + 8, MUTED, 13);
  ctx.save(); ctx.globalAlpha = .7; ctx.drawImage(corner, R, y - 4, 28, 28); ctx.restore();

  fs.writeFileSync(OUT, canvas.toBuffer("image/png"));
  console.log("wrote", OUT, canvas.width + "x" + canvas.height);
}
main().catch((e) => { console.error(e); process.exit(1); });
