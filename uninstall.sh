#!/bin/bash
#
# Copyright (c) 2006 Mellanox Technologies. All rights reserved.
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
#
#
#  $Id: uninstall.sh 9432 2006-09-12 09:06:46Z vlad $
#
# Description: OFED package uninstall script

RPM=`which rpm 2>/dev/null`
if [ ! -n "$RPM" ]; then
	echo "Please install rpm package to continue"
	exit 1
fi

RM=/bin/rm
NULL=/dev/null

PACKAGE="OFED"
# Default ${PACKAGE} stack prefix

STACK_PREFIX=/usr

ARCH=$(uname -m)

UNLOAD_MODULES=0
FORCE=0

while [ $# -gt 0 ]
do
    case $1 in
            --unload-modules)
                UNLOAD_MODULES=1
            ;;
            --force)
                FORCE=1
            ;;
            *)
            ;;
    esac
    shift
done

IB_ALL_PACKAGES="$IB_ALL_PACKAGES compat-rdma compat-rdma-devel "
IB_ALL_PACKAGES="$IB_ALL_PACKAGES kernel-ib kernel-ib-devel ipoibtools "
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libopensm libopensm-devel libosmcomp libosmcomp-devel libosmvendor libosmvendor-devel"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES openib-diags ib-bonding ib-bonding-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibverbs libibverbs-devel libibverbs-devel-static libibverbs-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibverbs-utils libibverbs-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libmthca libmthca-devel libmthca-devel-static libmthca-debuginfo libmthca-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libmlx4 libmlx4-devel libmlx4-devel-static libmlx4-debuginfo libmlx4-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libehca libehca-devel-static libehca-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libcxgb3 libcxgb3-devel libcxgb3-debuginfo libcxgb3-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libcxgb4 libcxgb4-devel libcxgb4-debuginfo libcxgb4-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libnes libnes-devel-static libnes-debuginfo libnes-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libipathverbs libipathverbs-devel libipathverbs-debuginfo libipathverbs-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibcm libibcm-devel libibcm-debuginfo libibcm-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibcommon libibcommon-devel libibcommon-static libibcommon-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibumad libibumad-devel libibumad-static libibumad-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibmad libibmad-devel libibmad-static libibmad-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES librdmacm librdmacm-utils librdmacm-devel librdmacm-debuginfo librdmacm-static ibacm"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libsdp libsdp-devel libsdp-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES opensm opensm-libs opensm-devel opensm-debuginfo opensm-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES perftest perftest-debuginfo mstflint mstflint-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES compat-dapl compat-dapl-devel compat-dapl-devel-static compat-dapl-utils compat-dapl-debuginfo compat-dapl-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES compat-dapl-1.2.5 compat-dapl-devel-1.2.5 compat-dapl-devel-static-1.2.5 compat-dapl-utils-1.2.5 compat-dapl-debuginfo-1.2.5 compat-dapl-static-1.2.5"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES dapl dapl-devel dapl-devel-static dapl-utils dapl-debuginfo dapl-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES qlvnictools qlvnictools-debuginfo ibvexdmtools ibvexdmtools-debuginfo qlgc_vnic_daemon sdpnetstat sdpnetstat-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES srptools srptools-debuginfo rds-tools rds-devel rds-tools-debuginfo rnfs-utils rnfs-utils-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES ibsim ibsim-debuginfo ibutils2 ibutils2-devel ibutils2-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES ibutils ibutils-debuginfo ibutils-libs ibutils-devel infiniband-diags infiniband-diags-debuginfo qperf qperf-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES openib-mstflint openib-tvflash openib-srptools openib-perftest"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES ofed-docs ofed-scripts"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES infinipath-psm infinipath-psm-devel"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES mlnxofed-docs mlnx-ofc"

ALL_PACKAGES="$IB_ALL_PACKAGES mvapich mvapich2 openmpi openmpi-libs openmpi-devel mpitests mft"

PREV_RELEASE_PACKAGES="mpich_mlx ibtsal openib opensm opensm-devel mpi_ncsa thca ib-osm osm diags ibadm ib-diags ibgdiag ibdiag ib-management"
PREV_RELEASE_PACKAGES="$PREV_RELEASE_PACKAGES ib-verbs ib-ipoib ib-cm ib-sdp ib-dapl udapl udapl-devel libdat libibat ib-kdapl ib-srp ib-srp_target oiscsi-iser-support"

MPI_SELECTOR_NAME="mpi-selector"
OPENMPI_NAME="openmpi"
MVAPICH2_NAME="mvapich2"
MVAPICH_NAME="mvapich"

