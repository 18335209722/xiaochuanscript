# 小川环境助手 · Windows 脚本版
# 功能和 XiaochuanEnv.exe / macOS、Linux 版 xiaochuan-env.sh 对齐：
#   清理 Claude Code 缓存 / 会话历史、清理 Chrome 缓存并设为 en-US、
#   时区改为太平洋时间（America/Los_Angeles）、系统语言改为 en-US、安装 / 卸载 Claude。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [ValidateSet('', 'status', 'install-code', 'uninstall-code', 'install-desktop', 'uninstall-desktop')]
    [string]$Action = '',
    [switch]$Cache,
    [switch]$History,
    [switch]$Chrome,
    [switch]$Timezone,
    [switch]$Language,
    [switch]$All,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Yes,
    [switch]$RemoveData,
    [switch]$Help,
    # 以下两个是脚本自己提权重启时用的，不需要手动传。
    [switch]$Elevated,
    [string]$OrigUser = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.1.0'
$TargetTz = 'Pacific Standard Time'          # 即 America/Los_Angeles
$TargetTzName = 'America/Los_Angeles'

$DataDir = Join-Path $env:USERPROFILE '.xiaochuan-env'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$ClaudeJson = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' }
$ChromeData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$TzAutoKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'

$script:Errors = 0
$script:FreedBytes = [int64]0
$script:Removed = 0
$script:BackupDir = ''
$script:DoCache = $false
$script:DoHistory = $false
$script:DoChrome = $false
$script:DoTz = $false
$script:DoLang = $false
$script:RemoveUserData = [bool]$RemoveData

# ~.claude 下要清理的项目；执行后检查也用这两份清单。
$script:ClaudeCacheItems = 'cache', 'debug', 'paste-cache', 'image-cache', 'usage-data', 'feedback-bundles',
    'feedbackdrafts', 'shell-snapshots', 'session-env', 'plans', 'todos', 'statsig', 'logs',
    'sessions', 'seed-admin', 'downloads', 'skills.trash', 'plugins.trash',
    'remote-settings.json', 'policy-limits.json', 'policy-limits.json.stamp.json', 'stats-cache.json'
$script:ClaudeHistoryItems = 'projects', 'file-history', 'backups', 'tasks', 'history', 'history.jsonl'

