import assert from "node:assert/strict";
import test from "node:test";
import {
  appendBoundedWindowsFilterOutput,
  describeWindowsFilterDiagnostics,
} from "../../scripts/windows-filter-diagnostics.mjs";

test("AC-05: Windows filter diagnostics retain only allowlisted UIA state", () => {
  const output = [
    "PROC_MON_FILTER_MENU_STATE=enabled:true;offscreen:false;keyboard-focusable:true",
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:true;invoke:false",
    "PROC_MON_FILTER_COMMAND_PATTERNS=invoke:true;selection-item:false",
    "PROC_MON_FILTER_MENU_TREE=MenuItem:Filter>MenuBar:MenuBar>Window:ProcessMonitor",
    "PROC_MON_FILTER_MENU_FOCUS=failed-COMException",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; menu-state=enabled:true;offscreen:false;keyboard-focusable:true"
      + "; menu-patterns=expand-collapse:true;invoke:false"
      + "; filter-command-patterns=invoke:true;selection-item:false"
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
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; focus-after-open=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other>Window:ProcessMonitor"
      + "; menu-items-after-open=count:2;truncated:false;items=MenuItem:FilterCommand:true:false:false,MenuItem:DropFilteredEvents:true:false:false"
      + "; focus-filter-command=MenuItem:FilterCommand;offscreen:false;keyboard-focusable:true;tree=MenuItem:FilterCommand>Menu:Other"
      + "; focus-after-enter=none"
      + "; focus-after-invoke=Window:ProcessMonitor;offscreen:false;keyboard-focusable:false;tree=Window:ProcessMonitor",
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

test("AC-05: Windows filter output retains diagnostics within a strict 4096-character cap", () => {
  const prefix = "x".repeat(3000);
  const snapshot = "PROC_MON_FILTER_SNAPSHOT=caller;element:present;control-type:menu";
  const captured = appendBoundedWindowsFilterOutput(prefix, snapshot);
  assert.equal(captured, `${prefix}${snapshot}`);
  assert.equal(captured.length, prefix.length + snapshot.length);

  const bounded = appendBoundedWindowsFilterOutput(captured, "y".repeat(5000));
  assert.equal(bounded.length, 4096);
  assert.equal(bounded.slice(0, captured.length), captured);
  assert.equal(appendBoundedWindowsFilterOutput(bounded, "extra"), bounded);
});
