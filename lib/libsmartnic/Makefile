# libsmartnic 用户态 provider 入口。
# 13.1 只实现设备发现和 context open/close；PD/CQ/QP/MR 仍留给后续任务。

CC ?= cc
AR ?= ar

CPPFLAGS ?=
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -pthread

PROJECT_ROOT := ../..
UAPI_INC := $(PROJECT_ROOT)/include/uapi

PROVIDER_LIB := libsmartnic_provider.a
PROVIDER_OBJS := smartnic_provider.o

.PHONY: all provider provider-build tools test clean

all: provider tools

provider:
	@if printf '#include <linux/ioctl.h>\n#include <linux/types.h>\nint main(void){return 0;}\n' | \
		$(CC) -x c - -o /tmp/smartnic-provider-uapi-check.$$ >/dev/null 2>&1; then \
		rm -f /tmp/smartnic-provider-uapi-check.$$; \
		$(MAKE) provider-build; \
	else \
		rm -f /tmp/smartnic-provider-uapi-check.$$; \
		echo "[lib/libsmartnic] Linux UAPI headers not available; provider build skipped."; \
	fi

provider-build: $(PROVIDER_LIB)

$(PROVIDER_LIB): $(PROVIDER_OBJS)
	$(AR) rcs $@ $^

%.o: %.c smartnic_provider.h $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I. -I$(UAPI_INC) $(CFLAGS) -c -o $@ $<

tools:
	@$(MAKE) -C ../../tools

test:
	@python3 tests/test_smartnic_provider_static.py

clean:
	@$(MAKE) -C ../../tools clean
	@rm -f $(PROVIDER_LIB) $(PROVIDER_OBJS)
