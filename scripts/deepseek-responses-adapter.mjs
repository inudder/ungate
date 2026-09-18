import { Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';

const CALLS = new Set(['function_call', 'custom_tool_call']);
const OUTPUTS = new Set(['function_call_output', 'custom_tool_call_output']);

// Normalize only complete, unambiguous rounds; never cross reasoning/user boundaries.
export function orderDeepSeekToolHistory(input) {
	if (!Array.isArray(input)) return input;
	const result = [];
	let segment = [];
	function flush() {
		const calls = segment.filter((item) => CALLS.has(item?.type));
		const outputs = segment.filter((item) => OUTPUTS.has(item?.type));
		const ids = new Set(calls.map((item) => item.call_id));
		const valid =
			calls.length > 0 &&
			ids.size === calls.length &&
			calls.every((call) => typeof call.call_id === 'string' && call.call_id.length > 0) &&
			outputs.length === calls.length &&
			new Set(outputs.map((item) => item.call_id)).size === outputs.length &&
			calls.every((call) =>
				outputs.some(
					(output) =>
						output.call_id === call.call_id &&
						output.type === `${call.type}_output` &&
						segment.indexOf(output) > segment.indexOf(call)
				)
			);
		if (!valid) result.push(...segment);
		else {
			let round = [];
			let sawOutput = false;
			let ambiguousRound = false;
			const pending = new Set();
			for (const item of segment) {
				round.push(item);
				if (sawOutput && !OUTPUTS.has(item?.type)) ambiguousRound = true;
				if (CALLS.has(item?.type)) pending.add(item.call_id);
				if (OUTPUTS.has(item?.type)) {
					sawOutput = true;
					pending.delete(item.call_id);
					if (pending.size === 0) {
						if (ambiguousRound) result.push(...round);
						else
							result.push(
								...round.filter((part) => !CALLS.has(part?.type) && !OUTPUTS.has(part?.type)),
								...round.filter((part) => CALLS.has(part?.type)),
								...round.filter((part) => OUTPUTS.has(part?.type))
							);
						round = [];
						sawOutput = false;
						ambiguousRound = false;
					}
				}
			}
			result.push(...round);
		}
		segment = [];
	}
	for (const item of input) {
		if (item?.type === 'reasoning' || ['user', 'system', 'developer'].includes(item?.role)) {
			flush();
			result.push(item);
		} else segment.push(item);
	}
	flush();

	return result;
}

export function adaptDeepSeekRequest(body) {
	const adaptedNames = new Set();
	const tools = body.tools?.map((tool) => {
		if (tool.type !== 'custom' || tool.name !== 'exec') return tool;
		adaptedNames.add('exec');

		return {
			type: 'function',
			name: 'exec',
			description: `${tool.description ?? ''}\nReturn the original executable source verbatim in the input string. Do not add markdown fences.${tool.format?.type === 'grammar' ? `\nThe source must satisfy this ${tool.format.syntax} grammar:\n${tool.format.definition}` : ''}`,
			parameters: {
				type: 'object',
				properties: { input: { type: 'string', description: 'Original source code for the Codex exec tool.' } },
				required: ['input'],
				additionalProperties: false
			},
			strict: true
		};
	});
	const calls = new Map();
	for (const item of Array.isArray(body.input) ? body.input : []) {
		if (item?.type === 'custom_tool_call' && item.name === 'exec') {
			calls.set(item.call_id, item.name);
			adaptedNames.add('exec');
		}
	}
	if (tools?.filter((tool) => tool.name === 'exec').length > 1) throw new Error('DeepSeek exec tool name collision.');
	const input = orderDeepSeekToolHistory(body.input);
	const rewritten = Array.isArray(input)
		? input.map((item) => {
				if (item.type === 'custom_tool_call' && item.name === 'exec') {
					const { input: source, ...rest } = item;
					if (typeof source !== 'string') throw new Error('DeepSeek historical exec input must be a string.');

					return { ...rest, type: 'function_call', arguments: JSON.stringify({ input: source }) };
				}
				if (item.type === 'custom_tool_call_output' && calls.has(item.call_id)) return { ...item, type: 'function_call_output' };

				return item;
			})
		: input;
	const choice =
		body.tool_choice?.type === 'custom' && body.tool_choice.name === 'exec'
			? { ...body.tool_choice, type: 'function' }
			: body.tool_choice;

	return {
		body: {
			...body,
			...(tools ? { tools } : {}),
			...(body.input !== undefined ? { input: rewritten } : {}),
			...(choice !== undefined ? { tool_choice: choice } : {})
		},
		mapping: { adaptedNames }
	};
}

function decodeInput(argumentsJson) {
	let value;
	try {
		value = JSON.parse(argumentsJson);
	} catch {
		throw new Error('deepseek_exec_arguments_invalid: expected JSON with a string input.');
	}
	if (!value || typeof value.input !== 'string') throw new Error('deepseek_exec_arguments_invalid: missing string input.');

	return value.input;
}

function isExec(item, mapping) {
	return item?.type === 'function_call' && mapping.adaptedNames.has(item.name);
}

function restoreItem(item, mapping) {
	if (!isExec(item, mapping)) return item;
	const { arguments: args, ...rest } = item;

	return { ...rest, type: 'custom_tool_call', input: decodeInput(args) };
}

export function restoreDeepSeekResponse(value, mapping) {
	if (!value || typeof value !== 'object') return value;

	return { ...value, ...(Array.isArray(value.output) ? { output: value.output.map((item) => restoreItem(item, mapping)) } : {}) };
}

export function createDeepSeekStreamAdapter(mapping) {
	const decoder = new StringDecoder('utf8');
	let buffer = '';
	let sequence = 0;
	let failed = false;
	const calls = new Map();
	const emitted = new Set();
	let stream;
	function emit(value) {
		stream.push(`event: ${value.type}\ndata: ${JSON.stringify({ ...value, sequence_number: sequence++ })}\n\n`);
	}
	function finishCall(index, item) {
		if (emitted.has(index)) return;
		const state = calls.get(index);
		const args = [item.arguments, state?.arguments, state?.item.arguments].find(
			(value) => typeof value === 'string' && value.length > 0
		);
		const complete = { ...state?.item, ...item, arguments: args };
		const restored = restoreItem(complete, mapping);
		// Buffer the JSON wrapper until valid: never expose partially decoded code to Codex.
		emit({ type: 'response.output_item.added', output_index: index, item: { ...restored, status: 'in_progress', input: '' } });
		emit({ type: 'response.custom_tool_call_input.delta', output_index: index, item_id: restored.id, delta: restored.input });
		emit({ type: 'response.custom_tool_call_input.done', output_index: index, item_id: restored.id, input: restored.input });
		emit({ type: 'response.output_item.done', output_index: index, item: restored });
		emitted.add(index);
	}
	function frame(block) {
		if (failed) return;
		const data = block
			.split('\n')
			.filter((line) => line.startsWith('data:'))
			.map((line) => line.slice(5).trimStart())
			.join('\n');
		if (!data || data === '[DONE]') {
			stream.push(`${block}\n\n`);

			return;
		}
		const value = JSON.parse(data);
		const index = value.output_index;
		if (value.type === 'response.output_item.added' && isExec(value.item, mapping)) {
			calls.set(index, { item: value.item, arguments: '' });

			return;
		}
		if (calls.has(index) && value.type === 'response.function_call_arguments.delta') {
			calls.get(index).arguments += value.delta;
			if (calls.get(index).arguments.length > 16 * 1024 * 1024) throw new Error('deepseek_exec_arguments_too_large');

			return;
		}
		if (calls.has(index) && value.type === 'response.function_call_arguments.done') {
			calls.get(index).arguments = value.arguments;

			return;
		}
		if (value.type === 'response.output_item.done' && isExec(value.item, mapping)) {
			finishCall(index, value.item);

			return;
		}
		if (['response.completed', 'response.incomplete'].includes(value.type)) {
			for (const [outputIndex, item] of (value.response?.output ?? []).entries()) {
				if (isExec(item, mapping)) finishCall(outputIndex, item);
			}
			for (const callIndex of calls.keys()) if (!emitted.has(callIndex)) throw new Error('deepseek_exec_arguments_incomplete');
			emit({ ...value, response: restoreDeepSeekResponse(value.response, mapping) });

			return;
		}
		emit(value);
	}
	function drain() {
		let match;
		while ((match = /\r?\n\r?\n/.exec(buffer))) {
			const block = buffer.slice(0, match.index).replace(/\r\n/g, '\n');
			buffer = buffer.slice(match.index + match[0].length);
			frame(block);
		}
		if (buffer.length > 16 * 1024 * 1024) throw new Error('deepseek_response_frame_too_large');
	}
	function fail() {
		if (failed) return;
		failed = true;
		emit({
			type: 'error',
			error: {
				type: 'deepseek_adapter_error',
				code: 'deepseek_exec_parse_error',
				message: 'DeepSeek returned an invalid or incomplete exec tool call.'
			}
		});
	}
	stream = new Transform({
		transform(chunk, _encoding, callback) {
			try {
				buffer += decoder.write(chunk);
				drain();
			} catch {
				fail();
			}
			callback();
		},
		flush(callback) {
			try {
				buffer += decoder.end();
				drain();
				if (buffer.trim() || [...calls.keys()].some((index) => !emitted.has(index))) fail();
			} catch {
				fail();
			}
			callback();
		}
	});

	return stream;
}
