# 小川强制代理助手 · Windows 脚本版
# 按《Windows Claude 强制代理实施方案》把 Claude Code / Claude Desktop 固定到 Clash 本地代理上：
#   找到 Clash 本地代理端口并测试、下载安装 Proxifier 并写入 Claude 专用规则、
#   给 Claude Code 写入自身代理设置、用 Windows 防火墙做 Kill Switch（代理失效时不能直连）、
#   可选：让 Chrome / Edge 的 Claude 网站强制走代理。其他软件保持原有网络方式。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [ValidateSet('', 'status', 'undo')]
    [string]$Action = '',
    [switch]$Proxifier,
    [switch]$ClaudeCode,
    [switch]$KillSwitch,
    [switch]$Browser,
    [switch]$All,
    [int]$ProxyPort = 0,
    [ValidateSet('', 'socks5', 'http')]
    [string]$ProxyType = '',
    [ValidateSet('claude', 'all')]
    [string]$BrowserMode = 'claude',
    [switch]$LocalDns,
    [switch]$IncludeNode,
    [switch]$DryRun,
    [switch]$Help,
    # 以下两个是脚本自己提权重启时用的，不需要手动传。
    [switch]$Elevated,
    [string]$OrigUser = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$ProxyHost = '127.0.0.1'
$TestUrl = 'https://api.anthropic.com/'
# 这些域名：Proxifier 里通过代理解析（不走本机 DNS），浏览器里强制走代理。
$ClaudeDomains = @('claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com')

$ProxifierUrl = 'https://www.proxifier.com/download/ProxifierSetup.exe'
$ClashApi = 'https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest'
$ClashFallbackVer = '2.5.10'

$DataDir = Join-Path $env:USERPROFILE '.xiaochuan-env'
$DownloadDir = Join-Path $DataDir 'downloads'
$ClaudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
$PxProfileDir = Join-Path $env:APPDATA 'Proxifier4\Profiles'
$PxProfileName = 'xiaochuan-claude.ppx'
$PxMarker = 'xiaochuan-proxy'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'XiaochuanProxifier'
$FwGroup = 'Xiaochuan Claude Proxy'
# 防火墙只拦「非本机」地址：Claude 到本机 Clash / Proxifier 的连接（127.0.0.1、::1）不受影响。
$FwRemote = @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255', '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
$BrowserKeys = @(
    [pscustomobject]@{ Name = 'Chrome'; Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome' },
    [pscustomobject]@{ Name = 'Edge'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
)
$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'

$script:Errors = 0
$script:BackupDir = ''
$script:DoPx = $false
$script:DoCode = $false
$script:DoKs = $false
$script:DoBrowser = $false
$script:StatusBad = 0
# 找到的 Clash 本地代理：SocksPort / HttpPort 为 0 表示没有这种入口。
$script:Px = $null

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Note([string]$Message) { Write-Host ("[{0}] 注意：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow }
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
    $script:Errors++
    Add-Bad $Message
}

# ---------------------------------------------------------------- 结果汇总
$script:Results = New-Object System.Collections.ArrayList
$script:OkCount = 0
$script:BadCount = 0
function Add-Ok([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "ok"; Text = $Text }); $script:OkCount++ }
function Add-Bad([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "bad"; Text = $Text }); $script:BadCount++ }
function Add-Info([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "info"; Text = $Text }) }
function Write-Skip([string]$Message) { Write-Log $Message; Add-Info $Message }

function Show-Result {
    Write-Host ""
    Write-Host "================ 执行结果 ================"
    foreach ($r in $script:Results) {
        if ($r.Kind -eq "ok") { Write-Host "  √ $($r.Text)" -ForegroundColor Green }
        elseif ($r.Kind -eq "bad") { Write-Host "  × 没有完成：$($r.Text)" -ForegroundColor Red }
        else { Write-Host "  - $($r.Text)" }
    }
    Write-Host "=========================================="
    if ($script:BadCount -gt 0) {
        Write-Host " 结果：有 $($script:BadCount) 行没有完成（上面标 × 的红色行） " -ForegroundColor White -BackgroundColor Red
    } elseif ($script:OkCount -gt 0) {
        Write-Host " 结果：全部完成 " -ForegroundColor White -BackgroundColor DarkGreen
    } else {
        Write-Host " 结果：没有做任何修改 " -ForegroundColor Black -BackgroundColor Gray
    }
}

# 调用外部命令并收集全部输出。PowerShell 5.1 在 ErrorActionPreference=Stop 时，
# 外部命令只要往 stderr 写一行就会被当成异常抛出，所以这里临时改成 Continue。
function Invoke-Native([scriptblock]$Block) {
    $ErrorActionPreference = 'Continue'
    $lines = & $Block 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    }
    return (($lines | Out-String).Trim())
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Backup-File([string]$Source, [string]$Relative) {
    if ($DryRun -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $dest = Join-Path $script:BackupDir $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $dest -Force
}

# ------------------------------------------------------- Clash 本地代理入口

# 往本机某个端口发一段数据，返回对方回的头几个字节；连不上或没回应返回空数组。
function Send-Probe([int]$Port, [byte[]]$Data, [int]$TimeoutMs) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($ProxyHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(800)) { return ,@() }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.Write($Data, 0, $Data.Length)
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return ,@() }
        return ,([byte[]]($buf[0..($n - 1)]))
    } catch {
        return ,@()
    } finally {
        $client.Close()
    }
}

# 这个端口是不是不用密码的 SOCKS5 入口。
function Test-Socks5([int]$Port) {
    $r = Send-Probe $Port ([byte[]](5, 1, 0)) 1500
    return ($r.Count -ge 2 -and $r[0] -eq 5 -and $r[1] -eq 0)
}

# 这个端口是不是 HTTP 代理入口（支持 CONNECT）。返回状态码，不是 HTTP 代理返回 0。
# 200 表示通；502 / 503 / 504 表示入口是对的，但后面的节点不通。
function Get-HttpConnectCode([int]$Port) {
    $req = [Text.Encoding]::ASCII.GetBytes("CONNECT api.anthropic.com:443 HTTP/1.1`r`nHost: api.anthropic.com:443`r`n`r`n")
    $r = Send-Probe $Port $req 8000
    if ($r.Count -lt 12) { return 0 }
    $text = [Text.Encoding]::ASCII.GetString($r)
    if ($text -match '^HTTP/1\.[01] (\d{3})') { return [int]$Matches[1] }
    return 0
}

function Test-HttpProxy([int]$Port) {
    return (@(200, 502, 503, 504) -contains (Get-HttpConnectCode $Port))
}

# 通过代理访问 Claude 的服务器，返回 HTTP 状态码；不通返回 '000'。$Scheme：socks5h 或 http
function Get-ProxyHttpCode([string]$Scheme, [int]$Port) {
    if (-not (Test-Path -LiteralPath $Curl)) {
        if ((Get-HttpConnectCode $Port) -eq 200) { return '200' }
        return '000'
    }
    $proxyUrl = "${Scheme}://${ProxyHost}:$Port"
    $out = Invoke-Native { & $Curl -s -o NUL -m 20 -w '%{http_code}' -x $proxyUrl $TestUrl }
    if ($out -match '(\d{3})\s*$') { return $Matches[1] }
    return '000'
}

