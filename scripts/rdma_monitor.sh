#!/bin/bash
# =============================================================================
# Script: check_rdma_traffic.sh
# Description: 多维度检测系统是否存在真正的RDMA协议流量
# Author: AI Assistant
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# 1. 检查RDMA设备是否存在且处于ACTIVE状态
# =============================================================================
check_rdma_devices() {
    echo "========================================"
    echo "1. 检查RDMA设备状态"
    echo "========================================"

    if ! command -v ibv_devices &>/dev/null; then
        log_warn "ibv_devices 未安装，跳过设备检查"
        return 1
    fi

    local devices=$(ibv_devices 2>/dev/null | tail -n +2 | awk '{print $1}')
    if [ -z "$devices" ]; then
        log_error "未发现RDMA设备"
        return 1
    fi

    for dev in $devices; do
        log_info "设备: $dev"
        ibv_devinfo -d "$dev" 2>/dev/null | grep -E "transport|state|link_layer|active_mtu" | sed 's/^/    /'
        
        # 检查端口是否ACTIVE
        local state=$(ibv_devinfo -d "$dev" 2>/dev/null | grep "state:" | head -1 | awk '{print $2}')
        if [ "$state" != "PORT_ACTIVE" ]; then
            log_warn "设备 $dev 端口状态: $state (非ACTIVE)"
        else
            log_info "设备 $dev 端口状态: ACTIVE ✓"
        fi
    done
    echo ""
}

# =============================================================================
# 2. 检查RDMA子系统资源（QP连接）——最直接的RDMA流量证据
# =============================================================================
check_rdma_resources() {
    echo "========================================"
    echo "2. 检查RDMA活跃资源（QP连接）"
    echo "========================================"

    if ! command -v rdma &>/dev/null; then
        log_warn "rdma 命令未安装（iproute2 RDMA模块），跳过资源检查"
        return 1
    fi

    # 查看RDMA链路状态
    log_info "RDMA链路状态:"
    rdma link show 2>/dev/null | sed 's/^/    /' || log_warn "无法获取链路状态"
    echo ""

    # 查看活跃的QP资源 —— 这是判断是否有RDMA流量的核心指标
    log_info "活跃的RDMA资源（QP/MR/CQ）:"
    local qp_count=$(rdma res show qp 2>/dev/null | tail -n +2 | wc -l)
    if [ "$qp_count" -gt 0 ]; then
        log_info "发现 $qp_count 个活跃的QP（Queue Pair），说明有应用在使用RDMA协议 ✓"
        rdma res show qp 2>/dev/null | head -20 | sed 's/^/    /'
    else
        log_warn "未发现活跃的QP资源，当前可能没有RDMA协议流量"
    fi
    echo ""
}

# =============================================================================
# 3. 检查网卡计数器中的RDMA/RoCE统计
# =============================================================================
check_nic_counters() {
    echo "========================================"
    echo "3. 检查网卡RDMA/RoCE计数器"
    echo "========================================"

    # 获取RDMA网卡对应的netdev名称
    if command -v ibdev2netdev &>/dev/null; then
        local mappings=$(ibdev2netdev 2>/dev/null | tail -n +2)
        if [ -n "$mappings" ]; then
            log_info "RDMA设备与网卡映射关系:"
            echo "$mappings" | sed 's/^/    /'
            echo ""
        fi
    fi

    # 遍历所有网卡，检查RDMA相关计数器
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        # 跳过lo和docker等非物理接口
        [[ "$iface" == "lo" || "$iface" == docker* ]] && continue

        if ! command -v ethtool &>/dev/null; then
            log_warn "ethtool 未安装，跳过网卡计数器检查"
            return 1
        fi

        local rdma_rx=$(ethtool -S "$iface" 2>/dev/null | grep -iE "rdma.*rx|roce.*rx" | awk '{sum+=$2} END {print sum+0}')
        local rdma_tx=$(ethtool -S "$iface" 2>/dev/null | grep -iE "rdma.*tx|roce.*tx" | awk '{sum+=$2} END {print sum+0}')
        local roce_rx=$(ethtool -S "$iface" 2>/dev/null | grep -iE "roce.*rx.*bytes|roce.*rx.*packets" | awk '{sum+=$2} END {print sum+0}')
        local roce_tx=$(ethtool -S "$iface" 2>/dev/null | grep -iE "roce.*tx.*bytes|roce.*tx.*packets" | awk '{sum+=$2} END {print sum+0}')

        local total_rdma_rx=$((rdma_rx + roce_rx))
        local total_rdma_tx=$((rdma_tx + roce_tx))

        if [ "$total_rdma_rx" -gt 0 ] || [ "$total_rdma_tx" -gt 0 ]; then
            log_info "网卡 $iface 检测到RDMA/RoCE流量:"
            echo "    RDMA RX: $total_rdma_rx  |  RDMA TX: $total_rdma_tx"
        fi
    done
    echo ""
}

