<#
.SYNOPSIS
    99SAK v2.0 - PowerShell Swiss Army Knife
    Portable, admin-elevated toolkit for IT professionals, help desk, and network engineers.
    Zero dependencies. Works on any Windows 10/11 PC.

.PARAMETER SelfTest
    Run a non-destructive smoke test (no system changes). Returns exit code 0 on pass.

.NOTES
    Launch via 99SAK.bat (double-click, auto-elevates to Administrator).
    Boss Key: Ctrl+B -- exits immediately from any prompt.
    Author: Salahuddin (https://github.com/salahmed-ctrlz)
#>
param([switch]$SelfTest)

# ---------------------------------------------------------------------------
# Bootstrap - dot-source modules
# ---------------------------------------------------------------------------

$script:RootDir = $PSScriptRoot

foreach ($Name in @('UI.psm1', 'Logging.psm1', 'Safety.psm1', 'Workflows.psm1')) {
    $path = Join-Path $script:RootDir "modules\$Name"
    if (Test-Path $path) {
        Import-Module $path -DisableNameChecking
    } else {
        Write-Host ("  [WARN] Module not found: {0}" -f $path) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Global session state
# ---------------------------------------------------------------------------

$script:SessionStart  = Get-Date
$script:SessionID     = [System.Guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
$script:ActionCount   = 0
$script:ErrorCount    = 0
$script:CmdHistory    = [System.Collections.ArrayList]@()

Initialize-Logging -ScriptRoot $script:RootDir -SessionID $script:SessionID

function Add-ToHistory {
    param([string]$Entry)
    if (-not $Entry) { return }
    $null = $script:CmdHistory.Insert(0, $Entry)
    if ($script:CmdHistory.Count -gt 10) { $script:CmdHistory.RemoveAt(10) }
}

function Track-Action {
    param([string]$Label)
    $script:ActionCount++
    Add-ToHistory $Label
    Log-Event $Label 'ACTION'
}

function Track-Error {
    param([string]$Label)
    $script:ErrorCount++
    Log-Event $Label 'ERROR'
}

# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------

function Get-DataFile {
    param([string]$Name)
    $path = Join-Path $script:RootDir "data\$Name"
    if (Test-Path $path) {
        return (Get-Content $path -Raw | ConvertFrom-Json)
    }
    return $null
}

# ---------------------------------------------------------------------------
# Command history
# ---------------------------------------------------------------------------

function Show-CommandHistory {
    Show-MiniHeader -Breadcrumbs @('Main', 'History')
    Write-SectionLabel 'Command History (last 10)'
    if ($script:CmdHistory.Count -eq 0) {
        Write-Host '  (no commands run this session)' -ForegroundColor DarkGray
    } else {
        $i = 1
        foreach ($entry in $script:CmdHistory) {
            Write-Host ("  {0,2}.  {1}" -f $i, $entry) -ForegroundColor Gray
            $i++
        }
    }
    Write-Host ''
    Write-Divider
    Pause-ForUser 'Press Enter to return'
}

# ===========================================================================
# NETWORKING FUNCTIONS
# ===========================================================================

function Net-ShowAdapters {
    Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MacAddress |
        Format-Table -AutoSize
}

function Net-EnableAdapter {
    $n = Read-InputWithBossKey 'Adapter name'
    if (-not $n) { return }
    try { Enable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop; Write-Host "  Enabled: $n" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; Track-Error "Enable adapter: $_" }
    Track-Action "Enabled adapter: $n"
}

function Net-DisableAdapter {
    $n = Read-InputWithBossKey 'Adapter name'
    if (-not $n) { return }
    if (-not (Confirm-Action "Disable adapter '$n'?")) { return }
    try { Disable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop; Write-Host "  Disabled: $n" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; Track-Error "Disable adapter: $_" }
    Track-Action "Disabled adapter: $n"
}

function Net-RestartAdapter {
    $n = Read-InputWithBossKey 'Adapter name'
    if (-not $n) { return }
    try { Restart-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop; Write-Host "  Restarted: $n" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Restarted adapter: $n"
}

function Net-ShowIPConfig {
    ipconfig /all
    Track-Action 'ipconfig /all'
}

function Net-ReleaseRenew {
    if (-not (Confirm-Action 'Release and renew IP address?')) { return }
    Write-Host '  Releasing...' -ForegroundColor DarkGray
    ipconfig /release | Out-Null
    Start-Sleep -Seconds 1
    Write-Host '  Renewing...' -ForegroundColor DarkGray
    ipconfig /renew
    Write-Host '  Done.' -ForegroundColor Green
    Track-Action 'Released and renewed IP'
}

function Net-FlushDNS {
    ipconfig /flushdns | Out-Null
    Write-Host '  DNS cache flushed.' -ForegroundColor Green
    Track-Action 'Flushed DNS cache'
}

function Net-SetDNS {
    param([string]$Label, [string[]]$Servers)
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host '  No active adapters found.' -ForegroundColor Yellow; return }
    Write-Host '  Active adapters:' -ForegroundColor DarkGray
    $adapters | ForEach-Object { Write-Host ("    {0}" -f $_.Name) -ForegroundColor Gray }
    $iface = Read-InputWithBossKey ('Adapter name (Enter for ' + $adapters[0].Name + ')')
    if (-not $iface) { $iface = $adapters[0].Name }
    if (-not (Confirm-Action "Set DNS to $Label on '$iface'?")) { return }
    New-SafetyRestorePoint -Description "SetDNS-$Label"
    try {
        Set-DnsClientServerAddress -InterfaceAlias $iface -ServerAddresses $Servers -ErrorAction Stop
        Write-Host ("  DNS set to {0}: {1}" -f $Label, ($Servers -join ', ')) -ForegroundColor Green
    } catch {
        Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Track-Error "Set DNS failed: $_"
    }
    Track-Action "Set DNS to $Label on $iface"
}

function Net-SetCustomDNS {
    $iface = Read-InputWithBossKey 'Adapter name'
    $pri   = Read-InputWithBossKey 'Primary DNS'
    $sec   = Read-InputWithBossKey 'Secondary DNS (Enter to skip)'
    if (-not $iface -or -not $pri) { return }
    $servers = if ($sec) { @($pri, $sec) } else { @($pri) }
    try {
        Set-DnsClientServerAddress -InterfaceAlias $iface -ServerAddresses $servers -ErrorAction Stop
        Write-Host ("  DNS set on {0}: {1}" -f $iface, ($servers -join ', ')) -ForegroundColor Green
    } catch {
        Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Track-Action "Set custom DNS on $iface"
}

function Net-DNSBenchmark {
    Write-Host ''
    Write-Host '  Testing DNS response latency...' -ForegroundColor DarkGray
    Write-Host ''
    $tests = @(
        @{ Label = 'Google (8.8.8.8)';      Server = '8.8.8.8'   }
        @{ Label = 'Cloudflare (1.1.1.1)';  Server = '1.1.1.1'   }
        @{ Label = 'OpenDNS (208.67.222.222)'; Server = '208.67.222.222' }
        @{ Label = 'Quad9 (9.9.9.9)';       Server = '9.9.9.9'   }
    )
    $results = @()
    foreach ($t in $tests) {
        try {
            $sw  = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Resolve-DnsName -Name 'www.google.com' -Server $t.Server -Type A -ErrorAction Stop
            $sw.Stop()
            $ms = $sw.ElapsedMilliseconds
            $results += [PSCustomObject]@{ DNS = $t.Label; 'ms' = $ms }
            Write-Host ("  {0,-38}  {1} ms" -f $t.Label, $ms) -ForegroundColor Gray
        } catch {
            Write-Host ("  {0,-38}  FAILED" -f $t.Label) -ForegroundColor Red
            $results += [PSCustomObject]@{ DNS = $t.Label; 'ms' = 99999 }
        }
    }
    $best = $results | Sort-Object 'ms' | Select-Object -First 1
    Write-Host ''
    Write-Host ("  Fastest: {0}" -f $best.DNS) -ForegroundColor Green
    Track-Action 'DNS benchmark'
}

function Net-ShowConnections {
    Get-NetTCPConnection |
        Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State |
        Sort-Object State |
        Format-Table -AutoSize
    Track-Action 'Listed active TCP connections'
}

function Net-ShowListeningPorts {
    Get-NetTCPConnection -State Listen |
        Select-Object LocalAddress, LocalPort,
            @{ Name='Process'; Expression={
                try { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name } catch { '?' }
            }} |
        Sort-Object LocalPort |
        Format-Table -AutoSize
    Track-Action 'Listed listening ports'
}

function Net-ScanCommonPorts {
    $t = Read-InputWithBossKey 'Target host or IP'
    if (-not $t) { return }
    Write-Host ("  Scanning common ports on {0}..." -f $t) -ForegroundColor DarkGray
    $ports = @(21,22,23,25,53,80,135,139,443,445,1433,3306,3389,5900,8080)
    foreach ($p in $ports) {
        $r = Test-NetConnection -ComputerName $t -Port $p -WarningAction SilentlyContinue
        $state  = if ($r.TcpTestSucceeded) { 'OPEN  ' } else { 'closed' }
        $fcolor = if ($r.TcpTestSucceeded) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  {0,-6}  {1}" -f $p, $state) -ForegroundColor $fcolor
    }
    Track-Action "Port scan: $t"
}

function Net-CheckBadPorts {
    $data = Get-DataFile 'bad_ports.json'
    if (-not $data) { Write-Host '  bad_ports.json not found.' -ForegroundColor Yellow; return }
    Write-Host '  Checking listening ports against known bad-port list...' -ForegroundColor DarkGray
    Write-Host ''
    $listening = Get-NetTCPConnection -State Listen |
        Select-Object -ExpandProperty LocalPort -Unique
    $found = $false
    foreach ($port in ($data.PSObject.Properties)) {
        if ($listening -contains [int]$port.Name) {
            Write-Host ("  [OPEN]  Port {0,-6}  {1}" -f $port.Name, $port.Value) -ForegroundColor Red
            $found = $true
        }
    }
    if (-not $found) {
        Write-Host '  No flagged ports are currently listening.' -ForegroundColor Green
    }
    Track-Action 'Checked listening ports vs bad_ports.json'
}

function Net-ResetTCPIP {
    if (-not (Confirm-Action 'Reset TCP/IP stack? A reboot will be required.')) { return }
    New-SafetyRestorePoint -Description 'Reset-TCPIP'
    netsh int ip reset
    Track-Action 'Reset TCP/IP stack'
    Write-Host '  TCP/IP reset complete. Reboot required.' -ForegroundColor Yellow
}

function Net-ResetWinsock {
    if (-not (Confirm-Action 'Reset Winsock catalog? A reboot will be required.')) { return }
    New-SafetyRestorePoint -Description 'Reset-Winsock'
    netsh winsock reset
    Track-Action 'Reset Winsock'
    Write-Host '  Winsock reset complete. Reboot required.' -ForegroundColor Yellow
}

function Net-ShowARP    { arp -a; Track-Action 'Viewed ARP table' }
function Net-ShowRoutes { route print; Track-Action 'Viewed routing table' }

function Net-AddRoute {
    $dest    = Read-InputWithBossKey 'Destination (e.g. 192.168.2.0)'
    $mask    = Read-InputWithBossKey 'Mask (e.g. 255.255.255.0)'
    $gateway = Read-InputWithBossKey 'Gateway'
    if (-not $dest -or -not $mask -or -not $gateway) { return }
    route add $dest mask $mask $gateway
    Track-Action "Added route $dest via $gateway"
}

function Net-RemoveRoute {
    $dest = Read-InputWithBossKey 'Destination to remove'
    if (-not $dest) { return }
    route delete $dest
    Track-Action "Removed route $dest"
}

function Net-Ping {
    $t = Read-InputWithBossKey 'Target host or IP'
    if (-not $t) { return }
    Test-Connection -ComputerName $t -Count 4 |
        Select-Object Address, ResponseTime, StatusCode |
        Format-Table -AutoSize
    Track-Action "Ping: $t"
}

function Net-Traceroute {
    $t = Read-InputWithBossKey 'Target host or IP'
    if (-not $t) { return }
    tracert $t
    Track-Action "Traceroute: $t"
}

function Net-LANScan {
    Write-Host '  Scanning local /24 subnet via ARP...' -ForegroundColor DarkGray
    Write-Host ''
    try {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
                    Select-Object -First 1)
        if (-not $localIP) { Write-Host '  Could not determine local IP.' -ForegroundColor Yellow; return }
        $base = ($localIP.IPAddress -split '\.')[ 0..2] -join '.'
        Write-Host ("  Base: {0}.0/24  (pinging 1-254, this may take a moment...)" -f $base) -ForegroundColor DarkGray
        Write-Host ''
        1..254 | ForEach-Object {
            $ip = "$base.$_"
            $r  = Test-Connection -ComputerName $ip -Count 1 -TimeToLive 64 -Quiet -ErrorAction SilentlyContinue
            if ($r) {
                $hostname = try { [System.Net.Dns]::GetHostEntry($ip).HostName } catch { 'unknown' }
                Write-Host ("  {0,-16}  {1}" -f $ip, $hostname) -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host ("  Scan failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Track-Action 'LAN device scan'
}

function Net-DNSLookup {
    $d = Read-InputWithBossKey 'Domain or IP'
    if (-not $d) { return }
    nslookup $d
    Track-Action "DNS lookup: $d"
}

function Net-ShowWiFiProfiles { netsh wlan show profiles; Track-Action 'Listed WiFi profiles' }

function Net-ShowWiFiPasswords {
    if (-not (Confirm-Action 'Display saved WiFi passwords?')) { return }
    $profiles = netsh wlan show profiles | Select-String ':\s+(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($p in $profiles) {
        Write-Host ''
        Write-Host ("  Profile: {0}" -f $p) -ForegroundColor White
        try {
            $detail = netsh wlan show profile name="$p" key=clear
            $pw     = $detail | Select-String 'Key Content\s+:\s+(.+)$'
            if ($pw) {
                Write-Host ("  Password: {0}" -f $pw.Matches[0].Groups[1].Value.Trim()) -ForegroundColor Yellow
            } else {
                Write-Host '  Password: (not stored or open network)' -ForegroundColor DarkGray
            }
        } catch {}
    }
    Track-Action 'Viewed WiFi passwords'
}

function Net-WiFiSignal {
    $info = netsh wlan show interfaces
    $info
    Track-Action 'Checked WiFi signal'
}

function Net-ExportNetworkInfo {
    $out = Join-Path $env:USERPROFILE "Desktop\network_info_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $data = @()
    $data += "=== ipconfig /all ===" ; $data += (ipconfig /all)
    $data += '' ; $data += "=== Active TCP Connections ==="
    $data += (Get-NetTCPConnection | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State |
              Format-Table -AutoSize | Out-String)
    $data += "=== Routing Table ===" ; $data += (route print)
    $data += '' ; $data += "=== ARP ===" ; $data += (arp -a)
    $data | Out-File -FilePath $out -Encoding UTF8 -Force
    Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Exported network info to $out"
}

# ===========================================================================
# SYSTEM MAINTENANCE FUNCTIONS
# ===========================================================================

function Sys-ShowInfo {
    Get-ComputerInfo | Select-Object CsName, WindowsProductName, WindowsVersion,
        OsArchitecture, CsTotalPhysicalMemory, OsHardwareAbstractionLayer |
        Format-List
    Track-Action 'Viewed system info'
}

function Sys-ShowDiskUsage {
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name,
            @{ N='Used GB';  E={ [math]::Round($_.Used  / 1GB, 2) } },
            @{ N='Free GB';  E={ [math]::Round($_.Free  / 1GB, 2) } },
            @{ N='Total GB'; E={ [math]::Round(($_.Used + $_.Free) / 1GB, 2) } },
            Root |
        Format-Table -AutoSize
    Track-Action 'Viewed disk usage'
}

function Sys-ShowTempSizes {
    $dirs = @($env:TEMP, "$env:windir\Temp")
    foreach ($d in $dirs) {
        if (Test-Path $d) {
            $size = (Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            Write-Host ("  {0,-30}  {1} MB" -f $d, [math]::Round($size / 1MB, 1)) -ForegroundColor Gray
        }
    }
    Track-Action 'Checked temp sizes'
}

function Sys-ShowUptime {
    try {
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $span = (Get-Date) - $os.LastBootUpTime
        Write-Host ("  Last boot:  {0}" -f $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
        Write-Host ("  Uptime:     {0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes) -ForegroundColor Gray
        Write-Host ("  RAM total:  {0} GB" -f [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) -ForegroundColor Gray
        Write-Host ("  RAM free:   {0} GB" -f [math]::Round($os.FreePhysicalMemory  / 1MB, 1)) -ForegroundColor Gray
    } catch {
        Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Track-Action 'Viewed uptime / hardware'
}

function Sys-CleanUserTemp {
    if (-not (Confirm-Action 'Clean user temp folder?')) { return }
    $t = $env:TEMP
    Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  User temp cleaned.' -ForegroundColor Green
    Track-Action 'Cleaned user temp'
}

function Sys-CleanSystemTemp {
    if (-not (Confirm-Action 'Clean system temp folder?')) { return }
    $t = "$env:windir\Temp"
    Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  System temp cleaned.' -ForegroundColor Green
    Track-Action 'Cleaned system temp'
}

function Sys-EmptyRecycleBin {
    if (-not (Confirm-Action 'Empty the Recycle Bin?')) { return }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Host '  Recycle Bin emptied.' -ForegroundColor Green
    Track-Action 'Emptied Recycle Bin'
}

function Sys-ClearWUCache {
    if (-not (Confirm-Action 'Clear Windows Update download cache? WU service will be temporarily stopped.')) { return }
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Host '  Windows Update cache cleared.' -ForegroundColor Green
    Track-Action 'Cleared Windows Update cache'
}

function Sys-ClearThumbnailCache {
    if (-not (Confirm-Action 'Clear thumbnail cache?')) { return }
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    Get-ChildItem $path -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host '  Thumbnail cache cleared.' -ForegroundColor Green
    Track-Action 'Cleared thumbnail cache'
}

function Sys-ClearAllCaches {
    if (-not (Confirm-Action 'Clear all caches (temp, WU, thumbnail, DNS)?')) { return }
    Write-Host '  Clearing user temp...'       -ForegroundColor DarkGray
    Get-ChildItem $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  Clearing system temp...'     -ForegroundColor DarkGray
    Get-ChildItem "$env:windir\Temp" -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  Flushing DNS...'             -ForegroundColor DarkGray
    ipconfig /flushdns | Out-Null
    Write-Host '  Clearing thumbnail cache...' -ForegroundColor DarkGray
    $tcPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    Get-ChildItem $tcPath -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host '  Done.' -ForegroundColor Green
    Track-Action 'Cleared all caches'
}

function Sys-CheckDisk {
    $d = Read-InputWithBossKey 'Drive letter (default C:)'
    if (-not $d) { $d = 'C:' }
    chkdsk $d
    Track-Action "chkdsk $d"
}

function Sys-RunSFC {
    if (-not (Confirm-Action 'Run SFC /scannow? This may take several minutes.')) { return }
    sfc /scannow
    Track-Action 'Ran sfc /scannow'
}

function Sys-RunDISM {
    if (-not (Confirm-Action 'Run DISM /Online /Cleanup-Image /RestoreHealth? This may take 15-30 minutes.')) { return }
    DISM /Online /Cleanup-Image /RestoreHealth
    Track-Action 'Ran DISM RestoreHealth'
}

function Sys-ScheduleMemDiag {
    if (-not (Confirm-Action 'Schedule Windows Memory Diagnostic on next reboot?')) { return }
    mdsched.exe
    Track-Action 'Scheduled memory diagnostic'
}

function Sys-ListServices {
    Get-Service | Where-Object { $_.Status -eq 'Running' } |
        Select-Object Name, DisplayName, Status |
        Sort-Object Name |
        Format-Table -AutoSize
    Track-Action 'Listed running services'
}

function Sys-StartService {
    $s = Read-InputWithBossKey 'Service name'
    if (-not $s) { return }
    try { Start-Service -Name $s -ErrorAction Stop; Write-Host "  Started: $s" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Started service: $s"
}

function Sys-StopService {
    $s = Read-InputWithBossKey 'Service name'
    if (-not $s) { return }
    if (-not (Confirm-Action "Stop service '$s'?")) { return }
    try { Stop-Service -Name $s -Force -ErrorAction Stop; Write-Host "  Stopped: $s" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Stopped service: $s"
}

function Sys-RestartService {
    $s = Read-InputWithBossKey 'Service name'
    if (-not $s) { return }
    try { Restart-Service -Name $s -Force -ErrorAction Stop; Write-Host "  Restarted: $s" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Restarted service: $s"
}

function Sys-ListStartupApps {
    Write-Host '  Registry startup (HKCU):' -ForegroundColor DarkGray
    Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue |
        Select-Object -Property * -ExcludeProperty PS* | Format-List
    Write-Host '  Registry startup (HKLM):' -ForegroundColor DarkGray
    Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue |
        Select-Object -Property * -ExcludeProperty PS* | Format-List
    Track-Action 'Listed startup apps'
}

function Sys-ListScheduledTasks {
    schtasks /Query /FO LIST /V 2>&1 | Select-Object -First 100
    Track-Action 'Listed scheduled tasks'
}

function Sys-WUStatus {
    Write-Host '  Windows Update service:' -ForegroundColor DarkGray
    Get-Service -Name wuauserv | Select-Object Name, Status, StartType | Format-List
    $a = Read-InputWithBossKey 'Action: start / stop / status (Enter = status)'
    switch ($a.ToLower()) {
        'start' { Start-Service wuauserv -ErrorAction SilentlyContinue; Write-Host '  WU service started.' -ForegroundColor Green }
        'stop'  { Stop-Service  wuauserv -Force -ErrorAction SilentlyContinue; Write-Host '  WU service stopped.' -ForegroundColor Yellow }
    }
    Track-Action "WU action: $a"
}

function Sys-PowerPlanManager {
    Write-Host '  Available power plans:' -ForegroundColor DarkGray
    powercfg /list
    Write-Host ''
    $plans = @{
        'B' = @{ Name = 'Balanced';          GUID = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        'P' = @{ Name = 'High Performance';  GUID = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'S' = @{ Name = 'Power Saver';       GUID = 'a1841308-3541-4fab-bc81-f71556f20b4a' }
    }
    Write-Host '  Quick select: B=Balanced  P=High Performance  S=Power Saver' -ForegroundColor DarkGray
    $sel = (Read-InputWithBossKey 'Choice or paste GUID').ToUpper()
    if ($plans.ContainsKey($sel)) {
        powercfg /setactive $plans[$sel].GUID
        Write-Host ("  Power plan set to: {0}" -f $plans[$sel].Name) -ForegroundColor Green
        Track-Action ("Set power plan: {0}" -f $plans[$sel].Name)
    } elseif ($sel.Length -eq 36) {
        powercfg /setactive $sel
        Write-Host "  Power plan set." -ForegroundColor Green
        Track-Action "Set power plan: $sel"
    } else {
        Write-Host '  No change.' -ForegroundColor DarkGray
    }
}

function Sys-Defrag {
    $d = Read-InputWithBossKey 'Drive letter (default C:)'
    if (-not $d) { $d = 'C:' }
    Optimize-Volume -DriveLetter $d.TrimEnd(':') -Defrag -Verbose
    Track-Action "Defrag: $d"
}

function Sys-BatteryReport {
    $out = Join-Path $env:USERPROFILE "Desktop\battery_report_$(Get-Date -Format 'yyyyMMdd').html"
    powercfg /batteryreport /output $out 2>&1
    Write-Host ("  Report saved: {0}" -f $out) -ForegroundColor Green
    Track-Action 'Generated battery report'
}

function Sys-EnergyReport {
    $out = Join-Path $env:USERPROFILE "Desktop\energy_report_$(Get-Date -Format 'yyyyMMdd').html"
    powercfg /energy /output $out 2>&1
    Write-Host ("  Report saved: {0}" -f $out) -ForegroundColor Green
    Track-Action 'Generated energy report'
}

function Sys-CreateRestorePoint {
    $desc = Read-InputWithBossKey 'Label (Enter for default)'
    if (-not $desc) { $desc = '99SAK Manual Checkpoint' }
    New-SafetyRestorePoint -Description $desc
    Track-Action "Created restore point: $desc"
}

function Sys-ExportInfo {
    $out = Join-Path $env:USERPROFILE "Desktop\sysinfo_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    Get-ComputerInfo | Out-File $out -Encoding UTF8 -Force
    Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Exported system info to $out"
}

function Sys-Reboot {
    if (-not (Confirm-Action 'Reboot the system NOW?')) { return }
    Restart-Computer -Force
}

function Sys-Shutdown {
    if (-not (Confirm-Action 'Shutdown the system NOW?')) { return }
    Stop-Computer -Force
}

# ===========================================================================
# SECURITY & PRIVACY FUNCTIONS
# ===========================================================================

function Sec-EnableFirewall {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
    Write-Host '  Firewall enabled on all profiles.' -ForegroundColor Green
    Track-Action 'Enabled firewall'
}

function Sec-DisableFirewall {
    if (-not (Confirm-Action 'Disable Windows Firewall on all profiles?')) { return }
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Write-Host '  Firewall disabled.' -ForegroundColor Yellow
    Track-Action 'Disabled firewall'
}

function Sec-ShowFirewallRules {
    Get-NetFirewallRule |
        Where-Object { $_.Enabled -eq 'True' } |
        Select-Object Name, DisplayName, Direction, Action, Profile |
        Format-Table -AutoSize
    Track-Action 'Listed firewall rules'
}

function Sec-ResetFirewall {
    if (-not (Confirm-Action 'Reset firewall to default policy?')) { return }
    netsh advfirewall reset
    Write-Host '  Firewall reset to defaults.' -ForegroundColor Green
    Track-Action 'Reset firewall to defaults'
}

function Sec-BlockHost {
    $h = Read-InputWithBossKey 'Host to block (e.g. ads.example.com)'
    if (-not $h) { return }
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $entry = "0.0.0.0 $h"
    $current = Get-Content $hostsPath
    if ($current -contains $entry) {
        Write-Host '  Host already blocked.' -ForegroundColor Yellow
    } else {
        Add-Content -Path $hostsPath -Value $entry
        Write-Host ("  Blocked: {0}" -f $h) -ForegroundColor Green
    }
    Track-Action "Blocked host: $h"
}

function Sec-UnblockHost {
    $h = Read-InputWithBossKey 'Host to unblock'
    if (-not $h) { return }
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    (Get-Content $hostsPath) |
        Where-Object { $_ -notmatch [regex]::Escape($h) } |
        Set-Content $hostsPath
    Write-Host ("  Unblocked: {0}" -f $h) -ForegroundColor Green
    Track-Action "Unblocked host: $h"
}

function Sec-ViewHosts {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    Get-Content $hostsPath | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
    Track-Action 'Viewed hosts file'
}

function Sec-DefenderStatus {
    try { Get-MpComputerStatus | Format-List }
    catch { Write-Host '  Defender not available on this system.' -ForegroundColor Yellow }
    Track-Action 'Viewed Defender status'
}

function Sec-DefenderQuickScan {
    if (-not (Confirm-Action 'Run Defender quick scan?')) { return }
    try { Start-MpScan -ScanType QuickScan -ErrorAction Stop; Write-Host '  Quick scan started.' -ForegroundColor Green }
    catch { Write-Host '  Defender scan failed or not available.' -ForegroundColor Yellow }
    Track-Action 'Ran Defender quick scan'
}

function Sec-DefenderFullScan {
    if (-not (Confirm-Action 'Run Defender full scan? This will take a long time.')) { return }
    try { Start-MpScan -ScanType FullScan -ErrorAction Stop; Write-Host '  Full scan started.' -ForegroundColor Green }
    catch { Write-Host '  Defender scan failed or not available.' -ForegroundColor Yellow }
    Track-Action 'Ran Defender full scan'
}

function Sec-UpdateDefender {
    try { Update-MpSignature -ErrorAction Stop; Write-Host '  Signatures updated.' -ForegroundColor Green }
    catch { Write-Host '  Update failed or Defender not available.' -ForegroundColor Yellow }
    Track-Action 'Updated Defender signatures'
}

function Sec-ShowUsers {
    Get-LocalUser | Select-Object Name, Enabled, PasswordLastSet, LastLogon |
        Format-Table -AutoSize
    Track-Action 'Listed local users'
}

function Sec-LockWorkstation {
    rundll32.exe user32.dll,LockWorkStation
    Track-Action 'Locked workstation'
}

function Sec-UACInfo {
    $val = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
    $levels = @{
        0 = 'Never notify'
        1 = 'Notify only for app changes (no dimming)'
        2 = 'Notify for app changes (dimming on)'
        5 = 'Default - notify only when apps try to make changes'
    }
    $levelDesc = if ($levels.ContainsKey($val)) { $levels[$val] } else { 'Unknown' }
    Write-Host ("  Current UAC level: {0} - {1}" -f $val, $levelDesc) -ForegroundColor Gray
    Write-Host '  To change, open User Account Control settings:' -ForegroundColor DarkGray
    $open = Read-InputWithBossKey 'Open UAC settings? (Y/N)'
    if ($open.ToUpper() -eq 'Y') { Start-Process useraccountcontrolsettings.exe }
    Track-Action 'Viewed UAC level'
}

function Sec-PasswordPolicy {
    net accounts
    Track-Action 'Viewed password policy'
}

function Sec-DisableDiagTrack {
    if (-not (Confirm-Action 'Disable Connected User Experiences (DiagTrack) service?')) { return }
    Stop-Service -Name DiagTrack -ErrorAction SilentlyContinue
    Set-Service  -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host '  DiagTrack disabled.' -ForegroundColor Green
    Track-Action 'Disabled DiagTrack'
}

function Sec-ClearRecentFiles {
    $path = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
    Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host '  Recent files cleared.' -ForegroundColor Green
    Track-Action 'Cleared recent files'
}

function Sec-ClearClipboard {
    try { [System.Windows.Forms.Clipboard]::Clear() } catch { cmd /c 'echo off | clip' }
    Write-Host '  Clipboard cleared.' -ForegroundColor Green
    Track-Action 'Cleared clipboard'
}

function Sec-ListeningPorts {
    Get-NetTCPConnection -State Listen |
        Select-Object LocalAddress, LocalPort,
            @{ Name='Process'; Expression={
                try { (Get-Process -Id $_.OwningProcess -EA SilentlyContinue).Name } catch { '?' }
            }} |
        Sort-Object LocalPort |
        Format-Table -AutoSize
    Track-Action 'Listed listening ports (security view)'
}

function Sec-TopProcesses {
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 25 |
        Select-Object Name, Id, CPU, WorkingSet64 |
        Format-Table -AutoSize
    Track-Action 'Listed top processes'
}

function Sec-CheckUnsigned {
    Write-Host '  Checking running processes for unsigned executables...' -ForegroundColor DarkGray
    Write-Host ''
    Get-Process | Where-Object { $_.Path } | ForEach-Object {
        $sig = Get-AuthenticodeSignature -FilePath $_.Path -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -ne 'Valid') {
            Write-Host ("  {0,-30}  {1}  {2}" -f $_.Name, $sig.Status, $_.Path) -ForegroundColor Yellow
        }
    }
    Write-Host '  Scan complete.' -ForegroundColor Green
    Track-Action 'Checked unsigned processes'
}

function Sec-SecurityAudit {
    Write-Host ''
    Write-Host '  Running security audit...' -ForegroundColor DarkGray
    Write-Host ''
    $score  = 100
    $issues = @()

    # Firewall
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($fw | Where-Object { $_.Enabled -eq $false }) {
        $issues += 'Firewall is disabled on one or more profiles'
        $score  -= 20
        Write-StatusLine 'Firewall: DISABLED on at least one profile' 'ERROR'
    } else {
        Write-StatusLine 'Firewall: enabled on all profiles' 'OK'
    }

    # Defender
    try {
        $def = Get-MpComputerStatus -ErrorAction Stop
        if ($def.RealTimeProtectionEnabled) {
            Write-StatusLine 'Defender real-time protection: enabled' 'OK'
        } else {
            $issues += 'Defender real-time protection is disabled'
            $score  -= 20
            Write-StatusLine 'Defender real-time protection: DISABLED' 'ERROR'
        }
        $sigAge = ((Get-Date) - $def.AntivirusSignatureLastUpdated).Days
        if ($sigAge -gt 3) {
            $issues += "Defender signatures are $sigAge days old"
            $score  -= 10
            Write-StatusLine ("Defender signatures: {0} days old" -f $sigAge) 'WARN'
        } else {
            Write-StatusLine ("Defender signatures: {0} days old" -f $sigAge) 'OK'
        }
    } catch {
        Write-StatusLine 'Defender: not available' 'WARN'
        $score -= 10
    }

    # Guest account
    $guest = Get-LocalUser -Name Guest -ErrorAction SilentlyContinue
    if ($guest -and $guest.Enabled) {
        $issues += 'Guest account is enabled'
        $score  -= 10
        Write-StatusLine 'Guest account: ENABLED' 'WARN'
    } else {
        Write-StatusLine 'Guest account: disabled' 'OK'
    }

    # RDP
    $rdp = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($rdp -eq 0) {
        $issues += 'RDP is enabled'
        $score  -= 10
        Write-StatusLine 'RDP: ENABLED (ensure NLA is enforced)' 'WARN'
    } else {
        Write-StatusLine 'RDP: disabled' 'OK'
    }

    # Auto-login
    $autoLogon = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
                  -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($autoLogon -eq '1') {
        $issues += 'Auto-login is enabled'
        $score  -= 15
        Write-StatusLine 'Auto-login: ENABLED' 'ERROR'
    } else {
        Write-StatusLine 'Auto-login: disabled' 'OK'
    }

    Write-Host ''
    Write-Divider -Char '-'
    Write-Host ("  Security score: {0}/100" -f [Math]::Max($score, 0)) -ForegroundColor $(if ($score -ge 80) { 'Green' } elseif ($score -ge 50) { 'Yellow' } else { 'Red' })

    if ($issues.Count -gt 0) {
        Write-Host '  Issues found:' -ForegroundColor Yellow
        foreach ($i in $issues) { Write-Host ("    - {0}" -f $i) -ForegroundColor Gray }
    }

    $save = Read-InputWithBossKey 'Save audit report? (Y/N)'
    if ($save.ToUpper() -eq 'Y') {
        $out = Join-Path $env:USERPROFILE "Desktop\99SAK_security_audit_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $report = @("Security Audit - $(Get-Date)", "Score: $score/100", '', 'Issues:')
        $issues | ForEach-Object { $report += "  - $_" }
        $report | Out-File $out -Encoding UTF8
        Write-Host ("  Report saved: {0}" -f $out) -ForegroundColor Green
    }
    Track-Action "Security audit (score: $score)"
}

function Sec-RDPStatus {
    $val = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name fDenyTSConnections -EA SilentlyContinue).fDenyTSConnections
    $state = if ($val -eq 0) { 'ENABLED' } else { 'disabled' }
    Write-Host ("  RDP: {0}" -f $state) -ForegroundColor $(if ($val -eq 0) { 'Yellow' } else { 'Green' })
    Track-Action 'Viewed RDP status'
}

function Sec-ToggleRDP {
    $action = Read-InputWithBossKey 'Enable or disable RDP? (E/D)'
    $enable = $action.ToUpper() -eq 'E'
    if (-not (Confirm-Action ("$(if ($enable) {'Enable'} else {'Disable'}) Remote Desktop?"))) { return }
    New-SafetyRestorePoint -Description "Toggle-RDP-$(if ($enable) {'On'} else {'Off'})"
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -Value ([int](-not $enable))
    if ($enable) {
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    } else {
        Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    }
    Write-Host ("  RDP {0}." -f $(if ($enable) { 'enabled' } else { 'disabled' })) -ForegroundColor Green
    Track-Action "Toggled RDP: $(if ($enable) {'On'} else {'Off'})"
}

function Sec-SetRDPPort {
    $p = Read-InputWithBossKey 'New RDP port (default 3389)'
    if (-not $p) { return }
    New-SafetyRestorePoint -Description 'RDP-Port-Change'
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name PortNumber -Value ([int]$p) -ErrorAction SilentlyContinue
    Write-Host ("  RDP port set to: {0}" -f $p) -ForegroundColor Green
    Write-Host '  Update your firewall rules accordingly.' -ForegroundColor Yellow
    Track-Action "Set RDP port: $p"
}

function Sec-BitLockerStatus {
    try { Get-BitLockerVolume | Select-Object MountPoint, EncryptionMethod, ProtectionStatus | Format-Table -AutoSize }
    catch { Write-Host '  BitLocker is not available on this system.' -ForegroundColor Yellow }
    Track-Action 'Checked BitLocker status'
}

function Sec-ActivationStatus { slmgr /xpr; Track-Action 'Checked activation status' }

# ===========================================================================
# UTILITIES FUNCTIONS
# ===========================================================================

function Util-Screenshot {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp    = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $gfx    = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $out = Join-Path $env:USERPROFILE "Desktop\screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose(); $bmp.Dispose()
    Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Screenshot: $out"
}

function Util-ListPrograms {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $paths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    } |
    Where-Object { $_.DisplayName } |
    Sort-Object DisplayName |
    Format-Table -AutoSize
    Track-Action 'Listed installed programs'
}

function Util-CreateAdmin {
    $name = Read-InputWithBossKey 'New username'
    if (-not $name) { return }
    $pw = Read-Host -AsSecureString 'Password'
    try {
        New-LocalUser -Name $name -Password $pw -PasswordNeverExpires:$true -ErrorAction Stop
        Add-LocalGroupMember -Group 'Administrators' -Member $name -ErrorAction Stop
        Write-Host ("  Created admin user: {0}" -f $name) -ForegroundColor Green
    } catch {
        Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Track-Action "Created local admin: $name"
}

function Util-RemoveUser {
    $name = Read-InputWithBossKey 'Username to remove'
    if (-not $name) { return }
    if (-not (Confirm-Action "Remove local user '$name'?")) { return }
    try { Remove-LocalUser -Name $name -ErrorAction Stop; Write-Host "  Removed: $name" -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Removed user: $name"
}

function Util-ChangePassword {
    $name = Read-InputWithBossKey 'Username'
    if (-not $name) { return }
    $pw = Read-Host -AsSecureString 'New password'
    try { Set-LocalUser -Name $name -Password $pw -ErrorAction Stop; Write-Host '  Password changed.' -ForegroundColor Green }
    catch { Write-Host ("  Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    Track-Action "Changed password for: $name"
}

function Util-TopProcesses {
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 25 |
        Select-Object Name, Id,
            @{ N='CPU (s)'; E={ [math]::Round($_.CPU, 1) } },
            @{ N='RAM (MB)'; E={ [math]::Round($_.WorkingSet64 / 1MB, 1) } } |
        Format-Table -AutoSize
    Track-Action 'Listed top processes'
}

function Util-KillProcess {
    $name = Read-InputWithBossKey 'Process name'
    if (-not $name) { return }
    if (-not (Confirm-Action "Kill all processes named '$name'?")) { return }
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  Done.' -ForegroundColor Green
    Track-Action "Killed process: $name"
}

function Util-RestartExplorer {
    if (-not (Confirm-Action 'Restart Windows Explorer? Desktop will briefly disappear.')) { return }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer
    Write-Host '  Explorer restarted.' -ForegroundColor Green
    Track-Action 'Restarted Explorer'
}

function Util-SetTimezone {
    tzutil /l
    $tz = Read-InputWithBossKey 'Timezone ID from above list'
    if (-not $tz) { return }
    tzutil /s $tz
    Write-Host ("  Timezone set: {0}" -f $tz) -ForegroundColor Green
    Track-Action "Set timezone: $tz"
}

function Util-EventLogs {
    Write-Host '  Most recent 30 System errors/warnings:' -ForegroundColor DarkGray
    Write-Host ''
    try {
        Get-WinEvent -LogName System -MaxEvents 30 -ErrorAction Stop |
            Where-Object { $_.Level -le 3 } |
            Select-Object TimeCreated, LevelDisplayName, Id, Message |
            ForEach-Object {
                Write-Host ("  {0}  [{1}]  {2}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $_.LevelDisplayName.PadRight(7), $_.Message.Substring(0, [Math]::Min(60, $_.Message.Length))) `
                    -ForegroundColor $(if ($_.Level -eq 2) { 'Red' } else { 'Yellow' })
            }
    } catch {
        Get-EventLog -LogName System -Newest 30 -EntryType Error,Warning |
            Format-Table -AutoSize
    }
    $save = Read-InputWithBossKey 'Save to .txt? (Y/N)'
    if ($save.ToUpper() -eq 'Y') {
        $out = Join-Path $env:USERPROFILE "Desktop\event_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        Get-WinEvent -LogName System -MaxEvents 200 |
            Where-Object { $_.Level -le 3 } |
            Select-Object TimeCreated, LevelDisplayName, Id, Message |
            Out-File $out -Encoding UTF8
        Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    }
    Track-Action 'Viewed event logs'
}

function Util-ExportSysInfo {
    $out = Join-Path $env:USERPROFILE "Desktop\sysinfo_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    Get-ComputerInfo | Out-File $out -Encoding UTF8 -Force
    Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Exported system info: $out"
}

function Util-DisablePnP {
    Get-PnpDevice | Select-Object -First 30 | Format-Table -AutoSize
    $dev = Read-InputWithBossKey 'Device InstanceId'
    if (-not $dev) { return }
    Disable-PnpDevice -InstanceId $dev -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host '  Device disabled.' -ForegroundColor Green
    Track-Action "Disabled PnP device: $dev"
}

function Util-EjectCD {
    try { (New-Object -ComObject WMPlayer.OCX).cdromCollection.Item(0).Eject() }
    catch { Write-Host '  No optical drive found or WMPlayer unavailable.' -ForegroundColor Yellow }
    Track-Action 'Ejected CD/DVD'
}

function Util-MountISO {
    $p = Read-InputWithBossKey 'Path to ISO'
    if (-not $p) { return }
    Mount-DiskImage -ImagePath $p -ErrorAction SilentlyContinue
    Write-Host ("  Mounted: {0}" -f $p) -ForegroundColor Green
    Track-Action "Mounted ISO: $p"
}

function Util-DismountISO {
    $p = Read-InputWithBossKey 'Path to ISO'
    if (-not $p) { return }
    Dismount-DiskImage -ImagePath $p -ErrorAction SilentlyContinue
    Write-Host ("  Dismounted: {0}" -f $p) -ForegroundColor Green
    Track-Action "Dismounted ISO: $p"
}

function Util-OpenRegistry {
    Start-Process regedit
    Track-Action 'Opened Registry Editor'
}

function Util-BackupRegistry {
    $out = Join-Path $env:USERPROFILE "Desktop\registry_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
    reg export HKLM $out /y 2>&1
    Write-Host ("  Registry backup saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Backed up registry: $out"
}

function Util-RestoreRegistry {
    $file = Read-InputWithBossKey 'Path to .reg file'
    if (-not $file) { return }
    if (-not (Confirm-Action "Import registry from '$file'?")) { return }
    reg import $file
    Track-Action "Imported registry: $file"
}

# ===========================================================================
# MISC FUNCTIONS
# ===========================================================================

function Misc-ShowSMBShares {
    Get-SmbShare | Select-Object Name, Path, Description | Format-Table -AutoSize
    Track-Action 'Listed SMB shares'
}

function Misc-NewSMBShare {
    $name = Read-InputWithBossKey 'Share name'
    $path = Read-InputWithBossKey 'Path to share'
    if (-not $name -or -not $path) { return }
    New-SmbShare -Name $name -Path $path -FullAccess Everyone -ErrorAction SilentlyContinue
    Write-Host ("  Share created: {0} -> {1}" -f $name, $path) -ForegroundColor Green
    Track-Action "Created SMB share: $name"
}

function Misc-RemoveSMBShare {
    $name = Read-InputWithBossKey 'Share name to remove'
    if (-not $name) { return }
    if (-not (Confirm-Action "Remove share '$name'?")) { return }
    Remove-SmbShare -Name $name -Force -ErrorAction SilentlyContinue
    Write-Host '  Share removed.' -ForegroundColor Green
    Track-Action "Removed SMB share: $name"
}

function Misc-MapDrive {
    $letter = Read-InputWithBossKey 'Drive letter (e.g. Z:)'
    $path   = Read-InputWithBossKey 'Network path (\\server\share)'
    if (-not $letter -or -not $path) { return }
    New-PSDrive -Name $letter.TrimEnd(':') -PSProvider FileSystem -Root $path -Persist -ErrorAction SilentlyContinue
    Write-Host ("  Mapped {0} to {1}" -f $letter, $path) -ForegroundColor Green
    Track-Action "Mapped drive $letter to $path"
}

function Misc-UnmapDrive {
    $letter = Read-InputWithBossKey 'Drive letter to remove (e.g. Z:)'
    if (-not $letter) { return }
    Remove-PSDrive -Name $letter.TrimEnd(':') -Force -ErrorAction SilentlyContinue
    net use $letter /delete /y 2>&1 | Out-Null
    Write-Host ("  Removed: {0}" -f $letter) -ForegroundColor Green
    Track-Action "Unmapped drive: $letter"
}

function Misc-SyncTime {
    w32tm /resync
    Write-Host '  Time synchronized.' -ForegroundColor Green
    Track-Action 'Synced system time'
}

function Misc-ExportARP {
    $out = Join-Path $env:USERPROFILE "Desktop\arp_cache_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    arp -a | Out-File $out -Encoding UTF8
    Write-Host ("  ARP cache saved: {0}" -f $out) -ForegroundColor Green
    Track-Action "Exported ARP cache: $out"
}

function Misc-ToggleHibernate {
    $a = Read-InputWithBossKey 'on / off / status'
    switch ($a.ToLower()) {
        'on'     { powercfg -h on;  Write-Host '  Hibernate enabled.'  -ForegroundColor Green  }
        'off'    { powercfg -h off; Write-Host '  Hibernate disabled.' -ForegroundColor Yellow }
        default  { powercfg /availablesleepstates }
    }
    Track-Action "Toggle hibernate: $a"
}

function Misc-BackupAll {
    $zip = Join-Path $env:USERPROFILE "Desktop\99SAK_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
    Compress-Archive -Path "$script:RootDir\*" -DestinationPath $zip -Force
    Write-Host ("  Backup created: {0}" -f $zip) -ForegroundColor Green
    Track-Action "Created full backup: $zip"
}

# ===========================================================================
# DEBLOAT FUNCTIONS
# ===========================================================================

function Debloat-ListBloatware {
    $data = Get-DataFile 'debloat_list.json'
    if (-not $data) { Write-Host '  debloat_list.json not found.' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host ('  {0,-40}  {1,-10}  {2}' -f 'App', 'Risk', 'Status') -ForegroundColor White
    Write-Divider -Char '-'
    foreach ($app in $data.apps) {
        $installed = $null -ne (Get-AppxPackage -Name $app.packageName -ErrorAction SilentlyContinue)
        $status    = if ($installed) { 'Installed' } else { 'Not found' }
        $color     = if ($installed) { 'Yellow'    } else { 'DarkGray'  }
        Write-Host ('  {0,-40}  {1,-10}  {2}' -f $app.name, $app.risk, $status) -ForegroundColor $color
    }
    Track-Action 'Listed bloatware apps'
}

function Debloat-RemoveByCategory {
    param([string]$Category)
    $data = Get-DataFile 'debloat_list.json'
    if (-not $data) { Write-Host '  debloat_list.json not found.' -ForegroundColor Yellow; return }
    $targets = $data.apps | Where-Object { $_.category -eq $Category }
    if (-not $targets) { Write-Host "  No apps in category: $Category" -ForegroundColor Yellow; return }
    if (-not (Confirm-Action ("Remove {0} app(s) in category '{1}'? A restore point will be created." -f $targets.Count, $Category))) { return }
    New-SafetyRestorePoint -Description "Debloat-$Category"
    foreach ($app in $targets) {
        $pkg = Get-AppxPackage -Name $app.packageName -ErrorAction SilentlyContinue
        if ($pkg) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-StatusLine ("Removed: {0}" -f $app.name) 'OK'
            } catch {
                Write-StatusLine ("Failed: {0} - {1}" -f $app.name, $_.Exception.Message) 'WARN'
            }
        } else {
            Write-StatusLine ("Not installed: {0}" -f $app.name) 'INFO'
        }
    }
    Track-Action "Debloat category: $Category"
}

function Debloat-RemoveOneDrive {
    if (-not (Confirm-Action 'Remove OneDrive? This will uninstall OneDrive from this user. Files in OneDrive folder will NOT be deleted.')) { return }
    New-SafetyRestorePoint -Description 'Remove-OneDrive'
    try {
        # Stop OneDrive processes
        Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2

        # Uninstall
        $odu = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path $odu)) { $odu = "$env:SystemRoot\System32\OneDriveSetup.exe" }
        if (Test-Path $odu) {
            Start-Process $odu -ArgumentList '/uninstall' -Wait
            Write-StatusLine 'OneDrive uninstalled' 'OK'
        } else {
            Write-StatusLine 'OneDrive setup not found - may already be removed' 'WARN'
        }

        # Remove AppX package
        $pkg = Get-AppxPackage -Name 'Microsoft.OneDriveSync' -ErrorAction SilentlyContinue
        if ($pkg) { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue }

        # Remove from Explorer sidebar (registry)
        $paths = @(
            'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
            'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
        )
        foreach ($rp in $paths) {
            if (Test-Path $rp) {
                Set-ItemProperty $rp -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -ErrorAction SilentlyContinue
            }
        }

        Write-Host '  OneDrive removed.' -ForegroundColor Green
    } catch {
        Write-Host ("  Partial failure: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Track-Action 'Removed OneDrive'
}

function Debloat-TelemetryServices {
    $data = Get-DataFile 'debloat_list.json'
    if (-not $data) { return }
    Write-Host ''
    Write-Host ('  {0,-20}  {1,-40}  {2}' -f 'Service', 'Display Name', 'Status') -ForegroundColor White
    Write-Divider -Char '-'
    foreach ($svc in $data.services) {
        $s = Get-Service -Name $svc.name -ErrorAction SilentlyContinue
        $st = if ($s) { $s.Status } else { 'Not found' }
        Write-Host ('  {0,-20}  {1,-40}  {2}' -f $svc.name, $svc.displayName, $st) -ForegroundColor Gray
    }
    Write-Host ''
    $svcName = Read-InputWithBossKey 'Service name to disable (Enter to skip)'
    if ($svcName) {
        if (-not (Confirm-Action "Disable service '$svcName'?")) { return }
        try {
            Stop-Service -Name $svcName -Force -ErrorAction Stop
            Set-Service  -Name $svcName -StartupType Disabled -ErrorAction Stop
            Write-StatusLine "Disabled: $svcName" 'OK'
        } catch {
            Write-StatusLine "Failed: $svcName - $($_.Exception.Message)" 'WARN'
        }
        Track-Action "Disabled service: $svcName"
    }
}

function Debloat-StartupCleaner {
    Write-Host '  Startup entries:' -ForegroundColor DarkGray
    Write-Host ''

    $entries = @()

    # Registry HKCU
    $hkcu = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue
    if ($hkcu) {
        $hkcu.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            $entries += [PSCustomObject]@{ Source='HKCU Run'; Name=$_.Name; Command=$_.Value }
        }
    }

    # Registry HKLM
    $hklm = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue
    if ($hklm) {
        $hklm.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            $entries += [PSCustomObject]@{ Source='HKLM Run'; Name=$_.Name; Command=$_.Value }
        }
    }

    $i = 1
    foreach ($e in $entries) {
        Write-Host ("  {0,2}.  [{1}]  {2,-30}  {3}" -f $i, $e.Source, $e.Name, ($e.Command.Substring(0, [Math]::Min(50, $e.Command.Length)))) -ForegroundColor Gray
        $i++
    }

    $save = Read-InputWithBossKey 'Export startup list to .txt? (Y/N)'
    if ($save.ToUpper() -eq 'Y') {
        $out = Join-Path $env:USERPROFILE "Desktop\startup_apps_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $entries | Format-Table -AutoSize | Out-File $out -Encoding UTF8
        Write-Host ("  Saved: {0}" -f $out) -ForegroundColor Green
    }
    Track-Action 'Viewed startup apps'
}

function Debloat-VisualPerformance {
    param([switch]$Restore)
    if ($Restore) {
        if (-not (Confirm-Action 'Restore default visual effects?')) { return }
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        Set-ItemProperty $regPath -Name VisualFXSetting -Value 0 -ErrorAction SilentlyContinue
        Write-Host '  Visual effects restored to defaults.' -ForegroundColor Green
        Track-Action 'Restored visual effects'
    } else {
        if (-not (Confirm-Action 'Set Windows to Performance mode (disables animations/transparency)?')) { return }
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        if (-not (Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
        Set-ItemProperty $regPath -Name VisualFXSetting -Value 2 -ErrorAction SilentlyContinue


        Write-Host '  Performance mode applied.' -ForegroundColor Green
        Write-Host '  Log out and back in or restart Explorer to see full effect.' -ForegroundColor DarkGray
        Track-Action 'Set visual effects to performance mode'
    }
}

function Debloat-DisableBingSearch {
    if (-not (Confirm-Action 'Disable Bing search results in Start menu?')) { return }
    New-SafetyRestorePoint -Description 'Disable-BingSearch'
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
    if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
    Set-ItemProperty $path -Name BingSearchEnabled -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty $path -Name CortanaConsent    -Value 0 -ErrorAction SilentlyContinue
    Write-Host '  Bing search disabled in Start menu.' -ForegroundColor Green
    Track-Action 'Disabled Bing search in Start menu'
}

function Debloat-ApplyRegistryTweaks {
    $data = Get-DataFile 'debloat_list.json'
    if (-not $data -or -not $data.registryTweaks) { return }
    Write-Host ''
    $i = 1
    foreach ($t in $data.registryTweaks) {
        Write-Host ("  {0,2}.  [{1}]  {2}" -f $i, $t.risk, $t.name) -ForegroundColor Gray
        Write-Host ("        {0}" -f $t.description) -ForegroundColor DarkGray
        $i++
    }
    Write-Host ''
    $sel = Read-InputWithBossKey 'Apply all? (Y) or number to apply single'
    if ($sel.ToUpper() -eq 'Y') {
        if (-not (Confirm-Action 'Apply all registry tweaks? A restore point will be created.')) { return }
        New-SafetyRestorePoint -Description 'RegistryTweaks'
        foreach ($t in $data.registryTweaks) {
            try {
                if (-not (Test-Path $t.path)) { New-Item $t.path -Force | Out-Null }
                Set-ItemProperty -Path $t.path -Name $t.key -Value $t.value -ErrorAction Stop
                Write-StatusLine $t.name 'OK'
            } catch {
                Write-StatusLine ("$($t.name): {0}" -f $_.Exception.Message) 'WARN'
            }
        }
        Track-Action 'Applied all registry tweaks'
    } elseif ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $data.registryTweaks.Count) {
            $t = $data.registryTweaks[$idx]
            if (-not (Confirm-Action "Apply: $($t.name)?")) { return }
            New-SafetyRestorePoint -Description "RegTweak-$($t.name)"
            try {
                if (-not (Test-Path $t.path)) { New-Item $t.path -Force | Out-Null }
                Set-ItemProperty -Path $t.path -Name $t.key -Value $t.value -ErrorAction Stop
                Write-StatusLine $t.name 'OK'
            } catch {
                Write-StatusLine ("$($t.name): {0}" -f $_.Exception.Message) 'WARN'
            }
            Track-Action "Registry tweak: $($t.name)"
        }
    }
}

# ===========================================================================
# SEARCH
# ===========================================================================

$script:CommandIndex = @(
    # Networking
    @{ Cat='A'; Num='1';  Desc='Show active network adapters';        Fn={ Net-ShowAdapters }    }
    @{ Cat='A'; Num='2';  Desc='Enable a network adapter';            Fn={ Net-EnableAdapter }   }
    @{ Cat='A'; Num='3';  Desc='Disable a network adapter';           Fn={ Net-DisableAdapter }  }
    @{ Cat='A'; Num='4';  Desc='Restart a network adapter';           Fn={ Net-RestartAdapter }  }
    @{ Cat='A'; Num='5';  Desc='Show full IP config (ipconfig /all)'; Fn={ Net-ShowIPConfig }    }
    @{ Cat='A'; Num='6';  Desc='Release and renew IP address (DHCP)'; Fn={ Net-ReleaseRenew }    }
    @{ Cat='A'; Num='7';  Desc='Flush DNS cache';                     Fn={ Net-FlushDNS }        }
    @{ Cat='A'; Num='8';  Desc='Set DNS to Google (8.8.8.8)';         Fn={ Net-SetDNS 'Google' @('8.8.8.8','8.8.4.4') } }
    @{ Cat='A'; Num='9';  Desc='Set DNS to Cloudflare (1.1.1.1)';     Fn={ Net-SetDNS 'Cloudflare' @('1.1.1.1','1.0.0.1') } }
    @{ Cat='A'; Num='10'; Desc='Set DNS to OpenDNS';                  Fn={ Net-SetDNS 'OpenDNS' @('208.67.222.222','208.67.220.220') } }
    @{ Cat='A'; Num='11'; Desc='Set custom DNS servers';              Fn={ Net-SetCustomDNS }    }
    @{ Cat='A'; Num='12'; Desc='DNS latency benchmark (4 providers)'; Fn={ Net-DNSBenchmark }    }
    @{ Cat='A'; Num='13'; Desc='Show active TCP connections';         Fn={ Net-ShowConnections } }
    @{ Cat='A'; Num='14'; Desc='Show listening ports with process';   Fn={ Net-ShowListeningPorts }}
    @{ Cat='A'; Num='15'; Desc='Scan common ports on a target';       Fn={ Net-ScanCommonPorts } }
    @{ Cat='A'; Num='16'; Desc='Check listening ports vs bad ports';  Fn={ Net-CheckBadPorts }   }
    @{ Cat='A'; Num='17'; Desc='Reset TCP/IP stack';                  Fn={ Net-ResetTCPIP }      }
    @{ Cat='A'; Num='18'; Desc='Reset Winsock catalog';               Fn={ Net-ResetWinsock }    }
    @{ Cat='A'; Num='19'; Desc='Show ARP table';                      Fn={ Net-ShowARP }         }
    @{ Cat='A'; Num='20'; Desc='Show routing table';                  Fn={ Net-ShowRoutes }      }
    @{ Cat='A'; Num='21'; Desc='Add a static route';                  Fn={ Net-AddRoute }        }
    @{ Cat='A'; Num='22'; Desc='Remove a static route';               Fn={ Net-RemoveRoute }     }
    @{ Cat='A'; Num='23'; Desc='Ping / Test-Connection';              Fn={ Net-Ping }            }
    @{ Cat='A'; Num='24'; Desc='Traceroute to a target';              Fn={ Net-Traceroute }      }
    @{ Cat='A'; Num='25'; Desc='LAN device scanner (/24 subnet)';     Fn={ Net-LANScan }         }
    @{ Cat='A'; Num='26'; Desc='DNS / nslookup lookup';               Fn={ Net-DNSLookup }       }
    @{ Cat='A'; Num='27'; Desc='Show saved Wi-Fi profiles';           Fn={ Net-ShowWiFiProfiles }}
    @{ Cat='A'; Num='28'; Desc='Show saved Wi-Fi passwords';          Fn={ Net-ShowWiFiPasswords}}
    @{ Cat='A'; Num='29'; Desc='Wi-Fi signal strength';               Fn={ Net-WiFiSignal }      }
    @{ Cat='A'; Num='30'; Desc='Export full network info to .txt';    Fn={ Net-ExportNetworkInfo}}
    # System
    @{ Cat='B'; Num='1';  Desc='Show system info';                    Fn={ Sys-ShowInfo }        }
    @{ Cat='B'; Num='2';  Desc='Show disk usage (all drives)';        Fn={ Sys-ShowDiskUsage }   }
    @{ Cat='B'; Num='3';  Desc='Show temp folder sizes';              Fn={ Sys-ShowTempSizes }   }
    @{ Cat='B'; Num='4';  Desc='Show uptime and hardware info';       Fn={ Sys-ShowUptime }      }
    @{ Cat='B'; Num='5';  Desc='Clean user temp folder';              Fn={ Sys-CleanUserTemp }   }
    @{ Cat='B'; Num='6';  Desc='Clean system temp folder';            Fn={ Sys-CleanSystemTemp } }
    @{ Cat='B'; Num='7';  Desc='Empty Recycle Bin';                   Fn={ Sys-EmptyRecycleBin } }
    @{ Cat='B'; Num='8';  Desc='Clear Windows Update cache';          Fn={ Sys-ClearWUCache }    }
    @{ Cat='B'; Num='9';  Desc='Clear thumbnail cache';               Fn={ Sys-ClearThumbnailCache }}
    @{ Cat='B'; Num='10'; Desc='Clear all caches (temp+WU+DNS+thumb)';Fn={ Sys-ClearAllCaches }  }
    @{ Cat='B'; Num='11'; Desc='Check disk (chkdsk)';                 Fn={ Sys-CheckDisk }       }
    @{ Cat='B'; Num='12'; Desc='Run SFC /scannow';                    Fn={ Sys-RunSFC }          }
    @{ Cat='B'; Num='13'; Desc='Run DISM RestoreHealth';              Fn={ Sys-RunDISM }         }
    @{ Cat='B'; Num='14'; Desc='Schedule memory diagnostic (mdsched)';Fn={ Sys-ScheduleMemDiag } }
    @{ Cat='B'; Num='15'; Desc='List running services';               Fn={ Sys-ListServices }    }
    @{ Cat='B'; Num='16'; Desc='Start a service';                     Fn={ Sys-StartService }    }
    @{ Cat='B'; Num='17'; Desc='Stop a service';                      Fn={ Sys-StopService }     }
    @{ Cat='B'; Num='18'; Desc='Restart a service';                   Fn={ Sys-RestartService }  }
    @{ Cat='B'; Num='19'; Desc='List startup apps (registry)';        Fn={ Sys-ListStartupApps } }
    @{ Cat='B'; Num='20'; Desc='List scheduled tasks';                Fn={ Sys-ListScheduledTasks}}
    @{ Cat='B'; Num='21'; Desc='Windows Update status / start / stop';Fn={ Sys-WUStatus }        }
    @{ Cat='B'; Num='22'; Desc='Power plan manager';                  Fn={ Sys-PowerPlanManager }}
    @{ Cat='B'; Num='23'; Desc='Defrag a drive';                      Fn={ Sys-Defrag }          }
    @{ Cat='B'; Num='24'; Desc='Generate battery report';             Fn={ Sys-BatteryReport }   }
    @{ Cat='B'; Num='25'; Desc='Generate energy report';              Fn={ Sys-EnergyReport }    }
    @{ Cat='B'; Num='26'; Desc='Create a system restore point';       Fn={ Sys-CreateRestorePoint}}
    @{ Cat='B'; Num='27'; Desc='Export system info to .txt';          Fn={ Sys-ExportInfo }      }
    @{ Cat='B'; Num='28'; Desc='Reboot system';                       Fn={ Sys-Reboot }          }
    @{ Cat='B'; Num='29'; Desc='Shutdown system';                     Fn={ Sys-Shutdown }        }
    # Security
    @{ Cat='C'; Num='1';  Desc='Enable Windows Firewall (all profiles)'; Fn={ Sec-EnableFirewall } }
    @{ Cat='C'; Num='2';  Desc='Disable Windows Firewall';            Fn={ Sec-DisableFirewall } }
    @{ Cat='C'; Num='3';  Desc='Show active firewall rules';          Fn={ Sec-ShowFirewallRules }}
    @{ Cat='C'; Num='4';  Desc='Reset firewall to default policy';    Fn={ Sec-ResetFirewall }   }
    @{ Cat='C'; Num='5';  Desc='Block a host in hosts file';          Fn={ Sec-BlockHost }       }
    @{ Cat='C'; Num='6';  Desc='Unblock a host from hosts file';      Fn={ Sec-UnblockHost }     }
    @{ Cat='C'; Num='7';  Desc='View hosts file entries';             Fn={ Sec-ViewHosts }       }
    @{ Cat='C'; Num='8';  Desc='Show Defender status';                Fn={ Sec-DefenderStatus }  }
    @{ Cat='C'; Num='9';  Desc='Defender quick scan';                 Fn={ Sec-DefenderQuickScan }}
    @{ Cat='C'; Num='10'; Desc='Defender full scan';                  Fn={ Sec-DefenderFullScan }}
    @{ Cat='C'; Num='11'; Desc='Update Defender signatures';          Fn={ Sec-UpdateDefender }  }
    @{ Cat='C'; Num='12'; Desc='Show local user accounts';            Fn={ Sec-ShowUsers }       }
    @{ Cat='C'; Num='13'; Desc='Lock workstation';                    Fn={ Sec-LockWorkstation } }
    @{ Cat='C'; Num='14'; Desc='View UAC level info';                 Fn={ Sec-UACInfo }         }
    @{ Cat='C'; Num='15'; Desc='View password policy';                Fn={ Sec-PasswordPolicy }  }
    @{ Cat='C'; Num='16'; Desc='Disable DiagTrack (telemetry)';       Fn={ Sec-DisableDiagTrack }}
    @{ Cat='C'; Num='17'; Desc='Clear recent files history';          Fn={ Sec-ClearRecentFiles }}
    @{ Cat='C'; Num='18'; Desc='Clear clipboard';                     Fn={ Sec-ClearClipboard }  }
    @{ Cat='C'; Num='19'; Desc='Listening ports with process names';  Fn={ Sec-ListeningPorts }  }
    @{ Cat='C'; Num='20'; Desc='Top 25 processes by CPU';             Fn={ Sec-TopProcesses }    }
    @{ Cat='C'; Num='21'; Desc='Check for unsigned running processes'; Fn={ Sec-CheckUnsigned }  }
    @{ Cat='C'; Num='22'; Desc='Run security audit (scored report)';  Fn={ Sec-SecurityAudit }   }
    @{ Cat='C'; Num='23'; Desc='Show RDP status';                     Fn={ Sec-RDPStatus }       }
    @{ Cat='C'; Num='24'; Desc='Enable or disable RDP';               Fn={ Sec-ToggleRDP }       }
    @{ Cat='C'; Num='25'; Desc='Change RDP port number';              Fn={ Sec-SetRDPPort }      }
    @{ Cat='C'; Num='26'; Desc='BitLocker volume status';             Fn={ Sec-BitLockerStatus } }
    @{ Cat='C'; Num='27'; Desc='Check Windows activation status';     Fn={ Sec-ActivationStatus }}
    # Utilities
    @{ Cat='D'; Num='1';  Desc='Take a screenshot (saves to Desktop)';Fn={ Util-Screenshot }     }
    @{ Cat='D'; Num='2';  Desc='List installed programs';             Fn={ Util-ListPrograms }    }
    @{ Cat='D'; Num='3';  Desc='Create a local Administrator account';Fn={ Util-CreateAdmin }     }
    @{ Cat='D'; Num='4';  Desc='Remove a local user account';         Fn={ Util-RemoveUser }      }
    @{ Cat='D'; Num='5';  Desc='Change a local user password';        Fn={ Util-ChangePassword }  }
    @{ Cat='D'; Num='6';  Desc='List top 25 processes by CPU/RAM';    Fn={ Util-TopProcesses }    }
    @{ Cat='D'; Num='7';  Desc='Kill a process by name';              Fn={ Util-KillProcess }     }
    @{ Cat='D'; Num='8';  Desc='Restart Windows Explorer';            Fn={ Util-RestartExplorer } }
    @{ Cat='D'; Num='9';  Desc='Set system timezone';                 Fn={ Util-SetTimezone }     }
    @{ Cat='D'; Num='10'; Desc='Show recent system event log errors';  Fn={ Util-EventLogs }      }
    @{ Cat='D'; Num='11'; Desc='Export full system info to .txt';     Fn={ Util-ExportSysInfo }   }
    @{ Cat='D'; Num='12'; Desc='Disable a PnP device';                Fn={ Util-DisablePnP }      }
    @{ Cat='D'; Num='13'; Desc='Eject CD/DVD drive';                  Fn={ Util-EjectCD }         }
    @{ Cat='D'; Num='14'; Desc='Mount ISO image';                     Fn={ Util-MountISO }        }
    @{ Cat='D'; Num='15'; Desc='Dismount ISO image';                  Fn={ Util-DismountISO }     }
    @{ Cat='D'; Num='16'; Desc='Open Registry Editor';                Fn={ Util-OpenRegistry }    }
    @{ Cat='D'; Num='17'; Desc='Backup registry to .reg file';        Fn={ Util-BackupRegistry }  }
    @{ Cat='D'; Num='18'; Desc='Restore / import a .reg file';        Fn={ Util-RestoreRegistry } }
    # Misc
    @{ Cat='E'; Num='1';  Desc='Show SMB shares';                     Fn={ Misc-ShowSMBShares }  }
    @{ Cat='E'; Num='2';  Desc='Create a new SMB share';              Fn={ Misc-NewSMBShare }    }
    @{ Cat='E'; Num='3';  Desc='Remove an SMB share';                 Fn={ Misc-RemoveSMBShare } }
    @{ Cat='E'; Num='4';  Desc='Map a network drive';                 Fn={ Misc-MapDrive }       }
    @{ Cat='E'; Num='5';  Desc='Unmap a network drive';               Fn={ Misc-UnmapDrive }     }
    @{ Cat='E'; Num='6';  Desc='Sync system time (w32tm)';            Fn={ Misc-SyncTime }       }
    @{ Cat='E'; Num='7';  Desc='Export ARP cache to .txt';            Fn={ Misc-ExportARP }      }
    @{ Cat='E'; Num='8';  Desc='Toggle hibernate on/off';             Fn={ Misc-ToggleHibernate }}
    @{ Cat='E'; Num='9';  Desc='Backup entire 99SAK folder to .zip';  Fn={ Misc-BackupAll }      }
    # Debloat
    @{ Cat='F'; Num='1';  Desc='List preinstalled bloatware (with status)'; Fn={ Debloat-ListBloatware }   }
    @{ Cat='F'; Num='2';  Desc='Remove Xbox components';              Fn={ Debloat-RemoveByCategory 'Xbox' }}
    @{ Cat='F'; Num='3';  Desc='Remove game apps (Candy Crush, etc.)';Fn={ Debloat-RemoveByCategory 'Games' }}
    @{ Cat='F'; Num='4';  Desc='Remove productivity bloat (Clipchamp, News, Maps, etc.)'; Fn={ Debloat-RemoveByCategory 'Productivity' }}
    @{ Cat='F'; Num='5';  Desc='Remove Cortana and Tips';             Fn={ Debloat-RemoveByCategory 'System' }}
    @{ Cat='F'; Num='6';  Desc='Remove media apps (Groove, Movies & TV)'; Fn={ Debloat-RemoveByCategory 'Media' }}
    @{ Cat='F'; Num='7';  Desc='Remove OneDrive (user uninstall)';    Fn={ Debloat-RemoveOneDrive }  }
    @{ Cat='F'; Num='8';  Desc='Show and disable telemetry services'; Fn={ Debloat-TelemetryServices }}
    @{ Cat='F'; Num='9';  Desc='Startup app cleaner (view + export)'; Fn={ Debloat-StartupCleaner }  }
    @{ Cat='F'; Num='10'; Desc='Set visual effects to Performance mode'; Fn={ Debloat-VisualPerformance } }
    @{ Cat='F'; Num='11'; Desc='Restore default visual effects';      Fn={ Debloat-VisualPerformance -Restore }}
    @{ Cat='F'; Num='12'; Desc='Disable Bing search in Start menu';   Fn={ Debloat-DisableBingSearch }}
    @{ Cat='F'; Num='13'; Desc='Apply curated registry tweaks';       Fn={ Debloat-ApplyRegistryTweaks }}
)

function Show-SearchMode {
    Show-MiniHeader -Breadcrumbs @('Main', 'Search')
    Write-SectionLabel 'Search Commands'
    Write-Host '  Type a keyword to search across all categories.' -ForegroundColor DarkGray
    Write-Host '  Leave blank to cancel.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Divider

    $kw = Read-InputWithBossKey 'Keyword'
    if (-not $kw) { return }

    $matches_ = $script:CommandIndex | Where-Object { $_.Desc -like "*$kw*" }

    if (-not $matches_ -or $matches_.Count -eq 0) {
        Write-Host ("  No commands matched: '{0}'" -f $kw) -ForegroundColor Yellow
        Pause-ForUser
        return
    }

    Show-MiniHeader -Breadcrumbs @('Main', 'Search', $kw)
    Write-Host ("  {0} result(s) for: '{1}'" -f $matches_.Count, $kw) -ForegroundColor DarkGray
    Write-Host ''

    $i = 1
    foreach ($m in $matches_) {
        Write-Host ("  {0,2}.  [{1}-{2}]  {3}" -f $i, $m.Cat, $m.Num, $m.Desc) -ForegroundColor Gray
        $i++
    }

    Write-Host ''
    Write-Divider
    $sel = Read-InputWithBossKey 'Run item number (Enter to cancel)'
    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $matches_.Count) {
            Write-Host ''
            & $matches_[$idx].Fn
            Pause-ForUser
        }
    }
}

# ===========================================================================
# CATEGORY MENUS
# ===========================================================================

$script:CatNames = @{
    'A' = 'Networking'
    'B' = 'System Maintenance'
    'C' = 'Security & Privacy'
    'D' = 'Utilities'
    'E' = 'Misc'
    'F' = 'Debloat & Cleanup'
}

function Show-CategoryMenu {
    param([string]$Cat)
    $catName = $script:CatNames[$Cat]
    $cmds    = $script:CommandIndex | Where-Object { $_.Cat -eq $Cat }

    do {
        Show-MiniHeader -Breadcrumbs @('Main', $catName)

        # Group commands by first word of description for display clusters
        # Use simple section labels at defined breakpoints
        switch ($Cat) {
            'A' {
                Write-SectionLabel 'Adapters'
                $cmds | Where-Object { [int]$_.Num -le 4  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'IP & DNS'
                $cmds | Where-Object { [int]$_.Num -ge 5  -and [int]$_.Num -le 12 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Connections & Ports'
                $cmds | Where-Object { [int]$_.Num -ge 13 -and [int]$_.Num -le 18 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Routing & Diagnostics'
                $cmds | Where-Object { [int]$_.Num -ge 19 -and [int]$_.Num -le 26 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Wi-Fi & Export'
                $cmds | Where-Object { [int]$_.Num -ge 27 } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
            'B' {
                Write-SectionLabel 'Information'
                $cmds | Where-Object { [int]$_.Num -le 4  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Cleanup'
                $cmds | Where-Object { [int]$_.Num -ge 5  -and [int]$_.Num -le 10 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Repair'
                $cmds | Where-Object { [int]$_.Num -ge 11 -and [int]$_.Num -le 14 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Services'
                $cmds | Where-Object { [int]$_.Num -ge 15 -and [int]$_.Num -le 18 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Startup & Updates'
                $cmds | Where-Object { [int]$_.Num -ge 19 -and [int]$_.Num -le 21 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Power & Storage'
                $cmds | Where-Object { [int]$_.Num -ge 22 -and [int]$_.Num -le 25 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'System Control'
                $cmds | Where-Object { [int]$_.Num -ge 26 } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
            'C' {
                Write-SectionLabel 'Firewall'
                $cmds | Where-Object { [int]$_.Num -le 4  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Hosts File'
                $cmds | Where-Object { [int]$_.Num -ge 5  -and [int]$_.Num -le 7  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Defender'
                $cmds | Where-Object { [int]$_.Num -ge 8  -and [int]$_.Num -le 11 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Users & Accounts'
                $cmds | Where-Object { [int]$_.Num -ge 12 -and [int]$_.Num -le 15 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Privacy'
                $cmds | Where-Object { [int]$_.Num -ge 16 -and [int]$_.Num -le 18 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Monitoring & Audit'
                $cmds | Where-Object { [int]$_.Num -ge 19 -and [int]$_.Num -le 22 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Remote Access & Encryption'
                $cmds | Where-Object { [int]$_.Num -ge 23 } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
            'D' {
                Write-SectionLabel 'Capture & Media'
                $cmds | Where-Object { [int]$_.Num -le 1  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Programs & Processes'
                $cmds | Where-Object { [int]$_.Num -ge 2  -and [int]$_.Num -le 8  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Users'
                $cmds | Where-Object { [int]$_.Num -ge 3  -and [int]$_.Num -le 5  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'System Tools'
                $cmds | Where-Object { [int]$_.Num -ge 9  -and [int]$_.Num -le 15 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Registry'
                $cmds | Where-Object { [int]$_.Num -ge 16 } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
            'E' {
                Write-SectionLabel 'Network Shares & Drives'
                $cmds | Where-Object { [int]$_.Num -le 5  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'System & Backup'
                $cmds | Where-Object { [int]$_.Num -ge 6  } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
            'F' {
                Write-SectionLabel 'Preinstalled Apps'
                $cmds | Where-Object { [int]$_.Num -le 7  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Services & Telemetry'
                $cmds | Where-Object { [int]$_.Num -ge 8  -and [int]$_.Num -le 8  } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Startup & Performance'
                $cmds | Where-Object { [int]$_.Num -ge 9  -and [int]$_.Num -le 11 } | ForEach-Object { Write-Option $_.Num $_.Desc }
                Write-SectionLabel 'Registry Tweaks'
                $cmds | Where-Object { [int]$_.Num -ge 12 } | ForEach-Object { Write-Option $_.Num $_.Desc }
            }
        }

        Write-Host ''
        Write-Option -Key 'B' -Description 'Back to main menu' -KeyColor Red
        Write-Host ''
        Write-Divider
        Write-Host '  Ctrl+B to exit immediately' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-InputWithBossKey 'Choice').ToUpper()

        if ($choice -eq 'B') { return }

        $matched = $cmds | Where-Object { $_.Num -eq $choice }
        if ($matched) {
            Write-Host ''
            & $matched.Fn
            $script:ActionCount++
            Write-Host ''
            Write-Divider
            $cont = (Read-InputWithBossKey 'Enter to continue in this category, B to return').ToUpper()
            if ($cont -eq 'B') { return }
        } else {
            Write-Host '  Invalid choice.' -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 400
        }

    } while ($true)
}

# ===========================================================================
# MAIN MENU
# ===========================================================================

function Show-MainMenu {
    while ($true) {
        Show-Header
        Write-Host '  Main Menu' -ForegroundColor White
        Write-Host ''
        Write-Option -Key 'A' -Description 'Networking'           -Badge '[30 tools]'
        Write-Option -Key 'B' -Description 'System Maintenance'   -Badge '[29 tools]'
        Write-Option -Key 'C' -Description 'Security & Privacy'   -Badge '[27 tools]'
        Write-Option -Key 'D' -Description 'Utilities'            -Badge '[18 tools]'
        Write-Option -Key 'E' -Description 'Misc'                 -Badge '[ 9 tools]'
        Write-Option -Key 'F' -Description 'Debloat & Cleanup'    -Badge '[13 tools]'
        Write-Host ''
        Write-Option -Key 'W' -Description 'Safety Workflows'
        Write-Option -Key 'L' -Description 'Logs & Reports'
        Write-Option -Key 'H' -Description 'Command History'
        Write-Option -Key '/' -Description 'Search Commands'
        Write-Host ''
        Write-Option -Key 'Q' -Description 'Quit' -KeyColor Red
        Write-Host ''
        Write-Divider
        Write-Host '  Ctrl+B: exit immediately   |   session: ' -NoNewline -ForegroundColor DarkGray
        Write-Host $script:SessionID -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-InputWithBossKey 'Choice').ToUpper()

        switch ($choice) {
            'A' { Show-CategoryMenu -Cat 'A' }
            'B' { Show-CategoryMenu -Cat 'B' }
            'C' { Show-CategoryMenu -Cat 'C' }
            'D' { Show-CategoryMenu -Cat 'D' }
            'E' { Show-CategoryMenu -Cat 'E' }
            'F' { Show-CategoryMenu -Cat 'F' }
            'W' { Show-WorkflowMenu }
            'L' { Show-LogViewer   }
            'H' { Show-CommandHistory }
            '/' { Show-SearchMode  }
            'Q' {
                Write-SessionSummary -Start $script:SessionStart `
                    -Actions $script:ActionCount `
                    -Errors  $script:ErrorCount `
                    -SessionID $script:SessionID
                return
            }
            default {
                Write-Host '  Invalid choice.' -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 400
            }
        }
    }
}

# ===========================================================================
# SHORTCUT CREATION
# ===========================================================================

function New-DesktopShortcut {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '99SAK.lnk'
    if (Test-Path $lnkPath) { return }   # already exists
    try {
        $batPath = Join-Path $script:RootDir '99SAK.bat'
        if (-not (Test-Path $batPath)) { return }
        $shell  = New-Object -ComObject WScript.Shell
        $lnk    = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $batPath
        $lnk.WorkingDirectory = $script:RootDir
        $lnk.Description      = '99SAK - PowerShell Swiss Army Knife'
        $lnk.WindowStyle      = 1
        $lnk.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        Write-Host '  Desktop shortcut created: 99SAK.lnk' -ForegroundColor DarkGray
        Log-Event 'Created desktop shortcut' 'INFO'
    } catch {
        # Non-critical - silently skip if shortcut creation fails
        Log-Event "Shortcut creation failed: $_" 'WARN'
    }
}

# ===========================================================================
# SELF-TEST MODE
# ===========================================================================

function Invoke-SelfTest {
    Write-Host ''
    Write-Host ' 99SAK v2.0  Self-Test Mode' -ForegroundColor Cyan
    Write-Divider
    $pass = $true

    # Test 1: Modules loaded
    $moduleFns = @('Write-Divider','Log-Event','Is-Admin','New-SafetyRestorePoint')
    foreach ($fn in $moduleFns) {
        if (Get-Command $fn -ErrorAction SilentlyContinue) {
            Write-StatusLine "Function available: $fn" 'OK'
        } else {
            Write-StatusLine "Function MISSING: $fn" 'ERROR'
            $pass = $false
        }
    }

    # Test 2: Data files
    foreach ($f in @('bad_ports.json','debloat_list.json')) {
        $p = Join-Path $script:RootDir "data\$f"
        if (Test-Path $p) {
            $parsed = Get-Content $p -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed) {
                Write-StatusLine "Data file OK: $f" 'OK'
            } else {
                Write-StatusLine "Data file parse failed: $f" 'ERROR'
                $pass = $false
            }
        } else {
            Write-StatusLine "Data file missing: $f" 'ERROR'
            $pass = $false
        }
    }

    # Test 3: Log engine
    try {
        Log-Event 'SelfTest log write' 'DEBUG'
        Write-StatusLine 'Log engine: write OK' 'OK'
    } catch {
        Write-StatusLine "Log engine failed: $_" 'ERROR'
        $pass = $false
    }

    # Test 4: Command index populated
    $count = $script:CommandIndex.Count
    if ($count -gt 100) {
        Write-StatusLine "Command index: $count commands registered" 'OK'
    } else {
        Write-StatusLine "Command index seems incomplete: $count commands" 'WARN'
    }

    # Test 5: Console width readable
    $w = Get-ConsoleWidth
    if ($w -gt 0) {
        Write-StatusLine "Console width: $w chars" 'OK'
    } else {
        Write-StatusLine 'Could not read console width' 'WARN'
    }

    Write-Divider
    if ($pass) {
        Write-Host '  PASS - all critical checks passed.' -ForegroundColor Green
        exit 0
    } else {
        Write-Host '  FAIL - one or more checks failed.' -ForegroundColor Red
        exit 1
    }
}

# ===========================================================================
# ENTRY POINT
# ===========================================================================

if ($SelfTest) {
    # Self-test does not require elevation
    Invoke-SelfTest
    return
}

Ensure-Admin
New-DesktopShortcut
Show-MainMenu
