#!/bin/sh
# Install the dispatcher into this clone's GIT_COMMON_DIR/hooks.
# Does not set core.hooksPath. Does not wrap git worktree add.

set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
src="$here/post-checkout"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
	echo "install-hook: not a git work tree" >&2
	exit 1
}

common=$(CDPATH= cd -P -- "$(git rev-parse --git-common-dir)" && pwd -P)
toplevel=$(CDPATH= cd -- "$(git rev-parse --show-toplevel)" && pwd -L)
toplevel_phys=$(CDPATH= cd -P -- "$toplevel" && pwd -P) || toplevel_phys=$toplevel
hook_dir="$common/hooks"
mkdir -p "$hook_dir"
dest="$hook_dir/post-checkout"
pre="$dest.pre-worktree-setup"

# Copy dispatcher onto $dest without following a symlink dest/tmp.
install_dispatcher() {
	tmp="$dest.worktree-setup.tmp"
	if [ -L "$tmp" ]; then
		echo "install-hook: refusing to write through symlink $tmp" >&2
		exit 1
	fi
	if [ -e "$tmp" ]; then
		rm -f "$tmp" || exit 1
	fi
	cp "$src" "$tmp" || exit 1
	chmod +x "$tmp"
	if [ -L "$tmp" ]; then
		echo "install-hook: $tmp became a symlink; not installing through it" >&2
		rm -f "$tmp"
		exit 1
	fi
	mv "$tmp" "$dest"
	chmod +x "$dest"
}

chain_existing() {
	if [ -e "$pre" ] || [ -L "$pre" ]; then
		echo "install-hook: $dest exists and $pre already exists; resolve by hand" >&2
		exit 1
	fi
	# Chain any previous hook, including a non-executable sample or a symlink.
	was_exec=0
	if [ -x "$dest" ]; then
		was_exec=1
	fi
	mv "$dest" "$pre"
	install_dispatcher
	if [ "$was_exec" = 1 ]; then
		chmod +x "$pre"
	fi
	echo "install-hook: chained previous hook to $pre"
	echo "install-hook: installed $dest"
}

# [ -f ] is true for a symlink to a regular file; never cp through that.
if [ -L "$dest" ]; then
	chain_existing
elif [ -f "$dest" ] && grep -q "worktree-setup: dispatcher" "$dest" 2>/dev/null; then
	install_dispatcher
	echo "install-hook: updated $dest"
elif [ -f "$dest" ]; then
	chain_existing
else
	install_dispatcher
	echo "install-hook: installed $dest"
fi

# --- husky / hooksPath bridge (does not change core.hooksPath) ---

normalize_hooks_path() {
	p=$1
	while [ "$p" != "${p%/}" ]; do
		p=${p%/}
	done
	while :; do
		case "$p" in
		./* ) p=${p#./} ;;
		*) break ;;
		esac
	done
	printf '%s' "$p"
}

looks_like_husky() {
	p=$(normalize_hooks_path "$1")
	case "$p" in
	.husky/_ | */.husky/_ | .husky | */.husky ) return 0 ;;
	esac
	return 1
}

looks_like_husky_underscore() {
	p=$(normalize_hooks_path "$1")
	case "$p" in
	.husky/_ | */.husky/_ ) return 0 ;;
	esac
	return 1
}

bridge_lines() {
	# Dispatcher failure must not be masked by a later `true` / husky body.
	printf '%s\n' \
		'# worktree-setup: husky-bridge' \
		'COMMON=$(CDPATH= cd -P -- "$(git rev-parse --git-common-dir)" && pwd -P)' \
		'if [ -x "$COMMON/hooks/post-checkout" ]; then' \
		'	"$COMMON/hooks/post-checkout" "$@" || exit $?' \
		'fi'
}

write_bridge() {
	# Standalone hook body. Same snippet as merged into .husky/post-checkout.
	printf '%s\n' '#!/bin/sh'
	bridge_lines
}

merge_bridge() {
	file=$1
	kind=${2-}
	mkdir -p "$(dirname "$file")"
	if [ -L "$file" ]; then
		echo "install-hook: refusing to write through symlink $file" >&2
		return 1
	fi
	if [ -f "$file" ] && grep -q "worktree-setup: husky-bridge" "$file" 2>/dev/null; then
		chmod +x "$file"
		return 0
	fi
	if [ ! -f "$file" ] && [ ! -L "$file" ]; then
		write_bridge >"$file"
		chmod +x "$file"
		return 0
	fi
	tmp="$file.worktree-setup.tmp"
	if [ -L "$tmp" ]; then
		echo "install-hook: refusing to write through symlink $tmp" >&2
		return 1
	fi
	if [ -e "$tmp" ]; then
		rm -f "$tmp" || return 1
	fi
	{
		IFS= read -r first || first=""
		case "$first" in
		'#!'*)
			printf '%s\n' "$first"
			bridge_lines
			if [ "$kind" = stub ]; then
				printf '%s\n' '[ -f "$(dirname "$0")/h" ] || exit 0'
			fi
			cat
			;;
		*)
			write_bridge
			if [ "$kind" = stub ]; then
				printf '%s\n' '[ -f "$(dirname "$0")/h" ] || exit 0'
			fi
			[ -n "$first" ] && printf '%s\n' "$first"
			cat
			;;
		esac
	} <"$file" >"$tmp"
	if [ -L "$tmp" ]; then
		echo "install-hook: $tmp became a symlink; not installing through it" >&2
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$file"
	chmod +x "$file"
}

