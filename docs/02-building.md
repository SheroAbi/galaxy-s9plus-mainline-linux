# Building

## Build host

Any Linux with an aarch64 cross toolchain, run as root (the scripts mount
loop images and chroot). The reference setup is **WSL Ubuntu-24.04** on
Windows, and every build script is written so it can be started with one
`wsl.exe` call.

The kernel tree does not live in the project folder. `scripts/build/env.sh`
defines where it does, and every value can be overridden:

```
BUILD_IMG=/mnt/e/s9plus-build.img   70 GB ext4 loop image (default), mounted at
BUILD=/mnt/build
  $BUILD/src/mainline               the mainline 7.1 tree
  $BUILD/out                        initramfs staging, busybox, empty ramdisk
  $BUILD/tools/bin                  mkbootimg, dtbTool-exynos
  $BUILD/rootfs/noble               the staged Ubuntu rootfs
```

On WSL the loop image is needed because a kernel tree on a 9p/DrvFs mount is
unusably slow and cannot hold the symlinks and permissions the build needs.
On a plain Linux host, `BUILD=/some/directory` is enough.

Three inputs are not fetched by the scripts: a static arm64 **busybox** at
`$BUILD/out/busybox-arm64` (the initramfs), and **mkbootimg** and
**dtbTool-exynos** in `$BUILD/tools/bin`.

> WSL unmounts the loop image between `wsl.exe` invocations, and anything
> still in the page cache is lost with it. Every script therefore mounts it
> itself and ends with `sync`. A finished `Image` that was 54 MB before the
> call has come back as 0 bytes without that.

### One-time setup

```bash
scripts/build/setup_build.sh    # create and mount the build image (BUILD_IMG)
scripts/build/toolchain.sh      # gcc-aarch64-linux-gnu, bison, flex, cpio, qemu-user-static, ...
scripts/build/fetch_mainline.sh # clone the mainline tree into /mnt/build/src/mainline
```

## The build

```bash
scripts/build/build_stable.sh
```

That is the configuration the device runs: `INIT=boot UFS=1 GPU=1 DECON=1
WLAN=1 GADGET=configfs`, the boot command line with the watchdog armed, no
Tux logo, no plymouth. It calls `build71.sh` and prints `BUILD EXIT 0` when
the image is ready.

Output lands in `dist/m71-<UTC timestamp>/`:

| File | |
|---|---|
| `boot.img` | the flashable Samsung boot image (`SEANDROIDENFORCE` appended) |
| `Image`, `vmlinux`, `System.map` | the kernel |
| `dt.img` | the DTBH table sboot expects |
| `exynos9810-star2lte.dts/.dtb` | the device tree as it was actually built |
| `kernel.config` | the full config |
| `kernel-source.patch` | the in-tree patches this build applied |
| `port-sources/` | the generated sources archived with the build |
| `SHA256SUMS` | |

Build logs go to `build-logs/build71-<stamp>.log`.

## build71.sh in detail

`build71.sh` is the end-to-end build: device tree, config, initramfs, kernel,
boot image. It reads everything it needs out of the project folder and locates
that folder from its own path, so the project can be moved without editing
anything.

### Switches

All of them are environment variables.

| | |
|---|---|
| `UFS=1` | enable the UFS node. Off by default: reading an unpowered block is a bus hang, not an error |
| `GPU=1` | enable the Mali node, same reasoning |
| `DECON=1` | let the DECON scanout driver take the display over from the bootloader framebuffer |
| `WLAN=1` | build `brcmfmac` in and embed the BCM4361 firmware and the regulatory database |
| `GADGET=configfs` | USB configfs gadget: ACM console plus NCM network |
| `INIT=boot` | build the image that hands over to Ubuntu on `USERDATA`. Without it you get the probe image, which reports and then panics on purpose |
| `NOFB=1` | drop the bootloader framebuffer node, for bisecting the display stack |
| `FRESH_CONFIG=1` | start from `defconfig` again |
| `POKE=ufs,gpu` | let the probe image read those blocks' registers directly |
| `BOOT_CMDLINE=...` | replace the kernel command line |
| `DIST=...` | write the build somewhere other than `dist/` |

### What it does, in order

