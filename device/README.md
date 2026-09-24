# Device layer

Two things live here.

**The initramfs init scripts**, built into the kernel image by
`scripts/build/build71.sh`:

| | |
|---|---|
| `mainline-init-boot` | the production init (`INIT=boot`): arms the recovery magic, waits for USERDATA, mounts it and switches to Ubuntu; drops to a rescue shell if anything is missing |
| `mainline-init` | the probe image (default): reports what the kernel found, then panics on purpose |
| `mainline-extra-probe` | opt-in CPU verification and hotplug experiments for the probe image |

**The hardware layer of the image**: what the Galaxy S9+'s root filesystem
carries on top of the common base system
([`../image/common/README.md`](../image/common/README.md)) — only what this
phone's hardware needs. `image/build-image.sh` copies `base/` into the image,
installs `packages.txt` and runs `configure.sh` inside it. The table in
[`../docs/03-installing.md`](../docs/03-installing.md#what-the-image-adds-for-this-phone)
lists every file.

Optional features live in [`../extras/`](../extras/).
