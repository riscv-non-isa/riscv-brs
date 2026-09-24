#!/usr/bin/env bash
set -euo pipefail

# Two-digit (fixed-point decimal) release metadata for the RISC-V spec lifecycle.
#
# Versions are `vMAJOR.FRAC` (or semver-shaped `vMAJOR.MINOR.PATCH`) where the
# value is a decimal to hundredths:
# v0.0 = 0.00, v0.6 = 0.60, v0.61 = 0.61, v0.6.1 = 0.601, v0.99 = 0.99,
# v1.0 = 1.00. Ordering is
# therefore DECIMAL, not per-component semver: v0.8 (0.80) > v0.61 (0.61). Do NOT
# compare these with `sort -V` or `git ... --sort=version:refname` -- both order
# the fractional part component-wise and get v0.8 < v0.61 wrong. Use the `compare`
# / `max` / `latest` subcommands here, which compare by centi-value.
#
# Milestones (manual gates, one release each): v0.6 development-complete,
# v0.8 stabilized, v0.9 frozen, v0.99 ratification-ready, v1.0 ratified. v0.0 is
# the inception version. Between milestones, merges to main auto-advance by 0.01
# (v0.61, v0.62, ... v0.79) up to -- but never onto -- the next manual milestone.

DEFAULT_VERSION="v0.0"
DEFAULT_PHASE="draft-and-development"
SPEC_STATE_URL="http://riscv.org/spec-state"

# Repo root, for resolving the committed .docmode switch (see docmode() below) --
# same BASH_SOURCE-relative pattern scripts/stamp-antora-version.sh uses for
# antora.yml, so this works whether invoked as ./scripts/release-info.sh or via
# an absolute/relative path from elsewhere.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

# `next` exits with this code when the auto-increment band is exhausted (the next
# 0.01 step would land on a manual milestone gate). Callers trap it to skip
# tagging rather than hard-fail.
NEXT_AT_MILESTONE_RC=10

usage() {
  cat <<'USAGE'
Usage: scripts/release-info.sh <command> [value ...]

Commands:
  version                 Resolve version from VERSION/RELEASE_VERSION/git tags.
  latest                  Highest valid v* git tag (decimal order), or default.
  normalize <v>           Canonicalize a version string (v0.60 -> v0.6).
  next [v]                Next auto version (+0.01); errors at a milestone gate.
  compare <a> <b>         Print -1 / 0 / 1 for a<b / a==b / a>b (decimal order).
  max <a> <b>             Print the greater of two versions.
  is-milestone <v>        Exit 0 if v is a manual milestone gate.
  mode                    Resolved .docmode: "spec" (default) or "doc".
  phase [v]               Lifecycle phase (state) for a version. Empty in doc mode.
  phase-floor-version <p> Version at the gate of phase p. Empty in doc mode.
  display [v]             Title-case display label for a version's phase. Empty in doc mode.
  milestone [v]           "<gate> <phase>" milestone label. Empty in doc mode.
  notice [v]              Change-control notice text for a version's phase. Empty in doc mode.
  revremark [v]           Revision remark (display label) for a version. Empty in doc mode.
  all                     Emit all of the above as KEY=VALUE lines.
USAGE
}

# .docmode selects the repo's ratification posture: "spec" (default -- today's
# behavior, byte-for-byte) keeps the full phase/milestone surface below; "doc"
# is for non-ratified documentation repos (e.g. docs-dev-guide) and neutralizes
# it -- see phase/display/milestone/notice/revremark/phase-floor-version below.
# Version resolution (get_version and everything derived from it) is UNCHANGED
# by mode: identity still comes from semver git tags + build-date stamping.
docmode() {
  local f="$repo_root/.docmode" v
  if [[ -f "$f" ]]; then
    v="$(head -n1 "$f" | tr -d '[:space:]')"
  else
    v=""
  fi
  case "$v" in
    ""|spec) echo "spec" ;;
    doc)     echo "doc" ;;
    *)
      echo "release-info: unrecognized .docmode value '$v'; defaulting to spec" >&2
      echo "spec"
      ;;
  esac
}

normalize_prefix() {
  local v="$1"
  v="${v##*/}"
  if [[ "$v" != v* ]]; then
    v="v${v}"
  fi
  echo "$v"
}

base_version() {
  local v="$1"
  v="${v#v}"
  v="${v%%+*}"
  v="${v%%-*}"
  echo "$v"
}

