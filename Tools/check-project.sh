#!/usr/bin/env bash
# The project checks CI runs besides the tests (.github/workflows/ci.yml), to run here first:
#   - every key in the String Catalog has German or is marked "Don't Translate"
#   - Diderot.xcodeproj is what xcodegen makes of project.yml
#   - sheets, full-screen covers and popovers open links as the page does (`linkSheet` and its siblings)
#   - the dev tools keep passwords and tokens off command lines (Tools/dev_api.py), and its tests pass
#   - the shell scripts pass shellcheck
# Needs xcodegen and shellcheck (Homebrew); CI pins the versions this was last run with.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 Tools/localize.py --missing

# Generated in place, so its paths stay those of the repository; git then shows any difference.
xcodegen generate --quiet
if [ -n "$(git status --porcelain -- Diderot.xcodeproj)" ]; then
  git status --short -- Diderot.xcodeproj
  echo "Diderot.xcodeproj differs from what xcodegen makes of project.yml: run xcodegen generate and commit the result." >&2
  exit 1
fi

# Presented without `linkSheet` and its siblings (Diderot/Rendering/ExternalLinks.swift), a sheet got the handler of
# the view that showed it, which can't present over it: its links did nothing.
if grep -rnE '\.(sheet|fullScreenCover|popover)\(' Diderot --include='*.swift' \
  | grep -v '^Diderot/Rendering/ExternalLinks\.swift:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; then
  echo "Present these with linkSheet, linkFullScreenCover or linkPopover (Diderot/Rendering/ExternalLinks.swift)." >&2
  exit 1
fi

# On a command line, ps shows a password or token to every user of the Mac: a token in a header, .env read by the
# shell (which also expands $ in it), or the app's sign-in as devicectl's JSON. (The brackets keep this line out.)
if grep -nE 'Bear[e]r|(sourc[e]|^[[:space:]]*\.) \.env|--environment-variable[s]' Tools/*.sh; then
  echo "Read .env with Tools/dev_api.py setting, call the API with Tools/dev_api.py call or upload, and hand the app its sign-in in the environment (SIMCTL_CHILD_*, DEVICECTL_CHILD_*, TEST_RUNNER_*)." >&2
  exit 1
fi

# Plain http only to this Mac, no token along a redirect, the dev users' made-up passwords: against a stand-in server.
python3 Tools/test_dev_api.py -q

shellcheck -S warning Tools/*.sh
echo "Project checks passed."
