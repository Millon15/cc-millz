#!/usr/bin/env bash
# sl-redact.sh: scrub secrets from stdin to stdout; --check prints nothing and exits 1 on any hit.
#
# Plain mode scrubs the raw text.
# --jsonl decodes each line, scrubs every string value, and re-encodes it,
# so an escaped `\"quoted secret\"` inside JSON is seen as the quoted value it is.
# Lines that are not JSON are scrubbed as plain text.
set -euo pipefail

usage() {
	echo "usage: sl-redact.sh [--check] [--jsonl] < input" >&2
	exit 64
}

main() {
	local check=0 jsonl=0 arg
	for arg in "$@"; do
		case "$arg" in
		--check) check=1 ;;
		--jsonl) jsonl=1 ;;
		*) usage ;;
		esac
	done
	SL_REDACT_CHECK="$check" SL_REDACT_JSONL="$jsonl" perl -CSD -MJSON::PP -MB -e "$(scrubber_program)"
}

# Each rule captures the text to keep in $1 and the secret in $2.
scrubber_program() {
	cat <<'PERL'
my $keys = qr{(?<![A-Za-z0-9])(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|auth)}i;
my $v = qr{[^\s"'\\,;]+};
my @rules = (
	[ "private-key", qr{()(-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----)}s ],
	[ "aws-key",     qr{()(\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)} ],
	[ "github",      qr{()(\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}))} ],
	[ "slack",       qr{()(\bxox[abprs]-[A-Za-z0-9-]{10,})} ],
	[ "anthropic",   qr{()(\bsk-ant-[A-Za-z0-9_-]{20,})} ],
	[ "openai",      qr{()(\bsk-(?:proj-)?[A-Za-z0-9_-]{20,})} ],
	[ "google",      qr{()(\bAIza[0-9A-Za-z_-]{35})} ],
	[ "jwt",         qr{()(\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})} ],
	[ "url-cred",    qr{(://)([^\s/:@"\\]+:[^\s/@"\\]+)(?=@)} ],
	[ "bearer",      qr{(?i)(\bbearer\s+)((?!\[REDACTED)$v)} ],
	[ "assignment",  qr{($keys(?:\\?["'])?\s{0,3}[:=]\s{0,3}\\")((?!\[REDACTED)[^"\\\n]+)(?=\\")} ],
	[ "assignment",  qr{($keys["']?\s{0,3}[:=]\s{0,3}")((?!\[REDACTED)[^"\n]+)(?=")} ],
	[ "assignment",  qr{($keys["']?\s{0,3}[:=]\s{0,3}')((?!\[REDACTED)[^'\n]+)(?=')} ],
	[ "assignment",  qr{($keys["']?\s{0,3}[:=]\s{0,3})((?!\[REDACTED)$v)} ],
);
my $hits = 0;

sub scrub {
	my ($text) = @_;
	for my $rule (@rules) {
		my ($kind, $re) = @$rule;
		$hits += ($text =~ s/$re/$1\[REDACTED:$kind\]/g) || 0;
	}
	return $text;
}

sub scrub_tree {
	my ($node) = @_;
	return [ map { scrub_tree($_) } @$node ] if ref $node eq 'ARRAY';
	return { map { $_ => scrub_tree($node->{$_}) } keys %$node } if ref $node eq 'HASH';
	return $node if !defined $node || ref $node || is_number($node);
	return scrub($node);
}

# A decoded JSON number must not pass through a regex: that would re-encode it as a string.
sub is_number {
	my $flags = B::svref_2object(\$_[0])->FLAGS;
	return ($flags & (B::SVp_IOK | B::SVp_NOK)) && !($flags & B::SVp_POK);
}

sub scrub_json_line {
	my ($line, $codec) = @_;
	my $tree = eval { $codec->decode($line) };
	return scrub($line) unless defined $tree;
	return $codec->encode(scrub_tree($tree));
}

my $input = do { local $/; <STDIN> };
my $output;
if ($ENV{SL_REDACT_JSONL}) {
	my $codec = JSON::PP->new->canonical->allow_nonref;
	$output = join '', map { (/\S/ ? scrub_json_line($_ =~ s/\n\z//r, $codec) : $_ =~ s/\n\z//r) . "\n" } split /(?<=\n)/, $input;
} else {
	$output = scrub($input);
}
exit($hits ? 1 : 0) if $ENV{SL_REDACT_CHECK};
print $output;
PERL
}

main "$@"
