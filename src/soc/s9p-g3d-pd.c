// SPDX-License-Identifier: GPL-2.0
/*
 * G3D (Mali-G72) power domain of the Samsung Exynos 9810.
 *
 * Switching the domain is more than the PMU write the generic Exynos
 * power-domain driver does. The vendor sequence (flexpmu_cal_local_exynos9810.h,
 * embedded_g3d_on/off) also drives the always-on CMU_G3D block, and after
 * power-up the domain's TrustZone protection controller has to be restored by
 * the EL3 monitor (pmucal_local_enable -> exynos_pd_tz_restore, the
 * "need_smc" property of the vendor device tree). Without that SMC the first
 * non-secure access to the GPU registers is refused by the bus, which on this
 * SoC is an SError, not an error return.
 *
 *   on:  PLL_CON2_PLL_G3D = 0x30000003
 *        PLL_CON0_PLL_G3D |= MUX_SEL (bit 4)
 *        PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER |= MUX_SEL (bit 4)
 *        PMU EMBEDDED_G3D_CONFIGURATION = 0xf, wait STATUS == 0xf
 *        SMC 0x82000410(1, 0x17410204, 0)
 *   off: the reverse, PLL_CON2 = 0x10000001
 *
 * The vendor programs the PLL itself through its DVFS code; here the rate is
 * fixed at PLL_G3D = 260 MHz (M=400, P=10, S=2 on a 26 MHz reference), the
 * frequency the vendor GPU driver starts on before DVFS takes over, so it is
 * safe at the voltage the bootloader leaves on VDD_G3D. The bus dividers get
 * the vendor's blk_g3d values (BUSD = PLL/1, BUSP = BUSD/4).
 */
#include <linux/arm-smccc.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_domain.h>
#include <linux/soc/samsung/s9p-acpm.h>

/* PMU, relative to EMBEDDED_G3D_CONFIGURATION (0x14064040) */
#define G3D_CONFIGURATION	0x0
#define G3D_STATUS		0x4
#define G3D_LOCAL_PWR_CFG	0xf

/* CMU_G3D at 0x17400000 */
#define PLL_LOCKTIME_PLL_G3D		0x0000
#define PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER 0x0100
#define PLL_CON0_PLL_G3D		0x0140
#define  PLL_CON0_ENABLE			BIT(31)
#define  PLL_CON0_STABLE			BIT(29)
#define  PLL_CON0_MDIV(m)			(((m) & 0x3ff) << 16)
#define  PLL_CON0_PDIV(p)			(((p) & 0x3f) << 8)
#define  PLL_CON0_SDIV(s)			((s) & 0x7)
#define  PLL_CON0_PMS_MASK			(PLL_CON0_MDIV(0x3ff) | \
						 PLL_CON0_PDIV(0x3f) | PLL_CON0_SDIV(7))
#define  PLL_CON0_MUX_SEL			BIT(4)
#define PLL_CON2_PLL_G3D		0x0148
#define CLK_CON_MUX_MUX_CLK_G3D_BUSD	0x1000
#define CLK_CON_DIV_DIV_CLK_G3D_BUSD	0x1800
#define CLK_CON_DIV_DIV_CLK_G3D_BUSP	0x1804
#define  CLK_CON_BUSY				BIT(16)

#define SMC_CMD_PREPARE_PD_ONOFF	0x82000410
#define EXYNOS_GET_IN_PD_DOWN	0
#define EXYNOS_WAKEUP_PD_DOWN		1
#define G3D_TZPC_RESTORE_ADDR		0x17410204

/* 26 MHz * M / (P * 2^S): 400/10/4 -> 260 MHz, VCO 1040 MHz (spec 600..1200) */
static unsigned int s9p_g3d_m = 400, s9p_g3d_p = 10, s9p_g3d_s = 2;
module_param_named(pll_m, s9p_g3d_m, uint, 0444);
module_param_named(pll_p, s9p_g3d_p, uint, 0444);
module_param_named(pll_s, s9p_g3d_s, uint, 0444);

static bool s9p_g3d_smc = true;
module_param_named(smc, s9p_g3d_smc, bool, 0444);
MODULE_PARM_DESC(smc, "restore the G3D TrustZone protection through EL3 after power-up");

