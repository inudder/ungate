import { spawn } from 'node:child_process';
import { writeSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const runtimeDirectory = path.dirname(fileURLToPath(import.meta.url));

// NSSM 2.24 can hang during logger cleanup when stdout and stderr share an
// online-rotated file. Merge the child's streams before they reach NSSM.
export function runRouter({
	executable = process.execPath,
	args = [path.join(runtimeDirectory, 'codex-model-shell-router-service.mjs')],
	output = process.stdout
} = {}) {
	return new Promise((resolve) => {
		const child = spawn(executable, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
		child.stdout.pipe(output, { end: false });
		child.stderr.pipe(output, { end: false });
		child.once('error', () => {
			output.write(
				`${JSON.stringify({ timestamp: new Date().toISOString(), service: 'codex-model-shell-router', event: 'supervisor_spawn_failed' })}\n`
			);
		});
		child.once('close', (code) => resolve(code === 0 ? 0 : 1));
	});
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const fatal = (event) => {
		try {
			writeSync(1, `${JSON.stringify({ timestamp: new Date().toISOString(), service: 'codex-model-shell-router', event })}\n`);
		} catch {
			/* NSSM will still observe the failing exit. */
		}
		process.exit(1);
	};
	process.on('uncaughtException', () => fatal('supervisor_uncaught_exception'));
	process.on('unhandledRejection', () => fatal('supervisor_unhandled_rejection'));
	process.exitCode = await runRouter();
}
