// SPDX-License-Identifier: GPL-2.0
/*
 * Mali-G72 (G3D) clock for the Exynos 9810: the stock maximum by default,
 * lower stock points for the thermal cap in s9p-cpufreq.
 *
 * The stock GPU DVFS tops out at 572 MHz (M=286, P=13, S=0 on the 26 MHz
 * OSC) at 950 mV on S2MPS18 BUCK6 -- the table in the stock device tree ends
 * there. sboot leaves the GPU at 260 MHz on 644 mV, a combination on which
 * Panfrost throws DATA_INVALID_FAULTs every few seconds.
 *
 * This moves the validated s9p-cpuclk/s9p-touch-power sequence into the
 * kernel: BUCK6 to 950 mV through the APM firmware, then the PLL_G3D relock
 * with the vendor quirk that PLL_CON2 must hold 0x30000003 while it locks
 * (sboot's 0x10000001 keeps the PLL from ever reaching STABLE). BUCK6 stays
 * at 950 mV on every step: the lower steps exist to shed heat, and the
 * voltage is the conservative baseline; faults still occur at 950 mV and
 * must not be attributed to undervolting without an isolated comparison.
 *
 * The APM answers only some time after boot, so the initial step is retried
 * from a delayed work until it goes through.
 *
 * The block is also a clock provider, which is what lets Panfrost run its own
 * devfreq on the GPU: without it the DT could only describe a fixed 26 MHz
 * clock, Panfrost found no operating points and the PLL stayed at its maximum
 * for the whole uptime -- 572 MHz on 950 mV while the desktop is idle.
 *
 * Three independent numbers decide the rate, and the lowest wins:
 *
 *   g3d_req_khz      what the clock consumer (devfreq) asks for
 *   g3d_thermal_khz  the cap s9p-cpufreq's TMU poll puts on
 *   g3d_max_khz      the user's ceiling (the power-saving profiles)
 */
#include <linux/clk-provider.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include <linux/soc/samsung/s9p-acpm.h>

/* CMU_G3D */
#define PLL_LOCKTIME_PLL_G3D	0x17400000
#define PLL_CON0_PLL_G3D	0x17400140
#define PLL_CON2_PLL_G3D	0x17400148

#define PLL_CON0_ENABLE		BIT(31)
#define PLL_CON0_STABLE		BIT(29)
#define PLL_CON0_PMS_MASK	((0x3ffu << 16) | (0x3fu << 8) | 0x7u)
#define PLL_CON0_MUX_SEL	BIT(4)
#define PLL_CON0_MUX_BUSY	BIT(7) /* Samsung CAL ra.h; bit 16 is MDIV[0] */

/* BUCK6 (vdd_g3d): 300 mV + sel * 6.25 mV -> 0x68 = 950 mV */
#define G3D_BUCK6_REG		0x2b
#define G3D_VSEL_950MV		0x68

struct s9p_g3d_step {
	unsigned int khz;
	u16 m;
	u8 p, s;
	u8 vsel;
};

/*
 * Stock clock points, validated on this device by the userspace governor,
 * each with its own rail voltage.
 *
 * The voltages are deliberately conservative. sboot's own combination is
 * 260 MHz on 644 mV and Panfrost throws DATA_INVALID_FAULTs on it, which is
 * why this driver used to hold 950 mV at every step. But holding the top
 * voltage while the GPU sits at its lowest clock -- which is where devfreq
 * leaves it whenever the desktop is quiet -- pays leakage for nothing, and
 * leakage is what makes this phone warm when it is doing nothing at all.
 *
 * 850 mV at 260 MHz is 206 mV above the combination that faults and 100 mV
 * below the conservative baseline. The rail is raised before the clock goes up
 * and lowered only after it has come down, the same ordering s9p-cpufreq
 * uses for the CPU clusters.
 */
static const struct s9p_g3d_step s9p_g3d_steps[] = {
	{ 572000, 286, 13, 0, 0x68 },	/* stock maximum, 950 mV */
	{ 455000, 455, 26, 0, 0x60 },	/*              900 mV */
	{ 260000, 160,  4, 2, 0x58 },	/* sboot's clock, 850 mV */
};

static void __iomem *g3d_con0;
static void __iomem *g3d_con2;
static void __iomem *g3d_locktime;
static DEFINE_MUTEX(g3d_lock);
static bool g3d_rail_set;
static bool g3d_domain_powered = true;
static unsigned int g3d_cur_khz;
/* the three requests; the applied rate is the lowest of them */
static unsigned int g3d_req_khz = 572000;
static unsigned int g3d_thermal_khz = 572000;
static unsigned int g3d_max_khz = 572000;

