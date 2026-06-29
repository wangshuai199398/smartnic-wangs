# libsmartnic 用户态 provider 入口。
# 13.1 只实现设备发现和 context open/close；PD/CQ/QP/MR 仍留给后续任务。

CC ?= cc
AR ?= ar

CPPFLAGS ?=
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -pthread
PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include
PKGCONFIGDIR ?= $(LIBDIR)/pkgconfig
PROVIDERDIR ?= $(LIBDIR)/smartnic/providers
VERSION ?= 0.1.0

PROJECT_ROOT := ../..
UAPI_INC := $(PROJECT_ROOT)/include/uapi

PROVIDER_LIB := libsmartnic_provider.a
PROVIDER_OBJS := smartnic_provider.o
PC_TEMPLATE := libsmartnic-provider.pc.in
PC_FILE := build/pkgconfig/libsmartnic-provider.pc
PROVIDER_METADATA := smartnic-provider.json
STAGED_METADATA := build/providers/$(PROVIDER_METADATA)

.PHONY: all provider provider-build packaging pkgconfig metadata tools test install clean FORCE

all: packaging provider tools

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

packaging: pkgconfig metadata

pkgconfig: $(PC_FILE)

metadata: $(STAGED_METADATA)

$(PC_FILE): $(PC_TEMPLATE) Makefile FORCE
	@mkdir -p $(dir $@)
	@sed -e 's|@prefix@|$(PREFIX)|g' \
		-e 's|@libdir@|$(LIBDIR)|g' \
		-e 's|@includedir@|$(INCLUDEDIR)|g' \
		-e 's|@version@|$(VERSION)|g' $< > $@

$(STAGED_METADATA): $(PROVIDER_METADATA) Makefile FORCE
	@mkdir -p $(dir $@)
	@cp $(PROVIDER_METADATA) $@

$(PROVIDER_LIB): $(PROVIDER_OBJS)
	$(AR) rcs $@ $^

%.o: %.c smartnic_provider.h $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I. -I$(UAPI_INC) $(CFLAGS) -c -o $@ $<

tools:
	@$(MAKE) -C ../../tools

test:
	@python3 tests/test_smartnic_provider_static.py
	@python3 tests/test_smartnic_provider_packaging.py

install: packaging provider
	@mkdir -p $(DESTDIR)$(INCLUDEDIR)/smartnic
	@mkdir -p $(DESTDIR)$(LIBDIR)
	@mkdir -p $(DESTDIR)$(PKGCONFIGDIR)
	@mkdir -p $(DESTDIR)$(PROVIDERDIR)
	@cp smartnic_provider.h $(DESTDIR)$(INCLUDEDIR)/smartnic/
	@if [ -f $(PROVIDER_LIB) ]; then cp $(PROVIDER_LIB) $(DESTDIR)$(LIBDIR)/; fi
	@cp $(PC_FILE) $(DESTDIR)$(PKGCONFIGDIR)/
	@cp $(STAGED_METADATA) $(DESTDIR)$(PROVIDERDIR)/

clean:
	@$(MAKE) -C ../../tools clean
	@rm -rf build
	@rm -f $(PROVIDER_LIB) $(PROVIDER_OBJS)
