#!/bin/bash
# Boot a built root filesystem in an arm64 VM and check it the way a phone
# comes up on its first boot. Not the phone's kernel (that only runs on the
# phone): Ubuntu's generic arm64 kernel, its modules copied into a copy of the
# image. Units that need the phone's hardware are listed in DEVICE_UNITS and
# may fail here; nothing else may fail or restart over and over.
#
#   sudo -E scripts/ci/vm-boot-test.sh <raw disk image> <root device>
#
#   root device        vda (the image is one ext4 file system) or vdaN (a
#                      disk image with partitions)
#   IMAGE_USER, IMAGE_PASSWORD   the login the image was built with
#   HOSTNAME_EXPECTED  the image's host name
#   DEVICE_UNITS       space separated units that need the phone's hardware
#   EXPECT_ZRAM        1 (default): zram swap must be active; 0: the phone's
#                      kernel has no zram, so the image must not set it up
#
# Needs qemu-system-arm, sshpass, zstd and e2fsprogs on the host.
set -euo pipefail
IMG=$1
ROOT=$2
USER_=${IMAGE_USER:-ubuntu}
PASS=${IMAGE_PASSWORD:?}
WORK=${VM_WORK:-/mnt/vmtest}
MIRROR=http://ports.ubuntu.com/ubuntu-ports
PORT=2222
log() { printf '\n=== %s ===\n' "$*"; }

rm -rf "$WORK"; mkdir -p "$WORK/k"

log "Ubuntu generic arm64 kernel and modules"
python3 - "$MIRROR" "$WORK/k" <<'PY'
import gzip, io, lzma, subprocess, sys, tarfile, urllib.request
mirror, out = sys.argv[1], sys.argv[2]
idx = gzip.decompress(urllib.request.urlopen(
    f"{mirror}/dists/noble-updates/main/binary-arm64/Packages.gz", timeout=300).read()).decode()
pk = {}
for s in idx.split("\n\n"):
    f = dict(l.split(": ", 1) for l in s.splitlines() if ": " in l and not l.startswith(" "))
    if "Package" in f:
        pk[f["Package"]] = f