module_param_named(cur_khz, g3d_cur_khz, uint, 0444);
MODULE_PARM_DESC(cur_khz, "current G3D clock (kHz), read-only");

/*
 * Per-step rail voltage, enabled after #159's OPP/PMIC readback validation.
 *
 * With it off the rail stays at 950 mV. With it on the table applies the
 * voltage per step. The recovered #150 image used these step voltages;
 * #155/#157 deliberately use constant voltage to isolate other GPU faults.
 * Runtime changes must adjust the live rail under the clock mutex: a plain
 * bool parameter could disable voltage scaling at 850 mV, then let a later
 * 572 MHz transition run without raising the rail to 950 mV.
 *
 * Off by default since 2026-09-23, together with s9p_cpufreq.idle_floor:
 * both lower voltages only while idle, and with both on the phone froze
 * about once a day when left alone.
 */
static bool g3d_step_volt;

static const struct s9p_g3d_step *s9p_g3d_find(unsigned int khz)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(s9p_g3d_steps); i++)
		if (s9p_g3d_steps[i].khz == khz)
			return &s9p_g3d_steps[i];
	return NULL;
}

static int s9p_g3d_step_volt_set(const char *val, const struct kernel_param *kp)
{
	const struct s9p_g3d_step *st;
	bool enable;
	int ret;

	ret = kstrtobool(val, &enable);
	if (ret)
		return ret;
	mutex_lock(&g3d_lock);
	if (enable != g3d_step_volt && g3d_rail_set) {
		st = s9p_g3d_find(g3d_cur_khz);
		if (!st) {
			ret = -EIO;
			goto out;
		}
		ret = s9p_acpm_pmic_write(G3D_BUCK6_REG,
					 enable ? st->vsel : G3D_VSEL_950MV);
		if (ret)
			goto out;
		udelay(200);
	}
	g3d_step_volt = enable;
out:
	mutex_unlock(&g3d_lock);
	return ret;
}

static const struct kernel_param_ops s9p_g3d_step_volt_ops = {
	.set = s9p_g3d_step_volt_set,
	.get = param_get_bool,
};
module_param_cb(step_volt, &s9p_g3d_step_volt_ops, &g3d_step_volt, 0644);
MODULE_PARM_DESC(step_volt, "apply the voltage of each G3D clock step; disabling restores 950 mV");

/* Read the actual PMIC setting through the serialized ACPM driver. This is
 * a programmed rail value, not a voltage measurement at the silicon. */
static int s9p_g3d_rail_uv_get(char *buffer, const struct kernel_param *kp)
{
	u8 value;
	int ret;

	mutex_lock(&g3d_lock);
	ret = s9p_acpm_pmic_read(G3D_BUCK6_REG, &value);
	mutex_unlock(&g3d_lock);
	if (ret)
		return ret;
	return scnprintf(buffer, 32, "%u\n", 300000u + value * 6250u);
}

static const struct kernel_param_ops s9p_g3d_rail_uv_ops = {
	.get = s9p_g3d_rail_uv_get,
};
module_param_cb(rail_uv, &s9p_g3d_rail_uv_ops, NULL, 0444);
MODULE_PARM_DESC(rail_uv, "BUCK6 programmed voltage in microvolts (PMIC readback)");

static bool s9p_g3d_pll_is(const struct s9p_g3d_step *st)
{
	u32 v = readl_relaxed(g3d_con0);

	return ((v >> 16) & 0x3ff) == st->m && ((v >> 8) & 0x3f) == st->p &&
	       (v & 0x7) == st->s && (v & PLL_CON0_MUX_SEL);
}

