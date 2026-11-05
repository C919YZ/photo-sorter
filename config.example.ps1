# PhotoSorter 配置示例
#
# 用法：复制成 config.ps1 再改（config.ps1 已被 .gitignore 忽略，不会误提交）。
# 只写想改的键即可，没写的走 src\lib\Common.ps1 里的默认值。
#
# 本文件必须保存成 UTF-8 with BOM（PowerShell 5.1 读中文路径的要求）。

@{
    # 资料库根目录：下面会有 待分类1 / 主目录 / 重复 / 认不出格式
    Root = 'C:\Users\c9195\Pictures\照片库'

    # 时间层粒度：day=2024-05-10  month=2024-05  year=2024
    TimeGroup = 'day'

    # exiftool.exe 路径。留空则依次尝试 PATH、tools\exiftool\、常见安装位置
    ExifToolPath = ''

    # 目录名（想换成英文/日文目录名就改这里）
    InboxFolderName     = '待分类1'
    LibraryFolderName   = '主目录'
    DuplicateFolderName = '重复'
    UnknownFolderName   = '认不出格式'
    UnknownValue        = '无数据'
}
