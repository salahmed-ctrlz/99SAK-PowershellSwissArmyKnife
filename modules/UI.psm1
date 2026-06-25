<#
.SYNOPSIS
    UI.psm1 - Console rendering helpers for 99SAK v2
    Provides consistent layout, input handling, and status output.
#>

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

function Get-ConsoleWidth {
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -and $w -gt 20) { return [Math]::Min($w, 120) }
    } catch {}
    return 80
}

function Write-Divider {
    param(
        [string]$Char       = '-',
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )
    Write-Host ($Char * (Get-ConsoleWidth)) -ForegroundColor $Color
}

function Write-SectionLabel {
    param([string]$Label)
    Write-Host ''
    Write-Host ("  {0}" -f $Label.ToUpper()) -ForegroundColor White
    Write-Host ''
}

function Write-Option {
    param(
        [string]$Key,
        [string]$Description,
        [ConsoleColor]$KeyColor  = [ConsoleColor]::Yellow,
        [ConsoleColor]$DescColor = [ConsoleColor]::Gray,
        [string]$Badge           = ''
    )
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host $Key  -NoNewline -ForegroundColor $KeyColor
    Write-Host ']  ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Description -NoNewline -ForegroundColor $DescColor
    if ($Badge) {
        Write-Host ("  $Badge") -ForegroundColor DarkCyan
    } else {
        Write-Host ''
    }
}

function Write-StatusLine {
    param(
        [string]$Message,
        [ValidateSet('OK','WARN','ERROR','INFO','STEP')]
        [string]$Status = 'INFO'
    )
    $tag = switch ($Status) {
        'OK'    { ' OK  ' }
        'WARN'  { 'WARN ' }
        'ERROR' { 'ERR  ' }
        'INFO'  { 'INFO ' }
        'STEP'  { '.... ' }
    }
    $color = switch ($Status) {
        'OK'    { [ConsoleColor]::Green    }
        'WARN'  { [ConsoleColor]::Yellow   }
        'ERROR' { [ConsoleColor]::Red      }
        'INFO'  { [ConsoleColor]::Cyan     }
        'STEP'  { [ConsoleColor]::DarkGray }
    }
    Write-Host '  [' -NoNewline -ForegroundColor DarkGray
    Write-Host $tag  -NoNewline -ForegroundColor $color
    Write-Host ']  ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Header renderers
# ---------------------------------------------------------------------------

function Show-Header {
    param([string[]]$Breadcrumbs = @())
    Clear-Host

    $date = Get-Date -Format 'yyyy-MM-dd  HH:mm:ss'

    try {
        $os     = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $osName = if ($os) { $os.Caption -replace 'Microsoft Windows ','Windows ' } else { 'Unknown' }
        $uptime = if ($os) {
            $span = (Get-Date) - $os.LastBootUpTime
            '{0}d {1}h {2}m' -f $span.Days, $span.Hours, $span.Minutes
        } else { 'N/A' }
    } catch { $osName = 'Unknown'; $uptime = 'N/A' }

    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
               Select-Object -First 1 -ExpandProperty IPAddress)
        if (-not $ip) { $ip = 'N/A' }
    } catch { $ip = 'N/A' }

    Write-Host ''
    Write-Host ' 99SAK  v2.0  |  PowerShell Swiss Army Knife' -ForegroundColor Cyan
    Write-Divider
    Write-Host ' Host   ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0,-22}' -f $env:COMPUTERNAME) -NoNewline -ForegroundColor Green
    Write-Host ' Date   ' -NoNewline -ForegroundColor DarkGray
    Write-Host $date -ForegroundColor Green
    Write-Host ' OS     ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0,-22}' -f $osName) -NoNewline -ForegroundColor Green
    Write-Host ' Uptime ' -NoNewline -ForegroundColor DarkGray
    Write-Host $uptime -ForegroundColor Green
    Write-Host ' User   ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0,-22}' -f $env:USERNAME) -NoNewline -ForegroundColor Green
    Write-Host ' IP     ' -NoNewline -ForegroundColor DarkGray
    Write-Host $ip -ForegroundColor Green
    Write-Divider

    if ($Breadcrumbs.Count -gt 0) {
        Write-Host (' ' + ($Breadcrumbs -join ' > ')) -ForegroundColor DarkGray
        Write-Divider
    }
}

function Show-MiniHeader {
    param([string[]]$Breadcrumbs = @())
    Clear-Host
    Write-Host ''
    Write-Host ' 99SAK v2.0' -ForegroundColor Cyan -NoNewline
    if ($Breadcrumbs.Count -gt 0) {
        Write-Host '  |  ' -NoNewline -ForegroundColor DarkGray
        Write-Host ($Breadcrumbs -join ' > ') -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Divider
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

function Read-InputWithBossKey {
    param([string]$Prompt = '')
    if ($Prompt) {
        Write-Host "  $Prompt : " -NoNewline -ForegroundColor DarkGray
    }
    try {
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $key = [System.Console]::ReadKey($true)
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and
                ($key.Key -eq [ConsoleKey]::B)) {
                Write-Host ''
                exit
            }
            switch ($key.Key) {
                'Enter' {
                    Write-Host ''
                    return $sb.ToString()
                }
                'Backspace' {
                    if ($sb.Length -gt 0) {
                        $null = $sb.Remove($sb.Length - 1, 1)
                        Write-Host "`b `b" -NoNewline
                    }
                }
                'Escape' {
                    Write-Host ''
                    return ''
                }
                default {
                    if ($key.KeyChar -ne [char]0) {
                        $null = $sb.Append($key.KeyChar)
                        Write-Host $key.KeyChar -NoNewline
                    }
                }
            }
        }
    } catch {
        # Fallback when running non-interactively
        return (Read-Host $Prompt)
    }
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function Confirm-Action {
    param([string]$Message = 'This action may modify system state.')
    Write-Host ''
    Write-Host ("  {0}" -f $Message) -ForegroundColor Yellow
    Write-Host ''
    $ans = Read-InputWithBossKey 'Type YES to confirm'
    Write-Host ''
    if ($ans -eq 'YES') { return $true }
    Write-Host '  Cancelled.' -ForegroundColor DarkGray
    return $false
}

function Pause-ForUser {
    param([string]$Message = 'Press Enter to continue')
    Write-Host ''
    $null = Read-InputWithBossKey $Message
}

# ---------------------------------------------------------------------------
# Workflow helpers
# ---------------------------------------------------------------------------

function Show-WorkflowBanner {
    param([string]$Title, [string]$Subtitle = '')
    Write-Host ''
    Write-Divider
    Write-Host ("  {0}" -f $Title.ToUpper()) -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host ("  {0}" -f $Subtitle) -ForegroundColor DarkGray
    }
    Write-Divider
    Write-Host ''
}

function Show-WorkflowStep {
    param([int]$Step, [int]$Total, [string]$Name)
    Write-Host ''
    Write-Host ("  [ {0}/{1} ]  {2}" -f $Step, $Total, $Name) -ForegroundColor White
    Write-Divider -Char '-'
}

function Show-WorkflowReport {
    param([System.Collections.ArrayList]$Results)
    Write-Host ''
    Write-Divider
    Write-Host '  Workflow Report' -ForegroundColor Cyan
    Write-Divider
    foreach ($r in $Results) {
        Write-StatusLine -Message $r.Message -Status $r.Status
    }
    Write-Divider
}
