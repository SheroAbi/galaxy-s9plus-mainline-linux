# Ubuntu on the Samsung Galaxy S9+

This is a Samsung Galaxy S9+ from 2018 that runs a real, current Linux: the
mainline kernel 7.1 and an ordinary Ubuntu 24.04 with GNOME on Wayland. There
is no Android underneath, no Halium, no container and no vendor Android
drivers doing the work behind the scenes. The desktop is drawn by the phone's
own Mali GPU through the open-source Panfrost driver, the screen is driven by
a display driver written for this project, and the system lives on the
phone's internal storage like on any other computer.

Why would you want that? Because an old flagship in a drawer is a small,
quiet, eight-core ARM64 computer with 6 GB of RAM, fast storage, Wi-Fi and a
built-in battery that bridges power cuts. Many people rent a VPS to run a
self-hosted AI agent, a bot, a home automation hub or a small web service.
This phone can be that machine instead: it sits on your desk, it costs
nothing per month, it draws a few watts, and your data stays at home. You
reach it over SSH like any server, and it still has a touchscreen and a full
desktop when you want to look at it. This repository shows, step by step,
how to turn such a device into your own Linux machine, and the same way of
working carries over to other old phones.

What makes this phone hard is its chip. The Exynos 9810 is Samsung's own
design, and mainline Linux knows almost nothing about it: when this project
started, the kernel could not even see the internal storage, so there was
nowhere to boot a system from. There was no clock driver, no power
management for the processor or the graphics core, no display driver, no
PCIe for the Wi-Fi chip and no USB. Each of those had to be written or
adapted, usually with nothing more than Samsung's old Android kernel source
as a map and a phone that shows nothing at all when something goes wrong.

It works now. The phone boots with all eight cores, mounts its Ubuntu root
filesystem from the internal UFS storage, shows GNOME at the panel's full
1440x2960 resolution at 60 frames per second, reacts to touch, connects to
Wi-Fi, reports its battery and charging state, and can be reached over the
USB cable as a network device and as a serial console. The CPU and GPU
change their clock speed with the load and throttle themselves before they
get too hot, and a hardware watchdog turns any hang into a reboot instead of
a dead phone.

You build the system yourself, from this repository and public sources
only. The build produces a clean, ordinary Ubuntu: the same base system as
the two sister projects for the Mi 9T and the Redmi 8, plus only the few
files this phone's hardware needs. Nothing of ours is preinstalled. The
extra features we built for our own use (power profiles, a flight recorder
for debugging hangs, apt through the USB cable, the bring-up tools) are kept
separate and marked as extras; you install them only if you want them. The
image has no default password: you choose one when you build it, root is
locked, and every phone creates its own SSH keys on its first boot.

Some of the problems on the way were the kind that cost days. A mainline
kernel did simply nothing, no message, no error, because Samsung's 2018
bootloader still places the kernel by a header field that mainline stopped
filling years ago, and then overwrites the first bytes of it. The graphics
core faulted randomly until it turned out the bootloader leaves its supply
voltage far too low. A mailbox to the power-management firmware seemed to
work but never answered, because two ring buffers were swapped. Icons showed
tiny stripes that were finally traced to a texture compression feature in
the graphics driver. All of that is written down here in detail.

Being honest about the limits matters. The processor cores cannot enter
their deeper idle states yet, which costs battery. The phone cannot suspend
and wake up again. There is no sound, no camera and no mobile network. About
every second warm reboot hangs early and is rescued by the watchdog. This is
a working Linux machine, not a finished phone.

This repository is for anyone who owns a Galaxy S9+ (the Exynos model,
SM-G965F) and wants to run Linux on it, and for anyone porting mainline Linux
to another Exynos device. The Snapdragon version of the phone (SM-G965U) is
a different device, and nothing here applies to it.

---

## Technical overview

