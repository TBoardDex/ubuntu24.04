#!/bin/bash
# Run on the board or inside a resumed Noble rootfs. Never restart GDM here.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble ]]

diversion=$(dpkg-divert --truename /usr/bin/Xorg)
if [[ "$diversion" == /usr/bin/Xorg.distrib ]]; then
    [[ -x /usr/bin/Xorg.distrib ]] || { echo 'Stock Xorg backup is missing; stopping.' >&2; exit 1; }
    if [[ -e /usr/bin/Xorg ]] && ! grep -q 'rockchip-desktop-renderer' /usr/bin/Xorg; then
        echo '/usr/bin/Xorg is not the expected TBoard wrapper; stopping.' >&2
        exit 1
    fi
elif [[ "$diversion" != /usr/bin/Xorg ]]; then
    echo "Unrecognized Xorg diversion: $diversion; stopping." >&2
    exit 1
fi

backup=$(mktemp -d /var/backups/tboard-desktop-rollback.XXXXXXXX)
files=(
    /usr/bin/Xorg
    /usr/local/bin/rk3588-xserver /usr/local/bin/rk3588-render-env
    /usr/local/lib/tboard/render-env.sh /usr/local/sbin/rk3588-desktop-renderer
    /etc/X11/Xsession.d/20-rk3588-software-rendering
    /etc/X11/Xsession.d/70-rk3588-session-renderer
    /etc/X11/xorg.conf.d/20-rockchip-modesetting.conf
    /etc/systemd/system/gdm.service.d/20-rockchip-renderer.conf
    /etc/systemd/user/gnome-shell-x11.service.d/20-rockchip-renderer.conf
    /etc/systemd/user/org.gnome.Shell@x11.service.d/20-rockchip-renderer.conf
    /etc/rockchip-renderer.env /etc/rockchip-desktop-renderer /etc/environment
)
for file in "${files[@]}"; do
    if [[ -e "$file" || -L "$file" ]]; then
        cp -a --parents "$file" "$backup/"
    fi
done
dpkg-divert --list > "$backup/diversions.txt"
if [[ "$diversion" == /usr/bin/Xorg.distrib ]]; then
    rm -f /usr/bin/Xorg
    dpkg-divert --local --rename --divert /usr/bin/Xorg.distrib --remove /usr/bin/Xorg
fi
rm -f /etc/X11/Xsession.d/70-rk3588-session-renderer \
    /etc/systemd/system/gdm.service.d/20-rockchip-renderer.conf \
    /etc/systemd/user/gnome-shell-x11.service.d/20-rockchip-renderer.conf \
    /etc/systemd/user/org.gnome.Shell@x11.service.d/20-rockchip-renderer.conf \
    /etc/rockchip-renderer.env \
    /usr/local/bin/rk3588-xserver /usr/local/bin/rk3588-render-env \
    /usr/local/lib/tboard/render-env.sh

# Restore the original software baseline, including the mode switch command.
cat > /usr/local/sbin/rk3588-desktop-renderer <<'HELPER'
#!/bin/bash
set -euo pipefail
case "${1:-status}" in
    status) echo 'Configured desktop renderer: software (Xorg/Mesa llvmpipe)'; exit 0 ;;
    software) ;;
    *) echo 'Only software rendering is supported; Mali desktop adaptation was rolled back.' >&2; exit 1 ;;
esac
[[ $EUID == 0 && $# == 1 ]] || { echo 'Run as root.' >&2; exit 1; }
mkdir -p /etc/X11/xorg.conf.d /etc/X11/Xsession.d
cat > /etc/X11/xorg.conf.d/20-rockchip-modesetting.conf <<'XORG'
Section "Device"
    Identifier "Rockchip Display"
    Driver "modesetting"
    Option "AccelMethod" "none"
    Option "SWcursor" "true"
EndSection
XORG
touch /etc/environment
sed -i -E '/^[[:space:]]*(LD_LIBRARY_PATH|LIBGL_ALWAYS_SOFTWARE|GALLIUM_DRIVER|COGL_DRIVER|COGL_RENDERER)=/d' /etc/environment
cat >> /etc/environment <<'ENV'
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe
ENV
cat > /etc/X11/Xsession.d/20-rk3588-software-rendering <<'SESSION'
unset LD_LIBRARY_PATH COGL_DRIVER COGL_RENDERER
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
SESSION
printf 'software\n' > /etc/rockchip-desktop-renderer
HELPER
chmod 0755 /usr/local/sbin/rk3588-desktop-renderer
/usr/local/sbin/rk3588-desktop-renderer software
# The package is isolated, so leaving it installed cannot replace stock Xorg.
# Preserve all packages, user display settings, and application GPU libraries.
if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
fi
echo "Desktop integration rolled back. Configuration backup: $backup"
echo 'Save desktop work, then reboot. Display recovery still needs board verification.'
