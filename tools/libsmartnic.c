// SPDX-License-Identifier: MIT
/*
 * Userspace wrappers for the prototype SmartNIC character device ABI.
 */

#include "libsmartnic.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int smartnic_open(struct smartnic_device *dev, const char *path)
{
	const char *device_path = path ? path : SMARTNIC_DEFAULT_DEVICE;
	int fd;

	if (!dev) {
		errno = EINVAL;
		return -1;
	}

	memset(dev, 0, sizeof(*dev));
	dev->fd = -1;

	fd = open(device_path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;

	dev->fd = fd;
	snprintf(dev->path, sizeof(dev->path), "%s", device_path);
	return 0;
}

void smartnic_close(struct smartnic_device *dev)
{
	if (!dev || dev->fd < 0)
		return;

	close(dev->fd);
	dev->fd = -1;
}

int smartnic_mailbox(struct smartnic_device *dev, uint16_t opcode,
		     const uint32_t *in_words, size_t in_words_count,
		     uint32_t *out_words, size_t out_words_count)
{
	struct smartnic_ioctl_mbox req;
	size_t i;

	if (!dev || dev->fd < 0) {
		errno = ENODEV;
		return -1;
	}

	if (in_words_count > SMARTNIC_IOCTL_MAX_DATA_DWORDS ||
	    out_words_count > SMARTNIC_IOCTL_MAX_DATA_DWORDS) {
		errno = EINVAL;
		return -1;
	}

	if (in_words_count && !in_words) {
		errno = EINVAL;
		return -1;
	}

	if (out_words_count && !out_words) {
		errno = EINVAL;
		return -1;
	}

	memset(&req, 0, sizeof(req));
	req.struct_size = sizeof(req);
	req.opcode = opcode;
	req.in_len = in_words_count * sizeof(uint32_t);
	req.out_len = out_words_count * sizeof(uint32_t);

	for (i = 0; i < in_words_count; i++)
		req.data[i] = in_words[i];

	if (ioctl(dev->fd, SMARTNIC_IOCTL_MBOX_EXEC, &req) < 0)
		return -1;

	for (i = 0; i < out_words_count; i++)
		out_words[i] = req.data[i];

	return 0;
}

int smartnic_query_device(struct smartnic_device *dev,
			  struct smartnic_device_info *info)
{
	uint32_t words[4] = {0};

	if (!info) {
		errno = EINVAL;
		return -1;
	}

	if (smartnic_mailbox(dev, SMARTNIC_CMD_QUERY_DEVICE, NULL, 0,
			    words, 4) < 0)
		return -1;

	info->version = words[0];
	info->features = words[1];
	info->caps = words[2];
	info->status = words[3];
	return 0;
}

int smartnic_reset_device(struct smartnic_device *dev)
{
	return smartnic_mailbox(dev, SMARTNIC_CMD_RESET_DEVICE, NULL, 0,
				NULL, 0);
}

const char *smartnic_strerror(int err)
{
	int positive_err = err < 0 ? -err : err;

	return strerror(positive_err);
}