# 可能是 Clash 本地代理端口的候选：配置文件里写的、Clash 进程正在监听的、常见默认值。
function Get-ProxyCandidates {
    $ports = New-Object System.Collections.ArrayList
    $files = @(
        (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'),
        (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\config.yaml'),
        (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'),
        (Join-Path $env:USERPROFILE '.config\clash-verge\verge.yaml'),
        (Join-Path $env:USERPROFILE '.config\clash-verge\config.yaml'),
        (Join-Path $env:USERPROFILE '.config\clash\config.yaml'),
        (Join-Path $env:USERPROFILE '.config\mihomo\config.yaml'),
        (Join-Path $env:APPDATA 'mihomo-party\mihomo.yaml'),
        (Join-Path $env:APPDATA 'mihomo-party\work\config.yaml'),
        (Join-Path $env:APPDATA 'sparkle\mihomo.yaml')
    )
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        # 只取端口号，文件里的其他内容（订阅、密码）不读出来、不显示。
        try { $text = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } catch { continue }
        foreach ($m in [regex]::Matches($text, '(?m)^(?:verge_mixed_port|mixed-port|verge_socks_port|socks-port|verge_port|port)\s*:\s*(\d{2,5})')) {
            [void]$ports.Add([int]$m.Groups[1].Value)
        }
    }
    # 正在监听的端口：$listening 为 $null 表示查不了（很老的系统），那就每个候选都试。
    $listening = $null
    try {
        $listening = @{}
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            $listening[[int]$c.LocalPort] = $true
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'clash|mihomo|verge|sing-box|flclash|sparkle|nekoray|nekobox|v2rayn|xray|v2ray') {
                [void]$ports.Add([int]$c.LocalPort)
            }
        }
    } catch { $listening = $null }
    foreach ($d in @(7897, 7890, 7893, 7891, 7898, 7899, 10808, 10809, 1080)) { [void]$ports.Add($d) }
    $seen = @{}
    $out = @()
    foreach ($p in $ports) {
        if ($p -lt 1 -or $p -gt 65535 -or $seen.ContainsKey($p)) { continue }
        # 没有程序在监听的端口直接跳过，省得一个个去连。
        if ($null -ne $listening -and -not $listening.ContainsKey($p)) { continue }
        $seen[$p] = $true
        $out += $p
    }
    return $out
}

# 找 Clash 本地代理入口。优先选「SOCKS5 和 HTTP 都支持」的混合端口；找到返回 $true，结果放在 $script:Px。
function Find-Proxy {
    $socks = 0; $http = 0
    $candidates = @()
    if ($ProxyPort -gt 0) { $candidates = @($ProxyPort) } else { $candidates = @(Get-ProxyCandidates) }
    foreach ($p in $candidates) {
        $s = Test-Socks5 $p
        $h = $false
        if ($s -or $ProxyPort -gt 0 -or $socks -eq 0 -or $http -eq 0) { $h = Test-HttpProxy $p }
        if ($s -and $h) { $socks = $p; $http = $p; break }
        if ($s -and $socks -eq 0) { $socks = $p }
        if ($h -and $http -eq 0) { $http = $p }
    }
    if ($socks -eq 0 -and $http -eq 0) { $script:Px = $null; return $false }
    $type = 'socks5'; $port = $socks
    if ($socks -eq 0 -or $ProxyType -eq 'http') {
        if ($http -eq 0) { $script:Px = $null; return $false }
        $type = 'http'; $port = $http
    }
    $script:Px = [pscustomobject]@{ SocksPort = $socks; HttpPort = $http; Type = $type; Port = $port }
    return $true
}

function Get-ProxyText {
    if (-not $script:Px) { return '没找到' }
    if ($script:Px.SocksPort -eq $script:Px.HttpPort) { return "${ProxyHost}:$($script:Px.Port)（混合端口：SOCKS5 + HTTP）" }
    $parts = @()
    if ($script:Px.SocksPort) { $parts += "SOCKS5 ${ProxyHost}:$($script:Px.SocksPort)" }
    if ($script:Px.HttpPort) { $parts += "HTTP ${ProxyHost}:$($script:Px.HttpPort)" }
    return ($parts -join '，')
}

# 代理入口通不通（真的通过它连一次 Claude 的服务器）。
function Test-ProxyWorks {
    if (-not $script:Px) { return $false }
    $scheme = 'socks5h'
    if ($script:Px.Type -eq 'http') { $scheme = 'http' }
    return ((Get-ProxyHttpCode $scheme $script:Px.Port) -ne '000')
}

# 已安装的 Clash 类客户端（看卸载信息）；返回 DisplayName / InstallLocation，没有返回空数组。
function Get-ClashInstalled {
    $found = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $name = [string](Get-RegValue $k.PSPath 'DisplayName')
            if ($name -match 'clash|mihomo|flclash|sparkle|v2rayn|nekoray|nekobox') {
                $found += [pscustomobject]@{ Name = $name; Dir = [string](Get-RegValue $k.PSPath 'InstallLocation') }
            }
        }
    }
    return $found
}

# 下载文件：先直接下，不行再通过 Clash 代理下，再不行换 .NET 自带的下载。成功返回 $true。
function Get-Download([string]$Url, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
    $tmp = "$Dest.part"
    $tries = @('direct')
    if ($script:Px -and $script:Px.HttpPort) { $tries += 'proxy' }
    $tries += 'dotnet'
    foreach ($t in $tries) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        try {
            if ($t -eq 'dotnet') {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                (New-Object Net.WebClient).DownloadFile($Url, $tmp)
            } elseif (Test-Path -LiteralPath $Curl) {
                if ($t -eq 'proxy') {
                    $proxyUrl = "http://${ProxyHost}:$($script:Px.HttpPort)"
                    Invoke-Native { & $Curl -fsSL --connect-timeout 15 -m 900 -x $proxyUrl -o $tmp $Url } | Out-Null
                } else {
                    Invoke-Native { & $Curl -fsSL --connect-timeout 15 -m 900 -o $tmp $Url } | Out-Null
                }
            }
        } catch { }
        if ((Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 200000) {
            Move-Item -LiteralPath $tmp -Destination $Dest -Force
            return $true
        }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $false
}

function Get-Arch {
    $a = "$env:PROCESSOR_ARCHITEW6432"
    if (-not $a) { $a = "$env:PROCESSOR_ARCHITECTURE" }
    if ($a -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

# 电脑上没有任何 Clash 客户端时：下载并安装 Clash Verge Rev（按 CPU 选 x64 / arm64 的安装包）。
# 装完还需要用户自己导入订阅，这一步脚本做不了。
function Install-ClashVerge {
    $arch = Get-Arch
    $url = ''
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri $ClashApi -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'xiaochuan-proxy' }
        foreach ($a in @($rel.assets)) {
            if ($a.name -like "*_${arch}-setup.exe" -and $a.name -notlike '*webview2*') { $url = [string]$a.browser_download_url; break }
        }
    } catch { }
    if (-not $url) {
        $url = "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v$ClashFallbackVer/Clash.Verge_${ClashFallbackVer}_${arch}-setup.exe"
    }
    $dest = Join-Path $DownloadDir ("ClashVerge-$arch-setup.exe")
    Write-Log "这台电脑没有 Clash 客户端，下载 Clash Verge Rev（$arch）：$url"
    if (-not (Get-Download $url $dest)) {
        Write-Fail "Clash Verge Rev 下载失败（GitHub 在没有代理时经常连不上）。请手动下载安装：$url"
        return $false
    }
    Write-Log '正在静默安装 Clash Verge Rev…'
    try {
        $p = Start-Process -FilePath $dest -ArgumentList '/S' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Fail "Clash Verge Rev 安装程序返回了错误码 $($p.ExitCode)。"; return $false }
    } catch {
        Write-Fail "Clash Verge Rev 安装失败：$($_.Exception.Message)"
        return $false
    }
    Write-Log 'Clash Verge Rev 已安装。'
    return $true
}

