# RDMA Write 简化数据通路

本文只解释一条简化的 RDMA Write 路径，帮助理解数据从用户程序进入网卡、再被封装成 RoCEv2/Ethernet 报文发出去的大致过程。

当前文档是教学用框图说明，不代表已经实现了 RTL、驱动或 Verbs 代码。

## 总览

一次 RDMA Write 可以粗略理解为：

```text
user app
  -> libsmartnic
  -> kernel driver
  -> doorbell
  -> QP
  -> DMA
  -> RoCEv2 packet
  -> Ethernet
```

更直观的框图：

```text
+-------------+       +--------------+       +---------------+
|  user app   | ----> | libsmartnic  | ----> | kernel driver |
+-------------+       +--------------+       +---------------+
       |                      |                       |
       | post RDMA Write WR   | build WQE / mmap      | create QP/CQ/MR
       |                      | queue + doorbell      | pin memory / setup HW
       v                      v                       v
+-------------------------------------------------------------+
|                         SmartNIC                            |
|                                                             |
|  +----------+     +------+     +------+     +-------------+ |
|  | doorbell | --> |  QP  | --> | DMA  | --> | RoCEv2 pkt  | |
|  +----------+     +------+     +------+     +-------------+ |
|                         |             read host memory       |
+-------------------------+-----------------------------------+
                                                  |
                                                  v
                                          +---------------+
                                          |   Ethernet    |
                                          +---------------+
```

## 1. user app：应用提交 RDMA Write

用户程序通过 Verbs 风格 API 发起 RDMA Write。

它通常会准备这些信息：

- 本地 buffer 地址
- 本地 buffer 长度
- 本地 `lkey`
- 远端虚拟地址 `remote_addr`
- 远端访问 key：`rkey`
- 目标 QP
- Work Request ID：`wr_id`

在概念上，应用会调用类似：

```text
ibv_post_send(qp, rdma_write_wr, &bad_wr)
```

这里的 `rdma_write_wr` 表示“我要把本地内存中的一段数据写到远端机器的某个内存地址”。

## 2. libsmartnic：构造 WQE 并准备 Doorbell

`libsmartnic` 是用户态库。它把应用传入的 Verbs Work Request 转换成硬件更容易理解的 WQE。

WQE 可以理解为网卡的任务单，里面会包含：

- 操作类型：RDMA Write
- 本地 SGE 列表
- 数据长度
- 远端地址
- 远端 `rkey`
- `wr_id`
- 是否需要 completion

`libsmartnic` 不应该每次都通过系统调用提交数据路径请求。更典型的做法是：

1. 把 WQE 写入 mmap 出来的 Send Queue。
2. 使用内存屏障确保 WQE 内容先对硬件可见。
3. 写一次 Doorbell 通知硬件：“这个 QP 有新任务了。”

## 3. kernel driver：负责控制面准备

Linux kernel driver 不直接搬运每个 RDMA Write 的数据。它主要负责控制面。

在 RDMA Write 真正发生前，驱动已经做过这些准备：

- 创建 PD
- 创建 CQ
- 创建 QP
- 注册 MR
- pin 用户内存页面
- 建立 MR 到硬件表项的映射
- 分配 SQ/RQ/CQ buffer
- 把 Doorbell 页面 mmap 给用户态
- 配置 QP 到 RTS 状态

所以在 fast path 上，RDMA Write 通常不需要每次进入内核。内核驱动提前把资源和映射都准备好，后续由用户态库和硬件配合完成。

## 4. doorbell：通知硬件有新 WQE

Doorbell 是用户态通知网卡硬件的快速入口。

当 `libsmartnic` 写 Doorbell 时，硬件看到的信息大致是：

- 哪个 QP 有新 WQE
- SQ producer index 更新到了哪里
- 这是 SQ Doorbell 还是 RQ/CQ Doorbell

Doorbell 本身不携带完整数据。它只是一个通知信号：

```text
QP X 的 Send Queue 里有新任务，请去取。
```

## 5. QP：读取和解释 Work Queue

