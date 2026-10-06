# Compose reader: docker-compose files -> project model + ServiceSpecs,
# then generated override + dc_resource wiring.
#
# Owner: task A (compose + labels).
# SKELETON: reads the first compose file with read_yaml, resolves build
# context/dockerfile, picks build_kind. Task A replaces the reader with a
# normalized model (`<compose_cmd> config --format json`, env interpolation,
# multiple files, profiles) and hardens the override/dc_resource wiring.

load("./contracts.star", "new_service_spec", "BUILD_KINDS")
load("./labels.star", "normalize_labels", "parse_opts")
load("./log.star", "log")

def _project_name(settings, compose_dir):
    name = settings.get("project_name") or os.path.basename(compose_dir)
    out = ""
    for ch in name.lower().elems():
        out += ch if (ch.isalnum() or ch in "-_") else "-"
    return out

def _resolve_build(raw, compose_dir):
    b = raw.get("build")
    if b == None:
        return None
    if type(b) == "string":
        b = {"context": b}
    context = os.path.abspath(os.path.join(compose_dir, b.get("context", ".")))
    dockerfile = os.path.abspath(os.path.join(context, b.get("dockerfile", "Dockerfile")))
    return {
        "context": context,
        "dockerfile": dockerfile,
        "target": b.get("target", ""),
        "args": b.get("args", {}) or {},
    }

def load_project(settings):
    files = [os.path.abspath(f) for f in settings["compose_files"]]
    for f in files:
        if not os.path.exists(f):
            log.fatal("compose", "compose file not found: %s" % f)
    compose_dir = os.path.dirname(files[0])
    doc = read_yaml(files[0])
    name = _project_name(settings, compose_dir)
    services = {}
    order = []
    for svc_name, raw in (doc.get("services") or {}).items():
        spec = new_service_spec(svc_name, raw, compose_dir)
        spec["labels"] = normalize_labels(raw.get("labels"))
        spec["opts"] = parse_opts(svc_name, spec["labels"])
        spec["build"] = _resolve_build(raw, compose_dir)
        if spec["build"] == None:
            spec["build_kind"] = "none"
            spec["kind_source"] = "no-build"
            spec["image_ref"] = raw.get("image", "")
            log.info("compose", "%s: no build section, deploy only (image %s)" % (svc_name, spec["image_ref"]))
        else:
            spec["image_ref"] = raw.get("image") or "%s-%s" % (name, svc_name)
            if spec["opts"]["build"]:
                spec["build_kind"] = spec["opts"]["build"]
                spec["kind_source"] = "label"
                log.info("compose", "%s: tilt-build=%s" % (svc_name, spec["build_kind"]))
            else:
                spec["build_kind"] = settings["default_build_kind"]
                spec["kind_source"] = "default"
                log.info("compose", "%s: no tilt-build label, using '%s' by default" % (svc_name, spec["build_kind"]))
        services[svc_name] = spec
        order.append(svc_name)
    log.info("compose", "project '%s': %d services from %s" % (name, len(order), ", ".join(files)))
    return {"name": name, "dir": compose_dir, "files": files, "services": services, "order": order}

def build_override(ctx):
    """Returns the override compose dict that docker_compose() merges last."""
    out = {}
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        res = ctx["results"].get(name)
        svc = {}
        if spec["build_kind"] not in ["none", "compose"]:
            svc["image"] = spec["image_ref"]
        if res:
            patch = res["compose_patch"]
            if patch["volumes"]:
                svc["volumes"] = patch["volumes"]
            if patch["environment"]:
                svc["environment"] = patch["environment"]
        if svc:
            out[name] = svc
    return {"services": out}

def register_resources(ctx):
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        opts = spec["opts"]
        res = ctx["results"].get(name)
        deps = list(opts["resource_deps"])
        if res:
            deps = deps + res["resource_deps"]
        dc_resource(
            name,
            labels = opts["group"] or [spec["build_kind"]],
            trigger_mode = TRIGGER_MODE_MANUAL if opts["trigger"] == "manual" else TRIGGER_MODE_AUTO,
            auto_init = opts["auto_start"],
            links = opts["links"],
            resource_deps = deps,
        )