version_valid() {
  local v
  v="$(base_version "$1")"
  [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

# Scaled lifecycle value. Legacy two-component versions use hundredths, while
# the optional patch component occupies three decimal places. This keeps the
# existing ordering (v0.8 > v0.61) and makes v0.6.1 sort between v0.6 and v0.61.
centi_of() {
  local v major frac patch scale
  v="$(base_version "$1")"
  IFS='.' read -r major frac patch <<<"$v"
  frac="${frac:-0}"
  if [[ -n "${patch:-}" ]]; then
    frac="${frac}0"
    frac="${frac:0:2}"
    scale=1000
    echo $(( 10#$major * 100000 + 10#$frac * scale + 10#$patch ))
  else
    frac="${frac}00"
    frac="${frac:0:2}"
    echo $(( 10#$major * 100000 + 10#$frac * 1000 ))
  fi
}

is_milestone_centi() {
  case "$1" in
  60000|80000|90000|99000|100000) return 0 ;;
    *)               return 1 ;;
  esac
}

# Canonical short (policy) form for a milestone centi-value.
milestone_string_for_centi() {
  case "$1" in
    0)      echo "v0.0"  ;;
    60000)  echo "v0.6"  ;;
    80000)  echo "v0.8"  ;;
    90000)  echo "v0.9"  ;;
    99000)  echo "v0.99" ;;
    100000) echo "v1.0"  ;;
    *)   return 1     ;;
  esac
}

# Format an arbitrary centi-value as a version string. Milestone values use the
# short policy form (60 -> v0.6); non-milestone auto values use the two-digit
# fractional form (70 -> v0.70, 5 -> v0.05).
format_centi() {
  local c="$1" major frac
  major=$(( c / 100000 ))
  frac=$(( (c % 100000) / 1000 ))
  if milestone_string_for_centi "$c" >/dev/null 2>&1; then
    milestone_string_for_centi "$c"
  elif (( frac == 0 )); then
    printf 'v%d.0\n' "$major"
  else
    printf 'v%d.%02d\n' "$major" "$frac"
  fi
}

canonical_version() {
  local v="$1" suffix="" major frac patch
  if [[ "$v" == *-* ]]; then
    suffix="-${v#*-}"
    v="${v%%-*}"
  fi
  if [[ "$(base_version "$v")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r major frac patch <<<"$(base_version "$v")"
    printf 'v%d.%d.%d%s\n' "$((10#$major))" "$((10#$frac))" "$((10#$patch))" "$suffix"
    return 0
  fi
  echo "$(format_centi "$(centi_of "$v")")${suffix}"
}

version_ge() {
  local a b
  a="$(centi_of "$1")"
  b="$(centi_of "$2")"
  (( a >= b ))
}

compare_versions() {
  local a b
  a="$(centi_of "$1")"
  b="$(centi_of "$2")"
  if (( a < b )); then
    echo -1
  elif (( a > b )); then
    echo 1
  else
    echo 0
  fi
}

max_version() {
  if version_ge "$1" "$2"; then
    canonical_version "$1"
  else
    canonical_version "$2"
  fi
}

next_version() {
  local c n
  c="$(centi_of "$1")"

  if (( c >= 100000 )); then
    echo "release-info: $1 is at or past v1.0 (ratified); no automatic successor." >&2
    exit 2
  fi

  n=$(( c + 1000 ))
  if is_milestone_centi "$n"; then
    local ms
    ms="$(milestone_string_for_centi "$n")"
    echo "release-info: next step $ms is a manual milestone gate; cut it via workflow_dispatch (target_phase or release_version)." >&2
    exit "$NEXT_AT_MILESTONE_RC"
  fi

  format_centi "$n"
}

# Highest valid v* tag by decimal (centi) order from origin's advertised tags --
# git's version sort cannot be trusted for this scheme (it would rank v0.8 below
# v0.61). The local-tag fallback is for callers without a reachable origin,
# such as isolated test clones.
latest_tag() {
  local best="" bestc=-1 t tc ref remote_tags=1
  local tag_args=()
  if command -v git >/dev/null 2>&1; then
    if git remote get-url origin >/dev/null 2>&1; then
      while IFS=$'\t' read -r _ ref; do
        t="${ref#refs/tags/}"
        t="${t%\^\{\}}"
        [[ -n "$t" ]] || continue
        version_valid "$t" || continue
        tc="$(centi_of "$t")"
        if (( tc > bestc )); then
          bestc="$tc"
          best="$t"
        fi
      done < <(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null || remote_tags=0)
      (( remote_tags == 1 )) && [[ -n "$best" ]] && {
        canonical_version "$best"
        return 0
      }
    fi
    if git rev-parse --verify --quiet origin/HEAD >/dev/null 2>&1; then
      tag_args=(--merged origin/HEAD)
    fi
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      version_valid "$t" || continue
      tc="$(centi_of "$t")"
      if (( tc > bestc )); then
        bestc="$tc"
        best="$t"
      fi
    done < <(git tag "${tag_args[@]}" --list 'v*' 2>/dev/null || true)
  fi
  if [[ -n "$best" ]]; then
    canonical_version "$best"
  else
    echo "$DEFAULT_VERSION"
  fi
}

get_version() {
  local v=""

  if [[ -n "${VERSION:-}" ]]; then
    v="$VERSION"
  elif [[ -n "${RELEASE_VERSION:-}" ]]; then
    v="$RELEASE_VERSION"
  elif [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    if version_valid "$GITHUB_REF_NAME"; then
      v="$GITHUB_REF_NAME"
    fi
  elif [[ -n "${GITHUB_REF:-}" ]]; then
    local ref="${GITHUB_REF##*/}"
    if version_valid "$ref"; then
      v="$ref"
    fi
  fi

  if [[ -n "$v" ]] && version_valid "$v"; then
    canonical_version "$v"
    return 0
  fi

  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    local exact_tag
    exact_tag="$(git tag --points-at HEAD --list 'v*' 2>/dev/null | head -n1 || true)"
    if [[ -n "$exact_tag" ]] && version_valid "$exact_tag"; then
      canonical_version "$exact_tag"
      return 0
    fi

    # Untagged: <latest tag>-<sha>, with NO date folded in. The build date
    # already reaches every artifact independently -- the Makefile passes it as
    # revdate and appends DATE_STAMP to the ARC filename -- so embedding it here
    # too stamped local PDFs with the date twice (spec-v0.6-abc-20260812-20260812
    # .pdf), which is not ARC-compliant. The sha alone keeps the build uniquely
    # identifiable and marks it as not built from a tag.
    local latest short_sha
    latest="$(latest_tag)"
    short_sha="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    echo "${latest}-${short_sha}"
    return 0
  fi

  latest_tag
}

phase_display_for_phase() {
  case "$1" in
    "draft-and-development") echo "Draft and Development" ;;
    "development-complete")  echo "Development Complete"  ;;
    "stabilized")            echo "Stabilized"            ;;
    "frozen")                echo "Frozen"                ;;
    "ratification-ready")    echo "Ratification-Ready"    ;;
    "ratified")              echo "Ratified"              ;;
    *)                       echo "Draft"                 ;;
  esac
}

