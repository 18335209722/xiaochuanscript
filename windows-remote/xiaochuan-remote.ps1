# 小川远程助手 · Windows 版
# 一个脚本把「远程用命令行操作这台 Windows 电脑」要做的事全做完：
#   1. 安装 Windows 自带的 OpenSSH 服务端（已经装了就跳过；系统自带的装不上时改从 GitHub 官方下载安装包）。
#   2. 启动 sshd 服务，并设为开机自动启动。
#   3. 防火墙放行 SSH 端口（默认 22）。
#   4. 登录设置：把远程登录后的命令行设为 PowerShell（用 Termius 等工具登录进来直接是 PowerShell）；
#      可选写入公钥（-PubKey）、给账户设密码（-SetPassword）、启用 Administrator（-EnableAdmin）、打开密码登录（-AllowPassword）。
#   5. 登录检查：列出本机账户，指出该用哪个账户登录；检查 sshd 配置有没有挡住登录。
#   6. 安装 Claude Code 命令行（claude），并加进 PATH，命令窗口里直接输入 claude 就能用。
#   7. 检查 SSH 端口确实通了，并显示从别的电脑连接要用的命令。
# 直接双击 xiaochuan-remote.bat 即可，Windows 会弹一次 UAC，点「是」。重复执行没有副作用。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [string]$PubKey = '',        # 写入公钥免密登录：公钥内容，或 .pub 文件路径
    [string]$ForUser = '',       # 公钥写给哪个账户；默认是当前登录的账户
    # 远程登录后的命令行。不传 = 设为 PowerShell（已经手动设成别的 shell 的话保持不动）。
    [ValidateSet('', 'powershell', 'cmd', 'keep')]
    [string]$Shell = '',
    [string]$SetPassword = '',   # 给这个账户设登录密码（会提示输入两遍）；密码登录必须有密码
    [switch]$EnableAdmin,        # 启用内置 Administrator 账户（Windows 默认把它禁用了）
    [switch]$AllowPassword,      # 在 sshd_config 里打开密码登录并重启 sshd
    [switch]$NoClaude,           # 不安装 Claude 命令行
    [switch]$ClaudeOnly,         # 只安装 Claude 命令行，不动 SSH（不需要管理员权限）
    [switch]$UpdateClaude,       # Claude 命令行已经装了的话，升级到最新版
    [switch]$Status,             # 只查看现在的状态，不做任何修改
    [switch]$Off,                # 关闭 SSH：停止 sshd 服务并删除防火墙规则
    [switch]$DryRun,             # 演练：只显示将要做的事
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
# Claude Code 命令行
$ClaudeInstallUrl = 'https://claude.ai/install.ps1'
$ClaudeNpmPackage = '@anthropic-ai/claude-code'
$ClaudeBinDir = Join-Path $env:USERPROFILE '.local\bin'
$ClaudeExe = Join-Path $ClaudeBinDir 'claude.exe'

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

# 远程登录后用的命令行（注册表 HKLM\SOFTWARE\OpenSSH 的 DefaultShell）。没有设过返回空字符串，这时 sshd 用 cmd。
function Get-DefaultShell {
    try { return "$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop).DefaultShell)" } catch { return '' }
}

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

# ================================================================ 账户信息

