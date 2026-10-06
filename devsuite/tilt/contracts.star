# Shared data contracts between devsuite modules.
#
# Owner: integration. Parallel tasks may ADD keys (additive only) but must not
# rename or remove existing ones. See docs/plan/PLAN.md "Contracts".

# ---------------------------------------------------------------------------
# Label schema. Every label a docker-compose service can carry.
#   key      : compose label name
#   opt      : key in ServiceSpec["opts"]
#   type     : "enum" | "bool" | "string" | "list" (comma separated)
#   default  : value when the label is absent (None = computed by the owner)
#   owner    : module that consumes it
# labels.star (task A) parses and validates against this table.
# ---------------------------------------------------------------------------
LABELS = [
    # --- requested by the user -------------------------------------------
    {"key": "tilt-build", "opt": "build", "type": "enum",
     "values": ["dotnet", "custom", "docker", "compose"], "default": None, "owner": "labels"},
    {"key": "tilt-skip-build-layer", "opt": "skip_build_layer", "type": "bool",
     "default": False, "owner": "dotnet"},
    # --- proposed: .NET build ---------------------------------------------
    {"key": "tilt-project", "opt": "project", "type": "string",
     "default": None, "owner": "dotnet"},
    {"key": "tilt-configuration", "opt": "configuration", "type": "string",
     "default": "Debug", "owner": "dotnet"},
    {"key": "tilt-app-path", "opt": "app_path", "type": "string",
     "default": None, "owner": "dotnet"},
    {"key": "tilt-publish-args", "opt": "publish_args", "type": "string",
     "default": "", "owner": "dotnet"},
    {"key": "tilt-live-update", "opt": "live_update", "type": "bool",
     "default": True, "owner": "dotnet"},
    # --- proposed: change detection ---------------------------------------
    {"key": "tilt-watch", "opt": "watch", "type": "list",
     "default": [], "owner": "dotnet"},
    {"key": "tilt-ignore", "opt": "ignore", "type": "list",
     "default": [], "owner": "dotnet"},
    # --- proposed: debugger -----------------------------------------------
    {"key": "tilt-debugger", "opt": "debugger", "type": "bool",
     "default": True, "owner": "vsdbg"},
    {"key": "tilt-debugger-rid", "opt": "debugger_rid", "type": "enum",
     "values": ["linux-x64", "linux-musl-x64", "linux-arm64", "linux-musl-arm64"],
     "default": None, "owner": "vsdbg"},
    {"key": "tilt-debugger-user-home", "opt": "debugger_user_home", "type": "string",
     "default": None, "owner": "vsdbg"},
    # --- proposed: Tilt UI / lifecycle ------------------------------------
    {"key": "tilt-group", "opt": "group", "type": "list",
     "default": [], "owner": "compose"},
    {"key": "tilt-trigger", "opt": "trigger", "type": "enum",
     "values": ["auto", "manual"], "default": "auto", "owner": "compose"},
    {"key": "tilt-auto-start", "opt": "auto_start", "type": "bool",
     "default": True, "owner": "compose"},
    {"key": "tilt-links", "opt": "links", "type": "list",
     "default": [], "owner": "compose"},
    {"key": "tilt-resource-deps", "opt": "resource_deps", "type": "list",
     "default": [], "owner": "compose"},
]

BUILD_KINDS = ["dotnet", "custom", "docker", "compose", "none"]

# ---------------------------------------------------------------------------
# ServiceSpec: one per compose service, produced by compose.star (task A).
# ---------------------------------------------------------------------------
def new_service_spec(name, raw, compose_dir):
    return {
        "name": name,                 # compose service name == Tilt resource name
        "raw": raw,                   # normalized compose service dict
        "compose_dir": compose_dir,   # absolute dir of the first compose file
        "image_ref": "",              # image ref Tilt builds and compose runs
        "build": None,                # None or {"context","dockerfile","target","args"} (absolute paths)
        "build_kind": "none",         # one of BUILD_KINDS
        "kind_source": "",            # "label" | "default" | "no-build" | "fallback"
        "labels": {},                 # raw compose labels (dict)
        "opts": {},                   # typed label values keyed by LABELS[*].opt
    }

# ---------------------------------------------------------------------------
# BuildResult: what each builder/attacher returns for a service.
# compose.star merges compose_patch into the generated override file.
# ---------------------------------------------------------------------------
def new_result():
    return {
        "resources": [],       # extra Tilt resources created (e.g. "orders-api-dotnet")
        "resource_deps": [],   # deps the compose resource must wait for
        "image_registered": False,  # True when docker_build/custom_build was registered for image_ref
        "compose_patch": {
            "volumes": [],     # compose long-syntax volume dicts {"type","source","target","read_only"}
            "environment": {}, # extra env vars
        },
        "notes": [],           # one-line facts for the summary table
    }

def merge_results(a, b):
    out = new_result()
    for r in [a, b]:
        out["resources"] = out["resources"] + r.get("resources", [])
        out["resource_deps"] = out["resource_deps"] + r.get("resource_deps", [])
        out["image_registered"] = out["image_registered"] or r.get("image_registered", False)
        p = r.get("compose_patch", {})
        out["compose_patch"]["volumes"] = out["compose_patch"]["volumes"] + p.get("volumes", [])
        out["compose_patch"]["environment"].update(p.get("environment", {}))
        out["notes"] = out["notes"] + r.get("notes", [])
    return out

# ---------------------------------------------------------------------------
# Context: passed to every module and to Tiltfile.extend's extend(ctx).
# ---------------------------------------------------------------------------
def new_context(settings, project):
    return {
        "settings": settings,         # merged settings dict (settings.star)
        "project": project,           # {"name","dir","files","services","order"} (compose.star)
        "results": {},                # service name -> BuildResult
        "root": config.main_dir,      # absolute dir of the root Tiltfile
    }
