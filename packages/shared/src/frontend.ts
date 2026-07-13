export * from './types';
export * from './constants';
export * from './guards';
export * from './helpers/model-provider';
export * from './helpers/provider-labels';
export * from './helpers/utils';
export * from './schemas';

import type { LogEntry, TunnelState } from './types';

export type ExtensionToWebview =
	| { type: 'port'; port: number | null }
	| { type: 'tunnel-status'; state: TunnelState }
	| { type: 'key-fix-state'; enabled: boolean }
	| {
			type: 'wake-ping-state';
			enabled: boolean;
			workStart: string;
			workEnd: string;
			nextPingAt: string | null;
			lastPingAt: string | null;
			lastPingError: string | null;
	  }
	| { type: 'log'; source: 'api' | 'tunnel'; entry: LogEntry }
	| { type: 'log-bulk'; source: 'api' | 'tunnel'; entries: LogEntry[] }
	| { type: 'logs-cleared'; source: 'api' | 'tunnel' };

export type WebviewToExtension =
	| { type: 'webview-ready' }
	| { type: 'restart-server' }
	| { type: 'start-tunnel' }
	| { type: 'stop-tunnel' }
	| { type: 'restart-tunnel' }
	| { type: 'toggle-wake-ping' }
	| { type: 'set-key-fix-enabled'; enabled: boolean }
	| { type: 'set-wake-ping-schedule'; start: string; end: string }
	| { type: 'clear-logs'; source: 'api' | 'tunnel' };
