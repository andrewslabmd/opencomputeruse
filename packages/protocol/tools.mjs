function permissionStatusTool() {
  return {
    name: "use_permissions",
    description: "Read the current native Computer Use backend and permission status. This is a preflight-only observation and never requests permission.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
  };
}

function pointSchema(description) {
  return {
    type: "object",
    additionalProperties: false,
    description,
    properties: {
      x: { type: "number", description: "Application-surface horizontal coordinate." },
      y: { type: "number", description: "Application-surface vertical coordinate." },
    },
    required: ["x", "y"],
  };
}

function backgroundObserveTool() {
  return {
    name: "use_observe",
    description: "Observe one explicit native desktop application without activating it. When the user names a document/window, use window_title. Returns {status, snapshot}; snapshot.surface.windows contains each {window_id, title, frame, tree}. Editable nodes expose value and selection_range (UTF-16 location/length); selection_style is included when available. The full collected hierarchy is returned in a compact encoding: frame is [x, y, width, height]; inside a web area a url on the page's own origin is a path (\"/a/b\") relative to the web area's url; a node without frame has its parent's frame (frame: null means none); unnamed layout groups with no text or state are not shown (a lone child takes its place) and a text that only repeats its parent's name is folded into the parent, but clicks on what is shown still reach them; selected appears only when true; offscreen applies to the node and everything inside it; a subtree that is entirely offscreen is one line with its id, role and every text it contains (use scroll_to_visible on that id to see it in full). Node ids are native control ids from this snapshot; the same control keeps its id while it exists. Frames use application-surface coordinates; this becomes the latest state for action_batch.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        app_target: {
          type: "string",
          minLength: 1,
          description: "Running application name, bundle identifier, or PID:<number>.",
        },
        window_title: {
          type: "string",
          description: "Optional case-insensitive window-title substring.",
        },
        window_id: { type: "integer", minimum: 1, maximum: 4294967295, description: "Exact observed window ID; remains bound across title changes. Cannot be combined with window_title." },
        include_screenshot: {
          type: "boolean",
          default: false,
          description: "Also attach a fresh app-window screenshot when visual information is necessary.",
        },
      },
      required: ["app_target"],
    },
  };
}

function actionVariant(kind, properties, required = []) {
  return {
    type: "object",
    additionalProperties: false,
    properties: {
      kind: { const: kind },
      ...properties,
    },
    required: ["kind", ...required],
  };
}