/*
 * The bootloader hands the domain over switched on. Runtime PM may now cut
 * power after the vendor LPM prerequisites and secure-save step. Keep this
 * override for recovery; a failed power-off also enables it automatically.
 */
static bool s9p_g3d_always_on;
module_param_named(always_on, s9p_g3d_always_on, bool, 0644);
MODULE_PARM_DESC(always_on, "veto domain power-off for recovery; default permits runtime PM");
static unsigned int s9p_g3d_power_ons, s9p_g3d_power_offs;
module_param_named(power_ons, s9p_g3d_power_ons, uint, 0444);
module_param_named(power_offs, s9p_g3d_power_offs, uint, 0444);

struct s9p_g3d_pd {
	struct generic_pm_domain pd;
	struct device *dev;
	void __iomem *pmu;
	void __iomem *cmu;
	void __iomem *pmu_global;
	bool initialized;
	bool low_power_initialized;
};

static inline void rmw(void __iomem *reg, u32 clear, u32 set)
{
	writel((readl(reg) & ~clear) | set, reg);
}

/* G3D entries from Samsung's pmucal_lpm_init, not the on/off table.
 * sboot leaves 4690=1, 4680=3, 4684=fff and both SYS_PWR bit0s clear.
 * #155 stopped at partial STATUS=002f000e without these prerequisites;
 * #160 completed power-off/on after applying them and secure-save. */
static void s9p_g3d_low_power_init(struct s9p_g3d_pd *g)
{
	if (g->low_power_initialized)
		return;
	rmw(g->pmu_global + 0x4690, 0x3, 0x2); /* MEMORY_EMBEDDED_G3D_OPTION */
	rmw(g->pmu_global + 0x4680, BIT(1), 0); /* PWR_EMBEDDED_G3D_OPTION */
	rmw(g->pmu_global + 0x4684, 0xfff, 0x363); /* PWR duration */
	rmw(g->pmu_global + 0x15a8, 0, BIT(0)); /* SCI_CRPPORTPWRDN */
	rmw(g->pmu_global + 0x15ac, 0, BIT(0)); /* PWR_EMBEDDED_G3D */
	g->low_power_initialized = true;
	dev_info(g->dev, "G3D LPM init: memory=%08x option=%08x duration=%08x sci=%08x pwr=%08x\n",
		 readl(g->pmu_global + 0x4690), readl(g->pmu_global + 0x4680),
		 readl(g->pmu_global + 0x4684), readl(g->pmu_global + 0x15a8),
		 readl(g->pmu_global + 0x15ac));
}

static int s9p_g3d_pll_setup(struct s9p_g3d_pd *g)
{
	void __iomem *con0 = g->cmu + PLL_CON0_PLL_G3D;
	u32 v;
	int ret;

	/* program with the PLL output deselected, as the vendor's set_pms does */
	rmw(con0, PLL_CON0_MUX_SEL, 0);
	writel(150 * s9p_g3d_p, g->cmu + PLL_LOCKTIME_PLL_G3D);
	v = readl(con0) & ~PLL_CON0_PMS_MASK;
	v |= PLL_CON0_ENABLE | PLL_CON0_MDIV(s9p_g3d_m) |
	     PLL_CON0_PDIV(s9p_g3d_p) | PLL_CON0_SDIV(s9p_g3d_s);
	writel(v, con0);
	ret = readl_poll_timeout(con0, v, v & PLL_CON0_STABLE, 10, 20000);
	dev_info(g->dev, "PLL_G3D: con0=%08x locktime=%08x -> %s (%u MHz)\n",
		 readl(con0), readl(g->cmu + PLL_LOCKTIME_PLL_G3D),
		 ret ? "NOT LOCKED" : "locked",
		 26 * s9p_g3d_m / s9p_g3d_p / (1 << s9p_g3d_s));
	return ret;
}

