# Copyright (c) 2021 Cisco and/or its affiliates.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export WS_ROOT=$(CURDIR)
export BR=$(WS_ROOT)/build-root
CCACHE_DIR?=$(BR)/.ccache
SHELL:=$(shell which bash)
GDB?=gdb
PLATFORM?=vpp
SAMPLE_PLUGIN?=no
STARTUP_DIR?=$(PWD)
MACHINE=$(shell uname -m)
SUDO?=sudo -E
DPDK_CONFIG?=no-pci

# we prefer clang by default
ifeq ($(CC),cc)
  CC=clang
endif

ifeq ($(strip $(SHELL)),)
$(error "bash not found, VPP requires bash to build")
endif

,:=,
define disable_plugins
$(if $(1), \
  "plugins {" \
  $(patsubst %,"plugin %_plugin.so { disable }",$(subst $(,), ,$(1))) \
  " }" \
  ,)
endef

MINIMAL_STARTUP_CONF="							\
unix { 									\
	interactive 							\
	cli-listen /run/vpp/cli.sock					\
	gid $(shell id -g)						\
	$(if $(wildcard startup.vpp),"exec startup.vpp",)		\
}									\
$(if $(DPDK_CONFIG), "dpdk { $(DPDK_CONFIG) }",)			\
$(if $(EXTRA_VPP_CONFIG), "$(EXTRA_VPP_CONFIG)",)			\
$(call disable_plugins,$(DISABLED_PLUGINS))				\
"

GDB_ARGS= -ex "handle SIGUSR1 noprint nostop"

#
# OS Detection
#
# We allow Darwin (MacOS) for docs generation; VPP build will still fail.
ifneq ($(shell uname),Darwin)
OS_ID        = $(shell grep '^ID=' /etc/os-release | cut -f2- -d= | sed -e 's/\"//g')
OS_VERSION_ID= $(shell grep '^VERSION_ID=' /etc/os-release | cut -f2- -d= | sed -e 's/\"//g')
OS_CODENAME  = $(shell grep '^VERSION_CODENAME=' /etc/os-release | cut -f2- -d= | sed -e 's/\"//g')
endif

# Fill in OS_VERSION_ID based on codename if its absent
ifeq ($(OS_VERSION_ID),)
# Debian testing doesn't define version_id and therefore need to be referenced by name
ifeq ($(OS_CODENAME),trixie)
OS_VERSION_ID = 13
endif
endif

ifeq ($(filter elxr ubuntu debian linuxmint,$(OS_ID)),$(OS_ID))
PKG=deb
else ifeq ($(filter rhel centos fedora opensuse-leap rocky almalinux anolis,$(OS_ID)),$(OS_ID))
PKG=rpm
else ifeq ($(filter freebsd,$(OS_ID)),$(OS_ID))
PKG=pkg
endif

ifeq ($(filter anolis,$(OS_ID)),$(OS_ID))
OS_VERSION_ID= $(shell grep '^VERSION_ID=' /etc/os-release | cut -f2 -d= | sed -e 's/\"//g' | cut -d. -f1)
endif

# +libganglia1-dev if building the gmond plugin

DEB_DEPENDS  = curl build-essential ccache
DEB_DEPENDS += debhelper git dh-python
DEB_DEPENDS += git-review exuberant-ctags cscope
DEB_DEPENDS += clang gcovr lcov chrpath
DEB_DEPENDS += python3-all python3-setuptools check
DEB_DEPENDS += python3-ply libunwind-dev
DEB_DEPENDS += cmake ninja-build python3-jsonschema python3-yaml
DEB_DEPENDS += python3-venv  # ensurepip
DEB_DEPENDS += python3-dev python3-pip
DEB_DEPENDS += libnl-3-dev libnl-route-3-dev libmnl-dev
# DEB_DEPENDS += enchant  # for docs
DEB_DEPENDS += python3-virtualenv
DEB_DEPENDS += libssl-dev
DEB_DEPENDS += libelf-dev libpcap-dev # for libxdp (af_xdp)
DEB_DEPENDS += iperf3 # for 'make test TEST=vcl'
DEB_DEPENDS += iperf ethtool  # for 'make test TEST=vm_vpp_interfaces'
DEB_DEPENDS += libpcap-dev
DEB_DEPENDS += tshark
DEB_DEPENDS += jq # for extracting test summary from .json report (hs-test)
DEB_DEPENDS += libiberty-dev
DEB_DEPENDS += nasm libnuma-dev # for make-ext-deps

LIBFFI=libffi6 # works on all but 20.04 and debian-testing
ifeq ($(OS_VERSION_ID),24.04)
	DEB_DEPENDS += libssl-dev
	DEB_DEPENDS += llvm clang clang-format-15
	# overwrite clang-format version to run `make checkstyle` successfully
	# TODO: remove once ubuntu 20.04 is deprecated and extras/scripts/checkstyle.sh is upgraded to 15
	export CLANG_FORMAT_VER=15
	LIBFFI=libffi8
	DEB_DEPENDS += enchant-2  # for docs
