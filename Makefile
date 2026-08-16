SHELL := /bin/sh

UV ?= uv
HOST ?= 127.0.0.1
PORT ?= 8000

VENV := .venv
VENV_BIN := $(VENV)/bin
DEPENDENCY_STAMP := $(VENV)/.requirements-installed

.DEFAULT_GOAL := help

.PHONY: help install dev run health

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: $(DEPENDENCY_STAMP) ## Create the virtual environment and install dependencies

$(DEPENDENCY_STAMP): requirements.txt
	test -x $(VENV_BIN)/python || $(UV) venv $(VENV)
	$(UV) pip install --python $(VENV_BIN)/python --requirements requirements.txt
	@touch $(DEPENDENCY_STAMP)

dev: $(DEPENDENCY_STAMP) ## Start the API with automatic reload
	$(VENV_BIN)/uvicorn main:app --app-dir src --host $(HOST) --port $(PORT) --reload

run: $(DEPENDENCY_STAMP) ## Start the API without automatic reload
	$(VENV_BIN)/uvicorn main:app --app-dir src --host $(HOST) --port $(PORT)

health: ## Check the health endpoint of a running API
	@curl --fail --silent --show-error --output /dev/null http://$(HOST):$(PORT)/health
	@echo "healthy"