phase_for_version() {
  local v="$1" c major minor patch lifecycle

  if ! version_valid "$v"; then
    echo "$DEFAULT_PHASE"
    return 0
  fi

  # In X.Y.Z versions, preserve the old lifecycle progression for the 0.Y
  # line: Y carries the state and Z is its patch component. Once the major
  # line is 1, X.0.Z carries the state in Z, while 1.Y.Z (Y > 0) is ratified.
  if [[ "$(base_version "$v")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r major minor patch <<<"$(base_version "$v")"
    if (( 10#$major == 0 )); then
      lifecycle="${minor}0"
      lifecycle="${lifecycle:0:2}"
      c=$(( 10#$lifecycle * 1000 ))
    elif (( 10#$minor > 0 )); then
      c=100000
    else
      lifecycle="${patch}0"
      lifecycle="${lifecycle:0:2}"
      c=$(( 10#$lifecycle * 1000 ))
    fi
  else
    c="$(centi_of "$v")"
  fi

  if (( c >= 100000 )); then
    echo "ratified"
  elif (( c >= 99000 )); then
    echo "ratification-ready"
  elif (( c >= 90000 )); then
    echo "frozen"
  elif (( c >= 80000 )); then
    echo "stabilized"
  elif (( c >= 60000 )); then
    echo "development-complete"
  else
    echo "draft-and-development"
  fi
}

milestone_for_phase() {
  case "$1" in
    "development-complete") echo "v0.6 development-complete" ;;
    "stabilized")          echo "v0.8 stabilized"           ;;
    "frozen")              echo "v0.9 frozen"               ;;
    "ratification-ready")  echo "v0.99 ratification-ready"  ;;
    "ratified")            echo "v1.0 ratified"             ;;
    *)                     echo "draft-and-development"     ;;
  esac
}

milestone_for_version() {
  local v="$1" phase="$2" base
  base="$(base_version "$v")"
  if [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'v%s %s\n' "$base" "$phase"
  else
    milestone_for_phase "$phase"
  fi
}

phase_floor_version() {
  case "$1" in
    "draft-and-development") echo "v0.0"  ;;
    "development-complete")  echo "v0.6"  ;;
    "stabilized")            echo "v0.8"  ;;
    "frozen")                echo "v0.9"  ;;
    "ratification-ready")    echo "v0.99" ;;
    "ratified")              echo "v1.0"  ;;
    *)
      echo "Unknown phase '$1'" >&2
      return 2
      ;;
  esac
}

