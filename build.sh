#!/bin/sh
# Builds Podman for this machine's architecture into dist/:
#
#   podman-<arch>.onelf
#
# The engine is compiled from the upstream source tarball with Go: it
# is the one piece upstream does not publish for Linux, their releases
# carry only the remote client and the Windows and macOS installers.
# Signature verification uses the pure-Go OpenPGP path, so gpgme and
# its dependencies stay out of the bundle. The helper stack podman
# execs comes from the repository's own packages, assembled into bin/
# beside the engine; on launch the wrapper writes config files naming
# the tree's copies by absolute path, which is where podman looks all
# of them up.
#
# Bundling and packing go through the checked-in recipe: `onelf
# build` bundles the library closures and packs in one pass, and
# strip = true keeps the copied libraries lean. The tree carries no
# newuidmap, newgidmap or fusermount3: those only work with a setuid
# bit, which no file in a materialized tree can use, so podman takes
# the host's own copies, giving real multi mapping where shadow is
# installed and its single-mapping fallback where it is not.
#
# Usage: build.sh
#
# Runs as root in a Void Linux (glibc) container with this directory as
# the working directory and onelf on PATH.
set -eu
cd "$(dirname "$0")"

arch=$(uname -m)
case $arch in
x86_64 | aarch64) ;;
*)
    echo "unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

# toml <table> <key>: the string value of <key> in [<table>] of
# package.toml.
toml() {
    awk -v table="[$1]" -v key="$2" '
        /^\[/ { in_table = ($0 == table); next }
        in_table && $1 == key && $2 == "=" { gsub(/"/, "", $3); print $3; exit }
    ' package.toml
}

version=$(toml sources.podman version)
release=$(sed -n 's/^release = //p' package.toml)

# The runtime installs only a strictly newer revision, so a client is
# never rolled back: 6.2.0 release 1 is 6002000001. awk reads Ventoy's
# zero-padded parts, such as the 05 of 1.1.05, as decimal.
revision=$(echo "$version.$release" | awk -F. '
    NF != 4 { exit 1 }
    { for (i = 2; i <= 4; i++) if ($i >= 1000) exit 1 }
    { printf "%.0f", $1 * 1e9 + $2 * 1e6 + $3 * 1e3 + $4 }
') || {
    echo "version $version release $release does not fit an update revision" >&2
    exit 1
}

xbps-install -Syu xbps > /dev/null
xbps-install -Syu > /dev/null
# The toolchain: Go is new enough in the repository (podman 6.2 needs
# 1.26), and the Makefile wants bash, find and git to be there even
# though the source tarball leaves nothing for git to describe.
xbps-install -y curl go gcc make pkg-config libseccomp-devel git \
    bsdtar bash findutils patchelf > /dev/null
# The helper stack: every binary podman execs by name.
xbps-install -y shadow crun conmon catatonit passt netavark \
    aardvark-dns fuse-overlayfs > /dev/null

work=$PWD/build/work
file=build/src/podman-$version.tar.gz
if [ ! -f "$file" ]; then
    mkdir -p build/src
    url=$(toml sources.podman url | sed "s/{version}/$version/")
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
fi
echo "$(toml sources.podman sha256)  $file" | sha256sum -c - > /dev/null

rm -rf "$work"
mkdir -p "$work"
bsdtar -xzf "$file" -C "$work"
src=$work/podman-$version
cd "$src"

# -buildvcs=false: the extracted source sits inside the checked-out
# repository, and go's VCS stamping trips over the ownership mismatch
# between the checkout and the root container.
make podman GOFLAGS=-buildvcs=false \
    EXTRA_BUILDTAGS=containers_image_openpgp 2>&1 | tail -3
[ -x bin/podman ] || {
    echo "the engine did not build" >&2
    exit 1
}
strip bin/podman

tree=$work/podman
mkdir -p "$tree/bin"
cp bin/podman "$tree/bin/podman"
# The copies ship without setuid bits; see the header for why the
# mapping and fuse-mount helpers are the host's job.
for helper in crun conmon passt fuse-overlayfs netavark aardvark-dns
do
    cp -p "/usr/bin/$helper" "$tree/bin/$helper"
done
cp -p /usr/libexec/catatonit/catatonit "$tree/bin/catatonit"
# pasta is a symlink to passt on the host; podman looks for pasta by
# name, so the same link goes beside the copy.
ln -s passt "$tree/bin/pasta"
# passt execs the .avx2 build beside itself when the CPU has AVX2.
# aarch64 ships none, and the plain build runs there.
if [ -f /usr/bin/passt.avx2 ]; then
    cp -p /usr/bin/passt.avx2 "$tree/bin/passt.avx2"
fi
cd "$OLDPWD"

# The wrapper is a standalone file next to this script; its header
# explains the config files and the saved-namespace handling.
cp podman-run "$tree/podman-run"
chmod 755 "$tree/podman-run"

for needed in \
    "$tree/bin/podman" \
    "$tree/bin/crun" \
    "$tree/bin/conmon" \
    "$tree/bin/catatonit" \
    "$tree/bin/pasta" \
    "$tree/bin/passt" \
    "$tree/bin/netavark" \
    "$tree/bin/aardvark-dns" \
    "$tree/bin/fuse-overlayfs" \
    "$tree/podman-run"
do
    [ -e "$needed" ] || {
        echo "the tree is missing $needed" >&2
        exit 1
    }
done

if [ -f /usr/bin/passt.avx2 ] && [ ! -e "$tree/bin/passt.avx2" ]; then
    echo "the tree is missing $tree/bin/passt.avx2" >&2
    exit 1
fi

if [ -f update.pub ]; then
    trust="key = \"$PWD/update.pub\""
else
    trust="unsigned = true"
fi

mkdir -p dist
export PODMAN_VERSION=$version
cp onelf.toml "$tree/onelf.toml"
cat >> "$tree/onelf.toml" <<EOF

[update]
url = "https://github.com/onelf-pkgs/podman/releases/latest/download/podman-$arch.onelf"
revision = $revision
$trust
EOF

onelf build "$tree" -o "dist/podman-$arch.onelf"

ls -l dist
