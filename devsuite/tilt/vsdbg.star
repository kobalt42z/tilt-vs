# Offline vsdbg mounting for dotnet containers.
#
# Owner: task C (vsdbg offline). See docs/vsdbg.md and docs/plan/PLAN.md section 6.
#   attach(ctx, spec) -> BuildResult whose compose_patch mounts the
#   pre-extracted vsdbg for the container RID (read-only) at every path
#   Visual Studio probes, with the marker files GetVsDbg.sh writes so VS
#   skips the download:
#     /remote_debugger                     (VS F5 container tools)
#     <home>/.vs-debugger/<key>            (Attach to Process > Docker), per key and home
#   The drop is produced once on a connected machine by
#   devsuite/vsdbg/Get-VsDbgOffline.ps1 (or .sh): <drop_dir>/<key>/<rid>/.
#
# Settings (devsuite.json "vsdbg" section, all optional):
#   drop_dir             "devsuite/vsdbg/drop"   relative to the root Tiltfile, or absolute
#   keys                 ["vs2022", "vs2026"]    VS version keys mounted under ~/.vs-debugger
#   remote_debugger_key  "vs2026"                key whose build is mounted at /remote_debugger
#   user_homes           ["/root", "/home/app"]  default homes (label tilt-debugger-user-home overrides)
#   default_rid          "linux-x64"             RID when the base image says nothing (glibc)
# Labels: tilt-debugger (main.star skips attach when false), tilt-debugger-rid,
#         tilt-debugger-user-home (comma list allowed).

load("./contracts.star", "new_result")
load("./log.star", "log")

DEFAULTS = {
    "drop_dir": "devsuite/vsdbg/drop",
    "keys": ["vs2022", "vs2026"],
    "remote_debugger_key": "vs2026",
    "user_homes": ["/root", "/home/app"],
    "default_rid": "linux-x64",
}

REMOTE_DEBUGGER = "/remote_debugger"

def vsdbg_settings(settings):
    out = dict(DEFAULTS)
    out.update(settings.get("vsdbg") or {})
    return out

def _drop_dir(ctx, s):
    d = s["drop_dir"]
    if not d.startswith("/") and not (len(d) > 1 and d[1] == ":"):
        d = os.path.join(ctx["root"], d)
    return os.path.abspath(d)

def _from_lines(dockerfile):
    """[(image, stage_name)] for every FROM line of the Dockerfile."""
    out = []
    for raw in str(read_file(dockerfile)).splitlines():
        parts = raw.strip().split()
        if len(parts) < 2 or parts[0].upper() != "FROM":
            continue
        args = [p for p in parts[1:] if not p.startswith("--")]  # drop --platform=...
        if not args:
            continue
        name = ""
        if len(args) >= 3 and args[1].upper() == "AS":
            name = args[2].lower()
        out.append((args[0], name))
    return out

def base_image(dockerfile, target):
    """Base image of the final stage (or `target`), following stage aliases."""
    froms = _from_lines(dockerfile)
    if not froms:
        return ""
    stages = {name: image for image, name in froms if name}
    image = stages.get(target.lower(), froms[-1][0]) if target else froms[-1][0]
    for _ in range(len(froms)):
        if image.lower() not in stages:
            break
        image = stages[image.lower()]
    return image

def detect_rid(spec, s):
    """(rid, why): label > base image name > default."""
    if spec["opts"].get("debugger_rid"):
        return spec["opts"]["debugger_rid"], "label tilt-debugger-rid"
    b = spec["build"] or {}
    image = ""
    if b.get("dockerfile") and os.path.exists(b["dockerfile"]):
        image = base_image(b["dockerfile"], b.get("target", ""))
    img = image.lower()
    if not img:
        return s["default_rid"], "default (no base image found)"
    arch = "arm64" if ("arm64" in img or "aarch64" in img) else s["default_rid"].split("-")[-1]
    libc = "linux-musl-" if "alpine" in img else "linux-"
    return libc + arch, "base image %s" % image

def _homes(spec, s):
    label = spec["opts"].get("debugger_user_home")
    if label:
        return [h.strip().rstrip("/") or "/" for h in label.split(",") if h.strip()]
    return list(s["user_homes"])

def _missing(name, path, key, rid):
    log.fatal("vsdbg", "\n".join([
        "%s: vsdbg drop missing: %s (key %s, rid %s)." % (name, path, key, rid),
        "  Package it once on a connected machine and commit it (Git LFS):",
        "    pwsh devsuite/vsdbg/Get-VsDbgOffline.ps1 -Version %s -RuntimeId %s" % (key, rid),
        "    sh   devsuite/vsdbg/Get-VsDbgOffline.sh -v %s -r %s" % (key, rid),
        "  Or skip the debugger: label tilt-debugger: \"false\" on the service, or `tilt up -- --no-debugger`.",
        "  See docs/vsdbg.md.",
    ]))

def _check(name, drop, key, rid):
    d = os.path.join(drop, key, rid)
    if not os.path.exists(os.path.join(d, "vsdbg")):
        _missing(name, d, key, rid)
    marker = os.path.join(d, "success_version.txt")
    if not os.path.exists(marker):
        _missing(name, marker, key, rid)
    return d, str(read_file(marker)).strip()

def attach(ctx, spec):
    s = vsdbg_settings(ctx["settings"])
    name = spec["name"]
    drop = _drop_dir(ctx, s)
    rid, why = detect_rid(spec, s)
    keys = list(s["keys"])
    if s["remote_debugger_key"] and s["remote_debugger_key"] not in keys:
        keys.append(s["remote_debugger_key"])

    dirs = {}
    versions = {}
    for key in keys:
        dirs[key], versions[key] = _check(name, drop, key, rid)

    def bind(source, target):
        return {"type": "bind", "source": source, "target": target, "read_only": True}

    r = new_result()
    vols = r["compose_patch"]["volumes"]
    if s["remote_debugger_key"]:
        vols.append(bind(dirs[s["remote_debugger_key"]], REMOTE_DEBUGGER))
    homes = _homes(spec, s)
    for home in homes:
        for key in s["keys"]:
            vols.append(bind(dirs[key], "%s/.vs-debugger/%s" % ("" if home == "/" else home, key)))

    log.info("vsdbg", "%s: rid %s (%s), %d read-only mounts from %s" % (name, rid, why, len(vols), drop))
    for v in vols:
        log.debug("vsdbg", "%s:   %s -> %s" % (name, v["source"], v["target"]))
    r["notes"].append("vsdbg %s %s" % (rid, ", ".join(["%s=%s" % (k, versions[k]) for k in keys])))
    return r
