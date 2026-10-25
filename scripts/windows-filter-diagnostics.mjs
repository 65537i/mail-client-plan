const allowedTypes = /^(?:MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other)$/;
const allowedNames = /^(?:Filter|FilterCommand|DropFilteredEvents|HighlightFilteredEvents|MenuBar|ProcessMonitor|Other)$/;
export const windowsFilterOutputLimit = 8192;

export function appendBoundedWindowsFilterOutput(current, chunk) {
  const remaining = windowsFilterOutputLimit - current.length;
  return remaining > 0 ? current + chunk.slice(0, remaining) : current;
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
    /^PROC_MON_FILTER_DROP_ITEM_STATE=keyboard-focusable:(true|false);item-status:(checked|unchecked|on|off|mixed|other);help-text:(checked|unchecked|on|off|mixed|other)\r?$/m,
  );
  if (dropItemState) {
    diagnostics.push(
      `drop-filter-item-state=keyboard-focusable:${dropItemState[1]};item-status:${dropItemState[2]};help-text:${dropItemState[3]}`,
    );
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
    /PROC_MON_FILTER_FAILURE=(ArgumentException|COMException|ElementNotAvailableException|InvalidOperationException|NullReferenceException|RuntimeException|Other)/,
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
    /^PROC_MON_FILTER_MENU_ITEMS=(after-open|after-home);unavailable\r?$/gm,
  )) {
    focusObservations.push({
      index: match.index,
      value: `menu-items-${match[1]}=unavailable`,
    });
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_MENU_ITEMS=(after-open|after-home);count:(\d{1,6});truncated:(true|false);items=([A-Za-z:,]*)\r?$/gm,
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
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke);type:(MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other);name:(Filter|FilterCommand|MenuBar|ProcessMonitor|Other);offscreen:(true|false);keyboard-focusable:(true|false);tree=([A-Za-z:>]+)\r?$/gm,
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
