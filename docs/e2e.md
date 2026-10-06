# Sample solution and end-to-end test script (task G)

The repository root is itself the sample: `TiltVs.slnx`, `docker-compose.yml`,
`Tiltfile.extend` and `devsuite.json` drive the projects under `samples/`.
Every build kind devsuite supports is represented, so each module thread can
test against the same stack.

## The sample

| Service | Kind | What it exercises | Host port |
|---|---|---|---|
| `orders-api` | `dotnet`, `tilt-skip-build-layer: "true"` | runtime-stage-only image, app from local `dotnet publish`; calls `catalog-api` and opens a TCP socket to `db` | 5080 |
| `catalog-api` | `dotnet`, `tilt-skip-build-layer: "false"` | full MS-template Dockerfile (SDK stage, `ARG BUILD_CONFIGURATION`) | 5081 |
| `web` | `custom` | non-.NET image (nginx) built by `Tiltfile.extend` with `live_update` | 5082 |
| `db` | none (no `build:`) | deploy-only `postgres:16-alpine` with a healthcheck | 55432 |
| `e2e-smoke` | `local_resource` from `Tiltfile.extend` | runs `samples/e2e/smoke.sh` (`smoke.ps1` on Windows) after the stack is up; gates `tilt ci` | - |

Layout:

```
samples/
  Directory.Build.props          net10.0, nullable, implicit usings (shared by all projects)
  Samples.Shared/                class library referenced by both APIs (ProjectReference change detection)
  Orders.Api/  Dockerfile        MS VS container template, ENTRYPOINT ["dotnet", "Orders.Api.dll"]
  Catalog.Api/ Dockerfile        same template
  web/         Dockerfile, www/  nginx static site
  e2e/         smoke.sh, smoke.ps1
  .dockerignore                  bin/obj/.vs/launchSettings, web/, e2e/
```

The .NET build context is `samples/` (Visual Studio's "solution directory"
convention, `dockerfile: Orders.Api/Dockerfile`), so the Dockerfiles can `COPY`
the shared project and `Directory.Build.props`. Project discovery still finds the
single `*.csproj` next to each Dockerfile.

Both APIs expose `/health`, which returns
`{"service","version","configuration","host"}`: `configuration` shows whether the
running build is Debug or Release, `version` comes from `Samples.Shared`
(`ServiceInfo.SharedVersion`), so edits are observable from outside the container.

`TiltVs.slnx` lists `devsuite/launcher/DevSuite.Launcher` first so VS picks it
as the default startup project, plus the three sample projects and the
devsuite config files as solution items.

## Prerequisites

* Docker or Podman with the Docker API, plus `docker compose` v2
* Tilt 0.35
* .NET 10 SDK on the host (every dotnet service is published locally by `<svc>-dotnet`)
* The `docker` CLI on PATH (or `"dotnet": {"build_cli": "podman"}` in `devsuite.json`):
  `catalog-api`'s full build with live update goes through `custom_build`, which shells
  out to the CLI instead of the engine API (docs/dotnet.md, "Design notes")
* A vsdbg drop under `devsuite/vsdbg/drop/` (docs/vsdbg.md). None is committed yet, so
  until one is, run every scenario with `-- --no-debugger` except S16
