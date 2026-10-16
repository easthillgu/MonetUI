---
description: 对改动文件逐个跑 wuxian check，只汇总错误/警告
---

对下面 git 列出的每个改动文件（限 MonetUI 项目内 `*.lua` / `*.toc`，包含未跟踪的新文件）逐个执行 `tools.wuxian.check`（`live: false`），只汇报 errors 和 warnings（文件、行号、含义）；全部通过就只回一句「全部通过」。不要修改任何文件。

!`git status --short`