# 确保有一个能用的 Clash 本地代理入口；后面每一步都要用它。
function Initialize-Proxy {
    Write-Log '正在找 Clash 本地代理入口…'
    if (Find-Proxy) {
        Write-Log "Clash 本地代理入口：$(Get-ProxyText)"
        if (Test-ProxyWorks) {
            Write-Log '通过代理访问 Claude 服务器：通。'
        } else {
            Write-Fail "代理入口 $(Get-ProxyText) 在监听，但通过它连不上 Claude 的服务器：Clash 的节点不可用。请在 Clash 里换一个能用的节点后重新运行。"
            return $false
        }
        return $true
    }
    if ($ProxyPort -gt 0) {
        Write-Fail "指定的端口 ${ProxyHost}:$ProxyPort 不是可用的 SOCKS5 / HTTP 代理入口。请到 Clash 的端口设置里核对 Mixed Port / HTTP Port / SOCKS Port。"
        return $false
    }
    $installed = @(Get-ClashInstalled)
    if ($installed.Count -eq 0) {
        if ($DryRun) {
            Write-Skip '（演练）这台电脑没有 Clash 客户端；正式执行时会下载并安装 Clash Verge Rev。'
            return $false
        }
        if (Install-ClashVerge) {
            Write-Fail 'Clash Verge Rev 已装好，但还没有订阅：请打开 Clash Verge，导入你的订阅并选好节点，然后重新运行本脚本（订阅链接只有你有，脚本做不了这一步）。'
        }
        return $false
    }
    Write-Fail "检测到已安装 $($installed[0].Name)，但没找到在监听的本地代理端口。请先打开 Clash、确认节点可用；端口不是常见值时用 -ProxyPort 指定（在 Clash 的端口设置里看 Mixed Port）。"
    return $false
}

# ------------------------------------------------------------ Claude 程序

# Claude Desktop 的安装目录（旧版 Squirrel 目录、新版应用商店格式的包），可能有多个。
function Get-ClaudeDesktopDirs {
    $dirs = @()
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path -LiteralPath $squirrel) { $dirs += $squirrel }
    try {
        foreach ($pkg in @(Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -like '*Claude*' -and $_.Publisher -like '*Anthropic*' })) {
            if ($pkg.InstallLocation -and (Test-Path -LiteralPath $pkg.InstallLocation)) { $dirs += [string]$pkg.InstallLocation }
        }
    } catch { }
    return $dirs
}

# 用 npm 装的 Claude Code（由 node.exe 运行）在不在。
function Test-NpmClaude {
    return (Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code'))
}

function Get-NodeExe {
    $cmd = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return [string]$cmd.Source }
    return ''
}

# 所有会联网的 Claude 程序文件（完整路径）：Claude Code、Claude Desktop 及其更新程序、正在运行的 claude.exe。
function Get-ClaudeExePaths {
    $paths = New-Object System.Collections.ArrayList
    $code = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $code) { [void]$paths.Add($code) }
    # Claude Code 自动更新时会直接运行 versions 目录里的新版本文件（文件名就是版本号）。
    $verDir = Join-Path $env:USERPROFILE '.local\share\claude\versions'
    foreach ($f in @(Get-ChildItem -LiteralPath $verDir -File -ErrorAction SilentlyContinue)) {
        if ($f.Length -gt 0) { [void]$paths.Add($f.FullName) }
    }
    foreach ($d in @(Get-ClaudeDesktopDirs)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq 'claude.exe' -or $f.Name -eq 'Update.exe') { [void]$paths.Add($f.FullName) }
        }
    }
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop)) {
            if ($p.ExecutablePath) { [void]$paths.Add([string]$p.ExecutablePath) }
        }
    } catch { }
    if ($IncludeNode) {
        $node = Get-NodeExe
        if ($node) { [void]$paths.Add($node) }
    }
    $seen = @{}
    $out = @()
    foreach ($p in $paths) {
        $k = $p.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $p
    }
    return $out
}

# 写进 Proxifier 规则的程序列表：claude.exe（Claude Code 和 Claude Desktop 的主程序、辅助进程都叫这个名字），
# 加上 Claude Code 的版本文件和 Claude Desktop 的更新程序（按完整路径，不影响别的软件）。
function Get-ProxifierApps {
    $apps = @('claude.exe')
    $verDir = Join-Path $env:USERPROFILE '.local\share\claude\versions'
    if (Test-Path -LiteralPath $verDir) { $apps += (Join-Path $verDir '*') }
    $upd = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Update.exe'
    if (Test-Path -LiteralPath $upd) { $apps += $upd }
    if ($IncludeNode) {
        $node = Get-NodeExe
        if ($node) { $apps += $node }
    }
    return $apps
}

# ---------------------------------------------------------------- Proxifier

function Get-ProxifierExe {
    $candidates = @()
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Proxifier_is1',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Proxifier_is1')) {
        $loc = [string](Get-RegValue $k 'InstallLocation')
        if ($loc) { $candidates += (Join-Path $loc 'Proxifier.exe') }
    }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Proxifier\Proxifier.exe') }
    $candidates += (Join-Path $env:ProgramFiles 'Proxifier\Proxifier.exe')
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return ''
}

function Test-ProxifierRunning { return [bool](Get-Process -Name 'Proxifier' -ErrorAction SilentlyContinue) }

function Test-ProxifierDriver {
    $svc = Get-Service -Name 'ProxifierDrv' -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

function Install-Proxifier {
    if (Get-ProxifierExe) { Write-Log "Proxifier 已安装：$(Get-ProxifierExe)"; return $true }
    if ($DryRun) { Write-Log "（演练）下载 $ProxifierUrl 并静默安装 Proxifier"; return $true }
    $dest = Join-Path $DownloadDir 'ProxifierSetup.exe'
    Write-Log "正在下载 Proxifier：$ProxifierUrl"
    if (-not (Get-Download $ProxifierUrl $dest)) {
        Write-Fail "Proxifier 下载失败。请手动下载安装后重新运行：$ProxifierUrl"
        return $false
    }
    # 只安装数字签名有效的安装包，防止下载到被改过的文件。
    $sig = Get-AuthenticodeSignature -LiteralPath $dest
    if ($sig.Status -ne 'Valid') {
        Write-Fail "下载到的 Proxifier 安装包数字签名无效（$($sig.Status)），没有安装。请到 https://www.proxifier.com/download/ 手动下载。"
        return $false
    }
    Write-Log "安装包签名有效（$($sig.SignerCertificate.Subject -replace '^CN=([^,]+).*$', '$1')），正在静默安装…"
    try {
        $p = Start-Process -FilePath $dest -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Fail "Proxifier 安装程序返回了错误码 $($p.ExitCode)。"; return $false }
    } catch {
        Write-Fail "Proxifier 安装失败：$($_.Exception.Message)"
        return $false
    }
    if (-not (Get-ProxifierExe)) { Write-Fail 'Proxifier 安装程序跑完了，但没找到 Proxifier.exe。'; return $false }
    Write-Log "Proxifier 已安装：$(Get-ProxifierExe)"
    return $true
}

