import { createHash, randomUUID } from 'node:crypto';
import { chmod, lstat, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, parse as parsePath, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const SERVER_NAME = 'ungate_patch';
const SERVER_VERSION = '1.0.0';
const DEFAULT_MAX_PATCH_BYTES = 8 * 1024 * 1024;
const DEFAULT_MAX_FILE_BYTES = 32 * 1024 * 1024;
const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf]);
const UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });
const PATCH_BEGIN = '*** Begin Patch';
const PATCH_END = '*** End Patch';
const END_OF_FILE = '*** End of File';
const DEVICE_PATH_PATTERN = /^\\\\[.?]\\/u;
const ADD_FILE_REMEDIATION = [
	'For Add File, copy this exact grammar and replace only the path and content:',
	'*** Begin Patch',
	'*** Add File: relative/path',
	'+content',
	'*** End Patch',
	'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.'
].join('\n');
const UPDATE_FILE_REMEDIATION = [
	'For Update File, copy this exact grammar and replace only the path and lines:',
	'*** Begin Patch',
	'*** Update File: relative/path',
	'@@',
	' unchanged context',
	'-removed line',
	'+added line',
	'*** End Patch',
	'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.'
].join('\n');

export class PatchError extends Error {
	constructor(code, message, details = {}) {
		super(message);
		this.name = 'PatchError';
		this.code = code;
		this.details = details;
	}
}

function fail(code, message, details) {
	throw new PatchError(code, message, details);
}

function remediationFor(patchError) {
	const remediationByCode = {
		no_change_hunk: "Add at least one '-' or '+' line to every Update File hunk, or remove the unchanged operation.",
		invalid_patch_header:
			'Use only the exact supported headers: *** Begin Patch, *** End Patch, *** Add File: path, *** Update File: path, *** Delete File: path, and *** Move to: path.\n' +
			ADD_FILE_REMEDIATION +
			'\n' +
			UPDATE_FILE_REMEDIATION
	};
	const remediation = remediationByCode[patchError.code];
	if (remediation) {
		return remediation;
	}

	if (patchError.code === 'invalid_patch') {
		if (patchError.message.includes('Add File')) {
			return ADD_FILE_REMEDIATION;
		}

		if (patchError.message.includes('Invalid update line')) {
			return UPDATE_FILE_REMEDIATION;
		}
	}

	return undefined;
}

function byteLength(value) {
	return Buffer.byteLength(value, 'utf8');
}

function hashBuffer(buffer) {
	return createHash('sha256').update(buffer).digest('hex');
}

function pathKey(value) {
	return resolve(value).toLocaleLowerCase('en-US');
}

function isMissingError(error) {
	return error && typeof error === 'object' && error.code === 'ENOENT';
}

async function lstatIfExists(targetPath) {
	try {
		return await lstat(targetPath);
	} catch (error) {
		if (isMissingError(error)) {
			return null;
		}
		throw error;
	}
}

function isPathInside(parentPath, candidatePath) {
	const relativePath = relative(parentPath, candidatePath);

	return relativePath === '' || (!relativePath.startsWith(`..${sep}`) && relativePath !== '..' && !isAbsolute(relativePath));
}

function assertNonDevicePath(targetPath, label) {
	if (DEVICE_PATH_PATTERN.test(targetPath)) {
		fail('device_path_rejected', `${label} must not use a Windows device path.`, { path: targetPath });
	}
}

function normalizePatchPath(rawPath, label = 'Patch path') {
	if (typeof rawPath !== 'string' || rawPath.length === 0) {
		fail('invalid_path', `${label} is empty.`);
	}
	if (rawPath.includes('\0')) {
		fail('invalid_path', `${label} contains a null character.`);
	}

	const normalizedSlashes = rawPath.replaceAll('\\', '/');
	assertNonDevicePath(rawPath, label);
	if (isAbsolute(rawPath) || /^[a-zA-Z]:/u.test(rawPath) || normalizedSlashes.startsWith('//')) {
		fail('absolute_path_rejected', `${label} must be relative to working_directory.`, { path: rawPath });
	}

	const segments = normalizedSlashes.split('/');
	while (segments[0] === '.') {
		segments.shift();
	}
	if (segments.length === 0 || segments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')) {
		fail('path_traversal_rejected', `${label} contains an unsafe path segment.`, { path: rawPath });
	}
	if (segments.some((segment) => segment.includes(':'))) {
		fail('invalid_path', `${label} contains a colon and could address an alternate data stream.`, { path: rawPath });
	}

	return segments.join('/');
}

