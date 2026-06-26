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
#define SMARTNIC_PROVIDER_MAX_PORTS     1U
#define SMARTNIC_PROVIDER_GID_LEN      16U
#define SMARTNIC_PROVIDER_GID_TABLE_LEN 1U
#define SMARTNIC_PROVIDER_PKEY_TABLE_LEN 1U

#define SMARTNIC_PROVIDER_LINK_LAYER_ETHERNET 1U
#define SMARTNIC_PROVIDER_PORT_STATE_ACTIVE   4U
#define SMARTNIC_PROVIDER_MTU_4096            4096U

#define SMARTNIC_PROVIDER_TRANSPORT_RC        0x00000001U
#define SMARTNIC_PROVIDER_TRANSPORT_UD        0x00000002U
#define SMARTNIC_PROVIDER_ATOMIC_NONE         0U

#define SMARTNIC_PROVIDER_ENV_DEV_DIR "SMARTNIC_PROVIDER_DEV_DIR"

#define SMARTNIC_CMD_QUERY_DEVICE 0x0001
#define SMARTNIC_CMD_ALLOC_PD     0x0101
#define SMARTNIC_CMD_DEALLOC_PD   0x0102

#define SMARTNIC_PROVIDER_OBJECT_MAGIC_PD 0x534e5044U

struct smartnic_provider_device_attr {
	uint32_t abi_version;
	uint32_t driver_version;
	uint32_t vendor_id;
	uint32_t device_id;
	uint32_t features;
	uint32_t caps;
	uint32_t status;
	uint32_t max_qp;
	uint32_t max_cq;
	uint32_t max_mr;
	uint32_t max_pd;
	uint32_t max_sge;
	uint32_t max_wr;
	uint32_t supported_transport;
	uint32_t link_layer;
	uint32_t atomic_cap;
	uint64_t page_size_cap;
};

struct smartnic_provider_port_attr {
	uint8_t port_num;
	uint8_t state;
	uint32_t max_mtu;
	uint32_t active_mtu;
	uint32_t lid;
	uint32_t link_layer;
	uint32_t active_speed;
	uint32_t active_width;
	uint32_t gid_tbl_len;
	uint32_t pkey_tbl_len;
};

struct smartnic_provider_gid {
	uint8_t raw[SMARTNIC_PROVIDER_GID_LEN];
};

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
	struct smartnic_provider_pd *pd_list;
	int closed;
};

struct smartnic_provider_pd {
	uint32_t magic;
	struct smartnic_provider_context *ctx;
	uint32_t pdn;
	uint32_t kernel_handle;
	unsigned int child_count;
	unsigned int refcount;
	struct smartnic_provider_pd *next;
};

int smartnic_provider_discover(struct smartnic_provider_device **devices,
			       size_t *count);
void smartnic_provider_free_devices(struct smartnic_provider_device *devices);

int smartnic_provider_open(const struct smartnic_provider_device *device,
			   struct smartnic_provider_context **ctx);
int smartnic_provider_open_path(const char *node_path,
				struct smartnic_provider_context **ctx);
int smartnic_provider_close(struct smartnic_provider_context *ctx);

int smartnic_provider_query_device(struct smartnic_provider_context *ctx,
				   struct smartnic_provider_device_attr *attr);
int smartnic_provider_query_port(struct smartnic_provider_context *ctx,
				 uint8_t port_num,
				 struct smartnic_provider_port_attr *attr);
int smartnic_provider_query_gid(struct smartnic_provider_context *ctx,
				uint8_t port_num, uint32_t index,
				struct smartnic_provider_gid *gid);
int smartnic_provider_query_pkey(struct smartnic_provider_context *ctx,
				 uint8_t port_num, uint32_t index,
				 uint16_t *pkey);

int smartnic_provider_alloc_pd(struct smartnic_provider_context *ctx,
			       struct smartnic_provider_pd **pd);
int smartnic_provider_dealloc_pd(struct smartnic_provider_pd *pd);

const char *smartnic_provider_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* SMARTNIC_PROVIDER_H */
