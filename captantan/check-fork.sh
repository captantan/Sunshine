#!/usr/bin/env bash
# captantan fork: check that the fork's changes are in place and upstream's workflows are out.
# Run it after every merge of an upstream release, before pushing. See CAPTANTAN.md.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
check() {
  if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi
}

check "only our workflow is in .github/workflows" \
  '[ "$(git ls-files .github/workflows)" = ".github/workflows/captantan-windows.yml" ] && [ -z "$(ls .github/workflows | grep -v "^captantan-windows.yml$")" ]'
check "src/nvhttp.cpp calls the hook twice" \
  '[ "$(grep -c "captantan::run_pre_display_cmd(\*launch_session)" src/nvhttp.cpp)" = 2 ]'
check "each call comes right before configure_display" \
  '[ "$(grep -A8 "captantan::run_pre_display_cmd(\*launch_session)" src/nvhttp.cpp | grep -c "display_device::configure_display(config::video, \*launch_session);")" = 2 ]'
check "upstream still calls configure_display exactly twice" \
  '[ "$(grep -c "display_device::configure_display(" src/nvhttp.cpp)" = 2 ]'
check "src/nvhttp.cpp includes the hook header" \
  'grep -q "^#include \"captantan/pre_display_cmd.h\"" src/nvhttp.cpp'
check "src/config.cpp reads pre_display_cmd" \
  'grep -q "string_f(vars, \"pre_display_cmd\", captantan::pre_display_cmd);" src/config.cpp && grep -q "^#include \"captantan/pre_display_cmd.h\"" src/config.cpp'
check "the hook source is in the build" \
  'grep -q "src/captantan/pre_display_cmd.cpp" cmake/compile_definitions/common.cmake'
check "the installer ships vdd-prepare.ps1" \
  'grep -q "captantan/vdd-prepare.ps1" cmake/packaging/windows.cmake && [ -f captantan/vdd-prepare.ps1 ]'
check "submodules match the commit" \
  '[ -z "$(git submodule status --recursive | grep "^[-+U]")" ]'

if [ "$fail" -ne 0 ]; then
  echo "Something above needs fixing before you push."
  exit 1
fi
echo "All good."
