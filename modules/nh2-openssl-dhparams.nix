{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.nh2-openssl-dhparams;
in {

  imports = [
  ];

  options = {

    services.nh2-openssl-dhparams = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          To enable the one-time generation of /etc/ssl/dhparam.pem.
          Note this can take a minute or so.
        '';
      };

    };

  };

  config = {

    systemd.services.openssl-dhparams = mkIf cfg.enable {
      wantedBy = [ "multi-user.target" ];
      # We run this after the file system is ready (so we can write
      # the file) and before the network is ready (because it is
      # typically networking services that care about dhparams).

      after = [ "local-fs.target" ]; # TODO
      before = [ "network-setup.service" ]; # TODO

      unitConfig = {
        ConditionPathExists = "!/etc/ssl/dhparam.pem";
      };
      serviceConfig = {
        # We use `-dsaparam` to make generation much faster.
        # See https://security.stackexchange.com/a/72296
        ExecStart = "${pkgs.openssl}/bin/openssl dhparam -dsaparam -out /etc/ssl/dhparam.pem 2048";
        Type = "oneshot";
        TimeoutStartSec = "60s";
      };
    };

  };

}
