# Tiltfile.extend support.
#
# Owner: task D (extend + docker/custom kinds).
# Target behaviour (docs/plan/PLAN.md section 4):
#   - custom(ctx, spec): nothing is registered for the service; records that
#     Tiltfile.extend must provide a build for spec["image_ref"].
#   - run(ctx): if <extend_file> exists, load_dynamic() it (top-level Tilt
#     calls run as-is), then call its extend(ctx) function if defined.
#     Afterwards warn for custom services the extend did not claim.
#
# SKELETON: loads the file and calls extend(ctx) if present.

load("./contracts.star", "new_result")
load("./log.star", "log")

def custom(ctx, spec):
    log.info("extend", "%s: tilt-build=custom, build expected from %s" % (spec["name"], ctx["settings"]["extend_file"]))
    return new_result()

def run(ctx):
    path = os.path.join(ctx["root"], ctx["settings"]["extend_file"])
    if not os.path.exists(path):
        log.debug("extend", "%s not found, nothing to merge" % path)
        return
    log.info("extend", "merging %s" % path)
    symbols = load_dynamic(path)
    if "extend" in symbols:
        symbols["extend"](ctx)
