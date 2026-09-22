/**
* dsh-auto-shutdown — shut the DSH instance down as soon as the web UI
* disconnects (zero grace by default). Zero-dependency host plugin: no
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
* Shutdown channel: the launcher provides ctx.appExit (bounded graceful
* process exit; 5s force-exit fallback inside the launcher). Calling it with 0
* disposes the whole tree and exits the DSH process.
* @module dsh-auto-shutdown
*/

/** Stable Cordis plugin name (matches the patch row id). */
const name = "auto-shutdown";

/**
* Normalize raw row config with defaults and hard bounds. Kept dependency-free
* on purpose (no schemastery import), so the module loads from any location.
* @param input - raw config object from the patch row (or undefined).
*/
function resolveConfig(input = {}) {
	const num = (value, fallback, min, max) => {
		if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
		return Math.min(max, Math.max(min, Math.trunc(value)));
	};
	return {
		enabled: input.enabled !== false,
		pollMs: num(input.pollMs, 1000, 100, 60000),
		disconnectGraceMs: num(input.disconnectGraceMs, 0, 0, 86400000),
		requireEverConnected: input.requireEverConnected !== false
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
				exiting = true;
				exit(0);
				return;
			}
			log("web UI disconnected; scheduling exit in " + resolved.disconnectGraceMs + "ms");
		}
		if (now - goneSince >= resolved.disconnectGraceMs) {
			log("no web UI connection for " + (now - goneSince) + "ms; shutting down the DSH instance");
			exiting = true;
			exit(0);
		}
	};

	const timer = setInterval(poll, resolved.pollMs);
	timer.unref?.();
	ctx.effect(() => () => {
		clearInterval(timer);
	});
}

export { apply, name };
