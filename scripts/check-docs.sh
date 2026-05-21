#!/usr/bin/env bash
# check-docs.sh — Lint all feature docs under docs/features/
#
# Checks:
#   1. For each file listed in frontmatter `files:`, verify it exists in the repo.
#   2. For `last_verified`, warn if older than 60 days from today.
#
# Exit codes:
#   0 — no errors (warnings are OK)
#   1 — one or more errors

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURES_DIR="${REPO_ROOT}/docs/features"

error_count=0
warn_count=0
doc_count=0

# Requires python3 + pyyaml for YAML frontmatter parsing
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: python3 pyyaml is required. Run: python3 -m pip install pyyaml" >&2
    exit 1
fi

# Today's date for staleness check
TODAY=$(python3 -c "from datetime import date; print(date.today().isoformat())")

for md_file in "${FEATURES_DIR}"/*.md; do
    # Skip the template and placeholder
    basename=$(basename "${md_file}")
    if [[ "${basename}" == "_TEMPLATE.md" || "${basename}" == "coming-soon.md" || "${basename}" == "index.md" ]]; then
        continue
    fi

    doc_count=$((doc_count + 1))
    rel_md="docs/features/${basename}"

    # Extract YAML frontmatter between first pair of --- delimiters
    frontmatter=$(python3 - "${md_file}" <<'PYEOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Match frontmatter block: starts with ---, ends with ---
m = re.match(r'^---\n(.*?)\n---\n', content, re.DOTALL)
if m:
    print(m.group(1))
else:
    print("")
PYEOF
)

    if [[ -z "${frontmatter}" ]]; then
        echo "WARNING: ${rel_md}: no YAML frontmatter found — skipping file checks"
        warn_count=$((warn_count + 1))
        continue
    fi

    # Parse frontmatter with pyyaml, extract files and last_verified
    file_check_result=$(python3 - "${REPO_ROOT}" "${rel_md}" <<PYEOF
import sys, yaml

repo_root = sys.argv[1]
rel_md = sys.argv[2]

frontmatter = """${frontmatter}"""

try:
    data = yaml.safe_load(frontmatter)
except yaml.YAMLError as e:
    print(f"YAML_ERROR: {rel_md}: invalid YAML frontmatter: {e}")
    sys.exit(0)

if not isinstance(data, dict):
    print(f"YAML_ERROR: {rel_md}: frontmatter did not parse as a dict")
    sys.exit(0)

# Check files
files = data.get('files', [])
if files:
    for f in files:
        if not isinstance(f, str):
            continue
        # Strip line anchor (e.g. path/to/file.py:123)
        path = f.split(':')[0]
        import os
        full = os.path.join(repo_root, path)
        if not os.path.exists(full):
            print(f"ERROR: {rel_md}: listed file does not exist: {path}")

# Check last_verified staleness
last_verified = data.get('last_verified')
if last_verified:
    from datetime import date, timedelta
    today = date.fromisoformat("${TODAY}")
    try:
        lv = date.fromisoformat(str(last_verified))
        delta = (today - lv).days
        if delta > 60:
            print(f"WARNING: {rel_md}: last_verified={last_verified} is {delta} days ago (>60)")
    except (ValueError, TypeError) as e:
        print(f"WARNING: {rel_md}: last_verified could not be parsed: {last_verified}")
else:
    print(f"WARNING: {rel_md}: missing last_verified in frontmatter")
PYEOF
)

    # Process results line by line
    while IFS= read -r line; do
        if [[ -z "${line}" ]]; then
            continue
        fi
        if [[ "${line}" == ERROR:* ]]; then
            echo "${line}"
            error_count=$((error_count + 1))
        elif [[ "${line}" == WARNING:* || "${line}" == YAML_ERROR:* ]]; then
            echo "${line}"
            warn_count=$((warn_count + 1))
        fi
    done <<< "${file_check_result}"

done

echo ""
echo "Checked ${doc_count} docs, ${error_count} errors, ${warn_count} warnings."

if [[ "${error_count}" -gt 0 ]]; then
    exit 1
fi
exit 0
