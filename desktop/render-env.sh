# Sourced by /bin/sh; keep the choice consistent across GDM, GNOME and apps.
# Renderer variables belong to this integration; discard stale login values.
unset LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER COGL_DRIVER COGL_RENDERER MALI_DEFAULT_DISPLAY
renderer=$(cat /etc/rockchip-desktop-renderer 2>/dev/null)
if [ "$renderer" = mali ]; then
    # X11 desktop: Mutter GLES2 via the Mali X11 EGL backend.
    export LD_LIBRARY_PATH=/opt/rockchip/mali
    export MALI_DEFAULT_DISPLAY=x11
    export COGL_DRIVER=gles2 COGL_RENDERER=EGL_XLIB
elif [ "$renderer" = wayland ]; then
    # Wayland desktop: Mutter composites with GLES2 on the Mali
    # GBM/Wayland backend (same stack as the Debian trixie reference).
    export LD_LIBRARY_PATH=/opt/rockchip/mali
    export MALI_DEFAULT_DISPLAY=wayland
    export COGL_DRIVER=gles2
else
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
fi