function operationBoundary(line) {
	return line === PATCH_END || /^\*\*\* (?:Add|Delete|Update) File: /u.test(line);
}

function normalizeDecoratedSentinel(line) {
	switch (line) {
		case `${PATCH_BEGIN} ***`:
			return PATCH_BEGIN;
		case `${PATCH_END} ***`:
			return PATCH_END;
		case `${END_OF_FILE} ***`:
			return END_OF_FILE;
		default:
			return line;
	}
}

function unwrapPatchEnvelope(patch) {
	let normalized = patch.replace(/^\uFEFF/u, '').trim();
	const markdownMatch = /^```(?:diff|patch)?[ \t]*\r?\n([\s\S]*?)\r?\n```$/iu.exec(normalized);
	if (markdownMatch) {
		normalized = markdownMatch[1].trim();
	}
	const xmlMatch = /^<patch>\s*([\s\S]*?)\s*<\/patch>$/iu.exec(normalized);
	if (xmlMatch) {
		normalized = xmlMatch[1].trim();
	}

	return normalized;
}

function parseUpdateBody(lines, startIndex, sourcePath) {
	let index = startIndex;
	let movePath = null;
	const chunks = [];
	let currentChunk = null;

	if (lines[index]?.startsWith('*** Move to: ')) {
		movePath = normalizePatchPath(lines[index].slice('*** Move to: '.length), 'Move destination');
		index += 1;
	}

	while (index < lines.length && !operationBoundary(lines[index])) {
		const line = lines[index];
		if (line.startsWith('*** Move to: ')) {
			fail('invalid_patch', `Move destination for '${sourcePath}' must immediately follow the Update File header.`);
		}
		if (line === END_OF_FILE) {
			if (!currentChunk || currentChunk.lines.length === 0 || currentChunk.endOfFile) {
				fail('invalid_patch', `Unexpected ${END_OF_FILE} marker for '${sourcePath}'.`);
			}
			currentChunk.endOfFile = true;
			index += 1;
			if (index < lines.length && !operationBoundary(lines[index])) {
				fail('invalid_patch', `${END_OF_FILE} must end the update body for '${sourcePath}'.`);
			}
			continue;
		}
		if (line === '@@' || line.startsWith('@@ ')) {
			currentChunk = {
				anchor: line === '@@' ? null : line.slice(3),
				endOfFile: false,
				lines: []
			};
			chunks.push(currentChunk);
			index += 1;
			continue;
		}
		if (![' ', '+', '-'].includes(line[0])) {
			fail('invalid_patch', `Invalid update line for '${sourcePath}': every line must start with space, +, or -.`, {
				line: index + 1
			});
		}
		if (!currentChunk) {
			currentChunk = { anchor: null, endOfFile: false, lines: [] };
			chunks.push(currentChunk);
		}
		currentChunk.lines.push({ marker: line[0], text: line.slice(1) });
		index += 1;
	}

	for (const chunk of chunks) {
		if (chunk.lines.length === 0) {
			fail('invalid_patch', `Empty update hunk for '${sourcePath}'.`);
		}
		if (!chunk.lines.some((line) => line.marker === '+' || line.marker === '-')) {
			fail('no_change_hunk', `Update hunk for '${sourcePath}' does not change any lines.`);
		}
	}
	if (chunks.length === 0 && !movePath) {
		fail('invalid_patch', `Update operation for '${sourcePath}' has neither hunks nor a move destination.`);
	}

	return { chunks, movePath, nextIndex: index };
}

