# Network arguments can be set with nixops's `set-args` feature.
{
  useNixCopyClosure ? false, # enable to copy everything over SSH, disabling usage of cache.nixos.org
}:
let
  glusterMountPoint = "/glustermount";

  # Which SSL certificate names are allowed to mount the volume.
  # These are the "CN" common name entries in the certificates.
  sslAllows = [
    "example-gluster-server"
    "example-gluster-client"
  ];

  sslPrivateKeyNixopsKeyName = "nh2-gluster-ssl-privkey";
  masterToSlaveRootSshPrivateKeyNixopsKeyName = "nh2-gluster-georep-ssh-privkey";

  vpnNetworkName = "glustervpn";

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

  packageOverrides = pkgs: {
  };

  # I found that a systemd .mount unit doesn't have the bugs that the
  # fstab generator has, see
  #    https://github.com/nh2/nixops-gluster-example/commit/67f59bf4
  # Note: When changing this and re-deploying an existing machine, you
  #       may get an error like
  #         Reload failed for /glustermount.
  #       because glusterfs doesn't support remounting.
  #       See https://github.com/systemd/systemd/issues/7007
  makeGlusterfsSystemdMountUnit = { server, glusterVolumeName, isLocalhostMount ? false, extraOptions ? [], config, pkgs }:
    let
      deps =
        if isLocalhostMount
          then [
            # localhost mounts don't need to care about SSL files being in place,
            # and they don't go via VPN addresses (which should make it faster).
            (serviceUnitOf config.systemd.services.glusterReadyForLocalhostMount)
          ]
          else [
            (serviceUnitOf config.systemd.services.glusterRequiredFilesSetup)
            (serviceUnitOf config.systemd.services.glusterReadyForClientMount)
            # TODO Do this once glusterfs-SSL-setup takes a path to a nixops key
            # Wait for SSL key to be uploaded by nixops
            # "${sslPrivateKeyNixopsKeyName}-key.service"
          ];
    in
    {
      wantedBy = [ "multi-user.target" ];
      what = "${server}:/${glusterVolumeName}";
      where = glusterMountPoint;
      type = "glusterfs";
      options = pkgs.lib.concatStringsSep " " (
        [
          # "log-level=DEBUG"
        ]
        ++ extraOptions
      );
      requires = deps;
      after = deps;
      mountConfig = {
        # This tiemout should be short because this should really succeed quickly.
        # Note: When it does time out, systemd doesn't correctly mark it as failed,
        #       see https://github.com/systemd/systemd/issues/7038
        TimeoutSec = "5s";
      };
    };


  gluster-node = {
    hostName,

    tincName,
    vpnIPAddress,
    allVpnNodes,

    machines,
    consulServerHosts,
    glusterVolumeName,
    geoReplicationMasterSettings ? null, # if null, this cluster has no slave cluster
    geoReplicationSlaveSettings ? null, # if null, it's a master cluster or not involve in geo-replication
  }: { config, pkgs, nodes, ... }:

  assert builtins.length machines >= 1;
  assert builtins.length consulServerHosts >= 1;

  assert (geoReplicationMasterSettings != null) -> (geoReplicationSlaveSettings == null);
  assert (geoReplicationSlaveSettings != null) -> (geoReplicationMasterSettings == null);

  let
    numReplicas = builtins.length machines;

    glusterClusterHosts = map ({ vpnIPAddress, ... }: vpnIPAddress) machines;

    brickFsPath = "/data/glusterfs/${glusterVolumeName}/brick1";

    isGeoReplicationMaster = geoReplicationSlaveSettings == null;
    isGeoReplicationSlave = !isGeoReplicationMaster;

    consul-scripting-helper = import ./consul-scripting-helper.nix { inherit pkgs; };
    consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";
  in rec {

    deployment.targetEnv = "ec2";
    deployment.ec2.accessKeyId = "nh2-nixops"; # symbolic name looked up in ~/.ec2-keys or a ~/.aws/credentials profile name
    deployment.ec2.region = "eu-central-1";
    deployment.ec2.instanceType = "t2.small";
    deployment.ec2.keyPair = "niklas";
    deployment.ec2.ebsBoot = true;
    deployment.ec2.ebsInitialRootDiskSize = 20;

    deployment.hasFastConnection = useNixCopyClosure;

    imports = [
      ./modules/nh2-tinc.nix
      ./modules/nh2-consul-over-tinc.nix
      ./modules/nh2-openssl-dhparams.nix
      ./modules/nh2-glusterfs-server.nix
    ];

    nixpkgs.config.packageOverrides = packageOverrides;

    fileSystems."${brickFsPath}" = {
      autoFormat = true;
      fsType = "xfs";
      formatOptions = "-i size=512";
      device = "/dev/xvdf";
      ec2.size = 1; # in GB
    };

    # Don't enable `autoUpgrade` because according to `clever` on IRC, it breaks
    # nixops, as it will rollback to plain NixOS and remove all our nixops setup:
    #system.autoUpgrade.channel = ...;

    environment.systemPackages = [
      pkgs.bind.dnsutils # for `dig` etc.
      pkgs.htop
      pkgs.jq
      pkgs.lsof
      pkgs.moreutils
      pkgs.netcat-openbsd
      pkgs.vim
    ];

    networking.firewall.enable = true; # enabled; we want only tinc to go through, and Gluster traffic to be blocked from the open Internet.
    # Reject instead of drop.
    networking.firewall.rejectPackets = true;
    networking.firewall.allowedTCPPorts = [
    ];

    # Tinc VPN

    services.nh2-tinc = {
      enable = true;
      vpnNetworkName = vpnNetworkName;
      tincName = tincName;
      vpnIPAddress = vpnIPAddress;
      publicKey = builtins.readFile ./example-secrets/tinc/ed25519_key.pub;
      # This file can be generated with e.g.
      #   nix-shell -p "tinc_pre" --pure --run 'tinc generate-ed25519-keys'
      # (you'll have to tell it where to save the files).
      privateKey = builtins.readFile ./example-secrets/tinc/ed25519_key.priv;
      allTincHosts = map ({ hostName, tincName, vpnIPAddress, configFieldNameIpAddress }: {
        tincName = tincName;
        # We make it configurable how to obtain this IP address using
        # `configFieldNameIpAddress`; this should be set e.g. to "privateIPv4"
        # for providers with internal networking (like EC2 VPCs), or
        # to "publicIPv4" when public IPs should be used.
        host = "${nodes."${hostName}".config.networking.${configFieldNameIpAddress}}";
        vpnIPAddress = vpnIPAddress;
      }) allVpnNodes;
    };

    # Consul, to synchronise the volume creation.

    services.nh2-consul-over-tinc = {
      enable = true;
      isServer = isGeoReplicationMaster; # Geo-replication slave clusters run only the consul agent.
      allConsensusServerHosts = consulServerHosts;
      thisConsensusServerHost = vpnIPAddress;
    };

    # Consul via DNS (*.consul)

    services.dnsmasq = {
      enable = true;
      extraConfig = ''
        server=/consul/127.0.0.1#8600
      '';
    };

    # OpenSSL dhparams

    # To avoid dhparams errors in gluster logs.
    # See https://bugzilla.redhat.com/show_bug.cgi?id=1398237
    services.nh2-openssl-dhparams = {
      enable = true;
      before = [ "glusterd.service" ];
    };

    # GlusterFS

    deployment.keys."${sslPrivateKeyNixopsKeyName}" = {
      text = builtins.readFile ./example-secrets/pki/example-gluster-server-privkey.pem;
    };
    deployment.keys."${masterToSlaveRootSshPrivateKeyNixopsKeyName}" = pkgs.lib.mkIf isGeoReplicationMaster {
      text = builtins.readFile ./example-secrets/glusterfs/nh2-gluster-georep-ssh-key;
    };

    services.nh2-gluster-server = {
      enable = true;
      allGlusterServerHosts = glusterClusterHosts;
      thisGlusterServerHost = vpnIPAddress;
      glusterTlsSettings = {
        caCert = ./example-secrets/pki/example-root-ca-cert.pem;
        # TODO Use .path here, inline sslPrivateKeyNixopsKeyName into `deployment.keys` above when https://github.com/NixOS/nixops/issues/646 is implemented
        tlsKeyPath = "/var/run/keys/${sslPrivateKeyNixopsKeyName}";
        tlsPem = ./example-secrets/pki/example-gluster-server-cert.pem;
      };
      glusterServiceSettings = {
        # logLevel = "DEBUG";
      };
      glusterVolumeName = glusterVolumeName;
      volumeReadySignalConsulKey = "nh2.distfs.${glusterVolumeName}.ready";
      brickFsPath = brickFsPath;
      numReplicas = numReplicas;
      sslAllows = sslAllows;
      geoReplicationMasterSettings =
        if isGeoReplicationMaster then {
          slaveHosts = geoReplicationMasterSettings.slaveHosts;
          slaveVolumeName = geoReplicationMasterSettings.slaveVolumeName;
          # TODO Use .path here, inline masterToSlaveRootSshPrivateKeyNixopsKeyName into `deployment.keys` above when https://github.com/NixOS/nixops/issues/646 is implemented
          masterToSlaveRootSshPrivateKeyPathOnMasterServer = "/var/run/keys/${masterToSlaveRootSshPrivateKeyNixopsKeyName}";
        } else null;
      geoReplicationSlaveSettings = geoReplicationSlaveSettings;
    };

    systemd.services.glusterdDependencies =
    let
      deps = [
        # Wait for tinc VPN to be up
        (serviceUnitOf config.systemd.services."tinc.${config.services.nh2-tinc.vpnNetworkName}")
        # Wait for SSL key to be uploaded by nixops
        "${sslPrivateKeyNixopsKeyName}-key.service"
      ];
    in
    {
      wantedBy = [ "glusterd.service" ];
      before = [ "glusterd.service" ];
      bindsTo = deps;
      after = deps;
      serviceConfig = {
        Type = "simple";
        ExecStart = ''${pkgs.bash}/bin/bash -c "sleep infinity"'';
        Restart = "always";
      };
    };

    # GlusterFS mount point

    services.nh2-consul-ready = {
      enable = true;
    };

    systemd.services.glusterReadyForLocalhostMount = {
      wantedBy = [ "multi-user.target" ];
      requires = [
        (serviceUnitOf config.systemd.services.consulReady)
      ];
      after = [
        "network-online.target"
        (serviceUnitOf config.systemd.services.consulReady)
      ];
      # Note: Here we `waitUntilService --node ${hostName}` because for
      #       servers we mount localhost, so we need to wait until this
      #       specific server is ready, not any arbitrary one of them.
      preStart = ''
        echo "Waiting for volume to be mountable..."
        ${consul-scripting-helper-exe} --verbose waitUntilService --service "gluster-volume-${glusterVolumeName}" --wait-for-index-change --node ${hostName}
        echo "Gluster service nodes:"
        ${pkgs.bind.dnsutils}/bin/dig +short gluster-volume-${glusterVolumeName}.service.consul
        echo "Volume should be mountable now."
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/true";
      };
    };

    systemd.mounts = [
      (makeGlusterfsSystemdMountUnit {
        server = "localhost"; # because this is a server it can mount itself
        isLocalhostMount = true;
        inherit glusterVolumeName;
        # On slaves we mount readonly as one should not write to a geo-replication slave mount;
        # that would prevent files of the same path to be synced over, even when deleted on
        # the geo-replication slave afterwards.
        # Only a delete on the master, and re-creation of the same file seems to fix that,
        # so we really never want to write to a geo-replication slave.
        extraOptions = if isGeoReplicationSlave then [ "ro" ] else [];
        inherit config pkgs;
      })
    ];

  };

  gluster-client-node = {
    hostName,

    tincName,
    vpnIPAddress,
    allVpnNodes,

    consulServerHosts,

    glusterServerHosts,
    glusterVolumeName,
  }: { config, pkgs, nodes, ... }:

  assert builtins.length consulServerHosts >= 1;

  let
    consul-scripting-helper = import ./consul-scripting-helper.nix { inherit pkgs; };
    consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";
  in
  {

    deployment.targetEnv = "ec2";
    deployment.ec2.accessKeyId = "nh2-nixops"; # symbolic name looked up in ~/.ec2-keys or a ~/.aws/credentials profile name
    deployment.ec2.region = "eu-central-1";
    deployment.ec2.instanceType = "t2.small";
    deployment.ec2.keyPair = "niklas";
    deployment.ec2.ebsBoot = true;
    deployment.ec2.ebsInitialRootDiskSize = 20;

    deployment.hasFastConnection = useNixCopyClosure;

    imports = [
      ./modules/nh2-tinc.nix
      ./modules/nh2-consul-over-tinc.nix
      ./modules/nh2-openssl-dhparams.nix
      ./modules/glusterfs-SSL-setup.nix # mount clients need this
    ];

    nixpkgs.config.packageOverrides = packageOverrides;

    environment.systemPackages = [
      pkgs.bind.dnsutils # for `dig` etc.
      pkgs.glusterfs # so that we can `mount -t glusterfs`
      pkgs.jq
      pkgs.lsof
    ];

    networking.firewall.enable = true; # enabled; we want only tinc to go through, and Gluster traffic to be blocked from the open Internet.
    # Reject instead of drop.
    networking.firewall.rejectPackets = true;
    networking.firewall.allowedTCPPorts = [
    ];

    # Tinc VPN

    services.nh2-tinc = {
      enable = true;
      vpnNetworkName = vpnNetworkName;
      tincName = tincName;
      vpnIPAddress = vpnIPAddress;
      publicKey = builtins.readFile ./example-secrets/tinc/ed25519_key.pub;
      # This file can be generated with e.g.
      #   nix-shell -p "tinc_pre" --pure --run 'tinc generate-ed25519-keys'
      # (you'll have to tell it where to save the files).
      privateKey = builtins.readFile ./example-secrets/tinc/ed25519_key.priv;
      allTincHosts = map ({ hostName, tincName, vpnIPAddress, configFieldNameIpAddress }: {
        tincName = tincName;
        # We make it configurable how to obtain this IP address using
        # `configFieldNameIpAddress`; this should be set e.g. to "privateIPv4"
        # for providers with internal networking (like EC2 VPCs), or
        # to "publicIPv4" when public IPs should be used.
        host = "${nodes."${hostName}".config.networking.${configFieldNameIpAddress}}";
        vpnIPAddress = vpnIPAddress;
      }) allVpnNodes;
    };

    # Consul, to synchronise the volume creation.

    services.nh2-consul-over-tinc = {
      enable = true;
      isServer = false; # Mount clients run only the consul agent.
      allConsensusServerHosts = consulServerHosts;
      thisConsensusServerHost = vpnIPAddress;
    };

    # Consul via DNS (*.consul)

    services.dnsmasq = {
      enable = true;
      extraConfig = ''
        server=/consul/127.0.0.1#8600
      '';
    };

    # OpenSSL dhparams

    # To avoid dhparams errors in gluster logs.
    # See https://bugzilla.redhat.com/show_bug.cgi?id=1398237
    services.nh2-openssl-dhparams = {
      enable = true;
      before = [ "glusterd.service" ];
    };

    # GlusterFS mount point

    services.glusterfs-SSL-setup = {
      enable = true;
      glusterSSLcertsCA = builtins.readFile example-secrets/pki/example-root-ca-cert.pem;

      # TODO Use .path here, inline sslPrivateKeyNixopsKeyName into `deployment.keys` above when https://github.com/NixOS/nixops/issues/646 is implemented
      # privateKeyPath = "/var/run/keys/${sslPrivateKeyNixopsKeyName}";
      # TODO Use nixops keys + a file path for this instead
      privateKey = builtins.readFile example-secrets/pki/example-gluster-server-privkey.pem;

      certificate = builtins.readFile example-secrets/pki/example-gluster-server-cert.pem;
    };

    services.nh2-consul-ready = {
      enable = true;
    };

    systemd.services.glusterReadyForClientMount = {
      wantedBy = [ "multi-user.target" ];
      requires = [
        (serviceUnitOf config.systemd.services.consulReady)
      ];
      after = [
        "network-online.target"
        (serviceUnitOf config.systemd.services.consulReady)
      ];
      preStart = ''
        echo "Waiting for volume to be mountable..."
        ${consul-scripting-helper-exe} --verbose waitUntilService --service "gluster-volume-${glusterVolumeName}" --wait-for-index-change
        echo "Gluster service nodes:"
        ${pkgs.bind.dnsutils}/bin/dig +short gluster-volume-${glusterVolumeName}.service.consul
        echo "Volume should be mountable now."
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/true";
      };
    };

    systemd.mounts = [
      (makeGlusterfsSystemdMountUnit {
        server = "gluster-volume-${glusterVolumeName}.service.consul";
        inherit glusterVolumeName;
        extraOptions = [ "backup-volfile-servers=${pkgs.lib.concatStringsSep ":" glusterServerHosts}" ];
        inherit config pkgs;
      })
    ];
  };

  # For EC2, we use the private IP to connect tinc nodes.
  # TODO: This is not optimal, as it charges us for traffic even within the same region.
  #       We should use the private address if the 2 VPN nodes in question are in the same
  #       region, or use the AWS DNS entries to have that happen automatically.
  #       However, using DNS doesn't currently work for tinc; see the note about
  #       "Non-VPN IP addresses of the machine" in `nh2-tinc.nix`.
  awsConfigFieldNameIpAddressForVPN = "publicIPv4";

  mkGlusterMasterNode = { i }: rec {
    hostName = "gluster-cluster-" + i;
    tincName = "gluster_cluster_" + i;
    vpnIPAddress = "10.0.0.${i}"; # Master nodes are in 10.0.0.*; we support only up to 254 master nodes for now.
    configFieldNameIpAddress = awsConfigFieldNameIpAddressForVPN;
    nodeConfig = gluster-node {
      inherit hostName;
      inherit tincName;
      inherit vpnIPAddress;
      inherit allVpnNodes;
      machines = masterClusterMachines;
      inherit consulServerHosts;
      glusterVolumeName = masterVolumeName;
      inherit geoReplicationMasterSettings;
    };
  };

  mkGlusterSlaveNode = { i }: rec {
    hostName = "gluster-georep-" + i;
    tincName = "gluster_georep_" + i;
    vpnIPAddress = "10.0.1.${i}"; # Slave nodes are in 10.0.1.*; we support only up to 254 slave nodes for now.
    configFieldNameIpAddress = awsConfigFieldNameIpAddressForVPN;
    nodeConfig = gluster-node {
      inherit hostName;
      inherit tincName;
      inherit vpnIPAddress;
      inherit allVpnNodes;
      machines = slaveClusterMachines;
      inherit consulServerHosts;
      glusterVolumeName = slaveVolumeName;
      inherit geoReplicationSlaveSettings;
    };
  };

  mkClientMountNode = { i }: rec {
    hostName = "gluster-client-" + i;
    tincName = "gluster_client_" + i;
    vpnIPAddress = "10.0.2.${i}"; # Client nodes are in 10.0.2.*; we support only up to 254 client nodes for now.
    configFieldNameIpAddress = awsConfigFieldNameIpAddressForVPN;
    nodeConfig = gluster-client-node {
      inherit hostName;
      inherit tincName;
      inherit vpnIPAddress;
      inherit allVpnNodes;
      inherit consulServerHosts;
      glusterServerHosts = map (machine: machine.vpnIPAddress) masterClusterMachines; # first server machine
      glusterVolumeName = masterVolumeName;
    };
  };

  geoReplicationMasterSettings = {
    slaveHosts = map (machine: machine.vpnIPAddress) slaveClusterMachines;
    inherit slaveVolumeName;
  };

  geoReplicationSlaveSettings = {
    # Created with:
    #   ssh-keygen -t rsa -f example-secrets/glusterfs/nh2-gluster-georep-ssh-key -N "" -C nh2-gluster-georep-ssh-key
    masterSshPubKey = builtins.readFile ./example-secrets/glusterfs/nh2-gluster-georep-ssh-key.pub;
  };

  masterVolumeName = "distfs";
  slaveVolumeName = "distfs-georep";

  masterClusterMachines = [
    (mkGlusterMasterNode { i = "1"; })
    (mkGlusterMasterNode { i = "2"; })
    (mkGlusterMasterNode { i = "3"; })
  ];
  slaveClusterMachines = [
    (mkGlusterSlaveNode { i = "1"; })
    # (mkGlusterSlaveNode { i = "2"; })
    # (mkGlusterSlaveNode { i = "3"; })
  ];
  clientMountMachines = [
    (mkClientMountNode { i = "1"; })
  ];

  machines = masterClusterMachines ++ slaveClusterMachines ++ clientMountMachines;

  allVpnNodes = map ({ hostName, tincName, vpnIPAddress, configFieldNameIpAddress, ... }: {
    inherit hostName;
    inherit tincName;
    inherit vpnIPAddress;
    inherit configFieldNameIpAddress;
  }) machines;

  consulServerHosts = map ({ vpnIPAddress, ... }: vpnIPAddress) masterClusterMachines;
in
rec {
  network.enableRollback = true;

} // # Add an entry in the network for each machine.
  builtins.listToAttrs (map ({ hostName, nodeConfig, ... }: { name = hostName; value = nodeConfig; }) machines)
