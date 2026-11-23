# 小川 SSH 登录修复助手 · Windows 版
# 用途：SSH 能连上但登录被拒（Connection closed / Permission denied）时，在「被连的那台电脑」上双击跑一次，
#       它会查出登录失败的原因并修好，最后打印能直接用的连接命令。
# 一次做这些事：
#   1. 确保 OpenSSH 服务端装好、sshd 在跑并开机自启、防火墙放行了 SSH 端口。
#   2. 列出本机账户，指出哪个账户能用来远程登录（启用、有密码的才行），并说明为什么 Administrator 常常连不上。
#   3. 检查 sshd 配置（sshd_config）里有没有禁用密码登录、或 AllowUsers/DenyUsers 之类的限制。
#   4. 按需要修复：给账户设密码（-SetPassword）、启用内置 Administrator（-EnableAdmin）、
#      写入公钥免密登录（-PubKey）、强制打开密码登录（-AllowPassword）。
#   5. 把远程登录后的命令行设为 PowerShell（用 Termius 等工具登录进来直接是 PowerShell；-Shell cmd 可以改回去）。
#   6. 打印从别的电脑连接要用的 ssh 命令。
# 直接双击 fix-ssh-login.bat 即可，Windows 会弹一次 UAC，点「是」。不加参数时只诊断 + 做安全的修复（含把命令行设为 PowerShell），不会动密码。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [string]$SetPassword = '',   # 给这个账户设登录密码（会提示输入两遍）；密码登录必须有密码
    [switch]$EnableAdmin,        # 启用并解锁内置 Administrator 账户（默认 Windows 把它禁用了）
    [string]$PubKey = '',        # 写入公钥免密登录：公钥内容，或 .pub 文件路径
    [string]$ForUser = '',       # 公钥 / 设密码针对哪个账户；默认是当前登录的账户
    [switch]$AllowPassword,      # 强制在 sshd_config 里打开密码登录并重启 sshd
    [ValidateSet('', 'powershell', 'cmd', 'keep')]
    [string]$Shell = '',         # 远程登录后的命令行；不传 = 设为 PowerShell（已手动设成别的 shell 就保持不动）
    [switch]$Status,             # 只诊断，不做任何修改
    [switch]$DryRun,             # 演练：只显示将要做的事
    [switch]$Help,
    # 下面几个是脚本自己用的，不用手动传。
    [switch]$FromBat,
    [switch]$Elevated,
    [string]$OrigUser = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.1.0'
$SshData = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshData 'sshd_config'
$AdminKeys = Join-Path $SshData 'administrators_authorized_keys'
$PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$FwRule = 'Xiaochuan-SSH-In-TCP'

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

function Get-SshPort {
    try {
        foreach ($line in [IO.File]::ReadAllLines($SshdConfig)) {
            if ($line -match '^\s*Port\s+(\d+)') { return [int]$Matches[1] }
        }
    } catch { }
    return 22
}

function Test-SshPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream(); $stream.ReadTimeout = 3000
        $buf = New-Object byte[] 64
        $n = $stream.Read($buf, 0, $buf.Length)
        return ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -like 'SSH-*')
    } catch { return $false } finally { $client.Close() }
}

# ================================================================ 账户信息

