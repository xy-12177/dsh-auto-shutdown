import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import { createExitWindow, READY_TIMEOUT_MS, COMMIT_TIMEOUT_MS } from "../lib/exit-window.js";

function fixture({ throwSpawn = false, writeError = false } = {}) {
	const child = new EventEmitter();
	child.stdout = new PassThrough(); child.stderr = new PassThrough();
	const writes = [];
	child.stdin = new Writable({ write(chunk, encoding, done) {
		writes.push(chunk.toString()); done(writeError ? new Error("pipe broken") : undefined);
	} });
	child.exitCode = null; child.kills = 0; child.unrefs = 0;
	child.kill = () => { child.kills++; return true; };
	child.unref = () => { child.unrefs++; };
	const timers = [], failures = [];
	let ready = 0, committed = 0, args;
	const session = createExitWindow({
		onReady() { ready++; }, onCommitted() { committed++; }, onFailure(reason) { failures.push(reason); },
	}, {
		spawn(...input) { args = input; if (throwSpawn) throw new Error("not found"); return child; },
		setTimeout(fn, ms) { const timer = { fn, ms }; timers.push(timer); return timer; },
		clearTimeout(timer) { if (timer) timer.cleared = true; },
	});
	return { session, child, timers, failures, writes, get ready() { return ready; }, get committed() { return committed; }, get args() { return args; } };
}

test("spawn detaches a hidden Node supervisor with the bundled script and original PID", () => {
	const f = fixture();
	assert.equal(f.args[0], process.execPath);
	assert.equal(f.args[1][1], String(process.pid));
	assert.match(f.args[1][0], /lib[\\/]windows[\\/]bootstrap.js$/);
	assert.deepEqual(f.args[2], { windowsHide: true, detached: true, stdio: ["pipe", "pipe", "pipe"], shell: false });
	f.session.cancel();
});

test("fragmented CRLF protocol waits for COMMITTED before detaching pipes", () => {
	const f = fixture(); f.child.stdout.write("REA"); assert.equal(f.ready, 0);
	f.child.stdout.write("DY\r\n"); assert.equal(f.ready, 1); assert.equal(f.committed, 0);
	assert.equal(f.timers[0].cleared, true); f.session.commit();
	assert.deepEqual(f.writes, ["COMMIT\n"]); assert.equal(f.timers[1].ms, COMMIT_TIMEOUT_MS);
	f.child.stdout.write("COMMITTED\n");
	assert.equal(f.committed, 1); assert.equal(f.child.unrefs, 1); assert.equal(f.child.kills, 0);
	assert.equal(f.child.stdin.destroyed, true); assert.equal(f.child.stdout.destroyed, true);
	f.session.cancel(); f.child.emit("error", new Error("late")); f.child.emit("exit", 0);
	assert.equal(f.child.kills, 0); assert.deepEqual(f.failures, []);
});

test("readiness timeout and handoff timeout kill only this child and fail once", () => {
	for (const committing of [false, true]) {
		const f = fixture(); assert.equal(f.timers[0].ms, READY_TIMEOUT_MS);
		if (committing) { f.child.stdout.write("READY\n"); f.session.commit(); }
		f.timers.at(-1).fn(); f.child.emit("exit", 1); f.child.emit("error", new Error("late"));
		assert.equal(f.child.kills, 1); assert.equal(f.failures.length, 1);
		assert.equal(f.child.stdin.destroyed, true);
	}
});

test("spawn throw reports failure asynchronously, allowing cancellation", async () => {
	const f = fixture({ throwSpawn: true }); assert.deepEqual(f.failures, []);
	await Promise.resolve(); assert.equal(f.failures.length, 1);
	const g = fixture({ throwSpawn: true }); g.session.cancel(); await Promise.resolve();
	assert.deepEqual(g.failures, []);
});

test("unexpected, oversized, duplicate and early messages abort the handshake", () => {
	for (const messages of [["COMMITTED\n"], ["x".repeat(1025)], ["READY\n", "READY\n"], ["noise\n"]]) {
		const f = fixture(); for (const message of messages) f.child.stdout.write(message);
		assert.equal(f.failures.length, 1); assert.equal(f.child.kills, 1);
	}
});

test("EOF, early exit and stream errors fail promptly", () => {
	for (const trigger of [
		(f) => f.child.stdout.emit("end"), (f) => f.child.emit("exit", 1),
		(f) => f.child.emit("error", new Error("spawn")),
		(f) => f.child.stdin.emit("error", new Error("input")),
		(f) => f.child.stdout.emit("error", new Error("output")),
		(f) => f.child.stderr.emit("error", new Error("diagnostic")),
	]) { const f = fixture(); trigger(f); assert.equal(f.failures.length, 1); }
});

test("write failure aborts without an unhandled stream error", async () => {
	const f = fixture({ writeError: true }); f.child.stdout.write("READY\n"); f.session.commit();
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(f.failures.length, 1); assert.equal(f.child.kills, 1);
});

test("cancel closes pipes and suppresses all late callbacks", () => {
	const f = fixture(); f.session.cancel(); f.session.cancel();
	f.timers[0].fn(); f.child.emit("error", new Error("late"));
	assert.equal(f.child.kills, 1); assert.deepEqual(f.failures, []);
});
