// SPDX-License-Identifier: GPL-2.0
/*
 * PCIe host controller for the Samsung Exynos 9810.
 *
 * The SoC has two DW PCIe root complexes in the FSYS1 block: channel 0 goes
 * to the WiFi module (BCM4361) on this board, channel 1 to the modem and is
 * not described here.
 *
 * There is no clock driver for this SoC. The CMU/FSYS1 gates this controller
 * sits behind are opened by the board's global "s9p,clock-gates" node before
 * this driver runs (addresses listed in its comment, from the vendor
 * cmucal-sfr tables: CMU top 0x1a242074 plus the FSYS1 GOUT ports at
 * 0x11402000-0x1140204c and the Gen2 XIUs at 0x114020b0/0x114020b4). The
 * FSYS1_QCH_CON_PCIE_GEN2_* hint registers are left alone, like the USB
 * port does for its block.
 *
 * The PHY has no struct phy provider either; the driver replays Samsung's
 * own calibration sequence for this exact PHY (pci-exynos9810_cal.c,
 * channel 0 path, table values unchanged) through the PMA/PCS windows and
 * the ELBI reset lines. The vendor's IA (interrupt aggregator) fast path
 * for the CDR reset during L1.2 exits is an L1.2 optimization and is not
 * implemented.
 *
 * Bring-up order mirrors the vendor driver:
 *   PMU PCIE_PHY_CONTROL on -> sysreg snoop bits sharable -> PHY power-down
 *   clear -> soft core reset -> PERST# deassert -> L1/QCH ELBI setup ->
 *   PHY CAL + reset pulses -> (core: setup_rc, iATU) -> LTSSM enable.
 *
 * Legacy INTx only. The BCM4361's firmware never signals MSI (the vendor
 * driver's dhdpcie_chip_support_msi() excludes this chip explicitly, and
 * the stock device tree runs the port with use-msi = "false"), so no MSI
 * controller is registered: the endpoint's pci_enable_msi() fails and
 * brcmfmac falls back to INTA. The controller reports an INTx assertion
 * as a latched pulse bit in ELBI IRQ_PULSE (bit 2*n for INTn), which the
 * chained handler clears and dispatches through a small INTx domain.
 *
 * Firmware (brcmfmac4361-pcie.bin/.txt/.clm_blob) is built into the
 * kernel image, so the driver can be built in and probe before the
 * rootfs is mounted.
 */
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/iopoll.h>
#include <linux/irq.h>
#include <linux/irqchip/chained_irq.h>
#include <linux/irqdomain.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#include "pcie-designware.h"

/* ELBI registers (0x116a0000) */
#define PCIE_IRQ_PULSE			0x000	/* latched pulse sources, W1C */
#define  IRQ_INTX_ASSERT(n)		BIT(2 * (n))
#define  IRQ_INTX_ASSERT_ALL		(IRQ_INTX_ASSERT(0) | IRQ_INTX_ASSERT(1) | \
					 IRQ_INTX_ASSERT(2) | IRQ_INTX_ASSERT(3))
#define PCIE_IRQ_LEVEL			0x004
#define PCIE_IRQ_SPECIAL		0x008
#define PCIE_IRQ_EN_PULSE		0x00c
#define PCIE_IRQ_EN_LEVEL		0x010
#define PCIE_IRQ_EN_SPECIAL		0x014
#define PCIE_SW_WAKE			0x018
#define  PCIE_BUS_EN			BIT(1)
#define PCIE_APP_LTSSM_ENABLE		0x02c
#define  PCIE_ELBI_LTSSM_DISABLE	0x0
#define  PCIE_ELBI_LTSSM_ENABLE		0x1
#define PCIE_ELBI_RDLH_LINKUP		0x074
#define  PCIE_ELBI_XMLH_LINKUP		BIT(4)
#define PCIE_APP_REQ_EXIT_L1_MODE	0x0f4
#define  APP_REQ_EXIT_L1_MODE_HW	BIT(0)
#define  L1_REQ_NAK_CONTROL_MASTER	BIT(4)
#define PCIE_LINKDOWN_RST_CTRL_SEL	0x1b8
#define  PCIE_LINKDOWN_RST_MANUAL	BIT(1)
#define PCIE_SOFT_CORE_RESET		0x1d0
#define PCIE_STATE_HISTORY_CHECK	0x274
#define  HISTORY_BUFFER_ENABLE		0x3
#define PCIE_STATE_POWER_S		0x2bc
#define PCIE_STATE_POWER_M		0x2c0
#define PCIE_QCH_SEL			0x2c8
#define  CLOCK_GATING_ALL		(0xf << 8 | 0xf << 4 | 0xf)
#define PCIE_ELB_PCS_G_RST		0x288
#define PCIE_ELB_PCS_CMN_RST		0x28c
#define PCIE_ELB_MAC_RST		0x290

