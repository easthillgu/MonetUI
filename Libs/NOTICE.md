# Libs — third-party code shipped with MonetUI

MonetUI本身完全自写，只有下面这些文件来自他人，按各自许可随包分发。

## LibStub (`Libs/LibStub/LibStub.lua`)

- 作者：Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke
- 许可：Public Domain（文件头部已注明）
- 未做修改。

## LibMonetColor-1.0 (`Libs/LibMonetColor-1.0/`)

- 自家仓库 `monetcolors` 的产物，非第三方。

## LibActionButton-1.0 (`Libs/LibActionButton-1.0/`)

- 原作者：Hendrik "nevcairiel" Leppkes <h.leppkes@gmail.com>
- 许可：**BSD-3-Clause**（全文见同目录 `LICENSE.txt`，文件头部亦保留原文）
- 来源：取自 **Andromeda** 随包分发的 `libraries/LibActionButton-1.0/` 副本。
  Andromeda 是 GPL-3.0 项目，但该库文件本身是 BSD-3 授权，Andromeda 只是随包分发，
  并没有（也不能）改变它的许可，因此可以合法再分发。
- MonetUI 的改动**只有三行**（文件内以 `MonetUI change:` 标注）：
  1. `MAJOR_VERSION` 改为 `"LibActionButton-1.0-MonetUI"` —— 避免与 ElvUI / Andromeda
     各自的同名 fork 在 LibStub 里互相顶替；
  2. `LibCustomGlow` 改用库名 `"LibCustomGlow-1.0"` 查找（原来查的是 Andromeda 私有名），
     这样任何装了标准 LibCustomGlow 的插件都能让按钮吃到技能高亮；
  3. `CallbackHandler-1.0` 由必需改为可选（缺失时用一个空的 `lib.callbacks` 兜底），
     与 MonetUI「只硬依赖 LibStub」的原则一致。
- 其余代码原样保留，未做任何改写。

## 为什么把它放进包里

主动作条（1–8 号）的安全按钮、拖放、状态分页、按键提示、冷却/充能/射程/可用性刷新
都由这个库完成——这也是 Bartender4 / Dominos / ElvUI / Andromeda 的主流做法：
**隐藏暴雪默认动作条，改用客户端的安全模板自绘按钮**。自己重写一遍风险大且难以验证，
因此按用户决定采用库文件方案。
