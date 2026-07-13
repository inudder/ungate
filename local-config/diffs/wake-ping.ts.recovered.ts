/**
 * Wake Ping — keep Claude/Codex quota active by sending a small periodic request.
 *
 * This module is a USER ADDITION (not present in upstream orchidfiles/ungate).
 * Recovered from the unpacked extension bundle
 * (bundled/api/bundle/main.cjs, lines 60262-60403).
 *
 * Reads config from `bundled/api/wake-ping.json` (relative to __dirname when bundled).
 * Exposes:
 *   - loadWakePingConfig()
 *   - saveWakePingConfig(cfg)
 *   - sendWakePing()
 *   - startWakePingScheduler()
 *   - stopWakePingScheduler()
 */

import * as path from 'node:path';
import * as fs from 'node:fs';
import { makeClaudeCodeRequest } from '../proxy/anthropic-client'; // verify import path

// Path resolves to bundled/api/wake-ping.json when bundled by tsup.
// At dev time, __dirname is apps/api/src, so config sits at apps/api/wake-ping.json.
const configPath = path.join(__dirname, '..', 'wake-ping.json');

export interface WakePingConfig {
    enabled: boolean;
    intervalHours: number;
    sendOnStartup: boolean;
    model: string;
    maxTokens: number;
    pingMessage: string;
}

const defaults: WakePingConfig = {
    enabled: false,
    intervalHours: 5,
    sendOnStartup: true,
    model: 'claude-sonnet-4-20250514',
    maxTokens: 10,
    pingMessage: 'ping'
};

let _wakePingTimer: NodeJS.Timeout | null = null;
let _wakePingEnabled = false;
let _wakePingConfig: WakePingConfig | null = null;

export function loadWakePingConfig(): WakePingConfig {
    try {
        delete require.cache[configPath];
        const cfg = require(configPath);
        return {
            enabled: cfg.enabled === true,
            intervalHours: cfg.intervalHours || 5,
            sendOnStartup: cfg.sendOnStartup !== false,
            model: cfg.model || 'claude-sonnet-4-20250514',
            maxTokens: cfg.maxTokens || 10,
            pingMessage: cfg.pingMessage || 'ping'
        };
    } catch (err) {
        console.error('[wake-ping] Failed to load config:', err.message);
        return { ...defaults };
    }
}

export function saveWakePingConfig(cfg: WakePingConfig): boolean {
    try {
        fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
        return true;
    } catch (err) {
        console.error('[wake-ping] Failed to save config:', err.message);
        return false;
    }
}

export async function sendWakePing(): Promise<void> {
    const cfg = _wakePingConfig || loadWakePingConfig();
    try {
        const body = {
            model: cfg.model,
            max_tokens: cfg.maxTokens,
            messages: [{ role: 'user', content: cfg.pingMessage }],
            stream: false
        };
        const headers: Record<string, string> = {};
        const result = await makeClaudeCodeRequest('/v1/messages', body, headers);
        if (result.success) {
            console.log('[wake-ping] OK at ' + new Date().toISOString());
        } else {
            console.log('[wake-ping] Failed: ' + result.error + ' (status: ' + result.status + ')');
        }
    } catch (err) {
        console.error('[wake-ping] Error: ' + (err as Error).message);
    }
}

export function startWakePingScheduler(): void {
    _wakePingConfig = loadWakePingConfig();
    if (!_wakePingConfig.enabled) {
        console.log('[wake-ping] Disabled in config, not starting');
        return;
    }
    if (_wakePingTimer) {
        clearInterval(_wakePingTimer);
    }
    const intervalMs = _wakePingConfig.intervalHours * 60 * 60 * 1000;
    console.log(`[wake-ping] Starting scheduler: every ${_wakePingConfig.intervalHours} hours, model=${_wakePingConfig.model}`);
    _wakePingEnabled = true;
    _wakePingTimer = setInterval(() => {
        if (_wakePingEnabled) {
            sendWakePing().catch(err => console.error('[wake-ping] Unhandled:', err));
        }
    }, intervalMs);
    if (_wakePingConfig.sendOnStartup) {
        console.log('[wake-ping] Sending startup wake ping...');
        sendWakePing().catch(err => console.error('[wake-ping] Initial ping error:', err));
    } else {
        console.log('[wake-ping] Startup ping skipped (sendOnStartup is false)');
    }
}

export function stopWakePingScheduler(): void {
    if (_wakePingTimer) {
        clearInterval(_wakePingTimer);
        _wakePingTimer = null;
    }
    _wakePingEnabled = false;
    console.log('[wake-ping] Scheduler stopped');
}

export function isWakePingRunning(): boolean {
    return _wakePingEnabled;
}
