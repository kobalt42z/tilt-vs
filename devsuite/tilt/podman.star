# Podman (Hyper-V machine) integration.
#
# Owner: task E (podman / hyper-v).
# Target behaviour (docs/plan/PLAN.md section 7):
#   preflight(settings): verify the engine answers (DOCKER_HOST / named pipe),
#     log engine + compose versions, set DOCKER_BUILDKIT=0 when the engine is
#     Podman, fail with a fix-it message otherwise.
#   translate(ctx, override): rewrite bind-mount sources (Windows paths) to
#     the path the Podman machine sees, for both the original compose volumes
#     and devsuite-added ones (same target => override replaces).
#
# SKELETON: no-ops.

load("./log.star", "log")

def preflight(settings):
    log.debug("podman", "preflight not implemented yet")

def translate(ctx, override):
    return override
