echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sysctl -w vm.swappiness=0
sysctl -w kernel.numa_balancing=0
sysctl -w kernel.sched_migration_cost_ns=50000
# bind cpu
export SGLANG_SET_CPU_AFFINITY=1

unset https_proxy
unset http_proxy
unset HTTPS_PROXY
unset HTTP_PROXY
unset ASCEND_LAUNCH_BLOCKING
# cann
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh

export STREAMS_PER_DEVICE=32
export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=600
# MTP OVERLAP
export SGLANG_ENABLE_SPEC_V2=1
export SGLANG_ENABLE_OVERLAP_PLAN_STREAM=1

export SGLANG_NPU_USE_MULTI_STREAM=1
export HCCL_BUFFSIZE=1000
export HCCL_OP_EXPANSION_MODE=AIV
export HCCL_SOCKET_IFNAME=bond1

# Run command ifconfig on two nodes, find out which inet addr has same IP with your node IP. That is your public interface, which should be added here
export HCCL_SOCKET_IFNAME=lo
export GLOO_SOCKET_IFNAME=lo

# DEEPEP
export DEEPEP_NORMAL_LONG_SEQ_ROUND=72
export DEEPEP_NORMAL_LONG_SEQ_PER_ROUND_TOKENS=1024
export DEEPEP_NORMAL_COMBINE_ENABLE_LONG_SEQ=1

export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=600


LOCAL_HOST=192.168.0.3
IP_MASTER=192.168.0.4
MODEL_PATH=/data/nvme0/GLM-5.2-w8a8
RANK=3

python3 -m sglang.launch_server \
    --model-path $MODEL_PATH \
    --attention-backend ascend \
    --device npu \
    --tp-size 32 --nnodes 4 --node-rank $RANK --dist-init-addr $IP_MASTER \
    --chunked-prefill-size 16384 --max-prefill-tokens 131072 \
    --trust-remote-code \
    --host 127.0.0.1 \
    --mem-fraction-static 0.8 \
    --port 8000 \
    --served-model-name glm-5 \
    --cuda-graph-max-bs-decode 32 \
    --moe-a2a-backend deepep \
    --deepep-mode auto \
    --speculative-draft-model-quantization unquant \
    --speculative-algorithm NEXTN --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4  \
    --disable-radix-cache
    NODE_RANK=$RANK