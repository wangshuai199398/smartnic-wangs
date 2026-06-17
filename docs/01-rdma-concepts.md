# RDMA SmartNIC 核心概念

本文用简单语言解释本项目里最重要的 RDMA 概念：

- QP
- CQ
- MR
- PD
- Doorbell
- WQE
- CQE
- DMA
- RoCEv2

这些概念会贯穿后续 RTL、Linux 驱动、用户态库和仿真验证。

## 一句话总览

在本项目里，一次简化的 RDMA Write 可以理解为：

```text
应用创建一个任务 WQE
  -> 把任务放进 QP 的发送队列
  -> 通过 Doorbell 通知网卡
  -> 网卡用 DMA 读取本地 MR 中的数据
  -> 封装成 RoCEv2 报文
  -> 通过 Ethernet 发到远端
  -> 完成后写 CQE 到 CQ
```

这些名词的关系可以画成：

```text
+-------------+       +----------------+       +----------------+
| user app    | ----> | WQE in QP SQ   | ----> | Doorbell       |
+-------------+       +----------------+       +----------------+
                                                   |
                                                   v
                                            +-------------+
                                            | SmartNIC QP |
                                            +-------------+
                                                   |
                         +-------------------------+------------------+
                         |                                            |
                         v                                            v
                    +---------+                                +--------------+
                    |   MR    | -- checked by PD/key/perm --> |     DMA      |
                    +---------+                                +--------------+
                                                                    |
                                                                    v
                                                             +--------------+
                                                             |   RoCEv2     |
                                                             +--------------+
                                                                    |
                                                                    v
                                                               Ethernet

完成事件：

SmartNIC -> CQE -> CQ -> user app polls completion
```

## QP：Queue Pair，队列对

QP 是 RDMA 通信的核心对象。

可以把 QP 理解成：

```text
一条 RDMA 通信通道的状态和任务队列。
```

它通常包含两条队列：

- SQ：Send Queue，发送队列
- RQ：Receive Queue，接收队列

在本项目中，用户程序发起 RDMA Write 时，会把一个 WQE 放进 QP 的 SQ。

网卡看到 Doorbell 后，会找到对应的 QP，然后从这个 QP 的 SQ 中取出 WQE。

QP 还会保存很多状态，例如：

- QPN：QP 编号
- QP 类型：RC 或 UD
- QP 状态：RESET、INIT、RTR、RTS、ERR 等
- 关联的 CQ
- 关联的 PD
- PSN：包序列号
- retry 相关状态

在简化数据通路中：

```text
Doorbell -> QP -> 读取 WQE -> 发起 DMA 和 RoCEv2 封包
```

## CQ：Completion Queue，完成队列

CQ 用来告诉应用：

```text
你之前提交的任务完成了，结果是成功还是失败。
```

应用提交 WQE 后，不会一直阻塞等待网卡。网卡完成任务后，会往 CQ 里写一个 CQE。

应用之后调用类似 `poll_cq` 的接口，从 CQ 中读取完成结果。

在本项目中，CQ 主要用于：

- 报告 Send 完成
- 报告 RDMA Write 完成
- 报告 RDMA Read 完成
- 报告 Recv 完成
- 报告错误，例如 MR 权限错误、DMA 错误、QP 错误

简化路径：

```text
SmartNIC 完成任务
  -> 生成 CQE
  -> 写入 CQ
  -> user app poll CQ
```

## MR：Memory Region，内存区域

MR 是允许网卡访问的一段主机内存。

RDMA 的关键点是：

```text
网卡可以直接访问主机内存，但不能随便访问所有内存。
```

所以应用必须先注册内存。注册后，这段内存会变成 MR。

MR 通常包含：

- 起始地址
- 长度
- 访问权限
- lkey
- rkey
- 所属 PD

### lkey 和 rkey

可以简单理解为：

- `lkey`：本地网卡访问本地 MR 时使用
- `rkey`：远端网卡访问这个 MR 时使用

在 RDMA Write 中：

- 本地网卡用本地 `lkey` 检查能不能读取本地 buffer
- 远端网卡用远端 `rkey` 检查能不能写入远端 buffer

在本项目的数据通路中：

```text
WQE 里的本地 SGE + lkey
  -> MR 检查
  -> DMA 读取本地内存
```

如果 MR 检查失败，DMA 不应该读写内存，而应该产生错误完成。

## PD：Protection Domain，保护域

PD 是资源隔离的边界。

可以把 PD 理解成：

```text
一组 QP、MR、AH 的安全分组。
```

同一个 PD 里的 QP 才应该访问这个 PD 里的 MR。

这样做的意义是防止资源误用。例如：

```text
QP-A 属于 PD-1
MR-B 属于 PD-2

QP-A 不应该直接访问 MR-B
```

在本项目里，PD 会参与 MR 权限检查：

```text
QP 发起 DMA
  -> 检查 QP 的 PD
  -> 检查 MR 的 PD
  -> 不匹配则拒绝访问
```

PD 本身不是数据搬运模块，而是访问控制规则的一部分。

## Doorbell：门铃

Doorbell 是用户态通知网卡的快速入口。

