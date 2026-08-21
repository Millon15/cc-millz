#!/usr/bin/env bash
#
# tests/fixtures/short-video-reader/stubs/whisper-cli.bash
#
# BEHAVIOURAL stub, with one honest asymmetry: the reader NEVER executes this
# binary. It only asks whether the name is on PATH and pairs it with a GGML
# model, then hands the operator a suggested command. So what this stub exists
# for is the detection half — being present on the hermetic PATH so the STT rung
# is reachable, and being absent so the "no free local transcription" rung is.
#
# The transcription half is implemented anyway, for the one case that runs the
# suggested command rather than only reading it: `-of <base>` names the output
# stem and `-otxt` asks for a text transcript, so `<base>.txt` is what a caller
# following the suggestion gets back.

set -euo pipefail

of=""
model=""
audio=""
want_txt=0
prev=""
for a in "$@"; do
	case "${prev}" in
	-of) of="${a}" ;;
	-m) model="${a}" ;;
	-f) audio="${a}" ;;
	esac
	[ "${a}" = "-otxt" ] && want_txt=1
	prev="${a}"
done

[ -n "${model}" ] && [ ! -f "${model}" ] && {
	printf 'whisper-cli-stub: no such model file: %s\n' "${model}" >&2
	exit 1
}

[ -n "${audio}" ] && [ ! -f "${audio}" ] && {
	printf 'whisper-cli-stub: no such audio file: %s\n' "${audio}" >&2
	exit 1
}

printf 'whisper-cli-stub: %s\n' "${audio:-<no input>}"

if [ "${want_txt}" -eq 1 ] && [ -n "${of}" ]; then
	mkdir -p "$(dirname "${of}")"
	printf 'fixture transcript line one\nfixture transcript line two\n' >"${of}.txt"
fi

exit 0
