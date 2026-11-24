# 小川环境还原助手 · Windows 脚本版
# 把 xiaochuan-env.ps1 改过的设置还原成「中国 / 中文」：
#   时区改回中国标准时间（Asia/Shanghai）、系统语言 / 区域改回简体中文并加回中文输入法、
#   打开系统定位、打开系统 IPv6、Chrome 语言改回 zh-CN 并恢复 Chrome 定位。
# 清理掉的缓存 / 会话历史无法还原，也不需要还原。
# 兼容 Windows 自带的 PowerShell 5.1。本文件必须保存为「UTF-8 带 BOM」，否则中文会乱码。

[CmdletBinding()]
param(
    [ValidateSet('', 'status')]
    [string]$Action = '',
    [switch]$Chrome,
    [switch]$Timezone,
    [switch]$Language,
    [switch]$Location,
    [switch]$IPv6,
    [switch]$All,
    [switch]$DryRun,
    [switch]$Help,
    # 以下两个是脚本自己提权重启时用的，不需要手动传。
    [switch]$Elevated,
    [string]$OrigUser = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$TargetTz = 'China Standard Time'          # 即 Asia/Shanghai
$TargetTzName = 'Asia/Shanghai'
$TargetGeoId = 45                          # 中国

$DataDir = Join-Path $env:USERPROFILE '.xiaochuan-env'
# xiaochuan-env.ps1 修改前留下的备份；最早的那一份就是最原始的设置。
$EnvBackups = Join-Path $DataDir 'backups'
$ChromeData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$TzAutoKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'
$LocConsent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$Ip6Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'

$script:Errors = 0
$script:BackupDir = ''
$script:DoChrome = $false
$script:DoTz = $false
$script:DoLang = $false
$script:DoLoc = $false
$script:DoIp6 = $false
$script:StatusBad = 0

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

function Backup-File([string]$Source, [string]$Relative) {
    if ($DryRun -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $dest = Join-Path $script:BackupDir $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $dest -Force
}

# xiaochuan-env.ps1 最早一次设置快照里的某一项（key=value 里的 value）；没有则返回空字符串。
# 备份目录名是时间，按名字排序的第一个就是最早的。
function Get-OldSetting([string]$Key) {
    if (-not (Test-Path -LiteralPath $EnvBackups)) { return '' }
    foreach ($d in (Get-ChildItem -LiteralPath $EnvBackups -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $snap = Join-Path $d.FullName 'settings-snapshot.txt'
        if (-not (Test-Path -LiteralPath $snap)) { continue }
        foreach ($line in (Get-Content -LiteralPath $snap -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1).Trim() }
        }
        return ''
    }
    return ''
}

# --------------------------------------------------------------------- Chrome

function Test-ChromeRunning {
    return [bool](Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)
}

# 关闭 Chrome：先正常关闭（标签页下次可以恢复），关不掉再强制结束。
function Stop-Chrome {
    Invoke-Native { taskkill.exe /IM chrome.exe } | Out-Null
    for ($i = 0; $i -lt 10 -and (Test-ChromeRunning); $i++) { Start-Sleep -Seconds 1 }
    if (Test-ChromeRunning) {
        Get-Process -Name 'chrome' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 10 -and (Test-ChromeRunning); $i++) { Start-Sleep -Seconds 1 }
    }
    return (-not (Test-ChromeRunning))
}

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
        $data['intl']['app_locale'] = 'zh-CN'
    } else {
        # 语言列表改回中文；「不翻译的语言」、翻译目标语言也改回中文。
        $data['intl']['accept_languages'] = 'zh-CN,zh'
        $data['intl']['selected_languages'] = 'zh-CN,zh'
        $data['translate_blocked_languages'] = [object[]]@('zh-CN')
        $data['translate_recent_target'] = 'zh-CN'
        # 定位：去掉「禁止」，回到 Chrome 默认的「网站可以询问」。
        if ($data.ContainsKey('profile') -and ($data['profile'] -is [System.Collections.IDictionary])) {
            $prof = $data['profile']
            if ($prof.ContainsKey('default_content_setting_values') -and ($prof['default_content_setting_values'] -is [System.Collections.IDictionary])) {
                if ($prof['default_content_setting_values'].ContainsKey('geolocation')) {
                    [void]$prof['default_content_setting_values'].Remove('geolocation')
                }
            }
        }
    }
    $tmp = "$File.xc-tmp"
    [IO.File]::WriteAllText($tmp, $ser.Serialize($data), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $File -Force
}

