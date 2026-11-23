# 小川远程 SSH 助手 · Windows 版
# 让这台 Windows 电脑可以被 SSH 连接，之后就能从别的电脑远程执行命令行：
#   1. 安装 Windows 自带的 OpenSSH 服务端（已经装了就跳过；系统自带的装不上时改从 GitHub 官方下载安装包）。
#   2. 启动 sshd 服务，并设为开机自动启动。
#   3. 防火墙放行 SSH 端口（默认 22）。
#   4. 登录设置：可选写入公钥（免密码登录）、可选把远程登录后的命令行换成 PowerShell。
#   5. 检查 SSH 端口确实通了，并显示从别的电脑连接要用的命令。
# 直接双击 enable-ssh.bat 即可，Windows 会弹一次 UAC，点「是」。重复执行没有副作用。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [string]$PubKey = '',
    [ValidateSet('', 'powershell', 'cmd')]
    [string]$Shell = '',
    [switch]$Status,
    [switch]$Off,
    [switch]$DryRun,
    [switch]$Help,
    # 下面三个是脚本自己用的，不用手动传。
    [switch]$FromBat,
    [switch]$Elevated,
    [string]$OrigUser = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Capability = 'OpenSSH.Server~~~~0.0.1.0'
$Repo = 'PowerShell/Win32-OpenSSH'
$ReleasesPage = "https://github.com/$Repo/releases/latest"
# GitHub 直连下载失败时用的镜像。镜像不是官方的，下载下来的安装包必须通过校验才会安装。
$Mirrors = 'https://gh-proxy.com/', 'https://ghfast.top/'
$RuleName = 'Xiaochuan-SSH-In-TCP'
$SshData = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshData 'sshd_config'
$AdminKeys = Join-Path $SshData 'administrators_authorized_keys'
$PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
# 系统自带的 OpenSSH 安装超过这个秒数还没完成，就改用 GitHub 安装包。
$CapabilityTimeout = 600

$script:StepNo = 0
$script:TotalSteps = 0

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Note([string]$Message) {
    Write-Host ("[{0}] 注意：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
}
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
    Add-Bad $Message
}

# 显示现在做到第几步。
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

# 双击运行、或者提权后新开的窗口，结束前停一下，免得结果一闪而过。
function Exit-Script([int]$Code) {
    if ($FromBat -or $Elevated) {
        Write-Host ''
        Read-Host '按回车关闭窗口' | Out-Null
    }
    exit $Code
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Sshd { return Get-Service -Name 'sshd' -ErrorAction SilentlyContinue }

# sshd 实际监听的端口：sshd_config 里没有写 Port 就是 22。
function Get-SshPort {
    try {
        foreach ($line in [IO.File]::ReadAllLines($SshdConfig)) {
            if ($line -match '^\s*Port\s+(\d+)') { return [int]$Matches[1] }
        }
    } catch { }
    return 22
}

# 连一下本机的 SSH 端口，收到「SSH-」开头的应答才算通。
function Test-SshPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, $buf.Length)
        return ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -like 'SSH-*')
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ================================================================ 第 1 步：安装 OpenSSH 服务端

# 系统自带的 OpenSSH 服务端。放在后台任务里装，超时就放弃，免得 Windows 更新有问题时一直卡住。
function Install-Capability {
    Write-Log '正在安装 Windows 自带的 OpenSSH 服务端，通常 1～5 分钟，请不要关窗口…'
    $job = Start-Job -ScriptBlock { param($n) Add-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null } -ArgumentList $Capability
    $start = Get-Date
    while ($job.State -eq 'Running') {
        $sec = [int]((Get-Date) - $start).TotalSeconds
        if ($sec -ge $CapabilityTimeout) { break }
        Write-Host ("`r    已用时 {0} 秒…" -f $sec) -NoNewline
        Start-Sleep -Seconds 2
    }
    Write-Host ''
    if ($job.State -eq 'Running') {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Note "超过 $CapabilityTimeout 秒还没装完，放弃这种方式。"
        return $false
    }
    $err = ''
    try { Receive-Job $job -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($err) { Write-Note "系统自带的 OpenSSH 没有装上：$err"; return $false }
    return [bool](Get-Sshd)
}

# 从 GitHub 官方发布页找到适合本机的 MSI 安装包，返回 @{ Name; Url; Sha }。
function Find-OpenSshMsi {
    $arch = 'Win64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'ARM64' }
    elseif ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and -not $env:PROCESSOR_ARCHITEW6432) { $arch = 'Win32' }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'xiaochuan-env' }
    foreach ($a in $rel.assets) {
        if ($a.name -match "^OpenSSH-$arch-v[\d.]+\.msi$") {
            $sha = ''
            if ($a.digest -and "$($a.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1].ToLower() }
            return @{ Name = $a.name; Url = $a.browser_download_url; Sha = $sha; Tag = $rel.tag_name }
        }
    }
    throw "最新版 $($rel.tag_name) 里没有找到适合本机（$arch）的安装包"
}