可以把 Doorbell 理解成：

```text
应用对网卡说：“我刚刚放了新任务，你去看一下。”
```

用户程序不会把完整数据写进 Doorbell。完整任务在 WQE 里，Doorbell 只是通知硬件：

- 哪个 QP 有新 WQE
- producer index 更新到了哪里
- 是 SQ Doorbell、RQ Doorbell，还是 CQ arm Doorbell

在本项目中：

```text
libsmartnic 写 WQE
  -> 写 Doorbell
  -> SmartNIC 捕获 Doorbell
  -> QP 开始处理新 WQE
```

Doorbell 通常通过 mmap 暴露给用户态，这样可以减少系统调用开销。

## WQE：Work Queue Entry，工作队列项

WQE 是应用交给网卡的任务单。

可以把 WQE 理解成：

```text
一张写给网卡的工作说明。
```

对于 RDMA Write，一个 WQE 大概会写：

- 操作类型：RDMA Write
- 本地内存地址
- 本地 lkey
- 数据长度
- 远端内存地址
- 远端 rkey
- wr_id
- 是否需要 completion

WQE 被放在 QP 的 SQ 或 RQ 中：

- 发送类任务放在 SQ
- 接收类任务放在 RQ

在本项目的数据通路中：

```text
user app
  -> libsmartnic 构造 WQE
  -> WQE 写入 QP SQ
  -> Doorbell 通知网卡
  -> QP 读取 WQE
```

WQE 是软件和硬件之间非常重要的接口。

## CQE：Completion Queue Entry，完成队列项

CQE 是网卡写给应用的完成记录。

可以把 CQE 理解成：

```text
网卡处理完任务后写回来的结果单。
```

一个 CQE 通常包含：

- wr_id
- 操作类型
- 状态：成功或错误
- 完成字节数
- QP 编号
- immediate data
- 错误信息

应用通过 CQ 读取 CQE。

在本项目中：

```text
SmartNIC 完成 RDMA Write
  -> 生成 CQE
  -> 写入 CQ
  -> libsmartnic poll CQ
  -> user app 得到完成事件
```

CQE 让应用知道之前提交的 WQE 是否完成。

## DMA：Direct Memory Access，直接内存访问

DMA 是网卡直接读写主机内存的机制。

没有 DMA 的话，CPU 需要参与搬运数据。RDMA 的性能优势来自：

```text
数据由网卡直接搬运，CPU 不参与每个数据包。
```

在 RDMA Write 中，本地网卡需要读取本地 buffer。

路径是：

```text
WQE 中的本地地址和 lkey
  -> MR 检查
  -> 地址转换
  -> PCIe Memory Read
  -> 得到 payload
```

然后网卡把 payload 封装成 RoCEv2 报文发出去。

DMA 必须受 MR 和 PD 保护，不能绕过权限检查。

## RoCEv2

RoCEv2 的全称是 RDMA over Converged Ethernet v2。

可以简单理解为：

```text
把 RDMA 操作封装到 Ethernet/IP/UDP 网络上。
```

一个简化的 RoCEv2 报文长这样：

```text
Ethernet
  IPv4
    UDP
      BTH
      RETH/AETH/DETH/ImmDt
      payload
      ICRC
```

对于 RDMA Write，常见字段包括：

- Ethernet header：以太网头
- IPv4 header：IP 头
- UDP header：UDP 头
- BTH：基础传输头，包含 opcode、目标 QPN、PSN
- RETH：RDMA 扩展传输头，包含远端地址、rkey、长度
- payload：真正要写到远端的数据
- ICRC：RDMA 校验字段

在本项目中：

```text
DMA 读出本地 payload
  -> RoCEv2 packet builder 加上协议头
  -> Ethernet MAC 发出去
```

## 这些概念如何串起来

以 RDMA Write 为例：

```text
1. 应用注册内存，得到 MR 和 lkey。
2. 应用创建 PD、CQ、QP，并把 QP 配置到可发送状态。
3. 应用准备一个 RDMA Write WQE。
4. libsmartnic 把 WQE 写入 QP 的 SQ。
5. libsmartnic 写 Doorbell。
6. SmartNIC 的 QP 逻辑读取 WQE。
7. DMA 根据 WQE 里的本地地址和 lkey 检查 MR。
8. DMA 从本地主机内存读出 payload。
9. RoCEv2 模块把 payload 封装成 RDMA Write 报文。
10. Ethernet MAC 把报文发到网络。
11. 操作完成后，SmartNIC 写 CQE 到 CQ。
12. 应用 poll CQ，看到任务完成。
```

## 最小记忆版

如果刚开始学习，只需要先记住：

- **QP**：任务队列和 RDMA 通信状态。
- **CQ**：完成结果队列。
- **MR**：网卡被允许访问的内存。
- **PD**：资源隔离边界。
- **Doorbell**：通知网卡有新任务。
- **WQE**：应用给网卡的任务单。
- **CQE**：网卡给应用的结果单。
- **DMA**：网卡直接读写主机内存。
- **RoCEv2**：把 RDMA 操作封装到 Ethernet 网络上。
