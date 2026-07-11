KEYWORK ?= keywork
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/keywork-shell
SYSTEMD_USER_DIR ?= $(HOME)/.config/systemd/user

SCRIPT := lua/init.lua
MODULES := \
	lua/shell/ipc.lua \
	lua/shell/bar/init.lua \
	lua/shell/bar/colors.lua \
	lua/shell/bar/network.lua \
	lua/shell/bar/status.lua \
	lua/shell/bar/sway.lua \
	lua/shell/bar/tray.lua \
	lua/shell/bar/util.lua \
	lua/shell/launcher/init.lua \
	lua/shell/launcher/history.lua \
	lua/shell/launcher/match.lua \
	lua/shell/launcher/providers/init.lua \
	lua/shell/launcher/providers/apps.lua \
	lua/shell/launcher/providers/power.lua
BIN := keywork-shell
SERVICE := keywork-shell.service

.PHONY: all check run install install-app install-service reload-service clean

all: check

check: $(SCRIPT) $(MODULES)
	for file in $(SCRIPT) $(MODULES); do luajit -b $$file /tmp/keywork-shell-check.luac || exit 1; done
	rm -f /tmp/keywork-shell-check.luac

run: check
	$(KEYWORK) --script=$(SCRIPT)

install: install-app install-service

install-app: check
	install -d $(DATADIR)/lua/shell/bar $(DATADIR)/lua/shell/launcher/providers $(BINDIR)
	install -m 0644 $(SCRIPT) $(DATADIR)/$(SCRIPT)
	for file in $(MODULES); do install -m 0644 $$file $(DATADIR)/$$file; done
	install -m 0755 bin/$(BIN) $(BINDIR)/$(BIN)

install-service:
	mkdir -p $(SYSTEMD_USER_DIR)
	cp $(SERVICE) $(SYSTEMD_USER_DIR)/$(SERVICE)
	systemctl --user daemon-reload

reload-service: install
	systemctl --user restart $(SERVICE)

clean:
	rm -rf .build
