# Podman on Windows (Hyper-V provider)

Task E. Files: `devsuite/tilt/podman.star`, `devsuite/podman/**`.

devsuite talks to Podman through its Docker-compatible API, exactly as it would
talk to Docker: Tilt builds images with the Docker API, `docker compose` (v2)
runs the stack, and `live_update` copies files with the API (no bind mount of
source code, no inotify across the VM boundary). This page covers the one-time
machine setup, what the Tiltfile checks on every run, and how Windows paths are
rewritten for the VM.

## 1. One-time setup

Prerequisites: Windows 11 / Server 2022+ with Hyper-V enabled, Podman for
Windows 5.x on `PATH`, the docker-compose v2 CLI (Podman Desktop bundles one;
any `docker-compose.exe` v2 or the `docker compose` plugin works), and
preferably a `docker.exe` client (only the CLI, no Docker Desktop) for the
engine probe.

From an **elevated** PowerShell in the solution root:

```powershell
.\devsuite\podman\Setup-PodmanMachine.ps1
```

It is idempotent and does:

| Step | Detail |
|---|---|
| provider | `CONTAINERS_MACHINE_PROVIDER=hyperv` (process + user env) |
| init | `podman machine init podman-machine-default --rootful --cpus 4 --memory 8192 --disk-size 100 --volume C:\:/mnt/c` |
| shares | default: the drive root holding the solution; `-Share C:\src, D:\data` for others. The VM path comes from `podman.path_map`, so Tilt and the machine always agree |
| start | `podman machine start` (Hyper-V needs admin for start too) |
| Docker API | uses `\\.\pipe\docker_engine` when Podman serves it (no Docker Desktop running); otherwise sets the user's `DOCKER_HOST=npipe:////./pipe/podman-machine-default` |
| BuildKit | `DOCKER_BUILDKIT=0` for the user |
| air-gapped | `-ImagePath <machine-os .vhdx[.zst]>` (init without download), `-LoadImages <folder of .tar>` (`podman load`), `-Registry registry.corp:5000 [-InsecureRegistry]` (writes `/etc/containers/registries.conf.d/50-devsuite.conf` in the VM, mirroring `docker.io` and `mcr.microsoft.com`) |

Shares are fixed when the machine is created. If you add a drive later, run
`Setup-PodmanMachine.ps1 -Share C:\, D:\ -Recreate` (deletes and recreates the
machine; loaded images are lost, reload them with `-LoadImages`).

Open a new terminal (or restart Visual Studio) afterwards so the user
environment applies.

## 2. Doctor

```powershell
.\devsuite\podman\Test-DevSuite.ps1          # no admin needed; exit 1 on any FAIL
```

Checks tilt, .NET 10 SDK, podman, docker CLI, compose v2 (`compose_cmd`), the
machine (exists, running, hyperv, rootful, its shares), `CONTAINERS_MACHINE_PROVIDER`,
`DOCKER_BUILDKIT`, the API pipe, the engine (warns when `DOCKER_HOST` reaches a
non-Podman engine such as Docker Desktop), a **bind-mount round trip** (writes
a token under `.tilt/doctor`, maps the path through `podman.path_map`, reads it
back from a container), the vsdbg drop (`devsuite/vsdbg/drop/**/manifest.json`,
or `vsdbg.drop_dir`), and that every image the stack needs is present locally:
deploy-only images and final stages are FAIL when missing, earlier build stages
(SDK images) only WARN, since `tilt-skip-build-layer: "true"` does not need them.
The round trip also reports whether your Podman version accepts raw Windows
paths by itself (informational; devsuite translates either way).

The Tiltfile prints this command when it cannot reach the engine.

## 3. Tiltfile preflight (`podman.star preflight`)

Runs first in `devsuite_up()`:

1. Probe: `docker version --format "{{json .Server}}"` through the current
   `DOCKER_HOST` / default pipe. Failure stops the Tiltfile with:
   ```
   [devsuite] ERROR podman    | container engine not reachable: <docker's error>
     probe     : docker version --format "{{json .Server}}"
     DOCKER_HOST=npipe:////./pipe/podman-machine-default
     fix       : podman machine start   (Hyper-V: run from an elevated shell)
     first-time: devsuite\podman\Setup-PodmanMachine.ps1
     diagnose  : powershell -NoProfile -ExecutionPolicy Bypass -File devsuite\podman\Test-DevSuite.ps1
   ```
2. Detect the engine: Podman when the platform or a component name contains
   "Podman" (`Podman Engine`), else Docker. Logs engine, version, API version,
   os/arch, `DOCKER_HOST` and the compose CLI version.
3. BuildKit: on Podman, `os.putenv("DOCKER_BUILDKIT", "0")`. Verified on Tilt
   0.35 (`tilt ci` and `tilt up`): Tilt chooses its image builder on the first
   build, after the Tiltfile ran, so this switches Tilt's own `docker_build` to
   the classic builder as well as compose and custom builds. The user env var
   from the setup script covers manual `docker compose` runs.
4. Decide path translation (below) and log it.

## 4. Bind path translation (`podman.star translate`)

With the Hyper-V provider, Windows folders reach the VM over 9p shares, so the
VM sees `C:\src\shop` as `/mnt/c/src/shop`. Compose sends bind sources to the
engine as Windows paths; whether Podman's API rewrites them depends on the
version. devsuite does not rely on it: `translate(ctx, override)` rewrites
every bind source in the generated override before `docker_compose()` runs.

