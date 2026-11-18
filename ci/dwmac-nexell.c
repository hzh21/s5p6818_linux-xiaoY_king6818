// SPDX-License-Identifier: GPL-2.0
/*
 * Nexell S5P6818 DWMAC glue layer
 *
 * Ported from the Nexell 4.14 BSP driver (dwmac-nexell.c in
 * hzh21/s5p6818_linux-xiaoY_king6818) to the Linux 5.10 stmmac API:
 *   - plat_dat->init  still returns int
 *   - plat_dat->exit  is void
 *   - plat_dat->set_wol/get_wol were removed upstream
 *   - the stmmaceth reset now lives in plat_dat->stmmac_rst
 *
 * 5.10 has no glue driver matching "nexell,s5p6818-gmac" (dwmac-generic only
 * matches "snps,dwmac-*"), so without this the on-board GMAC never probes.
 *
 * v2 (fix "Failed to reset the dma"):
 * In 5.10 the platform init callback (plat->init) is only invoked from
 * stmmac_pltfr_resume(); stmmac_dvr_probe() never calls it.  The 4.14 BSP
 * driver additionally called nexell_gmac_init() directly from its probe, and
 * that call is what actually ungates the GMAC clock and releases the IP reset.
 * After the port it was gone, so the CMU "gmac" output stayed gated and the
 * DWMAC1000 DMA soft reset (DMA_BUS_MODE.SWR) never self-cleared ->
 * "Failed to reset the dma" on every stmmac_open().
 *
 * So: bring the TX clock up and deassert the GMAC reset in probe, strictly
 * before stmmac_dvr_probe().  Order matters: clock first, reset second.
 *
 * v3 (fix "eth0 up but RX is always 0"):
 * A fixed-link node directly under the MAC node makes phylink pick
 * MLO_AN_FIXED, which means the PHY is never attached and never initialised.
 * On RGMII the RX clock comes from the PHY, so RX stayed at 0 packets while
 * TX counters still moved.
 *
 * v4: the real fix for RX is in the device tree, not here.  In 5.10
 * stmmac_mdio_register() only allocates/registers an MDIO bus when the dts
 * has an mdio subnode with compatible = "snps,dwmac-mdio" (mdio_bus_data is
 * NULL otherwise), and phylink only finds the PHY through the MAC node's
 * phy-handle.  The board dts had neither, so there was no bus and no PHY:
 * the MAC never learned the link speed and RGMII RX never clocked.
 * The dts now carries phy-mode/phy-handle/mdio/snps,reset-gpios for PHY 7
 * (the address the working 4.14 nanopi3 dtb uses).  This driver version adds
 * explicit diagnostics for both conditions.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/stmmac.h>
#include <linux/clk.h>
#include <linux/of_net.h>
#include <linux/reset.h>

#include "stmmac_platform.h"

struct nexell_priv_data {
	struct plat_stmmacenet_data *plat;
	struct clk *tx_clk;
	bool clk_enabled;
};

#define GMAC_GMII_RGMII_RATE	125000000

static void *nexell_gmac_setup(struct platform_device *pdev,
			       struct plat_stmmacenet_data *plat)
{
	struct device *dev = &pdev->dev;
	struct nexell_priv_data *gmac;

	gmac = devm_kzalloc(dev, sizeof(*gmac), GFP_KERNEL);
	if (!gmac)
		return ERR_PTR(-ENOMEM);

	gmac->plat = plat;

	/*
	 * dts: clocks = <&pclk>, <&gmac>;
	 *      clock-names = "stmmaceth", "nexell_gmac_tx";
	 * stmmac_probe_config_dt() already enables "stmmaceth" (pclk); the
	 * 125 MHz "gmac" output is ours to drive.
	 */
	gmac->tx_clk = devm_clk_get(dev, "nexell_gmac_tx");
	if (IS_ERR(gmac->tx_clk)) {
		dev_warn(dev, "no nexell_gmac_tx clock: %ld\n",
			 PTR_ERR(gmac->tx_clk));
		/* last resort: first clock of the node */
		gmac->tx_clk = devm_clk_get(dev, NULL);
		if (IS_ERR(gmac->tx_clk))
			dev_err(dev, "no usable gmac clock at all: %ld\n",
				PTR_ERR(gmac->tx_clk));
	}

	return gmac;
}

static int nexell_gmac_clk_on(struct device *dev, struct nexell_priv_data *gmac)
{
	long rate;
	int ret;

	if (IS_ERR_OR_NULL(gmac->tx_clk))
		return 0;

	ret = clk_set_rate(gmac->tx_clk, GMAC_GMII_RGMII_RATE);
	if (ret)
		dev_warn(dev, "cannot set tx clk to %d Hz: %d\n",
			 GMAC_GMII_RGMII_RATE, ret);

	ret = clk_prepare_enable(gmac->tx_clk);
	if (ret) {
		dev_err(dev, "cannot enable tx clk: %d\n", ret);
		return ret;
	}

	gmac->clk_enabled = true;
	rate = clk_get_rate(gmac->tx_clk);
	dev_info(dev, "gmac tx clk enabled at %ld Hz\n", rate);
	if (rate != GMAC_GMII_RGMII_RATE)
		dev_warn(dev, "gmac tx clk is %ld Hz, expected %d Hz\n",
			 rate, GMAC_GMII_RGMII_RATE);

	return 0;
}

