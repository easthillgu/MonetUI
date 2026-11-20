/**
 * 装饰候选对比图 — 现状 vs 候选，材质全部取自仓库现役资产。
 * 用法：node tools/make-decoration-compare.js
 * 输出：docs/texture-preview/decoration-compare.png
 */
const fs = require("fs");
const path = require("path");
const { createCanvas, GlobalFonts, loadImage } = require("@napi-rs/canvas");

const ROOT = path.join(__dirname, "..");
const OUT = path.join(ROOT, "docs", "texture-preview", "decoration-compare.png");
GlobalFonts.registerFromPath(path.join(ROOT, "Assets", "Fonts", "LXGWWenKai-Regular.ttf"), "LXGW");
const FONT = "LXGW";

const W = 1240;
const H = 1810;
const canvas = createCanvas(W, H);
const ctx = canvas.getContext("2d");

const EDGE = "rgba(134,143,175,.82)";
const AMBIENT = "rgba(33,38,37,.88)";
const BRIGHT = "#e6e2d4";
const MUTED = "#a9b0a8";
const GOLD = "#d5b26d";
const PURPLE = "rgba(171,108,250,.85)";

async function main() {
  const stripe = await loadImage(path.join(ROOT, "docs", "scratch", "monet_stripe_weave.png"));
  const hair = await loadImage(path.join(ROOT, "docs", "scratch", "monet_hairline.png"));
  const brush = await loadImage(path.join(ROOT, "docs", "texture-preview", "monet_brush_stroke.png"));
  const corner = await loadImage(path.join(ROOT, "docs", "texture-preview", "monet_corner.png"));

  ctx.fillStyle = "#101513";
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = BRIGHT;
  ctx.font = `bold 30px ${FONT}`;
  ctx.fillText("MonetUI 装饰候选 — 现状 vs 候选", 40, 46);
  ctx.font = `16px ${FONT}`;
  ctx.fillStyle = MUTED;
  ctx.fillText("材质全部来自仓库现役资产 · 配色取塔纳利斯河林档 · 未改任何游戏代码 · 2026-11-20", 40, 76);
  ctx.fillStyle = "rgba(255,255,255,.10)";
  ctx.fillRect(40, 92, W - 80, 1);

  const stripePat = ctx.createPattern(stripe, "repeat");
  function panel(x, y, w, h, title, noUnderline) {
    ctx.fillStyle = AMBIENT;
    ctx.fillRect(x, y, w, h);
    ctx.strokeStyle = EDGE;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    ctx.fillStyle = BRIGHT;
    ctx.font = `bold 16px ${FONT}`;
    ctx.fillText(title, x + 12, y + 24);
    if (!noUnderline) {
      ctx.fillStyle = "rgba(134,143,175,.45)";
      ctx.fillRect(x + 10, y + 34, w - 20, 1);
    }
  }
  function weave(x, y, w, h, alpha) {
    if (!alpha) return;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.fillStyle = stripePat;
    ctx.fillRect(x, y, w, h);
    ctx.restore();
  }
  function hairline(x, y, w, alpha = 0.5, color = "134,143,175") {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.drawImage(hair, x, y, w, 1);
    ctx.restore();
    void color;
  }
  function brushline(x, y, w, alpha = 0.9) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.drawImage(brush, x, y, w, 14);
    ctx.restore();
  }
  function tiny(text, x, y, color = MUTED, size = 13) {
    ctx.fillStyle = color;
    ctx.font = `${size}px ${FONT}`;
    ctx.fillText(text, x, y);
  }

  const CW = 570;
  const gap = 20;
  const left = 40;
  const right = left + CW + gap;
  let y = 118;

  function rowHeader(no, name, note) {
    ctx.fillStyle = GOLD;
    ctx.font = `bold 20px ${FONT}`;
    ctx.fillText(`${no}  ${name}`, left, y + 18);
    ctx.fillStyle = MUTED;
    ctx.font = `14px ${FONT}`;
    ctx.fillText(note, right, y + 18);
    y += 30;
    ctx.fillStyle = "rgba(255,255,255,.07)";
    ctx.fillRect(left, y, W - 80, 1);
    y += 10;
  }
  function half(x, label) {
    ctx.fillStyle = MUTED;
    ctx.font = `13px ${FONT}`;
    ctx.fillText(label, x, y + 12);
  }
  function finish(delta) {
    y += delta;
  }

  // A1 任务正文凹槽
  rowHeader("A1", "任务正文凹槽斜纹扩面", "复用 Quest.lua 现有 ADD 斜纹 · 成本 S / 风险低 · 推荐");
  half(left, "现状");
  half(right, "候选：正文区叠 0.10 α 斜纹");
  y += 20;
  panel(left, y, CW, 150, "任务追踪");
  ctx.fillStyle = "rgba(0,0,0,.25)";
  ctx.fillRect(left + 14, y + 44, CW - 28, 92);
  tiny("[任务] 前往十字路口", left + 24, y + 68);
  tiny("击败 8 只鬣狗", left + 24, y + 92);
  tiny("与纳格兰商人交谈", left + 24, y + 116);
  panel(right, y, CW, 150, "任务追踪");
  ctx.fillStyle = "rgba(0,0,0,.25)";
  ctx.fillRect(right + 14, y + 44, CW - 28, 92);
  weave(right + 14, y + 44, CW - 28, 92, 0.10);
  tiny("[任务] 前往十字路口", right + 24, y + 68);
  tiny("击败 8 只鬣狗", right + 24, y + 92);
  tiny("与纳格兰商人交谈", right + 24, y + 116);
  finish(175);

  // A2 银行分区头
  rowHeader("A2", "银行分区头淡斜纹底", "BankPanel · 成本 S / 别盖物品格 · 推荐");
  half(left, "现状");
  half(right, "候选：分区头带 0.14 α 斜纹");
  y += 20;
  panel(left, y, CW, 150, "银行");
  ctx.fillStyle = "rgba(0,0,0,.30)";
  ctx.fillRect(left + 14, y + 44, CW - 28, 30);
  tiny("背包", left + 24, y + 64);
  ctx.fillStyle = "rgba(255,255,255,.06)";
  for (let i = 0; i < 24; i++) ctx.fillRect(left + 18 + (i % 8) * 66, y + 84 + Math.floor(i / 8) * 20, 58, 16);
  panel(right, y, CW, 150, "银行");
  ctx.fillStyle = "rgba(0,0,0,.30)";
  ctx.fillRect(right + 14, y + 44, CW - 28, 30);
  weave(right + 14, y + 44, CW - 28, 30, 0.14);
  tiny("背包", right + 24, y + 64);
  ctx.fillStyle = "rgba(255,255,255,.06)";
  for (let i = 0; i < 24; i++) ctx.fillRect(right + 18 + (i % 8) * 66, y + 84 + Math.floor(i / 8) * 20, 58, 16);
  finish(175);

  // A3 收藏次级区
  rowHeader("A3", "收藏次级区 / 成就统计格斜纹底", "空列表不再一片死板 · 成本 S / 懒建窗要开窗补扫");
  half(left, "现状");
  half(right, "候选：内容区 0.08 α 斜纹");
  y += 20;
  panel(left, y, CW, 150, "收藏 · 坐骑");
  ctx.fillStyle = "rgba(0,0,0,.22)";
  ctx.fillRect(left + 14, y + 44, CW - 28, 92);
  tiny("（空列表）", left + CW / 2 - 40, y + 94, "#6c726d");
  panel(right, y, CW, 150, "收藏 · 坐骑");
  ctx.fillStyle = "rgba(0,0,0,.22)";
  ctx.fillRect(right + 14, y + 44, CW - 28, 92);
  weave(right + 14, y + 44, CW - 28, 92, 0.08);
  tiny("（空列表）", right + CW / 2 - 40, y + 94, "#6c726d");
  finish(175);

  // A4 配置面板笔刷线
  rowHeader("A4", "配置面板分区线改笔刷线", "monet_brush_stroke（保留美术色、只调 α）· 成本 S / 一屏一条上限");
  half(left, "现状：发丝线");
  half(right, "候选：标题下笔刷一笔");
  y += 20;
  panel(left, y, CW, 150, "界面设置");
  ctx.fillStyle = BRIGHT;
  ctx.font = `14px ${FONT}`;
  ctx.fillText("常规", left + 20, y + 70);
  hairline(left + 20, y + 82, CW - 40, 0.5);
  tiny("缩放 · 主题 · 字号", left + 20, y + 110);
  panel(right, y, CW, 150, "界面设置");
  ctx.fillStyle = BRIGHT;
  ctx.font = `14px ${FONT}`;
  ctx.fillText("常规", right + 20, y + 70);
  brushline(right + 20, y + 80, CW - 40, 0.9);
  tiny("缩放 · 主题 · 字号", right + 20, y + 110);
  finish(175);

  // A5 标题线第二批
  rowHeader("A5", "第二批窗口标题下发丝线", "交易/邮件/拍卖/银行/任务日志/幻化 · 成本 M / 要先逐窗截图");
  half(left, "现状：标题下空");
  half(right, "候选：HeaderRule 细金线");
  y += 20;
  panel(left, y, CW, 150, "交易", true);
  tiny("[物品] 商人出售列表…", left + 20, y + 76);
  tiny("金币 12 34 56", left + 20, y + 108);
  panel(right, y, CW, 150, "交易", true);
  hairline(right + 20, y + 40, CW - 40, 0.55);
  tiny("[物品] 商人出售列表…", right + 20, y + 76);
  tiny("金币 12 34 56", right + 20, y + 108);
  finish(175);

  // B1 中间格并入现实时间
  rowHeader("B1", "信息栏中间格并入现实时间（推荐）", "复用现有每秒链 · 全局 date(\"%H:%M\") · 按分钟写 · 零新块");
  half(left, "现状");
  half(right, "候选：14:32 · 45ms · 60 FPS");
  y += 20;
  function infobar(x, text, mark) {
    ctx.fillStyle = "rgba(12,16,15,.94)";
    ctx.fillRect(x, y, CW, 46);
    ctx.strokeStyle = EDGE;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, CW - 1, 45);
    tiny("12,450g", x + 16, y + 30, "#e0cf9a", 15);
    tiny("耐久 87%", x + 120, y + 30, MUTED, 15);
    tiny(text, x + CW / 2 - 68, y + 30, BRIGHT, 15);
    tiny("好友 4/12", x + CW - 88, y + 30, MUTED, 15);
    ctx.fillStyle = PURPLE;
    ctx.fillRect(x + CW / 2 - 68 - 8, y + 18, 3, 12);
    void mark;
  }
  infobar(left, "45ms · 60 FPS", false);
  infobar(right, "14:32 · 45ms · 60 FPS", true);
  finish(75);

  // B2 独立时钟块
  rowHeader("B2", "信息栏独立 CENTER 时钟块", "固定宽度 + 自带开关 · 成本 S–M / 中心组变宽不避让左右队");
  half(left, "现状");
  half(right, "候选：CENTER 右侧独立时钟");
  y += 20;
  infobar(left, "45ms · 60 FPS", false);
  ctx.fillStyle = "rgba(12,16,15,.94)";
  ctx.fillRect(right, y, CW, 46);
  ctx.strokeStyle = EDGE;
  ctx.strokeRect(right + 0.5, y + 0.5, CW - 1, 45);
  tiny("12,450g", right + 16, y + 30, "#e0cf9a", 15);
  tiny("耐久 87%", right + 120, y + 30, MUTED, 15);
  tiny("45ms · 60 FPS", right + CW / 2 - 68, y + 30, BRIGHT, 15);
  ctx.strokeStyle = PURPLE;
  ctx.lineWidth = 1;
  ctx.strokeRect(right + CW / 2 + 95, y + 12, 62, 22);
  tiny("14:32", right + CW / 2 + 106, y + 28, BRIGHT, 15);
  tiny("好友 4/12", right + CW - 88, y + 30, MUTED, 15);
  finish(85);

  // 角花示意（A4 配角）
  tiny("角花（monet_corner，只调 α）在窗口角落的现有位置保持不变；笔刷线位于标题下沿、与角花错开。", left, y + 6, MUTED, 13);
  ctx.save();
  ctx.globalAlpha = 0.75;
  ctx.drawImage(corner, right + 2, y + 20, 32, 32);
  ctx.restore();

  fs.writeFileSync(OUT, canvas.toBuffer("image/png"));
  console.log("wrote", OUT, canvas.width + "x" + canvas.height);
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