# 个人资料的配置里，定位的默认值是不是还被设成「禁止」（2）。
function Test-ChromeGeoOffText([string]$Text) {
    return ($Text -match '"default_content_setting_values"\s*:\s*\{[^{}]*"geolocation"\s*:\s*2')
}

# 读回文件核对是否已经还原。
function Test-ChromeJson([string]$File, [string]$Mode) {
    try { $text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) } catch { return $false }
    if ($Mode -eq 'local') { return ($text -match '"app_locale"\s*:\s*"zh-CN"') }
    return (($text -match '"accept_languages"\s*:\s*"zh-CN,zh"') -and -not (Test-ChromeGeoOffText $text))
}

function Get-ChromeProfiles {
    return @(Get-ChildItem -LiteralPath $ChromeData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
}

# 定位还被禁止的 Chrome 个人资料（目录名）。
function Get-ChromeGeoOffProfiles {
    $off = @()
    foreach ($p in (Get-ChromeProfiles)) {
        $prefs = Join-Path $p.FullName 'Preferences'
        if (-not (Test-Path -LiteralPath $prefs)) { continue }
        $text = ''
        try { $text = [IO.File]::ReadAllText($prefs, [Text.Encoding]::UTF8) } catch { }
        if (Test-ChromeGeoOffText $text) { $off += $p.Name }
    }
    return $off
}

# 直接改不行就去掉只读属性再改，再不行就夺取所有权后再改；每次都读回核对。
function Set-ChromeJson([string]$File, [string]$Mode, [string]$Label) {
    $what = if ($Mode -eq 'local') { '语言改回 zh-CN' } else { '语言改回 zh-CN、恢复定位' }
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

function Restore-Chrome {
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
                Write-Fail 'Chrome 关不掉，已跳过语言和定位的还原；请手动完全退出 Chrome（包括右下角托盘图标）后重试。'
                return
            }
        }
    }

    $allOk = $true
    Write-Log '正在把 Chrome 语言改回 zh-CN，并恢复 Chrome 定位…'
    foreach ($p in @(Get-ChromeProfiles)) {
        $prefs = Join-Path $p.FullName 'Preferences'
        if (-not (Test-Path -LiteralPath $prefs)) { continue }
        Backup-File $prefs "chrome-files\$($p.Name)\Preferences"
        if ($DryRun) {
            Write-Log "（演练）$($p.Name)\Preferences 的语言列表改回中文（zh-CN,zh）；定位改回「网站可以询问」"
        } else {
            if (-not (Set-ChromeJson $prefs 'prefs' "$($p.Name)\Preferences")) { $allOk = $false }
        }
    }

    $localState = Join-Path $ChromeData 'Local State'
    if (Test-Path -LiteralPath $localState) {
        Backup-File $localState 'chrome-files\Local State'
        if ($DryRun) {
            Write-Log '（演练）Local State 的界面语言改回 zh-CN'
        } else {
            if (-not (Set-ChromeJson $localState 'local' 'Local State')) { $allOk = $false }
        }
    }

    if ($allOk -and -not $DryRun) { Write-Log 'Chrome：语言已改回 zh-CN，定位已恢复为「网站可以询问」。' }
    $bk = Join-Path $script:BackupDir 'chrome-files'
    if (-not $DryRun -and (Test-Path -LiteralPath $bk)) { Write-Log "Chrome 备份：$bk" }
}

# ------------------------------------------------------------------- 时区

function Get-CurrentTz { return (Invoke-Native { tzutil.exe /g }) }
function Test-TzOk { return ((Get-CurrentTz) -eq $TargetTz) }

