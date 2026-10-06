# tilt-build=docker: Tilt builds the service Dockerfile as-is (no local
# .NET build). For non-.NET services that still want Tilt-managed rebuilds.
#
# Owner: task D (extend + docker/custom kinds).

load("./contracts.star", "new_result")
load("./log.star", "log")

def register(ctx, spec):
    b = spec["build"]
    log.info("docker", "%s: docker_build %s (context %s)" % (spec["name"], b["dockerfile"], b["context"]))
    docker_build(
        spec["image_ref"],
        b["context"],
        dockerfile = b["dockerfile"],
        target = b["target"],
        build_args = b["args"],
    )
    r = new_result()
    r["image_registered"] = True
    return r
