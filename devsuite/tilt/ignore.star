# File-watch ignore rules for .NET projects.
#
# Owner: task B.
# Target API:
#   dotnet_ignores(spec) -> list of globs for local_resource/docker_build ignore=
#   (bin/, obj/, .vs/, *.user, TestResults/, node_modules/, .git/, the devsuite
#    work_dir, plus tilt-ignore label values)
#
# Additions (task B):
#   DOTNET_IGNORES               the shared glob list (also shipped as /.tiltignore)
#   dotnet_ignores(spec, bases=[], work_dir="") -> absolute patterns for each base
#   global_ignores(work_dir)     -> watch_settings() patterns for devsuite scratch dirs
#
# Patterns are dockerignore syntax. Folders are listed twice ("**/bin" and
# "**/bin/**"): the first catches the event for creating the folder itself.
# Tilt resolves relative patterns against the directory of the .star file that
# registers the resource, so everything returned here is absolute (one copy per
# watched base directory).

DOTNET_IGNORES = [
    "**/bin",
    "**/bin/**",
    "**/obj",
    "**/obj/**",
    "**/.vs",
    "**/.vs/**",
    "**/*.user",
    "**/*.suo",
    "**/TestResults",
    "**/TestResults/**",
    "**/node_modules",
    "**/node_modules/**",
    "**/.git",
    "**/.git/**",
    "**/.idea",
    "**/.idea/**",
    "**/*.md",
    "**/*.swp",
    "**/~*",
    "**/*.tmp",
    "**/Properties/launchSettings.json",
    # Note: wwwroot/** and appsettings*.json are deliberately NOT ignored.
]

def _join(base, pattern):
    return base.rstrip("/\\") + "/" + pattern

def dotnet_ignores(spec, bases = [], work_dir = ""):
    """Absolute ignore patterns for a dotnet service.

    spec:     ServiceSpec (tilt-ignore label values are relative to the compose dir)
    bases:    absolute dirs the resource watches (project + reference dirs)
    work_dir: absolute devsuite work dir, ignored entirely
    """
    out = []
    for base in bases:
        for p in DOTNET_IGNORES:
            out.append(_join(base, p))
    for p in (spec["opts"].get("ignore") or []):
        p = p.replace("\\", "/")
        if p.startswith("/") or (len(p) > 1 and p[1] == ":"):
            out.append(p)
        else:
            out.append(_join(spec["compose_dir"], p))
    if work_dir:
        out.append(_join(work_dir, "**"))
    return out

def global_ignores(work_dir):
    """devsuite scratch dirs no resource should ever react to: intermediate
    build output and publish staging (the publish/ folder itself stays watched,
    it is what live_update syncs)."""
    return [
        _join(work_dir, "artifacts/**"),
        _join(work_dir, "staging/**"),
    ]