function Set-TargetTimezone {
    if (-not $script:DoTz) { return }
    Write-Log "当前时区 $(Get-CurrentTz)，准备改回 $TargetTzName…"
    if ($DryRun) {
        Write-Log "（演练）依次尝试各种方式把时区改为 $TargetTzName（$TargetTz），直到核对成功。"
        return
    }
    if (Test-TzOk) { Write-Log "时区已经是 $TargetTzName，无需修改。"; return }
    # 命令的返回值不可靠，每试一种方式都读回当前时区核对。
    $tzSet = Invoke-Methods "时区改为 $TargetTzName" { Test-TzOk } @(
        { Invoke-Native { tzutil.exe /s $TargetTz } },
        { Set-TimeZone -Id $TargetTz -ErrorAction Stop },
        { Set-TimeZone -Name $TargetTz -ErrorAction Stop }
    )
    [TimeZoneInfo]::ClearCachedData()
    if (-not $tzSet) {
        Write-Note '可以手动改：设置 > 时间和语言 > 日期和时间，选「(UTC+08:00) 北京，重庆，香港特别行政区，乌鲁木齐」。'
        return
    }
    Write-Log "时区已设为 $TargetTzName（$TargetTz）。"
}

# ------------------------------------------------------------ 语言 / 输入法

function Get-CurrentLang {
    try { return [string](Get-WinUserLanguageList)[0].LanguageTag } catch { return '' }
}

# 语言列表的第一项是中文才算还原（这样输入法里就有微软拼音）。
function Test-LangOk {
    $tags = @()
    try { $tags = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) } catch { }
    if ($tags.Count -eq 0) { $tags = @(Get-RegValue 'HKCU:\Control Panel\International\User Profile' 'Languages') }
    return ($tags.Count -ge 1 -and "$($tags[0])" -like 'zh*')
}

# 显示语言：已生效的值或「下次登录生效」的值是 zh-CN 都算设置成功。
function Test-UiLangOk {
    $desk = 'HKCU:\Control Panel\Desktop'
    $pending = @(Get-RegValue $desk 'PreferredUILanguagesPending')
    if ($pending.Count -ge 1 -and $pending[0]) { return ($pending[0] -eq 'zh-CN') }
    $now = @(Get-RegValue $desk 'PreferredUILanguages')
    return ($now.Count -ge 1 -and $now[0] -eq 'zh-CN')
}

function Test-SystemLocaleOk {
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'Default') -eq '0804') { return $true }
    try { return ((Get-WinSystemLocale).Name -eq 'zh-CN') } catch { return $false }
}

# 中文显示语言包在不在：$true 在，$false 不在，$null 查不了（Windows 10 没有这组命令）。
function Test-ZhPackInstalled {
    if (-not (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue)) { return $null }
    try {
        $l = @(Get-InstalledLanguage -Language 'zh-CN' -ErrorAction Stop)
        if ($l.Count -eq 0 -or $null -eq $l[0]) { return $false }
        if ($l[0].PSObject.Properties['LanguagePacks']) {
            $packs = [string]$l[0].LanguagePacks
            return [bool]($packs -and $packs -ne 'None' -and $packs -ne '0')
        }
        return $true
    } catch { return $false }
}

# 要还原成的语言列表：修改前的列表如果是中文打头就照原样恢复（比如「中文 + 英文」），否则只放中文。
function Get-TargetLanguageTags {
    $old = @((Get-OldSetting 'user_languages') -split ',' | Where-Object { $_ })
    if ($old.Count -ge 1 -and $old[0] -like 'zh*') { return $old }
    return @('zh-CN')
}

