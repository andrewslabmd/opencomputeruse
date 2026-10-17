// Observation/cleanup is a different phase from native dispatch. A later error
// must preserve the known operation receipt; never infer that it did not run.
export function interruptedActionReceipt(error, { index, kind }) {
  const observationError = error.snapshotError ? error : error.operationError?.snapshotError ? error.operationError : null;
  const result = error.actionResult;
  return {
    ...(result ?? { index, kind, status: "failed", code: error.code || "background_action_failed", error: error.message }),
    ...(observationError ? { observation_error: { code: observationError.code, message: observationError.message } } : {}),
    ...(result && error !== observationError ? { execution_error: { code: error.code || "background_action_failed", message: error.message } } : {}),
  };
}

export function batchDisposition(result, { targetExited, isLast }) {
  // An observed lifecycle transition cannot turn a failed/uncertain native
  // operation into a completed batch, even when it was the final step.
  if (result.execution_error || result.observation_error || ["failed", "no_effect", "pending", "unconfirmed"].includes(result.status)) {
    return { stop: true, status: "stopped" };
  }
  if (targetExited) return { stop: true, status: isLast ? "completed" : "stopped" };
  return { stop: false };
}

export function applyInputDelivery(result, receipts) {
  result.input_delivery = receipts.map(r => ({ ...r, target_delivery_observed: r.received_pids.includes(r.target_pid) }));
  if (receipts.some(r => r.violation || r.received_pids.some(pid => pid !== r.target_pid))) {
    result.status = 'failed'; result.code = 'input_isolation_violation';
    result.error = 'A tagged input event was observed in another application. Keyboard dispatch has been stopped.';
  } else if (receipts.length !== result.input_trace_ids.length ||
      result.input_trace_ids.some(id => !receipts.some(r => r.trace_id === id)) ||
      receipts.some(r => !r.observer_available || !r.received_pids.includes(r.target_pid))) {
    // Never hide an actual dispatch failure behind missing observation.
    if (result.status !== 'failed') { result.status = 'unconfirmed'; result.code = 'input_delivery_unconfirmed'; }
  }
  // Foreground activity neither authorizes another receiver nor cancels the
  // retained one. Describe observer coverage without stopping unrelated work.
  if (receipts.some(r => r.foreground_pid_after != null && !r.watched_pids?.includes(r.foreground_pid_after))) {
    result.input_delivery_coverage_changed = true;
  }
}
