// 生成 corner radius 对比测试页
const { createCanvas } = require('@napi-rs/canvas');
const fs = require('fs');

const SIZE = 16;           // 画布尺寸
const LINE_WIDTH = 1;      // 线宽固定 1px
const variants = [3, 4, 5, 6, 7, 8];  // 候选半径

function draw(ctx, radius) {
  ctx.strokeStyle = '#fffcf6';
  ctx.lineWidth = LINE_WIDTH;
  ctx.lineCap = 'butt';
  const r = radius - LINE_WIDTH / 2;
  const c = radius - LINE_WIDTH / 2;
  ctx.beginPath();
  ctx.arc(c, c, r, Math.PI, Math.PI * 1.5);
  ctx.stroke();
}

let html = `<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body{background:#1a1a2e;color:#eee;font-family:'Segoe UI','Microsoft YaHei',sans-serif;padding:24px;}
h2{margin-bottom:6px;font-size:16px;}
p{color:#888;font-size:12px;margin-bottom:20px;}
.row{display:flex;gap:24px;flex-wrap:wrap;align-items:flex-end;}
.item{text-align:center;}
.name{font-size:12px;color:#63b3ed;margin-bottom:8px;font-family:Consolas,monospace;}
.frame{width:128px;height:128px;display:flex;align-items:center;justify-content:center;
  background-image:conic-gradient(#262638 25%,#1e1e2e 0 50%,#262638 0 75%,#1e1e2e 0);
  background-size:16px 16px;border:1px solid #30363d;border-radius:4px;margin-bottom:6px;}
img{image-rendering:pixelated;width:128px;height:128px;}
.actual{font-size:10px;color:#666;}
</style></head><body>
<h2>Corner 半径候选（16×16 画布，1px 线宽，128px 放大预览）</h2>
<p>棋盘格为 16px 方格；图片按 8× 最近邻放大，像素清晰可见。选择视觉最合适的一个。</p>
<div class="row">`;

for (const radius of variants) {
  const canvas = createCanvas(SIZE, SIZE);
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, SIZE, SIZE);
  draw(ctx, radius);
  const uri = canvas.toDataURL('image/png');
  // 统计不透明像素
  const data = ctx.getImageData(0, 0, SIZE, SIZE).data;
  let count = 0, maxX = -1, maxY = -1;
  for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
    if (data[(y * SIZE + x) * 4 + 3] > 0) { count++; maxX = Math.max(maxX, x); maxY = Math.max(maxY, y); }
  }
  html += `<div class="item">
    <div class="name">radius = ${radius}</div>
    <div class="frame"><img src="${uri}"></div>
    <div class="actual">${count} px · 占 ${maxX + 1}×${maxY + 1}</div>
  </div>`;
}

html += `</div></body></html>`;
fs.writeFileSync(__dirname + '/../corner-radius-test.html', html);
console.log('Generated: corner-radius-test.html');
