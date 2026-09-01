#!/bin/sh
# Package checks for worktree-setup dispatcher + install-hook.
# Usage: sh scripts/check.sh

set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
install="$here/install-hook.sh"
dispatcher="$here/post-checkout"

phys() {
	(CDPATH= cd -P -- "$1" && pwd -P)
}

[ -f "$install" ] && [ -f "$dispatcher" ] || {
	echo "check: missing install-hook.sh or post-checkout" >&2
	exit 1
}
sh -n "$install" || {
	echo "check: install-hook.sh: sh -n failed" >&2
	exit 1
}
sh -n "$dispatcher" || {
	echo "check: post-checkout: sh -n failed" >&2
	exit 1
}
sh -n "$here/check.sh" || {
	echo "check: check.sh: sh -n failed" >&2
	exit 1
}

base=""
cleanup() {
	st=$?
	if [ -n "${base-}" ] && [ -d "$base" ]; then
		rm -rf "$base"
	fi
	exit "$st"
}
trap cleanup EXIT INT HUP

base=$(mktemp -d "${TMPDIR:-/tmp}/worktree-setup-check.XXXXXX")
base=$(phys "$base")

die() {
	echo "check: FAIL: $*" >&2
	exit 1
}

ok() {
	echo "check: ok: $*"
}

prep_git() {
	dir=$1
	mkdir -p "$dir"
	(
		CDPATH= cd -- "$dir" || exit 1
		git init >/dev/null
		git config user.email "worktree-setup-check@example.invalid"
		git config user.name "worktree-setup-check"
		git config commit.gpgsign false
	)
}

write_bootstrap() {
	dir=$1
	mkdir -p "$dir/.worktree"
	cat >"$dir/.worktree/bootstrap.sh" <<'EOF'
#!/bin/sh
set -eu
echo ran >.bootstrap-ran
printf '%s\n' "$WORKTREE_SETUP_MAIN" >.bootstrap-main
printf '%s\n' "$WORKTREE_SETUP_NEW" >.bootstrap-new
EOF
	chmod +x "$dir/.worktree/bootstrap.sh"
}

null_oid="0000000000000000000000000000000000000000"

# --- 1. copy .env, bootstrap, main skip, unsafe skip, chain old hook ---

repo="$base/repo"
wt="$base/wt"
outside="$base/outside-secret"
prep_git "$repo"
repo=$(phys "$repo")

printf '%s\n' "SECRET=1" >"$repo/.env"
printf '%s\n' "inside" >"$repo/foo..bar"
printf '%s\n' "outside" >"$outside"
ln -s "$outside" "$repo/.outlink"
# Multi-hop: .chain-outer -> .outlink -> $outside
ln -s .outlink "$repo/.chain-outer"
mkdir -p "$repo/keepdir"
printf '%s\n' "safe" >"$repo/keepdir/ok.txt"
ln -s "$outside" "$repo/keepdir/nested-out"
# Multi-hop inside a copied directory: chain-mid -> nested-out -> $outside
ln -s nested-out "$repo/keepdir/chain-mid"
# Intermediate path component is a symlink that escapes the main tree.
ln -s "$base" "$repo/via-parent"
# Two-level intermediate: via-mid -> via-parent -> $base
ln -s via-parent "$repo/via-mid"
printf '%s\n' ".env" >"$repo/.gitignore"

write_bootstrap "$repo"
cat >"$repo/.worktree/copy" <<'EOF'
.env
# comment
  # spaced comment
foo..bar
../outside-secret
foo/../../outside-secret
/etc/passwd
.outlink
.chain-outer
keepdir
via-parent/outside-secret
via-mid/outside-secret
EOF

mkdir -p "$repo/.git/hooks"
cat >"$repo/.git/hooks/post-checkout" <<'EOF'
#!/bin/sh
echo chained >.old-hook-ran
EOF
chmod +x "$repo/.git/hooks/post-checkout"

(
	CDPATH= cd -- "$repo" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	sh "$install"
)

