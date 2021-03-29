#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2021 Joyent, Inc.
#

NAME = prometheus

GO_PREBUILT_VERSION = 1.16.2
GOOS = illumos
NODE_PREBUILT_VERSION = v6.17.0
ifeq ($(shell uname -s),SunOS)
    NODE_PREBUILT_TAG=zone64
    NODE_PREBUILT_IMAGE=c2c31b00-1d60-11e9-9a77-ff9f06554b0f
endif

ENGBLD_USE_BUILDIMAGE = true
ENGBLD_REQUIRE := $(shell git submodule update --init deps/eng)
include ./deps/eng/tools/mk/Makefile.defs
TOP ?= $(error Unable to access eng.git submodule Makefiles.)

include ./deps/eng/tools/mk/Makefile.smf.defs
ifeq ($(shell uname -s),SunOS)
    include ./deps/eng/tools/mk/Makefile.go_prebuilt.defs
    include ./deps/eng/tools/mk/Makefile.node_prebuilt.defs
    include ./deps/eng/tools/mk/Makefile.agent_prebuilt.defs
endif

# triton-origin-x86_64-18.4.0
BASE_IMAGE_UUID = a9368831-958e-432d-a031-f8ce6768d190
BUILDIMAGE_NAME = mantav2-$(NAME)
BUILDIMAGE_PKGSRC = bind-9.11.22 yarn-1.12.3

BUILDIMAGE_DESC = Triton/Manta Prometheus
AGENTS = amon config registrar

RELEASE_TARBALL := $(NAME)-pkg-$(STAMP).tar.gz
RELSTAGEDIR := /tmp/$(NAME)-$(STAMP)

SMF_MANIFESTS = smf/manifests/prometheus.xml

JS_FILES := $(TOP)/bin/certgen
ESLINT_FILES := $(JS_FILES)
BASH_FILES := $(wildcard boot/*.sh) $(TOP)/bin/prometheus-configure

STAMP_CERTGEN := $(MAKE_STAMPS_DIR)/certgen

PROMETHEUS_IMPORT = github.com/prometheus/prometheus
PROMETHEUS_GO_DIR = $(GO_GOPATH)/src/$(PROMETHEUS_IMPORT)
PROMETHEUS_EXEC = $(PROMETHEUS_GO_DIR)/prometheus

#
# Repo-specific targets
#
.PHONY: all
all: $(PROMETHEUS_EXEC) $(STAMP_CERTGEN) sdc-scripts manta-scripts

#
# Link the "prometheus" submodule into the correct place within our
# project-local GOPATH, then build the binary.
#
$(PROMETHEUS_EXEC): deps/prometheus/.git $(STAMP_GO_TOOLCHAIN)
	$(GO) version
	mkdir -p $(dir $(PROMETHEUS_GO_DIR))
	rm -f $(PROMETHEUS_GO_DIR)
	ln -s $(TOP)/deps/prometheus $(PROMETHEUS_GO_DIR)
	(cd $(PROMETHEUS_GO_DIR) && env -i $(GO_ENV) make build)

$(STAMP_CERTGEN): | $(NODE_EXEC) $(NPM_EXEC)
	$(MAKE_STAMP_REMOVE)
	rm -rf $(TOP)/node_modules && cd $(TOP) && $(NPM) install --production
	$(MAKE_STAMP_CREATE)

sdc-scripts: deps/sdc-scripts/.git
manta-scripts: deps/manta-scripts/.git

.PHONY: clean
clean::
	# Clean certgen
	rm -rf $(TOP)/node_modules
	rm -rf $(PROMETHEUS_EXEC)

.PHONY: release
release: all docs $(SMF_MANIFESTS)
	@echo "Building $(RELEASE_TARBALL)"
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)
	cp -r \
		$(TOP)/bin \
		$(TOP)/etc \
		$(TOP)/package.json \
		$(TOP)/node_modules \
		$(TOP)/smf \
		$(TOP)/sapi_manifests \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/
	# our prometheus build
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)/prometheus
	cp -r \
		$(PROMETHEUS_GO_DIR)/prometheus \
		$(PROMETHEUS_GO_DIR)/promtool \
		$(PROMETHEUS_GO_DIR)/consoles \
		$(PROMETHEUS_GO_DIR)/console_libraries \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/prometheus/
	# our node version
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)/build
	cp -r \
		$(TOP)/build/node \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/build/
	# zone boot
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot
	cp -r $(TOP)/deps/sdc-scripts/{etc,lib,sbin,smf} \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	cp -r $(TOP)/boot/* \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot/manta-scripts
	cp -r $(TOP)/deps/manta-scripts/*.sh \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/manta-scripts
	# tar it up
	(cd $(RELSTAGEDIR) && $(TAR) -I pigz -cf $(TOP)/$(RELEASE_TARBALL) root)
	@rm -rf $(RELSTAGEDIR)

.PHONY: publish
publish: release
	mkdir -p $(ENGBLD_BITS_DIR)/$(NAME)
	cp $(TOP)/$(RELEASE_TARBALL) \
		$(ENGBLD_BITS_DIR)/$(NAME)/$(RELEASE_TARBALL)

include ./deps/eng/tools/mk/Makefile.deps
ifeq ($(shell uname -s),SunOS)
    include ./deps/eng/tools/mk/Makefile.go_prebuilt.targ
    include ./deps/eng/tools/mk/Makefile.node_prebuilt.targ
    include ./deps/eng/tools/mk/Makefile.agent_prebuilt.targ
endif
include ./deps/eng/tools/mk/Makefile.smf.targ
include ./deps/eng/tools/mk/Makefile.targ
