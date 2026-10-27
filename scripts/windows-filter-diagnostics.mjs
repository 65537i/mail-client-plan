const allowedTypes = /^(?:MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other)$/;
const allowedNames = /^(?:Event|FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|DropFilteredEvents|HighlightFilteredEvents|MenuBar|ProcessMonitor|Other)$/;
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
    /^PROC_MON_FILTER_SAVE_RESULT=phase:(after-enter|after-wait);foreground:(procmon-main|procmon-other|other-process|unavailable);same-process-dialogs:(\d{1,2});other-process-windows:(\d{1,2});buttons:save:(\d{1,2});cancel:(\d{1,2});yes:(\d{1,2});no:(\d{1,2});ok:(\d{1,2});retry:(\d{1,2});close:(\d{1,2});truncated:(true|false)\r?$/gm,
  )) {
    const counts = match.slice(3, 12).map(Number);
    if (counts.every((count) => count <= 32)) {
      diagnostics.push(
        `config-save-result-${match[1]}=foreground:${match[2]};same-process-dialogs:${match[3]};other-process-windows:${match[4]};buttons:save:${match[5]};cancel:${match[6]};yes:${match[7]};no:${match[8]};ok:${match[9]};retry:${match[10]};close:${match[11]};truncated:${match[12]}`,
      );
    }
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
    /^PROC_MON_FILTER_MSAA_MENU_STATE=observation:(before|after-invoke|after-reload);process:(same|other|unavailable);object:(available|unavailable);items:(\d{1,2});matches:(\d{1,2});read-failure:(none|window-unavailable|process-mismatch|object-unavailable|count-invalid|count-limit|child-read-failed|state-invalid|no-match|duplicate-match);checked:(on|off|unavailable)\r?$/gm,
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
    /^PROC_MON_FILTER_FOCUS_OWNER=(after-command-invoke|after-save-enter);owner:(procmon-main|procmon-other|other-process|no-window|unavailable)(?:;reason:(ElementNotAvailableException|InvalidOperationException|COMException|Other))?\r?$/gm,
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
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke|after-reload-filter-dialog-shortcut|after-reload-menu-(?:expand|select|legacy-ia|pointer|invoke|access-key|keyboard-event|keyboard-filter));focused:(none|unavailable)\r?$/gm,
  )) {
    focusObservations.push({
      index: match.index,
      value: `focus-${match[1]}=${match[2]}`,
    });
  }
  for (const match of output.matchAll(
    /^PROC_MON_FILTER_FOCUSED_CONTROL=(after-open|after-home|filter-command|after-enter|after-invoke|after-click|after-command-invoke|after-reload-filter-dialog-shortcut|after-reload-menu-(?:expand|select|legacy-ia|pointer|invoke|access-key|keyboard-event|keyboard-filter));type:(MenuBar|Menu|MenuItem|Window|Pane|ToolBar|Button|Text|Edit|Other);name:(Event|FileMenu|Filter|FilterCommand|SaveFilterCommand|ExportConfigCommand|MenuBar|ProcessMonitor|Other);offscreen:(true|false);keyboard-focusable:(true|false);tree=([A-Za-z:>]+)\r?$/gm,
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
