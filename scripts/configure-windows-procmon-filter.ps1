param(
  [Parameter(Mandatory = $true)][string]$ProcmonPath,
  [Parameter(Mandatory = $true)][string]$CanaryPath,
  [Parameter(Mandatory = $true)][string]$ControlPath,
  [Parameter(Mandatory = $true)][string]$ConfigPath,
  [ValidateRange(1, 2147483647)][int]$CaptureProcessId
)

$ErrorActionPreference = "Stop"
function Write-StartupFailure([string]$FailedStage, $Failure) {
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILED_STAGE=$FailedStage")
  $failureType = $Failure.Exception.GetType().Name
  if ($failureType -notin @(
      "ArgumentException",
      "BadImageFormatException",
      "FileLoadException",
      "FileNotFoundException",
      "InvalidOperationException",
      "MethodInvocationException",
      "TypeInitializationException"
    )) {
    $failureType = "Other"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILURE=$failureType")
  if ($FailedStage -eq "compile-native-menu-helper") {
    $compileCode = [regex]::Match(
      $Failure.ToString(),
      "\bCS\d{4}\b"
    ).Value
    if ($compileCode -match "^CS\d{4}$") {
      [Console]::Out.WriteLine("PROC_MON_FILTER_COMPILE_ERROR=$compileCode")
    }
  }
}

try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName System.Windows.Forms
} catch {
  Write-StartupFailure "load-automation-assemblies" $_
  exit 1
}

try {
  Add-Type -AssemblyName Accessibility
} catch {
  Write-StartupFailure "load-msaa-assembly" $_
  exit 1
}