# 安装包可信才返回 $true：有微软的有效数字签名，或者和 GitHub 官方公布的 SHA-256 一致。
function Test-MsiTrusted([string]$Path, [string]$Sha) {
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { return $true }
    } catch { }
    if ($Sha) {
        $got = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        if ($got -eq $Sha) { return $true }
    }
    return $false
}

function Install-FromGitHub {
    Write-Log '改从 GitHub 官方（PowerShell/Win32-OpenSSH）下载 OpenSSH 安装包…'
    $asset = $null
    try { $asset = Find-OpenSshMsi } catch {
        Write-Note "没能查到最新版：$($_.Exception.Message)"
        return $false
    }
    Write-Log "安装包：$($asset.Name)（$($asset.Tag)）"
    $msi = Join-Path $env:TEMP $asset.Name
    $urls = @($asset.Url) + @($Mirrors | ForEach-Object { $_ + $asset.Url })
    $ok = $false
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1 的进度条会把下载拖慢几十倍
    try {
        foreach ($u in $urls) {
            Write-Log "正在下载：$u"
            try {
                Invoke-WebRequest -Uri $u -OutFile $msi -UseBasicParsing -TimeoutSec 120
            } catch {
                Write-Note "下载失败：$($_.Exception.Message)"
                continue
            }
            if (Test-MsiTrusted $msi $asset.Sha) { $ok = $true; break }
            Write-Note '下载下来的文件没有通过校验（不是微软签名，也和官方校验值不一致），不使用。'
        }
    } finally { $ProgressPreference = $oldPref }
    if (-not $ok) {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Log '下载完成，校验通过，正在安装…'
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Note "安装程序返回了错误码 $($p.ExitCode)。"
        return $false
    }
    return [bool](Get-Sshd)
}

function Invoke-Install {
    Write-Step '安装 OpenSSH 服务端'
    if (Get-Sshd) {
        Write-Log 'OpenSSH 服务端已经装了，跳过安装。'
        Add-Ok 'OpenSSH 服务端已安装（之前就装了）'
        return $true
    }
    if ($DryRun) { Write-Log '演练：将会安装 OpenSSH 服务端（先用系统自带的，装不上再从 GitHub 官方下载）。'; return $true }
    if (Install-Capability) { Add-Ok 'OpenSSH 服务端已安装（Windows 自带）'; return $true }
    if (Get-Sshd) { Add-Ok 'OpenSSH 服务端已安装（Windows 自带）'; return $true }
    if (Install-FromGitHub) { Add-Ok 'OpenSSH 服务端已安装（GitHub 官方安装包）'; return $true }
    Write-Fail 'OpenSSH 服务端没有装上。'
    Write-Host '    可以手动安装，两种办法任选一种，装完再执行一次本脚本：'
    Write-Host '      1. 设置 > 系统 > 可选功能 > 查看功能（添加可选功能）> 搜索 OpenSSH > 勾选「OpenSSH 服务器」> 安装'
    Write-Host "      2. 打开 $ReleasesPage ，下载 OpenSSH-Win64-v*.msi（ARM 电脑下载 ARM64 的）双击安装"
    return $false
}

# ================================================================ 第 2 步：启动服务

