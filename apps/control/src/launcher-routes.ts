import { randomUUID } from 'node:crypto';

import type { ControlConfig } from './config';
import type { EventHub } from './event-hub';
import type { LauncherTransport } from './launcher-client';
import type { LauncherFailure, LauncherOperation } from '@ungate/shared';
import type { FastifyInstance } from 'fastify';

const profile = { type: 'string', const: 'default' } as const;

interface JsonSchemaNode {
	type?: string;
	additionalProperties?: boolean;
	properties?: Record<string, JsonSchemaNode>;
}

function unknownFields(value: unknown, schema: JsonSchemaNode, path = ''): string[] {
	if (schema.additionalProperties !== false || !schema.properties || !value || typeof value !== 'object' || Array.isArray(value))
		return [];
	const record = value as Record<string, unknown>;
	const unknown: string[] = [];
	for (const key of Object.keys(record)) {
		const field = path ? path + '.' + key : key;
		const child = schema.properties[key];
		if (!child) unknown.push(field);
		else unknown.push(...unknownFields(record[key], child, field));
	}

	return unknown;
}

function failure(status: number, code: string, message: string, extra: Record<string, unknown> = {}) {
	return { status, body: { code, message, ...extra } satisfies LauncherFailure };
}

export function registerLauncherRoutes(
	app: FastifyInstance,
	config: ControlConfig,
	events: EventHub,
	transport: LauncherTransport | null
): void {
	const watched = new Set<string>();
	const watch = (operationId: string) => {
		if (!transport || watched.has(operationId)) return;
		watched.add(operationId);
		const timer = setInterval(() => {
			void transport
				.request('operations.get', { profileId: 'default', operationId }, randomUUID())
				.then((response) => {
					if (response.status !== 200) return;
					const operation = response.body as LauncherOperation;
					events.broadcast({ type: 'launcher-operation', data: operation });
					if (operation.status !== 'queued' && operation.status !== 'running') {
						clearInterval(timer);
						watched.delete(operationId);
					}
				})
				.catch(() => undefined);
		}, 1000);
		timer.unref();
	};

	const call = async (action: string, payload: Record<string, unknown>) => {
		if (!config.launcher || !transport) return failure(503, 'agent_unavailable', 'Компонент управления не запущен');
		if (payload.profileId !== 'default') return failure(404, 'unknown_profile', 'Unknown launcher profile.');
		const supplied = payload.requestId;
		const forwarded = { ...payload };
		delete forwarded.requestId;
		const requestId = typeof supplied === 'string' && /^[A-Za-z0-9-]{8,80}$/.test(supplied) ? supplied : randomUUID();
		try {
			const response = await transport.request(action, forwarded, requestId);

			return { status: response.status, body: response.body };
		} catch (error) {
			const detail = error instanceof Error ? error.message.split('\n')[0] : 'unknown';

			return failure(503, 'agent_unavailable', 'Компонент управления не запущен', { detail });
		}
	};

	app.get('/api/control/launcher/state', async (request, reply) => {
		const profileId = (request.query as { profileId?: string }).profileId;
		const result = await call('state.get', { profileId: profileId ?? '' });
		if (result.status === 503 && config.launcher) {
			return reply.code(503).send({
				...(result.body as object),
				startCommand: `pwsh -NoProfile -File '${config.launcher.agentScript.replaceAll("'", "''")}'`
			});
		}

		return reply.code(result.status).send(result.body);
	});

	const post = (path: string, action: string, schema: Record<string, unknown>) => {
		app.post(
			path,
			{
				schema: { body: schema },
				preValidation: async (request, reply) => {
					const unknown = unknownFields(request.body, schema as JsonSchemaNode);
					if (unknown.length === 0) return;

					return reply.code(400).send({
						code: 'malformed_request',
						message: 'Malformed request',
						fieldErrors: unknown.map((field) => ({ field, message: 'Unknown field' }))
					});
				}
			},
			async (request, reply) => {
				const result = await call(action, request.body as Record<string, unknown>);
				if (result.status === 202 && result.body && typeof result.body === 'object' && 'operationId' in result.body) {
					watch(String((result.body as { operationId: string }).operationId));
				}

				return reply.code(result.status).send(result.body);
			}
		);
	};

	const revisionBody = {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'expectedRevision'],
		properties: { profileId: profile, expectedRevision: { type: 'string', minLength: 1 } }
	};
	post('/api/control/launcher/models/version', 'models.version', {
		...revisionBody,
		required: ['profileId', 'registryId', 'expectedRevision'],
		properties: {
			...revisionBody.properties,
			registryId: { type: 'string', minLength: 1 },
			set: { type: 'object' },
			unset: { type: 'array', items: { type: 'string' } }
		}
	});
	post('/api/control/launcher/models/capabilities', 'models.capabilities', {
		...revisionBody,
		required: ['profileId', 'registryId', 'expectedRevision'],
		properties: {
			...revisionBody.properties,
			registryId: { type: 'string', minLength: 1 },
			set: { type: 'object' },
			unset: { type: 'array', items: { type: 'string' } }
		}
	});
	post('/api/control/launcher/models/reset', 'models.reset', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'registryId', 'expectedRevision', 'scope'],
		properties: {
			profileId: profile,
			registryId: { type: 'string' },
			expectedRevision: { type: 'string' },
			scope: { type: 'string', enum: ['version', 'capabilities', 'transport-prefix'] }
		}
	});
	post('/api/control/launcher/models/prefix', 'models.prefix', {
		...revisionBody,
		required: ['profileId', 'registryId', 'expectedRevision'],
		properties: {
			...revisionBody.properties,
			registryId: { type: 'string', minLength: 1 },
			set: { type: 'object', additionalProperties: false, properties: { upstreamModelPrefix: { type: 'string' } } },
			unset: { type: 'array', items: { type: 'string', const: 'upstreamModelPrefix' } }
		}
	});
	post('/api/control/launcher/catalog', 'catalog.list', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'transport'],
		properties: { profileId: profile, transport: { type: 'string', enum: ['ungate', 'cliproxyapi', 'omniroute'] } }
	});
	post('/api/control/launcher/models/add', 'models.add', {
		type: 'object',
		additionalProperties: false,
		required: [
			'profileId',
			'registryId',
			'displayName',
			'upstreamModel',
			'transport',
			'defaultReasoningLevel',
			'supportsImageInput',
			'expectedRevision'
		],
		properties: {
			profileId: profile,
			registryId: { type: 'string' },
			displayName: { type: 'string' },
			upstreamModel: { type: 'string' },
			transport: { type: 'string', enum: ['ungate', 'cliproxyapi', 'omniroute'] },
			defaultReasoningLevel: { type: 'string' },
			supportsImageInput: { type: 'boolean' },
			supportsImageDetailOriginal: { type: 'boolean' },
			contextWindow: { type: 'string', maxLength: 32 },
			skipCatalogCheck: { type: 'boolean' },
			expectedRevision: { type: 'string' }
		}
	});
	const removalBody = {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'registryId', 'expectedRevision'],
		properties: {
			profileId: profile,
			registryId: { type: 'string', minLength: 1 },
			expectedRevision: { type: 'string', minLength: 1 }
		}
	};
	post('/api/control/launcher/models/remove', 'models.remove', removalBody);
	post('/api/control/launcher/models/add-template', 'models.addTemplate', removalBody);
	post('/api/control/launcher/picker', 'picker.set', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'registryIds', 'expectedRevision'],
		properties: {
			profileId: profile,
			expectedRevision: { type: 'string' },
			registryIds: { type: 'array', items: { type: 'string' } }
		}
	});
	post('/api/control/launcher/memories', 'memories.set', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'enabled', 'provider', 'model', 'expectedRevision'],
		properties: {
			profileId: profile,
			enabled: { type: 'boolean' },
			provider: { type: 'string' },
			model: { type: 'string' },
			expectedRevision: { type: 'string' },
			requestId: { type: 'string', minLength: 8, maxLength: 80 }
		}
	});
	post('/api/control/launcher/logging', 'logging.set', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'level', 'expectedRevision'],
		properties: {
			profileId: profile,
			level: { type: 'string', enum: ['Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors'] },
			expectedRevision: { type: 'string' }
		}
	});
	post('/api/control/launcher/diagnostics', 'diagnostics.start', {
		type: 'object',
		additionalProperties: false,
		required: ['profileId', 'kind', 'registryIds'],
		properties: {
			profileId: profile,
			kind: { type: 'string', enum: ['capabilities', 'tools', 'memory'] },
			registryIds: { type: 'array', items: { type: 'string' } },
			requestId: { type: 'string', minLength: 8, maxLength: 80 }
		}
	});
	app.get('/api/control/launcher/operations/:id', async (request, reply) => {
		const result = await call('operations.get', { profileId: 'default', operationId: (request.params as { id: string }).id });

		return reply.code(result.status).send(result.body);
	});
	app.post('/api/control/launcher/operations/:id/cancel', async (request, reply) => {
		const result = await call('operations.cancel', { profileId: 'default', operationId: (request.params as { id: string }).id });

		return reply.code(result.status).send(result.body);
	});
	app.get('/api/control/launcher/reports/:id', async (request, reply) => {
		const result = await call('reports.get', { profileId: 'default', reportId: (request.params as { id: string }).id });

		return reply.code(result.status).send(result.body);
	});
}