try {
  $nativeMenuTypeDefinition = @"
using System;
using System.Runtime.InteropServices;

public static class ProcmonNativeMenu
{
    private const uint MIIM_STATE = 0x00000001;
    private const uint MIIM_SUBMENU = 0x00000004;
    private const uint MIIM_STRING = 0x00000040;
    private const uint MIIM_FTYPE = 0x00000100;
    private const uint MFS_CHECKED = 0x00000008;
    private const uint MFS_HILITE = 0x00000080;
    private const uint MFS_DISABLED = 0x00000003;
    private const uint MFT_OWNERDRAW = 0x00000100;
    private const uint GUI_INMENUMODE = 0x00000004;
    private const uint GUI_POPUPMENUMODE = 0x00000010;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x00000002;
    private const uint WM_GETTEXT = 0x000D;
    private const uint WM_GETTEXTLENGTH = 0x000E;
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_COMMAND = 0x0111;
    private const uint CBN_SELCHANGE = 1;
    private const uint CB_GETCOUNT = 0x0146;
    private const uint CB_GETCURSEL = 0x0147;
    private const uint CB_SETCURSEL = 0x014E;
    private const uint CB_FINDSTRINGEXACT = 0x0158;
    private const uint BM_CLICK = 0x00F5;
    private const uint LVM_GETITEMCOUNT = 0x1004;
    private const uint LVM_GETHEADER = 0x101F;
    private const uint LVM_GETITEMTEXTW = 0x1073;
    private const uint HDM_GETITEMCOUNT = 0x1200;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint NativeControlMessageTimeout = 1000;
    private const uint LVIF_TEXT = 0x0001;
    private const uint ProcessVmOperation = 0x0008;
    private const uint ProcessVmRead = 0x0010;
    private const uint ProcessVmWrite = 0x0020;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint MemCommitReserve = 0x3000;
    private const uint MemRelease = 0x8000;
    private const uint PageReadWrite = 0x04;
    private const ushort VK_CONTROL = 0x0011;
    private const ushort VK_L = 0x004C;
    private const uint GA_ROOT = 2;
    private const int AccessibleMenuObjectId = -3;
    private const int AccessibleClientObjectId = -4;
    private const uint MaximumTextCharacters = 255;
    private const int MaximumAccessibleMenuItems = 64;
    private const int MenuItemRole = 12;
    private const int CheckedState = 0x10;
    private const int MixedState = 0x20;
    private const int UnavailableState = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct MenuItemInfo
    {
        public uint cbSize;
        public uint fMask;
        public uint fType;
        public uint fState;
        public uint wID;
        public IntPtr hSubMenu;
        public IntPtr hbmpChecked;
        public IntPtr hbmpUnchecked;
        public IntPtr dwItemData;
        public IntPtr dwTypeData;
        public uint cch;
        public IntPtr hbmpItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public Rect rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MouseInput Mouse;

        [FieldOffset(0)]
        public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeListViewItem
    {
        public uint Mask;
        public int Item;
        public int SubItem;
        public uint State;
        public uint StateMask;
        public IntPtr Text;
        public int TextMax;
        public int Image;
        public IntPtr Parameter;
        public int Indent;
        public int GroupId;
        public uint ColumnCount;
        public IntPtr Columns;
        public IntPtr ColumnFormats;
        public int Group;
    }

    public sealed class ItemSnapshot
    {
        public string Text { get; set; }
        public bool IsChecked { get; set; }
        public bool IsHighlighted { get; set; }
        public bool IsEnabled { get; set; }
        public IntPtr Submenu { get; set; }
    }

    public sealed class AccessibleMenuSnapshot
    {
        public bool ProcessKnown { get; set; }
        public bool ProcessSame { get; set; }
        public bool AccessibleAvailable { get; set; }
        public int ItemCount { get; set; }
        public int MatchCount { get; set; }
        public int EventCount { get; set; }
        public int FilterCount { get; set; }
        public int FilterCommandCount { get; set; }
        public string ReadFailure { get; set; }
        public string CheckState { get; set; }
        public bool IsEnabled { get; set; }
    }

    public sealed class FocusSnapshot
    {
        public bool Available { get; set; }
        public IntPtr ActiveWindow { get; set; }
        public IntPtr FocusWindow { get; set; }
    }

    public sealed class ShortcutInputSnapshot
    {
        public string State { get; set; }
        public uint Events { get; set; }
        public uint ReleaseEvents { get; set; }
    }

    public sealed class NativeChildSnapshot
    {
        public string State { get; set; }
        public NativeChildWindowSnapshot[] ChildWindows { get; set; }
        public int Windows { get; set; }
        public int Combos { get; set; }
        public int Edits { get; set; }
        public int Buttons { get; set; }
        public int Dialogs { get; set; }
        public int Toolbars { get; set; }
        public int Lists { get; set; }
        public int Statics { get; set; }
        public int Other { get; set; }
        public int Unreadable { get; set; }
        public bool Truncated { get; set; }
    }

    public sealed class NativeChildWindowSnapshot
    {
        public IntPtr Handle { get; set; }
        public string Kind { get; set; }
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetMenu(IntPtr hWnd);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(
        IntPtr parent,
        EnumWindowsProc callback,
        IntPtr parameter
    );

    [DllImport(
        "user32.dll",
        EntryPoint = "GetClassNameW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true
    )]
    private static extern int GetClassName(
        IntPtr window,
        System.Text.StringBuilder className,
        int maximum
    );

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr GetParent(IntPtr window);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern int GetDlgCtrlID(IntPtr window);

    [DllImport(
        "user32.dll",
        EntryPoint = "SendMessageTimeoutW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true
    )]
    private static extern IntPtr SendMessageTimeoutRaw(
        IntPtr window,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result
    );

    [DllImport(
        "user32.dll",
        EntryPoint = "SendMessageTimeoutW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true
    )]
    private static extern IntPtr SendMessageTimeoutText(
        IntPtr window,
        uint message,
        IntPtr wParam,
        System.Text.StringBuilder lParam,
        uint flags,
        uint timeout,
        out IntPtr result
    );

    [DllImport(
        "user32.dll",
        EntryPoint = "SendMessageTimeoutW",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true
    )]
    private static extern IntPtr SendMessageTimeoutString(
        IntPtr window,
        uint message,
        IntPtr wParam,
        [MarshalAs(UnmanagedType.LPWStr)] string lParam,
        uint flags,
        uint timeout,
        out IntPtr result
    );

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId
    );

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(
        IntPtr process,
        IntPtr address,
        UIntPtr size,
        uint allocationType,
        uint protection
    );

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool VirtualFreeEx(
        IntPtr process,
        IntPtr address,
        UIntPtr size,
        uint freeType
    );

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteProcessMemory(
        IntPtr process,
        IntPtr address,
        byte[] buffer,
        UIntPtr size,
        out UIntPtr written
    );

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadProcessMemory(
        IntPtr process,
        IntPtr address,
        byte[] buffer,
        UIntPtr size,
        out UIntPtr read
    );

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint SendInput(
        uint inputCount,
        NativeInput[] inputs,
        int inputSize
    );

    public static int GetWindowProcessId(IntPtr hWnd)
    {
        uint processId;
        return GetWindowThreadProcessId(hWnd, out processId) == 0
            ? 0
            : processId > int.MaxValue ? 0 : (int)processId;
    }

    private static NativeInput CreateKeyboardInput(ushort virtualKey, uint flags)
    {
        return new NativeInput
        {
            Type = INPUT_KEYBOARD,
            Data = new InputUnion
            {
                Keyboard = new KeyboardInput
                {
                    VirtualKey = virtualKey,
                    ScanCode = 0,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    public static ShortcutInputSnapshot SendControlLShortcut(
        IntPtr expectedWindow,
        int expectedProcessId
    )
    {
        if (
            expectedWindow == IntPtr.Zero ||
            expectedProcessId <= 0 ||
            GetForegroundWindow() != expectedWindow ||
            GetWindowProcessId(expectedWindow) != expectedProcessId
        )
        {
            return new ShortcutInputSnapshot
            {
                State = "target-mismatch",
                Events = 0,
                ReleaseEvents = 0
            };
        }

        var inputs = new[]
        {
            CreateKeyboardInput(VK_CONTROL, 0),
            CreateKeyboardInput(VK_L, 0),
            CreateKeyboardInput(VK_L, KEYEVENTF_KEYUP),
            CreateKeyboardInput(VK_CONTROL, KEYEVENTF_KEYUP)
        };
        var inserted = SendInput(
            (uint)inputs.Length,
            inputs,
            Marshal.SizeOf(typeof(NativeInput))
        );
        if (inserted != (uint)inputs.Length)
        {
            var releaseInputs = new[]
            {
                CreateKeyboardInput(VK_L, KEYEVENTF_KEYUP),
                CreateKeyboardInput(VK_CONTROL, KEYEVENTF_KEYUP)
            };
            var released = SendInput(
                (uint)releaseInputs.Length,
                releaseInputs,
                Marshal.SizeOf(typeof(NativeInput))
            );
            return new ShortcutInputSnapshot
            {
                State = "incomplete",
                Events = inserted,
                ReleaseEvents = released
            };
        }
        return new ShortcutInputSnapshot
        {
            State = "sent",
            Events = inserted,
            ReleaseEvents = 0
        };
    }

    public static NativeChildSnapshot ReadNativeChildSummary(
        IntPtr root,
        int expectedProcessId,
        int maximum
    )
    {
        var snapshot = new NativeChildSnapshot
        {
            State = "root-mismatch",
            ChildWindows = new NativeChildWindowSnapshot[0],
            Truncated = false
        };
        if (root == IntPtr.Zero || expectedProcessId <= 0 || maximum < 1 || maximum > 256)
            throw new ArgumentOutOfRangeException();
        uint rootProcessId;
        if (
            GetWindowThreadProcessId(root, out rootProcessId) == 0 ||
            rootProcessId != (uint)expectedProcessId
        )
        {
            return snapshot;
        }

        var seen = new System.Collections.Generic.HashSet<IntPtr>();
        var childWindows = new System.Collections.Generic.List<NativeChildWindowSnapshot>();
        var readFailed = false;
        EnumWindowsProc callback = delegate(IntPtr window, IntPtr parameter)
        {
            if (snapshot.Windows >= maximum)
            {
                snapshot.Truncated = true;
                return false;
            }
            if (!seen.Add(window))
            {
                readFailed = true;
                return false;
            }
            snapshot.Windows++;
            uint childProcessId;
            if (
                GetWindowThreadProcessId(window, out childProcessId) == 0 ||
                childProcessId != (uint)expectedProcessId
            )
            {
                snapshot.Unreadable++;
                readFailed = true;
                return true;
            }
            var className = new System.Text.StringBuilder(128);
            if (GetClassName(window, className, className.Capacity) == 0)
            {
                snapshot.Unreadable++;
                readFailed = true;
                return true;
            }
            string kind;
            switch (className.ToString())
            {
                case "ComboBox":
                case "ComboBoxEx32":
                    kind = "combo";
                    snapshot.Combos++;
                    break;
                case "Edit":
                    kind = "edit";
                    snapshot.Edits++;
                    break;
                case "Button":
                    kind = "button";
                    snapshot.Buttons++;
                    break;
                case "#32770":
                    kind = "dialog";
                    snapshot.Dialogs++;
                    break;
                case "ToolbarWindow32":
                    kind = "toolbar";
                    snapshot.Toolbars++;
                    break;
                case "SysListView32":
                    kind = "list";
                    snapshot.Lists++;
                    break;
                case "Static":
                    kind = "static";
                    snapshot.Statics++;
                    break;
                default:
                    kind = "other";
                    snapshot.Other++;
                    break;
            }
            childWindows.Add(new NativeChildWindowSnapshot
            {
                Handle = window,
                Kind = kind
            });
            return true;
        };
        var enumerationSucceeded = EnumChildWindows(root, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        if (!enumerationSucceeded && !snapshot.Truncated)
        {
            readFailed = true;
        }
        uint verifiedRootProcessId;
        if (
            GetWindowThreadProcessId(root, out verifiedRootProcessId) == 0 ||
            verifiedRootProcessId != (uint)expectedProcessId
        )
        {
            readFailed = true;
        }
        snapshot.ChildWindows = childWindows.ToArray();
        snapshot.State = readFailed
            ? "partial"
            : snapshot.Truncated ? "truncated" : "ready";
        return snapshot;
    }

    private static void VerifyNativeControl(
        IntPtr window,
        int expectedProcessId,
        string expectedKind
    )
    {
        uint processId;
        if (
            window == IntPtr.Zero ||
            expectedProcessId <= 0 ||
            !IsWindow(window) ||
            !IsWindowVisible(window) ||
            !IsWindowEnabled(window) ||
            GetWindowThreadProcessId(window, out processId) == 0 ||
            processId != (uint)expectedProcessId
        )
        {
            throw new InvalidOperationException("Native control ownership is unavailable");
        }
        var className = new System.Text.StringBuilder(128);
        if (GetClassName(window, className, className.Capacity) == 0)
        {
            throw new InvalidOperationException("Native control class is unavailable");
        }
        var actualClassName = className.ToString();
        var classMatches =
            (expectedKind == "combo" &&
                (actualClassName == "ComboBox" || actualClassName == "ComboBoxEx32")) ||
            (expectedKind == "edit" && actualClassName == "Edit") ||
            (expectedKind == "button" && actualClassName == "Button") ||
            (expectedKind == "list" && actualClassName == "SysListView32");
        if (!classMatches)
        {
            throw new InvalidOperationException("Native control class did not match its expected kind");
        }
    }

    private static string NormalizeNativeButtonLabel(string value)
    {
        return (value ?? string.Empty).Replace("&", string.Empty).Trim();
    }

    public static string ReadNativeControlText(
        IntPtr window,
        int expectedProcessId,
        string expectedKind,
        int maximumCharacters
    )
    {
        if (maximumCharacters < 1 || maximumCharacters > 1024)
            throw new ArgumentOutOfRangeException();
        VerifyNativeControl(window, expectedProcessId, expectedKind);
        IntPtr lengthResult;
        if (
            SendMessageTimeoutRaw(
                window,
                WM_GETTEXTLENGTH,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out lengthResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native control text length could not be read");
        }
        var textLength = lengthResult.ToInt32();
        if (textLength < 0 || textLength > maximumCharacters)
            throw new InvalidOperationException("Native control text exceeded its bound");
        var text = new System.Text.StringBuilder(textLength + 1);
        IntPtr copiedLength;
        if (
            SendMessageTimeoutText(
                window,
                WM_GETTEXT,
                new IntPtr(text.Capacity),
                text,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out copiedLength
            ) == IntPtr.Zero ||
            copiedLength.ToInt32() != textLength
        )
        {
            throw new InvalidOperationException("Native control text could not be read consistently");
        }
        VerifyNativeControl(window, expectedProcessId, expectedKind);
        return text.ToString();
    }

    public static int FindNativeComboItemExact(
        IntPtr window,
        int expectedProcessId,
        string value
    )
    {
        return FindNativeComboItemExactStartingAt(window, expectedProcessId, value, -1);
    }

    private static int FindNativeComboItemExactStartingAt(
        IntPtr window,
        int expectedProcessId,
        string value,
        int startAfter
    )
    {
        if (string.IsNullOrEmpty(value) || value.Length > 128 || value.IndexOf('\0') >= 0)
            throw new ArgumentException("Native combo lookup value is invalid");
        if (startAfter < -1 || startAfter > 255)
            throw new ArgumentOutOfRangeException();
        VerifyNativeControl(window, expectedProcessId, "combo");
        IntPtr indexResult;
        if (
            SendMessageTimeoutString(
                window,
                CB_FINDSTRINGEXACT,
                new IntPtr(startAfter),
                value,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out indexResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native combo option lookup failed");
        }
        VerifyNativeControl(window, expectedProcessId, "combo");
        var index = indexResult.ToInt32();
        if (index < -1 || index > 255)
            throw new InvalidOperationException("Native combo option index exceeded its bound");
        return index;
    }

    public static int CountNativeComboItemExact(
        IntPtr window,
        int expectedProcessId,
        string value
    )
    {
        var first = FindNativeComboItemExactStartingAt(window, expectedProcessId, value, -1);
        if (first < 0)
            return 0;
        var second = FindNativeComboItemExactStartingAt(window, expectedProcessId, value, first);
        return second < 0 || second == first ? 1 : 2;
    }

    public static void SelectNativeComboItemExact(
        IntPtr window,
        int expectedProcessId,
        string value
    )
    {
        if (CountNativeComboItemExact(window, expectedProcessId, value) != 1)
            throw new InvalidOperationException("Native combo option was not unique");
        var index = FindNativeComboItemExact(window, expectedProcessId, value);
        IntPtr selectionResult;
        if (
            SendMessageTimeoutRaw(
                window,
                CB_SETCURSEL,
                new IntPtr(index),
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out selectionResult
            ) == IntPtr.Zero ||
            selectionResult.ToInt32() != index
        )
        {
            throw new InvalidOperationException("Native combo selection failed");
        }
        var parent = GetParent(window);
        var controlId = GetDlgCtrlID(window);
        uint parentProcessId;
        if (
            parent == IntPtr.Zero ||
            controlId < 0 ||
            controlId > ushort.MaxValue ||
            GetWindowThreadProcessId(parent, out parentProcessId) == 0 ||
            parentProcessId != (uint)expectedProcessId
        )
        {
            throw new InvalidOperationException("Native combo parent ownership is unavailable");
        }
        var command = unchecked((int)(((uint)controlId << 16) | CBN_SELCHANGE));
        IntPtr notificationResult;
        if (
            SendMessageTimeoutRaw(
                parent,
                WM_COMMAND,
                new IntPtr(command),
                window,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out notificationResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native combo selection notification failed");
        }
        VerifyNativeControl(window, expectedProcessId, "combo");
        IntPtr currentSelection;
        if (
            SendMessageTimeoutRaw(
                window,
                CB_GETCURSEL,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out currentSelection
            ) == IntPtr.Zero ||
            currentSelection.ToInt32() != index ||
            ReadNativeControlText(window, expectedProcessId, "combo", 256) != value
        )
        {
            throw new InvalidOperationException("Native combo selection readback failed");
        }
    }

    public static int ReadNativeComboItemCount(IntPtr window, int expectedProcessId)
    {
        VerifyNativeControl(window, expectedProcessId, "combo");
        IntPtr countResult;
        if (
            SendMessageTimeoutRaw(
                window,
                CB_GETCOUNT,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out countResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native combo item count could not be read");
        }
        VerifyNativeControl(window, expectedProcessId, "combo");
        var count = countResult.ToInt32();
        if (count < 0 || count > 256)
            throw new InvalidOperationException("Native combo item count exceeded its bound");
        return count;
    }

    public static void SetNativeEditTextExact(
        IntPtr window,
        int expectedProcessId,
        string value
    )
    {
        if (
            string.IsNullOrEmpty(value) ||
            value.Length > 1024 ||
            value.IndexOf('\0') >= 0
        )
        {
            throw new ArgumentException("Native edit value is invalid");
        }
        VerifyNativeControl(window, expectedProcessId, "edit");
        IntPtr setResult;
        if (
            SendMessageTimeoutString(
                window,
                WM_SETTEXT,
                IntPtr.Zero,
                value,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out setResult
            ) == IntPtr.Zero ||
            setResult == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native edit value could not be set");
        }
        VerifyNativeControl(window, expectedProcessId, "edit");
        if (!string.Equals(
            ReadNativeControlText(window, expectedProcessId, "edit", 1024),
            value,
            StringComparison.Ordinal
        ))
        {
            throw new InvalidOperationException("Native edit value readback did not match");
        }
    }

    public static void ClickNativeButtonExact(
        IntPtr window,
        int expectedProcessId,
        string expectedText
    )
    {
        if (string.IsNullOrEmpty(expectedText) || expectedText.Length > 128)
            throw new ArgumentException("Native button label is invalid");
        VerifyNativeControl(window, expectedProcessId, "button");
        if (
            !string.Equals(
                NormalizeNativeButtonLabel(
                    ReadNativeControlText(window, expectedProcessId, "button", 128)
                ),
                NormalizeNativeButtonLabel(expectedText),
                StringComparison.OrdinalIgnoreCase
            )
        )
        {
            throw new InvalidOperationException("Native button label did not match");
        }
        IntPtr clickResult;
        if (
            SendMessageTimeoutRaw(
                window,
                BM_CLICK,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out clickResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native button activation failed");
        }
    }

    public static int ReadNativeListItemCount(IntPtr window, int expectedProcessId)
    {
        VerifyNativeControl(window, expectedProcessId, "list");
        IntPtr countResult;
        if (
            SendMessageTimeoutRaw(
                window,
                LVM_GETITEMCOUNT,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out countResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native list item count could not be read");
        }
        VerifyNativeControl(window, expectedProcessId, "list");
        var count = countResult.ToInt32();
        if (count < 0 || count > 64)
            throw new InvalidOperationException("Native list item count exceeded its bound");
        return count;
    }

    public static int ReadNativeListColumnCount(IntPtr window, int expectedProcessId)
    {
        VerifyNativeControl(window, expectedProcessId, "list");
        IntPtr headerResult;
        if (
            SendMessageTimeoutRaw(
                window,
                LVM_GETHEADER,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out headerResult
            ) == IntPtr.Zero ||
            headerResult == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native filter list header could not be read");
        }
        var header = headerResult;
        uint headerProcessId;
        if (
            GetWindowThreadProcessId(header, out headerProcessId) == 0 ||
            headerProcessId != (uint)expectedProcessId
        )
        {
            throw new InvalidOperationException("Native filter list header ownership is unavailable");
        }
        var className = new System.Text.StringBuilder(128);
        if (
            GetClassName(header, className, className.Capacity) == 0 ||
            className.ToString() != "SysHeader32"
        )
        {
            throw new InvalidOperationException("Native filter list header class did not match");
        }
        IntPtr countResult;
        if (
            SendMessageTimeoutRaw(
                header,
                HDM_GETITEMCOUNT,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                NativeControlMessageTimeout,
                out countResult
            ) == IntPtr.Zero
        )
        {
            throw new InvalidOperationException("Native filter list column count could not be read");
        }
        VerifyNativeControl(window, expectedProcessId, "list");
        var count = countResult.ToInt32();
        if (count < 1 || count > 8)
            throw new InvalidOperationException("Native filter list column count exceeded its bound");
        return count;
    }

    public static string ReadNativeListItemText(
        IntPtr window,
        int expectedProcessId,
        int item,
        int subItem,
        int maximumCharacters
    )
    {
        if (
            item < 0 ||
            item >= ReadNativeListItemCount(window, expectedProcessId) ||
            subItem < 0 ||
            subItem >= ReadNativeListColumnCount(window, expectedProcessId) ||
            maximumCharacters < 1 ||
            maximumCharacters > 1024
        )
        {
            throw new ArgumentOutOfRangeException();
        }
        VerifyNativeControl(window, expectedProcessId, "list");
        var process = OpenProcess(
            ProcessVmOperation |
                ProcessVmRead |
                ProcessVmWrite |
                ProcessQueryLimitedInformation,
            false,
            (uint)expectedProcessId
        );
        if (process == IntPtr.Zero)
            throw new InvalidOperationException("Native filter list process memory is unavailable");
        IntPtr remoteMemory = IntPtr.Zero;
        IntPtr localMemory = IntPtr.Zero;
        try
        {
            var itemSize = Marshal.SizeOf(typeof(NativeListViewItem));
            var textBufferSize = checked((maximumCharacters + 1) * 2);
            var allocationSize = checked(itemSize + textBufferSize);
            remoteMemory = VirtualAllocEx(
                process,
                IntPtr.Zero,
                new UIntPtr((uint)allocationSize),
                MemCommitReserve,
                PageReadWrite
            );
            if (remoteMemory == IntPtr.Zero)
                throw new InvalidOperationException("Native filter list buffer allocation failed");
            var remoteText = new IntPtr(remoteMemory.ToInt64() + itemSize);
            var nativeItem = new NativeListViewItem
            {
                Mask = LVIF_TEXT,
                Item = item,
                SubItem = subItem,
                Text = remoteText,
                TextMax = maximumCharacters + 1
            };
            localMemory = Marshal.AllocHGlobal(itemSize);
            Marshal.StructureToPtr(nativeItem, localMemory, false);
            var itemBytes = new byte[itemSize];
            Marshal.Copy(localMemory, itemBytes, 0, itemSize);
            UIntPtr written;
            if (
                !WriteProcessMemory(
                    process,
                    remoteMemory,
                    itemBytes,
                    new UIntPtr((uint)itemBytes.Length),
                    out written
                ) ||
                written.ToUInt64() != (ulong)itemBytes.Length
            )
            {
                throw new InvalidOperationException("Native filter list request could not be written");
            }
            IntPtr copiedResult;
            if (
                SendMessageTimeoutRaw(
                    window,
                    LVM_GETITEMTEXTW,
                    new IntPtr(item),
                    remoteMemory,
                    SMTO_ABORTIFHUNG,
                    NativeControlMessageTimeout,
                    out copiedResult
                ) == IntPtr.Zero
            )
            {
                throw new InvalidOperationException("Native filter list item text could not be read");
            }
            var copied = copiedResult.ToInt32();
            if (copied < 0 || copied > maximumCharacters)
                throw new InvalidOperationException("Native filter list item text exceeded its bound");
            var textBytes = new byte[textBufferSize];
            UIntPtr read;
            if (
                !ReadProcessMemory(
                    process,
                    remoteText,
                    textBytes,
                    new UIntPtr((uint)textBytes.Length),
                    out read
                ) ||
                read.ToUInt64() != (ulong)textBytes.Length
            )
            {
                throw new InvalidOperationException("Native filter list text readback failed");
            }
            var text = System.Text.Encoding.Unicode.GetString(textBytes);
            var terminator = text.IndexOf('\0');
            if (terminator < 0 || terminator != copied)
                throw new InvalidOperationException("Native filter list text was inconsistent");
            VerifyNativeControl(window, expectedProcessId, "list");
            return text.Substring(0, terminator);
        }
        finally
        {
            if (localMemory != IntPtr.Zero)
                Marshal.FreeHGlobal(localMemory);
            var cleanupFailed = false;
            if (
                remoteMemory != IntPtr.Zero &&
                !VirtualFreeEx(process, remoteMemory, UIntPtr.Zero, MemRelease)
            )
            {
                cleanupFailed = true;
            }
            if (!CloseHandle(process))
                cleanupFailed = true;
            if (cleanupFailed)
                throw new InvalidOperationException("Native filter list memory cleanup failed");
        }
    }

    public static IntPtr[] GetProcessTopLevelWindows(int processId, int maximum)
    {
        if (processId <= 0 || maximum < 1 || maximum > 257)
            throw new ArgumentOutOfRangeException();
        var windows = new System.Collections.Generic.List<IntPtr>();
        EnumWindowsProc callback = (hWnd, lParam) =>
        {
            uint ownerProcessId;
            if (
                GetWindowThreadProcessId(hWnd, out ownerProcessId) != 0 &&
                ownerProcessId == (uint)processId
            )
            {
                windows.Add(hWnd);
                return windows.Count < maximum;
            }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        return windows.ToArray();
    }

    public static FocusSnapshot ReadFocusSnapshot(IntPtr window)
    {
        uint processId;
        var threadId = GetWindowThreadProcessId(window, out processId);
        var snapshot = new FocusSnapshot
        {
            Available = false,
            ActiveWindow = IntPtr.Zero,
            FocusWindow = IntPtr.Zero
        };
        if (threadId == 0)
        {
            return snapshot;
        }
        var info = new GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf(typeof(GuiThreadInfo))
        };
        if (!GetGUIThreadInfo(threadId, ref info))
        {
            return snapshot;
        }
        snapshot.Available = true;
        snapshot.ActiveWindow = info.hwndActive;
        snapshot.FocusWindow = info.hwndFocus;
        return snapshot;
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

    [DllImport("oleacc.dll", ExactSpelling = true)]
    private static extern int AccessibleObjectFromWindow(
        IntPtr hWnd,
        uint objectId,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out Accessibility.IAccessible accessibleObject
    );

    private static bool TryGetInteger(object value, out int number)
    {
        if (value is short)
        {
            number = (short)value;
            return true;
        }
        if (value is int)
        {
            number = (int)value;
            return true;
        }
        if (value is uint && (uint)value <= int.MaxValue)
        {
            number = (int)(uint)value;
            return true;
        }
        if (value is long && (long)value >= int.MinValue && (long)value <= int.MaxValue)
        {
            number = (int)(long)value;
            return true;
        }
        number = 0;
        return false;
    }

    public static AccessibleMenuSnapshot ReadAccessibleDropMenuState(
        IntPtr menuWindow,
        uint expectedProcessId,
        bool useWindowMenuObject
    )
    {
        var snapshot = new AccessibleMenuSnapshot
        {
            ReadFailure = "window-unavailable",
            CheckState = "unavailable"
        };
        uint menuProcessId;
        if (GetWindowThreadProcessId(menuWindow, out menuProcessId) == 0)
        {
            return snapshot;
        }
        snapshot.ProcessKnown = true;
        if (menuProcessId != expectedProcessId)
        {
            snapshot.ReadFailure = "process-mismatch";
            return snapshot;
        }
        snapshot.ProcessSame = true;

        var interfaceId = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        Accessibility.IAccessible accessibleObject;
        var objectId = useWindowMenuObject
            ? unchecked((uint)AccessibleMenuObjectId)
            : unchecked((uint)AccessibleClientObjectId);
        var result = AccessibleObjectFromWindow(
            menuWindow,
            objectId,
            ref interfaceId,
            out accessibleObject
        );
        if (result != 0 || accessibleObject == null)
        {
            snapshot.ReadFailure = "object-unavailable";
            return snapshot;
        }
        snapshot.AccessibleAvailable = true;

        try
        {
            var itemCount = accessibleObject.accChildCount;
            if (itemCount < 0)
            {
                snapshot.ReadFailure = "count-invalid";
                return snapshot;
            }
            if (itemCount > MaximumAccessibleMenuItems)
            {
                snapshot.ReadFailure = "count-limit";
                return snapshot;
            }
            snapshot.ItemCount = itemCount;

            var matchState = 0;
            for (var childId = 1; childId <= itemCount; childId++)
            {
                var child = (object)childId;
                var name = accessibleObject.get_accName(child) ?? string.Empty;
                var roleValue = accessibleObject.get_accRole(child);
                int role;
                if (!TryGetInteger(roleValue, out role))
                {
                    snapshot.ReadFailure = "child-read-failed";
                    return snapshot;
                }
                if (role != MenuItemRole)
                {
                    continue;
                }

                var normalizedName = name.Replace("&", "");
                var acceleratorIndex = normalizedName.IndexOf('\t');
                if (acceleratorIndex >= 0)
                {
                    normalizedName = normalizedName.Substring(0, acceleratorIndex);
                }
                if (!string.Equals(
                    normalizedName.Trim(),
                    "Drop Filtered Events",
                    StringComparison.Ordinal
                ))
                {
                    continue;
                }

                snapshot.MatchCount++;
                var stateValue = accessibleObject.get_accState(child);
                int state;
                if (!TryGetInteger(stateValue, out state) || (state & MixedState) != 0)
                {
                    snapshot.ReadFailure = "state-invalid";
                    return snapshot;
                }
                matchState = state;
            }

            if (snapshot.MatchCount == 0)
            {
                snapshot.ReadFailure = "no-match";
                return snapshot;
            }
            if (snapshot.MatchCount != 1)
            {
                snapshot.ReadFailure = "duplicate-match";
                return snapshot;
            }
            snapshot.ReadFailure = "none";
            snapshot.CheckState = (matchState & CheckedState) != 0 ? "on" : "off";
            snapshot.IsEnabled = (matchState & UnavailableState) == 0;
            return snapshot;
        }
        catch (COMException)
        {
            snapshot.ReadFailure = "child-read-failed";
            return snapshot;
        }
    }

    public static AccessibleMenuSnapshot ReadAccessibleFilterMenuSummary(
        IntPtr menuWindow,
        uint expectedProcessId
    )
    {
        var snapshot = new AccessibleMenuSnapshot
        {
            ReadFailure = "window-unavailable",
            CheckState = "unavailable"
        };
        uint menuProcessId;
        if (GetWindowThreadProcessId(menuWindow, out menuProcessId) == 0)
        {
            return snapshot;
        }
        snapshot.ProcessKnown = true;
        if (menuProcessId != expectedProcessId)
        {
            snapshot.ReadFailure = "process-mismatch";
            return snapshot;
        }
        snapshot.ProcessSame = true;

        var interfaceId = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        Accessibility.IAccessible accessibleObject;
        var result = AccessibleObjectFromWindow(
            menuWindow,
            unchecked((uint)AccessibleMenuObjectId),
            ref interfaceId,
            out accessibleObject
        );
        if (result != 0 || accessibleObject == null)
        {
            snapshot.ReadFailure = "object-unavailable";
            return snapshot;
        }
        snapshot.AccessibleAvailable = true;

        try
        {
            var itemCount = accessibleObject.accChildCount;
            if (itemCount < 0 || itemCount > MaximumAccessibleMenuItems)
            {
                snapshot.ReadFailure = itemCount < 0 ? "count-invalid" : "count-limit";
                return snapshot;
            }
            snapshot.ItemCount = itemCount;
            for (var childId = 1; childId <= itemCount; childId++)
            {
                var child = (object)childId;
                var name = accessibleObject.get_accName(child) ?? string.Empty;
                var roleValue = accessibleObject.get_accRole(child);
                int role;
                if (!TryGetInteger(roleValue, out role))
                {
                    snapshot.ReadFailure = "child-read-failed";
                    return snapshot;
                }
                if (role != MenuItemRole)
                {
                    continue;
                }

                var normalizedName = name.Replace("&", "");
                var acceleratorIndex = normalizedName.IndexOf('\t');
                if (acceleratorIndex >= 0)
                {
                    normalizedName = normalizedName.Substring(0, acceleratorIndex);
                }
                switch (normalizedName.Trim())
                {
                    case "Event":
                        snapshot.EventCount++;
                        break;
                    case "Filter":
                        snapshot.FilterCount++;
                        break;
                    case "Filter...":
                        snapshot.FilterCommandCount++;
                        break;
                }
            }
            snapshot.ReadFailure = "none";
            return snapshot;
        }
        catch (COMException)
        {
            snapshot.ReadFailure = "child-read-failed";
            return snapshot;
        }
    }

    public static IntPtr GetMenuOwnerWindow(
        IntPtr menuWindow,
        uint expectedProcessId,
        out bool menuWindowProcessKnown,
        out bool menuWindowSameProcess,
        out bool guiThreadInfoAvailable,
        out bool menuModeActive
    )
    {
        menuWindowProcessKnown = false;
        menuWindowSameProcess = false;
        guiThreadInfoAvailable = false;
        menuModeActive = false;
        uint menuProcessId;
        var menuThreadId = GetWindowThreadProcessId(menuWindow, out menuProcessId);
        if (menuThreadId == 0)
        {
            return IntPtr.Zero;
        }
        menuWindowProcessKnown = true;
        if (menuProcessId != expectedProcessId)
        {
            return IntPtr.Zero;
        }
        menuWindowSameProcess = true;

        var info = new GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf(typeof(GuiThreadInfo))
        };
        if (!GetGUIThreadInfo(menuThreadId, ref info))
        {
            return IntPtr.Zero;
        }
        guiThreadInfoAvailable = true;
        menuModeActive =
            (info.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE)) != 0;
        if (info.hwndMenuOwner == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        uint ownerProcessId;
        if (
            GetWindowThreadProcessId(info.hwndMenuOwner, out ownerProcessId) == 0 ||
            ownerProcessId != expectedProcessId
        )
        {
            return IntPtr.Zero;
        }
        return info.hwndMenuOwner;
    }

    [DllImport(
        "user32.dll",
        EntryPoint = "GetMenuItemCount",
        ExactSpelling = true,
        SetLastError = true
    )]
    private static extern int GetMenuItemCountNative(IntPtr hMenu);

    public static int GetMenuItemCount(IntPtr hMenu)
    {
        var itemCount = GetMenuItemCountNative(hMenu);
        if (itemCount >= 0)
        {
            return itemCount;
        }
        var lastError = Marshal.GetLastWin32Error();
        return lastError == 1401 ? -2 : lastError == 0 ? -3 : -4;
    }

    [DllImport(
        "user32.dll",
        EntryPoint = "GetMenuItemInfoW",
        ExactSpelling = true,
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMenuItemInfo(
        IntPtr hMenu,
        uint item,
        [MarshalAs(UnmanagedType.Bool)] bool fByPosition,
        ref MenuItemInfo info
    );

    public static ItemSnapshot ReadItem(IntPtr hMenu, uint position, out bool ownerDrawn)
    {
        ownerDrawn = false;
        var info = new MenuItemInfo
        {
            cbSize = (uint)Marshal.SizeOf(typeof(MenuItemInfo)),
            fMask = MIIM_STATE | MIIM_SUBMENU | MIIM_FTYPE
        };
        if (!GetMenuItemInfo(hMenu, position, true, ref info))
        {
            return null;
        }
        var itemState = info.fState;
        ownerDrawn = (info.fType & MFT_OWNERDRAW) != 0;
        if (ownerDrawn)
        {
            return null;
        }
        info.fMask = MIIM_STRING;
        info.dwTypeData = IntPtr.Zero;
        info.cch = 0;
        if (!GetMenuItemInfo(hMenu, position, true, ref info) ||
            info.cch > MaximumTextCharacters)
        {
            return null;
        }
        var bufferCharacters = info.cch + 1;
        var buffer = Marshal.AllocHGlobal((int)(bufferCharacters * 2));
        try
        {
            info.dwTypeData = buffer;
            info.cch = bufferCharacters;
            if (!GetMenuItemInfo(hMenu, position, true, ref info) ||
                info.cch > MaximumTextCharacters)
            {
                return null;
            }
            return new ItemSnapshot
            {
                Text = Marshal.PtrToStringUni(buffer, (int)info.cch) ?? string.Empty,
                IsChecked = (itemState & MFS_CHECKED) != 0,
                IsHighlighted = (itemState & MFS_HILITE) != 0,
                IsEnabled = (itemState & MFS_DISABLED) == 0,
                Submenu = info.hSubMenu
            };
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
"@
  Add-Type -TypeDefinition $nativeMenuTypeDefinition `
    -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location)
} catch {
  Write-StartupFailure "compile-native-menu-helper" $_
  exit 1
}

try {
  if ($PSBoundParameters.ContainsKey("CaptureProcessId")) {
    $process = [System.Diagnostics.Process]::GetProcessById($CaptureProcessId)
    if ($process.Path -cne [IO.Path]::GetFullPath($ProcmonPath)) {
      throw "Capture process executable does not match the requested Process Monitor"
    }
  } else {
    $process = Start-Process -FilePath $ProcmonPath -ArgumentList "/AcceptEula" -PassThru
  }
} catch {
  Write-StartupFailure "start-procmon" $_
  exit 1
}

function Set-Stage([string]$Name) {
  $script:stage = $Name
  [Console]::Out.WriteLine("PROC_MON_FILTER_PROGRESS=$Name")
}

function Get-ConfigHeaderClass([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $header = [byte[]]::new(8)
    $length = $stream.Read($header, 0, $header.Length)
  } finally {
    $stream.Dispose()
  }
  if ($length -eq 0) { return "empty" }
  if ($length -lt 4) { return "short" }
  if ($header[0] -eq 0x4d -and $header[1] -eq 0x5a) { return "mz" }
  if ([System.Text.Encoding]::ASCII.GetString($header, 0, $length).StartsWith(
      "<?xml", [System.StringComparison]::Ordinal
    )) {
    return "xml"
  }
  return "other"
}

function Write-ConfigOutputObservation([string]$Phase, [string]$Path) {
  $targetState = "missing"
  $targetHeader = "not-file"
  if (Test-Path -LiteralPath $Path) {
    $target = Get-Item -LiteralPath $Path
    $targetState = if ($target.PSIsContainer) {
      "directory"
    } elseif ($target.Length -lt 100) {
      "undersized"
    } else {
      "ready"
    }
    if (-not $target.PSIsContainer) {
      $targetHeader = Get-ConfigHeaderClass $Path
    }
  }
  $pmcCount = 0
  $headerCounts = @{
    empty = 0
    short = 0
    mz = 0
    xml = 0
    other = 0
  }
  $otherCount = 0
  $entries = @(
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($Path)) -Force |
      Select-Object -First 33
  )
  $truncated = ($entries.Count -gt 32)
  foreach ($entry in $entries | Select-Object -First 32) {
    if ($entry.PSIsContainer) {
      $otherCount++
    } elseif ($entry.Extension -ieq ".pmc") {
      $pmcCount++
      $headerCounts[(Get-ConfigHeaderClass $entry.FullName)]++
    } else {
      $otherCount++
    }
  }
  $headerSummary = "empty:$($headerCounts.empty);short:$($headerCounts.short);mz:$($headerCounts.mz);xml:$($headerCounts.xml);other:$($headerCounts.other)"
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_CONFIG_OUTPUT=phase:$Phase;target:$targetState;target-header:$targetHeader;pmc-count:$pmcCount;headers:$headerSummary;other-count:$otherCount;truncated:$($truncated.ToString().ToLowerInvariant())"
  )
}

function Wait-Element(
  [System.Windows.Automation.AutomationElement]$Root,
  [System.Windows.Automation.Condition]$Condition,
  [int]$TimeoutSeconds = 10,
  [switch]$AllowMissing
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    if ($null -ne $element) { return $element }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  if ($AllowMissing) { return $null }
  throw "Timed out waiting for a Process Monitor UI control"
}

function Wait-FilterConfigFile([string]$Path, [int]$TimeoutMilliseconds = 5000) {
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $firstObservation = $true
  do {
    $state = "missing"
    if (Test-Path -LiteralPath $Path) {
      $file = Get-Item -LiteralPath $Path
      if ($file.PSIsContainer) {
        throw "Process Monitor configuration path is not a file"
      }
      $state = if ($file.Length -ge 100) { "ready" } else { "undersized" }
    }
    if ($firstObservation) {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:initial;state:$state")
      $firstObservation = $false
    }
    if ($state -eq "ready") {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:final;state:ready")
      return
    }
    $remaining = $TimeoutMilliseconds - $timer.ElapsedMilliseconds
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min(100, $remaining))
  } while ($true)
  [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:final;state:$state")
  throw "Process Monitor did not save the audit filter configuration before the deadline"
}

function Get-ConfigFilterPathEvidence([string]$Path, [string]$CanaryPath, [string]$ControlPath) {
  $file = Get-Item -LiteralPath $Path
  if ($file.PSIsContainer) {
    throw "Process Monitor configuration file is not a bounded file"
  }
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    if ($stream.Length -gt 1MB) {
      throw "Process Monitor configuration file is not a bounded file"
    }
    $bytes = [byte[]]::new([int]$stream.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
      $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) {
        throw "Process Monitor configuration file changed while being read"
      }
      $offset += $read
    }
    if ($stream.ReadByte() -ne -1) {
      throw "Process Monitor configuration file is not a bounded file"
    }
  } finally {
    $stream.Dispose()
  }
  $decoded = @(
    [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.Text.Encoding]::Unicode.GetString($bytes)
    [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
  )
  $countMatches = {
    param([string]$Content, [string]$Value)
    $count = 0
    $offset = 0
    while ($count -lt 999) {
      $match = $Content.IndexOf(
        $Value,
        $offset,
        [System.StringComparison]::OrdinalIgnoreCase
      )
      if ($match -lt 0) { break }
      $count++
      $offset = $match + $Value.Length
    }
    return $count
  }
  $canaryCounts = @()
  $controlCounts = @()
  foreach ($content in $decoded) {
    $canaryCounts += (& $countMatches $content $CanaryPath)
    $controlCounts += (& $countMatches $content $ControlPath)
  }
  $canaryMatches = ($canaryCounts | Measure-Object -Maximum).Maximum
  $controlMatches = ($controlCounts | Measure-Object -Maximum).Maximum
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_CONFIG_PATHS=canary:$canaryMatches;control:$controlMatches"
  )
  if ($canaryMatches -eq 0 -or $controlMatches -eq 0) {
    throw "Process Monitor configuration did not retain both audit filter paths"
  }
  return [pscustomobject]@{
    CanaryMatches = $canaryMatches
    ControlMatches = $controlMatches
  }
}

function Get-LoadedFilterRuleEvidence(
  [object[]]$Rows,
  [string]$CanaryPath,
  [string]$ControlPath
) {
  $canaryRows = 0
  $controlRows = 0
  $pathRows = 0
  $operatorRows = 0
  $includeRows = 0
  $exactRows = 0
  foreach ($row in $Rows) {
    $rowText = if ($row -is [string]) { $row } else { $row.Text }
    $hasCanary = $rowText.IndexOf(
      $CanaryPath,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
    $hasControl = $rowText.IndexOf(
      $ControlPath,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
    if ($hasCanary) { $canaryRows++ }
    if ($hasControl) { $controlRows++ }
    $canaryPattern = [regex]::Escape($CanaryPath)
    $controlPattern = [regex]::Escape($ControlPath)
    $hasCanaryPathRule = [regex]::IsMatch(
      $rowText,
      "(?i)(?<!\w)Path\s+is\s+$canaryPattern(?=\s|$)"
    )
    $hasControlPathRule = [regex]::IsMatch(
      $rowText,
      "(?i)(?<!\w)Path\s+is\s+$controlPattern(?=\s|$)"
    )
    $hasCanaryInclude = [regex]::IsMatch(
      $rowText,
      "(?i)$canaryPattern\s+Include\s*$"
    )
    $hasControlInclude = [regex]::IsMatch(
      $rowText,
      "(?i)$controlPattern\s+Include\s*$"
    )
    $hasPathRule = $hasCanaryPathRule -or $hasControlPathRule
    $hasIncludeRule = (
      ($hasCanaryPathRule -and $hasCanaryInclude) -or
      ($hasControlPathRule -and $hasControlInclude)
    )
    if ($hasPathRule) { $pathRows++ }
    if ($hasPathRule) { $operatorRows++ }
    if ($hasIncludeRule) { $includeRows++ }
    if (
      ($hasCanaryPathRule -and $hasCanaryInclude -and $hasCanary -and -not $hasControl) -or
      ($hasControlPathRule -and $hasControlInclude -and $hasControl -and -not $hasCanary)
    ) {
      $exactRows++
    }
  }
  $unclassifiedRows = $Rows.Count - $exactRows
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RELOADED_RULES=rows:$($Rows.Count);canary:$canaryRows;control:$controlRows;path:$pathRows;is:$operatorRows;include:$includeRows;unclassified:$unclassifiedRows"
  )
  if (
    $Rows.Count -ne 2 -or
    $canaryRows -ne 1 -or
    $controlRows -ne 1 -or
    $pathRows -ne 2 -or
    $operatorRows -ne 2 -or
    $includeRows -ne 2 -or
    $exactRows -ne 2
  ) {
    throw "Process Monitor did not reload exactly the two required Path Include rules"
  }
  return [pscustomobject]@{
    Rows = $Rows.Count
    CanaryRows = $canaryRows
    ControlRows = $controlRows
    ExactRows = $exactRows
    UnclassifiedRows = $unclassifiedRows
  }
}

function Get-LoadedFilterRuleRows(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$OwnerProcessId,
  [switch]$AllowEmpty,
  [switch]$Quiet,
  [switch]$Reloaded
) {
  $dialogState = $Dialog.Current
  $dialogHandle = [IntPtr]$dialogState.NativeWindowHandle
  if (
    $dialogState.ProcessId -ne $OwnerProcessId -or
    $dialogHandle -eq [IntPtr]::Zero -or
    [ProcmonNativeMenu]::GetWindowProcessId($dialogHandle) -ne $OwnerProcessId
  ) {
    throw "Process Monitor filter dialog ownership could not be verified"
  }
  $nativeControls = Get-ProcmonNativeFilterDialogControls $Dialog $OwnerProcessId
  if ($null -ne $nativeControls) {
    $nativeRows = Get-ProcmonNativeFilterRuleRows `
      $nativeControls $OwnerProcessId -Quiet:$Quiet -Reloaded:$Reloaded
    if ($nativeRows.Count -eq 0 -and -not $AllowEmpty) {
      throw "Process Monitor filter dialog did not expose readable native rule rows"
    }
    return ,$nativeRows
  }
  $items = $Dialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $rowKinds = @("ControlType.ListItem", "ControlType.DataItem")
  $containerKinds = @(
    "ControlType.List",
    "ControlType.DataGrid",
    "ControlType.Table"
  )
  $containerRows = [System.Collections.Generic.Dictionary[string, object]]::new()
  $rows = [System.Collections.Generic.List[object]]::new()
  $listCount = 0
  $dataGridCount = 0
  $tableCount = 0
  $listItemCount = 0
  $dataItemCount = 0
  $dialogWindowRowCount = 0
  $otherWindowRowCount = 0
  $unscopedRowCount = 0
  $comboOptionRowCount = 0
  $ruleRowCandidateCount = 0
  $ruleContainerUnclassifiedRowCount = 0
  $rowTruncated = $false
  $itemScanCount = [Math]::Min($items.Count, 1024)
  for ($itemIndex = 0; $itemIndex -lt $itemScanCount; $itemIndex++) {
    $item = $items[$itemIndex]
    $state = $item.Current
    switch ($state.ControlType.ProgrammaticName) {
      "ControlType.List" { $listCount++ }
      "ControlType.DataGrid" { $dataGridCount++ }
      "ControlType.Table" { $tableCount++ }
      "ControlType.ListItem" { $listItemCount++ }
      "ControlType.DataItem" { $dataItemCount++ }
    }
    if ($state.ProcessId -ne $OwnerProcessId -or
      $state.ControlType.ProgrammaticName -notin $rowKinds) {
      continue
    }
    $parent = $treeWalker.GetParent($item)
    $insideRow = $false
    $insideComboBox = $false
    $nearestContainer = $null
    $nearestWindowHandle = [IntPtr]::Zero
    for ($level = 0; $null -ne $parent -and $level -lt 10; $level++) {
      $parentType = $parent.Current.ControlType.ProgrammaticName
      if ($parentType -in $rowKinds) {
        $insideRow = $true
        break
      }
      if ($parentType -eq "ControlType.ComboBox") {
        $insideComboBox = $true
      }
      if ($null -eq $nearestContainer -and $parentType -in $containerKinds) {
        $nearestContainer = $parent
      }
      if ($parentType -eq "ControlType.Window") {
        $nearestWindowHandle = [IntPtr]$parent.Current.NativeWindowHandle
        break
      }
      $parent = $treeWalker.GetParent($parent)
    }
    if ($insideRow -or $null -eq $nearestContainer) {
      continue
    }
    if ($nearestWindowHandle -ne $dialogHandle) {
      if ($nearestWindowHandle -eq [IntPtr]::Zero) {
        $unscopedRowCount++
      } else {
        $otherWindowRowCount++
      }
      continue
    }
    $dialogWindowRowCount++
    if ($insideComboBox) {
      $comboOptionRowCount++
      continue
    }
    $containerRuntimeId = $nearestContainer.GetRuntimeId() -join ","
    if ([string]::IsNullOrWhiteSpace($containerRuntimeId)) {
      throw "Process Monitor filter rule container did not expose a runtime identifier"
    }
    if (-not $containerRows.ContainsKey($containerRuntimeId)) {
      if ($containerRows.Count -ge 32) {
        $rowTruncated = $true
        continue
      }
      $containerRows.Add($containerRuntimeId, [pscustomobject]@{
        Rows = [System.Collections.Generic.List[string]]::new()
        RuleRows = [System.Collections.Generic.List[string]]::new()
        RuleRowElements = [System.Collections.Generic.List[object]]::new()
        Element = $nearestContainer
        RuleControlTypes = [System.Collections.Generic.List[string]]::new()
        UniqueRuleRows = [System.Collections.Generic.HashSet[string]]::new(
          [System.StringComparer]::OrdinalIgnoreCase
        )
      })
    }
    $container = $containerRows[$containerRuntimeId]
    if ($container.Rows.Count -ge 64) {
      $rowTruncated = $true
      continue
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($state.Name)) {
      $parts.Add($state.Name)
    }
    $cells = $item.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    if ($cells.Count -gt 64) {
      throw "Process Monitor filter rule exceeded the cell limit"
    }
    foreach ($cell in $cells) {
      $cellState = $cell.Current
      if ($cellState.ProcessId -ne $OwnerProcessId) {
        throw "Process Monitor filter rule crossed a process boundary"
      }
      if (-not [string]::IsNullOrEmpty($cellState.Name)) {
        $parts.Add($cellState.Name)
      }
    }
    $rowText = $parts -join " "
    $container.Rows.Add($rowText)
    if ($rowText -match "(?i)\s(?:Include|Exclude)\s*$") {
      $container.RuleRows.Add($rowText)
      $container.RuleRowElements.Add($item)
      $container.RuleControlTypes.Add($state.ControlType.ProgrammaticName)
      $normalizedRow = [regex]::Replace($rowText, "\s+", " ").Trim()
      $container.UniqueRuleRows.Add($normalizedRow) | Out-Null
    }
  }
  $ruleContainers = [System.Collections.Generic.List[object]]::new()
  foreach ($container in $containerRows.Values) {
    if ($container.RuleRows.Count -gt 0) {
      $ruleContainers.Add($container)
      $ruleRowCandidateCount += $container.RuleRows.Count
      $ruleContainerUnclassifiedRowCount += (
        $container.Rows.Count - $container.RuleRows.Count
      )
    }
  }
  $ruleRowShape = [ordered]@{
    Rows = 0
    Distinct = 0
    Duplicates = 0
    ListItems = 0
    DataItems = 0
    Include = 0
    Exclude = 0
    PathField = 0
    ProcessField = 0
    OperationField = 0
    OtherField = 0
    UnknownField = 0
  }
  if ($ruleContainers.Count -eq 1) {
    $ruleContainer = $ruleContainers[0]
    $ruleRowShape.Rows = $ruleContainer.RuleRows.Count
    $ruleRowShape.Distinct = $ruleContainer.UniqueRuleRows.Count
    $ruleRowShape.Duplicates = (
      $ruleRowShape.Rows - $ruleRowShape.Distinct
    )
    $ruleRowShape.ListItems = @(
      $ruleContainer.RuleControlTypes |
        Where-Object { $_ -eq "ControlType.ListItem" }
    ).Count
    $ruleRowShape.DataItems = @(
      $ruleContainer.RuleControlTypes |
        Where-Object { $_ -eq "ControlType.DataItem" }
    ).Count
    foreach ($row in $ruleContainer.RuleRows) {
      if ($row -match "(?i)\sInclude\s*$") {
        $ruleRowShape.Include++
      } elseif ($row -match "(?i)\sExclude\s*$") {
        $ruleRowShape.Exclude++
      }
      if ($row -match "^(?i)Path\s") {
        $ruleRowShape.PathField++
      } elseif ($row -match "^(?i)Process Name\s") {
        $ruleRowShape.ProcessField++
      } elseif ($row -match "^(?i)Operation\s") {
        $ruleRowShape.OperationField++
      } elseif ($row -match "^(?i)(Result|Detail|Event Class|Date & Time|Duration|Sequence|PID|TID|User|Session|Architecture)\s") {
        $ruleRowShape.OtherField++
      } else {
        $ruleRowShape.UnknownField++
      }
    }
  }
  if ($ruleContainers.Count -eq 1 -and $ruleContainerUnclassifiedRowCount -eq 0) {
    for ($rowIndex = 0; $rowIndex -lt $ruleContainers[0].RuleRows.Count; $rowIndex++) {
      $rows.Add([pscustomobject]@{
        Text = $ruleContainers[0].RuleRows[$rowIndex]
        Element = $ruleContainers[0].RuleRowElements[$rowIndex]
        Container = $ruleContainers[0].Element
      })
    }
  }
  if (-not $Quiet) {
    $observation = if ($Reloaded) { "RELOADED" } else { "INITIAL" }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_${observation}_UI=items:$itemScanCount;lists:$listCount;data-grids:$dataGridCount;tables:$tableCount;list-items:$listItemCount;data-items:$dataItemCount;dialog-window-rows:$dialogWindowRowCount;other-window-rows:$otherWindowRowCount;unscoped-rows:$unscopedRowCount;combo-option-rows:$comboOptionRowCount;rule-containers:$($ruleContainers.Count);rule-row-candidates:$ruleRowCandidateCount;rule-container-unclassified-rows:$ruleContainerUnclassifiedRowCount;rows:$($rows.Count);truncated:$((($items.Count -gt 1024) -or $rowTruncated).ToString().ToLowerInvariant())"
    )
    if ($ruleContainers.Count -eq 1) {
      [Console]::Out.WriteLine(
        "PROC_MON_FILTER_${observation}_ROW_SHAPE=rows:$($ruleRowShape.Rows);distinct:$($ruleRowShape.Distinct);duplicates:$($ruleRowShape.Duplicates);list-items:$($ruleRowShape.ListItems);data-items:$($ruleRowShape.DataItems);include:$($ruleRowShape.Include);exclude:$($ruleRowShape.Exclude);path-field:$($ruleRowShape.PathField);process-field:$($ruleRowShape.ProcessField);operation-field:$($ruleRowShape.OperationField);other-field:$($ruleRowShape.OtherField);unknown-field:$($ruleRowShape.UnknownField)"
      )
    }
  }
  if ($items.Count -gt 1024 -or $rowTruncated) {
    throw "Process Monitor filter dialog exceeded the bounded UI item limit"
  }
  $allContainerRows = 0
  foreach ($container in $containerRows.Values) {
    $allContainerRows += $container.Rows.Count
  }
  if ($AllowEmpty -and
    $ruleContainers.Count -eq 0 -and
    $allContainerRows -eq 0) {
    return ,@()
  }
  if ($ruleContainers.Count -ne 1) {
    throw "Process Monitor filter dialog did not expose one filter rule list"
  }
  if ($ruleContainerUnclassifiedRowCount -gt 0) {
    throw "Process Monitor filter list contained unreadable or non-rule rows"
  }
  if ($rows.Count -eq 0) {
    throw "Process Monitor filter dialog did not expose readable rule rows"
  }
  return ,$rows.ToArray()
}

function Clear-LoadedFilterRules(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$OwnerProcessId
) {
  $maximumRows = 64
  $rows = Get-LoadedFilterRuleRows $Dialog $OwnerProcessId -AllowEmpty
  if ($rows.Count -eq 0) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_RULE_RESET=removed:0;remaining:0")
    return
  }
  if ($null -ne (Get-ProcmonNativeFilterDialogControls $Dialog $OwnerProcessId)) {
    throw "Process Monitor native Reset did not clear every existing filter rule"
  }
  if ($rows.Count -gt $maximumRows) {
    throw "Process Monitor filter list exceeded the bounded row limit"
  }
  $container = $rows[0].Container
  $containerState = $container.Current
  if ($containerState.ProcessId -ne $OwnerProcessId) {
    throw "Process Monitor filter rule container ownership could not be verified"
  }
  $selectionPattern = $null
  $hasSelectionPattern = $container.TryGetCurrentPattern(
    [System.Windows.Automation.SelectionPattern]::Pattern,
    [ref]$selectionPattern
  )
  $canSelectMultiple = $false
  if ($hasSelectionPattern) {
    $canSelectMultiple = $selectionPattern.Current.CanSelectMultiple
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RULE_CLEAR=rows:$($rows.Count);multi-select:$($canSelectMultiple.ToString().ToLowerInvariant())"
  )
  if (-not $canSelectMultiple) {
    throw "Process Monitor filter list does not support verified multi-selection"
  }
  $expectedRuntimeIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
  )
  for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
    $selectionPhase = "row-state"
    try {
      $rowElement = $rows[$rowIndex].Element
      $rowState = $rowElement.Current
      if ($rowState.ProcessId -ne $OwnerProcessId) {
        throw "Process Monitor filter row ownership could not be verified"
      }
      $selectionPhase = "runtime-id"
      $rowRuntimeId = $rowElement.GetRuntimeId() -join ","
      if ([string]::IsNullOrWhiteSpace($rowRuntimeId) -or
        -not $expectedRuntimeIds.Add($rowRuntimeId)) {
        throw "Process Monitor filter rows did not expose unique runtime identifiers"
      }
      $selectionPhase = "pattern"
      $rowSelectionPattern = $null
      if (-not $rowElement.TryGetCurrentPattern(
          [System.Windows.Automation.SelectionItemPattern]::Pattern,
          [ref]$rowSelectionPattern
        )) {
        throw "Process Monitor filter row could not be selected"
      }
      $selectionPhase = if ($rowIndex -eq 0) { "select" } else { "add" }
      if ($rowIndex -eq 0) {
        $rowSelectionPattern.Select()
      } else {
        $rowSelectionPattern.AddToSelection()
      }
      $selectionPhase = "verify"
      if (-not $rowSelectionPattern.Current.IsSelected) {
        throw "Process Monitor filter row selection was not confirmed"
      }
    } catch {
      [Console]::Out.WriteLine(
        "PROC_MON_FILTER_RULE_SELECTION_FAILURE=phase:$selectionPhase;row:$($rowIndex + 1);completed:$rowIndex;expected:$($rows.Count)"
      )
      throw
    }
  }
  try {
    $selectedRows = $selectionPattern.Current.GetSelection()
  } catch {
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_RULE_SELECTION_FAILURE=phase:selection-set;row:0;completed:$($rows.Count);expected:$($rows.Count)"
    )
    throw
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RULE_SELECTION=selected:$($selectedRows.Count);expected:$($rows.Count)"
  )
  if ($selectedRows.Count -ne $rows.Count) {
    throw "Process Monitor filter list did not select every existing row"
  }
  foreach ($selectedRow in $selectedRows) {
    if ($selectedRow.Current.ProcessId -ne $OwnerProcessId -or
      -not $expectedRuntimeIds.Contains(($selectedRow.GetRuntimeId() -join ","))) {
      throw "Process Monitor filter selection included an unexpected row"
    }
  }
  $removeButtons = $Dialog.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
          [System.Windows.Automation.AutomationElement]::NameProperty,
          "Remove"
        ),
        [System.Windows.Automation.PropertyCondition]::new(
          [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
          [System.Windows.Automation.ControlType]::Button
        )
      )
  )
  $removeEnabled = $false
  if ($removeButtons.Count -eq 1) {
    $removeEnabled = $removeButtons[0].Current.IsEnabled
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_REMOVE=buttons:$($removeButtons.Count);enabled:$($removeEnabled.ToString().ToLowerInvariant())"
  )
  if ($removeButtons.Count -ne 1) {
    throw "Process Monitor filter dialog did not expose one Remove button"
  }
  $removeState = $removeButtons[0].Current
  if ($removeState.ProcessId -ne $OwnerProcessId -or
    -not $removeState.IsEnabled -or $removeState.IsOffscreen) {
    throw "Process Monitor Remove button was unavailable"
  }
  $removePattern = $null
  if (-not $removeButtons[0].TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$removePattern
    )) {
    throw "Process Monitor Remove button could not be invoked"
  }
  $removePattern.Invoke()
  $remainingRows = Get-LoadedFilterRuleRows $Dialog $OwnerProcessId -AllowEmpty -Quiet
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RULES_REMAINING=rows:$($remainingRows.Count)"
  )
  if ($remainingRows.Count -ne 0) {
    throw "Process Monitor filter list did not become empty after removal"
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RULE_RESET=removed:$($rows.Count);remaining:0"
  )
}

function Wait-KeyboardFocus($Control, [int]$TimeoutMilliseconds = 2000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  do {
    $state = $Control.Current
    if ($state.HasKeyboardFocus) {
      return $state
    }
    $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min(50, $remaining))
  } while ([DateTime]::UtcNow -lt $deadline)
  return $null
}

function Set-ProcmonEditValueByKeyboard($Dialog, $Edit, $ValuePattern, [string]$Value, [int]$OwnerProcessId) {
  $dialogState = $Dialog.Current
  $editState = $Edit.Current
  $dialogHandle = [IntPtr]$dialogState.NativeWindowHandle
  $foregroundGate = "failed"
  if (
    $dialogState.ProcessId -eq $OwnerProcessId -and
    $editState.ProcessId -eq $OwnerProcessId -and
    $dialogHandle -ne [IntPtr]::Zero -and
    [ProcmonNativeMenu]::GetWindowProcessId($dialogHandle) -eq $OwnerProcessId
  ) {
    [ProcmonNativeMenu]::SetForegroundWindow($dialogHandle) | Out-Null
    $foregroundDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
      if (
        $foregroundHandle -eq $dialogHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle) -eq $OwnerProcessId
      ) {
        $foregroundGate = "passed"
        break
      }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $foregroundDeadline)
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_PATH_FOREGROUND=gate:$foregroundGate")
  if ($foregroundGate -ne "passed") {
    throw "Process Monitor filter dialog did not become the foreground window"
  }
  $Edit.SetFocus()
  $editFocus = Wait-KeyboardFocus $Edit
  if (
    $null -eq $editFocus -or
    $editFocus.ProcessId -ne $OwnerProcessId -or
    -not $editFocus.IsEnabled -or
    $editFocus.IsOffscreen -or
    -not $editFocus.IsKeyboardFocusable -or
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $dialogHandle
  ) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_PATH=gate:failed")
    throw "Process Monitor filter path control did not receive keyboard focus"
  }
  [System.Windows.Forms.SendKeys]::SendWait("^a")
  [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-SendKeysLiteral $Value))
  $pathGate = if ($ValuePattern.Current.Value -ceq $Value) {
    "passed"
  } else {
    "failed"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_PATH=gate:$pathGate")
  if ($pathGate -ne "passed") {
    throw "Process Monitor filter path did not retain the requested value"
  }
}

function ConvertTo-SendKeysLiteral([string]$Value) {
  $escaped = [System.Text.StringBuilder]::new()
  foreach ($character in $Value.ToCharArray()) {
    switch ([string]$character) {
      "+" { $null = $escaped.Append("{+}") }
      "^" { $null = $escaped.Append("{^}") }
      "%" { $null = $escaped.Append("{%}") }
      "~" { $null = $escaped.Append("{~}") }
      "(" { $null = $escaped.Append("{(}") }
      ")" { $null = $escaped.Append("{)}") }
      "{" { $null = $escaped.Append("{{}") }
      "}" { $null = $escaped.Append("{}}") }
      default { $null = $escaped.Append($character) }
    }
  }
  return $escaped.ToString()
}

function Write-ConfigSaveObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Controls,
  [int]$OwnerProcessId,
  [string]$ExpectedPath
) {
  try {
    $dialogState = $Controls.Dialog.Current
    $fileNameState = $Controls.FileName.Current
    $saveState = $Controls.Save.Current
    if ($dialogState.ProcessId -ne $OwnerProcessId -or
      $fileNameState.ProcessId -ne $OwnerProcessId -or
      $saveState.ProcessId -ne $OwnerProcessId) {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:other-process")
      return
    }
    $pathState = if (
      $Controls.FileName.GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern
      ).Current.Value -ceq $ExpectedPath
    ) { "matches" } else { "different" }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:available;enabled:$($dialogState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dialogState.IsOffscreen.ToString().ToLowerInvariant());path:$pathState;save-enabled:$($saveState.IsEnabled.ToString().ToLowerInvariant());save-offscreen:$($saveState.IsOffscreen.ToString().ToLowerInvariant());save-focusable:$($saveState.IsKeyboardFocusable.ToString().ToLowerInvariant());save-focused:$($saveState.HasKeyboardFocus.ToString().ToLowerInvariant())"
    )
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:unavailable")
  }
}

function Write-ConfigSaveResultObservation(
  [string]$Phase,
  [System.Diagnostics.Process]$Process,
  [System.Windows.Automation.AutomationElement]$MainWindow
) {
  try {
    $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    )
    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button
    )
    $rootWindows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    $embeddedWindows = $MainWindow.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $windowCondition
    )
    $seenHandles = [System.Collections.Generic.HashSet[int]]::new()
    $sameProcessDialogs = 0
    $otherProcessWindows = 0
    $buttonCounts = @{
      save = 0
      cancel = 0
      yes = 0
      no = 0
      ok = 0
      retry = 0
      close = 0
    }
    $truncated = $false
    foreach ($window in @($rootWindows) + @($embeddedWindows)) {
      $state = $window.Current
      if (
        $state.NativeWindowHandle -eq 0 -or
        -not $seenHandles.Add($state.NativeWindowHandle)
      ) {
        continue
      }
      if ($seenHandles.Count -gt 32) {
        $truncated = $true
        break
      }
      if ($state.ProcessId -ne $Process.Id) {
        $otherProcessWindows++
        continue
      }
      if ($state.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        continue
      }
      $sameProcessDialogs++
      $buttons = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $buttonCondition
      )
      foreach ($button in $buttons) {
        $buttonName = $button.Current.Name
        if ($buttonName -ceq "Save") { $buttonCounts.save++ }
        elseif ($buttonName -ceq "Cancel") { $buttonCounts.cancel++ }
        elseif ($buttonName -ceq "Yes") { $buttonCounts.yes++ }
        elseif ($buttonName -ceq "No") { $buttonCounts.no++ }
        elseif ($buttonName -ceq "OK") { $buttonCounts.ok++ }
        elseif ($buttonName -ceq "Retry") { $buttonCounts.retry++ }
        elseif ($buttonName -ceq "Close") { $buttonCounts.close++ }
      }
    }
    if ($buttonCounts.Values | Where-Object { $_ -gt 32 } | Select-Object -First 1) {
      $truncated = $true
    }
    $foreground = "unavailable"
    $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
    if ($foregroundHandle -ne [IntPtr]::Zero) {
      $foregroundProcessId = [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle)
      if ($foregroundProcessId -eq $Process.Id) {
        $foreground = if (
          $foregroundHandle -eq $MainWindow.Current.NativeWindowHandle
        ) { "procmon-main" } else { "procmon-other" }
      } elseif ($foregroundProcessId -gt 0) {
        $foreground = "other-process"
      }
    }
    $buttonSummary = "save:$([Math]::Min($buttonCounts.save, 32));cancel:$([Math]::Min($buttonCounts.cancel, 32));yes:$([Math]::Min($buttonCounts.yes, 32));no:$([Math]::Min($buttonCounts.no, 32));ok:$([Math]::Min($buttonCounts.ok, 32));retry:$([Math]::Min($buttonCounts.retry, 32));close:$([Math]::Min($buttonCounts.close, 32))"
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_SAVE_RESULT=phase:$Phase;foreground:$foreground;same-process-dialogs:$([Math]::Min($sameProcessDialogs, 32));other-process-windows:$([Math]::Min($otherProcessWindows, 32));buttons:$buttonSummary;truncated:$($truncated.ToString().ToLowerInvariant())"
    )
  } catch {
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_SAVE_RESULT_FAILED=phase:$Phase"
    )
  }
}

