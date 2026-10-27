import assert from "node:assert/strict";
import test from "node:test";
import {
  appendBoundedWindowsFilterOutput,
  describeWindowsFilterDiagnostics,
  windowsFilterOutputLimit,
} from "../../scripts/windows-filter-diagnostics.mjs";

test("AC-05: Windows filter diagnostics retain only allowlisted UIA and native menu state", () => {
  const output = [
    "PROC_MON_FILTER_MENU_STATE=enabled:true;offscreen:false;keyboard-focusable:true",
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:true;invoke:false",
    "PROC_MON_FILTER_COMMAND_PATTERNS=invoke:true;selection-item:false",
    "PROC_MON_FILTER_COMMAND_ACTIVATION=invoke-pattern",
    "PROC_MON_FILTER_DROP_MENU_STATE=owner-same-process:true;enabled:true;offscreen:false",
    "PROC_MON_FILTER_DROP_MENU_MATCH=items:11;matches:1",
    "PROC_MON_FILTER_DIALOG_DESKTOP_RESET_OWNER=procmon-main",
    "PROC_MON_FILTER_DIALOG_RESET_TREE=Button>Pane>Window",
    "PROC_MON_FILTER_DIALOG_DISCOVERY=embedded-window",
    "PROC_MON_FILTER_DIALOG_LAYOUT=combos:3;edits:1",
    "PROC_MON_FILTER_PATH_EDIT=enabled:true;offscreen:false;read-only:false;value-pattern:true",
    "PROC_MON_FILTER_DROP_PATTERN=toggle:true",
    "PROC_MON_FILTER_DROP_PATTERN=invoke:false",
    "PROC_MON_FILTER_DROP_PATTERN=selection-item:false",
    "PROC_MON_FILTER_DROP_ITEM_STATE=enabled:true;offscreen:false;keyboard-focusable:true;item-status:off;help-text:other",
    "PROC_MON_FILTER_DROP_ITEM_BACKEND=framework:Win32;native-window-handle:false;menu-window-handle:true",
    "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:19;matches:1;read-failure:none;readable:true;checked:off",
    "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:after-invoke;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:19;matches:1;read-failure:none;readable:true;checked:on",
    "PROC_MON_FILTER_FOCUS_OWNER=after-command-invoke;owner:procmon-main",
    "PROC_MON_FILTER_MENU_TREE=MenuItem:Filter>MenuBar:MenuBar>Window:ProcessMonitor",
    "PROC_MON_FILTER_MENU_FOCUS=failed-COMException",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; menu-state=enabled:true;offscreen:false;keyboard-focusable:true"
      + "; menu-patterns=expand-collapse:true;invoke:false"
      + "; filter-command-patterns=invoke:true;selection-item:false"
      + "; drop-filter-menu-state=owner-same-process:true;enabled:true;offscreen:false"
      + "; drop-filter-menu-match=items:11;matches:1"
      + "; filter-command-activation=invoke-pattern"
      + "; filter-dialog-desktop-reset-owner=procmon-main"
      + "; filter-dialog-discovery=embedded-window"
      + "; filter-dialog-layout=combos:3;edits:1"
      + "; filter-path-edit=enabled:true;offscreen:false;read-only:false;value-pattern:true"
      + "; drop-filter-pattern-toggle=true"
      + "; drop-filter-pattern-invoke=false"
      + "; drop-filter-pattern-selection-item=false"
      + "; drop-filter-item-state=enabled:true;offscreen:false;keyboard-focusable:true;item-status:off;help-text:other"
      + "; drop-filter-item-backend=framework:Win32;native-window-handle:false;menu-window-handle:true"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:19;matches:1;read-failure:none;readable:true;checked:off"
      + "; drop-native-menu-state=observation:after-invoke;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:19;matches:1;read-failure:none;readable:true;checked:on"
      + "; filter-dialog-reset-tree=Button>Pane>Window"
      + "; focus-owner-after-command-invoke=procmon-main"
      + "; menu-tree=MenuItem:Filter>MenuBar:MenuBar>Window:ProcessMonitor"
      + "; menu-focus=failed-COMException",
  );
});

test("AC-05: Windows filter diagnostics omit arbitrary names and exception details", () => {
  const output = [
    "PROC_MON_FILTER_MENU_STATE=enabled:yes;offscreen:false;keyboard-focusable:true",
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:yes;invoke:false",
    "PROC_MON_FILTER_MENU_TREE=MenuItem:C:\\private\\mail",
    "PROC_MON_FILTER_MENU_FOCUS=failed-SecretException",
  ].join("\n");
  assert.equal(describeWindowsFilterDiagnostics(output), "");
});

