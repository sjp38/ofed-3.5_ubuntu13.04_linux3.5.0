            Open Fabrics Enterprise Distribution (OFED)
                          Version 3.5
                             README

                          February 2013

==============================================================================
Table of contents
==============================================================================

 1.  Overview
 2.  How to Download and Extract the OFED Distribution
 3.  Installing OFED Software
 4.  Building OFED RPMs
 5.  IPoIB Configuration
 6.  Uninstalling OFED
 7.  Upgrading OFED
 8.  Configuration
 9.  Starting and Verifying the IB Fabric
 10. Related Documentation


==============================================================================
1. Overview
==============================================================================

This is the OpenFabrics Enterprise Distribution (OFED) version 3.5
software package supporting InfiniBand and iWARP fabrics. It is composed
of several software modules intended for use on a computer cluster
constructed as an InfiniBand subnet or an iWARP network.

This document describes how to install the various modules and test them in
a Linux environment.

General Notes:
 1) The install script removes all previously installed OFED packages
    and re-installs from scratch. (Note: Configuration files will not
    be removed).  You will be prompted to acknowledge the deletion of
    the old packages.

 2) When installing OFED on an entire [homogeneous] cluster, a common
    strategy is to install the software on one of the cluster nodes
    (perhaps on a shared file system such as NFS). The resulting RPMs,
    created under OFED-X.X.X/RPMS directory, can then be installed on all
    nodes in the cluster using any cluster-aware tools (such as pdsh).

==============================================================================
2. How to Download and Extract the OFED Distribution
==============================================================================

1) Download the OFED-X.X.X.tgz file to your target Linux host.

   If this package is to be installed on a cluster, it is recommended to
   download it to an NFS shared directory.

2) Extract the package using:

     tar xzvf OFED-X.X.X.tgz

==============================================================================
3. Installing OFED Software
==============================================================================

1) Go to the directory into which the package was extracted:

     cd /..../OFED-X.X.X

2) Installing the OFED package must be done as root.  For a
   menu-driven first build and installation, run the installer
   script:

     ./install.pl

   Interactive menus will direct you through the install process.

   Note: After the installer completes, information about the OFED
         installation such as the prefix, the kernel version, and
         installation parameters can be found by running
         /etc/infiniband/info.

         Information on the driver version and source git trees can be found
         using the ofed_info utility


   During the interactive installation of OFED, two files are
   generated: ofed.conf and ofed_net.conf.
   ofed.conf holds the installed software modules and configuration settings
   chosen by the user. ofed_net.conf holds the IPoIB settings chosen by the
   user.

   If the package is installed on a cluster-shared directory, these
   files can then be used to perform an automatic, unattended
   installation of OFED on other machines in the cluster. The
   unattended installation will use the same choices as were selected
   in the interactive installation.

   For an automatic installation on any host, run the following:

     ./OFED-X.X.X/install.pl -c <path>/ofed.conf -n <path>/ofed_net.conf

3) Install script usage:

 Usage: ./install.pl [-c <packages config_file>|--all|--hpc|--basic]
                     [-n|--net <network config_file>]

           -c|--config <packages config_file>. Example of the config file can
                                be found under docs (ofed.conf-example)
           -n|--net <network config_file>      Example of the config file can be
                                found under docs (ofed_net.conf-example)
           -l|--prefix          Set installation prefix.
           -p|--print-available Print available packages for current platform.
                                And create corresponding ofed.conf file.
           -k|--kernel <kernel version>. Default on this system: $(uname -r)
           -s|--kernel-sources  <path to the kernel sources>. Default on this
                                system: /lib/modules/$(uname -r)/build
           --build32            Build 32-bit libraries. Relevant for x86_64 and
                                ppc64 platforms
           --without-depcheck   Skip Distro's libraries check
           -v|-vv|-vvv.         Set verbosity level
           -q.                  Set quiet - no messages will be printed
           --force              Force uninstall RPM coming with Distribution
           --builddir           Change build directory. Default: /var/tmp/

           --all|--hpc|--basic  Install all,hpc or basic packages
                                correspondingly

