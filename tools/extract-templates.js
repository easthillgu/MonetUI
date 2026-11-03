#!/usr/bin/env node
/**
 * tools/extract-templates.js
 * 
 * 从 FrameXML 源文件提取界面模板定义，生成 MonetUI 的模板数据库。
 * 
 * 用法：
 *   node tools/extract-templates.js                          # 默认：framexml-source
 *   node tools/extract-templates.js --source <path>          # 自定义 FrameXML 源目录
 *   node tools/extract-templates.js --out <path>             # 输出位置
 *   node tools/extract-templates.js --audit                  # 只打印统计，不写文件
 * 
 * 输入：Gethe/wow-ui-source forever 分支（或本地 CASC 提取的 Interface/）
 * 输出：Modules/Skins/Templates/TemplateDB.lua
 */

const fs = require('fs');
const path = require('path');

// 配置
const DEFAULT_SOURCE = path.join(__dirname, '..', 'framexml-source', 'Interface', 'AddOns');
const DEFAULT_OUTPUT = path.join(__dirname, '..', 'Modules', 'Skins', 'Templates', 'TemplateDB.lua');

// 需要扫描的暴雪插件目录
const BLIZZARD_ADDONS = [
    'Blizzard_SharedXML',
    'Blizzard_SharedXMLBase',
    'Blizzard_SharedXMLGame',
    'Blizzard_FrameXML',
    'Blizzard_FrameXMLBase',
    'Blizzard_FrameXMLUtil',
    'Blizzard_MoneyFrame',
];

// skinAs 映射表：模板名 -> 识别类型
const SKIN_AS_MAP = {
    // 金币类
    'MoneyFrameTemplate': 'money',
    'MoneyDisplayFrameTemplate': 'money',
    'LargeMoneyFrameTemplate': 'money',
    'SmallMoneyFrameTemplate': 'money',
    'MoneyInputFrameTemplate': 'moneyinput',
    
    // 进度条类
    'ColoredProgressBarTemplate': 'coloredbar',
    'StatusBarTemplate': 'statusbar',
    
    // 滚动条类
    'HybridScrollFrameTemplate': 'scroll',
    'BasicHybridScrollFrameTemplate': 'scroll',
    'UIPanelScrollBarTemplate': 'scroll',
    'ScrollFrameTemplate': 'scroll',
    'ScrollBoxTemplate': 'scrollbox',
    
    // 按钮类
    'UIPanelButtonTemplate': 'button',
    'UIPanelButtonNoTooltipTemplate': 'button',
    'UIPanelCloseButton': 'closebutton',
    'SelectableButtonTemplate': 'selectable',
    
    // 标签类
    'PanelTabButtonTemplate': 'tab',
    'CharacterFrameTabButtonTemplate': 'tab',
    
    // 输入框类
    'InputBoxTemplate': 'editbox',
    'SearchBoxTemplate': 'editbox',
    'LargeMoneyInputBoxTemplate': 'editbox',
    'EditBoxTemplate': 'editbox',
    
    // 复选框类
    'UICheckButtonTemplate': 'checkbox',
    'UIRadioButtonTemplate': 'radio',
    'CheckBoxTemplate': 'checkbox',
    
    // 滑块类
    'UISliderTemplate': 'slider',
    'SliderTemplate': 'slider',
    
    // 下拉菜单类
    'UIDropDownMenuTemplate': 'dropdown',
    'WowStyle1DropdownTemplate': 'dropdown',
    
    // 九宫格类
    'NineSlicePanelTemplate': 'nineslice',
    'UIPanelDialogTemplate': 'nineslice',
    
    // 列表类
    'TemplatedListTemplate': 'templatelist',
    'ListTemplate': 'templatelist',
    'PagedListTemplate': 'pagedlist',
    
    // 属性控件类
    'PropertyButtonTemplate': 'propertybutton',
    'PropertySliderTemplate': 'slider',
    'PropertyFontStringTemplate': 'label',
    
    // 其他
    'SpinnerTemplate': 'spinner',
    'CollapseButtonTemplate': 'checkbox',
    'BulletPointTemplate': 'bullet',
};

/**
 * 从 XML 文件中提取模板定义
 */
