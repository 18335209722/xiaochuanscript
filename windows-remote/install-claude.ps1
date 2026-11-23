# 小川 Claude 命令行安装助手 · Windows 版
# 下载并安装 Claude Code 命令行（claude），装完之后在命令窗口（PowerShell / cmd / SSH 远程登录进来的窗口）里
# 直接输入 claude 就能用：
#   1. 下载并安装 Claude Code（用 Anthropic 官方安装脚本 https://claude.ai/install.ps1，装到 用户目录\.local\bin\claude.exe）。
#      官方安装脚本用不了、而电脑上有 npm 时，改用 npm install -g @anthropic-ai/claude-code。已经装了就跳过。
#   2. 把 用户目录\.local\bin 加进这个用户的 PATH，这样任何命令窗口里都能直接输入 claude。
#   3. 检查 claude 能正常运行，显示版本号和用法。
# 直接双击 install-claude.bat 即可。不需要管理员权限，只装给当前这个 Windows 用户。重复执行没有副作用。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [switch]$Update,
    [switch]$Status,
    [switch]$DryRun,
    [switch]$Help,
    # 下面这个是脚本自己用的，不用手动传。
    [switch]$FromBat
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$InstallUrl = 'https://claude.ai/install.ps1'
$NpmPackage = '@anthropic-ai/claude-code'
$BinDir = Join-Path $env:USERPROFILE '.local\bin'
$Exe = Join-Path $BinDir 'claude.exe'
$PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:StepNo = 0
$script:TotalSteps = 3

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Note([string]$Message) {
    Write-Host ("[{0}] 注意：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
}
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
    Add-Bad $Message
}
function Write-Step([string]$Title) {
    $script:StepNo++
    Write-Host ''
    Write-Host ("==== 第 {0}/{1} 步：{2} ====" -f $script:StepNo, $script:TotalSteps, $Title) -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 结果汇总
$script:Results = New-Object System.Collections.ArrayList
$script:OkCount = 0
$script:BadCount = 0
function Add-Ok([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = 'ok'; Text = $Text }); $script:OkCount++ }
function Add-Bad([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = 'bad'; Text = $Text }); $script:BadCount++ }
function Add-Info([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = 'info'; Text = $Text }) }

function Show-Result {
    Write-Host ''
    Write-Host '================ 执行结果 ================'
    foreach ($r in $script:Results) {
        if ($r.Kind -eq 'ok') { Write-Host "  √ $($r.Text)" -ForegroundColor Green }
        elseif ($r.Kind -eq 'bad') { Write-Host "  × 没有完成：$($r.Text)" -ForegroundColor Red }
        else { Write-Host "  - $($r.Text)" }
    }
    Write-Host '=========================================='
    if ($script:BadCount -gt 0) {
        Write-Host " 结果：有 $($script:BadCount) 行没有完成（上面标 × 的红色行） " -ForegroundColor White -BackgroundColor Red
    } elseif ($script:OkCount -gt 0) {
        Write-Host ' 结果：全部完成 ' -ForegroundColor White -BackgroundColor DarkGreen
    } else {
        Write-Host ' 结果：没有做任何修改 ' -ForegroundColor Black -BackgroundColor Gray
    }
}

# 双击运行时，结束前停一下，免得结果一闪而过。
function Exit-Script([int]$Code) {
    if ($FromBat) {
        Write-Host ''
        Read-Host '按回车关闭窗口' | Out-Null
    }
    exit $Code
}

# ================================================================ 查找 / 版本

# 找到 claude 命令的位置：先看官方安装的位置，再看 PATH 里有没有（比如 npm 装的 claude.cmd）。没有返回空字符串。
function Find-Claude {
    if (Test-Path -LiteralPath $Exe -PathType Leaf) { return $Exe }
    $cmd = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return ''
}

