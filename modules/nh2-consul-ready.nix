{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.nh2-consul-ready;

  consul-scripting-helper = import ../consul-scripting-helper.nix { inherit pkgs; };
  consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";

in {

  imports = [
  ];

  options = {

    services.nh2-consul-ready = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          To enable the consulReady service.
          Other services can use this service to check if consul is ready
          (whether sessions can be created).
        '';
      };

    };

  };

  config = {

    systemd.services.consulReady = mkIf cfg.enable {
      wantedBy = [ "multi-user.target" ];
      requires = [ "consul.service" ];
      after = [ "consul.service" ];
      serviceConfig = {
        ExecStart = "${consul-scripting-helper-exe} --verbose waitForSession";
        Type = "oneshot";
        TimeoutStartSec = "infinity";
      };
    };

  };

}
