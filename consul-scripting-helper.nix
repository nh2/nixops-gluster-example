let

in { pkgs }:
  pkgs.stdenv.mkDerivation {
    name = "consul-scripting-helper";
    buildInputs = [ (pkgs.python36.withPackages (pythonPackages: with pythonPackages; [ consul six requests ])) ];
    unpackPhase = "true";
    installPhase = ''
      mkdir -p $out/bin
      cp ${./scripts/consul-scripting-helper.py} $out/bin/consul-scripting-helper
    '';
  }