function ConvertTo-XmlText([string]$Text) { return [Security.SecurityElement]::Escape($Text) }

# 生成 Proxifier 配置：Claude 的程序走 Clash 代理，本机地址和其他所有软件保持直连。
# 规则里没有「代理失败后直连」这种回退：代理不通，Claude 的连接就失败。
function New-ProfileXml {
    $ptype = 'SOCKS5'
    if ($script:Px.Type -eq 'http') { $ptype = 'HTTPS' }
    $apps = (@(Get-ProxifierApps) | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join '; '
    $dnsList = ($ClaudeDomains | ForEach-Object { "$_; *.$_" }) -join '; '
    $viaProxy = 'true'
    if ($LocalDns) { $viaProxy = 'false' }
    $options = ''
    if ($ptype -eq 'SOCKS5') { $options = "`r`n`t`t`t<Options>48</Options>" }
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!-- $PxMarker $Version：由 xiaochuan-proxy.ps1 生成，重新运行脚本会覆盖 -->
<ProxifierProfile version="102" platform="Windows" product_id="0" product_minver="400">
	<Options>
		<Resolve>
			<AutoModeDetection enabled="false" />
			<ViaProxy enabled="$viaProxy" />
			<BlockNonATypes enabled="false" />
			<ExclusionList OnlyFromListMode="true">$(ConvertTo-XmlText $dnsList)</ExclusionList>
			<DnsUdpMode>0</DnsUdpMode>
		</Resolve>
		<Encryption mode="basic" />
		<ConnectionLoopDetection enabled="true" resolve="true" />
		<ProcessOtherUsers enabled="false" />
		<ProcessServices enabled="false" />
		<HandleDirectConnections enabled="false" />
		<HttpProxiesSupport enabled="false" />
	</Options>
	<ProxyList>
		<Proxy id="100" type="$ptype">$options
			<Port>$($script:Px.Port)</Port>
			<Address>$ProxyHost</Address>
		</Proxy>
	</ProxyList>
	<ChainList />
	<RuleList>
		<Rule enabled="true">
			<Action type="Direct" />
			<Targets>localhost; 127.0.0.1; %ComputerName%; ::1</Targets>
			<Name>Localhost</Name>
		</Rule>
		<Rule enabled="true">
			<Action type="Proxy">100</Action>
			<Applications>$(ConvertTo-XmlText $apps)</Applications>
			<Name>Claude via Clash</Name>
		</Rule>
		<Rule enabled="true">
			<Action type="Direct" />
			<Name>Default</Name>
		</Rule>
	</RuleList>
</ProxifierProfile>
"@
}

# 我们生成的配置文件里记的代理端口；文件不存在或不是我们生成的返回 0。
function Get-ProfilePort {
    $file = Join-Path $PxProfileDir $PxProfileName
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    try { $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) } catch { return 0 }
    if ($text -notmatch [regex]::Escape($PxMarker)) { return 0 }
    if ($text -match '<Port>(\d+)</Port>') { return [int]$Matches[1] }
    return 0
}

function Set-ProxifierProfile {
    if (-not $script:DoPx) { return }
    Write-Log '准备安装 / 配置 Proxifier…'
    if (-not (Install-Proxifier)) { return }
    $file = Join-Path $PxProfileDir $PxProfileName
    $default = Join-Path $PxProfileDir 'Default.ppx'
    if ($DryRun) {
        Write-Log "（演练）备份现有的 Proxifier 配置，写入 $file 并让 Proxifier 载入："
        Write-Log "（演练）  代理服务器 ${ProxyHost}:$($script:Px.Port)（$($script:Px.Type)）；规则：$((Get-ProxifierApps) -join '、') 走代理，其余直连"
        Write-Log '（演练）把 Proxifier 设为开机自动启动'
        return
    }
    # 修改前把现有的 Proxifier 配置全部备份。
    foreach ($f in @(Get-ChildItem -LiteralPath $PxProfileDir -Filter '*.ppx' -File -ErrorAction SilentlyContinue)) {
        Backup-File $f.FullName "proxifier-profiles\$($f.Name)"
    }
    try {
        New-Item -ItemType Directory -Force -Path $PxProfileDir | Out-Null
        $xml = New-ProfileXml
        [IO.File]::WriteAllText($file, $xml, (New-Object Text.UTF8Encoding($false)))
        # 刚装好的 Proxifier 第一次启动会自动载入 Default.ppx；用户已有自己的 Default.ppx 时不动它。
        $defaultIsOurs = $false
        if (Test-Path -LiteralPath $default) {
            $defaultIsOurs = ([IO.File]::ReadAllText($default, [Text.Encoding]::UTF8) -match [regex]::Escape($PxMarker))
        }
        if ($defaultIsOurs -or -not (Test-Path -LiteralPath $default)) {
            [IO.File]::WriteAllText($default, $xml, (New-Object Text.UTF8Encoding($false)))
        }
    } catch {
        Write-Fail "Proxifier 配置文件写入失败：$($_.Exception.Message)"
        return
    }
    $exe = Get-ProxifierExe
    try {
        # Proxifier 没开就启动并载入；已经开着就直接把配置载入正在运行的 Proxifier。
        Start-Process -FilePath $exe -ArgumentList "`"$file`"", 'silent-load' | Out-Null
        for ($i = 0; $i -lt 15 -and -not (Test-ProxifierRunning); $i++) { Start-Sleep -Seconds 1 }
    } catch {
        Write-Fail "Proxifier 启动失败：$($_.Exception.Message)"
        return
    }
    try {
        Set-ItemProperty -Path $RunKey -Name $RunName -Value "`"$exe`"" -Type String -ErrorAction Stop
    } catch {
        Write-Note "没能把 Proxifier 设为开机自动启动：$($_.Exception.Message)"
    }
    Write-Log "Proxifier 配置已写入并载入：$file"
}

# ------------------------------------------------- Claude Code 自身代理设置

function Get-CodeProxyUrl {
    if (-not $script:Px -or -not $script:Px.HttpPort) { return '' }
    return "http://${ProxyHost}:$($script:Px.HttpPort)"
}

# 读 Claude Code 的 settings.json；文件不存在返回空对象，内容不是合法 JSON 会抛出异常（不去覆盖它）。
function Read-ClaudeSettings {
    if (-not (Test-Path -LiteralPath $ClaudeSettings)) { return (New-Object psobject) }
    $raw = [IO.File]::ReadAllText($ClaudeSettings, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return (New-Object psobject) }
    $obj = $raw | ConvertFrom-Json
    if ($obj -isnot [pscustomobject]) { throw 'settings.json 的内容不是 JSON 对象' }
    return $obj
}

function Save-ClaudeSettings($Obj) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ClaudeSettings -Parent) | Out-Null
    $tmp = "$ClaudeSettings.xc-tmp"
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $ClaudeSettings -Force
}

# settings.json 的 env 里某一项的值；没有返回空字符串。
function Get-ClaudeEnv([string]$Name) {
    try {
        $obj = Read-ClaudeSettings
        if ($obj.PSObject.Properties['env'] -and $obj.env.PSObject.Properties[$Name]) { return [string]$obj.env.$Name }
    } catch { }
    return ''
}

function Test-CodeProxyOk {
    $want = Get-CodeProxyUrl
    return ($want -and (Get-ClaudeEnv 'HTTPS_PROXY') -eq $want -and (Get-ClaudeEnv 'HTTP_PROXY') -eq $want)
}

