import test from "node:test";
import assert from "node:assert/strict";
import { createWatchdog, resolveConfig, FALLBACK_EXIT_MS } from "../lib/watchdog.js";

function fixture(config = {}, extra = {}) {
	const clients = new Map();
	const windows = [];
	const timers = [];
	let tick, dispose, time = 0, exits = 0, forced = 0, cleared = false;
	const ctx = {
		get: (key) => key === "typertGateway" ? { remoteEventClients: clients } : () => {
			exits++;
			if (extra.throwExit) throw new Error("disposal failure");
			if (extra.rejectExit) return Promise.reject(new Error("disposal failure"));
			if (extra.disposeOnExit) dispose();
		},
		effect: (factory) => { dispose = factory(); },
	};
	createWatchdog(ctx, config, {
		platform: extra.platform ?? "win32", now: () => time, log() {},
		setInterval(fn) { tick = fn; return { unref() {} }; },
		clearInterval() { cleared = true; },
		setTimeout(fn, ms) { const timer = { fn, ms, unref() { this.unreferenced = true; } }; timers.push(timer); return timer; },
		forceExit() { forced++; },
		openWindow(callbacks) {
			const window = { callbacks, commits: 0, cancels: 0, commit() { this.commits++; }, cancel() { this.cancels++; } };
			windows.push(window);
			return window;
		},
	});
	return {
		clients, windows, timers,
		poll(at = time) { time = at; tick?.(); },
		arm() { clients.set("one", {}); tick(); clients.clear(); tick(); },
		dispose() { dispose?.(); },
		get exits() { return exits; }, get forced() { return forced; }, get cleared() { return cleared; },
	};
}

test("configuration preserves bounds and boolean spellings, including the new switch", () => {
	assert.equal(resolveConfig().showExitWindow, true);
	for (const value of [false, 0, "", "false", "0", null]) {
		assert.equal(resolveConfig({ showExitWindow: value }).showExitWindow, false);
	}
	assert.equal(resolveConfig({ pollMs: 1 }).pollMs, 100);
	assert.equal(resolveConfig({ disconnectGraceMs: Infinity }).disconnectGraceMs, 5000);
	assert.equal(resolveConfig({ disconnectGraceMs: -1 }).disconnectGraceMs, 0);
});

test("never connected stays alive; multiple clients must all disconnect", () => {
	const f = fixture();
	f.poll(100000);
	assert.equal(f.windows.length, 0);
	f.clients.set("one", {}); f.clients.set("two", {}); f.poll();
	f.clients.delete("one"); f.poll(200000);
	assert.equal(f.windows.length, 0);
	f.clients.clear(); f.poll(201000); f.poll(205999);
	assert.equal(f.windows.length, 0);
	f.poll(206000);
	assert.equal(f.windows.length, 1);
	assert.equal(f.exits, 0);
});

test("refresh resets the entire grace period, even when the clock starts at zero", () => {
	const f = fixture(); f.arm(); f.poll(4000);
	f.clients.set("one", {}); f.poll(4500); f.clients.clear(); f.poll(5000);
	f.poll(9999); assert.equal(f.windows.length, 0);
	f.poll(10000); assert.equal(f.windows.length, 1);
});

test("READY commits once; only COMMITTED invokes appExit and fallback survives disposal", () => {
	const f = fixture({ disconnectGraceMs: 0 }, { disposeOnExit: true }); f.arm();
	const w = f.windows[0]; f.poll(); w.callbacks.onReady(); f.poll();
	assert.equal(w.commits, 1); assert.equal(f.exits, 0);
	w.callbacks.onCommitted(); w.callbacks.onCommitted();
	assert.equal(f.exits, 1); assert.equal(w.cancels, 0); assert.equal(f.cleared, true);
	assert.equal(f.timers[0].ms, FALLBACK_EXIT_MS); assert.equal(f.timers[0].unreferenced, true);
	f.timers[0].fn(); assert.equal(f.forced, 1);
});

test("reconnect during preparation cancels, resets grace, and rejects stale callbacks", () => {
	const f = fixture(); f.arm(); f.poll(5000); const old = f.windows[0];
	f.clients.set("one", {}); f.poll(5100); assert.equal(old.cancels, 1);
	f.clients.clear(); f.poll(6000); f.poll(11000);
	const current = f.windows[1];
	old.callbacks.onReady(); old.callbacks.onFailure("late"); old.callbacks.onCommitted();
	assert.equal(current.commits, 0); assert.equal(f.exits, 0);
	current.callbacks.onReady(); current.callbacks.onCommitted(); assert.equal(f.exits, 1);
});

test("READY rechecks connections between polls; COMMIT locks shutdown", () => {
	const f = fixture({ disconnectGraceMs: 0 }); f.arm();
	f.clients.set("one", {}); f.windows[0].callbacks.onReady();
	assert.equal(f.windows[0].cancels, 1); assert.equal(f.exits, 0);
	f.poll(); f.clients.clear(); f.poll(); const w = f.windows[1]; w.callbacks.onReady();
	f.clients.set("one", {}); f.poll(); w.callbacks.onCommitted(); assert.equal(f.exits, 1);
});

test("window failure continues shutdown, but reconnect before commit keeps service alive", () => {
	const f = fixture({ disconnectGraceMs: 0 }); f.arm();
	f.windows[0].callbacks.onFailure("spawn"); assert.equal(f.exits, 1);
	const g = fixture({ disconnectGraceMs: 0 }); g.arm(); g.clients.set("one", {});
	g.windows[0].callbacks.onFailure("timeout"); assert.equal(g.exits, 0);
});

test("external disposal in either preparation phase prevents deferred appExit", () => {
	for (const commit of [false, true]) {
		const f = fixture({ disconnectGraceMs: 0 }); f.arm(); const w = f.windows[0];
		if (commit) w.callbacks.onReady(); f.dispose();
		w.callbacks.onReady(); w.callbacks.onCommitted(); w.callbacks.onFailure("late");
		assert.equal(f.exits, 0); assert.equal(w.cancels, 1); assert.equal(f.cleared, true);
	}
});

test("handoff failure after COMMIT still exits even if a page reconnects", () => {
	const f = fixture({ disconnectGraceMs: 0 }); f.arm(); const w = f.windows[0];
	w.callbacks.onReady(); f.clients.set("one", {});
	w.callbacks.onFailure("handoff timeout"); w.callbacks.onCommitted();
	assert.equal(f.exits, 1); assert.equal(f.timers.length, 1);
});

test("disabled window/non-Windows keep the original no-window behavior", () => {
	for (const [cfg, extra] of [[{ showExitWindow: false }, {}], [{}, { platform: "linux" }]]) {
		const f = fixture({ ...cfg, requireEverConnected: false, disconnectGraceMs: 0 }, extra);
		f.poll(); assert.equal(f.exits, 1); assert.equal(f.windows.length, 0);
	}
	const f = fixture({ enabled: false }); f.poll(); assert.equal(f.exits, 0);
});

test("synchronous and asynchronous appExit failure retain forced exit", async () => {
	for (const extra of [{ throwExit: true }, { rejectExit: true }]) {
		const f = fixture({ showExitWindow: false, disconnectGraceMs: 0 }, extra); f.arm();
		await Promise.resolve(); f.timers[0].fn(); assert.equal(f.forced, 1);
	}
});
