#!/usr/bin/env zsh
set -euo pipefail

repo_root=${0:A:h:h}
function_file="$repo_root/dot_zsh/functions.d/paste_rs"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
capture=${PASTE_RS_CAPTURE:?}
status=${PASTE_RS_CURL_STATUS:-201}
body=${PASTE_RS_CURL_BODY:-https://paste.rs/testid}
input=""
while (($#)); do
  case "$1" in
    --data-binary)
      shift
      if [[ "${1:-}" == @- ]]; then
        input=$(cat)
      elif [[ "${1:-}" == @* ]]; then
        input=$(cat "${1#@}")
      fi
      ;;
  esac
  shift || true
done
printf '%s' "$input" > "$capture"
printf '%s\n%s' "$body" "$status"
CURL
chmod +x "$tmpdir/bin/curl"
PATH="$tmpdir/bin:$PATH"
export PASTE_RS_CAPTURE="$tmpdir/captured"

source "$function_file"

# The managed ~/.zsh/functions loader should also expose paste_rs after apply.
loader_home="$tmpdir/home-loader"
mkdir -p "$loader_home/.zsh/functions.d"
ln -s "$function_file" "$loader_home/.zsh/functions.d/paste_rs"
HOME="$loader_home" zsh -fc 'source "$1"; paste_rs --help >/dev/null' zsh "$repo_root/dot_zsh/functions"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing [$needle] in [$haystack]"
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$label: unexpected [$needle] in [$haystack]"
}

# Default mode sanitizes common secret shapes before upload.
output=$(printf '%s\n' 'Authorization: Bearer leakme' 'password=hunter2' 'ok=true' | paste_rs)
assert_eq 'https://paste.rs/testid' "$output" 'default output URL'
captured=$(<"$PASTE_RS_CAPTURE")
assert_contains "$captured" 'Authorization: Bearer ***' 'authorization redaction'
assert_contains "$captured" 'password=[REDACTED]' 'password redaction'
assert_not_contains "$captured" 'leakme' 'bearer leaked'
assert_not_contains "$captured" 'hunter2' 'password leaked'

# --raw intentionally bypasses all sanitization.
output=$(printf '%s\n' 'password=hunter2' | paste_rs --raw)
assert_eq 'https://paste.rs/testid' "$output" 'raw output URL'
captured=$(<"$PASTE_RS_CAPTURE")
assert_contains "$captured" 'password=hunter2' 'raw keeps original'

# A custom sed rules file adds project-specific redactions.
rules="$tmpdir/rules.sed"
print 's/ACME-[0-9][0-9]*/ACME-[REDACTED]/g' > "$rules"
output=$(printf '%s\n' 'ticket=ACME-12345' | paste_rs --rules "$rules")
assert_eq 'https://paste.rs/testid' "$output" 'rules output URL'
captured=$(<"$PASTE_RS_CAPTURE")
assert_contains "$captured" 'ticket=ACME-[REDACTED]' 'custom rules applied'
assert_not_contains "$captured" 'ACME-12345' 'custom value leaked'

# The default rules file (gitignored: local identity + vendor-key redactions)
# is verified only when present. Real identity values are NEVER embedded here —
# a filter must not reveal what it filters. Vendor-key shapes below are synthetic
# format examples, not real keys; the real identity cases live in a gitignored
# fixtures file (sanitize.test) loaded as a generic harness at the end.
default_rules="${PASTE_RS_SANITIZE_FILE:-$HOME/.config/paste-rs/sanitize.sed}"
if [[ -r "$default_rules" ]]; then
  output=$(printf '%s\n' \
    'openai=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789' \
    'github=ghp_abcdefghijklmnopqrstuvwxyz0123456789' \
    "slack=xox${:-b}-123456789012-abcdefghijklmno" \
    "google=AI${:-za}SyAabcdefghijklmnopqrstuvwxyz0123456" \
    | paste_rs --rules "$default_rules")
  assert_eq 'https://paste.rs/testid' "$output" 'default rules output URL'
  captured=$(<"$PASTE_RS_CAPTURE")
  assert_contains "$captured" 'openai=sk-proj-[REDACTED]' 'OpenAI key redacted'
  assert_contains "$captured" 'github=ghp_[REDACTED]' 'GitHub token redacted'
  assert_contains "$captured" 'slack=xox[REDACTED]' 'Slack token redacted'
  assert_contains "$captured" 'google=AIza[REDACTED]' 'Google API key redacted'
  assert_not_contains "$captured" 'abcdefghijklmnopqrstuvwxyz0123456789' 'vendor key body leaked'

  # Identity redactions are exercised from a gitignored fixtures file so the real
  # values never enter VCS. One `input=>expected` case per line; '#'/blank skipped.
  fixtures="${PASTE_RS_SANITIZE_TEST:-$HOME/.config/paste-rs/sanitize.test}"
  if [[ -r "$fixtures" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == '#'* ]] && continue
      fin=${line%%=>*}
      fexp=${line#*=>}
      printf '%s\n' "$fin" | paste_rs --rules "$default_rules" >/dev/null
      captured=$(<"$PASTE_RS_CAPTURE")
      assert_contains "$captured" "$fexp" "identity fixture -> $fexp"
    done < "$fixtures"
    print 'ok - identity fixtures verified from gitignored sanitize.test'
  else
    print 'skip - no gitignored identity fixtures (sanitize.test) present'
  fi
else
  print 'skip - default rules file absent; identity/vendor redaction not checked'
fi

# File input is accepted.
input_file="$tmpdir/input.log"
print 'token: file-secret' > "$input_file"
output=$(paste_rs "$input_file")
assert_eq 'https://paste.rs/testid' "$output" 'file output URL'
captured=$(<"$PASTE_RS_CAPTURE")
assert_contains "$captured" 'token: [REDACTED]' 'file input sanitized'

# Non-201/206 statuses are errors and include context on stderr.
export PASTE_RS_CURL_STATUS=500
if err=$(printf '%s\n' 'ok' | paste_rs 2>&1 >/dev/null); then
  fail 'HTTP 500 should fail'
fi
assert_contains "$err" 'paste_rs: paste.rs returned HTTP 500' 'HTTP error message'

print 'ok - paste_rs tests passed'