export function parsePatch(patch, { maxPatchBytes = DEFAULT_MAX_PATCH_BYTES } = {}) {
	if (typeof patch !== 'string' || patch.length === 0) {
		fail('invalid_patch', 'patch must be a non-empty string.');
	}
	if (!Number.isSafeInteger(maxPatchBytes) || maxPatchBytes <= 0) {
		fail('invalid_limit', 'maxPatchBytes must be a positive safe integer.');
	}
	if (byteLength(patch) > maxPatchBytes) {
		fail('patch_too_large', `Patch exceeds the ${maxPatchBytes}-byte limit.`);
	}
	if (patch.includes('\0')) {
		fail('invalid_patch', 'Patch contains a null character.');
	}

	const normalized = unwrapPatchEnvelope(patch).replaceAll('\r\n', '\n');
	if (normalized.includes('\r')) {
		fail('invalid_patch', 'Patch contains unsupported lone carriage returns.');
	}
	const lines = normalized.split('\n').map(normalizeDecoratedSentinel);
	if (lines.at(-1) === '') {
		lines.pop();
	}
	if (lines[0] !== PATCH_BEGIN || lines.at(-1) !== PATCH_END) {
		fail('invalid_patch', `Patch must start with '${PATCH_BEGIN}' and end with '${PATCH_END}'.`);
	}

	const operations = [];
	const claimedPaths = new Set();
	let index = 1;
	while (index < lines.length - 1) {
		const header = lines[index];
		let match = /^\*\*\* Add File: (.+)$/u.exec(header);
		if (match) {
			const targetPath = normalizePatchPath(match[1], 'Add path');
			const contentLines = [];
			index += 1;
			while (index < lines.length && !operationBoundary(lines[index])) {
				const line = lines[index];
				if (!line.startsWith('+')) {
					fail('invalid_patch', `Every Add File content line for '${targetPath}' must start with +.`, {
						line: index + 1
					});
				}
				contentLines.push(line.slice(1));
				index += 1;
			}
			if (contentLines.length === 0) {
				fail('invalid_patch', `Add File operation for '${targetPath}' must contain at least one + line.`);
			}
			operations.push({ kind: 'add', path: targetPath, content: `${contentLines.join('\n')}\n` });
			continue;
		}

		match = /^\*\*\* Delete File: (.+)$/u.exec(header);
		if (match) {
			const targetPath = normalizePatchPath(match[1], 'Delete path');
			operations.push({ kind: 'delete', path: targetPath });
			index += 1;
			if (index < lines.length && !operationBoundary(lines[index])) {
				fail('invalid_patch', `Delete File operation for '${targetPath}' must not contain body lines.`);
			}
			continue;
		}

		match = /^\*\*\* Update File: (.+)$/u.exec(header);
		if (match) {
			const targetPath = normalizePatchPath(match[1], 'Update path');
			const parsedUpdate = parseUpdateBody(lines, index + 1, targetPath);
			operations.push({
				kind: 'update',
				path: targetPath,
				movePath: parsedUpdate.movePath,
				chunks: parsedUpdate.chunks
			});
			index = parsedUpdate.nextIndex;
			continue;
		}

		fail('invalid_patch_header', `Unexpected patch header at line ${index + 1}.`);
	}
	if (operations.length === 0) {
		fail('invalid_patch', 'Patch contains no file operations.');
	}

	for (const operation of operations) {
		for (const pathValue of [operation.path, operation.movePath].filter(Boolean)) {
			const key = pathValue.toLocaleLowerCase('en-US');
			if (claimedPaths.has(key)) {
				fail('path_conflict', `Patch addresses '${pathValue}' more than once.`);
			}
			claimedPaths.add(key);
		}
	}

	return operations;
}