function backgroundActionBatchTool() {
  const at = pointSchema("A point from the latest snapshot's application-surface coordinate space.");
  const element = { type: "string", minLength: 1, description: "Exact node id from the latest snapshot. Prefer this for native controls, including covered windows. References stay bound through one batch and expire after the next returned observation/result." };
  const target = (kind, properties = {}, required = []) => ({
    ...actionVariant(kind, { at, element, ...properties }, required),
    oneOf: [{ required: ["at"], not: { required: ["element"] } }, { required: ["element"], not: { required: ["at"] } }],
  });
  return {
    name: "use_action_batch",
    description: "Perform validated background operations on exact element references or application-surface points from the latest state. An element reference retains the observed native control and window, independent of overlapping windows. Returns {status, actions, snapshot}, not action_results. The snapshot lists only what changed since the last snapshot you received (snapshot.changes_since names it): a window with unchanged: true, or a bare id string in place of a node, is identical to your previous copy under the same id, and new or changed nodes are complete. Call use_observe for a complete snapshot. If an app jumps to the front as a reaction to OCU's own keystroke or click, OCU returns the user's app to the front and reports actions[i].foreground_guard; the user bringing any app forward themselves, or working inside the frontmost app, is never undone. actions[i] names the actual operation/receiver and observed_changes {count, items}; the fresh full snapshot already provides verification state. open invokes advertised native AXOpen; perform_action invokes one action the exact target advertises (without name it only lists them in supported); scroll_to_visible reveals an exact offscreen control without pressing it. select_text sets and verifies an exact unique substring. Text click positions the caret; type preserves current selection unless replace=true. Hotkeys check app-internal focus belongs to the observed window; sent records delivery to that app. Execution stops on invalid target, no_effect, pending call, unconfirmed state change or failure. unconfirmed means an accepted write is not confirmed by the fresh snapshot, not proof it failed. An uncertain native return may already have changed state: do not repeat it blindly. Supported target operations are included on unsupported attempts. Pointer input (click, drag with input_method pointer, long_press) is process- and window-bound; there is no physical mouse or foreground fallback. long_press holds the button at a point, then releases. A surface that changes only in its pixels (device mirror, remote screen, canvas) cannot be confirmed from the tree: those results are unconfirmed, so check with include_screenshot.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        actions: {
          type: "array",
          minItems: 1,
          maxItems: 20,
          items: {
            oneOf: [
              actionVariant("open_app", {
                name: { type: "string", minLength: 1, description: "Installed application name." },
                bundle_id: { type: "string", minLength: 1, description: "Installed application bundle identifier." },
                wait_until_ready: { type: "boolean", default: true },
              }),
              target("click", {
                input_method: { type: "string", enum: ["accessibility", "pointer"], default: "accessibility", description: "Accessibility performs the control's native operation. Pointer sends a left click bound to the observed window and app process only; it requires the app's background activation, never moves the physical cursor and never changes the foreground app. Web content without a native operation uses pointer automatically. click_count above 1 or any modifier always uses pointer: Accessibility has no equivalent." },
                click_count: { type: "integer", minimum: 1, maximum: 3, default: 1, description: "2 double-clicks, 3 triple-clicks (pointer input)." },
                modifiers: { type: "array", uniqueItems: true, maxItems: 4, items: { type: "string", enum: ["cmd", "shift", "option", "control"] }, description: "Modifiers held for the click, for example [\"cmd\"] to add an item to a selection or [\"shift\"] to extend it (pointer input). Physical modifier keys are never pressed." },
              }),
              target("right_click"),
              target("long_press", {
                duration_ms: { type: "integer", minimum: 100, maximum: 5_000, default: 800, description: "How long the left button is held before release." },
              }),
              target("open"),
              target("perform_action", {
                name: { type: "string", minLength: 1, description: "Exact Accessibility action name the target itself advertises, for example AXShowMenu, AXIncrement, AXDecrement, AXCancel, AXPick or one of the app's custom actions as listed. Omit to list the advertised actions of the target and its containers without performing anything." },
              }),
              actionVariant("scroll_to_visible", {
                element: { ...element, description: "Exact observed control to bring into view using its native AXScrollToVisible action. Supports offscreen references; does not click or focus the control. Inspect the returned snapshot for visibility." },
              }, ["element"]),
              target("type", {
                text: { type: "string", description: "Unicode text to enter." },
                input_method: { type: "string", enum: ["keyboard", "accessibility"], default: "keyboard", description: "Keyboard sends literal text through the exact editor's normal input path. On a surface that takes keys but exposes no editor (canvas, remote or device screen, game), keyboard sends the text as keystrokes to the app process, only while the app's keyboard focus is that surface or nothing; click the surface first (pointer) if focus is elsewhere. Such keystrokes cover characters on a standard US keyboard, report sent/unconfirmed, and cannot replace existing text. Accessibility directly changes an editor's value or selected text; property editing may have different application behavior." },
                replace: { type: "boolean", default: false, description: "Replace the field's current text before typing." },
                submit: { type: "boolean", default: false, description: "Perform native AXConfirm when supported; otherwise Return only if the exact field owns permitted keyboard focus." },
              }, ["text"]),
              target("select_text", { text: { type: "string", minLength: 1, description: "Exact unique substring to select, using UTF-16 range and native readback." } }, ["text"]),
              target("scroll", {
                direction: { type: "string", enum: ["up", "down", "left", "right"] },
                amount: { type: "integer", minimum: 1, maximum: 20, default: 3 },
              }, ["direction"]),
              actionVariant("drag", {
                from: pointSchema("Application-surface starting point: an adjustable control, or any point on the surface with input_method pointer."),
                to: pointSchema("Application-surface drag endpoint, inside the same window."),
                input_method: { type: "string", enum: ["accessibility", "pointer"], default: "accessibility", description: "Accessibility sets an adjustable control (slider, scroll bar) to the endpoint's value. Pointer presses at from, moves to to over duration_ms and releases, bound to the observed window and app process (a swipe on a canvas, remote or device screen); like the pointer click it needs the app's background activation, never moves the physical cursor and never changes the foreground app. Web content without an adjustable control uses pointer automatically." },
                duration_ms: { type: "integer", minimum: 0, maximum: 5_000, default: 300, description: "Pointer drag only: time from press to release. Short is a fast swipe (flick), long a slow drag." },
              }, ["from", "to"]),
              actionVariant("hotkey", {
                keys: {
                  type: "array",
                  minItems: 1,
                  maxItems: 8,
                  items: { type: "string", minLength: 1 },
                  description: "Modifier/key names, for example [\"cmd\", \"f\"].",
                },
              }, ["keys"]),
              actionVariant("wait", {
                milliseconds: { type: "integer", minimum: 25, maximum: 10_000 },
              }, ["milliseconds"]),
            ],
          },
        },
        diagnostics: {
          type: "boolean",
          default: false,
          description: "Also return each action's dispatch and delivery records (native operations, input trace ids and receipts, activation state). Only for diagnosing OCU itself.",
        },
        settle_ms: {
          type: "integer",
          minimum: 0,
          maximum: 2_000,
          default: 150,
          description: "Generic UI-settle delay before each post-action snapshot. Use a wait action for longer asynchronous changes.",
        },
      },
      required: ["actions"],
    },
  };
}


function listAppsTool() {
  return {
    name: "use_list_apps",
    description: "List running applications that have a user interface, with name, bundle_id, pid, whether each is the frontmost app or hidden, and its windows {window_id, title, on_screen}. Read-only: it activates nothing and does not start or take over a workflow. Use a name, bundle_id or PID:<pid> as use_observe's app_target, and a window_id to observe that window.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
  };
}

export const tools = [backgroundObserveTool(), backgroundActionBatchTool(), permissionStatusTool(), listAppsTool()];
