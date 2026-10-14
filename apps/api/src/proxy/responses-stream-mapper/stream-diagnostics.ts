import { logger } from 'src/utils/logger';

import type { StreamState } from './stream-state';
import type { ChatCompletionUsage } from 'src/types/openai';

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === 'object' ? (value as Record<string, unknown>) : undefined;
}

function tokenCount(value: unknown): number | undefined {
	return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined;
}

export class StreamDiagnostics {
	static bumpOutputItem(map: Map<string, number>, item: Record<string, unknown>): void {
		let t = '?';

		if (typeof item.type === 'string' && item.type.length > 0) {
			t = item.type;
		}

		map.set(t, (map.get(t) ?? 0) + 1);
	}

	static noteKind(state: StreamState, kind: string | undefined): void {
		let k = '(no-type)';

		if (kind != null) {
			k = kind;
		}

		state.sseKindCounts.set(k, (state.sseKindCounts.get(k) ?? 0) + 1);
	}

	/** Maps Responses `usage` to Chat Completions; undefined when it carries no input or output count. */
	static mapUsage(usage: unknown): ChatCompletionUsage | undefined {
		const raw = asRecord(usage);

		if (!raw) {
			return undefined;
		}

		const promptTokens = tokenCount(raw.input_tokens) ?? tokenCount(raw.prompt_tokens);
		const completionTokens = tokenCount(raw.output_tokens) ?? tokenCount(raw.completion_tokens);

		if (promptTokens === undefined && completionTokens === undefined) {
			return undefined;
		}

		const prompt = promptTokens ?? 0;
		const completion = completionTokens ?? 0;
		const upstreamTotal = tokenCount(raw.total_tokens);
		const mappedUsage: ChatCompletionUsage = {
			prompt_tokens: prompt,
			completion_tokens: completion,
			total_tokens: upstreamTotal !== undefined && upstreamTotal > 0 ? upstreamTotal : prompt + completion
		};
		const cachedTokens = tokenCount(asRecord(raw.input_tokens_details ?? raw.prompt_tokens_details)?.cached_tokens);
		const reasoningTokens = tokenCount(asRecord(raw.output_tokens_details ?? raw.completion_tokens_details)?.reasoning_tokens);

		if (cachedTokens !== undefined) {
			mappedUsage.prompt_tokens_details = { cached_tokens: cachedTokens };
		}

		if (reasoningTokens !== undefined) {
			mappedUsage.completion_tokens_details = { reasoning_tokens: reasoningTokens };
		}

		return mappedUsage;
	}

	static logFinished(state: StreamState, how: 'stream' | 'buffer'): void {
		const entries = [...state.sseKindCounts.entries()].sort((a, b) => b[1] - a[1]);
		const top = entries
			.slice(0, 24)
			.map(([t, n]) => `${t}:${n}`)
			.join(' ');
		let summary = top;

		if (top.length > 900) {
			summary = `${top.slice(0, 900)}…`;
		}

		const addedTypes = [...state.outputItemTypeAdded.entries()].map(([t, n]) => `${t}:${n}`).join(',');
		const doneTypes = [...state.outputItemTypeDone.entries()].map(([t, n]) => `${t}:${n}`).join(',');
		let added = addedTypes;

		if (!added) {
			added = '-';
		}

		let done = doneTypes;

		if (!done) {
			done = '-';
		}

		let summaryOrPlaceholder = summary;

		if (!summaryOrPlaceholder) {
			summaryOrPlaceholder = 'NO_SSE_PARSED';
		}

		logger.log(
			`[Codex stream] ${how} done toolCallsSeen=${state.toolCallsSeen} toolCallIndex=${state.toolCallIndex} text=${state.sawTextDelta} kinds=${state.sseKindCounts.size} output_item.added[${added}] output_item.done[${done}] ${summaryOrPlaceholder}`
		);
	}
}