function decodeTextFile(buffer, filePath, maxFileBytes) {
	if (buffer.length > maxFileBytes) {
		fail('file_too_large', `'${filePath}' exceeds the ${maxFileBytes}-byte limit.`, { path: filePath });
	}

	const hasBom = buffer.subarray(0, UTF8_BOM.length).equals(UTF8_BOM);
	const payload = hasBom ? buffer.subarray(UTF8_BOM.length) : buffer;
	let text;
	try {
		text = UTF8_DECODER.decode(payload);
	} catch {
		fail('invalid_utf8', `'${filePath}' is not valid UTF-8 text.`, { path: filePath });
	}
	if (text.includes('\0')) {
		fail('binary_file_rejected', `'${filePath}' contains null bytes and is treated as binary.`, { path: filePath });
	}
	if (/\r(?!\n)/u.test(text)) {
		fail('unsupported_newlines', `'${filePath}' contains lone carriage returns.`, { path: filePath });
	}

	const crlfCount = text.match(/\r\n/gu)?.length ?? 0;
	const loneLfCount = text.replaceAll('\r\n', '').match(/\n/gu)?.length ?? 0;
	if (crlfCount > 0 && loneLfCount > 0) {
		fail('mixed_newlines', `'${filePath}' mixes CRLF and LF line endings.`, { path: filePath });
	}

	return {
		bom: hasBom,
		finalNewline: text.endsWith('\n'),
		newline: crlfCount > 0 ? '\r\n' : '\n',
		text: text.replaceAll('\r\n', '\n')
	};
}

function encodeTextFile(textFile, normalizedText) {
	const body = Buffer.from(normalizedText.replaceAll('\n', textFile.newline), 'utf8');

	return textFile.bom ? Buffer.concat([UTF8_BOM, body]) : body;
}

function splitNormalizedText(text) {
	const finalNewline = text.endsWith('\n');
	const lines = text.split('\n');
	if (finalNewline) {
		lines.pop();
	}

	return { finalNewline, lines };
}

function findLine(lines, expected, startIndex) {
	for (let index = startIndex; index < lines.length; index += 1) {
		if (lines[index] === expected) {
			return index;
		}
	}

	return -1;
}

function sequenceMatches(lines, expected, startIndex) {
	if (startIndex + expected.length > lines.length) {
		return false;
	}

	return expected.every((line, offset) => lines[startIndex + offset] === line);
}

function findSequence(lines, expected, startIndex) {
	for (let index = startIndex; index <= lines.length - expected.length; index += 1) {
		if (sequenceMatches(lines, expected, index)) {
			return index;
		}
	}

	return -1;
}

function applyUpdateChunks(textFile, chunks, displayPath) {
	const split = splitNormalizedText(textFile.text);
	const lines = split.lines;
	let cursor = 0;

	for (const [chunkIndex, chunk] of chunks.entries()) {
		if (chunk.anchor !== null) {
			const anchorIndex = findLine(lines, chunk.anchor, cursor);
			if (anchorIndex < 0) {
				fail('anchor_not_found', `Anchor for hunk ${chunkIndex + 1} was not found in '${displayPath}'.`, {
					path: displayPath,
					hunk: chunkIndex + 1
				});
			}
			cursor = anchorIndex + 1;
		}

		const oldLines = chunk.lines.filter((line) => line.marker !== '+').map((line) => line.text);
		const newLines = chunk.lines.filter((line) => line.marker !== '-').map((line) => line.text);
		let matchIndex;
		if (oldLines.length === 0) {
			matchIndex = chunk.endOfFile ? lines.length : cursor;
		} else if (chunk.endOfFile) {
			matchIndex = lines.length - oldLines.length;
			if (matchIndex < cursor || !sequenceMatches(lines, oldLines, matchIndex)) {
				matchIndex = -1;
			}
		} else {
			matchIndex = findSequence(lines, oldLines, cursor);
		}
		if (matchIndex < 0) {
			fail('hunk_not_found', `Exact context for hunk ${chunkIndex + 1} was not found in '${displayPath}'.`, {
				path: displayPath,
				hunk: chunkIndex + 1
			});
		}

		lines.splice(matchIndex, oldLines.length, ...newLines);
		const trailingContextCount = [...chunk.lines].reverse().findIndex((line) => line.marker !== ' ');
		const reusableContext = trailingContextCount < 0 ? chunk.lines.length : trailingContextCount;
		cursor = Math.max(matchIndex, matchIndex + newLines.length - reusableContext);
	}

	return `${lines.join('\n')}${split.finalNewline ? '\n' : ''}`;
}

