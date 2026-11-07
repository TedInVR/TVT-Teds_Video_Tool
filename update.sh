#!/bin/bash
set -euo pipefail
repo=TedInVR/VFLR_VideoFixLinkRestore
target=/Applications/VFLR.app
development='/Applications/VFLR Development'
lock="$development/.install-lock"

download() {
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        --proto-redir '=https' --connect-timeout 10 --max-time 120 "$@"
}
check_release() {
    local installed=$1 sha available
    sha=$(download -H 'Cache-Control: no-cache' "https://api.github.com/repos/$repo/commits/main" |
        /usr/bin/plutil -extract sha raw -o - -)
    [[ "$sha" =~ ^[a-f0-9]{40}$ ]]
    available=$(download "https://raw.githubusercontent.com/$repo/$sha/VERSION")
    [[ "$available" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    if /usr/bin/awk -v a="$available" -v b="$installed" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i=1; i<=3; i++) {
            if (x[i]+0 > y[i]+0) exit 0
            if (x[i]+0 < y[i]+0) exit 1
        }
        exit 1
    }'; then
        printf '%s %s\n' "$available" "$sha"
    fi
}
stage_build() {
    local version=$1 sha=$2 stage=$3
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$sha" =~ ^[a-f0-9]{40}$ ]]
    if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
        echo 'Install the Apple Command Line Tools with xcode-select --install, then try again.' >&2
        exit 1
    fi
    printf 'Building VFLR %s for this Mac…\n' "$version" >&2
    mkdir "$stage/source" "$stage/tmp"
    download "https://codeload.github.com/$repo/tar.gz/$sha" -o "$stage/source.tar.gz"
    /usr/bin/tar -xzf "$stage/source.tar.gz" --strip-components 1 -C "$stage/source"
    [[ $(cat "$stage/source/VERSION") == "$version" ]]
    TMPDIR="$stage/tmp" CLANG_MODULE_CACHE_PATH="$stage/tmp/module-cache" \
        /bin/bash "$stage/source/build.sh" "$stage/VFLR.app"
}
install_staged() {
    local stage=$1
    local backup="$stage/previous.app"
    if /usr/bin/pgrep -x VFLR >/dev/null; then
        echo 'Quit VFLR before installing.' >&2
        return 1
    fi
    if [[ -L "$target" || ( -e "$target" && ! -d "$target" ) ]]; then
        echo 'The VFLR install path is occupied.' >&2
        return 1
    fi
    if [[ -d "$target" ]]; then /bin/mv "$target" "$backup" || return 1; fi
    if ! /bin/mv "$stage/VFLR.app" "$target"; then
        if [[ -d "$backup" ]]; then /bin/mv "$backup" "$target" || return 2; fi
        return 1
    fi
}
prepare_install() {
    local release=$1 sha=$2 parent_pid=${3:-}
    mkdir -p "$development"
    if ! mkdir "$lock"; then
        echo 'Another VFLR installation is in progress.' >&2
        exit 1
    fi
    stage=''
    trap 'if [[ -n "$stage" ]]; then rm -rf "$stage"; fi; rmdir "$lock"' EXIT
    stage=$(mktemp -d "$development/.update-XXXXXX")
    stage_build "$release" "$sha" "$stage"
    if [[ -n "$parent_pid" ]]; then
        cp "${BASH_SOURCE[0]}" "$stage/install-helper.sh"
        /usr/bin/nohup /bin/bash "$stage/install-helper.sh" apply "$stage" "$parent_pid" \
            </dev/null >/dev/null 2>&1 &
        trap - EXIT
    else
        local result=0
        install_staged "$stage" || result=$?
        if [[ "$result" == 2 ]]; then
            echo "The previous app is preserved at $stage/previous.app" >&2
            stage=''
        fi
        if [[ "$result" != 0 ]]; then exit 1; fi
        printf 'Installed VFLR %s in Applications.\n' "$release"
        /usr/bin/open -R "$target"
    fi
}
case "${1:-bootstrap}" in
    check) check_release "$2" ;;
    prepare) prepare_install "$2" "$3" "$4" ;;
    apply)
        stage=$2
        trap 'if [[ -n "$stage" ]]; then rm -rf "$stage"; fi; rmdir "$lock"' EXIT
        while kill -0 "$3" 2>/dev/null; do sleep 1; done
        result=0
        install_staged "$stage" || result=$?
        if [[ "$result" != 0 ]]; then
            message='The update could not install. Open VFLR and check again.'
            if [[ "$result" == 2 ]]; then
                message="The previous app is preserved at $stage/previous.app"
                stage=''
            fi
            /usr/bin/osascript -e 'on run argv' -e 'display alert "VFLR update failed" message (item 1 of argv)' -e 'end run' "$message"
        fi
        ;;
    bootstrap)
        if /usr/bin/pgrep -x VFLR >/dev/null; then
            echo 'VFLR is running. Quit it before running this installer.' >&2
            exit 1
        fi
        release=$(check_release 0.0.0)
        read -r version sha <<< "$release"
        prepare_install "$version" "$sha"
        ;;
    *) exit 1 ;;
esac
