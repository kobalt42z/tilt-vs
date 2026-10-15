# tilt-vs

Dev suite for running a Docker Compose stack through **Tilt**, launched with **F5 from Visual Studio 2026**,
on **Podman (Hyper-V backend) on Windows**, fully **air-gapped** (vsdbg shipped offline).

* Plan, label schema, task split: [docs/plan/PLAN.md](docs/plan/PLAN.md)
* Entry point: `Tiltfile` -> `devsuite/tilt/main.star`

## Quick start (sample)

```bash
# prerequisites: Docker or Podman + docker compose v2, Tilt 0.35, .NET 10 SDK
tilt up          # or F5 in Visual Studio 2026 on TiltVs.slnx (DevSuite.Launcher)
tilt ci          # one-shot: build, start, run the e2e smoke check, exit
tilt down
```

The sample stack (`docker-compose.yml`, `samples/`) has two .NET 10 APIs, a custom
nginx service built by `Tiltfile.extend` and a deploy-only postgres.
Scenario checklist and results: [docs/e2e.md](docs/e2e.md).

Status: skeleton on the `integration` branch; modules are being implemented in parallel.
