#!/usr/bin/env bash
# Ceph build driver used by flake apps.
set -euo pipefail

CEPH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CEPH_ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
FOR_MAKE_CHECK="${FOR_MAKE_CHECK:-1}"
WITH_CRIMSON="${WITH_CRIMSON:-1}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"
# RPM packaging follows src/script/build-with-container.py:
#   fedora-image → Dockerfile.build (install-deps / dnf builddep)
#   rpm          → make-srpm + rpmbuild --rebuild in that image
# Prefer the locally tagged ceph-fedora-rpm image when present.
# RPM_BUILDER=hermetic adds mock lockfile + offline --hermetic-build
# under podman --network=none (pins Fedora RPMs, not nixpkgs libs).
RPM_BACKEND="${RPM_BACKEND:-container}"
# rpmbuild matches BWC; mock/hermetic are opt-in.
RPM_BUILDER="${RPM_BUILDER:-rpmbuild}"
FEDORA_IMAGE="${FEDORA_IMAGE:-}"
FEDORA_BASE_IMAGE="${FEDORA_BASE_IMAGE:-registry.fedoraproject.org/fedora:43}"
FEDORA_IMAGE_FALLBACK="${FEDORA_IMAGE_FALLBACK:-$FEDORA_BASE_IMAGE}"
CEPH_FEDORA_IMAGE_NAME="${CEPH_FEDORA_IMAGE_NAME:-ceph-fedora-rpm}"
CEPH_FEDORA_IMAGE_TAG="${CEPH_FEDORA_IMAGE_TAG:-43}"
MOCK_CONFIG="${MOCK_CONFIG:-}"
MOCK_BUILDHOST="${MOCK_BUILDHOST:-ceph-nix-mock}"
HERMETIC_REPO_DIR="${HERMETIC_REPO_DIR:-hermetic-repo}"
HERMETIC_LOCKFILE="${HERMETIC_LOCKFILE:-rpmbuild/buildroot_lock.json}"
HERMETIC_FORCE_REFRESH="${HERMETIC_FORCE_REFRESH:-0}"
MOCK_MIN_VERSION="${MOCK_MIN_VERSION:-5.7}"

usage() {
  cat <<'EOF'
Usage: build-driver.sh <step> [args...]

Steps:
  configure     Run cmake configuration for the Nix environment
  build         Configure (if needed) and build vstart targets
  build-tests   Build unit tests (FOR_MAKE_CHECK=1)
  tests         Build and run the make check test suite
  debs          Build Debian packages (make-debs.sh)
  fedora-image  Build Ceph Fedora RPM image (Dockerfile.build, like BWC)
  source-rpm    Build a source RPM (Fedora container by default)
  rpm           Build binary RPMs (rpmbuild --rebuild, like BWC)
  packages      Build distro packages (DEB on Nix; RPM when requested)
  shell         Start an interactive development shell command

Environment:
  BUILD_DIR         Build output directory (default: build)
  FOR_MAKE_CHECK    Enable make-check dependencies (default: 1)
  WITH_CRIMSON      Enable crimson build profile (default: 1)
  CONFIGURE_ARGS    Extra cmake arguments for the Nix configure step
  CEPH_VERSION      Version string for package builds
  DEB_DISTRO        Target distro codename for debs (default: noble)
  RPM_BACKEND       RPM path: container (default) or nix
  RPM_BUILDER       rpmbuild (default), mock, or hermetic
  FEDORA_IMAGE      OCI image for RPM steps (auto: ceph-fedora-rpm:43)
  FEDORA_BASE_IMAGE Base for Dockerfile.build (default: fedora:43)
  MOCK_CONFIG       mock chroot config (mock/hermetic)
  MOCK_BUILDHOST    Fixed %%_buildhost (default: ceph-nix-mock)
  HERMETIC_REPO_DIR Offline RPM repo dir (default: hermetic-repo)
  HERMETIC_LOCKFILE Mock lockfile path (default: rpmbuild/buildroot_lock.json)
  HERMETIC_FORCE_REFRESH Set to 1 to redo calculate-deps / repo fetch
  SOURCE_DATE_EPOCH Unix timestamp for reproducible RPM timestamps
  CONTAINER_RUNTIME Override container CLI (podman or docker)
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
  run_configure
  cd "$BUILD_DIR"
  ninja vstart
}

