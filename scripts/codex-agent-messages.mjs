/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** @param {unknown} content */
function agentMessageContentParts(content) {
	const parts = [];
	const append = (text) => {
		if (typeof text === 'string') parts.push({ type: 'input_text', text });
	};
	if (typeof content === 'string') {
		append(content);

		return parts;
	}
	if (!Array.isArray(content)) return parts;

	for (const part of content) {
		if (typeof part === 'string') {
			append(part);
			continue;
		}
		if (!isObject(part)) continue;
		if (part.type === 'encrypted_content') {
			if (typeof part.encrypted_content === 'string') append(part.encrypted_content);
			else if (typeof part.text === 'string') append(part.text);
			continue;
		}
		if (
			typeof part.text === 'string' &&
			(part.type === 'input_text' || part.type === 'output_text' || part.type === 'text' || part.type === undefined)
		) {
			append(part.text);
		}
	}
	if (parts.length === 0 && content.length > 0) {
		append('[agent message content omitted: unsupported part types]');
	}

	return parts;
}

// Inter-agent input belongs to the receiving agent's user turn. Preserve its
// sender and recipient so it cannot be mistaken for a message from the human.
/** @param {Record<string, unknown>} item */
export function messageFromAgentMessage(item) {
	const author = typeof item.author === 'string' && item.author !== '' ? item.author : 'unknown';
	const recipient = typeof item.recipient === 'string' && item.recipient !== '' ? item.recipient : 'unknown';

	return {
		type: 'message',
		role: 'user',
		content: [
			{
				type: 'input_text',
				text: `Agent message from ${JSON.stringify(author)} to ${JSON.stringify(recipient)}:\n`
			},
			...agentMessageContentParts(item.content)
		]
	};
}
