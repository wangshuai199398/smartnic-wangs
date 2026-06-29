CC ?= cc
CPPFLAGS ?=
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -pthread
LDFLAGS ?=

PROJECT_ROOT := ..
UAPI_INC := $(PROJECT_ROOT)/include/uapi
PROVIDER_DIR := $(PROJECT_ROOT)/lib/libsmartnic

UAPI_EXAMPLES := smartnic_ioctl_example smartnic_poll_example smartnic_user_flow_example
PROVIDER_EXAMPLES := smartnic_provider_query_example smartnic_provider_cq_poll_example smartnic_provider_async_event_example

.PHONY: all clean

all:
	@if printf '#include <linux/ioctl.h>\n#include <linux/types.h>\nint main(void){return 0;}\n' | \
		$(CC) -x c - -o /tmp/smartnic-examples-uapi-check.$$ >/dev/null 2>&1; then \
		rm -f /tmp/smartnic-examples-uapi-check.$$; \
		$(MAKE) build; \
	else \
		rm -f /tmp/smartnic-examples-uapi-check.$$; \
		echo "[examples] Linux UAPI headers not available; examples build skipped."; \
	fi

build: $(UAPI_EXAMPLES) provider-examples

%: %.c $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I$(UAPI_INC) $(CFLAGS) -o $@ $<

provider-examples: $(PROVIDER_DIR)/libsmartnic_provider.a $(PROVIDER_EXAMPLES)

$(PROVIDER_DIR)/libsmartnic_provider.a:
	@$(MAKE) -C $(PROVIDER_DIR) provider-build

smartnic_provider_%_example: smartnic_provider_%_example.c $(PROVIDER_DIR)/smartnic_provider.h $(PROVIDER_DIR)/libsmartnic_provider.a
	$(CC) $(CPPFLAGS) -I$(PROVIDER_DIR) -I$(UAPI_INC) $(CFLAGS) -o $@ $< $(PROVIDER_DIR)/libsmartnic_provider.a $(LDFLAGS)

clean:
	@rm -f $(UAPI_EXAMPLES) $(PROVIDER_EXAMPLES)
