# Shared image-building functions. This file is identical in the three phone
# repositories (Galaxy S9+, Mi 9T, Redmi 8), so every phone gets the same
# clean Ubuntu 24.04. Sourced by image/build-image.sh; not meant to be run.
#
# Settings, all from the environment:
#   IMAGE_USER       login name                       (default: ubuntu)
#   IMAGE_PASSWORD   its password, at least 8 chars   (asked for if unset)
#   IMAGE_HOSTNAME   host name                        (default: the device)
#   IMAGE_TIMEZONE   e.g. Europe/Berlin               (default: Etc/UTC)
#   IMAGE_LOCALE     e.g. de_DE.UTF-8                 (default: en_US.UTF-8)
#   IMAGE_KEYMAP     keyboard layout, e.g. de         (default: us)
#   SSH_PUBKEY       a public key file; if set, SSH accepts only keys
#   UBUNTU_MIRROR    default http://ports.ubuntu.com/ubuntu-ports

COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UBUNTU_SUITE=noble
UBUNTU_MIRROR=${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}

log() { printf '\n=== %s ===\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# require_host [extra tools...]
require_host() {
	[ "$(id -u)" = 0 ] || die "run as root (debootstrap, chroot and loop files need it)"
	local t
	for t in debootstrap mke2fs e2fsck openssl sha256sum "$@"; do
		command -v "$t" >/dev/null || die "missing host tool: $t (see docs, 'Build host')"
	done
	if [ "$(uname -m)" != aarch64 ] && [ ! -x /usr/bin/qemu-aarch64-static ]; then
		die "missing /usr/bin/qemu-aarch64-static (package qemu-user-static)"
	fi
}

# image_settings <default hostname>
image_settings() {
	IMAGE_USER=${IMAGE_USER:-ubuntu}
	IMAGE_HOSTNAME=${IMAGE_HOSTNAME:-$1}
	IMAGE_TIMEZONE=${IMAGE_TIMEZONE:-Etc/UTC}
	IMAGE_LOCALE=${IMAGE_LOCALE:-en_US.UTF-8}
	IMAGE_KEYMAP=${IMAGE_KEYMAP:-us}
	case "$IMAGE_USER" in root|"") die "IMAGE_USER must be a normal user name" ;; esac
	if [ -z "${IMAGE_PASSWORD:-}" ]; then
		[ -t 0 ] || die "set IMAGE_PASSWORD, or run the build in a terminal to be asked"
		local a b
		read -rsp "Password for '$IMAGE_USER' on the phone: " a; echo
		read -rsp "Repeat: " b; echo
		[ "$a" = "$b" ] || die "the passwords differ"
		IMAGE_PASSWORD=$a
	fi
	[ "${#IMAGE_PASSWORD}" -ge 8 ] || die "use a password of at least 8 characters"
	IMAGE_PASSWORD_HASH=$(printf '%s\n' "$IMAGE_PASSWORD" | openssl passwd -6 -stdin)
	unset IMAGE_PASSWORD
	IMAGE_SSH_KEY=
	if [ -n "${SSH_PUBKEY:-}" ]; then
		IMAGE_SSH_KEY=$(head -n1 "$SSH_PUBKEY")
		case "$IMAGE_SSH_KEY" in
		ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com\ *) ;;
		*) die "$SSH_PUBKEY does not look like an SSH public key" ;;
		esac
	fi
}

# copy_tree <src dir> <dst dir>: modes as in the repository, owner root.
copy_tree() {
	tar -C "$1" --owner=0 --group=0 --numeric-owner -cf - . | tar -C "$2" -xpf -
}

_mounts=()
chroot_mount() {
	local R=$1 m
	for m in proc sys dev dev/pts run; do mkdir -p "$R/$m"; done
	mount -t proc proc "$R/proc"
	mount -t sysfs sysfs "$R/sys"
	mount --bind /dev "$R/dev"
	mount -t devpts devpts "$R/dev/pts"
	mount -t tmpfs tmpfs "$R/run"
	_mounts=("$R/run" "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc")
}

chroot_umount() {
	local m
	for m in "${_mounts[@]}"; do umount -l "$m" 2>/dev/null || true; done
	_mounts=()
}

in_chroot() {
	local R=$1; shift
	chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
		HOME=/root LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@"
}