function Invoke-Service {
    Write-Step '启动 sshd 服务，并设为开机自动启动'
    if ($DryRun) { Write-Log '演练：将会把 sshd 服务设为「自动」并启动。'; return }
    try {
        Set-Service -Name 'sshd' -StartupType Automatic
        if ((Get-Sshd).Status -ne 'Running') { Start-Service -Name 'sshd' }
        (Get-Sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
        Add-Ok 'sshd 服务已启动，开机会自动启动'
    } catch {
        Write-Fail "sshd 服务没有启动成功：$($_.Exception.Message)"
    }
}

# ================================================================ 第 3 步：防火墙

function Invoke-Firewall([int]$Port) {
    Write-Step "防火墙放行 SSH 端口 $Port"
    if ($DryRun) { Write-Log "演练：将会新建 / 更新防火墙入站规则 $RuleName（TCP $Port，所有网络类型）。"; return }
    try {
        if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
            Set-NetFirewallRule -Name $RuleName -Enabled True -Profile Any -Action Allow -Direction Inbound
            Get-NetFirewallRule -Name $RuleName | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port
        } else {
            New-NetFirewallRule -Name $RuleName -DisplayName "Xiaochuan SSH (TCP $Port)" -Description '小川远程 SSH 助手建的规则：允许别的电脑通过 SSH 连接本机。' `
                -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -Enabled True | Out-Null
        }
        Add-Ok "Windows 防火墙已放行 TCP $Port（规则名 $RuleName，专用 / 公用网络都放行）"
    } catch {
        Write-Fail "防火墙规则没有建成：$($_.Exception.Message)"
    }
}

# ================================================================ 第 4 步：登录设置

# 要登录的那个 Windows 用户的个人目录。用别的管理员账户通过 UAC 提权时，不能用 $env:USERPROFILE。
function Get-UserProfileDir([string]$User) {
    if ($User -eq $env:USERNAME) { return $env:USERPROFILE }
    try {
        $sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
        $dir = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if ($dir) { return [Environment]::ExpandEnvironmentVariables($dir) }
    } catch { }
    return (Join-Path (Split-Path $env:USERPROFILE -Parent) $User)
}

# -PubKey 可以直接是公钥内容，也可以是公钥文件（比如 id_ed25519.pub）的路径。返回合法的公钥行。
function Read-PubKeys([string]$Value) {
    $lines = @($Value)
    if (Test-Path -LiteralPath $Value -PathType Leaf) { $lines = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Value).Path) }
    $keys = @()
    foreach ($l in $lines) {
        $l = "$l".Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-\S+|sk-\S+)\s+[A-Za-z0-9+/]+=*(\s.*)?$') { $keys += $l }
        elseif ($l -match 'PRIVATE KEY') { throw '给的是私钥。私钥不能给别人，也不能放到这台电脑上，要用的是 .pub 结尾的公钥。' }
        else { throw "这不是合法的公钥：$l" }
    }
    if ($keys.Count -eq 0) { throw '没有读到公钥。' }
    return $keys
}

# 把公钥追加到 authorized_keys 文件里（已经有的不重复加）。文件不能带 BOM，否则 sshd 不认。
function Add-KeysToFile([string]$File, [string[]]$Keys) {
    $dir = Split-Path $File -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = @()
    if (Test-Path -LiteralPath $File) { $existing = @([IO.File]::ReadAllLines($File) | Where-Object { "$_".Trim() }) }
    $bodies = @($existing | ForEach-Object { ($_ -split '\s+')[1] })
    $added = 0
    foreach ($k in $Keys) {
        $body = ($k -split '\s+')[1]
        if ($bodies -notcontains $body) { $existing += $k; $bodies += $body; $added++ }
    }
    [IO.File]::WriteAllText($File, (($existing -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    return $added
}

function Invoke-LoginSetup([string]$User, [bool]$UserIsAdmin) {
    Write-Step '登录设置（公钥、默认命令行）'

    # ---- 默认命令行
    if ($Shell -eq 'powershell') {
        if ($DryRun) { Write-Log '演练：将会把远程登录后的命令行设为 PowerShell。' }
        else {
            try {
                if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' | Out-Null }
                New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $PsExe -PropertyType String -Force | Out-Null
                Add-Ok '远程登录后的命令行已设为 PowerShell'
            } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
        }
    } elseif ($Shell -eq 'cmd') {
        if ($DryRun) { Write-Log '演练：将会把远程登录后的命令行恢复为 cmd。' }
        else {
            try {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue
                Add-Ok '远程登录后的命令行已恢复为 cmd（Windows 默认）'
            } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
        }
    } else {
        Write-Log '默认命令行：不改动（想换成 PowerShell 可以加参数 -Shell powershell）。'
    }

    # ---- 公钥
    if (-not $PubKey) {
        Write-Log '没有给公钥：用 Windows 账户的密码登录（想免密码登录可以加参数 -PubKey）。'
        return
    }
    try {
        $keys = @(Read-PubKeys $PubKey)
    } catch {
        Write-Fail "公钥没有写入：$($_.Exception.Message)"; return
    }
    $userFile = Join-Path (Get-UserProfileDir $User) '.ssh\authorized_keys'
    if ($DryRun) {
        Write-Log "演练：将会把 $($keys.Count) 个公钥写入 $userFile"
        if ($UserIsAdmin) { Write-Log "演练：$User 是管理员，还会写入 $AdminKeys" }
        return
    }
    try {
        $n = Add-KeysToFile $userFile $keys
        if ($UserIsAdmin) {
            # 管理员账户登录时 sshd 只认这个文件，并且要求它只有 Administrators 和 SYSTEM 能访问。
            $n = [Math]::Max($n, (Add-KeysToFile $AdminKeys $keys))
            & icacls.exe $AdminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "设置 $AdminKeys 的权限失败（icacls 返回 $LASTEXITCODE）" }
        }
        if ($n -gt 0) { Add-Ok "公钥已写入（$($keys.Count) 个），用户 $User 可以免密码登录" }
        else { Add-Ok "公钥之前就已经写入过了，用户 $User 可以免密码登录" }
    } catch {
        Write-Fail "公钥没有写入：$($_.Exception.Message)"
    }
}

# ================================================================ 第 5 步：检查并显示连接方式

function Get-LocalIPv4 {
    $list = @()
    try {
        $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred' }
        foreach ($a in $addrs) {
            $label = $a.InterfaceAlias
            $p = $a.IPAddress.Split('.')
            if ([int]$p[0] -eq 100 -and [int]$p[1] -ge 64 -and [int]$p[1] -le 127) { $label = "$label，Tailscale 等组网地址，不在同一个局域网也能连" }
            $list += [pscustomobject]@{ IP = $a.IPAddress; Label = $label }
        }
    } catch { }
    return $list
}

function Show-Connect([string]$User, [int]$Port) {
    $portArg = ''
    if ($Port -ne 22) { $portArg = " -p $Port" }
    $u = $User
    if ($u -match '\s') { $u = "`"$u`"" }
    Write-Host ''
    Write-Host '---------------- 从别的电脑连接 ----------------' -ForegroundColor Cyan
    $ips = @(Get-LocalIPv4)
    if ($ips.Count -eq 0) {
        Write-Host "  没有查到本机的 IP 地址。连接命令的格式是：ssh$portArg $u@本机IP"
    } else {
        foreach ($i in $ips) {
            Write-Host ("  ssh{0} {1}@{2}" -f $portArg, $u, $i.IP) -ForegroundColor Green -NoNewline
            Write-Host "    （$($i.Label)）"
        }
    }
    Write-Host "  直接远程执行一条命令：在上面的命令后面加上要执行的内容，比如  ssh$portArg $u@IP hostname"
    Write-Host "  用户名：$User"
    Write-Host '  密码：这个 Windows 账户的登录密码。用微软账户登录 Windows 的，是微软账户的密码，不是 PIN 码。'
    Write-Host '        账户没有设密码的话不能用密码登录，要先给账户设一个密码，或者用 -PubKey 写入公钥。'
    Write-Host '  192.168 / 10 开头的地址只有在同一个局域网里才能连；电脑睡眠或关机时连不上。'
    Write-Host '------------------------------------------------' -ForegroundColor Cyan
}

function Invoke-Check([string]$User, [int]$Port) {
    Write-Step '检查 SSH 端口，显示连接方式'
    if ($DryRun) { Write-Log "演练：将会检查本机 TCP $Port 有没有 SSH 应答。"; Show-Connect $User $Port; return }
    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
        $ok = Test-SshPort $Port
        if (-not $ok) { Start-Sleep -Seconds 1 }
    }
    if ($ok) {
        Add-Ok "SSH 端口 $Port 已经通了，可以从别的电脑连接"
        Show-Connect $User $Port
    } else {
        Write-Fail "本机的 SSH 端口 $Port 没有应答，sshd 可能没有正常工作。可以看「事件查看器 > 应用程序和服务日志 > OpenSSH」里的报错。"
    }
}

# ================================================================ 查看状态 / 关闭

function Show-Status {
    Write-Host "小川远程 SSH 助手 $Version（Windows）· 当前状态"
    $svc = Get-Sshd
    if (-not $svc) {
        Write-Host '  × OpenSSH 服务端：没有安装' -ForegroundColor Red
        return 1
    }
    $bad = 0
    $port = Get-SshPort
    Write-Host '  √ OpenSSH 服务端：已安装' -ForegroundColor Green
    if ($svc.Status -eq 'Running') { Write-Host '  √ sshd 服务：正在运行' -ForegroundColor Green }
    else { Write-Host "  × sshd 服务：没有运行（$($svc.Status)）" -ForegroundColor Red; $bad++ }
    if ($svc.StartType -eq 'Automatic') { Write-Host '  √ 开机自动启动：是' -ForegroundColor Green }
    else { Write-Host "  × 开机自动启动：否（$($svc.StartType)）" -ForegroundColor Red; $bad++ }
    $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    if ($rule -and "$($rule.Enabled)" -eq 'True') { Write-Host "  √ 防火墙：已放行（规则 $RuleName）" -ForegroundColor Green }
    else { Write-Host "  - 防火墙：没有本脚本建的规则 $RuleName（系统自带的规则可能只放行专用网络）" }
    if (Test-SshPort $port) { Write-Host "  √ SSH 端口 $port：有应答" -ForegroundColor Green }
    else { Write-Host "  × SSH 端口 $port：没有应答" -ForegroundColor Red; $bad++ }
    $sh = ''
    try { $sh = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop).DefaultShell } catch { }
    if ($sh) { Write-Host "  - 远程登录后的命令行：$sh" } else { Write-Host '  - 远程登录后的命令行：cmd（Windows 默认）' }
    if ($bad -eq 0) { Show-Connect $env:USERNAME $port }
    return $bad
}

