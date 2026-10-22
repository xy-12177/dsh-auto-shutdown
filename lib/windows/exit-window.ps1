<#
.SYNOPSIS
Displays the automatic shutdown window for dsh-auto-shutdown.

The Node host starts this script detached with redirected stdin/stdout/stderr.
Only READY and COMMITTED protocol lines are written to stdout; diagnostics go
to stderr. -Preview exercises the window without a parent process or dsh IO.
#>
[CmdletBinding()]
param(
    [int]$ParentPid,
    [switch]$Preview,
    [int]$PreviewSeconds = 12,
    [ValidateRange(1, 30)]
    [int]$MaxLifetimeSeconds = 30
)

$ErrorActionPreference = 'Stop'
$parent = $null
$parentHandle = [IntPtr]::Zero

try {
    if (-not $Preview) {
        if ($ParentPid -le 0) { throw 'ParentPid is required unless -Preview is used.' }
        # Acquire and retain the process handle before loading the UI runtime.
        # The retained handle remains bound to this process object if its PID is
        # later reused by Windows.
        $parent = [System.Diagnostics.Process]::GetProcessById($ParentPid)
        $parentHandle = $parent.Handle
        if ($parentHandle -eq [IntPtr]::Zero) { throw "Could not retain parent process handle $ParentPid." }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $rendererPath = Join-Path $PSScriptRoot 'renderer.cs'
    $renderer = [System.IO.File]::ReadAllText($rendererPath, [System.Text.Encoding]::UTF8)
    Add-Type -TypeDefinition $renderer -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll')

    $logoPath = Join-Path $PSScriptRoot 'deepseek-logo.png'
    $mascotPath = Join-Path $PSScriptRoot 'whale-maid-static.png'
    if (-not [DshProgress]::Show('DeepSeek Harness', '正在关闭…', $logoPath, $mascotPath, $true)) {
        throw 'The exit window did not become visible within its startup timeout.'
    }

    if ($Preview) {
        Start-Sleep -Milliseconds ([Math]::Max(1000, $PreviewSeconds * 1000))
        [DshProgress]::SetStage(100, '已退出')
        Start-Sleep -Milliseconds 1000
        [DshProgress]::Close()
        exit 0
    }

    [Console]::Out.WriteLine('READY')
    [Console]::Out.Flush()

    # ReadLine runs separately so that the main loop can also notice a parent
    # exit before COMMIT. EOF or any non-COMMIT input is an abort handshake.
    $readTask = [DshProgress]::ReadCommandAsync()
    $committed = $false
    while (-not $committed) {
        if ($parent.HasExited) {
            [DshProgress]::Close()
            exit 0
        }
        if ($readTask.IsCompleted) {
            $line = $readTask.GetAwaiter().GetResult()
            if ($line -cne 'COMMIT') {
                [DshProgress]::Close()
                exit 0
            }
            $committed = $true
        } else {
            [void]$parent.WaitForExit(100)
        }
    }

    # The Node side expects COMMITTED only after the helper has accepted the
    # commit and started watching the retained parent handle.
    [Console]::Out.WriteLine('COMMITTED')
    [Console]::Out.Flush()

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $MaxLifetimeSeconds) {
        if ($parent.WaitForExit(100)) {
            [DshProgress]::SetStage(100, '已退出')
            Start-Sleep -Milliseconds 1000
            [DshProgress]::Close()
            exit 0
        }
    }

    # The maximum lifetime is a safety cap. Closing at the cap must never look
    # like a successful shutdown, so leave the loading stage unchanged.
    [DshProgress]::Close()
    exit 0
} catch {
    [Console]::Error.WriteLine(('exit-window: ' + $_.Exception.Message))
    try { [DshProgress]::Close() } catch { }
    exit 1
} finally {
    if ($null -ne $parent) { $parent.Dispose() }
}
