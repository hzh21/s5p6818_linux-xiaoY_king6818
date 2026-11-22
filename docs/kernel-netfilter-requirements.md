# 5.10 旁路由 netfilter 配置补全

> 编写：2026-11-22
> 触发：`wireless_acl.sh` 改用 nft 后暴露 `NFT_COUNTER` 缺失，顺带清查整套旁路由能力
> 落地：`ci/5.10-king6818.yml` 的 Configure 步骤 + 硬断言
> 核对依据：板上 `zcat /proc/config.gz`（`kconfig-current.txt`）＋ 5.10 源码 `net/**/Kconfig`

## 一、先纠正三个符号名错误

用户给的清单里，有三处和 5.10 源码对不上。这不是笔误，是被 OpenWrt 的写法带偏了。

| 清单写法 | 实际情况 |
|---|---|
| `NF_FLOW_TABLE_IPV4` / `NF_FLOW_TABLE_IPV6` | **5.10 没有这两个符号**。`net/netfilter/Kconfig` 里只有 `NF_FLOW_TABLE` 和 `NF_FLOW_TABLE_INET` |
| `NFT_FLOW_OFFLOAD` 用于软件快路径 | 符号存在，但注释原文是 *"hardware flow offload module"*，`depends on NF_CONNTRACK && NF_FLOW_TABLE`。软件快路径由 `NF_FLOW_TABLE` 提供；6818 的 GMAC 没有硬件 offload，开它只是保险（部分版本的 `nft_flow_offload.o` 仍由它 gate） |
| 只补 `IP_SET` 就能用 ipset | `IP_SET` 只是管理面。`iptables -m set --match-set` 需要 **`NETFILTER_XT_SET`**，清单里漏了这一项 —— 缺它 `ipset create` 能成功但规则里引用不到 |

## 二、当前实测状态（2026-11-22，`5.10.252-s5p6818`）

你标注的「未开」基本准确。实测 `=n` 的关键项：

```
NETFILTER_XT_MATCH_MAC        n     NETFILTER_XT_TARGET_CONNMARK  n
NETFILTER_XT_TARGET_MARK      n     IP_SET                        n
NETFILTER_XT_SET              隐藏  NFT_COUNTER                   n
NF_FLOW_TABLE                 n     NFT_SOCKET                    n
NFT_FIB_IPV4/IPV6             n     NFT_QUOTA / CONNLIMIT / DUP   n
```

已经 `=y` 的：`NETFILTER_XT_MATCH_MARK`、`NETFILTER_ADVANCED`、`NF_CONNTRACK`、
`NF_CONNTRACK_MARK`、`NF_NAT`、`NF_NAT_REDIRECT`、`NF_NAT_MASQUERADE`、
`NF_TABLES` + `_INET/_IPV4/_IPV6/_NETDEV`、`NFT_CT/NAT/MASQ/REDIR/REJECT/LOG/LIMIT/COMPAT`、
`IP_NF_IPTABLES/FILTER/NAT/MANGLE`、`BRIDGE_NETFILTER`。

## 三、清单里漏掉的、会真正导致功能静默缺失的项

优先级从高到低：

1. **`NETFILTER_XT_SET`** —— ipset 的规则侧。只开 `IP_SET` 等于白开。
2. **`IP_NF_RAW` / `IP6_NF_RAW`** —— 当前两个都是 `n`，后果是 `NETFILTER_XT_TARGET_CT`、
   `NOTRACK`、`TRACE` 三个符号**在 .config 里连影子都不出现**（被 Kconfig 隐藏）。
   而透明代理的标准写法 `iptables -t raw -A PREROUTING -j CT --notrack` 全靠它。
   这是整份清单里最隐蔽的一处：查配置时看不到，只有真要写规则时才炸。
3. **`NETFILTER_XT_TARGET_TPROXY` + `NETFILTER_XT_MATCH_SOCKET` + `NF_TPROXY_IPV4/IPV6`**
   —— 传统 TProxy 路径。当前 `NFT_TPROXY` 也是 `n`，等于两条 TProxy 路径全断，
   mihomo 只能退到 `REDIRECT`（这对 UDP 是致命缺陷：QUIC 一律走不通）。
4. **`NFT_HASH`** —— 是 `n`。nft 的 `set` 默认后端就是 hash，缺了它
   `nft add set inet t s { type ipv4_addr; }` 会报 `Operation not supported`。
   任何"黑白名单集合"写法都会失败。
5. **`IP6_NF_*` 全是 `=m`** —— IPv6 防火墙是模块，开机早期规则加载时可能还没 modprobe。
   `inet` 表的规则（`nft` 默认写法）在 IPv6 上是半残的。
