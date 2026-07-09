KEYWORK ?= keywork
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/keywork-shell

SCRIPT := lua/shell/init.lua
MODULES := \
	lua/shell/ipc.lua \
	lua/shell/bar/init.lua \
	lua/shell/bar/colors.lua \
	lua/shell/bar/status.lua \
	lua/shell/bar/sway.lua \
	lua/shell/bar/tray.lua \
	lua/shell/bar/util.lua \
	lua/shell/launcher/init.lua \
	lua/shell/launcher/apps.lua \
	lua/shell/launcher/history.lua \
	lua/shell/launcher/match.lua
BIN := keywork-shell

.PHONY: all check run install clean

all: check

check: $(SCRIPT) $(MODULES)
	for file in $(SCRIPT) $(MODULES); do luajit -b $$file /tmp/keywork-shell-check.luac || exit 1; done
	rm -f /tmp/keywork-shell-check.luac

run: check
	LUA_PATH="lua/?.lua;lua/?/init.lua;;" $(KEYWORK) --script=$(SCRIPT)

install: check
	install -d $(DATADIR)/lua/shell/bar $(DATADIR)/lua/shell/launcher $(BINDIR)
	install -m 0644 $(SCRIPT) $(DATADIR)/$(SCRIPT)
	for file in $(MODULES); do install -m 0644 $$file $(DATADIR)/$$file; done
	install -m 0755 bin/$(BIN) $(BINDIR)/$(BIN)

clean:
	rm -rf .build
