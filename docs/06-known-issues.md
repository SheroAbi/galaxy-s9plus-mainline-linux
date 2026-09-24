# Known issues

Honest list. Everything here has been reproduced on the device.

## CPU idle does not work

Deep CPU idle remains a major power-management gap. The current kernel uses
`WFI`; the contribution of each powered block to idle temperature has not been
isolated with a whole-device power measurement.

Four attempts, all reproduced:

| attempt | result |
|---|---|
| both clusters powerdown (`arm,psci-suspend-param = <0x10000>`) | boot hangs |
| little cluster only, big cluster with no idle state | boots, but `CPUidle PSCI: Failed to create psci-cpuidle device` -- `psci_cpuidle_probe()` walks every present CPU and aborts entirely when one has no DT idle state |
| big cluster given a retention state (`param = <0x0>`) so the probe has something for every CPU | boot hangs |
| CPU idle floor in cpufreq (hold an idle cluster at its lowest step) | booted on #150, #155 and #157; sampler pinned to A55 CPU0 on #155 and later |

The root causes of the suspend failures are unresolved. M3 hotplug previously
failed at assembly stage 7, but context-losing PSCI `CPU_SUSPEND` resumes through
`cpu_resume`; hotplug `CPU_OFF`/`CPU_ON` uses secondary entry. These are separate
paths and the hotplug failure does not prove the cause of the suspend failure.
Initial SMP bring-up works with the six vendor M3 PMU defaults and `maxcpus=8`.

Any further idle experiment needs separate resume instrumentation and DVFS/
cluster coordination. Do not enable the failed DT states at boot.

The device tree ships **without** deeper idle states. CPU idle frequency
flooring and GPU per-step voltage are both **off** (since 2026-09-23):

    s9p_cpufreq.idle_floor=1    hold an idle cluster at its lowest step
    s9p_g3d.step_volt=1         lower BUCK6 on the lower GPU clock steps

With both on, kernel #163 froze roughly once a day on an idle desktop:
seven hard hangs in a week, the journal simply stops, and three of them
never came back without a manual reset. Both switches lower voltages only
while idle (M3 at 400 MHz / 700 mV, a step no load test covered); their
validation ran 30-120 s. Kernels built before this change default to on,
so `s9p-stability.service` writes `N` to both at every boot.

`s9p-blackbox.service` writes every kernel message and a state line per
minute (clocks, rail, temperatures, Wi-Fi) to `/var/log/s9p-blackbox.log`,
fsync'ed. The journal does not keep kernel messages of a boot that hung, so
after the next freeze this file is where the last minute is.

## Wi-Fi drops and never comes back

A failed group rekey (`EAPOL-Key Replay Counter did not increase`) makes
NetworkManager ask for a new password; with no secret agent it ends in
`no-secrets` and never retries. `s9p-wifi-guard.service` reconnects after a
minute. The profile is pinned to 2.4 GHz (`band bg`): at the desk the
router's 5 GHz radio arrives at -82 dBm, 2.4 GHz at -57 dBm. Power save is
off in both NetworkManager and `s9p-power balanced`.

## No suspend

Suspend cannot resume (the M3 cores do not come back), so every sleep
target is masked and `AllowSuspend=no`.

See [07-validation.md](07-validation.md) for the CPU/GPU measurements and
the parameter state they were taken with.

## GPU power-off recovery history

On #155, setting `s9p_g3d_pd.always_on=N` resulted in a partial power-down
(`STATUS=002f000e`) and an SError on the next Panfrost reset. Pstore was recovered
from TWRP. The missing vendor secure-save step and five G3D PMU low-power
initialization settings were added. #160 completed repeated full off/on and
render cycles; #162 boots with this enabled by default. `always_on=Y` remains
the recovery override. See [07-validation.md](07-validation.md) for job faults
that remain separate from the repaired power-domain timeout.

## Screen transfer

The 9 FPS bottleneck of a 1080p GNOME screen-cast (see
[05-performance.md](05-performance.md)) was later worked around with a
capture path that reached about 51 FPS in an animated 1080p test.

## gnome-shell restarts in the first minute

A `SIGSEGV` inside Mesa/EGL (stack in `libgallium` / `libEGL_mesa`), not a
kernel-reported fault. It settles after a few restarts and then runs.

## Warm reboots hang early

Roughly every second warm restart stops early in boot. The watchdog is the
mitigation, not the fix: WDT1 is armed from the first boot instruction
(`s3c2410_wdt.tmr_atboot=1 tmr_margin=60`) and systemd takes over with
`RuntimeWatchdogSec=30s` once userspace is up, so a hang turns into a reboot
instead of a dead phone.

For this to work at all the PMU's `MASK_WDT_RESET_REQUEST` has to be cleared
-- see [04-drivers.md](04-drivers.md).

## Reading the sboot framebuffer resets the SoC

Mapping `0xcc000000` through `/dev/mem` resets the phone (`RST_STAT
0x10000`). Read the **live** scanout address out of DECON's IDMA register
instead.

## s9p-acpm info crashes

One channel entry lies in a faulting SRAM page. `read`, `write`, `update` and
`tsp` work.

## No snap

`CONFIG_SQUASHFS` does not build in this tree, so snaps cannot mount. Install
`gnome-shell` + `ubuntu-session` + Yaru + `gnome-shell-extension-ubuntu-dock`
rather than `ubuntu-desktop`, or GNOME looks like bare Debian.

Practical consequence: Thunderbird has no arm64 package outside snap. Evolution
is the substitute that works.

## Things that look like bugs and are not

* **glmark2 is clean while the desktop shows artefacts.** That is the texture
  path, not a contradiction. See [05-performance.md](05-performance.md).
* **`KNOX_NCM` cannot be turned off** in the old 4.9 tree -- the network core
  calls `check_ncm_flag()` and `knox_collect_conntrack_data()`
  unconditionally, so `vmlinux` does not link without it. Only relevant if you
  go back to the downstream kernel.
* **A mainline kernel that does nothing at all** is the `text_offset` trap.
  See [02-building.md](02-building.md).