function extractTemplatesFromXML(xmlContent, filePath) {
    const templates = [];
    
    // 匹配模板声明：<Button/Frame/ScrollFrame virtual="true" name="XTemplate" ...>
    // WoW FrameXML 使用多种标签类型
    const templateRegex = /<(Button|Frame|ScrollFrame|Slider|EditBox|StatusBar|CheckButton|RadioButton|ModelFrame|PlayerModelFrame|DressUpModelSceneMixinTemplate)\s+([^>]*?)>/g;
    
    let match;
    while ((match = templateRegex.exec(xmlContent)) !== null) {
        const tagType = match[1];
        const attrs = match[2];
        
        // 提取关键属性
        const nameMatch = attrs.match(/name="([^"]+)"/);
        const virtualMatch = attrs.match(/virtual="([^"]+)"/);
        const inheritsMatch = attrs.match(/inherits="([^"]+)"/);
        const mixinMatch = attrs.match(/mixin="([^"]+)"/);
        
        // 只处理模板（virtual="true" 或名字以 Template 结尾）
        const name = nameMatch ? nameMatch[1] : null;
        const isVirtual = virtualMatch && virtualMatch[1] === 'true';
        const isTemplate = name && (name.endsWith('Template') || name.endsWith('Template'));
        
        if (!name || (!isVirtual && !isTemplate)) continue;
        
        // 提取 parentKey 子节点
        const parentKeys = [];
        const parentKeyRegex = /parentKey="([^"]+)"/g;
        let pkMatch;
        while ((pkMatch = parentKeyRegex.exec(attrs)) !== null) {
            parentKeys.push(pkMatch[1]);
        }
        
        // 检测是否来自 Camelot 目录
        const isCamelot = filePath.includes('/Camelot/') || filePath.includes('\\Camelot\\');
        
        templates.push({
            name,
            type: tagType,
            inherits: inheritsMatch ? inheritsMatch[1] : null,
            mixin: mixinMatch ? mixinMatch[1] : null,
            parentKeys,
            source: filePath,
            isCamelot,
            skinAs: SKIN_AS_MAP[name] || null,
        });
    }
    
    return templates;
}

/**
 * 递归扫描目录下的所有 XML 文件
 */
function scanDirectory(dir, extensions = ['.xml']) {
    const results = [];
    
    if (!fs.existsSync(dir)) return results;
    
    const items = fs.readdirSync(dir, { withFileTypes: true });
    
    for (const item of items) {
        const fullPath = path.join(dir, item.name);
        
        if (item.isDirectory()) {
            results.push(...scanDirectory(fullPath, extensions));
        } else if (extensions.some(ext => item.name.endsWith(ext))) {
            try {
                const content = fs.readFileSync(fullPath, 'utf8');
                results.push({ path: fullPath, content });
            } catch (err) {
                console.error(`读取文件失败: ${fullPath}`, err.message);
            }
        }
    }
    
    return results;
}

/**
 * 生成 Lua 表源码
 */
function generateLuaSource(templates, sourceInfo) {
    const lines = [
        '-- Modules/Skins/Templates/TemplateDB.lua',
        '-- AUTO-GENERATED by tools/extract-templates.js -- DO NOT EDIT BY HAND',
        `-- Source: ${sourceInfo}`,
        `-- Generated: ${new Date().toISOString()}`,
        `-- Templates: ${templates.length}`,
        '--',
        '-- 每个条目：模板名 -> { type, inherits, mixin, fingerprints, skinAs, source }',
        '',
        'local ADDON_NAME, ns = ...',
        'local T = {}',
        '',
    ];
    
    // 按 skinAs 分组输出
    const grouped = {};
    for (const tpl of templates) {
        const key = tpl.skinAs || 'unmapped';
        if (!grouped[key]) grouped[key] = [];
        grouped[key].push(tpl);
    }
    
    // 输出已映射的模板
    for (const [skinAs, group] of Object.entries(grouped)) {
        if (skinAs === 'unmapped') continue;
        
        lines.push(`-- =========================================================================`);
        lines.push(`-- ${skinAs} 类 (${group.length} 个模板)`);
        lines.push(`-- =========================================================================`);
        lines.push('');
        
        for (const tpl of group) {
            lines.push(`T["${tpl.name}"] = {`);
            lines.push(`    type = "${tpl.type}",`);
            if (tpl.inherits) lines.push(`    inherits = "${tpl.inherits}",`);
            if (tpl.mixin) lines.push(`    mixin = "${tpl.mixin}",`);
            if (tpl.isCamelot) lines.push(`    camelotOnly = true,`);
            lines.push(`    source = "${path.basename(tpl.source)}",`);
            
            // 生成指纹
            const fingerprints = generateFingerprints(tpl);
            if (fingerprints.length > 0) {
                lines.push(`    fingerprints = {`);
                for (const fp of fingerprints) {
                    lines.push(`        { kind = "${fp.kind}", path = "${fp.path}" },`);
                }
                lines.push(`    },`);
            }
            
            lines.push(`    skinAs = "${tpl.skinAs}",`);
            lines.push(`}`);
            lines.push('');
        }
    }
    
    // 输出未映射的模板（作为参考）
    if (grouped.unmapped && grouped.unmapped.length > 0) {
        lines.push(`-- =========================================================================`);
        lines.push(`-- 未映射模板 (${grouped.unmapped.length} 个)`);
        lines.push(`-- =========================================================================`);
        lines.push('');
        
        for (const tpl of grouped.unmapped) {
            lines.push(`-- T["${tpl.name}"] = { type = "${tpl.type}", source = "${path.basename(tpl.source)}" }`);
        }
        lines.push('');
    }
    
    // 注册到 ns 命名空间
    lines.push('-- 注册到插件命名空间');
    lines.push('ns.TemplateDB = T');
    lines.push('');
    lines.push('return T');
    
    return lines.join('\n');
}