function Get-UniqueConfigSaveDialogMatch([System.Collections.IList]$Candidates) {
  if ($Candidates.Count -gt 1) {
    throw "Process Monitor exposed multiple configuration save dialogs"
  }
  if ($Candidates.Count -eq 1) {
    return $Candidates[0]
  }
  return $null
}

function Get-ConfigSaveWindowDisposition(
  [int]$WindowProcessId,
  [int]$ExpectedProcessId,
  [int]$WindowHandle,
  [int]$MainWindowHandle,
  [bool]$IsEnabled,
  [bool]$IsOffscreen
) {
  if ($WindowProcessId -ne $ExpectedProcessId) { return "other-process" }
  if ($WindowHandle -eq 0) { return "no-handle" }
  if ($WindowHandle -eq $MainWindowHandle) { return "main-window" }
  if (-not $IsEnabled) { return "disabled" }
  if ($IsOffscreen) { return "offscreen" }
  return "eligible"
}

function Wait-ConfigSaveDialog(
  [System.Diagnostics.Process]$Process,
  [System.Windows.Automation.AutomationElement]$MainWindow,
  [int]$TimeoutSeconds = 10
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $fileNameCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "File name:"
    )
  )
  $saveCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Save"
    )
  )
  do {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    $embeddedWindows = $MainWindow.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $windowCondition
    )
    $seenHandles = [System.Collections.Generic.HashSet[int]]::new()
    $dialogMatches = [System.Collections.Generic.List[object]]::new()
    $fileNameCount = 0
    $saveCount = 0
    $windowCounts = @{
      sameProcess = 0
      otherProcess = 0
      noHandle = 0
      mainWindow = 0
      disabled = 0
      offscreen = 0
      duplicateHandle = 0
      eligible = 0
    }
    $mainWindowHandle = $MainWindow.Current.NativeWindowHandle
    foreach ($window in @($windows) + @($embeddedWindows)) {
      $state = $window.Current
      $disposition = Get-ConfigSaveWindowDisposition `
        $state.ProcessId $Process.Id $state.NativeWindowHandle `
        $mainWindowHandle $state.IsEnabled $state.IsOffscreen
      if ($disposition -eq "other-process") {
        $windowCounts.otherProcess++
        continue
      }
      $windowCounts.sameProcess++
      if ($disposition -eq "no-handle") {
        $windowCounts.noHandle++
        continue
      }
      if ($disposition -eq "main-window") {
        $windowCounts.mainWindow++
        continue
      }
      if ($disposition -eq "disabled") {
        $windowCounts.disabled++
        continue
      }
      if ($disposition -eq "offscreen") {
        $windowCounts.offscreen++
        continue
      }
      if (-not $seenHandles.Add($state.NativeWindowHandle)) {
        $windowCounts.duplicateHandle++
        continue
      }
      $windowCounts.eligible++
      $fileNames = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $fileNameCondition
      )
      $saveButtons = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $saveCondition
      )
      $fileNameCount += $fileNames.Count
      $saveCount += $saveButtons.Count
      if ($fileNames.Count -eq 1 -and $saveButtons.Count -eq 1) {
        $dialogMatches.Add(@{ Dialog = $window; FileName = $fileNames[0]; Save = $saveButtons[0] })
      }
    }
    $dialogMatch = Get-UniqueConfigSaveDialogMatch $dialogMatches
    if ($null -ne $dialogMatch) {
      return $dialogMatch
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:$([Math]::Min($seenHandles.Count, 9999));file-names:$([Math]::Min($fileNameCount, 9999));save-buttons:$([Math]::Min($saveCount, 9999))"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SAVE_DIALOG_DIAGNOSTICS=same-process:$([Math]::Min($windowCounts.sameProcess, 9999));other-process:$([Math]::Min($windowCounts.otherProcess, 9999));no-handle:$([Math]::Min($windowCounts.noHandle, 9999));main-window:$([Math]::Min($windowCounts.mainWindow, 9999));disabled:$([Math]::Min($windowCounts.disabled, 9999));offscreen:$([Math]::Min($windowCounts.offscreen, 9999));duplicate-handle:$([Math]::Min($windowCounts.duplicateHandle, 9999));eligible:$([Math]::Min($windowCounts.eligible, 9999))"
  )
  throw "Process Monitor configuration save dialog did not expose unique file controls"
}

