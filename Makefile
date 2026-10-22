# Build the NIF shared library for :zaml using libyaml (via Zig cImport).
#
# Requires the Zig toolchain (0.16+) and libyaml headers/library. On
# macOS via Homebrew this is auto-detected; on Debian/Ubuntu install
# `libyaml-dev`; on Alpine `yaml-dev`. The Makefile falls back to
# pkg-config, then to common well-known paths.
#
# Erlang headers are picked up from the active Erlang/OTP installation.

ifeq ($(shell command -v pkg-config 2>/dev/null),)
  YAML_CFLAGS :=
  YAML_LIBS   :=
else
  YAML_CFLAGS := $(shell pkg-config --cflags yaml-0.1 2>/dev/null)
  YAML_LIBS   := $(shell pkg-config --libs yaml-0.1 2>/dev/null)
endif

ifeq ($(strip $(YAML_CFLAGS))$(strip $(YAML_LIBS)),)
  ifneq ($(wildcard /opt/homebrew/include/yaml.h),)
    YAML_CFLAGS := -I/opt/homebrew/include
    YAML_LIBS   := -L/opt/homebrew/lib -lyaml
  else ifneq ($(wildcard /usr/local/include/yaml.h),)
    YAML_CFLAGS := -I/usr/local/include
    YAML_LIBS   := -L/usr/local/lib -lyaml
  else ifneq ($(wildcard /usr/include/yaml.h),)
    YAML_CFLAGS :=
    YAML_LIBS   := -lyaml
  endif
endif

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [code:lib_dir(erts, include)]), halt().')

PRIV_DIR := $(MIX_APP_PATH)/priv
PRIV_SO  := $(PRIV_DIR)/zaml.so

ZIG_BUILD_ARGS := \
	build-lib \
	-O ReleaseFast \
	-dynamic \
	-fallow-shlib-undefined \
	-femit-bin=$(PRIV_SO) \
	-I $(ERTS_INCLUDE_DIR) \
	$(YAML_CFLAGS) \
	$(YAML_LIBS) \
	--dep core \
	-Mroot=native/zaml_nif.zig \
	-O ReleaseFast \
	-Mcore=core/native.zig

all: $(PRIV_SO)

$(PRIV_SO): native/zaml_nif.zig core/native.zig core/scalar.zig
	@mkdir -p $(PRIV_DIR)
	zig $(ZIG_BUILD_ARGS)

$(PRIV_DIR):
	@mkdir -p $(PRIV_DIR)

clean:
	rm -f $(PRIV_SO)

.PHONY: all clean
