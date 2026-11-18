#!/bin/bash
# Noble adaptation of the validated Ubuntu 22.04 GDM/Xorg/Mutter integration,
# extended with a Wayland renderer that mirrors the Debian trixie reference:
# GDM + GNOME on Wayland, Mutter GLES2 via the Mali GBM/Wayland EGL backend.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mode=${1:-mali}
[[ "$mode" == mali || "$mode" == wayland || "$mode" == software ]]
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble && $(dpkg --print-architecture) == arm64 ]]

if [[ "$mode" != software ]]; then
    # The Mali desktop needs Mutter's GLES2 cogl driver. EGL_XLIB is only
    # part of the X11 path; the Wayland compositor uses the GBM backend.
    python3 - "$mode" <<'PY'
import sys
from pathlib import Path
tokens = [b'gles2\0', b'COGL_DRIVER\0']
if sys.argv[1] == 'mali':
    tokens.append(b'EGL_XLIB\0')
libraries = Path('/usr/lib/aarch64-linux-gnu').glob('mutter-*/libmutter-cogl-*.so.0')
if not any(all(token in p.read_bytes() for token in tokens) for p in libraries):
    raise SystemExit('Installed Mutter lacks the GLES2 backend required by Mali')
PY
fi

if [[ "$mode" == mali ]]; then
    apt-get install -y --no-remove --no-install-recommends /tmp/rk3588-gpu/xserver.deb
    for library in /opt/rockchip/xserver/bin/Xorg \
        /opt/rockchip/xserver/lib/xorg/modules/libglamoregl.so \
        /opt/rockchip/xserver/lib/xorg/modules/drivers/modesetting_drv.so; do
        dependencies=$(LD_LIBRARY_PATH=/opt/rockchip/mali ldd "$library" 2>&1)
        [[ "$dependencies" != *"not found"* ]] || { printf '%s\n' "$dependencies" >&2; exit 1; }
    done
    /opt/rockchip/xserver/bin/Xorg -version
elif [[ "$mode" == wayland ]]; then
    [[ -r /usr/share/wayland-sessions/ubuntu-wayland.desktop ]] || {
        echo 'Ubuntu Wayland session (ubuntu-wayland.desktop) is missing.' >&2
        exit 1
    }
    apt-get install -y --no-remove --no-install-recommends glmark2-es2-wayland
fi

getent group render >/dev/null || groupadd --system render
for user in gdm tboard; do
    usermod -aG video,render "$user"
done
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/70-rk3588-mali.rules <<'UDEV'
KERNEL=="mali[0-9]*", GROUP="video", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660", TAG+="uaccess"
UDEV
if [[ "$mode" != wayland ]]; then
    # X11 desktops divert GDM's Xorg launcher. The Wayland desktop never
    # starts /usr/bin/Xorg from GDM, so the distro binary stays untouched.
    # Stock and Rockchip Xorg 21.1 use the same input ABI. The Mali launcher
    # selects the isolated Rockchip modules first; software selects stock Xorg.
    dpkg-divert --local --rename --divert /usr/bin/Xorg.distrib --add /usr/bin/Xorg
    install -m 0755 /usr/local/bin/rk3588-xserver /usr/bin/Xorg
fi
mkdir -p /etc/X11/Xsession.d
cat > /etc/X11/Xsession.d/20-rk3588-software-rendering <<'SESSION'
. /usr/local/lib/tboard/render-env.sh
SESSION
cat > /etc/X11/Xsession.d/70-rk3588-session-renderer <<'SESSION'
if [ -n "${STARTUP:-}" ]; then
    STARTUP="/usr/local/bin/rk3588-render-env $STARTUP"
fi
if [ -n "${command:-}" ]; then
    command="/usr/local/bin/rk3588-render-env $command"
fi
SESSION
for hook in /etc/X11/Xsession.d/20-rk3588-software-rendering \
    /etc/X11/Xsession.d/70-rk3588-session-renderer; do
    chmod 0644 "$hook"
    /bin/sh -n "$hook"
    run-parts --list /etc/X11/Xsession.d | grep -Fx "$hook" >/dev/null
done
case "$mode" in
    mali) units='gnome-shell-x11.service org.gnome.Shell@x11.service' ;;
    wayland) units='org.gnome.Shell@wayland.service' ;;
    software) units='gnome-shell-x11.service org.gnome.Shell@x11.service' ;;
esac
found=0
for unit in $units; do
    if [[ -r /usr/lib/systemd/user/$unit ]]; then
        mkdir -p "/etc/systemd/user/$unit.d"
        cat > "/etc/systemd/user/$unit.d/20-rockchip-renderer.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/local/bin/rk3588-render-env /usr/bin/gnome-shell
UNIT
        found=$((found + 1))
    fi
done
(( found > 0 ))
/usr/local/sbin/rk3588-desktop-renderer "$mode"
mkdir -p /usr/share/tboard
dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' > /usr/share/tboard/packages.tsv
apt-get clean