/* caller holds g3d_lock */
static int s9p_g3d_set_pll(const struct s9p_g3d_step *st)
{
	u32 v, old_con0 = readl(g3d_con0), old_locktime = readl(g3d_locktime);
	int ret, rollback;
	/* decided before the PLL moves: afterwards the clock already reads as
	 * the target and a downward step would never lower the rail */
	bool up = g3d_cur_khz < st->khz;

	if (g3d_step_volt && up && g3d_rail_set) {
		ret = s9p_acpm_pmic_write(G3D_BUCK6_REG, st->vsel);
		if (ret) {
			pr_err_ratelimited("s9p-g3d: BUCK6 write for %u kHz failed (%d)\n",
					   st->khz, ret);
			return ret;
		}
		udelay(200);
	}

	writel_relaxed(0x30000003, g3d_con2);
	writel_relaxed((u32)st->p * 150, g3d_locktime);

	/*
	 * Hand the block to the oscillator BEFORE the PLL stops, as a step of
	 * its own.
	 *
	 * Clearing MUX_SEL and PLL_CON0_ENABLE in one write, which is what
	 * this did, leaves a window in which the mux has not finished moving
	 * and the PLL is already down -- the G3D block briefly has no clock at
	 * all. A GPU job in flight across that window comes back as
	 * JOB_BUS_FAULT or DATA_INVALID_FAULT, and once Panfrost's devfreq
	 * started changing the rate by itself those faults landed within
	 * milliseconds of every single rate change (measured in dmesg: each
	 * fault sits between two "G72 at ... MHz" lines). The cluster PLLs in
	 * s9p-cpufreq have always done it in two steps with a busy poll; this
	 * is the same sequence.
	 */
	v = readl_relaxed(g3d_con0) & ~PLL_CON0_MUX_SEL;
	writel_relaxed(v, g3d_con0);
	ret = readl_poll_timeout_atomic(g3d_con0, v, !(v & PLL_CON0_MUX_BUSY),
				  1, 1000);
	if (ret)
		goto restore;

	/* only now may the PLL go down and be reprogrammed */
	v = readl_relaxed(g3d_con0) & ~(PLL_CON0_ENABLE | PLL_CON0_PMS_MASK);
	writel_relaxed(v, g3d_con0);
	writel_relaxed(v | ((u32)st->m << 16) | ((u32)st->p << 8) | st->s,
		       g3d_con0);
	writel_relaxed(v | PLL_CON0_ENABLE | ((u32)st->m << 16) |
		       ((u32)st->p << 8) | st->s, g3d_con0);

	ret = readl_poll_timeout(g3d_con0, v, v & PLL_CON0_STABLE, 10, 20000);
	if (ret) {
		pr_err("s9p-g3d: PLL_G3D did not lock for %u kHz (con0=%08x)\n",
		       st->khz, v);
		goto restore;
	}

	/* back onto the PLL, again waiting for the mux to settle */
	writel_relaxed(readl_relaxed(g3d_con0) | PLL_CON0_MUX_SEL, g3d_con0);
	ret = readl_poll_timeout_atomic(g3d_con0, v, !(v & PLL_CON0_MUX_BUSY),
				  1, 1000);
	if (ret || !s9p_g3d_pll_is(st)) {
		ret = ret ?: -EIO;
		goto restore;
	}
	g3d_cur_khz = st->khz;

	/* down: the rail follows the clock, never leads it */
	if (g3d_step_volt && !up && g3d_rail_set) {
		ret = s9p_acpm_pmic_write(G3D_BUCK6_REG, st->vsel);
		if (ret)
			pr_err_ratelimited("s9p-g3d: BUCK6 write for %u kHz failed (%d)\n",
					   st->khz, ret);
	}
	return 0;

restore:
	writel(readl(g3d_con0) & ~PLL_CON0_MUX_SEL, g3d_con0);
	rollback = readl_poll_timeout_atomic(g3d_con0, v,
					    !(v & PLL_CON0_MUX_BUSY), 1, 1000);
	if (!rollback) {
		writel(v & ~PLL_CON0_ENABLE, g3d_con0);
		writel(old_locktime, g3d_locktime);
		writel(old_con0 & ~PLL_CON0_MUX_SEL, g3d_con0);
		rollback = readl_poll_timeout(g3d_con0, v,
					    v & PLL_CON0_STABLE, 10, 20000);
	}
	if (!rollback) {
		writel(old_con0, g3d_con0);
		rollback = readl_poll_timeout_atomic(g3d_con0, v,
					!(v & PLL_CON0_MUX_BUSY), 1, 1000);
	}
	if (rollback) {
		g3d_cur_khz = 26000;
		pr_crit("s9p-g3d: PLL rollback failed (%d), con0=%08x\n", rollback, v);
	}
	return ret;
}

/* highest stock step at or below khz */
static const struct s9p_g3d_step *s9p_g3d_step_below(unsigned int khz)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(s9p_g3d_steps); i++)
		if (s9p_g3d_steps[i].khz <= khz)
			return &s9p_g3d_steps[i];
	return &s9p_g3d_steps[ARRAY_SIZE(s9p_g3d_steps) - 1];
}

/* caller holds g3d_lock; applies min(thermal request, user ceiling) */
static int s9p_g3d_apply(void)
{
	const struct s9p_g3d_step *st =
		s9p_g3d_step_below(min3(g3d_req_khz, g3d_thermal_khz,
					g3d_max_khz));
	int ret = 0;

	/* Keep requests while the consumer is suspended. The power-domain
	 * callback applies them before Panfrost can access the GPU again. */
	if (!g3d_domain_powered)
		return 0;

	if (s9p_g3d_pll_is(st))
		g3d_cur_khz = st->khz;
	else
		ret = s9p_g3d_set_pll(st);
	if (!ret)
		pr_debug("s9p-g3d: G72 at %u MHz\n", st->khz / 1000);
	return ret;
}

