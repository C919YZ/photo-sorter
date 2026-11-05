# 贡献指南

欢迎提 Issue 和 PR。这个项目很小，保持简单比堆功能重要 —— 提交前先看下面几条。

## 先看这些

- 架构与设计权衡：`docs\架构设计.md`
- 代码结构、扩展方法、已知的 PowerShell 坑：`docs\开发指南.md`

## 环境

```powershell
$PSVersionTable.PSVersion     # 需要 5.1.x（脚本要兼容 Windows 自带的 PowerShell）
& .\tools\exiftool\exiftool.exe -ver
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## 提交前必须做

1. **跑测试**：`tests\run-tests.ps1` 必须全部通过、退出码 0
2. **不要用 PS7 语法**：`??`、`?:`、`-Parallel`、`ForEach-Object -Parallel` 都会让 5.1 用户直接报语法错
3. **不要提交** `config.ps1`、`.cache\`、`.logs\`、`重复\`、`认不出格式\`、测试照片
4. **新增文件保持 UTF-8 with BOM**（`.ps1`）；bat 保持 **ASCII + CRLF**

## 分支与提交

```
main           稳定分支，tag 走发布
feat/xxx       新功能
fix/xxx        修 bug
docs/xxx       只有文档
```

提交信息用中文或英文都行，但要说清"为什么"：

```
分类: 手机视频的 GPSCoordinates 兜底解析

某些安卓机只写 GPSCoordinates 字符串而不写 GPSLatitude，
导致地点层全是"无数据"。补一条解析路径，并把用例加进自测。
```

## 代码风格

- 4 空格缩进，函数用 `动词-名词`（PowerShell 认可的动词：`Get-` `Set-` `Test-` `ConvertTo-` `Move-`）
- 所有文件操作带 `-LiteralPath`：用户文件名里出现 `[ ]` 时 `-Path` 会被当通配符
- 函数开头用 `.SYNOPSIS` / 注释说明"输入、输出、失败时返回什么"
- 处理"读不到"时优先返回 `$null` / 空串，把"抛异常"留给真正致命的错误（例如找不到 ExifTool）
- 输出给用户的中文提示，别用感叹号堆情绪；把"会发生什么"说清楚就够

## PR 检查表

- [ ] `tests\run-tests.ps1` 全绿
- [ ] 新增行为有对应断言（否则回归时没人知道它坏了）
- [ ] 没有引入 PS7 专有语法
- [ ] `CHANGELOG.md` 加了一行
- [ ] 修 bug 的 PR 说明了复现条件（截图或 `exiftool -a -G1 文件` 输出）
- [ ] 没有把个人路径、个人照片、真实邮箱写进代码或文档

## 报告分类错误

请附上：

1. 期望的目录 与 实际的目录
2. 该文件的 `exiftool -a -G1 -s "文件路径"` 输出（**先删掉 GPS 精确坐标**，你只需要保留 `FileType` / `Make` / `Model` / 时间 / 是否有 GPS）
3. 使用的 Windows 版本和 `$PSVersionTable.PSVersion`

90% 的分类问题都能从这三样里直接定位。

## 关于许可证

本项目是 **source-available**（PolyForm Internal Use 1.0.0）：个人和公司内部使用免费、可改；**禁止对外分发与转售**。它不是 OSI 开源。

提交 PR 即表示你同意以同一许可证发布你的贡献，并允许作者在你贡献的基础上进行对外授权（例如集成到商业产品）。如果这一点你不接受，请不要提交 PR，改成提 Issue 描述方案即可。
