# Fast functional-6502 headless bridge (drop-in for Sim6502HeadlessBridge).
CC      ?= cc
CFLAGS  ?= -O3 -std=c11 -Wall -Wextra
TARGET   = fast6502_bridge
SRCS     = fast6502_bridge.c cpu6502.c
HDRS     = cpu6502.h

$(TARGET): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS)

clean:
	rm -f $(TARGET)

.PHONY: clean