1. Copies `src/mainline-dts/exynos9810-star2lte.dts` into the tree and applies
   the `*-STATUS` switches above.
2. Registers the board in `arch/arm64/boot/dts/exynos/Makefile` if it is not
   there yet.
3. `purge_fbband.py` removes the early colour bands (a debugging aid that is
   only stripes across the boot logo on a working device).
4. `apply_drivers.sh` installs every driver from `src/` into the tree and runs
   `patch_tree.py` for the in-tree edits.
5. Builds the initramfs from a static busybox plus `device/mainline-init*`.
6. Configures, builds `Image` and `dtbs`, and modules if any are `=m`.
7. **Writes `0x00080000` back into the arm64 image header's `text_offset`.**
   See below.
8. Packs `dt.img` with `dtbTool-exynos` and the boot image with `mkbootimg`,
   then appends `SEANDROIDENFORCE`.

### text_offset — why a mainline kernel does nothing at all here

| | Samsung 4.9 | mainline 7.1 |
|---|---|---|
| `text_offset` (image header byte 0x08) | `0x00080000` | `0` |

Mainline has set that field to 0 since 5.8, because the kernel relocates
itself. sboot on this phone is from 2018 and still places the image by it, so
a mainline kernel lands at `0x80000000` instead of `0x80080000` — and the
bootloader's own log says what lives there:

```
sec_debug_magic   reg = <0x0 0x80000000 0x1000>
kaslr_region=0x1000@0x80001000
```

The bootloader writes its own structures over the first 8 KB of the kernel
before jumping to it. The result is a kernel that dies silently: no console,
no panic, no reset, not one byte in the ramoops window.

The build writes the old value back after linking. A relocatable kernel never
reads its own header, so this costs nothing and puts the image where this
bootloader expects it.

## The uniLoader image

`build_stable.sh` produces a raw `boot.img`. The **validated** image for
running Ubuntu wraps the same kernel in uniLoader, a small shim that fixes two
things sboot gets wrong before the kernel starts — most importantly DECON's
`HW_SW_TRIG_CONTROL`, which sboot leaves unset, so without the shim nothing
written to the framebuffer ever reaches the panel.

```bash
# from an existing build71 output
TWRP_IMG=/path/to/twrp-3.3.1-0-star2lte.img \
    scripts/build/pack_uniloader.sh dist/m71-<stamp> <image-name>.img
# or build and pack in one go
TWRP_IMG=/path/to/twrp-3.3.1-0-star2lte.img \
    scripts/build/build71_ubuntu.sh <image-name>.img GPU=1 GADGET=configfs
```

The image lands in `dist/uniloader/<image-name>`. Payload address `0x92000000`.

The boot image copies its header layout and its DTBH table from the official
**TWRP 3.3.1-0 image for star2lte** (twrp.me), because that is an image the
bootloader is known to accept; the kernel never sees that DT, uniLoader hands
over its own. The TWRP image this port was validated with has SHA-256
`5b5d2290940203316024a94581107ffad17670bb2f596fd27ef483d3d2685994`.

## Size

arm64 `defconfig` produces a 54 MB `Image` — a distro kernel for four dozen
SoC families. The config here strips it to about 21 MB by turning off every
other `ARCH_*` and the subsystems this phone does not have.

## Building the root filesystem

```bash
sudo image/build-image.sh
```

Builds the Ubuntu 24.04 root filesystem from scratch: debootstrap, the common
package set and settings of all three phone projects
([`image/common/README.md`](../image/common/README.md)), then this phone's
hardware layer (`device/base/`, `device/configure.sh`). It asks for the
password of the user it creates; user name, time zone, locale, keyboard and
an SSH key are environment variables described there.

Output: `dist/image/s9plus-rootfs.img` (raw ext4, grows to the whole of
USERDATA on the first boot) and `SHA256SUMS`. The image needs no kernel
modules — the stable kernel has every driver built in — so kernel and root
filesystem can be rebuilt independently.

Build host: Ubuntu 24.04 as root (WSL2 works), with
`debootstrap qemu-user-static binfmt-support e2fsprogs openssl python3 curl
git`. The work directory (`WORK`, default `/var/tmp/s9plus-image`) must be
on a Linux filesystem.