function Invoke-Off {
    $script:TotalSteps = 2
    Write-Step '停止 sshd 服务，并取消开机自动启动'
    if (-not (Get-Sshd)) {
        Write-Log '这台电脑没有装 OpenSSH 服务端，本来就不能被 SSH 连接。'
        Add-Info '没有装 OpenSSH 服务端，不需要关闭'
    } elseif ($DryRun) {
        Write-Log '演练：将会停止 sshd 服务，并把它设为「禁用」。'
    } else {
        try {
            Stop-Service -Name 'sshd' -Force
            Set-Service -Name 'sshd' -StartupType Disabled
            Add-Ok 'sshd 服务已停止，开机不会再启动（这台电脑不能再被 SSH 连接）'
        } catch { Write-Fail "sshd 服务没有停掉：$($_.Exception.Message)" }
    }
    Write-Step '删除防火墙放行规则'
    if (-not (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue)) {
        Write-Log "没有本脚本建的防火墙规则 $RuleName，不用删。"
    } elseif ($DryRun) {
        Write-Log "演练：将会删除防火墙规则 $RuleName。"
    } else {
        try { Remove-NetFirewallRule -Name $RuleName; Add-Ok "防火墙规则 $RuleName 已删除" }
        catch { Write-Fail "防火墙规则没有删掉：$($_.Exception.Message)" }
    }
    Add-Info 'OpenSSH 服务端本身没有卸载，写入过的公钥也还在；再执行一次 enable-ssh.bat 就能重新打开'
}

