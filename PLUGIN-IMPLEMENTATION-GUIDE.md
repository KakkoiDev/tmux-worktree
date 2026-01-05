# Tmux-Worktrees Plugin - Implementation Handoff Guide

**Last Updated:** 2026-01-05
**Purpose:** Complete implementation guide for converting standalone tmux_worktree.sh into TPM plugin
**Target Audience:** Claude Code implementation agent or future developer

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Current Implementation Analysis](#current-implementation-analysis)
3. [New Features to Implement](#new-features-to-implement)
4. [Technical Specifications](#technical-specifications)
5. [Step-by-Step Implementation Plan](#step-by-step-implementation-plan)
6. [Testing Strategy](#testing-strategy)
7. [Configuration Design](#configuration-design)
8. [Edge Cases and Gotchas](#edge-cases-and-gotchas)

---

## Project Overview

### What We're Building

**tmux-worktree** - A TPM-compatible tmux plugin for managing git worktrees with an interactive menu system.

### Why

**Current State:**
- Standalone script (`tmux_worktree.sh`) in personal dotfiles
- Manual installation and updates
- Limited to single user/machine

**Target State:**
- Installable via TPM (Tmux Plugin Manager)
- Community shareable
- Enhanced features: filter mode (all menus) and remote branch fetching
- Professional testing infrastructure

### Success Criteria

- [ ] TPM-compatible plugin structure
- [ ] All existing functionality preserved
- [ ] Filter mode available in ALL menus (list, add, remove) via 'f' key
- [ ] Remote branch fetching in Add menu via 'r' key
- [ ] POSIX-compliant filter (wildcard matching, no fzf dependency)
- [ ] Testable with isolated tmux socket (`tmux -L test-worktrees`)
- [ ] Published on GitHub with documentation

---

## Current Implementation Analysis

### Architecture Overview

**File:** `scripts/tmux_worktree.sh` (297 lines)

**Layered Architecture:**
```
┌─────────────────────────────────────┐
│   Main Menu (tmux_worktrees_main)   │
│   List | Add | Remove | Quit        │
└───────────┬─────────────────────────┘
            │
┌───────────┴─────────────────────────┐
│   Menu Display Functions            │
│   - show_worktree_menu              │
│   - show_add_worktree_menu          │
│   - show_remove_worktree_menu       │
└───────────┬─────────────────────────┘
            │
┌───────────┴─────────────────────────┐
│   Navigation Helpers                │
│   - generate_nav_options            │
│   - Pagination (15 items/page)      │
│   - Vim-style (o/i) navigation      │
└───────────┬─────────────────────────┘
            │
┌───────────┴─────────────────────────┐
│   Page Calculation Functions        │
│   - get_worktree_page_count         │
│   - get_branch_page_count           │
│   - get_removable_worktree_page_count│
└───────────┬─────────────────────────┘
            │
┌───────────┴─────────────────────────┐
│   Core Data Functions               │
│   - get_worktree_data (pagination)  │
│   - get_branch_data (pagination)    │
│   - get_removable_worktree_data     │
│   - remove_worktree (cleanup)       │
│   - create_new_worktree             │
│   - get_project_name                │
└─────────────────────────────────────┘
```

### Key Functions Reference

#### 1. Core Data Functions

**`get_project_name()`**
- Extracts project name from git repository root
- Used for session naming: `{project}-{branch}`

**`get_worktree_data(page)`**
- Returns paginated list of worktrees with switch/create actions
- AWK parses `git worktree list --porcelain`
- Generates tmux menu entries with session management commands
- Session naming: `project-branch` with `/` → `-` conversion

**`get_branch_data(page)`**
- Returns paginated list of local branches for worktree creation
- Each entry creates worktree in `$WORKTREE_BASE/{branch}`
- Auto-creates and switches to new tmux session

**`get_removable_worktree_data(page)`**
- Returns paginated list of worktrees (excluding current)
- **Smart cleanup detection:**
  - Managed worktrees (`__tmux_managed__`): Remove worktree + delete branch + kill session
  - Existing branch worktrees: Remove worktree only + kill session
- Includes timeout protection (10s worktree, 5s branch)
- Live menu refresh after removal

**`remove_worktree(path, branch, is_managed, session, page)`**
- Executes worktree removal with cleanup
- Handles both session naming patterns (`project-branch` and `branch`)
- Refreshes remove menu after completion

**`create_new_worktree(branch)`**
- Creates new branch + worktree in managed directory
- Auto-creates and switches to tmux session
- Uses `-b` flag for new branch creation

#### 2. Page Calculation Functions

**Pattern:** All use ceiling division for page count
```bash
total=$(count_items)
echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
```

#### 3. Navigation Helpers

**`generate_nav_options(page, total_pages, menu_function)`**
- Returns navigation menu entries:
  - Previous page (if page > 1): `◀ Previous` key: `o`
  - Next page (if page < total): `Next ▶` key: `i`
  - Back to main: `← Back` key: `BSpace`
- Uses `run-shell ". '$SCRIPT_PATH' && $menu_function $page"`

#### 4. Menu Display Functions

**`display_menu(title, options)`**
- Generic wrapper for `tmux display-menu`
- Handles title and option string evaluation

**`show_worktree_menu(page)`**
- List worktrees with pagination
- Title: `"Worktrees (Page $page/$total_pages)"`
- Actions: Switch to session or create new session for worktree

**`show_add_worktree_menu(page)`**
- Add worktree from branches
- First option: `"New" "n"` - Prompts for new branch name
- Remaining: Existing branches with pagination
- Title: `"Add Worktree (Page $page/$total_pages)"`

**`show_remove_worktree_menu(page)`**
- Remove worktree with smart cleanup
- Displays all worktrees except current directory
- Title: `"Remove Worktree (Page $page/$total_pages)"`
- Live refresh after removal operation

#### 5. Main Menu

**`tmux_worktrees_main()`**
- Entry point menu with 4 options:
  - `"List" "l"` → show_worktree_menu
  - `"Add" "a"` → show_add_worktree_menu
  - `"Remove" "r"` → show_remove_worktree_menu
  - `"Quit" "q"` → (empty command, closes menu)

### Configuration Constants

```bash
SCRIPT_PATH="$HOME/dotfiles/scripts/tmux_worktree.sh"
WORKTREE_BASE="$HOME/.tmux-worktree/worktrees"
MANAGED_DIR="$WORKTREE_BASE/__tmux_managed__"
ITEMS_PER_PAGE=15
```

### POSIX Compliance Features

1. **Environment handling** (lines 9-16):
   - PATH fallback if missing or git unavailable
   - HOME fallback to `~$USER` if unset

2. **Shell detection** (lines 295-297):
   - Executes main only if script run directly (not sourced)
   - Uses `case "$0" in *tmux_worktree.sh)` pattern

3. **Command compatibility:**
   - No bash-specific features (arrays, `[[`, etc.)
   - Uses `[ ]` tests only
   - AWK for data processing (not bash regex)
   - `command -v` instead of `which`

### Code Reuse Opportunities

**Directly Reusable:**
- All core data functions (get_worktree_data, etc.)
- Page calculation functions
- Navigation helpers
- Display menu wrapper
- POSIX environment handling
- Session naming logic

**Needs Refactoring:**
- Hardcoded `SCRIPT_PATH` → Use plugin path variable
- Configuration constants → Read from tmux variables
- Main entry point → Plugin loader pattern

**New Code Required:**
- Filter mode implementation (wildcards, not fzf)
- Remote branch fetching
- Plugin loader (`worktrees.tmux`)
- Configuration variable reading
- Test suite

---

## New Features to Implement

### 1. Filter Mode (ALL Menus)

**CRITICAL REQUIREMENT:** Filter mode must be available in **ALL three submenus** (List, Add, Remove) via the **'f' key**.

**User Experience:**
```
┌─────────────────────────────────────┐
│ Worktrees (15 items) - Filter: ""  │
├─────────────────────────────────────┤
│ f › Filter                          │
│ ~/worktrees/feat-A (feat-A)         │
│ ~/worktrees/feat-B (feat-B)         │
│ ~/worktrees/fix-bug (fix-bug)       │
└─────────────────────────────────────┘

[User presses 'f' in any submenu]

┌─────────────────────────────────────┐
│ Filter pattern (wildcards): _       │
└─────────────────────────────────────┘

[User enters: "feat*"]

┌─────────────────────────────────────┐
│ Worktrees (2 items) - Filter: "feat*" │
├─────────────────────────────────────┤
│ f › Filter                          │
│ c › Clear filter                    │
│ ~/worktrees/feat-A (feat-A)         │
│ ~/worktrees/feat-B (feat-B)         │
│ ◀ Previous | Next ▶ | ← Back        │
└─────────────────────────────────────┘
```

**Implementation Requirements:**

1. **Filter Input (Consistent Across All Menus):**
   - Add filter option to **all menu types** (list, add, remove)
   - Key binding: `f` for "Filter" (consistent key in all menus)
   - Use `command-prompt` for pattern input
   - Prompt text: `"Filter pattern (wildcards): "`

2. **Filter Pattern Matching:**
   - POSIX-compliant wildcards (no fzf dependency)
   - Support patterns: `*` (any chars), `?` (single char)
   - Case-insensitive matching
   - Match against branch names (not full paths)

3. **Filter Application:**
   - Modify all data functions to accept optional filter parameter:
     - `get_worktree_data(page, filter)`
     - `get_branch_data(page, filter, include_remotes)`
     - `get_removable_worktree_data(page, filter)`
   - Filter in AWK or grep before pagination
   - Recalculate page counts based on filtered results

4. **Filter State Management:**
   - Pass filter pattern through menu navigation
   - Update page counts dynamically
   - Display active filter in menu title
   - Add "Clear filter" option when filter active

5. **Menu Title Updates:**
   - Unfiltered: `"Worktrees (Page 1/3)"`
   - Filtered: `"Worktrees (Page 1/1) - Filter: 'feat*'"`

**Filter Implementation Pattern:**

```bash
# Modified data function signature (applies to all data functions)
get_worktree_data() {
    local page=${1:-1}
    local filter=${2:-}
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    git worktree list --porcelain | awk -v filter="$filter" '
        BEGIN {
            # Wildcard to regex conversion
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
            }
        }
        /^worktree/ {path=$2;full_path=$2}
        /^branch/ {
            branch=$2
            sub("refs/heads/", "", branch)

            # Filter logic (case-insensitive wildcard matching)
            if (filter == "" || match(tolower(branch), tolower(filter))) {
                # ... existing menu generation logic
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Modified menu function signature (applies to all menu functions)
show_worktree_menu() {
    local page=${1:-1}
    local filter=${2:-}
    local total_pages=$(get_worktree_page_count "$filter")
    local worktree_items=$(get_worktree_data $page "$filter")

    # ALWAYS add filter option (present in all menus)
    local filter_option="\"Filter (f)\" \"f\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $SCRIPT_PATH && show_worktree_menu 1 %1'\"\""

    # Add clear filter option if filter active
    local clear_filter=""
    if [ -n "$filter" ]; then
        clear_filter="\"Clear filter (c)\" \"c\" \"run-shell \\\". $SCRIPT_PATH && show_worktree_menu 1\\\"\""
    fi

    # Update navigation to preserve filter
    local nav_options=$(generate_nav_options $page $total_pages "show_worktree_menu" "$filter")

    # Update title
    local title="Worktrees (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    local all_options="$filter_option $clear_filter $worktree_items $nav_options"
    display_menu "$title" "$all_options"
}
```

**MUST IMPLEMENT FOR:**
- ✅ `show_worktree_menu()` - List menu
- ✅ `show_add_worktree_menu()` - Add menu
- ✅ `show_remove_worktree_menu()` - Remove menu

### 2. Remote Branch Fetching (Add Menu Only)

**User Experience:**
```
┌─────────────────────────────────────┐
│ Add Worktree (Page 1/2)             │
├─────────────────────────────────────┤
│ n › New                             │
│ r › Fetch remote branches...        │
│ f › Filter                          │
│     main                            │
│     develop                         │
│     feat-local-A                    │
└─────────────────────────────────────┘

[User presses 'r']

┌─────────────────────────────────────┐
│ Fetching remote branches...         │
└─────────────────────────────────────┘

[Shows progress, then updates menu]

┌─────────────────────────────────────┐
│ Add Worktree (Page 1/3)             │
├─────────────────────────────────────┤
│ n › New                             │
│ r › Fetch remote branches...        │
│ f › Filter                          │
│     main                            │
│     develop                         │
│     feat-local-A                    │
│   🌐 origin/feat-remote-B            │
│   🌐 origin/user/feature-C           │
└─────────────────────────────────────┘
```

**Implementation Requirements:**

1. **Add Menu Integration:**
   - Add "Fetch remote" option to add menu
   - Key binding: `r` for "Remote"
   - Position: After "New" option, before branch list

2. **Fetch Operation:**
   - Execute `git fetch --all` in background
   - Show progress message: `"Fetching remote branches..."`
   - Timeout: 30 seconds max (handle slow networks)
   - Error handling: Display failure message if fetch fails

3. **Remote Branch Listing:**
   - Include remote branches in `get_branch_data()`
   - Format: `origin/branch-name` with remote prefix
   - Visual indicator: Prefix with "🌐" or "[remote]"
   - Filter to relevant remotes (origin by default)

4. **Branch Creation Logic:**
   - Remote branch selection creates local tracking branch
   - Command: `git worktree add -b branch-name path origin/branch-name`
   - Local branch name: Strip remote prefix (`origin/feat` → `feat`)
   - Handle name conflicts (local branch already exists)

5. **Configuration:**
   - tmux variable: `@worktree-include-remotes` (on/off)
   - tmux variable: `@worktree-auto-fetch` (on/off for automatic fetch)
   - tmux variable: `@worktree-fetch-timeout` (default: 30)

---

## Technical Specifications

### Menu Flow Diagrams

```
Main Menu Flow:
┌─────────────────────────────────────┐
│         Git Worktrees               │
│  l › List    a › Add    r › Remove  │
│              q › Quit                │
└──┬────────────┬────────────┬────────┘
   │            │            │
   ▼            ▼            ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│   List   │ │   Add    │ │  Remove  │
│  Menu    │ │  Menu    │ │   Menu   │
│          │ │          │ │          │
│ f›Filter │ │ f›Filter │ │ f›Filter │
│ (ALWAYS) │ │ (ALWAYS) │ │ (ALWAYS) │
└──┬───────┘ └──┬───────┘ └──┬───────┘
   │            │            │
   │            │            │
   │ ┌──────────▼─────────┐  │
   │ │  r › Fetch Remote  │  │
   │ │  (Add Menu Only)   │  │
   │ └────────────────────┘  │
   │                         │
   └─────────┬───────────────┘
             │
   ┌─────────▼───────────┐
   │  o › Previous Page  │
   │  i › Next Page      │
   │  ⌫ › Back to Main   │
   └─────────────────────┘

Filter Mode (Available in ALL submenus):
┌─────────────────────────────────────┐
│ Any Menu: List/Add/Remove           │
├─────────────────────────────────────┤
│ User presses 'f' key                │
│ ↓                                   │
│ command-prompt: "Filter pattern:"   │
│ ↓                                   │
│ Menu refreshes with filtered items  │
│ + "Clear filter (c)" option added   │
└─────────────────────────────────────┘
```

### Filter Mode State Machine

```
State: UNFILTERED (in any menu)
├─ User presses 'f'
├─ Transition: PROMPT_FILTER
│
State: PROMPT_FILTER
├─ command-prompt "Filter pattern:"
├─ User enters pattern (e.g., "feat*")
├─ Transition: FILTERED
│
State: FILTERED (in same menu)
├─ Display: "... - Filter: 'feat*'"
├─ Options: c › Clear filter (added)
├─ Data: Filtered subset
├─ Pages: Recalculated
│
├─ User presses 'c' → Transition: UNFILTERED
├─ User presses 'f' → Transition: PROMPT_FILTER (change filter)
├─ User navigates pages → Stay: FILTERED (preserve pattern)
└─ User goes back → Transition: UNFILTERED (main menu)
```

### Remote Branch State Machine

```
State: LOCAL_ONLY (Add menu)
├─ Display: Local branches only
├─ Option: r › Fetch remote
├─ Option: f › Filter (always present)
│
├─ User presses 'r'
├─ Action: git fetch --all
├─ Transition: FETCHING
│
State: FETCHING
├─ Display: "Fetching remote branches..."
├─ Timeout: 30s
│
├─ Success → Transition: WITH_REMOTES
├─ Failure → Transition: LOCAL_ONLY (error message)
│
State: WITH_REMOTES (Add menu)
├─ Display: Local + Remote branches (🌐 prefix)
├─ Option: r › Fetch remote (refresh)
├─ Option: f › Filter (always present)
├─ Selection: Creates tracking branch + worktree
│
└─ User presses 'r' again → Transition: FETCHING (refresh)
```

### Configuration Variables

**Plugin Configuration (tmux variables):**

```bash
# Required in plugin loader (worktrees.tmux)
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$PLUGIN_DIR/scripts/worktree_manager.sh"

# User-configurable via .tmux.conf
set -g @worktree-base "$HOME/.tmux-worktree/worktrees"
set -g @worktree-managed-dir "__tmux_managed__"
set -g @worktree-items-per-page "15"
set -g @worktree-include-remotes "on"      # Show remote branches
set -g @worktree-auto-fetch "off"          # Auto-fetch on Add menu open
set -g @worktree-fetch-timeout "30"        # Seconds
set -g @worktree-menu-key "T"              # Main menu key binding

# Feature toggles
set -g @worktree-enable-filter "on"        # Enable filter mode
set -g @worktree-filter-case-sensitive "off"
```

**Reading Configuration in Script:**

```bash
# Helper function to read tmux variable with default
get_tmux_option() {
    local option="$1"
    local default="$2"
    local value=$(tmux show-option -gqv "$option")
    echo "${value:-$default}"
}

# Usage in script
WORKTREE_BASE=$(get_tmux_option "@worktree-base" "$HOME/.tmux-worktree/worktrees")
ITEMS_PER_PAGE=$(get_tmux_option "@worktree-items-per-page" "15")
INCLUDE_REMOTES=$(get_tmux_option "@worktree-include-remotes" "on")
```

### File Structure (Target)

```
tmux-worktree/                      # Git repository root
├── worktrees.tmux                   # Plugin loader (TPM entry point)
├── scripts/
│   ├── worktree_manager.sh          # Core functionality (refactored from current)
│   ├── filter.sh                    # Filter mode implementation
│   ├── remote_branches.sh           # Remote branch handling
│   └── helpers.sh                   # Shared utilities
├── tests/
│   ├── test_list_worktrees.sh       # List menu tests
│   ├── test_add_worktree.sh         # Add menu tests
│   ├── test_remove_worktree.sh      # Remove menu tests
│   ├── test_filter.sh               # Filter mode tests (all menus)
│   ├── test_remote_branches.sh      # Remote branch tests
│   └── helpers/
│       └── test_helpers.sh          # Test utilities
├── docs/
│   ├── configuration.md             # Configuration guide
│   ├── features.md                  # Feature documentation
│   └── development.md               # Development guide
├── README.md                        # Installation and usage
├── CHANGELOG.md                     # Version history
└── LICENSE                          # MIT License
```

---

## Step-by-Step Implementation Plan

### Phase 1: Repository Setup (1-2 hours)

**Goal:** Create TPM-compatible repository structure

**Steps:**

1. **Create new repository:**
   ```bash
   mkdir tmux-worktree
   cd tmux-worktree
   git init
   ```

2. **Create directory structure:**
   ```bash
   mkdir -p scripts tests/helpers docs
   touch worktrees.tmux
   touch scripts/{worktree_manager.sh,filter.sh,remote_branches.sh,helpers.sh}
   touch tests/helpers/test_helpers.sh
   chmod +x worktrees.tmux scripts/*.sh tests/*.sh tests/helpers/*.sh
   ```

3. **Create initial README.md**
4. **Create LICENSE (MIT)**
5. **Initial git commit**

### Phase 2: Plugin Loader Implementation (1 hour)

**Goal:** Create TPM entry point and configuration system

**Steps:**

1. **Implement `worktrees.tmux`:**
   ```bash
   #!/usr/bin/env bash

   CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   SCRIPTS_DIR="$CURRENT_DIR/scripts"

   # Source helpers
   source "$SCRIPTS_DIR/helpers.sh"

   # Set plugin path
   tmux set-environment -g TMUX_WORKTREES_PLUGIN_DIR "$CURRENT_DIR"

   # Get configuration
   MENU_KEY=$(get_tmux_option "@worktree-menu-key" "T")

   # Bind main menu
   tmux bind-key "$MENU_KEY" run-shell "$SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
   ```

2. **Implement `scripts/helpers.sh`:**
   - Copy `get_project_name()` from current script
   - Add `get_tmux_option()` function
   - Add `matches_filter()` for wildcard matching
   - Add `get_session_name()` helper

3. **Test loader**

### Phase 3: Core Functionality Migration (2-3 hours)

**Goal:** Migrate existing script to plugin structure

**Steps:**

1. **Copy current script to `scripts/worktree_manager.sh`**
2. **Refactor configuration:**
   - Remove hardcoded `SCRIPT_PATH`
   - Replace with plugin path variable
   - Replace constants with `get_tmux_option()` calls

3. **Source helpers at top**
4. **Move helper functions to `helpers.sh`**
5. **Test basic functionality with isolated socket**

### Phase 4: Filter Mode Implementation (3-4 hours)

**CRITICAL PHASE:** Must implement filter in **ALL THREE MENUS**

**Goal:** Add filter functionality to all menus (List, Add, Remove)

**Steps:**

1. **Create `scripts/filter.sh`:**
   - Implement wildcard matching function
   - Filter data processing

2. **Modify ALL data functions to accept filter parameter:**
   - `get_worktree_data(page, filter)` - **List menu**
   - `get_branch_data(page, filter, include_remotes)` - **Add menu**
   - `get_removable_worktree_data(page, filter)` - **Remove menu**

3. **Update ALL page count functions:**
   - `get_worktree_page_count(filter)` - **List menu**
   - `get_branch_page_count(filter, include_remotes)` - **Add menu**
   - `get_removable_worktree_page_count(filter)` - **Remove menu**

4. **Update ALL menu functions:**
   - `show_worktree_menu(page, filter)` - **List menu**
     - Add filter option: `f › Filter`
     - Add clear filter: `c › Clear filter` (when active)
   - `show_add_worktree_menu(page, filter, include_remotes)` - **Add menu**
     - Add filter option: `f › Filter`
     - Add clear filter: `c › Clear filter` (when active)
   - `show_remove_worktree_menu(page, filter)` - **Remove menu**
     - Add filter option: `f › Filter`
     - Add clear filter: `c › Clear filter` (when active)

5. **Update navigation helper for filter preservation:**
   ```bash
   generate_nav_options() {
       local page=$1
       local total_pages=$2
       local menu_function=$3
       local filter=${4:-}
       local include_remotes=${5:-false}

       # Navigation preserves filter state
       # ...
   }
   ```

6. **Test filter mode in ALL menus:**
   ```bash
   # Test checklist:
   # 1. List menu: press 'f', enter "main"
   # 2. Add menu: press 'f', enter "feat*"
   # 3. Remove menu: press 'f', enter "*test*"
   # 4. All menus: press 'c' to clear filter
   # 5. All menus: navigate pages with filter active
   ```

### Phase 5: Remote Branch Fetching (3-4 hours)

**Goal:** Add remote branch discovery to Add menu only

**Steps:**

1. **Create `scripts/remote_branches.sh`**
2. **Modify `get_branch_data()` for remotes**
3. **Update `get_branch_page_count()` for remotes**
4. **Update `show_add_worktree_menu()` with fetch option:**
   - Add "Fetch remote (r)" option
   - Implement fetch and refresh workflow
5. **Update navigation helper for 3 parameters**
6. **Source remote functions in main script**
7. **Test remote branches**

### Phase 6: Testing Setup (2-3 hours)

**Goal:** Implement manual testing with isolated tmux socket

**Focus Areas:**
1. Filter mode in **all three menus**
2. Remote branch fetching in Add menu
3. Filter + remote integration
4. Pagination with filter active
5. Clear filter functionality

### Phase 7: Documentation (1-2 hours)

**Goal:** Create comprehensive user and developer documentation

**Emphasize:**
- Filter mode available in ALL menus
- Consistent 'f' key binding across menus
- Remote fetching only in Add menu

### Phase 8: Publishing (1 hour)

**Goal:** Publish plugin to GitHub for TPM installation

---

## Testing Strategy

### Manual Testing with Isolated Socket

**Filter Mode Test Cases (ALL MENUS):**

**List Menu:**
1. Open List menu → press 'f' → enter "main" → verify single result
2. Enter "feat*" → verify multiple feat branches
3. Press 'c' → verify all worktrees shown
4. Filter active → navigate pages → verify filter persists

**Add Menu:**
1. Open Add menu → press 'f' → enter "fix*" → verify filtered branches
2. Clear filter → press 'f' again → enter "origin/*" → verify remote filter
3. With filter active → press 'r' → verify filter persists after fetch

**Remove Menu:**
1. Open Remove menu → press 'f' → enter "*test*" → verify filtered worktrees
2. Remove filtered item → verify menu refreshes with filter still active
3. Press 'c' → verify all removable worktrees shown

**Remote Branch Tests (Add Menu Only):**
1. Press 'r' → verify fetch executes
2. Verify 🌐 prefix on remote branches
3. Select remote → verify tracking branch created
4. Test timeout on slow network

---

## Configuration Design

### tmux Variable Schema

**Full Variable List:**

```bash
# Core
set -g @worktree-base "$HOME/.tmux-worktree/worktrees"
set -g @worktree-managed-dir "__tmux_managed__"

# Display
set -g @worktree-items-per-page "15"
set -g @worktree-menu-key "T"

# Features
set -g @worktree-include-remotes "on"      # on/off
set -g @worktree-auto-fetch "off"          # on/off
set -g @worktree-enable-filter "on"        # on/off
set -g @worktree-filter-case-sensitive "off" # on/off

# Timing
set -g @worktree-fetch-timeout "30"        # seconds
```

---

## Edge Cases and Gotchas

### 1. Session Naming Conflicts
### 2. Slow Remote Fetch
### 3. Filter Pattern Escaping
### 4. Worktree Path Length
### 5. Remote Branch Name Conflicts
### 6. Menu Argument Length Limits
### 7. POSIX Compliance Edge Cases
### 8. Tmux Version Compatibility
### 9. Git Worktree Prune
### 10. Unicode Support

*(See detailed descriptions in full implementation plan)*

---

## README Template

Use this template for the plugin README. Style based on [bench](https://github.com/KakkoiDev/bench).

```markdown
# tmux-worktree

Git worktree management with interactive menus, filtering, and remote branch discovery.

<!-- TODO: Add asciinema recording -->
<!-- <a href="https://asciinema.org/a/XXXXX"><img src="https://asciinema.org/a/XXXXX.svg" width="600"/></a> -->

## Why tmux-worktree?

**The gap:** Managing git worktrees requires multiple commands, and switching between them in tmux means manual session handling.

**tmux-worktree adds:**
- Interactive menu system with pagination
- Filter mode across all menus (wildcards, no fzf required)
- Remote branch discovery for colleague branches
- Automatic tmux session management per worktree

**tmux-worktree doesn't replace** git worktree commands - it wraps them with a tmux-native interface.

## Installation

**With [TPM](https://github.com/tmux-plugins/tpm):**

```bash
# Add to .tmux.conf
set -g @plugin 'username/tmux-worktree'

# Reload tmux and install
# prefix + I
```

**Manual:**

```bash
git clone https://github.com/username/tmux-worktree.git ~/.tmux/plugins/tmux-worktree
# Add to .tmux.conf
run-shell ~/.tmux/plugins/tmux-worktree/worktrees.tmux
```

## Usage

**Open menu:**

```
prefix + T
```

**List worktrees:**

```
T → l (list)
```
Switch to existing session or create new one for selected worktree.

**Add worktree:**

```
T → a (add) → select branch or create new
```

**Remove worktree:**

```
T → r (remove) → select worktree
```
Smart cleanup: managed worktrees delete branch + session, existing branch worktrees keep the branch.

**Filter (available in all menus):**

```
f → enter pattern → filtered results
c → clear filter
```
Supports wildcards: `feat*`, `*auth*`, `fix-???`

**Fetch remote branches:**

```
T → a (add) → r (fetch remote)
```
Discover colleague branches from origin.

### Navigation

| Key | Action |
|-----|--------|
| `l` | List worktrees |
| `a` | Add worktree |
| `r` | Remove worktree |
| `f` | Filter (in any submenu) |
| `c` | Clear filter |
| `n` | New branch (in Add menu) |
| `o` | Previous page |
| `i` | Next page |
| `⌫` | Back to main menu |
| `q` | Quit |

### Options

```bash
# In .tmux.conf
set -g @worktree-base "$HOME/.tmux-worktree/worktrees"  # Worktree location
set -g @worktree-managed-dir "__tmux_managed__"          # Managed worktrees subdir
set -g @worktree-items-per-page "15"                     # Items per menu page
set -g @worktree-menu-key "T"                            # Main menu key
set -g @worktree-include-remotes "on"                    # Show remote branches
set -g @worktree-fetch-timeout "30"                      # Fetch timeout (seconds)
```

### Output

Worktrees are organized as:

```
~/.tmux-worktree/worktrees/
├── __tmux_managed__/           # Plugin-created worktrees
│   ├── feat/new-feature/       # Branch: feat/new-feature
│   └── fix/bug-123/            # Branch: fix/bug-123
└── existing-branch/            # From existing branches
```

Sessions named: `{project}-{branch}` (e.g., `myapp-feat-new-feature`)

## With other tools

**Quick switch with [fzf](https://github.com/junegunn/fzf) (optional):**

```bash
# Add custom binding for fzf-powered switch
bind-key W run-shell "git worktree list | fzf-tmux | awk '{print $1}' | xargs -I {} tmux switch-client -t {}"
```

**Combine with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect):**

Sessions created by tmux-worktree are automatically saved/restored.

**Monitor worktrees with [git-delta](https://github.com/dandavison/delta):**

```bash
# See changes across all worktrees
for wt in $(git worktree list --porcelain | grep worktree | cut -d' ' -f2); do
  echo "=== $wt ===" && git -C "$wt" diff | delta
done
```

## Contributing

```bash
# Development - isolated tmux environment
tmux -L test-worktrees -f /dev/null new-session

# Load plugin manually
~/.tmux/plugins/tmux-worktree/worktrees.tmux

# Run tests
bats tests/
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Philosophy

- **Composable.** Wraps git worktree, enhances tmux.
- **Portable.** POSIX shell, no external dependencies.
- **Filterable.** Find branches fast with wildcards.
- **Session-aware.** One worktree = one tmux session.

## Resources

- [Git Worktrees Documentation](https://git-scm.com/docs/git-worktree)
- [TPM - Tmux Plugin Manager](https://github.com/tmux-plugins/tpm)
- [Command Line Interface Guidelines](https://clig.dev)

## License

[MIT License](LICENSE)
```

---

## Handoff Checklist

Before implementation:
- [ ] Read entire guide thoroughly
- [ ] Understand current `tmux_worktree.sh` architecture
- [ ] Understand filter must work in **ALL** menus (not just conceptual)
- [ ] Have test git repository ready

During implementation:
- [ ] Test filter mode in **each submenu separately**
- [ ] Verify 'f' key works consistently across menus
- [ ] Test filter persistence during pagination
- [ ] Use isolated tmux socket for testing

After completion:
- [ ] Filter works in List menu
- [ ] Filter works in Add menu
- [ ] Filter works in Remove menu
- [ ] Remote fetch works in Add menu
- [ ] All tests pass
- [ ] Published to GitHub

---

**End of Handoff Guide**

This document provides complete implementation details for the tmux-worktree plugin with emphasis on filter mode availability across **all submenus** (List, Add, Remove).
