let

  glusterMountPoint = "/glustermount";

  # Which SSL certificate names are allowed to mount the volume.
  # These are the "CN" common name entries in the certificates.
  sslAllows = [
    "example-gluster-server"
    "example-gluster-client"
  ];

  masterToSlaveRootSshPrivateKeyNixopsKeyName = "nh2-gluster-georep-ssh-privkey";

  vpnNetworkName = "glustervpn";

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

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

  in rec {

    deployment.targetEnv = "ec2";
    deployment.ec2.accessKeyId = "nh2-nixops"; # symbolic name looked up in ~/.ec2-keys or a ~/.aws/credentials profile name
    deployment.ec2.region = "eu-central-1";
    deployment.ec2.instanceType = "t2.small";
    deployment.ec2.keyPair = "niklas";
    deployment.ec2.ebsBoot = true;
    deployment.ec2.ebsInitialRootDiskSize = 20;

    imports = [
      ./modules/nh2-tinc.nix
      ./modules/nh2-consul-over-tinc.nix
      ./modules/nh2-glusterfs-server.nix
    ];

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
      pkgs.htop
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

    # GlusterFS

    deployment.keys = pkgs.lib.mkIf isGeoReplicationMaster {
      "${masterToSlaveRootSshPrivateKeyNixopsKeyName}".text = builtins.readFile ./example-secrets/glusterfs/nh2-gluster-georep-ssh-key;
    };

    services.nh2-gluster-server = {
      enable = true;
      allGlusterServerHosts = glusterClusterHosts;
      thisGlusterServerHost = vpnIPAddress;
      glusterSSLSetup = {
        enable = true;
        glusterSSLcertsCA = builtins.readFile example-secrets/pki/example-root-ca-cert.pem;
        privateKey = builtins.readFile example-secrets/pki/example-gluster-server-privkey.pem;
        certificate = builtins.readFile example-secrets/pki/example-gluster-server-cert.pem;
      };
      glusterServiceSettings = {
        logLevel = "DEBUG";
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

    # GlusterFS mount point

    fileSystems."${glusterMountPoint}" = {
      fsType = "glusterfs";
      device = "localhost:/${glusterVolumeName}";
      options =
        # The volume has to be created before we can mount it.
        [
          "x-systemd.requires=glusterClusterInit.service"
          "x-systemd-after=glusterClusterInit.service"
        ]
        # On slaves we mount readonly as one should not write to a geo-replication slave mount;
        # that would prevent files of the same path to be synced over, even when deleted on
        # the geo-replication slave afterwards.
        # Only a delete on the master, and re-creation of the same file seems to fix that,
        # so we really never want to write to a geo-replication slave.
        ++ (if isGeoReplicationSlave then [ "ro" ] else []);
    };

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

  machines = masterClusterMachines ++ slaveClusterMachines;

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
