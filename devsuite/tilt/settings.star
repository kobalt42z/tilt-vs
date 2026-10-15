# devsuite settings.
#
# Sources, later wins:
#   1. DEFAULTS below
#   2. devsuite.json        (committed, next to the root Tiltfile)
#   3. devsuite.local.json  (per developer, git-ignored)
#   4. CLI flags:  tilt up -- --skip-build-layer --no-debugger [service ...]
#
# Each module keeps its own section (e.g. settings["vsdbg"]) and applies its
# own defaults for keys inside it, so tasks never edit each other's defaults.
#
# Owner: integration. Tasks may add a top-level section key here (additive).

load("./log.star", "log")

DEFAULTS = {
    "compose_files": ["docker-compose.yml"],
    "project_name": "",            # "" -> folder name of the first compose file
    "compose_cmd": "docker compose",  # used to normalize the compose model
    "default_build_kind": "dotnet",
    "extend_file": "Tiltfile.extend",
    "work_dir": ".tilt",           # devsuite scratch (publish output, generated files)
    "dotnet": {},                  # task B
    "vsdbg": {},                   # task C
    "podman": {},                  # task E
    "launcher": {},                # task F; read by the C# F5 launcher only (docs/visual-studio.md)
}

def _merge(base, over):
    out = dict(base)
    for k, v in over.items():
        if type(v) == "dict" and type(out.get(k)) == "dict":
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out

def _read(path):
    if os.path.exists(path):
        log.info("settings", "reading %s" % path)
        return read_json(path)
    log.debug("settings", "%s not found, skipped" % path)
    return {}

def load_settings():
    config.define_string_list("services", args = True, usage = "compose services to run (default: all)")
    config.define_bool("skip-build-layer", usage = "force tilt-skip-build-layer=true for every dotnet service")
    config.define_bool("no-debugger", usage = "do not mount vsdbg into any container")
    config.define_bool("no-live-update", usage = "rebuild images instead of syncing files")
    cli = config.parse()

    root = config.main_dir
    s = _merge(DEFAULTS, _read(os.path.join(root, "devsuite.json")))
    s = _merge(s, _read(os.path.join(root, "devsuite.local.json")))
    s["cli"] = {
        "services": cli.get("services", []),
        "skip_build_layer": cli.get("skip-build-layer", False),
        "no_debugger": cli.get("no-debugger", False),
        "no_live_update": cli.get("no-live-update", False),
    }
    log.debug("settings", "effective settings: %s" % s)
    return s
