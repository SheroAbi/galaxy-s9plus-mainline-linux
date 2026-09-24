# Installing

## What has to be true first

1. **Bootloader unlocked** and `KG STATE: Normal` in download mode.
2. **TWRP 3.3.1-0 for star2lte on `RECOVERY`.**
3. `adb` on the host (Android platform-tools). The flash scripts find the S9+
   by its product name; with more than one on the bus, set `S9PLUS_SERIAL`.

### KG STATE: Prenormal blocks everything

In that state the bootloader accepts an Odin session and then refuses every
partition operation. Two independent tools fail at exactly the same point, so
it is not a tool bug:

| Tool | gets to | fails with |
|---|---|---|
| Thor 1.1.0 | `Successfully began an Odin session!` | `flashTar` → `Failed to bulk read: Connection timed out (110)` |
| Heimdall 1.4.2 | `Session begun.` | `ERROR: Failed to receive PIT file size!` |

`OEM LOCK: OFF` only means the developer-options switch is set. What matters
is `KG STATE`.

**How it was cleared on this device:** boot Android, correct the device clock,
give it internet (USB tethering works), and leave it online. Knox Guard went
to `Checking` and the bootloader started accepting writes. The seven days
Samsung nominally wants were not needed.

## Flashing

Everything after the initial TWRP install goes over **TWRP + adb**, not Odin.

```bash
# kernel only: the uniLoader-wrapped image (a raw m71-*/boot.img does not boot)
python scripts/flash/flash_s9plus_boot_adb.py dist/uniloader/<image>.img

# the Ubuntu rootfs (raw ext4 image, resumable, every chunk checked)
python scripts/flash/flash_s9plus_rootfs_adb.py <path>/ubuntu-rootfs.img
```

> TWRP's `adbd` accepts `exec-in` but **discards the stream**. The rootfs
> therefore goes over `adb push` in 128 MiB chunks into `/tmp` and is written
> with `dd seek=`, each chunk compared against the partition first. That makes
> the whole run idempotent and resumable — which matters, because the Windows
> adb server reliably drops out during long transfers.

Target partitions: `BOOT` = `/dev/block/sda10`, `USERDATA` = `/dev/block/sda25`.

### Odin, if you ever need it

`TWRP_IMG=<twrp image> scripts/image/mk_twrp_tar.sh` builds the smallest
possible Odin package: TWRP for `RECOVERY` only. That is the one write that matters, because sboot
keeps the recovery flag it was once given.

Odin-path traps that cost time:

* The device gives **one Odin handshake per download-mode entry**. Every test
  run uses it up; after that only a power cycle helps.
* `Thor-Windows.exe` cannot flash at all ("A USB handler wasn't written for
  your platform") — only the Linux binary can, over `usbipd-win`.
* Thor needs a real pty **with the window size set**, or Spectre.Console wraps
  after every single character.
* Blacklist `cdc_acm`; unloading it mid-session tears down the usbip link.
* Longer USB timeouts do **not** fix the PIT problem.

## First boot

* GDM logs `ubuntu` in automatically, Wayland session.
* Accounts: `ubuntu` / `1234`, root `1234` — **change them.**
* Over USB the phone is `172.16.42.1` and serves DHCP to the host:
  `ssh ubuntu@172.16.42.1`.
* A `getty` runs on `ttyGS0`, so the same cable also gives a serial console on
  a host COM port.

## Device-side configuration

`device/rootfs/` is the part of the Ubuntu install that belongs to this port.
Copy it over the rootfs and enable the units you want with `systemctl enable`
(`s9p-touch-power.service` is the one every install needs).

`device/s9-setup.sh` is the one-shot provisioning run that joins Wi-Fi, sets
the clock and installs the GNOME desktop with GDM on Wayland. It takes the
network credentials from the environment, never from the file:

    WIFI_SSID='my-network' WIFI_PSK='...' ./s9-setup.sh

`WIFI_HIDDEN` defaults to `yes`. Follow `/root/s9-setup.log`, not the serial
console — the script detaches.

| | |
|---|---|
| `usr/local/sbin/s9p-touch-power` | lifts the charger input limit from 375 mA (what TWRP leaves) to 500 mA. The touch rails (LDO35/LDO43) and BUCK6 for the GPU are set by the kernel now (`s9p-acpm`, `s9p-g3d`) |
| `usr/local/sbin/s9p-acpm` | speaks the ACPM mailbox protocol from userspace (`read`/`write`/`update`/`tsp`) |
| `usr/local/sbin/s9p-cpuclk` | sets the vendor clock maxima |
| `usr/local/sbin/s9p-governor` | userspace GPU steps and thermal CPU caps (from before the in-kernel drivers; optional) |
| `usr/local/sbin/s9p-wlan` | brings the BCM4361 up |
| `etc/gdm3/custom.conf` | `WaylandEnable=true` plus autologin |
| `etc/systemd/system.conf.d/s9p-watchdog.conf` | `RuntimeWatchdogSec=30s`, `RebootWatchdogSec=2min` |

Two userland settings that are easy to get wrong:

* **`PAN_MAX_AFBC_PACKING_RATIO=0` must be in `/etc/environment`** (`s9-setup.sh` adds it). Without it
  icons and glyphs show 16-pixel horizontal dashes. `/etc/environment.d/` does
  **not** reach `gnome-shell`; `/etc/environment` (pam_env) does.
* **`LIBGL_ALWAYS_SOFTWARE=1` must not be anywhere** (`/etc/environment`,
  `gdm3.service.d`) or every client silently gets llvmpipe. The `ubuntu` user
  must be in the `render` group.

> When you change either and want to measure the result, run
> `loginctl terminate-user ubuntu` before restarting GDM. The `systemd --user`
> manager keeps its environment across `systemctl restart gdm`, and a stale
> value has survived three measurements that way.

## If it does not come up

1. **Black, no USB** → wrong DTB or a kernel panic. Download mode is in ROM,
   not in `boot`, so it is still reachable. Flash a known-good `boot.img`
   back, or reach TWRP with Power + VolUp + Bixby.
2. **Boot log on the panel, then nothing** → read the ramoops window from
   TWRP; the kernel's console zone is at `0x4000` of `0x8000@0xfed10000` and
   TWRP shows it as `pmsg-ramoops-0`. Read the **end** of it.
3. **Serial console, rescue shell** → kernel is fine, the rootfs is missing or
   broken. Reflash `userdata.img`.

The kernel's init arms Samsung's recovery magic in the PMU before it does
anything else (`INFORM2 = 0x12345678`, `INFORM3 = 0x12345674`), so a panic,
the init's own deadman timer, or any later reset comes up **in TWRP** rather
than in the same kernel again.

> The inverse layout — TWRP on `BOOT`, the test kernel on `RECOVERY` — looks
> safer and is not: the recovery key combo then lands in the *test* kernel,
> which is exactly what someone reaches for when the phone looks dead.
