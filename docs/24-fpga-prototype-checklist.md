# FPGA Prototype Checklist

本文是 15.6 的 FPGA 原型 bring-up 清单。它用于把当前 RDMA SmartNIC DUT 推向真实 FPGA 板卡验证前的集成评审、bitstream 生成前检查、上板后 smoke 验证和主机驱动加载。当前仓库尚未选定具体 FPGA board，因此所有板级假设都必须在 board-specific notes 中显式填写，不能隐式写进 RTL、驱动或通用 CI。

本清单不引入 Vivado、Quartus 或厂商 IP 工程文件，不实现特定板卡 RTL wrapper，也不要求 generic CI 拥有 FPGA 工具或硬件。

## Status Template

每次 board bring-up 建议复制这一段到 board-specific notes：

| Item | Value |
| --- | --- |
| Board name / revision | TBD |
| FPGA part / speed grade | TBD |
| PCIe slot / host platform | TBD |
| Ethernet cage / cable / optics | TBD |
| PCIe IP core and version | TBD |
| MAC/PCS/PHY IP core and version | TBD |
| Constraint files | TBD |
| Bitstream build command | TBD |
| Programming method | TBD |
| Driver branch / commit | TBD |
| Known limitations / errata | TBD |

## Pre-Flight Checklist

完成以下项目后再开始板级 bitstream 集成：

- [ ] 选定 FPGA board、FPGA part、speed grade 和 board revision。
- [ ] 确认 PCIe slot 支持目标 generation 和 lane width，且 BIOS 没有限制 slot bifurcation、ACS、IOMMU 或 ASPM 行为。
- [ ] 确认 Ethernet port speed、connector、optics/cable、MAC/PHY IP 和 line-rate license。
- [ ] 确认 PCIe reference clock、MAC reference clock、management clock、reset source 和 JTAG/programming path。
- [ ] 确认 PCIe BAR layout 与 `docs/03-pcie-endpoint.md`、`docs/04-pcie-bar-decoder.md` 和 Linux driver CSR/UAPI 文档一致。
- [ ] 确认 top-level DUT wrapper 只做厂商 IP 适配，不改变内部 ready/valid 协议语义。
- [ ] 确认 generic CI 不依赖 FPGA 工具、板卡、license server 或硬件 cable。

## Board Selection

选择 FPGA board 时记录并评审：

- [ ] FPGA part number、package、speed grade、temperature grade。
- [ ] Board vendor、board revision、schematic revision 和 BOM revision。
- [ ] PCIe generation、lane width、edge connector 形态和 host slot 兼容性。
- [ ] Host BIOS 设置：Above 4G decoding、SR-IOV、IOMMU、ASPM、PCIe link speed override。
- [ ] DDR、HBM 或 external memory 资源。当前 DUT 不要求外部 packet buffer，但 board-level debug 或 large trace buffer 可能需要。
- [ ] Ethernet port 数量、line rate、connector type、optics/cable requirement。
- [ ] MAC/PCS/PHY availability、license 状态和支持的 line rates。
- [ ] Clock source：PCIe refclk、MAC refclk、free-running management clock、板上 oscillator jitter。
- [ ] Reset and management interfaces：PERST#、board reset button、I2C/PMBus、UART、JTAG。
- [ ] JTAG/programming method：USB cable、BMC、remote lab controller、flash boot mode。
- [ ] Power、cooling、airflow、thermal sensor、maximum board power 和 lab PSU/headroom。
- [ ] 已知 errata：PCIe equalization、retimer、QSFP cage、clock mux、reset polarity 或 power sequencing 限制。

## PCIe IP Wrapper

PCIe wrapper 必须把厂商 PCIe endpoint IP 隔离在稳定内部接口之外。评审项：