run_build_tests() {
  export FOR_MAKE_CHECK=1
  run_configure
  cd "$BUILD_DIR"
  ninja tests
}

run_tests() {
  export FOR_MAKE_CHECK=1
  ./run-make-check.sh
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
    echo "error: RPM_BACKEND=container requires podman or docker on PATH" >&2
    exit 1
  fi
}

# Derive mock config name from an image ref, e.g. ceph-fedora-rpm:41 -> fedora-41-x86_64.
default_mock_config() {
  local image="${1:-$FEDORA_IMAGE_FALLBACK}"
  local tag arch
  tag="${image##*:}"
  tag="${tag%%@*}"
  if [[ ! "$tag" =~ ^[0-9]+$ ]]; then
    tag="$CEPH_FEDORA_IMAGE_TAG"
  fi
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|ppc64le|s390x) ;;
    armv7l) arch=armhfp ;;
    *) arch=x86_64 ;;
  esac
  echo "fedora-${tag}-${arch}"
}

container_image_exists() {
  local runtime="$1" image="$2"
  "$runtime" image exists "$image" 2>/dev/null \
    || "$runtime" image inspect "$image" >/dev/null 2>&1
}

# Prefer explicit FEDORA_IMAGE, else locally loaded ceph-fedora-rpm, else upstream.
resolve_fedora_image() {
  if [ -n "${FEDORA_IMAGE:-}" ]; then
    echo "$FEDORA_IMAGE"
    return
  fi
  local runtime local_image
  runtime="$(container_runtime)"
  local_image="${CEPH_FEDORA_IMAGE_NAME}:${CEPH_FEDORA_IMAGE_TAG}"
  if container_image_exists "$runtime" "$local_image"; then
    echo "$local_image"
    return
  fi
  echo "$FEDORA_IMAGE_FALLBACK"
}

# Same install path as build-with-container.py / Dockerfile.build:
# buildcontainer-setup.sh → install-deps.sh (dnf builddep ceph.spec).
# Also installs mock >= 5.7 tooling for RPM_BUILDER=hermetic / mock.
run_fedora_image() {
  local runtime base image crimson_arg
  runtime="$(container_runtime)"
  base="$FEDORA_BASE_IMAGE"
  image="${CEPH_FEDORA_IMAGE_NAME}:${CEPH_FEDORA_IMAGE_TAG}"

  # WITH_CRIMSON empty disables crimson deps in install-deps.sh (BWC convention).
  if [ -n "${WITH_CRIMSON:-}" ]; then
    crimson_arg="1"
  else
    crimson_arg=""
  fi

  # Install hermetic/mock tooling after install-deps.
  # CUSTOM_IMAGE_COMMANDS runs each line via bash -c, so keep this one logical line.
  local mock_cmds
  mock_cmds='dnf -y install mock mock-core-configs createrepo_c; dnf -y install mock-hermetic-repo 2>/dev/null || dnf -y install /usr/bin/mock-hermetic-repo 2>/dev/null || true; mock --version; command -v mock-hermetic-repo || echo "warn: mock-hermetic-repo missing"'

  echo "Building Ceph Fedora RPM image like build-with-container.py"
  echo "  base:  $base"
  echo "  tag:   $image"
  echo "  file:  Dockerfile.build"
  echo "  FOR_MAKE_CHECK=false WITH_CRIMSON=${crimson_arg:-<empty>}"
  echo "  + mock / mock-core-configs (hermetic RPM support)"

  # Mirrors Steps.BUILD_CONTAINER in build-with-container.py.
  "$runtime" build --pull \
    -t "$image" \
    --build-arg "DISTRO=$base" \
    --build-arg FOR_MAKE_CHECK=false \
    --build-arg "WITH_CRIMSON=$crimson_arg" \
    --build-arg CEPH_BASE_BRANCH=main \
    --build-arg "CUSTOM_IMAGE_COMMANDS=$mock_cmds" \
    -f "$CEPH_ROOT/Dockerfile.build" \
    "$CEPH_ROOT"

  if ! container_image_exists "$runtime" "$image"; then
    echo "error: image $image not found after build" >&2
    "$runtime" images >&2 || true
    exit 1
  fi
  export FEDORA_IMAGE="$image"
  echo "FEDORA_IMAGE=$FEDORA_IMAGE ready (deps baked via install-deps.sh + mock)"
}

