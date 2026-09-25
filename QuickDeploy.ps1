<#
.SYNOPSIS
    QuickDeploy — כלי הקמת מחשב חדש ל-Windows 10/11 (PowerShell + WPF).

.DESCRIPTION
    כלי יחיד (קובץ אחד) להקמת מחשב חדש: התקנת תוכנות דרך winget, ניקוי אפליקציות מובנות,
    הגדרות מערכת, רשת, כוננים ממופים, מדפסות, שינוי שם מחשב והצטרפות לדומיין/קבוצת עבודה.
    כולל ממשק גרפי בעברית (RTL), מצב סימולציה, מצב שקט (CLI), יומן ודוח HTML.

.PARAMETER ProfileName
    שם הפרופיל לטעינה (ניתן גם כ- -Profile).

.PARAMETER ComputerName
    שם מחשב חדש (אופציונלי). לעולם אינו נשמר בפרופיל.

.PARAMETER Silent
    הרצה ללא ממשק. קוד יציאה: 0 = הכל תקין, 1 = חלק מהפעולות נכשלו, 2 = שגיאה קריטית.

.PARAMETER Simulate
    מצב סימולציה — שום שינוי לא מתבצע במערכת, כל פעולה נרשמת כ-[SIM].

.PARAMETER NoReboot
    לא לבצע הפעלה מחדש בסיום (גם אם נדרשת).

.EXAMPLE
    .\QuickDeploy.ps1

.EXAMPLE
    .\QuickDeploy.ps1 -Profile "משרד" -ComputerName "PC-01" -Silent -Simulate
#>
[CmdletBinding()]
param(
    [Alias('Profile')]
    [string]$ProfileName = '',

    [string]$ComputerName = '',

    [switch]$Silent,

    [switch]$Simulate,

    [switch]$NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region Bootstrap — elevation, STA, edition

function Test-QDIsAdmin {
    <#
    .SYNOPSIS
        בודק האם התהליך הנוכחי רץ בהרשאות מנהל.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-QDArgumentString {
    <#
    .SYNOPSIS
        עוטף ערך במירכאות לשורת פקודה של Windows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '"', '\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-QDRelaunchArgument {
    <#
    .SYNOPSIS
        בונה את שורת הארגומנטים להפעלה מחדש של הסקריפט (מוגבה / STA).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{}
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File')) { $parts.Add($p) }
    $parts.Add((ConvertTo-QDArgumentString -Value $ScriptPath))
    foreach ($key in @('ProfileName', 'ComputerName')) {
        if ($BoundParameters.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$BoundParameters[$key])) {
            $parts.Add("-$key")
            $parts.Add((ConvertTo-QDArgumentString -Value ([string]$BoundParameters[$key])))
        }
    }
    foreach ($key in @('Silent', 'Simulate', 'NoReboot')) {
        if ($BoundParameters.ContainsKey($key) -and [bool]$BoundParameters[$key]) { $parts.Add("-$key") }
    }
    return ($parts -join ' ')
}

$script:IsAdmin = Test-QDIsAdmin
$script:IsSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
$script:IsDesktopEdition = $PSVersionTable.PSEdition -ne 'Core'

if ((-not $script:IsAdmin) -or (-not $script:IsDesktopEdition) -or ((-not $Silent) -and (-not $script:IsSta))) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'QuickDeploy: יש להריץ את הסקריפט מקובץ שמור (QuickDeploy.cmd).' -ForegroundColor Red
        exit 2
    }
    $bound = @{}
    foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
    $argLine = Get-QDRelaunchArgument -ScriptPath $PSCommandPath -BoundParameters $bound
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $startArgs = @{ FilePath = $psExe; ArgumentList = $argLine; PassThru = $true; ErrorAction = 'Stop' }
        if (-not $script:IsAdmin) { $startArgs['Verb'] = 'RunAs' }
        if ($Silent) { $startArgs['Wait'] = $true }
        $child = Start-Process @startArgs
        if ($Silent -and $null -ne $child) { exit $child.ExitCode }
        exit 0
    }
    catch {
        Write-Host ('QuickDeploy: לא ניתן להפעיל בהרשאות מנהל — ' + $_.Exception.Message) -ForegroundColor Red
        exit 2
    }
}

# Windows PowerShell 5.1: prevent arrays from serialising as {"value":[],"Count":n}
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'No console attached.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

#endregion Bootstrap

#region Configuration & catalog data

$script:QD = @{}
$QD = $script:QD
$QD.Version = '1.0.0'
$QD.Root = Join-Path $env:ProgramData 'QuickDeploy'
$QD.ProfilesDir = Join-Path $QD.Root 'Profiles'
$QD.LogsDir = Join-Path $QD.Root 'Logs'
$QD.ReportsDir = Join-Path $QD.Root 'Reports'
$QD.SessionStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$QD.LogPath = Join-Path $QD.LogsDir ('QuickDeploy_{0}_{1}.log' -f $env:COMPUTERNAME, $QD.SessionStamp)
$QD.TranscriptPath = Join-Path $QD.LogsDir ('QuickDeploy_{0}_{1}_transcript.log' -f $env:COMPUTERNAME, $QD.SessionStamp)
$QD.DefaultHiveName = 'QD_Default'
$QD.WingetNotFoundCode = -1978335212
$QD.HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$QD.BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'

# Software catalog: category → display name → winget ID
$QD.Catalog = @(
    @{ Category = 'דפדפנים'; Name = 'Google Chrome'; Id = 'Google.Chrome'; Source = 'winget' }
    @{ Category = 'דפדפנים'; Name = 'Firefox'; Id = 'Mozilla.Firefox'; Source = 'winget' }
    @{ Category = 'דפדפנים'; Name = 'Brave'; Id = 'Brave.Brave'; Source = 'winget' }
    @{ Category = 'כלים'; Name = '7-Zip'; Id = '7zip.7zip'; Source = 'winget' }
    @{ Category = 'כלים'; Name = 'Notepad++'; Id = 'Notepad++.Notepad++'; Source = 'winget' }
    @{ Category = 'כלים'; Name = 'Everything'; Id = 'voidtools.Everything'; Source = 'winget' }
    @{ Category = 'כלים'; Name = 'PowerToys'; Id = 'Microsoft.PowerToys'; Source = 'winget' }
    @{ Category = 'משרד ומסמכים'; Name = 'Microsoft 365 Apps'; Id = 'Microsoft.Office'; Source = 'winget' }
    @{ Category = 'משרד ומסמכים'; Name = 'Adobe Acrobat Reader'; Id = 'Adobe.Acrobat.Reader.64-bit'; Source = 'winget' }
    @{ Category = 'תקשורת'; Name = 'Zoom'; Id = 'Zoom.Zoom'; Source = 'winget' }
    @{ Category = 'תקשורת'; Name = 'Microsoft Teams'; Id = 'Microsoft.Teams'; Source = 'winget' }
    @{ Category = 'תקשורת'; Name = 'WhatsApp'; Id = '9NKSQGP7F2NH'; Source = 'msstore' }
    @{ Category = 'תקשורת'; Name = 'Telegram'; Id = 'Telegram.TelegramDesktop'; Source = 'winget' }
    @{ Category = 'תמיכה מרחוק'; Name = 'AnyDesk'; Id = 'AnyDesk.AnyDesk'; Source = 'winget' }
    @{ Category = 'תמיכה מרחוק'; Name = 'TeamViewer'; Id = 'TeamViewer.TeamViewer'; Source = 'winget' }
    @{ Category = 'מדיה'; Name = 'VLC'; Id = 'VideoLAN.VLC'; Source = 'winget' }
    @{ Category = 'מדיה'; Name = 'Spotify'; Id = 'Spotify.Spotify'; Source = 'winget' }
    @{ Category = 'ספריות הרצה'; Name = 'VC++ 2015-2022 x64'; Id = 'Microsoft.VCRedist.2015+.x64'; Source = 'winget' }
    @{ Category = 'ספריות הרצה'; Name = '.NET Desktop Runtime 8'; Id = 'Microsoft.DotNet.DesktopRuntime.8'; Source = 'winget' }
    @{ Category = 'ספריות הרצה'; Name = 'Java'; Id = 'Oracle.JavaRuntimeEnvironment'; Source = 'winget' }
    @{ Category = 'גיימינג'; Name = 'Steam'; Id = 'Valve.Steam'; Source = 'winget' }
    @{ Category = 'גיימינג'; Name = 'Discord'; Id = 'Discord.Discord'; Source = 'winget' }
    @{ Category = 'גיימינג'; Name = 'Epic Games'; Id = 'EpicGames.EpicGamesLauncher'; Source = 'winget' }
    @{ Category = 'פיתוח'; Name = 'VS Code'; Id = 'Microsoft.VisualStudioCode'; Source = 'winget' }
    @{ Category = 'פיתוח'; Name = 'Git'; Id = 'Git.Git'; Source = 'winget' }
)
$QD.CategoryOrder = @('דפדפנים', 'כלים', 'משרד ומסמכים', 'תקשורת', 'תמיכה מרחוק', 'מדיה', 'ספריות הרצה', 'גיימינג', 'פיתוח')

# Debloat list — Group 'xbox' items are kept (OFF) in the gaming profile
$QD.Debloat = @(
    @{ Name = 'Microsoft.BingNews'; Label = 'חדשות (Bing News)'; Group = 'general' }
    @{ Name = 'Microsoft.BingWeather'; Label = 'מזג אוויר (Bing Weather)'; Group = 'general' }
    @{ Name = 'Microsoft.GetHelp'; Label = 'קבל עזרה'; Group = 'general' }
    @{ Name = 'Microsoft.Getstarted'; Label = 'טיפים / תחילת העבודה'; Group = 'general' }
    @{ Name = 'Microsoft.MicrosoftSolitaireCollection'; Label = 'Solitaire Collection'; Group = 'general' }
    @{ Name = 'Microsoft.People'; Label = 'אנשים (People)'; Group = 'general' }
    @{ Name = 'Microsoft.WindowsFeedbackHub'; Label = 'Feedback Hub'; Group = 'general' }
    @{ Name = 'Microsoft.ZuneMusic'; Label = 'Groove / Media Player (Zune Music)'; Group = 'general' }
    @{ Name = 'Microsoft.ZuneVideo'; Label = 'סרטים וטלוויזיה (Zune Video)'; Group = 'general' }
    @{ Name = 'Microsoft.MicrosoftOfficeHub'; Label = 'Office Hub / Microsoft 365 (אפליקציה)'; Group = 'general' }
    @{ Name = 'Microsoft.SkypeApp'; Label = 'Skype'; Group = 'general' }
    @{ Name = 'Clipchamp.Clipchamp'; Label = 'Clipchamp'; Group = 'general' }
    @{ Name = 'Microsoft.Todos'; Label = 'Microsoft To Do'; Group = 'general' }
    @{ Name = 'MicrosoftTeams'; Label = 'Teams לצרכן (לא Teams לעבודה)'; Group = 'general' }
    @{ Name = 'Microsoft.549981C3F5F10'; Label = 'Cortana'; Group = 'general' }
    @{ Name = '*CandyCrush*'; Label = 'Candy Crush'; Group = 'general' }
    @{ Name = '*Disney*'; Label = 'Disney+'; Group = 'general' }
    @{ Name = '*TikTok*'; Label = 'TikTok'; Group = 'general' }
    @{ Name = '*Facebook*'; Label = 'Facebook'; Group = 'general' }
    @{ Name = '*Instagram*'; Label = 'Instagram'; Group = 'general' }
    @{ Name = 'Microsoft.XboxApp'; Label = 'Xbox Console Companion'; Group = 'xbox' }
    @{ Name = 'Microsoft.GamingApp'; Label = 'Xbox (Gaming App)'; Group = 'xbox' }
    @{ Name = 'Microsoft.XboxGamingOverlay'; Label = 'Xbox Game Bar'; Group = 'xbox' }
    @{ Name = 'Microsoft.XboxGameOverlay'; Label = 'Xbox Game Overlay'; Group = 'xbox' }
    @{ Name = 'Microsoft.XboxSpeechToTextOverlay'; Label = 'Xbox Speech To Text'; Group = 'xbox' }
    @{ Name = 'Microsoft.Xbox.TCUI'; Label = 'Xbox TCUI'; Group = 'xbox' }
)

# Protected packages — never removed, even when matched by a wildcard
$QD.Protected = @(
    'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsCalculator',
    'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal',
    'Microsoft.SecHealthUI', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.StorePurchaseApp',
    'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET*', 'MSTeams'
)

# Pipeline steps (fixed order)
$QD.StepDefinitions = @(
    @{ Id = 'preflight'; Title = 'בדיקות מקדימות'; Icon = 'IconCheck'; Weight = 3 }
    @{ Id = 'restore'; Title = 'נקודת שחזור'; Icon = 'IconShield'; Weight = 5 }
    @{ Id = 'debloat'; Title = 'ניקוי תוכנות'; Icon = 'IconBroom'; Weight = 10 }
    @{ Id = 'system'; Title = 'הגדרות מערכת'; Icon = 'IconGear'; Weight = 10 }
    @{ Id = 'apps'; Title = 'התקנת תוכנות'; Icon = 'IconPackage'; Weight = 45 }
    @{ Id = 'network'; Title = 'רשת, כוננים ומדפסות'; Icon = 'IconNetwork'; Weight = 12 }
    @{ Id = 'identity'; Title = 'שם מחשב ודומיין'; Icon = 'IconMonitor'; Weight = 10 }
    @{ Id = 'report'; Title = 'דוח סיכום'; Icon = 'IconReport'; Weight = 5 }
)

$QD.StatusText = @{
    Pending     = 'ממתין'
    Running     = 'רץ'
    Success     = 'הצליח'
    Warning     = 'הצליח עם אזהרות'
    Partial     = 'הושלם חלקית'
    Failed      = 'נכשל'
    Skipped     = 'דולג'
    Cancelled   = 'בוטל'
    AlreadyDone = 'כבר קיים'
    Simulated   = 'סימולציה'
    Info        = 'מידע'
}

$QD.StatusColor = @{
    Pending     = '#8A93A3'
    Running     = '#F5A524'
    Success     = '#2DD4BF'
    Warning     = '#FBBF24'
    Partial     = '#FBBF24'
    Failed      = '#F87171'
    Skipped     = '#8A93A3'
    Cancelled   = '#8A93A3'
    AlreadyDone = '#2DD4BF'
    Simulated   = '#F5A524'
    Info        = '#8A93A3'
}

# Shared, thread-safe state between the UI thread and background runspaces
$script:Sync = [hashtable]::Synchronized(@{
        LogPath        = $QD.LogPath
        LogQueue       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        LogLock        = New-Object System.Object
        Silent         = [bool]$Silent
        Simulate       = [bool]$Simulate
        Cancel         = $false
        Running        = $false
        Done           = $false
        Dispatcher     = $null
        Pump           = $null
        LastPump       = [datetime]::MinValue
        Steps          = $null
        StepIndex      = 0
        SubProgress    = 0.0
        Progress       = 0.0
        Activity       = ''
        RebootRequired = $false
        RebootReasons  = New-Object System.Collections.ArrayList
        ReportPath     = ''
        Config         = $null
        Secrets        = @{}
        RunStart       = $null
        RunEnd         = $null
        ExitCode       = 0
        UserRoots      = @()
        DefaultHiveLoaded = $false
        WingetPath     = ''
        CatalogStatus  = [hashtable]::Synchronized(@{})
        CatalogVersion = 0
        SysInfo        = $null
        SysInfoState   = 'idle'
        PrinterDrivers = @()
        SearchState    = 'idle'
        SearchResults  = @()
        SearchError    = ''
        FatalError     = ''
    })
$Sync = $script:Sync

#endregion Configuration & catalog data


#region Logging & core helpers

function Initialize-QDFolder {
    <#
    .SYNOPSIS
        יוצר את תיקיות העבודה תחת ProgramData בהרצה הראשונה.
    #>
    [CmdletBinding()]
    param()
    foreach ($dir in @($QD.Root, $QD.ProfilesDir, $QD.LogsDir, $QD.ReportsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    }
}

function Write-QDLog {
    <#
    .SYNOPSIS
        כותב שורה ליומן (קובץ + תור הממשק + מסוף במצב שקט).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'SIM', 'STEP')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    [System.Threading.Monitor]::Enter($Sync.LogLock)
    try {
        [System.IO.File]::AppendAllText($Sync.LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
    }
    catch {
        Write-Verbose ('Log write failed: ' + $_.Exception.Message)
    }
    finally {
        [System.Threading.Monitor]::Exit($Sync.LogLock)
    }
    if ($Sync.Silent) {
        $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SIM' { 'Cyan' } 'STEP' { 'Magenta' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
    else {
        $Sync.LogQueue.Enqueue($line)
        Send-QDPump
    }
}

function Send-QDPump {
    <#
    .SYNOPSIS
        מבקש מתהליכון הממשק לרענן את התצוגה (Dispatcher.Invoke), עם ויסות קצב.
    #>
    [CmdletBinding()]
    param([switch]$Force)
    if ($null -eq $Sync.Dispatcher -or $null -eq $Sync.Pump) { return }
    if ($Sync.Dispatcher.CheckAccess()) { return }
    $now = [datetime]::UtcNow
    if (-not $Force -and ($now - $Sync.LastPump).TotalMilliseconds -lt 120) { return }
    $Sync.LastPump = $now
    try {
        $Sync.Dispatcher.Invoke($Sync.Pump, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    catch {
        Write-Verbose ('Pump failed: ' + $_.Exception.Message)
    }
}

function Test-QDCancel {
    <#
    .SYNOPSIS
        מחזיר $true אם המשתמש ביקש ביטול.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$Sync.Cancel
}

function Invoke-QDAction {
    <#
    .SYNOPSIS
        עוטף כל פעולה שמשנה את המערכת. במצב סימולציה רק רושם [SIM] ולא מבצע דבר.
    .PARAMETER Description
        תיאור הפעולה ליומן.
    .PARAMETER ScriptBlock
        הפעולה עצמה.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    if ($Sync.Simulate) {
        Write-QDLog -Message ('[SIM] would ' + $Description) -Level 'SIM'
        return
    }
    Write-QDLog -Message $Description
    & $ScriptBlock
}

function Invoke-QDNative {
    <#
    .SYNOPSIS
        מריץ קובץ הרצה חיצוני ומחזיר קוד יציאה ופלט (ללא זריקת שגיאה על stderr).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]
    $exit = -1
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            foreach ($part in ([string]$_ -split "[`r`n]+")) {
                $clean = $part.Trim()
                if ($clean.Length -eq 0) { continue }
                if ($clean -match '^[\-\\\|/\s]+$') { continue }
                if ($clean -match '[▀-▟]') { continue }
                $lines.Add($clean)
            }
        }
        $exit = $LASTEXITCODE
    }
    catch {
        $lines.Add($_.Exception.Message)
    }
    if ($null -eq $exit) { $exit = 0 }
    return @{ ExitCode = [int]$exit; Output = $lines.ToArray(); Text = ($lines -join [Environment]::NewLine) }
}

function Invoke-QDNativeAction {
    <#
    .SYNOPSIS
        מריץ פקודה חיצונית שמשנה את המערכת דרך Invoke-QDAction וזורק שגיאה על קוד יציאה שגוי.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0)
    )
    $desc = 'run: {0} {1}' -f (Split-Path -Leaf $FilePath), ($ArgumentList -join ' ')
    $result = Invoke-QDAction -Description $desc -ScriptBlock { Invoke-QDNative -FilePath $FilePath -ArgumentList $ArgumentList }
    if ($null -eq $result) { return }
    foreach ($l in $result.Output) { Write-QDLog -Message ('    ' + $l) }
    if ($SuccessCodes -notcontains $result.ExitCode) {
        throw ('{0} נכשל (קוד {1}): {2}' -f (Split-Path -Leaf $FilePath), $result.ExitCode, (($result.Output | Select-Object -Last 3) -join ' | '))
    }
    return $result
}

function Get-QDProp {
    <#
    .SYNOPSIS
        קורא מאפיין מאובייקט JSON / מילון בבטחה (תואם StrictMode).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function ConvertTo-QDBool {
    <#
    .SYNOPSIS
        ממיר ערך כלשהו ל-bool עם ברירת מחדל.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('true', '1', 'yes', 'on')) { return $true }
    if ($s -in @('false', '0', 'no', 'off')) { return $false }
    return $Default
}

function Test-QDComputerName {
    <#
    .SYNOPSIS
        מאמת שם מחשב: עד 15 תווים, A-Z a-z 0-9 -, לא ספרות בלבד. מחזיר הודעת שגיאה או מחרוזת ריקה.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name.Length -gt 15) { return 'שם המחשב ארוך מ-15 תווים' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'מותרים רק אותיות באנגלית, ספרות ומקף' }
    if ($Name -match '^[0-9]+$') { return 'השם אינו יכול להכיל ספרות בלבד' }
    if ($Name -match '^-|-$') { return 'השם אינו יכול להתחיל או להסתיים במקף' }
    return ''
}

function Test-QDIPv4 {
    <#
    .SYNOPSIS
        בודק שמחרוזת היא כתובת IPv4 תקינה.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Address)
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in ($Address -split '\.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

function Test-QDUncPath {
    <#
    .SYNOPSIS
        בודק שמחרוזת היא נתיב UNC בסיסי (\\server\share).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Path)
    return ($Path -match '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(\\.*)?$')
}

function ConvertTo-QDHtml {
    <#
    .SYNOPSIS
        קידוד HTML בטוח.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

#endregion Logging & core helpers

#region Profiles

function Get-QDDefaultProfile {
    <#
    .SYNOPSIS
        מחזיר פרופיל ריק עם כל ערכי ברירת המחדל לפי הסכמה (schemaVersion 1).
    #>
    [CmdletBinding()]
    param()
    $pkgs = @($QD.Debloat | ForEach-Object { $_.Name })
    return [ordered]@{
        schemaVersion = 1
        name          = 'פרופיל חדש'
        description   = ''
        apps          = @()
        customApps    = @()
        debloat       = [ordered]@{
            packages         = $pkgs
            consumerFeatures = $true
            ads              = $true
            bingSearch       = $true
            copilot          = $false
            oneDrive         = $false
        }
        system        = [ordered]@{
            timezone           = $true
            hebrewKeyboard     = $true
            powerPlan          = 'balanced'
            disableHibernation = $false
            disableFastStartup = $true
            showExtensions     = $true
            showHidden         = $false
            explorerThisPC     = $true
            taskbarLeft        = $false
            classicContextMenu = $false
            enableRdp          = $false
            createLocalAdmin   = $false
            windowsUpdateScan  = $true
        }
        network       = [ordered]@{
            joinType  = 'none'
            workgroup = ''
            domain    = ''
            ou        = ''
            drives    = @()
            wifi      = @()
            printers  = @()
        }
    }
}

function ConvertTo-QDProfile {
    <#
    .SYNOPSIS
        מנרמל אובייקט פרופיל (מ-JSON או מילון): מפתחות לא מוכרים נזנחים, מפתחות חסרים מקבלים ברירת מחדל.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$InputObject)
    if ($null -eq $InputObject) { throw 'קובץ הפרופיל ריק' }
    $p = Get-QDDefaultProfile
    $knownApps = @($QD.Catalog | ForEach-Object { $_.Id })
    $knownPkgs = @($QD.Debloat | ForEach-Object { $_.Name })

    $name = [string](Get-QDProp $InputObject 'name' '')
    if (-not [string]::IsNullOrWhiteSpace($name)) { $p.name = $name.Trim() }
    $p.description = [string](Get-QDProp $InputObject 'description' '')

    $p.apps = @(@(Get-QDProp $InputObject 'apps' @()) | Where-Object { $_ -is [string] -and $knownApps -contains $_ } | Select-Object -Unique)

    $customs = New-Object System.Collections.ArrayList
    foreach ($c in @(Get-QDProp $InputObject 'customApps' @())) {
        $cid = [string](Get-QDProp $c 'id' '')
        if ($cid -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]{1,127}$') { continue }
        if ($knownApps -contains $cid) { continue }
        $src = [string](Get-QDProp $c 'source' 'winget')
        if ($src -notin @('winget', 'msstore')) { $src = 'winget' }
        $cname = [string](Get-QDProp $c 'name' $cid)
        if ([string]::IsNullOrWhiteSpace($cname)) { $cname = $cid }
        [void]$customs.Add([ordered]@{ id = $cid; name = $cname; source = $src })
    }
    $p.customApps = @($customs)

    $d = Get-QDProp $InputObject 'debloat' $null
    if ($null -ne $d) {
        $p.debloat.packages = @(@(Get-QDProp $d 'packages' @()) | Where-Object { $_ -is [string] -and $knownPkgs -contains $_ } | Select-Object -Unique)
        foreach ($k in @('consumerFeatures', 'ads', 'bingSearch', 'copilot', 'oneDrive')) {
            $p.debloat[$k] = ConvertTo-QDBool (Get-QDProp $d $k $null) $p.debloat[$k]
        }
    }

    $s = Get-QDProp $InputObject 'system' $null
    if ($null -ne $s) {
        foreach ($k in @($p.system.Keys)) {
            if ($k -eq 'powerPlan') { continue }
            $p.system[$k] = ConvertTo-QDBool (Get-QDProp $s $k $null) $p.system[$k]
        }
        $plan = [string](Get-QDProp $s 'powerPlan' 'balanced')
        if ($plan -notin @('balanced', 'high')) { $plan = 'balanced' }
        $p.system.powerPlan = $plan
    }

    $n = Get-QDProp $InputObject 'network' $null
    if ($null -ne $n) {
        $jt = [string](Get-QDProp $n 'joinType' 'none')
        if ($jt -notin @('none', 'workgroup', 'domain')) { $jt = 'none' }
        $p.network.joinType = $jt
        $p.network.workgroup = ([string](Get-QDProp $n 'workgroup' '')).Trim()
        $p.network.domain = ([string](Get-QDProp $n 'domain' '')).Trim()
        $p.network.ou = ([string](Get-QDProp $n 'ou' '')).Trim()

        $drives = New-Object System.Collections.ArrayList
        foreach ($dr in @(Get-QDProp $n 'drives' @())) {
            $letter = ([string](Get-QDProp $dr 'letter' '')).Trim().TrimEnd(':').ToUpperInvariant()
            if ($letter -notmatch '^[A-Z]$') { continue }
            [void]$drives.Add([ordered]@{ letter = $letter; path = ([string](Get-QDProp $dr 'path' '')).Trim(); label = [string](Get-QDProp $dr 'label' '') })
        }
        $p.network.drives = @($drives)

        $wifi = New-Object System.Collections.ArrayList
        foreach ($w in @(Get-QDProp $n 'wifi' @())) {
            $ssid = [string](Get-QDProp $w 'ssid' '')
            if ([string]::IsNullOrWhiteSpace($ssid)) { continue }
            $sec = [string](Get-QDProp $w 'security' 'WPA2')
            if ($sec -notin @('WPA2', 'WPA3')) { $sec = 'WPA2' }
            [void]$wifi.Add([ordered]@{ ssid = $ssid; security = $sec })
        }
        $p.network.wifi = @($wifi)

        $printers = New-Object System.Collections.ArrayList
        foreach ($pr in @(Get-QDProp $n 'printers' @())) {
            $type = [string](Get-QDProp $pr 'type' 'ip')
            if ($type -notin @('ip', 'unc')) { $type = 'ip' }
            [void]$printers.Add([ordered]@{
                    type     = $type
                    name     = ([string](Get-QDProp $pr 'name' '')).Trim()
                    ip       = ([string](Get-QDProp $pr 'ip' '')).Trim()
                    path     = ([string](Get-QDProp $pr 'path' '')).Trim()
                    driver   = ([string](Get-QDProp $pr 'driver' '')).Trim()
                    default  = ConvertTo-QDBool (Get-QDProp $pr 'default' $false) $false
                    testPage = ConvertTo-QDBool (Get-QDProp $pr 'testPage' $false) $false
                })
        }
        $p.network.printers = @($printers)
    }
    return $p
}

function ConvertTo-QDProfileJson {
    <#
    .SYNOPSIS
        ממיר פרופיל מנורמל ל-JSON.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ProfileData, [switch]$Compress)
    return (ConvertTo-Json -InputObject $ProfileData -Depth 8 -Compress:$Compress)
}

function Get-QDProfileFileName {
    <#
    .SYNOPSIS
        מחזיר שם קובץ בטוח לפרופיל לפי שמו.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'profile' }
    return (Join-Path $QD.ProfilesDir ($safe + '.json'))
}

function Import-QDProfileFile {
    <#
    .SYNOPSIS
        קורא ומאמת קובץ פרופיל JSON. זורק שגיאה בעברית אם הקובץ אינו תקין.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "הקובץ לא נמצא: $Path" }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $obj = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        throw ('קובץ הפרופיל אינו JSON תקין: ' + (Split-Path -Leaf $Path))
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { throw 'מבנה הפרופיל אינו תקין' }
    $ver = Get-QDProp $obj 'schemaVersion' 1
    try { $verInt = [int]$ver } catch { $verInt = 1 }
    if ($verInt -gt 1) { Write-QDLog -Message ("הפרופיל נוצר בגרסת סכמה חדשה יותר ($verInt) — שדות לא מוכרים יזנחו") -Level 'WARN' }
    return (ConvertTo-QDProfile -InputObject $obj)
}

function Save-QDProfileFile {
    <#
    .SYNOPSIS
        שומר פרופיל לקובץ JSON (UTF-8). לעולם אינו שומר שם מחשב או סיסמאות.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileData, [string]$Path = '')
    $clean = ConvertTo-QDProfile -InputObject $ProfileData
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-QDProfileFileName -Name $clean.name }
    $json = ConvertTo-QDProfileJson -ProfileData $clean
    # UTF-8 without BOM — identical output on Windows PowerShell 5.1 and PowerShell 7
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
    return $Path
}

function Get-QDProfileList {
    <#
    .SYNOPSIS
        מחזיר רשימת פרופילים שמורים (שם תצוגה ונתיב).
    #>
    [CmdletBinding()]
    param()
    $list = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $QD.ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $display = $f.BaseName
        try {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $obj = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
            $n = [string](Get-QDProp $obj 'name' '')
            if (-not [string]::IsNullOrWhiteSpace($n)) { $display = $n.Trim() }
        }
        catch {
            $display = $f.BaseName + ' (פגום)'
        }
        [void]$list.Add([pscustomobject]@{ Name = $display; Path = $f.FullName })
    }
    return $list.ToArray()
}

function Find-QDProfile {
    <#
    .SYNOPSIS
        מאתר פרופיל לפי שם תצוגה או שם קובץ.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $all = @(Get-QDProfileList)
    $hit = $all | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $hit) { $hit = $all | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Path) -eq $Name } | Select-Object -First 1 }
    return $hit
}

function Initialize-QDBuiltInProfile {
    <#
    .SYNOPSIS
        יוצר את פרופילי ברירת המחדל (משרד, ביתי, גיימינג) אם הם חסרים.
    #>
    [CmdletBinding()]
    param()
    $allPkgs = @($QD.Debloat | ForEach-Object { $_.Name })
    $noXbox = @($QD.Debloat | Where-Object { $_.Group -ne 'xbox' } | ForEach-Object { $_.Name })

    $office = Get-QDDefaultProfile
    $office.name = 'משרד'
    $office.description = 'עמדת משרד: דפדפן, כלי משרד, תקשורת ותמיכה מרחוק. ניקוי מלא.'
    $office.apps = @('Google.Chrome', '7zip.7zip', 'Adobe.Acrobat.Reader.64-bit', 'Microsoft.Office', 'Zoom.Zoom', 'AnyDesk.AnyDesk', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.DotNet.DesktopRuntime.8')
    $office.debloat.packages = $allPkgs

    $homeProfile = Get-QDDefaultProfile
    $homeProfile.name = 'ביתי'
    $homeProfile.description = 'מחשב ביתי: דפדפן, מדיה, WhatsApp ו-Spotify.'
    $homeProfile.apps = @('Google.Chrome', '7zip.7zip', 'VideoLAN.VLC', '9NKSQGP7F2NH', 'Spotify.Spotify', 'Adobe.Acrobat.Reader.64-bit', 'Microsoft.VCRedist.2015+.x64')
    $homeProfile.debloat.packages = $allPkgs

    $gaming = Get-QDDefaultProfile
    $gaming.name = 'גיימינג'
    $gaming.description = 'מחשב גיימינג: חנויות משחקים, Discord, ביצועים גבוהים. אפליקציות Xbox נשמרות.'
    $gaming.apps = @('Google.Chrome', '7zip.7zip', 'Discord.Discord', 'Valve.Steam', 'EpicGames.EpicGamesLauncher', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.DotNet.DesktopRuntime.8')
    $gaming.debloat.packages = $noXbox
    $gaming.system.powerPlan = 'high'

    foreach ($prof in @($office, $homeProfile, $gaming)) {
        $path = Get-QDProfileFileName -Name $prof.name
        if (-not (Test-Path -LiteralPath $path)) {
            try {
                $null = Save-QDProfileFile -ProfileData $prof -Path $path
                Write-QDLog -Message ("נוצר פרופיל מובנה: " + $prof.name)
            }
            catch {
                Write-QDLog -Message ("שגיאה ביצירת פרופיל מובנה {0}: {1}" -f $prof.name, $_.Exception.Message) -Level 'ERROR'
            }
        }
    }
}

#endregion Profiles

#region System information

function Test-QDInternet {
    <#
    .SYNOPSIS
        בודק חיבור לאינטרנט. -Thorough משתמש ב-Test-NetConnection (איטי יותר) עם גיבוי DNS.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Thorough)
    if ($Thorough -and (Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue)) {
        try {
            $probeHost = '8.8.8.8'
            if (Test-NetConnection -ComputerName $probeHost -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop) { return $true }
        }
        catch { Write-Verbose $_.Exception.Message }
    }
    else {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync('8.8.8.8', 53)
            if ($task.Wait(1500) -and $client.Connected) { return $true }
        }
        catch { Write-Verbose $_.Exception.Message }
        finally { $client.Dispose() }
    }
    try {
        $addr = [System.Net.Dns]::GetHostAddresses('www.microsoft.com')
        return (@($addr).Count -gt 0)
    }
    catch { return $false }
}

function Get-QDPowerSource {
    <#
    .SYNOPSIS
        מחזיר מצב סוללה/חשמל: HasBattery, OnBattery, Charge.
    #>
    [CmdletBinding()]
    param()
    $result = @{ HasBattery = $false; OnBattery = $false; Charge = $null }
    try {
        $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($bat.Count -gt 0) {
            $result.HasBattery = $true
            $result.Charge = $bat[0].EstimatedChargeRemaining
            # BatteryStatus 1 = discharging (on battery)
            $result.OnBattery = ([int]$bat[0].BatteryStatus -eq 1)
        }
    }
    catch { Write-Verbose $_.Exception.Message }
    return $result
}

