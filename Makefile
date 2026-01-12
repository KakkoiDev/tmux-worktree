# tmux-worktree Makefile
# Test execution and development utilities

SHELL := /bin/bash
BATS := bats

# Directories
TEST_DIR := tests
UNIT_DIR := $(TEST_DIR)/unit
INTEGRATION_DIR := $(TEST_DIR)/integration

# Find all test files
UNIT_TESTS := $(wildcard $(UNIT_DIR)/*.bats)
INTEGRATION_TESTS := $(wildcard $(INTEGRATION_DIR)/*.bats)
ALL_TESTS := $(UNIT_TESTS) $(INTEGRATION_TESTS)

# Default number of parallel jobs (auto-detect CPU count)
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

.PHONY: test test-fast test-unit test-integration test-parallel clean help

# Default target
all: test

# Run all tests sequentially
test:
	@echo "Running all tests..."
	@$(BATS) $(ALL_TESTS)

# Run only unit tests (fast, no git operations)
test-fast: test-unit

test-unit:
	@echo "Running unit tests..."
	@$(BATS) $(UNIT_TESTS)

# Run only integration tests
test-integration:
	@echo "Running integration tests..."
	@$(BATS) $(INTEGRATION_TESTS)

# Run all tests in parallel (requires GNU parallel)
test-parallel:
	@if ! command -v parallel >/dev/null 2>&1; then \
		echo "Warning: GNU parallel not found. Install with:"; \
		echo "  Ubuntu/Debian: sudo apt-get install parallel"; \
		echo "  macOS: brew install parallel"; \
		echo "Running tests sequentially instead..."; \
		$(BATS) $(ALL_TESTS); \
	else \
		echo "Running all tests in parallel ($(JOBS) jobs)..."; \
		$(BATS) --jobs $(JOBS) $(ALL_TESTS); \
	fi

# Run unit tests in parallel (fastest)
test-unit-parallel:
	@echo "Running unit tests in parallel ($(JOBS) jobs)..."
	@$(BATS) --jobs $(JOBS) $(UNIT_TESTS)

# Run integration tests in parallel
test-integration-parallel:
	@echo "Running integration tests in parallel ($(JOBS) jobs)..."
	@$(BATS) --jobs $(JOBS) $(INTEGRATION_TESTS)

# Run tests with verbose output
test-verbose:
	@echo "Running all tests (verbose)..."
	@$(BATS) --verbose-run $(ALL_TESTS)

# Run a specific test file
# Usage: make test-file FILE=tests/unit/test_helpers_unit.bats
test-file:
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=tests/path/to/test.bats"; \
		exit 1; \
	fi
	@$(BATS) $(FILE)

# Run tests matching a filter
# Usage: make test-filter FILTER="pagination"
test-filter:
	@if [ -z "$(FILTER)" ]; then \
		echo "Usage: make test-filter FILTER=\"pattern\""; \
		exit 1; \
	fi
	@$(BATS) --filter "$(FILTER)" $(ALL_TESTS)

# Clean temporary test files
clean:
	@echo "Cleaning temporary test files..."
	@rm -rf /tmp/shared-repo.* /tmp/worktrees-* /tmp/tmux-worktree-*
	@echo "Done."

# Show test count
test-count:
	@echo "Test files:"
	@echo "  Unit:        $(words $(UNIT_TESTS)) files"
	@echo "  Integration: $(words $(INTEGRATION_TESTS)) files"
	@echo "  Total:       $(words $(ALL_TESTS)) files"
	@echo ""
	@echo "Test count:"
	@$(BATS) --count $(ALL_TESTS) 2>/dev/null || echo "  (run 'make test' to see test count)"

# Show help
help:
	@echo "tmux-worktree Test Targets:"
	@echo ""
	@echo "  make test                - Run all tests sequentially"
	@echo "  make test-fast           - Run only unit tests (fast, no git ops)"
	@echo "  make test-unit           - Run unit tests"
	@echo "  make test-integration    - Run integration tests"
	@echo "  make test-parallel       - Run all tests in parallel"
	@echo "  make test-verbose        - Run all tests with verbose output"
	@echo "  make test-file FILE=...  - Run a specific test file"
	@echo "  make test-filter FILTER=.- Run tests matching filter pattern"
	@echo "  make test-count          - Show test file and test count"
	@echo "  make clean               - Clean temporary test files"
	@echo ""
	@echo "Environment variables:"
	@echo "  JOBS=N                   - Number of parallel jobs (default: auto)"
	@echo ""
	@echo "Examples:"
	@echo "  make test-file FILE=tests/unit/test_helpers_unit.bats"
	@echo "  make test-filter FILTER=\"pagination\""
	@echo "  make test-parallel JOBS=8"
