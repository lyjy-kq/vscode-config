<#
.SYNOPSIS
安全导出当前用户的 VS Code 配置。

.DESCRIPTION
从指定的 VS Code 用户目录导出全局设置、快捷键、代码片段、可复制的 Profile 配置和带版本的扩展清单，
并在写入仓库前扫描疑似敏感信息，避免把令牌、密码或私钥类配置提交到 Git。
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string] $SourceUserDirectory = (Join-Path $env:APPDATA 'Code\User'),

    [Parameter()]
    [string] $RepositoryPath = '',

    [Parameter()]
    [string] $CodeCommand = 'code'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    # 当目标目录不存在时，先创建目录以承接后续导出文件。
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

<#
.SYNOPSIS
检查配置文件中是否存在疑似敏感信息。

.DESCRIPTION
按常见秘密字段名和值模式扫描文本配置；一旦发现疑似敏感信息即抛出终止错误。

.PARAMETER Path
需要扫描的文本文件路径。

.OUTPUTS
System.Void
无返回值。
#>
function Test-ConfigurationSecrets {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # 读取整个文本内容，供后续正则规则统一检查。
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    # 组合常见的敏感字段名和值模式，覆盖令牌、密码、私钥等高风险内容。
    $patterns = @(
        '(?i)(token|password|secret|api[_-]?key|private.?key)',
        '(?i)\bghp_[a-z0-9]{20,}\b',
        '(?i)\bgithub_pat_[a-z0-9_]{20,}\b',
        '(?i)\bsk-[a-z0-9]{20,}\b'
    )

    # 逐条匹配规则；命中后立即失败，阻止不安全内容被复制到仓库。
    foreach ($pattern in $patterns) {
        if ($content -match $pattern) {
            throw "检测到疑似敏感信息，已停止导出：$Path"
        }
    }
}

<#
.SYNOPSIS
清理旧的导出结果。

.DESCRIPTION
删除仓库中上一次导出的配置目录和扩展清单，避免残留文件造成误判或污染新快照。

.PARAMETER RepositoryPath
仓库根目录路径。

.OUTPUTS
System.Void
无返回值。
#>
function Clear-ExportTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath
    )

    # 定位会被本次导出重新生成的目录和文件。
    $targets = @(
        (Join-Path $RepositoryPath 'settings'),
        (Join-Path $RepositoryPath 'snippets'),
        (Join-Path $RepositoryPath 'profiles'),
        (Join-Path $RepositoryPath 'extensions.txt')
    )

    # 在删除前先确认目标存在，只清理本脚本负责生成的内容。
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
}

<#
.SYNOPSIS
复制单个配置文件。

.DESCRIPTION
对源文件执行秘密扫描，随后创建目标父目录并复制到仓库。

.PARAMETER SourcePath
源文件完整路径。

.PARAMETER DestinationPath
目标文件完整路径。

.OUTPUTS
System.Void
无返回值。
#>
function Copy-ConfigurationFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    # 先验证源文件存在，避免生成不完整的导出结果。
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    # 对文本配置做敏感信息检查，发现风险即终止流程。
    Test-ConfigurationSecrets -Path $SourcePath

    # 为目标文件创建父目录，随后覆盖式复制最新内容。
    Initialize-Directory -Path (Split-Path -Parent $DestinationPath)
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

<#
.SYNOPSIS
复制配置目录中的允许文件。

.DESCRIPTION
递归扫描目录，只复制指定扩展名的文件，并排除缓存与状态目录。

.PARAMETER SourcePath
源目录完整路径。

.PARAMETER DestinationPath
目标目录完整路径。

.PARAMETER AllowedExtensions
允许复制的文件扩展名集合，使用小写格式。

.PARAMETER ExcludedDirectoryNames
需要排除的目录名称集合。

