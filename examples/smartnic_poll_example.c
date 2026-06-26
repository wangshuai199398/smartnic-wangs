// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC poll and queue mmap example.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/smartnic_ioctl.h>

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_ioctl_queue queue = {0};
	struct pollfd pfd = {0};
	void *ring;
	int fd;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
		return 1;
	}

	queue.struct_size = sizeof(queue);
	queue.type = SMARTNIC_QUEUE_TYPE_CQ;
	queue.depth = 64;
	queue.desc_size = 64;
	if (ioctl(fd, SMARTNIC_IOCTL_QUEUE_CREATE, &queue) != 0) {
		fprintf(stderr, "queue create failed: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	ring = mmap(NULL, queue.ring_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		    fd, (off_t)queue.mmap_offset);
	if (ring == MAP_FAILED) {
		fprintf(stderr, "queue mmap failed: %s\n", strerror(errno));
	} else {
		printf("mapped queue_id=%u at %p size=%llu\n",
		       queue.queue_id, ring,
		       (unsigned long long)queue.ring_size);
		munmap(ring, queue.ring_size);
	}

	pfd.fd = fd;
	pfd.events = POLLIN | POLLOUT;
	if (poll(&pfd, 1, 1000) < 0)
		fprintf(stderr, "poll failed: %s\n", strerror(errno));
	else
		printf("poll revents=0x%x\n", pfd.revents);

	close(fd);
	return 0;
}
