# Makefile for RISC-V Doc Template
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 4.0
# International License. To view a copy of this license, visit
# http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to
# Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.
#
# SPDX-License-Identifier: CC-BY-SA-4.0
#
# Description:
# 
# This Makefile is designed to automate the process of building and packaging 
# the Doc Template for RISC-V Extensions.

DATE ?= $(shell date +%Y-%m-%d)
VERSION ?= $(shell git describe --tags)
REVMARK ?= \"This document is in development. Assume everything can change. See http://riscv.org/spec-state for details.\"
DOCKER_RUN := docker run --rm -v ${PWD}:/build -w /build \
riscvintl/riscv-docs-base-container-image:latest

HEADER_SOURCE := header.adoc
PDF_RESULT := riscv-brs-spec.pdf

TS_HEADER_SOURCE := brs_ts_header.adoc
TS_PDF_RESULT := riscv-brs-ts.pdf

ASCIIDOCTOR_PDF := asciidoctor-pdf
OPTIONS := --trace \
           -a compress \
           -a mathematical-format=svg \
           -a revnumber=${VERSION} \
           -a revremark=${REVMARK} \
           -a revdate=${DATE} \
           -a pdf-fontsdir=docs-resources/fonts \
           -a pdf-style=docs-resources/themes/riscv-pdf.yml \
           --failure-level=ERROR
REQUIRES := --require=asciidoctor-bibtex \
            --require=asciidoctor-diagram \
            --require=asciidoctor-mathematical

.PHONY: all build clean build-container build-no-container

all: build

build: 
	@echo "Checking if Docker is available..."
	@if command -v docker >/dev/null 2>&1 ; then \
		echo "Docker is available, building inside Docker container..."; \
		$(MAKE) build-container; \
	else \
		echo "Docker is not available, building without Docker..."; \
		$(MAKE) build-no-container; \
	fi

build-container:
	@echo "Starting build inside Docker container..."
	$(DOCKER_RUN) /bin/sh -c "$(ASCIIDOCTOR_PDF) $(OPTIONS) $(REQUIRES) --out-file=$(PDF_RESULT) $(HEADER_SOURCE)"
	$(DOCKER_RUN) /bin/sh -c "$(ASCIIDOCTOR_PDF) $(OPTIONS) $(REQUIRES) --out-file=$(TS_PDF_RESULT) $(TS_HEADER_SOURCE)"
	@echo "Build completed successfully inside Docker container."

build-no-container:
	@echo "Starting build..."
	$(ASCIIDOCTOR_PDF) $(OPTIONS) $(REQUIRES) --out-file=$(PDF_RESULT) $(HEADER_SOURCE)
	$(ASCIIDOCTOR_PDF) $(OPTIONS) $(REQUIRES) --out-file=$(TS_PDF_RESULT) $(TS_HEADER_SOURCE)
	@echo "Build completed successfully."

clean:
	@echo "Cleaning up generated files..."
	rm -f $(PDF_RESULT)
	@echo "Cleanup completed."