test("AC-05: reloaded Windows filter rule summaries retain bounded counts only", () => {
  const summary = "PROC_MON_FILTER_RELOADED_RULES="
    + "rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0";
  assert.equal(
    describeWindowsFilterDiagnostics(summary),
    "; reloaded-filter-rules=rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOADED_RULES=rows:65;canary:1;control:1;path:2;is:2;include:2;unclassified:0",
      "PROC_MON_FILTER_RELOADED_RULES=rows:2;canary:1;control:1;path:3;is:2;include:2;unclassified:0",
      "PROC_MON_FILTER_RELOADED_RULES=rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0;path=C:\\private\\mail",
    ].join("\n")),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(`${summary}\r`),
    "; reloaded-filter-rules=rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0",
  );
});

test("AC-05: reload window diagnostics retain only bounded process state", () => {
  const summary = "PROC_MON_FILTER_WINDOW_SCAN="
    + "stage:reload;phase:enumerate-uia-windows;process-exited:false;"
    + "root-windows:2;uia-owned-windows:0;"
    + "main-handle:unavailable;foreground-owner:other";
  assert.equal(
    describeWindowsFilterDiagnostics(summary),
    "; reload-window-scan=phase:enumerate-uia-windows;process-exited:false;"
      + "root-windows:2;uia-owned-windows:0;"
      + "main-handle:unavailable;foreground-owner:other",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_WINDOW_SCAN=stage:reload;phase:wait;process-exited:false;root-windows:2;uia-owned-windows:3;main-handle:unavailable;foreground-owner:other",
      "PROC_MON_FILTER_WINDOW_SCAN=stage:reload;phase:wait;process-exited:false;root-windows:10000;uia-owned-windows:0;main-handle:unavailable;foreground-owner:other",
      "PROC_MON_FILTER_WINDOW_SCAN=stage:reload;phase:private;process-exited:false;root-windows:2;uia-owned-windows:0;main-handle:unavailable;foreground-owner:other",
      "PROC_MON_FILTER_WINDOW_SCAN=stage:reload;phase:wait;process-exited:false;root-windows:2;uia-owned-windows:0;main-handle:unavailable;foreground-owner:other;handle=0x1234",
    ].join("\n")),
    "",
  );
});

test("AC-05: reloaded filter UI diagnostics retain only bounded control counts", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;rows:2;truncated:false",
    ),
    "; reloaded-filter-ui=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;rows:2;truncated:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:2;other-window-rows:8;unscoped-rows:1;rows:2;truncated:false",
    ),
    "; reloaded-filter-ui=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:2;other-window-rows:8;unscoped-rows:1;rows:2;truncated:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:12;other-window-rows:8;unscoped-rows:1;combo-option-rows:4;rule-containers:1;rule-row-candidates:2;rule-container-unclassified-rows:0;rows:2;truncated:false",
    ),
    "; reloaded-filter-ui=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:12;other-window-rows:8;unscoped-rows:1;combo-option-rows:4;rule-containers:1;rule-row-candidates:2;rule-container-unclassified-rows:0;rows:2;truncated:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOADED_UI=items:1025;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:35;data-grids:0;tables:0;list-items:2;data-items:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;rows:65;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;rows:2;truncated:false;name=C:\\private\\mail",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:35;other-window-rows:0;unscoped-rows:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:34;other-window-rows:1;unscoped-rows:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:2;other-window-rows:8;unscoped-rows:1;rows:2;truncated:false;name=C:\\private\\mail",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:12;other-window-rows:8;unscoped-rows:1;combo-option-rows:13;rule-containers:1;rule-row-candidates:2;rule-container-unclassified-rows:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:12;other-window-rows:8;unscoped-rows:1;combo-option-rows:4;rule-containers:33;rule-row-candidates:2;rule-container-unclassified-rows:0;rows:2;truncated:false",
      "PROC_MON_FILTER_RELOADED_UI=items:34;lists:1;data-grids:0;tables:0;list-items:2;data-items:0;dialog-window-rows:12;other-window-rows:8;unscoped-rows:1;combo-option-rows:4;rule-containers:1;rule-row-candidates:2;rule-container-unclassified-rows:11;rows:2;truncated:false;name=C:\\private\\mail",
    ].join("\n")),
    "",
  );
});

test("AC-05: reloaded rule shape diagnostics retain only consistent bounded counts", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOADED_ROW_SHAPE=rows:26;distinct:26;duplicates:0;list-items:0;data-items:26;include:2;exclude:24;path-field:2;process-field:0;operation-field:0;other-field:0;unknown-field:24",
    ),
    "; reloaded-filter-row-shape=rows:26;distinct:26;duplicates:0;list-items:0;data-items:26;include:2;exclude:24;path-field:2;process-field:0;operation-field:0;other-field:0;unknown-field:24",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOADED_ROW_SHAPE=rows:65;distinct:65;duplicates:0;list-items:0;data-items:65;include:2;exclude:63;path-field:2;process-field:0;operation-field:0;other-field:0;unknown-field:63",
      "PROC_MON_FILTER_RELOADED_ROW_SHAPE=rows:2;distinct:1;duplicates:0;list-items:0;data-items:2;include:2;exclude:0;path-field:2;process-field:0;operation-field:0;other-field:0;unknown-field:0",
      "PROC_MON_FILTER_RELOADED_ROW_SHAPE=rows:2;distinct:2;duplicates:0;list-items:1;data-items:0;include:2;exclude:0;path-field:2;process-field:0;operation-field:0;other-field:0;unknown-field:0;name=C:\\private\\mail",
    ].join("\n")),
    "",
  );
});

