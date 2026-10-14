import type { ChatCompletionUsage } from 'src/types/openai';

export interface StreamProcessResult {
	type: 'chunk' | 'done';
	data?: Record<string, unknown>;
}

export interface PendingFunctionCallState {
	callId: string;
	openAiIndex: number;
	argsBuffer: string;
	deferred: boolean;
}

export interface StreamState {
	buffer: string;
	id: string;
	model: string;
	created: number;
	roleSent: boolean;
	sawTextDelta: boolean;
	toolCallsSeen: boolean;
	toolCallIndex: number;
	processedItemIds: Set<string>;
	pendingFunctionCalls: Map<number, PendingFunctionCallState>;
	sseKindCounts: Map<string, number>;
	outputItemTypeAdded: Map<string, number>;
	outputItemTypeDone: Map<string, number>;
	/** Set from `response.completed`; absent when upstream sent no usable usage. */
	usage?: ChatCompletionUsage;
}

export class StreamStateFactory {
	static create(model: string): StreamState {
		const state: StreamState = {
			buffer: '',
			id: `chatcmpl-${Date.now().toString(36)}`,
			model,
			created: Math.floor(Date.now() / 1000),
			roleSent: false,
			sawTextDelta: false,
			toolCallsSeen: false,
			toolCallIndex: 0,
			processedItemIds: new Set(),
			pendingFunctionCalls: new Map(),
			sseKindCounts: new Map(),
			outputItemTypeAdded: new Map(),
			outputItemTypeDone: new Map()
		};

		return state;
	}
}
