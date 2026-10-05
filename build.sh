#!/usr/bin/env bash
# Regenerates driver.xml and the Documentation tab from gen_driver_xml.py and
# packages the .c4z that Composer Pro imports. A .c4z is a zip: driver.xml
# and driver.lua at the root, and the documentation under www/, whose path
# must be kept (driver.xml references www/documentation/index.html).
#
# Needs: python3 with the "markdown" package (pip install markdown), zip,
# and lua5.4 for the tests. luac5.1 is preferred for the syntax check because
# Control4 runs Lua 5.1.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Generating driver.xml and the Documentation tab"
python3 gen_driver_xml.py

echo "==> Checking Lua syntax"
if command -v luac5.1 >/dev/null 2>&1; then
  luac5.1 -p driver.lua && echo "    driver.lua OK (Lua 5.1)"
elif command -v luac >/dev/null 2>&1; then
  luac -p driver.lua && echo "    driver.lua OK"
else
  echo "    luac not found, skipping syntax check"
fi

echo "==> Running tests"
if command -v lua5.4 >/dev/null 2>&1; then
  lua5.4 tests/test_regressions.lua | tail -1
  lua5.4 tests/test_driver.lua | tail -1
else
  echo "    lua5.4 not found, skipping tests"
fi

echo "==> Packaging PimaForce.c4z"
rm -f PimaForce.c4z
zip -q -X PimaForce.c4z driver.xml driver.lua www/documentation/index.html
# The documentation path inside the package must be exactly what driver.xml
# names, or Composer's Documentation tab is empty.
DOC=$(grep -o '<documentation file="[^"]*"' driver.xml | sed 's/.*file="//; s/"$//')
unzip -l PimaForce.c4z | grep -q " ${DOC}\$" \
  || { echo "    ERROR: ${DOC} is referenced by driver.xml but missing from the package"; exit 1; }
VERSION=$(grep -o '<version>[0-9]*</version>' driver.xml | grep -o '[0-9]*')
echo "    PimaForce.c4z  (driver version ${VERSION})"