QP 是 Queue Pair，RDMA 的核心执行上下文。

对于 RDMA Write，QP 硬件逻辑会：

1. 根据 Doorbell 找到对应 QP。
2. 读取 Send Queue 中的新 WQE。
3. 检查 QP 是否处于 RTS 状态。
4. 解码 WQE，确认这是 RDMA Write。
5. 取出本地 SGE、远端地址、rkey、长度等信息。
6. 把数据搬运请求交给 DMA。
7. 把报文生成请求交给 RoCEv2 发送路径。

QP 还需要维护传输相关状态，例如：

- QP number
- QP type：RC 或 UD
- PSN
- retry 状态
- 关联的 CQ
- 关联的 PD

在简化理解中，QP 就是“这条 RDMA 连接或通信端点的状态管理器”。

## 6. DMA：从主机内存读取数据

RDMA Write 的数据来自本地主机内存。

DMA 引擎会根据 WQE 里的 SGE 信息读取用户 buffer：

```text
local virtual address + lkey
  -> MR lookup
  -> physical address
  -> PCIe Memory Read
  -> payload data
```

这里 MR 检查很关键。硬件不能随便读主机内存，必须确认：

- `lkey` 有效
- 地址在 MR 范围内
- 长度没有越界
- PD 匹配
- 本地读权限允许

如果检查失败，DMA 不应该继续读数据，而应该产生错误 completion。

如果检查成功，DMA 会通过 PCIe 从主机内存读出 payload。

## 7. RoCEv2 packet：封装 RDMA Write 报文

DMA 读出的 payload 需要被封装成 RoCEv2 报文。

一个简化的 RDMA Write over RoCEv2 报文包含：

```text
Ethernet header
  IPv4 header
    UDP header
      BTH
      RETH
      payload
      ICRC
```

其中：

- BTH 表示 Base Transport Header，包含 opcode、目标 QPN、PSN 等。
- RETH 表示 RDMA Extended Transport Header，包含远端地址、rkey、DMA 长度。
- payload 是从本地主机内存 DMA 读取出来的数据。
- ICRC 是 RDMA 协议使用的校验字段。

如果数据比较大，硬件还需要按 MTU/PMTU 拆分成多个包。

## 8. Ethernet：发送到网络

最后，packet builder 生成的 RoCEv2 报文会交给 Ethernet MAC。

之后数据路径变成：

```text
RoCEv2 packet
  -> Ethernet MAC
  -> PHY
  -> network switch
  -> remote RDMA NIC
```

远端 RDMA NIC 收到 RDMA Write 后，会检查远端 `rkey` 和远端地址权限，然后把 payload 写入远端主机内存。

## 简化时序图

```text
user app        libsmartnic       SmartNIC QP        DMA           RoCEv2/Eth
   |                |                 |                |                |
   | post_send      |                 |                |                |
   |--------------->|                 |                |                |
   |                | write WQE       |                |                |
   |                |---------------->|                |                |
   |                | ring doorbell   |                |                |
   |                |---------------->|                |                |
   |                |                 | decode WQE     |                |
   |                |                 |--------------->|                |
   |                |                 |                | read host mem  |
   |                |                 |                |--------------->|
   |                |                 |                | payload ready  |
   |                |                 |<---------------|                |
   |                |                 | build metadata |                |
   |                |                 |------------------------------->|
   |                |                 |                |                | send packet
```

## 这一阶段先记住什么

RDMA Write 的核心路径可以浓缩成一句话：

```text
应用写 WQE，敲 Doorbell；网卡 QP 取任务，DMA 读本地内存，RoCEv2 封包后从 Ethernet 发出去。
```

几个关键词：

- **WQE**：应用交给网卡的任务单。
- **Doorbell**：通知网卡有新任务。
- **QP**：RDMA 通信上下文和状态机。
- **MR**：允许网卡访问的内存区域。
- **DMA**：网卡直接读写主机内存。
- **RoCEv2**：把 RDMA 语义封装到 Ethernet/IP/UDP 上。
- **CQE**：任务完成后写回给应用的完成记录。
