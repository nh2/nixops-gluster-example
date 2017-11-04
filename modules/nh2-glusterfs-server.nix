{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.nh2-gluster-server;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

  consul-scripting-helper = import ../consul-scripting-helper.nix { inherit pkgs; };
  consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";

  brickPath = "${cfg.brickFsPath}/brick";
  allMachinesBrickPaths = map (host: "${host}:${brickPath}") cfg.allGlusterServerHosts;

  # Note that ANY use of `gluster volume status` has to be wrapped in a
  # `lockedCommand`, even if an operator wants to use it in a shell on the machine!
  # Because not doing so can disturb one of the invocations that we do
  # (e.g. in the consul check), thus making those invocations break with
  #   Another transaction is in progress for distfs. Please try again after sometime.

  # Note: Checking when a volume is actually mountable is tricky.
  # * Checking that glusterd is up is not enough.
  # * Checking that `gluster volume info` shows `Status: Started` is not enough.
  #   It seems to flip to that state immediately, even when the brick process
  #   isn't even started.
  brickStatusDetailCommand = "${pkgs.glusterfs}/bin/gluster volume status ${cfg.glusterVolumeName} ${cfg.thisGlusterServerHost}:${brickPath} detail";

  isGeoReplicationMaster = cfg.geoReplicationMasterSettings != null;
  isGeoReplicationSlave = cfg.geoReplicationSlaveSettings != null;
in {

  imports = [
    ./nh2-consul-ready.nix
  ];

  options = {

    services.nh2-gluster-server = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable the machine to be a nh2 GlusterFS server.
        '';
      };

      allGlusterServerHosts = mkOption {
        type = types.listOf types.str;
        description = ''
          Addresses or IPs of all GlusterFS server peers in the cluster.
          Its length should be at least 3 to tolerate the failure of 1 node
          (though less than that will work for testing).
        '';
        example = ["10.0.0.1" "10.0.0.2" "10.0.0.3"];
      };

      thisGlusterServerHost = mkOption {
        type = types.str;
        description = ''
          Address or IP of this GlusterFS server.
          Must be an element of the `allGlusterServerHosts` list.
        '';
        example = "10.0.0.1";
      };

      # TODO check if we can re-use the options type from services.glusterfs.tlsSettings, instead of `mkOption` with `types.attrs`
      glusterTlsSettings = mkOption {
        type = types.attrs;
        description = ''SSL setup options for this GlusterFS node.'';
      };

      glusterServiceSettings = mkOption {
        type = types.attrs;
        description = ''
          Extends/overrides (with `//`) the configuration of `services.glusterfs`.
          Useful to configure e.g. the `logLevel`.
        '';
        example = { logLevel = "DEBUG"; };
        default = {};
      };

      glusterVolumeName = mkOption {
        type = types.str;
        description = ''
          Name of the GlusterFS volume.
        '';
        example = "myvolume";
      };

      volumeReadySignalConsulKey = mkOption {
        type = types.str;
        description = ''
          Consul key to signal on when the volume is ready for being mounted.
          This is so that other servers know when they can mount it,
          and can wait for this event.
          The key's value being set to "1" means it's ready.
        '';
        example = "VOLNAME.ready";
      };

      brickFsPath = mkOption {
        type = types.str;
        description = ''
          Path to mount of a file system under which the brick directory shall be created.
          YOU MUST ENSURE that this directory exists and that it is a filesystem root.
          It should preferably be a file system that GlusterFS recommends.
        '';
        example = "/data/glusterfs/myvolume/brick1";
      };

      numReplicas = mkOption {
        type = types.int;
        description = ''
          Mirroring level of data in the volume.
          Should be at least 3 to tolerate the failure of 1 node.
        '';
        example = 3;
      };

      sslAllows = mkOption {
        type = types.listOf types.str;
        description = ''
          Certificate names that will be allowed to mount the volume.
        '';
        example = [ "gluster-server" "gluster-client" ];
      };

      geoReplicationMasterSettings = mkOption {
        description = ''
          Defines this cluster to act as a geo-replication master cluster,
          with the given settings to tell it how to talk to slave clusters.
          When set to `null`, this machine is not a geo-replication master.
        '';
        default = null;
        # TODO: Make this a list instead so that a master cluster can have multiple downstream slave clusters.
        type = types.nullOr (types.submodule {
          options = {

            slaveHosts = mkOption {
              type = types.listOf types.str;
              description = ''
                Addresses or IPs of all GlusterFS servers in the slave cluster.
              '';
              example = ["10.0.1.1" "10.0.1.2" "10.0.1.3"];
            };

            slaveVolumeName = mkOption {
              type = types.str;
              description = ''
                Name of the GlusterFS volume on the slave cluster that will
                mirror the contents of the master cluster volume.
              '';
              example = "myvolume-georep";
            };

            masterToSlaveRootSshPrivateKeyPathOnMasterServer = mkOption {
              type = types.str;
              description = ''
                Path (on the master server) to the ssh private key (without
                passphrase) that is used to initialise the connection between
                the master cluster and the slave cluster.
                The master server will connect as root to the slave server.
                This file should be readable by root only!
              '';
              example = "/var/run/keys/gluster-georep-ssh-privkey";
            };

          };
        });
      };

      geoReplicationSlaveSettings = mkOption {
        description = ''
          Defines this cluster to act as a geo-replication slave cluster,
          with the given settings to ensure a master can connect to it.
          When set to `null`, this machine is not a geo-replication slave.
        '';
        default = null;
        type = types.nullOr (types.submodule {
          options = {

            masterSshPubKey = mkOption {
              type = types.str;
              description = ''
                Contents of the SSH public key that allows the master cluster
                machines to SSH into the slave machines.
              '';
              example = "ssh-rsa ...";
            };

          };
        });
      };

    };

  };

  config =
  {

    # GlusterFS service

    services.glusterfs =
      assert cfg.numReplicas >= 1;
      assert builtins.length cfg.allGlusterServerHosts >= 1;
      assert builtins.length cfg.allGlusterServerHosts >= cfg.numReplicas;
      assert builtins.elem cfg.thisGlusterServerHost cfg.allGlusterServerHosts;
      # Geo-replication master/slave checks.
      # * In this current NixOS config, a machine cannot be at the same time
      #   be part of a master cluster and a slave cluster;
      #   GlusterFS itself does allow this type of cascading replication.
      assert (cfg.geoReplicationMasterSettings != null) -> (cfg.geoReplicationSlaveSettings == null);
      assert (cfg.geoReplicationSlaveSettings != null) -> (cfg.geoReplicationMasterSettings == null);
    {
      enable = cfg.enable;
      useRpcbind = false;
      killMode = "control-group";
      stopKillTimeout = "5s";
      tlsSettings = cfg.glusterTlsSettings;
    } // cfg.glusterServiceSettings;

    # Consul needs to be ready for our multi-machine orchestration to work.

    services.nh2-consul-ready = {
      enable = true;
    };

    # From `man 5 sudoers`:
    #   Note that the following characters must be escaped with a ‘\’ if
    #   they are used in command arguments: ‘,’, ‘:’, ‘=’, ‘\’.
    security.sudo.extraConfig = ''
      consul ALL=(root) NOPASSWD: ${builtins.replaceStrings [ "," ":" "=" "\\" ] [ "\\," "\\:" "\\=" "\\\\" ] brickStatusDetailCommand}
    '';

    environment.etc."consul.d/gluster-service.json" = rec {
      text = builtins.toJSON {
        service = {
          name = "gluster-volume-${cfg.glusterVolumeName}";
          address = cfg.thisGlusterServerHost;
          enableTagOverride = false;
          checks = [
            {
              id = "gluster-volume-${cfg.glusterVolumeName}";
              # This needs to be high enough so that one
              # `glusterVolumeRunningCheckWatchdog` loop can complete
              # (which can take a while because it's wrapped in a lock
              # and competing with all other such watchdogs), but short
              # enough so that it gets turned off during a reboot.
              # When I measured, on a 3 machine cluster with 0.5s ping,
              # across 500 samples the max time to complete was 5s.
              ttl = "7s";
            }
          ];
        };
      };
    };

    # GlusterFS volume status Consul tracking

    systemd.services.glusterVolumeRunningCheckWatchdog = mkIf cfg.enable {
      wantedBy = [ "multi-user.target" ];
      requires = [
        (serviceUnitOf config.systemd.services.consulReady)
        (serviceUnitOf config.systemd.services.glusterClusterInit)
      ];
      after = [
        "network-online.target"
        (serviceUnitOf config.systemd.services.consulReady)
        (serviceUnitOf config.systemd.services.glusterClusterInit)
      ];
      script = ''
        set -euo pipefail
        while true; do
          set +e # As this is a watchdog, we want this to run forever, also on failures
          ${consul-scripting-helper-exe} lockedCommand --key "glusterfs-${cfg.glusterVolumeName}-command-lock" --shell-command 'set -euo pipefail; ${brickStatusDetailCommand} | grep "^Online.*Y"' --pass-check-id "service:gluster-volume-${cfg.glusterVolumeName}"
          set -e
          sleep 1
        done
      '';
      serviceConfig = {
        Type = "simple";
        Restart = "always";
      };
    };

    # GlusterFS initial setup

    # This service is intended to be invoked only at first boot,
    # or afterwards manually by an operator.
    # Note: You can easily get the full path to this with
    #   echo $(cat $(systemctl status glusterClusterInit | grep -o '/nix/store/.*service') | grep ExecStartPre | cut -d= -f2)
    systemd.services.glusterClusterInit =
    let
      deps = [
        (serviceUnitOf config.systemd.services.consulReady)
        # Note: Racy. Waiting for glusterd.service doesn't currently
        #       guarantee that it's actually listening to requests yet,
        #       and as a result of that the "volume status" below
        #       can still fail due to that, and thus the rest
        #       of the script can incorrectly come to the conclusion
        #       that this means "glusterd is up but the volume hasn't
        #       been created yet, so I should create it" (at which
        #       it will hang "waiting for all machines to be up").
        #       But this race is relatively rare.
        #       A better solution would distinguish glusterd being down
        #       from the volume not existing, instead of relying only
        #       on a non-zero exit code from "gluster volume status".
        "glusterd.service"
      ];
    in
    mkIf cfg.enable {
      wantedBy = [ "multi-user.target" ];
      requires = deps;
      after = deps;
      preStart =
      let
        numPeers = builtins.length cfg.allGlusterServerHosts;
      in
      ''
        set -euo pipefail

        # Glusterfs commands don't like being run in parallel ("Locking failed" error message),
        # that's why we serialise them with `lockedCommand`.

        echo "Check whether volume '${cfg.glusterVolumeName}' already exists; exiting early if so..."
        # Note: This && early exit relies on consul-scripting-helper exiting only with the exit code
        # of the given --shell-command; if it exited by itself (bug), then we would incorrectly
        # continue with the script instead of exiting early.
        ${consul-scripting-helper-exe} --verbose lockedCommand --key "glusterfs-${cfg.glusterVolumeName}-command-lock" --shell-command '${pkgs.glusterfs}/bin/gluster volume status ${cfg.glusterVolumeName}' && echo "Exiting because volume already exists" && exit 0

        echo "Waiting for all machines to be up before probing..."
        ${consul-scripting-helper-exe} counterIncrement --key "glusterfs-${cfg.glusterVolumeName}-machine-up-counter"
        ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs-${cfg.glusterVolumeName}-machine-up-counter" --value "${toString numPeers}"
      ''
      # For probing, Gluster wants that the cluster adds new nodes, not that they add themselves.
      # Otherwise one can get the error:
      #   peer probe: failed: [OTHER_IP] is either already part of another cluster or having volumes configured
      # For this reason, we probe all peers from the first node.
      + (if (cfg.thisGlusterServerHost == builtins.head cfg.allGlusterServerHosts)
        then
          ''
            echo "This machine is the first node, probing peers..."
          ''
          + (concatMapStrings (host: "${pkgs.glusterfs}/bin/gluster peer probe ${host}\n") cfg.allGlusterServerHosts) # Note: Gluster allows a peer to probe itself.
          # It seems that `gluster peer probe` returns immediately,
          # even though it's a multi-step protocol.
          # To wait for it really really being done, we parse the `gluster peer status` output.
          # We do this only on the first machine because gluster can fail with
          # `peer status: failed` if we do it from multiple machines.
          + ''
            ${pkgs.glusterfs}/bin/gluster peer status
            while [ $(${pkgs.glusterfs}/bin/gluster peer status | grep -i "peer in cluster (connected)" | wc -l) -ne ${toString (numPeers - 1)} ]; do echo "Waiting for all peers to join first node; status:"; ${pkgs.glusterfs}/bin/gluster peer status; sleep 0.2; done
            echo "All peers have the right status now from the view of the first node"
            ${consul-scripting-helper-exe} counterIncrement --key "glusterfs-${cfg.glusterVolumeName}-first-node-peer-probe-completed"
          ''
        else
          ''
            echo "This machine is NOT the first node, not probing peers."
          ''
        )
      + ''
        echo "Waiting for first node to peer all ${toString numPeers} gluster nodes..."
        ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs-${cfg.glusterVolumeName}-first-node-peer-probe-completed" --value "1"

        echo "Waiting for this node to be peered to ${toString numPeers} gluster nodes..."
        while [ $(${pkgs.glusterfs}/bin/gluster peer status | grep -i "peer in cluster (connected)" | wc -l) -ne ${toString (numPeers - 1)} ]; do echo "Waiting for all peers to be joined to current code; status:"; ${pkgs.glusterfs}/bin/gluster peer status; sleep 0.2; done
        echo "All peers have the right status now from the view of this node"
        ${consul-scripting-helper-exe} counterIncrement --key "glusterfs-${cfg.glusterVolumeName}-all-nodes-peer-probe-completed-count"

        echo "Waiting for all nodes to be peered to ${toString numPeers} gluster nodes..."
        ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs-${cfg.glusterVolumeName}-all-nodes-peer-probe-completed-count" --value "${toString numPeers}"
        echo "All gluster nodes completed peering"
        ${pkgs.glusterfs}/bin/gluster peer status

        mkdir -p ${brickPath}

        echo "Waiting for all ${toString numPeers} gluster nodes to complete creating brick directory..."
        ${consul-scripting-helper-exe} counterIncrement --key "glusterfs.${cfg.glusterVolumeName}.brick-dir-counter"
        ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs.${cfg.glusterVolumeName}.brick-dir-counter" --value "${toString numPeers}"
        echo "All gluster nodes completed creating brick directory"

        echo "Waiting for first gluster node to create and configure the volume..."
      ''
      # Only 1 machine must create the volume.
      + (if (cfg.thisGlusterServerHost == builtins.head cfg.allGlusterServerHosts)
        then ''
          echo "This machine is the first node."

          # Create the volume
          ${pkgs.glusterfs}/bin/gluster volume create ${cfg.glusterVolumeName} ${optionalString (cfg.numReplicas > 1) "replica ${toString cfg.numReplicas}"} ${builtins.concatStringsSep " " allMachinesBrickPaths}

          # Options that must be set before starting the volume:
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} client.ssl on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} server.ssl on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} auth.ssl-allow '${builtins.concatStringsSep "," cfg.sslAllows}'

          # Start the volume
          ${pkgs.glusterfs}/bin/gluster volume start ${cfg.glusterVolumeName}

          # Options that can be set after starting the volume:
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} storage.linux-aio on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.io-thread-count 64
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.readdir-ahead on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} server.event-threads 32
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} client.event-threads 32
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} server.outstanding-rpc-limit 64
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} cluster.lookup-unhashed auto
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.flush-behind on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.strict-write-ordering off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.high-prio-threads 64
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.normal-prio-threads 64
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.low-prio-threads 64
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.write-behind-window-size 10MB
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} cluster.ensure-durability on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.lazy-open yes
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} cluster.use-compound-fops off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.open-behind on
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} features.cache-invalidation off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.quick-read off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.read-ahead off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} performance.stat-prefetch off
          ${pkgs.glusterfs}/bin/gluster volume set ${cfg.glusterVolumeName} rollover-time 1

          # Signal to other nodes that setting up the volume is done.
          ${pkgs.consul}/bin/consul kv put "glusterfs.${cfg.glusterVolumeName}.volume-started" 1

          # Signal globally that the volume is ready.
          ${pkgs.consul}/bin/consul kv put "${cfg.volumeReadySignalConsulKey}" 1
        ''
        else ''
          echo "This machine is NOT the first node."
          echo "Waiting for first node to signal the volume to be started..."
          ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs.${cfg.glusterVolumeName}.volume-started" --value 1
          echo "The first node has finished to create and configure the volume."
        '')
      + ''

        echo "Volume creation complete."
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''/run/current-system/sw/bin/true'';
      };
    };

    # Geo-replication setup

    # Add master ssh pub key to slave authorized keys so that the
    # master can ssh into the slave as root.
    users.extraUsers.root.openssh.authorizedKeys.keys =
      optional isGeoReplicationSlave (cfg.geoReplicationSlaveSettings.masterSshPubKey);

    systemd.services.glusterGeorepInit = mkIf isGeoReplicationMaster {
      wantedBy = [ "multi-user.target" ];
      requires = [
        (serviceUnitOf config.systemd.services.consulReady)
      ];
      after = [
        "network-online.target"
        (serviceUnitOf config.systemd.services.consulReady)
        (serviceUnitOf config.systemd.services.glusterClusterInit)
      ];
      preStart =
        let
          firstSlaveHostName = (builtins.head (cfg.geoReplicationMasterSettings.slaveHosts));
        in
        # Only 1 master must create the geo-replication session.
        if cfg.thisGlusterServerHost == builtins.head cfg.allGlusterServerHosts
          then
            ''
              echo "Ensuring that the master volume exists..."
              ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs.${cfg.glusterVolumeName}.volume-started" --value 1
              echo "Ensuring that the slave volume exists..."
              ${consul-scripting-helper-exe} waitUntilValue --key "glusterfs.${cfg.geoReplicationMasterSettings.slaveVolumeName}.volume-started" --value 1

              echo "Checking whether the geo-replication session already exists; exiting early if so..."
              ${consul-scripting-helper-exe} ensureValueEquals --key "glusterfs.${cfg.glusterVolumeName}.geo-rep.session-created" --value 1 && echo "Exiting because geo-replication session already exists" && exit 0

              echo "Generating geo-rep keypair with: gluster-georep-sshkey generate"
              ${pkgs.glusterfs}/bin/gluster-georep-sshkey generate

              cp -p "${cfg.geoReplicationMasterSettings.masterToSlaveRootSshPrivateKeyPathOnMasterServer}" /root/.ssh/id_rsa

              echo "Creating geo-replication"
              # The "create push-pem" and "start" commands can fail with "Another transaction is in progress for ${cfg.glusterVolumeName}" so we need to put it into a lock.
              set -x
              ${consul-scripting-helper-exe} lockedCommand --key "glusterfs-${cfg.glusterVolumeName}-command-lock" --shell-command '${pkgs.glusterfs}/bin/gluster volume geo-replication ${cfg.glusterVolumeName} ${firstSlaveHostName}::${cfg.geoReplicationMasterSettings.slaveVolumeName} create push-pem'
              ${consul-scripting-helper-exe} lockedCommand --key "glusterfs-${cfg.glusterVolumeName}-command-lock" --shell-command '${pkgs.glusterfs}/bin/gluster volume geo-replication ${cfg.glusterVolumeName} ${firstSlaveHostName}::${cfg.geoReplicationMasterSettings.slaveVolumeName} start'
              set +x

              ${pkgs.consul}/bin/consul kv put "glusterfs.${cfg.glusterVolumeName}.geo-rep.session-created" 1
            ''
          else
            ''
              echo "This is not a geo-replication master machine, exiting."
            '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''/run/current-system/sw/bin/true'';
      };
    };

  };

}
