import { interruptedActionReceipt, batchDisposition, applyInputDelivery } from "./computer-use-action-result.mjs";
import { tools as toolDefinitions } from "../protocol/tools.mjs";
const [observeDefinition, batchDefinition, permissionDefinition] = toolDefinitions;
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { requestBackgroundAppLaunch } from "./computer-use-background-app.mjs";
import {
  globalPoint,
  normalizeAirpointSnapshot,
  resolveAirpointPoint,
  resolveAirpointElement,
  elementReferenceKey,
  nativeActionAudit,
  confirmNativeState,
  confirmWebPress,
  confirmSelection,
  confirmedTextSubmitTarget,
  observedStateChanges,
  deltaModel,
  toCanonicalYaml,
} from "./computer-use-airpoint.mjs";
import { requestComputerUseHelper } from "./computer-use-helper-client.mjs";
import { withActivationOnDemand, actionNeedsActivation, requiresActivation, ActivationRequired, multiClick } from "./computer-use-action-focus.mjs";

// One agent's engine: it speaks MCP on stdio to the host and performs every
// observation and action through OpenComputerUse's own signed helper.
const ENGINE_TOOLS = new Set(["observe", "action_batch", "permissions"]);
const helperCommandDirectory = process.env.OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY;

let latestAirpointObservation;
// The complete model the agent last received; post-action results are sent as changes against it.
let deliveredModel;
let airpointOperation = Promise.resolve();

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function toolError(id, code, message, surface = "computer") {
  send({
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text: `${message}\n\n${JSON.stringify({ code, surface })}` }],
      isError: true,
      _meta: { code, surface },
    },
  });
}

function toolResult(id, text, metadata = {}) {
  send({
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text }],
      _meta: metadata,
    },
  });
}

function toolContentResult(id, content, metadata = {}, isError = false) {
  send({
    jsonrpc: "2.0",
    id,
    result: {
      content,
      ...(isError ? { isError: true } : {}),
      _meta: metadata,
    },
  });
}

function validateBackgroundCall(name, args) {
  if (args.foreground === true || args.background === false) {
    return {
      code: "invalid_background_request",
      message: "Foreground flags are unavailable in background Computer Use. Remove them and retry with an explicit target.",
    };
  }
  if (name === "action_batch" && (args.actions ?? []).some?.(
    (action) => action?.foreground === true || action?.background === false,
  )) {
    return {
      code: "invalid_background_request",
      message: "Foreground flags are unavailable inside a background action batch.",
    };
  }
  return null;
}

function prepareCall(message) {
  const exposedName = message.params?.name;
  const name = exposedName?.startsWith("use_") ? exposedName.slice("use_".length) : undefined;
  const args = { ...(message.params?.arguments ?? {}) };
  if (!ENGINE_TOOLS.has(name)) {
    return { error: { code: "tool_unavailable", message: `${exposedName || "This tool"} is not part of this Computer MCP surface.` } };
  }
  const error = validateBackgroundCall(name, args);
  return error ? { error } : { name, args };
}

async function reportPermissionStatus(message) {
  try {
    const response = await requestComputerUseHelper(
      helperCommandDirectory,
      "permissionStatus",
    );
    if (response.error || response.success !== true || typeof response.stdout !== "string") {
      toolError(
        message.id,
        "computer_use_permission_status_unavailable",
        response.error || "OpenComputerUse Helper could not report its permissions.",
        "use",
      );
      return;
    }
    const permissions = JSON.parse(response.stdout);
    toolResult(message.id, JSON.stringify({ permissions }), {
      code: "computer_use_permission_status",
      surface: "use",
    });
  } catch (error) {
    toolError(
      message.id,
      "computer_use_permission_status_unavailable",
      error?.message ?? String(error),
      "use",
    );
  }
}

function enqueueAirpointOperation(operation) {
  const run = airpointOperation.then(operation, operation);
  airpointOperation = run.catch(() => undefined);
  return run;
}

