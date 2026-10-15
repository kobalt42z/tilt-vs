# Tiltfile.extend support.
#
# Owner: task D (extend + docker/custom kinds). User docs: docs/extend.md.
#
#   custom(ctx, spec): devsuite registers nothing for the service; the build is
#     expected from Tiltfile.extend (or, if nobody builds it, from compose).
#   run(ctx): if <extend_file> exists:
#     1. pre-scan its source for docker_build()/custom_build() calls and resolve
#        their image refs where possible (string literals, simple variables,
#        ctx["project"]["services"][<name>]["image_ref"] chains). A ref devsuite
#        already builds fails here with a readable message instead of Tilt's
#        "Image for ref ... has already been defined".
#     2. load_dynamic() it: top-level Tilt calls register globally.
#     3. call its extend(ctx) if defined. ctx gains helpers for that call:
#          ctx["docker_build"](service, context = None, **kwargs)
#          ctx["custom_build"](service, command, deps, **kwargs)
#          ctx["claim"](service)   # "I build it some other way"
#          ctx["log"]              # devsuite log struct (log.info("scope", "msg"))
#     4. warn for every custom service whose image nobody built (compose
#        then builds it, PLAN §11 q5).
#
# State lives in ctx["extend"] (module globals are frozen after load).

load("./contracts.star", "new_result")
load("./log.star", "log")

_BUILD_FUNCS = ["docker_build", "custom_build"]

def _state(ctx):
    if "extend" not in ctx:
        ctx["extend"] = {
            "path": "",
            "custom": [],      # custom service names, in compose order
            "claimed": {},     # service name -> how it was claimed
            "unresolved": [],  # "file:line" of build calls the pre-scan could not resolve
        }
    return ctx["extend"]

def _is_abs(path):
    return path.startswith("/") or path.startswith("\\") or (len(path) > 1 and path[1] == ":")

def extend_path(ctx):
    p = ctx["settings"]["extend_file"]
    return p if _is_abs(p) else os.path.join(ctx["root"], p)

def custom(ctx, spec):
    st = _state(ctx)
    st["custom"].append(spec["name"])
    log.info("extend", "%s: tilt-build=custom, devsuite registers no build; expecting %s to build image %s" % (
        spec["name"], ctx["settings"]["extend_file"], spec["image_ref"]))
    r = new_result()
    r["notes"].append("build from %s" % ctx["settings"]["extend_file"])
    return r

# ---------------------------------------------------------------------------
# Image ref comparison. Tilt matches refs by their familiar form, so
# "docker.io/library/x:latest" and "x" are the same image.
# ---------------------------------------------------------------------------
def _norm_ref(ref):
    r = ref.strip()
    for prefix in ["docker.io/library/", "index.docker.io/library/", "docker.io/", "index.docker.io/"]:
        if r.startswith(prefix):
            r = r[len(prefix):]
            break
    if r.endswith(":latest"):
        r = r[:-len(":latest")]
    return r

def _devsuite_builds(ctx):
    """normalized image ref -> service name, for images devsuite registered itself."""
    out = {}
    for name in ctx["project"]["order"]:
        res = ctx["results"].get(name)
        if res and res["image_registered"]:
            out[_norm_ref(ctx["project"]["services"][name]["image_ref"])] = name
    return out

def _service_for_ref(ctx, ref):
    n = _norm_ref(ref)
    for name in ctx["project"]["order"]:
        spec = ctx["project"]["services"][name]
        if spec["image_ref"] and _norm_ref(spec["image_ref"]) == n:
            return name
    return None

def _duplicate_error(ctx, name, ref, where):
    spec = ctx["project"]["services"][name]
    log.fatal("extend", (
        "%s builds image '%s' for service '%s', but devsuite already builds it (tilt-build=%s, %s). " +
        "Tilt allows only one build per image. Either set the label `tilt-build: custom` on '%s' in %s " +
        "so only Tiltfile.extend builds it, or remove the build from Tiltfile.extend.") % (
        where, ref, name, spec["build_kind"], spec["kind_source"], name,
        ", ".join([os.path.basename(f) for f in ctx["project"]["files"]])))

