#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case);
use Time::Piece ();

Getopt::Long::GetOptions(
	'verbose|v+' => \(my $verbose = 0),
	# 'run|r' => \(my $run_real),
	'sync|s' => \(my $sync_db),
	'severity=s' => \(my $severity_min = 5),
	# 'hold-time|H=s' => \(my $hold_time_spec = '6 hr')
);

my $now = time();

$SIG{TERM} = $SIG{INT} = $SIG{QUIT} = $SIG{HUP} = sub { cleanup(); exit(1); };
END { cleanup(); }

($severity_min // '') =~ m/^[1-5]$/s ||
	die("--severity can be a value from 1-5 (critical-lowest); default is 5\n");

# Pacman DB info
if ($sync_db) {
	system("sudo pacman -Sy");
} else {
	print("Skipping DB sync\n");
}

my $upgradable_names = [ map {$_} (`pacman -Qu` =~ m/^\S+/mg) ];
my $name_len_max = 0;
for my $pac_name (@$upgradable_names) {
	($_ = length($pac_name)) && ($_ > $name_len_max) && ($name_len_max = $_);
}

my ($pac_list, $pac_map) = load_pacman($upgradable_names);
my $upgradable_pac_list = [ sort {$a->{build_epoch} <=> $b->{build_epoch}} @$pac_list ];
print("Upgradable package count: ".scalar(keys @$pac_list)."\n");

# Web issue pages
my $issue_oldest_epoch = $now - 21 * 24 * 60 * 60; # ignore issues before this TS
my $issue_max_hist_cnt = 2000; # MAX number of recent issues to consider
print("Ignoring issues created prior to: ".Time::Piece::localtime($issue_oldest_epoch)->strftime('%F %T')."\n");

my $loaded_issues = load_issues($issue_max_hist_cnt, $issue_oldest_epoch, $pac_map); # $pac_issue_map
print("GitLab issue count: ".scalar(keys @$loaded_issues)."\n");

my $issue_cnt = 0;

for my $pac (@$upgradable_pac_list) {
	my $pac_stat_msg = $pac->{Name}." : ";
	$pac_stat_msg .= Time::Piece::localtime($pac->{build_epoch})->strftime('%F %T');
	$pac_stat_msg .= ", ".$pac->{Description};
	if (my $pac_issues = $pac->{issues}) {
		$issue_cnt++;
		$pac_stat_msg .= ", ISSUES" if $verbose;
		print($pac_stat_msg."\n");
		for my $issue (@$pac_issues) {
			my ($pac_name, $text, $url) = @$issue{qw/pac text url/};
			print("    $text\n    $url\n");
		}
	} elsif ($verbose) {
		print($pac_stat_msg."\n");
	}
}

print STDERR "WARNING: Upgradable package issue count: $issue_cnt\n";
$issue_cnt && exit(1);

exit(0);

# =================================

sub load_pacman {
	my ($upgradable_names) = @_;
	my $cmd = "TZ=GMT pacman -Si ".join(' ', @$upgradable_names);
	my ($pac_list, $pac_map) = ([], {});
	for my $pac_info_text (split("\n\n", readpipe($cmd))) {
		my $props = {($pac_info_text =~ m{^\h*([^\:\v]+?)\h*:\h*(\V*?)\h*$}gm)};
		scalar(%$props) || next;
		#my $pac_date = $props->{'Build Date'} =~ s/ \w*$//r;
		my $pac_buit_epoch = $props->{build_epoch} = int(Time::Piece->strptime($props->{'Build Date'}, '%Y-%m-%dT%H:%M:%S %Z')->epoch);
		# $props->{hold} = $pac_buit_epoch > $accept_ts ? 1 : 0;
		push(@$pac_list, $props);
		$pac_map->{$props->{Name}} = $props;
	}
	return ($pac_list, $pac_map);
}

sub load_issues { # https://docs.gitlab.com/ee/api/issues.html
	my ($issue_max_hist_cnt, $issue_oldest_epoch, $upgradable_pac_map) = @_;
	my ($issue_list, $pac_issue_map) = ([], {});

	my $url_templ_page = 'https://gitlab.archlinux.org/api/v4/issues/?order_by=created_at&sort=desc&state=opened&scope=all';
	# my $url_templ_page = 'https://gitlab.archlinux.org/api/v4/issues/?order_by=created_at&sort=desc&state=opened&scope=all&labels=scope::bug';
	$url_templ_page .= '&page=${page}&per_page=100';

	my $axess_token = `cat $ENV{HOME}/.config/axess/gitlab-archlinux-token` =~ s/\s+//gsr;
	my $web_call_cmd = "curl -sL --header 'PRIVATE-TOKEN: $axess_token' '$url_templ_page'";

	for (my $page_idx = 1; $page_idx <= 100; $page_idx++) {
		my $cmd = $web_call_cmd =~ s"(\$\{(\w+)\})"{page => $page_idx}->{$2} // $1"ger;
		# print("$cmd\n");
		my $json_text = readpipe($cmd);
		my $json_res = json_parse_obj($json_text);
		$json_res->{err} && die($json_res->{err}."\n");

		my ($eof, $page_issues) = load_issues_from_json($json_res->{res}, $issue_oldest_epoch, $upgradable_pac_map);
		push(@$issue_list, @$page_issues);
		last if $eof || scalar(@$issue_list) > $issue_max_hist_cnt;
	}

	return $issue_list;
}

sub load_issues_from_json {
	my ($page_list, $issue_oldest_epoch, $upgradable_pac_map) = @_;
	my $page_issues = [];
	my $batch_isue_cnt = scalar(@$page_list);

	ISSUE: for my $issue_json (@$page_list) {
		my $pac_name = $issue_json->{web_url} =~ m{([^/]+)/-/} ? $1 : do {
			print STDERR "Can't infer project name from URL: $issue_json->{web_url}\n"; next ISSUE
		};
		my $pac = $upgradable_pac_map->{$pac_name}; #  // next; # not slated for an upgrade - ignore

		my $issue_ts = int(Time::Piece->strptime(substr($issue_json->{created_at}, 0, 19).' GMT', '%Y-%m-%dT%H:%M:%S %Z')->epoch);
		$verbose > 1 &&
			print("$pac_name : $issue_json->{id} : ".Time::Piece::localtime($issue_ts)->strftime('%F %T')." : $issue_json->{title}\n");
		($issue_ts < $issue_oldest_epoch) && return (1, $page_issues);

		my $labels = $issue_json->{labels};
		for my $lab (@$labels) { # https://gitlab.archlinux.org/groups/archlinux/-/labels?page=2
			if (index($lab, 'severity::') == 0 && substr($lab, 10, 1) > $severity_min) { # severity::4-low, severity::5-lowest
				next ISSUE;
			}
			if (index('scope::documentation|scope::enhancement|scope::feature|scope::question|scope::reproducibility|', $lab) > 0) {
				next ISSUE;
			}
		}

		$verbose > 1 && print("$pac_name : OK\n");
		my $issue = {pac => $pac_name, url => $issue_json->{web_url}, text => $issue_json->{title}, ts => $issue_json->{created_at}};
		push(@$page_issues, $issue);
		$pac && push(@{$pac->{issues} //= []}, $issue);
	}
	return ($batch_isue_cnt < 100, $page_issues);
}

sub cleanup {
	# system("rm -rf '$work_dir'/*");
}

sub json_parse_obj { # parses JSON text into a Perl hashmap/array structure
	my ($json_text) = @_;
	my ($hier, $ppos, $obj, $pname, $pval, $objn) = ([], 0);
	my $err = sub { # compose error object from a message & JSON RegEx
		{err => $_[0], pos => $-[0], token => ($_=$1//$2//$3), msg => $_[0].': '.($-[0] // '-1').': '.$_}
	};
	$json_text =~ m/^\s*([\{\[])/s || return $err->('root must be an object'); # shortcut execution to reduce in-loop checks
	my $consts = ($::{json_parse_consts} //= {true => 1, false => '', null => undef});
	while ($json_text =~ m/\s* (?: ([\,\:\{\}\[\]]) | "( [^"\\]*+ (?:\\.[^"\\]*+)* )" | (null|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false))/gsx) {
		$ppos != $-[0] && return $err->("inconsecutive match");
		$ppos = $+[0];
		if (my $cmd_ch = $1) { # lexical characters: , : [ ] { }
			if ($cmd_ch eq ',') { # next element in map or array
				$pval || return $err->("incomplete item, missing value");
				$pname = $pval = undef;
			} elsif ($cmd_ch eq ':') { # key-value separator
				defined($pname) || return $err->("prop name not defined");
				defined($pval) && return $err->("unexpected colon");
				$pval = 0;
			} elsif ($cmd_ch eq '{' || $cmd_ch eq '[') { # start of object or array
				$objn = $cmd_ch eq '{' ? {} : [];
				if (defined($obj)) { # previous object exists (not the initial pass)
					if (ref $obj eq 'HASH') { # prev object is HASH
						defined($pname) || return $err->("unknown prop name");
						$obj->{$pname} = $objn;
					} else {
						defined($pval) && return $err->("unexpected start of obj");
						push(@$obj, $objn);
					}
					push(@$hier, $obj);
				}
				$obj = $objn;
				$pname = $pval = undef;
			} elsif ($cmd_ch eq '}') {
				ref $obj eq 'HASH' || return $err->("HASH object is expected");
				defined($pname) && !$pval && return $err->("prop $pname has no value");
				$obj = pop(@$hier) //
					return substr($json_text, $+[0]) =~ m/^\s*$/s ? {res => $obj} : $err->("text after JSON end");
				$pname = undef;
				$pval = 1;
			} elsif ($cmd_ch eq ']') {
				ref $obj eq 'ARRAY' || return $err->("wrong object type, expected ARRAY");
				$obj = pop(@$hier) //
					return substr($json_text, $+[0]) =~ m/^\s*$/s ? {res => $obj} : $err->("text after JSON end");
				$pname = undef;
				$pval = 1;
			}
		} else { # regular value
			$pval && return $err->("value was already read");

			my $val = defined($2) ?
				(index($2, "\\") == -1 ? $2 : $2 =~ s{\\(?:(["/\\bfnrt])|u([0-9a-fA-F]{4}))}{
						$1 ? $1 =~ tr|"/\\bfnrt|"/\\\b\f\n\r\t|r : chr(hex '0x'.$2)
					}gerx # JSON escaping rules: https://www.json.org/json-en.html
				) :
				(exists $consts->{$3} ? $consts->{$3} : $3);

			if (ref $obj eq 'HASH') {
				if (defined($pname)) {
					defined($pval) || return $err->("name and value must be separated");
					$obj->{$pname} = $val;
					$pval = 1;
				} else {
					$pname = $val;
				}
			} else {
				push(@$obj, $val);
				$pval = 1;
			}
		}
	}
	return $err->("JSON ended prematurely");
} # returns either {res => obj} or {err => "err", pos => 123, token => "last match", msg => "err+details"}
