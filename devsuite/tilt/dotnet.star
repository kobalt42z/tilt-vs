# .NET build pipeline for services with tilt-build=dotnet.
#
# Owner: task B (dotnet build + skip build layer + change detection).
# Target behaviour (see docs/plan/PLAN.md section 5):
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
# SKELETON: plain docker_build of the service Dockerfile, no local build.

load("./contracts.star", "new_result")
load("./log.star", "log")

def register(ctx, spec):
    b = spec["build"]
    log.warn("dotnet", "%s: dotnet pipeline not implemented yet, building Dockerfile as-is" % spec["name"])
    docker_build(
        spec["image_ref"],
        b["context"],
        dockerfile = b["dockerfile"],
        target = b["target"],
        build_args = b["args"],
    )
    r = new_result()
    r["image_registered"] = True
    r["notes"].append("skeleton docker_build")
    return r
