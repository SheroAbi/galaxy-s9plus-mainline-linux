# Device firmware

Binary firmware for hardware on this phone. Not GPL; redistributed as it
shipped on the device.

| File | For | Used by |
|---|---|---|
| `bcmdhd_sta.bin_b2` | BCM4361 Wi-Fi | `build71.sh WLAN=1` installs it as `brcm/brcmfmac4361-pcie.bin` |
| `nvram.txt_r02a_b2` | BCM4361 board NVRAM | installed as `brcm/brcmfmac4361-pcie.txt` (CRLF is stripped — `brcmfmac` rejects it otherwise) |
| `bcmdhd_clm.blob` | BCM4361 regulatory | installed as `brcm/brcmfmac4361-pcie.clm_blob` |
| `regulatory.db`, `regulatory.db.p7s` | cfg80211 | built into the kernel, so there is no loader race at boot |
| `bcm4361B2_semco.hcd` | BCM4361 **Bluetooth** patchram | loaded on the device by `hciattach ... bcm43xx` (unit `overlay/etc/systemd/system/hciattach-bcm4361.service`); copy it to `/lib/firmware/brcm/` |

The same three Wi-Fi files are also staged for the rootfs under
`device/rootfs/lib/firmware/brcm/`, already under their final names, for
installs that load them from disk instead of from the kernel.