# Run a bash -lc script inside the resolved Fedora image with the Ceph tree mounted.
# Extra args before the script are passed to the container runtime
# (e.g. --privileged, --network=none).
run_in_fedora() {
  local script="${*: -1}"
  local runtime run_args=() image
  runtime="$(container_runtime)"
  if [ "$#" -gt 1 ]; then
    run_args=("${@:1:$#-1}")
  fi

  image="$(resolve_fedora_image)"
  local mock_cfg="${MOCK_CONFIG:-$(default_mock_config "$image")}"
  local sde
  sde="$(resolve_source_date_epoch)"

  echo "Using $runtime with image $image for RPM packaging"
  case "$RPM_BUILDER" in
    mock|hermetic)
      echo "mock config: $mock_cfg"
      ;;
  esac
  if printf '%s\n' "${run_args[@]}" | grep -qx -- '--network=none'; then
    echo "network: none (offline / hermetic build phase)"
  fi

  # :Z is required on SELinux hosts (Fedora) so the container can write
  # tarballs / SRPMs / rpmbuild outputs into the bind mount.
  "$runtime" run --rm -i \
    "${run_args[@]}" \
    -v "$CEPH_ROOT:/src:Z" \
    -w /src \
    -e "CEPH_VERSION=${CEPH_VERSION:?CEPH_VERSION must be set for container RPM builds}" \
    -e "MOCK_CONFIG=$mock_cfg" \
    -e "SOURCE_DATE_EPOCH=$sde" \
    -e "MOCK_BUILDHOST=$MOCK_BUILDHOST" \
    -e "RPM_BUILDER=$RPM_BUILDER" \
    -e "HERMETIC_REPO_DIR=$HERMETIC_REPO_DIR" \
    -e "HERMETIC_LOCKFILE=$HERMETIC_LOCKFILE" \
    -e "HERMETIC_FORCE_REFRESH=$HERMETIC_FORCE_REFRESH" \
    -e "MOCK_MIN_VERSION=$MOCK_MIN_VERSION" \
    -e "FOR_MAKE_CHECK=0" \
    -e "WITH_CRIMSON=${WITH_CRIMSON:-}" \
    "$image" \
    bash -lc "$script"
}

run_source_rpm_nix() {
  ./make-srpm.sh "$(ceph_rpm_version)"
}

run_source_rpm_container() {
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  # Prefer an image from `fedora-image` (Dockerfile.build / install-deps).
  # On a plain Fedora base, fall back to the same setup scripts BWC uses.
  run_in_fedora "$(cat <<'EOS'
set -euo pipefail
if command -v rpmbuild >/dev/null 2>&1 && rpm --quiet --query python3-devel 2>/dev/null; then
  echo "Ceph build deps already present in image (build-with-container style)"
else
  echo "Installing Ceph build deps via buildcontainer-setup / install-deps"
  dnf -y install /usr/bin/{rpmbuild,wget,curl} git
  export CEPH_CTR_SRC=/src
  export FOR_MAKE_CHECK=false
  export CLEAN_DNF=no
  export JENKINS_HOME=/src
  bash -x /src/src/script/buildcontainer-setup.sh
fi
echo "Building SRPM for version $CEPH_VERSION"
./make-srpm.sh "$CEPH_VERSION"
EOS
)"
}

