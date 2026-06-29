// SPDX-License-Identifier: MIT
/*
 * Minimal SmartNIC provider verbs-style RC Send/Recv example.
 *
 * This is a bring-up example for the project userspace provider API. It uses a
 * loopback-style RC QP setup when the underlying driver/device supports it.
 */

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <smartnic_provider.h>

#define EXAMPLE_SKIP 77
#define EXAMPLE_CQ_DEPTH 16
#define EXAMPLE_WR_DEPTH 8
#define EXAMPLE_POLL_TRIES 1000

static void print_errno(const char *what)
{
	fprintf(stderr, "%s failed: %s\n", what, strerror(errno));
}

static int modify_qp_state(struct smartnic_provider_qp *qp,
			   struct smartnic_provider_qp_attr *attr,
			   uint32_t mask, const char *label)
{
	if (smartnic_provider_modify_qp(qp, attr, mask) < 0) {
		print_errno(label);
		return -1;
	}

	return 0;
}

static int bring_qp_to_rts(struct smartnic_provider_qp *qp)
{
	struct smartnic_provider_qp_attr attr;

	memset(&attr, 0, sizeof(attr));
	attr.qp_state = SMARTNIC_PROVIDER_QPS_INIT;
	attr.port_num = 1;
	attr.pkey_index = 0;
	if (modify_qp_state(qp, &attr, SMARTNIC_PROVIDER_QP_REQUIRED_INIT,
			    "modify QP RESET->INIT") < 0)
		return -1;

	memset(&attr, 0, sizeof(attr));
	attr.qp_state = SMARTNIC_PROVIDER_QPS_RTR;
	attr.path_mtu = SMARTNIC_PROVIDER_MTU_4096;
	attr.dest_qpn = qp->qpn;
	attr.rq_psn = 0;
	if (modify_qp_state(qp, &attr, SMARTNIC_PROVIDER_QP_REQUIRED_RTR,
			    "modify QP INIT->RTR") < 0)
		return -1;

	memset(&attr, 0, sizeof(attr));
	attr.qp_state = SMARTNIC_PROVIDER_QPS_RTS;
	attr.sq_psn = 0;
	attr.retry_count = 1;
	attr.rnr_retry = 1;
	attr.timeout = 14;
	if (modify_qp_state(qp, &attr, SMARTNIC_PROVIDER_QP_REQUIRED_RTS,
			    "modify QP RTR->RTS") < 0)
		return -1;

	return 0;
}

static int poll_success(struct smartnic_provider_cq *cq, int needed)
{
	int seen = 0;

	while (seen < needed) {
		struct smartnic_provider_wc wc[4];
		int polled;
		int i;

		polled = smartnic_provider_poll_cq(cq, 4, wc);
		if (polled < 0) {
			errno = -polled;
			print_errno("poll CQ");
			return -1;
		}

		for (i = 0; i < polled; i++) {
			printf("CQE wr_id=0x%" PRIx64 " status=%u opcode=%u byte_len=%u qp=0x%x\n",
			       wc[i].wr_id, wc[i].status, wc[i].opcode,
			       wc[i].byte_len, wc[i].qp_num);
			if (wc[i].status != SMARTNIC_PROVIDER_WC_SUCCESS) {
				fprintf(stderr, "completion failed: status=%u vendor_err=0x%x\n",
					wc[i].status, wc[i].vendor_err);
				return -1;
			}
			seen++;
		}

		if (polled == 0) {
			static int tries;

			if (++tries >= EXAMPLE_POLL_TRIES) {
				fprintf(stderr, "timed out waiting for %d completions; saw %d\n",
					needed, seen);
				return -1;
			}
			usleep(1000);
		}
	}

	return 0;
}

