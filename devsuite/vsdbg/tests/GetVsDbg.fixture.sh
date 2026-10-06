#!/bin/sh
# shellcheck disable=SC2034,SC2154
# Test fixture: the shape of Microsoft's GetVsDbg.sh version table and URL
# (not the real script; version numbers are placeholders).
set_vsdbg_version()
{
    # This case statement is done on the lower case version of version_string
    version_string="$(echo "$1" | awk '{print tolower($0)}')"
    case "$version_string" in
        latest)
            __VsDbgVersion=18.7.10521.2
            ;;
        vs2022)
            __VsDbgVersion=17.14.10519.1
            ;;
        "vs2019"|vsfm-8)
            __VsDbgVersion=17.14.10519.1
            ;;
        vs2017u5) __VsDbgVersion=17.14.10519.1 ;;
        vs2017u1)
            __VsDbgVersion=15.1.10630.1
            ;;
        *)
            simpleVersionRegex="^[0-9].*"
            __VsDbgVersion=$1
            ;;
    esac
}
url="http://127.0.0.1:__PORT__/vsdbg-${__VsDbgVersionDashes}/${vsdbgCompressedFile}"