else ifeq ($(OS_VERSION_ID),22.04)
	DEB_DEPENDS += python3-virtualenv
	DEB_DEPENDS += libssl-dev
	DEB_DEPENDS += clang clang-format-15
	# overwrite clang-format version to run `make checkstyle` successfully
	# TODO: remove once ubuntu 20.04 is deprecated and extras/scripts/checkstyle.sh is upgraded to 15
	export CLANG_FORMAT_VER=15
	DEB_DEPENDS += enchant-2  # for docs
else ifeq ($(OS_VERSION_ID),20.04)
	DEB_DEPENDS += python3-virtualenv
	DEB_DEPENDS += libssl-dev
	DEB_DEPENDS += clang clang-format-11
	DEB_DEPENDS += enchant-2  # for docs
else ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-10)
	DEB_DEPENDS += virtualenv
else ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-11)
	DEB_DEPENDS += virtualenv
	DEB_DEPENDS += clang clang-format-11
else ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-12)
	DEB_DEPENDS += virtualenv
	DEB_DEPENDS += clang-14 clang-format-15
	# for extras/scripts/checkstyle.sh
	# TODO: remove once ubuntu 20.04 is deprecated and extras/scripts/checkstyle.sh is upgraded to -15
	export CLANG_FORMAT_VER=15
else ifeq ($(OS_ID)-$(OS_VERSION_ID),debian-13)
	DEB_DEPENDS += virtualenv
	DEB_DEPENDS += clang-19 clang-format-19
	# for extras/scripts/checkstyle.sh
	# TODO: remove once ubuntu 20.04 is deprecated and extras/scripts/checkstyle.sh is upgraded to -15
	export CLANG_FORMAT_VER=15
else ifeq ($(OS_ID)-$(OS_VERSION_ID),elxr-12)
	DEB_DEPENDS += virtualenv
	DEB_DEPENDS += clang-14 clang-format-15
	export CLANG_FORMAT_VER=15
else
	DEB_DEPENDS += clang-11 clang-format-11
	DEB_DEPENDS += enchant-2  # for docs
endif

RPM_DEPENDS  = glibc-static
RPM_DEPENDS += apr-devel
RPM_DEPENDS += numactl-devel
RPM_DEPENDS += check check-devel
RPM_DEPENDS += selinux-policy selinux-policy-devel
RPM_DEPENDS += ninja-build
RPM_DEPENDS += ccache
RPM_DEPENDS += xmlto
RPM_DEPENDS += elfutils-libelf-devel libpcap-devel
RPM_DEPENDS += libnl3-devel libmnl-devel
RPM_DEPENDS += nasm
RPM_DEPENDS += socat

ifeq ($(OS_ID),fedora)
	RPM_DEPENDS += dnf-utils
	RPM_DEPENDS += subunit subunit-devel
	RPM_DEPENDS += compat-openssl10-devel
	RPM_DEPENDS += python3-devel  # needed for python3 -m pip install psutil
	RPM_DEPENDS += python3-ply  # for vppapigen
	RPM_DEPENDS += python3-virtualenv python3-jsonschema
	RPM_DEPENDS += cmake
	RPM_DEPENDS_GROUPS = 'C Development Tools and Libraries'
else ifeq ($(OS_ID),rocky)
	RPM_DEPENDS += yum-utils
	RPM_DEPENDS += subunit subunit-devel
	RPM_DEPENDS += openssl-devel
	RPM_DEPENDS += python3-devel  # needed for python3 -m pip install psutil
	RPM_DEPENDS += python3-ply  # for vppapigen
	RPM_DEPENDS += python3-virtualenv python3-jsonschema
	RPM_DEPENDS += infiniband-diags llvm clang cmake
	RPM_DEPENDS_GROUPS = 'Development Tools'
else ifeq ($(OS_ID),almalinux)
	RPM_DEPENDS += yum-utils
	RPM_DEPENDS += subunit subunit-devel
	RPM_DEPENDS += openssl-devel
	RPM_DEPENDS += python3-devel  # needed for python3 -m pip install psutil
	RPM_DEPENDS += python3-ply  # for vppapigen
	RPM_DEPENDS += python3-virtualenv python3-jsonschema
	RPM_DEPENDS += infiniband-diags llvm clang cmake
	RPM_DEPENDS_GROUPS = 'Development Tools'
else ifeq ($(OS_ID)-$(OS_VERSION_ID),centos-8)
	RPM_DEPENDS += yum-utils
	RPM_DEPENDS += compat-openssl10 openssl-devel
	RPM_DEPENDS += python2-devel python36-devel python3-ply
	RPM_DEPENDS += python3-virtualenv python3-jsonschema
	RPM_DEPENDS += libarchive cmake
	RPM_DEPENDS += infiniband-diags libibumad
	RPM_DEPENDS += libpcap-devel llvm-toolset
	RPM_DEPENDS_GROUPS = 'Development Tools'
else ifeq ($(OS_ID)-$(OS_VERSION_ID),anolis-8)
	RPM_DEPENDS += yum-utils
	RPM_DEPENDS += compat-openssl10 openssl-devel
	RPM_DEPENDS += python2-devel python36-devel python3-ply
	RPM_DEPENDS += python3-virtualenv python3-jsonschema
	RPM_DEPENDS += libarchive cmake
	RPM_DEPENDS += libpcap-devel llvm-toolset git-clang-format python3-pyyaml
	RPM_DEPENDS_GROUPS = 'Development Tools'
	export CLANG_FORMAT_VER=15
