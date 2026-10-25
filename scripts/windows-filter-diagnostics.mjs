const allowedTypes = /^(?:MenuBar|MenuItem|Window|Pane|ToolBar|Other)$/;
const allowedNames = /^(?:Filter|MenuBar|ProcessMonitor|Other)$/;

export function describeWindowsFilterDiagnostics(output) {
  const diagnostics = [];
  const state = output.match(
    /PROC_MON_FILTER_MENU_STATE=(enabled:(?:true|false);offscreen:(?:true|false);keyboard-focusable:(?:true|false))/,
  )?.[1];
  if (state) diagnostics.push(`menu-state=${state}`);

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
    /PROC_MON_FILTER_MENU_FOCUS=(returned|failed-(?:ElementNotEnabledException|ElementNotAvailableException|InvalidOperationException|COMException|NoClickablePointException|Other))/,
  )?.[1];
  if (focus) diagnostics.push(`menu-focus=${focus}`);
  return diagnostics.length > 0 ? `; ${diagnostics.join("; ")}` : "";
}
