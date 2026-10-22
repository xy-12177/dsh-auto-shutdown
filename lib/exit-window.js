import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export const READY_TIMEOUT_MS = 5000;
export const COMMIT_TIMEOUT_MS = 1000;

export function createExitWindow(callbacks, runtime = {}) {
	const launch = runtime.spawn ?? spawn;
	const timeout = runtime.setTimeout ?? globalThis.setTimeout;
	const clear = runtime.clearTimeout ?? globalThis.clearTimeout;
	let child;
	let timer;
	let state = "starting";
	let buffer = "";
	const closePipes = () => {
		child?.stdin?.destroy();
		child?.stdout?.destroy();
		child?.stderr?.destroy();
	};
	const abort = () => {
		clear(timer);
		closePipes();
		// Only this exact ChildProcess is terminated, never a PID/port lookup.
		try { if (child && child.exitCode === null) child.kill(); } catch { /* Still shut down DSH. */ }
	};
	const fail = (reason) => {
		if (state === "done" || state === "cancelled") return;
		state = "done";
		abort();
		callbacks.onFailure(reason);
	};
	try {
		child = launch(process.execPath, [
			fileURLToPath(new URL("./windows/bootstrap.js", import.meta.url)), String(process.pid),
		], {
			windowsHide: true,
			// Detach Node, which can own a working non-detached PowerShell child.
			detached: true, stdio: ["pipe", "pipe", "pipe"], shell: false,
		});
		child.on("error", () => fail("process error"));
		child.on("exit", () => fail("helper exited before handoff"));
		child.stdin.on("error", () => fail("input pipe error"));
		child.stdout.on("error", () => fail("output pipe error"));
		child.stderr.on("error", () => fail("diagnostic pipe error"));
		child.stderr.resume();
		child.stdout.setEncoding("utf8");
		child.stdout.on("end", () => fail("protocol pipe ended"));
		child.stdout.on("data", (data) => {
			if (state === "done" || state === "cancelled") return;
			buffer += data;
			if (buffer.length > 1024) return fail("oversized protocol message");
			let newline;
			while ((newline = buffer.indexOf("\n")) !== -1) {
				const line = buffer.slice(0, newline).replace(/\r$/, "");
				buffer = buffer.slice(newline + 1);
				if (state === "starting" && line === "READY") {
					clear(timer);
					state = "ready";
					callbacks.onReady();
				} else if (state === "committing" && line === "COMMITTED") {
					state = "done";
					clear(timer);
					closePipes();
					child.unref();
					callbacks.onCommitted();
					return;
				} else return fail("unexpected protocol message");
			}
		});
		timer = timeout(() => fail("window readiness timeout"), READY_TIMEOUT_MS);
	} catch {
		// The caller must first have a chance to store the returned session.
		queueMicrotask(() => fail("could not launch helper"));
	}
	return {
		commit() {
			if (state !== "ready") return;
			state = "committing";
			timer = timeout(() => fail("handoff timeout"), COMMIT_TIMEOUT_MS);
			try { child.stdin.write("COMMIT\n", (error) => { if (error) fail("commit write failed"); }); }
			catch { fail("commit write failed"); }
		},
		cancel() {
			if (state === "done" || state === "cancelled") return;
			state = "cancelled";
			abort();
		},
	};
}
