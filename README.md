# PhotoSorter

按 EXIF 元数据整理照片/视频，并用 SHA-256 精确去重的命令行工具。Windows PowerShell 5.1，零依赖（除 ExifTool）。

整理后结构固定为 `主目录\<设备>\<时间>\<地点>\`，任何一层读不到就落进「无数据」文件夹；重复文件不会被删，而是挪进「重复」文件夹等你人工确认。

```
主目录\Canon EOS R6\2024-05-10\N31.23_E121.47\IMG_1234.JPG
主目录\Canon EOS R6\2024-05-10\无数据\IMG_1235.JPG          ← 这张没 GPS
主目录\Apple iPhone 13\无数据\N22.54_E114.06\IMG_0007.MOV   ← 这段视频没拍摄时间
主目录\无数据\无数据\无数据\IMG_0008.JPG                     ← 元数据全无
```

## 为什么是这套结构

| 决策 | 理由 |
|---|---|
| 三层深度固定，缺失写「无数据」 | 目录深度恒定，脚本/备份/媒体库软件都不用处理层级不确定的情况 |
| 时间只认 EXIF，不认文件修改时间 | 下载、解压、拷贝都会把文件时间改成"今天"，用它分类会全乱 |
| 地点用 GPS 网格（2 位小数 ≈ 1km），不做地名反查 | 不联网、不依赖地理编码服务；同一地点反复拍摄能落进同一个文件夹 |
| 复制而不是移动 | 分类结果可以整体验证/重来；源文件留给你确认后再删 |
| 用 `Copy-Item` 原样拷字节 | 不用 `exiftool -o`（那会重写元数据、改变文件哈希，去重就失效了） |
| 去重只移动不删除 | 误判永远可恢复 |

## 功能

- **三维分类**：设备（Make + Model）/ 时间（拍摄时间，按天/月/年可调）/ 地点（GPS 网格）
- **SHA-256 精确去重**：全文件哈希，不靠文件名或大小；先按大小分组预筛，几千张照片通常只算几十个哈希
- **两种去重模式**：待分类1 内部去重；待分类1 对比主目录（主目录优先保留）
- **增量哈希缓存**：主目录只对新增/改动过的文件重算，删掉的文件自动从缓存剔除
- **认不出格式单独收容**：扩展名是 `.jpg` 但内容其实不是图片（下载残片、文本改名）会被移进「认不出格式」，而不是塞进主目录
- **非媒体文件零打扰**：txt / docx / 无扩展名文件一个都不碰，只在运行时列出来提醒你
- **预览模式**：`-Preview` 只打印会分到哪，不落盘
- **可回滚**：全程复制 + 移动，加上 `.logs\` 里的逐条 CSV 日志

> 只支持 Windows（依赖 `cmd` 重定向与 PowerShell 5.1 的编码行为）。macOS / Linux 可参考 `docs/开发指南.md` 里的移植说明。

## 快速开始

### 最快的路子：下载发行包

Releases 里下 `PhotoSorter-x.y.z-win64.zip`（已内置 ExifTool，约 12 MB），解压后双击 `0-开始.bat`，按菜单选 `1` → `2` 即可。包里还有一页纸的 `使用说明.txt`，不需要看这个 README。

**兼容性**：Windows 10 1809+ / Windows 11，64 位，系统自带 PowerShell 5.1。不支持 macOS / Linux / 32 位。

### 从源码跑

### 1. 装 ExifTool

从 <https://exiftool.org/> 下载 Windows 版（`exiftool-XX.XX_64.zip`），解压后把 `exiftool(-k).exe` 改名成 `exiftool.exe`，放到仓库的 `tools\exiftool\` 下，或装到任意位置再写进 `config.ps1`。

### 2. 配置

```powershell
copy config.example.ps1 config.ps1
notepad config.ps1
```

只改 `Root`（资料库根目录）和 `ExifToolPath` 两项即可。`config.ps1` 已在 `.gitignore` 里，不会被提交。

### 3. 建目录，开跑

```
照片库\
├─ 待分类1\        ← 新文件先丢这里
├─ 主目录\         ← 分类结果（脚本自动建）
├─ 重复\           ← 判重后挪过来的文件
└─ 认不出格式\     ← 读不出元数据的文件
```

双击 `bin\` 下的 bat，或直接跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Classify.ps1
powershell -ExecutionPolicy Bypass -File .\src\Dedupe.ps1 -Scope Inbox
```

