import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, rename, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';

export function schemaHash(tools) {
	return createHash('sha256').update(JSON.stringify(tools)).digest('hex');
}

export function validateTools(tools) {
	if (!Array.isArray(tools) || tools.length === 0) throw new Error('The tool snapshot is empty.');
	for (const tool of tools) {
		if (!tool || typeof tool !== 'object' || typeof tool.type !== 'string') throw new Error('Invalid tool definition.');
		if (['function', 'custom', 'namespace'].includes(tool.type) && !tool.name) throw new Error('Tool name is missing.');
		if (tool.type === 'namespace') validateTools(tool.tools ?? tool.functions);
		if (tool.type === 'function' && !(tool.parameters ?? tool.inputSchema ?? tool.input_schema)) {
			throw new Error(`Function schema is missing: ${tool.name}`);
		}
	}
}

export async function writeJsonAtomic(filename, value) {
	await mkdir(path.dirname(filename), { recursive: true });
	const temporary = `${filename}.${randomUUID()}.tmp`;
	try {
		await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
		await rename(temporary, filename);
	} finally {
		await unlink(temporary).catch(() => {});
	}
}

export function createToolsCacheWriter(filename, warn = () => {}) {
	let pending = Promise.resolve();

	return (tools, sourceModel) => {
		if (!filename || !Array.isArray(tools) || tools.length === 0) return pending;
		try {
			validateTools(tools);
			// Clone before the router/adapter can mutate the request.
			const snapshot = {
				version: 1,
				capturedAt: new Date().toISOString(),
				sourceModel,
				schemaHash: schemaHash(tools),
				tools: structuredClone(tools)
			};
			pending = pending
				.then(() => writeJsonAtomic(filename, snapshot))
				.catch(() => warn('Tool schema cache could not be saved.'));
		} catch {
			warn('Tool schema cache skipped an invalid tools array.');
		}

		return pending;
	};
}

export async function readToolsSnapshot(filename) {
	const content = await readFile(filename, 'utf8');
	const snapshot = JSON.parse(content);
	validateTools(snapshot.tools);
	if (
		snapshot.version !== 1 ||
		!snapshot.sourceModel ||
		!Number.isFinite(Date.parse(snapshot.capturedAt)) ||
		snapshot.schemaHash !== schemaHash(snapshot.tools)
	)
		throw new Error('Invalid tool snapshot metadata or checksum.');

	return snapshot;
}

// Bootstrap only from original Responses requests retaining Codex namespaces.
// Do not mistake preflight/single-tool probes or translated Chat requests for a full snapshot.
export async function ensureToolsSnapshot(filename, logRoot) {
	try {
		return await readToolsSnapshot(filename);
	} catch {
		if (!logRoot) throw new Error('Tool snapshot unavailable.');
	}
	const directories = await readdir(logRoot, { withFileTypes: true });
	const days = directories
		.filter((entry) => entry.isDirectory() && /^\d{4}-\d{2}-\d{2}$/.test(entry.name))
		.map((entry) => entry.name)
		.sort()
		.reverse()
		.slice(0, 7);
	for (const day of days) {
		const entries = await readdir(path.join(logRoot, day));
		for (const entry of entries
			.filter((name) => name.endsWith('.json'))
			.sort()
			.reverse()
			.slice(0, 200)) {
			let snapshot;
			try {
				const source = path.join(logRoot, day, entry);
				const info = await stat(source);
				if (info.size > 32 * 1024 * 1024) continue;
				const content = await readFile(source, 'utf8');
				const record = JSON.parse(content);
				const tools = record.requestBody?.tools;
				if (
					record.summary?.sourceFormat !== 'openai-responses' ||
					record.summary.path !== '/v1/responses' ||
					!Array.isArray(tools) ||
					!tools.some((tool) => tool.type === 'namespace') ||
					!tools.some((tool) => ['apply_patch', 'shell_command', 'exec_command', 'exec'].includes(tool.name))
				)
					continue;
				validateTools(tools);
				if (!record.summary.model || !Number.isFinite(Date.parse(record.summary.timestamp))) continue;
				snapshot = {
					version: 1,
					capturedAt: record.summary.timestamp,
					sourceModel: record.summary.model,
					source: { kind: 'omniroute-log', file: `${day}/${entry}` },
					schemaHash: schemaHash(tools),
					tools
				};
			} catch {
				continue;
			}
			await writeJsonAtomic(filename, snapshot);

			return snapshot;
		}
	}
	throw new Error('No original Codex Responses tool snapshot found.');
}
