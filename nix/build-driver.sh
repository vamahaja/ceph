#!/usr/bin/env bash
# Ceph build driver used by flake apps.
set -euo pipefail

CEPH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CEPH_ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
FOR_MAKE_CHECK="${FOR_MAKE_CHECK:-1}"
WITH_CRIMSON="${WITH_CRIMSON:-1}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: build-driver.sh <step> [args...]

Steps:
  configure     Run cmake configuration for the Nix environment
  build         Configure (if needed) and build vstart targets
  build-tests   Build unit tests (FOR_MAKE_CHECK=1)
  tests         Build and run the make check test suite
  debs          Build Debian packages (make-debs.sh)
  source-rpm    Build a source RPM (make-srpm.sh)
  rpm           Build binary RPMs from an SRPM
  packages      Build distro packages (DEB on Nix; RPM when requested)
  shell         Start an interactive development shell command

Environment:
  BUILD_DIR         Build output directory (default: build)
  FOR_MAKE_CHECK    Enable make-check dependencies (default: 1)
  WITH_CRIMSON      Enable crimson build profile (default: 1)
  CONFIGURE_ARGS    Extra cmake arguments for the Nix configure step
  CEPH_VERSION      Version string for package builds
  DEB_DISTRO        Target distro codename for debs (default: noble)
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

run_source_rpm() {
  local version="${CEPH_VERSION:-$(git describe --match 'v*' | sed 's/^v//')}"
  ./make-srpm.sh "$version"
}

run_rpm() {
  local srpm
  srpm="$(ls -1 ceph-*.src.rpm 2>/dev/null | head -n1 || true)"
  if [ -z "$srpm" ]; then
    run_source_rpm
    srpm="$(ls -1 ceph-*.src.rpm 2>/dev/null | head -n1)"
  fi
  local topdir="$CEPH_ROOT/rpmbuild"
  mkdir -p "$topdir"
  rpmbuild --rebuild -D"_topdir $topdir" "$srpm"
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
