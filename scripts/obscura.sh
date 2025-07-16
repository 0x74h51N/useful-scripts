#!/usr/bin/env bash
# scripts/encode.sh

set -euo pipefail

trap 'echo "[DEBUG ERR] Line $LINENO: \"$BASH_COMMAND\" exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
UTILS="$ROOT_DIR/utils/utils.sh"

if [[ ! -r "$UTILS" ]]; then
	printf 'Error: Cannot locate or read utils file at %s\n' "$UTILS" >&2
	exit 1
fi

source "$UTILS"

BANNER=$(
	cat <<'EOF'
#########################################################################
#                            obscura.sh                                 #
# --------------------------------------------------------------------- #
#                                                                       #
#   This script encodes or decodes strings or file contents securely    #
#   using OpenSSL AES-256-CBC encryption with PBKDF2 key stretching.    #
#   It supports both CLI flags and an interactive mode for casual       #
#   usage, with flexible input/output and password options.             #
#                                                                       #
# --------------------------------------------------------------------- #
#                                                                       #
#       ! WARNING: This is NOT military-grade encryption. !             #
#       It's reasonably secure against normal mortal people.            #
#         Not safe for highly sensitive or classified data.             #
#                                                                       #
#   Use at your own risk. Good enough for personal use, scripts,        #
#                       private logs, notes, and casual secrets.        #
#                                                       0x74h51N        #
#                                                                       #
#########################################################################
EOF
)

usage() {
	echo "$BANNER"
	echo
	cat <<EOF
Usage: $0 (-e | -d) [INPUT] [OPTIONS]

  Interactive Mode:
    -i, --interactive      Runs interactive mode for decode/encode

  INPUT (mutually exclusive, one required):
    -I, --in-file FILE     Read plaintext/ciphertext from FILE
    -s, --in-str  STR      Use STR as plaintext/ciphertext

  Mode (mutually exclusive, one required):
    -e, --encode           Encrypt INPUT (AES-256-CBC + PBKDF2-SHA256, base64)
    -d, --decode           Decrypt INPUT

  Password (mutually exclusive, one required):
    -P, --pass-file FILE   Read password from FILE
    -x, --pass-str  STR    Use STR as password

  Output:
    -O, --out-file FILE    Write result to FILE
                           (default: write to STDOUT)

  Common:
    -h, --help             Show this help message and exit

Examples:
  # Encrypt the contents of secret.txt, prompt pass interactively:
  $0 -e -I secret.txt -P pass.txt

  # Decrypt a base64 string with inline password, output to file:
  $0 -d -s \"U2FsdGVkX1...\" -x \"myPassword\" -O decrypted.bin

  # Read plaintext from STDIN, write cipher to STDOUT (no flags for output):
  echo \"hello\" | $0 -e -s \"hello\" -P pass.txt

EOF
}

#just in case
if ! command -v openssl &>/dev/null; then
	error "openssl not found! Please install it first."
	exit 127
fi

#openssl encode/decode options:
declare -r BASE_CMD=(openssl enc -aes-256-cbc -pbkdf2 -md sha256 -a -A -pass stdin)

declare -A MSG=(
	[prompt_select]="Select your process:"
	[option_encode]="1 - Encode"
	[option_decode]="2 - Decode"
	[option_exit]="3 - Exit"
	[ask_file]="Data from file? (y/N):"
	[secret_key_fil]="Secret key is on file? (y/N)"
	[ask_secret]="Enter your secret key or q to cancel:"
	[ask_input]="Enter input string:"
	[ask_write]="Do you want to write data to file? (y/N):"
	[err_empty]="Input cannot be empty."
	[err_invalid]="Invalid data or unknown error:"
	[warn_toomany]="Too many failed attempts—giving up."
	[warn_badpass]="Wrong password! Try again."
	[warn_inv_opt]="Invalid option. Please choose an available option."
	[err_inv_flag]="Invalid options. Run with -h/--help for usage."
	[err_both_mode]="Cannot use both --decode and --encode"
	[err_none_mode]="You must specify -d/--decode or -e/--encode"
	[err_none_inp]="You must specify -I/--in-file or -s/--in-str"
	[err_both_inp]="Cannot use both --in-file and --in-str at the same time"
	[err_none_pass]="You must specify -P/--pass-file or -x/--pass-str"
	[err_both_pass]="Cannot use both --pass-file and --pass-str at the same time"
	[success]="Process succeed"
	[exit_msg]="Exiting..."
)

interactive_mode=0
mode=""
input_file=""
input_str=""
file_output=""
pass_file=""
pass_str=""

