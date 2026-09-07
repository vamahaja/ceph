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
# HERMETIC_LOCK=1 / hermetic-lock → online lock BuildRequires + local repo.
HERMETIC_LOCK="${HERMETIC_LOCK:-0}"
# HERMETIC=1 / hermetic → offline mock --hermetic-build (needs prior hermetic-lock).
HERMETIC="${HERMETIC:-0}"
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
                Options: source-only | hermetic-lock | hermetic
                Thin image = git/rpm-build/mock>=5.7/createrepo_c (no install-deps.sh)
                hermetic-lock: online calculate-deps + mock-hermetic-repo
                hermetic: offline mock --hermetic-build (podman --network=none)

Environment:
  BUILD_DIR          Build output directory (default: build)
  WITH_CRIMSON       Enable crimson build profile (default: 1)
  CONFIGURE_ARGS     Extra cmake arguments for the Nix configure step
  CEPH_VERSION       Version string for package builds
  SOURCE_ONLY        1 = SRPM only (same as source-only)
  HERMETIC_LOCK      1 = lock BuildRequires + local repo (same as hermetic-lock)
  HERMETIC           1 = offline hermetic rebuild (same as hermetic)
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

run_debs() {
  # make-debs.sh sources the host /etc/os-release for ID / VERSION_CODENAME.
  local outdir="${1:-debs}"
  local version="${CEPH_VERSION:-}"
  mkdir -p "$outdir"
  if [ -n "$version" ]; then
    ./make-debs.sh "$outdir" "$version"
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

# Hermetic lock/repo layout: rpmbuild/hermetic/<distro>/{buildroot_lock.json,repo/}
hermetic_dir() {
  apply_rpm_distro
  echo "$CEPH_ROOT/rpmbuild/hermetic/$DISTRO"
}

hermetic_lockfile() {
  echo "$(hermetic_dir)/buildroot_lock.json"
}

hermetic_repo_dir() {
  echo "$(hermetic_dir)/repo"
}

# Require mock >= 5.7 and hermetic tooling inside the thin image (rebuild if stale).
ensure_hermetic_image_tools() {
  local runtime image
  apply_rpm_distro
  runtime="$(container_runtime)"
  image="$CEPH_RPM_IMAGE"
  if ! "$runtime" run --rm "$image" bash -lc '
    command -v mock-hermetic-repo >/dev/null &&
    command -v createrepo_c >/dev/null &&
    command -v skopeo >/dev/null &&
    command -v podman >/dev/null &&
    mock --help 2>&1 | grep -q -- --hermetic-build
  '; then
    echo "Thin image $image lacks mock hermetic tools (need mock>=5.7); rebuilding"
    run_packaging_image
  fi
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
  echo "  packages: git rpm-build python3 wget make mock createrepo_c podman skopeo (+ repo enablement)"

  # Inline Containerfile keeps packaging independent of Dockerfile.build.
  # Do not install "curl": EL9 base images ship curl-minimal, which conflicts
  # with the full curl package. curl-minimal already provides /usr/bin/curl.
  # mock >= 5.7 provides --calculate-build-dependencies, --hermetic-build,
  # and mock-hermetic-repo for locked-repo builds. podman+skopeo export the
  # ready bootstrap image into the hermetic offline repo.
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
      $PM -y install git rpm-build python3 which wget make mock createrepo_c podman skopeo; \
    else \
      $PM config-manager --set-enabled crb 2>/dev/null \
        || $PM config-manager --set-enabled CRB 2>/dev/null \
        || $PM config-manager --set-enabled powertools 2>/dev/null \
        || $PM config-manager --set-enabled PowerTools 2>/dev/null \
        || true; \
      $PM -y install epel-release || true; \
      $PM -y install git rpm-build python3 which wget make mock createrepo_c podman skopeo; \
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

# Prefer the SRPM we just built (mtime), not lexicographic ls|head (stale g462… beats ge669…).
srpm=$(ls -1t ceph-*.src.rpm | head -n1)
topdir=/src/rpmbuild
mkdir -p "$topdir"

# mock defaults rpmbuild_networking=False; WITH_CATCH2 defaults ON and CPM clones
# github.com. Disable Catch2 (tests already off in RPM) and block FetchContent.
# Seastar defaults CMAKE_CXX_STANDARD=26; el9 gcc-toolset-13 cannot enable CXX26
# (CMake try_compile for LinuxMembarrier fails). Cap at 23 for toolset-13 RPMs.
mock_cfg_file="$topdir/ceph-nix-mock.cfg"
cat > "$mock_cfg_file" <<EOF
include("/etc/mock/${MOCK_CONFIG}.cfg")
config_opts['environment']['SOURCE_DATE_EPOCH'] = '${SOURCE_DATE_EPOCH}'
config_opts['environment']['CEPH_EXTRA_CMAKE_ARGS'] = '-DWITH_CATCH2:BOOL=OFF -DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON -DCMAKE_CXX_STANDARD=23'
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

# Online: resolve BuildRequires into buildroot_lock.json + local RPM repo.
run_rpm_hermetic_lock() {
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch)"
  export SOURCE_DATE_EPOCH

  local hdir
  hdir="$(hermetic_dir)"
  mkdir -p "$hdir"

  ensure_hermetic_image_tools

  run_in_packaging_image --privileged "$(cat <<'EOS'
set -euo pipefail
command -v git >/dev/null
command -v rpmbuild >/dev/null
command -v python3 >/dev/null
command -v mock >/dev/null
command -v mock-hermetic-repo >/dev/null
command -v createrepo_c >/dev/null
command -v podman >/dev/null
command -v skopeo >/dev/null
mock --help 2>&1 | grep -q -- --calculate-build-dependencies \
  || { echo "error: mock lacks --calculate-build-dependencies (need mock>=5.7)" >&2; exit 1; }

echo "Building SRPM for version $CEPH_VERSION (hermetic-lock)"
./make-srpm.sh "$CEPH_VERSION"
srpm=$(ls -1t ceph-*.src.rpm | head -n1)

hdir=/src/rpmbuild/hermetic/${DISTRO}
calcdir=/src/rpmbuild/hermetic-calc-${DISTRO}
rm -rf "$calcdir"
mkdir -p "$hdir" "$calcdir"

# Hermetic builds require bootstrap_image_ready=True, which means the image must
# already provide dnf builddep (python3-dnf-plugins-core / dnf5-plugins). Rocky
# stock images do not; Alma/CS/Fedora usually do. Build a local ready image when
# needed so lock + offline rebuild both see the same bootstrap.
stock_bootstrap="$(python3 - <<'PY'
import pathlib, re, os
cfg = pathlib.Path(f"/etc/mock/{os.environ['MOCK_CONFIG']}.cfg")
text = cfg.read_text()
# Follow include("...") one level into templates.
m = re.search(r'include\("([^"]+)"\)', text)
if m:
    inc = pathlib.Path(m.group(1))
    if inc.exists():
        text = inc.read_text() + "\n" + text
m = re.search(r"config_opts\s*\[\s*['\"]bootstrap_image['\"]\s*\]\s*=\s*['\"]([^'\"]+)['\"]", text)
if not m:
    raise SystemExit(f"error: bootstrap_image not found in {cfg}")
print(m.group(1))
PY
)"
bootstrap_image="$stock_bootstrap"
if podman pull "$stock_bootstrap" >/dev/null; then
  :
fi
if podman run --rm "$stock_bootstrap" bash -lc \
    'rpm -q python3-dnf-plugins-core >/dev/null 2>&1 || rpm -q dnf5-plugins >/dev/null 2>&1'; then
  echo "Bootstrap image already ready: $stock_bootstrap"
else
  bootstrap_image="localhost/ceph-mock-bootstrap:${DISTRO}"
  echo "Stock bootstrap lacks builddep plugins; building ready image $bootstrap_image"
  podman build -t "$bootstrap_image" - <<EOF
FROM ${stock_bootstrap}
RUN set -eux; \\
    if command -v dnf5 >/dev/null 2>&1; then \\
      dnf5 -y install dnf5-plugins; dnf5 clean all; \\
    else \\
      dnf -y install python3-dnf-plugins-core; dnf clean all; \\
    fi; \\
    rm -rf /var/cache/dnf/* /var/cache/yum/* || true
EOF
fi

mock_cfg_file="$calcdir/ceph-nix-mock.cfg"
cat > "$mock_cfg_file" <<EOF
include("/etc/mock/${MOCK_CONFIG}.cfg")
config_opts['environment']['SOURCE_DATE_EPOCH'] = '${SOURCE_DATE_EPOCH}'
config_opts['environment']['CEPH_EXTRA_CMAKE_ARGS'] = '-DWITH_CATCH2:BOOL=OFF -DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON -DCMAKE_CXX_STANDARD=23'
config_opts['macros']['%use_source_date_epoch_as_buildtime'] = '1'
config_opts['macros']['%clamp_mtime_to_source_date_epoch'] = '1'
config_opts['macros']['%_buildhost'] = '${MOCK_BUILDHOST}'
config_opts['hostname'] = '${MOCK_BUILDHOST}'
config_opts['use_bootstrap_image'] = True
config_opts['bootstrap_image'] = '${bootstrap_image}'
config_opts['bootstrap_image_ready'] = True
EOF

echo "Calculating build deps for $srpm (online) bootstrap=$bootstrap_image"
mock -r "$mock_cfg_file" --resultdir="$calcdir" --calculate-build-dependencies "$srpm"

lockfile="$calcdir/buildroot_lock.json"
if [ ! -f "$lockfile" ]; then
  echo "error: expected $lockfile after --calculate-build-dependencies" >&2
  ls -la "$calcdir" >&2 || true
  exit 1
fi
cp -f "$lockfile" "$hdir/buildroot_lock.json"

# Metalink can pin RPM urls to incomplete ControliQ GCP mirrors (404 on some NEVRAs).
# Rewrite those rocky hosts to dl.rockylinux.org before mock-hermetic-repo.
python3 - <<'PY'
import json, os, re
from urllib.parse import urlparse, urlunparse
path = f"/src/rpmbuild/hermetic/{os.environ['DISTRO']}/buildroot_lock.json"
with open(path) as f:
    data = json.load(f)
n = 0
for rpm in data.get("buildroot", {}).get("rpms", []):
    u = rpm.get("url") or ""
    host = urlparse(u).netloc
    if not host.endswith("gcp.mirrors.ctrliq.cloud"):
        continue
    p = re.sub(r"/{2,}", "/", urlparse(u).path)
    rpm["url"] = urlunparse(("https", "dl.rockylinux.org", p, "", "", ""))
    n += 1
if n:
    with open(path, "w") as f:
        json.dump(data, f, indent=4, sort_keys=True)
        f.write("\n")
    print(f"Rewrote {n} ControliQ mirror URL(s) → dl.rockylinux.org")
PY

echo "Fetching hermetic repo into $hdir/repo"
rm -rf "$hdir/repo"
mkdir -p "$hdir/repo"
# mock-hermetic-repo's prepare_image uses skopeo --src docker, which fails for
# localhost/* images. Download RPMs first; always export bootstrap ourselves.
set +e
mock-hermetic-repo --lockfile "$hdir/buildroot_lock.json" --output-repo "$hdir/repo"
repo_rc=$?
set -e
if [ ! -d "$hdir/repo/repodata" ]; then
  echo "error: mock-hermetic-repo failed (rc=$repo_rc) and RPM repodata is missing" >&2
  exit 1
fi

# Export bootstrap image into the path mock --hermetic-build expects:
#   <repo>/<name-without-tag>@<pull_digest>/
python3 - <<'PY'
import json, os, pathlib, shutil, subprocess
lock = pathlib.Path(f"/src/rpmbuild/hermetic/{os.environ['DISTRO']}/buildroot_lock.json")
repo = pathlib.Path(f"/src/rpmbuild/hermetic/{os.environ['DISTRO']}/repo")
data = json.loads(lock.read_text())
image = data["config"]["bootstrap_image"]
pull = data["bootstrap"]["pull_digest"]
name = image.split(":", 1)[0]
dest = repo / f"{name}@{pull}"
if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)
# Do not pass --preserve-digests: local builds often need layer recompression
# when copying containers-storage → dir, and mock asserts RootFS digest instead.
cmd = [
    "skopeo", "copy",
    f"containers-storage:{image}",
    f"dir:{dest}",
]
print("Exporting bootstrap:", " ".join(cmd))
subprocess.check_call(cmd)
print("Bootstrap exported to", dest)
PY

echo "Hermetic lock ready:"
echo "  lock: $hdir/buildroot_lock.json"
echo "  repo: $hdir/repo"
EOS
)"
}

# Offline: mock --hermetic-build using prior lock+repo (outer container network=none).
run_rpm_hermetic() {
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch)"
  export SOURCE_DATE_EPOCH

  local lockfile repodir
  lockfile="$(hermetic_lockfile)"
  repodir="$(hermetic_repo_dir)"
  if [ ! -f "$lockfile" ] || [ ! -d "$repodir" ]; then
    echo "error: hermetic lock/repo missing for $DISTRO" >&2
    echo "  expected lock: $lockfile" >&2
    echo "  expected repo: $repodir" >&2
    echo "run: ./nix/build-driver.sh $DISTRO hermetic-lock" >&2
    exit 1
  fi

  ensure_hermetic_image_tools

  run_in_packaging_image --privileged --network=none "$(cat <<'EOS'
set -euo pipefail
command -v git >/dev/null
command -v rpmbuild >/dev/null
command -v python3 >/dev/null
command -v mock >/dev/null
mock --help 2>&1 | grep -q -- --hermetic-build \
  || { echo "error: mock lacks --hermetic-build (need mock>=5.7)" >&2; exit 1; }

hdir=/src/rpmbuild/hermetic/${DISTRO}
lockfile="$hdir/buildroot_lock.json"
repo="$hdir/repo"
if [ ! -f "$lockfile" ] || [ ! -d "$repo" ]; then
  echo "error: hermetic lock/repo not mounted at $hdir" >&2
  exit 1
fi

echo "Building SRPM for version $CEPH_VERSION (hermetic offline)"
./make-srpm.sh "$CEPH_VERSION"
srpm=$(ls -1t ceph-*.src.rpm | head -n1)

topdir=/src/rpmbuild
mkdir -p "$topdir"

# --hermetic-build loads /etc/mock/hermetic-build.cfg (not our ceph-nix-mock.cfg).
# Inject offline cmake knobs + disable features that fetch from the network
# during %build (Catch2 CPM, lancedb crates.io).
cat >> /etc/mock/hermetic-build.cfg <<EOF

# Injected by nix/build-driver.sh for Ceph hermetic rebuilds
config_opts['environment']['SOURCE_DATE_EPOCH'] = '${SOURCE_DATE_EPOCH}'
config_opts['environment']['CEPH_EXTRA_CMAKE_ARGS'] = '-DWITH_CATCH2:BOOL=OFF -DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON -DCMAKE_CXX_STANDARD=23'
config_opts['macros']['%use_source_date_epoch_as_buildtime'] = '1'
config_opts['macros']['%clamp_mtime_to_source_date_epoch'] = '1'
config_opts['macros']['%_buildhost'] = '${MOCK_BUILDHOST}'
config_opts['hostname'] = '${MOCK_BUILDHOST}'
# lancedb: crates.io; cephadm_bundling+pip_deps: PyPI (MarkupSafe/Jinja2)
config_opts['rpmbuild_opts'] = '--without lancedb --without cephadm_bundling'
EOF

echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH hermetic rebuild of $srpm"
echo "  lock: $lockfile"
echo "  repo: $repo"
mock --resultdir="$topdir" --hermetic-build "$lockfile" "$repo" "$srpm"
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
  local source_only=0 hermetic_lock=0 hermetic=0
  while [ $# -gt 0 ]; do
    case "$1" in
      source-only)
        source_only=1
        shift
        ;;
      hermetic-lock)
        hermetic_lock=1
        shift
        ;;
      hermetic)
        hermetic=1
        shift
        ;;
      -h|--help|help)
        usage
        return 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        echo "usage: build-driver.sh <distro> [source-only|hermetic-lock|hermetic]" >&2
        exit 1
        ;;
    esac
  done

  case "${SOURCE_ONLY:-0}" in
    1|true|yes|YES|True) source_only=1 ;;
  esac
  case "${HERMETIC_LOCK:-0}" in
    1|true|yes|YES|True) hermetic_lock=1 ;;
  esac
  case "${HERMETIC:-0}" in
    1|true|yes|YES|True) hermetic=1 ;;
  esac

  local mode_count=0
  [ "$source_only" = 1 ] && mode_count=$((mode_count + 1))
  [ "$hermetic_lock" = 1 ] && mode_count=$((mode_count + 1))
  [ "$hermetic" = 1 ] && mode_count=$((mode_count + 1))
  if [ "$mode_count" -gt 1 ]; then
    echo "error: source-only, hermetic-lock, and hermetic are mutually exclusive" >&2
    exit 1
  fi

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
  elif [ "$hermetic_lock" = 1 ]; then
    echo "HERMETIC_LOCK: locking BuildRequires for $DISTRO ($CEPH_RPM_IMAGE)"
    run_rpm_hermetic_lock
  elif [ "$hermetic" = 1 ]; then
    echo "HERMETIC: offline mock rebuild for $DISTRO ($CEPH_RPM_IMAGE)"
    run_rpm_hermetic
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