async function captureAirpointObservation(appTarget, windowTitle, windowID, expectedSnapshot) {
  try {
    const response = await requestComputerUseHelper(
      helperCommandDirectory,
      "accessibilitySnapshot",
      {
        ...(expectedSnapshot ? { capturedAt: expectedSnapshot.model.captured_at } : {}),
        accessibilitySnapshot: {
          appTarget,
          ...(windowTitle ? { windowTitle } : {}),
          ...(windowID !== undefined ? { windowID } : {}),
        },
      },
      { timeoutMs: 30_000, pollMs: 25 },
    );
    if (response.error || response.success !== true || typeof response.stdout !== "string") {
      throw new Error(response.error || "The signed helper could not observe the target application.");
    }
    let raw;
    try {
      raw = JSON.parse(response.stdout);
    } catch {
      throw new Error("The signed helper returned malformed Accessibility state.");
    }
    const normalized = normalizeAirpointSnapshot(raw);
    latestAirpointObservation = {
      ...normalized,
      appTarget: `PID:${normalized.pid}`,
      requestedAppTarget: appTarget,
      scopeWindowID: raw.surface?.anchorWindowID ?? raw.surface?.closedWindowID ?? raw.surface?.unavailableWindowID,
    };
    return latestAirpointObservation;
  } catch (error) {
    latestAirpointObservation = undefined;
    throw error;
  }
}

async function captureAirpointSurfaceImage(snapshot) {
  if (!helperCommandDirectory) {
    throw new Error("The signed Computer Use helper is unavailable.");
  }
  const directory = join(dirname(helperCommandDirectory), "observations");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, `application-surface-${randomUUID()}.jpg`);
  try {
    const response = await requestComputerUseHelper(
      helperCommandDirectory,
      "captureApplicationSurface",
      {
        preview: {
          kind: "pid",
          value: String(snapshot.pid),
          path,
          windowIDs: snapshot.captureWindowIDs,
        },
      },
      { timeoutMs: 35_000, pollMs: 25 },
    );
    if (response.error || response.success !== true) {
      throw new Error(response.error || response.stderr || "The application surface could not be captured.");
    }
    const image = await readFile(path);
    if (image.length === 0 || image.length > 20 * 1024 * 1024) {
      throw new Error("The application-surface screenshot was invalid.");
    }
    return { type: "image", data: image.toString("base64"), mimeType: "image/jpeg" };
  } finally {
    await rm(path, { force: true }).catch(() => undefined);
  }
}