/* DBI: the controller's own auxiliary (26 MHz) clock frequency, for PM timers */
#define PCIE_AUX_CLK_FREQ		0xb40
#define  PCIE_AUX_CLK_FREQ_26MHZ	0x1a

/* PCS registers (0x116c0000) */
#define PCS_PRGM_TIMEOUT_L1SS		0x0c
#define PCS_CDR_RESET			0xd0
#define  PCS_CDR_RESET_MASK		(0x3 << 6)
#define PCS_RX_ELECIDLE			0xec
#define  PCS_RX_ELECIDLE_IGNORE		BIT(3)
#define PCS_TX_LATENCY			0xf8
#define PCS_REFCLK_OUT_CTRL		0x100
#define  PCS_PWRDN_A			BIT(6)
#define PCS_REFCLK_OUT_CTRL2		0x104
#define  PCS_PWRDN_B			BIT(7)

/* FSYS1 sysreg (syscon at 0x11410000) */
#define FSYS1_PCIE0_PHY_CTRL		0x1044	/* vendor "sysreg" resource 0x11411044 + 0 */
#define  FSYS1_PCIE0_PCS_HIGH_SPEED	BIT(1)
#define FSYS1_PCIE0_LANE_CTRL		0x1050	/* + 0xc, vendor "PCIE_WIFI0_PCIE_PHY_CONTROL" */
#define  FSYS1_PCIE0_LANE0_ENABLE	BIT(12)
#define FSYS1_PCIE0_SNOOP_CTRL		0x700
#define  FSYS1_PCIE0_SNOOP_SHARABLE	(0x3 << 8)

/* PMU */
#define PCIE_PHY_CONTROL		0x71c
#define  PCIE_PHY_CONTROL_ON		BIT(0)

struct exynos9810_pcie {
	struct dw_pcie		pci;
	void __iomem		*phy;		/* PMA: CMN/TRSV registers */
	void __iomem		*pcs;		/* PCS */
	struct regmap		*pmu;		/* PMU, PCIE_PHY_CONTROL */
	struct regmap		*sysreg;	/* FSYS1 sysreg */
	struct gpio_desc	*perst;
	struct gpio_desc	*wl_reg_on;	/* WL_REG_ON, gpg0-5 */
	void __iomem		*cmu_top;	/* 0x1a240000: FSYS1_PCIE gate */
	void __iomem		*fsys1_gates;	/* 0x11402000: GOUT gates */
	struct irq_domain	*intx_domain;
};

#define to_exynos9810_pcie(x)	container_of(x, struct exynos9810_pcie, pci)

static u32 elb_readl(struct exynos9810_pcie *ep, u32 reg)
{
	return readl(ep->pci.elbi_base + reg);
}

static void elb_writel(struct exynos9810_pcie *ep, u32 val, u32 reg)
{
	writel(val, ep->pci.elbi_base + reg);
}

/* 1 -> 0 -> 1 on an ELBI reset line; vendor pulses them with ~10-100 us */
static void elb_reset_pulse(struct exynos9810_pcie *ep, u32 reg, u32 last_us)
{
	elb_writel(ep, 0x1, reg);
	udelay(10);
	elb_writel(ep, 0x0, reg);
	udelay(10);
	elb_writel(ep, 0x1, reg);
	udelay(last_us);
}

