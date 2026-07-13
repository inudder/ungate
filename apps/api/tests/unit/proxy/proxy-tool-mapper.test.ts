import { describe, expect, it } from 'vitest';

import { ToolMapper } from 'src/proxy/tool-mapper';

describe('proxy-tool-mapper', () => {
	it('maps known aliases and creates reverse mapping', () => {
		const result = ToolMapper.map([
			{ name: 'read_file', description: '', input_schema: {} },
			{ name: 'SemanticSearch', description: '', input_schema: {} }
		]);

		expect(result.tools.map((tool) => tool.name)).toEqual(['Read', 'Grep']);
		expect(result.reverseMapping.Read).toBe('read_file');
		expect(result.reverseMapping.Grep).toBe('SemanticSearch');
	});

	it('maps the Codex shell command tool to Claude Code Bash', () => {
		const inputSchema = { type: 'object', properties: { command: { type: 'string' } } };
		const result = ToolMapper.map([{ name: 'shell_command', description: 'Run PowerShell', input_schema: inputSchema }]);

		expect(result.tools).toEqual([{ name: 'Bash', description: 'Run PowerShell', input_schema: inputSchema }]);
		expect(result.reverseMapping.Bash).toBe('shell_command');
	});

	it('maps Codex Desktop unified exec tools and preserves their schemas', () => {
		const execSchema = { type: 'object', properties: { cmd: { type: 'string' } } };
		const stdinSchema = { type: 'object', properties: { chars: { type: 'string' } } };
		const result = ToolMapper.map([
			{ name: 'exec_command', description: 'Start a command', input_schema: execSchema },
			{ name: 'write_stdin', description: 'Write to a command', input_schema: stdinSchema }
		]);

		expect(result.tools).toEqual([
			{ name: 'Bash', description: 'Start a command', input_schema: execSchema },
			{ name: 'Bash_1', description: 'Write to a command', input_schema: stdinSchema }
		]);
		expect(result.reverseMapping).toEqual({ Bash: 'exec_command', Bash_1: 'write_stdin' });
	});

	it('maps the Codex Plan Mode question tool to Claude Code AskUserQuestion', () => {
		const inputSchema = {
			type: 'object',
			properties: { questions: { type: 'array', items: { type: 'object' } } },
			required: ['questions']
		};
		const result = ToolMapper.map([{ name: 'request_user_input', description: 'Ask for a decision', input_schema: inputSchema }]);

		expect(result.tools).toEqual([{ name: 'AskUserQuestion', description: 'Ask for a decision', input_schema: inputSchema }]);
		expect(result.reverseMapping.AskUserQuestion).toBe('request_user_input');
	});

	it('keeps valid tools and deduplicates by suffix', () => {
		const result = ToolMapper.map([
			{ name: 'Read', description: '', input_schema: {} },
			{ name: 'read_file', description: '', input_schema: {} }
		]);

		expect(result.tools.map((tool) => tool.name)).toEqual(['Read', 'Read_1']);
		expect(result.reverseMapping.Read_1).toBe('read_file');
	});

	it('drops unknown tools', () => {
		const result = ToolMapper.map([{ name: 'UnknownTool', description: '', input_schema: {} }]);
		expect(result.tools).toHaveLength(0);
		expect(result.reverseMapping).toEqual({});
	});

	it('deduplicates repeated mapped aliases with increasing suffixes', () => {
		const result = ToolMapper.map([
			{ name: 'read_file', description: '', input_schema: {} },
			{ name: 'view_file', description: '', input_schema: {} },
			{ name: 'Read', description: '', input_schema: {} }
		]);

		expect(result.tools.map((tool) => tool.name)).toEqual(['Read', 'Read_1', 'Read_2']);
		expect(result.reverseMapping.Read).toBe('read_file');
		expect(result.reverseMapping.Read_1).toBe('view_file');
		expect(result.reverseMapping.Read_2).toBe('Read');
	});
});
