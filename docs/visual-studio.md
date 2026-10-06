# Visual Studio 2026: F5 runs Tilt

Task F (PLAN §8). Project: `devsuite/launcher/DevSuite.Launcher` (net10.0 console app, no NuGet packages, no project references).

## How it works

1. `DevSuite.Launcher` is the **startup project** of the solution. F5 builds only that project
   (keep *Tools > Options > Projects and Solutions > Build and Run > Only build startup projects and
   dependencies on Run* checked, which is the VS default), so VS never compiles the services. Tilt builds them.
2. The launcher finds the solution root, resolves `tilt`, regenerates the debugger attach files, and runs
   `tilt up --stream=true` in the root. Tilt's output streams into the launcher's console window.
3. Once the Tilt UI answers on its port, the launcher opens it in the default browser.
4. Stopping: Ctrl+C in the console stops tilt cleanly. *Stop Debugging* (Shift+F5) terminates the launcher;
   on Windows tilt is in a job object tied to the launcher, so it dies with it instead of being orphaned.
   Containers keep running unless `down_on_exit` is on (see below).

Why a launcher instead of a `"commandName": "Executable"` profile on `tilt.exe`: VS would try to debug the
Go binary; a managed launcher debugs cleanly and gives one place for root/tilt resolution and attach files.

## Launch profiles

Pick the profile in the F5 dropdown (`Properties/launchSettings.json`):

| Profile | Runs |
|---|---|
| **Tilt Up** | `tilt up` |
| **Tilt Up (skip build layer)** | `tilt up -- --skip-build-layer` |
| **Tilt Up (no debugger)** | `tilt up -- --no-debugger` |
| **Tilt CI** | `tilt ci`, then `tilt down` (exit code = result) |
| **Tilt Down** | `tilt down` |
| **Generate attach configs** | writes `.tilt/vs/attach-*.json` only |
| **Doctor** | prints what the launcher resolved (root, tilt, compose, engine, settings) |

To run only some services, add their names to the profile arguments, e.g. `up orders-api db`
(VS: project properties > Debug > Open debug launch profiles UI > Command line arguments).

## Command line

The same binary works outside VS:

```text
dotnet run --project devsuite/launcher/DevSuite.Launcher -- [command] [options] [devsuite args]

commands   up (default) | ci | down | attach-config | doctor
options    --root <dir>            solution root (default: first parent with Tiltfile + devsuite/tilt/main.star,
                                   searched from the working dir, then from the launcher binary; or DEVSUITE_ROOT)
           --tilt <path>           tilt executable
           --port <n>              Tilt port (up: 10350; ci: 0 = no HTTP server)
           --browser|--no-browser  open the Tilt UI when ready (up)
           --down|--no-down        tilt down when the launcher stops (up), or after ci
           --no-attach-config      skip regenerating attach files on up
           --tilt-arg <arg>        extra raw tilt argument, repeatable (e.g. --tilt-arg --legacy=false)
devsuite   [service ...] --skip-build-layer --no-debugger --no-live-update
           anything not recognized above goes to the Tiltfile after `--`
```

Examples: `dotnet run -- ci --down`, `dotnet run -- up orders-api --no-live-update`.

## Settings (`devsuite.json` / `devsuite.local.json`, section `launcher`)

Same files and merge order as the Tiltfile (`devsuite.local.json` wins and is git-ignored). All keys optional:

```jsonc
"launcher": {
  "tilt_path": "",          // "" = PATH, then <root>/tools/tilt(.exe), then <root>/tools/tilt/tilt(.exe); relative to root
  "port": 10350,            // Tilt UI port for `up`
  "open_browser": true,
  "down_on_exit": false,    // run `tilt down` when the launcher stops, however it stops
  "stream": true,           // tilt up --stream: logs in the VS console
  "engine": "auto",         // container CLI used in attach files: auto (podman, else docker) | podman | docker | full path
  "attach": {
    "enabled": true,        // regenerate attach files on every `up`
    "process_name": "dotnet",
    "debugger_path": "/remote_debugger/vsdbg"
  }
}
```

The launcher also reads the top-level `compose_files`, `project_name`, `compose_cmd`, `default_build_kind`
and `work_dir` keys so it sees the same project as the Tiltfile.

**tilt resolution order**: `--tilt`, `launcher.tilt_path`, `PATH`, `<root>/tools`. For an air-gapped team,
commit or drop `tilt.exe` into `tools/` and nobody needs to edit PATH.

**down_on_exit**: VS *Stop Debugging* kills the launcher without running any of its code, so `tilt down`
cannot run from the launcher itself. When the setting (or `--down`) is on, `up` starts a small detached
watcher (the same binary, `__down-when-exited`) that waits for the launcher to exit, stops a tilt that
outlived it, then runs `tilt down`. Its log is `.tilt/launcher/down.log`.