# ---------------------------------------------------------------------------
# Tiny Starlark tokenizer, just enough to find build calls and their first
# argument. Tokens: {"k": "name"|"str"|"num"|"op"|"nl", "v": value, "line": n}
# Starlark has no while loop, so loops iterate over range() and skip ahead.
# ---------------------------------------------------------------------------
_IDENT_START = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_IDENT = _IDENT_START + "0123456789"
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", "\"": "\""}

def _tokenize(src):
    toks = []
    n = len(src)
    line = 1
    skip_to = 0
    for i in range(n):
        if i < skip_to:
            continue
        c = src[i]
        if c == "\n":
            toks.append({"k": "nl", "v": "\n", "line": line})
            line += 1
        elif c in " \t\r\\":
            pass
        elif c == "#":
            end = src.find("\n", i)
            skip_to = n if end < 0 else end
        elif c in _IDENT_START:
            j = i
            for j in range(i, n + 1):
                if j == n or src[j] not in _IDENT:
                    break
            word = src[i:j]
            if word in ["r", "b", "rb", "br"] and j < n and src[j] in "'\"":
                skip_to = j
                # raw/bytes prefix: let the quote branch handle it next round
                toks.append({"k": "prefix", "v": word, "line": line})
            else:
                toks.append({"k": "name", "v": word, "line": line})
                skip_to = j
        elif c in "'\"":
            raw = len(toks) > 0 and toks[-1]["k"] == "prefix" and "r" in toks[-1]["v"]
            if len(toks) > 0 and toks[-1]["k"] == "prefix":
                toks.pop()
            q = src[i:i + 3] if src[i:i + 3] in ["'''", "\"\"\""] else c
            start_line = line
            val = ""
            j = i + len(q)
            esc = False
            end = n
            for j in range(i + len(q), n + 1):
                if j >= n:
                    end = n
                    break
                ch = src[j]
                if esc:
                    val += ("\\" + ch) if raw else _ESCAPES.get(ch, "\\" + ch)
                    esc = False
                    continue
                if ch == "\\":
                    esc = True
                    continue
                if src[j:j + len(q)] == q:
                    end = j + len(q)
                    break
                if ch == "\n":
                    line += 1
                val += ch
            toks.append({"k": "str", "v": val, "line": start_line})
            skip_to = end
        elif c in "0123456789":
            j = i
            for j in range(i, n + 1):
                if j == n or src[j] not in _IDENT + ".":
                    break
            toks.append({"k": "num", "v": src[i:j], "line": line})
            skip_to = j
        else:
            toks.append({"k": "op", "v": c, "line": line})
    return toks

def _is(tok, kind, value = None):
    return tok["k"] == kind and (value == None or tok["v"] == value)

def _assignments(toks):
    """name -> list of RHS token lists for `name = <expr>` statements (depth 0, one line)."""
    out = {}
    n = len(toks)
    for i in range(n - 2):
        if not (_is(toks[i], "name") and _is(toks[i + 1], "op", "=") and not _is(toks[i + 2], "op", "=")):
            continue
        if i > 0 and not (_is(toks[i - 1], "nl") or _is(toks[i - 1], "op", ":") or _is(toks[i - 1], "op", ";")):
            continue  # keyword argument or comparison, not an assignment
        rhs = []
        depth = 0
        for j in range(i + 2, n):
            t = toks[j]
            if t["k"] == "nl" and depth == 0:
                break
            if t["k"] == "op" and t["v"] in "([{":
                depth += 1
            if t["k"] == "op" and t["v"] in ")]}":
                depth -= 1
            if t["k"] != "nl":
                rhs.append(t)
        out.setdefault(toks[i]["v"], []).append(rhs)
    return out

def _resolve(ctx, expr, assigns, depth):
    """Resolve an expression token list to ("ref", str), ("service", name),
    an intermediate marker (("root",), ("project",), ("services",)) or None."""
    if depth > 8 or len(expr) == 0:
        return None
    first = expr[0]
    if first["k"] == "str":
        cur = ("ref", first["v"])
    elif first["k"] == "name":
        rhs = assigns.get(first["v"])
        if rhs != None and len(rhs) == 1:
            cur = _resolve(ctx, rhs[0], assigns, depth + 1)
        elif rhs == None:
            cur = ("root",)  # the ctx parameter, or anything unknown: checked by the subscripts
        else:
            return None  # reassigned: value depends on control flow
    else:
        return None
    rest = expr[1:]
    if len(rest) % 3 != 0:
        return None
    for k in range(0, len(rest), 3):
        if not (_is(rest[k], "op", "[") and rest[k + 1]["k"] == "str" and _is(rest[k + 2], "op", "]")):
            return None
        key = rest[k + 1]["v"]
        if cur == None:
            return None
        if cur[0] == "root" and key == "project":
            cur = ("project",)
        elif cur[0] == "project" and key == "services":
            cur = ("services",)
        elif cur[0] == "services" and key in ctx["project"]["services"]:
            cur = ("service", key)
        elif cur[0] == "service" and key == "image_ref":
            cur = ("ref", ctx["project"]["services"][cur[1]]["image_ref"])
        else:
            return None
    return cur

