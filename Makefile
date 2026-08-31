SHELL := $(shell which bash)
SELF  := $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST)))))

ENV_RUN      = hatch env run -e $(1) --
ENV_ONE_DEPLOY_VALIDATION := $(shell hatch env find validation-default)

I         ?= $(SELF)/inventory/reference/example.yml
INVENTORY ?= $(I)

T    ?=
TAGS ?= $(T)

S         ?=
SKIP_TAGS ?= $(S)

V       ?= vv
VERBOSE ?= $(V)

export

# Make sure we source ANSIBLE_ settings from ansible.cfg exclusively.
unexport $(filter ANSIBLE_%,$(.VARIABLES))

.PHONY: validation

validation: _TAGS      := $(if $(TAGS),-t $(TAGS),)
validation: _SKIP_TAGS := $(if $(SKIP_TAGS),--skip-tags $(SKIP_TAGS),)
validation: _VERBOSE   := $(if $(VERBOSE),-$(VERBOSE),)

ifdef ENV_ONE_DEPLOY_VALIDATION
$(ENV_ONE_DEPLOY_VALIDATION):
	hatch env create validation-default
endif

validation: $(ENV_ONE_DEPLOY_VALIDATION)
	cd $(SELF)/ && \
	$(call ENV_RUN,validation-default) ansible-playbook $(_VERBOSE) -i $(INVENTORY) $(_TAGS) $(_SKIP_TAGS) $(ANSIBLE_ARGS) $(SELF)/playbooks/validation.yml

.PHONY: test
test: $(ENV_ONE_DEPLOY_VALIDATION)
	cd $(SELF)/ && \
	$(call ENV_RUN,validation-default) python3 $(SELF)/test/gpu_benchmark/lint_shell.py && \
	$(call ENV_RUN,validation-default) ansible-playbook -i localhost, $(SELF)/test/gpu_benchmark/test_logic.yml && \
	$(call ENV_RUN,validation-default) ansible-playbook -i localhost, $(SELF)/test/harness/test_logic.yml