async function assertNoReparsePoints(targetPath, { includeLeaf = true } = {}) {
	const absolutePath = resolve(targetPath);
	const root = parsePath(absolutePath).root;
	const pathSegments = relative(root, absolutePath).split(sep).filter(Boolean);
	let currentPath = root;

	for (let index = 0; index < pathSegments.length; index += 1) {
		currentPath = join(currentPath, pathSegments[index]);
		if (!includeLeaf && index === pathSegments.length - 1) {
			break;
		}
		const item = await lstatIfExists(currentPath);
		if (!item) {
			break;
		}
		if (item.isSymbolicLink()) {
			fail('reparse_point_rejected', `'${currentPath}' is a symbolic link or junction.`, { path: currentPath });
		}
	}
}

async function validateWorkingDirectory(workingDirectory, allowRoots) {
	if (typeof workingDirectory !== 'string' || !isAbsolute(workingDirectory)) {
		fail('invalid_working_directory', 'working_directory must be an absolute path.');
	}
	assertNonDevicePath(workingDirectory, 'working_directory');
	const resolvedWorkingDirectory = resolve(workingDirectory);
	const workingDirectoryStats = await lstatIfExists(resolvedWorkingDirectory);
	if (!workingDirectoryStats?.isDirectory()) {
		fail('invalid_working_directory', `'${resolvedWorkingDirectory}' is not an existing directory.`);
	}
	await assertNoReparsePoints(resolvedWorkingDirectory);

	if (!allowRoots.includes('*')) {
		const allowed = allowRoots.some((rootPath) => isPathInside(rootPath, resolvedWorkingDirectory));
		if (!allowed) {
			fail('working_directory_not_allowed', `'${resolvedWorkingDirectory}' is outside the configured allow roots.`);
		}
	}

	return resolvedWorkingDirectory;
}

function resolveOperationPath(workingDirectory, patchPath) {
	const resolvedPath = resolve(workingDirectory, ...patchPath.split('/'));
	if (!isPathInside(workingDirectory, resolvedPath)) {
		fail('path_traversal_rejected', `'${patchPath}' resolves outside working_directory.`, { path: patchPath });
	}
	assertNonDevicePath(resolvedPath, 'Resolved path');

	return resolvedPath;
}

async function readSnapshot(filePath, displayPath, maxFileBytes) {
	await assertNoReparsePoints(filePath);
	const fileStats = await lstatIfExists(filePath);
	if (!fileStats?.isFile()) {
		fail('file_not_found', `'${displayPath}' is not an existing regular file.`, { path: displayPath });
	}
	const buffer = await readFile(filePath);
	const textFile = decodeTextFile(buffer, displayPath, maxFileBytes);

	return {
		buffer,
		hash: hashBuffer(buffer),
		mode: fileStats.mode,
		textFile
	};
}

async function assertParentDirectory(targetPath) {
	const parentPath = dirname(targetPath);
	await assertNoReparsePoints(parentPath);
	const parentStats = await lstatIfExists(parentPath);
	if (!parentStats?.isDirectory()) {
		fail('parent_directory_missing', `Parent directory '${parentPath}' does not exist or is not a directory.`, {
			path: parentPath
		});
	}
}

async function assertAbsent(targetPath, displayPath) {
	await assertNoReparsePoints(targetPath, { includeLeaf: false });
	const targetExists = await lstatIfExists(targetPath);
	if (targetExists) {
		fail('target_exists', `'${displayPath}' already exists.`, { path: displayPath });
	}
}

