# 小川环境助手 · Windows 脚本版
# 功能和 XiaochuanEnv.exe / macOS、Linux 版 xiaochuan-env.sh 对齐：
#   清理 Claude Code 缓存 / 会话历史、清理 Chrome 缓存并设为 en-US、
#   时区改为太平洋时间（America/Los_Angeles）、系统语言改为 en-US、关闭系统定位和 Chrome 定位、
#   安装 / 卸载 Claude。
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
    [switch]$Location,
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
$Version = '1.2.0'
$TargetTz = 'Pacific Standard Time'          # 即 America/Los_Angeles
$TargetTzName = 'America/Los_Angeles'

$DataDir = Join-Path $env:USERPROFILE '.xiaochuan-env'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$ClaudeJson = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' }
$ChromeData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$TzAutoKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'
# 「定位服务」总开关（设置 > 隐私和安全性 > 位置）：Value 为 Deny 表示关。
$LocConsent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
# 英文显示语言包最多等这么久；超时就不再等，其余项目照常完成。
$LangPackTimeoutMin = 15

$script:Errors = 0
$script:FreedBytes = [int64]0
$script:Removed = 0
$script:BackupDir = ''
$script:DoCache = $false
$script:DoHistory = $false
$script:DoChrome = $false
$script:DoTz = $false
$script:DoLang = $false
$script:DoLoc = $false
$script:LangPackState = ''
$script:RemoveUserData = [bool]$RemoveData

# ~.claude 下要清理的项目；执行结果也用这两份清单。
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
    Add-Bad $Message
}

# ---------------------------------------------------------------- 结果汇总
# 脚本结束前都会打印一份「执行结果」：完成的标绿色 √，没有完成的标红色 ×，
# 最后一行用整条绿底 / 红底显示总结果。
$script:Results = New-Object System.Collections.ArrayList
$script:OkCount = 0
$script:BadCount = 0
function Add-Ok([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "ok"; Text = $Text }); $script:OkCount++ }
function Add-Bad([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "bad"; Text = $Text }); $script:BadCount++ }
function Add-Info([string]$Text) { [void]$script:Results.Add([pscustomobject]@{ Kind = "info"; Text = $Text }) }
# 做完一件事：既显示一行日志，也记进最后的「执行结果」；演练时不算完成。
function Write-Done([string]$Message) {
    Write-Log $Message
    if ($DryRun) { Add-Info "（演练，实际没有执行）$Message" } else { Add-Ok $Message }
}
# 跳过 / 取消：既显示一行日志，也记进最后的「执行结果」（不算完成，也不算失败）。
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
        $data['intl'] = [System.Collections.Generic.Dictionary[string,object]]::new()
    }
    if ($Mode -eq 'local') {
        $data['intl']['app_locale'] = 'en-US'
    } else {
        # 语言列表整体替换成只有英文：中文等其它语言都会被删掉。
        $data['intl']['accept_languages'] = 'en-US,en'
        $data['intl']['selected_languages'] = 'en-US,en'
        # 拼写检查词典、「不翻译的语言」、翻译目标语言也只留英文。
        if (-not $data.ContainsKey('spellcheck') -or -not ($data['spellcheck'] -is [System.Collections.IDictionary])) {
            $data['spellcheck'] = [System.Collections.Generic.Dictionary[string,object]]::new()
        }
        $data['spellcheck']['dictionaries'] = [object[]]@('en-US')
        $data['translate_blocked_languages'] = [object[]]@('en')
        $data['translate_recent_target'] = 'en'
        # 定位：默认改成「不允许网站查看我的位置」（2 = 禁止），以前单独允许过的网站也一并清掉。
        if (-not $data.ContainsKey('profile') -or -not ($data['profile'] -is [System.Collections.IDictionary])) {
            $data['profile'] = [System.Collections.Generic.Dictionary[string,object]]::new()
        }
        $prof = $data['profile']
        if (-not $prof.ContainsKey('default_content_setting_values') -or -not ($prof['default_content_setting_values'] -is [System.Collections.IDictionary])) {
            $prof['default_content_setting_values'] = [System.Collections.Generic.Dictionary[string,object]]::new()
        }
        $prof['default_content_setting_values']['geolocation'] = 2
        if ($prof.ContainsKey('content_settings') -and ($prof['content_settings'] -is [System.Collections.IDictionary])) {
            $cs = $prof['content_settings']
            if ($cs.ContainsKey('exceptions') -and ($cs['exceptions'] -is [System.Collections.IDictionary])) {
                foreach ($k in 'geolocation', 'geolocation_with_options') {
                    if ($cs['exceptions'].ContainsKey($k)) { [void]$cs['exceptions'].Remove($k) }
                }
            }
        }
    }
    $tmp = "$File.xc-tmp"
    [IO.File]::WriteAllText($tmp, $ser.Serialize($data), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $File -Force
}

