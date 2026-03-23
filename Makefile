.PHONY: build test test-runtime test-e2e test-examples bench fuzz-lexer fuzz-parser fuzz-pipeline wasm clean
.PHONY: website website-dev website-build website-preview
.PHONY: help

# Compiler
build:
	zig build

test:
	zig build test

test-runtime:
	zig build test-runtime

test-e2e:
	zig build test-e2e

test-examples:
	zig build test-examples

test-all: test test-runtime test-e2e test-examples

bench:
	zig build bench

fuzz-lexer:
	zig build fuzz-lexer

fuzz-parser:
	zig build fuzz-parser

fuzz-pipeline:
	zig build fuzz-pipeline

wasm:
	zig build wasm

clean:
	rm -rf zig-out zig-cache .zig-cache

# Website
website-dev:
	cd website && bun run dev

website-build:
	cd website && bun run build

website-preview:
	cd website && bun run preview

website-install:
	cd website && bun install

# Help
help:
	@echo "Compiler:"
	@echo "  make build          - Build the run compiler"
	@echo "  make test           - Run unit tests (lexer + parser)"
	@echo "  make test-runtime   - Run runtime C tests"
	@echo "  make test-e2e       - Run end-to-end compiler tests"
	@echo "  make test-examples  - Build all example programs"
	@echo "  make test-all       - Run all tests"
	@echo "  make bench          - Run benchmarks"
	@echo "  make fuzz-lexer     - Fuzz the lexer"
	@echo "  make fuzz-parser    - Fuzz the parser"
	@echo "  make fuzz-pipeline  - Fuzz the full pipeline"
	@echo "  make wasm           - Build WASM module for web playground"
	@echo "  make clean          - Remove build artifacts"
	@echo ""
	@echo "Website:"
	@echo "  make website-install - Install website dependencies (bun)"
	@echo "  make website-dev     - Start dev server (localhost:4321)"
	@echo "  make website-build   - Production build"
	@echo "  make website-preview - Preview production build"
