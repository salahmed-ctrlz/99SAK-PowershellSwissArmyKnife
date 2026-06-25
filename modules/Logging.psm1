<#
.SYNOPSIS
    Logging.psm1 - Logging engine for 99SAK v2
    Writes structured log entries, handles rotation, and provides an
    interactive log viewer with keyword filtering and export.
#>

$script:_LogDir    = ''
$script:_LogFile   = ''
$script:_SessionID = ''

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

function Initialize-Logging {
    param([string]$ScriptRoot, [string]$SessionID)
    $script:_SessionID = $SessionID
    $script:_LogDir    = Join-Path $ScriptRoot 'Logs'
    if (-not (Test-Path $script:_LogDir)) {
        New-Item -Path $script:_LogDir -ItemType Directory -Force | Out-Null
    }
    $script:_LogFile = Join-Path $script:_LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
    Log-Event 'Session started' 'INFO'
    Start-LogRotation
}

# ---------------------------------------------------------------------------
# Core logging
# ---------------------------------------------------------------------------

function Log-Event {
    param(
        [string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','ACTION','WORKFLOW')]
        [string]$Level = 'INFO'
    )
    try {
        if (-not $script:_LogFile) { return }
        $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $entry = '{0}  [{1}]  [{2}]  {3}  (user:{4}  host:{5})' -f `
            $ts, $Level.PadRight(8), $script:_SessionID, `
            $Message, $env:USERNAME, $env:COMPUTERNAME
        Add-Content -Path $script:_LogFile -Value $entry -ErrorAction SilentlyContinue
    } catch {}
}

# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------

function Start-LogRotation {
    try {
        $cutoff  = (Get-Date).AddDays(-30)
        $archDir = Join-Path $script:_LogDir 'Archive'
        Get-ChildItem -Path $script:_LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                if (-not (Test-Path $archDir)) {
                    New-Item $archDir -ItemType Directory -Force | Out-Null
                }
                Move-Item $_.FullName (Join-Path $archDir $_.Name) -Force -ErrorAction SilentlyContinue
            }
    } catch {}
}

# ---------------------------------------------------------------------------
# Reading & export
# ---------------------------------------------------------------------------

function Get-LogContent {
    param([string]$Date = '')
    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
    $path = Join-Path $script:_LogDir "$Date.log"
    if (Test-Path $path) { return (Get-Content $path) }
    return @()
}

