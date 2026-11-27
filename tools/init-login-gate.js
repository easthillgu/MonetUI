// init-login-gate.js —— 异步初始化的登录事件防护
//   node tools/init-login-gate.js
// PLAYER_LOGIN 只派发一次，StartModules 被 Init:Run 切到后续帧。模块在 Initialize 里
// 自己订阅 PLAYER_LOGIN 必然错过；统一走 Core 的 ns:OnLogin(fn)。
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || '.';
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.lua')) files.push(p);
  }
})(path.join(root, 'Modules'));

let bad = 0;
function check(label, ok, detail) {
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} ${label}${detail ? '  —— ' + detail : ''}`);
}

console.log('=== 异步启动 / PLAYER_LOGIN 闸门 ===\n');
const core = fs.readFileSync(path.join(root, 'Core.lua'), 'utf8');
check('Core 定义了 ns:OnLogin', /function ns:OnLogin\(fn\)/.test(core));
check('Core 在登录派发时标记 loginDispatched = true', /ns\.loginDispatched = true/.test(core));
check('Core 初始 loginDispatched = false', /ns\.loginDispatched = false/.test(core));
check('OnLogin 在事件已过时立即补跑', /if self\.loginDispatched then[\s\S]*?pcall\(fn\)/.test(core));
check('OnLogin 是一次性订阅（自行 Unregister）',
  /Unregister, ns\.EventBus, "PLAYER_LOGIN", once/.test(core));

const offenders = [];
for (const f of files) {
  const rel = path.relative(root, f).replace(/\\/g, '/');
  fs.readFileSync(f, 'utf8').split(/\r?\n/).forEach((l, i) => {
    if (/^\s*--/.test(l)) return;
    if (/EventBus:Register\(\s*["']PLAYER_LOGIN["']/.test(l) ||
        /RegisterEvent\(\s*["']PLAYER_LOGIN["']/.test(l)) {
      offenders.push(rel + ':' + (i + 1) + '  ' + l.trim().slice(0, 100));
    }
  });
}
check('模块里没有直接订阅 PLAYER_LOGIN', offenders.length === 0, offenders.join('\n') || '无');

console.log('\n' + (bad === 0 ? '全部通过' : bad + ' 项未通过'));
process.exit(bad === 0 ? 0 : 1);
