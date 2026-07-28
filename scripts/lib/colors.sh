#!/bin/bash
# Shared ANSI color codes for terminal output. Not meant to be run directly.
# Usage: source this file, then use $GREEN/$YELLOW/$RED/$CYAN/$NC in echo -e.

# shellcheck disable=SC2034 # used by scripts that source this file
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