# 读回文件核对语言（和个人资料里的定位开关）是否已经是目标值。
function Test-ChromeJson([string]$File, [string]$Mode) {
    try { $text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) } catch { return $false }
    if ($Mode -eq 'local') { return ($text -match '"app_locale"\s*:\s*"en-US"') }
    return (($text -match '"accept_languages"\s*:\s*"en-US,en"') -and (Test-ChromeGeoText $text))
}

# 个人资料的配置里，定位的默认值是不是「禁止」（2）。
function Test-ChromeGeoText([string]$Text) {
    return ($Text -match '"default_content_setting_values"\s*:\s*\{[^{}]*"geolocation"\s*:\s*2')
}

function Get-ChromeProfiles {
    return @(Get-ChildItem -LiteralPath $ChromeData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
}

# 还没关掉定位的 Chrome 个人资料（目录名）。
function Get-ChromeGeoOnProfiles {
    $on = @()
    foreach ($p in (Get-ChromeProfiles)) {
        $prefs = Join-Path $p.FullName 'Preferences'
        if (-not (Test-Path -LiteralPath $prefs)) { continue }
        $text = ''
        try { $text = [IO.File]::ReadAllText($prefs, [Text.Encoding]::UTF8) } catch { }
        if (-not (Test-ChromeGeoText $text)) { $on += $p.Name }
    }
    return $on
}

# 改 Chrome 配置文件的语言和定位：直接改不行就去掉只读属性再改，再不行就夺取所有权后再改；每次都读回核对。
function Set-ChromeJson([string]$File, [string]$Mode, [string]$Label) {
    $what = if ($Mode -eq 'local') { '语言改为 en-US' } else { '语言改为 en-US、关闭定位' }
    return (Invoke-Methods "$Label 的$what" { Test-ChromeJson $File $Mode } @(
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
                Write-Fail 'Chrome 关不掉，已跳过缓存、语言和定位修改；请手动完全退出 Chrome（包括右下角托盘图标）后重试。'
                return
            }
        }
    }

    $beforeBytes = $script:FreedBytes; $beforeCount = $script:Removed
    $langOk = $true
    Write-Log '正在清理 Chrome 缓存、设置 en-US 并关闭 Chrome 定位…'

    foreach ($sub in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') {
        Remove-Safe (Join-Path $ChromeData $sub) $ChromeData
    }
    $profiles = @(Get-ChromeProfiles)
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
                Write-Log "（演练）$($p.Name)\Preferences 的语言列表改为只有英文（en-US,en），删除中文等其它语言；定位改为「不允许网站查看位置」"
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

    $tail = if ($langOk) { '语言已设为 en-US，定位已关闭。' } else { '语言 / 定位未完全修改。' }
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
        "location_system=$(Get-RegValue "HKLM:\$LocConsent" 'Value')"
        "location_user=$(Get-RegValue "HKCU:\$LocConsent" 'Value')"
        "location_desktop_apps=$(Get-RegValue "HKCU:\$LocConsent\NonPackaged" 'Value')"
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
    if ($results -notcontains $false) { Write-Log '语言 / 区域已设为 en-US，键盘只保留美式键盘；注销或重启后生效。' }
}