[ -f "$repo/.git/hooks/post-checkout" ] || die "dispatcher not installed"
grep -q "worktree-setup: dispatcher" "$repo/.git/hooks/post-checkout" || die "dispatcher marker missing"
[ -x "$repo/.git/hooks/post-checkout" ] || die "dispatcher not executable"
[ -f "$repo/.git/hooks/post-checkout.pre-worktree-setup" ] || die "old hook not chained"
[ -x "$repo/.git/hooks/post-checkout.pre-worktree-setup" ] || die "chained old hook lost +x"

(
	CDPATH= cd -- "$repo" || exit 1
	git worktree add -b check/wt "$wt" >/dev/null
)
wt=$(phys "$wt")

[ -f "$wt/.env" ] || die "worktree add did not copy .env"
[ "$(cat "$wt/.env")" = "SECRET=1" ] || die ".env content mismatch"
[ -f "$wt/.bootstrap-ran" ] || die "bootstrap did not run"
[ "$(cat "$wt/.bootstrap-main")" = "$repo" ] || die "WORKTREE_SETUP_MAIN mismatch (got $(cat "$wt/.bootstrap-main"), want $repo)"
[ "$(cat "$wt/.bootstrap-new")" = "$wt" ] || die "WORKTREE_SETUP_NEW mismatch (got $(cat "$wt/.bootstrap-new"), want $wt)"
[ -f "$wt/foo..bar" ] || die "false-positive .. skip (foo..bar should copy)"
[ -f "$wt/.old-hook-ran" ] || die "executable old hook was not chained"
[ -f "$wt/keepdir/ok.txt" ] || die "safe file inside copied directory missing"
[ ! -e "$wt/.outlink" ] && [ ! -L "$wt/.outlink" ] || die "symlink pointing outside main was copied"
[ ! -e "$wt/.chain-outer" ] && [ ! -L "$wt/.chain-outer" ] || die "multi-hop symlink pointing outside main was copied"
[ ! -e "$wt/keepdir/nested-out" ] && [ ! -L "$wt/keepdir/nested-out" ] || die "nested symlink outside main was copied"
[ ! -e "$wt/keepdir/chain-mid" ] && [ ! -L "$wt/keepdir/chain-mid" ] || die "multi-hop nested symlink outside main was copied"
[ ! -e "$wt/via-parent" ] && [ ! -e "$wt/via-parent/outside-secret" ] || die "path via intermediate outside symlink was copied"
[ ! -e "$wt/via-mid" ] && [ ! -e "$wt/via-mid/outside-secret" ] || die "path via two-level intermediate outside symlink was copied"
[ ! -f "$wt/outside-secret" ] && [ ! -L "$wt/outside-secret" ] || die "outside-secret leaked into worktree"
[ ! -e "$wt/etc" ] && [ ! -e "$wt/passwd" ] && [ ! -e "$wt/etc/passwd" ] || die "/etc/passwd leaked into worktree"
[ ! -f "$repo/.bootstrap-ran" ] || die "bootstrap ran on main tree during worktree add"
[ ! -f "$repo/.old-hook-ran" ] || die "old hook marker on main after worktree add (unexpected)"
ok "worktree add copied .env, bootstrap ran, old hook chained, unsafe skipped"

# main tree: flag=1 + null OID must still skip copy/bootstrap (git_dir == common)
(
	CDPATH= cd -- "$repo" || exit 1
	"$repo/.git/hooks/post-checkout" "$null_oid" "$(git rev-parse HEAD)" 1 || true
)
[ ! -f "$repo/.bootstrap-ran" ] || die "dispatcher bootstrapped the main tree"
ok "main tree did not run copy/bootstrap"

# --- 2. non-executable previous post-checkout is chained, not overwritten ---

