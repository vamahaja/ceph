#!/usr/bin/env bash
# Ceph build driver used by flake apps.
set -euo pipefail

CEPH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CEPH_ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
WITH_CRIMSON="${WITH_CRIMSON:-1}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"
# RPM packaging: distro step → thin packaging image → make-srpm + mock --rebuild.
# Thin image has packaging tools only (git/rpm-build/mock); Ceph BuildRequires are
# installed by mock into its chroot from distro repos — not via install-deps.sh.
# Base images match build-with-container.py DefaultImage.
# Set by the distro step (centos9, fedora43, …).
DISTRO="${DISTRO:-}"
MOCK_CONFIG="${MOCK_CONFIG:-}"
MOCK_BUILDHOST="${MOCK_BUILDHOST:-ceph-nix-mock}"
# SOURCE_ONLY=1 / source-only → SRPM only (skip mock rebuild).
SOURCE_ONLY="${SOURCE_ONLY:-0}"
# RPM_FORCE_IMAGE=1 → rebuild ceph-rpm-thin:<distro> even if the tag exists.
RPM_FORCE_IMAGE="${RPM_FORCE_IMAGE:-0}"

usage() {
  cat <<'EOF'
Usage: build-driver.sh <step> [args...]

Steps:
  shell         Start an interactive development shell
  configure     Run cmake configuration for the Nix environment
  build         Configure (if needed) and build (default: vstart)
                Options: tests (ninja tests), check (run-make-check)
  debs          Build Debian packages (make-debs.sh)
  centos8       Build RPMs via thin CentOS Stream 8 packaging image + mock
  centos9       Build RPMs via thin CentOS Stream 9 packaging image + mock
  centos10      Build RPMs via thin CentOS Stream 10 packaging image + mock
  fedora43      Build RPMs via thin Fedora 43 packaging image + mock
  fedora44      Build RPMs via thin Fedora 44 packaging image + mock
  rocky9        Build RPMs via thin Rocky Linux 9 packaging image + mock
  rocky10       Build RPMs via thin Rocky Linux 10 packaging image + mock
                Options: source-only (SRPM only)
                Thin image = git/rpm-build/mock only (no install-deps.sh)

Environment:
  BUILD_DIR          Build output directory (default: build)
  WITH_CRIMSON       Enable crimson build profile (default: 1)
  CONFIGURE_ARGS     Extra cmake arguments for the Nix configure step
  CEPH_VERSION       Version string for package builds
  DEB_DISTRO         Target distro codename for debs (default: noble)
  SOURCE_ONLY        1 = SRPM only (same as source-only)
  RPM_FORCE_IMAGE    1 = rebuild ceph-rpm-thin:<distro> even if tag exists
  MOCK_CONFIG        mock chroot config (default: from distro)
  MOCK_BUILDHOST     Fixed %%_buildhost (default: ceph-nix-mock)
  SOURCE_DATE_EPOCH  Unix timestamp for reproducible RPM timestamps
  CONTAINER_RUNTIME  Override container CLI (podman or docker)
EOF
}

require_nix_shell() {
  if [ -z "${IN_NIX_SHELL:-}" ]; then
    echo "error: run inside the Nix development environment (nix develop)" >&2
    exit 1
  fi
}

has_build_dir() {
  [ -d "$BUILD_DIR" ] && [ -f "$BUILD_DIR/build.ninja" ]
}

nix_pkg_cflags() {
  local flags="" pkg
  for pkg in openssl snappy lz4 libzstd zlib; do
    if pkg-config --exists "$pkg" 2>/dev/null; then
      flags+=" $(pkg-config --cflags-only-I "$pkg" 2>/dev/null)"
    fi
  done
  echo "$flags"
}

nix_cmake_prefix_path() {
  local paths=() pkg
  for pkg in openssl snappy lz4 libzstd zlib rocksdb boost; do
    if pkg-config --exists "$pkg" 2>/dev/null; then
      paths+=("$(pkg-config --variable=prefix "$pkg")")
    fi
  done
  local IFS=:
  echo "${paths[*]}"
}

