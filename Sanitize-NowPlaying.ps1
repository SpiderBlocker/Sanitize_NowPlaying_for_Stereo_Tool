#requires -version 5.1

# sanitize-nowplaying.ps1 (Windows PowerShell 5.1 - Wait-Event watcher)
#
# Input from Playout software:   %artist<sep>%title   (configurable; default separator U+241F "␟")
#
# Outputs for Stereo Tool, all encoded as UTF-8 (no BOM):
# - prefix.txt    : selected language prefix or custom prefix (or empty)
# - artist.txt    : sanitized artist, adaptively limited to 64 characters (or empty)
# - connector.txt : user-defined connector text, padded with one space on each side (only when both fields are present)
# - title.txt     : sanitized title, adaptively limited to 64 characters (or empty)
# - nowplaying_rt.txt        : compact RT text, ordered by the Artist/title order setting (or empty)
# - nowplaying_rtplus.txt    : compact RT+ tagged text, ordered by the Artist/title order setting (or empty)
#
# Console UI:
# - Distinguishes compact RT/RT+ outputs from separately composable PREFIX, ARTIST, CONNECTOR and TITLE outputs.
# - Artist/title output order follows the persistent Artist/title order setting; PREFIX always remains first.
# - Heartbeat status bar with clock + elapsed-since-update indicator.
#
# Notes:
# - UTF-8 is used end-to-end towards Stereo Tool.
# - The sanitizer can transliterate text (Greek/Cyrillic) to an RDS-safe Latin repertoire when ASCII-safe/transliteration is enabled.
#   When transliteration is OFF, it preserves Unicode (e.g., Greek/Cyrillic) while still stripping control/invisible chars.
# - Per-file atomic writes are used to avoid partial reads by Stereo Tool during normal operation.
# - Terminal console QuickEdit is disabled to prevent the console from "freezing" when selecting text.

# -------------------- UTF-8 console setup (code page 65001) --------------------
try { & chcp 65001 > $null } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# -------------------- Shutdown flush (host-independent) -----------------------
# Uses a native Console Control Handler (CTRL+C, close button, ALT+F4, logoff/shutdown) to hard-truncate
# the output files as a last-resort, even when PowerShell finally blocks are not executed (e.g., ps2exe).
# The handler performs only .NET file truncation and never calls back into PowerShell (thread-safe).

try {
    Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class NativeExitFlush
{
    private delegate bool HandlerRoutine(int ctrlType);

    [DllImport("Kernel32.dll", SetLastError=true)]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Volatile references to the active output paths.
    private static volatile string _prefix;
    private static volatile string _artist;
    private static volatile string _connector;
    private static volatile string _title;
    private static volatile string _rt;
    private static volatile string _rtp;

    private static int _installed;
    private static readonly HandlerRoutine _handler = new HandlerRoutine(Handle);

    public static void Install()
    {
        if (Interlocked.Exchange(ref _installed, 1) != 0) return;
        try { SetConsoleCtrlHandler(_handler, true); } catch { }
        // Extra safety net: flush on normal process exit as well.
        try { AppDomain.CurrentDomain.ProcessExit += (s, e) => Flush(); } catch { }
    }

    public static void Update(string prefix, string artist, string connector, string title, string rt, string rtp)
    {
        _prefix    = prefix;
        _artist    = artist;
        _connector = connector;
        _title     = title;
        _rt        = rt;
        _rtp       = rtp;
    }

    public static void Flush()
    {
        TryTruncate(_prefix);
        TryTruncate(_artist);
        TryTruncate(_connector);
        TryTruncate(_title);
        TryTruncate(_rt);
        TryTruncate(_rtp);
    }

    private static void TryTruncate(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            // FileShare.ReadWrite: avoid unnecessary failures when another process has the file open in shared mode.
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
            {
                fs.Flush(true);
            }
        }
        catch { }
    }

    private static bool Handle(int ctrlType)
    {
        // Always attempt flush, but do not "handle" the event.
        // Returning false lets PowerShell's CancelKeyPress/finally logic run when available,
        // while still ensuring the outputs are truncated for hard termination scenarios.
        Flush();
        return false;
    }
}
"@ -ErrorAction Stop
} catch { }

try { [NativeExitFlush]::Install() } catch { }

$ScriptTitle   = "Sanitize NowPlaying for Stereo Tool"
$ScriptVersion = "2.0.3"

# -------------------------------------------------------------------------------------------------
# UI configuration
#
# Keep UI-related constants centralized here to avoid scattering hardcoded values throughout the code.
# IMPORTANT: Do not change these values unless you intend to change the visual appearance/behavior of the UI.
# -------------------------------------------------------------------------------------------------

# Console compatibility switches
# These toggles exist to reduce the risk of host-specific console crashes/quirks on some systems.
# Defaults preserve the current behavior.
$EnableConsoleFontTweak  = $true  # Best-effort font selection (classic conhost only)
$EnableHardScrollLock    = $true  # Best-effort hard scrollback removal (classic conhost only)
$EnableConsoleResizeLock = $true  # Best-effort resize/maximize lock (classic conhost only)

# Console font (classic conhost only; ignored by Windows Terminal)
$UI_ConsolePreferredFonts = @(
    "Cascadia Mono"
    "Cascadia Code"
    "Consolas"
)
$UI_ConsoleFontHeight = 16

# UI margins: one blank row at the top and one blank column at the left.
$script:UiOffsetX     = 1
$script:UiOffsetY     = 1
$script:UiRightMargin = 1  # Keep one free column at the right edge.

# Console sizing and minimum render dimensions (best-effort)
$FixedConsoleWidth   = 111
$FixedConsoleHeight  = 27
$UI_MinConsoleWidth  = 40
$UI_MinConsoleHeight = 20
$UI_MinRenderWidth   = 40

# Base ConsoleColor palette (raw console colors)
$UI_Color_Background     = [ConsoleColor]::Black
$UI_Color_InputText      = [ConsoleColor]::Gray
$UI_Color_BrightText     = [ConsoleColor]::White
$UI_Color_DimText        = [ConsoleColor]::DarkGray
$UI_Color_WarningText    = [ConsoleColor]::Yellow
$UI_Color_WarningTextDim = [ConsoleColor]::DarkYellow
$UI_Color_ErrorText      = [ConsoleColor]::DarkRed

# Semantic colors (output, input, prefix/connector)
$UI_Color_LocationData = [ConsoleColor]::White
$UI_Color_Input        = [ConsoleColor]::DarkYellow
$UI_Color_Prefix       = [ConsoleColor]::Cyan
$UI_Color_Connector    = [ConsoleColor]::Cyan
$UI_Color_Artist       = [ConsoleColor]::Cyan
$UI_Color_Title        = [ConsoleColor]::Cyan
$UI_Color_RT           = [ConsoleColor]::DarkCyan
$UI_Color_RTPlus       = [ConsoleColor]::DarkCyan
$UI_Color_SectionTitle = $UI_Color_BrightText
$UI_Color_MenuFrame    = $UI_Color_InputText
$UI_Color_MenuTitle    = $UI_Color_BrightText
$UI_Color_MenuKey      = $UI_Color_InputText
$UI_Color_MenuLabel    = $UI_Color_InputText
$UI_Color_MenuValue    = $UI_Color_BrightText
$UI_Color_MenuHint     = $UI_Color_DimText
$UI_Color_MenuDisabled = $UI_Color_DimText
$UI_Color_FieldSeparator = [ConsoleColor]::Gray
$UI_Color_Separator      = $UI_Color_DimText

# Selection/inversion (used for menu highlighting, etc.)
$UI_Color_SelectedText = [ConsoleColor]::Black
$UI_Color_SelectedBack = [ConsoleColor]::White

# Frame glyphs
$UI_Frame_Horizontal  = '─'
$UI_Frame_Vertical    = '│'
$UI_Frame_TopLeft     = '╭'
$UI_Frame_TopRight    = '╮'
$UI_Frame_MiddleLeft  = '├'
$UI_Frame_MiddleRight = '┤'
$UI_Frame_BottomLeft  = '╰'
$UI_Frame_BottomRight = '╯'

# Other UI glyphs and text templates
$UI_SeparatorGlyph      = '─'
$UI_Ellipsis            = '...'
$UI_HeaderTitleTemplate = "{0} - v{1}"
$UI_WindowTitleTemplate = "{0} - v{1}  © 2026 Loenie"
$UI_HelpSegmentSeparator = '  '  # Used when fitting multiple action hints into narrow headers.
$UI_HelpCancel           = 'Esc: cancel'

# Dialog geometry
$UI_DialogOuterMargin       = 4  # Preferred total free console columns around a centered dialog.
$UI_DialogMinOuterMargin    = 2  # May be used when extra width is required to keep the header intact.
$UI_DialogFrameOverhead     = 4  # Two frame columns plus one inner padding column on each side.
$UI_DialogTitleHelpGap      = 1  # Minimum gap between the title and right-aligned action hints.
$UI_DialogDistinctSizeDelta = 2  # Width adjustment used when a child exactly matches its underlay.

# Output labels (padded at render time to keep the I/O columns aligned)
$UI_OutputLabelWidth = 13
$UI_Label_WorkingDir = 'WORKING DIR'
$UI_Label_Input      = 'INPUT'
$UI_Label_Prefix     = 'PREFIX'
$UI_Label_Artist     = 'ARTIST'
$UI_Label_Connector  = 'CONNECTOR'
$UI_Label_Title      = 'TITLE'
$UI_Label_CompactRt  = 'COMPACT RT'
$UI_Label_CompactRtPlus = 'COMPACT RT+'
$UI_Label_LastUpdate = 'LAST UPDATE'

# Timing
$UI_ShortSleepMs               = 10    # Milliseconds
$UI_ToastDurationMs            = 1400  # Milliseconds
$UI_WarningDurationShortMs     = 900   # Milliseconds
$UI_WarningDurationNormalMs    = 1400  # Milliseconds
$UI_WarningDurationLongMs      = 1800  # Milliseconds
$UI_StartupToastDurationSec    = 2     # Seconds
$StartupPublishFreshSec        = 180   # Seconds

# Set the console window title (best-effort).
try { $host.UI.RawUI.WindowTitle = ($UI_WindowTitleTemplate -f $ScriptTitle, $ScriptVersion) } catch { }

$InFile                        = 'C:\RDS\nowplaying.txt'
$script:InFile                 = $InFile
$script:StartupInputWasExpired = $false

$PrefixFile           = 'C:\RDS\prefix.txt'
$script:PrefixFile    = $PrefixFile
$ArtistFile           = 'C:\RDS\artist.txt'
$script:ArtistFile    = $ArtistFile
$ConnectorFile        = 'C:\RDS\connector.txt'
$script:ConnectorFile = $ConnectorFile
$TitleFile            = 'C:\RDS\title.txt'
$script:TitleFile     = $TitleFile
$OutFileRt            = 'C:\RDS\nowplaying_rt.txt'
$script:OutFileRt     = $OutFileRt
$OutFileRtPlus        = 'C:\RDS\nowplaying_rtplus.txt'
$script:OutFileRtPlus = $OutFileRtPlus

try { [NativeExitFlush]::Update($script:PrefixFile, $script:ArtistFile, $script:ConnectorFile, $script:TitleFile, $script:OutFileRt, $script:OutFileRtPlus) } catch { }
# -------------------------------------------------------------------------------------------------
# Persistent settings (single file)
#
# All persistent settings are stored in a single JSON file in the application directory.
# -------------------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------------------
# Determine application base directory
# - When running as a normal .ps1, this equals the script directory.
# - When compiled with ps2exe, $AppBaseDir can be empty; in that case we fall back to the EXE directory.
# -------------------------------------------------------------------------------------------------

$AppBaseDir = $null

# Preferred: normal .ps1 execution context
try {
    if ($PSCommandPath) { $AppBaseDir = Split-Path -Parent $PSCommandPath }
} catch { }

# ps2exe / host fallbacks
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try { $AppBaseDir = [AppDomain]::CurrentDomain.BaseDirectory } catch { }
}
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath) { $AppBaseDir = Split-Path -Parent $exePath }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try { $AppBaseDir = (Get-Location).Path } catch { $AppBaseDir = '.' }
}

$SettingsFile = Join-Path $AppBaseDir 'Sanitize-NowPlaying.settings.json'

# Maximum length of each separately emitted prefix/connector string, including automatic spacing.
# The editor validates both the stored input and the fully processed output against this limit.
$MaxCustomTextLen = 64

# In-memory settings (defaults).
$script:Settings = @{
    WorkDir                = ''     # Optional. If set, all IO paths below are derived from this directory.
    PrefixLanguageCode     = 'EN'
    CustomPrefixText       = ''     # Used when PrefixLanguageCode = CUSTOM.
    ConnectorText          = '-'    # Separate output; automatically padded with one space on each side.
    ArtistTitleOrder       = 'ARTIST_TITLE' # ARTIST_TITLE or TITLE_ARTIST; also controls RT/RT+ field order.
    TransliterationEnabled = $true
    AsciiSafeEnabled       = $false
    WorkDirWizardDone      = $false
    DelimiterKey           = 'U241F'  # One of: U241F, TAB, CUSTOM
    DelimiterCustom        = '' # Used when DelimiterKey = CUSTOM
}

function Get-HashtableFromPsObject($obj) {
    if ($null -eq $obj) { return @{} }
    if ($obj -is [System.Collections.IDictionary]) { return @{} + $obj }
    $ht = @{}
    foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    return $ht
}

function Save-Settings {
    $tmp = $null

    try {
        $json = ($script:Settings | ConvertTo-Json -Depth 6)
        $tmp  = [System.IO.Path]::Combine($AppBaseDir, ('~settings_{0}.tmp' -f ([System.Guid]::NewGuid().ToString('N'))))
        [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $SettingsFile -Force
    } catch {
        try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Load-Settings {
    # 1) Load JSON if present.
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $raw = Get-Content -LiteralPath $SettingsFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            $ht  = Get-HashtableFromPsObject $obj

            foreach ($k in @('WorkDir','PrefixLanguageCode','CustomPrefixText','ConnectorText','ArtistTitleOrder','TransliterationEnabled','AsciiSafeEnabled','WorkDirWizardDone','DelimiterKey','DelimiterCustom')) {
                if ($ht.ContainsKey($k)) { $script:Settings[$k] = $ht[$k] }
            }

            # Compatibility with the unreleased two-field implementation, should such a settings file exist.
            if (-not $ht.ContainsKey('CustomPrefixText') -and $ht.ContainsKey('CustomPrefixBeforeArtist')) {
                $script:Settings.CustomPrefixText = $ht['CustomPrefixBeforeArtist']
            }
            if (-not $ht.ContainsKey('ConnectorText') -and $ht.ContainsKey('CustomPrefixBeforeTitle')) {
                $script:Settings.ConnectorText = $ht['CustomPrefixBeforeTitle']
            }
        } catch { }
        return
    }

    # 2) First run: create the settings file with defaults.

    Save-Settings
}

function Ensure-Directory([string]$dir, [string]$purpose) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    if (Test-Path -LiteralPath $dir) {
        return (Test-Path -LiteralPath $dir -PathType Container)
    }

    try {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-WorkDirOrFallback {
    # Ensure the current working directory exists, or fall back to a writable directory.
    $wanted = ''
    try { $wanted = Split-Path -Parent $script:InFile } catch { $wanted = '' }

    # Do not implicitly create the default directory on first run. The user must confirm creation in the WorkDir wizard.
    $wizardDone = $false
    try { $wizardDone = [bool]$script:Settings.WorkDirWizardDone } catch { $wizardDone = $false }

    if ($wanted -and (Test-Path -LiteralPath $wanted -PathType Container)) { return $wanted }
    if ($wanted -and $wizardDone -and (Ensure-Directory $wanted "WorkDir")) { return $wanted }

    # Fallbacks that are typically writable without admin rights.
    $candidates = @()

    foreach ($base in @($env:ProgramData, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            try { $candidates += (Join-Path $base "RDS") } catch { }
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($HOME)) {
            $candidates += (Join-Path $HOME ".rds")
        }
    } catch { }

    foreach ($c in $candidates) {
        if (Ensure-Directory $c "Fallback WorkDir") {
            # Persist and switch all IO paths to the fallback directory.
            $script:Settings.WorkDir           = $c
            $script:Settings.WorkDirWizardDone = $true
            Save-Settings

            Set-WorkDirPaths $c
            return $c
        }
    }

    return $null
}

function Set-WorkDirPaths([string]$dir) {
    # Centralized path derivation for all workdir-dependent files.
    # NOTE: Uses the same variable names/assignments as the original inline blocks (behavior-preserving).
    $InFile               = Join-Path $dir 'nowplaying.txt'
    $script:InFile        = $InFile
    $PrefixFile           = Join-Path $dir 'prefix.txt'
    $script:PrefixFile    = $PrefixFile
    $ArtistFile           = Join-Path $dir 'artist.txt'
    $script:ArtistFile    = $ArtistFile
    $ConnectorFile        = Join-Path $dir 'connector.txt'
    $script:ConnectorFile = $ConnectorFile
    $TitleFile            = Join-Path $dir 'title.txt'
    $script:TitleFile     = $TitleFile
    $OutFileRt            = Join-Path $dir 'nowplaying_rt.txt'
    $script:OutFileRt     = $OutFileRt
    $OutFileRtPlus        = Join-Path $dir 'nowplaying_rtplus.txt'
    $script:OutFileRtPlus = $OutFileRtPlus

    try { [NativeExitFlush]::Update($script:PrefixFile, $script:ArtistFile, $script:ConnectorFile, $script:TitleFile, $script:OutFileRt, $script:OutFileRtPlus) } catch { }

}

function Apply-WorkDirIfConfigured {
    if (-not $script:Settings.WorkDir) { return }
    $dir = $script:Settings.WorkDir.Trim()
    if (-not $dir) { return }
    if (-not (Ensure-Directory $dir "Configured WorkDir")) { return }
    $script:Settings.WorkDir = $dir

    Set-WorkDirPaths $dir
}

function Show-WorkDirWizardIfNeeded {
    # Show a one-time first-run wizard (modal popup). If it has been completed and the directory exists,
    # it will not show again. Returns $false only when the user explicitly cancels the required wizard.
    $dir  = ($script:Settings.WorkDir | ForEach-Object { "$_".Trim() })
    $done = $false
    try { $done = [bool]$script:Settings.WorkDirWizardDone } catch { }

    # Ensure the fixed console layout is applied even before the first full UI render.
    # This matters on first run, where the WorkDir wizard appears before the main UI is initialized.
    try { Ensure-MinConsoleLayout } catch { }

    if ($done -and $dir -and (Test-Path -LiteralPath $dir -PathType Container)) { return $true }
    if ($done -and (-not $dir))                                                { return $true }

    $result = Show-WorkDirMenu -MarkWizardDone
    return ($null -ne $result)
}

# -------------------------------------------------------------------------------------------------
# Prefix text selection (modal settings UI)
#
# The prefix is written to the separate prefix output file and is shown in the console UI.
# Many receivers are conservative with character support. For maximum robustness your pipeline
# already sanitizes the prefix through the same ASCII/RDS-safe passes as other text.
# -------------------------------------------------------------------------------------------------

# Supported languages (Native prefix + ASCII-safe fallback).
# NOTE: Keep a trailing space after ':' to match the existing output formatting.
$PrefixLanguages = @(
@{ Code='CUSTOM'; Name='Custom text';        Native='';                         Ascii='' }
@{ Code='EN'; Name='English';            Native='Now playing: ';            Ascii='Now playing: ' }
@{ Code='NL'; Name='Nederlands';         Native='Je hoort nu: ';            Ascii='Je hoort nu: ' }
@{ Code='DE'; Name='Deutsch';            Native='Jetzt läuft: ';            Ascii='Jetzt laeuft: ' }
@{ Code='FR'; Name='Français';           Native='À l''écoute: ';            Ascii='A l''ecoute: ' }
@{ Code='ES'; Name='Español';            Native='Ahora suena: ';            Ascii='Ahora suena: ' }
@{ Code='PT'; Name='Português';          Native='A tocar agora: ';          Ascii='A tocar agora: ' }
@{ Code='IT'; Name='Italiano';           Native='In riproduzione: ';        Ascii='In riproduzione: ' }
@{ Code='DA'; Name='Dansk';              Native='Nu spiller: ';             Ascii='Nu spiller: ' }
@{ Code='SV'; Name='Svenska';            Native='Spelas nu: ';              Ascii='Spelas nu: ' }
@{ Code='NO'; Name='Norsk';              Native='Spilles nå: ';             Ascii='Spilles naa: ' }
@{ Code='FI'; Name='Suomi';              Native='Nyt soi: ';                Ascii='Nyt soi: ' }
@{ Code='IS'; Name='Íslenska';           Native='Í spilun núna: ';          Ascii='I spilun nuna: ' }
@{ Code='ET'; Name='Eesti';              Native='Hetkel mängib: ';          Ascii='Hetkel mangib: ' }
@{ Code='LV'; Name='Latviešu';           Native='Tagad skan: ';             Ascii='Tagad skan: ' }
@{ Code='LT'; Name='Lietuvių';           Native='Dabar groja: ';            Ascii='Dabar groja: ' }
@{ Code='PL'; Name='Polski';             Native='Teraz gra: ';              Ascii='Teraz gra: ' }
@{ Code='CS'; Name='Čeština';            Native='Právě hraje: ';            Ascii='Prave hraje: ' }
@{ Code='SK'; Name='Slovenčina';         Native='Práve hrá: ';              Ascii='Prave hra: ' }
@{ Code='HU'; Name='Magyar';             Native='Most szól: ';              Ascii='Most szol: ' }
@{ Code='RO'; Name='Română';             Native='Acum se aude: ';           Ascii='Acum se aude: ' }
@{ Code='SL'; Name='Slovenščina';        Native='Trenutno se predvaja: ';   Ascii='Trenutno se predvaja: ' }
@{ Code='HR'; Name='Hrvatski';           Native='Sada svira: ';             Ascii='Sada svira: ' }
@{ Code='BS'; Name='Bosanski';           Native='Sada svira: ';             Ascii='Sada svira: ' }
@{ Code='MK'; Name='Makedonski (Latin)'; Native='Momentalno sviri: ';       Ascii='Momentalno sviri: ' }
@{ Code='SQ'; Name='Shqip';              Native='Tani po luhet: ';          Ascii='Tani po luhet: ' }
@{ Code='TR'; Name='Türkçe';             Native='Şimdi çalıyor: ';          Ascii='Simdi caliyor: ' }
@{ Code='EL'; Name='Ελληνικά';           Native='Τώρα παίζει: ';            Ascii='Tora paizei: ' }
@{ Code='RU'; Name='Русский';            Native='Сейчас играет: ';          Ascii='Seichas igraet: ' }
@{ Code='SR'; Name='Srpski';             Native='Сада свира: ';             Ascii='Sada svira: ' }
@{ Code='BG'; Name='Български';          Native='Сега звучи: ';             Ascii='Sega zvuchi: ' }
@{ Code='UK'; Name='Українська';         Native='Зараз грає: ';             Ascii='Zaraz hraie: ' }
@{ Code='BE'; Name='Беларуская';         Native='Зараз грае: ';             Ascii='Zaraz hrae: ' }
)

# -------------------------------------------------------------------------------------------------
# Transliteration control (Greek + Cyrillic)
#
# Default is ON for maximum robustness, because RDS RadioText is largely Latin-only on many receivers.
# Transliteration can be changed via the F10 Settings menu (persisted to the unified settings JSON file).
# -------------------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------------------
# Unified settings helpers (consolidation)
# -------------------------------------------------------------------------------------------------

function Load-SettingBool([string]$key, [object]$default) {
    try {
        if ($script:Settings -and $script:Settings.ContainsKey($key)) {
            return [bool]$script:Settings[$key]
        }
    } catch { }
    return [bool]$default
}

function Save-SettingBool([string]$key, [bool]$value) {
    if (-not $script:Settings) { return }
    $script:Settings[$key] = [bool]$value
    Save-Settings
}

function Load-SettingStringUpper([string]$key, [string]$default = "") {
    try {
        if ($script:Settings -and $script:Settings.ContainsKey($key) -and $script:Settings[$key]) {
            return "$($script:Settings[$key])".Trim().ToUpperInvariant()
        }
    } catch { }
    return "$default".Trim().ToUpperInvariant()
}

function Save-SettingStringUpper([string]$key, [string]$value) {
    if (-not $script:Settings) { return }
    $script:Settings[$key] = "$value".Trim().ToUpperInvariant()
    Save-Settings
}

function Normalize-ArtistTitleOrder([string]$value) {
    $v = [regex]::Replace("$value".Trim().ToUpperInvariant(), '[^A-Z]+', '_').Trim('_')
    if ($v -eq 'TITLE_ARTIST') { return 'TITLE_ARTIST' }
    return 'ARTIST_TITLE'
}

$script:ArtistTitleOrder = 'ARTIST_TITLE'

function Load-ArtistTitleOrderSetting {
    $raw = Load-SettingStringUpper 'ArtistTitleOrder' 'ARTIST_TITLE'
    $script:ArtistTitleOrder = Normalize-ArtistTitleOrder $raw
    if ($script:Settings) { $script:Settings.ArtistTitleOrder = $script:ArtistTitleOrder }
}

function Save-ArtistTitleOrderSetting {
    $script:ArtistTitleOrder = Normalize-ArtistTitleOrder $script:ArtistTitleOrder
    Save-SettingStringUpper 'ArtistTitleOrder' $script:ArtistTitleOrder
}

function Test-TitleFirstOrder {
    return ((Normalize-ArtistTitleOrder $script:ArtistTitleOrder) -eq 'TITLE_ARTIST')
}

function Get-ArtistTitleOrderDisplay {
    if (Test-TitleFirstOrder) { return 'TITLE -> ARTIST' }
    return 'ARTIST -> TITLE'
}

function Get-ArtistTitleOrderCompactDisplay {
    if (Test-TitleFirstOrder) { return 'T>A' }
    return 'A>T'
}

function Get-PaddedOutputLabel([string]$label) {
    if ($null -eq $label) { $label = '' }
    if ($label.Length -gt $UI_OutputLabelWidth) { return $label.Substring(0, $UI_OutputLabelWidth) }
    return $label.PadRight($UI_OutputLabelWidth)
}

function Limit-TextLength([string]$text, [int]$maxLen) {
    if ($null -eq $text) { return "" }
    if ($maxLen -le 0) { return "" }
    if ($text.Length -le $maxLen) { return $text }

    $t = $text.Substring(0, $maxLen)
    # Do not leave a dangling UTF-16 high surrogate when a Unicode character straddles the boundary.
    if ($t.Length -gt 0 -and [char]::IsHighSurrogate($t[$t.Length - 1])) {
        $t = $t.Substring(0, $t.Length - 1)
    }
    return $t
}

function Normalize-CustomTextSetting([string]$text) {
    if ($null -eq $text) { return "" }

    $t = [string]$text
    # Settings may also be edited by hand, so sanitize control and invisible characters here as well as in the UI.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", " ")
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")
    $t = [regex]::Replace($t, "\s+", " ").Trim()
    return $t
}

function Convert-CustomTextForOutput([string]$text, [switch]$NoLengthLimit) {
    $t = Normalize-CustomTextSetting $text
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }

    # Apply the same common symbol normalization used for artist/title metadata. This also makes
    # the Processed counter reflect expansions such as £ -> GBP and € -> EUR.
    $t = Decode-BasicHtmlEntities $t
    $t = Normalize-FullwidthAscii $t
    $t = Apply-Replacements $t

    # ASCII-safe always implies effective transliteration, even if a settings file was edited by hand.
    if ($script:TransliterationEnabled -or $script:AsciiSafeEnabled) {
        $t = Transliterate-Cyrillic $t
        $t = Transliterate-Greek    $t
    }

    $t = $(if ($script:AsciiSafeEnabled) { AsciiSafe-FinalPass $t } else { UnicodeSafe-FinalPass $t })
    $t = (Cleanup-Whitespace $t).Trim()

    if (-not $NoLengthLimit -and $t.Length -gt $MaxCustomTextLen) {
        $t = Limit-TextLength $t $MaxCustomTextLen
        $t = $t.TrimEnd()
    }
    return $t
}

function Load-TransliterationSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:TransliterationEnabled = Load-SettingBool 'TransliterationEnabled' $script:Settings.TransliterationEnabled
}

function Save-TransliterationSetting {
    Save-SettingBool 'TransliterationEnabled' $script:TransliterationEnabled
}

function Apply-DelimiterFromSettings {
    # Delimiter is configurable to support different playout integrations.
    # Parsing rule is conservative:
    # - Exactly ONE delimiter occurrence -> split into Artist + Title
    # - Otherwise                     -> treat as title-only (Artist empty)
    $key = 'U241F'
    try {
        if ($script:Settings.ContainsKey('DelimiterKey') -and $script:Settings.DelimiterKey) {
            $key = "$($script:Settings.DelimiterKey)".Trim().ToUpperInvariant()
        }
    } catch { }

    switch ($key) {
        'TAB'    { $script:DelimiterKey = 'TAB';    $script:SepChar = "`t";         $script:SepGlyph = 'TAB' }
        'CUSTOM' {
            $custom = ''
            try {
                if ($script:Settings -and $script:Settings.ContainsKey('DelimiterCustom')) { $custom = [string]$script:Settings.DelimiterCustom }
            } catch { $custom = '' }
            if ($null -eq $custom) { $custom = '' }

            if ([string]::IsNullOrWhiteSpace($custom)) {
                # Invalid / empty custom delimiter -> fall back to the default.
                $script:DelimiterKey = 'U241F'
                $script:SepChar      = [char]0x241F
                $script:SepGlyph     = [char]0x241F
            } else {
                $script:DelimiterKey = 'CUSTOM'
                $script:SepChar      = $custom
                $script:SepGlyph     = $custom
            }
        }
        default  { $script:DelimiterKey = 'U241F';  $script:SepChar = [char]0x241F; $script:SepGlyph = [char]0x241F }
    }

    # Backward compatibility: older builds and some hosts may expect globals.
    $global:SepChar  = $script:SepChar
    $global:SepGlyph = $script:SepGlyph
}

function Format-DelimiterForDisplay {
    param([string]$delim)

    if ($null -eq $delim) { return "" }

    # TAB is a dedicated built-in option. Keep it as a clear label.
    if ($delim -eq "`t" -or $delim -eq "TAB") { return "TAB" }

    # Visualize spaces as open box (␣ U+2423) for clarity.
    return $delim.Replace(" ", [char]0x2423)
}

function Save-DelimiterSetting {
    if (-not $script:Settings) { return }

    $script:Settings.DelimiterKey = "$script:DelimiterKey".Trim().ToUpperInvariant()

    if ($script:Settings.DelimiterKey -eq 'CUSTOM') {
        # Persist the actual delimiter string as well.
        # IMPORTANT: when the user just entered a new custom delimiter, $script:SepChar may still hold the old value
        # until Apply-DelimiterFromSettings runs. Therefore we prefer the value already present in Settings.
        $custom = ''
        try {
            if ($script:Settings.ContainsKey('DelimiterCustom')) { $custom = [string]$script:Settings.DelimiterCustom }
        } catch { $custom = '' }

        if ($null -eq $custom) { $custom = '' }

        if ([string]::IsNullOrWhiteSpace($custom)) {
            # Fall back to the current runtime delimiter (best effort).
            try { $custom = [string]$script:SepChar } catch { $custom = '' }
            if ($null -eq $custom) { $custom = '' }

        }

        $script:Settings.DelimiterCustom = $custom
    }

    Save-Settings
}

# Load persisted setting (if any).
Load-TransliterationSetting

# -------------------------------------------------------------------------------------------------
# Global ASCII-safe control (all emitted text outputs)
#
# When enabled, output is forced through the conservative Latin/ASCII-oriented final pass used for RDS robustness.
# This is independent of the prefix language selection. If you enable ASCII-safe while transliteration is OFF,
# the script will temporarily force transliteration ON to avoid silently dropping Greek/Cyrillic. When ASCII-safe
# is turned OFF again, the previous transliteration state is restored.
# -------------------------------------------------------------------------------------------------

$script:AsciiSafeEnabled            = $false
$script:TranslitForcedByAsciiSafe   = $false
$script:TranslitPrevBeforeAsciiSafe = $true

function Load-AsciiSafeSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:AsciiSafeEnabled = Load-SettingBool 'AsciiSafeEnabled' $script:Settings.AsciiSafeEnabled
}

function Save-AsciiSafeSetting {
    Save-SettingBool 'AsciiSafeEnabled' $script:AsciiSafeEnabled
}

Load-AsciiSafeSetting

function Get-PrefixLanguageIndex([string]$code) {
    for ($i = 0; $i -lt $PrefixLanguages.Count; $i++) {
        if ($PrefixLanguages[$i].Code -eq $code) { return $i }
    }

    # CUSTOM is intentionally the first menu item, so index 0 is not a safe fallback for
    # an unknown, obsolete or manually corrupted language code. Prefer English instead.
    for ($i = 0; $i -lt $PrefixLanguages.Count; $i++) {
        if ($PrefixLanguages[$i].Code -eq 'EN') { return $i }
    }

    return 0
}

function Load-PrefixLanguageSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:PrefixLanguageCode = Load-SettingStringUpper 'PrefixLanguageCode' $script:Settings.PrefixLanguageCode
}

function Save-PrefixLanguageSetting {
    Save-SettingStringUpper 'PrefixLanguageCode' $script:PrefixLanguageCode
}

function Apply-PrefixFromLanguage {
    $idx   = Get-PrefixLanguageIndex $script:PrefixLanguageCode
    $entry = $PrefixLanguages[$idx]

    if ($entry.Code -eq 'CUSTOM') {
        $customPrefix = ''
        try { $customPrefix = Normalize-CustomTextSetting ([string]$script:Settings.CustomPrefixText) } catch { $customPrefix = '' }

        # Custom text is processed later by the same transliteration/ASCII-safe path as the connector.
        $script:PrefixTextNative = $customPrefix
        $script:PrefixTextAscii  = $customPrefix
    } else {
        $script:PrefixTextNative = $entry.Native
        $script:PrefixTextAscii  = $entry.Ascii
    }

    # The conventional combined RT/RT+ outputs remain language-neutral and backward compatible.
    $script:OutJoin = " - "
}

# Load persisted selection (if any) and apply.
Load-PrefixLanguageSetting
Apply-PrefixFromLanguage

# -------------------------------------------------------------------------------------------------

$MaxLen     = 64
$DebounceMs = 250

# Main-loop idle poll cadence. The heartbeat itself redraws only when its visible value changes.
$PollIntervalMs = 100

$ReadRetryCount   = 20
$ReadRetryDelayMs = 50

$SepChar  = [char]0x241F  # Configurable delimiter for the playout integration
$SepGlyph = [char]0x241F  # Display label for the current delimiter
$OutJoin  = " - "

# Stop flag (cooperative shutdown).
$script:Stopping       = $false
$script:RebuildWatcher = $false

# Tracks whether output files have been flushed due to missing input (prevents repeated writes).
$script:OutputsFlushedForNotAvailable = $false

# Active modal-dialog geometry, used to keep nested windows visually distinct from their underlay.
$script:UiDialogStack = New-Object System.Collections.ArrayList

function Get-UiEllipsis([int]$maxWidth) {
    if ($maxWidth -le 0) { return "" }

    $ellipsis = [string]$UI_Ellipsis
    if ([string]::IsNullOrEmpty($ellipsis)) { return "" }
    if ($ellipsis.Length -le $maxWidth) { return $ellipsis }

    return $ellipsis.Substring(0, $maxWidth)
}

function Truncate-UiText([string]$s, [int]$maxWidth) {
    if ($null -eq $s) { $s = "" }
    if ($maxWidth -le 0) { return "" }
    if ($s.Length -le $maxWidth) { return $s }

    $ellipsis = Get-UiEllipsis $maxWidth
    $keep     = [Math]::Max(0, $maxWidth - $ellipsis.Length)

    if ($keep -le 0) { return $ellipsis }
    return ($s.Substring(0, $keep) + $ellipsis)
}

function Truncate-UiTextMiddle([string]$s, [int]$maxWidth) {
    if ($null -eq $s) { $s = "" }
    if ($maxWidth -le 0) { return "" }
    if ($s.Length -le $maxWidth) { return $s }

    $ellipsis = Get-UiEllipsis $maxWidth
    $keep     = [Math]::Max(0, $maxWidth - $ellipsis.Length)
    if ($keep -le 0) { return $ellipsis }

    $leftKeep  = [int][Math]::Ceiling($keep / 2.0)
    $rightKeep = [int]($keep - $leftKeep)

    return ($s.Substring(0, $leftKeep) + $ellipsis + $s.Substring($s.Length - $rightKeep))
}


function Format-UiActionHints([string]$text, [int]$width) {
    # Keep the rightmost/highest-priority actions visible in narrow menu headers.
    # Help strings are split on runs of two or more spaces, then fitted from right to left.
    if ($width -le 0) { return "" }
    if ([string]::IsNullOrWhiteSpace($text)) { return (" " * $width) }

    $normalized = $text.Trim()
    if ($normalized.Length -le $width) { return $normalized.PadRight($width) }

    $segments = @(
        $normalized -split '\s{2,}' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($segments.Count -le 1) {
        return (Truncate-UiText $normalized $width).PadRight($width)
    }

    $separator = [string]$UI_HelpSegmentSeparator
    if ($null -eq $separator) { $separator = '  ' }

    $chosen = @()
    for ($i = $segments.Count - 1; $i -ge 0; $i--) {
        $candidate = (@([string]$segments[$i]) + $chosen) -join $separator
        if ($candidate.Length -le $width) {
            $chosen = @([string]$segments[$i]) + $chosen
        } else {
            break
        }
    }

    if ($chosen.Count -eq 0) {
        $result = Truncate-UiText ([string]$segments[$segments.Count - 1]) $width
    } else {
        $result = $chosen -join $separator
    }

    # Right-align shortened help so the cancellation action remains visually anchored.
    return $result.PadLeft($width)
}

function Write-UiActionHintText([int]$x, [int]$y, [string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return }

    $parts = [regex]::Split($text, '(\s{2,})')
    $cursorX = $x

    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }

        if ($part -match '^\s+$') {
            Write-At $cursorX $y $part $UI_Color_MenuHint
            $cursorX += $part.Length
            continue
        }

        if ($part -match '^([^:]+:)(.*)$') {
            $keyText  = $matches[1]
            $descText = $matches[2]

            Write-At $cursorX $y $keyText $UI_Color_MenuKey
            $cursorX += $keyText.Length

            if (-not [string]::IsNullOrEmpty($descText)) {
                Write-At $cursorX $y $descText $UI_Color_MenuHint
                $cursorX += $descText.Length
            }
        } else {
            Write-At $cursorX $y $part $UI_Color_MenuHint
            $cursorX += $part.Length
        }
    }
}

function Write-UiHeaderContent([int]$x, [int]$y, [int]$width, [string]$title, [string]$help) {
    if ($width -le 0) { return }
    if ($null -eq $title) { $title = '' }
    if ($null -eq $help)  { $help  = '' }

    # Always clear the full content area first, so shorter warnings/help text cannot leave remnants.
    Write-At $x $y (' ' * $width) $UI_Color_DimText

    $helpText = (Format-UiActionHints $help $width).Trim()
    $helpX    = $width
    $titleMax = $width

    if (-not [string]::IsNullOrEmpty($helpText)) {
        $helpX = [Math]::Max(0, $width - $helpText.Length)
        $titleMax = [Math]::Max(0, $helpX - $UI_DialogTitleHelpGap)
    }

    $titleText = Truncate-UiText $title $titleMax
    if (-not [string]::IsNullOrEmpty($titleText)) {
        Write-At $x $y $titleText $UI_Color_MenuTitle
    }

    if (-not [string]::IsNullOrEmpty($helpText)) {
        Write-UiActionHintText ($x + $helpX) $y $helpText
    }
}

function Get-UiDialogUnderlayGeometry {
    if ($null -eq $script:UiDialogStack -or $script:UiDialogStack.Count -le 0) { return $null }
    return $script:UiDialogStack[$script:UiDialogStack.Count - 1]
}

function Push-UiDialogGeometry([int]$width, [int]$height, [int]$x, [int]$y) {
    if ($null -eq $script:UiDialogStack) {
        $script:UiDialogStack = New-Object System.Collections.ArrayList
    }

    $entry = [pscustomobject]@{
        Token  = [Guid]::NewGuid().ToString('N')
        Width  = [Math]::Max(0, $width)
        Height = [Math]::Max(0, $height)
        X      = $x
        Y      = $y
    }

    [void]$script:UiDialogStack.Add($entry)
    return [string]$entry.Token
}

function Pop-UiDialogGeometry([string]$token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return }
    if ($null -eq $script:UiDialogStack -or $script:UiDialogStack.Count -le 0) { return }

    for ($i = $script:UiDialogStack.Count - 1; $i -ge 0; $i--) {
        if ([string]$script:UiDialogStack[$i].Token -eq $token) {
            $script:UiDialogStack.RemoveAt($i)
            break
        }
    }
}

function Get-UiAvailableHeight([int]$minimumHeight = 10) {
    # Return the height of the drawable UI area below the configured top margin.
    $height = $minimumHeight
    try {
        $windowHeight = [Console]::WindowHeight
        $bufferHeight = [Console]::BufferHeight
        if ($windowHeight -gt 0 -and $bufferHeight -gt 0) {
            $height = [Math]::Min($windowHeight, $bufferHeight)
        } elseif ($windowHeight -gt 0) {
            $height = $windowHeight
        } elseif ($bufferHeight -gt 0) {
            $height = $bufferHeight
        }
    } catch { }

    $height -= [Math]::Max(0, [int]$script:UiOffsetY)
    return [Math]::Max($minimumHeight, $height)
}

function Get-UiCenteredStart([int]$availableSize, [int]$dialogSize) {
    # Dialog widths are parity-aligned below, so this normally yields equal margins.
    $remaining = [Math]::Max(0, $availableSize - $dialogSize)
    return [int][Math]::Floor($remaining / 2.0)
}

function Get-UiDialogWidth(
    [int]$availableWidth,
    [int]$preferredWidth,
    [int]$minimumWidth,
    [string]$title,
    [string]$help,
    [int]$dialogHeight = 0,
    [int]$outerMargin = $UI_DialogOuterMargin
) {
    # Size the dialog from its content, with a per-dialog minimum and a console-safe maximum.
    # The title and all action hints fit on one line whenever the console is wide enough.
    $required = [Math]::Max(2, [int]$UI_DialogFrameOverhead)

    if (-not [string]::IsNullOrEmpty($title)) { $required += $title.Length }
    if (-not [string]::IsNullOrEmpty($help)) {
        if (-not [string]::IsNullOrEmpty($title)) {
            $required += [Math]::Max(0, [int]$UI_DialogTitleHelpGap)
        }
        $required += $help.Length
    }

    # Prefer the normal breathing room around a dialog, but reduce it to the configured minimum
    # when that is enough to keep the complete header on one line.
    $preferredMargin = [Math]::Max(0, $outerMargin)
    $minimumMargin   = [Math]::Max(0, [Math]::Min($preferredMargin, [int]$UI_DialogMinOuterMargin))
    $maxWidth        = [Math]::Max(8, $availableWidth - $preferredMargin)
    if ($required -gt $maxWidth) {
        $maxWidth = [Math]::Max(8, $availableWidth - $minimumMargin)
    }

    $minimum = [Math]::Max(8, $minimumWidth)
    $target  = [Math]::Max($minimum, [Math]::Max($preferredWidth, $required))
    $target  = [Math]::Min($maxWidth, $target)

    # Match the dialog-width parity to the available UI width. This guarantees equal left/right
    # margins whenever there is room, and keeps differently sized nested dialogs on one centre line.
    if ((($availableWidth - $target) % 2) -ne 0) {
        if (($target + 1) -le $maxWidth) {
            $target++
        } elseif (($target - 1) -ge $minimum) {
            $target--
        }
    }

    # A nested dialog with exactly the same width and height as its underlay looks like a redraw
    # rather than a separate modal layer. Nudge its width while preserving the header and minimum.
    $underlay = Get-UiDialogUnderlayGeometry
    if ($null -ne $underlay -and $dialogHeight -gt 0 -and
        $target -eq [int]$underlay.Width -and $dialogHeight -eq [int]$underlay.Height) {

        # Keep this adjustment even so the child remains exactly centred as well.
        $delta = [Math]::Max(2, [int]$UI_DialogDistinctSizeDelta)
        if (($delta % 2) -ne 0) { $delta++ }
        $wider = [Math]::Min($maxWidth, $target + $delta)

        if ($wider -gt $target) {
            $target = $wider
        } else {
            $smallestSafe = [Math]::Max($minimum, [Math]::Min($maxWidth, $required))
            $narrower     = $target - $delta
            if ($narrower -ge $smallestSafe) {
                $target = $narrower
            }
        }
    }

    return $target
}

# -------------------- Minimal startup toast (UI helpers only) -----------------
function Show-StartupToast {
    param(
    [Parameter(Mandatory=$true)][string]$Message,
    [int]$Seconds = $UI_StartupToastDurationSec
    )

    try {
        # Ensure we are writing to a real console window.
        if (-not $Host.UI -or -not $Host.UI.RawUI) { return }

        $raw = $Host.UI.RawUI
        $w   = [Math]::Max(20, $raw.WindowSize.Width)
        $h   = [Math]::Max(5,  $raw.WindowSize.Height)

        # Basic box geometry (centered, like a modal toast).
        $padX = 2
        $msg  = $Message.Trim()
        $msg = Truncate-UiText $msg ([Math]::Max(0, $w - 6))

        $boxW = [Math]::Min($w - 2, [Math]::Max(20, $msg.Length + 6))
        $left = [Math]::Max(0, [int](($w - $boxW) / 2))
        $top  = [Math]::Max(0, [int](($h - 5) / 2))

        # Draw
        $origFg = $raw.ForegroundColor
        $origBg = $raw.BackgroundColor

        $raw.ForegroundColor = $UI_Color_InputText
        $raw.BackgroundColor = $UI_Color_Background

        $lineTop = $UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight
        $lineMid = $UI_Frame_Vertical + (" " * ($boxW - 2)) + $UI_Frame_Vertical
        $lineBot = $UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight

        [Console]::SetCursorPosition($left, $top)
        [Console]::Write($lineTop)
        [Console]::SetCursorPosition($left, $top + 1)
        [Console]::Write($lineMid)
        [Console]::SetCursorPosition($left, $top + 2)
        [Console]::Write($UI_Frame_Vertical + (" " * $padX) + $msg.PadRight($boxW - 2 - ($padX * 2)) + (" " * $padX) + $UI_Frame_Vertical)
        [Console]::SetCursorPosition($left, $top + 3)
        [Console]::Write($lineMid)
        [Console]::SetCursorPosition($left, $top + 4)
        [Console]::Write($lineBot)

        Start-Sleep -Seconds ([Math]::Max(1, $Seconds))
        $raw.ForegroundColor = $origFg
        $raw.BackgroundColor = $origBg
    } catch {
        # Last resort: write a normal line.
        try { Write-Host $Message } catch { }
        try { Start-Sleep -Seconds ([Math]::Max(1, $Seconds)) } catch { }
    }
}

# -------------------- One-instance guard (Local named mutex) ------------------
# Prevent multiple instances from running simultaneously (per logon session).
$MutexName             = "Local\SanitizeNowPlayingForStereoTool"
$script:Mutex          = $null
$script:MutexHasHandle = $false

try {
    $createdNew   = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)

    if (-not $createdNew) {
        if (-not $script:Mutex.WaitOne(0, $false)) {
            try { Clear-Host } catch { }
            Show-StartupToast -Message "Another instance is already running."
            exit 0
        }
    }

    $script:MutexHasHandle = $true
} catch {
    $script:Mutex          = $null
    $script:MutexHasHandle = $false
}

# -------------------- Health / elapsed color tuning ---------------------------
$HealthGraceSec = 120  # 2 minutes grace
$HealthRedAtSec = 900  # 15 minutes to full red

# -------------------- Console host fixes --------------------------------------

function Disable-ConsoleQuickEdit {
    try {
        if (-not ("Win.ConsoleModeNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleModeNative {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);

        public const int STD_INPUT_HANDLE = -10;
        public const int ENABLE_QUICK_EDIT_MODE = 0x0040;
        public const int ENABLE_EXTENDED_FLAGS  = 0x0080;
        public const int ENABLE_MOUSE_INPUT    = 0x0010;
    }
}
"@
        }

        $h = [Win.ConsoleModeNative]::GetStdHandle([Win.ConsoleModeNative]::STD_INPUT_HANDLE)
        if ($h -eq [IntPtr]::Zero) { return }

        $mode = 0
        if (-not [Win.ConsoleModeNative]::GetConsoleMode($h, [ref]$mode)) { return }

        $mode = $mode -bor [Win.ConsoleModeNative]::ENABLE_EXTENDED_FLAGS
        $mode = $mode -band (-bnot [Win.ConsoleModeNative]::ENABLE_QUICK_EDIT_MODE)
        $mode = $mode -band (-bnot [Win.ConsoleModeNative]::ENABLE_MOUSE_INPUT)

        [void][Win.ConsoleModeNative]::SetConsoleMode($h, $mode)
    } catch { }
}

function Install-ConsoleCtrlABlocker {
    # Classic conhost handles Ctrl+A as a console-wide Select All command before .NET's
    # Console.ReadKey/KeyAvailable can see it. A low-level keyboard hook is therefore used
    # to suppress only Ctrl+A, and only while this console window is in the foreground.
    # No keystrokes are logged or retained; every other key is passed through unchanged.
    try {
        if (-not ("Win.ConsoleCtrlABlocker" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;
    using System.Threading;

    public static class ConsoleCtrlABlocker {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN     = 0x0100;
        private const int WM_KEYUP       = 0x0101;
        private const int WM_SYSKEYDOWN  = 0x0104;
        private const int WM_SYSKEYUP    = 0x0105;
        private const int WM_QUIT        = 0x0012;
        private const int VK_A           = 0x41;
        private const int VK_LCONTROL    = 0xA2;
        private const int VK_RCONTROL    = 0xA3;
        private const int VK_LMENU       = 0xA4;
        private const int VK_RMENU       = 0xA5;
        private const uint GA_ROOT       = 2;

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG {
            public IntPtr hwnd;
            public uint message;
            public UIntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public POINT pt;
            public uint lPrivate;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

        [DllImport("user32.dll", SetLastError=true)]
        private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool PostThreadMessage(uint idThread, uint Msg, UIntPtr wParam, IntPtr lParam);

        private static readonly object Sync = new object();
        private static readonly ManualResetEventSlim Ready = new ManualResetEventSlim(false);
        private static LowLevelKeyboardProc HookProc = HookCallback;
        private static Thread HookThread;
        private static IntPtr HookHandle = IntPtr.Zero;
        private static IntPtr ConsoleWindow = IntPtr.Zero;
        private static uint HookThreadId;
        private static int SuppressingA;

        public static bool Start() {
            lock (Sync) {
                if (HookThread != null) {
                    return HookHandle != IntPtr.Zero;
                }

                ConsoleWindow = GetConsoleWindow();
                if (ConsoleWindow == IntPtr.Zero) {
                    return false;
                }

                Ready.Reset();
                HookThread = new Thread(HookThreadMain);
                HookThread.IsBackground = true;
                HookThread.Name = "Console Ctrl+A blocker";
                HookThread.Start();
            }

            Ready.Wait(1500);
            return HookHandle != IntPtr.Zero;
        }

        public static void Stop() {
            Thread threadToJoin = null;

            lock (Sync) {
                threadToJoin = HookThread;
                if (threadToJoin == null) {
                    return;
                }

                if (HookThreadId != 0) {
                    PostThreadMessage(HookThreadId, WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
                }
            }

            try {
                if (threadToJoin.IsAlive) {
                    threadToJoin.Join(1000);
                }
            }
            catch { }
        }

        private static void HookThreadMain() {
            HookThreadId = GetCurrentThreadId();

            try {
                HookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, HookProc, GetModuleHandle(null), 0);
            }
            catch {
                HookHandle = IntPtr.Zero;
            }
            finally {
                Ready.Set();
            }

            if (HookHandle != IntPtr.Zero) {
                MSG msg;
                while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { }

                try { UnhookWindowsHookEx(HookHandle); } catch { }
            }

            lock (Sync) {
                HookHandle = IntPtr.Zero;
                HookThreadId = 0;
                HookThread = null;
                SuppressingA = 0;
            }
        }

        private static bool IsDown(int virtualKey) {
            return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        }

        private static bool IsOwnConsoleForeground() {
            IntPtr foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero || ConsoleWindow == IntPtr.Zero) {
                return false;
            }

            IntPtr foregroundRoot = GetAncestor(foreground, GA_ROOT);
            IntPtr consoleRoot = GetAncestor(ConsoleWindow, GA_ROOT);
            return foreground == ConsoleWindow ||
                   (foregroundRoot != IntPtr.Zero && foregroundRoot == consoleRoot);
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0) {
                int message = wParam.ToInt32();
                int virtualKey = Marshal.ReadInt32(lParam);

                if (virtualKey == VK_A) {
                    bool keyDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                    bool keyUp   = message == WM_KEYUP   || message == WM_SYSKEYUP;

                    if (keyDown) {
                        bool controlDown = IsDown(VK_LCONTROL) || IsDown(VK_RCONTROL);
                        bool altDown = IsDown(VK_LMENU) || IsDown(VK_RMENU);

                        // Do not suppress AltGr combinations, which often appear as Ctrl+Alt.
                        if (controlDown && !altDown && IsOwnConsoleForeground()) {
                            Interlocked.Exchange(ref SuppressingA, 1);
                            return new IntPtr(1);
                        }
                    }
                    else if (keyUp && Interlocked.Exchange(ref SuppressingA, 0) != 0) {
                        return new IntPtr(1);
                    }
                }
            }

            return CallNextHookEx(HookHandle, nCode, wParam, lParam);
        }
    }
}
"@
        }

        return [Win.ConsoleCtrlABlocker]::Start()
    } catch {
        return $false
    }
}

function Stop-ConsoleCtrlABlocker {
    try {
        if ("Win.ConsoleCtrlABlocker" -as [type]) {
            [Win.ConsoleCtrlABlocker]::Stop()
        }
    } catch { }
}

function Clear-ConsoleSelectionIfActive {
    # Best-effort fallback for console-host selection/mark mode, including a mouse-created
    # selection anchor. Cancelling it also prevents a stray block/caret from remaining visible.
    $selectionWasActive = $false
    try {
        if (-not ("Win.ConsoleSelectionNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleSelectionNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct CONSOLE_SELECTION_INFO {
            public uint dwFlags;
            public COORD dwSelectionAnchor;
            public SMALL_RECT srSelection;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleSelectionInfo(out CONSOLE_SELECTION_INFO lpConsoleSelectionInfo);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        public const uint WM_KEYDOWN = 0x0100;
        public const uint WM_KEYUP   = 0x0101;
        public const int VK_ESCAPE   = 0x1B;

        public const uint CONSOLE_SELECTION_IN_PROGRESS = 0x0001;
        public const uint CONSOLE_SELECTION_NOT_EMPTY   = 0x0002;
        public const uint CONSOLE_MOUSE_SELECTION      = 0x0004;
        public const uint CONSOLE_MOUSE_DOWN           = 0x0008;
        public const uint ANY_SELECTION_FLAG           = 0x000F;
    }
}
"@
        }

        $sel = New-Object Win.ConsoleSelectionNative+CONSOLE_SELECTION_INFO
        if (-not [Win.ConsoleSelectionNative]::GetConsoleSelectionInfo([ref]$sel)) { return $false }

        if (($sel.dwFlags -band [Win.ConsoleSelectionNative]::ANY_SELECTION_FLAG) -ne 0) {
            $selectionWasActive = $true
            $hwnd = [Win.ConsoleSelectionNative]::GetConsoleWindow()
            if ($hwnd -ne [IntPtr]::Zero) {
                [void][Win.ConsoleSelectionNative]::PostMessage($hwnd, [Win.ConsoleSelectionNative]::WM_KEYDOWN, [IntPtr][Win.ConsoleSelectionNative]::VK_ESCAPE, [IntPtr]::Zero)
                [void][Win.ConsoleSelectionNative]::PostMessage($hwnd, [Win.ConsoleSelectionNative]::WM_KEYUP,   [IntPtr][Win.ConsoleSelectionNative]::VK_ESCAPE, [IntPtr]::Zero)
            }
        }
    } catch { }

    return $selectionWasActive
}

function Maintain-MainConsoleInputState {
    # Some conhost versions can restore selection-related behavior after focus/mouse activity.
    # Re-assert the desired input mode and hide/cancel any stray main-view cursor or selection.
    if ($script:UiOverlayActive) { return }
    try { Disable-ConsoleQuickEdit } catch { }
    try { [void](Clear-ConsoleSelectionIfActive) } catch { }
    try { [Console]::CursorVisible = $false } catch { }
}

function Disable-ConsoleResizeControls {
    # Best-effort: remove resize borders (sizer grip) and disable the maximize button in classic conhost.
    # In Windows Terminal this is typically not applicable and is skipped.

    try {
        if ([bool]$env:WT_SESSION) { return }  # Windows Terminal (or compatible host)

        if (-not ("Win.ConsoleWindowNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleWindowNative {
        public const int GWL_STYLE = -16;

        public const int WS_MAXIMIZEBOX = 0x00010000;
        public const int WS_THICKFRAME  = 0x00040000; // WS_SIZEBOX / resizable border

        public const uint SWP_NOSIZE       = 0x0001;
        public const uint SWP_NOMOVE       = 0x0002;
        public const uint SWP_NOZORDER     = 0x0004;
        public const uint SWP_FRAMECHANGED = 0x0020;

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", EntryPoint="GetWindowLongPtr", SetLastError=true)]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint="SetWindowLongPtr", SetLastError=true)]
        private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        [DllImport("user32.dll", EntryPoint="GetWindowLong", SetLastError=true)]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint="SetWindowLong", SetLastError=true)]
        private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
            int X, int Y, int cx, int cy, uint uFlags);

        public static int GetStyle(IntPtr hwnd) {
            if (IntPtr.Size == 8) return (int)GetWindowLongPtr64(hwnd, GWL_STYLE);
            return GetWindowLong32(hwnd, GWL_STYLE);
        }

        public static void SetStyle(IntPtr hwnd, int style) {
            if (IntPtr.Size == 8) SetWindowLongPtr64(hwnd, GWL_STYLE, (IntPtr)style);
            else SetWindowLong32(hwnd, GWL_STYLE, style);
        }

        public static void RefreshFrame(IntPtr hwnd) {
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        }
    }
}
"@
        }

        $hwnd = [Win.ConsoleWindowNative]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }

        $style    = [Win.ConsoleWindowNative]::GetStyle($hwnd)
        $mask     = [Win.ConsoleWindowNative]::WS_THICKFRAME -bor [Win.ConsoleWindowNative]::WS_MAXIMIZEBOX
        $newStyle = $style -band (-bnot $mask)

        if ($newStyle -ne $style) {
            [Win.ConsoleWindowNative]::SetStyle($hwnd, $newStyle)
            [Win.ConsoleWindowNative]::RefreshFrame($hwnd)
        }
    } catch { }
}

function Read-OverlayKey {
    $key = [Console]::ReadKey($true)

    # Continuous key-repeat can otherwise starve the menu-idle branch. Refresh any uncovered
    # heartbeat row once per consumed key so navigation never builds up hidden display lag.
    try { Update-HeartbeatDuringOverlayIfVisible } catch { }

    return $key
}

function Read-TextEditorKey {
    while ($true) {
        try {
            if ([Console]::KeyAvailable) { return (Read-OverlayKey) }
        } catch {
            return (Read-OverlayKey)
        }

        # Keep input processing, failed-output retries and any safely visible heartbeat active
        # while a text editor is open. The helper restores the editor cursor afterwards.
        try { Do-UpdateIfNeeded } catch { }
        try { [void](Retry-PendingOutputsIfDue) } catch { }
        try { Update-HeartbeatDuringOverlayIfVisible } catch { }

        Start-Sleep -Milliseconds $UI_ShortSleepMs
    }
}

function Set-ClipboardTextSafe([string]$Text) {
    if ($null -eq $Text) { $Text = "" }

    try {
        if (Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
    } catch { }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
        [System.Windows.Forms.Clipboard]::SetText($Text)
        return $true
    } catch { }

    return $false
}


function Set-ConsoleFontBestEffort {
    param(
    [string[]]$PreferredFonts = $UI_ConsolePreferredFonts,
    [int]$FontHeight = $UI_ConsoleFontHeight
    )

    try {
        if (-not ("Win.ConsoleFontNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleFontNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        public struct CONSOLE_FONT_INFOEX {
            public uint cbSize;
            public uint nFont;
            public COORD dwFontSize;
            public int FontFamily;
            public int FontWeight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
            public string FaceName;
        }

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool GetCurrentConsoleFontEx(
            IntPtr hConsoleOutput,
            bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx
        );

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool SetCurrentConsoleFontEx(
            IntPtr hConsoleOutput,
            bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx
        );

        public const int STD_OUTPUT_HANDLE = -11;
    }
}
"@
        }

        $hOut = [Win.ConsoleFontNative]::GetStdHandle([Win.ConsoleFontNative]::STD_OUTPUT_HANDLE)
        if ($hOut -eq [IntPtr]::Zero) { return }

        $cfi        = New-Object Win.ConsoleFontNative+CONSOLE_FONT_INFOEX
        $cfi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($cfi)

        if (-not [Win.ConsoleFontNative]::GetCurrentConsoleFontEx($hOut, $false, [ref]$cfi)) { return }

        try {
            if ($FontHeight -gt 0 -and $FontHeight -lt 100) { $cfi.dwFontSize.Y = [int16]$FontHeight }
        } catch { }

        foreach ($name in $PreferredFonts) {
            try {
                $old          = $cfi.FaceName
                $cfi.FaceName = $name
                if ([Win.ConsoleFontNative]::SetCurrentConsoleFontEx($hOut, $false, [ref]$cfi)) { return }
                $cfi.FaceName = $old
            } catch { }
        }
    } catch { }
}
Disable-ConsoleQuickEdit

# Suppress conhost's built-in Ctrl+A / Select All action before it can affect the UI.
# The blocker is scoped to this console window and is removed again during shutdown.
$script:ConsoleCtrlABlockerInstalled = Install-ConsoleCtrlABlocker

# Font changing via SetCurrentConsoleFontEx is known to be unstable on some console hosts.
# Only attempt it in classic conhost sessions (best-effort).
try {
    $isWindowsTerminal = [bool]$env:WT_SESSION
    if (-not $isWindowsTerminal -and $EnableConsoleResizeLock) {
        Disable-ConsoleResizeControls
    }
    if (-not $isWindowsTerminal -and $EnableConsoleFontTweak) {
        Set-ConsoleFontBestEffort -PreferredFonts $UI_ConsolePreferredFonts -FontHeight $UI_ConsoleFontHeight
    }
} catch { }

try { Clear-Host } catch { }
try { [Console]::CursorVisible = $false } catch { }

$script:BaseFg = $UI_Color_InputText
$script:BaseBg = $UI_Color_Background
try {
    [Console]::ForegroundColor = $script:BaseFg
    [Console]::BackgroundColor = $script:BaseBg
} catch { }

# -------------------- Console primitives --------------------------------------

function With-ConsoleColor([ConsoleColor]$fg, [ConsoleColor]$bg, [scriptblock]$action) {
    $oldFg = [Console]::ForegroundColor
    $oldBg = [Console]::BackgroundColor
    try {
        [Console]::ForegroundColor = $fg
        [Console]::BackgroundColor = $bg
        & $action
    } finally {
        [Console]::ForegroundColor = $oldFg
        [Console]::BackgroundColor = $oldBg
    }
}

function Pad-OrEllipsize([string]$s, [int]$width) {
    return (Truncate-UiText $s $width)
}

function Show-CustomTextEditor([string]$title, [string]$label, [string]$initialValue, [int]$labelWidth = 17, [int]$outputPadding = 0) {
    # Single-field editor shared by the custom prefix and the independent connector setting.
    # Enter accepts only when both the stored input and the final emitted output, including
    # automatic spacing, fit within 64 characters.
    $dialogToken = $null
    $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
    $winH = Get-UiAvailableHeight 10

    $boxH = 7
    $sizingHelp = "Enter: apply$UI_HelpSegmentSeparator$UI_HelpCancel"
    $boxW = Get-UiDialogWidth $winW 68 54 $title $sizingHelp -dialogHeight $boxH
    $x0   = Get-UiCenteredStart $winW $boxW
    $y0   = Get-UiCenteredStart $winH $boxH
    $dialogToken = Push-UiDialogGeometry $boxW $boxH $x0 $y0

    $value         = Normalize-CustomTextSetting $initialValue
    $position      = $value.Length
    $selectAll     = ($value.Length -gt 0)
    $outputPadding = [Math]::Max(0, $outputPadding)
    function _DrawCustomTextBox {
        $headerHelp = "Enter: apply$UI_HelpSegmentSeparator$UI_HelpCancel"

        Write-At $x0 $y0 ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)

        $headerW = $boxW - 4

        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition $x0 ($y0 + 1); [Console]::Write($UI_Frame_Vertical + " ")
            Set-UiCursorPosition ($x0 + $boxW - 2) ($y0 + 1); [Console]::Write(" " + $UI_Frame_Vertical)
        }
        Write-UiHeaderContent ($x0 + 2) ($y0 + 1) $headerW $title $headerHelp

        Write-At $x0 ($y0 + 2) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

        $labelW = $labelWidth
        $fieldW = $boxW - 4 - $labelW
        $pos    = [Math]::Max(0, [Math]::Min($value.Length, [int]$position))
        $start  = 0
        if (($pos - $start) -ge $fieldW) { $start = $pos - $fieldW + 1 }
        if ($start -gt $value.Length) { $start = $value.Length }
        $take   = [Math]::Min($fieldW, [Math]::Max(0, $value.Length - $start))
        $shown  = $(if ($take -gt 0) { $value.Substring($start, $take) } else { '' })
        $shown  = $shown.PadRight($fieldW)

        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition $x0 ($y0 + 3); [Console]::Write($UI_Frame_Vertical + " ")
            Set-UiCursorPosition ($x0 + $boxW - 2) ($y0 + 3); [Console]::Write(" " + $UI_Frame_Vertical)
        }
        With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
            Set-UiCursorPosition ($x0 + 2) ($y0 + 3); [Console]::Write($label.PadRight($labelW))
        }

        $fieldX = $x0 + 2 + $labelW
        if ($selectAll -and $value.Length -gt 0) {
            With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                Set-UiCursorPosition $fieldX ($y0 + 3); [Console]::Write($shown)
            }
        } else {
            With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                Set-UiCursorPosition $fieldX ($y0 + 3); [Console]::Write($shown)
            }
        }

        Write-At $x0 ($y0 + 4) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

        $normalized      = Normalize-CustomTextSetting $value
        $processedCore   = Convert-CustomTextForOutput $normalized -NoLengthLimit
        $processedLength = $(if ([string]::IsNullOrWhiteSpace($processedCore)) { 0 } else { $processedCore.Length + $outputPadding })
        $inputLength   = $normalized.Length
        $inputAtLimit  = ($inputLength -ge $MaxCustomTextLen)
        $outputAtLimit = ($processedLength -ge $MaxCustomTextLen)
        $inputTooLong  = ($inputLength -gt $MaxCustomTextLen)
        $outputTooLong = ($processedLength -gt $MaxCustomTextLen)

        $statusSegments = @(
            @{ Text = 'Input: ';  Color = $UI_Color_DimText },
            @{ Text = ('{0}/{1}' -f $inputLength, $MaxCustomTextLen); Color = $(if ($inputAtLimit) { $UI_Color_WarningText } else { $UI_Color_InputText }) },
            @{ Text = '   ';      Color = $UI_Color_DimText },
            @{ Text = 'Output: '; Color = $UI_Color_DimText },
            @{ Text = ('{0}/{1}' -f $processedLength, $MaxCustomTextLen); Color = $(if ($outputAtLimit) { $UI_Color_WarningText } else { $UI_Color_InputText }) }
        )
        if ($inputTooLong -or $outputTooLong) {
            $statusSegments += @{ Text = '  TOO LONG'; Color = $UI_Color_WarningText }
        }

        $statusW = $boxW - 4

        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition $x0 ($y0 + 5); [Console]::Write($UI_Frame_Vertical + " ")
            Set-UiCursorPosition ($x0 + $boxW - 2) ($y0 + 5); [Console]::Write(" " + $UI_Frame_Vertical)
        }

        $statusX    = $x0 + 2
        $statusLeft = $statusW
        foreach ($segment in $statusSegments) {
            if ($statusLeft -le 0) { break }

            $segmentText = [string]$segment.Text
            if ($segmentText.Length -gt $statusLeft) {
                $segmentText = $segmentText.Substring(0, $statusLeft)
            }
            if ($segmentText.Length -le 0) { continue }

            With-ConsoleColor ([ConsoleColor]($segment.Color)) ($UI_Color_Background) {
                Set-UiCursorPosition $statusX ($y0 + 5); [Console]::Write($segmentText)
            }
            $statusX    += $segmentText.Length
            $statusLeft -= $segmentText.Length
        }

        if ($statusLeft -gt 0) {
            With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                Set-UiCursorPosition $statusX ($y0 + 5); [Console]::Write((' ' * $statusLeft))
            }
        }

        Write-At $x0 ($y0 + 6) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)

        if (-not $selectAll) {
            $pos = [Math]::Max(0, [Math]::Min($value.Length, [int]$position))
            $start = 0
            if (($pos - $start) -ge $fieldW) { $start = $pos - $fieldW + 1 }
            $cursorX = $fieldX + ($pos - $start)
            if ($cursorX -ge ($x0 + $boxW - 2)) { $cursorX = $x0 + $boxW - 3 }
            Set-UiInputCursor $cursorX ($y0 + 3)
        } else {
            try { [Console]::CursorVisible = $false } catch { }
        }
    }

    try {
        while ($true) {
            _DrawCustomTextBox
            $k = Read-TextEditorKey

            if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
            if ($k.Key -eq [ConsoleKey]::Enter) {
                $normalized      = Normalize-CustomTextSetting $value
                $processedCore   = Convert-CustomTextForOutput $normalized -NoLengthLimit
                $processedLength = $(if ([string]::IsNullOrWhiteSpace($processedCore)) { 0 } else { $processedCore.Length + $outputPadding })

                if ($normalized.Length -gt $MaxCustomTextLen) { continue }
                if ($processedLength -gt $MaxCustomTextLen) { continue }
                return $normalized
            }

            $pos = [Math]::Max(0, [Math]::Min($value.Length, [int]$position))

            if ($k.Key -eq [ConsoleKey]::Home) {
                $selectAll = $false
                $position  = 0
                continue
            }
            if ($k.Key -eq [ConsoleKey]::End) {
                $selectAll = $false
                $position  = $value.Length
                continue
            }
            if ($k.Key -eq [ConsoleKey]::LeftArrow) {
                if ($selectAll) { $position = 0 } else { $position = [Math]::Max(0, $pos - 1) }
                $selectAll = $false
                continue
            }
            if ($k.Key -eq [ConsoleKey]::RightArrow) {
                if ($selectAll) { $position = $value.Length } else { $position = [Math]::Min($value.Length, $pos + 1) }
                $selectAll = $false
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Backspace) {
                if ($selectAll) {
                    $value     = ''
                    $position  = 0
                    $selectAll = $false
                } elseif ($pos -gt 0) {
                    $value    = $value.Remove($pos - 1, 1)
                    $position = $pos - 1
                }
                continue
            }
            if ($k.Key -eq [ConsoleKey]::Delete) {
                if ($selectAll) {
                    $value     = ''
                    $position  = 0
                    $selectAll = $false
                } elseif ($pos -lt $value.Length) {
                    $value = $value.Remove($pos, 1)
                }
                continue
            }

            if ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                if ($selectAll) {
                    $value     = ''
                    $pos       = 0
                    $selectAll = $false
                }
                if ($value.Length -ge $MaxCustomTextLen) { continue }
                $value    = $value.Insert($pos, [string]$k.KeyChar)
                $position = $pos + 1
            }
        }
    } finally {
        try { [Console]::CursorVisible = $false } catch { }
        Pop-UiDialogGeometry $dialogToken
        # Restore the covered rows explicitly. The connector editor previously relied only on its
        # caller's partial redraw, which could leave frame remnants after Esc.
        try { Restore-UiAfterMenu $y0 $boxH } catch { }
    }
}

function Show-LanguageMenu {
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $dialogToken            = $null
    Lock-ConsoleScrolling
    try {
        # Modal language selection UI (opened from the Settings menu).
        # Keys: Up/Down = navigate, Enter = select, Esc = cancel.
        try { [Console]::CursorVisible = $false } catch { }
        Lock-ConsoleScrolling

        $winW = [Math]::Max(40, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = Get-UiAvailableHeight 10

        $title = "Select prefix text"
        $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   $UI_HelpCancel" } else { "Up/Down: move   Enter: apply   $UI_HelpCancel" })
        $menuH = [Math]::Min($winH - 6, 18)
        $menuW = Get-UiDialogWidth $winW 78 52 $title $help -dialogHeight $menuH
        $x0    = Get-UiCenteredStart $winW $menuW
        $y0    = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $selected = Get-PrefixLanguageIndex $script:PrefixLanguageCode

        $translitHintCodes = @("EL","RU","SR","BG","UK","BE")
        $translitHintPad   = 0
        if (-not $script:AsciiSafeEnabled -and $script:TransliterationEnabled) {
            foreach ($e2 in $PrefixLanguages) {
                if ($e2.Code -in $translitHintCodes) {
                    $n2 = $e2.Native.Trim().Length
                    if ($n2 -gt $translitHintPad) { $translitHintPad = $n2 }
                }
            }
        }

        # Ensure the currently selected language is visible immediately when opening the menu.
        $listH0 = $menuH - 5
        if ($PrefixLanguages.Count -le $listH0) {
            $top = 0
        } else {
            $half = [int]([Math]::Floor($listH0 / 2))
            $top  = [Math]::Max(0, [Math]::Min($PrefixLanguages.Count - $listH0, $selected - $half))
        }

        function _DrawMenu {
            # Border and title
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $listH = $menuH - 5
            for ($i = 0; $i -lt $listH; $i++) {
                $idx   = $top + $i
                $lineY = $y0 + 4 + $i

                $borderFg = $UI_Color_MenuFrame
                $borderBg = $script:BaseBg

                if ($idx -ge $PrefixLanguages.Count) {
                    # Empty filler line (keep the border in one consistent color).
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition $x0 $lineY
                        [Console]::Write($UI_Frame_Vertical)
                    }
                    With-ConsoleColor $itemFg $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write((" " * ($menuW - 2)))
                    }
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                        [Console]::Write($UI_Frame_Vertical)
                    }
                    continue
                }

                $e = $PrefixLanguages[$idx]
                $p = $(if ($script:AsciiSafeEnabled) { $e.Ascii } else { $e.Native })

                # Visual hint: when transliteration is enabled (and ASCII-safe is not), show the original script
                # plus the actual output form for Greek/Cyrillic prefixes.
                $pShown = $p.Trim()
                if ($e.Code -eq 'CUSTOM') {
                    $customRaw = ''
                    try { $customRaw = Normalize-CustomTextSetting ([string]$script:Settings.CustomPrefixText) } catch { }
                    $pShown = $(if ($customRaw) { $customRaw } else { '<empty>' })
                } elseif (-not $script:AsciiSafeEnabled -and $script:TransliterationEnabled -and ($e.Code -in @("EL","RU","SR","BG","UK","BE"))) {
                    $native0      = $e.Native.Trim()
                    $nativePadded = $(if ($translitHintPad -gt 0) { $native0.PadRight($translitHintPad) } else { $native0 })
                    $pShown       = ("{0} -> {1}" -f $nativePadded, $e.Ascii.Trim())
                }

                # Use identical column widths for CUSTOM and all language rows.
                $label = ("{0}  {1}  {2}" -f $e.Code.PadRight(6), $e.Name.PadRight(18), $pShown)

                $content = " " + $label
                if ($content.Length -gt ($menuW - 4)) { $content = $content.Substring(0, $menuW - 4) }
                $content = $content.PadRight($menuW - 4)

                # Draw with a constant border color, independent from the line's text highlighting.
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY
                    [Console]::Write($UI_Frame_Vertical)
                }

                $inner = " " + $content + " "
                if ($idx -eq $selected) {
                    With-ConsoleColor $UI_Color_SelectedText $UI_Color_SelectedBack {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                    [Console]::Write($UI_Frame_Vertical)
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
            try { [Console]::CursorVisible = $false } catch { }
        }

        _DrawMenu
        while ($true) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { _DrawMenu } catch { }
                }
                continue
            }
            $k = Read-OverlayKey

            if ($k.Key -eq [ConsoleKey]::Escape) { Restore-UiAfterMenu $y0 $menuH; return $false }

            if ($k.Key -eq [ConsoleKey]::UpArrow) {
                if ($selected -gt 0) { $selected-- }
            } elseif ($k.Key -eq [ConsoleKey]::DownArrow) {
                if ($selected -lt ($PrefixLanguages.Count - 1)) { $selected++ }
            } elseif ($k.Key -eq [ConsoleKey]::PageUp) {
                $selected = [Math]::Max(0, $selected - 10)
            } elseif ($k.Key -eq [ConsoleKey]::PageDown) {
                $selected = [Math]::Min($PrefixLanguages.Count - 1, $selected + 10)
            }
            elseif ($k.Key -eq [ConsoleKey]::Enter) {
                $newCode = $PrefixLanguages[$selected].Code

                if ($newCode -eq 'CUSTOM') {
                    $initial = ''
                    try { $initial = [string]$script:Settings.CustomPrefixText } catch { }

                    $custom = Show-CustomTextEditor 'Custom prefix text' 'Prefix text:' $initial -labelWidth 14 -outputPadding 1
                    if ($null -eq $custom) { _DrawMenu; continue }

                    $script:Settings.CustomPrefixText = Normalize-CustomTextSetting ([string]$custom)
                }

                $script:PrefixLanguageCode = $newCode
                Save-PrefixLanguageSetting
                Apply-PrefixFromLanguage
                Restore-UiAfterMenu $y0 $menuH
                return $true
            }

            # Keep selection visible
            $listH = $menuH - 5
            if ($selected -lt $top) { $top = $selected }
            if ($selected -ge ($top + $listH)) { $top = $selected - $listH + 1 }

            _DrawMenu
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
    }
}

function Show-OnOffMenu([string]$title, [bool]$currentValue) {
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $dialogToken            = $null
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW  = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH  = Get-UiAvailableHeight 10
        $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   $UI_HelpCancel" } else { "Up/Down: move   Enter: apply   $UI_HelpCancel" })
        $items = @(
        @{ Label = "ON";  Value = $true  }
        @{ Label = "OFF"; Value = $false }
        )

        $menuH = [Math]::Min($winH - 6, 8)
        $menuW = Get-UiDialogWidth $winW 34 34 $title $help -dialogHeight $menuH
        $x0    = Get-UiCenteredStart $winW $menuW
        $y0    = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $selected = $(if ($currentValue) { 0 } else { 1 })
        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = $script:BaseBg

            for ($i = 0; $i -lt 2; $i++) {
                $lineY = $y0 + 4 + $i
                $label = " " + $items[$i].Label
                $label = $label.PadRight($menuW - 4)
                $inner = " " + $label + " "

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical) }

                if ($i -eq $selected) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical) }
            }

            # fill remaining lines (if any)
            for ($j = 6; $j -lt ($menuH - 1); $j++) {
                $lineY = $y0 + $j
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical)
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical)
                }
                With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                    Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write((" " * ($menuW - 2)))
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { _DrawMenu } catch { }
                }
                continue
            }
            $k = Read-OverlayKey

            if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
            if ($k.Key -eq [ConsoleKey]::UpArrow) {
                $n = $selected
                while ($true) {
                    $n = [Math]::Max(0, $n - 1)
                    if ($n -eq $selected) { break }
                    if (_IsSelectableIndex $n) { $selected = $n; break }
                    if ($n -le 0) { break }
                }
                _DrawMenu
                continue
            }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min(1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {
                return [bool]$items[$selected].Value
            }
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-ArtistTitleOrderMenu([string]$currentOrder) {
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $menuW = 42
    $menuH = 8
    $x0 = 0
    $y0 = 0
    $dialogToken = $null
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = Get-UiAvailableHeight 10
        $title = 'Artist/title order'
        $help  = "Up/Down: move   Enter: apply   $UI_HelpCancel"
        $items = @(
            @{ Label = 'ARTIST -> TITLE'; Value = 'ARTIST_TITLE' }
            @{ Label = 'TITLE -> ARTIST'; Value = 'TITLE_ARTIST' }
        )

        $menuH = [Math]::Min($winH - 6, 8)
        $menuW = Get-UiDialogWidth $winW 42 42 $title $help -dialogHeight $menuH
        $x0    = Get-UiCenteredStart $winW $menuW
        $y0    = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $normalizedCurrent = Normalize-ArtistTitleOrder $currentOrder
        $selected = $(if ($normalizedCurrent -eq 'TITLE_ARTIST') { 1 } else { 0 })

        function _DrawOrderMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help
            $borderFg = $UI_Color_MenuFrame
            $borderBg = $script:BaseBg

            for ($i = 0; $i -lt 2; $i++) {
                $lineY = $y0 + 4 + $i
                $label = (' ' + $items[$i].Label).PadRight($menuW - 4)
                $inner = ' ' + $label + ' '

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical) }
                if ($i -eq $selected) {
                    With-ConsoleColor $UI_Color_SelectedText $UI_Color_SelectedBack {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor $UI_Color_MenuLabel $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                }
                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical) }
            }

            for ($j = 6; $j -lt ($menuH - 1); $j++) {
                $lineY = $y0 + $j
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical)
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical)
                }
                With-ConsoleColor $UI_Color_MenuLabel $borderBg {
                    Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write((' ' * ($menuW - 2)))
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) $UI_Color_MenuFrame
        }

        _DrawOrderMenu
        while ($true) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { _DrawOrderMenu } catch { }
                }
                continue
            }

            $k = Read-OverlayKey
            if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
            if ($k.Key -eq [ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1); _DrawOrderMenu; continue }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min(1, $selected + 1); _DrawOrderMenu; continue }
            if ($k.Key -eq [ConsoleKey]::Enter) { return [string]$items[$selected].Value }
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-DelimiterMenu {
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $dialogToken            = $null
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = Get-UiAvailableHeight 10

        $title = "Playout delimiter"
        $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   $UI_HelpCancel" } else { "Up/Down: move   Enter: apply   $UI_HelpCancel" })

        # Current custom delimiter (if any), for display purposes.
        $curCustom = ''
        try { if ($script:Settings -and $script:Settings.ContainsKey('DelimiterCustom')) { $curCustom = [string]$script:Settings.DelimiterCustom } } catch { $curCustom = '' }
        if ($null -eq $curCustom) { $curCustom = '' }
        # Display is formatted in two aligned columns for readability.
        $items = @(
        @{ Key = "U241F";  Glyph = "␟";    CodeLabel = "U+241F"; Desc = "recommended" }
        @{ Key = "TAB";    Glyph = "TAB";  CodeLabel = "U+0009"; Desc = "usually safe" }
        @{ Key = "CUSTOM"; Glyph = $(if ($curCustom) { if ($curCustom -eq "`t") { "TAB" } else { $curCustom.Replace(" ", [char]0x2423).Replace("`t", [char]0x2409) } } else { "" }); CodeLabel = "custom";  Desc = "enter custom playout delimiter" }
        )

        $menuH = [Math]::Min($winH - 6, 9)
        $menuW = Get-UiDialogWidth $winW 60 44 $title $help -dialogHeight $menuH
        $x0    = Get-UiCenteredStart $winW $menuW
        $y0    = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $selected = 0
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ("$($items[$i].Key)".ToUpperInvariant() -eq "$script:DelimiterKey".ToUpperInvariant()) { $selected = $i; break }
        }

        function _CopyToClipboard([string]$s) {
            return (Set-ClipboardTextSafe -Text $s)
        }

        function _ShowToast([string]$message) {
            if ([string]::IsNullOrWhiteSpace($message)) { return }

            $msg = $message.Trim()
            while ($msg.EndsWith(".")) { $msg = $msg.Substring(0, $msg.Length - 1).TrimEnd() }

            $maxW = [Math]::Max(24, [Math]::Min($menuW - 8, 72))
            $msg = Truncate-UiText $msg ([Math]::Max(0, $maxW - 6))

            $boxW = [Math]::Min($maxW, ($msg.Length + 6))
            $boxH = 3

            # Center horizontally within the menu.
            $bx = $x0 + [int](($menuW - $boxW) / 2)

            # Center vertically within the item list area (never on the frame lines).
            $listTopY = $y0 + 4
            $listH    = ($menuH - 5)
            $by       = $listTopY + [int](($listH - $boxH) / 2)

            # Safety clamps (menu interior only).
            if ($by -lt ($y0 + 2)) { $by = $y0 + 2 }
            if ($by -gt ($y0 + $menuH - 2 - $boxH + 1)) { $by = ($y0 + $menuH - 2 - $boxH + 1) }

            # Border
            Write-At $bx $by       ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)
            Write-At $bx ($by + 2) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)

            # Message line (bright text)
            $inner = (" " + $msg.PadRight($boxW - 4) + " ")

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $bx ($by + 1); [Console]::Write($UI_Frame_Vertical)
                Set-UiCursorPosition ($bx + $boxW - 1) ($by + 1); [Console]::Write($UI_Frame_Vertical)
            }
            With-ConsoleColor ($UI_Color_BrightText) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + 1) ($by + 1); [Console]::Write($inner)
            }

            Start-Sleep -Milliseconds $UI_ToastDurationMs

            # Redraw the Delimiter menu to restore any covered content cleanly (same behavior as the WorkDir menu).
            try { _DrawMenu } catch { }
        }

        function _PromptCustomDelimiter([string]$initialValue) {
            # Modal overlay input box.
            # Returns the entered delimiter string, or $null when cancelled (Esc) / empty (Enter).
            $boxW = [Math]::Min(68, [Math]::Max(44, $menuW - 6))
            $boxH = 7
            $bx   = $x0 + [int](($menuW - $boxW) / 2)
            $by   = $y0 + [int](($menuH - $boxH) / 2)

            $prompt = "Playout delimiter: "
            $buf    = ""

            $MaxCustomDelimiterLen = 5
            if ($initialValue) { $buf = [string]$initialValue }
            if ($buf.Length -gt $MaxCustomDelimiterLen) {
                $buf = $buf.Substring(0, $MaxCustomDelimiterLen)
            }

            $position  = $buf.Length
            $selectAll = ($buf.Length -gt 0)

            function _GetDelimiterDisplay([string]$value) {
                if ($null -eq $value) { return "" }
                if ($value -eq "`t") { return "TAB" }
                return $value.Replace(" ", [char]0x2423).Replace("`t", [char]0x2409)
            }

            function _GetDelimiterDisplayPrefixLength([string]$value, [int]$charCount) {
                if ($null -eq $value -or $charCount -le 0) { return 0 }
                $count = [Math]::Min($value.Length, $charCount)
                return (_GetDelimiterDisplay ($value.Substring(0, $count))).Length
            }

            function _DrawInputBox {
                Write-At $bx $by       ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)

                $innerWHeader = $boxW - 4
                $headerTitle  = "Custom playout delimiter"
                $headerHelp   = "Enter: apply$UI_HelpSegmentSeparator$UI_HelpCancel"

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 1); [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 1); [Console]::Write(" " + $UI_Frame_Vertical)
                }
                Write-UiHeaderContent ($bx + 2) ($by + 1) $innerWHeader $headerTitle $headerHelp

                Write-At $bx ($by + 2) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

                $innerW = $boxW - 4
                $fieldW = [Math]::Max(1, $innerW - $prompt.Length)
                $shown  = _GetDelimiterDisplay $buf
                if ($shown.Length -gt $fieldW) { $shown = $shown.Substring($shown.Length - $fieldW, $fieldW) }
                $shown = $shown.PadRight($fieldW)

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 3); [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 3); [Console]::Write(" " + $UI_Frame_Vertical)
                }
                With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 3); [Console]::Write($prompt)
                }

                $fieldX = $bx + 2 + $prompt.Length
                if ($selectAll -and $buf.Length -gt 0) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition $fieldX ($by + 3); [Console]::Write($shown)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                        Set-UiCursorPosition $fieldX ($by + 3); [Console]::Write($shown)
                    }
                }

                Write-At $bx ($by + 4) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

                $inputLength    = $buf.Length
                $inputAtLimit   = ($inputLength -ge $MaxCustomDelimiterLen)
                $statusSegments = @(
                    @{ Text = 'Input: '; Color = $UI_Color_DimText },
                    @{ Text = ('{0}/{1}' -f $inputLength, $MaxCustomDelimiterLen); Color = $(if ($inputAtLimit) { $UI_Color_WarningText } else { $UI_Color_InputText }) }
                )

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 5); [Console]::Write($UI_Frame_Vertical + " " )
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 5); [Console]::Write(" " + $UI_Frame_Vertical)
                }

                $statusX    = $bx + 2
                $statusLeft = $boxW - 4
                foreach ($segment in $statusSegments) {
                    if ($statusLeft -le 0) { break }
                    $segmentText = [string]$segment.Text
                    if ($segmentText.Length -gt $statusLeft) { $segmentText = $segmentText.Substring(0, $statusLeft) }
                    if ($segmentText.Length -le 0) { continue }

                    With-ConsoleColor ([ConsoleColor]($segment.Color)) ($UI_Color_Background) {
                        Set-UiCursorPosition $statusX ($by + 5); [Console]::Write($segmentText)
                    }
                    $statusX    += $segmentText.Length
                    $statusLeft -= $segmentText.Length
                }
                if ($statusLeft -gt 0) {
                    With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                        Set-UiCursorPosition $statusX ($by + 5); [Console]::Write((' ' * $statusLeft))
                    }
                }

                Write-At $bx ($by + 6) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)

                if (-not $selectAll) {
                    $pos        = [Math]::Max(0, [Math]::Min($buf.Length, [int]$position))
                    $displayPos = _GetDelimiterDisplayPrefixLength $buf $pos
                    $cursorX    = $fieldX + [Math]::Min(($fieldW - 1), $displayPos)
                    Set-UiInputCursor $cursorX ($by + 3)
                } else {
                    try { [Console]::CursorVisible = $false } catch { }
                }
            }

            try {
                while ($true) {
                    _DrawInputBox

                    $k = Read-TextEditorKey
                    if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
                    if ($k.Key -eq [ConsoleKey]::Enter) {
                        $val = $buf
                        if ([string]::IsNullOrWhiteSpace($val)) { return $null }
                        if ($val.Length -gt $MaxCustomDelimiterLen) { $val = $val.Substring(0, $MaxCustomDelimiterLen) }
                        return $val
                    }

                    $pos = [Math]::Max(0, [Math]::Min($buf.Length, [int]$position))

                    if ($k.Key -eq [ConsoleKey]::Home) {
                        $selectAll = $false
                        $position  = 0
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::End) {
                        $selectAll = $false
                        $position  = $buf.Length
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::LeftArrow) {
                        if ($selectAll) { $position = 0 } else { $position = [Math]::Max(0, $pos - 1) }
                        $selectAll = $false
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::RightArrow) {
                        if ($selectAll) { $position = $buf.Length } else { $position = [Math]::Min($buf.Length, $pos + 1) }
                        $selectAll = $false
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::Backspace) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                        } elseif ($pos -gt 0) {
                            $buf      = $buf.Remove($pos - 1, 1)
                            $position = $pos - 1
                        }
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::Delete) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                        } elseif ($pos -lt $buf.Length) {
                            $buf = $buf.Remove($pos, 1)
                        }
                        continue
                    }

                    # Allow printable characters and TAB; an initial selected value is replaced by the first edit.
                    $isInputChar = ($k.KeyChar -ne [char]0) -and ((-not [char]::IsControl($k.KeyChar)) -or ([int][char]$k.KeyChar -eq 9))
                    if ($isInputChar) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                            $pos       = 0
                        }

                        if ($buf.Length -ge $MaxCustomDelimiterLen) { continue }

                        $buf      = $buf.Insert($pos, [string]$k.KeyChar)
                        $position = $pos + 1
                    }
                }
            } finally {
                try { [Console]::CursorVisible = $false } catch { }
            }
        }
        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = $script:BaseBg

            $leftW = 0
            foreach ($it in $items) {
                $lw = ("{0}  ({1})" -f $it.Glyph, $it.CodeLabel).Length
                if ($lw -gt $leftW) { $leftW = $lw }
            }

            $listH = $menuH - 5
            for ($i = 0; $i -lt $listH; $i++) {
                $lineY = $y0 + 4 + $i
                if ($i -ge $items.Count) {
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical)
                        Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical)
                    }
                    With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write((" " * ($menuW - 2)))
                    }
                    continue
                }

                $targetParenCol = 7
                $gap            = $targetParenCol - $items[$i].Glyph.Length
                if ($gap -lt 2) { $gap = 2 }

                $left  = ("{0}{1}({2})" -f $items[$i].Glyph, (" " * $gap), $items[$i].CodeLabel)
                $label = ($left.PadRight($leftW) + "  -  " + $items[$i].Desc)

                $text = " " + $label
                if ($text.Length -gt ($menuW - 4)) { $text = $text.Substring(0, $menuW - 4) }
                $text  = $text.PadRight($menuW - 4)
                $inner = " " + $text + " "

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition $x0 $lineY; [Console]::Write($UI_Frame_Vertical) }

                if ($i -eq $selected) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write($UI_Frame_Vertical) }
            }

            Write-At $x0 ($y0 + $menuH - 1) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { _DrawMenu } catch { }
                }
                continue
            }
            $k = Read-OverlayKey

            if ($k.Key -eq [ConsoleKey]::Escape) { return $false }
            if ($k.Key -eq [ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1); _DrawMenu; continue }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min($items.Count - 1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {
                $newKey  = "$($items[$selected].Key)".Trim().ToUpperInvariant()
                $changed = $false

                if ($newKey -eq 'CUSTOM') {
                    $val = _PromptCustomDelimiter $curCustom
                    if ($null -eq $val) { _DrawMenu; continue }

                    # Apply to settings immediately (so Apply-DelimiterFromSettings can pick it up).
                    if (-not $script:Settings) { $script:Settings = @{} }
                    $script:Settings.DelimiterCustom = $val
                    # Keep runtime delimiter in sync so clipboard/toast reflect the entered value immediately.
                    $script:SepChar  = $val
                    $script:SepGlyph = $val

                    $changed             = ($script:DelimiterKey.ToUpperInvariant() -ne 'CUSTOM') -or ($curCustom -ne $val)
                    $script:DelimiterKey = 'CUSTOM'
                } else {
                    $changed             = ($newKey -ne "$script:DelimiterKey".Trim().ToUpperInvariant())
                    $script:DelimiterKey = $newKey
                }

                Save-DelimiterSetting
                Apply-DelimiterFromSettings
                try { Refresh-UiAfterSettingChange } catch { }

                # Copy to clipboard + toast (always, even when the selection didn't change).
                $clipText  = [string]$script:SepChar
                $toastText = (Format-DelimiterForDisplay $clipText)
                if (_CopyToClipboard $clipText) {
                    _ShowToast ("[{0}] copied to clipboard" -f $toastText)
                } else {
                    _ShowToast ("Clipboard copy failed")
                }

                return $changed
            }
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-SettingsMenu {
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $dialogToken            = $null
    $anyChanged             = $false
    # Snapshot current settings so Esc can discard changes reliably.
    # We copy key/value pairs to keep the object type consistent (hashtable-like).
    $originalSettings = @{}
    foreach ($k in $script:Settings.Keys) { $originalSettings[$k] = $script:Settings[$k] }
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = Get-UiAvailableHeight 10

        $title = "Settings"
        $help  = "Up/Down: move   Enter: select   $UI_HelpCancel"

        $items = @(
        @{ Label = "Working directory";      Kind = "workdir" }
        @{ Label = "Prefix text";            Kind = "prefix" }
        @{ Label = "Artist/title order";      Kind = "order" }
        @{ Label = "Connector text";         Kind = "connector" }
        @{ Label = "ASCII-safe";             Kind = "ascii" }
        @{ Label = "Transliteration EL/CYR"; Kind = "translit" }
        @{ Label = "Playout delimiter";      Kind = "sep" }
        @{ Label = "Save & exit";            Kind = "exit" }
        )

        $menuH = [Math]::Min($winH - 6, 14)
        $menuW = Get-UiDialogWidth $winW 56 50 $title $help -dialogHeight $menuH
        $x0    = Get-UiCenteredStart $winW $menuW
        $y0    = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $selected = 0

        function _IsSelectableIndex([int]$idx) {
            if ($idx -lt 0 -or $idx -ge $items.Count) { return $false }
            $k = $items[$idx].Kind
            if ($k -eq "translit" -and $script:AsciiSafeEnabled) { return $false }
            return $true
        }

        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = $script:BaseBg

            $listH = $menuH - 5
            for ($i = 0; $i -lt $listH; $i++) {
                $lineY = $y0 + 4 + $i
                $idx   = $i

                if ($idx -ge $items.Count) {
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition $x0 $lineY
                        [Console]::Write($UI_Frame_Vertical)
                        Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                        [Console]::Write($UI_Frame_Vertical)
                    }
                    With-ConsoleColor ($UI_Color_MenuLabel) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write((" " * ($menuW - 2)))
                    }
                    continue
                }

                $innerW = ($menuW - 4)

                function _Ellipsize-Middle([string]$s, [int]$maxLen) {
                    return (Truncate-UiTextMiddle $s $maxLen)
                }

                function _FormatMenuLine([string]$left, [string]$value) {
                    if ($null -eq $left)  { $left  = "" }
                    if ($null -eq $value) { $value = "" }

                    if ([string]::IsNullOrWhiteSpace($value)) {
                        $t = " " + $left
                        if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
                        return [pscustomobject]@{ Text = $t.PadRight($innerW); Value = ""; ValueStart = -1 }
                    }

                    $space    = 1
                    $rightPad = 1  # Keep 1 empty column to the right border (symmetry with left padding)

                    # Keep the label fully visible (with at least one space after it) by truncating the value first.
                    $maxValueLen = [Math]::Max(0, ($innerW - (1 + $left.Length) - $space - $rightPad))
                    if ($value.Length -gt $maxValueLen) {
                        $value = _Ellipsize-Middle $value $maxValueLen
                    }

                    $leftMax = [Math]::Max(0, ($innerW - $value.Length - $space - $rightPad))
                    if ($left.Length -gt $leftMax) {
                        $left = $left.Substring(0, $leftMax)
                    }

                    $valueStart = 1 + $leftMax + $space
                    $t = (" " + $left.PadRight($leftMax) + (" " * $space) + $value + (" " * $rightPad))

                    if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
                    return [pscustomobject]@{ Text = $t.PadRight($innerW); Value = $value; ValueStart = $valueStart }
                }

                $kind      = $items[$idx].Kind
                $leftText  = $items[$idx].Label
                $valueText = ""

                if ($kind -eq 'workdir') {
                    $wd = ""
                    try { $wd = "$($script:Settings.WorkDir)".Trim() } catch { }
                    if (-not $wd) {
                        try { $wd = (Split-Path -Parent $script:InFile) } catch { $wd = "" }
                    }
                    $valueText = "[" + $wd + "]"
                } elseif ($kind -eq 'prefix') {
                    $pc = ""
                    try { $pc = "$script:PrefixLanguageCode".Trim() } catch { }
                    if (-not $pc) { $pc = "--" }
                    $valueText = "[" + $pc + "]"
                } elseif ($kind -eq 'order') {
                    $valueText = '[' + (Get-ArtistTitleOrderDisplay) + ']'
                } elseif ($kind -eq 'connector') {
                    $connectorRaw = ''
                    try { $connectorRaw = Normalize-CustomTextSetting ([string]$script:Settings.ConnectorText) } catch { }
                    $valueText = $(if ($connectorRaw) { '[' + $connectorRaw + ']' } else { '[empty]' })
                } elseif ($kind -eq 'ascii') {
                    $leftText  = "ASCII-safe"
                    $valueText = $(if ($script:AsciiSafeEnabled) { "[ON]" } else { "[OFF]" })
                } elseif ($kind -eq 'translit') {
                    $leftText = "Transliteration EL/CYR"
                    if ($script:AsciiSafeEnabled) {
                        $valueText = "[ON*]"
                    } else {
                        $valueText = $(if ($script:TransliterationEnabled) { "[ON]" } else { "[OFF]" })
                    }
                } elseif ($kind -eq 'sep') {
                    $leftText  = "Playout delimiter"
                    $valueText = "[" + (Format-DelimiterForDisplay $global:SepGlyph) + "]"
                }

                $formatted    = _FormatMenuLine $leftText $valueText
                $text         = [string]$formatted.Text
                $shownValue   = [string]$formatted.Value
                $valueStart   = [int]$formatted.ValueStart
                $inner        = (" " + $text + " ")

                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY
                    [Console]::Write($UI_Frame_Vertical)
                }

                $isEnabled = $true
                if ($items[$idx].Kind -eq "translit" -and $script:AsciiSafeEnabled) { $isEnabled = $false }

                $itemFg = $(if ($isEnabled) { $UI_Color_MenuLabel } else { $UI_Color_MenuDisabled })
                if ($idx -eq $selected) {
                    # Always use the normal selected text color, even when disabled.
                    With-ConsoleColor $UI_Color_SelectedText $UI_Color_SelectedBack {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor $itemFg $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }

                    # Current settings are visually stronger than their active labels.
                    if ($isEnabled -and $valueStart -ge 0 -and -not [string]::IsNullOrEmpty($shownValue)) {
                        With-ConsoleColor $UI_Color_MenuValue $borderBg {
                            Set-UiCursorPosition ($x0 + 2 + $valueStart) $lineY
                            [Console]::Write($shownValue)
                        }
                    }
                }

                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                    [Console]::Write($UI_Frame_Vertical)
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { _DrawMenu } catch { }
                }
                continue
            }
            $k = Read-OverlayKey

            if ($k.Key -eq [ConsoleKey]::Escape) {
                # Cancel: restore original settings and re-apply runtime state.
                $script:Settings.Clear()
                foreach ($kk in $originalSettings.Keys) { $script:Settings[$kk] = $originalSettings[$kk] }
                Save-Settings

                Load-AsciiSafeSetting
                Load-TransliterationSetting
                Load-PrefixLanguageSetting
                Load-ArtistTitleOrderSetting
                Apply-PrefixFromLanguage
                Apply-DelimiterFromSettings
                Apply-WorkDirIfConfigured

                try { Refresh-UiAfterSettingChange } catch { }
                try { Draw-Header } catch { }

                return $false
            }
            if ($k.Key -eq [ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1); _DrawMenu; continue }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min($items.Count - 1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {

                if (-not (_IsSelectableIndex $selected)) {
                    try { [Console]::Beep(800,120) } catch { }
                    _DrawMenu
                    continue
                }

                $kind = $items[$selected].Kind
                if ($kind -eq 'exit') { return $anyChanged }

                $changed = $false

                if ($kind -eq 'workdir') {
                    $changed = Show-WorkDirMenu
                } elseif ($kind -eq 'prefix') {
                    $changed = Show-LanguageMenu
                } elseif ($kind -eq 'order') {
                    $newOrder = Show-ArtistTitleOrderMenu $script:ArtistTitleOrder
                    if ($null -ne $newOrder) {
                        $normalizedOrder = Normalize-ArtistTitleOrder ([string]$newOrder)
                        if ($normalizedOrder -ne (Normalize-ArtistTitleOrder $script:ArtistTitleOrder)) {
                            $script:ArtistTitleOrder = $normalizedOrder
                            Save-ArtistTitleOrderSetting
                            $changed = $true
                        }
                    }
                } elseif ($kind -eq 'connector') {
                    $initial = ''
                    try { $initial = [string]$script:Settings.ConnectorText } catch { }
                    $connector = Show-CustomTextEditor 'Connector text' 'Connector text:' $initial -outputPadding 2
                    if ($null -ne $connector) {
                        $normalizedConnector = Normalize-CustomTextSetting ([string]$connector)
                        $oldConnector = ''
                        try { $oldConnector = Normalize-CustomTextSetting ([string]$script:Settings.ConnectorText) } catch { }
                        if ($normalizedConnector -ne $oldConnector) {
                            $script:Settings.ConnectorText = $normalizedConnector
                            Save-Settings
                            $changed = $true
                        }
                    }
                } elseif ($kind -eq 'ascii') {
                    $newVal = Show-OnOffMenu "ASCII-safe" $script:AsciiSafeEnabled
                    if ($null -ne $newVal -and $newVal -ne $script:AsciiSafeEnabled) {
                        $changed = Toggle-AsciiSafe
                        if ($newVal -ne $script:AsciiSafeEnabled) { $changed = Toggle-AsciiSafe } # ensure exact state
                    }
                } elseif ($kind -eq 'translit') {
                    $newVal = Show-OnOffMenu "Transliteration EL/CYR" $script:TransliterationEnabled
                    if ($null -ne $newVal -and $newVal -ne $script:TransliterationEnabled) {
                        if ($script:AsciiSafeEnabled -and -not $newVal) {
                            $changed = $false
                        } else {
                            $changed = Toggle-Transliteration
                            if ($newVal -ne $script:TransliterationEnabled) { $changed = Toggle-Transliteration }
                        }
                    }
                } elseif ($kind -eq 'sep') {
                    $changed = Show-DelimiterMenu
                }

                if ($changed) { $anyChanged = $true }
                _DrawMenu
            }
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-WorkDirMenu([switch]$MarkWizardDone) {

    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $dialogToken            = $null
    $cancelled              = $false
    try {
        # Interactive working-directory picker (arrow keys + Enter).
        # Item 1 selects the current folder, item 2 goes to parent, remaining items enter subfolders.

        $winW  = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH  = Get-UiAvailableHeight 10
        $title = "Working directory"
        $help1 = "↑↓: move  Enter: open/select  V: volume  N: new folder  $UI_HelpCancel"
        $menuH = [Math]::Max(16, [Math]::Min(22, $winH - 4))
        $menuW = Get-UiDialogWidth $winW 88 68 $title $help1 -dialogHeight $menuH

        $x0 = Get-UiCenteredStart $winW $menuW
        $y0 = Get-UiCenteredStart $winH $menuH
        $dialogToken = Push-UiDialogGeometry $menuW $menuH $x0 $y0

        $listLines  = $null  # computed after infoLines is known
        $defaultDir = ''
        try { $defaultDir = (Split-Path -Parent $script:InFile) } catch { }
        if (-not $defaultDir) { $defaultDir = $AppBaseDir }

        # The picker must always browse from an existing directory. For a missing configured/default
        # path (for example C:\RDS), start at its nearest existing parent instead (normally C:\).
        $currentDir = ''
        $startCandidates = New-Object System.Collections.Generic.List[string]
        try {
            $configuredDir = "$($script:Settings.WorkDir)".Trim()
            if ($configuredDir) { [void]$startCandidates.Add($configuredDir) }
        } catch { }
        foreach ($candidate in @($defaultDir, $AppBaseDir)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { [void]$startCandidates.Add([string]$candidate) }
        }
        try {
            $locationPath = [string](Get-Location).Path
            if ($locationPath) { [void]$startCandidates.Add($locationPath) }
        } catch { }

        foreach ($startCandidate in $startCandidates) {
            $candidate = "$startCandidate".Trim()
            while ($candidate -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
                $parent = ''
                try { $parent = Split-Path -Path $candidate -Parent } catch { }
                if (-not $parent -or $parent -eq $candidate) { $candidate = ''; break }
                $candidate = $parent
            }
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                try { $candidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { }
                $currentDir = $candidate
                break
            }
        }

        if (-not $currentDir) { throw "No accessible directory available for the working-directory picker." }

        # Info area above the list: always show a single line with the folder currently under the cursor.
        $infoLines = 1
        # Calculate list height so the frame always uses the full menu height.
        # Layout: top(4) + infoLines + sep(1) + listLines + bottom(1) = menuH
        $listLines = [Math]::Max(6, ($menuH - 6 - $infoLines))
        $listTopY  = $y0 + 3 + $infoLines + 2
        # Title and actions share one header line; the following row is deliberately blank
        # to retain the existing list and overlay coordinates.
        $selectedIndex       = 0
        $listTop             = 0
        $lastRenderedTop     = $null
        $lastRenderedIndex   = $null
        $lastRenderedCount   = $null
        $lastRenderedVisible = $null
        $lastMsg             = ""
        $toastPending        = $false
        $itemsCacheDir       = $null
        $itemsCacheItems     = $null
        function _InvalidateItemsCache {
            Set-Variable -Name itemsCacheDir -Scope 1 -Value $null
            Set-Variable -Name itemsCacheItems -Scope 1 -Value $null
        }
        function _InvalidateListRenderState {
            Set-Variable -Name lastRenderedTop -Scope 1 -Value $null
            Set-Variable -Name lastRenderedIndex -Scope 1 -Value $null
            Set-Variable -Name lastRenderedCount -Scope 1 -Value $null
            Set-Variable -Name lastRenderedVisible -Scope 1 -Value $null
        }
        function _SetMsg([string]$m) {
            # NOTE: nested functions run in their own scope; update the parent variables explicitly.
            Set-Variable -Name lastMsg -Scope 1 -Value $m
            Set-Variable -Name toastPending -Scope 1 -Value (-not [string]::IsNullOrWhiteSpace($m))
            Set-Variable -Name needsRedraw  -Scope 1 -Value $true
        }

        function _FrameLine([string]$text) {
            return ($UI_Frame_Vertical + " " + $text.PadRight($menuW - 4).Substring(0, $menuW - 4) + " " + $UI_Frame_Vertical)
        }

        function _WriteFrameTextLine([int]$y, [string]$text, [ConsoleColor]$textColor, [switch]$ActionHints) {
            $innerW = $menuW - 4
            if ($ActionHints) {
                $t = Format-UiActionHints $text $innerW
            } else {
                $t = Truncate-UiText $text $innerW
                $t = $t.PadRight($innerW)
            }

            # Left border + space
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $x0 $y
                [Console]::Write($UI_Frame_Vertical + " ")
            }

            # Text (dim)
            With-ConsoleColor $textColor ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + 2) $y
                [Console]::Write($t)
            }

            # Space + right border
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + $menuW - 2) $y
                [Console]::Write(" " + $UI_Frame_Vertical)
            }
        }

        function _DrawFrame([string]$CurrentFolder) {
            Write-At $x0 $y0 ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)
            _WriteFrameTextLine ($y0 + 1) "" ($UI_Color_DimText)
            Write-UiHeaderContent ($x0 + 2) ($y0 + 1) ($menuW - 4) $title $help1
            _WriteFrameTextLine ($y0 + 2) "" ($UI_Color_DimText)
            Write-At $x0 ($y0 + 3) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

            function _WriteInfoLine([int]$y, [string]$label, [string]$value) {
                $innerW    = $menuW - 4
                $labelText = ($label + " ")
                $v         = $value

                # If this line ends with the informational suffix, render that suffix dim (and keep it intact
                # when truncating the path).
                $suffix = ""
                if ($v -and $v.EndsWith(" (will be created)")) {
                    $suffix = " (will be created)"
                    $v      = $v.Substring(0, $v.Length - $suffix.Length)
                }

                $maxValueLen = [Math]::Max(0, $innerW - $labelText.Length - $suffix.Length)
                if ($v.Length -gt $maxValueLen) {
                    $v = Truncate-UiText $v $maxValueLen
                }

                # Left border
                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $x0 $y
                    [Console]::Write($UI_Frame_Vertical + " ")
                }

                # Label (active menu label)
                With-ConsoleColor ($UI_Color_MenuLabel) ($UI_Color_Background) {
                    Set-UiCursorPosition ($x0 + 2) $y
                    [Console]::Write($labelText)
                }

                # Value (current setting)
                With-ConsoleColor ($UI_Color_MenuValue) ($UI_Color_Background) {
                    Set-UiCursorPosition ($x0 + 2 + $labelText.Length) $y
                    [Console]::Write($v)
                }

                # Suffix (dim)
                if ($suffix) {
                    With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                        Set-UiCursorPosition ($x0 + 2 + $labelText.Length + $v.Length) $y
                        [Console]::Write($suffix)
                    }
                }

                # Fill remainder + right border
                $written = $labelText.Length + $v.Length + $suffix.Length
                $pad     = [Math]::Max(0, $innerW - $written)
                With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($x0 + 2 + $written) $y
                    [Console]::Write((" " * $pad))
                }
                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition ($x0 + $menuW - 2) $y
                    [Console]::Write(" " + $UI_Frame_Vertical)
                }
            }

            # Info line (always present): show the folder path that we are currently browsing.
            _WriteInfoLine ($y0 + 4) "Current folder:" $CurrentFolder

            Write-At $x0 ($listTopY - 1) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

            # List area
            for ($i = 0; $i -lt $listLines; $i++) {
                Write-At $x0 ($listTopY + $i) (_FrameLine "") ($UI_Color_MenuFrame)
            }

            Write-At $x0 ($listTopY + $listLines) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
        }

        function _GetSelectPathDisplay([string]$path) {
            try {
                if ([string]::IsNullOrWhiteSpace($path)) { return $path }

                $p = "$path".Trim()

                # Ensure root paths are displayed with a trailing backslash (e.g. "C:\")
                if (-not $p.EndsWith('\')) {
                    if ($p -match '^[A-Za-z]:$') {
                        return ($p + '\')
                    }
                    # UNC share root (\\server\share)
                    if ($p -match '^\\\\[^\\]+\\[^\\]+$') {
                        return ($p + '\')
                    }
                }

                return $p
            } catch {
                return $path
            }
        }

        function _GetItems {
            if (($null -ne $itemsCacheItems) -and ($itemsCacheDir -eq $currentDir)) {
                return ,$itemsCacheItems
            }

            $items = New-Object System.Collections.Generic.List[string]

            # Virtual helper entry (first item when shown):
            # If the configured folder from settings does not exist anymore) offer that path for explicit creation.
            # Otherwise (first-run, offer creation of the default folder (derived from the input file location).

            # Build a drive-aware default folder suggestion:
            # If the user navigated to another volume, offer "\<defaultSubPath>" on that volume (e.g. D:\RDS),
            # instead of always offering the original defaultDir (often C:\RDS).
            $defaultCreateDir = $defaultDir
            try {
                $root = [System.IO.Path]::GetPathRoot($currentDir)
                if (-not [string]::IsNullOrWhiteSpace($root)) {
                    # Always suggest the canonical default folder name on the selected volume (e.g. D:\RDS).
                    $defaultCreateDir = Join-Path $root "RDS"

                }
            } catch { }

            $createTarget = $null
            try {
                $cfg = "$($script:Settings.WorkDir)".Trim()
                if ($cfg -and -not (Test-Path -LiteralPath $cfg)) { $createTarget = $cfg }
            } catch { }

            if (-not $createTarget) {
                try { if (-not (Test-Path -LiteralPath $defaultCreateDir)) { $createTarget = $defaultCreateDir } } catch { }
            }

            if ($createTarget) {
                if ($createTarget -eq $defaultCreateDir) {
                    [void]$items.Add("[Create default folder: $createTarget]")
                } else {
                    [void]$items.Add("[Create folder: $createTarget]")
                }
            }

            # Selection is valid only for an existing directory; creation remains an explicit action.
            if (Test-Path -LiteralPath $currentDir -PathType Container) {
                [void]$items.Add(("[Select {0}]" -f (_GetSelectPathDisplay $currentDir)))
            }

            $parentPath = $null
            try { $parentPath = Split-Path -Path $currentDir -Parent } catch { $parentPath = $null }
            if (-not [string]::IsNullOrWhiteSpace($parentPath) -and ($parentPath -ne $currentDir) -and (Test-Path -LiteralPath $parentPath)) {
                [void]$items.Add("..  (Parent)")
            }

            $dirs = @()
            try {
                $dirs = Get-ChildItem -LiteralPath $currentDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
            } catch { $dirs = @() }

            foreach ($d in $dirs) {
                # keep only the leaf name in the list
                [void]$items.Add($d.Name)
            }
            Set-Variable -Name itemsCacheDir -Scope 1 -Value $currentDir
            Set-Variable -Name itemsCacheItems -Scope 1 -Value $items
            return ,$items
        }

        function _IsDirWritable([string]$path) {
            try {
                if ([string]::IsNullOrWhiteSpace($path)) { return $false }
                if (-not (Test-Path -LiteralPath $path)) { return $false }

                $name = [System.IO.Path]::GetRandomFileName()
                $tmp  = Join-Path $path (".__writetest_" + $name)

                # Create with CreateNew to avoid clobbering anything.
                $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $fs.Close()
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
                return $true
            } catch {
                try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null } } catch { }
                return $false
            }
        }

        function _ShowToast([string]$message) {
            if ([string]::IsNullOrWhiteSpace($message)) { return }

            $msg = $message.Trim()
            while ($msg.EndsWith(".")) { $msg = $msg.Substring(0, $msg.Length - 1).TrimEnd() }
            $maxW = [Math]::Max(24, [Math]::Min($menuW - 8, 72))
            $msg = Truncate-UiText $msg ([Math]::Max(0, $maxW - 6))

            $boxW = [Math]::Min($maxW, ($msg.Length + 6))
            $boxH = 3
            $bx   = $x0 + [int](($menuW - $boxW) / 2)
            $by   = $y0 + [int](($menuH - $boxH) / 2)
            if ($by -lt ($y0 + 4)) { $by = $y0 + 4 }

            # Border
            Write-At $bx $by       ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)
            Write-At $bx ($by + 2) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)

            # Message line (white, centered within the box)
            $inner = (" " + $msg.PadRight($boxW - 4) + " ")

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $bx ($by + 1)
                [Console]::Write($UI_Frame_Vertical)
            }

            With-ConsoleColor ($UI_Color_BrightText) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + 1) ($by + 1)
                [Console]::Write($inner)
            }

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + $boxW - 1) ($by + 1)
                [Console]::Write($UI_Frame_Vertical)
            }

            Start-Sleep -Milliseconds $UI_ToastDurationMs

            # Let the outer WorkDir loop redraw the menu. Calling _DrawList from inside this nested
            # function changes the meaning of its -Scope 1 state lookups and can produce errors such as
            # "Cannot find a variable with the name 'listTop'" after showing a validation toast.
            $script:OverlayNeedsRedraw = $true
        }

        function _DrawListRow([System.Collections.Generic.List[string]]$items, [int]$top, [int]$row) {
            $innerW = $menuW - 4
            $idx    = $top + $row
            $text   = ""
            if (($idx -ge 0) -and ($idx -lt $items.Count)) { $text = $items[$idx] }

            if ($text.Length -gt $innerW) { $text = Truncate-UiText $text $innerW }
            $line = $text.PadRight($innerW)

            $fg = $UI_Color_MenuLabel
            $bg = $UI_Color_Background
            if ($idx -eq $selectedIndex) {
                $fg = $UI_Color_SelectedText
                $bg = $UI_Color_SelectedBack
            }

            With-ConsoleColor $fg $bg {
                Set-UiCursorPosition ($x0 + 2) ($listTopY + $row)
                [Console]::Write($line)
            }
        }

        function _DrawList([System.Collections.Generic.List[string]]$items) {
            $visible = $listLines

            if ($selectedIndex -lt 0) { $selectedIndex = 0 }
            if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }

            $maxTop = [Math]::Max(0, $items.Count - $visible)
            $top = 0
            try { $top = [int](Get-Variable -Name listTop -Scope 1 -ValueOnly) } catch { $top = 0 }

            if ($top -lt 0) { $top = 0 }
            if ($top -gt $maxTop) { $top = $maxTop }

            if ($selectedIndex -lt $top) {
                $top = $selectedIndex
            } elseif ($selectedIndex -ge ($top + $visible)) {
                $top = $selectedIndex - ($visible - 1)
            }

            if ($top -lt 0) { $top = 0 }
            if ($top -gt $maxTop) { $top = $maxTop }
            Set-Variable -Name listTop -Scope 1 -Value $top

            $oldTop     = $null
            $oldIndex   = $null
            $oldCount   = $null
            $oldVisible = $null
            try { $oldTop     = Get-Variable -Name lastRenderedTop -Scope 1 -ValueOnly } catch { }
            try { $oldIndex   = Get-Variable -Name lastRenderedIndex -Scope 1 -ValueOnly } catch { }
            try { $oldCount   = Get-Variable -Name lastRenderedCount -Scope 1 -ValueOnly } catch { }
            try { $oldVisible = Get-Variable -Name lastRenderedVisible -Scope 1 -ValueOnly } catch { }

            $fullDraw = ($null -eq $oldTop) -or ($oldTop -ne $top) -or ($oldCount -ne $items.Count) -or ($oldVisible -ne $visible)

            if ($fullDraw) {
                for ($row = 0; $row -lt $visible; $row++) {
                    _DrawListRow $items $top $row
                }
            } elseif ($oldIndex -ne $selectedIndex) {
                $oldRow = [int]$oldIndex - $top
                $newRow = [int]$selectedIndex - $top

                if (($oldRow -ge 0) -and ($oldRow -lt $visible)) { _DrawListRow $items $top $oldRow }
                if (($newRow -ge 0) -and ($newRow -lt $visible) -and ($newRow -ne $oldRow)) { _DrawListRow $items $top $newRow }
            }

            Set-Variable -Name lastRenderedTop -Scope 1 -Value $top
            Set-Variable -Name lastRenderedIndex -Scope 1 -Value $selectedIndex
            Set-Variable -Name lastRenderedCount -Scope 1 -Value $items.Count
            Set-Variable -Name lastRenderedVisible -Scope 1 -Value $visible

            if ($toastPending -and -not [string]::IsNullOrEmpty($lastMsg)) {
                $m = $lastMsg

                # NOTE: nested functions have their own scope; clear the parent variables explicitly
                # so the toast cannot be re-triggered by subsequent redraws (e.g. on Up/Down).
                Set-Variable -Name lastMsg -Scope 1 -Value ""
                Set-Variable -Name toastPending -Scope 1 -Value $false

                _ShowToast $m
            }
        }

        function _PromptNewFolderName {
            # Modal overlay input box.
            # Returns the entered folder name, or $null when cancelled (Esc) / empty (Enter).
            $boxW = [Math]::Min(60, [Math]::Max(38, $menuW - 10))
            $boxH = 5
            $bx   = $x0 + [int](($menuW - $boxW) / 2)
            $by   = $y0 + [int](($menuH - $boxH) / 2)

            $prompt    = "Name: "
            $buf       = ""
            $position  = 0
            $selectAll = $false

            function _DrawInputBox {
                Write-At $bx $by       ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)

                $innerWHeader = $boxW - 4
                $headerTitle  = "Create new folder"
                $headerHelp   = "Enter: create$UI_HelpSegmentSeparator$UI_HelpCancel"

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 1); [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 1); [Console]::Write(" " + $UI_Frame_Vertical)
                }
                Write-UiHeaderContent ($bx + 2) ($by + 1) $innerWHeader $headerTitle $headerHelp

                Write-At $bx ($by + 2) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

                $innerW = $boxW - 4
                $fieldW = [Math]::Max(1, $innerW - $prompt.Length)
                $pos    = [Math]::Max(0, [Math]::Min($buf.Length, [int]$position))
                $start  = 0
                if (($pos - $start) -ge $fieldW) { $start = $pos - $fieldW + 1 }
                if ($start -gt $buf.Length) { $start = $buf.Length }
                $take   = [Math]::Min($fieldW, [Math]::Max(0, $buf.Length - $start))
                $shown  = $(if ($take -gt 0) { $buf.Substring($start, $take) } else { "" })
                $shown  = $shown.PadRight($fieldW)

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 3); [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 3); [Console]::Write(" " + $UI_Frame_Vertical)
                }
                With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 3); [Console]::Write($prompt)
                }

                $fieldX = $bx + 2 + $prompt.Length
                if ($selectAll -and $buf.Length -gt 0) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition $fieldX ($by + 3); [Console]::Write($shown)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                        Set-UiCursorPosition $fieldX ($by + 3); [Console]::Write($shown)
                    }
                }

                Write-At $bx ($by + 4) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)

                if (-not $selectAll) {
                    $cursorX = $fieldX + ($pos - $start)
                    if ($cursorX -ge ($bx + $boxW - 2)) { $cursorX = $bx + $boxW - 3 }
                    Set-UiInputCursor $cursorX ($by + 3)
                } else {
                    try { [Console]::CursorVisible = $false } catch { }
                }
            }

            try {
                while ($true) {
                    _DrawInputBox
                    $k = Read-TextEditorKey

                    if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
                    if ($k.Key -eq [ConsoleKey]::Enter) {
                        $name = $buf.Trim()
                        if (-not $name) { return $null }
                        return $name
                    }

                    $pos = [Math]::Max(0, [Math]::Min($buf.Length, [int]$position))

                    if ($k.Key -eq [ConsoleKey]::Home) {
                        $selectAll = $false
                        $position  = 0
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::End) {
                        $selectAll = $false
                        $position  = $buf.Length
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::LeftArrow) {
                        if ($selectAll) { $position = 0 } else { $position = [Math]::Max(0, $pos - 1) }
                        $selectAll = $false
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::RightArrow) {
                        if ($selectAll) { $position = $buf.Length } else { $position = [Math]::Min($buf.Length, $pos + 1) }
                        $selectAll = $false
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::Backspace) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                        } elseif ($pos -gt 0) {
                            $buf      = $buf.Remove($pos - 1, 1)
                            $position = $pos - 1
                        }
                        continue
                    }
                    if ($k.Key -eq [ConsoleKey]::Delete) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                        } elseif ($pos -lt $buf.Length) {
                            $buf = $buf.Remove($pos, 1)
                        }
                        continue
                    }

                    if ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                        if ($selectAll) {
                            $buf       = ""
                            $position  = 0
                            $selectAll = $false
                            $pos       = 0
                        }
                        $buf      = $buf.Insert($pos, [string]$k.KeyChar)
                        $position = $pos + 1
                    }
                }
            } finally {
                try { [Console]::CursorVisible = $false } catch { }
            }
        }
        function _PromptSelectVolume {
            # Modal overlay volume picker.
            # Returns the selected drive root (e.g. "D:\"), or $null when cancelled.

            $drives = @()
            try {
                foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                    try {
                        if (-not $d.IsReady) { continue }
                        $root = $d.RootDirectory.FullName
                        if ([string]::IsNullOrWhiteSpace($root)) { continue }

                        $type = ""
                        try { $type = [string]$d.DriveType } catch { $type = "" }
                        $label = ""
                        try { $label = [string]$d.VolumeLabel } catch { $label = "" }

                        $display = $root
                        if (-not [string]::IsNullOrWhiteSpace($label)) {
                            $display = ("{0} ({1})" -f $root, $label)
                        } elseif (-not [string]::IsNullOrWhiteSpace($type)) {
                            $display = ("{0} ({1})" -f $root, $type)
                        }

                        $drives += [pscustomobject]@{ Root = $root; Display = $display }
                    } catch { }
                }
            } catch { $drives = @() }

            if ($drives.Count -le 0) {
                _SetMsg "No volumes found"
                return $null
            }

            $maxVisible = 10
            $listCount  = [Math]::Min($maxVisible, $drives.Count)

            $boxW = [Math]::Min(62, [Math]::Max(42, $menuW - 14))
            $boxH = 8 + $listCount  # top, title/help, sep, list, bottom

            $bx = $x0 + [int](($menuW - $boxW) / 2)
            $by = $y0 + [int](($menuH - $boxH) / 2)
            if ($by -lt ($y0 + 3)) { $by = $y0 + 3 }

            $sel = 0
            $top = 0

            function _DrawVolBox {
                Write-At $bx $by       ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)

                $innerW    = $boxW - 4
                $titleLine = "Select volume"
                $helpLine  = "Up/Down: move   Enter: select   $UI_HelpCancel"

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 1)
                    [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 1)
                    [Console]::Write(" " + $UI_Frame_Vertical)

                    Set-UiCursorPosition $bx ($by + 2)
                    [Console]::Write($UI_Frame_Vertical + " ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 2)
                    [Console]::Write(" " + $UI_Frame_Vertical)
                }
                Write-UiHeaderContent ($bx + 2) ($by + 1) $innerW $titleLine $helpLine
                Write-At ($bx + 2) ($by + 2) (" " * $innerW) $UI_Color_DimText

                Write-At $bx ($by + 3) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)

                # List
                $innerWList = $boxW - 4
                for ($i = 0; $i -lt $listCount; $i++) {
                    $idx  = $top + $i
                    $text = ""
                    if ($idx -lt $drives.Count) { $text = [string]$drives[$idx].Display }
                    if ($text.Length -gt $innerWList) { $text = Truncate-UiText $text $innerWList }
                    $line = $text.PadRight($innerWList)

                    $fg = $UI_Color_InputText
                    $bg = $UI_Color_Background
                    if ($idx -eq $sel) {
                        $fg = $UI_Color_SelectedText
                        $bg = $UI_Color_SelectedBack
                    }

                    With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                        Set-UiCursorPosition $bx ($by + 4 + $i)
                        [Console]::Write($UI_Frame_Vertical + " ")
                    }
                    With-ConsoleColor $fg $bg {
                        Set-UiCursorPosition ($bx + 2) ($by + 4 + $i)
                        [Console]::Write($line)
                    }
                    With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                        Set-UiCursorPosition ($bx + $boxW - 2) ($by + 4 + $i)
                        [Console]::Write(" " + $UI_Frame_Vertical)
                    }
                }

                Write-At $bx ($by + 4 + $listCount) ($UI_Frame_BottomLeft + ($UI_Frame_Horizontal * ($boxW - 2)) + $UI_Frame_BottomRight) ($UI_Color_MenuFrame)
            }

            _DrawVolBox

            while ($true) {
                if (-not [Console]::KeyAvailable) {
                    Start-Sleep -Milliseconds $UI_ShortSleepMs
                    Invoke-MenuIdleTick
                    if ($script:OverlayNeedsRedraw) {
                        $script:OverlayNeedsRedraw = $false
                        try { [Console]::CursorVisible = $false } catch { }
                        try { _DrawVolBox } catch { }
                    }
                    continue
                }
                $k = Read-OverlayKey

                if ($k.Key -eq [ConsoleKey]::Escape) { return $null }

                if ($k.Key -eq [ConsoleKey]::UpArrow) {
                    $sel--
                    if ($sel -lt 0) { $sel = 0 }
                    if ($sel -lt $top) { $top = $sel }
                    _DrawVolBox
                    continue
                }

                if ($k.Key -eq [ConsoleKey]::DownArrow) {
                    $sel++
                    if ($sel -gt ($drives.Count - 1)) { $sel = [Math]::Max(0, $drives.Count - 1) }
                    if ($sel -ge ($top + $listCount)) { $top = $sel - ($listCount - 1) }
                    if ($top -lt 0) { $top = 0 }
                    if ($top -gt [Math]::Max(0, $drives.Count - $listCount)) { $top = [Math]::Max(0, $drives.Count - $listCount) }
                    _DrawVolBox
                    continue
                }

                if ($k.Key -eq [ConsoleKey]::Enter) {
                    if ($drives.Count -le 0) { return $null }
                    $root = [string]$drives[$sel].Root
                    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
                    if (-not (Test-Path -LiteralPath $root)) { return $null }
                    try { $root = (Resolve-Path -LiteralPath $root -ErrorAction Stop).Path } catch { }
                    return $root
                }
            }
        }
        function _GetCursorFolderDisplay($items, [int]$idx) {
            try {
                if ($null -eq $items -or $items.Count -le 0) {
                    return $currentDir
                }

                if ($idx -lt 0) { $idx = 0 }
                if ($idx -gt ($items.Count - 1)) { $idx = $items.Count - 1 }

                $choice = $items[$idx]

                if ($choice -match '^\[Select\s+.*\]$') {
                    # Cursor is on the "select current directory" entry
                    return $currentDir
                }

                if ($choice -match '^\[Create .*folder:\s*(.+)\]$') {
                    # Cursor is on the virtual "Create ..." entry: keep showing the real current directory.
                    return $currentDir
                }

                if ($choice -like "..*") {
                    try { return (Split-Path -Path $currentDir -Parent) } catch { return $currentDir }
                }

                # Regular directory entry
                return (Join-Path $currentDir $choice)
            } catch {
                return $currentDir
            }
        }

        $items        = _GetItems
        $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex

        $needsRedraw      = $true
        $frameNeedsRedraw = $true

        while ($true) {

            if ($needsRedraw) {
                $items = _GetItems
                if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }
                if ($selectedIndex -lt 0) { $selectedIndex = 0 }

                $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex
                if ($frameNeedsRedraw) {
                    _DrawFrame $currentDir
                    _InvalidateListRenderState
                    $frameNeedsRedraw = $false
                }
                _DrawList $items

                $needsRedraw = $false
            }

            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds $UI_ShortSleepMs
                Invoke-MenuIdleTick
                if ($script:OverlayNeedsRedraw) {
                    $script:OverlayNeedsRedraw = $false
                    try { [Console]::CursorVisible = $false } catch { }
                    try { $items = _GetItems; $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex; _DrawFrame $currentDir; _InvalidateListRenderState; _DrawList $items } catch { }
                }
                continue
            }
            $k = Read-OverlayKey

            if ($k.Key -eq [ConsoleKey]::Escape) {
                # $null distinguishes cancellation from selecting the already-configured directory ($false).
                $cancelled = $true
                return $null
            }

            if ($k.Key -eq [ConsoleKey]::UpArrow) {
                $selectedIndex--
                if ($selectedIndex -lt 0) { $selectedIndex = 0 }
                $needsRedraw = $true
                continue
            }

            if ($k.Key -eq [ConsoleKey]::DownArrow) {
                $selectedIndex++
                if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }
                $needsRedraw = $true
                continue
            }

            if ($k.Key -eq [ConsoleKey]::V) {

                $root = _PromptSelectVolume
                if (-not [string]::IsNullOrWhiteSpace($root)) {
                    $currentDir    = $root
                    _InvalidateItemsCache
                    $selectedIndex = 0
                    $listTop       = 0
                    $lastMsg       = ""
                    $toastPending  = $false
                    $frameNeedsRedraw = $true
                }

                # Always redraw after closing the modal overlay (also on cancel),
                # otherwise the overlay remains visually on screen until the next repaint.
                $frameNeedsRedraw = $true
                $needsRedraw = $true
                continue
            }

            if ($k.Key -eq [ConsoleKey]::N) {

                $name = _PromptNewFolderName
                if ($null -eq $name) { $lastMsg = ""; $toastPending = $false; $frameNeedsRedraw = $true; $needsRedraw = $true; continue }

                # Validate folder name (Windows rules)
                $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
                if ($name.IndexOfAny($invalidChars) -ge 0) {
                    _SetMsg "Invalid folder name"
                    continue
                }
                if ($name -match '^\.+$') {
                    _SetMsg "Invalid folder name"
                    continue
                }

                $target = Join-Path $currentDir $name

                if (Test-Path -LiteralPath $target) {
                    _SetMsg "Folder already exists"
                    continue
                }

                try {
                    New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
                    try { $target = (Resolve-Path -LiteralPath $target -ErrorAction Stop).Path } catch { }
                    $currentDir    = $target
                    _InvalidateItemsCache
                    $selectedIndex = 0
                    $listTop       = 0
                    _SetMsg "Folder created"
                    $frameNeedsRedraw = $true
                    $needsRedraw = $true
                } catch {
                    _SetMsg "Unable to create folder"
                }

                continue
            }

            if ($k.Key -eq [ConsoleKey]::Enter) {

                if ($items.Count -le 0) { continue }

                $choice = $items[$selectedIndex]

                if ($choice -match '^\[Create\s+.*folder:\s*.+\]$') {

                    $picked = $null
                    try {
                        $p      = $choice.Trim().TrimStart('[').TrimEnd(']')
                        $picked = ($p -split "folder:\s*", 2)[1].Trim()
                    } catch { $picked = $null }

                    if ([string]::IsNullOrWhiteSpace($picked)) {
                        _SetMsg "Invalid folder"
                        continue
                    }

                    # Explicit action: try to create the selected folder.
                    if (-not (Test-Path -LiteralPath $picked)) {
                        try {
                            New-Item -ItemType Directory -Path $picked -Force -ErrorAction Stop | Out-Null
                        } catch {
                            _SetMsg "Unable to create folder"
                            continue
                        }
                    }

                    try { $picked = (Resolve-Path -LiteralPath $picked -ErrorAction Stop).Path } catch { }

                    if (-not (_IsDirWritable $picked)) {
                        _SetMsg "Folder not writable"
                        continue
                    }

                    $changed = ("$($script:Settings.WorkDir)".Trim() -ne $picked)

                    $script:Settings.WorkDir = $picked
                    if ($MarkWizardDone) { $script:Settings.WorkDirWizardDone = $true }
                    Save-Settings

                    return $changed
                }

                if ($choice -match '^\[Select\s+.*\]$') {

                    $picked = $currentDir
                    if (-not $picked) { $picked = $defaultDir }
                    if (-not (Test-Path -LiteralPath $picked)) {
                        # Do not create directories implicitly. Creation must be an explicit action via the
                        # dedicated "[Create ... folder: ...]" entry in the list.
                        _SetMsg "Folder does not exist"
                        continue
                    }

                    try { $picked = (Resolve-Path -LiteralPath $picked -ErrorAction Stop).Path } catch { }

                    if (-not (_IsDirWritable $picked)) {
                        _SetMsg "Folder not writable"
                        continue
                    }

                    $changed = ("$($script:Settings.WorkDir)".Trim() -ne $picked)

                    $script:Settings.WorkDir = $picked
                    if ($MarkWizardDone) { $script:Settings.WorkDirWizardDone = $true }
                    Save-Settings

                    return $changed
                }

                if ($choice -like "..*") {
                    try {
                        $parentPath = $null
                        try { $parentPath = Split-Path -Path $currentDir -Parent } catch { $parentPath = $null }
                        if (-not [string]::IsNullOrWhiteSpace($parentPath) -and ($parentPath -ne $currentDir) -and (Test-Path -LiteralPath $parentPath)) {
                            $currentDir    = $parentPath
                            _InvalidateItemsCache
                            $selectedIndex = 0
                            $listTop       = 0
                            $lastMsg       = ""
                            $frameNeedsRedraw = $true
                            $needsRedraw   = $true
                        }
                    } catch {
                        _SetMsg "Unable to open parent folder"
                    }
                    continue
                }

                # Enter a child directory
                $target = Join-Path $currentDir $choice
                if (Test-Path -LiteralPath $target) {
                    try { $target = (Resolve-Path -LiteralPath $target -ErrorAction Stop).Path } catch { }
                    $currentDir    = $target
                    _InvalidateItemsCache
                    $selectedIndex = 0
                    $listTop       = 0
                    $lastMsg       = ""
                    $frameNeedsRedraw = $true
                    $needsRedraw   = $true
                } else {
                    _SetMsg "Folder not found"
                }
                continue
            }
        }
    } finally {
        Pop-UiDialogGeometry $dialogToken
        $script:UiOverlayActive = $prevOverlay
        # A cancelled required startup wizard has no valid underlay to restore. In all other cases,
        # clear the picker footprint and redraw the UI exactly as before.
        if (-not ($MarkWizardDone -and $cancelled)) {
            try { Restore-UiAfterMenu $y0 $menuH } catch { }
        }
    }
}

function Restore-UiAfterMenu([int]$menuTop, [int]$menuHeight) {
    # Clear only the area that was covered by the overlay menu, then redraw the underlying UI sections
    # that can be affected. This avoids a full Clear-Host redraw when leaving the menu via ESC.
    # While an overlay menu is active, Ensure-UiFresh() early-returns. Submenus can still clear parts
    # of the underlying UI (e.g. the heartbeat/legend rows), so temporarily drop the overlay flag
    # while restoring the underlay.
    $prevOverlay            = $script:UiOverlayActive
    $script:UiOverlayActive = $false
    try { Ensure-UiFresh } catch { }

    try {
        $yStart = [Math]::Max(0, $menuTop)
        $yEnd   = [Math]::Max($yStart, $menuTop + $menuHeight - 1)

        for ($y = $yStart; $y -le $yEnd; $y++) {
            Write-At 0 $y "" $script:BaseFg $true
        }

        # If the menu overlaps the header, redraw it completely. Otherwise refresh the
        # FILES rows so write-failure markers changed during the overlay are not left stale.
        if ($yStart -lt $script:StatusTop) {
            try { Draw-Header } catch { }
        } else {
            try { Write-HeaderFileRows } catch { }
        }

        try { Draw-StatusFrame } catch { }
        try { Write-LiveOutputRows } catch { }

        $heartbeatRow    = $script:StatusTop + 9
        $settingsTop     = $script:StatusTop + 10
        $settingsBottom  = $script:StatusTop + 12
        $heartbeatCovered = ($heartbeatRow -ge $yStart -and $heartbeatRow -le $yEnd)
        $settingsCovered  = ($yEnd -ge $settingsTop -and $yStart -le $settingsBottom)

        if ($heartbeatCovered) {
            # The row was hidden and must be reconstructed. Its value is calculated directly from
            # LastGoodUpdate, not from an independently accumulated display state.
            $script:HeartbeatLayoutValid = $false
            try { Ensure-HeartbeatLayout } catch { }
        } elseif ($settingsCovered) {
            # Restore only the footer rows; keep the already-visible heartbeat and its render cache intact.
            try { Render-SettingsAndLegend } catch { }
        }

        try { Update-HeartbeatBar } catch { }
    } finally {
        $script:UiOverlayActive = $prevOverlay
    }
}

function Test-HeartbeatRowVisibleDuringOverlay {
    # The heartbeat spans the full UI width, so any active dialog touching its row must block the redraw.
    # Check the complete stack: a small child dialog may leave the row clear while its parent still covers it.
    if (-not $script:UiOverlayActive) { return $true }
    if (-not $script:UiInited -or -not $script:HeartbeatLayoutValid) { return $false }
    if ($null -eq $script:UiDialogStack -or $script:UiDialogStack.Count -le 0) { return $false }

    $heartbeatRow = $script:StatusTop + 9
    foreach ($dialog in $script:UiDialogStack) {
        try {
            $top    = [int]$dialog.Y
            $height = [Math]::Max(0, [int]$dialog.Height)
            $bottom = $top + $height - 1
            if ($height -gt 0 -and $heartbeatRow -ge $top -and $heartbeatRow -le $bottom) { return $false }
        } catch { return $false }
    }

    return $true
}

function Update-HeartbeatDuringOverlayIfVisible {
    if (-not (Test-HeartbeatRowVisibleDuringOverlay)) { return }

    # Preserve a text editor's live input cursor; ordinary menus normally keep it hidden.
    $cursorLeft              = 0
    $cursorTop               = 0
    $cursorVisible           = $false
    $cursorPositionCaptured  = $false
    $cursorVisibilityCaptured = $false
    try {
        $cursorLeft             = [Console]::CursorLeft
        $cursorTop              = [Console]::CursorTop
        $cursorPositionCaptured = $true
    } catch { }
    try {
        $cursorVisible            = [Console]::CursorVisible
        $cursorVisibilityCaptured = $true
    } catch { }

    try {
        Update-HeartbeatFields
    } finally {
        if ($cursorPositionCaptured) {
            try { [Console]::SetCursorPosition($cursorLeft, $cursorTop) } catch { }
        }
        if ($cursorVisibilityCaptured) {
            try { [Console]::CursorVisible = $cursorVisible } catch { }
        }
    }
}

function Set-NextHeartbeatElapsedRender([int]$ActualAgeSec) {
    # Anchor redraw scheduling directly to LastGoodUpdate. The display therefore cannot accumulate
    # a separate lag or perform a catch-up jump when a menu closes.
    $script:NextHeartbeatElapsedRenderUtc = $script:LastGoodUpdate.ToUniversalTime().AddSeconds([Math]::Max(0, $ActualAgeSec) + 1)
}

function Get-HeartbeatSleepMilliseconds([int]$MaximumMs) {
    $maximum = [Math]::Max(1, $MaximumMs)
    $nextUtc = $script:NextHeartbeatElapsedRenderUtc

    if ($null -eq $nextUtc -or $nextUtc -eq [DateTime]::MinValue) { return $maximum }

    $remainingMs = ($nextUtc - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMs -le 1) { return 1 }

    return [int][Math]::Max(1, [Math]::Min($maximum, [Math]::Ceiling($remainingMs)))
}

function Wait-WithHeartbeat([int]$Milliseconds) {
    # Keep the elapsed-time display responsive during deliberate short waits in the single-threaded
    # input path. This does not process watcher events or run maintenance recursively.
    $remainingMs = [Math]::Max(0, $Milliseconds)

    while ($remainingMs -gt 0) {
        $maximumSleepMs = [Math]::Min($PollIntervalMs, $remainingMs)
        $sleepMs        = Get-HeartbeatSleepMilliseconds $maximumSleepMs
        Start-Sleep -Milliseconds $sleepMs
        $remainingMs -= $sleepMs

        try {
            if ($script:UiOverlayActive) {
                Update-HeartbeatDuringOverlayIfVisible
            } elseif ($script:UiInited -and $script:HeartbeatLayoutValid) {
                Update-HeartbeatFields
            }
        } catch { }
    }
}

function Invoke-MenuIdleTick {
    # Keep file watching, output publishing and failed-output retries active while an overlay menu is open.
    # The heartbeat may also keep running when every active dialog leaves its row fully uncovered.
    try { Do-UpdateIfNeeded } catch { }
    try { [void](Retry-PendingOutputsIfDue) } catch { }
    try { Update-HeartbeatDuringOverlayIfVisible } catch { }

    try {
        if (Enforce-FixedConsoleLayout) { $script:OverlayNeedsRedraw = $true }
    } catch { }
    try { Lock-ConsoleScrolling } catch { }
    try { [Console]::CursorVisible = $false } catch { }
}

function Toggle-AsciiSafe {
    $script:AsciiSafeEnabled = -not $script:AsciiSafeEnabled
    Save-AsciiSafeSetting

    # If ASCII-safe is enabled while transliteration is OFF, temporarily force transliteration ON
    # to avoid dropping Greek/Cyrillic content entirely.
    if ($script:AsciiSafeEnabled) {
        if (-not $script:TransliterationEnabled) {
            $script:TranslitPrevBeforeAsciiSafe = $false
            $script:TransliterationEnabled      = $true
            $script:TranslitForcedByAsciiSafe   = $true
            Save-TransliterationSetting
        }
    } else {
        # When ASCII-safe is turned OFF, restore the previous transliteration state if we forced it.
        if ($script:TranslitForcedByAsciiSafe) {
            $script:TransliterationEnabled    = $script:TranslitPrevBeforeAsciiSafe
            $script:TranslitForcedByAsciiSafe = $false
            Save-TransliterationSetting
        }
    }

    try { Refresh-UiAfterSettingChange } catch { }
    return $true
}

function Toggle-Transliteration {
    # If ASCII-safe is enabled, transliteration must remain effectively ON.
    if ($script:AsciiSafeEnabled) { return $false }

    $script:TranslitForcedByAsciiSafe   = $false
    $script:TranslitPrevBeforeAsciiSafe = $script:TransliterationEnabled

    $script:TransliterationEnabled = -not $script:TransliterationEnabled
    Save-TransliterationSetting
    try { Refresh-UiAfterSettingChange } catch { }
    return $true
}

function Handle-Hotkeys {
    if (-not [Console]::KeyAvailable) { return $false }

    $k = [Console]::ReadKey($true)


    # Settings menu: F10 / Ctrl+S
    if ($k.Key -eq [ConsoleKey]::F10 -or ($k.Key -eq [ConsoleKey]::S -and ($k.Modifiers -band [ConsoleModifiers]::Control))) {
        $changed = Show-SettingsMenu
        if ($changed) {
            try { Apply-WorkDirIfConfigured } catch { }
            try { Draw-Header } catch { }
            $script:RebuildWatcher = $true
        }

        # IMPORTANT: When the input is currently in a warning state (Expired / NotAvailable),
        # do NOT trigger an immediate Do-Update() on menu exit. That would:
        # - re-read the stale/absent input,
        # - mark it as "fresh seen",
        # - reset the last-update timer,
        # - and clear the warning colors prematurely.
        #
        # Instead, keep the warning UI active until a *real* fresh input arrives.
        try {
            $stateNow = Get-InputUiState
            if ($changed -and $stateNow -ne "Normal") { return $false }
        } catch { }

        return $changed
    }
    return $false
}

function Get-UiWidth([int]$minWidth = $UI_MinRenderWidth) {
    # Use the *visible* console width to avoid unintended line wrapping that can overwrite UI separators.
    # Prefer WindowWidth (what the user sees), but never exceed BufferWidth.
    $ww = -1
    $bw = -1
    try { $ww = [Console]::WindowWidth } catch { }
    try { $bw = [Console]::BufferWidth } catch { }

    $w = -1
    if ($ww -gt 0 -and $bw -gt 0) { $w = [Math]::Min($ww, $bw) }
    elseif ($ww -gt 0)            { $w = $ww }
    elseif ($bw -gt 0)            { $w = $bw }
    else                          { $w = $minWidth }

    $wEff = $w - $script:UiOffsetX - $script:UiRightMargin
    return [Math]::Max($minWidth, $wEff)
}

function Set-UiCursorPosition([int]$x, [int]$y) {
    # UI-space cursor positioning (respects requested margins).
    # NOTE: $x/$y are in UI coordinates (0,0 is top-left inside the margins).
    try {
        [Console]::SetCursorPosition($x + $script:UiOffsetX, $y + $script:UiOffsetY)
    } catch { }
}

function Set-UiInputCursor([int]$x, [int]$y) {
    try {
        $targetX = $x + $script:UiOffsetX
        $targetY = $y + $script:UiOffsetY
        if (([Console]::CursorLeft -ne $targetX) -or ([Console]::CursorTop -ne $targetY)) {
            [Console]::SetCursorPosition($targetX, $targetY)
        }
        if (-not [Console]::CursorVisible) { [Console]::CursorVisible = $true }
    } catch { }
}

function Write-At([int]$x, [int]$y, [string]$text, [ConsoleColor]$fg, [bool]$PadLine = $true) {
    $w   = Get-UiWidth $UI_MinRenderWidth
    $max = [Math]::Max(0, $w - $x - 1)

    $t = Pad-OrEllipsize $text $max

    if ($PadLine -and $x -eq 0 -and $max -gt 0) { $t = $t.PadRight($max) }

    try {
        With-ConsoleColor $fg $script:BaseBg {
            Set-UiCursorPosition $x $y
            [Console]::Write($t)
        }
    } catch { }
    try { [Console]::CursorVisible = $false } catch { }
}

function Write-SegmentedLine(
    [int]$x,
    [int]$y,
    [string]$aText,
    [ConsoleColor]$aFg,
    [string]$bText,
    [ConsoleColor]$bFg,
    [string]$cText,
    [ConsoleColor]$cFg,
    [string]$dText,
    [ConsoleColor]$dFg,
    [bool]$PadLine = $true,
    [string]$rightText = "",
    [ConsoleColor]$rightFg = $script:BaseFg
) {
    $w   = Get-UiWidth $UI_MinRenderWidth
    $max = [Math]::Max(0, $w - $x - 1)

    # When a right-side status is present, reserve a fixed right-aligned column plus
    # two spaces of separation. This keeps multiple WRITE FAILED markers aligned.
    $rightText = [string]$rightText
    $rightGap  = $(if ([string]::IsNullOrEmpty($rightText)) { 0 } else { 2 })
    $reserve   = $(if ([string]::IsNullOrEmpty($rightText)) { 0 } else { $rightText.Length + $rightGap })
    $contentMax = [Math]::Max(0, $max - $reserve)

    # Clear the full line region first to avoid remnants when content or status shrinks.
    if ($PadLine) { try { Write-At $x $y "" $script:BaseFg $true } catch { } }

    $prefix    = [string]$aText + [string]$bText + [string]$cText
    $prefixLen = $prefix.Length

    $remain = [Math]::Max(0, $contentMax - $prefixLen)
    $d      = Pad-OrEllipsize ([string]$dText) $remain

    try { Write-At $x $y ([string]$aText) $aFg $false } catch { }
    $x2 = $x + ([string]$aText).Length
    try { Write-At $x2 $y ([string]$bText) $bFg $false } catch { }
    $x3 = $x2 + ([string]$bText).Length
    try { Write-At $x3 $y ([string]$cText) $cFg $false } catch { }
    $x4 = $x3 + ([string]$cText).Length
    try { Write-At $x4 $y $d $dFg $false } catch { }

    if ($PadLine) {
        $written = $prefixLen + $d.Length
        $pad     = [Math]::Max(0, $contentMax - $written)
        if ($pad -gt 0) {
            try { Write-At ($x + $written) $y (" " * $pad) $script:BaseFg $false } catch { }
        }
    }

    if (-not [string]::IsNullOrEmpty($rightText)) {
        $rightX = [Math]::Max($x, $x + $max - $rightText.Length)
        try { Write-At $rightX $y $rightText $rightFg $false } catch { }
    }
}

function Write-AtSegments([int]$x, [int]$y, [object[]]$segments, [ConsoleColor]$defaultFg, [bool]$PadLine = $true) {
    $w   = Get-UiWidth $UI_MinRenderWidth
    $max = [Math]::Max(0, $w - $x - 1)

    function Get-SegText($seg) {
        if ($null -eq $seg) { return "" }
        if ($seg -is [System.Collections.IDictionary]) { return [string]($seg["Text"]) }
        return [string]($seg.Text)
    }

    function Get-SegFg($seg, [ConsoleColor]$fallback) {
        if ($null -eq $seg) { return $fallback }
        if ($seg -is [System.Collections.IDictionary]) {
            if ($seg.Contains("Fg") -and $null -ne $seg["Fg"]) { return [ConsoleColor]$seg["Fg"] }
            return $fallback
        }
        if ($null -ne $seg.Fg) { return [ConsoleColor]$seg.Fg }
        return $fallback
    }

    # Build a plain-text preview for length limiting.
    $plain = ""
    foreach ($s in $segments) { $plain += (Get-SegText $s) }

    $plain = Pad-OrEllipsize $plain $max
    if ($PadLine -and $x -eq 0 -and $max -gt 0) { $plain = $plain.PadRight($max) }

    try {
        Set-UiCursorPosition $x $y

        $pos = 0
        foreach ($s in $segments) {
            if ($pos -ge $plain.Length) { break }
            $segText = Get-SegText $s
            if ([string]::IsNullOrEmpty($segText)) { continue }

            $remaining = $plain.Length - $pos
            if ($remaining -le 0) { break }
            if ($segText.Length -gt $remaining) { $segText = $segText.Substring(0, $remaining) }

            $fg = Get-SegFg $s $defaultFg
            With-ConsoleColor $fg $script:BaseBg {
                [Console]::Write($segText)
            }

            $pos += $segText.Length
        }

        # Fill any remaining part of the line with spaces.
        $remainingFill = $plain.Length - $pos
        if ($remainingFill -gt 0) {
            With-ConsoleColor $defaultFg $script:BaseBg {
                [Console]::Write((" " * $remainingFill))
            }
        }
    } catch { }

    try { [Console]::CursorVisible = $false } catch { }
}

# -------------------- Console layout -----------------------------------------

$script:UiInited           = $false
$script:UiOverlayActive    = $false
$script:OverlayNeedsRedraw = $false
$script:HeaderTop          = 0

$script:HeaderLineCount = 12
$script:StatusLineCount = 13

$script:StatusTop      = $script:HeaderTop + $script:HeaderLineCount
$script:LastGoodUpdate = Get-Date

# Output publication state. Failed writes remain visible and are retried with the
# exact same payload, so an expired or otherwise changed input is never republished accidentally.
$script:LastWriteFailures      = @{}
$script:OutputRetryPending     = $false
$script:PendingOutputWrite     = $null
$script:NextOutputRetryUtc     = [DateTime]::MinValue
$script:OutputRetryIntervalSec = 2

# Heartbeat layout (fixed template + field updates to avoid wrap/overdraw artifacts).
$script:HeartbeatLayoutValid   = $false
$script:HeartbeatLayoutWidth   = -1
$script:LastHeartbeatClock               = ""
$script:LastHeartbeatElapsed             = ""
$script:LastHeartbeatElapsedFg           = $script:BaseFg
$script:HeartbeatDisplaySourceTicks      = 0L
$script:NextHeartbeatElapsedRenderUtc    = [DateTime]::MinValue
$script:NextHeartbeatStateCheckUtc       = [DateTime]::MinValue
$script:NextIdleMaintenanceUtc           = [DateTime]::MinValue

$script:LastConsoleW = -1
$script:LastConsoleH = -1

$script:LastInFg          = $script:BaseFg
$script:LastPxFg          = $script:BaseFg
$script:LastArtistFg      = $script:BaseFg
$script:LastConnectorFg   = $script:BaseFg
$script:LastTitleFg       = $script:BaseFg
$script:LastRtFg          = $script:BaseFg
$script:LastRpFg          = $script:BaseFg

$script:LastRawInput         = ""
$script:LastPrefixOut        = ""
$script:LastArtistOut        = ""
$script:LastConnectorOut     = ""
$script:LastTitleOut         = ""
$script:LastRtText           = ""
$script:LastRtPlusText       = ""
$script:LastRawInputShown    = ""
$script:LastPrefixOutShown   = ""
$script:LastArtistShown      = ""
$script:LastConnectorShown   = ""
$script:LastTitleShown       = ""
$script:LastRtTextShown      = ""
$script:LastRtPlusTextShown  = ""
$script:LastInputUiState     = ""


$script:LastMetadataValid = $false

function Test-OutputWriteFailed([string]$label) {
    if ($null -eq $script:LastWriteFailures) { return $false }
    try { return $script:LastWriteFailures.ContainsKey($label) } catch { return $false }
}

function Write-LiveOutputRows {
    # Use the same thirteen-column context area as LOCATION, FILES and LAST UPDATE.
    $contextWidth = 13
    $contentPart  = 'CONTENT'.PadRight($contextWidth)
    $indentPart   = (' ' * $contextWidth)
    $sepPart      = ': '

    $labIn = Get-PaddedOutputLabel $UI_Label_Input
    $labPx = Get-PaddedOutputLabel $UI_Label_Prefix
    $labAr = Get-PaddedOutputLabel $UI_Label_Artist
    $labCn = Get-PaddedOutputLabel $UI_Label_Connector
    $labTi = Get-PaddedOutputLabel $UI_Label_Title
    $labRt = Get-PaddedOutputLabel $UI_Label_CompactRt
    $labRp = Get-PaddedOutputLabel $UI_Label_CompactRtPlus

    $rawInput    = [string]$script:LastRawInputShown
    $prefixOut   = [string]$script:LastPrefixOutShown
    $artistOut   = [string]$script:LastArtistShown
    $connectorOut = [string]$script:LastConnectorShown
    $titleOut    = [string]$script:LastTitleShown
    $rtText      = [string]$script:LastRtTextShown
    $rtPlusText  = [string]$script:LastRtPlusTextShown

    if ($rawInput) {
        $rawInput = $rawInput.Replace([string]$SepChar, [string]$SepGlyph)
    }

    Write-SegmentedLine 0 ($script:StatusTop + 1) $contentPart $UI_Color_SectionTitle $labIn $script:LastInFg $sepPart $UI_Color_FieldSeparator $rawInput $script:LastInFg $true
    Write-SegmentedLine 0 ($script:StatusTop + 2) $indentPart $script:BaseFg $labPx $script:LastPxFg $sepPart $UI_Color_FieldSeparator $prefixOut $script:LastPxFg $true

    if (Test-TitleFirstOrder) {
        Write-SegmentedLine 0 ($script:StatusTop + 3) $indentPart $script:BaseFg $labTi $script:LastTitleFg     $sepPart $UI_Color_FieldSeparator $titleOut     $script:LastTitleFg     $true
        Write-SegmentedLine 0 ($script:StatusTop + 4) $indentPart $script:BaseFg $labCn $script:LastConnectorFg $sepPart $UI_Color_FieldSeparator $connectorOut $script:LastConnectorFg $true
        Write-SegmentedLine 0 ($script:StatusTop + 5) $indentPart $script:BaseFg $labAr $script:LastArtistFg    $sepPart $UI_Color_FieldSeparator $artistOut    $script:LastArtistFg    $true
    } else {
        Write-SegmentedLine 0 ($script:StatusTop + 3) $indentPart $script:BaseFg $labAr $script:LastArtistFg    $sepPart $UI_Color_FieldSeparator $artistOut    $script:LastArtistFg    $true
        Write-SegmentedLine 0 ($script:StatusTop + 4) $indentPart $script:BaseFg $labCn $script:LastConnectorFg $sepPart $UI_Color_FieldSeparator $connectorOut $script:LastConnectorFg $true
        Write-SegmentedLine 0 ($script:StatusTop + 5) $indentPart $script:BaseFg $labTi $script:LastTitleFg     $sepPart $UI_Color_FieldSeparator $titleOut     $script:LastTitleFg     $true
    }

    Write-SegmentedLine 0 ($script:StatusTop + 6) $indentPart $script:BaseFg $labRt $script:LastRtFg $sepPart $UI_Color_FieldSeparator $rtText     $script:LastRtFg $true
    Write-SegmentedLine 0 ($script:StatusTop + 7) $indentPart $script:BaseFg $labRp $script:LastRpFg $sepPart $UI_Color_FieldSeparator $rtPlusText $script:LastRpFg $true
    Write-At 0 ($script:StatusTop + 8) "" $script:BaseFg $true
}

function Redraw-Ui {
    try { Clear-Host } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    $script:UiInited = $false
    Ensure-UiFresh

    try { Write-LiveOutputRows } catch { }
}

function Write-MenuHeaderLine([int]$x0, [int]$y, [int]$menuW, [string]$title, [string]$help) {
    $innerW = $menuW - 4

    With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
        Set-UiCursorPosition $x0 $y
        [Console]::Write($UI_Frame_Vertical + " ")
        Set-UiCursorPosition ($x0 + $menuW - 2) $y
        [Console]::Write(" " + $UI_Frame_Vertical)
    }

    Write-UiHeaderContent ($x0 + 2) $y $innerW $title $help
}

function Draw-MenuFrame([int]$x0, [int]$y0, [int]$menuW, [string]$title, [string]$help) {
    # Keep title and action hints on one physical header line. The second interior row remains
    # intentionally blank so existing item coordinates and menu heights do not change.
    Write-At $x0 $y0 ($UI_Frame_TopLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_TopRight) ($UI_Color_MenuFrame)
    Write-MenuHeaderLine $x0 ($y0 + 1) $menuW $title $help
    Write-MenuHeaderLine $x0 ($y0 + 2) $menuW "" ""
    Write-At $x0 ($y0 + 3) ($UI_Frame_MiddleLeft + ($UI_Frame_Horizontal * ($menuW - 2)) + $UI_Frame_MiddleRight) ($UI_Color_MenuFrame)
}

function Refresh-UiAfterSettingChange {
    if ($script:UiOverlayActive) { return }
    # Avoid a full Clear-Host redraw for simple setting toggles.
    # Update only the settings row (and keep the heartbeat template intact).
    try { Ensure-UiFresh } catch { }
    try { Ensure-HeartbeatLayout } catch { }
    try { Render-SettingsAndLegend } catch { }
    try { Update-HeartbeatFields } catch { }
}

function Ensure-MinConsoleLayout {
    # Apply the configured UI background and set a fixed window/buffer size (best-effort).
    # Goal: stable UI layout and no scrollbars (buffer == window).
    try {
        [Console]::BackgroundColor = $script:BaseBg
        Clear-Host
    } catch { }

    try {
        if ($FixedConsoleWidth  -lt $UI_MinConsoleWidth) { $FixedConsoleWidth  = $UI_MinConsoleWidth }
        if ($FixedConsoleHeight -lt $UI_MinConsoleHeight) { $FixedConsoleHeight = $UI_MinConsoleHeight }

        $lw = 0; $lh = 0
        try { $lw = [Console]::LargestWindowWidth } catch { }
        try { $lh = [Console]::LargestWindowHeight } catch { }

        $targetW = $FixedConsoleWidth
        $targetH = $FixedConsoleHeight
        if ($lw -gt 0) { $targetW = [Math]::Min($targetW, $lw) }
        if ($lh -gt 0) { $targetH = [Math]::Min($targetH, $lh) }

        # Important: when shrinking, set Window first (within current buffer), then buffer.
        # When growing, set Buffer first, then Window.
        $curBW = [Console]::BufferWidth
        $curBH = [Console]::BufferHeight
        $curWW = [Console]::WindowWidth
        $curWH = [Console]::WindowHeight

        if ($curWW -gt $targetW -or $curWH -gt $targetH) {
            if ($curWW -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW }
            if ($curWH -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH }
        }

        if ($curBW -ne $targetW -and $targetW -gt 0) { [Console]::BufferWidth  = $targetW }
        if ($curBH -ne $targetH -and $targetH -gt 0) { [Console]::BufferHeight = $targetH }

        if ([Console]::WindowWidth  -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW }
        if ([Console]::WindowHeight -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH }

        # Ensure no scrollbars (buffer == window)
        if ([Console]::BufferWidth  -ne [Console]::WindowWidth)  { [Console]::BufferWidth  = [Console]::WindowWidth }
        if ([Console]::BufferHeight -ne [Console]::WindowHeight) { [Console]::BufferHeight = [Console]::WindowHeight }

        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

function Enforce-FixedConsoleLayout {
    # Best-effort enforcement of the fixed console window/buffer size WITHOUT clearing the screen.
    # Returns $true if a size correction was applied.
    $changed = $false
    try {
        if ($FixedConsoleWidth  -lt $UI_MinConsoleWidth) { $FixedConsoleWidth  = $UI_MinConsoleWidth }
        if ($FixedConsoleHeight -lt $UI_MinConsoleHeight) { $FixedConsoleHeight = $UI_MinConsoleHeight }

        $lw = 0; $lh = 0
        try { $lw = [Console]::LargestWindowWidth } catch { }
        try { $lh = [Console]::LargestWindowHeight } catch { }

        $targetW = $FixedConsoleWidth
        $targetH = $FixedConsoleHeight
        if ($lw -gt 0) { $targetW = [Math]::Min($targetW, $lw) }
        if ($lh -gt 0) { $targetH = [Math]::Min($targetH, $lh) }

        $curBW = [Console]::BufferWidth
        $curBH = [Console]::BufferHeight
        $curWW = [Console]::WindowWidth
        $curWH = [Console]::WindowHeight

        # Shrink: window first, then buffer. Grow: buffer first, then window.
        if ($curWW -gt $targetW -or $curWH -gt $targetH) {
            if ($curWW -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW; $changed = $true }
            if ($curWH -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH; $changed = $true }
        }

        if ($curBW -ne $targetW -and $targetW -gt 0) { [Console]::BufferWidth  = $targetW; $changed = $true }
        if ($curBH -ne $targetH -and $targetH -gt 0) { [Console]::BufferHeight = $targetH; $changed = $true }

        if ([Console]::WindowWidth  -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW; $changed = $true }
        if ([Console]::WindowHeight -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH; $changed = $true }

        # Ensure no scrollbars (buffer == window)
        if ([Console]::BufferWidth  -ne [Console]::WindowWidth)  { [Console]::BufferWidth  = [Console]::WindowWidth;  $changed = $true }
        if ([Console]::BufferHeight -ne [Console]::WindowHeight) { [Console]::BufferHeight = [Console]::WindowHeight; $changed = $true }

        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
    return $changed
}

function Ensure-UiFresh {
    $w = -1
    $h = -1
    try { $w = [Console]::WindowWidth } catch { }
    try { $h = [Console]::WindowHeight } catch { }

    if (-not $script:UiInited) {
        Init-Ui
        try { $w = [Console]::WindowWidth } catch { }
        try { $h = [Console]::WindowHeight } catch { }
        $script:LastConsoleW = $w
        $script:LastConsoleH = $h
        return
    }

    if ($w -ne $script:LastConsoleW -or $h -ne $script:LastConsoleH) {
        $script:LastConsoleW = $w
        $script:LastConsoleH = $h
        Redraw-Ui
    }

    # Keep the UI anchored at the top-left so mouse-wheel/scrollbar attempts cannot move it out of view.
    # This is best-effort: Windows console scrolling cannot be fully disabled in a pure PowerShell script,
    # but regularly snapping the viewport back prevents the UI from disappearing.
    try { Lock-ConsoleScrolling } catch { }
}

function Ensure-BufferHeight([int]$minHeight) {
    try {
        if ([Console]::BufferHeight -lt $minHeight) { [Console]::BufferHeight = $minHeight }
    } catch { }
}

function Lock-ConsoleScrolling {
    # Prevent the user from scrolling the UI out of view using the mouse wheel or the scrollbar.
    # When the window is tall enough for the full UI, we keep buffer size equal to window size (no scrollback).
    # When the window is too small, we still snap back to the top-left so the UI stays anchored.
    try {
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -le 0 -or $h -le 0) { return }

        $minH = 0
        try { $minH = ($script:StatusTop + $script:StatusLineCount + 2) } catch { $minH = 0 }

        # Width: never shrink buffer sizes (shrinks can be unstable on some hosts). Only grow when needed.
        if ([Console]::BufferWidth -lt $w) { [Console]::BufferWidth = $w }

        # Height: never shrink buffer sizes. Ensure the buffer is at least large enough for the UI
        # (or at least as tall as the visible window).
        if ($minH -gt 0 -and $h -lt $minH) {
            if ([Console]::BufferHeight -lt $minH) { [Console]::BufferHeight = $minH }
        } else {
            if ([Console]::BufferHeight -lt $h) { [Console]::BufferHeight = $h }
        }

        # Snap back to the top-left of the buffer in case the user tried to scroll.
        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

$script:PostInitConsoleTweaksApplied = $false
$script:HardScrollLockApplied        = $false

function Lock-ConsoleScrollingHard {
    # HARD mode: remove scrollback by matching buffer size to the visible window size.
    # Only used in classic conhost sessions (Windows Terminal manages scrollback itself).
    try {
        if ($env:WT_SESSION) { return }

        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -le 0 -or $h -le 0) { return }

        $minH = 0
        try { $minH = ($script:StatusTop + $script:StatusLineCount + 2) } catch { $minH = 0 }
        if ($minH -gt 0 -and $h -lt $minH) { return }  # Do not force hard lock if the UI cannot fit.

        # Put the cursor safely inside the visible window before resizing.
        try { Set-UiCursorPosition 0 0 } catch { }

        # Match buffer to window -> no scrollback/scrollbar (classic console).
        if ([Console]::BufferWidth  -ne $w) { [Console]::BufferWidth  = $w }
        if ([Console]::BufferHeight -ne $h) { [Console]::BufferHeight = $h }

        # Pin viewport.
        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

function Apply-PostInitConsoleTweaks {
    # Some console hosts finalize / override input modes during startup.
    # Re-apply our preferred modes after the first full UI render.
    if ($script:PostInitConsoleTweaksApplied) { return }

    try { Disable-ConsoleQuickEdit } catch { }

    # Best-effort: in classic conhost, remove scrollback so the scrollbar is gone.
    if ($EnableHardScrollLock -and -not $script:HardScrollLockApplied) {
        try {
            Lock-ConsoleScrollingHard
            $script:HardScrollLockApplied = $true
        } catch { }
    }

    $script:PostInitConsoleTweaksApplied = $true
}

function Draw-StatusFrame {
    $top  = $script:StatusTop
    $w    = Get-UiWidth $UI_MinRenderWidth
    $line = ($UI_SeparatorGlyph * ([Math]::Max(1, $w - 1)))

    # One separator above the live output block and one below the Last update row.
    Write-At 0 ($top + 0)  $line $UI_Color_Separator $true
    Write-At 0 ($top + 10) $line $UI_Color_Separator $true
}

function Write-HeaderFileRows {
    # Keep publication errors with the affected file names. The right-side warning
    # column is reserved only on failed rows, so the CONTENT block remains untouched.
    $contextWidth = 13
    $filesPart    = 'FILES'.PadRight($contextWidth)
    $indentPart   = (' ' * $contextWidth)
    $sep          = ': '

    $labIn = Get-PaddedOutputLabel $UI_Label_Input
    $labPx = Get-PaddedOutputLabel $UI_Label_Prefix
    $labAr = Get-PaddedOutputLabel $UI_Label_Artist
    $labCn = Get-PaddedOutputLabel $UI_Label_Connector
    $labTi = Get-PaddedOutputLabel $UI_Label_Title
    $labRt = Get-PaddedOutputLabel $UI_Label_CompactRt
    $labRp = Get-PaddedOutputLabel $UI_Label_CompactRtPlus

    $inFileName        = [string]$InFile
    $prefixFileName    = [string]$PrefixFile
    $artistFileName    = [string]$ArtistFile
    $connectorFileName = [string]$ConnectorFile
    $titleFileName     = [string]$TitleFile
    $rtFileName        = [string]$OutFileRt
    $rtPlusFileName    = [string]$OutFileRtPlus

    try { $inFileName        = Split-Path -Leaf $InFile } catch { }
    try { $prefixFileName    = Split-Path -Leaf $PrefixFile } catch { }
    try { $artistFileName    = Split-Path -Leaf $ArtistFile } catch { }
    try { $connectorFileName = Split-Path -Leaf $ConnectorFile } catch { }
    try { $titleFileName     = Split-Path -Leaf $TitleFile } catch { }
    try { $rtFileName        = Split-Path -Leaf $OutFileRt } catch { }
    try { $rtPlusFileName    = Split-Path -Leaf $OutFileRtPlus } catch { }

    $fgIn = $UI_Color_Input
    $fgPx = $UI_Color_Prefix
    $fgAr = $UI_Color_Artist
    $fgCn = $UI_Color_Connector
    $fgTi = $UI_Color_Title
    $fgRt = $UI_Color_RT
    $fgRp = $UI_Color_RTPlus

    $writeFailedText = 'WRITE FAILED'
    $prefixWriteState    = $(if (Test-OutputWriteFailed 'prefix')    { $writeFailedText } else { '' })
    $artistWriteState    = $(if (Test-OutputWriteFailed 'artist')    { $writeFailedText } else { '' })
    $connectorWriteState = $(if (Test-OutputWriteFailed 'connector') { $writeFailedText } else { '' })
    $titleWriteState     = $(if (Test-OutputWriteFailed 'title')     { $writeFailedText } else { '' })
    $rtWriteState        = $(if (Test-OutputWriteFailed 'RT')        { $writeFailedText } else { '' })
    $rtPlusWriteState    = $(if (Test-OutputWriteFailed 'RT+')       { $writeFailedText } else { '' })

    Write-SegmentedLine 0 ($script:HeaderTop + 4) $filesPart  $UI_Color_SectionTitle $labIn $fgIn $sep $UI_Color_FieldSeparator $inFileName $fgIn $true
    Write-SegmentedLine 0 ($script:HeaderTop + 5) $indentPart $script:BaseFg $labPx $fgPx $sep $UI_Color_FieldSeparator $prefixFileName $fgPx $true $prefixWriteState $UI_Color_WarningText

    if (Test-TitleFirstOrder) {
        Write-SegmentedLine 0 ($script:HeaderTop + 6) $indentPart $script:BaseFg $labTi $fgTi $sep $UI_Color_FieldSeparator $titleFileName     $fgTi $true $titleWriteState     $UI_Color_WarningText
        Write-SegmentedLine 0 ($script:HeaderTop + 7) $indentPart $script:BaseFg $labCn $fgCn $sep $UI_Color_FieldSeparator $connectorFileName $fgCn $true $connectorWriteState $UI_Color_WarningText
        Write-SegmentedLine 0 ($script:HeaderTop + 8) $indentPart $script:BaseFg $labAr $fgAr $sep $UI_Color_FieldSeparator $artistFileName    $fgAr $true $artistWriteState    $UI_Color_WarningText
    } else {
        Write-SegmentedLine 0 ($script:HeaderTop + 6) $indentPart $script:BaseFg $labAr $fgAr $sep $UI_Color_FieldSeparator $artistFileName    $fgAr $true $artistWriteState    $UI_Color_WarningText
        Write-SegmentedLine 0 ($script:HeaderTop + 7) $indentPart $script:BaseFg $labCn $fgCn $sep $UI_Color_FieldSeparator $connectorFileName $fgCn $true $connectorWriteState $UI_Color_WarningText
        Write-SegmentedLine 0 ($script:HeaderTop + 8) $indentPart $script:BaseFg $labTi $fgTi $sep $UI_Color_FieldSeparator $titleFileName     $fgTi $true $titleWriteState     $UI_Color_WarningText
    }

    Write-SegmentedLine 0 ($script:HeaderTop + 9) $indentPart $script:BaseFg $labRt $fgRt $sep $UI_Color_FieldSeparator $rtFileName     $fgRt $true $rtWriteState     $UI_Color_WarningText
    Write-SegmentedLine 0 ($script:HeaderTop + 10) $indentPart $script:BaseFg $labRp $fgRp $sep $UI_Color_FieldSeparator $rtPlusFileName $fgRp $true $rtPlusWriteState $UI_Color_WarningText
}

function Draw-Header {
    $t0 = ($UI_HeaderTitleTemplate -f $ScriptTitle, $ScriptVersion)

    Write-At 0 ($script:HeaderTop + 0) $t0 $UI_Color_SectionTitle $true
    Write-At 0 ($script:HeaderTop + 1) ""  $script:BaseFg $true

    # LOCATION, FILES, CONTENT and LAST UPDATE share the same thirteen-column context area.
    $contextWidth = 13
    $locationPart = 'LOCATION'.PadRight($contextWidth)
    $sep          = ': '
    $labWd        = Get-PaddedOutputLabel $UI_Label_WorkingDir
    $workDir      = ''

    try { $workDir = Split-Path -Parent $InFile } catch { }

    Write-SegmentedLine 0 ($script:HeaderTop + 2) $locationPart $UI_Color_SectionTitle $labWd $UI_Color_LocationData $sep $UI_Color_FieldSeparator $workDir $UI_Color_LocationData $true
    Write-At 0 ($script:HeaderTop + 3) "" $script:BaseFg $true
    Write-HeaderFileRows
    Write-At 0 ($script:HeaderTop + 11) "" $script:BaseFg $true
}

function Init-Ui {
    if ($script:UiInited) { return }
    try { Ensure-MinConsoleLayout } catch { }
    $minNeeded = $script:StatusTop + $script:StatusLineCount + 2
    Ensure-BufferHeight $minNeeded

    Draw-Header
    Draw-StatusFrame

    for ($i = 1; $i -lt $script:StatusLineCount; $i++) {
        Write-At 0 ($script:StatusTop + $i) "" $script:BaseFg $true
    }

    Draw-StatusFrame

    # Static UI rows (heartbeat template + settings + legend).
    $script:HeartbeatLayoutValid = $false
    Ensure-HeartbeatLayout
    Update-HeartbeatFields

    $script:UiInited = $true

    # Apply post-init console tweaks (best-effort, host-dependent).
    try { Apply-PostInitConsoleTweaks } catch { }
}

# -------------------- Console status ------------------------------------------

function Get-HealthColor([int]$ageSec, [int]$graceSec, [int]$redAtSec, [int]$phase) {
    if ($ageSec -le $graceSec) { return $script:BaseFg }
    if ($redAtSec -le ($graceSec + 1)) { $redAtSec = $graceSec + 1 }

    $r = [double]($ageSec - $graceSec) / [double]($redAtSec - $graceSec)
    if ($r -lt 0) { $r = 0 }
    if ($r -gt 1) { $r = 1 }

    $ramp = @($script:BaseFg, $UI_Color_WarningTextDim, $UI_Color_ErrorText)

    $n = $ramp.Count
    if ($n -lt 2) { return $script:BaseFg }

    $pos = $r * ($n - 1)
    $idx = [int][Math]::Floor($pos)
    if ($idx -ge ($n - 1)) { return $ramp[$n - 1] }

    $frac = $pos - $idx
    if ($frac -ge 0.5) { return $ramp[$idx + 1] }
    return $ramp[$idx]
}

function Format-Elapsed([TimeSpan]$ts) {
    if ($ts.TotalSeconds -lt 0) { $ts = [TimeSpan]::Zero }

    $d = [int]$ts.TotalDays
    $h = $ts.Hours
    $m = $ts.Minutes
    $s = $ts.Seconds

    if ($d -gt 0) { return ("{0}d {1}h {2}m {3}s" -f $d, $h.ToString("00"), $m.ToString("00"), $s.ToString("00")) }
    if ($h -gt 0) { return ("{0}h {1}m {2}s" -f $h, $m.ToString("00"), $s.ToString("00")) }
    if ($m -gt 0) { return ("{0}m {1}s" -f $m, $s.ToString("00")) }
    return ("{0}s" -f $s)
}

function Ensure-HeartbeatLayout {
    # Prepare the fixed rows below the live status lines:
    # - Blank spacer row after the live output block
    # - Last update row
    # - Separator row
    # - Blank spacer row
    # - Settings / control legend row
    #
    # This function only ensures that those rows exist and are clean after an initial draw or a resize.
    # The heartbeat content itself is rendered by Update-HeartbeatFields.

    $w = Get-UiWidth $UI_MinRenderWidth

    if (-not $script:HeartbeatLayoutValid -or $w -ne $script:HeartbeatLayoutWidth) {
        $script:HeartbeatLayoutWidth = $w

        # Heartbeat row (will be overwritten by Update-HeartbeatFields).
        Write-At 0 ($script:StatusTop + 9) "" $script:BaseFg $true

        # Render separator + settings + footer in their fixed rows.
        Render-SettingsAndLegend

        # Force first field update after (re)layout.
        $script:LastHeartbeatClock            = ""
        $script:LastHeartbeatElapsed          = ""
        $script:LastHeartbeatElapsedFg        = $script:BaseFg
        $script:HeartbeatDisplaySourceTicks   = 0L
        $script:NextHeartbeatElapsedRenderUtc = [DateTime]::MinValue

        $script:HeartbeatLayoutValid = $true
    }
}

function Render-SettingsAndLegend {
    # Settings row
    $aState = $(if ($script:AsciiSafeEnabled) { "ON " } else { "OFF" })
    $tState = $(if ($script:TransliterationEnabled) { "ON " } else { "OFF" })

    $dimFg  = $UI_Color_MenuHint

    # Match the F10 menu: enabled values (including brackets) are bright; disabled values stay dim.
    $valueFgEnabled  = $UI_Color_MenuValue
    $valueFgDisabled = $UI_Color_MenuDisabled

    # ASCII-safe is always an enabled item in the F10 menu, regardless of ON/OFF.
    $aValueFg = $valueFgEnabled

    # Transliteration becomes a disabled item when ASCII-safe is ON.
    $tValueFg = if ($script:AsciiSafeEnabled) { $valueFgDisabled } else { $valueFgEnabled }

    # Determine displayed transliteration token (same text as before).
    $tDisplay    = if ($script:AsciiSafeEnabled) { "ON*" } else { $tState.Trim() }
    $orderDisplay = Get-ArtistTitleOrderCompactDisplay

    # Show current values in square brackets for quick scanning, in the same relative order as the F10 menu.
    $settingsSegments = @(
    @{ Text = "Order ";                  Fg = $dimFg }
    @{ Text = "[";                       Fg = $valueFgEnabled }
    @{ Text = $orderDisplay;             Fg = $valueFgEnabled }
    @{ Text = "]";                       Fg = $valueFgEnabled }
    @{ Text = " | ";                     Fg = $dimFg }

    @{ Text = "ASCII-safe ";             Fg = $dimFg }
    @{ Text = "[";                       Fg = $aValueFg }
    @{ Text = $aState.Trim();            Fg = $aValueFg }
    @{ Text = "]";                       Fg = $aValueFg }
    @{ Text = " | ";                     Fg = $dimFg }

    @{ Text = "Translit EL/CYR ";        Fg = $dimFg }
    @{ Text = "[";                       Fg = $tValueFg }
    @{ Text = $tDisplay;                 Fg = $tValueFg }
    @{ Text = "]";                       Fg = $tValueFg }
    @{ Text = " | ";                     Fg = $dimFg }

    @{ Text = "Delimiter ";              Fg = $dimFg }
    @{ Text = "[";                       Fg = $valueFgEnabled }
    @{ Text = (Format-DelimiterForDisplay $global:SepGlyph); Fg = $valueFgEnabled }
    @{ Text = "]";                       Fg = $valueFgEnabled }
    )
    # Separator line directly under the Last update row
    $w    = Get-UiWidth $UI_MinRenderWidth
    $line = ($UI_SeparatorGlyph * ([Math]::Max(1, $w - 1)))
    Write-At 0 ($script:StatusTop + 10) $line $UI_Color_Separator $true

    # Blank line between the separator and the control legend
    Write-At 0 ($script:StatusTop + 11) "" $script:BaseFg $true

    # Settings row (function hotkeys are shown left-to-right in F-key order)
    Write-AtSegments 0 ($script:StatusTop + 12) $settingsSegments $script:BaseFg $true

    # Exit key (Ctrl+C stops the main loop).
    $w2            = Get-UiWidth $UI_MinRenderWidth
    $exitHintLeft  = "F10 Settings"
    $exitHintRight = "CTRL+C Exit"
    $exitHint      = "$exitHintLeft   $exitHintRight"
    $xExit         = [Math]::Max(0, $w2 - $exitHint.Length - 1)

    # Hotkey hints are low-priority UI chrome. Keep the words dimmed, but show the actual key chords in bright white.
    Write-At $xExit ($script:StatusTop + 12) "F10" ($UI_Color_InputText)
    Write-At ($xExit + 3) ($script:StatusTop + 12) " Settings" ($UI_Color_DimText)
    Write-At ($xExit + 12) ($script:StatusTop + 12) "   " ($UI_Color_DimText)
    Write-At ($xExit + 15) ($script:StatusTop + 12) "CTRL+C" ($UI_Color_InputText)
    Write-At ($xExit + 21) ($script:StatusTop + 12) " Exit" ($UI_Color_DimText)
}

function Update-HeartbeatFields {
    $now = Get-Date
    $age = $now - $script:LastGoodUpdate
    if ($age.TotalSeconds -lt 0) { $age = [TimeSpan]::Zero }

    # PowerShell rounds floating-point values when casting to [int]; elapsed seconds must be floored.
    # Render the real elapsed value directly. Scheduling is tied to the corresponding absolute
    # LastGoodUpdate boundary, so no independent display counter can lag or catch up later.
    $actualAgeSec  = [int][Math]::Floor([Math]::Max(0.0, $age.TotalSeconds))
    $updateTicks   = [int64]$script:LastGoodUpdate.Ticks
    $sourceChanged = ($updateTicks -ne $script:HeartbeatDisplaySourceTicks)

    if ($sourceChanged) {
        $script:HeartbeatDisplaySourceTicks = $updateTicks
    }
    Set-NextHeartbeatElapsedRender $actualAgeSec

    $phase    = [int]$now.Second
    $healthFg = Get-HealthColor $actualAgeSec $HealthGraceSec $HealthRedAtSec $phase

    $clock        = $script:LastGoodUpdate.ToString("HH:mm:ss")
    $elapsedToken = Format-Elapsed ([TimeSpan]::FromSeconds($actualAgeSec))
    $contextWidth = 13
    $contextPart  = $UI_Label_LastUpdate.PadRight($contextWidth)
    $clockPart    = $clock.PadRight($UI_OutputLabelWidth)

    # Avoid unnecessary console writes during the subsecond idle poll and menu processing.
    # Layout rebuilds clear the cached values, so a restored or resized row is still drawn immediately.
    if (
        -not $sourceChanged -and
        $clock -eq $script:LastHeartbeatClock -and
        $elapsedToken -eq $script:LastHeartbeatElapsed -and
        $healthFg -eq $script:LastHeartbeatElapsedFg
    ) { return }

    # Render the entire heartbeat row so suffixes like "ago" always stay directly attached to the elapsed token.
    # This also guarantees that the complete row is restored after any overlay menu has cleared it.
    $segments = @(
    @{ Text = $contextPart;  Fg = $UI_Color_SectionTitle }
    @{ Text = $clockPart;    Fg = $healthFg }
    @{ Text = ": ";         Fg = $UI_Color_FieldSeparator }
    @{ Text = $elapsedToken; Fg = $healthFg }
    @{ Text = " ago";       Fg = $script:BaseFg }
    )

    Write-AtSegments 0 ($script:StatusTop + 9) $segments $script:BaseFg $true

    $script:LastHeartbeatClock     = $clock
    $script:LastHeartbeatElapsed   = $elapsedToken
    $script:LastHeartbeatElapsedFg = $healthFg
}

function Update-HeartbeatBar {
    if ($script:UiOverlayActive) { return }
    Ensure-UiFresh
    Ensure-HeartbeatLayout
    Update-HeartbeatFields

    # Preserve the former one-second cadence for availability/staleness checks, despite the faster UI poll.
    $nowUtc = [DateTime]::UtcNow
    if ($nowUtc -lt $script:NextHeartbeatStateCheckUtc) { return }
    $script:NextHeartbeatStateCheckUtc = $nowUtc.AddSeconds(1)

    # Update the live output block if the input availability/staleness state changed.
    $state = Get-InputUiState
    if ($state -ne $script:LastInputUiState) {
        $script:LastInputUiState = $state

        # If the input becomes unavailable, flush all output files once so downstream systems do not keep stale data.
        if ($state -eq "NotAvailable") {
            if (-not $script:OutputsFlushedForNotAvailable) {
                try { [void](Publish-Outputs "" "" "" "" "" "" $false) } catch { }
                $script:OutputsFlushedForNotAvailable = $true
            }
        } else {
            $script:OutputsFlushedForNotAvailable = $false
        }

        if ($state -eq "Normal") {
            # Restore the last known values (if any) when returning to a healthy state.
            Update-Status $script:LastRawInput $script:LastPrefixOut $script:LastArtistOut $script:LastConnectorOut $script:LastTitleOut $script:LastRtText $script:LastRtPlusText "Normal"
        } else {
            Update-Status "" "" "" "" "" "" "" $state
        }
    }

    Maintain-MainConsoleInputState
}

function Update-Status(
    [string]$rawInput,
    [string]$prefixOut,
    [string]$artistOut,
    [string]$connectorOut,
    [string]$titleOut,
    [string]$rtText,
    [string]$rtPlusText,
    [string]$inputState = "Normal"
) {
    if ($script:UiOverlayActive) { return }
    Ensure-UiFresh

    $rawInput = ($rawInput -replace "^\uFEFF", "")
    $rawInput = [regex]::Replace($rawInput, "\s+", " ").Trim()

    $prefixOut    = [regex]::Replace($prefixOut, "\s+", " ").Trim()
    $artistOut    = [regex]::Replace($artistOut, "\s+", " ").Trim()
    $connectorOut = [regex]::Replace($connectorOut, "\s+", " ").Trim()
    $titleOut     = [regex]::Replace($titleOut, "\s+", " ").Trim()
    $rtText       = [regex]::Replace($rtText, "\s+", " ").Trim()
    $rtPlusText   = [regex]::Replace($rtPlusText, "\s+", " ").Trim()

    # Persist the latest computed values for redraw/refresh scenarios.
    $script:LastRawInput     = $rawInput
    $script:LastPrefixOut    = $prefixOut
    $script:LastArtistOut    = $artistOut
    $script:LastConnectorOut = $connectorOut
    $script:LastTitleOut     = $titleOut
    $script:LastRtText       = $rtText
    $script:LastRtPlusText   = $rtPlusText

    # In special UI states we show a warning placeholder for the input itself.
    if ($inputState -eq "NotAvailable") {
        $rawInput = "<not available>"
    } elseif ($inputState -eq "Expired") {
        $rawInput = "<expired>"
    }

    # Show every absent derived value consistently as a dimmed placeholder, both
    # for incomplete valid metadata and for missing/expired input. This affects
    # only the console UI; the actual output files remain empty where applicable.
    if ([string]::IsNullOrEmpty($prefixOut))    { $prefixOut    = "<none>" }
    if ([string]::IsNullOrEmpty($artistOut))    { $artistOut    = "<none>" }
    if ([string]::IsNullOrEmpty($connectorOut)) { $connectorOut = "<none>" }
    if ([string]::IsNullOrEmpty($titleOut))     { $titleOut     = "<none>" }
    if ([string]::IsNullOrEmpty($rtText))       { $rtText       = "<none>" }
    if ([string]::IsNullOrEmpty($rtPlusText))   { $rtPlusText   = "<none>" }

    # Persist the latest *shown* values for UI redraw scenarios (menu overlay restore, partial refresh).
    $script:LastRawInputShown   = $rawInput
    $script:LastPrefixOutShown  = $prefixOut
    $script:LastArtistShown     = $artistOut
    $script:LastConnectorShown  = $connectorOut
    $script:LastTitleShown      = $titleOut
    $script:LastRtTextShown     = $rtText
    $script:LastRtPlusTextShown = $rtPlusText

    if ($rawInput) { $rawInput = ([string]$rawInput).Replace([string]$SepChar, [string]$SepGlyph) }

    $inFg = if ($inputState -ne "Normal" -or [string]::IsNullOrEmpty($rawInput)) { $UI_Color_WarningText } else { $UI_Color_Input }
    $pxFg = if ($prefixOut    -eq "<none>") { $UI_Color_DimText } else { $UI_Color_Prefix }
    $arFg = if ($artistOut    -eq "<none>") { $UI_Color_DimText } else { $UI_Color_Artist }
    $cnFg = if ($connectorOut -eq "<none>") { $UI_Color_DimText } else { $UI_Color_Connector }
    $tiFg = if ($titleOut     -eq "<none>") { $UI_Color_DimText } else { $UI_Color_Title }
    $rtFg = if ($rtText       -eq "<none>") { $UI_Color_DimText } else { $UI_Color_RT }
    $rpFg = if ($rtPlusText   -eq "<none>") { $UI_Color_DimText } else { $UI_Color_RTPlus }

    $script:LastInFg        = $inFg
    $script:LastPxFg        = $pxFg
    $script:LastArtistFg    = $arFg
    $script:LastConnectorFg = $cnFg
    $script:LastTitleFg     = $tiFg
    $script:LastRtFg        = $rtFg
    $script:LastRpFg        = $rpFg

    try { Write-LiveOutputRows } catch { }

    $script:LastInputUiState = $inputState
}

# -------------------- Normalization helpers ----------------------------------

function Strip-InvisibleControls([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $s = [regex]::Replace($s, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", "")
    $s = [regex]::Replace($s, "[\u00AD\uFEFF\u200B-\u200D\u2060]", "")
    return $s
}

function Decode-BasicHtmlEntities([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $s = $s.Replace("&amp;", "&").Replace("&quot;", '"').Replace("&apos;", "'")
    $s = $s.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&nbsp;", " ")

    $s = [regex]::Replace($s, "&#(\d+);", {
        param($m)
        try {
            $cp = [int]$m.Groups[1].Value
            if ($cp -lt 0 -or $cp -gt 0x10FFFF) { return $m.Value }
            return [char]::ConvertFromUtf32($cp)
        } catch { return $m.Value }
    })

    $s = [regex]::Replace($s, "&#x([0-9A-Fa-f]+);", {
        param($m)
        try {
            $cp = [Convert]::ToInt32($m.Groups[1].Value, 16)
            if ($cp -lt 0 -or $cp -gt 0x10FFFF) { return $m.Value }
            return [char]::ConvertFromUtf32($cp)
        } catch { return $m.Value }
    })

    $s = $s.Replace("&#39;", "'")
    return $s
}

function Normalize-FullwidthAscii([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($cp -eq 0x3000) { [void]$sb.Append(" "); continue }
        if ($cp -ge 0xFF01 -and $cp -le 0xFF5E) { [void]$sb.Append([char]($cp - 0xFEE0)); continue }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

function Apply-Replacements([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Normalize a few common symbols that are not reliably supported on RDS receivers.
    $s = [regex]::Replace($s, '\u00B0\s*([cCfF])', ' $1')  # "°C" -> " C", "°F" -> " F"
    # Replace omega only in electrical-unit context (e.g. 10Ω, 4.7kΩ, 1 MΩ). Otherwise, keep it
    # as a Greek letter and let Transliterate-Greek() handle it.
    $s = [regex]::Replace(
    $s,
    '(?i)(?<=\d)\s*(?<p>k|m|g|t|u|n|p)?\s*[\u03A9\u03C9]',
    {
        param($m)
        $p = $m.Groups['p'].Value
        if ([string]::IsNullOrEmpty($p)) { return ' Ohm' }
        return " $p" + 'Ohm'
    }
    )
    $map = @{
        0x2018="'"; 0x2019="'"; 0x201B="'"; 0x2032="'"; 0x00B4="'"; 0x02BC="'"
        0x201C='"'; 0x201D='"'; 0x201E='"'; 0x00AB='"'; 0x00BB='"'
        0x2010="-"; 0x2011="-"; 0x2012="-"; 0x2013="-"; 0x2014="-"; 0x2212="-"
        0x2026="..."
        0x00A0=" "; 0x2007=" "; 0x202F=" "
        0x2022=" "; 0x00B7=" "
        0x00B0=' deg'; 0x00B5='u'; 0x00B1='+/-'; 0x00D7='x'; 0x00F7='/'
        0x00A3="GBP";   # £
        0x00A5="Yen";   # ¥
        0x00A2="cent";  # ¢
        0x0192="fl";    # ƒ (florin)
        0x20A7="Pts";   # ₧ (peseta)
        0x20AC="EUR";   # €

    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Cleanup-Whitespace([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $s = $s.Trim()
    return [regex]::Replace($s, "\s+", " ")
}

function Ensure-TrailingSpace([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Ensure the string ends with exactly one space so a prefix never "sticks" to the artist.
    # Callers must already have applied final-pass cleanup and the length limit for the text core.
    $t = $s.TrimEnd()
    return ($t + " ")
}

function Ensure-SurroundingSpaces([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Connector output is meant for direct sequencing between artist and title.
    # Emit exactly one leading and one trailing space around the processed connector core.
    return (" " + $s.Trim() + " ")
}

function Cleanup-DanglingArtistSeparators([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # When non-Latin parts are filtered away (e.g. transliteration disabled), join tokens like "&" can be left behind.
    # This function removes separators that no longer separate two visible artist tokens, while preserving meaningful text.
    $t = Cleanup-Whitespace $s

    # If a separator is directly followed by a parenthesized token, treat it as an artist token:
    # remove the parentheses but keep the separator.
    # Example: "Ira Champion & (Blondy)" -> "Ira Champion & Blondy"
    $t = [regex]::Replace($t, "(\s*(?:&|,|/|\+)\s*)\(\s*([^\)]+?)\s*\)", '$1$2')

    # Remove leading / trailing separators.
    $t = [regex]::Replace($t, "^\s*(?:&|,|/|\+)\s*", "")
    $t = [regex]::Replace($t, "\s*(?:&|,|/|\+)\s*$", "")

    # Also remove a dangling dash separator at the start/end (e.g. "Prince -" after stripping "(EAC)").
    # Only affects standalone dash tokens (surrounded by whitespace), not hyphenated names like "AC-DC".
    $t = [regex]::Replace($t, "^\s*(?:-|–|—|−)\s+", "")
    $t = [regex]::Replace($t, "\s+(?:-|–|—|−)\s*$", "")

    return (Cleanup-Whitespace $t)
}

function Remove-ArtistAcronymSuffix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return "" }

    # Safely strip a trailing acronym that is merely an abbreviation of the artist name.
    # Examples:
    # - "Creedence Clearwater Revival (CCR)" -> "Creedence Clearwater Revival"
    # - "Bachman-Turner Overdrive (BTO)"     -> "Bachman-Turner Overdrive"
    # - "Creedence Clearwater Revival (C.C.R.)" -> "Creedence Clearwater Revival"
    #
    # Safety rules:
    # - Only acts on a *final* acronym token at the end of the artist field: "(...)", "[...]", "{...}" or a dash-separated suffix (" - ...").
    # - The abbreviation must be 2..6 letters (dots/spaces are allowed but ignored for the comparison).
    # - The abbreviation must match the initials (acronym) derived from the visible artist name.

    $t = Cleanup-Whitespace $artist

    # If the artist field contains multiple artists separated by "&", try stripping an acronym suffix
    # from the *last* artist only (e.g. "Olivia Newton-John & Electric Light Orchestra (ELO)").
    # This stays safe because the suffix must still match initials of that specific artist segment.
    $multi = [regex]::Match($t, '^(?<left>.+?)(?<sep>\s*&\s*)(?<right>[^&]+)$')
    if ($multi.Success) {
        $left  = Cleanup-Whitespace $multi.Groups["left"].Value
        $sep   = $multi.Groups["sep"].Value
        $right = Cleanup-Whitespace $multi.Groups["right"].Value

        $rightStripped = Remove-ArtistAcronymSuffix $right
        if ($rightStripped -ne $right) {
            return ($left + $sep + $rightStripped)
        }
    }

    # Accept common trailing abbreviation notations:
    # - "(ABBR)", "[ABBR]", "{ABBR}" at the very end of the artist field.
    # - " - ABBR" / " – ABBR" / " — ABBR" / " − ABBR" (dash-separated suffix), but only when separated by spaces.

    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<abbr>[^)]+?)\s*\)|\[\s*(?<abbr>[^\]]+?)\s*\]|\{\s*(?<abbr>[^}]+?)\s*\})\s*$')
    if (-not $m.Success) {
        $m = [regex]::Match($t, '^(?<name>.+?)\s+(?:-|–|—|−)\s+(?<abbr>.+?)\s*$')
    }
    if (-not $m.Success) { return $t }

    $name = Cleanup-Whitespace $m.Groups["name"].Value
    $abbr = Cleanup-Whitespace $m.Groups["abbr"].Value

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($abbr)) { return $t }

    # Normalize the abbreviation: keep only letters, and remove dot-separated styles (e.g. "C.C.R.").
    $abbrKey = [regex]::Replace($abbr.ToUpperInvariant(), '[^A-Z]', '')
    if ($abbrKey.Length -lt 2 -or $abbrKey.Length -gt 6) { return $t }

    # Build an acronym from the artist name:
    # - Split on spaces and hyphens.
    # - Take the first letter of each token that starts with a letter.
    $nameNorm = [regex]::Replace($name, "[\u2010-\u2015\u2212]", "-")
    $tokens   = [regex]::Split($nameNorm, '[\s\-]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    # Common stopwords that are typically not included in band acronyms (e.g. "Orchestral Manoeuvres In The Dark" -> OMD).
    # Keep this list intentionally conservative; the abbreviation must still match exactly, so this is safe by design.
    $stopWords = @(
    "A","AN","AND","THE","IN","OF","TO","FOR","ON","AT","BY","FROM","WITH",
    "DE","DA","DI","LA","LE","EL","LOS","LAS","DER","DIE","DAS","DEN","UND","ET","EN"
    )

    $initialsAll    = New-Object System.Text.StringBuilder
    $initialsNoStop = New-Object System.Text.StringBuilder

    foreach ($tok in $tokens) {
        $c = $tok.Trim()
        if ($c.Length -lt 1) { continue }

        $first = $c.Substring(0,1)
        if ($first -notmatch '^[A-Za-z]$') { continue }

        $uFirst = $first.ToUpperInvariant()
        [void]$initialsAll.Append($uFirst)

        $uTok = $c.ToUpperInvariant()
        if ($stopWords -contains $uTok) { continue }
        [void]$initialsNoStop.Append($uFirst)
    }

    $nameKeyAll    = $initialsAll.ToString()
    $nameKeyNoStop = $initialsNoStop.ToString()

    if ($nameKeyAll.Length -lt 2 -or $nameKeyAll.Length -gt 10) { return $t }

    if ($abbrKey -eq $nameKeyAll -or ($nameKeyNoStop.Length -ge 2 -and $abbrKey -eq $nameKeyNoStop)) {
        return $name
    }

    return $t
}

function AsciiSafe-FinalPass([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Final output pass for "ASCII-safe" mode:
    # - Remove control characters and invisible format characters.
    # - Strip diacritics (e.g., "é" -> "e") and map a small set of Latin letters that do not decompose cleanly.
    # - Keep *only* printable ISO-646 ASCII (0x20..0x7E), as this mode is meant to be fully diacritic-free.

    $t = $s

    # Strip ASCII control characters.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", "")

    # Strip common invisible / zero-width format chars (explicit ranges; avoids embedding invisible literals in source).
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")

    # Remove standalone empty bracket tokens (e.g., "[]", "( )", "{ }", "< >") without touching bracketed content.
    # This only removes tokens that are isolated by whitespace (or string edges), so "Song (Live)" remains intact.
    $t = [regex]::Replace($t, '(?<!\S)[\[\(\{\<]\s*[\]\)\}\>](?!\S)', '')

    # Normalize to decomposed form so diacritics become combining marks, then remove those marks.
    try { $t = $t.Normalize([Text.NormalizationForm]::FormD) } catch { }
    $t = [regex]::Replace($t, "\p{M}+", "")

    # Map a few Latin letters that are commonly encountered but do not decompose into ASCII base letters.
    # (This keeps the behavior predictable in ASCII-safe mode.)
    $t = $t.Replace("ß", "ss").Replace("ẞ", "SS")
    $t = $t.Replace("Æ", "AE").Replace("æ", "ae")
    $t = $t.Replace("Œ", "OE").Replace("œ", "oe")
    $t = $t.Replace("Ø", "O").Replace("ø", "o")
    $t = $t.Replace("Ð", "D").Replace("ð", "d")
    $t = $t.Replace("Þ", "TH").Replace("þ", "th")
    $t = $t.Replace("Ł", "L").Replace("ł", "l")

    $t = $t.Replace("Đ", "D").Replace("đ", "d")
    $t = $t.Replace("Ĳ", "IJ").Replace("ĳ", "ij")
    $t = $t.Replace("Ǆ", "DZ").Replace("ǅ", "Dz").Replace("ǆ", "dz")
    $t = $t.Replace("Ǉ", "LJ").Replace("ǈ", "Lj").Replace("ǉ", "lj")
    $t = $t.Replace("Ǌ", "NJ").Replace("ǋ", "Nj").Replace("ǌ", "nj")
    $t = $t.Replace("ı", "i")

    # Normalize common Unicode punctuation to ASCII equivalents (helps avoid losing dashes/quotes in ASCII-safe mode).
    $t = $t.Replace("–", "-").Replace("—", "-").Replace("−", "-")
    $t = $t.Replace('’','''').Replace('‘','''').Replace('“','"').Replace('”','"')

    # Keep only printable ASCII.
    $t = [regex]::Replace($t, "[^\x20-\x7E]", "")

    return (Cleanup-Whitespace $t)
}

function UnicodeSafe-FinalPass([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Unicode-safe output pass (used when transliteration is OFF):
    # - Keep Unicode letters/symbols (including Greek/Cyrillic), because the user explicitly disabled transliteration.
    # - Still strip ASCII control chars and invisible/format characters that may upset parsers or receivers.
    # - Normalize whitespace.
    $t = $s

    # Strip ASCII control characters.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", "")

    # Strip common invisible / zero-width format chars and private-use code points.
    # Private-use characters are also used internally as a temporary RT+ field marker and must never be emitted.
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")
    $t = [regex]::Replace($t, "\p{Co}+", "")

    # Remove standalone empty bracket tokens.
    $t = [regex]::Replace($t, '(?<!\S)[\[\(\{\<]\s*[\]\)\}\>](?!\S)', '')

    return (Cleanup-Whitespace $t)
}

function Transliterate-Cyrillic([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Cyrillic to Latin transliteration (broad coverage: Russian + common East/South Slavic letters).
    # This is intentionally ASCII-only to keep downstream RDS filtering predictable.

    $map = @{
        # Russian base
        0x0410="A";0x0411="B";0x0412="V";0x0413="G";0x0414="D";0x0415="E";0x0401="Yo";0x0416="Zh";0x0417="Z";0x0418="I";0x0419="Y";0x041A="K";0x041B="L";0x041C="M";0x041D="N";0x041E="O";0x041F="P";0x0420="R";0x0421="S";0x0422="T";0x0423="U";0x0424="F";0x0425="Kh";0x0426="Ts";0x0427="Ch";0x0428="Sh";0x0429="Shch";0x042A="";0x042B="Y";0x042C="";0x042D="E";0x042E="Yu";0x042F="Ya";
        0x0430="a";0x0431="b";0x0432="v";0x0433="g";0x0434="d";0x0435="e";0x0451="yo";0x0436="zh";0x0437="z";0x0438="i";0x0439="y";0x043A="k";0x043B="l";0x043C="m";0x043D="n";0x043E="o";0x043F="p";0x0440="r";0x0441="s";0x0442="t";0x0443="u";0x0444="f";0x0445="kh";0x0446="ts";0x0447="ch";0x0448="sh";0x0449="shch";0x044A="";0x044B="y";0x044C="";0x044D="e";0x044E="yu";0x044F="ya";

        # Ukrainian / Belarusian / common extended letters
        0x0404="Ye";0x0454="ye"; # Є
        0x0406="I";0x0456="i";   # І
        0x0407="Yi";0x0457="yi"; # Ї
        0x0490="G";0x0491="g";   # Ґ
        0x040E="U";0x045E="u";   # Ў (Belarusian)

        # Serbian/Macedonian (and related)
        0x0402="Dj";0x0452="dj"; # Ђ
        0x0403="Gj";0x0453="gj"; # Ѓ
        0x0405="Dz";0x0455="dz"; # Ѕ
        0x0408="J"; 0x0458="j";  # Ј
        0x0409="Lj";0x0459="lj"; # Љ
        0x040A="Nj";0x045A="nj"; # Њ
        0x040B="C"; 0x045B="c";  # Ћ
        0x040C="Kj";0x045C="kj"; # Ќ
        0x040F="Dzh";0x045F="dzh" # Џ
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }

    return $sb.ToString()
}

function Transliterate-Greek([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Greek to Latin transliteration.
    # Important: handle precomposed accented vowels (tonos/dialytika) and common digraphs first.
    # This avoids dropping vowels when later filtering removes non-Latin characters.

    $t = $s
    # Common digraphs (minimal, predictable set; processed before single-letter mapping).
    # Note: PowerShell hashtables are case-insensitive by default, so we must use an Ordinal comparer
    # to keep Greek casing variants as distinct keys.
    $digraphs = [hashtable]::new([System.StringComparer]::Ordinal)

    $digraphs['αι'] = 'ai'; $digraphs['Αι'] = 'Ai'; $digraphs['ΑΙ'] = 'AI'
    $digraphs['ει'] = 'ei'; $digraphs['Ει'] = 'Ei'; $digraphs['ΕΙ'] = 'EI'
    $digraphs['οι'] = 'oi'; $digraphs['Οι'] = 'Oi'; $digraphs['ΟΙ'] = 'OI'
    $digraphs['ου'] = 'ou'; $digraphs['Ου'] = 'Ou'; $digraphs['ΟΥ'] = 'OU'
    $digraphs['ευ'] = 'eu'; $digraphs['Ευ'] = 'Eu'; $digraphs['ΕΥ'] = 'EU'
    $digraphs['αυ'] = 'au'; $digraphs['Αυ'] = 'Au'; $digraphs['ΑΥ'] = 'AU'

    $digraphs['Στ'] = 'St'; $digraphs['στ'] = 'st'; $digraphs['ΣΤ'] = 'ST'
    $digraphs['Τσ'] = 'Ts'; $digraphs['τσ'] = 'ts'; $digraphs['ΤΣ'] = 'TS'
    $digraphs['Τζ'] = 'Tz'; $digraphs['τζ'] = 'tz'; $digraphs['ΤΖ'] = 'TZ'
    $digraphs['Γκ'] = 'Gk'; $digraphs['γκ'] = 'gk'; $digraphs['ΓΚ'] = 'GK'
    $digraphs['Ντ'] = 'Nt'; $digraphs['ντ'] = 'nt'; $digraphs['ΝΤ'] = 'NT'
    $digraphs['Μπ'] = 'Mp'; $digraphs['μπ'] = 'mp'; $digraphs['ΜΠ'] = 'MP'
    foreach ($k in $digraphs.Keys) {
        $t = $t.Replace($k, $digraphs[$k])
    }

    $map = @{
        # Uppercase
        0x0391="A";0x0392="V";0x0393="G";0x0394="D";0x0395="E";0x0396="Z";0x0397="I";0x0398="Th";0x0399="I";0x039A="K";0x039B="L";0x039C="M";0x039D="N";0x039E="X";0x039F="O";0x03A0="P";0x03A1="R";0x03A3="S";0x03A4="T";0x03A5="Y";0x03A6="F";0x03A7="Ch";0x03A8="Ps";0x03A9="O";

        # Lowercase
        0x03B1="a";0x03B2="v";0x03B3="g";0x03B4="d";0x03B5="e";0x03B6="z";0x03B7="i";0x03B8="th";0x03B9="i";0x03BA="k";0x03BB="l";0x03BC="m";0x03BD="n";0x03BE="x";0x03BF="o";0x03C0="p";0x03C1="r";0x03C3="s";0x03C2="s";0x03C4="t";0x03C5="y";0x03C6="f";0x03C7="ch";0x03C8="ps";0x03C9="o";

        # Precomposed tonos vowels (Greek and Coptic)
        0x0386="A";0x03AC="a"; # Ά ά
        0x0388="E";0x03AD="e"; # Έ έ
        0x0389="I";0x03AE="i"; # Ή ή
        0x038A="I";0x03AF="i"; # Ί ί
        0x038C="O";0x03CC="o"; # Ό ό
        0x038E="Y";0x03CD="y"; # Ύ ύ
        0x038F="O";0x03CE="o"; # Ώ ώ

        # Dialytika variants
        0x03AA="I";0x03CA="i"; # Ϊ ϊ
        0x03AB="Y";0x03CB="y"; # Ϋ ϋ
        0x0390="i";             # ΐ (iota with dialytika and tonos)
        0x03B0="y"              # ΰ (upsilon with dialytika and tonos)
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }

    return $sb.ToString()
}

function Filter-ToRdsLatin([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }

    # When transliteration is disabled, do NOT drop non-Latin scripts.
    # The toggle is meant to choose between (a) transliterating to Latin or (b) keeping the original script.
    if (-not $script:TransliterationEnabled) {
        return (UnicodeSafe-FinalPass $s)
    }

    # Transliteration is enabled: drop combining marks and keep a conservative "Latin-ish" repertoire.
    $t = [regex]::Replace($s, "\p{M}+", "")
    $t = [regex]::Replace($t, "[^\x20-\x7E\u00A1-\u00FF\u0100-\u017F\u0180-\u024F]", "")
    return (Cleanup-Whitespace $t)
}

# -------------------- Always-remove tag helpers -------------------------------

function Strip-EacTag([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Remove "(EAC)" or "[EAC]" anywhere (case-insensitive), including surrounding whitespace.
    $t = [regex]::Replace($s, "\s*[\(\[]\s*EAC\s*[\)\]]\s*", " ", "IgnoreCase")
    return (Cleanup-Whitespace $t)
}

function Is-AlwaysRemoveTagToken([string]$token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return $false }

    $t = (Cleanup-Whitespace $token).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }

    # Primary always-remove allowlist (strict).
    if ($t -match '^(?i)(?:EAC|Exact\s+Audio\s+Copy|ReplayGain|MP3Gain|AACGain|Sound\s*Check|SoundCheck|Normalized|Normalised|Normalization|Normalisation)$') { return $true }

    # Common encoders / rippers / taggers (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:LAME(?:\s*MP3\s*Encoder)?(?:\s*\d+(?:\.\d+)*)?|Fraunhofer|iTunes|XLD|CDex|dBpoweramp|MediaMonkey|MusicBrainz(?:\s+Picard)?|Picard|Spotify|Apple\s+Music|Amazon\s+Music|YouTube\s+Music|SoundCloud|Deezer|TIDAL|Bandcamp)$') { return $true }

    # DJ / library tools (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:Serato(?:\s+Edit)?|Traktor|Rekordbox|VirtualDJ|Mixxx|Pioneer\s*DJ)$') { return $true }

    # Scene / release-ish markers (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:WEB(?:-DL)?|WEBRIP|CDRIP|CD\s*RIP|PROMO|ADVANCE|RETAIL|SCENE|VINYL\s*RIP|CASSETTE\s*RIP)$') { return $true }

    # Technical/container/bitrate tokens (remove only when the token is clearly "format noise").
    # Examples: "MP3 320", "320kbps", "V0", "CBR", "FLAC", "24bit 96kHz", "Hi-Res"
    if ($t -match '^(?i)(?:MP3|MP4|FLAC|WAV|AAC|OGG|OPUS|M4A|WMA|ALAC|AIFF)(?:[\s\-\._]*(?:\d{2,3}\s*kbps|\d{2,3}k|V0|V1|V2|CBR|VBR|ABR|LOSSLESS|HI-?RES|24\s*BIT|16\s*BIT|\d{2,3}(?:\.\d+)?\s*K?HZ))*$') { return $true }
    if ($t -match '^(?i)(?:\d{2,3}\s*kbps|\d{2,3}k|V0|V1|V2|CBR|VBR|ABR|LOSSLESS|HI-?RES|24\s*BIT|16\s*BIT|\d{2,3}(?:\.\d+)?\s*K?HZ)$') { return $true }

    return $false
}

function Strip-AlwaysRemoveNoiseTags([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Keep the explicit EAC behavior intact (historical behavior).
    $t = Strip-EacTag $s

    # Remove always-remove tokens if they occur as isolated bracketed groups: "(...)" "[...]" "{...}".
    # This is intentionally conservative to avoid false positives in real titles.
    $pattern = '\s*[\(\[\{]\s*(?<tok>[^\)\]\}]{1,48})\s*[\)\]\}]\s*'

    $changed = $true
    while ($changed) {
        $changed = $false
        $t2      = [regex]::Replace($t, $pattern, {
            param($m)

            $tok = $m.Groups['tok'].Value
            if (Is-AlwaysRemoveTagToken $tok) {
                $script:__stripChanged = $true
                return ' '
            }
            return $m.Value
        }, "CultureInvariant")

        if ($script:__stripChanged) {
            $script:__stripChanged = $false
            $t                     = $t2
            $changed               = $true
        }
    }

    return (Cleanup-Whitespace $t)
}

# -------------------- Track number / filename parsing helpers -----------------

function Strip-TrackNumberPrefix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove common track number prefixes: "03. ", "03 - ", "(03) ", "[03] ", "03: ", etc.
    $t2 = [regex]::Replace(
    $t,
    "^\s*(?:\(\s*)?(?:\[\s*)?\d{1,3}(?:\s*\])?(?:\s*\))?\s*[\.\-_:)\]]\s+",
    "",
    "CultureInvariant"
    )

    if ($t2 -and $t2 -ne $t) { return $t2.Trim() }
    return $t
}

function Strip-TrackNumberPrefixLoose([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Conservative:
    # Only strip a 2-digit prefix when it is clearly separated from the artist/title by an unambiguous delimiter.
    #
    # Accepted examples:
    #   "03. Artist"     "03 - Artist"     "03: Artist"
    #   "(03) Artist"    "[03] Artist"     "{03} Artist"
    #
    # Rejected examples (to avoid damaging legitimate artist names):
    #   "50 Cent"        "77 Bombay Street"
    $m = [regex]::Match(
    $t,
    "^\s*(?:(?:\(\s*|\[\s*|\{\s*)?(?<n>\d{2})(?:\s*(?<closer>\)|\]|\}))\s+(?<next>.)|(?<n>\d{2})\s*(?<sep>[\.\-_:])\s+(?<next>.))",
    "CultureInvariant"
    )

    if (-not $m.Success) { return $t }

    $next = $m.Groups["next"].Value
    if (-not $next) { return $t }

    # Keep the first character by cutting from the 'next' group index.
    return $t.Substring($m.Groups["next"].Index).Trim()
}

# -------------------- Country-prefix stripping (title) -------------------------

# Some sources prepend a country/region label to the *title* field, e.g. "The Netherlands- Walk Along".
# This helper strips such a prefix conservatively:
# - Only acts when a recognized country name appears at the very start of the title.
# - Requires an immediate separator ("-", "–", "—", ":") followed by whitespace and real remaining content.
# - Country list is built from .NET cultures at runtime (English country names) and cached.
$script:_CountryPrefixRegex = $null
$script:_CountryAliases     = $null

function Get-CountryAliases() {
    if ($script:_CountryAliases) { return $script:_CountryAliases }

    # Legacy / alternate English country names and common metadata aliases.
    # This list is shared across:
    # - Title country-prefix stripping (e.g., "Belgium - Walk Along")
    # - Artist country/region suffix stripping (e.g., "Artist (Belgium)")
    $script:_CountryAliases = @(
    "UK",
    "U.K.",
    "Great Britain",
    "Britain",
    "USA",
    "U.S.A.",
    "US",
    "U.S.",
    "UAE",
    "U.A.E.",
    "Holland",
    "Czech Republic",
    "The Czech Republic",
    "Czechia",
    "F.Y.R. Macedonia",
    "FYR Macedonia",
    "North Macedonia",
    "Republic of North Macedonia",
    "Serbia & Montenegro",
    "Yugoslavia",
    "Russian Federation",
    "Byelorussia",
    "Türkiye",
    "Albanie",
    "Armenie"
    )

    return $script:_CountryAliases
}

function Get-CountryPrefixRegex() {
    if ($script:_CountryPrefixRegex) { return $script:_CountryPrefixRegex }

    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
            try {
                $ri = New-Object System.Globalization.RegionInfo($c.Name)
                if ($ri -and -not [string]::IsNullOrWhiteSpace($ri.EnglishName)) {
                    [void]$names.Add($ri.EnglishName.Trim())
                }
                if ($ri -and -not [string]::IsNullOrWhiteSpace($ri.TwoLetterISORegionName)) {
                    [void]$names.Add($ri.TwoLetterISORegionName.Trim())
                }
            } catch { }
        }
    } catch { }

    # Add a few common legacy/alternate English country names that RegionInfo may not emit on this system.
    foreach ($alias in (Get-CountryAliases)) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) { [void]$names.Add($alias.Trim()) }
    }

    foreach ($n in @("Netherlands","United States","United Kingdom","Czech Republic","Philippines","United Arab Emirates")) {
        if ($names.Contains($n)) { [void]$names.Add("The $n") }
    }

    $arr = @($names)
    # Prefer longer matches first (avoids partial matches when one name is a prefix of another).
    $arr = $arr | Sort-Object { $_.Length } -Descending

    $altsLong = @()
    $altsIso2 = @()
    foreach ($n in $arr) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $x = $n.Trim()

        # ISO2 codes are only stripped in an unmistakable metadata form (uppercase + clear separators).
        if ($x -match '^[A-Za-z]{2}$') {
            $altsIso2 += [regex]::Escape($x.ToUpperInvariant())
        } else {
            $altsLong += [regex]::Escape($x)
        }
    }

    if (($altsLong.Count + $altsIso2.Count) -eq 0) {
        # Fallback: nothing to match.
        $script:_CountryPrefixRegex = [regex]'(?!)'
        return $script:_CountryPrefixRegex
    }

    if ($altsLong.Count -gt 0 -and $altsIso2.Count -gt 0) {
        $pattern                    = "^(?:(?<cc>(?:$($altsLong -join '|')))\s*[-–—:]\s*(?<rest>.+)|(?<cc>(?-i:(?:$($altsIso2 -join '|'))))\s+[-–—:]\s+(?<rest>.+))$"
        $script:_CountryPrefixRegex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } elseif ($altsLong.Count -gt 0) {
        $pattern                    = "^(?<cc>(?:$($altsLong -join '|')))\s*[-–—:]\s*(?<rest>.+)$"
        $script:_CountryPrefixRegex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } else {
        $pattern                    = "^(?<cc>(?-i:(?:$($altsIso2 -join '|'))))\s+[-–—:]\s+(?<rest>.+)$"
        $script:_CountryPrefixRegex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $script:_CountryPrefixRegex
}

function Strip-CountryPrefix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Support bracketed country prefixes in titles, e.g. "(Belgium) Song" or "[F.Y.R. Macedonia] Track".
    # We only strip when the bracketed token is recognized as a country name/alias.
    if ($t -match '^\s*[\(\[\{]\s*(?<cc>[^\)\]\}]+?)\s*[\)\]\}]\s*(?<rest>.+)$') {
        $cc   = (Cleanup-Whitespace $matches['cc']).Trim()
        $rest = Cleanup-Whitespace $matches['rest']
        if (-not [string]::IsNullOrWhiteSpace($cc) -and (Test-IsCountryToken $cc)) {
            if (-not [string]::IsNullOrWhiteSpace($rest) -and ($rest -match '[\p{L}\p{N}]')) {
                return $rest
            }
        }
    }

    # Prefix form: "<country> - <title>" / "<country>: <title>"
    $rx = Get-CountryPrefixRegex
    $m  = $rx.Match($t)
    if (-not $m.Success) { return $t }

    $rest = Cleanup-Whitespace $m.Groups["rest"].Value
    if ([string]::IsNullOrWhiteSpace($rest)) { return $t }

    # Extra safety: only strip when something "title-like" remains (at least one letter or digit).
    if ($rest -notmatch '[\p{L}\p{N}]') { return $t }

    return $rest
}

function Strip-CountrySuffix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = Cleanup-Whitespace $s

    # Strip a trailing country/region tag that is clearly metadata and not part of the string.
    # Supported (end of field only):
    # - Bracketed suffixes:  "Title (Netherlands)", "Track [Belgium]", "Name {Japan}"
    # - Hyphen suffixes:     "Title - Netherlands", "Track – Belgium", "Name — Japan"
    # - Country/region codes (ISO2): "Title (US)", "Track [UK]", "Name {DE}"
    #
    # This is intentionally conservative: we only strip a *final* token at the end.

    Ensure-CountryData
    # --- 0) Event-style bracket suffixes with year + country: "(... 2010 - Finland)" ---
    # This is language-agnostic and intentionally conservative:
    # - must be a *trailing* bracket suffix ((), [], {})
    # - must contain a 4-digit year (19xx/20xx)
    # - must end with "- <country>" (dash can be -, – or —), where <country> is a known country token
    $m0 = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<tag>[^)]*?)\s*\)|\[\s*(?<tag>[^\]]*?)\s*\]|\{\s*(?<tag>[^}]*?)\s*\})\s*$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m0.Success) {
        $name0 = Cleanup-Whitespace $m0.Groups["name"].Value
        $tag0  = Cleanup-Whitespace $m0.Groups["tag"].Value

        if (-not [string]::IsNullOrWhiteSpace($name0) -and ($tag0 -match '\b(?:19|20)\d{2}\b')) {
            $parts = [regex]::Split($tag0, '\s*[-–—]\s*') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($parts.Count -ge 2) {
                $last = Cleanup-Whitespace $parts[$parts.Count - 1]
                if (Test-IsCountryToken $last) {
                    return $name0
                }
            }
        }
    }

    # --- 1) Two-letter country/region codes (ISO2) ---
    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<cc>[A-Z]{2})\s*\)|\[\s*(?<cc>[A-Z]{2})\s*\]|\{\s*(?<cc>[A-Z]{2})\s*\})\s*$')
    if ($m.Success) {
        $name = Cleanup-Whitespace $m.Groups["name"].Value
        $cc   = ($m.Groups["cc"].Value).ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($cc)) {
            if ($script:_CountryIso2Set.Contains($cc)) { return $name }
        }
        return $t
    }

    # --- 2) Bracketed suffixes: (Country) / [Country] / {Country} ---
    $m2 = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<tag>[^)\]]+?)\s*\)|\[\s*(?<tag>[^\]]+?)\s*\]|\{\s*(?<tag>[^}]+?)\s*\})\s*$')
    if ($m2.Success) {
        $name2 = Cleanup-Whitespace $m2.Groups["name"].Value
        $tag2  = Cleanup-Whitespace $m2.Groups["tag"].Value

        # Short ISO-style codes are only unambiguous when written entirely in uppercase.
        if ($tag2 -match '^[A-Za-z]{2,3}$' -and $tag2 -cne $tag2.ToUpperInvariant()) { return $t }

        if (-not [string]::IsNullOrWhiteSpace($name2) -and (Test-IsCountryToken $tag2)) {
            return $name2
        }
    }

    # --- 3) Hyphen/ndash/mdash suffixes: " - Country" / " – Country" / " — Country" ---
    # Require whitespace on both sides so hyphenated names such as "MO-DO" remain untouched.
    $m3 = [regex]::Match($t, '^(?<name>.+?)\s+[-–—]\s+(?<tag>[^-–—]+?)\s*$')
    if ($m3.Success) {
        $name3 = Cleanup-Whitespace $m3.Groups["name"].Value
        $tag3  = Cleanup-Whitespace $m3.Groups["tag"].Value

        if ($tag3 -match '^[A-Za-z]{2,3}$' -and $tag3 -cne $tag3.ToUpperInvariant()) { return $t }

        if (-not [string]::IsNullOrWhiteSpace($name3) -and (Test-IsCountryToken $tag3)) {
            return $name3
        }
    }

    return $t
}

function Is-TrackNumberOnly([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $t = $s.Trim()
    return [regex]::IsMatch($t, "^(?:\(\s*)?\d{1,3}(?:\s*\))?$|^(?:\[\s*)?\d{1,3}(?:\s*\])?$")
}

function Try-ParseArtistTitleFromFilename([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    $t = Cleanup-Whitespace $s
    $t = [regex]::Replace($t, "[\u2010-\u2015\u2212]", "-")

    $t = Strip-TrackNumberPrefix $t
    $t = Cleanup-Whitespace $t
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }

    # Pattern: "[Artist] Title" (and "(Artist) Title" / "{Artist} Title")
    # Allow an optional dash directly after the closing bracket so inputs like:
    #   "[Wow] - Keer Op Keer"
    # do not produce "Wow - - Keer Op Keer" after formatting.
    $m = [regex]::Match($t, "^\s*(?:\[(?<a>[^\[\]]+)\]|\((?<a>[^\(\)]+)\)|\{(?<a>[^\{\}]+)\})\s*(?:[-–—−]\s*)?(?<b>.+?)\s*$")
    if ($m.Success) {
        $a = Cleanup-Whitespace $m.Groups["a"].Value
        $b = Cleanup-Whitespace $m.Groups["b"].Value

        # Defensive: collapse any leading dash-run that may still be present.
        $b = [regex]::Replace($b, "^\s*(?:[-–—−]\s*)+", "")
        $b = Cleanup-Whitespace $b

        if ($a -and $b) { return [pscustomobject]@{ Artist = $a; Title = $b } }
    }

    # Pattern: "Artist - Title"
    $m = [regex]::Match($t, "^\s*(?<a>.+?)\s*-\s*(?<b>.+?)\s*$")
    if ($m.Success) {
        $a = Cleanup-Whitespace $m.Groups["a"].Value
        $b = Cleanup-Whitespace $m.Groups["b"].Value

        # If the title itself starts with a dash (e.g. "Artist - - Title"), collapse the run.
        $b = [regex]::Replace($b, "^\s*(?:[-–—−]\s*)+", "")
        $b = Cleanup-Whitespace $b

        if ($a -and $b) { return [pscustomobject]@{ Artist = $a; Title = $b } }
    }

    return $null
}

# -------------------- Identity / dedup helpers --------------------------------

function Normalize-IdentityKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    $t = $s.ToLowerInvariant()

    # Normalize to decomposed form so both "é" and "e◌́" compare identically.
    try { $t = $t.Normalize([Text.NormalizationForm]::FormD) } catch { }

    # Remove combining marks.
    $t = [regex]::Replace($t, "\p{M}+", "")

    # Normalize whitespace.
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    # Replace non letters/digits with spaces.
    $t = [regex]::Replace($t, "[^\p{L}\p{Nd}]+", " ")
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    return $t
}

function Normalize-NameKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    $t = $s

    # Drop bracketed qualifiers (conservative).
    $t = [regex]::Replace($t, "\s*[\(\[].*?[\)\]]\s*", " ").Trim()
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    # Drop common descriptive tails that should not affect identity matching.
    $t = [regex]::Replace($t, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()

    return (Normalize-IdentityKey $t)
}

function Get-ArtistNameKeys([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return $null }

    $a = Cleanup-Whitespace $artist

    # Use Regex.Split with explicit options (avoid PowerShell -split option quirks).
    $rx = New-Object System.Text.RegularExpressions.Regex(
    "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $parts = $rx.Split($a)

    $set = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $parts) {
        $name = Cleanup-Whitespace $p
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $key = Normalize-NameKey $name
        if (-not [string]::IsNullOrWhiteSpace($key)) { [void]$set.Add($key) }
    }

    return $set
}

function GuestIsAlreadyCreditedInArtist([string]$artist, [string]$guest) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($guest)) { return $false }

    $set = Get-ArtistNameKeys $artist
    if ($null -eq $set -or $set.Count -lt 1) { return $false }

    $g = Cleanup-Whitespace $guest
    $g = [regex]::Replace($g, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
    if ([string]::IsNullOrWhiteSpace($g)) { return $false }

    $gKey = Normalize-NameKey $g
    if ([string]::IsNullOrWhiteSpace($gKey)) { return $false }

    return $set.Contains($gKey)
}

function Strip-FeatInTitleIfGuestsAlreadyInArtist([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Case A: "(feat. X)" or "[feat. X]" at the very end.
    $patternBracket = "\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\b\s*(?<g>[^)\]]+?)\s*[\)\]]\s*$"

    # Case B: " feat. X" at the very end (no brackets).
    $patternBare = "\s+(?:feat\.?|ft\.?|featuring)\b\s*(?<g>.+?)\s*$"

    $m = [regex]::Match($title, $patternBracket, "IgnoreCase")
    if (-not $m.Success) { $m = [regex]::Match($title, $patternBare, "IgnoreCase") }
    if (-not $m.Success) { return $title }

    $guestRaw = Cleanup-Whitespace $m.Groups["g"].Value
    if ([string]::IsNullOrWhiteSpace($guestRaw)) { return $title }

    $gTokens = [regex]::Split(
    $guestRaw,
    "\s*(?:,|&|/|;|\+|\band\b)\s*",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($g in $gTokens) {
        $gg = Cleanup-Whitespace $g
        if (-not $gg) { return $title }

        $gg = [regex]::Replace($gg, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
        if (-not $gg) { return $title }

        if (-not (GuestIsAlreadyCreditedInArtist $artist $gg)) { return $title }
    }

    $head = $title.Substring(0, $m.Index).TrimEnd()
    return (Cleanup-Whitespace $head)
}

function Strip-WithInTitleIfGuestsAlreadyInArtist([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Match a trailing guest tail in the TITLE where the guest is already credited in the ARTIST field.
    # Supported forms (end-of-title only):
    # - "(with X)" / "[with X]"  (and localized variants)
    # - " - with X" (and localized variants)
    # Keywords: with, met, mit, con, avec, com, w/, &

    $pattern = "\s*(?:-\s*|[\(\[]\s*)(?:with|met|mit|con|avec|com|w\/|&)\s+(?<g>[^\)\]]+?)\s*(?:[\)\]]\s*)?$"

    $m = [regex]::Match($title, $pattern, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $guestRaw = Cleanup-Whitespace $m.Groups["g"].Value
    if ([string]::IsNullOrWhiteSpace($guestRaw)) { return $title }

    $gTokens = [regex]::Split(
    $guestRaw,
    "\s*(?:,|&|/|;|\+|\band\b)\s*",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($g in $gTokens) {
        $gg = Cleanup-Whitespace $g
        if (-not $gg) { return $title }

        $gg = [regex]::Replace($gg, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
        if (-not $gg) { return $title }

        if (-not (GuestIsAlreadyCreditedInArtist $artist $gg)) { return $title }
    }

    $head = $title.Substring(0, $m.Index).TrimEnd()
    return (Cleanup-Whitespace $head)
}

function Strip-ArtistDuplicateTitleTail([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Strip a trailing " - <artist>" (or " – <artist>" / " — <artist>") only if the tail matches a name
    # already credited in the ARTIST field. This prevents obvious duplicates like:
    # - "Song Title - The Melody Sisters"
    #
    # Intentionally conservative: only strips when the suffix matches an already-credited artist; allows optional whitespace around the dash.

    $pattern = "^(?<h>.+?)\s+[-–—]\s+(?<t>.+?)\s*$"
    $m       = [regex]::Match($title, $pattern, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $tail = Cleanup-Whitespace $m.Groups["t"].Value
    if ([string]::IsNullOrWhiteSpace($tail)) { return $title }

    if (-not (GuestIsAlreadyCreditedInArtist $artist $tail)) { return $title }

    $head = Cleanup-Whitespace $m.Groups["h"].Value
    return $head
}

function Strip-ArtistDuplicateTitlePrefix([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Strip a leading "<artist> - " (or with en-dash/em-dash variants) only if the prefix matches a name already credited
    # in the ARTIST field. This prevents obvious duplicates like:
    # - "The Melody Sisters - Dank Je Voor De Bloemen"
    # - "(The Melody Sisters) Dank Je Voor De Bloemen"
    #
    # Intentionally conservative: refuses prefixes that contain guest keywords (feat/with/etc.).
    # Allows optional whitespace around separators and optional bracket wrappers around the artist name.

    # 1) Bracket-wrapped artist prefix, optionally followed by a dash separator:
    #    "(Artist) Title", "[Artist] Title", "{Artist} Title", and also "(Artist)- Title", etc.
    $patternBracket = "^\s*[\(\[\{]\s*(?<p>[^\)\]\}]+?)\s*[\)\]\}]\s*(?:[-–—]\s*)?(?<r>.+?)\s*$"
    $mb             = [regex]::Match($title, $patternBracket, "IgnoreCase")
    if ($mb.Success) {
        $prefixB = Cleanup-Whitespace $mb.Groups["p"].Value
        if (-not [string]::IsNullOrWhiteSpace($prefixB)) {
            if (-not ([regex]::IsMatch($prefixB, "\b(?:feat\.?|ft\.?|featuring|with|met|mit|con|avec|com|w\/|&)\b", "IgnoreCase"))) {
                if (GuestIsAlreadyCreditedInArtist $artist $prefixB) {
                    $restB = Cleanup-Whitespace $mb.Groups["r"].Value
                    if (-not [string]::IsNullOrWhiteSpace($restB)) { return $restB }
                }
            }
        }
        return $title
    }

    # 2) Plain artist prefix with a required dash separator.
    $patternDash = "^(?<p>.+?)\s+[-–—]\s+(?<r>.+?)\s*$"
    $m           = [regex]::Match($title, $patternDash, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $prefix = Cleanup-Whitespace $m.Groups["p"].Value
    if ([string]::IsNullOrWhiteSpace($prefix)) { return $title }

    # Do not treat "Artist feat/with Guest - Title" as an artist-duplicate prefix.
    if ([regex]::IsMatch($prefix, "\b(?:feat\.?|ft\.?|featuring|with|met|mit|con|avec|com|w\/|&)\b", "IgnoreCase")) {
        return $title
    }

    if (-not (GuestIsAlreadyCreditedInArtist $artist $prefix)) { return $title }

    $rest = Cleanup-Whitespace $m.Groups["r"].Value
    if ([string]::IsNullOrWhiteSpace($rest)) { return $title }

    return $rest
}

function Unwrap-EnclosingArtistBrackets([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # If the entire artist token is wrapped in (), [] or {}, unwrap it.
    # This is conservative and repeats a few times to handle nested wrapping like "[[Artist]]".
    $t = $s.Trim()

    for ($i = 0; $i -lt 3; $i++) {
        $m = [regex]::Match($t, '^\s*(?<open>[\(\[\{])\s*(?<inner>.*?)\s*(?<close>[\)\]\}])\s*$', 'CultureInvariant')
        if (-not $m.Success) { break }

        $open  = $m.Groups["open"].Value
        $close = $m.Groups["close"].Value
        $inner = $m.Groups["inner"].Value

        $pairOk = $false
        if ($open -eq '(' -and $close -eq ')') { $pairOk = $true }
        elseif ($open -eq '[' -and $close -eq ']') { $pairOk = $true }
        elseif ($open -eq '{' -and $close -eq '}') { $pairOk = $true }

        if (-not $pairOk) { break }

        $inner = $inner.Trim()
        if ([string]::IsNullOrWhiteSpace($inner)) { return "" }

        # Only unwrap when the inner text does not itself contain the same bracket type.
        # This prevents accidental unwrapping of strings like "[WAV] Artist [EAC]" where the outermost
        # characters happen to form a valid pair but the content clearly contains additional brackets.
        if ($open -eq '(' -and $close -eq ')' -and $inner -match '[\(\)]') { break }
        if ($open -eq '[' -and $close -eq ']' -and $inner -match '[\[\]]') { break }
        if ($open -eq '{' -and $close -eq '}' -and $inner -match '[\{\}]') { break }

        $t = $inner
    }

    return $t
}

function Get-CompareKey([string]$s) {
    return (Normalize-IdentityKey $s)
}

function Dedup-DuplicateTitle([string]$title) {
    if ([string]::IsNullOrWhiteSpace($title)) { return $title }

    $t     = Cleanup-Whitespace $title
    $parts = $t -split "\s-\s"
    if ($parts.Count -lt 2) { return $t }

    $left  = ($parts[0..($parts.Count - 2)] -join " - ").Trim()
    $right = $parts[$parts.Count - 1].Trim()

    $leftKey  = Get-CompareKey ([regex]::Replace($left, "\s*[\(\[].*?[\)\]]\s*$", "").Trim())
    $rightKey = Get-CompareKey ([regex]::Replace($right,"\s*[\(\[].*?[\)\]]\s*$", "").Trim())

    if ($leftKey -and ($leftKey -eq $rightKey)) { return $left }
    return $t
}

function Dedup-AdjacentCommaArtistPrefix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return $artist }

    # Adjacent comma duplicate: "A, A ..." -> "A ..." (very conservative).
    $a     = Cleanup-Whitespace $artist
    $comma = $a.IndexOf(',')
    if ($comma -lt 0) { return $a }

    $left = Cleanup-Whitespace ($a.Substring(0, $comma))
    $rest = Cleanup-Whitespace ($a.Substring($comma + 1))

    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($rest)) { return $a }

    # Full-segment duplicate: "A, A" -> "A" (safe; avoids false multi-artist truncation).
    $kLeft = Normalize-IdentityKey $left
    $kRest = Normalize-IdentityKey $rest
    if ($kLeft -and $kRest -and ($kLeft -eq $kRest)) {
        return $left
    }
    if ($left.Length -lt 3) { return $a }
    if (-not ($left -match "(\p{L}|\p{Nd})")) { return $a }

    # Extract the first credited artist token from the remainder.
    $m = [regex]::Match(
    $rest,
    "^(?<first>.+?)(?=\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*|$)",
    "IgnoreCase"
    )

    if (-not $m.Success) { return $a }

    $first = Cleanup-Whitespace $m.Groups["first"].Value
    if ([string]::IsNullOrWhiteSpace($first)) { return $a }

    $k1 = Normalize-NameKey $left
    $k2 = Normalize-NameKey $first

    if ($k1 -and $k2 -and ($k1 -eq $k2)) {
        return $rest
    }

    return $a
}

function Dedup-BracketedArtistPrefix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return $artist }
    # Conservative bracketed duplicate: "[Artist] Artist" -> "Artist"
    # Also accepts () and {} wrappers, but only when the bracketed prefix and the remaining
    # artist text normalize to the same credited name.
    $a = Cleanup-Whitespace $artist
    $m = [regex]::Match($a, '^\s*[\(\[\{]\s*(?<p>[^\)\]\}]+?)\s*[\)\]\}]\s+(?<r>.+?)\s*$', 'CultureInvariant')
    if (-not $m.Success) { return $a }
    $prefix = Cleanup-Whitespace $m.Groups["p"].Value
    $rest   = Cleanup-Whitespace $m.Groups["r"].Value
    if ([string]::IsNullOrWhiteSpace($prefix) -or [string]::IsNullOrWhiteSpace($rest)) { return $a }
    $k1 = Normalize-NameKey $prefix
    $k2 = Normalize-NameKey $rest
    if ($k1 -and $k2 -and ($k1 -eq $k2)) {
        return $rest
    }
    return $a
}
# -------------------- IO helpers ---------------------------------------------

function Read-TextRobust([string]$path) {
    for ($i = 0; $i -lt $ReadRetryCount; $i++) {
        try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop }
        catch {
            try { return Get-Content -LiteralPath $path -Raw -Encoding Default -ErrorAction Stop }
            catch { Wait-WithHeartbeat $ReadRetryDelayMs }
        }
    }
    return ""
}

function Read-NowPlayingStable([string]$path) {
    $maxWaitMs           = 1500
    $stepMs              = 50
    $tries               = [Math]::Max(1, [int]($maxWaitMs / $stepMs))
    $lastArtistOnlyRaw   = $null

    for ($i = 0; $i -lt $tries; $i++) {
        $raw = Read-TextRobust $path
        if ($null -eq $raw) { $raw = "" }

        $raw2 = ($raw -replace "^\uFEFF", "")
        $raw2 = $raw2.Trim()
        if ([string]::IsNullOrWhiteSpace($raw2)) { return "" }
        if ($raw2.IndexOf($SepChar) -lt 0) { return $raw }

        $parts = $raw2 -split [regex]::Escape($SepChar), 2
        if ($parts.Count -ge 2) {
            $a = $parts[0]
            $t = $parts[1]
            if (-not [string]::IsNullOrWhiteSpace($t)) { return $raw }
            if ([string]::IsNullOrWhiteSpace($a)) { return $raw }
            if ($null -ne $lastArtistOnlyRaw -and $raw -ceq $lastArtistOnlyRaw) { return $raw }

            $lastArtistOnlyRaw = $raw
            if ($i -lt ($tries - 1)) {
                Wait-WithHeartbeat $stepMs
                continue
            }
            return $raw
        }

        Wait-WithHeartbeat $stepMs
    }

    return (Read-TextRobust $path)
}

function Write-Utf8NoBomAtomic([string]$path, [string]$text, [string]$tmpName) {
    # Atomic UTF-8 (no BOM) write: write to temp file in same directory, then move over the destination.
    # Returns $true on success, $false on failure (and stores the error message in $script:LastWriteError).
    $script:LastWriteError = $null

    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $tmp = Join-Path $dir $tmpName

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
        Move-Item -Force -LiteralPath $tmp -Destination $path -ErrorAction Stop
        return $true
    } catch {
        try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null } } catch { }
        try { $script:LastWriteError = $_.Exception.Message } catch { $script:LastWriteError = "Write failed." }
        return $false
    }
}

function Write-OutputsAtomic(
    [string]$prefixText,
    [string]$artistText,
    [string]$connectorText,
    [string]$titleText,
    [string]$rtText,
    [string]$rtPlusText
) {
    # Writes are atomic per file, not transactionally atomic across the complete six-file set.
    # Return every failed label so the UI can identify individual files and keep them aligned.
    $script:LastWriteError = $null
    $errors                = New-Object 'System.Collections.Generic.List[string]'
    $failedLabels          = New-Object 'System.Collections.Generic.List[string]'

    $clearAll = [string]::IsNullOrEmpty($rtText)
    $writes = @(
        [pscustomobject]@{ Label = 'prefix';    Path = $PrefixFile;    Text = $(if ($clearAll) { '' } else { $prefixText });    Temp = '.prefix.tmp' }
        [pscustomobject]@{ Label = 'artist';    Path = $ArtistFile;    Text = $(if ($clearAll) { '' } else { $artistText });    Temp = '.artist.tmp' }
        [pscustomobject]@{ Label = 'connector'; Path = $ConnectorFile; Text = $(if ($clearAll) { '' } else { $connectorText }); Temp = '.connector.tmp' }
        [pscustomobject]@{ Label = 'title';     Path = $TitleFile;     Text = $(if ($clearAll) { '' } else { $titleText });     Temp = '.title.tmp' }
        [pscustomobject]@{ Label = 'RT';        Path = $OutFileRt;     Text = $(if ($clearAll) { '' } else { $rtText });        Temp = '.nowplaying_rt.tmp' }
        [pscustomobject]@{ Label = 'RT+';       Path = $OutFileRtPlus; Text = $(if ($clearAll) { '' } else { $rtPlusText });    Temp = '.nowplaying_rtplus.tmp' }
    )

    foreach ($write in $writes) {
        $ok = Write-Utf8NoBomAtomic $write.Path $write.Text $write.Temp
        if (-not $ok) {
            $message = $(if ([string]::IsNullOrWhiteSpace($script:LastWriteError)) { 'Write failed.' } else { $script:LastWriteError })
            [void]$failedLabels.Add([string]$write.Label)
            [void]$errors.Add(("{0}: {1}" -f $write.Label, $message))
        }
    }

    if ($errors.Count -gt 0) {
        $script:LastWriteError = ($errors -join '; ')
    } else {
        $script:LastWriteError = $null
    }

    return [pscustomobject]@{
        Success      = ($failedLabels.Count -eq 0)
        FailedLabels = @($failedLabels.ToArray())
        ErrorMessage = $script:LastWriteError
    }
}

function Publish-Outputs(
    [string]$prefixText,
    [string]$artistText,
    [string]$connectorText,
    [string]$titleText,
    [string]$rtText,
    [string]$rtPlusText,
    [bool]$UpdateHeartbeatOnSuccess = $false
) {
    $result = Write-OutputsAtomic $prefixText $artistText $connectorText $titleText $rtText $rtPlusText

    if ($null -ne $result -and $result.Success) {
        $script:LastWriteFailures  = @{}
        $script:OutputRetryPending = $false
        $script:PendingOutputWrite = $null
        $script:NextOutputRetryUtc = [DateTime]::MinValue

        if ($UpdateHeartbeatOnSuccess) {
            $script:LastGoodUpdate = Get-Date
        }
    } else {
        $failures = @{}
        if ($null -ne $result) {
            foreach ($label in @($result.FailedLabels)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$label)) {
                    $failures[[string]$label] = $true
                }
            }
        }

        # A defensive fallback: an unexpected empty result still represents a failed publication.
        if ($failures.Count -eq 0) {
            foreach ($label in @('prefix', 'artist', 'connector', 'title', 'RT', 'RT+')) {
                $failures[$label] = $true
            }
        }

        $script:LastWriteFailures  = $failures
        $script:OutputRetryPending = $true
        $script:PendingOutputWrite = [pscustomobject]@{
            PrefixText                  = $prefixText
            ArtistText                  = $artistText
            ConnectorText               = $connectorText
            TitleText                   = $titleText
            RtText                      = $rtText
            RtPlusText                  = $rtPlusText
            UpdateHeartbeatOnSuccess    = $UpdateHeartbeatOnSuccess
        }
        $script:NextOutputRetryUtc = [DateTime]::UtcNow.AddSeconds($script:OutputRetryIntervalSec)
    }

    if ($script:UiInited -and -not $script:UiOverlayActive) {
        try { Write-HeaderFileRows } catch { }
    }

    return $result
}

function Retry-PendingOutputsIfDue {
    if (-not $script:OutputRetryPending -or $null -eq $script:PendingOutputWrite) { return $false }
    if ([DateTime]::UtcNow -lt $script:NextOutputRetryUtc) { return $false }

    $pending = $script:PendingOutputWrite
    [void](Publish-Outputs `
        $pending.PrefixText `
        $pending.ArtistText `
        $pending.ConnectorText `
        $pending.TitleText `
        $pending.RtText `
        $pending.RtPlusText `
        ([bool]$pending.UpdateHeartbeatOnSuccess)
    )

    # Publish-Outputs refreshes only the FILES rows, so recovered warnings disappear
    # immediately while the CONTENT block remains completely unchanged.

    return $true
}

function Hard-TruncateFileUtf8NoBom([string]$path) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $fs = $null
    $sw = $null
    try {
        $fs = New-Object System.IO.FileStream(
        $path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
        )
        $sw = New-Object System.IO.StreamWriter($fs, $utf8NoBom)
        $sw.Write("")
        $sw.Flush()
    } finally {
        if ($sw) { $sw.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

function Clear-OutputsFast([bool]$TrackFailures = $false) {
    if ($TrackFailures) {
        # At startup, use the normal publication path so failed clears are visible and retried.
        [void](Publish-Outputs "" "" "" "" "" "" $false)
        return
    }

    # Shutdown is best-effort: the main loop has ended, so no retry can still be performed.
    try { Hard-TruncateFileUtf8NoBom $PrefixFile } catch { }
    try { Hard-TruncateFileUtf8NoBom $ArtistFile } catch { }
    try { Hard-TruncateFileUtf8NoBom $ConnectorFile } catch { }
    try { Hard-TruncateFileUtf8NoBom $TitleFile } catch { }
    try { Hard-TruncateFileUtf8NoBom $OutFileRt } catch { }
    try { Hard-TruncateFileUtf8NoBom $OutFileRtPlus } catch { }
}

# -------------------- Content fixes ------------------------------------------

function Fix-ApostropheSuffixCase([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $chars = $s.ToCharArray()
    for ($i = 0; $i -lt ($chars.Length - 1); $i++) {
        if ($chars[$i] -ne "'") { continue }
        $next = $chars[$i + 1]
        if (-not [char]::IsUpper($next)) { continue }

        $afterIndex = $i + 2
        if ($afterIndex -lt $chars.Length) {
            $after = $chars[$afterIndex]
            if ([char]::IsLower($after)) { continue }
        }
        $chars[$i + 1] = [char]::ToLowerInvariant($next)
    }
    return -join $chars
}

function Strip-Trailing-Brackets([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Under length pressure, we normally drop a trailing bracket group to save space.
    # However, for acronym-style titles we prefer keeping the descriptive expansion.
    # Example:
    #   "T.S.O.P. (The Sound Of Philadelphia)" -> "The Sound Of Philadelphia"
    # This is intentionally conservative and only triggers when:
    # - The bracket group is trailing, and
    # - The head looks like a short all-caps acronym (optionally dotted), and
    # - The bracket content looks like a real title (contains letters and a space).
    $t = $s.Trim()
    $m = [regex]::Match($t, '^(?<head>.+?)\s*[\(\[]\s*(?<inner>[^)\]]+?)\s*[\)\]]\s*$', 'IgnoreCase')
    if ($m.Success) {
        $head  = ($m.Groups['head'].Value).Trim()
        $inner = ($m.Groups['inner'].Value).Trim()

        if (-not [string]::IsNullOrWhiteSpace($head) -and -not [string]::IsNullOrWhiteSpace($inner)) {
            $innerHasWords = ($inner -match '(\p{L}|\p{Nd})') -and ($inner -match '\s')
            if ($innerHasWords) {
                $headCompact = [regex]::Replace($head, '\s+', '')
                $headNoDots  = [regex]::Replace($headCompact, '\.', '')

                $isAcronymDotted = ($headCompact -match '^[A-Z0-9\.]{2,15}$') -and ($headCompact -match '\.') -and ($headNoDots -match '^[A-Z0-9]{2,8}$')
                $isAcronymPlain  = ($headNoDots -match '^[A-Z0-9]{2,6}$') -and ($headCompact -match '^[A-Z0-9\.]{2,8}$')

                if ($isAcronymDotted -or $isAcronymPlain) {
                    return $inner
                }
            }
        }
    }

    return ([regex]::Replace($t, "\s*[\(\[].*?[\)\]]\s*$", "")).Trim()
}

function Strip-FeatTail([string]$s) {
    return ([regex]::Replace($s, "(?:\s+|\s*[-–—]\s*)(feat\.?|ft\.?|featuring)\s+.*$", "", "IgnoreCase")).Trim()
}

function Compact-FeatTailToAmp([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Ensure we don't match "feat" inside "featuring".
    $pattern = "\s*(?:[\(\[]\s*)?(?:(?:featuring)\b|(?:feat|ft)\.?\b)\s*(?<g>[^)\]]+?)(?:\s*[\)\]])?\s*$"
    $m       = [regex]::Match($s, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $s }

    $guest = $m.Groups["g"].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($guest)) { return $s }

    $head = $s.Substring(0, $m.Index).TrimEnd()
    return ("$head & $guest").Trim()
}

function Strip-SoundtrackTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Strip film/soundtrack context tails that are commonly appended after a strong separator.
    # This is intentionally conservative: it only triggers when the suffix starts with
    # explicit keywords such as "Theme from" or "From the film/motion picture/soundtrack".
    $sep = "(?:-|–|—)"

    $t1 = [regex]::Replace(
    $t,
    "\s*${sep}\s*(?:Theme\s+from)\s+(?:'[^']+'|""[^""]+""|[^\r\n]+?)\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t1 -ne $t -and -not [string]::IsNullOrWhiteSpace($t1)) { return $t1 }

    # Also strip parenthesized "Theme from ..." tails when they appear as a trailing bracket group,
    # e.g. "My Heart Will Go On (Love Theme From Titanic)". This only triggers at the very end.
    $t1b = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*(?:(?:Love|Main)\s+)?Theme\s+From\s+[^)\]]+[\)\]]\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t1b -ne $t -and -not [string]::IsNullOrWhiteSpace($t1b)) { return $t1b }

    $t1b = [regex]::Replace(
    $t,
    "\s*${sep}\s*(?:From\s+(?:the\s+)?(?:film|movie|motion\s+picture|soundtrack|original\s+soundtrack|original\s+motion\s+picture\s+soundtrack|ost))\b[^\r\n]*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t1b -ne $t -and -not [string]::IsNullOrWhiteSpace($t1b)) { return $t1b }

    $t2 = [regex]::Replace(
    $t,
    "\s*-\s*From\s+""[^""]+""\s*(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)?\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*[^)\]]*(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)\s*[^)\]]*[\)\]]\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    $t4 = [regex]::Replace(
    $t,
    "\s*-\s*.+\s+(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t4 -ne $t -and -not [string]::IsNullOrWhiteSpace($t4)) { return $t4 }

    return $t
}

function Strip-RemasterTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Multilingual "remaster" markers (kept conservative; only used for trailing suffix stripping).
    $remKw = "(?:remaster(?:ed)?|remasteris(?:e|é)(?:e|d)?|remasteriz(?:ed)?|remasterizad[oa]|remasterizat[oa]|remasterizzat[oa]|remasterisiert)"

    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    # Require whitespace around dash/colon separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-:]\s*|\s*[-:]\s+)"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*[^)\]]*\b$remKw\b[^)\]]*[\)\]]$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "$sepDash[^\r\n]*\b$remKw\b[^\r\n]*$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    $t4 = [regex]::Replace(
    $t,
    "\s*\b(?:\d{4}\s*)?(?:digital\s*)?\b$remKw\b$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t4 -ne $t -and -not [string]::IsNullOrWhiteSpace($t4)) { return $t4 }

    return $t
}

function Strip-LanguageTagTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove standalone language tags like "(Dutch)" that are typically metadata, not part of the title.
    # Conservative: only removes if the bracket content is exactly one language word, and only when it
    # appears at the end of the string or right before a clear separator tail (" - ...", " : ...").
    $langs = "(?:dutch|english|german|french|spanish|italian|portuguese|polish|czech|slovak|hungarian|swedish|norwegian|danish|finnish|icelandic|greek|turkish|arabic|hebrew|japanese|chinese|korean|russian|ukrainian)"
    $sep   = "(?:\s+[-–—:]\s+|\s+[-–—:]\s*|\s*[-–—:]\s+)"  # requires whitespace on at least one side

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*\b$langs\b\s*[\)\]](?=\s*$|$sep)",
    "",
    "IgnoreCase"
    ).Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-TitleWhitelistTails([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw      = "(?:deluxe\s+edition|bonus\s+track|album\s+version|explicit|clean)"
    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*[^)\]]*\b$kw\b[^)\]]*[\)\]]$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "\s*[-:]\s*[^\r\n]*\b$kw\b[^\r\n]*$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}

function Strip-CompilationTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove clearly separated compilation/album markers such as " - Greatest Hits (2009)".
    # This is deliberately conservative: it only strips a trailing segment when the marker is
    # introduced by a strong separator or enclosed in trailing brackets.
    $kw      = "(?:greatest\s+hits(?:\s+[A-Za-z0-9&'\.\-/]+){0,4}|the\s+hits(?:\s+\d{1,3})?|the\s+essential(?:\s+[A-Za-z0-9&'\.\-/]+){0,4}|(?:the\s+)?best\s+of(?:\s+[A-Za-z0-9&'\.\-/]+){0,4}|(?:the\s+)?very\s+best\s+of(?:\s+[A-Za-z0-9&'\.\-/]+){0,4}|(?:the\s+)?ultimate\s+collection)"
    $optYear = "(?:\s*(?:[\(\[]\s*)?(?:19|20)\d{2}(?:\s*[\)\]])?)?"
    $optTail = "(?:\s*[-,:/]\s*[A-Za-z0-9][^\r\n\)\]]{0,40})?"
    $sepDash = "(?:\s+[-:–—]\s*|\s*[-:–—]\s+)"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*\b$kw\b$optTail\s*[\)\]]$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "$sepDash\b$kw\b$optTail$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}

function Strip-SeparatedYearTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove a standalone trailing year only when it is clearly separated from the payload.
    # Examples:
    # - "Let's Dance [1972]" -> "Let's Dance"
    # - "Let's Dance - 1972" -> "Let's Dance"
    #
    # This is intentionally conservative: it does not strip years that are part of the actual
    # title text, such as "Summer of '69" or "Symphony No. 1999" style content without a
    # strong separator before the year.
    $year    = "(?:19|20)\d{2}"
    $sepDash = "(?:\s+[-:–—]\s*|\s*[-:–—]\s+)"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[\{]\s*$year\s*[\)\]\}]\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "$sepDash$year\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}

function Strip-VersionMixTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw      = "(?:radio\s+edit|edit|single\s+(?:version|versie|versión|versione|versao|versão)|extended\s+(?:mix|version|versie|versión|versione|versao|versão)|club\s+mix|dub(?:\s+mix)?|instrumental|acoustic|acoustical|remix|mix|version|versie|versión|versione|versao|versão)"
    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    # Require whitespace around dash/colon separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-:]\s*|\s*[-:]\s+)"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*[^)\]]*\b$kw\b[^)\]]*[\)\]]$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "$sepDash[^\r\n]*\b$kw\b[^\r\n]*$optYear\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}

function Strip-LowPriorityDashSuffix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Under length pressure, drop low-priority trailing context after a dash.
    # Examples:
    #   "Run to Me - Live @Ahoy"        -> "Run to Me"  (handled earlier; kept here as an example)
    #   "Song Title – Acoustic Session" -> "Song Title"
    # This is intentionally conservative: it only triggers when the suffix starts with a dash and a known keyword.
    $kw = "(?:live|acoustic|acoustical|acoustique|akustisch|unplugged|session|studio(?:\s*(?:version|versie|versión|versione|versao|versão))?)"
    $t2 = [regex]::Replace($t, "\s*[-–—]\s*\b$kw\b.*$", "", "IgnoreCase").Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveDashSuffixAlways([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Always drop trailing " - Live ..." style suffixes from titles.
    # Rationale: the listener can hear that a track is live; the suffix is usually low-value metadata.
    # Examples:
    #   "Run to Me - Live @Ahoy"        -> "Run to Me"
    #   "Song Title – Live at Wembley" -> "Song Title"
    #
    # This is intentionally narrow: it only triggers when "live" is introduced by a dash separator.
    $t2 = [regex]::Replace($t, "\s*[-–—]\s*(?:live|(?:mtv\s+)?unplugged)\b.*$", "", "IgnoreCase").Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveBracketSuffixAlways([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Always drop trailing "(Live ...)" or "[Live ...]" style suffixes from titles.
    # Rationale: the listener can hear that a track is live; the suffix is usually low-value metadata.
    #
    # Note: Some tags contain nested parentheses inside the Live tail, e.g. "(Live @Ahoy(2009))".
    # A plain "[^)]*" match would fail in that case, so we handle:
    #   - Square brackets with a simple (non-nested) match, and
    #   - Parentheses with a .NET balancing-group pattern that supports nesting.

    # Case 1: trailing "[Live ...]" (no nesting support needed).
    $t = [regex]::Replace(
    $t,
    "\s*\[\s*(?:live|(?:mtv\s+)?unplugged)\b[^\]]*\]\s*$",
    "",
    "IgnoreCase"
    )

    # Case 1b: trailing "{Live ...}" or "{Unplugged ...}" (no nesting support needed).
    $t = [regex]::Replace(
    $t,
    "\s*\{\s*(?:live|(?:mtv\s+)?unplugged)\b[^}]*\}\s*$",
    "",
    "IgnoreCase"
    )

    # Case 2: trailing "(Live ...)" with possible nested parentheses.
    $t = [regex]::Replace(
    $t,
    "\s*\(\s*(?:live|(?:mtv\s+)?unplugged)\b(?>[^()]+|\((?<d>)|\)(?<-d>))*(?(d)(?!))\)\s*$",
    "",
    "IgnoreCase"
    )

    return (Cleanup-Whitespace $t)
}

function Strip-MeaninglessTrailingSeparators([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Remove obvious junk at the end of a string, such as a trailing dash or list separator
    # left behind after other tail-stripping operations.
    # Examples:
    # - "Run to Me -"            -> "Run to Me"
    # - "Run to Me -  "          -> "Run to Me"
    # - "Artist &"               -> "Artist"
    # - "Title , "               -> "Title"
    #
    # This is intentionally conservative: it only strips if the tail consists solely of
    # separators and whitespace (no letters/digits).

    $t = Cleanup-Whitespace $s

    $t = [regex]::Replace($t, "\s*(?:[-–—,;:/\+\|&])+\s*$", "", "IgnoreCase")

    return (Cleanup-Whitespace $t)
}

function Strip-AudioFormatTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw = "(?:mono|stereo|stereo\s*mix|mono\s*mix)"

    $t2 = [regex]::Replace(
    $t,
    "\s*(?:[-|/]\s*)?(?:[\(\[]\s*)?\b$kw\b(?:\s*[\)\]])?\s*$",
    "",
    "IgnoreCase"
    ).Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveLocationTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Conservative stripping of trailing " - Live From/At/In ..." style suffixes.
    # Only strips when the suffix strongly looks like a venue/location tag (contains a year, comma, or slash).
    $year = "(?:19|20)\d{2}"
    $live = "(?:live\s+(?:from|at|in))"

    # Require whitespace around dash separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-–—]\s*|\s*[-–—]\s+)"

    $t2 = [regex]::Replace(
    $t,
    "\s*[\(\[]\s*[^)\]]*\b$live\b[^)\]]*(?:\b$year\b|[,/])[^)\]]*[\)\]]\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
    $t,
    "$sepDash\b$live\b\s+.*?(?:\b$year\b|[,/].*)\s*$",
    "",
    "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}
function WordCut([string]$text, [int]$limit) {
    if ([string]::IsNullOrWhiteSpace($text) -or $limit -le 0) { return "" }
    if ($text.Length -le $limit) { return $text }

    $cut       = Limit-TextLength $text $limit
    $lastSpace = $cut.LastIndexOf(" ")
    if ($lastSpace -ge 10) { $cut = $cut.Substring(0, $lastSpace) }
    return $cut.Trim(" ", "-", "_", ",", ";", ":")
}

function Best-TitleCut([string]$title, [int]$limit) {
    if ([string]::IsNullOrWhiteSpace($title)) { return "" }
    if ($limit -le 0) { return "" }
    if ($title.Length -le $limit) { return $title }

    $wc = WordCut $title $limit

    # When a very long unbroken token exists, WordCut may stop too early.
    # In that case, prefer a filled cut (mid-token) and let Trim-ForEllipsis
    # clean up the end before we add an ellipsis.
    $sub = Limit-TextLength $title $limit
    $sub = Trim-ForEllipsis $sub

    if (-not [string]::IsNullOrWhiteSpace($sub) -and $sub.Length -ge 8 -and $sub.Length -gt $wc.Length) {
        return $sub
    }

    return $wc
}

function Trim-ForEllipsis([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Remove trailing characters that are very unlikely to be a meaningful end of a title.
    # This intentionally strips whitespace, punctuation and symbols (slashes, dashes, quotes, etc.).
    $t = $s.TrimEnd()

    # If we ended up with a tiny fragment after a hard separator (e.g. " / Li"),
    # drop that fragment so we don't send a dangling tail before the ellipsis.
    # This is intentionally conservative and only targets the slash separator.
    $t = [regex]::Replace($t, "\s*/\s*[\p{L}\p{Nd}]{1,4}$", "").TrimEnd()
    # Also treat a strong dash tail (" - Mo") like a tiny fragment and drop it before ellipsis.
    $t = [regex]::Replace($t, "\s*(?:-|–|—)\s*[\p{L}\p{Nd}]{1,6}$", "").TrimEnd()
    $t = [regex]::Replace($t, "[\s\p{P}\p{S}]+$", "").TrimEnd()

    # Safety: never return an empty string here if there were any letters/digits.
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }
    return $t
}

function Looks-LikeMultiArtist([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return [regex]::IsMatch($s, "(?:,|&|/|\+|\band\b|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)", "IgnoreCase")
}

function Fit-ArtistPreserveTitle([string]$artistOriginal, [string]$artistCandidate, [string]$title, [int]$maxLen, [string]$joiner) {
    $artistOriginal  = Cleanup-Whitespace $artistOriginal
    $artistCandidate = Cleanup-Whitespace $artistCandidate
    $title           = Cleanup-Whitespace $title

    $multiOriginal = (Looks-LikeMultiArtist $artistOriginal)

    if (-not $artistCandidate -or -not $title) { return $null }

    $base = "$artistCandidate$joiner$title"
    if ($base.Length -le $maxLen) { return $base }

    # Preserve the full title and squeeze artist into the remaining budget.
    $roomForArtist = $maxLen - $joiner.Length - $title.Length
    if ($roomForArtist -lt 1) { return $null }

    # If preserving the full title would force us to cut even the first credited artist
    # mid-name, skip this strategy and let the later truncation logic shorten the title
    # instead (including graceful ellipsis inside long unbroken tokens).
    $minDesiredArtist = $null
    try {
        $rxFirst = New-Object System.Text.RegularExpressions.Regex(
        "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        foreach ($p in $rxFirst.Split($artistCandidate)) {
            $n = Cleanup-Whitespace $p
            if (-not [string]::IsNullOrWhiteSpace($n)) { $minDesiredArtist = $n; break }
        }
    } catch { $minDesiredArtist = $null }

    if (-not [string]::IsNullOrWhiteSpace($minDesiredArtist)) {
        # Only enforce the "do not cut the first credited artist" guard when the original artist
        # string actually contains multiple credited artists. For a single long artist name, it is
        # preferable to truncate on a word boundary to preserve the full title.
        if ($multiOriginal) {
            $minDesiredArtist = Cleanup-Whitespace $minDesiredArtist
            if ($roomForArtist -lt $minDesiredArtist.Length) {
                return $null
            }
        }
    }

    if ($artistCandidate.Length -gt $roomForArtist) {
        # Heuristic: if we can keep the full artist by truncating the title later, prefer that when
        # squeezing the artist would produce an awkward or misleading result (e.g. only initials, or
        # a cut surname like "Margot Frie...").
        $maxArtistIfTitleMin1 = $maxLen - $joiner.Length - 1
        if ($artistCandidate.Length -le $maxArtistIfTitleMin1) {
            $guardName = $minDesiredArtist
            if ([string]::IsNullOrWhiteSpace($guardName)) { $guardName = $artistCandidate }

            $tokens = @()
            try {
                foreach ($tok in ($guardName -split "\s+")) {
                    $t = Cleanup-Whitespace $tok
                    if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens += $t }
                }
            } catch { $tokens = @() }

            if ($tokens.Count -ge 2) {
                $firstTok         = $tokens[0]
                $lastTok          = $tokens[$tokens.Count - 1]
                $needForFirstLast = $firstTok.Length + 1 + $lastTok.Length

                # If we cannot keep both the first and last token in full, do not squeeze the artist here.
                if ($roomForArtist -lt $needForFirstLast) { return $null }
            }
        }
    }

    $artistBudget = $roomForArtist
    if ($artistBudget -lt 1) { return $null }

    # If multiple artists are credited and the artist field must be squeezed, retain the
    # largest possible set of complete names before falling back to the first name only.
    if ($multiOriginal) {
        $parts = @()
        try {
            $rxSplit = New-Object System.Text.RegularExpressions.Regex(
            "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            foreach ($p in $rxSplit.Split($artistCandidate)) {
                $n = Cleanup-Whitespace $p
                if (-not [string]::IsNullOrWhiteSpace($n)) { $parts += $n }
            }
        } catch { $parts = @() }

        if ($parts.Count -ge 2) {
            # Prefer the maximum number of complete names that still fits within the budget.
            for ($k = $parts.Count - 1; $k -ge 1; $k--) {
                $candidate = ($parts[0..($k - 1)] -join ", ")
                if ($candidate.Length -le $roomForArtist) {
                    $out = "$candidate$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
            }
        } elseif ($parts.Count -eq 1) {
            $first = $parts[0]
            if (-not [string]::IsNullOrWhiteSpace($first) -and $first.Length -le $roomForArtist) {
                $out = "$first$joiner$title"
                if ($out.Length -le $maxLen) { return $out }
            }
        }
    }

    $ellipsis = "..."
    $aCut     = $null
    if ($artistCandidate.Length -gt $artistBudget -and $artistBudget -gt ($ellipsis.Length + 5)) {
        $aCut = WordCut $artistCandidate ($artistBudget - $ellipsis.Length)
        $aCut = Trim-ForEllipsis $aCut
        if (-not [string]::IsNullOrWhiteSpace($aCut)) {
            $aCut = (Cleanup-Whitespace ($aCut + $ellipsis))
        }
    }
    if ([string]::IsNullOrWhiteSpace($aCut)) {
        $aCut = WordCut $artistCandidate $artistBudget
    }
    if ([string]::IsNullOrWhiteSpace($aCut)) { return $null }

    $out = "$aCut$joiner$title"
    if ($out.Length -le $maxLen) { return $out }

    return $null
}

function Smart-Truncate-Fields([string]$artist, [string]$title, [int]$maxLen, [string]$joiner) {
    if ($null -eq $artist) { $artist = "" }
    if ($null -eq $title)  { $title  = "" }

    $artist = $artist.Trim()
    $title  = $title.Trim()

    $base = ""
    if ($artist -and $title) { $base = "$artist$joiner$title" }
    elseif ($artist) { $base = $artist }
    else { $base = $title }

    if ($base.Length -le $maxLen) { return $base }

    # First attempt: compact trailing feat tails to "& Guest".
    $aC = Compact-FeatTailToAmp $artist
    $tC = Compact-FeatTailToAmp $title

    $baseC = ""
    if ($aC -and $tC) { $baseC = "$aC$joiner$tC" }
    elseif ($aC) { $baseC = $aC }
    else { $baseC = $tC }

    if ($baseC.Length -le $maxLen) { return $baseC }

    # Second attempt:
    # - For title: strip a trailing feat tail (if any).
    # - Do NOT remove bracketed subtitle tails here. Those can be meaningful (e.g. "(The Postman Song)"),
    #   and they should only be dropped as a late length-pressure fallback.
    # - For artist: do not strip anything at this stage.
    $a2 = $artist
    $t2 = Strip-FeatTail $title

    $base2 = ""
    if ($a2 -and $t2) { $base2 = "$a2$joiner$t2" }
    elseif ($a2) { $base2 = $a2 }
    else { $base2 = $t2 }

    if ($base2.Length -le $maxLen) { return $base2 }

    # Third attempt: remove common version/mix suffixes from title.
    $t3 = Strip-VersionMixTail $t2
    if ($t3 -ne $t2 -and -not [string]::IsNullOrWhiteSpace($t3)) {
        $base3 = ""
        if ($a2 -and $t3) { $base3 = "$a2$joiner$t3" }
        elseif ($a2) { $base3 = $a2 }
        else { $base3 = $t3 }

        if ($base3.Length -le $maxLen) { return $base3 }

        $t2    = $t3
        $base2 = $base3
    }

    # Fourth attempt (length pressure): drop low-priority dash suffixes from the title (e.g. "- Live @Venue")
    # before we start reducing multi-artist credits to complete names that still fit.
    $tLP = Strip-LowPriorityDashSuffix $t2
    if ($tLP -ne $t2 -and -not [string]::IsNullOrWhiteSpace($tLP)) {
        $baseLP = ""
        if ($a2 -and $tLP) { $baseLP = "$a2$joiner$tLP" }
        elseif ($a2) { $baseLP = $a2 }
        else { $baseLP = $tLP }

        if ($baseLP.Length -le $maxLen) { return $baseLP }

        # Even if we still don't fit, keep the shorter title for later truncation steps.
        $t2    = $tLP
        $base2 = $baseLP
    }

    # Late fallback before aggressive truncation:
    # - Drop trailing bracket groups from title/artist ONLY under length pressure.
    # This preserves meaningful subtitles whenever possible.
    $aB = Strip-Trailing-Brackets $artist
    $tB = Strip-Trailing-Brackets $t2

    $baseB = ""
    if ($aB -and $tB) { $baseB = "$aB$joiner$tB" }
    elseif ($aB) { $baseB = $aB }
    else { $baseB = $tB }

    if ($baseB.Length -le $maxLen) { return $baseB }

    # Keep the shorter variants for subsequent steps.
    $artist = $aB
    $t2     = $tB

    # Prefer preserving at least the first complete credited artist name and truncate the title
    # instead of cutting the artist mid-name.

    # Extra safe attempt: preserve the full title if it fits and only squeeze the artist.
    # This must run *before* the aggressive multi-artist fallback below, so that we don't unnecessarily
    # collapse to only the first credited artist when two (or more) would still fit within the 64-char RT limit.
    $keepTitle = Fit-ArtistPreserveTitle $artist $a2 $t2 $maxLen $joiner
    if ($keepTitle) { return $keepTitle }
    $multi = (Looks-LikeMultiArtist $artist)
    if ($multi -and $a2 -and $t2) {
        $firstArtist = $null
        try {
            $rxFirst = New-Object System.Text.RegularExpressions.Regex(
            "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            foreach ($p in $rxFirst.Split($a2)) {
                $n = Cleanup-Whitespace $p
                if (-not [string]::IsNullOrWhiteSpace($n)) { $firstArtist = $n; break }
            }
        } catch { $firstArtist = $null }

        $candidates = @()
        if (-not [string]::IsNullOrWhiteSpace($firstArtist)) {
            $candidates += $firstArtist
        }

        foreach ($aTry in $candidates) {
            if ([string]::IsNullOrWhiteSpace($aTry)) { continue }
            $fixed        = "$aTry$joiner"
            $roomForTitle = $maxLen - $fixed.Length
            if ($roomForTitle -ge 8) {
                $tCut = WordCut $t2 $roomForTitle
                if (-not [string]::IsNullOrWhiteSpace($tCut)) {
                    $out = (Cleanup-Whitespace ($fixed + $tCut))

                    # Only return without ellipsis if the title was NOT truncated.
                    if ($tCut.Length -ge $t2.Length -and $out.Length -le $maxLen) { return $out }

                    # If we had to cut, use an ellipsis.
                    $ellipsis = "..."
                    $room2    = $maxLen - $fixed.Length - $ellipsis.Length
                    if ($room2 -ge 8) {
                        $tCut2 = Best-TitleCut $t2 $room2
                        $tCut2 = Trim-ForEllipsis $tCut2
                        if ([string]::IsNullOrWhiteSpace($tCut2) -and $room2 -gt 0) {
                            $tCut2 = Trim-ForEllipsis (Limit-TextLength $t2 $room2)
                        }
                        if (-not [string]::IsNullOrWhiteSpace($tCut2)) {
                            $out2 = (Cleanup-Whitespace ($fixed + $tCut2 + $ellipsis))
                            if ($out2.Length -le $maxLen) { return $out2 }
                        }
                    }
                }
            }
        }
    }

    # Final attempt: ellipsize with word boundary preference.
    $ellipsis   = "..."
    $limitTotal = [Math]::Max(0, $maxLen - $ellipsis.Length)

    if ($a2 -and $t2) {
        $fixed        = "$a2$joiner"
        $roomForTitle = $limitTotal - $fixed.Length
        if ($roomForTitle -gt 5) {
            $tCut = WordCut $t2 $roomForTitle
            $tCut = Trim-ForEllipsis $tCut
            if ([string]::IsNullOrWhiteSpace($tCut) -and $roomForTitle -gt 0) {
                $tCut = Trim-ForEllipsis (Limit-TextLength $t2 $roomForTitle)
            }
            $out = ($fixed + $tCut + $ellipsis).Trim()
            if ($out.Length -le $maxLen) { return $out }
        }
    }

    $one    = $base2
    $oneCut = WordCut $one $limitTotal
    if ($oneCut.Length -lt 3 -and $limitTotal -gt 0) {
        $oneCut = (Limit-TextLength $one $limitTotal).Trim()
    }
    $oneCut = Trim-ForEllipsis $oneCut
    if ([string]::IsNullOrWhiteSpace($oneCut) -and $limitTotal -gt 0) {
        $oneCut = Trim-ForEllipsis (Limit-TextLength $one $limitTotal)
    }
    return ($oneCut + $ellipsis)
}

function Has-LettersOrDigits([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -match "(\p{L}|\p{Nd})")
}

function Get-TruncatedVisibleArtistTitleParts([string]$artist, [string]$title) {
    $a = Cleanup-Whitespace $artist
    $t = Cleanup-Whitespace $title

    if (-not (Has-LettersOrDigits $a)) {
        $visibleTitle = Smart-Truncate-Fields '' $t $MaxLen $OutJoin
        return [pscustomobject]@{ Artist = ''; Title = (Cleanup-Whitespace $visibleTitle) }
    }
    if (-not (Has-LettersOrDigits $t)) {
        $visibleArtist = Smart-Truncate-Fields $a '' $MaxLen $OutJoin
        return [pscustomobject]@{ Artist = (Cleanup-Whitespace $visibleArtist); Title = '' }
    }

    # Keep Smart-Truncate-Fields artist/title semantics independent from display order. Replace only
    # the non-whitespace joiner character with a private-use marker, preserving the original spaces
    # and therefore the exact word-boundary behavior of the visible joiner.
    $marker = -join @($OutJoin.ToCharArray() | ForEach-Object {
        if ([char]::IsWhiteSpace($_)) { [string]$_ } else { [string][char]0xE000 }
    })
    if ([string]::IsNullOrEmpty($marker)) { $marker = [string][char]0xE000 }
    $marked = Cleanup-Whitespace (Smart-Truncate-Fields $a $t $MaxLen $marker)

    $markerPos = $marked.IndexOf($marker)
    if ($markerPos -lt 0) {
        # Under extreme length pressure the established truncation policy can drop the second field.
        # Remove any partial private-use marker before returning the surviving artist text.
        $visibleArtist = Cleanup-Whitespace ($marked.Replace([string][char]0xE000, ''))
        return [pscustomobject]@{ Artist = $visibleArtist; Title = '' }
    }

    return [pscustomobject]@{
        Artist = Cleanup-Whitespace ($marked.Substring(0, $markerPos))
        Title  = Cleanup-Whitespace ($marked.Substring($markerPos + $marker.Length))
    }
}

function Build-VisibleRtText([string]$artist, [string]$title) {
    $parts = Get-TruncatedVisibleArtistTitleParts $artist $title
    $a = $parts.Artist
    $t = $parts.Title
    $hasArtist = Has-LettersOrDigits $a
    $hasTitle  = Has-LettersOrDigits $t
    $artistOnly = $false

    if ($hasArtist -and $hasTitle) {
        $rt = $(if (Test-TitleFirstOrder) { "$t$OutJoin$a" } else { "$a$OutJoin$t" })
    } elseif ($hasArtist) {
        $rt = $a
        $artistOnly = $true
    } else {
        $rt = $t
    }

    $rt = Cleanup-Whitespace $rt
    $rt = Fix-ApostropheSuffixCase $rt
    $rt = Strip-AlwaysRemoveNoiseTags $rt
    $rt = Filter-ToRdsLatin $rt
    $rt = Strip-AlwaysRemoveNoiseTags $rt
    if ($artistOnly) { $rt = Cleanup-DanglingArtistSeparators $rt }

    if (-not (Has-LettersOrDigits $rt)) { return '' }
    if ($rt.Length -gt $MaxLen) {
        $rt = (Limit-TextLength $rt $MaxLen).Trim()
        $rt = Filter-ToRdsLatin $rt
        $rt = Strip-AlwaysRemoveNoiseTags $rt
        if ($artistOnly) { $rt = Cleanup-DanglingArtistSeparators $rt }
        if (-not (Has-LettersOrDigits $rt)) { return '' }
    }
    return $rt
}

function Build-RtPlusOutputFromParts([string]$artist, [string]$title) {
    $parts = Get-TruncatedVisibleArtistTitleParts $artist $title
    $a = $parts.Artist
    $t = $parts.Title

    if ((Has-LettersOrDigits $a) -and (Has-LettersOrDigits $t)) {
        if (Test-TitleFirstOrder) {
            return ("\+TI{0}\-{1}\+AR{2}\-" -f $t, $OutJoin, $a)
        }
        return ("\+AR{0}\-{1}\+TI{2}\-" -f $a, $OutJoin, $t)
    }
    if (Has-LettersOrDigits $a) { return ("\+AR{0}\-" -f $a) }
    if (Has-LettersOrDigits $t) { return ("\+TI{0}\-" -f $t) }
    return ''
}

# -------------------- Country/region token helpers (RegionInfo-derived) --------------------
# Notes:
# - We use RegionInfo as the primary source for country names and ISO region codes.
# - We intentionally keep a small alias list for common non-ISO or dotted forms seen in metadata (e.g., UK, U.S.A.).
# - Sets are built once and cached in script scope for performance and consistency.
function Ensure-CountryData {
    if ($script:_CountryNameSet -and $script:_CountryIso2Set -and $script:_CountryIso3Set) { return }

    $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $iso2Set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $iso3Set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    try {
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
            try {
                $ri = New-Object System.Globalization.RegionInfo($c.Name)
                if ($ri) {
                    if (-not [string]::IsNullOrWhiteSpace($ri.EnglishName)) {
                        [void]$nameSet.Add((Cleanup-Whitespace $ri.EnglishName).Trim())
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ri.TwoLetterISORegionName)) {
                        [void]$iso2Set.Add(($ri.TwoLetterISORegionName).Trim().ToUpperInvariant())
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ri.ThreeLetterISORegionName)) {
                        [void]$iso3Set.Add(($ri.ThreeLetterISORegionName).Trim().ToUpperInvariant())
                    }
                }
            } catch { }
        }
    } catch { }

    # Common aliases seen in music metadata / exports.
    foreach ($a in (Get-CountryAliases)) { [void]$nameSet.Add($a) }
    # Code aliases:
    # - "UK" is commonly used in metadata but ISO-3166 alpha-2 uses "GB".
    [void]$iso2Set.Add("UK")

    $script:_CountryNameSet = $nameSet
    $script:_CountryIso2Set = $iso2Set
    $script:_CountryIso3Set = $iso3Set
}

function Test-IsCountryToken([string]$token) {
    Ensure-CountryData

    if ([string]::IsNullOrWhiteSpace($token)) { return $false }

    $x = (Cleanup-Whitespace $token).Trim()
    if ([string]::IsNullOrWhiteSpace($x)) { return $false }

    # Exact English name / alias match.
    if ($script:_CountryNameSet.Contains($x)) { return $true }

    # ISO country/region codes (safe at edges only; callers enforce clear delimiters).
    if ($x -match '^[A-Za-z]{2}$') {
        $cc2 = $x.ToUpperInvariant()
        if ($script:_CountryIso2Set.Contains($cc2)) { return $true }
    } elseif ($x -match '^[A-Za-z]{3}$') {
        $cc3 = $x.ToUpperInvariant()
        if ($script:_CountryIso3Set.Contains($cc3)) { return $true }
    }

    # Allow "The <country>" if <country> is in the set (RegionInfo typically omits the article).
    if ($x -match '^(?i)the\s+(.+)$') {
        $rest = (Cleanup-Whitespace $matches[1]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rest) -and $script:_CountryNameSet.Contains($rest)) { return $true }
    }

    # Allow dotted abbreviations like "U.S.A." by comparing without dots too.
    $xNoDots = ($x -replace '\.', '').Trim()
    if ($xNoDots -ne $x) {
        if ($script:_CountryNameSet.Contains($xNoDots)) { return $true }

        if ($xNoDots -match '^[A-Za-z]{2}$') {
            $cc2 = $xNoDots.ToUpperInvariant()
            if ($script:_CountryIso2Set.Contains($cc2)) { return $true }
        } elseif ($xNoDots -match '^[A-Za-z]{3}$') {
            $cc3 = $xNoDots.ToUpperInvariant()
            if ($script:_CountryIso3Set.Contains($cc3)) { return $true }
        }
    }

    return $false
}
# ------------------------------------------------------------------------------------------

function Remove-ArtistRegionSuffix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return "" }

    # Strip a trailing country/region tag that is clearly metadata and not part of the artist name.
    #
    # Supported (end of artist field only):
    # - Bracketed suffixes:  "Artist (Netherlands)", "Band [Belgium]", "Name {Japan}"
    # - Hyphen suffixes:     "Artist - Netherlands", "Band – Belgium", "Name — Japan"
    # - Country/region codes (ISO2): "Artist (US)", "Band [UK]", "Name {DE}"
    #
    # Safety rules:
    # - Only acts on a *final* token at the end of the artist field.
    # - Only strips when the token is an exact country/region name (derived from .NET RegionInfo) or a known alias,
    #   or a two-letter ISO region code (RegionInfo-derived, plus a few common aliases).
    #
    # Note: This is intentionally conservative about *what* it matches (exact token match), but broad about *which*
    #       countries are eligible (RegionInfo-derived), per our intended playlist/export use-case.

    $t = Cleanup-Whitespace $artist

    # --- 0) Lazy-build country/region name set (English names) ---
    Ensure-CountryData

    # --- 1) Two-letter country/region codes (ISO2) ---
    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<cc>[A-Z]{2})\s*\)|\[\s*(?<cc>[A-Z]{2})\s*\]|\{\s*(?<cc>[A-Z]{2})\s*\})\s*$')
    if ($m.Success) {
        $name = Cleanup-Whitespace $m.Groups["name"].Value
        $cc   = ($m.Groups["cc"].Value).ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($cc)) {
            if ($script:_CountryIso2Set.Contains($cc)) { return $name }
        }

        # If it looks like a code token but is not in our allowlist, do nothing.
        return $t
    }

    # --- 2) Bracketed suffixes: (Country) / [Country] / {Country} ---
    $m2 = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<tag>[^)\]]+?)\s*\)|\[\s*(?<tag>[^\]]+?)\s*\]|\{\s*(?<tag>[^}]+?)\s*\})\s*$')
    if ($m2.Success) {
        $name2 = Cleanup-Whitespace $m2.Groups["name"].Value
        $tag2  = Cleanup-Whitespace $m2.Groups["tag"].Value

        # Short ISO-style codes are only unambiguous when written entirely in uppercase.
        if ($tag2 -match '^[A-Za-z]{2,3}$' -and $tag2 -cne $tag2.ToUpperInvariant()) { return $t }

        if (-not [string]::IsNullOrWhiteSpace($name2) -and (Test-IsCountryToken $tag2)) {
            return $name2
        }
    }

    # --- 3) Hyphen/ndash/mdash suffixes: " - Country" / " – Country" / " — Country" ---
    # Require whitespace on both sides so hyphenated names such as "MO-DO" remain untouched.
    $m3 = [regex]::Match($t, '^(?<name>.+?)\s+[-–—]\s+(?<tag>[^-–—]+?)\s*$')
    if ($m3.Success) {
        $name3 = Cleanup-Whitespace $m3.Groups["name"].Value
        $tag3  = Cleanup-Whitespace $m3.Groups["tag"].Value

        if ($tag3 -match '^[A-Za-z]{2,3}$' -and $tag3 -cne $tag3.ToUpperInvariant()) { return $t }

        if (-not [string]::IsNullOrWhiteSpace($name3) -and (Test-IsCountryToken $tag3)) {
            return $name3
        }
    }

    return $t
}

function Normalize-Field([string]$s) {
    $t = $s
    $t = Strip-InvisibleControls $t
    $t = Decode-BasicHtmlEntities $t
    $t = Normalize-FullwidthAscii $t
    $t = Apply-Replacements $t
    $t = Strip-AlwaysRemoveNoiseTags $t
    if ($script:TransliterationEnabled) {
        $t = Transliterate-Cyrillic $t
        $t = Transliterate-Greek $t
    }
    $t = Cleanup-Whitespace $t
    $t = Filter-ToRdsLatin $t
    $t = Strip-AlwaysRemoveNoiseTags $t
    return $t
}

function Normalize-NowPlayingParts([string]$raw) {
    if ($null -eq $raw) { return $null }

    $raw2 = $raw -replace "^\uFEFF", ""
    if ([string]::IsNullOrWhiteSpace($raw2)) { return $null }

    # Some sources (or intermediate tools) may wrap the real payload in a prefix/suffix,
    # e.g. "(03) [Artist␟Title] Artist - Title". In that case, prefer the bracketed payload
    # that contains the U+241F separator, and ignore the redundant trailing text.
    $sepEsc = [regex]::Escape([string]$SepChar)
    $m      = [regex]::Match($raw2, "\[([^\[\]]*${sepEsc}[^\[\]]*)\]")
    if ($m.Success) { $raw2 = $m.Groups[1].Value }

    # Conservative parsing: only split when the delimiter occurs exactly once.
    $sepCount = 0
    try { $sepCount = [regex]::Matches($raw2, $sepEsc).Count } catch { $sepCount = 0 }

    if ($sepCount -eq 1) {
        $parts = $raw2 -split $sepEsc, 2
        if ($parts.Count -lt 2) { return $null }
        $artistRaw = $parts[0]
        $titleRaw  = $parts[1]
    } else {
        # Title-only fallback (no split). This prevents accidental mis-parsing when the delimiter
        # is missing or appears multiple times inside titles or other payloads.
        $artistRaw = ""
        $titleRaw  = $raw2
    }

    $artistRawOrig = $artistRaw

    $artistRaw = Strip-TrackNumberPrefix $artistRaw
    $artistRaw = Strip-TrackNumberPrefixLoose $artistRaw

    # Strip a clearly separated leading 4-digit year from the *artist* field, e.g.
    # "2002 - Leonard Cohen" or "2002 – Leonard Cohen - The Essential".
    # This is deliberately conservative: it only triggers for a standalone year token
    # followed by a strong separator and payload that still contains at least one letter.
    $mYearPrefix = [regex]::Match($artistRaw, '^(?<year>(?:19|20)\d{2})\s*[-–—:]\s*(?<rest>.+)$')
    if ($mYearPrefix.Success) {
        $rest = Cleanup-Whitespace $mYearPrefix.Groups["rest"].Value
        if (-not [string]::IsNullOrWhiteSpace($rest) -and $rest -match '\p{L}') {
            $artistRaw = $rest
        }
    }

    # If the artist field ends with an EAC rip marker that also carries a track number (e.g., "Artist - 10 (EAC)"),
    # remove that entire trailing token. This is deliberately strict: it only triggers when an explicit "(EAC)" or "[EAC]"
    # is present at the very end, and a 1–3 digit track number is attached to it.
    $artistRaw = [regex]::Replace($artistRaw, '(?i)\s*[-–—]?\s*\d{1,3}\s*[\(\[]\s*EAC\s*[\)\]]\s*$', '')
    $artistRaw = Cleanup-Whitespace $artistRaw
    $artistRaw = Unwrap-EnclosingArtistBrackets $artistRaw

    # Also handle album-like EAC tails in the *artist* field, e.g. "Artist - The Hits 2 (EAC)".
    # This is still conservative: it only triggers when "(EAC)" or "[EAC]" is at the very end AND the token
    # immediately before it is a single dash-separated segment (no additional dashes).
    $mEacAlbum = [regex]::Match($artistRaw, '(?i)^(?<name>.+?)\s*[-–—]\s*(?<tail>[^-\\r\\n]{1,80})\s*[\(\[]\s*EAC\s*[\)\]]\s*$')
    if ($mEacAlbum.Success) {
        $name = Cleanup-Whitespace $mEacAlbum.Groups["name"].Value
        $tail = Cleanup-Whitespace $mEacAlbum.Groups["tail"].Value
        if (-not [string]::IsNullOrWhiteSpace($name) -and $tail -match '[A-Za-z]') {
            $artistRaw = $name
        }
    }

    # If we previously stripped an EAC-style rip marker/track number from an "album-like" artist token,
    # we can end up with a leftover compilation segment such as " - The Hits". Remove that segment only
    # when the ORIGINAL artist field clearly contained a "The Hits" + optional volume number + optional EAC marker.
    # This is deliberately strict to avoid breaking legitimate artist names that contain " - The Hits".
    $mHits = [regex]::Match($artistRaw, '(?i)^(?<name>.+?)\s*[-–—]\s*The\s+Hits\s*$')
    if ($mHits.Success) {
        $name = Cleanup-Whitespace $mHits.Groups["name"].Value
        $orig = "$artistRawOrig"
        if ([regex]::IsMatch($orig, '(?i)\bThe\s+Hits(?:\s+\d{1,3})?\s*(?:[\(\[]\s*EAC\s*[\)\]])?\s*$')) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $artistRaw = $name
            }
        }
    }

    if (Is-TrackNumberOnly $artistRaw) {
        $ft2 = Try-ParseArtistTitleFromFilename $titleRaw
        if ($null -ne $ft2) {
            $artistRaw = $ft2.Artist
            $titleRaw  = $ft2.Title
        }
    }

    # Title-only inputs are allowed (e.g. "␟Pink noise..."):
    # - Title is required.
    # - Artist may be empty.
    if ([string]::IsNullOrWhiteSpace($artistRaw) -or [string]::IsNullOrWhiteSpace($titleRaw)) {
        # If the input is "Artist␟" (missing title), try to recover from a filename-like string.
        if (-not [string]::IsNullOrWhiteSpace($artistRaw) -and [string]::IsNullOrWhiteSpace($titleRaw)) {
            $ft = Try-ParseArtistTitleFromFilename $artistRaw
            if ($null -ne $ft) {
                $artistRaw = $ft.Artist
                $titleRaw  = $ft.Title
            }
        }

        # Still no title => invalid.
        if ([string]::IsNullOrWhiteSpace($titleRaw)) { return $null }

        # If artist is empty but title exists, continue (title-only).
        if ([string]::IsNullOrWhiteSpace($artistRaw)) { $artistRaw = "" }
    }

    $artist = Normalize-Field $artistRaw
    $artist = Strip-CountryPrefix $artist
    $artist = Remove-ArtistAcronymSuffix $artist
    $artist = Remove-ArtistRegionSuffix $artist
    $artist = Strip-CompilationTail $artist
    $artist = Strip-SeparatedYearTail $artist
    $artist = Remove-ArtistAcronymSuffix $artist
    $title  = Normalize-Field $titleRaw

    $title = Strip-CountryPrefix $title
    $title = Strip-CountrySuffix $title
    $title = Strip-CompilationTail $title
    $title = Strip-SeparatedYearTail $title

    if ([string]::IsNullOrWhiteSpace($artist) -and [string]::IsNullOrWhiteSpace($title)) { return $null }

    # Remove version-like tails first (so "feat/with/met" stripping sees a clean title).
    $title2 = $title
    $title2 = Strip-SoundtrackTail      $title2
    $title2 = Strip-LanguageTagTail     $title2
    $title2 = Strip-RemasterTail        $title2
    $title2 = Strip-TitleWhitelistTails $title2
    $title2 = Strip-LiveDashSuffixAlways $title2
    $title2 = Strip-LiveBracketSuffixAlways $title2
    $title2 = Strip-MeaninglessTrailingSeparators $title2
    $title2 = Strip-LiveLocationTail    $title2
    $title2 = Strip-AudioFormatTail     $title2
    $title2 = Strip-VersionMixTail      $title2
    $title2 = Strip-LowPriorityDashSuffix $title2
    $title2 = Dedup-DuplicateTitle      $title2
    $title2 = Cleanup-Whitespace        $title2
    $title2 = Strip-AlwaysRemoveNoiseTags              $title2
    $title2 = Filter-ToRdsLatin         $title2
    $title2 = Strip-AlwaysRemoveNoiseTags              $title2

    $title2 = Strip-ArtistDuplicateTitlePrefix $artist $title2

    # Now perform guest-tail stripping based on the artist list (prevents duplicates).
    $title2 = Strip-FeatInTitleIfGuestsAlreadyInArtist $artist $title2
    $title2 = Strip-WithInTitleIfGuestsAlreadyInArtist $artist $title2
    $title2 = Strip-ArtistDuplicateTitleTail $artist $title2
    $title2 = Strip-MeaninglessTrailingSeparators $title2

    $title2 = Cleanup-Whitespace $title2
    $title2 = Strip-AlwaysRemoveNoiseTags       $title2
    $title2 = Filter-ToRdsLatin  $title2
    $title2 = Strip-AlwaysRemoveNoiseTags       $title2

    $artist = Cleanup-Whitespace $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Filter-ToRdsLatin  $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Dedup-BracketedArtistPrefix $artist
    $artist = Dedup-AdjacentCommaArtistPrefix $artist
    $artist = Cleanup-Whitespace $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Filter-ToRdsLatin  $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Cleanup-DanglingArtistSeparators $artist
    # Title is normally required, but if the user disables transliteration a non-Latin title may be filtered away.
    # In that case, keep an artist-only output rather than forcing an empty broadcast.
    if ([string]::IsNullOrWhiteSpace($title2)) {
        if (-not [string]::IsNullOrWhiteSpace($artist)) {
            $title2 = ""
        } else {
            return $null
        }
    }

    # Artist may be empty (title-only).
    if ([string]::IsNullOrWhiteSpace($artist)) { $artist = "" }
    return [pscustomobject]@{ Artist = $artist; Title = $title2 }
}

# -------------------- Initialize persistent settings -------------------------

Load-Settings
try { Load-ArtistTitleOrderSetting } catch { }
try { Apply-DelimiterFromSettings } catch { }
# Apply persisted toggles (best-effort, robust against missing keys).
try { if ($script:Settings.ContainsKey('PrefixLanguageCode'))     { $script:PrefixLanguageCode     = "$($script:Settings['PrefixLanguageCode'])".Trim().ToUpperInvariant() } } catch { }
try { if ($script:Settings.ContainsKey('TransliterationEnabled')) { $script:TransliterationEnabled = [bool]$script:Settings['TransliterationEnabled'] } } catch { }
try { if ($script:Settings.ContainsKey('AsciiSafeEnabled'))       { $script:AsciiSafeEnabled       = [bool]$script:Settings['AsciiSafeEnabled'] } } catch { }
try { if ($script:Settings.ContainsKey('DelimiterKey') -and $script:Settings['DelimiterKey']) { $script:DelimiterKey = "$($script:Settings['DelimiterKey'])".Trim().ToUpperInvariant() } } catch { }

# Re-apply the prefix text after loading the unified settings file.
# Earlier in the script, prefix settings are initialized before Load-Settings runs.
try { Apply-PrefixFromLanguage } catch { }

# Optional: show a one-time first-run wizard for the IO directory and apply WorkDir if configured.
# Cancelling the required wizard leaves no valid runtime state, so cleanly stop before initializing the UI/watcher.
if (-not (Show-WorkDirWizardIfNeeded)) {
    # Prevent the process-exit safety handler from touching default output paths after a cancelled startup.
    try { [NativeExitFlush]::Update($null, $null, $null, $null, $null, $null) } catch { }

    try { Clear-Host } catch { }
    Show-StartupToast -Message "Startup cancelled - no working directory was selected."

    # This early return occurs before the normal main-loop finally block, so release the startup resources here.
    try { Stop-ConsoleCtrlABlocker } catch { }
    try { [Console]::CursorVisible = $true } catch { }
    try {
        if ($script:MutexHasHandle -and $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null }
    } catch { }
    try {
        if ($script:Mutex) { $script:Mutex.Dispose() }
    } catch { }

    return
}
Apply-WorkDirIfConfigured

# -------------------- Watcher (Wait-Event) -----------------------------------

function Initialize-Watcher {
    # (Re)create the FileSystemWatcher so changing WorkDir takes effect immediately.
    try {
        if ($script:fsw) {
            try { $script:fsw.EnableRaisingEvents = $false } catch { }
            try { $script:fsw.Dispose() } catch { }
        }
    } catch { }

    try {
        foreach ($id in @("NP_Changed","NP_Created","NP_Renamed")) {
            try { Unregister-Event -SourceIdentifier $id -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { Get-Event | Remove-Event -ErrorAction SilentlyContinue } catch { }
    } catch { }

    $script:WatchedDir  = Split-Path -Parent $InFile
    $script:WatchedName = Split-Path -Leaf  $InFile

    if (-not (Ensure-Directory $script:WatchedDir "Watcher directory")) { throw "Cannot create/access watcher directory: $script:WatchedDir" }

    $script:fsw                       = New-Object System.IO.FileSystemWatcher
    $script:fsw.Path                  = $script:WatchedDir
    $script:fsw.Filter                = $script:WatchedName
    $script:fsw.IncludeSubdirectories = $false
    $script:fsw.NotifyFilter          = [IO.NotifyFilters]'FileName, LastWrite, Size'
    $script:fsw.InternalBufferSize    = 65536
    $script:fsw.EnableRaisingEvents   = $true

    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Changed -SourceIdentifier "NP_Changed"
    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Created -SourceIdentifier "NP_Created"
    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Renamed -SourceIdentifier "NP_Renamed"
}

$null = Ensure-WorkDirOrFallback
Initialize-Watcher

$script:LastStamp = ""

function Get-InputStamp {
    if (-not (Test-Path -LiteralPath $InFile)) { return "" }
    try {
        $fi = Get-Item -LiteralPath $InFile -ErrorAction Stop
        return ("{0:o}|{1}" -f $fi.LastWriteTimeUtc, $fi.Length)
    } catch { return "" }
}

function Get-InputUiState {
    if (-not (Test-Path -LiteralPath $InFile)) { return "NotAvailable" }
    try {
        $it = Get-Item -LiteralPath $InFile -ErrorAction Stop | Out-Null

        # Treat a truly empty input file as NotAvailable (requested UI behavior).
        try {
            $it = Get-Item -LiteralPath $InFile -ErrorAction Stop
            if ($it -and $it.Length -eq 0) { return "NotAvailable" }
        } catch { }

        # "Expired" is a startup-only concept: it applies only when the input file already existed at launch
        # and was older than the freshness window at that time. It must never appear later just because time passed.
        if (-not $script:HasSeenFreshInput -and $script:StartupInputWasExpired) { return "Expired" }

        # If we cannot extract valid metadata from the latest seen payload, treat the input as NotAvailable
        # even if the file physically exists (e.g., BOM-only / whitespace-only payloads from playout software).
        if (-not $script:LastMetadataValid) { return "NotAvailable" }

        return "Normal"
    } catch {
        # If the file exists but is momentarily locked during a write, keep the last known availability state.
        if ($script:LastMetadataValid) { return "Normal" }
        return "NotAvailable"
    }
}

function Should-HandleEvent($evt) {
    $args = $evt.SourceEventArgs
    if ($args.Name -ieq $script:WatchedName) { return $true }
    if ($args -is [System.IO.RenamedEventArgs]) {
        if ($args.OldName -ieq $script:WatchedName) { return $true }
    }
    return $false
}

function Get-EffectivePrefixOutput {
    $raw  = $(if ($script:AsciiSafeEnabled) { $script:PrefixTextAscii } else { $script:PrefixTextNative })
    $core = Convert-CustomTextForOutput $raw -NoLengthLimit
    if ([string]::IsNullOrWhiteSpace($core)) { return "" }

    $core = Limit-TextLength $core ($MaxCustomTextLen - 1)
    $core = $core.TrimEnd()
    return (Ensure-TrailingSpace $core)
}

function Get-EffectiveConnectorOutput {
    $raw = ''
    try { $raw = [string]$script:Settings.ConnectorText } catch { $raw = '' }

    $core = Convert-CustomTextForOutput $raw -NoLengthLimit
    if ([string]::IsNullOrWhiteSpace($core)) { return "" }

    $core = Limit-TextLength $core ($MaxCustomTextLen - 2)
    $core = $core.Trim()
    return (Ensure-SurroundingSpaces $core)
}

function Add-StandaloneEllipsis([string]$text, [int]$maxLen, [bool]$preferTitleCut) {
    if ([string]::IsNullOrWhiteSpace($text) -or $maxLen -le 0) { return "" }

    $t = (Cleanup-Whitespace $text).Trim()
    if ($t.Length -le $maxLen) { return $t }

    $ellipsis = "..."
    if ($maxLen -le $ellipsis.Length) {
        return $ellipsis.Substring(0, $maxLen)
    }

    $cutLimit = $maxLen - $ellipsis.Length
    if ($preferTitleCut) {
        $cut = Best-TitleCut $t $cutLimit
    } else {
        $cut = WordCut $t $cutLimit
    }

    $cut = Trim-ForEllipsis $cut
    if ([string]::IsNullOrWhiteSpace($cut)) {
        $cut = Trim-ForEllipsis (Limit-TextLength $t $cutLimit)
    }
    if ([string]::IsNullOrWhiteSpace($cut)) {
        $cut = (Limit-TextLength $t $cutLimit).Trim()
    }

    $out = (Cleanup-Whitespace ($cut + $ellipsis)).Trim()
    if ($out.Length -gt $maxLen) {
        $out = (Limit-TextLength $out $maxLen).TrimEnd()
    }
    return $out
}

function Build-StandaloneArtistOutput([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }

    $original = (Cleanup-Whitespace $text).Trim()
    if ($original.Length -le $MaxLen) { return $original }

    # Give the standalone artist field its own complete 64-character budget.
    # Reuse the artist-side length-pressure steps from Smart-Truncate-Fields,
    # without changing the established combined RT/RT+ decisions.
    $candidate = Compact-FeatTailToAmp $original
    $candidate = Cleanup-Whitespace $candidate
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $original }
    if ($candidate.Length -le $MaxLen) { return $candidate }

    $withoutBrackets = Strip-Trailing-Brackets $candidate
    if (-not [string]::IsNullOrWhiteSpace($withoutBrackets)) {
        $candidate = Cleanup-Whitespace $withoutBrackets
        if ($candidate.Length -le $MaxLen) { return $candidate }
    }

    $candidate = Add-StandaloneEllipsis $candidate $MaxLen $false
    $candidate = Cleanup-DanglingArtistSeparators $candidate

    # Final invariant guard; normally Add-StandaloneEllipsis already guarantees this.
    if ($candidate.Length -gt $MaxLen) {
        $candidate = Limit-TextLength $candidate $MaxLen
        $candidate = $candidate.TrimEnd()
    }
    return $candidate
}

function Build-StandaloneTitleOutput([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }

    $original = (Cleanup-Whitespace $text).Trim()
    if ($original.Length -le $MaxLen) { return $original }

    # Give the standalone title field its own complete 64-character budget.
    # This mirrors the title-side adaptive order in Smart-Truncate-Fields:
    # compact guest tail, remove guest tail, version/mix tail, low-priority
    # dash suffix, trailing brackets, and only then use a graceful ellipsis.
    $compact = Compact-FeatTailToAmp $original
    $compact = Cleanup-Whitespace $compact
    if (-not [string]::IsNullOrWhiteSpace($compact) -and $compact.Length -le $MaxLen) {
        return $compact
    }

    $candidate = Strip-FeatTail $original
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $original }
    $candidate = Cleanup-Whitespace $candidate
    if ($candidate.Length -le $MaxLen) { return $candidate }

    $shorter = Strip-VersionMixTail $candidate
    if (-not [string]::IsNullOrWhiteSpace($shorter)) {
        $candidate = Cleanup-Whitespace $shorter
        if ($candidate.Length -le $MaxLen) { return $candidate }
    }

    $shorter = Strip-LowPriorityDashSuffix $candidate
    if (-not [string]::IsNullOrWhiteSpace($shorter)) {
        $candidate = Cleanup-Whitespace $shorter
        if ($candidate.Length -le $MaxLen) { return $candidate }
    }

    $shorter = Strip-Trailing-Brackets $candidate
    if (-not [string]::IsNullOrWhiteSpace($shorter)) {
        $candidate = Cleanup-Whitespace $shorter
        if ($candidate.Length -le $MaxLen) { return $candidate }
    }

    $candidate = Add-StandaloneEllipsis $candidate $MaxLen $true

    # Final invariant guard; normally Add-StandaloneEllipsis already guarantees this.
    if ($candidate.Length -gt $MaxLen) {
        $candidate = Limit-TextLength $candidate $MaxLen
        $candidate = $candidate.TrimEnd()
    }
    return $candidate
}

function Compose-OutputsFromRaw([string]$raw) {
    $empty = [pscustomobject]@{ Prefix = ""; Artist = ""; Connector = ""; Title = ""; Rt = ""; RtPlus = "" }

    $parts = Normalize-NowPlayingParts $raw
    if ($null -eq $parts) { return $empty }

    # Keep ready-made RT/RT+ compact and independent from the longer prefix/connector components.
    # Only the artist/title order changes; the established short joiner and 64-character policy remain intact.
    $script:OutJoin = " - "
    $visibleRt = Build-VisibleRtText $parts.Artist $parts.Title
    if ([string]::IsNullOrWhiteSpace($visibleRt)) { return $empty }

    $forceAsciiFinal = $script:AsciiSafeEnabled

    if ($forceAsciiFinal) {
        # Apply the adaptive 64-character policy independently to the standalone fields,
        # after the final ASCII conversion because that conversion may expand characters.
        $artistOut = Build-StandaloneArtistOutput (AsciiSafe-FinalPass $parts.Artist)
        $titleOut  = Build-StandaloneTitleOutput  (AsciiSafe-FinalPass $parts.Title)
        $rt        = AsciiSafe-FinalPass $visibleRt
        $rtp       = AsciiSafe-FinalPass (Build-RtPlusOutputFromParts $parts.Artist $parts.Title)
    } else {
        $artistOut = Build-StandaloneArtistOutput (UnicodeSafe-FinalPass $parts.Artist)
        $titleOut  = Build-StandaloneTitleOutput  (UnicodeSafe-FinalPass $parts.Title)
        $rt        = UnicodeSafe-FinalPass $visibleRt
        $rtp       = UnicodeSafe-FinalPass (Build-RtPlusOutputFromParts $parts.Artist $parts.Title)
    }

    if ($forceAsciiFinal -and $rt.Length -gt $MaxLen) {
        $aF  = AsciiSafe-FinalPass $parts.Artist
        $tF  = AsciiSafe-FinalPass $parts.Title
        $rt  = Build-VisibleRtText $aF $tF
        $rtp = AsciiSafe-FinalPass (Build-RtPlusOutputFromParts $aF $tF)
    }

    if ($rt.Length -gt $MaxLen) { $rt = (Cleanup-Whitespace (Limit-TextLength $rt $MaxLen)).Trim() }

    $prefixOut    = Get-EffectivePrefixOutput
    $connectorOut = ''
    if ((Has-LettersOrDigits $artistOut) -and (Has-LettersOrDigits $titleOut)) {
        $connectorOut = Get-EffectiveConnectorOutput
    }

    return [pscustomobject]@{
        Prefix    = $prefixOut
        Artist    = $artistOut
        Connector = $connectorOut
        Title     = $titleOut
        Rt        = $rt
        RtPlus    = $rtp
    }
}

function Do-Update {
    if ($script:Stopping) { return }

    if (Test-Path -LiteralPath $InFile) {
        $raw = Read-NowPlayingStable $InFile
        $o   = Compose-OutputsFromRaw $raw

        # LastGoodUpdate advances only after the complete six-file publication succeeds.
        # On failure, Publish-Outputs retains this exact payload for automatic retry.
        [void](Publish-Outputs $o.Prefix $o.Artist $o.Connector $o.Title $o.Rt $o.RtPlus $true)

        $script:HasSeenFreshInput     = $true
        $script:StartupExpiredChecked = $true

        # Consider the input "not available" whenever we cannot extract valid metadata.
        # This covers BOM-only / whitespace-only inputs and malformed payloads.
        $script:LastMetadataValid = (-not [string]::IsNullOrWhiteSpace($o.Rt))

        if (-not $script:LastMetadataValid) {
            $script:LastInputUiState = "NotAvailable"
            try { Update-Status "" "" "" "" "" "" "" "NotAvailable" } catch { }
        } else {
            $script:LastInputUiState = "Normal"
            try { Update-Status $raw $o.Prefix $o.Artist $o.Connector $o.Title $o.Rt $o.RtPlus "Normal" } catch { }
        }
    } else {
        [void](Publish-Outputs "" "" "" "" "" "" $true)
        $script:LastMetadataValid = $false
        $script:LastInputUiState  = "NotAvailable"
        try { Update-Status "" "" "" "" "" "" "" "NotAvailable" } catch { }
    }
}

function Do-UpdateIfNeeded {
    if ($script:Stopping) { return }

    $stamp = Get-InputStamp
    if ($stamp -and ($stamp -ne $script:LastStamp)) {
        $script:LastStamp = $stamp
        Do-Update
    }
}

# Ctrl+C: stop the main loop.
try {
    [Console]::CancelKeyPress += {
        param($sender, $e)
        $e.Cancel        = $true
        $script:Stopping = $true
        return
    }
} catch { }

# -------------------- Startup -------------------------------------------------

# Publish current input at startup only if it was written recently.

# Tracks whether we've successfully processed at least one fresh input since start.
$script:HasSeenFreshInput = $false
# Tracks whether startup expiry logic has been evaluated
$script:StartupExpiredChecked = $false
Init-Ui

# Clear outputs immediately on startup to prevent stale broadcasts. Track and retry failed clears.
Clear-OutputsFast $true

# Decide whether to publish the current input immediately.
$script:LastStamp = Get-InputStamp

$publishNow                    = $false
$script:StartupInputWasExpired = $false
if (Test-Path -LiteralPath $InFile) {
    try {
        $fi     = Get-Item -LiteralPath $InFile -ErrorAction Stop
        $ageSec = ([DateTime]::UtcNow - $fi.LastWriteTimeUtc).TotalSeconds

        # Only publish immediately if the input looks "fresh".
        if ($ageSec -ge 0 -and $ageSec -le $StartupPublishFreshSec) { $publishNow = $true } else { $script:StartupInputWasExpired = $true }
    } catch { }
}

if ($publishNow) {
    Do-Update
} else {
    if (Test-Path -LiteralPath $InFile) {
        try { Update-Status "" "" "" "" "" "" "" "Expired" } catch { }
    } else {
        try { Update-Status "" "" "" "" "" "" "" "NotAvailable" } catch { }
    }
}

try { Update-HeartbeatBar } catch { }

try {
    while (-not $script:Stopping) {
        if (Handle-Hotkeys) { Do-Update }

        if ($script:RebuildWatcher) {
            $script:RebuildWatcher = $false
            try { Initialize-Watcher } catch { }
            # Refresh UI immediately so the 'Watching input' lines reflect the new paths.
            try { Draw-Header } catch { }
            try { Update-HeartbeatBar } catch { }
            continue
        }

        # Wait-Event only supports whole-second timeouts reliably in Windows PowerShell 5.1.
        # Poll the already-queued events briefly instead, then sleep cooperatively for a subsecond heartbeat cadence.
        $evt = Wait-Event -Timeout 0

        if ($script:Stopping) { break }

        if ($null -eq $evt) {
            $sleepMs = Get-HeartbeatSleepMilliseconds $PollIntervalMs
            Start-Sleep -Milliseconds $sleepMs
            if ($script:Stopping) { break }

            # Recheck after the cooperative sleep so a watcher event that arrived meanwhile is handled
            # through the normal debounce path instead of first being picked up by the fallback stamp check.
            $evt = Wait-Event -Timeout 0
        }

        if ($null -eq $evt) {
            if (Handle-Hotkeys) { Do-Update }
            try { Update-HeartbeatBar } catch { }

            # Keep the previous one-second cadence for the fallback input-stamp check and output retry scheduler.
            $nowUtc = [DateTime]::UtcNow
            if ($nowUtc -ge $script:NextIdleMaintenanceUtc) {
                $script:NextIdleMaintenanceUtc = $nowUtc.AddSeconds(1)
                Do-UpdateIfNeeded
                try { [void](Retry-PendingOutputsIfDue) } catch { }
            }
            continue
        }

        if (-not (Should-HandleEvent $evt)) {
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            try { Update-HeartbeatBar } catch { }
            try { [void](Retry-PendingOutputsIfDue) } catch { }
            continue
        }

        Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue

        Wait-WithHeartbeat $DebounceMs

        while ($true) {
            $evt2 = Wait-Event -Timeout 0
            if ($null -eq $evt2) { break }
            Remove-Event -EventIdentifier $evt2.EventIdentifier -ErrorAction SilentlyContinue
        }

        $stampNow = Get-InputStamp
        if ($stampNow) { $script:LastStamp = $stampNow }

        Do-Update
        try { Update-HeartbeatBar } catch { }
    }
} finally {
    try { Stop-ConsoleCtrlABlocker } catch { }
    try { [Console]::CursorVisible = $true } catch { }

    try { Clear-OutputsFast } catch { }

    try {
        if ($script:fsw) {
            $script:fsw.EnableRaisingEvents = $false
            $script:fsw.Dispose()
        }
    } catch { }

    try { Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue } catch { }
    try { Get-Event | Remove-Event -ErrorAction SilentlyContinue } catch { }

    try {
        if ($script:MutexHasHandle -and $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null }
    } catch { }
    try {
        if ($script:Mutex) { $script:Mutex.Dispose() }
    } catch { }
    # True only if the input file existed at startup and was already older than the startup freshness window.
    $script:StartupInputWasExpired = $false
}