def _first_arg(toks, open_idx):
    """Tokens of the `ref` argument of the call whose '(' is at open_idx."""
    args = []
    cur = []
    depth = 0
    for j in range(open_idx + 1, len(toks)):
        t = toks[j]
        if t["k"] == "nl":
            continue
        if t["k"] == "op" and t["v"] in "([{":
            depth += 1
        elif t["k"] == "op" and t["v"] in ")]}":
            if depth == 0:
                args.append(cur)
                break
            depth -= 1
        elif depth == 0 and _is(t, "op", ","):
            args.append(cur)
            cur = []
            continue
        cur.append(t)
    for a in args:
        if len(a) > 2 and _is(a[0], "name", "ref") and _is(a[1], "op", "=") and not _is(a[2], "op", "="):
            return a[2:]
    if args and not (len(args[0]) > 1 and args[0][0]["k"] == "name" and _is(args[0][1], "op", "=")):
        return args[0]
    return []

def prescan(ctx, path, src):
    """Finds global docker_build/custom_build calls in src. Returns
    [{"func","line","ref"|None,"service"|None}]."""
    toks = _tokenize(src)
    assigns = _assignments(toks)
    calls = []
    for i in range(len(toks) - 1):
        t = toks[i]
        if not (t["k"] == "name" and t["v"] in _BUILD_FUNCS and _is(toks[i + 1], "op", "(")):
            continue
        if i > 0 and (_is(toks[i - 1], "op", ".") or _is(toks[i - 1], "name", "def")):
            continue
        r = _resolve(ctx, _first_arg(toks, i + 1), assigns, 0)
        ref = r[1] if r and r[0] == "ref" else None
        calls.append({
            "func": t["v"],
            "line": t["line"],
            "ref": ref,
            "service": _service_for_ref(ctx, ref) if ref != None else None,
        })
    return calls

# ---------------------------------------------------------------------------
# Helpers injected into ctx for extend(ctx).
# ---------------------------------------------------------------------------
def _helpers(ctx):
    st = ctx["extend"]
    rel = ctx["settings"]["extend_file"]

    def spec_of(service, fn):
        spec = ctx["project"]["services"].get(service)
        if spec == None:
            log.fatal("extend", "%s: %s(%r): no compose service named %r (services: %s)" % (
                rel, fn, service, service, ", ".join(ctx["project"]["order"])))
        if spec["build"] == None:
            log.fatal("extend", "%s: %s(%r): the service has no build: section in compose, so there is no image to build" % (
                rel, fn, service))
        return spec

    def check(spec, fn):
        name = spec["name"]
        if name in _devsuite_builds(ctx).values():
            _duplicate_error(ctx, name, spec["image_ref"], "%s: extend(ctx) %s" % (rel, fn))
        if name in st["claimed"]:
            log.fatal("extend", "%s: %s(%r): image '%s' is already built by %s" % (
                rel, fn, name, spec["image_ref"], st["claimed"][name]))

    def claim(service):
        spec_of(service, "claim")
        st["claimed"].setdefault(service, "extend(ctx) claim")
        log.debug("extend", "%s: claimed by extend(ctx)" % service)

    def ext_docker_build(service, context = None, **kwargs):
        spec = spec_of(service, "docker_build")
        check(spec, "docker_build")
        b = spec["build"]
        if "dockerfile" not in kwargs and "dockerfile_contents" not in kwargs and context == None:
            kwargs["dockerfile"] = b["dockerfile"]
        if "target" not in kwargs and b["target"] and context == None:
            kwargs["target"] = b["target"]
        kwargs.setdefault("pull", False)
        docker_build(spec["image_ref"], context or b["context"], **kwargs)
        st["claimed"][service] = "extend(ctx) docker_build"
        log.info("extend", "%s: docker_build %s from extend(ctx)" % (service, spec["image_ref"]))

    def ext_custom_build(service, command, deps, **kwargs):
        spec = spec_of(service, "custom_build")
        check(spec, "custom_build")
        custom_build(spec["image_ref"], command, deps, **kwargs)
        st["claimed"][service] = "extend(ctx) custom_build"
        log.info("extend", "%s: custom_build %s from extend(ctx)" % (service, spec["image_ref"]))

    return {"docker_build": ext_docker_build, "custom_build": ext_custom_build, "claim": claim}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
