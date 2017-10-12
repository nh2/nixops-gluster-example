{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.nh2-tinc;
in {

  imports = [
  ];

  options = {

    services.nh2-tinc = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''Whether to enable this tinc VPN.'';
      };

      allowAllTrafficOnVpnInterface = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to configure the NixOS firewall such that all traffic on
          the tinc VPN network interface is automatically allowed.
          Disable this if you don't trust all participants within the VPN
          or if you want firewalling even inside the VPN for some other reason.
        '';
      };

      vpnNetworkName = mkOption {
        # This check is because tinc interface names are prefixed by "tinc." in the
        # nixpkgs tinc service, and iptables will refuse to work on too long
        # interface names; example:
        #
        #   iptables v1.6.1: interface name `tinc.example-gluster-vpn' must be shorter than IFNAMSIZ (15)
        type = types.addCheck types.str (x: stringLength x <= 10) // {
          description = ''
            tinc interface name (string <= 10 chars, IFNAMSIZ-len("tinc.") = 10, where IFNAMSIZ = 16-1)
          '';
        };
        description = ''Name of the tinc network.'';
        example = "myvpn";
      };

      tincName = mkOption {
        type = types.str;
        description = ''
          Unique "node name" of this node in the tinc network.

          Note that tinc will replace all non-alphanumeric characters (thus, also
          hyphens ('-')) in it by underscores ('_'); see
          https://github.com/gsliepen/tinc/blob/5c344f297682cf11793407fca4547968aee22d95/src/net_setup.c#L341.
        '';
        example = "node-1";
      };

      vpnIPAddress = mkOption {
        type = types.str;
        description = ''IP address of the tinc network interface.'';
        example = "10.0.0.1";
      };

      publicKey = mkOption {
        type = types.str;
        description = ''
          Contents of the tinc public key.
          In this config, all nodes use the same public/private key pair.
          Can be generated with `tinc generate-ed25519-keys`.
        '';
        example = "Ed25519PublicKey = abcd123...";
      };

      privateKey = mkOption {
        type = types.str;
        description = ''
          Contents of the tinc private key.
          In this config, all nodes use the same public/private key pair.
          See the corresponding `publicKey` option on how it can be generated.
        '';
        example = "-----BEGIN ED25519 PRIVATE KEY-----\n...";
      };

      allTincHosts = mkOption {
        description = ''
          Information about all machines that shall participate in the VPN.
        '';
        type = types.listOf (types.submodule {
          options = {

            tincName = mkOption {
              description = ''
                Tinc "node name" of the machine.

                See the docs of the `tincName` option further above for special
                handling of non-alphanumeric characters, such as hyphens ('-').
              '';
              example = "othermachine";
            };

            host = mkOption {
              # We only allow IP addresses below and no host names, but if host
              # names were allowed, they must not contain underscores.
              type = types.addCheck types.str (host: !(builtins.elem "_" (strings.stringToCharacters host)));
              description = ''
                Non-VPN IP addresses of the machine.

                This needs to be a real IP address, e.g. an entry in /etc/hosts:
                When tinc's chroot feature is used, it can't resolve
                entries in `/etc/hosts` (which e.g. nixops sets up) to IP addresses;
                see https://www.tinc-vpn.org/pipermail/tinc/2017-March/004794.html.
                If tried, we'd get an error like e.g.
                    Error looking up tinc-cluster-1 port 655: Name or service not known
                As a workaround, we have to use the other node's IP address directly
                instead of using its /etc/hosts configured hostname.
              '';
              example = "1.2.3.5";
            };

            vpnIPAddress = mkOption {
              type = types.str;
              description = ''IP address of the machine inside the VPN.'';
              example = "10.0.0.2";
            };

          };
        });
      };

    };

  };

  config = {

    # Firewall rules: Allow tinc.

    networking.firewall.allowedTCPPorts = [
      655 # tinc
    ];
    networking.firewall.allowedUDPPorts = [
      655 # tinc
    ];

    # Allow all traffic on the Tinc network interface ("inside our VPN")
    # if configured so.
    networking.firewall.extraCommands = mkIf (cfg.enable && cfg.allowAllTrafficOnVpnInterface) ''
      iptables -A nixos-fw -i tinc.${cfg.vpnNetworkName} -j ACCEPT
      iptables -A nixos-fw -o tinc.${cfg.vpnNetworkName} -j ACCEPT
    '';

    environment.etc."tinc-${cfg.vpnNetworkName}-tincDown" = mkIf cfg.enable {
      target = "tinc/${cfg.vpnNetworkName}/tinc-down";
      # Note $INTERFACE is a magic tinc keyword.
      text = ''
        #!/bin/sh
        ${pkgs.nettools}/bin/ifconfig $INTERFACE down
      '';
      mode = "0555";
    };

    environment.etc."tinc-${cfg.vpnNetworkName}-tincUp" = mkIf cfg.enable {
      target = "tinc/${cfg.vpnNetworkName}/tinc-up";
      # Note $INTERFACE is a magic tinc keyword.
      text = ''
        #!/bin/sh
        ${pkgs.nettools}/bin/ifconfig $INTERFACE ${cfg.vpnIPAddress} netmask 255.255.0.0
        ${pkgs.systemd}/bin/systemd-notify --ready
        # Have to sleep here because systemd cannot act on notify messages
        # if the sending process (this script) has exited;
        # see section `NotifyAccess=` from
        #   https://www.freedesktop.org/software/systemd/man/systemd.service.html
        # Of course this is racy, but 100ms should be enough for
        # systemd to process the notification.
        sleep 0.1
      '';
      mode = "0555";
    };

    # TODO we might want to change this to use nixops keys instead.
    environment.etc."tinc-${cfg.vpnNetworkName}-tincEd25519PrivateKey" = mkIf cfg.enable {
      target = "tinc/${cfg.vpnNetworkName}/ed25519_key.priv";
      text = cfg.privateKey;
      mode = "0400";
    };

    services.tinc.networks.${cfg.vpnNetworkName} = mkIf cfg.enable {
      chroot = true;
      name = cfg.tincName;
      hosts = builtins.listToAttrs (map ({ tincName, host, vpnIPAddress, ... }: {
        name = tincName;
        value =
          cfg.publicKey + ''
          Address = ${host}
          Subnet = ${vpnIPAddress}/32
          '';
      }) cfg.allTincHosts);
      ed25519PrivateKeyFile = "/etc/${config.environment.etc."tinc-${cfg.vpnNetworkName}-tincEd25519PrivateKey".target}";
      # debugLevel = 4; # for debugging
      extraConfig = ''
        AutoConnect = yes
      '';
      notify = true;
    };

  };

}
