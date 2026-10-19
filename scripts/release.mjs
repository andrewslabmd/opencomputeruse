// Release Open Computer Use from this Mac. docs/RELEASE.md describes the flow.
//   pnpm release:prepare X.Y.Z   build, notarize and package into release-artifacts/vX.Y.Z
//   pnpm release:publish X.Y.Z   (prints the plan) … --confirm to commit, tag, push and publish
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, copyFile, rm, stat, symlink, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const config = JSON.parse(await readFile(resolve(root, 'scripts/release-config.json'), 'utf8'));
const sparkleBin = resolve(root, '.build/artifacts/sparkle/Sparkle/bin');
const [command, version] = process.argv.slice(2);
const confirm = process.argv.includes('--confirm');
const tag = `v${version}`;
const out = resolve(root, 'release-artifacts', tag);
const notes = resolve(root, 'docs/releases', `${tag}.md`);
const app = resolve(root, 'dist/release/Open Computer Use.app');
const dmgName = `Open-Computer-Use-${version}.dmg`;
const latestDmgName = 'Open-Computer-Use.dmg';
const releaseUrl = `https://github.com/${config.repository}/releases`;

function run(cmd, args, { quiet = false, allowFail = false } = {}) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    p.stdout.on('data', d => { stdout += d; if (!quiet) process.stdout.write(d); });
    p.stderr.on('data', d => { stderr += d; if (!quiet) process.stderr.write(d); });
    p.once('error', rej);
    p.once('exit', code => code === 0 || allowFail ? res({ code, stdout: stdout.trim(), stderr: stderr.trim() }) : rej(new Error(`${cmd} ${args.join(' ')} exited ${code}\n${stderr.trim()}`)));
  });
}
const exists = path => access(path).then(() => true, () => false);
const sha256 = async path => createHash('sha256').update(await readFile(path)).digest('hex');
const fail = message => { throw new Error(message); };
const step = message => console.log(`\n== ${message}`);
const escape = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const buildNumber = v => { const [a, b, c] = v.split('.').map(Number); return String(a * 10000 + b * 100 + c); };

if (!['prepare', 'publish'].includes(command) || !/^\d+\.\d+\.\d+$/.test(version ?? '')) { console.error('usage: release.mjs prepare|publish X.Y.Z [--confirm]'); process.exit(1); }

async function git(...args) { return (await run('git', args, { quiet: true })).stdout; }
async function checkBranch() {
  if (await git('branch', '--show-current') !== 'main') fail('releases are made from main.');
}
async function checkTagFree() {
  if ((await run('git', ['rev-parse', '-q', '--verify', `refs/tags/${tag}`], { quiet: true, allowFail: true })).code === 0) fail(`tag ${tag} already exists locally.`);
  if (await git('ls-remote', '--tags', 'origin', `refs/tags/${tag}`)) fail(`tag ${tag} already exists on origin.`);
}
async function notarize(path, label) {
  step(`Notarizing ${label}`);
  const { stdout } = await run('xcrun', ['notarytool', 'submit', path, '--keychain-profile', config.notaryProfile, '--wait', '--timeout', '30m', '--output-format', 'json'], { quiet: true, allowFail: true });
  let result; try { result = JSON.parse(stdout); } catch { fail(`notarytool gave no result for ${label}:\n${stdout}`); }
  console.log(`${label}: ${result.status} (${result.id})`);
  if (result.status !== 'Accepted') {
    if (result.id) await run('xcrun', ['notarytool', 'log', result.id, '--keychain-profile', config.notaryProfile], { allowFail: true });
    fail(`Apple did not accept ${label}.`);
  }
}
// Release notes in Markdown, as the small HTML Sparkle shows: list items and paragraphs.
function notesHtml(markdown) {
  const html = []; let list = false;
  for (const line of markdown.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'))) {
    const item = line.match(/^[-*] (.*)$/);
    if (item && !list) { html.push('<ul>'); list = true; }
    if (!item && list) { html.push('</ul>'); list = false; }
    html.push(item ? `<li>${escape(item[1])}</li>` : `<p>${escape(line)}</p>`);
  }
  if (list) html.push('</ul>');
  return html.join('');
}

