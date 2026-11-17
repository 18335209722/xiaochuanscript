# 小川 Clash Verge 安装助手 · Windows 版
# 检查电脑上有没有装 Clash Verge Rev（https://github.com/clash-verge-rev/clash-verge-rev）：
#   已经装了：不再安装（桌面上没有快捷方式的话补建一个）。
#   没有装：找到适合本机系统的最新版，下载、校验、安装，建桌面快捷方式，然后打开。
# 执行过程中会显示现在做到第几步，下载时显示下载进度。
# 直接双击 clash-verge.bat 即可，不用「以管理员身份运行」；安装那一步 Windows 会弹一次 UAC，点「是」。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$DownloadOnly,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Repo = 'clash-verge-rev/clash-verge-rev'
$ReleasesPage = "https://github.com/$Repo/releases/latest"
# GitHub 直连下载失败或太慢时用的镜像。镜像不是官方的，所以只有在拿到官方校验值
# 并且下载下来的文件校验一致时才会使用。
$Mirrors = 'https://gh-proxy.com/', 'https://ghfast.top/'
# 下载速度连续 20 秒低于这个值（字节/秒）就换下一个下载地址。
$MinSpeed = 100000
$TotalSteps = 5

$script:AssetName = ''
$script:AssetUrl = ''
$script:AssetSha = ''
$script:AssetSize = 0
$script:ReleaseTag = ''

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Note([string]$Message) {
    Write-Host ("[{0}] 注意：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
}
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
}

# 显示现在做到第几步。
function Write-Step([int]$Number, [string]$Title) {
    Write-Host ''
    Write-Host ("==== 第 {0}/{1} 步：{2} ====" -f $Number, $TotalSteps, $Title) -ForegroundColor Cyan
}

