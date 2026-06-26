CC ?= cc
CPPFLAGS ?=
CFLAGS ?= -O2 -g -Wall -Wextra -Werror

PROJECT_ROOT := ..
UAPI_INC := $(PROJECT_ROOT)/include/uapi

EXAMPLES := smartnic_ioctl_example smartnic_poll_example

.PHONY: all clean

all: $(EXAMPLES)

%: %.c $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I$(UAPI_INC) $(CFLAGS) -o $@ $<

clean:
	@rm -f $(EXAMPLES)