# 英文显示语言包是不是已经装好（只有输入法 / 基本输入功能不算）。
function Test-EnPackInstalled {
    try {
        $l = @(Get-InstalledLanguage -Language 'en-US' -ErrorAction Stop)
        if ($l.Count -eq 0 -or $null -eq $l[0]) { return $false }
        if ($l[0].PSObject.Properties['LanguagePacks']) {
            $packs = [string]$l[0].LanguagePacks
            return ($packs -and $packs -ne 'None' -and $packs -ne '0')
        }
        return $true
    } catch { return $false }
}

# 没装英文显示语言包的话，界面文字仍然是中文：自动下载安装。
# Install-Language 在网络不通 / Windows 更新卡住时会一直不返回，所以放到后台做并限时：
# 整个脚本的最后一步才做（其余项目先完成），超时或按 S 就不再等。
function Install-EnglishPack {
    if (-not $script:DoLang) { return }
    if (-not (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue)) { return }   # Windows 10 没有这组命令
    if (-not (Get-Command Install-Language -ErrorAction SilentlyContinue)) { return }
    if (Test-EnPackInstalled) { $script:LangPackState = 'ok'; return }
    if ($DryRun) {
        Write-Log "（演练）系统还没有英文显示语言包：会在最后下载安装，最多等 $LangPackTimeoutMin 分钟"
        return
    }
    $manual = '可到 设置 > 时间和语言 > 语言和区域 手动添加 English (United States)，或稍后重新运行本脚本'
    # 语言包是通过 Windows 更新下载的：更新服务被禁用时一定下不下来，先查出来，失败时直接说明原因。
    $wuOff = $false
    try { $wuOff = ((Get-Service -Name wuauserv -ErrorAction Stop).StartType -eq 'Disabled') } catch { }
    if ($wuOff) {
        $manual = "原因很可能是「Windows 更新」服务（wuauserv）被禁用了，请先在 服务 里把它改回「手动」；$manual"
        Write-Note '「Windows 更新」服务（wuauserv）是禁用状态，英文语言包很可能下载不了。'
    }
    # 只装显示语言包，不带语音、手写、OCR 这些附加功能：下载量小很多，也更不容易卡住。
    $lite = $false
    try { $lite = (Get-Command Install-Language).Parameters.ContainsKey('ExcludeFeatures') } catch { }
    Write-Log "系统还没有英文显示语言包，正在下载安装（需要联网；最多等 $LangPackTimeoutMin 分钟，按 S 可以跳过不等）…"
    $job = $null
    try {
        $job = Start-Job -ArgumentList $lite -ScriptBlock {
            param($lite)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            if ($lite) { Install-Language -Language 'en-US' -ExcludeFeatures | Out-Null }
            else { Install-Language -Language 'en-US' | Out-Null }
        }
    } catch {
        $script:LangPackState = "没有装上（$($_.Exception.Message)）；$manual"
        Write-Note "英文显示语言包$($script:LangPackState)"
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $limit = $LangPackTimeoutMin * 60
    $nextReport = 30
    $skipped = $false
    while ($job.State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt $limit) {
        Wait-Job -Job $job -Timeout 2 | Out-Null
        # 没有真正的控制台（输出被重定向）时读按键会抛异常，忽略即可。
        try {
            while ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -eq 'S') { $skipped = $true }
            }
        } catch { }
        if ($skipped) { break }
        if ($sw.Elapsed.TotalSeconds -ge $nextReport) {
            Write-Log ("  英文语言包还在下载安装，已等 {0} 秒（最多等 {1} 秒，按 S 跳过）…" -f [int]$sw.Elapsed.TotalSeconds, $limit)
            $nextReport += 30
        }
    }
    $state = $job.State
    $err = ''
    if ($state -ne 'Running') {
        try { Receive-Job -Job $job -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message }
    }
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }

    if (Test-EnPackInstalled) {
        $script:LangPackState = 'ok'
        Write-Log '英文显示语言包已安装。'
    } elseif ($state -eq 'Running') {
        $why = if ($skipped) { '已按 S 跳过' } else { "等了 $LangPackTimeoutMin 分钟还没下载完，不再等待；多半是网络连不上 Windows 更新" }
        $script:LangPackState = "没有装上（$why）。界面文字会继续显示中文；$manual"
        Write-Note "英文显示语言包$($script:LangPackState)"
    } else {
        if (-not $err) { $err = '安装命令结束了，但系统里仍然没有英文显示语言包' }
        $script:LangPackState = "没有装上（$err）。界面文字会继续显示中文；$manual"
        Write-Note "英文显示语言包$($script:LangPackState)"
    }
}

