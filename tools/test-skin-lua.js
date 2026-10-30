// Static checks for the skin layer that the game cannot tell us about offline.
//
// Everything here reads the Lua source and asserts a property that must hold. It exists because the
// defects it catches (a nil-method call that only fires on first use, a reversed gradient, a slider
// that never strips its trough) are all invisible until the player meets them in-game, and the game is
// not always online.
//
// Run: node tools/test-skin-lua.js
const fs = require('fs');
const path = require('path');

const linesOf = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8').split(/\r?\n/);
const srcOf = (p) => linesOf(p).join('\n');
const skin = srcOf('Utils/Skin.lua');
const widget = srcOf('Utils/Widget.lua');
const widgetLines = linesOf('Utils/Widget.lua');
const eventBus = srcOf('Utils/EventBus.lua');

// The skin *panel* files, concatenated: section 10 asserts the gap windows are actually wired up,
// and that means reading the per-window files, not just the dispatcher.
const skinPanelFiles = fs.readdirSync(path.join(__dirname, '..', 'Modules', 'Skins'))
  .filter(f => f.endsWith('.lua'));
const skinsFilesSrc = skinPanelFiles
  .map(f => srcOf(path.join('Modules', 'Skins', f)))
  .join('\n');
const skins = srcOf('Modules/Skins/Skins.lua');

