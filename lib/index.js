import { createWatchdog } from "./watchdog.js";

const name = "auto-shutdown";

function apply(ctx, config = {}) {
	createWatchdog(ctx, config);
}

export { apply, name };