run_configure() {
  if has_build_dir; then
    echo "Build directory '$BUILD_DIR' already configured"
    return 0
  fi

  if [ -d .git ]; then
    git submodule update --init --recursive --recommend-shallow
  fi

  local build_type=RelWithDebInfo
  if [ -d .git ]; then
    build_type=Debug
  fi

  local cmake_args=(
    -GNinja
    -DWITH_PYTHON3=3
    -DCMAKE_BUILD_TYPE="$build_type"
    -DCMAKE_C_COMPILER="${CC:-gcc}"
    -DCMAKE_CXX_COMPILER="${CXX:-g++}"
    -DPython3_EXECUTABLE="$(command -v python3)"
  )

  if pkg-config --exists openssl 2>/dev/null; then
    cmake_args+=(-DOPENSSL_ROOT_DIR="$(pkg-config --variable=prefix openssl)")
  elif [ -n "${OPENSSL_ROOT_DIR:-}" ]; then
    cmake_args+=(-DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR")
  fi

  if type ccache >/dev/null 2>&1; then
    cmake_args+=(-DWITH_CCACHE=ON)
  elif type sccache >/dev/null 2>&1; then
    cmake_args+=(-DWITH_SCCACHE=ON)
  fi

  if [ -n "$WITH_CRIMSON" ]; then
    cmake_args+=(-DWITH_CRIMSON=ON)
  fi

  # Prefer nixpkgs libraries over bundled submodules where the bundled
  # build cannot see isolated Nix include paths. Keep bundled Boost: the
  # system package must match Python for boost_python, which is fragile.
  cmake_args+=(
    -DWITH_SYSTEM_ROCKSDB=ON
    -DWITH_QATLIB=OFF
    -DWITH_QATZIP=OFF
  )

  local pkg_cflags
  pkg_cflags="$(nix_pkg_cflags)"
  export CFLAGS="${CFLAGS:-}${pkg_cflags}"
  export CXXFLAGS="${CXXFLAGS:-}${pkg_cflags}"

  local prefix_path
  prefix_path="$(nix_cmake_prefix_path)"
  if [ -n "$prefix_path" ]; then
    cmake_args+=(-DCMAKE_PREFIX_PATH="$prefix_path")
  fi

  if [ -n "$CONFIGURE_ARGS" ]; then
    # shellcheck disable=SC2206
    local extra_args=( $CONFIGURE_ARGS )
    cmake_args+=("${extra_args[@]}")
  fi

  mkdir -p "$BUILD_DIR"
  (
    cd "$BUILD_DIR"
    cmake "${cmake_args[@]}" ..
    cat <<EOF > ceph.conf
[global]
plugin dir = lib
erasure code dir = lib
EOF
  )

  echo "Configured Ceph in '$BUILD_DIR'"
}

run_build() {
  local mode=vstart
  while [ $# -gt 0 ]; do
    case "$1" in
      tests)
        mode=tests
        shift
        ;;
      check)
        mode=check
        shift
        ;;
      -h|--help|help)
        usage
        return 0
        ;;
      *)
        echo "error: unknown build argument: $1" >&2
        echo "usage: build-driver.sh build [tests|check]" >&2
        exit 1
        ;;
    esac
  done

  case "$mode" in
    vstart)
      run_configure
      cd "$BUILD_DIR"
      ninja vstart
      ;;
    tests)
      export FOR_MAKE_CHECK=1
      run_configure
      cd "$BUILD_DIR"
      ninja tests
      ;;
    check)
      export FOR_MAKE_CHECK=1
      ./run-make-check.sh
      ;;
  esac
}

fake_os_release() {
  local profile="${1:-ubuntu}"
  case "$profile" in
    ubuntu*|noble|ubuntu24.04)
      export ID=ubuntu
      export VERSION_ID=24.04
      export VERSION_CODENAME=noble
      ;;
    debian*|trixie|debian13)
      export ID=debian
      export VERSION_ID=13
      export VERSION_CODENAME=trixie
      ;;
    centos*|rocky*|fedora*|el*)
      export ID=centos
      export VERSION_ID=9
      ;;
    *)
      export ID=ubuntu
      export VERSION_ID=24.04
      export VERSION_CODENAME=noble
      ;;
  esac
}

