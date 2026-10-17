# The CI gate (serialize-lua-ci card). Included by the design Makefile; no card
# edits the Makefile itself (DESIGN.md (h), "Tests": targets go in make/<card>.mk).
.PHONY: check-ci
check-ci:
	@tools/checkci/check-ci.sh .github/workflows/ci.yml
