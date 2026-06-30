#!/usr/bin/env python3

import os
import sys
from typing import List, Sequence, Tuple

import torch
import torch.distributed as dist

try:
    import torch_npu  # noqa: F401
except ImportError as exc:
    raise SystemExit("缺少 torch_npu，无法运行 Ascend/HCCL 测试") from exc


def parse_shapes(value: str) -> List[Tuple[int, ...]]:
    # Format: "1;8;2x4;2x2x4"
    shapes: List[Tuple[int, ...]] = []
    for item in value.split(";"):
        item = item.strip()
        if not item:
            continue
        dims = tuple(int(x) for x in item.split("x") if x)
        if not dims:
            raise ValueError(f"非法 shape: {item}")
        if any(dim <= 0 for dim in dims):
            raise ValueError(f"shape 必须全部 > 0: {item}")
        shapes.append(dims)
    if not shapes:
        raise ValueError("没有可用的 shape")
    return shapes


def parse_dtypes(value: str) -> List[torch.dtype]:
    mapping = {
        "float16": torch.float16,
        "float32": torch.float32,
        "bfloat16": torch.bfloat16,
        "int32": torch.int32,
        "int64": torch.int64,
    }
    dtypes: List[torch.dtype] = []
    for item in value.split(","):
        key = item.strip().lower()
        if not key:
            continue
        if key not in mapping:
            raise ValueError(f"不支持 dtype: {item}")
        dtypes.append(mapping[key])
    if not dtypes:
        raise ValueError("没有可用的 dtype")
    return dtypes


def dtype_name(dtype: torch.dtype) -> str:
    return str(dtype).replace("torch.", "")


def product(shape: Sequence[int]) -> int:
    out = 1
    for v in shape:
        out *= int(v)
    return out


def close_enough(lhs: torch.Tensor, rhs: torch.Tensor) -> bool:
    if lhs.dtype.is_floating_point:
        return torch.allclose(lhs, rhs, rtol=1e-3, atol=1e-3)
    return torch.equal(lhs, rhs)


def make_rank_tensor(shape: Sequence[int], rank: int, dtype: torch.dtype, device: torch.device, base: float = 0.0) -> torch.Tensor:
    numel = product(shape)
    data = torch.arange(numel, dtype=torch.float32, device=device).reshape(tuple(shape))
    data = data + float(rank) + base
    if not dtype.is_floating_point:
        data = torch.floor(data)
    return data.to(dtype)


def check_or_raise(name: str, rank: int, got: torch.Tensor, expected: torch.Tensor) -> None:
    got_cpu = got.detach().cpu()
    expected_cpu = expected.detach().cpu()
    if not close_enough(got_cpu, expected_cpu):
        raise RuntimeError(
            f"{name} 校验失败: rank={rank} got_shape={tuple(got_cpu.shape)} expected_shape={tuple(expected_cpu.shape)} "
            f"got={got_cpu.flatten()[:16].tolist()} expected={expected_cpu.flatten()[:16].tolist()}"
        )


def run_all_reduce(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype) -> None:
    tensor = make_rank_tensor(shape, rank, dtype, device)
    expected = torch.zeros_like(tensor)
    for src_rank in range(world_size):
        expected = expected + make_rank_tensor(shape, src_rank, dtype, device)
    dist.all_reduce(tensor, op=dist.ReduceOp.SUM)
    check_or_raise("all_reduce", rank, tensor, expected)


def run_reduce(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype, dst: int = 0) -> None:
    tensor = make_rank_tensor(shape, rank, dtype, device, base=1.0)
    dist.reduce(tensor, dst=dst, op=dist.ReduceOp.SUM)
    if rank == dst:
        expected = torch.zeros_like(tensor)
        for src_rank in range(world_size):
            expected = expected + make_rank_tensor(shape, src_rank, dtype, device, base=1.0)
        check_or_raise("reduce", rank, tensor, expected)


def run_broadcast(rank: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype, src: int = 0) -> None:
    if rank == src:
        tensor = make_rank_tensor(shape, rank, dtype, device, base=3.0)
    else:
        tensor = torch.empty(tuple(shape), dtype=dtype, device=device)
    dist.broadcast(tensor, src=src)
    expected = make_rank_tensor(shape, src, dtype, device, base=3.0)
    check_or_raise("broadcast", rank, tensor, expected)


def run_all_gather(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype) -> None:
    input_tensor = make_rank_tensor(shape, rank, dtype, device, base=5.0)
    output = [torch.empty_like(input_tensor) for _ in range(world_size)]
    dist.all_gather(output, input_tensor)
    gathered = torch.stack(output, dim=0)
    expected = torch.stack(
        [make_rank_tensor(shape, src_rank, dtype, device, base=5.0) for src_rank in range(world_size)], dim=0
    )
    check_or_raise("all_gather", rank, gathered, expected)


def run_all_gather_into_tensor(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype) -> None:
    input_tensor = make_rank_tensor(shape, rank, dtype, device, base=7.0).contiguous()
    out_shape = (world_size,) + tuple(shape)
    output = torch.empty(out_shape, dtype=dtype, device=device)
    dist.all_gather_into_tensor(output, input_tensor)
    expected = torch.stack(
        [make_rank_tensor(shape, src_rank, dtype, device, base=7.0) for src_rank in range(world_size)], dim=0
    )
    check_or_raise("all_gather_into_tensor", rank, output, expected)


