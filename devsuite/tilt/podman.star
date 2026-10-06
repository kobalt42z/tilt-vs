# Podman (Hyper-V machine) integration.
#
# Owner: task E (podman / hyper-v). See docs/podman-hyperv.md.
# Target behaviour (docs/plan/PLAN.md section 7):
#   preflight(settings): verify the engine answers (DOCKER_HOST / named pipe),
#     log engine + compose versions, set DOCKER_BUILDKIT=0 when the engine is
#     Podman, fail with a fix-it message otherwise.
#   translate(ctx, override): rewrite bind-mount sources (Windows paths) to
#     the path the Podman machine sees, for both the original compose volumes
#     and devsuite-added ones (same target => override replaces).
#
# Settings (settings["podman"], every key optional):
#   preflight   true                     ping the engine before anything else
#   engine      "auto"                   auto | podman | docker (auto = ask the engine)
#   probe_cmd   docker version ... json  command printing the engine's server version as JSON
#   buildkit    "auto"                   auto = off on Podman, untouched on Docker; true | false force
#   translate   "auto"                   auto = on when Tilt runs on Windows and the engine is Podman; true | false force
#   path_map    {"X:\\": "/mnt/x/"}      host prefix -> machine prefix. "X:\" matches any drive letter and
#                                        an "x" path segment in its value becomes that letter (C:\src -> /mnt/c/src).
#                                        Entries are merged over the default; set "X:\\": "" to drop the wildcard.
#   doctor      powershell ... Test-DevSuite.ps1   printed when the engine is unreachable
#
# Effective values are written back to settings["podman"], plus
# settings["podman"]["_engine"] = {"name","version","api","os","arch","platform"} and
# settings["podman"]["_translate"] (bool) once preflight ran.

load("./log.star", "log")

DEFAULTS = {
    "preflight": True,
    "engine": "auto",
    "probe_cmd": "docker version --format \"{{json .Server}}\"",
    "buildkit": "auto",
    "translate": "auto",
    "path_map": {"X:\\": "/mnt/x/"},
    "doctor": "powershell -NoProfile -ExecutionPolicy Bypass -File devsuite\\podman\\Test-DevSuite.ps1",
}

_FAIL = "__DEVSUITE_PROBE_FAILED__"
_WILDCARD = "X:\\"

# ---------------------------------------------------------------------------
# settings
# ---------------------------------------------------------------------------
def _config(settings):
    cfg = settings.get("podman") or {}
    if cfg.get("_applied"):
        return cfg
    out = dict(DEFAULTS)
    for k, v in cfg.items():
        out[k] = v
    pmap = dict(DEFAULTS["path_map"])
    pmap.update(cfg.get("path_map") or {})
    out["path_map"] = pmap
    out["_applied"] = True
    settings["podman"] = out
    return out

def _flag(v):
    """auto | true | false from a JSON bool or string."""
    if type(v) == "bool":
        return v
    s = str(v).lower()
    if s in ["true", "1", "yes", "on"]:
        return True
    if s in ["false", "0", "no", "off"]:
        return False
    return "auto"

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
def _run(cmd):
    """Runs cmd and returns (ok, output) without failing the Tiltfile."""
    full = "%s 2>&1 || echo %s" % (cmd, _FAIL)
    out = str(local(full, quiet = True, echo_off = True, command_bat = full))
    if _FAIL in out:
        return False, out.replace(_FAIL, "").strip()
    return True, out.strip()

def parse_engine(out):
    """Parses `docker version --format "{{json .Server}}"` (or podman's) output.

    Returns {"name","version","api","os","arch","platform"}; name is "podman",
    "docker" or "unknown". Lines before the JSON (warnings) are ignored."""
    line = ""
    for l in out.splitlines():
        l = l.strip()
        if l.startswith("{"):
            line = l
    if not line:
        return None
    v = decode_json(line)
    if type(v) != "dict":
        return None
    if "Server" in v and type(v["Server"]) == "dict":
        v = v["Server"]  # `podman version --format json` shape
    platform = ((v.get("Platform") or {}).get("Name")) or ""
    names = [platform] + [(c.get("Name") or "") for c in (v.get("Components") or [])]
    name = "docker"
    for n in names:
        if "podman" in n.lower():
            name = "podman"
    if not v.get("Version"):
        name = "unknown"
    return {
        "name": name,
        "version": v.get("Version") or "?",
        "api": v.get("ApiVersion") or v.get("APIVersion") or "?",
        "os": v.get("Os") or "",
        "arch": v.get("Arch") or "",
        "platform": platform,
    }