# ------------------------------------------------------------------- 定位

# 系统「定位服务」总开关、当前用户的「允许应用访问位置」、「允许桌面应用访问位置」是不是都关了。
function Test-LocSystemOff { return ((Get-RegValue "HKLM:\$LocConsent" 'Value') -eq 'Deny') }
function Test-LocUserOff { return ((Get-RegValue "HKCU:\$LocConsent" 'Value') -eq 'Deny') }
function Test-LocDesktopOff { return ((Get-RegValue "HKCU:\$LocConsent\NonPackaged" 'Value') -eq 'Deny') }
# 还开着的定位开关（名字）；全关了返回空。状态检查和执行结果共用。
function Get-LocOnParts {
    $on = @()
    if (-not (Test-LocSystemOff)) { $on += '「定位服务」总开关' }
    if (-not (Test-LocUserOff)) { $on += '「允许应用访问你的位置」' }
    if (-not (Test-LocDesktopOff)) { $on += '「允许桌面应用访问你的位置」' }
    return $on
}

function Set-LocConsentDeny([string]$Hive, [string]$Sub) {
    $path = "${Hive}:\$LocConsent$Sub"
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $path -Name Value -Value 'Deny' -Type String -ErrorAction Stop
}

function Set-LocationOff {
    if (-not $script:DoLoc) { return }
    Write-Log '准备关闭系统定位服务…'
    if ($DryRun) {
        Write-Log '（演练）关闭「定位服务」总开关、「允许应用访问你的位置」和「允许桌面应用访问你的位置」'
        return
    }
    $results = @(
        (Invoke-Methods '关闭「定位服务」总开关' { Test-LocSystemOff } @(
            { Set-LocConsentDeny 'HKLM' '' },
            { Invoke-Native { reg.exe add "HKLM\$LocConsent" /v Value /t REG_SZ /d Deny /f } }
        )),
        (Invoke-Methods '关闭「允许应用访问你的位置」' { Test-LocUserOff } @(
            { Set-LocConsentDeny 'HKCU' '' },
            { Invoke-Native { reg.exe add "HKCU\$LocConsent" /v Value /t REG_SZ /d Deny /f } }
        )),
        (Invoke-Methods '关闭「允许桌面应用访问你的位置」' { Test-LocDesktopOff } @(
            { Set-LocConsentDeny 'HKCU' '\NonPackaged' },
            { Invoke-Native { reg.exe add "HKCU\$LocConsent\NonPackaged" /v Value /t REG_SZ /d Deny /f } }
        ))
    )
    # 定位服务（lfsvc）自己记的开关也一起关掉，并把正在跑的服务停下来；这两步失败不算错。
    try {
        $cfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
        if (Test-Path -LiteralPath $cfg) { Set-ItemProperty -LiteralPath $cfg -Name Status -Value 0 -Type DWord -ErrorAction Stop }
    } catch { }
    Stop-Service -Name lfsvc -Force -ErrorAction SilentlyContinue
    if ($results -notcontains $false) { Write-Log '系统定位服务已关闭。' }
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
    if (-not (Confirm-Step '将用 winget 安装 Claude Code，是否继续？')) { Write-Skip '已取消。'; return }
    if (Invoke-Winget @('install', '--id', 'Anthropic.ClaudeCode', '-e', '--accept-source-agreements', '--accept-package-agreements')) {
        Write-Done 'Claude Code 安装完成。重新打开终端后输入 claude 使用。'
    } else { Write-Fail 'Claude Code 安装失败。' }
}

