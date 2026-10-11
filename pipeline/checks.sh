#!/usr/bin/env bash
# Deterministic team-rule checks for a pull request (docs/review-standard.md, items marked [CI]).
# Runs BEFORE the AI review. No network, no dependencies — git, grep and bash only.
#
#   usage: bash pipeline/checks.sh <base-sha> [<head-ref>]
#
# Failing checks (exit 1):  К4, К6, К9, К11, В3
# Warnings only (exit 0):   К2, К3, К5, К8, В4 (email)
# Output uses GitHub Actions annotations (::error / ::warning); locally it is plain text.

set -uo pipefail
export LC_ALL=C.UTF-8

BASE="${1:?usage: checks.sh <base-sha> [<head-ref>]}"
HEAD="${2:-HEAD}"
FAILED=0

fail() { echo "::error title=$1::$2"; FAILED=1; }
warn() { echo "::warning title=$1::$2"; }

# Added lines (without the leading "+") in the given paths.
added()   { git diff -U0 "$BASE" "$HEAD" -- "$@" | grep -E '^\+[^+]' | cut -c2-; }
# Removed lines (without the leading "-") in the given paths.
removed() { git diff -U0 "$BASE" "$HEAD" -- "$@" | grep -E '^-[^-]' | cut -c2-; }
changed_files() { git diff --name-only "$BASE" "$HEAD" -- "$@"; }

# --- К6: public API change without a CHANGELOG entry (fail) -------------------
api_change=$( { git diff -U0 "$BASE" "$HEAD" -- 'app/src/*.js' | grep -E '^[+-]([[:space:]]*|[^+-].*\b)export\b'; \
                git diff --name-only --diff-filter=AD "$BASE" "$HEAD" -- 'app/src/*.js'; } )
if [ -n "$api_change" ] && [ -z "$(changed_files app/CHANGELOG.md)" ]; then
  fail "К6 CHANGELOG" "exports in app/src changed, but app/CHANGELOG.md was not updated in this PR"
fi

# --- К4: money formatted for humans inside src/ (fail) ----------------------
money=$(added 'app/src/*.js' | grep -nE 'грн|toFixed\(|/ *100\b|toLocaleString\(')
if [ -n "$money" ]; then
  fail "К4 money" "money must leave src/ as integer kopecks only; found: $(echo "$money" | head -3 | tr '\n' ' ')"
fi

# --- К11: text addressed to tools or reviewers (fail) -----------------------
k11='(code[ -]?review|reviewer|рев.?ю(ер|ю)|ignore (all |any )?(previous|prior)|do not report|don.t report|already approved|\blgtm\b|@coderabbit|\bclaude\b|copilot|chatgpt|note for ai)'
asks=$(added 'app/**' | grep -inE "$k11")
if [ -n "$asks" ]; then
  fail "К11 text for tools" "added text addresses reviewers or tools: $(echo "$asks" | head -3 | tr '\n' ' ')"
fi

# --- К9: new access check without a denied-access test (fail) ---------------
if added 'app/src/*.js' | grep -qE 'requireRole|AccessDenied'; then
  if ! added 'app/test/*.js' | grep -q 'AccessDenied'; then
    fail "К9 denied test" "new code checks access (requireRole/AccessDenied), but no added test expects AccessDenied"
  fi
fi

# --- В3: no npm dependencies in app/ (fail) ---------------------------------
if added app/package.json | grep -qE '"(dependencies|devDependencies|peerDependencies|optionalDependencies)"'; then
  fail "В3 dependencies" "app/package.json gains a dependencies section"
fi
if [ -n "$(changed_files 'app/package-lock.json' 'app/yarn.lock' 'app/pnpm-lock.yaml')" ]; then
  fail "В3 lockfile" "a lockfile was added or changed in app/"
fi
bare=$(added 'app/**/*.js' | grep -E "^\s*import\b.*\bfrom\s+['\"][^'\"]+['\"]|\bimport\(\s*['\"]|\brequire\(\s*['\"]" \
       | grep -vE "['\"](node:|\./|\.\./)")
if [ -n "$bare" ]; then
  fail "В3 imports" "imports outside node: and relative modules: $(echo "$bare" | head -3 | tr '\n' ' ')"
fi

# --- К2: email/phone returned from a module that never logs access (warn) ----
for f in $(changed_files 'app/src/*.js'); do
  [ -f "$f" ] || continue
  if added "$f" | grep -qE '\b(email|phone)\b' && ! grep -q 'logAccess' "$f"; then
    warn "К2 access log" "$f adds email/phone but never calls logAccess"
  fi
done

# --- К3: file system access without a stay-inside-the-folder check (warn) ----
for f in $(changed_files 'app/src/*.js'); do
  [ -f "$f" ] || continue
  if added "$f" | grep -qE 'readFile|writeFile|createReadStream|createWriteStream|\bfs\.|path\.join' \
     && ! grep -qE 'startsWith\(|path\.relative\(' "$f"; then
    warn "К3 path" "$f touches the file system without checking the resolved path stays inside the allowed folder"
  fi
done

# --- К5: local-time date arithmetic (warn) -----------------------------------
dates=$(added 'app/src/*.js' | grep -nE '\.(getDate|getMonth|getFullYear|getHours|setDate|setMonth|setFullYear)\(|new Date\(\s*["'\''`]')
if [ -n "$dates" ]; then
  warn "К5 dates" "local-time date methods or Date(string) in src: $(echo "$dates" | head -3 | tr '\n' ' ')"
fi

# --- К8: weakened assertions (warn) ------------------------------------------
lost=$(removed 'app/test/*.js' | grep -cE 'assert\.(equal|deepEqual|strictEqual|deepStrictEqual|throws|rejects)\(')
loose=$(added 'app/test/*.js' | grep -nE 'assert\.ok\(|assert\.notEqual\(.*, *0\)|> *0\)')
if [ "$lost" -gt 0 ] && [ -n "$loose" ]; then
  warn "К8 weakened test" "$lost exact assertion(s) removed and loose ones added: $(echo "$loose" | head -3 | tr '\n' ' ')"
fi

# --- В4: real-looking e-mail addresses (warn; secrets are scanned by gitleaks) -
mails=$(added 'app/**' | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -v '@example\.invalid$' | sort -u)
if [ -n "$mails" ]; then
  warn "В4 personal data" "e-mail addresses outside @example.invalid: $(echo "$mails" | head -5 | tr '\n' ' ')"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "Deterministic checks failed — fix the errors above before the AI review runs."
  exit 1
fi
echo "Deterministic checks passed."