run_source_rpm() {
  case "$RPM_BACKEND" in
    container)
      run_source_rpm_container
      ;;
    nix)
      run_source_rpm_nix
      ;;
    *)
      echo "error: unknown RPM_BACKEND='$RPM_BACKEND' (use container or nix)" >&2
      exit 1
      ;;
  esac
}

run_rpm_nix() {
  local srpm
  srpm="$(ls -1 ceph-*.src.rpm 2>/dev/null | head -n1 || true)"
  if [ -z "$srpm" ]; then
    run_source_rpm_nix
    srpm="$(ls -1 ceph-*.src.rpm 2>/dev/null | head -n1)"
  fi
  if [ -z "$srpm" ]; then
    echo "error: no ceph-*.src.rpm produced" >&2
    exit 1
  fi
  local topdir="$CEPH_ROOT/rpmbuild"
  mkdir -p "$topdir"
  rpmbuild --rebuild -D"_topdir $topdir" "$srpm"
}

# Shared preamble: BWC deps (or install-deps fallback) + make-srpm.
fedora_rpm_prepare_srpm_script() {
  cat <<'EOS'
set -euo pipefail
if command -v rpmbuild >/dev/null 2>&1 && rpm --quiet --query python3-devel 2>/dev/null; then
  echo "Ceph build deps already present in image (build-with-container style)"
else
  echo "Installing Ceph build deps via buildcontainer-setup / install-deps"
  dnf -y install /usr/bin/{rpmbuild,wget,curl} git
  export CEPH_CTR_SRC=/src
  export FOR_MAKE_CHECK=false
  export CLEAN_DNF=no
  export JENKINS_HOME=/src
  bash -x /src/src/script/buildcontainer-setup.sh
fi

echo "Building SRPM for version $CEPH_VERSION inside Fedora"
./make-srpm.sh "$CEPH_VERSION"
EOS
}

write_mock_repro_cfg_script() {
  # Emits shell that writes /src/rpmbuild/ceph-nix-mock.cfg
  cat <<'EOS'
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
EOS
}

ensure_mock_hermetic_tools_script() {
  cat <<'EOS'
ensure_mock_hermetic_tools() {
  if ! command -v mock >/dev/null 2>&1; then
    dnf -y install mock mock-core-configs createrepo_c
  fi
  if ! command -v mock-hermetic-repo >/dev/null 2>&1; then
    dnf -y install mock-hermetic-repo 2>/dev/null \
      || dnf -y install /usr/bin/mock-hermetic-repo 2>/dev/null \
      || true
  fi
  if ! command -v mock-hermetic-repo >/dev/null 2>&1; then
    echo "error: mock-hermetic-repo not found (need mock >= ${MOCK_MIN_VERSION})" >&2
    exit 1
  fi
  # mock --version prints e.g. "mock-5.7" or "5.7"
  local ver
  ver="$(mock --version 2>/dev/null | head -n1 | sed -E 's/.*([0-9]+\.[0-9]+).*/\1/')"
  local min_major min_minor major minor
  min_major="${MOCK_MIN_VERSION%%.*}"
  min_minor="${MOCK_MIN_VERSION#*.}"
  min_minor="${min_minor%%.*}"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if [ -z "$ver" ] || [ "$major" -lt "$min_major" ] \
    || { [ "$major" -eq "$min_major" ] && [ "$minor" -lt "$min_minor" ]; }; then
    echo "error: mock $ver is older than required ${MOCK_MIN_VERSION}" >&2
    exit 1
  fi
  echo "mock version $ver OK (>= ${MOCK_MIN_VERSION})"
}
EOS
}

