// SPDX-License-Identifier: MIT
/*
 * SmartNIC userspace provider discovery and context lifetime.
 *
 * This file implements discovery, context, query, PD, and CQ provider
 * primitives. Later 13.x tasks layer QP/MR/AH and fast-path verbs APIs on top.
 */

#include "smartnic_provider.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/smartnic_ioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define SMARTNIC_PROVIDER_DEFAULT_MAX_QP 4096U
#define SMARTNIC_PROVIDER_DEFAULT_MAX_CQ 4096U
#define SMARTNIC_PROVIDER_DEFAULT_MAX_MR 8192U
#define SMARTNIC_PROVIDER_DEFAULT_MAX_PD 1024U
#define SMARTNIC_PROVIDER_DEFAULT_MAX_SGE 256U
#define SMARTNIC_PROVIDER_DEFAULT_MAX_WR 4096U
#define SMARTNIC_PROVIDER_DEFAULT_SPEED_GBPS 100U
#define SMARTNIC_PROVIDER_DEFAULT_WIDTH 1U
#define SMARTNIC_PROVIDER_VENDOR_ID 0x1d0fU
#define SMARTNIC_PROVIDER_DEVICE_ID 0x5a10U
#define SMARTNIC_PROVIDER_FULL_MEMBERSHIP_PKEY 0xffffU

static const char *smartnic_provider_dev_dir(void)
{
	const char *override = getenv(SMARTNIC_PROVIDER_ENV_DEV_DIR);

	return (override && override[0]) ? override : "/dev";
}

static int smartnic_provider_name_matches(const char *name)
{
	return name && strncmp(name, "smartnic", strlen("smartnic")) == 0;
}

static int smartnic_provider_join_path(char *out, size_t out_len,
				       const char *dir, const char *name)
{
	int written;

	if (!out || !dir || !name) {
		errno = EINVAL;
		return -1;
	}

	written = snprintf(out, out_len, "%s/%s", dir, name);
	if (written < 0 || (size_t)written >= out_len) {
		errno = ENAMETOOLONG;
		return -1;
	}

	return 0;
}

static int smartnic_provider_mailbox_query(int fd,
					   struct smartnic_provider_device *dev)
{
	struct smartnic_ioctl_mbox req;

	memset(&req, 0, sizeof(req));
	req.struct_size = sizeof(req);
	req.opcode = SMARTNIC_CMD_QUERY_DEVICE;
	req.out_len = sizeof(req.data);

	if (ioctl(fd, SMARTNIC_IOCTL_MBOX_EXEC, &req) < 0)
		return -1;

	dev->driver_version = req.data[0];
	dev->features = req.data[1];
	dev->caps = req.data[2];
	dev->status = req.data[3];
	return 0;
}

static int smartnic_provider_mailbox_exec(struct smartnic_provider_context *ctx,
					  uint16_t opcode, const uint32_t *in,
					  size_t in_dwords, uint32_t *out,
					  size_t out_dwords)
{
	struct smartnic_ioctl_mbox req;
	size_t i;

	if (!ctx || in_dwords > SMARTNIC_IOCTL_MAX_DATA_DWORDS ||
	    out_dwords > SMARTNIC_IOCTL_MAX_DATA_DWORDS) {
		errno = EINVAL;
		return -1;
	}

	memset(&req, 0, sizeof(req));
	req.struct_size = sizeof(req);
	req.opcode = opcode;
	req.in_len = in_dwords * sizeof(uint32_t);
	req.out_len = out_dwords * sizeof(uint32_t);

	for (i = 0; i < in_dwords; i++)
		req.data[i] = in[i];

	if (ioctl(ctx->fd, SMARTNIC_IOCTL_MBOX_EXEC, &req) < 0)
		return -1;

	for (i = 0; i < out_dwords; i++)
		out[i] = req.data[i];

	return 0;
}

static int smartnic_provider_context_is_valid(struct smartnic_provider_context *ctx)
{
	if (!ctx) {
		errno = EINVAL;
		return 0;
	}

	pthread_mutex_lock(&ctx->lock);
	if (ctx->closed || ctx->fd < 0) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EBADF;
		return 0;
	}
	pthread_mutex_unlock(&ctx->lock);
	return 1;
}