function Write-Log([string]$Message) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Write-Note([string]$Message) { Write-Host ("[{0}] 注意：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow }
function Write-Fail([string]$Message) {
    Write-Host ("[{0}] 失败：{1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red
    $script:Errors++
}

function Confirm-Step([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
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

# 依次尝试多种方式做同一件事：每试一种就用 $Check 核对，成功即停；全部试完还不行才算失败。
function Invoke-Methods([string]$Name, [scriptblock]$Check, [scriptblock[]]$Methods) {
    $tried = 0
    $errs = @()
    foreach ($m in $Methods) {
        $ok = $false
        try { $ok = [bool](& $Check) } catch { }
        if ($ok) { return $true }
        $tried++
        try { & $m | Out-Null } catch { $errs += $_.Exception.Message }
    }
    $ok = $false
    try { $ok = [bool](& $Check) } catch { }
    if ($ok) { return $true }
    Write-Fail "$Name 失败：试了 $tried 种方式都没成功。$($errs -join '；')"
    return $false
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-PathSize([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

# 只删除 $Root 之内的路径，防止变量为空或路径越界时误删。
function Remove-Safe([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        Write-Fail "拒绝删除（路径为空）：$Path"; return
    }
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($rootFull.Length -le 3 -or -not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail "拒绝删除（路径越界）：$Path"; return
    }
    if (-not (Test-Path -LiteralPath $full)) { return }
    $size = Get-PathSize $full
    if ($DryRun) {
        Write-Log "（演练）删除 $full（$(Format-Size $size)）"
    } else {
        # 普通方式删不掉时，依次去掉只读属性、用 rd/del 强删、夺取所有权后再删；每次都核对是否真的没了。
        $isDir = Test-Path -LiteralPath $full -PathType Container
        $gone = Invoke-Methods "删除 $full" { -not (Test-Path -LiteralPath $full) } @(
            { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop },
            {
                Invoke-Native { attrib.exe -R -S -H $full /S /D } | Out-Null
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
            },
            {
                if ($isDir) { Invoke-Native { cmd.exe /c rd /s /q "$full" } | Out-Null }
                else { Invoke-Native { cmd.exe /c del /f /q "$full" } | Out-Null }
            },
            {
                if ($isDir) { Invoke-Native { takeown.exe /F $full /R /A /D Y } | Out-Null }
                else { Invoke-Native { takeown.exe /F $full /A } | Out-Null }
                Invoke-Native { icacls.exe $full /grant '*S-1-5-32-544:F' /T /C /Q } | Out-Null
                if ($isDir) { Invoke-Native { cmd.exe /c rd /s /q "$full" } | Out-Null }
                else { Invoke-Native { cmd.exe /c del /f /q "$full" } | Out-Null }
            }
        )
        if (-not $gone) { return }
    }
    $script:FreedBytes += $size
    $script:Removed++
}

function Backup-File([string]$Source, [string]$Relative) {
    if ($DryRun -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $dest = Join-Path $script:BackupDir $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $dest -Force
}

function Test-ClaudeRunning {
    return [bool](Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
}

function Test-ChromeRunning {
    return [bool](Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)
}

# 关闭 Chrome：先正常关闭（等同于点窗口的 X，标签页下次可以恢复），
# 关不掉（后台进程、托盘常驻、卡在弹窗）再强制结束。
function Stop-Chrome {
    Invoke-Native { taskkill.exe /IM chrome.exe } | Out-Null
    for ($i = 0; $i -lt 10 -and (Test-ChromeRunning); $i++) { Start-Sleep -Seconds 1 }
    if (Test-ChromeRunning) {
        Get-Process -Name 'chrome' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 10 -and (Test-ChromeRunning); $i++) { Start-Sleep -Seconds 1 }
    }
    return (-not (Test-ChromeRunning))
}

# ---------------------------------------------------------------- Claude Code

function Clear-Claude {
    if (-not $script:DoCache -and -not $script:DoHistory) { return }
    if (-not $Force -and (Test-ClaudeRunning)) {
        Write-Fail 'Claude Code 正在运行。请先关闭所有 Claude Code 会话和终端（或加 -Force）。'
        return
    }
    $beforeBytes = $script:FreedBytes; $beforeCount = $script:Removed

    if ($script:DoCache) {
        Write-Log '正在清理 Claude Code 缓存、日志和临时文件…'
        foreach ($item in $script:ClaudeCacheItems) { Remove-Safe (Join-Path $ClaudeDir $item) $ClaudeDir }

        # MCP 日志缓存
        Remove-Safe (Join-Path $env:LOCALAPPDATA 'claude-cli-nodejs') $env:LOCALAPPDATA
        # 临时草稿和粘贴图片
        Remove-Safe (Join-Path $env:TEMP 'claude') $env:TEMP
        # npx 缓存里装的 @anthropic-ai/claude-code
        $npx = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
        if (Test-Path -LiteralPath $npx) {
            foreach ($d in (Get-ChildItem -LiteralPath $npx -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $d.FullName 'node_modules\@anthropic-ai\claude-code')) {
                    Remove-Safe $d.FullName $npx
                }
            }
        }
    }

    if ($script:DoHistory) {
        Write-Log '正在清理 Claude Code 会话历史（删除后无法恢复旧会话）…'
        foreach ($item in $script:ClaudeHistoryItems) {
            Remove-Safe (Join-Path $ClaudeDir $item) $ClaudeDir
        }
    }
    Write-Log ("Claude Code：已清理 {0} 项，释放 {1}。" -f ($script:Removed - $beforeCount), (Format-Size ($script:FreedBytes - $beforeBytes)))
}

# --------------------------------------------------------------------- Chrome

function New-JsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 1000
    return $ser
}

# 用 JavaScriptSerializer 而不是 ConvertFrom-Json：后者遇到只差大小写的键或空键会报错。
function Set-ChromeJsonCore([string]$File, [string]$Mode) {
    $ser = New-JsonSerializer
    $data = $ser.DeserializeObject([IO.File]::ReadAllText($File, [Text.Encoding]::UTF8))
    if (-not ($data -is [System.Collections.IDictionary])) { throw '文件内容不是 JSON 对象' }
    if (-not $data.ContainsKey('intl') -or -not ($data['intl'] -is [System.Collections.IDictionary])) {
        $data['intl'] = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    }
    if ($Mode -eq 'local') {
        $data['intl']['app_locale'] = 'en-US'
    } else {
        $data['intl']['accept_languages'] = 'en-US,en'
        $data['intl']['selected_languages'] = 'en-US,en'
    }
    $tmp = "$File.xc-tmp"
    [IO.File]::WriteAllText($tmp, $ser.Serialize($data), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $File -Force
}

# 读回文件核对语言是否已经是目标值。
function Test-ChromeJson([string]$File, [string]$Mode) {
    try { $text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) } catch { return $false }
    if ($Mode -eq 'local') { return ($text -match '"app_locale"\s*:\s*"en-US"') }
    return ($text -match '"accept_languages"\s*:\s*"en-US,en"')
}

# 改 Chrome 配置文件的语言：直接改不行就去掉只读属性再改，再不行就夺取所有权后再改；每次都读回核对。
function Set-ChromeJson([string]$File, [string]$Mode, [string]$Label) {
    return (Invoke-Methods "$Label 的语言改为 en-US" { Test-ChromeJson $File $Mode } @(
        { Set-ChromeJsonCore $File $Mode },
        {
            Invoke-Native { attrib.exe -R -S -H $File } | Out-Null
            Set-ChromeJsonCore $File $Mode
        },
        {
            Invoke-Native { takeown.exe /F $File /A } | Out-Null
            Invoke-Native { icacls.exe $File /grant '*S-1-5-32-544:F' /C /Q } | Out-Null
            Invoke-Native { icacls.exe $File /grant "${env:USERNAME}:F" /C /Q } | Out-Null
            Set-ChromeJsonCore $File $Mode
        }
    ))
}

function Get-ChromeLang {
    $file = Join-Path $ChromeData 'Local State'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $data = (New-JsonSerializer).DeserializeObject([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
        if ($data.ContainsKey('intl') -and $data['intl'].ContainsKey('app_locale')) { return [string]$data['intl']['app_locale'] }
    } catch { }
    return ''
}

function Clear-Chrome {
    if (-not $script:DoChrome) { return }
    if (-not (Test-Path -LiteralPath $ChromeData)) {
        Write-Note '未检测到 Google Chrome 用户数据，已跳过。'; return
    }
    if (Test-ChromeRunning) {
        if ($DryRun) {
            Write-Note 'Chrome 正在运行；正式执行时会先把 Chrome 关闭。'
        } else {
            Write-Log 'Chrome 正在运行，先把它关闭…'
            if (Stop-Chrome) {
                Write-Log 'Chrome 已关闭。'
            } else {
                Write-Fail 'Chrome 关不掉，已跳过缓存和语言修改；请手动完全退出 Chrome（包括右下角托盘图标）后重试。'
                return
            }
        }
    }

    $beforeBytes = $script:FreedBytes; $beforeCount = $script:Removed
    $langOk = $true
    Write-Log '正在清理 Chrome 缓存并设置 en-US…'

    foreach ($sub in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') {
        Remove-Safe (Join-Path $ChromeData $sub) $ChromeData
    }
    $profiles = @(Get-ChildItem -LiteralPath $ChromeData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    if ($profiles.Count -eq 0) { Write-Note 'Chrome 用户目录中没有找到 Profile。' }

    foreach ($p in $profiles) {
        foreach ($sub in 'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
            'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'Media Cache') {
            Remove-Safe (Join-Path $p.FullName $sub) $ChromeData
        }
        $prefs = Join-Path $p.FullName 'Preferences'
        if (Test-Path -LiteralPath $prefs) {
            Backup-File $prefs "chrome-files\$($p.Name)\Preferences"
            if ($DryRun) {
                Write-Log "（演练）$($p.Name)\Preferences 的 Accept-Language 设为 en-US,en"
            } else {
                if (-not (Set-ChromeJson $prefs 'prefs' "$($p.Name)\Preferences")) { $langOk = $false }
            }
        }
    }

    $localState = Join-Path $ChromeData 'Local State'
    if (Test-Path -LiteralPath $localState) {
        Backup-File $localState 'chrome-files\Local State'
        if ($DryRun) {
            Write-Log '（演练）Local State 的界面语言设为 en-US'
        } else {
            if (-not (Set-ChromeJson $localState 'local' 'Local State')) { $langOk = $false }
        }
    }

    $tail = if ($langOk) { '语言已设为 en-US。' } else { '语言未完全修改。' }
    Write-Log ("Chrome：清理 {0} 个缓存目录，释放 {1}；{2}" -f ($script:Removed - $beforeCount), (Format-Size ($script:FreedBytes - $beforeBytes)), $tail)
    $bk = Join-Path $script:BackupDir 'chrome-files'
    if (-not $DryRun -and (Test-Path -LiteralPath $bk)) { Write-Log "Chrome 备份：$bk" }
}

# ------------------------------------------------------------ 时区 / 语言

# Windows「自动设置时区」：服务 tzautoupdate 的 Start 为 3 表示开，4 表示关。
function Test-AutoTz {
    try { return ((Get-ItemProperty -Path $TzAutoKey -Name Start -ErrorAction Stop).Start -ne 4) } catch { return $false }
}

function Test-TzOk { return ((Get-CurrentTz) -eq $TargetTz -and -not (Test-AutoTz)) }

function Get-CurrentLang {
    try { return [string](Get-WinUserLanguageList)[0].LanguageTag } catch { return '' }
}

function Save-Snapshot {
    if ($DryRun) { return }
    New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    $lines = @(
        "time=$(Get-Date)"
        "timezone=$((Get-TimeZone).Id)"
        "auto_timezone=$(Test-AutoTz)"
        "user_languages=$((Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ',')"
        "input_methods=$((Get-WinUserLanguageList | ForEach-Object { $_.InputMethodTips }) -join ',')"
        "ui_override=$(Get-WinUILanguageOverride)"
        "culture=$((Get-Culture).Name)"
        "system_locale=$((Get-WinSystemLocale).Name)"
        "home_location=$((Get-WinHomeLocation).GeoId)"
    )
    $file = Join-Path $script:BackupDir 'settings-snapshot.txt'
    $lines | Out-File -FilePath $file -Encoding utf8
    Write-Log "设置备份：$file"
}

function Get-CurrentTz { return (Invoke-Native { tzutil.exe /g }) }

function Set-TargetTimezone {
    if (-not $script:DoTz) { return }
    Write-Log "当前时区 $(Get-CurrentTz)，准备设置…"
    if ($DryRun) {
        Write-Log "（演练）依次尝试各种方式关闭「自动设置时区」并把时区改为 $TargetTzName，直到核对成功。"
        return
    }
    # 先关掉「自动设置时区」，否则会被定位改回去。
    $autoOff = Invoke-Methods '关闭「自动设置时区」' { -not (Test-AutoTz) } @(
        { Set-ItemProperty -Path $TzAutoKey -Name Start -Value 4 -ErrorAction Stop },
        { Invoke-Native { sc.exe config tzautoupdate start= disabled } },
        { Invoke-Native { reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate' /v Start /t REG_DWORD /d 4 /f } }
    )
    Stop-Service -Name tzautoupdate -Force -ErrorAction SilentlyContinue

    # 命令的返回值不可靠，每试一种方式都读回当前时区核对。
    $tzSet = Invoke-Methods "时区改为 $TargetTzName" { (Get-CurrentTz) -eq $TargetTz } @(
        { Invoke-Native { tzutil.exe /s $TargetTz } },
        { Set-TimeZone -Id $TargetTz -ErrorAction Stop },
        { Set-TimeZone -Name $TargetTz -ErrorAction Stop }
    )
    [TimeZoneInfo]::ClearCachedData()
    if (-not $tzSet) {
        Write-Note '可以手动改：设置 > 时间和语言 > 日期和时间，关掉「自动设置时区」，再选「(UTC-08:00) 太平洋时间(美国和加拿大)」。'
        return
    }
    if (-not $autoOff) {
        Write-Note '时区已经改好，但「自动设置时区」没关掉，之后可能被改回去；请到 设置 > 时间和语言 > 日期和时间 手动关闭。'
        return
    }
    Write-Log "时区已设为 $TargetTzName（$TargetTz）。"
}

# 语言列表里只剩 en-US 才算达标（这样输入法也只剩美式键盘）。
function Test-LangOk {
    $tags = @()
    try { $tags = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) } catch { }
    if ($tags.Count -eq 0) { $tags = @(Get-RegValue 'HKCU:\Control Panel\International\User Profile' 'Languages') }
    return ($tags.Count -eq 1 -and $tags[0] -eq 'en-US')
}

# 显示语言：已生效的值或「下次登录生效」的值是 en-US 都算设置成功。
function Test-UiLangOk {
    $desk = 'HKCU:\Control Panel\Desktop'
    $pending = @(Get-RegValue $desk 'PreferredUILanguagesPending')
    if ($pending.Count -ge 1 -and $pending[0]) { return ($pending[0] -eq 'en-US') }
    $now = @(Get-RegValue $desk 'PreferredUILanguages')
    return ($now.Count -ge 1 -and $now[0] -eq 'en-US')
}

function Test-SystemLocaleOk {
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'Default') -eq '0409') { return $true }
    try { return ((Get-WinSystemLocale).Name -eq 'en-US') } catch { return $false }
}

function Set-TargetLanguage {
    if (-not $script:DoLang) { return }
    Write-Log '准备把系统语言 / 区域设为 en-US…'
    if ($DryRun) {
        Write-Log '（演练）语言列表改为只有 en-US（输入法只留美式键盘）'
        Write-Log '（演练）显示语言、区域格式、国家或地区、系统区域设置改为 en-US / 美国'
        Write-Log '（演练）每一项先用系统命令改，不行再直接改注册表，改完逐项核对'
        return
    }
    $intl = 'HKCU:\Control Panel\International'
    $desk = 'HKCU:\Control Panel\Desktop'
    $nls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls'
    $results = @(
        (Invoke-Methods '语言列表和键盘（只留 en-US）' { Test-LangOk } @(
            { Set-WinUserLanguageList -LanguageList (New-WinUserLanguageList 'en-US') -Force -WarningAction SilentlyContinue -ErrorAction Stop },
            {
                New-Item -Path "$intl\User Profile" -Force | Out-Null
                Set-ItemProperty -Path "$intl\User Profile" -Name Languages -Value ([string[]]@('en-US')) -Type MultiString -ErrorAction Stop
            }
        )),
        (Invoke-Methods '显示语言' { Test-UiLangOk } @(
            { Set-WinUILanguageOverride -Language 'en-US' -ErrorAction Stop },
            { Set-ItemProperty -Path $desk -Name PreferredUILanguagesPending -Value ([string[]]@('en-US')) -Type MultiString -ErrorAction Stop },
            { Set-ItemProperty -Path $desk -Name PreferredUILanguages -Value ([string[]]@('en-US')) -Type MultiString -ErrorAction Stop }
        )),
        (Invoke-Methods '区域格式' { (Get-RegValue $intl 'LocaleName') -eq 'en-US' } @(
            { Set-Culture -CultureInfo 'en-US' -ErrorAction Stop },
            { Set-ItemProperty -Path $intl -Name LocaleName -Value 'en-US' -ErrorAction Stop }
        )),
        (Invoke-Methods '国家或地区' { (Get-WinHomeLocation).GeoId -eq 244 } @(
            { Set-WinHomeLocation -GeoId 244 -ErrorAction Stop },
            {
                Set-ItemProperty -Path "$intl\Geo" -Name Nation -Value '244' -ErrorAction Stop
                Set-ItemProperty -Path "$intl\Geo" -Name Name -Value 'US' -ErrorAction Stop
            }
        )),
        (Invoke-Methods '系统区域设置' { Test-SystemLocaleOk } @(
            { Set-WinSystemLocale -SystemLocale 'en-US' -ErrorAction Stop },
            {
                Set-ItemProperty -Path "$nls\Language" -Name Default -Value '0409' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name ACP -Value '1252' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name OEMCP -Value '437' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name MACCP -Value '10000' -ErrorAction Stop
            }
        ))
    )
    # Windows 11 才有：把设置同步到欢迎屏幕和新用户。没有这个命令不算错。
    if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
        try { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true } catch { }
    }
    # 没装英文显示语言包的话，界面文字仍然是中文：有管理员权限就直接装上。
    if (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue) {
        $hasEn = $false
        try { $hasEn = [bool](Get-InstalledLanguage -Language 'en-US' -ErrorAction Stop) } catch { }
        if (-not $hasEn) {
            Write-Log '系统还没有英文显示语言包，正在下载安装（需要联网，可能要几分钟）…'
            try { Install-Language -Language 'en-US' -ErrorAction Stop | Out-Null; Write-Log '英文语言包已安装。' }
            catch {
                Write-Note "英文语言包安装失败（$($_.Exception.Message)）。界面文字会继续显示中文；可到 设置 > 时间和语言 > 语言和区域 手动添加 English (United States)。"
            }
        }
    }
    if ($results -notcontains $false) { Write-Log '语言 / 区域已设为 en-US，键盘只保留美式键盘；注销或重启后生效。' }
}

# ------------------------------------------------------- 安装 / 卸载 Claude

function Invoke-Winget([string[]]$Arguments) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail '找不到 winget。请先在 Microsoft Store 安装或更新「应用安装程序」。'
        return $false
    }
    if ($DryRun) { Write-Log "（演练）winget $($Arguments -join ' ')"; return $true }
    & winget @Arguments
    return ($LASTEXITCODE -eq 0)
}

function Install-Code {
    if (-not (Confirm-Step '将用 winget 安装 Claude Code，是否继续？')) { Write-Log '已取消。'; return }
    if (Invoke-Winget @('install', '--id', 'Anthropic.ClaudeCode', '-e', '--accept-source-agreements', '--accept-package-agreements')) {
        Write-Log 'Claude Code 安装完成。重新打开终端后输入 claude 使用。'
    } else { Write-Fail 'Claude Code 安装失败。' }
}

function Uninstall-Code {
    $msg = "将卸载 Claude Code，但保留 $ClaudeDir 配置和会话数据。确定继续？"
    if ($script:RemoveUserData) { $msg = "将卸载 Claude Code，并删除 $ClaudeDir 配置和会话数据。此操作不可恢复，确定继续？" }
    if (-not (Confirm-Step $msg)) { Write-Log '已取消。'; return }
    if (-not $Force -and (Test-ClaudeRunning)) {
        Write-Fail 'Claude Code 正在运行。请先关闭所有 Claude Code 会话和终端（或加 -Force）。'; return
    }
    if (-not (Invoke-Winget @('uninstall', '--id', 'Anthropic.ClaudeCode', '-e'))) {
        Write-Note 'winget 没有卸载成功（可能不是用 winget 装的）。'
    }
    if ((Get-Command npm -ErrorAction SilentlyContinue) -and -not $DryRun) {
        Invoke-Native { npm ls -g '@anthropic-ai/claude-code' } | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log (Invoke-Native { npm uninstall -g '@anthropic-ai/claude-code' }) }
    }
    # 原生安装
    Remove-Safe (Join-Path $env:USERPROFILE '.local\bin\claude.exe') (Join-Path $env:USERPROFILE '.local\bin')
    Remove-Safe (Join-Path $env:USERPROFILE '.local\share\claude') (Join-Path $env:USERPROFILE '.local\share')
    if ($script:RemoveUserData) {
        Remove-Safe $ClaudeDir (Split-Path $ClaudeDir -Parent)
        Remove-Safe $ClaudeJson (Split-Path $ClaudeJson -Parent)
        Write-Log 'Claude Code 已卸载。用户数据已删除。'
    } else {
        Write-Log 'Claude Code 已卸载。配置和会话数据已保留。'
    }
}

function Install-Desktop {
    if (-not (Confirm-Step '将用 winget 安装 Claude Desktop，是否继续？')) { Write-Log '已取消。'; return }
    if (Invoke-Winget @('install', '--id', 'Anthropic.Claude', '-e', '--accept-source-agreements', '--accept-package-agreements')) {
        Write-Log 'Claude Desktop 安装完成。'
    } else { Write-Fail 'Claude Desktop 安装失败。' }
}

function Uninstall-Desktop {
    if (-not (Confirm-Step '将卸载 Claude Desktop。聊天记录和项目文件不会被删除。确定继续？')) { Write-Log '已取消。'; return }
    if (Invoke-Winget @('uninstall', '--id', 'Anthropic.Claude', '-e')) { Write-Log 'Claude Desktop 已卸载。' }
    else { Write-Fail 'Claude Desktop 卸载失败。' }
}

# ----------------------------------------------------------------- 主流程

# 逐项显示当前状态，√ 表示已经符合目标，× 表示还需要处理。
function Show-Status {
    $tz = (Get-TimeZone).Id
    $auto = ''
    $tzMark = if ($tz -eq $TargetTz) { '√' } else { '×' }
    if (Test-AutoTz) { $auto = '；「自动设置时区」开着，会被改回去'; $tzMark = '×' }
    $lang = Get-CurrentLang
    $langMark = if ($lang -eq 'en-US') { '√' } else { '×' }
    Write-Host "  $tzMark 时区：$tz（目标 $TargetTz$auto）"
    Write-Host "  $langMark 系统语言：$lang（目标 en-US）"
    $cl = Get-ChromeLang
    if ($null -eq $cl) {
        Write-Host '  - Chrome：未检测到'
    } else {
        $clMark = if ($cl -eq 'en-US') { '√' } else { '×' }
        if (-not $cl) { $cl = '未设置，跟随系统' }
        Write-Host "  $clMark Chrome 语言：$cl（目标 en-US）"
    }
    $code = if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))) { '已安装' } else { '未安装' }
    $desktop = if (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) { '已安装' } else { '未检测到' }
    Write-Host "  - Claude Code：$code    Claude Desktop：$desktop"
    Write-Host "  - Claude 数据目录：$ClaudeDir"
}

# 执行后逐项核对「选中的项目」有没有真的达到目标；没达到的记为未通过。
function Show-Verify([bool]$WantCache, [bool]$WantHistory, [bool]$WantChrome, [bool]$WantTz, [bool]$WantLang) {
    $failed = 0
    Write-Host ''
    Write-Host '执行后检查：'
    if ($WantTz) {
        if (Test-TzOk) { Write-Host "  √ 时区：$(Get-CurrentTz)，「自动设置时区」已关闭" }
        else { Write-Host "  × 时区：当前是 $(Get-CurrentTz)，目标 $TargetTz（并且要关闭「自动设置时区」）" -ForegroundColor Red; $failed++ }
    }
    if ($WantLang) {
        $bad = @()
        if (-not (Test-LangOk)) { $bad += '语言列表' }
        if (-not (Test-UiLangOk)) { $bad += '显示语言' }
        if ((Get-RegValue 'HKCU:\Control Panel\International' 'LocaleName') -ne 'en-US') { $bad += '区域格式' }
        if ((Get-WinHomeLocation).GeoId -ne 244) { $bad += '国家或地区' }
        if (-not (Test-SystemLocaleOk)) { $bad += '系统区域设置' }
        if ($bad.Count -eq 0) { Write-Host '  √ 系统语言 / 区域：en-US，键盘只剩美式键盘（注销或重启后完全生效）' }
        else { Write-Host "  × 系统语言 / 区域：这些还不是 en-US：$($bad -join '、')" -ForegroundColor Red; $failed++ }
    }
    if ($WantChrome) {
        if (-not (Test-Path -LiteralPath $ChromeData)) {
            Write-Host '  - Chrome：这台电脑没有装 Chrome，无需处理'
        } elseif (Test-ChromeRunning) {
            Write-Host '  × Chrome：还在运行，没有彻底退出' -ForegroundColor Red; $failed++
        } elseif ((Get-ChromeLang) -ne 'en-US') {
            Write-Host "  × Chrome 语言：当前是 $(Get-ChromeLang)，目标 en-US" -ForegroundColor Red; $failed++
        } else {
            Write-Host '  √ Chrome：已彻底退出，缓存已清理，语言 en-US'
        }
    }
    if ($WantCache) {
        $left = @($script:ClaudeCacheItems | Where-Object { Test-Path -LiteralPath (Join-Path $ClaudeDir $_) }).Count
        if ($left -eq 0) { Write-Host '  √ Claude Code 缓存：已清空' }
        else { Write-Host "  × Claude Code 缓存：还有 $left 项没清掉" -ForegroundColor Red; $failed++ }
    }
    if ($WantHistory) {
        $left = @($script:ClaudeHistoryItems | Where-Object { Test-Path -LiteralPath (Join-Path $ClaudeDir $_) }).Count
        if ($left -eq 0) { Write-Host '  √ Claude Code 会话历史：已清空' }
        else { Write-Host "  × Claude Code 会话历史：还有 $left 项没清掉" -ForegroundColor Red; $failed++ }
    }
    return $failed
}

function Invoke-Pipeline {
    if (-not ($script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang)) {
        Write-Host '请至少选择一个执行项目。'; return
    }
    $script:BackupDir = Join-Path $DataDir ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }
    if ($script:DoHistory -and -not (Confirm-Step '会删除 Claude Code 的会话记录、自动记忆和提示词历史，无法恢复。确定继续？')) {
        $script:DoHistory = $false
    }
    # 记下用户选了什么，最后按这个逐项核对。
    $wantCache = $script:DoCache; $wantHistory = $script:DoHistory; $wantChrome = $script:DoChrome
    $wantTz = $script:DoTz; $wantLang = $script:DoLang

    if ($script:DoTz -and -not $DryRun -and (Test-TzOk)) {
        Write-Log "时区已经是 $TargetTzName，无需修改。"
        $script:DoTz = $false
    }
    if ($script:DoTz -or $script:DoLang) { Save-Snapshot }

    Set-TargetTimezone
    Set-TargetLanguage
    Clear-Claude
    Clear-Chrome

    if ($DryRun) {
        Write-Log "演练结束，没有做任何修改。预计可释放 $(Format-Size $script:FreedBytes)。"
        return
    }
    $failed = Show-Verify $wantCache $wantHistory $wantChrome $wantTz $wantLang
    Write-Host ''
    if ($failed -eq 0 -and $script:Errors -eq 0) {
        Write-Log "全部完成，检查全部通过。共释放 $(Format-Size $script:FreedBytes)。"
    } elseif ($failed -eq 0) {
        Write-Log "选中的项目检查全部通过，但过程中有 $($script:Errors) 条报错，请看上面标了「失败」的行。共释放 $(Format-Size $script:FreedBytes)。"
    } else {
        Write-Log "有 $failed 项没有达到目标（上面标 × 的），原因请看标了「失败」的行。"
        $script:Errors += $failed
    }
    if ($wantLang) { Write-Log '提示：语言和键盘设置需要注销或重启 Windows 后才完全生效。' }
}