function Wait-MainWindow([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 15) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $filterMenuCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )
  $rootWindowCount = 0
  $ownedWindowCount = 0
  $mainHandleAvailable = $false
  $processExited = $false
  $windowFound = $false
  $scanPhase = "refresh-process"
  $foregroundOwner = "unavailable"
  try {
    do {
      $mainWindowHandleElement = $null
      $mainHandleRootElement = $null
      $firstOwnedWindow = $null
      $filterMenuWindow = $null
      $scanPhase = "refresh-process"
      $Process.Refresh()
      $scanPhase = "check-process"
      if ($Process.HasExited) {
        $processExited = $true
        break
      }
      $scanPhase = "read-main-window-handle"
      $mainHandle = $Process.MainWindowHandle
      $mainHandleAvailable = $mainHandle -ne [IntPtr]::Zero
      if ($mainHandleAvailable) {
        $scanPhase = "read-main-window-owner"
        $candidate = [System.Windows.Automation.AutomationElement]::FromHandle($mainHandle)
        if ($candidate.Current.ProcessId -eq $Process.Id) {
          $mainWindowHandleElement = $candidate
        }
      }
      $scanPhase = "enumerate-uia-windows"
      $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        $windowCondition
      )
      $rootWindowCount = $windows.Count
      foreach ($window in $windows) {
        $scanPhase = "read-uia-window-owner"
        if ($window.Current.ProcessId -eq $Process.Id) {
          $ownedWindowCount++
          if ($mainHandleAvailable -and
            [IntPtr]$window.Current.NativeWindowHandle -eq $mainHandle) {
            $mainHandleRootElement = $window
          }
          if ($null -eq $firstOwnedWindow) {
            $firstOwnedWindow = $window
          }
          $menuItem = $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $filterMenuCondition
          )
          if ($null -ne $menuItem -and $menuItem.Current.ProcessId -eq $Process.Id) {
            $filterMenuWindow = $window
            break
          }
        }
      }
      if ($null -ne $filterMenuWindow) {
        $windowFound = $true
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_MAIN_WINDOW=selection:filter-menu-root;root-windows:$([Math]::Min($rootWindowCount, 9999));uia-owned-windows:$([Math]::Min($ownedWindowCount, 9999));main-handle:$(if ($mainHandleAvailable) { 'available' } else { 'unavailable' });filter-menu:present"
        )
        return $filterMenuWindow
      }
      if ($null -ne $mainHandleRootElement) {
        $windowFound = $true
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_MAIN_WINDOW=selection:main-handle-root;root-windows:$([Math]::Min($rootWindowCount, 9999));uia-owned-windows:$([Math]::Min($ownedWindowCount, 9999));main-handle:available;filter-menu:absent"
        )
        return $mainHandleRootElement
      }
      if ($null -ne $mainWindowHandleElement) {
        $windowFound = $true
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_MAIN_WINDOW=selection:from-handle;root-windows:$([Math]::Min($rootWindowCount, 9999));uia-owned-windows:$([Math]::Min($ownedWindowCount, 9999));main-handle:available;filter-menu:absent"
        )
        return $mainWindowHandleElement
      }
      if ($null -ne $firstOwnedWindow) {
        $windowFound = $true
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_MAIN_WINDOW=selection:first-owned;root-windows:$([Math]::Min($rootWindowCount, 9999));uia-owned-windows:$([Math]::Min($ownedWindowCount, 9999));main-handle:$(if ($mainHandleAvailable) { 'available' } else { 'unavailable' });filter-menu:absent"
        )
        return $firstOwnedWindow
      }
      $scanPhase = "wait"
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $scanPhase = "foreground-owner"
    $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
    if ($foregroundHandle -ne [IntPtr]::Zero) {
      $foregroundOwner = if (
        [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle) -eq $Process.Id
      ) { "same" } else { "other" }
    }
  } finally {
    if (-not $windowFound) {
      $stageClass = if ($script:stage -eq "find-reloaded-main-window") {
        "reload"
      } else {
        "initial"
      }
      [Console]::Out.WriteLine(
        "PROC_MON_FILTER_WINDOW_SCAN=stage:$stageClass;phase:$scanPhase;process-exited:$($processExited.ToString().ToLowerInvariant());root-windows:$([Math]::Min($rootWindowCount, 9999));uia-owned-windows:$([Math]::Min($ownedWindowCount, 9999));main-handle:$(if ($mainHandleAvailable) { 'available' } else { 'unavailable' });foreground-owner:$foregroundOwner"
      )
    }
  }
  if ($processExited) {
    throw "Process Monitor exited before its configuration window became available"
  }
  throw "Process Monitor did not expose its configuration window"
}

function Set-VerifiedProcmonMainWindowForeground(
  [System.Windows.Automation.AutomationElement]$Window,
  [System.Diagnostics.Process]$Process,
  [ValidateSet("MAIN", "RELOAD_MAIN")][string]$DiagnosticName
) {
  $windowHandle = [IntPtr]$Window.Current.NativeWindowHandle
  $foregroundGate = "failed"
  if (
    $Window.Current.ProcessId -eq $Process.Id -and
    $windowHandle -ne [IntPtr]::Zero -and
    [ProcmonNativeMenu]::GetWindowProcessId($windowHandle) -eq $Process.Id
  ) {
    [ProcmonNativeMenu]::SetForegroundWindow($windowHandle) | Out-Null
    $foregroundDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
      if (
        $foregroundHandle -eq $windowHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle) -eq $Process.Id
      ) {
        $foregroundGate = "passed"
        break
      }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $foregroundDeadline)
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_${DiagnosticName}_FOREGROUND=gate:$foregroundGate"
  )
  if ($foregroundGate -ne "passed") {
    throw "Process Monitor $DiagnosticName window did not become the foreground window"
  }
}

function Open-FilterDialogByShortcut(
  [System.Windows.Automation.AutomationElement]$MainWindow,
  [System.Diagnostics.Process]$Process
) {
  Set-Stage "fallback-open-filter-dialog-shortcut"
  Set-VerifiedProcmonMainWindowForeground $MainWindow $Process "MAIN"
  $mainWindowHandle = [IntPtr]$MainWindow.Current.NativeWindowHandle
  $currentForegroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
  $shortcutForegroundGate = if (
    $currentForegroundHandle -eq $mainWindowHandle -and
    [ProcmonNativeMenu]::GetWindowProcessId($currentForegroundHandle) -eq $Process.Id
  ) { "passed" } else { "failed" }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SHORTCUT_FOREGROUND=gate:$shortcutForegroundGate"
  )
  if ($shortcutForegroundGate -ne "passed") {
    throw "Process Monitor main window lost foreground before the Filter shortcut"
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MENU_OPEN_FALLBACK=filter-dialog-shortcut"
  )
  Write-ShortcutGuiFocusObservation "before" $Process $mainWindowHandle
  $shortcutInput = [ProcmonNativeMenu]::SendControlLShortcut(
    $mainWindowHandle,
    $Process.Id
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SHORTCUT_INPUT=state:$($shortcutInput.State);events:$($shortcutInput.Events);release-events:$($shortcutInput.ReleaseEvents)"
  )
  if ($shortcutInput.State -ne "sent" -or $shortcutInput.Events -ne 4) {
    throw "Process Monitor filter shortcut input failed"
  }
  Write-ShortcutGuiFocusObservation "after" $Process $mainWindowHandle
  Write-FocusObservation "after-filter-dialog-shortcut" | Out-Null
  Write-FocusOwnerObservation "after-filter-dialog-shortcut" $Process $MainWindow
  Set-Stage "wait-filter-dialog-shortcut"
  Wait-FilterDialog $Process $MainWindow
}

function Wait-ProcessMenu(
  [System.Diagnostics.Process]$Process,
  [int]$TimeoutSeconds = 5
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $menuCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Menu
  )
  $ownedWindowCount = 0
  $menuCount = 0
  $visibleMenuCount = 0
  $menus = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  do {
    $rootMenus = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $menuCondition
    )
    if ($rootMenus.Count -gt 256) {
      throw "Process Monitor menu scan exceeded the bounded menu limit"
    }
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    if ($windows.Count -gt 128) {
      throw "Process Monitor menu scan exceeded the bounded window limit"
    }
    $seenHandles = [System.Collections.Generic.HashSet[int]]::new()
    $seenMenuRuntimeIds = [System.Collections.Generic.HashSet[string]]::new()
    $menus.Clear()
    $ownedWindowCount = 0
    $menuCount = $rootMenus.Count
    $visibleMenuCount = 0
    foreach ($menu in $rootMenus) {
      $menuState = $menu.Current
      if (
        $menuState.ProcessId -eq $Process.Id -and
        $menuState.IsEnabled -and
        -not $menuState.IsOffscreen
      ) {
        $runtimeId = $menu.GetRuntimeId() -join ","
        if ([string]::IsNullOrWhiteSpace($runtimeId)) {
          throw "Process Monitor menu did not expose a runtime identifier"
        }
        if ($seenMenuRuntimeIds.Add($runtimeId)) {
          $menus.Add($menu)
          $visibleMenuCount++
        }
      }
    }
    foreach ($window in $windows) {
      $windowState = $window.Current
      if (
        $windowState.ProcessId -ne $Process.Id -or
        $windowState.NativeWindowHandle -eq 0 -or
        -not $seenHandles.Add($windowState.NativeWindowHandle)
      ) {
        continue
      }
      $ownedWindowCount++
      $windowMenus = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $menuCondition
      )
      $menuCount += $windowMenus.Count
      if ($menuCount -gt 256) {
        throw "Process Monitor menu scan exceeded the bounded menu limit"
      }
      foreach ($menu in $windowMenus) {
        $menuState = $menu.Current
        if (
          $menuState.ProcessId -eq $Process.Id -and
          $menuState.IsEnabled -and
          -not $menuState.IsOffscreen
        ) {
          $runtimeId = $menu.GetRuntimeId() -join ","
          if ([string]::IsNullOrWhiteSpace($runtimeId)) {
            throw "Process Monitor menu did not expose a runtime identifier"
          }
          if ($seenMenuRuntimeIds.Add($runtimeId)) {
            $menus.Add($menu)
            $visibleMenuCount++
          }
        }
      }
    }
    if ($menus.Count -eq 1) {
      return [pscustomobject]@{
        Menu = $menus[0]
        Windows = [Math]::Min($ownedWindowCount, 9999)
        Menus = [Math]::Min($menuCount, 9999)
        VisibleMenus = [Math]::Min($visibleMenuCount, 9999)
      }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RELOAD_MENU_SCAN=windows:$([Math]::Min($ownedWindowCount, 9999));menus:$([Math]::Min($menuCount, 9999));visible:$([Math]::Min($visibleMenuCount, 9999))"
  )
  throw "Process Monitor did not expose one visible menu in its own windows"
}

function Wait-FilterDialog([System.Diagnostics.Process]$Process, [System.Windows.Automation.AutomationElement]$MainWindow, [int]$TimeoutSeconds = 10) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $processWindowCount = 0
  $nonMainWindowCount = 0
  $resetControlPresent = $false
  $desktopResetOwner = "none"
  $desktopResetTree = [System.Collections.Generic.List[string]]::new()
  $mainResetPresent = $false
  $embeddedWindowCount = 0
  $embeddedOwnedWindowCount = 0
  $embeddedWindowHandleCount = 0
  $embeddedDistinctRuntimeIdCount = 0
  $embeddedResetCount = 0
  $embeddedLayoutCount = 0
  $embeddedMaxItemCount = 0
  $embeddedMaxComboCount = 0
  $embeddedMaxEditCount = 0
  $embeddedMaxButtonCount = 0
  $embeddedMaxTextCount = 0
  $embeddedMaxCustomCount = 0
  $embeddedMaxPaneCount = 0
  $embeddedMaxWindowCount = 0
  $embeddedMaxMenuCount = 0
  $embeddedMaxMenuItemCount = 0
  $embeddedMaxToolbarCount = 0
  $embeddedMaxOtherCount = 0
  $embeddedItemsTruncated = $false
  $focusedWindowCount = 0
  $focusedOwnedWindowCount = 0
  $focusedWindowHandleCount = 0
  $focusedNativeOwnerCount = 0
  $focusedDistinctRuntimeIdCount = 0
  $focusedResetCount = 0
  $focusedMaxComboCount = 0
  $focusedMaxEditCount = 0
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $resetCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    "Reset"
  )
  do {
    $embeddedWindowCount = 0
    $embeddedOwnedWindowCount = 0
    $embeddedWindowHandleCount = 0
    $embeddedDistinctRuntimeIdCount = 0
    $embeddedResetCount = 0
    $embeddedLayoutCount = 0
    $embeddedMaxItemCount = 0
    $embeddedMaxComboCount = 0
    $embeddedMaxEditCount = 0
    $embeddedMaxButtonCount = 0
    $embeddedMaxTextCount = 0
    $embeddedMaxCustomCount = 0
    $embeddedMaxPaneCount = 0
    $embeddedMaxWindowCount = 0
    $embeddedMaxMenuCount = 0
    $embeddedMaxMenuItemCount = 0
    $embeddedMaxToolbarCount = 0
    $embeddedMaxOtherCount = 0
    $embeddedItemsTruncated = $false
    $focusedWindowCount = 0
    $focusedOwnedWindowCount = 0
    $focusedWindowHandleCount = 0
    $focusedNativeOwnerCount = 0
    $focusedDistinctRuntimeIdCount = 0
    $focusedResetCount = 0
    $focusedMaxComboCount = 0
    $focusedMaxEditCount = 0
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    $processWindowCount = 0
    $nonMainWindowCount = 0
    $resetControlPresent = $false
    foreach ($window in $windows) {
      if ($window.Current.ProcessId -ne $Process.Id) {
        continue
      }
      $processWindowCount++
      if ($window.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        continue
      }
      $nonMainWindowCount++
      if ($null -ne $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)) {
        $resetControlPresent = $true
        return $window
      }
    }
    $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
    $focusedTreeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    for ($level = 0; $null -ne $focusedElement -and $level -lt 8; $level++) {
      $focusedState = $focusedElement.Current
      $focusedHandle = [IntPtr]$focusedState.NativeWindowHandle
      if ($focusedState.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
        $focusedWindowCount++
        if ($focusedState.ProcessId -eq $Process.Id) {
          $focusedOwnedWindowCount++
        }
      }
      if (
        $focusedState.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
        $focusedState.ProcessId -eq $Process.Id -and
        $focusedHandle -ne [IntPtr]::Zero
      ) {
        $focusedWindowHandleCount++
      }
      if (
        $focusedState.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
        $focusedState.ProcessId -eq $Process.Id -and
        $focusedHandle -ne [IntPtr]::Zero -and
        $focusedHandle -ne [IntPtr]$MainWindow.Current.NativeWindowHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($focusedHandle) -eq $Process.Id
      ) {
        $focusedNativeOwnerCount++
        $focusedRuntimeId = $focusedElement.GetRuntimeId() -join ","
        $mainRuntimeId = $MainWindow.GetRuntimeId() -join ","
        if ($focusedRuntimeId -cne $mainRuntimeId) {
          $focusedDistinctRuntimeIdCount++
        }
        $focusedCombos = $focusedElement.FindAll(
          [System.Windows.Automation.TreeScope]::Descendants,
          [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ComboBox
          )
        )
        $focusedEdits = $focusedElement.FindAll(
          [System.Windows.Automation.TreeScope]::Descendants,
          [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit
          )
        )
        $focusedMaxComboCount = [Math]::Max($focusedMaxComboCount, $focusedCombos.Count)
        $focusedMaxEditCount = [Math]::Max($focusedMaxEditCount, $focusedEdits.Count)
        $focusedReset = $focusedElement.FindFirst(
          [System.Windows.Automation.TreeScope]::Descendants,
          $resetCondition
        )
        if ($null -ne $focusedReset) {
          $focusedResetCount++
          if ($focusedCombos.Count -ge 3 -and $focusedEdits.Count -ge 1) {
            $comboCount = [Math]::Min($focusedCombos.Count, 9999)
            $editCount = [Math]::Min($focusedEdits.Count, 9999)
            [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=focused-window")
            [Console]::Out.WriteLine(
              "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$comboCount;edits:$editCount"
            )
            return $focusedElement
          }
        }
      }
      $focusedElement = $focusedTreeWalker.GetParent($focusedElement)
    }
    $mainReset = $MainWindow.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $resetCondition
    )
    if ($null -ne $mainReset) {
      $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $candidateWindow = $mainReset
      for ($level = 0; $null -ne $candidateWindow -and $level -lt 8; $level++) {
        $candidateState = $candidateWindow.Current
        if ($candidateState.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
          $embeddedWindowCount++
          if ($candidateState.ProcessId -eq $Process.Id) {
            $embeddedOwnedWindowCount++
          }
          if (
            $candidateState.ProcessId -eq $Process.Id -and
            $candidateState.NativeWindowHandle -ne 0
          ) {
            $embeddedWindowHandleCount++
            $candidateRuntimeId = $candidateWindow.GetRuntimeId() -join ","
            $mainRuntimeId = $MainWindow.GetRuntimeId() -join ","
            $distinctRuntimeId = $candidateRuntimeId -cne $mainRuntimeId
            if ($distinctRuntimeId) {
              $embeddedDistinctRuntimeIdCount++
            }
            $candidateReset = $candidateWindow.FindFirst(
              [System.Windows.Automation.TreeScope]::Descendants,
              $resetCondition
            )
            if ($null -ne $candidateReset) {
              $embeddedResetCount++
              $candidateItems = $candidateWindow.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
              )
              $candidateComboCount = 0
              $candidateEditCount = 0
              $candidateButtonCount = 0
              $candidateTextCount = 0
              $candidateCustomCount = 0
              $candidatePaneCount = 0
              $candidateWindowCount = 0
              $candidateMenuCount = 0
              $candidateMenuItemCount = 0
              $candidateToolbarCount = 0
              $candidateOtherCount = 0
              $candidateItemCount = [Math]::Min($candidateItems.Count, 1024)
              if ($candidateItems.Count -gt 1024) {
                $embeddedItemsTruncated = $true
              }
              for ($itemIndex = 0; $itemIndex -lt $candidateItemCount; $itemIndex++) {
                $itemControlType = $candidateItems[$itemIndex].Current.ControlType.ProgrammaticName
                switch ($itemControlType) {
                  "ControlType.ComboBox" { $candidateComboCount++ }
                  "ControlType.Edit" { $candidateEditCount++ }
                  "ControlType.Button" { $candidateButtonCount++ }
                  "ControlType.Text" { $candidateTextCount++ }
                  "ControlType.Custom" { $candidateCustomCount++ }
                  "ControlType.Pane" { $candidatePaneCount++ }
                  "ControlType.Window" { $candidateWindowCount++ }
                  "ControlType.Menu" { $candidateMenuCount++ }
                  "ControlType.MenuItem" { $candidateMenuItemCount++ }
                  "ControlType.ToolBar" { $candidateToolbarCount++ }
                  default { $candidateOtherCount++ }
                }
              }
              $embeddedMaxItemCount = [Math]::Max($embeddedMaxItemCount, $candidateItemCount)
              $embeddedMaxComboCount = [Math]::Max($embeddedMaxComboCount, $candidateComboCount)
              $embeddedMaxEditCount = [Math]::Max($embeddedMaxEditCount, $candidateEditCount)
              $embeddedMaxButtonCount = [Math]::Max($embeddedMaxButtonCount, $candidateButtonCount)
              $embeddedMaxTextCount = [Math]::Max($embeddedMaxTextCount, $candidateTextCount)
              $embeddedMaxCustomCount = [Math]::Max($embeddedMaxCustomCount, $candidateCustomCount)
              $embeddedMaxPaneCount = [Math]::Max($embeddedMaxPaneCount, $candidatePaneCount)
              $embeddedMaxWindowCount = [Math]::Max($embeddedMaxWindowCount, $candidateWindowCount)
              $embeddedMaxMenuCount = [Math]::Max($embeddedMaxMenuCount, $candidateMenuCount)
              $embeddedMaxMenuItemCount = [Math]::Max($embeddedMaxMenuItemCount, $candidateMenuItemCount)
              $embeddedMaxToolbarCount = [Math]::Max($embeddedMaxToolbarCount, $candidateToolbarCount)
              $embeddedMaxOtherCount = [Math]::Max($embeddedMaxOtherCount, $candidateOtherCount)
              $hasEmbeddedLayout = $candidateComboCount -ge 3 -and $candidateEditCount -ge 1
              if ($hasEmbeddedLayout) {
                $embeddedLayoutCount++
              }
              if (
                $distinctRuntimeId -and
                $hasEmbeddedLayout
              ) {
                $comboCount = [Math]::Min($candidateComboCount, 9999)
                $editCount = [Math]::Min($candidateEditCount, 9999)
                [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=embedded-window")
                [Console]::Out.WriteLine(
                  "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$comboCount;edits:$editCount"
                )
                return $candidateWindow
              }
            }
          }
        }
        $candidateWindow = $treeWalker.GetParent($candidateWindow)
      }
      $mainResetPresent = $true
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_FOCUS_SCAN=windows:$([Math]::Min($focusedWindowCount, 9999));owned:$([Math]::Min($focusedOwnedWindowCount, 9999));handled:$([Math]::Min($focusedWindowHandleCount, 9999));native-owned:$([Math]::Min($focusedNativeOwnerCount, 9999));distinct-runtime-id:$([Math]::Min($focusedDistinctRuntimeIdCount, 9999));reset:$([Math]::Min($focusedResetCount, 9999));max-combos:$([Math]::Min($focusedMaxComboCount, 9999));max-edits:$([Math]::Min($focusedMaxEditCount, 9999))"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_EMBEDDED_SCAN=main-reset:$($mainResetPresent.ToString().ToLowerInvariant());windows:$([Math]::Min($embeddedWindowCount, 9999));owned:$([Math]::Min($embeddedOwnedWindowCount, 9999));handled:$([Math]::Min($embeddedWindowHandleCount, 9999));distinct-runtime-id:$([Math]::Min($embeddedDistinctRuntimeIdCount, 9999));reset:$([Math]::Min($embeddedResetCount, 9999));layout:$([Math]::Min($embeddedLayoutCount, 9999));max-items:$embeddedMaxItemCount;max-combos:$embeddedMaxComboCount;max-edits:$embeddedMaxEditCount;max-buttons:$embeddedMaxButtonCount;max-texts:$embeddedMaxTextCount;max-custom:$embeddedMaxCustomCount;max-panes:$embeddedMaxPaneCount;max-windows:$embeddedMaxWindowCount;max-menus:$embeddedMaxMenuCount;max-menu-items:$embeddedMaxMenuItemCount;max-toolbars:$embeddedMaxToolbarCount;max-other:$embeddedMaxOtherCount;items-truncated:$($embeddedItemsTruncated.ToString().ToLowerInvariant())"
  )
  foreach ($window in $windows) {
    $reset = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)
    if ($null -ne $reset) {
      if ($window.Current.ProcessId -ne $Process.Id) {
        $desktopResetOwner = "other-process"
      } elseif ($window.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        $desktopResetOwner = "procmon-main"
      } else {
        $desktopResetOwner = "procmon-other"
      }
      $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $treeNode = $reset
      for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
        $desktopResetTree.Add((Get-ControlTypeLabel $treeNode))
        $treeNode = $treeWalker.GetParent($treeNode)
      }
      break
    }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_SCAN=process-windows:$processWindowCount;non-main-windows:$nonMainWindowCount;reset-control:$($resetControlPresent.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_DESKTOP_RESET_OWNER=$desktopResetOwner"
  )
  if ($desktopResetTree.Count -gt 0) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_RESET_TREE=$($desktopResetTree -join '>')")
  }
  $nativeFilterDialog = Find-ProcmonNativeFilterDialog `
    $Process ([IntPtr]$MainWindow.Current.NativeWindowHandle)
  if ($null -ne $nativeFilterDialog) {
    return $nativeFilterDialog
  }
  throw "Process Monitor filter dialog did not expose its Reset control"
}

function Close-ReloadedFilterDialog($Dialog, $MainWindow, [int]$OwnerProcessId) {
  Set-Stage "validate-reloaded-filter-dialog-close"
  $dialogState = $Dialog.Current
  $mainState = $MainWindow.Current
  $dialogHandle = [IntPtr]$dialogState.NativeWindowHandle
  $mainHandle = [IntPtr]$mainState.NativeWindowHandle
  if (
    $dialogState.ProcessId -ne $OwnerProcessId -or
    $mainState.ProcessId -ne $OwnerProcessId -or
    $dialogHandle -eq [IntPtr]::Zero -or
    $mainHandle -eq [IntPtr]::Zero -or
    $dialogHandle -eq $mainHandle -or
    [ProcmonNativeMenu]::GetWindowProcessId($dialogHandle) -ne $OwnerProcessId -or
    [ProcmonNativeMenu]::GetWindowProcessId($mainHandle) -ne $OwnerProcessId -or
    -not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle) -or
    -not $dialogState.IsEnabled -or $dialogState.IsOffscreen
  ) {
    throw "Process Monitor reloaded filter dialog cannot be closed safely"
  }
  if ($null -ne (Get-ProcmonNativeFilterDialogControls $Dialog $OwnerProcessId)) {
    Set-Stage "close-reloaded-native-filter-dialog"
    Invoke-ProcmonNativeFilterButton $Dialog $OwnerProcessId "Cancel"
    Set-Stage "wait-reloaded-native-filter-dialog-closed"
    $nativeCloseDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      if (-not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) { break }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $nativeCloseDeadline)
    if ([ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) {
      [Console]::Out.WriteLine("PROC_MON_FILTER_RELOAD_DIALOG_CLOSED=gate:failed")
      throw "Process Monitor reloaded filter dialog remained visible after Cancel"
    }
    Set-Stage "restore-reloaded-main-window"
    [ProcmonNativeMenu]::SetForegroundWindow($mainHandle) | Out-Null
    $nativeCloseDeadline = [DateTime]::UtcNow.AddSeconds(2)
    $nativeCloseGate = "failed"
    do {
      if (
        [ProcmonNativeMenu]::GetForegroundWindow() -eq $mainHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($mainHandle) -eq $OwnerProcessId -and
        -not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle)
      ) {
        $nativeCloseGate = "passed"
        break
      }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $nativeCloseDeadline)
    [Console]::Out.WriteLine("PROC_MON_FILTER_RELOAD_DIALOG_CLOSED=gate:$nativeCloseGate")
    if ($nativeCloseGate -ne "passed") {
      throw "Process Monitor main window was not restored after closing the reloaded filter dialog"
    }
    return
  }
  Set-Stage "close-reloaded-filter-dialog"
  $windowPattern = $Dialog.GetCurrentPattern(
    [System.Windows.Automation.WindowPattern]::Pattern
  )
  $windowPattern.Close()
  Set-Stage "wait-reloaded-filter-dialog-closed"
  $deadline = [DateTime]::UtcNow.AddSeconds(2)
  do {
    if (-not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) { break }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  if ([ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_RELOAD_DIALOG_CLOSED=gate:failed")
    throw "Process Monitor reloaded filter dialog remained visible after Close"
  }
  Set-Stage "restore-reloaded-main-window"
  [ProcmonNativeMenu]::SetForegroundWindow($mainHandle) | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds(2)
  $gate = "failed"
  do {
    $currentMainState = $MainWindow.Current
    if (
      $currentMainState.ProcessId -eq $OwnerProcessId -and
      $currentMainState.IsEnabled -and -not $currentMainState.IsOffscreen -and
      [ProcmonNativeMenu]::GetForegroundWindow() -eq $mainHandle -and
      [ProcmonNativeMenu]::GetWindowProcessId($mainHandle) -eq $OwnerProcessId -and
      -not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle)
    ) {
      $gate = "passed"
      break
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  [Console]::Out.WriteLine("PROC_MON_FILTER_RELOAD_DIALOG_CLOSED=gate:$gate")
  if ($gate -ne "passed") {
    throw "Process Monitor main window was not restored after closing the reloaded filter dialog"
  }
}

function Find-NativeDropMenuItem([System.IntPtr]$MenuHandle, [int]$Depth) {
  if ($Depth -gt 4 -or $script:nativeMenuVisited -ge 256) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = if ($Depth -gt 4) { "depth-limit" } else { "total-limit" }
    }
    return
  }
  Set-Stage "invoke-native-menu-count"
  $itemCount = [ProcmonNativeMenu]::GetMenuItemCount($MenuHandle)
  Set-Stage "classify-native-menu-count"
  if ($itemCount -lt 0) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = if ($itemCount -eq -2) {
        "invalid-menu-handle"
      } elseif ($itemCount -eq -3) {
        "menu-count-invalid"
      } else {
        "menu-count-failed"
      }
    }
    return
  }
  if ($itemCount -gt 64) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = "menu-count-limit"
    }
    return
  }
  for ($position = 0; $position -lt $itemCount; $position++) {
    if ($script:nativeMenuVisited -ge 256) {
      $script:nativeMenuReadable = $false
      if ($script:nativeMenuFailure -eq "none") {
        $script:nativeMenuFailure = "total-limit"
      }
      return
    }
    $ownerDrawn = $false
    $item = [ProcmonNativeMenu]::ReadItem(
      $MenuHandle,
      [uint32]$position,
      [ref]$ownerDrawn
    )
    if ($null -eq $item) {
      $script:nativeMenuReadable = $false
      if ($script:nativeMenuFailure -eq "none") {
        $script:nativeMenuFailure = if ($ownerDrawn) { "owner-drawn" } else { "item-read-failed" }
      }
      continue
    }
    $script:nativeMenuVisited++
    $itemName = $item.Text.Replace("&", "")
    $acceleratorIndex = $itemName.IndexOf("`t")
    if ($acceleratorIndex -ge 0) {
      $itemName = $itemName.Substring(0, $acceleratorIndex)
    }
    $itemName = $itemName.Trim()
    if ([string]::Equals(
        $itemName,
        "Drop Filtered Events",
        [System.StringComparison]::Ordinal
      )) {
      $script:nativeDropMenuMatches.Add([pscustomobject]@{
        IsChecked = [bool]$item.IsChecked
        IsEnabled = [bool]$item.IsEnabled
      })
    }
    if (-not $item.Submenu.Equals([System.IntPtr]::Zero)) {
      Find-NativeDropMenuItem $item.Submenu ($Depth + 1)
    }
  }
}