def _unreachable(cfg, out):
    host = os.getenv("DOCKER_HOST", "") or "(unset: default pipe/socket)"
    lines = [l.strip() for l in out.splitlines() if l.strip() not in ["", "null"]]
    first = lines[0] if lines else "no output"
    log.fatal("podman", "\n".join([
        "container engine not reachable: %s" % first,
        "  probe     : %s" % cfg["probe_cmd"],
        "  DOCKER_HOST=%s" % host,
        "  fix       : podman machine start   (Hyper-V: run from an elevated shell)",
        "  first-time: devsuite\\podman\\Setup-PodmanMachine.ps1",
        "  diagnose  : %s" % cfg["doctor"],
    ]))

def preflight(settings):
    cfg = _config(settings)
    want = cfg["engine"]
    if not _flag(cfg["preflight"]):
        log.info("podman", "preflight disabled (podman.preflight=false), engine assumed '%s'" % want)
        engine = {"name": want if want != "auto" else "unknown", "version": "?", "api": "?", "os": "", "arch": "", "platform": ""}
    else:
        ok, out = _run(cfg["probe_cmd"])
        if not ok:
            _unreachable(cfg, out)
        engine = parse_engine(out)
        if engine == None:
            _unreachable(cfg, "unexpected probe output: %s" % out)
        if want != "auto" and want != engine["name"]:
            log.warn("podman", "podman.engine=%s but the engine reports %s; using %s" % (want, engine["name"], want))
            engine["name"] = want
        log.info("podman", "engine %s %s (API %s, %s/%s) via DOCKER_HOST=%s" % (
            "Podman" if engine["name"] == "podman" else (engine["platform"] or engine["name"]), engine["version"], engine["api"], engine["os"], engine["arch"],
            os.getenv("DOCKER_HOST", "") or "default"))
        cok, cout = _run("%s version --short" % settings.get("compose_cmd", "docker compose"))
        if cok:
            log.info("podman", "compose %s (%s)" % (cout.splitlines()[-1] if cout else "?", settings.get("compose_cmd")))
        else:
            log.warn("podman", "'%s version' failed: %s. Tilt needs the docker-compose v2 CLI; run %s" % (
                settings.get("compose_cmd"), cout.splitlines()[0] if cout else "no output", cfg["doctor"]))
    cfg["_engine"] = engine
    _buildkit(cfg, engine)
    cfg["_translate"] = _translate_enabled(cfg, engine)
    log.info("podman", "bind path translation %s (podman.translate=%s, host os=%s)" % (
        "on" if cfg["_translate"] else "off", cfg["translate"], os.name))

def _buildkit(cfg, engine):
    mode = _flag(cfg["buildkit"])
    if mode == "auto":
        if engine["name"] != "podman":
            log.debug("podman", "BuildKit left to Tilt/compose defaults (engine %s)" % engine["name"])
            return
        mode = False
    before = os.getenv("DOCKER_BUILDKIT", "")
    os.putenv("DOCKER_BUILDKIT", "1" if mode else "0")
    if mode:
        log.info("podman", "DOCKER_BUILDKIT=1 (podman.buildkit=true)")
        return
    log.info("podman", "DOCKER_BUILDKIT=0 for Tilt, compose and custom builds (Podman has no BuildKit session API)")
    if before.lower() not in ["0", "false"]:
        # Verified with tilt 0.35 (ci and up): Tilt picks its image builder on
        # its first build, after the Tiltfile ran, so this putenv is enough.
        # Keeping it in the user environment (Setup-PodmanMachine.ps1 does)
        # also covers plain `docker compose` / `podman` runs outside Tilt.
        log.debug("podman", "DOCKER_BUILDKIT was %s when Tilt started" % (before or "unset"))

def _translate_enabled(cfg, engine):
    mode = _flag(cfg["translate"])
    if mode != "auto":
        return mode
    return os.name == "nt" and engine["name"] == "podman"

