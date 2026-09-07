# Optional pinned Fedora *base* image via pkgs.dockerTools.
#
# The default RPM packaging path follows src/script/build-with-container.py and
# builds a full dependency image with:
#   podman build -f Dockerfile.build  (see build-driver.sh fedora-image)
# That image runs buildcontainer-setup.sh → install-deps.sh (dnf builddep).
#
# This dockerTools image is only a pinned upstream Fedora base if you want a
# Nix-fixed FROM layer; it does not bake Ceph BuildRequires. Prefer
# `./nix/build-driver.sh fedora-image` for packaging.
#
# Refresh the base pin:
#   nix-shell -p nix-prefetch-docker --run \
#     'nix-prefetch-docker --image-name registry.fedoraproject.org/fedora --image-tag 43 --arch amd64 --os linux'

{
  pkgs,
  fedoraVersion ? "43",
  imageDigest ? "sha256:893f7eeffce8e3e2bb2bc62786ba5603fb1e0bd6ba07091acb892266b95bafdf",
  # NOTE: digest/hash below still pin fedora:41 from an earlier prefetch.
  # Re-run nix-prefetch-docker for fedora:43 before relying on this base.
  imageHash ? "sha256-9eLdSZchONKedc521mE2YQGLgBnAOw0LeV1HszNBvSI=",
}:

let
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  mockArch =
    if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";

  fedoraBase = pkgs.dockerTools.pullImage {
    imageName = "registry.fedoraproject.org/fedora";
    inherit imageDigest;
    hash = imageHash;
    finalImageName = "fedora";
    finalImageTag = fedoraVersion;
    os = "linux";
    inherit arch;
  };

  marker = pkgs.runCommand "ceph-fedora-base-marker" { } ''
    mkdir -p $out/etc
    cat > $out/etc/ceph-nix-fedora-base <<EOF
    name=ceph-fedora-base
    fedora=${fedoraVersion}
    note=base-only; use Dockerfile.build for Ceph BuildRequires
    EOF
    sed -i 's/^    //' $out/etc/ceph-nix-fedora-base
  '';

in
pkgs.dockerTools.buildImage {
  name = "ceph-fedora-base";
  tag = fedoraVersion;
  fromImage = fedoraBase;
  copyToRoot = marker;
  config = {
    WorkingDir = "/src";
    Env = [
      "CEPH_NIX_FEDORA_BASE=1"
      "MOCK_CONFIG=fedora-${fedoraVersion}-${mockArch}"
    ];
    Cmd = [ "/bin/bash" ];
  };
}
