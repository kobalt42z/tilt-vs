using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DevSuite.Launcher;

/// <summary>tilt up / ci / down in the solution root.</summary>
internal sealed class TiltSession(Options options, DevSuiteSettings settings, string tilt)
{
    private static readonly TimeSpan StopGrace = TimeSpan.FromSeconds(15);

    public int Up()
    {
        var port = options.Port ?? settings.Port;
        var args = new List<string> { "up", "--port", port.ToString() };
        if (settings.Stream)
            args.Add("--stream=true");
        args.AddRange(options.TiltArgs);
        AddDevSuiteArgs(args);

        using var child = ChildProcess.Start(tilt, args, settings.Root);
        if (options.DownOnExit ?? settings.DownOnExit)
            StartDownWatcher(child.Id);

        using var stopping = new CancellationTokenSource();
        using var signals = HookStopSignals(child, stopping);

        if ((options.OpenBrowser ?? settings.OpenBrowser) && port != 0)
            _ = OpenUiWhenReady(port, child, stopping.Token);
        else if (port != 0)
            Log.Info("launcher", $"Tilt UI: http://localhost:{port}/");

        var code = child.WaitForExit();
        stopping.Cancel();
        Log.Info("launcher", $"tilt up exited with code {code}");
        return code;
    }

    public int Ci()
    {
        var args = new List<string> { "ci", "--port", (options.Port ?? 0).ToString() };
        args.AddRange(options.TiltArgs);
        AddDevSuiteArgs(args);

        int code;
        using (var child = ChildProcess.Start(tilt, args, settings.Root))
        using (HookStopSignals(child, null))
            code = child.WaitForExit();
        Log.Info("launcher", code == 0 ? "tilt ci passed" : $"tilt ci failed with code {code}");

        if (options.DownOnExit == true)
        {
            var downCode = Down();
            if (code == 0 && downCode != 0)
                code = downCode;
        }
        return code;
    }

    public int Down()
    {
        var args = new List<string> { "down" };
        args.AddRange(options.TiltArgs);
        AddDevSuiteArgs(args);
        var code = ChildProcess.Run(tilt, args, settings.Root);
        Log.Info("launcher", $"tilt down exited with code {code}");
        return code;
    }

