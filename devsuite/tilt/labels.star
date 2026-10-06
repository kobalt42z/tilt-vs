# Label parsing: compose labels -> typed ServiceSpec["opts"].
#
# Owner: task A (compose + labels).
# Source of truth for the schema is LABELS in contracts.star; this module only
# interprets it:
#   normalize_labels(raw)            dict or ["k=v", "k"] list -> {k: "v"}
#   parse_opts(service_name, labels) typed opts for every LABELS entry
#                                    (default when absent), validated:
#     * unknown "tilt-*" label      -> warning (with a "did you mean" hint)
#     * bad enum / bool value       -> fatal error naming service + label
#     * bad tilt-group value        -> fatal (Tilt UI labels are restricted)
# See docs/compose.md for the user-facing reference.

load("./contracts.star", "LABELS")
load("./log.star", "log")

_PREFIX = "tilt-"
_TRUE = ["true", "1", "yes", "on"]
_FALSE = ["false", "0", "no", "off", ""]
_BY_KEY = {e["key"]: e for e in LABELS}

def _label_str(v):
    # YAML dict form may give bools/numbers/null; compose turns them into strings.
    if v == None:
        return ""
    if type(v) == "bool":
        return "true" if v else "false"
    return str(v)

def normalize_labels(raw_labels):
    """Compose allows labels as a dict or a list of "k=v" (or bare "k") strings."""
    if raw_labels == None:
        return {}
    if type(raw_labels) == "dict":
        return {str(k).strip(): _label_str(v) for k, v in raw_labels.items()}
    out = {}
    for item in raw_labels:
        k, _, v = str(item).partition("=")
        out[k.strip()] = v
    return out

def _distance(a, b):
    # Levenshtein distance, only used for "did you mean" hints on short keys.
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[len(b)]

def _suggest(key):
    best = None
    best_d = 4  # beyond 3 edits a suggestion is noise
    for known in _BY_KEY.keys():
        d = _distance(key, known)
        if d < best_d:
            best, best_d = known, d
    return best

def _is_ui_label(s):
    # Tilt resource labels follow Kubernetes label-name rules:
    # 1..63 chars of [A-Za-z0-9-_.], starting and ending alphanumeric.
    if len(s) == 0 or len(s) > 63:
        return False
    if not (s[0].isalnum() and s[-1].isalnum()):
        return False
    for ch in s.elems():
        if not (ch.isalnum() or ch in "-_."):
            return False
    return True

def _bad(service_name, key, value, expected):
    log.fatal("labels", "service '%s': label %s=%r is invalid, expected %s" % (
        service_name, key, value, expected))

def _parse(service_name, entry, value):
    t = entry["type"]
    v = value.strip()
    if t == "bool":
        if v.lower() in _TRUE:
            return True
        if v.lower() in _FALSE:
            return False
        _bad(service_name, entry["key"], value, "true or false")
    if t == "enum":
        if v.lower() not in entry["values"]:
            _bad(service_name, entry["key"], value, "one of " + " | ".join(entry["values"]))
        return v.lower()
    if t == "list":
        return [x.strip() for x in v.split(",") if x.strip()]
    if v == "":
        return entry["default"]
    return v

def parse_opts(service_name, labels):
    for key in sorted(labels.keys()):
        if key.lower().startswith(_PREFIX) and key not in _BY_KEY:
            hint = _suggest(key.lower())
            log.warn("labels", "service '%s': unknown label '%s' ignored%s" % (
                service_name, key, " (did you mean '%s'?)" % hint if hint else ""))
    opts = {}
    for entry in LABELS:
        if entry["key"] in labels:
            opts[entry["opt"]] = _parse(service_name, entry, labels[entry["key"]])
            log.debug("labels", "%s: %s=%s" % (service_name, entry["key"], opts[entry["opt"]]))
        else:
            d = entry["default"]
            opts[entry["opt"]] = list(d) if type(d) == "list" else d
    for g in opts.get("group") or []:
        if not _is_ui_label(g):
            _bad(service_name, "tilt-group", g,
                 "names of letters, digits, '-', '_' or '.' (max 63 chars, alphanumeric at both ends)")
    return opts