async function prepareOperations(workingDirectory, operations, maxFileBytes) {
	const prepared = [];
	const absoluteClaims = new Set();

	for (const operation of operations) {
		const sourcePath = resolveOperationPath(workingDirectory, operation.path);
		const targetPath = operation.movePath ? resolveOperationPath(workingDirectory, operation.movePath) : sourcePath;
		for (const claimedPath of new Set([sourcePath, targetPath])) {
			const key = pathKey(claimedPath);
			if (absoluteClaims.has(key)) {
				fail('path_conflict', `Patch resolves multiple operations to '${claimedPath}'.`);
			}
			absoluteClaims.add(key);
		}

		if (operation.kind === 'add') {
			await assertParentDirectory(targetPath);
			await assertAbsent(targetPath, operation.path);
			const outputBuffer = Buffer.from(operation.content, 'utf8');
			if (outputBuffer.length > maxFileBytes) {
				fail('file_too_large', `'${operation.path}' would exceed the ${maxFileBytes}-byte limit.`);
			}
			prepared.push({
				kind: 'add',
				displayPath: operation.path,
				sourcePath: null,
				targetPath,
				snapshot: null,
				outputBuffer
			});
			continue;
		}

		const snapshot = await readSnapshot(sourcePath, operation.path, maxFileBytes);
		if (operation.kind === 'delete') {
			prepared.push({
				kind: 'delete',
				displayPath: operation.path,
				sourcePath,
				targetPath: null,
				snapshot,
				outputBuffer: null
			});
			continue;
		}

		if (operation.movePath) {
			await assertParentDirectory(targetPath);
			await assertAbsent(targetPath, operation.movePath);
		}
		const updatedText = applyUpdateChunks(snapshot.textFile, operation.chunks, operation.path);
		const outputBuffer = encodeTextFile(snapshot.textFile, updatedText);
		if (outputBuffer.length > maxFileBytes) {
			fail('file_too_large', `'${operation.movePath ?? operation.path}' would exceed the ${maxFileBytes}-byte limit.`);
		}
		prepared.push({
			kind: operation.movePath ? 'move' : 'update',
			displayPath: operation.path,
			displayTargetPath: operation.movePath ?? null,
			sourcePath,
			targetPath,
			snapshot,
			outputBuffer
		});
	}

	return prepared;
}

async function verifyPreparedState(prepared) {
	for (const item of prepared) {
		if (item.snapshot) {
			const currentBuffer = await readFile(item.sourcePath).catch((error) => {
				if (isMissingError(error)) {
					fail('concurrent_change', `'${item.displayPath}' disappeared before commit.`);
				}
				throw error;
			});
			if (hashBuffer(currentBuffer) !== item.snapshot.hash) {
				fail('concurrent_change', `'${item.displayPath}' changed before commit.`);
			}
		}
		if (item.targetPath && (!item.sourcePath || pathKey(item.targetPath) !== pathKey(item.sourcePath))) {
			await assertAbsent(item.targetPath, item.displayTargetPath ?? item.displayPath);
		}
	}
}

function operationSummary(item) {
	const summary = { operation: item.kind, path: item.displayPath };
	if (item.displayTargetPath) {
		summary.destination = item.displayTargetPath;
	}

	return summary;
}

async function stageOutputs(prepared, transactionId) {
	const stagedPaths = [];

	try {
		for (const item of prepared) {
			if (!item.outputBuffer) {
				continue;
			}
			item.temporaryPath = join(dirname(item.targetPath), `.${basename(item.targetPath)}.ungate-patch-${transactionId}.tmp`);
			stagedPaths.push(item.temporaryPath);
			await writeFile(item.temporaryPath, item.outputBuffer, {
				flag: 'wx',
				mode: item.snapshot?.mode
			});
			if (item.snapshot?.mode !== undefined) {
				await chmod(item.temporaryPath, item.snapshot.mode);
			}
		}
	} catch (error) {
		await cleanupPaths(stagedPaths);
		throw error;
	}
}

async function cleanupPaths(paths) {
	const errors = [];
	for (const targetPath of paths.filter(Boolean)) {
		try {
			await rm(targetPath, { force: true });
		} catch (error) {
			errors.push(error);
		}
	}

	return errors;
}

async function rollbackOperations(states) {
	const rollbackErrors = [];
	for (const state of [...states].reverse()) {
		try {
			if (state.targetCreated) {
				await rm(state.item.targetPath, { force: true });
			}
			const backupExists = state.backupPath ? await lstatIfExists(state.backupPath) : null;
			if (backupExists) {
				await rename(state.backupPath, state.item.sourcePath);
			}
		} catch (error) {
			rollbackErrors.push(error);
		}
	}

	return rollbackErrors;
}

