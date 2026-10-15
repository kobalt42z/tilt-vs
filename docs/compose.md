# Compose model and labels

How devsuite reads your `docker-compose.yml`, what the `tilt-*` labels do, and
what it hands to Tilt. Code: `devsuite/tilt/compose.star`, `devsuite/tilt/labels.star`;
schema: `LABELS` in `devsuite/tilt/contracts.star`; tests: `devsuite/tilt/tests/compose/`.

## 1. Reading the compose project

Settings involved (`devsuite.json` / `devsuite.local.json`):

| Key | Default | Meaning |
|---|---|---|
| `compose_files` | `["docker-compose.yml"]` | one or more files, merged in order like `docker compose -f a -f b`. The first file's folder is the project directory (relative paths, `.env`). |
| `compose_cmd` | `"docker compose"` | CLI used to normalize the files (`"podman compose"`, `"docker-compose"` work too). `"none"` skips it. |
| `project_name` | `""` | overrides the compose project name (and therefore default image names). |
| `default_build_kind` | `"dotnet"` | kind used when a service has `build:` but no `tilt-build` label. |

**Primary path.** devsuite runs

```
<compose_cmd> -f <file1> -f <file2> ... --project-directory <dir> [-p <project_name>] config --format json
```

and uses compose's own output as the model, so everything compose supports is
honoured exactly: file merging, `${VAR}` interpolation from the shell and `.env`,
`extends`, `include`, profiles (`COMPOSE_PROFILES`), and long/short syntax
normalization. Compose's own warnings (unset variables...) are not repeated.

**Fallback.** If the CLI is missing or exits non-zero, devsuite logs one warning with
compose's error message and reads the files with `read_yaml` instead:

```
[devsuite] WARN  compose   | 'docker compose config' failed, falling back to read_yaml (no extends/include): <compose error>
```

The fallback implements the common subset:

* merging several files: mappings (`environment`, `labels`, `build`, `build.args`,
  `depends_on`, ...) merge by key (list and dict forms mixed freely), `volumes` merge
  by container target, `ports`/`expose`/... are concatenated, scalars are replaced;
* interpolation of every string value: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
  `${VAR:?error}`, `${VAR?error}`, `${VAR:+alt}`, `${VAR+alt}`, nested defaults and `$$`.
  Values come from the shell environment first, then `.env` next to the first compose file;
  unset variables warn once and become `""`; a missing required variable stops the Tiltfile
  naming the file and service;
* `profiles`: services whose profiles are not in `COMPOSE_PROFILES` are skipped;
* project name: `project_name` setting > top-level `name:` > `COMPOSE_PROJECT_NAME` > folder name.

Not supported in the fallback (warned, then ignored): `extends`, `include`.
If you rely on them, make sure `compose_cmd` works.

Either way `.env` and every compose file are watched: editing them re-runs the Tiltfile.
Services are processed in alphabetical order.

## 2. ServiceSpec per service

`ctx["project"]["services"][name]` (contract in `contracts.star`):

