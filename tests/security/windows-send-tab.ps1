param(
  [Parameter(Mandatory = $true)]
  [string] $ApplicationPath,
  [ValidateSet("Tab", "Enter")]
  [string] $Key = "Tab",
  [switch] $Shift
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MailClientNativeKeyboardInput
{
    private const uint InputKeyboard = 1;
    private const ushort VirtualKeyTab = 0x09;
    private const ushort VirtualKeyShift = 0x10;
    private const uint KeyEventKeyUp = 0x0002;

    public static uint LastInserted { get; private set; }
    public static int LastError { get; private set; }

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
        public KeyboardInput Keyboard;

        [FieldOffset(0)]
        public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput
    {
        public uint Type;
        public InputUnion Data;
    }

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr GetAncestor(IntPtr window, uint flags);

    public static IntPtr GetForegroundRootWindow()
    {
        return GetAncestor(GetForegroundWindow(), 2);
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(
        IntPtr window,
        out uint processId
    );

    public static uint GetWindowProcessId(IntPtr window)
    {
        uint processId;
        return GetWindowThreadProcessId(window, out processId) == 0
            ? 0
            : processId;
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint SendInput(
        uint inputCount,
        NativeInput[] inputs,
        int inputSize
    );

    private static NativeInput CreateKeyInput(ushort virtualKey, uint flags)
    {
        return new NativeInput
        {
            Type = InputKeyboard,
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

    public static bool SendKeyToForegroundWindow(
        IntPtr expectedWindow,
        uint expectedProcessId,
        ushort virtualKey,
        bool shift
    )
    {
        const uint GetAncestorRoot = 2;
        if (shift && virtualKey != VirtualKeyTab)
        {
            return false;
        }

        var foregroundWindow = GetForegroundWindow();
        if (expectedWindow == IntPtr.Zero ||
            GetAncestor(foregroundWindow, GetAncestorRoot) != expectedWindow)
        {
            return false;
        }

        uint foregroundProcessId;
        if (GetWindowThreadProcessId(foregroundWindow, out foregroundProcessId) == 0 ||
            foregroundProcessId != expectedProcessId)
        {
            return false;
        }

        NativeInput[] inputs = shift
            ? new[]
            {
                CreateKeyInput(VirtualKeyShift, 0),
                CreateKeyInput(virtualKey, 0),
                CreateKeyInput(virtualKey, KeyEventKeyUp),
                CreateKeyInput(VirtualKeyShift, KeyEventKeyUp)
            }
            : new[]
            {
                CreateKeyInput(virtualKey, 0),
                CreateKeyInput(virtualKey, KeyEventKeyUp)
            };
        var inserted = SendInput(
            (uint) inputs.Length,
            inputs,
            Marshal.SizeOf(typeof(NativeInput))
        );
        LastInserted = inserted;
        LastError = Marshal.GetLastWin32Error();
        if (inserted == (uint) inputs.Length)
        {
            return true;
        }

        SendInput(
            2,
            new[]
            {
                CreateKeyInput(virtualKey, KeyEventKeyUp),
                CreateKeyInput(VirtualKeyShift, KeyEventKeyUp)
            },
            Marshal.SizeOf(typeof(NativeInput))
        );
        return false;
    }
}
'@

$resolvedApplicationPath = [System.IO.Path]::GetFullPath($ApplicationPath)
$applicationName = [System.IO.Path]::GetFileNameWithoutExtension(
  $resolvedApplicationPath
)
$applicationProcesses = @(
  Get-Process -Name $applicationName -ErrorAction Stop |
    Where-Object {
      $_.Path -and
      [string]::Equals(
        [System.IO.Path]::GetFullPath($_.Path),
        $resolvedApplicationPath,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    }
)

if ($applicationProcesses.Count -ne 1) {
  throw "Expected exactly one running security-test application"
}

$applicationProcess = $applicationProcesses[0]
$applicationWindow = [IntPtr] $applicationProcess.MainWindowHandle
if ($applicationWindow -eq [IntPtr]::Zero) {
  throw "Security-test application has no main window"
}

$virtualKey = if ($Key -eq "Enter") { [uint16] 0x0D } else { [uint16] 0x09 }
if (-not [MailClientNativeKeyboardInput]::SendKeyToForegroundWindow(
  $applicationWindow,
  [uint32] $applicationProcess.Id,
  $virtualKey,
  [bool] $Shift
)) {
  $foregroundWindow = [MailClientNativeKeyboardInput]::GetForegroundWindow()
  $foregroundProcessId = [MailClientNativeKeyboardInput]::GetWindowProcessId(
    $foregroundWindow
  )
  $foregroundRootWindow = [MailClientNativeKeyboardInput]::GetForegroundRootWindow()
  throw "Native keyboard input was refused or incomplete: expected process $($applicationProcess.Id), foreground process $foregroundProcessId, root matched $($foregroundRootWindow -eq $applicationWindow), inserted $([MailClientNativeKeyboardInput]::LastInserted), last error $([MailClientNativeKeyboardInput]::LastError)"
}

Write-Output "NATIVE_KEY_SENT"
