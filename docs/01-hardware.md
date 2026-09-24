# The hardware

Samsung Galaxy S9+, model **SM-G965F**, Samsung codename **star2lte**,
Exynos 9810 variant (the Snapdragon SM-G965U is a different phone and none of
this applies to it).

## SoC map

| Block | Address | Notes |
|---|---|---|
| DECON0 (display controller) | `0x16070000` | IDMA channel registers at `+0x1000*(1+ch)`; the live scanout address is at `+0x40` of that |
| DSIM0 (MIPI DSI) | `0x16100000` | command mode, TE-triggered |
| Mali-G72 MP18 | `0x11400000` | r0p1, driven by upstream panfrost |
| UFS host controller | `0x11120000` | UFS 2.1, HS gear 3, 2 lanes, series B |
| PCIe (Wi-Fi) | `0x11500000` | DesignWare core, INTx only |
| PMU | `0x14060000` | `INFORM2/3` at `+0x808/+0x80c`, `MASK_WDT_RESET_REQUEST` at `+0x40c` |
| WDT cluster 1 | `0x10060000` | `s3c2410_wdt`, exynos7 variant, `GIC_SPI 465` |
| ACPM mailbox (APM firmware) | SRAM | the only path to the S2MPS18 PMIC |
| ramoops window | `0x8000@0xfed10000` | geometry kept byte-compatible with the stock 4.9 kernel so TWRP can read it |
| sboot framebuffer | `0xcc000000` | **do not read it through `/dev/mem`** — it resets the SoC (`RST_STAT 0x10000`) |
| CMA (this port) | `0x98000000`, 320 MiB | below 4 GB, because DECON's scanout address register is 32 bit |

## Power

The **S2MPS18** PMIC is not on a bus the kernel can reach directly. It sits
behind the APM firmware and is spoken to over the ACPM mailbox on channel 2.
`s9p-acpm` (in [`extras/debug-tools`](../extras/debug-tools/)) implements that protocol from
userspace through `/dev/mem`, and `src/soc/s9p-acpm.c` does the same in the
kernel.

Only 32-bit accesses work, and the first three SRAM pages fault when mapped —
`s9p-acpm info` still crashes for that reason; `read`, `write` and `tsp` work.

Rails that matter:

| Rail | Register | What it feeds | What sboot/TWRP leave it at |
|---|---|---|---|
| BUCK2 | `0x29` | M3 cluster | ~694 mV (≈1.05 GHz) |
| BUCK3 | `0x2a` | A55 cluster | ~768 mV |
| BUCK6 | `0x2b` | `vdd_g3d` | **644 mV** — Panfrost throws `DATA_INVALID_FAULT` on this; the port raises it to 950 mV (`0x68`) before the GPU is allowed to run |
| LDO35, LDO43 | | touch controller | **off** — the port switches them on at boot |

BUCK6 encoding: 300 mV + `sel` × 6.25 mV, so `0x68` = 950 mV.

## Clocks

There is no CMU driver for this SoC. sboot has already configured FSYS0 (it
loaded the boot image over UFS), so the device tree declares fixed clocks and
the UFS probe prints `HCI_1US_TO_CNT_VAL` — which is `mclk / 1 MHz` as the
last driver to touch the block programmed it, so the real rate can be read off
the hardware instead of guessed.

`PLL_G3D` only relocks after `PLL_CON2 = 0x30000003`; sboot's `0x10000001`
keeps it from ever reaching `STABLE`. The vendor PLL tables are in
Samsung's 4.9 kernel source for this phone (`cmucal-node.c`).

Vendor maxima the port sets:

| | Clock | Rail |
|---|---|---|
| M3 | 2704 MHz | 1100 mV (BUCK2) |
| A55 | 1794 MHz | 1000 mV (BUCK3) |
| G72 | 572 MHz (M 286 / P 13 / S 0) | 950 mV (BUCK6) |

## Thermals

Three TMU sensors, two-point trim, 9-bit codes, three sensors per
`CURRENT_TEMP` register. `s9p-cpufreq` caps the clusters and `s9p-g3d` caps
the GPU:

| Sensor above | big cluster | little cluster | GPU |
|---|---|---|---|
| 72 °C | 2327 MHz | 1499 MHz | — |
| 80 °C | 1794 MHz | — | — |
| 88 °C | 1066 MHz | — | 260 MHz |

A single big core at 2.7 GHz reaches ~90 °C within two minutes of full load,
so expect that cap to cycle under sustained load.

## Peripherals

| Device | Bus | Driver |
|---|---|---|
| S6SY761 touch | `hsi2c` USI03 | upstream `s6sy761`; the DT declares `touchscreen-size-x/y = <4096>` because the firmware reports 12-bit coordinates on both axes — with the panel size there instead, every one-finger tap lands on the screen edge |
| MAX77705 | i2c | charger + MUIC; TWRP resets it, so the port reprograms the input limit (375 mA → 500 mA) |
| MAX17042 | i2c | fuel gauge |
| BCM4361 | PCIe | `brcmfmac`; RAM base `0x170000`, **INTx not MSI**, and `dma-coherent` in the DT is fatal |

## Partitions

| Partition | Block device | Holds |
|---|---|---|
| `BOOT` | `/dev/block/sda10` | this kernel |
| `RECOVERY` | | TWRP 3.3.1-0 |
| `USERDATA` | `/dev/block/sda25` | the Ubuntu 24.04 rootfs, 57 GB |

sboot keeps whatever recovery flag it was last given, so whatever sits on
`RECOVERY` is what every boot lands in. Keeping TWRP there is the recovery
path for a kernel that does not come up.