    /// <summary>
    /// Detached watcher: waits for <see cref="Options.ParentPid"/> to exit,
    /// however it exits (Ctrl+C, VS Stop Debugging, closing the console), then
    /// runs tilt down. Logs to &lt;work_dir&gt;/launcher/down.log.
    /// </summary>
    public int DownWhenExited()
    {
        Directory.CreateDirectory(Path.Combine(settings.WorkDirFull, "launcher"));
        Log.FilePath = Path.Combine(settings.WorkDirFull, "launcher", "down.log");
        // Nobody reads our stdout once the launcher is gone; log to the file only.
        Console.SetOut(TextWriter.Null);
        Console.SetError(TextWriter.Null);
        try
        {
            using var parent = Process.GetProcessById(options.ParentPid);
            Log.Info("launcher", $"waiting for launcher pid {options.ParentPid} to exit");
            parent.WaitForExit();
        }
        catch (ArgumentException)
        {
            // Parent already gone.
        }
        StopOrphanedTilt();
        Log.Info("launcher", "launcher stopped, running tilt down");
        var psi = new ProcessStartInfo(tilt)
        {
            WorkingDirectory = settings.Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("down");
        foreach (var a in options.TiltArgs)
            psi.ArgumentList.Add(a);
        if (options.DevSuiteArgs.Count > 0)
        {
            psi.ArgumentList.Add("--");
            foreach (var a in options.DevSuiteArgs)
                psi.ArgumentList.Add(a);
        }
        using var p = Process.Start(psi)!;
        p.OutputDataReceived += (_, e) => { if (e.Data is not null) Log.Info("tilt", e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data is not null) Log.Info("tilt", e.Data); };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        p.WaitForExit();
        Log.Info("launcher", $"tilt down exited with code {p.ExitCode}");
        return p.ExitCode;
    }

    /// <summary>
    /// A hard-killed launcher leaves tilt up running on Unix (Windows: the job
    /// object already killed it). tilt down must not race a live tilt up.
    /// </summary>
    private void StopOrphanedTilt()
    {
        if (options.ChildPid <= 0)
            return;
        try
        {
            using var orphan = Process.GetProcessById(options.ChildPid);
            if (!Path.GetFileNameWithoutExtension(orphan.ProcessName).StartsWith("tilt", StringComparison.OrdinalIgnoreCase))
                return; // pid reused by something else
            Log.Info("launcher", $"tilt up (pid {orphan.Id}) outlived the launcher, stopping it");
            orphan.Kill(entireProcessTree: true);
            orphan.WaitForExit(StopGrace);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Already gone.
        }
    }

    private void StartDownWatcher(int tiltPid)
    {
        var self = Environment.ProcessPath ?? throw new LauncherException("cannot locate the launcher binary");
        var psi = new ProcessStartInfo(self)
        {
            WorkingDirectory = settings.Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            // Detach from the VS console: the window may close before tilt down finishes.
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        // `dotnet run` / `dotnet DevSuite.Launcher.dll`: the process is the dotnet host.
        if (Path.GetFileNameWithoutExtension(self).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            psi.ArgumentList.Add(typeof(TiltSession).Assembly.Location);
        foreach (var a in new[] { "__down-when-exited", "--parent-pid", Environment.ProcessId.ToString(), "--child-pid", tiltPid.ToString(), "--root", settings.Root, "--tilt", tilt })
            psi.ArgumentList.Add(a);
        foreach (var a in options.TiltArgs)
        {
            psi.ArgumentList.Add("--tilt-arg");
            psi.ArgumentList.Add(a);
        }
        if (options.DevSuiteArgs.Count > 0)
        {
            psi.ArgumentList.Add("--");
            foreach (var a in options.DevSuiteArgs)
                psi.ArgumentList.Add(a);
        }
        var watcher = Process.Start(psi);
        Log.Info("launcher", $"tilt down will run when the launcher stops (watcher pid {watcher?.Id}, log {Path.Combine(settings.WorkDir, "launcher", "down.log")})");
    }

    private void AddDevSuiteArgs(List<string> args)
    {
        if (options.DevSuiteArgs.Count == 0)
            return;
        args.Add("--");
        args.AddRange(options.DevSuiteArgs);
    }

    /// <summary>
    /// Ctrl+C in the console reaches tilt directly (same console); the
    /// launcher only stays alive until tilt has shut down. On Unix the signal
    /// is also forwarded as SIGTERM. After a grace period tilt is killed.
    /// </summary>
    private static IDisposable HookStopSignals(ChildProcess child, CancellationTokenSource? stopping)
    {
        var registrations = new List<IDisposable>();
        void OnSignal(PosixSignalContext ctx)
        {
            ctx.Cancel = true;
            stopping?.Cancel();
            // A terminal Ctrl+C already reached tilt (same process group or
            // console); a signal sent to the launcher alone did not.
            child.RequestStop();
            Log.Info("launcher", "stopping tilt...");
            _ = Task.Run(() =>
            {
                if (!child.WaitForExit(StopGrace))
                {
                    Log.Warn("launcher", $"tilt still running after {StopGrace.TotalSeconds:0}s, killing it");
                    child.Kill();
                }
            });
        }
        registrations.Add(PosixSignalRegistration.Create(PosixSignal.SIGINT, OnSignal));
        registrations.Add(PosixSignalRegistration.Create(PosixSignal.SIGTERM, OnSignal));
        registrations.Add(PosixSignalRegistration.Create(PosixSignal.SIGQUIT, OnSignal));
        // Windows: closing the console window (CTRL_CLOSE_EVENT); Unix: terminal hangup.
        registrations.Add(PosixSignalRegistration.Create(PosixSignal.SIGHUP, OnSignal));
        return new Disposables(registrations);
    }

    private static async Task OpenUiWhenReady(int port, ChildProcess child, CancellationToken ct)
    {
        var url = $"http://localhost:{port}/";
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        var deadline = DateTime.UtcNow + TimeSpan.FromMinutes(2);
        while (!ct.IsCancellationRequested && !child.HasExited && DateTime.UtcNow < deadline)
        {
            try
            {
                using var resp = await http.GetAsync(url, ct);
                if (resp.IsSuccessStatusCode)
                {
                    OpenBrowser(url);
                    return;
                }
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { }
            catch (OperationCanceledException) { return; }
            try { await Task.Delay(500, ct); } catch (OperationCanceledException) { return; }
        }
        if (!child.HasExited && !ct.IsCancellationRequested)
            Log.Warn("launcher", $"Tilt UI did not answer on {url}; open it yourself");
    }

    private static void OpenBrowser(string url)
    {
        Log.Info("launcher", $"opening Tilt UI {url}");
        try
        {
            if (OperatingSystem.IsWindows())
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
            else if (OperatingSystem.IsMacOS())
                Process.Start("open", url)?.Dispose();
            else if (ToolLocator.FindOnPath("xdg-open") is { } xdg)
                Process.Start(xdg, url)?.Dispose();
            else
                Log.Info("launcher", "no browser opener found; open the URL above");
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Log.Warn("launcher", $"could not open a browser: {e.Message}");
        }
    }

    private sealed class Disposables(List<IDisposable> items) : IDisposable
    {
        public void Dispose() => items.ForEach(i => i.Dispose());
    }
}
