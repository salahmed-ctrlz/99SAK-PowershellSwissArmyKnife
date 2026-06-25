<#
.SYNOPSIS
    Workflows.psm1 - Guided multi-step safety workflows for 99SAK v2
    Each workflow: pre-flight check, auto restore point, animated steps,
    per-step status, final report, optional .txt export.
#>

# ---------------------------------------------------------------------------
# Shared workflow engine
# ---------------------------------------------------------------------------

function Invoke-WorkflowStep {
    param(
        [int]$Step,
        [int]$Total,
        [string]$Name,
        [scriptblock]$Action,
        [System.Collections.ArrayList]$Results,
        [switch]$ContinueOnError
    )

    Show-WorkflowStep -Step $Step -Total $Total -Name $Name

    try {
        & $Action
        $null = $Results.Add([PSCustomObject]@{ Step=$Step; Name=$Name; Status='OK';   Message=$Name })
        Write-StatusLine $Name 'OK'
    } catch {
        $msg = $_.Exception.Message -replace '\r?\n', ' '
        $null = $Results.Add([PSCustomObject]@{ Step=$Step; Name=$Name; Status='ERROR'; Message="$Name - $msg" })
        Write-StatusLine ("$Name - $msg") 'ERROR'
        Log-Event "Workflow step $Step failed: $msg" 'ERROR'
        if (-not $ContinueOnError) { throw }
    }
}

