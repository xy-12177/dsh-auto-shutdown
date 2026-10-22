// Windows PowerShell 5.1 cannot start under DETACHED_PROCESS. A detached Node
// supervisor owns its normal PowerShell child until the exit card finishes.
// Inherited stdio connects the original DSH directly to the PowerShell helper;
// the supervisor never reads or writes protocol messages.
import { spawn } from "node:child_process";
import { win32 } from "node:path";
import { fileURLToPath } from "node:url";

const parentPid = process.argv[2];
if (!/^[1-9]\d*$/.test(parentPid ?? "")) process.exit(1);
const systemRoot = process.env.SystemRoot || process.env.WINDIR || "C:\\Windows";
const helper = spawn(win32.join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), [
	"-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
	"-WindowStyle", "Hidden", "-File", fileURLToPath(new URL("./exit-window.ps1", import.meta.url)),
	"-ParentPid", parentPid,
], { windowsHide: true, detached: false, stdio: "inherit", shell: false });

// The host bounds preparation; this independent limit also covers a hung
// window or helper after handoff. Never terminate the original DSH here.
const deadline = setTimeout(() => {
	try { helper.kill(); } finally { process.exit(1); }
}, 40000);
helper.once("error", () => { clearTimeout(deadline); process.exitCode = 1; });
helper.once("exit", (code) => { clearTimeout(deadline); process.exitCode = code ?? 1; });