int main(int argc, char **argv)
{
	const char *path = getenv("SMARTNIC_PROVIDER_DEVICE");
	struct smartnic_provider_context *ctx = NULL;
	struct smartnic_provider_device_attr dev_attr;
	struct smartnic_provider_pd *pd = NULL;
	struct smartnic_provider_cq *cq = NULL;
	struct smartnic_provider_qp *qp = NULL;
	struct smartnic_provider_mr *send_mr = NULL;
	struct smartnic_provider_mr *recv_mr = NULL;
	struct smartnic_provider_qp_init_attr init_attr;
	struct smartnic_provider_sge recv_sge;
	struct smartnic_provider_sge send_sge;
	struct smartnic_provider_recv_wr recv_wr;
	struct smartnic_provider_send_wr send_wr;
	const struct smartnic_provider_recv_wr *bad_recv = NULL;
	const struct smartnic_provider_send_wr *bad_send = NULL;
	char send_buf[64] = "smartnic minimal rc send";
	char recv_buf[64];
	int rc = 1;

	if (argc > 1)
		path = argv[1];
	if (!path || !path[0])
		path = "/dev/smartnic0";

	if (smartnic_provider_open_path(path, &ctx) < 0) {
		if (errno == ENOENT || errno == ENODEV || errno == ENXIO ||
		    errno == EACCES) {
			printf("SKIP: cannot open %s: %s\n", path, strerror(errno));
			return EXAMPLE_SKIP;
		}
		print_errno("open provider context");
		return 1;
	}

	if (smartnic_provider_query_device(ctx, &dev_attr) < 0) {
		print_errno("query device");
		goto out;
	}
	printf("opened %s abi=%u max_qp=%u max_cq=%u max_mr=%u\n",
	       path, dev_attr.abi_version, dev_attr.max_qp,
	       dev_attr.max_cq, dev_attr.max_mr);

	if (smartnic_provider_alloc_pd(ctx, &pd) < 0) {
		print_errno("alloc PD");
		goto out;
	}

	if (smartnic_provider_create_cq(ctx, EXAMPLE_CQ_DEPTH, &cq) < 0) {
		print_errno("create CQ");
		goto out;
	}

	memset(&init_attr, 0, sizeof(init_attr));
	init_attr.send_cq = cq;
	init_attr.recv_cq = cq;
	init_attr.qp_type = SMARTNIC_PROVIDER_QPT_RC;
	init_attr.max_send_wr = EXAMPLE_WR_DEPTH;
	init_attr.max_recv_wr = EXAMPLE_WR_DEPTH;
	init_attr.max_send_sge = 1;
	init_attr.max_recv_sge = 1;
	init_attr.sq_sig_all = 0;
	if (smartnic_provider_create_qp(pd, &init_attr, &qp) < 0) {
		print_errno("create QP");
		goto out;
	}
	printf("created loopback RC QP qpn=0x%x\n", qp->qpn);

	if (bring_qp_to_rts(qp) < 0)
		goto out;

	memset(recv_buf, 0, sizeof(recv_buf));
	if (smartnic_provider_reg_mr(pd, recv_buf, sizeof(recv_buf),
				     SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE |
				     SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE |
				     SMARTNIC_PROVIDER_ACCESS_REMOTE_READ,
				     &recv_mr) < 0) {
		print_errno("register receive MR");
		goto out;
	}
	if (smartnic_provider_reg_mr(pd, send_buf, sizeof(send_buf),
				     0, &send_mr) < 0) {
		print_errno("register send MR");
		goto out;
	}
	printf("registered recv MR lkey=0x%x rkey=0x%x; send MR lkey=0x%x\n",
	       recv_mr->lkey, recv_mr->rkey, send_mr->lkey);

	memset(&recv_sge, 0, sizeof(recv_sge));
	recv_sge.addr = (uint64_t)(uintptr_t)recv_buf;
	recv_sge.length = sizeof(recv_buf);
	recv_sge.lkey = recv_mr->lkey;

	memset(&recv_wr, 0, sizeof(recv_wr));
	recv_wr.wr_id = 0x1001;
	recv_wr.sg_list = &recv_sge;
	recv_wr.num_sge = 1;
	if (smartnic_provider_post_recv(qp, &recv_wr, &bad_recv) < 0) {
		fprintf(stderr, "post recv failed%s%s\n",
			bad_recv ? " at wr_id=" : "",
			bad_recv ? "0x1001" : "");
		print_errno("post recv");
		goto out;
	}

	memset(&send_sge, 0, sizeof(send_sge));
	send_sge.addr = (uint64_t)(uintptr_t)send_buf;
	send_sge.length = (uint32_t)strlen(send_buf) + 1;
	send_sge.lkey = send_mr->lkey;

	memset(&send_wr, 0, sizeof(send_wr));
	send_wr.wr_id = 0x2001;
	send_wr.opcode = SMARTNIC_PROVIDER_WR_SEND;
	send_wr.send_flags = SMARTNIC_PROVIDER_SEND_SIGNALED;
	send_wr.sg_list = &send_sge;
	send_wr.num_sge = 1;
	if (smartnic_provider_post_send(qp, &send_wr, &bad_send) < 0) {
		fprintf(stderr, "post send failed%s%s\n",
			bad_send ? " at wr_id=" : "",
			bad_send ? "0x2001" : "");
		print_errno("post send");
		goto out;
	}

	if (poll_success(cq, 2) < 0)
		goto out;

	printf("SUCCESS: minimal RC Send/Recv completed; recv buffer=\"%s\"\n",
	       recv_buf);
	rc = 0;

out:
	if (qp && smartnic_provider_destroy_qp(qp) < 0)
		print_errno("destroy QP");
	if (send_mr && smartnic_provider_dereg_mr(send_mr) < 0)
		print_errno("deregister send MR");
	if (recv_mr && smartnic_provider_dereg_mr(recv_mr) < 0)
		print_errno("deregister receive MR");
	if (cq && smartnic_provider_destroy_cq(cq) < 0)
		print_errno("destroy CQ");
	if (pd && smartnic_provider_dealloc_pd(pd) < 0)
		print_errno("dealloc PD");
	if (ctx && smartnic_provider_close(ctx) < 0)
		print_errno("close provider context");

	return rc;
}
