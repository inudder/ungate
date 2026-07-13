import { appendFileSync } from 'node:fs';
import { homedir } from 'node:os';

import { startServer } from './server';

function crashMessage(err: unknown): string {
	if (err instanceof Error) {
		return err.stack ?? err.message;
	}

	return String(err);
}

function writeCrashLog(message: string): void {
	appendFileSync(
		`${homedir()}/.ungate/extension.log`,
		JSON.stringify({ source: 'api', entry: { timestamp: Date.now(), level: 'error', message } }) + '\n'
	);
}

// Guard against EPIPE crash-loop: when the extension host closes the stderr pipe,
// console.error throws EPIPE, which triggers uncaughtException, which tries to
// console.error again → infinite loop. Exit silently on EPIPE instead.
process.on('uncaughtException', (err: NodeJS.ErrnoException) => {
	if (err.code === 'EPIPE' || err.syscall === 'write') {
		process.exit(1);
	}
	// For other errors, write to file (console may also be broken)
	try {
		writeCrashLog(`[CRASH] ${crashMessage(err)}`);
	} catch {
		// nothing we can do
	}
	process.exit(1);
});

startServer().catch((err: unknown) => {
	try {
		console.error('API failed to start:', err);
	} catch {
		// console broken, write to file
		writeCrashLog(`[START_CRASH] ${crashMessage(err)}`);
	}
	process.exit(1);
});