/*
 * Undo the PHY power-down a previous kernel (TWRP) leaves behind, channel 0
 * part (vendor exynos_phy_all_pwrdn_clear).
 */
static void exynos9810_phy_all_pwrdn_clear(struct exynos9810_pcie *ep)
{
	u32 val;

	val = readl(ep->pcs + PCS_REFCLK_OUT_CTRL);
	val &= ~PCS_PWRDN_A;
	writel(val, ep->pcs + PCS_REFCLK_OUT_CTRL);

	val = readl(ep->pcs + PCS_REFCLK_OUT_CTRL2);
	val &= ~PCS_PWRDN_B;
	writel(val, ep->pcs + PCS_REFCLK_OUT_CTRL2);

	writel(0xc0, ep->phy + (0x20 * 4));	/* common block */
	writel(0x7e, ep->phy + (0x57 * 4));	/* trsv */
}

/*
 * Channel 0 PHY configuration, translated from pci-exynos9810_cal.c
 * (exynos_pcie_phy_config). 26 MHz reference, Gen2, one lane. The table
 * values are Samsung's, unchanged.
 */
static void exynos9810_phy_config(struct exynos9810_pcie *ep)
{
	static const u32 cmn_config_val[48] = {
		0x01, 0xE1, 0x05, 0x00, 0x88, 0x88, 0x88, 0x0C,
		0x61, 0x45, 0x65, 0x24, 0x33, 0x18, 0xE3, 0xFC,
		0xD8, 0x05, 0xE6, 0x80, 0x00, 0x00, 0x00, 0x00,
		0x60, 0x11, 0x00, 0xA0, 0x05, 0x04, 0x18, 0x88,
		0xC0, 0xFF, 0x9B, 0x52, 0x22, 0x30, 0x4F, 0xDC,
		0x40, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x80,
	}; /* Ch0 HS1 Gen2 */
	static const u32 trsv_config_val[80] = {
		0x31, 0x40, 0x37, 0x99, 0x85, 0x00, 0xC0, 0xFF,
		0xFF, 0x3F, 0x8C, 0xC8, 0x02, 0x01, 0x88, 0x80,
		0x06, 0x90, 0x6C, 0x66, 0x09, 0x61, 0x42, 0x44,
		0xC6, 0x50, 0x0A, 0x33, 0x58, 0xE7, 0x20, 0x22,
		0x80, 0x38, 0x05, 0x85, 0x00, 0x00, 0x00, 0x7E,
		0x00, 0x00, 0x55, 0x15, 0xAC, 0xAA, 0x3E, 0x00,
		0x00, 0x00, 0x20, 0x3F, 0x00, 0x03, 0x01, 0x00,
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40,
		0x05, 0x85, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
	}; /* Ch0 Gen2 */
	u32 val;
	int i;

	/* Set PCS_HIGH_SPEED, then the lane source and lane0_enable */
	regmap_update_bits(ep->sysreg, FSYS1_PCIE0_PHY_CTRL,
			   FSYS1_PCIE0_PCS_HIGH_SPEED,
			   FSYS1_PCIE0_PCS_HIGH_SPEED);
	/* clear 0xf<<4 and 0xf<<2, set 0x3<<2, clear bit 1, set lane0 bit 12 */
	regmap_update_bits(ep->sysreg, FSYS1_PCIE0_LANE_CTRL,
			   0xf << 4 | 0xf << 2 | FSYS1_PCIE0_PCS_HIGH_SPEED,
			   0x3 << 2);
	regmap_update_bits(ep->sysreg, FSYS1_PCIE0_LANE_CTRL,
			   FSYS1_PCIE0_LANE0_ENABLE,
			   FSYS1_PCIE0_LANE0_ENABLE);

	/* pcs_g_rst */
	elb_reset_pulse(ep, PCIE_ELB_PCS_G_RST, 10);

	/* PHY common block setting */
	for (i = 0; i < ARRAY_SIZE(cmn_config_val); i++)
		writel(cmn_config_val[i], ep->phy + (i * 4));

	/* PHY transceiver/receiver block setting */
	for (i = 0; i < ARRAY_SIZE(trsv_config_val); i++)
		writel(trsv_config_val[i], ep->phy + ((0x30 + i) * 4));

	/* tx latency, pcs refclk out control, PRGM_TIMEOUT_L1SS_VAL */
	writel(0x70, ep->pcs + PCS_TX_LATENCY);
	writel(0x87, ep->pcs + PCS_REFCLK_OUT_CTRL);
	writel(0x50, ep->pcs + PCS_REFCLK_OUT_CTRL2);
	val = readl(ep->pcs + PCS_PRGM_TIMEOUT_L1SS);
	val &= ~BIT(1);
	val |= BIT(4);
	writel(val, ep->pcs + PCS_PRGM_TIMEOUT_L1SS);

	/* PCIE_MAC RST */
	elb_reset_pulse(ep, PCIE_ELB_MAC_RST, 10);

	/* PCIE_PHY PCS&PMA(CMN)_RST */
	elb_reset_pulse(ep, PCIE_ELB_PCS_CMN_RST, 100);

	/* CDR reset: 0b11 -> 0b10 -> 0b00 in bits [7:6], 20 us steps */
	val = readl(ep->pcs + PCS_CDR_RESET);
	val |= PCS_CDR_RESET_MASK;
	writel(val, ep->pcs + PCS_CDR_RESET);
	udelay(20);
	val = readl(ep->pcs + PCS_CDR_RESET);
	val &= ~PCS_CDR_RESET_MASK;
	val |= 0x2 << 6;
	writel(val, ep->pcs + PCS_CDR_RESET);
	val &= ~PCS_CDR_RESET_MASK;
	writel(val, ep->pcs + PCS_CDR_RESET);
}

