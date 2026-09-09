[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$InstanceId,
    [Parameter(Mandatory = $true)][int]$ServerPort,
    [string]$MslExe = 'D:\MC\server\MSL\MSL.exe',
    [string]$ConfigPath = 'D:\MC\server\MSL\MSL\config.json',
    [string]$ServerListPath = 'D:\MC\server\MSL\MSL\ServerList.json',
    [int]$WaitSeconds = 300,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Legacy cold-start path: only safe when MSL runs no other active servers.
# The on-demand controller uses start-msl-ui-instance.ps1, which starts a
# server card in the already-running MSL without restarting it.

function Get-MslProcess {
    $normalized = $MslExe.Replace('/', '\').TrimEnd('\')
    Get-CimInstance Win32_Process -Filter "Name='MSL.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.Replace('/', '\').TrimEnd('\') -ieq $normalized
        }
}

function Get-MslChildTasks {
    param([int[]]$MslIds)
    Get-CimInstance Win32_Process |
        Where-Object {
            $MslIds -contains $_.ParentProcessId -and
            $_.Name -ine 'conhost.exe' -and
            $_.Name -ine 'MSL.exe'
        }
}

function Test-ServerPort {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $ServerPort -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

if (Test-ServerPort) {
    Write-Host "Server already listening on port $ServerPort; no restart needed."
    exit 0
}

$serverList = Get-Content -Raw -LiteralPath $ServerListPath | ConvertFrom-Json
$entry = $serverList."$InstanceId"
if (-not $entry) {
    throw "MSL ServerList.json has no instance $InstanceId"
}

$json = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$newValue = [string]$InstanceId

$msl = @(Get-MslProcess)
if ($DryRun) {
    $mslText = if ($msl.Count -gt 0) { "running PID $($msl.ProcessId -join ',')" } else { 'not running' }
    Write-Host "Dry-run: MSL is $mslText; would set AutoOpenServer=$newValue and restart it to open instance $InstanceId ($($entry.Name), port $ServerPort)."
    exit 0
}

if ($msl.Count -gt 0) {
    $mslIds = @($msl.ProcessId)
    $tasks = @(Get-MslChildTasks -MslIds $mslIds)
    if ($tasks.Count -gt 0) {
        $detail = ($tasks | ForEach-Object { "$($_.Name) PID $($_.ProcessId)" }) -join ', '
        throw "MSL still runs active child task(s): $detail; stop them before restarting MSL"
    }
    Write-Host "Stopping MSL (PID $($msl.ProcessId -join ', ')) so AutoOpenServer is re-read..."
    $msl | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep -Seconds 2
    if (@(Get-MslProcess).Count -gt 0) {
        throw 'MSL is still running after Stop-Process'
    }
}

if ($json.AutoOpenServer -ne $newValue) {
    Copy-Item -LiteralPath $ConfigPath -Destination ($ConfigPath + '.bak') -Force
    $json.AutoOpenServer = $newValue
    $jsonText = $json | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        $jsonText,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "AutoOpenServer => $newValue"
}
else {
    Write-Host "AutoOpenServer already $newValue"
}

Write-Host 'Starting MSL; it will auto-open the requested instance from config.json.'
Start-Process -FilePath $MslExe

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$childSeen = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    if (Test-ServerPort) {
        Write-Host "OK: instance $InstanceId ($($entry.Name)) is listening on port $ServerPort."
        exit 0
    }
    $current = @(Get-MslProcess)
    if ($current.Count -gt 0) {
        $tasks = @(Get-MslChildTasks -MslIds @($current.ProcessId))
        if ($tasks.Count -gt 0) {
            $childSeen = $true
        }
    }
}

if (-not $childSeen) {
    throw "Timed out after $WaitSeconds s: MSL did not open instance $InstanceId"
}
throw "Timed out after $WaitSeconds s: instance $InstanceId started but port $ServerPort is not listening"
