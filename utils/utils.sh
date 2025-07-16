#!/usr/bin/env bash

set -euo pipefail

yesPattern='^(y|Y|yes|Yes|YES)$'

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
RESET='\e[0m'

error() {
	local inner
	inner=$(printf "$1" "${@:2}")
	printf "${RED}Error:${RESET} %b\n" "$inner" >&2
}

info() {
	local inner
	inner=$(printf "$1" "${@:2}")
	printf "${GREEN}Info:${RESET} %b\n" "$inner" >&1
}

warning() {
	local inner
	inner=$(printf "$1" "${@:2}")
	printf "${YELLOW}Warning:${RESET} %b\n" "$inner" >&2
}

check_input() {
	local input="$1"

	if [[ $input == q ]]; then
		return 2
	fi
	if [[ -z "$input" ]]; then
		error "Input cannot be empty."
		return 3
	fi
	return 0
}

check_file() {
	local file="$1"

	if [[ ! -f $file ]]; then
		error "File not found: $file" >&2
		return 2
	elif [[ ! -s $file ]]; then
		error "File is empty: $file" >&2
		return 2
	fi

}
get_file_name() {
	local input content
	local c=0

	while ((c < 3)); do
		((c++))
		read -p "Enter filename or return prev opt with 'q': " input

		check_input "$input"
		case $? in
		2) return 2 ;;
		3) continue ;;
		esac

		if ! check_file "$input"; then
			continue
		fi
		break
	done

	if ((c >= 3)); then
		warning "Too many failed attempts giving up."
		return 3
	fi
	printf "%s" "$input"
}

get_input() {
	local text="${1}"
	local secret="${2:-0}"
	local verify="${3:-0}"
	local input input2 result
	local c=0

	while ((c < 3)); do
		((c++))

		echo "$text" >&2

		if ((secret)); then
			read -s input
			echo >&2
		else
			read -rp "" input
		fi

		check_input "$input"
		case $? in
		2) return 2 ;;
		3) continue ;;
		esac

		if ((verify)); then
			echo "Re-enter to verify:" >&2
			if ((secret)); then
				read -s input2
				echo >&2
			else
				read -rp "" input2
			fi

			if [[ $input != $input2 ]]; then
				warning "Values do not match—try again!"
				sleep 1
				continue
			fi
		fi

		result="$input"
		break
	done

	if ((c >= 3)); then
		warning "Too many failed attempts—giving up."
		return 3
	fi

	printf "%s" "$result"
	return 0
}

write_file() {
	local data="$1"
	local out

	while true; do
		read -p "Enter output filename: " out

		if [[ "$out" == "$0" ]]; then
			error "Refusing to overwrite the script itself!"
			continue
		fi

		if ! printf '%s\n' "$data" >"$out" 2>/dev/null; then
			error "Could not write to '$out'. \
        Check permissions or disk space.\
        \nPlease try a different path or filename."
			continue
		fi

		sleep 1
		info "Data written to : $out"
		break
	done
}

tmpfiles=()
trap 'rm -f "${tmpfiles[@]:-}"' EXIT

create_temp_file() {
	local src="$1"
	local tf

	tf=$(
		umask 177
		mktemp
	) || {
		error "Could not create temporary file."
		exit 1
	}

	if ! printf '%s' "$src" >"$tf"; then
		error "Failed to write to temp file $tf."
		rm -f "$tf"
		exit 1
	fi

	tmpfiles+=("$tf")
	echo "$tf"
}

time_animation() {
	local total=$1
	local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
	local len=${#frames}
	local i=0
	while ((total > 0)); do
		local ch="${frames:i++%len:1}"
		printf "\r%s Running... %3ds left" "$ch" "$total"
		sleep 1
		((total--))
	done
	printf "\rFinished!             \n"
}

wait_until() {
	local time="$1"
	local info="$2"
	local error="$3"

	if ((time > 0)); then
		info "$info" "$time"
		time_animation "$time"
	else
		warning "$error"
	fi

}

approve() {
	local msg="$1"
	read -r -p "$msg" fixapprv
	if [[ ! $fixapprv =~ $yesPattern ]]; then
		warning "Process aborted; exiting."
		exit 0
	fi
}
