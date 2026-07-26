import { cp, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const controlRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.resolve(controlRoot, '..', 'web', 'dist');
const target = path.resolve(controlRoot, 'bundle', 'public');

await rm(target, { recursive: true, force: true });
await mkdir(path.dirname(target), { recursive: true });
await cp(source, target, { recursive: true });

console.log(`[ungate-dashboard] copied web assets to ${target}`);
