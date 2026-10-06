# tilt-vs: Tilt + Visual Studio 2026 + Docker Compose + Podman (Hyper-V) dev suite

Status: phase 1 plan. Branch `integration` carries the skeleton described here;
it already evaluates and runs end to end (`tilt ci` green on the skeleton sample
with Docker on Linux). Parallel task threads fill in the modules.

## 1. The developer flow we are building

```
VS 2026  F5 (startup project = DevSuite.Launcher)
  └─ launcher runs `tilt up` in the solution root (console window, Ctrl+C / Stop = tilt down optional)
       └─ Tiltfile -> devsuite/tilt/main.star
            1. settings      devsuite.json + devsuite.local.json + CLI flags
            2. podman        preflight: engine reachable, versions, BuildKit off for Podman
            3. compose       read docker-compose.yml -> ServiceSpec per service (labels parsed)
            4. per service   dotnet | docker | custom | compose | none   (see §3)
                 dotnet: local `dotnet publish -c Debug` -> docker_build (optionally without
                         the SDK build stage) -> live_update sync dlls + restart_container
                         + vsdbg mounted read-only where VS looks for it
            5. compose       generated override (image refs, volumes, env, translated paths)
                             -> docker_compose([compose files..., override blob])
            6. dc_resource   Tilt UI groups, triggers, links, resource deps
            7. extend        Tiltfile.extend merged (top-level Tilt calls + extend(ctx))
            8. summary       one log line per service: kind, why, image, notes
VS 2026  Debug > Attach to Process > Docker (Linux container) > pick container > dotnet
  └─ VS finds vsdbg already present -> no download (air-gapped)
```

Every step logs through `devsuite/tilt/log.star` with the format
`[devsuite] LEVEL scope | message`; `DEVSUITE_LOG_LEVEL=debug` shows everything.

## 2. Repository layout and ownership

| Path | Owner | Notes |
|---|---|---|
| `Tiltfile` | integration | two lines, calls `devsuite_up()` |
| `devsuite/tilt/main.star` | integration | orchestration order (frozen; small additive edits only) |
| `devsuite/tilt/log.star`, `settings.star`, `contracts.star` | integration | shared contracts, additive edits only |
| `devsuite/tilt/compose.star`, `labels.star` | **A** | compose model, labels, override, dc_resource |
| `devsuite/tilt/dotnet.star`, `dockerfile.star`, `ignore.star`, `.tiltignore` | **B** | .NET build, skip build layer, change detection |
| `devsuite/tilt/vsdbg.star`, `devsuite/vsdbg/**` | **C** | offline vsdbg packaging + mounting |
| `devsuite/tilt/extend.star`, `devsuite/tilt/docker.star`, `Tiltfile.extend.example` | **D** | Tiltfile.extend merge, docker/custom kinds |
| `devsuite/tilt/podman.star`, `devsuite/podman/**` | **E** | Podman Hyper-V setup, preflight, path translation |
| `devsuite/launcher/**` | **F** | VS 2026 F5 launcher project + launch profiles + attach helpers |
| `samples/**`, `docker-compose.yml`, `Tiltfile.extend`, `TiltVs.slnx`, `devsuite.json` | **G** | sample solution, e2e scenarios, user docs |
| `docs/<task>.md` | each task | one doc per task (`docs/compose.md`, `docs/dotnet.md`, ...) |
| `docs/plan/**`, `README.md`, `.gitignore` | integration | |

Rule: a thread edits only files it owns. If it needs a change in a shared file,
it makes the smallest additive edit (new key, new function), says so in its PR,
and the integration merge resolves it. Module stubs already exist with their
target API in the header comment; keep those signatures.

## 3. Compose label schema

Labels go on the compose service (`labels:` dict or list form). The source of
truth is `LABELS` in `devsuite/tilt/contracts.star`.

**Requested**

| Label | Values | Default | Meaning |
|---|---|---|---|
| `tilt-build` | `dotnet` \| `custom` \| `docker` \| `compose` | `dotnet` when the service has `build:`; logged as "defaulted" | how Tilt builds the image |
| `tilt-skip-build-layer` | `true` \| `false` | `false` | build only the runtime stage; the app comes from the local `dotnet publish` |

`tilt-build` values: `dotnet` = local .NET build + image + live update + vsdbg;
`custom` = devsuite registers nothing, `Tiltfile.extend` builds it;
`docker` (proposed) = Tilt builds the Dockerfile as-is, no .NET logic (Node, nginx...);
`compose` (proposed) = Tilt does not build, `docker compose up --build` does.
A service **without** `build:` is deploy-only (kind `none`) regardless of labels.

