import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Broker } from '../../packages/host/broker.mjs';

for (const capture of ['live', 'screenshot', 'capture_stopped_by_user']) {
  test(`engine capture ${capture} preserves the AX observation and capture diagnostics`, async t => {
    const runtime = await mkdtemp(join(tmpdir(), 'ocu-live-engine-'));
    const commands = join(runtime, 'commands'); await mkdir(commands);
    const broker = new Broker(process.execPath, ['packages/engine/computer-use-mcp.mjs'],
      { ...process.env, OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY: commands });
    const snapshot = {
      app: { pid: 101, name: 'Fixture' }, capturedAt: 1, nodeCount: 1,
      surface: { frame: { x: 100, y: 200, w: 800, h: 400 }, captureWindowIDs: [42], windows: [{
        windowID: 42, zIndex: 0, frame: { x: 100, y: 200, w: 800, h: 400 },
        tree: { id: 'w42', role: 'AXWindow', name: 'Fixture', children: [] },
      }] },
    };
    let running = true, failure, screenshotPath;
    const worker = (async () => {
      while (running) {
        for (const name of await readdir(commands)) {
          if (!/^request-.*\.json$/.test(name)) continue;
          const request = JSON.parse(await readFile(join(commands, name), 'utf8'));
          let response = { id: request.id, success: true, stdout: JSON.stringify(snapshot) };
          if (request.action === 'captureApplicationSurface') {
            assert.deepEqual(request.preview.windowIDs, [42]);
            screenshotPath = request.preview.path;
            if (capture === 'capture_stopped_by_user') response = { id: request.id, success: false, error: capture };
            else {
              await writeFile(screenshotPath, Buffer.from('synthetic image bytes'));
              response.stdout = JSON.stringify({ success: true, capture_source: capture });
            }
          }
          await rm(join(commands, name));
          const path = join(commands, `response-${request.id}.json`);
          await writeFile(path + '.tmp', JSON.stringify(response)); await rename(path + '.tmp', path);
        }
        await new Promise(resolve => setTimeout(resolve, 5));
      }
    })().catch(error => { failure = error; });
    t.after(async () => {
      await broker.stop(); running = false; await worker; await rm(runtime, { recursive: true, force: true });
      if (failure) throw failure;
    });
    await broker.start();
    const result = await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture', include_screenshot: true } });
    assert.equal(result.isError, undefined);
    assert.equal(JSON.parse(result.content[0].text).status, 'observed');
    assert.equal(result._meta.pid, 101);
    if (capture === 'capture_stopped_by_user') {
      assert.equal(JSON.parse(result.content[1].text).screenshot_error, 'capture_stopped_by_user');
      assert.equal(result.content.some(part => part.type === 'image'), false);
      assert.equal(result._meta.capture_source, undefined);
    } else {
      assert.equal(result._meta.capture_source, capture);
      assert.deepEqual(result.content[1], { type: 'image', data: Buffer.from('synthetic image bytes').toString('base64'), mimeType: 'image/jpeg' });
    }
    await assert.rejects(readFile(screenshotPath), { code: 'ENOENT' });
  });
}
