import { spawnSync } from 'node:child_process';
import { readdir } from 'node:fs/promises';
async function files(path) { const result = []; for (const f of await readdir(path, { withFileTypes: true })) { if (f.isDirectory()) result.push(...await files(`${path}/${f.name}`)); else if (f.name.endsWith('.mjs')) result.push(`${path}/${f.name}`); } return result; }
for (const file of [...await files('packages'), ...await files('scripts')]) { const p = spawnSync('node', ['--check', file], { stdio: 'inherit' }); if (p.status) process.exit(p.status); }
for (const [cmd, args] of [['node', ['--test', ...await files('tests/contract')]], ['swift', ['test']]]) { const p = spawnSync(cmd, args, { stdio: 'inherit' }); if (p.status) process.exit(p.status); }
