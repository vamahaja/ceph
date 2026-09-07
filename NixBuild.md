# Build Ceph with Nix

The Ceph project includes a Nix flake that provides a hermetic, reproducible build environment for compiling Ceph on Linux without installing distribution packages on the host. Day-to-day compiles stay in the Nix shell; RPM packaging has two modes:

* **Default (nested thin image):** build-driver starts a distro OCI image (`ceph-rpm-thin:<distro>`, git / rpm-build / mock) via podman and runs `make-srpm` + `mock --rebuild` inside it.
* **On-host (`on-host` / `ON_HOST=1`):** skip nested thin-image podman; run the same packaging steps on the **current node**. Use when already inside a packaging environment that provides mock (and hermetic tools when needed). Supports `source-only`, online mock, `hermetic-lock`, and `hermetic` (offline **package** rebuild).

The flake pins compilers, libraries, and tools via `nixpkgs`, so builds are less sensitive to the host distribution. Dependencies are declared in `nix/deps.nix` and mirror the build profiles defined in `debian/control` (`pkg.ceph.check`, `pkg.ceph.crimson`, and packaging tools).

# Prerequisites

* [Nix](https://nixos.org/download.html) with flakes enabled
* Git (flake inputs are resolved from the git tree)
* A Linux system (`x86_64-linux` is the primary target)
* `podman` or `docker` on PATH for the **default nested thin-image** path; also needed **on-host** for hermetic bootstrap export (`podman`/`skopeo` on the packaging host)
* For `on-host`: packaging tools on the node (`git`, `rpm-build`, `mock`; hermetic also needs `mock-hermetic-repo`, `createrepo_c`, `podman`, `skopeo`)

On first use, generate the lock file:

```
nix flake update
```

If your Nix installation does not enable flakes globally, pass `--extra-experimental-features 'nix-command flakes'` to every `nix` command below, or add that setting to `~/.config/nix/nix.conf`.

# flake.nix Introduction

The flake lives at the root of the ceph.git tree in `flake.nix`. Supporting files are under `nix/`:

| File | Role |
|------|------|
| `flake.nix` | Flake entry point: dev shells, apps, and packages |
| `nix/deps.nix` | Ceph build dependency lists and profile composition |
| `nix/build-driver.sh` | Build step driver (configure, build, debs, RPM distros) |

To enter the default development shell:

```
nix develop
```

This drops you into a shell with GCC 14, CMake, Ninja, Boost, RocksDB, and the rest of the dependencies needed for a full developer build (including make-check and crimson profiles).

At any time, `nix flake show` lists available outputs, and `./nix/build-driver.sh --help` lists build steps.

# Development Shells

The flake defines several `devShell` variants. Select one with `nix develop .#<name>`:

| Shell | Description |
|-------|-------------|
| `default` | Full developer environment: base + make-check + crimson + packaging tools |
| `minimal` | Core compile dependencies only (no make-check, crimson, or packaging extras) |
| `crimson` | Base + crimson dependencies, without make-check extras |
| `packages` | Base + crimson + packaging tools (`debhelper`, `rpmbuild`, etc.) |

Examples:

```
nix develop
nix develop .#minimal
nix develop .#packages
```

Inside a dev shell, the environment sets:

* `CC` / `CXX` to GCC 14
* `FOR_MAKE_CHECK` and `WITH_CRIMSON` according to the selected shell
* `SOURCE_DATE_EPOCH` set from the flake's last git commit time
* `CEPH_NIX_DEPS=1` to mark the Nix-provided environment

# build-driver.sh Introduction

The script `nix/build-driver.sh` orchestrates common Ceph build tasks. It must be run inside a Nix development shell (or via `nix develop -c` / `nix run`).

Default build (configure if needed, then `ninja vstart`):

```
nix develop -c ./nix/build-driver.sh build
```

Other common invocations:

```
BUILD_DIR=build.nix nix develop -c ./nix/build-driver.sh build
CONFIGURE_ARGS="-DWITH_RBD_MIRROR=OFF" nix develop -c ./nix/build-driver.sh configure
nix develop -c ./nix/build-driver.sh build tests
nix develop -c ./nix/build-driver.sh build check
nix develop .#packages -c ./nix/build-driver.sh debs
nix develop .#packages -c ./nix/build-driver.sh centos9
nix develop .#packages -c ./nix/build-driver.sh centos9 on-host
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic-lock on-host
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic on-host
ON_HOST=1 nix develop .#packages -c ./nix/build-driver.sh centos9
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic-lock
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic
nix develop .#packages -c ./nix/build-driver.sh fedora43 -- source-only
```

RPM steps need a real git checkout (for `git describe` / `make-srpm.sh`). Prefer `nix develop … -c ./nix/build-driver.sh <distro>` over `nix run .#<distro>` (the latter runs from the flake store copy without `.git`).

## Common Steps

* `configure` — Run cmake configuration for the Nix environment
* `build` — Configure (if needed) and compile; default `vstart`, or `tests` / `check`
* `debs` — Build Debian packages via `make-debs.sh`
* `centos8` / `centos9` / `centos10` / `fedora43` / `fedora44` / `rocky9` / `rocky10` — RPM packaging; options: `source-only`, `hermetic-lock`, `hermetic`, `on-host`
  * default: nested thin `ceph-rpm-thin:<distro>` image + `make-srpm` + `mock`
  * `on-host`: no nested thin image; same modes on the current node (see [On-host RPM packaging](#on-host-rpm-packaging))
* `shell` — Start an interactive shell (when already inside `nix develop`)

### Custom Commands

Any command can be run inside the Nix development shell without using `build-driver.sh`:

```
nix develop -c shellcheck nix/build-driver.sh
```

Or enter the shell interactively and run commands by hand:

```
nix develop
./nix/build-driver.sh configure
cd build && ninja vstart
```

## Nix Apps

The flake also exposes steps as Nix apps, invocable without manually entering a shell first:

```
nix run .#configure
nix run .#build
nix run .#build -- tests
nix run .#build -- check
nix run .#debs
```

For RPM distro apps, use the git tree instead:

```
nix develop .#packages -c ./nix/build-driver.sh centos9
nix develop .#packages -c ./nix/build-driver.sh centos9 on-host
nix develop .#packages -c ./nix/build-driver.sh fedora43 -- source-only
# Args after -- are forwarded by flake apps:
ON_HOST=1 nix run .#centos9
nix run .#centos9 -- on-host
```

Apps bundle the required packages and environment variables. They are convenient for one-shot CI jobs; for iterative development, `nix develop` is usually more flexible.

# Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_DIR` | `build` | CMake/Ninja output directory |
| `WITH_CRIMSON` | `1` in default shell | Enable crimson build profile |
| `CONFIGURE_ARGS` | (empty) | Extra cmake arguments for `build-driver.sh configure` |
| `CEPH_VERSION` | (from git) | Version string for package builds |
| `SOURCE_ONLY` | `0` | `1` = SRPM only (same as `source-only`) |
| `HERMETIC_LOCK` | `0` | `1` = lock BuildRequires + local repo (same as `hermetic-lock`) |
| `HERMETIC` | `0` | `1` = offline hermetic **package** rebuild (same as `hermetic`) |
| `ON_HOST` | `0` | `1` = package on current node (same as `on-host`; no nested thin image) |
| `RPM_FORCE_IMAGE` | `0` | `1` = rebuild `ceph-rpm-thin:<distro>` even if the tag exists |
| `MOCK_CONFIG` | from distro step | mock chroot config |
| `MOCK_BUILDHOST` | `ceph-nix-mock` | Fixed RPM `%_buildhost` |
| `SOURCE_DATE_EPOCH` | flake `lastModified` (or git) | Reproducible timestamps |
| `CONTAINER_RUNTIME` | (auto: podman, else docker) | Override container CLI (nested thin-image path) |

Example disabling crimson for a minimal configure:

```
WITH_CRIMSON= nix develop .#minimal -c ./nix/build-driver.sh configure
```

# Package Builds

## Debian packages

`build-driver.sh debs` calls `make-debs.sh`, which reads the host `/etc/os-release` for `ID` / `VERSION_CODENAME`.

```
nix develop .#packages -c ./nix/build-driver.sh debs
# or: nix run .#debs
```

Output is written under `debs/` (or a path passed as the first argument).

## RPM packages

Each distro is its own build-driver step. Choose a packaging mode:

| Mode | How to invoke | Nested thin image? | Binary / package build |
|------|---------------|--------------------|------------------------|
| Default | `… centos9` | yes (`ceph-rpm-thin:<distro>`) | `mock --rebuild` inside image |
| On-host | `… centos9 on-host` | **no** (node is packaging env) | `mock --rebuild` on current node |
| Source-only | `… centos9 source-only` (+ optional `on-host`) | yes unless `on-host` | SRPM only |
| Hermetic | `hermetic-lock` then `hermetic` (+ optional `on-host`) | yes unless `on-host` | offline `mock --hermetic-build` (**binary RPMs**, not the packaging image) |

### Default: thin packaging image

Packaging uses a **thin** image (no `Dockerfile.build` / `install-deps.sh`). Base `FROM` values match `build-with-container.py` `DefaultImage`; the local tag is `ceph-rpm-thin:<distro>`:

| Step | Thin image `FROM` | Local tag |
|------|-------------------|-----------|
| `centos8` | `quay.io/centos/centos:stream8` | `ceph-rpm-thin:centos8` |
| `centos9` | `quay.io/centos/centos:stream9` | `ceph-rpm-thin:centos9` |
| `centos10` | `quay.io/centos/centos:stream10` | `ceph-rpm-thin:centos10` |
| `fedora43` | `registry.fedoraproject.org/fedora:43` | `ceph-rpm-thin:fedora43` |
| `fedora44` | `registry.fedoraproject.org/fedora:44` | `ceph-rpm-thin:fedora44` |
| `rocky9` | `docker.io/rockylinux/rockylinux:9` | `ceph-rpm-thin:rocky9` |
| `rocky10` | `docker.io/rockylinux/rockylinux:10` | `ceph-rpm-thin:rocky10` |

```
nix develop .#packages -c ./nix/build-driver.sh centos9
nix develop .#packages -c ./nix/build-driver.sh fedora43 -- source-only
nix develop .#packages -c ./nix/build-driver.sh rocky9
RPM_FORCE_IMAGE=1 nix develop .#packages -c ./nix/build-driver.sh fedora44
```

#### What a distro step does (default / online mock)

1. Map the step name → fixed base image; tag local image as `ceph-rpm-thin:<distro>`
2. Ensure that thin image exists (skip if present unless `RPM_FORCE_IMAGE=1`)
3. Resolve `CEPH_VERSION` / `SOURCE_DATE_EPOCH` on the host (requires `.git`)
4. `podman run` with the image and `/src` bind-mount (`--privileged` only when running mock)
5. `./make-srpm.sh`
6. Unless `source-only`: `mock --rebuild` with reproducible-timestamp macros (BuildRequires from live distro repos)

### On-host RPM packaging

Use this when the **current node already provides** the packaging toolchain (mock≥5.7, and hermetic extras when needed). Nix still provides the packaging shell / flake entrypoint; build-driver does **not** start a nested `ceph-rpm-thin` container.

```
# Flag form
nix develop .#packages -c ./nix/build-driver.sh centos9 on-host
nix develop .#packages -c ./nix/build-driver.sh centos9 source-only on-host
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic-lock on-host
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic on-host

# Env form (also works with flake apps)
ON_HOST=1 nix develop .#packages -c ./nix/build-driver.sh rocky10
nix run .#centos9 -- on-host
```

#### What `on-host` does

1. Skip `ensure_packaging_image` / nested thin-image podman
2. Resolve `CEPH_VERSION` / `SOURCE_DATE_EPOCH` (set `CEPH_VERSION` explicitly if a prior step already ran `make-dist`)
3. `./make-srpm.sh` on the current node (reuses `ceph-${CEPH_VERSION}.tar.bz2` if present)
4. Then, depending on mode:
   * **default:** `mock --rebuild` on this node (BuildRequires into mock chroot)
   * **source-only:** stop after SRPM
   * **hermetic-lock:** calculate deps + local repo under `rpmbuild/hermetic/<distro>/`
   * **hermetic:** `mock --hermetic-build` offline **binary RPM** rebuild (requires prior lock/repo)

`source-only`, `hermetic-lock`, and `hermetic` remain mutually exclusive. Each may be combined with `on-host`.

#### Shared source then per-distro packaging

A common workflow is to produce the source tarball once, then package on matching environments:

1. **Once:** `nix develop .#packages -c ./make-dist "$CEPH_VERSION"` (source tarball only, not RPMs).
2. **Per distro:** on a node that already matches that distro’s packaging environment:

```
export CEPH_VERSION=…   # same string used for make-dist
nix develop .#packages -c ./nix/build-driver.sh centos9 on-host
# or: … hermetic-lock on-host ; … hermetic on-host
```

Distro authenticity comes from the **host OS / packaging environment**, not from a nested Stream9/Rocky container started by build-driver.

### Hermetic mock (locked repos, mock >= 5.7)

Opt-in two-phase flow; default distro builds stay online.

```
# 1) Online: calculate BuildRequires, write lock + download offline repo
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic-lock

# 2) Offline: rebuild from lock+repo (podman --network=none)
nix develop .#packages -c ./nix/build-driver.sh centos9 hermetic
```

Artifacts under `rpmbuild/hermetic/<distro>/` (gitignored; CI can cache):

* `buildroot_lock.json` — Mock buildroot lockfile
* `repo/` — RPMs + createrepo metadata from `mock-hermetic-repo`

`hermetic` fails if lock/repo are missing; run `hermetic-lock` first. `source-only`, `hermetic-lock`, and `hermetic` are mutually exclusive among themselves; each may be paired with `on-host`.

Thin image contents (conceptually):

```
podman build --pull -t ceph-rpm-thin:centos9 --build-arg BASE=quay.io/centos/centos:stream9 -f - <<'EOF'
ARG BASE
FROM $BASE
RUN dnf -y install dnf-plugins-core \
 && dnf config-manager --set-enabled crb || true \
 && dnf -y install epel-release || true \
 && dnf -y install git rpm-build python3 which wget make mock createrepo_c \
 && dnf clean all
EOF
```

**Where Ceph build deps come from:**

* **Nested thin-image / on-host online mock:** mock installs SRPM **BuildRequires** from CentOS/Fedora/Rocky repos into the chroot.
* **Hermetic mock (nested or on-host):** installs them from the locked local repo under `rpmbuild/hermetic/<distro>/`.

Nix does not supply those distro BuildRequires; `install-deps.sh` is not used on these RPM paths.

SRPM artifacts land in the source tree; binary RPMs under `rpmbuild/`.

# Nix Package Output

The flake defines a `packages.ceph` derivation that builds Ceph inside the Nix sandbox and installs binaries into the Nix store:

```
nix build .#ceph
```

This is experimental. It uses a minimal dependency set and may require additional CMake flags or bundled submodules for a complete build. The recommended workflow for day-to-day development is `nix develop` plus `build-driver.sh`.

# Dependency Profiles

Dependencies in `nix/deps.nix` are grouped to match `debian/control` build profiles:

* **base** — Compilers, CMake, Boost, OpenSSL, RocksDB, gRPC, Python, and other core libraries
* **makeCheck** — Python test tooling (`tox`, `coverage`, etc.) and utilities needed by `make check`
* **crimson** — Crimson-specific libraries (`c-ares`, `cryptopp`, `gnutls`, `hwloc`, `ragel`, `systemtap`, etc.)
* **packaging** — `debhelper`, `devscripts`, `dpkg`, `rpm`, `rpmbuild`

`ceph.spec.in` is **not** used by the Nix flake to discover host dependencies. For RPM packaging (nested thin image or `on-host`), mock consumes the generated spec’s BuildRequires inside its chroot.