**Proposed** (all optional, plain strings, comma lists where noted)

| Label | Default | Purpose |
|---|---|---|
| `tilt-project` | the single `*.csproj` next to the Dockerfile | path (relative to the Dockerfile dir) when there are several or it lives elsewhere |
| `tilt-configuration` | `Debug` | `dotnet publish -c` value, also passed as `BUILD_CONFIGURATION` build arg |
| `tilt-app-path` | inferred from the final stage (`WORKDIR` / `COPY --from=... <dst>`) | container dir the dlls are synced into |
| `tilt-publish-args` | empty | extra `dotnet publish` args (escape hatch) |
| `tilt-live-update` | `true` | `false` = rebuild the image on every change instead of syncing |
| `tilt-watch` | empty | extra paths (comma list) that trigger the .NET build |
| `tilt-ignore` | empty | extra globs (comma list) ignored by the watcher |
| `tilt-debugger` | `true` | mount vsdbg into this container |
| `tilt-debugger-rid` | inferred from base image (alpine -> `linux-musl-x64`) | which vsdbg build to mount |
| `tilt-debugger-user-home` | `/root` (and `/home/app` for non-root .NET 8+ images) | where `~/.vs-debugger` is for the container user |
| `tilt-group` | the build kind | Tilt UI label(s) |
| `tilt-trigger` | `auto` | `manual` = rebuild only when clicked in the Tilt UI |
| `tilt-auto-start` | `true` | `false` = resource is registered but not started |
| `tilt-links` | empty | extra URLs shown on the resource in Tilt UI |
| `tilt-resource-deps` | compose `depends_on` (automatic) | extra Tilt resource deps |

Example:

```yaml
services:
  orders-api:
    build: { context: ./src/Orders.Api }
    labels:
      tilt-build: dotnet
      tilt-skip-build-layer: "true"
      tilt-group: backend
  legacy-worker:
    build: ./src/Legacy.Worker
    labels: { tilt-build: custom }
  db:
    image: postgres:16-alpine        # no build -> deploy only
```

## 4. Tiltfile structure and Tiltfile.extend merge

* Root `Tiltfile` only does `load("./devsuite/tilt/main.star", "devsuite_up")` then `devsuite_up()`.
* `main.star` runs the pipeline in §1. Modules return a **BuildResult** (§9); the
  compose module folds all `compose_patch` entries into one override document and
  calls `docker_compose([...compose files, encode_yaml(override)], project_name=...)`.
  Compose merges the override last: `image` is replaced, `environment` merges by key,
  `volumes` merge by container target (so a re-emitted volume replaces the original).
* Image matching: Tilt pairs a `docker_build(ref)` with the compose service whose
  `image` equals `ref`. The override sets `image: <project>-<service>` (or keeps the
  compose `image:`) so this is deterministic. When Tilt registers a build, it runs
  `compose up --no-build`; services with no registered build are built by compose.
* **Tiltfile.extend** (path from settings, default next to the root Tiltfile):
  `main.star` calls `load_dynamic()` on it **after** all devsuite resources are
  registered. Two styles, both supported:
  1. plain top-level Tilt calls (`local_resource`, `docker_build`, `dc_resource`, `load('ext://...')` from a vendored repo) which register globally, exactly like being in the Tiltfile;
  2. `def extend(ctx):` which receives the parsed model (`ctx["project"]["services"][name]["image_ref"]`, build context, opts, settings, log helpers) so custom builds never hard-code image names.
  Tilt assembles resources after the whole Tiltfile runs, so order is not an issue;
  conflicts are: registering a second `docker_build` for an image devsuite already
  built (Tilt error; task D turns it into a clear message: "set tilt-build: custom").
  After the extend runs, devsuite warns for every `custom` service whose image nobody built.
* Verified here: relative `load()` from `.star` files, `load_dynamic`, `struct`,
  recursion, and the `[file, blob]` compose list all work in Tilt 0.35.
  Starlark has no `%-10s` padding (use `log.pad`), no `while`, and module globals
  are frozen after load (keep state in `ctx`).

## 5. .NET pipeline (task B)