# rootfs_bootstrap <dir>: a fresh Ubuntu 24.04 arm64 minbase.
rootfs_bootstrap() {
	local R=$1
	log "debootstrap $UBUNTU_SUITE arm64 into $R"
	# A build that died with /dev or /proc still bind-mounted inside must
	# never be cleaned up blindly: that would delete the host's device nodes.
	if grep -q " $(realpath -m "$R")/" /proc/mounts; then
		die "something is still mounted under $R - unmount it first"
	fi
	rm -rf --one-file-system "$R"
	mkdir -p "$R"
	if [ "$(uname -m)" = aarch64 ]; then
		debootstrap --arch=arm64 --variant=minbase --include=ca-certificates "$UBUNTU_SUITE" "$R" "$UBUNTU_MIRROR"
	else
		debootstrap --arch=arm64 --variant=minbase --include=ca-certificates --foreign "$UBUNTU_SUITE" "$R" "$UBUNTU_MIRROR"
		# binfmt_misc may be registered without the F flag; with qemu inside
		# the tree the chroot works either way.
		cp /usr/bin/qemu-aarch64-static "$R/usr/bin/"
		chroot "$R" /debootstrap/debootstrap --second-stage
	fi
}

# rootfs_install <dir> <device packages.txt>
rootfs_install() {
	local R=$1 devpkgs=$2 pkgs
	log "packages"
	rm -f "$R/etc/apt/sources.list"
	cat > "$R/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $UBUNTU_MIRROR
Suites: $UBUNTU_SUITE $UBUNTU_SUITE-updates $UBUNTU_SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
	copy_tree "$COMMON_DIR/rootfs" "$R"
	cp /etc/resolv.conf "$R/etc/resolv.conf.build"
	rm -f "$R/etc/resolv.conf"
	cp "$R/etc/resolv.conf.build" "$R/etc/resolv.conf"
	printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
	chmod 755 "$R/usr/sbin/policy-rc.d"
	pkgs=$(cat "$COMMON_DIR/packages.txt" "$devpkgs" | sed 's/#.*//' | tr -s ' \t\n' ' ')
	in_chroot "$R" apt-get update
	in_chroot "$R" apt-get -y --no-install-recommends install $pkgs
	in_chroot "$R" apt-get -y --no-install-recommends full-upgrade
}

# rootfs_configure <dir>: the settings every phone shares.
rootfs_configure() {
	local R=$1
	log "common configuration"
	sed -i "s/^# *\($IMAGE_LOCALE\)/\1/" "$R/etc/locale.gen"
	grep -q "^$IMAGE_LOCALE" "$R/etc/locale.gen" || echo "$IMAGE_LOCALE UTF-8" >> "$R/etc/locale.gen"
	in_chroot "$R" locale-gen
	echo "LANG=$IMAGE_LOCALE" > "$R/etc/default/locale"
	ln -sf "/usr/share/zoneinfo/$IMAGE_TIMEZONE" "$R/etc/localtime"
	echo "$IMAGE_TIMEZONE" > "$R/etc/timezone"
	cat > "$R/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$IMAGE_KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
	echo "$IMAGE_HOSTNAME" > "$R/etc/hostname"
	cat > "$R/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$IMAGE_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
EOF

	# One user with sudo, root locked. The password was hashed on the host.
	local g groups=
	for g in sudo adm video render audio input plugdev netdev dialout; do
		in_chroot "$R" getent group "$g" >/dev/null && groups="$groups${groups:+,}$g"
	done
	in_chroot "$R" useradd -m -s /bin/bash -G "$groups" "$IMAGE_USER"
	in_chroot "$R" usermod -p "$IMAGE_PASSWORD_HASH" "$IMAGE_USER"
	in_chroot "$R" passwd -l root

	# A phone has no keyboard at the login screen: log the user in, like the
	# reference phones do. The password still guards sudo, SSH and the lock screen.
	mkdir -p "$R/etc/gdm3"
	cat > "$R/etc/gdm3/custom.conf" <<EOF
[daemon]
WaylandEnable=true
AutomaticLoginEnable=true
AutomaticLogin=$IMAGE_USER
EOF

	if [ -n "$IMAGE_SSH_KEY" ]; then
		install -d -m 700 "$R/home/$IMAGE_USER/.ssh"
		printf '%s\n' "$IMAGE_SSH_KEY" > "$R/home/$IMAGE_USER/.ssh/authorized_keys"
		chmod 600 "$R/home/$IMAGE_USER/.ssh/authorized_keys"
		in_chroot "$R" chown -R "$IMAGE_USER:$IMAGE_USER" "/home/$IMAGE_USER/.ssh"
		printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
			> "$R/etc/ssh/sshd_config.d/20-keys-only.conf"
	fi

	# ssh.socket (Ubuntu's default) starts sshd on the first connection.
	in_chroot "$R" systemctl enable first-boot-ssh-keys.service grow-rootfs.service \
		NetworkManager.service ssh.socket gdm.service
	mkdir -p "$R/etc/X11"
	echo /usr/sbin/gdm3 > "$R/etc/X11/default-display-manager"
	in_chroot "$R" systemctl set-default graphical.target
	in_chroot "$R" dconf update
}

