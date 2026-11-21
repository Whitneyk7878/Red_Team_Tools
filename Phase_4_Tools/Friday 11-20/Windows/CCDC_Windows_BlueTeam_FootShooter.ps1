# /////////////////////////////////////////////////////////////\
# CCDC Blue Team -- FOOT SHOOTER  (Service Break Simulator)
#  ___              _     ___ _               _
# | __|___  ___  __| |   / __| |_  ___  ___ | |_ ___ _ _
# | _|/ _ \/ _ \/ _` |   \__ \ ' \/ _ \/ _ \|  _/ -_) '_|
# |_| \___/\___/\__,_|   |___/_||_\___/\___/ \__\___|_|
#
# PURPOSE: Blue-team training tool. Run on your OWN box to
# simulate common misconfigurations that kill scored services.
# NOT an attack script. Zero persistence, zero C2.
#
# Services scored by box:
#   AD box   : ICMP (ping), WinRM, DNS, Internet/routing
#   MSSQL box: ICMP (ping), MSSQL, RDP, SMB, Internet/routing
#
# Usage:
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1              # interactive
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1 -Box AD      # skip box menu
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1 -Box MSSQL
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1 -Box AD    -All
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1 -Box MSSQL -Modules MSSQL,SMB
#   .\CCDC_Windows_BlueTeam_FootShooter.ps1 -Status     # show state only
# /////////////////////////////////////////////////////////////\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateSet("AD","MSSQL")]
    [string]   $Box     = "",
    [string[]] $Modules = @(),
    [switch]   $All,
    [switch]   $Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# -- Color helpers --------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# -- State ----------------------------------------------------------------------
$script:Results = [ordered]@{}   # ModuleName -> PENDING|RUNNING|SUCCESS|FAILED

# -- Banner ---------------------------------------------------------------------
function Show-Banner {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Yellow
    Write-Host " //                                                         //" -ForegroundColor Yellow
    Write-Host " //   " -ForegroundColor Yellow -NoNewline
    Write-Host "FOOT SHOOTER  --  Blue Team Service Break Simulator" -ForegroundColor White -NoNewline
    Write-Host "   //" -ForegroundColor Yellow
    Write-Host " //   Run on YOUR OWN box. Simulates real admin mistakes.   //" -ForegroundColor Yellow
    Write-Host " //   Every scored service goes red. That is the point.     //" -ForegroundColor Yellow
    Write-Host " //                                                         //" -ForegroundColor Yellow
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Yellow
    Write-Host ""
}

# -- Module definitions by box -------------------------------------------------
#  Execution order is deliberate:
#   AD:    DNS -> WinRM -> ICMP -> NET
#   MSSQL: MSSQL -> SMB -> RDP -> ICMP -> NET
#   NET always last -- deletes default route, severing cross-subnet scoring traffic

$script:ADModules = [ordered]@{
    "DNS"   = @{ Num = 1; Label = "DNS Misconfigured  "; Role = "DNS  " }
    "WinRM" = @{ Num = 2; Label = "WinRM Broken       "; Role = "WinRM" }
    "ICMP"  = @{ Num = 3; Label = "ICMP Blackout      "; Role = "ICMP " }
    "NET"   = @{ Num = 4; Label = "Network Wreck      "; Role = "NET  " }
}

$script:MSSQLModules = [ordered]@{
    "MSSQL" = @{ Num = 1; Label = "MSSQL Down         "; Role = "MSSQL" }
    "SMB"   = @{ Num = 2; Label = "SMB Killed         "; Role = "SMB  " }
    "RDP"   = @{ Num = 3; Label = "RDP Disabled       "; Role = "RDP  " }
    "ICMP"  = @{ Num = 4; Label = "ICMP Blackout      "; Role = "ICMP " }
    "NET"   = @{ Num = 5; Label = "Network Wreck      "; Role = "NET  " }
}

function Get-BoxModules { param([string]$B)
    if ($B -eq "AD") { return $script:ADModules }
    return $script:MSSQLModules
}

# -- Menu helpers ---------------------------------------------------------------
function Show-BoxMenu {
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |      FOOT SHOOTER -- Which box are you on?              |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [A]  Active Directory box                              |" -ForegroundColor Cyan
    Write-Host "  |       Services scored: ICMP, WinRM, DNS, routing        |" -ForegroundColor Cyan
    Write-Host "  |                                                         |" -ForegroundColor Cyan
    Write-Host "  |  [B]  MSSQL box                                         |" -ForegroundColor Cyan
    Write-Host "  |       Services scored: ICMP, MSSQL, RDP, SMB, routing   |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [Q] Quit                                               |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Show-ModuleMenu { param([string]$B)
    $mods    = Get-BoxModules $B
    $boxName = if ($B -eq "AD") { "Active Directory" } else { "MSSQL" }

    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  |   BOX: {0,-50}|" -f "$boxName  -- Select Modules") -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan

    foreach ($key in $mods.Keys) {
        $def   = $mods[$key]
        $state = if ($script:Results.Contains($key)) { $script:Results[$key] } else { "PENDING" }

        $stTag = "[$state]"
        $stCol = switch ($state) {
            "SUCCESS" { "Green"  }
            "FAILED"  { "Red"    }
            "RUNNING" { "Yellow" }
            default   { "White"  }
        }

        Write-Host ("  |  [{0}] {1} ({2})  " -f $def.Num, $def.Label, $def.Role) -ForegroundColor White -NoNewline
        Write-Host ("{0,-10}" -f $stTag) -ForegroundColor $stCol -NoNewline
        Write-Host " |" -ForegroundColor Cyan
    }

    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [A] Run All (safe order)  [S] Status  [Q] Quit         |" -ForegroundColor Cyan
    Write-Host "  |  Enter number(s), name(s), or comma-separated list      |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status { param([string]$B)
    $mods = Get-BoxModules $B
    Write-Section "Module Status"
    foreach ($key in $mods.Keys) {
        $state = if ($script:Results.Contains($key)) { $script:Results[$key] } else { "PENDING" }
        $col   = switch ($state) {
            "SUCCESS" { "Green"  }
            "FAILED"  { "Red"    }
            "RUNNING" { "Yellow" }
            default   { "White"  }
        }
        Write-Host ("  {0,-20} " -f $key) -NoNewline
        Write-Host $state -ForegroundColor $col
    }
}

function Resolve-Token { param([string]$Token, [string]$B)
    $mods = Get-BoxModules $B
    $t    = $Token.ToLower().Trim()
    foreach ($key in $mods.Keys) {
        if ($t -eq [string]$mods[$key].Num) { return $key }
    }
    foreach ($key in $mods.Keys) {
        if ($t -eq $key.ToLower()) { return $key }
    }
    return $null
}

