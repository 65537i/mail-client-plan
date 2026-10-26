const allowedTypes = /^(?:MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other)$/;
const allowedNames = /^(?:FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|DropFilteredEvents|HighlightFilteredEvents|MenuBar|ProcessMonitor|Other)$/;
export const windowsFilterOutputLimit = 8192;
const windowsFilterOutputHeadLimit = 3072;
const windowsFilterOutputTruncationMarker = "\nPROC_MON_FILTER_OUTPUT_TRUNCATED=true\n";
const windowsFilterOutputTailLimit =
  windowsFilterOutputLimit
  - windowsFilterOutputHeadLimit
  - windowsFilterOutputTruncationMarker.length;

export function appendBoundedWindowsFilterOutput(current, chunk) {
  const combined = current + chunk;
  if (combined.length <= windowsFilterOutputLimit) return combined;
  return combined.slice(0, windowsFilterOutputHeadLimit)
    + windowsFilterOutputTruncationMarker
    + combined.slice(-windowsFilterOutputTailLimit);
}

export function describeWindowsFilterDiagnostics(output) {
  const diagnostics = [];
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

  const dialogScan = output.match(
    /PROC_MON_FILTER_DIALOG_SCAN=process-windows:(\d{1,4});non-main-windows:(\d{1,4});reset-control:(true|false)/,
  );
  if (dialogScan) {
    diagnostics.push(
      `filter-dialog-scan=process-windows:${dialogScan[1]};non-main-windows:${dialogScan[2]};reset-control:${dialogScan[3]}`,
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

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_CONFIG_FILE=observation:(initial|final);state:(missing|undersized|ready)\r?$/gm,
  )) {
    diagnostics.push(`config-file-${match[1]}=${match[2]}`);
  }

  const saveFocusGate = output.match(
    /^PROC_MON_FILTER_SAVE_FOCUS=gate:(passed|failed)\r?$/m,
  )?.[1];
  if (saveFocusGate) diagnostics.push(`config-save-focus-gate=${saveFocusGate}`);

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_CONFIG_SAVE=(after-invoke|verify-failed|focus-failed);(dialog:(?:unavailable|other-process)|dialog:available;enabled:(?:true|false);offscreen:(?:true|false);path:(?:matches|different);save-enabled:(?:true|false);save-offscreen:(?:true|false);save-focusable:(?:true|false);save-focused:(?:true|false))\r?$/gm,
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

  if (/^PROC_MON_FILTER_DIALOG_DISCOVERY=embedded-window\r?$/m.test(output)) {
    diagnostics.push("filter-dialog-discovery=embedded-window");
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
    /^PROC_MON_FILTER_NATIVE_MENU_STATE=observation:(before|after-invoke);source:(main|menu-window|menu-owner|unavailable);menu-window-process:(same|other|unavailable);gui-thread-info:(available|unavailable);owner-window:(available|unavailable);handle:(available|unavailable);items:(\d{1,3});matches:(\d{1,3});read-failure:(none|depth-limit|total-limit|menu-count-invalid|menu-count-failed|menu-count-limit|invalid-menu-handle|owner-drawn|item-read-failed);readable:(true|false);checked:(on|off|unavailable)\r?$/gm,
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
    /^PROC_MON_FILTER_MSAA_MENU_STATE=observation:(before|after-invoke);process:(same|other|unavailable);object:(available|unavailable);items:(\d{1,2});matches:(\d{1,2});read-failure:(none|window-unavailable|process-mismatch|object-unavailable|count-invalid|count-limit|child-read-failed|state-invalid|no-match|duplicate-match);checked:(on|off|unavailable)\r?$/gm,
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
      || (process === "same" && readFailure === "object-unavailable");
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

  const resetTree = output.match(
    /^PROC_MON_FILTER_DIALOG_RESET_TREE=(Window|Pane|ToolBar|Button|Text|Edit|Other)(?:>(?:Window|Pane|ToolBar|Button|Text|Edit|Other)){0,3}\r?$/m,
  )?.[0]?.replace("PROC_MON_FILTER_DIALOG_RESET_TREE=", "");
  if (resetTree) {
    diagnostics.push(`filter-dialog-reset-tree=${resetTree}`);
  }

  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUS_OWNER=(after-command-invoke);owner:(procmon-main|procmon-other|other-process|no-window|unavailable)(?:;reason:(ElementNotAvailableException|InvalidOperationException|COMException|Other))?\r?$/gm,
  )) {
    const reason = match[3] ? `;reason:${match[3]}` : "";
    diagnostics.push(`focus-owner-${match[1]}=${match[2]}${reason}`);
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
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke);focused:(none|unavailable)\r?$/gm,
  )) {
    focusObservations.push({
      index: match.index,
      value: `focus-${match[1]}=${match[2]}`,
    });
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke);type:(MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other);name:(FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|MenuBar|ProcessMonitor|Other);offscreen:(true|false);keyboard-focusable:(true|false);tree=([A-Za-z:>]+)\r?$/gm,
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
