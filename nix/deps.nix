# Ceph build dependency sets for Nix flakes.
#
# These lists mirror debian/control build profiles using nixpkgs attributes.
# Attribute names are plain strings so hyphenated packages resolve correctly.

{ pkgs }:

let
  lib = pkgs.lib;
  py = pkgs.python3Packages;

  get = name:
    if builtins.hasAttr name pkgs then pkgs.${name}
    else builtins.throw "nixpkgs is missing required package: ${name}";

  getPy = name:
    if builtins.hasAttr name py then py.${name}
    else builtins.throw "nixpkgs.python3Packages is missing required package: ${name}";

  # CMake and build scripts invoke `python3` directly; bundle common modules.
  cephPython = pkgs.python3.withPackages (ps: [
    ps.pyyaml
    ps.cython
  ]);

  pythonCheck = [
    (getPy "tox")
    (getPy "coverage")
    (getPy "bcrypt")
    (getPy "jmespath")
    (getPy "xmltodict")
    (getPy "pyopenssl")
    (getPy "prettytable")
    (getPy "requests")
    (getPy "scipy")
    (getPy "cherrypy")
    (getPy "grpcio")
    (getPy "python-dateutil")
    (getPy "pip")
    (getPy "setuptools")
    (getPy "wheel")
    (getPy "sphinx")
    (getPy "jinja2")
    (getPy "markupsafe")
    (getPy "pyyaml")
    (getPy "cython")
  ];

  baseNames = [
    "autoconf"
    "automake"
    "bison"
    "ccache"
    "cmake"
    "cpio"
    "curl"
    "cunit"
    "dpkg"
    "expat"
    "flex"
    "fmt"
    "fuse3"
    "gcc14"
    "git"
    "gperf"
    "gperftools"
    "go"
    "grpc"
    "icu"
    "jdk"
    "keyutils"
    "libaio"
    "libcap"
    "libcap_ng"
    "libedit"
    "libevent"
    "libffi"
    "libnbd"
    "libnl"
    "libtool"
    "lmdb"
    "lua5_3"
    "lz4"
    "nasm"
    "ncurses"
    "ninja"
    "nlohmann_json"
    "numactl"
    "nss"
    "oath-toolkit"
    "openldap"
    "openssl"
    "patch"
    "pkg-config"
    "protobuf"
    "rabbitmq-c"
    "ragel"
    "rdma-core"
    "re2"
    "rocksdb"
    "snappy"
    "sqlite"
    "systemd"
    "thrift"
    "utf8proc"
    "util-linux"
    "valgrind"
    "which"
    "xfsprogs"
    "xmlstarlet"
    "yaml-cpp"
    "zlib"
    "zstd"
    "boost"
    "cryptsetup"
    "cyrus_sasl"
    "lttng-ust"
    "babeltrace"
    "iproute2"
    "jq"
    "jsonnet"
    "lvm2"
    "nodejs"
    "socat"
    "ant"
    "maven"
  ];

  base = map get baseNames ++ [ cephPython ];

  makeCheck = pythonCheck ++ [
    (get "prometheus")
  ];

  crimsonNames = [
    "c-ares"
    "cryptopp"
    "gnutls"
    "hwloc"
    "libpciaccess"
    "lksctp-tools"
    "systemtap-sdt"
  ];

  crimson = map get crimsonNames;

  packagingNames = [
    "dpkg"
    "rpm"
    "fakeroot"
    "cpio"
    "perl"
    "patch"
    "git"
  ];

  packaging = map get packagingNames;

in {
  inherit base makeCheck crimson packaging cephPython;

  mkDeps = {
    forMakeCheck ? true,
    withCrimson ? true,
    withPackaging ? false,
  }:
    base
    ++ (if forMakeCheck then makeCheck else [ ])
    ++ (if withCrimson then crimson else [ ])
    ++ (if withPackaging then packaging else [ ]);
}
