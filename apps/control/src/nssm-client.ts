import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import type { DashboardServiceAction, DashboardServicePhase } from '@ungate/shared';

const execFileAsync = promisify(execFile);
const NSSM_TIMEOUT_MS = 30_000;

export class NssmClient {
	constructor(private readonly executable: string) {}

	async get(serviceName: string, parameter: string): Promise<string> {
		const { stdout } = await this.run(['get', serviceName, parameter]);

		return stdout.trim();
	}

	async status(serviceName: string): Promise<DashboardServicePhase> {
		const { stdout } = await this.run(['status', serviceName]);
		const normalized = stdout.trim().toUpperCase();

		if (normalized === 'SERVICE_RUNNING') return 'running';
		if (normalized === 'SERVICE_STOPPED') return 'stopped';
		if (normalized.includes('START_PENDING') || normalized.includes('CONTINUE_PENDING')) return 'starting';
		if (normalized.includes('STOP_PENDING') || normalized.includes('PAUSE_PENDING')) return 'stopping';

		return 'unknown';
	}

	async control(serviceName: string, action: DashboardServiceAction): Promise<void> {
		await this.run([action, serviceName]);
	}

	private async run(args: string[]): Promise<{ stdout: string; stderr: string }> {
		try {
			return await execFileAsync(this.executable, args, {
				timeout: NSSM_TIMEOUT_MS,
				maxBuffer: 1024 * 1024,
				windowsHide: true
			});
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			throw new Error(`[nssm] ${args.join(' ')} failed: ${message}`);
		}
	}
}
