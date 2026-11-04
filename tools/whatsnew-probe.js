/**
 * 更新提示（WhatsNew）行为闸门入口 —— 跑 tools/harness/whatsnew-probe.lua。
 *
 * 为什么需要：该模块的提示挂在 `C_Timer.After(3, …)` 上，harness 只 pump 1 秒 ⇒ `run.js red=0`
 * 对它是"没跑到"而不是"跑过没红"。这条探针 loadfile 真文件进假环境并手动触发那颗定时器，
 * 于是"只打一次 / 可重看 / 无记录时不编内容 / 拿不到版本不崩"都是真断言。
 *
 * 用法：node tools/whatsnew-probe.js  （或 LUA_BIN=... node tools/whatsnew-probe.js）
 * 退出码：探针原样透传；找不到解释器 → 明确失败 1，绝不静默跳过。
 */

const path = require('path');
const { spawnSync } = require('child_process');

const PROBE = path.join(__dirname, 'harness', 'whatsnew-probe.lua');

function findLua() {
  const cands = [];
  if (process.env.LUA_BIN) cands.push(process.env.LUA_BIN);
  cands.push('C:/Users/EastHillGu/AppData/Local/Programs/Lua/bin/lua.exe');
  cands.push('lua', 'lua5.1', 'lua54', 'luajit');
  for (const c of cands) {
    const r = spawnSync(c, ['-v'], { encoding: 'utf8' });
    if (r.status === 0 || (r.stderr && /Lua/i.test(r.stderr))) return c;
  }
  return null;
}

const lua = findLua();
if (!lua) {
  console.error('[whatsnew-probe] 找不到 Lua 解释器（设 LUA_BIN 指定）。判不了就失败退出 1，不静默跳过。');
  process.exit(1);
}

const run = spawnSync(lua, [PROBE], { stdio: 'inherit' });
process.exit(run.status === null ? 1 : run.status);