static int smartnic_provider_validate_abi(struct smartnic_provider_context *ctx)
{
	if (ctx->abi_version != SMARTNIC_PROVIDER_ABI_VERSION) {
		errno = EPROTO;
		return -1;
	}

	return 0;
}

static struct smartnic_provider_pd *
smartnic_provider_pd_alloc_object(struct smartnic_provider_context *ctx,
				  uint32_t pdn)
{
	struct smartnic_provider_pd *pd;

	pd = calloc(1, sizeof(*pd));
	if (!pd)
		return NULL;

	pd->magic = SMARTNIC_PROVIDER_OBJECT_MAGIC_PD;
	pd->ctx = ctx;
	pd->pdn = pdn;
	pd->kernel_handle = pdn;
	pd->refcount = 1;
	return pd;
}

static void smartnic_provider_pd_link_locked(struct smartnic_provider_context *ctx,
					     struct smartnic_provider_pd *pd)
{
	pd->next = ctx->pd_list;
	ctx->pd_list = pd;
	ctx->pd_count++;
}

static int smartnic_provider_pd_unlink_locked(struct smartnic_provider_context *ctx,
					      struct smartnic_provider_pd *pd)
{
	struct smartnic_provider_pd **cursor = &ctx->pd_list;

	while (*cursor) {
		if (*cursor == pd) {
			*cursor = pd->next;
			pd->next = NULL;
			if (ctx->pd_count)
				ctx->pd_count--;
			return 0;
		}
		cursor = &(*cursor)->next;
	}

	errno = EINVAL;
	return -1;
}

static int smartnic_provider_pd_is_linked_locked(struct smartnic_provider_context *ctx,
						 const struct smartnic_provider_pd *pd)
{
	const struct smartnic_provider_pd *cursor;

	for (cursor = ctx->pd_list; cursor; cursor = cursor->next) {
		if (cursor == pd)
			return 1;
	}

	return 0;
}

static struct smartnic_provider_cq *
smartnic_provider_cq_alloc_object(struct smartnic_provider_context *ctx,
				  uint32_t cqn, int cqe)
{
	struct smartnic_provider_cq *cq;

	cq = calloc(1, sizeof(*cq));
	if (!cq)
		return NULL;

	cq->magic = SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ;
	cq->ctx = ctx;
	cq->cqn = cqn;
	cq->kernel_handle = cqn;
	cq->cqe = cqe;
	cq->refcount = 1;

	if (pthread_mutex_init(&cq->lock, NULL) != 0) {
		free(cq);
		errno = ENOMEM;
		return NULL;
	}

	return cq;
}

static void smartnic_provider_cq_free_object(struct smartnic_provider_cq *cq)
{
	if (!cq)
		return;

	pthread_mutex_destroy(&cq->lock);
	free(cq->ring);
	free(cq);
}

static void smartnic_provider_cq_link_locked(struct smartnic_provider_context *ctx,
					     struct smartnic_provider_cq *cq)
{
	cq->next = ctx->cq_list;
	ctx->cq_list = cq;
	ctx->cq_count++;
}

static int smartnic_provider_cq_unlink_locked(struct smartnic_provider_context *ctx,
					      struct smartnic_provider_cq *cq)
{
	struct smartnic_provider_cq **cursor = &ctx->cq_list;

	while (*cursor) {
		if (*cursor == cq) {
			*cursor = cq->next;
			cq->next = NULL;
			if (ctx->cq_count)
				ctx->cq_count--;
			return 0;
		}
		cursor = &(*cursor)->next;
	}

	errno = EINVAL;
	return -1;
}

static int smartnic_provider_cq_is_linked_locked(struct smartnic_provider_context *ctx,
						 const struct smartnic_provider_cq *cq)
{
	const struct smartnic_provider_cq *cursor;

	for (cursor = ctx->cq_list; cursor; cursor = cursor->next) {
		if (cursor == cq)
			return 1;
	}

	return 0;
}

static int smartnic_provider_validate_cqe_count(int cqe)
{
	if (cqe <= 0 || (uint32_t)cqe > SMARTNIC_PROVIDER_DEFAULT_MAX_WR) {
		errno = EINVAL;
		return -1;
	}

	return 0;
}

static void smartnic_provider_translate_wc(const uint32_t data[4],
					   uint32_t consumer_index,
					   struct smartnic_provider_wc *wc)
{
	uint32_t meta = data[0];

