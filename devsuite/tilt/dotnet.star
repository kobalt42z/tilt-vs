# .NET build pipeline for services with tilt-build=dotnet.
#
# Owner: task B (dotnet build + skip build layer + change detection).
# Target behaviour (see docs/plan/PLAN.md section 5, user docs in docs/dotnet.md):
#   - find the .csproj next to the Dockerfile (or tilt-project label)
#   - local_resource "<svc>-dotnet": dotnet publish -c Debug into
#     <work_dir>/publish/<svc>, deps = project dir + ProjectReference dirs,
#     ignores from ignore.star
#   - docker_build(image_ref, ...) with
#       * tilt-skip-build-layer=true  -> derived Dockerfile (dockerfile.star)
#         whose final stage COPYs the local publish output
#       * otherwise                    -> original Dockerfile, build arg
#         BUILD_CONFIGURATION=<configuration>
#     live_update = [sync(publish dir, app_path), restart_container()]
#   - returns BuildResult with resource_deps=["<svc>-dotnet"]
#
# Image registration, by case:
#   skip build layer, live update  docker_build(rewritten Dockerfile, only=publish dir
#                                  + files the runtime stage copies) + live_update
#   skip build layer, no live upd. same docker_build, no live_update: a publish
#                                  rebuilds the (runtime-only, cheap) image
#   full build, live update        custom_build(`<build_cli> build` of the original
#                                  Dockerfile, deps=[Dockerfile, publish dir]) + live_update.
#                                  docker_build would watch the whole source context,
#                                  so every .cs edit would rebuild the SDK image.
#   full build, no live update     docker_build(original Dockerfile), no local publish

load("./contracts.star", "new_result")
load("./log.star", "log")
load("./ignore.star", "dotnet_ignores", "global_ignores")
load("./dockerfile.star", "build_copies", "rewrite", df_parse = "parse", df_app_path = "app_path")
load("./docker.star", docker_register = "register")

# settings["dotnet"] keys (devsuite.json / devsuite.local.json)
DEFAULTS = {
    # put obj/ and bin/ under <work_dir>/artifacts/<svc> (dotnet --artifacts-path)
    # so Tilt's publish never contends with Visual Studio for obj/
    "isolate_intermediates": True,
    # CLI used by custom_build for full-build images ("docker" or "podman")
    "build_cli": "docker",
    # extra `dotnet publish` args for every service (tilt-publish-args adds per service)
    "publish_args": "",
}

# MSBuild / NuGet / SDK files that change the build when edited anywhere up the tree
MSBUILD_FILES = [
    "Directory.Build.props",
    "Directory.Build.targets",
    "Directory.Build.rsp",
    "Directory.Packages.props",
    "NuGet.Config",
    "nuget.config",
    "NuGet.config",
    "global.json",
]

_SEP = os.path.join("a", "b")[1]

# devsuite/dotnet/publish.{sh,ps1}; relative paths resolve against this file's dir
_SCRIPT_DIR = os.path.abspath("../dotnet")

def _settings(ctx):
    s = dict(DEFAULTS)
    s.update(ctx["settings"].get("dotnet") or {})
    return s

def _norm(p):
    return os.path.abspath(p.replace("\\", "/") if _SEP == "/" else p)

def _is_under(parent, child):
    return child == parent or child.startswith(parent.rstrip(_SEP) + _SEP)

def _common_dir(a, b):
    cand = a
    for _ in range(128):
        if _is_under(cand, b):
            return cand
        parent = os.path.dirname(cand)
        if parent == cand:
            break
        cand = parent
    return cand

def _slash(p):
    return p.replace("\\", "/")

def _csprojs_in(d):
    if not os.path.exists(d):
        return []
    return sorted([f for f in listdir(d) if f.lower().endswith(".csproj")])

def find_project(spec):
    """-> (absolute csproj path or None, reason)."""
    ddir = os.path.dirname(spec["build"]["dockerfile"])
    override = spec["opts"].get("project")
    if override:
        p = _norm(os.path.join(ddir, override))
        if p.lower().endswith(".csproj"):
            if os.path.exists(p):
                return p, "tilt-project"
            return None, "tilt-project %s not found" % p
        found = _csprojs_in(p)
        if len(found) == 1:
            return found[0], "tilt-project dir"
        return None, "tilt-project dir %s has %d csproj files" % (p, len(found))
    found = _csprojs_in(ddir)
    if len(found) == 1:
        return found[0], "next to Dockerfile"
    if not found:
        return None, "no *.csproj next to %s (set tilt-project)" % spec["build"]["dockerfile"]
    return None, "%d *.csproj next to the Dockerfile (%s); set tilt-project" % (
        len(found), ", ".join([os.path.basename(f) for f in found]))