# 本机的「管理员组成员」名字集合（账户名，不含机器名前缀）。
function Get-AdminMembers {
    $names = @()
    try {
        # 本地化安全起见用 SID S-1-5-32-544 取管理员组。
        $grp = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
        $gname = $grp.Split('\')[-1]
        foreach ($m in (Get-LocalGroupMember -Name $gname -ErrorAction Stop)) {
            $names += $m.Name.Split('\')[-1]
        }
    } catch {
        try { foreach ($line in (& net.exe localgroup Administrators)) { } } catch { }
    }
    return $names
}

# 返回一个账户的诊断对象。$null 表示本机没有这个本地账户（可能是微软账户/域账户）。
function Get-AccountInfo([string]$Name) {
    try {
        $u = Get-LocalUser -Name $Name -ErrorAction Stop
    } catch { return $null }
    # 判断「有没有密码」：Windows 没有直接接口。用两个线索——
    #   PasswordRequired=$false 常意味着允许空密码（sshd 默认拒绝空密码登录）；
    #   PasswordLastSet 为空且从未设过，多半没有密码。
    $hasPwd = $true
    if (-not $u.PasswordRequired -and -not $u.PasswordLastSet) { $hasPwd = $false }
    return [pscustomobject]@{
        Name = $u.Name
        Enabled = $u.Enabled
        LikelyHasPassword = $hasPwd
        PasswordLastSet = $u.PasswordLastSet
        IsAdmin = ((Get-AdminMembers) -contains $u.Name)
    }
}

# ================================================================ 第 1 步：服务端

function Invoke-EnsureServer([int]$Port) {
    Write-Step 'SSH 服务端：安装 / 启动 / 开机自启 / 防火墙'
    $svc = Get-Sshd
    if (-not $svc) {
        if ($DryRun -or $Status) { Write-Note '没有装 OpenSSH 服务端（演练/诊断模式不安装）。'; return }
        Write-Log '没装 OpenSSH 服务端，正在安装 Windows 自带的（1～5 分钟）…'
        try { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null } catch { Write-Fail "OpenSSH 服务端没装上：$($_.Exception.Message)（可到 设置>系统>可选功能 里手动装 OpenSSH 服务器）"; return }
        $svc = Get-Sshd
    } else { Write-Log 'OpenSSH 服务端已安装。' }
    if (-not $svc) { Write-Fail 'OpenSSH 服务端没装上。'; return }

    if ($Status) {
        if ($svc.Status -eq 'Running') { Write-Log 'sshd 正在运行。' } else { Write-Note "sshd 没有运行（$($svc.Status)）。" }
    } elseif (-not $DryRun) {
        try {
            Set-Service -Name 'sshd' -StartupType Automatic
            if ((Get-Sshd).Status -ne 'Running') { Start-Service -Name 'sshd' }
            (Get-Sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
            Write-Log 'sshd 已启动并设为开机自启。'
        } catch { Write-Fail "sshd 没启动成功：$($_.Exception.Message)" }
    } else { Write-Log '演练：将会把 sshd 设为自启并启动。' }

    # 防火墙：没有可用的放行规则就补一条，覆盖所有网络类型。
    if (-not ($DryRun -or $Status)) {
        try {
            if (Get-NetFirewallRule -Name $FwRule -ErrorAction SilentlyContinue) {
                Set-NetFirewallRule -Name $FwRule -Enabled True -Profile Any -Action Allow -Direction Inbound
                Get-NetFirewallRule -Name $FwRule | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port
            } else {
                New-NetFirewallRule -Name $FwRule -DisplayName "Xiaochuan SSH (TCP $Port)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -Enabled True | Out-Null
            }
            Write-Log "防火墙已放行 TCP $Port。"
        } catch { Write-Note "防火墙规则没建成：$($_.Exception.Message)" }
    }

    if (Test-SshPort $Port) { Add-Ok "SSH 服务端正常，端口 $Port 有应答" }
    elseif (-not ($DryRun -or $Status)) { Write-Fail "SSH 端口 $Port 没有应答，sshd 可能没正常工作（看 事件查看器>应用程序和服务日志>OpenSSH）" }
}

# ================================================================ 第 2 步：账户诊断

function Invoke-DiagnoseAccounts([string]$LoginUser) {
    Write-Step '账户：查出该用哪个账户远程登录'

    # 本机所有启用的本地账户。
    $all = @()
    try { $all = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled }) } catch { }
    $admins = Get-AdminMembers

    Write-Host '  本机启用的账户：'
    foreach ($u in $all) {
        $info = Get-AccountInfo $u.Name
        $tags = @()
        if ($info.IsAdmin) { $tags += '管理员' }
        if (-not $info.LikelyHasPassword) { $tags += '疑似无密码(不能用密码登录)' }
        $tagStr = if ($tags.Count) { ' [' + ($tags -join '，') + ']' } else { '' }
        Write-Host ("    - {0}{1}" -f $u.Name, $tagStr)
    }

    # 当前登录账户的情况。
    $me = Get-AccountInfo $LoginUser
    Write-Host ''
    if ($me) {
        Write-Host "  当前登录账户：$LoginUser（$(if($me.IsAdmin){'管理员'}else{'普通用户'})）"
        if (-not $me.LikelyHasPassword) {
            Write-Note "$LoginUser 疑似没有设登录密码，用密码登录会被拒。加参数 -SetPassword $LoginUser 设一个，或用 -PubKey 写公钥免密登录。"
        } else {
            Add-Ok "推荐用账户 $LoginUser 远程登录（用它的 Windows 登录密码）"
        }
    } else {
        Write-Note "$LoginUser 不是本机本地账户（可能是微软账户或域账户）。用微软账户登录的，SSH 密码就是微软账户的密码（不是 PIN）。"
        Add-Info "推荐用账户 $LoginUser 远程登录（微软账户用微软账户密码，不是 PIN）"
    }

    # 专门解释 Administrator 的坑。
    $adminInfo = Get-AccountInfo 'Administrator'
    if ($adminInfo) {
        if (-not $adminInfo.Enabled) {
            Write-Note '内置 Administrator 账户被禁用（Windows 默认如此），所以用 Administrator 登录会直接被拒。这就是你连不上的最可能原因——请改用上面列出的账户名；一定要用 Administrator 的话加参数 -EnableAdmin。'
        } elseif (-not $adminInfo.LikelyHasPassword) {
            Write-Note '内置 Administrator 已启用但疑似没有密码，不能用密码登录。加参数 -SetPassword Administrator 给它设一个。'
        }
    }
}

# ================================================================ 第 3 步：sshd 配置

function Invoke-CheckConfig {
    Write-Step 'SSH 配置：检查有没有挡住登录'
    if (-not (Test-Path -LiteralPath $SshdConfig)) { Write-Note "没找到 $SshdConfig，跳过。"; return }
    $pwAuth = $true; $pubAuth = $true
    $limits = @()
    $inMatch = $false
    foreach ($raw in [IO.File]::ReadAllLines($SshdConfig)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^Match\s') { $inMatch = $true; continue }   # 只看全局（Match 之前）的设置
        if ($inMatch) { continue }
        if ($line -match '^PasswordAuthentication\s+(\S+)') { $pwAuth = ($Matches[1] -eq 'yes') }
        elseif ($line -match '^PubkeyAuthentication\s+(\S+)') { $pubAuth = ($Matches[1] -eq 'yes') }
        elseif ($line -match '^(AllowUsers|AllowGroups|DenyUsers|DenyGroups)\s+(.+)') { $limits += "$($Matches[1]) $($Matches[2])" }
    }
    if ($pwAuth) { Write-Log '密码登录：已开启。' } else { Write-Note '密码登录：已被关闭（PasswordAuthentication no）。想用密码登录，加参数 -AllowPassword，或用 -PubKey 走公钥。' }
    if ($pubAuth) { Write-Log '公钥登录：已开启。' } else { Write-Note '公钥登录：已被关闭（PubkeyAuthentication no）。' }
    if ($limits.Count) {
        foreach ($l in $limits) { Write-Note "配置里有登录名单限制：$l（不在允许名单/在拒绝名单里的账户连不上）" }
    } else { Write-Log '没有 AllowUsers/DenyUsers 这类名单限制。' }
    if ($pwAuth -and -not $limits.Count) { Add-Ok 'sshd 配置没有挡住密码登录' }
}

# ================================================================ 第 4 步：远程登录后的命令行

function Get-DefaultShell {
    try { return "$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop).DefaultShell)" } catch { return '' }
}

# 不传 -Shell 时设为 PowerShell；已经手动设成别的 shell（比如 pwsh、bash）就不覆盖。
function Invoke-DefaultShell {
    Write-Step '远程登录后的命令行（默认 PowerShell）'
    $cur = Get-DefaultShell
    $curText = if ($cur) { $cur } else { 'cmd（Windows 默认）' }
    $want = $Shell
    if (-not $want) {
        if ($cur -and $cur -ne $PsExe) { $want = 'keep' } else { $want = 'powershell' }
    }
    if ($Status -or $want -eq 'keep') { Write-Log "现在是 $curText，不改动。"; return }
    if ($want -eq 'powershell') {
        if ($cur -eq $PsExe) { Write-Log '已经是 PowerShell，不用改。'; Add-Ok '远程登录后的命令行是 PowerShell（之前就设了）'; return }
        if ($DryRun) { Write-Log '演练：将会把远程登录后的命令行设为 PowerShell。'; return }
        try {
            if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
            New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $PsExe -PropertyType String -Force | Out-Null
            Add-Ok '远程登录后的命令行已设为 PowerShell（已经连着的窗口要断开重新登录才生效）'
        } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
    } else {
        if (-not $cur) { Write-Log '已经是 cmd，不用改。'; Add-Ok '远程登录后的命令行是 cmd（Windows 默认）'; return }
        if ($DryRun) { Write-Log '演练：将会把远程登录后的命令行恢复为 cmd。'; return }
        try {
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop
            Add-Ok '远程登录后的命令行已恢复为 cmd（Windows 默认）'
        } catch { Write-Fail "默认命令行没有改成：$($_.Exception.Message)" }
    }
}

# ================================================================ 修复动作

function Invoke-SetPassword([string]$User) {
    Write-Step "给账户「$User」设登录密码"
    if ($DryRun) { Write-Log "演练：将会提示为 $User 设置登录密码。"; return }
    Write-Host "  现在为账户「$User」设置一个登录密码（输入时不显示是正常的）。" -ForegroundColor Cyan
    $p1 = Read-Host '  输入新密码' -AsSecureString
    $p2 = Read-Host '  再输一遍' -AsSecureString
    $s1 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
    $s2 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
    if (-not $s1) { Write-Fail '密码为空，没有设置。'; return }
    if ($s1 -ne $s2) { Write-Fail '两次输入不一致，没有设置。'; return }
    try {
        Set-LocalUser -Name $User -Password $p1 -ErrorAction Stop
        # 确保账户不被「下次登录须改密码/密码永不过期」之类卡住。
        try { & net.exe user $User /logonpasswordchg:no | Out-Null } catch { }
        Add-Ok "账户 $User 的登录密码已设置，现在可以用密码远程登录"
    } catch { Write-Fail "设置密码失败：$($_.Exception.Message)" }
}

function Invoke-EnableAdmin {
    Write-Step '启用内置 Administrator 账户'
    if ($DryRun) { Write-Log '演练：将会启用并解锁内置 Administrator 账户。'; return }
    try {
        Enable-LocalUser -Name 'Administrator' -ErrorAction Stop
        try { & net.exe user Administrator /active:yes | Out-Null } catch { }
        $info = Get-AccountInfo 'Administrator'
        if ($info -and -not $info.LikelyHasPassword) {
            Write-Note 'Administrator 已启用，但还没有密码，仍不能用密码登录。请再加 -SetPassword Administrator 给它设密码。'
        }
        Add-Ok '内置 Administrator 账户已启用'
    } catch { Write-Fail "启用 Administrator 失败：$($_.Exception.Message)" }
}

function Read-PubKeys([string]$Value) {
    $lines = @($Value)
    if (Test-Path -LiteralPath $Value -PathType Leaf) { $lines = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Value).Path) }
    $keys = @()
    foreach ($l in $lines) {
        $l = "$l".Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-\S+|sk-\S+)\s+[A-Za-z0-9+/]+=*(\s.*)?$') { $keys += $l }
        elseif ($l -match 'PRIVATE KEY') { throw '给的是私钥。要用的是 .pub 结尾的公钥。' }
        else { throw "这不是合法的公钥：$l" }
    }
    if ($keys.Count -eq 0) { throw '没有读到公钥。' }
    return $keys
}