function Set-TargetLanguage {
    if (-not $script:DoLang) { return }
    Write-Log '准备把系统语言 / 区域改回简体中文（中国）…'
    if ($DryRun) {
        Write-Log "（演练）语言列表改回：$((Get-TargetLanguageTags) -join '、')（带微软拼音输入法）"
        Write-Log '（演练）显示语言、区域格式、国家或地区、系统区域设置改回 zh-CN / 中国'
        Write-Log '（演练）每一项先用系统命令改，不行再直接改注册表，改完逐项核对'
        return
    }
    $intl = 'HKCU:\Control Panel\International'
    $desk = 'HKCU:\Control Panel\Desktop'
    $nls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls'
    $results = @(
        (Invoke-Methods '语言列表和输入法（改回中文）' { Test-LangOk } @(
            {
                $tags = @(Get-TargetLanguageTags)
                $list = New-WinUserLanguageList $tags[0]
                foreach ($t in ($tags | Select-Object -Skip 1)) { $list.Add($t) }
                Set-WinUserLanguageList -LanguageList $list -Force -WarningAction SilentlyContinue -ErrorAction Stop
            },
            { Set-WinUserLanguageList -LanguageList (New-WinUserLanguageList 'zh-CN') -Force -WarningAction SilentlyContinue -ErrorAction Stop },
            {
                New-Item -Path "$intl\User Profile" -Force | Out-Null
                Set-ItemProperty -Path "$intl\User Profile" -Name Languages -Value ([string[]]@('zh-Hans-CN')) -Type MultiString -ErrorAction Stop
            }
        )),
        (Invoke-Methods '显示语言' { Test-UiLangOk } @(
            { Set-WinUILanguageOverride -Language 'zh-CN' -ErrorAction Stop },
            { Set-ItemProperty -Path $desk -Name PreferredUILanguagesPending -Value ([string[]]@('zh-CN')) -Type MultiString -ErrorAction Stop },
            { Set-ItemProperty -Path $desk -Name PreferredUILanguages -Value ([string[]]@('zh-CN')) -Type MultiString -ErrorAction Stop }
        )),
        (Invoke-Methods '区域格式' { (Get-RegValue $intl 'LocaleName') -eq 'zh-CN' } @(
            { Set-Culture -CultureInfo 'zh-CN' -ErrorAction Stop },
            { Set-ItemProperty -Path $intl -Name LocaleName -Value 'zh-CN' -ErrorAction Stop }
        )),
        (Invoke-Methods '国家或地区' { (Get-WinHomeLocation).GeoId -eq $TargetGeoId } @(
            { Set-WinHomeLocation -GeoId $TargetGeoId -ErrorAction Stop },
            {
                Set-ItemProperty -Path "$intl\Geo" -Name Nation -Value "$TargetGeoId" -ErrorAction Stop
                Set-ItemProperty -Path "$intl\Geo" -Name Name -Value 'CN' -ErrorAction Stop
            }
        )),
        (Invoke-Methods '系统区域设置' { Test-SystemLocaleOk } @(
            { Set-WinSystemLocale -SystemLocale 'zh-CN' -ErrorAction Stop },
            {
                Set-ItemProperty -Path "$nls\Language" -Name Default -Value '0804' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name ACP -Value '936' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name OEMCP -Value '936' -ErrorAction Stop
                Set-ItemProperty -Path "$nls\CodePage" -Name MACCP -Value '10008' -ErrorAction Stop
            }
        ))
    )
    # Windows 11 才有：把设置同步到欢迎屏幕和新用户。没有这个命令不算错。
    if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
        try { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true } catch { }
    }
    if ($results -notcontains $false) { Write-Log '语言 / 区域已改回简体中文，输入法已加回微软拼音；注销或重启后生效。' }
}

# ------------------------------------------------------------------- 定位

function Test-LocSystemOn { return ((Get-RegValue "HKLM:\$LocConsent" 'Value') -eq 'Allow') }
function Test-LocUserOn { return ((Get-RegValue "HKCU:\$LocConsent" 'Value') -eq 'Allow') }
function Test-LocDesktopOn { return ((Get-RegValue "HKCU:\$LocConsent\NonPackaged" 'Value') -eq 'Allow') }
# 还关着的定位开关（名字）；全开了返回空。状态检查和执行结果共用。
function Get-LocOffParts {
    $off = @()
    if (-not (Test-LocSystemOn)) { $off += '「定位服务」总开关' }
    if (-not (Test-LocUserOn)) { $off += '「允许应用访问你的位置」' }
    if (-not (Test-LocDesktopOn)) { $off += '「允许桌面应用访问你的位置」' }
    return $off
}

