import { randomBytes } from "node:crypto";
const nativeStateCheck = Symbol("native state check");
const nativeTextCheck = Symbol("native text check");
const nativePressCheck = Symbol("native web press check");
const nativeSelectionCheck = Symbol("native selection check");
const nativeMenuCheck = Symbol("native menu dismissal check");
function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function meaningfulString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function normalizeFrame(frame, origin) {
  if (
    !frame ||
    !finiteNumber(frame.x) ||
    !finiteNumber(frame.y) ||
    !finiteNumber(frame.w) ||
    !finiteNumber(frame.h)
  ) return undefined;
  return {
    x: Math.round(frame.x - origin.x),
    y: Math.round(frame.y - origin.y),
    width: Math.round(frame.w),
    height: Math.round(frame.h),
  };
}

function normalizeNode(node, origin) {
  if (!node || typeof node !== "object") return null;
  const normalized = {
    id: meaningfulString(node.id) ?? "unknown",
    role: meaningfulString(node.role) ?? "AXUnknown",
  };
  const subrole = meaningfulString(node.subrole);
  const name = meaningfulString(node.name);
  const value = typeof node.value === "string" ? node.value : (finiteNumber(node.value) || typeof node.value === "boolean" ? node.value : undefined);
  const identifier = meaningfulString(node.identifier);
  const frame = normalizeFrame(node.frame, origin);
  if (subrole) normalized.subrole = subrole;
  if (name) normalized.name = name;
  if (value !== undefined && value !== name) normalized.value = value;
  if (identifier) normalized.identifier = identifier;
  for (const key of ["url", "document"]) if (meaningfulString(node[key])) normalized[key] = node[key];
  if (node.enabled === false) normalized.enabled = false;
  if (node.focused === true) normalized.focused = true;
  if (typeof node.selected === "boolean") normalized.selected = node.selected;
  if (node.selection_range && Number.isSafeInteger(node.selection_range.location) && node.selection_range.location >= 0 &&
      Number.isSafeInteger(node.selection_range.length) && node.selection_range.length >= 0 &&
      Number.isSafeInteger(node.selection_range.location + node.selection_range.length)) normalized.selection_range = node.selection_range;
  if (Array.isArray(node.selection_style)) normalized.selection_style = node.selection_style;
  if (frame) normalized.frame = frame;
  if (node.offscreen === true) normalized.offscreen = true;
  const children = (Array.isArray(node.children) ? node.children : [])
    .map((child) => normalizeNode(child, origin))
    .filter(Boolean);
  if (children.length > 0) normalized.children = children;
  return normalized;
}

// Agent-facing encoding. Lossless conventions (documented to the agent):
// ids are bare native ids, valid against the observation that returned them;
// offscreen is stated on the root of an offscreen subtree and applies to all of
// it; selected appears only when true; an unfocused empty selection_range is
// omitted; a node without frame shares its parent's frame (frame: null = none).
// A subtree that is offscreen throughout cannot be acted on, so it is sent as
// one line with every distinct text it contains; scroll_to_visible on its id
// brings it back in full detail. Internal trees keep every field.
// Inside a web area, a URL on the page's own origin is sent as its path ("/a/b"),
// relative to the web area's url, which is always sent in full.
const webOrigin = url => { try { const origin = new URL(url).origin; return origin === "null" ? undefined : origin; } catch { return undefined; } };
const pageRelative = (url, origin) => origin && url.startsWith(`${origin}/`) ? url.slice(origin.length) : url;
const summaryText = (node, origin) => {
  const parts = [];
  (function walk(n) {
    for (const key of ["name", "value", "identifier", "url", "document"]) {
      const v = key === "url" && typeof n.url === "string" ? pageRelative(n.url, origin) : n[key];
      if (typeof v === "string" && v.trim()) parts.push(v.trim());
      else if (key === "value" && (finiteNumber(v) || typeof v === "boolean")) parts.push(String(v));
    }
    (n.children ?? []).forEach(walk);
  })(node);
  return [...new Set(parts)].join(" · ");
};
const allOffscreen = node => node.offscreen === true && (node.children ?? []).every(allOffscreen);
const anyTrue = (node, key) => node[key] === true || (node.children ?? []).some(child => anyTrue(child, key));
const frameArray = frame => [frame.x, frame.y, frame.width, frame.height];
const sameFrame = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const carriesState = node => ["name", "value", "identifier", "url", "document", "selection_range", "selection_style"].some(key => node[key] !== undefined) ||
  node.focused === true || node.selected === true || node.enabled === false;