else
	RPM_DEPENDS += yum-utils
	RPM_DEPENDS += openssl-devel
	RPM_DEPENDS += python36-ply  # for vppapigen
	RPM_DEPENDS += python3-devel python3-pip
	RPM_DEPENDS += python-virtualenv python36-jsonschema
	RPM_DEPENDS += devtoolset-9 devtoolset-9-libasan-devel
	RPM_DEPENDS += cmake3
	RPM_DEPENDS_GROUPS = 'Development Tools'
endif

# +ganglia-devel if building the ganglia plugin

RPM_DEPENDS += chrpath libffi-devel rpm-build

RPM_DEPENDS_DEBUG  = glibc-debuginfo e2fsprogs-debuginfo
RPM_DEPENDS_DEBUG += krb5-debuginfo openssl-debuginfo
RPM_DEPENDS_DEBUG += zlib-debuginfo nss-softokn-debuginfo
RPM_DEPENDS_DEBUG += yum-plugin-auto-update-debug-info

RPM_SUSE_BUILDTOOLS_DEPS = autoconf automake ccache check-devel chrpath
RPM_SUSE_BUILDTOOLS_DEPS += clang cmake indent libtool make ninja python3-ply

RPM_SUSE_DEVEL_DEPS = glibc-devel-static libnuma-devel libelf-devel
RPM_SUSE_DEVEL_DEPS += libopenssl-devel lsb-release
RPM_SUSE_DEVEL_DEPS += libpcap-devel llvm-devel
RPM_SUSE_DEVEL_DEPS += curl libstdc++-devel bison gcc-c++ zlib-devel

RPM_SUSE_PYTHON_DEPS = python3-devel python3-pip python3-rpm-macros

RPM_SUSE_PLATFORM_DEPS = shadow rpm-build

ifeq ($(OS_ID),opensuse-leap)
	RPM_SUSE_DEVEL_DEPS += xmlto openssl-devel asciidoc git nasm
	RPM_SUSE_PYTHON_DEPS += python3 python3-ply python3-virtualenv
	RPM_SUSE_PLATFORM_DEPS += distribution-release
endif

RPM_SUSE_DEPENDS += $(RPM_SUSE_BUILDTOOLS_DEPS) $(RPM_SUSE_DEVEL_DEPS) $(RPM_SUSE_PYTHON_DEPS) $(RPM_SUSE_PLATFORM_DEPS)

# FreeBSD build and test dependancies

FBSD_PY_PRE=py311

FBSD_TEST_DEPS = setsid rust $(FBSD_PY_PRE)-pyshark
FBSD_PYTHON_DEPS = python3 $(FBSD_PY_PRE)-pyelftools $(FBSD_PY_PRE)-ply
FBSD_DEVEL_DEPS = cscope gdb
FBSD_BUILD_DEPS = bash gmake sudo
FBSD_BUILD_DEPS += git sudo autoconf automake curl gsed
FBSD_BUILD_DEPS += pkgconf ninja cmake libepoll-shim jansson
FBSD_DEPS = $(FBSD_BUILD_DEPS) $(FBSD_PYTHON_DEPS) $(FBSD_TEST_DEPS) $(FBSD_DEVEL_DEPS)

ifneq ($(wildcard $(STARTUP_DIR)/startup.conf),)
        STARTUP_CONF ?= $(STARTUP_DIR)/startup.conf
endif

ifeq ($(findstring y,$(UNATTENDED)),y)
DEBIAN_FRONTEND=noninteractive
CONFIRM=-y
FORCE=--allow-downgrades --allow-remove-essential --allow-change-held-packages
endif

TARGETS = vpp

ifneq ($(SAMPLE_PLUGIN),no)
TARGETS += sample-plugin
endif

define banner
	@echo "========================================================================"
	@echo " $(1)"
	@echo "========================================================================"
	@echo " "
endef

