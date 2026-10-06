# devsuite orchestration. The root Tiltfile calls devsuite_up().
#
# Owner: integration. Parallel tasks implement the modules below; changes here
# are limited to small additive edits coordinated through the integration branch.

load("./log.star", "log")
load("./settings.star", "load_settings")
load("./contracts.star", "new_context", "new_result", "merge_results")
load("./compose.star", "load_project", "build_override", "register_resources")
load("./podman.star", podman_preflight = "preflight", podman_translate = "translate")
load("./dotnet.star", dotnet_register = "register")
load("./docker.star", docker_register = "register")
load("./extend.star", extend_custom = "custom", extend_run = "run")
load("./vsdbg.star", vsdbg_attach = "attach")

def _summary(ctx):
    log.section("summary")
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        res = ctx["results"].get(name) or new_result()
        log.info("summary", "%s kind=%s (%s) image=%s %s" % (
            log.pad(name, 24), log.pad(spec["build_kind"], 7), spec["kind_source"], spec["image_ref"] or "-",
            "; ".join(res["notes"])))

def devsuite_up():
    log.section("devsuite")
    settings = load_settings()
    podman_preflight(settings)

    project = load_project(settings)
    ctx = new_context(settings, project)

    for name in project["order"]:
        spec = project["services"][name]
        kind = spec["build_kind"]
        if kind == "dotnet":
            res = dotnet_register(ctx, spec)
        elif kind == "docker":
            res = docker_register(ctx, spec)
        elif kind == "custom":
            res = extend_custom(ctx, spec)
        else:
            res = new_result()  # "none" (deploy only) or "compose" (compose builds it)
        # re-read: dotnet_register may fall back to "docker" (no single csproj)
        if spec["build_kind"] == "dotnet" and spec["opts"]["debugger"] and not settings["cli"]["no_debugger"]:
            res = merge_results(res, vsdbg_attach(ctx, spec))
        ctx["results"][name] = res

    override = podman_translate(ctx, build_override(ctx))
    log.debug("compose", "generated override: %s" % override)
    docker_compose(project["files"] + [encode_yaml(override)], project_name = project["name"])
    register_resources(ctx)

    extend_run(ctx)

    if settings["cli"]["services"]:
        config.set_enabled_resources(settings["cli"]["services"])
    _summary(ctx)
    return ctx