/**
 * 为模板生成运行时指纹
 */
function generateFingerprints(tpl) {
    const fps = [];
    
    // 基于 mixin 生成方法检查
    if (tpl.mixin) {
        // 常见 mixin 的标志性方法
        const mixinMethods = {
            'ColoredProgressBarMixin': ['SetFill'],
            'MoneyDisplayFrameMixin': ['SetMoney'],
            'HybridScrollFrameMixin': ['Update'],
            'ScrollBoxMixin': ['ScrollToBegin'],
            'NineSlicePanelMixin': ['SetupNineSlice'],
            'UIPanelButtonBaseMixin': ['SetText'],
            'SelectableButtonMixin': ['SetSelected'],
            'TemplatedListMixin': ['SetTemplate'],
            'PropertyButtonMixin': ['SetValue'],
        };
        
        const methods = mixinMethods[tpl.mixin];
        if (methods) {
            for (const method of methods) {
                fps.push({ kind: 'method', path: method });
            }
        }
    }
    
    // 基于 parentKey 生成字段检查
    for (const key of tpl.parentKeys) {
        fps.push({ kind: 'field', path: key });
    }
    
    // 基于继承链生成检查
    if (tpl.inherits) {
        // 常见父模板的标志性字段
        const inheritFields = {
            'MoneyFrameTemplate': ['moneyType'],
            'ColoredProgressBarTemplate': ['Fill', 'Mask'],
            'HybridScrollFrameTemplate': ['scrollChild'],
            'NineSlicePanelTemplate': ['NineSlice'],
        };
        
        const fields = inheritFields[tpl.inherits];
        if (fields) {
            for (const field of fields) {
                // 避免重复
                if (!fps.some(fp => fp.path === field)) {
                    fps.push({ kind: 'field', path: field });
                }
            }
        }
    }
    
    return fps;
}

/**
 * 主函数
 */
function main() {
    const args = process.argv.slice(2);
    
    // 解析参数
    let sourceDir = DEFAULT_SOURCE;
    let outputFile = DEFAULT_OUTPUT;
    let auditOnly = false;
    
    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--source' && args[i + 1]) {
            sourceDir = path.resolve(args[++i]);
        } else if (args[i] === '--out' && args[i + 1]) {
            outputFile = path.resolve(args[++i]);
        } else if (args[i] === '--audit') {
            auditOnly = true;
        }
    }
    
    console.log(`扫描目录: ${sourceDir}`);
    
    // 扫描所有暴雪插件目录
    const allTemplates = [];
    const sourceInfo = [];
    
    for (const addon of BLIZZARD_ADDONS) {
        const addonDir = path.join(sourceDir, addon);
        if (!fs.existsSync(addonDir)) {
            console.warn(`目录不存在，跳过: ${addonDir}`);
            continue;
        }
        
        console.log(`处理: ${addon}`);
        const xmlFiles = scanDirectory(addonDir, ['.xml']);
        
        for (const file of xmlFiles) {
            const templates = extractTemplatesFromXML(file.content, file.path);
            allTemplates.push(...templates);
        }
        
        sourceInfo.push(`${addon} (${xmlFiles.length} files)`);
    }
    
    // 去重（同名模板保留 Camelot 版本）
    const uniqueTemplates = new Map();
    for (const tpl of allTemplates) {
        const existing = uniqueTemplates.get(tpl.name);
        if (!existing || tpl.isCamelot) {
            uniqueTemplates.set(tpl.name, tpl);
        }
    }
    
    const templates = Array.from(uniqueTemplates.values());
    
    // 统计
    const mapped = templates.filter(t => t.skinAs);
    const camelot = templates.filter(t => t.isCamelot);
    
    console.log('\n=== 统计 ===');
    console.log(`总模板数: ${templates.length}`);
    console.log(`已映射 skinAs: ${mapped.length}`);
    console.log(`Camelot 覆盖: ${camelot.length}`);
    console.log(`源信息: ${sourceInfo.join(', ')}`);
    
    if (auditOnly) {
        console.log('\n=== 前 20 个模板示例 ===');
        for (const tpl of templates.slice(0, 20)) {
            console.log(`  ${tpl.name} (${tpl.type}) -> ${tpl.skinAs || 'unmapped'}`);
        }
        return;
    }
    
    // 生成 Lua 源码
    const luaSource = generateLuaSource(templates, sourceInfo.join('; '));
    
    // 确保输出目录存在
    const outputDir = path.dirname(outputFile);
    if (!fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }
    
    // 写入文件
    fs.writeFileSync(outputFile, luaSource, 'utf8');
    console.log(`\n已写入: ${outputFile}`);
}

main();
