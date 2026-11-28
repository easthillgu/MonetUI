// keyfeeder-gate.js —— 施法成功技能图标反馈的离线闸门
//   node tools/keyfeeder-gate.js
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || '.';
const src = fs.readFileSync(path.join(root, 'Modules/Tools/KeyFeeder.lua'), 'utf8');
const toc = fs.readFileSync(path.join(root, 'Modules/Tools/Tools.xml'), 'utf8');
const core = fs.readFileSync(path.join(root, 'Core.lua'), 'utf8');
const cfg = fs.readFileSync(path.join(root, 'Config/SimpleConfig.lua'), 'utf8');

let bad = 0;
function check(label, ok) {
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} ${label}`);
}

console.log('=== keyfeeder 闸门 ===\n');
check('只在玩家成功施法时触发',
      /UNIT_SPELLCAST_SUCCEEDED/.test(src) && /unit ~= "player"/.test(src));
check('spellID 值级守卫（CanRead + Number，不当表键 / 不比较机密）',
      /Secrets\.CanRead\(spellID\)/.test(src) && /Secrets\.Number\(spellID\)/.test(src));
check('图标走 C_Spell.GetSpellTexture，拿不到就不画',
      /C_Spell\.GetSpellTexture/.test(src) && /if not ok or texture == nil then return end/.test(src));
check('渐隐时长 0.3s', /local FADE\s*=\s*0\.3/.test(src));
check('每帧驱动按需挂摘 + Profile 壳进 /mui perf',
      /Scheduler:EveryFrame/.test(src) && /Scheduler:Profile\("keyfeeder:fade"/.test(src)
      && /Scheduler:Unregister\(driverId\)/.test(src));
check('屏幕中央、自建框、不碰暴雪对象',
      /"CENTER", _G\.UIParent, "CENTER"/.test(src) && /Widget:CreateFrame/.test(src));
check('挂进 Tools.xml', /<Script file="KeyFeeder.lua"\/>/.test(toc));
check('默认模块表 + 配置面板有开关',
      /KeyFeeder\s*=\s*true/.test(core) && /KeyFeeder\s*=\s*"按键反馈"/.test(cfg)
      && /"KeyFeeder"/.test(cfg));

console.log('\n' + (bad === 0 ? '全部通过' : bad + ' 项未通过'));
process.exit(bad === 0 ? 0 : 1);
