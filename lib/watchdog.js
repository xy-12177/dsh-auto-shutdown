import { createExitWindow } from "./exit-window.js";

// Outlast the host's 5s disposal deadline; survive successful plugin disposal.
export const FALLBACK_EXIT_MS = 8000;

export function resolveConfig(input = {}) {
	input ??= {};
	const num = (value, fallback, min, max) => typeof value === "number" && Number.isFinite(value)
		? Math.min(max, Math.max(min, Math.trunc(value))) : fallback;
	const off = (value) => [false, 0, "", "false", "0", null].includes(value);
	return {
		enabled: !off(input.enabled),
		pollMs: num(input.pollMs, 1000, 100, 60000),
		disconnectGraceMs: num(input.disconnectGraceMs, 5000, 0, 86400000),
		requireEverConnected: !off(input.requireEverConnected),
		showExitWindow: !off(input.showExitWindow),
	};
}

// Internal runtime seams let tests run without a real DSH, timers or windows.
export function createWatchdog(ctx, config, runtime = {}) {
	const cfg = resolveConfig(config);
	if (!cfg.enabled) return;
	const {
		platform = process.platform, now = Date.now,
		setInterval: interval = globalThis.setInterval, clearInterval: clear = globalThis.clearInterval,
		setTimeout: timeout = globalThis.setTimeout, forceExit = (code) => process.exit(code),
		openWindow = createExitWindow,
		log = (message) => process.stderr.write("auto-shutdown: " + message + "\n"),
	} = runtime;
	const gateway = ctx.get("typertGateway");
	const exit = ctx.get("appExit");
	if (gateway?.remoteEventClients === undefined || typeof exit !== "function") {
		log("typertGateway or appExit unavailable; watchdog disabled");
		return;
	}
	let state = "watching";
	let everConnected = false;
	let goneSince = null;
	let window = null;
	let attempt = 0;

	const shutdown = () => {
		if (state === "disposed" || state === "exiting") return;
		state = "exiting";
		const fallback = timeout(() => forceExit(0), FALLBACK_EXIT_MS);
		fallback.unref?.();
		try {
			Promise.resolve(exit(0)).catch(() => log("appExit rejected; exit fallback remains armed"));
		} catch {
			log("appExit threw; exit fallback remains armed");
		}
	};
	const cancelPreparation = () => {
		attempt++;
		state = "watching";
		const pending = window;
		window = null;
		pending?.cancel();
		goneSince = null;
	};
	const requestExit = () => {
		if (state !== "watching" || gateway.remoteEventClients.size > 0) return;
		if (!cfg.showExitWindow || platform !== "win32") {
			shutdown();
			return;
		}
		state = "preparing";
		const currentAttempt = ++attempt;
		window = openWindow({
			onReady() {
				if (currentAttempt !== attempt || state !== "preparing") return;
				if (gateway.remoteEventClients.size > 0) {
					cancelPreparation();
					return;
				}
				// COMMIT is the boundary after which reconnect cannot cancel.
				state = "committing";
				window.commit();
			},
			onCommitted() {
				if (currentAttempt !== attempt || state !== "committing") return;
				window = null;
				shutdown();
			},
			onFailure(reason) {
				if (currentAttempt !== attempt || (state !== "preparing" && state !== "committing")) return;
				window = null;
				log("exit window unavailable (" + reason + "); continuing shutdown");
				if (state === "preparing" && gateway.remoteEventClients.size > 0) {
					goneSince = null;
					state = "watching";
					return;
				}
				shutdown();
			},
		});
	};
	const poll = () => {
		if (state === "disposed" || state === "exiting" || state === "committing") return;
		if (gateway.remoteEventClients.size > 0) {
			everConnected = true;
			goneSince = null;
			if (state === "preparing") cancelPreparation();
			return;
		}
		if (state === "preparing" || (cfg.requireEverConnected && !everConnected)) return;
		goneSince ??= now();
		if (now() - goneSince >= cfg.disconnectGraceMs) {
			log("web UI disconnected; shutting down the DSH instance");
			requestExit();
		}
	};
	log("active (poll " + cfg.pollMs + "ms, grace " + cfg.disconnectGraceMs + "ms, showExitWindow=" + cfg.showExitWindow + ")");
	const timer = interval(poll, cfg.pollMs);
	timer.unref?.();
	ctx.effect(() => () => {
		attempt++;
		clear(timer);
		const pending = window;
		window = null;
		state = "disposed";
		pending?.cancel();
		// Do not clear the fallback or terminate a committed helper here.
	});
}