function Set-LocConsentAllow([string]$Hive, [string]$Sub) {
    $path = "${Hive}:\$LocConsent$Sub"
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $path -Name Value -Value 'Allow' -Type String -ErrorAction Stop
}

function Set-LocationOn {
    if (-not $script:DoLoc) { return }
    Write-Log '准备打开系统定位服务…'
    if ($DryRun) {
        Write-Log '（演练）打开「定位服务」总开关、「允许应用访问你的位置」和「允许桌面应用访问你的位置」'
        return
    }
    $results = @(
        (Invoke-Methods '打开「定位服务」总开关' { Test-LocSystemOn } @(
            { Set-LocConsentAllow 'HKLM' '' },
            { Invoke-Native { reg.exe add "HKLM\$LocConsent" /v Value /t REG_SZ /d Allow /f } }
        )),
        (Invoke-Methods '打开「允许应用访问你的位置」' { Test-LocUserOn } @(
            { Set-LocConsentAllow 'HKCU' '' },
            { Invoke-Native { reg.exe add "HKCU\$LocConsent" /v Value /t REG_SZ /d Allow /f } }
        )),
        (Invoke-Methods '打开「允许桌面应用访问你的位置」' { Test-LocDesktopOn } @(
            { Set-LocConsentAllow 'HKCU' '\NonPackaged' },
            { Invoke-Native { reg.exe add "HKCU\$LocConsent\NonPackaged" /v Value /t REG_SZ /d Allow /f } }
        ))
    )
    # 定位服务（lfsvc）自己记的开关也一起打开，并把服务拉起来；这两步失败不算错。
    try {
        $cfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
        if (Test-Path -LiteralPath $cfg) { Set-ItemProperty -LiteralPath $cfg -Name Status -Value 1 -Type DWord -ErrorAction Stop }
    } catch { }
    Start-Service -Name lfsvc -ErrorAction SilentlyContinue
    if ($results -notcontains $false) { Write-Log '系统定位服务已打开。' }
}

# ------------------------------------------------------------------- IPv6

# 系统级开关是不是还处在「全部关闭」（低 8 位全为 1）。
function Test-Ip6RegOff {
    $v = Get-RegValue $Ip6Key 'DisabledComponents'
    if ($null -eq $v) { return $false }
    return (([int64]$v -band 0xFF) -eq 0xFF)
}

# IPv6 还关着的网卡（名字）；没有这组命令或都开了则返回空。
function Get-Ip6OffAdapters {
    try {
        return @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop |
            Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    } catch { return @() }
}