// A web layout group (div) with no subrole beyond AXEmptyGroup and no text or
// state. Its native identity and any operation it owns remain in the internal
// tree: a click on a shown descendant or point still reaches it.
const bareGroup = node => node.role === "AXGroup" && [undefined, "AXEmptyGroup"].includes(node.subrole) && !carriesState(node);
const repeatsName = (child, parent) => child.role === "AXStaticText" && parent.name !== undefined && child.name === parent.name &&
  !child.children?.length && !carriesState({ ...child, name: undefined });

// Agent view of the tree: what is shown, never what exists. Bare groups with
// nothing inside are omitted, a bare group around one node shows that node in
// its place, and a text that only repeats its parent's name is folded into the
// parent. Every named, valued, stateful or non-group node is kept.
function visibleChildren(node) {
  const children = (node.children ?? []).flatMap(visibleNodes).filter(child => !repeatsName(child, node));
  const { children: _, ...rest } = node;
  return children.length ? { ...rest, children } : rest;
}
function visibleNodes(node) {
  const shown = visibleChildren(node);
  return bareGroup(node) && (shown.children?.length ?? 0) <= 1 ? shown.children ?? [] : [shown];
}

function modelNode(node, parent, origin) {
  const output = { id: node.id, role: node.role };
  const offscreenRoot = node.offscreen === true && parent?.offscreen !== true;
  if (offscreenRoot && node.children?.length && allOffscreen(node)) {
    output.offscreen = true;
    const text = summaryText(node, origin);
    if (text) output.text = text;
    for (const key of ["selected", "focused"]) if (anyTrue(node, key)) output[key] = true;
    return output;
  }
  for (const key of ["subrole", "name", "value", "identifier", "url", "document", "enabled", "focused"]) {
    if (node[key] !== undefined) output[key] = node[key];
  }
  const page = node.role === "AXWebArea" && node.url ? webOrigin(node.url) : undefined;
  if (output.url && !page) output.url = pageRelative(output.url, origin);
  if (node.selected === true) output.selected = true;
  const range = node.selection_range;
  if (range && (node.focused === true || range.location !== 0 || range.length !== 0)) output.selection_range = range;
  if (node.selection_style !== undefined) output.selection_style = node.selection_style;
  if (!node.frame) { if (parent && parent.frame) output.frame = null; }
  else if (!parent || !sameFrame(node.frame, parent.frame)) output.frame = frameArray(node.frame);
  if (offscreenRoot) output.offscreen = true;
  if (node.children?.length) output.children = node.children.map(child => modelNode(child, node, page ?? origin));
  return output;
}

// A window's root is always shown as itself; its frame, when equal to the
// window's, is inherited from the window like any other node's, and a name
// equal to the window title is stated once, as the title.
function modelTree(tree, window) {
  const root = visibleChildren(tree);
  if (root.name !== undefined && root.name === window.title) delete root.name;
  return modelNode(root, { frame: window.frame });
}

