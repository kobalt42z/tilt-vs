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
* .NET 10 SDK on the host (needed once task B's local `dotnet publish` lands; the
  skeleton builds everything in containers)
* Base images present locally (`pull=False`, air-gapped): `mcr.microsoft.com/dotnet/aspnet:10.0`,
  `mcr.microsoft.com/dotnet/sdk:10.0` (only `catalog-api`'s full build needs it),
  `nginx:1.27-alpine`, `postgres:16-alpine`

## Scenario checklist

Run from the repository root. "Expect" is what passes; the status column records
the last run (see Results below). Owner = the module the scenario validates.

| # | Scenario | Steps | Expect | Owner |
|---|---|---|---|---|
| S1 | Cold start | `tilt ci --port 0` | exit 0, `SUCCESS. All workloads are healthy.`, `e2e-smoke` prints `smoke: all checks passed`; summary has one line per service with the right kind | all |
| S2 | Evaluate only | `tilt alpha tiltfile-result` | exit 0, no `WARN` except known-unimplemented modules | all |
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
| S16 | vsdbg mounted | `docker exec tiltvs-orders-api-1 /remote_debugger/vsdbg --version` (and in catalog); `ls /home/app/.vs-debugger/` | binary runs, marker files present, mount is read-only | C |
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

Linux test bench (Docker 29.8, compose v5.6, Tilt 0.35 from source), integration branch.

| Date | Branch state | Result |
|---|---|---|
| 2026-10-06 | integration with task A merged; B-F still skeleton | S1 pass (all 5 resources green, smoke passed), S2 pass (only the expected "dotnet pipeline not implemented" warnings), S12 pass (`tilt up`: marker edit live-synced with `Will copy 1 file(s)`, no image rebuild), S20 pass for the sample projects (`dotnet build` in `sdk:10.0`; with a placeholder launcher project the whole `.slnx` builds). S3 currently `Release` everywhere: the skeleton builds both Dockerfiles as-is without `BUILD_CONFIGURATION`. Other scenarios pending their modules. |

Not verifiable here: W1-W5 (Windows, VS 2026, Podman Hyper-V).

## Troubleshooting the sample

* Docker Hub rate limits (`429 Too Many Requests`) when pulling `postgres`/`nginx`:
  pull from a mirror and retag, e.g.
  `docker pull mirror.gcr.io/library/postgres:16-alpine && docker tag mirror.gcr.io/library/postgres:16-alpine postgres:16-alpine`.
* Tilt tries to reach `events.windmill.build` / `cloud.tilt.dev` (analytics); harmless offline, silence with `tilt analytics opt out`.
* Port clash on 5080-5082 or 55432: change the host side in `docker-compose.yml`
  and the `*_URL` env vars used by `samples/e2e/smoke.sh`.
