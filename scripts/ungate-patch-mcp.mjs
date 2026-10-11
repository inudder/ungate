import { createHash, randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, readFile, rename, rm, rmdir, writeFile } from 'node:fs/promises';
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
const EXEC_PATCH_AUTHORING = [
	'When building a patch in exec, every array item must be a JavaScript string. Put patch markers inside the quotes: "+];", "@@", "-old", "+new". Never write +"...": unary + converts the string to a number before apply_patch sees it.',
	'Before joining, validate the array: if (patchLines.some((line) => typeof line !== "string")) throw new Error("Patch lines must all be strings");',
	'Join with patchLines.join(String.fromCharCode(10)), call this same apply_patch tool, and pass its result to text(...).'
].join('\n');
const NUMERIC_COERCION_REMEDIATION = [
	'The patch contains a bare NaN line. A likely cause is unary + outside a JavaScript string in the exec array, such as +"];" instead of "+];".',
	'The original line content was lost before validation. Rebuild all affected array entries as strings and retry this same apply_patch tool. Splitting the patch does not fix the coercion.',
	EXEC_PATCH_AUTHORING
].join('\n');
const ADD_FILE_REMEDIATION = [
	'For Add File, copy this exact grammar and replace only the path and content:',
	'*** Begin Patch',
	'*** Add File: relative/path',
	'+content',
	'*** End Patch',
	'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.',
	'If validation returns invalid_patch for a missing +, rebuild the affected Add File body and call apply_patch again; do not use shell edits.'
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
	'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.',
	'The first character is the marker. After it, copy the exact file line including its indent; file indent is not the marker, so a copied indented line needs one extra leading space.'
].join('\n');

const OPERATION_RULES = [
	'Every Update File needs at least one - or + line. A context-only @@ section between changing hunks only moves the search position.',
	'To replace a whole existing file, write *** Delete File: path followed by *** Add File: path in one patch. Add File alone never overwrites.',
	'Missing parent directories of Add File and Move to targets are created.'
].join('\n');