repo2="$base/repo-sample"
prep_git "$repo2"
repo2=$(phys "$repo2")
mkdir -p "$repo2/.git/hooks"
printf '%s\n' "# sample post-checkout" "echo sample-ran" >"$repo2/.git/hooks/post-checkout"
[ ! -x "$repo2/.git/hooks/post-checkout" ] || chmod -x "$repo2/.git/hooks/post-checkout"
(
	CDPATH= cd -- "$repo2" || exit 1
	printf '%s\n' "init" >README
	git add README
	git commit -m init >/dev/null
	sh "$install"
)
[ -f "$repo2/.git/hooks/post-checkout.pre-worktree-setup" ] || die "non-executable hook was not backed up"
grep -q "sample post-checkout" "$repo2/.git/hooks/post-checkout.pre-worktree-setup" || die "sample hook content lost"
[ ! -x "$repo2/.git/hooks/post-checkout.pre-worktree-setup" ] || die "sample backup should stay non-executable"
grep -q "worktree-setup: dispatcher" "$repo2/.git/hooks/post-checkout" || die "dispatcher not installed over sample"
ok "non-executable post-checkout chained to .pre-worktree-setup"

# --- 3. husky-like hooksPath: merge + stub, no core.hooksPath change ---

repo3="$base/repo-husky"
wt3="$base/wt-husky"
prep_git "$repo3"
repo3=$(phys "$repo3")
printf '%s\n' "SECRET=1" >"$repo3/.env"
printf '%s\n' ".env" >"$repo3/.gitignore"
write_bootstrap "$repo3"
printf '%s\n' ".env" >"$repo3/.worktree/copy"
(
	CDPATH= cd -- "$repo3" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	mkdir -p .husky/_
	cat >.husky/_/.gitignore <<'EOF'
*
EOF
	cat >.husky/_/h <<'EOF'
#!/usr/bin/env sh
[ "$HUSKY" = "0" ] && exit 0
n=$(basename "$0")
hook="$(dirname "$0")/../$n"
[ -f "$hook" ] || exit 0
sh -e "$hook" "$@"
EOF
	chmod +x .husky/_/h
	cat >.husky/post-checkout <<'EOF'
#!/usr/bin/env sh
# user-husky-hook
true
EOF
	chmod +x .husky/post-checkout
	cat >.husky/_/post-checkout <<'EOF'
#!/usr/bin/env sh
# husky-internal-stub
. "$(dirname "$0")/h"
EOF
	chmod +x .husky/_/post-checkout
	git config core.hooksPath .husky/_
	before=$(git config --get core.hooksPath)
	sh "$install"
	after=$(git config --get core.hooksPath)
	[ "$before" = "$after" ] || die "install-hook changed core.hooksPath"
	[ "$after" = ".husky/_" ] || die "core.hooksPath not preserved"
	[ -f .husky/post-checkout ] || die "missing .husky/post-checkout"
	grep -q "worktree-setup: husky-bridge" .husky/post-checkout || die "husky post-checkout missing bridge"
	grep -q 'post-checkout" "$@" || exit $?' .husky/post-checkout || die "husky user hook masks dispatcher status"
	grep -q "user-husky-hook" .husky/post-checkout || die "existing .husky/post-checkout was overwritten"
	[ -f .husky/_/post-checkout ] || die "missing .husky/_/post-checkout stub"
	grep -q "worktree-setup: husky-bridge" .husky/_/post-checkout || die "stub missing bridge"
	grep -q 'post-checkout" "$@" || exit $?' .husky/_/post-checkout || die "husky stub masks dispatcher status"
	grep -q "husky-internal-stub" .husky/_/post-checkout || die "existing husky stub was overwritten"
	grep -q 'dirname "$0")/h' .husky/_/post-checkout || die "husky stub lost . h wrapper"
	git ls-files --error-unmatch -- .husky/_/post-checkout >/dev/null || die "stub not tracked"
	# install-hook git-adds the stub; new worktrees only see committed files.
	git commit -m husky-bridge >/dev/null
	git worktree add -b check/husky "$wt3" >/dev/null
)
wt3=$(phys "$wt3")
[ -f "$wt3/.husky/_/post-checkout" ] || die "new worktree missing tracked husky stub"
[ -f "$wt3/.env" ] || die "husky hooksPath worktree add did not copy .env"
[ -f "$wt3/.bootstrap-ran" ] || die "husky hooksPath worktree add did not run bootstrap"
[ ! -f "$repo3/.bootstrap-ran" ] || die "husky repo main tree ran bootstrap"
ok "husky hooksPath bridged without changing core.hooksPath"

