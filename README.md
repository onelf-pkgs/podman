# podman

[Podman](https://podman.io) packed for
[onelf](https://github.com/QaidVoid/onelf) packages. The engine is
upstream's and its [documentation](https://docs.podman.io) describes
it; this repository only repacks it into one file that runs on hosts
with no container tooling installed.

| | |
|---|---|
| Description | Daemonless container engine for developing, managing, and running OCI containers |
| Upstream | <https://github.com/containers/podman> |
| License | Apache-2.0 |

## The repack

- Compiles the engine from upstream's source: podman publishes no
  Linux engine binary, its releases carry only the remote client and
  the Windows and macOS installers. Signature verification uses the
  pure-Go OpenPGP path, so gpgme and its dependencies stay out of the
  bundle.
- Carries the whole helper stack podman execs by name: crun, conmon,
  catatonit, pasta, netavark, aardvark-dns, fuse-overlayfs, and the
  setuid newuidmap, newgidmap and fusermount3 that keep rootless
  operation working. The `podman-run` launcher puts bin/ ahead of the
  host's PATH, which is where podman looks all of them up, and keeps
  the caller's working directory so relative `-v` mounts resolve as
  usual.
- Bundles the container's libseccomp and glibc into lib/, so the
  packed file runs on hosts that have neither installed.
- Runs setuid binaries, so the package stays out of a user namespace,
  where a setuid bit does nothing. The library bundler's binary
  rewrite strips those bits, so bundling runs first and packing
  snapshots the tree after they are restored.
