/* SPDX-License-Identifier: MIT */
/*
 * Minimal userspace provider-facing API for SmartNIC device discovery and
 * context lifetime. Later 13.x tasks layer PD/CQ/QP/MR verbs APIs on top.
 */

#ifndef SMARTNIC_PROVIDER_H
#define SMARTNIC_PROVIDER_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SMARTNIC_PROVIDER_ABI_VERSION 1U
#define SMARTNIC_PROVIDER_MAX_DEVICES 32U
#define SMARTNIC_PROVIDER_MAX_PATH    256U
#define SMARTNIC_PROVIDER_MAX_NAME     64U

#define SMARTNIC_PROVIDER_ENV_DEV_DIR "SMARTNIC_PROVIDER_DEV_DIR"

#define SMARTNIC_CMD_QUERY_DEVICE 0x0001

struct smartnic_provider_device {
	char name[SMARTNIC_PROVIDER_MAX_NAME];
	char node_path[SMARTNIC_PROVIDER_MAX_PATH];
	uint32_t abi_version;
	uint32_t driver_version;
	uint32_t features;
	uint32_t caps;
	uint32_t status;
	int compatible;
};

struct smartnic_provider_context {
	int fd;
	char node_path[SMARTNIC_PROVIDER_MAX_PATH];
	uint32_t abi_version;
	uint32_t driver_version;
	uint32_t features;
	uint32_t caps;
	uint32_t status;
	pthread_mutex_t lock;
	unsigned int pd_count;
	unsigned int cq_count;
	unsigned int qp_count;
	unsigned int mr_count;
	unsigned int ah_count;
	int closed;
};

int smartnic_provider_discover(struct smartnic_provider_device **devices,
			       size_t *count);
void smartnic_provider_free_devices(struct smartnic_provider_device *devices);

int smartnic_provider_open(const struct smartnic_provider_device *device,
			   struct smartnic_provider_context **ctx);
int smartnic_provider_open_path(const char *node_path,
				struct smartnic_provider_context **ctx);
int smartnic_provider_close(struct smartnic_provider_context *ctx);

const char *smartnic_provider_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* SMARTNIC_PROVIDER_H */