function Get-QDOsInfo {
    <#
    .SYNOPSIS
        מחזיר פרטי מערכת הפעלה: שם, גרסה, Build, האם Windows 11.
    #>
    [CmdletBinding()]
    param()
    $caption = 'Windows'
    $build = [Environment]::OSVersion.Version.Build
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = ([string]$os.Caption).Replace('Microsoft ', '')
        $build = [int]$os.BuildNumber
    }
    catch { Write-Verbose $_.Exception.Message }
    $display = ''
    $ubr = ''
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $display = [string](Get-QDProp $cv 'DisplayVersion' '')
        $ubr = [string](Get-QDProp $cv 'UBR' '')
    }
    catch { Write-Verbose $_.Exception.Message }
    $full = $caption
    if ($display) { $full += " $display" }
    $buildText = if ($ubr) { "$build.$ubr" } else { "$build" }
    return @{ Caption = $caption; Display = $full; Build = $build; BuildText = $buildText; IsWin11 = ($build -ge 22000) }
}

function Get-QDSystemInfo {
    <#
    .SYNOPSIS
        אוסף מידע מערכת לכרטיס המידע ולדוח.
    #>
    [CmdletBinding()]
    param()
    $info = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Model        = ''
        Serial       = ''
        OS           = ''
        Build        = ''
        IsWin11      = $false
        CPU          = ''
        RamGB        = ''
        DiskFree     = ''
        DiskFreeGB   = 0
        Internet     = $false
        Power        = ''
        OnBattery    = $false
        Domain       = ''
        PartOfDomain = $false
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $info.Model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $info.RamGB = '{0:N1} GB' -f ($cs.TotalPhysicalMemory / 1GB)
        $info.PartOfDomain = [bool]$cs.PartOfDomain
        $info.Domain = if ($cs.PartOfDomain) { "דומיין: $($cs.Domain)" } else { "קבוצת עבודה: $($cs.Workgroup)" }
    }
    catch { Write-Verbose $_.Exception.Message }
    try { $info.Serial = [string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber } catch { Write-Verbose $_.Exception.Message }
    $os = Get-QDOsInfo
    $info.OS = $os.Display
    $info.Build = $os.BuildText
    $info.IsWin11 = $os.IsWin11
    try { $info.CPU = ([string](@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].Name)).Trim() -replace '\s{2,}', ' ' } catch { Write-Verbose $_.Exception.Message }
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        $info.DiskFreeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        $info.DiskFree = '{0:N1} GB פנויים מתוך {1:N0} GB' -f ($disk.FreeSpace / 1GB), ($disk.Size / 1GB)
    }
    catch { Write-Verbose $_.Exception.Message }
    $info.Internet = Test-QDInternet
    $pwr = Get-QDPowerSource
    $info.OnBattery = $pwr.OnBattery
    if (-not $pwr.HasBattery) { $info.Power = 'חשמל (ללא סוללה)' }
    elseif ($pwr.OnBattery) { $info.Power = "על סוללה ($($pwr.Charge)%)" }
    else { $info.Power = "מחובר לחשמל ($($pwr.Charge)%)" }
    return $info
}

function Get-QDPrinterDriverList {
    <#
    .SYNOPSIS
        מחזיר רשימת מנהלי התקן מדפסת מותקנים + מנהלי ה-Class המובנים.
    #>
    [CmdletBinding()]
    param()
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add('Microsoft IPP Class Driver')
    $names.Add('Microsoft PS Class Driver')
    try {
        foreach ($d in @(Get-PrinterDriver -ErrorAction Stop | Sort-Object Name)) {
            if (-not $names.Contains([string]$d.Name)) { $names.Add([string]$d.Name) }
        }
    }
    catch { Write-Verbose $_.Exception.Message }
    return $names.ToArray()
}

function Get-QDInteractiveUser {
    <#
    .SYNOPSIS
        מאתר את המשתמש המחובר בפועל (בעל תהליך explorer.exe): SID ושם מלא.
    #>
    [CmdletBinding()]
    param()
    try {
        $mySession = (Get-Process -Id $PID).SessionId
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
        $pick = @($procs | Where-Object { $_.SessionId -eq $mySession }) + @($procs) | Select-Object -First 1
        if ($null -eq $pick) { return $null }
        $sid = (Invoke-CimMethod -InputObject $pick -MethodName GetOwnerSid -ErrorAction Stop).Sid
        $owner = Invoke-CimMethod -InputObject $pick -MethodName GetOwner -ErrorAction Stop
        return @{ Sid = [string]$sid; User = [string]$owner.User; Domain = [string]$owner.Domain; FullName = ('{0}\{1}' -f $owner.Domain, $owner.User) }
    }
    catch {
        Write-Verbose $_.Exception.Message
        return $null
    }
}

#endregion System information

#region Registry & user hives

function Write-QDRegistryValue {
    <#
    .SYNOPSIS
        כותב ערך רישום (יוצר מפתח במידת הצורך) דרך Invoke-QDAction.
    .PARAMETER Path
        נתיב ספק (למשל HKLM:\... או Registry::HKEY_USERS\...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'Binary', 'MultiString')][string]$Type = 'DWord'
    )
    $display = if ($Name -eq '') { '(default)' } else { $Name }
    Invoke-QDAction -Description ("reg set {0} :: {1} = {2} ({3})" -f $Path, $display, $Value, $Type) -ScriptBlock {
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force -ErrorAction Stop }
        if ($Name -eq '') {
            $null = Set-Item -LiteralPath $Path -Value $Value -ErrorAction Stop
        }
        else {
            $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop
        }
    }
}

