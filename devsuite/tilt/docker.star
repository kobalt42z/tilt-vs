# tilt-build=docker: Tilt builds the service Dockerfile as-is (no local
# .NET build). For non-.NET services that still want Tilt-managed rebuilds
# (Node, nginx, Go...). User docs: docs/extend.md.
#
# Owner: task D (extend + docker/custom kinds).
#
#   register(ctx, spec) -> BuildResult
#     docker_build(image_ref, context, dockerfile, target, build_args,
#                  ignore = tilt-ignore, pull = False)
#   pull=False keeps it air-gapped friendly: base images come from the local
#   engine store (podman load) or a registry mirror, never a forced pull.

load("./contracts.star", "new_result")
load("./log.star", "log")

def build_args(args):
    """Compose build.args (dict or ["K=V", "K"] list) -> {str: str} for docker_build.
    A key without a value takes it from the environment, like compose does."""
    out = {}
    if args == None:
        return out
    if type(args) == "dict":
        items = [(k, v) for k, v in args.items()]
    else:
        items = []
        for item in args:
            k, sep, v = str(item).partition("=")
            items.append((k, v if sep else None))
    for k, v in items:
        if v == None:
            v = os.getenv(k, "")
            if v == "":
                continue
        elif type(v) == "bool":
            v = "true" if v else "false"
        out[str(k)] = str(v)
    return out

def register(ctx, spec):
    b = spec["build"]
    name = spec["name"]
    if not os.path.exists(b["dockerfile"]):
        log.fatal("docker", "%s: tilt-build=docker but the Dockerfile does not exist: %s" % (name, b["dockerfile"]))
    kwargs = {
        "dockerfile": b["dockerfile"],
        "build_args": build_args(b["args"]),
        "pull": False,
    }
    if b["target"]:
        kwargs["target"] = b["target"]
    ignores = spec["opts"].get("ignore") or []
    if ignores:
        kwargs["ignore"] = ignores
    log.info("docker", "%s: docker_build %s from %s%s (pull=False)" % (
        name, spec["image_ref"], os.path.relpath(b["dockerfile"], ctx["root"]),
        " target %s" % b["target"] if b["target"] else ""))
    docker_build(spec["image_ref"], b["context"], **kwargs)
    r = new_result()
    r["image_registered"] = True
    r["notes"].append("docker_build as-is, pull=False")
    return r