.PHONY: help
help:
	@echo "Make Targets:"
	@echo " install-dep[s]       - install software dependencies"
	@echo " wipe                 - wipe all products of debug build "
	@echo " wipe-release         - wipe all products of release build "
	@echo " build                - build debug binaries"
	@echo " build-release        - build release binaries"
	@echo " build-coverity       - build coverity artifacts"
	@echo " build-gcov 		 - build gcov vpp only"
	@echo " rebuild              - wipe and build debug binaries"
	@echo " rebuild-release      - wipe and build release binaries"
	@echo " run                  - run debug binary"
	@echo " run-release          - run release binary"
	@echo " debug                - run debug binary with debugger"
	@echo " debug-release        - run release binary with debugger"
	@echo " test                 - build and run tests"
	@echo " test-cov-hs   		 - build and run host stack tests with coverage"
	@echo " test-cov-both	  	 - build and run python and host stack tests, merge coverage data"
	@echo " test-help            - show help on test framework"
	@echo " run-vat              - run vpp-api-test tool"
	@echo " pkg-deb              - build DEB packages"
	@echo " pkg-deb-debug        - build DEB debug packages"
	@echo " pkg-snap             - build SNAP package"
	@echo " snap-clean           - clean up snap build environment"
	@echo " pkg-rpm              - build RPM packages"
	@echo " install-ext-dep[s]   - install external development dependencies"
	@echo " install-opt-deps     - install optional dependencies"
	@echo " ctags                - (re)generate ctags database"
	@echo " etags                - (re)generate etags database"
	@echo " gtags                - (re)generate gtags database"
	@echo " cscope               - (re)generate cscope database"
	@echo " compdb               - (re)generate compile_commands.json"
	@echo " checkstyle           - check coding style"
	@echo " checkstyle-commit    - check commit message format"
	@echo " checkstyle-python    - check python coding style using 'black' formatter"
	@echo " checkstyle-api       - check api for incompatible changes"
	@echo " checkstyle-go        - check style of .go source files"
	@echo " fixstyle             - fix coding style"
	@echo " fixstyle-python      - fix python coding style using 'black' formatter"
	@echo " fixstyle-go          - format .go source files"
	@echo " doxygen              - DEPRECATED - use 'make docs'"
	@echo " bootstrap-doxygen    - DEPRECATED"
	@echo " wipe-doxygen         - DEPRECATED"
	@echo " checkfeaturelist     - check FEATURE.yaml according to schema"
	@echo " featurelist          - dump feature list in markdown"
	@echo " json-api-files       - (re)-generate json api files"
	@echo " json-api-files-debug - (re)-generate json api files for debug target"
	@echo " go-api-files         - (re)-generate golang api files"
	@echo " cleanup-hst          - stops and removes all docker contaiers and namespaces"
	@echo " docs                 - Build the Sphinx documentation"
	@echo " docs-venv            - Build the virtual environment for the Sphinx docs"
	@echo " docs-clean           - Remove the generated files from the Sphinx docs"
	@echo " docs-rebuild         - Rebuild all of the Sphinx documentation"
	@echo ""
	@echo "Make Arguments:"
	@echo " V=[0|1]                  - set build verbosity level"
	@echo " STARTUP_CONF=<path>      - startup configuration file"
	@echo "                            (e.g. /etc/vpp/startup.conf)"
	@echo " STARTUP_DIR=<path>       - startup directory (e.g. /etc/vpp)"
	@echo "                            It also sets STARTUP_CONF if"
	@echo "                            startup.conf file is present"
	@echo " GDB=<path>               - gdb binary to use for debugging"
	@echo " PLATFORM=<name>          - target platform. default is vpp"
	@echo " DPDK_CONFIG=<conf>       - add specified dpdk config commands to"
	@echo "                            autogenerated startup.conf"
	@echo "                            (e.g. \"no-pci\" )"
	@echo " SAMPLE_PLUGIN=yes        - in addition build/run/debug sample plugin"
	@echo " DISABLED_PLUGINS=<list>  - comma separated list of plugins which"
	@echo "                            should not be loaded"
	@echo ""
	@echo "Current Argument Values:"
	@echo " V                 = $(V)"
	@echo " STARTUP_CONF      = $(STARTUP_CONF)"
	@echo " STARTUP_DIR       = $(STARTUP_DIR)"
	@echo " GDB               = $(GDB)"
	@echo " PLATFORM          = $(PLATFORM)"
	@echo " DPDK_VERSION      = $(DPDK_VERSION)"
	@echo " DPDK_CONFIG       = $(DPDK_CONFIG)"
	@echo " SAMPLE_PLUGIN     = $(SAMPLE_PLUGIN)"
	@echo " DISABLED_PLUGINS  = $(DISABLED_PLUGINS)"

$(BR)/.deps.ok:
ifeq ($(findstring y,$(UNATTENDED)),y)
	$(MAKE) install-dep
endif
ifeq ($(filter elxr ubuntu debian linuxmint,$(OS_ID)),$(OS_ID))
	@MISSING=$$(apt-get install -y -qq -s $(DEB_DEPENDS) | grep "^Inst ") ; \
	if [ -n "$$MISSING" ] ; then \
	  echo "\nPlease install missing packages: \n$$MISSING\n" ; \
	  echo "by executing \"make install-dep\"\n" ; \
	  exit 1 ; \
	fi ; \
	exit 0
else ifneq ("$(wildcard /etc/redhat-release)","")
	@for i in $(RPM_DEPENDS) ; do \
	    RPM=$$(basename -s .rpm "$${i##*/}" | cut -d- -f1,2,3,4)  ;	\
	    MISSING+=$$(rpm -q $$RPM | grep "^package")	   ;    \
	done							   ;	\
	if [ -n "$$MISSING" ] ; then \
	  echo "Please install missing RPMs: \n$$MISSING\n" ; \
	  echo "by executing \"make install-dep\"\n" ; \
	  exit 1 ; \
	fi ; \
	exit 0
endif
	@touch $@

.PHONY: bootstrap
bootstrap:
	@echo "'make bootstrap' is not needed anymore"

.PHONY: install-dep
install-dep:
ifeq ($(filter elxr ubuntu debian linuxmint,$(OS_ID)),$(OS_ID))
	@sudo -E apt-get update
	@sudo -E apt-get $(APT_ARGS) $(CONFIRM) $(FORCE) install $(DEB_DEPENDS)
