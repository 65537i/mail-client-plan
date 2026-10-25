import assert from "node:assert/strict";
import test from "node:test";
import { describeWindowsFilterDiagnostics } from "../../scripts/windows-filter-diagnostics.mjs";

test("AC-05: Windows filter diagnostics retain only allowlisted UIA state", () => {
  const output = [
    "PROC_MON_FILTER_MENU_STATE=enabled:true;offscreen:false;keyboard-focusable:true",
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:true;invoke:false",
    "PROC_MON_FILTER_MENU_TREE=MenuItem:Filter>MenuBar:MenuBar>Window:ProcessMonitor",
    "PROC_MON_FILTER_MENU_FOCUS=failed-COMException",
  ].join("\n");
  assert.equal(
    describeWindowsFilterDiagnostics(output),
    "; menu-state=enabled:true;offscreen:false;keyboard-focusable:true"
      + "; menu-patterns=expand-collapse:true;invoke:false"
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