function Mount-QDUserHive {
    <#
    .SYNOPSIS
        מכין את רשימת ה-Hive של המשתמשים: המשתמש הנוכחי, המשתמש המחובר (אם שונה), ו-Default (reg load).
    #>
    [CmdletBinding()]
    param()
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add(@{ Label = 'משתמש נוכחי'; Path = 'Registry::HKEY_CURRENT_USER'; IsDefault = $false })
    $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $iu = Get-QDInteractiveUser
    if ($null -ne $iu -and $iu.Sid -and $iu.Sid -ne $mySid -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $iu.Sid))) {
        [void]$roots.Add(@{ Label = "משתמש מחובר ($($iu.FullName))"; Path = ("Registry::HKEY_USERS\" + $iu.Sid); IsDefault = $false })
    }
    $defaultDir = $null
    try {
        $defaultDir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop).Default)
    }
    catch { Write-QDLog -Message ('לא נמצא נתיב פרופיל Default: ' + $_.Exception.Message) -Level 'WARN' }
    $hivePath = if ($defaultDir) { Join-Path $defaultDir 'NTUSER.DAT' } else { $null }
    $hiveKey = 'HKU\' + $QD.DefaultHiveName
    $Sync.DefaultHiveLoaded = $false
    if ($hivePath -and (Test-Path -LiteralPath $hivePath)) {
        if ($Sync.Simulate) {
            Write-QDLog -Message ("[SIM] would reg load $hiveKey `"$hivePath`"") -Level 'SIM'
            [void]$roots.Add(@{ Label = 'משתמש ברירת מחדל'; Path = ('Registry::HKEY_USERS\' + $QD.DefaultHiveName); IsDefault = $true })
        }
        else {
            if (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $QD.DefaultHiveName)) {
                $null = Invoke-QDNative -FilePath 'reg.exe' -ArgumentList @('unload', $hiveKey)
            }
            $r = Invoke-QDNative -FilePath 'reg.exe' -ArgumentList @('load', $hiveKey, $hivePath)
            if ($r.ExitCode -eq 0) {
                $Sync.DefaultHiveLoaded = $true
                Write-QDLog -Message "reg load $hiveKey ($hivePath)"
                [void]$roots.Add(@{ Label = 'משתמש ברירת מחדל'; Path = ('Registry::HKEY_USERS\' + $QD.DefaultHiveName); IsDefault = $true })
            }
            else {
                Write-QDLog -Message ('טעינת Hive של Default נכשלה: ' + $r.Text) -Level 'WARN'
            }
        }
    }
    $Sync.UserRoots = $roots.ToArray()
    return $Sync.UserRoots
}

function Dismount-QDUserHive {
    <#
    .SYNOPSIS
        פורק את ה-Hive של Default (gc + reg unload, עם ניסיונות חוזרים).
    #>
    [CmdletBinding()]
    param()
    if (-not $Sync.DefaultHiveLoaded) { return }
    $hiveKey = 'HKU\' + $QD.DefaultHiveName
    for ($i = 1; $i -le 5; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $r = Invoke-QDNative -FilePath 'reg.exe' -ArgumentList @('unload', $hiveKey)
        if ($r.ExitCode -eq 0) {
            $Sync.DefaultHiveLoaded = $false
            Write-QDLog -Message "reg unload $hiveKey"
            return
        }
        Start-Sleep -Milliseconds (500 * $i)
    }
    Write-QDLog -Message "פריקת $hiveKey נכשלה — ייפרק בהפעלה מחדש" -Level 'WARN'
}

function Write-QDUserValue {
    <#
    .SYNOPSIS
        כותב ערך HKCU לכל ה-Hives שהוכנו (משתמש נוכחי, מחובר, Default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()]$Value,
        [string]$Type = 'DWord',
        [switch]$SkipDefaultHive
    )
    $roots = @($Sync.UserRoots)
    if ($roots.Count -eq 0) { $roots = @(@{ Label = 'משתמש נוכחי'; Path = 'Registry::HKEY_CURRENT_USER'; IsDefault = $false }) }
    foreach ($root in $roots) {
        if ($SkipDefaultHive -and $root.IsDefault) { continue }
        Write-QDRegistryValue -Path ($root.Path + '\' + $SubKey) -Name $Name -Value $Value -Type $Type
    }
}

#endregion Registry & user hives


#region Pipeline framework

function Initialize-QDStepState {
    <#
    .SYNOPSIS
        מאתחל את מצב שלבי ההרצה ב-Sync.
    #>
    [CmdletBinding()]
    param()
    $steps = New-Object System.Collections.ArrayList
    foreach ($def in $QD.StepDefinitions) {
        [void]$steps.Add([hashtable]::Synchronized(@{
                    Id       = $def.Id
                    Title    = $def.Title
                    Icon     = $def.Icon
                    Weight   = $def.Weight
                    Status   = 'Pending'
                    Start    = $null
                    End      = $null
                    Duration = ''
                    Detail   = ''
                    Items    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
                }))
    }
    $Sync.Steps = $steps
    $Sync.StepIndex = 0
    $Sync.SubProgress = 0.0
    $Sync.Progress = 0.0
    $Sync.Cancel = $false
    $Sync.Done = $false
    $Sync.RebootRequired = $false
    $Sync.RebootReasons.Clear()
    $Sync.ReportPath = ''
    $Sync.ExitCode = 0
    $Sync.FatalError = ''
    $Sync.Activity = ''
}

function Sync-QDProgress {
    <#
    .SYNOPSIS
        מחשב את אחוז ההתקדמות הכולל לפי משקלי השלבים והתקדמות-המשנה.
    #>
    [CmdletBinding()]
    param()
    $total = 0.0
    $done = 0.0
    for ($i = 0; $i -lt $Sync.Steps.Count; $i++) {
        $s = $Sync.Steps[$i]
        $total += $s.Weight
        if ($s.Status -notin @('Pending', 'Running')) { $done += $s.Weight }
        elseif ($s.Status -eq 'Running') { $done += $s.Weight * [math]::Min(1.0, [math]::Max(0.0, [double]$Sync.SubProgress)) }
    }
    if ($total -gt 0) { $Sync.Progress = [math]::Round(($done / $total) * 100, 1) }
}

function Enter-QDStep {
    <#
    .SYNOPSIS
        מסמן שלב כ"רץ".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Index)
    $step = $Sync.Steps[$Index]
    $Sync.StepIndex = $Index
    $Sync.SubProgress = 0.0
    $step.Status = 'Running'
    $step.Start = Get-Date
    $Sync.Activity = $step.Title
    Write-QDLog -Message ('=== שלב {0}/{1}: {2} ===' -f ($Index + 1), $Sync.Steps.Count, $step.Title) -Level 'STEP'
    Sync-QDProgress
    Send-QDPump -Force
}

function Add-QDStepItem {
    <#
    .SYNOPSIS
        מוסיף תוצאת-משנה לשלב הנוכחי ורושם אותה ביומן.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Success', 'AlreadyDone', 'Skipped', 'Failed', 'Warning', 'Simulated', 'Info', 'Cancelled')][string]$Status,
        [AllowEmptyString()][string]$Message = ''
    )
    $step = $Sync.Steps[$Sync.StepIndex]
    [void]$step.Items.Add(@{ Name = $Name; Status = $Status; Message = $Message })
    $level = switch ($Status) { 'Success' { 'OK' } 'AlreadyDone' { 'OK' } 'Failed' { 'ERROR' } 'Warning' { 'WARN' } 'Simulated' { 'SIM' } default { 'INFO' } }
    $text = '{0} — {1}' -f $Name, $QD.StatusText[$Status]
    if ($Message) { $text += ': ' + $Message }
    Write-QDLog -Message $text -Level $level
}

function Complete-QDStep {
    <#
    .SYNOPSIS
        מסיים את השלב הנוכחי ומחשב את הסטטוס הסופי שלו לפי תוצאות-המשנה.
    #>
    [CmdletBinding()]
    param([string]$ForceStatus = '')
    $step = $Sync.Steps[$Sync.StepIndex]
    $items = @($step.Items)
    $status = 'Success'
    if ($ForceStatus) {
        $status = $ForceStatus
    }
    else {
        $failed = @($items | Where-Object { $_.Status -eq 'Failed' }).Count
        $warn = @($items | Where-Object { $_.Status -eq 'Warning' }).Count
        $cancelled = @($items | Where-Object { $_.Status -eq 'Cancelled' }).Count
        $good = @($items | Where-Object { $_.Status -in @('Success', 'AlreadyDone', 'Simulated') }).Count
        $skipped = @($items | Where-Object { $_.Status -eq 'Skipped' }).Count
        if ($cancelled -gt 0 -and $Sync.Cancel) { $status = 'Cancelled' }
        elseif ($failed -gt 0 -and $good -eq 0 -and $warn -eq 0) { $status = 'Failed' }
        elseif ($failed -gt 0) { $status = 'Partial' }
        elseif ($warn -gt 0) { $status = 'Warning' }
        elseif ($items.Count -gt 0 -and $skipped -eq $items.Count) { $status = 'Skipped' }
        elseif ($items.Count -eq 0) { $status = 'Skipped' }
    }
    $step.End = Get-Date
    if ($null -ne $step.Start) {
        $span = $step.End - $step.Start
        $step.Duration = if ($span.TotalMinutes -ge 1) { '{0}:{1:00} דק׳' -f [int][math]::Floor($span.TotalMinutes), $span.Seconds } else { '{0:N1} שנ׳' -f $span.TotalSeconds }
    }
    $step.Status = $status
    $step.Detail = '{0} פעולות' -f $items.Count
    Write-QDLog -Message ('--- {0}: {1} ({2}) ---' -f $step.Title, $QD.StatusText[$status], $step.Duration) -Level $(if ($status -eq 'Failed') { 'ERROR' } elseif ($status -in @('Partial', 'Warning')) { 'WARN' } else { 'OK' })
    $Sync.SubProgress = 0.0
    Sync-QDProgress
    Send-QDPump -Force
}

function Invoke-QDSubAction {
    <#
    .SYNOPSIS
        מריץ פעולת-משנה עם בדיקת ביטול, try/catch ורישום תוצאה.
        הבלוק יכול להחזיר מחרוזת (הודעה) או מילון @{Status; Message}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    if (Test-QDCancel) {
        Add-QDStepItem -Name $Name -Status 'Cancelled' -Message 'בוטל על ידי המשתמש'
        return
    }
    $ErrorActionPreference = 'Stop'
    try {
        $out = @(& $ScriptBlock)
        $override = $out | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Status') } | Select-Object -Last 1
        if ($null -ne $override) {
            Add-QDStepItem -Name $Name -Status $override.Status -Message ([string]$override.Message)
        }
        else {
            $msg = (@($out | Where-Object { $_ -is [string] }) -join ' ').Trim()
            $status = if ($Sync.Simulate) { 'Simulated' } else { 'Success' }
            Add-QDStepItem -Name $Name -Status $status -Message $msg
        }
    }
    catch {
        Add-QDStepItem -Name $Name -Status 'Failed' -Message $_.Exception.Message
    }
    Send-QDPump
}

function Add-QDRebootReason {
    <#
    .SYNOPSIS
        מסמן שנדרשת הפעלה מחדש ומוסיף סיבה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason)
    $Sync.RebootRequired = $true
    if (-not $Sync.RebootReasons.Contains($Reason)) { [void]$Sync.RebootReasons.Add($Reason) }
}

#endregion Pipeline framework

#region Step 1-2 — Preflight & restore point

function Invoke-QDPreflight {
    <#
    .SYNOPSIS
        שלב 1: בדיקות מקדימות — הרשאות, גרסת מערכת, אינטרנט, מקום פנוי, סוללה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    Write-QDLog -Message ('פרופיל: {0} · תוכנות: {1} · מצב: {2}' -f $Config.name, (@($Config.apps).Count + @($Config.customApps).Count), $(if ($Sync.Simulate) { 'סימולציה' } else { 'ביצוע' }))
    Invoke-QDSubAction -Name 'הרשאות מנהל' -ScriptBlock {
        if (Test-QDIsAdmin) { @{ Status = 'Success'; Message = 'התהליך רץ בהרשאות מנהל' } }
        else { @{ Status = 'Failed'; Message = 'התהליך אינו רץ כמנהל' } }
    }
    Invoke-QDSubAction -Name 'גרסת מערכת הפעלה' -ScriptBlock {
        $os = Get-QDOsInfo
        if ($os.Build -ge 19045) { @{ Status = 'Success'; Message = ('{0} (Build {1})' -f $os.Display, $os.BuildText) } }
        else { @{ Status = 'Warning'; Message = ('{0} (Build {1}) — גרסה ישנה מהנתמך (Windows 10 22H2 ומעלה)' -f $os.Display, $os.BuildText) } }
    }
    Invoke-QDSubAction -Name 'חיבור לאינטרנט' -ScriptBlock {
        if (Test-QDInternet -Thorough) { @{ Status = 'Success'; Message = 'יש חיבור' } }
        else { @{ Status = 'Warning'; Message = 'אין חיבור לאינטרנט — התקנת תוכנות צפויה להיכשל' } }
    }
    Invoke-QDSubAction -Name 'מקום פנוי בכונן המערכת' -ScriptBlock {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
        $gb = [math]::Round($disk.FreeSpace / 1GB, 1)
        if ($gb -ge 10) { @{ Status = 'Success'; Message = "$gb GB פנויים" } }
        else { @{ Status = 'Warning'; Message = "רק $gb GB פנויים (מומלץ 10GB לפחות)" } }
    }
    Invoke-QDSubAction -Name 'מקור חשמל' -ScriptBlock {
        $p = Get-QDPowerSource
        if (-not $p.HasBattery) { @{ Status = 'Success'; Message = 'ללא סוללה' } }
        elseif ($p.OnBattery) { @{ Status = 'Warning'; Message = "המחשב פועל על סוללה ($($p.Charge)%) — מומלץ לחבר מטען" } }
        else { @{ Status = 'Success'; Message = "מחובר לחשמל ($($p.Charge)%)" } }
    }
    $Sync.SubProgress = 1.0
}

function Invoke-QDRestorePoint {
    <#
    .SYNOPSIS
        שלב 2: יצירת נקודת שחזור (כשל = אזהרה בלבד).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    if (Test-QDCancel) { Add-QDStepItem -Name 'נקודת שחזור' -Status 'Cancelled' -Message 'בוטל'; return }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $valueName = 'SystemRestorePointCreationFrequency'
    $previous = $null
    try { $previous = (Get-ItemProperty -LiteralPath $key -Name $valueName -ErrorAction Stop).$valueName } catch { $previous = $null }
    $drive = $env:SystemDrive + '\'
    try {
        Invoke-QDAction -Description "Enable-ComputerRestore -Drive $drive" -ScriptBlock { Enable-ComputerRestore -Drive $drive -ErrorAction Stop }
        Write-QDRegistryValue -Path $key -Name $valueName -Value 0 -Type 'DWord'
        $desc = 'QuickDeploy {0} {1}' -f $Config.name, (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Invoke-QDAction -Description "Checkpoint-Computer '$desc'" -ScriptBlock {
            Checkpoint-Computer -Description $desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue
        }
        $st = if ($Sync.Simulate) { 'Simulated' } else { 'Success' }
        Add-QDStepItem -Name 'נקודת שחזור' -Status $st -Message $desc
    }
    catch {
        Add-QDStepItem -Name 'נקודת שחזור' -Status 'Warning' -Message ('לא נוצרה נקודת שחזור: ' + $_.Exception.Message)
    }
    finally {
        try {
            if ($null -eq $previous) {
                Invoke-QDAction -Description "reg delete $key :: $valueName" -ScriptBlock { Remove-ItemProperty -LiteralPath $key -Name $valueName -ErrorAction SilentlyContinue }
            }
            else {
                Write-QDRegistryValue -Path $key -Name $valueName -Value $previous -Type 'DWord'
            }
        }
        catch { Write-QDLog -Message ('שחזור ערך תדירות נקודות שחזור נכשל: ' + $_.Exception.Message) -Level 'WARN' }
    }
}

#endregion Step 1-2

#region Step 3 — Debloat

function Test-QDProtectedPackage {
    <#
    .SYNOPSIS
        בודק האם חבילה ברשימת המוגנות (אסור להסיר).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in $QD.Protected) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Invoke-QDAppxRemoval {
    <#
    .SYNOPSIS
        מסיר חבילת Appx לפי תבנית לכל המשתמשים ומבטל את ההקצאה (Provisioned), תוך אכיפת רשימת המוגנות.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pattern)
    $ErrorActionPreference = 'Stop'
    $removed = New-Object System.Collections.Generic.List[string]
    $protectedHits = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    $installed = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue)
    foreach ($pkg in $installed) {
        if (Test-QDProtectedPackage -Name $pkg.Name) { $protectedHits.Add($pkg.Name); continue }
        try {
            $full = $pkg.PackageFullName
            Invoke-QDAction -Description "Remove-AppxPackage -AllUsers $full" -ScriptBlock { Remove-AppxPackage -Package $full -AllUsers -ErrorAction Stop }
            $removed.Add($pkg.Name)
        }
        catch { $errors.Add(('{0}: {1}' -f $pkg.Name, $_.Exception.Message)) }
    }
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern })
    foreach ($prov in $provisioned) {
        if (Test-QDProtectedPackage -Name $prov.DisplayName) { $protectedHits.Add($prov.DisplayName); continue }
        try {
            $pn = $prov.PackageName
            Invoke-QDAction -Description "Remove-AppxProvisionedPackage -Online $pn" -ScriptBlock { $null = Remove-AppxProvisionedPackage -Online -PackageName $pn -ErrorAction Stop }
            $removed.Add($prov.DisplayName + ' (provisioned)')
        }
        catch { $errors.Add(('{0} (provisioned): {1}' -f $prov.DisplayName, $_.Exception.Message)) }
    }
    $uniqueProtected = @($protectedHits | Select-Object -Unique)
    if ($uniqueProtected.Count -gt 0) { Write-QDLog -Message ('חבילות מוגנות דולגו: ' + ($uniqueProtected -join ', ')) -Level 'WARN' }
    if ($errors.Count -gt 0) {
        return @{ Status = 'Failed'; Message = ($errors -join ' | ') }
    }
    if ($removed.Count -eq 0) {
        $msg = 'לא נמצא במחשב'
        if ($uniqueProtected.Count -gt 0) { $msg = 'מוגן — לא הוסר (' + ($uniqueProtected -join ', ') + ')' }
        return @{ Status = 'Skipped'; Message = $msg }
    }
    $status = if ($Sync.Simulate) { 'Simulated' } else { 'Success' }
    return @{ Status = $status; Message = ('הוסר: ' + ((@($removed) | Select-Object -Unique) -join ', ')) }
}

function Invoke-QDOneDriveRemoval {
    <#
    .SYNOPSIS
        מסיר את OneDrive (מערכת + משתמש) ומונע התקנה אוטומטית למשתמשים חדשים.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $messages = New-Object System.Collections.Generic.List[string]
    Invoke-QDAction -Description 'Stop-Process OneDrive' -ScriptBlock { Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    $setups = @(
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    foreach ($s in $setups) {
        $null = Invoke-QDNativeAction -FilePath $s -ArgumentList @('/uninstall', '/allusers') -SuccessCodes @(0, 1, -2147219813)
        $messages.Add('הוסר מ-' + (Split-Path -Parent $s))
        break
    }
    $uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($root in @($Sync.UserRoots)) {
        if (-not $root.IsDefault) { $uninstallRoots += ($root.Path + '\Software\Microsoft\Windows\CurrentVersion\Uninstall') }
    }
    foreach ($ur in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $ur)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $ur -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $dn = [string](Get-QDProp $props 'DisplayName' '')
            $us = [string](Get-QDProp $props 'UninstallString' '')
            if ($dn -like 'Microsoft OneDrive*' -and $us) {
                if ($us -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
                else { $exe = ($us -split '\s+', 2)[0]; $rest = if (($us -split '\s+', 2).Count -gt 1) { ($us -split '\s+', 2)[1] } else { '' } }
                if (Test-Path -LiteralPath $exe) {
                    $argList = @($rest -split '\s+' | Where-Object { $_ })
                    if ($argList -notcontains '/silent') { $argList += '/silent' }
                    try {
                        $null = Invoke-QDNativeAction -FilePath $exe -ArgumentList $argList -SuccessCodes @(0, 1)
                        $messages.Add('הוסר: ' + $dn)
                    }
                    catch { $messages.Add('הסרה נכשלה: ' + $_.Exception.Message) }
                }
            }
        }
    }
    # Prevent the per-user OneDrive setup for new users
    foreach ($root in @($Sync.UserRoots | Where-Object { $_.IsDefault })) {
        $runKey = $root.Path + '\Software\Microsoft\Windows\CurrentVersion\Run'
        Invoke-QDAction -Description "reg delete $runKey :: OneDriveSetup" -ScriptBlock {
            if (Test-Path -LiteralPath $runKey) { Remove-ItemProperty -LiteralPath $runKey -Name 'OneDriveSetup' -ErrorAction SilentlyContinue }
        }
    }
    Write-QDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1
    if ($messages.Count -eq 0) { $messages.Add('OneDrive לא נמצא; נחסמה התקנה עתידית') }
    return ($messages -join ' | ')
}

function Invoke-QDDebloat {
    <#
    .SYNOPSIS
        שלב 3: הסרת אפליקציות מובנות וכיבוי הצעות/פרסומות.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $d = $Config.debloat
    $pkgs = @($d.packages)
    $total = [math]::Max(1, $pkgs.Count + 5)
    $i = 0
    foreach ($pattern in $pkgs) {
        $i++
        $Sync.SubProgress = $i / $total
        $label = ($QD.Debloat | Where-Object { $_.Name -eq $pattern } | Select-Object -First 1)
        $name = if ($label) { '{0} ({1})' -f $label.Label, $pattern } else { $pattern }
        $Sync.Activity = 'מסיר: ' + $name
        if (Test-QDProtectedPackage -Name $pattern) {
            Add-QDStepItem -Name $name -Status 'Skipped' -Message 'חבילה מוגנת — לעולם לא מוסרת'
            continue
        }
        Invoke-QDSubAction -Name $name -ScriptBlock { Invoke-QDAppxRemoval -Pattern $pattern }
    }

    $null = Mount-QDUserHive
    try {
        if ($d.consumerFeatures) {
            Invoke-QDSubAction -Name 'כיבוי התקנת אפליקציות מוצעות (Consumer Features)' -ScriptBlock {
                Write-QDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1
                Write-QDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Value 1
                'DisableWindowsConsumerFeatures=1'
            }
        }
        $Sync.SubProgress = ($pkgs.Count + 1) / $total
        if ($d.ads) {
            Invoke-QDSubAction -Name 'כיבוי הצעות ופרסומות (Start, הגדרות, מסך נעילה)' -ScriptBlock {
                $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                $values = @('SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
                    'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                    'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled', 'SilentInstalledAppsEnabled',
                    'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
                    'PreInstalledAppsEverEnabled', 'RotatingLockScreenOverlayEnabled', 'ContentDeliveryAllowed')
                foreach ($v in $values) { Write-QDUserValue -SubKey $cdm -Name $v -Value 0 }
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Value 0
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' -Value 0
                ('{0} ערכים הוגדרו ל-0 (משתמש נוכחי + ברירת מחדל)' -f ($values.Count + 2))
            }
        }
        $Sync.SubProgress = ($pkgs.Count + 2) / $total
        if ($d.bingSearch) {
            Invoke-QDSubAction -Name 'כיבוי תוצאות Bing בחיפוש Start' -ScriptBlock {
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -Value 0
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Search' -Name 'CortanaConsent' -Value 0
                Write-QDUserValue -SubKey 'Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Value 1
                'BingSearchEnabled=0, DisableSearchBoxSuggestions=1'
            }
        }
        $Sync.SubProgress = ($pkgs.Count + 3) / $total
        if ($d.copilot) {
            Invoke-QDSubAction -Name 'כיבוי Copilot' -ScriptBlock {
                Write-QDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
                Write-QDUserValue -SubKey 'Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Value 0
                'TurnOffWindowsCopilot=1'
            }
        }
        $Sync.SubProgress = ($pkgs.Count + 4) / $total
        if ($d.oneDrive) {
            Invoke-QDSubAction -Name 'הסרת OneDrive' -ScriptBlock { Invoke-QDOneDriveRemoval }
        }
    }
    finally {
        Dismount-QDUserHive
    }
    if ($pkgs.Count -eq 0 -and -not ($d.consumerFeatures -or $d.ads -or $d.bingSearch -or $d.copilot -or $d.oneDrive)) {
        Add-QDStepItem -Name 'ניקוי' -Status 'Skipped' -Message 'לא נבחרו פריטים'
    }
}

#endregion Step 3

#region Step 4 — System settings

function Resolve-QDHighPerformancePlan {
    <#
    .SYNOPSIS
        מחזיר GUID של תוכנית "ביצועים גבוהים"; יוצר אותה אם היא מוסתרת.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $list = Invoke-QDNative -FilePath 'powercfg.exe' -ArgumentList @('/list')
    if ($list.Text -match [regex]::Escape($QD.HighPerfGuid)) { return $QD.HighPerfGuid }
    if ($Sync.Simulate) {
        Write-QDLog -Message ('[SIM] would powercfg -duplicatescheme ' + $QD.HighPerfGuid) -Level 'SIM'
        return $QD.HighPerfGuid
    }
    $dup = Invoke-QDNative -FilePath 'powercfg.exe' -ArgumentList @('-duplicatescheme', $QD.HighPerfGuid)
    if ($dup.Text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    throw 'לא ניתן ליצור תוכנית ביצועים גבוהים'
}

function Invoke-QDSystemConfig {
    <#
    .SYNOPSIS
        שלב 4: הגדרות מערכת — אזור זמן, מקלדת, חשמל, סייר, Windows 11, RDP, משתמש מנהל.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $s = $Config.system
    $os = Get-QDOsInfo
    $null = Mount-QDUserHive
    try {
        if ($s.timezone) {
            Invoke-QDSubAction -Name 'אזור זמן: ישראל' -ScriptBlock {
                $tz = Get-TimeZone
                if ($tz.Id -eq 'Israel Standard Time') { @{ Status = 'AlreadyDone'; Message = 'כבר מוגדר' } }
                else {
                    Invoke-QDAction -Description "Set-TimeZone -Id 'Israel Standard Time'" -ScriptBlock { Set-TimeZone -Id 'Israel Standard Time' -ErrorAction Stop }
                    'Israel Standard Time'
                }
            }
        }
        $Sync.SubProgress = 0.1
        if ($s.hebrewKeyboard) {
            Invoke-QDSubAction -Name 'מקלדת עברית + אנגלית' -ScriptBlock {
                $langs = Get-WinUserLanguageList
                $tags = @($langs | ForEach-Object { $_.LanguageTag })
                $hasHe = @($tags | Where-Object { $_ -like 'he*' }).Count -gt 0
                $hasEn = $tags -contains 'en-US'
                $msg = 'עברית ואנגלית כבר ברשימה'
                if (-not ($hasHe -and $hasEn)) {
                    Invoke-QDAction -Description 'Set-WinUserLanguageList (+he-IL, +en-US)' -ScriptBlock {
                        $l = Get-WinUserLanguageList
                        if (-not $hasHe) { $l.Add('he-IL') }
                        if (-not $hasEn) { $l.Add('en-US') }
                        Set-WinUserLanguageList -LanguageList $l -Force -ErrorAction Stop
                    }
                    $msg = 'נוספו שפות קלט חסרות'
                }
                if (Get-Command -Name 'Copy-UserInternationalSettingsToSystem' -ErrorAction SilentlyContinue) {
                    Invoke-QDAction -Description 'Copy-UserInternationalSettingsToSystem -WelcomeScreen -NewUser' -ScriptBlock { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop }
                    Add-QDRebootReason -Reason 'הגדרות שפה למסך הכניסה ולמשתמשים חדשים'
                    $msg += '; הועתק למסך הכניסה ולמשתמשים חדשים'
                }
                if (-not ($hasHe -and $hasEn)) { $msg } else { @{ Status = 'AlreadyDone'; Message = $msg } }
            }
        }
        $Sync.SubProgress = 0.2
        Invoke-QDSubAction -Name ('תוכנית חשמל: ' + $(if ($s.powerPlan -eq 'high') { 'ביצועים גבוהים' } else { 'מאוזן' })) -ScriptBlock {
            $guid = if ($s.powerPlan -eq 'high') { Resolve-QDHighPerformancePlan } else { $QD.BalancedGuid }
            $null = Invoke-QDNativeAction -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $guid)
            $null = Invoke-QDNativeAction -FilePath 'powercfg.exe' -ArgumentList @('/change', 'standby-timeout-ac', '0')
            $null = Invoke-QDNativeAction -FilePath 'powercfg.exe' -ArgumentList @('/change', 'monitor-timeout-ac', '30')
            'שינה בחשמל: לעולם לא; כיבוי מסך: 30 דקות'
        }
        if ($s.disableHibernation) {
            Invoke-QDSubAction -Name 'כיבוי מצב שינה עמוקה (Hibernation)' -ScriptBlock {
                $null = Invoke-QDNativeAction -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', 'off')
                'powercfg /hibernate off'
            }
        }
        if ($s.disableFastStartup) {
            Invoke-QDSubAction -Name 'כיבוי הפעלה מהירה (Fast Startup)' -ScriptBlock {
                Write-QDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0
                'HiberbootEnabled=0'
            }
        }
        $Sync.SubProgress = 0.4
        $adv = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        if ($s.showExtensions) {
            Invoke-QDSubAction -Name 'הצגת סיומות קבצים' -ScriptBlock { Write-QDUserValue -SubKey $adv -Name 'HideFileExt' -Value 0; 'HideFileExt=0' }
        }
        if ($s.showHidden) {
            Invoke-QDSubAction -Name 'הצגת קבצים מוסתרים' -ScriptBlock { Write-QDUserValue -SubKey $adv -Name 'Hidden' -Value 1; 'Hidden=1' }
        }
        if ($s.explorerThisPC) {
            Invoke-QDSubAction -Name 'סייר נפתח ב"מחשב זה"' -ScriptBlock { Write-QDUserValue -SubKey $adv -Name 'LaunchTo' -Value 1; 'LaunchTo=1' }
        }
        $Sync.SubProgress = 0.55
        if ($os.IsWin11) {
            if ($s.taskbarLeft) {
                Invoke-QDSubAction -Name 'שורת משימות מיושרת לצד' -ScriptBlock { Write-QDUserValue -SubKey $adv -Name 'TaskbarAl' -Value 0; 'TaskbarAl=0' }
            }
            if ($s.classicContextMenu) {
                Invoke-QDSubAction -Name 'תפריט לחצן ימני קלאסי' -ScriptBlock {
                    Write-QDUserValue -SubKey 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '' -Value '' -Type 'String' -SkipDefaultHive
                    'הוחל למשתמשים הקיימים (דורש כניסה מחדש)'
                }
            }
        }
        elseif ($s.taskbarLeft -or $s.classicContextMenu) {
            Add-QDStepItem -Name 'הגדרות Windows 11' -Status 'Skipped' -Message 'המחשב מריץ Windows 10'
        }
        $Sync.SubProgress = 0.65
        if ($s.enableRdp) {
            Invoke-QDSubAction -Name 'הפעלת שולחן עבודה מרוחק (RDP)' -ScriptBlock {
                Write-QDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
                Invoke-QDAction -Description "Enable-NetFirewallRule -Group 'Remote Desktop'" -ScriptBlock {
                    Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop
                }
                'RDP מופעל + חוקי חומת אש'
            }
        }
        $Sync.SubProgress = 0.8
        if ($s.createLocalAdmin) {
            Invoke-QDSubAction -Name 'יצירת משתמש מנהל מקומי' -ScriptBlock {
                if ($Sync.Silent) { return @{ Status = 'Skipped'; Message = 'דורש סיסמה — דולג במצב שקט' } }
                $la = $null
                if ($Sync.Secrets.ContainsKey('LocalAdmin')) { $la = $Sync.Secrets['LocalAdmin'] }
                if ($null -eq $la) {
                    if ($Sync.Simulate) { return @{ Status = 'Simulated'; Message = 'would create local admin (פרטים לא נאספו בסימולציה)' } }
                    return @{ Status = 'Skipped'; Message = 'לא הוזנו שם משתמש וסיסמה' }
                }
                $userName = [string]$la.Name
                $secure = $la.Secret
                $existing = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
                if ($null -eq $existing) {
                    Invoke-QDAction -Description "New-LocalUser $userName" -ScriptBlock {
                        $null = New-LocalUser -Name $userName -Password $secure -PasswordNeverExpires -AccountNeverExpires -Description 'Created by QuickDeploy' -ErrorAction Stop
                    }
                }
                Invoke-QDAction -Description "Add-LocalGroupMember S-1-5-32-544 $userName" -ScriptBlock {
                    try { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $userName -ErrorAction Stop }
                    catch { if ($_.FullyQualifiedErrorId -notlike '*MemberExists*') { throw } }
                }
                if ($null -ne $existing) { @{ Status = 'Warning'; Message = "המשתמש $userName כבר קיים — הסיסמה לא שונתה, וודא חברות בקבוצת המנהלים" } }
                else { "נוצר המשתמש $userName ונוסף למנהלים" }
            }
        }
    }
    finally {
        Dismount-QDUserHive
    }
    if ($os.IsWin11 -and ($s.taskbarLeft -or $s.classicContextMenu)) {
        Add-QDRebootReason -Reason 'הגדרות שורת משימות ותפריט (כניסה מחדש)'
    }
    $Sync.SubProgress = 1.0
}

#endregion Step 4

#region Step 5 — Software installation (winget)

function Resolve-QDWinget {
    <#
    .SYNOPSIS
        מאתר את winget.exe (PATH או WindowsApps). מחזיר נתיב או מחרוזת ריקה.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return [string]$cmd.Source }
    $candidates = @()
    $userAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $userAlias) { $candidates += $userAlias }
    $wa = Join-Path $env:ProgramFiles 'WindowsApps'
    try {
        $dirs = @(Get-ChildItem -LiteralPath $wa -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction Stop | Sort-Object Name -Descending)
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName 'winget.exe'
            if (Test-Path -LiteralPath $exe) { $candidates += $exe }
        }
    }
    catch { Write-Verbose $_.Exception.Message }
    if ($candidates.Count -gt 0) { return [string]$candidates[0] }
    return ''
}

function Install-QDWinget {
    <#
    .SYNOPSIS
        מוריד ומתקין את App Installer (winget) עם התלויות VCLibs ו-UI.Xaml.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $tmp = Join-Path $env:TEMP 'QuickDeploy_winget'
    $downloads = @(
        @{ Url = "https://aka.ms/Microsoft.VCLibs.$arch.14.00.Desktop.appx"; File = "Microsoft.VCLibs.$arch.appx" }
        @{ Url = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.$arch.appx"; File = "Microsoft.UI.Xaml.2.8.$arch.appx" }
        @{ Url = 'https://aka.ms/getwinget'; File = 'Microsoft.DesktopAppInstaller.msixbundle' }
    )
    Invoke-QDAction -Description 'download & install App Installer (winget) + dependencies' -ScriptBlock {
        if (-not (Test-Path -LiteralPath $tmp)) { $null = New-Item -Path $tmp -ItemType Directory -Force }
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            foreach ($dl in $downloads) {
                $target = Join-Path $tmp $dl.File
                Write-QDLog -Message ('מוריד ' + $dl.Url)
                Invoke-WebRequest -Uri $dl.Url -OutFile $target -UseBasicParsing -ErrorAction Stop
            }
        }
        finally { $ProgressPreference = $oldProgress }
        foreach ($dep in $downloads[0..1]) {
            try { Add-AppxPackage -Path (Join-Path $tmp $dep.File) -ErrorAction Stop }
            catch { Write-QDLog -Message ('תלות {0}: {1}' -f $dep.File, $_.Exception.Message) -Level 'WARN' }
        }
        Add-AppxPackage -Path (Join-Path $tmp $downloads[2].File) -ErrorAction Stop
        Start-Sleep -Seconds 3
    }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Verbose $_.Exception.Message }
}

function Invoke-QDWinget {
    <#
    .SYNOPSIS
        מריץ winget עם ארגומנטים ומחזיר קוד יציאה ופלט.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { $Sync.WingetPath = Resolve-QDWinget }
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { return @{ ExitCode = -1; Output = @('winget not found'); Text = 'winget not found' } }
    return (Invoke-QDNative -FilePath $Sync.WingetPath -ArgumentList $ArgumentList)
}

function Test-QDWingetPackage {
    <#
    .SYNOPSIS
        בודק זמינות מזהה בקטלוג winget (winget show). מחזיר ok / unavailable / unknown / nowinget.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id, [string]$Source = 'winget')
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { $Sync.WingetPath = Resolve-QDWinget }
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { return 'nowinget' }
    $wgArgs = @('show', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ($Source -eq 'msstore') { $wgArgs += @('--source', 'msstore') }
    $r = Invoke-QDWinget -ArgumentList $wgArgs
    if ($r.ExitCode -eq 0) { return 'ok' }
    if ($r.ExitCode -eq $QD.WingetNotFoundCode) { return 'unavailable' }
    return 'unknown'
}

function Test-QDCatalog {
    <#
    .SYNOPSIS
        בודק ברקע את זמינות כל מזהי הקטלוג (winget show) ומעדכן את Sync.CatalogStatus.
    #>
    [CmdletBinding()]
    param([object[]]$Apps = @())
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { $Sync.WingetPath = Resolve-QDWinget }
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) {
        foreach ($a in $Apps) { $Sync.CatalogStatus[[string]$a.Id] = 'nowinget' }
        $Sync.CatalogVersion++
        Send-QDPump -Force
        return
    }
    $unknownCount = 0
    foreach ($a in $Apps) {
        $state = Test-QDWingetPackage -Id ([string]$a.Id) -Source ([string]$a.Source)
        if ($state -eq 'unknown') { $unknownCount++ }
        $Sync.CatalogStatus[[string]$a.Id] = $state
        $Sync.CatalogVersion++
        Send-QDPump -Force
    }
    Write-QDLog -Message ('בדיקת זמינות קטלוג הושלמה ({0} פריטים, {1} לא נבדקו)' -f @($Apps).Count, $unknownCount)
}

function Search-QDWinget {
    <#
    .SYNOPSIS
        מריץ winget search ומפרק את הטבלה לרשימת תוצאות (Name, Id, Version, Source).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Query)
    $r = Invoke-QDWinget -ArgumentList @('search', $Query, '--accept-source-agreements', '--disable-interactivity')
    $results = New-Object System.Collections.ArrayList
    $lines = @($r.Output)
    $sepIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}$') { $sepIndex = $i; break } }
    if ($sepIndex -lt 1) { return @() }
    $header = $lines[$sepIndex - 1]
    $starts = New-Object System.Collections.Generic.List[int]
    $mc = [regex]::Matches($header, '(?<=^|\s)\S')
    foreach ($m in $mc) { $starts.Add($m.Index) }
    if ($starts.Count -lt 3) { return @() }
    $hasSource = $starts.Count -ge 5
    for ($i = $sepIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -le $starts[1]) { continue }
        $name = $line.Substring(0, [math]::Min($starts[1], $line.Length)).Trim()
        # IDs never contain spaces — take the first token from the Id column (tolerates column overflow)
        $tokens = @($line.Substring($starts[1]).Trim() -split '\s+')
        $id = $tokens[0]
        $version = if ($tokens.Count -gt 1) { $tokens[1] } else { '' }
        $source = 'winget'
        if ($hasSource) {
            $last = ($line.Trim() -split '\s+')[-1]
            if ($last -in @('winget', 'msstore')) { $source = $last }
        }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]{1,127}$') { continue }
        [void]$results.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $version; Source = $source })
        if ($results.Count -ge 40) { break }
    }
    return $results.ToArray()
}

function Get-QDRunAppList {
    <#
    .SYNOPSIS
        מחזיר את רשימת התוכנות להתקנה מתוך הפרופיל (קטלוג + מותאמות).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $list = New-Object System.Collections.ArrayList
    foreach ($id in @($Config.apps)) {
        $cat = $QD.Catalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($cat) { [void]$list.Add(@{ Id = $cat.Id; Name = $cat.Name; Source = $cat.Source }) }
    }
    foreach ($c in @($Config.customApps)) {
        [void]$list.Add(@{ Id = [string]$c.id; Name = [string]$c.name; Source = [string]$c.source })
    }
    return $list.ToArray()
}

function Install-QDApp {
    <#
    .SYNOPSIS
        מתקין תוכנה אחת דרך winget (בדיקת "כבר מותקן", scope machine, ניסיון חוזר ללא scope).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    $id = $App.Id
    $listArgs = @('list', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $list = Invoke-QDWinget -ArgumentList $listArgs
    if ($list.ExitCode -eq 0 -and ($list.Text -match [regex]::Escape($id))) {
        return @{ Status = 'AlreadyDone'; Message = 'כבר מותקן' }
    }
    if ($Sync.CatalogStatus.ContainsKey($id) -and $Sync.CatalogStatus[$id] -eq 'unavailable') {
        return @{ Status = 'Skipped'; Message = 'לא זמין במקור winget' }
    }
    $baseArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($App.Source -eq 'msstore') { $baseArgs += @('--source', 'msstore') }
    $okCodes = @(0, 3010, 1641, -1978335189, -1978335135, -1978334967)
    if ($Sync.Simulate) {
        $scopeNote = if ($App.Source -eq 'msstore') { '' } else { ' --scope machine' }
        Write-QDLog -Message ('[SIM] would winget ' + ($baseArgs -join ' ') + $scopeNote) -Level 'SIM'
        return @{ Status = 'Simulated'; Message = 'would install' }
    }
    $attempts = New-Object System.Collections.ArrayList
    if ($App.Source -ne 'msstore') { [void]$attempts.Add(@($baseArgs + @('--scope', 'machine'))) }
    [void]$attempts.Add($baseArgs)
    $last = $null
    foreach ($a in $attempts) {
        Write-QDLog -Message ('winget ' + ($a -join ' '))
        $last = Invoke-QDWinget -ArgumentList $a
        foreach ($l in ($last.Output | Select-Object -Last 15)) { Write-QDLog -Message ('    ' + $l) }
        if ($okCodes -contains $last.ExitCode) {
            if ($last.ExitCode -in @(3010, 1641, -1978334967)) { Add-QDRebootReason -Reason ('התקנת ' + $App.Name) }
            if ($last.ExitCode -in @(-1978335189, -1978335135)) { return @{ Status = 'AlreadyDone'; Message = 'כבר מותקן' } }
            $note = if ($a -contains '--scope') { 'הותקן (כל המשתמשים)' } else { 'הותקן' }
            return @{ Status = 'Success'; Message = $note }
        }
        if ($attempts.Count -gt 1 -and $a -contains '--scope') { Write-QDLog -Message 'ההתקנה עם --scope machine נכשלה — ניסיון חוזר ללא scope' -Level 'WARN' }
    }
    $reason = ($last.Output | Where-Object { $_ -notmatch '^(Found|נמצא)' } | Select-Object -Last 2) -join ' | '
    return @{ Status = 'Failed'; Message = ('winget קוד {0}: {1}' -f $last.ExitCode, $reason) }
}

function Invoke-QDAppInstall {
    <#
    .SYNOPSIS
        שלב 5: התקנת תוכנות דרך winget, עם התקדמות-משנה לכל תוכנה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $apps = @(Get-QDRunAppList -Config $Config)
    if ($apps.Count -eq 0) {
        Add-QDStepItem -Name 'התקנת תוכנות' -Status 'Skipped' -Message 'לא נבחרו תוכנות'
        return
    }
    $Sync.WingetPath = Resolve-QDWinget
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) {
        if ($Sync.Simulate) {
            Write-QDLog -Message '[SIM] would install App Installer (winget) from https://aka.ms/getwinget' -Level 'SIM'
        }
        else {
            $Sync.Activity = 'מתקין את winget…'
            try { Install-QDWinget } catch { Write-QDLog -Message ('התקנת winget נכשלה: ' + $_.Exception.Message) -Level 'ERROR' }
            $Sync.WingetPath = Resolve-QDWinget
        }
    }
    if ([string]::IsNullOrWhiteSpace($Sync.WingetPath) -and -not $Sync.Simulate) {
        Add-QDStepItem -Name 'winget' -Status 'Failed' -Message 'winget אינו מותקן ולא ניתן היה להתקין אותו (בדוק חיבור לאינטרנט / Microsoft Store)'
        foreach ($a in $apps) { Add-QDStepItem -Name $a.Name -Status 'Failed' -Message 'winget לא זמין' }
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($Sync.WingetPath)) {
        $Sync.Activity = 'מעדכן מקורות winget…'
        try { $null = Invoke-QDNativeAction -FilePath $Sync.WingetPath -ArgumentList @('source', 'update') }
        catch { Write-QDLog -Message ('winget source update: ' + $_.Exception.Message) -Level 'WARN' }
    }
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]
        $Sync.SubProgress = $i / $apps.Count
        $Sync.Activity = 'מתקין: {0} ({1}/{2})' -f $app.Name, ($i + 1), $apps.Count
        Send-QDPump -Force
        if (Test-QDCancel) {
            for ($j = $i; $j -lt $apps.Count; $j++) { Add-QDStepItem -Name $apps[$j].Name -Status 'Cancelled' -Message 'בוטל לפני ההתקנה' }
            break
        }
        $label = '{0} ({1})' -f $app.Name, $app.Id
        if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) {
            Add-QDStepItem -Name $label -Status 'Simulated' -Message 'would install (winget יותקן תחילה)'
            continue
        }
        Invoke-QDSubAction -Name $label -ScriptBlock { Install-QDApp -App $app }
    }
    $Sync.SubProgress = 1.0
}

#endregion Step 5

#region Step 6 — Network, drives, Wi-Fi, printers

function Get-QDWifiProfileXml {
    <#
    .SYNOPSIS
        בונה XML של פרופיל Wi-Fi עבור netsh wlan add profile.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Ssid,
        [ValidateSet('WPA2', 'WPA3')][string]$Security = 'WPA2',
        [Parameter(Mandatory)][string]$Key
    )
    $hex = -join ([System.Text.Encoding]::UTF8.GetBytes($Ssid) | ForEach-Object { $_.ToString('X2') })
    $auth = if ($Security -eq 'WPA3') { 'WPA3SAE' } else { 'WPA2PSK' }
    $ssidXml = [System.Security.SecurityElement]::Escape($Ssid)
    $keyXml = [System.Security.SecurityElement]::Escape($Key)
    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidXml</name>
  <SSIDConfig><SSID><hex>$hex</hex><name>$ssidXml</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption><authentication>$auth</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
      <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$keyXml</keyMaterial></sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
}

function ConvertFrom-QDSecureString {
    <#
    .SYNOPSIS
        ממיר SecureString לטקסט לצורך שימוש מיידי בלבד (לא נשמר).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-QDWqlEscaped {
    <#
    .SYNOPSIS
        מקודד מחרוזת לשימוש בתוך מסנן WQL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)
    return ($Text -replace '\\', '\\' -replace "'", "\'")
}

function Invoke-QDNetworkConfig {
    <#
    .SYNOPSIS
        שלב 6: כוננים ממופים, Wi-Fi ומדפסות.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $n = $Config.network
    $drives = @($n.drives)
    $wifi = @($n.wifi)
    $printers = @($n.printers)
    $total = [math]::Max(1, $drives.Count + $wifi.Count + $printers.Count)
    $done = 0
    if ($drives.Count + $wifi.Count + $printers.Count -eq 0) {
        Add-QDStepItem -Name 'רשת ומדפסות' -Status 'Skipped' -Message 'לא הוגדרו כוננים, רשתות או מדפסות'
        return
    }
    $iu = Get-QDInteractiveUser

    # --- Mapped drives ---
    if ($drives.Count -gt 0) {
        Invoke-QDSubAction -Name 'EnableLinkedConnections' -ScriptBlock {
            Write-QDRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLinkedConnections' -Value 1
            Add-QDRebootReason -Reason 'EnableLinkedConnections (כוננים ממופים)'
            'EnableLinkedConnections=1'
        }
        $userRoot = 'Registry::HKEY_CURRENT_USER'
        if ($null -ne $iu -and $iu.Sid -and (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $iu.Sid))) { $userRoot = 'Registry::HKEY_USERS\' + $iu.Sid }
        foreach ($dr in $drives) {
            $done++
            $Sync.SubProgress = $done / $total
            $letter = [string]$dr.letter
            $path = [string]$dr.path
            $label = [string]$dr.label
            Invoke-QDSubAction -Name ('כונן {0}: → {1}' -f $letter, $path) -ScriptBlock {
                if (-not (Test-QDUncPath -Path $path)) { throw 'נתיב UNC לא תקין' }
                $reachable = $false
                try { $reachable = Test-Path -LiteralPath $path -ErrorAction Stop } catch { $reachable = $false }
                $key = $userRoot + '\Network\' + $letter
                Write-QDRegistryValue -Path $key -Name 'RemotePath' -Value $path -Type 'String'
                Write-QDRegistryValue -Path $key -Name 'UserName' -Value '' -Type 'String'
                Write-QDRegistryValue -Path $key -Name 'ProviderName' -Value 'Microsoft Windows Network' -Type 'String'
                Write-QDRegistryValue -Path $key -Name 'ProviderType' -Value 0x20000 -Type 'DWord'
                Write-QDRegistryValue -Path $key -Name 'ConnectionType' -Value 1 -Type 'DWord'
                Write-QDRegistryValue -Path $key -Name 'DeferFlags' -Value 4 -Type 'DWord'
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    $mp = $userRoot + '\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\' + ($path -replace '\\', '#')
                    Write-QDRegistryValue -Path $mp -Name '_LabelFromReg' -Value $label -Type 'String'
                }
                $who = if ($null -ne $iu) { $iu.FullName } else { 'המשתמש הנוכחי' }
                if (-not $reachable) { @{ Status = 'Warning'; Message = "נשמר עבור $who, אך הנתיב אינו נגיש כעת" } }
                else { "נשמר עבור $who (יתחבר בכניסה הבאה)" }
            }
        }
    }

    # --- Wi-Fi ---
    foreach ($w in $wifi) {
        $done++
        $Sync.SubProgress = $done / $total
        $ssid = [string]$w.ssid
        $sec = [string]$w.security
        Invoke-QDSubAction -Name ('Wi-Fi: ' + $ssid) -ScriptBlock {
            if ($Sync.Silent) { return @{ Status = 'Skipped'; Message = 'דורש סיסמה — דולג במצב שקט' } }
            $secret = $null
            if ($Sync.Secrets.ContainsKey('Wifi') -and $Sync.Secrets['Wifi'].ContainsKey($ssid)) { $secret = $Sync.Secrets['Wifi'][$ssid] }
            if ($null -eq $secret) {
                if ($Sync.Simulate) { return @{ Status = 'Simulated'; Message = "would add WLAN profile ($sec)" } }
                return @{ Status = 'Skipped'; Message = 'לא הוזנה סיסמה' }
            }
            if (-not (Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue)) { throw 'שירות ה-WLAN אינו קיים במחשב (אין כרטיס אלחוטי?)' }
            $tmpFile = Join-Path $env:TEMP ('qd_wlan_' + [guid]::NewGuid().ToString('N') + '.xml')
            try {
                Invoke-QDAction -Description "netsh wlan add profile ($ssid, $sec)" -ScriptBlock {
                    $xml = Get-QDWifiProfileXml -Ssid $ssid -Security $sec -Key (ConvertFrom-QDSecureString -Secure $secret)
                    [System.IO.File]::WriteAllText($tmpFile, $xml, (New-Object System.Text.UTF8Encoding($false)))
                    $r = Invoke-QDNative -FilePath 'netsh.exe' -ArgumentList @('wlan', 'add', 'profile', ('filename="{0}"' -f $tmpFile), 'user=all')
                    if ($r.ExitCode -ne 0) { throw ('netsh נכשל: ' + $r.Text) }
                }
            }
            finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
            "פרופיל $sec נוסף לכל המשתמשים"
        }
    }

    # --- Printers ---
    $pi = 0
    foreach ($pr in $printers) {
        $done++
        $pi++
        $Sync.SubProgress = $done / $total
        if ($pr.type -eq 'unc') {
            $uncPath = [string]$pr.path
            $isDefault = [bool]$pr.default
            $taskName = 'QuickDeploy_Printer_{0}_{1}' -f $pi, (Get-Date -Format 'HHmmss')
            Invoke-QDSubAction -Name ('מדפסת משותפת: ' + $uncPath) -ScriptBlock {
                if (-not (Test-QDUncPath -Path $uncPath)) { throw 'נתיב מדפסת UNC לא תקין' }
                if ($null -eq $iu) { throw 'לא נמצא משתמש מחובר (explorer.exe) — לא ניתן להוסיף מדפסת משותפת' }
                $p = $uncPath -replace "'", "''"
                $cmd = "try { Add-Printer -ConnectionName '$p' -ErrorAction Stop } catch { }"
                if ($isDefault) {
                    $wql = (Get-QDWqlEscaped -Text $uncPath) -replace "'", "''"
                    $cmd += "; try { Get-CimInstance -ClassName Win32_Printer -Filter 'Name=''$wql''' | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null } catch { }"
                }
                $cmd += "; Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue"
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
                Invoke-QDAction -Description "Register-ScheduledTask $taskName (Add-Printer -ConnectionName $uncPath as $($iu.FullName))" -ScriptBlock {
                    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
                    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $iu.FullName
                    $trigger.EndBoundary = (Get-Date).AddDays(7).ToString('s')
                    $principal = New-ScheduledTaskPrincipal -UserId $iu.FullName -LogonType Interactive -RunLevel Limited
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)
                    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop
                    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                }
                "נוסף דרך משימה מתוזמנת חד-פעמית עבור $($iu.FullName)"
            }
            continue
        }
        $pName = [string]$pr.name
        $ip = [string]$pr.ip
        $driver = [string]$pr.driver
        if ([string]::IsNullOrWhiteSpace($driver)) { $driver = 'Microsoft IPP Class Driver' }
        $isDefaultIp = [bool]$pr.default
        $testPage = [bool]$pr.testPage
        Invoke-QDSubAction -Name ('מדפסת {0} ({1})' -f $pName, $ip) -ScriptBlock {
            if (-not (Test-QDIPv4 -Address $ip)) { throw 'כתובת IP לא תקינה' }
            if ([string]::IsNullOrWhiteSpace($pName)) { throw 'חסר שם מדפסת' }
            $warnings = New-Object System.Collections.Generic.List[string]
            $reach = $false
            try { $reach = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction Stop } catch { $reach = $false }
            if (-not $reach) { $warnings.Add("הכתובת $ip אינה מגיבה לפינג") }
            $portName = 'IP_' + $ip
            if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
                Invoke-QDAction -Description "Add-PrinterPort -Name $portName -PrinterHostAddress $ip" -ScriptBlock { Add-PrinterPort -Name $portName -PrinterHostAddress $ip -ErrorAction Stop }
            }
            if (-not (Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue)) {
                Invoke-QDAction -Description "Add-PrinterDriver -Name '$driver'" -ScriptBlock { Add-PrinterDriver -Name $driver -ErrorAction Stop }
            }
            $existed = [bool](Get-Printer -Name $pName -ErrorAction SilentlyContinue)
            if (-not $existed) {
                Invoke-QDAction -Description "Add-Printer -Name '$pName' -DriverName '$driver' -PortName $portName" -ScriptBlock { Add-Printer -Name $pName -DriverName $driver -PortName $portName -ErrorAction Stop }
            }
            $wql = Get-QDWqlEscaped -Text $pName
            if ($isDefaultIp) {
                Invoke-QDAction -Description "SetDefaultPrinter '$pName'" -ScriptBlock {
                    Get-CimInstance -ClassName Win32_Printer -Filter ("Name='{0}'" -f $wql) -ErrorAction Stop | Invoke-CimMethod -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
                }
                Write-QDUserValue -SubKey 'Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name 'LegacyDefaultPrinterMode' -Value 1 -SkipDefaultHive
            }
            if ($testPage) {
                Invoke-QDAction -Description "PrintTestPage '$pName'" -ScriptBlock {
                    Get-CimInstance -ClassName Win32_Printer -Filter ("Name='{0}'" -f $wql) -ErrorAction Stop | Invoke-CimMethod -MethodName PrintTestPage -ErrorAction Stop | Out-Null
                }
            }
            $msg = if ($existed) { 'המדפסת כבר קיימת' } else { "נוספה עם $driver" }
            if ($isDefaultIp) { $msg += '; ברירת מחדל' }
            if ($testPage) { $msg += '; נשלח דף ניסיון' }
            if ($warnings.Count -gt 0) { @{ Status = 'Warning'; Message = ($msg + ' — ' + ($warnings -join '; ')) } }
            elseif ($existed -and -not $Sync.Simulate) { @{ Status = 'AlreadyDone'; Message = $msg } }
            else { $msg }
        }
    }
    $Sync.SubProgress = 1.0
}

#endregion Step 6

#region Step 7 — Computer name & domain

function Invoke-QDIdentity {
    <#
    .SYNOPSIS
        שלב 7 (אחרון): קבוצת עבודה / דומיין, שינוי שם מחשב, וסריקת Windows Update.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $n = $Config.network
    $newName = ([string]$Config.computerName).Trim()
    $renamePending = (-not [string]::IsNullOrWhiteSpace($newName)) -and ($newName -ne $env:COMPUTERNAME)
    if ($renamePending) {
        $err = Test-QDComputerName -Name $newName
        if ($err) {
            Add-QDStepItem -Name ('שם מחשב: ' + $newName) -Status 'Failed' -Message $err
            $renamePending = $false
        }
    }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $state = @{ RenamePending = $renamePending }

    if ($n.joinType -eq 'domain') {
        Invoke-QDSubAction -Name ('הצטרפות לדומיין ' + $n.domain) -ScriptBlock {
            if ($Sync.Silent) { return @{ Status = 'Skipped'; Message = 'דורש פרטי הזדהות — דולג במצב שקט' } }
            if ($cs.PartOfDomain -and $cs.Domain -eq $n.domain) { return @{ Status = 'AlreadyDone'; Message = 'המחשב כבר חבר בדומיין' } }
            $cred = $null
            if ($Sync.Secrets.ContainsKey('DomainCredential')) { $cred = $Sync.Secrets['DomainCredential'] }
            if ($null -eq $cred) {
                if ($Sync.Simulate) {
                    $sim = "would Add-Computer -DomainName $($n.domain)"
                    if ($state.RenamePending) { $sim += " -NewName $newName"; $state.RenamePending = $false }
                    Write-QDLog -Message ('[SIM] ' + $sim) -Level 'SIM'
                    return @{ Status = 'Simulated'; Message = $sim }
                }
                return @{ Status = 'Skipped'; Message = 'לא הוזנו פרטי הזדהות לדומיין' }
            }
            $joinArgs = @{ DomainName = $n.domain; Credential = $cred; Force = $true; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($n.ou)) { $joinArgs['OUPath'] = $n.ou }
            if ($renamePending) { $joinArgs['NewName'] = $newName }
            Invoke-QDAction -Description ("Add-Computer -DomainName {0}{1}{2}" -f $n.domain, $(if ($n.ou) { " -OUPath '$($n.ou)'" } else { '' }), $(if ($renamePending) { " -NewName $newName" } else { '' })) -ScriptBlock {
                Add-Computer @joinArgs
            }
            Add-QDRebootReason -Reason 'הצטרפות לדומיין'
            if ($renamePending) {
                $state.RenamePending = $false
                Add-QDStepItem -Name ('שם מחשב: ' + $newName) -Status $(if ($Sync.Simulate) { 'Simulated' } else { 'Success' }) -Message 'שונה יחד עם ההצטרפות לדומיין'
            }
            "הצטרף ל-$($n.domain)"
        }
    }
    elseif ($n.joinType -eq 'workgroup') {
        Invoke-QDSubAction -Name ('קבוצת עבודה: ' + $n.workgroup) -ScriptBlock {
            if ([string]::IsNullOrWhiteSpace($n.workgroup)) { throw 'לא הוזן שם קבוצת עבודה' }
            if ($cs.PartOfDomain) { throw 'המחשב חבר בדומיין — יציאה מדומיין אינה נתמכת בכלי (נדרשים פרטי מנהל דומיין)' }
            if ($cs.Workgroup -eq $n.workgroup) { return @{ Status = 'AlreadyDone'; Message = 'כבר מוגדר' } }
            Invoke-QDAction -Description "Add-Computer -WorkgroupName $($n.workgroup)" -ScriptBlock { Add-Computer -WorkgroupName $n.workgroup -Force -ErrorAction Stop -WarningAction SilentlyContinue }
            Add-QDRebootReason -Reason 'שינוי קבוצת עבודה'
            "הוגדר $($n.workgroup)"
        }
    }
    $Sync.SubProgress = 0.5
    if ($state.RenamePending) {
        Invoke-QDSubAction -Name ('שם מחשב: ' + $newName) -ScriptBlock {
            Invoke-QDAction -Description "Rename-Computer -NewName $newName" -ScriptBlock { Rename-Computer -NewName $newName -Force -ErrorAction Stop -WarningAction SilentlyContinue }
            Add-QDRebootReason -Reason 'שינוי שם מחשב'
            "$env:COMPUTERNAME → $newName"
        }
    }
    $Sync.SubProgress = 0.8
    if ($Config.system.windowsUpdateScan) {
        Invoke-QDSubAction -Name 'סריקת Windows Update' -ScriptBlock {
            $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
            if (-not (Test-Path -LiteralPath $uso)) { return @{ Status = 'Skipped'; Message = 'UsoClient לא נמצא' } }
            Invoke-QDAction -Description 'UsoClient StartInteractiveScan' -ScriptBlock { Start-Process -FilePath $uso -ArgumentList 'StartInteractiveScan' -WindowStyle Hidden -ErrorAction Stop }
            'הסריקה הופעלה ברקע'
        }
    }
    if (@($Sync.Steps[$Sync.StepIndex].Items).Count -eq 0) {
        Add-QDStepItem -Name 'שם מחשב ודומיין' -Status 'Skipped' -Message 'אין שינוי'
    }
    $Sync.SubProgress = 1.0
}

#endregion Step 7

#region Pipeline runner

function Invoke-QDPipeline {
    <#
    .SYNOPSIS
        מריץ את כל שלבי ההקמה לפי הסדר. שלב שנכשל לעולם אינו עוצר את הצינור.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $Sync.Running = $true
    $Sync.RunStart = Get-Date
    Initialize-QDStepState
    $mode = if ($Sync.Simulate) { 'סימולציה' } else { 'ביצוע אמיתי' }
    Write-QDLog -Message ('התחלת הרצה — פרופיל "{0}", מצב: {1}' -f $Config.name, $mode) -Level 'STEP'
    try {
        for ($i = 0; $i -lt $Sync.Steps.Count; $i++) {
            $step = $Sync.Steps[$i]
            if ($Sync.Cancel -and $step.Id -ne 'report') {
                $step.Status = 'Cancelled'
                Write-QDLog -Message ('{0} — בוטל' -f $step.Title) -Level 'WARN'
                Sync-QDProgress
                Send-QDPump -Force
                continue
            }
            Enter-QDStep -Index $i
            try {
                switch ($step.Id) {
                    'preflight' { Invoke-QDPreflight -Config $Config }
                    'restore' { Invoke-QDRestorePoint -Config $Config }
                    'debloat' { Invoke-QDDebloat -Config $Config }
                    'system' { Invoke-QDSystemConfig -Config $Config }
                    'apps' { Invoke-QDAppInstall -Config $Config }
                    'network' { Invoke-QDNetworkConfig -Config $Config }
                    'identity' { Invoke-QDIdentity -Config $Config }
                    'report' { Invoke-QDReportStep -Config $Config }
                }
                Complete-QDStep
            }
            catch {
                Add-QDStepItem -Name 'שגיאה בשלב' -Status 'Failed' -Message $_.Exception.Message
                Complete-QDStep -ForceStatus 'Failed'
            }
        }
    }
    catch {
        $Sync.FatalError = $_.Exception.Message
        Write-QDLog -Message ('שגיאה קריטית: ' + $_.Exception.Message) -Level 'ERROR'
    }
    finally {
        $Sync.RunEnd = Get-Date
        $failed = @($Sync.Steps | Where-Object { $_.Status -in @('Failed', 'Partial') }).Count
        if ($Sync.FatalError) { $Sync.ExitCode = 2 }
        elseif ($failed -gt 0) { $Sync.ExitCode = 1 }
        else { $Sync.ExitCode = 0 }
        $Sync.Progress = 100
        $Sync.Activity = if ($Sync.Cancel) { 'ההרצה בוטלה' } elseif ($Sync.ExitCode -eq 0) { 'ההרצה הושלמה בהצלחה' } else { 'ההרצה הושלמה עם שגיאות' }
        Write-QDLog -Message ('סיום הרצה — קוד יציאה {0}' -f $Sync.ExitCode) -Level 'STEP'
        $Sync.Running = $false
        $Sync.Done = $true
        Send-QDPump -Force
    }
}

#endregion Pipeline runner


#region Step 8 — HTML report

function Get-QDReportIcon {
    <#
    .SYNOPSIS
        מחזיר אייקון SVG inline לדוח.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [string]$Color = 'currentColor', [int]$Size = 18)
    $paths = @{
        check   = 'M4 12.5l5.5 5.5L20 6'
        x       = 'M6 6l12 12M18 6L6 18'
        alert   = 'M12 3l10 17H2L12 3zM12 10v4M12 17v.5'
        info    = 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 11v6M12 7.5v.5'
        skip    = 'M5 12h14M13 6l6 6-6 6'
        monitor = 'M3 4h18v12H3zM8 21h8M12 16v5'
        report  = 'M6 2h8l6 6v14H6zM14 2v6h6M9 13h8M9 17h5'
        power   = 'M12 2v10M6.3 6.3a8 8 0 1 0 11.4 0'
        clock   = 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2'
        user    = 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4.5 3.5-7 8-7s8 2.5 8 7'
    }
    $d = if ($paths.ContainsKey($Name)) { $paths[$Name] } else { $paths['info'] }
    return ('<svg width="{0}" height="{0}" viewBox="0 0 24 24" fill="none" stroke="{1}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{2}"/></svg>' -f $Size, $Color, $d)
}

function Build-QDReport {
    <#
    .SYNOPSIS
        בונה דוח HTML עצמאי (CSS ו-SVG מוטמעים, RTL, ערכת צבעים כהה).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $info = Get-QDSystemInfo
    $steps = @($Sync.Steps)
    $allItems = @($steps | ForEach-Object { @($_.Items) })
    $countable = @($allItems | Where-Object { $_.Status -in @('Success', 'AlreadyDone', 'Simulated', 'Failed', 'Warning') })
    $good = @($countable | Where-Object { $_.Status -in @('Success', 'AlreadyDone', 'Simulated', 'Warning') }).Count
    $rate = if ($countable.Count -gt 0) { [math]::Round(($good / $countable.Count) * 100) } else { 100 }
    $failedItems = @($allItems | Where-Object { $_.Status -eq 'Failed' })
    $end = if ($null -ne $Sync.RunEnd) { $Sync.RunEnd } else { Get-Date }
    $start = if ($null -ne $Sync.RunStart) { $Sync.RunStart } else { $end }
    $dur = $end - $start
    $durText = '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($dur.TotalHours), $dur.Minutes, $dur.Seconds
    $circ = [math]::Round(2 * [math]::PI * 52, 2)
    $offset = [math]::Round($circ * (1 - ($rate / 100)), 2)
    $ringColor = if ($rate -ge 90) { '#2DD4BF' } elseif ($rate -ge 60) { '#FBBF24' } else { '#F87171' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@'
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>QuickDeploy — דוח הקמה</title>
<style>
:root{--bg:#0D1015;--card:#161A21;--border:#232935;--text:#F2F4F7;--muted:#8A93A3;--accent:#F5A524;--ok:#2DD4BF;--warn:#FBBF24;--err:#F87171}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:"Segoe UI Variable Display","Segoe UI",system-ui,sans-serif;font-size:14px;line-height:1.55;
background-image:radial-gradient(ellipse 80% 60% at 50% 0%,rgba(245,165,36,.2),transparent 70%);background-attachment:fixed;min-height:100vh}
.wrap{max-width:1100px;margin:0 auto;padding:32px 16px 64px}
header{display:flex;align-items:center;gap:24px;flex-wrap:wrap;margin-bottom:24px}
h1{font-size:30px;font-weight:700;margin:0}
h2{font-size:18px;font-weight:600;margin:0 0 14px;display:flex;align-items:center;gap:10px}
.sub{color:var(--muted)}
.ltr{direction:ltr;unicode-bidi:isolate;display:inline-block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;margin-bottom:12px;animation:rise .4s cubic-bezier(.2,.8,.2,1) both}
@keyframes rise{from{transform:translateY(8px)}to{transform:none}}
@media (prefers-reduced-motion:reduce){.card{animation:none}}
.kv{display:flex;flex-direction:column;gap:2px}.kv .k{color:var(--muted);font-size:12px}.kv .v{font-weight:600;word-break:break-word}
.ring{position:relative;width:132px;height:132px;flex:none}
.ring svg{transform:rotate(-90deg)}
.ring .pct{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}
.ring .pct b{font-size:25px}.ring .pct span{font-size:12px;color:var(--muted)}
.banner{display:flex;gap:12px;align-items:flex-start;border-radius:16px;padding:16px 20px;margin-bottom:12px;border:1px solid}
.banner.warn{background:rgba(251,191,36,.08);border-color:rgba(251,191,36,.35);color:var(--warn)}
.banner.sim{background:rgba(245,165,36,.08);border-color:rgba(245,165,36,.35);color:var(--accent)}
.banner p{margin:4px 0 0;color:var(--text)}
.pill{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;white-space:nowrap}
table{width:100%;border-collapse:collapse}
td,th{padding:9px 8px;border-top:1px solid var(--border);text-align:right;vertical-align:top}
th{color:var(--muted);font-weight:500;font-size:12px;border-top:none}
td.msg{color:var(--muted);word-break:break-word}
.step-head{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
.step-meta{color:var(--muted);font-size:12px}
.err li{margin-bottom:6px}
footer{color:var(--muted);font-size:12px;text-align:center;margin-top:24px}
@media (max-width:600px){h1{font-size:24px}.ring{width:110px;height:110px}td,th{padding:8px 4px}}
</style>
</head>
<body><div class="wrap">
'@)

    # Header with ring
    [void]$sb.Append('<header><div class="ring"><svg width="132" height="132" viewBox="0 0 132 132">')
    [void]$sb.Append('<circle cx="66" cy="66" r="52" fill="none" stroke="#232935" stroke-width="12"/>')
    [void]$sb.Append(('<circle cx="66" cy="66" r="52" fill="none" stroke="{0}" stroke-width="12" stroke-linecap="round" stroke-dasharray="{1}" stroke-dashoffset="{2}"/>' -f $ringColor, $circ, $offset))
    [void]$sb.Append(('</svg><div class="pct"><b>{0}%</b><span>הצלחה</span></div></div>' -f $rate))
    [void]$sb.Append('<div><h1>דוח הקמת מחשב</h1>')
    [void]$sb.Append(('<div class="sub"><span class="ltr">{0}</span> · פרופיל: {1} · {2}</div></div></header>' -f (ConvertTo-QDHtml $info.ComputerName), (ConvertTo-QDHtml ([string]$Config.name)), (ConvertTo-QDHtml ($start.ToString('dd/MM/yyyy HH:mm')))))

    if ($Sync.Simulate) {
        [void]$sb.Append(('<div class="banner sim">{0}<div><b>מצב סימולציה</b><p>לא בוצע שום שינוי במערכת. כל הפעולות נרשמו בלבד.</p></div></div>' -f (Get-QDReportIcon -Name 'info' -Color '#F5A524' -Size 22)))
    }
    if ($Sync.RebootRequired) {
        $reasons = (@($Sync.RebootReasons) | ForEach-Object { ConvertTo-QDHtml $_ }) -join ' · '
        [void]$sb.Append(('<div class="banner warn">{0}<div><b>נדרשת הפעלה מחדש</b><p>{1}</p></div></div>' -f (Get-QDReportIcon -Name 'power' -Color '#FBBF24' -Size 22), $reasons))
    }

    # Run summary
    [void]$sb.Append(('<div class="card"><h2>{0}סיכום הרצה</h2><div class="grid">' -f (Get-QDReportIcon -Name 'clock' -Color '#F5A524')))
    $mode = if ($Sync.Simulate) { 'כן' } else { 'לא' }
    $kv = [ordered]@{ 'התחלה' = $start.ToString('dd/MM/yyyy HH:mm:ss'); 'סיום' = $end.ToString('dd/MM/yyyy HH:mm:ss'); 'משך' = $durText; 'סימולציה' = $mode; 'פעולות שהצליחו' = "$good / $($countable.Count)"; 'שגיאות' = [string]$failedItems.Count }
    foreach ($k in $kv.Keys) { [void]$sb.Append(('<div class="kv"><span class="k">{0}</span><span class="v" dir="auto">{1}</span></div>' -f (ConvertTo-QDHtml $k), (ConvertTo-QDHtml ([string]$kv[$k])))) }
    [void]$sb.Append('</div></div>')

    # Machine info
    [void]$sb.Append(('<div class="card"><h2>{0}פרטי המחשב</h2><div class="grid">' -f (Get-QDReportIcon -Name 'monitor' -Color '#F5A524')))
    $mi = [ordered]@{ 'שם מחשב' = $info.ComputerName; 'דגם' = $info.Model; 'מספר סידורי' = $info.Serial; 'מערכת הפעלה' = ('{0} (Build {1})' -f $info.OS, $info.Build); 'מעבד' = $info.CPU; 'זיכרון' = $info.RamGB; 'כונן מערכת' = $info.DiskFree; 'רשת' = $info.Domain }
    foreach ($k in $mi.Keys) { [void]$sb.Append(('<div class="kv"><span class="k">{0}</span><span class="v" dir="auto">{1}</span></div>' -f (ConvertTo-QDHtml $k), (ConvertTo-QDHtml ([string]$mi[$k])))) }
    [void]$sb.Append('</div></div>')

    # Steps
    foreach ($st in $steps) {
        $color = $QD.StatusColor[[string]$st.Status]
        [void]$sb.Append('<div class="card"><div class="step-head">')
        [void]$sb.Append(('<h2>{0}</h2>' -f (ConvertTo-QDHtml $st.Title)))
        [void]$sb.Append(('<div><span class="step-meta">{0}</span> <span class="pill" style="background:{1}22;color:{1}">{2}</span></div></div>' -f (ConvertTo-QDHtml $st.Duration), $color, (ConvertTo-QDHtml $QD.StatusText[[string]$st.Status])))
        $items = @($st.Items)
        if ($items.Count -gt 0) {
            [void]$sb.Append('<table><thead><tr><th>פעולה</th><th>תוצאה</th><th>פירוט</th></tr></thead><tbody>')
            foreach ($it in $items) {
                $ic = $QD.StatusColor[[string]$it.Status]
                $iconName = switch ($it.Status) { 'Success' { 'check' } 'AlreadyDone' { 'check' } 'Failed' { 'x' } 'Warning' { 'alert' } 'Skipped' { 'skip' } 'Cancelled' { 'skip' } default { 'info' } }
                [void]$sb.Append(('<tr><td>{0}</td><td><span class="pill" style="background:{1}22;color:{1}">{2}{3}</span></td><td class="msg">{4}</td></tr>' -f (ConvertTo-QDHtml $it.Name), $ic, (Get-QDReportIcon -Name $iconName -Color $ic -Size 13), (ConvertTo-QDHtml $QD.StatusText[[string]$it.Status]), (ConvertTo-QDHtml ([string]$it.Message))))
            }
            [void]$sb.Append('</tbody></table>')
        }
        else {
            [void]$sb.Append('<div class="sub">אין פעולות בשלב זה.</div>')
        }
        [void]$sb.Append('</div>')
    }

    # Printers & drives summary
    $n = $Config.network
    if (@($n.drives).Count + @($n.printers).Count -gt 0) {
        [void]$sb.Append(('<div class="card"><h2>{0}מדפסות וכוננים שהוגדרו</h2><table><thead><tr><th>סוג</th><th>שם</th><th>יעד</th></tr></thead><tbody>' -f (Get-QDReportIcon -Name 'report' -Color '#F5A524')))
        foreach ($dr in @($n.drives)) { [void]$sb.Append(('<tr><td>כונן</td><td>{0}:</td><td><span class="ltr">{1}</span></td></tr>' -f (ConvertTo-QDHtml $dr.letter), (ConvertTo-QDHtml $dr.path))) }
        foreach ($pr in @($n.printers)) {
            $target = if ($pr.type -eq 'unc') { $pr.path } else { $pr.ip }
            $name = if ($pr.default) { $pr.name + ' (ברירת מחדל)' } else { $pr.name }
            [void]$sb.Append(('<tr><td>מדפסת</td><td>{0}</td><td><span class="ltr">{1}</span></td></tr>' -f (ConvertTo-QDHtml $name), (ConvertTo-QDHtml $target)))
        }
        [void]$sb.Append('</tbody></table></div>')
    }

    # Errors
    if ($failedItems.Count -gt 0) {
        [void]$sb.Append(('<div class="card"><h2>{0}שגיאות</h2><ul class="err">' -f (Get-QDReportIcon -Name 'alert' -Color '#F87171')))
        foreach ($f in $failedItems) { [void]$sb.Append(('<li><b>{0}</b> — <span class="sub">{1}</span></li>' -f (ConvertTo-QDHtml $f.Name), (ConvertTo-QDHtml ([string]$f.Message)))) }
        [void]$sb.Append('</ul></div>')
    }
    [void]$sb.Append(('<footer>QuickDeploy {0} · יומן: <span class="ltr">{1}</span></footer>' -f $QD.Version, (ConvertTo-QDHtml $Sync.LogPath)))
    [void]$sb.Append('</div></body></html>')

    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    return $Path
}

function Invoke-QDReportStep {
    <#
    .SYNOPSIS
        שלב 8: יצירת דוח HTML (נוצר גם במצב סימולציה וגם אחרי ביטול).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $ErrorActionPreference = 'Stop'
    $path = Join-Path $QD.ReportsDir ('Report_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $step = $Sync.Steps[$Sync.StepIndex]
    $step.Status = 'Success'
    $Sync.RunEnd = Get-Date
    try {
        $null = Build-QDReport -Config $Config -Path $path
        $Sync.ReportPath = $path
        Add-QDStepItem -Name 'דוח HTML' -Status 'Success' -Message $path
    }
    catch {
        Add-QDStepItem -Name 'דוח HTML' -Status 'Failed' -Message $_.Exception.Message
    }
}

#endregion Step 8


#region XAML — resources (palette, icons, control templates)

$script:ResourcesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

    <!-- Palette -->
    <SolidColorBrush x:Key="BgBrush" Color="#0D1015"/>
    <SolidColorBrush x:Key="CardBrush" Color="#161A21"/>
    <SolidColorBrush x:Key="CardBorderBrush" Color="#232935"/>
    <SolidColorBrush x:Key="CardHoverBorderBrush" Color="#3A4252"/>
    <SolidColorBrush x:Key="TextPrimaryBrush" Color="#F2F4F7"/>
    <SolidColorBrush x:Key="TextSecondaryBrush" Color="#8A93A3"/>
    <SolidColorBrush x:Key="TextFaintBrush" Color="#5B6474"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#F5A524"/>
    <SolidColorBrush x:Key="AccentSoftBrush" Color="#26F5A524"/>
    <SolidColorBrush x:Key="SuccessBrush" Color="#2DD4BF"/>
    <SolidColorBrush x:Key="WarningBrush" Color="#FBBF24"/>
    <SolidColorBrush x:Key="ErrorBrush" Color="#F87171"/>
    <SolidColorBrush x:Key="InputBrush" Color="#11151B"/>
    <SolidColorBrush x:Key="SubtleBrush" Color="#1B2029"/>
    <SolidColorBrush x:Key="HoverBrush" Color="#222834"/>
    <FontFamily x:Key="UiFont">Segoe UI Variable Display, Segoe UI</FontFamily>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas, Courier New</FontFamily>

    <!-- Vector icons (24x24 grid, stroked) -->
    <Geometry x:Key="IconHome">M3,11 L12,3 L21,11 M5,9.5 L5,21 L19,21 L19,9.5 M10,21 L10,14 L14,14 L14,21</Geometry>
    <Geometry x:Key="IconProfile">M12,12 A4,4 0 1 0 12,4 A4,4 0 1 0 12,12 Z M4,21 C4,16.5 7.5,14 12,14 C16.5,14 20,16.5 20,21</Geometry>
    <Geometry x:Key="IconPackage">M12,2 L21,7 L21,17 L12,22 L3,17 L3,7 Z M3,7 L12,12 L21,7 M12,12 L12,22 M7.5,4.5 L16.5,9.5</Geometry>
    <Geometry x:Key="IconBroom">M20,3 L13,10 M8.5,9.5 L14.5,15.5 L11,21 L3,21 L3,13 Z M6.5,21 L8.5,17 M3,17.5 L6,16</Geometry>
    <Geometry x:Key="IconGear">M12,15.5 A3.5,3.5 0 1 0 12,8.5 A3.5,3.5 0 1 0 12,15.5 Z M12,2 L12,5 M12,19 L12,22 M2,12 L5,12 M19,12 L22,12 M4.9,4.9 L7,7 M17,17 L19.1,19.1 M4.9,19.1 L7,17 M17,7 L19.1,4.9</Geometry>
    <Geometry x:Key="IconNetwork">M2,9 C8,3.5 16,3.5 22,9 M5,12.5 C9,8.8 15,8.8 19,12.5 M8.5,16 C10.5,14.3 13.5,14.3 15.5,16 M12,21 A1.2,1.2 0 1 0 12,18.6 A1.2,1.2 0 1 0 12,21 Z</Geometry>
    <Geometry x:Key="IconPrinter">M6,9 L6,2 L18,2 L18,9 M6,18 L4,18 A2,2 0 0 1 2,16 L2,11 A2,2 0 0 1 4,9 L20,9 A2,2 0 0 1 22,11 L22,16 A2,2 0 0 1 20,18 L18,18 M6,14 L18,14 L18,22 L6,22 Z</Geometry>
    <Geometry x:Key="IconPlay">M7,4 L20,12 L7,20 Z</Geometry>
    <Geometry x:Key="IconCheck">M4,12.5 L9.5,18 L20,6</Geometry>
    <Geometry x:Key="IconX">M6,6 L18,18 M18,6 L6,18</Geometry>
    <Geometry x:Key="IconAlert">M12,3 L22,20 L2,20 Z M12,9.5 L12,14 M12,17 L12,17.2</Geometry>
    <Geometry x:Key="IconSave">M5,3 L16,3 L21,8 L21,21 L3,21 L3,3 Z M7,3 L7,8 L15,8 L15,3 M7,21 L7,14 L17,14 L17,21</Geometry>
    <Geometry x:Key="IconFolder">M3,6 A1,1 0 0 1 4,5 L9,5 L11,7 L20,7 A1,1 0 0 1 21,8 L21,18 A1,1 0 0 1 20,19 L4,19 A1,1 0 0 1 3,18 Z</Geometry>
    <Geometry x:Key="IconRefresh">M20,11 A8,8 0 1 0 17.7,17.7 M20,4 L20,11 L13,11</Geometry>
    <Geometry x:Key="IconReport">M6,2 L14,2 L20,8 L20,22 L6,22 Z M14,2 L14,8 L20,8 M9,13 L17,13 M9,17 L14,17</Geometry>
    <Geometry x:Key="IconSearch">M11,18 A7,7 0 1 0 11,4 A7,7 0 1 0 11,18 Z M16.2,16.2 L21,21</Geometry>
    <Geometry x:Key="IconPlus">M12,5 L12,19 M5,12 L19,12</Geometry>
    <Geometry x:Key="IconTrash">M4,7 L20,7 M9,7 L9,4 L15,4 L15,7 M6,7 L7,21 L17,21 L18,7 M10,11 L10,17 M14,11 L14,17</Geometry>
    <Geometry x:Key="IconCopy">M8,8 L20,8 L20,20 L8,20 Z M16,8 L16,4 L4,4 L4,16 L8,16</Geometry>
    <Geometry x:Key="IconImport">M12,3 L12,15 M7,10 L12,15 L17,10 M4,17 L4,21 L20,21 L20,17</Geometry>
    <Geometry x:Key="IconExport">M12,15 L12,3 M7,8 L12,3 L17,8 M4,17 L4,21 L20,21 L20,17</Geometry>
    <Geometry x:Key="IconMonitor">M3,4 L21,4 L21,16 L3,16 Z M8,21 L16,21 M12,16 L12,21</Geometry>
    <Geometry x:Key="IconInfo">M12,22 A10,10 0 1 0 12,2 A10,10 0 1 0 12,22 Z M12,11 L12,17 M12,7.5 L12,7.7</Geometry>
    <Geometry x:Key="IconStop">M6,6 L18,6 L18,18 L6,18 Z</Geometry>
    <Geometry x:Key="IconPower">M12,2 L12,12 M6.3,6.3 A8,8 0 1 0 17.7,6.3</Geometry>
    <Geometry x:Key="IconShield">M12,2 L20,5 L20,11 C20,16 16.5,20 12,22 C7.5,20 4,16 4,11 L4,5 Z M8.5,12 L11,14.5 L15.5,10</Geometry>
    <Geometry x:Key="IconDrive">M3,14 L21,14 L21,20 L3,20 Z M3,14 L6,5 L18,5 L21,14 M16.5,17 L17,17</Geometry>
    <Geometry x:Key="IconWifi">M2,9 C8,3.5 16,3.5 22,9 M5,12.5 C9,8.8 15,8.8 19,12.5 M8.5,16 C10.5,14.3 13.5,14.3 15.5,16 M12,20 L12,20.2</Geometry>
    <Geometry x:Key="IconMinimize">M5,12 L19,12</Geometry>
    <Geometry x:Key="IconMaximize">M5,5 L19,5 L19,19 L5,19 Z</Geometry>
    <Geometry x:Key="IconRestore">M8,8 L19,8 L19,19 L8,19 Z M5,16 L5,5 L16,5</Geometry>
    <Geometry x:Key="IconBolt">M13,2 L4,14 L11,14 L10,22 L20,9 L13,9 Z</Geometry>
    <Geometry x:Key="IconClock">M12,22 A10,10 0 1 0 12,2 A10,10 0 1 0 12,22 Z M12,6 L12,12 L16,14</Geometry>
    <Geometry x:Key="IconGlobe">M12,22 A10,10 0 1 0 12,2 A10,10 0 1 0 12,22 Z M2,12 L22,12 M12,2 C15,5 16,9 16,12 C16,15 15,19 12,22 C9,19 8,15 8,12 C8,9 9,5 12,2 Z</Geometry>
    <Geometry x:Key="IconCpu">M6,6 L18,6 L18,18 L6,18 Z M9,9 L15,9 L15,15 L9,15 Z M9,2 L9,6 M15,2 L15,6 M9,18 L9,22 M15,18 L15,22 M2,9 L6,9 M2,15 L6,15 M18,9 L22,9 M18,15 L22,15</Geometry>
    <Geometry x:Key="IconBattery">M3,7 L18,7 L18,17 L3,17 Z M21,10 L21,14 M6,10 L6,14 M9,10 L9,14</Geometry>
    <Geometry x:Key="IconTag">M3,3 L11,3 L21,13 L13,21 L3,11 Z M7.5,7.5 L7.6,7.6</Geometry>

    <Style x:Key="Icon" TargetType="Path">
        <Setter Property="Width" Value="18"/>
        <Setter Property="Height" Value="18"/>
        <Setter Property="Stretch" Value="Uniform"/>
        <Setter Property="StrokeThickness" Value="1.8"/>
        <Setter Property="StrokeStartLineCap" Value="Round"/>
        <Setter Property="StrokeEndLineCap" Value="Round"/>
        <Setter Property="StrokeLineJoin" Value="Round"/>
        <Setter Property="Stroke" Value="{Binding Path=(TextElement.Foreground), RelativeSource={RelativeSource Self}}"/>
        <Setter Property="FlowDirection" Value="LeftToRight"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <!-- Typography -->
    <Style x:Key="PageTitle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="30"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
    </Style>
    <Style x:Key="PageSubtitle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="Margin" Value="0,4,0,18"/>
        <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="18"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
        <Setter Property="FontSize" Value="12.5"/>
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
        <Setter Property="FontSize" Value="13"/>
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="Margin" Value="0,12,0,6"/>
    </Style>

    <!-- Cards -->
    <Style x:Key="Card" TargetType="Border">
        <Setter Property="Background" Value="{StaticResource CardBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="CornerRadius" Value="16"/>
        <Setter Property="Padding" Value="20"/>
        <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="HoverCard" TargetType="Border" BasedOn="{StaticResource Card}">
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="BorderBrush" Value="{StaticResource CardHoverBorderBrush}"/>
                <Setter Property="Background" Value="#191E26"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="Tile" TargetType="Border">
        <Setter Property="Background" Value="{StaticResource SubtleBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="CornerRadius" Value="16"/>
        <Setter Property="Padding" Value="16,14"/>
        <Setter Property="Margin" Value="0,0,12,12"/>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="BorderBrush" Value="{StaticResource CardHoverBorderBrush}"/>
                <Setter Property="Background" Value="#1F2530"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="InfoNote" TargetType="Border">
        <Setter Property="Background" Value="#14F5A524"/>
        <Setter Property="BorderBrush" Value="#40F5A524"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="CornerRadius" Value="16"/>
        <Setter Property="Padding" Value="16,12"/>
        <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <!-- Buttons -->
    <Style TargetType="Button">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Background" Value="#1E232C"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="Padding" Value="16,9"/>
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
                        <Border.RenderTransform>
                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                        </Border.RenderTransform>
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="RenderTransform">
                                <Setter.Value>
                                    <ScaleTransform ScaleX="0.97" ScaleY="0.97"/>
                                </Setter.Value>
                            </Setter>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.4"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#272D38"/>
                <Setter Property="BorderBrush" Value="{StaticResource CardHoverBorderBrush}"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
        <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="Foreground" Value="#0D1015"/>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#FFB940"/>
                <Setter Property="BorderBrush" Value="#FFB940"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
        <Setter Property="Background" Value="#2A1719"/>
        <Setter Property="BorderBrush" Value="#4A2328"/>
        <Setter Property="Foreground" Value="{StaticResource ErrorBrush}"/>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#3A1D21"/>
                <Setter Property="BorderBrush" Value="#6B2A31"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderBrush" Value="Transparent"/>
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="Padding" Value="8"/>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#1F2530"/>
                <Setter Property="BorderBrush" Value="Transparent"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="TitleButton" TargetType="Button">
        <Setter Property="Width" Value="46"/>
        <Setter Property="Height" Value="34"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}" CornerRadius="8">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#222834"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource TitleButton}">
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#E5484D"/>
                <Setter Property="Foreground" Value="White"/>
            </Trigger>
        </Style.Triggers>
    </Style>

    <!-- Toggle switch (CheckBox) -->
    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Margin" Value="0,6"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <Grid Background="Transparent">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <ContentPresenter VerticalAlignment="Center" Margin="0,0,14,0"/>
                        <Border x:Name="Track" Grid.Column="1" Width="44" Height="24" CornerRadius="12"
                                Background="#232935" BorderBrush="#343C4A" BorderThickness="1" VerticalAlignment="Center">
                            <Ellipse x:Name="Knob" Width="16" Height="16" HorizontalAlignment="Left" Margin="3,0,0,0" Fill="#8A93A3">
                                <Ellipse.RenderTransform>
                                    <TranslateTransform X="0"/>
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Trigger.EnterActions>
                                <BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="20" Duration="0:0:0.18">
                                            <DoubleAnimation.EasingFunction>
                                                <CubicEase EasingMode="EaseOut"/>
                                            </DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                    </Storyboard>
                                </BeginStoryboard>
                            </Trigger.EnterActions>
                            <Trigger.ExitActions>
                                <BeginStoryboard>
                                    <Storyboard>
                                        <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.18">
                                            <DoubleAnimation.EasingFunction>
                                                <CubicEase EasingMode="EaseOut"/>
                                            </DoubleAnimation.EasingFunction>
                                        </DoubleAnimation>
                                    </Storyboard>
                                </BeginStoryboard>
                            </Trigger.ExitActions>
                            <Setter TargetName="Track" Property="Background" Value="#F5A524"/>
                            <Setter TargetName="Track" Property="BorderBrush" Value="#F5A524"/>
                            <Setter TargetName="Knob" Property="Fill" Value="#0D1015"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Track" Property="BorderBrush" Value="#5B6474"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.4"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- Radio (options) -->
    <Style TargetType="RadioButton">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Margin" Value="0,4,18,4"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="RadioButton">
                    <StackPanel Orientation="Horizontal" Background="Transparent">
                        <Grid Width="20" Height="20" VerticalAlignment="Center">
                            <Ellipse x:Name="Outer" Stroke="#434B5A" StrokeThickness="1.6" Fill="#11151B"/>
                            <Ellipse x:Name="Dot" Width="10" Height="10" Fill="#F5A524" Opacity="0"/>
                        </Grid>
                        <ContentPresenter VerticalAlignment="Center" Margin="10,0,0,0"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Outer" Property="Stroke" Value="#F5A524"/>
                            <Setter TargetName="Dot" Property="Opacity" Value="1"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Outer" Property="Stroke" Value="#8A93A3"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.4"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- Navigation rail item -->
    <Style x:Key="NavItem" TargetType="RadioButton">
        <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
        <Setter Property="FontSize" Value="15"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Margin" Value="0,0,0,4"/>
        <Setter Property="GroupName" Value="Nav"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="RadioButton">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="12" Padding="14,11">
                        <Grid>
                            <Border x:Name="Indicator" Width="3" Height="18" CornerRadius="2" Background="#F5A524"
                                    HorizontalAlignment="Left" Margin="-14,0,0,0" Opacity="0"/>
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#181D25"/>
                            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
                        </Trigger>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#1F2530"/>
                            <Setter TargetName="Indicator" Property="Opacity" Value="1"/>
                            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- TextBox / PasswordBox -->
    <Style TargetType="TextBox">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Background" Value="{StaticResource InputBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="CaretBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="MinHeight" Value="40"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
        <Setter Property="Padding" Value="10,0,10,0"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="TextBox">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10">
                        <Grid>
                            <Border x:Name="Placeholder" Padding="{TemplateBinding Padding}" IsHitTestVisible="False" Visibility="Collapsed">
                                <TextBlock Text="{TemplateBinding Tag}" Foreground="#5B6474" Margin="4,0,4,0" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" TextTrimming="CharacterEllipsis"/>
                            </Border>
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Focusable="False"
                                          HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                        </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Text" Value="">
                            <Setter TargetName="Placeholder" Property="Visibility" Value="Visible"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4252"/>
                        </Trigger>
                        <Trigger Property="IsKeyboardFocused" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="#F5A524"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="MultilineTextBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
        <Setter Property="VerticalContentAlignment" Value="Top"/>
        <Setter Property="AcceptsReturn" Value="True"/>
        <Setter Property="TextWrapping" Value="Wrap"/>
        <Setter Property="Padding" Value="10,9,10,9"/>
        <Setter Property="MinHeight" Value="72"/>
    </Style>
    <Style x:Key="LogBox" TargetType="TextBox">
        <Setter Property="Foreground" Value="#C9D1DC"/>
        <Setter Property="Background" Value="#0A0D11"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="FontFamily" Value="{StaticResource MonoFont}"/>
        <Setter Property="FontSize" Value="12.5"/>
        <Setter Property="IsReadOnly" Value="True"/>
        <Setter Property="TextWrapping" Value="Wrap"/>
        <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
        <Setter Property="FlowDirection" Value="LeftToRight"/>
        <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="TextBox">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="12">
                        <ScrollViewer x:Name="PART_ContentHost" Margin="12,10"/>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="PasswordBox">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Background" Value="{StaticResource InputBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="CaretBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="MinHeight" Value="40"/>
        <Setter Property="FlowDirection" Value="LeftToRight"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="PasswordBox">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10">
                        <ScrollViewer x:Name="PART_ContentHost" Margin="10,0" VerticalAlignment="Center" Focusable="False"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4252"/>
                        </Trigger>
                        <Trigger Property="IsKeyboardFocused" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="#F5A524"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- ComboBox -->
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Padding" Value="12,8"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="2">
                        <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#222834"/>
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#26F5A524"/>
                            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="ComboBox">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Background" Value="{StaticResource InputBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="FontSize" Value="14"/>
        <Setter Property="Height" Value="40"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="MaxDropDownHeight" Value="320"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBox">
                    <Grid>
                        <ToggleButton Focusable="False" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                      IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                            <ToggleButton.Template>
                                <ControlTemplate TargetType="ToggleButton">
                                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10">
                                        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0" Data="M0,0 L5,5 L10,0"
                                              Stroke="#8A93A3" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4252"/>
                                        </Trigger>
                                        <Trigger Property="IsChecked" Value="True">
                                            <Setter TargetName="Bd" Property="BorderBrush" Value="#F5A524"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </ToggleButton.Template>
                        </ToggleButton>
                        <ContentPresenter IsHitTestVisible="False" Margin="14,0,36,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                          Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                        <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True"
                               Focusable="False" PopupAnimation="Fade">
                            <Border Background="#1A1F27" BorderBrush="#2C3340" BorderThickness="1" CornerRadius="12" Margin="0,6,0,0" Padding="4"
                                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                </ScrollViewer>
                            </Border>
                        </Popup>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- ListBox (dialog results) -->
    <Style TargetType="ListBox">
        <Setter Property="Background" Value="{StaticResource InputBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ListBox">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="4">
                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <ItemsPresenter/>
                        </ScrollViewer>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ListBoxItem">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="12,8" Margin="2">
                        <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#222834"/>
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="#26F5A524"/>
                            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!-- Slim scrollbars -->
    <Style TargetType="ScrollBar">
        <Setter Property="Width" Value="10"/>
        <Setter Property="MinWidth" Value="10"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ScrollBar">
                    <Grid Background="Transparent">
                        <Track x:Name="PART_Track" IsDirectionReversed="True">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border CornerRadius="4" Background="#2E3542" Margin="2"/>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Width" Value="Auto"/>
                <Setter Property="MinWidth" Value="0"/>
                <Setter Property="Height" Value="10"/>
                <Setter Property="MinHeight" Value="10"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="ScrollBar">
                            <Grid Background="Transparent">
                                <Track x:Name="PART_Track" IsDirectionReversed="False">
                                    <Track.Thumb>
                                        <Thumb>
                                            <Thumb.Template>
                                                <ControlTemplate TargetType="Thumb">
                                                    <Border CornerRadius="4" Background="#2E3542" Margin="2"/>
                                                </ControlTemplate>
                                            </Thumb.Template>
                                        </Thumb>
                                    </Track.Thumb>
                                </Track>
                            </Grid>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Trigger>
        </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
        <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ToolTip">
                    <Border Background="#1A1F27" BorderBrush="#2C3340" BorderThickness="1" CornerRadius="8" Padding="10,6">
                        <ContentPresenter/>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>
'@

#endregion XAML — resources

#region XAML — main window

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="QuickDeploy" Width="1200" Height="800" MinWidth="1000" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="False" ResizeMode="CanResize"
        FlowDirection="RightToLeft" Background="{StaticResource BgBrush}" Foreground="{StaticResource TextPrimaryBrush}"
        FontFamily="{StaticResource UiFont}" FontSize="14" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="56" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Border x:Name="RootBorder" BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1">
        <Grid>
            <!-- Radial glow -->
            <Border IsHitTestVisible="False">
                <Border.Background>
                    <RadialGradientBrush Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.8" RadiusY="0.8">
                        <GradientStop Color="#33F5A524" Offset="0"/>
                        <GradientStop Color="#00F5A524" Offset="1"/>
                    </RadialGradientBrush>
                </Border.Background>
            </Border>

            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="56"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Custom title bar -->
                <Grid Grid.Row="0" Margin="20,0,8,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="32" Height="32" CornerRadius="10" Background="{StaticResource AccentBrush}">
                            <Path Data="{StaticResource IconBolt}" Style="{StaticResource Icon}" Width="16" Height="16" Stroke="#0D1015" Fill="#0D1015" StrokeThickness="1"/>
                        </Border>
                        <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                            <TextBlock Text="QuickDeploy" FontSize="16" FontWeight="Bold" FlowDirection="LeftToRight" HorizontalAlignment="Left"/>
                            <TextBlock Text="הקמת מחשב חדש" FontSize="12" Foreground="{StaticResource TextSecondaryBrush}"/>
                        </StackPanel>
                        <Border x:Name="SimBadge" Margin="16,0,0,0" CornerRadius="999" Padding="10,3" Background="#26F5A524" VerticalAlignment="Center" Visibility="Collapsed">
                            <TextBlock Text="מצב סימולציה" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource AccentBrush}"/>
                        </Border>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="BtnMin" Style="{StaticResource TitleButton}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="מזער">
                            <Path Data="{StaticResource IconMinimize}" Style="{StaticResource Icon}" Width="12" Height="12"/>
                        </Button>
                        <Button x:Name="BtnMax" Style="{StaticResource TitleButton}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="הגדל">
                            <Path x:Name="IconMaxPath" Data="{StaticResource IconMaximize}" Style="{StaticResource Icon}" Width="11" Height="11"/>
                        </Button>
                        <Button x:Name="BtnClose" Style="{StaticResource CloseButton}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="סגור">
                            <Path Data="{StaticResource IconX}" Style="{StaticResource Icon}" Width="12" Height="12"/>
                        </Button>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="236"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Navigation rail (right side in RTL) -->
                    <Border Grid.Column="0" Margin="16,4,8,16" CornerRadius="16" Background="#12161C" BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1" Padding="12">
                        <DockPanel LastChildFill="False">
                            <StackPanel DockPanel.Dock="Top">
                                <TextBlock Text="שלבי ההקמה" Style="{StaticResource Caption}" Margin="8,4,0,10"/>
                                <RadioButton x:Name="NavProfile" Style="{StaticResource NavItem}" Tag="PageProfile" IsChecked="True">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconProfile}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="פרופיל" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="NavApps" Style="{StaticResource NavItem}" Tag="PageApps">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconPackage}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="תוכנות" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="NavCleanup" Style="{StaticResource NavItem}" Tag="PageCleanup">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconBroom}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="ניקוי" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="NavSystem" Style="{StaticResource NavItem}" Tag="PageSystem">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconGear}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="הגדרות מערכת" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="NavNetwork" Style="{StaticResource NavItem}" Tag="PageNetwork">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconNetwork}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="רשת ומדפסות" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                                <RadioButton x:Name="NavRun" Style="{StaticResource NavItem}" Tag="PageRun">
                                    <StackPanel Orientation="Horizontal">
                                        <Path Data="{StaticResource IconPlay}" Style="{StaticResource Icon}"/>
                                        <TextBlock Text="סיכום והרצה" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </RadioButton>
                            </StackPanel>
                            <Border DockPanel.Dock="Bottom" CornerRadius="12" Background="{StaticResource SubtleBrush}" Padding="14,12">
                                <StackPanel>
                                    <TextBlock Text="פרופיל פעיל" Style="{StaticResource Caption}"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                                        <TextBlock x:Name="TxtNavProfile" Text="—" FontWeight="SemiBold" FontSize="15" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
                                        <Ellipse x:Name="DotUnsaved" Width="8" Height="8" Fill="{StaticResource AccentBrush}" Margin="8,0,0,0" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="שינויים שלא נשמרו"/>
                                    </StackPanel>
                                    <TextBlock x:Name="TxtNavVersion" Style="{StaticResource Caption}" Margin="0,6,0,0"/>
                                </StackPanel>
                            </Border>
                        </DockPanel>
                    </Border>

                    <!-- Pages -->
                    <Grid Grid.Column="1" Margin="8,4,20,16">

                        <!-- ===== Page: Profile ===== -->
                        <Grid x:Name="PageProfile">
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel Margin="0,0,8,0">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock Text="פרופיל" Style="{StaticResource PageTitle}"/>
                                        <Ellipse x:Name="DotUnsavedPage" Width="10" Height="10" Fill="{StaticResource AccentBrush}" Margin="12,6,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                                    </StackPanel>
                                    <TextBlock Style="{StaticResource PageSubtitle}" Text="בחר תבנית הקמה, ערוך אותה בעמודים הבאים ושמור. שם המחשב, סיסמאות ופרטי הזדהות לעולם אינם נשמרים בפרופיל."/>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="12"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Border Grid.Column="0" Style="{StaticResource Card}" VerticalAlignment="Top">
                                            <StackPanel>
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconProfile}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="ניהול פרופילים" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                                <TextBlock Text="פרופיל" Style="{StaticResource FieldLabel}"/>
                                                <ComboBox x:Name="CmbProfile"/>
                                                <TextBlock Text="שם הפרופיל" Style="{StaticResource FieldLabel}"/>
                                                <TextBox x:Name="TxtProfileName" Tag="לדוגמה: משרד — הנהלת חשבונות"/>
                                                <TextBlock Text="תיאור" Style="{StaticResource FieldLabel}"/>
                                                <TextBox x:Name="TxtProfileDesc" Style="{StaticResource MultilineTextBox}" Tag="תיאור קצר (אופציונלי)"/>
                                                <WrapPanel Margin="0,16,0,0">
                                                    <Button x:Name="BtnSaveProfile" Style="{StaticResource PrimaryButton}" Margin="0,0,8,8">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconSave}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                            <TextBlock Text="שמור" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                    <Button x:Name="BtnDuplicateProfile" Margin="0,0,8,8">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconCopy}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                            <TextBlock Text="שכפל" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                    <Button x:Name="BtnImportProfile" Margin="0,0,8,8">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconImport}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                            <TextBlock Text="ייבוא" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                    <Button x:Name="BtnExportProfile" Margin="0,0,8,8">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconExport}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                            <TextBlock Text="ייצוא" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                    <Button x:Name="BtnDeleteProfile" Style="{StaticResource DangerButton}" Margin="0,0,8,8">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconTrash}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                            <TextBlock Text="מחק" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                </WrapPanel>
                                                <Button x:Name="BtnOpenProfilesFolder" Style="{StaticResource GhostButton}" HorizontalAlignment="Left" Margin="0,4,0,0">
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconFolder}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                        <TextBlock Text="פתח את תיקיית הפרופילים" Margin="8,0,0,0" FontWeight="Normal"/>
                                                    </StackPanel>
                                                </Button>
                                            </StackPanel>
                                        </Border>
                                        <Border Grid.Column="2" Style="{StaticResource Card}" VerticalAlignment="Top">
                                            <StackPanel>
                                                <DockPanel>
                                                    <Button x:Name="BtnRefreshInfo" DockPanel.Dock="Right" Style="{StaticResource GhostButton}" ToolTip="רענן">
                                                        <Path Data="{StaticResource IconRefresh}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                    </Button>
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconMonitor}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="פרטי המחשב" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                </DockPanel>
                                                <StackPanel x:Name="SysInfoPanel" Margin="0,14,0,0">
                                                    <TextBlock Text="טוען מידע מערכת…" Style="{StaticResource Caption}"/>
                                                </StackPanel>
                                            </StackPanel>
                                        </Border>
                                    </Grid>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <!-- ===== Page: Apps ===== -->
                        <Grid x:Name="PageApps" Visibility="Collapsed">
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel Margin="0,0,8,0">
                                    <TextBlock Text="תוכנות" Style="{StaticResource PageTitle}"/>
                                    <TextBlock Style="{StaticResource PageSubtitle}" Text="בחר תוכנות להתקנה שקטה דרך winget. זמינות כל מזהה נבדקת ברקע."/>
                                    <Border Style="{StaticResource Card}">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <Grid>
                                                <TextBox x:Name="TxtAppSearch" Tag="חיפוש בקטלוג (שם או מזהה)…" Padding="10,0,36,0"/>
                                                <Path Data="{StaticResource IconSearch}" Style="{StaticResource Icon}" Width="15" Height="15" TextElement.Foreground="{StaticResource TextFaintBrush}" HorizontalAlignment="Right" Margin="0,0,14,0" IsHitTestVisible="False"/>
                                            </Grid>
                                            <Border Grid.Column="1" Margin="12,0,0,0" CornerRadius="999" Background="#26F5A524" Padding="12,6" VerticalAlignment="Center">
                                                <TextBlock x:Name="TxtAppCount" Text="0 נבחרו" Foreground="{StaticResource AccentBrush}" FontWeight="SemiBold"/>
                                            </Border>
                                            <Button x:Name="BtnAppsNone" Grid.Column="2" Margin="12,0,0,0" Content="נקה בחירה"/>
                                        </Grid>
                                    </Border>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <StackPanel Orientation="Horizontal">
                                                <Path Data="{StaticResource IconPlus}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                <TextBlock Text="הוסף מזהה winget ידני" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                            </StackPanel>
                                            <Grid Margin="0,12,0,0">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBox x:Name="TxtWingetQuery" FlowDirection="LeftToRight" Tag="e.g. Microsoft.PowerShell or keyword"/>
                                                <Button x:Name="BtnWingetSearch" Grid.Column="1" Margin="12,0,0,0" Style="{StaticResource PrimaryButton}">
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconSearch}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                                        <TextBlock Text="חפש" Margin="8,0,0,0"/>
                                                    </StackPanel>
                                                </Button>
                                            </Grid>
                                            <TextBlock x:Name="TxtWingetState" Style="{StaticResource Caption}" Margin="0,8,0,0" Text="החיפוש מתבצע ברקע ומציג רשימת תוצאות לבחירה."/>
                                        </StackPanel>
                                    </Border>
                                    <StackPanel x:Name="AppsPanel"/>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <!-- ===== Page: Cleanup ===== -->
                        <Grid x:Name="PageCleanup" Visibility="Collapsed">
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel Margin="0,0,8,0">
                                    <TextBlock Text="ניקוי" Style="{StaticResource PageTitle}"/>
                                    <TextBlock Style="{StaticResource PageSubtitle}" Text="הסרת אפליקציות מובנות לכל המשתמשים וביטול ההקצאה שלהן למשתמשים חדשים, וכיבוי הצעות ופרסומות."/>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                                                <Path Data="{StaticResource IconShield}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                <TextBlock Text="הצעות, פרסומות ושירותים" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                            </StackPanel>
                                            <UniformGrid Columns="2">
                                                <CheckBox x:Name="ChkConsumerFeatures" Margin="0,6,24,6">
                                                    <StackPanel>
                                                        <TextBlock Text="חסימת התקנה אוטומטית של אפליקציות מוצעות"/>
                                                        <TextBlock Text="Consumer Features — מדיניות מחשב" Style="{StaticResource Caption}"/>
                                                    </StackPanel>
                                                </CheckBox>
                                                <CheckBox x:Name="ChkAds" Margin="0,6,24,6">
                                                    <StackPanel>
                                                        <TextBlock Text="כיבוי הצעות ופרסומות"/>
                                                        <TextBlock Text="תפריט התחל, הגדרות ומסך נעילה" Style="{StaticResource Caption}"/>
                                                    </StackPanel>
                                                </CheckBox>
                                                <CheckBox x:Name="ChkBingSearch" Margin="0,6,24,6">
                                                    <StackPanel>
                                                        <TextBlock Text="כיבוי תוצאות Bing בחיפוש"/>
                                                        <TextBlock Text="חיפוש מקומי בלבד בתפריט התחל" Style="{StaticResource Caption}"/>
                                                    </StackPanel>
                                                </CheckBox>
                                                <CheckBox x:Name="ChkCopilot" Margin="0,6,24,6">
                                                    <StackPanel>
                                                        <TextBlock Text="כיבוי Copilot"/>
                                                        <TextBlock Text="מדיניות TurnOffWindowsCopilot" Style="{StaticResource Caption}"/>
                                                    </StackPanel>
                                                </CheckBox>
                                                <CheckBox x:Name="ChkOneDrive" Margin="0,6,24,6">
                                                    <StackPanel>
                                                        <TextBlock Text="הסרת OneDrive"/>
                                                        <TextBlock Text="כולל חסימת התקנה למשתמשים חדשים" Style="{StaticResource Caption}"/>
                                                    </StackPanel>
                                                </CheckBox>
                                            </UniformGrid>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <DockPanel Margin="0,0,0,12">
                                                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                                    <Button x:Name="BtnDebloatAll" Content="בחר הכל" Margin="0,0,8,0"/>
                                                    <Button x:Name="BtnDebloatNone" Content="נקה הכל"/>
                                                </StackPanel>
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconBroom}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="אפליקציות להסרה" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    <TextBlock x:Name="TxtDebloatCount" Style="{StaticResource Caption}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                                                </StackPanel>
                                            </DockPanel>
                                            <WrapPanel x:Name="DebloatPanel"/>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource InfoNote}">
                                        <StackPanel Orientation="Horizontal">
                                            <Path Data="{StaticResource IconShield}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}" VerticalAlignment="Top"/>
                                            <TextBlock Margin="10,0,0,0" TextWrapping="Wrap" MaxWidth="820" Foreground="{StaticResource TextPrimaryBrush}"
                                                       Text="מוגנות תמיד ולעולם לא יוסרו: Microsoft Store, App Installer (winget), מחשבון, תמונות, פנקס רשימות, Terminal, אבטחת Windows, Paint, כלי החיתוך, ספריות VCLibs / UI.Xaml / .NET ו-Teams לעבודה."/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <!-- ===== Page: System ===== -->
                        <Grid x:Name="PageSystem" Visibility="Collapsed">
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel Margin="0,0,8,0">
                                    <TextBlock Text="הגדרות מערכת" Style="{StaticResource PageTitle}"/>
                                    <TextBlock Style="{StaticResource PageSubtitle}" Text="הגדרות משתמש מוחלות על המשתמש הנוכחי ועל פרופיל ברירת המחדל, כך שגם משתמשים חדשים יקבלו אותן."/>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="12"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <Border Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconTag}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="שם מחשב" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <TextBlock Text="שם חדש (יוחל בשלב האחרון, דורש הפעלה מחדש)" Style="{StaticResource FieldLabel}"/>
                                                    <TextBox x:Name="TxtComputerName" FlowDirection="LeftToRight" MaxLength="15"/>
                                                    <TextBlock x:Name="TxtComputerNameHint" Style="{StaticResource Caption}" Margin="0,6,0,0" Text="עד 15 תווים: אותיות באנגלית, ספרות ומקף. השאר ריק כדי לא לשנות."/>
                                                </StackPanel>
                                            </Border>
                                            <Border Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                        <Path Data="{StaticResource IconGlobe}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="אזור ושפה" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <CheckBox x:Name="ChkTimezone" Content="אזור זמן: ישראל (Israel Standard Time)"/>
                                                    <CheckBox x:Name="ChkHebrewKeyboard" Content="מקלדת עברית + אנגלית (he-IL, en-US)"/>
                                                </StackPanel>
                                            </Border>
                                            <Border Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                        <Path Data="{StaticResource IconPower}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="צריכת חשמל" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <TextBlock Text="תוכנית חשמל" Style="{StaticResource FieldLabel}" Margin="0,4,0,6"/>
                                                    <ComboBox x:Name="CmbPowerPlan">
                                                        <ComboBoxItem Content="מאוזן" Tag="balanced"/>
                                                        <ComboBoxItem Content="ביצועים גבוהים" Tag="high"/>
                                                    </ComboBox>
                                                    <TextBlock Style="{StaticResource Caption}" Margin="0,8,0,4" Text="בחיבור לחשמל: שינה — לעולם לא, כיבוי מסך — 30 דקות."/>
                                                    <CheckBox x:Name="ChkDisableHibernation" Content="כיבוי מצב שינה עמוקה (Hibernation)"/>
                                                    <CheckBox x:Name="ChkDisableFastStartup" Content="כיבוי הפעלה מהירה (Fast Startup)"/>
                                                </StackPanel>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Grid.Column="2">
                                            <Border Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                        <Path Data="{StaticResource IconFolder}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="סייר הקבצים" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <CheckBox x:Name="ChkShowExtensions" Content="הצג סיומות קבצים"/>
                                                    <CheckBox x:Name="ChkShowHidden" Content="הצג קבצים מוסתרים"/>
                                                    <CheckBox x:Name="ChkExplorerThisPC" Content="פתח את הסייר ב&quot;מחשב זה&quot;"/>
                                                </StackPanel>
                                            </Border>
                                            <Border x:Name="PanelWin11" Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                        <Path Data="{StaticResource IconMonitor}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="Windows 11" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <CheckBox x:Name="ChkTaskbarLeft" Content="יישור שורת המשימות לצד (כמו Windows 10)"/>
                                                    <CheckBox x:Name="ChkClassicContextMenu" Content="תפריט לחצן ימני קלאסי"/>
                                                </StackPanel>
                                            </Border>
                                            <Border Style="{StaticResource Card}">
                                                <StackPanel>
                                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                                                        <Path Data="{StaticResource IconShield}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                        <TextBlock Text="גישה וניהול" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                    </StackPanel>
                                                    <CheckBox x:Name="ChkEnableRdp" Content="הפעל שולחן עבודה מרוחק (RDP) + חומת אש"/>
                                                    <CheckBox x:Name="ChkCreateLocalAdmin">
                                                        <StackPanel>
                                                            <TextBlock Text="צור משתמש מנהל מקומי"/>
                                                            <TextBlock Text="שם משתמש וסיסמה יתבקשו בעת ההרצה ולא יישמרו" Style="{StaticResource Caption}"/>
                                                        </StackPanel>
                                                    </CheckBox>
                                                    <CheckBox x:Name="ChkWindowsUpdateScan" Content="הפעל סריקת Windows Update בסיום"/>
                                                </StackPanel>
                                            </Border>
                                            <Border Style="{StaticResource InfoNote}">
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconInfo}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}" VerticalAlignment="Top"/>
                                                    <TextBlock Margin="10,0,0,0" TextWrapping="Wrap" MaxWidth="360" Foreground="{StaticResource TextPrimaryBrush}"
                                                               Text="הגדרת דפדפן ברירת מחדל אינה נתמכת באופן שקט ב-Windows 11 (מוגנת על ידי המערכת). יש לבחור אותו ידנית בהגדרות ← אפליקציות ← אפליקציות ברירת מחדל."/>
                                                </StackPanel>
                                            </Border>
                                        </StackPanel>
                                    </Grid>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <!-- ===== Page: Network ===== -->
                        <Grid x:Name="PageNetwork" Visibility="Collapsed">
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel Margin="0,0,8,0">
                                    <TextBlock Text="רשת ומדפסות" Style="{StaticResource PageTitle}"/>
                                    <TextBlock Style="{StaticResource PageSubtitle}" Text="דומיין / קבוצת עבודה, כוננים ממופים, רשתות אלחוטיות ומדפסות. סיסמאות ופרטי הזדהות מתבקשים רק בעת ההרצה."/>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <StackPanel Orientation="Horizontal">
                                                <Path Data="{StaticResource IconNetwork}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                <TextBlock Text="קבוצת עבודה / דומיין" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                            </StackPanel>
                                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                                <RadioButton x:Name="RbJoinNone" GroupName="Join" Content="ללא שינוי" IsChecked="True"/>
                                                <RadioButton x:Name="RbJoinWorkgroup" GroupName="Join" Content="קבוצת עבודה"/>
                                                <RadioButton x:Name="RbJoinDomain" GroupName="Join" Content="דומיין"/>
                                            </StackPanel>
                                            <StackPanel x:Name="PanelWorkgroup" Visibility="Collapsed">
                                                <TextBlock Text="שם קבוצת העבודה" Style="{StaticResource FieldLabel}"/>
                                                <TextBox x:Name="TxtWorkgroup" FlowDirection="LeftToRight" MaxLength="15" Tag="WORKGROUP"/>
                                            </StackPanel>
                                            <StackPanel x:Name="PanelDomain" Visibility="Collapsed">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="12"/>
                                                        <ColumnDefinition Width="*"/>
                                                    </Grid.ColumnDefinitions>
                                                    <StackPanel Grid.Column="0">
                                                        <TextBlock Text="שם הדומיין" Style="{StaticResource FieldLabel}"/>
                                                        <TextBox x:Name="TxtDomain" FlowDirection="LeftToRight" Tag="corp.example.local"/>
                                                    </StackPanel>
                                                    <StackPanel Grid.Column="2">
                                                        <TextBlock Text="OU (אופציונלי)" Style="{StaticResource FieldLabel}"/>
                                                        <TextBox x:Name="TxtOU" FlowDirection="LeftToRight" Tag="OU=Computers,DC=corp,DC=example,DC=local"/>
                                                    </StackPanel>
                                                </Grid>
                                                <TextBlock Style="{StaticResource Caption}" Margin="0,8,0,0" Text="פרטי מנהל הדומיין יתבקשו בחלון מאובטח לפני תחילת ההרצה. ההצטרפות מתבצעת בשלב האחרון."/>
                                            </StackPanel>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <DockPanel>
                                                <Button x:Name="BtnAddDrive" DockPanel.Dock="Right">
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconPlus}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                        <TextBlock Text="הוסף כונן" Margin="8,0,0,0"/>
                                                    </StackPanel>
                                                </Button>
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconDrive}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="כוננים ממופים" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                            </DockPanel>
                                            <TextBlock Style="{StaticResource Caption}" Margin="0,6,0,10" Text="נשמרים באופן קבוע עבור המשתמש המחובר (לא המנהל המוגבה) ומתחברים בכניסה הבאה."/>
                                            <StackPanel x:Name="DrivesPanel"/>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <DockPanel>
                                                <Button x:Name="BtnAddWifi" DockPanel.Dock="Right">
                                                    <StackPanel Orientation="Horizontal">
                                                        <Path Data="{StaticResource IconPlus}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                        <TextBlock Text="הוסף רשת" Margin="8,0,0,0"/>
                                                    </StackPanel>
                                                </Button>
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconWifi}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="רשתות Wi-Fi" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                            </DockPanel>
                                            <TextBlock Style="{StaticResource Caption}" Margin="0,6,0,10" Text="הסיסמה תתבקש בעת ההרצה ולעולם לא תישמר בפרופיל."/>
                                            <StackPanel x:Name="WifiPanel"/>
                                        </StackPanel>
                                    </Border>
                                    <Border Style="{StaticResource Card}">
                                        <StackPanel>
                                            <DockPanel>
                                                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                                    <Button x:Name="BtnAddPrinterIp" Margin="0,0,8,0">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconPlus}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                            <TextBlock Text="מדפסת IP" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                    <Button x:Name="BtnAddPrinterUnc">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Path Data="{StaticResource IconPlus}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                            <TextBlock Text="מדפסת משותפת" Margin="8,0,0,0"/>
                                                        </StackPanel>
                                                    </Button>
                                                </StackPanel>
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconPrinter}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="מדפסות" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                            </DockPanel>
                                            <TextBlock Style="{StaticResource Caption}" Margin="0,6,0,10" Text="מדפסת משותפת (\\server\printer) נוספת עבור המשתמש המחובר באמצעות משימה מתוזמנת חד-פעמית."/>
                                            <StackPanel x:Name="PrintersPanel"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </ScrollViewer>
                        </Grid>

                        <!-- ===== Page: Run ===== -->
                        <Grid x:Name="PageRun" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid Width="128" Height="128" FlowDirection="LeftToRight">
                                        <Ellipse Width="118" Height="118" Stroke="#232935" StrokeThickness="10"/>
                                        <Path x:Name="RingArc" Stroke="{StaticResource AccentBrush}" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                            <TextBlock x:Name="RingText" Text="0%" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center"/>
                                            <TextBlock x:Name="RingSub" Text="מוכן" FontSize="12" Foreground="{StaticResource TextSecondaryBrush}" HorizontalAlignment="Center" FlowDirection="RightToLeft"/>
                                        </StackPanel>
                                    </Grid>
                                    <StackPanel Grid.Column="1" Margin="24,0,16,0" VerticalAlignment="Center">
                                        <TextBlock Text="סיכום והרצה" Style="{StaticResource PageTitle}"/>
                                        <TextBlock x:Name="TxtRunStatus" Style="{StaticResource Caption}" FontSize="14" Margin="0,4,0,0" Text="בדוק את הסיכום ולחץ &quot;הרץ&quot;. פרטי הזדהות וסיסמאות ייאספו לפני תחילת ההרצה."/>
                                        <TextBlock x:Name="TxtRunActivity" FontSize="14" FontWeight="SemiBold" Foreground="{StaticResource AccentBrush}" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                                        <Border x:Name="RebootBanner" Margin="0,10,0,0" CornerRadius="12" Background="#1AFBBF24" BorderBrush="#55FBBF24" BorderThickness="1" Padding="12,8" Visibility="Collapsed" HorizontalAlignment="Left">
                                            <StackPanel Orientation="Horizontal">
                                                <Path Data="{StaticResource IconAlert}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource WarningBrush}" Width="16" Height="16"/>
                                                <TextBlock x:Name="TxtRebootReason" Margin="8,0,0,0" Foreground="{StaticResource WarningBrush}" TextWrapping="Wrap" MaxWidth="420" Text="נדרשת הפעלה מחדש"/>
                                            </StackPanel>
                                        </Border>
                                    </StackPanel>
                                    <StackPanel Grid.Column="2" VerticalAlignment="Center" MinWidth="220">
                                        <CheckBox x:Name="ChkSimulate" Margin="0,0,0,12">
                                            <StackPanel>
                                                <TextBlock Text="מצב סימולציה" FontWeight="SemiBold"/>
                                                <TextBlock Text="רישום בלבד, ללא שינויים" Style="{StaticResource Caption}"/>
                                            </StackPanel>
                                        </CheckBox>
                                        <WrapPanel HorizontalAlignment="Left">
                                            <Button x:Name="BtnRun" Style="{StaticResource PrimaryButton}" Padding="22,11" Margin="0,0,8,8">
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconPlay}" Style="{StaticResource Icon}" Width="15" Height="15" Fill="#0D1015"/>
                                                    <TextBlock Text="הרץ" Margin="8,0,0,0" FontSize="15"/>
                                                </StackPanel>
                                            </Button>
                                            <Button x:Name="BtnCancel" Style="{StaticResource DangerButton}" Padding="18,11" Margin="0,0,8,8" Visibility="Collapsed">
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconStop}" Style="{StaticResource Icon}" Width="14" Height="14"/>
                                                    <TextBlock Text="בטל" Margin="8,0,0,0"/>
                                                </StackPanel>
                                            </Button>
                                            <Button x:Name="BtnOpenReport" Padding="18,11" Margin="0,0,8,8" Visibility="Collapsed">
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconReport}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                    <TextBlock Text="פתח דוח" Margin="8,0,0,0"/>
                                                </StackPanel>
                                            </Button>
                                            <Button x:Name="BtnReboot" Padding="18,11" Margin="0,0,8,8" Visibility="Collapsed">
                                                <StackPanel Orientation="Horizontal">
                                                    <Path Data="{StaticResource IconPower}" Style="{StaticResource Icon}" Width="15" Height="15"/>
                                                    <TextBlock Text="הפעל מחדש" Margin="8,0,0,0"/>
                                                </StackPanel>
                                            </Button>
                                        </WrapPanel>
                                    </StackPanel>
                                </Grid>
                            </Border>
                            <Grid Grid.Row="1">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="12"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                                    <StackPanel>
                                        <Border Style="{StaticResource Card}">
                                            <StackPanel>
                                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                                    <Path Data="{StaticResource IconCheck}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="מה ייבחר להרצה" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                                <WrapPanel x:Name="SummaryPanel"/>
                                            </StackPanel>
                                        </Border>
                                        <Border Style="{StaticResource Card}">
                                            <StackPanel>
                                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                                    <Path Data="{StaticResource IconPlay}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                    <TextBlock Text="שלבי ביצוע" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                                </StackPanel>
                                                <StackPanel x:Name="StepsPanel"/>
                                            </StackPanel>
                                        </Border>
                                    </StackPanel>
                                </ScrollViewer>
                                <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0">
                                    <DockPanel>
                                        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,12">
                                            <Button x:Name="BtnOpenLogs" DockPanel.Dock="Right" Style="{StaticResource GhostButton}" ToolTip="פתח את תיקיית היומנים">
                                                <Path Data="{StaticResource IconFolder}" Style="{StaticResource Icon}" Width="16" Height="16"/>
                                            </Button>
                                            <StackPanel Orientation="Horizontal">
                                                <Path Data="{StaticResource IconReport}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                                                <TextBlock Text="יומן חי" Style="{StaticResource SectionTitle}" Margin="10,0,0,0"/>
                                            </StackPanel>
                                        </DockPanel>
                                        <TextBox x:Name="TxtLog" Style="{StaticResource LogBox}"/>
                                    </DockPanel>
                                </Border>
                            </Grid>
                        </Grid>
                    </Grid>
                </Grid>
            </Grid>

            <!-- Modal dim overlay -->
            <Border x:Name="Overlay" Background="#B3080A0D" Visibility="Collapsed"/>

            <!-- Toast -->
            <Border x:Name="ToastHost" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,28" CornerRadius="14"
                    Background="#1C2129" BorderBrush="#2E3542" BorderThickness="1" Padding="16,12" Visibility="Collapsed" MaxWidth="640">
                <Border.RenderTransform>
                    <TranslateTransform Y="0"/>
                </Border.RenderTransform>
                <Border.Effect>
                    <DropShadowEffect BlurRadius="24" ShadowDepth="6" Opacity="0.45" Color="#000000"/>
                </Border.Effect>
                <StackPanel Orientation="Horizontal">
                    <Path x:Name="ToastIcon" Data="{StaticResource IconInfo}" Style="{StaticResource Icon}" TextElement.Foreground="{StaticResource AccentBrush}"/>
                    <TextBlock x:Name="ToastText" Margin="10,0,0,0" TextWrapping="Wrap" MaxWidth="560" VerticalAlignment="Center"/>
                </StackPanel>
            </Border>
        </Grid>
    </Border>
</Window>
'@

#endregion XAML — main window

#region XAML — dialog window

$script:DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="QuickDeploy" Width="480" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner" Topmost="False"
        FlowDirection="RightToLeft" FontFamily="{StaticResource UiFont}" FontSize="14" Foreground="{StaticResource TextPrimaryBrush}">
    <Border Margin="16" CornerRadius="16" Background="{StaticResource CardBrush}" BorderBrush="#2E3542" BorderThickness="1" Padding="24">
        <Border.Effect>
            <DropShadowEffect BlurRadius="28" ShadowDepth="8" Opacity="0.55" Color="#000000"/>
        </Border.Effect>
        <StackPanel>
            <StackPanel Orientation="Horizontal">
                <Border x:Name="DlgIconHost" Width="40" Height="40" CornerRadius="12" Background="#26F5A524">
                    <Path x:Name="DlgIcon" Data="{StaticResource IconInfo}" Style="{StaticResource Icon}" Width="20" Height="20" TextElement.Foreground="{StaticResource AccentBrush}"/>
                </Border>
                <TextBlock x:Name="DlgTitle" Style="{StaticResource SectionTitle}" Margin="14,0,0,0" TextWrapping="Wrap" MaxWidth="340"/>
            </StackPanel>
            <TextBlock x:Name="DlgMessage" Margin="0,14,0,0" TextWrapping="Wrap" Foreground="{StaticResource TextSecondaryBrush}" LineHeight="21"/>
            <TextBlock x:Name="DlgCountdown" Margin="0,14,0,0" FontSize="44" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{StaticResource AccentBrush}" Visibility="Collapsed"/>
            <StackPanel x:Name="DlgFields" Margin="0,4,0,0"/>
            <ListBox x:Name="DlgList" Margin="0,14,0,0" MaxHeight="300" Visibility="Collapsed" FlowDirection="LeftToRight"/>
            <StackPanel x:Name="DlgButtons" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,22,0,0"/>
        </StackPanel>
    </Border>
</Window>
'@

#endregion XAML — dialog window


#region UI — core helpers (WPF, XAML loading, brushes, animation)

# UI state (initialised here so StrictMode never sees an unset variable)
$script:App = $null
$script:MainWindow = $null
$script:UI = $null
$script:ToastTimer = $null
$script:AppCards = $null
$script:DebloatToggles = $null
$script:CategoryPanels = @{}
$script:StartupToast = ''

function Hide-QDConsole {
    <#
    .SYNOPSIS
        מסתיר את חלון המסוף במצב גרפי — רק אם המסוף שייך לתהליך זה בלבד.
    #>
    [CmdletBinding()]
    param()
    try {
        if (-not ('QuickDeploy.NativeMethods' -as [type])) {
            Add-Type -Namespace 'QuickDeploy' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        }
        $native = 'QuickDeploy.NativeMethods' -as [type]
        $handle = $native::GetConsoleWindow()
        if ($handle -eq [IntPtr]::Zero) { return }
        $buffer = New-Object 'uint32[]' 8
        $count = $native::GetConsoleProcessList($buffer, 8)
        if ($count -le 1) { [void]$native::ShowWindow($handle, 0) }
    }
    catch { Write-Verbose ('Hide console: ' + $_.Exception.Message) }
}

function Initialize-QDWpf {
    <#
    .SYNOPSIS
        טוען את WPF ואת מילון המשאבים (צבעים, אייקונים, תבניות) ברמת האפליקציה.
    #>
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    if ($null -eq [System.Windows.Application]::Current) {
        $script:App = New-Object System.Windows.Application
        $script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    else {
        $script:App = [System.Windows.Application]::Current
    }
    $dict = [System.Windows.Markup.XamlReader]::Parse($script:ResourcesXaml)
    $script:App.Resources.MergedDictionaries.Add($dict)
}

function Import-QDXaml {
    <#
    .SYNOPSIS
        טוען XAML ומחזיר את האלמנט הראשי + מילון של כל הפקדים בעלי x:Name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Xaml)
    $xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    [xml]$doc = $Xaml
    $reader = New-Object System.Xml.XmlNodeReader($doc)
    $root = [System.Windows.Markup.XamlReader]::Load($reader)
    $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $nsm.AddNamespace('x', $xamlNs)
    $names = @{}
    foreach ($node in $doc.SelectNodes('//*[@x:Name]', $nsm)) {
        $n = $node.GetAttribute('Name', $xamlNs)
        $el = $root.FindName($n)
        if ($null -ne $el) { $names[$n] = $el }
    }
    return @{ Root = $root; Names = $names }
}

function Get-QDColor {
    <#
    .SYNOPSIS
        ממיר מחרוזת HEX לצבע WPF.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hex)
    return [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function Get-QDBrush {
    <#
    .SYNOPSIS
        יוצר מברשת צבע אחיד מ-HEX.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hex)
    return (New-Object System.Windows.Media.SolidColorBrush((Get-QDColor -Hex $Hex)))
}

function Get-QDResource {
    <#
    .SYNOPSIS
        מחזיר משאב מהמילון הגלובלי (סגנון, אייקון, מברשת).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    return $script:App.FindResource($Key)
}

function Get-QDIconPath {
    <#
    .SYNOPSIS
        יוצר Path של אייקון וקטורי מהמשאבים.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [double]$Size = 16, [string]$Color = '')
    $p = New-Object System.Windows.Shapes.Path
    $p.Style = Get-QDResource -Key 'Icon'
    $p.Data = Get-QDResource -Key $Name
    $p.Width = $Size
    $p.Height = $Size
    if ($Color) { $p.SetValue([System.Windows.Documents.TextElement]::ForegroundProperty, (Get-QDBrush -Hex $Color)) }
    return $p
}

function Get-QDTextBlock {
    <#
    .SYNOPSIS
        יוצר TextBlock עם סגנון אופציונלי.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '', [string]$StyleKey = '', [double]$FontSize = 0, [switch]$Bold, [switch]$Ltr, [string]$Color = '')
    $t = New-Object System.Windows.Controls.TextBlock
    if ($StyleKey) { $t.Style = Get-QDResource -Key $StyleKey }
    $t.Text = $Text
    if ($FontSize -gt 0) { $t.FontSize = $FontSize }
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Ltr) { $t.FlowDirection = [System.Windows.FlowDirection]::LeftToRight; $t.TextAlignment = [System.Windows.TextAlignment]::Right }
    if ($Color) { $t.Foreground = Get-QDBrush -Hex $Color }
    $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    return $t
}

function Get-QDDoubleAnimation {
    <#
    .SYNOPSIS
        יוצר DoubleAnimation עם CubicEase.
    #>
    [CmdletBinding()]
    param([double]$From, [double]$To, [int]$Milliseconds = 200)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From
    $a.To = $To
    $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($Milliseconds))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $a.EasingFunction = $ease
    return $a
}

function Invoke-QDSafe {
    <#
    .SYNOPSIS
        מריץ קוד של אירוע ממשק עם טיפול בשגיאות (הודעה במקום קריסה).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    try { & $ScriptBlock }
    catch {
        Write-QDLog -Message ('שגיאת ממשק: ' + $_.Exception.Message) -Level 'ERROR'
        Show-QDToast -Message ('שגיאה: ' + $_.Exception.Message) -Kind 'error'
    }
}

#endregion UI — core helpers

#region UI — navigation, toast, dialogs

function Show-QDPage {
    <#
    .SYNOPSIS
        מעבר עמוד עם אנימציית fade + slide (200ms, CubicEase).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in $script:PageNames) {
        if ($p -ne $Name) { $UI[$p].Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $page = $UI[$Name]
    $page.Visibility = [System.Windows.Visibility]::Visible
    $page.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0 -To 1 -Milliseconds 200))
    $tt = New-Object System.Windows.Media.TranslateTransform
    $page.RenderTransform = $tt
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (Get-QDDoubleAnimation -From 14 -To 0 -Milliseconds 200))
    if ($Name -eq 'PageRun') { Build-QDRunSummary }
}

function Show-QDToast {
    <#
    .SYNOPSIS
        מציג הודעה צפה בתחתית החלון.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('info', 'success', 'warning', 'error')][string]$Kind = 'info')
    if ($null -eq $script:UI -or -not $script:UI.ContainsKey('ToastHost')) { return }
    $map = @{ info = @('IconInfo', '#F5A524'); success = @('IconCheck', '#2DD4BF'); warning = @('IconAlert', '#FBBF24'); error = @('IconAlert', '#F87171') }
    $UI.ToastIcon.Data = Get-QDResource -Key $map[$Kind][0]
    $UI.ToastIcon.SetValue([System.Windows.Documents.TextElement]::ForegroundProperty, (Get-QDBrush -Hex $map[$Kind][1]))
    $UI.ToastHost.BorderBrush = Get-QDBrush -Hex ($map[$Kind][1] -replace '#', '#55')
    $UI.ToastText.Text = $Message
    $UI.ToastHost.Visibility = [System.Windows.Visibility]::Visible
    $UI.ToastHost.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0 -To 1 -Milliseconds 220))
    $UI.ToastHost.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (Get-QDDoubleAnimation -From 18 -To 0 -Milliseconds 220))
    if ($null -eq $script:ToastTimer) {
        $script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToastTimer.Add_Tick({ Hide-QDToast })
    }
    $script:ToastTimer.Stop()
    $script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds([math]::Max(3500, 60 * $Message.Length))
    $script:ToastTimer.Start()
}

function Hide-QDToast {
    <#
    .SYNOPSIS
        מסתיר את ההודעה הצפה.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:ToastTimer) { $script:ToastTimer.Stop() }
    $UI.ToastHost.Visibility = [System.Windows.Visibility]::Collapsed
}

function Show-QDDialog {
    <#
    .SYNOPSIS
        חלון דו-שיח מעוצב (במקום MessageBox): הודעה, שדות קלט (כולל PasswordBox), רשימה לבחירה, ספירה לאחור.
    .OUTPUTS
        אובייקט עם Button (אינדקס הכפתור, -1 = נסגר), Values (מילון שדות), SelectedIndex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message = '',
        [ValidateSet('info', 'warning', 'error', 'question', 'success')][string]$Kind = 'info',
        [string[]]$Buttons = @('אישור'),
        [object[]]$Fields = @(),
        [string[]]$ListItems = @(),
        [int]$CountdownSeconds = 0
    )
    $r = Import-QDXaml -Xaml $script:DialogXaml
    $dlg = $r.Root
    $d = $r.Names
    $kinds = @{
        info     = @('IconInfo', '#F5A524')
        question = @('IconInfo', '#F5A524')
        warning  = @('IconAlert', '#FBBF24')
        error    = @('IconAlert', '#F87171')
        success  = @('IconCheck', '#2DD4BF')
    }
    $d.DlgIcon.Data = Get-QDResource -Key $kinds[$Kind][0]
    $d.DlgIcon.SetValue([System.Windows.Documents.TextElement]::ForegroundProperty, (Get-QDBrush -Hex $kinds[$Kind][1]))
    $d.DlgIconHost.Background = Get-QDBrush -Hex ($kinds[$Kind][1] -replace '#', '#26')
    $d.DlgTitle.Text = $Title
    if ([string]::IsNullOrWhiteSpace($Message)) { $d.DlgMessage.Visibility = [System.Windows.Visibility]::Collapsed } else { $d.DlgMessage.Text = $Message }

    $controls = @{}
    $first = $null
    foreach ($f in $Fields) {
        $label = Get-QDTextBlock -Text ([string]$f.Label) -StyleKey 'FieldLabel'
        [void]$d.DlgFields.Children.Add($label)
        if ($f.Type -eq 'password') {
            $ctrl = New-Object System.Windows.Controls.PasswordBox
        }
        else {
            $ctrl = New-Object System.Windows.Controls.TextBox
            if ($f.ContainsKey('Value')) { $ctrl.Text = [string]$f.Value }
            if ($f.ContainsKey('Ltr') -and $f.Ltr) { $ctrl.FlowDirection = [System.Windows.FlowDirection]::LeftToRight }
        }
        [void]$d.DlgFields.Children.Add($ctrl)
        $controls[[string]$f.Key] = $ctrl
        if ($null -eq $first) { $first = $ctrl }
    }
    if (@($ListItems).Count -gt 0) {
        $d.DlgList.ItemsSource = $ListItems
        $d.DlgList.SelectedIndex = 0
        $d.DlgList.Visibility = [System.Windows.Visibility]::Visible
        $d.DlgList.Add_MouseDoubleClick({
                $w = [System.Windows.Window]::GetWindow($this)
                $w.Tag = 0
                $w.Close()
            })
        if ($null -eq $first) { $first = $d.DlgList }
    }
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Buttons[$i]
        $b.Tag = $i
        $b.MinWidth = 96
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        if ($i -eq 0) {
            $b.Style = if ($Kind -eq 'error' -and $Buttons.Count -gt 1) { Get-QDResource -Key 'DangerButton' } else { Get-QDResource -Key 'PrimaryButton' }
            $b.IsDefault = $true
        }
        if ($Buttons.Count -gt 1 -and $i -eq $Buttons.Count - 1) { $b.IsCancel = $true }
        $b.Add_Click({
                $w = [System.Windows.Window]::GetWindow($this)
                $w.Tag = [int]$this.Tag
                $w.Close()
            })
        [void]$d.DlgButtons.Children.Add($b)
    }
    $dlg.Tag = -1
    $dlg.DataContext = $first
    $dlg.Add_Loaded({ if ($this.DataContext -is [System.Windows.UIElement]) { [void]$this.DataContext.Focus() } })
    $dlg.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { Write-Verbose 'DragMove ignored' } })

    $timer = $null
    if ($CountdownSeconds -gt 0) {
        $d.DlgCountdown.Text = [string]$CountdownSeconds
        $d.DlgCountdown.Visibility = [System.Windows.Visibility]::Visible
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Tag = @{ Window = $dlg; Remaining = $CountdownSeconds; Label = $d.DlgCountdown }
        $timer.Add_Tick({
                $st = $this.Tag
                $st.Remaining = $st.Remaining - 1
                $st.Label.Text = [string]$st.Remaining
                if ($st.Remaining -le 0) {
                    $this.Stop()
                    $st.Window.Tag = 0
                    $st.Window.Close()
                }
            })
        $timer.Start()
    }

    $hasOwner = $false
    if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) {
        $dlg.Owner = $script:MainWindow
        $UI.Overlay.Visibility = [System.Windows.Visibility]::Visible
        $hasOwner = $true
    }
    else {
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    }
    try { [void]$dlg.ShowDialog() }
    finally {
        if ($null -ne $timer) { $timer.Stop() }
        if ($hasOwner) { $UI.Overlay.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $values = @{}
    foreach ($k in $controls.Keys) {
        $c = $controls[$k]
        if ($c -is [System.Windows.Controls.PasswordBox]) { $values[$k] = $c.SecurePassword } else { $values[$k] = $c.Text }
    }
    return [pscustomobject]@{ Button = [int]$dlg.Tag; Values = $values; SelectedIndex = $d.DlgList.SelectedIndex }
}

#endregion UI — navigation, toast, dialogs

#region UI — software catalog page

function Build-QDAppCatalogUi {
    <#
    .SYNOPSIS
        בונה את כרטיסי הקטלוג מקובצים לפי קטגוריה.
    #>
    [CmdletBinding()]
    param()
    $UI.AppsPanel.Children.Clear()
    $script:AppCards = [ordered]@{}
    $script:CategoryPanels = @{}
    foreach ($cat in @($QD.CategoryOrder + @('מותאם אישית'))) {
        $container = New-Object System.Windows.Controls.StackPanel
        $header = Get-QDTextBlock -Text $cat -StyleKey 'SectionTitle'
        $header.Margin = New-Object System.Windows.Thickness(4, 10, 0, 12)
        $wrap = New-Object System.Windows.Controls.WrapPanel
        [void]$container.Children.Add($header)
        [void]$container.Children.Add($wrap)
        [void]$UI.AppsPanel.Children.Add($container)
        $script:CategoryPanels[$cat] = @{ Container = $container; Wrap = $wrap }
        foreach ($app in @($QD.Catalog | Where-Object { $_.Category -eq $cat })) {
            Add-QDAppCard -App @{ Id = $app.Id; Name = $app.Name; Source = $app.Source; Category = $cat; Custom = $false }
        }
    }
    $script:CategoryPanels['מותאם אישית'].Container.Visibility = [System.Windows.Visibility]::Collapsed
}

function Add-QDAppCard {
    <#
    .SYNOPSIS
        מוסיף כרטיס תוכנה (עם מתג) לקטגוריה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App, [bool]$Checked = $false)
    $card = New-Object System.Windows.Controls.Border
    $card.Style = Get-QDResource -Key 'Tile'
    $card.Width = 236
    $card.Cursor = [System.Windows.Input.Cursors]::Hand
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @('*', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt 3; $i++) { $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) }

    $name = Get-QDTextBlock -Text $App.Name -Bold -FontSize 14.5
    $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $id = Get-QDTextBlock -Text $App.Id -StyleKey 'Caption' -Ltr
    $id.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $id.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $id.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($id, 1)
    $status = Get-QDTextBlock -Text 'בודק זמינות…' -StyleKey 'Caption'
    $status.FontSize = 12
    $status.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($status, 2)
    $toggle = New-Object System.Windows.Controls.CheckBox
    $toggle.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $toggle.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $toggle.IsChecked = $Checked
    [System.Windows.Controls.Grid]::SetColumn($toggle, 1)
    [System.Windows.Controls.Grid]::SetRowSpan($toggle, 2)
    foreach ($el in @($name, $id, $status, $toggle)) { [void]$grid.Children.Add($el) }

    $entry = @{ Card = $card; Toggle = $toggle; Status = $status; App = $App }
    if ($App.Custom) {
        $rm = New-Object System.Windows.Controls.Button
        $rm.Style = Get-QDResource -Key 'GhostButton'
        $rm.Padding = New-Object System.Windows.Thickness(4)
        $rm.Content = Get-QDIconPath -Name 'IconTrash' -Size 14
        $rm.ToolTip = 'הסר מזהה מותאם'
        $rm.Tag = $App.Id
        [System.Windows.Controls.Grid]::SetRow($rm, 2)
        [System.Windows.Controls.Grid]::SetColumn($rm, 1)
        $rm.Add_Click({ $cid = [string]$this.Tag; Invoke-QDSafe { Invoke-QDCustomAppRemoval -Id $cid } })
        [void]$grid.Children.Add($rm)
    }
    $card.Child = $grid
    $card.Tag = $entry
    $card.Add_MouseLeftButtonUp({
            $t = $this.Tag
            if ($t.Toggle.IsEnabled) { $t.Toggle.IsChecked = -not [bool]$t.Toggle.IsChecked }
        })
    $toggle.Add_Checked({ Sync-QDAppCount })
    $toggle.Add_Unchecked({ Sync-QDAppCount })
    $script:AppCards[$App.Id] = $entry
    $cat = if ($App.Custom) { 'מותאם אישית' } else { $App.Category }
    [void]$script:CategoryPanels[$cat].Wrap.Children.Add($card)
    if ($App.Custom) { $script:CategoryPanels[$cat].Container.Visibility = [System.Windows.Visibility]::Visible }
    Sync-QDAppCardState -Id $App.Id
}

function Sync-QDAppCardState {
    <#
    .SYNOPSIS
        מעדכן את מצב הזמינות בכרטיסי התוכנות לפי בדיקת winget ברקע.
    #>
    [CmdletBinding()]
    param([string]$Id = '')
    $ids = if ($Id) { @($Id) } else { @($script:AppCards.Keys) }
    foreach ($k in $ids) {
        if (-not $script:AppCards.Contains($k)) { continue }
        $e = $script:AppCards[$k]
        $state = if ($Sync.CatalogStatus.ContainsKey($k)) { [string]$Sync.CatalogStatus[$k] } elseif ($e.App.Custom) { 'custom' } else { 'checking' }
        $text = 'בודק זמינות…'; $color = '#8A93A3'; $enabled = $true
        switch ($state) {
            'ok' { $text = 'זמין'; $color = '#2DD4BF' }
            'unavailable' { $text = 'לא זמין'; $color = '#F87171'; $enabled = $false }
            'unknown' { $text = 'לא נבדק (אין חיבור?)'; $color = '#FBBF24' }
            'nowinget' { $text = 'winget יותקן בזמן ההרצה'; $color = '#FBBF24' }
            'custom' { $text = 'מזהה מותאם'; $color = '#F5A524' }
        }
        if ($e.App.Source -eq 'msstore' -and $state -eq 'ok') { $text = 'זמין (Microsoft Store)' }
        $e.Status.Text = $text
        $e.Status.Foreground = Get-QDBrush -Hex $color
        $e.Toggle.IsEnabled = $enabled
        $e.Card.Opacity = if ($enabled) { 1.0 } else { 0.55 }
    }
}

function Sync-QDAppCount {
    <#
    .SYNOPSIS
        מעדכן את מונה התוכנות שנבחרו.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:AppCards) { return }
    $n = @($script:AppCards.Values | Where-Object { $_.Toggle.IsChecked }).Count
    $UI.TxtAppCount.Text = "$n נבחרו"
}

function Sync-QDAppFilter {
    <#
    .SYNOPSIS
        מסנן את כרטיסי הקטלוג לפי תיבת החיפוש.
    #>
    [CmdletBinding()]
    param()
    $q = $UI.TxtAppSearch.Text.Trim().ToLowerInvariant()
    foreach ($e in $script:AppCards.Values) {
        $match = ($q -eq '') -or $e.App.Name.ToLowerInvariant().Contains($q) -or $e.App.Id.ToLowerInvariant().Contains($q)
        $e.Card.Visibility = if ($match) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    foreach ($cat in $script:CategoryPanels.Keys) {
        $cp = $script:CategoryPanels[$cat]
        $visible = @($cp.Wrap.Children | Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible }).Count
        $cp.Container.Visibility = if ($visible -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Add-QDCustomApp {
    <#
    .SYNOPSIS
        מוסיף מזהה winget מותאם (או מסמן פריט קטלוג קיים).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$Name = '', [string]$Source = 'winget')
    if ($script:AppCards.Contains($Id)) {
        $script:AppCards[$Id].Toggle.IsChecked = $true
        Show-QDToast -Message "$Id כבר ברשימה — סומן להתקנה" -Kind 'info'
        return
    }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Id }
    $Sync.CatalogStatus[$Id] = 'ok'
    Add-QDAppCard -App @{ Id = $Id; Name = $Name; Source = $Source; Category = 'מותאם אישית'; Custom = $true } -Checked $true
    Sync-QDAppCount
    Show-QDToast -Message "נוסף: $Name ($Id)" -Kind 'success'
}

function Invoke-QDCustomAppRemoval {
    <#
    .SYNOPSIS
        מסיר כרטיס של מזהה מותאם.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:AppCards.Contains($Id)) { return }
    $e = $script:AppCards[$Id]
    $cp = $script:CategoryPanels['מותאם אישית']
    $cp.Wrap.Children.Remove($e.Card)
    $script:AppCards.Remove($Id)
    if ($cp.Wrap.Children.Count -eq 0) { $cp.Container.Visibility = [System.Windows.Visibility]::Collapsed }
    Sync-QDAppCount
}

function Invoke-QDWingetSearch {
    <#
    .SYNOPSIS
        מפעיל חיפוש winget ברקע עבור מזהה/מילת מפתח.
    #>
    [CmdletBinding()]
    param()
    $q = $UI.TxtWingetQuery.Text.Trim()
    if ($q.Length -lt 2) { Show-QDToast -Message 'הקלד לפחות 2 תווים לחיפוש' -Kind 'warning'; return }
    if ($Sync.SearchState -eq 'running') { return }
    $Sync.SearchState = 'running'
    $UI.BtnWingetSearch.IsEnabled = $false
    $UI.TxtWingetState.Text = "מחפש את `"$q`" ב-winget…"
    Invoke-QDWorker -Name 'search' -Parameters @{ Query = $q } -ScriptBlock {
        param($Query)
        Set-StrictMode -Version Latest
        try {
            $Sync.SearchResults = @(Search-QDWinget -Query $Query)
            $Sync.SearchError = ''
            if ([string]::IsNullOrWhiteSpace($Sync.WingetPath)) { $Sync.SearchError = 'winget אינו מותקן במחשב זה — הוא יותקן אוטומטית בזמן ההרצה' }
        }
        catch {
            $Sync.SearchResults = @()
            $Sync.SearchError = $_.Exception.Message
        }
        $Sync.SearchState = 'done'
        Send-QDPump -Force
    }
}

function Show-QDSearchResult {
    <#
    .SYNOPSIS
        מציג את תוצאות חיפוש winget לבחירה.
    #>
    [CmdletBinding()]
    param()
    $UI.BtnWingetSearch.IsEnabled = $true
    $results = @($Sync.SearchResults)
    if ($Sync.SearchError) {
        $UI.TxtWingetState.Text = $Sync.SearchError
        Show-QDToast -Message $Sync.SearchError -Kind 'error'
        return
    }
    if ($results.Count -eq 0) {
        $UI.TxtWingetState.Text = 'לא נמצאו תוצאות.'
        Show-QDToast -Message 'לא נמצאו תוצאות ב-winget' -Kind 'warning'
        return
    }
    $UI.TxtWingetState.Text = "נמצאו $($results.Count) תוצאות."
    $items = @($results | ForEach-Object { '{0}   |   {1}   |   {2}' -f $_.Name, $_.Id, $_.Source })
    $res = Show-QDDialog -Title 'תוצאות חיפוש winget' -Message 'בחר חבילה להוספה לרשימת ההתקנה:' -Kind 'question' -Buttons @('הוסף', 'ביטול') -ListItems $items
    if ($res.Button -eq 0 -and $res.SelectedIndex -ge 0) {
        $pick = $results[$res.SelectedIndex]
        Add-QDCustomApp -Id $pick.Id -Name $pick.Name -Source $pick.Source
        $UI.TxtWingetQuery.Text = ''
    }
}

#endregion UI — software catalog page

#region UI — cleanup page

function Build-QDDebloatUi {
    <#
    .SYNOPSIS
        בונה את מתגי ההסרה של אפליקציות מובנות.
    #>
    [CmdletBinding()]
    param()
    $UI.DebloatPanel.Children.Clear()
    $script:DebloatToggles = [ordered]@{}
    foreach ($item in $QD.Debloat) {
        $tile = New-Object System.Windows.Controls.Border
        $tile.Style = Get-QDResource -Key 'Tile'
        $tile.Width = 262
        $tile.Padding = New-Object System.Windows.Thickness(14, 8, 14, 8)
        $chk = New-Object System.Windows.Controls.CheckBox
        $sp = New-Object System.Windows.Controls.StackPanel
        $title = Get-QDTextBlock -Text $item.Label
        $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        [void]$sp.Children.Add($title)
        $sub = Get-QDTextBlock -Text $item.Name -StyleKey 'Caption' -Ltr
        $sub.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        $sub.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        if ($item.Group -eq 'xbox') { $sub.Text = $item.Name + '  · Xbox' }
        [void]$sp.Children.Add($sub)
        $chk.Content = $sp
        $chk.Margin = New-Object System.Windows.Thickness(0)
        $chk.Add_Checked({ Sync-QDDebloatCount })
        $chk.Add_Unchecked({ Sync-QDDebloatCount })
        $tile.Child = $chk
        [void]$UI.DebloatPanel.Children.Add($tile)
        $script:DebloatToggles[$item.Name] = $chk
    }
}

function Sync-QDDebloatCount {
    <#
    .SYNOPSIS
        מעדכן מונה פריטי ניקוי שנבחרו.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:DebloatToggles) { return }
    $n = @($script:DebloatToggles.Values | Where-Object { $_.IsChecked }).Count
    $UI.TxtDebloatCount.Text = "($n מתוך $($script:DebloatToggles.Count))"
}

#endregion UI — cleanup page

#region UI — network page (dynamic rows)

function Get-QDRowShell {
    <#
    .SYNOPSIS
        יוצר מסגרת שורה דינמית (כונן / Wi-Fi / מדפסת).
    #>
    [CmdletBinding()]
    param()
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-QDBrush -Hex '#1B2029'
    $b.BorderBrush = Get-QDBrush -Hex '#232935'
    $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $b.Padding = New-Object System.Windows.Thickness(12, 10, 12, 10)
    $b.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $b.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0 -To 1 -Milliseconds 220))
    return $b
}

