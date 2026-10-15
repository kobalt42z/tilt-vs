# Test harness for compose.star / labels.star fixtures.
#
# Each case directory has a Tiltfile that loads this file and calls run().
# run() executes the compose half of main.star (settings -> load_project ->
# build_override -> docker_compose -> register_resources) without the build
# modules, then prints the model on one "DEVSUITE_MODEL <json>" line that
# run.sh extracts for `model` assertions.

load("../../settings.star", "load_settings")
load("../../contracts.star", "new_context", "new_result")
load("../../compose.star", "load_project", "build_override", "register_resources")

def _strip(spec):
    # raw is large and engine-specific; tests assert on the typed fields.
    return {k: v for k, v in spec.items() if k != "raw"}

def run(results = None):
    """results: optional {service: partial BuildResult} to exercise the override."""
    settings = load_settings()
    project = load_project(settings)
    ctx = new_context(settings, project)
    for name, partial in (results or {}).items():
        r = new_result()
        r.update(partial)
        ctx["results"][name] = r
    override = build_override(ctx)
    docker_compose(project["files"] + [encode_yaml(override)], project_name = project["name"])
    register_resources(ctx)
    model = {
        "name": project["name"],
        "source": project["source"],
        "order": project["order"],
        "services": {n: _strip(s) for n, s in project["services"].items()},
        "override": override,
    }
    print("DEVSUITE_MODEL " + encode_json(model).replace("\n", ""))
    return ctx