	memset(wc, 0, sizeof(*wc));
	wc->wr_id = consumer_index;
	wc->status = meta & SMARTNIC_PROVIDER_CQE_STATUS_MASK;
	wc->opcode = (meta & SMARTNIC_PROVIDER_CQE_OPCODE_MASK) >>
		     SMARTNIC_PROVIDER_CQE_OPCODE_SHIFT;
	wc->wc_flags = (meta & SMARTNIC_PROVIDER_CQE_FLAGS_MASK) >>
		       SMARTNIC_PROVIDER_CQE_FLAGS_SHIFT;
	wc->byte_len = data[1];
	wc->qp_num = data[2];
	if (wc->wc_flags & SMARTNIC_PROVIDER_WC_FLAG_IMM)
		wc->imm_data = data[3];
	else
		wc->vendor_err = data[3];
}

static int smartnic_provider_validate_node(const char *path,
					   struct smartnic_provider_device *dev)
{
	struct stat st;
	int fd;
	int saved_errno;

	if (stat(path, &st) < 0)
		return -1;

	/*
	 * Normal discovery expects the kernel driver to create a character
	 * device. Tests may point SMARTNIC_PROVIDER_DEV_DIR at a directory with
	 * regular files, but those are marked incompatible by the open path.
	 */
	if (!S_ISCHR(st.st_mode)) {
		dev->compatible = 0;
		return 0;
	}

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		dev->compatible = 0;
		return 0;
	}

	if (smartnic_provider_mailbox_query(fd, dev) == 0) {
		dev->abi_version = SMARTNIC_PROVIDER_ABI_VERSION;
		dev->compatible = 1;
	} else {
		saved_errno = errno;
		dev->compatible = 0;
		errno = saved_errno;
	}

	close(fd);
	return 0;
}

static int smartnic_provider_append_device(struct smartnic_provider_device **devices,
					   size_t *count, size_t *capacity,
					   const struct smartnic_provider_device *dev)
{
	struct smartnic_provider_device *new_devices;
	size_t new_capacity;

	if (*count >= SMARTNIC_PROVIDER_MAX_DEVICES)
		return 0;

	if (*count == *capacity) {
		new_capacity = *capacity ? *capacity * 2 : 4;
		if (new_capacity > SMARTNIC_PROVIDER_MAX_DEVICES)
			new_capacity = SMARTNIC_PROVIDER_MAX_DEVICES;

		new_devices = realloc(*devices, new_capacity * sizeof(**devices));
		if (!new_devices)
			return -1;

		*devices = new_devices;
		*capacity = new_capacity;
	}

	(*devices)[*count] = *dev;
	(*count)++;
	return 0;
}

int smartnic_provider_discover(struct smartnic_provider_device **devices,
			       size_t *count)
{
	struct smartnic_provider_device *found = NULL;
	struct smartnic_provider_device dev;
	size_t found_count = 0;
	size_t capacity = 0;
	const char *dir_path;
	struct dirent *entry;
	DIR *dir;
	int err = 0;

	if (!devices || !count) {
		errno = EINVAL;
		return -1;
	}

	*devices = NULL;
	*count = 0;
	dir_path = smartnic_provider_dev_dir();
	dir = opendir(dir_path);
	if (!dir) {
		if (errno == ENOENT)
			return 0;
		return -1;
	}

	while ((entry = readdir(dir)) != NULL) {
		if (!smartnic_provider_name_matches(entry->d_name))
			continue;

		memset(&dev, 0, sizeof(dev));
		snprintf(dev.name, sizeof(dev.name), "%s", entry->d_name);
		if (smartnic_provider_join_path(dev.node_path, sizeof(dev.node_path),
						dir_path, entry->d_name) < 0) {
			err = -1;
			break;
		}

		dev.abi_version = SMARTNIC_PROVIDER_ABI_VERSION;
		(void)smartnic_provider_validate_node(dev.node_path, &dev);
		if (!dev.compatible)
			continue;

		if (smartnic_provider_append_device(&found, &found_count,
						    &capacity, &dev) < 0) {
			err = -1;
			break;
		}
	}

	closedir(dir);
	if (err) {
		free(found);
		return -1;
	}

	*devices = found;
	*count = found_count;
	return 0;
}

void smartnic_provider_free_devices(struct smartnic_provider_device *devices)
{
	free(devices);
}