async function runAirpointAction(action, index) {
  const audit = { index, kind: action?.kind ?? "unknown" };
  if (!action || typeof action !== "object") {
    return { ...audit, status: "failed", code: "invalid_action", error: "Each action must be an object." };
  }
  if (action.kind === "open_app") {
    const name = typeof action.name === "string" ? action.name.trim() : "";
    const bundleIdentifier = typeof action.bundle_id === "string" ? action.bundle_id.trim() : "";
    if (!name && !bundleIdentifier) {
      return { ...audit, status: "failed", code: "invalid_app_target", error: "open_app requires name or bundle_id." };
    }
    const launch = await requestBackgroundAppLaunch(helperCommandDirectory, {
      name: name || undefined,
      bundleIdentifier: bundleIdentifier || undefined,
      waitUntilReady: action.wait_until_ready !== false,
    });
    if (!launch.success) {
      return { ...audit, status: "failed", code: "background_app_launch_failed", error: launch.error };
    }
    const target = name || bundleIdentifier;
    try {
      await captureAirpointObservation(target);
    } catch (error) {
      return {
        ...audit, status: "completed", target, behavior: "open_in_background",
        observation_error: { code: "post_launch_observation_failed", message: error?.message ?? String(error) },
      };
    }
    return { ...audit, status: "completed", target, behavior: "open_in_background" };
  }

  const snapshot = latestAirpointObservation;
  if (!snapshot) {
    return {
      ...audit,
      status: "failed",
      code: "observation_required",
      error: "Observe the target application before performing background actions.",
    };
  }

  if (action.kind === "wait") {
    if (!Number.isInteger(action.milliseconds) || action.milliseconds < 25 || action.milliseconds > 10_000) {
      return { ...audit, status: "failed", code: "invalid_wait", error: "wait milliseconds must be between 25 and 10000." };
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, action.milliseconds));
    return { ...audit, status: "completed", behavior: "wait", milliseconds: action.milliseconds };
  }

  if (action.kind === "hotkey") {
    if (!Array.isArray(action.keys) || action.keys.length < 1) {
      return { ...audit, status: "failed", code: "invalid_hotkey", error: "hotkey requires at least one key." };
    }
    const target = await requestComputerUseHelper(helperCommandDirectory, "sendHotkey", {
      processID: snapshot.pid, capturedAt: snapshot.model.captured_at, keys: action.keys,
    }, { timeoutMs: 10_000, pollMs: 25 });
    if (target.success !== true || !target.stdout) return { ...audit, status: "failed", code: "keyboard_target_unavailable", error: target.error || "The keyboard target could not be checked." };
    const { input_trace_ids, dispatch_error, code, ...receiver } = JSON.parse(target.stdout);
    return { ...audit, status: dispatch_error ? "failed" : "sent", behavior: "hotkey", keys: action.keys, receiver,
      ...(input_trace_ids?.length ? { input_trace_ids } : {}),
      ...(dispatch_error ? { code: code ?? "background_hotkey_failed", error: dispatch_error } : {}) };
  }

  const point = action.kind === "drag" ? action.from : action.at;
  const route = action.element !== undefined ? resolveAirpointElement(snapshot, action.element, { allowOffscreen: action.kind === "scroll_to_visible" }) : resolveAirpointPoint(snapshot, point);
  if (!route.ok) return { ...audit, requested: point, status: "failed", code: route.code, error: route.message };
  if (route.noEffect) return { ...audit, requested: point, status: "no_effect", behavior: "no_effect" };
  const destination = action.kind === "drag" ? globalPoint(snapshot, action.to) : undefined;
  if (action.kind === "drag" && !destination) return { ...audit, status: "failed", code: "invalid_drag", error: "drag requires a finite destination." };
  const response = await requestComputerUseHelper(helperCommandDirectory, "accessibilityInteraction", {
    accessibilityInteraction: {
      point: { processID: snapshot.pid, capturedAt: snapshot.model.captured_at,
        windowID: route.windowID, x: route.global.x, y: route.global.y },
      kind: action.kind,
      ...(route.elementID ? { elementID: route.elementID } : {}),
      ...(["type", "select_text"].includes(action.kind) ? { text: action.text, replace: action.replace === true, submit: action.submit === true } : {}),
      ...(action.kind === "type" ? { inputMethod: action.input_method ?? "keyboard" } : {}),
      ...(["click", "drag"].includes(action.kind) && (action.input_method === "pointer" || multiClick(action)) ? { inputMethod: "pointer" } : {}),
      ...(action.kind === "click" && action.click_count > 1 ? { clickCount: action.click_count } : {}),
      ...(action.kind === "click" && action.modifiers?.length ? { modifiers: action.modifiers } : {}),
      ...(action.kind === "perform_action" && action.name !== undefined ? { actionName: action.name } : {}),
      ...(action.kind === "long_press" ? { durationMs: action.duration_ms ?? 800 } : {}),
      ...(action.kind === "drag" && action.duration_ms !== undefined ? { durationMs: action.duration_ms } : {}),
      ...(destination ? { toX: destination.x, toY: destination.y } : {}),
      ...(action.kind === "scroll" ? { direction: action.direction, amount: action.amount ?? 3 } : {}),
    },
  }, { timeoutMs: 10_000, pollMs: 25 });
  if (response.success !== true || !response.stdout) {
    return { ...audit, requested: point, status: "failed", code: "native_action_unavailable",
      error: response.error || "The helper could not execute the native action." };
  }
  const native = JSON.parse(response.stdout);
  const resolved = nativeActionAudit(snapshot, native, action.kind === "drag" ? { from: action.from, to: action.to } : point);
  if (native.submit_ready && native.status === "completed") {
    // Spatial resolution and editing already used the exact retained field.
    // Reuse the existing background keyboard path, which performs no hit-test.
    const returned = await requestComputerUseHelper(helperCommandDirectory,"sendHotkey",{
      processID:snapshot.pid,capturedAt:snapshot.model.captured_at,keys:["return"],
      keyboardElementID:native.element_id,
    },{timeoutMs:10_000,pollMs:25});
    const receipt=returned.success===true && returned.stdout ? JSON.parse(returned.stdout) : undefined;
    const error=receipt?.dispatch_error ?? (returned.success!==true ? returned.error : undefined);
    if(receipt?.input_trace_ids?.length)resolved.input_trace_ids=[...(resolved.input_trace_ids ?? []),...receipt.input_trace_ids];
    resolved.native_operations.push({ kind: "keyboard", name: "Return", receiver_id: native.element_id,
      outcome: error ? "failed" : "dispatched" });
    if (error) return { ...audit, ...resolved, status: "failed", code: "background_submit_failed", error,
      effect: "text_changed_submit_failed" };
    resolved.effect = "text_changed_return_dispatched";
  }
  return { ...audit, ...resolved };
}

