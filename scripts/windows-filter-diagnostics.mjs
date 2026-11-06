const allowedTypes = /^(?:MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other)$/;
const allowedNames = /^(?:Event|FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|DropFilteredEvents|HighlightFilteredEvents|MenuBar|ProcessMonitor|Other)$/;
export const windowsFilterOutputLimit = 8192;
export const reloadedFilterUiEvidencePattern = /^reloaded-filter-ui=items:\d+;lists:\d+;data-grids:\d+;tables:\d+;list-items:\d+;data-items:\d+(?:;dialog-window-rows:\d+;other-window-rows:\d+;unscoped-rows:\d+(?:;combo-option-rows:\d+;rule-containers:\d+;rule-row-candidates:\d+;rule-container-unclassified-rows:\d+)?)?;rows:2;truncated:false$/;
const windowsFilterOutputHeadLimit = 3072;
const windowsFilterOutputTruncationMarker = "\nPROC_MON_FILTER_OUTPUT_TRUNCATED=true\n";
const windowsFilterOutputTailLimit =
  windowsFilterOutputLimit
  - windowsFilterOutputHeadLimit
  - windowsFilterOutputTruncationMarker.length;

export function appendBoundedWindowsFilterOutput(current, chunk) {
  const combined = current + chunk;
  if (combined.length <= windowsFilterOutputLimit) return combined;
  const evidence = new Map();
  for (const match of combined.matchAll(
    /^(PROC_MON_FILTER_STARTUP_SNAPSHOT|PROC_MON_FILTER_CONFIG_PATHS|PROC_MON_FILTER_RELOADED_RULES|PROC_MON_FILTER_RELOADED_UI|PROC_MON_FILTER_RELOADED_DROP|PROC_MON_FILTER_NATIVE_CHILDREN|PROC_MON_FILTER_NATIVE_CHILD_UIA|PROC_MON_FILTER_NATIVE_CHILD_PATTERNS|PROC_MON_FILTER_NATIVE_CONTROLS|PROC_MON_FILTER_STATIC_TEXT|PROC_MON_FILTER_NATIVE_DIALOG_CANDIDATE|PROC_MON_FILTER_NATIVE_RULES|PROC_MON_FILTER_NATIVE_SHAPE|PROC_MON_FILTER_RULE_CLEAR|PROC_MON_FILTER_RULE_SELECTION|PROC_MON_FILTER_REMOVE|PROC_MON_FILTER_RULES_REMAINING|PROC_MON_FILTER_RULE_RESET|PROC_MON_FILTER_NATIVE_BUTTON_FOREGROUND|PROC_MON_FILTER_PROCESS_DROP_ITEM_SCAN|PROC_MON_FILTER_PROCESS_MENU_SCAN|PROC_MON_FILTER_MENU_SHORTCUT_INPUT|PROC_MON_FILTER_MENU_GUI_STATE|PROC_MON_FILTER_MENU_GUI_ACCESSIBLE|PROC_MON_FILTER_MENU_COMMAND|PROC_MON_FILTER_TOOLBAR_COMMAND|PROC_MON_FILTER_NATIVE_TOOLBAR_COMMAND|PROC_MON_FILTER_NATIVE_TOOLBAR_METADATA|PROC_MON_FILTER_ACCESSIBLE_TOOLBAR_COMMAND|PROC_MON_FILTER_MENU_MAIN|PROC_MON_FILTER_NATIVE_MENU|PROC_MON_FILTER_NATIVE_TOPLEVEL|PROC_MON_FILTER_MENU_LOOP_WINDOWS|PROC_MON_FILTER_MENU_LOOP_ROOTS|PROC_MON_FILTER_MENU_LOOP_STYLES|PROC_MON_FILTER_MENU_LOOP_ACCESSIBLE|PROC_MON_FILTER_MENU_LOOP_UIA|PROC_MON_FILTER_FAILED_STAGE)=[^\r\n]{1,1024}\r?\n/gm,
  )) {
    if (
      match[1] === "PROC_MON_FILTER_FAILED_STAGE"
      && describeWindowsFilterDiagnostics(match[0])
    ) {
      evidence.set(match[1], match[0].replace(/\r?\n$/, ""));
      continue;
    }
    const hasSource = match[1] === "PROC_MON_FILTER_NATIVE_CHILDREN"
      || match[1] === "PROC_MON_FILTER_NATIVE_CHILD_UIA"
      || match[1] === "PROC_MON_FILTER_NATIVE_CHILD_PATTERNS"
      || match[1] === "PROC_MON_FILTER_NATIVE_CONTROLS"
      || match[1] === "PROC_MON_FILTER_STATIC_TEXT"
      || match[1] === "PROC_MON_FILTER_NATIVE_RULES";
    const source = hasSource
      ? match[0].match(/^PROC_MON_FILTER_NATIVE_CHILD(?:REN|_UIA|_PATTERNS)=source:(main|visible-other);/)?.[1]
        ?? match[0].match(/^PROC_MON_FILTER_NATIVE_CONTROLS=source:(main|visible-other);/)?.[1]
        ?? match[0].match(/^PROC_MON_FILTER_STATIC_TEXT=source:(main|visible-other);/)?.[1]
        ?? match[0].match(/^PROC_MON_FILTER_NATIVE_RULES=phase:(initial|reloaded);/)?.[1]
      : match[1] === "PROC_MON_FILTER_NATIVE_MENU"
        ? match[0].match(/^PROC_MON_FILTER_NATIVE_MENU=source:(main|focused-root|all-top-level|active-menu-loop);/)?.[1]
      : match[1] === "PROC_MON_FILTER_MENU_LOOP_UIA"
        ? match[0].match(/^PROC_MON_FILTER_MENU_LOOP_UIA=role:(main-after-shortcut|focus|capture|menu-owner);/)?.[1]
      : match[1] === "PROC_MON_FILTER_MENU_LOOP_ACCESSIBLE"
        ? match[0].match(/^PROC_MON_FILTER_MENU_LOOP_ACCESSIBLE=role:(main-after-shortcut|focus|capture|menu-owner);object:(menu|client);/)?.slice(1).join(":")
      : undefined;
    const evidenceKey = source ? `${match[1]}:${source}` : match[1];
    if (!evidence.has(evidenceKey) && describeWindowsFilterDiagnostics(match[0])) {
      evidence.set(evidenceKey, match[0].replace(/\r?\n$/, ""));
    }
  }
  const retainedEvidence = evidence.size ? `${[...evidence.values()].join("\n")}\n` : "";
  const tailLimit = windowsFilterOutputTailLimit - retainedEvidence.length;
  return combined.slice(0, windowsFilterOutputHeadLimit)
    + windowsFilterOutputTruncationMarker
    + retainedEvidence
    + combined.slice(-tailLimit);
}