function Get-NativeMenuItemSnapshot(
  [System.IntPtr]$MenuHandle,
  [string]$ExpectedName
) {
  if ($MenuHandle.Equals([System.IntPtr]::Zero)) {
    throw "Process Monitor native menu handle was unavailable"
  }
  $itemCount = [ProcmonNativeMenu]::GetMenuItemCount($MenuHandle)
  if ($itemCount -lt 0) {
    throw "Process Monitor native menu count could not be read"
  }
  if ($itemCount -gt 64) {
    throw "Process Monitor native menu exceeded the bounded item limit"
  }
  $matchedItems = [System.Collections.Generic.List[object]]::new()
  for ($position = 0; $position -lt $itemCount; $position++) {
    if ($script:nativeMenuVisited -ge 256) {
      throw "Process Monitor native menu exceeded the bounded traversal limit"
    }
    $ownerDrawn = $false
    $item = [ProcmonNativeMenu]::ReadItem(
      $MenuHandle,
      [uint32]$position,
      [ref]$ownerDrawn
    )
    if ($null -eq $item) {
      throw "Process Monitor native menu item could not be read"
    }
    $script:nativeMenuVisited++
    $itemName = $item.Text.Replace("&", "")
    $acceleratorIndex = $itemName.IndexOf("`t")
    if ($acceleratorIndex -ge 0) {
      $itemName = $itemName.Substring(0, $acceleratorIndex)
    }
    if ([string]::Equals(
        $itemName.Trim(),
        $ExpectedName,
        [System.StringComparison]::Ordinal
      )) {
      $matchedItems.Add($item)
    }
  }
  [pscustomobject]@{
    ItemCount = $itemCount
    MatchCount = $matchedItems.Count
    Item = if ($matchedItems.Count -eq 1) { $matchedItems[0] } else { $null }
  }
}

function Write-ProcmonNativeMenuSummary(
  [System.IntPtr[]]$WindowHandles,
  [System.Diagnostics.Process]$Process,
  [ValidateSet("main", "focused-root", "all-top-level")][string]$Source = "main"
) {
  $state = "ready"
  $menus = 0
  $items = 0
  $eventMatches = 0
  $filterMatches = 0
  $filterCommandMatches = 0
  $unreadableItems = 0
  if ($null -eq $WindowHandles -or $WindowHandles.Length -gt 257) {
    $state = "over-limit"
  } else {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $seenMenus = [System.Collections.Generic.HashSet[IntPtr]]::new()
    foreach ($windowHandle in $WindowHandles) {
      if ([IntPtr]$windowHandle -eq [IntPtr]::Zero) {
        continue
      }
      if ([ProcmonNativeMenu]::GetWindowProcessId($windowHandle) -ne $Process.Id) {
        $state = "owner-mismatch"
        break
      }
      $rootMenu = [ProcmonNativeMenu]::GetMenu($windowHandle)
      if ($rootMenu -ne [IntPtr]::Zero) {
        $queue.Enqueue(@{ Handle = $rootMenu; Depth = 0 })
      }
    }
    if ($state -eq "ready" -and $queue.Count -eq 0) {
      $state = "unavailable"
    }
    if ($state -eq "ready") {
      while ($queue.Count -gt 0) {
        if ($menus -ge 32) {
          $state = "over-limit"
          break
        }
        $candidate = $queue.Dequeue()
        if (-not $seenMenus.Add([IntPtr]$candidate.Handle)) {
          continue
        }
        $menus++
        $itemCount = [ProcmonNativeMenu]::GetMenuItemCount([IntPtr]$candidate.Handle)
        if ($itemCount -lt 0) {
          $unreadableItems++
          continue
        }
        if ($itemCount -gt 64 -or $items + $itemCount -gt 256) {
          $state = "over-limit"
          break
        }
        $items += $itemCount
        for ($position = 0; $position -lt $itemCount; $position++) {
          $ownerDrawn = $false
          $item = [ProcmonNativeMenu]::ReadItem(
            [IntPtr]$candidate.Handle,
            [uint32]$position,
            [ref]$ownerDrawn
          )
          if ($null -eq $item) {
            $unreadableItems++
            continue
          }
          $itemName = $item.Text.Replace("&", "")
          $acceleratorIndex = $itemName.IndexOf("`t")
          if ($acceleratorIndex -ge 0) {
            $itemName = $itemName.Substring(0, $acceleratorIndex)
          }
          switch ($itemName.Trim()) {
            "Event" { $eventMatches++ }
            "Filter" { $filterMatches++ }
            "Filter..." { $filterCommandMatches++ }
          }
          if (
            $candidate.Depth -lt 2 -and
            $item.Submenu -ne [IntPtr]::Zero -and
            $queue.Count -lt 64
          ) {
            $queue.Enqueue(@{
              Handle = $item.Submenu
              Depth = $candidate.Depth + 1
            })
          } elseif (
            $candidate.Depth -lt 2 -and
            $item.Submenu -ne [IntPtr]::Zero
          ) {
            $state = "over-limit"
            break
          }
        }
        if ($state -eq "over-limit") {
          break
        }
      }
      if ($state -eq "ready" -and $unreadableItems -gt 0) {
        $state = "partial"
      }
    }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_MENU=source:$Source;state:$state;menus:$([Math]::Min($menus, 99));items:$([Math]::Min($items, 999));event:$([Math]::Min($eventMatches, 99));filter:$([Math]::Min($filterMatches, 99));filter-command:$([Math]::Min($filterCommandMatches, 99));unreadable:$([Math]::Min($unreadableItems, 999))"
  )
}

function Write-ProcmonAccessibleMenuSummary(
  [IntPtr[]]$WindowHandles,
  [System.Diagnostics.Process]$Process
) {
  $menuWindowCount = 0
  $readableWindowCount = 0
  $unreadableWindowCount = 0
  $itemCount = 0
  $eventCount = 0
  $filterCount = 0
  $filterCommandCount = 0
  $windowLimit = [Math]::Min($WindowHandles.Length, 256)
  $truncated = $WindowHandles.Length -gt 256
  for ($index = 0; $index -lt $windowLimit; $index++) {
    $handle = [IntPtr]$WindowHandles[$index]
    if ([ProcmonNativeMenu]::GetMenu($handle) -eq [IntPtr]::Zero) {
      continue
    }
    $menuWindowCount++
    $snapshot = [ProcmonNativeMenu]::ReadAccessibleFilterMenuSummary(
      $handle,
      [uint32]$Process.Id
    )
    if (-not $snapshot.ProcessSame -or -not $snapshot.AccessibleAvailable -or $snapshot.ReadFailure -ne "none") {
      $unreadableWindowCount++
      continue
    }
    $readableWindowCount++
    $itemCount += $snapshot.ItemCount
    $eventCount += $snapshot.EventCount
    $filterCount += $snapshot.FilterCount
    $filterCommandCount += $snapshot.FilterCommandCount
  }
  $state = if ($menuWindowCount -eq 0) {
    "unavailable"
  } elseif ($unreadableWindowCount -gt 0) {
    "partial"
  } else {
    "ready"
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_ACCESSIBLE_MENU=state:$state;windows:$menuWindowCount;readable:$readableWindowCount;unreadable:$unreadableWindowCount;items:$itemCount;event:$eventCount;filter:$filterCount;filter-command:$filterCommandCount;truncated:$($truncated.ToString().ToLowerInvariant())"
  )
}

function Get-ProcmonRawUiaSummary(
  [System.Windows.Automation.AutomationElement]$Root,
  [int]$ProcessId
) {
  $maximumNodes = 512
  $maximumDepth = 16
  $nodes = 0
  $windows = 0
  $panes = 0
  $combos = 0
  $edits = 0
  $buttons = 0
  $menus = 0
  $menuItems = 0
  $other = 0
  $truncated = $false
  $readFailed = $false
  $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $pending = [System.Collections.Generic.Queue[object]]::new()
  $pending.Enqueue([pscustomobject]@{ Element = $Root; Depth = 0 })
  try {
    while ($pending.Count -gt 0) {
      if ($nodes -ge $maximumNodes) {
        $truncated = $true
        break
      }
      $entry = $pending.Dequeue()
      $state = $entry.Element.Current
      if ($state.ProcessId -ne $ProcessId) {
        continue
      }
      $nodes++
      switch ($state.ControlType.ProgrammaticName) {
        "ControlType.Window" { $windows++ }
        "ControlType.Pane" { $panes++ }
        "ControlType.ComboBox" { $combos++ }
        "ControlType.Edit" { $edits++ }
        "ControlType.Button" { $buttons++ }
        "ControlType.Menu" { $menus++ }
        "ControlType.MenuItem" { $menuItems++ }
        default { $other++ }
      }
      $child = $walker.GetFirstChild($entry.Element)
      if ($null -eq $child) {
        continue
      }
      if ($entry.Depth -ge $maximumDepth) {
        $truncated = $true
        break
      }
      do {
        if ($pending.Count + $nodes -ge $maximumNodes) {
          $truncated = $true
          break
        }
        $pending.Enqueue([pscustomobject]@{
          Element = $child
          Depth = $entry.Depth + 1
        })
        $child = $walker.GetNextSibling($child)
      } while ($null -ne $child)
      if ($truncated) {
        break
      }
    }
  } catch [System.Windows.Automation.ElementNotAvailableException] {
    $readFailed = $true
  } catch [System.InvalidOperationException] {
    $readFailed = $true
  } catch [System.Runtime.InteropServices.COMException] {
    $readFailed = $true
  }
  $scanState = if ($readFailed) {
    "partial"
  } elseif ($truncated) {
    "truncated"
  } else {
    "ready"
  }
  return [pscustomobject]@{
    State = $scanState
    Nodes = $nodes
    Windows = $windows
    Panes = $panes
    Combos = $combos
    Edits = $edits
    Buttons = $buttons
    Menus = $menus
    MenuItems = $menuItems
    Other = $other
    Truncated = $truncated
  }
}

function Write-ProcmonRawUiaSummary(
  [System.Windows.Automation.AutomationElement]$Root,
  [ValidateSet("main", "visible-other")][string]$Source,
  [int]$ProcessId
) {
  $summary = Get-ProcmonRawUiaSummary $Root $ProcessId
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RAW_UIA=source:$Source;state:$($summary.State);nodes:$($summary.Nodes);windows:$($summary.Windows);panes:$($summary.Panes);combos:$($summary.Combos);edits:$($summary.Edits);buttons:$($summary.Buttons);menus:$($summary.Menus);menu-items:$($summary.MenuItems);other:$($summary.Other);truncated:$($summary.Truncated.ToString().ToLowerInvariant())"
  )
}

function Resolve-ProcmonNativeFixedButtonLabel([string]$Label) {
  if ($null -eq $Label -or $Label.Length -gt 128) {
    return $null
  }
  $normalized = $Label.Replace("&", "").Trim()
  foreach ($fixedLabel in @("Reset", "Add", "OK", "Cancel", "Remove")) {
    if ([string]::Equals(
        $normalized,
        $fixedLabel,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      return $fixedLabel
    }
  }
  return $null
}

function Write-ProcmonNativeChildSummary(
  [System.IntPtr]$Root,
  [ValidateSet("main", "visible-other")][string]$Source,
  [int]$ProcessId
) {
  $summary = [ProcmonNativeMenu]::ReadNativeChildSummary($Root, $ProcessId, 256)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_CHILDREN=source:$Source;state:$($summary.State);windows:$($summary.Windows);combos:$($summary.Combos);edits:$($summary.Edits);buttons:$($summary.Buttons);dialogs:$($summary.Dialogs);toolbars:$($summary.Toolbars);lists:$($summary.Lists);statics:$($summary.Statics);other:$($summary.Other);unreadable:$($summary.Unreadable);truncated:$($summary.Truncated.ToString().ToLowerInvariant())"
  )
  $uiaCandidates = @(
    $summary.ChildWindows | Where-Object {
      $_.Kind -in @("combo", "edit", "button", "dialog")
    }
  )
  $mapped = 0
  $uiaCombos = 0
  $uiaEdits = 0
  $uiaButtons = 0
  $uiaWindows = 0
  $uiaPanes = 0
  $uiaOther = 0
  $uiaReadFailures = 0
  $uiaPatternReadFailures = 0
  $uiaValuePatterns = 0
  $uiaSelectionPatterns = 0
  $uiaSelectionItemPatterns = 0
  $uiaExpandCollapsePatterns = 0
  $uiaInvokePatterns = 0
  $uiaTogglePatterns = 0
  $patternDefinitions = @(
    [pscustomobject]@{
      Kind = "value"
      Pattern = [System.Windows.Automation.ValuePattern]::Pattern
    },
    [pscustomobject]@{
      Kind = "selection"
      Pattern = [System.Windows.Automation.SelectionPattern]::Pattern
    },
    [pscustomobject]@{
      Kind = "selection-item"
      Pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern
    },
    [pscustomobject]@{
      Kind = "expand-collapse"
      Pattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
    },
    [pscustomobject]@{
      Kind = "invoke"
      Pattern = [System.Windows.Automation.InvokePattern]::Pattern
    },
    [pscustomobject]@{
      Kind = "toggle"
      Pattern = [System.Windows.Automation.TogglePattern]::Pattern
    }
  )
  foreach ($child in $uiaCandidates) {
    try {
      $element = [System.Windows.Automation.AutomationElement]::FromHandle($child.Handle)
      if ($null -eq $element) {
        $uiaReadFailures++
        continue
      }
      $elementState = $element.Current
      if (
        $elementState.ProcessId -ne $ProcessId -or
        [System.IntPtr]$elementState.NativeWindowHandle -ne $child.Handle
      ) {
        $uiaReadFailures++
        continue
      }
      $mapped++
      if ($elementState.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox) {
        $uiaCombos++
      } elseif ($elementState.ControlType -eq [System.Windows.Automation.ControlType]::Edit) {
        $uiaEdits++
      } elseif ($elementState.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
        $uiaButtons++
      } elseif ($elementState.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
        $uiaWindows++
      } elseif ($elementState.ControlType -eq [System.Windows.Automation.ControlType]::Pane) {
        $uiaPanes++
      } else {
        $uiaOther++
      }
      foreach ($patternDefinition in $patternDefinitions) {
        try {
          $null = $element.GetCurrentPattern($patternDefinition.Pattern)
          switch ($patternDefinition.Kind) {
            "value" { $uiaValuePatterns++ }
            "selection" { $uiaSelectionPatterns++ }
            "selection-item" { $uiaSelectionItemPatterns++ }
            "expand-collapse" { $uiaExpandCollapsePatterns++ }
            "invoke" { $uiaInvokePatterns++ }
            "toggle" { $uiaTogglePatterns++ }
          }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
          $uiaPatternReadFailures++
          break
        } catch [System.Runtime.InteropServices.COMException] {
          $uiaPatternReadFailures++
          break
        } catch [System.ArgumentException] {
          $uiaPatternReadFailures++
          break
        } catch [System.InvalidOperationException] {
          continue
        }
      }
    } catch [System.Windows.Automation.ElementNotAvailableException] {
      $uiaReadFailures++
    } catch [System.InvalidOperationException] {
      $uiaReadFailures++
    } catch [System.Runtime.InteropServices.COMException] {
      $uiaReadFailures++
    } catch [System.ArgumentException] {
      $uiaReadFailures++
    }
  }
  $uiaState = if ($summary.State -eq "root-mismatch") {
    "root-mismatch"
  } elseif (
    $summary.State -eq "partial" -or
    $uiaReadFailures -gt 0 -or
    $uiaPatternReadFailures -gt 0
  ) {
    "partial"
  } else {
    $summary.State
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_CHILD_UIA=source:$Source;state:$uiaState;candidates:$($uiaCandidates.Count);mapped:$mapped;combos:$uiaCombos;edits:$uiaEdits;buttons:$uiaButtons;windows:$uiaWindows;panes:$uiaPanes;other:$uiaOther;unreadable:$uiaReadFailures;truncated:$($summary.Truncated.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_CHILD_PATTERNS=source:$Source;state:$uiaState;candidates:$($uiaCandidates.Count);mapped:$mapped;value:$uiaValuePatterns;selection:$uiaSelectionPatterns;selection-item:$uiaSelectionItemPatterns;expand-collapse:$uiaExpandCollapsePatterns;invoke:$uiaInvokePatterns;toggle:$uiaTogglePatterns;pattern-errors:$uiaPatternReadFailures;unreadable:$uiaReadFailures;truncated:$($summary.Truncated.ToString().ToLowerInvariant())"
  )
  $nativeControlState = "ready"
  $nativeCombos = 0
  $pathOptions = 0
  $operatorOptions = 0
  $includeOptions = 0
  $nativeEdits = 0
  $readableEdits = 0
  $nativeButtons = 0
  $resetButtons = 0
  $addButtons = 0
  $okButtons = 0
  $cancelButtons = 0
  $removeButtons = 0
  $nativeLists = 0
  $nativeListItems = 0
  $nativeReadFailures = 0
  foreach ($child in $summary.ChildWindows) {
    if (-not [ProcmonNativeMenu]::IsWindowVisible($child.Handle)) {
      continue
    }
    if ([ProcmonNativeMenu]::GetWindowProcessId($child.Handle) -ne $ProcessId) {
      $nativeReadFailures++
      continue
    }
    if (-not [ProcmonNativeMenu]::IsWindowEnabled($child.Handle)) {
      continue
    }
    $childReadFailed = $false
    try {
      switch ($child.Kind) {
        "combo" {
          $nativeCombos++
          $optionCount = [ProcmonNativeMenu]::ReadNativeComboItemCount(
            $child.Handle,
            $ProcessId
          )
          if ($optionCount -gt 0) {
            [ProcmonNativeMenu]::ReadNativeControlText(
              $child.Handle,
              $ProcessId,
              "combo",
              256
            ) | Out-Null
            if ([ProcmonNativeMenu]::FindNativeComboItemExact(
                $child.Handle,
                $ProcessId,
                "Path"
              ) -ge 0) {
              $pathOptions++
            }
            if ([ProcmonNativeMenu]::FindNativeComboItemExact(
                $child.Handle,
                $ProcessId,
                "is"
              ) -ge 0) {
              $operatorOptions++
            }
            if ([ProcmonNativeMenu]::FindNativeComboItemExact(
                $child.Handle,
                $ProcessId,
                "Include"
              ) -ge 0) {
              $includeOptions++
            }
          }
        }
        "edit" {
          $nativeEdits++
          [ProcmonNativeMenu]::ReadNativeControlText(
            $child.Handle,
            $ProcessId,
            "edit",
            1024
          ) | Out-Null
          $readableEdits++
        }
        "button" {
          $nativeButtons++
          $controlText = [ProcmonNativeMenu]::ReadNativeControlText(
            $child.Handle,
            $ProcessId,
            "button",
            128
          )
          $fixedLabel = Resolve-ProcmonNativeFixedButtonLabel $controlText
          if ($fixedLabel -ceq "Reset") { $resetButtons++ }
          if ($fixedLabel -ceq "Add") { $addButtons++ }
          if ($fixedLabel -ceq "OK") { $okButtons++ }
          if ($fixedLabel -ceq "Cancel") { $cancelButtons++ }
          if ($fixedLabel -ceq "Remove") { $removeButtons++ }
        }
        "list" {
          $nativeLists++
          $listCount = [ProcmonNativeMenu]::ReadNativeListItemCount(
            $child.Handle,
            $ProcessId
          )
          if ($nativeListItems + $listCount -gt 256) {
            $childReadFailed = $true
          } else {
            $nativeListItems += $listCount
          }
        }
      }
    } catch [System.InvalidOperationException] {
      $childReadFailed = $true
    } catch [System.ArgumentException] {
      $childReadFailed = $true
    } catch [System.Runtime.InteropServices.COMException] {
      $childReadFailed = $true
    }
    if ($childReadFailed) {
      $nativeReadFailures++
    }
  }
  if ($nativeReadFailures -gt 0 -or $summary.State -ne "ready") {
    $nativeControlState = "partial"
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_CONTROLS=source:$Source;state:$nativeControlState;combos:$nativeCombos;path-options:$pathOptions;operator-options:$operatorOptions;include-options:$includeOptions;edits:$nativeEdits;readable-edits:$readableEdits;buttons:$nativeButtons;reset:$resetButtons;add:$addButtons;ok:$okButtons;cancel:$cancelButtons;remove:$removeButtons;lists:$nativeLists;list-items:$nativeListItems;read-failures:$nativeReadFailures;truncated:$($summary.Truncated.ToString().ToLowerInvariant())"
  )
}

function Get-ProcmonNativeFilterDialogControls(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$ProcessId
) {
  $script:nativeFilterControlGate = "checking"
  $dialogState = $Dialog.Current
  $root = [IntPtr]$dialogState.NativeWindowHandle
  if (
    $ProcessId -le 0 -or
    $root -eq [IntPtr]::Zero -or
    $dialogState.ProcessId -ne $ProcessId -or
    [ProcmonNativeMenu]::GetWindowProcessId($root) -ne $ProcessId -or
    -not [ProcmonNativeMenu]::IsWindowVisible($root) -or
    -not [ProcmonNativeMenu]::IsWindowEnabled($root) -or
    $dialogState.ControlType -notin @(
      [System.Windows.Automation.ControlType]::Window,
      [System.Windows.Automation.ControlType]::Pane
    )
  ) {
    throw "Process Monitor native filter dialog ownership is unavailable"
  }
  $summary = [ProcmonNativeMenu]::ReadNativeChildSummary($root, $ProcessId, 256)
  if (
    $summary.State -ne "ready" -or
    $summary.Truncated -or
    $summary.Windows -gt 256
  ) {
    throw "Process Monitor native filter dialog controls were not completely readable"
  }
  $controls = [ordered]@{
    Root = $root
    Combos = [System.Collections.Generic.List[System.IntPtr]]::new()
    Edits = [System.Collections.Generic.List[System.IntPtr]]::new()
    Buttons = [System.Collections.Generic.Dictionary[string, System.IntPtr]]::new(
      [System.StringComparer]::Ordinal
    )
    Lists = [System.Collections.Generic.List[System.IntPtr]]::new()
  }
  $allCandidateControls = [System.Collections.Generic.List[System.IntPtr]]::new()
  foreach ($child in $summary.ChildWindows) {
    if ($child.Kind -notin @("combo", "edit", "button", "list")) {
      continue
    }
    if (
      -not [ProcmonNativeMenu]::IsWindowVisible($child.Handle) -or
      (
        $child.Kind -ne "button" -and
        -not [ProcmonNativeMenu]::IsWindowEnabled($child.Handle)
      ) -or
      [ProcmonNativeMenu]::GetWindowProcessId($child.Handle) -ne $ProcessId
    ) {
      continue
    }
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($child.Handle)
    if ($null -eq $element) {
      $script:nativeFilterControlGate = "uia-unavailable"
      return $null
    }
    $elementState = $element.Current
    if (
      $elementState.ProcessId -ne $ProcessId -or
      [IntPtr]$elementState.NativeWindowHandle -ne $child.Handle -or
      $elementState.ControlType -ne [System.Windows.Automation.ControlType]::Pane
    ) {
      $script:nativeFilterControlGate = "uia-mismatch"
      return $null
    }
    foreach ($pattern in @(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [System.Windows.Automation.SelectionPattern]::Pattern,
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
        [System.Windows.Automation.InvokePattern]::Pattern,
        [System.Windows.Automation.TogglePattern]::Pattern
      )) {
      $patternObject = $null
      if ($element.TryGetCurrentPattern($pattern, [ref]$patternObject)) {
        $script:nativeFilterControlGate = "uia-pattern-available"
        return $null
      }
    }
    $allCandidateControls.Add($child.Handle)
    switch ($child.Kind) {
      "combo" { $controls.Combos.Add($child.Handle) }
      "edit" { $controls.Edits.Add($child.Handle) }
      "list" { $controls.Lists.Add($child.Handle) }
      "button" {
        $labelText = [ProcmonNativeMenu]::ReadNativeControlText(
          $child.Handle,
          $ProcessId,
          "button",
          128
        )
        $fixedLabel = Resolve-ProcmonNativeFixedButtonLabel $labelText
        if ($null -ne $fixedLabel) {
          $label = $fixedLabel
          if ($controls.Buttons.ContainsKey($label)) {
            $script:nativeFilterControlGate = "duplicate-fixed-buttons"
            throw "Process Monitor native filter dialog has duplicate fixed buttons"
          }
          $controls.Buttons.Add($label, $child.Handle)
        }
      }
    }
  }
  if (
    $controls.Combos.Count -lt 3 -or
    $controls.Combos.Count -gt 8 -or
    $controls.Edits.Count -ne 1 -or
    $controls.Lists.Count -ne 1 -or
    $allCandidateControls.Count -gt 64
  ) {
    $script:nativeFilterControlGate = "control-counts"
    return $null
  }
  foreach ($label in @("Reset", "Add", "OK", "Cancel")) {
    if (-not $controls.Buttons.ContainsKey($label)) {
      $script:nativeFilterControlGate = "fixed-buttons"
      return $null
    }
  }
  $pathCombos = @(
    $controls.Combos | Where-Object {
      [ProcmonNativeMenu]::CountNativeComboItemExact($_, $ProcessId, "Path") -eq 1
    }
  )
  $operatorCombos = @(
    $controls.Combos | Where-Object {
      [ProcmonNativeMenu]::CountNativeComboItemExact($_, $ProcessId, "is") -eq 1
    }
  )
  $includeCombos = @(
    $controls.Combos | Where-Object {
      [ProcmonNativeMenu]::CountNativeComboItemExact($_, $ProcessId, "Include") -eq 1
    }
  )
  if (
    $pathCombos.Count -ne 1 -or
    $operatorCombos.Count -ne 1 -or
    $includeCombos.Count -ne 1 -or
    $pathCombos[0] -eq $operatorCombos[0] -or
    $pathCombos[0] -eq $includeCombos[0] -or
    $operatorCombos[0] -eq $includeCombos[0]
  ) {
    $script:nativeFilterControlGate = "fixed-options"
    return $null
  }
  $columnCount = [ProcmonNativeMenu]::ReadNativeListColumnCount(
    $controls.Lists[0],
    $ProcessId
  )
  if ($columnCount -ne 4) {
    $script:nativeFilterControlGate = "list-columns"
    return $null
  }
  $controls["PathCombo"] = $pathCombos[0]
  $controls["OperatorCombo"] = $operatorCombos[0]
  $controls["IncludeCombo"] = $includeCombos[0]
  $controls["Edit"] = $controls.Edits[0]
  $controls["List"] = $controls.Lists[0]
  $controls["ColumnCount"] = $columnCount
  $script:nativeFilterControlGate = "eligible"
  return [pscustomobject]$controls
}

function Get-ProcmonNativeFilterRuleRows(
  [object]$Controls,
  [int]$ProcessId,
  [switch]$Quiet,
  [switch]$Reloaded
) {
  $count = [ProcmonNativeMenu]::ReadNativeListItemCount($Controls.List, $ProcessId)
  if ($count -gt 64) {
    throw "Process Monitor native filter list exceeded the bounded row limit"
  }
  $rows = [System.Collections.Generic.List[object]]::new()
  for ($rowIndex = 0; $rowIndex -lt $count; $rowIndex++) {
    $cells = [System.Collections.Generic.List[string]]::new()
    for ($columnIndex = 0; $columnIndex -lt 4; $columnIndex++) {
      $cell = [ProcmonNativeMenu]::ReadNativeListItemText(
        $Controls.List,
        $ProcessId,
        $rowIndex,
        $columnIndex,
        1024
      )
      if ([string]::IsNullOrWhiteSpace($cell)) {
        throw "Process Monitor native filter row contained an empty cell"
      }
      $cells.Add($cell)
    }
    $rows.Add([pscustomobject]@{
      Text = $cells -join " "
      Element = $null
      Container = $null
    })
  }
  $finalCount = [ProcmonNativeMenu]::ReadNativeListItemCount($Controls.List, $ProcessId)
  $finalColumnCount = [ProcmonNativeMenu]::ReadNativeListColumnCount(
    $Controls.List,
    $ProcessId
  )
  if ($finalCount -ne $count -or $finalColumnCount -ne 4) {
    throw "Process Monitor native filter list changed while it was being read"
  }
  $ruleCount = @(
    $rows | Where-Object {
      $_.Text -match "(?i)^Path\s+is\s+.+\s+Include$"
    }
  ).Count
  $pathCount = @(
    $rows | Where-Object { $_.Text -match "(?i)^Path\s+" }
  ).Count
  $operatorCount = @(
    $rows | Where-Object { $_.Text -match "(?i)^Path\s+is\s+" }
  ).Count
  $includeCount = @(
    $rows | Where-Object { $_.Text -match "(?i)\sInclude$" }
  ).Count
  $phase = if ($Reloaded) { "reloaded" } else { "initial" }
  if (-not $Quiet) {
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_NATIVE_RULES=phase:$phase;state:ready;rows:$count;columns:4;path:$pathCount;is:$operatorCount;include:$includeCount;exact-shape:$ruleCount;unclassified:$($count - $ruleCount);truncated:false"
    )
  }
  return ,$rows.ToArray()
}

