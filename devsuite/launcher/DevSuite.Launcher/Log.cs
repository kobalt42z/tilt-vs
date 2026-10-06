namespace DevSuite.Launcher;

/// <summary>
/// Same line format as devsuite/tilt/log.star so the VS console and the Tilt
/// logs read alike: <c>[devsuite] LEVEL scope     | message</c>.
/// DEVSUITE_LOG_LEVEL=debug shows debug lines.
/// </summary>
internal static class Log
{
    private static readonly bool DebugEnabled =
        string.Equals(Environment.GetEnvironmentVariable("DEVSUITE_LOG_LEVEL"), "debug", StringComparison.OrdinalIgnoreCase);

    /// <summary>When set, lines also go to this file (used by the detached down watcher).</summary>
    public static string? FilePath { get; set; }

    public static void Debug(string scope, string message)
    {
        if (DebugEnabled)
            Write("DEBUG", scope, message, Console.Out);
    }

    public static void Info(string scope, string message) => Write("INFO", scope, message, Console.Out);

    public static void Warn(string scope, string message) => Write("WARN", scope, message, Console.Error);

    public static void Error(string scope, string message) => Write("ERROR", scope, message, Console.Error);

    private static void Write(string level, string scope, string message, TextWriter writer)
    {
        var line = $"[devsuite] {level,-5} {scope,-9} | {message}";
        writer.WriteLine(line);
        if (FilePath is null)
            return;
        try
        {
            File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // Logging must never stop the launcher.
        }
    }
}
