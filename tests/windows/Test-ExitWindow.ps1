[CmdletBinding()]
param(
    [switch]$SkipScreenshot
)

$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\windows')).Path
$tempRoot = Join-Path $env:TEMP ('退出窗口 集成测试 ' + [guid]::NewGuid().ToString('N'))
$helperRoot = Join-Path $tempRoot '插件 路径 带空格'
New-Item -ItemType Directory -Path $helperRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot 'exit-window.ps1'),
    (Join-Path $sourceRoot 'renderer.cs'),
    (Join-Path $sourceRoot 'deepseek-logo.png'),
    (Join-Path $sourceRoot 'whale-maid-static.png') -Destination $helperRoot
$helperPath = Join-Path $helperRoot 'exit-window.ps1'

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class ExitWindowTestProbe {
    private delegate bool EnumProc(IntPtr h, IntPtr state);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] private struct ProcessEntry {
        public uint dwSize, cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExeFile;
    }
    public static IntPtr FindVisibleWindow(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr state) {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)processId) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr FindVisibleWindowByTitle(string expectedTitle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr state) {
            if (!IsWindowVisible(h)) return true;
            if (Title(h) == expectedTitle) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static int OwnerProcessId(IntPtr h) {
        uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid;
    }
    public static int FindPowerShellChild(int parentPid) {
        const uint TH32CS_SNAPPROCESS = 2;
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return 0;
        try {
            ProcessEntry entry = new ProcessEntry(); entry.dwSize = (uint)Marshal.SizeOf(typeof(ProcessEntry));
            if (!Process32First(snapshot, ref entry)) return 0;
            do {
                if (entry.th32ParentProcessID == (uint)parentPid && entry.szExeFile.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase)) return (int)entry.th32ProcessID;
            } while (Process32Next(snapshot, ref entry));
            return 0;
        } finally { CloseHandle(snapshot); }
    }
    public static string Title(IntPtr h) {
        StringBuilder text = new StringBuilder(256); GetWindowText(h, text, text.Capacity); return text.ToString();
    }
    public static string Dimensions(IntPtr h) {
        Rect wr, cr; GetWindowRect(h, out wr); GetClientRect(h, out cr);
        return String.Format("window={0}x{1}, client={2}x{3}", wr.Right-wr.Left, wr.Bottom-wr.Top, cr.Right-cr.Left, cr.Bottom-cr.Top);
    }
    public static void Capture(IntPtr h, string path) {
        Rect rect; if (!GetWindowRect(h, out rect)) throw new InvalidOperationException("GetWindowRect failed.");
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width < 700 || height < 300) throw new InvalidOperationException("Unexpectedly small DPI-aware window bounds: " + Dimensions(h));
        using (Bitmap bitmap = new Bitmap(width, height))
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            IntPtr dc = graphics.GetHdc();
            try { if (!PrintWindow(h, dc, 2)) throw new InvalidOperationException("PrintWindow failed for " + Dimensions(h)); }
            finally { graphics.ReleaseHdc(dc); }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
"@ -ReferencedAssemblies @('System.Drawing.dll')
[void][ExitWindowTestProbe]::SetProcessDPIAware()

function Start-TestParent {
    param([int]$Seconds = 30)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = '-NoProfile -Command "Start-Sleep -Seconds ' + $Seconds + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($info)
}

function Start-ExitHelper {
    param(
        [System.Diagnostics.Process]$Parent,
        [int]$MaxLifetimeSeconds = 30
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $helperPath + '" -ParentPid ' + $Parent.Id + ' -MaxLifetimeSeconds ' + $MaxLifetimeSeconds
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($info)
}

function Read-LineWithTimeout {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 10000)
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) {
        throw 'Timed out waiting for helper stdout.'
    }
    return $task.GetAwaiter().GetResult()
}

function Wait-HelperExit {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 10000, [switch]$AllowNonZero)
    if (-not $Process.WaitForExit($TimeoutMs)) { throw "Exit helper $($Process.Id) did not exit within ${TimeoutMs}ms." }
    $Process.Refresh()
    $exitCode = $Process.ExitCode
    if (-not $AllowNonZero -and $null -ne $exitCode -and $exitCode -ne 0) { throw "Exit helper exited with code $exitCode." }
}