# idempotent second install; ./hooksPath prefix is treated as husky
(
	CDPATH= cd -- "$repo3" || exit 1
	sh "$install"
	n=$(grep -c "worktree-setup: husky-bridge" .husky/post-checkout)
	[ "$n" -eq 1 ] || die "husky bridge not idempotent (marker count=$n)"
	ns=$(grep -c "worktree-setup: husky-bridge" .husky/_/post-checkout)
	[ "$ns" -eq 1 ] || die "husky stub bridge not idempotent (marker count=$ns)"
	grep -q "husky-internal-stub" .husky/_/post-checkout || die "second install overwrote husky stub"
	git config core.hooksPath ./.husky/_
	before=$(git config --get core.hooksPath)
	sh "$install"
	after=$(git config --get core.hooksPath)
	[ "$before" = "$after" ] || die "dot-slash hooksPath changed by install-hook"
	[ "$after" = "./.husky/_" ] || die "dot-slash core.hooksPath not preserved"
	n=$(grep -c "worktree-setup: husky-bridge" .husky/post-checkout)
	[ "$n" -eq 1 ] || die "dot-slash hooksPath re-merged user hook (marker count=$n)"
	git config core.hooksPath .husky/_
)
ok "husky bridge idempotent"

# --- 3b. already-tracked husky stub without bridge is merged, not skipped ---
# .husky/_ gitignore * : original stub is in HEAD first, then install.

repo3b="$base/repo-husky-tracked-stub"
wt3b="$base/wt-husky-tracked-stub"
prep_git "$repo3b"
repo3b=$(phys "$repo3b")
printf '%s\n' "SECRET=1" >"$repo3b/.env"
printf '%s\n' ".env" >"$repo3b/.gitignore"
write_bootstrap "$repo3b"
printf '%s\n' ".env" >"$repo3b/.worktree/copy"
(
	CDPATH= cd -- "$repo3b" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	mkdir -p .husky/_
	cat >.husky/_/.gitignore <<'EOF'
*
EOF
	cat >.husky/_/h <<'EOF'
#!/usr/bin/env sh
[ "$HUSKY" = "0" ] && exit 0
n=$(basename "$0")
hook="$(dirname "$0")/../$n"
[ -f "$hook" ] || exit 0
sh -e "$hook" "$@"
EOF
	chmod +x .husky/_/h
	cat >.husky/post-checkout <<'EOF'
#!/usr/bin/env sh
# user-husky-hook
true
EOF
	chmod +x .husky/post-checkout
	cat >.husky/_/post-checkout <<'EOF'
#!/usr/bin/env sh
# husky-internal-stub
. "$(dirname "$0")/h"
EOF
	chmod +x .husky/_/post-checkout
	# Original stub in HEAD *before* install (force-add: _/.gitignore is *).
	git add -f -- .husky/_/post-checkout
	git add -- .husky/post-checkout
	git commit -m husky-original-stub >/dev/null
	git ls-files --error-unmatch -- .husky/_/post-checkout >/dev/null || die "precondition: stub not in HEAD"
	if grep -q "worktree-setup: husky-bridge" .husky/_/post-checkout; then
		die "precondition: original stub already had bridge"
	fi
	git config core.hooksPath .husky/_
	before=$(git config --get core.hooksPath)
	sh "$install"
	after=$(git config --get core.hooksPath)
	[ "$before" = "$after" ] || die "tracked-stub install-hook changed core.hooksPath"
	grep -q "worktree-setup: husky-bridge" .husky/_/post-checkout || die "tracked stub missing bridge after install"
	grep -q 'post-checkout" "$@" || exit $?' .husky/_/post-checkout || die "tracked stub masks dispatcher status"
	grep -q "husky-internal-stub" .husky/_/post-checkout || die "tracked stub was overwritten"
	grep -q 'dirname "$0")/h' .husky/_/post-checkout || die "tracked stub lost . h wrapper"
	grep -q "worktree-setup: husky-bridge" .husky/post-checkout || die "tracked-stub case: user hook missing bridge"
	grep -q "user-husky-hook" .husky/post-checkout || die "tracked-stub case: user hook overwritten"
	git commit -m husky-bridge-tracked-stub >/dev/null
	git worktree add -b check/husky-tracked-stub "$wt3b" >/dev/null
)
wt3b=$(phys "$wt3b")
[ -f "$wt3b/.husky/_/post-checkout" ] || die "new worktree missing tracked husky stub"
[ ! -e "$wt3b/.husky/_/h" ] || die "new worktree unexpectedly has husky h"
grep -q "worktree-setup: husky-bridge" "$wt3b/.husky/_/post-checkout" || die "new worktree stub missing bridge"
[ -f "$wt3b/.env" ] || die "tracked-stub hooksPath worktree add did not copy .env"
[ -f "$wt3b/.bootstrap-ran" ] || die "tracked stub without h did not run dispatcher/bootstrap"
[ ! -f "$repo3b/.bootstrap-ran" ] || die "tracked-stub repo main tree ran bootstrap"
ok "tracked husky stub without bridge merged; no h still runs dispatcher"

