# Tiltfile.extend, `custom` and `docker` services

devsuite builds most services for you from `docker-compose.yml` labels. When a
service needs something devsuite does not do, put the Tilt code in
**`Tiltfile.extend`** (next to the root `Tiltfile`) instead of editing the
`Tiltfile` or `devsuite/`. Start from `Tiltfile.extend.example`.

## Build kinds this covers

| `tilt-build` | Who builds the image | Use it for |
|---|---|---|
| `docker` | Tilt: `docker_build` of the service Dockerfile as-is (`pull=False`) | non-.NET services you still want Tilt to rebuild on change (Node, nginx, Go...) |
| `custom` | your `Tiltfile.extend`; compose if nobody does | anything special: another Dockerfile, Buildah, a script, live_update rules |
| `compose` | `docker compose up --build` | images you never want Tilt to manage |

(`dotnet` is documented in `docs/dotnet.md`; services without `build:` are deploy only.)

### `docker` kind details

* `docker_build(image_ref, build.context, dockerfile = build.dockerfile, target = build.target, build_args = build.args, pull = False)`.
* `build.args` accepts compose's dict or list form; `- NAME` without a value takes `NAME` from the environment (skipped when unset), like compose.
* `tilt-ignore` (comma list) is passed as `ignore=`; `.dockerignore` applies as usual.
* `pull = False` never forces a base image pull, so air-gapped engines use what `podman load` put there. A base image that is missing locally is still looked up by the engine.

## How Tiltfile.extend is merged

`devsuite_up()` registers every devsuite resource (builds, the compose project,
`dc_resource` settings), then:

1. **Pre-scan.** devsuite reads the file and finds every `docker_build(...)` /
   `custom_build(...)` call (comments and strings ignored). It resolves the
   image ref when it is a string literal, a variable assigned once, or a chain
   back to `ctx["project"]["services"]["<name>"]["image_ref"]` (through
   variables too). A ref devsuite already builds stops here with a readable
   error (below).
2. **`load_dynamic(Tiltfile.extend)`.** Top-level Tilt calls run as if they
   were in the `Tiltfile` (`local_resource`, `docker_build`, `dc_resource`,
   `load("ext://...")`...). Tilt assembles resources after the whole Tiltfile
   ran, so registering after devsuite is fine.
3. **`extend(ctx)`**, if the file defines it, with the context below.
4. **Unbuilt custom check.** Every `tilt-build: custom` service whose image
   nobody built gets a warning and is built by docker compose instead (PLAN
   §11 default 5).

The path comes from the `extend_file` setting (default `Tiltfile.extend`,
relative to the root `Tiltfile`, absolute paths allowed). Only one root file
is supported (PLAN §11 default 6). Tilt watches it: saving it re-runs the Tiltfile.

### `ctx` inside `extend(ctx)`

| Key | What |
|---|---|
| `ctx["project"]["services"][name]` | ServiceSpec: `image_ref`, `build` (`context`, `dockerfile`, `target`, `args`, absolute paths), `build_kind`, `labels`, `opts` |
| `ctx["project"]["name" / "dir" / "files" / "order"]` | compose project facts |
| `ctx["settings"]` | merged `devsuite.json` + `devsuite.local.json` + CLI flags (`ctx["settings"]["cli"]`) |
| `ctx["results"][name]` | what devsuite registered for each service |
| `ctx["docker_build"](svc, context = None, **kwargs)` | `docker_build` with the service's ref; context, Dockerfile and target default to its compose build section; `pull=False` unless you pass it |
| `ctx["custom_build"](svc, command, deps, **kwargs)` | `custom_build` with the service's ref |
| `ctx["claim"](svc)` | tell devsuite you build `svc` some way it cannot see (silences the unbuilt warning) |
| `ctx["log"]` | devsuite logger: `ctx["log"].info("scope", "message")`, `.debug`, `.warn`, `.fatal` |

Never hard-code image names such as `tilt-vs-web`: the project name, and so
the ref, changes with the folder name and settings. Take
`ctx["project"]["services"][name]["image_ref"]`.

## Errors and warnings

**Building an image devsuite already builds** (a `dotnet` or `docker`
service). Tilt only allows one build per image ref, and its own message
(`Image for ref "x" has already been defined`) does not say what to do.
devsuite stops first:

```
[devsuite] ERROR extend    | Tiltfile.extend:2 docker_build() builds image 'extfix-api' for service 'api',
but devsuite already builds it (tilt-build=docker, label). Tilt allows only one build per image. Either set
the label `tilt-build: custom` on 'api' in docker-compose.yml so only Tiltfile.extend builds it, or remove
the build from Tiltfile.extend.
```

The same check runs for `ctx["docker_build"]` / `ctx["custom_build"]`. When a
ref is computed in a way the pre-scan cannot follow (a loop, string
formatting, a function argument), Tilt's own error is what you see, and
devsuite prints this line right above it:

```
[devsuite] INFO  extend    | devsuite already builds extfix-api. If Tiltfile.extend builds one of these too,
set `tilt-build: custom` on that service.
```

**`custom` service nobody built.**

```
[devsuite] WARN  extend    | web: tilt-build=custom but Tiltfile.extend does not build image 'extfix-web',
so docker compose builds it instead. ...
```

The stack still comes up: Tilt runs compose for that service without
`--no-build`, so compose builds `extfix-web:latest` from the service's
`build:` section. When the extend has build calls devsuite cannot resolve, it
cannot tell, so this becomes an INFO line suggesting `ctx["docker_build"]` or
`ctx["claim"]`.

The summary at the end of the Tiltfile log says, per custom service, who built it:
`built by Tiltfile.extend:4 docker_build()`, `built by extend(ctx) docker_build`,
`compose builds it (no build in Tiltfile.extend)` or `build not confirmed (...)`.

## Tests

Fixtures live in `devsuite/tilt/tests/extend/` (see its README):

```bash
devsuite/tilt/tests/extend/run.sh        # tilt alpha tiltfile-result on every fixture
devsuite/tilt/tests/extend/run.sh --ci   # plus real tilt ci runs
```

## Limits

* The pre-scan is static. It does not follow refs built with `%`/`+`/`format`,
  loops, or function parameters; those calls still work, devsuite just
  cannot confirm them (see above). Prefer `ctx["docker_build"]`.
* Calling `dc_resource` again for a devsuite service from the extend is not
  checked by devsuite; Tilt decides what happens.
* Tilt extensions (`ext://`) fetch from GitHub; air-gapped, register a
  vendored extension repo with `v1alpha1.extension_repo` first.
* Verified on Linux with Docker 29 and Tilt 0.35.2 built from source. Not
  verified here: Windows, Podman with the Hyper-V provider, VS 2026. Nothing in
  this module is OS specific; `pull=False` behaviour on Podman's compat API
  (classic builder) should be checked once on Windows.
