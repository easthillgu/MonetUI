/**
 * N4 能力表闸门入口 —— 跑 tools/harness/capability-probe.lua。
 *
 * 为什么需要：`Compat:Capability` 是"模块判断这台客户端有没有 X"的唯一出口，
 * 而它的三种典型错（把"读不出"塌成"没有"、在受限窗口造探测框、重复造框）都是**行为**性质，
 * 静态 grep 看不见。这条探针把真 Compat.lua loadfile 进假环境，拿 CreateFrame 计数器与
 * 可变状态把三条纪律钉成断言。
 *
 * 用法：node tools/capability-probe.js  （或 LUA_BIN=... node tools/capability-probe.js）
 * 退出码：探针原样透传；找不到解释器 → 明确 1，绝不静默跳过。
 */

const path = require('path');
const { spawnSync } = require('child_process');

const PROBE = path.join(__dirname, 'harness', 'capability-probe.lua');

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
  console.error('[capability-probe] 找不到 Lua 解释器（设 LUA_BIN 指定）。判不了就失败退出 1。');
  process.exit(1);
}

const run = spawnSync(lua, [PROBE], { stdio: 'inherit' });
process.exit(run.status === null ? 1 : run.status);
