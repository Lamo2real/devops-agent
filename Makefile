# AWS DevOps Agent serverless template. Everything is driven by project.env.
SHELL := /bin/bash
VENV  := .venv
PY    := $(VENV)/bin/python
export PYTHON := $(abspath $(PY))

.DEFAULT_GOAL := help

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

STAMP := $(VENV)/.installed

$(STAMP): requirements-dev.txt src/requirements.txt
	@if command -v uv >/dev/null; then uv venv -q --allow-existing -p 3.13 $(VENV) && uv pip install -q --python $(PY) -r requirements-dev.txt; \
	else python3 -m venv $(VENV) && $(PY) -m pip install -q -r requirements-dev.txt; fi
	@touch $(STAMP)

venv: $(STAMP) ## Create the local Python environment

config: $(STAMP) ## Validate project.env
	$(PY) scripts/config.py validate

build: $(STAMP) ## Build the Lambda package
	scripts/build_lambda.sh

test: $(STAMP) ## Unit tests, Terraform format/validate and Terraform mock tests (no AWS needed)
	$(PY) -m pytest -q
	terraform fmt -check -recursive terraform
	scripts/build_lambda.sh
	@# Separate data dir: tests never touch a real backend configured by deploy/bootstrap.
	@for stack in main bootstrap; do \
	  echo "terraform $$stack: init, validate, test"; \
	  TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack init -backend=false -input=false >/dev/null && \
	  TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack validate && \
	  TF_DATA_DIR=.terraform-test terraform -chdir=terraform/$$stack test || exit 1; \
	done
	@if command -v tflint >/dev/null; then cd terraform/main && TF_DATA_DIR=.terraform-test tflint --init >/dev/null && TF_DATA_DIR=.terraform-test tflint; else echo "tflint not installed, skipped"; fi

bootstrap: $(STAMP) ## One-time per environment: state bucket, boundaries, GitHub OIDC roles
	scripts/bootstrap.sh

github-setup: $(STAMP) ## Connect your fork's GitHub Actions to the OIDC roles (gh CLI)
	scripts/github_setup.sh

plan: $(STAMP) ## Plan the main stack
	PLAN_ONLY=1 scripts/deploy.sh

deploy: $(STAMP) ## Plan and apply the main stack
	scripts/deploy.sh

smoke-test: $(STAMP) ## Fire the test alarm and check an investigation starts (costs one short investigation)
	$(PY) scripts/smoke_test.py

destroy: $(STAMP) ## Delete the main stack (keeps the bootstrap stack)
	scripts/destroy.sh

clean: ## Remove build output
	rm -rf build terraform/main/.build

.PHONY: help venv config build test bootstrap github-setup plan deploy smoke-test destroy clean