* Base images present locally (`pull=False`, air-gapped): `mcr.microsoft.com/dotnet/aspnet:10.0`,
  `mcr.microsoft.com/dotnet/sdk:10.0` (only `catalog-api`'s full build needs it),
  `nginx:1.27-alpine`, `postgres:16-alpine`

## Scenario checklist

Run from the repository root. "Expect" is what passes; the status column records
the last run (see Results below). Owner = the module the scenario validates.

| # | Scenario | Steps | Expect | Owner |
|---|---|---|---|---|
| S1 | Cold start | `tilt ci --port 0` | exit 0, `SUCCESS. All workloads are healthy.`, `e2e-smoke` prints `smoke: all checks passed`; summary has one line per service with the right kind | all |
| S2 | Evaluate only | `tilt alpha tiltfile-result` | exit 0, no `WARN`; without a vsdbg drop it fails with the missing folder, key and RID (expected) | all |
| S3 | Debug build everywhere | `curl localhost:5080/health`, `curl localhost:5081/health` | both `"configuration":"Debug"` (orders from local publish, catalog via `BUILD_CONFIGURATION=Debug`) | B |
| S4 | Source edit, skip-build-layer service | `tilt up`; edit a string in `samples/Orders.Api/Program.cs` | `orders-api-dotnet` runs publish, `orders-api` does live update (sync + restart), **no** "Building Dockerfile" step; `curl :5080/` shows the change | B |
| S5 | Source edit, full-build service | edit `samples/Catalog.Api/Program.cs` | same as S4 for `catalog-api` (publish + sync + restart, no image rebuild) | B |
| S6 | Shared project edit | bump `ServiceInfo.SharedVersion` in `samples/Samples.Shared/ServiceInfo.cs` | both `*-dotnet` resources rebuild; both `/health` show the new `version` | B |
| S7 | Build props edit | touch `samples/Directory.Build.props` | both `*-dotnet` resources rebuild | B |
| S8 | Ignored paths | touch `samples/Orders.Api/obj/x`, `samples/Orders.Api/README.md`, `samples/Orders.Api/Properties/launchSettings.json`, `.vs/x` | nothing rebuilds | B |
| S9 | No SDK layer | `docker history tiltvs-orders-api` / `docker image inspect` | no `dotnet restore`/SDK layers; image size close to `aspnet:10.0` | B |
| S10 | Force skip build layer | `tilt ci -- --skip-build-layer` | `catalog-api` also built without the SDK stage; S1 still green | B |
| S11 | No live update | `tilt up -- --no-live-update`; repeat S4 | image is rebuilt instead of synced | B |
| S12 | Custom service live update | edit `web-marker-1` in `samples/web/www/index.html` | `web` live-updates (sync only); `curl :5082/` shows the new marker | D |
| S13 | Custom without extend | `devsuite.local.json`: `{"extend_file": "missing.extend"}`; `tilt ci` | warning that `web` is `custom` but unclaimed; compose builds it; `e2e-smoke` absent; rest green | D |
| S14 | Duplicate build | add `docker_build("tiltvs-orders-api", "samples")` to `Tiltfile.extend` | readable error telling to set `tilt-build: custom` | D |
| S15 | Labels | `tilt-group` shows backend/frontend/infra/e2e groups in the UI; `tilt-links` show on orders/catalog | A |
| S16 | vsdbg mounted | `docker exec tiltvs-orders-api-1 /remote_debugger/vsdbg --help` (and in catalog; the packaged build rejects `--version`); `ls /home/app/.vs-debugger/` | binary runs, marker files present, mount is read-only | C |
| S17 | No debugger | `tilt ci -- --no-debugger` | no vsdbg mounts in `docker inspect` | C |
| S18 | Service subset | `tilt up -- orders-api` | only `orders-api` (and what it needs) enabled | A |
| S19 | Launcher | `dotnet run --project devsuite/launcher/DevSuite.Launcher -- ci` | same as S1 | F |
| S20 | Solution | `dotnet build TiltVs.slnx` | builds launcher + samples | F, G |
| W1 | VS 2026 F5 | open `TiltVs.slnx`, F5 | console shows `tilt up`, Tilt UI opens, stack green; services are not compiled by VS | F (Windows) |
| W2 | Attach | Debug > Attach to Process > Docker (Linux container) > `tiltvs-orders-api-1` > `dotnet`; breakpoint in `/orders` handler; `curl :5080/orders` | breakpoint hits, no vsdbg download (offline) | C, F (Windows) |
| W3 | Reattach after live update | after S4, Shift+Alt+P | reattaches to the restarted process | C, F (Windows) |
| W4 | Podman Hyper-V | run S1, S4, S12 on Podman machine (Hyper-V provider) | same results; bind mounts translated (vsdbg) | E (Windows) |
| W5 | Air-gapped | disconnect network, `tilt down`, `tilt up` | stack starts from preloaded images and offline NuGet | B, C, E (Windows) |

## Results

Linux test bench (Docker 29.8, compose v5.6, Tilt 0.35 from source), integration branch. Host .NET SDK 10.0.401.

| Date | Branch state | Result |
|---|---|---|
| 2026-10-06 | full integration: A-G merged (#1-#7) plus compose fallback fix (#8) | **All Linux scenarios pass** (details below); `--no-debugger` used except S16 |
| 2026-10-06 | integration with task A merged; B-F still skeleton | S1 pass (all 5 resources green, smoke passed), S2 pass (only the expected "dotnet pipeline not implemented" warnings), S12 pass (`tilt up`: marker edit live-synced with `Will copy 1 file(s)`, no image rebuild), S20 pass for the sample projects (`dotnet build` in `sdk:10.0`; with a placeholder launcher project the whole `.slnx` builds). S3 currently `Release` everywhere: the skeleton builds both Dockerfiles as-is without `BUILD_CONFIGURATION`. Other scenarios pending their modules. |

### Full run, 2026-10-06 (integration at `2a33fe8`)

| # | Result | Evidence |
|---|---|---|
| S1 | pass | `tilt ci --port 0 -- --no-debugger` from a clean `.tilt/` and no cached images: 1m22s, `SUCCESS`, smoke passed; summary: orders `skip build layer`, catalog `full build via docker`, web `built by Tiltfile.extend:12`, db `no-build` |
| S2 | pass | with `--no-debugger` exit 0, no warnings; without it, stops with `vsdbg drop missing: devsuite/vsdbg/drop/vs2022/linux-x64` (expected, no drop committed) |
| S3 | pass | both `/health` return `"configuration":"Debug"` |
| S4 | pass | Orders `Program.cs` edit: `orders-api-dotnet` publish (`2 file(s) updated`), `orders-api` `Will copy 2 file(s)`, no image build; `/` returns the new text |
| S5 | pass | same for catalog (full-build service): publish + copy, no image build |
| S6 | pass | `SharedVersion` bump: both publishes run (`4 file(s) updated`), both `/health` show `shared-2` |
| S7 | pass | `Directory.Build.props` edit: both publishes run (`0 file(s) updated`, nothing synced) |
| S8 | pass | touching `obj/x`, `bin/y`, `README.md`, `Properties/launchSettings.json`, `.vs/x`, `foo.user` one by one: 0 publishes. Edge case seen: **creating** a new `Properties/` folder (the folder itself, not the json) triggers one publish; harmless (no files change) and real projects already have the folder |
| S9 | pass | `docker history tiltvs-orders-api`: no SDK or `dotnet restore` layer; 340 MB, same as `aspnet:10.0` |
| S10 | pass | `--skip-build-layer`: catalog logs `skip build layer, image = runtime stage + .tilt/publish/catalog-api (1 COPY rewritten)`; green |
| S11 | pass, note | `--no-live-update`: Orders edit rebuilds the `orders-api` image (0.4s) instead of syncing. It also rebuilds `catalog-api` (12s), because without live update its full build is a plain `docker_build` watching the whole `samples/` context. Expected from the design; a per-service context would avoid it |
| S12 | pass | marker edit: `web` `Will copy 1 file(s)`, new marker served, no image build |
| S13 | pass | `extend_file: missing.extend`: `WARN ... web: tilt-build=custom but missing.extend does not exist ... docker compose builds it instead`; green |
| S14 | pass | duplicate `docker_build("tiltvs-orders-api", ...)`: `ERROR extend | Tiltfile.extend:30 docker_build() builds image 'tiltvs-orders-api' for service 'orders-api', but devsuite already builds it ... set the label tilt-build: custom` |
| S15 | pass | UI labels backend (APIs and `*-dotnet`), frontend, infra, e2e; links `:5080/orders`, `:5081/products` plus the published ports |
| S16 | pass (synthetic drop) | Microsoft's vsdbg hosts are blocked here, so the drop was built with `Get-VsDbgOffline.sh -a <archive>` from a stand-in `vsdbg` script (keys vs2022, vs2026). In both containers `/remote_debugger/vsdbg --help` runs, `success_version.txt` present, mounts at `/remote_debugger`, `/root/.vs-debugger/{vs2022,vs2026}`, `/home/app/.vs-debugger/{vs2022,vs2026}` all `rw=false`, write attempt gets `Read-only file system`. The real binary was not run |
| S17 | pass | covered by S1: no vsdbg mounts with `--no-debugger` |
| S18 | pass | `tilt up -- orders-api`: orders-api, its `depends_on` (catalog-api, db) and both `*-dotnet` enabled; web and e2e-smoke disabled |
| S19 | pass | `dotnet run --project devsuite/launcher/DevSuite.Launcher -- ci --down --no-debugger`: `tilt ci passed`, `tilt down exited with code 0`, no containers left |
| S20 | pass | `dotnet build TiltVs.slnx`: 0 warnings, 0 errors |

Watch on Windows: `~/.vs-debugger` itself is created by the engine as root-owned
(`drwxr-xr-x root`) in the non-root .NET images. If VS uses a key that is not mounted,
it cannot create it there and attach fails with a permission error rather than a
download; the fix is the key procedure in docs/vsdbg.md section 4.

Not verifiable here: W1-W5 (Windows, VS 2026, Podman Hyper-V).

## Troubleshooting the sample

* Docker Hub rate limits (`429 Too Many Requests`) when pulling `postgres`/`nginx`:
  pull from a mirror and retag, e.g.
  `docker pull mirror.gcr.io/library/postgres:16-alpine && docker tag mirror.gcr.io/library/postgres:16-alpine postgres:16-alpine`.
* Tilt tries to reach `events.windmill.build` / `cloud.tilt.dev` (analytics); harmless offline, silence with `tilt analytics opt out`.
* Port clash on 5080-5082 or 55432: change the host side in `docker-compose.yml`
  and the `*_URL` env vars used by `samples/e2e/smoke.sh`.