test("AC-05: reloaded Drop Filtered Events state accepts only a safe enum", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOADED_DROP=checked:on",
      "PROC_MON_FILTER_RELOADED_DROP=checked:off",
      "PROC_MON_FILTER_RELOADED_DROP=checked:unavailable",
      "PROC_MON_FILTER_RELOADED_DROP=checked:C:\\private\\mail",
    ].join("\n")),
    "; reloaded-drop-filtered-events=on",
  );
});

test("AC-05: Windows filter diagnostics retain the non-focusable menu route", () => {
  const output = [
    "PROC_MON_FILTER_MENU_STATE=enabled:true;offscreen:false;keyboard-focusable:false",
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:true;invoke:false",
    "PROC_MON_FILTER_MENU_FOCUS=skipped-not-keyboard-focusable",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; menu-state=enabled:true;offscreen:false;keyboard-focusable:false"
      + "; menu-patterns=expand-collapse:true;invoke:false"
      + "; menu-focus=skipped-not-keyboard-focusable",
  );
});

test("AC-05: Windows filter diagnostics retain safe focused-control observations", () => {
  const output = [
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-open;type:MenuItem;name:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other>Window:ProcessMonitor",
    "PROC_MON_FILTER_MENU_ITEMS=after-open;count:2;truncated:false;items=MenuItem:FilterCommand:true:false:false,MenuItem:DropFilteredEvents:true:false:false",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-open;type:MenuItem;name:FileMenu;offscreen:false;keyboard-focusable:true;tree=MenuItem:FileMenu>Menu:Other>Pane:Other",
    "PROC_MON_FILTER_MENU_ITEMS=after-open;count:2;truncated:false;items=MenuItem:SaveFilterCommand:true:false:true,MenuItem:Other:true:false:true",
    "PROC_MON_FILTER_MENU_ITEMS=after-home;count:1;truncated:false;items=MenuItem:C:\\private\\mail:true:false:true",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-home;type:Text;name:C:\\private\\mail;offscreen:false;keyboard-focusable:true;tree=Text:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=filter-command;type:MenuItem;name:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-enter;focused:none",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-invoke;type:Window;name:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-invoke;type:Button;name:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-invoke;type:Text;name:C:\\private\\mail;offscreen:false;keyboard-focusable:true;tree=Text:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-command-invoke;type:Window;name:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-invoke;type:MenuItem;name:Filter;offscreen:false;keyboard-focusable:true;tree=MenuItem:Filter>Menu:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-invoke;type:Button;name:C:\\private\\mail;offscreen:false;keyboard-focusable:true;tree=Button:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-expand;type:Button;name:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-select;type:Button;name:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-pointer;type:Menu;name:Filter;offscreen:false;keyboard-focusable:true;tree=Menu:Filter>Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-filter-dialog-shortcut;type:Window;name:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-keyboard-event;type:Menu;name:Other;offscreen:false;keyboard-focusable:false;tree=Menu:Other>Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-reload-menu-keyboard-filter;type:Menu;name:Other;offscreen:false;keyboard-focusable:false;tree=Menu:Other>Window:ProcessMonitor",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; focus-after-open=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other>Window:ProcessMonitor"
      + "; menu-items-after-open=count:2;truncated:false;items=MenuItem:FilterCommand:true:false:false,MenuItem:DropFilteredEvents:true:false:false"
      + "; focus-after-open=MenuItem:FileMenu;offscreen:false;keyboard-focusable:true;tree=MenuItem:FileMenu>Menu:Other>Pane:Other"
      + "; menu-items-after-open=count:2;truncated:false;items=MenuItem:SaveFilterCommand:true:false:true,MenuItem:Other:true:false:true"
      + "; focus-filter-command=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other"
      + "; focus-after-enter=none"
      + "; focus-after-invoke=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor"
      + "; focus-after-invoke=Button:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor"
      + "; focus-after-command-invoke=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor"
      + "; focus-after-reload-menu-invoke=MenuItem:Filter;offscreen:false;keyboard-focusable:true;tree=MenuItem:Filter>Menu:Other"
      + "; focus-after-reload-menu-expand=Button:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor"
      + "; focus-after-reload-menu-select=Button:Other;offscreen:false;keyboard-focusable:true;tree=Button:Other>Window:ProcessMonitor"
      + "; focus-after-reload-menu-pointer=Menu:Filter;offscreen:false;keyboard-focusable:true;tree=Menu:Filter>Window:ProcessMonitor"
      + "; focus-after-reload-filter-dialog-shortcut=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor"
      + "; focus-after-reload-menu-keyboard-event=Menu:Other;offscreen:false;keyboard-focusable:false;tree=Menu:Other>Window:ProcessMonitor"
      + "; focus-after-reload-menu-keyboard-filter=Menu:Other;offscreen:false;keyboard-focusable:false;tree=Menu:Other>Window:ProcessMonitor",
  );
});

