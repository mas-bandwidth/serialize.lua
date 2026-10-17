# serialize.lua: the build, the pinned interpreter and the test runner.
# DESIGN.md (i) is the page for this file. A later card adds its own targets in
# its own make/<card>.mk, included below, so no two cards edit this Makefile.

# THE PINNED INTERPRETER: PUC-Rio Lua 5.4.8, built from source into dist/
# (gitignored). The same pin, URL and refusal as mas-bandwidth/schema's
# make/lua.mk, so schema's Lua leg vendors these files against the interpreter
# it already pins. Any other sha256 is refused by name and never built.
LUA_VERSION := 5.4.8
LUA_TARBALL := lua-$(LUA_VERSION).tar.gz
LUA_URL     := https://www.lua.org/ftp/$(LUA_TARBALL)
LUA_SHA256  := 4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
LUA_DIST    := dist/lua-$(LUA_VERSION)
LUA         := $(LUA_DIST)/src/lua

# make test runs every test/*/*_test.lua; make test T=<name> runs the files of
# test/<name>/ only (one directory per card, so no two cards share a test path).
T ?=

RUNNER := build/test_runner.lua

.PHONY: all dist-lua toolchain-lua test
all: test

dist-lua:
	@mkdir -p dist
	@if [ ! -f dist/$(LUA_TARBALL) ]; then curl -fsSL -o dist/$(LUA_TARBALL).part $(LUA_URL) && mv dist/$(LUA_TARBALL).part dist/$(LUA_TARBALL); fi
	@got=$$(sha256sum dist/$(LUA_TARBALL) 2>/dev/null | cut -d" " -f1); \
	if [ -z "$$got" ]; then got=$$(shasum -a 256 dist/$(LUA_TARBALL) | cut -d" " -f1); fi; \
	if [ "$$got" != "$(LUA_SHA256)" ]; then \
		echo "dist-lua REFUSES: dist/$(LUA_TARBALL) has sha256 $$got, the pin is $(LUA_SHA256)"; \
		echo "  delete dist/$(LUA_TARBALL) and run make dist-lua again; a tarball that does not match the pin is never built"; \
		exit 1; fi
	@rm -rf $(LUA_DIST) && tar -xzf dist/$(LUA_TARBALL) -C dist
	$(MAKE) -C $(LUA_DIST) $(if $(filter Darwin,$(shell uname -s)),macosx,$(if $(filter Linux,$(shell uname -s)),linux,posix))
	@echo "dist-lua: Lua $(LUA_VERSION) $(LUA_URL) sha256 $(LUA_SHA256)"
	@echo "dist-lua: $$($(LUA) -v)"

# THE TOOLCHAIN GATE: refuses by name when the pin does not resolve, never a skip.
toolchain-lua:
	@if [ ! -x $(LUA) ]; then \
		echo "toolchain-lua REFUSES: $(LUA) does not resolve; run make dist-lua (Lua $(LUA_VERSION), sha256 $(LUA_SHA256))"; \
		exit 1; fi
	@v=$$($(LUA) -v 2>&1); case "$$v" in "Lua $(LUA_VERSION) "*) ;; *) \
		echo "toolchain-lua REFUSES: $(LUA) reports \"$$v\", the pin is Lua $(LUA_VERSION); run make dist-lua"; \
		exit 1;; esac

# THE RUNNER (DESIGN.md (i)). One pinned interpreter process per test file, run
# from the repository root with -E (LUA_PATH and LUA_INIT are never consulted).
# The runner replaces package.path with ./src/?.lua and empties package.cpath
# (DESIGN.md (f)) before it loads the test file. A test file declares global
# functions named Test<Name>; the runner calls each in declaration order and
# prints RUN Test<Name>, then --- PASS Test<Name> or --- FAIL Test<Name>. A test
# fails by raising. A file that declares no test fails, by name: never a skip.
define TEST_RUNNER
-- generated from the Makefile (TEST_RUNNER); never edit build/test_runner.lua
package.path = "./src/?.lua"
package.cpath = ""
local file = arg[1]
local order, tests = {}, {}
local env = setmetatable({}, {
  __index = _G,
  __newindex = function(t, k, v)
    if type(k) == "string" and k:match("^Test%u") and type(v) == "function" and tests[k] == nil then
      order[#order + 1] = k
      tests[k] = v
    end
    rawset(t, k, v)
  end,
})
local chunk, err = loadfile(file, "t", env)
if not chunk then
  print("--- FAIL " .. file .. ": " .. tostring(err))
  os.exit(1)
end
local ok, loadErr = xpcall(chunk, debug.traceback)
if not ok then
  print("--- FAIL " .. file .. ": loading raised: " .. tostring(loadErr))
  os.exit(1)
end
if #order == 0 then
  print("--- FAIL " .. file .. ": declares no Test<Name> function")
  os.exit(1)
end
local failed = 0
for _, name in ipairs(order) do
  print("RUN " .. name)
  local passed, msg = xpcall(tests[name], debug.traceback)
  if passed then
    print("--- PASS " .. name)
  else
    print(tostring(msg))
    print("--- FAIL " .. name)
    failed = failed + 1
  end
end
os.exit(failed == 0 and 0 or 1)
endef

build:
	@mkdir -p build

# $(file) expands before any recipe line runs, so the directory is an order-only
# prerequisite rather than a line of this recipe.
$(RUNNER): Makefile | build
	$(file >$@,$(TEST_RUNNER))
	@echo "runner: $@ written from the Makefile"

test: toolchain-lua $(RUNNER)
	@if [ -n "$(T)" ]; then \
		if [ ! -d "test/$(T)" ]; then echo "make test REFUSES: test/$(T)/ does not exist"; exit 1; fi; \
		files=$$(ls test/$(T)/*_test.lua 2>/dev/null); \
		if [ -z "$$files" ]; then echo "make test REFUSES: test/$(T)/ holds no *_test.lua"; exit 1; fi; \
	else \
		files=$$(ls test/*/*_test.lua 2>/dev/null); \
		if [ -z "$$files" ]; then echo "make test REFUSES: no test/*/*_test.lua exists"; exit 1; fi; \
	fi; \
	status=0; \
	for f in $$files; do $(LUA) -E $(RUNNER) $$f || status=1; done; \
	if [ $$status -eq 0 ]; then echo "ok   make test$(if $(T), T=$(T))"; else echo "FAIL make test$(if $(T), T=$(T))"; fi; \
	exit $$status

-include make/*.mk
