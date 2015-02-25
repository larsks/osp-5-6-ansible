---
title: RHEL-OSP 5 to RHEL-OSP 6 HA Upgrade
---

# RHEL-OSP 5 to RHEL-OSP 6 HA Upgrade

## Before you begin

You must update your system configuration to point at RHEL-OSP 6 package
repositories, using either subscription-manager or some other appropriate
tool.

Before starting the upgrade process, ensure that your pre-upgrade
environment is healthy.  In particular, make sure that all
Pacemaker-managed resources are active.

## Basic configuration tasks

In order to prevent conflicts during (and after) the upgrade process, we need
to disable Puppet.  On all systems in your OpenStack deployment, run:

    # systemctl stop puppet
    # systemctl disable puppet

We also put selinux into permissive mode to work around
existing bugs in the RHEL-OSP 6 packages for RHEL 7.0.  On all your
systems, run:

    # setenforce 0

In RHEL-OSP 5, some services were erroneously configured to be started by
systemd *and* by Pacemaker.  We want services involved in our HA
configuration to be managed only by Pacemaker.  On all your
controllers, run:

    # systemctl disable memcached
    # systemctl disable haproxy
    
## Stop all resources

We instruct Pacemaker to stop all managed resources, and then wait for
everything to stop completely before continuing:

    # pcs property set stop-all-resources=true

Ensure that all resources are stopped before continuing.  This avoids
conflicts as we update packages and modify configuration files and
resource configurations during the upgrade process.

After Pacemaker stops all the resources, we mark them individually
disabled and then unset Pacemaker's `stop-all-resources` property.
This allows Pacemaker to start resources as we create them or
explicitly enable them as part of the upgrade.

Use the following script to disable all Pacemaker-managed resources:

    # cibadmin -Q |
      xmllint --xpath '/cib/configuration/resources/*/@id' - |
      tr ' ' '\n' |
      cut -f2 -d'"' |
      xargs -n1 pcs resource disable
    
And then reset the `stop-all-resources` property:

    # pcs property set stop-all-resources=false
    
## Stop services on compute hosts

The compute hosts are not part of the Pacemaker cluster, so we need
to shut down services there separately.  On each compute host, run:

    # openstack-service stop

## Upgrade all packages

We run `yum upgrade` on all the hosts in our OpenStack deployment to
install the RHEL-OSP 6 packages.  On all hosts, run:

    # yum -y upgrade

Note that this requires you have configured your hosts to point to the
appropriate RHEL-OSP 6 package repositories.

## Reconfigure VIP resources

RHEL-OSP 6 names VIP resources differently from RHEL-OSP 5.  In this
step, we remove all the existing VIP resources and then re-generate
them, using RHEL-OSP 6 naming conventions, from information in the
HAProxy configuration.

The following commands should be run on *one of* your controllers.

First, delete the existing VIP resources:

    # crm_resource -l |
      grep ip- |
      xargs -n1 pcs resource delete

Then use the following script to generate a new set of VIP resources:

    # egrep 'listen|bind' /etc/haproxy/haproxy.cfg |
    { while read entry serv; do
      if [ "$entry" = listen ]; then
        #echo $entry
        case "$serv" in
          amqp)             vipserv=amqp;;
          cinder-api)       vipserv=cinder;;
          galera)           vipserv=galera;;
          glance-api)       vipserv=glance;;
          glance-registry)  vipserv="";;
          heat-api)         vipserv=heat;;
          heat-cfn)         vipserv=heat_cfn;;
          heat-cloudwatch)  vipserv="";;
          horizon)          vipserv=horizon;;
          keystone-admin)   vipserv=keystone;;
          keystone-public)  vipserv="";;
          neutron-api)      vipserv=neutron;;
          nova-api)         vipserv=nova;;
          nova-metadata)    vipserv="";;
          nova-novncproxy)  vipserv="";;
          nova-xvpvncproxy) vipserv="";;
          stats)            vipserv="";;

          *) echo UNKNOWN && exit 1;;
        esac
        suffix=pub
      fi

      if [ -n "$vipserv" ] && [ "$entry" = bind ]; then
        # note this only work for IPv4
        serv=${serv%:*}
        pcs resource create ip-$vipserv-$suffix-$serv \
          IPaddr2 ip=$serv cidr_netmask=32
        pcs constraint order start ip-$vipserv-$suffix-$serv \
          then haproxy-clone kind=Optional
        pcs constraint colocation add ip-$vipserv-$suffix-$serv \
          with haproxy-clone
        # add pub with prv with adm constraints!
        [ "$suffix" != pub ] && pcs constraint colocation add \
          ip-$vipserv-$suffix-$serv with ip-$vipserv-pub-$pubip
        [ "$suffix" = prv ] && suffix=adm
        if [ "$suffix" = pub ]; then
          pubip=$serv
          suffix=prv
        fi
      fi
    done; }

