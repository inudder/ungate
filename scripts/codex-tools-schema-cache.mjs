import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
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
