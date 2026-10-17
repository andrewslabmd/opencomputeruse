let lastFocusToken;

// The helper owns activation state and watches this process independently.
// Cleanup surrounds both dispatch and its post-action observation.
export async function withActionFocus({ request, snapshot, ownerPID, enabled = true, retain = false }, operation) {
  if (!enabled || !snapshot) return operation();
  let focus;
  try {
    const begin = await request('beginActionFocus', {
      processID: snapshot.pid, capturedAt: snapshot.model.captured_at, ownerProcessID: ownerPID,
    });
    if (begin.success !== true || !begin.stdout) throw new Error(begin.error || 'The native action focus could not be prepared.');
    focus = JSON.parse(begin.stdout);
    if (typeof focus.token !== 'string' || !focus.token) throw new Error('Missing native action focus token.');
  } catch (error) {
    // A lost reply is not proof activation did not occur. Reconcile by owner.
    const release = await request('releaseActionFocus', { ownerProcessID: ownerPID });
    if (release.success !== true) throw new Error(release.error || 'Native action focus cleanup was not confirmed.');
    throw error;
  }
  let result;
  let operationError;
  // Whether this action is the one that just created the owned activation.
  const fresh = focus.mode === 'synthetic' && focus.token !== lastFocusToken;
  lastFocusToken = focus.token;
  try { result = await operation({ fresh }); }
  catch (error) { operationError = error; result = error.actionResult; }
  // A tool outcome does not end an owned workflow. In particular an uncertain
  // native error can already have opened a modal dialog. Deactivating its app
  // here changes application state while the agent is still recovering from it.
  // Stop/release/disconnect, target changes and owner death own lease cleanup.
  if (retain) {
    if (result && typeof result === 'object') result.background_focus = { mode: focus.mode, cleanup: 'retained_for_workflow' };
    if (operationError) throw operationError;
    return result;
  }
  let cleanupError;
  let cleanup;
  try {
    const end = await request('endActionFocus', { focusToken: focus.token, ownerProcessID: ownerPID });
    if (end.success !== true || !end.stdout) throw new Error(end.error || 'Native action focus cleanup was not confirmed.');
    cleanup = JSON.parse(end.stdout).cleanup;
  } catch (error) { cleanupError = error; }
  if (result && typeof result === 'object') result.background_focus = { mode: focus.mode, cleanup: cleanup || 'unconfirmed' };
  if (cleanupError) throw Object.assign(cleanupError, { code: 'background_focus_cleanup_failed', actionResult: result, operationError });
  if (operationError) throw operationError;
  return result;
}

// Background activation raises the target's window in the window stack, so it
// is requested only for actions an inactive app ignores. Keyboard input and
// explicit pointer input (clicks, drags, long presses) are known in advance. Otherwise the native side
// reports app_activation_required before dispatching anything; only then is the
// same request repeated once with activation. A retained lease keeps the app
// active for the rest of the workflow.
export function actionNeedsActivation(action) {
  return action?.kind === "hotkey" ||
    (action?.kind === "type" && (action.input_method !== "accessibility" || action.submit === true)) ||
    (["click", "drag"].includes(action?.kind) && action.input_method === "pointer") ||
    multiClick(action) ||
    action?.kind === "long_press";
}

// Double/triple and modified clicks have no Accessibility equivalent: always pointer input.
export function multiClick(action) {
  return action?.kind === "click" && (action.click_count > 1 || action.modifiers?.length > 0);
}

export class ActivationRequired extends Error {
  constructor() { super("The action needs the app's background activation."); this.activationRequired = true; }
}

export function requiresActivation(result) {
  return result?.code === "app_activation_required" && !result.native_operations?.length && !result.input_trace_ids?.length;
}

// operation(activated) throws ActivationRequired only when it ran unactivated.
export async function withActivationOnDemand(context, { needed, never = false }, operation) {
  if (never) return withActionFocus({ ...context, enabled: false }, () => operation(false));
  if (!needed) {
    try { return await withActionFocus({ ...context, enabled: false }, () => operation(false)); }
    catch (error) { if (!error.activationRequired) throw error; }
  }
  return withActionFocus({ ...context, enabled: true }, focus => operation(true, focus?.fresh === true));
}