function Get-QDGrid {
    <#
    .SYNOPSIS
        יוצר Grid עם עמודות לפי רשימת רוחבים ('*', 'Auto', או מספר).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Columns)
    $g = New-Object System.Windows.Controls.Grid
    foreach ($c in $Columns) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($c -eq '*') { $cd.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        elseif ($c -eq 'Auto') { $cd.Width = [System.Windows.GridLength]::Auto }
        else { $cd.Width = New-Object System.Windows.GridLength([double]$c) }
        $g.ColumnDefinitions.Add($cd)
    }
    return $g
}

function Add-QDGridChild {
    <#
    .SYNOPSIS
        מוסיף אלמנט ל-Grid בעמודה נתונה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Grid, [Parameter(Mandatory)]$Element, [int]$Column = 0, [int]$Row = 0)
    [System.Windows.Controls.Grid]::SetColumn($Element, $Column)
    [System.Windows.Controls.Grid]::SetRow($Element, $Row)
    [void]$Grid.Children.Add($Element)
}

function Get-QDRemoveButton {
    <#
    .SYNOPSIS
        כפתור הסרת שורה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Row)
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = Get-QDResource -Key 'GhostButton'
    $btn.Content = Get-QDIconPath -Name 'IconTrash' -Size 15
    $btn.ToolTip = 'הסר'
    $btn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $btn.Tag = $Row
    $btn.Add_Click({ $r = $this.Tag; Invoke-QDSafe { Invoke-QDRowRemoval -Row $r } })
    return $btn
}

