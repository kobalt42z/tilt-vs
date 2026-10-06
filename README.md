# tilt-vs

Dev suite for running a Docker Compose stack through **Tilt**, launched with **F5 from Visual Studio 2026**,
on **Podman (Hyper-V backend) on Windows**, fully **air-gapped** (vsdbg shipped offline).

* Plan, label schema, task split: [docs/plan/PLAN.md](docs/plan/PLAN.md)
* Entry point: `Tiltfile` -> `devsuite/tilt/main.star`

Status: skeleton on the `integration` branch; modules are being implemented in parallel.
