# flight-recorder

Every kernel message plus a state line per minute, fsync'ed to disk.

`/var/log/s9p-blackbox.log` (rotated to `.1` at 4 MB). The journal does not
keep the kernel messages of a boot that hung; this file does. The state line
holds clocks, the GPU rail, temperatures, the idle parameters, Wi-Fi state
and free memory. Useful while hunting the rare idle hangs described in
`docs/06-known-issues.md`; it costs a small amount of flash writes.
