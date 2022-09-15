#!/usr/bin/env perl

use utf8;
use strict;
use warnings;

binmode(STDOUT, ':utf8');

package State;

use constant {
	LISTING => 0,
	FETCHING => 1,
	OPTIONS => 2,
	SHOWLINK => 3,
	SEARCHING => 4,
};
our $state = LISTING;
our %args = ();

# terminal size and a few escape codes
# for movement
package Terminal;

our $width = qx[tput cols];
our $height = qx[tput lines];
our $bottom = "\x1b[H\x1b[${height}B";
our $goto_top = "\x1b[H";
our $erase = "\x1b[2J";

package Colors;

our $bold = "\x1b[1m";
our $italic = "\x1b[3m";
our $black = "\x1b[30m";
our $red = "\x1b[31m";
our $green = "\x1b[32m";
our $yellow = "\x1b[33m";
our $blue = "\x1b[34m";
our $magenta = "\x1b[35m";
our $cyan = "\x1b[36m";
our $white = "\x1b[37m";
our $default = "\x1b[39m";
our $reset = "\x1b[0m";

package Launch;

use File::Which;

sub transmission {
	my $link = shift;
	my $prog;
	if($prog = which 'transmission-cli') {
		system $prog, $link;
	}	elsif($prog = which 'transmission-gtk') {
		system $prog, $link;
	} elsif($prog = which 'transmission-qt') {
		system $prog, $link;
	}
}

sub clipboard {
	my $link = shift;
	my $prog;
	if($prog = which 'wl-copy') {
		system $prog, $link;
	}	elsif($prog = which 'xclip') {
		open(my $xclip, '|-', $prog);
		print $xclip $link;
	} elsif($prog = which 'xsel') {
		open(my $xsel, '|-', $prog);
		print $xsel $link;
	}
}

package Torrent;
use LWP::Simple qw<get $ua>;

# set the user agent otherwise the website blocks us
$ua->agent("Firefox (jk lol i'm scraping your website)");

sub torrent {
	my ($id, $title, $size, $seed, $leech) = @_;
	return bless {
		url => "https://cpasbien.ch/torrent/$id",
		title => $title,
		size => $size,
		seed => $seed,
		leech => $leech
	}, 'Torrent';
}

# string representation of a torrent, of the format:
# <title>       <size> <seed> S <leech> L
sub str {
	my $self = shift;
	my $leftside = $self->{title};
	my $rightside = "$self->{size}  $self->{seed} S  $self->{leech} L";
	my $whitespace;
	if(length($leftside) + length($rightside) + 4 > $Terminal::width) {
		my $size = ($Terminal::width - length($rightside) - 5);
		$leftside = substr $self->{title}, 0, $size;
		$leftside .= '…';
		$whitespace = '  ';
	} else {
		$whitespace = ' ' x ($Terminal::width - length($leftside) - length($rightside) - 2); # 2 is the length of the left padding ('  ' or ' >')
	}
	return "$leftside$whitespace$rightside\n";
}

use constant URL => "https://cpasbien.ch/";

# returns an array of Torrent::torrent from
# the parsed HTML
sub parse {
	my $content = shift;
	my @result;

	while($content =~ m,<a\s
		href="/?torrent/(\d+)"\s # torrent id
		title="([^"]+)" \s [^>]*
	>.*?</a>
		.<div \s class="poid">([^<]+)</div> # size
		.<div \s class="up">
			<span \s class="seed_ok">(\d+)</span> # seed
		</div>
		.<div \s class="down">(\d+)</div> # leech
	</td>,sgx) {
		push @result, torrent($1, $2, $3, $4, $5);
	}

	return @result;
}

# fetch index and parse it
sub fetch_all {
	my $content = get(URL);
	die "can't access teh website ;(" unless $content;
	return parse $content;
}

# fetch the specified query and parse it
sub search {
	my $query = shift;
	my $content = get("https://cpasbien.ch/recherche/$query");
	die "can't make teh search ;(" unless $content;
	return parse $content;
}