* **Original compose volumes**: each bind mount of a service (short or long
  syntax, relative, absolute, `~`) is resolved like compose does (relative to
  the compose file directory), mapped, and re-emitted in the override with the
  same `target`. Compose merges volumes by target, so the re-emitted one
  replaces the original. Options carry over (`:ro` -> `read_only`, `z`/`Z` ->
  `bind.selinux`, propagation).
* **devsuite volumes** (vsdbg and others in `compose_patch.volumes`): binds are
  mapped; a devsuite volume wins over an original with the same target.
* Named and anonymous volumes are untouched; unix-absolute sources
  (`/var/run/docker.sock`) are left as is.
* A Windows source no `path_map` entry covers (for example a UNC path) is
  passed through and logged as a warning.
* The summary line of each service shows `N bind path(s) translated`;
  `DEVSUITE_LOG_LEVEL=debug` prints every rewrite.

When it runs: `podman.translate` = `auto` (default) translates only when Tilt
runs on Windows **and** the engine is Podman. On Linux, or with Docker Desktop,
nothing changes.

## 5. Settings (`devsuite.json` / `devsuite.local.json`, section `podman`)

| Key | Default | Meaning |
|---|---|---|
| `preflight` | `true` | ping the engine before anything else |
| `engine` | `"auto"` | `auto` / `podman` / `docker`: override detection |
| `probe_cmd` | `docker version --format "{{json .Server}}"` | command printing the server version JSON; `podman version --format json` also parses, but talks to Podman's own connection, not the Docker API pipe |
| `buildkit` | `"auto"` | `auto` = off on Podman, untouched on Docker; `true` / `false` force |
| `translate` | `"auto"` | `auto` / `true` / `false` |
| `path_map` | `{"X:\\": "/mnt/x/"}` | host prefix -> VM prefix, see below |
| `doctor` | `powershell ... Test-DevSuite.ps1` | command printed when the engine is unreachable |

`path_map` rules:

* `"X:\\"` is a wildcard for any drive letter; an `x` path segment in its value
  becomes that letter in lower case: `C:\src` -> `/mnt/c/src`, `D:\` -> `/mnt/d`.
* Other keys are literal prefixes (drive, UNC `\\\\server\\share`, or a posix
  path), matched case-insensitively for Windows paths, only on whole path
  segments (`D:\Work` does not match `D:\Workshop`). The longest key wins; the
  wildcard is tried last.
* Your entries are merged over the default; `"X:\\": ""` removes the wildcard.
* Keep it in sync with the machine shares: `Setup-PodmanMachine.ps1` computes
  the share targets from the same map and refuses a share the map does not cover.

Example: source on `D:\work`, shared to the VM as `/work`:

```json
{ "podman": { "path_map": { "D:\\work\\": "/work/" } } }
```

## 6. BuildKit gaps on Podman

With `DOCKER_BUILDKIT=0` the classic builder API is used; Podman implements it
with Buildah. Dockerfiles that need BuildKit-only syntax do not build through
the compat API: `RUN --mount=type=cache|secret|ssh`, heredocs (`RUN <<EOF`),
`COPY --link`, `COPY --chmod` (newer Podman supports `--chmod`), `# syntax=`
frontends and `--platform` automatic args (`TARGETARCH` ...) are unreliable or
ignored. The .NET templates' Dockerfiles do not use them. With
`tilt-skip-build-layer: "true"` only the runtime stage builds, which avoids
most of these anyway.

## 7. Air-gapped checklist

* Machine OS image: `-ImagePath` (download `podman-machine-os` once on a
  connected machine).
* All `docker_build` calls use `pull=False` (tasks B/D); base images must be
  present: `podman save -o x.tar <image>` on a connected machine, then
  `Setup-PodmanMachine.ps1 -LoadImages <folder>`, or point `-Registry` at an
  internal mirror. The doctor lists anything missing.
* Tilt extensions (`ext://`) download from GitHub: vendor them.

## 8. Tests (Linux bench)

```bash
devsuite/podman/tests/run.sh          # podman.star fixtures (tilt alpha tiltfile-result)
devsuite/podman/tests/e2e/run.sh      # tilt ci: faked Podman probe, path_map ./host -> ./vm,
                                      # container only stays up if it sees vm/marker
pwsh -File devsuite/podman/tests/PathMap.Tests.ps1   # PowerShell mapping == Starlark mapping
pwsh -File devsuite/podman/tests/Lint.ps1            # parse all scripts (+ PSScriptAnalyzer if installed)
```

## 9. Not verified here (needs a Windows machine)

Run these once on Windows and fix forward:

1. `Setup-PodmanMachine.ps1` end to end: `--volume C:\:/mnt/c` accepted by
   `podman machine init` on the Hyper-V provider, the `--image` flag name for
   offline init, `podman machine inspect` fields used (`State`, `Rootful`,
   `Mounts`, `VMType`, `ConnectionInfo.PodmanPipe.Path`).
2. Whether Podman claims `\\.\pipe\docker_engine` on your version, else the
   `DOCKER_HOST` fallback.
3. Compose on Windows accepts the translated unix source (`/mnt/c/...`) in the
   override's long-syntax bind and passes it through unchanged (the doctor's
   round trip uses `docker run`, not compose, so the first `tilt up` is the check).
4. `tilt up` on Windows: preflight via `cmd.exe` (`... 2>&1 || echo ...`) and
   `os.name == "nt"` turning translation on.
5. PSScriptAnalyzer: not reachable from the bench (PowerShell Gallery blocked);
   scripts were only parsed and the doctor run under pwsh on Linux against
   Docker. Run `Install-Module PSScriptAnalyzer; .\devsuite\podman\tests\Lint.ps1`.