# 安装包大小的文字说明，例如「（约 45 MB）」；不知道大小就是空的。
function Get-SizeText {
    if ($script:AssetSize -gt 0) { return ('（约 {0} MB）' -f [int][Math]::Round($script:AssetSize / 1MB)) }
    return ''
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- 检测

# 找到已安装的 Clash Verge 主程序；没装返回 $null。
function Get-ClashExe {
    $dirs = New-Object System.Collections.ArrayList
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($item in @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)) {
        if ([string]$item.DisplayName -notmatch '^Clash Verge') { continue }
        $loc = ([string]$item.InstallLocation).Trim().Trim('"')
        if ($loc) { [void]$dirs.Add($loc) }
    }
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs')) {
        if ($base) { [void]$dirs.Add((Join-Path $base 'Clash Verge')) }
    }
    foreach ($dir in $dirs) {
        foreach ($name in 'clash-verge.exe', 'Clash Verge.exe') {
            $exe = Join-Path $dir $name
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return $null
}

function Test-ClashRunning {
    return [bool](Get-Process -Name 'clash-verge', 'Clash Verge' -ErrorAction SilentlyContinue)
}

# 本机该用哪个安装包：返回文件名的结尾部分；认不出返回 $null。
function Get-AssetSuffix {
    $arch = ''
    try { $arch = [string](Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture } catch { }
    if ($arch -eq '12' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        return '_arm64-setup.exe'
    }
    if ([Environment]::Is64BitOperatingSystem) { return '_x64-setup.exe' }
    return $null
}

# ---------------------------------------------------------------- 找最新版

# 找到本机要下载的安装包，结果放进 $script:AssetName / AssetUrl / AssetSha / AssetSize / ReleaseTag。
# 先问 GitHub 接口（能拿到校验值）；接口不通就从「最新版」页面的跳转地址里取版本号，自己拼文件名。
function Find-Asset([string]$Suffix) {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 40 `
            -UseBasicParsing -UserAgent 'curl' -Headers @{ 'Accept' = 'application/vnd.github+json' }
        foreach ($a in @($rel.assets)) {
            if (([string]$a.name).EndsWith($Suffix)) {
                $script:ReleaseTag = [string]$rel.tag_name
                $script:AssetName = [string]$a.name
                $script:AssetUrl = [string]$a.browser_download_url
                $script:AssetSha = ([string]$a.digest) -replace '^sha256:', ''
                try { $script:AssetSize = [long]$a.size } catch { $script:AssetSize = 0 }
                return $true
            }
        }
    } catch { }

    try {
        $req = [Net.WebRequest]::Create($ReleasesPage)
        $req.Method = 'HEAD'
        $req.UserAgent = 'curl'
        $req.Timeout = 40000
        $resp = $req.GetResponse()
        $final = $resp.ResponseUri.AbsoluteUri
        $resp.Close()
    } catch { return $false }
    if ($final -notmatch '/tag/(v[0-9][^/]*)$') { return $false }
    $tag = $Matches[1]
    $script:ReleaseTag = $tag
    $script:AssetName = 'Clash.Verge_' + $tag.Substring(1) + $Suffix
    $script:AssetUrl = "https://github.com/$Repo/releases/download/$tag/$($script:AssetName)"
    $script:AssetSha = ''
    $script:AssetSize = 0
    return $true
}

# ---------------------------------------------------------------- 下载

# $MinSpeed：最低速度（字节/秒）。大于 0 时，连续 20 秒低于它就放弃，好换下一个下载地址；
# 等于 0 表示不限速度、断了自动续传（最后兜底时用）。下载时屏幕上会显示进度条和百分比。
function Get-File([string]$Url, [string]$Out, [int]$MinSpeed) {
    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $curlArgs = @('-fL', '--progress-bar', '-o', $Out)
        if ($MinSpeed -gt 0) {
            $curlArgs += @('--connect-timeout', '20', '--retry', '2', '--speed-limit', "$MinSpeed", '--speed-time', '20')
        } else {
            $curlArgs += @('--connect-timeout', '30', '--retry', '5', '--retry-delay', '3', '-C', '-')
        }
        # curl 的进度条写在错误输出里，这里临时放宽，免得被当成脚本出错。
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $curl.Source @curlArgs $Url | Out-Host
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $old
        return ($rc -eq 0 -and (Test-Path -LiteralPath $Out))
    }
    # 很老的 Windows 没有 curl.exe：用 PowerShell 自己下载（窗口顶部会显示进度）。
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -UserAgent 'curl'
        return (Test-Path -LiteralPath $Out)
    } catch { return $false }
}

# 文件校验值是否和官方的一致：'ok' / 'bad'；没有官方校验值时返回 'none'。
function Test-Checksum([string]$Path) {
    if (-not $script:AssetSha) { return 'none' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $script:AssetSha) { return 'ok' }
    return 'bad'
}

# 从一个地址下载并校验。$MustVerify：必须校验通过才算数（镜像用）。
function Get-FromSource([string]$Url, [string]$Out, [int]$MinSpeed, [bool]$MustVerify) {
    if (Get-File $Url $Out $MinSpeed) {
        $state = Test-Checksum $Out
        if ($state -eq 'ok') { Write-Log '下载完成，校验值和官方一致。'; return $true }
        if ($state -eq 'none' -and -not $MustVerify) {
            Write-Note '下载完成，但没拿到官方校验值，无法校验（文件来自 GitHub 官方地址）。'
            return $true
        }
        Write-Note '下载的文件校验值和官方不一致，已丢弃。'
    } else {
        Write-Note '这个下载地址连不上或者太慢。'
    }
    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    return $false
}

# 下载安装包：先 GitHub 直连；太慢或失败就换镜像；镜像也不行就回到直连、不限速度下完。
# 能校验的一律校验。
function Get-Asset([string]$Out) {
    Write-Log "正在从 GitHub 下载 $($script:AssetName)$(Get-SizeText) …"
    if (Get-FromSource $script:AssetUrl $Out $MinSpeed $false) { return $true }

    if ($script:AssetSha) {
        foreach ($m in $Mirrors) {
            Write-Log "换镜像下载：$m"
            if (Get-FromSource ($m + $script:AssetUrl) $Out $MinSpeed $true) { return $true }
        }
    } else {
        Write-Note '没有官方校验值，不使用镜像（无法确认文件没被改过）。'
    }

    Write-Log '回到 GitHub 直连再试一次，这次不限速度，慢也会下完，请耐心等待…'
    return (Get-FromSource $script:AssetUrl $Out 0 $false)
}

# ---------------------------------------------------------------- 安装 / 快捷方式 / 打开

function Wait-Installed([int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Get-ClashExe) { return $true }
        Start-Sleep -Seconds 1
    }
    return [bool](Get-ClashExe)
}

# 先静默安装；没装上就打开普通的安装界面让用户点。每种方式做完都核对是否真的装上了。
function Install-Clash([string]$Installer) {
    Write-Log '安装需要管理员权限：弹出「用户账户控制」窗口时请点「是」。'
    try {
        # /S：静默安装，不用一步步点「下一步」。
        $p = Start-Process -FilePath $Installer -ArgumentList '/S' -Verb RunAs -Wait -PassThru
        if (Wait-Installed 30) { return $true }
        Write-Note "静默安装没有成功（退出码 $($p.ExitCode)），改为打开安装界面。"
    } catch {
        Write-Note "静默安装没有启动（$($_.Exception.Message)），改为打开安装界面。"
    }
    try {
        Write-Log '请在弹出的安装界面里一路点「下一步」完成安装，装完后脚本会继续。'
        Start-Process -FilePath $Installer -Verb RunAs -Wait
    } catch {
        Write-Fail "安装程序没有运行（$($_.Exception.Message)）。如果是 UAC 点了「否」，请重新运行并点「是」。"
        return $false
    }
    return (Wait-Installed 30)
}

# 桌面上有没有 Clash Verge 的快捷方式（自己的桌面和「公用桌面」都算）；有就返回它的路径。
function Get-DesktopShortcut {
    foreach ($folder in 'Desktop', 'CommonDesktopDirectory') {
        $dir = [Environment]::GetFolderPath($folder)
        if (-not $dir) { continue }
        $lnk = Join-Path $dir 'Clash Verge.lnk'
        if (Test-Path -LiteralPath $lnk) { return $lnk }
    }
    return $null
}

# 保证桌面上有 Clash Verge 的快捷方式图标。返回 'exists'（本来就有）/ 'created'（新建了）/ 'failed'。
function Set-DesktopShortcut([string]$Exe) {
    if (Get-DesktopShortcut) { return 'exists' }
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clash Verge.lnk'
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $shortcut.TargetPath = $Exe
        $shortcut.WorkingDirectory = Split-Path -Parent $Exe
        $shortcut.IconLocation = "$Exe,0"
        $shortcut.Description = 'Clash Verge'
        $shortcut.Save()
    } catch { }
    if (Get-DesktopShortcut) { return 'created' }
    return 'failed'
}

function Open-Clash([string]$Exe) {
    if (Test-Elevated) {
        # 当前是管理员权限的窗口：直接启动的话 Clash Verge 也会带管理员权限，
        # 交给资源管理器去打开，它就以普通权限运行。
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Exe + '"')
    } else {
        Start-Process -FilePath $Exe
    }
}

# ---------------------------------------------------------------- 主流程

function Invoke-Main {
    Write-Step 1 '检查有没有装 Clash Verge'
    $exe = Get-ClashExe
    if (-not $DownloadOnly -and $exe) {
        Write-Log "这台电脑已经装了 Clash Verge（$exe），不需要再安装，后面的步骤跳过。"
        if ($DryRun) {
            if (-not (Get-DesktopShortcut)) { Write-Log '（演练）桌面上没有 Clash Verge 的快捷方式，会补建一个' }
            return 0
        }
        $state = Set-DesktopShortcut $exe
        if ($state -eq 'created') { Write-Log '桌面上原来没有 Clash Verge 的快捷方式，已经补建了一个。' }
        elseif ($state -eq 'failed') { Write-Fail '桌面快捷方式没有建成。'; return 1 }
        return 0
    }
    if ($DownloadOnly) { Write-Log '只下载安装包，不安装。' } else { Write-Log '这台电脑还没有装 Clash Verge。' }

    Write-Step 2 '查找适合本机的最新版'
    $suffix = Get-AssetSuffix
    if (-not $suffix) {
        Write-Fail "Clash Verge 不支持 32 位 Windows。详情见 $ReleasesPage"
        return 1
    }
    if (-not (Find-Asset $suffix)) {
        Write-Fail "连不上 GitHub，查不到最新版。请检查网络，或到 $ReleasesPage 手动下载。"
        return 1
    }
    Write-Log "最新版是 $($script:ReleaseTag)，适合本机的安装包：$($script:AssetName)$(Get-SizeText)"

    if ($DryRun) {
        Write-Log "（演练）第 3 步：下载 $($script:AssetUrl)"
        if (-not $DownloadOnly) { Write-Log '（演练）第 4、5 步：校验后安装，建桌面快捷方式，并打开 Clash Verge' }
        return 0
    }

    Write-Step 3 '下载安装包（下面会显示下载进度）'
    $tmpDir = ''
    try {
        if ($DownloadOnly) {
            $outDir = Join-Path $env:USERPROFILE 'Downloads'
        } else {
            $tmpDir = Join-Path $env:TEMP ('xc-clash-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $outDir = $tmpDir
        }
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $out = Join-Path $outDir $script:AssetName

        if (-not (Get-Asset $out)) {
            Write-Fail "安装包下载失败。请检查网络，或到 $ReleasesPage 手动下载 $($script:AssetName)。"
            return 1
        }
        if ($DownloadOnly) {
            Write-Log "安装包已保存到：$out"
            return 0
        }

        Write-Step 4 '安装'
        if (-not (Install-Clash $out)) {
            Write-Fail '安装没有成功：装完后找不到 Clash Verge 主程序。'
            return 1
        }
        Write-Log '安装完成。'
    } finally {
        if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step 5 '建桌面快捷方式，打开 Clash Verge 并检查'
    $exe = Get-ClashExe
    $shortcutState = Set-DesktopShortcut $exe
    if (-not (Test-ClashRunning)) {
        Write-Log '正在打开 Clash Verge…'
        try { Open-Clash $exe } catch { Write-Note "启动时出错：$($_.Exception.Message)" }
        for ($i = 0; $i -lt 20 -and -not (Test-ClashRunning); $i++) { Start-Sleep -Seconds 1 }
    }

    $code = 0
    Write-Host ''
    Write-Host '执行后检查：'
    Write-Host "  √ Clash Verge $($script:ReleaseTag) 已安装（$exe）"
    if ($shortcutState -eq 'failed') {
        Write-Host '  × 桌面快捷方式没有建成，可以从开始菜单里找到 Clash Verge' -ForegroundColor Red
        $code = 1
    } else {
        Write-Host "  √ 桌面上有 Clash Verge 的快捷方式（$(Get-DesktopShortcut)）"
    }
    if (Test-ClashRunning) {
        Write-Host '  √ Clash Verge 已打开'
    } else {
        Write-Host '  × Clash Verge 没有成功打开，请双击桌面上的图标手动打开一次' -ForegroundColor Red
        $code = 1
    }
    return $code
}

if ($Help) {
    Write-Host @"
小川 Clash Verge 安装助手 $Version（Windows）

检查有没有装 Clash Verge Rev；没装就下载适合本机的最新版，安装、建桌面快捷方式并打开。
已经装了就不再安装（桌面上没有快捷方式的话会补建一个）。

用法：
  双击 clash-verge.bat                检查，没装就安装并打开
  clash-verge.bat -DryRun             演练：只显示将要下载哪个安装包，不下载也不安装
  clash-verge.bat -DownloadOnly       只下载并校验安装包（保存到「下载」文件夹），不安装
"@
    exit 0
}

$code = 1
try { $code = Invoke-Main } catch { Write-Fail "脚本出错：$($_.Exception.Message)" }
exit $code
