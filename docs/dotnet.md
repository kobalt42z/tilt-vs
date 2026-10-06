# .NET build pipeline (`tilt-build: dotnet`)

Task B. Code: `devsuite/tilt/dotnet.star`, `dockerfile.star`, `ignore.star`,
`devsuite/dotnet/publish.{sh,ps1}`, root `.tiltignore`. Plan: `docs/plan/PLAN.md` §5.

## What happens for a dotnet service

For a compose service with `build:` and `tilt-build: dotnet` (or no `tilt-build`
label, since `dotnet` is the default kind):

1. **Project discovery.** The single `*.csproj` in the Dockerfile's folder, or the
   `tilt-project` label (a csproj path, or a folder holding one csproj, relative to
   the Dockerfile folder). None or several: a warning, and the service falls back to
   `tilt-build: docker` (summary shows `kind=docker (fallback)`).
2. **Local build**, Tilt resource `<svc>-dotnet`:
   ```
   dotnet publish <csproj> -c Debug -o .tilt/staging/<svc>
          --no-self-contained -p:UseAppHost=false --artifacts-path .tilt/artifacts/<svc>
   ```
   Framework-dependent and RID-less, so no runtime packs are needed from NuGet
   (the Dockerfile must start the app with `dotnet X.dll`, which the VS templates do).
   When publish succeeds, `publish.sh` / `publish.ps1` mirrors the staging folder into
   `.tilt/publish/<svc>` **by content**: only files whose bytes changed are replaced
   (one atomic rename each) and files that disappeared are deleted. Tilt therefore
   never sees a half-written folder and syncs only the dlls/pdbs that really changed.
   A failed publish leaves `.tilt/publish/<svc>` and the running container untouched.
3. **Image.**
   * `tilt-skip-build-layer: "true"`: `dockerfile.star` rewrites the Dockerfile. It keeps
     the final stage (or compose `build.target`) and the stages it derives from, replaces
     every `COPY --from=<.NET build stage>` with `COPY .tilt/publish/<svc>/ <same dst>`,
     and drops the SDK stages. A ".NET build stage" is one whose image is
     `dotnet/sdk` or that runs `dotnet build`/`dotnet publish` (directly or through its
     `FROM` parent). Other `COPY --from=` stages (a Node UI build, say) are kept. The
     result goes to `docker_build(dockerfile_contents=...)` with `only=` limited to the
     publish folder plus whatever plain `COPY`/`ADD` the kept stages read from the
     context. No SDK image, no NuGet restore in the container.
   * `tilt-skip-build-layer: "false"` (default): the original Dockerfile is built with
     build arg `BUILD_CONFIGURATION=<tilt-configuration>` (Debug), the convention of the
     VS templates, so the first image is a Debug build too. With live update on, the
     image is registered with `custom_build` running `<build_cli> build ...` and
     `deps=[Dockerfile, publish folder]`; see "Design notes" for why.
4. **Live update**: `sync(.tilt/publish/<svc>, <app path>)` then `restart_container()`.
   The app path is the destination of the replaced `COPY --from=` (resolved against
   `WORKDIR`), else the final stage's `WORKDIR`; `tilt-app-path` overrides it.
5. The compose resource gets `resource_deps=["<svc>-dotnet"]`, so the first image
   waits for the first publish.

Editing a `.cs` file therefore runs `<svc>-dotnet` (publish), then `<svc>` copies the
changed files into the container and restarts it. The image is not rebuilt. It is
rebuilt only when the Dockerfile changes (or, with skip build layer, a file the
runtime stage copies from the context).

| Case | Local publish | Image | On a `.cs` edit |
|---|---|---|---|
| skip build layer, live update (recommended) | yes | runtime stage + publish folder | publish, sync, restart |
| skip build layer, `tilt-live-update: "false"` | yes | same | publish, rebuild of the small runtime image |
| full build, live update | yes | original Dockerfile, Debug | publish, sync, restart |
| full build, `tilt-live-update: "false"` | no | original Dockerfile, Debug | full image rebuild |

CLI flags: `tilt up -- --skip-build-layer` forces skip build layer for every dotnet
service; `--no-live-update` turns live update off everywhere.

## Labels used

| Label | Default | Effect |
|---|---|---|
| `tilt-skip-build-layer` | `false` | see above |
| `tilt-project` | single csproj next to the Dockerfile | csproj (or folder) relative to the Dockerfile folder |
| `tilt-configuration` | `Debug` | `dotnet publish -c` and `BUILD_CONFIGURATION` build arg |
| `tilt-app-path` | inferred | container folder the publish output is synced to |
| `tilt-publish-args` | empty | extra `dotnet publish` args (split on spaces) |
| `tilt-live-update` | `true` | `false`: no sync, rebuild instead |
| `tilt-watch` | empty | extra paths (comma list, relative to the compose file) that trigger the publish |
| `tilt-ignore` | empty | extra ignore globs (comma list, relative to the compose file, dockerignore syntax) |
| `tilt-trigger` | `auto` | also applied to `<svc>-dotnet` |
| `tilt-group` | `dotnet` | also applied to `<svc>-dotnet` |

## Settings (`devsuite.json` → `"dotnet": {...}`)

| Key | Default | Meaning |
|---|---|---|
| `isolate_intermediates` | `true` | pass `--artifacts-path .tilt/artifacts/<svc>` (see below) |
| `build_cli` | `"docker"` | CLI used by `custom_build` for full-build images; set `"podman"` when only the Podman CLI is installed |
| `publish_args` | `""` | extra `dotnet publish` args for every service |

The work dir is the top-level `work_dir` setting (default `.tilt`, git-ignored).

## Change detection

