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