export function normalizeAirpointSnapshot(raw) {
  const rawWindows = raw?.surface?.windows;
  const surfaceFrame = raw?.surface?.frame;
  if (raw?.app && Number.isInteger(raw.app.pid) &&
      (raw?.surface?.processExited === true || raw?.surface?.unavailable === true || Number.isInteger(raw?.surface?.closedWindowID) || Number.isInteger(raw?.surface?.unavailableWindowID)) &&
      Array.isArray(rawWindows) && rawWindows.length === 0 && raw.nodeCount === 0) {
    return { model: { application: { name: raw.app.name ?? "Unknown application", pid: raw.app.pid,
        ...(raw.surface.processExited === true ? { state: "exited" } : {}) },
      surface: { available: false, window_count: 0, windows: [],
        ...(Number.isInteger(raw.surface.closedWindowID) ? { closed_window_id: raw.surface.closedWindowID } :
          Number.isInteger(raw.surface.unavailableWindowID) ? { unavailable_window_id: raw.surface.unavailableWindowID } : {}) },
      captured_at: raw.capturedAt, node_count: 0,
      coordinate_space: { origin: "application-surface", units: "points", width: 0, height: 0 } },
      pid: raw.app.pid, origin: { x: 0, y: 0 }, internalWindows: [], captureWindowIDs: [], preservation: raw.preservation };
  }
  if (
    !raw ||
    typeof raw !== "object" ||
    !raw.app ||
    !Array.isArray(rawWindows) ||
    rawWindows.length === 0 ||
    !surfaceFrame ||
    !finiteNumber(surfaceFrame.x) ||
    !finiteNumber(surfaceFrame.y) ||
    !finiteNumber(surfaceFrame.w) ||
    !finiteNumber(surfaceFrame.h) ||
    surfaceFrame.w <= 0 ||
    surfaceFrame.h <= 0
  ) {
    throw new Error("The helper returned an invalid Accessibility snapshot.");
  }
  const origin = { x: surfaceFrame.x, y: surfaceFrame.y };
  const internalWindows = rawWindows
    .map((window, index) => {
      if (!window?.tree) return null;
      const tree = normalizeNode(window.tree, origin);
      const frame = normalizeFrame(window.frame, origin) ?? tree?.frame;
      if (!tree || !frame) return null;
      return {
        windowID: window.windowID,
        title: meaningfulString(window.title),
        zIndex: Number.isInteger(window.zIndex) ? window.zIndex : index,
        frame,
        tree,
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.zIndex - right.zIndex);
  if (internalWindows.length === 0) {
    throw new Error("The helper returned an application surface without accessible windows.");
  }
  const generation = randomBytes(8).toString("hex");
  const elementReferences = new Map();
  const nativeReferences = new Map();
  for (const window of internalWindows) {
    const pending = [window.tree];
    while (pending.length) {
      const node = pending.pop();
      const reference = `${generation}/${node.id}`;
      if (nativeReferences.has(node.id)) throw new Error("Duplicate native element identity in snapshot.");
      nativeReferences.set(node.id, reference);
      elementReferences.set(reference, { windowID: window.windowID, elementID: node.id, node });
      pending.push(...(node.children ?? []));
    }
  }
  const model = {
    observation: generation,
    application: {
      name: meaningfulString(raw.app.name) ?? "Unknown application",
      pid: raw.app.pid,
    },
    surface: {
      available: true,
      window_count: internalWindows.length,
      capture_window_count: Array.isArray(raw.surface.captureWindowIDs)
        ? raw.surface.captureWindowIDs.length
        : internalWindows.length,
      windows: internalWindows.map((window) => ({
        window_id: window.windowID,
        ...(window.title ? { title: window.title } : {}),
        z_index: window.zIndex,
        frame: frameArray(window.frame),
        tree: modelTree(window.tree, window),
      })),
    },
    captured_at: raw.capturedAt,
    ...(raw.collectionRestarts ? { collection_restarts: raw.collectionRestarts } : {}),
    node_count: raw.nodeCount,
    coordinate_space: {
      origin: "application-surface",
      units: "points",
      width: Math.round(surfaceFrame.w),
      height: Math.round(surfaceFrame.h),
    },
  };
  const bundleIdentifier = meaningfulString(raw.app.bundleIdentifier);
  if (bundleIdentifier) model.application.bundle_id = bundleIdentifier;
  return {
    model,
    generation, elementReferences, nativeReferences,
    internalWindows,
    captureWindowIDs: Array.isArray(raw.surface.captureWindowIDs)
      ? raw.surface.captureWindowIDs
      : internalWindows.map((window) => window.windowID),
    origin,
    pid: raw.app.pid,
    preservation: raw.preservation,
  };
}

function quoteYamlString(value) {
  return JSON.stringify(value);
}

function yamlScalar(value) {
  if (typeof value === "string") return quoteYamlString(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (value === null) return "null";
  return quoteYamlString(String(value));
}

export function toCanonicalYaml(value) {
  // Compact representation preserves the full hierarchy. It is an encoding
  // optimization, not a guarantee about any client's result-size threshold.
  const flow = (item) => {
    if (Array.isArray(item)) return `[${item.map(flow).join(",")}]`;
    if (item && typeof item === "object") {
      return `{${Object.entries(item).filter(([, v]) => v !== undefined)
        .map(([key, v]) => `${quoteYamlString(key)}:${flow(v)}`).join(",")}}`;
    }
    return yamlScalar(item);
  };
  return flow(value);
}

function contains(frame, point) {
  return Boolean(
    frame &&
      point.x >= frame.x &&
      point.y >= frame.y &&
      point.x < frame.x + frame.width &&
      point.y < frame.y + frame.height,
  );
}

function pointIsValid(point) {
  return Boolean(point && finiteNumber(point.x) && finiteNumber(point.y));
}

// This validates coordinate space only. Native resolution, operation selection
// and execution are one helper request; JavaScript never predicts a behavior.
// Agents receive bare native ids; prefixed references remain accepted.
export function elementReferenceKey(snapshot, reference) {
  return typeof reference === "string" && !reference.includes("/") && snapshot?.generation ? `${snapshot.generation}/${reference}` : reference;
}

export function resolveAirpointElement(snapshot, reference, { allowOffscreen = false } = {}) {
  const key = elementReferenceKey(snapshot, reference);
  const target = typeof key === "string" ? snapshot?.elementReferences?.get(key) : undefined;
  if (!target) return { ok: false, code: "element_reference_expired", message: "Use an element id from the latest snapshot. The old reference is no longer actionable." };
  if (target.node.offscreen && !allowOffscreen) return { ok: false, code: "target_offscreen", message: "The control is offscreen. Use native scroll_to_visible on its reference or scroll its owning container, then inspect the returned state." };
  const frame = target.node.frame ?? snapshot.internalWindows.find(w => w.windowID === target.windowID)?.frame;
  if (!frame) return { ok: false, code: "coordinate_space_unavailable", message: "The retained target has no window geometry." };
  return { ok: true, windowID: target.windowID, elementID: target.elementID,
    global: globalPoint(snapshot, { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 }) };
}

export function resolveAirpointPoint(snapshot, point) {
  if (!snapshot?.internalWindows?.length || !snapshot.origin) {
    return { ok: false, code: "coordinate_space_unavailable", message: "The target has no application-surface coordinate space." };
  }
  if (!pointIsValid(point)) {
    return { ok: false, code: "invalid_point", message: "The action requires finite application-surface coordinates." };
  }
  const space = snapshot.model.coordinate_space;
  if (point.x < 0 || point.y < 0 || point.x >= space.width || point.y >= space.height) {
    return { ok: false, code: "point_outside_surface", message: "The action point is outside the latest application surface." };
  }
  function covers(node) {
    if (!node.offscreen && contains(node.frame, point)) return true;
    return node.children?.some(covers) === true;
  }
  function ownsOverflow(window) {
    const root = window.tree.frame;
    // Conflicting window/root geometry cannot establish an overflow scope.
    return root && ["x", "y", "width", "height"].every(key => root[key] === window.frame[key]) &&
      window.tree.children?.some(covers) === true;
  }
  // A retained menu/popover can extend beyond its owning window. Geometry
  // selects the scope only; live AX hit ancestry still validates the receiver.
  const window = snapshot.internalWindows.find(window => contains(window.frame, point) || ownsOverflow(window));
  return window
    ? { ok: true, windowID: window.windowID, global: globalPoint(snapshot, point) }
    : { ok: true, noEffect: true };
}

export function nativeActionAudit(snapshot, result, requested) {
  if (!result || !["completed", "failed", "no_effect", "pending", "sent", "unconfirmed"].includes(result.status) ||
      typeof result.behavior !== "string" || !Array.isArray(result.operations)) {
    throw new Error("The helper returned a malformed native action result.");
  }
  let element;
  function find(node, id) {
    if (node.id === id) return node;
    for (const child of node.children ?? []) { const match = find(child, id); if (match) return match; }
  }
  if (result.element_id) {
    for (const window of snapshot.internalWindows) { element = find(window.tree, result.element_id); if (element) break; }
    if (!element) throw new Error("The native action referred to an element outside the observation.");
  }
  const audit = {
    requested, status: result.status, behavior: result.behavior,
    ...(element ? { resolved_element: { id: element.id, role: element.role,
      ...(element.name ? { name: element.name } : {}), ...(element.frame ? { frame: element.frame } : {}) } } : {}),
    observation_captured_at: snapshot.model.captured_at,
    native_operations: result.operations.map(operation => {
      let receiver;
      for (const window of snapshot.internalWindows) { receiver = find(window.tree, operation.receiver_id); if (receiver) break; }
      if (!receiver) throw new Error("The native operation receiver is outside the observation.");
      return { ...operation, receiver: { id: receiver.id, role: receiver.role,
        ...(receiver.name ? { name: receiver.name } : {}), ...(receiver.frame ? { frame: receiver.frame } : {}) } };
    }),
    ...(result.effect ? { effect: result.effect } : {}),
    ...(result.code ? { code: result.code } : {}),
    ...(result.error ? { error: result.error } : {}),
    ...(result.supported ? { supported: result.supported.map(item => ({ ...item, id: item.id })) } : {}),
    ...(Array.isArray(result.input_trace_ids) ? { input_trace_ids: result.input_trace_ids } : {}),
  };
  if (result.behavior === "cancel_menu" && result.status === "sent") {
    const window = snapshot.internalWindows.find(w => find(w.tree, result.element_id));
    if (!window || element?.role !== "AXMenu") throw new Error("The menu cancellation receiver is outside the observation.");
    audit[nativeMenuCheck] = { pid: snapshot.pid, windowID: window.windowID };
  }
  if (result.state_check) {
    const check = result.state_check;
    const window = snapshot.internalWindows.find(w => find(w.tree, check.receiver_id));
    if (!window || check.property !== "value" || !["increase", "decrease", "equals"].includes(check.comparison) ||
        (check.comparison !== "equals" && !finiteNumber(check.before)) || !["scroll_position_changed", "value_matches"].includes(check.matched_effect) ||
        (check.comparison === "equals" && (!finiteNumber(check.expected) || !finiteNumber(check.tolerance) || check.tolerance < 0))) {
      throw new Error("The native action returned an invalid state check.");
    }
    // Execution metadata stays private; the model receives measured confirmation
    // and the ordinary complete snapshot, not duplicated expected content.
    audit[nativeStateCheck] = { ...check, windowID: window.windowID, pid: snapshot.pid };
  }
  // Web content can accept AXPress without delivering it to the page. Keep a
  // private fingerprint of the receiver's window to confirm against the fresh
  // post-action capture; native AppKit presses keep their existing semantics.
  // Window-bound pointer input and keystrokes to a surface without an editor
  // are likewise dispatch receipts, not effects.
  const press = result.status === "completed" && result.behavior === "press" &&
    result.operations.find(operation => operation.name === "AXPress");
  const pointer = result.status === "sent" && surfaceInput(result) &&
    result.operations.find(operation => ["pointer", "keyboard"].includes(operation.kind));
  if (press || pointer) {
    for (const window of snapshot.internalWindows) {
      const path = ancestry(window.tree, (press || pointer).receiver_id);
      if (pointer ? path : path?.some(node => node.role === "AXWebArea")) {
        audit[nativePressCheck] = { windowID: window.windowID, pid: snapshot.pid, before: window,
          windowIDs: snapshot.internalWindows.map(w => w.windowID) };
        break;
      }
    }
  }
  if (result.selection_check) {
    const window = snapshot.internalWindows.find(w => find(w.tree, result.selection_check.receiver_id));
    if (!window) throw new Error("The native action returned an invalid selection check.");
    audit[nativeSelectionCheck] = { itemID: result.selection_check.receiver_id, windowID: window.windowID, pid: snapshot.pid, before: window };
  }
  if (result.text_check) {
    const check=result.text_check;
    const window=snapshot.internalWindows.find(w=>find(w.tree,check.receiver_id));
    if (!window || (check.expected !== undefined && typeof check.expected !== 'string') || typeof check.submit !== 'boolean') throw new Error('Invalid native text input check.');
    audit[nativeTextCheck]={...check,windowID:window.windowID,pid:snapshot.pid};
  }
  return audit;
}

function ancestry(node, id, path = []) {
  const current = [...path, node];
  if (node.id === id) return current;
  for (const child of node.children ?? []) { const match = ancestry(child, id, current); if (match) return match; }
}

// Selection that the immediate readback could not show: the item selected in
// the fresh capture, or its window changing (an app navigating on selection),
// confirms it; otherwise it is unconfirmed, never repeated.
export function confirmSelection(result, snapshot) {
  const check = result[nativeSelectionCheck];
  if (!check || result.status !== "completed") return result;
  const after = snapshot?.pid === check.pid && snapshot.internalWindows?.find(w => w.windowID === check.windowID);
  const find = node => node.id === check.itemID ? node : (node.children ?? []).map(find).find(Boolean);
  if (after && find(after.tree)?.selected === true) { result.effect = "selection_set"; return result; }
  const scoped = window => ({ internalWindows: [window], model: { application: {}, surface: {} } });
  if (!after || observedStateChanges(scoped(check.before), scoped(after)).count > 0) { result.effect = "selection_changed_window"; return result; }
  result.status = "unconfirmed"; result.code = "selection_not_confirmed"; result.effect = "selection_unconfirmed";
  return result;
}

function surfaceInput(result) {
  return /^pointer_/.test(result.behavior) || result.behavior === "keyboard_text";
}

export function confirmWebPress(result, snapshot) {
  const check = result[nativePressCheck];
  const pointer = surfaceInput(result);
  if (!check || result.status !== (pointer ? "sent" : "completed")) return result;
  // Use the same change definition the agent receives in observed_changes,
  // scoped to the receiver's window. A closed/unavailable window is a change.
  const after = snapshot?.pid === check.pid && snapshot.internalWindows?.find(w => w.windowID === check.windowID);
  const scoped = window => ({ internalWindows: [window], model: { application: {}, surface: {} } });
  // A window the input opened or closed (a toolbar bubble, a popover) is its effect.
  const windowIDs = snapshot?.internalWindows?.map(w => w.windowID) ?? [];
  const windowsChanged = windowIDs.length !== check.windowIDs.length || windowIDs.some(id => !check.windowIDs.includes(id));
  if (after && check.before && !windowsChanged && observedStateChanges(scoped(check.before), scoped(after)).count === 0) {
    // Accepted is not delivered: stop dependent steps without claiming rejection
    // or replaying; the effect may also still be pending in the page.
    // A device mirror, remote screen or canvas can change only in its pixels:
    // the fresh Accessibility tree cannot show it, so check with a screenshot.
    result.status = "unconfirmed";
    result.code = !pointer ? "press_effect_unobserved" : result.behavior === "keyboard_text" ? "keyboard_effect_unobserved" : "pointer_effect_unobserved";
    result.effect = pointer ? `${result.behavior}_no_observed_change` : "web_press_no_observed_change";
  }
  return result;
}

export function confirmedTextSubmitTarget(result,snapshot) {
  const check=result[nativeTextCheck];
  return check?.submit && result.status==='completed' ? snapshot.nativeReferences.get(check.receiver_id) : undefined;
}

export function confirmNativeState(result, snapshot) {
  const menu = result[nativeMenuCheck];
  if (menu && result.status === "sent") {
    const window = snapshot?.pid === menu.pid && snapshot.internalWindows?.find(w => w.windowID === menu.windowID);
    const visibleItem = node => (node.role === "AXMenuItem" && !node.offscreen && node.frame?.width > 0 && node.frame?.height > 0) ||
      (node.children ?? []).some(visibleItem);
    const visibleMenu = node => (node.role === "AXMenu" && visibleItem(node)) || (node.children ?? []).some(visibleMenu);
    const dismissed = Boolean(window && !visibleMenu(window.tree));
    result.state_confirmation = { property: "menu_visible", matched: dismissed };
    result.status = dismissed ? "completed" : "unconfirmed";
    result.effect = dismissed ? "menu_dismissed" : "menu_dismissal_unconfirmed";
    if (!dismissed) result.code = "menu_dismissal_unconfirmed";
  }
  const text=result[nativeTextCheck];
  if (text && result.status==='sent') {
    const window=snapshot?.pid===text.pid && snapshot.internalWindows.find(w=>w.windowID===text.windowID);
    function find(node){if(node.id===text.receiver_id)return node;for(const c of node.children??[]){const n=find(c);if(n)return n;}}
    const actual=window && find(window.tree)?.value;
    if (typeof text.expected==='string') {
      const matched=actual===text.expected;
      result.state_confirmation={property:'value',matched};
      result.status=matched?'completed':'unconfirmed';result.effect=matched?'text_value_matches':'text_input_unconfirmed';
      if(!matched)result.code='state_change_unconfirmed';
    } else if(text.submit) {result.status='unconfirmed';result.code='text_value_unavailable';result.effect='text_input_sent_submit_unconfirmed';}
  }
  const check = result[nativeStateCheck];
  if (!check || result.status !== "completed") return result;
  const window = snapshot?.pid === check.pid && snapshot.internalWindows?.find(w => w.windowID === check.windowID);
  function find(node) {
    if (node.id === check.receiver_id) return node;
    for (const child of node.children ?? []) { const match = find(child); if (match) return match; }
  }
  const actual = window && find(window.tree)?.[check.property];
  const matched = finiteNumber(actual) && (check.comparison === "equals" ? Math.abs(actual-check.expected) <= check.tolerance
    : check.comparison === "increase" ? actual > check.before : actual < check.before);
  result.state_confirmation = { property: check.property, ...(finiteNumber(check.before) ? { before: check.before } : {}),
    ...(finiteNumber(actual) ? { after: actual } : {}), matched };
  if (matched) result.effect = check.matched_effect;
  else {
    // Unconfirmed is not proof of an ignored write or an ongoing native call.
    // Stop dependent batch steps; let the agent inspect/replan from actual state.
    result.status = "unconfirmed"; result.code = "state_change_unconfirmed";
    result.effect = check.matched_effect === "scroll_position_changed" ? "scroll_position_unconfirmed" : "value_unconfirmed";
  }
  return result;
}

export function observedStateChanges(before, after) {
  function stable(value) {
    if (Array.isArray(value)) return value.map(stable);
    if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(k => [k, stable(value[k])]));
    return value;
  }
  const changes = [];
  const moved = new Map();
  if (after?.model.application.state === "exited" && before?.model.application.state !== "exited") {
    changes.push({ property: "process", pid: after.pid, before: "running", after: "exited" });
  }
  // Diff the complete internal trees, not the agent encoding: collapsed
  // offscreen summaries must not turn scrolling into appearing/disappearing UI.
  const windowsOf = snapshot => snapshot?.internalWindows
    ? snapshot.internalWindows.map(w => ({ window_id: w.windowID, title: w.title, tree: w.tree }))
    : snapshot?.model?.surface?.windows ?? [];
  const oldWindows = windowsOf(before);
  const newWindows = windowsOf(after);
  const unavailable = after?.model?.surface?.unavailable_window_id;
  const scopedAbsent = after?.model?.surface?.closed_window_id ?? unavailable;
  const unavailableApp = scopedAbsent === undefined && after?.model?.surface?.available === false && after?.model?.application?.state !== "exited";
  for (const window of oldWindows) if ((scopedAbsent === undefined || scopedAbsent === window.window_id) && !newWindows.some(w => w.window_id === window.window_id)) changes.push({ window_id: window.window_id, property: "window", before: "present", after: unavailableApp || unavailable === window.window_id ? "not_observable" : "absent" });
  for (const window of newWindows) {
    const previous = oldWindows.find(w => w.window_id === window.window_id);
    if (!previous) { changes.push({ window_id: window.window_id, property: "window", before: "absent", after: "present", title: window.title }); continue; }
    if (previous.title !== window.title) changes.push({ window_id: window.window_id, property: "title", before: previous.title, after: window.title });
    function index(tree) {
      const map = new Map();
      function walk(node, path) {
        const key = `${path}:${node.role}:${node.identifier ?? node.name ?? ""}`;
        map.set(key, node);
        (node.children ?? []).forEach((child, i) => walk(child, `${path}/${i}`));
      }
      walk(tree, ""); return map;
    }
    const oldNodes = index(previous.tree);
    const newNodes = index(window.tree);
    // Web panels are often plain groups, not menu/sheet roles, and sibling
    // inserts shift path keys. Compare named controls as a multiset so an
    // opened or closed panel is reported instead of looking like no change.
    const named = tree => {
      const counts = new Map();
      (function walk(node) {
        if (node.name && node.name.length <= 256) { const key = `${node.role}\u0000${node.name}`; counts.set(key, (counts.get(key) ?? 0) + 1); }
        (node.children ?? []).forEach(walk);
      })(tree);
      return counts;
    };
    const oldNamed = named(previous.tree), newNamed = named(window.tree);
    const difference = (left, right) => [...left].flatMap(([key, count]) =>
      Array(Math.max(0, count - (right.get(key) ?? 0))).fill(key)).map(key => { const [role, name] = key.split("\u0000"); return { role, name }; });
    const added = difference(newNamed, oldNamed), removed = difference(oldNamed, newNamed);
    if (added.length || removed.length) changes.push({ window_id: window.window_id, property: "named_elements",
      added: added.length, removed: removed.length,
      ...(added.length ? { added_examples: added.slice(0, 8) } : {}), ...(removed.length ? { removed_examples: removed.slice(0, 8) } : {}) });
    const transient = node => ["AXMenu", "AXSheet", "AXDialog", "AXPopover"].includes(node.role) && !node.offscreen && node.frame?.width > 0 && node.frame?.height > 0;
    for (const [key, node] of oldNodes) if (transient(node) && !newNodes.has(key)) changes.push({window_id:window.window_id,role:node.role,property:"present",before:true,after:false});
    for (const [key, node] of newNodes) {
      const old = oldNodes.get(key);
      if (!old) {
        if (transient(node)) changes.push({window_id:window.window_id,role:node.role,property:"present",before:false,after:true});
        continue;
      }
      for (const property of ["value", "selected", "selection_range", "selection_style", "focused", "frame"]) {
        if (JSON.stringify(stable(old[property])) === JSON.stringify(stable(node[property]))) continue;
        if (property === "frame") { moved.set(window.window_id, (moved.get(window.window_id) ?? 0) + 1); continue; }
        const summarize = value => typeof value === "string" && value.length > 256 ? { character_count: value.length, summary_only: true } : value ?? null;
        changes.push({ window_id: window.window_id, role: node.role, element_id: node.id,
          ...(node.name && node.name.length <= 256 ? { name: node.name } : {}), property, before: summarize(old[property]), after: summarize(node[property]) });
      }
    }
  }
  // Moved or resized elements are counted per window: the fresh snapshot
  // carries each one's new frame, so listing them would repeat it.
  for (const [window_id, elements] of moved) changes.push({ window_id, property: "frame", elements });
  const count = changes.length - moved.size + [...moved.values()].reduce((sum, n) => sum + n, 0);
  return { count, items: changes.slice(0, 32) };
}

// Post-action results describe only what differs from the snapshot the agent
// last received. An identical subtree becomes its bare id string in place of the
// node, and an identical window a stub with `unchanged: true`; new or changed
// nodes are complete. Ids are stable for
// the same native control, so the agent's previous copy stays authoritative
// for stubs. A different process or no previous delivery yields the full model.
export function deltaModel(previous, current) {
  if (!previous || !current?.surface?.available || previous.application?.pid !== current.application?.pid) return current;
  const serialized = new Map();
  (function index(node) { serialized.set(node.id, JSON.stringify(node)); (node.children ?? []).forEach(index); })
    ({ id: "\u0000", children: (previous.surface?.windows ?? []).map(w => w.tree) });
  let stubbed = 0;
  const delta = node => {
    if (serialized.get(node.id) === JSON.stringify(node)) { stubbed += 1; return node.id; }
    return node.children ? { ...node, children: node.children.map(delta) } : node;
  };
  const prior = new Map((previous.surface?.windows ?? []).map(w => [w.window_id, JSON.stringify(w)]));
  const windows = current.surface.windows.map(w => prior.get(w.window_id) === JSON.stringify(w)
    ? { window_id: w.window_id, ...(w.title ? { title: w.title } : {}), unchanged: true }
    : { ...w, tree: delta(w.tree) });
  if (!stubbed && windows.every(w => !w.unchanged)) return current;
  return { ...current, changes_since: previous.observation, surface: { ...current.surface, windows } };
}

export function globalPoint(snapshot, point) {
  if (!snapshot?.origin || !pointIsValid(point)) return null;
  return { x: snapshot.origin.x + point.x, y: snapshot.origin.y + point.y };
}
