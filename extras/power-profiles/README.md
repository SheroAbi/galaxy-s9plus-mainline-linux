# power-profiles

CPU/GPU ceilings and Wi-Fi power save as three profiles, following GNOME's power mode.

    s9p-power performance|balanced|power-saver   apply and remember
    s9p-power status                              what is in effect

A profile is a ceiling on the two CPU clusters (`scaling_max_freq`), on the
Mali-G72 (`s9p_g3d max_khz`) and the Wi-Fi power-save setting. With
`power-profiles-daemon` running (installed with this feature), the profile
follows GNOME's power mode switch. The kernel's thermal caps stay underneath
either way. `power-saver` caps the big cores at 1066 MHz and the GPU at
455 MHz.
