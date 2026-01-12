# Contributing to tmux-worktree

Thanks for your interest in contributing! This guide covers how to set up your development environment and run the test suite.

## Prerequisites

- **BATS** (Bash Automated Testing System) 1.7+
  ```bash
  # Ubuntu/Debian
  sudo apt-get install bats

  # macOS
  brew install bats-core

  # From source
  git clone https://github.com/bats-core/bats-core.git
  cd bats-core && sudo ./install.sh /usr/local
  ```

- **tmux** 3.0+ (required for display-menu support)
  ```bash
  tmux -V  # Check version
  ```

- **git** (any recent version)

## Running Tests

### Quick Commands

```bash
# Run all tests
make test

# Run only unit tests (fast, no git operations)
make test-fast

# Run all tests in parallel (fastest)
make test-parallel

# Run integration tests only
make test-integration
```

### Specific Tests

```bash
# Run a specific test file
make test-file FILE=tests/unit/test_helpers_unit.bats

# Run tests matching a pattern
make test-filter FILTER="pagination"

# Run with verbose output
make test-verbose
```

### Parallel Execution

Parallel execution requires [GNU parallel](https://www.gnu.org/software/parallel/):

```bash
# Install GNU parallel
sudo apt-get install parallel  # Ubuntu/Debian
brew install parallel          # macOS

# Auto-detect CPU count
make test-parallel

# Specify job count
make test-parallel JOBS=8
```

## Test Organization

```
tests/
  test_helper.bash         # Shared test utilities
  unit/                    # Fast tests (no git operations)
    test_helpers_unit.bats # Helper function tests
  integration/             # Tests requiring git repositories
    test_core_functions.bats
    test_defensive_coding.bats
    test_error_handling.bats
    test_filter.bats
    test_menu_integration.bats
    test_plugin_loader.bats
    test_remote_fetch.bats
    test_worktree_lifecycle.bats
```

### Unit Tests

Located in `tests/unit/`. These tests:
- Don't require git repositories
- Run very quickly (~1 second)
- Test pure functions like `get_session_name`, `validate_positive_int`

### Integration Tests

Located in `tests/integration/`. These tests:
- Require git repositories (created automatically)
- Use the shared repo pattern for performance
- Test worktree operations, menu generation, filtering

## Writing Tests

### Unit Test Example

```bash
@test "function_name does expected behavior" {
    source "$SCRIPTS_DIR/helpers.sh"
    run function_name "input"
    assert_success
    assert_equal "expected" "$output"
}
```

### Integration Test Example

```bash
@test "worktree operation works correctly" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-branch"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-branch"

    # Test logic here
    run get_worktree_data 1 ""
    assert_contains "$output" "test-branch"

    # Cleanup
    git worktree remove --force "$wt_dir"
    git branch -D "test-branch"
}
```

### Test Patterns

- **Use shared repo pattern**: Integration tests use `create_shared_repo()` / `reset_shared_repo()` for performance
- **Clean up resources**: Always clean up worktrees and branches in tests
- **Mock tmux calls**: Override `display_menu()` or `tmux()` to capture output
- **Test edge cases**: Empty inputs, invalid pages, special characters

## Available Assertions

From `test_helper.bash`:
- `assert_success` - Check command succeeded (exit 0)
- `assert_failure` - Check command failed (non-zero exit)
- `assert_equal "expected" "$actual"` - Check string equality
- `assert_contains "$haystack" "needle"` - Check substring present
- `assert_file_exists "path"` - Check file exists
- `assert_executable "path"` - Check file is executable

## Cleaning Up

```bash
# Remove temporary test files
make clean
```

## Pull Request Guidelines

1. Run `make test` and ensure all tests pass
2. Add tests for new functionality
3. Keep commits focused and atomic
4. Follow existing code style

## Questions?

Open an issue if you have questions about contributing.