function Uninstall-Code {
    $msg = "将卸载 Claude Code，但保留 $ClaudeDir 配置和会话数据。确定继续？"
    if ($script:RemoveUserData) { $msg = "将卸载 Claude Code，并删除 $ClaudeDir 配置和会话数据。此操作不可恢复，确定继续？" }
    if (-not (Confirm-Step $msg)) { Write-Skip '已取消。'; return }
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
        Write-Done 'Claude Code 已卸载。用户数据已删除。'
    } else {
        Write-Done 'Claude Code 已卸载。配置和会话数据已保留。'
    }
}

function Install-Desktop {
    if (-not (Confirm-Step '将用 winget 安装 Claude Desktop，是否继续？')) { Write-Skip '已取消。'; return }
    if (Invoke-Winget @('install', '--id', 'Anthropic.Claude', '-e', '--accept-source-agreements', '--accept-package-agreements')) {
        Write-Done 'Claude Desktop 安装完成。'
    } else { Write-Fail 'Claude Desktop 安装失败。' }
}

function Uninstall-Desktop {
    if (-not (Confirm-Step '将卸载 Claude Desktop。聊天记录和项目文件不会被删除。确定继续？')) { Write-Skip '已取消。'; return }
    if (Invoke-Winget @('uninstall', '--id', 'Anthropic.Claude', '-e')) { Write-Done 'Claude Desktop 已卸载。' }
    else { Write-Fail 'Claude Desktop 卸载失败。' }
}

# ----------------------------------------------------------------- 主流程

# 状态里的一行：达标的绿色，没达标的红色并计数。
function Write-StatusLine([string]$Mark, [string]$Text) {
    if ($Mark -eq '√') { Write-Host "  √ $Text" -ForegroundColor Green }
    else { Write-Host "  × $Text" -ForegroundColor Red; $script:StatusBad++ }
}

# 逐项显示当前状态，√ 表示已经符合目标，× 表示还需要处理。
function Show-Status {
    $tz = (Get-TimeZone).Id
    $auto = ''
    $tzMark = if ($tz -eq $TargetTz) { '√' } else { '×' }
    if (Test-AutoTz) { $auto = '；「自动设置时区」开着，会被改回去'; $tzMark = '×' }
    $lang = Get-CurrentLang
    $langMark = if ($lang -eq 'en-US') { '√' } else { '×' }
    $script:StatusBad = 0
    Write-StatusLine $tzMark "时区：$tz（目标 $TargetTz$auto）"
    Write-StatusLine $langMark "系统语言：$lang（目标 en-US）"
    $locOn = @(Get-LocOnParts)
    if ($locOn.Count -eq 0) { Write-StatusLine '√' '系统定位：已关闭' }
    else { Write-StatusLine '×' "系统定位：这些还开着：$($locOn -join '、')（目标 全部关闭）" }
    $cl = Get-ChromeLang
    if ($null -eq $cl) {
        Write-Host '  - Chrome：未检测到'
    } else {
        $clMark = if ($cl -eq 'en-US') { '√' } else { '×' }
        if (-not $cl) { $cl = '未设置，跟随系统' }
        Write-StatusLine $clMark "Chrome 语言：$cl（目标 en-US）"
        $geoOn = @(Get-ChromeGeoOnProfiles)
        if ($geoOn.Count -eq 0) { Write-StatusLine '√' 'Chrome 定位：已关闭' }
        else { Write-StatusLine '×' "Chrome 定位：这些个人资料还开着：$($geoOn -join '、')（目标 关闭）" }
    }
    $code = if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))) { '已安装' } else { '未安装' }
    $desktop = if (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) { '已安装' } else { '未检测到' }
    Write-Host "  - Claude Code：$code    Claude Desktop：$desktop"
    Write-Host "  - Claude 数据目录：$ClaudeDir"
}

