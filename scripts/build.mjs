import { spawn } from 'node:child_process';
import { mkdir, copyFile, writeFile, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
const root = new URL('..', import.meta.url).pathname;
const app = resolve(root, 'dist/Open Computer Use.app');
const mac = join(app, 'Contents/MacOS'); const resources = join(app, 'Contents/Resources');
const helper = join(resources, 'Open Computer Use Helper.app');
function run(cmd, args) { return new Promise((res, rej) => { const p = spawn(cmd, args, { cwd: root, stdio: 'inherit' }); p.once('error', rej); p.once('exit', c => c === 0 ? res() : rej(new Error(`${cmd} exited ${c}`))); }); }
await run('swift', ['build', '-c', 'release']);
// A clean bundle: nothing from an earlier build survives in it.
await rm(app, { recursive: true, force: true });
await mkdir(mac, { recursive: true }); await mkdir(join(helper, 'Contents/MacOS'), { recursive: true });
await copyFile(resolve(root, '.build/release/OpenComputerUse'), join(mac, 'OpenComputerUse'));
await copyFile(resolve(root, '.build/release/ocu-helper'), join(helper, 'Contents/MacOS/ocu-helper'));
for (const [name, source] of [['ocu', 'packages/cli/main.mjs'], ['ocu-host', 'packages/host/main.mjs'], ['ocu-engine', 'packages/engine/computer-use-mcp.mjs']]) {
  await run(resolve(root, 'node_modules/.bin/bun'), ['build', '--compile', '--target=bun-darwin-arm64', source, '--outfile', join(mac, name)]);
}
function plist(name, executable, id) { return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>${name}</string><key>CFBundleDisplayName</key><string>${name}</string><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>CFBundleIconFile</key><string>OpenComputerUse</string><key>CFBundleIconName</key><string>OpenComputerUse</string><key>LSUIElement</key><true/><key>NSScreenCaptureUsageDescription</key><string>Capture the selected app for agent observations and your private preview.</string></dict></plist>`; }
await writeFile(join(app, 'Contents/Info.plist'), plist('Open Computer Use', 'OpenComputerUse', 'com.andrewslabmd.opencomputeruse.dev'));
await writeFile(join(helper, 'Contents/Info.plist'), plist('Open Computer Use Helper', 'ocu-helper', 'com.andrewslabmd.opencomputeruse.dev.helper'));
await mkdir(resources, { recursive: true });
// The committed compiled icon (pnpm build:icon regenerates it), in the app and in
// the helper, which is the entry shown in macOS privacy settings.
for (const destination of [resources, join(helper, 'Contents/Resources')]) {
  await mkdir(destination, { recursive: true });
  for (const name of ['Assets.car', 'OpenComputerUse.icns']) await copyFile(resolve(root, 'assets/icon/compiled', name), join(destination, name));
}
await copyFile(resolve(root, 'THIRD_PARTY_NOTICES.md'), join(resources, 'THIRD_PARTY_NOTICES.md'));
const identity = process.env.OCU_SIGN_IDENTITY || '-';
for (const name of ['ocu', 'ocu-host', 'ocu-engine']) await run('codesign', ['--force', '--sign', identity, '--entitlements', 'scripts/Runtime.entitlements', join(mac, name)]);
await run('codesign', ['--force', '--sign', identity, helper]);
await run('codesign', ['--force', '--sign', identity, app]);
await run('codesign', ['--verify', '--deep', '--strict', app]);
console.log(`Development artifact: ${app}. Not notarized; native acceptance remains separate.`);
