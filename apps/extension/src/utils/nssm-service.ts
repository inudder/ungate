import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const NSSM_TIMEOUT_MS = 30_000;

/**
 * Controls NSSM-managed Windows services via `nssm.exe` (expected on PATH).
 *
 * Used by `ApiServer` to restart the `ungate-api` service that owns the API
 * process, instead of spawning/killing the process directly.
 */
export class NssmService {
	static async restart(serviceName: string): Promise<void> {
		await this.run(serviceName, 'restart');
	}

	static async start(serviceName: string): Promise<void> {
		await this.run(serviceName, 'start');
	}

	static async stop(serviceName: string): Promise<void> {
		await this.run(serviceName, 'stop');
	}

	static async status(serviceName: string): Promise<string> {
		const { stdout } = await this.run(serviceName, 'status', true);

		return stdout.trim();
	}

	private static async run(
		serviceName: string,
		action: string,
		returnStdout = false
	): Promise<{ stdout: string; stderr: string }> {
		if (process.platform !== 'win32') {
			throw new Error('NSSM service control is only supported on Windows');
		}

		try {
			const result = await execFileAsync('nssm', [action, serviceName], {
				timeout: NSSM_TIMEOUT_MS,
				maxBuffer: 1024 * 1024
			});

			return returnStdout ? result : { stdout: '', stderr: '' };
		} catch (err) {
			const message = err instanceof Error ? err.message : `nssm ${action} ${serviceName} failed`;
			throw new Error(`[nssm] ${action} ${serviceName} failed: ${message}`);
		}
	}
}