# 执行后逐项核对「选中的项目」有没有真的达到目标；没达到的记为未通过。
function Show-Verify([bool]$WantCache, [bool]$WantHistory, [bool]$WantChrome, [bool]$WantTz, [bool]$WantLang, [bool]$WantLoc) {
    $failed = 0
    if ($WantTz) {
        if (Test-TzOk) { Add-Ok "时区：$(Get-CurrentTz)，「自动设置时区」已关闭" }
        else { Add-Bad "时区：当前是 $(Get-CurrentTz)，目标 $TargetTz（并且要关闭「自动设置时区」）"; $failed++ }
    }
    if ($WantLang) {
        $bad = @()
        if (-not (Test-LangOk)) { $bad += '语言列表' }
        if (-not (Test-UiLangOk)) { $bad += '显示语言' }
        if ((Get-RegValue 'HKCU:\Control Panel\International' 'LocaleName') -ne 'en-US') { $bad += '区域格式' }
        if ((Get-WinHomeLocation).GeoId -ne 244) { $bad += '国家或地区' }
        if (-not (Test-SystemLocaleOk)) { $bad += '系统区域设置' }
        if ($bad.Count -eq 0) { Add-Ok '系统语言 / 区域：en-US，键盘只剩美式键盘（注销或重启后完全生效）' }
        else { Add-Bad "系统语言 / 区域：这些还不是 en-US：$($bad -join '、')"; $failed++ }
        if ($script:LangPackState -eq 'ok') { Add-Ok '英文显示语言包：已安装' }
        elseif ($script:LangPackState) { Add-Bad "英文显示语言包：$($script:LangPackState)"; $failed++ }
    }
    if ($WantLoc) {
        $bad = @(Get-LocOnParts)
        if ($bad.Count -eq 0) { Add-Ok '系统定位：定位服务已关闭' }
        else { Add-Bad "系统定位：这些还开着：$($bad -join '、')"; $failed++ }
    }
    if ($WantChrome) {
        $geoOn = @()
        if (Test-Path -LiteralPath $ChromeData) { $geoOn = @(Get-ChromeGeoOnProfiles) }
        if (-not (Test-Path -LiteralPath $ChromeData)) {
            Add-Info 'Chrome：这台电脑没有装 Chrome，无需处理'
        } elseif (Test-ChromeRunning) {
            Add-Bad 'Chrome：还在运行，没有彻底退出'; $failed++
        } elseif ((Get-ChromeLang) -ne 'en-US') {
            Add-Bad "Chrome 语言：当前是 $(Get-ChromeLang)，目标 en-US"; $failed++
        } elseif ($geoOn.Count -gt 0) {
            Add-Bad "Chrome 定位：这些个人资料还没关掉：$($geoOn -join '、')"; $failed++
        } else {
            Add-Ok 'Chrome：已彻底退出，缓存已清理，语言 en-US，定位已关闭'
        }
    }
    if ($WantCache) {
        $left = @($script:ClaudeCacheItems | Where-Object { Test-Path -LiteralPath (Join-Path $ClaudeDir $_) }).Count
        if ($left -eq 0) { Add-Ok 'Claude Code 缓存：已清空' }
        else { Add-Bad "Claude Code 缓存：还有 $left 项没清掉"; $failed++ }
    }
    if ($WantHistory) {
        $left = @($script:ClaudeHistoryItems | Where-Object { Test-Path -LiteralPath (Join-Path $ClaudeDir $_) }).Count
        if ($left -eq 0) { Add-Ok 'Claude Code 会话历史：已清空' }
        else { Add-Bad "Claude Code 会话历史：还有 $left 项没清掉"; $failed++ }
    }
    return $failed
}