run_rpm_container_rpmbuild_or_mock() {
  local run_args=()
  if [ "$RPM_BUILDER" = mock ]; then
    run_args+=(--privileged)
  fi

  run_in_fedora "${run_args[@]}" "$(cat <<EOS
$(fedora_rpm_prepare_srpm_script)

srpm=\$(ls -1 ceph-*.src.rpm | head -n1)
topdir=/src/rpmbuild
mkdir -p "\$topdir"

echo "SOURCE_DATE_EPOCH=\$SOURCE_DATE_EPOCH MOCK_BUILDHOST=\$MOCK_BUILDHOST"
case "\${RPM_BUILDER:-rpmbuild}" in
  rpmbuild)
    echo "Rebuilding \$srpm with rpmbuild --rebuild (build-with-container style)"
    export SOURCE_DATE_EPOCH
    rpmbuild --rebuild \\
      -D"_topdir \$topdir" \\
      -D"use_source_date_epoch_as_buildtime 1" \\
      -D"clamp_mtime_to_source_date_epoch 1" \\
      -D"_buildhost \$MOCK_BUILDHOST" \\
      "\$srpm"
    ;;
  mock)
    $(ensure_mock_hermetic_tools_script)
    ensure_mock_hermetic_tools
    $(write_mock_repro_cfg_script)
    echo "Rebuilding \$srpm with mock -r \$mock_cfg_file"
    mock -r "\$mock_cfg_file" --resultdir="\$topdir" --rebuild "\$srpm"
    ;;
  *)
    echo "error: unknown RPM_BUILDER=\$RPM_BUILDER" >&2
    exit 1
    ;;
esac
EOS
)"
}

# Online phase: calculate-build-dependencies + mock-hermetic-repo (network OK).
run_rpm_hermetic_prepare() {
  run_in_fedora --privileged "$(cat <<EOS
$(fedora_rpm_prepare_srpm_script)
$(ensure_mock_hermetic_tools_script)
ensure_mock_hermetic_tools
$(write_mock_repro_cfg_script)

srpm=\$(ls -1 ceph-*.src.rpm | head -n1)
repo_dir="/src/\${HERMETIC_REPO_DIR}"
lockfile="/src/\${HERMETIC_LOCKFILE}"
stamp="\$repo_dir/.ceph-hermetic-stamp"
mkdir -p "\$(dirname "\$lockfile")" "\$repo_dir"

fingerprint="\${srpm}|\${MOCK_CONFIG}|\${SOURCE_DATE_EPOCH}"
if [ "\${HERMETIC_FORCE_REFRESH}" != 1 ] \
  && [ -f "\$lockfile" ] \
  && [ -d "\$repo_dir" ] \
  && [ -f "\$stamp" ] \
  && [ "\$(cat "\$stamp")" = "\$fingerprint" ] \
  && find "\$repo_dir" -name '*.rpm' 2>/dev/null | grep -q .; then
  echo "Reusing hermetic lockfile+repo for \$fingerprint"
  echo "Set HERMETIC_FORCE_REFRESH=1 to regenerate"
  exit 0
fi

echo "Calculating build dependencies for \$srpm (online)"
mock -r "\$mock_cfg_file" --resultdir=/src/rpmbuild --calculate-build-dependencies "\$srpm"

if [ ! -f /src/rpmbuild/buildroot_lock.json ]; then
  echo "error: buildroot_lock.json not produced in /src/rpmbuild" >&2
  ls -la /src/rpmbuild >&2 || true
  exit 1
fi
# Keep lockfile at the configured path (may already be rpmbuild/buildroot_lock.json).
if [ "\$lockfile" != /src/rpmbuild/buildroot_lock.json ]; then
  cp -f /src/rpmbuild/buildroot_lock.json "\$lockfile"
fi

echo "Materializing offline repo at \$repo_dir"
rm -rf "\$repo_dir"
mkdir -p "\$repo_dir"
mock-hermetic-repo --lockfile "\$lockfile" --output-repo "\$repo_dir"
printf '%s\n' "\$fingerprint" > "\$stamp"
echo "Hermetic prepare done: \$lockfile + \$repo_dir"
EOS
)"
}