static int s9p_g3d_power_on(struct generic_pm_domain *pd)
{
	struct s9p_g3d_pd *g = container_of(pd, struct s9p_g3d_pd, pd);
	struct arm_smccc_res res = {};
	u32 v;
	int ret;

	s9p_g3d_domain_lock();

	/* embedded_g3d_on[] */
	writel(0x30000003, g->cmu + PLL_CON2_PLL_G3D);
	/* CMU_G3D survives domain power-off (the vendor save list is empty).
	 * Resetting PMS to 260 MHz on every resume would silently desynchronize
	 * devfreq from the hardware. Bootstrap only when the domain was off at
	 * initial probe; preserve the negotiated rate on every later resume. */
	if (!g->initialized) {
		ret = s9p_g3d_pll_setup(g);
		if (ret)
			goto fail;
	}
	rmw(g->cmu + PLL_CON0_PLL_G3D, 0, PLL_CON0_MUX_SEL);
	rmw(g->cmu + PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER, 0, PLL_CON0_MUX_SEL);
	writel(G3D_LOCAL_PWR_CFG, g->pmu + G3D_CONFIGURATION);
	ret = readl_poll_timeout(g->pmu + G3D_STATUS, v,
				 (v & G3D_LOCAL_PWR_CFG) == G3D_LOCAL_PWR_CFG,
				 10, 10000);
	if (ret) {
		dev_err(g->dev, "power-up timed out, STATUS=%08x\n", v);
		goto fail;
	}

	if (s9p_g3d_smc) {
		arm_smccc_smc(SMC_CMD_PREPARE_PD_ONOFF, EXYNOS_WAKEUP_PD_DOWN,
			      G3D_TZPC_RESTORE_ADDR, 0, 0, 0, 0, 0, &res);
		if (res.a0) {
			dev_err(g->dev, "TZPC restore failed: %ld\n", (long)res.a0);
			ret = -EIO;
			goto fail;
		}
	}

	/* blk_g3d: BUSD = PLL_G3D / 1, BUSP = BUSD / 4 */
	if (!g->initialized) {
		writel(0, g->cmu + CLK_CON_MUX_MUX_CLK_G3D_BUSD);
		writel(0, g->cmu + CLK_CON_DIV_DIV_CLK_G3D_BUSD);
		writel(3, g->cmu + CLK_CON_DIV_DIV_CLK_G3D_BUSP);
		ret = readl_poll_timeout(g->cmu + CLK_CON_DIV_DIV_CLK_G3D_BUSP,
				v, !(v & CLK_CON_BUSY), 1, 1000);
		if (ret)
			goto fail;
	}
	g->initialized = true;
	s9p_g3d_power_ons++;
	s9p_g3d_domain_unlock(true);

	dev_dbg(g->dev, "on: STATUS=%08x con0=%08x con2=%08x user=%08x busd=%08x/%08x busp=%08x\n",
		 readl(g->pmu + G3D_STATUS), readl(g->cmu + PLL_CON0_PLL_G3D),
		 readl(g->cmu + PLL_CON2_PLL_G3D),
		 readl(g->cmu + PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER),
		 readl(g->cmu + CLK_CON_MUX_MUX_CLK_G3D_BUSD),
		 readl(g->cmu + CLK_CON_DIV_DIV_CLK_G3D_BUSD),
		 readl(g->cmu + CLK_CON_DIV_DIV_CLK_G3D_BUSP));
	return 0;
fail:
	s9p_g3d_domain_unlock(false);
	return ret;
}

