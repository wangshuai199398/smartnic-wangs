/* SPDX-License-Identifier: MIT */
/*
 * Small userspace helper library for the prototype SmartNIC control device.
 */

#ifndef LIBSMARTNIC_H
#define LIBSMARTNIC_H

#include <stddef.h>
#include <stdint.h>

#include <linux/smartnic_ioctl.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SMARTNIC_DEFAULT_DEVICE "/dev/smartnic0"

#define SMARTNIC_CMD_NOP          0x0000
#define SMARTNIC_CMD_QUERY_DEVICE 0x0001
#define SMARTNIC_CMD_RESET_DEVICE 0x0002

struct smartnic_device {
	int fd;
	char path[256];
};

struct smartnic_device_info {
	uint32_t version;
	uint32_t features;
	uint32_t caps;
	uint32_t status;
};

int smartnic_open(struct smartnic_device *dev, const char *path);
void smartnic_close(struct smartnic_device *dev);

int smartnic_mailbox(struct smartnic_device *dev, uint16_t opcode,
		     const uint32_t *in_words, size_t in_words_count,
		     uint32_t *out_words, size_t out_words_count);

int smartnic_query_device(struct smartnic_device *dev,
			  struct smartnic_device_info *info);
int smartnic_reset_device(struct smartnic_device *dev);

const char *smartnic_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* LIBSMARTNIC_H */
