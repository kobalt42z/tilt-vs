# Compose reader: docker-compose files -> project model + ServiceSpecs,
# then generated override + dc_resource wiring.
#
# Owner: task A (compose + labels). User reference: docs/compose.md.
#
#   load_project(settings) -> {"name","dir","files","services","order","source","env"}
#       Normalized model from `<compose_cmd> -f a.yml -f b.yml config --format json`
#       (compose itself merges files, interpolates ${VARS} from the shell and
#       .env, applies profiles). When the CLI is missing or fails, falls back
#       to read_yaml + a local merge/interpolation that covers the common
#       subset (logged as a warning with compose's error).
#   build_override(ctx) -> override compose dict, merged last by docker_compose()
#   register_resources(ctx) -> one dc_resource() per service (groups, trigger,
#       auto-start, links, extra deps; compose depends_on is added by Tilt).

load("./contracts.star", "new_service_spec", "BUILD_KINDS")
load("./labels.star", "normalize_labels", "parse_opts")
load("./log.star", "log")

_FAIL_MARK = "__DEVSUITE_COMPOSE_CONFIG_FAILED__"

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def _is_abs(p):
    return p.startswith("/") or p.startswith("\\") or (len(p) > 2 and p[1] == ":" and p[2] in "/\\")

def _join(base, p):
    # Tilt's os.path.join does not reset on an absolute second argument.
    return os.path.abspath(p if _is_abs(p) else os.path.join(base, p))

def _sanitize_name(name):
    # Same rule as compose: lowercase, [a-z0-9_-] only.
    out = ""
    for ch in name.lower().elems():
        out += ch if (ch.isalnum() or ch in "-_") else ""
    return out

def _as_dict(v, sep = "="):
    """Compose mapping-or-list fields (environment, labels, args) -> dict."""
    if v == None:
        return {}
    if type(v) == "dict":
        return dict(v)
    out = {}
    for item in v:
        k, has, val = str(item).partition(sep)
        out[k.strip()] = val if has else None
    return out

def _depends_dict(v):
    if v == None:
        return {}
    if type(v) == "dict":
        return dict(v)
    return {str(n): {"condition": "service_started"} for n in v}

def _volume_target(v):
    if type(v) == "dict":
        return v.get("target", "")
    parts = str(v).split(":")
    # "C:\src:/app[:ro]" -> drive letter is part of the source
    if len(parts) > 2 and len(parts[0]) == 1 and parts[1][:1] in ["\\", "/"]:
        parts = [parts[0] + ":" + parts[1]] + parts[2:]
    return parts[1] if len(parts) > 1 else parts[0]

def _shell_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

def _bat_quote(s):
    return '"' + s + '"'

# ---------------------------------------------------------------------------
# .env + ${VAR} interpolation (fallback path only; the CLI does its own)
# ---------------------------------------------------------------------------

def read_dotenv(path):
    env = {}
    if not os.path.exists(path):
        return env
    for line in str(read_file(path)).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        k, has, v = line.partition("=")
        if not has:
            continue
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        elif " #" in v:
            v = v.partition(" #")[0].rstrip()
        env[k.strip()] = v
    return env

def _lookup(name, env):
    v = os.getenv(name, None)
    if v != None:
        return v
    return env["dotenv"].get(name)

def _unset(name, env):
    if name not in env["warned"]:
        env["warned"][name] = True
        log.warn("compose", "variable '%s' is not set, defaulting to an empty string" % name)
    return ""

