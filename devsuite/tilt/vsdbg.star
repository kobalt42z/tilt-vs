# Offline vsdbg mounting for dotnet containers.
#
# Owner: task C (vsdbg offline).
# Target behaviour (docs/plan/PLAN.md section 6):
#   attach(ctx, spec) -> BuildResult whose compose_patch mounts the
#   pre-extracted vsdbg for the container RID (read-only) at every path
#   Visual Studio probes, with the marker files GetVsDbg.sh writes so VS
#   skips the download.
#
# SKELETON: logs and returns an empty result.

load("./contracts.star", "new_result")
load("./log.star", "log")

def attach(ctx, spec):
    log.debug("vsdbg", "%s: vsdbg mount not implemented yet" % spec["name"])
    return new_result()