def _project_refs(csproj):
    """ProjectReference Include paths of one csproj, absolute."""
    text = str(read_file(csproj))
    out = []
    base = os.path.dirname(csproj)
    for chunk in text.split("<ProjectReference")[1:]:
        tag = chunk.partition(">")[0]
        for q in ["\"", "'"]:
            key = "Include=" + q
            if key in tag:
                inc = tag.partition(key)[2].partition(q)[0]
                inc = inc.replace("$(MSBuildThisFileDirectory)", "").replace("$(MSBuildProjectDirectory)", "")
                inc = inc.replace("\\", "/")
                if inc:
                    out.append(_norm(os.path.join(base, inc)))
                break
    return out

def project_closure(csproj):
    """The project and all transitive ProjectReferences (absolute csproj paths)."""
    seen = {}
    order = []
    todo = [csproj]
    for _ in range(1000):
        if not todo:
            break
        p = todo.pop(0)
        if p in seen:
            continue
        seen[p] = True
        order.append(p)
        if not os.path.exists(p):
            log.warn("dotnet", "ProjectReference not found: %s" % p)
            continue
        todo.extend(_project_refs(p))
    return order

def _msbuild_inputs(dirs):
    found = {}
    for d in dirs:
        cur = d
        for _ in range(128):
            for name in MSBUILD_FILES:
                f = os.path.join(cur, name)
                if f not in found and os.path.exists(f):
                    found[f] = True
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    return sorted(found.keys())

