CC ?= cc
AR ?= ar

CPPFLAGS ?=
CFLAGS ?= -O2 -g -Wall -Wextra -Werror
LDFLAGS ?=

PROJECT_ROOT := ..
UAPI_INC := $(PROJECT_ROOT)/include/uapi

LIB_OBJS := libsmartnic.o
BIN := smartnicctl
LIB := libsmartnic.a

.PHONY: all build clean test examples install

all:
	@if printf '#include <linux/ioctl.h>\n#include <linux/types.h>\nint main(void){return 0;}\n' | \
		$(CC) -x c - -o /tmp/smartnic-tools-uapi-check.$$ >/dev/null 2>&1; then \
		rm -f /tmp/smartnic-tools-uapi-check.$$; \
		$(MAKE) build; \
	else \
		rm -f /tmp/smartnic-tools-uapi-check.$$; \
		echo "[tools] Linux UAPI headers not available; tools build skipped."; \
	fi

build: $(LIB) $(BIN)

$(LIB): $(LIB_OBJS)
	$(AR) rcs $@ $^

$(BIN): smartnicctl.o $(LIB)
	$(CC) $(LDFLAGS) -o $@ smartnicctl.o $(LIB)

%.o: %.c libsmartnic.h $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I. -I$(UAPI_INC) $(CFLAGS) -c -o $@ $<

test: all
	@if [ -x ./smartnicctl ]; then \
		./smartnicctl --help >/dev/null; \
		python3 tests/test_smartnicctl.py; \
	else \
		echo "[tools] smartnicctl not built; Linux-only tool tests skipped."; \
	fi

examples:
	@$(MAKE) -C ../examples

install: all
	@echo "install target is intentionally left to packaging in this prototype"

clean:
	@rm -f $(BIN) $(LIB) *.o