if [ -f /etc/SuSE-release ]; then
    DISTRIBUTION="SuSE"
elif [ -f /etc/fedora-release ]; then
    DISTRIBUTION="fedora"
elif [ -f /etc/rocks-release ]; then
    DISTRIBUTION="Rocks"
elif [ -f /etc/redhat-release ]; then
    DISTRIBUTION="redhat"
elif [ -f /etc/debian_version ]; then
    DISTRIBUTION="debian"
else
    DISTRIBUTION=$(ls /etc/*-release | head -n 1 | xargs -iXXX basename XXX -release 2> $NULL)
    [ -z "${DISTRIBUTION}" ] && DISTRIBUTION="unsupported"
fi

OPEN_ISCSI_SUSE_NAME="open-iscsi"
OPEN_ISCSI_REDHAT_NAME="iscsi-initiator-utils"
STGT_SUSE_NAME="tgt"
STGT_REDHAT_NAME="scsi-target-utils"

# Execute the command $@ and check exit status
ex()
{
echo Running $@
eval "$@"
if [ $? -ne 0 ]; then
     echo
     echo Failed in execution \"$@\"
     echo
     exit 5
fi
}


# Uninstall Software
uninstall()
{
    local RC=0
    echo
    echo "Removing ${PACKAGE} Software installations"
    echo
    packs_to_remove=""

    case ${DISTRIBUTION} in
        SuSE)
        if ( $RPM -q ${OPEN_ISCSI_SUSE_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${OPEN_ISCSI_SUSE_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${OPEN_ISCSI_SUSE_NAME}"
        fi
        if ( $RPM -q ${STGT_SUSE_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${STGT_SUSE_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${STGT_SUSE_NAME}"
        fi
        ;;
        redhat)
        if ( $RPM -q ${OPEN_ISCSI_REDHAT_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${OPEN_ISCSI_REDHAT_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${OPEN_ISCSI_REDHAT_NAME}"
        fi
        if ( $RPM -q ${STGT_REDHAT_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${STGT_REDHAT_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${STGT_REDHAT_NAME}"
        fi
        ;;
        *)
        echo "Error: Distribution ${DISTRIBUTION} is not supported by open-iscsi over iSER. Cannot uninstall open-iscsi"
        ;;
    esac

    MPITESTS_LIST=$(rpm -qa | grep mpitests)

    if [ -n "$MPITESTS_LIST" ]; then
        for mpitest_name in $MPITESTS_LIST
        do 
            if ( $RPM -q ${mpitest_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpitest_name}"
            fi
        done    
    fi

   MVAPICH_LIST=$(rpm -qa | grep ${MVAPICH_NAME})

    if [ -n "$MVAPICH_LIST" ]; then
        for mpi_name in $MVAPICH_LIST
        do 
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ex "$RPM -e --allmatches ${mpi_name}"
            fi
        done    
    fi

    MVAPICH2_LIST=$(rpm -qa |grep ${MVAPICH2_NAME})

    if [ -n "$MVAPICH2_LIST" ]; then
        for mpi_name in $MVAPICH2_LIST
        do
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ex "$RPM -e --allmatches ${mpi_name}"
            fi
        done
    fi

    OPENMPI_LIST=$(rpm -qa | grep ${OPENMPI_NAME})

    if [ -n "$OPENMPI_LIST" ]; then
        ompi_packs_to_remove=""
        for mpi_name in $OPENMPI_LIST
        do 
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ompi_packs_to_remove="$ompi_packs_to_remove ${mpi_name}"	
            fi
        done   
        ex "$RPM -e --allmatches $ompi_packs_to_remove > /dev/null 2>&1"
    fi

    MPI_SELECTOR_LIST=$(rpm -qa | grep ${MPI_SELECTOR_NAME})

    if [ -n "$MPI_SELECTOR_LIST" ]; then
        for mpiselector in $MPI_SELECTOR_LIST
        do 
            if ( $RPM -q ${mpiselector} > $NULL 2>&1 ); then
                if ! ( $RPM -e --allmatches ${mpiselector} > /dev/null 2>&1 ); then
			echo "Cannot remove ${mpiselector}."
			echo "There are RPMs that depend on it."
                fi
            fi
        done    
    fi
    
    for package in $ALL_PACKAGES $PREV_RELEASE_PACKAGES
    do
        if ( $RPM -q ${package} > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${package}"
            let RC++
        fi
    done    

    if ( $RPM -q ib-verbs > $NULL 2>&1 ); then
        STACK_PREFIX=`$RPM -ql ib-verbs | grep "bin/ibv_devinfo" | sed -e 's/\/bin\/ibv_devinfo//'`
        let RC++
    fi    

    if ( $RPM -q libibverbs > $NULL 2>&1 ); then
        STACK_PREFIX=$($RPM -ql libibverbs | grep "libibverbs.so" | head -1 | sed -e 's@/lib.*/libibverbs.so.*@@')            
    fi

    if [ -x /etc/infiniband/info ]; then
        if [ -z ${STACK_PREFIX} ]; then
            STACK_PREFIX=`/etc/infiniband/info | grep -w prefix | cut -d '=' -f 2`
        fi
        KVERSION=`/etc/infiniband/info | grep -w Kernel | cut -d '=' -f 2`
    fi

    if [ -n "${packs_to_remove}" ]; then
        ex "$RPM -e --allmatches $packs_to_remove"
    fi

    if [[ ! -z $MTHOME && -d $MTHOME ]]; then
        if [ -e $MTHOME/uninstall.sh ]; then
            echo
            echo "  An old version of the OPENIB driver was detected and will be removed now"
            ex "yes | env MTHOME=$MTHOME $MTHOME/uninstall.sh"
        fi    
        let RC++
    elif [ -d /usr/mellanox ]; then
        if [ -e /usr/mellanox/uninstall.sh ]; then
            echo
            echo "  Removing MVAPI..."
            ex "yes | /usr/mellanox/uninstall.sh"
        fi  
    fi

    # Remove /usr/local/ofed* if exist
    # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=563
    if [ -d ${STACK_PREFIX} ]; then
        case ${STACK_PREFIX} in
                    /usr/local/ofed* )
                    rm -rf ${STACK_PREFIX}
                    ;;
        esac
    fi

    if [ -d ${STACK_PREFIX}/mpi ]; then
        find ${STACK_PREFIX}/mpi -type d | sort -r | xargs rmdir
    fi

