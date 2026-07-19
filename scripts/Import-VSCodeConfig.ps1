<#
.SYNOPSIS
从仓库恢复 VS Code 用户配置。

.DESCRIPTION
在恢复前先把目标电脑的当前配置备份到仓库本地 `backups/` 目录，
随后恢复安全导出的设置、快捷键、代码片段与 Profile 配置，并按扩展清单重新安装扩展。
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string] $RepositoryPath = '',

    [Parameter()]
    [string] $TargetUserDirectory = (Join-Path $env:APPDATA 'Code\User'),

    [Parameter()]
    [string] $CodeCommand = 'code'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ShouldProcessContext = $PSCmdlet

# 在脚本体内解析仓库根目录，兼容 Windows PowerShell 对参数默认表达式的处理差异。
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = Split-Path -Parent $PSScriptRoot
}

<#
.SYNOPSIS
初始化目录。

.DESCRIPTION
确保目标目录存在；如果目录不存在，则自动创建。

.PARAMETER Path
需要存在的目录路径。

.OUTPUTS
System.Void
无返回值。
#>
function Initialize-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # 当目标目录不存在时，创建目录以承接备份或恢复结果。
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

<#
.SYNOPSIS
按原结构复制文件或目录。

.DESCRIPTION
在复制前确保目标父目录存在，并根据源路径类型执行文件复制或目录递归复制。

.PARAMETER SourcePath
源文件或目录路径。

.PARAMETER DestinationPath
目标文件或目录路径。

.OUTPUTS
System.Void
无返回值。
#>
function Copy-PathContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    # 若源路径不存在则直接跳过，兼容部分配置缺失的场景。
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    # 先确保目标父目录已就绪，再按文件或目录类型复制内容。
    Initialize-Directory -Path (Split-Path -Parent $DestinationPath)
    if ((Get-Item -LiteralPath $SourcePath).PSIsContainer) {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Recurse -Force
    }
    else {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }
}

<#
.SYNOPSIS
清理将被恢复覆盖的目标目录。

.DESCRIPTION
在恢复代码片段或 Profile 前删除旧目录，避免仓库之外的遗留文件残留在目标机器上。

.PARAMETER Path
需要清理的目标目录路径。

.OUTPUTS
System.Void
无返回值。
#>
function Reset-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # 仅在目录存在且用户确认写入时执行清理动作。
    if ((Test-Path -LiteralPath $Path) -and $script:ShouldProcessContext.ShouldProcess($Path, '清理现有目录内容')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

<#
.SYNOPSIS
创建恢复前备份。

.DESCRIPTION
把目标用户目录中的当前设置、快捷键、代码片段和 Profile 复制到仓库本地时间戳备份目录。

.PARAMETER RepositoryPath
仓库根目录路径。

.PARAMETER TargetUserDirectory
目标 VS Code 用户目录路径。

.OUTPUTS
System.String
返回备份目录路径。
#>
function New-ConfigurationBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string] $TargetUserDirectory
    )

    # 生成时间戳备份目录，便于后续回滚和审计。
    $backupRoot = Join-Path $RepositoryPath 'backups'
    $backupPath = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')

    # 在确认写入时创建备份根目录。
    if ($script:ShouldProcessContext.ShouldProcess($backupPath, '创建恢复前备份目录')) {
        Initialize-Directory -Path $backupPath
    }

    # 逐项备份当前目标配置，确保恢复前状态可回退。
    $items = @(
        @{ Source = (Join-Path $TargetUserDirectory 'settings.json'); Destination = (Join-Path $backupPath 'settings.json') },
        @{ Source = (Join-Path $TargetUserDirectory 'keybindings.json'); Destination = (Join-Path $backupPath 'keybindings.json') },
        @{ Source = (Join-Path $TargetUserDirectory 'snippets'); Destination = (Join-Path $backupPath 'snippets') },
        @{ Source = (Join-Path $TargetUserDirectory 'profiles'); Destination = (Join-Path $backupPath 'profiles') }
    )
    foreach ($item in $items) {
        if ((Test-Path -LiteralPath $item.Source) -and $script:ShouldProcessContext.ShouldProcess($item.Destination, '备份现有配置')) {
            Copy-PathContent -SourcePath $item.Source -DestinationPath $item.Destination
        }
    }

    return $backupPath
}

<#
.SYNOPSIS
恢复仓库中的配置文件。

.DESCRIPTION
把仓库中的设置、快捷键、代码片段和 Profile 文件复制到目标用户目录。

.PARAMETER RepositoryPath
仓库根目录路径。

.PARAMETER TargetUserDirectory
目标 VS Code 用户目录路径。

