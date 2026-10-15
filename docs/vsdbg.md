# Offline vsdbg (task C)

Visual Studio debugs .NET code in a Linux container with **vsdbg**. When it is not
already in the container, VS downloads it there with Microsoft's `GetVsDbg.sh`
(`https://aka.ms/getvsdbgsh`), which fails on an air-gapped machine. devsuite ships
vsdbg in the repo (Git LFS) and Tilt mounts it read-only into every `dotnet`
container at every path VS looks, with the marker files `GetVsDbg.sh` writes, so VS
finds it installed and never downloads.

| Container path | Used by |
|---|---|
| `/remote_debugger` | VS F5 container tooling (it mounts `%USERPROFILE%\vsdbg\vs2017u5` there) and the `DebugAdapterHost` fallback (task F) |
| `<home>/.vs-debugger/<key>` | Debug > Attach to Process > Docker (Linux Container); `<key>` is the VS version keyword (`vs2022`, ...) |

## 1. Package vsdbg once, on a connected machine

Windows (PowerShell 5.1 or 7):

```powershell
git lfs install                                   # once per clone
.\devsuite\vsdbg\Get-VsDbgOffline.ps1             # keys vs2022,vs2026  x  rids linux-x64,linux-musl-x64
git add devsuite/vsdbg/drop
git add --chmod=+x 'devsuite/vsdbg/drop/*/vsdbg'  # Windows does not record the exec bit
git commit -m "vsdbg drop"
```

Linux / macOS / WSL:

```bash
git lfs install
sh devsuite/vsdbg/Get-VsDbgOffline.sh
git add devsuite/vsdbg/drop && git commit -m "vsdbg drop"
```

The scripts mirror `GetVsDbg.sh`:

* **Version resolution**: each keyword (`latest`, `vs2022`, ...) resolves to the version
  number the *current* `GetVsDbg.sh` gives it; the script is downloaded and its version
  table parsed, so the drop matches what VS would install today. A keyword the script
  does not know fails, except `vs2026`, which falls back to `latest` with a warning until
  Microsoft adds it (see section 4).
* **Download**: `<base>/vsdbg-<version with dots as dashes>/vsdbg-<rid>.tar.gz`, base taken
  from the script (today `https://vsdebugger-cyg0dxb6czfafzaz.b01.azurefd.net`).
* **Layout and markers**: the archive is extracted as-is, then `success_rid.txt` and
  `success_version.txt` are written with the same one-line contents as `GetVsDbg.sh`.
  Re-running with the same versions is a no-op; `-Force` / `-f` re-downloads.

Options (PowerShell / sh):

| PowerShell | sh | Default | Meaning |
|---|---|---|---|
| `-Version` | `-v` | `vs2022,vs2026` | keywords or version numbers; each becomes a drop key |
| `-RuntimeId` | `-r` | `linux-x64,linux-musl-x64` | RIDs (`linux-arm64`, `linux-musl-arm64` for ARM hosts) |
| `-DropDir` | `-l` | `devsuite/vsdbg/drop` | output folder |
| `-Key` | `-k` | the `-Version` value | key name when `-Version` is a number |
| `-FromArchive` | `-a` | | use an already-downloaded `vsdbg-<rid>.tar.gz` (one version, one RID) |
| `-ScriptUrl` | `-S` | `https://aka.ms/getvsdbgsh` | URL or local copy of `GetVsDbg.sh` for version resolution |
| `-BaseUrl` | `-B` | from the script | internal mirror of the vsdbg CDN |
| `-Force` | `-f` | | re-download even if the markers match |

Only the archive is available (downloaded by hand, from a mirror, or from another team):

```powershell
.\devsuite\vsdbg\Get-VsDbgOffline.ps1 -FromArchive C:\Downloads\vsdbg-linux-x64.tar.gz `
    -RuntimeId linux-x64 -Version 18.7.10521.2 -Key vs2026
```

Output:

```
devsuite/vsdbg/drop/
  manifest.json                 every entry below (version, rid, sha256, source, date)
  vs2022/linux-x64/             vsdbg, its libraries, success_rid.txt, success_version.txt
  vs2022/linux-x64.json         sidecar for that folder
  vs2022/linux-musl-x64/ ...
  vs2026/...