coder() {
	local cmd=("${BASE_CMD[@]}")

	read -p "${MSG[ask_file]} " useFile
	if [[ $useFile =~ $yesPattern ]]; then
		input=$(get_file_name) || exit 1
	else
		input_str=$(get_input "${MSG[ask_input]}") || exit 1
		input=$(create_temp_file "$input_str")
	fi

	if [[ $mode == "decode" ]]; then
		cmd+=(-d)
	fi

	c=0
	while ((c < 3)); do
		c=$((c + 1))

		read -p "${MSG[secret_key_fil]} : " scrtOpt
		if [[ $scrtOpt =~ $yesPattern ]]; then
			filename=$(get_file_name) || continue
			key=$(<"$filename")
		else
			if [[ "$mode" == "encode" ]]; then
				key=$(get_input "${MSG[ask_secret]}" 1 1) || exit 1
			else
				key=$(get_input "${MSG[ask_secret]}" 1) || exit 1
			fi
		fi

		if ! coded=$(printf '%s' "$key" | "${cmd[@]}" -in "$input" 2>&1); then
			if echo "$coded" | grep -q "bad decrypt"; then
				warning "${MSG[warn_badpass]}"
			else
				error "${MSG[err_invalid]}\n%s" "$coded"
				exit 1
			fi
		else
			sleep 1
			echo
			read -p "${MSG[ask_write]} " wrtOpt
			if [[ $wrtOpt =~ $yesPattern ]]; then
				if ! write_file "$coded"; then
					continue
				fi
				exit 0
			else
				info "Output:\n%s" "$coded"
				exit 0
			fi
		fi
	done
	if ((c == 3)); then
		warning "${MSG[warn_toomany]}"
		exit 1
	fi
}

user_friendly() {
	echo "$BANNER"
	sleep 1

	while true; do
		printf "${MSG[prompt_select]} \n%s\n%s\n%s\n" \
			"${MSG[option_encode]}" \
			"${MSG[option_decode]}" \
			"${MSG[option_exit]}"
		read -p "> " prcs

		case "$prcs" in
		1)
			mode="encode"
			coder
			;;
		2)
			mode="decode"
			coder
			;;
		3)
			warning "${MSG[exit_msg]}"
			break
			;;
		*)
			warning "${MSG[warn_inv_opt]}"
			;;
		esac
	done
}

if [[ "${1-}" == "-i" || "${1-}" == "--interactive" ]]; then
	interactive_mode=1
	user_friendly
	exit 0
fi

PARSED=$(getopt \
	-o dehI:s:O:P:x \
	-l decode,encode,help,in-file:,in-str:,out-file:,pass-file:,pass-str \
	-- "$@") || {
	error "${MSG[err_inv_flag]}"
	exit 1
}

eval set -- "$PARSED"
while true; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-d | --decode)
		if [[ -n "$mode" ]]; then
			error "${MSG[err_both_mode]}" >&2
			exit 1
		fi
		mode=decode
		shift
		;;
	-e | --encode)
		if [[ -n "$mode" ]]; then
			error "${MSG[err_both_mode]}" >&2
			exit 1
		fi
		mode=encode
		shift
		;;
	-I | --in-file)
		input_file="$2"
		shift 2
		;;
	-s | --in-str)
		input_str="$2"
		shift 2
		;;
	-O | --out-file)
		file_output="$2"
		shift 2
		;;
	-P | --pass-file)
		pass_file="$2"
		shift 2
		;;
	-x | --pass-str)
		if [[ "$mode" == "encode" ]]; then
			pass_str=$(get_input "${MSG[ask_secret]}" 1 1) || exit 1
		else
			pass_str=$(get_input "${MSG[ask_secret]}" 1) || exit 1
		fi
		shift
		;;
	--)
		shift
		break
		;;
	*) break ;;
	esac
done

non_interactive() {
	local cmd=("${BASE_CMD[@]}")

	if [[ -z "$mode" ]]; then
		error "${MSG[err_none_mode]}" >&2
		exit 1
	fi

	if [[ -z "$input_file" && -z "$input_str" ]]; then
		error "${MSG[err_none_inp]}" >&2
		exit 1
	elif [[ -n "$input_file" && -n "$input_str" ]]; then
		error "${MSG[err_both_inp]}" >&2
		exit 1
	fi

	if [[ -z "$pass_file" && -z "$pass_str" ]]; then
		error "${MSG[err_none_pass]}" >&2
		exit 1
	elif [[ -n "$pass_file" && -n "$pass_str" ]]; then
		error "${MSG[err_both_pass]}" >&2
		exit 1
	fi

	if [[ -n "$input_file" ]]; then
		check_file "$input_file" || exit 1
		input="$input_file"
	else
		input=$(create_temp_file "$input_str")
	fi

	if [[ -n "$pass_file" ]]; then
		check_file "$pass_file" || exit 1
		key=$(<"$pass_file")
	else
		key="$pass_str"
	fi

	if [[ $mode == "decode" ]]; then
		cmd+=(-d)
	fi

	if [[ -n "$file_output" ]]; then
		cmd+=(-out "$file_output")
	fi

	if ! coded=$(printf '%s' "$key" | "${cmd[@]}" -in "$input" 2>&1); then
		if echo "$coded" | grep -q "bad decrypt"; then
			warning "${MSG[warn_badpass]}"
		else
			error "${MSG[err_invalid]}\n%s" "$coded"
			exit 1
		fi
	else
		[[ -z $file_output ]] && info "Output\n%s" "$coded" || info "$mode\n%s" "${MSG[success]}"
		exit 0
	fi
}

if ((interactive_mode == 0)); then
	non_interactive
fi