static void exynos9810_rx_elecidle(struct exynos9810_pcie *ep, bool ignore)
{
	u32 val = readl(ep->pcs + PCS_RX_ELECIDLE);

	val &= ~PCS_RX_ELECIDLE_IGNORE;
	if (ignore)
		val |= PCS_RX_ELECIDLE_IGNORE;
	writel(val, ep->pcs + PCS_RX_ELECIDLE);
}

static int exynos9810_pcie_host_init(struct dw_pcie_rp *pp)
{
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct exynos9810_pcie *ep = to_exynos9810_pcie(pci);
	static const unsigned short fsys1_gates[] = {
		0x000, 0x038, 0x03c, 0x040, 0x044, 0x048, 0x04c, 0x0b0, 0x0b4,
	};
	u32 val, i;

	/*
	 * The FSYS1 PCIe gates live behind the PCIe power domain, so they
	 * are only touchable AFTER the PMU un-isolates the PHY -- which is
	 * why they are opened here and not by the early s9p-clkgate lists
	 * (a gate access while the domain is down is a synchronous external
	 * abort, measured at 0x1141302c).
	 */
	regmap_update_bits(ep->pmu, PCIE_PHY_CONTROL,
			   PCIE_PHY_CONTROL_ON, PCIE_PHY_CONTROL_ON);
	writel_relaxed(0x300000, ep->cmu_top + 0x2074);	/* GATE_CLKCMU_FSYS1_PCIE */
	for (i = 0; i < ARRAY_SIZE(fsys1_gates); i++) {
		void __iomem *a = ep->fsys1_gates + fsys1_gates[i];
		u32 g = readl_relaxed(a);

		writel_relaxed(g | 0x300000, a);	/* MANUAL | CG_VAL */
	}

	/* WiFi RC shares the system cache on this board: snoop bits sharable */
	regmap_update_bits(ep->sysreg, FSYS1_PCIE0_SNOOP_CTRL,
			   FSYS1_PCIE0_SNOOP_SHARABLE,
			   FSYS1_PCIE0_SNOOP_SHARABLE);

	exynos9810_phy_all_pwrdn_clear(ep);

	/* avoid checking rx elecidle while the DBI is being programmed */
	exynos9810_rx_elecidle(ep, true);

	/* soft core reset */
	elb_writel(ep, 0x0, PCIE_SOFT_CORE_RESET);
	udelay(20);
	elb_writel(ep, 0x1, PCIE_SOFT_CORE_RESET);

	/* PERST# deassert, then 20 ms for the endpoint's own power-up */
	gpiod_set_value_cansleep(ep->perst, 0);
	usleep_range(18000, 20000);

	/* APP_REQ_EXIT_L1 in H/W mode, L1 NAK control master */
	val = elb_readl(ep, PCIE_APP_REQ_EXIT_L1_MODE);
	val |= APP_REQ_EXIT_L1_MODE_HW | L1_REQ_NAK_CONTROL_MASTER;
	elb_writel(ep, val, PCIE_APP_REQ_EXIT_L1_MODE);

	/* link-down reset through the manual path, no clock gating */
	elb_writel(ep, PCIE_LINKDOWN_RST_MANUAL, PCIE_LINKDOWN_RST_CTRL_SEL);
	val = elb_readl(ep, PCIE_QCH_SEL);
	val &= ~CLOCK_GATING_ALL;
	elb_writel(ep, val, PCIE_QCH_SEL);

	/* LTSSM history buffer: cheap and makes failures diagnosable */
	elb_writel(ep, 0x0, PCIE_STATE_HISTORY_CHECK);
	elb_writel(ep, HISTORY_BUFFER_ENABLE, PCIE_STATE_HISTORY_CHECK);
	elb_writel(ep, 0x200000, PCIE_STATE_POWER_S);
	elb_writel(ep, 0xffffffff, PCIE_STATE_POWER_M);

	exynos9810_phy_config(ep);

	/* bus number enable */
	val = elb_readl(ep, PCIE_SW_WAKE);
	val &= ~PCIE_BUS_EN;
	elb_writel(ep, val, PCIE_SW_WAKE);

	/* the controller's own 26 MHz auxiliary clock, for the PM timers */
	dw_pcie_writel_dbi(pci, PCIE_AUX_CLK_FREQ, PCIE_AUX_CLK_FREQ_26MHZ);

	/*
	 * Interrupt sources: the four INTx assertion pulses and nothing
	 * else (vendor exynos_pcie_enable_interrupts). Stale status from a
	 * previous kernel is cleared first.
	 */
	elb_writel(ep, elb_readl(ep, PCIE_IRQ_PULSE), PCIE_IRQ_PULSE);
	elb_writel(ep, elb_readl(ep, PCIE_IRQ_LEVEL), PCIE_IRQ_LEVEL);
	elb_writel(ep, elb_readl(ep, PCIE_IRQ_SPECIAL), PCIE_IRQ_SPECIAL);
	elb_writel(ep, IRQ_INTX_ASSERT_ALL, PCIE_IRQ_EN_PULSE);
	elb_writel(ep, 0x0, PCIE_IRQ_EN_LEVEL);
	elb_writel(ep, 0x0, PCIE_IRQ_EN_SPECIAL);

	return 0;
}

