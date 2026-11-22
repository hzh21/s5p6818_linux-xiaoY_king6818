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
