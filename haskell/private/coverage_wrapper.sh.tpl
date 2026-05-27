#!/usr/bin/env bash
# A wrapper for Haskell binaries which have been instrumented for hpc code coverage.

# Sources rules_haskell's vendored copy of Bazel's bash runfiles
# library (haskell/private/runfiles.bash). Vendored rather than
# referenced via @bazel_tools//tools/bash/runfiles:runfiles because
# bzlmod remaps that label to @rules_shell//shell/runfiles:runfiles,
# an alias that resolves to a sh_library (not a single file) under
# rules_shell 0.6+. See haskell/defs.bzl `_bash_runfiles` attr for
# details.
#
# Path components reflect rules_haskell's bzlmod canonical repo
# name (`rules_haskell+` under Bazel 9; `rules_haskell` under
# Bazel 8). We try both so the template stays portable across
# Bazel versions.
set -euo pipefail
RH_RUNFILES_PATH_BZLMOD="rules_haskell+/haskell/private/runfiles.bash"
RH_RUNFILES_PATH_LEGACY="rules_haskell/haskell/private/runfiles.bash"
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/${RH_RUNFILES_PATH_BZLMOD}" || -f "$0.runfiles/${RH_RUNFILES_PATH_LEGACY}" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi
_rh_source_runfiles() {
  local d="${RUNFILES_DIR:-/dev/null}"
  if [[ -f "$d/$RH_RUNFILES_PATH_BZLMOD" ]]; then
    # shellcheck source=/dev/null
    source "$d/$RH_RUNFILES_PATH_BZLMOD" && return 0
  elif [[ -f "$d/$RH_RUNFILES_PATH_LEGACY" ]]; then
    # shellcheck source=/dev/null
    source "$d/$RH_RUNFILES_PATH_LEGACY" && return 0
  fi
  return 1
}
if ! _rh_source_runfiles; then
  if [[ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
    _rh_manifest_path="$(grep -m1 "^rules_haskell[+]*/haskell/private/runfiles.bash " \
            "$RUNFILES_MANIFEST_FILE" | cut -d ' ' -f 2-)"
    if [[ -n "$_rh_manifest_path" && -f "$_rh_manifest_path" ]]; then
      # shellcheck source=/dev/null
      source "$_rh_manifest_path"
    else
      echo >&2 "ERROR: cannot find rules_haskell vendored runfiles.bash in manifest"
      exit 1
    fi
  else
    echo >&2 "ERROR: cannot locate rules_haskell vendored runfiles.bash"
    exit 1
  fi
fi
# --- end runfiles.bash initialization ---

ERRORCOLOR='\033[1;31m'
CLEARCOLOR='\033[0m'
# Variables quoted in bazel (shell.quote) should not
# be quoted twice (export f=f; "'$f'" gets evaluated to 'f', not f).
# Hence why we need to turn off shellcheck's SC1083 on already quoted variables.
# shellcheck disable=SC1083
binary_path=$(rlocation {binary_path})
# shellcheck disable=SC1083
hpc_path=$(rlocation {hpc_path})
# shellcheck disable=SC1083
tix_file_path={tix_file_path}
# shellcheck disable=SC1083
coverage_report_format={coverage_report_format}
# shellcheck disable=SC1083
strict_coverage_analysis={strict_coverage_analysis}
# shellcheck disable=SC1083
package_path={package_path}

# either of the two expected coverage metrics should be set to -1 if they're meant to be unused
# shellcheck disable=SC1083
expected_covered_expressions_percentage={expected_covered_expressions_percentage}
# shellcheck disable=SC1083
expected_uncovered_expression_count={expected_uncovered_expression_count}

# gather the hpc directories
hpc_dir_args=()
# We want word splitting on mix_file_paths, that holds a list of values
# shellcheck disable=SC1083
mix_file_paths={mix_file_paths}
for m in "${mix_file_paths[@]}"
do
  absolute_mix_file_path=$(rlocation "$m")
  hpc_parent_dir=$(dirname "$absolute_mix_file_path")
  trimmed_hpc_parent_dir="${hpc_parent_dir%%_.hpc*}"
  hpc_dir_args+=("--hpcdir=${trimmed_hpc_parent_dir}_.hpc")
done

# gather the modules to exclude from the coverage analysis
hpc_exclude_args=()
# We want word splitting on modules_to_exclude, that holds a list of values
# shellcheck disable=SC1083
modules_to_exclude={modules_to_exclude}
for m in "${modules_to_exclude[@]}"
do
  hpc_exclude_args+=("--exclude=$m")
done

# run the test binary, and then generate the report
$binary_path "$@" > /dev/null 2>&1

# Persist the coverage inputs (.tix + the .mix dirs) into the test's
# undeclared outputs. Bazel keeps these as a stable per-target artifact
# under bazel-testlogs/<target>/test.outputs/, so the lcov post-processor
# (scripts/coverage.sh) reads complete, deterministic per-target data.
# Without this the .tix lives ONLY in the ephemeral sandbox, which
# Bazel's sandbox-stash pool evicts once there are many tests — silently
# under-counting coverage (a gate that can falter is worse than none).
if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ] && [ -f "$tix_file_path" ]; then
  cp "$tix_file_path" "$TEST_UNDECLARED_OUTPUTS_DIR/" 2>/dev/null || true
  mkdir -p "$TEST_UNDECLARED_OUTPUTS_DIR/mix"
  for _hd in "${hpc_dir_args[@]}"; do
    _d="${_hd#--hpcdir=}"
    [ -d "$_d" ] && cp -r "$_d" "$TEST_UNDECLARED_OUTPUTS_DIR/mix/" 2>/dev/null || true
  done
fi

$hpc_path report "$tix_file_path" "${hpc_dir_args[@]}" "${hpc_exclude_args[@]}" \
  --srcdir "." --srcdir "$package_path" > __hpc_coverage_report

# if we want a text report, just output the file generated in the previous step
if [ "$coverage_report_format" == "text" ]
then
  echo "Overall report"
  cat __hpc_coverage_report
fi

# check the covered expression percentage, and if it matches our expectations
if [ "$expected_covered_expressions_percentage" -ne -1 ]
then
  covered_expression_percentage=$(grep "expressions used" __hpc_coverage_report | cut -c 1-3)
  if [ "$covered_expression_percentage" -lt "$expected_covered_expressions_percentage" ]
  then
    echo -e "\n==>$ERRORCOLOR Inadequate expression coverage percentage.$CLEARCOLOR"
    echo -e "==> Expected $expected_covered_expressions_percentage%, but the actual coverage was $ERRORCOLOR$((covered_expression_percentage))%$CLEARCOLOR.\n"
    exit 1
  elif [ "$strict_coverage_analysis" == "True" ] && [ "$covered_expression_percentage" -gt "$expected_covered_expressions_percentage" ]
  then
    echo -e "\n==>$ERRORCOLOR ** BECAUSE STRICT COVERAGE ANALYSIS IS ENABLED **$CLEARCOLOR"
    echo -e "==> Your coverage percentage is now higher than expected.$CLEARCOLOR"
    echo -e "==> Expected $expected_covered_expressions_percentage% of expressions covered, but the actual value is $ERRORCOLOR$((covered_expression_percentage))%$CLEARCOLOR."
    echo -e "==> Please increase the expected coverage percentage to match.\n"
    exit 1
  fi
fi

# check how many uncovered expressions there are, and if that number matches our expectations
if [ "$expected_uncovered_expression_count" -ne -1 ]
then
  coverage_numerator=$(grep "expressions used" __hpc_coverage_report | sed s:.*\(::g | cut -f1 -d "/")
  coverage_denominator=$(grep "expressions used" __hpc_coverage_report | sed s:.*/::g | cut -f1 -d ")")
  uncovered_expression_count="$((coverage_denominator - coverage_numerator))"
  if [ "$uncovered_expression_count" -gt "$expected_uncovered_expression_count" ]
  then
    echo -e "\n==>$ERRORCOLOR Too many uncovered expressions.$CLEARCOLOR"
    echo -e "==> Expected $expected_uncovered_expression_count uncovered expressions, but the actual count was $ERRORCOLOR$((uncovered_expression_count))$CLEARCOLOR.\n"
    exit 1
  elif [ "$strict_coverage_analysis" == "True" ] && [ "$uncovered_expression_count" -lt "$expected_uncovered_expression_count" ]
  then
    echo -e "\n==>$ERRORCOLOR ** BECAUSE STRICT COVERAGE ANALYSIS IS ENABLED **$CLEARCOLOR"
    echo -e "==>$ERRORCOLOR Your uncovered expression count is now lower than expected.$CLEARCOLOR"
    echo -e "==> Expected $expected_uncovered_expression_count uncovered expressions, but there is $ERRORCOLOR$((uncovered_expression_count))$CLEARCOLOR."
    echo -e "==> Please lower the expected uncovered expression count to match.\n"
    exit 1
  fi
fi

# if we want an html report, run the hpc binary again with the "markup" command,
# and feed its generated files into stdout, wrapped in XML tags
if [ "$coverage_report_format" == "html" ]
then
  $hpc_path markup "$tix_file_path" "${hpc_dir_args[@]}" "${hpc_exclude_args[@]}" \
    --srcdir "." --srcdir "$package_path" --destdir=hpc_out > /dev/null 2>&1
  cd hpc_out
  echo "COVERAGE REPORT BELOW"
  echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
  for file in *.html **/*.hs.html; do
    [ -e "$file" ] || continue
    echo "<coverage-report-part name=\"$file\">"
    echo '<![CDATA['
    cat "$file"
    echo ']]>'
    echo "</coverage-report-part>"
  done
  echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
fi
