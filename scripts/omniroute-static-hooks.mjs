import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

function withTypeScriptExtension(filePath) {
	if (existsSync(filePath)) return filePath;
	if (existsSync(filePath + '.ts')) return filePath + '.ts';
	if (filePath.endsWith('.js') && existsSync(filePath.slice(0, -3) + '.ts')) return filePath.slice(0, -3) + '.ts';

	return null;
}

export async function resolve(specifier, context, nextResolve) {
	const appRoot = process.env.OMNIROUTE_APP_ROOT;
	if (appRoot && specifier.startsWith('@omniroute/open-sse/')) {
		const resolved = withTypeScriptExtension(path.join(appRoot, 'open-sse', specifier.slice('@omniroute/open-sse/'.length)));
		if (resolved) return { url: pathToFileURL(resolved).href, shortCircuit: true };
	}
	if (appRoot && specifier.startsWith('@/')) {
		const resolved = withTypeScriptExtension(path.join(appRoot, 'src', specifier.slice(2)));
		if (resolved) return { url: pathToFileURL(resolved).href, shortCircuit: true };
	}
	if (context.parentURL && (specifier.startsWith('./') || specifier.startsWith('../'))) {
		const parentPath = fileURLToPath(context.parentURL);
		const resolved = withTypeScriptExtension(path.resolve(path.dirname(parentPath), specifier));
		if (resolved) return { url: pathToFileURL(resolved).href, shortCircuit: true };
	}

	return nextResolve(specifier, context);
}
