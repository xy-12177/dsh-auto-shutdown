/**
* dsh-auto-shutdown — shut the DSH instance down once the web UI stays
* disconnected past a short grace period (5s by default, enough to cover a
* tab reload or a brief machine sleep). Zero-dependency host plugin: no
* imports, so it loads from any installation location (live link, copy,
* hoisted store) without peer-resolution issues.
*
* Presence signal: every browser page keeps one WebSocket mux open at
* /api/remote.mux (dsh-api-gateway) and pumps the $events logical stream for
* the whole page lifetime. The host TypertGatewayService registers one entry
* in ctx.typertGateway.remoteEventClients per live $events stream and
* removes it the moment the socket closes, so a size of 0 means no UI page is
* connected anywhere.
*
* Shutdown channel: the launcher provides ctx.appExit, which is
* createProcessShutdown().shutdown(code) under the hood (dsh/lib/profile-boot):
* it arms a 5s force-exit timer and disposes the whole tree; when dispose
* succeeds it clears that timer and only sets process.exitCode — the process
* then exits solely when the event loop drains, which nothing guarantees.
* This plugin therefore schedules its own unref()'d process.exit(0) fallback
* (FALLBACK_EXIT_MS) right after calling appExit(0), so a successfully
* disposed tree cannot linger forever.
* @module dsh-auto-shutdown
*/

/** Stable Cordis plugin name (matches the patch row id). */
const name = "auto-shutdown";

/**
* Plugin-owned last-resort process exit, in ms, after ctx.appExit(0) has been
* called. Must outlast the launcher's 5s tree-dispose grace
* (PROCESS_SHUTDOWN_TIMEOUT_MS in dsh/lib/profile-boot-*.js) so a graceful
* disposal is never preempted, while staying short enough that a successfully
* disposed tree cannot linger.
*/
const FALLBACK_EXIT_MS = 8000;

/**
* Normalize raw row config with defaults and hard bounds. Kept dependency-free
* on purpose (no schemastery import), so the module loads from any location.
* @param input - raw config object from the patch row (or undefined).
*/
function resolveConfig(input = {}) {
	input = input ?? {};
	const num = (value, fallback, min, max) => {
		if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
		return Math.min(max, Math.max(min, Math.trunc(value)));
	};
	// YAML patch rows spell "off" in several ways (false, 0, "", "false",
	// "0", or an empty null value); any of them must disarm the watchdog.
	const off = (value) => value === false || value === 0 || value === "" || value === "false" || value === "0" || value === null;
	return {
		enabled: !off(input.enabled),
		pollMs: num(input.pollMs, 1000, 100, 60000),
		disconnectGraceMs: num(input.disconnectGraceMs, 5000, 0, 86400000),
		requireEverConnected: !off(input.requireEverConnected)
	};
}

function log(message) {
	process.stderr.write("auto-shutdown: " + message + "\n");
}

function apply(ctx, config = {}) {
	const resolved = resolveConfig(config);
	if (!resolved.enabled) return;
	const gateway = ctx.get("typertGateway");
	const exit = ctx.get("appExit");
	if (gateway === void 0 || gateway.remoteEventClients === void 0) {
		log("typertGateway service (or its remoteEventClients map) is unavailable; watchdog disabled");
		return;
	}
	if (exit === void 0) {
		log("appExit is unavailable; watchdog disabled");
		return;
	}
	log("active (poll " + resolved.pollMs + "ms, grace " + resolved.disconnectGraceMs + "ms, requireEverConnected=" + resolved.requireEverConnected + ")");
	let armed = false;
	let everConnected = false;
	let goneSince = 0;
	let exiting = false;

	// appExit(0) alone does not guarantee process death (see header), so the
	// watchdog adds its own unref()'d fallback. It is deliberately NOT cleared
	// by the effect disposer below: the tree disposal triggered by appExit
	// also disposes this plugin, and the fallback is exactly what must survive
	// that disposal.
	const requestExit = () => {
		if (exiting) return;
		exiting = true;
		const fallback = setTimeout(() => {
			process.exit(0);
		}, FALLBACK_EXIT_MS);
		fallback.unref?.();
		exit(0);
	};

	const poll = () => {
		if (exiting) return;
		const clients = gateway.remoteEventClients.size;
		if (clients > 0) {
			everConnected = true;
			if (!armed) {
				armed = true;
				log("armed; " + clients + " UI client(s) connected");
			}
			goneSince = 0;
			return;
		}
		if (!armed) {
			if (resolved.requireEverConnected && !everConnected) return;
			armed = true;
			log("armed; no UI client connected");
		}
		const now = Date.now();
		if (goneSince === 0) {
			goneSince = now;
			if (resolved.disconnectGraceMs === 0) {
				log("web UI disconnected; shutting down the DSH instance");
				requestExit();
				return;
			}
			log("web UI disconnected; scheduling exit in " + resolved.disconnectGraceMs + "ms");
		}
		if (now - goneSince >= resolved.disconnectGraceMs) {
			log("no web UI connection for " + (now - goneSince) + "ms; shutting down the DSH instance");
			requestExit();
		}
	};

	const timer = setInterval(poll, resolved.pollMs);
	timer.unref?.();
	ctx.effect(() => () => {
		clearInterval(timer);
	});
}

export { apply, name };