Next, update the `haproxy` resource configuration in Pacemaker:

    # pcs resource update haproxy start-delay=
    # pcs resource update haproxy op monitor interval=60s
    # pcs resource update haproxy clone interleave=true

And re-enable the `haproxy` resource:

    # pcs resource enable haproxy-clone
    
## Update MySQL/MariaDB resource

RHEL-OSP 6 uses a different resource agent for managing the database.
The `galera` agents resolves issues encountered in the older
configuration that would prevent the database from starting after
rebooting all the nodes in the Pacemaker cluster.

In this step, we remove parts of the configuration file specific to the older
configuration.

On all of your controllers, remove the `wsrep_cluster_address` from
`/etc/my.cnf.d/galera.cnf`:

    # sed -i 's/^wsrep_cluster_address/#wsrep_cluster_address/g' 
      /etc/my.cnf.d/galera.cnf
    
Now that the configuration files are correct, we delete the old
`mysqld` resource and create a new `galera` resource.  Pacemaker
will proceed to start this resource, and we wait for the database to
become operational before continuining.

On *one of* your controllers, run the following to delete the mysqld
resource:

    # pcs resource delete mysqld

And then create a new `galera` resource:

    # nodes=$(pcs status | grep ^Online | sed -e 's/.*\[ //g' -e 's/ \].*//g' -e 's/ /,/g')
    # pcs resource create galera galera enable_creation=true \
      wsrep_cluster_address="gcomm://$nodes" meta master-max=3 \
      ordered=true op promote timeout=300s on-fail=block  --master

## Update rabbitmq resource

In this step we replace the RHEL-OSP 5 `rabbitmq-server` resource
with an identically named resource using the new `rabbitmq-cluster`
resource agent.

We start by removing parts of the configuration specific to the
older resource definition.  On all of your controller, remove the
cluster configuration options from `/etc/rabbitnq/rabbitmq.config` and
clean up the `rabbitmq` state directory:

      sed -i '/cluster_/d' /etc/rabbitmq/rabbitmq.config 
      rm -rf /var/lib/rabbitmq/mnesia/
    
Next, we replace the `rabbitmq-server` resource definition, enable
the resource, and wait for the service to become active.

On *one of* your controllers, delete the `rabbitmq-server` resource:

    # pcs resource delete rabbitmq-server

Then create the replacement:

    # pcs resource create rabbitmq-server rabbitmq-cluster \
      set_policy='HA ^(?!amq\.).* {"ha-mode":"all"}'
    
## Update memcached resource

Make some minor changes to the `memcached` resource and then
enable the service.  On *one of* your controllers, update the resource
definition:

    # pcs resource update memcached start-delay=
    # pcs resource update memcached op monitor interval=60s
    # pcs resource update memcached clone interleave=true

And then enable the service:

    # pcs resource enable memcached-clone
    
## Update OpenStack database schemas

We'll use the `openstack-db` wrapper script to perform database schema
upgrades on all of our OpenStack services.  One *one of* your
controllers:

    # for service in keystone glance cinder nova neutron heat; do
      openstack-db --service $service --update
      done
    
## Update Keystone resource

In this step we make some minor changes to the `openstack-keystone`
resource, and we add some missing start constraints such that
keystone will start *after* basic services (galera, rabbitmq,
memcached, haproxy) are up.

