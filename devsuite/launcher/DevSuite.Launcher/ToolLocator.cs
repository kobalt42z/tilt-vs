namespace DevSuite.Launcher;

internal static class ToolLocator
{
    private static readonly string[] Extensions = OperatingSystem.IsWindows()
        ? (Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.CMD;.BAT")
            .Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Prepend("")
            .ToArray()
        : [""];

    /// <summary>
    /// Solution root: --root, DEVSUITE_ROOT, else the first parent (of the
    /// working directory, then of the launcher binary) holding a Tiltfile and
    /// devsuite/tilt/main.star.
    /// </summary>
    public static string FindRoot(string? explicitRoot)
    {
        var given = explicitRoot ?? Environment.GetEnvironmentVariable("DEVSUITE_ROOT");
        if (!string.IsNullOrEmpty(given))
        {
            var full = Path.GetFullPath(given);
            if (!File.Exists(Path.Combine(full, "Tiltfile")))
                throw new LauncherException($"no Tiltfile in {full} (from --root / DEVSUITE_ROOT)");
            return full;
        }
        foreach (var start in new[] { Environment.CurrentDirectory, AppContext.BaseDirectory })
        {
            for (var dir = new DirectoryInfo(start); dir is not null; dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, "Tiltfile")) &&
                    File.Exists(Path.Combine(dir.FullName, "devsuite", "tilt", "main.star")))
                    return dir.FullName;
            }
        }
        throw new LauncherException(
            $"solution root not found above {Environment.CurrentDirectory} or {AppContext.BaseDirectory}; pass --root <dir>");
    }

    /// <summary>tilt: --tilt, launcher.tilt_path, PATH, then &lt;root&gt;/tools.</summary>
    public static string FindTilt(string? explicitPath, DevSuiteSettings settings)
    {
        var tried = new List<string>();
        foreach (var (candidate, source) in new[] { (explicitPath, "--tilt"), (settings.TiltPath, "launcher.tilt_path") })
        {
            if (string.IsNullOrEmpty(candidate))
                continue;
            var full = Path.GetFullPath(Environment.ExpandEnvironmentVariables(candidate), settings.Root);
            var hit = WithExtensions(full).FirstOrDefault(File.Exists);
            if (hit is not null)
            {
                Log.Debug("launcher", $"tilt from {source}: {hit}");
                return hit;
            }
            tried.Add($"{full} ({source})");
        }

        var onPath = FindOnPath("tilt");
        if (onPath is not null)
        {
            Log.Debug("launcher", $"tilt from PATH: {onPath}");
            return onPath;
        }
        tried.Add("PATH");

        foreach (var dir in new[] { Path.Combine(settings.Root, "tools"), Path.Combine(settings.Root, "tools", "tilt") })
        {
            var hit = WithExtensions(Path.Combine(dir, "tilt")).FirstOrDefault(File.Exists);
            if (hit is not null)
            {
                Log.Debug("launcher", $"tilt from tools: {hit}");
                return hit;
            }
            tried.Add(dir);
        }
        throw new LauncherException($"tilt not found (tried {string.Join(", ", tried)}); install it or set launcher.tilt_path in devsuite.local.json");
    }

    /// <summary>Container CLI written into the attach files (launcher.engine).</summary>
    public static string ResolveEngine(string engine)
    {
        if (engine is "auto" or "")
            return FindOnPath("podman") ?? FindOnPath("docker") ?? "docker";
        if (engine is "podman" or "docker")
            return FindOnPath(engine) ?? engine;
        return engine;
    }

    public static string? FindOnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var candidate in WithExtensions(Path.Combine(dir.Trim('"'), name)))
            {
                if (File.Exists(candidate))
                    return candidate;
            }
        }
        return null;
    }

    private static IEnumerable<string> WithExtensions(string path) =>
        Path.HasExtension(path) ? [path] : Extensions.Select(e => path + e.ToLowerInvariant());
}

internal sealed class LauncherException(string message) : Exception(message);
