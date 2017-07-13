{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.nh2-consul-over-tinc;

  consul-scripting-helper = import ../consul-scripting-helper.nix { inherit pkgs; };
  consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";

  # Settings for both servers and agents
  webUi = true;
  retry_interval = "1s";
  raft_multiplier = 1;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

in {

  imports = [
    ./nh2-consul-ready.nix
  ];

  options = {

    services.nh2-consul-over-tinc = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          To enable the nh2 customized Consul service.
          Includes:
          * A consul server or agent service running inside Tinc VPN
          * the `systemd.services.consulReady` service to wait for consul being up
        '';
      };

      isServer = mkOption {
        type = types.bool;
        default = false;
        description = ''Whether to start a consul server instead of an agent.'';
      };

      allConsensusServerHosts = mkOption {
        type = types.listOf types.str;
        description = ''
          Addresses or IPs of all consensus servers in the Consul cluster.
          Its length should be at least 3 to tolerate the failure of 1 node
          (though less than that will work for testing).
          Used in Consul's `bootstrap-expect` setting.
        '';
        example = ["10.0.0.1" "10.0.0.2" "10.0.0.3"];
      };

      thisConsensusServerHost = mkOption {
        type = types.str;
        description = ''
          Address or IP of this consensus server.
          Should be an element of the `allConsensusServerHosts` lists.
          Used to work around https://github.com/hashicorp/consul/issues/2868.
        '';
        example = "10.0.0.1";
      };

    };

  };

  config = {

    services.nh2-consul-ready = {
      enable = cfg.enable;
    };


    services.consul =
      if cfg.isServer
        then
          assert builtins.elem cfg.thisConsensusServerHost cfg.allConsensusServerHosts;
          {
            enable = cfg.enable;
            inherit webUi;
            extraConfig = {
              server = true;
              bootstrap_expect = builtins.length cfg.allConsensusServerHosts;
              inherit retry_interval;
              retry_join =
                # If there's only 1 node in the network, we allow self-join;
                # otherwise, the node must not try to join itself, and join only the other servers.
                # See https://github.com/hashicorp/consul/issues/2868
                if builtins.length cfg.allConsensusServerHosts == 1
                  then cfg.allConsensusServerHosts
                  else builtins.filter (h: h != cfg.thisConsensusServerHost) cfg.allConsensusServerHosts;
              performance = {
                inherit raft_multiplier;
              };
              bind_addr = config.services.nh2-tinc.vpnIPAddress;
            };
          }
        else
          {
            enable = cfg.enable;
            inherit webUi;
            extraConfig = {
              server = false;
              inherit retry_interval;
              retry_join = cfg.allConsensusServerHosts;
              performance = {
                inherit raft_multiplier;
              };
              bind_addr = config.services.nh2-tinc.vpnIPAddress;
            };
          };


    # Helper systemd service to ensure consul starts after tinc.
    # See README note "Design of the `*after*` services"
    systemd.services.consulAfterTinc = mkIf cfg.enable {
      wantedBy = [ (serviceUnitOf config.systemd.services.consul) ];
      before = [ (serviceUnitOf config.systemd.services.consul) ];
      # Ideally we would wait for the virtual device, as opposed to "tinc.${vpnNetworkName}.service",
      # to ensure that we can actually bind to the interface
      # (otherwise we may get `bind: cannot assign requested address`).
      # But we couldn't find a systemd target that ensures that device is actually ready.
      # So instead, we've made tinc signal to systemd when the connection is up,
      # using `systemd-notify` in "preStart". As a result we can now safely wait for
      # "tinc.${vpnNetworkName}.service".
      bindsTo = [ (serviceUnitOf config.systemd.services."tinc.${config.services.nh2-tinc.vpnNetworkName}")  ];
      after = [ (serviceUnitOf config.systemd.services."tinc.${config.services.nh2-tinc.vpnNetworkName}")  ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''${pkgs.bash}/bin/bash -c "sleep infinity"'';
        Restart = "always";
      };
    };

  };

}