async function refreshLatestAirpointObservation() {
  if (!latestAirpointObservation) return null;
  return captureAirpointObservation(latestAirpointObservation.appTarget, undefined, latestAirpointObservation.scopeWindowID, latestAirpointObservation);
}

// An app that was not frontmost took the front after this action (for example
// Finder activating itself on Cmd+N). The helper already restored the user's
// app; the agent is told so it can choose another approach if it repeats.
async function attachForegroundGuard(result, sinceMs) {
  if (!result || typeof result !== "object") return;
  const response = await requestComputerUseHelper(helperCommandDirectory, "foregroundGuardEvents", { sinceMs }, { timeoutMs: 5_000, pollMs: 25 }).catch(() => undefined);
  if (response?.success !== true || !response.stdout) return;
  const events = JSON.parse(response.stdout);
  if (events.length) result.foreground_guard = events.map(e => ({ outcome: e.outcome, took_front: e.intruder_name ?? e.intruder_pid,
    restored_to: e.previous_name ?? e.previous_pid, ...(e.restore_ms != null ? { restore_ms: e.restore_ms } : {}) }));
}

async function attachInputDelivery(result) {
  if(!result.input_trace_ids?.length)return;
  const response=await requestComputerUseHelper(helperCommandDirectory,'inputDelivery',{inputTraceIDs:result.input_trace_ids},{timeoutMs:10_000,pollMs:25});
  if(response.success!==true || !response.stdout){
    result.input_delivery_error=response.error ?? 'Input delivery receipts are unavailable.';
    if(result.status!=='failed'){result.status='unconfirmed';result.code='input_delivery_unavailable';}
    return;
  }
  const receipts=JSON.parse(response.stdout);
  applyInputDelivery(result, receipts);
}

async function reportAirpointObservation(message, args) {
  if (args.window_id !== undefined && args.window_title !== undefined) {
    toolError(message.id, "ambiguous_window_scope", "Choose an exact window_id or window_title, not both.", "use"); return;
  }
  const appTarget = typeof args.app_target === "string" ? args.app_target.trim() : "";
  if (!appTarget || appTarget === "frontmost") {
    toolError(message.id, "invalid_background_target", "observe requires an explicit running app, bundle identifier, or PID.", "use");
    return;
  }
  try {
    const snapshot = await captureAirpointObservation(
      appTarget,
      typeof args.window_title === "string" ? args.window_title.trim() : undefined,
      args.window_id,
    );
    const content = [{
      type: "text",
      text: toCanonicalYaml({ status: "observed", snapshot: snapshot.model }),
    }];
    deliveredModel = snapshot.model;
    if (args.include_screenshot === true) {
      try {
        content.push(await captureAirpointSurfaceImage(snapshot));
      } catch (error) {
        // A failed optional image must not discard a valid AX observation.
        content.push({ type: "text", text: toCanonicalYaml({ screenshot_error: error?.message ?? String(error) }) });
      }
    }
    toolContentResult(message.id, content, {
      code: "computer_use_observation",
      surface: "use",
      pid: snapshot.pid,
    });
  } catch (error) {
    deliveredModel = undefined;
    toolError(message.id, "computer_use_observation_failed", error?.message ?? String(error), "use");
  }
}

