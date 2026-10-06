# Dockerfile analysis and rewriting.
#
# Owner: task B.
# Target API:
#   parse(path) -> {"stages": [{"name","from","index","instructions":[...]}]}
#   final_stage(parsed, target) -> stage dict
#   app_path(parsed, target) -> container dir where the app lives (WORKDIR / COPY dst)
#   strip_build_layer(path, target, publish_rel) -> Dockerfile text whose final
#       stage copies publish_rel instead of `COPY --from=<build stage>`
#   detect_rid(parsed, target) -> "linux-x64" | "linux-musl-x64" | ... from the base image
#
# Additions (task B):
#   rewrite(parsed, target, publish_rel, context_prefix) -> {"text", "replaced",
#       "app_path", "context_paths"}; strip_build_layer() is a thin wrapper.
#   build_copies(parsed, target) -> the `COPY --from=<build stage>` instructions
#       of the final stage chain (empty = nothing to strip).
#
# Supported syntax: line continuations (`\` or the `# escape=` directive), comments,
# global ARGs, `FROM [--platform=..] image [AS name]`, stage references by name or
# index, COPY/ADD flags and JSON (exec) form. Heredocs are not supported (they
# need BuildKit, which Podman's compat API does not offer anyway).

def _escape_char(lines):
    for line in lines:
        s = line.strip()
        if not s.startswith("#"):
            break
        body = s[1:].strip().lower()
        if body.startswith("escape") and "=" in body:
            ch = body.partition("=")[2].strip()
            if ch in ["`", "\\"]:
                return ch
    return "\\"

def _logical_lines(text):
    raw = text.replace("\r\n", "\n").split("\n")
    esc = _escape_char(raw)
    out = []
    cur = ""
    for line in raw:
        s = line.rstrip()
        stripped = s.strip()
        if cur == "" and (stripped == "" or stripped.startswith("#")):
            continue
        if cur != "" and stripped.startswith("#"):
            continue  # comment lines inside a continuation are dropped by Docker too
        if s.endswith(esc):
            cur += s[:-1] + " "
            continue
        cur += s
        out.append(cur.strip())
        cur = ""
    if cur.strip():
        out.append(cur.strip())
    return out

def _split_ws(s):
    return [x for x in s.replace("\t", " ").split(" ") if x]

def _parse_from(args):
    words = _split_ws(args)
    platform = ""
    rest = []
    for w in words:
        if w.startswith("--platform="):
            platform = w
        else:
            rest.append(w)
    image = rest[0] if rest else ""
    name = ""
    if len(rest) >= 3 and rest[1].lower() == "as":
        name = rest[2].lower()
    return image, name, platform

def parse_text(text):
    """Parses Dockerfile text. See parse()."""
    stages = []
    global_args = []
    for line in _logical_lines(text):
        cmd, _, args = line.partition(" ")
        cmd = cmd.upper()
        args = args.strip()
        if cmd == "FROM":
            image, name, platform = _parse_from(args)
            from_stage = -1
            for st in stages:
                if st["name"] and st["name"] == image.lower():
                    from_stage = st["index"]
            stages.append({
                "name": name,
                "from": image,
                "from_stage": from_stage,  # index of the parent stage, -1 for an image
                "platform": platform,
                "index": len(stages),
                "instructions": [],
            })
        elif not stages:
            global_args.append(line)
        else:
            stages[-1]["instructions"].append({"cmd": cmd, "args": args, "raw": line})
    return {"stages": stages, "global_args": global_args}

def parse(path):
    """Returns {"stages": [...], "global_args": [...]}.

    Stage: {"name", "from", "from_stage", "platform", "index", "instructions"}
    Instruction: {"cmd" (upper case), "args", "raw" (continuations joined)}.
    """
    return parse_text(str(read_file(path)))

def _stage_ref(parsed, ref):
    """Resolves a --from=/FROM reference to a stage index, -1 for an external image."""
    ref = ref.lower()
    if ref.isdigit():
        i = int(ref)
        return i if i < len(parsed["stages"]) else -1
    for st in parsed["stages"]:
        if st["name"] == ref:
            return st["index"]
    return -1

