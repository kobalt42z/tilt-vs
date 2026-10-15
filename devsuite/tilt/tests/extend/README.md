# Tiltfile.extend fixtures (task D)

Each folder is a tiny project (compose file, `devsuite.json`, optional
`Tiltfile.extend`) whose `Tiltfile` loads `devsuite/tilt/main.star`. `expect`
lists the checks; `run.sh` evaluates every fixture with
`tilt alpha tiltfile-result` and checks the log and the resulting manifests.

```bash
devsuite/tilt/tests/extend/run.sh          # evaluate all fixtures (needs tilt + docker compose)
devsuite/tilt/tests/extend/run.sh --ci     # plus real `tilt ci` runs (needs a Docker engine)
devsuite/tilt/tests/extend/run.sh dup-helper custom-no-extend
```

All fixtures share one compose file: `api` (`tilt-build: docker`, build
target and list-form build args), `web` (`tilt-build: custom`) and `db`
(deploy only).

| Fixture | Tiltfile.extend | Expected |
|---|---|---|
| `custom-extend-fn` | `extend(ctx)` + plain `docker_build(web["image_ref"], ...)` | Tilt builds `web`; no warning; `api` built with target, args, pull=False |
| `custom-extend-helper` | `extend(ctx)` + `ctx["docker_build"]("web")` | Tilt builds `web`; no warning |
| `custom-extend-toplevel` | top-level `docker_build(WEB_IMAGE, ...)` + `local_resource` | Tilt builds `web`; extra resource registered |
| `custom-extend-chain` | ref via variables and `ref=` keyword; decoy calls in comment/string | Tilt builds `web`; decoys ignored |
| `custom-no-extend` | (none) | warning; compose builds `web` (`--ci` proves `extfix-web:latest` comes from compose) |
| `custom-extend-no-build` | builds nothing for `web` | warning; compose builds `web` |
| `dup-toplevel` | top-level `docker_build("extfix-api", ...)` | readable devsuite error naming the line and `tilt-build: custom`, before Tilt's own error |
| `dup-helper` | `ctx["docker_build"]("api")` | readable devsuite error |
| `dup-unresolved` | ref computed in a loop | Tilt's own error, with the devsuite hint line right above it |
