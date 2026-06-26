// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC ioctl example.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/smartnic_ioctl.h>

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_ioctl_mbox mbox = {0};
	struct smartnic_ioctl_queue queue = {0};
	struct smartnic_ioctl_queue_destroy destroy = {0};
	int fd;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
		return 1;
	}

	mbox.struct_size = sizeof(mbox);
	mbox.opcode = 0x0001; /* QUERY_DEVICE in tools/libsmartnic.h */
	mbox.out_len = sizeof(mbox.data);
	if (ioctl(fd, SMARTNIC_IOCTL_MBOX_EXEC, &mbox) == 0) {
		printf("version=0x%08x features=0x%08x caps=0x%08x status=0x%08x\n",
		       mbox.data[0], mbox.data[1], mbox.data[2], mbox.data[3]);
	} else {
		printf("query mailbox failed: %s\n", strerror(errno));
	}

	queue.struct_size = sizeof(queue);
	queue.type = SMARTNIC_QUEUE_TYPE_CQ;
	queue.depth = 64;
	queue.desc_size = 64;
	if (ioctl(fd, SMARTNIC_IOCTL_QUEUE_CREATE, &queue) == 0) {
		printf("created queue_id=%u mmap_offset=0x%llx ring_size=%llu dma=0x%llx\n",
		       queue.queue_id,
		       (unsigned long long)queue.mmap_offset,
		       (unsigned long long)queue.ring_size,
		       (unsigned long long)queue.dma_addr);

		destroy.struct_size = sizeof(destroy);
		destroy.queue_id = queue.queue_id;
		if (ioctl(fd, SMARTNIC_IOCTL_QUEUE_DESTROY, &destroy) != 0)
			fprintf(stderr, "destroy queue failed: %s\n", strerror(errno));
	} else {
		printf("queue create failed: %s\n", strerror(errno));
	}

	close(fd);
	return 0;
}