run_debs() {
  local outdir="${1:-debs}"
  local version="${CEPH_VERSION:-}"
  local distro="${DEB_DISTRO:-noble}"
  fake_os_release "$distro"
  mkdir -p "$outdir"
  if [ -n "$version" ]; then
    ./make-debs.sh "$outdir" "$version" "$distro"
  else
    ./make-debs.sh "$outdir"
  fi
}

ceph_rpm_version() {
  if [ -n "${CEPH_VERSION:-}" ]; then
    echo "$CEPH_VERSION"
  else
    git describe --match 'v*' | sed 's/^v//'
  fi
}

# Prefer flake/shell SOURCE_DATE_EPOCH; else last git commit time.
resolve_source_date_epoch() {
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    echo "$SOURCE_DATE_EPOCH"
  elif [ -d .git ]; then
    git log -1 --pretty=%ct
  else
    echo "error: SOURCE_DATE_EPOCH is unset and no .git tree is available" >&2
    exit 1
  fi
}

container_runtime() {
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
      echo "error: CONTAINER_RUNTIME='$CONTAINER_RUNTIME' not found on PATH" >&2
      exit 1
    fi
    echo "$CONTAINER_RUNTIME"
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    echo podman
  elif command -v docker >/dev/null 2>&1; then
    echo docker
  else
    echo "error: RPM packaging requires podman or docker on PATH" >&2
    exit 1
  fi
}

# Canonical RPM distro step names (build-with-container.py DistroKind).
normalize_rpm_distro() {
  local raw="${1:-}"
  case "$raw" in
    centos8|centos9|centos10|fedora43|fedora44|rocky9|rocky10)
      echo "$raw"
      ;;
    *)
      echo "error: unknown RPM distro '$raw'" >&2
      echo "valid: centos8 centos9 centos10 fedora43 fedora44 rocky9 rocky10" >&2
      exit 1
      ;;
  esac
}

# Fixed thin-image FROM values (same as build-with-container.py DefaultImage).
rpm_base_image_for() {
  case "$1" in
    centos10) echo "quay.io/centos/centos:stream10" ;;
    centos8) echo "quay.io/centos/centos:stream8" ;;
    centos9) echo "quay.io/centos/centos:stream9" ;;
    rocky9) echo "docker.io/rockylinux/rockylinux:9" ;;
    rocky10) echo "docker.io/rockylinux/rockylinux:10" ;;
    fedora43) echo "registry.fedoraproject.org/fedora:43" ;;
    fedora44) echo "registry.fedoraproject.org/fedora:44" ;;
    *)
      echo "error: no base image for distro '$1'" >&2
      exit 1
      ;;
  esac
}

host_rpm_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|ppc64le|s390x) echo "$arch" ;;
    armv7l) echo armhfp ;;
    *) echo x86_64 ;;
  esac
}

# Apply DISTRO → thin image FROM (RPM_BASE_IMAGE) and local tag (CEPH_RPM_IMAGE).
apply_rpm_distro() {
  if [ -z "${DISTRO:-}" ]; then
    echo "error: DISTRO is not set (use a distro step, e.g. centos9)" >&2
    exit 1
  fi
  DISTRO="$(normalize_rpm_distro "$DISTRO")"
  RPM_BASE_IMAGE="$(rpm_base_image_for "$DISTRO")"
  # Distinct from legacy fat ceph-rpm:<distro> images that baked install-deps.sh.
  CEPH_RPM_IMAGE="ceph-rpm-thin:${DISTRO}"
  export DISTRO RPM_BASE_IMAGE CEPH_RPM_IMAGE
}

# Derive mock config for DISTRO.
default_mock_config() {
  local arch
  arch="$(host_rpm_arch)"
  case "${DISTRO:-fedora43}" in
    fedora43) echo "fedora-43-${arch}" ;;
    fedora44) echo "fedora-44-${arch}" ;;
    # +epel configs also enable CRB/PowerTools needed for Ceph BuildRequires.
    centos8) echo "centos-stream+epel-8-${arch}" ;;
    centos9) echo "centos-stream+epel-9-${arch}" ;;
    centos10) echo "centos-stream+epel-10-${arch}" ;;
    rocky9) echo "rocky+epel-9-${arch}" ;;
    rocky10) echo "rocky+epel-10-${arch}" ;;
    *) echo "fedora-43-${arch}" ;;
  esac
}

