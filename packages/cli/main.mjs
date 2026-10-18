import { Client, connectHost } from './client.mjs';
import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { saveImages } from './images.mjs';
const [command = 'help', ...args] = process.argv.slice(2);
if (command === 'mcp') { await import('../mcp/main.mjs'); }
else if (command === 'help' || command === '--help') {
  console.log('ocu status | permissions | apps | observe APP [--screenshot[=FILE]] | batch APP JSON | stop | resume | revoke CLIENT_ID | setup [claude | codex | cursor | opencode] [--remove] [--print] | --version\nBatch observes APP and acts within one exclusive connection. mcp serves a persistent agent connection.\n--screenshot attaches the app window image, saved to FILE (default: a private temporary file) and printed as its path.\nsetup connects coding agents to Open Computer Use; with no agent it shows each one\'s status.');
} else if (command === '--version') console.log('0.1.0-dev');
else if (command === 'setup') {
  const { runSetup } = await import('./setup.mjs');
  try { process.exitCode = await runSetup(args); } catch (error) { console.error(`error: ${error.message}`); process.exitCode = 1; }
} else {
  const client = new Client();
  try {
    await connectHost(client, 'CLI');
    let result;
    if (['status', 'resume'].includes(command)) result = await client.request(command);
    else if (command === 'stop') result = await client.request('pause');
    else if (command === 'revoke') result = await client.request('revoke', { client: args[0] });
    else if (command === 'permissions') result = await client.request('tools/call', { name: 'use_permissions', arguments: {} });
    else if (command === 'apps') result = await client.request('tools/call', { name: 'use_list_apps', arguments: {} });
    else if (command === 'observe' || command === 'batch') {
      const screenshot = args.find(arg => arg === '--screenshot' || arg.startsWith('--screenshot='));
      const [target] = args.filter(arg => arg !== screenshot);
      if (!target) throw new Error('Application target required');
      if (screenshot && command !== 'observe') throw new Error('--screenshot applies to observe');
      result = await client.request('tools/call', { name: 'use_observe', arguments: { app_target: target, ...(screenshot ? { include_screenshot: true } : {}) } });
      if (screenshot) result = await saveImages(result, screenshot.slice('--screenshot='.length) || undefined);
      if (command === 'batch' && !result.isError) result = await client.request('tools/call', { name: 'use_action_batch', arguments: { actions: JSON.parse(args[1]) } });
      await client.request('release');
    } else throw new Error('Unknown command; run ocu help');
    console.log(JSON.stringify(result, null, 2));
    if (result?.isError) process.exitCode = 1;
  } catch (error) { console.error(`${error.code || 'error'}: ${error.message}`); process.exitCode = 1; }
  finally { client.close(); }
}