/*
 * No MSI controller on this port (see the header comment). Providing the
 * hook keeps the DWC core from claiming the interrupt line for its iMSI-RX
 * chained handler; the line is ours, for INTx.
 */
static int exynos9810_pcie_msi_init(struct dw_pcie_rp *pp)
{
	return 0;
}

static const struct dw_pcie_host_ops exynos9810_pcie_host_ops = {
	.init = exynos9810_pcie_host_init,
	.msi_init = exynos9810_pcie_msi_init,
};

static void exynos9810_pcie_irq_handler(struct irq_desc *desc)
{
	struct exynos9810_pcie *ep = irq_desc_get_handler_data(desc);
	struct irq_chip *chip = irq_desc_get_chip(desc);
	u32 val;
	int i;

	chained_irq_enter(chip, desc);

	val = elb_readl(ep, PCIE_IRQ_PULSE);
	elb_writel(ep, val, PCIE_IRQ_PULSE);
	for (i = 0; i < PCI_NUM_INTX; i++)
		if (val & IRQ_INTX_ASSERT(i))
			generic_handle_domain_irq(ep->intx_domain, i);

	/* level/special sources are not enabled; clear them like the vendor does */
	elb_writel(ep, elb_readl(ep, PCIE_IRQ_LEVEL), PCIE_IRQ_LEVEL);
	elb_writel(ep, elb_readl(ep, PCIE_IRQ_SPECIAL), PCIE_IRQ_SPECIAL);

	chained_irq_exit(chip, desc);
}