container_image_exists() {
  local runtime="$1" image="$2"
  "$runtime" image exists "$image" 2>/dev/null \
    || "$runtime" image inspect "$image" >/dev/null 2>&1
}

# Local thin packaging image tag (always ceph-rpm-thin:<distro>).
resolve_packaging_image() {
  apply_rpm_distro
  echo "$CEPH_RPM_IMAGE"
}

# Build a thin packaging image: packaging tools only (no install-deps.sh /
# buildcontainer-setup.sh). Ceph BuildRequires are resolved later by mock.
run_packaging_image() {
  local runtime base image
  apply_rpm_distro
  runtime="$(container_runtime)"
  base="$RPM_BASE_IMAGE"
  image="$CEPH_RPM_IMAGE"

  echo "Building thin packaging image (no install-deps.sh)"
  echo "  distro: $DISTRO"
  echo "  FROM:   $base"
  echo "  tag:    $image"
  echo "  packages: git rpm-build python3 wget make mock (+ repo enablement)"

  # Inline Containerfile keeps packaging independent of Dockerfile.build.
  # Do not install "curl": EL9 base images ship curl-minimal, which conflicts
  # with the full curl package. curl-minimal already provides /usr/bin/curl.
  "$runtime" build --pull \
    -t "$image" \
    --build-arg "BASE=$base" \
    -f - <<'EOF'
ARG BASE
FROM $BASE
# Thin packaging toolchain only. Full Ceph BuildRequires come from mock.
RUN set -eux; \
    if command -v dnf >/dev/null 2>&1; then PM=dnf; else PM=yum; fi; \
    $PM -y install dnf-plugins-core || true; \
    if [ -f /etc/fedora-release ]; then \
      $PM -y install git rpm-build python3 which wget make mock; \
    else \
      $PM config-manager --set-enabled crb 2>/dev/null \
        || $PM config-manager --set-enabled CRB 2>/dev/null \
        || $PM config-manager --set-enabled powertools 2>/dev/null \
        || $PM config-manager --set-enabled PowerTools 2>/dev/null \
        || true; \
      $PM -y install epel-release || true; \
      $PM -y install git rpm-build python3 which wget make mock; \
    fi; \
    $PM clean all || true; \
    rm -rf /var/cache/dnf/* /var/cache/yum/* || true
EOF

  if ! container_image_exists "$runtime" "$image"; then
    echo "error: image $image not found after build" >&2
    "$runtime" images >&2 || true
    exit 1
  fi
  echo "$image ready (thin packaging tools; Ceph deps via mock BuildRequires)"
}

# Run a bash -lc script inside the thin packaging image with the Ceph tree mounted.
# Extra args before the script are passed to the container runtime (e.g. --privileged).
run_in_packaging_image() {
  local script="${*: -1}"
  local runtime run_args=() image
  apply_rpm_distro
  runtime="$(container_runtime)"
  if [ "$#" -gt 1 ]; then
    run_args=("${@:1:$#-1}")
  fi

  image="$(resolve_packaging_image)"
  local mock_cfg="${MOCK_CONFIG:-$(default_mock_config)}"
  local sde
  sde="$(resolve_source_date_epoch)"

  echo "Using $runtime with image $image (distro=$DISTRO) for RPM packaging"
  echo "mock config: $mock_cfg"

  # :Z is required on SELinux hosts (Fedora) so the container can write
  # tarballs / SRPMs / rpmbuild outputs into the bind mount.
  "$runtime" run --rm -i \
    "${run_args[@]}" \
    -v "$CEPH_ROOT:/src:Z" \
    -w /src \
    -e "CEPH_VERSION=${CEPH_VERSION:?CEPH_VERSION must be set for container RPM builds}" \
    -e "DISTRO=$DISTRO" \
    -e "MOCK_CONFIG=$mock_cfg" \
    -e "SOURCE_DATE_EPOCH=$sde" \
    -e "MOCK_BUILDHOST=$MOCK_BUILDHOST" \
    -e "FOR_MAKE_CHECK=0" \
    -e "WITH_CRIMSON=${WITH_CRIMSON:-}" \
    "$image" \
    bash -lc "$script"
}

run_source_rpm() {
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  run_in_packaging_image "$(cat <<'EOS'
set -euo pipefail
command -v git >/dev/null
command -v rpmbuild >/dev/null
command -v python3 >/dev/null
echo "Building SRPM for version $CEPH_VERSION (thin image; no install-deps.sh)"
./make-srpm.sh "$CEPH_VERSION"
EOS
)"
}

run_rpm() {
  # make-srpm.sh then mock --rebuild; mock pulls BuildRequires from distro repos.
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch)"
  export SOURCE_DATE_EPOCH

  run_in_packaging_image --privileged "$(cat <<'EOS'
set -euo pipefail
command -v git >/dev/null
command -v rpmbuild >/dev/null
command -v python3 >/dev/null
command -v mock >/dev/null

echo "Building SRPM for version $CEPH_VERSION (thin image; no install-deps.sh)"
./make-srpm.sh "$CEPH_VERSION"

srpm=$(ls -1 ceph-*.src.rpm | head -n1)
topdir=/src/rpmbuild
mkdir -p "$topdir"

mock_cfg_file="$topdir/ceph-nix-mock.cfg"
cat > "$mock_cfg_file" <<EOF
include("/etc/mock/${MOCK_CONFIG}.cfg")
config_opts['environment']['SOURCE_DATE_EPOCH'] = '${SOURCE_DATE_EPOCH}'
config_opts['macros']['%use_source_date_epoch_as_buildtime'] = '1'
config_opts['macros']['%clamp_mtime_to_source_date_epoch'] = '1'
config_opts['macros']['%_buildhost'] = '${MOCK_BUILDHOST}'
config_opts['hostname'] = '${MOCK_BUILDHOST}'
EOF
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH MOCK_BUILDHOST=$MOCK_BUILDHOST"
echo "Rebuilding $srpm with mock -r $mock_cfg_file"
echo "Ceph BuildRequires will be installed by mock into its chroot from distro repos"
mock -r "$mock_cfg_file" --resultdir="$topdir" --rebuild "$srpm"
EOS
)"
}

# Build/reuse thin packaging image, then produce SRPM/binary RPMs inside it.
ensure_packaging_image() {
  local runtime image
  apply_rpm_distro
  runtime="$(container_runtime)"
  image="$CEPH_RPM_IMAGE"

  if [ "${RPM_FORCE_IMAGE:-0}" = 1 ] || ! container_image_exists "$runtime" "$image"; then
    run_packaging_image
  else
    echo "Using existing image $image (RPM_FORCE_IMAGE=1 to rebuild)"
  fi
}

# Ensure thin packaging image + SRPM/binary RPMs for DISTRO.
run_distro_rpm() {
  local source_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      source-only)
        source_only=1
        shift
        ;;
      -h|--help|help)
        usage
        return 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        echo "usage: build-driver.sh <distro> [source-only]" >&2
        exit 1
        ;;
    esac
  done

  case "${SOURCE_ONLY:-0}" in
    1|true|yes|YES|True) source_only=1 ;;
  esac

  if [ ! -d "$CEPH_ROOT/.git" ]; then
    echo "error: RPM steps need a git checkout (found no .git under $CEPH_ROOT)" >&2
    echo "run from the tree: nix develop .#packages -c ./nix/build-driver.sh <distro>" >&2
    echo "(nix run .#<distro> executes from the flake store copy without .git)" >&2
    exit 1
  fi

  apply_rpm_distro
  ensure_packaging_image

  if [ "$source_only" = 1 ]; then
    echo "SOURCE_ONLY: building SRPM inside $DISTRO image ($CEPH_RPM_IMAGE)"
    run_source_rpm
  else
    echo "Building binary RPMs with mock inside $DISTRO image ($CEPH_RPM_IMAGE)"
    run_rpm
  fi
}

main() {
  local step="${1:-build}"
  shift || true

  require_nix_shell

  case "$step" in
    configure) run_configure ;;
    build) run_build "$@" ;;
    debs) run_debs "$@" ;;
    centos8|centos9|centos10|fedora43|fedora44|rocky9|rocky10)
      DISTRO="$step"
      run_distro_rpm "$@"
      ;;
    shell) exec "${SHELL:-bash}" ;;
    -h|--help|help) usage ;;
    *)
      echo "error: unknown step: $step" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
