#!/usr/bin/perl
#
# Copyright (c) 2012 Mellanox Technologies. All rights reserved.
#
# This Software is licensed under one of the following licenses:
#
# 1) under the terms of the "Common Public License 1.0" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/cpl.php.
#
# 2) under the terms of the "The BSD License" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/bsd-license.php.
#
# 3) under the terms of the "GNU General Public License (GPL) Version 2" a
#    copy of which is available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/gpl-license.php.
#
# Licensee has the right to choose one of the above licenses.
#
# Redistributions of source code must retain the above copyright
# notice and one of the license notices.
#
# Redistributions in binary form must reproduce both the above copyright
# notice, one of the license notices in the documentation
# and/or other materials provided with the distribution.


use strict;
use File::Basename;
use File::Path;
use File::Find;
use File::Copy;
use Cwd;
use Term::ANSIColor qw(:constants);
use sigtrap 'handler', \&sig_handler, 'normal-signals';

if ($<) {
    print RED "Only root can run $0", RESET "\n";
    exit 1;
}

$| = 1;
my $LOCK_EXCLUSIVE = 2;
my $UNLOCK         = 8;
#Setup some defaults
my $KEY_ESC=27;
my $KEY_CNTL_C=3;
my $KEY_ENTER=13;

my $BASIC = 1;
my $HPC = 2;
my $ALL = 3;
my $CUSTOM = 4;

my $interactive = 1;
my $quiet = 0;
my $verbose = 1;
my $verbose2 = 0;
my $verbose3 = 0;

my $print_available = 0;

my $clear_string = `clear`;
my $bonding_force_all_os = 0;

my $vendor_pre_install = "";
my $vendor_post_install = "";
my $vendor_pre_uninstall = "";
my $vendor_post_uninstall = "";

my $DISTRO = "";
my $rpmbuild_flags = "";
my $rpminstall_flags = "";

my $WDIR    = dirname($0);
chdir $WDIR;
my $CWD     = getcwd;
my $TMPDIR  = '/tmp';
my $netdir;

my $config = $CWD . '/ofed.conf';
chomp $config;
my $config_net;

my $builddir = "/var/tmp/";
chomp $builddir;

my $PACKAGE     = 'OFED';
my $ofedlogs = "/tmp/$PACKAGE.$$.logs";
mkpath([$ofedlogs]);

my $default_prefix = '/usr';
chomp $default_prefix;
my $prefix = $default_prefix;

my $build32 = 0;
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;
my $kernel_sources = "/lib/modules/$kernel/build";
chomp $kernel_sources;
my $ib_udev_rules = "/etc/udev/rules.d/90-ib.rules";

# Define RPMs environment
my $dist_rpm;
my $dist_rpm_ver = 0;
my $dist_rpm_rel = 0;

my $umad_dev_rw = 0;
my $config_given = 0;
my $config_net_given = 0;
my $kernel_given = 0;
my $kernel_source_given = 0;
my $install_option;
my $check_linux_deps = 1;
my $force = 0;
my $kmp = 1;

while ( $#ARGV >= 0 ) {

   my $cmd_flag = shift(@ARGV);

    if ( $cmd_flag eq "-c" or $cmd_flag eq "--config" ) {
        $config = shift(@ARGV);
        $interactive = 0;
        $config_given = 1;
    } elsif ( $cmd_flag eq "-n" or $cmd_flag eq "--net" ) {
        $config_net = shift(@ARGV);
        $config_net_given = 1;
    } elsif ( $cmd_flag eq "-l" or $cmd_flag eq "--prefix" ) {
        $prefix = shift(@ARGV);
        $prefix =~ s/\/$//;
    } elsif ( $cmd_flag eq "-k" or $cmd_flag eq "--kernel" ) {
        $kernel = shift(@ARGV);
        $kernel_given = 1;
    } elsif ( $cmd_flag eq "-s" or $cmd_flag eq "--kernel-sources" ) {
        $kernel_sources = shift(@ARGV);
        $kernel_source_given = 1;
    } elsif ( $cmd_flag eq "-p" or $cmd_flag eq "--print-available" ) {
        $print_available = 1;
    } elsif ( $cmd_flag eq "--force" ) {
        $force = 1;
    } elsif ( $cmd_flag eq "--all" ) {
        $interactive = 0;
        $install_option = 'all';
    } elsif ( $cmd_flag eq "--hpc" ) {
        $interactive = 0;
        $install_option = 'hpc';
    } elsif ( $cmd_flag eq "--basic" ) {
        $interactive = 0;
        $install_option = 'basic';
    } elsif ( $cmd_flag eq "--umad-dev-rw" ) {
        $umad_dev_rw = 1;
    } elsif ( $cmd_flag eq "--build32" ) {
        if (supported32bit()) {
            $build32 = 1;
        }
    } elsif ( $cmd_flag eq "--without-depcheck" ) {
        $check_linux_deps = 0;
    } elsif ( $cmd_flag eq "--builddir" ) {
        $builddir = shift(@ARGV);
    } elsif ( $cmd_flag eq "-q" ) {
        $quiet = 1;
    } elsif ( $cmd_flag eq "-v" ) {
        $verbose = 1;
    } elsif ( $cmd_flag eq "-vv" ) {
        $verbose = 1;
        $verbose2 = 1;
    } elsif ( $cmd_flag eq "-vvv" ) {
        $verbose = 1;
        $verbose2 = 1;
        $verbose3 = 1;
    } else {
        &usage();
        exit 1;
    }
}

if (-f "/etc/issue") {
    if (-f "/usr/bin/dpkg") {
        if ( `which rpm` eq ""){
            print RED "rpm package is not installed. Exiting...", RESET "\n";
            print RED "Please run 'sudo apt-get install rpm'", RESET "\n";
            exit 1;
        }
        if (-f "/etc/lsb-release") {
            $dist_rpm  = `lsb_release -s -i`;
            $dist_rpm_ver = `lsb_release -s -r`;
        }
        else {
            print "lsb_release is required to continue\n";
            $dist_rpm = "unsupported";
        }
    }
    else {
        $dist_rpm = `rpm -qf /etc/issue 2> /dev/null | grep -v "is not owned by any package" | head -1`;
        chomp $dist_rpm;
        if ($dist_rpm) {
            $dist_rpm = `rpm -q --queryformat "[%{NAME}]-[%{VERSION}]-[%{RELEASE}]" $dist_rpm`;
            chomp $dist_rpm;
            $dist_rpm_ver = get_rpm_ver_inst($dist_rpm);
            $dist_rpm_rel = get_rpm_rel_inst($dist_rpm);
        } else {
            $dist_rpm = "unsupported";
        }
    }
}
else {
    $dist_rpm = "unsupported";
}
chomp $dist_rpm;

my $rpm_distro = '';

if ($dist_rpm =~ /openSUSE-release-11.2/) {
    $DISTRO = "openSUSE11.2";
    $rpm_distro = "opensuse11sp2";
} elsif ($dist_rpm =~ /openSUSE/) {
    $DISTRO = "openSUSE";
    $rpm_distro = "opensuse11sp0";
} elsif ($dist_rpm =~ /sles-release-11.2/) {
    $DISTRO = "SLES11.2";
    $rpm_distro = "sles11sp2";
} elsif ($dist_rpm =~ /sles-release-11.1/) {
    $DISTRO = "SLES11.1";
    $rpm_distro = "sles11sp1";
} elsif ($dist_rpm =~ /sles-release-11/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp0";
} elsif ($dist_rpm =~ /sles-release-10-15.45.8/) {
    $DISTRO = "SLES10";
    $rpm_distro = "sles10sp3";
} elsif ($dist_rpm =~ /sles-release-10-15.57.1/) {
    $DISTRO = "SLES10";
    $rpm_distro = "sles10sp4";
} elsif ($dist_rpm =~ /redhat-release-.*-6.1|sl-release-6.1|centos-release-6-1/) {
    $DISTRO = "RHEL6.1";
    $rpm_distro = "rhel6u1";
} elsif ($dist_rpm =~ /redhat-release-.*-6.2|sl-release-6.2|centos-release-6-2/) {
    $DISTRO = "RHEL6.2";
    $rpm_distro = "rhel6u2";
} elsif ($dist_rpm =~ /redhat-release-.*-6.3|sl-release-6.3|centos-release-6-3/) {
    $DISTRO = "RHEL6.3";
    $rpm_distro = "rhel6u3";
} elsif ($dist_rpm =~ /oraclelinux-release-6.*-1.0.2/) {
    $DISTRO = "OEL6.1";
    $rpm_distro = "oel6u1";
} elsif ($dist_rpm =~ /oraclelinux-release-6.*-2.0.2/) {
    $DISTRO = "OEL6.2";
    $rpm_distro = "oel6u2";
} elsif ($dist_rpm =~ /redhat-release-.*-6.0|centos-release-6-0/) {
    $DISTRO = "RHEL6.0";
    $rpm_distro = "rhel6u0";
} elsif ($dist_rpm =~ /redhat-release-.*-5.8|centos-release-5-8|enterprise-release-5-8/) {
    $DISTRO = "RHEL5.8";
    $rpm_distro = "rhel5u8";
} elsif ($dist_rpm =~ /redhat-release-.*-5.7|centos-release-5-7|enterprise-release-5-7/) {
    $DISTRO = "RHEL5.7";
    $rpm_distro = "rhel5u7";
} elsif ($dist_rpm =~ /redhat-release-.*-5.6|centos-release-5-6|enterprise-release-5-6/) {
    $DISTRO = "RHEL5.6";
    $rpm_distro = "rhel5u6";
} elsif ($dist_rpm =~ /redhat-release-.*-5.5|centos-release-5-5|enterprise-release-5-5/) {
    system("grep -wq XenServer /etc/issue > /dev/null 2>&1");
    my $res = $? >> 8;
    my $sig = $? & 127; 
    if ($sig or $res) {
        $DISTRO = "RHEL5.5";
        $rpm_distro = "rhel5u5";
    } else {
        $DISTRO = "XenServer5.6";
        $rpm_distro = "xenserver5u6";
    }
} elsif ($dist_rpm =~ /redhat-release-.*-5.4|centos-release-5-4/) {
    $DISTRO = "RHEL5.4";
    $rpm_distro = "rhel5u4";
} elsif ($dist_rpm =~ /redhat-release-.*-5.3|centos-release-5-3/) {
    $DISTRO = "RHEL5.3";
    $rpm_distro = "rhel5u3";
} elsif ($dist_rpm =~ /redhat-release-.*-5.2|centos-release-5-2/) {
    $DISTRO = "RHEL5.2";
    $rpm_distro = "rhel5u2";
} elsif ($dist_rpm =~ /redhat-release-4AS-9/) {
    $DISTRO = "RHEL4.8";
    $rpm_distro = "rhel4u8";
} elsif ($dist_rpm =~ /redhat-release-4AS-8/) {
    $DISTRO = "RHEL4.7";
    $rpm_distro = "rhel4u7";
} elsif ($dist_rpm =~ /fedora-release-12/) {
    $DISTRO = "FC12";
    $rpm_distro = "fc12";
} elsif ($dist_rpm =~ /fedora-release-13/) {
    $DISTRO = "FC13";
    $rpm_distro = "fc13";
} elsif ($dist_rpm =~ /fedora-release-14/) {
    $DISTRO = "FC14";
    $rpm_distro = "fc14";
} elsif ($dist_rpm =~ /Ubuntu/) {
    $DISTRO = "UBUNTU$dist_rpm_ver";
    $rpm_distro =~ tr/[A-Z]/[a-z]/;
    $rpm_distro =~ s/\./u/g;
} elsif ( -f "/etc/debian_version" ) {
    $DISTRO = "DEBIAN";
    $rpm_distro = "debian";
} else {
    $DISTRO = "unsupported";
    $rpm_distro = "unsupported";
}

my $SRPMS = $CWD . '/' . 'SRPMS/';
chomp $SRPMS;
my $RPMS  = $CWD . '/' . 'RPMS' . '/' . $dist_rpm . '/' . $arch;
chomp $RPMS;
if (not -d $RPMS) {
    mkpath([$RPMS]);
}

my $target_cpu  = `rpm --eval '%{_target_cpu}'`;
chomp $target_cpu;

my $target_cpu32;
if ($arch eq "x86_64") {
    if (-f "/etc/SuSE-release") {
        $target_cpu32 = 'i586';
    }
    else {
        $target_cpu32 = 'i686';
    }
}
elsif ($arch eq "ppc64") {
    $target_cpu32 = 'ppc';
}
elsif ($arch eq "sparc64") {
    $target_cpu32 = 'sparc';
}

chomp $target_cpu32;

if ($kernel_given and not $kernel_source_given) {
    if (-d "/lib/modules/$kernel/build") {
        $kernel_sources = "/lib/modules/$kernel/build";
    }
    else {
        print RED "Provide path to the kernel sources for $kernel kernel.", RESET "\n";
        exit 1;
    }
}

my $kernel_rel = $kernel;
$kernel_rel =~ s/-/_/g;

if ($DISTRO eq "DEBIAN") {
    $check_linux_deps = 0;
}
if ($DISTRO =~ /UBUNTU.*/) {
    $rpminstall_flags .= ' --force-debian --nodeps ';
    $rpmbuild_flags .= ' --nodeps ';
}

if (not $check_linux_deps) {
    $rpmbuild_flags .= ' --nodeps';
    $rpminstall_flags .= ' --nodeps';
}
my $optflags  = `rpm --eval '%{optflags}'`;
chomp $optflags;

my $mandir      = `rpm --eval '%{_mandir}'`;
chomp $mandir;
my $sysconfdir  = `rpm --eval '%{_sysconfdir}'`;
chomp $sysconfdir;
my %main_packages = ();
my @selected_packages = ();
my @selected_by_user = ();
my @selected_modules_by_user = ();
my @packages_to_uninstall = ();
my @dependant_packages_to_uninstall = ();
my %selected_for_uninstall = ();
my @selected_kernel_modules = ();


my $libstdc = '';
my $libgcc = 'libgcc';
my $libgfortran = '';
my $curl_devel = 'curl-devel';
if ($DISTRO eq "openSUSE11.2") {
    $libstdc = 'libstdc++44';
    $libgcc = 'libgcc44';
    $libgfortran = 'libgfortran44';
} elsif ($DISTRO eq "openSUSE") {
    $libstdc = 'libstdc++42';
    $libgcc = 'libgcc42';
} elsif ($DISTRO =~ /UBUNTU/) {
    $libstdc = 'libstdc++6';
    $libgfortran = 'libgfortran3';
} elsif ($DISTRO =~ m/SLES11/) {
    $libstdc = 'libstdc++43';
    $libgcc = 'libgcc43';
    $libgfortran = 'libgfortran43';
    $curl_devel = 'libcurl-devel';
    if ($rpm_distro eq "sles11sp2") {
        $libstdc = 'libstdc++46';
        $libgcc = 'libgcc46';
        $libgfortran = 'libgfortran46';
    }
} elsif ($DISTRO =~ m/RHEL|OEL|FC/) {
    $libstdc = 'libstdc++';
    $libgcc = 'libgcc';
    $libgfortran = 'gcc-gfortran';
    if ($DISTRO =~ m/RHEL6|OEL6|FC14/) {
        $curl_devel = 'libcurl-devel';
    }
} else {
    $libstdc = 'libstdc++';
}
my $libstdc_devel = "$libstdc-devel";

# Suffix for 32 and 64 bit packages
my $is_suse_suff64 = $arch eq "ppc64" && $DISTRO !~ /SLES11/;
my $suffix_32bit = ($DISTRO =~ m/SLES|openSUSE/ && !$is_suse_suff64) ? "-32bit" : ".$target_cpu32";
my $suffix_64bit = ($DISTRO =~ m/SLES|openSUSE/ &&  $is_suse_suff64) ? "-64bit" : "";

sub usage
{
   print GREEN;
   print "\n Usage: $0 [-c <packages config_file>|--all|--hpc|--basic] [-n|--net <network config_file>]\n";

   print "\n           -c|--config <packages config_file>. Example of the config file can be found under docs (ofed.conf-example).";
   print "\n           -n|--net <network config_file>      Example of the config file can be found under docs (ofed_net.conf-example).";
   print "\n           -l|--prefix          Set installation prefix.";
   print "\n           -p|--print-available Print available packages for current platform.";
   print "\n                                And create corresponding ofed.conf file.";
   print "\n           -k|--kernel <kernel version>. Default on this system: $kernel";
   print "\n           -s|--kernel-sources  <path to the kernel sources>. Default on this system: $kernel_sources";
   print "\n           --build32            Build 32-bit libraries. Relevant for x86_64 and ppc64 platforms";
   print "\n           --without-depcheck   Skip Distro's libraries check";
   print "\n           -v|-vv|-vvv          Set verbosity level";
   print "\n           -q                   Set quiet - no messages will be printed";
   print "\n           --force              Force uninstall RPM coming with Distribution";
   print "\n           --builddir           Change build directory. Default: $builddir";
   print "\n           --umad-dev-rw        Grant non root users read/write permission for umad devices instead of default";
   print "\n\n           --all|--hpc|--basic    Install all,hpc or basic packages correspondingly";
   print RESET "\n\n";
}

