using System.Diagnostics;

namespace DevSuite.Launcher;

/// <summary>
/// Visual Studio 2026 F5 entry point for the devsuite: resolves the solution
/// root and tilt, then runs `tilt up` (or ci/down) there. See
/// docs/visual-studio.md and Options.Usage.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            var options = Options.Parse(args);
            if (options.Command == Command.Help)
            {
                Console.WriteLine(Options.Usage);
                return 0;
            }

            var root = ToolLocator.FindRoot(options.Root);
            var settings = DevSuiteSettings.Load(root);
            if (options.Command == Command.AttachConfig)
            {
                new AttachConfigGenerator(settings).Generate();
                return 0;
            }

            var tilt = ToolLocator.FindTilt(options.TiltPath, settings);
            var session = new TiltSession(options, settings, tilt);
            switch (options.Command)
            {
                case Command.DownWhenExited:
                    return session.DownWhenExited();
                case Command.Doctor:
                    return Doctor(settings, tilt);
                case Command.Down:
                    return session.Down();
                case Command.Ci:
                    Log.Info("launcher", $"root {root}, tilt {tilt}");
                    return session.Ci();
                default:
                    Log.Info("launcher", $"root {root}, tilt {tilt}");
                    if (options.AttachConfig ?? settings.AttachEnabled)
                        new AttachConfigGenerator(settings).Generate();
                    return session.Up();
            }
        }
        catch (UsageException e)
        {
            Log.Error("launcher", e.Message);
            Console.Error.WriteLine(Options.Usage);
            return 2;
        }
        catch (LauncherException e)
        {
            Log.Error("launcher", e.Message);
            return 1;
        }
    }

    private static int Doctor(DevSuiteSettings settings, string tilt)
    {
        Log.Info("doctor", $"root          {settings.Root}");
        Log.Info("doctor", $"tilt          {tilt} ({FirstLine(tilt, "version")})");
        Log.Info("doctor", $"compose_cmd   {settings.ComposeCmd} ({FirstLine(settings.ComposeCmd, "version")})");
        Log.Info("doctor", $"compose files {string.Join(", ", settings.ComposeFiles)} (project {settings.ResolveProjectName()})");
        Log.Info("doctor", $"engine        {ToolLocator.ResolveEngine(settings.Engine)} (attach files)");
        Log.Info("doctor", $"work_dir      {settings.WorkDirFull}");
        Log.Info("doctor", $"up            port {settings.Port}, open_browser {settings.OpenBrowser}, down_on_exit {settings.DownOnExit}, stream {settings.Stream}");
        Log.Info("doctor", "Podman/engine checks: devsuite/podman/Test-DevSuite.ps1 (task E)");
        return 0;
    }

    private static string FirstLine(string command, string arg)
    {
        var parts = command.Split(' ', StringSplitOptions.RemoveEmptyEntries).Append(arg).ToArray();
        try
        {
            var psi = new ProcessStartInfo(parts[0]) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var p in parts.Skip(1))
                psi.ArgumentList.Add(p);
            using var proc = Process.Start(psi)!;
            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit();
            return output.Split('\n').FirstOrDefault()?.Trim() is { Length: > 0 } line ? line : $"exit {proc.ExitCode}";
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            return $"not runnable: {e.Message}";
        }
    }
}