Notes:
------
   It is possible to rename and/or edit the ofed.conf and ofed_net.conf files.
   Thus it is possible to change user choices (observing the original format).
   See examples of ofed.conf and ofed_net.conf under OFED-X.X.X/docs.
   Run './install.pl -p' to get ofed.conf with all available packages included.

Install Process Results:
------------------------

o The OFED package is installed under <prefix> directory. Default prefix is /usr
o The kernel modules are installed under:
    /lib/modules/`uname -r`/updates/
o The package kernel include files are placed under <prefix>/src/compat-rdma/.
  These includes should be used when building kernel modules which use
  the Openfabrics stack. (Note that these includes, if needed, are
  "backported" to your kernel).
o The raw package (un-backported) source files are placed under
  <prefix>/src/compat-rdma-x.x.x
o The script "openibd" is installed under /etc/init.d/. This script can
  be used to load and unload the software stack.
o The directory /etc/infiniband is created with the files "info" and
  "openib.conf". The "info" script can be used to retrieve OFED
  installation information. The "openib.conf" file contains the list of
  modules that are loaded when the "openibd" script is used.
o The file "90-ib.rules" is installed under /etc/udev/rules.d/
o The file /etc/modprobe.d/ib_ipoib.conf is updated to include the following:
  - "alias ib<n> ib_ipoib" for each ib<n> interface.
o If opensm is installed, the daemon opensmd is installed under /etc/init.d/
o All verbs tests and examples are installed under <prefix>/bin and management
  utilities under <prefix>/sbin
o ofed_info script provides information on the OFED version and git repository.
o man pages will be installed under /usr/share/man/.

==============================================================================
4. Building OFED RPMs
==============================================================================

1) Go to the directory into which the package was extracted:

     cd /..../OFED-X.X.X

2) Run install.pl as explained above
   This script also builds OFED binary RPMs under OFED-X.X.X/RPMS; the sources
   are placed in OFED-X.X.X/SRPMS/.

   Once the install process has completed, the user may run ./install.pl on
   other machines that have the same operating system and kernel to
   install the new RPMs.

Note: Depending on your hardware, the build procedure may take 30-45
      minutes.  Installation, however, is a relatively short process
      (~5 minutes).  A common strategy for OFED installation on large
      homogeneous clusters is to extract the tarball on a network
      file system (such as NFS), build OFED RPMs on NFS, and then run the
      installer on each node with the RPMs that were previously built.

==============================================================================
5. IP-over-IB (IPoIB) Configuration
==============================================================================

Configuring IPoIB is an optional step during the installation.  During
an interactive installation, the user may choose to insert the ifcfg-ib<n>
files.  If this option is chosen, the ifcfg-ib<n> files will be
installed under:

- RedHat: /etc/sysconfig/network-scripts/
- SuSE:   /etc/sysconfig/network/

Setting IPoIB Configuration:
----------------------------
There is no default configuration for IPoIB interfaces.

One should manually specify the full IP configuration during the
interactive installation: IP address, network address, netmask, and
broadcast address, or use the ofed_net.conf file.

For bonding setting please see "ipoib_release_notes.txt"

For unattended installations, a configuration file can be provided
with this information.  The configuration file must specify the
following information:
- Fixed values for each IPoIB interface
- Base IPoIB configuration on Ethernet configuration (may be useful for
  cluster configuration)

Here are some examples of ofed_net.conf:

# Static settings; all values provided by this file
IPADDR_ib0=172.16.0.4
NETMASK_ib0=255.255.0.0
NETWORK_ib0=172.16.0.0
BROADCAST_ib0=172.16.255.255
ONBOOT_ib0=1

# Based on eth0; each '*' will be replaced by the script with corresponding
# octet from eth0.
LAN_INTERFACE_ib0=eth0
IPADDR_ib0=172.16.'*'.'*'
NETMASK_ib0=255.255.0.0
NETWORK_ib0=172.16.0.0
BROADCAST_ib0=172.16.255.255
ONBOOT_ib0=1