# 运行 claude --version，返回形如「2.1.0 (Claude Code)」的一行；运行不了返回空字符串。
function Get-ClaudeVersion([string]$Path) {
    try {
        # 先把输出收完再取第一行：用 Select-Object -First 1 会提前掐断 claude，退出码就不准了。
        $out = @(& $Path --version)
        if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0 -and "$($out[0])" -match '\d+\.\d+\.\d+') { return "$($out[0])".Trim() }
    } catch { }
    return ''
}

# ================================================================ 第 1 步：下载并安装

# 用 Anthropic 官方安装脚本安装。脚本会从 downloads.claude.ai 下载 claude.exe 并核对校验值（SHA-256）。
function Install-Native {
    $tmp = Join-Path $env:TEMP ("claude-install-{0}.ps1" -f $PID)
    Write-Log "正在下载官方安装脚本：$InstallUrl"
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1 的进度条会把下载拖慢几十倍
    try {
        Invoke-WebRequest -Uri $InstallUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 60
    } catch {
        Write-Note "官方安装脚本没有下载下来：$($_.Exception.Message)"
        return $false
    } finally { $ProgressPreference = $oldPref }
    try {
        # 网络被拦截时拿到的可能是一个网页，不是安装脚本。
        $text = [IO.File]::ReadAllText($tmp)
        if ($text -match '(?i)<html' -or $text -notmatch 'claude-code-releases') {
            Write-Note '下载下来的不是官方安装脚本（可能是网络被拦截后返回的网页），不执行。'
            return $false
        }
        Write-Log '正在下载并安装 Claude Code（安装包 200 多 MB，网速慢时要等几分钟，请不要关窗口）…'
        & $PsExe -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) {
            Write-Note "官方安装脚本返回了错误码 $LASTEXITCODE。"
            return $false
        }
    } catch {
        Write-Note "官方安装脚本执行出错：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return (Test-Path -LiteralPath $Exe -PathType Leaf)
}

# 官方安装脚本用不了时的备用办法：电脑上有 npm 就用 npm 装。
function Install-WithNpm {
    $npm = Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) {
        Write-Log '这台电脑没有 npm（Node.js），不能用 npm 这个备用办法。'
        return $false
    }
    Write-Log "改用 npm 安装：npm install -g $NpmPackage"
    try {
        & $npm.Source install -g $NpmPackage
        if ($LASTEXITCODE -ne 0) { Write-Note "npm 返回了错误码 $LASTEXITCODE。"; return $false }
    } catch {
        Write-Note "npm 安装出错：$($_.Exception.Message)"
        return $false
    }
    return [bool](Find-Claude)
}

function Invoke-Install {
    Write-Step '下载并安装 Claude Code 命令行'
    $path = Find-Claude
    if ($path) {
        $ver = Get-ClaudeVersion $path
        if (-not $Update) {
            Write-Log "已经装了：$path（$ver），跳过安装。想升级到最新版可以加参数 -Update。"
            Add-Ok "Claude Code 已安装（之前就装了，$ver）"
            return $true
        }
        if ($DryRun) { Write-Log "演练：将会执行 claude update，把 $path 升级到最新版。"; return $true }
        Write-Log "正在升级（现在是 $ver）…"
        try {
            & $path update
            if ($LASTEXITCODE -ne 0) { throw "claude update 返回了错误码 $LASTEXITCODE" }
            Add-Ok "Claude Code 已升级到最新版（$(Get-ClaudeVersion $path)）"
        } catch { Write-Fail "升级没有成功：$($_.Exception.Message)" }
        return $true
    }
    if ($DryRun) {
        Write-Log "演练：将会用官方安装脚本 $InstallUrl 安装 Claude Code 到 $Exe（用不了时改用 npm）。"
        return $true
    }
    if (Install-Native) { Add-Ok "Claude Code 已安装（官方安装包，$Exe）"; return $true }
    if (Install-WithNpm) { Add-Ok 'Claude Code 已安装（用 npm 装的）'; return $true }
    Write-Fail 'Claude Code 没有装上。'
    Write-Host '    最常见的原因是网络：这台电脑要能访问 claude.ai 和 downloads.claude.ai。'
    Write-Host '    网络调好之后再执行一次本脚本；也可以手动安装，在 PowerShell 里执行：'
    Write-Host "      irm $InstallUrl | iex"
    return $false
}