else ifneq ("$(wildcard /etc/redhat-release)","")
ifeq ($(OS_ID),rhel)
	@sudo -E yum-config-manager --enable rhel-server-rhscl-7-rpms
	@sudo -E yum groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E yum install $(CONFIRM) $(RPM_DEPENDS)
	@sudo -E debuginfo-install $(CONFIRM) glibc openssl-libs zlib
else ifeq ($(OS_ID),rocky)
	@sudo -E dnf install $(CONFIRM) dnf-plugins-core epel-release
	@sudo -E dnf config-manager --set-enabled \
          $(shell dnf repolist all 2>/dev/null|grep -i crb|cut -d' ' -f1|grep -v source)
	@sudo -E dnf groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E dnf install $(CONFIRM) $(RPM_DEPENDS)
else ifeq ($(OS_ID)-$(OS_VERSION_ID),centos-8)
	@sudo -E dnf install $(CONFIRM) dnf-plugins-core epel-release
	@sudo -E dnf config-manager --set-enabled \
          $(shell dnf repolist all 2>/dev/null|grep -i powertools|cut -d' ' -f1|grep -v source)
	@sudo -E dnf groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E dnf install --skip-broken $(CONFIRM) $(RPM_DEPENDS)
else ifeq ($(OS_ID),centos)
	@sudo -E yum install $(CONFIRM) centos-release-scl-rh epel-release
	@sudo -E yum groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E yum install $(CONFIRM) $(RPM_DEPENDS)
	@sudo -E yum install $(CONFIRM) --enablerepo=base-debuginfo $(RPM_DEPENDS_DEBUG)
else ifeq ($(OS_ID),fedora)
	@sudo -E dnf groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E dnf install $(CONFIRM) $(RPM_DEPENDS)
	@sudo -E debuginfo-install $(CONFIRM) glibc openssl-libs zlib
endif
else ifeq ($(OS_ID)-$(OS_VERSION_ID),anolis-8)
	@sudo -E dnf install $(CONFIRM) dnf-plugins-core epel-release
	@sudo -E dnf config-manager --set-enabled \
          $(shell dnf repolist all 2>/dev/null|grep -i powertools|cut -d' ' -f1|grep -v source)
	@sudo -E dnf groupinstall $(CONFIRM) $(RPM_DEPENDS_GROUPS)
	@sudo -E dnf install --skip-broken $(CONFIRM) $(RPM_DEPENDS)
else ifeq ($(filter opensuse-leap-15.3 opensuse-leap-15.4 ,$(OS_ID)-$(OS_VERSION_ID)),$(OS_ID)-$(OS_VERSION_ID))
	@sudo -E zypper refresh
	@sudo -E zypper install  -y $(RPM_SUSE_DEPENDS)
else ifeq ($(OS_ID), freebsd)
	@sudo pkg install -y $(FBSD_DEPS)
else
	$(error "This option currently works only on eLxr, Ubuntu, Debian, RHEL, CentOS, openSUSE-leap or FreeBSD systems")
endif
	git config commit.template .git_commit_template.txt

.PHONY: install-deps
install-deps: install-dep

define make
	@$(MAKE) -C $(BR) CC=$(CC) PLATFORM=$(PLATFORM) TAG=$(1) $(2)
endef

$(BR)/scripts/.version:
ifneq ("$(wildcard /etc/redhat-release)","")
	$(shell $(BR)/scripts/version rpm-string > $(BR)/scripts/.version)
else
	$(shell $(BR)/scripts/version > $(BR)/scripts/.version)
endif

DIST_FILE = $(BR)/vpp-$(shell src/scripts/version).tar
DIST_SUBDIR = vpp-$(shell src/scripts/version|cut -f1 -d-)

.PHONY: dist
dist:
	@if git rev-parse 2> /dev/null ; then \
	    git archive \
	      --prefix=$(DIST_SUBDIR)/ \
	      --format=tar \
	      -o $(DIST_FILE) \
	    HEAD ; \
	    git describe --long > $(BR)/.version ; \
	else \
	    (cd .. ; tar -cf $(DIST_FILE) $(DIST_SUBDIR) --exclude=*.tar) ; \
	    src/scripts/version > $(BR)/.version ; \
	fi
	@tar --append \
	  --file $(DIST_FILE) \
	  --transform='s,.*/.version,$(DIST_SUBDIR)/src/scripts/.version,' \
	  $(BR)/.version
	@$(RM) $(BR)/.version $(DIST_FILE).xz
	@xz -v --threads=0 $(DIST_FILE)
	@$(RM) $(BR)/vpp-latest.tar.xz
	@ln -rs $(DIST_FILE).xz $(BR)/vpp-latest.tar.xz

.PHONY: build
build: $(BR)/.deps.ok
	$(call make,$(PLATFORM)_debug,$(addsuffix -install,$(TARGETS)))