# -- Module dispatch ------------------------------------------------------------
function Invoke-Modules { param([string[]]$ToRun, [string]$B)
    $mods    = Get-BoxModules $B
    $summary = @()

    foreach ($key in $mods.Keys) {
        if ($key -notin $ToRun) { continue }

        $script:Results[$key] = "RUNNING"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            switch ($key) {
                "DNS"   { Invoke-DNSMisconfigured  }
                "WinRM" { Invoke-WinRMBroken       }
                "ICMP"  { Invoke-ICMPBlackout      }
                "MSSQL" { Invoke-MSSQLDown         }
                "SMB"   { Invoke-SMBKilled         }
                "RDP"   { Invoke-RDPDisabled       }
                "NET"   { Invoke-NetworkWreck      }
            }
            $script:Results[$key] = "SUCCESS"
            $summary += [PSCustomObject]@{ Module = $key; Result = "SUCCESS"; Elapsed = $sw.Elapsed.ToString("mm\:ss") }
        } catch {
            Write-Err "[$key] Unhandled exception: $_"
            $script:Results[$key] = "FAILED"
            $summary += [PSCustomObject]@{ Module = $key; Result = "FAILED";  Elapsed = $sw.Elapsed.ToString("mm\:ss") }
        }
        $sw.Stop()
    }

    Write-Host ""
    Write-Section "Session Summary"
    $summary | Format-Table -AutoSize | Out-String | Write-Host
}

# ==============================================================================
#  SQL REGISTRY HELPERS
# ==============================================================================
function Get-SqlTcpRegistryPath {
    $sqlRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    if (-not (Test-Path $sqlRoot)) { return $null }
    $verDir = Get-ChildItem $sqlRoot -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^MSSQL\d+\.MSSQLSERVER$' } |
              Select-Object -First 1
    if (-not $verDir) { return $null }
    return Join-Path $sqlRoot "$($verDir.PSChildName)\MSSQLServer\SuperSocketNetLib\Tcp"
}

function Get-SqlMssqlBase {
    $sqlRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    if (-not (Test-Path $sqlRoot)) { return $null }
    $verDir = Get-ChildItem $sqlRoot -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^MSSQL\d+\.MSSQLSERVER$' } |
              Select-Object -First 1
    if (-not $verDir) { return $null }
    return Join-Path $sqlRoot "$($verDir.PSChildName)\MSSQLServer"
}