function Wait-VisibleWindow {
    param([System.Diagnostics.Process]$Process)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Exit helper $($Process.Id) quit before displaying its window." }
        $hwnd = [ExitWindowTestProbe]::FindVisibleWindow($Process.Id)
        if ($hwnd -ne [IntPtr]::Zero) { return $hwnd }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 10)
    throw 'Exit helper did not create a visible window.'
}

function Wait-WindowTitle {
    param([int]$ProcessId, [string]$ExpectedTitle, [int]$TimeoutMs = 3000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $hwnd = [ExitWindowTestProbe]::FindVisibleWindow($ProcessId)
        if ($hwnd -ne [IntPtr]::Zero -and [ExitWindowTestProbe]::Title($hwnd) -eq $ExpectedTitle) { return $hwnd }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMs)
    throw "Window title did not reach '$ExpectedTitle'."
}

function Find-BootstrapHelper {
    param([int]$BootstrapPid, [int]$TimeoutMs = 10000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $processId = [ExitWindowTestProbe]::FindPowerShellChild($BootstrapPid)
        if ($processId -gt 0) { return [System.Diagnostics.Process]::GetProcessById($processId) }
        Start-Sleep -Milliseconds 100
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMs)
    throw "Could not find a visible PowerShell helper window for bootstrap $BootstrapPid."
}