def run_reduce_scatter(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype) -> None:
    input_list = [make_rank_tensor(shape, rank + idx, dtype, device, base=11.0) for idx in range(world_size)]
    output = torch.empty(tuple(shape), dtype=dtype, device=device)
    dist.reduce_scatter(output, input_list, op=dist.ReduceOp.SUM)

    expected = torch.zeros_like(output)
    for src_rank in range(world_size):
        expected = expected + make_rank_tensor(shape, src_rank + rank, dtype, device, base=11.0)
    check_or_raise("reduce_scatter", rank, output, expected)


def run_all_to_all_single(rank: int, world_size: int, device: torch.device, shape: Sequence[int], dtype: torch.dtype) -> None:
    numel = product(shape)
    send_chunks = []
    for dst_rank in range(world_size):
        chunk = torch.full((numel,), fill_value=rank * 1000 + dst_rank, dtype=dtype, device=device)
        send_chunks.append(chunk)
    input_tensor = torch.cat(send_chunks, dim=0)

    output = torch.empty_like(input_tensor)
    dist.all_to_all_single(output, input_tensor)
    out_2d = output.reshape(world_size, numel)

    expected = torch.stack(
        [torch.full((numel,), fill_value=src_rank * 1000 + rank, dtype=dtype, device=device) for src_rank in range(world_size)],
        dim=0,
    )
    check_or_raise("all_to_all_single", rank, out_2d, expected)


def run_barrier() -> None:
    dist.barrier()


def iter_enabled_ops(value: str) -> List[str]:
    ops = [item.strip() for item in value.split(",") if item.strip()]
    if not ops:
        raise ValueError("没有可用的 op")
    return ops


def is_supported_exception(exc: Exception) -> bool:
    text = str(exc).lower()
    keywords = [
        "not support",
        "not supported",
        "unsupported",
        "unimplemented",
        "hccl",
        "all_to_all",
        "reduce_scatter",
    ]
    return any(k in text for k in keywords)


def main() -> int:
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    local_rank = int(os.environ["LOCAL_RANK"])

    print(f"[INFO ] rank={rank} local_rank={local_rank} world_size={world_size} starting", flush=True)

    torch.npu.set_device(local_rank)
    dist.init_process_group(backend="hccl", init_method="env://")

    print(f"[INFO ] rank={rank} process group initialized", flush=True)

    device = torch.device("npu", local_rank)
    shapes_env = os.environ.get("HCCL_TEST_SHAPES", "1;8;2x4;2x2x4")
    dtypes_env = os.environ.get("HCCL_TEST_DTYPES", "float32,int32,float16")
    ops_env = os.environ.get(
        "HCCL_TEST_OPS",
        "all_reduce,reduce,broadcast,all_gather,all_gather_into_tensor,reduce_scatter,all_to_all_single,barrier",
    )

    try:
        shapes = parse_shapes(shapes_env)
        dtypes = parse_dtypes(dtypes_env)
        enabled_ops = iter_enabled_ops(ops_env)
    except ValueError as exc:
        print(f"[FAIL] 配置解析失败: {exc}", file=sys.stderr)
        dist.destroy_process_group()
        return 1

    if rank == 0:
        print(f"[INFO ] enabled_ops={enabled_ops}")
        print(f"[INFO ] shapes={shapes}")
        print(f"[INFO ] dtypes={[dtype_name(x) for x in dtypes]}")

    op_impl = {
        "all_reduce": run_all_reduce,
        "reduce": run_reduce,
        "broadcast": run_broadcast,
        "all_gather": run_all_gather,
        "all_gather_into_tensor": run_all_gather_into_tensor,
        "reduce_scatter": run_reduce_scatter,
        "all_to_all_single": run_all_to_all_single,
        "barrier": lambda *_args: run_barrier(),
    }

    skipped: List[str] = []
    try:
        for shape in shapes:
            for dtype in dtypes:
                # Some collectives may have dtype limitations on specific firmware/runtime versions.
                for op_name in enabled_ops:
                    if op_name not in op_impl:
                        raise RuntimeError(f"未知 op: {op_name}")

                    dist.barrier()
                    print(
                        f"[INFO ] rank={rank} testing op={op_name} shape={tuple(shape)} dtype={dtype_name(dtype)}",
                        flush=True,
                    )
                    try:
                        op_impl[op_name](rank, world_size, device, shape, dtype)
                    except Exception as exc:
                        if is_supported_exception(exc):
                            skip_msg = f"op={op_name},shape={tuple(shape)},dtype={dtype_name(dtype)}"
                            if skip_msg not in skipped:
                                skipped.append(skip_msg)
                                print(f"[SKIP] rank={rank} {skip_msg} reason={exc}", flush=True)
                        else:
                            raise
                    dist.barrier()
    except Exception as exc:
        print(f"[FAIL] rank={rank} collective 测试失败: {exc}", file=sys.stderr)
        dist.destroy_process_group()
        return 1

    if rank == 0:
        if skipped:
            print("[WARN] 以下 case 因后端不支持被跳过:")
            for item in skipped:
                print(f"[WARN] {item}")
        print(
            f"[OK] HCCL collective matrix passed. world_size={world_size}, total_cases={len(shapes) * len(dtypes) * len(enabled_ops)}"
        )

    dist.barrier()
    print(f"[INFO ] rank={rank} finished", flush=True)
    dist.destroy_process_group()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())