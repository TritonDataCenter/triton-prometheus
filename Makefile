#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

include ./tools/mk/Makefile.defs

SERVICE_NAME = prometheus
RELEASE_TARBALL := $(SERVICE_NAME)-pkg-$(STAMP).tar.bz2
RELSTAGEDIR := /tmp/$(STAMP)
SMF_MANIFESTS = smf/manifests/prometheus.xml


#
# Repo-specific targets
#
.PHONY: all
all: $(PROMETHEUS_EXEC)

$(PROMETHEUS_EXEC):
	XXX

.PHONY: release
release: all deps docs $(SMF_MANIFESTS)
	@echo "Building $(RELEASE_TARBALL)"
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/build
	cp -PR $(NODE_INSTALL) $(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/build/node
	cp -r $(TOP)/lib \
		$(TOP)/server.js \
		$(TOP)/volapi-updater.js \
		$(TOP)/Makefile \
		$(TOP)/node_modules \
		$(TOP)/package.json \
		$(TOP)/sapi_manifests \
		$(TOP)/smf \
		$(TOP)/test \
		$(TOP)/tools \
		$(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/
	mkdir -p $(RELSTAGEDIR)/root/opt/triton/boot
	cp -R $(TOP)/deps/sdc-scripts/* $(RELSTAGEDIR)/root/opt/triton/boot/
	cp -R $(TOP)/boot/* $(RELSTAGEDIR)/root/opt/triton/boot/
	(cd $(RELSTAGEDIR) && $(TAR) -jcf $(TOP)/$(RELEASE_TARBALL) root)
	@rm -rf $(RELSTAGEDIR)


.PHONY: publish
publish: release
	@if [[ -z "$(BITS_DIR)" ]]; then \
		echo "error: 'BITS_DIR' must be set for 'publish' target"; \
		exit 1; \
	fi
	mkdir -p $(BITS_DIR)/$(SERVICE_NAME)
	cp $(TOP)/$(RELEASE_TARBALL) $(BITS_DIR)/$(SERVICE_NAME)/$(RELEASE_TARBALL)

.PHONY: dumpvar
dumpvar:
	@if [[ -z "$(VAR)" ]]; then \
		echo "error: set 'VAR' to dump a var"; \
		exit 1; \
	fi
	@echo "$(VAR) is '$($(VAR))'"

include ./tools/mk/Makefile.deps
include ./tools/mk/Makefile.targ