# Offline phase: mock --hermetic-build under --network=none.
run_rpm_hermetic_build() {
  run_in_fedora --privileged --network=none "$(cat <<EOS
set -euo pipefail
$(ensure_mock_hermetic_tools_script)
ensure_mock_hermetic_tools

srpm=\$(ls -1 ceph-*.src.rpm | head -n1)
repo_dir="/src/\${HERMETIC_REPO_DIR}"
lockfile="/src/\${HERMETIC_LOCKFILE}"
topdir=/src/rpmbuild
mkdir -p "\$topdir"

if [ ! -f "\$lockfile" ]; then
  echo "error: missing hermetic lockfile \$lockfile (run prepare phase first)" >&2
  exit 1
fi
if [ ! -d "\$repo_dir" ] || ! find "\$repo_dir" -name '*.rpm' 2>/dev/null | grep -q .; then
  echo "error: hermetic repo \$repo_dir is empty or missing" >&2
  exit 1
fi

echo "Offline hermetic rebuild of \$srpm (--network=none)"
echo "  lockfile=\$lockfile"
echo "  repo=\$repo_dir"
mock --resultdir="\$topdir" --hermetic-build "\$lockfile" "\$repo_dir" "\$srpm"
EOS
)"
}

run_rpm_hermetic_container() {
  # 1) Online: make-srpm + calculate-deps + mock-hermetic-repo
  # 2) Offline: podman --network=none + mock --hermetic-build
  # Pins Fedora RPM NEVRAs via lockfile; does not use nixpkgs link libraries.
  echo "=== Hermetic RPM: prepare (network allowed) ==="
  run_rpm_hermetic_prepare
  echo "=== Hermetic RPM: build (network=none) ==="
  run_rpm_hermetic_build
}

run_rpm_container() {
  # Follow build-with-container.py Steps.SOURCE_RPM + Steps.RPM by default.
  CEPH_VERSION="$(ceph_rpm_version)"
  export CEPH_VERSION
  SOURCE_DATE_EPOCH="$(resolve_source_date_epoch)"
  export SOURCE_DATE_EPOCH

  case "$RPM_BUILDER" in
    rpmbuild|mock)
      run_rpm_container_rpmbuild_or_mock
      ;;
    hermetic)
      run_rpm_hermetic_container
      ;;
    *)
      echo "error: unknown RPM_BUILDER='$RPM_BUILDER' (use rpmbuild, mock, or hermetic)" >&2
      exit 1
      ;;
  esac
}

run_rpm() {
  case "$RPM_BACKEND" in
    container)
      run_rpm_container
      ;;
    nix)
      run_rpm_nix
      ;;
    *)
      echo "error: unknown RPM_BACKEND='$RPM_BACKEND' (use container or nix)" >&2
      exit 1
      ;;
  esac
}

run_packages() {
  local kind="${1:-auto}"
  case "$kind" in
    rpm|srpm)
      run_rpm
      ;;
    deb|debs)
      run_debs "${2:-debs}"
      ;;
    auto)
      run_debs "${2:-debs}"
      ;;
    *)
      echo "error: unknown package kind: $kind" >&2
      exit 1
      ;;
  esac
}

main() {
  local step="${1:-build}"
  shift || true

  require_nix_shell

  case "$step" in
    configure) run_configure ;;
    build) run_build ;;
    build-tests|buildtests) run_build_tests ;;
    tests|test) run_tests ;;
    debs|deb) run_debs "$@" ;;
    fedora-image|image) run_fedora_image ;;
    source-rpm|srpm) run_source_rpm ;;
    rpm) run_rpm ;;
    packages) run_packages "$@" ;;
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