test("AC-05: reload keyboard diagnostics retain only known Procmon commands and menu states", () => {
  const output = [
    "PROC_MON_FILTER_RELOAD_DROP_MAIN_FOREGROUND=gate:passed",
    "PROC_MON_FILTER_RELOAD_DROP_MAIN_FOREGROUND=gate:C:\\private",
    "PROC_MON_FILTER_RELOAD_SHORTCUT=command:filter-dialog;state:sent",
    "PROC_MON_FILTER_RELOAD_SHORTCUT=command:C:\\private;state:sent",
    "PROC_MON_FILTER_RELOAD_EVENT_MENU=opened",
    "PROC_MON_FILTER_RELOAD_EVENT_MENU=name:C:\\private",
    "PROC_MON_FILTER_RELOAD_EVENT_FILTER_PATTERNS=expand-collapse:false;invoke:true",
    "PROC_MON_FILTER_RELOAD_EVENT_FILTER_PATTERNS=expand-collapse:true;invoke:unknown",
    "PROC_MON_FILTER_RELOAD_MENU_KEYBOARD=route:event-filter;state:activated",
    "PROC_MON_FILTER_RELOAD_MENU_KEYBOARD=route:C:\\private;state:activated",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; reload-drop-main-foreground-gate=passed"
      + "; reload-filter-dialog-shortcut=sent"
      + "; reload-event-menu=opened"
      + "; reload-event-filter-patterns=expand-collapse:false;invoke:true"
      + "; reload-menu-keyboard=route:event-filter;state:activated",
  );
});

test("AC-05: Windows save-menu diagnostics retain bounded labels, not arbitrary text", () => {
  const output = [
    "PROC_MON_FILTER_MENU_ITEMS=before-save;count:11;truncated:true;items=MenuItem:Other:true:false:true,Other:Other:false:false:false,MenuItem:FilterCommand:true:false:true,MenuItem:Other:true:false:true,MenuItem:Other:true:false:true,MenuItem:SaveFilterCommand:true:false:true,MenuItem:Other:true:false:true,Other:Other:false:false:false",
    "PROC_MON_FILTER_MENU_ITEMS=before-save;count:1;truncated:false;items=MenuItem:C:\\private\\mail:true:false:true",
    "PROC_MON_FILTER_MENU_ITEMS=before-save;count:1;truncated:false;items=MenuItem:ExportConfigCommand:true:false:true",
    "PROC_MON_FILTER_MENU_ITEMS=before-save;unavailable",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; menu-items-before-save=count:11;truncated:true;items=MenuItem:Other:true:false:true,Other:Other:false:false:false,MenuItem:FilterCommand:true:false:true,MenuItem:Other:true:false:true,MenuItem:Other:true:false:true,MenuItem:SaveFilterCommand:true:false:true,MenuItem:Other:true:false:true,Other:Other:false:false:false"
      + "; menu-items-before-save=count:1;truncated:false;items=MenuItem:ExportConfigCommand:true:false:true"
      + "; menu-items-before-save=unavailable",
  );
});

test("AC-05: configuration save diagnostics expose only bounded control counts", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:2;file-names:0;save-buttons:1",
    ),
    "; config-save-dialog-scan=windows:2;file-names:0;save-buttons:1",
  );
  for (const line of [
    "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:20000;file-names:0;save-buttons:1",
    "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:2;file-names:C:\\private\\mail;save-buttons:1",
    "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:2;file-names:0;save-buttons:1;title:private",
  ]) {
    assert.equal(describeWindowsFilterDiagnostics(line), "");
  }
});

test("AC-05: Windows filter diagnostics retain only snapshot handoff state", () => {
  const output = [
    "PROC_MON_FILTER_FAILURE=InvalidOperationException",
    "PROC_MON_FILTER_SNAPSHOT=writer;element:present;control-type:menu",
    "PROC_MON_FILTER_SNAPSHOT=caller;element:missing;control-type:missing",
    "PROC_MON_FILTER_SNAPSHOT=caller;element:present;control-type:C:\\private\\mail",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; failure-type=InvalidOperationException"
      + "; focus-snapshot-writer=element:present;control-type:menu"
      + "; focus-snapshot-caller=element:missing;control-type:missing",
  );
});

