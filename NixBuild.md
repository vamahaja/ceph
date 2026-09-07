# Build Ceph with Nix

The Ceph project includes a Nix flake that provides a hermetic, reproducible build environment for compiling Ceph on Linux without installing distribution packages on the host. Day-to-day compiles stay in the Nix shell; RPM packaging uses a **thin** distro OCI image (git / rpm-build / mock only) plus `mock --rebuild`, so Ceph BuildRequires come from distro repos into the mock chroot — not from `install-deps.sh` or Nix.

The flake pins compilers, libraries, and tools via `nixpkgs`, so builds are less sensitive to the host distribution. Dependencies are declared in `nix/deps.nix` and mirror the build profiles defined in `debian/control` (`pkg.ceph.check`, `pkg.ceph.crimson`, and packaging tools).

# Prerequisites

* [Nix](https://nixos.org/download.html) with flakes enabled
* Git (flake inputs are resolved from the git tree)
* A Linux system (`x86_64-linux` is the primary target)
* `podman` or `docker` on the host PATH (required for the default RPM packaging path)

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
nix develop .#packages -c ./nix/build-driver.sh fedora43 -- source-only
```

RPM steps need a real git checkout (for `git describe` / `make-srpm.sh`). Prefer `nix develop … -c ./nix/build-driver.sh <distro>` over `nix run .#<distro>` (the latter runs from the flake store copy without `.git`).

## Common Steps

* `configure` — Run cmake configuration for the Nix environment
* `build` — Configure (if needed) and compile; default `vstart`, or `tests` / `check`
* `debs` — Build Debian packages via `make-debs.sh`
* `centos8` / `centos9` / `centos10` / `fedora43` / `fedora44` / `rocky9` / `rocky10` — Ensure thin `ceph-rpm-thin:<distro>` image, then `make-srpm` + `mock`; `source-only` for SRPM only
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
nix develop .#packages -c ./nix/build-driver.sh fedora43 -- source-only
```

Apps bundle the required packages and environment variables. They are convenient for one-shot CI jobs; for iterative development, `nix develop` is usually more flexible.

# Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_DIR` | `build` | CMake/Ninja output directory |
| `WITH_CRIMSON` | `1` in default shell | Enable crimson build profile |
| `CONFIGURE_ARGS` | (empty) | Extra cmake arguments for `build-driver.sh configure` |
| `CEPH_VERSION` | (from git) | Version string for package builds |
| `DEB_DISTRO` | `noble` | Target distro codename for `make-debs.sh` |
| `SOURCE_ONLY` | `0` | `1` = SRPM only (same as `source-only`) |
| `RPM_FORCE_IMAGE` | `0` | `1` = rebuild `ceph-rpm-thin:<distro>` even if the tag exists |
| `MOCK_CONFIG` | from distro step | mock chroot config |
| `MOCK_BUILDHOST` | `ceph-nix-mock` | Fixed RPM `%_buildhost` |
| `SOURCE_DATE_EPOCH` | flake `lastModified` (or git) | Reproducible timestamps for mock |
| `CONTAINER_RUNTIME` | (auto: podman, else docker) | Override container CLI |

Example disabling crimson for a minimal configure:

```
WITH_CRIMSON= nix develop .#minimal -c ./nix/build-driver.sh configure
```

# Package Builds

## Debian packages

`build-driver.sh debs` calls the existing `make-debs.sh` script. Because Nix is distribution-agnostic, the driver sets `ID`, `VERSION_ID`, and `VERSION_CODENAME` to emulate an Ubuntu 24.04 (noble) target by default. Override with `DEB_DISTRO`:

```
DEB_DISTRO=trixie nix develop .#packages -c ./nix/build-driver.sh debs
```

Output is written under `debs/` (or a path passed as the first argument).

## RPM packages

Each distro is its own build-driver step. Packaging uses a **thin** image (no `Dockerfile.build` / `install-deps.sh`). Base `FROM` values match `build-with-container.py` `DefaultImage`; the local tag is `ceph-rpm-thin:<distro>`:

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

### What a distro step does

1. Map the step name → fixed base image; tag local image as `ceph-rpm-thin:<distro>`
2. Ensure that thin image exists (skip if present unless `RPM_FORCE_IMAGE=1`)
3. Resolve `CEPH_VERSION` / `SOURCE_DATE_EPOCH` on the host (requires `.git`)
4. `podman run` with the image and `/src` bind-mount (`--privileged` only when running mock)
5. `./make-srpm.sh`
6. Unless `source-only` / `SOURCE_ONLY=1`: `mock --rebuild` with reproducible-timestamp macros

Thin image contents (conceptually):

```
podman build --pull -t ceph-rpm-thin:centos9 --build-arg BASE=quay.io/centos/centos:stream9 -f - <<'EOF'
ARG BASE
FROM $BASE
RUN dnf -y install dnf-plugins-core \
 && dnf config-manager --set-enabled crb || true \
 && dnf -y install epel-release || true \
 && dnf -y install git rpm-build python3 which wget make mock \
 && dnf clean all
EOF
```

**Where Ceph build deps come from:** mock installs SRPM **BuildRequires** into its chroot from CentOS/Fedora/Rocky repos. Nix does not supply those packages; `install-deps.sh` is not used on this path.

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

`ceph.spec.in` is **not** used by the Nix flake to discover host dependencies. For RPM packaging, mock consumes the generated spec’s BuildRequires inside its chroot.