* **Project discovery**: the single `*.csproj` in the Dockerfile directory; `tilt-project` overrides; zero or several -> warning and fall back to kind `docker` (logged).
* **Local build**: `local_resource("<svc>-dotnet", cmd=..., cmd_bat=...)` running
  `dotnet publish <csproj> -c Debug -o <work_dir>/publish/<svc> --no-self-contained -p:UseAppHost=false`
  (framework-dependent, portable, so no RID-specific NuGet packages are needed offline).
  Output goes to a staging dir and is swapped in when publish succeeds, so Tilt never syncs a half-written folder.
  Must not fight VS for `obj/`: investigate `--artifacts-path` / a separate `BaseIntermediateOutputPath` via `Directory.Build.props` hook; document the result.
* **Change detection**: deps = project dir + all transitive `ProjectReference` dirs (parsed from the csproj files) + `Directory.Build.props/targets`, `Directory.Packages.props`, `nuget.config`, `global.json` up the tree + `tilt-watch`.
  Ignores (`ignore.star` + shipped `.tiltignore`): `**/bin/**`, `**/obj/**`, `**/.vs/**`, `*.user`, `*.suo`, `**/TestResults/**`, `**/node_modules/**`, `.git/**`, `<work_dir>/**` (except as image context), `**/*.md`, `**/*.swp`, `**/~*`, `**/*.tmp`, `**/.idea/**`, `**/Properties/launchSettings.json`, plus `tilt-ignore`. `wwwroot` and `appsettings*.json` stay watched.
* **Image**: `docker_build(image_ref, context, ...)` with `only=` restricted to what the final stage actually needs, so a source edit never triggers a full image rebuild, only the publish -> sync path.
  * skip build layer = `true`: `dockerfile.star` parses the Dockerfile, takes the final stage (or compose `build.target`), and rewrites each `COPY --from=<stage that builds/publishes>` into `COPY <work_dir>/publish/<svc> <dst>`; passed via `dockerfile_contents`. No SDK image, no NuGet restore inside the container.
  * skip build layer = `false`: original Dockerfile, build arg `BUILD_CONFIGURATION=<configuration>` (MS template convention) so the first image is Debug too.
* **Live update**: `sync(<publish dir>, <app_path>)` then `restart_container()` (still supported for compose resources). `tilt-live-update=false` or `--no-live-update` -> no live_update (full rebuild).
* The compose resource gets `resource_deps=["<svc>-dotnet"]` so the first image waits for the first publish.

## 6. Offline vsdbg (task C)

Microsoft's `GetVsDbg.sh` (aka.ms/getvsdbgsh) resolves a version keyword
(`latest`, `vs2022`, ...) to a version number, downloads
`vsdbg-<rid>.tar.gz` (or `.zip`) for that version, extracts it to `-l <dir>`, and
writes marker files (`success_rid.txt`, `success_version.txt`) that make the next
run a no-op. Visual Studio's "Docker (Linux container)" attach runs that script
inside the container (into `~/.vs-debugger/<vs key>`), which is the download that
fails air-gapped. VS F5 container tooling instead mounts `%USERPROFILE%\vsdbg\vs2017u5` at `/remote_debugger`.

Deliverables:
* `devsuite/vsdbg/Get-VsDbgOffline.ps1` (+ `.sh`) to run **once on a connected machine**: mirrors GetVsDbg.sh (same version resolution, same RIDs, same layout, same marker files with the same contents), produces `devsuite/vsdbg/drop/<vs key>/<rid>/` plus a `manifest.json` (version, rid, sha256, source URL, date). Also accepts `-FromArchive` for an already-downloaded tarball.
* `vsdbg.star`: for each dotnet service, mount the matching `<rid>` folder read-only at **every** path VS probes: `/remote_debugger`, `<home>/.vs-debugger/<vs key>` for each supported key (`vs2022`, and the VS 2026 key confirmed on a real machine), with `<home>` from `tilt-debugger-user-home`. Fail with a clear message when the drop is missing; `tilt-debugger=false` or `--no-debugger` skips.
* `docs/vsdbg.md`: the one-time procedure to capture what VS 2026 really probes (attach once on a connected machine, `find / -name vsdbg -o -name success_version.txt` in the container) and record it in settings.
* Fallback that never downloads: per-service attach JSON for VS's `DebugAdapterHost.Launch` (pipeTransport `podman exec -i <container> /remote_debugger/vsdbg --interpreter=vscode`), generated by task F from the same settings.

## 7. Podman on Windows with the Hyper-V provider (task E)

