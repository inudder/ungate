/**
 * Wake Ping — keep Claude quota active by sending a small periodic request
 * at the start of each provider window during your active hours.
 *
 * User addition (not present in upstream orchidfiles/ungate).
 *
 * Config: bundled/api/wake-ping.json (relative to __dirname when bundled).
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { makeClaudeCodeRequest } from './proxy/anthropic-client';
import { defaults, getNextPingTime, TIME_RE, type WakePingConfig } from './wake-ping-scheduler';

import type { AnthropicRequest } from './types/anthropic';

// Re-export for server.ts
export { getNextPingTime, TIME_RE, type WakePingConfig };

// __dirname is available in the CJS bundle (tsup targets cjs).
// wake-ping.ts is only loaded from server.ts in the bundled context, never in ESM tests.
const configPath = join(__dirname, '..', 'wake-ping.json');

let _wakePingTimer: NodeJS.Timeout | null = null;
let _wakePingEnabled = false;
let _wakePingConfig: WakePingConfig | null = null;
let _lastPingAt: string | null = null;
let _lastPingError: string | null = null;

export function loadWakePingConfig(): WakePingConfig {
	try {
		const raw = readFileSync(configPath, 'utf8');
		const cfg = JSON.parse(raw) as Partial<WakePingConfig>;

		return {
			enabled: cfg.enabled === true,
			intervalHours: cfg.intervalHours ?? defaults.intervalHours,
			workStart: cfg.workStart ?? defaults.workStart,
			workEnd: cfg.workEnd ?? defaults.workEnd,
			sendOnStartup: cfg.sendOnStartup !== false,
			model: cfg.model ?? defaults.model,
			maxTokens: cfg.maxTokens ?? defaults.maxTokens,
			pingMessage: cfg.pingMessage ?? defaults.pingMessage
		};
	} catch (err) {
		console.error('[wake-ping] Failed to load config:', (err as Error).message);

		return { ...defaults };
	}
}

export function saveWakePingConfig(cfg: WakePingConfig): boolean {
	try {
		writeFileSync(configPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');

		return true;
	} catch (err) {
		console.error('[wake-ping] Failed to save config:', (err as Error).message);

		return false;
	}
}

export async function sendWakePing(): Promise<void> {
	const cfg = _wakePingConfig ?? loadWakePingConfig();
	try {
		const body: AnthropicRequest = {
			model: cfg.model,
			max_tokens: cfg.maxTokens,
			messages: [{ role: 'user', content: cfg.pingMessage }],
			stream: false
		};
		const result = await makeClaudeCodeRequest('/v1/messages', body, {});
		if (result.success) {
			const httpStatus = result.response.status;
			let responseModel = '';
			let inputTokens = 0;
			let outputTokens = 0;
			let responseType = '';
			try {
				const responseJson = await result.response.clone().json();
				const json = responseJson as {
					model?: string;
					type?: string;
					usage?: { input_tokens?: number; output_tokens?: number };
				};
				responseModel = json.model ?? '';
				responseType = json.type ?? '';
				inputTokens = json.usage?.input_tokens ?? 0;
				outputTokens = json.usage?.output_tokens ?? 0;
			} catch {
				// response body parse failed
			}
			const totalTokens = inputTokens + outputTokens;
			const pingOk = httpStatus === 200 && responseType === 'message' && totalTokens > 0;
			if (pingOk) {
				_lastPingAt = new Date().toISOString();
				_lastPingError = null;
				console.log('[wake-ping] OK at ' + _lastPingAt + ` (${totalTokens} tokens, model=${responseModel})`);
			} else {
				_lastPingError = `Invalid response: HTTP ${httpStatus}, type=${responseType || 'unknown'}, tokens=${totalTokens}`;
				console.log(`[wake-ping] Failed: ${_lastPingError}`);
			}
		} else {
			_lastPingError = `${result.error} (status: ${result.status})`;
			console.log(`[wake-ping] Failed: ${result.error} (status: ${result.status})`);
		}
	} catch (err) {
		_lastPingError = (err as Error).message;
		console.error('[wake-ping] Error: ' + _lastPingError);
	}
}

function scheduleNextPing(): void {
	if (_wakePingTimer) {
		clearTimeout(_wakePingTimer);
		_wakePingTimer = null;
	}
	if (!_wakePingConfig) return;

	const now = new Date();
	const next = getNextPingTime(now, _wakePingConfig);
	const delay = next.getTime() - now.getTime();
	console.log(`[wake-ping] Next at ${next.toISOString()} (in ${Math.round(delay / 60000)}m)`);

	_wakePingTimer = setTimeout(() => {
		if (_wakePingEnabled) {
			sendWakePing().catch((err) => console.error('[wake-ping] Unhandled:', err));
		}
		scheduleNextPing();
	}, delay);
}

export function startWakePingScheduler(): void {
	_wakePingConfig = loadWakePingConfig();
	if (!_wakePingConfig.enabled) {
		console.log('[wake-ping] Disabled in config, not starting');

		return;
	}
	console.log(
		`[wake-ping] Starting scheduler: workStart=${_wakePingConfig.workStart} workEnd=${_wakePingConfig.workEnd} interval=${_wakePingConfig.intervalHours}h model=${_wakePingConfig.model}`
	);
	_wakePingEnabled = true;

	if (_wakePingConfig.sendOnStartup) {
		console.log('[wake-ping] Sending startup wake ping...');
		sendWakePing().catch((err) => console.error('[wake-ping] Initial ping error:', err));
	} else {
		console.log('[wake-ping] Startup ping skipped (sendOnStartup is false)');
	}

	scheduleNextPing();
}

export function stopWakePingScheduler(): void {
	if (_wakePingTimer) {
		clearTimeout(_wakePingTimer);
		_wakePingTimer = null;
	}
	_wakePingEnabled = false;
	console.log('[wake-ping] Scheduler stopped');
}

export function isWakePingRunning(): boolean {
	return _wakePingEnabled;
}

export function getLastPingAt(): string | null {
	return _lastPingAt;
}

export function getLastPingError(): string | null {
	return _lastPingError;
}
