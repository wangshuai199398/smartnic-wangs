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
#define SMARTNIC_CMD_CREATE_CQ    0x0201
#define SMARTNIC_CMD_DESTROY_CQ   0x0202
#define SMARTNIC_CMD_RESIZE_CQ    0x0203
#define SMARTNIC_CMD_POLL_CQ      0x0204
#define SMARTNIC_CMD_ARM_CQ       0x0205
#define SMARTNIC_CMD_CREATE_QP    0x0301
#define SMARTNIC_CMD_MODIFY_QP    0x0302
#define SMARTNIC_CMD_QUERY_QP     0x0303
#define SMARTNIC_CMD_DESTROY_QP   0x0304
#define SMARTNIC_CMD_REG_MR       0x0401
#define SMARTNIC_CMD_DEREG_MR     0x0402

#define SMARTNIC_PROVIDER_OBJECT_MAGIC_PD 0x534e5044U
#define SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ 0x534e4345U
#define SMARTNIC_PROVIDER_OBJECT_MAGIC_QP 0x534e5150U
#define SMARTNIC_PROVIDER_OBJECT_MAGIC_MR 0x534e4d52U

#define SMARTNIC_PROVIDER_WC_FLAG_IMM 0x00000001U

#define SMARTNIC_PROVIDER_CQ_NOTIFY_NEXT      0
#define SMARTNIC_PROVIDER_CQ_NOTIFY_SOLICITED 1

#define SMARTNIC_PROVIDER_CQE_VALID_BIT 0x80000000U
#define SMARTNIC_PROVIDER_CQE_STATUS_MASK 0x000000ffU
#define SMARTNIC_PROVIDER_CQE_OPCODE_SHIFT 8U
#define SMARTNIC_PROVIDER_CQE_OPCODE_MASK 0x0000ff00U
#define SMARTNIC_PROVIDER_CQE_FLAGS_SHIFT 16U
#define SMARTNIC_PROVIDER_CQE_FLAGS_MASK 0x00ff0000U

#define SMARTNIC_PROVIDER_QP_ATTR_STATE        0x00000001U
#define SMARTNIC_PROVIDER_QP_ATTR_PORT         0x00000002U
#define SMARTNIC_PROVIDER_QP_ATTR_PKEY_INDEX   0x00000004U
#define SMARTNIC_PROVIDER_QP_ATTR_QKEY         0x00000008U
#define SMARTNIC_PROVIDER_QP_ATTR_PATH_MTU     0x00000010U
#define SMARTNIC_PROVIDER_QP_ATTR_DEST_QPN     0x00000020U
#define SMARTNIC_PROVIDER_QP_ATTR_RQ_PSN       0x00000040U
#define SMARTNIC_PROVIDER_QP_ATTR_SQ_PSN       0x00000080U
#define SMARTNIC_PROVIDER_QP_ATTR_ACCESS_FLAGS 0x00000100U
#define SMARTNIC_PROVIDER_QP_ATTR_RETRY        0x00000200U
#define SMARTNIC_PROVIDER_QP_ATTR_TIMEOUT      0x00000400U

#define SMARTNIC_PROVIDER_QP_REQUIRED_INIT \
	(SMARTNIC_PROVIDER_QP_ATTR_STATE | SMARTNIC_PROVIDER_QP_ATTR_PORT | \
	 SMARTNIC_PROVIDER_QP_ATTR_PKEY_INDEX)
#define SMARTNIC_PROVIDER_QP_REQUIRED_RTR \
	(SMARTNIC_PROVIDER_QP_ATTR_STATE | SMARTNIC_PROVIDER_QP_ATTR_PATH_MTU | \
	 SMARTNIC_PROVIDER_QP_ATTR_DEST_QPN | SMARTNIC_PROVIDER_QP_ATTR_RQ_PSN)
#define SMARTNIC_PROVIDER_QP_REQUIRED_RTS \
	(SMARTNIC_PROVIDER_QP_ATTR_STATE | SMARTNIC_PROVIDER_QP_ATTR_SQ_PSN | \
	 SMARTNIC_PROVIDER_QP_ATTR_RETRY | SMARTNIC_PROVIDER_QP_ATTR_TIMEOUT)

#define SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE    0x00000001U
#define SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE   0x00000002U
#define SMARTNIC_PROVIDER_ACCESS_REMOTE_READ    0x00000004U
#define SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC  0x00000008U
#define SMARTNIC_PROVIDER_ACCESS_RELAXED_ORDER  0x00000010U
#define SMARTNIC_PROVIDER_ACCESS_SUPPORTED_MASK \
	(SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE | \
	 SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE | \
	 SMARTNIC_PROVIDER_ACCESS_REMOTE_READ | \
	 SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC | \
	 SMARTNIC_PROVIDER_ACCESS_RELAXED_ORDER)

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

enum smartnic_provider_wc_status {
	SMARTNIC_PROVIDER_WC_SUCCESS = 0,
	SMARTNIC_PROVIDER_WC_LOC_LEN_ERR = 1,
	SMARTNIC_PROVIDER_WC_LOC_PROT_ERR = 2,
	SMARTNIC_PROVIDER_WC_WR_FLUSH_ERR = 5,
	SMARTNIC_PROVIDER_WC_GENERAL_ERR = 255,
};

enum smartnic_provider_wc_opcode {
	SMARTNIC_PROVIDER_WC_SEND = 0,
	SMARTNIC_PROVIDER_WC_RECV = 1,
	SMARTNIC_PROVIDER_WC_RDMA_WRITE = 2,
	SMARTNIC_PROVIDER_WC_RDMA_READ = 3,
	SMARTNIC_PROVIDER_WC_RECV_RDMA_WITH_IMM = 4,
};

