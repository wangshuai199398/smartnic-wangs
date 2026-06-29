// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC provider async event queue example.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <smartnic_provider.h>

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/smartnic0";
	struct smartnic_provider_context *ctx = NULL;
	struct smartnic_provider_async_event event;

	if (smartnic_provider_open_path(path, &ctx) != 0) {
		fprintf(stderr, "open %s failed: %s\n", path, strerror(errno));
		return 1;
	}

	memset(&event, 0, sizeof(event));
	if (smartnic_provider_get_async_event(ctx, &event) != 0) {
		if (errno == EAGAIN) {
			printf("no async event pending\n");
			smartnic_provider_close(ctx);
			return 0;
		}
		fprintf(stderr, "get_async_event failed: %s\n", strerror(errno));
		smartnic_provider_close(ctx);
		return 1;
	}

	printf("event_type=%u element_type=%u vendor_err=%u\n",
	       event.event_type, event.element_type, event.vendor_err);
	if (smartnic_provider_ack_async_event(&event) != 0) {
		fprintf(stderr, "ack_async_event failed: %s\n", strerror(errno));
		smartnic_provider_close(ctx);
		return 1;
	}

	smartnic_provider_close(ctx);
	return 0;
}