The `<svc>-dotnet` resource watches:

* the project folder and every transitive `ProjectReference` folder (parsed from the
  csproj files; `$(MSBuildThisFileDirectory)` prefixes are understood, other MSBuild
  properties in paths are not);
* `Directory.Build.props/.targets/.rsp`, `Directory.Packages.props`, `NuGet.Config`
  (any common casing) and `global.json` in those folders and every parent folder;
* `tilt-watch` paths.

The csproj files are read with `read_file`, so adding a `ProjectReference` reloads
the Tiltfile and the new folder is watched.

Ignored (root `.tiltignore`, which Tilt applies to every resource, plus the same list
applied by the publish resource to each folder it watches, so folders outside the repo root are covered too):
`bin/`, `obj/`, `.vs/`, `*.user`, `*.suo`, `TestResults/`, `node_modules/`, `.git/`,
`.idea/`, `*.md`, `*.swp`, `~*`, `*.tmp`, `Properties/launchSettings.json`, plus
`tilt-ignore`. `wwwroot/` and `appsettings*.json` stay watched (they are published).
The devsuite work dir is ignored by the publish resource; `.tilt/artifacts` and
`.tilt/staging` are ignored globally (`watch_settings`). `.tilt/publish` is not
ignored, because it is what the image and live update watch.

## Visual Studio and `obj/`

VS (design-time builds, IntelliSense, its own F5 build) writes `obj/` and `bin/` in
each project folder. `dotnet publish` from Tilt would write the same files
(`project.assets.json`, `*.AssemblyInfo.cs`, the compiled dll) and both would fight
over locks and incremental state.

Result of the investigation: **`--artifacts-path` isolates everything.** It is the
.NET 8+ CLI switch for "artifacts output"; passed on the command line it is a global
MSBuild property, so it applies to the project *and* all its `ProjectReference`s
before `BaseIntermediateOutputPath` is computed. With it, NuGet restore output and
every intermediate land under `.tilt/artifacts/<svc>/{obj,bin}/<project>/debug/`, and
nothing is written to the source folders. Verified on the test bench: after a
publish there is no `obj/`/`bin/` in any project folder, and a parallel `dotnet build`
in the source tree (what VS does) neither conflicts nor triggers Tilt. Each service
has its own artifacts folder, so two services sharing a library build it
independently (no cross-service contention either).

A `Directory.Build.props` hook (`BaseIntermediateOutputPath` switched on an
environment variable) was the alternative; it needs a file in the user's repo and is
easy to get wrong (it must be set before `Microsoft.Common.props`), so it is not used.
Caveat: a project that hard-codes `BaseIntermediateOutputPath`/`OutputPath` in its own
files can still write into its folder; set `isolate_intermediates: false` only if
`--artifacts-path` is unsupported (SDK older than 8).

## Design notes

* **Why `custom_build` for full-build images with live update.** A `docker_build` image
  watches its whole build context. For a full build the context is the source tree,
  so every `.cs` edit would be a change "not matching any sync" and force a full
  SDK image rebuild, defeating the publish + sync loop. `custom_build` separates what
  goes into the build (the context, on the command line) from what triggers it
  (`deps`: the Dockerfile and the publish folder). Cost: it needs a container CLI
  (`build_cli`) on PATH, whereas `docker_build` talks to the engine API directly.
* **Mixed binaries in full-build containers.** The first image holds dlls built inside
  the container; after the first edit, the dlls that changed come from the local
  publish. Both are Debug builds of the same sources, so this works, but the pdbs of
  untouched assemblies point at `/src/...` paths. Use skip build layer for the
  smoothest debugging.
* **Build context for skip build layer.** The context becomes the closest folder that
  contains both the original context and `.tilt/` (usually the repo root), with
  `only=` so only the publish folder and the runtime stage's own inputs are sent.
  A `.dockerignore` at that folder still applies: do not exclude `.tilt` there.
* **Dockerfile support.** Comments, line continuations, `# escape=`, global `ARG`s,
  `FROM --platform`, stage references by name or index, `COPY`/`ADD` flags and JSON
  form. Heredocs are not supported (BuildKit only; unavailable on Podman's compat API).
  If skip build layer is requested but the final stage has no `COPY --from=<.NET
  build stage>`, devsuite warns and builds the Dockerfile as-is.

## Testing

* Unit-style checks (Dockerfile parsing/rewriting, ignore patterns):
  `tilt alpha tiltfile-result -v -f devsuite/tilt/tests/dotnet/unit/Tiltfile`
  (prints `ok ...` lines, fails on the first mismatch).
* Fixture stack: `devsuite/tilt/tests/dotnet/` (VS-template Dockerfiles; `skip-api`
  with skip build layer, `full-api` full build, both referencing `Shared.Lib`;
  `nocsproj` falls back to docker). `cd` there, then `tilt ci --port 0`.
  Live-update check: `tilt up`, edit `src/Shared.Lib/Greeting.cs`, `curl
  localhost:18081/` and `:18082/` show the new text after publish + sync + restart,
  with no image build in the logs.

## Not verified here

* Windows: `publish.ps1`, `cmd_bat`, backslash paths, `custom_build`'s
  `command_bat`. Written to mirror the Linux path, not run (no Windows/PowerShell on the
  bench). Watch for `tilt-publish-args` values starting with `-` being taken as
  PowerShell parameters by `publish.ps1`.
* Podman (Hyper-V): `docker_build` with `dockerfile_contents` against the compat API
  with `DOCKER_BUILDKIT=0`, and `custom_build` with `build_cli: podman`.
* VS 2026 with the solution open while Tilt publishes (the obj/ isolation was
  verified with a concurrent CLI build, not with VS itself).