## Debugging a service

Auto-attach on F5 is out of scope (PLAN §11 question 2: it needs a VS extension). Two manual ways:

### 1. Attach to Process (preferred)

1. Wait for the service to be green in the Tilt UI.
2. *Debug > Attach to Process* (Ctrl+Alt+P), *Connection type*: **Docker (Linux Container)**,
   *Connection target*: the container (e.g. `tilt-vs-orders-api-1`), pick the `dotnet` process, code type **Managed (.NET Core for Unix)**.
3. Next time: *Debug > Reattach to Process* (Shift+Alt+P).

VS finds vsdbg already mounted by devsuite (task C, `docs/vsdbg.md`), so nothing is downloaded.
After a live update the container restarts: reattach with Shift+Alt+P.

### 2. DebugAdapterHost attach files (no-download fallback)

If VS still tries to download vsdbg (unknown VS 2026 probe path), use the generated files. They make VS
start vsdbg itself through `podman exec`, so the in-container download script never runs.

On every `up` (or with the *Generate attach configs* profile) the launcher writes, per dotnet service
with the debugger enabled:

* `.tilt/vs/attach-<service>.json`
* `.tilt/vs/attach-commands.txt` with one ready-to-paste line per service

```jsonc
// .tilt/vs/attach-orders-api.json
{
  "name": "Attach orders-api (vsdbg in container tilt-vs-orders-api-1)",
  "type": "coreclr",
  "request": "attach",
  "processName": "dotnet",
  "$adapter": "C:\\Program Files\\RedHat\\Podman\\podman.exe",
  "$adapterArgs": "exec -i tilt-vs-orders-api-1 /remote_debugger/vsdbg --interpreter=vscode",
  "justMyCode": true,
  "sourceFileMap": { "/src/": "C:\\src\\tilt-vs\\samples\\Orders.Api\\" }
}
```

Use it: *View > Other Windows > Command Window*, paste the line from `attach-commands.txt`:

```text
DebugAdapterHost.Launch /LaunchJson:"C:\src\tilt-vs\.tilt\vs\attach-orders-api.json" /EngineGuid:541B8A8A-6081-4506-9F0A-1CE771DEBC04
```

Tip: bind it once with *Tools > External Tools* or a Command Window alias
(`alias attachorders DebugAdapterHost.Launch /LaunchJson:"..."`).

Which services get a file: compose services with a `build:` and `tilt-build: dotnet`, or no `tilt-build`
label with `default_build_kind` = `dotnet` and exactly one `*.csproj` next to the Dockerfile (or `tilt-project`
set), the same rule as `dotnet.star`. `tilt-debugger: "false"` skips the service. The container name is
`container_name` or `<project>-<service>-1` (compose v2 naming; project name is the same as the Tiltfile uses).
The service list comes from `<compose_cmd> config --format json`; if that fails the launcher warns and continues.

`sourceFileMap` maps `/src/` (the MS Dockerfile template's build dir) to the build context, for images built
in-container. Skip-build-layer images are published locally, so their pdbs already carry local paths.

## Verified here vs. not verified

Verified on the Linux test bench (Docker 29, Tilt 0.35 from source, .NET SDK 10.0.401):

* `dotnet build` of the launcher, 0 warnings (warnings are errors).
* `dotnet run -- ci --down` on the sample: tilt ci green, then tilt down, exit code 0.
* `up --down orders-api db`: devsuite args reach the Tiltfile; SIGTERM stops tilt cleanly and the watcher runs
  tilt down; SIGKILL of the launcher (what *Stop Debugging* does): watcher stops the orphaned tilt and runs tilt down.
* `attach-config` writes the file for the sample's `orders-api` and skips the `custom` and deploy-only services;
  the container name matches the one compose creates (`tilt-vs-orders-api-1`).

Not verifiable here (needs your Windows machine):

* VS 2026 F5 with the profiles, console window behaviour, *Stop Debugging* + job object killing tilt.
* `DebugAdapterHost.Launch` with the generated JSON (`$adapter` format, coreclr engine GUID, `processName`)
  against Podman: there is no VS and no vsdbg download here. If VS rejects `processName`, set `"processId": 1`
  by hand (the app is PID 1 when the Dockerfile uses `ENTRYPOINT ["dotnet", "X.dll"]`) and tell us.
* Whether the down watcher survives VS ending the debug session (it is started outside tilt's job; if VS puts
  the whole debuggee tree in its own kill-on-close job, use the *Tilt Down* profile instead).
* Opening the browser on Windows (`UseShellExecute` on the URL).
