// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC provider CQ poll example.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <smartnic_provider.h>

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_provider_context *ctx = NULL;
	struct smartnic_provider_cq *cq = NULL;
	struct smartnic_provider_wc wc[4];
	int n;

	if (smartnic_provider_open_path(path, &ctx) != 0) {
		fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
		return 1;
	}

	if (smartnic_provider_create_cq(ctx, 64, &cq) != 0) {
		fprintf(stderr, "create_cq failed: %s\n", strerror(errno));
		smartnic_provider_close(ctx);
		return 1;
	}

	n = smartnic_provider_poll_cq(cq, 4, wc);
	if (n < 0) {
		fprintf(stderr, "poll_cq failed: %s\n", smartnic_provider_strerror(-n));
		smartnic_provider_destroy_cq(cq);
		smartnic_provider_close(ctx);
		return 1;
	}

	printf("polled %d completions\n", n);
	for (int i = 0; i < n; i++) {
		printf("wc[%d]: wr_id=%llu status=%u opcode=%u byte_len=%u qp=%u flags=0x%x\n",
		       i, (unsigned long long)wc[i].wr_id, wc[i].status,
		       wc[i].opcode, wc[i].byte_len, wc[i].qp_num,
		       wc[i].wc_flags);
	}

	smartnic_provider_destroy_cq(cq);
	smartnic_provider_close(ctx);
	return 0;
}
