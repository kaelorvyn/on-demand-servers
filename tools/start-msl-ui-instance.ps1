[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstanceName,
    [Parameter(Mandatory = $true)][string]$InstanceTag,
    [Parameter(Mandatory = $true)][int]$ServerPort,
    [int]$MslPid = 0,
    [int]$WaitSeconds = 300,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Test-ServerPort {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $ServerPort -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class OnDemandNativeUi {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public static List<IntPtr> WindowsForProcess(int processId) {
        var result = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint windowProcessId;
            GetWindowThreadProcessId(hWnd, out windowProcessId);
            if (windowProcessId == processId) {
                result.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static string WindowTitle(IntPtr hWnd) {
        var text = new StringBuilder(512);
        GetWindowText(hWnd, text, text.Capacity);
        return text.ToString();
    }
}
'@

function Get-StartButtonName {
    param([IntPtr]$WindowHandle)
    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
        $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            'controlServer1')
        $button = $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
        if ($button) {
            return $button.Current.Name
        }
    }
    catch {
    }
    return ""
}

function Get-StaleManagementWindows {
    param(
        [int]$MslProcessId,
        [string]$InstanceName,
        [int]$ServerPort
    )
    return @([OnDemandNativeUi]::WindowsForProcess($MslProcessId) |
        Where-Object {
            $title = [OnDemandNativeUi]::WindowTitle($_)
            $titleMatches = $title -eq $InstanceName -or $title.Contains("[$ServerPort]")
            $titleMatches -and (Get-StartButtonName $_) -eq '开服'
        })
}

function Close-StaleManagementWindows {
    param(
        [int]$MslProcessId,
        [string]$InstanceName,
        [int]$ServerPort
    )
    $windows = Get-StaleManagementWindows -MslProcessId $MslProcessId -InstanceName $InstanceName -ServerPort $ServerPort
    if ($windows.Count -eq 0) {
        return
    }
    Write-Host "Closing stopped management window '$InstanceName' so MSL can start it from the server card..."
    foreach ($hwnd in $windows) {
        [OnDemandNativeUi]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $remaining = Get-StaleManagementWindows -MslProcessId $MslProcessId -InstanceName $InstanceName -ServerPort $ServerPort
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out closing stopped management window '$InstanceName'."
}

if (Test-ServerPort) {
    Write-Host "Server already listening on port $ServerPort; nothing to start."
    exit 0
}

$msl = @(Get-CimInstance Win32_Process -Filter "Name='MSL.exe'" -ErrorAction SilentlyContinue)
if ($MslPid -gt 0) {
    $msl = @($msl | Where-Object { $_.ProcessId -eq $MslPid })
}
if ($msl.Count -ne 1) {
    throw "Expected exactly one running MSL process for in-place start, found $($msl.Count)."
}

$root = [System.Windows.Automation.AutomationElement]::RootElement
$pidCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
    [int]$msl[0].ProcessId)
$windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCondition)
if ($windows.Count -eq 0) {
    throw 'MSL main window is not present in the UI Automation tree.'
}

if ($DryRun) {
    $staleCount = @(Get-StaleManagementWindows -MslProcessId $msl[0].ProcessId -InstanceName $InstanceName -ServerPort $ServerPort).Count
    Write-Host "Dry-run: would close $staleCount stopped window(s) for '$InstanceName', then invoke '开启服务器' on the MSL server card (port $ServerPort)."
    exit 0
}

Close-StaleManagementWindows -MslProcessId $msl[0].ProcessId -InstanceName $InstanceName -ServerPort $ServerPort

$listCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
    'serverList')
$mainWindow = $null
foreach ($candidate in $windows) {
    if ($candidate.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $listCondition)) {
        $mainWindow = $candidate
        break
    }
}
if (-not $mainWindow) {
    throw 'MSL server list page was not found in any MSL window.'
}
$list = $mainWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $listCondition)

$itemCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::ListItem)
$items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, $itemCondition)
$target = $null
foreach ($item in $items) {
    $texts = $item.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $hasName = $false
    $hasTag = $false
    foreach ($t in $texts) {
        if ($t.Current.ControlType.ProgrammaticName -notlike '*Text*') { continue }
        if ($t.Current.Name -eq $InstanceName -or $t.Current.Name -like "*$InstanceName*") {
            $hasName = $true
        }
        if ($t.Current.Name -eq $InstanceTag) {
            $hasTag = $true
        }
    }
    if ($hasName -and $hasTag) {
        $target = $item
        break
    }
}
if (-not $target) {
    throw "Server card '$InstanceName' ($InstanceTag) was not found in MSL."
}

$startCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    '开启服务器')
$startButton = $target.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $startCondition)
if (-not $startButton) {
    throw "Start button was not found on server card '$InstanceName'."
}
$invoke = $null
try {
    $invoke = $startButton.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
}
catch {
    throw "Start button on '$InstanceName' does not support Invoke."
}

if ($DryRun) {
    Write-Host "Dry-run: MSL PID $($msl[0].ProcessId) would click start on '$InstanceName' ($InstanceTag, port $ServerPort) without restarting MSL."
    exit 0
}

Write-Host "Clicking MSL start for '$InstanceName' ($InstanceTag) on running MSL PID $($msl[0].ProcessId)..."
$invoke.Invoke()

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-ServerPort) {
        Write-Host "OK: '$InstanceName' is listening on port $ServerPort."
        exit 0
    }
}

throw "Timed out after $WaitSeconds s: '$InstanceName' did not start listening on port $ServerPort."