function Get-UserProfileDir([string]$User) {
    if ($User -eq $env:USERNAME) { return $env:USERPROFILE }
    try {
        $sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
        $dir = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if ($dir) { return [Environment]::ExpandEnvironmentVariables($dir) }
    } catch { }
    return (Join-Path (Split-Path $env:USERPROFILE -Parent) $User)
}

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

function Invoke-AddPubKey([string]$User) {
    Write-Step "写入公钥，让账户「$User」免密登录"
    try { $keys = @(Read-PubKeys $PubKey) } catch { Write-Fail "公钥没写入：$($_.Exception.Message)"; return }
    $isAdmin = ((Get-AdminMembers) -contains $User)
    $userFile = Join-Path (Get-UserProfileDir $User) '.ssh\authorized_keys'
    if ($DryRun) { Write-Log "演练：将把 $($keys.Count) 个公钥写入 $userFile$(if($isAdmin){'，并写入 '+$AdminKeys}else{''})"; return }
    try {
        Add-KeysToFile $userFile $keys | Out-Null
        if ($isAdmin) {
            Add-KeysToFile $AdminKeys $keys | Out-Null
            & icacls.exe $AdminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        }
        Add-Ok "公钥已写入，账户 $User 可以免密登录"
    } catch { Write-Fail "公钥没写入：$($_.Exception.Message)" }
}

