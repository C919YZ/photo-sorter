# tools\

放 ExifTool 的目录（不随仓库分发）。

从 <https://exiftool.org/> 下载 Windows 版（`exiftool-XX.XX_64.zip`），解压后：

```
tools\
└─ exiftool\
   ├─ exiftool.exe        ← 把 exiftool(-k).exe 改名成这个
   └─ exiftool_files\
```

脚本的查找顺序：

1. `config.ps1` 里的 `ExifToolPath`
2. 系统 `PATH`
3. 本目录下的 `tools\exiftool\exiftool.exe`
4. `C:\Users\<用户>\Tools\exiftool\exiftool.exe`、`C:\Windows\exiftool.exe`

所以也可以完全不放在这里，装到任何地方再写进 `config.ps1` 即可。