function Export-WorkflowReport {
    param([string]$Title, [System.Collections.ArrayList]$Results, [string[]]$Lines)
    $out  = Join-Path $env:USERPROFILE "Desktop\99SAK_workflow_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $text = @()
    $text += "99SAK Workflow Report"
    $text += ("Workflow: {0}" -f $Title)
    $text += ("Date:     {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $text += ("Host:     {0}  User: {1}" -f $env:COMPUTERNAME, $env:USERNAME)
    $text += ''
    $text += '--- Steps ---'
    foreach ($r in $Results) {
        $text += ('[{0}]  {1}' -f $r.Status.PadRight(5), $r.Message)
    }
    if ($Lines -and $Lines.Count -gt 0) {
        $text += ''
        $text += '--- Output ---'
        $text += $Lines
    }
    $text | Out-File -FilePath $out -Encoding UTF8 -Force
    Write-Host ("  Report saved: {0}" -f $out) -ForegroundColor Green
    Log-Event "Workflow report saved: $out" 'WORKFLOW'
}

# ---------------------------------------------------------------------------
# Workflow 1: Deep System Health Check (read-only)
# ---------------------------------------------------------------------------

function Invoke-HealthCheckWorkflow {
    $title   = 'Deep System Health Check'
    $results = [System.Collections.ArrayList]@()
    $output  = [System.Collections.ArrayList]@()

    Show-WorkflowBanner -Title $title -Subtitle 'Read-only diagnosis - no changes made to the system'

    Write-Host '  This workflow collects system health data and generates a report.' -ForegroundColor DarkGray
    Write-Host '  No changes will be made.' -ForegroundColor DarkGray
    Write-Host ''
    $ans = Read-InputWithBossKey 'Start health check? (Y/N)'
    if ($ans.ToUpper() -ne 'Y') { return }

    $total = 8

    # Step 1: OS and Windows Update
    Show-WorkflowStep 1 $total 'Windows version and update status'
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $wuv = (Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending |
                Select-Object -First 1)
        $info = "OS: {0} (Build {1})  Last patch: {2}" -f $os.Caption, $os.BuildNumber,
            $(if ($wuv) { $wuv.InstalledOn.ToString('yyyy-MM-dd') } else { 'unknown' })
        Write-StatusLine $info 'OK'
        $null = $output.Add($info)
        $null = $results.Add([PSCustomObject]@{ Step=1; Name='OS info'; Status='OK'; Message=$info })
    } catch {
        Write-StatusLine "Could not read OS info: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=1; Name='OS info'; Status='WARN'; Message="$_" })
    }

    # Step 2: Disk health via SMART
    Show-WorkflowStep 2 $total 'Disk health (physical drives)'
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        foreach ($d in $disks) {
            $st = $d.HealthStatus
            $color = if ($st -eq 'Healthy') { 'OK' } else { 'WARN' }
            $msg = "{0}  {1}  {2} GB  {3}" -f $d.FriendlyName, $d.MediaType,
                [math]::Round($d.Size/1GB,0), $st
            Write-StatusLine $msg $color
            $null = $output.Add($msg)
            $null = $results.Add([PSCustomObject]@{ Step=2; Name=$d.FriendlyName; Status=$color; Message=$msg })
        }
    } catch {
        Write-StatusLine "Disk SMART query failed (cmdlet unavailable on this SKU)" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Disk health'; Status='WARN'; Message='Get-PhysicalDisk not available' })
    }

    # Step 3: SFC verify (non-destructive)
    Show-WorkflowStep 3 $total 'System file integrity (SFC /verifyonly)'
    Write-Host '  Running - this may take a few minutes...' -ForegroundColor DarkGray
    try {
        $sfcOut = sfc /verifyonly 2>&1
        $sfcStr = ($sfcOut | Where-Object { $_ }) -join ' '
        if ($sfcStr -match 'did not find any integrity violations') {
            Write-StatusLine 'No integrity violations found' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=3; Name='SFC verify'; Status='OK'; Message='No integrity violations' })
        } else {
            Write-StatusLine 'Integrity violations detected - run System Repair workflow' 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=3; Name='SFC verify'; Status='WARN'; Message='Violations found - run System Repair' })
        }
        $null = $output.Add("SFC: $sfcStr")
    } catch {
        Write-StatusLine "SFC failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=3; Name='SFC verify'; Status='WARN'; Message="$_" })
    }

    # Step 4: DISM image check
    Show-WorkflowStep 4 $total 'Windows image health (DISM /CheckHealth)'
    try {
        $dismOut = DISM /Online /Cleanup-Image /CheckHealth 2>&1
        $dismStr = ($dismOut | Where-Object { $_ }) -join ' '
        if ($dismStr -match 'No component store corruption detected') {
            Write-StatusLine 'Component store: healthy' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=4; Name='DISM check'; Status='OK'; Message='Component store healthy' })
        } else {
            Write-StatusLine 'Component store may be corrupted - run System Repair workflow' 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=4; Name='DISM check'; Status='WARN'; Message='Possible corruption detected' })
        }
    } catch {
        Write-StatusLine "DISM failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=4; Name='DISM check'; Status='WARN'; Message="$_" })
    }

    # Step 5: RAM - check event log for memory errors
    Show-WorkflowStep 5 $total 'Memory - event log check'
    try {
        $memErrors = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=@(1, 41, 1001); Level=@(1,2) } `
            -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($memErrors) {
            Write-StatusLine ("Found {0} memory/crash events in System log" -f $memErrors.Count) 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=5; Name='Memory'; Status='WARN'; Message="$($memErrors.Count) memory/crash events found" })
        } else {
            Write-StatusLine 'No critical memory events in System log' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=5; Name='Memory'; Status='OK'; Message='No memory errors in event log' })
        }
    } catch {
        Write-StatusLine 'Could not query event log' 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=5; Name='Memory'; Status='WARN'; Message='Event log query failed' })
    }

    # Step 6: Top CPU/RAM hogs
    Show-WorkflowStep 6 $total 'Top resource consumers'
    try {
        $procs = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5
        foreach ($p in $procs) {
            $msg = "{0,-22}  CPU: {1,6:F1}s  RAM: {2,6} MB" -f $p.Name,
                $p.CPU, [math]::Round($p.WorkingSet64 / 1MB, 0)
            Write-Host ("  {0}" -f $msg) -ForegroundColor Gray
            $null = $output.Add($msg)
        }
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Top processes'; Status='OK'; Message='Listed top 5 processes' })
    } catch {
        Write-StatusLine "Could not list processes: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Top processes'; Status='WARN'; Message="$_" })
    }

    # Step 7: Firewall status
    Show-WorkflowStep 7 $total 'Firewall status'
    try {
        $fw = Get-NetFirewallProfile -ErrorAction Stop
        $off = $fw | Where-Object { $_.Enabled -eq $false }
        if ($off) {
            $profiles = ($off | Select-Object -ExpandProperty Name) -join ', '
            Write-StatusLine ("Firewall DISABLED on: {0}" -f $profiles) 'ERROR'
            $null = $results.Add([PSCustomObject]@{ Step=7; Name='Firewall'; Status='ERROR'; Message="Disabled on: $profiles" })
        } else {
            Write-StatusLine 'Firewall enabled on all profiles' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=7; Name='Firewall'; Status='OK'; Message='Enabled on all profiles' })
        }
    } catch {
        Write-StatusLine "Could not check firewall: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=7; Name='Firewall'; Status='WARN'; Message="$_" })
    }

    # Step 8: Disk space warnings
    Show-WorkflowStep 8 $total 'Disk space'
    try {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
            $freeGB = [math]::Round($_.Free / 1GB, 1)
            $totGB  = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
            if ($totGB -gt 0) {
                $pct = [math]::Round(($_.Free / ($_.Used + $_.Free)) * 100, 0)
                $st  = if ($pct -lt 10) { 'ERROR' } elseif ($pct -lt 20) { 'WARN' } else { 'OK' }
                $msg = "{0}:  {1} GB free / {2} GB total  ({3}% free)" -f $_.Name, $freeGB, $totGB, $pct
                Write-StatusLine $msg $st
                $null = $output.Add($msg)
                $null = $results.Add([PSCustomObject]@{ Step=8; Name="Disk $($_.Name):"; Status=$st; Message=$msg })
            }
        }
    } catch {
        Write-StatusLine "Disk check failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=8; Name='Disk space'; Status='WARN'; Message="$_" })
    }

    # Final report
    Write-Host ''
    Show-WorkflowReport -Results $results

    $errors = ($results | Where-Object { $_.Status -eq 'ERROR' }).Count
    $warns  = ($results | Where-Object { $_.Status -eq 'WARN'  }).Count
    Write-Host ("  Summary: {0} error(s), {1} warning(s)" -f $errors, $warns) -ForegroundColor $(
        if ($errors -gt 0) { 'Red' } elseif ($warns -gt 0) { 'Yellow' } else { 'Green' })

    $save = Read-InputWithBossKey 'Save report to Desktop? (Y/N)'
    if ($save.ToUpper() -eq 'Y') {
        Export-WorkflowReport -Title $title -Results $results -Lines $output
    }

    Log-Event "Workflow: $title completed. Errors:$errors Warns:$warns" 'WORKFLOW'
    Pause-ForUser
}

# ---------------------------------------------------------------------------
# Workflow 2: Full System Repair
# ---------------------------------------------------------------------------

function Invoke-SystemRepairWorkflow {
    $title   = 'Full System Repair'
    $results = [System.Collections.ArrayList]@()

    Show-WorkflowBanner -Title $title -Subtitle 'SFC + DISM RestoreHealth + verify - low risk, may take 30+ minutes'
    Test-PreFlight
    Write-Host ''

    $ans = Read-InputWithBossKey 'Start system repair? (Y/N)'
    if ($ans.ToUpper() -ne 'Y') { return }

    $total = 5

    # Step 1: Restore point
    Show-WorkflowStep 1 $total 'Creating system restore point'
    $rp = New-SafetyRestorePoint -Description '99SAK-SystemRepair'
    $null = $results.Add([PSCustomObject]@{ Step=1; Name='Restore point';
        Status=$(if ($rp) { 'OK' } else { 'WARN' });
        Message=$(if ($rp) { 'Restore point created' } else { 'Restore point skipped (may not be available)' }) })

    # Step 2: SFC
    Show-WorkflowStep 2 $total 'Running SFC /scannow (system file repair)'
    Write-Host '  This can take 10-20 minutes...' -ForegroundColor DarkGray
    $sfcOut = sfc /scannow 2>&1
    $sfcStr = ($sfcOut | Where-Object { $_ }) -join ' '
    $sfcOK  = $sfcStr -match 'did not find any integrity violations' -or
              $sfcStr -match 'successfully repaired'
    Write-StatusLine $(if ($sfcOK) { 'SFC complete - no unfixable violations' } else { 'SFC found issues - running DISM to repair' }) $(if ($sfcOK) { 'OK' } else { 'WARN' })
    $null = $results.Add([PSCustomObject]@{ Step=2; Name='SFC';
        Status=$(if ($sfcOK) { 'OK' } else { 'WARN' });
        Message=$(if ($sfcOK) { 'No violations or repaired' } else { 'Issues found, DISM will repair' }) })

    # Step 3: DISM RestoreHealth (run regardless to ensure image is clean)
    Show-WorkflowStep 3 $total 'Running DISM /Online /Cleanup-Image /RestoreHealth'
    Write-Host '  This can take 15-30 minutes and requires internet access...' -ForegroundColor DarkGray
    try {
        $dismOut = DISM /Online /Cleanup-Image /RestoreHealth 2>&1
        $dismStr = ($dismOut | Where-Object { $_ }) -join ' '
        $dismOK  = $dismStr -match 'operation completed successfully'
        Write-StatusLine $(if ($dismOK) { 'DISM RestoreHealth complete' } else { 'DISM may have encountered issues' }) $(if ($dismOK) { 'OK' } else { 'WARN' })
        $null = $results.Add([PSCustomObject]@{ Step=3; Name='DISM';
            Status=$(if ($dismOK) { 'OK' } else { 'WARN' });
            Message=$(if ($dismOK) { 'RestoreHealth complete' } else { 'Check DISM log: C:\Windows\Logs\DISM\dism.log' }) })
    } catch {
        Write-StatusLine "DISM failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=3; Name='DISM'; Status='WARN'; Message="$_" })
    }

    # Step 4: SFC re-verify
    Show-WorkflowStep 4 $total 'Re-running SFC to verify repair'
    $sfcOut2 = sfc /verifyonly 2>&1
    $sfcStr2 = ($sfcOut2 | Where-Object { $_ }) -join ' '
    $sfcOK2  = $sfcStr2 -match 'did not find any integrity violations'
    Write-StatusLine $(if ($sfcOK2) { 'System files verified - clean' } else { 'Some files may still need attention' }) $(if ($sfcOK2) { 'OK' } else { 'WARN' })
    $null = $results.Add([PSCustomObject]@{ Step=4; Name='SFC verify';
        Status=$(if ($sfcOK2) { 'OK' } else { 'WARN' });
        Message=$(if ($sfcOK2) { 'All system files verified clean' } else { 'Manual review may be needed' }) })

    # Step 5: Reboot advisory
    Show-WorkflowStep 5 $total 'Post-repair advisory'
    Write-StatusLine 'Repair sequence complete. A reboot is recommended.' 'INFO'
    $null = $results.Add([PSCustomObject]@{ Step=5; Name='Advisory'; Status='INFO'; Message='Reboot recommended to finalize repairs' })

    Write-Host ''
    Show-WorkflowReport -Results $results

    $save = Read-InputWithBossKey 'Save report to Desktop? (Y/N)'
    if ($save.ToUpper() -eq 'Y') { Export-WorkflowReport -Title $title -Results $results -Lines @() }

    $reboot = Read-InputWithBossKey 'Reboot now? (Y/N)'
    if ($reboot.ToUpper() -eq 'Y') { Restart-Computer -Force }

    Log-Event "Workflow: $title completed" 'WORKFLOW'
}

# ---------------------------------------------------------------------------
# Workflow 3: Network Full Reset & Repair
# ---------------------------------------------------------------------------

function Invoke-NetworkResetWorkflow {
    $title   = 'Network Full Reset & Repair'
    $results = [System.Collections.ArrayList]@()
    $snap    = $null

    Show-WorkflowBanner -Title $title -Subtitle 'Winsock + TCP/IP reset, DNS flush, adapter renew, connectivity test'
    Write-Host '  Risk: Moderate - resets network stack. Reboot required.' -ForegroundColor Yellow
    Write-Host ''
    Test-PreFlight
    Write-Host ''

    $ans = Read-InputWithBossKey 'Start network reset? (Y/N)'
    if ($ans.ToUpper() -ne 'Y') { return }

    $total = 9

    # Step 1: Restore point
    Show-WorkflowStep 1 $total 'Creating restore point'
    $rp = New-SafetyRestorePoint -Description '99SAK-NetworkReset'
    $null = $results.Add([PSCustomObject]@{ Step=1; Name='Restore point';
        Status=$(if ($rp) { 'OK' } else { 'WARN' });
        Message=$(if ($rp) { 'Created' } else { 'Skipped' }) })

    # Step 2: Snapshot current config
    Show-WorkflowStep 2 $total 'Snapshotting current network configuration'
    $snapDir = Join-Path $script:RootDir 'Logs'
    $snap = Save-NetworkSnapshot -OutDir $snapDir
    if ($snap) {
        Write-StatusLine ("Snapshot saved: {0}" -f $snap) 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Snapshot'; Status='OK'; Message="Saved to $snap" })
    } else {
        Write-StatusLine 'Snapshot failed' 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Snapshot'; Status='WARN'; Message='Could not save snapshot' })
    }

    # Step 3: Release IP
    Show-WorkflowStep 3 $total 'Releasing IP address'
    ipconfig /release 2>&1 | Out-Null
    Write-StatusLine 'IP released' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=3; Name='IP release'; Status='OK'; Message='Released' })

    # Step 4: TCP/IP reset
    Show-WorkflowStep 4 $total 'Resetting TCP/IP stack'
    netsh int ip reset 2>&1 | Out-Null
    Write-StatusLine 'TCP/IP stack reset' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=4; Name='TCP/IP reset'; Status='OK'; Message='Complete' })

    # Step 5: Winsock reset
    Show-WorkflowStep 5 $total 'Resetting Winsock catalog'
    netsh winsock reset 2>&1 | Out-Null
    Write-StatusLine 'Winsock reset' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=5; Name='Winsock reset'; Status='OK'; Message='Complete' })

    # Step 6: DNS flush
    Show-WorkflowStep 6 $total 'Flushing DNS cache'
    ipconfig /flushdns 2>&1 | Out-Null
    Write-StatusLine 'DNS cache flushed' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=6; Name='DNS flush'; Status='OK'; Message='Complete' })

    # Step 7: Re-enable adapters
    Show-WorkflowStep 7 $total 'Re-enabling network adapters'
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    foreach ($a in $adapters) {
        Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-StatusLine 'Adapters enabled' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=7; Name='Adapters'; Status='OK'; Message='All adapters enabled' })

    # Step 8: Renew IP
    Show-WorkflowStep 8 $total 'Renewing IP address'
    Start-Sleep -Seconds 3
    ipconfig /renew 2>&1 | Out-Null
    Write-StatusLine 'IP renewal attempted' 'OK'
    $null = $results.Add([PSCustomObject]@{ Step=8; Name='IP renew'; Status='OK'; Message='Renewal sent' })

    # Step 9: Connectivity test
    Show-WorkflowStep 9 $total 'Testing connectivity'
    Start-Sleep -Seconds 2
    $ping8   = Test-Connection -ComputerName '8.8.8.8'    -Count 2 -Quiet -ErrorAction SilentlyContinue
    $pingDNS = Test-Connection -ComputerName 'www.google.com' -Count 2 -Quiet -ErrorAction SilentlyContinue

    if ($ping8) {
        Write-StatusLine 'IP connectivity: OK (reached 8.8.8.8)' 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=9; Name='IP connectivity'; Status='OK'; Message='8.8.8.8 reachable' })
    } else {
        Write-StatusLine 'IP connectivity: FAILED - reboot and retry' 'ERROR'
        $null = $results.Add([PSCustomObject]@{ Step=9; Name='IP connectivity'; Status='ERROR'; Message='8.8.8.8 not reachable - reboot required' })
    }
    if ($pingDNS) {
        Write-StatusLine 'DNS resolution: OK (google.com resolved)' 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=9; Name='DNS resolution'; Status='OK'; Message='www.google.com resolved' })
    } else {
        Write-StatusLine 'DNS resolution: FAILED - may resolve after reboot' 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=9; Name='DNS resolution'; Status='WARN'; Message='Could not resolve www.google.com' })
    }

    Write-Host ''
    Show-WorkflowReport -Results $results
    Write-Host '  Note: full effect requires a reboot.' -ForegroundColor DarkGray

    $save = Read-InputWithBossKey 'Save report to Desktop? (Y/N)'
    if ($save.ToUpper() -eq 'Y') { Export-WorkflowReport -Title $title -Results $results -Lines @() }

    $reboot = Read-InputWithBossKey 'Reboot now? (Y/N)'
    if ($reboot.ToUpper() -eq 'Y') { Restart-Computer -Force }

    Log-Event "Workflow: $title completed" 'WORKFLOW'
}

# ---------------------------------------------------------------------------
# Workflow 4: Malware / Compromise Triage
# ---------------------------------------------------------------------------

function Invoke-MalwareTriage {
    $title   = 'Malware / Compromise Triage'
    $results = [System.Collections.ArrayList]@()
    $output  = [System.Collections.ArrayList]@()

    Show-WorkflowBanner -Title $title -Subtitle 'Startup, ports, hosts, unsigned processes, Defender scan - mostly read-only'

    $ans = Read-InputWithBossKey 'Start triage? (Y/N)'
    if ($ans.ToUpper() -ne 'Y') { return }

    $total = 7

    # Step 1: Suspicious startup entries
    Show-WorkflowStep 1 $total 'Startup entries (HKCU + HKLM Run keys)'
    try {
        $startups = @()
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' |
            ForEach-Object {
                $reg = Get-ItemProperty $_ -ErrorAction SilentlyContinue
                if ($reg) {
                    $reg.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                        ForEach-Object { $startups += "$($_.Name) = $($_.Value)" }
                }
            }
        foreach ($s in $startups) {
            Write-Host ("  {0}" -f $s) -ForegroundColor Gray
            $null = $output.Add("Startup: $s")
        }
        Write-StatusLine ("{0} startup entries found" -f $startups.Count) 'INFO'
        $null = $results.Add([PSCustomObject]@{ Step=1; Name='Startup entries'; Status='INFO'; Message="$($startups.Count) entries found - review above" })
    } catch {
        Write-StatusLine "Failed to read startup entries: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=1; Name='Startup entries'; Status='WARN'; Message="$_" })
    }

    # Step 2: Listening ports with process names
    Show-WorkflowStep 2 $total 'Listening ports (with owning processes)'
    try {
        $listeners = Get-NetTCPConnection -State Listen -ErrorAction Stop
        $badPorts  = Get-DataFile 'bad_ports.json'
        $flagged   = 0
        foreach ($l in $listeners) {
            $proc = try { (Get-Process -Id $l.OwningProcess -EA SilentlyContinue).Name } catch { '?' }
            $risk = if ($badPorts -and $badPorts.PSObject.Properties[$l.LocalPort.ToString()]) { 'FLAGGED' } else { '' }
            $msg  = "Port {0,-6}  Process: {1,-25}  {2}" -f $l.LocalPort, $proc, $risk
            $col  = if ($risk) { 'Yellow' } else { 'DarkGray' }
            Write-Host ("  {0}" -f $msg) -ForegroundColor $col
            $null = $output.Add("Port: $msg")
            if ($risk) { $flagged++ }
        }
        Write-StatusLine ("{0} flagged port(s) listening" -f $flagged) $(if ($flagged -gt 0) { 'WARN' } else { 'OK' })
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Listening ports';
            Status=$(if ($flagged -gt 0) { 'WARN' } else { 'OK' });
            Message="$flagged risky port(s) listening" })
    } catch {
        Write-StatusLine "Port check failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Listening ports'; Status='WARN'; Message="$_" })
    }

    # Step 3: Hosts file check
    Show-WorkflowStep 3 $total 'Hosts file - unauthorized entries'
    try {
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $entries   = Get-Content $hostsPath | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
        if ($entries) {
            foreach ($e in $entries) {
                Write-Host ("  {0}" -f $e) -ForegroundColor Gray
                $null = $output.Add("Hosts: $e")
            }
            Write-StatusLine ("{0} active hosts file entry/entries - review above" -f $entries.Count) 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=3; Name='Hosts file'; Status='WARN'; Message="$($entries.Count) active entries" })
        } else {
            Write-StatusLine 'Hosts file has no active entries' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=3; Name='Hosts file'; Status='OK'; Message='No active entries' })
        }
    } catch {
        Write-StatusLine "Could not read hosts file: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=3; Name='Hosts file'; Status='WARN'; Message="$_" })
    }

    # Step 4: Unsigned running processes
    Show-WorkflowStep 4 $total 'Unsigned running process check'
    Write-Host '  Checking process signatures...' -ForegroundColor DarkGray
    try {
        $unsigned = @()
        Get-Process | Where-Object { $_.Path } | ForEach-Object {
            $sig = Get-AuthenticodeSignature -FilePath $_.Path -ErrorAction SilentlyContinue
            if ($sig -and $sig.Status -notin @('Valid', 'NotSigned')) {
                $unsigned += $_.Name
                Write-Host ("  [UNSIGNED]  {0}  {1}" -f $_.Name, $_.Path) -ForegroundColor Yellow
                $null = $output.Add("Unsigned: $($_.Name) - $($_.Path)")
            }
        }
        Write-StatusLine ("{0} unsigned/invalid signature process(es)" -f $unsigned.Count) $(if ($unsigned.Count -gt 0) { 'WARN' } else { 'OK' })
        $null = $results.Add([PSCustomObject]@{ Step=4; Name='Unsigned processes';
            Status=$(if ($unsigned.Count -gt 0) { 'WARN' } else { 'OK' });
            Message="$($unsigned.Count) unsigned process(es) found" })
    } catch {
        Write-StatusLine "Signature check failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=4; Name='Unsigned processes'; Status='WARN'; Message="$_" })
    }

    # Step 5: Recently modified scheduled tasks
    Show-WorkflowStep 5 $total 'Recently modified scheduled tasks (last 7 days)'
    try {
        $cutoff = (Get-Date).AddDays(-7)
        $tasks  = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Date -and ([datetime]$_.Date) -gt $cutoff } catch { $false }
        }
        if ($tasks -and $tasks.Count -gt 0) {
            foreach ($t in $tasks) {
                Write-Host ("  {0}  {1}" -f $t.TaskName, $t.Date) -ForegroundColor Yellow
                $null = $output.Add("Recent task: $($t.TaskName) $($t.Date)")
            }
            Write-StatusLine ("{0} task(s) modified in last 7 days" -f $tasks.Count) 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=5; Name='Scheduled tasks'; Status='WARN'; Message="$($tasks.Count) recently modified" })
        } else {
            Write-StatusLine 'No recently modified scheduled tasks' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=5; Name='Scheduled tasks'; Status='OK'; Message='None recently modified' })
        }
    } catch {
        Write-StatusLine "Scheduled task check failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=5; Name='Scheduled tasks'; Status='WARN'; Message="$_" })
    }

    # Step 6: Defender quick scan
    Show-WorkflowStep 6 $total 'Running Defender quick scan'
    try {
        Start-MpScan -ScanType QuickScan -ErrorAction Stop
        Write-StatusLine 'Defender quick scan started (runs in background)' 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Defender scan'; Status='OK'; Message='Quick scan initiated' })
    } catch {
        Write-StatusLine "Defender scan not available: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Defender scan'; Status='WARN'; Message='Defender not available' })
    }

    # Step 7: Recently installed programs
    Show-WorkflowStep 7 $total 'Programs installed in last 7 days'
    try {
        $cutoff   = (Get-Date).AddDays(-7).ToString('yyyyMMdd')
        $recent   = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue |
            Where-Object { $_.InstallDate -and $_.InstallDate -ge $cutoff -and $_.DisplayName } |
            Select-Object DisplayName, InstallDate
        if ($recent -and $recent.Count -gt 0) {
            foreach ($p in $recent) {
                Write-Host ("  {0}  (installed: {1})" -f $p.DisplayName, $p.InstallDate) -ForegroundColor Yellow
                $null = $output.Add("Recent install: $($p.DisplayName) $($p.InstallDate)")
            }
            Write-StatusLine ("{0} program(s) installed in last 7 days" -f $recent.Count) 'WARN'
            $null = $results.Add([PSCustomObject]@{ Step=7; Name='Recent installs'; Status='WARN'; Message="$($recent.Count) programs installed recently" })
        } else {
            Write-StatusLine 'No programs installed in last 7 days' 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=7; Name='Recent installs'; Status='OK'; Message='None' })
        }
    } catch {
        Write-StatusLine "Install check failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=7; Name='Recent installs'; Status='WARN'; Message="$_" })
    }

    Write-Host ''
    Show-WorkflowReport -Results $results

    $save = Read-InputWithBossKey 'Save full triage report to Desktop? (Y/N)'
    if ($save.ToUpper() -eq 'Y') { Export-WorkflowReport -Title $title -Results $results -Lines $output }

    Log-Event "Workflow: $title completed" 'WORKFLOW'
    Pause-ForUser
}

# ---------------------------------------------------------------------------
# Workflow 5: Pre-Maintenance Safety Backup
# ---------------------------------------------------------------------------

function Invoke-SafetyBackupWorkflow {
    $title   = 'Pre-Maintenance Safety Backup'
    $results = [System.Collections.ArrayList]@()
    $saved   = [System.Collections.ArrayList]@()

    Show-WorkflowBanner -Title $title -Subtitle 'Read-only backup of critical system state before any major change'
    Write-Host '  Everything is saved to your Desktop.' -ForegroundColor DarkGray
    Write-Host ''

    $ans = Read-InputWithBossKey 'Start safety backup? (Y/N)'
    if ($ans.ToUpper() -ne 'Y') { return }

    $desk  = [Environment]::GetFolderPath('Desktop')
    $ts    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $total = 6

    # Step 1: System restore point
    Show-WorkflowStep 1 $total 'System restore point'
    $label = "99SAK-PreMaintenance-$ts"
    $rp    = New-SafetyRestorePoint -Description $label
    $null  = $results.Add([PSCustomObject]@{ Step=1; Name='Restore point';
        Status=$(if ($rp) { 'OK' } else { 'WARN' });
        Message=$(if ($rp) { "Created: $label" } else { 'Skipped (System Restore may be disabled)' }) })

    # Step 2: Registry backup
    Show-WorkflowStep 2 $total 'Registry backup (HKLM)'
    $regPath = Join-Path $desk "99SAK_registry_$ts.reg"
    try {
        reg export HKLM $regPath /y 2>&1 | Out-Null
        Write-StatusLine ("Registry saved: {0}" -f $regPath) 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Registry'; Status='OK'; Message="Saved: $regPath" })
        $null = $saved.Add($regPath)
    } catch {
        Write-StatusLine "Registry backup failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=2; Name='Registry'; Status='WARN'; Message="$_" })
    }

    # Step 3: Network config snapshot
    Show-WorkflowStep 3 $total 'Network configuration snapshot'
    $netPath = Join-Path $desk "99SAK_network_$ts.txt"
    try {
        $snap = Save-NetworkSnapshot -OutDir $desk
        if ($snap) {
            # Move to our named file
            if (Test-Path $snap) { Move-Item $snap $netPath -Force -ErrorAction SilentlyContinue }
            Write-StatusLine ("Network config saved: {0}" -f $netPath) 'OK'
            $null = $results.Add([PSCustomObject]@{ Step=3; Name='Network config'; Status='OK'; Message="Saved: $netPath" })
            $null = $saved.Add($netPath)
        }
    } catch {
        Write-StatusLine "Network snapshot failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=3; Name='Network config'; Status='WARN'; Message="$_" })
    }

    # Step 4: Installed programs list
    Show-WorkflowStep 4 $total 'Installed programs list'
    $progPath = Join-Path $desk "99SAK_programs_$ts.txt"
    try {
        $progs = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
            ForEach-Object { Get-ItemProperty $_ -EA SilentlyContinue } |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
            Sort-Object DisplayName
        $progs | Format-Table -AutoSize | Out-File $progPath -Encoding UTF8 -Force
        Write-StatusLine ("Programs list saved: {0}  ({1} items)" -f $progPath, $progs.Count) 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=4; Name='Programs list'; Status='OK'; Message="$($progs.Count) programs - $progPath" })
        $null = $saved.Add($progPath)
    } catch {
        Write-StatusLine "Programs list failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=4; Name='Programs list'; Status='WARN'; Message="$_" })
    }

    # Step 5: Firewall rules export
    Show-WorkflowStep 5 $total 'Firewall rules export'
    $fwPath = Join-Path $desk "99SAK_firewall_$ts.txt"
    try {
        Get-NetFirewallRule | Select-Object Name, DisplayName, Enabled, Direction, Action, Profile |
            Format-Table -AutoSize | Out-File $fwPath -Encoding UTF8 -Force
        Write-StatusLine ("Firewall rules saved: {0}" -f $fwPath) 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=5; Name='Firewall rules'; Status='OK'; Message="Saved: $fwPath" })
        $null = $saved.Add($fwPath)
    } catch {
        Write-StatusLine "Firewall export failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=5; Name='Firewall rules'; Status='WARN'; Message="$_" })
    }

    # Step 6: Hosts file backup
    Show-WorkflowStep 6 $total 'Hosts file backup'
    $hostsPath = Join-Path $desk "99SAK_hosts_$ts.txt"
    try {
        Copy-Item "$env:SystemRoot\System32\drivers\etc\hosts" $hostsPath -Force
        Write-StatusLine ("Hosts file saved: {0}" -f $hostsPath) 'OK'
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Hosts file'; Status='OK'; Message="Saved: $hostsPath" })
        $null = $saved.Add($hostsPath)
    } catch {
        Write-StatusLine "Hosts backup failed: $_" 'WARN'
        $null = $results.Add([PSCustomObject]@{ Step=6; Name='Hosts file'; Status='WARN'; Message="$_" })
    }

    Write-Host ''
    Show-WorkflowReport -Results $results
    Write-Host ''
    Write-Host '  Files saved to Desktop:' -ForegroundColor DarkGray
    foreach ($f in $saved) { Write-Host ("  - {0}" -f $f) -ForegroundColor Gray }

    $open = Read-InputWithBossKey 'Open Desktop folder? (Y/N)'
    if ($open.ToUpper() -eq 'Y') { Start-Process $desk }

    Log-Event "Workflow: $title completed. Files saved: $($saved.Count)" 'WORKFLOW'
    Pause-ForUser
}

# ---------------------------------------------------------------------------
# Workflow selection menu
# ---------------------------------------------------------------------------

function Show-WorkflowMenu {
    while ($true) {
        Show-MiniHeader -Breadcrumbs @('Main', 'Safety Workflows')
        Write-SectionLabel 'Safety Workflows'
        Write-Host '  Each workflow creates a restore point, logs every action, and produces a report.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Option -Key '1' -Description 'System Health Check          (read-only, no risk)'
        Write-Option -Key '2' -Description 'Full System Repair           (SFC + DISM, low risk)'
        Write-Option -Key '3' -Description 'Network Full Reset & Repair  (Winsock + TCP/IP, moderate risk)'
        Write-Option -Key '4' -Description 'Malware / Compromise Triage  (scan + audit, low risk)'
        Write-Option -Key '5' -Description 'Pre-Maintenance Safety Backup (read-only backup)'
        Write-Host ''
        Write-Option -Key 'B' -Description 'Back' -KeyColor Red
        Write-Host ''
        Write-Divider

        $c = (Read-InputWithBossKey 'Choice').ToUpper()
        switch ($c) {
            '1' { Invoke-HealthCheckWorkflow    }
            '2' { Invoke-SystemRepairWorkflow   }
            '3' { Invoke-NetworkResetWorkflow   }
            '4' { Invoke-MalwareTriage          }
            '5' { Invoke-SafetyBackupWorkflow   }
            'B' { return }
            default {
                Write-Host '  Invalid choice.' -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 400
            }
        }
    }
}
