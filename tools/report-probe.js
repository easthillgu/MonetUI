/**
 * `/mui report` 行为闸门入口 —— 跑 tools/harness/report-probe.lua 那套断言。
 *
 * 为什么需要：harness 的替身世界**不调斜杠命令**，所以 `run.js` 的红 0 只能证明 Report.lua 被加载、
 * 里面的 C_* 名字对得上快照，证明不了"报告打得出来"。这条探针把**发行码原文件**loadfile 进假环境
 * （假 ns / Secrets / Skin / C_Map / C_AddOns，并让角色名·地图名·坐标·插件标题都"带密"），
 * 于是能真的判：段落齐不齐、机密值有没有被拼进输出、账本有没有落、DB 打不开/战斗中会不会崩。
 *
 * 它已经抓到过一个真 bug：`table.concat(names, ", ", 1, 6)` 在缺失名不足 6 项时撞 nil ——
 * 明早第一次 `/mui report` 就会红在那里。
 *
 * 用法：node tools/report-probe.js
 *      （或 LUA_BIN=C:\path\to\lua.exe node tools/report-probe.js）
 * 退出码：探针原样透传（全过 0，任一失败 1，找不到解释器 1 —— 绝不静默跳过）。
 */

const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PROBE = path.join(__dirname, 'harness', 'report-probe.lua');

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
  console.error('[report-probe] 找不到 Lua 解释器（设 LUA_BIN 指定）。这条闸门判不了，明确失败退出 1。');
  process.exit(1);
}

const run = spawnSync(lua, [PROBE], { stdio: 'inherit' });
process.exit(run.status === null ? 1 : run.status);
