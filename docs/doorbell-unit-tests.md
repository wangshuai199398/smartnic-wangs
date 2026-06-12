# Doorbell Unit Tests

本文说明 3.6 阶段新增和完善的 Doorbell 单元测试。测试目标是验证 Doorbell path 的最小行为，不模拟完整 PCIe TLP，不读取真实 WQE/RQE，不执行 RDMA 操作，也不生成真实 CQE 或 MSI-X。

## 测试范围

Doorbell path 当前被拆成五类模块：

```text
BAR0 write
  -> doorbell_decoder
  -> doorbell_access_check
  -> sq_doorbell_handler / rq_doorbell_handler / cq_arm_doorbell_handler
```

3.6 的测试覆盖这些模块的边界行为：

| 测试文件 | 覆盖模块 | 覆盖行为 |
| --- | --- | --- |
| `sim/cocotb/test_doorbell_decoder.py` | `doorbell_decoder` | BAR0 SQ/RQ/CQ arm offset 解码、非法 offset、未对齐 offset |
| `sim/cocotb/test_doorbell_access_check.py` | `doorbell_access_check` | PF 允许、enabled VF 窗口内允许、disabled VF 拒绝、cross-VF QP/CQ 拒绝、QPN/CQN 越界拒绝 |
| `sim/cocotb/test_sq_doorbell.py` | `sq_doorbell_handler` | SQ producer index 更新、producer wraparound、invalid QPN、payload 格式错误、access denied |
| `sim/cocotb/test_rq_doorbell.py` | `rq_doorbell_handler` | RQ producer index 更新、producer wraparound、invalid QPN、payload 格式错误、access denied |
| `sim/cocotb/test_cq_arm_doorbell.py` | `cq_arm_doorbell_handler` | CQ consumer index 更新、armed 标志、solicited-only、invalid CQN、access denied |

## 运行方式

从仓库根目录运行：

```sh
make doorbell-test
```

也可以进入 Cocotb 目录运行：

```sh
make -C sim/cocotb doorbell-tests
```

如果本机没有安装 `cocotb` 或 `verilator`，测试入口会提示跳过。仍然可以先用 Python 编译检查测试文件语法：

```sh
PYTHONPYCACHEPREFIX=/private/tmp/smartnic_pycache python3 -m py_compile \
  sim/cocotb/test_doorbell_decoder.py \
  sim/cocotb/test_doorbell_access_check.py \
  sim/cocotb/test_sq_doorbell.py \
  sim/cocotb/test_rq_doorbell.py \
  sim/cocotb/test_cq_arm_doorbell.py
```

## 与需求的关系

### Doorbell Interface

`test_doorbell_decoder.py` 覆盖 BAR0 Doorbell aperture 的地址分类：

- `0x000` 映射为 SQ Doorbell。
- `0x008` 映射为 RQ Doorbell。
- `0x010` 映射为 CQ arm Doorbell。
- 非法 page 内 offset 和未对齐 offset 返回错误。

`test_sq_doorbell.py`、`test_rq_doorbell.py`、`test_cq_arm_doorbell.py` 覆盖 Doorbell payload 到内部更新事件的转换。

### QP Lifecycle Management

SQ 和 RQ 测试覆盖 producer index 更新、producer wraparound、invalid QPN 和 access denied。它们不读取 WQE/RQE，只验证 Doorbell 是否能安全地形成后续 QP manager 可消费的更新事件。

### CQ Lifecycle and Completion Queue

CQ arm 测试覆盖 consumer index、armed 标志和 solicited-only 标志。它们不写 CQE、不触发 MSI-X，只验证后续 CQ manager 和 interrupt moderation 需要的 arm 状态输入。

### SR-IOV Function Isolation

`test_doorbell_access_check.py` 覆盖 PF/VF ownership 和资源窗口检查，确保 disabled VF、cross-VF 访问、QPN/CQN 越界访问不会继续产生有效 Doorbell 副作用。

## 为什么这样设计

Doorbell path 是 RDMA fast path。若一开始就做端到端 PCIe、QP、CQ、DMA、RoCEv2 联合仿真，问题定位会很困难。3.6 先把地址解码、权限检查、payload 解析分开测清楚，后续实现 QP manager、CQ manager 和 completion path 时，可以更放心地复用这些边界。
