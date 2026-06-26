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

.PHONY: all clean test install

all: $(LIB) $(BIN)

$(LIB): $(LIB_OBJS)
	$(AR) rcs $@ $^

$(BIN): smartnicctl.o $(LIB)
	$(CC) $(LDFLAGS) -o $@ smartnicctl.o $(LIB)

%.o: %.c libsmartnic.h $(PROJECT_ROOT)/include/uapi/linux/smartnic_ioctl.h
	$(CC) $(CPPFLAGS) -I. -I$(UAPI_INC) $(CFLAGS) -c -o $@ $<

test: all
	@./smartnicctl --help >/dev/null
	@python3 tests/test_smartnicctl.py

install: all
	@echo "install target is intentionally left to packaging in this prototype"

clean:
	@rm -f $(BIN) $(LIB) *.o
