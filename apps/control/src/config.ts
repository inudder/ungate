import path from 'node:path';

import { launcherPipeName } from './launcher-client';

export interface LauncherProfileConfig {
	profileId: 'default';
	ownerSid: string;
	betaHome: string;
	pipeName: string;
	entryPoint: string;
	agentScript: string;
}

export interface ControlConfig {
	host: '127.0.0.1';
	port: number;
	apiPort: number;
	apiUrl: string;
	apiServiceName: string;
	tunnelServiceName: string;
	tunnelHealthUrl: string;
	nssmPath: string;
	publicDir: string;
	statusPollIntervalMs: number;
	logPollIntervalMs: number;
	operationTimeoutMs: number;
	launcher: LauncherProfileConfig | null;
}

function parsePort(value: string | undefined, fallback: number): number {
	if (value === '0') return 0;
	const parsed = Number.parseInt(value ?? '', 10);

	if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
		return fallback;
	}

	return parsed;
}

function trimTrailingSlash(value: string): string {
	return value.replace(/\/+$/, '');
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ControlConfig {
	const port = parsePort(env.PORT, 47820);
	const apiPort = parsePort(env.UNGATE_API_PORT, 47821);

	return {
		host: '127.0.0.1',
		port,
		apiPort,
		apiUrl: trimTrailingSlash(env.UNGATE_API_URL ?? `http://127.0.0.1:${apiPort}`),
		apiServiceName: env.UNGATE_API_SERVICE ?? 'ungate-api',
		tunnelServiceName: env.UNGATE_TUNNEL_SERVICE ?? 'frpc',
		tunnelHealthUrl: trimTrailingSlash(env.UNGATE_TUNNEL_HEALTH_URL ?? 'https://ungate.ahref.cyou/health'),
		nssmPath: env.NSSM_PATH ?? 'nssm',
		publicDir: env.UNGATE_DASHBOARD_PUBLIC_DIR ?? path.resolve(process.cwd(), 'bundle', 'public'),
		statusPollIntervalMs: 2000,
		logPollIntervalMs: 500,
		operationTimeoutMs: 30_000,
		launcher: readLauncherProfile(env)
	};
}

function readLauncherProfile(env: NodeJS.ProcessEnv): LauncherProfileConfig | null {
	const ownerSid = env.UNGATE_LAUNCHER_OWNER_SID;
	const betaHome = env.UNGATE_LAUNCHER_BETA_HOME;
	const pipeName = env.UNGATE_LAUNCHER_PIPE;
	const entryPoint = env.UNGATE_LAUNCHER_ENTRY;
	const agentScript = env.UNGATE_LAUNCHER_AGENT;
	if (!ownerSid || !betaHome || !pipeName || !entryPoint || !agentScript) return null;
	if (launcherPipeName(ownerSid, betaHome) !== pipeName) return null;

	return { profileId: 'default', ownerSid, betaHome, pipeName, entryPoint, agentScript };
}
