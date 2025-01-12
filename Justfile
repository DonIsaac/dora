#!/usr/bin/env -S just --justfile

# Useful resources:
# - Justfile syntax cheatsheet: https://cheatography.com/linux-china/cheat-sheets/justfile/

set windows-shell := ["powershell"]
set shell := ["bash", "-cu"]

alias b   := build
alias c   := check
alias ck  := check
alias f   := fmt
alias t   := test
alias w   := watch

_default:
  @just --list -u

build *ARGS:
  zig build --summary all {{ARGS}}

# Type check and look for semantic errors. Faster than `build`
check:
  zig build check --summary all

run *ARGS:
  zig build run {{ARGS}}

test *ARGS:
  zig build test --summary all {{ARGS}}

# Fix formatting issues and typos
fmt:
  zig fmt src
  typos -w

# Run a command in watch mode. Re-runs whenever a source file changes
watch cmd="check":
    git ls-files | entr -rc just clear-run {{cmd}}

# Clear the screen, then run `zig build {{cmd}}`. Used by `just watch`.
clear-run cmd:
    @clear
    @zig build {{cmd}}
