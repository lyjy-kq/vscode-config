# VS Code 配置备份仓库设计

## 目标

在 Windows 电脑之间通过私有 Git 仓库复刻 VS Code 的用户级开发环境。仓库应保存可公开审查的设置、快捷键、代码片段、Profile 配置和带版本的扩展清单；不保存登录凭据、聊天内容、缓存或工作区状态。

## 仓库结构

```text
settings/                 全局 settings.json 与 keybindings.json
snippets/                 用户代码片段目录
profiles/                 可安全复制的 VS Code Profile 配置
extensions.txt            扩展标识和精确版本
scripts/                  导出和导入 PowerShell 脚本
README.md                 中文使用、更新、恢复和限制说明
.gitignore                缓存、凭据和临时文件排除规则
```

## 数据流

`Export-VSCodeConfig.ps1` 从 `%APPDATA%\Code\User` 读取配置，复制允许的文件到仓库，扫描并拒绝疑似秘密字段，随后通过 `code --list-extensions --show-versions` 生成扩展清单。

`Import-VSCodeConfig.ps1` 先在目标电脑备份现有 VS Code 用户配置，再恢复仓库中的设置、快捷键、代码片段与 Profile 文件，最后根据扩展清单逐项运行 `code --install-extension`。

## 安全边界

允许提交的内容：编辑器设置、扩展设置、快捷键、代码片段、Profile 定义和扩展名称/版本。

必须排除的内容：`globalStorage`、`History`、`workspaceStorage`、扩展认证令牌、Cookie、私钥、密码、聊天记录、会话状态、机器路径以外的任何凭据文件及导出临时文件。

导出脚本检查常见秘密键名和值模式。发现匹配项即失败，并输出文件和字段路径，要求用户先在源配置中移除或改用环境变量。仓库保持私有，但“私有”不能替代检查。

## 错误处理和恢复

脚本应在 VS Code 命令行 `code` 不可用时给出安装 PATH 的说明。复制前应检测所需源文件是否存在；缺失的可选文件只提示并继续。导入前创建时间戳备份目录，任何扩展安装失败均汇总显示，但不撤销已成功恢复的文本配置。

## 验证

导出后验证必需文件已生成、秘密扫描通过且扩展清单非空（如当前安装了扩展）。导入脚本支持 `-WhatIf` 进行无写入演练。README 记录从克隆仓库到完成导入的命令，以及无法自动迁移的登录状态。

## 非目标

不备份项目级 `.vscode` 目录，不迁移 VS Code 登录会话，也不尝试复制扩展二进制缓存；扩展由 VS Code Marketplace 正常重新安装。