# Based on the first eth<n> interface that is found (for n=0,1,...);
# each '*' will be replaced by the script with corresponding octet from eth<n>.
LAN_INTERFACE_ib0=
IPADDR_ib0=172.16.'*'.'*'
NETMASK_ib0=255.255.0.0
NETWORK_ib0=172.16.0.0
BROADCAST_ib0=172.16.255.255
ONBOOT_ib0=1

==============================================================================
6. Uninstalling OFED
==============================================================================

There are two ways to uninstall OFED:
1) Via the installation menu.
2) Using the script ofed_uninstall.sh. The script is part of ofed-scripts
   package.
3) ofed_uninstall.sh script supports an option to executes 'openibd stop'
   before removing the RPMs using the flag: --unload-modules

==============================================================================
7. Upgrading OFED
==============================================================================

If an old OFED version is installed, it may be upgraded by installing a
new OFED version as described in section 5. Note that if the old OFED
version was loaded before upgrading, you need to restart OFED or reboot
your machine in order to start the new OFED stack.

==============================================================================
8. Configuration
==============================================================================

Most of the OFED components can be configured or reconfigured after
the installation by modifying the relevant configuration files.  The
list of the modules that will be loaded automatically upon boot can be
found in the /etc/infiniband/openib.conf file.  Other configuration
files include:
- OpenSM configuration file: /etc/ofa/opensm.conf (for RedHat)
                             /etc/sysconfig/opensm (for SuSE) - should be
                             created manually if required.
- DAPL configuration file:   /etc/dat.conf

See packages Release Notes for more details.

Note: After the installer completes, information about the OFED
      installation such as the prefix, kernel version, and
      installation parameters can be found by running
      /etc/infiniband/info.


==============================================================================
9. Starting and Verifying the IB Fabric
==============================================================================
1)  If you rebooted your machine after the installation process completed,
    IB interfaces should be up. If you did not reboot your machine, please
    enter the following command: /etc/init.d/openibd restart

2)  Check that the IB driver is running on all nodes: ibv_devinfo should print
    "hca_id: <linux device name>" on the first line.

3)  Make sure that a Subnet Manager is running by invoking the sminfo utility.
    If an SM is not running, sminfo prints:
    sminfo: iberror: query failed
    If an SM is running, sminfo prints the LID and other SM node information.
    Example:
    sminfo: sm lid 0x1 sm guid 0x2c9010b7c2ae1, activity count 20 priority 1

    To check if OpenSM is running on the management node, enter: /etc/init.d/opensmd status
    To start OpenSM, enter: /etc/init.d/opensmd start

    Note: OpenSM parameters can be set via the file /etc/opensm/opensm.conf

4)  Verify the status of ports by using ibv_devinfo: all connected ports should
    report a "PORT_ACTIVE" state.

5)  Check the network connectivity status: run ibchecknet to see if the subnet
    is "clean" and ready for ULP/application use. The following tools display
    more information in addition to IB info: ibnetdiscover, ibhosts, and
    ibswitches.

6)  Alternatively, instead of running steps 3 to 5 you can use the ibdiagnet
    utility to perform a set of tests on your network. Upon finding an error,
    ibdiagnet will print a message starting with a "-E-". For a more complete
    report of the network features you should run ibdiagnet -r. If you have a
    topology file describing your network you can feed this file to ibdiagnet
    (using the option: -t <file>) and all reports will use the names they
    appear in the file (instead of LIDs, GUIDs and directed routes).


==============================================================================
10. Related Documentation
==============================================================================

OFED documentation is located in the ofed-docs RPM.  After
installation the documents are located under the directory:
/usr/share/doc/ofed-docs-x.x.x for RedHat
/usr/share/doc/packages/ofed-docs-x.x.x for SuSE

Documents list:

   o README.txt
   o OFED_Installation_Guide.txt
   o Examples of configuration files
   o OFED_tips.txt
   o HOWTO.build_ofed
   o All release notes and README files

For more information, please visit the OpenFabrics web site:
   http://www.openfabrics.org