static int smartnic_provider_context_alloc(const char *node_path, int fd,
					   const struct smartnic_provider_device *dev,
					   struct smartnic_provider_context **out)
{
	struct smartnic_provider_context *ctx;

	ctx = calloc(1, sizeof(*ctx));
	if (!ctx)
		return -1;

	ctx->fd = fd;
	ctx->abi_version = SMARTNIC_PROVIDER_ABI_VERSION;
	if (dev) {
		ctx->driver_version = dev->driver_version;
		ctx->features = dev->features;
		ctx->caps = dev->caps;
		ctx->status = dev->status;
	}
	snprintf(ctx->node_path, sizeof(ctx->node_path), "%s", node_path);

	if (pthread_mutex_init(&ctx->lock, NULL) != 0) {
		free(ctx);
		errno = ENOMEM;
		return -1;
	}

	*out = ctx;
	return 0;
}

static int smartnic_provider_query_context(struct smartnic_provider_context *ctx)
{
	struct smartnic_provider_device dev;

	memset(&dev, 0, sizeof(dev));
	if (smartnic_provider_mailbox_query(ctx->fd, &dev) < 0)
		return -1;

	ctx->driver_version = dev.driver_version;
	ctx->features = dev.features;
	ctx->caps = dev.caps;
	ctx->status = dev.status;
	return 0;
}

static void smartnic_provider_translate_device_attr(
	struct smartnic_provider_context *ctx,
	struct smartnic_provider_device_attr *attr)
{
	memset(attr, 0, sizeof(*attr));
	attr->abi_version = ctx->abi_version;
	attr->driver_version = ctx->driver_version;
	attr->vendor_id = SMARTNIC_PROVIDER_VENDOR_ID;
	attr->device_id = SMARTNIC_PROVIDER_DEVICE_ID;
	attr->features = ctx->features;
	attr->caps = ctx->caps;
	attr->status = ctx->status;
	attr->max_qp = SMARTNIC_PROVIDER_DEFAULT_MAX_QP;
	attr->max_cq = SMARTNIC_PROVIDER_DEFAULT_MAX_CQ;
	attr->max_mr = SMARTNIC_PROVIDER_DEFAULT_MAX_MR;
	attr->max_pd = SMARTNIC_PROVIDER_DEFAULT_MAX_PD;
	attr->max_sge = SMARTNIC_PROVIDER_DEFAULT_MAX_SGE;
	attr->max_wr = SMARTNIC_PROVIDER_DEFAULT_MAX_WR;
	attr->supported_transport = SMARTNIC_PROVIDER_TRANSPORT_RC |
				    SMARTNIC_PROVIDER_TRANSPORT_UD;
	attr->link_layer = SMARTNIC_PROVIDER_LINK_LAYER_ETHERNET;
	attr->atomic_cap = SMARTNIC_PROVIDER_ATOMIC_NONE;
	attr->page_size_cap = 4096ULL;
}

static int smartnic_provider_validate_port(uint8_t port_num)
{
	if (port_num == 0 || port_num > SMARTNIC_PROVIDER_MAX_PORTS) {
		errno = EINVAL;
		return -1;
	}

	return 0;
}

static void smartnic_provider_translate_port_attr(
	uint8_t port_num, struct smartnic_provider_port_attr *attr)
{
	memset(attr, 0, sizeof(*attr));
	attr->port_num = port_num;
	attr->state = SMARTNIC_PROVIDER_PORT_STATE_ACTIVE;
	attr->max_mtu = SMARTNIC_PROVIDER_MTU_4096;
	attr->active_mtu = SMARTNIC_PROVIDER_MTU_4096;
	attr->lid = 0;
	attr->link_layer = SMARTNIC_PROVIDER_LINK_LAYER_ETHERNET;
	attr->active_speed = SMARTNIC_PROVIDER_DEFAULT_SPEED_GBPS;
	attr->active_width = SMARTNIC_PROVIDER_DEFAULT_WIDTH;
	attr->gid_tbl_len = SMARTNIC_PROVIDER_GID_TABLE_LEN;
	attr->pkey_tbl_len = SMARTNIC_PROVIDER_PKEY_TABLE_LEN;
}

static int smartnic_provider_get_gid(uint8_t port_num, uint32_t index,
				     struct smartnic_provider_gid *gid)
{
	(void)port_num;

