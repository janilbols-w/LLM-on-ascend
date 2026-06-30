#!/bin/bash
# =============================================================================
# Script: rdma_traffic_test.sh
# Description: 使用可用的 RDMA 工具产生真实的 RDMA 流量进行测试
# Usage: 
#   Server端: ./rdma_traffic_test.sh server [backend]
#   Client端: ./rdma_traffic_test.sh client <Server_IP> [backend]
#   backend: auto | pingpong | rping
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 默认参数配置
PORT=18515            # RDMA 通信端口
SIZE=8388608          # 消息大小 (8MB)
ITERS=10000           # 迭代次数
DURATION=10           # 测试持续时间(秒)
BACKEND="${RDMA_BACKEND:-auto}"

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

is_runnable() {
    local bin="$1"
    if ! command -v "$bin" &>/dev/null; then
        return 1
    fi

    if ldd "$(command -v "$bin")" 2>/dev/null | grep -q "LIBPCI_3.8"; then
        return 1
    fi

    return 0
}

backend_to_bin() {
    case "$1" in
        pingpong)
            echo "ibv_rc_pingpong"
            ;;
        rping)
            echo "rping"
            ;;
        *)
            echo ""
            ;;
    esac
}

select_backend() {
    local requested="${1:-$BACKEND}"
    local bin

    case "$requested" in
        auto)
            if is_runnable ibv_rc_pingpong; then
                echo "pingpong"
            elif is_runnable rping; then
                echo "rping"
            else
                echo ""
            fi
            ;;
        pingpong|rping)
            bin="$(backend_to_bin "$requested")"
            if is_runnable "$bin"; then
                echo "$requested"
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

run_pingpong_server() {
    log_info "使用 ibv_rc_pingpong 作为 RDMA 负载工具"
    log_info "正在启动 Server 端，等待 Client 连接..."
    ibv_rc_pingpong
}

run_pingpong_client() {
    local server_ip="$1"
    log_info "使用 ibv_rc_pingpong 连接 ${server_ip} 并产生 RDMA 流量..."
    ibv_rc_pingpong "$server_ip"
}

run_rping_server() {
    log_info "使用 rping 作为 RDMA 负载工具"
    log_info "正在启动 Server 端，等待 Client 连接..."
    rping -s -a 0.0.0.0 -p "$PORT"
}

run_rping_client() {
    local server_ip="$1"
    log_info "使用 rping 连接 ${server_ip}:${PORT} 并产生 RDMA 流量..."
    rping -c -a "$server_ip" -p "$PORT"
}

run_server() {
    local backend
    backend="$(select_backend "$1")"

    if [ -z "$backend" ]; then
        log_error "没有可用的 RDMA 后端可用，请检查 ibv_rc_pingpong 或 rping 是否安装且可运行"
        exit 1
    fi

    if [ "$backend" != "auto" ]; then
        log_info "自动/指定后端选择结果: $backend"
    fi

    case "$backend" in
        pingpong)
            run_pingpong_server
            ;;
        rping)
            run_rping_server
            ;;
    esac
}

run_client() {
    local SERVER_IP=$1
    local backend

    if [ -z "$SERVER_IP" ]; then
        log_error "Client 模式需要指定服务器 IP: ./rdma_traffic_test.sh client <IP>"
        exit 1
    fi

    backend="$(select_backend "$2")"

    if [ -z "$backend" ]; then
        log_error "没有可用的 RDMA 后端可用，请检查 ibv_rc_pingpong 或 rping 是否安装且可运行"
        exit 1
    fi

    if [ "$backend" != "auto" ]; then
        log_info "自动/指定后端选择结果: $backend"
    fi

    case "$backend" in
        pingpong)
            run_pingpong_client "$SERVER_IP"
            ;;
        rping)
            run_rping_client "$SERVER_IP"
            ;;
    esac
}

# --- 主逻辑 ---
if [ $# -lt 1 ]; then
    echo "用法: $0 {server|client} [Server_IP] [backend]"
    echo "backend: auto | pingpong | rping"
    exit 1
fi

case "$1" in
    server)
        run_server "$2"
        ;;
    client)
        run_client "$2" "$3"
        ;;
    *)
        echo "无效参数: $1"
        exit 1
        ;;
esac
