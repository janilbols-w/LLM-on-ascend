local_ip="192.168.0.3"
node0_ip="192.168.0.5"
export IFNAME="bond1"
MODEL_PATH=/data/nvme0/DeepSeek-V4-Pro-w4a8-mtp

export HCCL_IF_IP=$local_ip
export GLOO_SOCKET_IFNAME="$IFNAME"
export TP_SOCKET_IFNAME="$IFNAME"
export HCCL_SOCKET_IFNAME="$IFNAME"
export HCCL_BUFFSIZE=512
export ASCEND_RT_VISIBLE_DEVICES=0,1,2,3,4,5,6,7

export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ACL_OP_INIT_MODE=1
export VLLM_ENGINE_READY_TIMEOUT_S=3600
export HCCL_OP_EXPANSION_MODE="AIV"

export TASK_QUEUE_ENABLE=1
export VLLM_ASCEND_ENABLE_FLASHCOMM1=1

export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2:$LD_PRELOAD

export HCCL_CONNECT_TIMEOUT=7200
export ASCEND_CONNECT_TIMEOUT=10000
export ASCEND_TRANSFER_TIMEOUT=10000
export VLLM_RPC_TIMEOUT=1800000

export VLLM_VERSION=0.21.0
vllm serve $MODEL_PATH \
  --host 0.0.0.0 \
  --port 10010 \
  --max-model-len 2048 \
  --max-num-batched-tokens 4096 \
  --served-model-name dsv4 \
  --gpu-memory-utilization 0.9 \
  --max-num-seqs 16 \
  --data-parallel-size 4 \
  --tensor-parallel-size 8 \
  --data-parallel-size-local 1 \
  --data-parallel-start-rank 1 \
  --data-parallel-address $node0_ip  \
  --enable-expert-parallel \
  --quantization ascend \
  --no-enable-prefix-caching \
  --tokenizer-mode deepseek_v4 \
  --tool-call-parser deepseek_v4 \
  --enable-auto-tool-choice \
  --reasoning-parser deepseek_v4 \
  --async-scheduling \
  --safetensors-load-strategy 'prefetch' \
  --block-size 128 \
  --headless \
  --speculative-config '{
     "num_speculative_tokens": 1,
     "method": "mtp",
     "enforce_eager": true
  }' \
  --additional-config '{
     "ascend_compilation_config":{
        "enable_npugraph_ex":true,
        "enable_static_kernel":false
     },
     "enable_cpu_binding": true,
     "enable_shared_expert_dp": true,
     "multistream_overlap_shared_expert":true
  }' \
  --compilation-config '{
     "cudagraph_mode":"FULL_DECODE_ONLY"
  }' \
  --model-loader-extra-config '{
     "enable_multithread_load": "true",
     "num_threads": 128
  }' \
  2>&1 | tee ./node3.log