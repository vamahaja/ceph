{
  description = "Hermetic Ceph build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Unix timestamp of the flake's last git commit (for reproducible builds).
      sourceDateEpoch = self.lastModified;
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        lib = pkgs.lib;
        deps = import ./nix/deps.nix { inherit pkgs; };

        pkgConfigPaths = lib.concatStringsSep ":" [
          "${pkgs.openssl.dev}/lib/pkgconfig"
          "${pkgs.cyrus_sasl.dev}/lib/pkgconfig"
          "${pkgs.snappy.dev}/lib/pkgconfig"
          "${pkgs.zstd.dev}/lib/pkgconfig"
          "${pkgs.lz4.dev}/lib/pkgconfig"
          "${pkgs.zlib.dev}/lib/pkgconfig"
          "${pkgs.rocksdb}/lib/pkgconfig"
          "${pkgs.boost}/lib/pkgconfig"
        ];

        cephBuildInputs = deps.mkDeps {
          forMakeCheck = true;
          withCrimson = true;
          withPackaging = true;
        };

        cephMinimalInputs = deps.mkDeps {
          forMakeCheck = false;
          withCrimson = false;
          withPackaging = false;
        };

        cephCrimsonInputs = deps.mkDeps {
          forMakeCheck = false;
          withCrimson = true;
          withPackaging = false;
        };

        cephPackagesInputs = deps.mkDeps {
          forMakeCheck = false;
          withCrimson = true;
          withPackaging = true;
        };

        # Reproducible debug info and build metadata.
        cephShellEnv = {
          SOURCE_DATE_EPOCH = toString sourceDateEpoch;
          CMAKE_BUILD_RPATH_USE_ORIGIN = "ON";
          CEPH_NIX_DEPS = "1";
          NIX_CFLAGS_COMPILE = "-fdebug-prefix-map=$PWD=/workspace";
          NIX_CXXFLAGS_COMPILE = "-fdebug-prefix-map=$PWD=/workspace";
        };

        mkCephShell = {
          name,
          packages,
          forMakeCheck ? true,
          withCrimson ? true,
        }:
          pkgs.mkShell {
            name = "ceph-${name}";
            packages = packages;
            env = {
              SOURCE_DATE_EPOCH = cephShellEnv.SOURCE_DATE_EPOCH;
            };
            shellHook = ''
              export CMAKE_BUILD_RPATH_USE_ORIGIN=${cephShellEnv.CMAKE_BUILD_RPATH_USE_ORIGIN}
              export CEPH_NIX_DEPS=${cephShellEnv.CEPH_NIX_DEPS}
              export CFLAGS="${cephShellEnv.NIX_CFLAGS_COMPILE}"
              export CXXFLAGS="${cephShellEnv.NIX_CXXFLAGS_COMPILE}"
              export CC="${pkgs.gcc14}/bin/gcc"
              export CXX="${pkgs.gcc14}/bin/g++"
              # Nix stdenv sets AS=as; bundled isa-l requires nasm when AS is unset.
              unset AS
              export OPENSSL_ROOT_DIR="${pkgs.openssl.dev}"
              export PKG_CONFIG_PATH="${pkgConfigPaths}''${PKG_CONFIG_PATH:+:}$PKG_CONFIG_PATH"
              export FOR_MAKE_CHECK=${if forMakeCheck then "1" else "0"}
              export WITH_CRIMSON=${if withCrimson then "1" else ""}

              echo "=========================================================="
              echo " Ceph Nix Development Environment (${name})"
              echo " GCC $(gcc -dumpversion) | CMake $(cmake --version | head -n1 | cut -d' ' -f3)"
              echo " Profiles: make-check=${if forMakeCheck then "on" else "off"} crimson=${if withCrimson then "on" else "off"}"
              echo "=========================================================="
              echo " Build:  nix develop -c ./nix/build-driver.sh build"
              echo " Tests:  nix develop -c ./nix/build-driver.sh tests"
              echo " Debs:   nix develop .#packages -c ./nix/build-driver.sh debs"
              echo " RPM:    nix develop .#packages -c ./nix/build-driver.sh rpm"
              echo "=========================================================="
            '';
          };

        mkBuildApp = step: extraEnv: {
          type = "app";
          program = toString (pkgs.writeShellScript "ceph-${step}" ''
            export IN_NIX_SHELL=1
            export CEPH_NIX_DEPS=1
            export SOURCE_DATE_EPOCH=${cephShellEnv.SOURCE_DATE_EPOCH}
            export CMAKE_BUILD_RPATH_USE_ORIGIN=${cephShellEnv.CMAKE_BUILD_RPATH_USE_ORIGIN}
            export CC="${pkgs.gcc14}/bin/gcc"
            export CXX="${pkgs.gcc14}/bin/g++"
            export PATH="${lib.makeBinPath cephPackagesInputs}:$PATH"
            ${extraEnv}
            exec "${self}/nix/build-driver.sh" ${step} "$@"
          '');
        };

        src = lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              base = builtins.baseNameOf path;
            in
              !(base == "build" || base == ".git" || lib.hasPrefix "build." base);
        };

        cephPackage = pkgs.stdenv.mkDerivation {
          pname = "ceph";
          version = "git";
          src = src;
          inherit sourceDateEpoch;

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            git
            gcc14
          ];
          buildInputs = cephMinimalInputs;

          dontUseCMakeConfigure = true;

          configurePhase = ''
            runHook preConfigure
            mkdir -p build
            cd build
            cmake -GNinja \
              -DCMAKE_BUILD_TYPE=Release \
              -DWITH_PYTHON3=3 \
              -DWITH_CCACHE=ON \
              ..
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            cd build
            ninja vstart
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            cd build
            DESTDIR=$out ninja install
            runHook postInstall
          '';

          meta = with lib; {
            description = "Ceph distributed storage system";
            license = licenses.lgpl21Only;
            platforms = platforms.linux;
          };
        };

      in {
        devShells = {
          default = mkCephShell {
            name = "default";
            packages = cephBuildInputs;
            forMakeCheck = true;
            withCrimson = true;
          };
          minimal = mkCephShell {
            name = "minimal";
            packages = cephMinimalInputs;
            forMakeCheck = false;
            withCrimson = false;
          };
          crimson = mkCephShell {
            name = "crimson";
            packages = cephCrimsonInputs;
            forMakeCheck = false;
            withCrimson = true;
          };
          packages = mkCephShell {
            name = "packages";
            packages = cephPackagesInputs;
            forMakeCheck = false;
            withCrimson = true;
          };
        };

        apps = {
          configure = mkBuildApp "configure" "";
          build = mkBuildApp "build" "";
          build-tests = mkBuildApp "build-tests" "export FOR_MAKE_CHECK=1";
          tests = mkBuildApp "tests" "export FOR_MAKE_CHECK=1";
          debs = mkBuildApp "debs" "export FOR_MAKE_CHECK=0";
          source-rpm = mkBuildApp "source-rpm" "export FOR_MAKE_CHECK=0";
          rpm = mkBuildApp "rpm" "export FOR_MAKE_CHECK=0";
          packages = mkBuildApp "packages" "export FOR_MAKE_CHECK=0";
        };

        packages = {
          default = cephPackage;
          ceph = cephPackage;
        };

        formatter = pkgs.nixfmt;
      });
}
