// SPDX-License-Identifier: MIT
/*
 * SmartNIC userspace flow example: ioctl + queue mmap + poll.
 *
 * This is Linux-only and uses the project UAPI header. It is a compact
 * example rather than a verbs application; full RDMA semantics are added in
 * later OpenSpec stages.
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

static void explain_errno(const char *op)
{
	switch (errno) {
	case ENOTTY:
		fprintf(stderr, "%s: unsupported ioctl or wrong UAPI header\n", op);
		break;
	case EINVAL:
		fprintf(stderr, "%s: invalid structure size, queue parameter, or mmap size\n", op);
		break;
	case ETIMEDOUT:
		fprintf(stderr, "%s: CSR mailbox timed out\n", op);
		break;
	case ENODEV:
		fprintf(stderr, "%s: device removed or not ready\n", op);
		break;
	case EPERM:
	case EACCES:
		fprintf(stderr, "%s: access denied or mmap ownership mismatch\n", op);
		break;
	default:
		fprintf(stderr, "%s: %s\n", op, strerror(errno));
		break;
	}
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_ioctl_mbox mbox = {0};
	struct smartnic_ioctl_queue queue = {0};
	struct smartnic_ioctl_queue_destroy destroy = {0};
	struct pollfd pfd = {0};
	void *ring = MAP_FAILED;
	int fd;
	int rc = 1;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		explain_errno("open");
		return 1;
	}

	mbox.struct_size = sizeof(mbox);
	mbox.opcode = 0x0001; /* QUERY_DEVICE in tools/libsmartnic.h */
	mbox.out_len = sizeof(mbox.data);
	if (ioctl(fd, SMARTNIC_IOCTL_MBOX_EXEC, &mbox) < 0)
		explain_errno("SMARTNIC_IOCTL_MBOX_EXEC");
	else
		printf("version=0x%08x features=0x%08x caps=0x%08x status=0x%08x\n",
		       mbox.data[0], mbox.data[1], mbox.data[2], mbox.data[3]);

	queue.struct_size = sizeof(queue);
	queue.type = SMARTNIC_QUEUE_TYPE_CQ;
	queue.depth = 64;
	queue.desc_size = 64;
	if (ioctl(fd, SMARTNIC_IOCTL_QUEUE_CREATE, &queue) < 0) {
		explain_errno("SMARTNIC_IOCTL_QUEUE_CREATE");
		goto out_close;
	}

	ring = mmap(NULL, queue.ring_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		    fd, (off_t)queue.mmap_offset);
	if (ring == MAP_FAILED) {
		explain_errno("mmap queue ring");
		goto out_destroy;
	}

	pfd.fd = fd;
	pfd.events = POLLIN | POLLOUT;
	if (poll(&pfd, 1, 1000) < 0) {
		explain_errno("poll");
		goto out_unmap;
	}

	if (pfd.revents & (POLLERR | POLLHUP))
		fprintf(stderr, "device is quiescing or removed\n");
	if (pfd.revents & (POLLIN | POLLRDNORM))
		printf("event or completion notification pending\n");
	if (pfd.revents & (POLLOUT | POLLWRNORM))
		printf("device accepts commands\n");

	rc = 0;

out_unmap:
	if (ring != MAP_FAILED)
		munmap(ring, queue.ring_size);
out_destroy:
	destroy.struct_size = sizeof(destroy);
	destroy.queue_id = queue.queue_id;
	if (ioctl(fd, SMARTNIC_IOCTL_QUEUE_DESTROY, &destroy) < 0)
		explain_errno("SMARTNIC_IOCTL_QUEUE_DESTROY");
out_close:
	close(fd);
	return rc;
}
