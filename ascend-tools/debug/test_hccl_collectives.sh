#!/usr/bin/env bash
set -euo pipefail

# Use as:
#   node0: ./test_hccl_collectives.sh node0
#   node1: ./test_hccl_collectives.sh node1

ROLE="${1:-}"

if [[ "$ROLE" != "node0" && "$ROLE" != "node1" ]]; then
    echo "Usage: $0 {node0|node1}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Adjust these values to your environment.
nic_name="bond1"
local_ip="${LOCAL_IP:-}"
node0_ip="${NODE0_IP:-192.168.0.4}"
master_port="${MASTER_PORT:-29500}"
nnodes="${NNODES:-2}"
nproc_per_node="${NPROC_PER_NODE:-8}"

if [[ -z "$local_ip" ]]; then
    case "$ROLE" in
        node0) local_ip="192.168.0.4" ;;
        node1) local_ip="192.168.0.2" ;;
    esac
fi

export HCCL_OP_EXPANSION_MODE="AIV"
export HCCL_IF_IP="$local_ip"
export GLOO_SOCKET_IFNAME="$nic_name"
export TP_SOCKET_IFNAME="$nic_name"
export HCCL_SOCKET_IFNAME="$nic_name"
export HCCL_CONNECT_TIMEOUT=120
export HCCL_EXEC_TIMEOUT=200
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export TORCH_DISTRIBUTED_DEBUG=DETAIL

node_rank=0
if [[ "$ROLE" == "node1" ]]; then
    node_rank=1
fi

LOG_FILE=./output/`date +%y%m%d-%H%M`.${ROLE}.log
set -x

python3 -m torch.distributed.run \
    --nnodes="$nnodes" \
    --nproc_per_node="$nproc_per_node" \
    --node_rank="$node_rank" \
    --master_addr="$node0_ip" \
    --master_port="$master_port" \
    "$SCRIPT_DIR/test_hccl_collectives.py" 2>&1 | tee $LOG_FILE