function Invoke-QDRowRemoval {
    <#
    .SYNOPSIS
        מסיר שורה דינמית מהממשק ומהרשימה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Row)
    $Row.Panel.Children.Remove($Row.Root)
    $Row.List.Remove($Row)
}

function Get-QDTextInput {
    <#
    .SYNOPSIS
        יוצר TextBox עם placeholder.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '', [string]$Placeholder = '', [switch]$Ltr)
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $Text
    $t.Tag = $Placeholder
    if ($Ltr) { $t.FlowDirection = [System.Windows.FlowDirection]::LeftToRight }
    return $t
}

function Add-QDDriveRow {
    <#
    .SYNOPSIS
        מוסיף שורת כונן ממופה (אות, נתיב UNC, תווית).
    #>
    [CmdletBinding()]
    param([hashtable]$Data = @{})
    $row = @{ List = $script:DriveRows; Panel = $UI.DrivesPanel }
    $shell = Get-QDRowShell
    $g = Get-QDGrid -Columns @('90', '10', '*', '10', '170', 'Auto')
    $letters = @([char[]](68..90) | ForEach-Object { "$($_):" })
    $cmb = New-Object System.Windows.Controls.ComboBox
    $cmb.ItemsSource = $letters
    $used = @($script:DriveRows | ForEach-Object { [string]$_.Letter.SelectedItem })
    $want = if ($Data.ContainsKey('letter') -and $Data.letter) { "$($Data.letter):" } else { @($letters | Where-Object { $used -notcontains $_ -and $_ -notin @('D:', 'E:') }) | Select-Object -First 1 }
    $cmb.SelectedItem = $want
    $path = Get-QDTextInput -Text $(if ($Data.ContainsKey('path')) { [string]$Data.path } else { '' }) -Placeholder '\\server\share' -Ltr
    $label = Get-QDTextInput -Text $(if ($Data.ContainsKey('label')) { [string]$Data.label } else { '' }) -Placeholder 'תווית (אופציונלי)'
    Add-QDGridChild -Grid $g -Element $cmb -Column 0
    Add-QDGridChild -Grid $g -Element $path -Column 2
    Add-QDGridChild -Grid $g -Element $label -Column 4
    $row.Letter = $cmb
    $row.Path = $path
    $row.Label = $label
    $row.Root = $shell
    Add-QDGridChild -Grid $g -Element (Get-QDRemoveButton -Row $row) -Column 5
    $shell.Child = $g
    [void]$UI.DrivesPanel.Children.Add($shell)
    [void]$script:DriveRows.Add($row)
}