async function prepare() {
  step('Checking the release can start');
  await checkBranch();
  if (await git('status', '--porcelain')) fail('the working tree has uncommitted changes.');
  await checkTagFree();
  if (!await exists(notes)) fail(`write the release notes first: docs/releases/${tag}.md`);
  if (await exists(out)) fail(`${out} already exists; a prepared version is never overwritten.`);
  if (!(await run('security', ['find-identity', '-v', '-p', 'codesigning'], { quiet: true })).stdout.includes(`"${config.signingIdentity}"`)) fail(`signing identity not in the Keychain: ${config.signingIdentity}`);
  if ((await run('xcrun', ['notarytool', 'history', '--keychain-profile', config.notaryProfile], { quiet: true, allowFail: true })).code !== 0) fail(`notary profile ${config.notaryProfile} is missing or invalid; see docs/RELEASE.md.`);
  if (!await exists(join(sparkleBin, 'sign_update'))) await run('swift', ['package', 'resolve']);
  const key = await run(join(sparkleBin, 'generate_keys'), ['--account', config.sparkle.account, '-p'], { quiet: true, allowFail: true });
  if (key.stdout !== config.sparkle.publicKey) fail(`the Sparkle key for account ${config.sparkle.account} is missing or differs from release-config.json.`);
  const commit = await git('rev-parse', 'HEAD');

  step(`Setting version ${version}`);
  const pkgPath = resolve(root, 'package.json');
  const original = await readFile(pkgPath, 'utf8');
  await writeFile(pkgPath, `${JSON.stringify({ ...JSON.parse(original), version }, null, 2)}\n`);
  // A failed preparation leaves nothing behind: no version change, no partial artifacts.
  try { await build(commit); } catch (error) {
    await writeFile(pkgPath, original); await rm(out, { recursive: true, force: true });
    throw error;
  }
  console.log(`\nPrepared ${tag} in ${out}.
Next: install ${dmgName} from there and test it, then run: pnpm release:publish ${version}`);
}

async function build(commit) {

  step('Running checks');
  await run('node', ['scripts/check.mjs']);
  step('Building the release app');
  await run('node', ['scripts/build.mjs', '--release']);

  step('Checking the built app');
  const info = join(app, 'Contents/Info.plist');
  const plist = async key => (await run('plutil', ['-extract', key, 'raw', info], { quiet: true })).stdout;
  const expected = { CFBundleIdentifier: config.bundleId, CFBundleShortVersionString: version, CFBundleVersion: buildNumber(version), SUFeedURL: config.sparkle.feedUrl, SUPublicEDKey: config.sparkle.publicKey };
  for (const [key, value] of Object.entries(expected)) if (await plist(key) !== value) fail(`Info.plist ${key} is not ${value}.`);
  if (!(await run('codesign', ['-dv', '--verbose=2', app], { quiet: true })).stderr.includes(`TeamIdentifier=${config.teamId}`)) fail('the app is not signed by the release team.');

  await mkdir(out, { recursive: true });
  const work = await mkdtemp(join(tmpdir(), 'ocu-release-'));
  try {
    const zip = join(work, 'Open Computer Use.zip');
    await run('ditto', ['-c', '-k', '--keepParent', app, zip]);
    await notarize(zip, 'the app');
    await run('xcrun', ['stapler', 'staple', app]);
    await run('xcrun', ['stapler', 'validate', app]);
    await run('spctl', ['--assess', '--type', 'execute', '--verbose=2', app]);

    step('Making the disk image');
    const staging = join(work, 'dmg');
    await mkdir(staging);
    await run('ditto', [app, join(staging, 'Open Computer Use.app')]);
    await symlink('/Applications', join(staging, 'Applications'));
    const dmg = join(out, dmgName);
    await run('hdiutil', ['create', '-volname', 'Open Computer Use', '-srcfolder', staging, '-format', 'UDZO', dmg]);
    await run('codesign', ['--force', '--sign', config.signingIdentity, '--timestamp', dmg]);
    // notarytool can hang on these attributes.
    await run('xattr', ['-d', 'com.apple.provenance', dmg], { quiet: true, allowFail: true });
    await run('xattr', ['-d', 'com.apple.FinderInfo', dmg], { quiet: true, allowFail: true });
    await notarize(dmg, 'the disk image');
    await run('xcrun', ['stapler', 'staple', dmg]);
    await run('xcrun', ['stapler', 'validate', dmg]);
    await run('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg]);

    step('Signing the update feed');
    const signed = (await run(join(sparkleBin, 'sign_update'), ['--account', config.sparkle.account, dmg], { quiet: true })).stdout;
    const signature = signed.match(/sparkle:edSignature="([^"]+)"/)?.[1];
    if (!signature) fail(`sign_update gave no signature: ${signed}`);
    const { size } = await stat(dmg);
    const appcast = join(out, 'appcast.xml');
    await writeFile(appcast, `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Open Computer Use</title>
    <link>${releaseUrl}</link>
    <item>
      <title>Version ${version}</title>
      <pubDate>${new Date().toUTCString()}</pubDate>
      <sparkle:version>${buildNumber(version)}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${releaseUrl}/tag/${tag}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[${notesHtml(await readFile(notes, 'utf8'))}]]></description>
      <enclosure url="${releaseUrl}/download/${tag}/${dmgName}" length="${size}" type="application/octet-stream" sparkle:edSignature="${signature}" />
    </item>
  </channel>
</rss>
`);
    await run('xmllint', ['--noout', appcast]);
    await run(join(sparkleBin, 'sign_update'), ['--account', config.sparkle.account, '--disable-signing-warning', appcast]);
    await run(join(sparkleBin, 'sign_update'), ['--account', config.sparkle.account, '--verify', appcast]);

    const sums = `${await sha256(dmg)}  ${dmgName}\n${await sha256(appcast)}  appcast.xml\n`;
    await writeFile(join(out, 'SHA256SUMS'), sums);
    await writeFile(join(out, 'release.json'), `${JSON.stringify({ version, build: buildNumber(version), commit, dmg: dmgName, size, createdAt: new Date().toISOString() }, null, 2)}\n`);
  } finally { await rm(work, { recursive: true, force: true }); }
}