function Invoke-Pipeline {
    if (-not ($script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:DoLoc)) {
        Write-Host '请至少选择一个执行项目。'; return
    }
    $script:BackupDir = Join-Path $DataDir ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }
    if ($script:DoHistory -and -not (Confirm-Step '会删除 Claude Code 的会话记录、自动记忆和提示词历史，无法恢复。确定继续？')) {
        $script:DoHistory = $false
    }
    # 记下用户选了什么，最后按这个逐项核对。
    $wantCache = $script:DoCache; $wantHistory = $script:DoHistory; $wantChrome = $script:DoChrome
    $wantTz = $script:DoTz; $wantLang = $script:DoLang; $wantLoc = $script:DoLoc
    $script:LangPackState = ''

    if ($script:DoTz -and -not $DryRun -and (Test-TzOk)) {
        Write-Log "时区已经是 $TargetTzName，无需修改。"
        $script:DoTz = $false
    }
    if ($script:DoTz -or $script:DoLang -or $script:DoLoc) { Save-Snapshot }

    Set-TargetTimezone
    Set-TargetLanguage
    Set-LocationOff
    Clear-Claude
    Clear-Chrome
    # 英文语言包要联网下载，可能很慢甚至卡住：放在最后，其余项目都已经做完了。
    Install-EnglishPack

    if ($DryRun) {
        Write-Skip "演练结束，没有做任何修改。预计可释放 $(Format-Size $script:FreedBytes)。"
        return
    }
    # 逐项核对的结果记进「执行结果」，由调用的地方统一打印。
    $failed = Show-Verify $wantCache $wantHistory $wantChrome $wantTz $wantLang $wantLoc
    $script:Errors += $failed
    Add-Info "共释放 $(Format-Size $script:FreedBytes)"
    if ($wantLang) { Add-Info '提示：语言和键盘设置需要注销或重启 Windows 后才完全生效' }
}

function Show-Menu {
    while ($true) {
        $script:DoCache = $false; $script:DoHistory = $false; $script:DoChrome = $false
        $script:DoTz = $false; $script:DoLang = $false; $script:DoLoc = $false
        $script:RemoveUserData = $false; $script:Errors = 0; $script:FreedBytes = [int64]0; $script:Removed = 0
        $script:Results.Clear(); $script:OkCount = 0; $script:BadCount = 0

        Write-Host ''
        Write-Host "================ 小川环境助手 $Version（Windows）================"
        Show-Status
        Write-Host ''
        Write-Host '  1) 清理 Claude Code 缓存、日志、临时文件'
        Write-Host '  2) 清理 Claude Code 会话历史（不可恢复）'
        Write-Host '  3) 清理 Chrome 缓存，把 Chrome 语言设为 en-US，并关闭 Chrome 定位'
        Write-Host "  4) 时区改为 $TargetTzName"
        Write-Host '  5) 系统语言 / 区域改为 en-US，键盘只留美式键盘'
        Write-Host '  6) 关闭系统定位服务'
        Write-Host '  a) 一键执行 1 3 4 5 6（推荐）'
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
            elseif ($c -eq '6') { $script:DoLoc = $true; $picked = $true }
            elseif ($c -eq 'a') { $script:DoCache = $true; $script:DoChrome = $true; $script:DoTz = $true; $script:DoLang = $true; $script:DoLoc = $true; $picked = $true }
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
        if ($act -ne 'none') { Show-Result }

        Write-Host ''
        if ((Read-Host '按回车返回菜单（输入 q 退出）') -eq 'q') { return }
    }
}

