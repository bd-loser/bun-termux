# Bun for Termux — pure-android Makefile
# SHELL must use Termux bash path (not /bin/bash)

SHELL := /data/data/com.termux/files/usr/bin/bash
.DEFAULT_GOAL := help

PKGVER ?= 1.3.14
PKGREL ?= 1
ARCH ?= aarch64

PROJECT_DIR := $(shell pwd)
DIST_DIR := $(PROJECT_DIR)/dist
RUNTIME_DIR := $(PROJECT_DIR)/runtime
RUNTIME_BIN := $(RUNTIME_DIR)/bun

DEB_NAME := bun_$(PKGVER)_$(ARCH).deb
PAC_NAME := bun-$(PKGVER)-$(PKGREL)-$(ARCH).pkg.tar.xz

.PHONY: help build deb pacman clean fix-network

help:
	@echo "Bun for Termux — pure-android"
	@echo ""
	@echo "make build       Download Android Bun binary"
	@echo "make deb         Build DEB package (with network fix + postinst)"
	@echo "make pacman      Build pacman package"
	@echo "make clean       Clean build artifacts"
	@echo ""
	@echo "Variables: PKGVER=$(PKGVER) ARCH=$(ARCH)"

build:
	@echo "Downloading Android Bun v$(PKGVER)..."
	@mkdir -p $(RUNTIME_DIR)
	@ZIP="bun-linux-$(ARCH)-android.zip"; \
	URL="https://github.com/oven-sh/bun/releases/download/bun-v$(PKGVER)/$$ZIP"; \
	if [ -f "$(RUNTIME_BIN)" ]; then \
		echo "  already cached: $$(file $(RUNTIME_BIN) | cut -d: -f2 | head -c60)"; \
	else \
		mkdir -p /tmp/bun-dl-$$$$; \
		cd /tmp/bun-dl-$$$$; \
		curl -fL "$$URL" -o bun.zip || { echo "Download failed"; exit 1; }; \
		unzip -o bun.zip -d extracted >/dev/null 2>&1; \
		B=$$(find extracted -name bun -type f | head -1); \
		[ -n "$$B" ] && cp "$$B" $(RUNTIME_BIN) && chmod 755 $(RUNTIME_BIN); \
		rm -rf /tmp/bun-dl-$$$$; \
		echo "  downloaded: $$(file $(RUNTIME_BIN) | cut -d: -f2 | head -c60)"; \
	fi

deb: build
	@echo "Building DEB: $(DEB_NAME)"
	@mkdir -p $(DIST_DIR)
	@ROOT="$$(mktemp -d)"; \
	TMPUSR="$$ROOT/data/data/com.termux/files/usr"; \
	mkdir -p "$$ROOT/DEBIAN" "$$TMPUSR/bin" "$$TMPUSR/lib/bun-termux"; \
	install -m755 $(RUNTIME_BIN) "$$TMPUSR/lib/bun-termux/bun"; \
	install -m755 scripts/launcher-bun.sh "$$TMPUSR/bin/bun"; \
	install -m755 scripts/launcher-bunx.sh "$$TMPUSR/bin/bunx"; \
	install -m755 scripts/fix-bun-network.sh "$$TMPUSR/bin/bun-fix-network"; \
	cat > "$$ROOT/DEBIAN/control" << CONTROL; \
	Package: bun; \
	Version: $(PKGVER); \
	Architecture: $(ARCH); \
	Maintainer: bd-loser; \
	Section: utils; \
	Priority: optional; \
	Description: Android-native Bun runtime for Termux Bionic + auto network fix; \
	Depends: bash, ncurses, curl; \
CONTROL; \
	echo "Installed-Size: $$(du -sk $$ROOT | cut -f1)" >> "$$ROOT/DEBIAN/control"; \
	install -m755 packaging/deb/DEBIAN/postinst "$$ROOT/DEBIAN/postinst"; \
	chmod 755 "$$ROOT" "$$ROOT/DEBIAN"; \
	dpkg-deb --build "$$ROOT" "$(DIST_DIR)/$(DEB_NAME)" >/dev/null 2>&1; \
	rm -rf "$$ROOT"; \
	echo "  $(DIST_DIR)/$(DEB_NAME)"

pacman: build
	@echo "Building pacman: $(PAC_NAME)"
	@mkdir -p $(DIST_DIR)
	@ROOT="$$(mktemp -d)"; \
	TMPUSR="$$ROOT/data/data/com.termux/files/usr"; \
	mkdir -p "$$TMPUSR/bin" "$$TMPUSR/lib/bun-termux"; \
	install -m755 $(RUNTIME_BIN) "$$TMPUSR/lib/bun-termux/bun"; \
	install -m755 scripts/launcher-bun.sh "$$TMPUSR/bin/bun"; \
	install -m755 scripts/launcher-bunx.sh "$$TMPUSR/bin/bunx"; \
	install -m755 scripts/fix-bun-network.sh "$$TMPUSR/bin/bun-fix-network"; \
	cat > "$$ROOT/.PKGINFO" << PKGINFO; \
	pkgname = bun; \
	pkgver = $(PKGVER)-$(PKGREL); \
	pkgdesc = Android-native Bun runtime for Termux Bionic + auto network fix; \
	url = https://github.com/oven-sh/bun; \
	builddate = $$(date +%Y-%m-%d); \
	packager = bd-loser; \
	size = $$(stat -c%s $(RUNTIME_BIN)); \
	arch = $(ARCH); \
	license = MIT; \
PKGINFO; \
	install -m755 packaging/deb/DEBIAN/postinst "$$ROOT/.INSTALL"; \
	cd "$$ROOT" && tar -cJf "$(DIST_DIR)/$(PAC_NAME)" .PKGINFO .INSTALL data/ 2>/dev/null; \
	rm -rf "$$ROOT"; \
	echo "  $(DIST_DIR)/$(PAC_NAME)"

clean:
	@rm -rf $(DIST_DIR) $(RUNTIME_DIR)
	@echo "Clean complete"