.PHONY: wipedist
wipedist:
	@$(RM) $(BR)/*.tar.xz

.PHONY: wipe
wipe: wipedist test-wipe $(BR)/.deps.ok
	$(call make,$(PLATFORM)_debug,$(addsuffix -wipe,$(TARGETS)))
	@find . -type f -name "*.api.json" ! -path "./src/*" -exec rm {} \;

.PHONY: rebuild
rebuild: wipe build

.PHONY: build-release
build-release: $(BR)/.deps.ok
	$(call make,$(PLATFORM),$(addsuffix -install,$(TARGETS)))

.PHONY: build-gcov
build-gcov: $(BR)/.deps.ok
	$(eval CC=gcc)
	$(call make,vpp_gcov,$(addsuffix -install,$(TARGETS)))

.PHONY: wipe-release
wipe-release: test-wipe $(BR)/.deps.ok
	$(call make,$(PLATFORM),$(addsuffix -wipe,$(TARGETS)))

.PHONY: rebuild-release
rebuild-release: wipe-release build-release

export TEST_DIR ?= $(WS_ROOT)/test

define test
	$(if $(filter-out $(2),retest),$(MAKE) -C $(BR) PLATFORM=vpp TAG=$(1) CC=$(CC) vpp-install,)
	$(eval libs:=lib lib64)
	$(MAKE) -C test \
	  VPP_BUILD_DIR=$(BR)/build-$(1)-native/vpp \
	  VPP_BIN=$(BR)/install-$(1)-native/vpp/bin/vpp \
	  VPP_INSTALL_PATH=$(BR)/install-$(1)-native/ \
	  EXTENDED_TESTS=$(EXTENDED_TESTS) \
	  DECODE_PCAPS=$(DECODE_PCAPS) \
	  TEST_GCOV=$(TEST_GCOV) \
	  PYTHON=$(PYTHON) \
	  OS_ID=$(OS_ID) \
	  RND_SEED=$(RND_SEED) \
	  CACHE_OUTPUT=$(CACHE_OUTPUT) \
	  TAG=$(1) \
	  $(2)
endef

.PHONY: test
test:
	$(call test,vpp,test)

.PHONY: test-debug
test-debug:
	$(call test,vpp_debug,test)

.PHONY: test-cov
test-cov:
	$(eval CC=gcc)
	$(eval TEST_GCOV=1)
	$(call test,vpp_gcov,cov)

.PHONY: test-cov-hs
test-cov-hs: build-gcov
	@$(MAKE) CC=$(CC) -C extras/hs-test test-cov \
	VPP_BUILD_DIR=$(BR)/build-vpp_gcov-native/vpp

.PHONY: test-cov-post-standalone
test-cov-post-standalone:
	$(MAKE) CC=$(CC) -C test cov-post HS_TEST=$(HS_TEST) VPP_BUILD_DIR=$(BR)/build-vpp_gcov-native/vpp

.PHONY: test-cov-both
test-cov-both:
	@echo "Running Python, Golang tests and merging coverage reports."
	find $(BR) -name '*.gcda' -delete
	@$(MAKE) test-cov
	find $(BR) -name '*.gcda' -delete
	@$(MAKE) test-cov-hs
	@$(MAKE) cov-merge

.PHONY: test-cov-build
test-cov-build:
	$(eval CC=gcc)
	$(eval TEST_GCOV=1)
	$(call test,vpp_gcov,test)

.PHONY: test-cov-prep
test-cov-prep:
	$(eval CC=gcc)
	$(call test,vpp_gcov,cov-prep)

.PHONY: test-cov-post
test-cov-post:
	$(eval CC=gcc)
	$(call test,vpp_gcov,cov-post)

.PHONY: cov-merge
cov-merge:
	@lcov --add-tracefile $(BR)/test-coverage-merged/coverage-filtered.info \
		-a $(BR)/test-coverage-merged/coverage-filtered1.info -o $(BR)/test-coverage-merged/coverage-merged.info
	@genhtml $(BR)/test-coverage-merged/coverage-merged.info \
		--output-directory $(BR)/test-coverage-merged/html
	@echo "Code coverage report is in $(BR)/test-coverage-merged/html/index.html"

.PHONY: test-all
test-all:
	$(eval EXTENDED_TESTS=1)
	$(call test,vpp,test)

.PHONY: test-all-debug
test-all-debug:
	$(eval EXTENDED_TESTS=1)
	$(call test,vpp_debug,test)

.PHONY: test-all-cov
test-all-cov:
	$(eval CC=gcc)
	$(eval TEST_GCOV=1)
	$(eval EXTENDED_TESTS=1)
	$(call test,vpp_gcov,test)

.PHONY: papi-wipe
papi-wipe: test-wipe-papi
	$(call banner,"This command is deprecated. Please use 'test-wipe-papi'")

.PHONY: test-wipe-papi
test-wipe-papi:
	@$(MAKE) -C test wipe-papi

.PHONY: test-help
test-help:
	@$(MAKE) -C test help

.PHONY: test-wipe
test-wipe:
	@$(MAKE) -C test wipe

.PHONY: test-shell
test-shell:
	$(call test,vpp,shell)

.PHONY: test-shell-debug
test-shell-debug:
	$(call test,vpp_debug,shell)

.PHONY: test-shell-cov
test-shell-cov:
	$(eval CC=gcc)
	$(eval TEST_GCOV=1)
	$(call test,vpp_gcov,shell)

.PHONY: test-dep
test-dep:
	@$(MAKE) -C test test-dep

.PHONY: test-doc
test-doc:
	@echo "make test-doc is DEPRECATED: use 'make docs'"
	sleep 300

.PHONY: test-wipe-doc
test-wipe-doc:
	@echo "make test-wipe-doc is DEPRECATED"
	sleep 300

.PHONY: test-wipe-cov
test-wipe-cov:
	$(call make,$(PLATFORM)_gcov,$(addsuffix -wipe,$(TARGETS)))
	@$(MAKE) -C test wipe-cov

.PHONY: test-wipe-all
test-wipe-all:
	@$(MAKE) -C test wipe-all

# Note: All python venv consolidated in test/Makefile, test/requirements*.txt
#       Also, this target is used by ci-management/jjb/scripts/vpp/checkstyle-test.sh,
#       thus inclusion of checkstyle-go here to include checkstyle for hs-test
#       in the vpp-checkstyle-verify-*-*-* jobs
.PHONY: test-checkstyle
test-checkstyle:
	@$(MAKE) -C test checkstyle-python-all
	@$(MAKE) -C extras/hs-test checkstyle-go

# Note: All python venv consolidated in test/Makefile, test/requirements*.txt
.PHONY: test-checkstyle-diff
test-checkstyle-diff:
	$(warning test-checkstyle-diff is deprecated. Running checkstyle-python.")
	@$(MAKE) -C test checkstyle-python-all

.PHONY: test-refresh-deps
test-refresh-deps:
	@$(MAKE) -C test refresh-deps

.PHONY: retest
retest:
	$(call test,vpp,retest)

.PHONY: retest-debug
retest-debug:
	$(call test,vpp_debug,retest)

.PHONY: retest-all
retest-all:
	$(eval EXTENDED_TESTS=1)
	$(call test,vpp,retest)

.PHONY: retest-all-debug
retest-all-debug:
	$(eval EXTENDED_TESTS=1)
	$(call test,vpp_debug,retest)

.PHONY: test-start-vpp-in-gdb
test-start-vpp-in-gdb:
	$(call test,vpp,start-gdb)

.PHONY: test-start-vpp-debug-in-gdb
test-start-vpp-debug-in-gdb:
	$(call test,vpp_debug,start-gdb)

ifeq ("$(wildcard $(STARTUP_CONF))","")
define run
	@echo "WARNING: STARTUP_CONF not defined or file doesn't exist."
	@echo "         Running with minimal startup config: $(MINIMAL_STARTUP_CONF)\n"
	@cd $(STARTUP_DIR) && \
	  $(SUDO) $(2) $(1)/vpp/bin/vpp $(MINIMAL_STARTUP_CONF)
endef
else
define run
	@cd $(STARTUP_DIR) && \
	  $(SUDO) $(2) $(1)/vpp/bin/vpp $(shell cat $(STARTUP_CONF) | sed -e 's/#.*//')