function Show-Usage {
    Write-Host @"
小川环境助手 $Version（Windows 脚本版）

用法：
  双击 xiaochuan-env.bat                     交互菜单
  xiaochuan-env.bat -All                     直接执行：清缓存 + Chrome + 时区 + 语言 + 关定位
  xiaochuan-env.bat -All -DryRun             演练，只显示将要做的事
  xiaochuan-env.bat status                   检查当前状态（时区 / 语言 / 定位 / Chrome 是否已达标）
  xiaochuan-env.bat install-code | uninstall-code [-RemoveData]
  xiaochuan-env.bat install-desktop | uninstall-desktop

选项：
  -Cache       清理 Claude Code 缓存、日志、临时文件
  -History     清理 Claude Code 会话历史（不可恢复）
  -Chrome      清理 Chrome 缓存，把 Chrome 语言设为 en-US，并关闭 Chrome 定位
  -Timezone    时区改为 $TargetTzName
  -Language    系统语言 / 区域改为 en-US，键盘只留美式键盘
  -Location    关闭系统定位服务
  -All         等于 -Cache -Chrome -Timezone -Language -Location（不含 -History）
  -DryRun      演练：只显示将要做的事，不做任何修改
  -Force       Claude Code 在运行时也继续清理
  -Yes         不再逐项确认

脚本会自己弹出 UAC 申请管理员权限，不需要手动「以管理员身份运行」。
"@
}

# ------------------------------------------------------------------- 入口

if ($Help) { Show-Usage; exit 0 }

if ($All) { $Cache = $true; $Chrome = $true; $Timezone = $true; $Language = $true; $Location = $true }
$script:DoCache = [bool]$Cache
$script:DoHistory = [bool]$History
$script:DoChrome = [bool]$Chrome
$script:DoTz = [bool]$Timezone
$script:DoLang = [bool]$Language
$script:DoLoc = [bool]$Location

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

# 用别的管理员账户通过 UAC 提权时，清理和语言会改到那个账户上，而不是当前登录的用户。
if ($Elevated -and $OrigUser -and $OrigUser -ne $env:USERNAME) {
    Write-Fail "当前登录用户 $OrigUser 不是管理员，UAC 用的是另一个账户 $env:USERNAME，设置会改错账户。请用管理员账户登录 Windows 后再运行。"
    Show-Result
    Read-Host '按回车关闭'
    exit 1
}

# 菜单里每执行完一次都会打印「执行结果」；其余情况在这里统一打印一次。
$showResult = $true
try {
    switch ($Action) {
        'status' {
            $showResult = $false
            Write-Host "小川环境助手 $Version（Windows）"
            Show-Status
            Write-Host '=========================================='
            if ($script:StatusBad -eq 0) {
                Write-Host ' 结果：时区、语言、定位都已达标 ' -ForegroundColor White -BackgroundColor DarkGreen
            } else {
                Write-Host " 结果：有 $($script:StatusBad) 项还没达标（上面标 × 的红色行） " -ForegroundColor White -BackgroundColor Red
                $script:Errors += $script:StatusBad
            }
        }
        'install-code' { Install-Code }
        'uninstall-code' { Uninstall-Code }
        'install-desktop' { Install-Desktop }
        'uninstall-desktop' { Uninstall-Desktop }
        default {
            if ($script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:DoLoc) { Invoke-Pipeline }
            else { $showResult = $false; Show-Menu }
        }
    }
} catch {
    Write-Fail "脚本出错：$($_.Exception.Message)"
    $showResult = $true
}
if ($showResult) { Show-Result }

# 提权后是新开的窗口，结束前停一下，免得结果一闪而过。
if ($Elevated -and ($Action -or $script:DoCache -or $script:DoHistory -or $script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:DoLoc -or $script:Errors)) {
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
}
if ($script:Errors -gt 0) { exit 1 }
exit 0
