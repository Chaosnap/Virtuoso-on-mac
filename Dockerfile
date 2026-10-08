# Virtuoso IC6.1.7 / MMSIM15 / Calibre2015 (CentOS 8, linux/amd64)
# X11-client image for macOS XQuartz: GUI windows open directly on the Mac,
# no Linux desktop and no VNC server inside the container.
#
# Base = the original image, kept unchanged under a backup tag (it has no
# Dockerfile of its own; it was produced with `docker commit`):
#   docker tag virtuoso:ic617 virtuoso:ic617-vnc-backup        # once, before the first build
# Build:
#   docker build --platform linux/amd64 -t virtuoso:ic617-x11 .
#
# /opt (Cadence + Mentor installs), license files and ~/.bashrc are untouched.
# NOTE (2026-10-08): virtuoso:ic617-vnc-backup was deleted after the build, so this
# file can no longer be rebuilt as-is; it documents how virtuoso:ic617 was produced.
ARG BASE_IMAGE=virtuoso:ic617-vnc-backup
FROM ${BASE_IMAGE}

# Desktop / VNC packages to remove. Checked against the RPM database
# (`rpm -e --test`) and against every ELF file under /opt: none of these
# packages provides a library that an EDA binary links to. Plain `rpm -e` is
# used on purpose instead of `dnf remove`, so that no "unused" dependency is
# auto-removed (the EDA tools are not RPM-managed, so RPM cannot see that
# they use libraries such as gtk2, libXp, libXft or mesa-libGLU).
#   XFCE4 desktop + plugins
ARG XFCE_PKGS="Thunar thunar-volman exo garcon libxfce4ui libxfce4util mousepad tumbler \
    xfce-polkit xfce4-appfinder xfce4-panel xfce4-pulseaudio-plugin xfce4-screensaver \
    xfce4-session xfce4-settings xfce4-terminal xfconf xfdesktop xfwm4"
#   TigerVNC server
ARG VNC_PKGS="tigervnc-server tigervnc-server-minimal tigervnc-license"
#   GNOME session / shell / display manager (desktop management only; GTK, GNOME libraries kept)
ARG GNOME_PKGS="gdm gnome-shell mutter gnome-session gnome-session-xsession \
    gnome-session-wayland-session gnome-settings-daemon gnome-control-center \
    gnome-control-center-filesystem"
#   Local X display servers (XQuartz on the Mac is the X server now)
ARG XSERVER_PKGS="xorg-x11-server-Xorg xorg-x11-server-Xwayland xorg-x11-drv-fbdev \
    xorg-x11-drv-libinput xorg-x11-drv-vesa"

RUN set -eu; \
    pkgs="$XFCE_PKGS $VNC_PKGS $GNOME_PKGS $XSERVER_PKGS"; \
    rpm -e --test $pkgs; \
    rpm -e $pkgs; \
    # VNC config/password and XFCE session leftovers from the old desktop setup
    rm -rf /root/.vnc /root/.config/xfce4 /root/.config/Thunar /root/.config/Mousepad \
           /root/.config/autostart/xfce-polkit.desktop /root/.ICEauthority /root/.Xauthority \
           /tmp/.xfsm-ICE-*; \
    rmdir /root/.config/autostart 2>/dev/null || true; \
    # Fail the build if any EDA entry point disappeared
    test -x /opt/cadence/IC617/tools/dfII/bin/64bit/virtuoso; \
    test -e /opt/cadence/MMSIM151/bin/spectre; \
    test -e /opt/mentor/calibre2015/aoi_cal_2015.2_36.27/bin/calibre

# Virtuoso launcher: applies VIRTUOSO_SCALE (Cadence hiSetFont via -restore),
# then execs the real Cadence virtuoso. Cadence files are not modified.
COPY scripts/virtuoso-hidpi-wrapper.sh /usr/local/bin/virtuoso
COPY scripts/virtuoso-hidpi.il /usr/local/share/virtuoso-hidpi/hidpi.il
RUN chmod 755 /usr/local/bin/virtuoso && chmod 644 /usr/local/share/virtuoso-hidpi/hidpi.il

# X11 client settings for XQuartz over TCP (OrbStack: host.docker.internal).
# XAUTHORITY points at a cookie file that run_virtuoso.sh mounts read-only.
# Qt 4 must not try MIT-SHM (shared memory does not cross the VM boundary).
# VIRTUOSO_SCALE: Virtuoso UI font scale (1.0/1.25/1.5/2.0, or "off").
ENV DISPLAY=host.docker.internal:0 \
    XAUTHORITY=/run/xauth/Xauthority \
    QT_X11_NO_MITSHM=1 \
    VIRTUOSO_SCALE=1.5

WORKDIR /workspace
CMD ["/bin/bash", "-l"]