endef
endif

%.files: .FORCE
	@find src -name '*.[chS]' > $@

.FORCE:

.PHONY: run
run:
	$(call run, $(BR)/install-$(PLATFORM)_debug-native)

.PHONY: run-release
run-release:
	$(call run, $(BR)/install-$(PLATFORM)-native)

.PHONY: debug
debug:
	$(call run, $(BR)/install-$(PLATFORM)_debug-native,$(GDB) $(GDB_ARGS) --args)

.PHONY: build-coverity
build-coverity:
	$(call make,$(PLATFORM)_coverity,install-packages)
	@$(MAKE) -C build-root PLATFORM=vpp TAG=vpp_coverity libmemif-install

.PHONY: debug-release
debug-release:
	$(call run, $(BR)/install-$(PLATFORM)-native,$(GDB) $(GDB_ARGS) --args)

.PHONY: build-vat
build-vat:
	$(call make,$(PLATFORM)_debug,vpp-api-test-install)

.PHONY: run-vat
run-vat:
	@$(SUDO) $(BR)/install-$(PLATFORM)_debug-native/vpp/bin/vpp_api_test

.PHONY: pkg-deb
pkg-deb:
	$(call make,$(PLATFORM),vpp-package-deb)

.PHONY: pkg-snap
pkg-snap:
	cd extras/snap ;			\
        ./prep ;				\
	SNAPCRAFT_BUILD_ENVIRONMENT_MEMORY=8G 	\
	SNAPCRAFT_BUILD_ENVIRONMENT_CPU=6 	\
	snapcraft --debug

.PHONY: snap-clean
snap-clean:
	cd extras/snap ;			\
        snapcraft clean ;			\
	rm -f *.snap *.tgz

.PHONY: pkg-deb-debug
pkg-deb-debug:
	$(call make,$(PLATFORM)_debug,vpp-package-deb)

.PHONY: pkg-rpm
pkg-rpm: dist
	$(MAKE) -C extras/rpm

.PHONY: pkg-srpm
pkg-srpm: dist
	$(MAKE) -C extras/rpm srpm

.PHONY: install-ext-deps
install-ext-deps:
	$(MAKE) CC=$(CC) -C build/external install-$(PKG)

.PHONY: install-ext-dep
install-ext-dep: install-ext-deps

.PHONY: install-opt-deps
install-opt-deps:
	$(MAKE) CC=$(CC) -C build/optional install-$(PKG)

.PHONY: json-api-files
json-api-files:
	$(WS_ROOT)/src/tools/vppapigen/generate_json.py

.PHONY: json-api-files-debug
json-api-files-debug:
	$(WS_ROOT)/src/tools/vppapigen/generate_json.py --debug-target