| Field | Value |
|---|---|
| `raw` | normalized compose service dict (as compose printed it, or as the fallback merged it) |
| `build` | `None` (no `build:`) or `{"context", "dockerfile", "target", "args"}` with absolute paths. `dockerfile` is resolved against the context; `args` are strings (an arg with no value takes the env/.env value, or is dropped). Extra keys when relevant: `remote: True` (git/URL context), `dockerfile_inline`. |
| `image_ref` | the compose `image:` if set, else `<project>-<service>` (compose's own default); for a deploy-only service, its `image:` |
| `build_kind`, `kind_source` | see §4 |
| `labels` | all compose labels as a `{string: string}` dict |
| `opts` | typed `tilt-*` values, one key per `LABELS[*].opt`, defaults filled in |

`ctx["project"]` also carries `source` (`"cli"` or `"yaml"`) and `env` (the `.env` values).

## 3. Labels

Labels may be written in either compose form:

```yaml
labels:                       # dict form
  tilt-build: dotnet
  tilt-skip-build-layer: true # unquoted YAML bools/numbers are fine
labels:                       # list form
  - tilt-build=dotnet
  - tilt-group=backend,apis
```

Types and validation (`labels.star`):

| Type | Labels | Accepted | Invalid value |
|---|---|---|---|
| enum | `tilt-build`, `tilt-trigger`, `tilt-debugger-rid` | listed values, case-insensitive | Tiltfile stops: `service 'orders': label tilt-build="maven" is invalid, expected one of dotnet \| custom \| docker \| compose` |
| bool | `tilt-skip-build-layer`, `tilt-live-update`, `tilt-debugger`, `tilt-auto-start` | `true/false`, `1/0`, `yes/no`, `on/off`; empty = false | Tiltfile stops: `... expected true or false` |
| list | `tilt-watch`, `tilt-ignore`, `tilt-group`, `tilt-links`, `tilt-resource-deps` | comma separated, blanks trimmed | `tilt-group` items must be valid Tilt labels (letters, digits, `-_.`, max 63, alphanumeric at both ends) |
| string | `tilt-project`, `tilt-configuration`, `tilt-app-path`, `tilt-publish-args`, `tilt-debugger-user-home` | anything; empty = default | - |

Any other label starting with `tilt-` is ignored with a warning and a suggestion:

```
[devsuite] WARN  labels    | service 'api': unknown label 'tilt-buidl' ignored (did you mean 'tilt-build'?)
```

Labels without the `tilt-` prefix are left alone. Defaults and meaning of each label
are in [PLAN.md §3](plan/PLAN.md#3-compose-label-schema); this module only parses them,
the consuming module (`dotnet`, `vsdbg`, `compose`) applies them.

## 4. Build kind

| Service | Kind | `kind_source` | Log line |
|---|---|---|---|
| no `build:` | `none` (deploy only, any `tilt-build` ignored) | `no-build` | `db: no build section, deploy only (image postgres:16-alpine)` |
| `build:` + `tilt-build` | the label value | `label` | `api: tilt-build=dotnet (label)` |
| `build:` with a git/URL context or `dockerfile_inline`, no label | `compose` | `fallback` | `remote: no tilt-build label and remote build context, compose builds it (kind 'compose')` |
| `build:` without label | `default_build_kind` (default `dotnet`) | `default` | `api: no tilt-build label, defaulted to 'dotnet'` |

`default_build_kind` itself is validated (`dotnet`, `custom`, `docker`, `compose`).
The dotnet module may later downgrade a `dotnet` service to `docker` (no single csproj),
with `kind_source = "fallback"`.

## 5. Generated override

`build_override(ctx)` returns a compose document that `main.star` passes last to
`docker_compose([...compose_files, override])`:

* `image: <image_ref>` for every service of kind `dotnet`, `docker` or `custom`, so a
  `docker_build(image_ref, ...)` (devsuite's or Tiltfile.extend's) pairs with it. Kinds
  `compose` and `none` keep their compose definition (compose builds / pulls).
* From each module's `BuildResult.compose_patch`:
  * `volumes`: de-duplicated by container `target` (the last patch wins); compose then
    merges them with the original service volumes by target, so a devsuite mount replaces
    a user mount on the same path;
  * `environment`: merged by key, values turned into strings;
  * any other non-empty key (e.g. `user`) is copied as-is, an additive extension point.

Run with `DEVSUITE_LOG_LEVEL=debug` to see the generated override in the Tiltfile log.

## 6. Tilt resources

One `dc_resource` per service:

| Argument | From |
|---|---|
| `labels` (Tilt UI groups) | `tilt-group`, else the build kind (`dotnet`, `custom`, `none`, ...) |
| `trigger_mode` | `tilt-trigger=manual` -> `TRIGGER_MODE_MANUAL`, else auto |
| `auto_init` | `tilt-auto-start` (default `true`); `false` registers the resource without starting it |
| `links` | `tilt-links` URLs |
| `resource_deps` | `tilt-resource-deps` + module deps (e.g. `orders-api-dotnet`), de-duplicated; a service listing itself is warned and dropped. Compose `depends_on` is added by Tilt itself. |

Combined trigger/auto-start behaviour (Tilt semantics): manual + auto-start = built once
at startup, then only on click; auto + no auto-start = starts on first click, then
rebuilds on change; manual + no auto-start = only on click.

## 7. Tests

```bash
devsuite/tilt/tests/compose/run.sh            # all cases
devsuite/tilt/tests/compose/run.sh bad-enum   # one case
```

Each case folder holds a Tiltfile that calls `harness.star`'s `run()` (the compose half of
`main.star`, without the build modules), compose files, optional `devsuite.json`, `.env`,
`env` (exported for that case) and an `expect` file checked against the Tiltfile log, the
printed model and the `tilt alpha tiltfile-result` JSON. Needs `tilt`, `jq` and the
`docker compose` CLI (only `config`, no daemon).

Covered: dict and list labels with every type, defaults, unknown-label warning, invalid
enum / bool / group / setting errors, default kind and `default_build_kind`, remote context,
deploy-only, project name sanitizing, multiple files + interpolation + `.env` + shell env on
both the CLI and fallback paths, every interpolation operator, missing required variable on
both paths, profiles on both paths, fallback warnings (`include`, `extends`, unset variable),
missing compose file, service without build or image, override patch merging and
`dc_resource` wiring (groups, trigger modes, auto-start, links, deps).

## 8. Not verified here

* Windows: the fallback detection uses `command_bat` with `2>NUL || echo ...` and
  `2>&1 >NUL || echo.` under `cmd.exe`; written to standard cmd semantics but not run on Windows.
* `podman compose config --format json` (Podman Desktop delegates to docker-compose v2,
  which supports it; the native `podman-compose` Python tool does not and lands on the fallback).
* Windows drive-letter paths in short volume syntax are handled when computing the target
  (`C:\src:/app`), but path translation itself is task E's.