	if (index >= SMARTNIC_PROVIDER_GID_TABLE_LEN) {
		errno = EINVAL;
		return -1;
	}

	memset(gid, 0, sizeof(*gid));
	return 0;
}

static int smartnic_provider_get_pkey(uint8_t port_num, uint32_t index,
				      uint16_t *pkey)
{
	(void)port_num;

	if (index >= SMARTNIC_PROVIDER_PKEY_TABLE_LEN) {
		errno = EINVAL;
		return -1;
	}

	*pkey = SMARTNIC_PROVIDER_FULL_MEMBERSHIP_PKEY;
	return 0;
}

int smartnic_provider_open_path(const char *node_path,
				struct smartnic_provider_context **ctx)
{
	struct smartnic_provider_context *new_ctx = NULL;
	int fd;

	if (!node_path || !ctx) {
		errno = EINVAL;
		return -1;
	}

	*ctx = NULL;
	fd = open(node_path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;

	if (smartnic_provider_context_alloc(node_path, fd, NULL, &new_ctx) < 0)
		goto err_close_fd;

	if (smartnic_provider_query_context(new_ctx) < 0)
		goto err_free_ctx;

	*ctx = new_ctx;
	return 0;

err_free_ctx:
	pthread_mutex_destroy(&new_ctx->lock);
	free(new_ctx);
err_close_fd:
	close(fd);
	return -1;
}

int smartnic_provider_open(const struct smartnic_provider_device *device,
			   struct smartnic_provider_context **ctx)
{
	if (!device || !device->node_path[0] || !device->compatible) {
		errno = EINVAL;
		return -1;
	}

	return smartnic_provider_open_path(device->node_path, ctx);
}

int smartnic_provider_close(struct smartnic_provider_context *ctx)
{
	int child_count;
	int fd;

	if (!ctx) {
		errno = EINVAL;
		return -1;
	}

	pthread_mutex_lock(&ctx->lock);
	if (ctx->closed) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EBADF;
		return -1;
	}

	child_count = ctx->pd_count || ctx->cq_count || ctx->qp_count ||
		      ctx->mr_count || ctx->ah_count;
	if (child_count) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EBUSY;
		return -1;
	}

	fd = ctx->fd;
	ctx->fd = -1;
	ctx->closed = 1;
	pthread_mutex_unlock(&ctx->lock);

	if (fd >= 0)
		close(fd);

	pthread_mutex_destroy(&ctx->lock);
	free(ctx);
	return 0;
}

int smartnic_provider_query_device(struct smartnic_provider_context *ctx,
				   struct smartnic_provider_device_attr *attr)
{
	if (!attr) {
		errno = EINVAL;
		return -1;
	}

	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	if (smartnic_provider_query_context(ctx) < 0)
		return -1;

	smartnic_provider_translate_device_attr(ctx, attr);
	return 0;
}

int smartnic_provider_query_port(struct smartnic_provider_context *ctx,
				 uint8_t port_num,
				 struct smartnic_provider_port_attr *attr)
{
	if (!attr) {
		errno = EINVAL;
		return -1;
	}

	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	if (smartnic_provider_validate_port(port_num) < 0)
		return -1;

	smartnic_provider_translate_port_attr(port_num, attr);
	return 0;
}

int smartnic_provider_query_gid(struct smartnic_provider_context *ctx,
				uint8_t port_num, uint32_t index,
				struct smartnic_provider_gid *gid)
{
	if (!gid) {
		errno = EINVAL;
		return -1;
	}

	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	if (smartnic_provider_validate_port(port_num) < 0)
		return -1;

	return smartnic_provider_get_gid(port_num, index, gid);
}

int smartnic_provider_query_pkey(struct smartnic_provider_context *ctx,
				 uint8_t port_num, uint32_t index,
				 uint16_t *pkey)
{
	if (!pkey) {
		errno = EINVAL;
		return -1;
	}

	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	if (smartnic_provider_validate_port(port_num) < 0)
		return -1;

	return smartnic_provider_get_pkey(port_num, index, pkey);
}

int smartnic_provider_alloc_pd(struct smartnic_provider_context *ctx,
			       struct smartnic_provider_pd **pd)
{
	struct smartnic_provider_pd *new_pd;
	uint32_t out[1] = { 0 };

	if (!pd) {
		errno = EINVAL;
		return -1;
	}