On *one of* your controllers, update the `openstack-keystone` resource
definition:

    # pcs resource update openstack-keystone start-delay=
    # pcs resource update openstack-keystone op monitor interval=60s
    # pcs resource update openstack-keystone clone interleave=true

Add start constraints to the resource:

    # for rsrc in galera-master rabbitmq-server memcached-clone haproxy-clone; do
      pcs constraint order start $rsrc \
              then openstack-keystone-clone
      done

Enable the resource and wait for keystone to become active before
continuing:

    # pcs resource enable openstack-keystone-clone
    
## Update Glance resources

This steps updates both the `openstack-glance-api` and
`openstack-glance-registry` resources.  We add a start constraint on
glance-registry such that it will only start *after* keystone (there is
an existing constraint between glance-api and glance-registry that
ensures the proper ordering of those services).


On *one of* your controllers, update the resource definitions:

    # for rsrc in openstack-glance-{api,registry}; do
      pcs resource update $rsrc start-delay=
      pcs resource update $rsrc op monitor interval=60s
      pcs resource update $rsrc clone interleave=true
      done

Add start constraints on the resources:

    # pcs constraint order start openstack-keystone-clone \
      then openstack-glance-registry-clone

Then we enable glance (and the supporting filesystem), and wait for
glance to become active before continuing:

    # for rsrc in fs-varlibglanceimages-clone openstack-glance-{api,registry}-clone; do
      pcs resource enable $rsrc
      done
    
## Update Cinder resources

Here we update cinder, adding a start constraint between cinder-api
and keystone.  On *one of* your controllers, update the resource
definitions:

    # for rsrc in openstack-cinder-{api,scheduler,volume}; do
      pcs resource update $rsrc start-delay=
      pcs resource update $rsrc op monitor interval=60s
      [ "$rsrc" = "openstack-cinder-volume" ] ||
        pcs resource update $rsrc clone interleave=true
      done

Add the necessary start constraint:

    # pcs constraint order start openstack-keystone-clone \
      then openstack-cinder-api-clone

Then enable all the cinder services and wait for cinder to become
active before continuing:

    # for rsrc in openstack-cinder-{api-clone,scheduler-clone,volume}; do
      pcs resource enable $rsrc
      done

## Update Nova resources

Here we update nova, adding a start constraint between nova-api
and keystone.  On *one of* your controllers, update the resource
definitions:

    # for rsrc in openstack-nova-{api,consoleauth,novncproxy,conductor,scheduler}; do
      pcs resource update $rsrc start-delay=
      pcs resource update $rsrc op monitor interval=60s
      pcs resource update $rsrc clone interleave=true
      done

Add the start constraint:

    # pcs constraint order start openstack-keystone-clone \
      then openstack-nova-api-clone

Then enable all the nova services and wait for nova to become
active before continuing:

    # for rsrc in openstack-nova-{api,consoleauth,novncproxy,conductor,scheduler}; do
      pcs resource enable $rsrc-clone
      done

## Update Heat resources

Here we update heat, adding a start constraint between heat-api
and keystone.  On *one of* your controllers, update the resource
definitions:

    # for rsrc in openstack-heat-{api,api-cfn,api-cloudwatch,engine}; do
      pcs resource update $rsrc start-delay=
      pcs resource update $rsrc op monitor interval=60s
      pcs resource update $rsrc clone interleave=true
      done

Add the start constraint:

    # pcs constraint order start openstack-keystone-clone \
      then openstack-heat-api-clone

Then enable all the heat services and wait for heat to become
active before continuing:

    # for rsrc in in heat openstack-heat-{api,api-cfn,api-cloudwatch}-clone; do
      pcs resource enable $rsrc
      done
    
## Update Apache (httpd) resource

Update and enable the `httpd` resource.  On *one of* your controllers,
update the resource definition:

    # pcs resource update httpd start-delay=
    # pcs resource update httpd op monitor interval=60s
    # pcs resource update httpd clone interleave=true

And enable the resource:

    # pcs resource enable httpd-clone
    
## Update Neutron resources