async function commitPreparedOperations(prepared, transactionId, testHooks) {
	const states = [];
	await verifyPreparedState(prepared);
	await stageOutputs(prepared, transactionId);

	try {
		for (const [index, item] of prepared.entries()) {
			const state = { item, backupPath: null, targetCreated: false };
			states.push(state);
			await testHooks?.beforeCommitOperation?.(index, item);

			if (item.sourcePath) {
				state.backupPath = join(dirname(item.sourcePath), `.${basename(item.sourcePath)}.ungate-patch-${transactionId}.bak`);
				await rename(item.sourcePath, state.backupPath);
			}
			if (item.temporaryPath) {
				await rename(item.temporaryPath, item.targetPath);
				item.temporaryPath = null;
				state.targetCreated = true;
			}
		}
	} catch (error) {
		const rollbackErrors = await rollbackOperations(states);
		await cleanupPaths(prepared.map((item) => item.temporaryPath));
		if (rollbackErrors.length > 0) {
			fail('rollback_failed', 'Patch commit failed and automatic rollback was incomplete.', {
				rollbackErrors: rollbackErrors.length
			});
		}
		if (error instanceof PatchError) {
			throw error;
		}
		fail('commit_failed', `Patch commit failed and was rolled back: ${error.message}`);
	}

	const cleanupErrors = await cleanupPaths(states.map((state) => state.backupPath));
	await cleanupPaths(prepared.map((item) => item.temporaryPath));
	if (cleanupErrors.length > 0) {
		fail('backup_cleanup_failed', 'Patch was applied, but one or more transaction backups could not be removed.', {
			cleanupErrors: cleanupErrors.length
		});
	}
}

function normalizeAllowRoots(allowRoots) {
	if (!Array.isArray(allowRoots) || allowRoots.length === 0) {
		fail('missing_allow_root', 'At least one --allow-root value is required.');
	}
	if (allowRoots.includes('*')) {
		return ['*'];
	}

	return allowRoots.map((rootPath) => {
		if (typeof rootPath !== 'string' || !isAbsolute(rootPath)) {
			fail('invalid_allow_root', `Allow root '${rootPath}' must be an absolute path or '*'.`);
		}
		assertNonDevicePath(rootPath, 'Allow root');

		return resolve(rootPath);
	});
}

export async function applyPatchTransaction(
	{ workingDirectory, patch, dryRun = false },
	{ allowRoots = [], maxPatchBytes = DEFAULT_MAX_PATCH_BYTES, maxFileBytes = DEFAULT_MAX_FILE_BYTES, testHooks } = {}
) {
	if (typeof dryRun !== 'boolean') {
		fail('invalid_dry_run', 'dry_run must be a boolean.');
	}
	if (!Number.isSafeInteger(maxFileBytes) || maxFileBytes <= 0) {
		fail('invalid_limit', 'maxFileBytes must be a positive safe integer.');
	}

	const normalizedAllowRoots = normalizeAllowRoots(allowRoots);
	const resolvedWorkingDirectory = await validateWorkingDirectory(workingDirectory, normalizedAllowRoots);
	const operations = parsePatch(patch, { maxPatchBytes });
	const prepared = await prepareOperations(resolvedWorkingDirectory, operations, maxFileBytes);
	const result = {
		dry_run: dryRun,
		operations: prepared.map(operationSummary),
		changed_files: prepared.length
	};

	if (!dryRun) {
		await commitPreparedOperations(prepared, randomUUID().replaceAll('-', ''), testHooks);
	}

	return result;
}