```

`devsuite/vsdbg/.gitattributes` stores everything under `drop/` in Git LFS except the
JSON and marker files. Identical files under two keys are stored once by LFS. Expect
roughly 150 to 200 MB per key and RID extracted.

## 2. What Tilt does

For every service with `tilt-build: dotnet` (unless `tilt-debugger: "false"` or
`tilt up -- --no-debugger`), `devsuite/tilt/vsdbg.star` adds read-only bind mounts to the
generated compose override:

* `/remote_debugger` <- `drop/<remote_debugger_key>/<rid>`
* `<home>/.vs-debugger/<key>` <- `drop/<key>/<rid>` for every key and every home

The Tilt log shows one line per service and the summary carries the versions:

```
[devsuite] INFO  vsdbg     | orders-api: rid linux-x64 (base image mcr.microsoft.com/dotnet/aspnet:10.0), 5 read-only mounts from .../devsuite/vsdbg/drop
[devsuite] INFO  summary   | orders-api  kind=dotnet (label) image=... vsdbg linux-x64 vs2022=17.14.10519.1, vs2026=18.7.10521.2
```

**RID**: label `tilt-debugger-rid`, else the base image of the final stage (or of the
compose `build.target` stage, following `FROM <stage>` aliases): `alpine` in the name gives
`linux-musl-*`, `arm64`/`aarch64` gives `*-arm64`, otherwise `default_rid`.

**Home**: label `tilt-debugger-user-home` (comma list allowed), else `user_homes`
(`/root` and `/home/app`, the non-root user of the .NET 8+ images). Mounting both costs
nothing and covers containers whose `USER` changes.

**Missing drop**: Tilt stops with the folder, key and RID that are missing and the exact
packager command to run, plus how to skip the debugger.

Settings (`devsuite.json`, section `vsdbg`, all optional):

```json
{
  "vsdbg": {
    "drop_dir": "devsuite/vsdbg/drop",
    "keys": ["vs2022", "vs2026"],
    "remote_debugger_key": "vs2026",
    "user_homes": ["/root", "/home/app"],
    "default_rid": "linux-x64"
  }
}
```

`drop_dir` may be absolute (a shared folder instead of Git LFS). With Podman on Hyper-V
the source paths are Windows paths; task E's `podman.star translate` rewrites them to the
VM path like every other bind mount.

## 3. Check a container by hand

```bash
docker exec <container> sh -c 'ls -l /remote_debugger/vsdbg ~/.vs-debugger/*/vsdbg; cat ~/.vs-debugger/*/success_version.txt'
docker exec <container> /remote_debugger/vsdbg --help     # prints "Microsoft .NET Core Debugger (vsdbg)"
```

Alpine images need `libstdc++` and `libgcc` in the image (the .NET `-alpine` images have
them). Older vsdbg builds (16.x) also need `libintl`; a current build should not, but
check `vsdbg --help` once in your Alpine image.

## 4. Confirm what VS 2026 probes (one time, connected machine)

Microsoft does not document the folder key VS 2026 uses under `~/.vs-debugger`, so
devsuite mounts `vs2022` and `vs2026` until this is confirmed:

1. Start any .NET Linux container **without** devsuite's mounts, e.g.
   `docker run -d --name probe mcr.microsoft.com/dotnet/aspnet:10.0 sleep infinity`
   (or `tilt up -- --no-debugger`). Put a `dotnet` process in it if you want the attach to
   finish (any sample app); the download happens before the process list matters.
2. VS 2026: **Debug > Attach to Process**, Connection type **Docker (Linux Container)**,
   pick the container, pick a process, Attach. With the network available VS downloads
   vsdbg into the container. **Output > Debug** (or the Container Tools pane) shows the
   `GetVsDbg.sh -v <key> -l <path>` command it ran: note `<key>` and `<path>`.
3. In the container:
   ```bash
   docker exec probe sh -c 'find / -xdev \( -name vsdbg -o -name success_version.txt \) 2>/dev/null; \
     for f in $(find / -xdev -name success_version.txt 2>/dev/null); do echo "$f: $(cat $f) $(cat $(dirname $f)/success_rid.txt)"; done'
   ```
4. For the F5 path, check which folder VS 2026 mounts at `/remote_debugger` from a container
   VS started with F5: `docker inspect <container> --format '{{json .Mounts}}'` (on
   Windows it is under `%USERPROFILE%\vsdbg\`).
5. Record the result:
   * the key in `devsuite.json` `vsdbg.keys` (and `remote_debugger_key`), and package it:
     `Get-VsDbgOffline.ps1 -Version <key>`; if `GetVsDbg.sh` does not know the keyword,
     package the version VS installed: `-Version <success_version.txt value> -Key <key>`;
   * the findings in this section (date, VS build, key, path, version).

If VS ever runs `GetVsDbg.sh` with a version different from the one in the drop, it tries
to re-download into the read-only mount and the attach fails with a write error: re-run the
packager on a connected machine to refresh the drop.

## 5. Tests

* `sh devsuite/vsdbg/tests/test-packager.sh` and `pwsh devsuite/vsdbg/tests/test-packager.ps1`:
  version table parsing, download through a local HTTP server, `FromArchive`, markers,
  manifest, no-op re-run, error messages. They use a fixture shaped like `GetVsDbg.sh`
  and fake archives, so they run offline.
* `tilt ci` on the sample with a drop in place, then the commands in section 3.