async function reportAirpointActionBatch(message, args) {
  const actions = Array.isArray(args.actions) ? args.actions : [];
  if (actions.length < 1 || actions.length > 20) {
    toolError(message.id, "invalid_action_batch", "action_batch requires between 1 and 20 actions.", "use");
    return;
  }
  const settleMs = Number.isInteger(args.settle_ms)
    ? Math.min(Math.max(args.settle_ms, 0), 2_000)
    : 150;
  const batchReferences = new Map(latestAirpointObservation?.elementReferences ?? []);
  const batchSnapshot = latestAirpointObservation;
  const results = [];
  let status = "completed";
  let finalSnapshotError;
  let invalidatedObservation;
  {
    for (let index = 0; index < actions.length; index += 1) {
      let result;
      const before = latestAirpointObservation;
      const actionStartedMs = Date.now();
      try {
        result = await withActivationOnDemand({
          snapshot: before, ownerPID: process.pid, retain: true,
          request: (action, payload) => requestComputerUseHelper(helperCommandDirectory, action, payload, { timeoutMs: 10_000, pollMs: 25 }),
        }, { needed: actionNeedsActivation(actions[index]), never: ["open_app", "wait"].includes(actions[index]?.kind) }, async (activated, freshActivation) => {
          let actionResult;
          try {
            let action = actions[index];
            if (action.element !== undefined) {
              const bound = batchReferences.get(elementReferenceKey(batchSnapshot, action.element));
              const currentRef = bound && latestAirpointObservation?.nativeReferences?.get(bound.elementID);
              const current = currentRef && latestAirpointObservation.elementReferences.get(currentRef);
              if (!bound || !current || current.windowID !== bound.windowID || current.node.role !== bound.node.role) {
                actionResult = { index, kind: action.kind, status: "failed", code: "element_reference_expired", error: "The batch's retained native control is no longer present in its observed window." };
              } else { actionResult = await runAirpointAction({ ...action, element: currentRef }, index); actionResult.requested = { element: action.element }; }
            } else { actionResult = await runAirpointAction(action, index); }
          }
          catch (error) {
            if (error.actionResult) throw error;
            actionResult = { index, kind: actions[index]?.kind ?? "unknown", status: "failed",
              code: "background_action_failed", error: error.message };
          }
          // Nothing was dispatched: activate and repeat this same request once.
          if (!activated && requiresActivation(actionResult)) throw new ActivationRequired();
          // OCU's own fresh activation can move the app's focus away from the
          // observed shortcut receiver. Nothing was sent; observe once more and
          // repeat. A change the user made is never retried onto their control.
          if (freshActivation && actions[index]?.kind === "hotkey" && actionResult.code === "keyboard_target_changed" && !actionResult.input_trace_ids?.length) {
            await refreshLatestAirpointObservation();
            actionResult = await runAirpointAction(actions[index], index);
            actionResult.repeated_after_activation = true;
          }
          if (actionResult.observation_error) throw Object.assign(new Error(actionResult.observation_error.message),
            { code: actionResult.observation_error.code, actionResult, snapshotError: true });
          if (settleMs > 0) await new Promise(resolve => setTimeout(resolve, settleMs));
          try {
            await refreshLatestAirpointObservation();
            confirmNativeState(actionResult, latestAirpointObservation);
            confirmWebPress(actionResult, latestAirpointObservation);
            confirmSelection(actionResult, latestAirpointObservation);
            const submitTarget=confirmedTextSubmitTarget(actionResult,latestAirpointObservation);
            await attachInputDelivery(actionResult);
            if(submitTarget && !['failed','unconfirmed'].includes(actionResult.status)){
              const submission=await runAirpointAction({kind:'confirm',element:submitTarget},index);
              actionResult.native_operations.push(...submission.native_operations ?? []);
              actionResult.input_trace_ids=[...(actionResult.input_trace_ids ?? []),...(submission.input_trace_ids ?? [])];
              actionResult.status=submission.status;actionResult.effect=submission.effect ?? 'text_changed_submit_dispatched';
              if(submission.error){actionResult.error=submission.error;actionResult.code=submission.code;}
              if(settleMs>0)await new Promise(resolve=>setTimeout(resolve,settleMs));
              await refreshLatestAirpointObservation();
              await attachInputDelivery(actionResult);
            }
            actionResult.observed_changes = observedStateChanges(before, latestAirpointObservation);
            actionResult.observed_changes.captured_at = latestAirpointObservation.model.captured_at;
          } catch (error) {
            await attachInputDelivery(actionResult).catch(()=>{});
            throw Object.assign(error, { code: "post_action_observation_failed", actionResult, snapshotError: true });
          }
          return actionResult;
        });
      } catch (error) {
        result = interruptedActionReceipt(error, { index, kind: actions[index]?.kind ?? "unknown" });
        // Dispatch may have changed the app before throwing. Reconcile once,
        // after cleanup; never replay the action to obtain a result.
        if (error.snapshotError || error.operationError?.snapshotError) {
          invalidatedObservation = before;
          finalSnapshotError = (error.operationError || error).message;
        } else if (!error.actionResult) {
          try {
            await refreshLatestAirpointObservation();
            result.observed_changes = observedStateChanges(before, latestAirpointObservation);
          } catch (captureError) { finalSnapshotError = captureError.message; }
        }
      }
      await attachForegroundGuard(result, actionStartedMs);
      results.push(result);
      if (finalSnapshotError) {
        invalidatedObservation ??= before;
        latestAirpointObservation = undefined;
        status = "stopped"; break;
      }
      const disposition = batchDisposition(result, {
        targetExited: latestAirpointObservation?.model.application.state === "exited",
        isLast: index === actions.length - 1,
      });
      if (disposition.stop) { status = disposition.status; break; }
    }
  }
  const payload = {
    status,
    actions: results,
    snapshot: finalSnapshotError
      ? {
          available: false,
          ...(invalidatedObservation
            ? {
                application: invalidatedObservation.model.application,
                last_surface: invalidatedObservation.model.surface,
              }
            : {}),
          error: finalSnapshotError,
        }
      : latestAirpointObservation?.model ? deltaModel(deliveredModel, latestAirpointObservation.model) : {
          available: false,
          error: "No target application has been observed.",
        },
  };
  deliveredModel = finalSnapshotError ? undefined : latestAirpointObservation?.model;
  if (finalSnapshotError) payload.snapshot_error = finalSnapshotError;
  toolResult(message.id, toCanonicalYaml(payload), {
    code: status === "completed" ? "computer_use_batch_completed" : "computer_use_batch_stopped",
    surface: "use",
    actionCount: results.length,
    ...(latestAirpointObservation ? { pid: latestAirpointObservation.pid } : {}),
  });
}

