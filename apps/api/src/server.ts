import cors from '@fastify/cors';
import Fastify from 'fastify';

import { setQuietMode } from 'src/utils/logger';

import { getConfig } from './config';
import { getDb } from './database/index';
import { Settings } from './database/settings';
import analyticsPlugin from './routes/analytics';
import anthropicPlugin from './routes/anthropic';
import authPlugin from './routes/auth';
import healthPlugin from './routes/health';
import modelsPlugin from './routes/models';
import openaiPlugin from './routes/openai';
import responsesPlugin from './routes/responses';
import settingsPlugin from './routes/settings';
import {
	getLastPingAt,
	getLastPingError,
	getNextPingTime,
	isWakePingRunning,
	loadWakePingConfig,
	saveWakePingConfig,
	sendWakePing,
	startWakePingScheduler,
	stopWakePingScheduler,
	TIME_RE
} from './wake-ping';

export async function startServer(): Promise<void> {
	getDb();
	const settings = Settings.get();
	const config = getConfig(settings);
	setQuietMode(config.quietMode);

	const app = Fastify({ logger: false });
	app.decorate('config', config);

	await app.register(cors, { origin: '*' });

	await app.register(healthPlugin);
	await app.register(authPlugin);
	await app.register(anthropicPlugin);
	await app.register(openaiPlugin);
	await app.register(responsesPlugin);
	await app.register(modelsPlugin);
	await app.register(analyticsPlugin);
	await app.register(settingsPlugin);

	// Wake Ping API routes
	app.get('/wake-ping', async (_request, reply) => {
		const cfg = loadWakePingConfig();
		const nextPingAt = cfg.enabled ? getNextPingTime(new Date(), cfg).toISOString() : null;

		return reply.send({
			enabled: cfg.enabled,
			intervalHours: cfg.intervalHours,
			workStart: cfg.workStart,
			workEnd: cfg.workEnd,
			sendOnStartup: cfg.sendOnStartup,
			model: cfg.model,
			maxTokens: cfg.maxTokens,
			pingMessage: cfg.pingMessage,
			running: isWakePingRunning(),
			lastPingAt: getLastPingAt(),
			lastPingError: getLastPingError(),
			nextPingAt
		});
	});

	app.post('/wake-ping', async (request, reply) => {
		const body = (request.body ?? {}) as Partial<{
			enabled: boolean;
			intervalHours: number;
			workStart: string;
			workEnd: string;
			sendOnStartup: boolean;
			model: string;
			maxTokens: number;
			pingMessage: string;
		}>;
		const cfg = loadWakePingConfig();
		if (typeof body.enabled === 'boolean') cfg.enabled = body.enabled;
		if (typeof body.intervalHours === 'number' && body.intervalHours >= 1) cfg.intervalHours = body.intervalHours;
		if (typeof body.workStart === 'string') {
			if (!TIME_RE.test(body.workStart)) return reply.code(400).send({ error: 'workStart must be HH:MM' });
			cfg.workStart = body.workStart;
		}
		if (typeof body.workEnd === 'string') {
			if (!TIME_RE.test(body.workEnd)) return reply.code(400).send({ error: 'workEnd must be HH:MM' });
			cfg.workEnd = body.workEnd;
		}
		if (cfg.workStart >= cfg.workEnd) {
			return reply.code(400).send({ error: 'workStart must be earlier than workEnd (overnight windows not yet supported)' });
		}
		if (typeof body.sendOnStartup === 'boolean') cfg.sendOnStartup = body.sendOnStartup;
		if (typeof body.model === 'string' && body.model.length > 0) cfg.model = body.model;
		if (typeof body.maxTokens === 'number' && body.maxTokens >= 1) cfg.maxTokens = body.maxTokens;
		if (typeof body.pingMessage === 'string') cfg.pingMessage = body.pingMessage;
		saveWakePingConfig(cfg);
		if (cfg.enabled) {
			stopWakePingScheduler();
			startWakePingScheduler();
		} else {
			stopWakePingScheduler();
		}

		return reply.send({ ok: true, enabled: cfg.enabled, running: isWakePingRunning() });
	});

	// Wake Ping: manually trigger a ping on demand
	app.post('/wake-ping/ping', async (_request, reply) => {
		const before = getLastPingAt();
		await sendWakePing();

		return reply.send({
			ok: true,
			lastPingAt: getLastPingAt(),
			lastPingError: getLastPingError(),
			sent: getLastPingAt() !== before
		});
	});

	await app.listen({ port: config.port, host: '0.0.0.0' });

	// Always print port to stdout — extension parses this to detect the running port.
	// Uses globalThis.console to bypass quiet mode.
	globalThis.console.log(`[ungate] listening on localhost:${config.port}`);

	startWakePingScheduler();
}
