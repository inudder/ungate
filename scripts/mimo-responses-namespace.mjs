function isObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function flatToolName(namespace, name) {
	return `${namespace.replace(/__+$/u, '')}__${name}`;
}

function namespaceKey(namespace, name) {
	return `${namespace}\u0000${name}`;
}

function directToolName(tool) {
	if (typeof tool?.name === 'string') return tool.name;
	if (isObject(tool?.function) && typeof tool.function.name === 'string') return tool.function.name;

	return undefined;
}

function cloneNamespaceTool(tool, name) {
	const parameters = tool.parameters ?? tool.input_schema ?? tool.inputSchema;
	const flattened = { ...tool, type: 'function', name };

	delete flattened.namespace;
	delete flattened.input_schema;
	delete flattened.inputSchema;
	if (parameters !== undefined) flattened.parameters = parameters;

	return flattened;
}

function addBareCandidate(candidates, original) {
	const current = candidates.get(original.name);
	if (current === undefined) {
		candidates.set(original.name, original);

		return;
	}
	if (current && (current.namespace !== original.namespace || current.name !== original.name)) {
		candidates.set(original.name, null);
	}
}

function rewriteInput(value, mapping) {
	if (Array.isArray(value)) return value.map((item) => rewriteInput(item, mapping));
	if (!isObject(value)) return value;

	const rewritten = {};
	for (const [key, child] of Object.entries(value)) rewritten[key] = rewriteInput(child, mapping);
	if (rewritten.type === 'function_call' && typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToFlat.get(namespaceKey(rewritten.namespace, rewritten.name));
		if (flatName) {
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}

	return rewritten;
}

function rewriteToolChoice(toolChoice, mapping) {
	if (!isObject(toolChoice)) return toolChoice;

	const rewritten = { ...toolChoice };
	if (typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToFlat.get(namespaceKey(rewritten.namespace, rewritten.name));
		if (flatName) {
			rewritten.type = 'function';
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}
	if (
		isObject(rewritten.function) &&
		typeof rewritten.function.namespace === 'string' &&
		typeof rewritten.function.name === 'string'
	) {
		const flatName = mapping.namespaceToFlat.get(namespaceKey(rewritten.function.namespace, rewritten.function.name));
		if (flatName) {
			rewritten.function = { ...rewritten.function, name: flatName };
			delete rewritten.function.namespace;
		}
	}

	return rewritten;
}

export function flattenMimoResponsesRequest(body) {
	if (!isObject(body)) throw new Error('Mimo Responses request body must be an object');

	const tools = Array.isArray(body.tools) ? body.tools : [];
	const directNames = new Set(
		tools
			.filter((tool) => tool?.type !== 'namespace')
			.map(directToolName)
			.filter((name) => typeof name === 'string')
	);
	const usedNames = new Set(directNames);
	const fullToOriginal = new Map();
	const namespaceToFlat = new Map();
	const bareCandidates = new Map();
	const flattenedTools = [];

	for (const tool of tools) {
		if (!isObject(tool) || tool.type !== 'namespace') {
			flattenedTools.push(tool);
			continue;
		}

		const namespace = tool.name;
		const innerTools = tool.tools ?? tool.functions;
		if (typeof namespace !== 'string' || namespace.trim() === '' || !Array.isArray(innerTools)) {
			throw new Error('Mimo namespace tools require a non-empty name and tools array');
		}

		for (const innerTool of innerTools) {
			if (!isObject(innerTool) || typeof innerTool.name !== 'string' || innerTool.name.trim() === '') {
				throw new Error(`Mimo namespace '${namespace}' contains a tool without a valid name`);
			}

			const flatName = flatToolName(namespace, innerTool.name);
			if (usedNames.has(flatName)) throw new Error(`Mimo flattened tool name '${flatName}' collides with another tool`);

			const original = { namespace, name: innerTool.name };
			usedNames.add(flatName);
			fullToOriginal.set(flatName, original);
			namespaceToFlat.set(namespaceKey(namespace, innerTool.name), flatName);
			addBareCandidate(bareCandidates, original);
			flattenedTools.push(cloneNamespaceTool(innerTool, flatName));
		}
	}

	for (const directName of directNames) {
		if (bareCandidates.has(directName)) bareCandidates.set(directName, null);
	}

	const mapping = {
		fullToOriginal,
		uniqueBareToOriginal: new Map([...bareCandidates.entries()].filter(([, original]) => original !== null)),
		namespaceToFlat
	};

	return {
		body: {
			...body,
			...(Array.isArray(body.tools) ? { tools: flattenedTools } : {}),
			...(body.input !== undefined ? { input: rewriteInput(body.input, mapping) } : {}),
			...(body.tool_choice !== undefined ? { tool_choice: rewriteToolChoice(body.tool_choice, mapping) } : {})
		},
		mapping
	};
}

export function restoreMimoResponsesValue(value, mapping) {
	if (!mapping || !isObject(mapping)) return value;
	if (Array.isArray(value)) return value.map((item) => restoreMimoResponsesValue(item, mapping));
	if (!isObject(value)) return value;

	const restored = {};
	for (const [key, child] of Object.entries(value)) restored[key] = restoreMimoResponsesValue(child, mapping);

	if ((restored.type === 'function_call' || restored.type === 'custom_tool_call') && typeof restored.name === 'string') {
		const original = mapping.fullToOriginal.get(restored.name) ?? mapping.uniqueBareToOriginal.get(restored.name);
		if (original) {
			restored.name = original.name;
			restored.namespace = original.namespace;
		}
	}

	return restored;
}