6. **`NET_SCH_CAKE` / `IFB` 都是 `n`** —— 现有的只有 `fq/fq_codel/htb`。
   入向限速必须靠 `IFB` + `ingress` + `police`，出向才轮到 CAKE。
   旁路由最常见的痛点就是"下载抢满带宽"，没有这套做不了。

## 四、已加入 CI 的完整清单

分组见 `ci/5.10-king6818.yml` 的 Configure 步骤（A~J 十组，共 89 个符号，全部 `=y`）：

| 组 | 内容 | 关键符号 |
|---|---|---|
| A | ipset + xt_set | `IP_SET`, `IP_SET_HASH_IP/NET/IPPORT/IPPORTNET`, `IP_SET_BITMAP_*`, `NETFILTER_XT_SET` |
| B | MAC / 连接标记 / 计数 | `XT_MATCH_MAC`, `XT_TARGET_CONNMARK`, `XT_TARGET_MARK`, `NFT_COUNTER` |
| C | raw 表（CT/NOTRACK/TRACE 父依赖） | `IP_NF_RAW`, `IP6_NF_RAW`, `XT_TARGET_CT/NOTRACK/TRACE` |
| D | 透明代理 | `XT_TARGET_TPROXY`, `XT_MATCH_SOCKET`, `NF_TPROXY_IPV4/6`, `NFT_TPROXY`, `NFT_SOCKET`, `IP_NF_TARGET_REDIRECT`, `XT_TARGET_NFLOG` |
| E | nft 表达式 | `NFT_HASH`, `NFT_QUOTA`, `NFT_CONNLIMIT`, `NFT_SYNPROXY`, `NFT_NUMGEN`, `NFT_OSF`, `NFT_XFRM`, `NFT_DUP_IPV4/6`, `NFT_FIB_IPV4/6/INET`, `NF_CT_NETLINK` |
| F | 软件快路径 | `NF_FLOW_TABLE`, `NF_FLOW_TABLE_INET`, `NFT_FLOW_OFFLOAD` |
| G | 常用 match/target | `XT_MATCH_STATE/OWNER/CONNLIMIT/HASHLIMIT/RECENT/STRING/TIME/CONNBYTES/STATISTIC/BPF/CGROUP/PHYSDEV/IPRANGE/LENGTH/TCPMSS/U32/HELPER/ECN/REALM/RATEEST`, `XT_TARGET_TEE/TCPMSS/CLASSIFY/DSCP/LOG` |
| H | conntrack 诊断 | `NF_CONNTRACK_LABELS/TIMEOUT/PROCFS` |
| I | QoS | `IFB`, `NET_SCH_CAKE`, `NET_SCH_INGRESS`, `NET_ACT_POLICE` |
| J | IPv6 / 容器 / 隧道 | `IP6_NF_*` 全改 `y`，`VLAN_8021Q`, `MACVLAN`, `DUMMY`, `WIREGUARD`, `CRYPTO_CHACHA20POLY1305`, `INET6_ESP` |

## 五、为什么全部用 `=y` 而不是 `=m`

用户的判断是对的，补充两条更硬的理由：

1. **静默失败**：模块没编进 initramfs 时，`modprobe xt_mac` 失败只会在规则加载那一刻报
   `No chain/target/match by that name`，而这类报错通常被脚本 `2>/dev/null` 吞掉。
2. **内存不是瓶颈**：这套东西加起来约 1.2 MB（去掉调试信息后），对 2G 内存的机器可以忽略；
   而每多一个模块，就多一次"忘了 modprobe"的机会。

## 六、验证方法（修正版）

用户给的 `strings Image | grep CONFIG_IP_SET` **不可靠** —— 只有当 `CONFIG_IKCONFIG` 编进
内核、且字符串没有被压缩时才可能命中，属于碰运气。按下面三步做，缺一步都可能误判：

### 1. 构建期（CI 已经做成硬断言）

```bash
grep -c '^CONFIG_IP_SET=y$' .config     # CI 里 89 项逐条断言，缺一个就 fail 并打印 depends
```

### 2. 板上静态核对

```bash
zcat /proc/config.gz | grep -E '^CONFIG_(IP_SET|NETFILTER_XT_SET|NFT_COUNTER|NF_FLOW_TABLE)=' 
# 或者用仓库里的审计脚本
python3 tools/kconfig-audit.py kconfig-current.txt
```

### 3. 板上功能自测（真正有意义的一步）