	*pd = NULL;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (ctx->pd_count >= SMARTNIC_PROVIDER_DEFAULT_MAX_PD) {
		pthread_mutex_unlock(&ctx->lock);
		errno = ENOSPC;
		return -1;
	}

	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_ALLOC_PD,
					   NULL, 0, out, 1) < 0) {
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	if (out[0] == 0) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EIO;
		return -1;
	}

	new_pd = smartnic_provider_pd_alloc_object(ctx, out[0]);
	if (!new_pd) {
		uint32_t destroy_in[1] = { out[0] };
		int saved_errno = errno;

		(void)smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_DEALLOC_PD,
						     destroy_in, 1, NULL, 0);
		pthread_mutex_unlock(&ctx->lock);
		errno = saved_errno;
		return -1;
	}

	smartnic_provider_pd_link_locked(ctx, new_pd);
	pthread_mutex_unlock(&ctx->lock);

	*pd = new_pd;
	return 0;
}

int smartnic_provider_dealloc_pd(struct smartnic_provider_pd *pd)
{
	struct smartnic_provider_context *ctx;
	uint32_t in[1];

	if (!pd || pd->magic != SMARTNIC_PROVIDER_OBJECT_MAGIC_PD || !pd->ctx) {
		errno = EINVAL;
		return -1;
	}

	ctx = pd->ctx;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (!smartnic_provider_pd_is_linked_locked(ctx, pd)) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	if (pd->child_count != 0 || pd->refcount > 1) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EBUSY;
		return -1;
	}

	in[0] = pd->kernel_handle;
	if (in[0] == 0) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_DEALLOC_PD,
					   in, 1, NULL, 0) < 0) {
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	if (smartnic_provider_pd_unlink_locked(ctx, pd) < 0) {
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	pd->magic = 0;
	pd->ctx = NULL;
	pd->kernel_handle = 0;
	pthread_mutex_unlock(&ctx->lock);

	free(pd);
	return 0;
}

int smartnic_provider_create_cq(struct smartnic_provider_context *ctx, int cqe,
				struct smartnic_provider_cq **cq)
{
	struct smartnic_provider_cq *new_cq;
	uint32_t in[1];
	uint32_t out[1] = { 0 };

	if (!cq) {
		errno = EINVAL;
		return -1;
	}

	*cq = NULL;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	if (smartnic_provider_validate_abi(ctx) < 0)
		return -1;

	if (smartnic_provider_validate_cqe_count(cqe) < 0)
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (ctx->cq_count >= SMARTNIC_PROVIDER_DEFAULT_MAX_CQ) {
		pthread_mutex_unlock(&ctx->lock);
		errno = ENOSPC;
		return -1;
	}

	in[0] = (uint32_t)cqe;
	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_CREATE_CQ,
					   in, 1, out, 1) < 0) {
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	if (out[0] == 0) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EIO;
		return -1;
	}

	new_cq = smartnic_provider_cq_alloc_object(ctx, out[0], cqe);
	if (!new_cq) {
		uint32_t destroy_in[1] = { out[0] };
		int saved_errno = errno;

		(void)smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_DESTROY_CQ,
						     destroy_in, 1, NULL, 0);
		pthread_mutex_unlock(&ctx->lock);
		errno = saved_errno;
		return -1;
	}

	smartnic_provider_cq_link_locked(ctx, new_cq);
	pthread_mutex_unlock(&ctx->lock);

	*cq = new_cq;
	return 0;
}

int smartnic_provider_destroy_cq(struct smartnic_provider_cq *cq)
{
	struct smartnic_provider_context *ctx;
	uint32_t in[1];

	if (!cq || cq->magic != SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ || !cq->ctx) {
		errno = EINVAL;
		return -1;
	}

	ctx = cq->ctx;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (!smartnic_provider_cq_is_linked_locked(ctx, cq)) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	pthread_mutex_lock(&cq->lock);
	if (cq->child_count != 0 || cq->refcount > 1) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		errno = EBUSY;
		return -1;
	}

	in[0] = cq->kernel_handle;
	if (in[0] == 0) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_DESTROY_CQ,
					   in, 1, NULL, 0) < 0) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	if (smartnic_provider_cq_unlink_locked(ctx, cq) < 0) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	cq->magic = 0;
	cq->ctx = NULL;
	cq->kernel_handle = 0;
	pthread_mutex_unlock(&cq->lock);
	pthread_mutex_unlock(&ctx->lock);

	smartnic_provider_cq_free_object(cq);
	return 0;
}