$owned = New-Object System.Collections.ArrayList
try {
    # COMMIT flow: a live parent keeps the card open; actual parent exit changes
    # it to the success state and closes it after its short display interval.
    $parent = Start-TestParent
    [void]$owned.Add($parent)
    $helper = Start-ExitHelper -Parent $parent
    [void]$owned.Add($helper)
    if ((Read-LineWithTimeout $helper) -cne 'READY') { throw 'Expected READY as the first protocol line.' }
    $hwnd = Wait-VisibleWindow $helper
    if ([ExitWindowTestProbe]::Title($hwnd) -ne 'DeepSeek Harness') { throw 'The visible window title did not match.' }
    Write-Output ("Live helper window " + [ExitWindowTestProbe]::Dimensions($hwnd))
    if (-not $SkipScreenshot) {
        $artifactDir = Join-Path $PSScriptRoot 'artifacts'
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        [ExitWindowTestProbe]::Capture($hwnd, (Join-Path $artifactDir 'exit-window.png'))
    }
    $helper.StandardInput.WriteLine('COMMIT')
    $helper.StandardInput.Flush()
    if ((Read-LineWithTimeout $helper) -cne 'COMMITTED') { throw 'Expected COMMITTED after COMMIT.' }
    # Node may release every pipe after the commit acknowledgment. The helper
    # must remain independent and continue watching its retained process handle.
    $helper.StandardInput.Close()
    $helper.StandardOutput.Close()
    $helper.StandardError.Close()
    Start-Sleep -Milliseconds 1200
    $helper.Refresh(); $parent.Refresh()
    if ($helper.HasExited) { throw 'The helper closed while the test parent was still running.' }
    if ($parent.HasExited) { throw 'The test parent unexpectedly exited before the helper.' }
    $exitTimer = [Diagnostics.Stopwatch]::StartNew()
    $parent.Kill()
    $completeHwnd = Wait-WindowTitle -ProcessId $helper.Id -ExpectedTitle '已退出'
    if (-not $SkipScreenshot) {
        [ExitWindowTestProbe]::Capture($completeHwnd, (Join-Path $artifactDir 'exit-window-complete.png'))
    }
    Wait-HelperExit $helper
    if ($exitTimer.ElapsedMilliseconds -lt 750) { throw 'The success state was not left visible for approximately one second.' }
    $parent.Dispose(); $helper.Dispose()

    # EOF before COMMIT aborts silently and never acknowledges a commit.
    $parent = Start-TestParent
    [void]$owned.Add($parent)
    $helper = Start-ExitHelper -Parent $parent
    [void]$owned.Add($helper)
    if ((Read-LineWithTimeout $helper) -cne 'READY') { throw 'Expected READY before the EOF test.' }
    [void](Wait-VisibleWindow $helper)
    $helper.StandardInput.Close()
    Wait-HelperExit $helper
    $remaining = $helper.StandardOutput.ReadToEnd()
    if ($remaining -match 'COMMITTED') { throw 'The helper acknowledged COMMIT after stdin EOF.' }
    $parent.Kill(); $parent.Dispose(); $helper.Dispose()

    # Parent exit before COMMIT also closes silently after the UI is ready.
    $parent = Start-TestParent
    [void]$owned.Add($parent)
    $helper = Start-ExitHelper -Parent $parent
    [void]$owned.Add($helper)
    if ((Read-LineWithTimeout $helper) -cne 'READY') { throw 'Expected READY before pre-COMMIT parent-exit test.' }
    [void](Wait-VisibleWindow $helper)
    $parent.Kill()
    Wait-HelperExit $helper
    if ($helper.StandardOutput.ReadToEnd() -match 'COMMITTED') { throw 'The helper acknowledged COMMIT after the parent exited.' }
    $parent.Dispose(); $helper.Dispose()

    # Test the production lifetime cap with a shorter test-only value.
    $parent = Start-TestParent
    [void]$owned.Add($parent)
    $helper = Start-ExitHelper -Parent $parent -MaxLifetimeSeconds 3
    [void]$owned.Add($helper)
    if ((Read-LineWithTimeout $helper) -cne 'READY') { throw 'Expected READY before max-lifetime test.' }
    $maxLifetimeHwnd = Wait-VisibleWindow $helper
    $helper.StandardInput.WriteLine('COMMIT')
    $helper.StandardInput.Flush()
    if ((Read-LineWithTimeout $helper) -cne 'COMMITTED') { throw 'Expected COMMITTED before max-lifetime wait.' }
    $lifetime = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 1200
    $helper.Refresh()
    if ($helper.HasExited) { throw 'The max-lifetime helper closed before its configured cap.' }
    if ([ExitWindowTestProbe]::Title($maxLifetimeHwnd) -eq '已退出') { throw 'The max-lifetime cap must not report a successful exit.' }
    Wait-HelperExit $helper -TimeoutMs 8000
    if ($lifetime.Elapsed.TotalSeconds -lt 2.5 -or $lifetime.Elapsed.TotalSeconds -gt 7) {
        throw "The shortened max lifetime was not respected ($([int]$lifetime.Elapsed.TotalMilliseconds)ms)."
    }
    $parent.Refresh()
    if ($parent.HasExited) { throw 'The max-lifetime case must not terminate its parent.' }
    $parent.Kill(); $parent.Dispose(); $helper.Dispose()

    # The parentless preview shows the same closing state and then a completion
    # state, without creating a workspace, state file, browser, or dsh process.
    $previewInfo = New-Object System.Diagnostics.ProcessStartInfo
    $previewInfo.FileName = $powershell
    $previewInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $helperPath + '" -Preview -PreviewSeconds 1'
    $previewInfo.UseShellExecute = $false
    $previewInfo.CreateNoWindow = $true
    $previewInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $previewInfo.RedirectStandardOutput = $true
    $previewInfo.RedirectStandardError = $true
    $preview = [System.Diagnostics.Process]::Start($previewInfo)
    [void]$owned.Add($preview)
    [void](Wait-VisibleWindow $preview)
    $previewHwnd = Wait-WindowTitle -ProcessId $preview.Id -ExpectedTitle '已退出' -TimeoutMs 5000
    if (-not $SkipScreenshot) {
        [ExitWindowTestProbe]::Capture($previewHwnd, (Join-Path $artifactDir 'exit-window-complete.png'))
    }
    Wait-HelperExit $preview -TimeoutMs 8000
    if ($preview.StandardOutput.ReadToEnd() -ne '') { throw 'Preview wrote protocol data to stdout.' }

    # Exercise the real Node adapter and detached bootstrap. The bootstrap
    # keeps PowerShell alive after this Node controller releases all three pipes.
    $nodeCommand = Get-Command node.exe -ErrorAction Stop
    $nodeScript = Join-Path $tempRoot 'Node exit-window adapter controller.mjs'
    $nodeSource = @'
import { spawn as nativeSpawn } from "node:child_process";
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const mode = process.argv[3] || "complete";
const { createExitWindow } = await import(pathToFileURL(modulePath).href);
let session;
session = createExitWindow({
  onReady() {
    process.stdout.write("NODE_READY\n");
    if (mode === "cancel") {
      process.stdin.resume();
      process.stdin.once("data", () => { session.cancel(); process.stdout.write("NODE_CANCELLED\n"); process.exit(0); });
    } else session.commit();
  },
  onCommitted() {
    process.stdout.write("NODE_COMMITTED\n");
    process.stdin.resume();
    process.stdin.once("data", () => process.exit(0));
  },
  onFailure(reason) { process.stdout.write("NODE_FAILURE=" + String(reason) + "\n"); process.stderr.write(String(reason) + "\n"); process.exit(1); }
}, {
  spawn(...args) {
    const child = nativeSpawn(...args);
      process.stdout.write("BOOTSTRAP_PID=" + child.pid + "\n");
    child.stderr.on("data", data => process.stdout.write("HELPER_STDERR=" + data.toString().replace(/\n/g, "\\n") + "\n"));
    return child;
  }
});
'@
    [IO.File]::WriteAllText($nodeScript, $nodeSource, (New-Object System.Text.UTF8Encoding($false)))
    $nodeInfo = New-Object System.Diagnostics.ProcessStartInfo
    $nodeInfo.FileName = $nodeCommand.Source
    $nodeInfo.Arguments = '"' + $nodeScript + '" "' + (Join-Path $sourceRoot '..\exit-window.js') + '" complete'
    $nodeInfo.UseShellExecute = $false
    $nodeInfo.CreateNoWindow = $true
    $nodeInfo.RedirectStandardInput = $true
    $nodeInfo.RedirectStandardOutput = $true
    $nodeInfo.RedirectStandardError = $true
    $node = [System.Diagnostics.Process]::Start($nodeInfo)
    [void]$owned.Add($node)
    $bootstrapPidLine = Read-LineWithTimeout $node
    if ($bootstrapPidLine -notmatch '^BOOTSTRAP_PID=(\d+)$') { throw "Node adapter did not report the bootstrap PID: $bootstrapPidLine" }
    $bootstrapPid = [int]$Matches[1]
    $bootstrap = [System.Diagnostics.Process]::GetProcessById($bootstrapPid)
    [void]$owned.Add($bootstrap)
    $nodeHelper = Find-BootstrapHelper -BootstrapPid $bootstrapPid
    [void]$owned.Add($nodeHelper)
    $node.Refresh()
    if ($node.HasExited) { throw ("Node adapter exited before handoff. stderr=" + $node.StandardError.ReadToEnd()) }
    $nodeReadyLine = Read-LineWithTimeout $node
    if ($nodeReadyLine -match '^NODE_FAILURE=') { throw "Node adapter failed before READY: $nodeReadyLine" }
    if ($nodeReadyLine -cne 'NODE_READY') { throw "Expected NODE_READY, received: $nodeReadyLine" }
    $nodeCommitLine = Read-LineWithTimeout $node
    if ($nodeCommitLine -match '^NODE_FAILURE=') { throw "Node adapter failed before COMMITTED: $nodeCommitLine" }
    if ($nodeCommitLine -cne 'NODE_COMMITTED') { throw "Expected NODE_COMMITTED, received: $nodeCommitLine" }
    try { $nodeHelperHwnd = Wait-VisibleWindow $nodeHelper }
    catch {
        $node.Refresh()
        if (-not $node.HasExited) { $node.Kill(); [void]$node.WaitForExit(3000) }
        throw ("Node adapter helper did not display: " + $_.Exception.Message + " Node stderr: " + $node.StandardError.ReadToEnd() + " Node stdout: " + $node.StandardOutput.ReadToEnd())
    }
    $node.Refresh(); $nodeHelper.Refresh()
    if ($node.HasExited -or $nodeHelper.HasExited) { throw 'Node adapter or detached helper exited before handoff.' }
    $node.StandardInput.WriteLine('EXIT')
    $node.StandardInput.Flush()
    Wait-HelperExit $node -TimeoutMs 5000
    $nodeHelper.Refresh(); $bootstrap.Refresh()
    if ($nodeHelper.HasExited -or $bootstrap.HasExited) { throw 'Bootstrap or PowerShell helper did not survive the Node controller exit.' }
    $nodeCompleteHwnd = Wait-WindowTitle -ProcessId $nodeHelper.Id -ExpectedTitle '已退出'
    if (-not $SkipScreenshot) {
        [ExitWindowTestProbe]::Capture($nodeCompleteHwnd, (Join-Path $artifactDir 'exit-window-node-complete.png'))
    }
    Wait-HelperExit $nodeHelper -TimeoutMs 8000
    Wait-HelperExit $bootstrap -TimeoutMs 8000
    $node.Dispose(); $nodeHelper.Dispose(); $bootstrap.Dispose()

    # Cancellation before COMMIT must tear down the detached bootstrap and its
    # PowerShell child; the canceled card must not linger or report completion.
    $cancelInfo = New-Object System.Diagnostics.ProcessStartInfo
    $cancelInfo.FileName = $nodeCommand.Source
    $cancelInfo.Arguments = '"' + $nodeScript + '" "' + (Join-Path $sourceRoot '..\exit-window.js') + '" cancel'
    $cancelInfo.UseShellExecute = $false
    $cancelInfo.CreateNoWindow = $true
    $cancelInfo.RedirectStandardInput = $true
    $cancelInfo.RedirectStandardOutput = $true
    $cancelInfo.RedirectStandardError = $true
    $cancelNode = [System.Diagnostics.Process]::Start($cancelInfo)
    [void]$owned.Add($cancelNode)
    $cancelBootstrapLine = Read-LineWithTimeout $cancelNode
    if ($cancelBootstrapLine -notmatch '^BOOTSTRAP_PID=(\d+)$') { throw "Node cancel adapter did not report the bootstrap PID: $cancelBootstrapLine" }
    $cancelBootstrapPid = [int]$Matches[1]
    $cancelBootstrap = [System.Diagnostics.Process]::GetProcessById($cancelBootstrapPid)
    [void]$owned.Add($cancelBootstrap)
    $cancelHelper = Find-BootstrapHelper -BootstrapPid $cancelBootstrapPid
    [void]$owned.Add($cancelHelper)
    if ((Read-LineWithTimeout $cancelNode) -cne 'NODE_READY') { throw 'Expected NODE_READY before cancel.' }
    [void](Wait-VisibleWindow $cancelHelper)
    $cancelNode.StandardInput.WriteLine('CANCEL')
    $cancelNode.StandardInput.Flush()
    if ((Read-LineWithTimeout $cancelNode) -cne 'NODE_CANCELLED') { throw 'Expected NODE_CANCELLED from the Node adapter.' }
    Wait-HelperExit $cancelNode -TimeoutMs 5000
    Wait-HelperExit $cancelBootstrap -TimeoutMs 8000 -AllowNonZero
    Wait-HelperExit $cancelHelper -TimeoutMs 8000 -AllowNonZero
    if ([ExitWindowTestProbe]::FindVisibleWindow($cancelHelper.Id) -ne [IntPtr]::Zero) { throw 'The canceled helper window remained visible.' }
    $cancelNode.Dispose(); $cancelBootstrap.Dispose(); $cancelHelper.Dispose()

    Write-Output "PASS: direct and Node/bootstrap ready/commit handoff, pipe release after COMMITTED, parent-still-running behavior, successful parent exit, pre-COMMIT EOF and parent exit, cancellation subtree cleanup, short max lifetime, Preview completion, and Chinese/space-containing helper path."
    if (-not $SkipScreenshot) {
        $screenshotPath = Join-Path $PSScriptRoot "artifacts\exit-window.png"
        Write-Output ("Screenshot: " + $screenshotPath)
    }
} finally {
    foreach ($process in $owned) {
        try { $process.Refresh(); if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(3000) } } catch { }
        try { $process.Dispose() } catch { }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        $tempFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).Path).TrimEnd('\')
        $tempBase = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path).TrimEnd('\')
        if ($tempFull.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tempFull -Recurse -Force
        } else { throw "Refusing to remove path outside TEMP: $tempFull" }
    }
}