# 在 Claude Code 的设置里写入 HTTPS_PROXY / HTTP_PROXY：Claude Code 自己只走这个代理，代理不通就连接失败。
function Set-ClaudeCodeProxy {
    if (-not $script:DoCode) { return }
    $url = Get-CodeProxyUrl
    Write-Log '准备给 Claude Code 写入代理设置…'
    if (-not $url) {
        Write-Fail 'Claude Code 只支持 HTTP 代理，但没找到 Clash 的 HTTP / 混合端口。请在 Clash 里打开 Mixed Port（混合端口）后重新运行。'
        return
    }
    if ($DryRun) {
        Write-Log "（演练）在 $ClaudeSettings 的 env 里写入 HTTPS_PROXY / HTTP_PROXY = $url"
        return
    }
    try {
        Backup-File $ClaudeSettings 'claude\settings.json'
        $obj = Read-ClaudeSettings
        if (-not $obj.PSObject.Properties['env'] -or $obj.env -isnot [pscustomobject]) {
            $obj | Add-Member -NotePropertyName env -NotePropertyValue (New-Object psobject) -Force
        }
        foreach ($k in @('HTTPS_PROXY', 'HTTP_PROXY')) {
            $obj.env | Add-Member -NotePropertyName $k -NotePropertyValue $url -Force
        }
        # 本机地址不走代理（本机的 MCP 服务、IDE 插件等）；用户自己设过就不动。
        if (-not $obj.env.PSObject.Properties['NO_PROXY']) {
            $obj.env | Add-Member -NotePropertyName NO_PROXY -NotePropertyValue 'localhost,127.0.0.1,::1' -Force
        }
        Save-ClaudeSettings $obj
    } catch {
        Write-Fail "Claude Code 设置文件修改失败：$($_.Exception.Message)（文件：$ClaudeSettings）"
        return
    }
    if (Test-CodeProxyOk) { Write-Log "Claude Code 代理已设为 $url（重新打开 Claude Code 后生效）。" }
}

# -------------------------------------------------- 防火墙 Kill Switch

# 现有的 Kill Switch 规则拦着哪些程序（完整路径，小写）。
function Get-KillSwitchPrograms {
    $out = @()
    try {
        foreach ($r in @(Get-NetFirewallRule -Group $FwGroup -ErrorAction Stop)) {
            if ($r.Enabled -ne 'True' -or $r.Action -ne 'Block') { continue }
            $f = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            if ($f -and $f.Program) { $out += ([string]$f.Program).ToLowerInvariant() }
        }
    } catch { }
    return $out
}

# 还没有被 Kill Switch 规则拦住的 Claude 程序。
function Get-KillSwitchMissing {
    $have = @(Get-KillSwitchPrograms)
    return @(Get-ClaudeExePaths | Where-Object { $have -notcontains $_.ToLowerInvariant() })
}

# 没打开防火墙的网络类型（域 / 专用 / 公用）；防火墙关着时阻断规则不起作用。
function Get-FirewallOffProfiles {
    try { return @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name }) } catch { return @() }
}

function Remove-KillSwitchRules {
    try { Get-NetFirewallRule -Group $FwGroup -ErrorAction Stop | Remove-NetFirewallRule -ErrorAction Stop } catch { }
}

# 给每个 Claude 程序加一条出站阻断规则：IPv4 / IPv6、TCP / UDP（含 QUIC）一律不许直接连外网，
# 只剩「连本机」这一条路，也就是只能走本机的 Clash / Proxifier。Proxifier 退出、Clash 退出时 Claude 都连不出去。
function Set-KillSwitch {
    if (-not $script:DoKs) { return }
    Write-Log '准备设置防火墙 Kill Switch…'
    $paths = @(Get-ClaudeExePaths)
    if ($paths.Count -eq 0) {
        Write-Fail '没找到任何 Claude 程序（Claude Code / Claude Desktop 都没装？），Kill Switch 没有可拦的对象。'
        return
    }
    if ($DryRun) {
        foreach ($p in $paths) { Write-Log "（演练）添加出站阻断规则（只放行本机地址）：$p" }
        return
    }
    Remove-KillSwitchRules
    $n = 0
    foreach ($p in $paths) {
        $n++
        $kind = 'Claude Desktop'
        if ($p -like '*\.local\*') { $kind = 'Claude Code' }
        if ($p -like '*\node.exe') { $kind = 'Claude Code (node)' }
        try {
            New-NetFirewallRule -DisplayName "$kind outbound block $n" -Description "xiaochuan-proxy：禁止直连外网，只能走本机代理。程序：$p" `
                -Group $FwGroup -Direction Outbound -Action Block -Program $p -RemoteAddress $FwRemote `
                -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        } catch {
            Write-Fail "防火墙规则添加失败（$p）：$($_.Exception.Message)"
        }
    }
    # 规则加完后马上复查：本机代理入口必须还是通的，否则说明规则误拦了，立刻撤掉。
    if (-not (Test-ProxyWorks)) {
        Remove-KillSwitchRules
        Write-Fail '加上防火墙规则后本机代理入口不通了，已把刚加的规则全部撤掉。'
        return
    }
    Write-Log "防火墙 Kill Switch 已设置：$n 条规则（规则组「$FwGroup」）。"
}

# ------------------------------------------------------ 浏览器（可选）