static int exynos9810_pcie_intx_map(struct irq_domain *domain,
				    unsigned int irq, irq_hw_number_t hwirq)
{
	irq_set_chip_and_handler(irq, &dummy_irq_chip, handle_simple_irq);
	irq_set_chip_data(irq, domain->host_data);

	return 0;
}

static const struct irq_domain_ops exynos9810_pcie_intx_domain_ops = {
	.map = exynos9810_pcie_intx_map,
	.xlate = irq_domain_xlate_onecell,
};

static int exynos9810_pcie_init_irq(struct exynos9810_pcie *ep,
				    struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *intc;
	int irq;

	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;

	intc = of_get_child_by_name(dev->of_node, "legacy-interrupt-controller");
	if (!intc)
		return dev_err_probe(dev, -EINVAL,
				     "no legacy-interrupt-controller node\n");

	ep->intx_domain = irq_domain_create_linear(of_fwnode_handle(intc),
						   PCI_NUM_INTX,
						   &exynos9810_pcie_intx_domain_ops,
						   ep);
	of_node_put(intc);
	if (!ep->intx_domain)
		return dev_err_probe(dev, -ENOMEM,
				     "failed to create INTx domain\n");

	irq_set_chained_handler_and_data(irq, exynos9810_pcie_irq_handler, ep);

	return 0;
}

static bool exynos9810_pcie_link_up(struct dw_pcie *pci)
{
	struct exynos9810_pcie *ep = to_exynos9810_pcie(pci);

	return elb_readl(ep, PCIE_ELBI_RDLH_LINKUP) & PCIE_ELBI_XMLH_LINKUP;
}

static int exynos9810_pcie_start_link(struct dw_pcie *pci)
{
	struct exynos9810_pcie *ep = to_exynos9810_pcie(pci);
	u32 v;
	int ret;

	/* rx elecidle check back on before the link comes up */
	exynos9810_rx_elecidle(ep, false);

	/* assert LTSSM enable */
	elb_writel(ep, PCIE_ELBI_LTSSM_ENABLE, PCIE_APP_LTSSM_ENABLE);

	/*
	 * Do not hand a dead link to the core. The vendor driver refuses
	 * every config access while the link is down because this root
	 * complex answers such an access with a bus error that hangs the
	 * SoC instead of returning all ones. Failing here fails host init
	 * before enumeration: no WLAN on this boot, but a booting phone.
	 */
	ret = readl_poll_timeout(pci->elbi_base + PCIE_ELBI_RDLH_LINKUP, v,
				 v & PCIE_ELBI_XMLH_LINKUP, 1000, 500000);
	if (ret) {
		dev_err(pci->dev, "link did not come up (RDLH_LINKUP=%08x)\n", v);
		elb_writel(ep, PCIE_ELBI_LTSSM_DISABLE, PCIE_APP_LTSSM_ENABLE);
		gpiod_set_value_cansleep(ep->perst, 1);
	}
	return ret;
}

static void exynos9810_pcie_stop_link(struct dw_pcie *pci)
{
	struct exynos9810_pcie *ep = to_exynos9810_pcie(pci);

	elb_writel(ep, PCIE_ELBI_LTSSM_DISABLE, PCIE_APP_LTSSM_ENABLE);
	gpiod_set_value_cansleep(ep->perst, 1);
}

static const struct dw_pcie_ops exynos9810_pcie_ops = {
	.link_up = exynos9810_pcie_link_up,
	.start_link = exynos9810_pcie_start_link,
	.stop_link = exynos9810_pcie_stop_link,
};

