# VS Code 配置备份仓库

这个仓库存放 Windows 上 VS Code 的用户级配置备份，目标是让你可以在不同电脑之间恢复一致的编辑器环境，同时避免把登录态、缓存和工作区状态提交到 Git。

## 备份范围

- `settings/`：全局 `settings.json` 与 `keybindings.json`
- `snippets/`：用户代码片段
- `profiles/`：可安全复制的 Profile 配置文件
- `extensions.txt`：已安装扩展及精确版本
- `scripts/`：导出与导入脚本

## 不会备份的内容

- `globalStorage`
- `History`
- `workspaceStorage`
- 登录凭据、令牌、Cookie、聊天记录
- 项目级 `.vscode`
- 扩展二进制缓存

## 日常导出

在当前仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Export-VSCodeConfig.ps1
git diff --check
rg -n -i "token|password|secret|api[_-]?key|private.?key" --glob "!README.md" --glob "!docs/**"
git status --short
git add .
git commit -m "chore: back up current VS Code environment"
git push
```

如果脚本检测到疑似敏感配置，会直接失败，并提示需要先从源配置中移除或改为环境变量引用。

## 在新电脑导入

先演练：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Import-VSCodeConfig.ps1 -WhatIf
```

确认无误后再执行实际导入：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Import-VSCodeConfig.ps1
```

导入脚本会先把当前电脑的用户配置备份到 `backups/<时间戳>/`，然后恢复仓库中的设置并重新安装扩展。

## 还原限制

- 各类服务的登录状态需要手动重新登录。
- 某些扩展的运行时缓存不会迁移。
- 如果你修改了 `code` 命令安装位置，可以通过 `-CodeCommand` 参数显式指定。