# =============================================================================
# 4. 抓包检测RoCEv2流量（UDP 4791端口）
# =============================================================================
check_roce_packets() {
    echo "========================================"
    echo "4. 检测RoCEv2数据包（UDP 4791）"
    echo "========================================"

    if ! command -v tcpdump &>/dev/null; then
        log_warn "tcpdump 未安装，跳过抓包检测"
        return 1
    fi

    # 获取RDMA对应的网卡接口
    local capture_iface=""
    if command -v ibdev2netdev &>/dev/null; then
        capture_iface=$(ibdev2netdev 2>/dev/null | tail -n +2 | head -1 | awk '{print $NF}')
    fi

    if [ -z "$capture_iface" ]; then
        log_warn "无法确定抓包接口，使用第一个非lo接口"
        capture_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    fi

    log_info "在接口 $capture_iface 上检测RoCEv2流量（5秒采样）..."

    # 使用tcpdump检测RoCEv2（UDP 4791），只抓少量包避免阻塞
    local roce_packets=$(timeout 5 tcpdump -i "$capture_iface" -n -c 10 udp port 4791 2>/dev/null | grep -c "RoCE" || echo "0")

    if [ "$roce_packets" -gt 0 ]; then
        log_info "检测到 $roce_packets 个RoCEv2数据包 ✓"
        timeout 3 tcpdump -i "$capture_iface" -n -c 3 udp port 4791 2>/dev/null | sed 's/^/    /'
    else
        log_warn "未检测到RoCEv2数据包（UDP 4791）"
        log_info "注意：RoCEv1（直接以太网封装）不走UDP 4791，需使用ibdump工具检测"
    fi
    echo ""
}

# =============================================================================
# 5. 检查是否有RDMA相关内核模块加载
# =============================================================================
check_rdma_modules() {
    echo "========================================"
    echo "5. 检查RDMA内核模块"
    echo "========================================"

    local modules=$(lsmod | grep -E "ib_|rdma_|mlx5_ib|mlx4_ib" | awk '{print $1}')
    if [ -n "$modules" ]; then
        log_info "已加载的RDMA相关模块:"
        echo "$modules" | sed 's/^/    /'
    else
        log_warn "未发现RDMA相关内核模块"
    fi
    echo ""
}

# =============================================================================
# 6. 检查SMC-R（Shared Memory Communications over RDMA）状态
# =============================================================================
check_smc_r() {
    echo "========================================"
    echo "6. 检查SMC-R状态（如适用）"
    echo "========================================"

    if command -v smcss &>/dev/null; then
        log_info "SMC-R socket状态:"
        smcss 2>/dev/null | sed 's/^/    /' || log_warn "smcss 无输出或执行失败"
    else
        log_warn "smcss 命令未安装（SMC-R工具），跳过检查"
    fi
    echo ""
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║        RDMA 协议流量检测脚本 v1.0                      ║"
    echo "║        检测时间: $(date)                    ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""

    check_rdma_devices
    check_rdma_resources
    check_nic_counters
    check_roce_packets
    check_rdma_modules
    check_smc_r

    echo "========================================"
    echo "检测完成"
    echo "========================================"
    echo ""
    echo "判断标准总结："
    echo "  ✓ rdma res 显示活跃QP → 有RDMA协议流量"
    echo "  ✓ ethtool计数器RDMA/RoCE字段增长 → 有RDMA协议流量"
    echo "  ✓ tcpdump抓到UDP 4791 (RoCEv2) → 有RDMA协议流量"
    echo "  ✗ 仅有TCP流量在RDMA网卡上 → 不是RDMA协议"
    echo ""
}

main "$@"