def final_stage(parsed, target):
    stages = parsed["stages"]
    if not stages:
        fail("Dockerfile has no FROM instruction")
    if target:
        i = _stage_ref(parsed, target)
        if i < 0:
            fail("Dockerfile has no stage named '%s' (compose build.target)" % target)
        return stages[i]
    return stages[-1]

def _chain(parsed, index):
    """Stage indexes from the root image down to `index` (FROM ancestry)."""
    out = []
    i = index
    for _ in range(len(parsed["stages"]) + 1):
        if i < 0:
            break
        out.insert(0, i)
        i = parsed["stages"][i]["from_stage"]
    return out

def _is_build_stage(parsed, index):
    """True when the stage (or one it derives from) runs the .NET SDK."""
    for i in _chain(parsed, index):
        st = parsed["stages"][i]
        if "dotnet/sdk" in st["from"].lower():
            return True
        for ins in st["instructions"]:
            if ins["cmd"] == "RUN":
                a = " ".join(_split_ws(ins["args"])).lower()
                if "dotnet publish" in a or "dotnet build" in a:
                    return True
    return False

def _unquote(s):
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ["\"", "'"]:
        return s[1:-1]
    return s

def _parse_copy(args):
    """COPY/ADD args -> {"flags": [...], "from": str, "srcs": [...], "dst": str, "json": bool}."""
    flags = []
    frm = ""
    rest = args.strip()
    for _ in range(16):
        if not rest.startswith("--"):
            break
        word, _, rest = rest.partition(" ")
        rest = rest.strip()
        if word.startswith("--from="):
            frm = word[len("--from="):]
        else:
            flags.append(word)
    paths = []
    is_json = rest.startswith("[")
    if is_json:
        decoded = decode_json(rest)
        paths = [str(p) for p in decoded]
    else:
        paths = [_unquote(p) for p in _split_ws(rest)]
    if len(paths) < 2:
        return None
    return {"flags": flags, "from": frm, "srcs": paths[:-1], "dst": paths[-1], "json": is_json}

def _json_str(s):
    return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _format_copy(cmd, flags, srcs, dst):
    # exec form (one line; encode_json() would pretty-print over several lines)
    parts = [cmd] + flags + ["[" + ", ".join([_json_str(p) for p in srcs + [dst]]) + "]"]
    return " ".join(parts)

def _workdir_join(workdir, path):
    if path.startswith("/"):
        return path
    base = workdir or "/"
    if path in [".", "./"]:
        return base
    if path.startswith("./"):
        path = path[2:]
    return base.rstrip("/") + "/" + path

def _norm_dir(p):
    p = p.replace("\\", "/")
    if len(p) > 1:
        p = p.rstrip("/")
    return p

def build_copies(parsed, target):
    """`COPY --from=<build stage>` instructions in the final stage chain.

    Returns [{"stage": index, "pos": instruction index, "copy": parsed copy, "dst_abs": str}].
    """
    final = final_stage(parsed, target)
    out = []
    workdir = ""
    for si in _chain(parsed, final["index"]):
        st = parsed["stages"][si]
        for pos, ins in enumerate(st["instructions"]):
            if ins["cmd"] == "WORKDIR":
                workdir = _workdir_join(workdir, _unquote(ins["args"].strip()))
            elif ins["cmd"] == "COPY":
                c = _parse_copy(ins["args"])
                if c == None or not c["from"]:
                    continue
                ref = _stage_ref(parsed, c["from"])
                if ref >= 0 and _is_build_stage(parsed, ref):
                    out.append({"stage": si, "pos": pos, "copy": c,
                                "dst_abs": _norm_dir(_workdir_join(workdir, c["dst"]))})
    return out

def _final_workdir(parsed, target):
    final = final_stage(parsed, target)
    workdir = ""
    for si in _chain(parsed, final["index"]):
        for ins in parsed["stages"][si]["instructions"]:
            if ins["cmd"] == "WORKDIR":
                workdir = _workdir_join(workdir, _unquote(ins["args"].strip()))
    return _norm_dir(workdir) if workdir else ""