async function publish() {
  step('Checking the prepared release');
  await checkBranch();
  const manifest = JSON.parse(await readFile(join(out, 'release.json'), 'utf8').catch(() => fail(`nothing prepared for ${tag}; run release:prepare first.`)));
  if (manifest.commit !== await git('rev-parse', 'HEAD')) fail(`${tag} was prepared from ${manifest.commit.slice(0, 7)}, but main is now at another commit; prepare it again.`);
  const changed = (await git('status', '--porcelain')).split('\n').filter(Boolean);
  if (changed.some(line => line.slice(3) !== 'package.json')) fail(`only the version change may be uncommitted:\n${changed.join('\n')}`);
  if (JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8')).version !== version) fail(`package.json is not at ${version}.`);
  for (const line of (await readFile(join(out, 'SHA256SUMS'), 'utf8')).trim().split('\n')) {
    const [sum, file] = line.split(/\s+/);
    if (await sha256(join(out, file)) !== sum) fail(`${file} does not match SHA256SUMS.`);
  }
  await checkTagFree();
  await run('gh', ['auth', 'status'], { quiet: true });

  const plan = [`commit package.json as "Release ${tag}" and tag ${tag}`, 'push main and the tag to origin',
    `create the GitHub release ${tag} with ${dmgName}, ${latestDmgName}, appcast.xml and SHA256SUMS`, 'check the public download and update feed'];
  if (!confirm) { console.log(`Publishing ${tag} will:\n${plan.map(p => `- ${p}`).join('\n')}\nRun again with --confirm to do it.`); return; }

  step(`Tagging ${tag}`);
  if (changed.length) await run('git', ['commit', '-m', `Release ${tag}`, '--', 'package.json']);
  await run('git', ['tag', '-a', tag, '-m', `Open Computer Use ${version}`]);
  await run('git', ['push', 'origin', 'main', tag]);

  step('Creating the GitHub release');
  await copyFile(join(out, dmgName), join(out, latestDmgName));
  await run('gh', ['release', 'create', tag, '--repo', config.repository, '--verify-tag', '--title', `Open Computer Use ${version}`, '--notes-file', notes,
    join(out, dmgName), join(out, latestDmgName), join(out, 'appcast.xml'), join(out, 'SHA256SUMS')]);

  step('Checking what users get');
  // GitHub's "latest" links can take a moment to move to a new release.
  const appcast = await readFile(join(out, 'appcast.xml'), 'utf8');
  let served = false;
  for (let attempt = 0; attempt < 12 && !served; attempt++) {
    if (attempt) await new Promise(r => setTimeout(r, 5000));
    const feed = await fetch(config.sparkle.feedUrl, { cache: 'no-store' });
    served = feed.ok && await feed.text() === appcast;
  }
  if (!served) fail(`the public feed ${config.sparkle.feedUrl} does not serve this release's appcast yet.`);
  const download = await fetch(`${releaseUrl}/latest/download/${latestDmgName}`, { method: 'HEAD' });
  if (!download.ok) fail(`${releaseUrl}/latest/download/${latestDmgName} answered ${download.status}.`);
  console.log(`\nPublished ${tag}: ${releaseUrl}/tag/${tag}
Download: ${releaseUrl}/latest/download/${latestDmgName}
Add the CHANGELOG entry now that it is live.`);
}

await (command === 'prepare' ? prepare() : publish()).catch(error => { console.error(`\nrelease: ${error.message}`); process.exit(1); });
