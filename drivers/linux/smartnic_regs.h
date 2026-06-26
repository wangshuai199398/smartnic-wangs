/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Register and PCI identity definitions for the prototype RDMA SmartNIC
 * Linux driver.
 */

#ifndef _SMARTNIC_REGS_H
#define _SMARTNIC_REGS_H

#include <linux/types.h>

#define SMARTNIC_DRV_NAME              "smartnic"

#define SMARTNIC_PCI_VENDOR_ID         0x1d0f
#define SMARTNIC_PCI_DEVICE_ID         0x5a10

/*
 * 12.1 keeps the software side conservative: BAR0 is mapped as the
 * primary control/MMIO aperture requested by the task, and BAR2 is mapped
 * opportunistically as a secondary doorbell/MMIO aperture. Later ioctl/mmap
 * work can tighten this to the hardware ABI's BAR0 Doorbell + BAR2 CSR split.
 */
#define SMARTNIC_BAR_CONTROL           0
#define SMARTNIC_BAR_DOORBELL          2

#define SMARTNIC_CSR_VERSION           0x0000
#define SMARTNIC_CSR_FEATURES          0x0004
#define SMARTNIC_CSR_CAPS              0x0008
#define SMARTNIC_CSR_STATUS            0x000c
#define SMARTNIC_CSR_RESET             0x0010

#define SMARTNIC_RESET_REQUEST         0x00000001u
#define SMARTNIC_RESET_DONE            0x00000002u

#define SMARTNIC_RESET_POLL_US         20
#define SMARTNIC_RESET_TIMEOUT_US      2000

#define SMARTNIC_MBOX_COMMAND          0x0100
#define SMARTNIC_MBOX_OWNER_FUNCTION   0x0104
#define SMARTNIC_MBOX_CONTROL          0x0108
#define SMARTNIC_MBOX_STATUS           0x010c
#define SMARTNIC_MBOX_ERROR            0x0110
#define SMARTNIC_MBOX_TIMEOUT_COUNTER  0x0114
#define SMARTNIC_MBOX_ARG_BASE         0x0120
#define SMARTNIC_MBOX_ARG_STRIDE       0x0004
#define SMARTNIC_MBOX_ARG(_idx)        (SMARTNIC_MBOX_ARG_BASE + \
					 ((_idx) * SMARTNIC_MBOX_ARG_STRIDE))

#define SMARTNIC_MBOX_CTRL_GO          0x00000001u
#define SMARTNIC_MBOX_CTRL_DONE        0x00000002u
#define SMARTNIC_MBOX_CTRL_BUSY        0x00000004u
#define SMARTNIC_MBOX_CTRL_ERROR       0x00000008u
#define SMARTNIC_MBOX_CTRL_CLEAR_STATUS 0x80000000u

#define SMARTNIC_MBOX_MAX_DATA_DWORDS  4
#define SMARTNIC_MBOX_MAX_DATA_BYTES   (SMARTNIC_MBOX_MAX_DATA_DWORDS * \
					 sizeof(u32))
#define SMARTNIC_MBOX_POLL_US          10
#define SMARTNIC_MBOX_TIMEOUT_US       100000

#define SMARTNIC_MBOX_ERR_NONE         0x00000000u
#define SMARTNIC_MBOX_ERR_INVALID_CMD  0x00000001u
#define SMARTNIC_MBOX_ERR_TIMEOUT      0x00000002u
#define SMARTNIC_MBOX_ERR_BUSY         0x00000003u
#define SMARTNIC_MBOX_ERR_INVALID_ARG  0x00000004u
#define SMARTNIC_MBOX_ERR_PERMISSION   0x00000005u
#define SMARTNIC_MBOX_ERR_BAD_STATE    0x00000006u
#define SMARTNIC_MBOX_ERR_NO_RESOURCE  0x00000007u
#define SMARTNIC_MBOX_ERR_HW           0x00000008u

#endif /* _SMARTNIC_REGS_H */