# ==============================================================================
#  MODULE: DNS MISCONFIGURED  (AD box -- runs FIRST)
# ==============================================================================
# Simulates common admin mistakes:
#   - Stopping DNS for "planned maintenance" and forgetting to restart
#   - CIS/STIG hardening guide says "disable unnecessary services"
#   - Running a "block all inbound" script that catches port 53
#   - Hardening guide says "restrict DNS to listen on localhost only"
#   - Switching forwarder to new ISP and typing wrong IP
#   - Following "authoritative DNS hardening" guide that disables recursion
# ==============================================================================
function Invoke-DNSMisconfigured {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   DNS MISCONFIGURED" -ForegroundColor Yellow
    Write-Host "   What went wrong: port blocked + loopback bind + forwarder poisoned + recursion off + service dead" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    $dnsSvc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if (-not $dnsSvc) {
        Write-Warn "DNS Server service not found -- DNS Server role may not be installed. Skipping."
        return
    }

    # Sub-step 1: Block inbound UDP/TCP 53 via Windows Firewall
    Write-Section "DNS 1/6  Block port 53 via Windows Firewall"
    $fwRules = @(
        @{ Name = "CCDC_FootShooter_BlockDNS_UDP53"; Proto = "UDP"; Port = 53 },
        @{ Name = "CCDC_FootShooter_BlockDNS_TCP53"; Proto = "TCP"; Port = 53 }
    )
    foreach ($r in $fwRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
                Write-Info "Firewall rule already exists: $($r.Name)"
            } else {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Proto `
                    -LocalPort $r.Port -Action Block -Profile Any -Enabled True | Out-Null
                Write-Success "Firewall rule created: block inbound $($r.Proto) port $($r.Port)"
            }
        } catch {
            Write-Err "Firewall rule failed ($($r.Name)): $_"
        }
    }

    # Sub-step 2: Bind DNS to listen only on loopback (simulates "restrict DNS to localhost")
    Write-Section "DNS 2/6  Bind DNS listen address to 127.0.0.1 only"
    try {
        & dnscmd.exe /Config /ListenAddresses 127.0.0.1 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "DNS ListenAddresses = 127.0.0.1 (scoring engine cannot reach it from outside)"
        } else {
            Write-Warn "dnscmd /Config /ListenAddresses returned rc=$LASTEXITCODE"
        }
    } catch {
        Write-Warn "dnscmd not available or failed: $_"
    }

    # Sub-step 3: Poison DNS forwarders to RFC 5737 blackhole
    Write-Section "DNS 3/6  Poison DNS forwarders to 192.0.2.1 (RFC 5737 blackhole)"
    try {
        & dnscmd.exe /ResetForwarders 192.0.2.1 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "DNS forwarders set to 192.0.2.1 -- all recursive lookups blackholed"
        } else {
            Write-Warn "dnscmd /ResetForwarders returned rc=$LASTEXITCODE"
        }
    } catch {
        Write-Warn "dnscmd /ResetForwarders failed: $_"
    }

    # Sub-step 4: Disable DNS recursion (correct on public authoritative servers, fatal on AD DNS)
    Write-Section "DNS 4/6  Disable DNS recursion (NoRecursion = 1)"
    try {
        & dnscmd.exe /Config /NoRecursion 1 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "DNS recursion disabled -- server only answers its own zones; all external lookups fail"
        } else {
            Write-Warn "dnscmd /Config /NoRecursion returned rc=$LASTEXITCODE"
        }
    } catch {
        Write-Warn "dnscmd /Config /NoRecursion failed: $_"
    }

    # Sub-step 5: Stop DNS service
    Write-Section "DNS 5/6  Stop DNS Server service"
    try {
        Stop-Service -Name DNS -Force -ErrorAction Stop
        Write-Success "DNS Server service stopped"
    } catch {
        Write-Warn "Could not stop DNS service: $_"
    }

    # Sub-step 6: Disable DNS service startup (prevents auto/manual restart)
    Write-Section "DNS 6/6  Disable DNS Server service startup"
    try {
        Set-Service -Name DNS -StartupType Disabled -ErrorAction Stop
        Write-Success "DNS Server StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable DNS service: $_"
    }

    Write-Success "DNS Misconfigured complete"
    Write-Info "  To fix: Remove firewall rules (CCDC_FootShooter_BlockDNS_*)"
    Write-Info "           dnscmd /Config /ListenAddresses 0.0.0.0"
    Write-Info "           dnscmd /ResetForwarders <correct upstream DNS IP>"
    Write-Info "           dnscmd /Config /NoRecursion 0"
    Write-Info "           Set-Service DNS -StartupType Automatic; Start-Service DNS"
}

# ==============================================================================
#  MODULE: WINRM BROKEN  (AD box -- runs SECOND)
# ==============================================================================
# Simulates common admin mistakes:
#   - Running Disable-PSRemoting from a "PS hardening" guide
#   - CIS benchmark says disable WinRM if not needed
#   - "Close all remote management ports" firewall script
#   - Setting AllowRemoteShellAccess=0 from a GPO hardening template
#   - Explicitly removing all WinRM listeners as part of "config cleanup"
#   - Setting MaxConnections=0 from a performance hardening guide
# ==============================================================================
function Invoke-WinRMBroken {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   WINRM BROKEN" -ForegroundColor Yellow
    Write-Host "   What went wrong: PSRemoting disabled + listeners removed + ports blocked + MaxConns=0 + service dead" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    $winrmSvc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if (-not $winrmSvc) {
        Write-Warn "WinRM service not found. Skipping."
        return
    }

    # Sub-step 1: Disable PSRemoting (disables listeners, sets AllowRemoteShellAccess=0)
    Write-Section "WinRM 1/6  Disable-PSRemoting"
    try {
        Disable-PSRemoting -Force -ErrorAction SilentlyContinue
        Write-Success "Disable-PSRemoting -Force executed (listeners removed, remote shell disabled)"
    } catch {
        Write-Warn "Disable-PSRemoting failed: $_"
    }

    # Sub-step 2: Set AllowRemoteShellAccess = 0 in registry (GPO/registry path)
    Write-Section "WinRM 2/6  Disable AllowRemoteShellAccess in registry"
    $wsmanPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service"
    try {
        if (-not (Test-Path $wsmanPolicy)) {
            New-Item -Path $wsmanPolicy -Force | Out-Null
        }
        Set-ItemProperty -Path $wsmanPolicy -Name "AllowRemoteShellAccess" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "AllowRemoteShellAccess = 0 set in $wsmanPolicy"
    } catch {
        Write-Warn "Registry path failed: $_"
    }

    # Sub-step 3: Explicitly remove all WinRM HTTP and HTTPS listeners
    Write-Section "WinRM 3/6  Remove all WinRM HTTP/HTTPS listeners explicitly"
    try {
        & winrm.cmd delete winrm/config/listener?Address=*+Transport=HTTP  2>$null | Out-Null
        Write-Info "winrm delete HTTP listener (rc=$LASTEXITCODE)"
    } catch { }
    try {
        & winrm.cmd delete winrm/config/listener?Address=*+Transport=HTTPS 2>$null | Out-Null
        Write-Info "winrm delete HTTPS listener (rc=$LASTEXITCODE)"
    } catch { }
    # Belt-and-suspenders via PS WSMan provider
    try {
        $listeners = Get-WSManInstance -ResourceURI winrm/config/listener -Enumerate -ErrorAction SilentlyContinue
        if ($listeners) {
            foreach ($l in $listeners) {
                try {
                    Remove-WSManInstance -ResourceURI winrm/config/listener `
                        -SelectorSet @{Address=$l.Address; Transport=$l.Transport} -ErrorAction SilentlyContinue
                    Write-Success "Removed WinRM listener: $($l.Transport) @ $($l.Address)"
                } catch { }
            }
        } else {
            Write-Info "No WinRM listeners found (already removed or never configured)"
        }
    } catch {
        Write-Warn "WSMan listener enumeration failed: $_"
    }

    # Sub-step 4: Set MaxConnections = 0 (even a re-created listener accepts zero connections)
    Write-Section "WinRM 4/6  Set MaxConnections = 0"
    try {
        & winrm.cmd set winrm/config '@{MaxConnections="0"}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "WinRM MaxConnections = 0 (zero concurrent connections accepted)"
        } else {
            Write-Warn "winrm set MaxConnections returned rc=$LASTEXITCODE (WinRM may already be stopped)"
        }
    } catch {
        Write-Warn "winrm set MaxConnections failed: $_"
    }

    # Sub-step 5: Block TCP 5985 (HTTP) and 5986 (HTTPS) via firewall
    Write-Section "WinRM 5/6  Block ports 5985 and 5986 via Windows Firewall"
    $fwRules = @(
        @{ Name = "CCDC_FootShooter_BlockWinRM_TCP5985"; Port = 5985 },
        @{ Name = "CCDC_FootShooter_BlockWinRM_TCP5986"; Port = 5986 }
    )
    foreach ($r in $fwRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
                Write-Info "Firewall rule already exists: $($r.Name)"
            } else {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP `
                    -LocalPort $r.Port -Action Block -Profile Any -Enabled True | Out-Null
                Write-Success "Firewall rule created: block inbound TCP $($r.Port)"
            }
        } catch {
            Write-Err "Firewall rule failed ($($r.Name)): $_"
        }
    }

    # Sub-step 6: Stop and disable WinRM service
    Write-Section "WinRM 6/6  Stop and disable WinRM service"
    try {
        Stop-Service -Name WinRM -Force -ErrorAction Stop
        Write-Success "WinRM service stopped"
    } catch {
        Write-Warn "Could not stop WinRM: $_"
    }
    try {
        Set-Service -Name WinRM -StartupType Disabled -ErrorAction Stop
        Write-Success "WinRM StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable WinRM: $_"
    }

    Write-Success "WinRM Broken complete"
    Write-Info "  To fix: Remove firewall rules (CCDC_FootShooter_BlockWinRM_*)"
    Write-Info "           Remove registry value AllowRemoteShellAccess from $wsmanPolicy"
    Write-Info "           Set-Service WinRM -StartupType Automatic; Enable-PSRemoting -Force"
    Write-Info "           winrm set winrm/config '@{MaxConnections=""25""}'"
}

# ==============================================================================
#  MODULE: ICMP BLACKOUT  (both boxes -- runs SECOND-TO-LAST before NET)
# ==============================================================================
# Simulates common admin mistakes:
#   - Disabling the built-in Echo Request firewall allow rule when "hardening"
#   - Running "block all inbound" firewall command without an ICMP exception
#   - Adding an explicit "block all ICMP" rule from a network hardening guide
#   - Setting default inbound firewall action to Block across all profiles
# ==============================================================================
function Invoke-ICMPBlackout {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   ICMP BLACKOUT" -ForegroundColor Yellow
    Write-Host "   What went wrong: built-in rules off + explicit block + ICMPv6 blocked + default-deny" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    # Sub-step 1: Disable the built-in Windows Firewall ICMP Echo Request allow rules
    Write-Section "ICMP 1/5  Disable built-in Echo Request allow rules"
    $builtinRules = @("FPS-ICMP4-ERQ-In", "FPS-ICMP4-ERQ-Out", "FPS-ICMP6-ERQ-In", "FPS-ICMP6-ERQ-Out",
                      "CoreNet-Diag-ICMP4-EchoRequest-In", "CoreNet-Diag-ICMP4-EchoRequest-Out")
    foreach ($rName in $builtinRules) {
        try {
            $rule = Get-NetFirewallRule -Name $rName -ErrorAction SilentlyContinue
            if ($rule) {
                Set-NetFirewallRule -Name $rName -Enabled False -ErrorAction Stop
                Write-Success "Disabled built-in rule: $rName"
            }
        } catch {
            Write-Warn "Could not disable $rName : $_"
        }
    }

    # Sub-step 2: Create an explicit block rule for ICMPv4 Echo Request (type 8)
    Write-Section "ICMP 2/5  Add explicit block rule for ICMPv4 Echo Request"
    try {
        $existing = Get-NetFirewallRule -DisplayName "CCDC_FootShooter_BlockICMP_EchoReq" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Info "Block rule already exists: CCDC_FootShooter_BlockICMP_EchoReq"
        } else {
            New-NetFirewallRule -DisplayName "CCDC_FootShooter_BlockICMP_EchoReq" `
                -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
                -Action Block -Profile Any -Enabled True | Out-Null
            Write-Success "Created explicit block rule: ICMPv4 Echo Request (type 8) inbound"
        }
    } catch {
        Write-Err "Failed to create ICMPv4 block rule: $_"
    }

    # Sub-step 3: Add a netsh-level block rule (firewall profile path, independent of PS rules)
    Write-Section "ICMP 3/5  Add netsh advfirewall block rule for ping"
    try {
        $existing = & netsh.exe advfirewall firewall show rule name="CCDC_FootShooter_BlockPing" 2>$null
        if ($existing -match "Rule Name") {
            Write-Info "netsh rule already exists: CCDC_FootShooter_BlockPing"
        } else {
            & netsh.exe advfirewall firewall add rule name="CCDC_FootShooter_BlockPing" `
                protocol=icmpv4:8,any dir=in action=block 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "netsh advfirewall: added block rule for ICMPv4 Echo Request"
            } else {
                Write-Warn "netsh advfirewall add rule returned rc=$LASTEXITCODE"
            }
        }
    } catch {
        Write-Warn "netsh advfirewall command failed: $_"
    }

    # Sub-step 4: Block ICMPv6 Echo Request (type 128) in case scoring engine uses IPv6
    Write-Section "ICMP 4/5  Add explicit block rule for ICMPv6 Echo Request"
    try {
        $existing = Get-NetFirewallRule -DisplayName "CCDC_FootShooter_BlockICMPv6_EchoReq" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Info "Block rule already exists: CCDC_FootShooter_BlockICMPv6_EchoReq"
        } else {
            New-NetFirewallRule -DisplayName "CCDC_FootShooter_BlockICMPv6_EchoReq" `
                -Direction Inbound -Protocol ICMPv6 -IcmpType 128 `
                -Action Block -Profile Any -Enabled True | Out-Null
            Write-Success "Created explicit block rule: ICMPv6 Echo Request (type 128) inbound"
        }
    } catch {
        Write-Err "Failed to create ICMPv6 block rule: $_"
    }

    # Sub-step 5: Set Windows Firewall default inbound action to Block on all profiles
    Write-Section "ICMP 5/5  Set Windows Firewall default inbound action to Block on all profiles"
    try {
        Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultInboundAction Block -ErrorAction Stop
        Write-Success "DefaultInboundAction = Block on Domain, Public, Private profiles"
        Write-Info    "All inbound traffic not covered by an existing allow rule is now blocked"
    } catch {
        Write-Err "Failed to set DefaultInboundAction: $_"
    }

    Write-Success "ICMP Blackout complete"
    Write-Info "  To fix: Remove-NetFirewallRule -DisplayName 'CCDC_FootShooter_BlockICMP*'"
    Write-Info "           netsh advfirewall firewall delete rule name='CCDC_FootShooter_BlockPing'"
    Write-Info "           Re-enable built-in FPS-ICMP4-ERQ-In and related rules"
    Write-Info "           Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultInboundAction Allow"
}

# ==============================================================================
#  MODULE: MSSQL DOWN  (MSSQL box -- runs FIRST)
# ==============================================================================
# Simulates common admin mistakes:
#   - Stopping SQL Server for "planned maintenance" and forgetting to restart
#   - "Disable unnecessary services" checklist kills MSSQLSERVER
#   - Blocking port 1433 inbound during "database server hardening"
#   - Using SQL Server Config Manager to disable TCP/IP
#   - Changing port to "hide" SQL from scanners
#   - Stopping SQLBrowser because "it's not needed"
#   - Switching to Windows-auth only to "improve security" (locks out SQL logins)
#   - Pointing error log at non-existent path so SQL won't start even if fixed
# ==============================================================================
function Invoke-MSSQLDown {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   MSSQL DOWN" -ForegroundColor Yellow
    Write-Host "   What went wrong: port blocked + TCP/IP off + port remapped + auth mode + error log path + service dead" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    $sqlSvc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    if (-not $sqlSvc) {
        Write-Warn "MSSQLSERVER service not found -- SQL Server may not be installed. Skipping."
        return
    }

    # Sub-step 1: Block TCP 1433 and UDP 1434 via Windows Firewall
    Write-Section "MSSQL 1/7  Block ports 1433 (TCP) and 1434 (UDP) via Windows Firewall"
    $fwRules = @(
        @{ Name = "CCDC_FootShooter_BlockSQL_TCP1433"; Proto = "TCP"; Port = 1433 },
        @{ Name = "CCDC_FootShooter_BlockSQL_UDP1434"; Proto = "UDP"; Port = 1434 }
    )
    foreach ($r in $fwRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
                Write-Info "Firewall rule already exists: $($r.Name)"
            } else {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Proto `
                    -LocalPort $r.Port -Action Block -Profile Any -Enabled True | Out-Null
                Write-Success "Firewall rule created: block inbound $($r.Proto) port $($r.Port)"
            }
        } catch {
            Write-Err "Firewall rule failed ($($r.Name)): $_"
        }
    }

    # Sub-step 2: Disable TCP/IP protocol in SQL Server registry
    Write-Section "MSSQL 2/7  Disable TCP/IP protocol in SQL Server registry"
    $tcpPath = Get-SqlTcpRegistryPath
    if ($tcpPath -and (Test-Path $tcpPath)) {
        try {
            Set-ItemProperty -Path $tcpPath -Name "Enabled" -Value 0 -Type DWord -ErrorAction Stop
            Write-Success "SQL Server TCP/IP Enabled = 0 (simulates SSMS: disable TCP/IP protocol)"
        } catch {
            Write-Warn "Could not disable SQL TCP/IP in registry: $_"
        }
    } else {
        Write-Warn "SQL Server TCP registry path not found -- skipping TCP/IP disable"
    }

    # Sub-step 3: Remap SQL Server port 1433 -> 14334 in registry
    Write-Section "MSSQL 3/7  Remap SQL Server port 1433 -> 14334 in registry"
    if ($tcpPath) {
        $ipAllPath = Join-Path $tcpPath "IPAll"
        if (Test-Path $ipAllPath) {
            try {
                Set-ItemProperty -Path $ipAllPath -Name "TcpPort"         -Value "14334" -ErrorAction Stop
                Set-ItemProperty -Path $ipAllPath -Name "TcpDynamicPorts" -Value ""      -ErrorAction Stop
                Write-Success "TcpPort remapped to 14334; TcpDynamicPorts cleared"
            } catch {
                Write-Warn "Could not remap SQL port in registry: $_"
            }
        } else {
            Write-Warn "SQL IPAll registry path not found -- skipping port remap"
        }
    }

    # Sub-step 4: Stop and disable SQL Server Browser
    Write-Section "MSSQL 4/7  Stop and disable SQL Server Browser"
    try {
        $browser = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
        if ($browser) {
            Stop-Service -Name SQLBrowser -Force -ErrorAction SilentlyContinue
            Set-Service  -Name SQLBrowser -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Success "SQLBrowser stopped and disabled"
        } else {
            Write-Info "SQLBrowser service not found (may not be installed)"
        }
    } catch {
        Write-Warn "SQLBrowser stop/disable failed: $_"
    }

    # Sub-step 5: Set SQL Server authentication mode to Windows-only (LoginMode=1)
    Write-Section "MSSQL 5/7  Set SQL Server authentication to Windows-only (LoginMode = 1)"
    $sqlBase = Get-SqlMssqlBase
    if ($sqlBase -and (Test-Path $sqlBase)) {
        try {
            Set-ItemProperty -Path $sqlBase -Name "LoginMode" -Value 1 -Type DWord -ErrorAction Stop
            Write-Success "LoginMode = 1 (Windows Authentication only -- SQL logins including scoring account locked out)"
        } catch {
            Write-Warn "Could not set LoginMode: $_"
        }
    } else {
        Write-Warn "SQL Server MSSQLServer registry base not found -- skipping LoginMode"
    }

    # Sub-step 6: Point SQL Server error log to non-existent path
    Write-Section "MSSQL 6/7  Point SQL Server error log to non-existent path"
    if ($sqlBase -and (Test-Path $sqlBase)) {
        try {
            Set-ItemProperty -Path $sqlBase -Name "ErrorLogFile" `
                -Value "C:\NonExistentLogs\ERRORLOG" -Type String -ErrorAction Stop
            Write-Success "ErrorLogFile -> C:\NonExistentLogs\ERRORLOG (SQL cannot start without its error log)"
        } catch {
            Write-Warn "Could not set ErrorLogFile: $_"
        }
    } else {
        Write-Warn "SQL Server MSSQLServer registry base not found -- skipping ErrorLogFile"
    }

    # Sub-step 7: Stop and disable MSSQLSERVER
    Write-Section "MSSQL 7/7  Stop and disable MSSQLSERVER service"
    try {
        Stop-Service -Name MSSQLSERVER -Force -ErrorAction Stop
        Write-Success "MSSQLSERVER service stopped"
    } catch {
        Write-Warn "Could not stop MSSQLSERVER: $_"
    }
    try {
        Set-Service -Name MSSQLSERVER -StartupType Disabled -ErrorAction Stop
        Write-Success "MSSQLSERVER StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable MSSQLSERVER: $_"
    }

    Write-Success "MSSQL Down complete"
    Write-Info "  To fix: Remove firewall rules (CCDC_FootShooter_BlockSQL_*)"
    Write-Info "           Restore TCP/IP Enabled=1 and TcpPort=1433 in SQL Server registry"
    Write-Info "           Restore LoginMode=2 (Mixed) in SQL Server MSSQLServer registry key"
    Write-Info "           Restore ErrorLogFile to default path in SQL Server MSSQLServer registry key"
    Write-Info "           Set-Service MSSQLSERVER -StartupType Automatic; Start-Service MSSQLSERVER"
    Write-Info "           Set-Service SQLBrowser   -StartupType Automatic; Start-Service SQLBrowser"
}

# ==============================================================================
#  MODULE: SMB KILLED  (MSSQL box -- runs SECOND)
# ==============================================================================
# Simulates common admin mistakes:
#   - Disabling SMBv1 for security (correct!) but accidentally running
#     -EnableSMB2Protocol $false too (copy-paste error from a hardening guide)
#   - Stopping "Server" (LanmanServer) thinking it is just the file server
#   - Blocking TCP 445 inbound during "SMB hardening"
#   - Setting MaxMpxCt=1 from an obscure benchmark (kills all concurrent connections)
#   - Blocking TCP 139 when "blocking all SMB ports"
#   - Setting LmCompatibilityLevel=0 from old hardening guide (forces LM-only auth)
# ==============================================================================
function Invoke-SMBKilled {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   SMB KILLED" -ForegroundColor Yellow
    Write-Host "   What went wrong: SMB2 off + ports 445+139 blocked + LM-only auth + capacity=1 + service dead" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    $smbSvc = Get-Service -Name LanmanServer -ErrorAction SilentlyContinue
    if (-not $smbSvc) {
        Write-Warn "LanmanServer service not found. Skipping."
        return
    }

    # Sub-step 1: Disable SMB1 AND SMB2 (the "oops I went too far" mistake)
    Write-Section "SMB 1/6  Disable SMB1 and SMB2 protocols"
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -EnableSMB2Protocol $false -Force -ErrorAction Stop
        Write-Success "Set-SmbServerConfiguration: SMB1=disabled, SMB2=disabled"
    } catch {
        Write-Warn "Set-SmbServerConfiguration failed: $_ -- trying registry fallback"
        try {
            $lanParams = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
            Set-ItemProperty -Path $lanParams -Name "SMB2" -Value 0 -Type DWord -ErrorAction Stop
            Write-Success "Registry fallback: LanmanServer\Parameters\SMB2 = 0"
        } catch {
            Write-Err "Registry fallback also failed: $_"
        }
    }

    # Sub-step 2: Block TCP 445 and TCP 139 via Windows Firewall
    Write-Section "SMB 2/6  Block TCP 445 and TCP 139 via Windows Firewall"
    $fwRules = @(
        @{ Name = "CCDC_FootShooter_BlockSMB_TCP445"; Port = 445 },
        @{ Name = "CCDC_FootShooter_BlockSMB_TCP139"; Port = 139 }
    )
    foreach ($r in $fwRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
                Write-Info "Firewall rule already exists: $($r.Name)"
            } else {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP `
                    -LocalPort $r.Port -Action Block -Profile Any -Enabled True | Out-Null
                Write-Success "Firewall rule created: block inbound TCP $($r.Port)"
            }
        } catch {
            Write-Err "Firewall rule creation failed ($($r.Name)): $_"
        }
    }

    # Sub-step 3: Set LmCompatibilityLevel = 0 (forces LM-only responses, all modern clients refuse)
    Write-Section "SMB 3/6  Set LmCompatibilityLevel = 0 (LM-only auth)"
    try {
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
            -Name "LmCompatibilityLevel" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "LmCompatibilityLevel = 0 (forces LM-only responses -- all Vista+ clients refuse auth)"
    } catch {
        Write-Err "Failed to set LmCompatibilityLevel: $_"
    }

    # Sub-step 4: Strangle SMB connection capacity (MaxMpxCt=1 from obscure hardening guide)
    Write-Section "SMB 4/6  Set connection capacity to 1 (MaxMpxCt / MaxWorkItems)"
    $lanParams = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    $capProps  = @(
        @{ Name = "MaxMpxCt";     Value = 1 },
        @{ Name = "MaxWorkItems"; Value = 1 }
    )
    foreach ($p in $capProps) {
        try {
            Set-ItemProperty -Path $lanParams -Name $p.Name -Value $p.Value -Type DWord -ErrorAction Stop
            Write-Success "$($p.Name) = $($p.Value) (connection capacity strangled)"
        } catch {
            Write-Warn "Could not set $($p.Name): $_"
        }
    }

    # Sub-step 5: Stop and disable LanmanServer service
    Write-Section "SMB 5/6  Stop and disable LanmanServer service"
    try {
        Stop-Service -Name LanmanServer -Force -ErrorAction Stop
        Write-Success "LanmanServer service stopped"
    } catch {
        Write-Warn "Could not stop LanmanServer: $_"
    }
    try {
        Set-Service -Name LanmanServer -StartupType Disabled -ErrorAction Stop
        Write-Success "LanmanServer StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable LanmanServer: $_"
    }

    # Sub-step 6: (informational) note that this count matches plan 6/6
    Write-Section "SMB 6/6  Verification note"
    Write-Info "SMB is broken via 5 independent mechanisms:"
    Write-Info "  SMB2 disabled + TCP 445 blocked + TCP 139 blocked + LM-only auth + LanmanServer dead"

    Write-Success "SMB Killed complete"
    Write-Info "  To fix: Remove firewall rules (CCDC_FootShooter_BlockSMB_*)"
    Write-Info "           Set-SmbServerConfiguration -EnableSMB2Protocol `$true -Force"
    Write-Info "           Restore LmCompatibilityLevel=3 in HKLM:\SYSTEM\...\Control\Lsa"
    Write-Info "           Remove MaxMpxCt / MaxWorkItems overrides from LanmanServer\Parameters"
    Write-Info "           Set-Service LanmanServer -StartupType Automatic; Start-Service LanmanServer"
}

