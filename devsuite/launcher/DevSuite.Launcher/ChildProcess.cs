using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DevSuite.Launcher;

/// <summary>
/// Runs a child (tilt) sharing the launcher's console, so its output streams
/// straight into the VS console window with colors, and Ctrl+C reaches it.
/// On Windows the child goes into a job object with KILL_ON_JOB_CLOSE: when
/// VS stops debugging it terminates the launcher, and the job takes tilt and
/// its docker-compose children down with it instead of leaving them orphaned.
/// </summary>
internal sealed class ChildProcess : IDisposable
{
    private readonly Process _process;
    private readonly WindowsJob? _job;

    private ChildProcess(Process process, WindowsJob? job)
    {
        _process = process;
        _job = job;
    }

    public int Id => _process.Id;
    public bool HasExited => _process.HasExited;
    public int ExitCode => _process.ExitCode;

    public static ChildProcess Start(string file, IEnumerable<string> args, string workingDir)
    {
        var psi = new ProcessStartInfo(file) { WorkingDirectory = workingDir, UseShellExecute = false };
        foreach (var a in args)
            psi.ArgumentList.Add(a);
        Log.Info("launcher", $"> {Quote(file)} {string.Join(' ', psi.ArgumentList.Select(Quote))}  (in {workingDir})");
        var p = Process.Start(psi) ?? throw new LauncherException($"could not start {file}");

        WindowsJob? job = null;
        if (OperatingSystem.IsWindows())
        {
            try
            {
                job = new WindowsJob();
                job.Add(p);
            }
            catch (Win32Exception e)
            {
                // Nested jobs are fine on Windows 8+; if it still fails, tilt
                // just will not die with a hard-killed launcher.
                Log.Warn("launcher", $"could not tie tilt to the launcher lifetime: {e.Message}");
                job?.Dispose();
                job = null;
            }
        }
        return new ChildProcess(p, job);
    }

    /// <summary>Runs to completion and returns the exit code.</summary>
    public static int Run(string file, IEnumerable<string> args, string workingDir)
    {
        using var child = Start(file, args, workingDir);
        return child.WaitForExit();
    }

    public int WaitForExit()
    {
        _process.WaitForExit();
        return _process.ExitCode;
    }

    public bool WaitForExit(TimeSpan timeout) => _process.WaitForExit(timeout);

    public Task WaitForExitAsync(CancellationToken ct = default) => _process.WaitForExitAsync(ct);

    /// <summary>Ask nicely (SIGTERM on Unix); on Windows Ctrl+C already reached it through the console.</summary>
    public void RequestStop()
    {
        if (_process.HasExited)
            return;
        if (!OperatingSystem.IsWindows())
            _ = Native.kill(_process.Id, Native.SIGTERM);
    }

    public void Kill()
    {
        try
        {
            if (!_process.HasExited)
                _process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // Already gone.
        }
    }

    public void Dispose()
    {
        _job?.Dispose();
        _process.Dispose();
    }

    public static string Quote(string s) => s.Length == 0 || s.Any(char.IsWhiteSpace) ? $"\"{s}\"" : s;

    private static class Native
    {
        public const int SIGTERM = 15;

        [DllImport("libc", SetLastError = true)]
        public static extern int kill(int pid, int sig);
    }
}

/// <summary>Minimal Win32 job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.</summary>
internal sealed class WindowsJob : IDisposable
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    private IntPtr _handle;

    public WindowsJob()
    {
        _handle = CreateJobObject(IntPtr.Zero, null);
        if (_handle == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error());

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
        };
        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(_handle, JobObjectExtendedLimitInformation, ptr, (uint)size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    public void Add(Process p)
    {
        if (!AssignProcessToJobObject(_handle, p.Handle))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public void Dispose()
    {
        // Closing the last handle kills whatever is still in the job.
        if (_handle != IntPtr.Zero)
        {
            CloseHandle(_handle);
            _handle = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