test("AC-05: configuration file wait reports states without file paths or contents", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_CONFIG_FILE=observation:initial;state:missing",
      "PROC_MON_FILTER_CONFIG_FILE=observation:final;state:ready",
      "PROC_MON_FILTER_CONFIG_FILE=observation:final;state:C:\\private\\mail",
      "PROC_MON_FILTER_CONFIG_FILE=observation:final;state:ready;path:private",
    ].join("\n")),
    "; config-file-initial=missing; config-file-final=ready",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_CONFIG_FILE=observation:final;state:undersized",
    ),
    "; config-file-final=undersized",
  );
});

test("AC-05: reloaded Filter pointer diagnostics expose only verified bounded state", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:valid;point-match:true;input:sent",
    ),
    "; reload-menu-pointer=geometry:valid;point-match:true;input:sent",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:valid;point-match:false;input:sent",
    ),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:invalid;point-match:false;input:not-attempted",
    ),
    "; reload-menu-pointer=geometry:invalid;point-match:false;input:not-attempted",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:valid;point-match:true;input:unknown",
    ),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_POINTER=geometry:valid;point-match:true;input:sent;name=C:\\private",
    ),
    "",
  );
});

test("AC-05: configuration save observations expose states, not paths or dialog text", () => {
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FOCUS=gate:passed"),
    "; config-save-focus-gate=passed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FOCUS=gate:failed"),
    "; config-save-focus-gate=failed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FOREGROUND=gate:passed"),
    "; config-save-foreground-gate=passed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FOREGROUND=gate:failed"),
    "; config-save-foreground-gate=failed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FILENAME=gate:passed"),
    "; config-save-filename-gate=passed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FILENAME=gate:C:\\private"),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FINAL_FOREGROUND=gate:passed"),
    "; config-save-final-foreground-gate=passed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_SAVE_FINAL_FOREGROUND=gate:C:\\private"),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_RELOAD_MAIN_FOREGROUND=gate:passed"),
    "; reload-main-foreground-gate=passed",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_RELOAD_MAIN_FOREGROUND=gate:C:\\private"),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_RELOAD_MENU_PATTERN=invoke:true"),
    "; reload-menu-invoke-pattern=true",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_PATTERNS=expand-collapse:true;selection-item:false;legacy-ia:true;invoke:true",
    ),
    "; reload-menu-patterns=expand-collapse:true;selection-item:false;legacy-ia:true;invoke:true",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOAD_MENU_PATTERNS=expand-collapse:unknown;selection-item:false;legacy-ia:false;invoke:true",
      "PROC_MON_FILTER_RELOAD_MENU_PATTERNS=expand-collapse:true;selection-item:false;legacy-ia:false;invoke:true;name=C:\\private",
    ].join("\n")),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOAD_MENU_PATTERN=invoke:false",
      "PROC_MON_FILTER_RELOAD_MENU_PATTERN=invoke:unknown",
      "PROC_MON_FILTER_RELOAD_MENU_PATTERN=invoke:true;name=C:\\private",
      "PROC_MON_FILTER_RELOAD_MENU_KEY=gate:passed",
    ].join("\n")),
    "; reload-menu-invoke-pattern=false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:2;menus:1;visible:1",
    ),
    "; reload-menu-scan=windows:2;menus:1;visible:1",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:10000;menus:1;visible:1",
      "PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:2;menus:1;visible:2",
      "PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:2;menus:1;visible:1;name=C:\\private",
    ].join("\n")),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_PATH_FOREGROUND=gate:passed\nPROC_MON_FILTER_PATH_FOREGROUND=gate:failed\nPROC_MON_FILTER_PATH=gate:passed\nPROC_MON_FILTER_PATH=gate:passed",
    ),
    "; filter-path-foreground-gates=passed:1,failed:1; filter-path-input-gates=passed:2,failed:0",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_PATH=gate:C:\\private"),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_CONFIG_PATHS=canary:1;control:1",
    ),
    "; config-filter-paths=canary:1;control:1",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_CONFIG_PATHS=canary:C:\\private;control:1",
    ),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_SAVE_RESULT=phase:after-enter;foreground:procmon-main;same-process-dialogs:0;other-process-windows:0;buttons:save:0;cancel:0;yes:0;no:0;ok:0;retry:0;close:0;truncated:false",
    ),
    "; config-save-result-after-enter=foreground:procmon-main;same-process-dialogs:0;other-process-windows:0;buttons:save:0;cancel:0;yes:0;no:0;ok:0;retry:0;close:0;truncated:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_SAVE_RESULT=phase:after-wait;foreground:other-process;same-process-dialogs:1;other-process-windows:0;buttons:save:0;cancel:1;yes:1;no:1;ok:0;retry:0;close:0;truncated:false",
    ),
    "; config-save-result-after-wait=foreground:other-process;same-process-dialogs:1;other-process-windows:0;buttons:save:0;cancel:1;yes:1;no:1;ok:0;retry:0;close:0;truncated:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_SAVE_RESULT=phase:after-wait;foreground:C:\\private;same-process-dialogs:0;other-process-windows:0;buttons:save:0;cancel:0;yes:0;no:0;ok:0;retry:0;close:0;truncated:false",
    ),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_SAVE_FOCUS=gate:C:\\private\\mail",
      "PROC_MON_FILTER_SAVE_FOREGROUND=gate:C:\\private\\mail",
      "PROC_MON_FILTER_CONFIG_SAVE=after-invoke;dialog:available;enabled:true;offscreen:false;path:matches;save-enabled:true;save-offscreen:false;save-focusable:true;save-focused:true",
      "PROC_MON_FILTER_CONFIG_SAVE=focus-failed;dialog:available;enabled:true;offscreen:true;path:matches;save-enabled:true;save-offscreen:true;save-focusable:true;save-focused:false",
      "PROC_MON_FILTER_CONFIG_SAVE=foreground-failed;dialog:available;enabled:true;offscreen:false;path:matches;save-enabled:true;save-offscreen:false;save-focusable:true;save-focused:true",
      "PROC_MON_FILTER_CONFIG_SAVE=verify-failed;dialog:available;enabled:false;offscreen:false;path:different;save-enabled:false;save-offscreen:false;save-focusable:false;save-focused:false",
      "PROC_MON_FILTER_CONFIG_SAVE=verify-failed;dialog:unavailable",
      "PROC_MON_FILTER_CONFIG_SAVE=after-invoke;dialog:other-process",
      "PROC_MON_FILTER_CONFIG_SAVE=focus-failed;dialog:C:\\private\\mail",
      "PROC_MON_FILTER_CONFIG_SAVE=verify-failed;dialog:C:\\private\\mail",
      "PROC_MON_FILTER_CONFIG_SAVE=after-invoke;dialog:available;enabled:true;offscreen:false;path:C:\\private\\mail;save-enabled:true;save-offscreen:false;save-focusable:true;save-focused:true",
      "PROC_MON_FILTER_CONFIG_SAVE=verify-failed;dialog:unavailable;title:private",
    ].join("\n")),
    "; config-save-after-invoke=dialog:available;enabled:true;offscreen:false;path:matches;save-enabled:true;save-offscreen:false;save-focusable:true;save-focused:true"
      + "; config-save-focus-failed=dialog:available;enabled:true;offscreen:true;path:matches;save-enabled:true;save-offscreen:true;save-focusable:true;save-focused:false"
      + "; config-save-foreground-failed=dialog:available;enabled:true;offscreen:false;path:matches;save-enabled:true;save-offscreen:false;save-focusable:true;save-focused:true"
      + "; config-save-verify-failed=dialog:available;enabled:false;offscreen:false;path:different;save-enabled:false;save-offscreen:false;save-focusable:false;save-focused:false"
      + "; config-save-verify-failed=dialog:unavailable"
      + "; config-save-after-invoke=dialog:other-process",
  );
});