```
SoC        Exynos 9810 (Samsung 10 nm, "Mongoose 3")
CPU        4x Mongoose M3 @ 2704 MHz  +  4x Cortex-A55 @ 1794 MHz
GPU        Mali-G72 MP18 @ 572 MHz, Panfrost + Mesa
Display    1440x2960 AMOLED, DECON + MIPI DSI in command mode
Memory     6 GB LPDDR4X
Storage    64 GB UFS 2.1
Kernel     mainline 7.1.0 + this port's drivers
Userland   Ubuntu 24.04 LTS arm64, GNOME on Wayland
```

The clocks above are hardware maxima. The validated default ceilings are
2327 MHz M3 / 1499 MHz A55, with lower busy-core and thermal caps.

### Boot chain

```
Samsung S-Boot (unlocked, never reflashed)
  -> BOOT partition: uniLoader shim + mainline Image + DTB
    -> built-in initramfs: arms the recovery magic, finds USERDATA
      -> switch_root into Ubuntu on USERDATA (/dev/sda25)
RECOVERY keeps TWRP 3.3.1-0 as the way back.
```

### What works

| Subsystem | State | Driver |
|---|---|---|
| Boot | all 8 cores, `maxcpus=8` | uniLoader shim + mainline 7.1.0 |
| Storage | UFS 2.1, read/write, rootfs on `USERDATA` | `src/ufs/` (own) |
| Display | 1440x2960 KMS, 60 fps to the panel | `src/gpu/drm/s9p/` (own) |
| GPU | Mali-G72 via Panfrost, `renderD128`, GNOME on Wayland | upstream panfrost + `src/soc/s9p-g3d.c` |
| Touch | S6SY761 multi-touch | upstream `s6sy761` + ACPM rail setup |
| Wi-Fi | BCM4361, `brcmfmac`, firmware embedded | `src/pci/pcie-exynos9810.c` (own) |
| USB | configfs gadget: ACM console + NCM network | `src/usb/phy-exynos9810-usbdrd.c` (own) |
| Battery | MAX17042 gauge + MAX77705 charger in UPower; charging can be stopped via `charge_behaviour` | upstream + `src/soc/max77705_charger.c` + `src/soc/s9p-max77705-muic.c` |
| CPU DVFS | both clusters, thermal capped | `src/cpufreq/s9p-cpufreq.c` (own) |
| GPU DVFS | devfreq, 260 / 455 / 572 MHz | `src/soc/s9p-g3d.c` (own) |
| GPU idle power | full G3D domain off/on | `src/soc/s9p-g3d-pd.c` (own) |
| Watchdog | cluster-1 WDT, armed from the first boot instruction | upstream `s3c2410_wdt` + PMU unmask |
| Panel power | display off cuts the panel supply, not just the backlight | `src/gpu/drm/s9p/s9p-decon.c` |
| Not working | CPU idle states, suspend, audio, camera, modem | [docs/06-known-issues.md](docs/06-known-issues.md) |

### Measured

| | before this round of work | after |
|---|---|---|
| Scanout buffer allocation errors | continuous | 0 |
| Frames per second reaching the panel | CPU copy path | 60 |
| `gnome-shell` CPU at an idle desktop | 12.4 % | 1.2 % |
| Panfrost GPU faults after a full load run | 16 in 2 min | 0 |
| SoC temperature under GPU load | 66 °C | 58 °C |
| SoC temperature at idle | 52 °C | 43–46 °C |
| glmark2 score (1080x1920) | 840 | 1025 |
| Panfrost probe time | 14.3 s | 0.9 s |

How each was measured: [docs/05-performance.md](docs/05-performance.md) and
[docs/07-validation.md](docs/07-validation.md).

### Hurdles that were overcome

