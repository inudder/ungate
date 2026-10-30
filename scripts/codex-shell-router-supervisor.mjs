import { spawn } from 'node:child_process';
import { writeSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const runtimeDirectory = path.dirname(fileURLToPath(import.meta.url));

export function safeFailureDetails(error) {
	const names = new Set([
		'Error',
		'TypeError',
		'RangeError',
		'ReferenceError',
		'SyntaxError',
		'URIError',
		'EvalError',
		'AggregateError'
	]);
	const codes = new Set([
		'EADDRINUSE',
		'EACCES',
		'EPERM',
		'ENOENT',
		'ECONNREFUSED',
		'ECONNRESET',
		'ETIMEDOUT',
		'EPIPE',
		'ERR_STREAM_PREMATURE_CLOSE',
		'ERR_INVALID_ARG_TYPE',
		'ERR_INVALID_URL',
		'ERR_SERVER_NOT_RUNNING'
	]);
	const files = new Set([
		'codex-shell-router-supervisor.mjs',
		'codex-model-shell-router-service.mjs',
		'codex-model-shell-router.mjs',
		'codex-agent-messages.mjs',
		'codex-tools-schema-cache.mjs',
		'deepseek-responses-adapter.mjs',
		'mimo-responses-namespace.mjs',
		'mimo-responses-stream-adapter.mjs'
	]);
	let errorType = 'unknown';
	let errorCode = null;
	const frames = [];
	try {
		if (error instanceof Error) {
			errorType = names.has(error.name) ? error.name : 'Error';
			errorCode = codes.has(error.code) ? error.code : null;
			if (typeof error.stack === 'string') {
				for (const line of error.stack.split('\n').slice(1)) {
					const frame = /\b([\w.-]+\.mjs):(\d{1,7}):(\d{1,7})\)?$/.exec(line);
					if (frame && files.has(frame[1])) frames.push({ file: frame[1], line: Number(frame[2]), column: Number(frame[3]) });
					if (frames.length >= 8) break;
				}
			}
		}
	} catch {
		/* An exceptional error accessor must not prevent the process from exiting. */
	}

	return { error_type: errorType, error_code: errorCode, stack_frames: frames };
}

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
	const fatal = (event, error) => {
		try {
			writeSync(
				1,
				`${JSON.stringify({ timestamp: new Date().toISOString(), service: 'codex-model-shell-router', event, ...safeFailureDetails(error) })}\n`
			);
		} catch {
			/* NSSM will still observe the failing exit. */
		}
		process.exit(1);
	};
	process.on('uncaughtException', (error) => fatal('supervisor_uncaught_exception', error));
	process.on('unhandledRejection', (error) => fatal('supervisor_unhandled_rejection', error));
	process.exitCode = await runRouter();
}