```bash
# counter：nft 表达式是否可用，同时验证 nft 表能建
nft add table inet t
nft add chain inet t c
nft add rule inet t c counter accept && nft list chain inet t c

# set（hash 后端）+ 元素
nft add set inet t s '{ type ipv4_addr; }'
nft add element inet t s '{ 1.2.3.4 }'

# ipset 两种用法：管理面 + 规则侧
ipset create t1 hash:ip
iptables -t mangle -A PREROUTING -m set --match-set t1 src -j RETURN   # 这一步才验证 XT_SET

# TProxy + raw/CT
iptables -t raw -A PREROUTING -j CT --notrack
iptables -t mangle -A PREROUTING -p tcp -j TPROXY --on-port 7893 --tproxy-mark 1

# flowtable（软件快路径）
nft add flowtable inet t f '{ hook ingress priority 0; devices = { eth0 }; }'

# QoS
tc qdisc add dev eth0 root cake bandwidth 100mbit
tc qdisc add dev eth0 handle ffff: ingress
ip link add ifb0 type ifb
```

任何一条报 `Operation not supported` / `No such file` / `Invalid argument`，
都对应上表某一项没生效。

## 七、还有哪些没做（明确留白）

- **OpenWrt 的 `FLOWOFFLOAD` xt target**：那是 OpenWrt 自家补丁，上游 5.10 没有。
  想要 iptables 风格的 fastpath，只能靠 nft 的 `flowtable`，或者自己背补丁。
- **`NETFILTER_XT_MATCH_AH_ESP`**：5.10 已移除 AH/ESP 匹配（`xt_AH` 不在树里），清单里也写了，
  这里明确说明是**不存在**，不是没开。
- **`XTABLES_COMPAT`**：只有当容器里跑 32 位 armhf 的 iptables 才需要（转译 32 位 getsockopt）。
  当前容器都是 arm64，没开。
- **硬件 offload**：6818 的 GMAC 不支持，`NFT_FLOW_OFFLOAD` 开了也不会生效，纯属无害。

## 八、CI 实测：断言抓到的问题（run #40 / #41）

### run #40 —— IFB 被 Kconfig 静默丢弃

第一次带 89 项断言构建，Configure 在 **2 分钟内**失败（而不是烧完 21 分钟）：

```
FATAL: 以下旁路由选项没进 .config（多半 depends 没满足）：
 CONFIG_IFB
--- IFB
drivers/net/Kconfig-149-	tristate "Intermediate Functional Block support"
drivers/net/Kconfig-150-	depends on NET_ACT_MIRRED || NFT_FWD_NETDEV
```

根因：只勾了 `IFB`，没勾 `NET_ACT_MIRRED`。而 `NET_ACT_MIRRED` 本身
`depends on NET_CLS_ACT`（`net/sched/Kconfig:711`）。链路是：

```
NET_SCHED -> NET_CLS_ACT -> NET_ACT_MIRRED -> IFB
```

`NET_CLS_ACT` 在 nanopi3_linux_defconfig 里**本来就是 y**，所以真正缺的只有
`NET_ACT_MIRRED` 一环。同时补齐 `NET_ACT_GACT`、`NET_CLS_FLOWER`，
并把五项一起加进断言清单（89 → 94 项）。

### run #41 —— 全部通过

```
旁路由 netfilter 选项 OK（… NET_SCHED NET_CLS_ACT NET_ACT_GACT
NET_ACT_MIRRED NET_CLS_FLOWER IFB NET_SCH_CAKE NET_SCH_INGRESS
NET_ACT_POLICE … 共 94 项）
```

产物：`king6818-5.10.252-Image-dtb`（11.2 MB）、`king6818-5.10.252-modules`（6.0 MB）。

### 经验

- 依赖链上任何一环为 n，Kconfig 就把下游符号**整条从 .config 里删掉**
  （不是写 `is not set`），`grep "^CONFIG_X is not set"` 查不出来，只能反查 Kconfig。
- 断言里打印 `depends on` 行的做法是有效的：一条报错直接给出原因，不用再翻源码。

## 九、TCP 拥塞控制：BBR（第二轮补全）

板上原状：

```
# CONFIG_TCP_CONG_ADVANCED is not set
CONFIG_TCP_CONG_CUBIC=y
CONFIG_DEFAULT_TCP_CONG="cubic"
/proc/sys/net/ipv4/tcp_available_congestion_control -> reno cubic
```

即 BBR 完全不可用。原因与 IFB 一模一样：`net/ipv4/Kconfig` 里

```
menuconfig TCP_CONG_ADVANCED
	bool "TCP: advanced congestion control"
...
if TCP_CONG_ADVANCED
config TCP_CONG_BBR
	tristate "BBR TCP"
	default n
endif
```

外层 `menuconfig` 为 n 时，`TCP_CONG_BBR` 在 `.config` 里**连 `is not set` 都不会出现**，
grep 不到任何痕迹，只能从 `tcp_available_congestion_control` 反推。