function handleParentMessage(message) {
  if (message.method === "engine/reset") {
    latestAirpointObservation = undefined; deliveredModel = undefined;
    send({ jsonrpc: "2.0", id: message.id, result: { reset: true } });
    return;
  }
  if (message.id === undefined) return; // notifications need no reply
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {
      protocolVersion: message.params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "opencomputeruse-engine", version: "1.0.0" },
    } });
    return;
  }
  if (message.method === "tools/list") {
    send({ jsonrpc: "2.0", id: message.id, result: { tools: [observeDefinition, batchDefinition, permissionDefinition].map((tool) => structuredClone(tool)) } });
    return;
  }
  if (message.method === "tools/call") {
    const prepared = prepareCall(message);
    if (prepared.error) { toolError(message.id, prepared.error.code, prepared.error.message, "use"); return; }
    if (prepared.name === "observe") void enqueueAirpointOperation(() => reportAirpointObservation(message, prepared.args));
    else if (prepared.name === "action_batch") void enqueueAirpointOperation(() => reportAirpointActionBatch(message, prepared.args));
    else void reportPermissionStatus(message);
    return;
  }
  send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
}

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  try {
    handleParentMessage(JSON.parse(line));
  } catch (error) {
    process.stderr.write(`Invalid MCP message: ${error.message}\n`);
  }
});
input.on("close", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));