# PAC 脚本：Claude 的网站只走 Clash 代理，没有 DIRECT 回退（代理不通就打不开）。
function New-PacText {
    $parts = @()
    if ($script:Px.SocksPort) { $parts += "SOCKS5 ${ProxyHost}:$($script:Px.SocksPort)" }
    if ($script:Px.HttpPort) { $parts += "PROXY ${ProxyHost}:$($script:Px.HttpPort)" }
    $proxy = $parts -join '; '
    $domains = ($ClaudeDomains | ForEach-Object { "`"$_`"" }) -join ', '
    $other = 'return "DIRECT";'
    if ($BrowserMode -eq 'all') { $other = 'return P;' }
    return @"
// $PxMarker $Version mode=$BrowserMode
function FindProxyForURL(url, host) {
  var P = "$proxy";
  var d = [$domains];
  host = host.toLowerCase();
  if (isPlainHostName(host) || host == "localhost" || host == "127.0.0.1" || host == "[::1]") return "DIRECT";
  for (var i = 0; i < d.length; i++) { if (host == d[i] || dnsDomainIs(host, "." + d[i])) return P; }
  if (/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)/.test(host)) return "DIRECT";
  $other
}
"@
}

function Get-InstalledBrowsers {
    $out = @()
    foreach ($b in $BrowserKeys) {
        $exes = @()
        if ($b.Name -eq 'Chrome') {
            $exes = @((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
            if (${env:ProgramFiles(x86)}) { $exes += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe') }
        } else {
            $exes = @((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
            if (${env:ProgramFiles(x86)}) { $exes += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
        }
        foreach ($e in $exes) { if (Test-Path -LiteralPath $e) { $out += $b; break } }
    }
    return $out
}

# 这个浏览器的代理策略是不是我们写的；是则返回 PAC 文本，否则返回空字符串。
function Get-BrowserPac($B) {
    $url = [string](Get-RegValue $B.Key 'ProxyPacUrl')
    $prefix = 'data:application/x-ns-proxy-autoconfig;base64,'
    if (-not $url.StartsWith($prefix)) { return '' }
    try {
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($url.Substring($prefix.Length)))
        if ($text -match [regex]::Escape($PxMarker)) { return $text }
    } catch { }
    return ''
}

function Test-BrowserOk($B) {
    return ((Get-RegValue $B.Key 'ProxyMode') -eq 'pac_script' -and (Get-BrowserPac $B) -eq (New-PacText))
}

# 用浏览器的「策略」固定代理：扩展被关掉、设置被重置都改不了它，比 SwitchyOmega 扩展更严格。
function Set-BrowserPolicy {
    if (-not $script:DoBrowser) { return }
    Write-Log '准备设置浏览器代理策略…'
    $browsers = @(Get-InstalledBrowsers)
    if ($browsers.Count -eq 0) { Write-Skip '没检测到 Chrome / Edge，浏览器这一步已跳过。'; return }
    $pacUrl = 'data:application/x-ns-proxy-autoconfig;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((New-PacText)))
    foreach ($b in $browsers) {
        if ($DryRun) {
            $what = 'Claude 的网站强制走代理，其余网站直连'
            if ($BrowserMode -eq 'all') { $what = '所有网站强制走代理' }
            Write-Log "（演练）$($b.Name)：写入代理策略（$what）"
            continue
        }
        try {
            # 用户或公司已经设了别的代理策略时不去覆盖。
            $oldMode = Get-RegValue $b.Key 'ProxyMode'
            if ($oldMode -and -not (Get-BrowserPac $b)) {
                Write-Fail "$($b.Name) 已经有别的代理策略（ProxyMode=$oldMode），没有覆盖。"
                continue
            }
            if (-not (Test-Path -LiteralPath $b.Key)) { New-Item -Path $b.Key -Force | Out-Null }
            Set-ItemProperty -LiteralPath $b.Key -Name ProxyMode -Value 'pac_script' -Type String
            Set-ItemProperty -LiteralPath $b.Key -Name ProxyPacUrl -Value $pacUrl -Type String
            Set-ItemProperty -LiteralPath $b.Key -Name ProxyPacMandatory -Value 1 -Type DWord
            Write-Log "$($b.Name)：代理策略已写入（重新打开浏览器后生效）。"
        } catch {
            Write-Fail "$($b.Name) 代理策略写入失败：$($_.Exception.Message)"
        }
    }
}

function Remove-BrowserPolicy {
    foreach ($b in $BrowserKeys) {
        if (-not (Get-BrowserPac $b)) { continue }
        foreach ($n in @('ProxyMode', 'ProxyPacUrl', 'ProxyPacMandatory')) {
            Remove-ItemProperty -LiteralPath $b.Key -Name $n -ErrorAction SilentlyContinue
        }
        Write-Log "$($b.Name)：代理策略已删除。"
    }
}

# ------------------------------------------------------------------- IPv6

# 只检查、不修改：方案要求不要未经测试就全局关闭 IPv6；Claude 的 IPv6 直连由 Kill Switch 规则拦住。
function Get-Ip6OnAdapters {
    try {
        return @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop |
            Where-Object { $_.Enabled } | ForEach-Object { $_.Name })
    } catch { return @() }
}

# ----------------------------------------------------------------- 主流程

function Write-StatusLine([string]$Mark, [string]$Text) {
    if ($Mark -eq '√') { Write-Host "  √ $Text" -ForegroundColor Green }
    elseif ($Mark -eq '-') { Write-Host "  - $Text" }
    else { Write-Host "  × $Text" -ForegroundColor Red; $script:StatusBad++ }
}

# 逐项显示当前状态。$Full 为真时多做一次「通过代理连 Claude 服务器」的联网测试。
function Show-Status([bool]$Full) {
    $script:StatusBad = 0
    if (-not (Find-Proxy)) {
        Write-StatusLine '×' 'Clash 本地代理：没找到在监听的代理端口（Clash 没开？或用 -ProxyPort 指定端口）'
    } elseif ($Full -and -not (Test-ProxyWorks)) {
        Write-StatusLine '×' "Clash 本地代理：$(Get-ProxyText) 在监听，但通过它连不上 Claude 的服务器（节点不可用）"
    } else {
        Write-StatusLine '√' "Clash 本地代理：$(Get-ProxyText)"
    }

    $exe = Get-ProxifierExe
    $pport = Get-ProfilePort
    if (-not $exe) {
        Write-StatusLine '×' 'Proxifier：没有安装'
    } elseif (-not (Test-ProxifierRunning)) {
        Write-StatusLine '×' 'Proxifier：已安装，但没有运行（没运行时 Claude Desktop 不会走代理）'
    } elseif ($pport -eq 0) {
        Write-StatusLine '×' 'Proxifier：在运行，但还没有写入 Claude 规则'
    } elseif ($script:Px -and $pport -ne $script:Px.Port) {
        Write-StatusLine '×' "Proxifier：规则里的代理端口是 $pport，和 Clash 现在的端口 $($script:Px.Port) 不一致（重新运行脚本即可）"
    } elseif (-not (Test-ProxifierDriver)) {
        Write-StatusLine '×' 'Proxifier：在运行，但它的驱动（ProxifierDrv）没有启动'
    } else {
        Write-StatusLine '√' "Proxifier：在运行，Claude 规则已写入（代理端口 $pport）"
    }

    $codeUrl = Get-ClaudeEnv 'HTTPS_PROXY'
    if (Test-CodeProxyOk) { Write-StatusLine '√' "Claude Code 代理设置：$codeUrl" }
    elseif ($codeUrl) { Write-StatusLine '×' "Claude Code 代理设置：现在是 $codeUrl，和 Clash 的端口不一致" }
    else { Write-StatusLine '×' 'Claude Code 代理设置：还没有写入' }
    if ((Test-NpmClaude) -and -not $IncludeNode) {
        Write-StatusLine '-' '检测到用 npm 装的 Claude Code（由 node.exe 运行）：Proxifier / 防火墙规则管不到它，只有上面的代理设置对它生效'
    }

    $rules = @(Get-KillSwitchPrograms)
    $missing = @(Get-KillSwitchMissing)
    $fwOff = @(Get-FirewallOffProfiles)
    if ($rules.Count -eq 0) {
        Write-StatusLine '×' '防火墙 Kill Switch：还没有设置（Proxifier 退出时 Claude Desktop 会直连）'
    } elseif ($missing.Count -gt 0) {
        Write-StatusLine '×' "防火墙 Kill Switch：这些 Claude 程序还没有规则（多半是更新后路径变了，重新运行脚本即可）：$($missing -join '、')"
    } elseif ($fwOff.Count -gt 0) {
        Write-StatusLine '×' "防火墙 Kill Switch：规则已有，但 Windows 防火墙在这些网络类型上是关的，规则不起作用：$($fwOff -join '、')"
    } else {
        Write-StatusLine '√' "防火墙 Kill Switch：$($rules.Count) 条规则，Claude 程序不能直连外网（IPv4 / IPv6 / UDP）"
    }

    $bset = @($BrowserKeys | Where-Object { Get-BrowserPac $_ } | ForEach-Object { $_.Name })
    if ($bset.Count -gt 0) { Write-StatusLine '-' "浏览器代理策略（可选项）：已设置：$($bset -join '、')" }
    else { Write-StatusLine '-' '浏览器代理策略（可选项）：没有设置' }

    $ip6 = @(Get-Ip6OnAdapters)
    if ($ip6.Count -gt 0) { Write-StatusLine '-' "IPv6：这些网卡开着 IPv6：$($ip6 -join '、')（脚本不去关它；Claude 的 IPv6 直连由 Kill Switch 拦住）" }
    else { Write-StatusLine '-' 'IPv6：所有网卡都没有开 IPv6' }
}

# 执行后逐项核对「选中的项目」有没有真的做到。
function Show-Verify([bool]$WantPx, [bool]$WantCode, [bool]$WantKs, [bool]$WantBrowser) {
    if ($WantPx) {
        $pport = Get-ProfilePort
        if (-not (Get-ProxifierExe)) { Add-Bad 'Proxifier：没有安装上' }
        elseif ($pport -ne $script:Px.Port) { Add-Bad 'Proxifier：Claude 规则没有写进配置文件' }
        elseif (-not (Test-ProxifierRunning)) { Add-Bad 'Proxifier：配置已写好，但 Proxifier 没有运行起来；请手动打开 Proxifier' }
        elseif (-not (Test-ProxifierDriver)) { Add-Bad 'Proxifier：在运行，但驱动 ProxifierDrv 没有启动；请重启电脑后再看' }
        else { Add-Ok "Proxifier：已运行，Claude 程序走 ${ProxyHost}:$pport，其他软件直连" }
    }
    if ($WantCode) {
        if (Test-CodeProxyOk) { Add-Ok "Claude Code 代理设置：$(Get-CodeProxyUrl)（重新打开 Claude Code 后生效）" }
        else { Add-Bad 'Claude Code 代理设置：没有写进 settings.json' }
    }
    if ($WantKs) {
        $rules = @(Get-KillSwitchPrograms)
        $missing = @(Get-KillSwitchMissing)
        $fwOff = @(Get-FirewallOffProfiles)
        if ($rules.Count -eq 0) { Add-Bad '防火墙 Kill Switch：规则没有加上' }
        elseif ($missing.Count -gt 0) { Add-Bad "防火墙 Kill Switch：这些程序没有加上规则：$($missing -join '、')" }
        elseif ($fwOff.Count -gt 0) { Add-Bad "防火墙 Kill Switch：规则已加，但 Windows 防火墙在这些网络类型上是关的，规则不起作用：$($fwOff -join '、')。请到「Windows 安全中心 > 防火墙和网络保护」打开" }
        else { Add-Ok "防火墙 Kill Switch：$($rules.Count) 条规则，Claude 程序不能直连外网" }
    }
    if ($WantBrowser) {
        foreach ($b in @(Get-InstalledBrowsers)) {
            if (Test-BrowserOk $b) { Add-Ok "$($b.Name)：代理策略已设置（重新打开浏览器后生效）" }
            else { Add-Bad "$($b.Name)：代理策略没有设置上" }
        }
    }
}

function Invoke-Pipeline {
    if (-not ($script:DoPx -or $script:DoCode -or $script:DoKs -or $script:DoBrowser)) {
        Write-Host '请至少选择一个执行项目。'; return
    }
    $script:BackupDir = Join-Path $DataDir ('proxy-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }
    $wantPx = $script:DoPx; $wantCode = $script:DoCode; $wantKs = $script:DoKs; $wantBrowser = $script:DoBrowser

    # 每一步都要用 Clash 的本地代理入口；入口找不到或不通就不往下做，免得把 Claude 的网络弄断。
    if (-not (Initialize-Proxy)) { return }

    Set-ClaudeCodeProxy
    Set-ProxifierProfile
    Set-KillSwitch
    Set-BrowserPolicy

    if ($DryRun) {
        Write-Skip '演练结束，没有做任何修改。'
        return
    }
    Show-Verify $wantPx $wantCode $wantKs $wantBrowser
    if ((Test-NpmClaude) -and -not $IncludeNode) {
        Add-Info '提示：检测到用 npm 装的 Claude Code（由 node.exe 运行），Proxifier / 防火墙规则管不到它；建议改用官方安装版，或加 -IncludeNode（会让所有 node 程序都走代理）'
    }
    if ($wantPx) {
        Add-Info '需要你手动做：Proxifier 是收费软件（31 天试用），启动时的试用窗口要点一下；到期后要自己购买并输入注册码'
    }
    if ($wantPx -or $wantKs) {
        Add-Info '需要你手动验证（脚本没法替你关 Clash）：先确认 Claude Code / Claude Desktop 能正常用；再分别退出 Clash、退出 Proxifier，两种情况下 Claude 都应该连不上'
    }
    if (Test-Path -LiteralPath $script:BackupDir) { Add-Info "修改前的备份：$script:BackupDir" }
}

# 撤销本脚本做的所有修改。Proxifier 程序本身不卸载（需要的话到「设置 > 应用」里卸载）。
function Invoke-Undo {
    $script:BackupDir = Join-Path $DataDir ('proxy-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($DryRun) {
        Write-Log '（演练）删除防火墙 Kill Switch 规则、Claude Code 代理设置、浏览器代理策略、Proxifier 的 Claude 配置和开机启动项，并退出 Proxifier'
        Write-Skip '演练结束，没有做任何修改。'
        return
    }
    # 先撤防火墙规则：网络出问题时最先要停掉的就是这些新增的阻断规则。
    Remove-KillSwitchRules
    if (@(Get-KillSwitchPrograms).Count -eq 0) { Add-Ok '防火墙 Kill Switch 规则：已全部删除' } else { Add-Bad '防火墙 Kill Switch 规则：没删干净' }

    try {
        if (Test-Path -LiteralPath $ClaudeSettings) {
            Backup-File $ClaudeSettings 'claude\settings.json'
            $obj = Read-ClaudeSettings
            if ($obj.PSObject.Properties['env'] -and $obj.env -is [pscustomobject]) {
                # 只删我们写的值（指向本机的代理地址）；用户自己设的别的代理不动。
                foreach ($k in @('HTTPS_PROXY', 'HTTP_PROXY')) {
                    if ($obj.env.PSObject.Properties[$k] -and [string]$obj.env.$k -match '^http://127\.0\.0\.1:\d+$') { $obj.env.PSObject.Properties.Remove($k) }
                }
                if ($obj.env.PSObject.Properties['NO_PROXY'] -and [string]$obj.env.NO_PROXY -eq 'localhost,127.0.0.1,::1') { $obj.env.PSObject.Properties.Remove('NO_PROXY') }
                if (@($obj.env.PSObject.Properties).Count -eq 0) { $obj.PSObject.Properties.Remove('env') }
                Save-ClaudeSettings $obj
            }
        }
        Add-Ok 'Claude Code 代理设置：已删除'
    } catch {
        Add-Bad "Claude Code 代理设置：删除失败：$($_.Exception.Message)"
    }

    Remove-BrowserPolicy
    if (@($BrowserKeys | Where-Object { Get-BrowserPac $_ }).Count -eq 0) { Add-Ok '浏览器代理策略：已删除' } else { Add-Bad '浏览器代理策略：没删干净' }

    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    Get-Process -Name 'Proxifier' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($n in @($PxProfileName, 'Default.ppx')) {
        $f = Join-Path $PxProfileDir $n
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            if ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) -match [regex]::Escape($PxMarker)) {
                Backup-File $f "proxifier-profiles\$n"
                Remove-Item -LiteralPath $f -Force
            }
        } catch { }
    }
    if ((Get-ProfilePort) -eq 0 -and -not (Test-ProxifierRunning)) { Add-Ok 'Proxifier：已退出，Claude 配置和开机启动项已删除' }
    else { Add-Bad 'Proxifier：没能退出或配置没删掉，请手动退出 Proxifier' }
    if (Get-ProxifierExe) { Add-Info 'Proxifier 程序本身没有卸载；需要的话到「设置 > 应用 > 已安装的应用」里卸载' }
    Add-Info '现在 Claude 恢复成原来的联网方式（不再强制走代理）'
}

function Show-Menu {
    while ($true) {
        $script:DoPx = $false; $script:DoCode = $false; $script:DoKs = $false; $script:DoBrowser = $false
        $script:Errors = 0
        $script:Results.Clear(); $script:OkCount = 0; $script:BadCount = 0

        Write-Host ''
        Write-Host "================ 小川强制代理助手 $Version（Windows）================"
        Show-Status $false
        Write-Host ''
        Write-Host '  1) Proxifier：下载安装，写入「Claude 走 Clash 代理、其他软件直连」的规则'
        Write-Host '  2) Claude Code：写入自身代理设置（代理不通就连接失败）'
        Write-Host '  3) 防火墙 Kill Switch：禁止 Claude 程序直连外网（Proxifier / Clash 退出时也不会直连）'
        Write-Host '  4) 浏览器（可选）：Chrome / Edge 里 Claude 的网站强制走代理'
        Write-Host '  a) 一键执行 1 2 3（推荐）'
        Write-Host '  u) 撤销本脚本做的全部修改'
        Write-Host '  q) 退出'
        Write-Host ''
        $choices = Read-Host '请输入要执行的项目（可多选，用空格分开，例如 1 2），然后按回车'
        $picked = $false; $bad = $false; $undo = $false
        foreach ($c in ($choices -split '[\s,]+' | Where-Object { $_ })) {
            if ($c -eq '1') { $script:DoPx = $true; $picked = $true }
            elseif ($c -eq '2') { $script:DoCode = $true; $picked = $true }
            elseif ($c -eq '3') { $script:DoKs = $true; $picked = $true }
            elseif ($c -eq '4') { $script:DoBrowser = $true; $picked = $true }
            elseif ($c -eq 'a') { $script:DoPx = $true; $script:DoCode = $true; $script:DoKs = $true; $picked = $true }
            elseif ($c -eq 'u') { $undo = $true; $picked = $true }
            elseif ($c -eq 'q') { return }
            else { Write-Host "看不懂的选项：$c"; $bad = $true; break }
        }
        if (-not $bad) {
            if (-not $picked) { continue }
            if ($undo) { Invoke-Undo } else { Invoke-Pipeline }
            Show-Result
        }

        Write-Host ''
        if ((Read-Host '按回车返回菜单（输入 q 退出）') -eq 'q') { return }
    }
}

function Show-Usage {
    Write-Host @"
小川强制代理助手 $Version（Windows 脚本版）
让 Claude Code / Claude Desktop 只走 Clash 本地代理；代理失效时连接失败，不会自动直连。其他软件不受影响。

用法：
  双击 xiaochuan-proxy.bat                   交互菜单
  xiaochuan-proxy.bat -All                   直接执行：Proxifier + Claude Code 代理设置 + 防火墙 Kill Switch
  xiaochuan-proxy.bat -All -DryRun           演练，只显示将要做的事
  xiaochuan-proxy.bat status                 检查当前状态（会真的通过代理连一次 Claude 服务器）
  xiaochuan-proxy.bat undo                   撤销本脚本做的全部修改

选项：
  -Proxifier       下载安装 Proxifier，写入 Claude 专用规则并载入，设为开机启动
  -ClaudeCode      在 Claude Code 的 settings.json 里写入 HTTPS_PROXY / HTTP_PROXY
  -KillSwitch      Windows 防火墙：禁止 Claude 程序直连外网（IPv4 / IPv6 / UDP）
  -Browser         可选：Chrome / Edge 用策略固定代理（不包含在 -All 里）
  -All             等于 -Proxifier -ClaudeCode -KillSwitch
  -ProxyPort 端口  指定 Clash 本地代理端口（默认自动查找）
  -ProxyType 类型  socks5 或 http（默认自动判断，优先 socks5）
  -BrowserMode     claude：只有 Claude 的网站走代理，其余直连（默认）；all：所有网站都走代理
  -LocalDns        Claude 的域名改用本机 DNS 解析（默认通过代理解析，防止 DNS 泄漏）
  -IncludeNode     把 node.exe 也纳入规则（npm 装的 Claude Code 才需要；会影响所有 node 程序）
  -DryRun          演练：只显示将要做的事，不做任何修改

脚本会自己弹出 UAC 申请管理员权限，不需要手动「以管理员身份运行」。
"@
}

# ------------------------------------------------------------------- 入口

if ($Help) { Show-Usage; exit 0 }

if ($All) { $Proxifier = $true; $ClaudeCode = $true; $KillSwitch = $true }
$script:DoPx = [bool]$Proxifier
$script:DoCode = [bool]$ClaudeCode
$script:DoKs = [bool]$KillSwitch
$script:DoBrowser = [bool]$Browser
$anySelected = ($script:DoPx -or $script:DoCode -or $script:DoKs -or $script:DoBrowser)

# 除了「演练」和「查看状态」，其余全部在管理员权限下执行：只弹一次 UAC。
$needAdmin = -not $DryRun -and $Action -ne 'status'
if ($needAdmin -and -not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    $argList += '-Elevated'; $argList += '-OrigUser'; $argList += "`"$env:USERNAME`""
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
        exit 0
    } catch {
        Write-Fail '没有拿到管理员权限（UAC 被取消）。请重新运行，并在弹出的窗口里点「是」。'
        Show-Result
        exit 1
    }
}

# 用别的管理员账户通过 UAC 提权时，Claude Code 设置和 Proxifier 配置会写到那个账户上，而不是当前登录的用户。
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) {
    Write-Fail "当前登录用户 $OrigUser 不是管理员，UAC 用的是另一个账户 $env:USERNAME，设置会改错账户。请用管理员账户登录 Windows 后再运行。"
    Show-Result
    Read-Host '按回车关闭'
    exit 1
}