notice_for_phase() {
  case "$1" in
    "draft-and-development")
      echo "Assume everything is subject to change. At this stage, ideas, structures, and content are still evolving. Feedback and iteration are encouraged as nothing is final, and adjustments may be frequent."
      ;;
    "development-complete")
      echo "Assume everything is subject to change. At this stage, ideas, structures, and content are still evolving. Feedback and iteration are encouraged as nothing is final, and adjustments may be frequent."
      ;;
    "stabilized")
      echo "Changes may still occur, but they should be limited in scope. The core structure and content are mostly settled, with only refinements or necessary adjustments expected. Any modifications should be carefully considered to maintain stability."
      ;;
    "frozen")
      echo "Changes are highly unlikely. A high threshold will be applied, and modifications will only be made in response to critical issues. Any other proposed changes should be addressed through a follow-on extension."
      ;;
    "ratification-ready")
      echo "The specification is preparing for ratification. Only critical, ratification-blocking issues should be considered for change."
      ;;
    "ratified")
      echo "No changes are allowed. Any necessary or desired modifications must be addressed through a follow-on extension. Ratified extensions are never revised."
      ;;
    *)
      echo "Assume everything is subject to change until a formal milestone is reached."
      ;;
  esac
}

revremark_for_phase() {
  phase_display_for_phase "$1"
}

phase_from_input() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    phase_for_version "$(get_version)"
  elif version_valid "$input"; then
    phase_for_version "$input"
  else
    echo "$input"
  fi
}

command="${1:-all}"
value="${2:-}"

# Neutralize the phase surface in doc mode: these commands short-circuit to an
# empty value before touching any version/phase machinery, so every consumer
# (Makefile, stamp-antora-version.sh) sees "" rather than a spec-mode label.
case "$command" in
  phase|phase-floor-version|display|milestone|notice|revremark)
    if [[ "$(docmode)" == "doc" ]]; then
      echo ""
      exit 0
    fi
    ;;
esac

case "$command" in
  version)
    get_version
    ;;
  latest)
    latest_tag
    ;;
  mode)
    docmode
    ;;
  normalize)
    if [[ -z "$value" ]]; then
      echo "normalize requires a version value" >&2
      exit 2
    fi
    if ! version_valid "$value"; then
      echo "invalid version: $value" >&2
      exit 2
    fi
    canonical_version "$value"
    ;;
  next)
    if [[ -z "$value" ]]; then
      value="$(get_version)"
    fi
    if ! version_valid "$value"; then
      echo "invalid version: $value" >&2
      exit 2
    fi
    next_version "$value"
    ;;
  compare)
    if [[ -z "$value" || -z "${3:-}" ]]; then
      echo "compare requires two version values" >&2
      exit 2
    fi
    if ! version_valid "$value" || ! version_valid "$3"; then
      echo "invalid version(s): $value $3" >&2
      exit 2
    fi
    compare_versions "$value" "$3"
    ;;
  max)
    if [[ -z "$value" || -z "${3:-}" ]]; then
      echo "max requires two version values" >&2
      exit 2
    fi
    if ! version_valid "$value" || ! version_valid "$3"; then
      echo "invalid version(s): $value $3" >&2
      exit 2
    fi
    max_version "$value" "$3"
    ;;
  is-milestone)
    if [[ -z "$value" ]] || ! version_valid "$value" || [[ "$value" == *-* ]]; then
      exit 1
    fi
    is_milestone_centi "$(centi_of "$value")"
    ;;
  phase)
    if [[ -z "$value" ]]; then
      value="$(get_version)"
    fi
    phase_for_version "$value"
    ;;
  phase-floor-version)
    if [[ -z "$value" ]]; then
      value="$(phase_for_version "$(get_version)")"
    fi
    phase_floor_version "$value"
    ;;
  display)
    if [[ -z "$value" ]]; then
      value="$(get_version)"
    fi
    phase_display_for_phase "$(phase_for_version "$value")"
    ;;
  milestone)
    phase="$(phase_from_input "$value")"
    if [[ -n "$value" ]] && version_valid "$value"; then
      milestone_for_version "$value" "$phase"
    else
      milestone_for_phase "$phase"
    fi
    ;;
  notice)
    phase="$(phase_from_input "$value")"
    notice_for_phase "$phase"
    ;;
  revremark)
    phase="$(phase_from_input "$value")"
    revremark_for_phase "$phase"
    ;;
  all|"")
    mode="$(docmode)"
    version="$(get_version)"
    if [[ "$mode" == "doc" ]]; then
      phase="" display="" milestone="" notice="" revremark=""
    else
      phase="$(phase_for_version "$version")"
      display="$(phase_display_for_phase "$phase")"
      milestone="$(milestone_for_phase "$phase")"
      notice="$(notice_for_phase "$phase")"
      revremark="$(revremark_for_phase "$phase")"
    fi
    printf 'MODE=%s\nVERSION=%s\nPHASE=%s\nPHASE_DISPLAY=%s\nMILESTONE=%s\nPHASE_NOTICE=%s\nREVMARK=%s\n' \
      "$mode" "$version" "$phase" "$display" "$milestone" "$notice" "$revremark"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