def _match_brace(s, start):
    depth = 0
    for i in range(start, len(s)):
        if s[i] == "{":
            depth += 1
        elif s[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def _ident_end(s, start):
    for j in range(start, len(s)):
        if not (s[j].isalnum() or s[j] == "_"):
            return j
    return len(s)

def _expand(expr, env, where):
    name = expr[:_ident_end(expr, 0)]
    rest = expr[len(name):]
    if name == "":
        log.fatal("compose", "%s: invalid interpolation '${%s}'" % (where, expr))
    val = _lookup(name, env)
    if rest == "":
        return val if val != None else _unset(name, env)
    for op in [":-", ":?", ":+", "-", "?", "+"]:
        if rest.startswith(op):
            arg = rest[len(op):]
            strict = op.startswith(":")  # ":" variants also treat "" as unset
            missing = val == None or (strict and val == "")
            if op.endswith("-"):
                return _interp(arg, env, where) if missing else val
            if op.endswith("?"):
                if missing:
                    log.fatal("compose", "%s: required variable '%s' is missing a value: %s" % (
                        where, name, _interp(arg, env, where) or name))
                return val
            return "" if missing else _interp(arg, env, where)
    log.fatal("compose", "%s: invalid interpolation '${%s}'" % (where, expr))

def _interp(s, env, where):
    if "$" not in s:
        return s
    out = ""
    n = len(s)
    i = 0
    for _ in range(n):  # every step consumes at least one char
        if i >= n:
            break
        ch = s[i]
        nxt = s[i + 1] if i + 1 < n else ""
        if ch != "$":
            out += ch
            i += 1
        elif nxt == "$":
            out += "$"
            i += 2
        elif nxt == "{":
            end = _match_brace(s, i + 1)
            if end < 0:
                log.fatal("compose", "%s: unterminated '${' in %r" % (where, s))
            out += _expand(s[i + 2:end], env, where)
            i = end + 1
        else:
            j = _ident_end(s, i + 1)
            if j == i + 1 or s[i + 1].isdigit():
                out += "$"
                i += 1
            else:
                name = s[i + 1:j]
                val = _lookup(name, env)
                out += val if val != None else _unset(name, env)
                i = j
    return out

def interpolate(v, env, where):
    """Recursively interpolate string values (not keys) like compose does."""
    t = type(v)
    if t == "string":
        return _interp(v, env, where)
    if t == "dict":
        return {k: interpolate(x, env, where) for k, x in v.items()}
    if t == "list":
        return [interpolate(x, env, where) for x in v]
    return v

# ---------------------------------------------------------------------------
# fallback merge of several compose files (subset of the compose merge rules)
# ---------------------------------------------------------------------------

_MAPPINGS = ["environment", "labels", "annotations", "sysctls", "extra_hosts"]
_SEQUENCES = ["ports", "expose", "external_links", "dns", "dns_search", "tmpfs",
              "cap_add", "cap_drop", "security_opt", "env_file", "profiles", "devices"]

def _merge_dicts(a, b):
    out = dict(a)
    for k, v in b.items():
        if type(v) == "dict" and type(out.get(k)) == "dict":
            out[k] = _merge_dicts(out[k], v)
        else:
            out[k] = v
    return out

def _build_dict(b):
    if b == None:
        return None
    return {"context": b} if type(b) == "string" else dict(b)

def merge_service(base, over):
    out = dict(base)
    for k, v in over.items():
        cur = out.get(k)
        if k in _MAPPINGS:
            m = _as_dict(cur, ":" if k == "extra_hosts" and type(cur) == "list" else "=")
            m.update(_as_dict(v, ":" if k == "extra_hosts" and type(v) == "list" else "="))
            out[k] = m
        elif k == "build":
            b = _build_dict(cur) or {}
            o = _build_dict(v)
            args = _as_dict(b.get("args"))
            args.update(_as_dict(o.get("args")))
            b = _merge_dicts(b, o)
            if args:
                b["args"] = args
            out[k] = b
        elif k == "depends_on":
            d = _depends_dict(cur)
            d.update(_depends_dict(v))
            out[k] = d
        elif k == "volumes":
            by_target = {}
            order = []
            for vol in (cur or []) + (v or []):
                t = _volume_target(vol)
                if t not in by_target:
                    order.append(t)
                by_target[t] = vol
            out[k] = [by_target[t] for t in order]
        elif k in _SEQUENCES and type(v) == "list":
            merged = list(cur or [])
            for x in v:
                if x not in merged:
                    merged.append(x)
            out[k] = merged
        elif type(v) == "dict" and type(cur) == "dict":
            out[k] = _merge_dicts(cur, v)
        else:
            out[k] = v
    return out

def _active_profiles():
    return [p.strip() for p in (os.getenv("COMPOSE_PROFILES", "") or "").split(",") if p.strip()]

def _load_yaml_model(settings, files, compose_dir):
    env = {"dotenv": read_dotenv(os.path.join(compose_dir, ".env")), "warned": {}}
    name = ""
    services = {}
    order = []
    for f in files:
        doc = read_yaml(f) or {}
        for unsupported in ["include"]:
            if unsupported in doc:
                log.warn("compose", "%s: '%s' is not supported without the compose CLI, ignored" % (f, unsupported))
        if doc.get("name"):
            name = interpolate(str(doc["name"]), env, f)
        for svc_name, raw in (doc.get("services") or {}).items():
            raw = interpolate(raw or {}, env, "%s: service '%s'" % (os.path.basename(f), svc_name))
            if "extends" in raw:
                log.warn("compose", "service '%s': 'extends' is not supported without the compose CLI, ignored" % svc_name)
            if svc_name in services:
                services[svc_name] = merge_service(services[svc_name], raw)
            else:
                services[svc_name] = merge_service({}, raw)
                order.append(svc_name)
    profiles = _active_profiles()
    active = []
    # read_yaml returns Go maps: key order is random, so sort like the CLI path.
    for svc_name in sorted(order):
        p = services[svc_name].get("profiles") or []
        if p and not [x for x in p if x in profiles or x == "*"]:
            log.debug("compose", "service '%s' skipped: profiles %s not active" % (svc_name, p))
            services.pop(svc_name)
        else:
            active.append(svc_name)
    if not name:
        name = os.getenv("COMPOSE_PROJECT_NAME", "") or os.path.basename(compose_dir)
    return {"name": name, "services": services, "order": active, "env": env["dotenv"]}

# ---------------------------------------------------------------------------
# compose CLI path
# ---------------------------------------------------------------------------

def _config_argv(settings, files, compose_dir):
    argv = [a for a in settings["compose_cmd"].split(" ") if a]
    for f in files:
        argv += ["-f", f]
    argv += ["--project-directory", compose_dir]
    if settings.get("project_name"):
        argv += ["-p", _sanitize_name(settings["project_name"])]
    return argv + ["config", "--format", "json"]

def _run_config(settings, files, compose_dir):
    """Returns (doc, error_text). Never fails the Tiltfile on its own."""
    if settings["compose_cmd"].strip() in ["", "none"]:
        return None, "compose_cmd is disabled in settings"
    argv = _config_argv(settings, files, compose_dir)
    sh = " ".join([_shell_quote(a) for a in argv])
    bat = " ".join([_bat_quote(a) for a in argv])
    log.debug("compose", "normalizing with: %s" % " ".join(argv))
    out = str(local(
        command = "%s 2>/dev/null || echo %s" % (sh, _FAIL_MARK),
        command_bat = "%s 2>NUL || echo %s" % (bat, _FAIL_MARK),
        quiet = True,
        echo_off = True,
    ))
    if _FAIL_MARK not in out and out.strip().startswith("{"):
        return decode_json(out), ""
    # Second run only to capture compose's error message for the log.
    err = str(local(
        command = "%s 2>&1 >/dev/null || true" % sh,
        command_bat = "%s 2>&1 >NUL || echo." % bat,
        quiet = True,
        echo_off = True,
    )).strip()
    return None, err or "no output"

# ---------------------------------------------------------------------------
# ServiceSpec construction
# ---------------------------------------------------------------------------

def _resolve_build(svc_name, raw, compose_dir, env):
    b = _build_dict(raw.get("build"))
    if b == None:
        return None
    ctx_val = str(b.get("context", "."))
    remote = "://" in ctx_val or ctx_val.startswith("git@")
    context = ctx_val if remote else _join(compose_dir, ctx_val)
    dockerfile = str(b.get("dockerfile", "Dockerfile"))
    args = {}
    for k, v in _as_dict(b.get("args")).items():
        if v == None:  # "ARG" with no value: compose takes it from the environment
            v = os.getenv(k, None) or env.get(k)
            if v == None:
                continue
        args[k] = str(v)
    out = {
        "context": context,
        "dockerfile": dockerfile if remote else _join(context, dockerfile),
        "target": b.get("target", "") or "",
        "args": args,
    }
    if remote:
        out["remote"] = True
    if b.get("dockerfile_inline"):
        out["dockerfile_inline"] = b["dockerfile_inline"]
    return out

def _pick_kind(settings, spec):
    name = spec["name"]
    label_kind = spec["opts"]["build"]
    if spec["build"] == None:
        if label_kind:
            log.info("compose", "%s: tilt-build=%s ignored, no build section (deploy only, image %s)" % (
                name, label_kind, spec["image_ref"] or "-"))
        else:
            log.info("compose", "%s: no build section, deploy only (image %s)" % (name, spec["image_ref"] or "-"))
        return "none", "no-build"
    if label_kind:
        log.info("compose", "%s: tilt-build=%s (label)" % (name, label_kind))
        return label_kind, "label"
    b = spec["build"]
    if b.get("remote") or b.get("dockerfile_inline"):
        why = "remote build context" if b.get("remote") else "dockerfile_inline"
        log.info("compose", "%s: no tilt-build label and %s, compose builds it (kind 'compose')" % (name, why))
        return "compose", "fallback"
    kind = settings["default_build_kind"]
    log.info("compose", "%s: no tilt-build label, defaulted to '%s'" % (name, kind))
    return kind, "default"

def _check_settings(settings):
    k = settings.get("default_build_kind")
    allowed = [x for x in BUILD_KINDS if x != "none"]
    if k not in allowed:
        log.fatal("compose", "settings: default_build_kind=%r is invalid, expected one of %s" % (
            k, " | ".join(allowed)))
    files = settings.get("compose_files")
    if type(files) == "string":
        files = [files]
    if not files:
        log.fatal("compose", "settings: compose_files is empty")
    return files

def load_project(settings):
    files = [os.path.abspath(f) for f in _check_settings(settings)]
    for f in files:
        if not os.path.exists(f):
            log.fatal("compose", "compose file not found: %s" % f)
    compose_dir = os.path.dirname(files[0])
    dotenv_path = os.path.join(compose_dir, ".env")
    watch_file(dotenv_path)

    doc, err = _run_config(settings, files, compose_dir)
    if doc != None:
        source = "cli"
        name = doc.get("name") or os.path.basename(compose_dir)
        raw_services = doc.get("services") or {}
        order = sorted(raw_services.keys())
        env = read_dotenv(dotenv_path)
    else:
        source = "yaml"
        log.warn("compose", "'%s config' failed, falling back to read_yaml (no extends/include): %s" % (
            settings["compose_cmd"], err))
        model = _load_yaml_model(settings, files, compose_dir)
        name, raw_services, order, env = model["name"], model["services"], model["order"], model["env"]
    name = _sanitize_name(settings.get("project_name") or name)
    if not name:
        log.fatal("compose", "could not derive a project name; set project_name in devsuite.json")

    services = {}
    for svc_name in order:
        raw = raw_services[svc_name]
        spec = new_service_spec(svc_name, raw, compose_dir)
        spec["labels"] = normalize_labels(raw.get("labels"))
        spec["opts"] = parse_opts(svc_name, spec["labels"])
        spec["build"] = _resolve_build(svc_name, raw, compose_dir, env)
        if spec["build"] == None:
            spec["image_ref"] = raw.get("image", "") or ""
        else:
            spec["image_ref"] = raw.get("image") or "%s-%s" % (name, svc_name)
        spec["build_kind"], spec["kind_source"] = _pick_kind(settings, spec)
        if spec["build_kind"] == "none" and not spec["image_ref"]:
            log.fatal("compose", "service '%s' has neither build nor image" % svc_name)
        services[svc_name] = spec
    log.info("compose", "project '%s': %d services from %s (via %s)" % (
        name, len(order), ", ".join(files), "compose config" if source == "cli" else "read_yaml"))
    return {
        "name": name,
        "dir": compose_dir,
        "files": files,
        "services": services,
        "order": order,
        "source": source,  # "cli" | "yaml"
        "env": env,        # .env values (shell env still wins)
    }

# ---------------------------------------------------------------------------
# override + resources
# ---------------------------------------------------------------------------

def _merge_volumes(vols):
    by_target = {}
    order = []
    for v in vols:
        t = _volume_target(v)
        if t not in by_target:
            order.append(t)
        by_target[t] = v  # later patch wins for the same container path
    return [by_target[t] for t in order]

def build_override(ctx):
    """Returns the override compose dict that docker_compose() merges last.

    - image: image_ref for every service Tilt (or Tiltfile.extend) builds, so
      docker_build(image_ref) pairs with the compose service deterministically
    - volumes / environment from each BuildResult.compose_patch (volumes are
      de-duplicated by container target, compose merges them by target too)
    - any other compose_patch key is copied as-is (additive extension point)
    """
    out = {}
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        res = ctx["results"].get(name)
        svc = {}
        if spec["build_kind"] not in ["none", "compose"]:
            svc["image"] = spec["image_ref"]
        if res:
            patch = res.get("compose_patch") or {}
            for k, v in patch.items():
                if not v:
                    continue
                if k == "volumes":
                    svc["volumes"] = _merge_volumes(v)
                elif k == "environment":
                    svc["environment"] = {ek: str(ev) for ek, ev in v.items()}
                else:
                    svc[k] = v
        if svc:
            out[name] = svc
    return {"services": out}

def register_resources(ctx):
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        opts = spec["opts"]
        res = ctx["results"].get(name)
        deps = []
        for d in list(opts["resource_deps"] or []) + (res["resource_deps"] if res else []):
            if d == name:
                log.warn("compose", "service '%s': tilt-resource-deps lists itself, ignored" % name)
            elif d not in deps:
                deps.append(d)
        groups = opts["group"] or [spec["build_kind"]]
        log.debug("compose", "%s: dc_resource labels=%s trigger=%s auto_start=%s deps=%s links=%s" % (
            name, groups, opts["trigger"], opts["auto_start"], deps, opts["links"]))
        dc_resource(
            name,
            labels = groups,
            trigger_mode = TRIGGER_MODE_MANUAL if opts["trigger"] == "manual" else TRIGGER_MODE_AUTO,
            auto_init = opts["auto_start"],
            links = opts["links"] or [],
            resource_deps = deps,
        )
