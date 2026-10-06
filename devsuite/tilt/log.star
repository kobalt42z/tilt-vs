# devsuite logging helpers.
#
# Every devsuite module logs through these functions so the Tilt UI
# ("Tiltfile" resource log) shows one consistent, greppable format:
#
#   [devsuite] INFO  compose   | found 4 services in docker-compose.yml
#
# Level comes from the DEVSUITE_LOG_LEVEL environment variable
# (debug | info | warn), default "info". Errors always stop the Tiltfile.
#
# Owner: integration (shared contract). Do not change signatures.

_LEVELS = {"debug": 10, "info": 20, "warn": 30}
_LEVEL = _LEVELS.get(os.getenv("DEVSUITE_LOG_LEVEL", "info").lower(), 20)

def pad(s, n):
    """Left-justify s to n chars (Starlark has no %-Ns formatting)."""
    s = str(s)
    return s + " " * (n - len(s)) if len(s) < n else s

def _fmt(level, scope, msg):
    return "[devsuite] %s %s | %s" % (pad(level, 5), pad(scope, 9), msg)

def debug(scope, msg):
    if _LEVEL <= 10:
        print(_fmt("DEBUG", scope, msg))

def info(scope, msg):
    if _LEVEL <= 20:
        print(_fmt("INFO", scope, msg))

def warning(scope, msg):
    # Tilt's warn() also surfaces the message as a warning badge in the UI.
    warn(_fmt("WARN", scope, msg))

def fatal(scope, msg):
    fail(_fmt("ERROR", scope, msg))

def section(title):
    if _LEVEL <= 20:
        print("[devsuite] ---------- %s ----------" % title)

log = struct(
    pad = pad,
    debug = debug,
    info = info,
    warn = warning,
    fatal = fatal,
    section = section,
)
