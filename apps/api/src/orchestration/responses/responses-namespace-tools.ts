import type {
	OpenAIResponsesFunctionTool,
	OpenAIResponsesNamespaceFunctionTool,
	OpenAIResponsesNamespaceTool,
	OpenAIResponsesRequest,
	OpenAITool
} from 'src/types/openai';

export interface ResponsesNamespacedToolName {
	namespace: string;
	name: string;
}

export interface ResponsesNamespaceToolMapping {
	fullToOriginal: ReadonlyMap<string, ResponsesNamespacedToolName>;
	uniqueBareToOriginal: ReadonlyMap<string, ResponsesNamespacedToolName>;
}

interface MutableNamespaceToolMapping {
	fullToOriginal: Map<string, ResponsesNamespacedToolName>;
	namespaceToolToFlat: Map<string, string>;
	bareCandidates: Map<string, ResponsesNamespacedToolName | null>;
}

type ResponsesRequestTool = OpenAIResponsesFunctionTool | OpenAIResponsesNamespaceTool | OpenAITool;

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function directToolName(tool: ResponsesRequestTool): string | undefined {
	const record = tool as unknown as Record<string, unknown>;

	if (typeof record.name === 'string') {
		return record.name;
	}

	if (isRecord(record.function) && typeof record.function.name === 'string') {
		return record.function.name;
	}

	return undefined;
}

function flattenedToolName(namespace: string, name: string): string {
	return `${namespace.replace(/__+$/u, '')}__${name}`;
}

function namespaceToolKey(namespace: string, name: string): string {
	return `${namespace}\u0000${name}`;
}

function addBareCandidate(mapping: MutableNamespaceToolMapping, original: ResponsesNamespacedToolName): void {
	const current = mapping.bareCandidates.get(original.name);

	if (current === undefined) {
		mapping.bareCandidates.set(original.name, original);

		return;
	}

	if (current && (current.namespace !== original.namespace || current.name !== original.name)) {
		mapping.bareCandidates.set(original.name, null);
	}
}

function cloneNamespaceFunctionTool(tool: OpenAIResponsesNamespaceFunctionTool, name: string): OpenAIResponsesFunctionTool {
	const parameters = tool.parameters ?? tool.input_schema ?? tool.inputSchema;

	return {
		type: 'function',
		name,
		description: tool.description,
		parameters,
		strict: tool.strict
	};
}

function rewriteRequestValue(value: unknown, mapping: MutableNamespaceToolMapping): unknown {
	if (Array.isArray(value)) {
		return value.map((item) => rewriteRequestValue(item, mapping));
	}

	if (!isRecord(value)) {
		return value;
	}

	const rewritten: Record<string, unknown> = {};
	for (const [key, child] of Object.entries(value)) {
		rewritten[key] = rewriteRequestValue(child, mapping);
	}

	if (rewritten.type === 'function_call' && typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToolToFlat.get(namespaceToolKey(rewritten.namespace, rewritten.name));
		if (flatName) {
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}

	return rewritten;
}

function rewriteToolChoice(
	toolChoice: OpenAIResponsesRequest['tool_choice'],
	mapping: MutableNamespaceToolMapping
): OpenAIResponsesRequest['tool_choice'] {
	if (!isRecord(toolChoice)) {
		return toolChoice;
	}

	const rewritten = { ...toolChoice };
	if (typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToolToFlat.get(namespaceToolKey(rewritten.namespace, rewritten.name));
		if (flatName) {
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}

	if (isRecord(rewritten.function)) {
		const nested = { ...rewritten.function };
		if (typeof nested.namespace === 'string' && typeof nested.name === 'string') {
			const flatName = mapping.namespaceToolToFlat.get(namespaceToolKey(nested.namespace, nested.name));
			if (flatName) {
				nested.name = flatName;
				delete nested.namespace;
				rewritten.function = nested;
			}
		}
	}

	return rewritten as OpenAIResponsesRequest['tool_choice'];
}

export function flattenResponsesNamespaceTools(req: OpenAIResponsesRequest): {
	request: OpenAIResponsesRequest;
	mapping: ResponsesNamespaceToolMapping;
} {
	const tools = req.tools ?? [];
	const directNames = new Set(
		tools
			.filter((tool) => tool.type !== 'namespace')
			.map(directToolName)
			.filter((name): name is string => Boolean(name))
	);
	const usedNames = new Set(directNames);
	const mutableMapping: MutableNamespaceToolMapping = {
		fullToOriginal: new Map(),
		namespaceToolToFlat: new Map(),
		bareCandidates: new Map()
	};
	const flattenedTools: (OpenAIResponsesFunctionTool | OpenAITool)[] = [];

	for (const tool of tools) {
		if (tool.type !== 'namespace') {
			flattenedTools.push(tool);
			continue;
		}

		const namespaceTool = tool;
		const innerTools = namespaceTool.tools ?? namespaceTool.functions;
		if (!namespaceTool.name || !Array.isArray(innerTools)) {
			throw new Error('Responses namespace tools require a non-empty name and a tools array');
		}

		for (const innerTool of innerTools) {
			if (!innerTool.name) {
				throw new Error(`Responses namespace '${namespaceTool.name}' contains a tool without a valid name`);
			}

			const flatName = flattenedToolName(namespaceTool.name, innerTool.name);
			if (usedNames.has(flatName)) {
				throw new Error(`Flattened Responses tool name '${flatName}' collides with another tool`);
			}

			const original = { namespace: namespaceTool.name, name: innerTool.name };
			usedNames.add(flatName);
			mutableMapping.fullToOriginal.set(flatName, original);
			mutableMapping.namespaceToolToFlat.set(namespaceToolKey(original.namespace, original.name), flatName);
			addBareCandidate(mutableMapping, original);
			flattenedTools.push(cloneNamespaceFunctionTool(innerTool, flatName));
		}
	}

	const mapping: ResponsesNamespaceToolMapping = {
		fullToOriginal: mutableMapping.fullToOriginal,
		uniqueBareToOriginal: new Map(
			[...mutableMapping.bareCandidates.entries()].filter(
				(entry): entry is [string, ResponsesNamespacedToolName] => entry[1] !== null
			)
		)
	};

	return {
		request: {
			...req,
			...(req.tools && { tools: flattenedTools }),
			input: rewriteRequestValue(req.input, mutableMapping) as OpenAIResponsesRequest['input'],
			tool_choice: rewriteToolChoice(req.tool_choice, mutableMapping)
		},
		mapping
	};
}

export function restoreResponsesNamespaceValue<T>(value: T, mapping: ResponsesNamespaceToolMapping): T {
	if (Array.isArray(value)) {
		return value.map((item) => restoreResponsesNamespaceValue(item, mapping)) as T;
	}

	if (!isRecord(value)) {
		return value;
	}

	const rewritten: Record<string, unknown> = {};
	for (const [key, child] of Object.entries(value)) {
		rewritten[key] = restoreResponsesNamespaceValue(child, mapping);
	}

	if (rewritten.type === 'function_call' && typeof rewritten.name === 'string') {
		const original = mapping.fullToOriginal.get(rewritten.name) ?? mapping.uniqueBareToOriginal.get(rewritten.name);
		if (original) {
			rewritten.name = original.name;
			rewritten.namespace = original.namespace;
		}
	}

	return rewritten as T;
}
