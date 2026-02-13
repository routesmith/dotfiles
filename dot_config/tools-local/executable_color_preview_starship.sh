#!/usr/bin/env bash

# color_preview_starship.sh — color swatch and matrix viewer for starship.toml
#
# Default: simple matrix
# Use --grid for bordered matrix
# You may optionally provide a path to a starship.toml file
#
# NOTE: Requires the use of a palette in your starship.toml.

MODE="simple"
STARSHIP_TOML="$HOME/.config/starship.toml"

# Parse args
for arg in "$@"; do
    if [[ "$arg" == "--grid" ]]; then
        MODE="grid"
    elif [[ -f "$arg" ]]; then
        STARSHIP_TOML="$arg"
    fi
done

if [[ "$1" == "--help" ]]; then
    echo "Usage: $0 [--grid] [path/to/starship.toml]"
    echo
    echo "Displays color swatches and a foreground/background matrix for the"
    echo "currently selected palette in a starship.toml file."
    echo
    echo "Options:"
    echo "  --grid     Show matrix with borders (NOTE: terminal size may be exceeded for large palettes.)"
    echo "  --help     Show this help message"
    echo
    echo "If no file is given, defaults to: ~/.config/starship.toml"
    exit 0
fi

# Detect active palette
ACTIVE_PALETTE=$(grep -E '^\s*palette\s*=' "$STARSHIP_TOML" | awk -F '=' '{gsub(/[[:space:]]*/, "", $2); gsub(/["'\'']/, "", $2); print $2}')
# Only for debugging.
# echo "Parsed palette = '$ACTIVE_PALETTE'"
# grep -A5 "\[palettes.$ACTIVE_PALETTE\]" "$STARSHIP_TOML"

if [[ -z "$ACTIVE_PALETTE" ]]; then
    echo "❌ No 'palette = ...' line found in $STARSHIP_TOML"
    exit 1
fi

# Extract that palette section
declare -A COLORS
in_palette=0

while IFS= read -r line; do
    # Check if we're entering the desired palette
    # if [[ "$line" =~ ^\[palettes\.$ACTIVE_PALETTE\] ]]; then
    if [[ "$line" =~ ^[[:space:]]*\[palettes\.$ACTIVE_PALETTE\] ]]; then
        in_palette=1
        continue
    fi

    # Exit palette section if we hit a new [section]
    # if [[ "$line" =~ ^\[[^]]+\] ]]; then
    if [[ "$line" =~ ^[[:space:]]*\[[^]]+\] ]]; then
        in_palette=0
    fi

    if ((in_palette)); then
        line_cleaned="${line//[[:space:]]/}"
        key="${line_cleaned%%=*}"
        val="${line_cleaned#*=}"
        val="${val//\"/}"
        val="${val//\'/}"
        val="${val#\#}"

        if [[ "$val" =~ ^[0-9a-fA-F]{6}$ ]]; then
            COLORS["$key"]="$val"
        fi
    fi
done <"$STARSHIP_TOML"

# Sorted keys
keys=("${!COLORS[@]}")
IFS=$'\n' keys=($(sort <<<"${keys[*]}"))

abbrev() {
    local input="$1"

    if [[ "$input" == *_* ]]; then
        local first="${input%%_*}"
        local second="${input#*_}"
        printf "%s%s" "${first:0:1}" "${second:0:1}"
    else
        # Safe digit-extraction loop
        local prefix digit
        prefix="$input"
        digit=""
        while [[ -n "$prefix" && "${prefix: -1}" =~ [0-9] ]]; do
            digit="${prefix: -1}$digit"
            prefix="${prefix%?}"
        done
        if [[ -n "$digit" ]]; then
            printf "%s%s" "${prefix:0:1}" "$digit"
        else
            printf "%s0" "${input:0:1}"
        fi
    fi
}

# ─────────────────────────────────────────────
# 🔹 1. INDIVIDUAL COLOR SWATCHES
# ─────────────────────────────────────────────

echo -e "\n\033[1mUsing colors from:\033[0m $STARSHIP_TOML"
echo -e "\n\033[1m▶ Individual color swatches:\033[0m"
for name in "${keys[@]}"; do
    hex=${COLORS[$name]}
    r=$((16#${hex:0:2}))
    g=$((16#${hex:2:2}))
    b=$((16#${hex:4:2}))

    fg="\e[38;2;${r};${g};${b}m█ fg sample\e[0m"
    bg="\e[48;2;${r};${g};${b}m\e[38;2;255;255;255m BG TEST \e[0m"

    printf "%-20s #%s  %b  %b\n" "$name" "$hex" "$fg" "$bg"
done

# ─────────────────────────────────────────────
# 🔹 2. FG × BG MATRIX (with headers)
# ─────────────────────────────────────────────

if [[ "$MODE" == "simple" ]]; then
    echo -e "\n\033[1m▶ FG × BG matrix (2-char swatches):\033[0m"

    # Column headers
    printf "%-14s " " " # empty cell for row labels
    for bg in "${keys[@]}"; do
        printf " %2s" "$(abbrev "$bg")"
    done
    echo

    # Color matrix
    for fg in "${keys[@]}"; do
        fg_hex=${COLORS[$fg]}
        rfg=$((16#${fg_hex:0:2}))
        gfg=$((16#${fg_hex:2:2}))
        bfg=$((16#${fg_hex:4:2}))

        abbrev_fg=$(abbrev "$fg")
        printf "%-14s " "$fg"

        for bg in "${keys[@]}"; do
            bg_hex=${COLORS[$bg]}
            rbg=$((16#${bg_hex:0:2}))
            gbg=$((16#${bg_hex:2:2}))
            bbg=$((16#${bg_hex:4:2}))

            printf "\e[38;2;%d;%d;%dm\e[48;2;%d;%d;%dm %2s\e[0m" \
                "$rfg" "$gfg" "$bfg" "$rbg" "$gbg" "$bbg" "$abbrev_fg"
        done
        echo
    done
    exit 0
fi

# ─────────────────────────────────────────────
# 🔹 2. FG × BG MATRIX (Grid with borders)
# ─────────────────────────────────────────────

echo -e "\n\033[1m▶ FG × BG matrix (grid layout):\033[0m"

# Prepare column header
printf "%-16s┃" ""
for bg in "${keys[@]}"; do
    printf " %2s ┃" "$(abbrev "$bg")"
done
echo

# Separator line
printf "────────────────┼"
for _ in "${keys[@]}"; do
    printf "────┼"
done
echo

# Matrix body
for fg in "${keys[@]}"; do
    fg_hex=${COLORS[$fg]}
    rfg=$((16#${fg_hex:0:2}))
    gfg=$((16#${fg_hex:2:2}))
    bfg=$((16#${fg_hex:4:2}))

    abbrev_fg=$(abbrev "$fg")
    printf "%-15s ┃" "$fg"

    for bg in "${keys[@]}"; do
        bg_hex=${COLORS[$bg]}
        rbg=$((16#${bg_hex:0:2}))
        gbg=$((16#${bg_hex:2:2}))
        bbg=$((16#${bg_hex:4:2}))

        printf "\e[38;2;%d;%d;%dm\e[48;2;%d;%d;%dm %2s \e[0m┃" \
            "$rfg" "$gfg" "$bfg" "$rbg" "$gbg" "$bbg" "$abbrev_fg"
    done
    echo
done