补法：

```
./scripts/config --enable CONFIG_TCP_CONG_ADVANCED
./scripts/config --enable CONFIG_TCP_CONG_BBR
```

`CONFIG_DEFAULT_TCP_CONG` **保持 "cubic" 不动**。这样两种算法同时可用，
要切 BBR 在运行时执行 `sysctl -w net.ipv4.tcp_congestion_control=bbr`，
出问题直接切回 cubic，不需要重编。BBR 建议配 `net.core.default_qdisc=fq`
（`CONFIG_NET_SCH_FQ` 已经是 y）。

断言单独一组（不并进 netfilter 那 94 项，避免报错信息语义混淆）：

```
for s in CONFIG_TCP_CONG_ADVANCED CONFIG_TCP_CONG_BBR; do
  grep -qE "^$s=y$" .config || { echo "FATAL: $s 没进 .config" >&2; ... exit 1; }
done
```

## 十、与 4.14 原厂内核逐项比对（第二轮，32 项）

方法：两个镜像都编入了 `CONFIG_IKCONFIG`，直接把内嵌 `.config` 抠出来比，
不靠印象。工具 `tools/extract-ikconfig.py`（扫 `IKCFG_ST`/`IKCFG_ED` 标记解 gzip）
与 `tools/cfg-gap.py`（把「5.10 里存在但为 n」和「5.10 已删除该符号」分开统计）。

```
Image      4.14.137  4733 行
Image.510  5.10.252  7320 行
4.14 已启用而旧 5.10 关闭：143 项
本轮之前已补：29 项；本轮再补：32 项
```

### 板载实测（不是看配置猜的）

```
# ip rule add fwmark 0x1 table 100
RTNETLINK answers: Operation not supported        <- IP_ADVANCED_ROUTER=n

# nft add rule inet wbtest c counter log prefix "wbtest"
Error: Could not process rule: No such file or directory
                     ^^^^^^^                     <- NETFILTER_NETLINK_LOG=n
```

这两条对旁路由是硬伤：前者让 `ip rule` / 多路由表全废（按 fwmark 或源地址分流
的基础），后者让 nft 的 `log` 语句直接不存在。

### 澄清：CGROUP_FREEZER=n 不是问题

`CONFIG_CGROUP_FREEZER` 只影响 cgroup **v1**。本机是 cgroup v2，
`/sys/fs/cgroup/machine.slice/libpod-*.scope/cgroup.freeze` 实测存在，
`podman pause` 走 v2 的 core freezer，不依赖该符号。不要为它重编。

### 本轮补的 32 项

| 类别 | 符号 |
|---|---|
| 策略路由 | `IP_ADVANCED_ROUTER` `IP_MULTIPLE_TABLES` `IPV6_MULTIPLE_TABLES` |
| nfnetlink | `NETFILTER_NETLINK_LOG` `NETFILTER_NETLINK_QUEUE` `XT_TARGET_NFQUEUE` `XT_TARGET_REDIRECT` `XT_TARGET_IDLETIMER` `XT_MATCH_QUOTA` |
| QoS 分类 | `XT_MATCH_PKTTYPE` `XT_MATCH_HL` |
| nft | `NFT_OBJREF` `NF_TABLES_ARP` |
| NAT 穿越 | `NF_CONNTRACK_FTP` `_SIP` `_TFTP` `_PPTP` |
| 容器 | `BLK_DEV_THROTTLING` `OVERLAY_FS_INDEX` `TMPFS_XATTR` `TMPFS_POSIX_ACL` |
| 文件系统 | `CIFS` `ISO9660_FS` `MSDOS_FS` `EXT4_FS_SECURITY` `BINFMT_MISC` |
| 诊断/密码学 | `INET_UDP_DIAG` `CRYPTO_ARC4` `CRYPTO_DES` `CRYPTO_MD4` `DM_CRYPT` `CRC_CCITT` |

`EXT4_FS_SECURITY` 单独说一句：它是 ext4 的 security xattr 支持，缺了 `setcap`
在 ext4 上写了也不生效（`getcap` 读不到），rootless podman 会因此莫名其妙起不来。

### 故意不补的（判过，对本机无意义或有害）

蓝牙全家桶（板子无 BT 硬件）、触摸屏/鼠标、`KGDB`/`DEBUG_SPINLOCK`/`SCHEDSTATS`
（调试用，带运行时开销）、`ANDROID` binder、`USB_ETH` gadget、`UHID`、
`LOGO_LINUX_*`、`IP_VS`、`NFSD`、`STAGING`、`CFG80211_WEXT`/`MAC80211_MESH`。
