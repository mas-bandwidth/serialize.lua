# The static lens (luacheck). Included by the design Makefile; no card edits the
# Makefile itself (DESIGN.md (h), "Tests": targets go in make/<card>.mk).
#
# THE PINNED LINTER: luacheck 1.2.0 and its two dependencies, argparse 0.7.2
# and LuaFileSystem 1.9.0, fetched as source tarballs into dist/ (gitignored),
# each refused by name unless its sha256 matches the pin, as make dist-lua
# refuses the interpreter. luacheck runs on the pinned Lua 5.4.8 with -E (no
# LUA_PATH, no LUA_INIT); lfs, its one C module, is compiled against the pinned
# interpreter's headers with warnings as errors.
#
#   make dist-luacheck   fetch, verify and build the linter
#   make lint            luacheck over src/, test/ and fuzz/driver.lua with
#                        .luacheckrc; any warning is red (luacheck exits 1)
LUACHECK_VERSION := 1.2.0
LUACHECK_TARBALL := luacheck-$(LUACHECK_VERSION).tar.gz
LUACHECK_URL     := https://github.com/lunarmodules/luacheck/archive/refs/tags/v$(LUACHECK_VERSION).tar.gz
LUACHECK_SHA256  := 8efe62a7da4fdb32c0c22ec1f7c9306cbc397d7d40493c29988221a059636e25

ARGPARSE_VERSION := 0.7.2
ARGPARSE_TARBALL := argparse-$(ARGPARSE_VERSION).tar.gz
ARGPARSE_URL     := https://github.com/luarocks/argparse/archive/refs/tags/$(ARGPARSE_VERSION).tar.gz
ARGPARSE_SHA256  := d2ae8066939420957bb6d580c6a6b8176c4f05419eca318e48d90a670fe2f59e

LFS_TAG     := 1_9_0
LFS_TARBALL := luafilesystem-$(LFS_TAG).tar.gz
LFS_URL     := https://github.com/lunarmodules/luafilesystem/archive/refs/tags/v$(LFS_TAG).tar.gz
LFS_SHA256  := 1142c1876e999b3e28d1c236bf21ffd9b023018e336ac25120fb5373aade1450

LINT_DIST := dist/lint
LFS_SO    := $(LINT_DIST)/lib/lfs.so
LFS_LINK  := $(if $(filter Darwin,$(shell uname -s)),-bundle -undefined dynamic_lookup,-shared)

LUACHECK_PATH  := $(LINT_DIST)/luacheck-$(LUACHECK_VERSION)/src/?.lua;$(LINT_DIST)/luacheck-$(LUACHECK_VERSION)/src/?/init.lua;$(LINT_DIST)/argparse-$(ARGPARSE_VERSION)/src/?.lua
LUACHECK       := $(LUA) -E -e "package.path='$(LUACHECK_PATH)' package.cpath='$(LINT_DIST)/lib/?.so'" $(LINT_DIST)/luacheck-$(LUACHECK_VERSION)/bin/luacheck.lua
LINT_FILES     := src test fuzz/driver.lua

# lint-fetch <tarball> <url> <sha256>: download into dist/ once, then refuse any
# file whose sha256 is not the pin; a tarball that does not match is never used.
define lint-fetch
	@mkdir -p dist
	@if [ ! -f dist/$(1) ]; then curl -fsSL -o dist/$(1).part $(2) && mv dist/$(1).part dist/$(1); fi
	@got=$$(sha256sum dist/$(1) 2>/dev/null | cut -d" " -f1); \
	if [ -z "$$got" ]; then got=$$(shasum -a 256 dist/$(1) | cut -d" " -f1); fi; \
	if [ "$$got" != "$(3)" ]; then \
		echo "dist-luacheck REFUSES: dist/$(1) has sha256 $$got, the pin is $(3)"; \
		echo "  delete dist/$(1) and run make dist-luacheck again; a tarball that does not match the pin is never used"; \
		exit 1; fi
	@tar -xzf dist/$(1) -C $(LINT_DIST)
endef

.PHONY: dist-luacheck toolchain-luacheck lint
dist-luacheck: toolchain-lua
	@rm -rf $(LINT_DIST) && mkdir -p $(LINT_DIST)/lib
	$(call lint-fetch,$(LUACHECK_TARBALL),$(LUACHECK_URL),$(LUACHECK_SHA256))
	$(call lint-fetch,$(ARGPARSE_TARBALL),$(ARGPARSE_URL),$(ARGPARSE_SHA256))
	$(call lint-fetch,$(LFS_TARBALL),$(LFS_URL),$(LFS_SHA256))
	$(CC) -O2 -fPIC -Wall -Wextra -Werror -I$(LUA_DIST)/src $(LFS_LINK) -o $(LFS_SO) $(LINT_DIST)/luafilesystem-$(LFS_TAG)/src/lfs.c
	@echo "dist-luacheck: luacheck $(LUACHECK_VERSION) sha256 $(LUACHECK_SHA256)"
	@echo "dist-luacheck: argparse $(ARGPARSE_VERSION) sha256 $(ARGPARSE_SHA256), luafilesystem $(LFS_TAG) sha256 $(LFS_SHA256)"
	@echo "dist-luacheck: $$($(LUACHECK) --version | head -n1)"

# THE TOOLCHAIN GATE: refuses by name when the pin does not resolve, never a skip.
toolchain-luacheck: toolchain-lua
	@if [ ! -f $(LFS_SO) ] || [ ! -f $(LINT_DIST)/luacheck-$(LUACHECK_VERSION)/bin/luacheck.lua ]; then \
		echo "toolchain-luacheck REFUSES: luacheck $(LUACHECK_VERSION) is not built under $(LINT_DIST); run make dist-luacheck"; \
		exit 1; fi

lint: toolchain-luacheck
	$(LUACHECK) --config .luacheckrc --no-cache --codes --formatter plain $(LINT_FILES)
	@echo "ok   make lint (luacheck $(LUACHECK_VERSION), zero warnings)"

# THE NEGATIVE CONTROL: the same luacheck and .luacheckrc over a scratch copy of
# src/serialize_bits.lua with an unused local and a stray global planted at its top.
# It must go red with both W211 and W111 named; a lint that passes it is blind.
LINT_NEG_DIR := build/lint-neg
.PHONY: lint-neg
lint-neg: toolchain-luacheck
	@rm -rf $(LINT_NEG_DIR) && mkdir -p $(LINT_NEG_DIR)
	@{ printf '%s\n' 'local function plantedUnused() local planted = 1 end' 'plantedGlobal = plantedUnused'; \
		cat src/serialize_bits.lua; } > $(LINT_NEG_DIR)/serialize_bits.lua
	@if $(LUACHECK) --config .luacheckrc --no-cache --codes --formatter plain $(LINT_NEG_DIR)/serialize_bits.lua > $(LINT_NEG_DIR)/out.txt 2>&1; then \
		cat $(LINT_NEG_DIR)/out.txt; echo "lint-neg FAIL: luacheck passed a file with a planted unused variable and global"; exit 1; fi
	@cat $(LINT_NEG_DIR)/out.txt
	@grep -q '(W211)' $(LINT_NEG_DIR)/out.txt || { echo "lint-neg FAIL: the planted unused variable (W211) was not named"; exit 1; }
	@grep -q '(W111)' $(LINT_NEG_DIR)/out.txt || { echo "lint-neg FAIL: the planted global (W111) was not named"; exit 1; }
	@echo "ok   make lint-neg: the planted unused variable and global were refused, as required"