# ---------------------------------------------------------------------------
# path translation (pure string logic, host independent: testable on Linux)
# ---------------------------------------------------------------------------
def _is_drive(p):
    return len(p) >= 2 and p[1] == ":" and p[0].isalpha() and (len(p) == 2 or p[2] in "\\/")

def _is_unc(p):
    return p.startswith("\\\\") or p.startswith("//")

def is_windows_path(p):
    return _is_drive(p) or _is_unc(p)

def _norm_win(p):
    """C:/a/./b/../c -> C:\\a\\c ; \\\\srv\\share\\x stays UNC."""
    unc = _is_unc(p)
    parts = p.replace("/", "\\").split("\\")
    if unc:
        head = "\\\\" + "\\".join(parts[2:4])
        rest = parts[4:]
    else:
        head = parts[0].upper()
        rest = parts[1:]
    out = []
    for s in rest:
        if s == "" or s == ".":
            continue
        if s == "..":
            if out:
                out.pop()
            continue
        out.append(s)
    if unc and not out:
        return head
    return head + "\\" + "\\".join(out)

def _norm_posix(p):
    out = []
    for s in p.split("/"):
        if s == "" or s == ".":
            continue
        if s == "..":
            if out:
                out.pop()
            continue
        out.append(s)
    return "/" + "/".join(out)

def resolve_source(source, base_dir, home = ""):
    """Absolute, normalized host path of a bind source (compose rules:
    relative to the compose dir, ~ is the user's home)."""
    s = source
    if s == "~" or s.startswith("~/") or s.startswith("~\\"):
        s = (home or os.getenv("USERPROFILE", "") or os.getenv("HOME", "")) + s[1:]
    if is_windows_path(s):
        return _norm_win(s)
    if s.startswith("/"):
        return _norm_posix(s)
    if is_windows_path(base_dir):
        return _norm_win(base_dir + "\\" + s)
    return _norm_posix(base_dir + "/" + s)

def compile_map(path_map):
    """path_map dict -> list of entries sorted most specific first."""
    entries = []
    for k, v in path_map.items():
        if not v:
            continue
        win = is_windows_path(k)
        key = k.replace("/", "\\") if win else k
        sep = "\\" if win else "/"
        if not key.endswith(sep):
            key += sep
        val = v if v.endswith("/") else v + "/"
        entries.append({"key": key, "value": val, "win": win, "wild": k.replace("/", "\\") in [_WILDCARD, "X:"]})
    # longest key first; the drive wildcard always last
    return sorted(entries, key = lambda e: (0 if e["wild"] else 1, len(e["key"])), reverse = True)

def _drive_value(value, letter):
    segs = value.split("/")
    return "/".join([letter.lower() if s == "x" else s for s in segs])

def map_path(path, entries):
    """Maps an absolute normalized host path through compiled entries.
    Returns the machine path, or None when nothing matches."""
    win = is_windows_path(path)
    for e in entries:
        if e["win"] != win:
            continue
        if win:
            probe = path if path.endswith("\\") else path + "\\"
            if e["wild"]:
                if not _is_drive(probe):
                    continue
                value = _drive_value(e["value"], probe[0])
                rest = probe[3:]
            elif probe.lower().startswith(e["key"].lower()):
                value = e["value"]
                rest = probe[len(e["key"]):]
            else:
                continue
            rest = rest.replace("\\", "/")
        else:
            probe = path if path.endswith("/") else path + "/"
            if not probe.startswith(e["key"]):
                continue
            value = e["value"]
            rest = probe[len(e["key"]):]
        out = (value + rest).rstrip("/")
        return out or "/"
    return None

def translate_source(source, base_dir, path_map, home = ""):
    """Bind source as written in compose -> path the engine VM sees.
    Returns {"source": <new>, "mapped": bool, "host": <absolute host path>}."""
    host = resolve_source(source, base_dir, home)
    entries = compile_map(path_map) if type(path_map) == "dict" else path_map
    mapped = map_path(host, entries)
    if mapped == None:
        return {"source": host, "mapped": False, "host": host}
    return {"source": mapped, "mapped": True, "host": host}

def _is_path_source(s):
    return s.startswith(".") or s.startswith("/") or s.startswith("~") or s.startswith("\\") or is_windows_path(s)