static int exynos9810_pcie_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct exynos9810_pcie *ep;
	struct dw_pcie *pci;
	int ret;

	ep = devm_kzalloc(dev, sizeof(*ep), GFP_KERNEL);
	if (!ep)
		return -ENOMEM;

	pci = &ep->pci;
	pci->dev = dev;
	pci->ops = &exynos9810_pcie_ops;

	ep->phy = devm_platform_ioremap_resource_byname(pdev, "phy");
	if (IS_ERR(ep->phy))
		return PTR_ERR(ep->phy);

	ep->pcs = devm_platform_ioremap_resource_byname(pdev, "pcs");
	if (IS_ERR(ep->pcs))
		return PTR_ERR(ep->pcs);

	ep->pmu = syscon_regmap_lookup_by_phandle(dev->of_node,
						 "samsung,pmu-syscon");
	if (IS_ERR(ep->pmu))
		return dev_err_probe(dev, PTR_ERR(ep->pmu),
				     "failed to get PMU syscon\n");

	ep->sysreg = syscon_regmap_lookup_by_phandle(dev->of_node,
						    "samsung,fsys-sysreg");
	if (IS_ERR(ep->sysreg))
		return dev_err_probe(dev, PTR_ERR(ep->sysreg),
				     "failed to get FSYS1 sysreg syscon\n");

	/* PERST# asserted until host_init brings the PHY up */
	ep->perst = devm_gpiod_get(dev, "perst", GPIOD_OUT_HIGH);
	if (IS_ERR(ep->perst))
		return dev_err_probe(dev, PTR_ERR(ep->perst),
				     "failed to get perst gpio\n");

	/*
	 * WL_REG_ON powers the endpoint's PCIe interface. Vendor order
	 * (dhd_custom_exynos.c): WL_REG_ON high, WIFI_TURNON_DELAY = 200 ms,
	 * then the root complex comes up and trains the link. With 100 ms a
	 * cold-started chip still enumerated but answered its first BAR read
	 * with all ones (brcmf_chip_recognition "MMIO read failed"); a warm
	 * chip never showed it.
	 */
	ep->wl_reg_on = devm_gpiod_get_optional(dev, "enable",
						GPIOD_OUT_LOW);
	if (IS_ERR(ep->wl_reg_on))
		return dev_err_probe(dev, PTR_ERR(ep->wl_reg_on),
				     "failed to get wifi-enable gpio\n");
	if (ep->wl_reg_on) {
		/* off first: after a warm restart the chip is still running the
		 * previous kernel's firmware with its link half alive. Every boot
		 * starts from a powered-down module this way. */
		msleep(50);
		gpiod_set_value_cansleep(ep->wl_reg_on, 1);
		msleep(200);
	}

	ep->cmu_top = devm_ioremap(dev, 0x1a240000, 0x4000);
	ep->fsys1_gates = devm_ioremap(dev, 0x11402000, 0x100);
	if (!ep->cmu_top || !ep->fsys1_gates)
		return -ENOMEM;

	/* INTx domain before enumeration: the endpoint's IRQ is mapped during the scan */
	ret = exynos9810_pcie_init_irq(ep, pdev);
	if (ret)
		return ret;

	pci->pp.ops = &exynos9810_pcie_host_ops;
	platform_set_drvdata(pdev, ep);

	ret = dw_pcie_host_init(&pci->pp);
	if (ret)
		dev_err(dev, "failed to initialize host: %d\n", ret);

	return ret;
}

static void exynos9810_pcie_remove(struct platform_device *pdev)
{
	struct exynos9810_pcie *ep = dev_get_drvdata(&pdev->dev);

	dw_pcie_host_deinit(&ep->pci.pp);
}

static const struct of_device_id exynos9810_pcie_of_match[] = {
	{ .compatible = "samsung,exynos9810-pcie", },
	{ },
};
MODULE_DEVICE_TABLE(of, exynos9810_pcie_of_match);

static struct platform_driver exynos9810_pcie_driver = {
	.probe = exynos9810_pcie_probe,
	.remove = exynos9810_pcie_remove,
	.driver = {
		.name = "pcie-exynos9810",
		.of_match_table = exynos9810_pcie_of_match,
	},
};
module_platform_driver(exynos9810_pcie_driver);

MODULE_DESCRIPTION("PCIe host controller driver for the Samsung Exynos 9810");
MODULE_LICENSE("GPL v2");
