#!/bin/bash
# One-shot provisioning run on the phone itself: network, then GNOME.
# Started detached; follow /root/s9-setup.log instead of the serial console.
exec 2>&1
set -u
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
# Wi-Fi credentials come from the environment, never from this file.
#   WIFI_SSID=... WIFI_PSK=... ./s9-setup.sh
: "${WIFI_SSID:?set WIFI_SSID}"
: "${WIFI_PSK:?set WIFI_PSK}"
: "${WIFI_HIDDEN:=yes}"

step() { echo "=== [$(date -u +%H:%M:%S)] $* ==="; }

step "wifi"
nmcli radio wifi on || true
for attempt in 1 2 3; do
	nmcli --wait 45 device wifi connect "$WIFI_SSID" password "$WIFI_PSK" ifname wlan0 hidden "$WIFI_HIDDEN" && break
	echo "attempt $attempt failed, rescanning"
	nmcli device wifi rescan ifname wlan0 || true
	sleep 8
done
nmcli -t -f NAME,DEVICE,STATE connection show --active
ip -4 -br addr

step "clock"
timedatectl set-ntp true || true
for _ in $(seq 20); do
	timedatectl show -p NTPSynchronized --value | grep -q yes && break
	sleep 3
done
date -u

step "connectivity"
ok=no
for _ in $(seq 20); do
	if getent hosts ports.ubuntu.com >/dev/null 2>&1; then ok=yes; break; fi
	sleep 5
done
echo "dns=$ok"
[ "$ok" = yes ] || { echo "NO INTERNET -- stopping"; exit 1; }

step "ssh"
systemctl enable --now ssh
ip -4 -br addr show wlan0

step "apt update"
apt-get update

step "install GNOME"
# Ubuntu's own GNOME, but without ubuntu-desktop: that pulls snapd, and snaps
# need squashfs, which this kernel does not enable.
apt-get install -y --no-install-recommends \
	gnome-shell gnome-session gdm3 gnome-control-center gnome-terminal \
	nautilus gnome-text-editor gnome-system-monitor gnome-tweaks \
	gnome-shell-extension-prefs xdg-desktop-portal-gnome \
	yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound \
	adwaita-icon-theme fonts-ubuntu gnome-backgrounds \
	mesa-utils libgl1-mesa-dri xserver-xorg-core dbus-x11

step "select gdm3"
echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections
echo /usr/sbin/gdm3 > /etc/X11/default-display-manager
systemctl disable lightdm 2>/dev/null || true
systemctl enable gdm3
systemctl set-default graphical.target

step "gdm: Wayland with autologin"
# The mainline kernel has a KMS device (s9p-decon) and Panfrost, so GNOME runs
# on Wayland. device/rootfs/etc/gdm3/custom.conf holds the settings.
if [ -f "$(dirname "$0")/rootfs/etc/gdm3/custom.conf" ]; then
	install -D -m 644 "$(dirname "$0")/rootfs/etc/gdm3/custom.conf" /etc/gdm3/custom.conf
fi
cat /etc/gdm3/custom.conf 2>/dev/null

step "mesa and render access"
# Mesa's AFBC repacking corrupts textures on this Mali-G72 (16-pixel dashes in
# icons and text); /etc/environment is what reaches gnome-shell. And the
# desktop user needs the render node, or every client falls back to llvmpipe.
grep -q '^PAN_MAX_AFBC_PACKING_RATIO=' /etc/environment || \
	echo 'PAN_MAX_AFBC_PACKING_RATIO=0' >> /etc/environment
usermod -aG render ubuntu || true

step "input devices"
grep -E 'Name=|Handlers=' /proc/bus/input/devices | paste - - | head -20
udevadm info -q property -n /dev/input/event0 2>/dev/null | grep -i 'ID_INPUT' || true

step "done"
echo S9_SETUP_COMPLETE
