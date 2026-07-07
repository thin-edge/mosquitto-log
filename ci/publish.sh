#!/bin/bash
# -----------------------------------------------
# Publish packages to Cloudsmith.io
# -----------------------------------------------
# Uploads the deb/rpm/apk packages produced by GoReleaser (under dist/) to a
# Cloudsmith repository. The cloudsmith CLI is installed on demand if missing.
#
# Adapted from thin-edge/tedge-container-plugin.
help() {
  cat <<EOF
Publish packages from a path to a Cloudsmith package repository

The cloudsmith CLI is downloaded automatically if it is not already present.

Usage:
    $0 [--path <dir>] --token <string> --owner <string> --repo <string>

Flags:
    --token <string>            Cloudsmith API key used to authenticate uploads
    --owner <string>            Cloudsmith repository owner (default: thinedge)
    --repo <string>             Cloudsmith repository name (default: community)
    --path <dir>                Directory to search for packages (default: ./)
    --help|-h                   Show this help

Optional environment variables (used instead of flags):

    PUBLISH_TOKEN               Equivalent to --token
    PUBLISH_OWNER               Equivalent to --owner
    PUBLISH_REPO                Equivalent to --repo

Examples:
    $0 --path ./dist --token "mytoken" --owner thinedge --repo community

        Publish all deb/rpm/apk packages found under ./dist
EOF
}

PUBLISH_TOKEN="${PUBLISH_TOKEN:-}"
PUBLISH_OWNER="${PUBLISH_OWNER:-thinedge}"
PUBLISH_REPO="${PUBLISH_REPO:-community}"
SOURCE_PATH="./"

#
# Argument parsing
#
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)
            if [ -n "$2" ]; then PUBLISH_OWNER="$2"; fi
            shift
            ;;
        --token)
            PUBLISH_TOKEN="$2"
            shift
            ;;
        --path)
            SOURCE_PATH="$2"
            shift
            ;;
        --repo)
            if [ -n "$2" ]; then PUBLISH_REPO="$2"; fi
            shift
            ;;
        --help | -h)
            help
            exit 0
            ;;
        -*)
            echo "Unrecognized flag: $1" >&2
            help
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done
set -- "${POSITIONAL[@]}"

if [ -z "$PUBLISH_TOKEN" ]; then
    echo "Missing required Cloudsmith API key (--token or PUBLISH_TOKEN)" >&2
    exit 1
fi

# Add local tools path (cloudsmith installs here when using pip --user)
LOCAL_TOOLS_PATH="$HOME/.local/bin"
export PATH="$LOCAL_TOOLS_PATH:$PATH"

# Install tooling if missing
if ! [ -x "$(command -v cloudsmith)" ]; then
    echo 'Installing cloudsmith cli' >&2
    if command -v pip3 &>/dev/null; then
        pip3 install --upgrade cloudsmith-cli
    elif command -v pip &>/dev/null; then
        pip install --upgrade cloudsmith-cli
    else
        echo "Could not install cloudsmith cli. Reason: pip3/pip is not installed" >&2
        exit 2
    fi
fi

publish() {
    local sourcedir="$1"
    local pattern="$2"
    local package_type="$3"
    local distribution="$4"
    local distribution_version="$5"

    # Notes: Cloudsmith currently requires that:
    #  * distribution/distribution_version come from `cloudsmith list distros`
    #  * the component is fixed to 'main'
    find "$sourcedir" -name "$pattern" -print0 | while read -r -d $'\0' file; do
        if [ "$package_type" = "deb" ] && [[ "$file" =~ .+_armv7.deb ]]; then
            echo "Skipping debian armv7 package as it conflicts with the armv6" >&2
            continue
        fi
        echo "Publishing: $file" >&2
        cloudsmith upload "$package_type" "${PUBLISH_OWNER}/${PUBLISH_REPO}/${distribution}/${distribution_version}" "$file" \
            --no-wait-for-sync \
            --api-key "${PUBLISH_TOKEN}"
    done
}

publish "$SOURCE_PATH" "*.deb" deb "any-distro" "any-version"
publish "$SOURCE_PATH" "*.rpm" rpm "any-distro" "any-version"
publish "$SOURCE_PATH" "*.apk" alpine "alpine" "any-version"
