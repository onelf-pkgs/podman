#!/bin/sh
# Tests the Podman package build.sh wrote. Runs in the same container,
# right after it.
#
# The job container runs as root without CAP_SYS_ADMIN and without a
# user namespace podman could map, so image and container operations
# cannot run here; pull and run are for a real host. What can run is
# the launch path up to the runtime: the packed engine, every helper on
# PATH, and the storage stack, with vfs standing in for overlay, which
# needs CAP_SYS_ADMIN to mount. The two podman variables tell it the
# namespace is already settled and name that vfs store.
#
# Usage: test.sh
set -eu
cd "$(dirname "$0")"

arch=$(uname -m)

# toml <table> <key>: the string value of <key> in [<table>] of
# package.toml.
toml() {
    awk -v table="[$1]" -v key="$2" '
        /^\[/ { in_table = ($0 == table); next }
        in_table && $1 == key && $2 == "=" { gsub(/"/, "", $3); print $3; exit }
    ' package.toml
}

version=$(toml sources.podman version)

xbps-install -Syu xbps > /dev/null
xbps-install -Syu > /dev/null
xbps-install -y libseccomp shadow crun conmon catatonit passt netavark \
    aardvark-dns fuse-overlayfs > /dev/null

packed=dist/podman-$arch.onelf
onelf verify "$packed"

# The tree inside the package must carry every helper podman execs by
# name, and the setuid trio with their setuid bit: without it, rootless
# mapping and fuse mounts fail on a real host.
extract=$(mktemp -d)
store=$(mktemp -d)
conf=$(mktemp)
trap 'rm -rf "$extract" "$store" "$conf"' EXIT
# --preserve-mode because this is our own package and the check is the
# setuid bits themselves; extract masks modes to 0777 without it.
onelf extract "$packed" -o "$extract" --preserve-mode \
    --file bin/podman \
    --file bin/crun --file bin/conmon --file bin/catatonit \
    --file bin/passt \
    --file bin/netavark --file bin/aardvark-dns \
    --file bin/fuse-overlayfs \
    --file bin/fusermount3 --file bin/newuidmap --file bin/newgidmap
# pasta is a symlink to passt, so the extraction carries the binary and
# the link is checked in the manifest.
list=$(onelf list "$packed")
for helper in podman crun conmon catatonit pasta passt netavark \
    aardvark-dns fuse-overlayfs
do
    case $list in
    *"bin/$helper"*) : ;;
    *)
        echo "the package is missing bin/$helper" >&2
        exit 1
        ;;
    esac
done
for helper in conmon crun catatonit passt netavark \
    aardvark-dns fuse-overlayfs
do
    [ -x "$extract/bin/$helper" ] || {
        echo "bin/$helper did not extract as an executable" >&2
        exit 1
    }
done
for helper in fusermount3 newuidmap newgidmap; do
    mode=$(stat -c '%a' "$extract/bin/$helper")
    [ "$mode" = 4755 ] || {
        echo "bin/$helper lost its setuid bit (mode $mode)" >&2
        exit 1
    }
done

# The engine reports itself through the wrapper: a bare invocation and
# the full version, which walks the runtime path and stands up the vfs
# store. This much of the launch works without CAP_SYS_ADMIN; a pull
# or a run would go looking for a user namespace the container cannot
# give it, and belongs to a real host.
printf '[storage]\ndriver = "vfs"\n' > "$conf"
export CONTAINERS_STORAGE_CONF=$conf
export _CONTAINERS_USERNS_CONFIGURED=done
"$packed" --version | grep -q "podman version $version"
"$packed" version | grep -q "$version"

echo "podman-$arch: verify, helpers, setuid bits and engine ok"
