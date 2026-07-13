import * as fs from 'node:fs';
import * as path from 'node:path';

import * as vscode from 'vscode';

import { SharedLogStore } from './runtime-state/shared-log-store';
import { LogRingBuffer } from './utils/log-ring-buffer';

import type { LogEntry, TunnelState, WebviewToExtension } from '@ungate/shared/frontend';

const LOG_BUFFER_SIZE = 500;
const LOG_POLL_INTERVAL_MS = 500;

const WAKE_PING_SCRIPT = `
(function() {
    let wakePingEnabled = false;
    let vscodeInstance = null;
    // #region agent log
    function dbgLog(msg, data) { try { fetch('http://127.0.0.1:7346/ingest/6a1fc829-b612-414b-b07e-6665c6c8059a', {method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'afb0d1'},body:JSON.stringify({sessionId:'afb0d1',location:'dashboard-wake-ping',message:msg,data:data||{},timestamp:Date.now()})}).catch(()=>{}); } catch(e){} }
    dbgLog('WAKE_PING_SCRIPT loaded', {hypothesisId:'H5'});
    // #endregion
    function getVsCode() {
        if (!vscodeInstance) {
            try {
                vscodeInstance = acquireVsCodeApi();
                // #region agent log
                dbgLog('acquireVsCodeApi succeeded', {hasInstance: !!vscodeInstance, hypothesisId:'H5'});
                // #endregion
            } catch(e) {
                // #region agent log
                dbgLog('acquireVsCodeApi THREW', {error: String(e), hypothesisId:'H5'});
                // #endregion
                console.error('Failed to acquire VSCode API:', e);
            }
        }
        return vscodeInstance;
    }

    setInterval(() => {
        if (document.getElementById('wake-ping-checkbox')) return;

        const labels = document.querySelectorAll('label');
        let targetLabel = null;
        for (const label of labels) {
            if (label.textContent.includes('OpenAI API Key')) {
                targetLabel = label;
                break;
            }
        }
        if (!targetLabel) return;

        const card = targetLabel.closest('.card');
        if (!card) return;

        const wakePingCard = document.createElement('div');
        wakePingCard.className = 'card preset-tonal-surface border border-surface-700/30 p-3 space-y-2 mt-4';
        wakePingCard.innerHTML = \`
            <label class="flex items-start gap-3 cursor-pointer">
                <input class="checkbox mt-0.5" type="checkbox" id="wake-ping-checkbox"/>
                <span class="text-sm leading-5 font-semibold">Keep Claude quota active (Wake Ping)</span>
            </label>
            <p class="text-xs text-surface-400">
                Sends minimal pings at the start of each 5-hour provider window during your active hours.
            </p>
            <div class="grid grid-cols-2 gap-2 mt-2">
                <label class="flex flex-col gap-1">
                    <span class="text-xs text-surface-400">Active from</span>
                    <input type="time" id="wake-ping-start" value="07:00" class="input input-sm" />
                </label>
                <label class="flex flex-col gap-1">
                    <span class="text-xs text-surface-400">until</span>
                    <input type="time" id="wake-ping-end" value="22:00" class="input input-sm" />
                </label>
            </div>
            <p class="text-xs text-surface-400">Next ping: <span id="wake-ping-next">--:--</span></p>
            <p class="text-xs text-surface-400">Last ping: <span id="wake-ping-last">never</span></p>
            <p class="text-xs text-red-400 hidden" id="wake-ping-error-row">Last error: <span id="wake-ping-error"></span></p>
            <button class="btn btn-sm preset-tonal-surface w-full mt-1" id="wake-ping-send">Send Ping Now</button>
        \`;

        card.parentNode.insertBefore(wakePingCard, card.nextSibling);

        const checkbox = wakePingCard.querySelector('#wake-ping-checkbox');
        checkbox.checked = wakePingEnabled;
        checkbox.addEventListener('change', () => {
            const vs = getVsCode();
            if (vs) {
                vs.postMessage({ type: 'toggle-wake-ping' });
            }
        });
        const startInput = wakePingCard.querySelector('#wake-ping-start');
        const endInput = wakePingCard.querySelector('#wake-ping-end');
        startInput.addEventListener('change', () => {
            const vs = getVsCode();
            if (vs) {
                vs.postMessage({ type: 'set-wake-ping-schedule', start: startInput.value, end: endInput.value });
            }
        });
        endInput.addEventListener('change', () => {
            const vs = getVsCode();
            if (vs) {
                vs.postMessage({ type: 'set-wake-ping-schedule', start: startInput.value, end: endInput.value });
            }
        });
        const sendBtn = wakePingCard.querySelector('#wake-ping-send');
        sendBtn.addEventListener('click', () => {
            const vs = getVsCode();
            // #region agent log
            dbgLog('sendBtn clicked', {hasVs: !!vs, hypothesisId:'H5'});
            // #endregion
            if (vs) {
                sendBtn.disabled = true;
                sendBtn.textContent = 'Sending...';
                vs.postMessage({ type: 'send-wake-ping' });
                // #region agent log
                dbgLog('postMessage send-wake-ping called', {hypothesisId:'H5'});
                // #endregion
            }
        });
    }, 500);

    window.addEventListener('message', event => {
        const message = event.data;
        if (message.type === 'wake-ping-state') {
            wakePingEnabled = message.enabled;
            const checkbox = document.getElementById('wake-ping-checkbox');
            if (checkbox) {
                checkbox.checked = wakePingEnabled;
            }
            const startInput = document.getElementById('wake-ping-start');
            const endInput = document.getElementById('wake-ping-end');
            if (startInput && message.workStart) startInput.value = message.workStart;
            if (endInput && message.workEnd) endInput.value = message.workEnd;
            const nextSpan = document.getElementById('wake-ping-next');
            if (nextSpan) {
                if (message.nextPingAt) {
                    const d = new Date(message.nextPingAt);
                    nextSpan.textContent = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                } else {
                    nextSpan.textContent = '--:--';
                }
            }
            const lastSpan = document.getElementById('wake-ping-last');
            if (lastSpan) {
                if (message.lastPingAt) {
                    const d = new Date(message.lastPingAt);
                    lastSpan.textContent = d.toLocaleString([], { hour: '2-digit', minute: '2-digit', day: '2-digit', month: '2-digit' });
                } else {
                    lastSpan.textContent = 'never';
                }
            }
            const errorRow = document.getElementById('wake-ping-error-row');
            const errorSpan = document.getElementById('wake-ping-error');
            if (errorRow && errorSpan) {
                if (message.lastPingError) {
                    errorSpan.textContent = message.lastPingError;
                    errorRow.classList.remove('hidden');
                } else {
                    errorRow.classList.add('hidden');
                }
            }
            const sendBtn = document.getElementById('wake-ping-send');
            if (sendBtn) {
                sendBtn.disabled = false;
                sendBtn.textContent = 'Send Ping Now';
            }
        }
    });
})();
`;