let bad = 0;
function check(label, ok, detail) {
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} ${label}${detail ? '  —— ' + detail : ''}`);
}
function has(src, re, label) {
  const ok = re.test(src);
  check(label, ok, ok ? '' : '源码里找不到：' + re);
  return ok;
}
const lineOf = (src, re) => src.split('\n').findIndex(l => re.test(l)) + 1;

console.log('=== 皮肤层静态检查（离线可跑，代替等游戏上线）===\n');

// ---------------------------------------------------------------- 1
console.log('[1] 方法调用必须真有定义');
// Widget:Hairline 曾经调用 self:Track(tex)，而 Track 只定义在 Skin 上 —— 每次调用必崩。
// self:Hide / self:Show 等是 WoW API 的 Frame 方法，不是本文件的，排除掉。
const engine = new Set(['Hide', 'Show', 'SetScript', 'HookScript', 'GetObjectType', 'IsObjectType']);

// 只扫代码，不扫注释：注释里出现的 self:X 是解释性文字（比如"这里以前写的是 self:Track"），
// 当成调用会让这一节永远红。
const codeOnly = (src) => src.split('\n')
  .filter(l => !/^\s*--/.test(l))
  .join('\n');

function undefinedSelfCalls(src, methods) {
  const calls = [...codeOnly(src).matchAll(/\bself:(\w+)\(/g)].map(m => m[1]);
  return [...new Set(calls)].filter(n => !methods.includes(n) && !engine.has(n));
}
const widgetMethods = [...widget.matchAll(/function Widget:(\w+)\(/g)].map(m => m[1]);
const skinMethods = [...skin.matchAll(/function Skin:(\w+)\(/g)].map(m => m[1]);

const missingWidget = undefinedSelfCalls(widget, widgetMethods);
const missingSkin = undefinedSelfCalls(skin, skinMethods);
check(`Widget 的 self:X 全部有定义（缺失: ${missingWidget.join(',') || '无'}）`, missingWidget.length === 0);
check(`Skin 的 self:X 全部有定义（缺失: ${missingSkin.join(',') || '无'}）`, missingSkin.length === 0);
has(skin, /function Skin:ControlState\(/, '新加的 Skin:ControlState 已定义');
has(skin, /function Skin:UpdateTabState\(/, '新加的 Skin:UpdateTabState 已定义');
has(skins, /function M:Apply\b/, 'M:Apply 仍在（ControlState / RefreshThemes 依赖它）');
// 回归断言：注释里可以解释这段历史，但代码里不能再调用它。
check('Widget.lua 代码里没有 self:Track（只剩注释里解释这段历史）',
      !widgetLines.some(l => /self:Track\(/.test(l) && !/^\s*--/.test(l)));

// ---------------------------------------------------------------- 2
console.log('\n[2] 阴影渐变方向：贴近边框的一端必须是实色');
// SetGradient 的 minC 在 VERTICAL 底 / HORIZONTAL 左。四条 strip 里，贴近边框的端各在哪个位置，
// 决定了参数顺序。原来的 top/bot 传反了：阴影从边框处的 0 alpha 渐变到空中的 0.55 —— 变成光晕。
const stripCall = (name) => {
  const m = new RegExp(`local ${name} = Strip\\("(\\w+)", (\\w+), (\\w+)`).exec(widget);
  return m ? { orient: m[1], min: m[2], max: m[3] } : null;
};
const nearEnd = { top: 'min', bot: 'max', lef: 'max', rig: 'min' };
const expectOrient = { top: 'VERTICAL', bot: 'VERTICAL', lef: 'HORIZONTAL', rig: 'HORIZONTAL' };
for (const name of ['top', 'bot', 'lef', 'rig']) {
  const s = stripCall(name);
  if (!s) { check(`${name} strip 找得到`, false, 'Shadow 里没有这条 Strip 调用'); continue; }
  const got = s.min === 'near' ? 'min' : 'max';
  check(`${name}：贴近边框的一端是 near（当前 min=${s.min} max=${s.max}）`,
        got === nearEnd[name] && s.orient === expectOrient[name],
        `期望 ${expectOrient[name]}，near 落在 ${nearEnd[name]}`);
}

// ---------------------------------------------------------------- 3
console.log('\n[3] 控件皮肤必须剥掉暴雪原画');
// Skin:Slider 曾经是唯一不调 Strip 的控件 helper，暴雪蓝色滑轨整条留在 Monet 板下面。
const sliderBody = /function Skin:Slider\(([^)]*)\)([\s\S]*?)\nend/.exec(skin);
check('找得到 Skin:Slider', !!sliderBody);
if (sliderBody) {
  const body = sliderBody[0];
  check('Skin:Slider 调用了 Strip', /self:Strip\(/.test(body));
  check('thumb 在 Strip 之前取出（否则会被 Strip 一起淡掉）',
        body.indexOf('GetThumbTexture') > -1 && body.indexOf('GetThumbTexture') < body.indexOf('self:Strip('),
        `thumb@${body.indexOf('GetThumbTexture')} Strip@${body.indexOf('self:Strip(')}`);
  check('Strip 用 keepTexture 保住了 thumb', /keepTexture\s*=\s*thumb/.test(body));
  check('贴图切换走 SwapArt（可回滚），不是裸 SetTexture',
        /self:SwapArt\(thumb/.test(body) && !/pcall\(thumb\.SetTexture/.test(body));
}

// ---------------------------------------------------------------- 4
console.log('\n[4] Tab 必须表达选中态');
// Strip 会淡掉 SelectedTexture，所以下划线是唯一的状态载体，必须跟着 IsSelected 走。
has(skin, /IsSelected/, '读 tab:IsSelected()');
has(skin, /PanelTemplates_SelectTab/, '挂了 PanelTemplates_SelectTab / DeselectTab');
has(skin, /Media:SnapUnit\(2\)/, '下划线高度走 SnapUnit（裸 2 单位在 0.71 缩放下变 1.42px，会发虚）');
const tabBody = /function Skin:Tab\(([^)]*)\)([\s\S]*?)\nend/.exec(skin);
check('Skin:Tab 每次应用都刷新状态', tabBody && /self:UpdateTabState\(tab\)/.test(tabBody[0]));

// ---------------------------------------------------------------- 5
console.log('\n[5] RadioButton 不能被当成 CheckButton');
// GetObjectType 对 radio 返回 "RadioButton"；不单独分支的话每个单选钮都会拿到勾号。
has(skin, /function Skin:RadioButton\(/, 'Skin:RadioButton 已定义');
has(skins, /Skin:RadioButton\(button/, 'M:Buttons 分派 RadioButton');
has(skins, /Skin:RadioButton\(child/, 'M:SkinButtonsIn 分派 RadioButton');
has(skin, /SwapArt\(checked, "monet_radio"\)/, '用的是 monet_radio（monet_check 会画成勾）');

// ---------------------------------------------------------------- 6
console.log('\n[6] 缩放变化必须重建边框几何');
// edgeSize / inset 全部由 Media:Mult()（读 uiScale CVar）推导，之前没有任何地方监听 UI_SCALE_CHANGED。
has(widget, /function Widget:ApplyBackdrop\(/, 'ApplyBackdrop 已从 Theme 里拆出');
has(widget, /ApplyBackdrop\(frame, opts\)/, 'ApplyBackdrop 至少被 Theme 调一次');
has(widget, /function Widget:RefreshThemes\(rescale\)/, 'RefreshThemes 接受 rescale');
has(skins, /"UI_SCALE_CHANGED"/, 'Skins 监听 UI_SCALE_CHANGED');
has(skins, /Widget:RefreshThemes\(true\)/, '缩放变化带着 rescale=true 重建边框');
check('Theme 不再自己算 edgeSize（已移交 ApplyBackdrop）',
      !/function Widget:Theme[\s\S]*?edgeSize = opts\.thickness/.test(widget));

// ---------------------------------------------------------------- 7
console.log('\n[7] 失败只报一次，不刷屏');
has(eventBus, /local reported\s*=\s*\{\}/, 'EventBus 有 reported 表');
has(eventBus, /if n == 1 then/, 'EventBus 只在首次失败时 print');
check('EventBus 的 print 在首次判断之内', /if n == 1 then[\s\S]{0,200}print\(/.test(eventBus));
has(skins, /__applyFailed/, 'M:Apply 记住已失败的面板');
check('失败 print 在 __applyFailed 判断之内', /if not entry\.__applyFailed then[\s\S]{0,240}Print\(/.test(skins));

// ---------------------------------------------------------------- 8
console.log('\n[8] 按下 / 禁用态必须有表现');
has(skin, /HookScript\("OnDown"/, 'OnDown 用 HookScript（SetScript 会吃掉暴雪的点击脚本）');
has(skin, /HookScript\("OnUp"/, 'OnUp 用 HookScript');
has(skin, /hooksecurefunc\(control, "Enable"/, 'Enable/Disable 被 hook（暴雪切状态不经过任何脚本）');
check('ControlState 从不在 Skin:Button 里被跳过',
      /function Skin:Button[\s\S]{0,1200}self:ControlState\(/.test(skin));
check('ControlState 从不在 Skin:CheckButton 里被跳过',
      /function Skin:CheckButton[\s\S]{0,2500}self:ControlState\(/.test(skin));

// ---------------------------------------------------------------- 9
console.log('\n[9] 控件尺寸一律走 SnapUnit');
// Widget.lua 自己的注释：所有交给引擎的尺寸都走 Size/Width/Height，裸尺寸就是漏出像素网格的尺寸。
// 唯一的例外是阴影的四条 strip：reach 是"离边框多远"，由 opts.reach（物理像素）推导，
// 它不是控件尺寸，跟着缩放走反而会把阴影范围改变。这四条单独放行，且理由写在这里。
const shadowReachLines = new Set();
widgetLines.forEach((l, i) => {
  if (/^\s*(top|bot|lef|rig):Set(Height|Width)\(reach\)/.test(l)) shadowReachLines.add(i);
});
check('阴影四条 strip 仍然是 reach（D9 的唯一例外）', shadowReachLines.size === 4,
      `找到 ${shadowReachLines.size} 条`);

const offenders = [];
widgetLines.forEach((l, i) => {
  const m = /(\w+):Set(Size|Width|Height)\(([^)]*)\)/.exec(l);
  if (!m) return;
  if (/^\s*--/.test(l)) return;                       // 注释
  if (shadowReachLines.has(i)) return;               // 阴影 reach，见上
  const [, obj, , args] = m;
  if (obj === 'frame') return;                       // Size/Width/Height 的本体
  // 扫整行而不是参数：`(opts.height or 9) * Media:Mult()` 的参数在第一个 ')' 就断了，
  // 只看 args 会漏掉这个已经按物理像素换算过的写法。
  if (/SnapUnit|Media:Mult/.test(l)) return;
  offenders.push(`L${i + 1} ${l.trim()}`);
});
check(`Widget.lua 的 SetSize/Width/Height 都已吸附（发现: ${offenders.join(' ; ') || '无'}）`,
      offenders.length === 0);

// ---------------------------------------------------------------- 10
console.log('\n[10] 缺口窗口必须真的接上了');
// 这几个窗口此前完全没有 handler：ItemRefTooltip / TradeFrame / EditModeManager / ChatFrame /
// SpellBook / ObjectiveTracker。名字进了 frames 名单不等于皮肤碰了它，所以断言有实际取用路径。
const registered = [...skinsFilesSrc.matchAll(/M:Panel\("(\w+)"/g)].map(m => m[1]);
const required = {
  trade:          ['TradeFrame', 'AcceptTradeButton', 'CancelTradeButton'],
  editmode:       ['EditModeManager', 'EditModeSystemSettingsDialog'],
  chat:           ['ChatFrame1', 'ChatFrame1EditBox', 'ChatChannelManagerPopup'],
  playerspells:   ['PlayerSpellsFrame', 'SpellBookFrame', 'PlayerSpellsTab1'],
  objectivetracker: ['ObjectiveTrackerFrame', 'ObjectiveTrackerHeader'],
  tooltip:        ['ItemRefTooltip'],
};
for (const [key, names] of Object.entries(required)) {
  check(`面板 ${key} 已注册`, registered.includes(key),
        registered.includes(key) ? '' : '已注册的有: ' + registered.join(', '));
  const missing = names.filter(n => !skinsFilesSrc.includes(`"${n}"`));
  check(`面板 ${key} 引用了 ${names.length} 个窗口（缺: ${missing.join(',') || '无'}）`, missing.length === 0);
}
// 邮件滚动框曾经把子窗口 InboxFrame 直接当滚动框传进 Skin:ScrollFrame —— 拿不到 ScrollBar 成员，
// 函数静默返回，邮件列表的滚动条从来没被换过。
has(skinsFilesSrc, /frame\.MailListScrollFrame/, '邮件滚动框走正确成员名');
check('Skin:ScrollFrame 不再直接收 frame.InboxFrame（那是子窗口不是滚动框）',
      !/Skin:ScrollFrame\(frame\.InboxFrame\s+or/.test(skinsFilesSrc));

// ---------------------------------------------------------------- 11
console.log('\n[11] IsMouseOver 必须走守卫');
// 客户端把 IsMouseOver 的返回值标为 SecretWhenAnchoringSecret：锚定机密时返回**机密布尔**，
// 而 `not secret` / `secret and x` 都会报错。pcall 救不了 —— 调用成功、只是结果机密。
// 所以全项目只允许 Widget:IsMouseOver 一个入口。
has(widget, /function Widget:IsMouseOver\(/, 'Widget:IsMouseOver 已定义');
check('守卫先测机密、后做比较（顺序反了 value == nil 自己就会报错）',
      /issecretvalue\(value\)[\s\S]{0,160}value == nil/.test(widget));
const bareMouseOver = [];
for (const f of ['Utils/Widget.lua', 'Utils/Skin.lua', 'Modules/UnitFrames/UnitFrames.lua']) {
  linesOf(f).forEach((l, i) => {
    if (/^\s*--/.test(l)) return;
    if (/(?<![\w:.])[\w.]+:IsMouseOver\(/.test(l) && !/Widget:IsMouseOver/.test(l)) {
      bareMouseOver.push(`${f}:${i + 1} ${l.trim()}`);
    }
  });
}
check(`没有裸 IsMouseOver 调用（发现: ${bareMouseOver.join(' ; ') || '无'}）`, bareMouseOver.length === 0);

// ---------------------------------------------------------------- 12
console.log('\n[12] 发丝线必须做纹素吸附');
// 单行不透明贴图,放在半纹素位置就只是糊。动画填充相反（吸附会让进度条一像素一像素地跳），
// 所以这是逐贴图设置,不是全局开关。
const hairBody = /function Widget:Hairline[\s\S]*?\nend/.exec(widget);
check('Widget:Hairline 打开了 SetSnapToPixelGrid', hairBody && /SetSnapToPixelGrid, tex, true/.test(hairBody[0]));

// ---------------------------------------------------------------- 13
console.log('\n[13] 目标光环走 B 方案（原生 AuraContainer），A 方案必须可回滚');
// A 方案（借 TargetFrame 的光环子帧）超的是一整段代码，回滚就是「删掉块注释的两个标记」，
// 所以这里守的不变量是：A 段完整躺在注释里、注释外没有活引用、B 段的硬约束都还在。
const ufLines = linesOf('Modules/UnitFrames/UnitFrames.lua');
const uf = ufLines.join('\n');
const openAt = ufLines.findIndex(l => l.trim() === '--[==[');
const closeAt = ufLines.findIndex(l => l.trim() === ']==]');

check('A 方案的块注释成对', openAt >= 0 && closeAt > openAt, `open=${openAt + 1} close=${closeAt + 1}`);
check('块注释内没有提前出现 ]==]',
      openAt >= 0 && closeAt > openAt && ufLines.slice(openAt + 1, closeAt).every(l => !l.includes(']==]')));

// A 段的每一根骨头都还在注释范围内
for (const marker of ['TARGET_AURA_CHILDREN', 'local function AuraChild', 'local function StackTargetAuras',
                      'local function BorrowTargetAuras', 'function RestoreTargetAuras', 'local function HookAuraRelayout']) {
  const at = ufLines.findIndex(l => l.includes(marker));
  check(`A 的 ${marker} 完整保留在注释里`, at > openAt && at < closeAt, `L${at + 1}`);
}

// 注释之外不许再有活引用，否则删注释回滚会立刻撞上重复定义 / 未定义
const liveRefs = [];
ufLines.forEach((l, i) => {
  if (i > openAt && i < closeAt) return;
  if (/^\s*--/.test(l)) return;
  for (const name of ['BorrowTargetAuras', 'RestoreTargetAuras', 'StackTargetAuras',
                      'HookAuraRelayout', 'blizzardAuras', 'TARGET_AURA_CHILDREN']) {
    if (new RegExp(`\\b${name}\\b`).test(l)) liveRefs.push(`L${i + 1} ${name}`);
  }
});
check(`A 的函数在注释外零引用（发现: ${liveRefs.join(', ') || '无'}）`, liveRefs.length === 0);
check('RefreshUnit 调的是 EnsureTargetAuras', /if unit == "target" then EnsureTargetAuras\(frame\) end/.test(uf));

// B 方案的硬约束（每一条都是 EllesmereUI 在同一个客户端上踩出来的）
const liveUf = ufLines.filter((_, i) => !(i > openAt && i < closeAt)).join('\n');
for (const [label, re] of Object.entries({
  '先 LoadAddOn Blizzard_AuraContainer': /LoadAddOn[\s\S]{0,40}Blizzard_AuraContainer/,
  'CreateFrame AuraContainer + CustomAuraContainerTemplate': /CreateFrame, "AuraContainer", nil, parent, "CustomAuraContainerTemplate"/,
  '建容器先给可渲染矩形 SetSize(1,1)': /container:SetSize\(1, 1\)/,
  'AddAuraGroup 传 initializeFrame': /AddAuraGroup, container, key, filterString, opts/,
  'SetUnit + UpdateAllAuras': /SetUnit, container, "target"[\s\S]{0,120}UpdateAllAuras, container/,
  '关掉引擎按钮的点击（否则吃掉换目标）': /SetMouseClickEnabled, button, false/,
  '字体在 SetApplicationCount 之前': /SetFont\(stack[\s\S]{0,700}SetApplicationCount/,
  '两代 Flow/AuraLayout setter 兜底': /FlowCall\(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint"/,
  '主题变化重涂引擎按钮': /MONETUI_THEME_CHANGED[\s\S]{0,220}TintTargetAuras\(\)/,
})) check(label, re.test(liveUf));

// ---------------------------------------------------------------- 14
console.log('\n[14] 姓名板 debuff 图标走 B1（借来打补丁）');
// 姓名板的减益图标是借 Blizzard 的 AurasFrame 画的，原先只设锚点、一点样式都没碰。
// B1 只做三件低风险的事，且不依赖暴雪内部成员名（这个 fork 的字段名离线查不到）。
const np = srcOf('Modules/Nameplates/Nameplates.lua');
for (const [label, re] of Object.entries({
  'DressDebuffButton 已定义':            /local function DressDebuffButton\(button\)/,
  'DressDebuffList 已定义':              /local function DressDebuffList\(list\)/,
  'AnchorDebuffs 里真的调用了':           /pcall\(list\.SetPoint, list, "BOTTOMLEFT"[\s\S]{0,220}DressDebuffList\(list\)/,
  '每个按钮额外挂 OnShow（池化复用）':      /HookScript, child, "OnShow"/,
  '边框是我们自己建的 OVERLAY 贴图':       /CreateTexture\(nil, "OVERLAY"\)/,
  '暴雪边框按名字优先、几何兜底':          /TextureOf\(button, "Border", "DebuffBorder"[\s\S]{0,1500}rw > bw \+ 0\.5/,
  '图标按名字优先、几何兜底':              /TextureOf\(button, "Icon", "icon"[\s\S]{0,900}rw >= bw - 0\.5/,
  '图标裁边（和施法图标同比例）':           /icon\.SetTexCoord, icon, DEBUFF_ICON_CROP/,
  '驱散色：读 GetVertexColor 后复用':      /GetVertexColor, stock[\s\S]{0,1400}SetColorTexture, bd, sr, sg, sb/,
  '一律淡掉暴雪厚边框':                    /if stock then\s*\n\s*pcall\(stock\.SetAlpha, stock, 0\)/,
  '读不到颜色时退回主题边框色':            /if not sr then\s*\n\s*sr, sg, sb = Color:GetBorder\(\)/,
  '边框来源记进 d.borderSource（实机可查）': /d\.borderSource = "dispel"[\s\S]{0,300}d\.borderSource = "theme"/,
  '冷却关描边、保留扫圈':                  /SetDrawEdge, c, false[\s\S]{0,90}SetDrawSwipe, c, true/,
  '字号跟着图标高度走':                    /bh \* 0\.42/,
  '字体换成 pixel 数字体':                /SetFont, Widget, d\.fonts\[i\], d\.size, "cooldown"/,
  '字体每次重设（回收会写回）':            /for i = 1, #d\.fonts do[\s\S]{0,140}SetFont/,
  '文字只收 FontString，不碰贴图':          /GetObjectType\(\) == "FontString"/,
})) check(label, re.test(np));

// 绝不能出现：改图标贴图 / 重锚文字（会和暴雪每帧重设打架）
check('没有对 borrowed 按钮 SetTexture（图标归游戏）',
      !/button:SetTexture|button\.Icon:SetTexture/.test(np));
check('没有给 debuff 的 FontString ClearAllPoints（会和暴雪重锚打架）',
      !/pcall\(r\.ClearAllPoints, r\)/.test(np));
check('diagnose 会打印已修饰按钮数', /已修饰的 debuff 按钮：%d 个/.test(np));

console.log('\n' + (bad === 0 ? '全部通过' : bad + ' 项未通过'));
process.exit(bad === 0 ? 0 : 1);