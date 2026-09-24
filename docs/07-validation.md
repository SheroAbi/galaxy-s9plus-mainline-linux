# CPU/GPU validation

Kernels #157 to #162, September 2026, on the reference SM-G965F. Scope:
CPU/GPU scheduling, DVFS, power and thermal behaviour. This is not a claim of
complete power-management support or of a global performance optimum.

> Since this validation, the idle-only voltage reductions (`idle_floor`,
> `step_volt`) default to **off**, because they led to rare hard hangs on an
> idle desktop over a week of use. See [06-known-issues.md](06-known-issues.md).
> The measurements below were taken with them on.

## CPU changes verified on #157

- CPUfreq uses a target callback with explicit begin/end notifications, so
  the instantaneous M3 busy-core cap reports the frequency actually applied.
  Ordinary busy-core races no longer return repeated `-EAGAIN`.
- Initial frequency validation puts the bootloader frequency onto a real
  table entry before stats initialization. Both policies now accumulate
  time-in-state; A55 stats were previously all zero.
- CPU capacity is 368 for A55 and 1024 for M3. The per-MHz DT ratio 556:1024
  comes from the same EEMBC CoreMark binary on fixed, sampled clocks:
  A55 4174.145 iterations/s at 1150.5 MHz; M3 7127.076 at 1066 MHz.
  Both CRCs passed, both runs exceeded 10 seconds. This integer workload is an
  initial calibration, not a universal IPC ratio or measured energy model.
- The policy worker runs on A55 CPU0; its own execution no longer prevents
  M3 idleness. The idle floor, busy-core limits and thermal caps remain active.
- Default validated ceilings are A55 1499 MHz and M3 2327 MHz; M3 is limited
  to 1794 MHz with three or more busy cores. Stock maximum boost stays off.

