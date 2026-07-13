import { execFile } from 'node:child_process';
import * as os from 'node:os';
import * as path from 'node:path';
import { promisify } from 'node:util';

import { Sqlite3CliResolver } from './sqlite3-cli-resolver';

const execFileAsync = promisify(execFile);

type InstallLogger = (message: string) => void;

/**
 * Reads the API port from the ungate `app_settings` SQLite table.
 *
 * The API process is NSSM-managed and listens on the port stored in
 * `app_settings.port` (default 47821). The extension reads this port to
 * attach to the running service instead of spawning its own process.
 *
 * Mirrors the pattern in `CursorStateDbReader` for SQLite CLI access.
 */
export class UngateSettingsReader {
	private cliPath: string | null = null;
	private initResult: string | null | undefined;

	constructor(private readonly onLog?: InstallLogger) {}

	async init(): Promise<string | null> {
		if (this.initResult !== undefined) {
			return this.initResult;
		}

		this.cliPath = await Sqlite3CliResolver.resolve(this.onLog);
		this.initResult = this.cliPath ? null : 'SQLite CLI could not be prepared';

		return this.initResult;
	}

	/**
	 * Reads `port` from `app_settings` (row id = 1).
	 * Returns `null` if the DB, row, or CLI is unavailable — caller falls back to default.
	 */
	async readPort(): Promise<number | null> {
		if (!this.cliPath) {
			return null;
		}

		const dbPath = path.join(os.homedir(), '.ungate', 'data.db');
		const query = 'SELECT port FROM app_settings WHERE id = 1;';

		try {
			const { stdout } = await execFileAsync(this.cliPath, [dbPath, query]);
			const raw = stdout.trim();

			if (!raw) {
				return null;
			}

			const port = parseInt(raw, 10);

			return Number.isFinite(port) && port > 0 ? port : null;
		} catch {
			return null;
		}
	}
}