# 本机「管理员组」成员的账户名（不含机器名前缀）。查不到返回空数组。
function Get-AdminMembers {
    $names = @()
    try {
        # 中文 / 英文系统组名不一样，用 SID S-1-5-32-544 取管理员组。
        $grp = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
        foreach ($m in (Get-LocalGroupMember -Name ($grp.Split('\')[-1]) -ErrorAction Stop)) {
            $names += $m.Name.Split('\')[-1]
        }
    } catch { }
    return $names
}

function Test-UserIsAdmin([string]$User) {
    $members = @(Get-AdminMembers)
    if ($members.Count -gt 0) { return ($members -contains $User) }
    # 管理员组查不出来时：只能确定「现在这个有管理员权限的用户」是管理员。
    return ($User -eq $env:USERNAME -and (Test-Admin))
}

# 返回一个账户的诊断对象。$null 表示本机没有这个本地账户（可能是微软账户 / 域账户）。
function Get-AccountInfo([string]$Name) {
    try { $u = Get-LocalUser -Name $Name -ErrorAction Stop } catch { return $null }
    # 「有没有密码」Windows 没有直接接口：不要求密码、并且从来没设过密码的，多半没有密码。
    $hasPwd = $true
    if (-not $u.PasswordRequired -and -not $u.PasswordLastSet) { $hasPwd = $false }
    return [pscustomobject]@{
        Name = $u.Name
        Enabled = $u.Enabled
        LikelyHasPassword = $hasPwd
        IsAdmin = (Test-UserIsAdmin $u.Name)
    }
}

# 一个 Windows 用户的个人目录。用别的管理员账户通过 UAC 提权时，不能用 $env:USERPROFILE。
function Get-UserProfileDir([string]$User) {
    if ($User -eq $env:USERNAME) { return $env:USERPROFILE }
    try {
        $sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
        $dir = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if ($dir) { return [Environment]::ExpandEnvironmentVariables($dir) }
    } catch { }
    return (Join-Path (Split-Path $env:USERPROFILE -Parent) $User)
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
            New-NetFirewallRule -Name $RuleName -DisplayName "Xiaochuan SSH (TCP $Port)" -Description '小川远程助手建的规则：允许别的电脑通过 SSH 连接本机。' `
                -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -Enabled True | Out-Null
        }
        Add-Ok "Windows 防火墙已放行 TCP $Port（规则名 $RuleName，专用 / 公用网络都放行）"
    } catch {
        Write-Fail "防火墙规则没有建成：$($_.Exception.Message)"
    }
}

# ================================================================ 第 4 步：登录设置

# 默认命令行：不传 -Shell 时设为 PowerShell；已经手动设成别的 shell（比如 pwsh、bash）就不覆盖。
function Set-LoginShell {
    $cur = Get-DefaultShell
    $want = $Shell
    if (-not $want) {
        if ($cur -and $cur -ne $PsExe) { $want = 'keep' } else { $want = 'powershell' }
    }
    if ($want -eq 'powershell') {
        if ($cur -eq $PsExe) {
            Write-Log '远程登录后的命令行已经是 PowerShell，不用改。'
            Add-Ok '远程登录后的命令行是 PowerShell（之前就设了）'
        } elseif ($DryRun) { Write-Log '演练：将会把远程登录后的命令行设为 PowerShell。' }
        else {
            try {
                if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
                New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $PsExe -PropertyType String -Force | Out-Null
                Add-Ok '远程登录后的命令行已设为 PowerShell（已经连着的窗口要断开重新登录才生效）'
            } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
        }
    } elseif ($want -eq 'cmd') {
        if (-not $cur) {
            Write-Log '远程登录后的命令行已经是 cmd，不用改。'
            Add-Ok '远程登录后的命令行是 cmd（Windows 默认）'
        } elseif ($DryRun) { Write-Log '演练：将会把远程登录后的命令行恢复为 cmd。' }
        else {
            try {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop
                Add-Ok '远程登录后的命令行已恢复为 cmd（Windows 默认）'
            } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
        }
    } elseif ($cur) {
        Write-Log "远程登录后的命令行：保持现在的 $cur，不改动（想换成 PowerShell 可以加参数 -Shell powershell）。"
    } else {
        Write-Log '远程登录后的命令行：保持 cmd，不改动。'
    }
}

function Enable-BuiltinAdmin {
    if ($DryRun) { Write-Log '演练：将会启用内置 Administrator 账户。'; return }
    try {
        Enable-LocalUser -Name 'Administrator' -ErrorAction Stop
        $info = Get-AccountInfo 'Administrator'
        if ($info -and -not $info.LikelyHasPassword) {
            Write-Note 'Administrator 已启用，但还没有密码，仍不能用密码登录。请再加 -SetPassword Administrator 给它设密码。'
        }
        Add-Ok '内置 Administrator 账户已启用'
    } catch { Write-Fail "启用 Administrator 失败：$($_.Exception.Message)" }
}

function Set-AccountPassword([string]$User) {
    if ($DryRun) { Write-Log "演练：将会提示为账户 $User 设置登录密码。"; return }
    Write-Host "  现在为账户「$User」设置一个登录密码（输入时不显示是正常的）。" -ForegroundColor Cyan
    $p1 = Read-Host '  输入新密码' -AsSecureString
    $p2 = Read-Host '  再输一遍' -AsSecureString
    $s1 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
    $s2 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
    if (-not $s1) { Write-Fail '密码为空，没有设置。'; return }
    if ($s1 -ne $s2) { Write-Fail '两次输入不一致，没有设置。'; return }
    try {
        Set-LocalUser -Name $User -Password $p1 -ErrorAction Stop
        Add-Ok "账户 $User 的登录密码已设置，现在可以用密码远程登录"
    } catch { Write-Fail "设置密码失败：$($_.Exception.Message)" }
}

# 在 sshd_config 的全局部分（Match 之前）把 PasswordAuthentication 设为 yes，并重启 sshd。
function Enable-PasswordAuth {
    if (-not (Test-Path -LiteralPath $SshdConfig)) { Write-Fail "没找到 $SshdConfig，密码登录没有打开。"; return }
    if ($DryRun) { Write-Log '演练：将会把 sshd_config 里的 PasswordAuthentication 设为 yes 并重启 sshd。'; return }
    try {
        $out = New-Object System.Collections.ArrayList
        $done = $false; $inMatch = $false
        foreach ($raw in [IO.File]::ReadAllLines($SshdConfig)) {
            $t = $raw.Trim()
            if ($t -match '^Match\s') { $inMatch = $true }
            if (-not $inMatch -and $t -match '^#?\s*PasswordAuthentication\s') {
                if (-not $done) { [void]$out.Add('PasswordAuthentication yes'); $done = $true }
                continue
            }
            [void]$out.Add($raw)
        }
        if (-not $done) { [void]$out.Insert(0, 'PasswordAuthentication yes') }
        $bak = "$SshdConfig.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item -LiteralPath $SshdConfig -Destination $bak -Force
        [IO.File]::WriteAllLines($SshdConfig, $out, (New-Object Text.UTF8Encoding($false)))
        Restart-Service -Name 'sshd'
        Add-Ok "已打开密码登录并重启 sshd（原配置备份在 $bak）"
    } catch { Write-Fail "打开密码登录失败：$($_.Exception.Message)" }
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

function Add-PubKey([string]$User) {
    try { $keys = @(Read-PubKeys $PubKey) } catch { Write-Fail "公钥没有写入：$($_.Exception.Message)"; return }
    $isAdmin = Test-UserIsAdmin $User
    $userFile = Join-Path (Get-UserProfileDir $User) '.ssh\authorized_keys'
    if ($DryRun) {
        Write-Log "演练：将会把 $($keys.Count) 个公钥写入 $userFile"
        if ($isAdmin) { Write-Log "演练：$User 是管理员，还会写入 $AdminKeys" }
        return
    }
    try {
        $n = Add-KeysToFile $userFile $keys
        if ($isAdmin) {
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

function Invoke-LoginSetup([string]$User) {
    Write-Step '登录设置（PowerShell 命令行、公钥、密码）'
    Set-LoginShell
    if ($EnableAdmin) { Enable-BuiltinAdmin }
    if ($SetPassword) { Set-AccountPassword $SetPassword }
    if ($AllowPassword) { Enable-PasswordAuth }
    if ($PubKey) { Add-PubKey $User }
    else { Write-Log '没有给公钥：用 Windows 账户的密码登录（想免密码登录可以加参数 -PubKey）。' }
}

# ================================================================ 第 5 步：登录检查

# 列出本机账户，指出该用哪个账户登录、哪些账户登录会被拒。只看不改。
function Show-Accounts([string]$LoginUser) {
    $all = @()
    try { $all = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled }) } catch { }
    if ($all.Count -gt 0) {
        Write-Host '  本机启用的账户：'
        foreach ($u in $all) {
            $info = Get-AccountInfo $u.Name
            $tags = @()
            if ($info.IsAdmin) { $tags += '管理员' }
            if (-not $info.LikelyHasPassword) { $tags += '疑似没有密码，不能用密码登录' }
            $tagStr = ''
            if ($tags.Count) { $tagStr = ' [' + ($tags -join '，') + ']' }
            Write-Host ("    - {0}{1}" -f $u.Name, $tagStr)
        }
    }
    $me = Get-AccountInfo $LoginUser
    if (-not $me) {
        Write-Note "$LoginUser 不是本机的本地账户（可能是微软账户或域账户）。用微软账户登录 Windows 的，SSH 密码是微软账户的密码，不是 PIN 码。"
        Add-Info "用账户 $LoginUser 远程登录（微软账户用微软账户的密码，不是 PIN 码）"
    } elseif (-not $me.LikelyHasPassword) {
        Write-Note "$LoginUser 疑似没有设登录密码，用密码登录会被拒。加参数 -SetPassword $LoginUser 设一个，或者用 -PubKey 写入公钥免密码登录。"
        Add-Info "账户 $LoginUser 疑似没有密码：要先 -SetPassword $LoginUser 或 -PubKey 才能远程登录"
    } else {
        Add-Ok "用账户 $LoginUser 远程登录（密码是它的 Windows 登录密码）"
    }
    # Administrator 的坑：Windows 默认把它禁用了，用它登录会直接被拒。
    $adminInfo = Get-AccountInfo 'Administrator'
    if ($adminInfo -and -not $adminInfo.Enabled) {
        Write-Note '内置 Administrator 账户是禁用的（Windows 默认如此），用 Administrator 登录会直接被拒，请用上面列出的账户名。一定要用 Administrator 的话加参数 -EnableAdmin。'
    } elseif ($adminInfo -and -not $adminInfo.LikelyHasPassword) {
        Write-Note '内置 Administrator 已启用但疑似没有密码，不能用密码登录。加参数 -SetPassword Administrator 给它设一个。'
    }
}

# 检查 sshd_config 的全局部分有没有关掉密码 / 公钥登录、有没有登录名单限制。只看不改。
function Show-ConfigCheck {
    if (-not (Test-Path -LiteralPath $SshdConfig)) { Write-Log "还没有 $SshdConfig（sshd 第一次启动后才会生成），跳过配置检查。"; return }
    $pwAuth = $true; $pubAuth = $true
    $limits = @()
    $inMatch = $false
    try {
        foreach ($raw in [IO.File]::ReadAllLines($SshdConfig)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            if ($line -match '^Match\s') { $inMatch = $true; continue }
            if ($inMatch) { continue }
            if ($line -match '^PasswordAuthentication\s+(\S+)') { $pwAuth = ($Matches[1] -eq 'yes') }
            elseif ($line -match '^PubkeyAuthentication\s+(\S+)') { $pubAuth = ($Matches[1] -eq 'yes') }
            elseif ($line -match '^(AllowUsers|AllowGroups|DenyUsers|DenyGroups)\s+(.+)') { $limits += "$($Matches[1]) $($Matches[2])" }
        }
    } catch { Write-Note "读不了 $SshdConfig：$($_.Exception.Message)"; return }
    if ($pwAuth) { Write-Log 'sshd 配置：密码登录是开着的。' }
    else { Write-Note 'sshd 配置把密码登录关掉了（PasswordAuthentication no）。想用密码登录加参数 -AllowPassword，或者用 -PubKey 走公钥。' }
    if (-not $pubAuth) { Write-Note 'sshd 配置把公钥登录关掉了（PubkeyAuthentication no）。' }
    foreach ($l in $limits) { Write-Note "sshd 配置里有登录名单限制：$l（不在允许名单里 / 在拒绝名单里的账户连不上）" }
    if ($pwAuth -and $limits.Count -eq 0) { Add-Ok 'sshd 配置没有挡住密码登录' }
}

function Invoke-LoginCheck([string]$LoginUser) {
    Write-Step '登录检查（该用哪个账户、配置有没有挡住登录）'
    Show-Accounts $LoginUser
    Show-ConfigCheck
}

# ================================================================ 第 6 步：Claude 命令行

# 找到 claude 命令的位置：先看官方安装的位置，再看 PATH 里有没有（比如 npm 装的 claude.cmd）。没有返回空字符串。
function Find-Claude {
    if (Test-Path -LiteralPath $ClaudeExe -PathType Leaf) { return $ClaudeExe }
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

# 用 Anthropic 官方安装脚本安装。脚本会从 downloads.claude.ai 下载 claude.exe 并核对校验值（SHA-256）。
function Install-ClaudeNative {
    $tmp = Join-Path $env:TEMP ("claude-install-{0}.ps1" -f $PID)
    Write-Log "正在下载官方安装脚本：$ClaudeInstallUrl"
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $ClaudeInstallUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 60
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
    return (Test-Path -LiteralPath $ClaudeExe -PathType Leaf)
}

# 官方安装脚本用不了时的备用办法：电脑上有 npm 就用 npm 装。
function Install-ClaudeWithNpm {
    $npm = Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) {
        Write-Log '这台电脑没有 npm（Node.js），不能用 npm 这个备用办法。'
        return $false
    }
    Write-Log "改用 npm 安装：npm install -g $ClaudeNpmPackage"
    try {
        & $npm.Source install -g $ClaudeNpmPackage
        if ($LASTEXITCODE -ne 0) { Write-Note "npm 返回了错误码 $LASTEXITCODE。"; return $false }
    } catch {
        Write-Note "npm 安装出错：$($_.Exception.Message)"
        return $false
    }
    return [bool](Find-Claude)
}

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

function Test-ClaudeInPath {
    return ((Test-InPathList (Get-RawPath 'User') $ClaudeBinDir) -or (Test-InPathList (Get-RawPath 'Machine') $ClaudeBinDir))
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

function Show-ClaudeUsage {
    Write-Host ''
    Write-Host '---------------- Claude 命令行怎么用 ----------------' -ForegroundColor Cyan
    Write-Host '  1. 新开一个命令窗口（SSH / Termius 远程登录的要断开重新登录），用 cd 进到要干活的目录，输入：' -NoNewline
    Write-Host '  claude' -ForegroundColor Green
    Write-Host '  2. 第一次用要登录 Claude 账户。远程登录时这台电脑弹不出浏览器：把屏幕上显示的网址复制到自己电脑的'
    Write-Host '     浏览器里打开，登录后把网页给的代码粘贴回命令窗口。'
    Write-Host '  常用：claude --version 看版本；claude update 升级；claude -p "问题" 只问一句就退出。'
    Write-Host '  使用时这台电脑要能访问 Anthropic 的服务（claude.ai / api.anthropic.com）。'
    Write-Host '------------------------------------------------------' -ForegroundColor Cyan
}

# $User 是要远程登录的那个 Windows 用户。Claude 是装在用户自己目录里的，只能给「现在运行脚本的这个用户」装。
function Invoke-Claude([string]$User) {
    Write-Step '安装 Claude 命令行（命令窗口里直接输入 claude）'
    if ($User -ne $env:USERNAME) {
        Write-Note "UAC 用的是另一个管理员账户（$($env:USERNAME)），不能替 $User 安装 Claude。"
        Write-Host "    请在 $User 自己的命令窗口里执行：xiaochuan-remote.bat -ClaudeOnly（不需要管理员权限）"
        Add-Info "Claude 命令行没有安装：要在 $User 的命令窗口里执行 xiaochuan-remote.bat -ClaudeOnly"
        return
    }

    # ---- 安装 / 升级
    $path = Find-Claude
    if ($path -and -not $UpdateClaude) {
        Write-Log "已经装了：$path，跳过安装。想升级到最新版可以加参数 -UpdateClaude。"
    } elseif ($path) {
        if ($DryRun) { Write-Log "演练：将会执行 claude update，把 $path 升级到最新版。" }
        else {
            Write-Log "正在升级（现在是 $(Get-ClaudeVersion $path)）…"
            try {
                & $path update
                if ($LASTEXITCODE -ne 0) { throw "claude update 返回了错误码 $LASTEXITCODE" }
            } catch { Write-Fail "Claude 命令行升级没有成功：$($_.Exception.Message)" }
        }
    } elseif ($DryRun) {
        Write-Log "演练：将会用官方安装脚本 $ClaudeInstallUrl 安装 Claude Code 到 $ClaudeExe（用不了时改用 npm），并把 $ClaudeBinDir 加进 PATH。"
        return
    } elseif (-not (Install-ClaudeNative) -and -not (Install-ClaudeWithNpm)) {
        Write-Fail 'Claude 命令行没有装上。'
        Write-Host '    最常见的原因是网络：这台电脑要能访问 claude.ai 和 downloads.claude.ai。'
        Write-Host '    网络调好之后执行 xiaochuan-remote.bat -ClaudeOnly 再装一次；也可以在 PowerShell 里手动执行：'
        Write-Host "      irm $ClaudeInstallUrl | iex"
        return
    }

    # ---- PATH（npm 装的 claude 在 npm 的全局目录里，装 Node.js 时已经在 PATH 里了）
    if (Test-Path -LiteralPath $ClaudeExe -PathType Leaf) {
        if (Test-ClaudeInPath) { Write-Log "$ClaudeBinDir 已经在 PATH 里，不用改。" }
        elseif ($DryRun) { Write-Log "演练：将会把 $ClaudeBinDir 加进当前用户的 PATH。" }
        else {
            try { Add-UserPath $ClaudeBinDir; Write-Log "已把 $ClaudeBinDir 加进 PATH（新开的命令窗口里生效）。" }
            catch { Write-Fail "PATH 没有改成，命令窗口里不能直接输入 claude：$($_.Exception.Message)"; return }
        }
    }
    if ($DryRun) { return }

    # ---- 检查
    $path = Find-Claude
    $ver = ''
    if ($path) { $ver = Get-ClaudeVersion $path }
    if (-not $ver) { Write-Fail "claude 运行不了：$path --version 没有返回版本号。"; return }
    Add-Ok "Claude 命令行可以用了：$ver，命令窗口里直接输入 claude"
    Show-ClaudeUsage
}

# ================================================================ 第 7 步：检查并显示连接方式

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
    Write-Host "  Termius 里新建主机：地址填上面的 IP，端口 $Port，用户名 $User，密码填 Windows 登录密码。"
    Write-Host "  直接远程执行一条命令：在 ssh 命令后面加上要执行的内容，比如  ssh$portArg $u@IP hostname"
    Write-Host '  密码：这个 Windows 账户的登录密码。用微软账户登录 Windows 的，是微软账户的密码，不是 PIN 码。'
    Write-Host '        账户没有设密码的话不能用密码登录，要先 -SetPassword 设一个密码，或者用 -PubKey 写入公钥。'
    Write-Host '  192.168 / 10 开头的地址只有在同一个局域网里才能连；电脑睡眠或关机时连不上。'
    Write-Host '  电脑有公网 IP 的话，22 端口会被人扫描撞库，建议只用公钥登录或者走 Tailscale。'
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
    Write-Host "小川远程助手 $Version（Windows）· 当前状态"
    $bad = 0
    $sshOk = $false
    $port = Get-SshPort
    $svc = Get-Sshd
    if (-not $svc) {
        Write-Host '  × OpenSSH 服务端：没有安装' -ForegroundColor Red; $bad++
    } else {
        $sshOk = $true
        Write-Host '  √ OpenSSH 服务端：已安装' -ForegroundColor Green
        if ($svc.Status -eq 'Running') { Write-Host '  √ sshd 服务：正在运行' -ForegroundColor Green }
        else { Write-Host "  × sshd 服务：没有运行（$($svc.Status)）" -ForegroundColor Red; $bad++; $sshOk = $false }
        if ($svc.StartType -eq 'Automatic') { Write-Host '  √ 开机自动启动：是' -ForegroundColor Green }
        else { Write-Host "  × 开机自动启动：否（$($svc.StartType)）" -ForegroundColor Red; $bad++ }
        $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
        if ($rule -and "$($rule.Enabled)" -eq 'True') { Write-Host "  √ 防火墙：已放行（规则 $RuleName）" -ForegroundColor Green }
        else { Write-Host "  - 防火墙：没有本脚本建的规则 $RuleName（系统自带的规则可能只放行专用网络）" }
        if (Test-SshPort $port) { Write-Host "  √ SSH 端口 $port：有应答" -ForegroundColor Green }
        else { Write-Host "  × SSH 端口 $port：没有应答" -ForegroundColor Red; $bad++; $sshOk = $false }
        $sh = Get-DefaultShell
        if ($sh -eq $PsExe) { Write-Host '  √ 远程登录后的命令行：PowerShell' -ForegroundColor Green }
        elseif ($sh) { Write-Host "  - 远程登录后的命令行：$sh" }
        else { Write-Host '  - 远程登录后的命令行：cmd（Windows 默认；再执行一次本脚本会换成 PowerShell）' }
    }
    $claude = Find-Claude
    if (-not $claude) {
        Write-Host '  × Claude 命令行：没有安装' -ForegroundColor Red; $bad++
    } else {
        $ver = Get-ClaudeVersion $claude
        if ($ver) { Write-Host "  √ Claude 命令行：$ver（$claude）" -ForegroundColor Green }
        else { Write-Host "  × Claude 命令行：$claude 运行不了" -ForegroundColor Red; $bad++ }
        if ($claude -ne $ClaudeExe -or (Test-ClaudeInPath)) { Write-Host '  √ PATH：命令窗口里可以直接输入 claude' -ForegroundColor Green }
        else { Write-Host "  × PATH：$ClaudeBinDir 不在 PATH 里，命令窗口里不能直接输入 claude" -ForegroundColor Red; $bad++ }
    }
    if ($svc) {
        Write-Host ''
        Show-Accounts $env:USERNAME
        Show-ConfigCheck
    }
    if ($sshOk) { Show-Connect $env:USERNAME $port }
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
    Add-Info 'OpenSSH 服务端和 Claude 命令行都没有卸载，写入过的公钥也还在；再执行一次 xiaochuan-remote.bat 就能重新打开'
}

# ================================================================ 主流程

if ($Help) {
    Write-Host @"
小川远程助手 $Version（Windows）

一个脚本把「远程用命令行操作这台电脑」要做的事全做完：打开 SSH（安装 OpenSSH 服务端、开机自启、
防火墙放行）、远程登录后的命令行设为 PowerShell、检查登录会不会被拒、安装 Claude 命令行，
最后显示连接命令。

用法：
  双击 xiaochuan-remote.bat             全部做完；用 Windows 账户的密码登录
  xiaochuan-remote.bat -Status          只查看现在的状态和连接命令，不做任何修改
  xiaochuan-remote.bat -DryRun          演练：只显示将要做的事，不做任何修改
  xiaochuan-remote.bat -Off             关闭 SSH：停止 sshd 服务并删除防火墙规则

登录相关（可以和上面的一起用）：
  -PubKey "ssh-ed25519 AAAA... 备注"    写入公钥，可以免密码登录（也可以给 .pub 文件的路径）
  -ForUser 账户名                       公钥写给哪个账户（默认是当前登录的账户）
  -SetPassword 账户名                   给这个账户设登录密码（没有密码的账户不能用密码登录）
  -EnableAdmin                          启用内置 Administrator 账户（Windows 默认是禁用的）
  -AllowPassword                        sshd 配置把密码登录关掉了的话，重新打开
  -Shell cmd | keep | powershell        远程登录后的命令行：恢复 cmd / 不改动 / 强制设为 PowerShell

Claude 命令行相关：
  -NoClaude                             不安装 Claude 命令行
  -ClaudeOnly                           只安装 Claude 命令行，不动 SSH（不需要管理员权限）
  -UpdateClaude                         已经装了的话，升级到最新版
"@
    Exit-Script 0
}

if ($Status) {
    $bad = 1
    try { $bad = Show-Status } catch { Write-Host "查看状态时出错：$($_.Exception.Message)" -ForegroundColor Red }
    if ($bad -gt 0) { Exit-Script 1 }
    Exit-Script 0
}

# 除了「演练」和「只装 Claude」，其余都要管理员权限：只弹一次 UAC。
if (-not $DryRun -and -not $ClaudeOnly -and -not (Test-Admin)) {
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

# 要远程登录的是「当前登录 Windows 的那个用户」。如果 UAC 用的是另一个管理员账户，用 OrigUser 还原。
$loginUser = $env:USERNAME
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) { $loginUser = $OrigUser }
$keyUser = $loginUser
if ($ForUser) { $keyUser = $ForUser }

if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }

try {
    if ($Off) {
        Invoke-Off
    } elseif ($ClaudeOnly) {
        $script:TotalSteps = 1
        Invoke-Claude $loginUser
    } else {
        $script:TotalSteps = 7
        if ($NoClaude) { $script:TotalSteps = 6 }
        if (Invoke-Install) {
            Invoke-Service
            $port = Get-SshPort
            Invoke-Firewall $port
            Invoke-LoginSetup $keyUser
            Invoke-LoginCheck $loginUser
            if (-not $NoClaude) { Invoke-Claude $loginUser }
            Invoke-Check $loginUser $port
        } elseif (-not $NoClaude) {
            # SSH 没装上也不耽误装 Claude。
            $script:TotalSteps = 2
            Invoke-Claude $loginUser
        }
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
}

Show-Result
if ($script:BadCount -gt 0) { Exit-Script 1 }
Exit-Script 0
