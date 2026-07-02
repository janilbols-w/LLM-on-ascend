# this obtained through ifconfig
# nic_name is the network interface name corresponding to local_ip of the current node
nic_name="bond1"
local_ip="192.168.0.4"

# The value of node0_ip must be consistent with the value of local_ip set in node0 (master node)
node0_ip="192.168.0.4"

model_path=/data/nvme0/GLM-5.2-w8a8

export HCCL_OP_EXPANSION_MODE="AIV"
export HCCL_IF_IP=$local_ip
export GLOO_SOCKET_IFNAME=$nic_name
export TP_SOCKET_IFNAME=$nic_name
export HCCL_SOCKET_IFNAME=$nic_name
export VLLM_RPC_TIMEOUT=360000
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=3000
export HCCL_EXEC_TIMEOUT=200
export HCCL_CONNECT_TIMEOUT=120
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ACL_OP_INIT_MODE=1
#export VLLM_ASCEND_ENABLE_FLASHCOMM1=1
#export USE_MULTI_GROUPS_KV_CACHE=1
#export USE_MULTI_BLOCK_POOL=1
export TASK_QUEUE_ENABLE=1
export CPU_AFFINITY_CONF=1
export VLLM_ENGINE_READY_TIMEOUT_S=1200

export LMCACHE_USE_EXPERIMENTAL=True
export LMCACHE_CHUNK_SIZE=256
export LMCACHE_LOCAL_CPU=TRUE
export LMCACHE_MAX_LOCAL_CPU_SIZE=64

export VLLM_VERSION=0.21.0
vllm serve $model_path \
    --max_model_len 200000  \
    --max-num-batched-tokens 4096 \
    --served-model-name glm-52 \
    --seed 1024 \
    --gpu-memory-utilization 0.95 \
    --api-server-count 1 \
    --max-num-seqs 32 \
    --data-parallel-size 4 \
    --data-parallel-size-local 1 \
    --data-parallel-address $node0_ip \
    --data-parallel-rpc-port 13389 \
    --tensor-parallel-size 8 \
    --enable-expert-parallel \
    --quantization ascend \
    --port 7000 \
    --safetensors-load-strategy 'prefetch' \
    --block-size 128 \
    --async-scheduling \
    --additional-config '{"fuse_muls_add": true, "multistream_overlap_shared_expert": true, "ascend_compilation_config": {"enable_npugraph_ex": true}}' \
    --compilation-config '{"cudagraph_mode": "FULL_DECODE_ONLY"}' \
    --speculative-config '{"num_speculative_tokens": 5, "method": "deepseek_mtp"}' \
    --kv-transfer-config '{"kv_connector":"LMCacheAscendConnector","kv_role":"kv_both"}' \
    2>&1 | tee ./log/node0.`date +%y%m%d%H%M`.log