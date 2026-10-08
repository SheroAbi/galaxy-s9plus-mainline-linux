# 📱 Ubuntu on the Samsung Galaxy S9+

[![build](https://github.com/SheroAbi/galaxy-s9plus-mainline-linux/actions/workflows/build.yml/badge.svg)](https://github.com/SheroAbi/galaxy-s9plus-mainline-linux/actions/workflows/build.yml)

**A real Ubuntu 24.04 desktop on the Galaxy S9+, on mainline Linux 7.1.**
No Android underneath, no Halium, no container, no vendor blobs doing the work.
Just a current kernel, GNOME on Wayland and your phone as a small Linux computer.

- 🐧 **Mainline kernel:** Linux 7.1 plus this port's own drivers for storage, display, GPU clock, CPU frequency, PCIe Wi-Fi and USB.
- 🖥️ **Full desktop:** GNOME on Wayland at the panel's native 1440x2960, 60 fps, rendered by the Mali GPU (Panfrost).
- 💾 **Lives on the phone:** Ubuntu boots from the internal UFS storage like on any computer.
- 📶 **Connected:** Wi-Fi, touch, battery and charging, and USB network + serial console on one cable.
- 🔒 **Yours:** you build it yourself from public sources. No default password, root locked, SSH keys made on the phone.
- 💸 **A free home server:** 8 cores, 6 GB RAM, a few watts, a built-in UPS. Run your bot, AI agent or home automation on it instead of renting a VPS.

> Only for the **Exynos** Galaxy S9+ (**SM-G965F**, star2lte). The Snapdragon
> model (SM-G965U) is a different device and nothing here applies to it.
> *(Hobby project, not affiliated with Samsung.)*

---

## ✨ What works

| Subsystem | State | Driver |
|---|---|---|
| Boot | all 8 cores | uniLoader shim + mainline 7.1.0 |
| Storage | UFS 2.1, read/write, rootfs on `USERDATA` | `src/ufs/` (own) |
| Display | 1440x2960 KMS, 60 fps to the panel | `src/gpu/drm/s9p/` (own) |
| GPU | Mali-G72 via Panfrost, GNOME on Wayland | upstream panfrost + `src/soc/s9p-g3d.c` |
| Touch | S6SY761 multi-touch | upstream `s6sy761` + ACPM rail setup |
| Wi-Fi | BCM4361, `brcmfmac`, firmware embedded | `src/pci/pcie-exynos9810.c` (own) |
| USB | serial console (ACM) + network (NCM) | `src/usb/phy-exynos9810-usbdrd.c` (own) |
| Battery | MAX17042 gauge + MAX77705 charger in UPower; charging can be paused | upstream + `src/soc/max77705_charger.c` |
| CPU / GPU clocks | both CPU clusters and the GPU scale with load, thermally capped | `src/cpufreq/`, `src/soc/s9p-g3d.c` (own) |
| Watchdog | any hang becomes a reboot into TWRP instead of a dead phone | upstream `s3c2410_wdt` + PMU unmask |

**Not working (yet):** deep CPU idle (costs battery), suspend, audio, camera,
mobile network, Bluetooth (not in the kernel). About every second warm reboot hangs early and is rescued by
the watchdog. This is a working Linux machine, not a finished phone.
Details: [docs/06-known-issues.md](docs/06-known-issues.md).

---

## 🛠️ Build it yourself

Everything is built from this repository and public sources. No image is
downloaded from us. These exact steps run on every change on a fresh Ubuntu
24.04 machine ([build](https://github.com/SheroAbi/galaxy-s9plus-mainline-linux/actions/workflows/build.yml)).

**You need:** a Galaxy S9+ (SM-G965F) with an **unlocked bootloader** and
**TWRP 3.3.1-0** on `RECOVERY`, a **Linux** build host (Ubuntu 24.04 on a PC
or in a VM; WSL2 works too, but neither Windows nor WSL is required) and `adb`.

```bash
git clone https://github.com/SheroAbi/galaxy-s9plus-mainline-linux.git
cd galaxy-s9plus-mainline-linux

# 1. one-time setup: build directory, cross toolchain + static busybox, kernel tree
sudo scripts/build/setup_build.sh
sudo scripts/build/toolchain.sh
sudo scripts/build/fetch_mainline.sh

# 2. the kernel, wrapped in uniLoader (needs the official TWRP image as a template)
sudo scripts/build/build_stable.sh
sudo TWRP_IMG=/path/to/twrp-3.3.1-0-star2lte.img \
    scripts/build/pack_uniloader.sh dist/m71-<stamp> boot-s9plus.img

# 3. the Ubuntu root filesystem (asks for your password)
sudo image/build-image.sh
```

Good to know:
- 📁 The kernel tree lives in `BUILD` (default `/mnt/build`, any directory works; `BUILD=/some/dir` to move it). See [docs/02-building.md](docs/02-building.md).
- 🧰 No prebuilt tools needed: `toolchain.sh` fetches a **static** arm64 busybox from Ubuntu's archive, and the boot image and `dt.img` are written by the Python scripts in `scripts/build/`.
- ⚠️ Flash the **uniLoader** image from `dist/uniloader/`. The raw `dist/m71-<stamp>/boot.img` does not boot on its own.

---

## 📲 Install

Boot the phone into TWRP (Power + Volume-Up + Bixby) and connect it by USB:

```bash
# the root filesystem: resumable, every chunk checked, then read back whole
python3 scripts/flash/flash_s9plus_rootfs_adb.py dist/image/s9plus-rootfs.img
# the kernel: reboots only after BOOT reads back correctly
python3 scripts/flash/flash_s9plus_boot_adb.py dist/uniloader/boot-s9plus.img
```

> ⚠️ **This erases all Android user data** (`USERDATA`). `RECOVERY` keeps
> TWRP as the way back.

**First boot:** the root filesystem grows to the whole partition, the phone
makes its own SSH keys, and GNOME logs your user in. Over the USB cable the
phone is `172.16.42.2`: give the PC's new USB network adapter `172.16.42.1/24`
and `ssh <user>@172.16.42.2`. Wi-Fi is set up from the GNOME menu.
Details: [docs/03-installing.md](docs/03-installing.md).

---

## 🧩 Extras (optional)

Nothing of ours is preinstalled. These are installed on the phone only if you want them:

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

---

## 🛟 Troubleshooting

| Problem | Fix |
|---|---|
| `qemu-aarch64-static: Could not open '/lib/ld-linux-aarch64.so.1'` | The busybox in `$BUILD/out` is dynamically linked. Get the static one: `python3 scripts/build/fetch_busybox.py $BUILD/out/busybox-arm64` |
| `no build directory: /mnt/build` | Run `sudo scripts/build/setup_build.sh` first, or point `BUILD` at an existing directory. |
| Odin/Heimdall start a session, then every write fails | `KG STATE: Prenormal` (Knox Guard). Boot Android online with a correct clock until it clears. See [docs/03-installing.md](docs/03-installing.md). |
| Phone "hangs at the logo" or falls back to recovery | S-Boot rejected the image. Use the uniLoader image, never the raw `boot.img`. |
| Black screen, no USB | Wrong device tree or a kernel panic. Reach TWRP with Power + Volume-Up + Bixby and flash a known-good image back. |
| Wi-Fi drops after a failed rekey | `s9p-wifi-guard` reconnects after a minute; on weak 5 GHz pin the connection to 2.4 GHz. |

---

## 🔬 Under the hood

```
SoC        Exynos 9810 (Samsung 10 nm, "Mongoose 3")
CPU        4x Mongoose M3 @ 2704 MHz  +  4x Cortex-A55 @ 1794 MHz
GPU        Mali-G72 MP18 @ 572 MHz, Panfrost + Mesa
Display    1440x2960 AMOLED, DECON + MIPI DSI in command mode
Memory     6 GB LPDDR4X        Storage    64 GB UFS 2.1
Kernel     mainline 7.1.0 + this port's drivers
Userland   Ubuntu 24.04 LTS arm64, GNOME on Wayland
```

The clocks above are hardware maxima; the validated default ceilings are
2327 MHz M3 / 1499 MHz A55, with lower busy-core and thermal caps.

**Boot chain:** Samsung S-Boot (unlocked, never reflashed) → `BOOT`:
uniLoader shim + mainline Image + DTB → built-in initramfs (arms the recovery
magic, finds `USERDATA`) → `switch_root` into Ubuntu on `/dev/sda25`.
`RECOVERY` keeps TWRP 3.3.1-0 as the way back.

### 📈 Measured

| | before this round of work | after |
|---|---|---|
| Frames per second reaching the panel | CPU copy path | 60 |
| `gnome-shell` CPU at an idle desktop | 12.4 % | 1.2 % |
| Panfrost GPU faults after a full load run | 16 in 2 min | 0 |
| SoC temperature under GPU load / at idle | 66 °C / 52 °C | 58 °C / 43–46 °C |
| glmark2 score (1080x1920) | 840 | 1025 |
| Panfrost probe time | 14.3 s | 0.9 s |

How each was measured: [docs/05-performance.md](docs/05-performance.md),
[docs/07-validation.md](docs/07-validation.md).

### 🧗 Hurdles that were overcome

<details>
<summary>The problems that cost days, and what fixed them (click to open)</summary>

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

</details>

### 🗂️ Repository layout

```text
src/                 the drivers this port adds to the mainline tree
  ufs/               UFS 2.1 host controller + Samsung's PHY calibration
  gpu/drm/s9p/       DECON scanout driver (KMS)
  soc/               ACPM mailbox, G3D clock and power domain, clock gates, MUIC, charger
  cpufreq/  pci/  usb/   CPU clusters, PCIe root complex for Wi-Fi, USB 2.0 PHY
  mainline-dts/      the board device tree
bootloader/uniLoader/  the shim that starts a mainline kernel on this S-Boot
image/               build the Ubuntu root filesystem (common/ is shared by all three phones)
device/              initramfs init scripts, and the hardware layer of the image (base/)
extras/              optional features, installed on request
scripts/build/       kernel, boot image, DTBH table, busybox (env.sh: locations)
scripts/flash/       write boot and rootfs to the phone from TWRP
firmware/            BCM4361 firmware and the wireless regulatory database
docs/                everything above in detail
```

`dist/` is where builds land; it is ignored by git.

### 📚 Documentation

| | |
|---|---|
| [01-hardware.md](docs/01-hardware.md) | the SoC, what sits on which bus, and the addresses that matter |
| [02-building.md](docs/02-building.md) | build host, toolchain, every build switch, the image |
| [03-installing.md](docs/03-installing.md) | partitions, TWRP, flashing, first boot |
| [04-drivers.md](docs/04-drivers.md) | each driver, why it exists, how it works |
| [05-performance.md](docs/05-performance.md) | the display path, the GPU, thermals, and how each was measured |
| [06-known-issues.md](docs/06-known-issues.md) | what does not work, and what was tried |
| [07-validation.md](docs/07-validation.md) | the CPU/GPU validation runs and their limits |

---

## 🙏 Acknowledgements

Starting a mainline kernel on the Exynos 9810 at all rests on
[uniLoader](https://github.com/ivoszbg/uniLoader) and on the mainline Exynos
9810 work of its community, which already carried the SoC and Galaxy S9 board
support this port builds on. `mkdtbh.py` follows
[dtbtool-exynos](https://github.com/dsankouski/dtbtool-exynos).

**Same idea, other phones:**
[Xiaomi Mi 9T (Snapdragon 730)](https://github.com/SheroAbi/mi9t-mainline-linux) ·
[Xiaomi Redmi 8 (Snapdragon 439)](https://github.com/SheroAbi/redmi8-mainline-linux)

---

## 🇩🇪 Kurz auf Deutsch

Dieses Projekt bringt ein **echtes Ubuntu 24.04 mit GNOME** auf das Galaxy S9+
(Exynos, SM-G965F): aktueller Mainline-Kernel 7.1, kein Android darunter.
Display, GPU, internes UFS, WLAN, Touch, Akku und USB laufen, dafür wurden
eigene Treiber geschrieben. Ideal als stromsparender Heimserver statt VPS.
Gebaut wird alles selbst aus öffentlichen Quellen auf einem Linux-Rechner
(Windows/WSL nicht nötig): `setup_build.sh` → `toolchain.sh` →
`fetch_mainline.sh` → `build_stable.sh` → `pack_uniloader.sh` →
`image/build-image.sh`, dann per TWRP + adb flashen. **Achtung:** Die
Android-Nutzerdaten werden gelöscht.

---

## 📄 License

GPL-2.0-only, the same as the kernel these drivers are built into. See
[LICENSE](LICENSE), and [THIRD-PARTY.md](THIRD-PARTY.md) for the vendored and
redistributed components. `bootloader/uniLoader/` is a third-party project and
carries its own licence.

This is a hobby project and comes without any warranty. Flashing a phone can
go wrong; you do it at your own risk.