## 每一轮的操作顺序

**第一轮**（待分类1 里全是新文件）

```
1) bin\1-dedupe-inbox.bat       同一批内部重复的，只留 1 份
2) bin\2-classify.bat           复制到 主目录\设备\时间\地点
3) 手动清空 待分类1
```

**之后每一轮**

```
1) bin\1-dedupe-inbox.bat          先处理这批内部的重复
2) bin\3-dedupe-vs-library.bat     和已分类的主目录比，重复的挪进 重复\
3) bin\2-classify.bat              剩下的分类
4) 手动清空 待分类1
```

顺序不能颠倒：先分类再对比，主目录里会多一份重复，还得手工收拾。

## 目录与命名规则

| 层 | 取值 | 取不到时 |
|---|---|---|
| 设备 | `Make` + `Model`，如 `Canon EOS R6`、`Apple iPhone 13` | `无数据` |
| 时间 | `DateTimeOriginal` → `CreateDate` → `MediaCreateDate` → `TrackCreateDate` → `CreationDate`，默认 `2024-05-10` | `无数据` |
| 地点 | GPS 四舍五入 2 位小数，如 `N31.23_E121.47`（约 1km 网格） | `无数据` |

- 文件夹名里的 `<>:"/\|?*` 等 Windows 非法字符会替换成 `_`，长度截断到 60
- 同名但内容不同 → 目标文件加 `_1`、`_2`，**绝不覆盖**
- 扩展名白名单：jpg / jpeg / heic / heif / png / webp / gif / bmp / tif / tiff / dng / cr2 / cr3 / nef / arw / raf / rw2 / orf / srw / mp4 / mov / m4v / avi / mkv / 3gp / mts / m2ts / wmv / flv / mpg / mpeg

## 命令行参数

| 脚本 | 参数 | 说明 |
|---|---|---|
| `src\Classify.ps1` | `-Root <路径>` | 覆盖 config.ps1 里的数据根目录 |
| | `-TimeGroup day\|month\|year` | 时间层粒度，默认 `day` |
| | `-Preview` | 只打印结果，不复制不移动 |
| `src\Dedupe.ps1` | `-Scope Inbox\|Library` | `Inbox`=内部去重，`Library`=对比主目录 |
| | `-Root <路径>` | 同上 |
| | `-Preview` | 只报告，不移动不写缓存 |
| | `-ConfigPath <路径>` | 用另一份配置文件 |

## 去重怎么判