# rootfs_device <dir> <device base dir> <device configure.sh>
rootfs_device() {
	local R=$1 base=$2 script=$3
	log "device layer"
	copy_tree "$base" "$R"
	install -m 755 "$script" "$R/tmp/device-configure.sh"
	in_chroot "$R" env IMAGE_USER="$IMAGE_USER" /bin/bash /tmp/device-configure.sh
	rm -f "$R/tmp/device-configure.sh"
}

# rootfs_finish <dir>: nothing of the build machine and nothing shared
# between images stays behind.
rootfs_finish() {
	local R=$1
	log "clean up"
	in_chroot "$R" apt-get -y autoremove --purge
	in_chroot "$R" apt-get clean
	rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/*.bin
	# SSH host keys are made on the phone's first boot, never shared.
	rm -f "$R"/etc/ssh/ssh_host_*
	# A new machine-id on the first boot.
	: > "$R/etc/machine-id"
	rm -f "$R/var/lib/dbus/machine-id"
	rm -f "$R/usr/sbin/policy-rc.d" "$R/usr/bin/qemu-aarch64-static" "$R/etc/resolv.conf.build"
	ln -sf ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
	rm -rf "$R"/tmp/* "$R"/var/tmp/* "$R"/root/.bash_history "$R"/var/log/*.log \
		"$R"/var/log/apt/* "$R"/var/cache/debconf/*-old
	find "$R/var/log" -type f -name '*.gz' -delete
}

# make_ext4 <dir> <image> <label> [uuid] [extra MiB]
make_ext4() {
	local R=$1 img=$2 label=$3 uuid=${4:-$(cat /proc/sys/kernel/random/uuid)} extra=${5:-1024}
	local used size files
	log "ext4 image $img"
	used=$(du -sxm "$R" | cut -f1)
	files=$(find "$R" -xdev | wc -l)
	size=$(( (used * 120 / 100 + extra + 63) / 64 * 64 ))
	mkdir -p "$(dirname "$img")"
	rm -f "$img"
	mke2fs -q -F -t ext4 -b 4096 -O ^orphan_file,^metadata_csum_seed -m 1 \
		-N $((files * 3 / 2 + 65536)) -L "$label" -U "$uuid" -d "$R" "$img" "${size}M"
	e2fsck -fn "$img" >/dev/null
	echo "$img: ${size} MiB, ${used} MiB used, UUID $uuid"
}

# sparse_image <raw> <sparse>: Android sparse v1.0 with explicit zero-fill
# chunks, so the flashed partition matches the image byte for byte.
sparse_image() {
	python3 - "$1" "$2" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
BS = 4096
ZERO = bytes(BS)
chunks = []
with open(src, 'rb') as f:
    f.seek(0, 2); size = f.tell(); f.seek(0)
    assert size % BS == 0, 'image size is not a multiple of 4096'
    total = size // BS
    kind = None; start = 0; n = 0
    for i in range(total):
        k = 'Z' if f.read(BS) == ZERO else 'R'
        if k != kind:
            if kind:
                chunks.append((kind, n, start))
            kind, start, n = k, i, 0
        n += 1
    chunks.append((kind, n, start))
with open(src, 'rb') as f, open(dst, 'wb') as out:
    out.write(struct.pack('<IHHHHIIII', 0xed26ff3a, 1, 0, 28, 12, BS, total, len(chunks), 0))
    for kind, n, start in chunks:
        if kind == 'R':
            out.write(struct.pack('<HHII', 0xCAC1, 0, n, 12 + n * BS))
            f.seek(start * BS)
            left = n * BS
            while left:
                buf = f.read(min(left, 8 << 20)); out.write(buf); left -= len(buf)
        else:
            out.write(struct.pack('<HHII', 0xCAC2, 0, n, 16))
            out.write(struct.pack('<I', 0))
print('%s: %d blocks, %d chunks' % (dst, total, len(chunks)))
PY
}

# checksums <dir>
checksums() {
	(cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf "%f\0" | sort -z | xargs -0 sha256sum -- > SHA256SUMS && cat SHA256SUMS)
}
