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
# beside the engine; the wrapper puts bin/ ahead of PATH, which is
# where podman looks all of them up.
#
# Bundling runs before packing, in two steps rather than one `onelf
# build`: the library bundler rewrites every binary to reach lib/ and
# that rewrite strips setuid, and the newuidmap, newgidmap and
# fusermount3 copies must keep theirs. The bits go back after the
# bundler has done its work, and packing snapshots the modes as they
# then stand. Packing is explicit rather than recipe-driven for the
# same reason: pack does not read onelf.toml, and its flags cover
# everything the package needs.
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

tree=$work/podman
mkdir -p "$tree/bin"
cp bin/podman "$tree/bin/podman"
# -p keeps the setuid bits: podman checks newuidmap carries one before
# it will use it for rootless mapping, and fusermount3 needs it to
# mount where the kernel's overlay is out of reach.
for helper in crun conmon passt fuse-overlayfs netavark aardvark-dns \
    fusermount3 newuidmap newgidmap
do
    cp -p "/usr/bin/$helper" "$tree/bin/$helper"
done
cp -p /usr/libexec/catatonit/catatonit "$tree/bin/catatonit"
# pasta is a symlink to passt on the host; podman looks for pasta by
# name, so the same link goes beside the copy.
ln -s passt "$tree/bin/pasta"
cd "$OLDPWD"

cat > "$tree/podman-run" <<'EOF'
#!/bin/sh
# podman execs its helpers by name: crun, conmon, catatonit, pasta,
# netavark, aardvark-dns, fuse-overlayfs and the setuid newuidmap and
# newgidmap all come from bin/ beside this script, put ahead of the
# host's PATH. The caller's working directory is kept: podman resolves
# relative -v mounts against it.
self=$0
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case $link in
    /*) self=$link ;;
    *) self=${self%/*}/$link ;;
    esac
done
root=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)
PATH=$root/bin:$PATH
export PATH
exec "$root/bin/podman" "$@"
EOF
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
    "$tree/bin/fusermount3" \
    "$tree/bin/newuidmap" \
    "$tree/bin/newgidmap" \
    "$tree/podman-run"
do
    [ -e "$needed" ] || {
        echo "the tree is missing $needed" >&2
        exit 1
    }
done

# The library bundler scans the tree's binaries, copies their closure
# into lib/ and rewrites them to reach it, clearing the setuid bits of
# the trio on the way. They go back once the rewriting is done; the
# packed manifest records modes as they stand at pack time.
onelf bundle-libs "$tree"
chmod 4755 "$tree/bin/newuidmap" "$tree/bin/newgidmap" \
    "$tree/bin/fusermount3"

if [ -f update.pub ]; then
    trust="--update-key $PWD/update.pub"
else
    trust="--update-unsigned"
fi

mkdir -p dist
onelf pack "$tree" --command podman-run --name podman \
    --level 22 --payload stipple --needs-setuid \
    --update-url "https://github.com/onelf-pkgs/podman/releases/latest/download/podman-$arch.onelf" \
    --update-revision "$revision" \
    $trust \
    -o "dist/podman-$arch.onelf"

ls -l dist