# ==============================================================================
#  MODULE: RDP DISABLED  (MSSQL box -- runs THIRD)
# ==============================================================================
# Simulates common admin mistakes:
#   - Unchecking "Allow Remote Desktop connections" in System Properties
#     (sets fDenyTSConnections=1)
#   - Disabling "Remote Desktop Services" following a hardening guide
#   - Blocking TCP 3389 during "close all remote access ports" hardening
#   - Changing RDP port to "hide it from scanners" (port 33890)
#   - Setting session timeouts in ms instead of minutes (typo/unit confusion)
#   - Following two conflicting hardening guides: SecurityLayer=0 (legacy) +
#     MinEncryptionLevel=4 (FIPS) = paradox that kills all client handshakes
# ==============================================================================
function Invoke-RDPDisabled {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   RDP DISABLED" -ForegroundColor Yellow
    Write-Host "   What went wrong: fDenyTS=1 + port remapped + FW blocked + sec paradox + 1ms timeouts + service dead" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    $rdpSvc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if (-not $rdpSvc) {
        Write-Warn "TermService (Remote Desktop Services) not found. Skipping."
        return
    }

    $tsKey     = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
    $rdpTcpKey = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

    # Sub-step 1: Set fDenyTSConnections=1 (same as unchecking RDP in System Properties)
    Write-Section "RDP 1/6  Set fDenyTSConnections = 1 (disable RDP at TS layer)"
    try {
        Set-ItemProperty -Path $tsKey -Name "fDenyTSConnections" -Value 1 -Type DWord -ErrorAction Stop
        Write-Success "fDenyTSConnections = 1 (RDP connections hard-denied)"
    } catch {
        Write-Err "Failed to set fDenyTSConnections: $_"
    }

    # Sub-step 2: Remap RDP port 3389 -> 33890 in registry
    Write-Section "RDP 2/6  Remap RDP port 3389 -> 33890 in registry"
    try {
        if (Test-Path $rdpTcpKey) {
            Set-ItemProperty -Path $rdpTcpKey -Name "PortNumber" -Value 33890 -Type DWord -ErrorAction Stop
            Write-Success "RDP PortNumber changed from 3389 to 33890"
        } else {
            Write-Warn "RDP-Tcp registry key not found -- port remap skipped"
        }
    } catch {
        Write-Err "Failed to remap RDP port: $_"
    }

    # Sub-step 3: Block TCP 3389 via Windows Firewall + disable built-in allow rules
    Write-Section "RDP 3/6  Block TCP 3389 via Windows Firewall"
    try {
        $rName = "CCDC_FootShooter_BlockRDP_TCP3389"
        if (Get-NetFirewallRule -DisplayName $rName -ErrorAction SilentlyContinue) {
            Write-Info "Firewall rule already exists: $rName"
        } else {
            New-NetFirewallRule -DisplayName $rName -Direction Inbound -Protocol TCP `
                -LocalPort 3389 -Action Block -Profile Any -Enabled True | Out-Null
            Write-Success "Firewall rule created: block inbound TCP 3389"
        }
    } catch {
        Write-Err "Firewall block rule creation failed: $_"
    }
    $builtinRdpRules = @(
        "RemoteDesktop-UserMode-In-TCP",
        "RemoteDesktop-UserMode-In-UDP",
        "Remote Desktop - User Mode (TCP-In)",
        "Remote Desktop - User Mode (UDP-In)"
    )
    foreach ($r in $builtinRdpRules) {
        try {
            $rule = Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue
            if (-not $rule) { $rule = Get-NetFirewallRule -Name $r -ErrorAction SilentlyContinue }
            if ($rule) {
                Set-NetFirewallRule -InputObject $rule -Enabled False -ErrorAction SilentlyContinue
                Write-Success "Disabled built-in RDP allow rule: $r"
            }
        } catch { }
    }

    # Sub-step 4: Security layer paradox -- SecurityLayer=0 (legacy) + MinEncryptionLevel=4 (FIPS)
    Write-Section "RDP 4/6  Security layer paradox: SecurityLayer=0 (legacy) + MinEncryptionLevel=4 (FIPS)"
    if (Test-Path $rdpTcpKey) {
        try {
            Set-ItemProperty -Path $rdpTcpKey -Name "SecurityLayer"      -Value 0 -Type DWord -ErrorAction Stop
            Write-Success "SecurityLayer = 0 (legacy RDP mode -- no TLS)"
        } catch {
            Write-Err "Failed to set SecurityLayer: $_"
        }
        try {
            Set-ItemProperty -Path $rdpTcpKey -Name "MinEncryptionLevel" -Value 4 -Type DWord -ErrorAction Stop
            Write-Success "MinEncryptionLevel = 4 (FIPS mandatory -- paradox: clients need TLS but it is off)"
        } catch {
            Write-Err "Failed to set MinEncryptionLevel: $_"
        }
    } else {
        Write-Warn "RDP-Tcp registry key not found -- security layer paradox skipped"
    }

    # Sub-step 5: Set session timeouts to 1ms (typo/unit confusion: ms instead of minutes)
    Write-Section "RDP 5/6  Set session timeouts to 1ms (unit confusion: ms not minutes)"
    if (Test-Path $rdpTcpKey) {
        $timeouts = @("MaxConnectionTime", "MaxIdleTime", "MaxDisconnectionTime")
        foreach ($t in $timeouts) {
            try {
                Set-ItemProperty -Path $rdpTcpKey -Name $t -Value 1 -Type DWord -ErrorAction Stop
                Write-Success "$t = 1 (ms -- any surviving RDP session disconnects instantly)"
            } catch {
                Write-Warn "Could not set ${t}: $_"
            }
        }
    } else {
        Write-Warn "RDP-Tcp registry key not found -- timeout settings skipped"
    }

    # Sub-step 6: Stop and disable TermService
    Write-Section "RDP 6/6  Stop and disable Remote Desktop Services (TermService)"
    try {
        Stop-Service -Name TermService -Force -ErrorAction Stop
        Write-Success "TermService stopped"
    } catch {
        Write-Warn "Could not stop TermService: $_"
    }
    try {
        Set-Service -Name TermService -StartupType Disabled -ErrorAction Stop
        Write-Success "TermService StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable TermService: $_"
    }

    Write-Success "RDP Disabled complete"
    Write-Info "  To fix: Set fDenyTSConnections=0 in Terminal Server registry key"
    Write-Info "           Restore PortNumber=3389 in RDP-Tcp registry key"
    Write-Info "           Remove firewall rule (CCDC_FootShooter_BlockRDP_TCP3389)"
    Write-Info "           Restore SecurityLayer=2, MinEncryptionLevel=2 in RDP-Tcp key"
    Write-Info "           Remove MaxConnectionTime/MaxIdleTime overrides from RDP-Tcp key"
    Write-Info "           Set-Service TermService -StartupType Automatic; Start-Service TermService"
}

# ==============================================================================
#  MODULE: NETWORK WRECK  (both boxes -- runs LAST, always)
# ==============================================================================
# Simulates common admin mistakes:
#   - Changing default gateway to wrong IP when "updating network config"
#   - Setting NIC DNS to 127.0.0.1 thinking the DNS Server service handles it
#   - Stopping DNS Client (Dnscache) thinking it is the DNS Server service
#   - Running a "block all web traffic" lockdown firewall script
#   - Setting WinHTTP proxy to a dead server when configuring Windows Update
#   - Running "route delete 0.0.0.0" while troubleshooting routing
#
# WARNING: NET 5/6 and 6/6 delete and corrupt the default route. After these
# steps the box cannot reach any host outside its local subnet. Run LAST.
# ==============================================================================
function Invoke-NetworkWreck {
    Write-Host ""
    Write-Host " /////////////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   NETWORK WRECK" -ForegroundColor Yellow
    Write-Host "   What went wrong: NIC DNS dead + Dnscache dead + outbound web blocked + proxy dead + no default route" -ForegroundColor DarkGray
    Write-Host " \/////////////////////////////////////////////////////////////" -ForegroundColor Magenta

    # Sub-step 1: Set all active NIC DNS resolvers to invalid addresses
    Write-Section "NET 1/6  Set all active NIC DNS resolvers to 127.0.0.1 and 0.0.0.0"
    try {
        $upAdapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" }
        if ($upAdapters) {
            foreach ($nic in $upAdapters) {
                try {
                    Set-DnsClientServerAddress -InterfaceAlias $nic.Name `
                        -ServerAddresses @("127.0.0.1","0.0.0.0") -ErrorAction Stop
                    Write-Success "NIC '$($nic.Name)': DNS resolvers set to 127.0.0.1, 0.0.0.0"
                } catch {
                    Write-Warn "Could not set DNS on '$($nic.Name)': $_"
                }
            }
        } else {
            Write-Warn "No active network adapters found"
        }
    } catch {
        Write-Err "Get-NetAdapter failed: $_"
    }

    # Sub-step 2: Stop and disable DNS Client service (Dnscache)
    Write-Section "NET 2/6  Stop and disable DNS Client service (Dnscache)"
    try {
        Stop-Service -Name Dnscache -Force -ErrorAction SilentlyContinue
        Write-Success "Dnscache service stopped"
    } catch {
        Write-Warn "Could not stop Dnscache: $_"
    }
    try {
        Set-Service -Name Dnscache -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Success "Dnscache StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable Dnscache: $_"
    }
    Write-Info "Windows resolver stub dead -- name resolution fails for all processes"

    # Sub-step 3: Block outbound HTTP (80) and HTTPS (443)
    Write-Section "NET 3/6  Block outbound HTTP (80) and HTTPS (443) via Windows Firewall"
    $outRules = @(
        @{ Name = "CCDC_FootShooter_BlockOut_HTTP80";   Port = 80  },
        @{ Name = "CCDC_FootShooter_BlockOut_HTTPS443"; Port = 443 }
    )
    foreach ($r in $outRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
                Write-Info "Firewall rule already exists: $($r.Name)"
            } else {
                New-NetFirewallRule -DisplayName $r.Name -Direction Outbound -Protocol TCP `
                    -RemotePort $r.Port -Action Block -Profile Any -Enabled True | Out-Null
                Write-Success "Firewall rule created: block outbound TCP $($r.Port)"
            }
        } catch {
            Write-Err "Firewall rule creation failed ($($r.Name)): $_"
        }
    }

    # Sub-step 4: Set WinHTTP system proxy to non-existent server
    Write-Section "NET 4/6  Set WinHTTP system proxy to 127.0.0.1:9999 (non-existent)"
    try {
        & netsh.exe winhttp set proxy proxy-server="http://127.0.0.1:9999" bypass-list="<local>" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "WinHTTP proxy = 127.0.0.1:9999 (Windows Update, WSUS, services that use WinHTTP all fail)"
        } else {
            Write-Warn "netsh winhttp set proxy returned rc=$LASTEXITCODE"
        }
    } catch {
        Write-Warn "netsh winhttp command failed: $_"
    }

    # Sub-step 5: Delete all IPv4 default routes
    Write-Section "NET 5/6  Delete all IPv4 default routes (0.0.0.0/0)"
    Write-Warn "After this step the box cannot reach hosts outside its local subnet"
    try {
        $defaultRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
        if ($defaultRoutes) {
            foreach ($route in $defaultRoutes) {
                try {
                    Remove-NetRoute -InterfaceIndex $route.InterfaceIndex `
                        -DestinationPrefix $route.DestinationPrefix `
                        -NextHop $route.NextHop -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Success "Deleted default route: via $($route.NextHop) on ifIdx=$($route.InterfaceIndex)"
                } catch {
                    Write-Warn "Could not delete route via $($route.NextHop): $_"
                }
            }
        } else {
            Write-Info "No default routes found (already missing)"
        }
    } catch {
        Write-Err "Get-NetRoute failed: $_"
    }

    # Sub-step 6: Add wrong default gateway (192.0.2.1 -- RFC 5737 blackhole) on all active NICs
    Write-Section "NET 6/6  Add wrong default gateway 192.0.2.1 (RFC 5737 blackhole) on all active NICs"
    try {
        $upAdapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" }
        foreach ($nic in $upAdapters) {
            try {
                New-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix "0.0.0.0/0" `
                    -NextHop "192.0.2.1" -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
                Write-Success "Added default route via 192.0.2.1 on '$($nic.Name)' (routed nowhere)"
            } catch {
                Write-Warn "Could not add blackhole route on '$($nic.Name)': $_"
            }
        }
    } catch {
        Write-Err "Get-NetAdapter failed: $_"
    }

    Write-Success "Network Wreck complete"
    Write-Info "  To fix:"
    Write-Info "    Set-DnsClientServerAddress -InterfaceAlias <NIC> -ResetServerAddresses"
    Write-Info "    Set-Service Dnscache -StartupType Automatic; Start-Service Dnscache"
    Write-Info "    Remove-NetFirewallRule -DisplayName 'CCDC_FootShooter_BlockOut_HTTP80'"
    Write-Info "    Remove-NetFirewallRule -DisplayName 'CCDC_FootShooter_BlockOut_HTTPS443'"
    Write-Info "    netsh winhttp reset proxy"
    Write-Info "    Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop 192.0.2.1 -Confirm:`$false"
    Write-Info "    route add 0.0.0.0 mask 0.0.0.0 <correct_gateway>"
}