sub get_real_link {
	my $url = shift;
	get($url) =~ m,get_torrent/[^']+,;
	return "https://cpasbien.ch/$&";
}

package Input;

use experimental 'switch';
use Term::ReadKey;

sub restore {
	ReadMode 0;
}

sub prepare {
	# cbreak: echo off, unbuffered, signals enabled.
	ReadMode 3;
	END { restore; }
}

sub key {
	return ReadKey 0;
}

sub handle_key {
	my $key = shift;
	# torrents length, maximum line the user can scroll to
	my $max = shift;
	my $cur = shift;

	given($State::state) {
		when(State::LISTING) {
			given($key) {
				# down
				when(/j|n/) {
					if(${$cur} < $max) {
						${$cur}++;
					}
				}
				# up
				when(/k|p/) {
					if(${$cur} > 0) {
						${$cur}--;
					}
				}
				# fetch link and show more options on spacebar
				when(' ') {
					$State::state = State::FETCHING;
				}
				# search
				when('/') {
					$State::state = State::SEARCHING;
				}
			}
		}

		when(State::OPTIONS) {
			given($key) {
				when('s') {
					$State::state = State::SHOWLINK;
				}
				when(/o|t/) {
					Launch::transmission($State::args->{link});
				}
				when('c') {
					Launch::clipboard($State::args->{link});
				}
				default {
					$State::state = State::LISTING;
				}
			}
		}

		when(State::SEARCHING) {
			given($key) {
				my %keys = GetControlChars;
				when($keys{ERASE}) {
					chop $State::args{query};
				}
				# <C-W> to remove the last word
				# (it should probably remove the word before
				# the cursor, but we don't even have a cursor...)
				when($keys{ERASEWORD}) {
					$State::args{query} =~ s/(?:(.*) )?\w+\s*$/$1/;
				}
				# enter key
				when(/$keys{EOF}|\n/) {
					$State::state = State::LISTING;
				}
				default {
					if(not $State::args{query}) {
						$State::args{query} = '';
					}
					$State::args{query} .= $key;
				}
			}
		}

		default {
			$State::state = State::LISTING;
		}
	}
}

package main;

use experimental 'switch';
use experimental 'smartmatch';

# currently highlighted torrent;
# the one with a leading '> ' when printed
my $cur = 0;

sub print_torrents {
	print $Terminal::erase;
	print $Terminal::goto_top;

	my @torrents = @{$_[0]};
	my $i = 0;
	foreach my $torrent (@torrents) {
		if($i ~~ [$cur..$cur+$Terminal::height-2]) {
			if($i == $cur) {
				print "$Colors::yellow> $Colors::reset";
			} else {
				print '  ';
			}
			print $torrent->str;
		}
		$i++;
	}
}

# returns bottom line's text, without printing it,
# depending on the current application state
sub bottomline {
	given($state) {
		when(State::LISTING) {
			my ($index, $total) = @_;
			return "$Colors::bold$index$Colors::reset/$Colors::bold$total$Colors::reset, press $Colors::green${Colors::bold}space$Colors::reset for options, $Colors::green${Colors::bold}j$Colors::reset/$Colors::green${Colors::bold}k$Colors::reset to move, $Colors::green${Colors::bold}/$Colors::reset to search";
		}
		when(State::FETCHING) {
			return "Fetching link...";
		}
		when(State::OPTIONS) {
			return "Press $Colors::green${Colors::bold}o$Colors::reset to open the link in Transmission, $Colors::green${Colors::bold}c$Colors::reset to copy it, and $Colors::green${Colors::bold}s$Colors::reset to show it";
		}
		when(State::SHOWLINK) {
			return $State::args->{link};
		}
		when(State::SEARCHING) {
			if($State::args{query}) {
				return "Search: $State::args{query}";
			} else {
				return 'Search: ';
			}
		}
	}
}

sub print_bottomline {
	my ($cur, $torrents_length) = @_;
	my $text = bottomline $cur+1, $torrents_length+1;
	my $unformatted_text = $text =~ s/\x1b\[\d+.//gr; # remove colors
	my $whitespace = ' ' x ($Terminal::width - length $unformatted_text);
	print "$Terminal::bottom$text$whitespace";
}

sub handle_state {
	my @torrents = @{$_[0]};
	given($State::state) {
		when(State::FETCHING) {
			my $torrent = $torrents[$cur];
			my $link = Torrent::get_real_link $torrent->{url};
			$State::state = State::OPTIONS;
			return { link => $link };
		}
		default { return $State::args }
	}
}

sub main {
	my @torrents;
	if($State::state == State::LISTING && $State::args{query}) {
		@torrents = Torrent::search $State::args{query};
		delete $State::args{query};
		$cur = 0;
	} else {
		@torrents = @_ > 0 ? @_ : Torrent::fetch_all;
	}

	$State::args = handle_state \@torrents;

	print_torrents \@torrents;
	print_bottomline $cur, $#torrents;

	Input::prepare;
	my $key = Input::key;
	Input::handle_key $key, $#torrents, \$cur;
	&main(@torrents);
}

&main::main;