Reference contracts: [Linux CPU capacity](https://docs.kernel.org/scheduler/sched-capacity.html),
[CPUfreq driver interface](https://docs.kernel.org/cpu-freq/cpu-drivers.html),
[EEMBC CoreMark](https://github.com/eembc/coremark).

## Physical-device checks

The raw measurement logs are not part of this repository; their names are
kept below so the runs can be told apart.

`sustained-157.jsonl`: 30 seconds idle, all eight CPU cores checking SHA-256 for
40 seconds concurrently with three 15-second GPU scenes, then 40 seconds
cooldown. Every CPU checksum passed, GPU exit was 0, and the timestamp-bounded
kernel log had no GPU faults or CPUfreq transition errors during this run.
This bounded test is not long-term stability proof.

Idle samples: M3 48-51 C, A55 48-51 C, GPU 47-49 C. Mixed-load samples:
M3 up to 86 C, A55 81 C, GPU 73 C; the faster kernel thermal poll reached
88 C and reduced M3 frequency to 1066 MHz. End-of-cooldown chip readings were
about 50-51 C. Battery temperature remained reported as 33.3 C.
Die temperature is not case or battery temperature. No whole-device power
measurement was made. Do not derive a watt or battery-life improvement here.

The short GPU test in `perf-157.json` also had no faults, but #155 produced
faults under other desktop workloads at a constant 950 mV. Disabling Panfrost
flush reduction did not remove them. These runs do not establish the GPU
faults as globally fixed. Earlier test JSONs could include the entire dmesg
buffer on a prefix mismatch; only timestamp-bounded deltas support fault
counts for a particular interval.

## Boot images

Every validated image was the uniLoader-wrapped boot image
(`scripts/build/pack_uniloader.sh`), written to BOOT with a readback check,
with TWRP left untouched on RECOVERY. #162 booted with `step_volt=Y`,
`always_on=N`, `boost=0` as its defaults; GNOME started and the G3D domain
reached `off-0` on the first boot. A direct (unwrapped) boot of the same
kernels failed early; the cause is not known.

## GPU voltage and runtime power repair

`gpu-voltage-159.jsonl`: 36 OPP transitions during desktop rendering, with
PMIC readback matching 260 MHz / 850 mV, 455 MHz / 900 mV and 572 MHz / 950 mV.
No job faults in that interval. Disabling voltage scaling at 260 MHz correctly
restores 950 mV before a subsequent 572 MHz request. Readback reports the PMIC
programmed setting; it is not a physical voltage measurement.

The G3D PMU prerequisite settings were missing from the original on/off code.
Live readback on #159 matched the bootloader values, not Samsung's
`flexpmu_cal_system_exynos9810.h` `pmucal_lpm_init` sequence:

| PMU address | Mask | Before | Required masked value |
|---|---:|---:|---:|
| 0x14064690, MEMORY_EMBEDDED_G3D_OPTION | 0x3 | 1 | 2 |
| 0x14064680, PWR_EMBEDDED_G3D_OPTION | 0x2 | 3 | 0 |
| 0x14064684, PWR_EMBEDDED_G3D_DURATION | 0xfff | 0xfff | 0x363 |
| 0x140615a8, SCI_CRPPORTPWRDN | 1 | 0xaf4d0000 | 1 |
| 0x140615ac, PWR_EMBEDDED_G3D | 1 | 0x896b0000 | 1 |

The driver uses masked writes, preserving other bits. It also saves secure
state before power-off, restores it after power-on, and verifies rollback
before allowing GPU register accesses after a failed shutdown.
Vendor source commit: `5eaa43c40667ef407f826ca2bab9552568327c23`.

`gpu-pm-160.jsonl` proves four complete power-on/off pairs. The subsequent
`gpu-resume-160.jsonl` records 15 independent render/context-destruction/idle
cycles, power-on count 9 -> 24 and power-off count 10 -> 25, with no fault log.
`sustained-pm-160.jsonl` passed all eight CPU checksums and GPU rendering, but
recorded **two DATA_INVALID_FAULT jobs during cooldown**. These are not hidden
by the passing benchmark exit. #162 adds submitter name/PID to future faults
to distinguish benchmark jobs from compositor/other-client jobs.

`idle-pm-160.jsonl` records 60 seconds with all sampled GPU runtime states
suspended; GPU 45-46 C, A55 47-49 C, individual M3 sensors 45-48 C.
The PMU completed seven further power-offs during that interval.

The #162 CPU thermal table adds the existing 1469 MHz / 850 mV point at 84 C
between 1794 and 1066 MHz. The 88 C cap remains unchanged. This addresses
the repeated large frequency drops observed on #157/#160.

## Final #162 device validation

`sustained-162.jsonl`: 30 seconds idle, **120 seconds of all eight CPU cores
checking SHA-256 concurrently with GPU rendering**, followed by 40 seconds
cooldown. All eight workers passed; GPU exited 0 (scene score 931). The full
timestamp-bounded log, including cooldown, had no CPUfreq errors or GPU faults.
The 1469 MHz level was used under load; the existing 88 C protection also
remained effective. This is not evidence of unlimited sustained peak clocks.

| Phase | M3 die | A55 die | GPU die |
|---|---|---|---|
| Idle before load | 47-48 C | at most 48 C | 46-47 C |
| Highest 2-second load sample | 87 C | 85 C | 77 C |
| After 40-second cooldown | 54 C | 54 C | 53 C |

Battery sensor reported 33.3 C throughout. The faster kernel thermal poll
reached the 88 C M3 and 86 C A55 thresholds and lowered clocks as intended.
The 120-second test is longer than the earlier 40-second comparison; do not
interpret its score or peak temperatures as a controlled percentage gain.

`gpu-readback-162.json`: the physical Mali-G72 uploaded and rendered 30
different 512x512 RGBA patterns, then returned each pixel to the CPU for exact
comparison. **30 MiB compared, zero mismatched bytes.** EGL context, shaders
and textures stayed allocated across idle intervals. PMU power-on and
power-off counters each increased by 32; the kernel fault delta was empty.
This validates preservation of live graphics resources across full G3D idle
for this workload, beyond simply checking that a benchmark exits successfully.

Final live checks: kernel #162, GNOME active, CPUs 0-7 online, capacities
368/1024, boost off, CPU idle floor on, GPU step voltage on, automatic G3D
power-off on. The PMIC read back 850000 uV at the low OPP. The domain was
observed in `off-0`, and its successful shutdown counter reached 68.

## Remaining limitations

- No validated deep CPU idle; WFI only. Suspend and hotplug need distinct
  diagnosis, not the assumption that they share a resume entry.
- GPU job faults are not globally fixed. Power-off/resume now works, but the
  two post-load faults on #160 still need client/job-level diagnosis.
- CPU PLL code still has unbounded external-mux waits and advisory STABLE
  timeouts. The rejected internal-mux rewrite caused boot failures; it must
  not be reintroduced without resolving the clock-controller contract.
- No registered CPU energy model or validated MIF/INT DVFS. Do not fabricate
  power costs, DRAM timings or a battery-life estimate.
- Kernel build and a short clean graphics run do not prove sustained desktop
  correctness, suspend/resume, or thermal behavior under every workload.
