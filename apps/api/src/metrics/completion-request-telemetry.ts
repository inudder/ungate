import { Requests } from 'src/database/requests';

import { logThinkingSummary, type ThinkingStats } from './thinking-stats';

import type { RequestRecord } from '@ungate/shared';
import type { FastifyReply } from 'fastify';

export type TelemetryRecord = RequestRecord & { thinking?: ThinkingStats };

export class CompletionRequestTelemetry {
	static recordAndApplyProxyHeaders(
		reply: FastifyReply,
		latencyMs: number,
		record: TelemetryRecord,
		cacheReadTokens?: number,
		cacheCreationTokens?: number
	): number {
		const requestId = this.record(record, cacheReadTokens, cacheCreationTokens);
		this.applyProxyHeaders(reply, latencyMs);

		return requestId;
	}

	static record(record: TelemetryRecord, cacheReadTokens?: number, cacheCreationTokens?: number): number {
		const { thinking, ...stored } = record;

		if (stored.source !== 'error') {
			logThinkingSummary(stored.model, thinking, stored.reasoningTokens);
		}

		return Requests.record(stored, cacheReadTokens, cacheCreationTokens);
	}

	static applyProxyHeaders(reply: FastifyReply, latencyMs: number): void {
		reply.header('x-request-id', `req_${Date.now()}`);
		reply.header('openai-processing-ms', latencyMs.toString());
		reply.header('openai-version', '2020-10-01');
	}
}
