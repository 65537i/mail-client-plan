import assert from "node:assert/strict";
import test from "node:test";
import {
  appendBoundedWindowsFilterOutput,
  describeWindowsFilterDiagnostics,
  windowsFilterOutputLimit,
} from "../../scripts/windows-filter-diagnostics.mjs";

test("AC-05: Windows filter diagnostics retain only allowlisted UIA state", () => {
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
    "PROC_MON_FILTER_DROP_ITEM_STATE=keyboard-focusable:true;item-status:off;help-text:other",
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
      + "; drop-filter-item-state=keyboard-focusable:true;item-status:off;help-text:other"
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
    "PROC_MON_FILTER_MENU_ITEMS=after-home;count:1;truncated:false;items=MenuItem:C:\\private\\mail:true:false:true",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-home;type:Text;name:C:\\private\\mail;offscreen:false;keyboard-focusable:true;tree=Text:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=filter-command;type:MenuItem;name:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-enter;focused:none",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-invoke;type:Window;name:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
    "PROC_MON_FILTER_FOCUSED_CONTROL=after-command-invoke;type:Window;name:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; focus-after-open=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other>Window:ProcessMonitor"
      + "; menu-items-after-open=count:2;truncated:false;items=MenuItem:FilterCommand:true:false:false,MenuItem:DropFilteredEvents:true:false:false"
      + "; focus-filter-command=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other"
      + "; focus-after-enter=none"
      + "; focus-after-invoke=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor"
      + "; focus-after-command-invoke=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
  );
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

test("AC-05: Windows filter diagnostics omit unknown exception types", () => {
  assert.equal(
    describeWindowsFilterDiagnostics("PROC_MON_FILTER_FAILURE=SecretException"),
    "",
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
    ].join("\n")),
    "; filter-dialog-desktop-reset-owner=other-process"
      + "; filter-dialog-reset-tree=Button>Pane>Window"
      + "; focus-owner-after-command-invoke=other-process"
      + "; focus-owner-after-command-invoke=unavailable;reason:COMException",
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
      "PROC_MON_FILTER_DROP_ITEM_STATE=keyboard-focusable:true;item-status:checked;help-text:C:\\private\\mail",
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
  assert.equal(bounded.slice(0, captured.length), captured);
  assert.equal(appendBoundedWindowsFilterOutput(bounded, "extra"), bounded);
});
