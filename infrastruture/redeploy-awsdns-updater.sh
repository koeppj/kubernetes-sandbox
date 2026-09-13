#!/bin/bash
set -euo pipefail
#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source "$SCRIPT_DIR/../.env"
"$SCRIPT_DIR/scripts/build-import-awsdns.sh"
"$SCRIPT_DIR/scripts/deploy-awsdns.sh"
