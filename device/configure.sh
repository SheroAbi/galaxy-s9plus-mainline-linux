#!/bin/bash
# Galaxy S9+: hardware configuration, run inside the image during the build
# (image/build-image.sh). Only what this phone needs to work; the optional
# features are in extras/.
set -euo pipefail

chmod 600 /etc/NetworkManager/system-connections/usb0.nmconnection

# USB serial console and network, touch/charger power fix, the stability
# defaults, Wi-Fi reconnect after a failed rekey, Bluetooth attach.
systemctl enable usb-gadget.service s9p-touch-power.service s9p-stability.service \
	s9p-wifi-guard.service hciattach-bcm4361.service serial-getty@ttyGS0.service

# Suspend never resumes on this port (the M3 cores do not come back).
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
	suspend-then-hibernate.target

# Mesa's AFBC repacking corrupts textures on this Mali-G72 (16-pixel dashes
# in icons and text). /etc/environment is what reaches gnome-shell.
grep -q '^PAN_MAX_AFBC_PACKING_RATIO=' /etc/environment ||
	echo 'PAN_MAX_AFBC_PACKING_RATIO=0' >> /etc/environment

cat > /etc/fstab <<'FSTAB'
# The initramfs mounts USERDATA (/dev/sda25) as the root filesystem.
LABEL=s9plus-root  /  ext4  defaults,noatime  0 0
FSTAB

dconf update
