namespace DevSuite.Launcher;

internal enum Command
{
    Up,
    Ci,
    Down,
    AttachConfig,
    Doctor,
    Help,
    // Internal: started detached by `up` when down-on-exit is on.
    DownWhenExited,
}

/// <summary>
/// Command line of the launcher:
/// <code>
/// DevSuite.Launcher [up|ci|down|attach-config|doctor] [launcher options] [devsuite args]
/// </code>
/// Launcher options are listed in <see cref="Usage"/>. Everything else
/// (service names, --skip-build-layer, --no-debugger, --no-live-update, ...)
/// is a devsuite arg and goes to Tilt after "--", i.e. `tilt up -- args`.
/// </summary>
internal sealed class Options
{
    public Command Command { get; set; } = Command.Up;
    public string? Root { get; set; }
    public string? TiltPath { get; set; }
    public int? Port { get; set; }
    public bool? OpenBrowser { get; set; }
    public bool? DownOnExit { get; set; }
    public bool? AttachConfig { get; set; }
    public int ParentPid { get; set; }
    public int ChildPid { get; set; }
    public List<string> TiltArgs { get; } = new();
    public List<string> DevSuiteArgs { get; } = new();

    public const string Usage = """
        DevSuite.Launcher - runs Tilt for the devsuite (Visual Studio F5 startup project)

        Usage: DevSuite.Launcher [command] [options] [devsuite args]

        Commands:
          up              tilt up in the solution root, streaming logs (default)
          ci              tilt ci (exit code = result); add --down to tear down after
          down            tilt down
          attach-config   write VS DebugAdapterHost attach files to <work_dir>/vs/
          doctor          show what the launcher resolved (root, tilt, compose, engine)

        Options:
          --root <dir>          solution root (default: first parent with Tiltfile + devsuite/tilt)
          --tilt <path>         tilt executable (default: settings, PATH, <root>/tools)
          --port <n>            Tilt UI/API port (up default 10350, ci default 0 = random)
          --browser | --no-browser          open the Tilt UI when it is ready (up)
          --down | --no-down    run tilt down when the launcher stops (even when VS kills it)
          --no-attach-config    do not regenerate attach files before up
          --tilt-arg <arg>      extra raw argument for tilt itself (repeatable)
          -h | --help

        Devsuite args (passed after `--` to the Tiltfile, see devsuite/tilt/settings.star):
          [service ...] --skip-build-layer --no-debugger --no-live-update
        """;

    public static Options Parse(string[] args)
    {
        var o = new Options();
        var i = 0;
        if (args.Length > 0 && !args[0].StartsWith('-'))
        {
            var cmd = ParseCommand(args[0]);
            if (cmd is not null)
            {
                o.Command = cmd.Value;
                i = 1;
            }
        }

        var passthrough = false;
        for (; i < args.Length; i++)
        {
            var a = args[i];
            if (passthrough)
            {
                o.DevSuiteArgs.Add(a);
                continue;
            }
            switch (a)
            {
                case "--":
                    passthrough = true;
                    break;
                case "-h" or "--help" or "/?":
                    o.Command = Command.Help;
                    break;
                case "--root":
                    o.Root = Value(args, ref i, a);
                    break;
                case "--tilt":
                    o.TiltPath = Value(args, ref i, a);
                    break;
                case "--port":
                    o.Port = int.TryParse(Value(args, ref i, a), out var p) && p >= 0
                        ? p
                        : throw new UsageException("--port needs a number >= 0");
                    break;
                case "--browser":
                    o.OpenBrowser = true;
                    break;
                case "--no-browser":
                    o.OpenBrowser = false;
                    break;
                case "--down" or "--down-on-exit":
                    o.DownOnExit = true;
                    break;
                case "--no-down" or "--no-down-on-exit":
                    o.DownOnExit = false;
                    break;
                case "--no-attach-config":
                    o.AttachConfig = false;
                    break;
                case "--tilt-arg":
                    o.TiltArgs.Add(Value(args, ref i, a));
                    break;
                case "--parent-pid":
                    o.ParentPid = int.Parse(Value(args, ref i, a));
                    break;
                case "--child-pid":
                    o.ChildPid = int.Parse(Value(args, ref i, a));
                    break;
                default:
                    o.DevSuiteArgs.Add(a);
                    break;
            }
        }
        return o;
    }

    private static Command? ParseCommand(string s) => s.ToLowerInvariant() switch
    {
        "up" => Command.Up,
        "ci" => Command.Ci,
        "down" => Command.Down,
        "attach-config" or "attach" => Command.AttachConfig,
        "doctor" => Command.Doctor,
        "help" => Command.Help,
        "__down-when-exited" => Command.DownWhenExited,
        _ => null,
    };

    private static string Value(string[] args, ref int i, string name)
    {
        if (i + 1 >= args.Length)
            throw new UsageException($"{name} needs a value");
        return args[++i];
    }
}

internal sealed class UsageException(string message) : Exception(message);