function Show-Menu {
    while ($true) {
        $script:DoCache = $false; $script:DoHistory = $false; $script:DoChrome = $false
        $script:DoTz = $false; $script:DoLang = $false
        $script:RemoveUserData = $false; $script:Errors = 0; $script:FreedBytes = [int64]0; $script:Removed = 0

        Write-Host ''
        Write-Host "================ 小川环境助手 $Version（Windows）================"
        Show-Status
        Write-Host ''
        Write-Host '  1) 清理 Claude Code 缓存、日志、临时文件'
        Write-Host '  2) 清理 Claude Code 会话历史（不可恢复）'
        Write-Host '  3) 清理 Chrome 缓存，并把 Chrome 语言设为 en-US'
        Write-Host "  4) 时区改为 $TargetTzName"
        Write-Host '  5) 系统语言 / 区域改为 en-US，键盘只留美式键盘'
        Write-Host '  a) 一键执行 1 3 4 5（推荐）'
        Write-Host '  i) 安装 Claude Code        u) 卸载 Claude Code'
        Write-Host '  I) 安装 Claude Desktop     U) 卸载 Claude Desktop'
        Write-Host '  q) 退出'
        Write-Host ''
        $choices = Read-Host '请输入要执行的项目（可多选，用空格分开，例如 1 3 4），然后按回车'
        $picked = $false; $act = ''
        foreach ($c in ($choices -split '[\s,]+' | Where-Object { $_ })) {
            # -ceq 区分大小写：i/u 是 Claude Code，I/U 是 Claude Desktop。
            if ($c -eq '1') { $script:DoCache = $true; $picked = $true }
            elseif ($c -eq '2') { $script:DoHistory = $true; $picked = $true }
            elseif ($c -eq '3') { $script:DoChrome = $true; $picked = $true }
            elseif ($c -eq '4') { $script:DoTz = $true; $picked = $true }
            elseif ($c -eq '5') { $script:DoLang = $true; $picked = $true }
            elseif ($c -eq 'a') { $script:DoCache = $true; $script:DoChrome = $true; $script:DoTz = $true; $script:DoLang = $true; $picked = $true }
            elseif ($c -ceq 'i') { $act = 'install-code' }
            elseif ($c -ceq 'u') { $act = 'uninstall-code' }
            elseif ($c -ceq 'I') { $act = 'install-desktop' }
            elseif ($c -ceq 'U') { $act = 'uninstall-desktop' }
            elseif ($c -eq 'q') { return }
            else { Write-Host "看不懂的选项：$c"; $act = 'none'; break }
        }
        if ($act -eq 'uninstall-code') {
            if (Confirm-Step '同时删除配置和会话数据？') { $script:RemoveUserData = $true }
            Uninstall-Code
        } elseif ($act -eq 'install-code') { Install-Code }
        elseif ($act -eq 'install-desktop') { Install-Desktop }
        elseif ($act -eq 'uninstall-desktop') { Uninstall-Desktop }
        elseif ($act -eq '' -and $picked) { Invoke-Pipeline }
        elseif ($act -eq '') { continue }

        Write-Host ''
        if ((Read-Host '按回车返回菜单（输入 q 退出）') -eq 'q') { return }
    }
}