.OUTPUTS
System.Void
无返回值。
#>
function Copy-ConfigurationDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string[]] $AllowedExtensions,

        [Parameter(Mandatory = $true)]
        [string[]] $ExcludedDirectoryNames
    )

    # 当源目录不存在时直接跳过，兼容没有 snippets 或 profiles 的机器。
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    # 遍历全部文件，并按扩展名和目录白名单进行筛选。
    $files = Get-ChildItem -LiteralPath $SourcePath -Recurse -File
    foreach ($file in $files) {
        # 计算相对路径，便于按原目录结构写入仓库。
        $relativePath = $file.FullName.Substring($SourcePath.Length).TrimStart('\')

        # 遇到需要排除的状态目录时直接跳过对应文件。
        $pathSegments = $relativePath -split '[\\/]'
        $isExcluded = $false
        foreach ($segment in $pathSegments) {
            if ($ExcludedDirectoryNames -contains $segment) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) {
            continue
        }

        # 只复制允许的文本配置文件，避免把数据库或缓存文件带入仓库。
        $extension = $file.Extension.ToLowerInvariant()
        if ($AllowedExtensions -notcontains $extension) {
            continue
        }

        # 复用单文件复制逻辑，统一执行秘密检查和目录创建。
        $destinationFile = Join-Path $DestinationPath $relativePath
        Copy-ConfigurationFile -SourcePath $file.FullName -DestinationPath $destinationFile
    }
}

<#
.SYNOPSIS
导出 VS Code 用户配置。

.DESCRIPTION
清理旧导出结果后，复制安全的配置文件，并使用 VS Code CLI 生成带版本的扩展清单。

.PARAMETER SourceUserDirectory
VS Code 用户目录路径。

.PARAMETER RepositoryPath
仓库根目录路径。

.PARAMETER CodeCommand
VS Code CLI 命令或完整路径。

.OUTPUTS
System.Void
无返回值。
#>
function Export-VSCodeConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceUserDirectory,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string] $CodeCommand
    )

    # 在导出前确认用户目录存在，避免对错误路径执行空导出。
    if (-not (Test-Path -LiteralPath $SourceUserDirectory)) {
        throw "未找到 VS Code 用户目录：$SourceUserDirectory"
    }

    # 提前验证 VS Code CLI 可用，确保扩展清单能够被正常生成。
    Get-Command $CodeCommand -ErrorAction Stop | Out-Null

    # 清理旧快照，保证仓库中的内容与当前机器状态一致。
    Clear-ExportTargets -RepositoryPath $RepositoryPath

    # 准备核心目录，分别承接设置、片段和 Profile 导出内容。
    $settingsDirectory = Join-Path $RepositoryPath 'settings'
    $snippetsDirectory = Join-Path $RepositoryPath 'snippets'
    $profilesDirectory = Join-Path $RepositoryPath 'profiles'
    Initialize-Directory -Path $settingsDirectory
    Initialize-Directory -Path $snippetsDirectory
    Initialize-Directory -Path $profilesDirectory

    # 复制全局设置与快捷键文件。
    Copy-ConfigurationFile -SourcePath (Join-Path $SourceUserDirectory 'settings.json') -DestinationPath (Join-Path $settingsDirectory 'settings.json')
    Copy-ConfigurationFile -SourcePath (Join-Path $SourceUserDirectory 'keybindings.json') -DestinationPath (Join-Path $settingsDirectory 'keybindings.json')

    # 复制用户代码片段，保留原有目录结构。
    Copy-ConfigurationDirectory `
        -SourcePath (Join-Path $SourceUserDirectory 'snippets') `
        -DestinationPath $snippetsDirectory `
        -AllowedExtensions @('.json', '.code-snippets') `
        -ExcludedDirectoryNames @('globalStorage', 'History', 'workspaceStorage')

    # 复制 Profile 中的安全文本配置，排除状态目录与数据库缓存。
    Copy-ConfigurationDirectory `
        -SourcePath (Join-Path $SourceUserDirectory 'profiles') `
        -DestinationPath $profilesDirectory `
        -AllowedExtensions @('.json') `
        -ExcludedDirectoryNames @('globalStorage', 'History', 'workspaceStorage')

    # 调用 VS Code CLI 获取带版本的扩展列表，并过滤空行。
    $extensionOutput = & $CodeCommand --list-extensions --show-versions
    if ($LASTEXITCODE -ne 0) {
        throw '调用 VS Code CLI 生成扩展清单失败。'
    }
    $extensions = @($extensionOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # 将扩展清单写入仓库根目录，供后续恢复脚本逐项安装。
    Set-Content -Path (Join-Path $RepositoryPath 'extensions.txt') -Value $extensions -Encoding UTF8

    Write-Host "已导出 VS Code 配置到：$RepositoryPath"
    Write-Host "扩展数量：$($extensions.Count)"
}

Export-VSCodeConfiguration -SourceUserDirectory $SourceUserDirectory -RepositoryPath $RepositoryPath -CodeCommand $CodeCommand