| Symptom | Cause | Fix |
|---|---|---|
| Nowhere to boot a system from | mainline's `exynos9810.dtsi` has no storage node, no UFS driver fits the 9810 | own UFS host driver around Samsung's unchanged PHY calibration (`src/ufs/`) |
| A mainline kernel does nothing at all: no console, no panic, no reset | S-Boot places the image by the header's `text_offset`, which mainline sets to 0; the kernel lands on S-Boot's own structures at 0x80000000 | write `0x80000` back into the header after linking |
| Nothing written to the framebuffer ever reaches the panel | S-Boot leaves DECON's `HW_SW_TRIG_CONTROL` unset | boot through uniLoader, which sets it |
| The same image boots once and hangs the next time | S-Boot hands firmware log windows inside 0x90000000–0x9179c000 to the other side, which keeps writing into the copied kernel | uniLoader payload at 0x92000000 |
| Images rejected, phone falls back to recovery ("hangs at the logo") | S-Boot checks the SHA1 image id and needs the `SEANDROIDENFORCE` trailer | both written by the build (`mkboot.py`) |
| Odin and Heimdall start a session, then every write fails | `KG STATE: Prenormal` (Knox Guard) | boot Android online with a correct clock until it clears |
| Power-management mailbox "works" but never answers | the two ACPM ring buffers were swapped | fixed field mapping in `s9p-acpm.c` |
| Random `DATA_INVALID_FAULT` from the GPU, two kernels hung at boot | S-Boot leaves the GPU rail at 644 mV; Panfrost bound before it was raised | `s9p-g3d` raises BUCK6 to 950 mV first and only then publishes the clock (`-EPROBE_DEFER` until then) |
| GPU faults on every clock change | mux and PLL switched in one write, the GPU briefly had no clock | glitch-free mux switch with a busy poll |
| Desktop laggy, compositor copying every frame on the CPU | 128 MiB CMA held exactly one 16 MiB frame | 320 MiB CMA below 4 GB (DECON's address register is 32 bit) |
| "First an artefact, then it loads" on every click | page flips did not wait for DECON's shadow registers | the vendor's update-done handshake, 250 µs poll |
| Panfrost probe took 14 s | a sibling OPP table is a `fw_devlink` supplier | OPP table inside the `gpu` node |
| 16-pixel dashes in icons and text, glmark2 clean | Mesa's AFBC repacking on Mali-G72 r0p1 | `PAN_MAX_AFBC_PACKING_RATIO=0` in `/etc/environment` |
| Wi-Fi: "firmware failed to initialize", then ioctl timeouts | wrong RAM base, MSI instead of INTx, `dma-coherent` in the DT | RAM base 0x170000, INTx domain, no `dma-coherent` |
| Every one-finger tap lands on the screen edge | the touch firmware reports 12-bit coordinates on both axes | `touchscreen-size-x/y = <4096>` |
| Phone discharges on a PC port | TWRP resets the MAX77705, input limit 375 mA | restored to 500 mA at boot |
| The watchdog never fired | S-Boot sets `MASK_WDT_RESET_REQUEST` in the PMU | cleared from the device tree (`s9p-clkgate`) |
| Early boot died before any console | 52-bit VA/PA fallback runs before a console exists; the M3 lacks LVA/LPA2 | 48-bit VA and PA |
| Rare hard hangs on an idle desktop | idle-only voltage reductions on CPU and GPU | both off by default; an optional flight recorder logs the last minute |

### Build your own system

Everything is built from this repository and public sources; no image is
downloaded from us. You need the phone with an unlocked bootloader and TWRP
3.3.1-0 on `RECOVERY`, a Linux build host (Ubuntu 24.04, a VM or WSL2
works), an aarch64 cross toolchain and `adb`.

```bash
# 1. the kernel (one-time setup, then the validated configuration)
scripts/build/setup_build.sh && scripts/build/toolchain.sh && scripts/build/fetch_mainline.sh
scripts/build/build_stable.sh
TWRP_IMG=/path/to/twrp-3.3.1-0-star2lte.img \
    scripts/build/pack_uniloader.sh dist/m71-<stamp> boot-s9plus.img

# 2. the Ubuntu root filesystem: asks for your password
sudo image/build-image.sh

# 3. flash from TWRP (the scripts check the device and read everything back)
python scripts/flash/flash_s9plus_rootfs_adb.py dist/image/s9plus-rootfs.img
python scripts/flash/flash_s9plus_boot_adb.py dist/uniloader/boot-s9plus.img
```

What the image contains: the common base system of all three phone projects
([`image/common/README.md`](image/common/README.md): Ubuntu 24.04, GNOME,
Firefox, SSH, no default password, root locked, SSH keys made on the phone),
plus this phone's hardware layer in [`device/`](device/). Do not flash the
raw `m71-<stamp>/boot.img`: a direct boot without uniLoader fails early.
Details: [docs/02-building.md](docs/02-building.md),
[docs/03-installing.md](docs/03-installing.md).

### Extras (optional, never installed by the image build)

On the phone, from a checkout of this repository:

```bash
sudo extras/install.sh                    # list them
sudo extras/install.sh power-profiles     # install one; --remove takes it out again
```

| Extra | What it does |
|---|---|
| [power-profiles](extras/power-profiles/) | CPU/GPU ceilings and Wi-Fi power save as three profiles, following GNOME's power mode |
| [flight-recorder](extras/flight-recorder/) | every kernel message and a state line per minute, fsync'ed, for hunting hangs |
| [usb-apt-proxy](extras/usb-apt-proxy/) | apt through a proxy on the PC the phone is cabled to |
| [debug-tools](extras/debug-tools/) | the register, PMIC and clock tools from the bring-up |

### Repository layout

```
src/                 the drivers this port adds to the mainline tree
  ufs/               UFS 2.1 host controller + Samsung's PHY calibration
  gpu/drm/s9p/       DECON scanout driver (KMS)
  soc/               ACPM mailbox, G3D clock and power domain, clock gates,
                     MUIC, MAX77705 charger
  cpufreq/           both CPU clusters, with the thermal cap
  pci/               PCIe root complex for the Wi-Fi chip
  usb/               USB 2.0 PHY
  mainline-dts/      the board device tree
  reference/         pinned upstream file the build checks against
bootloader/uniLoader/  the shim that starts a mainline kernel on this S-Boot
image/               build the Ubuntu root filesystem (common/ is shared by all three phones)
device/              initramfs init scripts, and the hardware layer of the image (base/)
extras/              optional features, installed on request
scripts/
  build/             build the kernel and the boot image (env.sh: locations)
  flash/             write boot and rootfs to the phone from TWRP
firmware/            BCM4361 firmware and the wireless regulatory database
branding/            boot logo
docs/                everything above in detail
```

`dist/` is where builds land; it is ignored by git.

### Documentation

| | |
|---|---|
| [01-hardware.md](docs/01-hardware.md) | the SoC, what sits on which bus, and the addresses that matter |
| [02-building.md](docs/02-building.md) | build host, toolchain, every build switch, the image |
| [03-installing.md](docs/03-installing.md) | partitions, TWRP, flashing, first boot |
| [04-drivers.md](docs/04-drivers.md) | each driver, why it exists, how it works |
| [05-performance.md](docs/05-performance.md) | the display path, the GPU, thermals, and how each was measured |
| [06-known-issues.md](docs/06-known-issues.md) | what does not work, and what was tried |
| [07-validation.md](docs/07-validation.md) | the CPU/GPU validation runs and their limits |

### Acknowledgements

Starting a mainline kernel on the Exynos 9810 at all rests on
[uniLoader](https://github.com/ivoszbg/uniLoader) and on the mainline
Exynos 9810 work of its community, which already carried the SoC and
Galaxy S9 board support that this port builds on.

### Related projects

The same idea, Ubuntu on mainline Linux, on two other phones:

* [Xiaomi Mi 9T (Snapdragon 730)](https://github.com/SheroAbi/mi9t-mainline-linux)
* [Xiaomi Redmi 8 (Snapdragon 439)](https://github.com/SheroAbi/redmi8-mainline-linux)

### Licence

GPL-2.0-only, the same as the kernel these drivers are built into. See
[LICENSE](LICENSE), and [THIRD-PARTY.md](THIRD-PARTY.md) for the vendored and
redistributed components. `bootloader/uniLoader/` is a third-party project
and carries its own licence.

This is a hobby project and comes without any warranty. Flashing a phone can
go wrong; you do it at your own risk.
