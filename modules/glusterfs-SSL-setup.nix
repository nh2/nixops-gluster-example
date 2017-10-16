# Note that since NixOS 17.09 this is only necessary for
# machines that are not at the same time glusterfs servers,
# because those have `services.glusterfs.tlsSettings`
# to configure this.
{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.glusterfs-SSL-setup;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";
in {

  imports = [
  ];

  options = {

    services.glusterfs-SSL-setup = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to set up the files this machine neeeds before it can become
          a GlusterFS server or client.
        '';
      };

      glusterSSLcertsCA = mkOption {
        type = types.str;
        description = ''Contents of the CA certificate used for encryption and authentication.'';
        example = "-----BEGIN CERTIFICATE-----\n...";
      };

      privateKeyPath = mkOption {
        type = types.str;
        description = ''
          Path on the target machine to the private key used for encryption and authentication.
          This is not the key contents so that they don't go into the (world-readable) nix store.
        '';
        example = "/var/run/keys/gluster-key.pem";
      };

      certificate = mkOption {
        type = types.str;
        description = ''Contents of the certificate used for encryption and authentication.'';
        example = "-----BEGIN CERTIFICATE-----\n...";
      };

    };

  };

  config =
  {

    # Service that sets up files that make gluster decide whether to use SSL or not.

    systemd.services.glusterRequiredFilesSetup = mkIf cfg.enable {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      before = optional config.services.glusterfs.enable (serviceUnitOf config.systemd.services.glusterd); # has no effect if only the client parts of glusterfs are used (if `glusterd` is not started)
      # Note: If the /var/lib/glusterd/secure-access thing breaks in the future
      # and we get
      #   error:1408F10B:SSL routines:SSL3_GET_RECORD:wrong version number
      # in the server log, then that means that nixpkgs has switched the prefix
      # `localstatedir=/var` to something different; the `secure-access` file
      # must be under that prefix.
      preStart = ''
        mkdir -p /var/log/glusterfs/

        mkdir -p /var/lib/glusterd/
        touch /var/lib/glusterd/secure-access
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''/run/current-system/sw/bin/true'';
      };
    };

    # SSL files

    environment.etc.glusterSSLcertsCA = mkIf cfg.enable {
      target = "ssl/glusterfs.ca";
      text = cfg.glusterSSLcertsCA;
    };

    environment.etc.glusterSSLcertsPrivateKey = mkIf cfg.enable {
      target = "ssl/glusterfs.key";
      source = cfg.privateKeyPath;
    };

    environment.etc.glusterSSLcertsCert = mkIf cfg.enable {
      target = "ssl/glusterfs.pem";
      text = cfg.certificate;
    };

  };

}