- [ ] 选定 PCIe IP core 和 version，并记录生成参数。
- [ ] 配置 PCIe generation、lane width、max payload size、max read request size、tag count、completion boundary。
- [ ] 配置 BAR0 Doorbell aperture、BAR2 CSR aperture、BAR4 MSI-X table/PBA aperture，和 RTL/driver 文档保持一致。
- [ ] 映射 AXI-Stream、Avalon-ST 或 vendor user interface 到 DUT 内部 TLP/control/DMA ready-valid 接口。
- [ ] 明确 requester ID、completer ID、PF/VF function identity 传递方式。
- [ ] 配置 MSI/MSI-X capability、vector count、table BAR 和 PBA offset。
- [ ] 记录 DMA read/write TLP 数据位宽、byte enable、tag、completion status 和 backpressure 行为。
- [ ] 定义 reset sequencing：PERST#、PCIe hard IP reset、user reset、core reset 的释放顺序。
- [ ] 定义 link training observability：LTSSM state、link up、negotiated speed、negotiated width。
- [ ] 确认 unsupported PCIe features：ATS/PRI/PASID、AER、SR-IOV VF instantiation、relaxed ordering、atomic ops。

Host-side PCIe smoke commands:

```bash
lspci -nn | grep -i smartnic
lspci -vv -s <bus:dev.fn> | egrep 'LnkCap|LnkSta|Region|MSI-X'
sudo setpci -s <bus:dev.fn> COMMAND
sudo lspci -xxxx -s <bus:dev.fn> | head
```

Pass criteria:

- Device enumerates with expected vendor/device ID.
- BAR0/BAR2/BAR4 are assigned and have expected size.
- Link speed and width match board/IP expectation or documented fallback.
- MSI-X capability is visible when enabled.
- Driver can read version/feature CSR through BAR2.

## MAC IP Wrapper

MAC wrapper 必须隔离 MAC/PCS/PHY IP，同时向 packet parser/builder 暴露稳定 frame stream。

- [ ] 选定 MAC、PCS、FEC、PHY IP core 和 version。
- [ ] 记录 line rate：10G/25G/40G/50G/100G，connector 和 optics/cable requirement。
- [ ] 记录 DUT-facing interface：GMII、XGMII、XLGMII、AXI-Stream、Avalon-ST 或 vendor-specific stream。
- [ ] 明确 TX/RX clock domains、data width、tkeep/tlast/tuser、underflow/overflow/error 标志。
- [ ] 明确 FCS insertion/checking 行为：MAC 自动插入、DUT 插入、BFM 插入或测试中忽略。
- [ ] 配置 MTU/jumbo frame 能力，至少覆盖 RoCEv2 PMTU smoke。
- [ ] 配置 pause/PFC support，说明 PFC frames 是否由 MAC IP 处理或交给 DUT。
- [ ] 记录 loopback mode：internal PCS loopback、PHY serial loopback、near-end/far-end loopback、cable loopback。
- [ ] 记录 link status counters、packet counters、bad FCS counters、alignment/block lock status。
- [ ] 定义 reset sequencing：MAC reset、PCS reset、PHY reset、FEC lock、link-up 后释放 packet datapath。
- [ ] 记录 unsupported Ethernet features：VLAN offload、checksum offload、RSS、PTP timestamp、multicast filtering。

Packet-path smoke commands depend on board tooling. At minimum collect:

```bash
ethtool <netdev>
ethtool -S <netdev> | egrep 'rx|tx|fcs|err|pause|pfc'
ip link show <netdev>
```

If no Linux netdev exists for this prototype, expose equivalent MAC counters through CSR/debug registers and record the command used to read them.

## Clocks And Resets

Clock and reset review must happen before timing closure:

- [ ] List all DUT clock domains: core/control, PCIe user, DMA/TLP, MAC TX, MAC RX, management/debug.
- [ ] Record PCIe reference clock frequency and PCIe user clock frequency after IP generation.
- [ ] Record MAC/PHY reference clock frequencies and recovered clock usage.
- [ ] Record simulation clock assumptions and map them to FPGA clocks.
- [ ] Mark CDC boundaries: PCIe user to core, MAC RX to core, core to MAC TX, management to core, interrupt/control crossings.
- [ ] Confirm CDC implementation: async FIFO, two-flop sync, handshake synchronizer, reset synchronizer.
- [ ] Record reset sources: PERST#, board reset, software CSR reset, IP reset done, PLL/MMCM lock, PHY link-up.
- [ ] Confirm reset polarity and synchronous/asynchronous behavior at each module boundary.
- [ ] Define reset deassertion order:
  1. Board power good and clocks stable.
  2. PLL/MMCM lock.
  3. PCIe hard IP exits reset and reaches link-up.
  4. MAC/PHY resets release and link becomes stable.
  5. Core reset releases.
  6. Driver performs CSR reset and feature discovery.
- [ ] Verify datapath reset is held until required PCIe/MAC status is stable.

## Constraints

Board-specific constraint files must be reviewed like source code:

- [ ] Pin constraints for PCIe refclk, PERST#, PCIe lanes, Ethernet lanes, refclks, management, JTAG, LEDs/debug.
- [ ] Timing constraints for all primary clocks.
- [ ] Generated clocks and derived clocks from PLL/MMCM, PCIe IP and MAC IP.
- [ ] Asynchronous clock groups for unrelated PCIe, MAC, management and debug clocks.
- [ ] CDC-related false paths or max-delay exceptions, tied to documented synchronizers.
- [ ] Input/output delay constraints for management interfaces if applicable.
- [ ] Board-specific XDC/SDC file names and source order.
- [ ] Vendor IP generated constraints are included and reviewed, not blindly accepted.
- [ ] DRC critical warnings reviewed and either fixed or waived with rationale.
- [ ] Timing signoff: setup, hold, pulse width, clock interaction and unconstrained paths clean.

Suggested review commands:

```bash
# Vivado-style, if Vivado is the selected flow.
report_timing_summary -file timing_summary.rpt
report_clock_interaction -file clock_interaction.rpt
report_cdc -file cdc.rpt
report_drc -file drc.rpt

# Quartus-style, if Quartus is the selected flow.
report_timing
report_clock_fmax_summary
report_exceptions
```

These commands are documentation examples only; generic CI must not require vendor tools.

## Loopback And Smoke Bring-Up

Use loopback in layers so failures localize quickly:

- [ ] CSR smoke: read version/features, write/read scratch CSR, issue reset, confirm status returns healthy.
- [ ] PCIe DMA loopback: host-to-card and card-to-host memory read/write smoke if a DMA loopback hook exists.
- [ ] Doorbell-to-CQE loopback: post a minimal WR, ring SQ/RQ Doorbell, observe CQE and optional MSI-X.
- [ ] MAC internal loopback: enable MAC/PCS loopback, send packet, check TX/RX counters and no FCS/alignment errors.
- [ ] DUT packet loopback: packet_builder output loops to parser input, verify BTH/QPN/PSN/payload and CQE path.
- [ ] External cable loopback: connect port TX/RX or use switch loopback, verify link, packet counters and payload.
- [ ] Error counter smoke: intentionally send malformed packet or invalid key where safe, confirm error counter increments.
- [ ] Interrupt smoke: arm CQ, trigger completion, confirm MSI-X vector and poll wakeup.

Suggested host commands:

```bash
make -C drivers/linux
sudo insmod drivers/linux/smartnic.ko
dmesg | tail -100
lspci -vv -s <bus:dev.fn> | egrep 'LnkSta|MSI-X|Region'
make -C tools
sudo ./tools/smartnicctl info --device /dev/smartnic0
sudo ./tools/smartnicctl reset --device /dev/smartnic0
sudo SMARTNIC_DEV=/dev/smartnic0 bash tests/run_driver_integration.sh
```

If userspace provider and RDMA stack are enabled:

```bash
ibv_devices
ibv_devinfo -d <verbs-device>
SMARTNIC_PROVIDER_DEVICE=/dev/smartnic0 ./examples/smartnic_minimal_verbs_example
```

Pass/fail expectations:

- Register read/write and reset commands complete without timeout.
- PCIe link is stable across reset and driver reload.
- DMA smoke leaves expected host memory contents.
- Packet counters increase only on expected paths.
- CQE status is success for valid WRs and expected error for invalid WRs.
- No kernel oops, AER fatal error, CQ overflow, unbounded retry, or wedged reset.

## Host Driver Loading

Host-side checklist:

- [ ] Kernel headers match the running kernel.
- [ ] Required kernel config is available for PCI, MSI-X, DMA coherent allocations, char devices and mmap.
- [ ] Build driver:

```bash
make -C drivers/linux
```

- [ ] Load driver:

```bash
sudo insmod drivers/linux/smartnic.ko
```

- [ ] Verify enumeration and BAR assignment:

```bash
lspci -nn | grep -i smartnic
lspci -vv -s <bus:dev.fn>
```

- [ ] Check dmesg:

```bash
dmesg | egrep -i 'smartnic|pcie|aer|msi|dma' | tail -100
```

- [ ] Verify device node and permissions:

```bash
ls -l /dev/smartnic*
```

- [ ] Run control smoke:

```bash
make -C tools
sudo ./tools/smartnicctl info --device /dev/smartnic0
sudo ./tools/smartnicctl reset --device /dev/smartnic0
```

- [ ] Run optional provider visibility checks only when userspace provider is installed:

```bash
ibv_devices
pkg-config --cflags --libs libsmartnic-provider
```

- [ ] Unload cleanly:

```bash
sudo rmmod smartnic
dmesg | tail -50
```

Common failure signatures:

| Symptom | Likely cause | Recovery |
| --- | --- | --- |
| Device missing from `lspci` | PCIe link training, PERST#, power, BIOS slot setting | Check LTSSM, slot speed, refclk, retimer, board power |
| BAR not assigned | BAR size mismatch, host resource exhaustion, invalid config-space wrapper | Check BAR masks and `dmesg` PCI resource allocation |
| Driver probe timeout | CSR reset/status path not connected or clock/reset held | Read raw BAR2 CSR, verify core reset and PCIe user clock |
| DMA mask failure | Host platform/IOMMU limitation | Try different slot/platform, check BIOS/IOMMU settings |
| MSI-X not firing | MSI-X table BAR/PBA mapping, mask bit, vector data/address | Check `lspci -vv`, driver IRQ logs, MSI-X CSR counters |
| MAC link down | Optics/cable/FEC/line-rate mismatch or PHY reset | Check module presence, FEC mode, PCS block lock, loopback |
| CQE missing | Doorbell decode, QP/CQ context, DMA write or interrupt path | Run Doorbell-to-CQE loopback with counters enabled |

## Post-Programming Checklist

After programming the FPGA:

- [ ] Confirm board power, temperature and fan status.
- [ ] Confirm PCIe link-up before loading the driver.
- [ ] Confirm MAC/PHY link-up or selected loopback mode.
- [ ] Confirm CSR version/features are readable.
- [ ] Run reset through CSR and verify health returns to ready.
- [ ] Run one no-DMA CSR smoke, one DMA smoke and one packet loopback smoke.
- [ ] Save `lspci -vv`, `dmesg`, timing summary, DRC summary and board-specific notes with the bitstream hash.

## Known Limitations

- No FPGA board is selected in the generic repository state.
- No vendor-specific IP generation scripts or generated constraints are committed by this task.
- Generic CI must skip FPGA hardware validation unless a board-specific job explicitly opts in.
- Several RTL paths are still prototype/minimal implementations; use `docs/23-top-level-integration.md`, `docs/testing.md` and OpenSpec task status to decide which smoke tests are meaningful.
- This checklist does not replace timing closure, SI validation, thermal validation or vendor IP signoff.