test("AC-05: Procmon export inventory retains bounded type and header classes only", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:before-save;target:missing;target-header:not-file;pmc-count:0;headers:empty:0;short:0;mz:0;xml:0;other:0;other-count:4;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-invoke;target:missing;target-header:not-file;pmc-count:1;headers:empty:0;short:0;mz:0;xml:1;other:0;other-count:4;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:ready;target-header:xml;pmc-count:1;headers:empty:0;short:0;mz:0;xml:0;other:1;other-count:4;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:C:\\private\\mail;target-header:xml;pmc-count:1;headers:empty:0;short:0;mz:0;xml:0;other:1;other-count:4;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:missing;target-header:other;pmc-count:99;headers:empty:0;short:0;mz:0;xml:0;other:0;other-count:0;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:missing;target-header:not-file;pmc-count:1;headers:empty:0;short:2;mz:0;xml:0;other:0;other-count:0;truncated:false",
      "PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:missing;target-header:not-file;pmc-count:1;headers:empty:0;short:0;mz:0;xml:0;other:0;other-count:0;truncated:false;path:private",
    ].join("\n")),
    "; config-output-before-save=target:missing;target-header:not-file;pmc-count:0;headers:empty:0;short:0;mz:0;xml:0;other:0;other-count:4;truncated:false"
      + "; config-output-after-invoke=target:missing;target-header:not-file;pmc-count:1;headers:empty:0;short:0;mz:0;xml:1;other:0;other-count:4;truncated:false"
      + "; config-output-after-wait=target:ready;target-header:xml;pmc-count:1;headers:empty:0;short:0;mz:0;xml:0;other:1;other-count:4;truncated:false",
  );
});

