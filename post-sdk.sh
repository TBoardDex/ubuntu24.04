#!/bin/bash
set -e
SCRIPT_DIR=$(dirname "$(realpath "$0")")
SDK_DIR=$(dirname "$SCRIPT_DIR")
[[ $EUID == 0 && $# == 1 && -f "$1/etc/os-release" ]] || exit 1
# Import the SDK function library without executing the build entry point.
source <(sed '/^err_handler()/,$d' "$SDK_DIR/device/rockchip/common/scripts/build.sh")
TARGET=$(realpath "$1")
[[ "$TARGET" != / ]] || exit 1
FLAVOR=${FLAVOR:-server}
case "$FLAVOR" in server|desktop) ;; *) exit 1 ;; esac
export RK_SDK_DIR="$SDK_DIR" RK_COMMON_DIR="$SDK_DIR/device/rockchip/common"
export RK_SCRIPTS_DIR="$RK_COMMON_DIR/scripts" RK_CHIP_DIR="$SDK_DIR/device/rockchip/.chips/rk3588"
export RK_TOOLS_DIR="$RK_COMMON_DIR/tools" RK_OUTDIR="$SDK_DIR/output/ubuntu-noble-$FLAVOR/sdk-post"
export RK_LOG_DIR="$RK_OUTDIR/log" RK_SESSION="ubuntu-noble-$FLAVOR" RK_CONFIG="$RK_OUTDIR/.config"
export RK_POST_HELPER="$RK_SCRIPTS_DIR/post-helper" RK_OWNER_UID=$(stat -c %u "$SDK_DIR") RK_OWNER=$(stat -c %U "$SDK_DIR")
export RK_EXTRA_PARTS_DIR="$RK_COMMON_DIR/extra-parts" RK_EXTRA_PART_OUTDIR="$RK_OUTDIR/extra-parts"
# The standalone Ubuntu build does not run through the normal SDK session
# setup.  Point post-hooks at the Ubuntu resources explicitly so they do not
# accidentally inherit a Debian/Buildroot session from the host shell.
export RK_RKSCRIPT_DIR="$SDK_DIR/ubuntu24.04/bsp/rkscript"
export RK_WIFIBT_RESOURCE_DIR="$SDK_DIR/ubuntu24.04/bsp/wifibt"
export RK_AIC_FIRMWARE_DIR="$SDK_DIR/ubuntu24.04/overlay-firmware/lib/firmware/aic8800"
export RK_ROOTFS_OVERLAY=y RK_ROOTFS_INSTALL_MODULES=y
export RK_ROOTFS_STRIP_MODULES=y RK_ROOTFS_LD_CACHE=y RK_ROOTFS_TYPE=ext4
export POST_OS=ubuntu POST_INIT=systemd POST_INIT_SYSTEMD=1 POST_ROOTFS=1
mkdir -p "$RK_LOG_DIR"
DEFCONFIG="tboard-r5a_rk3588s_ubuntu24_${FLAVOR}_defconfig"
CONF="$SDK_DIR/output/kconf/conf"
[[ -x "$CONF" ]] || make -C "$RK_COMMON_DIR" "$CONF"
if [ -n "$UBUNTU_SDK_CONFIG" ] && [ -r "$UBUNTU_SDK_CONFIG" ]; then
  cp "$UBUNTU_SDK_CONFIG" "$RK_CONFIG"
  RK_DEFCONFIG="$DEFCONFIG" RK_CHIP_FAMILY=rk3588 RK_CHIP=rk3588s srctree="$RK_COMMON_DIR/configs" \
    "$CONF" --olddefconfig "$RK_COMMON_DIR/configs/Config.in"
else
  RK_DEFCONFIG="$DEFCONFIG" RK_CHIP_FAMILY=rk3588 RK_CHIP=rk3588s srctree="$RK_COMMON_DIR/configs" \
    "$CONF" --defconfig="$RK_CHIP_DIR/$DEFCONFIG" "$RK_COMMON_DIR/configs/Config.in"
fi
set -a
source "$RK_CONFIG"
RK_KERNEL_VERSION_RAW=$(grep '^VERSION = ' "$SDK_DIR/kernel/Makefile" | cut -d' ' -f3).$(grep '^PATCHLEVEL = ' "$SDK_DIR/kernel/Makefile" | cut -d' ' -f3)
RK_KERNEL_VERSION="$RK_KERNEL_VERSION_RAW"
source "$RK_SCRIPTS_DIR/partition-helper"
rk_partition_init
set +a
unset RK_SUDO_ROOT
cd "$SDK_DIR"
for hook in "$RK_COMMON_DIR"/post-hooks/*.sh; do
  "$hook" "$TARGET" ubuntu systemd
done