function Export-LogToFile {
    param([string]$Date = '', [string]$OutPath = '')
    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
    $lines = Get-LogContent -Date $Date
    if (-not $lines -or $lines.Count -eq 0) {
        Write-Host '  No log entries found for that date.' -ForegroundColor Yellow
        return $false
    }
    if (-not $OutPath) {
        $OutPath = Join-Path $env:USERPROFILE "Desktop\99SAK_log_$Date.txt"
    }
    try {
        $lines | Out-File -FilePath $OutPath -Encoding UTF8 -Force
        Write-Host ("  Saved to: {0}" -f $OutPath) -ForegroundColor Green
        Log-Event "Log exported: $OutPath" 'ACTION'
        return $true
    } catch {
        Write-Host ("  Export failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Log-Event "Log export failed: $_" 'ERROR'
        return $false
    }
}

function Get-LogFilePath { return $script:_LogFile }

# ---------------------------------------------------------------------------
# Interactive log display
# ---------------------------------------------------------------------------

function Show-LogContents {
    param([string]$Date, [string]$Filter = '')
    $lines = Get-LogContent -Date $Date
    if ($Filter) { $lines = $lines | Where-Object { $_ -like "*$Filter*" } }

    Clear-Host
    Write-Host ''
    $hdr = "  Log:  $Date"
    if ($Filter) { $hdr += "  |  keyword: $Filter" }
    Write-Host $hdr -ForegroundColor Cyan
    Write-Divider

    if (-not $lines -or $lines.Count -eq 0) {
        Write-Host '  (no entries found)' -ForegroundColor DarkGray
    } else {
        foreach ($line in $lines) {
            if     ($line -match '\[ERROR   \]') { Write-Host "  $line" -ForegroundColor Red      }
            elseif ($line -match '\[WARN    \]') { Write-Host "  $line" -ForegroundColor Yellow   }
            elseif ($line -match '\[ACTION  \]') { Write-Host "  $line" -ForegroundColor Cyan     }
            elseif ($line -match '\[WORKFLOW \]') { Write-Host "  $line" -ForegroundColor Magenta }
            else                                  { Write-Host "  $line" -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
    Write-Divider
    Write-Host ("  {0} entries shown" -f $lines.Count) -ForegroundColor DarkGray
    $ans = Read-InputWithBossKey 'Enter to return, SAVE to export to .txt'
    if ($ans.ToUpper() -eq 'SAVE') {
        Export-LogToFile -Date $Date
        Pause-ForUser
    }
}

# ---------------------------------------------------------------------------
# Log viewer menu
# ---------------------------------------------------------------------------

function Show-LogViewer {
    while ($true) {
        Show-MiniHeader -Breadcrumbs @('Main', 'Logs')
        Write-SectionLabel 'Logs & Reports'

        Write-Option -Key '1' -Description "View today's log"
        Write-Option -Key '2' -Description "View yesterday's log"
        Write-Option -Key '3' -Description 'Search today''s log by keyword'
        Write-Option -Key '4' -Description "Export today's log to .txt"
        Write-Option -Key '5' -Description 'Export specific date to .txt'
        Write-Option -Key '6' -Description 'Archive logs older than 30 days'
        Write-Host ''
        Write-Option -Key 'B' -Description 'Back' -KeyColor Red
        Write-Host ''
        Write-Divider

        $c = (Read-InputWithBossKey 'Choice').ToUpper()

        switch ($c) {
            '1' {
                Show-LogContents -Date (Get-Date).ToString('yyyy-MM-dd')
            }
            '2' {
                Show-LogContents -Date (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
            }
            '3' {
                $kw = Read-InputWithBossKey 'Keyword'
                if ($kw) {
                    Show-LogContents -Date (Get-Date).ToString('yyyy-MM-dd') -Filter $kw
                }
            }
            '4' {
                Export-LogToFile
                Pause-ForUser
            }
            '5' {
                $d = Read-InputWithBossKey 'Date (yyyy-MM-dd)'
                if ($d) {
                    Export-LogToFile -Date $d
                    Pause-ForUser
                }
            }
            '6' {
                Start-LogRotation
                Write-Host '  Log rotation complete.' -ForegroundColor Green
                Pause-ForUser
            }
            'B' { return }
            default {
                Write-Host '  Invalid choice.' -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Session summary (called at exit)
# ---------------------------------------------------------------------------

function Write-SessionSummary {
    param(
        [DateTime]$Start,
        [int]$Actions,
        [int]$Errors,
        [string]$SessionID
    )
    $dur = (Get-Date) - $Start
    $durStr = '{0}m {1}s' -f [int]$dur.TotalMinutes, $dur.Seconds

    Clear-Host
    Write-Host ''
    Write-Divider
    Write-Host '  Session Complete' -ForegroundColor Cyan
    Write-Divider
    Write-Host ("  Session ID  {0}" -f $SessionID)   -ForegroundColor DarkGray
    Write-Host ("  Duration    {0}" -f $durStr)        -ForegroundColor Gray
    Write-Host ("  Actions     {0}" -f $Actions)       -ForegroundColor Gray
    if ($Errors -gt 0) {
        Write-Host ("  Errors      {0}" -f $Errors) -ForegroundColor Yellow
    } else {
        Write-Host '  Errors      0' -ForegroundColor Gray
    }
    if ($script:_LogFile) {
        Write-Host ("  Log         {0}" -f $script:_LogFile) -ForegroundColor DarkGray
    }
    Write-Divider
    Write-Host ''

    Log-Event ("Session ended  actions:$Actions  errors:$Errors  duration:$durStr") 'INFO'
}
