<#
.SYNOPSIS
导出脚本测试文件。

.DESCRIPTION
验证导出脚本会拒绝包含疑似敏感信息的配置，并能在安全输入下正确导出 VS Code 用户配置与扩展清单。
#>

$scriptPath = Join-Path $PSScriptRoot '..\scripts\Export-VSCodeConfig.ps1'

<#
.SYNOPSIS
创建用于测试的伪造 VS Code CLI 命令。

.DESCRIPTION
生成一个批处理文件，用于模拟 `code --list-extensions --show-versions` 的输出。

.PARAMETER CommandPath
伪造命令文件的完整路径。

.PARAMETER OutputLines
命令执行时输出的扩展清单内容。

.OUTPUTS
System.String
返回生成的命令文件路径。
#>
function New-FakeCodeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandPath,

        [Parameter(Mandatory = $true)]
        [string[]] $OutputLines
    )

    # 生成批处理文件内容，用于稳定返回扩展列表。
    $content = @(
        '@echo off'
    ) + $OutputLines.ForEach({ "echo $_" })

    # 将伪造命令写入测试目录，供被测脚本调用。
    Set-Content -Path $CommandPath -Value $content -Encoding ASCII

    return $CommandPath
}
Describe 'Export-VSCodeConfig.ps1' {
    It '在发现疑似敏感配置时终止导出' {
        # 准备源目录和目标目录，模拟用户配置与仓库目录。
        $source = Join-Path $TestDrive 'source'
        $repository = Join-Path $TestDrive 'repository'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path $repository -ItemType Directory -Force | Out-Null

        # 写入带有可疑令牌字段的配置文件，触发安全检查。
        Set-Content -Path (Join-Path $source 'settings.json') -Encoding UTF8 -Value @'
{
  "github.token": "abc"
}
'@

        # 准备一个最小可用的伪造 code 命令，避免因 CLI 缺失导致误报。
        $fakeCode = New-FakeCodeCommand -CommandPath (Join-Path $TestDrive 'code.cmd') -OutputLines @('publisher.extension@1.0.0')

        # 断言脚本会因敏感信息而失败，并且不会写出 settings 备份文件。
        $threw = $false
        try {
            & $scriptPath -SourceUserDirectory $source -RepositoryPath $repository -CodeCommand $fakeCode
        }
        catch {
            $threw = $true
            $_.Exception.Message | Should Match '敏感信息'
        }
        $threw | Should Be $true
        (Test-Path (Join-Path $repository 'settings\settings.json')) | Should Be $false
    }

    It '在配置安全时导出设置、代码片段、Profile 与扩展清单' {
        # 准备源目录结构，模拟真实的 VS Code 用户目录。
        $source = Join-Path $TestDrive 'source'
        $repository = Join-Path $TestDrive 'repository'
        $snippets = Join-Path $source 'snippets'
        $profileSettings = Join-Path $source 'profiles\default'
        New-Item -Path $snippets -ItemType Directory -Force | Out-Null
        New-Item -Path $profileSettings -ItemType Directory -Force | Out-Null
        New-Item -Path $repository -ItemType Directory -Force | Out-Null

        # 写入安全的设置、快捷键、代码片段和 Profile 配置。
        Set-Content -Path (Join-Path $source 'settings.json') -Encoding UTF8 -Value @'
{
  "editor.fontSize": 16
}
'@
        Set-Content -Path (Join-Path $source 'keybindings.json') -Encoding UTF8 -Value @'
[
  {
    "key": "ctrl+alt+t",
    "command": "workbench.action.terminal.toggleTerminal"
  }
]
'@
        Set-Content -Path (Join-Path $snippets 'python.code-snippets') -Encoding UTF8 -Value @'
{
  "Print": {
    "prefix": "pp",
    "body": "print($1)"
  }
}
'@
        Set-Content -Path (Join-Path $profileSettings 'settings.json') -Encoding UTF8 -Value @'
{
  "workbench.colorTheme": "Default Dark+"
}
'@

        # 构造扩展清单输出，验证脚本会写入版本化扩展列表。
        $fakeCode = New-FakeCodeCommand -CommandPath (Join-Path $TestDrive 'code.cmd') -OutputLines @(
            'publisher.extension@1.0.0',
            'publisher.another@2.0.0'
        )

        # 执行导出脚本，生成仓库备份内容。
        & $scriptPath -SourceUserDirectory $source -RepositoryPath $repository -CodeCommand $fakeCode

        # 断言关键文件已被导出，并且扩展清单内容正确。
        (Test-Path (Join-Path $repository 'settings\settings.json')) | Should Be $true
        (Test-Path (Join-Path $repository 'settings\keybindings.json')) | Should Be $true
        (Test-Path (Join-Path $repository 'snippets\python.code-snippets')) | Should Be $true
        (Test-Path (Join-Path $repository 'profiles\default\settings.json')) | Should Be $true
        (Get-Content -Path (Join-Path $repository 'extensions.txt')) | Should Be @(
            'publisher.extension@1.0.0',
            'publisher.another@2.0.0'
        )
    }
}