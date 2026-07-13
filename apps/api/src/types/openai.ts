export interface OpenAIMessage {
	role: 'system' | 'user' | 'assistant' | 'tool' | 'developer' | 'function';
	content: string | OpenAIContentPart[] | null;
	tool_calls?: OpenAIToolCall[];
	tool_call_id?: string;
	name?: string;
}

export interface OpenAIContentPart {
	type: 'text' | 'image_url';
	text?: string;
	image_url?: {
		url: string;
		detail?: 'auto' | 'low' | 'high';
	};
}

export interface OpenAITool {
	type: 'function';
	function: {
		name: string;
		description?: string;
		parameters?: Record<string, unknown>;
		strict?: boolean;
	};
}

export interface OpenAIToolCall {
	id: string;
	type: 'function';
	function: {
		name: string;
		arguments: string;
	};
}

export interface OpenAIChatRequest {
	model: string;
	messages: OpenAIMessage[];
	/** Some clients send the thread as `input` (chat roles or Responses items) instead of `messages`. */
	input?: unknown;
	max_tokens?: number;
	max_completion_tokens?: number;
	temperature?: number;
	top_p?: number;
	stream?: boolean;
	stop?: string | string[];
	presence_penalty?: number;
	frequency_penalty?: number;
	user?: string;
	tools?: OpenAITool[];
	tool_choice?: 'none' | 'auto' | 'required' | { type: 'function'; function: { name: string } };
	reasoning_effort?: 'none' | 'low' | 'medium' | 'high' | 'xhigh';
	reasoning?: {
		effort?: 'none' | 'low' | 'medium' | 'high' | 'xhigh';
	};
}

export interface OpenAIChatResponse {
	id: string;
	object: 'chat.completion';
	created: number;
	model: string;
	choices: {
		index: number;
		message: {
			role: 'assistant';
			content: string | null;
			tool_calls?: OpenAIToolCall[];
		};
		finish_reason: 'stop' | 'length' | 'content_filter' | 'tool_calls' | null;
	}[];
	usage: {
		prompt_tokens: number;
		completion_tokens: number;
		total_tokens: number;
	};
}

export interface OpenAIStreamChunkToolCall {
	index: number;
	id?: string;
	type?: 'function';
	function?: {
		name?: string;
		arguments?: string;
	};
}

export type OpenAIResponseReasoningEffort = 'minimal' | 'none' | 'low' | 'medium' | 'high' | 'xhigh';

export interface OpenAIResponsesFunctionTool {
	type: 'function';
	name: string;
	description?: string;
	parameters?: Record<string, unknown>;
	strict?: boolean;
}

export interface OpenAIResponsesRequest {
	model: string;
	input: string | Record<string, unknown>[];
	instructions?: string;
	tools?: (OpenAIResponsesFunctionTool | OpenAITool)[];
	tool_choice?: 'none' | 'auto' | 'required' | { type: 'function'; name?: string; function?: { name?: string } };
	stream?: boolean;
	temperature?: number;
	top_p?: number;
	max_output_tokens?: number;
	parallel_tool_calls?: boolean;
	reasoning?: {
		effort?: OpenAIResponseReasoningEffort;
	};
	metadata?: Record<string, unknown> | null;
	user?: string;
	previous_response_id?: string;
	store?: boolean;
}

export interface OpenAIResponseUsage {
	input_tokens: number;
	output_tokens: number;
	total_tokens: number;
}

export interface OpenAIResponseOutputText {
	type: 'output_text';
	text: string;
	annotations: unknown[];
}

export interface OpenAIResponseOutputMessage {
	id: string;
	type: 'message';
	role: 'assistant';
	status: 'in_progress' | 'completed' | 'incomplete';
	content: OpenAIResponseOutputText[];
}

export interface OpenAIResponseOutputFunctionToolCall {
	id: string;
	type: 'function_call';
	call_id: string;
	name: string;
	arguments: string;
	status: 'in_progress' | 'completed' | 'incomplete';
}

export type OpenAIResponseOutputItem = OpenAIResponseOutputMessage | OpenAIResponseOutputFunctionToolCall;

export interface OpenAIResponsesResponse {
	id: string;
	object: 'response';
	created_at: number;
	model: string;
	status: 'in_progress' | 'completed' | 'incomplete' | 'failed';
	output: OpenAIResponseOutputItem[];
	usage: OpenAIResponseUsage;
	error?: { message: string; type?: string; code?: string };
	incomplete_details?: { reason: string };
	metadata?: Record<string, unknown> | null;
}

export interface OpenAIResponsesErrorResponse {
	error: {
		message: string;
		type: string;
		code?: string;
	};
}

export type OpenAIResponseStreamEvent =
	| { type: 'response.created'; response: OpenAIResponsesResponse }
	| { type: 'response.in_progress'; response: OpenAIResponsesResponse }
	| { type: 'response.output_item.added'; response_id: string; output_index: number; item: OpenAIResponseOutputItem }
	| {
			type: 'response.content_part.added';
			response_id: string;
			item_id: string;
			output_index: number;
			content_index: number;
			part: OpenAIResponseOutputText;
	  }
	| {
			type: 'response.output_text.delta';
			response_id: string;
			item_id: string;
			output_index: number;
			content_index: number;
			delta: string;
	  }
	| {
			type: 'response.output_text.done';
			response_id: string;
			item_id: string;
			output_index: number;
			content_index: number;
			text: string;
	  }
	| {
			type: 'response.content_part.done';
			response_id: string;
			item_id: string;
			output_index: number;
			content_index: number;
			part: OpenAIResponseOutputText;
	  }
	| {
			type: 'response.function_call_arguments.delta';
			response_id: string;
			item_id: string;
			output_index: number;
			call_id: string;
			delta: string;
	  }
	| {
			type: 'response.function_call_arguments.done';
			response_id: string;
			item_id: string;
			output_index: number;
			call_id: string;
			name: string;
			arguments: string;
	  }
	| { type: 'response.output_item.done'; response_id: string; output_index: number; item: OpenAIResponseOutputItem }
	| { type: 'response.completed'; response: OpenAIResponsesResponse }
	| { type: 'response.incomplete'; response: OpenAIResponsesResponse }
	| { type: 'response.failed'; response: OpenAIResponsesResponse }
	| { type: 'response.error'; error: { message: string; type?: string; code?: string } };

export interface OpenAIStreamChunk {
	id: string;
	object: 'chat.completion.chunk';
	created: number;
	model: string;
	choices: {
		index: number;
		delta: {
			role?: 'assistant';
			content?: string | null;
			tool_calls?: OpenAIStreamChunkToolCall[];
		};
		finish_reason: 'stop' | 'length' | 'content_filter' | 'tool_calls' | null;
	}[];
}