export function describeWindowsFilterDiagnostics(output) {
  const diagnostics = [];
  const startupSnapshot = output.match(
    /^PROC_MON_FILTER_STARTUP_SNAPSHOT=state:dismissed;kind:(missing-profile-pml);button:(unique-enabled-ok)\r?$/m,
  );
  if (startupSnapshot) {
    diagnostics.push(
      `startup-snapshot=state:dismissed;kind:${startupSnapshot[1]};button:${startupSnapshot[2]}`,
    );
  }
  const state = output.match(
    /PROC_MON_FILTER_MENU_STATE=(enabled:(?:true|false);offscreen:(?:true|false);keyboard-focusable:(?:true|false))/,
  )?.[1];
  if (state) diagnostics.push(`menu-state=${state}`);

  const patterns = output.match(
    /PROC_MON_FILTER_MENU_PATTERNS=(expand-collapse:(?:true|false);invoke:(?:true|false))/,
  )?.[1];
  if (patterns) diagnostics.push(`menu-patterns=${patterns}`);

  const commandPatterns = output.match(
    /PROC_MON_FILTER_COMMAND_PATTERNS=(invoke:(?:true|false);selection-item:(?:true|false))/,
  )?.[1];
  if (commandPatterns) diagnostics.push(`filter-command-patterns=${commandPatterns}`);

  const commandMatch = output.match(
    /PROC_MON_FILTER_COMMAND_MATCH=items:(\d{1,4});matches:(\d{1,4})/,
  );
  if (commandMatch) {
    diagnostics.push(
      `filter-command-match=items:${commandMatch[1]};matches:${commandMatch[2]}`,
    );
  }

  const compileError = output.match(
    /^PROC_MON_FILTER_COMPILE_ERROR=(CS\d{4})\r?$/m,
  )?.[1];
  if (compileError) {
    diagnostics.push(`filter-compile-error=${compileError}`);
  }

  const dropMenuState = output.match(
    /^PROC_MON_FILTER_DROP_MENU_STATE=owner-same-process:(true|false);enabled:(true|false);offscreen:(true|false)\r?$/m,
  );
  if (dropMenuState) {
    diagnostics.push(
      `drop-filter-menu-state=owner-same-process:${dropMenuState[1]};enabled:${dropMenuState[2]};offscreen:${dropMenuState[3]}`,
    );
  }

  const filterMenuCommand = output.match(
    /^PROC_MON_FILTER_MENU_COMMAND=state:candidate;owner:(same|other);enabled:(true|false);offscreen:(true|false);invoke:(true|false)\r?$/m,
  );
  if (filterMenuCommand) {
    diagnostics.push(
      `filter-menu-command=state:candidate;owner:${filterMenuCommand[1]};enabled:${filterMenuCommand[2]};offscreen:${filterMenuCommand[3]};invoke:${filterMenuCommand[4]}`,
    );
  }

  const filterToolbarCommand = output.match(
    /^PROC_MON_FILTER_TOOLBAR_COMMAND=items:(\d{1,2});matches:(\d{1,2})\r?$/m,
  );
  if (
    filterToolbarCommand
    && Number(filterToolbarCommand[1]) <= 64
    && Number(filterToolbarCommand[2]) <= 64
  ) {
    diagnostics.push(
      `filter-toolbar-command=items:${filterToolbarCommand[1]};matches:${filterToolbarCommand[2]}`,
    );
  }

  const nativeFilterToolbarCommand = output.match(
    /^PROC_MON_FILTER_NATIVE_TOOLBAR_COMMAND=state:(ready|unavailable);toolbars:(0|[1-9]\d?);items:(0|[1-9]\d?);matches:(0|1|2);truncated:(true|false)\r?$/m,
  );
  if (nativeFilterToolbarCommand) {
    const [, state, toolbars, items, matches, truncated] = nativeFilterToolbarCommand;
    if (
      Number(toolbars) <= 64
      && Number(items) <= 64
      && !(state === "ready" && truncated === "true")
      && !(Number(matches) > Number(items))
    ) {
      diagnostics.push(
        `filter-native-toolbar-command=state:${state};toolbars:${toolbars};items:${items};matches:${matches};truncated:${truncated}`,
      );
    }
  }

  const nativeToolbarMetadata = output.match(
    /^PROC_MON_FILTER_NATIVE_TOOLBAR_METADATA=toolbars:(0|[1-9]\d?);buttons:(0|[1-9]\d?);labels:(0|[1-9]\d?);matches:(0|[1-9]\d?);enabled-matches:(0|[1-9]\d?);enabled:(true|false);read:(none|no-match|ambiguous-match|owner-mismatch|class-mismatch|count-invalid|count-limit|state-invalid|child-read-failed|unavailable)\r?$/m,
  );
  if (nativeToolbarMetadata) {
    const [, toolbars, buttons, labels, matches, enabledMatches, enabled, read] =
      nativeToolbarMetadata;
    if (
      Number(toolbars) <= 64
      && Number(buttons) <= 64
      && Number(labels) <= Number(buttons)
      && Number(matches) <= Number(labels)
      && Number(enabledMatches) <= Number(matches)
      && (enabledMatches === "0" || enabled === "true")
    ) {
      diagnostics.push(
        `filter-native-toolbar-metadata=toolbars:${toolbars};buttons:${buttons};labels:${labels};matches:${matches};enabled-matches:${enabledMatches};enabled:${enabled};read:${read}`,
      );
    }
  }

  const accessibleToolbarCommand = output.match(
    /^PROC_MON_FILTER_ACCESSIBLE_TOOLBAR_COMMAND=toolbars:(0|[1-9]\d?);items:(0|[1-9]\d?);labels:(0|[1-9]\d?);matches:(0|1|2);enabled:(true|false);default-action:(true|false);read:(none|no-match|ambiguous-match|owner-mismatch|class-mismatch|object-invalid|object-unavailable|count-invalid|count-limit|state-invalid|child-read-failed|unavailable)\r?$/m,
  );
  if (accessibleToolbarCommand) {
    const [, toolbars, items, labels, matches, enabled, defaultAction, read] =
      accessibleToolbarCommand;
    if (
      Number(toolbars) <= 64
      && Number(items) <= 64
      && Number(labels) <= 64
      && Number(matches) <= Number(labels)
      && (matches === "0" || labels === "1")
    ) {
      diagnostics.push(
        `filter-accessible-toolbar-command=toolbars:${toolbars};items:${items};labels:${labels};matches:${matches};enabled:${enabled};default-action:${defaultAction};read:${read}`,
      );
    }
  }

  const filterMenuMain = output.match(
    /^PROC_MON_FILTER_MENU_MAIN=process:(same|other);handle:(available|unavailable);native-process:(same|other|unavailable);visible:(true|false);enabled:(true|false);control:(window|pane|other)\r?$/m,
  );
  if (filterMenuMain) {
    diagnostics.push(
      `filter-menu-main=process:${filterMenuMain[1]};handle:${filterMenuMain[2]};native-process:${filterMenuMain[3]};visible:${filterMenuMain[4]};enabled:${filterMenuMain[5]};control:${filterMenuMain[6]}`,
    );
  }

  const dropMenuMatch = output.match(
    /^PROC_MON_FILTER_DROP_MENU_MATCH=items:(\d{1,4});matches:(\d{1,4})\r?$/m,
  );
  if (dropMenuMatch) {
    diagnostics.push(
      `drop-filter-menu-match=items:${dropMenuMatch[1]};matches:${dropMenuMatch[2]}`,
    );
  }

  if (/^PROC_MON_FILTER_COMMAND_ACTIVATION=invoke-pattern\r?$/m.test(output)) {
    diagnostics.push("filter-command-activation=invoke-pattern");
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_SHORTCUT_INPUT=state:(sent|target-mismatch|incomplete);events:(\d);release-events:(\d)\r?$/gm,
  )) {
    const [, state, rawEvents, rawReleaseEvents] = match;
    const events = Number(rawEvents);
    const releaseEvents = Number(rawReleaseEvents);
    if (
      events <= 4
      && releaseEvents <= 2
      && (
        (state === "sent" && events === 4 && releaseEvents === 0)
        || (state === "target-mismatch" && events === 0 && releaseEvents === 0)
        || (state === "incomplete" && events < 4)
      )
    ) {
      diagnostics.push(
        `filter-shortcut-input=state:${state};events:${events};release-events:${releaseEvents}`,
      );
    }
  }

  const dialogScan = output.match(
    /PROC_MON_FILTER_DIALOG_SCAN=process-windows:(\d{1,4});non-main-windows:(\d{1,4});reset-control:(true|false)/,
  );
  if (dialogScan) {
    diagnostics.push(
      `filter-dialog-scan=process-windows:${dialogScan[1]};non-main-windows:${dialogScan[2]};reset-control:${dialogScan[3]}`,
    );
  }

  const embeddedDialogScan = output.match(
    /^PROC_MON_FILTER_DIALOG_EMBEDDED_SCAN=main-reset:(true|false);windows:(\d{1,4});owned:(\d{1,4});handled:(\d{1,4});distinct-runtime-id:(\d{1,4});reset:(\d{1,4});layout:(\d{1,4});max-items:(\d{1,4});max-combos:(\d{1,4});max-edits:(\d{1,4});max-buttons:(\d{1,4});max-texts:(\d{1,4});max-custom:(\d{1,4});max-panes:(\d{1,4});max-windows:(\d{1,4});max-menus:(\d{1,4});max-menu-items:(\d{1,4});max-toolbars:(\d{1,4});max-other:(\d{1,4});items-truncated:(true|false)\r?$/m,
  );
  if (embeddedDialogScan) {
    diagnostics.push(
      `filter-dialog-embedded-scan=main-reset:${embeddedDialogScan[1]};windows:${embeddedDialogScan[2]};owned:${embeddedDialogScan[3]};handled:${embeddedDialogScan[4]};distinct-runtime-id:${embeddedDialogScan[5]};reset:${embeddedDialogScan[6]};layout:${embeddedDialogScan[7]};max-items:${embeddedDialogScan[8]};max-combos:${embeddedDialogScan[9]};max-edits:${embeddedDialogScan[10]};max-buttons:${embeddedDialogScan[11]};max-texts:${embeddedDialogScan[12]};max-custom:${embeddedDialogScan[13]};max-panes:${embeddedDialogScan[14]};max-windows:${embeddedDialogScan[15]};max-menus:${embeddedDialogScan[16]};max-menu-items:${embeddedDialogScan[17]};max-toolbars:${embeddedDialogScan[18]};max-other:${embeddedDialogScan[19]};items-truncated:${embeddedDialogScan[20]}`,
    );
  }

  const focusedDialogScan = output.match(
    /^PROC_MON_FILTER_DIALOG_FOCUS_SCAN=windows:(\d{1,4});owned:(\d{1,4});handled:(\d{1,4});native-owned:(\d{1,4});distinct-runtime-id:(\d{1,4});reset:(\d{1,4});max-combos:(\d{1,4});max-edits:(\d{1,4})\r?$/m,
  );
  if (
    focusedDialogScan &&
    Number(focusedDialogScan[2]) <= Number(focusedDialogScan[1]) &&
    Number(focusedDialogScan[3]) <= Number(focusedDialogScan[2]) &&
    Number(focusedDialogScan[4]) <= Number(focusedDialogScan[3]) &&
    Number(focusedDialogScan[5]) <= Number(focusedDialogScan[3]) &&
    Number(focusedDialogScan[6]) <= Number(focusedDialogScan[4])
  ) {
    diagnostics.push(
      `filter-dialog-focus-scan=windows:${focusedDialogScan[1]};owned:${focusedDialogScan[2]};handled:${focusedDialogScan[3]};native-owned:${focusedDialogScan[4]};distinct-runtime-id:${focusedDialogScan[5]};reset:${focusedDialogScan[6]};max-combos:${focusedDialogScan[7]};max-edits:${focusedDialogScan[8]}`,
    );
  }

  const saveDialogScan = output.match(
    /^PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:(\d{1,4});file-names:(\d{1,4});save-buttons:(\d{1,4})\r?$/m,
  );
  if (saveDialogScan) {
    diagnostics.push(
      `config-save-dialog-scan=windows:${saveDialogScan[1]};file-names:${saveDialogScan[2]};save-buttons:${saveDialogScan[3]}`,
    );
  }

  const saveDialogDiagnostics = output.match(
    /^PROC_MON_FILTER_SAVE_DIALOG_DIAGNOSTICS=same-process:(\d{1,4});other-process:(\d{1,4});no-handle:(\d{1,4});main-window:(\d{1,4});disabled:(\d{1,4});offscreen:(\d{1,4});duplicate-handle:(\d{1,4});eligible:(\d{1,4})\r?$/m,
  );
  if (saveDialogDiagnostics) {
    diagnostics.push(
      `config-save-dialog-diagnostics=same-process:${saveDialogDiagnostics[1]};other-process:${saveDialogDiagnostics[2]};no-handle:${saveDialogDiagnostics[3]};main-window:${saveDialogDiagnostics[4]};disabled:${saveDialogDiagnostics[5]};offscreen:${saveDialogDiagnostics[6]};duplicate-handle:${saveDialogDiagnostics[7]};eligible:${saveDialogDiagnostics[8]}`,
    );
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_CONFIG_FILE=observation:(initial|final);state:(missing|undersized|ready)\r?$/gm,
  )) {
    diagnostics.push(`config-file-${match[1]}=${match[2]}`);
  }

  const saveFocusGate = output.match(
    /^PROC_MON_FILTER_SAVE_FOCUS=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (saveFocusGate) diagnostics.push(`config-save-focus-gate=${saveFocusGate}`);

  const saveForegroundGate = output.match(
    /^PROC_MON_FILTER_SAVE_FOREGROUND=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (saveForegroundGate) {
    diagnostics.push(`config-save-foreground-gate=${saveForegroundGate}`);
  }

  const saveFilenameGate = output.match(
    /^PROC_MON_FILTER_SAVE_FILENAME=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (saveFilenameGate) {
    diagnostics.push(`config-save-filename-gate=${saveFilenameGate}`);
  }

  const saveFinalForegroundGate = output.match(
    /^PROC_MON_FILTER_SAVE_FINAL_FOREGROUND=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (saveFinalForegroundGate) {
    diagnostics.push(`config-save-final-foreground-gate=${saveFinalForegroundGate}`);
  }

  const mainForegroundGate = [...output.matchAll(
    /^PROC_MON_FILTER_MAIN_FOREGROUND=gate:(passed|failed)\r?$/gm,
  )].at(-1)?.[1];
  if (mainForegroundGate) {
    diagnostics.push(`main-foreground-gate=${mainForegroundGate}`);
  }

  const shortcutForegroundGate = output.match(
    /^PROC_MON_FILTER_SHORTCUT_FOREGROUND=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (shortcutForegroundGate) {
    diagnostics.push(`filter-shortcut-foreground-gate=${shortcutForegroundGate}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_SHORTCUT_GUI_FOCUS=phase:(before|after);available:(true|false);active:(procmon-main|procmon-other|other-process|none|unavailable);focus:(procmon-main|procmon-other|other-process|none|unavailable)\r?$/gm,
  )) {
    const [, phase, available, active, focus] = match;
    if (
      available === "true"
      || (active === "unavailable" && focus === "unavailable")
    ) {
      diagnostics.push(
        `filter-shortcut-gui-focus=${phase};available:${available};active:${active};focus:${focus}`,
      );
    }
  }

  const nativeWindowUi = output.match(
    /^PROC_MON_FILTER_NATIVE_WINDOW_UIA=visible-other:(\d{1,3});inspected:(\d{1,3});owned:(\d{1,3});distinct-runtime-id:(\d{1,3});reset:(\d{1,3});max-combos:(\d{1,3});max-edits:(\d{1,3});read-failures:(\d{1,3});truncated:(true|false)\r?$/m,
  );
  if (nativeWindowUi) {
    const [, rawVisible, rawInspected, rawOwned, rawDistinct, rawReset, rawCombos, rawEdits, rawFailures, truncated] = nativeWindowUi;
    const [visible, inspected, owned, distinct, reset, combos, edits, failures] = [
      rawVisible,
      rawInspected,
      rawOwned,
      rawDistinct,
      rawReset,
      rawCombos,
      rawEdits,
      rawFailures,
    ].map(Number);
    if (
      visible <= 256
      && inspected <= visible
      && owned <= inspected
      && distinct <= owned
      && reset <= owned
      && combos <= 999
      && edits <= 999
      && failures <= inspected + 1
    ) {
      diagnostics.push(
        `filter-native-window-uia=visible-other:${visible};inspected:${inspected};owned:${owned};distinct-runtime-id:${distinct};reset:${reset};max-combos:${combos};max-edits:${edits};read-failures:${failures};truncated:${truncated}`,
      );
    }
  }

  const accessibleMenu = output.match(
    /^PROC_MON_FILTER_ACCESSIBLE_MENU=state:(ready|partial|unavailable);windows:(\d{1,3});readable:(\d{1,3});unreadable:(\d{1,3});items:(\d{1,5});event:(\d{1,5});filter:(\d{1,5});filter-command:(\d{1,5});truncated:(true|false)\r?$/m,
  );
  if (accessibleMenu) {
    const [, state, rawWindows, rawReadable, rawUnreadable, rawItems, rawEvents, rawFilters, rawCommands, truncated] = accessibleMenu;
    const [windows, readable, unreadable, items, events, filters, commands] = [
      rawWindows,
      rawReadable,
      rawUnreadable,
      rawItems,
      rawEvents,
      rawFilters,
      rawCommands,
    ].map(Number);
    if (
      windows <= 256
      && readable + unreadable === windows
      && items <= readable * 64
      && events <= items
      && filters <= items
      && commands <= items
      && (
        (windows === 0 && state === "unavailable")
        || (windows > 0 && unreadable === 0 && state === "ready")
        || (windows > 0 && unreadable > 0 && state === "partial")
      )
    ) {
      diagnostics.push(
        `filter-accessible-menu=state:${state};windows:${windows};readable:${readable};unreadable:${unreadable};items:${items};event:${events};filter:${filters};filter-command:${commands};truncated:${truncated}`,
      );
    }
  }

  for (const rawUia of output.matchAll(
    /^PROC_MON_FILTER_RAW_UIA=source:(main|visible-other);state:(ready|partial|truncated);nodes:(\d{1,3});windows:(\d{1,3});panes:(\d{1,3});combos:(\d{1,3});edits:(\d{1,3});buttons:(\d{1,3});menus:(\d{1,3});menu-items:(\d{1,3});other:(\d{1,3});truncated:(true|false)\r?$/gm,
  )) {
    const [, source, state, ...rawCounts] = rawUia;
    const [nodes, windows, panes, combos, edits, buttons, menus, menuItems, other] =
      rawCounts.slice(0, 9).map(Number);
    const truncated = rawCounts[9] === "true";
    if (
      nodes >= 1
      && nodes <= 512
      && [windows, panes, combos, edits, buttons, menus, menuItems, other]
        .every((count) => count <= nodes)
      && windows + panes + combos + edits + buttons + menus + menuItems + other === nodes
      && (
        (state === "ready" && !truncated)
        || (state === "truncated" && truncated)
        || state === "partial"
      )
    ) {
      diagnostics.push(
        `filter-raw-uia=source:${source};state:${state};nodes:${nodes};windows:${windows};panes:${panes};combos:${combos};edits:${edits};buttons:${buttons};menus:${menus};menu-items:${menuItems};other:${other};truncated:${truncated}`,
      );
    }
  }

  for (const nativeChildren of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_CHILDREN=source:(main|visible-other);state:(ready|partial|truncated|root-mismatch);windows:(\d{1,3});combos:(\d{1,3});edits:(\d{1,3});buttons:(\d{1,3});dialogs:(\d{1,3});toolbars:(\d{1,3});lists:(\d{1,3});statics:(\d{1,3});other:(\d{1,3});unreadable:(\d{1,3});truncated:(true|false)\r?$/gm,
  )) {
    const [, source, state, ...rawCounts] = nativeChildren;
    const [
      windows,
      combos,
      edits,
      buttons,
      dialogs,
      toolbars,
      lists,
      statics,
      other,
      unreadable,
    ] = rawCounts.slice(0, 10).map(Number);
    const truncated = rawCounts[10] === "true";
    if (
      windows <= 256
      && [combos, edits, buttons, dialogs, toolbars, lists, statics, other, unreadable]
        .every((count) => count <= windows)
      && combos + edits + buttons + dialogs + toolbars + lists + statics + other + unreadable
        === windows
      && (
        (state === "ready" && !truncated)
        || (state === "truncated" && truncated)
        || state === "partial"
        || (state === "root-mismatch" && windows === 0 && !truncated)
      )
    ) {
      diagnostics.push(
        `filter-native-children=source:${source};state:${state};windows:${windows};combos:${combos};edits:${edits};buttons:${buttons};dialogs:${dialogs};toolbars:${toolbars};lists:${lists};statics:${statics};other:${other};unreadable:${unreadable};truncated:${truncated}`,
      );
    }
  }

  for (const staticText of output.matchAll(
    /^PROC_MON_FILTER_STATIC_TEXT=source:(main|visible-other);controls:(\d{1,3});categories:((?:filter|configuration|capture|driver|driver-load|service|instance|permission|error|warning|license|update|filter-configuration|filter-driver|driver-load-error|instance-error|filter-error|filter-configuration-error|filter-driver-error)(?:,(?:filter|configuration|capture|driver|driver-load|service|instance|permission|error|warning|license|update|filter-configuration|filter-driver|driver-load-error|instance-error|filter-error|filter-configuration-error|filter-driver-error))*)?\r?$/gm,
  )) {
    const [, source, rawControls, rawCategories] = staticText;
    const controls = Number(rawControls);
    const categories = rawCategories ? rawCategories.split(",") : [];
    if (
      controls <= 256
      && categories.length <= 18
      && new Set(categories).size === categories.length
    ) {
      diagnostics.push(
        `filter-static-text=source:${source};controls:${controls};categories:${categories.join(",") || "none"}`,
      );
    }
  }

  for (const nativeChildUia of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_CHILD_UIA=source:(main|visible-other);state:(ready|partial|truncated|root-mismatch);candidates:(\d{1,3});mapped:(\d{1,3});combos:(\d{1,3});edits:(\d{1,3});buttons:(\d{1,3});windows:(\d{1,3});panes:(\d{1,3});other:(\d{1,3});unreadable:(\d{1,3});truncated:(true|false)\r?$/gm,
  )) {
    const [, source, state, ...rawCounts] = nativeChildUia;
    const [
      candidates,
      mapped,
      combos,
      edits,
      buttons,
      windows,
      panes,
      other,
      unreadable,
    ] = rawCounts.slice(0, 9).map(Number);
    const truncated = rawCounts[9] === "true";
    if (
      candidates <= 256
      && mapped <= candidates
      && unreadable <= candidates
      && mapped + unreadable === candidates
      && [combos, edits, buttons, windows, panes, other]
        .every((count) => count <= mapped)
      && combos + edits + buttons + windows + panes + other === mapped
      && (
        (state === "ready" && !truncated && unreadable === 0)
        || (state === "truncated" && truncated && unreadable === 0)
        || state === "partial"
        || (
          state === "root-mismatch" &&
          candidates === 0 &&
          mapped === 0 &&
          unreadable === 0 &&
          !truncated
        )
      )
    ) {
      diagnostics.push(
        `filter-native-child-uia=source:${source};state:${state};candidates:${candidates};mapped:${mapped};combos:${combos};edits:${edits};buttons:${buttons};windows:${windows};panes:${panes};other:${other};unreadable:${unreadable};truncated:${truncated}`,
      );
    }
  }

  for (const nativeChildPatterns of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_CHILD_PATTERNS=source:(main|visible-other);state:(ready|partial|truncated|root-mismatch);candidates:(\d{1,3});mapped:(\d{1,3});value:(\d{1,3});selection:(\d{1,3});selection-item:(\d{1,3});expand-collapse:(\d{1,3});invoke:(\d{1,3});toggle:(\d{1,3});pattern-errors:(\d{1,3});unreadable:(\d{1,3});truncated:(true|false)\r?$/gm,
  )) {
    const [, source, state, ...rawCounts] = nativeChildPatterns;
    const [
      candidates,
      mapped,
      value,
      selection,
      selectionItem,
      expandCollapse,
      invoke,
      toggle,
      patternErrors,
      unreadable,
    ] = rawCounts.slice(0, 10).map(Number);
    const truncated = rawCounts[10] === "true";
    if (
      candidates <= 256
      && mapped <= candidates
      && unreadable <= candidates
      && mapped + unreadable === candidates
      && [value, selection, selectionItem, expandCollapse, invoke, toggle, patternErrors]
        .every((count) => count <= mapped)
      && (
        (state === "ready" && !truncated && unreadable === 0 && patternErrors === 0)
        || (
          state === "truncated" &&
          truncated &&
          unreadable === 0 &&
          patternErrors === 0
        )
        || state === "partial"
        || (
          state === "root-mismatch" &&
          candidates === 0 &&
          mapped === 0 &&
          unreadable === 0 &&
          patternErrors === 0 &&
          !truncated
        )
      )
    ) {
      diagnostics.push(
        `filter-native-child-patterns=source:${source};state:${state};candidates:${candidates};mapped:${mapped};value:${value};selection:${selection};selection-item:${selectionItem};expand-collapse:${expandCollapse};invoke:${invoke};toggle:${toggle};pattern-errors:${patternErrors};unreadable:${unreadable};truncated:${truncated}`,
      );
    }
  }

  for (const nativeControls of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_CONTROLS=source:(main|visible-other);state:(ready|partial);combos:(\d{1,3});path-options:(\d{1,3});operator-options:(\d{1,3});include-options:(\d{1,3});edits:(\d{1,3});readable-edits:(\d{1,3});buttons:(\d{1,3});reset:(\d{1,3});add:(\d{1,3});ok:(\d{1,3});cancel:(\d{1,3});remove:(\d{1,3});lists:(\d{1,3});list-items:(\d{1,3});read-failures:(\d{1,3});truncated:(true|false)\r?$/gm,
  )) {
    const [, source, state, ...rawCounts] = nativeControls;
    const [
      combos,
      pathOptions,
      operatorOptions,
      includeOptions,
      edits,
      readableEdits,
      buttons,
      reset,
      add,
      ok,
      cancel,
      remove,
      lists,
      listItems,
      readFailures,
    ] = rawCounts.slice(0, 15).map(Number);
    const truncated = rawCounts[15] === "true";
    if (
      [combos, edits, buttons, lists, listItems, readFailures].every((count) => count <= 256)
      && [pathOptions, operatorOptions, includeOptions].every((count) => count <= combos)
      && readableEdits <= edits
      && [reset, add, ok, cancel, remove].every((count) => count <= buttons)
      && (
        state === "partial"
        || (!truncated && readFailures === 0)
      )
    ) {
      diagnostics.push(
        `filter-native-controls=source:${source};state:${state};combos:${combos};path-options:${pathOptions};operator-options:${operatorOptions};include-options:${includeOptions};edits:${edits};readable-edits:${readableEdits};buttons:${buttons};reset:${reset};add:${add};ok:${ok};cancel:${cancel};remove:${remove};lists:${lists};list-items:${listItems};read-failures:${readFailures};truncated:${truncated}`,
      );
    }
  }

  for (const candidate of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_DIALOG_CANDIDATE=state:(accepted|rejected);gate:(checking|native-children|uia-unavailable|uia-mismatch|uia-pattern-available|uia-verification|native-control-read|control-counts|fixed-buttons|fixed-options|list-columns|eligible)\r?$/gm,
  )) {
    diagnostics.push(
      `filter-native-dialog-candidate=state:${candidate[1]};gate:${candidate[2]}`,
    );
  }
  for (const candidate of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_DIALOG_CANDIDATE=state:error;gate:(checking|native-children|uia-unavailable|uia-mismatch|uia-pattern-available|uia-verification|native-control-read|control-counts|fixed-buttons|fixed-options|list-columns|eligible);exception:(invalid-operation|argument|com|method-invocation)\r?$/gm,
  )) {
    diagnostics.push(
      `filter-native-dialog-candidate=state:error;gate:${candidate[1]};exception:${candidate[2]}`,
    );
  }

  for (const nativeRules of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_RULES=phase:(initial|reloaded);state:(ready|partial);rows:(\d{1,2});columns:(\d);path:(\d{1,2});is:(\d{1,2});include:(\d{1,2});exact-shape:(\d{1,2});unclassified:(\d{1,2});truncated:(true|false)\r?$/gm,
  )) {
    const [, phase, state, ...rawCounts] = nativeRules;
    const [rows, columns, path, operator, include, exactShape, unclassified] =
      rawCounts.slice(0, 7).map(Number);
    const truncated = rawCounts[7] === "true";
    if (
      rows <= 64 &&
      columns === 4 &&
      [path, operator, include, exactShape, unclassified].every((count) => count <= rows) &&
      exactShape + unclassified === rows &&
      (
        state === "partial" ||
        (!truncated && unclassified === 0)
      )
    ) {
      diagnostics.push(
        `filter-native-rules=phase:${phase};state:${state};rows:${rows};columns:${columns};path:${path};is:${operator};include:${include};exact-shape:${exactShape};unclassified:${unclassified};truncated:${truncated}`,
      );
    }
  }

  const mainWindowSelection = output.match(
    /^PROC_MON_FILTER_MAIN_WINDOW=selection:(filter-menu-root|main-handle-root|from-handle|first-owned);root-windows:(\d{1,4});uia-owned-windows:(\d{1,4});main-handle:(available|unavailable);filter-menu:(present|absent)\r?$/m,
  );
  if (
    mainWindowSelection &&
    Number(mainWindowSelection[2]) <= 9999 &&
    Number(mainWindowSelection[3]) <= Number(mainWindowSelection[2])
  ) {
    diagnostics.push(
      `main-window-selection=${mainWindowSelection[1]};root-windows:${mainWindowSelection[2]};uia-owned-windows:${mainWindowSelection[3]};main-handle:${mainWindowSelection[4]};filter-menu:${mainWindowSelection[5]}`,
    );
  }

  for (const nativeMenu of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_MENU=source:(main|focused-root|all-top-level|active-menu-loop);state:(ready|partial|unavailable|owner-mismatch|read-failed|over-limit);menus:(\d{1,2});items:(\d{1,3});event:(\d{1,2});filter:(\d{1,2});filter-command:(\d{1,2});drop:(\d{1,2});invalid-handles:(\d{1,2});unreadable:(\d{1,3})\r?$/gm,
  )) {
    const [, source, state, rawMenus, rawItems, rawEvents, rawFilters, rawCommands, rawDrops, rawInvalid, rawUnreadable] = nativeMenu;
    const [menus, items, events, filters, commands, drops, invalid, unreadable] = [
      rawMenus,
      rawItems,
      rawEvents,
      rawFilters,
      rawCommands,
      rawDrops,
      rawInvalid,
      rawUnreadable,
    ].map(Number);
    if (
      menus <= 32
      && items <= 256
      && events <= items
      && filters <= items
      && commands <= items
      && drops <= items
      && invalid <= menus
      && unreadable <= menus + items
      && (state !== "ready" || unreadable === 0)
      && (state !== "partial" || unreadable > 0)
    ) {
      diagnostics.push(
        `filter-native-menu${source === "main" ? "" : `-${source}`}=state:${state};menus:${menus};items:${items};event:${events};filter:${filters};filter-command:${commands};drop:${drops};invalid-handles:${invalid};unreadable:${unreadable}`,
      );
    }
  }

  const menuLoopWindows = output.match(
    /^PROC_MON_FILTER_MENU_LOOP_WINDOWS=available:(true|false);active-same:(true|false);focus-same:(true|false);capture-same:(true|false);menu-owner-same:(true|false);active-visible:(true|false);focus-visible:(true|false);capture-visible:(true|false);menu-owner-visible:(true|false);active-menu:(true|false);focus-menu:(true|false);capture-menu:(true|false);menu-owner-menu:(true|false);active-class:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);active-parent:(none|main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);focus-class:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);focus-parent:(none|main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);capture-class:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);capture-parent:(none|main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);menu-owner-class:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);menu-owner-parent:(none|main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process)\r?$/m,
  );
  if (
    menuLoopWindows
    && (menuLoopWindows[6] !== "true" || menuLoopWindows[2] === "true")
    && (menuLoopWindows[7] !== "true" || menuLoopWindows[3] === "true")
    && (menuLoopWindows[8] !== "true" || menuLoopWindows[4] === "true")
    && (menuLoopWindows[9] !== "true" || menuLoopWindows[5] === "true")
    && (menuLoopWindows[10] !== "true" || (menuLoopWindows[2] === "true" && menuLoopWindows[6] === "true"))
    && (menuLoopWindows[11] !== "true" || (menuLoopWindows[3] === "true" && menuLoopWindows[7] === "true"))
    && (menuLoopWindows[12] !== "true" || (menuLoopWindows[4] === "true" && menuLoopWindows[8] === "true"))
    && (menuLoopWindows[13] !== "true" || (menuLoopWindows[5] === "true" && menuLoopWindows[9] === "true"))
  ) {
    diagnostics.push(
      `filter-menu-loop-windows=available:${menuLoopWindows[1]};active-same:${menuLoopWindows[2]};focus-same:${menuLoopWindows[3]};capture-same:${menuLoopWindows[4]};menu-owner-same:${menuLoopWindows[5]};active-visible:${menuLoopWindows[6]};focus-visible:${menuLoopWindows[7]};capture-visible:${menuLoopWindows[8]};menu-owner-visible:${menuLoopWindows[9]};active-menu:${menuLoopWindows[10]};focus-menu:${menuLoopWindows[11]};capture-menu:${menuLoopWindows[12]};menu-owner-menu:${menuLoopWindows[13]};active-class:${menuLoopWindows[14]};active-parent:${menuLoopWindows[15]};focus-class:${menuLoopWindows[16]};focus-parent:${menuLoopWindows[17]};capture-class:${menuLoopWindows[18]};capture-parent:${menuLoopWindows[19]};menu-owner-class:${menuLoopWindows[20]};menu-owner-parent:${menuLoopWindows[21]}`,
    );
  }
  const menuLoopRoots = output.match(
    /^PROC_MON_FILTER_MENU_LOOP_ROOTS=available:(true|false);active:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);focus:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);capture:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process);menu-owner:(main|popup|dialog|toolbar|list|button|combo|other|unavailable|other-process)\r?$/m,
  );
  if (menuLoopRoots) {
    diagnostics.push(
      `filter-menu-loop-roots=available:${menuLoopRoots[1]};active:${menuLoopRoots[2]};focus:${menuLoopRoots[3]};capture:${menuLoopRoots[4]};menu-owner:${menuLoopRoots[5]}`,
    );
  }
  const menuLoopStyles = output.match(
    /^PROC_MON_FILTER_MENU_LOOP_STYLES=available:(true|false);active:(popup|child|standard|unavailable);focus:(popup|child|standard|unavailable);capture:(popup|child|standard|unavailable);menu-owner:(popup|child|standard|unavailable)\r?$/m,
  );
  if (menuLoopStyles) {
    diagnostics.push(
      `filter-menu-loop-styles=available:${menuLoopStyles[1]};active:${menuLoopStyles[2]};focus:${menuLoopStyles[3]};capture:${menuLoopStyles[4]};menu-owner:${menuLoopStyles[5]}`,
    );
  }
  for (const accessible of output.matchAll(
    /^PROC_MON_FILTER_MENU_LOOP_ACCESSIBLE=role:(main-after-shortcut|focus|capture|menu-owner);object:(menu|client);available:(true|false);failure:(none|window-unavailable|process-mismatch|object-unavailable|object-invalid|count-invalid|count-limit|child-read-failed|no-match|duplicate-match|role-mismatch|state-invalid);nodes:(\d{1,2});items:(\d{1,3});label-matches:(\d{1,3});matches:(\d{1,3});enabled:(true|false);checked:(unavailable|on|off)\r?$/gm,
  )) {
    const [, role, object, available, failure, rawNodes, rawItems, rawLabelMatches, rawMatches, enabled, checked] = accessible;
    const [nodes, items, labelMatches, matches] = [rawNodes, rawItems, rawLabelMatches, rawMatches].map(Number);
    if (
      nodes <= 64
      && (nodes >= 1 || (available === "false" && items === 0 && labelMatches === 0 && matches === 0))
      && items <= 256
      && nodes <= items + 1
      && labelMatches <= items
      && matches <= labelMatches
      && (
        (failure === "none" && labelMatches === 1 && matches === 1)
        || (failure === "no-match" && labelMatches === 0 && matches === 0)
        || (failure === "role-mismatch" && labelMatches === 1 && matches === 0)
        || (failure === "duplicate-match" && labelMatches > 1)
        || !["none", "no-match", "role-mismatch", "duplicate-match"].includes(failure)
      )
    ) {
      diagnostics.push(
        `filter-menu-loop-msaa=role:${role};object:${object};available:${available};failure:${failure};nodes:${nodes};items:${items};label-matches:${labelMatches};matches:${matches};enabled:${enabled};checked:${checked}`,
      );
    }
  }
  const nativeWindows = output.match(
    /^PROC_MON_FILTER_NATIVE_WINDOWS=state:ready;windows:(\d{1,3});main:(\d{1,3});other:(\d{1,3});visible:(\d{1,3});menus:(\d{1,3});truncated:(true|false)\r?$/m,
  );
  if (nativeWindows) {
    const [, rawWindows, rawMain, rawOther, rawVisible, rawMenus, truncated] = nativeWindows;
    const [windows, main, other, visible, menus] = [
      rawWindows,
      rawMain,
      rawOther,
      rawVisible,
      rawMenus,
    ].map(Number);
    if (
      windows <= 256
      && main + other === windows
      && visible <= windows
      && menus <= windows
    ) {
      diagnostics.push(
        `filter-native-windows=windows:${windows};main:${main};other:${other};visible:${visible};menus:${menus};truncated:${truncated}`,
      );
    }
  }
  for (const nativeTopLevel of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_TOPLEVEL=windows:(\d{1,3});visible:(\d{1,3});enabled:(\d{1,3});main:(\d{1,3});dialog:(\d{1,3});popup:(\d{1,3});toolbar:(\d{1,3});list:(\d{1,3});button:(\d{1,3});other:(\d{1,3});unavailable:(\d{1,3});style-popup:(\d{1,3});style-child:(\d{1,3});style-standard:(\d{1,3});style-unavailable:(\d{1,3})\r?$/gm,
  )) {
    const [, ...rawCounts] = nativeTopLevel;
    const [
      windows,
      visible,
      enabled,
      main,
      dialogs,
      popups,
      toolbars,
      lists,
      buttons,
      other,
      unavailable,
      stylePopups,
      styleChildren,
      styleStandard,
      styleUnavailable,
    ] = rawCounts.map(Number);
    if (
      windows <= 256
      && visible <= windows
      && enabled <= visible
      && main + dialogs + popups + toolbars + lists + buttons + other + unavailable === visible
      && stylePopups + styleChildren + styleStandard + styleUnavailable === visible
    ) {
      diagnostics.push(
        `filter-native-toplevel=windows:${windows};visible:${visible};enabled:${enabled};main:${main};dialog:${dialogs};popup:${popups};toolbar:${toolbars};list:${lists};button:${buttons};other:${other};unavailable:${unavailable};style-popup:${stylePopups};style-child:${styleChildren};style-standard:${styleStandard};style-unavailable:${styleUnavailable}`,
      );
    }
  }
  for (const focusMenuUia of output.matchAll(
    /^PROC_MON_FILTER_MENU_LOOP_UIA=role:(main-after-shortcut|focus|capture|menu-owner);available:(true|false);failure:(none|window-unavailable|owner-mismatch|item-limit|label-limit|element-unavailable|com-exception);items:(\d{1,2});event:(\d{1,2});filter:(\d{1,2});filter-command:(\d{1,2});drop:(\d{1,2});drop-labels:(\d{1,2});drop-menu-items:(\d{1,2});drop-enabled:(true|false)\r?$/gm,
  )) {
    const [
      ,
      role,
      available,
      failure,
      rawItems,
      rawEvents,
      rawFilters,
      rawCommands,
      rawDrops,
      rawDropLabels,
      rawDropMenuItems,
      dropEnabled,
    ] = focusMenuUia;
    const [items, events, filters, commands, drops, dropLabels, dropMenuItems] = [
      rawItems,
      rawEvents,
      rawFilters,
      rawCommands,
      rawDrops,
      rawDropLabels,
      rawDropMenuItems,
    ].map(Number);
    if (
      items <= 64
      && events <= items
      && filters <= items
      && commands <= items
      && drops <= items
      && dropLabels <= 64
      && dropMenuItems <= dropLabels
      && dropMenuItems === drops
      && (dropEnabled === "false"
        || (dropLabels === 1 && dropMenuItems === 1 && available === "true"))
      && (available === "true" ? failure === "none" : failure !== "none")
      && (failure === "none" || items === 0)
    ) {
      diagnostics.push(
        `filter-menu-loop-uia=role:${role};available:${available};failure:${failure};items:${items};event:${events};filter:${filters};filter-command:${commands};drop:${drops};drop-labels:${dropLabels};drop-menu-items:${dropMenuItems};drop-enabled:${dropEnabled}`,
      );
    }
  }

  if (/^PROC_MON_FILTER_MENU_OPEN_FALLBACK=filter-dialog-shortcut\r?$/m.test(output)) {
    diagnostics.push("filter-menu-open-fallback=filter-dialog-shortcut");
  }

  const menuGuiState = output.match(
    /^PROC_MON_FILTER_MENU_GUI_STATE=process-known:(true|false);same-process:(true|false);gui-info:(true|false);menu-mode:(true|false);owner:([01])\r?$/m,
  );
  if (menuGuiState) {
    diagnostics.push(
      `filter-menu-gui-state=process-known:${menuGuiState[1]};same-process:${menuGuiState[2]};gui-info:${menuGuiState[3]};menu-mode:${menuGuiState[4]};owner:${menuGuiState[5]}`,
    );
  }
  const accessibleMenuState = output.match(
    /^PROC_MON_FILTER_MENU_GUI_ACCESSIBLE=available:(true|false);failure:(none|window-unavailable|process-mismatch|object-unavailable|object-invalid|count-invalid|count-limit|child-read-failed|no-match|duplicate-match|state-invalid);items:(\d{1,3});matches:(\d{1,3});enabled:(true|false);checked:(unavailable|on|off)\r?$/m,
  );
  if (accessibleMenuState) {
    diagnostics.push(
      `filter-menu-accessible=available:${accessibleMenuState[1]};failure:${accessibleMenuState[2]};items:${accessibleMenuState[3]};matches:${accessibleMenuState[4]};enabled:${accessibleMenuState[5]};checked:${accessibleMenuState[6]}`,
    );
  }

  const reloadMainForegroundGate = output.match(
    /^PROC_MON_FILTER_RELOAD_MAIN_FOREGROUND=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (reloadMainForegroundGate) {
    diagnostics.push(`reload-main-foreground-gate=${reloadMainForegroundGate}`);
  }

  const reloadDialogClosedGate = output.match(
    /^PROC_MON_FILTER_RELOAD_DIALOG_CLOSED=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (reloadDialogClosedGate) {
    diagnostics.push(`reload-dialog-closed-gate=${reloadDialogClosedGate}`);
  }

  const reloadDropMainForegroundGate = output.match(
    /^PROC_MON_FILTER_RELOAD_DROP_MAIN_FOREGROUND=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (reloadDropMainForegroundGate) {
    diagnostics.push(
      `reload-drop-main-foreground-gate=${reloadDropMainForegroundGate}`,
    );
  }

  const reloadShortcut = output.match(
    /^PROC_MON_FILTER_RELOAD_SHORTCUT=command:filter-dialog;state:sent\r?$/m,
  );
  if (reloadShortcut) {
    diagnostics.push("reload-filter-dialog-shortcut=sent");
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_RELOAD_EVENT_MENU_ITEM=process:(same|other|unavailable);items:(\d{1,3});matches:(\d{1,3});enabled:(true|false);offscreen:(true|false);keyboard-focusable:(true|false);invoke:(true|false);expand-collapse:(true|false);selection-item:(true|false)\r?$/gm,
  )) {
    const [
      ,
      process,
      rawItems,
      rawMatches,
      enabled,
      offscreen,
      keyboardFocusable,
      invoke,
      expandCollapse,
      selectionItem,
    ] = match;
    const items = Number(rawItems);
    const matches = Number(rawMatches);
    const uniqueProcess = process === "same" || process === "other";
    const consistent =
      items <= 256
      && matches <= items
      && (
        (uniqueProcess && matches === 1)
        || (process === "unavailable" && matches !== 1)
      )
      && (
        (process === "same")
        || (
          enabled === "false"
          && offscreen === "false"
          && keyboardFocusable === "false"
          && invoke === "false"
          && expandCollapse === "false"
          && selectionItem === "false"
        )
      );
    if (consistent) {
      diagnostics.push(
        `reload-event-menu-item=process:${process};items:${items};matches:${matches};enabled:${enabled};offscreen:${offscreen};keyboard-focusable:${keyboardFocusable};invoke:${invoke};expand-collapse:${expandCollapse};selection-item:${selectionItem}`,
      );
    }
  }

  const reloadNativeEvent = output.match(
    /^PROC_MON_FILTER_RELOAD_NATIVE_EVENT=items:(\d{1,2});matches:(\d{1,2});enabled:(true|false);highlighted:(true|false);submenu:(true|false)\r?$/m,
  );
  if (reloadNativeEvent) {
    const [items, matches] = reloadNativeEvent.slice(1, 3).map(Number);
    if (items <= 64 && matches <= items) {
      diagnostics.push(
        `reload-native-event=items:${items};matches:${matches};enabled:${reloadNativeEvent[3]};highlighted:${reloadNativeEvent[4]};submenu:${reloadNativeEvent[5]}`,
      );
    }
  }

  const reloadNativeFilter = output.match(
    /^PROC_MON_FILTER_RELOAD_NATIVE_FILTER=items:(\d{1,2});matches:(\d{1,2});enabled:(true|false);submenu:(true|false)\r?$/m,
  );
  if (reloadNativeFilter) {
    const [items, matches] = reloadNativeFilter.slice(1, 3).map(Number);
    if (items <= 64 && matches <= items) {
      diagnostics.push(
        `reload-native-filter=items:${items};matches:${matches};enabled:${reloadNativeFilter[3]};submenu:${reloadNativeFilter[4]}`,
      );
    }
  }

  const reloadNativeDrop = output.match(
    /^PROC_MON_FILTER_RELOAD_NATIVE_DROP=items:(\d{1,2});matches:(\d{1,2});read-failure:(none|depth-limit|total-limit|invalid-menu-handle|menu-count-invalid|menu-count-failed|menu-count-limit|owner-drawn|item-read-failed);readable:(true|false);enabled:(true|false);checked:(on|off|unavailable)\r?$/m,
  );
  if (reloadNativeDrop) {
    const [items, matches] = reloadNativeDrop.slice(1, 3).map(Number);
    if (items <= 64 && matches <= items) {
      diagnostics.push(
        `reload-native-drop=items:${items};matches:${matches};read-failure:${reloadNativeDrop[3]};readable:${reloadNativeDrop[4]};enabled:${reloadNativeDrop[5]};checked:${reloadNativeDrop[6]}`,
      );
    }
  }

  const reloadMenuPatterns = output.match(
    /^PROC_MON_FILTER_RELOAD_MENU_PATTERNS=expand-collapse:(true|false);selection-item:(true|false);legacy-ia:(true|false);invoke:(true|false)\r?$/m,
  );
  if (reloadMenuPatterns) {
    diagnostics.push(
      `reload-menu-patterns=expand-collapse:${reloadMenuPatterns[1]};selection-item:${reloadMenuPatterns[2]};legacy-ia:${reloadMenuPatterns[3]};invoke:${reloadMenuPatterns[4]}`,
    );
  }

  const reloadMenuInvokePattern = output.match(
    /^PROC_MON_FILTER_RELOAD_MENU_PATTERN=invoke:(true|false)\r?$/m,
  )?.[1];
  if (reloadMenuInvokePattern) {
    diagnostics.push(`reload-menu-invoke-pattern=${reloadMenuInvokePattern}`);
  }

  const reloadMenuPointer = output.match(
    /^PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:(valid|invalid);point-match:(true|false);input:(not-attempted|foreground-mismatch|position-failed|down-failed|up-failed|sent)\r?$/m,
  );
  if (reloadMenuPointer) {
    const [geometry, pointMatch, input] = reloadMenuPointer.slice(1);
    if (input !== "sent" || (geometry === "valid" && pointMatch === "true")) {
      diagnostics.push(
        `reload-menu-pointer=geometry:${geometry};point-match:${pointMatch};input:${input}`,
      );
    }
  }

  const reloadMenuScan = output.match(
    /^PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:(\d{1,4});menus:(\d{1,4});visible:(\d{1,4})\r?$/m,
  );
  if (reloadMenuScan) {
    const [windows, menus, visibleMenus] = reloadMenuScan.slice(1).map(Number);
    if (windows <= 9999 && menus <= 9999 && visibleMenus <= menus) {
      diagnostics.push(
        `reload-menu-scan=windows:${windows};menus:${menus};visible:${visibleMenus}`,
      );
    }
  }

  const processMenuScan = output.match(
    /^PROC_MON_FILTER_PROCESS_MENU_SCAN=windows:(\d{1,4});menus:(\d{1,4});visible:(\d{1,4})\r?$/m,
  );
  if (processMenuScan) {
    const [windows, menus, visibleMenus] = processMenuScan.slice(1).map(Number);
    if (windows <= 9999 && menus <= 9999 && visibleMenus <= menus) {
      diagnostics.push(
        `process-menu-scan=windows:${windows};menus:${menus};visible:${visibleMenus}`,
      );
    }
  }

  const processDropItemScan = output.match(
    /^PROC_MON_FILTER_PROCESS_DROP_ITEM_SCAN=state:(ready|owner-or-label-mismatch|runtime-id-unavailable);windows:(\d{1,4});items:(\d{1,4});matches:(\d{1,4});enabled:(\d{1,4});offscreen:(\d{1,4})\r?$/m,
  );
  if (processDropItemScan) {
    const [, state, rawWindows, rawItems, rawMatches, rawEnabled, rawOffscreen] =
      processDropItemScan;
    const [windows, items, matches, enabled, offscreen] = [
      rawWindows,
      rawItems,
      rawMatches,
      rawEnabled,
      rawOffscreen,
    ].map(Number);
    if (
      windows <= 128 &&
      items <= 256 &&
      matches === items &&
      enabled <= matches &&
      offscreen <= matches
    ) {
      diagnostics.push(
        `process-drop-item-scan=state:${state};windows:${windows};items:${items};matches:${matches};enabled:${enabled};offscreen:${offscreen}`,
      );
    }
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_BUTTON_FOREGROUND=label:(Reset|Add|OK|Cancel|Remove);gate:(passed|failed|dialog-unavailable)\r?$/gm,
  )) {
    diagnostics.push(
      `native-button-foreground=label:${match[1]};gate:${match[2]}`,
    );
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MENU_SHORTCUT_INPUT=state:(sent|target-mismatch|incomplete);events:(\d);release-events:(\d)\r?$/gm,
  )) {
    const [, state, rawEvents, rawReleaseEvents] = match;
    const events = Number(rawEvents);
    const releaseEvents = Number(rawReleaseEvents);
    if (
      events <= 4 &&
      releaseEvents <= 2 &&
      (
        (state === "sent" && events === 4 && releaseEvents === 0) ||
        (state === "target-mismatch" && events === 0 && releaseEvents === 0) ||
        (state === "incomplete" && events < 4)
      )
    ) {
      diagnostics.push(
        `filter-menu-shortcut-input=state:${state};events:${events};release-events:${releaseEvents}`,
      );
    }
  }

  const filterPathForegroundGates = Array.from(output.matchAll(
    /^PROC_MON_FILTER_PATH_FOREGROUND=gate:(passed|failed)\r?$/gm,
  ), (match) => match[1]);
  if (filterPathForegroundGates.length > 0) {
    diagnostics.push(
      `filter-path-foreground-gates=passed:${filterPathForegroundGates.filter((gate) => gate === "passed").length},failed:${filterPathForegroundGates.filter((gate) => gate === "failed").length}`,
    );
  }

  const filterPathGates = Array.from(output.matchAll(
    /^PROC_MON_FILTER_PATH=gate:(passed|failed)\r?$/gm,
  ), (match) => match[1]);
  if (filterPathGates.length > 0) {
    diagnostics.push(
      `filter-path-input-gates=passed:${filterPathGates.filter((gate) => gate === "passed").length},failed:${filterPathGates.filter((gate) => gate === "failed").length}`,
    );
  }

  const filterConfigPaths = output.match(
    /^PROC_MON_FILTER_CONFIG_PATHS=canary:(\d{1,3});control:(\d{1,3})\r?$/m,
  );
  if (filterConfigPaths) {
    diagnostics.push(
      `config-filter-paths=canary:${filterConfigPaths[1]};control:${filterConfigPaths[2]}`,
    );
  }

  const reloadedFilterRules = output.match(
    /^PROC_MON_FILTER_RELOADED_RULES=rows:(\d{1,2});canary:(\d{1,2});control:(\d{1,2});path:(\d{1,2});is:(\d{1,2});include:(\d{1,2});unclassified:(\d{1,2})\r?$/m,
  );
  if (reloadedFilterRules) {
    const counts = reloadedFilterRules.slice(1).map(Number);
    const [rows, canary, control, path, relation, include, unclassified] = counts;
    if (
      rows <= 64
      && counts.every((count) => count <= 64)
      && canary <= rows
      && control <= rows
      && path <= rows
      && relation <= rows
      && include <= rows
      && unclassified <= rows
    ) {
      diagnostics.push(
        `reloaded-filter-rules=rows:${rows};canary:${canary};control:${control};path:${path};is:${relation};include:${include};unclassified:${unclassified}`,
      );
    }
  }

  const reloadedFilterRowShape = output.match(
    /^PROC_MON_FILTER_RELOADED_ROW_SHAPE=rows:(\d{1,2});distinct:(\d{1,2});duplicates:(\d{1,2});list-items:(\d{1,2});data-items:(\d{1,2});include:(\d{1,2});exclude:(\d{1,2});path-field:(\d{1,2});process-field:(\d{1,2});operation-field:(\d{1,2});other-field:(\d{1,2});unknown-field:(\d{1,2})\r?$/m,
  );
  if (reloadedFilterRowShape) {
    const counts = reloadedFilterRowShape.slice(1).map(Number);
    const [
      rows,
      distinct,
      duplicates,
      listItems,
      dataItems,
      include,
      exclude,
      pathField,
      processField,
      operationField,
      otherField,
      unknownField,
    ] = counts;
    if (
      rows <= 64
      && counts.every((count) => count <= rows)
      && distinct + duplicates === rows
      && listItems + dataItems === rows
      && include + exclude === rows
      && pathField + processField + operationField + otherField + unknownField === rows
    ) {
      diagnostics.push(
        `reloaded-filter-row-shape=rows:${rows};distinct:${distinct};duplicates:${duplicates};list-items:${listItems};data-items:${dataItems};include:${include};exclude:${exclude};path-field:${pathField};process-field:${processField};operation-field:${operationField};other-field:${otherField};unknown-field:${unknownField}`,
      );
    }
  }

  const ruleClear = output.match(
    /^PROC_MON_FILTER_RULE_CLEAR=rows:(\d{1,2});multi-select:(true|false)\r?$/m,
  );
  if (ruleClear && Number(ruleClear[1]) <= 64) {
    diagnostics.push(
      `filter-rule-clear=rows:${ruleClear[1]};multi-select:${ruleClear[2]}`,
    );
  }

  const nativeShape = output.match(
    /^PROC_MON_FILTER_NATIVE_SHAPE=expected-columns:4;actual-columns:(\d)\r?$/m,
  );
  if (nativeShape) {
    const actualColumns = Number(nativeShape[1]);
    if (actualColumns >= 1 && actualColumns <= 8) {
      diagnostics.push(
        `filter-native-shape=expected-columns:4;actual-columns:${actualColumns}`,
      );
    }
  }

  const ruleSelection = output.match(
    /^PROC_MON_FILTER_RULE_SELECTION=selected:(\d{1,2});expected:(\d{1,2})\r?$/m,
  );
  if (ruleSelection) {
    const [selected, expected] = ruleSelection.slice(1).map(Number);
    if (selected <= 64 && expected <= 64 && selected <= expected) {
      diagnostics.push(
        `filter-rule-selection=selected:${selected};expected:${expected}`,
      );
    }
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_RULE_SELECTION_FAILURE=phase:(row-state|runtime-id|pattern|select|add|verify|selection-set);row:(\d{1,2});completed:(\d{1,2});expected:(\d{1,2})\r?$/gm,
  )) {
    const [, phase, rawRow, rawCompleted, rawExpected] = match;
    const row = Number(rawRow);
    const completed = Number(rawCompleted);
    const expected = Number(rawExpected);
    const isSelectionSetFailure = phase === "selection-set";
    if (
      expected > 0
      && expected <= 64
      && completed <= expected
      && (
        (
          isSelectionSetFailure
          && row === 0
          && completed === expected
        )
        || (
          !isSelectionSetFailure
          && row > 0
          && row <= expected
          && completed < expected
          && completed === row - 1
        )
      )
    ) {
      diagnostics.push(
        `filter-rule-selection-failure=phase:${phase};row:${row};completed:${completed};expected:${expected}`,
      );
    }
  }

  const removeControl = output.match(
    /^PROC_MON_FILTER_REMOVE=buttons:(\d{1,2});enabled:(true|false)\r?$/m,
  );
  if (removeControl && Number(removeControl[1]) <= 16) {
    diagnostics.push(
      `filter-rule-remove=buttons:${removeControl[1]};enabled:${removeControl[2]}`,
    );
  }

  const remainingRules = output.match(
    /^PROC_MON_FILTER_RULES_REMAINING=rows:(\d{1,2})\r?$/m,
  );
  if (remainingRules && Number(remainingRules[1]) <= 64) {
    diagnostics.push(`filter-rules-remaining=${remainingRules[1]}`);
  }

  const resetRules = output.match(
    /^PROC_MON_FILTER_RULE_RESET=removed:(\d{1,2});remaining:(0)\r?$/m,
  );
  if (resetRules && Number(resetRules[1]) <= 64) {
    diagnostics.push(
      `filter-rule-reset=removed:${resetRules[1]};remaining:0`,
    );
  }

  const windowScan = output.match(
    /^PROC_MON_FILTER_WINDOW_SCAN=stage:(initial|reload);phase:(refresh-process|check-process|enumerate-uia-windows|read-uia-window-owner|read-main-window-handle|read-main-window-owner|wait|foreground-owner);process-exited:(true|false);root-windows:(\d{1,4});uia-owned-windows:(\d{1,4});main-handle:(available|unavailable);foreground-owner:(same|other|unavailable)\r?$/m,
  );
  if (windowScan) {
    const [rootWindows, ownedWindows] = windowScan.slice(4, 6).map(Number);
    if (rootWindows <= 9999 && ownedWindows <= rootWindows) {
      diagnostics.push(
        `${windowScan[1]}-window-scan=phase:${windowScan[2]};process-exited:${windowScan[3]};root-windows:${rootWindows};uia-owned-windows:${ownedWindows};main-handle:${windowScan[6]};foreground-owner:${windowScan[7]}`,
      );
    }
  }

  const reloadedFilterUi = output.match(
    /^PROC_MON_FILTER_RELOADED_UI=items:(\d{1,4});lists:(\d{1,4});data-grids:(\d{1,4});tables:(\d{1,4});list-items:(\d{1,4});data-items:(\d{1,4});dialog-window-rows:(\d{1,4});other-window-rows:(\d{1,4});unscoped-rows:(\d{1,4});combo-option-rows:(\d{1,4});rule-containers:(\d{1,2});rule-row-candidates:(\d{1,4});rule-container-unclassified-rows:(\d{1,4});rows:(\d{1,2});truncated:(true|false)\r?$/m,
  ) ?? output.match(
    /^PROC_MON_FILTER_RELOADED_UI=items:(\d{1,4});lists:(\d{1,4});data-grids:(\d{1,4});tables:(\d{1,4});list-items:(\d{1,4});data-items:(\d{1,4});dialog-window-rows:(\d{1,4});other-window-rows:(\d{1,4});unscoped-rows:(\d{1,4});rows:(\d{1,2});truncated:(true|false)\r?$/m,
  ) ?? output.match(
    /^PROC_MON_FILTER_RELOADED_UI=items:(\d{1,4});lists:(\d{1,4});data-grids:(\d{1,4});tables:(\d{1,4});list-items:(\d{1,4});data-items:(\d{1,4});rows:(\d{1,2});truncated:(true|false)\r?$/m,
  );
  if (reloadedFilterUi) {
    if (reloadedFilterUi.length === 16) {
      const counts = reloadedFilterUi.slice(1, 15).map(Number);
      const [
        items,
        lists,
        dataGrids,
        tables,
        listItems,
        dataItems,
        dialogWindowRows,
        otherWindowRows,
        unscopedRows,
        comboOptionRows,
        ruleContainers,
        ruleRowCandidates,
        ruleContainerUnclassifiedRows,
        rows,
      ] = counts;
      if (
        items <= 1024
        && [lists, dataGrids, tables, listItems, dataItems].every((count) => count <= items)
        && dialogWindowRows + otherWindowRows + unscopedRows <= items
        && comboOptionRows <= dialogWindowRows
        && ruleContainers <= 32
        && ruleRowCandidates + ruleContainerUnclassifiedRows <= dialogWindowRows
        && rows <= 64
      ) {
        diagnostics.push(
          `reloaded-filter-ui=items:${items};lists:${lists};data-grids:${dataGrids};tables:${tables};list-items:${listItems};data-items:${dataItems};dialog-window-rows:${dialogWindowRows};other-window-rows:${otherWindowRows};unscoped-rows:${unscopedRows};combo-option-rows:${comboOptionRows};rule-containers:${ruleContainers};rule-row-candidates:${ruleRowCandidates};rule-container-unclassified-rows:${ruleContainerUnclassifiedRows};rows:${rows};truncated:${reloadedFilterUi[15]}`,
        );
      }
    } else if (reloadedFilterUi.length === 12) {
      const counts = reloadedFilterUi.slice(1, 11).map(Number);
      const [
        items,
        lists,
        dataGrids,
        tables,
        listItems,
        dataItems,
        dialogWindowRows,
        otherWindowRows,
        unscopedRows,
        rows,
      ] = counts;
      if (
        items <= 1024
        && [lists, dataGrids, tables, listItems, dataItems].every((count) => count <= items)
        && dialogWindowRows + otherWindowRows + unscopedRows <= items
        && rows <= 64
      ) {
        diagnostics.push(
          `reloaded-filter-ui=items:${items};lists:${lists};data-grids:${dataGrids};tables:${tables};list-items:${listItems};data-items:${dataItems};dialog-window-rows:${dialogWindowRows};other-window-rows:${otherWindowRows};unscoped-rows:${unscopedRows};rows:${rows};truncated:${reloadedFilterUi[11]}`,
        );
      }
    } else {
      const counts = reloadedFilterUi.slice(1, 8).map(Number);
      const [items, lists, dataGrids, tables, listItems, dataItems, rows] = counts;
      if (
        items <= 1024
        && [lists, dataGrids, tables, listItems, dataItems].every((count) => count <= items)
        && rows <= 64
      ) {
        diagnostics.push(
          `reloaded-filter-ui=items:${items};lists:${lists};data-grids:${dataGrids};tables:${tables};list-items:${listItems};data-items:${dataItems};rows:${rows};truncated:${reloadedFilterUi[8]}`,
        );
      }
    }
  }

  const reloadedDrop = output.match(
    /^PROC_MON_FILTER_RELOADED_DROP=checked:(on|off|unavailable)\r?$/m,
  )?.[1];
  if (reloadedDrop) {
    diagnostics.push(`reloaded-drop-filtered-events=${reloadedDrop}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_SAVE_RESULT=phase:(after-enter|after-wait|export-timeout);foreground:(procmon-main|procmon-other|other-process|unavailable);same-process-dialogs:(\d{1,2});other-process-windows:(\d{1,2});buttons:save:(\d{1,2});cancel:(\d{1,2});yes:(\d{1,2});no:(\d{1,2});ok:(\d{1,2});retry:(\d{1,2});close:(\d{1,2});truncated:(true|false)\r?$/gm,
  )) {
    const counts = match.slice(3, 12).map(Number);
    if (counts.every((count) => count <= 32)) {
      diagnostics.push(
        `config-save-result-${match[1]}=foreground:${match[2]};same-process-dialogs:${match[3]};other-process-windows:${match[4]};buttons:save:${match[5]};cancel:${match[6]};yes:${match[7]};no:${match[8]};ok:${match[9]};retry:${match[10]};close:${match[11]};truncated:${match[12]}`,
      );
    }
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_SAVE_RESULT_FAILED=phase:(after-enter|after-wait|export-timeout)\r?$/gm,
  )) {
    diagnostics.push(`config-save-result-${match[1]}=unavailable`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_CONFIG_SAVE=(after-invoke|verify-failed|focus-failed|foreground-failed);(dialog:(?:unavailable|other-process)|dialog:available;enabled:(?:true|false);offscreen:(?:true|false);path:(?:matches|different);save-enabled:(?:true|false);save-offscreen:(?:true|false);save-focusable:(?:true|false);save-focused:(?:true|false))\r?$/gm,
  )) {
    diagnostics.push(`config-save-${match[1]}=${match[2]}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_CONFIG_OUTPUT=phase:(before-save|after-invoke|after-wait);target:(missing|directory|undersized|ready);target-header:(not-file|empty|short|mz|xml|other);pmc-count:(\d{1,2});headers:empty:(\d{1,2});short:(\d{1,2});mz:(\d{1,2});xml:(\d{1,2});other:(\d{1,2});other-count:(\d{1,2});truncated:(true|false)\r?$/gm,
  )) {
    const counts = match.slice(4, 10).map(Number);
    const [pmcCount, ...headerCounts] = counts;
    if (
      pmcCount <= 32
      && counts.every((count) => count <= 32)
      && headerCounts.reduce((sum, count) => sum + count, 0) <= pmcCount
      && Number(match[10]) <= 32
    ) {
      diagnostics.push(
        `config-output-${match[1]}=target:${match[2]};target-header:${match[3]};pmc-count:${match[4]};headers:empty:${match[5]};short:${match[6]};mz:${match[7]};xml:${match[8]};other:${match[9]};other-count:${match[10]};truncated:${match[11]}`,
      );
    }
  }

  const desktopResetOwner = output.match(
    /^PROC_MON_FILTER_DIALOG_DESKTOP_RESET_OWNER=(procmon-main|procmon-other|other-process|none)\r?$/m,
  )?.[1];
  if (desktopResetOwner) {
    diagnostics.push(`filter-dialog-desktop-reset-owner=${desktopResetOwner}`);
  }

  const dialogDiscovery = output.match(
    /^PROC_MON_FILTER_DIALOG_DISCOVERY=(embedded-window|focused-window|native-top-level-window)\r?$/m,
  )?.[1];
  if (dialogDiscovery) {
    diagnostics.push(`filter-dialog-discovery=${dialogDiscovery}`);
  }

  const dialogLayout = output.match(
    /^PROC_MON_FILTER_DIALOG_LAYOUT=combos:(\d{1,4});edits:(\d{1,4})\r?$/m,
  );
  if (dialogLayout) {
    diagnostics.push(
      `filter-dialog-layout=combos:${dialogLayout[1]};edits:${dialogLayout[2]}`,
    );
  }

  const pathEdit = output.match(
    /^PROC_MON_FILTER_PATH_EDIT=enabled:(true|false);offscreen:(true|false);read-only:(true|false);value-pattern:(true|false)\r?$/m,
  );
  if (pathEdit) {
    diagnostics.push(
      `filter-path-edit=enabled:${pathEdit[1]};offscreen:${pathEdit[2]};read-only:${pathEdit[3]};value-pattern:${pathEdit[4]}`,
    );
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_DROP_PATTERN=(toggle|invoke|selection-item):(true|false)\r?$/gm,
  )) {
    diagnostics.push(`drop-filter-pattern-${match[1]}=${match[2]}`);
  }

  const dropItemState = output.match(
    /^PROC_MON_FILTER_DROP_ITEM_STATE=enabled:(true|false);offscreen:(true|false);keyboard-focusable:(true|false);item-status:(checked|unchecked|on|off|mixed|other);help-text:(checked|unchecked|on|off|mixed|other)\r?$/m,
  );
  if (dropItemState) {
    diagnostics.push(
      `drop-filter-item-state=enabled:${dropItemState[1]};offscreen:${dropItemState[2]};keyboard-focusable:${dropItemState[3]};item-status:${dropItemState[4]};help-text:${dropItemState[5]}`,
    );
  }

  const dropItemBackend = output.match(
    /^PROC_MON_FILTER_DROP_ITEM_BACKEND=framework:(Win32|WPF|WinForm|DirectUI|other);native-window-handle:(true|false);menu-window-handle:(true|false)\r?$/m,
  );
  if (dropItemBackend) {
    diagnostics.push(
      `drop-filter-item-backend=framework:${dropItemBackend[1]};native-window-handle:${dropItemBackend[2]};menu-window-handle:${dropItemBackend[3]}`,
    );
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_NATIVE_MENU_STATE=observation:(before|after-invoke|after-reload);source:(main|menu-window|menu-owner|unavailable);menu-window-process:(same|other|unavailable);gui-thread-info:(available|unavailable);owner-window:(available|unavailable);handle:(available|unavailable);items:(\d{1,3});matches:(\d{1,3});read-failure:(none|depth-limit|total-limit|menu-count-invalid|menu-count-failed|menu-count-limit|invalid-menu-handle|owner-drawn|item-read-failed);readable:(true|false);checked:(on|off|unavailable)\r?$/gm,
  )) {
    const [
      ,
      observation,
      source,
      menuWindowProcess,
      guiThreadInfo,
      ownerWindow,
      handle,
      rawItems,
      rawMatches,
      readFailure,
      readable,
      checked,
    ] = match;
    const items = Number(rawItems);
    const matches = Number(rawMatches);
    const validSource =
      (source === "main" && handle === "available")
      || (
        (source === "menu-window" || source === "menu-owner")
        && menuWindowProcess === "same"
        && guiThreadInfo === "available"
        && ownerWindow === "available"
        && handle === "available"
      )
      || (
        source === "unavailable"
        && handle === "unavailable"
        && items === 0
        && matches === 0
        && readable === "false"
      );
    const consistentCheck =
      validSource
      && readFailure === "none"
      && handle === "available"
      && readable === "true"
      && matches === 1
      && (checked === "on" || checked === "off");
    const consistentUnavailable =
      checked === "unavailable"
      && (
        (
          validSource
          && handle === "available"
          && (
            (readFailure === "none" && readable === "true" && matches !== 1)
            || (readFailure !== "none" && readable === "false")
          )
        )
        || (
          source === "unavailable"
          && handle === "unavailable"
          && items === 0
          && matches === 0
          && readFailure === "none"
          && readable === "false"
        )
      );
    if (
      items <= 256
      && matches <= items
      && (consistentCheck || consistentUnavailable)
    ) {
      diagnostics.push(
        `drop-native-menu-state=observation:${observation};source:${source};menu-window-process:${menuWindowProcess};gui-thread-info:${guiThreadInfo};owner-window:${ownerWindow};handle:${handle};items:${items};matches:${matches};read-failure:${readFailure};readable:${readable};checked:${checked}`,
      );
    }
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MSAA_MENU_STATE=observation:(before|after-invoke|after-reload);process:(same|other|unavailable);object:(available|unavailable);items:(\d{1,2});matches:(\d{1,2});read-failure:(none|window-unavailable|process-mismatch|object-unavailable|object-invalid|count-invalid|count-limit|child-read-failed|state-invalid|no-match|duplicate-match);checked:(on|off|unavailable)\r?$/gm,
  )) {
    const [
      ,
      observation,
      process,
      object,
      rawItems,
      rawMatches,
      readFailure,
      checked,
    ] = match;
    const items = Number(rawItems);
    const matches = Number(rawMatches);
    const sameProcessObject = process === "same" && object === "available";
    const unavailableObject =
      (process === "unavailable" && readFailure === "window-unavailable")
      || (process === "other" && readFailure === "process-mismatch")
      || (process === "same" && ["object-unavailable", "object-invalid"].includes(readFailure));
    const consistentCheck =
      sameProcessObject
      && readFailure === "none"
      && matches === 1
      && (checked === "on" || checked === "off");
    const consistentUnavailable =
      checked === "unavailable"
      && (
        (sameProcessObject && readFailure !== "none")
        || (unavailableObject && items === 0 && matches === 0 && object === "unavailable")
        || (sameProcessObject && readFailure === "none" && matches !== 1)
      );
    if (
      items <= 64
      && matches <= items
      && (consistentCheck || consistentUnavailable)
    ) {
      diagnostics.push(
        `drop-msaa-menu-state=observation:${observation};process:${process};object:${object};items:${items};matches:${matches};read-failure:${readFailure};checked:${checked}`,
      );
    }
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MSAA_MENU_ENABLED=observation:after-reload;enabled:(true|false)\r?$/gm,
  )) {
    diagnostics.push(
      `drop-msaa-menu-enabled=observation:after-reload;enabled:${match[1]}`,
    );
  }

  const resetTree = output.match(
    /^PROC_MON_FILTER_DIALOG_RESET_TREE=(Window|Pane|ToolBar|Button|Text|Edit|Other)(?:>(?:Window|Pane|ToolBar|Button|Text|Edit|Other)){0,3}\r?$/m,
  )?.[0]?.replace("PROC_MON_FILTER_DIALOG_RESET_TREE=", "");
  if (resetTree) {
    diagnostics.push(`filter-dialog-reset-tree=${resetTree}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUS_OWNER=(after-command-invoke|after-filter-dialog-shortcut|after-save-enter);owner:(procmon-main|procmon-other|other-process|no-window|unavailable)(?:;reason:(ElementNotAvailableException|InvalidOperationException|COMException|Other))?\r?$/gm,
  )) {
    const reason = match[3] ? `;reason:${match[3]}` : "";
    diagnostics.push(`focus-owner-${match[1]}=${match[2]}${reason}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUS_NATIVE_ROOT=(after-command-invoke|after-filter-dialog-shortcut);root:(procmon-main|procmon-other|other-process|none|unavailable)\r?$/gm,
  )) {
    diagnostics.push(`focus-native-root-${match[1]}=${match[2]}`);
  }

  const tree = output.match(/PROC_MON_FILTER_MENU_TREE=([A-Za-z:>]+)/)?.[1];
  if (tree) {
    const nodes = tree.split(">");
    if (
      nodes.length <= 4
      && nodes.every((node) => {
        const [type, name, ...extra] = node.split(":");
        return extra.length === 0 && allowedTypes.test(type) && allowedNames.test(name);
      })
    ) {
      diagnostics.push(`menu-tree=${tree}`);
    }
  }

  const focus = output.match(
    /PROC_MON_FILTER_MENU_FOCUS=(returned|skipped-not-keyboard-focusable|failed-(?:ElementNotEnabledException|ElementNotAvailableException|InvalidOperationException|COMException|NoClickablePointException|Other))/,
  )?.[1];
  if (focus) diagnostics.push(`menu-focus=${focus}`);

  const failureType = output.match(
    /PROC_MON_FILTER_FAILURE=(AmbiguousMatchException|ArgumentException|COMException|DllNotFoundException|ElementNotAvailableException|EntryPointNotFoundException|InvalidOperationException|MethodAccessException|MethodException|MethodInvocationException|MissingMethodException|NullReferenceException|RuntimeException|TargetInvocationException|TypeInitializationException|Other)/,
  )?.[1];
  if (failureType) diagnostics.push(`failure-type=${failureType}`);

  const failedStage = [...output.matchAll(
    /^PROC_MON_FILTER_FAILED_STAGE=(refresh-filter-menu-process|read-filter-menu-main-handle|check-filter-menu-main-handle|read-filter-menu-main-owner|verify-filter-menu-main-owner|check-filter-menu-main-visible|check-filter-menu-main-enabled|resolve-filter-menu-blocking-snapshot-dialog|verify-filter-menu-main-enabled-after-recovery|resolve-filter-menu-main-uia|read-filter-menu-main-state|classify-filter-menu-main-state|validate-filter-menu-main|focus-filter-menu-main|find-filter-menu-item|find-filter-toolbar-command|invoke-filter-toolbar-command|wait-filter-toolbar-popup|find-native-filter-toolbar-command|invoke-native-filter-toolbar-command|wait-native-filter-toolbar-popup|read-accessible-filter-toolbar-command|invoke-accessible-filter-toolbar-command|wait-accessible-filter-toolbar-popup|verify-filter-menu-item|fallback-open-filter-menu-with-keyboard|wait-filter-menu-popup|invoke-filter-menu-item|resolve-opened-filter-menu|find-filter-menu-for-drop-filtered-events|fallback-open-filter-dialog-shortcut|wait-filter-dialog-shortcut|reset-existing-filters|clear-existing-filter-rules|set-canary-filter|set-control-filter|apply-filters|save-filter|reload-filter|capture|verify-capture)\r?$/gm,
  )].at(-1)?.[1];
  if (failedStage) diagnostics.push(`failed-stage=${failedStage}`);

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_SNAPSHOT=(writer|caller);element:(present|missing);control-type:(menu|menu-item|window|pane|toolbar|other|missing)\r?$/gm,
  )) {
    diagnostics.push(
      `focus-snapshot-${match[1]}=element:${match[2]};control-type:${match[3]}`,
    );
  }

  const focusObservations = [];
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MENU_ITEMS=(after-open|after-home|before-save);unavailable\r?$/gm,
  )) {
    focusObservations.push({
      index: match.index,
      value: `menu-items-${match[1]}=unavailable`,
    });
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MENU_ITEMS=(after-open|after-home|before-save);count:(\d{1,6});truncated:(true|false);items=([A-Za-z:,]*)\r?$/gm,
  )) {
    const items = match[4] === "" ? [] : match[4].split(",");
    if (
      items.length <= 8
      && items.every((item) => {
        const [type, name, enabled, offscreen, focusable, ...extra] = item.split(":");
        return extra.length === 0
          && allowedTypes.test(type)
          && allowedNames.test(name)
          && /^(?:true|false)$/.test(enabled)
          && /^(?:true|false)$/.test(offscreen)
          && /^(?:true|false)$/.test(focusable);
      })
    ) {
      focusObservations.push({
        index: match.index,
        value: `menu-items-${match[1]}=count:${match[2]};truncated:${match[3]};items=${match[4]}`,
      });
    }
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke|after-filter-dialog-shortcut|after-reload-filter-dialog-shortcut|after-reload-menu-(?:expand|select|legacy-ia|pointer|invoke|access-key|keyboard-event|keyboard-filter));focused:(none|unavailable)\r?$/gm,
  )) {
    focusObservations.push({
      index: match.index,
      value: `focus-${match[1]}=${match[2]}`,
    });
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke|after-filter-dialog-shortcut|after-reload-filter-dialog-shortcut|after-reload-menu-(?:expand|select|legacy-ia|pointer|invoke|access-key|keyboard-event|keyboard-filter));type:(MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other);name:(Event|FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|MenuBar|ProcessMonitor|Other);offscreen:(true|false);keyboard-focusable:(true|false);tree=([A-Za-z:>]+)\r?$/gm,
  )) {
    const nodes = match[6].split(">");
    if (
      nodes.length <= 4
      && nodes.every((node) => {
        const [type, name, ...extra] = node.split(":");
        return extra.length === 0 && allowedTypes.test(type) && allowedNames.test(name);
      })
    ) {
      focusObservations.push({
        index: match.index,
        value: `focus-${match[1]}=${match[2]}:${match[3]};offscreen:${match[4]};keyboard-focusable:${match[5]};tree=${match[6]}`,
      });
    }
  }
  focusObservations.sort((left, right) => left.index - right.index);
  diagnostics.push(...focusObservations.map(({ value }) => value));
  return diagnostics.length > 0 ? `; ${diagnostics.join("; ")}` : "";
}