# ================================================================ 主流程

if ($Help) {
    Write-Host @"
小川远程 SSH 助手 $Version（Windows）

让这台 Windows 电脑可以被 SSH 连接，之后就能从别的电脑远程执行命令行：
安装 OpenSSH 服务端、启动并设为开机自启、防火墙放行端口，最后显示连接命令。

用法：
  双击 enable-ssh.bat                   打开 SSH，用 Windows 账户的密码登录
  enable-ssh.bat -PubKey "ssh-ed25519 AAAA... 备注"
                                        同时写入公钥，可以免密码登录（也可以给 .pub 文件的路径）
  enable-ssh.bat -Shell powershell      远程登录后的命令行用 PowerShell（默认不改动，是 cmd）
  enable-ssh.bat -Shell cmd             远程登录后的命令行恢复为 cmd
  enable-ssh.bat -Status                只查看现在的状态和连接命令，不做任何修改
  enable-ssh.bat -Off                   关闭：停止 sshd 服务并删除防火墙规则
  enable-ssh.bat -DryRun                演练：只显示将要做的事，不做任何修改
"@
    Exit-Script 0
}

if ($Status) {
    $bad = 1
    try { $bad = Show-Status } catch { Write-Host "查看状态时出错：$($_.Exception.Message)" -ForegroundColor Red }
    if ($bad -gt 0) { Exit-Script 1 }
    Exit-Script 0
}

# 除了「演练」，其余都要管理员权限：只弹一次 UAC。
if (-not $DryRun -and -not (Test-Admin)) {
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
        Exit-Script 1
    }
}

# 要远程登录的是「当前登录 Windows 的那个用户」。如果 UAC 用的是另一个管理员账户，
# 说明当前登录的用户不是管理员，公钥要写到他自己的目录里。
$targetUser = $env:USERNAME
$targetIsAdmin = $true
if ($DryRun) { $targetIsAdmin = Test-Admin }
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) { $targetUser = $OrigUser; $targetIsAdmin = $false }

if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }

try {
    if ($Off) {
        Invoke-Off
    } else {
        $script:TotalSteps = 5
        if (Invoke-Install) {
            Invoke-Service
            $port = Get-SshPort
            Invoke-Firewall $port
            Invoke-LoginSetup $targetUser $targetIsAdmin
            Invoke-Check $targetUser $port
        }
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
}

Show-Result
if ($script:BadCount -gt 0) { Exit-Script 1 }
Exit-Script 0
