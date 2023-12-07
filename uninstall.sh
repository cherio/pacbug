#!/bin/sh

srcdir="$(dirname "$(realpath "$0")")"
bindir="/usr/bin"

cd "$srcdir" || { echo "Dir $srcdir is inaccessible"; exit 1; }

ls -1 *.pl | ( while read pl_script; do
	[ -x "$pl_script" ] || continue;
	pl_basename="${pl_script%.*}"
	bin_file="$bindir/$pl_basename"
	file -bi "$bin_file" | grep -q 'perl;' && # must be a Perl script
		sudo rm -f "$bin_file" &&
		echo "'$pl_basename' was uninstalled"
done )