const MSGS_SIMPLE = [
	'webview-ready',
	'restart-server',
	'start-tunnel',
	'stop-tunnel',
	'restart-tunnel',
	'toggle-wake-ping',
	'send-wake-ping'
] as const;

export type Msg =
	| { type: 'open-external-url'; url: string }
	| { type: 'set-key-fix-enabled'; enabled: boolean }
	| { type: 'set-wake-ping-schedule'; start: string; end: string }
	| { type: 'clear-logs'; source: 'api' | 'tunnel' }
	| Extract<WebviewToExtension, { type: (typeof MSGS_SIMPLE)[number] }>;

export class Dashboard {
	private panel: vscode.WebviewPanel | null = null;
	private readonly apiLogBuffer = new LogRingBuffer(LOG_BUFFER_SIZE);
	private readonly tunnelLogBuffer = new LogRingBuffer(LOG_BUFFER_SIZE);
	private currentPort: number | null = null;
	private apiLogFileOffset = 0;
	private tunnelLogFileOffset = 0;
	private logPollTimer: NodeJS.Timeout | null = null;

	constructor(
		private readonly context: vscode.ExtensionContext,
		private readonly onMessage: (message: Msg) => void
	) {}

	show(): void {
		if (this.panel) {
			this.panel.reveal();

			return;
		}

		this.panel = vscode.window.createWebviewPanel('ungate', 'Ungate', vscode.ViewColumn.One, {
			enableScripts: true,
			localResourceRoots: [vscode.Uri.file(this.getWebDistPath())]
		});

		this.panel.iconPath = vscode.Uri.file(path.join(this.context.extensionPath, 'resources', 'icon.png'));

		this.panel.webview.onDidReceiveMessage((message: unknown) => {
			const parsed = Dashboard.parseIncomingMessage(message);

			if (!parsed) {
				return;
			}

			this.onMessage(parsed);
		});

		this.panel.webview.html = this.buildHtml();

		this.panel.onDidChangeViewState(() => {
			if (this.panel?.visible) {
				this.sendBufferedLogs('api');
				this.sendBufferedLogs('tunnel');
			}
		});

		this.panel.onDidDispose(() => {
			this.stopLogPoll();
			this.panel = null;
		});

		this.startLogPoll();
	}

	setPort(port: number | null): void {
		if (this.currentPort === port) {
			return;
		}

		this.currentPort = port;
		this.sendPort();
		this.rebuildHtml();
	}

	pushLog(source: 'api' | 'tunnel', entry: LogEntry): void {
		const buffer = source === 'api' ? this.apiLogBuffer : this.tunnelLogBuffer;
		buffer.push(entry);
		SharedLogStore.append(source, entry);

		this.panel?.webview.postMessage({ type: 'log', source, entry });
	}

	clearLogs(source: 'api' | 'tunnel'): void {
		const buffer = source === 'api' ? this.apiLogBuffer : this.tunnelLogBuffer;
		buffer.clear();
		SharedLogStore.clear(source);
		this.syncLogFileOffsets();
		this.panel?.webview.postMessage({ type: 'logs-cleared', source });
	}

