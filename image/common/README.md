# The common base system

This directory is identical in the three phone projects
([Galaxy S9+](https://github.com/SheroAbi/galaxy-s9plus-mainline-linux),
[Mi 9T](https://github.com/SheroAbi/mi9t-mainline-linux),
[Redmi 8](https://github.com/SheroAbi/redmi8-mainline-linux)). Every phone
gets the same clean Ubuntu from it; only the kernel and the few files a
phone's hardware needs (`device/` in each project) differ.

## What every image contains

* **Ubuntu 24.04 LTS (noble), arm64**, bootstrapped fresh with debootstrap
  from the official Ubuntu ports mirror. Nothing is copied from a running
  phone.
* **GNOME on Wayland** with GDM, the Ubuntu session, Yaru, the Ubuntu dock,
  Files, Terminal, Text Editor, Settings, System Monitor. No snaps.
* **Firefox** from Mozilla's own APT repository (Ubuntu's `firefox` package
  is only a snap).
* NetworkManager, OpenSSH, Bluetooth (BlueZ), PipeWire, UPower, zram swap.
* Exactly the packages in [`packages.txt`](packages.txt), installed without
  recommends, plus what they strictly depend on.

Nothing else: no extra services, no tools of ours, no settings of ours
beyond the ones below. The optional features of each project are in its
`extras/` and are never installed by the image build.

## Security defaults

* **One user, no default password.** The build asks for the password (or
  takes `IMAGE_PASSWORD`) and refuses anything shorter than 8 characters.
  Only its SHA-512 hash goes into the image.
* **root is locked**, and root can never log in over SSH
  (`PermitRootLogin no`). Use `sudo`.
* **SSH host keys are made on the phone's first boot**
  (`first-boot-ssh-keys.service`), so no two phones, and no two builds,
  share a key. The same goes for `/etc/machine-id`.
* With `SSH_PUBKEY=~/.ssh/id_ed25519.pub`, the key is installed for the user
  and SSH stops accepting passwords altogether.
* The USB network of each phone is a private link between the phone and the
  one PC it is plugged into.

GDM logs the user in automatically, because a phone has no keyboard at the
login screen. The password still protects `sudo`, SSH and the lock screen.

## Settings

All of them are environment variables for `image/build-image.sh`:

| Variable | Default | |
|---|---|---|
| `IMAGE_USER` | `ubuntu` | the login name |
| `IMAGE_PASSWORD` | asked for | at least 8 characters |
| `IMAGE_HOSTNAME` | the device name | |
| `IMAGE_TIMEZONE` | `Etc/UTC` | e.g. `Europe/Berlin` |
| `IMAGE_LOCALE` | `en_US.UTF-8` | e.g. `de_DE.UTF-8` |
| `IMAGE_KEYMAP` | `us` | e.g. `de` |
| `SSH_PUBKEY` | none | a public key file; SSH then accepts only keys |
| `UBUNTU_MIRROR` | `http://ports.ubuntu.com/ubuntu-ports` | |

## First boot

`grow-rootfs.service` grows the root filesystem to its whole partition
(the image is only as large as its content), and the SSH host keys are
created. After that the phone boots straight into GNOME.

## Build host

Ubuntu 24.04 (a VM or WSL2 works), run as root, with:

    sudo apt install debootstrap qemu-user-static binfmt-support e2fsprogs \
        openssl python3 curl git

The device's `image/build-image.sh` names the few extra tools it needs.