function Invoke-ProcmonNativeFilterButton(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$ProcessId,
  [ValidateSet("Reset", "Add", "OK", "Cancel", "Remove")][string]$Label
) {
  $controls = Get-ProcmonNativeFilterDialogControls $Dialog $ProcessId
  if ($null -eq $controls -or -not $controls.Buttons.ContainsKey($Label)) {
    throw "Process Monitor native filter button could not be identified exactly"
  }
  $button = $controls.Buttons[$Label]
  if (
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $controls.Root -or
    -not [ProcmonNativeMenu]::IsWindowVisible($button) -or
    -not [ProcmonNativeMenu]::IsWindowEnabled($button) -or
    [ProcmonNativeMenu]::GetWindowProcessId($button) -ne $ProcessId
  ) {
    throw "Process Monitor native filter button is unavailable"
  }
  [ProcmonNativeMenu]::ClickNativeButtonExact($button, $ProcessId, $Label)
}

function Set-ProcmonNativeFilterCombo(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$ProcessId,
  [ValidateSet("Path", "is", "Include")][string]$Value
) {
  $controls = Get-ProcmonNativeFilterDialogControls $Dialog $ProcessId
  if ($null -eq $controls) {
    throw "Process Monitor native filter combo is unavailable"
  }
  $combo = switch ($Value) {
    "Path" { $controls.PathCombo }
    "is" { $controls.OperatorCombo }
    "Include" { $controls.IncludeCombo }
  }
  if (
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $controls.Root -or
    -not [ProcmonNativeMenu]::IsWindowVisible($combo) -or
    -not [ProcmonNativeMenu]::IsWindowEnabled($combo) -or
    [ProcmonNativeMenu]::GetWindowProcessId($combo) -ne $ProcessId
  ) {
    throw "Process Monitor native filter combo is unavailable"
  }
  [ProcmonNativeMenu]::SelectNativeComboItemExact($combo, $ProcessId, $Value)
}

function Set-ProcmonNativeFilterPath(
  [System.Windows.Automation.AutomationElement]$Dialog,
  [int]$ProcessId,
  [string]$Path
) {
  $controls = Get-ProcmonNativeFilterDialogControls $Dialog $ProcessId
  if ($null -eq $controls) {
    throw "Process Monitor native filter path field is unavailable"
  }
  $edit = $controls.Edit
  if (
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $controls.Root -or
    -not [ProcmonNativeMenu]::IsWindowVisible($edit) -or
    -not [ProcmonNativeMenu]::IsWindowEnabled($edit) -or
    [ProcmonNativeMenu]::GetWindowProcessId($edit) -ne $ProcessId
  ) {
    throw "Process Monitor native filter path field is unavailable"
  }
  [ProcmonNativeMenu]::SetNativeEditTextExact($edit, $ProcessId, $Path)
}