# --- 4. hooksPath value is used (nested dir), not hardcoded .husky ---

repo4="$base/repo-nested-husky"
wt4="$base/wt-nested-husky"
prep_git "$repo4"
repo4=$(phys "$repo4")
printf '%s\n' "SECRET=1" >"$repo4/.env"
printf '%s\n' ".env" >"$repo4/.gitignore"
write_bootstrap "$repo4"
printf '%s\n' ".env" >"$repo4/.worktree/copy"
(
	CDPATH= cd -- "$repo4" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	mkdir -p tools/.husky/_
	cat >tools/.husky/_/.gitignore <<'EOF'
*
EOF
	cat >tools/.husky/_/h <<'EOF'
#!/usr/bin/env sh
[ "$HUSKY" = "0" ] && exit 0
n=$(basename "$0")
hook="$(dirname "$0")/../$n"
[ -f "$hook" ] || exit 0
sh -e "$hook" "$@"
EOF
	chmod +x tools/.husky/_/h
	cat >tools/.husky/post-checkout <<'EOF'
#!/usr/bin/env sh
# nested-user-hook
true
EOF
	chmod +x tools/.husky/post-checkout
	cat >tools/.husky/_/post-checkout <<'EOF'
#!/usr/bin/env sh
# nested-internal-stub
. "$(dirname "$0")/h"
EOF
	chmod +x tools/.husky/_/post-checkout
	git config core.hooksPath tools/.husky/_
	before=$(git config --get core.hooksPath)
	sh "$install"
	after=$(git config --get core.hooksPath)
	[ "$before" = "$after" ] || die "nested install-hook changed core.hooksPath"
	[ "$after" = "tools/.husky/_" ] || die "nested core.hooksPath not preserved"
	[ ! -e .husky/post-checkout ] && [ ! -e .husky/_/post-checkout ] || die "bridge written to hardcoded .husky instead of hooksPath"
	[ -f tools/.husky/post-checkout ] || die "missing tools/.husky/post-checkout"
	grep -q "worktree-setup: husky-bridge" tools/.husky/post-checkout || die "nested user hook missing bridge"
	grep -q 'post-checkout" "$@" || exit $?' tools/.husky/post-checkout || die "nested user hook masks dispatcher status"
	grep -q "nested-user-hook" tools/.husky/post-checkout || die "nested user hook overwritten"
	[ -f tools/.husky/_/post-checkout ] || die "missing nested stub"
	grep -q "worktree-setup: husky-bridge" tools/.husky/_/post-checkout || die "nested stub missing bridge"
	grep -q 'post-checkout" "$@" || exit $?' tools/.husky/_/post-checkout || die "nested stub masks dispatcher status"
	grep -q "nested-internal-stub" tools/.husky/_/post-checkout || die "nested stub overwritten"
	git ls-files --error-unmatch -- tools/.husky/_/post-checkout >/dev/null || die "nested stub not tracked"
	# install-hook git-adds the stub; new worktrees only see committed files.
	git commit -m nested-husky-bridge >/dev/null
	git worktree add -b check/nested "$wt4" >/dev/null
)
wt4=$(phys "$wt4")
[ -f "$wt4/tools/.husky/_/post-checkout" ] || die "new worktree missing nested husky stub"
[ -f "$wt4/.env" ] || die "nested hooksPath worktree add did not copy .env"
[ -f "$wt4/.bootstrap-ran" ] || die "nested hooksPath worktree add did not run bootstrap"
[ ! -f "$repo4/.bootstrap-ran" ] || die "nested repo main tree ran bootstrap"
ok "hooksPath original value used; nested husky stub merged"