# ================================================================ 第 2 步：PATH

# 目录是不是已经在 PATH 列表里（忽略大小写、结尾的反斜杠，环境变量展开后再比）。
function Test-InPathList([string]$List, [string]$Dir) {
    $want = $Dir.TrimEnd('\')
    foreach ($p in ("$List" -split ';')) {
        $p = [Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"')).TrimEnd('\')
        if ($p -and $p -eq $want) { return $true }
    }
    return $false
}

# 读注册表里 PATH 的原始值（不展开 %变量%）。$Scope 是 'User' 或 'Machine'。
function Get-RawPath([string]$Scope) {
    try {
        if ($Scope -eq 'User') { $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment') }
        else { $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment') }
        if (-not $key) { return '' }
        try { return "$($key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))" }
        finally { $key.Close() }
    } catch { return '' }
}

function Test-BinDirInPath {
    return ((Test-InPathList (Get-RawPath 'User') $BinDir) -or (Test-InPathList (Get-RawPath 'Machine') $BinDir))
}

# 把目录追加到当前用户的 PATH。直接改注册表原始值，保留原来的 %变量% 写法和值类型。
function Add-UserPath([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $old = "$($key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))"
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($old) { $kind = $key.GetValueKind('Path') }
        $new = $Dir
        if ($old.Trim(';')) { $new = $old.TrimEnd(';') + ';' + $Dir }
        $key.SetValue('Path', $new, $kind)
    } finally { $key.Close() }
    # 通知系统「环境变量变了」，这样之后新开的命令窗口不用注销就能用。
    # （.NET 设置用户环境变量时会广播 WM_SETTINGCHANGE；这里删一个本来就不存在的变量，只为了触发这次广播。）
    try { [Environment]::SetEnvironmentVariable('XIAOCHUAN_PATH_REFRESH', $null, 'User') } catch { }
}

function Invoke-Path {
    Write-Step '让命令窗口里能直接输入 claude（PATH）'
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        # npm 装的：claude 在 npm 的全局目录里，npm 安装 Node.js 时已经把它加进 PATH 了。
        if ($DryRun) { Write-Log "演练：安装之后会把 $BinDir 加进当前用户的 PATH。"; return }
        if (Find-Claude) { Add-Ok 'claude 已经在 PATH 里，命令窗口里可以直接用' }
        else { Write-Fail "PATH 里找不到 claude，命令窗口里不能直接用。" }
        return
    }
    if (Test-BinDirInPath) {
        Write-Log "$BinDir 已经在 PATH 里，不用改。"
        Add-Ok 'claude 已经在 PATH 里，命令窗口里可以直接用'
    } elseif ($DryRun) {
        Write-Log "演练：将会把 $BinDir 加进当前用户的 PATH。"
    } else {
        try {
            Add-UserPath $BinDir
            Add-Ok "已把 $BinDir 加进 PATH（新开的命令窗口里生效）"
        } catch { Write-Fail "PATH 没有改成：$($_.Exception.Message)"; return }
    }
    # 让本窗口接下来也能找到 claude。
    if (-not (Test-InPathList $env:Path $BinDir)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $BinDir }
}

# ================================================================ 第 3 步：检查

function Show-Usage {
    Write-Host ''
    Write-Host '---------------- 怎么用 ----------------' -ForegroundColor Cyan
    Write-Host '  1. 新开一个命令窗口（PowerShell 或 cmd 都行；SSH / Termius 远程登录的要断开重新登录）。'
    Write-Host '  2. 用 cd 进到要干活的目录，输入：' -NoNewline
    Write-Host '  claude' -ForegroundColor Green
    Write-Host '  3. 第一次用要登录：按屏幕提示在浏览器里登录 Claude 账户。'
    Write-Host '     远程登录（SSH）时这台电脑弹不出浏览器，把屏幕上显示的网址复制到自己电脑的浏览器里打开，'
    Write-Host '     登录后把网页给的代码粘贴回命令窗口。'
    Write-Host '  常用：claude --version 看版本；claude update 升级；claude -p "问题" 只问一句就退出。'
    Write-Host '  使用时这台电脑要能访问 Anthropic 的服务（claude.ai / api.anthropic.com）。'
    Write-Host '----------------------------------------' -ForegroundColor Cyan
}

# Claude Code 在 Windows 上执行命令时可以用 Git Bash；没装也能用 PowerShell，这里只是提醒一下。
function Test-GitBash {
    if (Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    foreach ($d in $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'Git\bin\bash.exe'))) { return $true }
    }
    return $false
}

function Invoke-Check {
    Write-Step '检查 claude 能正常运行'
    if ($DryRun) { Write-Log '演练：将会执行 claude --version 检查。'; return }
    $path = Find-Claude
    if (-not $path) { Write-Fail '没有找到 claude 命令。'; return }
    $ver = Get-ClaudeVersion $path
    if (-not $ver) { Write-Fail "claude 运行不了：$path --version 没有返回版本号。"; return }
    Add-Ok "claude 可以正常运行：$ver"
    if (-not (Test-GitBash)) {
        Add-Info '这台电脑没有装 Git for Windows。启动 claude 时如果提示需要 git-bash，到 https://git-scm.com/download/win 装一下'
    }
    Show-Usage
}

# ================================================================ 查看状态

function Show-Status {
    Write-Host "小川 Claude 命令行安装助手 $Version（Windows）· 当前状态"
    $path = Find-Claude
    if (-not $path) {
        Write-Host '  × Claude Code：没有安装' -ForegroundColor Red
        return 1
    }
    $bad = 0
    Write-Host "  √ Claude Code：已安装（$path）" -ForegroundColor Green
    $ver = Get-ClaudeVersion $path
    if ($ver) { Write-Host "  √ 版本：$ver" -ForegroundColor Green }
    else { Write-Host '  × 版本：claude --version 运行不了' -ForegroundColor Red; $bad++ }
    if ($path -ne $Exe -or (Test-BinDirInPath)) { Write-Host '  √ PATH：命令窗口里可以直接输入 claude' -ForegroundColor Green }
    else { Write-Host "  × PATH：$BinDir 不在 PATH 里，命令窗口里不能直接输入 claude（再执行一次本脚本就会加上）" -ForegroundColor Red; $bad++ }
    if (Test-GitBash) { Write-Host '  - Git for Windows：已安装' } else { Write-Host '  - Git for Windows：没有安装（不是必须的）' }
    return $bad
}

# ================================================================ 主流程

if ($Help) {
    Write-Host @"
小川 Claude 命令行安装助手 $Version（Windows）

下载并安装 Claude Code 命令行，装完之后在命令窗口（PowerShell / cmd / SSH 远程登录进来的窗口）里
直接输入 claude 就能用。不需要管理员权限，只装给当前这个 Windows 用户。

用法：
  双击 install-claude.bat               安装 Claude Code，并让命令窗口里能直接输入 claude（已经装了就跳过）
  install-claude.bat -Update            已经装了的话，升级到最新版
  install-claude.bat -Status            只查看现在的状态，不做任何修改
  install-claude.bat -DryRun            演练：只显示将要做的事，不做任何修改
"@
    Exit-Script 0
}

if ($Status) {
    $bad = 1
    try { $bad = Show-Status } catch { Write-Host "查看状态时出错：$($_.Exception.Message)" -ForegroundColor Red }
    if ($bad -gt 0) { Exit-Script 1 }
    Exit-Script 0
}

if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }

try {
    if (Invoke-Install) {
        Invoke-Path
        Invoke-Check
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
}

Show-Result
if ($script:BadCount -gt 0) { Exit-Script 1 }
Exit-Script 0