test("AC-05: Windows filter diagnostics omit unknown exception types", () => {
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_FAILURE=SecretException"),
    "",
  );
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_FAILURE=EntryPointNotFoundException"),
    "; failure-type=EntryPointNotFoundException",
  );
});

test("AC-05: Windows filter diagnostics retain only compiler error codes", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_COMPILE_ERROR=CS0234",
      "PROC_MON_FILTER_COMPILE_ERROR=CS99999",
      "PROC_MON_FILTER_COMPILE_ERROR=CS0234;C:\\private\\mail",
    ].join("\n")),
    "; filter-compile-error=CS0234",
  );
});

test("AC-05: Windows filter diagnostics retain bounded dialog scan counts", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_DIALOG_SCAN=process-windows:2;non-main-windows:1;reset-control:false",
    ),
    "; filter-dialog-scan=process-windows:2;non-main-windows:1;reset-control:false",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_DIALOG_SCAN=process-windows:20000;non-main-windows:1;reset-control:false",
    ),
    "",
  );
});

test("AC-05: Windows filter diagnostics retain safe dialog ownership state", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_DIALOG_DESKTOP_RESET_OWNER=other-process",
      "PROC_MON_FILTER_DIALOG_RESET_TREE=Button>Pane>Window",
      "PROC_MON_FILTER_FOCUS_OWNER=after-command-invoke;owner:other-process",
      "PROC_MON_FILTER_FOCUS_OWNER=after-command-invoke;owner:unavailable;reason:COMException",
      "PROC_MON_FILTER_FOCUS_OWNER=after-command-invoke;owner:other-process;reason:C:\\private\\mail",
      "PROC_MON_FILTER_FOCUS_OWNER=after-save-enter;owner:procmon-main",
      "PROC_MON_FILTER_FOCUS_OWNER=after-save-enter;owner:procmon-other",
      "PROC_MON_FILTER_FOCUS_OWNER=after-save-enter;owner:other-process",
      "PROC_MON_FILTER_FOCUS_OWNER=after-save-enter;owner:C:\\private\\mail",
    ].join("\n")),
    "; filter-dialog-desktop-reset-owner=other-process"
      + "; filter-dialog-reset-tree=Button>Pane>Window"
      + "; focus-owner-after-command-invoke=other-process"
      + "; focus-owner-after-command-invoke=unavailable;reason:COMException"
      + "; focus-owner-after-save-enter=procmon-main"
      + "; focus-owner-after-save-enter=procmon-other"
      + "; focus-owner-after-save-enter=other-process",
  );
});

test("AC-05: Windows filter diagnostics retain bounded command match counts", () => {
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_COMMAND_MATCH=items:11;matches:1",
    ),
    "; filter-command-match=items:11;matches:1",
  );
  assert.equal(
    describeWindowsFilterDiagnostics(
      "PROC_MON_FILTER_COMMAND_MATCH=items:10000;matches:1",
    ),
    "",
  );
});

test("AC-05: Windows filter diagnostics reject unsafe Drop menu values", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_DROP_MENU_STATE=owner-same-process:true;enabled:yes;offscreen:false",
      "PROC_MON_FILTER_DROP_MENU_MATCH=items:10000;matches:1",
      "PROC_MON_FILTER_DROP_MENU_MATCH=items:11;matches:C:\\private\\mail",
    ].join("\n")),
    "",
  );
});

test("AC-05: Windows filter diagnostics reject unknown Drop item patterns", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_DROP_PATTERN=toggle:true;private-value",
      "PROC_MON_FILTER_DROP_PATTERN=legacy-accessible:true",
      "PROC_MON_FILTER_DROP_PATTERN=invoke:unknown",
      "PROC_MON_FILTER_DROP_ITEM_STATE=enabled:true;offscreen:false;keyboard-focusable:true;item-status:checked;help-text:C:\\private\\mail",
      "PROC_MON_FILTER_DROP_ITEM_BACKEND=framework:C:\\private\\mail;native-window-handle:true;menu-window-handle:true",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:main;menu-window-process:unavailable;gui-thread-info:unavailable;owner-window:unavailable;handle:available;items:1000;matches:1;read-failure:none;readable:true;checked:off",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:1;matches:1;read-failure:none;readable:true;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:private;source:main;menu-window-process:unavailable;gui-thread-info:unavailable;owner-window:unavailable;handle:available;items:1;matches:1;read-failure:none;readable:true;checked:on",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:true;items:19;matches:1;read-failure:none;readable:true;checked:off",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-window;menu-window-process:other;gui-thread-info:available;owner-window:available;handle:available;items:19;matches:1;read-failure:none;readable:true;checked:off",
    ].join("\n")),
    "",
  );
});