function Show-Usage {
    Write-Host @"
小川环境助手 $Version（Windows 脚本版）

用法：
  双击 xiaochuan-env.bat                     交互菜单
  xiaochuan-env.bat -All                     直接执行：清缓存 + Chrome + 时区 + 语言
  xiaochuan-env.bat -All -DryRun             演练，只显示将要做的事
  xiaochuan-env.bat status                   检查当前状态（时区 / 语言 / Chrome 是否已达标）
  xiaochuan-env.bat install-code | uninstall-code [-RemoveData]
  xiaochuan-env.bat install-desktop | uninstall-desktop

选项：
  -Cache       清理 Claude Code 缓存、日志、临时文件
  -History     清理 Claude Code 会话历史（不可恢复）
  -Chrome      清理 Chrome 缓存，并把 Chrome 语言设为 en-US
  -Timezone    时区改为 $TargetTzName
  -Language    系统语言 / 区域改为 en-US，键盘只留美式键盘
  -All         等于 -Cache -Chrome -Timezone -Language（不含 -History）
  -DryRun      演练：只显示将要做的事，不做任何修改
  -Force       Claude Code 在运行时也继续清理
  -Yes         不再逐项确认

脚本会自己弹出 UAC 申请管理员权限，不需要手动「以管理员身份运行」。
"@
}