# --- 5. husky stub does not mask dispatcher/bootstrap non-zero ---

repo5="$base/repo-husky-fail"
wt5="$base/wt-husky-fail"
prep_git "$repo5"
repo5=$(phys "$repo5")
printf '%s\n' "SECRET=1" >"$repo5/.env"
printf '%s\n' ".env" >"$repo5/.gitignore"
mkdir -p "$repo5/.worktree"
cat >"$repo5/.worktree/bootstrap.sh" <<'EOF'
#!/bin/sh
set -eu
echo ran >.bootstrap-ran
printf '%s\n' "$WORKTREE_SETUP_MAIN" >.bootstrap-main
printf '%s\n' "$WORKTREE_SETUP_NEW" >.bootstrap-new
exit 7
EOF
chmod +x "$repo5/.worktree/bootstrap.sh"
printf '%s\n' ".env" >"$repo5/.worktree/copy"
(
	CDPATH= cd -- "$repo5" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	mkdir -p .husky/_
	cat >.husky/_/.gitignore <<'EOF'
*
EOF
	cat >.husky/_/h <<'EOF'
#!/usr/bin/env sh
[ "$HUSKY" = "0" ] && exit 0
n=$(basename "$0")
hook="$(dirname "$0")/../$n"
[ -f "$hook" ] || exit 0
sh -e "$hook" "$@"
EOF
	chmod +x .husky/_/h
	cat >.husky/post-checkout <<'EOF'
#!/usr/bin/env sh
# user-husky-hook
true
EOF
	chmod +x .husky/post-checkout
	cat >.husky/_/post-checkout <<'EOF'
#!/usr/bin/env sh
# husky-internal-stub
. "$(dirname "$0")/h"
EOF
	chmod +x .husky/_/post-checkout
	git config core.hooksPath .husky/_
	sh "$install"
	git add -f -- .husky/_/post-checkout .husky/post-checkout 2>/dev/null || true
	git commit -m husky-fail-bridge >/dev/null
	# Git keeps the worktree but returns post-checkout status (bootstrap's 7).
	ec=0
	git worktree add -b check/husky-fail "$wt5" >/dev/null || ec=$?
	[ "$ec" -eq 7 ] || die "husky stub masked dispatcher/bootstrap status (got $ec, want 7)"
)
wt5=$(phys "$wt5")
[ -f "$wt5/.bootstrap-ran" ] || die "failing bootstrap did not run"
ec=0
(
	CDPATH= cd -- "$wt5" || exit 1
	".husky/_/post-checkout" "$null_oid" "$(git rev-parse HEAD)" 1
) || ec=$?
[ "$ec" -eq 7 ] || die "husky stub masked dispatcher/bootstrap status (got $ec, want 7)"
ok "husky stub propagates bootstrap non-zero"

# --- 6. dest intermediate symlink must not escape the new worktree ---

