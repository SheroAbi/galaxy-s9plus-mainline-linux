#!/bin/bash
# Packages, users, overlay/ and services for the staged rootfs. This is the
# base system (Xfce on the framebuffer); device/s9-setup.sh then installs the
# GNOME desktop on the phone itself.
#
#   ROOT_PASSWORD, USER_PASSWORD  initial passwords (default 1234 - change them)
#   TIMEZONE                      default Etc/UTC
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../build/env.sh"
mount_build
R=$BUILD/rootfs/noble
PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[ -f "$R/.debootstrap_done" ] || { echo "stage1 not finished"; exit 1; }

cleanup() {
  rm -f "$R/usr/bin/qemu-aarch64-static"
  for m in dev/pts dev sys proc run; do umount -l "$R/$m" 2>/dev/null || true; done
}
trap cleanup EXIT
mount -t proc  proc  "$R/proc"
mount -t sysfs sysfs "$R/sys"
mount --bind /dev  "$R/dev"
mount -t devpts devpts "$R/dev/pts" 2>/dev/null || true
mount -t tmpfs tmpfs "$R/run"

# binfmt_misc may be registered without the "F" flag (or not at all) after a WSL
# restart, in which case the chroot cannot find the interpreter. Copying qemu in
# makes the chroot work either way.
cp /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
chroot "$R" /usr/bin/qemu-aarch64-static /bin/true   || { echo "aarch64 chroot still not executable"; exit 1; }
echo "aarch64 chroot works"

cp /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod +x "$R/usr/sbin/policy-rc.d"

cat > "$R/etc/apt/sources.list" <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-backports main restricted universe multiverse
EOF

chroot "$R" /usr/bin/env \
	ROOT_PASSWORD="${ROOT_PASSWORD:-1234}" USER_PASSWORD="${USER_PASSWORD:-1234}" \
	TIMEZONE="${TIMEZONE:-Etc/UTC}" \
	/bin/bash -e <<'INNER'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
# recover from a previously aborted run
dpkg --configure -a 2>&1 | tail -3 || true
apt-get -f install -y -qq 2>&1 | tail -3 || true
apt-get update -qq

# ---------- base system ----------
apt-get install -y -qq \
  systemd-sysv systemd-resolved systemd-timesyncd dbus udev kmod locales tzdata sudo \
  netplan.io network-manager wpasupplicant wireless-regdb iw rfkill iproute2 iputils-ping \
  openssh-server bluez \
  e2fsprogs parted gdisk dosfstools \
  nano vim less htop curl wget ca-certificates gnupg file tree unzip zip rsync git \
  usbutils pciutils psmisc bash-completion man-db \
  python3 python3-pip alsa-utils 2>&1 | grep -viE '^(Selecting|Preparing|Unpacking|Setting up|Processing)' | tail -15

# ---------- graphical stack (Xorg on fbdev, no GPU) ----------
apt-get install -y -qq \
  xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput \
  xserver-xorg-input-evdev xinit x11-xserver-utils xterm \
  xfce4 xfce4-terminal thunar \
  lightdm lightdm-gtk-greeter onboard \
  fonts-dejavu-core pipewire pipewire-pulse wireplumber \
  2>&1 | grep -viE '^(Selecting|Preparing|Unpacking|Setting up|Processing)' | tail -15

# ---------- identity ----------
echo "s9plus" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   s9plus
::1         localhost ip6-localhost ip6-loopback
EOF

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/${TIMEZONE:-Etc/UTC}" /etc/localtime
# Install defaults. Override with ROOT_PASSWORD= / USER_PASSWORD=; the README
# and docs/03-installing.md both say to change them on first boot.

echo "root:${ROOT_PASSWORD:-1234}" | chpasswd
useradd -m -s /bin/bash -G sudo,video,audio,input,dialout,plugdev,netdev ubuntu
echo "ubuntu:${USER_PASSWORD:-1234}" | chpasswd

# ---------- ssh ----------
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/; s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh >/dev/null 2>&1 || true

# ---------- serial console on the USB gadget ----------
systemctl enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true
grep -q ttyGS0 /etc/securetty 2>/dev/null || echo ttyGS0 >> /etc/securetty 2>/dev/null || true

# ---------- autologin into Xfce ----------
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<'EOF'
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=xfce
EOF

# high-DPI defaults for a 1440x2960 phone panel
cat > /etc/X11/Xresources.s9plus <<'EOF'
Xft.dpi: 280
Xft.antialias: true
Xft.hinting: true
Xft.hintstyle: hintslight
Xft.rgba: rgb
EOF
echo 'xrdb -merge /etc/X11/Xresources.s9plus' > /etc/X11/Xsession.d/99s9plus-dpi

# ---------- fstab ----------
cat > /etc/fstab <<'EOF'
# rootfs is mounted by the initramfs (userdata partition)
tmpfs   /tmp        tmpfs   nosuid,nodev,size=512M   0 0
tmpfs   /var/tmp    tmpfs   nosuid,nodev,size=256M   0 0
EOF

# ---------- things that make no sense on this device ----------
systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
systemctl mask  systemd-networkd-wait-online.service   >/dev/null 2>&1 || true
systemctl mask  NetworkManager-wait-online.service     >/dev/null 2>&1 || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

apt-get clean
rm -rf /var/lib/apt/lists/*
INNER

# ---------- overlay files ----------
cp -a "$PROJ/overlay/." "$R/"
find "$R/usr/local/sbin" "$R/etc/systemd/system" "$R/etc/NetworkManager" -type f -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
chmod 755 "$R/usr/local/sbin/usb-gadget"
chmod 600 "$R/etc/NetworkManager/system-connections/usb0.nmconnection"

# ---------- firmware ----------
mkdir -p "$R/lib/firmware/postmarketos"
cp "$PROJ/firmware/"* "$R/lib/firmware/postmarketos/"
ln -sf bcmdhd_sta.bin_b2 "$R/lib/firmware/postmarketos/bcmdhd_sta.bin"
ln -sf nvram.txt_r02a_b2 "$R/lib/firmware/postmarketos/nvram.txt"
ln -sf /lib/firmware/postmarketos "$R/lib/firmware/samsung-star2lte" 2>/dev/null || true

chroot "$R" systemctl enable usb-gadget.service >/dev/null 2>&1 || true
chroot "$R" systemctl enable hciattach-bcm4361.service >/dev/null 2>&1 || true

rm -f "$R/usr/sbin/policy-rc.d"
touch "$R/.stage2_done"
# du trips over vanishing /proc entries and would abort the script under set -e
du -sh "$R" 2>/dev/null || true
echo STAGE2_OK
