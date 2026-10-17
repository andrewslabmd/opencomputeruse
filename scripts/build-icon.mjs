import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
// Compiles assets/icon/OpenComputerUse.icon into the committed files the app
// build copies (Assets.car for the layered icon, .icns for older systems).
// Needs Xcode with Icon Composer support; `pnpm build` itself does not.
const root = new URL('..', import.meta.url).pathname;
const compiled = resolve(root, 'assets/icon/compiled');
const run = (cmd, args) => { const p = spawnSync(cmd, args, { cwd: root, stdio: 'inherit' }); if (p.status) process.exit(p.status ?? 1); };
run('swift', ['assets/icon/layers.swift']);
const out = await mkdtemp(join(tmpdir(), 'ocu-icon-'));
try {
  run('xcrun', ['actool', 'assets/icon/OpenComputerUse.icon', '--compile', out, '--app-icon', 'OpenComputerUse',
    '--platform', 'macosx', '--minimum-deployment-target', '15.0', '--output-partial-info-plist', join(out, 'partial.plist')]);
  await mkdir(compiled, { recursive: true });
  for (const name of ['Assets.car', 'OpenComputerUse.icns']) await copyFile(join(out, name), join(compiled, name));
} finally { await rm(out, { recursive: true, force: true }); }
console.log(`Compiled icon: ${compiled}`);