test("AC-05: Windows native menu diagnostics retain safe owner fallback and unavailable state", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:unavailable;menu-window-process:same;gui-thread-info:unavailable;owner-window:unavailable;handle:unavailable;items:0;matches:0;read-failure:none;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:off",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-window;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:off",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:other;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:off",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:item-read-failed;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:2;matches:0;read-failure:none;readable:true;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:owner-drawn;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:invalid-menu-handle;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:menu-count-invalid;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:menu-count-failed;readable:false;checked:unavailable",
      "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:after-reload;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:on",
    ].join("\n")),
    "; drop-native-menu-state=observation:before;source:unavailable;menu-window-process:same;gui-thread-info:unavailable;owner-window:unavailable;handle:unavailable;items:0;matches:0;read-failure:none;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:off"
      + "; drop-native-menu-state=observation:before;source:menu-window;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:off"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:item-read-failed;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:2;matches:0;read-failure:none;readable:true;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:owner-drawn;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:invalid-menu-handle;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:menu-count-invalid;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:before;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:0;matches:0;read-failure:menu-count-failed;readable:false;checked:unavailable"
      + "; drop-native-menu-state=observation:after-reload;source:menu-owner;menu-window-process:same;gui-thread-info:available;owner-window:available;handle:available;items:11;matches:1;read-failure:none;readable:true;checked:on",
  );
});

test("AC-05: Windows MSAA diagnostics retain only exact, same-process menu state", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:11;matches:1;read-failure:none;checked:off",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:after-invoke;process:same;object:available;items:11;matches:1;read-failure:none;checked:on",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:11;matches:0;read-failure:no-match;checked:unavailable",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:unavailable;object:unavailable;items:0;matches:0;read-failure:window-unavailable;checked:unavailable",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:after-invoke;process:unavailable;object:unavailable;items:0;matches:0;read-failure:window-unavailable;checked:unavailable",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:after-reload;process:same;object:available;items:11;matches:1;read-failure:none;checked:on",
    ].join("\n")),
    "; drop-msaa-menu-state=observation:before;process:same;object:available;items:11;matches:1;read-failure:none;checked:off"
      + "; drop-msaa-menu-state=observation:after-invoke;process:same;object:available;items:11;matches:1;read-failure:none;checked:on"
      + "; drop-msaa-menu-state=observation:before;process:same;object:available;items:11;matches:0;read-failure:no-match;checked:unavailable"
      + "; drop-msaa-menu-state=observation:before;process:unavailable;object:unavailable;items:0;matches:0;read-failure:window-unavailable;checked:unavailable"
      + "; drop-msaa-menu-state=observation:after-invoke;process:unavailable;object:unavailable;items:0;matches:0;read-failure:window-unavailable;checked:unavailable"
      + "; drop-msaa-menu-state=observation:after-reload;process:same;object:available;items:11;matches:1;read-failure:none;checked:on",
  );
});

test("AC-05: Windows MSAA diagnostics reject inconsistent or unsafe state", () => {
  assert.equal(
    describeWindowsFilterDiagnostics([
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:other;object:available;items:11;matches:1;read-failure:none;checked:off",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:unavailable;items:0;matches:0;read-failure:none;checked:unavailable",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:65;matches:1;read-failure:none;checked:off",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:11;matches:2;read-failure:none;checked:on",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:11;matches:1;read-failure:duplicate-match;checked:off",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:private;process:same;object:available;items:11;matches:1;read-failure:none;checked:on",
      "PROC_MON_FILTER_MSAA_MENU_STATE=observation:before;process:same;object:available;items:11;matches:1;read-failure:none;checked:C:\\private\\mail",
    ].join("\n")),
    "",
  );
});

test("AC-05: Windows filter output retains diagnostics within a strict 8192-character cap", () => {
  const prefix = "x".repeat(3000);
  const snapshot = "PROC_MON_FILTER_SNAPSHOT=caller;element:present;control-type:menu";
  const captured = appendBoundedWindowsFilterOutput(prefix, snapshot);
  assert.equal(captured, `${prefix}${snapshot}`);
  assert.equal(captured.length, prefix.length + snapshot.length);

  const bounded = appendBoundedWindowsFilterOutput(captured, "y".repeat(10_000));
  assert.equal(windowsFilterOutputLimit, 8192);
  assert.equal(bounded.length, windowsFilterOutputLimit);
  assert.ok(bounded.startsWith(prefix));
  assert.ok(bounded.includes("PROC_MON_FILTER_OUTPUT_TRUNCATED=true"));
  assert.ok(bounded.endsWith("y".repeat(100)));
  assert.ok(
    appendBoundedWindowsFilterOutput(bounded, "extra").endsWith("extra"),
  );
});