export function parseServerOptions(argumentsList) {
	const allowRoots = [];
	let maxPatchBytes = DEFAULT_MAX_PATCH_BYTES;
	let maxFileBytes = DEFAULT_MAX_FILE_BYTES;

	for (let index = 0; index < argumentsList.length; index += 1) {
		const argument = argumentsList[index];
		const value = argumentsList[index + 1];
		if (argument === '--allow-root') {
			if (value === undefined) {
				fail('invalid_arguments', '--allow-root requires a value.');
			}
			allowRoots.push(value);
			index += 1;
			continue;
		}
		if (argument === '--max-patch-bytes' || argument === '--max-file-bytes') {
			if (value === undefined || !/^[1-9]\d*$/u.test(value)) {
				fail('invalid_arguments', `${argument} requires a positive integer.`);
			}
			const parsedValue = Number(value);
			if (!Number.isSafeInteger(parsedValue)) {
				fail('invalid_arguments', `${argument} exceeds JavaScript's safe integer range.`);
			}
			if (argument === '--max-patch-bytes') {
				maxPatchBytes = parsedValue;
			} else {
				maxFileBytes = parsedValue;
			}
			index += 1;
			continue;
		}
		fail('invalid_arguments', `Unknown argument '${argument}'.`);
	}

	return {
		allowRoots: normalizeAllowRoots(allowRoots),
		maxFileBytes,
		maxPatchBytes
	};
}

function errorResult(error) {
	const patchError =
		error instanceof PatchError ? error : new PatchError('internal_error', `Unexpected patch server error: ${error.message}`);
	const payload = {
		ok: false,
		error: {
			code: patchError.code,
			message: patchError.message
		}
	};
	const remediation = remediationFor(patchError);
	if (remediation) {
		payload.error.remediation = remediation;
	}

	return {
		isError: true,
		content: [{ type: 'text', text: JSON.stringify(payload) }]
	};
}

export function createPatchMcpServer(options) {
	const normalizedOptions = {
		...options,
		allowRoots: normalizeAllowRoots(options.allowRoots)
	};
	const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });
	let operationQueue = Promise.resolve();

	server.registerTool(
		'apply_patch',
		{
			title: 'Apply source patch',
			description: [
				'Apply a native-style patch transactionally when the native Codex apply_patch tool is unavailable.',
				'The first and last lines must be the exact sentinels *** Begin Patch and *** End Patch.',
				'Use only plain-text Add File, Update File, Delete File, and Move to headers; do not wrap headers in Markdown emphasis.',
				ADD_FILE_REMEDIATION,
				UPDATE_FILE_REMEDIATION,
				'Every Update File hunk must contain at least one - or + line; context-only hunks are invalid.'
			].join('\n'),
			inputSchema: {
				working_directory: z.string().min(1).describe('Absolute Windows working directory. Patch paths are relative to it.'),
				patch: z
					.string()
					.min(1)
					.describe(
						[
							'Exact native patch text. First line: *** Begin Patch. Last line: *** End Patch. Headers are plain text with no Markdown emphasis.',
							ADD_FILE_REMEDIATION,
							UPDATE_FILE_REMEDIATION,
							'Every Update File hunk must include at least one - or + line; context-only hunks are invalid.'
						].join('\n')
					),
				dry_run: z.boolean().optional().default(false).describe('Validate and summarize without changing files.')
			},
			annotations: {
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: false
			}
		},
		async ({ working_directory: workingDirectory, patch, dry_run: dryRun = false }) => {
			const run = operationQueue.then(() => applyPatchTransaction({ workingDirectory, patch, dryRun }, normalizedOptions));
			operationQueue = run.catch(() => undefined);
			try {
				const result = await run;

				return {
					content: [{ type: 'text', text: JSON.stringify({ ok: true, ...result }) }]
				};
			} catch (error) {
				return errorResult(error);
			}
		}
	);

	return server;
}

export async function runStdioServer(argumentsList = process.argv.slice(2)) {
	const options = parseServerOptions(argumentsList);
	const server = createPatchMcpServer(options);
	const transport = new StdioServerTransport();
	await server.connect(transport);
}

const entryPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null;
if (entryPath === import.meta.url) {
	runStdioServer().catch((error) => {
		const code = error instanceof PatchError ? error.code : 'startup_failed';
		console.error(`[${SERVER_NAME}] ${code}: ${error.message}`);
		process.exitCode = 1;
	});
}