function Invoke-AllowPassword {
    Write-Step '在 sshd 配置里打开密码登录'
    if (-not (Test-Path -LiteralPath $SshdConfig)) { Write-Fail "没找到 $SshdConfig。"; return }
    if ($DryRun) { Write-Log '演练：将把 PasswordAuthentication 设为 yes 并重启 sshd。'; return }
    try {
        $lines = [IO.File]::ReadAllLines($SshdConfig)
        $out = New-Object System.Collections.ArrayList
        $done = $false; $inMatch = $false
        foreach ($raw in $lines) {
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

# ================================================================ 连接方式

function Get-LocalIPv4 {
    $list = @()
    try {
        foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred' })) {
            $label = $a.InterfaceAlias
            $p = $a.IPAddress.Split('.')
            if ([int]$p[0] -eq 100 -and [int]$p[1] -ge 64 -and [int]$p[1] -le 127) { $label = "$label，Tailscale 等组网地址，不在同一局域网也能连" }
            $list += [pscustomobject]@{ IP = $a.IPAddress; Label = $label }
        }
    } catch { }
    return $list
}

function Show-Connect([string]$User, [int]$Port) {
    $portArg = if ($Port -ne 22) { " -p $Port" } else { '' }
    $u = if ($User -match '\s') { "`"$User`"" } else { $User }
    Write-Host ''
    Write-Host '---------------- 从别的电脑连接 ----------------' -ForegroundColor Cyan
    $ips = @(Get-LocalIPv4)
    if ($ips.Count -eq 0) { Write-Host "  连接命令格式：ssh$portArg $u@本机IP" }
    else { foreach ($i in $ips) { Write-Host ("  ssh{0} {1}@{2}" -f $portArg, $u, $i.IP) -ForegroundColor Green -NoNewline; Write-Host "    （$($i.Label)）" } }
    Write-Host "  远程执行一条命令：命令写在后面，如  ssh$portArg $u@IP hostname"
    Write-Host "  推荐账户：$User    密码：这个账户的 Windows 登录密码（微软账户用微软账户密码，不是 PIN）"
    Write-Host '  公网 IP 直接开 22 端口会被人扫描撞库，建议只留公钥登录或走 Tailscale。'
    Write-Host '------------------------------------------------' -ForegroundColor Cyan
}

# ================================================================ 主流程

if ($Help) {
    Write-Host @"
小川 SSH 登录修复助手 $Version（Windows）

SSH 能连上但登录被拒（Connection closed / Permission denied）时，在被连的那台电脑上跑一次，
查出原因并修好，最后打印能用的连接命令。

用法：
  双击 fix-ssh-login.bat                 诊断 + 安全修复（确保服务/防火墙，查出该用哪个账户，
                                         远程登录后的命令行设为 PowerShell）；不动密码
  fix-ssh-login.bat -Status              只诊断，不做任何修改
  fix-ssh-login.bat -SetPassword 账户名  给这个账户设登录密码（密码登录必须有密码）
  fix-ssh-login.bat -EnableAdmin         启用内置 Administrator 账户（默认被禁用）
  fix-ssh-login.bat -AllowPassword       强制在 sshd 配置里打开密码登录
  fix-ssh-login.bat -Shell cmd           远程登录后的命令行恢复为 cmd（-Shell keep 是不改动）
  fix-ssh-login.bat -PubKey "ssh-ed25519 AAAA..." [-ForUser 账户名]
                                         写入公钥免密登录（也可给 .pub 文件路径）
  fix-ssh-login.bat -DryRun              演练：只显示将要做的事
"@
    Exit-Script 0
}

# 除了演练，其余都要管理员权限：只弹一次 UAC。
if (-not $DryRun -and -not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    $argList += '-Elevated'; $argList += '-OrigUser'; $argList += "`"$env:USERNAME`""
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null; exit 0 }
    catch { Write-Fail '没有拿到管理员权限（UAC 被取消）。请重新运行并在弹窗里点「是」。'; Show-Result; Exit-Script 1 }
}

# 要远程登录的账户：当前登录 Windows 的那个用户。UAC 用了别的管理员账户时，用 OrigUser 还原。
$loginUser = $env:USERNAME
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) { $loginUser = $OrigUser }
$targetUser = if ($ForUser) { $ForUser } else { $loginUser }
$port = Get-SshPort

if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }

# 算总步数：固定 4 步（服务/账户/配置/命令行），加上要做的修复动作。
$script:TotalSteps = 4
if (-not $Status) {
    if ($SetPassword) { $script:TotalSteps++ }
    if ($EnableAdmin) { $script:TotalSteps++ }
    if ($AllowPassword) { $script:TotalSteps++ }
    if ($PubKey) { $script:TotalSteps++ }
}

try {
    Invoke-EnsureServer $port
    Invoke-DiagnoseAccounts $loginUser
    Invoke-CheckConfig
    Invoke-DefaultShell
    if (-not $Status) {
        if ($EnableAdmin) { Invoke-EnableAdmin }
        if ($SetPassword) { Invoke-SetPassword $SetPassword }
        if ($AllowPassword) { Invoke-AllowPassword }
        if ($PubKey) { Invoke-AddPubKey $targetUser }
    }
    Show-Connect $targetUser $port
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
}

Show-Result
if ($script:BadCount -gt 0) { Exit-Script 1 }
Exit-Script 0
