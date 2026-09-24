/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ACPM MFD (S2MPS18 over the APM "speedy" bus) access, Exynos 9810.
 * Implemented in drivers/soc/samsung/s9p-acpm.c; the G3D clock steps in
 * drivers/soc/samsung/s9p-g3d.c.
 */
#ifndef _S9P_ACPM_H
#define _S9P_ACPM_H

#include <linux/types.h>

#ifdef CONFIG_S9P_ACPM

int s9p_acpm_pmic_read(u8 reg, u8 *val);
int s9p_acpm_pmic_write(u8 reg, u8 val);
int s9p_acpm_pmic_update(u8 reg, u8 val, u8 mask);
bool s9p_acpm_is_ready(void);

/* Mali-G72 clock: 572000 / 455000 / 260000 kHz (stock points) */
int s9p_g3d_set_khz(unsigned int khz);
unsigned int s9p_g3d_get_khz(void);
/* Serialize genpd's CMU sequence with clock/thermal transitions. */
void s9p_g3d_domain_lock(void);
void s9p_g3d_domain_unlock(bool powered);

#else

static inline int s9p_acpm_pmic_read(u8 reg, u8 *val) { return -ENODEV; }
static inline int s9p_acpm_pmic_write(u8 reg, u8 val) { return -ENODEV; }
static inline int s9p_acpm_pmic_update(u8 reg, u8 val, u8 mask)
{
	return -ENODEV;
}
static inline bool s9p_acpm_is_ready(void) { return false; }
static inline int s9p_g3d_set_khz(unsigned int khz) { return -ENODEV; }
static inline unsigned int s9p_g3d_get_khz(void) { return 0; }
static inline void s9p_g3d_domain_lock(void) { }
static inline void s9p_g3d_domain_unlock(bool powered) { }

#endif

#endif /* _S9P_ACPM_H */
