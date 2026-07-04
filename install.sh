#!/bin/sh
set -eu

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage: sh install.sh [options]

Install helix-steel-plugin-manager into Helix's Steel module search path.

Options:
  --configure        Append idempotent setup blocks to helix.scm and init.scm.
  --copy             Copy plugin-manager.scm instead of creating a symlink.
  --symlink          Create a symlink. This is the default.
  --config-dir DIR   Use DIR as the Helix Steel config directory.
                     Defaults to $HELIX_STEEL_CONFIG, then
                     ${XDG_CONFIG_HOME:-$HOME/.config}/helix.
  --force            Back up and replace an existing plugin-manager.scm target.
  -h, --help         Show this help.
EOF
}

mode=symlink
configure=0
force=0
config_dir=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configure)
            configure=1
            ;;
        --copy)
            mode=copy
            ;;
        --symlink)
            mode=symlink
            ;;
        --config-dir)
            shift
            [ "$#" -gt 0 ] || die "--config-dir requires a directory"
            config_dir=$1
            ;;
        --force)
            force=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

script=$0
case $script in
    */*) ;;
    *)
        if command -v "$script" >/dev/null 2>&1; then
            script=$(command -v "$script")
        fi
        ;;
esac

script_dir=$(CDPATH= cd "$(dirname "$script")" && pwd -P) ||
    die "unable to locate script directory"
source_file=$script_dir/plugin-manager.scm

[ -f "$source_file" ] ||
    die "plugin-manager.scm was not found next to install.sh"

if [ -z "$config_dir" ]; then
    if [ "${HELIX_STEEL_CONFIG+x}" = x ] && [ -n "$HELIX_STEEL_CONFIG" ]; then
        config_dir=$HELIX_STEEL_CONFIG
    else
        [ "${HOME+x}" = x ] && [ -n "$HOME" ] ||
            die "HOME is not set; pass --config-dir explicitly"
        config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
        config_dir=$config_home/helix
    fi
fi

module_dir=$config_dir/helix
target_file=$module_dir/plugin-manager.scm
helix_scm=$config_dir/helix.scm
init_scm=$config_dir/init.scm

backup_existing() {
    target=$1
    [ -e "$target" ] || [ -L "$target" ] || return 0

    if [ "$force" -ne 1 ]; then
        die "$target already exists; use --force to back it up and replace it"
    fi

    stamp=$(date +%Y%m%d%H%M%S 2>/dev/null || printf unknown)
    backup=$target.bak.$stamp
    suffix=0
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        suffix=$((suffix + 1))
        backup=$target.bak.$stamp.$suffix
    done

    mv "$target" "$backup" || die "failed to back up $target"
    printf 'Backed up %s to %s\n' "$target" "$backup"
}

install_module() {
    mkdir -p "$module_dir" || die "failed to create $module_dir"

    if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
        printf 'plugin-manager.scm is already installed at %s\n' "$target_file"
        return 0
    fi

    if [ "$mode" = symlink ] &&
       [ -L "$target_file" ] &&
       command -v readlink >/dev/null 2>&1 &&
       [ "$(readlink "$target_file")" = "$source_file" ]; then
        printf 'plugin-manager.scm symlink is already installed at %s\n' "$target_file"
        return 0
    fi

    backup_existing "$target_file"

    if [ "$mode" = copy ]; then
        cp -p "$source_file" "$target_file" ||
            die "failed to copy plugin-manager.scm"
        printf 'Copied plugin-manager.scm to %s\n' "$target_file"
        return 0
    fi

    if ln -s "$source_file" "$target_file" 2>/dev/null; then
        printf 'Linked plugin-manager.scm to %s\n' "$target_file"
    else
        warn "symlink failed; falling back to copy"
        cp -p "$source_file" "$target_file" ||
            die "failed to copy plugin-manager.scm"
        printf 'Copied plugin-manager.scm to %s\n' "$target_file"
    fi
}

marker_state() {
    file=$1
    begin=$2
    end=$3

    has_begin=0
    has_end=0
    if grep -F "$begin" "$file" >/dev/null 2>&1; then
        has_begin=1
    fi
    if grep -F "$end" "$file" >/dev/null 2>&1; then
        has_end=1
    fi

    if [ "$has_begin" -ne "$has_end" ]; then
        die "$file has a partial helix-steel-plugin-manager block"
    fi

    [ "$has_begin" -eq 1 ]
}

append_helix_config() {
    mkdir -p "$config_dir" || die "failed to create $config_dir"
    [ -f "$helix_scm" ] || : > "$helix_scm"

    begin=';; BEGIN helix-steel-plugin-manager'
    end=';; END helix-steel-plugin-manager'

    if marker_state "$helix_scm" "$begin" "$end"; then
        printf 'helix.scm already contains plugin manager setup\n'
        return 0
    fi

    {
        printf '\n%s\n' "$begin"
        cat <<'EOF'
(require (only-in "helix/plugin-manager.scm"
                  plugin-install
                  plugin-update
                  plugin-remove
                  plugin-enable
                  plugin-disable
                  plugin-load
                  plugin-load-all
                  plugin-list))

(provide plugin-install
         plugin-update
         plugin-remove
         plugin-enable
         plugin-disable
         plugin-load
         plugin-load-all
         plugin-list)
EOF
        printf '%s\n' "$end"
    } >> "$helix_scm"

    printf 'Updated %s\n' "$helix_scm"
}

append_init_config() {
    mkdir -p "$config_dir" || die "failed to create $config_dir"
    [ -f "$init_scm" ] || : > "$init_scm"

    begin=';; BEGIN helix-steel-plugin-manager'
    end=';; END helix-steel-plugin-manager'

    if marker_state "$init_scm" "$begin" "$end"; then
        printf 'init.scm already contains plugin manager setup\n'
        return 0
    fi

    {
        printf '\n%s\n' "$begin"
        cat <<'EOF'
(require (only-in "helix/plugin-manager.scm" plugin-load-all))
(plugin-load-all)
EOF
        printf '%s\n' "$end"
    } >> "$init_scm"

    printf 'Updated %s\n' "$init_scm"
}

if ! command -v git >/dev/null 2>&1; then
    warn "git was not found on PATH; plugin-install and plugin-update require git"
fi

install_module

if [ "$configure" -eq 1 ]; then
    append_helix_config
    append_init_config
else
    cat <<EOF

Next step:
  Add the setup snippets from README.md to:
    $helix_scm
    $init_scm

Or rerun:
  sh $script --configure
EOF
fi

printf '\nDone. Restart Helix or reload the Steel configuration.\n'