There are substantial changes in the Neutron resource configuration
between RHEL-OSP 5 and RHEL-OSP 6.  In particular, we replace the
`neutron-agents` resource group with individual clones for each
service.  We run Neutron in active/passive mode by (a) creating a
`neutron-scale` clone resource that can only run one instance at a
time (`clone_max=1`), and (b) adding constraints to the other
neutron services that tie them to whichever host is currently
running the `neutron-scale` instance.

On *one of* your controllers, update the `neutron-server` resource
definition:

    # pcs resource update neutron-server start-delay=
    # pcs resource update neutron-server op monitor interval=60s
    # pcs resource update neutron-server op start timeout=60s
    # pcs resource update neutron-server clone interleave=true

Add a start constraint to start `neutron-server` after Keystone:

    # pcs constraint order start openstack-keystone-clone \
      then neutron-server-clone

And enable the `neutron-server` resource:

    # pcs resource enable neutron-server-clone

Delete the legacy Neutron resources:

   # for rsrc in neutron-{agents,netns-cleanup,ovs-cleanup}; do
     pcs resource delete $rsrc
     done

Create the `neutron-scale` resource:

    # pcs resource create neutron-scale ocf:neutron:NeutronScale \
      clone globally-unique=true clone-max=3 interleave=true

Wait for the `neutron-scale` resource to become active on all nodes in
your Pacemaker cluster by running `pcs status` and inspecting the
output.  Once `neutron-scale` is active, modify the resource to
restrict it to a single instance:

    # pcs resource disable neutron-scale-clone
    # pcs resource meta neutron-scale-clone clone-max=1
    # pcs resource enable neutron-scale-clone

Create replacement Neutron resources:

    # pcs resource create neutron-ovs-cleanup \
      ocf:neutron:OVSCleanup clone interleave=true \
      meta target-role=Stopped
    # pcs resource create neutron-netns-cleanup \
      ocf:neutron:NetnsCleanup clone interleave=true \
      meta target-role=Stopped
    # for rsrc in neutron-{openvswitch,dhcp,l3,metadata}-agent; do
      pcs resource create $rsrc systemd:$rsrc clone interleave=true \
        meta target-role=Stopped
      done

Create colocation constraints for the Neutron resources:

    # pcs constraint colocation add neutron-metadata-agent-clone with neutron-l3-agent-clone
    # pcs constraint colocation add neutron-l3-agent-clone with neutron-dhcp-agent-clone
    # pcs constraint colocation add neutron-dhcp-agent-clone with neutron-openvswitch-agent-clone
    # pcs constraint colocation add neutron-openvswitch-agent-clone with neutron-netns-cleanup-clone
    # pcs constraint colocation add neutron-netns-cleanup-clone with neutron-ovs-cleanup-clone
    # pcs constraint colocation add neutron-ovs-cleanup-clone with neutron-scale-clone

Create start constraints for the Neutron resources:

    # pcs constraint order start neutron-scale-clone then neutron-server-clone
    # pcs constraint order start neutron-scale-clone then neutron-ovs-cleanup-clone
    # pcs constraint order start neutron-ovs-cleanup-clone then neutron-netns-cleanup-clone
    # pcs constraint order start neutron-netns-cleanup-clone then neutron-openvswitch-agent-clone
    # pcs constraint order start neutron-openvswitch-agent-clone then neutron-dhcp-agent-clone
    # pcs constraint order start neutron-dhcp-agent-clone then neutron-l3-agent-clone
    # pcs constraint order start neutron-l3-agent-clone then neutron-metadata-agent-clone

Enable all the Neutron resources:

    # for rsrc in neutron-{netns,ovs}-cleanup neutron-{openvswitch,dhcp,l3,metadata}-agent; do
      pcs resource enable $rsrc-clone
      done

Wait for the Neutron agents to become active by running `neutron
agent-list` and inspecting the output.

## Restart compute services

Restarts OpenStack services on all of the compute hosts.  On each
compute host, run:

    # openstack-service start

## Verification

Run `pcs status` and inspect the output for any errors.  There should
be at least one active instance for every resource (and most resources
should have an instance active on every controller).

Run `nova service-list` and verify that all your Nova services are
active and healthy.

Attempt to boot a Nova instance and ensure that it comes up properly.