# ==============================================================================
#  ENTRY POINT
# ==============================================================================

Show-Banner

if ($Status) {
    if (-not $Box) {
        Write-Warn "-Status requires -Box AD or -Box MSSQL to know which modules to display"
        exit 1
    }
    $mods = Get-BoxModules $Box
    foreach ($key in $mods.Keys) {
        if (-not $script:Results.Contains($key)) { $script:Results[$key] = "PENDING" }
    }
    Show-Status -B $Box
    exit 0
}

# -- Box selection ---------------------------------------------------------------
if (-not $Box) {
    Show-BoxMenu
    while ($true) {
        $choice = (Read-Host "  Box selection").Trim()
        if     ($choice -ieq "A") { $Box = "AD";    break }
        elseif ($choice -ieq "B") { $Box = "MSSQL"; break }
        elseif ($choice -ieq "Q") { Write-Info "Exiting."; exit 0 }
        else                      { Write-Warn "Enter A, B, or Q" }
    }
}

$mods = Get-BoxModules $Box
foreach ($key in $mods.Keys) { $script:Results[$key] = "PENDING" }

# -- Non-interactive path -------------------------------------------------------
if ($All) {
    $toRun = @($mods.Keys)
    Write-Info "Box: $Box -- Running all modules in safe order: $($toRun -join ' -> ')"
    Invoke-Modules -ToRun $toRun -B $Box
    exit 0
}

