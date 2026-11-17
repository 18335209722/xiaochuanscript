# 小川 Chrome 个人资料助手 · Windows 版
# 新建一个「不登录 Google 账号」的 Chrome 个人资料（默认名字 claude），并用它打开 Chrome。
# 已经建过就直接打开。不动用户原来登录过的那个个人资料，只是不再用它。
# 建议在重启电脑之后执行。不需要管理员权限，直接双击 chrome-profile.bat 即可；
# 即使在管理员窗口里运行，Chrome 也会以普通权限启动。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [string]$Name = 'claude',
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$DataDir = Join-Path $env:USERPROFILE '.xiaochuan-env'
$ChromeData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
}

function Get-ChromeExe {
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) {
        if (-not $base) { continue }
        $exe = Join-Path $base 'Google\Chrome\Application\chrome.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Text([string]$Path) {
    try { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) } catch { return '' }
}

function Invoke-Main {
    if (-not $Name -or $Name.Contains('"') -or $Name.Contains('\')) {
        Write-Fail '个人资料名字不能为空，也不能包含引号或反斜杠。'; return 1
    }
    $exe = Get-ChromeExe
    if (-not $exe) { Write-Fail '没有找到 Google Chrome，请先安装。'; return 1 }

    # 记下这个名字对应哪个目录，下次执行就直接打开，不会重复新建。
    $record = Join-Path $DataDir ('chrome-profile-' + ($Name -replace '[^A-Za-z0-9_-]', '_'))
    $dir = ''
    if (Test-Path -LiteralPath $record) {
        $dir = (Read-Text $record).Trim()
        if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $ChromeData $dir))) { $dir = '' }
    }

    if ($dir) {
        Write-Log "个人资料「$Name」已经建过（$dir），直接打开。"
        if ($DryRun) { Write-Log "（演练）用个人资料「$Name」（$dir）打开 Chrome"; return 0 }
    } else {
        $n = 1
        while (Test-Path -LiteralPath (Join-Path $ChromeData "Profile $n")) { $n++ }
        $dir = "Profile $n"
        if ($DryRun) {
            Write-Log "（演练）新建 Chrome 个人资料「$Name」（目录 $dir，不登录账号，语言只有英文），并用它打开 Chrome"
            return 0
        }
        # 提前写好这份配置，Chrome 第一次用这个目录时就会按它建个人资料：
        # 名字是指定的名字，不登录任何账号，语言只有英文。
        $json = '{"profile":{"name":"' + $Name + '","using_default_name":false},' +
            '"intl":{"accept_languages":"en-US,en","selected_languages":"en-US,en"},' +
            '"spellcheck":{"dictionaries":["en-US"]},"translate_blocked_languages":["en"],"translate_recent_target":"en"}'
        $utf8 = New-Object Text.UTF8Encoding($false)
        try {
            $profileDir = Join-Path $ChromeData $dir
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
            [IO.File]::WriteAllText((Join-Path $profileDir 'Preferences'), $json, $utf8)
            New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
            [IO.File]::WriteAllText($record, $dir, $utf8)
        } catch {
            Write-Fail "创建个人资料失败：$($_.Exception.Message)"; return 1
        }
        Write-Log "已新建个人资料「$Name」（$dir），未登录任何账号。"
    }

    Write-Log "正在用个人资料「$Name」打开 Chrome…"
    $chromeArgs = '--profile-directory="' + $dir + '" --no-first-run --no-default-browser-check'
    try {
        if (Test-Elevated) {
            # 当前是管理员权限的窗口：直接启动的话 Chrome 也会带管理员权限。
            # 改成建一个快捷方式交给资源管理器去打开，这样 Chrome 以普通权限运行。
            New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
            $lnk = Join-Path $DataDir 'chrome-profile.lnk'
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
            $shortcut.TargetPath = $exe
            $shortcut.Arguments = $chromeArgs
            $shortcut.Save()
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $lnk + '"')
        } else {
            Start-Process -FilePath $exe -ArgumentList $chromeArgs
        }
    } catch {
        Write-Fail "Chrome 启动失败：$($_.Exception.Message)"; return 1
    }

    # 核对：Chrome 把这个个人资料登记进 Local State，并且名字是对的，才算成功。
    $localState = Join-Path $ChromeData 'Local State'
    $quotedDir = '"' + $dir + '"'
    $text = ''
    for ($i = 0; $i -lt 20; $i++) {
        $text = Read-Text $localState
        if ($text.Contains($quotedDir)) { break }
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Write-Host '执行后检查：'
    if (-not $text.Contains($quotedDir)) {
        Write-Host "  × Chrome 没有登记个人资料 $dir（可能没有成功启动）" -ForegroundColor Red
        return 1
    }
    $namePattern = '"name"\s*:\s*"' + [regex]::Escape($Name) + '"'
    $inLocalState = $text -match ([regex]::Escape($quotedDir) + '\s*:\s*\{[^}]*' + $namePattern)
    $inPrefs = (Read-Text (Join-Path (Join-Path $ChromeData $dir) 'Preferences')) -match $namePattern
    if (-not ($inLocalState -or $inPrefs)) {
        Write-Host "  × 个人资料 $dir 已打开，但名字不是「$Name」；可在 Chrome 右上角头像 > 齿轮 里手动改名" -ForegroundColor Red
        return 1
    }
    Write-Host "  √ Chrome 已用个人资料「$Name」（$dir）打开，未登录账号"
    Write-Log '以后直接点 Chrome 图标，默认也会进入这个个人资料（Chrome 会记住最后使用的那个）。'
    return 0
}

if ($Help) {
    Write-Host @"
小川 Chrome 个人资料助手 $Version（Windows）

新建一个不登录 Google 账号的 Chrome 个人资料并用它打开 Chrome；已经建过就直接打开。

用法：
  双击 chrome-profile.bat                 新建 / 打开名字叫 claude 的个人资料
  chrome-profile.bat -Name 名字           换一个名字
  chrome-profile.bat -DryRun              演练：只显示将要做的事，不做任何修改
"@
    exit 0
}

$code = 1
try { $code = Invoke-Main } catch { Write-Fail "脚本出错：$($_.Exception.Message)" }
exit $code
