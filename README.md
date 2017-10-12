# Advanced `nixops` deployment example: **GlusterFS**

This demonstrates an advanced [nixops](https://nixos.org/nixops/) deployment of

* the [GlusterFS](https://www.gluster.org/) distributed file system
  * a replicated setup across 3 machines in AWS Frankfurt
* read-only [geo-replication](https://gluster.readthedocs.io/en/latest/Administrator%20Guide/Geo%20Replication/) to another gluster cluster (could be on the other side of the world)
* mounting the file system from a client-only node
* use of gluster's [SSL](https://gluster.readthedocs.io/en/latest/Administrator%20Guide/Geo%20Replication/) support for encryption and server/client authentication
* use of [consul](https://www.consul.io/) to orchestrate volume-initialisation across machines on first boot
* the whole thing running over the [tinc](http://tinc-vpn.org/) VPN for security

all in one declarative and reproducible setup.


## Goal

After running this deployment, you'll have 3 machines which all have a `/glustermount` directory that has the distributed file system mounted.

If you drop some files in there, they will be safely stored with triple-redundancy in Frankfurt, and after a few seconds they will appear on the geo-replicated mirror.


## Prequisites

* An [Amazon AWS](http://aws.amazon.com) account
* AWS credentials set up in `~/.aws/credentials` (see [here](http://docs.aws.amazon.com/cli/latest/topic/config-vars.html#the-shared-credentials-file)); should look like this:

  ```
  [myprofilename]
  aws_access_key_id = AAAAAAAAAAAAAAAAAAAA
  aws_secret_access_key = ssssssssssssssssssssssssssssssssssssssss
  ```

  The account must have EC2 permissions.
* Make sure you have an ssh key configured in the `eu-central-1` region.
* Edit `example-gluster-cluster.nix`, changing:
  * `deployment.ec2.accessKeyId = "...";` to your `myprofilename` from the config file above
  * `deployment.ec2.keyPair = "...";` to the name of your SSH key as configured in AWS
* In you AWS account make sure that the `default` security group in the `eu-central-1` region lets port `665` (`TCP` and `UDP`) through so that `tinc` can communicate across the machines.
* Also make sure that you let SSH from the Internet through so that nixops and you can connect to the machines.
* [`nix`](http://nixos.org/nix/) and [`nixops`](https://nixos.org/nixops/) installed (I'm using versions nix 1.11.8 and nixops 1.5)

Also know that:

* `example-secrets/` contains example tinc keys, Gluster SSL keys etc. I generated for this purpose. Use them only for testing. The locations in the `.nix` files where they are used explain how you can generate your own ones.
* The VPN is there fore a reason: Running Consul on the open Internet is not safe. Gluster technically is, but it still find it safer to run that inside the VPN, too.
* You shouldn't forget to shut down all machines when you're done with trying this example.


## Usage

Run

```
nixops create -d gluster-test-deployment '<example-gluster-cluster.nix>'
env NIX_PATH=.:nixpkgs=https://github.com/nh2/nixpkgs/archive/84ecf17.tar.gz nixops deploy -d gluster-test-deployment
```

This should complete without errors and you should have your gluster cluster ready.

(To destroy it when you're done, use `nixops destroy -d gluster-test --confirm`, otherwise you keep paying for the machines.)


### Testing the distributed file system

Open 3 terminals to 3 different machines:

* `nixops ssh -d gluster-test gluster-cluster-1`
* `nixops ssh -d gluster-test gluster-cluster-2 -t 'watch -n0.1 ls /glustermount'`
* `nixops ssh -d gluster-test gluster-georep-1  -t 'watch -n0.1 ls /glustermount'`

Then in the first terminal, run `touch /glustermount/hello`.

You should see the file `hello` appear on the second machine immediately, and on the georep machine a few seconds later.