def run(ctx):
    st = _state(ctx)
    path = extend_path(ctx)
    rel = ctx["settings"]["extend_file"]
    st["path"] = path
    if not os.path.exists(path):
        log.debug("extend", "%s not found, nothing to merge" % path)
        _check_custom(ctx, False)
        return

    log.section("extend")
    log.info("extend", "merging %s" % path)
    calls = prescan(ctx, path, str(read_file(path)))
    built = _devsuite_builds(ctx)
    for c in calls:
        where = "%s:%d %s()" % (rel, c["line"], c["func"])
        if c["ref"] == None:
            st["unresolved"].append(where)
            log.debug("extend", "%s: image ref not resolvable statically" % where)
            continue
        dup = built.get(_norm_ref(c["ref"]))
        if dup != None:
            _duplicate_error(ctx, dup, c["ref"], where)
        if c["service"] != None:
            st["claimed"][c["service"]] = where
            log.debug("extend", "%s: builds %s (service %s)" % (where, c["ref"], c["service"]))
        else:
            log.debug("extend", "%s: builds %s (no compose service uses that image)" % (where, c["ref"]))
    if st["unresolved"] and built:
        # Tilt fails with "Image for ref ... has already been defined" if one
        # of these collides; this line sits right above that error.
        log.info("extend", ("devsuite already builds %s. If Tiltfile.extend builds one of these too, " +
                            "set `tilt-build: custom` on that service.") % ", ".join(sorted(built.keys())))

    symbols = load_dynamic(path)
    fn = symbols.get("extend")
    if fn != None:
        ctx.update(_helpers(ctx))
        ctx["log"] = log
        log.debug("extend", "calling extend(ctx)")
        fn(ctx)
    _check_custom(ctx, True)

def _check_custom(ctx, extend_exists):
    st = ctx["extend"]
    rel = ctx["settings"]["extend_file"]
    for name in st["custom"]:
        spec = ctx["project"]["services"][name]
        res = ctx["results"].get(name)
        if name in st["claimed"]:
            if res:
                res["image_registered"] = True
                res["notes"] = [n for n in res["notes"] if not n.startswith("build from ")]
                res["notes"].append("built by %s" % st["claimed"][name])
            continue
        if res:
            res["notes"] = [n for n in res["notes"] if not n.startswith("build from ")]
            if extend_exists and st["unresolved"]:
                res["notes"].append("build not confirmed (%s)" % ", ".join(st["unresolved"]))
            else:
                res["notes"].append("compose builds it (no build in %s)" % rel)
        if not extend_exists:
            log.warn("extend", ("%s: tilt-build=custom but %s does not exist, so nothing builds image '%s'; " +
                                "docker compose builds it instead. Add the build to %s (see Tiltfile.extend.example).") % (
                name, rel, spec["image_ref"], rel))
        elif st["unresolved"]:
            log.info("extend", ("%s: tilt-build=custom and devsuite could not confirm a build for image '%s' " +
                                "(build calls at %s use refs it cannot resolve). If none of them builds it, compose will. " +
                                "Use ctx[\"docker_build\"](\"%s\") or ctx[\"claim\"](\"%s\") in extend(ctx) to make this explicit.") % (
                name, spec["image_ref"], ", ".join(st["unresolved"]), name, name))
        else:
            log.warn("extend", ("%s: tilt-build=custom but %s does not build image '%s', so docker compose builds it instead. " +
                                "Build it in extend(ctx) with ctx[\"docker_build\"](\"%s\") (or docker_build(ctx[\"project\"][\"services\"][\"%s\"][\"image_ref\"], ...)), " +
                                "or drop the label.") % (name, rel, spec["image_ref"], name, name))