deps = [d.split()[0] for d in pk["linux-image-generic"]["Depends"].split(", ")]
image = next(d for d in deps if d.startswith("linux-image-") and d[12:13].isdigit())
ver = image[len("linux-image-"):]
# zram is in modules-extra
for name in (image, "linux-modules-" + ver, "linux-modules-extra-" + ver):
    if name not in pk:
        print(f"{name}: not in the index, skipped")
        continue
    deb = urllib.request.urlopen(f"{mirror}/{pk[name]['Filename']}", timeout=600).read()
    pos = 8
    while pos < len(deb):
        member = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58])
        body = deb[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if not member.startswith("data.tar"):
            continue
        if member.endswith(".xz"):
            body = lzma.decompress(body)
        elif member.endswith(".gz"):
            body = gzip.decompress(body)
        elif member.endswith(".zst"):
            body = subprocess.run(["zstd", "-dc"], input=body, check=True, capture_output=True).stdout
        tarfile.open(fileobj=io.BytesIO(body)).extractall(out, filter="tar")
    print(name)
open(f"{out}/version", "w").write(ver)
PY
KVER=$(cat "$WORK/k/version")
VMLINUZ=$(ls "$WORK"/k/boot/vmlinuz-*)
MODS=$WORK/k/lib/modules/$KVER
[ -d "$MODS" ] || MODS=$WORK/k/usr/lib/modules/$KVER

log "a copy of the image, 2 GiB larger, with the kernel's modules"
cp --sparse=always "$IMG" "$WORK/disk.img"
truncate -s +2G "$WORK/disk.img"
DEV=$(losetup -fP --show "$WORK/disk.img")
PART=$DEV
[ "$ROOT" = vda ] || PART=${DEV}p${ROOT#vda}
# The root file system grows on the first boot only where it fills the
# whole device; in a partition, only the phone's loop-device layout grows it.
GROW_MIN=0
if [ "$ROOT" = vda ]; then
	GROW_MIN=$(dumpe2fs -h "$PART" 2>/dev/null |
		awk -F: '/^Block count/ {c = $2} /^Block size/ {s = $2} END {print int(c * s / 1048576) + 1024}')
fi
mkdir -p "$WORK/mnt"
mount "$PART" "$WORK/mnt"
mkdir -p "$WORK/mnt/usr/lib/modules"
cp -a "$MODS" "$WORK/mnt/usr/lib/modules/"
depmod -b "$WORK/mnt" "$KVER"
# a journal on disk, readable afterwards if the VM never answers
mkdir -p "$WORK/mnt/var/log/journal"
umount "$WORK/mnt"
losetup -d "$DEV"

# Job logs need a login on GitHub, annotations do not: results go there too.
# annotate <notice|error> <file>...
annotate() {
	[ -n "${GITHUB_ACTIONS:-}" ] || return 0
	python3 - "$@" <<'PY'
import sys
kind, *files = sys.argv[1:]
lines = [l[:300] for f in files for l in open(f, errors="replace").read().splitlines() if l.strip()]
chunks, cur = [], ""
for l in lines:
    if cur and len(cur) + len(l) > 3400:
        chunks.append(cur)
        cur = ""
    cur += l + "\n"
chunks.append(cur)
for i, c in enumerate(chunks[-4:], 1):
    c = c.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::{kind} title=First boot in a VM ({i})::{c}")
PY
}

# postmortem <reason>: stop the VM and read its journal from the disk
postmortem() {
	local P=$WORK/postmortem.txt d p
	set +e
	{
		echo "$1"
		kill $QEMU 2>/dev/null; wait $QEMU 2>/dev/null
		d=$(losetup -fP --show "$WORK/disk.img"); p=$d
		[ "$ROOT" = vda ] || p=${d}p${ROOT#vda}
		mount -o ro,noload "$p" "$WORK/mnt"
		J="journalctl -D $WORK/mnt/var/log/journal --no-pager -o short-monotonic"
		echo "--- failed units and errors"
		$J -p err | grep -v ' kernel: ' | tail -n 30
		echo "--- network and SSH"
		$J -u NetworkManager.service -u ssh.socket -u ssh.service -u first-boot-ssh-keys.service | tail -n 30
		umount "$WORK/mnt"; losetup -d "$d"
		echo "--- console"
		tail -n 15 "$WORK/console.log" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
	} > "$P" 2>&1
	cat "$P"
	annotate error "$P"
	exit 1
}

log "boot $KVER (TCG, multi-user target)"
# romfile=: the NIC's boot ROM is only for firmware network boot, and its
# package (ipxe-qemu) is only a recommendation of qemu-system-arm.
qemu-system-aarch64 -M virt -cpu max,pauth-impdef=on -smp 4 -m 4096 \
	-kernel "$VMLINUZ" \
	-append "root=/dev/$ROOT rootwait rw console=ttyAMA0 systemd.unit=multi-user.target" \
	-drive file="$WORK/disk.img",if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0,romfile= \
	-serial file:"$WORK/console.log" -monitor none -display none &
QEMU=$!
trap 'kill $QEMU 2>/dev/null || true' EXIT

ssh_vm() {
	sshpass -p "$PASS" ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 -o LogLevel=ERROR "$USER_@127.0.0.1" "$@"
}
sudo_vm() { ssh_vm "echo '$PASS' | sudo -S -p '' $1"; }
for i in $(seq 1 120); do
	if ssh_vm true 2>/dev/null; then echo "SSH login after ~$((i * 10)) s"; break; fi
	kill -0 $QEMU 2>/dev/null || postmortem "VM stopped"
	[ "$i" = 120 ] && postmortem "no SSH login after 20 min: $(ssh_vm true 2>&1 | tail -n 2)"
	sleep 10
done

log "boot finished?"
echo "system state: $(ssh_vm 'timeout 900 systemctl is-system-running --wait' || true)"
# Timers that fire shortly after boot, and services that keep restarting,
# need a little time to show.
ssh_vm 'w=$((150 - $(cut -d. -f1 /proc/uptime))); [ $w -le 0 ] || sleep $w'

log "inside the VM"
sudo_vm "sh -c 'echo \"host: \$(hostname)   kernel: \$(uname -r)   default target: \$(systemctl get-default)\"
	df -h /; echo; swapon --show; echo; systemd-analyze || true; echo
	systemctl --failed --no-pager --plain; echo
	journalctl -b -p err --no-pager | tail -n 40'" > "$WORK/summary.txt" 2>&1 || true
cat "$WORK/summary.txt"

# The checks that need root run inside the VM.
cat > "$WORK/vmcheck.sh" <<'CHECK'
#!/bin/bash
# <expect zram 0|1> <host name> <minimum root size in MiB, 0 = not checked> <device units...>
set -u
EXPECT_ZRAM=$1 HOST=$2 GROW_MIN=$3
shift 3
DEVICE=" $* "
fail=0
check() {
	local what=$1; shift
	if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; fail=1; fi
}
device_unit() { case "$DEVICE" in *" $1 "*) return 0 ;; esac; return 1; }

check "own SSH host keys made on first boot" test -s /etc/ssh/ssh_host_ed25519_key.pub
check "grow-rootfs ran" test "$(systemctl show -p Result --value grow-rootfs.service)" = success -a \
	-f /var/lib/grow-rootfs.done
if [ "$GROW_MIN" -gt 0 ]; then
	size=$(df --output=size -BM / | tail -1 | tr -dc 0-9)
	check "root file system grew to its device ($size MiB, at least $GROW_MIN)" test "$size" -ge "$GROW_MIN"
fi
check "graphical target is the default" test "$(systemctl get-default)" = graphical.target
if [ "$EXPECT_ZRAM" = 1 ]; then
	check "zram swap active" grep -q '^/dev/zram' /proc/swaps
else
	check "no zram swap set up (the phone's kernel has no zram)" test -z \
		"$(grep zram /proc/swaps; systemctl list-units --all --no-legend --plain 'dev-zram*' 'systemd-zram-setup@*')"
fi
[ -z "$HOST" ] || check "host name $HOST" test "$(hostname)" = "$HOST"

unexpected=
for u in $(systemctl --failed --no-legend --plain | awk '{print $1}'); do
	if device_unit "$u"; then echo "info  $u failed (needs the phone's hardware)"; else unexpected="$unexpected $u"; fi
done
check "no failed units besides the hardware ones${unexpected:+:$unexpected}" test -z "$unexpected"

loops=
for u in $(systemctl list-units --type=service --all --no-legend --plain | awk '{print $1}'); do
	n=$(systemctl show -p NRestarts --value "$u" 2>/dev/null)
	[ "${n:-0}" -ge 3 ] 2>/dev/null || continue
	if device_unit "$u"; then echo "info  $u restarted $n times (needs the phone's hardware)"; else loops="$loops $u($n)"; fi
done
check "no service restarting over and over${loops:+:$loops}" test -z "$loops"

# The image's own unit files (and units it adds drop-ins to): no unknown
# settings, no missing programs, no missing units they depend on.
units=$({
	find /etc/systemd/system /usr/local/lib/systemd/system -maxdepth 1 -type f -printf '%f\n' 2>/dev/null
	for d in /etc/systemd/system/*.d; do [ -d "$d" ] && basename "$d" .d; done
} | grep -E '\.(service|timer|socket|mount|path)$' | grep -v '@\.' | sort -u)
broken=
for u in $units; do
	out=$(systemd-analyze verify "$u" 2>&1 |
		grep -E "Unknown (key|section)|Failed to parse|not executable|bad unit file|Invalid|Missing '='|not found" |
		grep -F -e "$u" -e /etc/systemd -e /usr/local || true)
	[ -z "$out" ] || { echo "$out" | sed 's/^/      /'; broken="$broken $u"; }
done
echo "info  verified:" $units
check "the image's own unit files are valid${broken:+:$broken}" test -z "$broken"
exit $fail
CHECK

log "checks"
fail=0
C=$WORK/checks.txt
ssh_vm 'cat > /tmp/vmcheck.sh' < "$WORK/vmcheck.sh"
sudo_vm "bash /tmp/vmcheck.sh '${EXPECT_ZRAM:-1}' '${HOSTNAME_EXPECTED:-}' '$GROW_MIN' ${DEVICE_UNITS:-}" \
	> "$C" 2>&1 || fail=1
if sudo_vm true; then echo "ok    sudo with the image password" >> "$C"; else
	echo "FAIL  sudo with the image password" >> "$C"; fail=1; fi
if sshpass -p "$PASS" ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=10 -o LogLevel=ERROR root@127.0.0.1 true 2>/dev/null; then
	echo "FAIL  root cannot log in over SSH" >> "$C"; fail=1
else
	echo "ok    root cannot log in over SSH" >> "$C"
fi
cat "$C"

kind=notice; [ $fail = 0 ] || kind=error
annotate $kind "$WORK/summary.txt" "$C"

sudo_vm 'systemctl poweroff' 2>/dev/null || true
for i in $(seq 1 30); do kill -0 $QEMU 2>/dev/null || break; sleep 2; done
exit $fail