void s9p_g3d_domain_lock(void)
{
	mutex_lock(&g3d_lock);
}
EXPORT_SYMBOL_GPL(s9p_g3d_domain_lock);

void s9p_g3d_domain_unlock(bool powered)
{
	int ret;

	g3d_domain_powered = powered;
	if (powered && g3d_con0 && g3d_rail_set) {
		ret = s9p_g3d_apply();
		if (ret)
			pr_err_ratelimited("s9p-g3d: deferred clock request failed after power-on (%d)\n", ret);
	}
	mutex_unlock(&g3d_lock);
}
EXPORT_SYMBOL_GPL(s9p_g3d_domain_unlock);

/* the thermal cap from s9p-cpufreq's TMU poll */
int s9p_g3d_set_khz(unsigned int khz)
{
	int ret;

	if (!s9p_g3d_find(khz))
		return -EINVAL;
	if (!g3d_con0 || !g3d_rail_set)
		return -EAGAIN;

	mutex_lock(&g3d_lock);
	g3d_thermal_khz = khz;
	ret = s9p_g3d_apply();
	mutex_unlock(&g3d_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(s9p_g3d_set_khz);

/*
 * /sys/module/s9p_g3d/parameters/max_khz: a ceiling the power-saving mode
 * puts on top of the thermal cap. Any value is accepted and rounded down to
 * the next stock step; the lowest step is the floor.
 */
static int s9p_g3d_max_set(const char *val, const struct kernel_param *kp)
{
	unsigned int khz;
	int ret;

	ret = kstrtouint(val, 0, &khz);
	if (ret)
		return ret;

	mutex_lock(&g3d_lock);
	g3d_max_khz = s9p_g3d_step_below(khz)->khz;
	if (g3d_con0 && g3d_rail_set)
		ret = s9p_g3d_apply();
	mutex_unlock(&g3d_lock);
	return ret;
}

static const struct kernel_param_ops s9p_g3d_max_ops = {
	.set = s9p_g3d_max_set,
	.get = param_get_uint,
};
module_param_cb(max_khz, &s9p_g3d_max_ops, &g3d_max_khz, 0644);
MODULE_PARM_DESC(max_khz, "user ceiling on the G3D clock (kHz), rounded down to a stock step");

unsigned int s9p_g3d_get_khz(void)
{
	return g3d_cur_khz;
}
EXPORT_SYMBOL_GPL(s9p_g3d_get_khz);

/* ------------------------------------------------------- clock provider */

/*
 * Panfrost's devfreq drives the GPU through the clock framework, so the PLL
 * is published as a clock. Only the stock steps exist; round_rate reports
 * the one that will actually be used, so the OPP layer never believes it got
 * a rate the hardware cannot produce.
 *
 * enable/disable are deliberately absent: the PLL feeds the whole G3D block
 * and the power domain driver owns whether that block is alive at all.
 */
static unsigned long s9p_g3d_clk_recalc(struct clk_hw *hw, unsigned long parent)
{
	return (unsigned long)g3d_cur_khz * 1000;
}

static int s9p_g3d_clk_determine(struct clk_hw *hw,
				 struct clk_rate_request *req)
{
	req->rate = (unsigned long)s9p_g3d_step_below(req->rate / 1000)->khz *
		    1000;
	return 0;
}

static int s9p_g3d_clk_set(struct clk_hw *hw, unsigned long rate,
			   unsigned long parent)
{
	int ret;

	/*
	 * Until the APM has put BUCK6 on 950 mV the GPU may not leave the
	 * clock sboot left it on. -EAGAIN makes devfreq keep the old rate
	 * and come back, which is exactly right during the first seconds.
	 */
	if (!g3d_con0 || !g3d_rail_set)
		return -EAGAIN;

	mutex_lock(&g3d_lock);
	g3d_req_khz = s9p_g3d_step_below(rate / 1000)->khz;
	ret = s9p_g3d_apply();
	mutex_unlock(&g3d_lock);
	return ret;
}

static const struct clk_ops s9p_g3d_clk_ops = {
	.recalc_rate = s9p_g3d_clk_recalc,
	.determine_rate = s9p_g3d_clk_determine,
	.set_rate = s9p_g3d_clk_set,
};

static struct clk_hw s9p_g3d_clk_hw = {
	.init = &(struct clk_init_data){
		.name = "g3d",
		.ops = &s9p_g3d_clk_ops,
		.num_parents = 0,
		/*
		 * The thermal cap and the user's ceiling move this PLL without
		 * going through the clock framework, so a cached rate goes
		 * stale. Without this, Panfrost read the rate once at probe
		 * (sboot's 260 MHz), believed it for the rest of the uptime,
		 * and devfreq never asked for the step it was already on --
		 * the GPU stayed at 572 MHz on an idle desktop.
		 */
		.flags = CLK_GET_RATE_NOCACHE,
	},
};

/*
 * A platform driver on the clock node, not an initcall, and the order inside
 * probe is the whole point: the rail goes to 950 mV BEFORE the clock is
 * published.
 *
 * Panfrost cannot probe until this clock exists, so publishing it last is
 * what keeps Panfrost away from a GPU that is still on sboot's 260 MHz at
 * 644 mV. Two builds that published the clock early and raised the rail from
 * a delayed work a second later hung the boot outright: Panfrost probed at
 * 0.9 s, reset and read the GPU on that combination, and the SoC never came
 * back. The same builds with a late clock booted fine.
 *
 * The APM mailbox is not answering yet when this first runs, hence the short
 * in-probe retry and then -EPROBE_DEFER: the ACPM driver's own probe kicks
 * the deferred queue and the next attempt goes through.
 */
#define G3D_RAIL_POLL_MS	20
#define G3D_RAIL_POLLS		25	/* half a second inside one probe */
#define G3D_RAIL_ATTEMPTS	40	/* then fail instead of publishing an unsafe clock */

static int s9p_g3d_rail_up(struct device *dev)
{
	static unsigned int attempts;
	unsigned int i;
	int ret = -ETIMEDOUT;

	for (i = 0; i < G3D_RAIL_POLLS; i++) {
		ret = s9p_acpm_pmic_write(G3D_BUCK6_REG, G3D_VSEL_950MV);
		if (!ret)
			break;
		msleep(G3D_RAIL_POLL_MS);
	}
	if (ret) {
		if (++attempts < G3D_RAIL_ATTEMPTS)
			return dev_err_probe(dev, -EPROBE_DEFER,
					     "APM has not taken the BUCK6 write yet\n");
		dev_err(dev, "BUCK6 write keeps failing (%d), GPU clock not published\n",
			ret);
		return ret;
	}

	udelay(200);
	g3d_rail_set = true;

	mutex_lock(&g3d_lock);
	ret = s9p_g3d_apply();
	mutex_unlock(&g3d_lock);
	if (!ret)
		dev_info(dev, "G72 at %u MHz on 950 mV\n", g3d_cur_khz / 1000);
	return ret;
}

static int s9p_g3d_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	int ret;

	if (!g3d_con0) {
		g3d_con0 = devm_ioremap(dev, PLL_CON0_PLL_G3D, 0x20);
		g3d_con2 = devm_ioremap(dev, PLL_CON2_PLL_G3D, 0x10);
		g3d_locktime = devm_ioremap(dev, PLL_LOCKTIME_PLL_G3D, 0x10);
		if (!g3d_con0 || !g3d_con2 || !g3d_locktime)
			return -ENOMEM;
		/* whatever sboot left, reported truthfully so the OPP table
		 * has something to match against */
		g3d_cur_khz = s9p_g3d_pll_is(&s9p_g3d_steps[0]) ?
			      s9p_g3d_steps[0].khz : s9p_g3d_steps[2].khz;
	}

	ret = s9p_g3d_rail_up(dev);
	if (ret)
		return ret;

	ret = devm_clk_hw_register(dev, &s9p_g3d_clk_hw);
	if (ret)
		return dev_err_probe(dev, ret, "clk_hw_register\n");

	return devm_of_clk_add_hw_provider(dev, of_clk_hw_simple_get,
					   &s9p_g3d_clk_hw);
}

static const struct of_device_id s9p_g3d_of_match[] = {
	{ .compatible = "samsung,exynos9810-g3d-clock" },
	{ }
};
MODULE_DEVICE_TABLE(of, s9p_g3d_of_match);

static struct platform_driver s9p_g3d_driver = {
	.driver = {
		.name = "s9p-g3d",
		.of_match_table = s9p_g3d_of_match,
	},
	.probe = s9p_g3d_probe,
};
module_platform_driver(s9p_g3d_driver);

MODULE_DESCRIPTION("Exynos 9810 G3D stock clock steps");
MODULE_LICENSE("GPL v2");
