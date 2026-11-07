using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace XivSpell;

// Event-driven characters: even a press shorter than one game frame is retained.
// Native character translation preserves spaces, punctuation and keyboard layouts.
internal sealed class SpellKeyboard : IDisposable
{
    internal enum Kind { Character, Escape, Input, Backspace, TextBackspace, ClearLine, Complete, Commit, Movement }
    internal readonly record struct Input(Kind Type, char Character = '\0');
    internal readonly ConcurrentQueue<Input> Events = new();
    internal bool Enabled, Capture = true;
    internal volatile bool CaptureCombatEnter;
    private int combatEnterRequested;
    internal bool TakeCombatEnter() => Interlocked.Exchange(ref combatEnterRequested, 0) != 0;
    internal bool Installed => window != 0;
    private readonly BackspaceGesture backspace = new();
    private readonly object backspaceGate = new();
    internal void PollBackspace(long now, bool down, bool hasDraft = false)
    {
        lock (backspaceGate) {
            if (backspace.Poll(now, down, Enabled && Capture, hasDraft)) Events.Enqueue(new(Kind.ClearLine));
            else if (backspace.EraseText) Events.Enqueue(new(Kind.TextBackspace));
        }
    }
    private nint window;
    private readonly SubclassProc callback;
    private const nuint Id = 0x5853504C;
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc proc, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc proc, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern short GetKeyState(int key);
    internal SpellKeyboard() => callback = Handle;
    internal void Install()
    {
        if (window != 0) return;
        using var process = Process.GetCurrentProcess();
        var hwnd = process.MainWindowHandle;
        if (hwnd != 0 && SetWindowSubclass(hwnd, callback, Id, 0)) window = hwnd;
    }
    private nint Handle(nint hwnd, uint message, nuint value, nint param, nuint id, nuint data)
    {
        try {
            if (message == 0x101 && value == 0x08) { lock (backspaceGate) backspace.Release(); }
            // Intercept before the native chat sees WM_KEYDOWN. Framework key
            // filtering alone cannot retain a tap shorter than one frame.
            if (message == 0x100 && value == 0x0D && CaptureCombatEnter &&
                (GetKeyState(0x11) & 0x8000) == 0 && (GetKeyState(0x12) & 0x8000) == 0 && (GetKeyState(0x10) & 0x8000) == 0)
            {
                if (((long)param & (1L << 30)) == 0) {
                    if (!Capture) Interlocked.Exchange(ref combatEnterRequested, 1);
                    else Events.Enqueue(new(Kind.Commit));
                }
                Capture = true;
                return 0;
            }
            if (Enabled && (GetKeyState(0x11) & 0x8000) == 0 && (GetKeyState(0x12) & 0x8000) == 0) {
                if (message == 0x100) { // WM_KEYDOWN; ignore operating-system key repeat
                    var key = (int)value;
                    var fresh = ((long)param & (1L << 30)) == 0;
                    if (key == 0x1B) { if (fresh) { Capture = false; Events.Enqueue(new(Kind.Escape)); } }
                    else if (key is >= 0x25 and <= 0x28 || (!Capture && key is 0x57 or 0x41 or 0x53 or 0x44)) {
                        if (fresh) Events.Enqueue(new(Kind.Movement));
                    } else if (Capture && key is 0x08 or 0x09 or 0x0D) {
                        if (key == 0x08 && fresh) { lock (backspaceGate) backspace.Press(Environment.TickCount64); }
                        if (fresh) Events.Enqueue(new(key == 0x08 ? Kind.Backspace : key == 0x09 ? Kind.Complete : Kind.Commit));
                        return 0;
                    } else if ((Capture && (key is >= 0x30 and <= 0x5A || key is >= 0xBA and <= 0xE2 || key is 0x20 or 0x0D)) || (!Capture && key is 0x49 or 0xBE)) return 0;
                } else if (message == 0x102) { // WM_CHAR, produced by the game's TranslateMessage
                    var ch = (char)value;
                    if (((long)param & (1L << 30)) != 0) return 0;
                    if (ch is '.' or '>') { Events.Enqueue(new(Kind.Character, ch)); return 0; }
                    if (!Capture && ch == ':') { Capture = true; Events.Enqueue(new(Kind.Input)); Events.Enqueue(new(Kind.Character, ch)); return 0; }
                    if (!Capture && ch is 'i' or 'I') { Capture = true; Events.Enqueue(new(Kind.Input)); return 0; }
                    if (Capture) { if (!char.IsControl(ch)) Events.Enqueue(new(Kind.Character, ch)); return 0; }
                }
            }
        } catch { Enabled = false; } // managed exceptions must never cross the window procedure
        return DefSubclassProc(hwnd, message, value, param);
    }
    public void Dispose()
    {
        Enabled = false;
        CaptureCombatEnter = false;
        Interlocked.Exchange(ref combatEnterRequested, 0);
        lock (backspaceGate) backspace.Release();
        if (window != 0) RemoveWindowSubclass(window, callback, Id);
        window = 0;
        GC.KeepAlive(callback);
    }
}