.OUTPUTS
System.Void
无返回值。
#>
function Restore-ConfigurationContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string] $TargetUserDirectory
    )

    # 计算仓库中各类配置的标准位置，后续逐项恢复。
    $settingsDirectory = Join-Path $RepositoryPath 'settings'
    $repositorySnippets = Join-Path $RepositoryPath 'snippets'
    $repositoryProfiles = Join-Path $RepositoryPath 'profiles'

    # 先确保目标用户目录存在，避免复制到无效路径。
    Initialize-Directory -Path $TargetUserDirectory

    # 恢复全局设置与快捷键。
    $fileMappings = @(
        @{ Source = (Join-Path $settingsDirectory 'settings.json'); Destination = (Join-Path $TargetUserDirectory 'settings.json') },
        @{ Source = (Join-Path $settingsDirectory 'keybindings.json'); Destination = (Join-Path $TargetUserDirectory 'keybindings.json') }
    )
    foreach ($mapping in $fileMappings) {
        if ((Test-Path -LiteralPath $mapping.Source) -and $script:ShouldProcessContext.ShouldProcess($mapping.Destination, '恢复配置文件')) {
            Copy-PathContent -SourcePath $mapping.Source -DestinationPath $mapping.Destination
        }
    }

    # 恢复代码片段前先清理旧目录，确保结果与仓库内容一致。
    $targetSnippets = Join-Path $TargetUserDirectory 'snippets'
    if (Test-Path -LiteralPath $repositorySnippets) {
        Reset-DirectoryContent -Path $targetSnippets
        if ($script:ShouldProcessContext.ShouldProcess($targetSnippets, '恢复代码片段目录')) {
            Copy-PathContent -SourcePath $repositorySnippets -DestinationPath $targetSnippets
        }
    }

    # 恢复 Profile 配置前同样清理旧目录，避免残留状态文件。
    $targetProfiles = Join-Path $TargetUserDirectory 'profiles'
    if (Test-Path -LiteralPath $repositoryProfiles) {
        Reset-DirectoryContent -Path $targetProfiles
        if ($script:ShouldProcessContext.ShouldProcess($targetProfiles, '恢复 Profile 配置目录')) {
            Copy-PathContent -SourcePath $repositoryProfiles -DestinationPath $targetProfiles
        }
    }
}

<#
.SYNOPSIS
按扩展清单安装 VS Code 扩展。

.DESCRIPTION
读取仓库根目录的 `extensions.txt`，并逐项调用 VS Code CLI 重新安装扩展。

.PARAMETER RepositoryPath
仓库根目录路径。

.PARAMETER CodeCommand
VS Code CLI 命令或完整路径。

.OUTPUTS
System.String[]
返回安装失败的扩展标识集合。
#>
function Install-VSCodeExtensions {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string] $CodeCommand
    )

    # 若仓库中没有扩展清单，则无需执行安装步骤。
    $extensionsFile = Join-Path $RepositoryPath 'extensions.txt'
    if (-not (Test-Path -LiteralPath $extensionsFile)) {
        return @()
    }

    # 确认 VS Code CLI 可用，以便执行扩展安装。
    Get-Command $CodeCommand -ErrorAction Stop | Out-Null

    # 读取扩展清单并收集安装失败项，便于恢复结束后统一提示。
    $failedExtensions = @()
    $extensions = Get-Content -LiteralPath $extensionsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($extension in $extensions) {
        if ($script:ShouldProcessContext.ShouldProcess($extension, '安装 VS Code 扩展')) {
            $null = & $CodeCommand --install-extension $extension --force
            if ($LASTEXITCODE -ne 0) {
                $failedExtensions += $extension
            }
        }
    }

    return $failedExtensions
}

<#
.SYNOPSIS
执行配置恢复主流程。

.DESCRIPTION
依次创建备份、恢复文本配置，并重新安装扩展；若部分扩展失败，则在结束时统一输出。

.PARAMETER RepositoryPath
仓库根目录路径。

.PARAMETER TargetUserDirectory
目标 VS Code 用户目录路径。

.PARAMETER CodeCommand
VS Code CLI 命令或完整路径。

.OUTPUTS
System.Void
无返回值。
#>
function Import-VSCodeConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string] $TargetUserDirectory,

        [Parameter(Mandatory = $true)]
        [string] $CodeCommand
    )

    # 在恢复前先创建备份，确保任何覆盖写入都可以回退。
    $backupPath = New-ConfigurationBackup -RepositoryPath $RepositoryPath -TargetUserDirectory $TargetUserDirectory

    # 从仓库恢复配置内容，再根据扩展清单安装扩展。
    Restore-ConfigurationContent -RepositoryPath $RepositoryPath -TargetUserDirectory $TargetUserDirectory
    $failedExtensions = @(Install-VSCodeExtensions -RepositoryPath $RepositoryPath -CodeCommand $CodeCommand)

    # 向用户输出本次恢复所使用的备份目录，方便后续检查。
    Write-Host "恢复前备份目录：$backupPath"

    # 若存在安装失败的扩展，则统一列出，便于后续手工处理。
    if (@($failedExtensions).Count -gt 0) {
        Write-Warning "以下扩展安装失败：$($failedExtensions -join ', ')"
    }
}

Import-VSCodeConfiguration -RepositoryPath $RepositoryPath -TargetUserDirectory $TargetUserDirectory -CodeCommand $CodeCommand