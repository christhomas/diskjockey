# DiskJockey's tasks now live in chores.yml, run with `chore`.
#
# This file is a shim so anything that still says `make` keeps working —
# CI, muscle memory, a bookmark in someone's notes. Every target below
# forwards to its chore task and nothing else. The real definitions, with
# their arguments and their documentation, are in chores.yml.
#
#   make vendor-fs-ext4-force   ->  chore vendor ext4 --force
#   make dev-link FS=ext4       ->  chore dev:link ext4
#
# Delete this file once nothing calls it. `chore --list` is the index.

# Must agree with FS_DRIVERS in chores.yml, which is the list that matters —
# this one only decides which `make vendor-fs-<x>` shims get generated. It was
# four when chores.yml already had six; xfs and btrfs had no shim at all.
FS_DRIVERS := ext4 ntfs squashfs erofs xfs btrfs

CHORE := chore

# A missing `chore` should say so plainly rather than fail as a shell error
# in the middle of a target someone is waiting on.
check-chore:
	@command -v $(CHORE) >/dev/null || { \
		echo 'chore is not installed. See https://github.com/antimatter-studios/chore'; \
		echo '  brew install antimatter-studios/tap/chore'; \
		exit 127; }

.PHONY: check-chore all proto proto-fileprovider clean clean-all vendor-all vendor-bundles vendor-bundles-clean vendor-img-containers vendor-img-containers-clean vendor-gonetworkfs vendor-gonetworkfs-clean install-agent installable pins pins-check vendor-img-containers-force vendor-gonetworkfs-force vendor-gonetworkfs-add installable-install dev-link dev-unlink vendor-fs-ext4 vendor-fs-ext4-force vendor-fs-ext4-clean vendor-fs-ntfs vendor-fs-ntfs-force vendor-fs-ntfs-clean vendor-fs-squashfs vendor-fs-squashfs-force vendor-fs-squashfs-clean vendor-fs-erofs vendor-fs-erofs-force vendor-fs-erofs-clean

all: check-chore
	@$(CHORE) build

proto: check-chore
	@$(CHORE) proto

proto-fileprovider: check-chore
	@$(CHORE) proto

clean: check-chore
	@$(CHORE) clean

clean-all: check-chore
	@$(CHORE) clean:all

vendor-all: check-chore
	@$(CHORE) vendor:all

vendor-bundles: check-chore
	@$(CHORE) bundles

vendor-bundles-clean: check-chore
	@$(CHORE) bundles:clean

vendor-img-containers: check-chore
	@$(CHORE) img

vendor-img-containers-clean: check-chore
	@$(CHORE) img:clean

vendor-gonetworkfs: check-chore
	@$(CHORE) gonetworkfs

vendor-gonetworkfs-clean: check-chore
	@$(CHORE) gonetworkfs:clean

install-agent: check-chore
	@$(CHORE) agent:install

installable: check-chore
	@$(CHORE) installable

pins: check-chore
	@$(CHORE) pins

pins-check: check-chore
	@$(CHORE) pins:check

# --force GOES BEFORE THE TASK NAME. It is a chore flag, not a task argument,
# and the tasks no longer declare one of their own: chore binds a trailing
# `--word` to a declared parameter and REFUSES it otherwise, so
# `chore img --force` fails with "task img takes no arguments, got 1".
# Measured on chore 0.6.0, 2026-08-27 — every `-force` target here was broken
# by the move to `includes:` and this is the fix.
vendor-img-containers-force: check-chore
	@$(CHORE) --force img

vendor-gonetworkfs-force: check-chore
	@$(CHORE) --force gonetworkfs

installable-install: check-chore
	@$(CHORE) installable --install

# DRIVER= became --extra: the driver list moved into go-networkfs's own
# chores.yml, so what this passes is an ADDITION to that list rather than a
# selection from one this file holds.
vendor-gonetworkfs-add: check-chore
	@test -n "$(DRIVER)" || { echo 'usage: make vendor-gonetworkfs-add DRIVER=<name>'; exit 2; }
	@$(CHORE) gonetworkfs --extra $(DRIVER)

dev-link: check-chore
	@test -n "$(FS)" || { echo 'usage: make dev-link FS=<ext4|ntfs|erofs|squashfs|xfs|btrfs> [EXTRA=am-img-qcow2]'; exit 2; }
	@$(CHORE) dev:link $(FS) $(if $(EXTRA),--extra $(EXTRA),)

dev-unlink: check-chore
	@test -n "$(FS)" || { echo 'usage: make dev-unlink FS=<ext4|ntfs|erofs|squashfs|xfs|btrfs>'; exit 2; }
	@$(CHORE) dev:unlink $(FS)

# One block per driver, generated: the shim should not reintroduce the
# repetition the move was made to remove.
define fs_shim
vendor-fs-$(1): check-chore
	@$$(CHORE) vendor $(1)
vendor-fs-$(1)-force: check-chore
	@$$(CHORE) --force vendor $(1)
vendor-fs-$(1)-clean: check-chore
	@$$(CHORE) vendor:clean $(1)
endef
$(foreach fs,$(FS_DRIVERS),$(eval $(call fs_shim,$(fs))))