function Add-QDWifiRow {
    <#
    .SYNOPSIS
        מוסיף שורת רשת Wi-Fi (SSID + סוג אבטחה).
    #>
    [CmdletBinding()]
    param([hashtable]$Data = @{})
    $row = @{ List = $script:WifiRows; Panel = $UI.WifiPanel }
    $shell = Get-QDRowShell
    $g = Get-QDGrid -Columns @('*', '10', '140', 'Auto')
    $ssid = Get-QDTextInput -Text $(if ($Data.ContainsKey('ssid')) { [string]$Data.ssid } else { '' }) -Placeholder 'SSID' -Ltr
    $sec = New-Object System.Windows.Controls.ComboBox
    $sec.ItemsSource = @('WPA2', 'WPA3')
    $sec.SelectedItem = if ($Data.ContainsKey('security') -and $Data.security -eq 'WPA3') { 'WPA3' } else { 'WPA2' }
    Add-QDGridChild -Grid $g -Element $ssid -Column 0
    Add-QDGridChild -Grid $g -Element $sec -Column 2
    $row.Ssid = $ssid
    $row.Security = $sec
    $row.Root = $shell
    Add-QDGridChild -Grid $g -Element (Get-QDRemoveButton -Row $row) -Column 3
    $shell.Child = $g
    [void]$UI.WifiPanel.Children.Add($shell)
    [void]$script:WifiRows.Add($row)
}

function Add-QDPrinterRow {
    <#
    .SYNOPSIS
        מוסיף שורת מדפסת (IP או משותפת UNC).
    #>
    [CmdletBinding()]
    param([ValidateSet('ip', 'unc')][string]$Type = 'ip', [hashtable]$Data = @{})
    $row = @{ List = $script:PrinterRows; Panel = $UI.PrintersPanel; Type = $Type }
    $shell = Get-QDRowShell
    $stack = New-Object System.Windows.Controls.StackPanel
    $badge = New-Object System.Windows.Controls.Border
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(999)
    $badge.Background = Get-QDBrush -Hex '#26F5A524'
    $badge.Padding = New-Object System.Windows.Thickness(10, 3, 10, 3)
    $badge.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badge.Child = Get-QDTextBlock -Text $(if ($Type -eq 'ip') { 'IP' } else { 'משותפת' }) -FontSize 12 -Bold -Color '#F5A524'

    if ($Type -eq 'ip') {
        $g = Get-QDGrid -Columns @('Auto', '*', '10', '150', '10', '230')
        $name = Get-QDTextInput -Text $(if ($Data.ContainsKey('name')) { [string]$Data.name } else { '' }) -Placeholder 'שם המדפסת'
        $ip = Get-QDTextInput -Text $(if ($Data.ContainsKey('ip')) { [string]$Data.ip } else { '' }) -Placeholder '192.168.1.50' -Ltr
        $drv = New-Object System.Windows.Controls.ComboBox
        $want = if ($Data.ContainsKey('driver') -and $Data.driver) { [string]$Data.driver } else { 'Microsoft IPP Class Driver' }
        $list = @($script:DriverNames)
        if ($list -notcontains $want) { $list += $want }
        $drv.ItemsSource = $list
        $drv.SelectedItem = $want
        $drv.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
        Add-QDGridChild -Grid $g -Element $badge -Column 0
        Add-QDGridChild -Grid $g -Element $name -Column 1
        Add-QDGridChild -Grid $g -Element $ip -Column 3
        Add-QDGridChild -Grid $g -Element $drv -Column 5
        $row.Name = $name
        $row.Ip = $ip
        $row.Driver = $drv
    }
    else {
        $g = Get-QDGrid -Columns @('Auto', '*')
        $path = Get-QDTextInput -Text $(if ($Data.ContainsKey('path')) { [string]$Data.path } else { '' }) -Placeholder '\\server\printer' -Ltr
        Add-QDGridChild -Grid $g -Element $badge -Column 0
        Add-QDGridChild -Grid $g -Element $path -Column 1
        $row.Path = $path
    }
    [void]$stack.Children.Add($g)

    $opts = Get-QDGrid -Columns @('Auto', 'Auto', '*', 'Auto')
    $opts.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    $def = New-Object System.Windows.Controls.RadioButton
    $def.GroupName = 'DefaultPrinter'
    $def.Content = 'מדפסת ברירת מחדל'
    $def.IsChecked = ($Data.ContainsKey('default') -and [bool]$Data.default)
    $def.Add_PreviewMouseLeftButtonDown({
            if ($this.IsChecked) { $this.IsChecked = $false; $_.Handled = $true }
        })
    Add-QDGridChild -Grid $opts -Element $def -Column 0
    $row.Default = $def
    if ($Type -eq 'ip') {
        $tp = New-Object System.Windows.Controls.CheckBox
        $tp.Content = 'הדפס דף ניסיון'
        $tp.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)
        $tp.IsChecked = ($Data.ContainsKey('testPage') -and [bool]$Data.testPage)
        Add-QDGridChild -Grid $opts -Element $tp -Column 1
        $row.TestPage = $tp
    }
    $row.Root = $shell
    Add-QDGridChild -Grid $opts -Element (Get-QDRemoveButton -Row $row) -Column 3
    [void]$stack.Children.Add($opts)
    $shell.Child = $stack
    [void]$UI.PrintersPanel.Children.Add($shell)
    [void]$script:PrinterRows.Add($row)
}

function Sync-QDDriverCombo {
    <#
    .SYNOPSIS
        מרענן את רשימות מנהלי ההתקן בשורות המדפסות לאחר טעינה ברקע.
    #>
    [CmdletBinding()]
    param()
    $drivers = @($Sync.PrinterDrivers)
    if ($drivers.Count -eq 0) { return }
    $script:DriverNames = $drivers
    foreach ($row in @($script:PrinterRows)) {
        if ($row.Type -ne 'ip') { continue }
        $current = [string]$row.Driver.SelectedItem
        $list = @($drivers)
        if ($current -and $list -notcontains $current) { $list += $current }
        $row.Driver.ItemsSource = $list
        $row.Driver.SelectedItem = $current
    }
}

