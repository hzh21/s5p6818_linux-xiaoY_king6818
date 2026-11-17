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
	gmac->tx_clk = devm_clk_get(dev, "nexell_gmac_tx");
	if (IS_ERR(gmac->tx_clk))
		dev_warn(dev, "no nexell_gmac_tx clock: %ld\n",
			 PTR_ERR(gmac->tx_clk));

	return gmac;
}

static int nexell_gmac_init(struct platform_device *pdev, void *priv)
{
	struct nexell_priv_data *gmac = priv;

	if (gmac->plat && gmac->plat->stmmac_rst)
		reset_control_deassert(gmac->plat->stmmac_rst);

	if (!IS_ERR(gmac->tx_clk)) {
		clk_set_rate(gmac->tx_clk, GMAC_GMII_RGMII_RATE);
		clk_prepare_enable(gmac->tx_clk);
		gmac->clk_enabled = true;
	}

	return 0;
}

static void nexell_gmac_exit(struct platform_device *pdev, void *priv)
{
	struct nexell_priv_data *gmac = priv;

	if (!IS_ERR(gmac->tx_clk) && gmac->clk_enabled) {
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

	ret = stmmac_dvr_probe(&pdev->dev, plat_dat, &stmmac_res);
	if (ret)
		goto err_remove;

	return 0;

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
