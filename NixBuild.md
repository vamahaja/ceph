# Build Ceph with Nix

The Ceph project includes a Nix flake that provides a hermetic, reproducible build environment for compiling Ceph on Linux without installing distribution packages on the host. Day-to-day compiles stay in the Nix shell; RPM packaging optionally uses a Fedora OCI container so `rpmbuild` sees real distro macros and BuildRequires.

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
| `nix/build-driver.sh` | Build step driver (configure, build, tests, packages) |
| `nix/fedora-rpm-image.nix` | Optional pinned Fedora *base* via dockerTools (packaging uses `Dockerfile.build`) |

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

To build Ceph with the default options:

```
nix develop -c ./nix/build-driver.sh build
```

This configures the tree (via `build-driver.sh configure` if `build/` does not exist) and compiles the `vstart` targets with Ninja. The default build directory is `build` in the root of the source tree.

You can select a different build directory with the `BUILD_DIR` environment variable:

```
BUILD_DIR=build.try1 nix develop -c ./nix/build-driver.sh build
```

The tool supports multiple build steps. Steps are typically chained manually or via separate invocations. For example, run tests after a build:

```
nix develop -c ./nix/build-driver.sh tests
```

## Examples

Build from source with the default shell and build directory:

```
nix develop -c ./nix/build-driver.sh build
```

Build with a custom build directory:

```
BUILD_DIR=build.nix nix develop -c ./nix/build-driver.sh build
```

Configure only, passing extra CMake arguments:

```
CONFIGURE_ARGS="-DWITH_RBD_MIRROR=OFF" nix develop -c ./nix/build-driver.sh configure
```

Build Debian packages (uses the `packages` shell for packaging tools):

```
nix develop .#packages -c ./nix/build-driver.sh debs
```

Build RPM packages:

```
nix develop .#packages -c ./nix/build-driver.sh rpm
```

Build a source RPM only:

```
nix develop .#packages -c ./nix/build-driver.sh source-rpm
```

## Common Steps

* `configure` — Run cmake configuration for the Nix environment
* `build` — Configure (if needed) and compile `vstart` targets
* `build-tests` — Build the unit test binaries (`ninja tests`)
* `tests` — Run the full make-check test suite (`run-make-check.sh`)
* `debs` — Build Debian packages via `make-debs.sh`
* `fedora-image` — Build `ceph-fedora-rpm` via `Dockerfile.build` (same as build-with-container.py)
* `source-rpm` — Build a source RPM via `make-srpm.sh` (Fedora container by default)
* `rpm` — Build binary RPMs via `make-srpm` + `rpmbuild --rebuild` (BWC-style)
* `packages` — Build distribution packages (DEB by default)
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
nix run .#build-tests
nix run .#tests
nix run .#debs
nix run .#fedora-image
nix run .#source-rpm
nix run .#rpm
nix run .#packages
```

Apps bundle the required packages and environment variables. They are convenient for one-shot CI jobs; for iterative development, `nix develop` is usually more flexible.

# Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_DIR` | `build` | CMake/Ninja output directory |
| `FOR_MAKE_CHECK` | `1` in default shell | Enable make-check profile |
| `WITH_CRIMSON` | `1` in default shell | Enable crimson build profile |
| `CONFIGURE_ARGS` | (empty) | Extra cmake arguments for `build-driver.sh configure` |
| `CEPH_VERSION` | (from git) | Version string for package builds |
| `DEB_DISTRO` | `noble` | Target distro codename for `make-debs.sh` |
| `RPM_BACKEND` | `container` | RPM path: `container` (Fedora OCI) or `nix` (legacy in-shell) |
| `RPM_BUILDER` | `rpmbuild` | Binary builder: `rpmbuild` (BWC default) or `mock` |
| `FEDORA_IMAGE` | auto (`ceph-fedora-rpm:43` if present) | Image used when `RPM_BACKEND=container` |
| `FEDORA_BASE_IMAGE` | `registry.fedoraproject.org/fedora:43` | `FROM` for `Dockerfile.build` |
| `MOCK_CONFIG` | `fedora-<ver>-<arch>` from image | mock chroot config when `RPM_BUILDER=mock` |
| `MOCK_BUILDHOST` | `ceph-nix-mock` | Fixed RPM `%_buildhost` |
| `SOURCE_DATE_EPOCH` | flake `lastModified` (or git) | Reproducible timestamps for rpmbuild/mock |
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

Aligned with `src/script/build-with-container.py`.

### Fedora image (`Dockerfile.build`)

Build the packaging image once (same deps path as BWC):

```
nix develop .#packages -c ./nix/build-driver.sh fedora-image
```

This runs (conceptually):

```
podman build --pull -f Dockerfile.build \
  --build-arg DISTRO=$FEDORA_BASE_IMAGE \
  --build-arg FOR_MAKE_CHECK=false \
  --build-arg WITH_CRIMSON=… \
  -t ceph-fedora-rpm:43 .
```

Inside the image build, `buildcontainer-setup.sh` installs `rpmbuild`/`wget`/`curl`, then `install-deps.sh` runs **`dnf builddep ceph.spec`** (full BuildRequires), matching BWC.

### Container RPM build

1. Resolve `CEPH_VERSION` / `SOURCE_DATE_EPOCH` on the host
2. `podman run` with `ceph-fedora-rpm:43` (or `FEDORA_IMAGE`) and `/src` bind-mount
3. `./make-srpm.sh`
4. Default: `rpmbuild --rebuild` (BWC) with reproducible-timestamp macros
5. Optional: `RPM_BUILDER=mock` for mock chroot rebuilds

```
nix develop .#packages -c ./nix/build-driver.sh fedora-image
nix develop .#packages -c ./nix/build-driver.sh rpm
RPM_BUILDER=mock nix develop .#packages -c ./nix/build-driver.sh rpm
```

Legacy in-shell rebuild (not recommended):

```
RPM_BACKEND=nix nix develop .#packages -c ./nix/build-driver.sh rpm
```

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

`ceph.spec.in` is **not** used by the Nix flake to discover dependencies. It is only consumed indirectly when you run RPM packaging steps through the existing Ceph scripts (`make-srpm.sh`, `rpmbuild`).
