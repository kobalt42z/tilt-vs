using System.Text.Json;
using System.Text.Json.Nodes;

namespace DevSuite.Launcher;

/// <summary>
/// The part of devsuite.json (+ devsuite.local.json, later wins) the launcher
/// needs. Mirrors the merge in devsuite/tilt/settings.star; launcher keys live
/// in the "launcher" section:
/// <code>
/// "launcher": {
///   "tilt_path": "",            // "" = PATH, then &lt;root&gt;/tools
///   "port": 10350,              // Tilt UI port for `up`
///   "open_browser": true,       // open the Tilt UI once it answers
///   "down_on_exit": false,      // tilt down when the launcher stops
///   "stream": true,             // tilt up --stream (logs in the VS console)
///   "engine": "auto",           // auto | podman | docker | full path, used in attach files
///   "attach": {
///     "enabled": true,          // regenerate attach files on `up`
///     "process_name": "dotnet", // process vsdbg attaches to
///     "debugger_path": "/remote_debugger/vsdbg"
///   }
/// }
/// </code>
/// </summary>
internal sealed class DevSuiteSettings
{
    public required string Root { get; init; }
    public List<string> ComposeFiles { get; init; } = ["docker-compose.yml"];
    public string ProjectName { get; init; } = "";
    public string ComposeCmd { get; init; } = "docker compose";
    public string DefaultBuildKind { get; init; } = "dotnet";
    public string WorkDir { get; init; } = ".tilt";

    public string TiltPath { get; init; } = "";
    public int Port { get; init; } = 10350;
    public bool OpenBrowser { get; init; } = true;
    public bool DownOnExit { get; init; }
    public bool Stream { get; init; } = true;
    public string Engine { get; init; } = "auto";
    public bool AttachEnabled { get; init; } = true;
    public string AttachProcessName { get; init; } = "dotnet";
    public string DebuggerPath { get; init; } = "/remote_debugger/vsdbg";

    public string WorkDirFull => Path.GetFullPath(Path.Combine(Root, WorkDir));

    public static DevSuiteSettings Load(string root)
    {
        var merged = new JsonObject();
        foreach (var name in new[] { "devsuite.json", "devsuite.local.json" })
        {
            var path = Path.Combine(root, name);
            if (!File.Exists(path))
            {
                Log.Debug("settings", $"{path} not found, skipped");
                continue;
            }
            Log.Debug("settings", $"reading {path}");
            var node = JsonNode.Parse(File.ReadAllText(path),
                documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (node is JsonObject obj)
                Merge(merged, obj);
        }

        var launcher = merged["launcher"] as JsonObject ?? new JsonObject();
        var attach = launcher["attach"] as JsonObject ?? new JsonObject();
        var s = new DevSuiteSettings
        {
            Root = root,
            ComposeFiles = merged["compose_files"] is JsonArray files
                ? files.Select(f => f!.GetValue<string>()).ToList()
                : ["docker-compose.yml"],
            ProjectName = Str(merged, "project_name", ""),
            ComposeCmd = Str(merged, "compose_cmd", "docker compose"),
            DefaultBuildKind = Str(merged, "default_build_kind", "dotnet"),
            WorkDir = Str(merged, "work_dir", ".tilt"),
            TiltPath = Str(launcher, "tilt_path", ""),
            Port = launcher["port"]?.GetValue<int>() ?? 10350,
            OpenBrowser = launcher["open_browser"]?.GetValue<bool>() ?? true,
            DownOnExit = launcher["down_on_exit"]?.GetValue<bool>() ?? false,
            Stream = launcher["stream"]?.GetValue<bool>() ?? true,
            Engine = Str(launcher, "engine", "auto"),
            AttachEnabled = attach["enabled"]?.GetValue<bool>() ?? true,
            AttachProcessName = Str(attach, "process_name", "dotnet"),
            DebuggerPath = Str(attach, "debugger_path", "/remote_debugger/vsdbg"),
        };
        return s;
    }

    private static string Str(JsonObject o, string key, string fallback) =>
        o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : fallback;

    private static void Merge(JsonObject into, JsonObject from)
    {
        foreach (var (key, value) in from)
        {
            if (value is JsonObject fromObj && into[key] is JsonObject intoObj)
                Merge(intoObj, fromObj);
            else
                into[key] = value?.DeepClone();
        }
    }

    /// <summary>
    /// Compose project name, same rule as compose.star: project_name setting,
    /// else the normalized model's name (top-level `name:` or the compose
    /// dir), lowercased with only [a-z0-9_-] kept.
    /// </summary>
    public string ResolveProjectName(string? modelName = null)
    {
        var name = ProjectName;
        if (string.IsNullOrEmpty(name))
            name = modelName;
        if (string.IsNullOrEmpty(name))
            name = Path.GetFileName(ComposeDir) ?? "";
        return new string(name.ToLowerInvariant()
            .Where(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')
            .ToArray());
    }

    public string ComposeDir =>
        Path.GetDirectoryName(Path.GetFullPath(ComposeFiles.FirstOrDefault() ?? "docker-compose.yml", Root))!;
}
