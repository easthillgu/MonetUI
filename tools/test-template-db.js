#!/usr/bin/env node
/**
 * tools/test-template-db.js
 * 
 * 测试模板数据库加载和识别逻辑。
 * 
 * 用法：
 *   node tools/test-template-db.js
 */

const fs = require('fs');
const path = require('path');

// 模拟 WoW Lua 环境
const mockEnv = {
    ADDON_NAME: 'MonetUI',
    ns: {
        Skin: {},
        Mark: function() {},
        Marked: function() {},
    },
};

// 加载 TemplateDB.lua 并解析
function loadTemplateDB() {
    const dbPath = path.join(__dirname, '..', 'Modules', 'Skins', 'Templates', 'TemplateDB.lua');
    const content = fs.readFileSync(dbPath, 'utf8');
    
    // 简单的 Lua 表解析（只处理我们生成的格式）
    const templates = {};
    const templateRegex = /T\["([^"]+)"\]\s*=\s*\{([^}]+)\}/g;
    
    let match;
    while ((match = templateRegex.exec(content)) !== null) {
        const name = match[1];
        const body = match[2];
        
        const entry = {};
        
        // 提取字段
        const typeMatch = body.match(/type\s*=\s*"([^"]+)"/);
        if (typeMatch) entry.type = typeMatch[1];
        
        const inheritsMatch = body.match(/inherits\s*=\s*"([^"]+)"/);
        if (inheritsMatch) entry.inherits = inheritsMatch[1];
        
        const mixinMatch = body.match(/mixin\s*=\s*"([^"]+)"/);
        if (mixinMatch) entry.mixin = mixinMatch[1];
        
        const skinAsMatch = body.match(/skinAs\s*=\s*"([^"]+)"/);
        if (skinAsMatch) entry.skinAs = skinAsMatch[1];
        
        const camelotMatch = body.match(/camelotOnly\s*=\s*true/);
        if (camelotMatch) entry.camelotOnly = true;
        
        templates[name] = entry;
    }
    
    return templates;
}

// 测试函数
function runTests() {
    console.log('=== 模板数据库测试 ===\n');
    
    // 测试 1：加载数据库
    console.log('测试 1：加载 TemplateDB.lua');
    const db = loadTemplateDB();
    const count = Object.keys(db).length;
    console.log(`  ✓ 加载成功，${count} 个模板\n`);
    
    // 测试 2：检查关键模板
    console.log('测试 2：关键模板存在性');
    const critical = [
        'MoneyFrameTemplate',
        'ColoredProgressBarTemplate',
        'HybridScrollFrameTemplate',
        'UIPanelButtonTemplate',
        'InputBoxTemplate',
    ];
    
    for (const name of critical) {
        if (db[name]) {
            console.log(`  ✓ ${name} (${db[name].type}) -> ${db[name].skinAs || 'unmapped'}`);
        } else {
            console.log(`  ✗ ${name} 缺失`);
        }
    }
    console.log();
    
    // 测试 3：Camelot 覆盖
    console.log('测试 3：Camelot 覆盖');
    const camelot = Object.entries(db).filter(([_, v]) => v.camelotOnly);
    console.log(`  ✓ ${camelot.length} 个 Camelot 特有模板`);
    for (const [name, entry] of camelot) {
        console.log(`    - ${name} (${entry.type})`);
    }
    console.log();
    
    // 测试 4：skinAs 分布
    console.log('测试 4：skinAs 映射分布');
    const bySkinAs = {};
    for (const entry of Object.values(db)) {
        const key = entry.skinAs || 'unmapped';
        bySkinAs[key] = (bySkinAs[key] || 0) + 1;
    }
    
    const sorted = Object.entries(bySkinAs).sort((a, b) => b[1] - a[1]);
    for (const [skinAs, count] of sorted.slice(0, 10)) {
        console.log(`  ${skinAs}: ${count}`);
    }
    console.log();
    
    // 测试 5：类型分布
    console.log('测试 5：Frame 类型分布');
    const byType = {};
    for (const entry of Object.values(db)) {
        byType[entry.type] = (byType[entry.type] || 0) + 1;
    }
    
    const sortedTypes = Object.entries(byType).sort((a, b) => b[1] - a[1]);
    for (const [type, count] of sortedTypes) {
        console.log(`  ${type}: ${count}`);
    }
    console.log();
    
    console.log('=== 测试完成 ===');
}

runTests();