# 菜单里每执行完一次都会打印「执行结果」；其余情况在这里统一打印一次。
$showResult = $true
try {
    if ($Action -eq 'status') {
        $showResult = $false
        Write-Host "小川强制代理助手 $Version（Windows）"
        Show-Status $true
        Write-Host '=========================================='
        if ($script:StatusBad -eq 0) {
            Write-Host ' 结果：强制代理的各项设置都在 ' -ForegroundColor White -BackgroundColor DarkGreen
        } else {
            Write-Host " 结果：有 $($script:StatusBad) 项没有到位（上面标 × 的红色行） " -ForegroundColor White -BackgroundColor Red
            $script:Errors += $script:StatusBad
        }
    } elseif ($Action -eq 'undo') {
        Invoke-Undo
    } elseif ($anySelected) {
        Invoke-Pipeline
    } else {
        $showResult = $false
        Show-Menu
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
    $showResult = $true
}
if ($showResult) { Show-Result }
if ($script:BadCount -gt 0 -and $script:Errors -eq 0) { $script:Errors = $script:BadCount }

# 提权后是新开的窗口，结束前停一下，免得结果一闪而过。
if ($Elevated -and ($Action -or $anySelected -or $script:Errors)) {
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
}
if ($script:Errors -gt 0) { exit 1 }
exit 0