my $sysfsutils;
my $sysfsutils_devel;

if ($DISTRO =~ m/SLES|openSUSE/) {
    $sysfsutils = "sysfsutils";
    $sysfsutils_devel = "sysfsutils";
} elsif ($DISTRO =~ m/RHEL5/) {
    $sysfsutils = "libsysfs";
    $sysfsutils_devel = "libsysfs";
} elsif ($DISTRO =~ m/RHEL6|OEL6/) {
    $sysfsutils = "libsysfs";
    $sysfsutils_devel = "libsysfs";
}

my $kernel_req = "";
if ($DISTRO =~ /RHEL|OEL/) {
    $kernel_req = "redhat-rpm-config";
} elsif ($DISTRO =~ /SLES10/) {
    $kernel_req = "kernel-syms";
} elsif ($DISTRO =~ /SLES11/) {
    $kernel_req = "kernel-source";
}

my $network_dir;
if ($DISTRO =~ m/SLES/) {
    $network_dir = "/etc/sysconfig/network";
}
else {
    $network_dir = "/etc/sysconfig/network-scripts";
}

my $setpci = '/sbin/setpci';
my $lspci = '/sbin/lspci';

# List of packages that were included in the previous OFED releases
# for uninstall purpose
my @prev_ofed_packages = (
                        "mpich_mlx", "ibtsal", "openib", "opensm", "opensm-devel", "opensm-libs",
                        "mpi_ncsa", "mpi_osu", "thca", "ib-osm", "osm", "diags", "ibadm",
                        "ib-diags", "ibgdiag", "ibdiag", "ib-management",
                        "ib-verbs", "ib-ipoib", "ib-cm", "ib-sdp", "ib-dapl", "udapl",
                        "udapl-devel", "libdat", "libibat", "ib-kdapl", "ib-srp", "ib-srp_target",
                        "libipathverbs", "libipathverbs-devel",
                        "libehca", "libehca-devel", "dapl", "dapl-devel",
                        "libibcm", "libibcm-devel", "libibcommon", "libibcommon-devel",
                        "libibmad", "libibmad-devel", "libibumad", "libibumad-devel",
                        "ibsim", "ibsim-debuginfo",
                        "libibverbs", "libibverbs-devel", "libibverbs-utils",
                        "libipathverbs", "libipathverbs-devel", "libmthca",
                        "libmthca-devel", "libmlx4", "libmlx4-devel",
                        "libsdp", "librdmacm", "librdmacm-devel", "librdmacm-utils", "ibacm",
                        "openib-diags", "openib-mstflint", "openib-perftest", "openib-srptools", "openib-tvflash",
                        "openmpi", "openmpi-devel", "openmpi-libs",
                        "ibutils", "ibutils-devel", "ibutils-libs", "ibutils2", "ibutils2-devel",
                        "libnes", "libnes-devel",
                        "infinipath-psm", "infinipath-psm-devel",
                        "mvapich", "openmpi", "mvapich2"
                        );


my @distro_ofed_packages = (
                        "libamso", "libamso-devel", "dapl2", "dapl2-devel", "mvapich", "mvapich2", "mvapich2-devel",
                        "mvapich-devel", "libboost_mpi1_36_0", "boost-devel", "boost-doc", "libmthca-rdmav2", "libcxgb3-rdmav2", "libcxgb4-rdmav2",
                        "libmlx4-rdmav2", "libibmad1", "libibumad1", "libibcommon1", "ofed", "ofa",
                        "scsi-target-utils", "rdma-ofa-agent", "libibumad3", "libibmad5"
                        );

my @mlnx_en_packages = (
                       "mlnx_en", "mlnx-en-devel", "mlnx_en-devel", "mlnx_en-doc", "mlnx-ofc", "mlnx-ofc-debuginfo"
                        );

# List of all available packages sorted following dependencies
my @kernel_packages = ("compat-rdma", "compat-rdma-devel", "ib-bonding", "ib-bonding-debuginfo");
my @basic_kernel_modules = ("core", "mthca", "mlx4", "mlx4_en", "cxgb3", "cxgb4", "nes", "ehca", "qib", "ipoib");
my @ulp_modules = ("sdp", "srp", "srpt", "rds", "qlgc_vnic", "iser", "nfsrdma");

# kernel modules in "technology preview" status can be installed by
# adding "module=y" to the ofed.conf file in unattended installation mode
# or by selecting the module in custom installation mode during interactive installation
my @tech_preview;

my @kernel_modules = (@basic_kernel_modules, @ulp_modules);

my $kernel_configure_options = '';
my $user_configure_options = '';

my @misc_packages = ("ofed-docs", "ofed-scripts");

my @mpitests_packages = (
                     "mpitests_mvapich_gcc", "mpitests_mvapich_pgi", "mpitests_mvapich_intel", "mpitests_mvapich_pathscale", 
                     "mpitests_mvapich2_gcc", "mpitests_mvapich2_pgi", "mpitests_mvapich2_intel", "mpitests_mvapich2_pathscale", 
                     "mpitests_openmpi_gcc", "mpitests_openmpi_pgi", "mpitests_openmpi_intel", "mpitests_openmpi_pathscale" 
                    );

my @mpi_packages = ( "mpi-selector",
                     "mvapich_gcc", "mvapich_pgi", "mvapich_intel", "mvapich_pathscale", 
                     "mvapich2_gcc", "mvapich2_pgi", "mvapich2_intel", "mvapich2_pathscale", 
                     "openmpi_gcc", "openmpi_pgi", "openmpi_intel", "openmpi_pathscale", 
                     @mpitests_packages
                    );

my @user_packages = ("libibverbs", "libibverbs-devel", "libibverbs-devel-static", 
                     "libibverbs-utils", "libibverbs-debuginfo",
                     "libmthca", "libmthca-devel-static", "libmthca-debuginfo", 
                     "libmlx4", "libmlx4-devel", "libmlx4-debuginfo",
                     "libehca", "libehca-devel-static", "libehca-debuginfo",
                     "libcxgb3", "libcxgb3-devel", "libcxgb3-debuginfo",
                     "libcxgb4", "libcxgb4-devel", "libcxgb4-debuginfo",
                     "libnes", "libnes-devel-static", "libnes-debuginfo",
                     "libipathverbs", "libipathverbs-devel", "libipathverbs-debuginfo",
                     "libibcm", "libibcm-devel", "libibcm-debuginfo",
                     "libibumad", "libibumad-devel", "libibumad-static", "libibumad-debuginfo",
                     "libibmad", "libibmad-devel", "libibmad-static", "libibmad-debuginfo",
                     "ibsim", "ibsim-debuginfo", "ibacm",
                     "librdmacm", "librdmacm-utils", "librdmacm-devel", "librdmacm-debuginfo",
                     "libsdp", "libsdp-devel", "libsdp-debuginfo",
                     "opensm", "opensm-libs", "opensm-devel", "opensm-debuginfo", "opensm-static",
                     "compat-dapl", "compat-dapl-devel",
                     "dapl", "dapl-devel", "dapl-devel-static", "dapl-utils", "dapl-debuginfo",
                     "perftest", "mstflint",
                     "qlvnictools", "sdpnetstat", "srptools", "rds-tools", "rds-devel",
                     "ibutils", "infiniband-diags", "qperf", "qperf-debuginfo",
                     "ofed-docs", "ofed-scripts",
                     "infinipath-psm", "infinipath-psm-devel", @mpi_packages
                     );

my @basic_kernel_packages = ("compat-rdma");
my @basic_user_packages = ("libibverbs", "libibverbs-utils", "libmthca", "libmlx4",
                            "libehca", "libcxgb3", "libcxgb4", "libnes", "libipathverbs", "librdmacm", "librdmacm-utils",
                            "mstflint", @misc_packages);

my @hpc_kernel_packages = ("compat-rdma", "ib-bonding");
my @hpc_kernel_modules = (@basic_kernel_modules);
my @hpc_user_packages = (@basic_user_packages, "librdmacm",
                        "librdmacm-utils", "compat-dapl", "compat-dapl-devel", "dapl", "dapl-devel", "dapl-devel-static", "dapl-utils",
                        "infiniband-diags", "ibutils", "qperf", "mstflint", "perftest", @mpi_packages);

# all_packages is required to save ordered (following dependencies) list of
# packages. Hash does not saves the order
my @all_packages = (@kernel_packages, @user_packages);