* `devsuite/podman/Setup-PodmanMachine.ps1`: `CONTAINERS_MACHINE_PROVIDER=hyperv`, `podman machine init` (admin shell required by Hyper-V) with explicit volume shares for the source drive(s), rootful mode, start, and Docker-API compatibility (`\\.\pipe\docker_engine` or `DOCKER_HOST=npipe:////./pipe/podman-machine-default`).
* `devsuite/podman/Test-DevSuite.ps1` (doctor): checks tilt, dotnet SDK, podman, `docker compose` (docker-compose v2 binary, which Tilt shells out to), machine running, pipe reachable, a test bind mount round-trip, vsdbg drop present, base images present locally.
* `podman.star preflight`: ping the engine (`docker version` through DOCKER_HOST), log versions, set `DOCKER_BUILDKIT=0` when the engine is Podman (no BuildKit session API), fail with the doctor command when unreachable.
* **Volume mounts**: with Hyper-V, Windows folders reach the VM over 9p shares (`C:\src` -> `/mnt/c/src`). Compose resolves bind sources to Windows paths; whether Podman's API translates them is version dependent, so `podman.star translate` rewrites every bind source (original compose volumes and devsuite ones, re-emitted by target) to the VM path using a configurable `path_map` (default `X:\` -> `/mnt/x/`). Read-only mounts for vsdbg; named volumes untouched.
* File watching never relies on inotify across 9p: Tilt watches on Windows (NTFS) and pushes changes with `live_update` (docker cp API), which is why code is synced, not bind mounted.
* Air-gapped: all `docker_build` calls use `pull=False`; base images must be preloaded (`podman load`) or come from an internal registry configured in `registries.conf`.

## 8. Visual Studio 2026 F5 (task F)

* `devsuite/launcher/DevSuite.Launcher/` – a tiny .NET console project, startup project of the solution, with `Properties/launchSettings.json` profiles:
  `Tilt Up` (`tilt up` in the solution dir), `Tilt Up (skip build layer)`, `Tilt Up (no debugger)`, `Tilt CI`. The launcher resolves `tilt.exe` (settings, PATH, `tools/`), forwards output to the VS console, opens the Tilt UI, and on stop optionally runs `tilt down` (setting).
  Why a launcher instead of `"commandName": "Executable"` on `tilt.exe`: VS would try to debug the Go binary; the managed launcher debugs cleanly and gives us a place for preflight checks.
* Only the launcher is built on F5 (no project references), so VS does not compile the services; Tilt does (Debug).
* Attach helpers: documented Attach to Process (Docker) + Reattach (Shift+Alt+P), and generated `DebugAdapterHost` attach files per dotnet service (§6 fallback).
* Auto-attach on F5 would need a VS extension and is **not** in scope unless you ask (question 2).

## 9. Contracts (in `devsuite/tilt/contracts.star`)

* `ServiceSpec`: `name, raw, compose_dir, image_ref, build{context,dockerfile,target,args}|None, build_kind, kind_source, labels, opts`.
* `BuildResult`: `resources, resource_deps, image_registered, compose_patch{volumes[], environment{}}, notes[]`; combine with `merge_results`.
* `ctx`: `settings, project{name,dir,files,services,order}, results{name: BuildResult}, root`.
* Settings sections per module: `settings["dotnet"]`, `["vsdbg"]`, `["podman"]`; each module applies its own defaults inside its section.
* CLI flags (already defined in `settings.star`): `tilt up -- [service ...] --skip-build-layer --no-debugger --no-live-update`.

## 10. Parallel tasks

All tasks branch from `integration`, open a PR into `integration`, and merge it
themselves once their acceptance checks pass and it rebases cleanly.