static int s9p_g3d_power_off(struct generic_pm_domain *pd)
{
	struct s9p_g3d_pd *g = container_of(pd, struct s9p_g3d_pd, pd);
	struct arm_smccc_res res = {};
	u32 v;
	int ret, rollback;

	/* A runtime recovery override can veto subsequent power-off attempts. */
	if (READ_ONCE(s9p_g3d_always_on))
		return -EBUSY;
	s9p_g3d_domain_lock();
	s9p_g3d_low_power_init(g);

	/* pmucal_local_disable() saves secure protection BEFORE cutting power;
	 * its matching restore call alone cannot reconstruct that state. */
	if (s9p_g3d_smc) {
		arm_smccc_smc(SMC_CMD_PREPARE_PD_ONOFF, EXYNOS_GET_IN_PD_DOWN,
			      G3D_TZPC_RESTORE_ADDR, 0, 0, 0, 0, 0, &res);
		if (res.a0) {
			dev_err(g->dev, "TZPC save failed: %ld\n", (long)res.a0);
			s9p_g3d_domain_unlock(true);
			return -EIO;
		}
	}

	/* embedded_g3d_off[] */
	writel(0, g->pmu + G3D_CONFIGURATION);
	ret = readl_poll_timeout(g->pmu + G3D_STATUS, v,
				 !(v & G3D_LOCAL_PWR_CFG), 10, 10000);
	if (ret) {
		dev_err(g->dev, "power-down timed out, STATUS=%08x\n", v);
		/* A partial power-off is NOT an accessible powered domain. Restore
		 * all power bits and secure protection before allowing any MMIO. */
		writel(G3D_LOCAL_PWR_CFG, g->pmu + G3D_CONFIGURATION);
		rollback = readl_poll_timeout(g->pmu + G3D_STATUS, v,
			(v & G3D_LOCAL_PWR_CFG) == G3D_LOCAL_PWR_CFG, 10, 10000);
		if (!rollback && s9p_g3d_smc) {
			arm_smccc_smc(SMC_CMD_PREPARE_PD_ONOFF, EXYNOS_WAKEUP_PD_DOWN,
				      G3D_TZPC_RESTORE_ADDR, 0, 0, 0, 0, 0, &res);
			if (res.a0)
				rollback = -EIO;
		}
		WRITE_ONCE(s9p_g3d_always_on, true);
		if (rollback) {
			s9p_g3d_domain_unlock(false);
			/* Runtime callers cannot safely resume a partially powered
			 * GPU. Preserve a precise pstore report instead of an SError. */
			panic("s9p-g3d: power-off rollback failed (%d), STATUS=%08x", rollback, v);
		}
		s9p_g3d_domain_unlock(true);
		return ret;
	}
	rmw(g->cmu + PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER, PLL_CON0_MUX_SEL, 0);
	rmw(g->cmu + PLL_CON0_PLL_G3D, PLL_CON0_MUX_SEL, 0);
	writel(0x10000001, g->cmu + PLL_CON2_PLL_G3D);
	s9p_g3d_power_offs++;
	s9p_g3d_domain_unlock(false);
	dev_dbg(g->dev, "off: STATUS=%08x\n", readl(g->pmu + G3D_STATUS));
	return ret;
}

static int s9p_g3d_pd_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct s9p_g3d_pd *g;
	bool on;
	int ret;

	g = devm_kzalloc(dev, sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;
	g->dev = dev;

	/*
	 * Plain ioremap, no region request: the PMU window belongs to the
	 * pmu_system_controller syscon, which has already claimed it.
	 */
	for (ret = 0; ret < 3; ret++) {
		struct resource *res = platform_get_resource(pdev, IORESOURCE_MEM, ret);
		void __iomem *m;

		if (!res)
			return -EINVAL;
		m = devm_ioremap(dev, res->start, resource_size(res));
		if (!m)
			return -ENOMEM;
		if (ret == 0)
			g->pmu = m;
		else if (ret == 1)
			g->cmu = m;
		else
			g->pmu_global = m;
	}

	g->pd.name = "G3D";
	g->pd.power_on = s9p_g3d_power_on;
	g->pd.power_off = s9p_g3d_power_off;
	on = (readl(g->pmu + G3D_STATUS) & G3D_LOCAL_PWR_CFG) == G3D_LOCAL_PWR_CFG;
	g->initialized = on;
	dev_info(dev, "G3D domain is %s at boot (STATUS=%08x, con0=%08x user=%08x)%s\n",
		 on ? "on" : "off", readl(g->pmu + G3D_STATUS),
		 readl(g->cmu + PLL_CON0_PLL_G3D),
		 readl(g->cmu + PLL_CON0_MUX_CLKCMU_EMBEDDED_G3D_USER),
		 s9p_g3d_always_on ? ", kept always on" : "");
	if (!on && s9p_g3d_always_on) {
		ret = s9p_g3d_power_on(&g->pd);
		if (ret)
			return ret;
		on = true;
	}

	ret = pm_genpd_init(&g->pd, NULL, !on);
	if (ret)
		return ret;
	ret = of_genpd_add_provider_simple(dev->of_node, &g->pd);
	if (ret)
		pm_genpd_remove(&g->pd);
	return ret;
}

static const struct of_device_id s9p_g3d_pd_of_match[] = {
	{ .compatible = "samsung,exynos9810-g3d-pd" },
	{ }
};

static struct platform_driver s9p_g3d_pd_driver = {
	.probe	= s9p_g3d_pd_probe,
	.driver	= {
		.name			= "s9p-g3d-pd",
		.of_match_table		= s9p_g3d_pd_of_match,
		.suppress_bind_attrs	= true,
	},
};
builtin_platform_driver(s9p_g3d_pd_driver);