my %kernel_modules_info = (
        'core' =>
            { name => "core", available => 1, selected => 0,
            included_in_rpm => 0, requires => [], },
        'mthca' =>
            { name => "mthca", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx4' =>
            { name => "mlx4", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx4_en' =>
            { name => "mlx4_en", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ehca' =>
            { name => "ehca", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipath' =>
            { name => "ipath", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'qib' =>
            { name => "qib", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb3' =>
            { name => "cxgb3", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb4' =>
            { name => "cxgb4", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'nes' =>
            { name => "nes", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipoib' =>
            { name => "ipoib", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'sdp' =>
            { name => "sdp", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'srp' =>
            { name => "srp", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'srpt' =>
            { name => "srpt", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'rds' =>
            { name => "rds", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'iser' =>
            { name => "iser", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], ofa_req_inst => [] },
        'qlgc_vnic' =>
            { name => "qlgc_vnic", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'nfsrdma' =>
            { name => "nfsrdma", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        );

my %packages_info = (
        # Kernel packages
        'compat-rdma' =>
            { name => "compat-rdma", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => ["make", "gcc"],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => ["ofed-scripts"], configure_options => '' },
        'compat-rdma' =>
            { name => "compat-rdma", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => ["make", "gcc"],
            dist_req_inst => ["pciutils"], ofa_req_build => [], ofa_req_inst => ["ofed-scripts"], },
        'compat-rdma-devel' =>
            { name => "compat-rdma-devel", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["compat-rdma"], },
        'ib-bonding' =>
            { name => "ib-bonding", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], configure_options => '' },
        'ib-bonding-debuginfo' =>
            { name => "ib-bonding-debuginfo", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        # User space libraries
        'libibverbs' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => 
            ( $build32 == 1 )?["gcc_3.3.3", "glibc-devel$suffix_64bit","glibc-devel$suffix_32bit","$libstdc","$libstdc" . "$suffix_32bit","$libgcc","$libgcc" . "lib32gcc1"]:["gcc_3.3.3", "glibc-devel$suffix_64bit","$libstdc","$libgcc"],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => ["ofed-scripts"], 
            ubuntu_dist_req_build =>( $build32 == 1 )?["gcc", "libc6-dev","libc6-dev-i386","$libstdc",
            "lib32stdc++6","libgcc1","lib32gcc1"]:["gcc", "libc6-dev","$libstdc","libgcc1"], 
            ubuntu_dist_req_inst => [],install32 => 1, exception => 0, configure_options => '' },
        'libibverbs-devel' =>
            { name => "libibverbs-devel", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibverbs-devel-static' =>
            { name => "libibverbs-devel-static", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibverbs-utils' =>
            { name => "libibverbs-utils", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 0, exception => 0 },
        'libibverbs-debuginfo' =>
            { name => "libibverbs-debuginfo", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libmthca' =>
            { name => "libmthca", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libmthca-devel-static' =>
            { name => "libmthca-devel-static", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmthca"],
            install32 => 1, exception => 0 },
        'libmthca-debuginfo' =>
            { name => "libmthca-debuginfo", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libmlx4' =>
            { name => "libmlx4", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libmlx4-devel' =>
            { name => "libmlx4-devel", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmlx4"],
            install32 => 1, exception => 0 },
        'libmlx4-debuginfo' =>
            { name => "libmlx4-debuginfo", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libehca' =>
            { name => "libehca", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libehca-devel-static' =>
            { name => "libehca-devel-static", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libehca"],
            install32 => 1, exception => 0 },
        'libehca-debuginfo' =>
            { name => "libehca-debuginfo", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libcxgb3' =>
            { name => "libcxgb3", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libcxgb3-devel' =>
            { name => "libcxgb3-devel", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libcxgb3"],
            install32 => 1, exception => 0 },
        'libcxgb3-debuginfo' =>
            { name => "libcxgb3-debuginfo", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libcxgb4' =>
            { name => "libcxgb4", parent => "libcxgb4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libcxgb4-devel' =>
            { name => "libcxgb4-devel", parent => "libcxgb4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libcxgb4"],
            install32 => 1, exception => 0 },
        'libcxgb4-debuginfo' =>
            { name => "libcxgb4-debuginfo", parent => "libcxgb4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libnes' =>
            { name => "libnes", parent => "libnes",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libnes-devel-static' =>
            { name => "libnes-devel-static", parent => "libnes",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libnes"],
            install32 => 1, exception => 0 },
        'libnes-debuginfo' =>
            { name => "libnes-debuginfo", parent => "libnes",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libipathverbs' =>
            { name => "libipathverbs", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libipathverbs-devel' =>
            { name => "libipathverbs-devel", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libipathverbs"],
            install32 => 1, exception => 0 },
        'libipathverbs-debuginfo' =>
            { name => "libipathverbs-debuginfo", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibcm' =>
            { name => "libibcm", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0, configure_options => '' },
        'libibcm-devel' =>
            { name => "libibcm-devel", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libibverbs-devel", "libibcm"],
            install32 => 1, exception => 0 },
        'libibcm-debuginfo' =>
            { name => "libibcm-debuginfo", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        # Management
        'libibumad' =>
            { name => "libibumad", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["libtool"],
            dist_req_inst => [],ubuntu_dist_req_build => ["libtool"],ubuntu_dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 1, exception => 0, configure_options => '' },
        'libibumad-devel' =>
            { name => "libibumad-devel", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibumad"],
            install32 => 1, exception => 0 },
        'libibumad-static' =>
            { name => "libibumad-static", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibumad"],
            install32 => 1, exception => 0 },
        'libibumad-debuginfo' =>
            { name => "libibumad-debuginfo", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibmad' =>
            { name => "libibmad", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["libtool"],
            dist_req_inst => [],ubuntu_dist_req_build => ["libtool"],ubuntu_dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad"],
            install32 => 1, exception => 0, configure_options => '' },
        'libibmad-devel' =>
            { name => "libibmad-devel", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibmad", "libibumad-devel"],
            install32 => 1, exception => 0 },
        'libibmad-static' =>
            { name => "libibmad-static", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibmad", "libibumad-devel"],
            install32 => 1, exception => 0 },
        'libibmad-debuginfo' =>
            { name => "libibmad-debuginfo", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'opensm' =>
            { name => "opensm", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["bison", "flex"],
            dist_req_inst => [],ubuntu_dist_req_build => ["bison", "flex"],ubuntu_dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'opensm-devel' =>
            { name => "opensm-devel", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad-devel", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-libs' =>
            { name => "opensm-libs", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["bison", "flex"],
            dist_req_inst => [],ubuntu_dist_req_build => ["bison", "flex"],ubuntu_dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad"],
            install32 => 1, exception => 0 },
        'opensm-static' =>
            { name => "opensm-static", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad-devel", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-debuginfo' =>
            { name => "opensm-debuginfo", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibsim' =>
            { name => "ibsim", parent => "ibsim",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibmad-devel"],
            ofa_req_inst => ["libibumad", "libibmad"],
            install32 => 0, exception => 0, configure_options => '' },
        'ibsim-debuginfo' =>
            { name => "ibsim-debuginfo", parent => "ibsim",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibmad-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },

        'ibacm' =>
            { name => "ibacm", parent => "ibacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel", "libibumad-devel"],
            ofa_req_inst => ["libibverbs", "libibumad"],
            install32 => 0, exception => 0, configure_options => '' },
        'librdmacm' =>
            { name => "librdmacm", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libibverbs-devel"],
            install32 => 1, exception => 0, configure_options => '' },
        'librdmacm-devel' =>
            { name => "librdmacm-devel", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["librdmacm"],
            install32 => 1, exception => 0 },
        'librdmacm-utils' =>
            { name => "librdmacm-utils", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["librdmacm"],
            install32 => 0, exception => 0 },
        'librdmacm-debuginfo' =>
            { name => "librdmacm-debuginfo", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libsdp' =>
            { name => "libsdp", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 1, exception => 0, configure_options => '' },
        'libsdp-devel' =>
            { name => "libsdp-devel", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libsdp"],
            install32 => 1, exception => 0 },
        'libsdp-debuginfo' =>
            { name => "libsdp-debuginfo", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'perftest' =>
            { name => "perftest", parent => "perftest",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel", "librdmacm-devel", "libibumad-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm", "libibumad"],
            install32 => 0, exception => 0, configure_options => '' },
        'perftest-debuginfo' =>
            { name => "perftest-debuginfo", parent => "perftest",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mstflint' =>
            { name => "mstflint", parent => "mstflint",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", 
            dist_req_build => ["zlib-devel$suffix_64bit", "$libstdc_devel$suffix_64bit", "gcc-c++"],
            dist_req_inst => [], ofa_req_build => [],
            ubuntu_dist_req_build => ["zlib1g-dev", "$libstdc_devel", "gcc","g++","byacc"],ubuntu_dist_req_inst => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'mstflint-debuginfo' =>
            { name => "mstflint-debuginfo", parent => "mstflint",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibvexdmtools' =>
            { name => "ibvexdmtools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad"],
            install32 => 0, exception => 0, configure_options => '' },
        'qlgc_vnic_daemon' =>
            { name => "qlgc_vnic_daemon", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'qlvnictools' =>
            { name => "qlvnictools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["ibvexdmtools", "qlgc_vnic_daemon", "libibumad"],
            install32 => 0, exception => 0, configure_options => '' },
        'qlvnictools-debuginfo' =>
            { name => "qlvnictools-debuginfo", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'sdpnetstat' =>
            { name => "sdpnetstat", parent => "sdpnetstat",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'sdpnetstat-debuginfo' =>
            { name => "sdpnetstat-debuginfo", parent => "sdpnetstat",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'srptools' =>
            { name => "srptools", parent => "srptools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["libibumad", "libibverbs"],
            install32 => 0, exception => 0, configure_options => '' },
        'srptools-debuginfo' =>
            { name => "srptools-debuginfo", parent => "srptools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'rnfs-utils' =>
            { name => "rnfs-utils", parent => "rnfs-utils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'rnfs-utils-debuginfo' =>
            { name => "rnfs-utils-debuginfo", parent => "rnfs-utils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'rds-tools' =>
            { name => "rds-tools", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'rds-devel' =>
            { name => "rds-devel", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["rds-tools"],
            install32 => 0, exception => 0, configure_options => '' },
        'rds-tools-debuginfo' =>
            { name => "rds-tools-debuginfo", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'qperf' =>
            { name => "qperf", parent => "qperf",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm"],
            install32 => 0, exception => 0, configure_options => '' },
        'qperf-debuginfo' =>
            { name => "qperf-debuginfo", parent => "qperf",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibutils' =>
            { name => "ibutils", parent => "ibutils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["tcl_8.4", "tcl-devel_8.4", "tk", "$libstdc_devel"],
            dist_req_inst => ["tcl_8.4", "tk", "$libstdc"], ofa_req_build => ["libibverbs-devel", "opensm-libs", "opensm-devel"],
            ofa_req_inst => ["libibumad", "opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'ibutils-debuginfo' =>
            { name => "ibutils-debuginfo", parent => "ibutils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'infiniband-diags' =>
            { name => "infiniband-diags", parent => "infiniband-diags",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["opensm-devel", "libibmad-devel", "libibumad-devel"],
            ofa_req_inst => ["libibumad", "libibmad", "opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'infiniband-diags-debuginfo' =>
            { name => "infiniband-diags-debuginfo", parent => "infiniband-diags",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'compat-dapl' =>
            { name => "dapl", parent => "compat-dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs", "libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm"],
            install32 => 1, exception => 0, configure_options => '' },
        'compat-dapl-devel' =>
            { name => "dapl-devel", parent => "compat-dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["compat-dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl' =>
            { name => "dapl", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs", "libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-devel' =>
            { name => "dapl-devel", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-devel-static' =>
            { name => "dapl-devel-static", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-utils' =>
            { name => "dapl-utils", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => ["dapl"],
            install32 => 0, exception => 0, configure_options => '' },
        'dapl-debuginfo' =>
            { name => "dapl-debuginfo", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel", "librdmacm", "librdmacm-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mpi-selector' =>
            { name => "mpi-selector", parent => "mpi-selector",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["tcsh"],
            dist_req_inst => ["tcsh"], ofa_req_build => [],
            ofa_req_inst => [],
            ubuntu_dist_req_build => ["tcsh"],ubuntu_dist_req_inst => ["tcsh"],
            install32 => 0, exception => 0, configure_options => '' },

        'mvapich' =>
            { name => "mvapich", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibumad"],
            ubuntu_dist_req_build => ["$libstdc_devel"],
            ubuntu_dist_req_inst => ["$libstdc"],
            install32 => 0, exception => 0, configure_options => '' },
        'mvapich_gcc' =>
            { name => "mvapich_gcc", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libgfortran","$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibumad"],
            ubuntu_dist_req_build => ["$libstdc_devel"],
            ubuntu_dist_req_inst => [""],
            install32 => 0, exception => 0 },
        'mvapich_pgi' =>
            { name => "mvapich_pgi", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => [],
            ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich_intel' =>
            { name => "mvapich_intel", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich_pathscale' =>
            { name => "mvapich_pathscale", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibumad"],
            install32 => 0, exception => 0 },

        'mvapich2' =>
            { name => "mvapich2", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [$sysfsutils_devel, "$libstdc_devel"],
            dist_req_inst => [$sysfsutils, "$libstdc"], ofa_req_build => ["libibumad-devel", "libibverbs-devel"],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad", "libibumad-devel"],
            install32 => 0, exception => 0, configure_options => '' },
        'mvapich2_gcc' =>
            { name => "mvapich2_gcc", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["$libgfortran","$sysfsutils_devel", "$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad", "libibumad-devel"],
            install32 => 0, exception => 0 },
        'mvapich2_pgi' =>
            { name => "mvapich2_pgi", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [$sysfsutils_devel, "$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad", "libibumad-devel"],
            install32 => 0, exception => 0 },
        'mvapich2_intel' =>
            { name => "mvapich2_intel", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [$sysfsutils_devel, "$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad", "libibumad-devel"],
            install32 => 0, exception => 0 },
        'mvapich2_pathscale' =>
            { name => "mvapich2_pathscale", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [$sysfsutils_devel, "$libstdc_devel"],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel", "libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad", "libibumad-devel"],
            install32 => 0, exception => 0 },

        'openmpi' =>
            { name => "openmpi", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "mpi-selector", "librdmacm"],
            ubuntu_dist_req_build => ["$libstdc_devel"],
            ubuntu_dist_req_inst => ["$libstdc"],
            install32 => 0, exception => 0, configure_options => '' },
        'openmpi_gcc' =>
            { name => "openmpi_gcc", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["$libgfortran","$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm-devel", "mpi-selector"],
            ubuntu_dist_req_build => ["$libgfortran","$libstdc_devel"],
            ubuntu_dist_req_inst => ["$libstdc"],
            install32 => 0, exception => 0 },
        'openmpi_pgi' =>
            { name => "openmpi_pgi", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm-devel", "mpi-selector"],
            install32 => 0, exception => 0 },
        'openmpi_intel' =>
            { name => "openmpi_intel", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm-devel", "mpi-selector"],
            install32 => 0, exception => 0 },
        'openmpi_pathscale' =>
            { name => "openmpi_pathscale", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => ["$libstdc_devel"],
            dist_req_inst => ["$libstdc"], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm-devel", "mpi-selector"],
            install32 => 0, exception => 0 },

        'mpitests' =>
            { name => "mpitests", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },

        'mpitests_mvapich_gcc' =>
            { name => "mpitests_mvapich_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_pgi' =>
            { name => "mpitests_mvapich_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_pathscale' =>
            { name => "mpitests_mvapich_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_intel' =>
            { name => "mpitests_mvapich_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_intel"],
            install32 => 0, exception => 0 },

        'mpitests_mvapich2_gcc' =>
            { name => "mpitests_mvapich2_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_pgi' =>
            { name => "mpitests_mvapich2_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_pathscale' =>
            { name => "mpitests_mvapich2_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_intel' =>
            { name => "mpitests_mvapich2_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_intel"],
            install32 => 0, exception => 0 },

        'mpitests_openmpi_gcc' =>
            { name => "mpitests_openmpi_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_pgi' =>
            { name => "mpitests_openmpi_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_pathscale' =>
            { name => "mpitests_openmpi_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_intel' =>
            { name => "mpitests_openmpi_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_intel"],
            install32 => 0, exception => 0 },

        'ofed-docs' =>
            { name => "ofed-docs", parent => "ofed-docs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ofed-scripts' =>
            { name => "ofed-scripts", parent => "ofed-scripts",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'infinipath-psm' =>
            { name => "infinipath-psm", parent=> "infinipath-psm",
             selected => 0, installed => 0, rpm_exits => 0, rpm_exists32 => 0,
             available => 0, mode => "user", dist_req_build => [],
             dist_req_inst => [], ofa_req_build => [],
             ofa_req_inst => [], install32 => 0, exception => 0 },
        'infinipath-psm-devel' =>
            { name => "infinipath-psm-devel", parent=> "infinipath-psm",
             selected => 0, installed => 0, rpm_exits => 0, rpm_exists32 => 0,
             available => 0, mode => "user", dist_req_build => [],
             dist_req_inst => [], ofa_req_build => [],
             ofa_req_inst => ["infinipath-psm"], install32 => 0, exception => 0 },
        );


my @hidden_packages = ("ibvexdmtools", "qlgc_vnic_daemon");

my %MPI_SUPPORTED_COMPILERS = (gcc => 0, pgi => 0, intel => 0, pathscale => 0);

my %gcc = ('gcc' => 0, 'gfortran' => 0, 'g77' => 0, 'g++' => 0);
my %pathscale = ('pathcc' => 0, 'pathCC' => 0, 'pathf90' => 0);
my %pgi = ('pgf77' => 0, 'pgf90' => 0, 'pgCC' => 0); 
my %intel = ('icc' => 0, 'icpc' => 0, 'ifort' => 0); 

# mvapich2 environment
my $mvapich2_conf_impl = "ofa";
my $mvapich2_conf_romio = 1;
my $mvapich2_conf_shared_libs = 1;
my $mvapich2_conf_ckpt = 0;
my $mvapich2_conf_blcr_home;
my $mvapich2_conf_vcluster = "small";
my $mvapich2_conf_io_bus;
my $mvapich2_conf_link_speed;
my $mvapich2_conf_dapl_provider = "";
my $mvapich2_comp_env;
my $mvapich2_dat_lib;
my $mvapich2_dat_include;
my $mvapich2_conf_done = 0;

my $TOPDIR = $builddir . '/' . $PACKAGE . "_topdir";
chomp $TOPDIR;

rmtree ("$TOPDIR");
mkpath([$TOPDIR . '/BUILD' ,$TOPDIR . '/RPMS',$TOPDIR . '/SOURCES',$TOPDIR . '/SPECS',$TOPDIR . '/SRPMS']);

if ($config_given and $install_option) {
    print RED "\nError: '-c' option can't be used with '--all|--hpc|--basic'", RESET "\n";
    exit 1;
}

if ($config_given and not -e $config) {
    print RED "$config does not exist", RESET "\n";
    exit 1;
}

if (not $config_given and -e $config) {
    move($config, "$config.save");
}

if ($quiet) {
    $verbose = 0;
    $verbose2 = 0;
    $verbose3 = 0;
}

my %ifcfg = ();
if ($config_net_given and not -e $config_net) {
    print RED "$config_net does not exist", RESET "\n";
    exit 1;
}

my $eth_dev;
if ($config_net_given) {
    open(NET, "$config_net") or die "Can't open $config_net: $!";
    while (<NET>) {
        my ($param, $value) = split('=');
        chomp $param;
        chomp $value;
        my $dev = $param;
        $dev =~ s/(.*)_(ib[0-9]+)/$2/;
        chomp $dev;

        if ($param =~ m/IPADDR/) {
            $ifcfg{$dev}{'IPADDR'} = $value;
        }
        elsif ($param =~ m/NETMASK/) {
            $ifcfg{$dev}{'NETMASK'} = $value;
        }
        elsif ($param =~ m/NETWORK/) {
            $ifcfg{$dev}{'NETWORK'} = $value;
        }
        elsif ($param =~ m/BROADCAST/) {
            $ifcfg{$dev}{'BROADCAST'} = $value;
        }
        elsif ($param =~ m/ONBOOT/) {
            $ifcfg{$dev}{'ONBOOT'} = $value;
        }
        elsif ($param =~ m/LAN_INTERFACE/) {
            $ifcfg{$dev}{'LAN_INTERFACE'} = $value;
        }
        else {
            print RED "Unsupported parameter '$param' in $config_net\n" if ($verbose2);
        }
    }
    close(NET);
}

sub sig_handler
{
    exit 1;
}

sub getch
{
        my $c;
        system("stty -echo raw");
        $c=getc(STDIN);
        system("stty echo -raw");
        # Exit on Ctrl+c or Esc
        if ($c eq "\cC" or $c eq "\e") {
            print "\n";
            exit 1;
        }
        print "$c\n";
        return $c;
}

sub get_rpm_name_arch
{
    my $ret = `rpm --queryformat "[%{NAME}] [%{ARCH}]" -qp @_ | grep -v Freeing`;
    chomp $ret;
    return $ret;
}

sub get_rpm_ver
{
    my $ret = `rpm --queryformat "[%{VERSION}]\n" -qp @_ | uniq`;
    chomp $ret;
    return $ret;
}

sub get_rpm_rel
{
    my $ret = `rpm --queryformat "[%{RELEASE}]\n" -qp @_ | uniq`;
    chomp $ret;
    return $ret;
}

# Get RPM name and version of the INSTALLED package
sub get_rpm_ver_inst
{
    my $ret;
    if ($DISTRO =~ /DEBIAN|UBUNTU/) {
        $ret = `dpkg-query -W -f='\${Version}\n' @_ | cut -d ':' -f 2 | uniq`;
    }
    else {
        $ret = `rpm --queryformat '[%{VERSION}]\n' -q @_ | uniq`;
    }
    chomp $ret;
    return $ret;
}

sub get_rpm_rel_inst
{
    my $ret = `rpm --queryformat "[%{RELEASE}]\n" -q @_ | uniq`;
    chomp $ret;
    return $ret;
}

sub get_rpm_info
{
    my $ret = `rpm --queryformat "[%{NAME}] [%{VERSION}] [%{RELEASE}] [%{DESCRIPTION}]" -qp @_`;
    chomp $ret;
    return $ret;
}

sub supported32bit
{
    if ($arch =~ /i[0-9]86|ia64/) {
        return 0;
    }
    return 1
}

# Check whether compiler $1 exist
sub set_compilers
{
    if (`which gcc 2> /dev/null`) {
        $gcc{'gcc'} = 1;
    }
    if (`which g77 2> /dev/null`) {
        $gcc{'g77'} = 1;
    }
    if (`which g++ 2> /dev/null`) {
        $gcc{'g++'} = 1;
    }
    if (`which gfortran 2> /dev/null`) {
        $gcc{'gfortran'} = 1;
    }

    if (`which pathcc 2> /dev/null`) {
        $pathscale{'pathcc'} = 1;
    }
    if (`which pathCC 2> /dev/null`) {
        $pathscale{'pathCC'} = 1;
    }
    if (`which pathf90 2> /dev/null`) {
        $pathscale{'pathf90'} = 1;
    }

    if (`which pgcc 2> /dev/null`) {
        $pgi{'pgcc'} = 1;
    }
    if (`which pgCC 2> /dev/null`) {
        $pgi{'pgCC'} = 1;
    }
    if (`which pgf77 2> /dev/null`) {
        $pgi{'pgf77'} = 1;
    }
    if (`which pgf90 2> /dev/null`) {
        $pgi{'pgf90'} = 1;
    }

    if (`which icc 2> /dev/null`) {
        $intel{'icc'} = 1;
    }
    if (`which icpc 2> /dev/null`) {
        $intel{'icpc'} = 1;
    }
    if (`which ifort 2> /dev/null`) {
        $intel{'ifort'} = 1;
    }
}

sub set_cfg
{
    my $srpm_full_path = shift @_;

    my $info = get_rpm_info($srpm_full_path);
    my $name = (split(/ /,$info,4))[0];
    my $version = (split(/ /,$info,4))[1];

    ( $main_packages{$name}{'name'},
      $main_packages{$name}{'version'},
      $main_packages{$name}{'release'},
      $main_packages{$name}{'description'} ) = split(/ /,$info,4);
      $main_packages{$name}{'srpmpath'}   = $srpm_full_path;

    print "set_cfg: " .
             "name: $name, " .
             "original name: $main_packages{$name}{'name'}, " .
             "version: $main_packages{$name}{'version'}, " .
             "release: $main_packages{$name}{'release'}, " .
             "srpmpath: $main_packages{$name}{'srpmpath'}\n" if ($verbose3);

}

# Set packages availability depending OS/Kernel/arch
sub set_availability
{
    set_compilers();

    if ($kernel =~ m/^3\.5/) {
            $kernel_modules_info{'rds'}{'available'} = 1;
            $packages_info{'rds-tools'}{'available'} = 1;
            $packages_info{'rds-devel'}{'available'} = 1;
            $packages_info{'rds-tools-debuginfo'}{'available'} = 1;
            $kernel_modules_info{'iser'}{'available'} = 1;
            $kernel_modules_info{'srpt'}{'available'} = 1;
            if ($arch =~ m/ppc64|powerpc/) {
                $kernel_modules_info{'ehca'}{'available'} = 1;
                $packages_info{'libehca'}{'available'} = 1;
                $packages_info{'libehca-devel-static'}{'available'} = 1;
                $packages_info{'libehca-debuginfo'}{'available'} = 1;
            }
    }

    # Ipath
    if ($arch =~ m/x86_64/) {
	    $packages_info{'infinipath-psm'}{'available'} = 1;
	    $packages_info{'infinipath-psm-devel'}{'available'} = 1;
	    if ($kernel =~ m/2\.6\.(27|32|37|38|39)\..*-.*|2\.6\.32-.*\.el6|3\.0\.[1-9][0-9]-*/) {
		    $kernel_modules_info{'qib'}{'available'} = 1;
		    $packages_info{'libipathverbs'}{'available'} = 1;
		    $packages_info{'libipathverbs-devel'}{'available'} = 1;
		    $packages_info{'libipathverbs-debuginfo'}{'available'} = 1;
	    }
    }


    # QLogic vnic
    if ($kernel =~ m/^3\.5/) {
            $kernel_modules_info{'qlgc_vnic'}{'available'} = 1;
            $packages_info{'ibvexdmtools'}{'available'} = 1;
            $packages_info{'qlgc_vnic_daemon'}{'available'} = 1;
            $packages_info{'qlvnictools'}{'available'} = 1;
            $packages_info{'qlvnictools-debuginfo'}{'available'} = 1;
    }

    # NFSRDMA
    if ($kernel =~ m/^3\.5/ or $DISTRO =~ /SLES11.2|RHEL6.[23]/) {
            $kernel_modules_info{'nfsrdma'}{'available'} = 1;
    }

    # mvapich, mvapich2 and openmpi
    if ($gcc{'gcc'}) {
        if ($gcc{'g77'} or $gcc{'gfortran'}) {
            $packages_info{'mvapich_gcc'}{'available'} = 1;
            $packages_info{'mvapich2_gcc'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_gcc'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_gcc'}{'available'} = 1;
        }
        $packages_info{'openmpi_gcc'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_gcc'}{'available'} = 1;
    }
    if ($pathscale{'pathcc'}) {
        if ($pathscale{'pathCC'} and $pathscale{'pathf90'}) {
            $packages_info{'mvapich_pathscale'}{'available'} = 1;
            $packages_info{'mvapich2_pathscale'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_pathscale'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_pathscale'}{'available'} = 1;
        }
        $packages_info{'openmpi_pathscale'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_pathscale'}{'available'} = 1;
    }
    if ($pgi{'pgcc'}) {
        if ($pgi{'pgf77'} and $pgi{'pgf90'}) {
            $packages_info{'mvapich_pgi'}{'available'} = 1;
            $packages_info{'mvapich2_pgi'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_pgi'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_pgi'}{'available'} = 1;
        }
        $packages_info{'openmpi_pgi'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_pgi'}{'available'} = 1;
    }
    if ($intel{'icc'}) {
        if ($intel{'icpc'} and $intel{'ifort'}) {
            $packages_info{'mvapich_intel'}{'available'} = 1;
            $packages_info{'mvapich2_intel'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_intel'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_intel'}{'available'} = 1;
        }
        $packages_info{'openmpi_intel'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_intel'}{'available'} = 1;
    }

    # debuginfo RPM currently are not supported on SuSE
    if ($DISTRO =~ m/SLES/ or $DISTRO eq 'DEBIAN') {
        for my $package (@all_packages) {
            if ($package =~ m/-debuginfo/) {
                $packages_info{$package}{'available'} = 0;
            }
        }
    }
}

# Set rpm_exist parameter for existing RPMs
sub set_existing_rpms
{
    # Check if the ofed-scripts RPM exist and its prefix is the same as required one
    my $scr_rpm = '';
    $scr_rpm = <$RPMS/ofed-scripts-*.$target_cpu.rpm>;
    if ( -f $scr_rpm ) {
        my $current_prefix = `rpm -qlp $scr_rpm | grep ofed_info | sed -e "s@/bin/ofed_info@@"`;
        chomp $current_prefix;
        print "Found $scr_rpm. Its installation prefix: $current_prefix\n" if ($verbose2);
        if (not $current_prefix eq $prefix) {
            print "Required prefix is: $prefix\n" if ($verbose2);
            print "Going to rebuild RPMs from scratch\n" if ($verbose2);
            return;
        }
    }

    for my $binrpm ( <$RPMS/*.rpm> ) {
        my ($rpm_name, $rpm_arch) = (split ' ', get_rpm_name_arch($binrpm));
        $main_packages{$rpm_name}{'rpmpath'}   = $binrpm;
        if ($rpm_name =~ /compat-rdma|ib-bonding/) {
            if (($rpm_arch eq $target_cpu) and (get_rpm_rel($binrpm) eq $kernel_rel)) {
                $packages_info{$rpm_name}{'rpm_exist'} = 1;
                print "$rpm_name RPM exist\n" if ($verbose2);
            }
        }
        else {
            if ($rpm_arch eq $target_cpu) {
                $packages_info{$rpm_name}{'rpm_exist'} = 1;
                print "$rpm_name RPM exist\n" if ($verbose2);
            }
            elsif ($rpm_arch eq $target_cpu32) {
                $packages_info{$rpm_name}{'rpm_exist32'} = 1;
                print "$rpm_name 32-bit RPM exist\n" if ($verbose2);
            }
        }
    }
}

sub mvapich2_config
{
    my $ans;
    my $done;

    if ($mvapich2_conf_done) {
        return;
    }

    if (not $interactive) {
        $mvapich2_conf_done = 1;
        return;
    }

    print "\nPlease choose an implementation of MVAPICH2:\n\n";
    print "1) OFA (IB and iWARP)\n";
    print "2) uDAPL\n";
    $done = 0;

    while (not $done) {
        print "Implementation [1]: ";
        $ans = getch();

        if (ord($ans) == $KEY_ENTER or $ans eq "1") {
            $mvapich2_conf_impl = "ofa";
            $done = 1;
        }

        elsif ($ans eq "2") {
            $mvapich2_conf_impl = "udapl";
            $done = 1;
        }

        else {
            $done = 0;
        }
    }

    print "\nEnable ROMIO support [Y/n]: ";
    $ans = getch();

    if ($ans =~ m/Nn/) {
        $mvapich2_conf_romio = 0;
    }

    else {
        $mvapich2_conf_romio = 1;
    }

    print "\nEnable shared library support [Y/n]: ";
    $ans = getch();

    if ($ans =~ m/Nn/) {
        $mvapich2_conf_shared_libs = 0;
    }

    else {
        $mvapich2_conf_shared_libs = 1;
    }

    # OFA specific options.
    if ($mvapich2_conf_impl eq "ofa") {
        $done = 0;

        while (not $done) {
            print "\nEnable Checkpoint-Restart support [y/N]: ";
            $ans = getch();

            if ($ans =~ m/[Yy]/) {
                $mvapich2_conf_ckpt = 1;
                print "\nBLCR installation directory [or nothing if not installed]: ";
                my $tmp = <STDIN>;
                chomp $tmp;

                if (-d "$tmp") {
                    $mvapich2_conf_blcr_home = $tmp;
                    $done = 1;
                }

                else {
                    print RED "\nBLCR installation directory not found.", RESET "\n";
                }
            }

            else {
                $mvapich2_conf_ckpt = 0;
                $done = 1;
            }
        }
    }

    else {
        $mvapich2_conf_ckpt = 0;
    }

    # uDAPL specific options.
    if ($mvapich2_conf_impl eq "udapl") {
        print "\nCluster size:\n\n1) Small\n2) Medium\n3) Large\n";
        $done = 0;

        while (not $done) {
            print "Cluster size [1]: ";
            $ans = getch();

            if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                $mvapich2_conf_vcluster = "small";
                $done = 1;
            }

            elsif ($ans eq "2") {
                $mvapich2_conf_vcluster = "medium";
                $done = 1;
            }

            elsif ($ans eq "3") {
                $mvapich2_conf_vcluster = "large";
                $done = 1;
            }
        }

        print "\nI/O Bus:\n\n1) PCI-Express\n2) PCI-X\n";
        $done = 0;

        while (not $done) {
            print "I/O Bus [1]: ";
            $ans = getch();

            if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                $mvapich2_conf_io_bus = "PCI_EX";
                $done = 1;
            }

            elsif ($ans eq "2") {
                $mvapich2_conf_io_bus = "PCI_X";
                $done = 1;
            }
        }

        if ($mvapich2_conf_io_bus eq "PCI_EX") {
            print "\nLink Speed:\n\n1) SDR\n2) DDR\n";
            $done = 0;

            while (not $done) {
                print "Link Speed [1]: ";
                $ans = getch();

                if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                    $mvapich2_conf_link_speed = "SDR";
                    $done = 1;
                }

                elsif ($ans eq "2") {
                    $mvapich2_conf_link_speed = "DDR";
                    $done = 1;
                }
            }
        }

        else {
            $mvapich2_conf_link_speed = "SDR";
        }

        print "\nDefault DAPL provider []: ";
        $ans = <STDIN>;
        chomp $ans;

        if ($ans) {
            $mvapich2_conf_dapl_provider = $ans;
        }
    }

    $mvapich2_conf_done = 1;

    open(CONFIG, ">>$config") || die "Can't open $config: $!";;
    flock CONFIG, $LOCK_EXCLUSIVE;

    print CONFIG "mvapich2_conf_impl=$mvapich2_conf_impl\n";
    print CONFIG "mvapich2_conf_romio=$mvapich2_conf_romio\n";
    print CONFIG "mvapich2_conf_shared_libs=$mvapich2_conf_shared_libs\n";
    print CONFIG "mvapich2_conf_ckpt=$mvapich2_conf_ckpt\n";
    print CONFIG "mvapich2_conf_blcr_home=$mvapich2_conf_blcr_home\n" if ($mvapich2_conf_blcr_home);
    print CONFIG "mvapich2_conf_vcluster=$mvapich2_conf_vcluster\n";
    print CONFIG "mvapich2_conf_io_bus=$mvapich2_conf_io_bus\n" if ($mvapich2_conf_io_bus);
    print CONFIG "mvapich2_conf_link_speed=$mvapich2_conf_link_speed\n" if ($mvapich2_conf_link_speed);
    print CONFIG "mvapich2_conf_dapl_provider=$mvapich2_conf_dapl_provider\n" if ($mvapich2_conf_dapl_provider);

    flock CONFIG, $UNLOCK;
    close(CONFIG);
}

sub show_menu
{
    my $menu = shift @_;
    my $max_inp;

    print $clear_string;
    if ($menu eq "main") {
        print "$PACKAGE Distribution Software Installation Menu\n\n";
        print "   1) View $PACKAGE Installation Guide\n";
        print "   2) Install $PACKAGE Software\n";
        print "   3) Show Installed Software\n";
        print "   4) Configure IPoIB\n";
        print "   5) Uninstall $PACKAGE Software\n";
#        print "   6) Generate Supporting Information for Problem Report\n";
        print "\n   Q) Exit\n";
        $max_inp=5;
        print "\nSelect Option [1-$max_inp]:"
    }
    elsif ($menu eq "select") {
        print "$PACKAGE Distribution Software Installation Menu\n\n";
        print "   1) Basic ($PACKAGE modules and basic user level libraries)\n";
        print "   2) HPC ($PACKAGE modules and libraries, MPI and diagnostic tools)\n";
        print "   3) All packages (all of Basic, HPC)\n";
        print "   4) Customize\n";
        print "\n   Q) Exit\n";
        $max_inp=4;
        print "\nSelect Option [1-$max_inp]:"
    }

    return $max_inp;
}

# Select package for installation
sub select_packages
{
    my $cnt = 0;
    if ($interactive) {
        open(CONFIG, ">$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        my $ok = 0;
        my $inp;
        my $max_inp;
        while (! $ok) {
            $max_inp = show_menu("select");
            $inp = getch();
            if ($inp =~ m/[qQ]/ || $inp =~ m/[Xx]/ ) {
                die "Exiting\n";
            }
            if (ord($inp) == $KEY_ENTER) {
                next;
            }
            if ($inp =~ m/[0123456789abcdefABCDEF]/)
            {
                $inp = hex($inp);
            }
            if ($inp < 1 || $inp > $max_inp)
            {
                print "Invalid choice...Try again\n";
                next;
            }
            $ok = 1;
        }
        if ($inp == $BASIC) {
            for my $package (@basic_user_packages, @basic_kernel_packages) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @basic_kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $HPC) {
            for my $package ( @hpc_user_packages, @hpc_kernel_packages ) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @hpc_kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $ALL) {
            for my $package ( @all_packages, @hidden_packages ) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $CUSTOM) {
            my $ans;
            for my $package ( @all_packages ) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                print "Install $package? [y/N]:";
                $ans = getch();
                if ( $ans eq 'Y' or $ans eq 'y' ) {
                    print CONFIG "$package=y\n";
                    push (@selected_by_user, $package);
                    $cnt ++;

                    if ($package eq "compat-rdma") {
                        # Select kernel modules to be installed
                        for my $module ( @kernel_modules, @tech_preview ) {
                            next if (not $kernel_modules_info{$module}{'available'});
                            print "Install $module module? [y/N]:";
                            $ans = getch();
                            if ( $ans eq 'Y' or $ans eq 'y' ) {
                                push (@selected_modules_by_user, $module);
                                print CONFIG "$module=y\n";
                            }
                        }
                    }
                }
                else {
                    print CONFIG "$package=n\n";
                }
            }
            if ($arch eq "x86_64" or $arch eq "ppc64") {
                if (supported32bit()) {
                    print "Install 32-bit packages? [y/N]:";
                    $ans = getch();
                    if ( $ans eq 'Y' or $ans eq 'y' ) {
                        $build32 = 1;
                        print CONFIG "build32=1\n";
                    }
                    else {
                        $build32 = 0;
                        print CONFIG "build32=0\n";
                    }
                }
                else {
                    $build32 = 0;
                    print CONFIG "build32=0\n";
                }
            }
            print "Please enter the $PACKAGE installation directory: [$prefix]:";
            $ans = <STDIN>;
            chomp $ans;
            if ($ans) {
                $prefix = $ans;
                $prefix =~ s/\/$//;
            }
            print CONFIG "prefix=$prefix\n";
        }
        flock CONFIG, $UNLOCK;
    }
    else {
        if ($config_given) {
            open(CONFIG, "$config") || die "Can't open $config: $!";;
            while(<CONFIG>) {
                next if (m@^\s+$|^#.*@);
                my ($package,$selected) = (split '=', $_);
                chomp $package;
                chomp $selected;

                print "$package=$selected\n" if ($verbose3);

                if ($package eq "build32") {
                    if (supported32bit()) {
                        $build32 = 1 if ($selected);
                    }
                    next;
                }

                if ($package eq "prefix") {
                    $prefix = $selected;
                    $prefix =~ s/\/$//;
                    next;
                }

                if ($package eq "bonding_force_all_os") {
                    if ($selected =~ m/[Yy]|[Yy][Ee][Ss]/) {
                        $bonding_force_all_os = 1;
                    }
                    next;
                }

		if (substr($package,0,length("vendor_config")) eq "vendor_config") {
		       next;
		}

                if ($package eq "vendor_pre_install") {
		    if ( -f $selected ) {
			$vendor_pre_install = dirname($selected) . '/' . basename($selected);
		    }
		    else {
			print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
			exit 1
		    }
                    next;
                }

                if ($package eq "vendor_post_install") {
		    if ( -f $selected ) {
			$vendor_post_install = dirname($selected) . '/' . basename($selected);
		    }
		    else {
			print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
			exit 1
		    }
                    next;
                }

                if ($package eq "vendor_pre_uninstall") {
		    if ( -f $selected ) {
			$vendor_pre_uninstall = dirname($selected) . '/' . basename($selected);
		    }
		    else {
			print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
			exit 1
		    }
                    next;
                }

                if ($package eq "vendor_post_uninstall") {
		    if ( -f $selected ) {
			$vendor_post_uninstall = dirname($selected) . '/' . basename($selected);
		    }
		    else {
			print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
			exit 1
		    }
                    next;
                }

                if ($package eq "kernel_configure_options" or $package eq "OFA_KERNEL_PARAMS") {
                    $kernel_configure_options = $selected;
                    next;
                }

                if ($package eq "user_configure_options") {
                    $user_configure_options = $selected;
                    next;
                }

                if ($package =~ m/configure_options/) {
                    my $pack_name = (split '_', $_)[0];
                    $packages_info{$pack_name}{'configure_options'} = $selected;
                    next;
                }

                # mvapich2 configuration environment
                if ($package eq "mvapich2_conf_impl") {
                    $mvapich2_conf_impl = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_romio") {
                    $mvapich2_conf_romio = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_shared_libs") {
                    $mvapich2_conf_shared_libs = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_ckpt") {
                    $mvapich2_conf_ckpt = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_blcr_home") {
                    $mvapich2_conf_blcr_home = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_vcluster") {
                    $mvapich2_conf_vcluster = $selected;
                    next;
                }
		
                elsif ($package eq "mvapich2_conf_io_bus") {
                    $mvapich2_conf_io_bus = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_link_speed") {
                    $mvapich2_conf_link_speed = $selected;
                    next;
                }

                elsif ($package eq "mvapich2_conf_dapl_provider") {
                    $mvapich2_conf_dapl_provider = $selected;
                    next;
                }

                if (not $packages_info{$package}{'parent'}) {
                    my $modules = "@kernel_modules @tech_preview";
                    chomp $modules;
                    $modules =~ s/ /|/g;
                    if ($package =~ m/$modules/) {
                        if ( $selected eq 'y' ) {
                            if (not $kernel_modules_info{$package}{'available'}) {
                                print "$package is not available on this platform\n" if (not $quiet);
                            }
                            else {
                                push (@selected_modules_by_user, $package);
                            }
                            next;
                        }
                    }
                    else {
                       print "Unsupported package: $package\n" if (not $quiet);
                       next;
                    }
                }

                if (not $packages_info{$package}{'available'} and $selected eq 'y') {
                    print "$package is not available on this platform\n" if (not $quiet);
                    next;
                }

                if ( $selected eq 'y' ) {
                    my $parent = $packages_info{$package}{'parent'};
                    if (not $main_packages{$parent}{'srpmpath'}) {
                        print "Unsupported package: $package\n" if (not $quiet);
                        next;
                    }
                    push (@selected_by_user, $package);
                    print "select_package: selected $package\n" if ($verbose2);
                    $cnt ++;
                }
            }
        }
        else {
            open(CONFIG, ">$config") || die "Can't open $config: $!";
            flock CONFIG, $LOCK_EXCLUSIVE;
            if ($install_option eq 'all') {
                for my $package ( @all_packages ) {
                    next if (not $packages_info{$package}{'available'});
                    my $parent = $packages_info{$package}{'parent'};
                    next if (not $main_packages{$parent}{'srpmpath'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            elsif ($install_option eq 'hpc') {
                for my $package ( @hpc_user_packages, @hpc_kernel_packages ) {
                    next if (not $packages_info{$package}{'available'});
                    my $parent = $packages_info{$package}{'parent'};
                    next if (not $main_packages{$parent}{'srpmpath'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @hpc_kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            elsif ($install_option eq 'basic') {
                for my $package (@basic_user_packages, @basic_kernel_packages) {
                    next if (not $packages_info{$package}{'available'});
                    my $parent = $packages_info{$package}{'parent'};
                    next if (not $main_packages{$parent}{'srpmpath'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @basic_kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            else {
                print RED "\nUnsupported installation option: $install_option", RESET "\n" if (not $quiet);
                exit 1;
            }
        }

        flock CONFIG, $UNLOCK;
    }
    close(CONFIG);

    
    return $cnt;
}

sub module_in_rpm
{
    my $module = shift @_;
    my $ret = 1;

    my $name = 'compat-rdma';
    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print "is_module_in_rpm: $package not found\n";
        return 1;
    }

    if ($module eq "nfsrdma") {
        $module = "xprtrdma";
    }

    open(LIST, "rpm -qlp $package |") or die "Can't run 'rpm -qlp $package': $!\n";
    while (<LIST>) {
        if (/$module[a-z_]*.ko/) {
            print "is_module_in_rpm: $module $_\n" if ($verbose3);
            $ret = 0;
            last;
        }
    }
    close LIST;

    if ($ret) {
        print "$module not in $package\n" if ($verbose2);
    }

    return $ret;
}

sub mark_for_uninstall
{
    my $package = shift @_;
    if (not $selected_for_uninstall{$package}) {
        push (@dependant_packages_to_uninstall, "$package");
        $selected_for_uninstall{$package} = 1;
    }
}

sub get_requires
{
    my $package = shift @_;
    my @what_requires = `/bin/rpm -q --whatrequires $package 2>&1 | grep -v "no package requires" 2> /dev/null`;

    for my $pack_req (@what_requires) {
        chomp $pack_req;
        print "get_requires: $package is required by $pack_req\n" if ($verbose2);
        next if ("$pack_req" =~ /no package requires/);
        get_requires($pack_req);
        mark_for_uninstall($pack_req);
    }
}

sub select_dependent
{
    my $package = shift @_;

    if ( (not $packages_info{$package}{'rpm_exist'}) or
         ($build32 and not $packages_info{$package}{'rpm_exist32'}) ) {
        for my $req ( @{ $packages_info{$package}{'ofa_req_build'} } ) {
            next if not $req;
            print "resolve_dependencies: $package requires $req for rpmbuild\n" if ($verbose2);
            if (not $packages_info{$req}{'selected'}) {
                select_dependent($req);
            }
        }
    }

    for my $req ( @{ $packages_info{$package}{'ofa_req_inst'} } ) {
        next if not $req;
        print "resolve_dependencies: $package requires $req for rpm install\n" if ($verbose2);
        if (not $packages_info{$req}{'selected'}) {
            select_dependent($req);
        }
    }

    if (not $packages_info{$package}{'selected'}) {
        $packages_info{$package}{'selected'} = 1;
        push (@selected_packages, $package);
        print "select_dependent: Selected package $package\n" if ($verbose2);
    }

}

sub select_dependent_module
{
    my $module = shift @_;

    for my $req ( @{ $kernel_modules_info{$module}{'requires'} } ) {
        print "select_dependent_module: $module requires $req for rpmbuild\n" if ($verbose2);
        if (not $kernel_modules_info{$req}{'selected'}) {
            select_dependent_module($req);
        }
    }
    if (not $kernel_modules_info{$module}{'selected'}) {
        $kernel_modules_info{$module}{'selected'} = 1;
        push (@selected_kernel_modules, $module);
        print "select_dependent_module: Selected module $module\n" if ($verbose2);
    }
}

sub resolve_dependencies
{
    for my $package ( @selected_by_user ) {
            # Get the list of dependencies
            select_dependent($package);

            if ($package =~ /mvapich2_*/) {
                    mvapich2_config();
            }
        }

    for my $module ( @selected_modules_by_user ) {
        # if ($module eq "ehca" and $kernel =~ m/2.6.9-55/ and not -d "$kernel_sources/include/asm-ppc") {
        #     print RED "\nTo install ib_ehca module please ensure that $kernel_sources/include/ contains directory asm-ppc.", RESET;
        #     print RED "\nPlease install the kernel.src.rpm from redhat and copy the directory and the files into $kernel_sources/include/", RESET;
        #     print "\nThen rerun this Script\n";
        #     exit 1;
        # }
        select_dependent_module($module);
    }

    if ($packages_info{'compat-rdma'}{'rpm_exist'}) {
        for my $module (@selected_kernel_modules) {
            if (module_in_rpm($module)) {
                $packages_info{'compat-rdma'}{'rpm_exist'} = 0;
                last;
            }
        }
    }
}

sub check_linux_dependencies
{
    my $err = 0;
    my $p1 = 0;
    my $gcc_32bit_printed = 0;
    if (! $check_linux_deps) {
        return 0;
    }
    my $dist_req_build = ($DISTRO =~ m/UBUNTU/)?'ubuntu_dist_req_build':'dist_req_build';
    for my $package ( @selected_packages ) {
        # Check rpmbuild requirements
        if ($package =~ /compat-rdma|ib-bonding/) {
            if (not $packages_info{$package}{'rpm_exist'}) {
                # Check that required kernel is supported
                if ($kernel !~ /2.6.16.60-[A-Za-z0-9.]*-[A-Za-z0-9.]*|2.6.1[8-9]|2.6.2[0-9]|2.6.3[0-9]|2.6.40|3.[0-5]/) {
                    print RED "Kernel $kernel is not supported.", RESET "\n";
                    print BLUE "For the list of Supported Platforms and Operating Systems see", RESET "\n";
                    print BLUE "$CWD/docs/OFED_release_notes.txt", RESET "\n";
                    exit 1;
                }
                # kernel sources required
                if ( not -d "$kernel_sources/scripts" ) {
                    print RED "$kernel_sources/scripts is required to build $package RPM.", RESET "\n";
                    print RED "Please install the corresponding kernel-source or kernel-devel RPM.", RESET "\n";
                    $err++;
                }
            }
        }
		
        if($DISTRO =~/UBUNTU/){
            if(not is_installed_deb("rpm")){
                print RED "rpm is required to build OFED", RESET "\n";
            }
        }

        if ($DISTRO =~ m/RHEL|FC/) {
            if (not is_installed("rpm-build")) {
                print RED "rpm-build is required to build OFED", RESET "\n";
                $err++;
            }
        }

        if ($package =~ /debuginfo/ and ($DISTRO =~ m/RHEL|FC/)) {
            if (not $packages_info{$package}{'rpm_exist'}) {
                if (not is_installed("redhat-rpm-config")) {
                    print RED "redhat-rpm-config rpm is required to build $package", RESET "\n";
                    $err++;
                }
            }
        }

        if (not $packages_info{$package}{'rpm_exist'}) {
            for my $req ( @{ $packages_info{$package}{$dist_req_build} } ) {
                my ($req_name, $req_version) = (split ('_',$req));
                next if not $req_name;
                print BLUE "check_linux_dependencies: $req_name  is required to build $package", RESET "\n" if ($verbose3);
                my $is_installed_flag = ($DISTRO =~ m/UBUNTU/)?(is_installed_deb($req_name)):(is_installed($req_name));
                if (not $is_installed_flag) {
                    print RED "$req_name rpm is required to build $package", RESET "\n";
                    $err++;
                }
                if ($req_version) {
                    my $inst_version = get_rpm_ver_inst($req_name);
                    print "check_linux_dependencies: $req_name installed version $inst_version, required at least $req_version\n" if ($verbose3);
                    if ($inst_version lt $req_version) {
                        print RED "$req_name-$req_version rpm is required to build $package", RESET "\n";
                        $err++;
                    }
                }
            }
            if ($build32) {
                if (not -f "/usr/lib/crt1.o") {
                    if (! $p1) {
                        print RED "glibc-devel 32bit is required to build 32-bit libraries.", RESET "\n";
                        $p1 = 1;
                        $err++;
                    }
                }
		if ($DISTRO =~ m/SLES11/) {
                    if (not is_installed("gcc-32bit")) {
                        if (not $gcc_32bit_printed) {
                            print RED "gcc-32bit is required to build 32-bit libraries.", RESET "\n";
                            $gcc_32bit_printed++;
                            $err++;
                        }
                    }
                }
                if ($arch eq "ppc64") {
                    my @libstdc32 = </usr/lib/libstdc++.so.*>;
                    if ($package eq "mstflint") {
                        if (not $#libstdc32) {
                            print RED "$libstdc 32bit is required to build mstflint.", RESET "\n";
                            $err++;
                        }
                    }
                    elsif ($package eq "openmpi") {
                        my @libsysfs = </usr/lib/libsysfs.so>;
                        if (not $#libstdc32) {
                            print RED "$libstdc_devel 32bit is required to build openmpi.", RESET "\n";
                            $err++;
                        }
                        if (not $#libsysfs) {
                            print RED "$sysfsutils_devel 32bit is required to build openmpi.", RESET "\n";
                            $err++;
                        }
                    }
                }
            }
            if ($package eq "rnfs-utils") {
                if (not is_installed("krb5-devel")) {
                    print RED "krb5-devel is required to build rnfs-utils.", RESET "\n";
                    $err++;
                }
                if ($DISTRO =~ m/RHEL|FC/) {
                    if (not is_installed("krb5-libs")) {
                        print RED "krb5-libs is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("libevent-devel")) {
                        print RED "libevent-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("nfs-utils-lib-devel")) {
                        print RED "nfs-utils-lib-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("openldap-devel")) {
                        print RED "openldap-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                } else {
                    if ($DISTRO =~ m/SLES11/) {
                        if (not is_installed("libevent-devel")) {
                            print RED "libevent-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("nfsidmap-devel")) {
                            print RED "nfsidmap-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("libopenssl-devel")) {
                            print RED "libopenssl-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                    } elsif ($DISTRO eq "SLES10") {
                        if (not is_installed("libevent")) {
                            print RED "libevent is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("nfsidmap")) {
                            print RED "nfsidmap is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                    }
                    if (not is_installed("krb5")) {
                        print RED "krb5 is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("openldap2-devel")) {
                        print RED "openldap2-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("cyrus-sasl-devel")) {
                        print RED "cyrus-sasl-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                }

                my $blkid_so = ($arch =~ m/x86_64/) ? "/usr/lib64/libblkid.so" : "/usr/lib/libblkid.so";
                my $blkid_pkg = ($DISTRO =~ m/SLES10|RHEL5/) ? "e2fsprogs-devel" : "libblkid-devel";
                $blkid_pkg .= ($arch =~ m/powerpc|ppc64/) ? "-32bit" : "";

                if (not -e $blkid_so) {
                    print RED "$blkid_pkg is required to build rnfs-utils.", RESET "\n";
                    $err++;
                }
            }
        }
        my $dist_req_inst = ($DISTRO =~ m/UBUNTU/)?'ubuntu_dist_req_inst':'dist_req_inst';
        # Check installation requirements
        for my $req ( @{ $packages_info{$package}{$dist_req_inst} } ) {
            my ($req_name, $req_version) = (split ('_',$req));
            next if not $req_name;
            my $is_installed_flag = ($DISTRO =~ m/UBUNTU/)?(is_installed_deb($req_name)):(is_installed($req_name));
            if (not $is_installed_flag) {
                print RED "$req_name rpm is required to install $package", RESET "\n";
                $err++;
            }
            if ($req_version) {
                my $inst_version = get_rpm_ver_inst($req_name);
                print "check_linux_dependencies: $req_name installed version $inst_version, required $req_version\n" if ($verbose3);
                if ($inst_version lt $req_version) {
                    print RED "$req_name-$req_version rpm is required to install $package", RESET "\n";
                    $err++;
                }
            }
        }
        if ($build32) {
            if (not -f "/usr/lib/crt1.o") {
                if (! $p1) {
                    print RED "glibc-devel 32bit is required to install 32-bit libraries.", RESET "\n";
                    $p1 = 1;
                    $err++;
                }
            }
            if ($arch eq "ppc64") {
                my @libstdc32 = </usr/lib/libstdc++.so.*>;
                if ($package eq "mstflint") {
                    if (not $#libstdc32) {
                        print RED "$libstdc 32bit is required to install mstflint.", RESET "\n";
                        $err++;
                    }
                }
                elsif ($package eq "openmpi") {
                    my @libsysfs = </usr/lib/libsysfs.so.*>;
                    if (not $#libstdc32) {
                        print RED "$libstdc 32bit is required to install openmpi.", RESET "\n";
                        $err++;
                    }
                    if (not $#libsysfs) {
                        print RED "$sysfsutils 32bit is required to install openmpi.", RESET "\n";
                        $err++;
                    }
                }
            }
        }
    }
    if ($err) {
        exit 1;
    }
}

# Print the list of selected packages
sub print_selected
{
    print GREEN "\nBelow is the list of ${PACKAGE} packages that you have chosen
    \r(some may have been added by the installer due to package dependencies):\n", RESET "\n";
    for my $package ( @selected_packages ) {
        print "$package\n";
    }
    if ($build32) {
        print "32-bit binaries/libraries will be created\n";
    }
    print "\n";
}

sub build_kernel_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    $cmd = "rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";

    if ($name eq 'compat-rdma') {
        $kernel_configure_options .= " $packages_info{'compat-rdma'}{'configure_options'}";

        for my $module ( @selected_kernel_modules ) {
            if ($module eq "core") {
                $kernel_configure_options .= " --with-core-mod --with-user_mad-mod --with-user_access-mod --with-addr_trans-mod";
            }
            elsif ($module eq "ipath") {
                $kernel_configure_options .= " --with-ipath_inf-mod";
            }
            elsif ($module eq "qib") {
                $kernel_configure_options .= " --with-qib-mod";
            }
            elsif ($module eq "srpt") {
                $kernel_configure_options .= " --with-srp-target-mod";
            }
            else {
                $kernel_configure_options .= " --with-$module-mod";
            }
        }

        if ($DISTRO eq "DEBIAN") {
                $kernel_configure_options .= " --without-modprobe";
        }

        # WA for Fedora C12
        if ($DISTRO =~ /FC12/) {
            $cmd .= " --define '__spec_install_pre %{___build_pre}'";
        }

        if ($DISTRO =~ /SLES11/) {
            $cmd .= " --define '_suse_os_install_post %{nil}'";
        }

        if ($DISTRO =~ /RHEL5/ and $target_cpu eq "i386") {
            $cmd .= " --define '_target_cpu i686'";
        }

        if ($DISTRO eq "RHEL6.3") {
            $cmd .= " --define '__find_provides %{nil}'";
        }
        $cmd .= " --nodeps";
        $cmd .= " --define '_dist .$rpm_distro'";
        $cmd .= " --define 'configure_options $kernel_configure_options'";
        $cmd .= " --define 'build_kernel_ib 1'";
        $cmd .= " --define 'build_kernel_ib_devel 1'";
        $cmd .= " --define 'KVERSION $kernel'";
        $cmd .= " --define 'K_SRC $kernel_sources'";
        $cmd .= " --define '_release $kernel_rel'";
        $cmd .= " --define 'network_dir $network_dir'";
    }
    elsif ($name eq 'ib-bonding') {
        $cmd .= " --define 'KVERSION $kernel'";
        $cmd .= " --define '_release $kernel_rel'";
        $cmd .= " --define 'force_all_os $bonding_force_all_os'";
    }

    $cmd .= " --define '_prefix $prefix'";
    $cmd .= " --define '__arch_install_post %{nil}'";
    $cmd .= " $main_packages{$name}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    system("echo $cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
    system("$cmd >> $ofedlogs/$name.rpmbuild.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to build $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpmbuild.log", RESET "\n";
        exit 1;
    }

    $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
    chomp $TMPRPMS;

    print "TMPRPMS $TMPRPMS\n" if ($verbose2);

    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        system("/bin/rpm -qlp $myrpm | grep lib.modules | awk -F '/' '{print\$4}' | sort -u >> $RPMS/.supported_kernels");
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        $packages_info{$myrpm_name}{'rpm_exist'} = 1;
    }
}

sub build_rpm_32
{
    my $name = shift @_;
    my $parent = $packages_info{$name}{'parent'};
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    my $pref_env32;
    my $ldflags32;
    my $cflags32;
    my $cppflags32;
    my $cxxflags32;
    my $fflags32;
    my $ldlibs32;

    $ldflags32    .= " -m32 -g -O2 -L/usr/lib";
    $cflags32     .= " -m32 -g -O2";
    $cppflags32   .= " -m32 -g -O2";
    $cxxflags32   .= " -m32 -g -O2";
    $fflags32     .= " -m32 -g -O2";
    $ldlibs32     .= " -m32 -g -O2 -L/usr/lib";

    if ($prefix ne $default_prefix) {
        $ldflags32 .= " -L$prefix/lib";
        $cflags32 .= " -I$prefix/include";
        $cppflags32 .= " -I$prefix/include";
    }

    $pref_env32 .= " LDFLAGS='$ldflags32'";
    $pref_env32 .= " CFLAGS='$cflags32'";
    $pref_env32 .= " CPPFLAGS='$cppflags32'";
    $pref_env32 .= " CXXFLAGS='$cxxflags32'";
    $pref_env32 .= " FFLAGS='$fflags32'";
    $pref_env32 .= " LDLIBS='$ldlibs32'";

    $cmd = "$pref_env32 rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";
    $cmd .= " --target $target_cpu32";
    $cmd .= " --define '_prefix $prefix'";
    $cmd .= " --define 'dist %{nil}'";
    $cmd .= " --define '_exec_prefix $prefix'";
    $cmd .= " --define '_sysconfdir $sysconfdir'";
    $cmd .= " --define '_usr $prefix'";
    $cmd .= " --define '_lib lib'";
    $cmd .= " --define '__arch_install_post %{nil}'";

    if ($parent =~ m/dapl/) {
        my $def_doc_dir = `rpm --eval '%{_defaultdocdir}'`;
        chomp $def_doc_dir;
        $cmd .= " --define '_prefix $prefix'";
        $cmd .= " --define '_exec_prefix $prefix'";
        $cmd .= " --define '_sysconfdir $sysconfdir'";
        $cmd .= " --define '_defaultdocdir $def_doc_dir/$main_packages{$parent}{'name'}-$main_packages{$parent}{'version'}'";
        $cmd .= " --define '_usr $prefix'";
    }

    if ($DISTRO =~ m/SLES/) {
        $cmd .= " --define '_suse_os_install_post %{nil}'";
    }

    $cmd .= " $main_packages{$parent}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    open(LOG, "+>$ofedlogs/$parent.rpmbuild32bit.log");
    print LOG "Running $cmd\n";
    close LOG;
    system("$cmd >> $ofedlogs/$parent.rpmbuild32bit.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to build $parent RPM", RESET "\n";
        print RED "See $ofedlogs/$parent.rpmbuild32bit.log", RESET "\n";
        exit 1;
    }

    $TMPRPMS = "$TOPDIR/RPMS/$target_cpu32";
    chomp $TMPRPMS;
    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        $packages_info{$myrpm_name}{'rpm_exist32'} = 1;
    }
}

# Build RPM from source RPM
sub build_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    my $ldflags;
    my $cflags;
    my $cppflags;
    my $cxxflags;
    my $fflags;
    my $ldlibs;
    my $openmpi_comp_env;
    my $parent = $packages_info{$name}{'parent'};
    my $srpmdir;
    my $srpmpath_for_distro;

    print "Build $name RPM\n" if ($verbose);

    my $pref_env = '';
    if ($prefix ne $default_prefix) {
        if ($parent ne "mvapich" and $parent ne "mvapich2" and $parent ne "openmpi") {
            $ldflags .= "$optflags -L$prefix/lib64 -L$prefix/lib";
            $cflags .= "$optflags -I$prefix/include";
            $cppflags .= "$optflags -I$prefix/include";
        }
    }

    if (not $packages_info{$name}{'rpm_exist'}) {

        if ($parent eq "ibacm" and $DISTRO eq "FC14") {
            $ldflags    = " -g -O2 -lpthread";
        }

        if ($arch eq "ppc64") {
            if ($DISTRO =~ m/SLES/ and $dist_rpm_rel gt 15.2) {
                # SLES 10 SP1
                if ($parent eq "ibutils") {
                    $packages_info{'ibutils'}{'configure_options'} .= " LDFLAGS=-L/usr/lib/gcc/powerpc64-suse-linux/4.1.2/64";
                }
                if ($parent eq "openmpi") {
                    $openmpi_comp_env .= ' LDFLAGS="-m64 -O2 -L/usr/lib/gcc/powerpc64-suse-linux/4.1.2/64"';
                }
                if ($parent eq "sdpnetstat" or $parent eq "rds-tools" or $parent eq "rnfs-utils") {
                    $ldflags    = " -g -O2";
                    $cflags     = " -g -O2";
                    $cppflags   = " -g -O2";
                    $cxxflags   = " -g -O2";
                    $fflags     = " -g -O2";
                    $ldlibs     = " -g -O2";
                }
            }
            else {
                if ($parent =~ /sdpnetstat|rds-tools|rnfs-utils/) {
                    # Override compilation flags on RHEL 4.0 and 5.0 PPC64
                    $ldflags    = " -g -O2";
                    $cflags     = " -g -O2";
                    $cppflags   = " -g -O2";
                    $cxxflags   = " -g -O2";
                    $fflags     = " -g -O2";
                    $ldlibs     = " -g -O2";
                }
                elsif ($parent !~ /ibutils/) {
                    $ldflags    .= " $optflags -m64 -g -O2 -L/usr/lib64";
                    $cflags     .= " $optflags -m64 -g -O2";
                    $cppflags   .= " $optflags -m64 -g -O2";
                    $cxxflags   .= " $optflags -m64 -g -O2";
                    $fflags     .= " $optflags -m64 -g -O2";
                    $ldlibs     .= " $optflags -m64 -g -O2 -L/usr/lib64";
                }
            }
        }

        if ($ldflags) {
            $pref_env   .= " LDFLAGS='$ldflags'";
        }
        if ($cflags) {
            $pref_env   .= " CFLAGS='$cflags'";
        }
        if ($cppflags) {
            $pref_env   .= " CPPFLAGS='$cppflags'";
        }
        if ($cxxflags) {
            $pref_env   .= " CXXFLAGS='$cxxflags'";
        }
        if ($fflags) {
            $pref_env   .= " FFLAGS='$fflags'";
        }
        if ($ldlibs) {
            $pref_env   .= " LDLIBS='$ldlibs'";
        }

        $cmd = "$pref_env rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";
        $cmd .= " --define 'dist %{nil}'";
        $cmd .= " --target $target_cpu";

        # Prefix should be defined per package
        if ($parent eq "ibutils") {
            $packages_info{'ibutils'}{'configure_options'} .= " --with-osm=$prefix";
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'build_ibmgtsim 1'";
            $cmd .= " --define '__arch_install_post %{nil}'";
        }
        elsif ( $parent eq "mvapich") {
            my $compiler = (split('_', $name))[1];
            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'compiler $compiler'";
            $cmd .= " --define 'openib_prefix $prefix'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'use_mpi_selector 1'";
            $cmd .= " --define '__arch_install_post %{nil}'";
            if ($packages_info{'mvapich'}{'configure_options'}) {
                $cmd .= " --define 'configure_options $packages_info{'mvapich'}{'configure_options'}'";
            }
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
        }
        elsif ($parent eq "mvapich2") {
            my $compiler = (split('_', $name))[1];
            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'impl $mvapich2_conf_impl'";

            if ($compiler eq "gcc") {
                if ($gcc{'gfortran'}) {
                    if ($arch eq "ppc64") {
                        $mvapich2_comp_env = 'CC="gcc -m64" CXX="g++ -m64" F77="gfortran -m64" FC="gfortran -m64"';
                    }

                    else {
                        $mvapich2_comp_env = "CC=gcc CXX=g++ F77=gfortran FC=gfortran";
                    }
                }

                elsif ($gcc{'g77'}) {
                    if ($arch eq "ppc64") {
                        $mvapich2_comp_env = 'CC="gcc -m64" CXX="g++ -m64" F77="g77 -m64" FC=/bin/false';
                    }

                    else {
                        $mvapich2_comp_env = "CC=gcc CXX=g++ F77=g77 FC=/bin/false";
                    }
                }

                else {
                    $mvapich2_comp_env .= " --disable-f77 --disable-fc";
                }
            }

            elsif ($compiler eq "pathscale") {
                $mvapich2_comp_env = "CC=pathcc CXX=pathCC F77=pathf90 FC=pathf90";
                # On i686 the PathScale compiler requires -g optimization
                # for MVAPICH2 in the shared library configuration.
                if ($arch eq "i686" and $mvapich2_conf_shared_libs) {
                    $mvapich2_comp_env .= " OPT_FLAG=-g";
                }
            }

            elsif ($compiler eq "pgi") {
                $mvapich2_comp_env = "CC=pgcc CXX=pgCC F77=pgf77 FC=pgf90";
            }

            elsif ($compiler eq "intel") {
                if ($mvapich2_conf_shared_libs) {
                    # The -i-dynamic flag is required for MVAPICH2 in the shared
                    # library configuration.
                    $mvapich2_comp_env = 'CC="icc -i-dynamic" CXX="icpc -i-dynamic" F77="ifort -i-dynamic" FC="ifort -i-dynamic"';
                }

                else {
                    $mvapich2_comp_env = "CC=icc CXX=icpc F77=ifort FC=ifort";
                }
            }

            if ($mvapich2_conf_impl eq "ofa") {
                if ($verbose) {
                    print BLUE;
                    print "Building the MVAPICH2 RPM [OFA]...\n";
                    print RESET;
                }

                $cmd .= " --define 'rdma --with-rdma=gen2'";
                $cmd .= " --define 'ib_include --with-ib-include=$prefix/include'";
                $cmd .= " --define 'ib_libpath --with-ib-libpath=$prefix/lib";
                $cmd .= "64" if $arch =~ m/x86_64|ppc64/;
                $cmd .= "'";

                if ($mvapich2_conf_ckpt) {
                    $cmd .= " --define 'blcr 1'";
                    $cmd .= " --define 'blcr_include --with-blcr-include=$mvapich2_conf_blcr_home/include'";
                    $cmd .= " --define 'blcr_libpath --with-blcr-libpath=$mvapich2_conf_blcr_home/lib'";
                }
            }

            elsif ($mvapich2_conf_impl eq "udapl") {
                if ($verbose) {
                    print BLUE;
                    print "Building the MVAPICH2 RPM [uDAPL]...\n";
                    print RESET;
                }

                $cmd .= " --define 'rdma --with-rdma=udapl'";
                $cmd .= " --define 'dapl_include --with-dapl-include=$prefix/include'";
                $cmd .= " --define 'dapl_libpath --with-dapl-libpath=$prefix/lib";
                $cmd .= "64" if $arch =~ m/x86_64|ppc64/;
                $cmd .= "'";

                $cmd .= " --define 'cluster_size --with-cluster-size=$mvapich2_conf_vcluster'";
                $cmd .= " --define 'io_bus --with-io-bus=$mvapich2_conf_io_bus'";
                $cmd .= " --define 'link_speed --with-link=$mvapich2_conf_link_speed'";
                $cmd .= " --define 'dapl_provider --with-dapl-provider=$mvapich2_conf_dapl_provider'" if
($mvapich2_conf_dapl_provider);
            }

            if ($packages_info{'mvapich2'}{'configure_options'}) {
                $cmd .= " --define 'configure_options $packages_info{'mvapich2'}{'configure_options'}'";
            }

            $cmd .= " --define 'shared_libs 1'" if $mvapich2_conf_shared_libs;
            $cmd .= " --define 'romio 1'" if $mvapich2_conf_romio;
            $cmd .= " --define 'comp_env $mvapich2_comp_env'";
            $cmd .= " --define 'auto_req 0'";
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
        }
        elsif ($parent eq "openmpi") {
            my $compiler = (split('_', $name))[1];
            my $use_default_rpm_opt_flags = 1;
            my $openmpi_ldflags = '';
            my $openmpi_wrapper_cxx_flags;
            my $openmpi_lib;

            if ($arch =~ m/x86_64|ppc64/) {
                $openmpi_lib = 'lib64';
            }
            else {
                $openmpi_lib = 'lib';
            }
            
            if ($compiler eq "gcc") {
                $openmpi_comp_env .= " CC=gcc";
                if ($gcc{'g++'}) {
                    $openmpi_comp_env .= " CXX=g++";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($gcc{'gfortran'}) {
                    $openmpi_comp_env .= " F77=gfortran FC=gfortran";
                }
                elsif ($gcc{'g77'}) {
                    $openmpi_comp_env .= " F77=g77 --disable-mpi-f90";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
            }
            elsif ($compiler eq "pathscale") {
                $cmd .= " --define 'disable_auto_requires 1'";
                $openmpi_comp_env .= " CC=pathcc";
                if ($pathscale{'pathCC'}) {
                    $openmpi_comp_env .= " CXX=pathCC";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($pathscale{'pathf90'}) {
                    $openmpi_comp_env .= " F77=pathf90 FC=pathf90";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
                # On fedora6 and redhat5 the pathscale compiler fails with default $RPM_OPT_FLAGS
                if ($DISTRO =~ m/RHEL|FC/) {
                    $use_default_rpm_opt_flags = 0;
                }
            }
            elsif ($compiler eq "pgi") {
                $cmd .= " --define 'disable_auto_requires 1'";
                $openmpi_comp_env .= " CC=pgcc";
                $use_default_rpm_opt_flags = 0;
                if ($pgi{'pgCC'}) {
                    $openmpi_comp_env .= " CXX=pgCC";
                    # See http://www.pgroup.com/userforum/viewtopic.php?p=2371
                    $openmpi_wrapper_cxx_flags .= " -fpic";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($pgi{'pgf77'}) {
                    $openmpi_comp_env .= " F77=pgf77";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77";
                }
                if ($pgi{'pgf90'}) {
                    # *Must* put in FCFLAGS=-O2 so that -g doesn't get
                    # snuck in there (pgi 6.2-5 has a problem with
                    # modules and -g).
                    $openmpi_comp_env .= " FC=pgf90 FCFLAGS=-O2";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f90";
                }
            }
            elsif ($compiler eq "intel") {
                $cmd .= " --define 'disable_auto_requires 1'";
                $openmpi_comp_env .= " CC=icc";
                if ($intel{'icpc'}) {
                    $openmpi_comp_env .= " CXX=icpc";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($intel{'ifort'}) {
                    $openmpi_comp_env .= "  F77=ifort FC=ifort";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
            }

            if ($arch eq "ppc64") {
                # In the ppc64 case, add -m64 to all the relevant
                # flags because it's not the default.  Also
                # unconditionally add $OMPI_RPATH because even if
                # it's blank, it's ok because there are other
                # options added into the ldflags so the overall
                # string won't be blank.
                $openmpi_comp_env .= ' CFLAGS="-m64 -O2" CXXFLAGS="-m64 -O2" FCFLAGS="-m64 -O2" FFLAGS="-m64 -O2"';
                $openmpi_comp_env .= ' --with-wrapper-ldflags="-g -O2 -m64 -L/usr/lib64" --with-wrapper-cflags=-m64';
                $openmpi_comp_env .= ' --with-wrapper-cxxflags=-m64 --with-wrapper-fflags=-m64 --with-wrapper-fcflags=-m64';
                $openmpi_wrapper_cxx_flags .= " -m64";
            }

            $openmpi_comp_env .= " --enable-mpirun-prefix-by-default";
            if ($openmpi_wrapper_cxx_flags) {
                $openmpi_comp_env .= " --with-wrapper-cxxflags=\"$openmpi_wrapper_cxx_flags\"";
            }

            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define 'use_mpi_selector 1'";
            $cmd .= " --define 'install_shell_scripts 1'";
            $cmd .= " --define 'shell_scripts_basename mpivars'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'ofed 0'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_defaultdocdir $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_mandir %{_prefix}/share/man'";
            $cmd .= " --define '_datadir %{_prefix}/share'";
            $cmd .= " --define 'mflags -j 4'";
            $cmd .= " --define 'configure_options $packages_info{'openmpi'}{'configure_options'} $openmpi_ldflags --with-openib=$prefix --with-openib-libdir=$prefix/$openmpi_lib $openmpi_comp_env --with-contrib-vt-flags=--disable-iotrace'";
            $cmd .= " --define 'use_default_rpm_opt_flags $use_default_rpm_opt_flags'";
        }
        elsif ($parent eq "mpitests") {
            my $mpi = (split('_', $name))[1];
            my $compiler = (split('_', $name))[2];

            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'root_path /'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'path_to_mpihome $prefix/mpi/$compiler/$mpi-$main_packages{$mpi}{'version'}'";
        }
        elsif ($parent eq "mpi-selector") {
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'shell_startup_dir /etc/profile.d'";
        }
        elsif ($parent =~ m/dapl/) {
            my $def_doc_dir = `rpm --eval '%{_defaultdocdir}'`;
            chomp $def_doc_dir;
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_defaultdocdir $def_doc_dir/$main_packages{$parent}{'name'}-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_usr $prefix'";
        }
        else {
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_usr $prefix'";
        }

        if ($parent eq "librdmacm") {
            if ( $packages_info{'ibacm'}{'selected'}) {
                $packages_info{'librdmacm'}{'configure_options'} .= " --with-ib_acm";
            }
        }

        if ($packages_info{$parent}{'configure_options'} or $user_configure_options) {
            $cmd .= " --define 'configure_options $packages_info{$parent}{'configure_options'} $user_configure_options'";
        }

        $cmd .= " $main_packages{$parent}{'srpmpath'}";

        print "Running $cmd\n" if ($verbose);
        open(LOG, "+>$ofedlogs/$parent.rpmbuild.log");
        print LOG "Running $cmd\n";
        close LOG;
        system("$cmd >> $ofedlogs/$parent.rpmbuild.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to build $parent RPM", RESET "\n";
            print RED "See $ofedlogs/$parent.rpmbuild.log", RESET "\n";
            exit 1;
        }

        $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
        chomp $TMPRPMS;

        print "TMPRPMS $TMPRPMS\n" if ($verbose2);

        for my $myrpm ( <$TMPRPMS/*.rpm> ) {
            print "Created $myrpm\n" if ($verbose2);
            my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
            move($myrpm, $RPMS);
            $packages_info{$myrpm_name}{'rpm_exist'} = 1;
        }
    }

    if ($build32 and $packages_info{$name}{'install32'} and 
        not $packages_info{$name}{'rpm_exist32'}) {
        build_rpm_32($name);
    }
}

sub install_kernel_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    # my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};
    my $release = $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }

    $cmd = "rpm -iv $rpminstall_flags";
    if ($DISTRO =~ m/SLES/) {
        # W/A for ksym dependencies on SuSE
        $cmd .= " --nodeps";
    }
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }
}

sub install_rpm_32
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $package;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};

    $package = "$RPMS/$name-$version-$release.$target_cpu32.rpm";
    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        # exit 1;
    }

    $cmd = "rpm -iv $rpminstall_flags";
    if ($DISTRO =~ m/SLES/) {
        $cmd .= " --force";
    }
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }
}

# Install required RPM
sub install_rpm
{
    my $name = shift @_;
    my $tmp_name;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $package;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};

    $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }

    if ($name eq "mpi-selector") {
        $cmd = "rpm -Uv $rpminstall_flags --force";
    } else {
        if ($name eq "opensm" and $DISTRO eq "DEBIAN") {
            $rpminstall_flags .= " --nopost";
        }
        $cmd = "rpm -iv $rpminstall_flags";
    }

    if ($name =~ /intel|pgi/) {
        $cmd .= " --nodeps";
    }

    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }

    if ($build32 and $packages_info{$name}{'install32'}) {
        install_rpm_32($name);
    }
}

sub print_package_info
{
    print "\n\nDate:" . localtime(time) . "\n";
    for my $key ( keys %main_packages ) {
        print "$key:\n";
        print "======================================\n";
        my %pack = %{$main_packages{$key}};
        for my $subkey ( keys %pack ) {
            print $subkey . ' = ' . $pack{$subkey} . "\n";
        }
        print "\n";
    }
}

sub is_installed_deb
{
    my $res = 0;
    my $name = shift @_;
    my $result = `dpkg-query -W -f='\${version}' $name`;
    if (($result eq "") && ($? == 0) ){
        $res = 1; 
    } 
    return not $res;
}

sub is_installed
{
    my $res = 0;
    my $name = shift @_;
    
    if ($DISTRO eq "DEBIAN") {
        system("dpkg-query -W -f='\${Package} \${Version}\n' $name > /dev/null 2>&1");
    }
    else {
        system("rpm -q $name > /dev/null 2>&1");
    }
    $res = $? >> 8;

    return not $res;
}

sub count_ports
{
    my $cnt = 0;
    open(LSPCI, "/sbin/lspci -n|");

    while (<LSPCI>) {
        if (/15b3:6282/) {
            $cnt += 2;  # InfiniHost III Ex mode
        }
        elsif (/15b3:5e8c|15b3:6274/) {
            $cnt ++;    # InfiniHost III Lx mode
        }
        elsif (/15b3:5a44|15b3:6278/) {
            $cnt += 2;  # InfiniHost mode
        }
        elsif (/15b3:6340|15b3:634a|15b3:6354|15b3:6732|15b3:673c|15b3:6746|15b3:6750/) {
            $cnt += 2;  # ConnectX
        }
    }
    close (LSPCI);

    return $cnt;
}

sub is_valid_ipv4
{
    my $ipaddr = shift @_;

    if( $ipaddr =~ m/^(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)/ ) {
        if($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
            return 0;
        }
    }
    return 1;
}

sub get_net_config
{
    my $interface = shift @_;

    open(IFCONFIG, "/sbin/ifconfig $interface |") or die "Failed to run /sbin/ifconfig $interface: $!";
    while (<IFCONFIG>) {
        next if (not m/inet addr:/);
        my $line = $_;
        chomp $line;
        $ifcfg{$interface}{'IPADDR'} = (split (' ', $line))[1];
        $ifcfg{$interface}{'IPADDR'} =~ s/addr://g;
        $ifcfg{$interface}{'BROADCAST'} = (split (' ', $line))[2];
        $ifcfg{$interface}{'BROADCAST'} =~ s/Bcast://g;
        $ifcfg{$interface}{'NETMASK'} = (split (' ', $line))[3];
        $ifcfg{$interface}{'NETMASK'} =~ s/Mask://g;
        if ($DISTRO eq "RHEL6.3") {
            $ifcfg{$interface}{'NM_CONTROLLED'} = "yes";
            $ifcfg{$interface}{'TYPE'} = "InfiniBand";
        }
    }
    close(IFCONFIG);
}

sub is_carrier
{
    my $ifcheck = shift @_;
    open(IFSTATUS, "ip link show dev $ifcheck |");
    while ( <IFSTATUS> ) {
        next unless m@(\s$ifcheck).*@;
        if( m/NO-CARRIER/ or not m/UP/ ) {
            close(IFSTATUS);
            return 0;
        }
    }
    close(IFSTATUS);
    return 1;
}

sub config_interface
{
    my $interface = shift @_;
    my $ans;
    my $dev = "ib$interface";
    my $target = "$network_dir/ifcfg-$dev";
    my $ret;
    my $ip;
    my $nm;
    my $nw;
    my $bc;
    my $onboot = 1;
    my $found_eth_up = 0;

    if ($interactive) {
        print "\nDo you want to configure $dev? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            return;
        }
        if (-e $target) {
            print BLUE "\nThe current IPoIB configuration for $dev is:\n";
            open(IF,$target);
            while (<IF>) {
                print $_;
            }
            close(IF);
            print "\nDo you want to change this configuration? [y/N]:", RESET;
            $ans = getch();
            if ($ans !~ m/[yY]/) {
                return;
            }
        }
        print "\nEnter an IP Adress: ";
        $ip = <STDIN>;
        chomp $ip;
        $ret = is_valid_ipv4($ip);
        while ($ret) {
            print "\nEnter a valid IPv4 Adress: ";
            $ip = <STDIN>;
            chomp $ip;
            $ret = is_valid_ipv4($ip);
        }
        print "\nEnter the Netmask: ";
        $nm = <STDIN>;
        chomp $nm;
        $ret = is_valid_ipv4($nm);
        while ($ret) {
            print "\nEnter a valid Netmask: ";
            $nm = <STDIN>;
            chomp $nm;
            $ret = is_valid_ipv4($nm);
        }
        print "\nEnter the Network: ";
        $nw = <STDIN>;
        chomp $nw;
        $ret = is_valid_ipv4($nw);
        while ($ret) {
            print "\nEnter a valid Network: ";
            $nw = <STDIN>;
            chomp $nw;
            $ret = is_valid_ipv4($nw);
        }
        print "\nEnter the Broadcast Adress: ";
        $bc = <STDIN>;
        chomp $bc;
        $ret = is_valid_ipv4($bc);
        while ($ret) {
            print "\nEnter a valid Broadcast Adress: ";
            $bc = <STDIN>;
            chomp $bc;
            $ret = is_valid_ipv4($bc);
        }
        print "\nStart Device On Boot? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            $onboot = 0;
        }

        print GREEN "\nSelected configuration:\n";
        print "DEVICE=$dev\n";
        print "IPADDR=$ip\n";
        print "NETMASK=$nm\n";
        print "NETWORK=$nw\n";
        print "BROADCAST=$bc\n";
        if ($DISTRO eq "RHEL6.3") {
            print "NM_CONTROLLED=yes\n";
            print "TYPE=InfiniBand\n";
        }
        if ($onboot) {
            print "ONBOOT=yes\n";
        }
        else {
            print "ONBOOT=no\n";
        }
        print "\nDo you want to save the selected configuration? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            return;
        } 
    }
    else {
        if (not $config_net_given) {
            return;
        }
        print "Going to update $target\n" if ($verbose2);
        if ($ifcfg{$dev}{'LAN_INTERFACE'}) {
            $eth_dev = $ifcfg{$dev}{'LAN_INTERFACE'};
            if (not -e "/sys/class/net/$eth_dev") {
                print "Device $eth_dev is not present\n" if (not $quiet);
                return;
            }
            if ( is_carrier ($eth_dev) ) {
                $found_eth_up = 1;
            }
        }
        else {
            # Take the first existing Eth interface
            my @eth_devs = </sys/class/net/eth*>;
            for my $tmp_dev ( @eth_devs ) {
                $eth_dev = $tmp_dev;
                $eth_dev =~ s@/sys/class/net/@@g;
                if ( is_carrier ($eth_dev) ) {
                    $found_eth_up = 1;
                    last;
                }
            }
        }

        if ($found_eth_up) {
            get_net_config("$eth_dev");
        }

        if (not $ifcfg{$dev}{'IPADDR'}) {
            print "IP address is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'NETMASK'}) {
            print "Netmask is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'NETWORK'}) {
            print "Network is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'BROADCAST'}) {
            print "Broadcast address is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }

        my @ipib = (split('\.', $ifcfg{$dev}{'IPADDR'}));
        my @nmib = (split('\.', $ifcfg{$dev}{'NETMASK'}));
        my @nwib = (split('\.', $ifcfg{$dev}{'NETWORK'}));
        my @bcib = (split('\.', $ifcfg{$dev}{'BROADCAST'}));

        my @ipeth = (split('\.', $ifcfg{$eth_dev}{'IPADDR'}));
        my @nmeth = (split('\.', $ifcfg{$eth_dev}{'NETMASK'}));
        my @nweth = (split('\.', $ifcfg{$eth_dev}{'NETWORK'}));
        my @bceth = (split('\.', $ifcfg{$eth_dev}{'BROADCAST'}));

        for (my $i = 0; $i < 4 ; $i ++) {
            if ($ipib[$i] =~ m/\*/) {
                if ($ipeth[$i] =~ m/(\d\d?\d?)/) {
                    $ipib[$i] = $ipeth[$i];
                }
                else {
                    print "Cannot determine the IP address of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($nmib[$i] =~ m/\*/) {
                if ($nmeth[$i] =~ m/(\d\d?\d?)/) {
                    $nmib[$i] = $nmeth[$i];
                }
                else {
                    print "Cannot determine the netmask of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($bcib[$i] =~ m/\*/) {
                if ($bceth[$i] =~ m/(\d\d?\d?)/) {
                    $bcib[$i] = $bceth[$i];
                }
                else {
                    print "Cannot determine the broadcast address of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($nwib[$i] !~ m/(\d\d?\d?)/) {
                $nwib[$i] = $nweth[$i];
            }
        }

        $ip = "$ipib[0].$ipib[1].$ipib[2].$ipib[3]";
        $nm = "$nmib[0].$nmib[1].$nmib[2].$nmib[3]";
        $nw = "$nwib[0].$nwib[1].$nwib[2].$nwib[3]";
        $bc = "$bcib[0].$bcib[1].$bcib[2].$bcib[3]";

        print GREEN "IPoIB configuration for $dev\n";
        print "DEVICE=$dev\n";
        print "IPADDR=$ip\n";
        print "NETMASK=$nm\n";
        print "NETWORK=$nw\n";
        print "BROADCAST=$bc\n";
        if ($onboot) {
            print "ONBOOT=yes\n";
        }
        else {
            print "ONBOOT=no\n";
        } 
        print RESET "\n";
    }

    open(IF, ">$target") or die "Can't open $target: $!";
    if ($DISTRO =~ m/SLES/) {
        print IF "BOOTPROTO='static'\n";
        print IF "IPADDR='$ip'\n";
        print IF "NETMASK='$nm'\n";
        print IF "NETWORK='$nw'\n";
        print IF "BROADCAST='$bc'\n";
        print IF "REMOTE_IPADDR=''\n";
        if ($onboot) {
            print IF "STARTMODE='onboot'\n";
        }
        else {
            print IF "STARTMODE='manual'\n";
        }
        print IF "WIRELESS=''\n";
    }
    else {
        print IF "DEVICE=$dev\n";
        print IF "BOOTPROTO=static\n";
        print IF "IPADDR=$ip\n";
        print IF "NETMASK=$nm\n";
        print IF "NETWORK=$nw\n";
        print IF "BROADCAST=$bc\n";
        if ($DISTRO eq "RHEL6.3") {
            print IF "NM_CONTROLLED=yes\n";
            print IF "TYPE=InfiniBand\n";
        }
        if ($onboot) {
            print IF "ONBOOT=yes\n";
        }
        else {
            print IF "ONBOOT=no\n";
        }
    }
    close(IF);
}

sub ipoib_config
{
    if ($interactive) {
        print BLUE;
        print "\nThe default IPoIB interface configuration is based on DHCP.";
        print "\nNote that a special patch for DHCP is required for supporting IPoIB.";
        print "\nThe patch is available under docs/dhcp";
        print "\nIf you do not have DHCP, you must change this configuration in the following steps.";
        print RESET "\n";
    }

    my $ports_num = count_ports();
    for (my $i = 0; $i < $ports_num; $i++ ) {
        config_interface($i);
    }

    if ($interactive) {
        print GREEN "IPoIB interfaces configured successfully",RESET "\n";
        print "Press any key to continue ...";
        getch();
    }

    if (-f "/etc/sysconfig/network/config") {
        my $nm = `grep ^NETWORKMANAGER=yes /etc/sysconfig/network/config`;
        chomp $nm;
        if ($nm) {
            print RED "Please set NETWORKMANAGER=no in the /etc/sysconfig/network/config", RESET "\n";
        }
    }

}

sub force_uninstall
{
    my $res = 0;
    my $sig = 0;
    my $cnt = 0;
    my @other_ofed_rpms = `rpm -qa 2> /dev/null | grep -wE "rdma|ofed|openib|ofa_kernel"`;
    my $cmd = "rpm -e --allmatches";

    for my $package (@all_packages, @hidden_packages, @prev_ofed_packages, @other_ofed_rpms, @distro_ofed_packages) {
        chomp $package;
        next if ($package eq "mpi-selector");
        if (is_installed($package)) {
            push (@packages_to_uninstall, $package);
            $selected_for_uninstall{$package} = 1;
        }
        if (is_installed("$package-static")) {
            push (@packages_to_uninstall, "$package-static");
            $selected_for_uninstall{$package} = 1;
        }
        if ($suffix_32bit and is_installed("$package$suffix_32bit")) {
            push (@packages_to_uninstall,"$package$suffix_32bit");
            $selected_for_uninstall{$package} = 1;
        }
        if ($suffix_64bit and is_installed("$package$suffix_64bit")) {
            push (@packages_to_uninstall,"$package$suffix_64bit");
            $selected_for_uninstall{$package} = 1;
        }
    }

    for my $package (@packages_to_uninstall) {
        get_requires($package);
    }

    for my $package (@packages_to_uninstall, @dependant_packages_to_uninstall) {
        if (is_installed("$package")) {
            $cmd .= " $package";
            $cnt ++;
        }
    }

    if ($cnt) {
        print "\n$cmd\n" if (not $quiet);
        open (LOG, "+>$ofedlogs/ofed_uninstall.log");
        print LOG "$cmd\n";
        close LOG;
        system("$cmd >> $ofedlogs/ofed_uninstall.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to uninstall the previous installation", RESET "\n";
            print RED "See $ofedlogs/ofed_uninstall.log", RESET "\n";
            exit 1;
        }
    }
}

sub uninstall
{
    my $res = 0;
    my $sig = 0;
    my $distro_rpms = '';

    my $ofed_uninstall = `which ofed_uninstall.sh 2> /dev/null`;
    chomp $ofed_uninstall;
    if (-f "$ofed_uninstall") {
        print BLUE "Uninstalling the previous version of $PACKAGE", RESET "\n" if (not $quiet);
        system("yes | ofed_uninstall.sh >> $ofedlogs/ofed_uninstall.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            system("yes | $CWD/uninstall.sh >> $ofedlogs/ofed_uninstall.log 2>&1");
            $res = $? >> 8;
            $sig = $? & 127;
            if ($sig or $res) {
                # Last try to uninstall
                force_uninstall();
            }
        } else {
            return 0;
        }
    } else {
        force_uninstall();
    }
}

sub install
{
    # Build and install selected RPMs
    for my $package ( @selected_packages ) {
        if ($packages_info{$package}{'internal'}) {
            my $parent = $packages_info{$package}{'parent'};
            if (not $main_packages{$parent}{'srpmpath'}) {
                print RED "$parent source RPM is not available", RESET "\n";
                next;
            }
        }

        if ($packages_info{$package}{'mode'} eq "user") {
            if (not $packages_info{$package}{'exception'}) {
                if ( (not $packages_info{$package}{'rpm_exist'}) or 
                     ($build32 and $packages_info{$package}{'install32'} and 
                      not $packages_info{$package}{'rpm_exist32'}) ) {
                    build_rpm($package);
                }
    
                if ( (not $packages_info{$package}{'rpm_exist'}) or 
                     ($build32 and $packages_info{$package}{'install32'} and 
                      not $packages_info{$package}{'rpm_exist32'}) ) {
                    print RED "$package was not created", RESET "\n";
                    exit 1;
                }
                print "Install $package RPM:\n" if ($verbose);
                install_rpm($package);
            }
        }
        else {
            # kernel modules
            if (not $packages_info{$package}{'rpm_exist'}) {
                my $parent = $packages_info{$package}{'parent'};
                print "Build $parent RPM\n" if ($verbose);
                build_kernel_rpm($parent);
            }
            if (not $packages_info{$package}{'rpm_exist'}) {
                print RED "$package was not created", RESET "\n";
                exit 1;
            }
            print "Install $package RPM:\n" if ($verbose);
            install_kernel_rpm($package);
        }
    }
}

sub check_pcie_link
{
    if (open (PCI, "$lspci -d 15b3: -n|")) {
        while(<PCI>) {
            my $devinfo = $_;
            $devinfo =~ /(15b3:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])/;
            my $devid = $&;
            my $link_width = `$setpci -d $devid 72.B | cut -b1`;
            chomp $link_width;

            print BLUE "Device ($devid):\n";
            print "\t" . `$lspci -d $devid`;

            if ( $link_width eq "8" ) {
                print "\tLink Width: 8x\n";
            }
            else {
                print "\tLink Width is not 8x\n";
            }
            my $link_speed = `$setpci -d $devid 72.B | cut -b2`;
            chomp $link_speed;
            if ( $link_speed eq "1" ) {
                print "\tPCI Link Speed: 2.5Gb/s\n";
            }
            elsif ( $link_speed eq "2" ) {
                print "\tPCI Link Speed: 5Gb/s\n";
            }
            else {
                print "\tPCI Link Speed: Unknown\n";
            }
            print "", RESET "\n";
        }
        close (PCI);
    }
}

### MAIN AREA ###
sub main
{
    if ($print_available) {
        my @list = ();
        set_availability();

        if (!$install_option) {
            $install_option = 'all';
        }

        $config = $CWD . "/ofed-$install_option.conf";
        chomp $config;
        if ($install_option eq 'all') {
            @list = (@all_packages, @hidden_packages);
        }
        elsif ($install_option eq 'hpc') {
            @list = (@hpc_user_packages, @hpc_kernel_packages);
            @kernel_modules = (@hpc_kernel_modules);
        }
        elsif ($install_option eq 'basic') {
            @list = (@basic_user_packages, @basic_kernel_packages);
            @kernel_modules = (@basic_kernel_modules);
        }
        open(CONFIG, ">$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        print "\nOFED packages: ";
        for my $package ( @list ) {
            next if (not $packages_info{$package}{'available'});
            if ($package eq "compat-rdma") {
                print "\nKernel modules: ";
                for my $module ( @kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    print $module . ' ';
                    print CONFIG "$module=y\n";
                }
                print "\nRPMs: ";
            }
            print $package . ' ';
            print CONFIG "$package=y\n";
        }
        flock CONFIG, $UNLOCK;
        close(CONFIG);
        print "\n";
        print GREEN "Created $config", RESET "\n";
        exit 0;
    }
    
    my $num_selected = 0;

    if ($interactive) {
        my $inp;
        my $ok = 0;
        my $max_inp;
    
        while (! $ok) {
            $max_inp = show_menu("main");
            $inp = getch();
    
            if ($inp =~ m/[qQ]/ || $inp =~ m/[Xx]/ ) {
                die "Exiting\n";
            }
            if (ord($inp) == $KEY_ENTER) {
                next;
            }
            if ($inp =~ m/[0123456789abcdefABCDEF]/)
            {
                $inp = hex($inp);
            }
            if ($inp < 1 || $inp > $max_inp)
            {
                print "Invalid choice...Try again\n";
                next;
            }
            $ok = 1;
        }
    
        if ($inp == 1) {
            if (-e "$CWD/docs/${PACKAGE}_Installation_Guide.txt") {
                system("less $CWD/docs/${PACKAGE}_Installation_Guide.txt");
            }
            elsif (-e "$CWD/README.txt") {
                system("less $CWD/README.txt");
            }
            else {
                print RED "$CWD/docs/${PACKAGE}_Installation_Guide.txt does not exist...", RESET;
            }

            return 0;
        }
        elsif ($inp == 2) {
            for my $srcrpm ( <$SRPMS*> ) {
                set_cfg ($srcrpm);
            }
            
            # Set RPMs info for available source RPMs
            set_availability();
            $num_selected = select_packages();
            set_existing_rpms();
            resolve_dependencies();
            check_linux_dependencies();
            if (not $quiet) {
                print_selected();
            }
        }
        elsif ($inp == 3) {
            my $cnt = 0;
            for my $package ( @all_packages, @hidden_packages) {
                if (is_installed($package)) {
                    print "$package\n";
                    $cnt ++;
                }
            }
            if (not $cnt) {
                print "\nThere is no $PACKAGE software installed\n";
            }
            print GREEN "\nPress any key to continue...", RESET;
            getch();
            return 0;
        }
        elsif ($inp == 4) {
            ipoib_config();
            return 0;
        }
        elsif ($inp == 5) {
            uninstall();
            exit 0;
        }
    
    }
    else {
        for my $srcrpm ( <$SRPMS*> ) {
            set_cfg ($srcrpm);
        }

        # Set RPMs info for available source RPMs
        set_availability();
        $num_selected = select_packages();
        set_existing_rpms();
        resolve_dependencies();
        check_linux_dependencies();
        if (not $quiet) {
            print_selected();
        }
    }
    
    if (not $num_selected) {
        print RED "$num_selected packages selected. Exiting...", RESET "\n";
        exit 1;
    }
    print BLUE "Detected Linux Distribution: $DISTRO", RESET "\n" if ($verbose3);
    
    # Uninstall the previous installations
    uninstall();
    my $vendor_ret;
    if (length($vendor_pre_install) > 0) {
            print BLUE "\nRunning vendor pre install script: $vendor_pre_install", RESET "\n" if (not $quiet);
            $vendor_ret = system ( "$vendor_pre_install", "CONFIG=$config",
                "RPMS=$RPMS", "SRPMS=$SRPMS", "PREFIX=$prefix", "TOPDIR=$TOPDIR", "QUIET=$quiet" );
            if ($vendor_ret != 0) {
                    print RED "\nExecution of vendor pre install script failed.", RESET "\n" if (not $quiet);
                    exit 1;
            }
    }
    install();

    system("/sbin/ldconfig > /dev/null 2>&1");

    if (-f "/etc/modprobe.conf.dist") {
        open(MDIST, "/etc/modprobe.conf.dist") or die "Can't open /etc/modprobe.conf.dist: $!";
        my @mdist_lines;
        while (<MDIST>) {
            push @mdist_lines, $_;
        }
        close(MDIST);

        open(MDIST, ">/etc/modprobe.conf.dist") or die "Can't open /etc/modprobe.conf.dist: $!";
        foreach my $line (@mdist_lines) {
            chomp $line;
            if ($line =~ /^\s*install ib_core|^\s*alias ib|^\s*alias net-pf-26 ib_sdp/) {
                print MDIST "# $line\n";
            } else {
                print MDIST "$line\n";
            }
        }
        close(MDIST);
    }

    if (length($vendor_pre_uninstall) > 0) {
	    system "cp $vendor_pre_uninstall $prefix/sbin/vendor_pre_uninstall.sh";
    }
    if (length($vendor_post_uninstall) > 0) {
	    system "cp $vendor_post_uninstall $prefix/sbin/vendor_post_uninstall.sh";
    }
    if (length($vendor_post_install) > 0) {
	    print BLUE "\nRunning vendor post install script: $vendor_post_install", RESET "\n" if (not $quiet);
	    $vendor_ret = system ( "$vendor_post_install", "CONFIG=$config",
		"RPMS=$RPMS", "SRPMS=$SRPMS", "PREFIX=$prefix", "TOPDIR=$TOPDIR", "QUIET=$quiet");
	    if ($vendor_ret != 0) {
		    print RED "\nExecution of vendor post install script failed.", RESET "\n" if (not $quiet);
		    exit 1;
	    }
    }

    if ($kernel_modules_info{'ipoib'}{'selected'}) {
        ipoib_config();

        # Decrease send/receive queue sizes on 32-bit arcitecture
        # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=1420
        if ($arch =~ /i[3-6]86/) {
            if (-f "/etc/modprobe.d/ib_ipoib.conf") {
                open(MODPROBE_CONF, ">>/etc/modprobe.d/ib_ipoib.conf");
                print MODPROBE_CONF "options ib_ipoib send_queue_size=64 recv_queue_size=128\n";
                close MODPROBE_CONF;
            }
        }

        # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=1449
        if (-f "/etc/modprobe.d/ipv6") {
            open(IPV6, "/etc/modprobe.d/ipv6") or die "Can't open /etc/modprobe.d/ipv6: $!";
            my @ipv6_lines;
            while (<IPV6>) {
                push @ipv6_lines, $_;
            }
            close(IPV6);

            open(IPV6, ">/etc/modprobe.d/ipv6") or die "Can't open /etc/modprobe.d/ipv6: $!";
            foreach my $line (@ipv6_lines) {
                chomp $line;
                if ($line =~ /^\s*install ipv6/) {
                    print IPV6 "# $line\n";
                } else {
                    print IPV6 "$line\n";
                }
            }
            close(IPV6);
        }
    }

    if ( not $quiet ) {
        check_pcie_link();
    }

    if ($umad_dev_rw) {
        if (-f $ib_udev_rules) {
            open(IB_UDEV_RULES, $ib_udev_rules) or die "Can't open $ib_udev_rules: $!";
            my @ib_udev_rules_lines;
            while (<IB_UDEV_RULES>) {
                push @ib_udev_rules_lines, $_;
            }
            close(IPV6);

            open(IB_UDEV_RULES, ">$ib_udev_rules") or die "Can't open $ib_udev_rules: $!";
            foreach my $line (@ib_udev_rules_lines) {
                chomp $line;
                if ($line =~ /umad/) {
                    print IB_UDEV_RULES "$line, MODE=\"0666\"\n";
                } else {
                    print IB_UDEV_RULES "$line\n";
                }
            }
            close(IB_UDEV_RULES);
        }
    }

    print GREEN "\nInstallation finished successfully.", RESET;
    if ($interactive) {
        print GREEN "\nPress any key to continue...", RESET;
        getch();
    }
    else {
        print "\n";
    }
}

while (1) {
    main();
    exit 0 if (not $interactive);
}
