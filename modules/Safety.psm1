<#
.SYNOPSIS
    Safety.psm1 - Admin elevation, restore points, pre-flight checks for 99SAK v2
#>

# ---------------------------------------------------------------------------
# Admin
# ---------------------------------------------------------------------------

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Is-Admin) { return }
    Write-Host ''
    Write-Host '  Requires Administrator privileges. Relaunching elevated...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host '  Could not auto-elevate. Please right-click the launcher and select Run as Administrator.' -ForegroundColor Red
        Pause-ForUser
    }
    exit
}

# ---------------------------------------------------------------------------
# Restore point
# ---------------------------------------------------------------------------

function New-SafetyRestorePoint {
    param([string]$Description = '99SAK Checkpoint')
    Write-Host ("  Creating restore point: {0}" -f $Description) -ForegroundColor DarkGray
    try {
        # Enable System Restore on C: if it's disabled (best effort)
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-StatusLine "Restore point created: $Description" 'OK'
        Log-Event "Restore point created: $Description" 'ACTION'
        return $true
    } catch {
        $msg = $_.Exception.Message -replace '\r?\n', ' '
        Write-StatusLine "Restore point unavailable: $msg" 'WARN'
        Log-Event "Restore point failed: $msg" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Pre-flight system checks
# ---------------------------------------------------------------------------

function Test-PreFlight {
    param([int]$MinFreeGB = 1)
    Write-Host '  Pre-flight checks' -ForegroundColor DarkGray
    Write-Host ''
    $pass = $true

    # Elevation
    if (Is-Admin) {
        Write-StatusLine 'Running as Administrator' 'OK'
    } else {
        Write-StatusLine 'Not running as Administrator' 'ERROR'
        $pass = $false
    }

    # PowerShell version
    $ver = $PSVersionTable.PSVersion
    if ($ver.Major -ge 5) {
        Write-StatusLine ('PowerShell {0}.{1}' -f $ver.Major, $ver.Minor) 'OK'
    } else {
        Write-StatusLine ('PowerShell {0}.{1} — version 5.1+ recommended' -f $ver.Major, $ver.Minor) 'WARN'
    }

    # Disk space on system drive
    try {
        $drv = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($drv) {
            $gb = [math]::Round($drv.Free / 1GB, 1)
            if ($gb -ge $MinFreeGB) {
                Write-StatusLine ('Free disk: {0} GB on {1}' -f $gb, $env:SystemDrive) 'OK'
            } else {
                Write-StatusLine ('Low disk space: {0} GB free on {1}' -f $gb, $env:SystemDrive) 'WARN'
            }
        }
    } catch {}

    # Execution policy (informational)
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        Write-StatusLine ('Execution policy: {0}' -f $policy) 'INFO'
    } catch {}

    Write-Host ''
    return $pass
}

# ---------------------------------------------------------------------------
# State snapshot (used before risky operations)
# ---------------------------------------------------------------------------

function Save-NetworkSnapshot {
    param([string]$OutDir)
    try {
        $path = Join-Path $OutDir ('network_snapshot_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $out  = @()
        $out += '=== IP Config ==='
        $out += (ipconfig /all)
        $out += ''
        $out += '=== Routing Table ==='
        $out += (route print)
        $out += ''
        $out += '=== ARP Cache ==='
        $out += (arp -a)
        $out | Out-File -FilePath $path -Encoding UTF8 -Force
        return $path
    } catch { return $null }
}
