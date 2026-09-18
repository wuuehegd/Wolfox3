#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$PROJECT_DIR/run_linux_location_tests.sh"
"$PROJECT_DIR/run_linux_identifier_tests.sh"
"$PROJECT_DIR/test_external_maps_static.sh"
"$PROJECT_DIR/test_build_compatibility_static.sh"
"$PROJECT_DIR/test_security_scope_static.sh"
echo "✅ اكتملت جميع اختبارات WolFox المتاحة على لينكس."
