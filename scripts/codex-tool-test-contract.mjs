import { createHash } from 'node:crypto';

export const TOOL_PURPOSES = {
	exec: 'выполнение JavaScript и вызов вложенных инструментов',
	wait: 'получение результата незавершённой ячейки exec',
	request_user_input: 'вопрос пользователю и получение ответа',
	'collaboration.spawn_agent': 'создание вспомогательного агента',
	'collaboration.list_agents': 'список агентов и их состояния',
	'collaboration.send_message': 'доставка сообщения существующему агенту',
	'collaboration.followup_task': 'новое задание, включая запуск простаивающего агента',
	'collaboration.wait_agent': 'ожидание сообщения или завершения агента',
	'collaboration.interrupt_agent': 'прерывание работающего агента',
	web_search: 'поиск в интернете и получение источников'
};

export function flattenTools(tools, prefix = '') {
	return tools.flatMap((tool) => {
		const name = `${prefix}${tool.name ?? tool.type}`;
		if (tool.type !== 'namespace') return [{ name, definition: tool }];

		return flattenTools(tool.tools ?? tool.functions ?? [], `${name}.`);
	});
}

export function filterTools(tools, names, prefix = '') {
	return tools.flatMap((tool) => {
		const name = `${prefix}${tool.name ?? tool.type}`;
		if (tool.type !== 'namespace') return names.has(name) ? [tool] : [];
		const key = Array.isArray(tool.tools) ? 'tools' : 'functions';
		const children = filterTools(tool[key], names, `${name}.`);

		return children.length ? [{ ...tool, [key]: children }] : [];
	});
}

// Descriptions are model-specific prose; all validation constraints remain significant.
function canonical(value) {
	if (Array.isArray(value)) return value.map(canonical);
	if (!value || typeof value !== 'object') return value;

	return Object.fromEntries(
		Object.keys(value)
			.filter((key) => !['description', 'title', '$comment'].includes(key))
			.sort()
			.map((key) => [key, canonical(value[key])])
	);
}

export function toolContractHash(tool) {
	const contract = { type: tool.type, name: tool.name };
	if (tool.type === 'function') {
		contract.parameters = tool.parameters ?? tool.inputSchema ?? tool.input_schema;
		if (tool.strict !== undefined) contract.strict = tool.strict;
	} else if (tool.type === 'custom') contract.format = tool.format;
	else Object.assign(contract, tool);

	return createHash('sha256')
		.update(JSON.stringify(canonical(contract)))
		.digest('hex');
}

export function compareContracts(expected, actual, names) {
	const saved = new Map(flattenTools(expected).map((tool) => [tool.name, tool.definition]));
	const runtime = new Map(flattenTools(actual).map((tool) => [tool.name, tool.definition]));

	return [...names].flatMap((name) => {
		if (!saved.has(name) || !runtime.has(name)) return [{ tool: name, reason: 'Tool is absent from snapshot or runtime.' }];
		if (toolContractHash(saved.get(name)) !== toolContractHash(runtime.get(name))) {
			return [{ tool: name, reason: 'Runtime input contract differs from the saved snapshot.' }];
		}

		return [];
	});
}

export function outputText(output) {
	if (typeof output === 'string') return output;
	if (Array.isArray(output)) return output.map(outputText).join('\n');
	if (output?.text) return output.text;
	if (output?.content) return outputText(output.content);

	return JSON.stringify(output ?? '');
}

export class ToolLedger {
	constructor(names) {
		this.names = new Set(names);
		this.calls = new Map();
		this.outputs = new Map();
		this.errors = [];
		this.streamed = new Set();
		this.messages = [];
		this.contextMessages = [];
	}

	input(items) {
		for (const item of Array.isArray(items) ? items : []) {
			if (item.role === 'developer') this.contextMessages.push(outputText(item.content));
			if (!['function_call_output', 'custom_tool_call_output'].includes(item.type)) continue;
			if (!item.call_id || !this.calls.has(item.call_id)) {
				this.errors.push('Tool output has no matching call.');
				continue;
			}
			const text = outputText(item.output);
			if (this.outputs.has(item.call_id) && this.outputs.get(item.call_id) !== text) {
				this.errors.push('Conflicting tool outputs for one call ID.');
			}
			this.outputs.set(item.call_id, text);
		}
	}

	event(event) {
		if (event.type === 'response.output_item.done') this.item(event.item, true);
		if (event.type === 'response.completed') {
			for (const item of event.response?.output ?? []) this.item(item, false);
		}
	}

	item(item, streamed) {
		if (item?.type === 'message') {
			this.messages.push(item);

			return;
		}
		if (!['function_call', 'custom_tool_call', 'web_search_call'].includes(item?.type)) return;
		const name = item.type === 'web_search_call' ? 'web_search' : `${item.namespace ? `${item.namespace}.` : ''}${item.name}`;
		const id = item.call_id ?? (item.type === 'web_search_call' ? item.id : null);
		if (!id || !item.id || !this.names.has(name)) {
			this.errors.push('Tool call has a missing identity or an unexposed tool name.');

			return;
		}
		if (streamed && this.streamed.has(id)) this.errors.push('Duplicate completed tool call in SSE.');
		if (streamed) this.streamed.add(id);
		const previous = this.calls.get(id);
		if (
			previous &&
			(previous.name !== name ||
				previous.item.id !== item.id ||
				previous.item.arguments !== item.arguments ||
				previous.item.input !== item.input)
		) {
			this.errors.push('Conflicting tool call IDs.');
		}
		if (item.type === 'function_call') {
			try {
				JSON.parse(item.arguments);
			} catch {
				this.errors.push('Function arguments are not valid JSON.');
			}
		}
		this.calls.set(id, { name, item, sequence: previous?.sequence ?? this.calls.size });
	}

	forTool(name) {
		return [...this.calls]
			.filter(([, call]) => call.name === name)
			.map(([id, call]) => ({
				...call,
				id,
				output: this.outputs.get(id)
			}));
	}

	summary() {
		return {
			calls: this.calls.size,
			outputs: this.outputs.size,
			errors: [...new Set(this.errors)],
			observations: [...this.calls].map(([id, call]) => ({
				id,
				tool: call.name,
				sequence: call.sequence,
				inputHash: createHash('sha256')
					.update(call.item.arguments ?? call.item.input ?? '')
					.digest('hex'),
				output: this.outputs.get(id)?.slice(0, 1500),
				status: call.item.status
			}))
		};
	}
}
