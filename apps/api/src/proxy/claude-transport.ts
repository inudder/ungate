import { ProxyAgent, type Dispatcher } from 'undici';

const PRE_SEND_ERRORS = new Set([
	'ECONNREFUSED',
	'ENOTFOUND',
	'EAI_AGAIN',
	'UND_ERR_CONNECT_TIMEOUT',
	'CERT_HAS_EXPIRED',
	'DEPTH_ZERO_SELF_SIGNED_CERT',
	'UNABLE_TO_VERIFY_LEAF_SIGNATURE'
]);

let proxyAgent: ProxyAgent | undefined;
let proxyUrl: string | undefined;

export class ClaudeTransportError extends Error {
	constructor(
		readonly code: 'proxy_unavailable' | 'network_error',
		readonly safeToRetry: boolean
	) {
		super(code === 'proxy_unavailable' ? 'Claude proxy connection is unavailable.' : 'Claude connection is unavailable.');
		this.name = 'ClaudeTransportError';
	}
}

function hasPreSendError(error: unknown): boolean {
	let current = error;
	for (let depth = 0; depth < 8 && current && typeof current === 'object'; depth += 1) {
		const cause = current as { code?: string; message?: string; cause?: unknown };
		if (cause.code && PRE_SEND_ERRORS.has(cause.code)) return true;
		// Undici rejected CONNECT before sending the OAuth request into the tunnel.
		if (cause.code === 'UND_ERR_ABORTED' && /^Proxy response \(\d+\) !== 200 when HTTP Tunneling$/.test(cause.message ?? ''))
			return true;
		current = cause.cause;
	}

	return false;
}

function dispatcher(): ProxyAgent | undefined {
	const configuredUrl = process.env.UNGATE_CLAUDE_PROXY_URL?.trim();
	if (!configuredUrl) return undefined;
	if (proxyAgent && proxyUrl === configuredUrl) return proxyAgent;
	const parsed = new URL(configuredUrl);
	if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
		throw new Error('UNGATE_CLAUDE_PROXY_URL requires an HTTP or HTTPS proxy.');
	}
	const token =
		parsed.username || parsed.password
			? `Basic ${Buffer.from(`${decodeURIComponent(parsed.username)}:${decodeURIComponent(parsed.password)}`).toString('base64')}`
			: undefined;
	parsed.username = '';
	parsed.password = '';
	if (proxyAgent) void proxyAgent.close();
	proxyAgent = new ProxyAgent({ uri: parsed.href, token, requestTls: { timeout: 5000 }, proxyTls: { timeout: 5000 } });
	proxyUrl = configuredUrl;

	return proxyAgent;
}

export async function fetchClaude(url: string, init: RequestInit = {}): Promise<Response> {
	let agent: ProxyAgent | undefined;
	try {
		agent = dispatcher();
	} catch {
		throw new ClaudeTransportError('proxy_unavailable', true);
	}
	let dispatched = false;
	let requestStarted = false;
	const tracked: Pick<Dispatcher, 'dispatch'> | undefined = agent && {
		dispatch(options, handler) {
			dispatched = true;
			// CONNECT and TLS must finish before this target-request callback runs.
			if (handler.onRequestStart) {
				const original = handler.onRequestStart.bind(handler);
				handler.onRequestStart = function (controller, context) {
					requestStarted = true;
					original(controller, context);
				};
			} else {
				const original = handler.onConnect?.bind(handler);
				handler.onConnect = function (abort) {
					requestStarted = true;
					original?.(abort);
				};
			}

			return agent.dispatch(options, handler);
		}
	};
	try {
		const options: RequestInit & { dispatcher?: Pick<Dispatcher, 'dispatch'> } = tracked
			? { ...init, dispatcher: tracked }
			: init;

		return await fetch(url, options);
	} catch (error) {
		const safe = (dispatched && !requestStarted) || hasPreSendError(error);
		throw new ClaudeTransportError(agent ? 'proxy_unavailable' : 'network_error', safe);
	}
}

export async function closeClaudeTransport(): Promise<void> {
	const agent = proxyAgent;
	proxyAgent = undefined;
	proxyUrl = undefined;
	await agent?.close();
}