# 打开 IPv6：在每块网卡上重新勾上「Internet 协议版本 6」（马上生效），
# 再删掉系统级开关 DisabledComponents（重启后生效）。
function Set-Ip6On {
    if (-not $script:DoIp6) { return }
    Write-Log '准备打开系统 IPv6…'
    if ($DryRun) {
        Write-Log '（演练）在所有网卡上重新勾上「Internet 协议版本 6 (TCP/IPv6)」，并删除系统级开关 DisabledComponents（重启后生效）'
        return
    }
    $results = @(
        (Invoke-Methods '打开各网卡上的 IPv6' { @(Get-Ip6OffAdapters).Count -eq 0 } @(
            { Enable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -ErrorAction Stop },
            {
                # 整批开有网卡报错时，逐块网卡再开一遍。
                foreach ($n in @(Get-Ip6OffAdapters)) {
                    try { Enable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction Stop } catch { }
                }
            }
        )),
        (Invoke-Methods '打开 IPv6 的系统级开关' { -not (Test-Ip6RegOff) } @(
            { Remove-ItemProperty -Path $Ip6Key -Name DisabledComponents -ErrorAction Stop },
            { Invoke-Native { reg.exe delete 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' /v DisabledComponents /f } },
            { Set-ItemProperty -Path $Ip6Key -Name DisabledComponents -Value 0 -Type DWord -ErrorAction Stop }
        ))
    )
    if ($results -notcontains $false) { Write-Log '系统 IPv6 已打开（各网卡马上生效；系统级开关重启后生效）。' }
}

# ----------------------------------------------------------------- 主流程

# 状态里的一行：已还原的绿色，还没还原的红色并计数。
function Write-StatusLine([string]$Mark, [string]$Text) {
    if ($Mark -eq '√') { Write-Host "  √ $Text" -ForegroundColor Green }
    else { Write-Host "  × $Text" -ForegroundColor Red; $script:StatusBad++ }
}

# 逐项显示当前状态，√ 表示已经是中国 / 中文的设置，× 表示还没还原。
function Show-Status {
    $script:StatusBad = 0
    $tz = (Get-TimeZone).Id
    $tzMark = if ($tz -eq $TargetTz) { '√' } else { '×' }
    Write-StatusLine $tzMark "时区：$tz（目标 $TargetTz，即 $TargetTzName）"
    $lang = Get-CurrentLang
    $langMark = if (Test-LangOk) { '√' } else { '×' }
    Write-StatusLine $langMark "系统语言：$lang（目标 简体中文）"
    $locOff = @(Get-LocOffParts)
    if ($locOff.Count -eq 0) { Write-StatusLine '√' '系统定位：已打开' }
    else { Write-StatusLine '×' "系统定位：这些还关着：$($locOff -join '、')（目标 全部打开）" }
    $ip6Off = @(Get-Ip6OffAdapters)
    if ($ip6Off.Count -gt 0) { Write-StatusLine '×' "系统 IPv6：这些网卡还关着：$($ip6Off -join '、')（目标 打开）" }
    elseif (Test-Ip6RegOff) { Write-StatusLine '×' '系统 IPv6：各网卡已开，但系统级开关还是关的（目标 打开）' }
    else { Write-StatusLine '√' '系统 IPv6：已打开' }
    $cl = Get-ChromeLang
    if ($null -eq $cl) {
        Write-Host '  - Chrome：未检测到'
    } else {
        $clMark = if ($cl -eq 'zh-CN') { '√' } else { '×' }
        if (-not $cl) { $cl = '未设置，跟随系统' }
        Write-StatusLine $clMark "Chrome 语言：$cl（目标 zh-CN）"
        $geoOff = @(Get-ChromeGeoOffProfiles)
        if ($geoOff.Count -eq 0) { Write-StatusLine '√' 'Chrome 定位：没有被禁止' }
        else { Write-StatusLine '×' "Chrome 定位：这些个人资料还是「禁止」：$($geoOff -join '、')（目标 网站可以询问）" }
    }
}

# 执行后逐项核对「选中的项目」有没有真的还原；没还原的记为未通过。
function Show-Verify([bool]$WantChrome, [bool]$WantTz, [bool]$WantLang, [bool]$WantLoc, [bool]$WantIp6) {
    $failed = 0
    if ($WantTz) {
        if (Test-TzOk) { Add-Ok "时区：$(Get-CurrentTz)（$TargetTzName）" }
        else { Add-Bad "时区：当前是 $(Get-CurrentTz)，目标 $TargetTz"; $failed++ }
    }
    if ($WantLang) {
        $bad = @()
        if (-not (Test-LangOk)) { $bad += '语言列表' }
        if (-not (Test-UiLangOk)) { $bad += '显示语言' }
        if ((Get-RegValue 'HKCU:\Control Panel\International' 'LocaleName') -ne 'zh-CN') { $bad += '区域格式' }
        if ((Get-WinHomeLocation).GeoId -ne $TargetGeoId) { $bad += '国家或地区' }
        if (-not (Test-SystemLocaleOk)) { $bad += '系统区域设置' }
        if ($bad.Count -eq 0) { Add-Ok '系统语言 / 区域：简体中文（中国），输入法已加回微软拼音（注销或重启后完全生效）' }
        else { Add-Bad "系统语言 / 区域：这些还不是中文：$($bad -join '、')"; $failed++ }
        if ((Test-ZhPackInstalled) -eq $false) {
            Add-Bad '中文显示语言包：系统里没有，界面文字会继续显示英文；请到 设置 > 时间和语言 > 语言和区域 添加「中文(简体，中国)」'
            $failed++
        }
    }
    if ($WantLoc) {
        $bad = @(Get-LocOffParts)
        if ($bad.Count -eq 0) { Add-Ok '系统定位：定位服务已打开' }
        else { Add-Bad "系统定位：这些还关着：$($bad -join '、')"; $failed++ }
    }
    if ($WantIp6) {
        $ip6Off = @(Get-Ip6OffAdapters)
        if ($ip6Off.Count -gt 0) { Add-Bad "系统 IPv6：这些网卡还关着：$($ip6Off -join '、')"; $failed++ }
        elseif (Test-Ip6RegOff) { Add-Bad '系统 IPv6：系统级开关（DisabledComponents）没改回来'; $failed++ }
        else { Add-Ok '系统 IPv6：已打开（各网卡马上生效；系统级开关重启后生效）' }
    }
    if ($WantChrome) {
        if (-not (Test-Path -LiteralPath $ChromeData)) {
            Add-Info 'Chrome：这台电脑没有装 Chrome，无需处理'
        } else {
            $geoOff = @(Get-ChromeGeoOffProfiles)
            if ((Get-ChromeLang) -ne 'zh-CN') {
                Add-Bad "Chrome 语言：当前是 $(Get-ChromeLang)，目标 zh-CN"; $failed++
            } elseif ($geoOff.Count -gt 0) {
                Add-Bad "Chrome 定位：这些个人资料还是「禁止」：$($geoOff -join '、')"; $failed++
            } else {
                Add-Ok 'Chrome：语言 zh-CN，定位已恢复为「网站可以询问」'
            }
        }
    }
    return $failed
}

function Invoke-Pipeline {
    if (-not ($script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:DoLoc -or $script:DoIp6)) {
        Write-Host '请至少选择一个执行项目。'; return
    }
    $script:BackupDir = Join-Path $DataDir ('restore-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($DryRun) { Write-Log '演练模式：只显示将要做的事，不做任何修改。' }
    # 记下用户选了什么，最后按这个逐项核对。
    $wantChrome = $script:DoChrome; $wantTz = $script:DoTz; $wantLang = $script:DoLang
    $wantLoc = $script:DoLoc; $wantIp6 = $script:DoIp6

    Set-TargetTimezone
    Set-TargetLanguage
    Set-LocationOn
    Set-Ip6On
    Restore-Chrome

    if ($DryRun) {
        Write-Skip '演练结束，没有做任何修改。'
        return
    }
    $failed = Show-Verify $wantChrome $wantTz $wantLang $wantLoc $wantIp6
    $script:Errors += $failed
    if ($wantLang) { Add-Info '提示：语言和输入法设置需要注销或重启 Windows 后才完全生效' }
    if ($wantIp6) { Add-Info '提示：IPv6 的系统级开关需要重启 Windows 后才完全生效' }
}

function Show-Menu {
    while ($true) {
        $script:DoChrome = $false; $script:DoTz = $false; $script:DoLang = $false
        $script:DoLoc = $false; $script:DoIp6 = $false; $script:Errors = 0
        $script:Results.Clear(); $script:OkCount = 0; $script:BadCount = 0

        Write-Host ''
        Write-Host "================ 小川环境还原助手 $Version（Windows）================"
        Show-Status
        Write-Host ''
        Write-Host '  1) Chrome 语言改回 zh-CN，并恢复 Chrome 定位（网站可以询问）'
        Write-Host "  2) 时区改回 $TargetTzName（北京时间）"
        Write-Host '  3) 系统语言 / 区域改回简体中文（中国），加回微软拼音输入法'
        Write-Host '  4) 打开系统定位服务'
        Write-Host '  5) 打开系统 IPv6'
        Write-Host '  a) 一键执行 1 2 3 4 5（推荐）'
        Write-Host '  q) 退出'
        Write-Host ''
        $choices = Read-Host '请输入要执行的项目（可多选，用空格分开，例如 2 3），然后按回车'
        $picked = $false; $bad = $false
        foreach ($c in ($choices -split '[\s,]+' | Where-Object { $_ })) {
            if ($c -eq '1') { $script:DoChrome = $true; $picked = $true }
            elseif ($c -eq '2') { $script:DoTz = $true; $picked = $true }
            elseif ($c -eq '3') { $script:DoLang = $true; $picked = $true }
            elseif ($c -eq '4') { $script:DoLoc = $true; $picked = $true }
            elseif ($c -eq '5') { $script:DoIp6 = $true; $picked = $true }
            elseif ($c -eq 'a') { $script:DoChrome = $true; $script:DoTz = $true; $script:DoLang = $true; $script:DoLoc = $true; $script:DoIp6 = $true; $picked = $true }
            elseif ($c -eq 'q') { return }
            else { Write-Host "看不懂的选项：$c"; $bad = $true; break }
        }
        if (-not $bad) {
            if (-not $picked) { continue }
            Invoke-Pipeline
            Show-Result
        }

        Write-Host ''
        if ((Read-Host '按回车返回菜单（输入 q 退出）') -eq 'q') { return }
    }
}

function Show-Usage {
    Write-Host @"
小川环境还原助手 $Version（Windows 脚本版）
把 xiaochuan-env 改过的设置还原成中国 / 中文。

用法：
  双击 xiaochuan-restore.bat                 交互菜单
  xiaochuan-restore.bat -All                 直接执行：Chrome + 时区 + 语言 + 开定位 + 开 IPv6
  xiaochuan-restore.bat -All -DryRun         演练，只显示将要做的事
  xiaochuan-restore.bat status               检查当前状态（时区 / 语言 / 定位 / IPv6 / Chrome 是否已还原）

选项：
  -Chrome      Chrome 语言改回 zh-CN，并恢复 Chrome 定位（网站可以询问）
  -Timezone    时区改回 $TargetTzName（中国标准时间）
  -Language    系统语言 / 区域改回简体中文（中国），加回微软拼音输入法
  -Location    打开系统定位服务
  -IPv6        打开系统 IPv6（各网卡马上生效，系统级开关重启后生效）
  -All         等于 -Chrome -Timezone -Language -Location -IPv6
  -DryRun      演练：只显示将要做的事，不做任何修改

脚本会自己弹出 UAC 申请管理员权限，不需要手动「以管理员身份运行」。
"@
}

# ------------------------------------------------------------------- 入口

if ($Help) { Show-Usage; exit 0 }

if ($All) { $Chrome = $true; $Timezone = $true; $Language = $true; $Location = $true; $IPv6 = $true }
$script:DoChrome = [bool]$Chrome
$script:DoTz = [bool]$Timezone
$script:DoLang = [bool]$Language
$script:DoLoc = [bool]$Location
$script:DoIp6 = [bool]$IPv6
$anySelected = ($script:DoChrome -or $script:DoTz -or $script:DoLang -or $script:DoLoc -or $script:DoIp6)

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

# 用别的管理员账户通过 UAC 提权时，语言和 Chrome 会改到那个账户上，而不是当前登录的用户。
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
        Write-Host "小川环境还原助手 $Version（Windows）"
        Show-Status
        Write-Host '=========================================='
        if ($script:StatusBad -eq 0) {
            Write-Host ' 结果：时区、语言、定位、IPv6 都已还原 ' -ForegroundColor White -BackgroundColor DarkGreen
        } else {
            Write-Host " 结果：有 $($script:StatusBad) 项还没还原（上面标 × 的红色行） " -ForegroundColor White -BackgroundColor Red
            $script:Errors += $script:StatusBad
        }
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

# 提权后是新开的窗口，结束前停一下，免得结果一闪而过。
if ($Elevated -and ($Action -or $anySelected -or $script:Errors)) {
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
}
if ($script:Errors -gt 0) { exit 1 }
exit 0