	sendInitialState(tunnelState: TunnelState): void {
		this.sendPort();
		this.sendBufferedLogs('api');
		this.sendBufferedLogs('tunnel');
		this.panel?.webview.postMessage({ type: 'tunnel-status', state: tunnelState });
	}

	sendKeyFixState(enabled: boolean): void {
		this.panel?.webview.postMessage({ type: 'key-fix-state', enabled });
	}

	sendWakePingState(
		enabled: boolean,
		workStart: string,
		workEnd: string,
		nextPingAt: string | null,
		lastPingAt: string | null,
		lastPingError: string | null
	): void {
		this.panel?.webview.postMessage({
			type: 'wake-ping-state',
			enabled,
			workStart,
			workEnd,
			nextPingAt,
			lastPingAt,
			lastPingError
		});
	}

	sendTunnelState(state: TunnelState): void {
		this.panel?.webview.postMessage({ type: 'tunnel-status', state });
	}

	isOpen(): boolean {
		return this.panel !== null;
	}

	private static parseIncomingMessage(raw: unknown): Msg | null {
		if (typeof raw !== 'object' || raw === null || !('type' in raw)) {
			return null;
		}

		const record = raw as Record<string, unknown>;
		const type = record.type;

		if (typeof type !== 'string') {
			return null;
		}

		if (type === 'open-external-url') {
			const url = record.url;

			if (typeof url !== 'string') {
				return null;
			}

			return { type: 'open-external-url', url };
		}

		if (type === 'set-key-fix-enabled') {
			const enabled = record.enabled;

			if (typeof enabled !== 'boolean') {
				return null;
			}

			return { type: 'set-key-fix-enabled', enabled };
		}

		if (type === 'set-wake-ping-schedule') {
			const start = record.start;
			const end = record.end;

			if (typeof start !== 'string' || typeof end !== 'string') {
				return null;
			}

			return { type: 'set-wake-ping-schedule', start, end };
		}

		if (type === 'clear-logs') {
			const source = record.source;

			if (source !== 'api' && source !== 'tunnel') {
				return null;
			}

			return { type: 'clear-logs', source };
		}

		for (const allowed of MSGS_SIMPLE) {
			if (allowed === type) {
				return { type: allowed };
			}
		}

		return null;
	}

	private getWebDistPath(): string {
		if (this.context.extensionMode === vscode.ExtensionMode.Development) {
			return path.join(this.context.extensionPath, '..', 'web', 'dist');
		}

		return path.join(this.context.extensionPath, 'bundled', 'web', 'dist');
	}

	private sendPort(): void {
		this.panel?.webview.postMessage({ type: 'port', port: this.currentPort });
	}

	private rebuildHtml(): void {
		if (!this.panel) {
			return;
		}

		this.panel.webview.html = this.buildHtml();
	}

	private sendBufferedLogs(source: 'api' | 'tunnel'): void {
		const entries = SharedLogStore.readAll(source);

		if (entries.length > 0) {
			this.panel?.webview.postMessage({ type: 'log-bulk', source, entries });
		}

		this.syncLogFileOffsets();
	}

	private startLogPoll(): void {
		this.stopLogPoll();
		this.logPollTimer = setInterval(() => {
			this.pollSharedLogs('api');
			this.pollSharedLogs('tunnel');
		}, LOG_POLL_INTERVAL_MS);
	}

	private stopLogPoll(): void {
		if (this.logPollTimer) {
			clearInterval(this.logPollTimer);
			this.logPollTimer = null;
		}
	}

	private pollSharedLogs(source: 'api' | 'tunnel'): void {
		const offset = source === 'api' ? this.apiLogFileOffset : this.tunnelLogFileOffset;
		const { entries, nextOffset } = SharedLogStore.readSince(source, offset);

		if (source === 'api') {
			this.apiLogFileOffset = nextOffset;
		} else {
			this.tunnelLogFileOffset = nextOffset;
		}

		for (const entry of entries) {
			this.panel?.webview.postMessage({ type: 'log', source, entry });
		}
	}

	private syncLogFileOffsets(): void {
		const fileSize = SharedLogStore.getFileSize();

		this.apiLogFileOffset = fileSize;
		this.tunnelLogFileOffset = fileSize;
	}

	private buildHtml(): string {
		const distPath = this.getWebDistPath();
		const assetsUri = this.panel!.webview.asWebviewUri(vscode.Uri.file(path.join(distPath, 'assets')));
		const faviconUri = this.panel!.webview.asWebviewUri(vscode.Uri.file(path.join(distPath, 'favicon.png')));

		let html = fs.readFileSync(path.join(distPath, 'index.html'), 'utf-8');

		html = html.replace(/src="\/assets\//g, `src="${assetsUri.toString()}/`);
		html = html.replace(/href="\/assets\//g, `href="${assetsUri.toString()}/`);
		html = html.replace('href="/favicon.png"', `href="${faviconUri.toString()}"`);
		html = html.replace(
			'</head>',
			`<script>window.__PORT__ = ${this.currentPort}; window.__TS__ = ${Date.now()};</script>\n\t</head>`
		);
		html = html.replace('</body>', `<script>${WAKE_PING_SCRIPT}</script>\n</body>`);

		return html;
	}
}
