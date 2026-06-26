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

#endif /* _SMARTNIC_REGS_H */