.PHONY: go-api-files
go-api-files: json-api-files
	$(WS_ROOT)/src/tools/vppapigen/generate_go.py $(ARGS)

.PHONY: cleanup-hst
cleanup-hst:
	$(MAKE) -C extras/hs-test cleanup-hst

.PHONY: ctags
ctags: ctags.files
	@ctags --totals --tag-relative=yes -L $<
	@rm $<

.PHONY: etags
etags: ctags.files
	@ctags -e --totals -L $<
	@rm $<

.PHONY: gtags
gtags: ctags
	@gtags --gtagslabel=ctags

.PHONY: cscope
cscope: cscope.files
	@cscope -b -q -v

.PHONY: compdb
compdb:
	@ninja -C build-root/build-vpp_debug-native/vpp build.ninja
	@ninja -C build-root/build-vpp_debug-native/vpp -t compdb | \
	  src/scripts/compdb_cleanup.py > compile_commands.json

.PHONY: checkstyle
checkstyle: checkfeaturelist
	@extras/scripts/checkstyle.sh

.PHONY: checkstyle-commit
checkstyle-commit:
	@extras/scripts/check_commit_msg.sh

.PHONY: checkstyle-test
checkstyle-test:
	$(warning test-checkstyle is deprecated. Running checkstyle-python.")
	@$(MAKE) -C test checkstyle-python-all

# Note: All python venv consolidated in test/Makefile, test/requirements*.txt
.PHONY: checkstyle-python
checkstyle-python:
	@$(MAKE) -C test checkstyle-python-all

.PHONY: checkstyle-go
checkstyle-go:
	@$(MAKE) -C extras/hs-test checkstyle-go

.PHONY: fixstyle-go
fixstyle-go:
	@$(MAKE) -C extras/hs-test fixstyle-go

.PHONY: checkstyle-all
checkstyle-all: checkstyle-commit checkstyle checkstyle-python docs-spell checkstyle-go

.PHONY: fixstyle
fixstyle:
	@extras/scripts/checkstyle.sh --fix

# Note: All python venv consolidated in test/Makefile, test/requirements*.txt
.PHONY: fixstyle-python
fixstyle-python:
	@$(MAKE) -C test fixstyle-python-all

.PHONY: checkstyle-api
checkstyle-api:
	@extras/scripts/crcchecker.py --check-patchset

# necessary because Bug 1696324 - Update to python3.6 breaks PyYAML dependencies
# Status:	CLOSED CANTFIX
# https://bugzilla.redhat.com/show_bug.cgi?id=1696324
.PHONY: centos-pyyaml
centos-pyyaml:
ifeq ($(OS_ID)-$(OS_VERSION_ID),centos-8)
	@sudo -E yum install $(CONFIRM) python3-pyyaml
endif

.PHONY: featurelist
featurelist: centos-pyyaml
	@extras/scripts/fts.py --all --markdown

.PHONY: checkfeaturelist
checkfeaturelist: centos-pyyaml
	@extras/scripts/fts.py --validate --all

#
# Build the documentation
#

.PHONY: bootstrap-doxygen
bootstrap-doxygen:
	@echo "make bootstrap-doxygen is DEPRECATED"
	sleep 300

.PHONY: doxygen
doxygen: docs
	@echo "make doxygen is DEPRECATED: use 'make docs'"
	sleep 300

.PHONY: wipe-doxygen
wipe-doxygen:
	@echo "make wipe-doxygen is DEPRECATED"
	sleep 300

.PHONY: docs-%
docs-%:
	@$(MAKE) -C $(WS_ROOT)/docs $*

.PHONY: docs
docs:
	@$(MAKE) -C $(WS_ROOT)/docs docs

.PHONY: pkg-verify
pkg-verify: $(BR)/.deps.ok install-ext-deps
	$(call banner,"Building for PLATFORM=vpp")
	@$(MAKE) CC=$(CC) -C build-root PLATFORM=vpp TAG=vpp wipe-all install-packages
	$(call banner,"Building sample-plugin")
	@$(MAKE) CC=$(CC) -C build-root PLATFORM=vpp TAG=vpp sample-plugin-install
	$(call banner,"Building libmemif")
	@$(MAKE) CC=gcc -C build-root PLATFORM=vpp TAG=vpp libmemif-install
	$(call banner,"Building $(PKG) packages")
	@$(MAKE) CC=$(CC) pkg-$(PKG)

# Note: 'make verify' target is not used by ci-management scripts
MAKE_VERIFY_GATE_OS ?= ubuntu-22.04
.PHONY: verify
verify: pkg-verify
ifeq ($(OS_ID)-$(OS_VERSION_ID),$(MAKE_VERIFY_GATE_OS))
	$(call banner,"Testing vppapigen")
	@src/tools/vppapigen/test_vppapigen.py
	$(call banner,"Running tests")
	@$(MAKE) CC=$(CC) COMPRESS_FAILED_TEST_LOGS=yes RETRIES=3 test
else
	$(call banner,"Skipping tests. Tests under 'make verify' supported on $(MAKE_VERIFY_GATE_OS)")
endif

.PHONY: check-dpdk-mlx
check-dpdk-mlx:
	@[ $$($(MAKE) -sC build/external dpdk-show-DPDK_MLX_DEFAULT) = y ]