const CONTEXT_MISMATCH_REMEDIATION = [
	'The message names the patch line that does not match the live file and quotes the file line found there. Fix the hunk from the live lines and retry this same apply_patch tool once.',
	'Do not switch to native apply_patch, a different exec wrapper, or Shell. Do not reuse a hunk that already applied.',
	'If exec output is empty (Wall time 0.0s), you forgot text(result); the UI result is authoritative.',
	'Context before and after the + lines must be different file lines. Do not repeat the line you insert next to on both sides of the insertion.'
].join('\n');
const TARGET_EXISTS_REMEDIATION = [
	'Add File creates a new file only.',
	'To replace an existing file completely, put *** Delete File: path and then *** Add File: path for the same path in one patch. The replacement is atomic.',
	'To change part of the file, use Update File hunks.'
].join('\n');
const PATH_CONFLICT_REMEDIATION = [
	'Address each path once. Two forms are allowed for the same path:',
	'*** Delete File: path followed by *** Add File: path replaces the file atomically.',
	'Several *** Update File: path sections without Move to are applied in order.'
].join('\n');
const ESCAPED_NEWLINES_REMEDIATION = [
	'The patch arrived as one line that contains the two characters backslash and n instead of line breaks.',
	'Build the patch as an array of strings and join it with String.fromCharCode(10) instead of a backslash-n escape. Do not JSON.stringify the patch text.'
].join('\n');
const ADJUSTMENT_DESCRIPTIONS = {
	loose_whitespace:
		'matched after ignoring trailing whitespace and Unicode dash, quote, and space variants; file context was kept',
	missing_context_marker_space:
		'context lines were missing the marker space; matched them one space deeper and kept the file lines',
	extra_space_after_marker: 'every - and + line had a space after the marker; removed that space from the + lines'
};
const MAX_QUOTED_LINE_LENGTH = 160;

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
	if (patchError.code === 'invalid_patch' && patchError.details.reason === 'javascript_numeric_coercion') {
		return NUMERIC_COERCION_REMEDIATION;
	}

	if (patchError.code === 'invalid_patch' && patchError.details.reason === 'escaped_newlines') {
		return ESCAPED_NEWLINES_REMEDIATION;
	}

	const remediationByCode = {
		no_change_hunk:
			"This Update File has no '-' or '+' line in any hunk. Add the intended change, or remove the unchanged operation. A context-only @@ section is allowed only next to hunks that change lines.",
		hunk_not_found: CONTEXT_MISMATCH_REMEDIATION,
		anchor_not_found: CONTEXT_MISMATCH_REMEDIATION,
		target_exists:
			patchError.details.operation === 'add'
				? TARGET_EXISTS_REMEDIATION
				: 'Move to must name a path that does not exist yet. Delete or rename the occupying file in a separate step first.',
		path_conflict: PATH_CONFLICT_REMEDIATION,
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

function quoteLine(value) {
	if (value === undefined) {
		return '<end of file>';
	}
	const text = value.length > MAX_QUOTED_LINE_LENGTH ? `${value.slice(0, MAX_QUOTED_LINE_LENGTH)}...` : value;

	return JSON.stringify(text);
}

function leadingWhitespace(value) {
	return /^[ \t]*/u.exec(value)[0];
}

// Mirrors the fallback in Codex's native apply_patch: trailing whitespace and typographic
// dash, quote, and space variants do not count as differences. Leading indentation does.
function looseLine(value) {
	return value
		.trimEnd()
		.replace(/[‐-―−]/gu, '-')
		.replace(/[‘-‛]/gu, "'")
		.replace(/[“-‟]/gu, '"')
		.replace(/[  -   　]/gu, ' ');
}

function sameIgnoringIndent(left, right) {
	return looseLine(left).trimStart() === looseLine(right).trimStart();
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
	// A JSON-stringified line array is unambiguous: join it instead of rejecting it.
	if (normalized.startsWith('[') && normalized.endsWith(']')) {
		let parsedLines;
		try {
			parsedLines = JSON.parse(normalized);
		} catch {
			parsedLines = null;
		}
		if (
			Array.isArray(parsedLines) &&
			parsedLines.every((line) => typeof line === 'string') &&
			normalizeDecoratedSentinel(parsedLines[0]?.trim()) === PATCH_BEGIN
		) {
			normalized = parsedLines.join('\n').trim();
		}
	}

	return normalized;
}

function failInvalidBodyLine(line, lineNumber, sourcePath, operation) {
	if (line === 'NaN') {
		fail(
			'invalid_patch',
			`Invalid ${operation} line for '${sourcePath}' at patch line ${lineNumber}: found bare NaN, likely from JavaScript unary + outside a string.`,
			{ line: lineNumber, reason: 'javascript_numeric_coercion' }
		);
	}

	const message =
		operation === 'Add File'
			? `Every Add File content line for '${sourcePath}' must start with +; patch line ${lineNumber} is ${quoteLine(line)}.`
			: `Invalid update line for '${sourcePath}' at patch line ${lineNumber}: ${quoteLine(line)}. Every line must start with space, +, or -.`;
	fail('invalid_patch', message, { line: lineNumber });
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
		if (line === '') {
			let peek = index + 1;
			while (peek < lines.length && lines[peek] === '') {
				peek += 1;
			}
			const nextLine = lines[peek];
			const isTrailingOrBoundary =
				!currentChunk ||
				peek >= lines.length ||
				nextLine === '@@' ||
				Boolean(nextLine?.startsWith('@@ ')) ||
				Boolean(nextLine && operationBoundary(nextLine));
			if (isTrailingOrBoundary) {
				index += 1;
				continue;
			}
			currentChunk.lines.push({ marker: ' ', text: '', lineNumber: index + 1 });
			index += 1;
			continue;
		}
		if (![' ', '+', '-'].includes(line[0])) {
			failInvalidBodyLine(line, index + 1, sourcePath, 'Update File');
		}
		if (!currentChunk) {
			currentChunk = { anchor: null, endOfFile: false, lines: [] };
			chunks.push(currentChunk);
		}
		currentChunk.lines.push({ marker: line[0], text: line.slice(1), lineNumber: index + 1 });
		index += 1;
	}

	// A bare @@ with no lines is a no-op. An anchor-only or context-only section is kept: like native
	// Codex, it only moves the search position for the hunks after it.
	const keptChunks = chunks.filter((chunk) => chunk.lines.length > 0 || chunk.anchor !== null);
	if (keptChunks.length === 0 && !movePath) {
		fail('invalid_patch', `Update operation for '${sourcePath}' has neither hunks nor a move destination.`);
	}
	const changesLines = keptChunks.some((chunk) => chunk.lines.some((line) => line.marker === '+' || line.marker === '-'));
	if (!changesLines && !movePath) {
		fail('no_change_hunk', `Update File for '${sourcePath}' does not change any lines.`);
	}

	return { chunks: keptChunks, movePath, nextIndex: index };
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
	if (lines.length === 1 && /^\*\*\* Begin Patch(?: \*\*\*)?\\n/u.test(lines[0])) {
		fail('invalid_patch', 'Patch is a single line with literal \\n escape sequences instead of line breaks.', {
			reason: 'escaped_newlines'
		});
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
				if (line === '') {
					let peek = index + 1;
					while (peek < lines.length && lines[peek] === '') {
						peek += 1;
					}
					if (peek >= lines.length || operationBoundary(lines[peek])) {
						index += 1;
						continue;
					}
					contentLines.push('');
					index += 1;
					continue;
				}
				if (!line.startsWith('+')) {
					failInvalidBodyLine(line, index + 1, targetPath, 'Add File');
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

	const mergedOperations = mergeSamePathOperations(operations);
	for (const operation of mergedOperations) {
		for (const pathValue of [operation.path, operation.movePath].filter(Boolean)) {
			const key = pathValue.toLocaleLowerCase('en-US');
			if (claimedPaths.has(key)) {
				fail('path_conflict', `Patch addresses '${pathValue}' more than once.`);
			}
			claimedPaths.add(key);
		}
	}

	return mergedOperations;
}

// Delete File + Add File for one path is an atomic replace. Repeated Update File sections for one
// path apply in order, each searching from the top of the file as a separate native patch would.
function mergeSamePathOperations(operations) {
	const merged = [];
	const latestByPath = new Map();
	for (const operation of operations) {
		const key = operation.path.toLocaleLowerCase('en-US');
		const previous = latestByPath.get(key);
		if (previous?.kind === 'delete' && operation.kind === 'add') {
			previous.kind = 'replace';
			previous.content = operation.content;
			continue;
		}
		if (previous?.kind === 'update' && operation.kind === 'update' && !previous.movePath && !operation.movePath) {
			const [firstChunk, ...otherChunks] = operation.chunks;
			if (firstChunk) {
				previous.chunks.push({ ...firstChunk, resetCursor: true }, ...otherChunks);
			}
			continue;
		}
		merged.push(operation);
		if (!previous) {
			latestByPath.set(key, operation);
		}
	}

	return merged;
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

	// Every line keeps its own terminator, so a file that mixes CRLF and LF keeps both.
	// Inserted lines use the file's majority terminator.
	const lines = [];
	const endings = [];
	let crlfCount = 0;
	let lfCount = 0;
	let lineStart = 0;
	for (const match of text.matchAll(/\r?\n/gu)) {
		lines.push(text.slice(lineStart, match.index));
		endings.push(match[0]);
		if (match[0] === '\r\n') {
			crlfCount += 1;
		} else {
			lfCount += 1;
		}
		lineStart = match.index + match[0].length;
	}
	const finalNewline = text.length > 0 && lineStart === text.length;
	if (lineStart < text.length) {
		lines.push(text.slice(lineStart));
		endings.push('');
	}

	return {
		bom: hasBom,
		finalNewline,
		newline: crlfCount > lfCount ? '\r\n' : '\n',
		lines,
		endings
	};
}

function encodeTextFile(textFile, records) {
	const body = records
		.map((record, index) => {
			if (index === records.length - 1 && !textFile.finalNewline) {
				return record.text;
			}

			return record.text + (record.ending || textFile.newline);
		})
		.join('');
	const buffer = Buffer.from(body, 'utf8');

	return textFile.bom ? Buffer.concat([UTF8_BOM, buffer]) : buffer;
}

function chunkOldEntries(chunk) {
	return chunk.lines.filter((line) => line.marker !== '+');
}

function stripsMarkerSpace(entry, fileLine) {
	return entry.text.startsWith(' ') && looseLine(entry.text.slice(1)) === looseLine(fileLine);
}

// Fallbacks tried in order when the exact hunk is absent. Each must match exactly one location.
// Context lines always keep the live file text, so a fallback never rewrites unchanged lines.
const MATCH_FALLBACKS = [
	{
		adjustment: 'loose_whitespace',
		matches: (entry, fileLine) => looseLine(entry.text) === looseLine(fileLine)
	},
	{
		// The hunk copied indented file lines without the leading marker space.
		adjustment: 'missing_context_marker_space',
		matches: (entry, fileLine) =>
			looseLine(entry.text) === looseLine(fileLine) ||
			(entry.marker === ' ' && looseLine(` ${entry.text}`) === looseLine(fileLine))
	},
	{
		// The hunk wrote "- line" and "+ line" with a space after every change marker.
		adjustment: 'extra_space_after_marker',
		applies: (chunk) => {
			const changedLines = chunk.lines.filter((line) => line.marker !== ' ' && line.text.trim() !== '');

			return changedLines.some((line) => line.marker === '-') && changedLines.every((line) => line.text.startsWith(' '));
		},
		matches: (entry, fileLine) => {
			if (entry.marker === ' ') {
				return looseLine(entry.text) === looseLine(fileLine) || stripsMarkerSpace(entry, fileLine);
			}
			if (entry.text.trim() === '') {
				return fileLine.trim() === '';
			}

			return stripsMarkerSpace(entry, fileLine);
		}
	}
];

function locateChunk(lines, chunk, cursor) {
	const oldEntries = chunkOldEntries(chunk);
	if (oldEntries.length === 0) {
		return { index: chunk.endOfFile ? lines.length : cursor, length: 0, adjustment: null };
	}

	const firstStart = chunk.endOfFile ? lines.length - oldEntries.length : cursor;
	const lastStart = chunk.endOfFile ? firstStart : lines.length - oldEntries.length;
	if (firstStart < cursor) {
		return null;
	}
	const matchesAt = (start, matches) => oldEntries.every((entry, offset) => matches(entry, lines[start + offset]));

	for (let start = firstStart; start <= lastStart; start += 1) {
		if (matchesAt(start, (entry, fileLine) => entry.text === fileLine)) {
			return { index: start, length: oldEntries.length, adjustment: null };
		}
	}
	for (const fallback of MATCH_FALLBACKS) {
		if (fallback.applies && !fallback.applies(chunk)) {
			continue;
		}
		const starts = [];
		for (let start = firstStart; start <= lastStart && starts.length < 2; start += 1) {
			if (matchesAt(start, fallback.matches)) {
				starts.push(start);
			}
		}
		if (starts.length === 1) {
			return { index: starts[0], length: oldEntries.length, adjustment: fallback.adjustment };
		}
		if (starts.length > 1) {
			return { ambiguous: true };
		}
	}

	return null;
}

function findAnchor(lines, anchor, cursor) {
	const comparisons = [
		(fileLine) => fileLine === anchor,
		(fileLine) => looseLine(fileLine) === looseLine(anchor),
		(fileLine) => sameIgnoringIndent(fileLine, anchor)
	];
	for (const compare of comparisons) {
		for (let index = cursor; index < lines.length; index += 1) {
			if (compare(lines[index])) {
				return index;
			}
		}
	}

	return -1;
}

function failAnchorNotFound(lines, chunk, cursor, hunkNumber, displayPath) {
	const earlierIndex = findAnchor(lines.slice(0, cursor), chunk.anchor, 0);
	const position = cursor > 0 ? ` after line ${cursor}` : '';
	const earlier =
		earlierIndex >= 0
			? ` It exists at line ${earlierIndex + 1}, above where the previous hunk ended; hunks for one file must follow file order.`
			: '';
	fail(
		'anchor_not_found',
		`Anchor @@ ${quoteLine(chunk.anchor)} for hunk ${hunkNumber} was not found in '${displayPath}'${position}.${earlier}`,
		{
			path: displayPath,
			hunk: hunkNumber
		}
	);
}

function duplicatedInsertionContext(chunk) {
	return chunk.lines.find((line, index) => {
		if (line.marker !== ' ' || line.text.trim() === '') {
			return false;
		}
		let previous = index - 1;
		while (previous >= 0 && chunk.lines[previous].marker === '+') {
			previous -= 1;
		}

		return (
			previous >= 0 && previous < index - 1 && chunk.lines[previous].marker === ' ' && chunk.lines[previous].text === line.text
		);
	});
}

// Names the first patch line that disagrees with the live file, so one retry can fix it.
function failHunkNotFound(lines, chunk, cursor, hunkNumber, displayPath, ambiguous) {
	const oldEntries = chunkOldEntries(chunk);
	const fileKeys = lines.map((line) => looseLine(line).trimStart());
	const entryKeys = oldEntries.map((entry) => looseLine(entry.text).trimStart());
	let best = { start: -1, length: 0 };
	for (let start = 0; start < lines.length; start += 1) {
		let length = 0;
		while (length < oldEntries.length && start + length < lines.length && entryKeys[length] === fileKeys[start + length]) {
			length += 1;
		}
		if (length === 0 || !entryKeys.slice(0, length).some((key) => key !== '')) {
			continue;
		}
		if (length > best.length || (length === best.length && best.start < cursor && start >= cursor)) {
			best = { start, length };
		}
	}

	const prefix = `Hunk ${hunkNumber} for '${displayPath}' was not found`;
	const parts = [];
	let reportedLine;
	const indentOffset =
		best.length === oldEntries.length
			? oldEntries.findIndex((entry, index) => looseLine(entry.text) !== looseLine(lines[best.start + index]))
			: -1;
	if (ambiguous) {
		parts.push(
			`${prefix}: its lines match several places once trailing whitespace, Unicode punctuation, or a one-space marker offset is ignored. Add distinctive context.`
		);
	} else if (best.length === 0) {
		const firstEntry = oldEntries.find((entry) => entry.text.trim() !== '') ?? oldEntries[0];
		reportedLine = firstEntry.lineNumber;
		parts.push(`${prefix}: patch line ${firstEntry.lineNumber} ${quoteLine(firstEntry.text)} does not occur in the file.`);
	} else if (best.length === oldEntries.length && indentOffset < 0) {
		reportedLine = oldEntries[0].lineNumber;
		parts.push(`${prefix} where it may apply: its lines are at file lines ${best.start + 1}-${best.start + best.length}.`);
		if (chunk.endOfFile && best.start + best.length !== lines.length) {
			parts.push(`*** End of File requires the hunk to end at the last file line, line ${lines.length}.`);
		}
	} else if (best.length === oldEntries.length) {
		const entry = oldEntries[indentOffset];
		const fileLine = lines[best.start + indentOffset];
		reportedLine = entry.lineNumber;
		parts.push(
			`${prefix}: it matches file lines ${best.start + 1}-${best.start + best.length} only when indentation is ignored. ` +
				`After the marker, patch line ${entry.lineNumber} has ${leadingWhitespace(entry.text).length} leading whitespace characters; ` +
				`file line ${best.start + indentOffset + 1} has ${leadingWhitespace(fileLine).length}: ${quoteLine(fileLine)}.`
		);
	} else {
		const entry = oldEntries[best.length];
		const fileIndex = best.start + best.length;
		reportedLine = entry.lineNumber;
		parts.push(
			`${prefix}: its first ${best.length} context or removed lines match file lines ${best.start + 1}-${fileIndex}, ` +
				`but patch line ${entry.lineNumber} ${quoteLine(entry.text)} differs from file line ${fileIndex + 1} ${quoteLine(lines[fileIndex])}.`
		);
	}
	if (!ambiguous && best.length > 0 && best.start < cursor) {
		parts.push(
			`That location is above line ${cursor + 1}, where the previous hunk ended; hunks for one file must follow file order.`
		);
	}
	const duplicated = duplicatedInsertionContext(chunk);
	if (duplicated) {
		parts.push(
			`Context line ${quoteLine(duplicated.text)} appears both before and after the added lines (patch line ${duplicated.lineNumber}); unless the file repeats it, keep it on one side only.`
		);
	}

	fail('hunk_not_found', parts.join(' '), { path: displayPath, hunk: hunkNumber, line: reportedLine });
}

function applyUpdateChunks(textFile, chunks, displayPath) {
	const records = textFile.lines.map((text, index) => ({ text, ending: textFile.endings[index] }));
	const adjustments = [];
	let cursor = 0;

	for (const [chunkIndex, chunk] of chunks.entries()) {
		const hunkNumber = chunkIndex + 1;
		const lines = records.map((record) => record.text);
		if (chunk.resetCursor) {
			cursor = 0;
		}
		if (chunk.anchor !== null) {
			const anchorIndex = findAnchor(lines, chunk.anchor, cursor);
			if (anchorIndex < 0) {
				failAnchorNotFound(lines, chunk, cursor, hunkNumber, displayPath);
			}
			cursor = anchorIndex + 1;
		}
		if (chunk.lines.length === 0) {
			continue;
		}

		const match = locateChunk(lines, chunk, cursor);
		if (!match || match.ambiguous) {
			failHunkNotFound(lines, chunk, cursor, hunkNumber, displayPath, Boolean(match?.ambiguous));
		}
		if (match.adjustment) {
			adjustments.push(`${displayPath} hunk ${hunkNumber}: ${ADJUSTMENT_DESCRIPTIONS[match.adjustment]}.`);
		}

		const replacement = [];
		let fileIndex = match.index;
		for (const line of chunk.lines) {
			if (line.marker === ' ') {
				replacement.push(records[fileIndex]);
				fileIndex += 1;
			} else if (line.marker === '-') {
				fileIndex += 1;
			} else {
				const text =
					match.adjustment === 'extra_space_after_marker' && line.text.startsWith(' ') ? line.text.slice(1) : line.text;
				replacement.push({ text, ending: '' });
			}
		}
		records.splice(match.index, match.length, ...replacement);
		const trailingContextCount = [...chunk.lines].reverse().findIndex((line) => line.marker !== ' ');
		// A context-only section exists to skip past its lines; a changing hunk lets the next
		// hunk reuse its trailing context.
		const reusableContext = trailingContextCount < 0 ? 0 : trailingContextCount;
		cursor = Math.max(match.index, match.index + replacement.length - reusableContext);
	}

	return { records, adjustments };
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

// Returns the missing parent directories of targetPath, outermost first. Like native apply_patch,
// the commit creates them; existing ancestors must be real directories inside working_directory.
async function planParentDirectories(workingDirectory, targetPath) {
	const parentPath = dirname(targetPath);
	const segments = relative(workingDirectory, parentPath).split(sep).filter(Boolean);
	const missing = [];
	let currentPath = workingDirectory;
	for (const segment of segments) {
		currentPath = join(currentPath, segment);
		if (missing.length > 0) {
			missing.push(currentPath);
			continue;
		}
		const stats = await lstatIfExists(currentPath);
		if (!stats) {
			missing.push(currentPath);
			continue;
		}
		if (stats.isSymbolicLink()) {
			fail('reparse_point_rejected', `'${currentPath}' is a symbolic link or junction.`, { path: currentPath });
		}
		if (!stats.isDirectory()) {
			fail('parent_not_directory', `'${relative(workingDirectory, currentPath)}' exists and is not a directory.`, {
				path: currentPath
			});
		}
	}

	return missing;
}

async function assertAbsent(targetPath, displayPath, operation = 'move') {
	await assertNoReparsePoints(targetPath, { includeLeaf: false });
	const targetExists = await lstatIfExists(targetPath);
	if (targetExists) {
		fail('target_exists', `'${displayPath}' already exists.`, { path: displayPath, operation });
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
			const createDirectories = await planParentDirectories(workingDirectory, targetPath);
			await assertAbsent(targetPath, operation.path, 'add');
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
				outputBuffer,
				createDirectories
			});
			continue;
		}

		const snapshot = await readSnapshot(sourcePath, operation.path, maxFileBytes);
		if (operation.kind === 'replace') {
			const outputBuffer = Buffer.from(operation.content, 'utf8');
			if (outputBuffer.length > maxFileBytes) {
				fail('file_too_large', `'${operation.path}' would exceed the ${maxFileBytes}-byte limit.`);
			}
			prepared.push({
				kind: 'replace',
				displayPath: operation.path,
				sourcePath,
				targetPath,
				snapshot,
				outputBuffer
			});
			continue;
		}
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

		const createDirectories = operation.movePath ? await planParentDirectories(workingDirectory, targetPath) : [];
		if (operation.movePath) {
			await assertAbsent(targetPath, operation.movePath);
		}
		const { records, adjustments } = applyUpdateChunks(snapshot.textFile, operation.chunks, operation.path);
		const outputBuffer = encodeTextFile(snapshot.textFile, records);
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
			outputBuffer,
			createDirectories,
			adjustments
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
			await assertAbsent(item.targetPath, item.displayTargetPath ?? item.displayPath, item.kind);
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

async function createPlannedDirectories(prepared) {
	const created = [];
	const seen = new Set();
	try {
		for (const directoryPath of prepared.flatMap((item) => item.createDirectories ?? [])) {
			const key = pathKey(directoryPath);
			if (seen.has(key)) {
				continue;
			}
			seen.add(key);
			const existing = await lstatIfExists(directoryPath);
			if (existing?.isDirectory() && !existing.isSymbolicLink()) {
				continue;
			}
			if (existing) {
				fail('parent_not_directory', `'${directoryPath}' appeared before commit and is not a directory.`, {
					path: directoryPath
				});
			}
			await mkdir(directoryPath);
			created.push(directoryPath);
		}
	} catch (error) {
		await removeCreatedDirectories(created);
		throw error;
	}

	return created;
}

async function removeCreatedDirectories(directories) {
	for (const directoryPath of [...directories].reverse()) {
		try {
			await rmdir(directoryPath);
		} catch {
			// A directory that is no longer empty is left in place rather than risking its contents.
		}
	}
}

async function commitPreparedOperations(prepared, transactionId, testHooks) {
	const states = [];
	await verifyPreparedState(prepared);
	const createdDirectories = await createPlannedDirectories(prepared);
	try {
		await stageOutputs(prepared, transactionId);
	} catch (error) {
		await removeCreatedDirectories(createdDirectories);
		throw error;
	}

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
		await removeCreatedDirectories(createdDirectories);
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
	const createdDirectories = [
		...new Set(
			prepared
				.flatMap((item) => item.createDirectories ?? [])
				.map((directoryPath) => relative(resolvedWorkingDirectory, directoryPath).replaceAll(sep, '/'))
		)
	];
	if (createdDirectories.length > 0) {
		result.created_directories = createdDirectories;
	}
	const adjustments = prepared.flatMap((item) => item.adjustments ?? []);
	if (adjustments.length > 0) {
		result.adjustments = adjustments;
	}

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
	if (Number.isSafeInteger(patchError.details.line) && patchError.details.line > 0) {
		payload.error.line = patchError.details.line;
	}
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
				'Required source-edit tool for Ungate Desktop sessions. Invoke it from exec with working_directory and patch, then pass the return value to text(...). A bare await yields empty exec output even if the patch applied.',
				'This is the safe patch path: `${}` here is ordinary text. Do not send the patch through an exec template literal.',
				'The first and last lines must be the exact sentinels *** Begin Patch and *** End Patch.',
				'Use only plain-text Add File, Update File, Delete File, and Move to headers; do not wrap headers in Markdown emphasis.',
				ADD_FILE_REMEDIATION,
				UPDATE_FILE_REMEDIATION,
				EXEC_PATCH_AUTHORING,
				OPERATION_RULES
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
							EXEC_PATCH_AUTHORING,
							OPERATION_RULES
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