if ($Modules.Count -gt 0) {
    $resolved = @()
    foreach ($m in $Modules) {
        $name = Resolve-Token -Token $m -B $Box
        if ($name) { $resolved += $name }
        else        { Write-Warn "Unknown module '$m' -- ignored" }
    }
    if ($resolved.Count -eq 0) { Write-Err "No valid modules resolved."; exit 1 }
    Invoke-Modules -ToRun $resolved -B $Box
    exit 0
}

# -- Interactive menu loop -------------------------------------------------------
while ($true) {
    Show-ModuleMenu -B $Box

    $userInput = (Read-Host "  Enter choice(s)").Trim()
    if ($userInput -eq "") { continue }

    if ($userInput -ieq "Q") { Write-Info "Exiting."; break }

    if ($userInput -ieq "S") {
        Show-Status -B $Box
        continue
    }

    if ($userInput -ieq "A") {
        $toRun = @($mods.Keys)
        Invoke-Modules -ToRun $toRun -B $Box
        continue
    }

    $tokens   = $userInput -split '[,\s]+' | Where-Object { $_ -ne "" }
    $resolved = @()
    foreach ($t in $tokens) {
        $name = Resolve-Token -Token $t -B $Box
        if ($name) { $resolved += $name }
        else        { Write-Warn "Unknown token '$t' -- skipped" }
    }

    if ($resolved.Count -gt 0) {
        Invoke-Modules -ToRun ($resolved | Select-Object -Unique) -B $Box
    }
}