enum smartnic_provider_qp_type {
	SMARTNIC_PROVIDER_QPT_RC = 1,
	SMARTNIC_PROVIDER_QPT_UD = 3,
};

enum smartnic_provider_qp_state {
	SMARTNIC_PROVIDER_QPS_RESET = 0,
	SMARTNIC_PROVIDER_QPS_INIT = 1,
	SMARTNIC_PROVIDER_QPS_RTR = 2,
	SMARTNIC_PROVIDER_QPS_RTS = 3,
	SMARTNIC_PROVIDER_QPS_SQD = 4,
	SMARTNIC_PROVIDER_QPS_SQE = 5,
	SMARTNIC_PROVIDER_QPS_ERR = 6,
};

struct smartnic_provider_wc {
	uint64_t wr_id;
	uint32_t status;
	uint32_t opcode;
	uint32_t byte_len;
	uint32_t qp_num;
	uint32_t vendor_err;
	uint32_t imm_data;
	uint32_t wc_flags;
};

struct smartnic_provider_qp_init_attr {
	struct smartnic_provider_cq *send_cq;
	struct smartnic_provider_cq *recv_cq;
	uint32_t qp_type;
	uint32_t max_send_wr;
	uint32_t max_recv_wr;
	uint32_t max_send_sge;
	uint32_t max_recv_sge;
	uint32_t sq_sig_all;
};

struct smartnic_provider_qp_attr {
	uint32_t qp_state;
	uint32_t qp_type;
	uint32_t qpn;
	uint8_t port_num;
	uint16_t pkey_index;
	uint32_t qkey;
	uint32_t path_mtu;
	uint32_t dest_qpn;
	uint32_t rq_psn;
	uint32_t sq_psn;
	uint32_t access_flags;
	uint8_t retry_count;
	uint8_t rnr_retry;
	uint8_t timeout;
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
	struct smartnic_provider_cq *cq_list;
	struct smartnic_provider_qp *qp_list;
	struct smartnic_provider_mr *mr_list;
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

struct smartnic_provider_cq {
	uint32_t magic;
	struct smartnic_provider_context *ctx;
	pthread_mutex_t lock;
	uint32_t cqn;
	uint32_t kernel_handle;
	int cqe;
	uint32_t producer_index;
	uint32_t consumer_index;
	void *ring;
	size_t ring_size;
	unsigned int child_count;
	unsigned int refcount;
	int armed;
	int solicited_only;
	struct smartnic_provider_cq *next;
};

struct smartnic_provider_qp {
	uint32_t magic;
	struct smartnic_provider_context *ctx;
	struct smartnic_provider_pd *pd;
	struct smartnic_provider_cq *send_cq;
	struct smartnic_provider_cq *recv_cq;
	pthread_mutex_t lock;
	uint32_t qpn;
	uint32_t kernel_handle;
	uint32_t qp_type;
	uint32_t qp_state;
	uint32_t max_send_wr;
	uint32_t max_recv_wr;
	uint32_t max_send_sge;
	uint32_t max_recv_sge;
	uint32_t sq_producer_index;
	uint32_t sq_consumer_index;
	uint32_t rq_producer_index;
	uint32_t rq_consumer_index;
	unsigned int active_ops;
	unsigned int refcount;
	struct smartnic_provider_qp_attr attr;
	struct smartnic_provider_qp_init_attr init_attr;
	struct smartnic_provider_qp *next;
};

struct smartnic_provider_mr {
	uint32_t magic;
	struct smartnic_provider_context *ctx;
	struct smartnic_provider_pd *pd;
	void *addr;
	uint64_t length;
	uint32_t access_flags;
	uint32_t kernel_handle;
	uint32_t lkey;
	uint32_t rkey;
	uint32_t page_size;
	uint8_t page_shift;
	unsigned int active_ops;
	unsigned int refcount;
	struct smartnic_provider_mr *next;
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

int smartnic_provider_create_cq(struct smartnic_provider_context *ctx, int cqe,
				struct smartnic_provider_cq **cq);
int smartnic_provider_destroy_cq(struct smartnic_provider_cq *cq);
int smartnic_provider_resize_cq(struct smartnic_provider_cq *cq, int cqe);
int smartnic_provider_poll_cq(struct smartnic_provider_cq *cq, int num_entries,
			      struct smartnic_provider_wc *wc);
int smartnic_provider_req_notify_cq(struct smartnic_provider_cq *cq,
				    int solicited_only);

int smartnic_provider_create_qp(struct smartnic_provider_pd *pd,
				const struct smartnic_provider_qp_init_attr *init_attr,
				struct smartnic_provider_qp **qp);
int smartnic_provider_modify_qp(struct smartnic_provider_qp *qp,
				const struct smartnic_provider_qp_attr *attr,
				uint32_t attr_mask);
int smartnic_provider_query_qp(struct smartnic_provider_qp *qp,
			       struct smartnic_provider_qp_attr *attr,
			       struct smartnic_provider_qp_init_attr *init_attr);
int smartnic_provider_destroy_qp(struct smartnic_provider_qp *qp);

int smartnic_provider_reg_mr(struct smartnic_provider_pd *pd, void *addr,
			     uint64_t length, uint32_t access_flags,
			     struct smartnic_provider_mr **mr);
int smartnic_provider_dereg_mr(struct smartnic_provider_mr *mr);

const char *smartnic_provider_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* SMARTNIC_PROVIDER_H */