int smartnic_provider_resize_cq(struct smartnic_provider_cq *cq, int cqe)
{
	struct smartnic_provider_context *ctx;
	uint32_t in[2];

	if (!cq || cq->magic != SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ || !cq->ctx) {
		errno = EINVAL;
		return -1;
	}

	if (smartnic_provider_validate_cqe_count(cqe) < 0)
		return -1;

	ctx = cq->ctx;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (!smartnic_provider_cq_is_linked_locked(ctx, cq)) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	pthread_mutex_lock(&cq->lock);
	in[0] = cq->kernel_handle;
	in[1] = (uint32_t)cqe;
	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_RESIZE_CQ,
					   in, 2, NULL, 0) < 0) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	cq->cqe = cqe;
	if (cq->consumer_index >= (uint32_t)cqe)
		cq->consumer_index = 0;
	if (cq->producer_index >= (uint32_t)cqe)
		cq->producer_index = 0;
	pthread_mutex_unlock(&cq->lock);
	pthread_mutex_unlock(&ctx->lock);
	return 0;
}

int smartnic_provider_poll_cq(struct smartnic_provider_cq *cq, int num_entries,
			      struct smartnic_provider_wc *wc)
{
	struct smartnic_provider_context *ctx;
	uint32_t in[2];
	uint32_t out[4];
	int polled = 0;

	if (!cq || cq->magic != SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ || !cq->ctx ||
	    num_entries < 0 || (num_entries > 0 && !wc)) {
		errno = EINVAL;
		return -EINVAL;
	}

	if (num_entries == 0)
		return 0;

	ctx = cq->ctx;
	if (!smartnic_provider_context_is_valid(ctx))
		return -errno;

	pthread_mutex_lock(&cq->lock);
	while (polled < num_entries) {
		memset(out, 0, sizeof(out));
		in[0] = cq->kernel_handle;
		in[1] = cq->consumer_index;

		if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_POLL_CQ,
						   in, 2, out, 4) < 0) {
			int err = errno;

			pthread_mutex_unlock(&cq->lock);
			return polled ? polled : -err;
		}

		if ((out[0] & SMARTNIC_PROVIDER_CQE_VALID_BIT) == 0)
			break;

		smartnic_provider_translate_wc(out, cq->consumer_index,
					       &wc[polled]);
		cq->consumer_index++;
		if (cq->consumer_index >= (uint32_t)cq->cqe)
			cq->consumer_index = 0;
		polled++;
	}
	pthread_mutex_unlock(&cq->lock);

	return polled;
}

int smartnic_provider_req_notify_cq(struct smartnic_provider_cq *cq,
				    int solicited_only)
{
	struct smartnic_provider_context *ctx;
	uint32_t in[2];

	if (!cq || cq->magic != SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ || !cq->ctx) {
		errno = EINVAL;
		return -1;
	}

	ctx = cq->ctx;
	if (!smartnic_provider_context_is_valid(ctx))
		return -1;

	pthread_mutex_lock(&ctx->lock);
	if (!smartnic_provider_cq_is_linked_locked(ctx, cq)) {
		pthread_mutex_unlock(&ctx->lock);
		errno = EINVAL;
		return -1;
	}

	pthread_mutex_lock(&cq->lock);
	in[0] = cq->kernel_handle;
	in[1] = solicited_only ? SMARTNIC_PROVIDER_CQ_NOTIFY_SOLICITED :
				 SMARTNIC_PROVIDER_CQ_NOTIFY_NEXT;
	if (smartnic_provider_mailbox_exec(ctx, SMARTNIC_CMD_ARM_CQ,
					   in, 2, NULL, 0) < 0) {
		pthread_mutex_unlock(&cq->lock);
		pthread_mutex_unlock(&ctx->lock);
		return -1;
	}

	cq->armed = 1;
	cq->solicited_only = solicited_only ? 1 : 0;
	pthread_mutex_unlock(&cq->lock);
	pthread_mutex_unlock(&ctx->lock);
	return 0;
}

const char *smartnic_provider_strerror(int err)
{
	return strerror(err < 0 ? -err : err);
}