def _quote_sh(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

def _quote_bat(s):
    return "\"" + s + "\""

def _build_args(spec, configuration):
    raw = spec["build"]["args"]
    args = {}
    if type(raw) == "dict":
        for k, v in raw.items():
            args[k] = "" if v == None else str(v)
    else:
        for item in raw:
            k, _, v = str(item).partition("=")
            args[k] = v
    if configuration:
        args["BUILD_CONFIGURATION"] = configuration
    return args

def register(ctx, spec):
    name = spec["name"]
    b = spec["build"]
    opts = spec["opts"]
    cli = ctx["settings"]["cli"]
    s = _settings(ctx)

    csproj, why = find_project(spec)
    if csproj == None:
        log.warn("dotnet", "%s: %s -> falling back to tilt-build=docker" % (name, why))
        spec["build_kind"] = "docker"
        spec["kind_source"] = "fallback"
        r = docker_register(ctx, spec)
        r["notes"].append("fallback to docker: " + why)
        return r

    configuration = opts.get("configuration") or "Debug"
    skip = bool(opts.get("skip_build_layer")) or cli["skip_build_layer"]
    live = opts.get("live_update") != False and not cli["no_live_update"]
    parsed = df_parse(b["dockerfile"])
    target = b["target"]
    if skip and not build_copies(parsed, target):
        log.warn("dotnet", "%s: tilt-skip-build-layer=true but the final stage of %s has no COPY --from=<.NET build stage>; building the Dockerfile as-is" % (name, b["dockerfile"]))
        skip = False

    app_path = opts.get("app_path") or df_app_path(parsed, target)
    if live and not app_path:
        log.fatal("dotnet", "%s: cannot infer where the app lives in the container from %s; set the tilt-app-path label" % (name, b["dockerfile"]))

    work = _norm(os.path.join(ctx["root"], ctx["settings"]["work_dir"]))
    publish_dir = os.path.join(work, "publish", name)
    staging_dir = os.path.join(work, "staging", name)
    artifacts_dir = os.path.join(work, "artifacts", name)
    watch_settings(ignore = global_ignores(work))

    r = new_result()
    r["image_registered"] = True
    r["notes"].append("project %s" % os.path.basename(csproj))
    labels = opts.get("group") or ["dotnet"]
    trigger_mode = TRIGGER_MODE_MANUAL if opts.get("trigger") == "manual" else TRIGGER_MODE_AUTO

    # ---- local build -----------------------------------------------------------
    if skip or live:
        projects = project_closure(csproj)
        dirs = [os.path.dirname(p) for p in projects]
        deps = list(dirs) + _msbuild_inputs(dirs)
        for w in (opts.get("watch") or []):
            deps.append(_norm(os.path.join(spec["compose_dir"], w)))
        publish_args = (s["publish_args"] + " " + (opts.get("publish_args") or "")).split()
        if s["isolate_intermediates"]:
            artifacts_arg = artifacts_dir
        else:
            artifacts_arg = ""
        script_dir = _SCRIPT_DIR
        sh_args = [csproj, configuration, staging_dir, publish_dir, artifacts_arg] + publish_args
        local_resource(
            name + "-dotnet",
            cmd = ["sh", os.path.join(script_dir, "publish.sh")] + sh_args,
            cmd_bat = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                       os.path.join(script_dir, "publish.ps1")] + sh_args,
            deps = deps,
            ignore = dotnet_ignores(spec, dirs, work),
            env = {"DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1"},
            labels = labels,
            trigger_mode = trigger_mode,
            allow_parallel = True,
        )
        r["resources"].append(name + "-dotnet")
        r["resource_deps"].append(name + "-dotnet")
        log.info("dotnet", "%s: %s-dotnet publishes %s (-c %s, %d project(s)) to %s" % (
            name, name, os.path.relpath(csproj, ctx["root"]), configuration, len(projects), os.path.relpath(publish_dir, ctx["root"])))
        log.debug("dotnet", "%s: watching %s" % (name, deps))

    lu = []
    if live:
        lu = [sync(publish_dir, app_path), restart_container()]
        r["notes"].append("live update -> %s" % app_path)
    else:
        r["notes"].append("no live update")

    # ---- image ---------------------------------------------------------------
    if skip:
        context = _common_dir(b["context"], publish_dir)
        publish_rel = _slash(os.path.relpath(publish_dir, context))
        prefix = _slash(os.path.relpath(b["context"], context))
        if prefix == ".":
            prefix = ""
        out = rewrite(parsed, target, publish_rel, prefix)
        only = [publish_rel]
        for p in out["context_paths"]:
            if "*" in p or "?" in p:
                p = p.partition("*")[0].partition("?")[0].rpartition("/")[0] or "."
            if p == "." or p == prefix:
                log.warn("dotnet", "%s: the runtime stage copies the whole build context; source edits will rebuild the image" % name)
            only.append(p)
        log.debug("dotnet", "%s: skip-build-layer Dockerfile (context %s):\n%s" % (name, context, out["text"]))
        docker_build(
            spec["image_ref"],
            context,
            dockerfile_contents = out["text"],
            only = only,
            build_args = _build_args(spec, ""),
            live_update = lu,
        )
        log.info("dotnet", "%s: skip build layer, image = runtime stage + %s (%d COPY rewritten)" % (name, publish_rel, out["replaced"]))
        r["notes"].append("skip build layer")
    elif live:
        args = _build_args(spec, configuration)
        bcli = s["build_cli"]
        sh = [bcli, "build", "-t", "$EXPECTED_REF", "-f", _quote_sh(b["dockerfile"])]
        bat = [bcli, "build", "-t", "%EXPECTED_REF%", "-f", _quote_bat(b["dockerfile"])]
        if target:
            sh += ["--target", _quote_sh(target)]
            bat += ["--target", _quote_bat(target)]
        for k in sorted(args.keys()):
            sh += ["--build-arg", _quote_sh("%s=%s" % (k, args[k]))]
            bat += ["--build-arg", _quote_bat("%s=%s" % (k, args[k]))]
        sh.append(_quote_sh(b["context"]))
        bat.append(_quote_bat(b["context"]))
        custom_build(
            spec["image_ref"],
            " ".join(sh),
            deps = [b["dockerfile"], publish_dir],
            command_bat = " ".join(bat),
            live_update = lu,
        )
        log.info("dotnet", "%s: full build (%s build, BUILD_CONFIGURATION=%s); source edits go through %s-dotnet + live update" % (name, bcli, configuration, name))
        r["notes"].append("full build via %s" % bcli)
    else:
        docker_build(
            spec["image_ref"],
            b["context"],
            dockerfile = b["dockerfile"],
            target = target,
            build_args = _build_args(spec, configuration),
        )
        log.info("dotnet", "%s: full build, BUILD_CONFIGURATION=%s, no live update (every change rebuilds the image)" % (name, configuration))
        r["notes"].append("full build")
    return r