# ------------------------------------------------------------------- 入口

if ($Help) { Show-Usage; exit 0 }

if ($All) { $Cache = $true; $Chrome = $true; $Timezone = $true; $Language = $true }
$script:DoCache = [bool]$Cache
$script:DoHistory = [bool]$History
$script:DoChrome = [bool]$Chrome
$script:DoTz = [bool]$Timezone
$script:DoLang = [bool]$Language

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
        exit 1
    }
}

# 用别的管理员账户通过 UAC 提权时，清理和语言会改到那个账户上，而不是当前登录的用户。
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) {
    Write-Fail "当前登录用户 $OrigUser 不是管理员，UAC 用的是另一个账户 $env:USERNAME，设置会改错账户。请用管理员账户登录 Windows 后再运行。"
    Read-Host '按回车关闭'
    exit 1
}

try {
    switch ($Action) {
        'status' { Write-Host "小川环境助手 $Version（Windows）"; Show-Status }
        'install-code' { Install-Code }
        'uninstall-code' { Uninstall-Code }
        'install-desktop' { Install-Desktop }
        'uninstall-desktop' { Uninstall-Desktop }
        default {
            if ($script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang) { Invoke-Pipeline }
            else { Show-Menu }
        }
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
}

# 提权后是新开的窗口，结束前停一下，免得结果一闪而过。
if ($Elevated -and ($Action -or $script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:Errors)) {
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
}
if ($script:Errors -gt 0) { exit 1 }
exit 0