static int nexell_gmac_init(struct platform_device *pdev, void *priv)
{
	struct device *dev = &pdev->dev;
	struct nexell_priv_data *gmac = priv;
	int ret;

	if (!gmac)
		return 0;

	/* clock first ... */
	ret = nexell_gmac_clk_on(dev, gmac);
	if (ret)
		return ret;

	/* ... then release the IP reset so the DMA can come out of SWR */
	if (gmac->plat && gmac->plat->stmmac_rst) {
		reset_control_deassert(gmac->plat->stmmac_rst);
		dev_info(dev, "gmac reset deasserted\n");
	} else {
		dev_warn(dev, "no gmac reset control, continuing\n");
	}

	return 0;
}

static void nexell_gmac_exit(struct platform_device *pdev, void *priv)
{
	struct nexell_priv_data *gmac = priv;

	if (!gmac)
		return;

	if (!IS_ERR_OR_NULL(gmac->tx_clk) && gmac->clk_enabled) {
		clk_disable_unprepare(gmac->tx_clk);
		gmac->clk_enabled = false;
	}
}

static int nexell_gmac_probe(struct platform_device *pdev)
{
	struct plat_stmmacenet_data *plat_dat;
	struct stmmac_resources stmmac_res;
	void *bsp_priv;
	int ret;

	ret = stmmac_get_platform_resources(pdev, &stmmac_res);
	if (ret)
		return ret;

	plat_dat = stmmac_probe_config_dt(pdev, &stmmac_res.mac);
	if (IS_ERR(plat_dat))
		return PTR_ERR(plat_dat);

	plat_dat->has_gmac = true;
	plat_dat->init = nexell_gmac_init;
	plat_dat->exit = nexell_gmac_exit;

	bsp_priv = nexell_gmac_setup(pdev, plat_dat);
	if (IS_ERR(bsp_priv)) {
		ret = PTR_ERR(bsp_priv);
		goto err_remove;
	}
	plat_dat->bsp_priv = bsp_priv;

	/*
	 * 5.10 never calls plat->init from the probe path, so do it here.
	 * Without the clock running the DMA soft reset below times out.
	 */
	ret = nexell_gmac_init(pdev, bsp_priv);
	if (ret)
		goto err_remove;

	ret = stmmac_dvr_probe(&pdev->dev, plat_dat, &stmmac_res);
	if (ret)
		goto err_exit;

	/*
	 * 诊断输出：这三项决定 phylink 能不能真正把 PHY 接起来。
	 *   mdio_bus_data == NULL -> dts 的 mdio 子节点没有 snps,dwmac-mdio，
	 *                            总线根本没注册，PHY 永远不会被 attach，
	 *                            snps,reset-gpios 的复位脉冲也不会发；
	 *   phy_node == NULL      -> dts 没有 phy-handle，phylink 拿不到 phy
	 *                            fwnode，链路停在 MLO_AN_PHY 却没有 phydev；
	 *   phy_addr < 0          -> 既没写 phy-addr 也没扫到 PHY。
	 */
	dev_info(&pdev->dev,
		 "nexell-dwmac: mdio=%s phy-handle=%s phy_addr=%d\n",
		 plat_dat->mdio_bus_data ? "registered" : "NONE",
		 plat_dat->phy_node ? "yes" : "no",
		 plat_dat->phy_addr);

	if (!plat_dat->mdio_bus_data)
		dev_err(&pdev->dev,
			"no MDIO bus registered, check compatible = \"snps,dwmac-mdio\"\n");

	if (plat_dat->phy_addr < 0) {
		dev_warn(&pdev->dev,
			 "no PHY responded on the MDIO bus, clamping phy_addr to 0\n");
		plat_dat->phy_addr = 0;
	}

	dev_info(&pdev->dev, "nexell-dwmac ready (v4, phylink phy-handle)\n");
	return 0;

err_exit:
	nexell_gmac_exit(pdev, bsp_priv);
err_remove:
	stmmac_remove_config_dt(pdev, plat_dat);
	return ret;
}

static const struct of_device_id nexell_dwmac_match[] = {
	{ .compatible = "nexell,s5p6818-gmac" },
	{ }
};
MODULE_DEVICE_TABLE(of, nexell_dwmac_match);

static struct platform_driver nexell_dwmac_driver = {
	.probe	= nexell_gmac_probe,
	.remove	= stmmac_pltfr_remove,
	.driver	= {
		.name		= "nexell-dwmac",
		.pm		= &stmmac_pltfr_pm_ops,
		.of_match_table	= nexell_dwmac_match,
	},
};
module_platform_driver(nexell_dwmac_driver);

MODULE_AUTHOR("Bon-gyu, KOO <freestyle@nexell.co.kr>");
MODULE_DESCRIPTION("Nexell DWMAC specific glue layer");
MODULE_LICENSE("GPL");