#    # Uninstall SilverStorm package
#    if [ -e /sbin/iba_config ]; then
#        ex /sbin/iba_config -u
#    fi

    # Uninstall Topspin package
    topspin_rpms=$($RPM -qa | grep "topspin-ib")
    if [ -n "${topspin_rpms}" ]; then
        ex $RPM -e ${topspin_rpms}
    fi

    # Uninstall Voltaire package
    voltaire_rpms=$($RPM -qa | grep -i "Voltaire" | grep "4.0.0_5")
    if [ -n "${voltaire_rpms}" ]; then
        ex $RPM -e ${voltaire_rpms}
    fi

    if [ ! -z "${KVERSION}" ]; then
        # Remove OFED kernel modules from updates directory
        LIB_MOD_DIR=/lib/modules/${KVERSION}/updates
        /bin/rm -rf ${LIB_MOD_DIR}/kernel/drivers/infiniband
        /bin/rm -rf ${LIB_MOD_DIR}/kernel/drivers/net/mlx4
        /bin/rm -rf ${LIB_MOD_DIR}/kernel/drivers/net/cxgb3
        /bin/rm -rf ${LIB_MOD_DIR}/kernel/net/rds
    fi

    if [ -f /etc/modprobe.d/ipv6 ]; then
        perl -ni -e "s@# install ipv6 \/bin\/true@install ipv6 /bin/true@;print" /etc/modprobe.d/ipv6
    fi
}

echo
echo "This program will uninstall all ${PACKAGE} packages on your machine."
echo

if [ $FORCE -eq 0 ]; then
    read -p "Do you want to continue?[y/N]:" ans_r
else
    ans_r="y"
fi

if [[ "$ans_r" == "y" || "$ans_r" == "Y" || "$ans_r" == "yes" ]]; then
    if [ $UNLOAD_MODULES -eq 1 ]; then
        if [ -x /etc/init.d/openibd ]; then
            ex /etc/init.d/openibd stop
        fi
    fi
    [ -x $STACK_PREFIX/sbin/vendor_pre_uninstall.sh ] && ex $STACK_PREFIX/sbin/vendor_pre_uninstall.sh
    [ -x $STACK_PREFIX/sbin/vendor_post_uninstall.sh ] && \
        cp $STACK_PREFIX/sbin/vendor_post_uninstall.sh /tmp/$$-ofed_vendor_post_uninstall.sh
    uninstall
    [ -x /tmp/$$-ofed_vendor_post_uninstall.sh ] && ex /tmp/$$-ofed_vendor_post_uninstall.sh
    exit 0
else    
    exit 1
fi
