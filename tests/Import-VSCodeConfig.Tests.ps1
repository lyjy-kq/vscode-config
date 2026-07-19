<#
.SYNOPSIS
导入脚本测试文件。

.DESCRIPTION
验证导入脚本支持 `-WhatIf` 演练、会先创建备份，再恢复配置并安装扩展。
#>

$scriptPath = Join-Path $PSScriptRoot '..\scripts\Import-VSCodeConfig.ps1'

<#
.SYNOPSIS
创建用于测试的伪造 VS Code CLI 命令。

.DESCRIPTION
生成一个批处理文件，用于记录扩展安装命令，便于断言导入脚本的调用行为。

.PARAMETER CommandPath
伪造命令文件的完整路径。

.PARAMETER LogPath
记录命令参数的日志文件路径。

.OUTPUTS
System.String
返回生成的命令文件路径。
#>
function New-FakeInstallCodeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandPath,

        [Parameter(Mandatory = $true)]
        [string] $LogPath
    )

    # 生成会把收到的参数追加到日志中的批处理命令。
    $content = @(
        '@echo off',
        "echo %*>>`"$LogPath`""
    )

    # 将伪造命令写入测试目录，供被测脚本调用。
    Set-Content -Path $CommandPath -Value $content -Encoding ASCII

    return $CommandPath
}
Describe 'Import-VSCodeConfig.ps1' {
    It '在 WhatIf 模式下不修改目标配置' {
        # 准备仓库中的备份内容和现有目标配置。
        $repository = Join-Path $TestDrive 'repository'
        $target = Join-Path $TestDrive 'target'
        New-Item -Path (Join-Path $repository 'settings') -ItemType Directory -Force | Out-Null
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $repository 'settings\settings.json') -Encoding UTF8 -Value '{"editor.fontSize": 18}'
        Set-Content -Path (Join-Path $target 'settings.json') -Encoding UTF8 -Value '{"editor.fontSize": 12}'
        Set-Content -Path (Join-Path $repository 'extensions.txt') -Encoding UTF8 -Value 'publisher.extension@1.2.3'

        # 准备一个会记录安装命令的伪造 code 命令。
        $logPath = Join-Path $TestDrive 'install.log'
        $fakeCode = New-FakeInstallCodeCommand -CommandPath (Join-Path $TestDrive 'code.cmd') -LogPath $logPath

        # 以 WhatIf 模式运行，确认目标文件内容保持不变。
        & $scriptPath -RepositoryPath $repository -TargetUserDirectory $target -CodeCommand $fakeCode -WhatIf
        ((Get-Content -Raw -Path (Join-Path $target 'settings.json')).Trim()) | Should Be '{"editor.fontSize": 12}'
        (Test-Path $logPath) | Should Be $false
    }

    It '恢复配置前创建备份，并安装扩展' {
        # 准备仓库中的设置、代码片段和扩展清单。
        $repository = Join-Path $TestDrive 'repository'
        $target = Join-Path $TestDrive 'target'
        New-Item -Path (Join-Path $repository 'settings') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $repository 'snippets') -ItemType Directory -Force | Out-Null
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $repository 'settings\settings.json') -Encoding UTF8 -Value '{"editor.fontSize": 18}'
        Set-Content -Path (Join-Path $repository 'snippets\python.code-snippets') -Encoding UTF8 -Value '{"Print":{"prefix":"pp","body":"print($1)"}}'
        Set-Content -Path (Join-Path $repository 'extensions.txt') -Encoding UTF8 -Value 'publisher.extension@1.2.3'

        # 准备目标目录的旧配置，用于验证备份和覆盖恢复。
        Set-Content -Path (Join-Path $target 'settings.json') -Encoding UTF8 -Value '{"editor.fontSize": 12}'

        # 准备记录扩展安装命令的伪造 code 命令。
        $logPath = Join-Path $TestDrive 'install.log'
        $fakeCode = New-FakeInstallCodeCommand -CommandPath (Join-Path $TestDrive 'code.cmd') -LogPath $logPath

        # 运行导入脚本，执行备份、恢复和扩展安装。
        & $scriptPath -RepositoryPath $repository -TargetUserDirectory $target -CodeCommand $fakeCode

        # 断言备份目录已创建，目标配置被覆盖，扩展安装命令被调用。
        (Get-ChildItem -Path (Join-Path $repository 'backups') -Directory | Measure-Object).Count | Should Be 1
        ((Get-Content -Raw -Path (Join-Path $target 'settings.json')).Trim()) | Should Be '{"editor.fontSize": 18}'
        (Test-Path (Join-Path $target 'snippets\python.code-snippets')) | Should Be $true
        (Get-Content -Raw -Path $logPath) | Should Match '--install-extension publisher.extension@1.2.3 --force'
    }
}