1. 按文件大小分组 —— 大小不同，内容必然不同，直接跳过
2. 同尺寸组内才算 SHA-256；同哈希的只留 1 份
3. 内部去重时保留**文件名最短**的那份（通常是没有「- 副本」后缀的原件），同长度比修改时间、再比路径
4. 跨主目录去重时**主目录优先**，待分类1 里那份挪进 `重复\<时间戳>_library\`

主目录缓存放在 `.cache\library-hashes.csv`（相对路径 / 大小 / 修改时间 / 哈希）。文件改名或移动后，旧条目会因为路径对不上而自动重算，不需要手工维护。删掉这个 csv 可以强制全量重建。

## 安全边界

| 会做的事 | 不会做的事 |
|---|---|
| 复制文件到主目录 | 删除任何文件 |
| 把重复文件**移动**到 `重复\` | 覆盖同名文件（一律加序号） |
| 把读不出的文件**移动**到 `认不出格式\` | 改动照片/视频的内容或元数据 |
| 写 `.logs\` 与 `.cache\` 里的 CSV | 动非照片/视频文件（只提醒） |

每次运行的明细都在 `.logs\`：`classify_*.csv`（源文件 / 目标 / 设备 / 时间 / 地点 / 动作）、`dedupe_*.csv`（哈希 / 原路径 / 重复于 / 移到）。分类错了就照日志删掉主目录里对应文件，重跑一次即可。

## 常见问题

**视频被分到前一天？**
iPhone / 安卓的 mp4，`CreateDate` 常是 UTC，比北京时间早 8 小时，跨零点就会差一天。要按拍摄地时区换算，在 `src\Classify.ps1` 的 `$argList` 里加 `'-api', 'QuickTimeUTC=1'`。

**HEIC / RAW 支持吗？**
支持。ExifTool 能读，扩展名白名单里也有。但 Windows 资源管理器本身可能没有 HEIC 预览，那是系统解码器的问题，与分类无关。

**为什么有些文件进了「认不出格式」？**
判定依据是 ExifTool 读出的 `MIMEType`（必须是 `image/*` 或 `video/*`）。下载没下完的残片、0 字节文件、把 txt 改名成 `.jpg` 的，都会进去 —— 它们留在待分类1 只会被误删，挪出来更安全。

**非照片/视频的文件会被删吗？**
不会。去重和分类都只看扩展名白名单，其他文件原样留在 `待分类1`，运行时列表提醒。清空文件夹之前看一眼就行。

**中文文件名乱码？**
不会。脚本用 `cmd` 重定向把 ExifTool 输出写成文件再按 UTF-8 读，避开了 PowerShell 5.1 按 GB2312 解码原生命令输出的坑（详见 `docs\开发指南.md`）。

**能改目录名吗？**
可以。`config.ps1` 里的 `InboxFolderName` / `LibraryFolderName` / `DuplicateFolderName` / `UnknownFolderName` / `UnknownValue` 都能改，改成英文也没问题。

## 开发

- 架构与设计权衡：`docs\架构设计.md`
- 代码结构、扩展方法、踩坑记录：`docs\开发指南.md`
- 贡献流程：`CONTRIBUTING.md`

跑自测（会自己在临时目录造测试照片，25 项断言）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## 许可证

本项目使用 **PolyForm Internal Use License 1.0.0**，全文见 `LICENSE`。

| 使用场景 | 是否允许 |
|---|---|
| 个人使用、家庭、学习、教学、研究 | ✅ 免费 |
| 公司/单位内部业务使用（可在本单位内部发放给员工） | ✅ 免费，无需授权 |
| 修改代码、内部二次开发 | ✅ 允许 |
| 对外分发安装包、公开转载 | ❌ 禁止 |
| 转售、随硬件或服务销售、二次打包收费 | ❌ 严禁 |

这就是"源码公开可读可改、企业内部随便用、但谁也别拿去卖"的那种授权。需要对外分发（例如集成进你销售的产品）请单独联系作者授权。

> 严格来说，这不是 OSI 定义下的"开源软件"，而是 **source-available（源码可见）**。GitHub 会把它标成 "Other" 而不是 "Open Source"。如果你希望它变成 OSI 开源项目，把 `LICENSE` 换成 MIT / Apache-2.0 即可 —— 但那样就没有"禁止倒卖"这条约束了。

**其他授权**：请开 Issue 或邮件联系作者（把这里换成你的邮箱）。

## 免责声明

软件按"现状"提供，不附带任何担保。整理前的原始文件请自行备份 —— 虽然工具只复制和移动、从不删除，但任何批量文件操作都值得先跑一次 `-Preview` 确认。

---

如果这个工具帮你省了时间，欢迎在 Issue 里说说你的使用场景；发现分类错误，附上一张 `exiftool -a -G1 文件` 的输出，基本能直接定位。
