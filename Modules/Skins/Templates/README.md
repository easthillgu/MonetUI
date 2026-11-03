# Modules/Skins/Templates/

从 WoW Forever 客户端（Interface 16001）的 FrameXML 源文件提取的界面模板数据库。

## 背景

MonetUI 的模板识别系统（`Utils/SkinTemplates.lua` 的 `Skin:Recognize()`）原本只能通过运行时结构指纹识别 8 种控件类型。本模块通过提取暴雪 FrameXML 的模板定义，建立了包含 **387 个模板**的数据库。

> **运行时实际加载的只有 32 条**（映射到 skinAs 的那些）；其余 355 条在生成文件里以注释保留。
> 而且这 32 条里**只有 5 条带 `fingerprints`** —— `Skin:MatchFingerprints` 对没有指纹的条目直接返回
> false，所以真正能被 `LookupTemplate` 命中的目前是这 5 条（ColoredProgressBar / BasicHybridScrollFrame /
> SelectableButton / TemplatedList / MoneyDisplayFrame）。想让更多模板参与识别，得给
> `tools/extract-templates.js` 补指纹规则，而不是只加 skinAs 映射。

覆盖 Aurora 的 26 个 SharedXML 皮肤文件目标。

## 文件结构

```
Modules/Skins/Templates/
├── Templates.xml              # 加载清单（必须在 Skins.xml 之前）
├── TemplateDB.lua             # 自动生成的模板数据库（387 条）
├── TemplateRecognizer.lua     # 增强版识别引擎
├── CamelotOverrides.lua       # 1.60 特有调整
└── README.md                  # 本文件
```

## 数据来源

模板数据从 [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) 的 `forever` 分支提取，对应 WoW Forever 1.60 客户端的 FrameXML 文件。

提取工具：`tools/extract-templates.js`

```bash
# 审计模式（只打印统计）
node tools/extract-templates.js --audit

# 生成数据库
node tools/extract-templates.js
```

## 关键差异（1.60 Camelot vs Retail）

### ColoredProgressBarTemplate

- **1.60**: `Frame` 类型，使用 `ColoredProgressBarMixin`，有 `.Fill` 和 `.Mask` 字段
- **Retail**: `StatusBar` 类型，使用 `SetStatusBarTexture` / `SetStatusBarColor`

**影响**：按 StatusBar 处理会抛出 `"SetStatusBarTexture is not a function"`。

**处理**：`CamelotOverrides.lua` 强制将类型改为 `Frame`，并移除不适用的指纹。

### MoneyFrameTemplate

- **1.60**: 38 个实例，`.moneyType` 字段存在
- **Retail**: 相同

**影响**：无差异，指纹检查一致。

## 识别流程

```
Skin:Recognize(obj)
  ├─ 第一层：Skin:RecognizeEnhanced(obj)
  │   └─ Skin:LookupTemplate(obj)
  │       ├─ 查缓存（弱键表）
  │       ├─ 按 GetObjectType() 过滤候选模板
  │       └─ 对每个候选检查 fingerprints（AND 逻辑）
  │           ├─ field: obj[path] ~= nil
  │           ├─ method: type(obj[path]) == "function"
  │           └─ child: type(obj[path]) == "table"
  │
  └─ 第二层：原有结构指纹回退
      ├─ Frame: 检查 .moneyType / .Fill+.Mask
      ├─ ScrollFrame: 直接返回 "scroll"
      ├─ Slider: 直接返回 "slider"
      └─ ...
```

## 性能优化

1. **类型索引**：按 Frame 类型分区（Button/Frame/ScrollFrame），Button 对象不检查 Frame 模板
2. **弱键缓存**：对象 -> 模板名，避免重复查询
3. **指纹短路**：先检查最具选择性的指纹（如 `.moneyType` 比 `.Fill` 更稀有）
4. **批量大小**：每 2 秒扫描 ~100 个可见框架 × ~80 个映射模板 = 8000 次检查，开销可忽略

## 新增 skinAs 类型

| 类型 | 描述 | 处理方式 |
|------|------|----------|
| `scrollbox` | ScrollBox 框架 | 回退到 `scroll` |
| `nineslice` | NineSlice 面板 | 由 `Skin:Strip` 处理 |
| `selectable` | SelectableButton | 回退到 `button` |
| `templatelist` | TemplatedList | 暂不处理 |
| `moneyinput` | MoneyInputFrame | 回退到 `editbox` |
| `propertybutton` | PropertyButton | 暂不处理 |
| `closebutton` | 关闭按钮 | 回退到 `button` |

## 诊断命令

### /mui skins templates

显示模板数据库统计（数字取自运行时 `ns.TemplateDB`，所以是 32 条而不是源库的 387）：

```
模板库（运行时）：32 条，5 条带指纹（能被 LookupTemplate 匹配），32 条映射到 skinAs，Camelot 覆盖 1 条
  注：27 条没有指纹 —— 只登记了 type/skinAs，识别时不会被命中。
类型分布：
  Frame        13
  Button        8
  EditBox       3
  ScrollFrame   3
  Slider        3
  CheckButton   2
skinAs 分布：
  scroll         4
  editbox        3
  money          3
  button         2
  checkbox       2
  nineslice      2
  slider         2
  tab            2
  …另有 12 种
用法：/mui skins templates <片段> 按模板名 / skinAs 查映射。
```

`/mui skins templates money` 会列出名字或 skinAs 含 `money` 的模板及其映射。

### /mui compat tmpl

探测运行时模板存在性（已在 `Utils/Compat.lua` 实现）。

## 维护

### 更新数据库

客户端更新后，重新提取 FrameXML 并运行：

```bash
# 1. 更新 framexml-source（如果是从 GitHub 克隆）
cd framexml-source
git pull origin forever

# 2. 重新生成数据库
node tools/extract-templates.js

# 3. 验证
node tools/test-template-db.js

# 4. 提交
git add Modules/Skins/Templates/TemplateDB.lua
git commit -m "templates: 更新模板数据库到 <客户端版本>"
```

### 添加新模板映射

编辑 `tools/extract-templates.js` 的 `SKIN_AS_MAP` 对象，添加模板名到 skinAs 的映射：

```javascript
const SKIN_AS_MAP = {
    // 现有映射...
    'NewTemplate': 'newtype',
};
```

然后重新生成数据库。

### 添加 Camelot 覆盖

编辑 `Modules/Skins/Templates/CamelotOverrides.lua` 的 `CAMELOT_OVERRIDES` 表：

```lua
local CAMELOT_OVERRIDES = {
    NewTemplate = {
        forceType = "Frame",  -- 强制类型
        removeFingerprints = { "MethodToRemove" },  -- 移除的指纹
        note = "1.60 Camelot: 差异说明",
    },
}
```

## 参考

- `docs/AURORA-COVERAGE.md` — Aurora 覆盖对照表
- `docs/HANDOFF.md` §8.15 — "Reading Aurora as a 1.60 Fact Library"
- `Utils/SkinTemplates.lua` — 原有识别引擎
- `Modules/Skins/Skins.lua` — 皮肤引擎

## 已知限制

1. **指纹误报**：两个模板可能共享相同字段（如多个 Frame 都有 `.Fill`）。通过 AND 多个指纹降低误报率。
2. **匿名模板**：某些模板实例没有名字，无法通过数据库查询。回退到结构指纹识别。
3. **动态创建**：某些控件在运行时动态创建，数据库无法预知。通过 `PollWatch` 机制补扫。
4. **Camelot 覆盖不完整**：目前只记录了 1 个已知差异（ColoredProgressBarTemplate）。需要通过实机测试发现更多。
