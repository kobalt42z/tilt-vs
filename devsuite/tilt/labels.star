# Label parsing: compose labels -> typed ServiceSpec["opts"].
#
# Owner: task A (compose + labels).
# SKELETON: minimal happy-path parsing so the pipeline runs end to end.
# Task A hardens it: validation against LABELS[*].values, unknown "tilt-*"
# label warnings, list-form labels, bool spellings, clear error messages.

load("./contracts.star", "LABELS")
load("./log.star", "log")

def normalize_labels(raw_labels):
    """Compose allows labels as a dict or a list of "k=v" strings."""
    if raw_labels == None:
        return {}
    if type(raw_labels) == "dict":
        return {k: str(v) for k, v in raw_labels.items()}
    out = {}
    for item in raw_labels:
        k, _, v = str(item).partition("=")
        out[k] = v
    return out

def _parse(entry, value):
    t = entry["type"]
    if t == "bool":
        return value.strip().lower() in ["true", "1", "yes", "on"]
    if t == "list":
        return [x.strip() for x in value.split(",") if x.strip()]
    return value.strip()

def parse_opts(service_name, labels):
    opts = {}
    for entry in LABELS:
        if entry["key"] in labels:
            opts[entry["opt"]] = _parse(entry, labels[entry["key"]])
        else:
            opts[entry["opt"]] = entry["default"]
    return opts