function Find-ProcmonNativeFilterDialog(
  [System.Diagnostics.Process]$Process,
  [System.IntPtr]$MainWindowHandle
) {
  [IntPtr[]]$handles = [ProcmonNativeMenu]::GetProcessTopLevelWindows($Process.Id, 257)
  Write-ProcmonNativeMenuSummary `
    -WindowHandles $handles `
    -Process $Process `
    -Source "all-top-level"
  Write-ProcmonAccessibleMenuSummary $handles $Process
  $windowCount = [Math]::Min($handles.Length, 256)
  $mainWindowCount = 0
  $otherWindowCount = 0
  $visibleWindowCount = 0
  $menuHandleCount = 0
  $truncated = $handles.Length -gt 256
  $visibleOtherCount = 0
  $inspectedCount = 0
  $ownedCount = 0
  $distinctRuntimeIdCount = 0
  $resetCount = 0
  $maxComboCount = 0
  $maxEditCount = 0
  $readFailureCount = 0
  $rawScannedOtherCount = 0
  $nativeChildScannedOtherCount = 0
  $resetCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    "Reset"
  )
  $comboCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::ComboBox
  )
  $editCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit
  )
  $mainRuntimeId = $null
  $mainWindowElement = $null
  try {
    $mainWindowElement = [System.Windows.Automation.AutomationElement]::FromHandle(
      $MainWindowHandle
    )
    $mainRuntimeId = $mainWindowElement.GetRuntimeId() -join ","
  } catch {
    $failureType = $_.Exception.GetType().Name
    if ($failureType -notin @(
        "ElementNotAvailableException",
        "InvalidOperationException",
        "COMException"
      )) {
      throw
    }
    $readFailureCount++
  }
  if ($null -ne $mainWindowElement -and
    [ProcmonNativeMenu]::GetWindowProcessId($MainWindowHandle) -eq $Process.Id) {
    Write-ProcmonRawUiaSummary $mainWindowElement "main" $Process.Id
    Write-ProcmonNativeChildSummary $MainWindowHandle "main" $Process.Id
  }
  for ($index = 0; $index -lt $windowCount; $index++) {
    $handle = [IntPtr]$handles[$index]
    if ($handle -eq $MainWindowHandle) {
      $mainWindowCount++
    } else {
      $otherWindowCount++
    }
    if ([ProcmonNativeMenu]::IsWindowVisible($handle)) {
      $visibleWindowCount++
    }
    if ([ProcmonNativeMenu]::GetMenu($handle) -ne [IntPtr]::Zero) {
      $menuHandleCount++
    }
    if (
      $handle -eq $MainWindowHandle -or
      -not [ProcmonNativeMenu]::IsWindowVisible($handle)
    ) {
      continue
    }
    $visibleOtherCount++
    if ([ProcmonNativeMenu]::GetWindowProcessId($handle) -ne $Process.Id) {
      continue
    }
    $inspectedCount++
    try {
      $candidateWindow = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
      if ($null -eq $candidateWindow) {
        $readFailureCount++
        continue
      }
      $candidateState = $candidateWindow.Current
      if (
        $candidateState.ProcessId -ne $Process.Id -or
        [IntPtr]($candidateState.NativeWindowHandle) -ne $handle
      ) {
        continue
      }
      $candidateRuntimeId = $candidateWindow.GetRuntimeId() -join ","
      $distinctRuntimeId = (
        $null -ne $mainRuntimeId -and
        $candidateRuntimeId -cne $mainRuntimeId
      )
      if ($distinctRuntimeId) {
        $distinctRuntimeIdCount++
      }
      $ownedCount++
      if ($rawScannedOtherCount -lt 2) {
        Write-ProcmonRawUiaSummary $candidateWindow "visible-other" $Process.Id
        $rawScannedOtherCount++
      }
      if ($nativeChildScannedOtherCount -lt 2) {
        Write-ProcmonNativeChildSummary $handle "visible-other" $Process.Id
        $nativeChildScannedOtherCount++
      }
      if ($candidateState.ControlType -eq [System.Windows.Automation.ControlType]::Pane) {
        if (-not $distinctRuntimeId) {
          continue
        }
        $nativeControls = Get-ProcmonNativeFilterDialogControls $candidateWindow $Process.Id
        if ($null -ne $nativeControls) {
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_NATIVE_WINDOWS=state:ready;windows:$windowCount;main:$mainWindowCount;other:$otherWindowCount;visible:$visibleWindowCount;menus:$menuHandleCount;truncated:$($truncated.ToString().ToLowerInvariant())"
          )
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_NATIVE_WINDOW_UIA=visible-other:$visibleOtherCount;inspected:$inspectedCount;owned:$ownedCount;distinct-runtime-id:$distinctRuntimeIdCount;reset:1;max-combos:$($nativeControls.Combos.Count);max-edits:$($nativeControls.Edits.Count);read-failures:$readFailureCount;truncated:$($truncated.ToString().ToLowerInvariant())"
          )
          [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=native-top-level-window")
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$($nativeControls.Combos.Count);edits:$($nativeControls.Edits.Count)"
          )
          return $candidateWindow
        }
        continue
      }
      if (
        $candidateState.ControlType -ne [System.Windows.Automation.ControlType]::Window -or
        -not $candidateState.IsEnabled -or
        $candidateState.IsOffscreen
      ) {
        continue
      }
      $combos = $candidateWindow.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $comboCondition
      )
      $edits = $candidateWindow.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $editCondition
      )
      $maxComboCount = [Math]::Max($maxComboCount, $combos.Count)
      $maxEditCount = [Math]::Max($maxEditCount, $edits.Count)
      $reset = $candidateWindow.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $resetCondition
      )
      if ($null -ne $reset) {
        $resetCount++
      }
      if (
        $distinctRuntimeId -and
        ($null -eq $reset -or $combos.Count -lt 3 -or $edits.Count -lt 1)
      ) {
        $nativeControls = Get-ProcmonNativeFilterDialogControls $candidateWindow $Process.Id
        if ($null -ne $nativeControls) {
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_NATIVE_WINDOWS=state:ready;windows:$windowCount;main:$mainWindowCount;other:$otherWindowCount;visible:$visibleWindowCount;menus:$menuHandleCount;truncated:$($truncated.ToString().ToLowerInvariant())"
          )
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_NATIVE_WINDOW_UIA=visible-other:$visibleOtherCount;inspected:$inspectedCount;owned:$ownedCount;distinct-runtime-id:$distinctRuntimeIdCount;reset:1;max-combos:$($nativeControls.Combos.Count);max-edits:$($nativeControls.Edits.Count);read-failures:$readFailureCount;truncated:$($truncated.ToString().ToLowerInvariant())"
          )
          [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=native-top-level-window")
          [Console]::Out.WriteLine(
            "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$($nativeControls.Combos.Count);edits:$($nativeControls.Edits.Count)"
          )
          return $candidateWindow
        }
      }
      if (
        $distinctRuntimeId -and
        $null -ne $reset -and
        $combos.Count -ge 3 -and
        $edits.Count -ge 1
      ) {
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_NATIVE_WINDOWS=state:ready;windows:$windowCount;main:$mainWindowCount;other:$otherWindowCount;visible:$visibleWindowCount;menus:$menuHandleCount;truncated:$($truncated.ToString().ToLowerInvariant())"
        )
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_NATIVE_WINDOW_UIA=visible-other:$visibleOtherCount;inspected:$inspectedCount;owned:$ownedCount;distinct-runtime-id:$distinctRuntimeIdCount;reset:$resetCount;max-combos:$maxComboCount;max-edits:$maxEditCount;read-failures:$readFailureCount;truncated:$($truncated.ToString().ToLowerInvariant())"
        )
        [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=native-top-level-window")
        [Console]::Out.WriteLine(
          "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$($combos.Count);edits:$($edits.Count)"
        )
        return $candidateWindow
      }
    } catch {
      $failureType = $_.Exception.GetType().Name
      if ($failureType -notin @(
          "ElementNotAvailableException",
          "InvalidOperationException",
          "COMException"
        )) {
        throw
      }
      $readFailureCount++
    }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_WINDOWS=state:ready;windows:$windowCount;main:$mainWindowCount;other:$otherWindowCount;visible:$visibleWindowCount;menus:$menuHandleCount;truncated:$($truncated.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_WINDOW_UIA=visible-other:$visibleOtherCount;inspected:$inspectedCount;owned:$ownedCount;distinct-runtime-id:$distinctRuntimeIdCount;reset:$resetCount;max-combos:$maxComboCount;max-edits:$maxEditCount;read-failures:$readFailureCount;truncated:$($truncated.ToString().ToLowerInvariant())"
  )
  return $null
}

function Read-ReloadedFilterPopupState(
  [System.IntPtr]$MainWindowHandle,
  [uint32]$ProcessId
) {
  Set-Stage "find-reloaded-filter-toolbar-item"
  $main = [System.Windows.Automation.AutomationElement]::FromHandle($MainWindowHandle)
  $condition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )
  $items = $main.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  if ($items.Count -ne 1) {
    throw "Process Monitor reloaded main window did not expose one Filter menu item"
  }
  $filter = $items[0]
  $state = $filter.Current
  $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($filter)
  if (
    $main.Current.ProcessId -ne $ProcessId -or
    -not $main.Current.IsEnabled -or $main.Current.IsOffscreen -or
    $state.ProcessId -ne $ProcessId -or -not $state.IsEnabled -or $state.IsOffscreen -or
    $null -eq $parent -or $parent.Current.ProcessId -ne $ProcessId -or
    $parent.Current.ControlType -ne [System.Windows.Automation.ControlType]::ToolBar -or
    [ProcmonNativeMenu]::GetWindowProcessId($MainWindowHandle) -ne $ProcessId -or
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $MainWindowHandle
  ) {
    throw "Process Monitor reloaded Filter toolbar item is not available in its foreground main window"
  }
  Set-Stage "open-reloaded-filter-toolbar-menu"
  $pattern = $filter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $pattern.Invoke()
  Set-Stage "wait-reloaded-filter-toolbar-popup"
  $process = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
  $popup = (Wait-ProcessMenu $process).Menu
  Set-Stage "validate-reloaded-filter-popup"
  $popupState = $popup.Current
  $popupHandle = [IntPtr]$popupState.NativeWindowHandle
  if (
    $popupState.ProcessId -ne $ProcessId -or
    -not $popupState.IsEnabled -or $popupState.IsOffscreen -or
    $popupHandle -eq [IntPtr]::Zero -or
    $popupHandle -eq $MainWindowHandle -or
    [ProcmonNativeMenu]::GetWindowProcessId($popupHandle) -ne $ProcessId
  ) {
    throw "Process Monitor reloaded Filter popup is unavailable"
  }
  $dropCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Drop Filtered Events"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )
  $drops = $popup.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dropCondition)
  if ($drops.Count -ne 1) {
    throw "Process Monitor reloaded Filter popup did not expose one Drop item"
  }
  $dropState = $drops[0].Current
  if ($dropState.ProcessId -ne $ProcessId -or -not $dropState.IsEnabled -or $dropState.IsOffscreen) {
    throw "Process Monitor reloaded Drop item is unavailable"
  }
  $native = Get-NativeDropMenuSnapshot $MainWindowHandle $popupHandle $ProcessId
  Write-NativeDropMenuSnapshot $native "after-reload"
  $accessible = $null
  if ($native.CheckState -eq "unavailable") {
    $accessible = Get-AccessibleDropMenuSnapshot $popupHandle $ProcessId $false "after-reload"
    if (-not $accessible.IsEnabled) {
      throw "Process Monitor reloaded Filter popup did not expose an enabled accessible Drop item"
    }
  }
  Set-Stage "verify-reloaded-filter-popup-state"
  $checked = Get-VerifiedDropMenuCheckState $native $accessible
  if ($checked -notin @("on", "off")) {
    throw "Process Monitor reloaded Filter popup checked-state is unavailable"
  }
  return $checked
}

function Get-ReloadedNativeDropCheckState(
  [System.IntPtr]$MainWindowHandle,
  [uint32]$ProcessId
) {
  Set-Stage "verify-reloaded-main-window-process"
  if ([ProcmonNativeMenu]::GetWindowProcessId($MainWindowHandle) -ne $ProcessId) {
    throw "Process Monitor reloaded main window belongs to a different process"
  }

  Set-Stage "read-reloaded-native-main-menu"
  $menuHandle = [ProcmonNativeMenu]::GetMenu($MainWindowHandle)
  $checkState = "unavailable"
  $dropEnabled = $false
  if (-not $menuHandle.Equals([System.IntPtr]::Zero)) {
    $script:nativeMenuVisited = 0
    Set-Stage "find-reloaded-native-event-menu-item"
    $eventMenu = Get-NativeMenuItemSnapshot $menuHandle "Event"
    $eventEnabled = $false
    $eventHighlighted = $false
    $eventSubmenuAvailable = $false
    if ($null -ne $eventMenu.Item) {
      $eventEnabled = [bool]$eventMenu.Item.IsEnabled
      $eventHighlighted = [bool]$eventMenu.Item.IsHighlighted
      $eventSubmenuAvailable = -not $eventMenu.Item.Submenu.Equals([System.IntPtr]::Zero)
    }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_RELOAD_NATIVE_EVENT=items:$($eventMenu.ItemCount);matches:$($eventMenu.MatchCount);enabled:$($eventEnabled.ToString().ToLowerInvariant());highlighted:$($eventHighlighted.ToString().ToLowerInvariant());submenu:$($eventSubmenuAvailable.ToString().ToLowerInvariant())"
    )
    if ($eventMenu.MatchCount -ne 1 -or -not $eventEnabled -or -not $eventSubmenuAvailable) {
      throw "Process Monitor reloaded main menu did not expose one enabled Event submenu"
    }

    Set-Stage "find-reloaded-native-filter-menu-item"
    $filterMenu = Get-NativeMenuItemSnapshot $eventMenu.Item.Submenu "Filter"
    $filterEnabled = $false
    $filterSubmenuAvailable = $false
    if ($null -ne $filterMenu.Item) {
      $filterEnabled = [bool]$filterMenu.Item.IsEnabled
      $filterSubmenuAvailable = -not $filterMenu.Item.Submenu.Equals([System.IntPtr]::Zero)
    }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_RELOAD_NATIVE_FILTER=items:$($filterMenu.ItemCount);matches:$($filterMenu.MatchCount);enabled:$($filterEnabled.ToString().ToLowerInvariant());submenu:$($filterSubmenuAvailable.ToString().ToLowerInvariant())"
    )
    if ($filterMenu.MatchCount -ne 1 -or -not $filterEnabled -or -not $filterSubmenuAvailable) {
      throw "Process Monitor reloaded Event menu did not expose one enabled Filter submenu"
    }

    Set-Stage "read-reloaded-native-drop-filtered-events-state"
    $dropMenu = Get-NativeMenuItemSnapshot $filterMenu.Item.Submenu "Drop Filtered Events"
    $dropEnabled = $false
    if ($null -ne $dropMenu.Item) {
      $dropEnabled = [bool]$dropMenu.Item.IsEnabled
      $checkState = if ($dropMenu.Item.IsChecked) { "on" } else { "off" }
    }
    $dropReadable = ($dropMenu.MatchCount -eq 1).ToString().ToLowerInvariant()
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_RELOAD_NATIVE_DROP=items:$($dropMenu.ItemCount);matches:$($dropMenu.MatchCount);read-failure:none;readable:$dropReadable;enabled:$($dropEnabled.ToString().ToLowerInvariant());checked:$checkState"
    )
  } else {
    $nativeSnapshot = Get-NativeDropMenuSnapshot `
      $MainWindowHandle ([System.IntPtr]::Zero) $ProcessId
    Write-NativeDropMenuSnapshot $nativeSnapshot "after-reload"
    Write-ReloadedEventMenuPatternSnapshot $MainWindowHandle $ProcessId
    Set-Stage "read-reloaded-msaa-menu-state"
    $accessibleSnapshot = Get-AccessibleDropMenuSnapshot `
      $MainWindowHandle $ProcessId $true "after-reload"
    Set-Stage "consume-reloaded-msaa-menu-state"
    if ($accessibleSnapshot.CheckState -in @("on", "off")) {
      $checkState = $accessibleSnapshot.CheckState
      $dropEnabled = [bool]$accessibleSnapshot.IsEnabled
    }
    if ($checkState -eq "unavailable") {
      $checkState = Read-ReloadedFilterPopupState $MainWindowHandle $ProcessId
      $dropEnabled = $true
    }
  }
  Set-Stage "verify-reloaded-drop-check-state"
  if ($checkState -notin @("on", "off") -or -not $dropEnabled) {
    throw "Process Monitor reloaded Drop Filtered Events state was unavailable or disabled"
  }
  return $checkState
}

function Get-NativeDropMenuSnapshot(
  [System.IntPtr]$WindowHandle,
  [System.IntPtr]$MenuWindowHandle,
  [uint32]$ProcessId
) {
  Set-Stage "get-native-menu-handle"
  $menuHandle = [ProcmonNativeMenu]::GetMenu($WindowHandle)
  $menuSource = "main"
  $menuOwnerWindowHandle = [System.IntPtr]::Zero
  $menuWindowProcessKnown = $false
  $menuWindowSameProcess = $false
  $guiThreadInfoAvailable = $false
  $menuModeActive = $false
  if ($menuHandle.Equals([System.IntPtr]::Zero)) {
    $menuOwnerWindowHandle = [ProcmonNativeMenu]::GetMenuOwnerWindow(
      $MenuWindowHandle,
      $ProcessId,
      [ref]$menuWindowProcessKnown,
      [ref]$menuWindowSameProcess,
      [ref]$guiThreadInfoAvailable,
      [ref]$menuModeActive
    )
    if (-not $menuOwnerWindowHandle.Equals([System.IntPtr]::Zero)) {
      $menuHandle = [ProcmonNativeMenu]::GetMenu($MenuWindowHandle)
      if ($menuHandle.Equals([System.IntPtr]::Zero)) {
        $menuHandle = [ProcmonNativeMenu]::GetMenu($menuOwnerWindowHandle)
        if ($menuHandle.Equals([System.IntPtr]::Zero)) {
          $menuSource = "unavailable"
        } else {
          $menuSource = "menu-owner"
        }
      } else {
        $menuSource = "menu-window"
      }
    } else {
      $menuSource = "unavailable"
    }
  }
  $handleAvailable = -not $menuHandle.Equals([System.IntPtr]::Zero)
  $script:nativeMenuVisited = 0
  $script:nativeMenuReadable = $handleAvailable
  $script:nativeMenuFailure = "none"
  $script:nativeDropMenuMatches = [System.Collections.Generic.List[object]]::new()
  if ($handleAvailable) {
    Set-Stage "scan-native-menu-state"
    Find-NativeDropMenuItem $menuHandle 0
  }
  Set-Stage "report-native-menu-state"
  $checkState = "unavailable"
  if ($script:nativeMenuReadable -and $script:nativeDropMenuMatches.Count -eq 1) {
    $checkState = if ($script:nativeDropMenuMatches[0].IsChecked) { "on" } else { "off" }
  }
  [pscustomobject]@{
    MenuSource = $menuSource
    MenuWindowProcess = if (-not $menuWindowProcessKnown) { "unavailable" } elseif ($menuWindowSameProcess) { "same" } else { "other" }
    GuiThreadInfoAvailable = $guiThreadInfoAvailable
    OwnerWindowAvailable = -not $menuOwnerWindowHandle.Equals([System.IntPtr]::Zero)
    HandleAvailable = $handleAvailable
    ItemCount = [Math]::Min($script:nativeMenuVisited, 9999)
    MatchCount = [Math]::Min($script:nativeDropMenuMatches.Count, 9999)
    ReadFailure = $script:nativeMenuFailure
    Readable = $script:nativeMenuReadable
    CheckState = $checkState
  }
}

function Write-NativeDropMenuSnapshot($Snapshot, [string]$Observation) {
  $guiThreadInfoState = if ($Snapshot.GuiThreadInfoAvailable) { "available" } else { "unavailable" }
  $ownerWindowState = if ($Snapshot.OwnerWindowAvailable) { "available" } else { "unavailable" }
  $handleState = if ($Snapshot.HandleAvailable) { "available" } else { "unavailable" }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:$Observation;source:$($Snapshot.MenuSource);menu-window-process:$($Snapshot.MenuWindowProcess);gui-thread-info:$guiThreadInfoState;owner-window:$ownerWindowState;handle:$handleState;items:$($Snapshot.ItemCount);matches:$($Snapshot.MatchCount);read-failure:$($Snapshot.ReadFailure);readable:$($Snapshot.Readable.ToString().ToLowerInvariant());checked:$($Snapshot.CheckState)"
  )
}

function Write-ReloadedEventMenuPatternSnapshot(
  [System.IntPtr]$MainWindowHandle,
  [uint32]$ProcessId
) {
  Set-Stage "probe-reloaded-event-main-window"
  $mainWindow = [System.Windows.Automation.AutomationElement]::FromHandle(
    $MainWindowHandle
  )
  Set-Stage "probe-reloaded-event-window-process"
  if ($mainWindow.Current.ProcessId -ne $ProcessId) {
    throw "Process Monitor reloaded main window belongs to a different process"
  }
  Set-Stage "probe-reloaded-event-menu-items"
  $menuItemCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::MenuItem
  )
  $menuItems = $mainWindow.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    $menuItemCondition
  )
  if ($menuItems.Count -gt 256) {
    throw "Process Monitor reloaded menu-item probe exceeded its bounded limit"
  }
  $eventMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  Set-Stage "probe-reloaded-event-menu-item-names"
  foreach ($item in $menuItems) {
    if ($item.Current.Name -ceq "Event") {
      $eventMatches.Add($item)
    }
  }

  $processState = "unavailable"
  $isEnabled = $false
  $isOffscreen = $false
  $isKeyboardFocusable = $false
  $hasInvokePattern = $false
  $hasExpandCollapsePattern = $false
  $hasSelectionItemPattern = $false
  Set-Stage "probe-reloaded-event-item-state"
  if ($eventMatches.Count -eq 1) {
    $eventItem = $eventMatches[0]
    $eventState = $eventItem.Current
    if ($eventState.ProcessId -eq $ProcessId) {
      $processState = "same"
      $isEnabled = [bool]$eventState.IsEnabled
      $isOffscreen = [bool]$eventState.IsOffscreen
      $isKeyboardFocusable = [bool]$eventState.IsKeyboardFocusable
      $pattern = $null
      Set-Stage "probe-reloaded-event-invoke-pattern"
      $hasInvokePattern = $eventItem.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
      )
      $pattern = $null
      Set-Stage "probe-reloaded-event-expand-collapse-pattern"
      $hasExpandCollapsePattern = $eventItem.TryGetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
        [ref]$pattern
      )
      $pattern = $null
      Set-Stage "probe-reloaded-event-selection-item-pattern"
      $hasSelectionItemPattern = $eventItem.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [ref]$pattern
      )
    } else {
      $processState = "other"
    }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RELOAD_EVENT_MENU_ITEM=process:$processState;items:$($menuItems.Count);matches:$($eventMatches.Count);enabled:$($isEnabled.ToString().ToLowerInvariant());offscreen:$($isOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($isKeyboardFocusable.ToString().ToLowerInvariant());invoke:$($hasInvokePattern.ToString().ToLowerInvariant());expand-collapse:$($hasExpandCollapsePattern.ToString().ToLowerInvariant());selection-item:$($hasSelectionItemPattern.ToString().ToLowerInvariant())"
  )
}

function Get-AccessibleDropMenuSnapshot(
  [System.IntPtr]$MenuWindowHandle,
  [uint32]$ProcessId,
  [bool]$UseWindowMenuObject,
  [string]$Observation
) {
  Set-Stage "invoke-msaa-menu-state"
  $snapshot = [ProcmonNativeMenu]::ReadAccessibleDropMenuState(
    $MenuWindowHandle,
    $ProcessId,
    $UseWindowMenuObject
  )
  Set-Stage "read-msaa-process-state"
  $processKnown = [bool]$snapshot.ProcessKnown
  $processSame = [bool]$snapshot.ProcessSame
  $processState = if (-not $processKnown) {
    "unavailable"
  } elseif ($processSame) {
    "same"
  } else {
    "other"
  }
  Set-Stage "read-msaa-object-state"
  $accessibleAvailable = [bool]$snapshot.AccessibleAvailable
  $objectState = if ($accessibleAvailable) { "available" } else { "unavailable" }
  Set-Stage "read-msaa-menu-counts"
  $itemCount = [int]$snapshot.ItemCount
  $matchCount = [int]$snapshot.MatchCount
  Set-Stage "read-msaa-menu-result"
  $readFailure = [string]$snapshot.ReadFailure
  $checkState = [string]$snapshot.CheckState
  $isEnabled = [bool]$snapshot.IsEnabled
  Set-Stage "report-msaa-menu-state"
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MSAA_MENU_STATE=observation:$Observation;process:$processState;object:$objectState;items:$itemCount;matches:$matchCount;read-failure:$readFailure;checked:$checkState"
  )
  Set-Stage "report-msaa-menu-enabled"
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MSAA_MENU_ENABLED=observation:$Observation;enabled:$($isEnabled.ToString().ToLowerInvariant())"
  )
  return $snapshot
}

function Get-VerifiedDropMenuCheckState($NativeSnapshot, $AccessibleSnapshot) {
  if ($NativeSnapshot.CheckState -in @("on", "off")) {
    return $NativeSnapshot.CheckState
  }
  if (
    $null -ne $AccessibleSnapshot -and
    $AccessibleSnapshot.CheckState -in @("on", "off")
  ) {
    return $AccessibleSnapshot.CheckState
  }
  return "unavailable"
}

function Find-ComboValue(
  [System.Windows.Automation.AutomationElement]$Combo,
  [string]$Value,
  [int]$TimeoutSeconds = 1
) {
  $comboPattern = $null
  if (-not $Combo.TryGetCurrentPattern(
      [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
      [ref]$comboPattern
    )) {
    return $null
  }
  $condition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, $Value
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $comboPattern.Expand()
  try {
    do {
      $item = $Combo.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
      if ($null -ne $item) { return $item }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
  } finally {
    $comboPattern.Collapse()
  }
}

function Select-ComboValue($Combos, [string]$Value) {
  $matchingCombos = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  $optionLabel = switch ($Value) {
    "Path" { "column" }
    "is" { "operator" }
    "Include" { "action" }
    default { "other" }
  }
  $index = 0
  foreach ($combo in $Combos) {
    $ordinal = switch ($index) {
      0 { "one" }
      1 { "two" }
      2 { "three" }
      3 { "four" }
      4 { "five" }
      5 { "six" }
      6 { "seven" }
      7 { "eight" }
      default { "many" }
    }
    Set-Stage "probe-$optionLabel-combo-$ordinal"
    if ($null -ne (Find-ComboValue $combo $Value)) {
      $matchingCombos.Add($combo)
    }
    $index++
  }
  if ($matchingCombos.Count -ne 1) {
    throw "Process Monitor filter dialog did not expose one exact option"
  }
  Set-Stage "expand-$optionLabel-combo"
  $comboPattern = $matchingCombos[0].GetCurrentPattern(
    [System.Windows.Automation.ExpandCollapsePattern]::Pattern
  )
  $comboPattern.Expand()
  try {
    Set-Stage "wait-$optionLabel-option"
    $item = Wait-Element $matchingCombos[0] ([System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, $Value
    )) 5
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
  } finally {
    $comboPattern.Collapse()
  }
}

function Set-FilterRule([System.Windows.Automation.AutomationElement]$Dialog, [string]$Path, [int]$OwnerProcessId) {
  Set-Stage "inspect-native-filter-controls"
  $nativeControls = Get-ProcmonNativeFilterDialogControls $Dialog $OwnerProcessId
  if ($null -eq $nativeControls) {
    Set-Stage "native-filter-controls-$script:nativeFilterControlGate"
  }
  if ($null -ne $nativeControls) {
    Set-Stage "select-filter-column"
    Set-ProcmonNativeFilterCombo $Dialog $OwnerProcessId "Path"
    Set-Stage "select-filter-operator"
    Set-ProcmonNativeFilterCombo $Dialog $OwnerProcessId "is"
    Set-Stage "set-filter-path-value"
    Set-ProcmonNativeFilterPath $Dialog $OwnerProcessId $Path
    Set-Stage "select-filter-action"
    Set-ProcmonNativeFilterCombo $Dialog $OwnerProcessId "Include"
    Set-Stage "add-filter-rule"
    Invoke-ProcmonNativeFilterButton $Dialog $OwnerProcessId "Add"
    $updatedControls = Get-ProcmonNativeFilterDialogControls $Dialog $OwnerProcessId
    $updatedRows = Get-ProcmonNativeFilterRuleRows $updatedControls $OwnerProcessId -Quiet
    $expectedRow = "Path is $Path Include"
    $exactMatches = @(
      $updatedRows | Where-Object {
        [string]::Equals($_.Text, $expectedRow, [System.StringComparison]::Ordinal)
      }
    ).Count
    if ($exactMatches -ne 1) {
      throw "Process Monitor native Add did not retain the exact filter rule"
    }
    return
  }
  $combos = $Dialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::ComboBox
    )
  )
  $edits = $Dialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit
    )
  )
  if ($combos.Count -lt 3 -or $edits.Count -lt 1) {
    throw "Process Monitor filter dialog has an unexpected control layout"
  }
  Set-Stage "select-filter-column"
  Select-ComboValue $combos "Path"
  Set-Stage "select-filter-operator"
  Select-ComboValue $combos "is"
  Set-Stage "probe-filter-path-edit"
  $editState = $edits[0].Current
  $valuePattern = $null
  $hasValuePattern = $edits[0].TryGetCurrentPattern(
    [System.Windows.Automation.ValuePattern]::Pattern,
    [ref]$valuePattern
  )
  $isReadOnly = $true
  if ($hasValuePattern) {
    $isReadOnly = $valuePattern.Current.IsReadOnly
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_PATH_EDIT=enabled:$($editState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($editState.IsOffscreen.ToString().ToLowerInvariant());read-only:$($isReadOnly.ToString().ToLowerInvariant());value-pattern:$($hasValuePattern.ToString().ToLowerInvariant())"
  )
  if (-not $editState.IsEnabled -or
    $editState.IsOffscreen -or
    -not $hasValuePattern -or
    $isReadOnly) {
    throw "Process Monitor filter path field is not writable"
  }
  Set-Stage "set-filter-path-value"
  Set-ProcmonEditValueByKeyboard $Dialog $edits[0] $valuePattern $Path $OwnerProcessId
  Set-Stage "select-filter-action"
  Select-ComboValue $combos "Include"
  Set-Stage "add-filter-rule"
  $add = Wait-Element $Dialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Add"
  )) 5
  $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Get-ControlTypeLabel([System.Windows.Automation.AutomationElement]$Element) {
  switch ($Element.Current.ControlType.ProgrammaticName) {
    "ControlType.MenuBar" { return "MenuBar" }
    "ControlType.Menu" { return "Menu" }
    "ControlType.MenuItem" { return "MenuItem" }
    "ControlType.Window" { return "Window" }
    "ControlType.Pane" { return "Pane" }
    "ControlType.ToolBar" { return "ToolBar" }
    "ControlType.Button" { return "Button" }
    "ControlType.Text" { return "Text" }
    "ControlType.Edit" { return "Edit" }
    default { return "Other" }
  }
}

function Get-ControlNameLabel([System.Windows.Automation.AutomationElement]$Element) {
  switch ($Element.Current.Name) {
    "Event" { return "Event" }
    "File" { return "FileMenu" }
    "Filter" { return "Filter" }
    "Filter..." { return "FilterCommand" }
    "Save Filter..." { return "SaveFilterCommand" }
    "Export Configuration..." { return "ExportConfigCommand" }
    "Drop Filtered Events" { return "DropFilteredEvents" }
    "Highlight Filtered Events" { return "HighlightFilteredEvents" }
    "Menu Bar" { return "MenuBar" }
    "Process Monitor" { return "ProcessMonitor" }
    default { return "Other" }
  }
}

function Write-MenuItemsObservation(
  [string]$Phase,
  [System.Windows.Automation.AutomationElement]$Menu
) {
  try {
    $items = $Menu.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $observedItems = [System.Collections.Generic.List[string]]::new()
    $itemLimit = [Math]::Min($items.Count, 8)
    for ($index = 0; $index -lt $itemLimit; $index++) {
      $item = $items[$index]
      $state = $item.Current
      $observedItems.Add(
        "$(Get-ControlTypeLabel $item):$(Get-ControlNameLabel $item):$($state.IsEnabled.ToString().ToLowerInvariant()):$($state.IsOffscreen.ToString().ToLowerInvariant()):$($state.IsKeyboardFocusable.ToString().ToLowerInvariant())"
      )
    }
    $truncated = ($items.Count -gt $itemLimit).ToString().ToLowerInvariant()
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_MENU_ITEMS=$Phase;count:$($items.Count);truncated:$truncated;items=$($observedItems -join ',')"
    )
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_ITEMS=$Phase;unavailable")
  }
}

function Write-FocusSnapshotObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Snapshot
) {
  $elementState = if ($null -eq $Snapshot["Element"]) { "missing" } else { "present" }
  $controlType = switch ($Snapshot["ControlType"]) {
    "ControlType.Menu" { "menu" }
    "ControlType.MenuItem" { "menu-item" }
    "ControlType.Window" { "window" }
    "ControlType.Pane" { "pane" }
    "ControlType.ToolBar" { "toolbar" }
    $null { "missing" }
    default { "other" }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SNAPSHOT=$Phase;element:$elementState;control-type:$controlType"
  )
}

function Write-FocusObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Snapshot = $null
) {
  if ($null -ne $Snapshot) {
    $Snapshot["Element"] = $null
    $Snapshot["ControlType"] = $null
  }
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) {
      if ($null -ne $Snapshot) {
        Write-FocusSnapshotObservation "writer" $Snapshot
      }
      [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;focused:none")
      return
    }
    $state = $focused.Current
    $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $treeParts = [System.Collections.Generic.List[string]]::new()
    $treeNode = $focused
    for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
      $treeParts.Add("$(Get-ControlTypeLabel $treeNode):$(Get-ControlNameLabel $treeNode)")
      $treeNode = $treeWalker.GetParent($treeNode)
    }
    if ($null -ne $Snapshot) {
      $Snapshot["Element"] = $focused
      $Snapshot["ControlType"] = $state.ControlType.ProgrammaticName
    }
    if ($null -ne $Snapshot) {
      Write-FocusSnapshotObservation "writer" $Snapshot
    }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;type:$(Get-ControlTypeLabel $focused);name:$(Get-ControlNameLabel $focused);offscreen:$($state.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($state.IsKeyboardFocusable.ToString().ToLowerInvariant());tree=$($treeParts -join '>')"
    )
    if (
      $Phase -in @("after-open", "after-home") -and
      $state.ControlType.ProgrammaticName -eq "ControlType.Menu"
    ) {
      Write-MenuItemsObservation $Phase $focused
    }
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;focused:unavailable")
  }
}

function Write-FocusOwnerObservation(
  [string]$Phase,
  [System.Diagnostics.Process]$Process,
  [System.Windows.Automation.AutomationElement]$MainWindow
) {
  $owner = "unavailable"
  $nativeRoot = "unavailable"
  $reason = $null
  $focusedWindowHandle = [IntPtr]::Zero
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    for ($level = 0; $null -ne $focused -and $level -lt 4; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
        if ($focused.Current.ProcessId -ne $Process.Id) {
          $owner = "other-process"
        } elseif ($focused.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
          $owner = "procmon-main"
        } else {
          $owner = "procmon-other"
        }
        $focusedWindowHandle = [IntPtr]$focused.Current.NativeWindowHandle
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -eq $focused) {
      $owner = "no-window"
    }
  } catch {
    $reason = $_.Exception.GetType().Name
    if ($reason -notin @(
        "ElementNotAvailableException",
        "InvalidOperationException",
        "COMException"
      )) {
      $reason = "Other"
    }
  }
  if ($focusedWindowHandle -ne [IntPtr]::Zero) {
    try {
      $nativeRoot = Get-ProcmonFocusHandleClass `
        $focusedWindowHandle $Process ([IntPtr]$MainWindow.Current.NativeWindowHandle)
      if ($nativeRoot -eq "procmon-other") {
        $rootHandle = [ProcmonNativeMenu]::GetAncestor($focusedWindowHandle, 2)
        Write-ProcmonNativeMenuSummary `
          -WindowHandles ([IntPtr[]]@($rootHandle)) `
          -Process $Process `
          -Source "focused-root"
      }
    } catch {
      $reason = $_.Exception.GetType().Name
      if ($reason -notin @(
          "ElementNotAvailableException",
          "InvalidOperationException",
          "COMException"
        )) {
        $reason = "Other"
      }
    }
  }
  $suffix = if ($null -eq $reason) { "" } else { ";reason:$reason" }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUS_OWNER=$Phase;owner:$owner$suffix")
  [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUS_NATIVE_ROOT=$Phase;root:$nativeRoot")
}

function Get-ProcmonFocusHandleClass(
  [System.IntPtr]$Handle,
  [System.Diagnostics.Process]$Process,
  [System.IntPtr]$MainWindowHandle
) {
  if ($Handle -eq [IntPtr]::Zero) {
    return "none"
  }
  $rootHandle = [ProcmonNativeMenu]::GetAncestor($Handle, 2)
  if ($rootHandle -eq [IntPtr]::Zero) {
    return "unavailable"
  }
  $ownerProcessId = [ProcmonNativeMenu]::GetWindowProcessId($rootHandle)
  if ($ownerProcessId -eq $Process.Id) {
    if ($rootHandle -eq $MainWindowHandle) {
      return "procmon-main"
    }
    return "procmon-other"
  }
  if ($ownerProcessId -gt 0) {
    return "other-process"
  }
  return "unavailable"
}

function Write-ShortcutGuiFocusObservation(
  [ValidateSet("before", "after")][string]$Phase,
  [System.Diagnostics.Process]$Process,
  [System.IntPtr]$MainWindowHandle
) {
  $snapshot = [ProcmonNativeMenu]::ReadFocusSnapshot($MainWindowHandle)
  $active = "unavailable"
  $focus = "unavailable"
  if ($snapshot.Available) {
    $active = Get-ProcmonFocusHandleClass $snapshot.ActiveWindow $Process $MainWindowHandle
    $focus = Get-ProcmonFocusHandleClass $snapshot.FocusWindow $Process $MainWindowHandle
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SHORTCUT_GUI_FOCUS=phase:$Phase;available:$($snapshot.Available.ToString().ToLowerInvariant());active:$active;focus:$focus"
  )
}

try {
  if (-not $PSBoundParameters.ContainsKey("CaptureProcessId")) {
  Set-Stage "wait-for-input-idle"
  if (-not $process.WaitForInputIdle(10000)) {
    throw "Process Monitor UI did not become idle"
  }
  Set-Stage "find-main-window"
  $main = Wait-MainWindow $process
  Set-Stage "activate-main-window"
  Set-VerifiedProcmonMainWindowForeground $main $process "MAIN"
  Set-Stage "find-filter-menu"
  Write-ProcmonNativeMenuSummary `
    -WindowHandles ([IntPtr[]]@([IntPtr]$main.Current.NativeWindowHandle)) `
    -Process $process `
    -Source "main"
  $filterMenuCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )
  $filterMenu = Wait-Element $main $filterMenuCondition 5 -AllowMissing
  $filterDialog = $null
  if ($null -eq $filterMenu -or $filterMenu.Current.ProcessId -ne $process.Id) {
    $filterDialog = Open-FilterDialogByShortcut $main $process
  } else {
  Set-Stage "focus-filter-menu"
  $menuState = $filterMenu.Current
  $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $treeParts = [System.Collections.Generic.List[string]]::new()
  $treeNode = $filterMenu
  for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
    $treeParts.Add("$(Get-ControlTypeLabel $treeNode):$(Get-ControlNameLabel $treeNode)")
    $treeNode = $treeWalker.GetParent($treeNode)
  }
  $expandPattern = $null
  $hasExpandPattern = $filterMenu.TryGetCurrentPattern(
    [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
    [ref]$expandPattern
  )
  $invokePattern = $null
  $hasInvokePattern = $filterMenu.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MENU_STATE=enabled:$($menuState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($menuState.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($menuState.IsKeyboardFocusable.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_TREE=$($treeParts -join '>')")
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:$($hasExpandPattern.ToString().ToLowerInvariant());invoke:$($hasInvokePattern.ToString().ToLowerInvariant())"
  )
  if ($menuState.IsKeyboardFocusable) {
    try {
      $filterMenu.SetFocus()
      [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=returned")
    } catch {
      $focusError = $_.Exception.GetType().Name
      if ($focusError -notin @(
          "ElementNotEnabledException",
          "ElementNotAvailableException",
          "InvalidOperationException",
          "COMException",
          "NoClickablePointException"
        )) {
        $focusError = "Other"
      }
      [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=failed-$focusError")
      throw
    }
  } else {
    [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=skipped-not-keyboard-focusable")
  }
  Set-Stage "expand-filter-menu"
  if ($hasExpandPattern) {
    $expandPattern.Expand()
  } elseif ($hasInvokePattern) {
    $invokePattern.Invoke()
  } else {
    throw "Process Monitor Filter menu exposes no supported open pattern"
  }
  Set-Stage "wait-for-open-filter-menu"
  $menu = $null
  $menuDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
        if ($focused.Current.ProcessId -eq $process.Id) {
          $menu = $focused
        }
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -ne $menu) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $menuDeadline)
  Set-Stage "observe-menu-focus"
  $focusSnapshot = @{}
  Write-FocusObservation "after-open" $focusSnapshot
  Set-Stage "verify-menu-focus-snapshot"
  Write-FocusSnapshotObservation "caller" $focusSnapshot
  Set-Stage "resolve-open-filter-menu"
  if ($null -eq $menu -or $menu.Current.ProcessId -ne $process.Id) {
    $filterDialog = Open-FilterDialogByShortcut $main $process
  } else {
    if ($focusSnapshot["ControlType"] -ne "ControlType.Menu") {
      Write-MenuItemsObservation "after-open" $menu
    }
    Set-Stage "enumerate-filter-menu-items"
    $menuItems = $menu.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $menuItemCount = [Math]::Min($menuItems.Count, 9999)
    $filterCommands = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($item in $menuItems) {
      Set-Stage "read-filter-menu-item"
      $itemState = $item.Current
      Set-Stage "match-filter-menu-item"
      if ($itemState.Name -eq "Filter..." -and
        $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
        $filterCommands.Add($item)
      }
    }
    Set-Stage "verify-filter-command-count"
    $filterMatchCount = [Math]::Min($filterCommands.Count, 9999)
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_COMMAND_MATCH=items:$menuItemCount;matches:$filterMatchCount"
    )
    if ($filterCommands.Count -ne 1) {
      throw "Process Monitor open menu did not expose one Filter command"
    }
    $filterCommand = $filterCommands[0]
    Set-Stage "read-filter-command-state"
    $filterCommandState = $filterCommand.Current
    Set-Stage "probe-filter-command-patterns"
    $filterInvokePattern = $null
    $hasFilterInvokePattern = $filterCommand.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$filterInvokePattern
    )
    $filterSelectionPattern = $null
    $hasFilterSelectionPattern = $filterCommand.TryGetCurrentPattern(
      [System.Windows.Automation.SelectionItemPattern]::Pattern,
      [ref]$filterSelectionPattern
    )
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_COMMAND_PATTERNS=invoke:$($hasFilterInvokePattern.ToString().ToLowerInvariant());selection-item:$($hasFilterSelectionPattern.ToString().ToLowerInvariant())"
    )
    Set-Stage "validate-filter-command-state"
    if (-not $filterCommandState.IsEnabled -or
      $filterCommandState.IsOffscreen -or
      -not $filterCommandState.IsKeyboardFocusable -or
      -not $hasFilterInvokePattern) {
      throw "Process Monitor Filter command is not available through its InvokePattern"
    }
    Set-Stage "focus-filter-command"
    $filterCommand.SetFocus()
    Set-Stage "observe-filter-command-focus"
    Write-FocusObservation "filter-command" | Out-Null
    [Console]::Out.WriteLine("PROC_MON_FILTER_COMMAND_ACTIVATION=invoke-pattern")
    Set-Stage "invoke-filter-command"
    $filterInvokePattern.Invoke()
    Set-Stage "observe-dialog-focus"
    Write-FocusObservation "after-command-invoke" | Out-Null
    Write-FocusOwnerObservation "after-command-invoke" $process $main
    Set-Stage "wait-filter-dialog"
    $filterDialog = Wait-FilterDialog $process $main
  }
  }
  Set-Stage "reset-existing-filters"
  $nativeFilterControls = Get-ProcmonNativeFilterDialogControls $filterDialog $process.Id
  if ($null -ne $nativeFilterControls) {
    Invoke-ProcmonNativeFilterButton $filterDialog $process.Id "Reset"
  } else {
    $reset = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Reset"
    )) 5
    $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  }
  Set-Stage "clear-existing-filter-rules"
  Clear-LoadedFilterRules $filterDialog $process.Id
  Set-Stage "set-canary-filter"
  Set-FilterRule $filterDialog $CanaryPath $process.Id
  Set-Stage "set-control-filter"
  Set-FilterRule $filterDialog $ControlPath $process.Id
  Set-Stage "apply-filters"
  $nativeFilterControls = Get-ProcmonNativeFilterDialogControls $filterDialog $process.Id
  if ($null -ne $nativeFilterControls) {
    Invoke-ProcmonNativeFilterButton $filterDialog $process.Id "OK"
    $dialogHandle = [IntPtr]$filterDialog.Current.NativeWindowHandle
    $closeDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      if (-not [ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) { break }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $closeDeadline)
    if ([ProcmonNativeMenu]::IsWindowVisible($dialogHandle)) {
      throw "Process Monitor native filter dialog did not close after OK"
    }
  } else {
    $ok = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "OK"
    )) 5
    $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  }

  Set-Stage "find-main-for-drop-filtered-events"
  $main = Wait-MainWindow $process
  Set-Stage "focus-main-for-drop-filtered-events"
  Set-VerifiedProcmonMainWindowForeground $main $process "MAIN"
  Set-Stage "find-filter-menu-for-drop-filtered-events"
  $filterMenu = Wait-Element $main ([System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )) 5
  $dropMenuPattern = $null
  if (-not $filterMenu.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$dropMenuPattern
    )) {
    throw "Process Monitor Filter menu does not expose InvokePattern"
  }
  Set-Stage "open-drop-filtered-events-menu"
  $dropMenuPattern.Invoke()
  Set-Stage "resolve-drop-filtered-events-menu"
  $dropMenu = $null
  $dropMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
        $dropMenu = $focused
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -ne $dropMenu) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $dropMenuDeadline)
  if ($null -eq $dropMenu) {
    throw "Process Monitor did not expose the opened Filter menu"
  }
  $dropMenuState = $dropMenu.Current
  $dropMenuOwned = ($dropMenuState.ProcessId -eq $process.Id)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_MENU_STATE=owner-same-process:$($dropMenuOwned.ToString().ToLowerInvariant());enabled:$($dropMenuState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dropMenuState.IsOffscreen.ToString().ToLowerInvariant())"
  )
  if (-not $dropMenuOwned -or -not $dropMenuState.IsEnabled -or $dropMenuState.IsOffscreen) {
    throw "Process Monitor Filter menu is not available in its own process"
  }
  Set-Stage "enumerate-drop-filtered-events-items"
  $dropItems = $dropMenu.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $dropMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  foreach ($item in $dropItems) {
    $itemState = $item.Current
    if ($itemState.Name -eq "Drop Filtered Events" -and
      $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
      $dropMatches.Add($item)
    }
  }
  $dropItemCount = [Math]::Min($dropItems.Count, 9999)
  $dropMatchCount = [Math]::Min($dropMatches.Count, 9999)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_MENU_MATCH=items:$dropItemCount;matches:$dropMatchCount"
  )
  if ($dropMatches.Count -ne 1) {
    throw "Process Monitor open Filter menu did not expose one Drop Filtered Events item"
  }
  Set-Stage "find-drop-filtered-events"
  $drop = $dropMatches[0]
  $dropState = $drop.Current
  $togglePattern = $null
  Set-Stage "probe-drop-toggle-pattern"
  $hasTogglePattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.TogglePattern]::Pattern,
    [ref]$togglePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=toggle:$($hasTogglePattern.ToString().ToLowerInvariant())"
  )
  $invokePattern = $null
  Set-Stage "probe-drop-invoke-pattern"
  $hasInvokePattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=invoke:$($hasInvokePattern.ToString().ToLowerInvariant())"
  )
  $selectionItemPattern = $null
  Set-Stage "probe-drop-selection-item-pattern"
  $hasSelectionItemPattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern,
    [ref]$selectionItemPattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=selection-item:$($hasSelectionItemPattern.ToString().ToLowerInvariant())"
  )
  Set-Stage "probe-drop-item-state"
  $dropItemStatus = switch ($dropState.ItemStatus) {
    "Checked" { "checked" }
    "Unchecked" { "unchecked" }
    "On" { "on" }
    "Off" { "off" }
    "Mixed" { "mixed" }
    default { "other" }
  }
  $dropHelpText = switch ($dropState.HelpText) {
    "Checked" { "checked" }
    "Unchecked" { "unchecked" }
    "On" { "on" }
    "Off" { "off" }
    "Mixed" { "mixed" }
    default { "other" }
  }
  $dropFramework = switch ($dropState.FrameworkId) {
    "Win32" { "Win32" }
    "WPF" { "WPF" }
    "WinForm" { "WinForm" }
    "DirectUI" { "DirectUI" }
    default { "other" }
  }
  $dropNativeHandle = ($dropState.NativeWindowHandle -ne 0).ToString().ToLowerInvariant()
  $menuNativeHandle = (
    $dropMenu.Current.NativeWindowHandle -ne 0
  ).ToString().ToLowerInvariant()
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_ITEM_STATE=enabled:$($dropState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dropState.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($dropState.IsKeyboardFocusable.ToString().ToLowerInvariant());item-status:$dropItemStatus;help-text:$dropHelpText"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_ITEM_BACKEND=framework:$dropFramework;native-window-handle:$dropNativeHandle;menu-window-handle:$menuNativeHandle"
  )
  Set-Stage "probe-drop-native-menu-state"
  $mainWindowHandle = [System.IntPtr]$main.Current.NativeWindowHandle
  $dropMenuWindowHandle = [System.IntPtr]$dropMenu.Current.NativeWindowHandle
  $nativeDropMenuSnapshot = Get-NativeDropMenuSnapshot $mainWindowHandle $dropMenuWindowHandle $process.Id
  Write-NativeDropMenuSnapshot $nativeDropMenuSnapshot "before"
  $accessibleDropMenuSnapshot = $null
  if ($nativeDropMenuSnapshot.CheckState -eq "unavailable") {
    $accessibleDropMenuSnapshot = Get-AccessibleDropMenuSnapshot `
      $dropMenuWindowHandle $process.Id $false "before"
  }
  $dropCheckState = Get-VerifiedDropMenuCheckState `
    $nativeDropMenuSnapshot $accessibleDropMenuSnapshot
  Set-Stage "verify-drop-native-menu-state"
  if ($dropCheckState -eq "unavailable") {
    throw "Process Monitor native menu state could not be verified"
  }
  if (-not $dropState.IsEnabled -or $dropState.IsOffscreen) {
    throw "Process Monitor Drop Filtered Events is unavailable"
  }
  if ($dropCheckState -eq "off") {
    if (-not $hasInvokePattern) {
      throw "Process Monitor Drop Filtered Events cannot be enabled without InvokePattern"
    }
    Set-Stage "invoke-drop-filtered-events"
    $invokePattern.Invoke()
    Start-Sleep -Milliseconds 100

    Set-Stage "reopen-drop-filtered-events-menu"
    $filterMenu = Wait-Element $main $filterMenuCondition 5
    $reopenMenuPattern = $null
    if (-not $filterMenu.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$reopenMenuPattern
      )) {
      throw "Process Monitor Filter menu does not expose InvokePattern after toggle"
    }
    $reopenMenuPattern.Invoke()

    Set-Stage "resolve-drop-filtered-events-menu-after-invoke"
    $dropMenu = $null
    $dropMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
      for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
        if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
          $dropMenu = $focused
          break
        }
        $focused = $treeWalker.GetParent($focused)
      }
      if ($null -ne $dropMenu) { break }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $dropMenuDeadline)
    if ($null -eq $dropMenu) {
      throw "Process Monitor did not expose the reopened Filter menu"
    }
    $dropMenuState = $dropMenu.Current
    if ($dropMenuState.ProcessId -ne $process.Id -or
      -not $dropMenuState.IsEnabled -or
      $dropMenuState.IsOffscreen) {
      throw "Process Monitor reopened Filter menu is not available in its own process"
    }

    Set-Stage "enumerate-drop-filtered-events-items-after-invoke"
    $dropItems = $dropMenu.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $dropMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($item in $dropItems) {
      $itemState = $item.Current
      if ($itemState.Name -eq "Drop Filtered Events" -and
        $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
        $dropMatches.Add($item)
      }
    }
    if ($dropMatches.Count -ne 1) {
      throw "Process Monitor reopened Filter menu did not expose one Drop Filtered Events item"
    }
    $drop = $dropMatches[0]
    $dropState = $drop.Current
    if (-not $dropState.IsEnabled -or $dropState.IsOffscreen) {
      throw "Process Monitor reopened Drop Filtered Events item is unavailable"
    }

    $dropMenuWindowHandle = [System.IntPtr]$dropMenu.Current.NativeWindowHandle
    Set-Stage "verify-drop-native-menu-state"
    $nativeDropMenuSnapshot = Get-NativeDropMenuSnapshot `
      $mainWindowHandle $dropMenuWindowHandle $process.Id
    Write-NativeDropMenuSnapshot $nativeDropMenuSnapshot "after-invoke"
    $accessibleDropMenuSnapshot = $null
    if ($nativeDropMenuSnapshot.CheckState -eq "unavailable") {
      $accessibleDropMenuSnapshot = Get-AccessibleDropMenuSnapshot `
        $dropMenuWindowHandle $process.Id $false "after-invoke"
    }
    $dropCheckState = Get-VerifiedDropMenuCheckState `
      $nativeDropMenuSnapshot $accessibleDropMenuSnapshot
    if ($dropCheckState -ne "on") {
      throw "Process Monitor did not enable Drop Filtered Events"
    }
  }
  Set-Stage "drop-filtered-events-verified"

  Set-Stage "save-filter"
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
  Set-Stage "find-main-before-export"
  $main = Wait-MainWindow $process
  Set-Stage "activate-main-before-export"
  Set-VerifiedProcmonMainWindowForeground $main $process "MAIN"
  Set-Stage "open-file-menu-for-export"
  [System.Windows.Forms.SendKeys]::SendWait("%f")
  Set-Stage "resolve-file-menu-for-export"
  $saveMenu = $null
  $saveMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
        $saveMenu = $focused
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -ne $saveMenu) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $saveMenuDeadline)
  if ($null -eq $saveMenu) {
    throw "Process Monitor did not expose its File menu for configuration export"
  }
  $saveMenuState = $saveMenu.Current
  if ($saveMenuState.ProcessId -ne $process.Id -or
    -not $saveMenuState.IsEnabled -or
    $saveMenuState.IsOffscreen) {
    throw "Process Monitor File menu is not available for export in its own process"
  }
  Write-MenuItemsObservation "before-save" $saveMenu
  Set-Stage "find-export-config-command"
  $saveCommands = $saveMenu.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $saveMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  foreach ($item in $saveCommands) {
    $itemState = $item.Current
    if ($itemState.Name -eq "Export Configuration..." -and
      $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
      $saveMatches.Add($item)
    }
  }
  if ($saveMatches.Count -ne 1) {
    throw "Process Monitor File menu did not expose one Export Configuration command"
  }
  $saveFilter = $saveMatches[0]
  $saveFilterState = $saveFilter.Current
  if ($saveFilterState.ProcessId -ne $process.Id -or
    -not $saveFilterState.IsEnabled -or $saveFilterState.IsOffscreen) {
    throw "Process Monitor Export Configuration command is unavailable"
  }
  Set-Stage "probe-export-config-command"
  $saveInvokePattern = $null
  if (-not $saveFilter.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$saveInvokePattern
    )) {
    throw "Process Monitor Export Configuration command does not expose InvokePattern"
  }
  Set-Stage "invoke-export-config-command"
  $saveInvokePattern.Invoke()
  Set-Stage "wait-export-config-dialog"
  try {
    $saveControls = Wait-ConfigSaveDialog $process $main
  } catch {
    Write-ConfigSaveResultObservation "export-timeout" $process $main
    throw
  }
  $fileName = $saveControls.FileName
  $save = $saveControls.Save
  if ($fileName.Current.ProcessId -ne $process.Id -or
    $save.Current.ProcessId -ne $process.Id -or
    -not $fileName.Current.IsEnabled -or $fileName.Current.IsOffscreen -or
    -not $save.Current.IsEnabled -or $save.Current.IsOffscreen) {
    throw "Process Monitor configuration save controls are unavailable"
  }
  Set-Stage "activate-export-config-dialog"
  $dialogHandle = [IntPtr]$saveControls.Dialog.Current.NativeWindowHandle
  $foregroundGate = "failed"
  if (
    $dialogHandle -ne [IntPtr]::Zero -and
    [ProcmonNativeMenu]::GetWindowProcessId($dialogHandle) -eq $process.Id
  ) {
    [ProcmonNativeMenu]::SetForegroundWindow($dialogHandle) | Out-Null
    $foregroundDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
      if (
        $foregroundHandle -eq $dialogHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle) -eq $process.Id
      ) {
        $foregroundGate = "passed"
        break
      }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $foregroundDeadline)
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FOREGROUND=gate:$foregroundGate")
  if ($foregroundGate -ne "passed") {
    Write-ConfigSaveObservation "foreground-failed" $saveControls $process.Id $ConfigPath
    throw "Process Monitor configuration save dialog did not become the foreground window"
  }
  Set-Stage "set-export-config-path"
  $fileNamePattern = $fileName.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  if ($fileNamePattern.Current.IsReadOnly) {
    throw "Process Monitor configuration file name is read-only"
  }
  $fileName.SetFocus()
  $fileNameFocus = Wait-KeyboardFocus $fileName
  if (
    $null -eq $fileNameFocus -or
    $fileNameFocus.ProcessId -ne $process.Id -or
    -not $fileNameFocus.IsEnabled -or
    $fileNameFocus.IsOffscreen -or
    -not $fileNameFocus.IsKeyboardFocusable -or
    [ProcmonNativeMenu]::GetForegroundWindow() -ne $dialogHandle
  ) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FILENAME=gate:failed")
    throw "Process Monitor configuration file name control did not receive keyboard focus"
  }
  [System.Windows.Forms.SendKeys]::SendWait("^a")
  [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-SendKeysLiteral $ConfigPath))
  $fileNameGate = if ($fileNamePattern.Current.Value -ceq $ConfigPath) {
    "passed"
  } else {
    "failed"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FILENAME=gate:$fileNameGate")
  if ($fileNameGate -ne "passed") {
    throw "Process Monitor configuration file name did not retain the requested path"
  }
  Set-Stage "focus-export-config-save"
  if (-not $save.Current.IsKeyboardFocusable) {
    throw "Process Monitor configuration Save button cannot receive focus"
  }
  $save.SetFocus()
  Set-Stage "verify-export-config-path"
  $saveFocusState = Wait-KeyboardFocus $save
  $saveFocusGate = if (
    $null -ne $saveFocusState -and
    $saveFocusState.ProcessId -eq $process.Id -and
    $saveFocusState.IsEnabled -and
    -not $saveFocusState.IsOffscreen -and
    $saveFocusState.IsKeyboardFocusable -and
    $saveFocusState.HasKeyboardFocus
  ) { "passed" } else { "failed" }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FOCUS=gate:$saveFocusGate")
  if ($saveFocusGate -ne "passed") {
    Write-ConfigSaveObservation "focus-failed" $saveControls $process.Id $ConfigPath
    throw "Process Monitor configuration Save button did not receive keyboard focus"
  }
  $finalForegroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
  $finalForegroundGate = if (
    $finalForegroundHandle -eq $dialogHandle -and
    [ProcmonNativeMenu]::GetWindowProcessId($finalForegroundHandle) -eq $process.Id
  ) { "passed" } else { "failed" }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FINAL_FOREGROUND=gate:$finalForegroundGate")
  if ($finalForegroundGate -ne "passed") {
    Write-ConfigSaveObservation "foreground-failed" $saveControls $process.Id $ConfigPath
    throw "Process Monitor configuration save dialog lost foreground before activation"
  }
  Write-ConfigOutputObservation "before-save" $ConfigPath
  Set-Stage "confirm-export-config-enter"
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  Write-ConfigSaveResultObservation "after-enter" $process $main
  Write-FocusObservation "after-invoke"
  Write-FocusOwnerObservation "after-save-enter" $process $main
  Write-ConfigSaveObservation "after-invoke" $saveControls $process.Id $ConfigPath
  Write-ConfigOutputObservation "after-invoke" $ConfigPath
  Set-Stage "verify-filter-file"
  try {
    Wait-FilterConfigFile $ConfigPath
  } catch {
    Write-ConfigSaveObservation "verify-failed" $saveControls $process.Id $ConfigPath
    Write-ConfigOutputObservation "after-wait" $ConfigPath
    Write-ConfigSaveResultObservation "after-wait" $process $main
    throw
  }
  Set-Stage "verify-exported-filter-paths"
  Get-ConfigFilterPathEvidence $ConfigPath $CanaryPath $ControlPath | Out-Null
  Write-ConfigOutputObservation "after-wait" $ConfigPath
  Write-ConfigSaveResultObservation "after-wait" $process $main

  Set-Stage "close-procmon-before-config-reload"
  if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(5000)) {
    throw "Process Monitor did not close before configuration reload"
  }
  Set-Stage "reload-exported-config"
  $process = Start-Process `
    -FilePath $ProcmonPath `
    -ArgumentList @("/AcceptEula", "/LoadConfig", ('"{0}"' -f $ConfigPath)) `
    -PassThru
  if (-not $process.WaitForInputIdle(10000)) {
    throw "Process Monitor configuration reload did not become idle"
  }
  }
  Set-Stage "find-reloaded-main-window"
  $main = Wait-MainWindow $process
  Set-Stage "activate-reloaded-main-window"
  Set-VerifiedProcmonMainWindowForeground $main $process "RELOAD_MAIN"
  $mainWindowHandle = [IntPtr]$main.Current.NativeWindowHandle
  Set-Stage "verify-reloaded-filter-dialog-shortcut-foreground"
  $currentForegroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
  if ($currentForegroundHandle -ne $mainWindowHandle -or
    [ProcmonNativeMenu]::GetWindowProcessId($currentForegroundHandle) -ne $process.Id) {
    throw "Process Monitor reloaded main window lost the foreground before the Filter shortcut"
  }
  Set-Stage "open-reloaded-filter-dialog-shortcut"
  $reloadShortcutInput = [ProcmonNativeMenu]::SendControlLShortcut(
    $mainWindowHandle,
    $process.Id
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SHORTCUT_INPUT=state:$($reloadShortcutInput.State);events:$($reloadShortcutInput.Events);release-events:$($reloadShortcutInput.ReleaseEvents)"
  )
  if ($reloadShortcutInput.State -ne "sent" -or $reloadShortcutInput.Events -ne 4) {
    throw "Process Monitor reload filter shortcut input failed"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_RELOAD_SHORTCUT=command:filter-dialog;state:sent")
  Write-FocusObservation "after-reload-filter-dialog-shortcut" | Out-Null
  Set-Stage "wait-reloaded-filter-dialog"
  $reloadFilterDialog = Wait-FilterDialog $process $main
  Set-Stage "read-reloaded-filter-rules"
  $reloadFilterRows = Get-LoadedFilterRuleRows $reloadFilterDialog $process.Id -Reloaded
  Set-Stage "verify-reloaded-filter-rules"
  Get-LoadedFilterRuleEvidence $reloadFilterRows $CanaryPath $ControlPath | Out-Null
  Close-ReloadedFilterDialog $reloadFilterDialog $main $process.Id
  $reloadMainHandle = [IntPtr]$main.Current.NativeWindowHandle
  Set-Stage "read-reloaded-drop-state"
  $reloadDropCheckState = Get-ReloadedNativeDropCheckState `
    $reloadMainHandle $process.Id
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_RELOADED_DROP=checked:$reloadDropCheckState"
  )
  if ($reloadDropCheckState -ne "on") {
    throw "Process Monitor did not reload Drop Filtered Events as enabled"
  }
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
  Set-Stage "reloaded-filter-rules-verified"
  if ($PSBoundParameters.ContainsKey("CaptureProcessId")) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_LIVE_VERIFIED=rules:exact-two;drop:on")
  }
} catch {
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILED_STAGE=$stage")
  $failureException = $_.Exception
  if (
    $failureException.GetType().Name -eq "MethodInvocationException" -and
    $null -ne $failureException.InnerException
  ) {
    $failureException = $failureException.InnerException
  }
  $failureType = $failureException.GetType().Name
  if ($failureType -notin @(
      "AmbiguousMatchException",
      "ArgumentException",
      "DllNotFoundException",
      "EntryPointNotFoundException",
      "COMException",
      "ElementNotAvailableException",
      "InvalidOperationException",
      "MethodAccessException",
      "MethodException",
      "MethodInvocationException",
      "MissingMethodException",
      "NullReferenceException",
      "RuntimeException",
      "TargetInvocationException",
      "TypeInitializationException"
    )) {
    $failureType = "Other"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILURE=$failureType")
  exit 1
} finally {
  if (-not $PSBoundParameters.ContainsKey("CaptureProcessId") -and -not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(5000)) {
      Stop-Process -Id $process.Id -Force
    }
  }
}
