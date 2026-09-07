#!/usr/bin/env bash
# Regenerates driver.xml from gen_driver_xml.py and packages the .c4z that
# Composer Pro imports. A .c4z is just a zip of driver.xml + driver.lua with
# no directory structure.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Generating driver.xml"
python3 gen_driver_xml.py

echo "==> Checking Lua syntax"
if command -v luac >/dev/null 2>&1; then
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
zip -j -q PimaForce.c4z driver.xml driver.lua
VERSION=$(grep -o '<version>[0-9]*</version>' driver.xml | grep -o '[0-9]*')
echo "    PimaForce.c4z  (driver version ${VERSION})"