has_dotdot_component() {
	p=$1
	while [ "$p" != "${p%/}" ]; do
		p=${p%/}
	done
	case "$p" in
	.. | ../* | */.. | */../* ) return 0 ;;
	esac
	return 1
}

under_toplevel() {
	# Require a path-component boundary so $toplevel is not a prefix of $toplevel-extra.
	case "$1" in
	"$toplevel" | "$toplevel"/* | "$toplevel_phys" | "$toplevel_phys"/* ) return 0 ;;
	esac
	return 1
}

existing_ancestor() {
	a=$1
	while [ ! -e "$a" ] && [ ! -L "$a" ]; do
		n=$(dirname "$a")
		[ "$n" = "$a" ] && break
		a=$n
	done
	printf '%s' "$a"
}

rel_to_toplevel() {
	case "$1" in
	"$toplevel"/* )
		printf '%s' "${1#"$toplevel"/}"
		return 0
		;;
	"$toplevel_phys"/* )
		printf '%s' "${1#"$toplevel_phys"/}"
		return 0
		;;
	esac
	return 1
}

hooks_path=$(git config --get core.hooksPath || true)
hooks_path=${hooks_path%"$(printf '\r')"}
hooks_path=${hooks_path#"${hooks_path%%[![:space:]]*}"}
hooks_path=${hooks_path%"${hooks_path##*[![:space:]]}"}
hooks_path=$(normalize_hooks_path "$hooks_path")

if [ -z "$hooks_path" ]; then
	# Default GIT_COMMON_DIR/hooks; dispatcher already installed there.
	:
elif looks_like_husky "$hooks_path"; then
	if has_dotdot_component "$hooks_path"; then
		echo "install-hook: core.hooksPath=$hooks_path"
		echo "install-hook: refusing husky bridge (path escapes the work tree)." >&2
	else
		case "$hooks_path" in
		/* ) hooks_dir=$hooks_path ;;
		* ) hooks_dir="$toplevel/$hooks_path" ;;
		esac
		if ! under_toplevel "$hooks_dir"; then
			echo "install-hook: core.hooksPath=$hooks_path"
			echo "install-hook: refusing husky bridge (not under this work tree)." >&2
		else
			# Resolve the existing prefix *before* mkdir -p so a symlink
			# component cannot create directories outside the work tree.
			ancestor=$(existing_ancestor "$hooks_dir")
			if [ -e "$ancestor" ] || [ -L "$ancestor" ]; then
				ancestor_abs=$(CDPATH= cd -P -- "$ancestor" && pwd -P) || ancestor_abs=""
				if [ -z "$ancestor_abs" ] || ! under_toplevel "$ancestor_abs"; then
					echo "install-hook: core.hooksPath=$hooks_path"
					echo "install-hook: refusing husky bridge (resolved path escapes)." >&2
					ancestor_abs=""
				fi
			else
				ancestor_abs=$toplevel_phys
			fi
			if [ -n "${ancestor_abs-}" ]; then
				mkdir -p "$hooks_dir"
				hooks_abs=$(CDPATH= cd -P -- "$hooks_dir" && pwd -P) || hooks_abs=""
				if [ -z "$hooks_abs" ] || ! under_toplevel "$hooks_abs"; then
					echo "install-hook: core.hooksPath=$hooks_path"
					echo "install-hook: refusing husky bridge (resolved path escapes)." >&2
				else
					if looks_like_husky_underscore "$hooks_path"; then
						husky_root=$(dirname "$hooks_dir")
					else
						husky_root=$hooks_dir
					fi
					user_hook="$husky_root/post-checkout"
					merge_bridge "$user_hook"
					if rel_user=$(rel_to_toplevel "$user_hook"); then
						git -C "$toplevel" add -f -- "$rel_user"
					fi
					echo "install-hook: merged $user_hook (staged; commit so new worktrees receive it)"

					if looks_like_husky_underscore "$hooks_path"; then
						stub="$hooks_dir/post-checkout"
						if [ "$stub" != "$user_hook" ]; then
							# Merge even if the stub is already tracked without a bridge marker.
							merge_bridge "$stub" stub
							if rel_stub=$(rel_to_toplevel "$stub"); then
								git -C "$toplevel" add -f -- "$rel_stub"
							fi
							echo "install-hook: staged stub $stub (commit so new worktrees receive it)"
						fi
					fi
				fi
			fi
		fi
	fi
else
	echo "install-hook: core.hooksPath=$hooks_path"
	echo "install-hook: Git will not run $dest until hooksPath is unset or a tracked hook at that path calls it."
fi
