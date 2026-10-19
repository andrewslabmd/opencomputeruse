import { spawn, execFileSync } from 'node:child_process';
import { mkdir, copyFile, writeFile, readFile, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
// `pnpm build` makes the development app (ad hoc or OCU_SIGN_IDENTITY, `.dev`
// identifiers). `pnpm build --release` makes the release app: release
// identifiers, Developer ID, hardened runtime and the Sparkle feed. Neither
// notarizes; scripts/release.mjs does that.
const root = new URL('..', import.meta.url).pathname;
const release = process.argv.includes('--release');
const config = JSON.parse(await readFile(resolve(root, 'scripts/release-config.json'), 'utf8'));
const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
if (release && !/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`A release needs a plain x.y.z version in package.json, not ${version}.`);
// The build number only grows with the version, as Sparkle compares it.
const [major, minor, patch] = version.split(/[.-]/).map(Number);
if ([minor, patch].some(n => n > 99)) throw new Error('Minor and patch versions above 99 need a new build-number scheme.');
const build = String(major * 10000 + minor * 100 + patch);
const id = release ? config.bundleId : `${config.bundleId}.dev`;
// macOS ties permissions to the signature. Ad hoc changes with every build, so
// a development build signs with the Mac's Apple Development certificate when
// there is one and keeps its permissions across rebuilds.
const identity = release ? config.signingIdentity : (process.env.OCU_SIGN_IDENTITY || developmentIdentity() || '-');
if (!release) console.log(identity === '-' ? 'Signing ad hoc: macOS permissions must be granted again after each build.' : `Signing with Apple Development certificate ${identity}`);
const signing = release ? ['--options', 'runtime', '--timestamp'] : [];

const app = resolve(root, release ? 'dist/release/Open Computer Use.app' : 'dist/Open Computer Use.app');
const mac = join(app, 'Contents/MacOS'); const resources = join(app, 'Contents/Resources'); const frameworks = join(app, 'Contents/Frameworks');
const helper = join(resources, 'Open Computer Use Helper.app');
const sparkle = join(frameworks, 'Sparkle.framework');
function run(cmd, args) { return new Promise((res, rej) => { const p = spawn(cmd, args, { cwd: root, stdio: 'inherit' }); p.once('error', rej); p.once('exit', c => c === 0 ? res() : rej(new Error(`${cmd} exited ${c}`))); }); }
await run('swift', ['build', '-c', 'release']);
// A clean bundle: nothing from an earlier build survives in it.
await rm(app, { recursive: true, force: true });
await mkdir(mac, { recursive: true }); await mkdir(join(helper, 'Contents/MacOS'), { recursive: true }); await mkdir(frameworks, { recursive: true });
await copyFile(resolve(root, '.build/release/OpenComputerUse'), join(mac, 'OpenComputerUse'));
await copyFile(resolve(root, '.build/release/ocu-helper'), join(helper, 'Contents/MacOS/ocu-helper'));
await run('ditto', [resolve(root, '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'), sparkle]);
// OCU_BUN names another Bun (for example one rebuilt with a modified
// JavaScriptCore, as BUN_RUNTIME_NOTICES.md describes). Compiling for the
// host platform, it embeds itself as the runtime.
const bun = process.env.OCU_BUN ? resolve(process.env.OCU_BUN) : resolve(root, 'node_modules/.bin/bun');
const target = process.env.OCU_BUN ? [] : ['--target=bun-darwin-arm64'];
for (const [name, source] of [['ocu', 'packages/cli/main.mjs'], ['ocu-host', 'packages/host/main.mjs'], ['ocu-engine', 'packages/engine/computer-use-mcp.mjs']]) {
  await run(bun, ['build', '--compile', ...target, source, '--outfile', join(mac, name)]);
}
const updates = release ? `<key>SUFeedURL</key><string>${config.sparkle.feedUrl}</string><key>SUPublicEDKey</key><string>${config.sparkle.publicKey}</string><key>SUEnableAutomaticChecks</key><true/><key>SUScheduledCheckInterval</key><integer>86400</integer><key>SUAllowsAutomaticUpdates</key><false/><key>SUAutomaticallyUpdate</key><false/><key>SURequireSignedFeed</key><true/><key>SUVerifyUpdateBeforeExtraction</key><true/>` : '';
function plist(name, executable, id, extra = '') { return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>${name}</string><key>CFBundleDisplayName</key><string>${name}</string><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>${build}</string><key>CFBundleShortVersionString</key><string>${version}</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>CFBundleIconFile</key><string>OpenComputerUse</string><key>CFBundleIconName</key><string>OpenComputerUse</string><key>LSUIElement</key><true/><key>NSScreenCaptureUsageDescription</key><string>Capture the selected app for agent observations and your private preview.</string>${extra}</dict></plist>`; }
await writeFile(join(app, 'Contents/Info.plist'), plist('Open Computer Use', 'OpenComputerUse', id, updates));
await writeFile(join(helper, 'Contents/Info.plist'), plist('Open Computer Use Helper', 'ocu-helper', `${id}.helper`));
await mkdir(resources, { recursive: true });
// The committed compiled icon (pnpm build:icon regenerates it), in the app and in
// the helper, which is the entry shown in macOS privacy settings.
for (const destination of [resources, join(helper, 'Contents/Resources')]) {
  await mkdir(destination, { recursive: true });
  for (const name of ['Assets.car', 'OpenComputerUse.icns']) await copyFile(resolve(root, 'assets/icon/compiled', name), join(destination, name));
}
for (const notices of ['THIRD_PARTY_NOTICES.md', 'BUN_RUNTIME_NOTICES.md']) await copyFile(resolve(root, notices), join(resources, notices));
// Sign inside out: the Bun runtimes, Sparkle's parts, the helper, then the app.
await run('xattr', ['-cr', app]);
const sign = (path, ...extra) => run('codesign', ['--force', '--sign', identity, ...signing, ...extra, path]);
for (const name of ['ocu', 'ocu-host', 'ocu-engine']) await sign(join(mac, name), '--identifier', `${id}.${name}`, '--entitlements', 'scripts/Runtime.entitlements');
const sparkleParts = join(sparkle, 'Versions/B');
await sign(join(sparkleParts, 'XPCServices/Installer.xpc'));
await sign(join(sparkleParts, 'XPCServices/Downloader.xpc'), '--preserve-metadata=entitlements');
await sign(join(sparkleParts, 'Autoupdate'));
await sign(join(sparkleParts, 'Updater.app'));
await sign(sparkle);
await sign(helper);
await sign(app);
await run('codesign', ['--verify', '--deep', '--strict', app]);
console.log(release
  ? `Release app ${version} (${build}): ${app}. Signed, not notarized; scripts/release.mjs notarizes it.`
  : `Development artifact: ${app}. Not notarized; native acceptance remains separate.`);
function developmentIdentity() {
  // By fingerprint: codesign can miss a certificate whose name has accents.
  try { return execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' }).match(/([0-9A-F]{40}) "Apple Development: /)?.[1]; } catch { return undefined; }
}
