// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC provider open/query example.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <smartnic_provider.h>

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_provider_context *ctx = NULL;
	struct smartnic_provider_device_attr attr;

	if (smartnic_provider_open_path(path, &ctx) != 0) {
		fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
		return 1;
	}

	if (smartnic_provider_query_device(ctx, &attr) != 0) {
		fprintf(stderr, "query_device failed: %s\n", strerror(errno));
		smartnic_provider_close(ctx);
		return 1;
	}

	printf("abi=%u driver=0x%08x max_qp=%u max_cq=%u max_mr=%u transports=0x%x\n",
	       attr.abi_version, attr.driver_version, attr.max_qp,
	       attr.max_cq, attr.max_mr, attr.supported_transport);

	smartnic_provider_close(ctx);
	return 0;
}