function Sync-QDJoinPanel {
    <#
    .SYNOPSIS
        מציג את שדות קבוצת העבודה / הדומיין לפי הבחירה.
    #>
    [CmdletBinding()]
    param()
    $UI.PanelWorkgroup.Visibility = if ($UI.RbJoinWorkgroup.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $UI.PanelDomain.Visibility = if ($UI.RbJoinDomain.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

#endregion UI — network page

#region UI — profile <-> controls

function Read-QDProfileFromUi {
    <#
    .SYNOPSIS
        אוסף את כל הבחירות מהממשק לפרופיל (ללא שם מחשב וללא סיסמאות).
    #>
    [CmdletBinding()]
    param()
    $p = Get-QDDefaultProfile
    $name = $UI.TxtProfileName.Text.Trim()
    $p.name = if ($name) { $name } else { 'ללא שם' }
    $p.description = $UI.TxtProfileDesc.Text
    $p.apps = @($QD.Catalog | Where-Object { $script:AppCards.Contains($_.Id) -and $script:AppCards[$_.Id].Toggle.IsChecked } | ForEach-Object { $_.Id })
    $p.customApps = @($script:AppCards.Values | Where-Object { $_.App.Custom -and $_.Toggle.IsChecked } | ForEach-Object { [ordered]@{ id = $_.App.Id; name = $_.App.Name; source = $_.App.Source } })
    $p.debloat.packages = @($script:DebloatToggles.Keys | Where-Object { $script:DebloatToggles[$_].IsChecked })
    $p.debloat.consumerFeatures = [bool]$UI.ChkConsumerFeatures.IsChecked
    $p.debloat.ads = [bool]$UI.ChkAds.IsChecked
    $p.debloat.bingSearch = [bool]$UI.ChkBingSearch.IsChecked
    $p.debloat.copilot = [bool]$UI.ChkCopilot.IsChecked
    $p.debloat.oneDrive = [bool]$UI.ChkOneDrive.IsChecked
    $p.system.timezone = [bool]$UI.ChkTimezone.IsChecked
    $p.system.hebrewKeyboard = [bool]$UI.ChkHebrewKeyboard.IsChecked
    $p.system.powerPlan = if ($UI.CmbPowerPlan.SelectedIndex -eq 1) { 'high' } else { 'balanced' }
    $p.system.disableHibernation = [bool]$UI.ChkDisableHibernation.IsChecked
    $p.system.disableFastStartup = [bool]$UI.ChkDisableFastStartup.IsChecked
    $p.system.showExtensions = [bool]$UI.ChkShowExtensions.IsChecked
    $p.system.showHidden = [bool]$UI.ChkShowHidden.IsChecked
    $p.system.explorerThisPC = [bool]$UI.ChkExplorerThisPC.IsChecked
    $p.system.taskbarLeft = [bool]$UI.ChkTaskbarLeft.IsChecked
    $p.system.classicContextMenu = [bool]$UI.ChkClassicContextMenu.IsChecked
    $p.system.enableRdp = [bool]$UI.ChkEnableRdp.IsChecked
    $p.system.createLocalAdmin = [bool]$UI.ChkCreateLocalAdmin.IsChecked
    $p.system.windowsUpdateScan = [bool]$UI.ChkWindowsUpdateScan.IsChecked
    $p.network.joinType = if ($UI.RbJoinDomain.IsChecked) { 'domain' } elseif ($UI.RbJoinWorkgroup.IsChecked) { 'workgroup' } else { 'none' }
    $p.network.workgroup = $UI.TxtWorkgroup.Text.Trim()
    $p.network.domain = $UI.TxtDomain.Text.Trim()
    $p.network.ou = $UI.TxtOU.Text.Trim()
    $p.network.drives = @($script:DriveRows | ForEach-Object {
            [ordered]@{ letter = ([string]$_.Letter.SelectedItem).TrimEnd(':'); path = $_.Path.Text.Trim(); label = $_.Label.Text.Trim() }
        })
    $p.network.wifi = @($script:WifiRows | ForEach-Object { [ordered]@{ ssid = $_.Ssid.Text.Trim(); security = [string]$_.Security.SelectedItem } })
    $p.network.printers = @($script:PrinterRows | ForEach-Object {
            $row = $_
            if ($row.Type -eq 'ip') {
                [ordered]@{ type = 'ip'; name = $row.Name.Text.Trim(); ip = $row.Ip.Text.Trim(); path = ''; driver = [string]$row.Driver.SelectedItem; default = [bool]$row.Default.IsChecked; testPage = [bool]$row.TestPage.IsChecked }
            }
            else {
                $pp = $row.Path.Text.Trim()
                $pn = @($pp -split '\\' | Where-Object { $_ }) | Select-Object -Last 1
                [ordered]@{ type = 'unc'; name = [string]$pn; ip = ''; path = $pp; driver = ''; default = [bool]$row.Default.IsChecked; testPage = $false }
            }
        })
    return $p
}

function Write-QDProfileToUi {
    <#
    .SYNOPSIS
        מציג פרופיל מנורמל בכל פקדי הממשק.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileData)
    $p = $ProfileData
    $script:Loading = $true
    try {
        $UI.TxtProfileName.Text = $p.name
        $UI.TxtProfileDesc.Text = $p.description
        foreach ($cid in @($script:AppCards.Keys | Where-Object { $script:AppCards[$_].App.Custom })) { Invoke-QDCustomAppRemoval -Id $cid }
        foreach ($e in $script:AppCards.Values) { $e.Toggle.IsChecked = (@($p.apps) -contains $e.App.Id) }
        foreach ($c in @($p.customApps)) {
            if ($script:AppCards.Contains($c.id)) { $script:AppCards[$c.id].Toggle.IsChecked = $true; continue }
            Add-QDAppCard -App @{ Id = $c.id; Name = $c.name; Source = $c.source; Category = 'מותאם אישית'; Custom = $true } -Checked $true
        }
        foreach ($k in $script:DebloatToggles.Keys) { $script:DebloatToggles[$k].IsChecked = (@($p.debloat.packages) -contains $k) }
        $UI.ChkConsumerFeatures.IsChecked = $p.debloat.consumerFeatures
        $UI.ChkAds.IsChecked = $p.debloat.ads
        $UI.ChkBingSearch.IsChecked = $p.debloat.bingSearch
        $UI.ChkCopilot.IsChecked = $p.debloat.copilot
        $UI.ChkOneDrive.IsChecked = $p.debloat.oneDrive
        $UI.ChkTimezone.IsChecked = $p.system.timezone
        $UI.ChkHebrewKeyboard.IsChecked = $p.system.hebrewKeyboard
        $UI.CmbPowerPlan.SelectedIndex = if ($p.system.powerPlan -eq 'high') { 1 } else { 0 }
        $UI.ChkDisableHibernation.IsChecked = $p.system.disableHibernation
        $UI.ChkDisableFastStartup.IsChecked = $p.system.disableFastStartup
        $UI.ChkShowExtensions.IsChecked = $p.system.showExtensions
        $UI.ChkShowHidden.IsChecked = $p.system.showHidden
        $UI.ChkExplorerThisPC.IsChecked = $p.system.explorerThisPC
        $UI.ChkTaskbarLeft.IsChecked = $p.system.taskbarLeft
        $UI.ChkClassicContextMenu.IsChecked = $p.system.classicContextMenu
        $UI.ChkEnableRdp.IsChecked = $p.system.enableRdp
        $UI.ChkCreateLocalAdmin.IsChecked = $p.system.createLocalAdmin
        $UI.ChkWindowsUpdateScan.IsChecked = $p.system.windowsUpdateScan
        switch ($p.network.joinType) {
            'domain' { $UI.RbJoinDomain.IsChecked = $true }
            'workgroup' { $UI.RbJoinWorkgroup.IsChecked = $true }
            default { $UI.RbJoinNone.IsChecked = $true }
        }
        $UI.TxtWorkgroup.Text = $p.network.workgroup
        $UI.TxtDomain.Text = $p.network.domain
        $UI.TxtOU.Text = $p.network.ou
        $UI.DrivesPanel.Children.Clear(); $script:DriveRows.Clear()
        $UI.WifiPanel.Children.Clear(); $script:WifiRows.Clear()
        $UI.PrintersPanel.Children.Clear(); $script:PrinterRows.Clear()
        foreach ($dr in @($p.network.drives)) { Add-QDDriveRow -Data @{ letter = $dr.letter; path = $dr.path; label = $dr.label } }
        foreach ($w in @($p.network.wifi)) { Add-QDWifiRow -Data @{ ssid = $w.ssid; security = $w.security } }
        foreach ($pr in @($p.network.printers)) {
            Add-QDPrinterRow -Type $pr.type -Data @{ name = $pr.name; ip = $pr.ip; path = $pr.path; driver = $pr.driver; default = $pr.default; testPage = $pr.testPage }
        }
        Sync-QDJoinPanel
        Sync-QDAppCount
        Sync-QDDebloatCount
        Sync-QDAppFilter
    }
    finally {
        $script:Loading = $false
    }
    $script:SavedSnapshot = ConvertTo-QDProfileJson -ProfileData (Read-QDProfileFromUi) -Compress
    Sync-QDDirtyIndicator
}

function Test-QDProfileDirty {
    <#
    .SYNOPSIS
        בודק האם יש שינויים שלא נשמרו ביחס לפרופיל שנטען.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:Loading -or $null -eq $script:SavedSnapshot) { return $false }
    $now = ConvertTo-QDProfileJson -ProfileData (Read-QDProfileFromUi) -Compress
    return ($now -ne $script:SavedSnapshot)
}

function Sync-QDDirtyIndicator {
    <#
    .SYNOPSIS
        מעדכן את נקודת "שינויים שלא נשמרו" ואת שם הפרופיל בסרגל.
    #>
    [CmdletBinding()]
    param()
    $dirty = Test-QDProfileDirty
    $vis = if ($dirty) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $UI.DotUnsaved.Visibility = $vis
    $UI.DotUnsavedPage.Visibility = $vis
    $n = $UI.TxtProfileName.Text.Trim()
    $UI.TxtNavProfile.Text = if ($n) { $n } else { '—' }
}

#endregion UI — profile <-> controls

#region UI — profile management

function Sync-QDProfileCombo {
    <#
    .SYNOPSIS
        טוען מחדש את רשימת הפרופילים לתיבה ובוחר פרופיל לפי נתיב.
    #>
    [CmdletBinding()]
    param([string]$SelectPath = '')
    $script:ProfileEntries = @(Get-QDProfileList)
    $script:SuppressProfileChange = $true
    try {
        $UI.CmbProfile.ItemsSource = @($script:ProfileEntries | ForEach-Object { $_.Name })
        $idx = -1
        for ($i = 0; $i -lt $script:ProfileEntries.Count; $i++) { if ($script:ProfileEntries[$i].Path -eq $SelectPath) { $idx = $i } }
        $UI.CmbProfile.SelectedIndex = $idx
        $script:CurrentProfileIndex = $idx
    }
    finally { $script:SuppressProfileChange = $false }
}

function Import-QDProfileIntoUi {
    <#
    .SYNOPSIS
        טוען פרופיל מקובץ לממשק; במקרה של קובץ פגום מציג הודעה ולא קורס.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $p = Import-QDProfileFile -Path $Path
    }
    catch {
        Show-QDToast -Message $_.Exception.Message -Kind 'error'
        Write-QDLog -Message $_.Exception.Message -Level 'ERROR'
        return $false
    }
    Write-QDProfileToUi -ProfileData $p
    $script:CurrentProfilePath = $Path
    $script:CurrentProfileName = $p.name
    Write-QDLog -Message ('נטען פרופיל: ' + $p.name)
    return $true
}

function Invoke-QDProfileSwitch {
    <#
    .SYNOPSIS
        מטפל בבחירת פרופיל אחר (עם אישור אם יש שינויים שלא נשמרו).
    #>
    [CmdletBinding()]
    param()
    if ($script:SuppressProfileChange) { return }
    $idx = $UI.CmbProfile.SelectedIndex
    if ($idx -lt 0 -or $idx -eq $script:CurrentProfileIndex) { return }
    if (Test-QDProfileDirty) {
        $res = Show-QDDialog -Title 'שינויים שלא נשמרו' -Message ('בפרופיל "{0}" יש שינויים שלא נשמרו. מה לעשות?' -f $script:CurrentProfileName) -Kind 'warning' -Buttons @('שמור והחלף', 'החלף בלי לשמור', 'ביטול')
        if ($res.Button -eq 0) {
            $target = $script:ProfileEntries[$idx].Path
            if (-not (Save-QDCurrentProfile -Quiet)) { $res = [pscustomobject]@{ Button = 2 } }
            else {
                Sync-QDProfileCombo -SelectPath $target
                [void](Import-QDProfileIntoUi -Path $target)
                return
            }
        }
        if ($res.Button -ne 0 -and $res.Button -ne 1) {
            $script:SuppressProfileChange = $true
            $UI.CmbProfile.SelectedIndex = $script:CurrentProfileIndex
            $script:SuppressProfileChange = $false
            return
        }
    }
    $script:CurrentProfileIndex = $idx
    [void](Import-QDProfileIntoUi -Path $script:ProfileEntries[$idx].Path)
}

function Save-QDCurrentProfile {
    <#
    .SYNOPSIS
        שומר את הפרופיל הנוכחי מהממשק לקובץ.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Quiet)
    $p = Read-QDProfileFromUi
    if ([string]::IsNullOrWhiteSpace($UI.TxtProfileName.Text)) {
        Show-QDToast -Message 'יש להזין שם לפרופיל' -Kind 'warning'
        return $false
    }
    $path = if ($p.name -eq $script:CurrentProfileName -and $script:CurrentProfilePath) { $script:CurrentProfilePath } else { Get-QDProfileFileName -Name $p.name }
    if ($path -ne $script:CurrentProfilePath -and (Test-Path -LiteralPath $path)) {
        $ow = Show-QDDialog -Title 'הפרופיל קיים' -Message ('כבר קיים פרופיל בשם "{0}". להחליף אותו?' -f $p.name) -Kind 'warning' -Buttons @('החלף', 'ביטול')
        if ($ow.Button -ne 0) { return $false }
    }
    $saved = Save-QDProfileFile -ProfileData $p -Path $path
    $script:CurrentProfilePath = $saved
    $script:CurrentProfileName = $p.name
    $script:SavedSnapshot = ConvertTo-QDProfileJson -ProfileData (Read-QDProfileFromUi) -Compress
    Sync-QDProfileCombo -SelectPath $saved
    Sync-QDDirtyIndicator
    Write-QDLog -Message ('הפרופיל נשמר: ' + $saved) -Level 'OK'
    if (-not $Quiet) { Show-QDToast -Message ('הפרופיל "{0}" נשמר' -f $p.name) -Kind 'success' }
    return $true
}

function Copy-QDCurrentProfile {
    <#
    .SYNOPSIS
        משכפל את הפרופיל הנוכחי בשם חדש.
    #>
    [CmdletBinding()]
    param()
    $base = $UI.TxtProfileName.Text.Trim()
    $res = Show-QDDialog -Title 'שכפול פרופיל' -Message 'הזן שם לעותק החדש:' -Kind 'question' -Buttons @('שכפל', 'ביטול') -Fields @(@{ Key = 'name'; Label = 'שם'; Type = 'text'; Value = ($base + ' - עותק') })
    if ($res.Button -ne 0) { return }
    $newName = ([string]$res.Values['name']).Trim()
    if (-not $newName) { Show-QDToast -Message 'שם ריק — השכפול בוטל' -Kind 'warning'; return }
    $path = Get-QDProfileFileName -Name $newName
    if (Test-Path -LiteralPath $path) { Show-QDToast -Message 'כבר קיים פרופיל בשם זה' -Kind 'error'; return }
    $p = Read-QDProfileFromUi
    $p.name = $newName
    $saved = Save-QDProfileFile -ProfileData $p -Path $path
    Sync-QDProfileCombo -SelectPath $saved
    [void](Import-QDProfileIntoUi -Path $saved)
    Show-QDToast -Message ('נוצר הפרופיל "{0}"' -f $newName) -Kind 'success'
}

function Invoke-QDProfileDelete {
    <#
    .SYNOPSIS
        מוחק את הפרופיל הנוכחי (עם אישור).
    #>
    [CmdletBinding()]
    param()
    if (-not $script:CurrentProfilePath -or -not (Test-Path -LiteralPath $script:CurrentProfilePath)) {
        Show-QDToast -Message 'הפרופיל הנוכחי עוד לא נשמר לקובץ' -Kind 'warning'
        return
    }
    $res = Show-QDDialog -Title 'מחיקת פרופיל' -Message ('למחוק לצמיתות את הפרופיל "{0}"?' -f $script:CurrentProfileName) -Kind 'error' -Buttons @('מחק', 'ביטול')
    if ($res.Button -ne 0) { return }
    Remove-Item -LiteralPath $script:CurrentProfilePath -Force
    Write-QDLog -Message ('נמחק פרופיל: ' + $script:CurrentProfilePath)
    $deletedName = $script:CurrentProfileName
    $script:CurrentProfilePath = ''
    $script:CurrentProfileName = ''
    $list = @(Get-QDProfileList)
    if ($list.Count -gt 0) {
        Sync-QDProfileCombo -SelectPath $list[0].Path
        [void](Import-QDProfileIntoUi -Path $list[0].Path)
    }
    else {
        Sync-QDProfileCombo
        Write-QDProfileToUi -ProfileData (Get-QDDefaultProfile)
    }
    Show-QDToast -Message ('הפרופיל "{0}" נמחק' -f $deletedName) -Kind 'success'
}

function Import-QDProfileDialog {
    <#
    .SYNOPSIS
        מייבא קובץ פרופיל JSON לתיקיית הפרופילים (עם אימות).
    #>
    [CmdletBinding()]
    param()
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = 'פרופיל QuickDeploy (*.json)|*.json'
    $ofd.Title = 'ייבוא פרופיל'
    if (-not $ofd.ShowDialog($script:MainWindow)) { return }
    try { $p = Import-QDProfileFile -Path $ofd.FileName }
    catch { Show-QDToast -Message $_.Exception.Message -Kind 'error'; return }
    $target = Get-QDProfileFileName -Name $p.name
    if (Test-Path -LiteralPath $target) {
        $p.name = $p.name + ' (מיובא ' + (Get-Date -Format 'HHmmss') + ')'
        $target = Get-QDProfileFileName -Name $p.name
    }
    $saved = Save-QDProfileFile -ProfileData $p -Path $target
    Sync-QDProfileCombo -SelectPath $saved
    [void](Import-QDProfileIntoUi -Path $saved)
    Show-QDToast -Message ('יובא הפרופיל "{0}"' -f $p.name) -Kind 'success'
}

function Export-QDProfileDialog {
    <#
    .SYNOPSIS
        מייצא את הפרופיל הנוכחי (כפי שמוצג בממשק) לקובץ JSON.
    #>
    [CmdletBinding()]
    param()
    $p = Read-QDProfileFromUi
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = 'פרופיל QuickDeploy (*.json)|*.json'
    $sfd.Title = 'ייצוא פרופיל'
    $sfd.FileName = [System.IO.Path]::GetFileName((Get-QDProfileFileName -Name $p.name))
    if (-not $sfd.ShowDialog($script:MainWindow)) { return }
    $null = Save-QDProfileFile -ProfileData $p -Path $sfd.FileName
    Show-QDToast -Message ('יוצא אל ' + $sfd.FileName) -Kind 'success'
}

#endregion UI — profile management

#region UI — system info

function Show-QDSysInfo {
    <#
    .SYNOPSIS
        מציג את כרטיס פרטי המחשב מתוך המידע שנאסף ברקע.
    #>
    [CmdletBinding()]
    param()
    $info = $Sync.SysInfo
    if ($null -eq $info) { return }
    $UI.SysInfoPanel.Children.Clear()
    $grid = New-Object System.Windows.Controls.Primitives.UniformGrid
    $grid.Columns = 2
    $tiles = @(
        , @('IconMonitor', 'שם מחשב', $info.ComputerName, $true, '')
        , @('IconTag', 'דגם', $info.Model, $true, '')
        , @('IconTag', 'מספר סידורי', $info.Serial, $true, '')
        , @('IconGear', 'מערכת הפעלה', ('{0} · Build {1}' -f $info.OS, $info.Build), $false, '')
        , @('IconCpu', 'מעבד', $info.CPU, $true, '')
        , @('IconCpu', 'זיכרון', $info.RamGB, $true, '')
        , @('IconDrive', 'כונן מערכת', $info.DiskFree, $false, $(if ($info.DiskFreeGB -lt 10) { '#FBBF24' } else { '' }))
        , @('IconNetwork', 'רשת', $info.Domain, $false, '')
        , @('IconGlobe', 'אינטרנט', $(if ($info.Internet) { 'מחובר' } else { 'אין חיבור' }), $false, $(if ($info.Internet) { '#2DD4BF' } else { '#F87171' }))
        , @('IconBattery', 'חשמל', $info.Power, $false, $(if ($info.OnBattery) { '#FBBF24' } else { '#2DD4BF' }))
    )
    foreach ($t in $tiles) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = Get-QDBrush -Hex '#1B2029'
        $b.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $b.Padding = New-Object System.Windows.Thickness(12, 10, 12, 10)
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
        $sp = New-Object System.Windows.Controls.StackPanel
        $hdr = New-Object System.Windows.Controls.StackPanel
        $hdr.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        [void]$hdr.Children.Add((Get-QDIconPath -Name $t[0] -Size 13 -Color '#8A93A3'))
        $cap = Get-QDTextBlock -Text $t[1] -StyleKey 'Caption'
        $cap.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
        [void]$hdr.Children.Add($cap)
        [void]$sp.Children.Add($hdr)
        $val = Get-QDTextBlock -Text ([string]$t[2]) -Bold
        $val.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $val.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        if ($t[3]) { $val.FlowDirection = [System.Windows.FlowDirection]::LeftToRight; $val.TextAlignment = [System.Windows.TextAlignment]::Right }
        if ($t[4]) { $val.Foreground = Get-QDBrush -Hex $t[4] }
        if ([string]::IsNullOrWhiteSpace([string]$t[2])) { $val.Text = '—' }
        [void]$sp.Children.Add($val)
        $b.Child = $sp
        [void]$grid.Children.Add($b)
    }
    [void]$UI.SysInfoPanel.Children.Add($grid)
    $grid.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0 -To 1 -Milliseconds 250))
}

function Invoke-QDSysInfoRefresh {
    <#
    .SYNOPSIS
        אוסף מידע מערכת ומנהלי התקן מדפסות ברקע.
    #>
    [CmdletBinding()]
    param()
    if ($Sync.SysInfoState -eq 'running') { return }
    $Sync.SysInfoState = 'running'
    Invoke-QDWorker -Name 'sysinfo' -ScriptBlock {
        Set-StrictMode -Version Latest
        try {
            $Sync.SysInfo = Get-QDSystemInfo
            $Sync.PrinterDrivers = @(Get-QDPrinterDriverList)
        }
        catch { Write-QDLog -Message ('איסוף מידע מערכת: ' + $_.Exception.Message) -Level 'WARN' }
        $Sync.SysInfoState = 'ready'
        Send-QDPump -Force
    }
}

#endregion UI — system info

#region UI — background workers & pump

function Initialize-QDWorkerState {
    <#
    .SYNOPSIS
        מכין InitialSessionState עם כל פונקציות הכלי ומשתני המצב המשותפים עבור runspaces ברקע.
    #>
    [CmdletBinding()]
    param()
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { Write-Verbose 'ExecutionPolicy not settable' }
    foreach ($f in @(Get-ChildItem -Path 'Function:' | Where-Object { $_.Name -like '*-QD*' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f.Name, $f.Definition)))
    }
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('Sync', $Sync, 'QuickDeploy shared state')))
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('QD', $QD, 'QuickDeploy configuration')))
    $script:WorkerIss = $iss
    $script:Workers = New-Object System.Collections.ArrayList
}

function Invoke-QDWorker {
    <#
    .SYNOPSIS
        מריץ scriptblock ב-runspace ברקע (הממשק לעולם אינו קופא).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$ScriptBlock, [hashtable]$Parameters = @{})
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($script:WorkerIss)
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptBlock.ToString())
    foreach ($k in $Parameters.Keys) { [void]$ps.AddParameter($k, $Parameters[$k]) }
    $handle = $ps.BeginInvoke()
    [void]$script:Workers.Add(@{ Name = $Name; PS = $ps; Handle = $handle; Runspace = $rs })
}

function Complete-QDWorker {
    <#
    .SYNOPSIS
        משחרר runspaces שסיימו ורושם שגיאות שלהם ליומן.
    #>
    [CmdletBinding()]
    param()
    foreach ($w in @($script:Workers)) {
        if (-not $w.Handle.IsCompleted) { continue }
        try { [void]$w.PS.EndInvoke($w.Handle) }
        catch { Write-QDLog -Message ('תהליך רקע {0}: {1}' -f $w.Name, $_.Exception.Message) -Level 'ERROR' }
        foreach ($er in @($w.PS.Streams.Error | Select-Object -First 3)) { Write-QDLog -Message ('[{0}] {1}' -f $w.Name, $er.ToString()) -Level 'WARN' }
        $w.PS.Dispose()
        $w.Runspace.Dispose()
        $script:Workers.Remove($w)
    }
}

function Sync-QDLogView {
    <#
    .SYNOPSIS
        מעביר שורות יומן חדשות מהתור לחלונית היומן החי.
    #>
    [CmdletBinding()]
    param()
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($Sync.LogQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -eq 0) { return }
    $UI.TxtLog.AppendText($sb.ToString())
    if ($UI.TxtLog.Text.Length -gt 300000) { $UI.TxtLog.Text = $UI.TxtLog.Text.Substring($UI.TxtLog.Text.Length - 150000) }
    $UI.TxtLog.ScrollToEnd()
}

function Invoke-QDUiPump {
    <#
    .SYNOPSIS
        רענון ממשק מרוכז — נקרא מתהליכוני הרקע דרך Dispatcher.Invoke ומטיימר גיבוי.
    #>
    [CmdletBinding()]
    param()
    if ($script:PumpBusy) { return }
    $script:PumpBusy = $true
    try {
        Sync-QDLogView
        if ($null -ne $Sync.Steps -and ($Sync.Running -or $Sync.Done)) { Sync-QDRunView }
        if ($Sync.CatalogVersion -ne $script:CatalogRendered) {
            $script:CatalogRendered = $Sync.CatalogVersion
            Sync-QDAppCardState
        }
        if ($Sync.SysInfoState -eq 'ready') {
            $Sync.SysInfoState = 'shown'
            Show-QDSysInfo
            Sync-QDDriverCombo
        }
        Complete-QDWorker
        if ($Sync.Done -and -not $script:RunFinalized) {
            $script:RunFinalized = $true
            Complete-QDRunUi
        }
        if ($Sync.SearchState -eq 'done') {
            $Sync.SearchState = 'idle'
            Show-QDSearchResult
        }
    }
    catch {
        Write-Verbose ('Pump: ' + $_.Exception.Message)
    }
    finally {
        $script:PumpBusy = $false
    }
}

#endregion UI — background workers & pump

#region UI — run page

function Build-QDStepRowList {
    <#
    .SYNOPSIS
        בונה את שורות השלבים בעמוד ההרצה.
    #>
    [CmdletBinding()]
    param()
    $UI.StepsPanel.Children.Clear()
    $script:StepRows = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($def in $QD.StepDefinitions) {
        $i++
        $root = New-Object System.Windows.Controls.Border
        $root.Background = Get-QDBrush -Hex '#1B2029'
        $root.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $root.Padding = New-Object System.Windows.Thickness(12, 10, 12, 10)
        $root.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $g = Get-QDGrid -Columns @('Auto', '*', 'Auto', 'Auto')
        $iconHost = New-Object System.Windows.Controls.Border
        $iconHost.Width = 36; $iconHost.Height = 36
        $iconHost.CornerRadius = New-Object System.Windows.CornerRadius(18)
        $iconHost.Background = Get-QDBrush -Hex '#232935'
        $icon = Get-QDIconPath -Name $def.Icon -Size 16 -Color '#8A93A3'
        $iconHost.Child = $icon
        Add-QDGridChild -Grid $g -Element $iconHost -Column 0
        $textStack = New-Object System.Windows.Controls.StackPanel
        $textStack.Margin = New-Object System.Windows.Thickness(12, 0, 8, 0)
        $textStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$textStack.Children.Add((Get-QDTextBlock -Text ('{0}. {1}' -f $i, $def.Title) -Bold))
        $detail = Get-QDTextBlock -Text '' -StyleKey 'Caption'
        $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $detail.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        [void]$textStack.Children.Add($detail)
        Add-QDGridChild -Grid $g -Element $textStack -Column 1
        $dur = Get-QDTextBlock -Text '' -StyleKey 'Caption'
        $dur.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        Add-QDGridChild -Grid $g -Element $dur -Column 2
        $pill = New-Object System.Windows.Controls.Border
        $pill.CornerRadius = New-Object System.Windows.CornerRadius(999)
        $pill.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
        $pill.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $pillBrush = New-Object System.Windows.Media.SolidColorBrush((Get-QDColor -Hex '#268A93A3'))
        $pill.Background = $pillBrush
        $pillText = Get-QDTextBlock -Text $QD.StatusText['Pending'] -FontSize 12 -Bold -Color '#8A93A3'
        $pill.Child = $pillText
        Add-QDGridChild -Grid $g -Element $pill -Column 3
        $root.Child = $g
        [void]$UI.StepsPanel.Children.Add($root)
        [void]$script:StepRows.Add(@{ Root = $root; IconHost = $iconHost; Icon = $icon; IconName = $def.Icon; Detail = $detail; Duration = $dur; PillBrush = $pillBrush; PillText = $pillText; Rendered = 'Pending' })
    }
}

function Show-QDStepStatus {
    <#
    .SYNOPSIS
        מעדכן שורת שלב לסטטוס חדש עם אנימציית צבע והבהוב.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Row, [Parameter(Mandatory)][string]$Status)
    $hex = $QD.StatusColor[$Status]
    $color = Get-QDColor -Hex $hex
    $tint = [System.Windows.Media.Color]::FromArgb(0x26, $color.R, $color.G, $color.B)
    $ca = New-Object System.Windows.Media.Animation.ColorAnimation
    $ca.To = $tint
    $ca.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(280))
    $Row.PillBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
    $Row.PillText.Text = $QD.StatusText[$Status]
    $Row.PillText.Foreground = New-Object System.Windows.Media.SolidColorBrush($color)
    $Row.IconHost.Background = New-Object System.Windows.Media.SolidColorBrush($tint)
    $iconName = switch ($Status) { 'Success' { 'IconCheck' } 'Failed' { 'IconX' } 'Partial' { 'IconAlert' } 'Warning' { 'IconAlert' } default { $Row.IconName } }
    $Row.Icon.Data = Get-QDResource -Key $iconName
    $Row.Icon.SetValue([System.Windows.Documents.TextElement]::ForegroundProperty, (New-Object System.Windows.Media.SolidColorBrush($color)))
    if ($Status -eq 'Running') {
        $pulse = Get-QDDoubleAnimation -From 1 -To 0.3 -Milliseconds 650
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $Row.Icon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
        $Row.Root.Background = Get-QDBrush -Hex '#1F2530'
    }
    else {
        $Row.Icon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $Row.Icon.Opacity = 1
        $Row.Root.Background = Get-QDBrush -Hex '#1B2029'
    }
    $Row.Root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0.5 -To 1 -Milliseconds 320))
    $Row.Rendered = $Status
}

function Show-QDRing {
    <#
    .SYNOPSIS
        מצייר את טבעת ההתקדמות (Path + ArcSegment) לפי אחוז.
    #>
    [CmdletBinding()]
    param([double]$Percent)
    $pct = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $UI.RingText.Text = ('{0}%' -f [int][math]::Round($pct))
    if ($pct -le 0.05) { $UI.RingArc.Data = $null; return }
    if ($pct -ge 99.95) {
        $UI.RingArc.Data = New-Object System.Windows.Media.EllipseGeometry((New-Object System.Windows.Point(64, 64)), 54, 54)
        return
    }
    $angle = $pct / 100.0 * 2 * [math]::PI
    $x = 64 + 54 * [math]::Sin($angle)
    $y = 64 - 54 * [math]::Cos($angle)
    $large = if ($pct -gt 50) { 1 } else { 0 }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $data = [string]::Format($inv, 'M 64,10 A 54,54 0 {0} 1 {1:0.###},{2:0.###}', $large, $x, $y)
    $UI.RingArc.Data = [System.Windows.Media.Geometry]::Parse($data)
}

function Step-QDRingAnimation {
    <#
    .SYNOPSIS
        מקדם את אנימציית הטבעת לעבר היעד (טיימר ~30fps).
    #>
    [CmdletBinding()]
    param()
    $diff = $script:RingTarget - $script:RingCurrent
    if ([math]::Abs($diff) -lt 0.1) {
        $script:RingCurrent = $script:RingTarget
        Show-QDRing -Percent $script:RingCurrent
        $script:RingTimer.Stop()
        return
    }
    $step = $diff * 0.16
    if ([math]::Abs($step) -lt 0.15) { $step = [math]::Sign($diff) * 0.15 }
    $script:RingCurrent += $step
    Show-QDRing -Percent $script:RingCurrent
}

function Sync-QDRunView {
    <#
    .SYNOPSIS
        מסנכרן את עמוד ההרצה עם מצב הצינור (טבעת, שלבים, פעילות).
    #>
    [CmdletBinding()]
    param()
    $target = [double]$Sync.Progress
    if ($target -ne $script:RingTarget) {
        $script:RingTarget = $target
        if (-not $script:RingTimer.IsEnabled) { $script:RingTimer.Start() }
    }
    $UI.TxtRunActivity.Text = [string]$Sync.Activity
    $steps = $Sync.Steps
    for ($i = 0; $i -lt [math]::Min($steps.Count, $script:StepRows.Count); $i++) {
        $st = $steps[$i]
        $row = $script:StepRows[$i]
        if ($row.Rendered -ne $st.Status) { Show-QDStepStatus -Row $row -Status $st.Status }
        $row.Duration.Text = [string]$st.Duration
        $items = @($st.Items)
        if ($items.Count -gt 0) {
            $failed = @($items | Where-Object { $_.Status -eq 'Failed' }).Count
            $last = $items[$items.Count - 1]
            $txt = if ($st.Status -eq 'Running') { [string]$last.Name } else { '{0} פעולות' -f $items.Count }
            if ($failed -gt 0) { $txt += (' · {0} נכשלו' -f $failed) }
            $row.Detail.Text = $txt
        }
    }
}