def parse_volume(v):
    """Compose volume (short string or long dict) -> long-syntax dict, or None.
    Short syntax understands Windows drive sources (C:\\src:/app:ro)."""
    if type(v) == "dict":
        out = dict(v)
        if not out.get("type"):
            out["type"] = "bind" if _is_path_source(out.get("source") or "") else "volume"
        return out
    if type(v) != "string":
        return None
    s = v
    src = ""
    if _is_drive(s):
        i = s.find(":", 2)
        if i < 0:
            return {"type": "volume", "target": s}  # Windows-container anonymous volume; not ours
        src = s[:i]
        s = s[i + 1:]
    elif ":" in s:
        i = s.find(":")
        src = s[:i]
        s = s[i + 1:]
    else:
        return {"type": "volume", "target": s}  # anonymous volume
    parts = s.split(":")
    target = parts[0]
    mode = parts[1].split(",") if len(parts) > 1 else []
    out = {"type": "bind" if _is_path_source(src) else "volume", "source": src, "target": target}
    if "ro" in mode:
        out["read_only"] = True
    for m in mode:
        if m in ["z", "Z"]:
            out["bind"] = {"selinux": m}
        if m in ["shared", "slave", "private", "rshared", "rslave", "rprivate"]:
            b = out.get("bind") or {}
            b["propagation"] = m
            out["bind"] = b
    return out

def translate_volumes(name, original, extra, base_dir, path_map, home = ""):
    """Returns (volumes, changes) for one service.

    original: the service's compose volumes; only bind mounts whose source
              changes are re-emitted (compose merges by target).
    extra:    devsuite volumes from the override; all re-emitted, binds
              translated, and they win over an original with the same target.
    changes:  list of "host -> machine" strings, plus "!host" for binds no
              path_map entry covers (left as the absolute host path)."""
    entries = compile_map(path_map)
    out = []
    index = {}
    changes = []
    for v, from_override in [(x, False) for x in (original or [])] + [(x, True) for x in (extra or [])]:
        b = parse_volume(v)
        if b == None:
            continue
        if b["type"] == "bind" and b.get("source"):
            t = translate_source(b["source"], base_dir, entries, home)
            if not t["mapped"]:
                if is_windows_path(t["host"]):
                    changes.append("!" + t["host"])
                if not from_override:
                    continue  # nothing to rewrite, the original stays as written
            elif t["source"] == b["source"]:
                if not from_override:
                    continue
            else:
                changes.append("%s -> %s" % (t["host"], t["source"]))
                b["source"] = t["source"]
        elif not from_override:
            continue  # named / anonymous volumes stay in the original file
        else:
            b = v  # devsuite non-bind volume: pass through untouched
        tgt = b.get("target") if type(b) == "dict" else None
        if tgt != None and tgt in index:
            out[index[tgt]] = b
        else:
            if tgt != None:
                index[tgt] = len(out)
            out.append(b)
    return out, changes

def translate(ctx, override):
    cfg = _config(ctx["settings"])
    enabled = cfg.get("_translate")
    if enabled == None:  # preflight not run (fixtures, callers outside main.star)
        enabled = _flag(cfg["translate"]) == True
    if not enabled:
        log.debug("podman", "bind path translation off")
        return override
    services = override.get("services") or {}
    total = 0
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        svc = services.get(name) or {}
        raw = spec.get("raw") or {}
        vols, changes = translate_volumes(name, raw.get("volumes"), svc.get("volumes"),
                                          spec["compose_dir"], cfg["path_map"])
        for c in changes:
            if c.startswith("!"):
                log.warn("podman", "%s: no podman.path_map entry for bind source %s; passed through as is" % (name, c[1:]))
            else:
                log.debug("podman", "%s: bind %s" % (name, c))
        mapped = len([c for c in changes if not c.startswith("!")])
        if vols:
            svc["volumes"] = vols
            services[name] = svc
        if mapped:
            total += mapped
            res = ctx["results"].get(name)
            if res != None:
                res["notes"].append("%d bind path(s) translated" % mapped)
    override["services"] = services
    log.info("podman", "translated %d bind source(s) for the Podman machine" % total)
    return override
