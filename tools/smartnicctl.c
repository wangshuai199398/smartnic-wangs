// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC control CLI.
 */

#include "libsmartnic.h"

#include <errno.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *out)
{
	fprintf(out,
		"Usage: smartnicctl [--device PATH] COMMAND [ARGS]\n"
		"\n"
		"Commands:\n"
		"  list\n"
		"      List /dev/smartnic* devices.\n"
		"  info\n"
		"      Query device version/features/caps through mailbox.\n"
		"  reset\n"
		"      Request device reset through mailbox if supported.\n"
		"  mbox OPCODE [WORD...]\n"
		"      Issue a raw mailbox command. OPCODE and WORD values accept hex.\n"
		"  read-csr OFFSET\n"
		"      Not supported by the current 12.3 UAPI.\n"
		"  write-csr OFFSET VALUE\n"
		"      Not supported by the current 12.3 UAPI.\n"
		"\n"
		"Options:\n"
		"  -d, --device PATH   Device node, default /dev/smartnic0.\n"
		"  -h, --help          Show this help.\n");
}

static int parse_u32(const char *text, uint32_t *value)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 0);
	if (errno || !end || *end || parsed > UINT32_MAX)
		return -1;

	*value = (uint32_t)parsed;
	return 0;
}

static int cmd_list(void)
{
	glob_t matches;
	size_t i;
	int ret;

	ret = glob("/dev/smartnic*", 0, NULL, &matches);
	if (ret == GLOB_NOMATCH) {
		printf("no SmartNIC devices found\n");
		return 0;
	}
	if (ret) {
		fprintf(stderr, "failed to list devices: glob error %d\n", ret);
		return 1;
	}

	for (i = 0; i < matches.gl_pathc; i++)
		printf("%s\n", matches.gl_pathv[i]);

	globfree(&matches);
	return 0;
}

static int open_device(struct smartnic_device *dev, const char *path)
{
	if (smartnic_open(dev, path) == 0)
		return 0;

	fprintf(stderr, "failed to open %s: %s\n",
		path ? path : SMARTNIC_DEFAULT_DEVICE, strerror(errno));
	return -1;
}

static int cmd_info(const char *path)
{
	struct smartnic_device dev;
	struct smartnic_device_info info;
	int ret = 0;

	if (open_device(&dev, path) < 0)
		return 1;

	if (smartnic_query_device(&dev, &info) < 0) {
		fprintf(stderr, "query device failed: %s\n", strerror(errno));
		ret = 1;
		goto out_close;
	}

	printf("device:   %s\n", dev.path);
	printf("version:  0x%08x\n", info.version);
	printf("features: 0x%08x\n", info.features);
	printf("caps:     0x%08x\n", info.caps);
	printf("status:   0x%08x\n", info.status);

out_close:
	smartnic_close(&dev);
	return ret;
}

static int cmd_reset(const char *path)
{
	struct smartnic_device dev;
	int ret = 0;

	if (open_device(&dev, path) < 0)
		return 1;

	if (smartnic_reset_device(&dev) < 0) {
		fprintf(stderr, "reset failed: %s\n", strerror(errno));
		ret = 1;
		goto out_close;
	}

	printf("reset command accepted for %s\n", dev.path);

out_close:
	smartnic_close(&dev);
	return ret;
}

static int cmd_mbox(const char *path, int argc, char **argv)
{
	struct smartnic_device dev;
	uint32_t opcode_u32;
	uint32_t in_words[SMARTNIC_IOCTL_MAX_DATA_DWORDS] = {0};
	uint32_t out_words[SMARTNIC_IOCTL_MAX_DATA_DWORDS] = {0};
	size_t in_count;
	size_t i;
	int ret = 0;

	if (argc < 1) {
		fprintf(stderr, "mbox requires an opcode\n");
		return 1;
	}

	if (parse_u32(argv[0], &opcode_u32) < 0 || opcode_u32 > UINT16_MAX) {
		fprintf(stderr, "invalid mailbox opcode: %s\n", argv[0]);
		return 1;
	}

	in_count = (size_t)(argc - 1);
	if (in_count > SMARTNIC_IOCTL_MAX_DATA_DWORDS) {
		fprintf(stderr, "too many mailbox input words, max %u\n",
			SMARTNIC_IOCTL_MAX_DATA_DWORDS);
		return 1;
	}

	for (i = 0; i < in_count; i++) {
		if (parse_u32(argv[i + 1], &in_words[i]) < 0) {
			fprintf(stderr, "invalid mailbox word: %s\n", argv[i + 1]);
			return 1;
		}
	}

	if (open_device(&dev, path) < 0)
		return 1;

	if (smartnic_mailbox(&dev, (uint16_t)opcode_u32, in_words, in_count,
			    out_words, SMARTNIC_IOCTL_MAX_DATA_DWORDS) < 0) {
		fprintf(stderr, "mailbox command failed: %s\n", strerror(errno));
		ret = 1;
		goto out_close;
	}

	for (i = 0; i < SMARTNIC_IOCTL_MAX_DATA_DWORDS; i++)
		printf("out[%zu]=0x%08x\n", i, out_words[i]);

out_close:
	smartnic_close(&dev);
	return ret;
}

static int unsupported_csr_command(const char *name)
{
	fprintf(stderr, "%s is not supported by the current SmartNIC UAPI\n",
		name);
	return 2;
}

int main(int argc, char **argv)
{
	const char *device_path = SMARTNIC_DEFAULT_DEVICE;
	const char *cmd;
	int i = 1;

	if (argc <= 1) {
		usage(stderr);
		return 1;
	}

	while (i < argc) {
		if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(stdout);
			return 0;
		}
		if (!strcmp(argv[i], "-d") || !strcmp(argv[i], "--device")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "--device requires a path\n");
				return 1;
			}
			device_path = argv[i + 1];
			i += 2;
			continue;
		}
		break;
	}

	if (i >= argc) {
		usage(stderr);
		return 1;
	}

	cmd = argv[i++];
	if (!strcmp(cmd, "list"))
		return cmd_list();
	if (!strcmp(cmd, "info"))
		return cmd_info(device_path);
	if (!strcmp(cmd, "reset"))
		return cmd_reset(device_path);
	if (!strcmp(cmd, "mbox"))
		return cmd_mbox(device_path, argc - i, &argv[i]);
	if (!strcmp(cmd, "read-csr"))
		return unsupported_csr_command("read-csr");
	if (!strcmp(cmd, "write-csr"))
		return unsupported_csr_command("write-csr");

	fprintf(stderr, "unknown command: %s\n", cmd);
	usage(stderr);
	return 1;
}