| Task | Scope | Acceptance (on the Linux test bench unless noted) |
|---|---|---|
| **A compose + labels** | normalized compose model via `<compose_cmd> config --format json` with `read_yaml` fallback; multiple compose files; env interpolation; list/dict labels; label validation (unknown `tilt-*` -> warn, bad enum -> fail with service name); override builder; dc_resource wiring; `docs/compose.md` | unit-style Tiltfile fixtures under `devsuite/tilt/tests/compose/` evaluated with `tilt alpha tiltfile-result`; skeleton sample still `tilt ci` green |
| **B dotnet** | §5 in full; `.tiltignore`; `docs/dotnet.md` | sample API: edit a `.cs` file -> only publish + sync + restart (no image rebuild) seen in `tilt ci`/logs; skip-build-layer image has no SDK layer; ignored paths do not trigger |
| **C vsdbg** | §6; drop layout + manifest; `docs/vsdbg.md` | packager runs here against a real download; container has `/remote_debugger/vsdbg` executable and markers; `vsdbg --version` runs inside the sample container |
| **D extend + docker/custom** | §4 extend semantics, clear conflict errors, unclaimed custom warnings, `docker` kind with `pull=False`, `Tiltfile.extend.example`; `docs/extend.md` | fixtures: custom built by extend; custom without extend warns and compose builds; duplicate build -> readable error |
| **E podman** | §7 scripts + `podman.star`; `docs/podman-hyperv.md` | path translation fixtures; preflight logic tested against Docker here; Windows scripts linted with PSScriptAnalyzer if available, validated by you on Windows |
| **F launcher** | §8; `docs/visual-studio.md` | `dotnet build` of the launcher here; launcher runs `tilt ci` on the sample from Linux (`dotnet run -- ci`) |
| **G sample + e2e** | `samples/` with 2 .NET APIs (one skip-build-layer, one full build), one `custom` service, one deploy-only db; `docker-compose.yml`; `Tiltfile.extend`; `TiltVs.slnx` (sample projects + `devsuite/launcher/DevSuite.Launcher/DevSuite.Launcher.csproj`); `devsuite.json`; `README` quick start; `docs/e2e.md` test script | `tilt ci` green on the full sample once A–D land; scenario checklist in `docs/e2e.md` |

Dependencies: none block starting. B, C, D consume A's ServiceSpec, which the
skeleton already provides. G's full e2e runs last against merged work.

### Test bench for every thread (Linux cloud container)

```bash
# Docker daemon
dockerd > /tmp/dockerd.log 2>&1 &
# Tilt 0.35 from source (GitHub release downloads are blocked here)
GOFLAGS=-mod=mod go install github.com/tilt-dev/tilt/cmd/tilt@v0.35.2 || true   # populates the module cache
cp -r "$(go env GOMODCACHE)/github.com/tilt-dev/tilt@v0.35.2" /tmp/tiltsrc && chmod -R u+w /tmp/tiltsrc
(cd /tmp/tiltsrc && go build -o /usr/local/bin/tilt ./cmd/tilt)
# Evaluate the Tiltfile without running anything
tilt alpha tiltfile-result -v > /dev/null
# Real run
tilt ci --port 0 ; tilt down
# .NET SDK: mcr.microsoft.com/dotnet/sdk:10.0 pulls fine (docker run ... dotnet ...)
```

Windows, Podman Hyper-V and VS 2026 cannot run here; those parts are validated
by reasoning + scripts + your run on Windows, and each task lists what it could not verify.

## 11. Open questions (defaults used until you answer)

1. vsdbg binaries in git? **Default: Git LFS** under `devsuite/vsdbg/drop/`. Alt: plain git (~70 MB per RID) or a shared folder path in `devsuite.json`.
2. Auto-attach the debugger on F5? **Default: no** (manual Attach to Process / Reattach). Auto-attach needs a VS extension.
3. Publish mode? **Default: framework-dependent, no RID, `UseAppHost=false`**, so the Dockerfile must start the app with `dotnet X.dll`. Alt: `-r linux-x64` (needs apphost packs in your offline NuGet feed).
4. `tilt-build` missing and no single csproj next to the Dockerfile? **Default: log a warning and use `docker`.**
5. `tilt-build: custom` but nothing in Tiltfile.extend builds it? **Default: warn and let compose build it.**
6. One `Tiltfile.extend` at the root, or also per-service files next to Dockerfiles? **Default: root only.**
7. Target .NET for the sample? **Default: net10.0** (LTS, ships with VS 2026).
8. Base images and NuGet offline? **Default: images preloaded in Podman (`pull=False`), NuGet via your `nuget.config` offline feed.** Tell me if there is an internal registry.
9. Compose CLI on Windows? **Default: docker-compose v2 binary (as bundled by Podman Desktop) talking to Podman's pipe.** Alt: `podman compose`.

## 12. Risks to watch

* VS 2026's exact vsdbg probe path/version key is not documented; task C mounts at all known paths and documents how to confirm on a real machine.
* Podman's handling of Windows bind paths over the Docker API varies by version; task E translates paths itself.
* `dotnet publish` from Tilt while VS has the solution open can contend on `obj/`; task B must isolate intermediates.
* BuildKit-only Dockerfile features (`RUN --mount`, heredocs) won't build on Podman's compat API with `DOCKER_BUILDKIT=0`; Buildah supports most, task E documents gaps.
* Tilt extensions (`ext://`) download from GitHub; air-gapped use needs a vendored extension repo.