def app_path(parsed, target):
    """Container dir the published app lives in: dst of the first
    `COPY --from=<build stage>` of the final stage, else its WORKDIR, else ""."""
    copies = build_copies(parsed, target)
    if copies:
        return copies[0]["dst_abs"]
    return _final_workdir(parsed, target)

def _needed_stages(parsed, final_index, replaced):
    """Stage indexes the rewritten Dockerfile keeps: the final chain plus stages
    still referenced by COPY --from that are not replaced (and their chains)."""
    needed = {}
    todo = [final_index]
    for _ in range(len(parsed["stages"]) * 4 + 4):
        if not todo:
            break
        idx = todo.pop()
        for si in _chain(parsed, idx):
            if si in needed:
                continue
            needed[si] = True
            for pos, ins in enumerate(parsed["stages"][si]["instructions"]):
                if ins["cmd"] != "COPY" or (si, pos) in replaced:
                    continue
                c = _parse_copy(ins["args"])
                if c and c["from"]:
                    ref = _stage_ref(parsed, c["from"])
                    if ref >= 0 and ref not in needed:
                        todo.append(ref)
    return sorted(needed.keys())

def rewrite(parsed, target, publish_rel, context_prefix = ""):
    """Rewrites the final stage chain so the app comes from the local publish
    folder instead of the SDK build stages.

    publish_rel:    publish folder, relative to the new build context ("/" separators)
    context_prefix: original build context relative to the new one ("" = same);
                    prepended to plain COPY/ADD sources that stay in the file.

    Returns {"text": Dockerfile text, "replaced": number of COPY rewritten,
             "app_path": str, "context_paths": [context-relative paths the kept
             stages COPY/ADD from the build context]}.
    """
    final = final_stage(parsed, target)
    copies = build_copies(parsed, target)
    replaced = {}
    for c in copies:
        replaced[(c["stage"], c["pos"])] = True
    keep = _needed_stages(parsed, final["index"], replaced)
    prefix = context_prefix.replace("\\", "/").strip("/")

    lines = list(parsed["global_args"])
    context_paths = []
    for si in keep:
        st = parsed["stages"][si]
        head = ["FROM"]
        if st["platform"]:
            head.append(st["platform"])
        head.append(st["from"])
        if st["name"]:
            head = head + ["AS", st["name"]]
        lines.append("")
        lines.append(" ".join(head))
        for pos, ins in enumerate(st["instructions"]):
            if (si, pos) in replaced:
                c = _parse_copy(ins["args"])
                lines.append("# devsuite: was " + ins["raw"])
                lines.append(_format_copy("COPY", c["flags"], [publish_rel.rstrip("/") + "/"], c["dst"]))
                continue
            if ins["cmd"] in ["COPY", "ADD"]:
                c = _parse_copy(ins["args"])
                if c != None and not c["from"]:
                    srcs = []
                    for s in c["srcs"]:
                        if "://" in s:
                            srcs.append(s)  # ADD <url>
                            continue
                        rel = s.lstrip("/")
                        if rel.startswith("./"):
                            rel = rel[2:]
                        rel = rel.rstrip("/")
                        if rel in ["", "."]:
                            full = prefix or "."
                        else:
                            full = (prefix + "/" + rel) if prefix else rel
                        srcs.append(full)
                        context_paths.append(full)
                    lines.append(_format_copy(ins["cmd"], c["flags"], srcs, c["dst"]))
                    continue
            lines.append(ins["raw"])
    return {
        "text": "\n".join(lines).strip() + "\n",
        "replaced": len(copies),
        "app_path": copies[0]["dst_abs"] if copies else _final_workdir(parsed, target),
        "context_paths": context_paths,
    }

def strip_build_layer(path, target, publish_rel):
    return rewrite(parse(path), target, publish_rel)["text"]

def detect_rid(parsed, target):
    final = final_stage(parsed, target)
    chain = _chain(parsed, final["index"])
    image = parsed["stages"][chain[0]]["from"].lower()
    arch = "arm64" if ("arm64" in image or "aarch64" in image) else "x64"
    if "alpine" in image or "musl" in image:
        return "linux-musl-" + arch
    return "linux-" + arch