function Add-QDSummaryChip {
    <#
    .SYNOPSIS
        מוסיף "צ'יפ" סיכום לעמוד ההרצה.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Icon, [Parameter(Mandatory)][string]$Text, [string]$Color = '#F2F4F7')
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Object System.Windows.CornerRadius(999)
    $b.Background = Get-QDBrush -Hex '#1B2029'
    $b.BorderBrush = Get-QDBrush -Hex '#2A303C'
    $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.Padding = New-Object System.Windows.Thickness(12, 6, 14, 6)
    $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    [void]$sp.Children.Add((Get-QDIconPath -Name $Icon -Size 14 -Color '#F5A524'))
    $t = Get-QDTextBlock -Text $Text -Color $Color
    $t.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    [void]$sp.Children.Add($t)
    $b.Child = $sp
    [void]$UI.SummaryPanel.Children.Add($b)
}

function Build-QDRunSummary {
    <#
    .SYNOPSIS
        בונה את סיכום הבחירות בעמוד ההרצה.
    #>
    [CmdletBinding()]
    param()
    $p = Read-QDProfileFromUi
    $UI.SummaryPanel.Children.Clear()
    $apps = @($p.apps).Count + @($p.customApps).Count
    Add-QDSummaryChip -Icon 'IconProfile' -Text ('פרופיל: ' + $p.name)
    Add-QDSummaryChip -Icon 'IconPackage' -Text ("$apps תוכנות להתקנה")
    Add-QDSummaryChip -Icon 'IconBroom' -Text ("$(@($p.debloat.packages).Count) אפליקציות להסרה")
    $sysOn = @($p.system.Keys | Where-Object { $p.system[$_] -is [bool] -and $p.system[$_] }).Count
    Add-QDSummaryChip -Icon 'IconGear' -Text ("$sysOn הגדרות מערכת · חשמל: " + $(if ($p.system.powerPlan -eq 'high') { 'ביצועים גבוהים' } else { 'מאוזן' }))
    $cn = $UI.TxtComputerName.Text.Trim()
    if ($cn -and $cn -ne $env:COMPUTERNAME) { Add-QDSummaryChip -Icon 'IconTag' -Text ('שם מחשב חדש: ' + $cn) -Color '#F5A524' }
    else { Add-QDSummaryChip -Icon 'IconTag' -Text 'שם המחשב ללא שינוי' }
    switch ($p.network.joinType) {
        'domain' { Add-QDSummaryChip -Icon 'IconNetwork' -Text ('דומיין: ' + $p.network.domain) -Color '#F5A524' }
        'workgroup' { Add-QDSummaryChip -Icon 'IconNetwork' -Text ('קבוצת עבודה: ' + $p.network.workgroup) }
    }
    if (@($p.network.drives).Count) { Add-QDSummaryChip -Icon 'IconDrive' -Text ("$(@($p.network.drives).Count) כוננים ממופים") }
    if (@($p.network.wifi).Count) { Add-QDSummaryChip -Icon 'IconWifi' -Text ("$(@($p.network.wifi).Count) רשתות Wi-Fi") }
    if (@($p.network.printers).Count) { Add-QDSummaryChip -Icon 'IconPrinter' -Text ("$(@($p.network.printers).Count) מדפסות") }
    if ($UI.ChkSimulate.IsChecked) { Add-QDSummaryChip -Icon 'IconInfo' -Text 'מצב סימולציה — ללא שינויים' -Color '#F5A524' }
}

function Test-QDRunConfig {
    <#
    .SYNOPSIS
        מאמת את הקלט לפני הרצה ומחזיר רשימת שגיאות בעברית.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileData, [AllowEmptyString()][string]$NewComputerName = '')
    $errors = New-Object System.Collections.Generic.List[string]
    $cnErr = Test-QDComputerName -Name $NewComputerName
    if ($cnErr) { $errors.Add('שם מחשב: ' + $cnErr) }
    $n = $ProfileData.network
    if ($n.joinType -eq 'workgroup') {
        if ([string]::IsNullOrWhiteSpace($n.workgroup)) { $errors.Add('לא הוזן שם קבוצת עבודה') }
        elseif ($n.workgroup.Length -gt 15 -or $n.workgroup -match '["/\\\[\]:|<>+=;,?*]') { $errors.Add('שם קבוצת העבודה אינו תקין') }
    }
    if ($n.joinType -eq 'domain') {
        if ($n.domain -notmatch '^[A-Za-z0-9][A-Za-z0-9\.-]*\.[A-Za-z0-9\.-]+$' -and $n.domain -notmatch '^[A-Za-z0-9-]{1,15}$') { $errors.Add('שם הדומיין אינו תקין') }
    }
    $letters = @()
    foreach ($dr in @($n.drives)) {
        if ($letters -contains $dr.letter) { $errors.Add("אות הכונן $($dr.letter): מופיעה יותר מפעם אחת") }
        $letters += $dr.letter
        if (-not (Test-QDUncPath -Path $dr.path)) { $errors.Add("כונן $($dr.letter): — נתיב UNC לא תקין (\\server\share)") }
    }
    foreach ($w in @($n.wifi)) { if ([string]::IsNullOrWhiteSpace($w.ssid)) { $errors.Add('רשת Wi-Fi ללא SSID') } }
    foreach ($pr in @($n.printers)) {
        if ($pr.type -eq 'ip') {
            if ([string]::IsNullOrWhiteSpace($pr.name)) { $errors.Add('מדפסת IP ללא שם') }
            if (-not (Test-QDIPv4 -Address $pr.ip)) { $errors.Add("מדפסת '$($pr.name)': כתובת IP לא תקינה") }
        }
        elseif (-not (Test-QDUncPath -Path $pr.path)) { $errors.Add("מדפסת משותפת: נתיב לא תקין '$($pr.path)'") }
    }
    return $errors.ToArray()
}

function Request-QDRunInput {
    <#
    .SYNOPSIS
        אוסף לפני תחילת ההרצה את כל מה שדורש משתמש (פרטי דומיין, סיסמאות, אזהרת סוללה),
        כך שההרצה עצמה אינה דורשת התערבות. מחזיר $null אם המשתמש ביטל.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileData, [bool]$SimulateRun = $false)
    $secrets = @{ Wifi = @{} }
    $pwr = Get-QDPowerSource
    if ($pwr.OnBattery) {
        $res = Show-QDDialog -Title 'המחשב פועל על סוללה' -Message ("רמת הסוללה: $($pwr.Charge)%. התקנות ועדכונים עלולים להימשך זמן רב — מומלץ מאוד לחבר מטען לפני ההרצה.") -Kind 'warning' -Buttons @('המשך בכל זאת', 'ביטול')
        if ($res.Button -ne 0) { return $null }
    }
    if ($SimulateRun) {
        Write-QDLog -Message 'מצב סימולציה — פרטי הזדהות וסיסמאות לא נאספים' -Level 'SIM'
        return $secrets
    }
    $n = $ProfileData.network
    if ($n.joinType -eq 'domain') {
        $cred = $null
        while ($true) {
            $res = Show-QDDialog -Title ('הצטרפות לדומיין ' + $n.domain) -Message 'משתמש עם הרשאה לצרף מחשבים לדומיין. הפרטים משמשים להצטרפות בלבד ולא יישמרו.' -Kind 'question' -Buttons @('אישור', 'דלג') -Fields @(
                @{ Key = 'user'; Label = 'שם משתמש (DOMAIN\user או user@domain)'; Type = 'text'; Ltr = $true }
                @{ Key = 'pw'; Label = 'סיסמה'; Type = 'password' }
            )
            if ($res.Button -ne 0) { break }
            $du = ([string]$res.Values['user']).Trim()
            if (-not $du -or $res.Values['pw'].Length -eq 0) { Show-QDToast -Message 'יש להזין שם משתמש וסיסמה' -Kind 'error'; continue }
            if ($du -notmatch '[\\@]') { $du = $n.domain + '\' + $du }
            $cred = New-Object System.Management.Automation.PSCredential($du, $res.Values['pw'])
            break
        }
        if ($null -eq $cred) {
            $res = Show-QDDialog -Title 'לא הוזנו פרטי הזדהות' -Message 'להמשיך בהרצה בלי הצטרפות לדומיין?' -Kind 'warning' -Buttons @('המשך בלי דומיין', 'ביטול')
            if ($res.Button -ne 0) { return $null }
        }
        else { $secrets['DomainCredential'] = $cred }
    }
    if ($ProfileData.system.createLocalAdmin) {
        while ($true) {
            $res = Show-QDDialog -Title 'משתמש מנהל מקומי' -Message 'הפרטים משמשים ליצירת המשתמש בלבד ולא יישמרו.' -Kind 'question' -Buttons @('אישור', 'דלג') -Fields @(
                @{ Key = 'user'; Label = 'שם משתמש'; Type = 'text'; Ltr = $true }
                @{ Key = 'p1'; Label = 'סיסמה'; Type = 'password' }
                @{ Key = 'p2'; Label = 'אימות סיסמה'; Type = 'password' }
            )
            if ($res.Button -ne 0) { break }
            $u = ([string]$res.Values['user']).Trim()
            $a = ConvertFrom-QDSecureString -Secure $res.Values['p1']
            $b = ConvertFrom-QDSecureString -Secure $res.Values['p2']
            $ok = $true
            if ($u -notmatch '^[A-Za-z0-9._-]{1,20}$') { Show-QDToast -Message 'שם משתמש לא תקין (אנגלית, ספרות, . _ - עד 20 תווים)' -Kind 'error'; $ok = $false }
            elseif ($a.Length -lt 8) { Show-QDToast -Message 'הסיסמה חייבת להכיל לפחות 8 תווים' -Kind 'error'; $ok = $false }
            elseif ($a -cne $b) { Show-QDToast -Message 'הסיסמאות אינן תואמות' -Kind 'error'; $ok = $false }
            $a = $null; $b = $null
            if ($ok) { $secrets['LocalAdmin'] = @{ Name = $u; Secret = $res.Values['p1'] }; break }
        }
    }
    foreach ($w in @($ProfileData.network.wifi)) {
        while ($true) {
            $res = Show-QDDialog -Title ('סיסמת Wi-Fi: ' + $w.ssid) -Message ('אבטחה: {0}. הסיסמה לא תישמר.' -f $w.security) -Kind 'question' -Buttons @('אישור', 'דלג') -Fields @(@{ Key = 'k'; Label = 'סיסמה'; Type = 'password' })
            if ($res.Button -ne 0) { break }
            $len = $res.Values['k'].Length
            if ($len -lt 8 -or $len -gt 63) { Show-QDToast -Message 'סיסמת Wi-Fi חייבת להכיל 8–63 תווים' -Kind 'error'; continue }
            $secrets['Wifi'][$w.ssid] = $res.Values['k']
            break
        }
    }
    return $secrets
}

function Invoke-QDRunStart {
    <#
    .SYNOPSIS
        מאמת, אוסף קלט מקדים ומפעיל את צינור ההקמה ב-runspace ברקע.
    #>
    [CmdletBinding()]
    param()
    if ($Sync.Running) { return }
    $p = Read-QDProfileFromUi
    $cn = $UI.TxtComputerName.Text.Trim()
    $errors = @(Test-QDRunConfig -ProfileData $p -NewComputerName $cn)
    if ($errors.Count -gt 0) {
        [void](Show-QDDialog -Title 'יש לתקן לפני ההרצה' -Message ('• ' + ($errors -join "`n• ")) -Kind 'error')
        return
    }
    $simulateRun = [bool]$UI.ChkSimulate.IsChecked
    if (-not $simulateRun) {
        $confirm = Show-QDDialog -Title 'להתחיל בהקמה?' -Message 'ההרצה תבצע שינויים אמיתיים במחשב (הסרת אפליקציות, התקנות, הגדרות). מומלץ לסגור תוכנות פתוחות.' -Kind 'warning' -Buttons @('הרץ', 'ביטול')
        if ($confirm.Button -ne 0) { return }
    }
    $secrets = Request-QDRunInput -ProfileData $p -SimulateRun $simulateRun
    if ($null -eq $secrets) { Show-QDToast -Message 'ההרצה בוטלה' -Kind 'info'; return }

    $config = $p
    $config['computerName'] = $cn
    $Sync.Simulate = $simulateRun
    $Sync.Secrets = $secrets
    $Sync.Steps = $null
    $Sync.Done = $false
    $Sync.Cancel = $false
    $Sync.Progress = 0
    $script:RunFinalized = $false
    $script:RingTarget = 0.0
    $script:RingCurrent = 0.0
    Show-QDRing -Percent 0
    $UI.RingArc.Stroke = Get-QDResource -Key 'AccentBrush'
    $UI.RingSub.Text = 'מתבצע'
    Build-QDStepRowList
    try {
        $null = Start-Transcript -Path $QD.TranscriptPath -Append -ErrorAction Stop
        $script:TranscriptOn = $true
    }
    catch { $script:TranscriptOn = $false }

    $UI.BtnRun.Visibility = [System.Windows.Visibility]::Collapsed
    $UI.BtnCancel.Visibility = [System.Windows.Visibility]::Visible
    $UI.BtnCancel.IsEnabled = $true
    $UI.BtnOpenReport.Visibility = [System.Windows.Visibility]::Collapsed
    $UI.BtnReboot.Visibility = [System.Windows.Visibility]::Collapsed
    $UI.RebootBanner.Visibility = [System.Windows.Visibility]::Collapsed
    $UI.ChkSimulate.IsEnabled = $false
    $UI.TxtRunStatus.Text = if ($simulateRun) { 'סימולציה פועלת — לא מתבצעים שינויים.' } else { 'ההקמה פועלת. ניתן לעקוב אחרי היומן החי.' }
    $Sync.Running = $true
    Invoke-QDWorker -Name 'pipeline' -Parameters @{ Config = $config } -ScriptBlock {
        param($Config)
        Set-StrictMode -Version Latest
        Invoke-QDPipeline -Config $Config
    }
}

function Invoke-QDRunCancel {
    <#
    .SYNOPSIS
        מבקש ביטול — ייכנס לתוקף בין פעולות (לעולם לא באמצע התקנה).
    #>
    [CmdletBinding()]
    param()
    if (-not $Sync.Running) { return }
    $res = Show-QDDialog -Title 'לבטל את ההרצה?' -Message 'הפעולה הנוכחית תסתיים (התקנה לא תיקטע באמצע), ושאר השלבים יסומנו כ"בוטל". דוח יופק בכל מקרה.' -Kind 'warning' -Buttons @('בטל הרצה', 'המשך')
    if ($res.Button -ne 0) { return }
    $Sync.Cancel = $true
    $UI.BtnCancel.IsEnabled = $false
    $UI.TxtRunStatus.Text = 'מבטל לאחר הפעולה הנוכחית…'
    Write-QDLog -Message 'המשתמש ביקש ביטול' -Level 'WARN'
}

function Complete-QDRunUi {
    <#
    .SYNOPSIS
        מעדכן את הממשק בסיום ההרצה: טבעת, כפתורי דוח/הפעלה מחדש, הודעת הפעלה מחדש.
    #>
    [CmdletBinding()]
    param()
    if ($script:TranscriptOn) {
        try { $null = Stop-Transcript } catch { Write-Verbose 'transcript' }
        $script:TranscriptOn = $false
    }
    Sync-QDLogView
    $UI.BtnCancel.Visibility = [System.Windows.Visibility]::Collapsed
    $UI.BtnRun.Visibility = [System.Windows.Visibility]::Visible
    $UI.ChkSimulate.IsEnabled = $true
    if ($Sync.ReportPath) { $UI.BtnOpenReport.Visibility = [System.Windows.Visibility]::Visible }
    if (-not $script:NoRebootMode) {
        $UI.BtnReboot.Visibility = [System.Windows.Visibility]::Visible
        $UI.BtnReboot.Style = if ($Sync.RebootRequired) { Get-QDResource -Key 'PrimaryButton' } else { $null }
    }
    if ($Sync.RebootRequired) {
        $UI.TxtRebootReason.Text = 'נדרשת הפעלה מחדש: ' + ((@($Sync.RebootReasons) | Select-Object -First 4) -join ' · ')
        $UI.RebootBanner.Visibility = [System.Windows.Visibility]::Visible
    }
    $all = @($Sync.Steps | ForEach-Object { @($_.Items) })
    $failed = @($all | Where-Object { $_.Status -eq 'Failed' }).Count
    $okCount = @($all | Where-Object { $_.Status -in @('Success', 'AlreadyDone', 'Simulated') }).Count
    $color = if ($Sync.Cancel) { '#8A93A3' } elseif ($Sync.ExitCode -eq 0) { '#2DD4BF' } elseif ($Sync.ExitCode -eq 1) { '#FBBF24' } else { '#F87171' }
    $UI.RingArc.Stroke = Get-QDBrush -Hex $color
    $UI.RingSub.Text = if ($Sync.Cancel) { 'בוטל' } elseif ($Sync.ExitCode -eq 0) { 'הושלם' } else { 'הושלם חלקית' }
    $UI.TxtRunStatus.Text = ('{0} פעולות הצליחו, {1} נכשלו. יומן: {2}' -f $okCount, $failed, $QD.LogPath)
    $kind = if ($Sync.ExitCode -eq 0 -and -not $Sync.Cancel) { 'success' } elseif ($Sync.Cancel) { 'info' } else { 'warning' }
    Show-QDToast -Message ([string]$Sync.Activity) -Kind $kind
    $UI.BtnRun.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Get-QDDoubleAnimation -From 0 -To 1 -Milliseconds 300))
}

function Invoke-QDRebootPrompt {
    <#
    .SYNOPSIS
        חלון ספירה לאחור של 60 שניות להפעלה מחדש (ניתן לביטול).
    #>
    [CmdletBinding()]
    param()
    $res = Show-QDDialog -Title 'הפעלה מחדש' -Message 'המחשב יופעל מחדש בסיום הספירה. שמור עבודה פתוחה.' -Kind 'warning' -Buttons @('הפעל מחדש עכשיו', 'ביטול') -CountdownSeconds 60
    if ($res.Button -ne 0) { Show-QDToast -Message 'ההפעלה מחדש בוטלה' -Kind 'info'; return }
    if ($Sync.Simulate) {
        Write-QDLog -Message '[SIM] would Restart-Computer -Force' -Level 'SIM'
        Show-QDToast -Message 'מצב סימולציה — המחשב לא הופעל מחדש' -Kind 'info'
        return
    }
    Write-QDLog -Message 'מפעיל מחדש את המחשב' -Level 'WARN'
    Restart-Computer -Force
}

#endregion UI — run page

#region UI — wiring & main window

function Register-QDUiEvent {
    <#
    .SYNOPSIS
        מחבר את כל אירועי הממשק לפונקציות.
    #>
    [CmdletBinding()]
    param()
    $win = $script:MainWindow
    $UI.BtnMin.Add_Click({ $script:MainWindow.WindowState = [System.Windows.WindowState]::Minimized })
    $UI.BtnMax.Add_Click({
            $script:MainWindow.WindowState = if ($script:MainWindow.WindowState -eq [System.Windows.WindowState]::Maximized) { [System.Windows.WindowState]::Normal } else { [System.Windows.WindowState]::Maximized }
        })
    $UI.BtnClose.Add_Click({ $script:MainWindow.Close() })
    $win.Add_StateChanged({
            $max = $script:MainWindow.WindowState -eq [System.Windows.WindowState]::Maximized
            $UI.RootBorder.Margin = if ($max) { New-Object System.Windows.Thickness(7) } else { New-Object System.Windows.Thickness(0) }
            $UI.IconMaxPath.Data = Get-QDResource -Key $(if ($max) { 'IconRestore' } else { 'IconMaximize' })
        })
    $win.Add_Closing({
            if ($Sync.Running) {
                $_.Cancel = $true
                [void](Show-QDDialog -Title 'ההרצה עדיין פועלת' -Message 'לא ניתן לסגור את הכלי בזמן הרצה. בטל תחילה והמתן לסיום הפעולה הנוכחית.' -Kind 'warning')
            }
        })
    $win.Dispatcher.Add_UnhandledException({
            $_.Handled = $true
            Write-QDLog -Message ('חריגה בממשק: ' + $_.Exception.Message) -Level 'ERROR'
            Show-QDToast -Message ('שגיאה: ' + $_.Exception.Message) -Kind 'error'
        })

    foreach ($nav in @('NavProfile', 'NavApps', 'NavCleanup', 'NavSystem', 'NavNetwork', 'NavRun')) {
        $UI[$nav].Add_Checked({ $page = [string]$this.Tag; Invoke-QDSafe { Show-QDPage -Name $page } })
    }

    $UI.CmbProfile.Add_SelectionChanged({ Invoke-QDSafe { Invoke-QDProfileSwitch } })
    $UI.BtnSaveProfile.Add_Click({ Invoke-QDSafe { [void](Save-QDCurrentProfile) } })
    $UI.BtnDuplicateProfile.Add_Click({ Invoke-QDSafe { Copy-QDCurrentProfile } })
    $UI.BtnDeleteProfile.Add_Click({ Invoke-QDSafe { Invoke-QDProfileDelete } })
    $UI.BtnImportProfile.Add_Click({ Invoke-QDSafe { Import-QDProfileDialog } })
    $UI.BtnExportProfile.Add_Click({ Invoke-QDSafe { Export-QDProfileDialog } })
    $UI.BtnOpenProfilesFolder.Add_Click({ Invoke-QDSafe { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $QD.ProfilesDir) } })
    $UI.BtnRefreshInfo.Add_Click({ Invoke-QDSafe { Invoke-QDSysInfoRefresh } })

    $UI.TxtAppSearch.Add_TextChanged({ Invoke-QDSafe { Sync-QDAppFilter } })
    $UI.BtnAppsNone.Add_Click({ Invoke-QDSafe { foreach ($e in $script:AppCards.Values) { $e.Toggle.IsChecked = $false } } })
    $UI.BtnWingetSearch.Add_Click({ Invoke-QDSafe { Invoke-QDWingetSearch } })
    $UI.TxtWingetQuery.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Enter) { Invoke-QDSafe { Invoke-QDWingetSearch } } })

    $UI.BtnDebloatAll.Add_Click({ Invoke-QDSafe { foreach ($c in $script:DebloatToggles.Values) { $c.IsChecked = $true } } })
    $UI.BtnDebloatNone.Add_Click({ Invoke-QDSafe { foreach ($c in $script:DebloatToggles.Values) { $c.IsChecked = $false } } })

    $UI.TxtComputerName.Add_TextChanged({
            $err = Test-QDComputerName -Name $UI.TxtComputerName.Text.Trim()
            if ($err) { $UI.TxtComputerNameHint.Text = $err; $UI.TxtComputerNameHint.Foreground = Get-QDBrush -Hex '#F87171' }
            else { $UI.TxtComputerNameHint.Text = 'עד 15 תווים: אותיות באנגלית, ספרות ומקף. השאר ריק כדי לא לשנות.'; $UI.TxtComputerNameHint.Foreground = Get-QDResource -Key 'TextSecondaryBrush' }
        })
    foreach ($rb in @('RbJoinNone', 'RbJoinWorkgroup', 'RbJoinDomain')) { $UI[$rb].Add_Checked({ Sync-QDJoinPanel }) }
    $UI.BtnAddDrive.Add_Click({ Invoke-QDSafe { Add-QDDriveRow } })
    $UI.BtnAddWifi.Add_Click({ Invoke-QDSafe { Add-QDWifiRow } })
    $UI.BtnAddPrinterIp.Add_Click({ Invoke-QDSafe { Add-QDPrinterRow -Type 'ip' } })
    $UI.BtnAddPrinterUnc.Add_Click({ Invoke-QDSafe { Add-QDPrinterRow -Type 'unc' } })

    $UI.ChkSimulate.Add_Checked({ $UI.SimBadge.Visibility = [System.Windows.Visibility]::Visible; Invoke-QDSafe { Build-QDRunSummary } })
    $UI.ChkSimulate.Add_Unchecked({ $UI.SimBadge.Visibility = [System.Windows.Visibility]::Collapsed; Invoke-QDSafe { Build-QDRunSummary } })
    $UI.BtnRun.Add_Click({ Invoke-QDSafe { Invoke-QDRunStart } })
    $UI.BtnCancel.Add_Click({ Invoke-QDSafe { Invoke-QDRunCancel } })
    $UI.BtnOpenReport.Add_Click({ Invoke-QDSafe { if ($Sync.ReportPath -and (Test-Path -LiteralPath $Sync.ReportPath)) { Invoke-Item -LiteralPath $Sync.ReportPath } } })
    $UI.BtnReboot.Add_Click({ Invoke-QDSafe { Invoke-QDRebootPrompt } })
    $UI.BtnOpenLogs.Add_Click({ Invoke-QDSafe { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $QD.LogsDir) } })
}

function Invoke-QDGuiMode {
    <#
    .SYNOPSIS
        מצב גרפי: בונה את החלון, טוען פרופיל, מפעיל בדיקות רקע ומציג.
    #>
    [CmdletBinding()]
    param([string]$InitialProfile = '', [string]$InitialComputerName = '', [bool]$StartSimulate = $false, [bool]$DisableReboot = $false)
    Hide-QDConsole
    Initialize-QDWpf
    $loaded = Import-QDXaml -Xaml $script:MainXaml
    $script:MainWindow = $loaded.Root
    $script:UI = $loaded.Names
    foreach ($k in $loaded.Names.Keys) { Set-Variable -Name $k -Value $loaded.Names[$k] -Scope Script }

    $script:PageNames = @('PageProfile', 'PageApps', 'PageCleanup', 'PageSystem', 'PageNetwork', 'PageRun')
    $script:DriveRows = New-Object System.Collections.ArrayList
    $script:WifiRows = New-Object System.Collections.ArrayList
    $script:PrinterRows = New-Object System.Collections.ArrayList
    $script:DriverNames = @('Microsoft IPP Class Driver', 'Microsoft PS Class Driver')
    $script:Loading = $false
    $script:SavedSnapshot = $null
    $script:SuppressProfileChange = $false
    $script:CurrentProfileIndex = -1
    $script:CurrentProfilePath = ''
    $script:CurrentProfileName = ''
    $script:CatalogRendered = -1
    $script:PumpBusy = $false
    $script:RunFinalized = $true
    $script:TranscriptOn = $false
    $script:RingTarget = 0.0
    $script:RingCurrent = 0.0
    $script:NoRebootMode = $DisableReboot

    $Sync.Dispatcher = $script:MainWindow.Dispatcher
    $Sync.Pump = [System.Action] { Invoke-QDUiPump }
    Initialize-QDWorkerState

    Build-QDAppCatalogUi
    Build-QDDebloatUi
    Build-QDStepRowList
    Show-QDRing -Percent 0
    $UI.TxtNavVersion.Text = 'גרסה ' + $QD.Version
    $isWin11 = [Environment]::OSVersion.Version.Build -ge 22000
    if (-not $isWin11) { $UI.PanelWin11.Visibility = [System.Windows.Visibility]::Collapsed }
    $UI.TxtComputerName.Tag = $env:COMPUTERNAME
    if ($InitialComputerName) { $UI.TxtComputerName.Text = $InitialComputerName }
    $UI.ChkSimulate.IsChecked = $StartSimulate
    if ($StartSimulate) { $UI.SimBadge.Visibility = [System.Windows.Visibility]::Visible }
    Register-QDUiEvent

    # Timers: pump fallback, dirty indicator, ring animation
    $script:PumpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PumpTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:PumpTimer.Add_Tick({ Invoke-QDUiPump })
    $script:DirtyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DirtyTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:DirtyTimer.Add_Tick({ try { Sync-QDDirtyIndicator } catch { Write-Verbose 'dirty check' } })
    $script:RingTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RingTimer.Interval = [TimeSpan]::FromMilliseconds(33)
    $script:RingTimer.Add_Tick({ Step-QDRingAnimation })

    # Initial profile
    $profileError = ''
    $entry = $null
    if ($InitialProfile) {
        $entry = Find-QDProfile -Name $InitialProfile
        if ($null -eq $entry) { $profileError = "הפרופיל '$InitialProfile' לא נמצא" }
    }
    if ($null -eq $entry) { $entry = Find-QDProfile -Name 'משרד' }
    if ($null -eq $entry) { $entry = @(Get-QDProfileList) | Select-Object -First 1 }
    if ($null -ne $entry) {
        Sync-QDProfileCombo -SelectPath $entry.Path
        if (-not (Import-QDProfileIntoUi -Path $entry.Path)) { Write-QDProfileToUi -ProfileData (Get-QDDefaultProfile) }
    }
    else {
        Sync-QDProfileCombo
        Write-QDProfileToUi -ProfileData (Get-QDDefaultProfile)
    }

    $script:MainWindow.Add_ContentRendered({
            $script:PumpTimer.Start()
            $script:DirtyTimer.Start()
            Invoke-QDSysInfoRefresh
            $catalogApps = @($QD.Catalog)
            Invoke-QDWorker -Name 'catalog' -Parameters @{ Apps = $catalogApps } -ScriptBlock {
                param($Apps)
                Set-StrictMode -Version Latest
                Test-QDCatalog -Apps $Apps
            }
            if ($script:StartupToast) { Show-QDToast -Message $script:StartupToast -Kind 'error' }
        })
    $script:StartupToast = $profileError
    [void]$script:MainWindow.ShowDialog()

    $script:PumpTimer.Stop()
    $script:DirtyTimer.Stop()
    $script:RingTimer.Stop()
    # Detach the dispatcher first so background workers never block on a UI that is gone
    $Sync.Dispatcher = $null
    $Sync.Pump = $null
    foreach ($w in @($script:Workers)) {
        try { [void]$w.PS.BeginStop($null, $null) } catch { Write-Verbose 'worker stop' }
    }
    try { $script:MainWindow.Dispatcher.InvokeShutdown() } catch { Write-Verbose 'dispatcher shutdown' }
    Write-QDLog -Message 'QuickDeploy נסגר'
}

#endregion UI — wiring & main window

#region Silent mode & entry point

function Invoke-QDSilentMode {
    <#
    .SYNOPSIS
        מצב שקט: מריץ פרופיל ללא ממשק. מחזיר קוד יציאה 0/1/2.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Name = '', [string]$NewComputerName = '', [bool]$DisableReboot = $false)
    Write-Host ''
    Write-Host ('  QuickDeploy {0} — מצב שקט{1}' -f $QD.Version, $(if ($Sync.Simulate) { ' (סימולציה)' } else { '' })) -ForegroundColor Yellow
    Write-Host ''
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-QDLog -Message 'במצב שקט חובה לציין -Profile' -Level 'ERROR'
        return 2
    }
    $entry = Find-QDProfile -Name $Name
    if ($null -eq $entry) {
        Write-QDLog -Message "הפרופיל '$Name' לא נמצא בתיקייה $($QD.ProfilesDir)" -Level 'ERROR'
        return 2
    }
    try { $p = Import-QDProfileFile -Path $entry.Path }
    catch {
        Write-QDLog -Message $_.Exception.Message -Level 'ERROR'
        return 2
    }
    $cnErr = Test-QDComputerName -Name $NewComputerName
    if ($cnErr) {
        Write-QDLog -Message ('שם מחשב לא תקין: ' + $cnErr) -Level 'ERROR'
        return 2
    }
    $p['computerName'] = $NewComputerName
    foreach ($warn in @(
            $(if ($p.network.joinType -eq 'domain') { 'הצטרפות לדומיין תדולג (דורשת פרטי הזדהות)' }),
            $(if ($p.system.createLocalAdmin) { 'יצירת מנהל מקומי תדולג (דורשת סיסמה)' }),
            $(if (@($p.network.wifi).Count -gt 0) { 'רשתות Wi-Fi ידולגו (דורשות סיסמה)' })
        ) | Where-Object { $_ }) {
        Write-QDLog -Message ('מצב שקט: ' + $warn) -Level 'WARN'
    }
    $transcript = $false
    try { $null = Start-Transcript -Path $QD.TranscriptPath -Append -ErrorAction Stop; $transcript = $true } catch { Write-Verbose 'transcript' }
    try {
        $null = Invoke-QDPipeline -Config $p
    }
    catch {
        Write-QDLog -Message ('שגיאה קריטית: ' + $_.Exception.Message) -Level 'ERROR'
        $Sync.ExitCode = 2
    }
    finally {
        if ($transcript) { try { $null = Stop-Transcript } catch { Write-Verbose 'transcript' } }
    }
    if ($Sync.ReportPath) { Write-QDLog -Message ('דוח: ' + $Sync.ReportPath) -Level 'OK' }
    if ($Sync.RebootRequired) {
        if ($DisableReboot -or $Sync.Simulate) {
            Write-QDLog -Message ('נדרשת הפעלה מחדש (לא בוצעה): ' + (@($Sync.RebootReasons) -join ', ')) -Level 'WARN'
        }
        else {
            Write-QDLog -Message 'המחשב יופעל מחדש בעוד 60 שניות (לביטול: shutdown /a)' -Level 'WARN'
            $null = Invoke-QDNative -FilePath 'shutdown.exe' -ArgumentList @('/r', '/t', '60', '/c', 'QuickDeploy: הפעלה מחדש להשלמת ההקמה')
        }
    }
    return [int]$Sync.ExitCode
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    Initialize-QDFolder
}
catch {
    Write-Host ('QuickDeploy: לא ניתן ליצור את תיקיות העבודה — ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
}
Write-QDLog -Message ('QuickDeploy {0} הופעל על {1} (PowerShell {2}, {3})' -f $QD.Version, $env:COMPUTERNAME, $PSVersionTable.PSVersion, $(if ($Silent) { 'מצב שקט' } else { 'ממשק גרפי' }))
Initialize-QDBuiltInProfile

if ($Silent) {
    $exitCode = 2
    try {
        $exitCode = [int](@(Invoke-QDSilentMode -Name $ProfileName -NewComputerName $ComputerName -DisableReboot ([bool]$NoReboot)) | Select-Object -Last 1)
    }
    catch {
        Write-QDLog -Message ('שגיאה קריטית: ' + $_.Exception.Message) -Level 'ERROR'
        $exitCode = 2
    }
    exit $exitCode
}

try {
    Invoke-QDGuiMode -InitialProfile $ProfileName -InitialComputerName $ComputerName -StartSimulate ([bool]$Simulate) -DisableReboot ([bool]$NoReboot)
}
catch {
    Write-QDLog -Message ('שגיאה קריטית בממשק: ' + $_.Exception.Message) -Level 'ERROR'
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(('QuickDeploy נתקל בשגיאה קריטית:' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + $QD.LogPath), 'QuickDeploy')
    }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    exit 2
}
# Background catalog checks may still be running — end the process explicitly
[Environment]::Exit(0)

#endregion Silent mode & entry point