repo6="$base/repo-dest-escape"
wt6="$base/wt-dest-escape"
escape_dest="$base/escape-dest"
mkdir -p "$escape_dest"
prep_git "$repo6"
repo6=$(phys "$repo6")
printf '%s\n' "SECRET=1" >"$repo6/.env"
mkdir -p "$repo6/planted"
printf '%s\n' "inside" >"$repo6/planted/file"
printf '%s\n' ".env" "planted/" >"$repo6/.gitignore"
write_bootstrap "$repo6"
cat >"$repo6/.worktree/copy" <<'EOF'
.env
planted/file
EOF
(
	CDPATH= cd -- "$repo6" || exit 1
	printf '%s\n' "init" >README
	git add README .gitignore
	git commit -m init >/dev/null
	sh "$install"
	git worktree add -b check/dest-escape "$wt6" >/dev/null
)
wt6=$(phys "$wt6")
[ -f "$wt6/planted/file" ] || die "planted/file was not copied"
[ "$(cat "$wt6/planted/file")" = "inside" ] || die "planted/file content mismatch"
rm -rf "$wt6/planted"
ln -s "$escape_dest" "$wt6/planted"
(
	CDPATH= cd -- "$wt6" || exit 1
	"$repo6/.git/hooks/post-checkout" "$null_oid" "$(git rev-parse HEAD)" 1 || true
)
[ ! -e "$escape_dest/file" ] && [ ! -L "$escape_dest/file" ] || die "copy escaped new worktree via dest symlink"
[ ! -f "$wt6/planted/file" ] || die "dest-escape skip still wrote through planted symlink"
ok "dest path outside new worktree skipped"

# --- 7. install-hook does not write through a symlink dest ---

repo7="$base/repo-symlink-hook"
prep_git "$repo7"
repo7=$(phys "$repo7")
hook_target="$base/cp-follow-target"
printf '%s\n' '#!/bin/sh' '# worktree-setup: dispatcher' 'echo should-not-overwrite' >"$hook_target"
mkdir -p "$repo7/.git/hooks"
ln -s "$hook_target" "$repo7/.git/hooks/post-checkout"
(
	CDPATH= cd -- "$repo7" || exit 1
	printf '%s\n' "init" >README
	git add README
	git commit -m init >/dev/null
	sh "$install"
)
grep -q 'should-not-overwrite' "$hook_target" || die "install-hook followed symlink and overwrote target"
[ -L "$repo7/.git/hooks/post-checkout.pre-worktree-setup" ] || die "symlink hook was not chained"
[ ! -L "$repo7/.git/hooks/post-checkout" ] || die "dispatcher dest is still a symlink"
grep -q "worktree-setup: dispatcher" "$repo7/.git/hooks/post-checkout" || die "dispatcher not installed beside chained symlink"
ok "install-hook chained symlink dest instead of writing through it"

# --- 8. merge_bridge refuses a symlink user hook ---

repo8="$base/repo-husky-symlink"
prep_git "$repo8"
repo8=$(phys "$repo8")
husky_target="$base/husky-follow-target"
printf '%s\n' '#!/usr/bin/env sh' '# user-husky-hook' 'true' >"$husky_target"
(
	CDPATH= cd -- "$repo8" || exit 1
	printf '%s\n' "init" >README
	git add README
	git commit -m init >/dev/null
	mkdir -p .husky/_
	ln -s "$husky_target" .husky/post-checkout
	cat >.husky/_/post-checkout <<'EOF'
#!/usr/bin/env sh
# husky-internal-stub
true
EOF
	chmod +x .husky/_/post-checkout
	git config core.hooksPath .husky/_
	if sh "$install"; then
		die "install-hook should refuse symlink husky user hook"
	fi
)
grep -q 'user-husky-hook' "$husky_target" || die "symlink husky target lost original content"
if grep -q 'worktree-setup: husky-bridge' "$husky_target"; then
	die "merge_bridge wrote through symlink user hook"
fi
ok "merge_bridge refused symlink user hook"

echo "check: all passed"
