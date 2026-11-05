# 更新记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [1.0.0] - 2026-11-05

首个可发布版本。

### 新增

- 三维分类：`主目录\<设备>\<时间>\<地点>\`，缺失层统一写「无数据」
- 设备取 `Make` + `Model`，时间按 `DateTimeOriginal → CreateDate → MediaCreateDate → TrackCreateDate → CreationDate` 依次回退
- 地点取 GPS 十进制度，四舍五入 2 位小数（约 1km 网格）；视频的 `GPSCoordinates` 字符串也能解析
- 复制模式：`Copy-Item` 原样拷字节，不改元数据、不改变文件哈希
- SHA-256 去重，两种模式：待分类1 内部 / 待分类1 对比主目录（主目录优先）
- 哈希计算前按文件大小预筛，只对同尺寸文件算哈希
- 主目录哈希缓存 `.cache\library-hashes.csv`，按「相对路径 + 大小 + 修改时间」增量复用
- 认不出格式（`MIMEType` 不是 `image/*` / `video/*`，或 ExifTool 读不出）自动移入「认不出格式」
- 非照片/视频文件完全不参与处理，运行时列出清单提醒
- 同名不同内容自动加 `_1`、`_2`，绝不覆盖
- `-Preview` 预览模式
- 每次运行写 `.logs\` CSV 日志（逐文件动作，可用于回滚核对）
- `tests\run-tests.ps1` 端到端自测：25 项断言，覆盖分类、去重、缓存、坏文件、非媒体文件
- `config.ps1` 外置配置，目录名可改（中文/英文均可）
- `src\Menu.ps1` + `bin\0-开始.bat`：中文菜单，双击即用，不用记命令
- `build-release.ps1`：一键打「解压即用」发行包（内置 ExifTool），输出 `dist\PhotoSorter-<版本>-win64.zip` 与 SHA256
- `使用说明.txt` / `RELEASE_NOTES.md`：给不懂命令的人看的图文说明与发行说明

### 说明

- 仅支持 Windows 10 1809+ / Windows 11（64 位）+ PowerShell 5.1
- 许可证为 PolyForm Internal Use 1.0.0：个人与企业内部使用免费、可修改，**禁止对外分发与转售**，全文见 `LICENSE`（1.0.0 起从 Noncommercial 改为 Internal Use）
