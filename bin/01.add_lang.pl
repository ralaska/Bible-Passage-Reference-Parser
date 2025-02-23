use strict;
use warnings;
use Data::Dumper;
use Unicode::Normalize;
use JSON;
use MIME::Base64;

my ($lang) = @ARGV;
die "The first argument should be a language iso code (e.g., \"fr\")" unless ($lang && $lang =~ /^\w+$/);
my $dir = '../src';
my $test_dir = '../test';
my $regexp_space = "\\s";
my $valid_characters = "[\\d\\s.:,;\\x1e\\x1f&\\(\\)\x{ff08}\x{ff09}\\[\\]\\/\"'\\*=~\\-\x{2013}\x{2014}]";
my $letters = '';
my %valid_osises = make_valid_osises(qw(Gen Exod Lev Num Deut Josh Judg Ruth 1Sam 2Sam 1Kgs 2Kgs 1Chr 2Chr Ezra Neh Esth Job Ps Prov Eccl Song Isa Jer Lam Ezek Dan Hos Joel Amos Obad Jonah Mic Nah Hab Zeph Hag Zech Mal Matt Mark Luke John Acts Rom 1Cor 2Cor Gal Eph Phil Col 1Thess 2Thess 1Tim 2Tim Titus Phlm Heb Jas 1Pet 2Pet 1John 2John 3John Jude Rev Tob Jdt GkEsth Wis Sir Bar PrAzar Sus Bel SgThree EpJer 1Macc 2Macc 3Macc 4Macc 1Esd 2Esd PrMan AddEsth AddDan));

my %raw_abbrevs;
my %vars = get_vars();
my %abbrevs = get_abbrevs();
my @order = get_order();
my %all_abbrevs = make_tests();
my $default_alternates_file = "$dir/en/translation_additions.js";
my @translation_regexps = make_translations();
make_regexps(\@translation_regexps);
make_grammar();

sub make_translations
{
	my $out = get_file_contents("$dir/core/lang_translations.ts");
	my (@regexps, @aliases);
	foreach my $translation (@{$vars{'$TRANS'}})
	{
		my ($trans, $osis, $alias) = split /,/, $translation;
		push @regexps, $trans;
		next unless ($osis || $alias);
		$alias = 'default' unless ($alias);
		my $lc = lc $trans;
		$lc = '"' . $lc . '"' if ($lc =~ /\W/);
		my $string = "$lc: {";
		$string .= " system: \"$alias\"";
		$string .= ", osis: \"$osis\"" if ($osis);
		# The comma is OK because `current` and `default` are always at the end.
		push @aliases, "$string },";
	}
	my $alias = join "\x0a\t", @aliases;
	if (-f "$dir/$lang/translation_aliases.js")
	{
		$alias = get_file_contents("$dir/$lang/translation_aliases.js");
		$out =~ s/\t+(\$TRANS_ALIAS)/$1/g;
	}
	my $alternate = get_file_contents($default_alternates_file);
	$alternate = get_file_contents("$dir/$lang/translation_additions.js") if (-f "$dir/$lang/translation_additions.js");
	$alternate =~ s!^\(?\{[\r\n]+!!;
	$alternate =~ s!\}\)?[\r\n]*$!!;
	$out =~ s!//\$TRANS_ALIAS!$alias!g;
	$out =~ s!//\$TRANS_ALTERNATE!,\n$alternate!g;
	my $lang_isos = to_json($vars{'$LANG_ISOS'});
	$out =~ s/"\$LANG_ISOS"/$lang_isos/g;
	open OUT, ">:utf8", "$dir/$lang/translations.ts";
	print OUT $out;
	close OUT;
	if ($out =~ /(\$[A-Z_]+)/)
	{
		die "$1\nTranslations: Capital variable";
	}
	return @regexps;
}

sub make_grammar
{
	my $out = get_file_contents("$dir/core/lang_grammar.pegjs");
	unless (defined $vars{'$NEXT'})
	{
		$out =~ s/\nnext_v\s+=.+\s+\{ [^;]+?; return[^\}]+\}\s+\}\s+/\n/;
		$out =~ s/\bnext_v \/ //g;
		$out =~ s/\$NEXT \/ //g;
		die "Grammar: next_v" if ($out =~ /\bnext_v\b|\$NEXT/);
	}

	foreach my $key (sort keys %vars)
	{
		my $safe_key = $key;
		$safe_key =~ s/^\$/\\\$/;
		$out =~ s/$safe_key\b/format_var('pegjs', $key)/ge;
	}

	open OUT, ">:utf8", "$dir/$lang/grammar.pegjs";
	print OUT $out;
	close OUT;
	if ($out =~ /(\$[A-Z_]+)/)
	{
		die "$1\nGrammar: Capital variable";
	}
}

sub make_regexps
{
	my ($translation_regexps) = @_;
	make_translations();

	my $out = get_file_contents("$dir/core/lang_regexps.ts");

	my $translation_regexp = make_book_regexp('translations', $translation_regexps, 1);
	$out =~ s/\$TRANS_REGEXP/$translation_regexp/g;

	unless (defined $vars{'$NEXT'})
	{
		$out =~ s/\n.+\$NEXT.+\n/\n/;
		die "Regexps: next" if ($out =~ /\$NEXT\b/);
	}
	my @osises = @order;
	foreach my $osis (sort keys %raw_abbrevs)
	{
		next unless ($osis =~ /,/);
		my $temp = $osis;
		$temp =~ s/,+$//;
		push @osises, {osis => $osis, testament => get_testament($temp)};
	}
	my $book_regexps = make_regexp_set(@osises);
	$out =~ s/\/\/\$BOOK_REGEXPS/$book_regexps/;
	$out =~ s/\$VALID_CHARACTERS/$valid_characters/;
	$out =~ s/\$PRE_PASSAGE_ALLOWED_CHARACTERS/join('|', @{$vars{'$PRE_PASSAGE_ALLOWED_CHARACTERS'}})/e;
	my $pre = join '|', map { format_value('regexp', $_)} @{$vars{'$PRE_BOOK_ALLOWED_CHARACTERS'}};
	$out =~ s/\$PRE_BOOK_ALLOWED_CHARACTERS/$pre/;
	$pre = join '|', map { format_value('regexp', $_)} @{$vars{'$FULL_PRE_BOOK_ALLOWED_CHARACTERS'}};
	$out =~ s/\$FULL_PRE_BOOK_ALLOWED_CHARACTERS/$pre/;
	$pre = join '|', map { format_value('regexp', $_)} @{$vars{'$PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'}};
	$out =~ s/\$PRE_NUMBER_BOOK_ALLOWED_CHARACTERS/$pre/;
	$pre = join '|', map { format_value('regexp', $_)} @{$vars{'$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'}};
	$out =~ s/\$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS/join('|', @{$vars{'$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'}})/ge;
	#die Dumper($vars{'$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'});
	$pre = join '|', map { format_value('regexp', $_)} @{$vars{'$POST_BOOK_ALLOWED_CHARACTERS'}};
	$out =~ s/\$POST_BOOK_ALLOWED_CHARACTERS/$pre/;
	my @passage_components;
	foreach my $var ('$CHAPTER', '$NEXT', '$FF', '$TO', '$AND', '$VERSE')
	{
		push @passage_components, map { format_value('regexp', $_) } @{$vars{$var}} if (exists $vars{$var});
	}
	@passage_components = sort { length $b <=> length $a } @passage_components;
	$out =~ s/\$PASSAGE_COMPONENTS/join(' | ', @passage_components)/e;
	my $lang_isos = to_json($vars{'$LANG_ISOS'});
	$out =~ s/"\$LANG_ISOS"/$lang_isos/g;
	$out =~ s/($(?:AND|TO))/format_var('string_raw', $1)/ge;
	foreach my $key (sort keys %vars)
	{
		my $safe_key = $key;
		$safe_key =~ s/^\$/\\\$/;
		$out =~ s/`$safe_key/"`" . format_var('string_raw', $key)/ge;
		$out =~ s/$safe_key(?!\w)/format_var('regexp', $key)/ge;
	}
	$out =~ s@new RegExp\(String\.raw`((?:.(?!\t\.replace))*?\t)`\.replace\(/\\s\+/g, ""\), "(\w+)"\)@
		my ($in_string, $flags) = ($1, $2);
		$in_string =~ s/\s+//g;
		$in_string =~ s/\//\\\//g;
		"/$in_string/$flags";
		@ges;

	open OUT, ">:utf8", "$dir/$lang/regexps.ts";
	print OUT $out;
	close OUT;
	if ($out =~ /(\$[A-Z_]+)/)
	{
		die "$1\nRegexps: Capital variable";
	}
}

sub make_regexp_set
{
	my @out;
	my $has_psalm_cb = 0;
	foreach my $ref (@_)
	{
		my $osis = $ref->{osis};
		if ($osis eq 'Ps' && !$has_psalm_cb && -f "$dir/$lang/psalm_cb.js")
		{
			my $out = get_file_contents("$dir/$lang/psalm_cb.js");
			$out =~ s@new RegExp\(String\.raw`((?:.(?!\t\)\\b`\.replace))*?.\t\)\\b)`\.replace\(/\\s\+/g, ""\), "(\w+)"\)@
				my ($in_string, $flags) = ($1, $2);
				$in_string =~ s/\s+//g;
				$in_string =~ s/\//\\\//g;
				"/$in_string/$flags";
				@ges;
			push @out, $out;
			$has_psalm_cb = 1;
		}
		my %safes;
		foreach my $abbrev (keys %{$raw_abbrevs{$osis}})
		{
			my $safe = $abbrev;
			$safe =~ s/[\[\]\?]//g;
			$safes{$abbrev} = length $safe;
		}
		push @out, make_regexp($osis, sort { $safes{$b} <=> $safes{$a} } keys %safes);
	}
	return join(",\x0a", @out);
}

sub make_regexp
{
	my $osis = shift;
	my (@out, @abbrevs);

	foreach my $abbrev (@_)
	{
		$abbrev =~ s/ /$regexp_space*/g;
		$abbrev =~ s/[\x{200b}]/my $temp = $regexp_space; $temp =~ s!\]$!\x{200b}]!; "$temp*"/ge;
		$abbrev = handle_accents($abbrev);
		$abbrev =~ s/(\$[A-Z]+)(?!\w)/format_var('regexp', $1) . "\\.?"/ge;
		push @abbrevs, $abbrev;
	}
	my $book_regexp = make_book_regexp($osis, $all_abbrevs{$osis}, 1);
	$osis =~ s/,+$//;
	my $osis_json = $osis;
	$osis_json =~ s/,/", "/g;
	push @out, "\t{\x0a\t\tosis: [\"$osis_json\"],\x0a\t\t";
	my $testament = get_testament($osis);
	push @out, "testament: \"$testament\",\x0a\t\t";
	if (length($testament) > 1) {
		my $testament_books = make_testament_books($osis);
		push @out, "testament_books: " . JSON->new->canonical->encode($testament_books) . ",\x0a\t\t";
	}
	my $pre = join '|', @{$vars{'$PRE_BOOK_ALLOWED_CHARACTERS'}};
	my $before_pre_book = '(?:^|(?<=';
	my $after_pre_book = '))';
	$vars{'$FULL_PRE_BOOK_ALLOWED_CHARACTERS'} = ["$before_pre_book$pre$after_pre_book"];
	if ($osis =~ /^[0-9]/ || join('|', @abbrevs) =~ /[0-9]/)
	{
		if ($pre eq '[^\\p{L}]')
		{
			$pre = '[^\\p{L}\\p{N}])(?<!\d:(?=\d)';
		}
		else
		{
			$pre = join '|', map { format_value('quote', $_)} @{$vars{'$PRE_BOOK_ALLOWED_CHARACTERS'}};
			$pre = '\b' if ($pre eq "\\\\d|\\\\b");
			$pre =~ s/\\+d\|?//;
			$pre =~ s/^\|+//;
			$pre =~ s/^\||\|\||\|$//; #remove leftover |
			$pre =~ s/^\[\^/[^0-9/; #if it's a negated class, add \d
		}
		$vars{'$PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'} = [$pre];
		$vars{'$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'} = ["$before_pre_book$pre$after_pre_book"];
		#print Dumper($vars{'$FULL_PRE_NUMBER_BOOK_ALLOWED_CHARACTERS'});
	}
	my $post = join '|', @{$vars{'$POST_BOOK_ALLOWED_CHARACTERS'}};
	push @out, "regexp: /(?:^|(?<=$pre))(";
	push @out, $book_regexp;
	if ($out[-1] =~ /-/)
	{
		my $temp = $out[-1];
		$temp =~ s!\[[^\]]+?\]!###!g;
		# This is basically duplicating code in format_var.
		if ($temp =~ /-/)
		{
			$temp = '';
			my $in_bracket = 0;
			my @chars = split //, $out[-1];
			while (@chars)
			{
				my $char = shift @chars;
				if ($char eq '\\')
				{
					$temp .= $char;
					$temp .= shift(@chars);
				}
				elsif ($char eq '[')
				{
					die "[ inside bracket: $out[-1]" if ($in_bracket);
					$in_bracket = 1;
					$temp .= $char;
				}
				elsif ($char eq '-')
				{
					if ($in_bracket)
					{
						$temp .= $char
					}
					elsif ($chars[0] && $chars[0] ne '?')
					{
						$temp .= "$char?";
					}
					else
					{
						$temp .= $char;
					}
				}
				elsif ($char eq ']')
				{
					$in_bracket = 0;
					$temp .= $char;
				}
				else
				{
					$temp .= $char;
				}
			}
			$out[-1] = $temp;
		}
	}
	$post =~ s!(\[[^[\[\]]+?)\[(\x{2019}')\]]!$1$2!;
	$vars{'$FULL_POST_BOOK_ALLOWED_CHARACTERS'} = ["(?:(?=$post)|\$)"];
	push @out, ")(?:(?=$post)|\$)/giu\x0a\t}";
	return join("", @out);
}

sub make_testament_books
{
	my @osises = split /,/, $_[0];
	my %out;
	foreach my $osis (@osises)
	{
		$out{$osis} = get_testament($osis);
	}
	return \%out;
}

sub make_book_regexp
{
	my ($osis, $abbrevs, $recurse_level, $note) = @_;
	#print "  Regexping $osis..\n";
	map { s/\\//g; } @{$abbrevs};
	#my @subsets = get_book_subsets($abbrevs);
	my @subsets = ($abbrevs);
	my @out;
	my $i = 1;
	foreach my $subset (@subsets)
	{
		next unless (@{$subset});
		#print "Sub $i\n";
		$i++;
		#print Dumper($subset);
		my $json = JSON->new->ascii(1)->encode($subset);
		#print "$json\n";
		my $base64 = encode_base64($json, "");
		print "$osis " . length($base64) . "\n";
		my $use_file = 0;
		if (length $base64 > 128_000) #Ubuntu limitation
		{
			$use_file = 1;
			open TEMP, '>./temp.txt';
			print TEMP $json;
			close TEMP;
			$base64 = '<';
		}
		my $regexp = `node ./make_regexps.js "$base64"`;
		#print Dumper($regexp) if ($osis eq 'Acts');
		unlink './temp.txt' if ($use_file);
		$regexp = decode_json($regexp);
		die "No regexp json object" unless (defined $regexp->{patterns});
		my @patterns;
		foreach my $pattern (@{$regexp->{patterns}})
		{
			$pattern = format_node_regexp_pattern($pattern);
			push @patterns, $pattern;
		}
		my $pattern = join('|', @patterns);
		$pattern = validate_node_regexp($osis, $pattern, $subset, $recurse_level);
		push @out, $pattern;
	}
	validate_full_node_regexp($osis, join('|', @out), $abbrevs);
	return join('|', @out);
}

sub validate_full_node_regexp
{
	my ($osis, $pattern, $abbrevs) = @_;
	foreach my $abbrev (@{$abbrevs})
	{
		my $compare = "$abbrev 1";
		$compare =~ s/^(?:$pattern) //;
		print Dumper("  Not parseable ($abbrev): '$compare'\n$pattern") unless ($compare eq '1');
	}
}

sub get_book_subsets
{
	my @abbrevs = @{$_[0]};
	return ([@abbrevs]) unless (scalar @abbrevs > 500);
	my @groups = ([]);
	my %subs;
	@abbrevs = sort { length $b <=> length $a } @abbrevs;
	while (@abbrevs)
	{
		my $long = shift @abbrevs;
		#print "$long\n";
		next if (exists $subs{$long});
		for my $i (0 .. $#abbrevs)
		{
			my $short = quotemeta $abbrevs[$i];
			next unless ($long =~ /(?:^|[\s\p{InPunctuation}\p{Punct}])$short(?:[\s\p{InPunctuation}\p{Punct}]|$)/i);
			$subs{$abbrevs[$i]}++;
		}
		push @{$groups[0]}, $long;
	}
	$groups[1] = [sort { length $b <=> length $a } keys %subs] if (%subs);
	return @groups;
}

sub consolidate_abbrevs
{
	my @out;
	my $merge_i = -1;
	while (@_)
	{
		my $ref = shift;
		if (scalar(keys(%{$ref})) == 2)
		{
			if ($merge_i == -1)
			{
				$merge_i = scalar @out;
				push @out, [keys %{$ref}];
			}
			else
			{
				foreach my $abbrev (keys %{$ref})
				{
					push @{$out[$merge_i]}, $abbrev;
				}
				$merge_i = -1 if (scalar @{$out[$merge_i]} > 6);
			}
		}
		else
		{
			push @out, [keys %{$ref}];
		}
	}
	return @out;
}

sub validate_node_regexp
{
	my ($osis, $pattern, $abbrevs, $recurse_level, $note) = @_;
	my ($oks, $not_oks) = check_regexp_pattern($osis, $pattern, $abbrevs);
	my @oks = @{$oks};
	my @not_oks = @{$not_oks};
	return $pattern unless (@not_oks);
	#print scalar(@not_oks) . " not oks:\n" . Dumper(\@not_oks) . "\n$pattern\n";
	if ($recurse_level > 10)
	{
		print "Splitting $osis by length...\n";
		if ($note && $note eq 'lengths')
		{
			die "'Lengths' didn't work; no pattern available for: $osis / " . Dumper(\@not_oks);
		}
		my %lengths = split_by_length(@{$abbrevs});
		my @patterns;
		foreach my $length (sort { $b <=> $a } keys %lengths)
		{
			# This can lead to an infinite loop if the pattern never matches.
			push @patterns, make_book_regexp($osis, $lengths{$length}, 1, 'lengths');
		}
		return validate_node_regexp($osis, join('|', @patterns), $abbrevs, $recurse_level + 1, 'lengths');

	}
	print "  Recurse ($osis): $recurse_level\n";# if ($recurse_level > 3);
	#if ($note && $note eq 'final')
	#{
	#	print Dumper(\@oks);
	#	print Dumper(\@not_oks);
	#	exit;
	#}
	#print Dumper($abbrevs);
	#print Dumper(\@oks);
	#print Dumper(\@not_oks);
	my $ok_pattern = make_book_regexp($osis, \@oks, $recurse_level + 1);
	my $not_ok_pattern = make_book_regexp($osis, \@not_oks, $recurse_level + 1);
	#print "Nop: $not_ok_pattern\n";
	my ($shortest_ok) = sort { length $a <=> length $b } @oks;
	my ($shortest_not_ok) = sort { length $a <=> length $b } @not_oks;
	my $new_pattern = (length $shortest_ok > length $shortest_not_ok && $recurse_level < 10) ? "$ok_pattern|$not_ok_pattern" : "$not_ok_pattern|$ok_pattern";
	$new_pattern = validate_node_regexp($osis, $new_pattern, $abbrevs, $recurse_level + 1, 'final');
	#print Dumper($new_pattern);
	return $new_pattern;
}

sub get_testament
{
	my ($osis) = @_;
	$osis =~ s/,+$//;
	my (%testaments);
	foreach my $book (split(/,/, $osis))
	{
		my $testament = (exists $valid_osises{$book}) ? $valid_osises{$book} : "";
		if ($testament)
		{
			$testaments{$testament} = 1;
			$testaments{a} = 1 if ($book eq 'Ps'); #Ps is both Old Testament and Apocrypha since Ps151 adjusts the number of psalms in Ps.
		}
		else
		{
			die "No valid testament for '$book'";
		}
	}
	my $out = '';
	foreach my $testament (qw(o n a))
	{
		$out .= $testament if (exists $testaments{$testament});
	}
	die "No testament for " . Dumper($osis) unless ($out);
	return $out;
}

sub split_by_length
{
	my %lengths;
	foreach my $abbrev (@_)
	{
		my $length = int(length($abbrev) / 2);
		push @{$lengths{$length}}, $abbrev;
	}
	return %lengths;
}

sub check_regexp_pattern
{
	my ($osis, $pattern, $abbrevs) = @_;
	my (@oks, @not_oks);
	foreach my $abbrev (@{$abbrevs})
	{
		my $compare = "$abbrev 1";
		$compare =~ s/^(?:$pattern)(?=$valid_characters)//i;
		if ($compare ne ' 1')
		{
			#print "not ok=$compare\nnot ok abbrev=$abbrev\nnot ok pattern=$pattern\n";
			push @not_oks, $abbrev;
		}
		else
		{
			push @oks, $abbrev;
		}
	}
	return (\@oks, \@not_oks);
}

sub format_node_regexp_pattern
{
	my ($pattern) = @_;
	die "Unexpected regexp pattern: '$pattern'" unless ($pattern =~ /^\^/ && $pattern =~ /\$$/);
	$pattern =~ s/^\^//;
	$pattern =~ s/\$$//;
	# grex returns `-` as `\-`, which doesn't work with Javascript's /u regexp flag.
	$pattern =~ s/\\-/-/g;
	$pattern =~ s!([^\\])(/)!$1\\$2!g;
	$pattern =~ s/ /\\s*/g;
	$pattern =~ s/\x{2009}/\\s/g;
	return $pattern;
}

sub format_value
{
	my ($type, $value) = @_;
	$vars{'$TEMP_VALUE'} = [$value];
	return format_var($type, '$TEMP_VALUE');
}

sub format_var
{
	my ($type, $var_name) = @_;
	my @values = @{$vars{$var_name}};
	if ($type eq 'regexp' || $type eq 'quote' || $type eq 'string_raw')
	{
		map {
			s/\.$//;
			s/!(.+)$/(?!$1)/;
			s/`/\\`/g if ($type eq 'string_raw');
			s/\\/\\\\/g if ($type eq 'quote');
			s/"/\\"/g if ($type eq 'quote');
			} @values;
		my $out = join('|', @values);
		$out = handle_accents($out);
		$out =~ s/ +/\\s+/g;
		return (scalar @values > 1) ? '(?:' . $out . ')' : $out;
	}
	elsif ($type eq 'pegjs')
	{
		map {
			s/\.(?!`)/" abbrev? "/;
			s/\.`/" abbrev "/;
			s/([A-Z])/lc $1/ge;
			$_ = handle_accents($_);
			s/\[/" [/g;
			s/\]/\] "/g;
			$_ = "\"$_\"";
			s/\s*!\[/" ![/;
			s/\s*!([^\[])/" !"$1/;
			s/"{2,}//g;
			s/^\s+|\s+$//g;
			$_ .= ' ';
			my @out;
			my @parts = split /"/;
			my $is_outside_quote = 1;
			while (@parts)
			{
				my $part = shift @parts;
				if ($is_outside_quote == 0)
				{
					$part =~ s/^ /$out[-1] .= 'space '; ''/e;
					$part =~ s/ /" space "/g;
					$part =~ s!((?:^|")[^"]+?")( space )!
						my ($quote, $space) = ($1, $2);
						$quote .= 'i' if ($quote =~ /[\x80-\x{ffff}]/);
						"$quote$space";
						!ge;
					push @out, $part;
					$parts[0] = 'i' . $parts[0] if ($part =~ /[\x80-\x{ffff}]/);
					$is_outside_quote = 1;
				}
				else
				{
					push @out, $part;
					$is_outside_quote = 0;
				}
			}
			$_ = join '"', @out;
			s/\[([^\]]*?[\x80-\x{ffff}][^\]]*?)\]/[$1]i/g;
			s/!(space ".+)/!($1)/;
			s/\s+$//;
			$_ .= ' sp' if ($var_name eq '$TO')
			} @values;
		my $out = join(' / ', @values);
		if (($var_name eq '$TITLE' || $var_name eq '$NEXT' || $var_name eq '$FF') && scalar @values > 1)
		{
			$out = "( $out )";
		}
		elsif (scalar @values >= 2 && ($var_name eq '$CHAPTER' || $var_name eq '$VERSE' || $var_name eq '$NEXT' || $var_name eq '$FF'))
		{
			$out = handle_pegjs_prepends($out, @values);
			#print Dumper(\@values);
		}
		return $out;
	}
	else
	{
		die "Unknown var type: $type / $var_name";
	}
}

sub handle_pegjs_prepends
{
	my $out = shift;
	my $count = scalar @_;
	my %lcs;
	foreach my $c (@_)
	{
		next unless ($c =~ /^"/);
		for my $length (2 .. length $c)
		{
			push @{$lcs{substr($c, 0, $length)}}, $c;
		}
	}
	my $longest = '';
	foreach my $lc (keys %lcs)
	{
		$longest = $lc if (scalar @{$lcs{$lc}} == $count && length $lc > length $longest);
	}
	return $out unless ($longest);
	my $length = length $longest;
	my @out;
	foreach my $c (@_)
	{
		$c = substr($c, $length);
		$c = '"' . $c unless ($c =~ /^\s*\[|^\s*abbrev\?/);
		return $out if ($c eq '"');
		$c =~ s!^"" !!;
		next unless (length $c);
		push @out, $c;
	}
	unless ($longest =~ /"i?\s*$/)
	{
		$longest .= '"';
		$longest .= 'i' if ($longest =~ /[\x80-\x{ffff}]/);
	}
	return "$longest ( " . join(' / ', @out) . " )";
}

sub make_tests
{
	my @out;
	my @osises = @order;
	my %all_abbrevs;
	foreach my $osis (sort keys %abbrevs)
	{
		next unless ($osis =~ /,/);
		push @osises, {osis => $osis, testament => get_testament($osis)};
	}
	foreach my $ref (@osises)
	{
		my $osis = $ref->{osis};
		my @tests;
		my ($first) = split /,/, $osis;
		my $match = "$first\.1\.1";
		foreach my $abbrev (sort_abbrevs_by_length(keys %{$abbrevs{$osis}}))
		{
			foreach my $expanded (expand_abbrev_vars($abbrev))
			{
				add_abbrev_to_all_abbrevs($osis, $expanded, \%all_abbrevs);
				push @tests, "\t\texpect(p.parse(\"$expanded 1:1\").osis()).toEqual(\"$match\");";
			}
			foreach my $alt_osis (@osises)
			{
				next if ($osis eq $alt_osis);
				foreach my $alt_abbrev (keys %{$abbrevs{$alt_osis}})
				{
					next unless (length $alt_abbrev >= length $abbrev);
					my $q_abbrev = quotemeta $abbrev;
					if ($alt_abbrev =~ /\b$q_abbrev\b/)
					{
						foreach my $check (@osises)
						{
							last if ($alt_osis eq $check); # if $alt_osis comes first, that's what we want
							next unless ($osis eq $check); # we only care about $osis
							print Dumper("$alt_osis should be before $osis in parsing order\n  $alt_abbrev matches $abbrev");
						}
					}
				}
			}
		}
		push @out, "describe(\"Localized book $osis ($lang)\", () => {";
		push @out, "\tlet p = {}";
		push @out, "\tbeforeEach(() => {";
		push @out, "\t\tp = new bcv_parser(lang);";
		push @out, "\t\tp.set_options({ book_alone_strategy: \"ignore\", book_sequence_strategy: \"ignore\", osis_compaction_strategy: \"bc\", captive_end_digits_strategy: \"delete\", testaments: \"ona\" });";
		push @out, "\t});"; # close beforeEach
		push @out, "\tit(\"should handle book: $osis ($lang)\", () => {";
		push @out, @tests;
		push @out, add_non_latin_digit_tests($osis, @tests);

		# Don't check for an empty string because books like EpJer will lead to Jer in language-specific ways.
		if ($valid_osises{$first} ne 'a')
		{
			foreach my $abbrev (sort_abbrevs_by_length(keys %{$abbrevs{$osis}}))
			{
				foreach my $expanded (expand_abbrev_vars($abbrev))
				{
					$expanded = uc_normalize($expanded);
					push @out, "\t\texpect(p.parse(\"$expanded 1:1\").osis()).toEqual(\"$match\");";
				}
			}
		}
		push @out, "\t});";
		push @out, "});"; #close book describe
	}
	open OUT, '>:utf8', "$dir/$lang/book_names.txt";
	foreach my $osis (sort keys %all_abbrevs)
	{
		my @osis_abbrevs = sort_abbrevs_by_length(keys %{$all_abbrevs{$osis}});
		my $use_osis = $osis;
		$use_osis =~ s/,+$//;
		foreach my $abbrev (@osis_abbrevs)
		{
			my $use = $abbrev;
			$use =~ s/\x{2009}/ /g;
			print OUT "$use_osis\t$use\n";
		}
		$all_abbrevs{$osis} = \@osis_abbrevs;
	}
	close OUT;
	my @misc_tests;
	push @misc_tests, add_range_tests();
	push @misc_tests, add_chapter_tests();
	push @misc_tests, add_verse_tests();
	push @misc_tests, add_sequence_tests();
	push @misc_tests, add_title_tests();
	push @misc_tests, add_ff_tests();
	push @misc_tests, add_next_tests();
	push @misc_tests, add_trans_tests();
	push @misc_tests, add_book_range_tests();
	push @misc_tests, add_boundary_tests();
	my $out = get_file_contents("$dir/core/lang_spec.js");
	my $lang_isos = to_json($vars{'$LANG_ISOS'});
	$out =~ s/\$LANG_ISOS/$lang_isos/g;
	$out =~ s/\$LANG/$lang/g;
	$out =~ s/\/\/\$BOOK_TESTS/join("\x0a", @out)/e;
	$out =~ s/\/\/\$MISC_TESTS/join("\x0a", @misc_tests)/e;
	if (-f "$dir/$lang/spec_additions.js") {
		$out .= get_file_contents("$dir/$lang/spec_additions.js");
	}
	open OUT, ">:utf8", "$dir/$lang/spec.js";
	print OUT $out;
	close OUT;
	if ($out =~ /(\$[A-Z]+)/)
	{
		die "$1\nTests: Capital variable";
	}

	$out = get_file_contents("$dir/core/lang_specrunner.html");
	$out =~ s/\$LANG/$lang/g;
	open OUT, ">:utf8", "$test_dir/html/$lang.html";
	print OUT $out;
	close OUT;
	if ($out =~ /(\$[A-Z])/)
	{
		die "$1\nTests: Capital variable";
	}
	return %all_abbrevs;
}

sub sort_abbrevs_by_length
{
	my (%lengths, @out);
	foreach my $abbrev (@_)
	{
		my $length = length $abbrev;
		push @{$lengths{$length}}, $abbrev;
	}
	foreach my $length (sort { $b <=> $a } keys %lengths)
	{
		my @abbrevs = sort @{$lengths{$length}};
		push @out, @abbrevs;
	}
	return @out;
}

sub add_abbrev_to_all_abbrevs
{
	my ($osis, $abbrev, $all_abbrevs) = @_;
	if ($abbrev =~ /\./ && $abbrev ne "\x{418}.\x{41d}")
	{
		my @news = split /\./, $abbrev;
		my @olds = (shift(@news));
		foreach my $new (@news)
		{
			my @temp;
			foreach my $old (@olds)
			{
				push @temp, "$old.$new";
				push @temp, "$old$new";
			}
			@olds = @temp;
		}
		foreach my $abbrev (@olds)
		{
			$all_abbrevs->{$osis}->{$abbrev} = 1;
		}
	}
	else
	{
		$all_abbrevs->{$osis}->{$abbrev} = 1;
	}
}

sub add_non_latin_digit_tests
{
	my $osis = shift;
	my @out;
	my $temp = join "\n", @_;
	return @out unless ($temp =~ /[\x{0660}-\x{0669}\x{06f0}-\x{06f9}\x{07c0}-\x{07c9}\x{0966}-\x{096f}\x{09e6}-\x{09ef}\x{0a66}-\x{0a6f}\x{0ae6}-\x{0aef}\x{0b66}-\x{0b6f}\x{0be6}-\x{0bef}\x{0c66}-\x{0c6f}\x{0ce6}-\x{0cef}\x{0d66}-\x{0d6f}\x{0e50}-\x{0e59}\x{0ed0}-\x{0ed9}\x{0f20}-\x{0f29}\x{1040}-\x{1049}\x{1090}-\x{1099}\x{17e0}-\x{17e9}\x{1810}-\x{1819}\x{1946}-\x{194f}\x{19d0}-\x{19d9}\x{1a80}-\x{1a89}\x{1a90}-\x{1a99}\x{1b50}-\x{1b59}\x{1bb0}-\x{1bb9}\x{1c40}-\x{1c49}\x{1c50}-\x{1c59}\x{a620}-\x{a629}\x{a8d0}-\x{a8d9}\x{a900}-\x{a909}\x{a9d0}-\x{a9d9}\x{aa50}-\x{aa59}\x{abf0}-\x{abf9}\x{ff10}-\x{ff19}]/);
	push @out, "\t\tp.set_options({ non_latin_digits_strategy: \"replace\" });";
	return (@out, @_);
}

sub add_range_tests
{
	my @out;
	push @out, "\tit(\"should handle ranges ($lang)\", () => {";
	foreach my $abbrev (@{$vars{'$TO'}})
	{
		foreach my $to (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Titus 1:1 $to 2\").osis()).toEqual(\"Titus.1.1-Titus.1.2\");";
			push @out, "\t\texpect(p.parse(\"Matt 1${to}2\").osis()).toEqual(\"Matt.1-Matt.2\");";
			push @out, "\t\texpect(p.parse(\"Phlm 2 " . uc_normalize($to) . " 3\").osis()).toEqual(\"Phlm.1.2-Phlm.1.3\");";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_chapter_tests
{
	my @out;
	push @out, "\tit(\"should handle chapters ($lang)\", () => {";
	foreach my $abbrev (@{$vars{'$CHAPTER'}})
	{
		foreach my $chapter (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Titus 1:1, $chapter 2\").osis()).toEqual(\"Titus.1.1,Titus.2\");";
			push @out, "\t\texpect(p.parse(\"Matt 3:4 " . uc_normalize($chapter) . " 6\").osis()).toEqual(\"Matt.3.4,Matt.6\");";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_verse_tests
{
	my @out;
	push @out, "\tit(\"should handle verses ($lang)\", () => {";
	foreach my $abbrev (@{$vars{'$VERSE'}})
	{
		foreach my $verse (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Exod 1:1 $verse 3\").osis()).toEqual(\"Exod.1.1,Exod.1.3\");";
			push @out, "\t\texpect(p.parse(\"Phlm " . uc_normalize($verse) . " 6\").osis()).toEqual(\"Phlm.1.6\");";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_sequence_tests
{
	my @out;
	push @out, "\tit(\"should handle 'and' ($lang)\", () => {";
	foreach my $abbrev (@{$vars{'$AND'}})
	{
		foreach my $and (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Exod 1:1 $and 3\").osis()).toEqual(\"Exod.1.1,Exod.1.3\");";
			push @out, "\t\texpect(p.parse(\"Phlm 2 " . uc_normalize($and) . " 6\").osis()).toEqual(\"Phlm.1.2,Phlm.1.6\");";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_title_tests
{
	my @out;
	push @out, "\tit(\"should handle titles ($lang)\", () => {";
	foreach my $abbrev (@{$vars{'$TITLE'}})
	{
		foreach my $title (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Ps 3 $title, 4:2, 5:$title\").osis()).toEqual(\"Ps.3.1,Ps.4.2,Ps.5.1\");";
			push @out, "\t\texpect(p.parse(\"" . uc_normalize("Ps 3 $title, 4:2, 5:$title") . "\").osis()).toEqual(\"Ps.3.1,Ps.4.2,Ps.5.1\");";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_ff_tests
{
	my @out;
	push @out, "\tit(\"should handle 'ff' ($lang)\", () => {";
	push @out, "\t\tp.set_options({ case_sensitive: \"books\" });" if ($lang eq 'it');
	foreach my $abbrev (@{$vars{'$FF'}})
	{
		foreach my $ff (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Rev 3$ff, 4:2$ff\").osis()).toEqual(\"Rev.3-Rev.22,Rev.4.2-Rev.4.11\");";
			push @out, "\t\texpect(p.parse(\"" . uc_normalize("Rev 3 $ff, 4:2 $ff") . "\").osis()).toEqual(\"Rev.3-Rev.22,Rev.4.2-Rev.4.11\");" unless ($lang eq 'it');
		}
	}
	push @out, "\t\tp.set_options({ case_sensitive: \"none\" });" if ($lang eq 'it');
	push @out, "\t});";
	return @out;
}

sub add_next_tests
{
	return () unless (defined $vars{'$NEXT'});
	my @out;
	push @out, "\tit(\"should handle 'next' ($lang)\", () => {";
	push @out, "\t\tp.set_options({ case_sensitive: \"books\" });" if ($lang eq 'it');
	foreach my $abbrev (@{$vars{'$NEXT'}})
	{
		foreach my $next (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			push @out, "\t\texpect(p.parse(\"Rev 3:1$next, 4:2$next\").osis()).toEqual(\"Rev.3.1-Rev.3.2,Rev.4.2-Rev.4.3\");";
			push @out, "\t\texpect(p.parse(\"" . uc_normalize("Rev 3 $next, 4:2 $next") . "\").osis()).toEqual(\"Rev.3-Rev.4,Rev.4.2-Rev.4.3\");" unless ($lang eq 'it');
			push @out, "\t\texpect(p.parse(\"Jude 1$next, 2$next\").osis()).toEqual(\"Jude.1.1-Jude.1.2,Jude.1.2-Jude.1.3\");";
			push @out, "\t\texpect(p.parse(\"Gen 1:31$next\").osis()).toEqual(\"Gen.1.31-Gen.2.1\");";
			push @out, "\t\texpect(p.parse(\"Gen 1:2-31$next\").osis()).toEqual(\"Gen.1.2-Gen.2.1\");";
			push @out, "\t\texpect(p.parse(\"Gen 1:2$next-30\").osis()).toEqual(\"Gen.1.2-Gen.1.3,Gen.1.30\");";
			push @out, "\t\texpect(p.parse(\"Gen 50$next, Gen 50:26$next\").osis()).toEqual(\"Gen.50,Gen.50.26\");";
			push @out, "\t\texpect(p.parse(\"Gen 1:32$next, Gen 51$next\").osis()).toEqual(\"\");";
		}
	}
	push @out, "\t\tp.set_options({ case_sensitive: \"none\" });" if ($lang eq 'it');
	push @out, "\t});";
	return @out;
}

sub add_trans_tests
{
	my @out;
	push @out, "\tit(\"should handle translations ($lang)\", () => {";
	foreach my $abbrev (sort @{$vars{'$TRANS'}})
	{
		foreach my $translation (expand_abbrev(remove_exclamations(handle_accents($abbrev))))
		{
			my ($trans, $osis) = split /,/, $translation;
			$osis = $trans unless ($osis);
			push @out, "\t\texpect(p.parse(\"Lev 1 ($trans)\").osis_and_translations()).toEqual([[\"Lev.1\", \"$osis\"]]);";
			push @out, "\t\texpect(p.parse(\"" . lc("Lev 1 $trans") . "\").osis_and_translations()).toEqual([[\"Lev.1\", \"$osis\"]]);";
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_book_range_tests
{
	my ($first) = expand_abbrev(handle_accents($vars{'$FIRST'}->[0]));
	my ($third) = expand_abbrev(handle_accents($vars{'$THIRD'}->[0]));
	#my ($and) = sort { length $b <=> length $a } keys %{$vars{'$AND'}};
	#my ($to) = sort { length $b <=> length $a } keys %{$vars{'$TO'}};
	my $john = '';
	foreach my $key (sort keys %{$raw_abbrevs{'1John'}})
	{
		next unless ($key =~ /^\$FIRST/);
		$key =~ s/^\$FIRST(?!\w)//;
		$john = $key;
		last;
	}
	unless ($john)
	{
		print "  Warning: no available John abbreviation for testing book ranges\n";
		return;
	}
	my @out;
	my @johns = expand_abbrev(handle_accents($john));
	push @out, "\tit(\"should handle book ranges ($lang)\", () => {";
	push @out, "\t\tp.set_options({ book_alone_strategy: \"full\", book_range_strategy: \"include\" });";
	my %alreadys;
	foreach my $abbrev (sort @johns)
	{
		foreach my $to_regex (@{$vars{'$TO'}})
		{
			foreach my $to (expand_abbrev(remove_exclamations(handle_accents($to_regex))))
			{
				next if (exists $alreadys{"$first $to $third $abbrev"});
				push @out, "\t\texpect(p.parse(\"$first $to $third $abbrev\").osis()).toEqual(\"1John.1-3John.1\");";
				$alreadys{"$first $to $third $abbrev"} = 1;
			}
		}
	}
	push @out, "\t});";
	return @out;
}

sub add_boundary_tests
{
	my @out;
	push @out, "\tit(\"should handle boundaries ($lang)\", () => {";
	push @out, "\t\tp.set_options({ book_alone_strategy: \"full\" });";
	push @out, "\t\texpect(p.parse(\"\\u2014Matt\\u2014\").osis()).toEqual(\"Matt.1-Matt.28\");";
	push @out, "\t\texpect(p.parse(\"\\u201cMatt 1:1\\u201d\").osis()).toEqual(\"Matt.1.1\");";
	push @out, "\t});";
	return @out;
}

sub get_abbrevs
{
	my %out;
	open CORRECTIONS, ">:utf8", "temp.corrections.txt";
	my $has_corrections = 0;
	open FILE, "<:utf8", "$dir/$lang/data.txt";
	while (<FILE>)
	{
		print "Tab followed by space: $_\n" if (/\t\s/ && /^[^\*]/);
		print "Space followed by tab/newline: $_\n" if (/\ [\t\n]/);
		next unless (/^[\w\*]/);
		print "Regex character in preferred: $_\n" if (/^\*/ && /[\[\?!]/);
		next unless (/\t/);
		s/[\r\n]+$//;
		my $prev = $_;
		$_ = NFC(NFD($_));
		if ($_ ne $prev)
		{
			print "Non-normalized text\n";
			$has_corrections = 1;
			print CORRECTIONS "$_\n";
		}
		my $is_literal = (/^\*/) ? 1 : 0;
		s/([\x80-\x{ffff}])/$1`/g if ($is_literal);
		my ($osis, @abbrevs) = split /\t/;
		$osis =~ s/^\*//;
		is_valid_osis($osis);
		$out{$osis}->{$osis} = 1 unless ($osis =~ /,/ || (exists $vars{'$FORCE_OSIS_ABBREV'} && $vars{'$FORCE_OSIS_ABBREV'}->[0] eq 'false'));
		foreach my $abbrev (@abbrevs)
		{
			next unless (length $abbrev);
			unless ($is_literal)
			{
				$abbrev = $vars{'$PRE_BOOK'}->[0] . $abbrev if (exists $vars{'$PRE_BOOK'});
				$abbrev .= $vars{'$POST_BOOK'}->[0] if (exists $vars{'$POST_BOOK'});
				$raw_abbrevs{$osis}->{$abbrev} = 1;
			}
			$abbrev = handle_accents($abbrev);
			my @alts = expand_abbrev_vars($abbrev);
			if (Dumper(\@alts) =~ /.\$/)
			{
				die "Alts:" . Dumper(\@alts);
			}
			foreach my $alt (@alts)
			{
				if ($alt =~ /[\[\?]/)
				{
					#print Dumper("$osis / $abbrev");
					foreach my $expanded (expand_abbrev($alt))
					{
						$out{$osis}->{$expanded} = 1;
					}
				}
				else
				{
					#print " $osis abbrev already exists: " . Dumper($abbrev) if (exists $out{$osis}->{$abbrev} && !$is_literal && $abbrev ne $osis && $abbrev !~ /\$/);
					$out{$osis}->{$alt} = 1;
				}
			}
		}
	}
	close FILE;
	close CORRECTIONS;
	unlink "temp.corrections.txt" unless ($has_corrections);
	return %out;
}

sub expand_abbrev_vars
{
	my ($abbrev) = @_;
	$abbrev =~ s/\\(?![\(\)\[\]\|s])//g;
	return ($abbrev) unless ($abbrev =~ /\$[A-Z]+/);
	my ($var) = $abbrev =~ /(\$[A-Z]+)(?!\w)/;
	my @out;
	my $recurse = 0;
	foreach my $value (@{$vars{$var}})
	{
		foreach my $val (expand_abbrev($value))
		{
			$val = handle_accents($val);
			my $temp = $abbrev;
			$temp =~ s/\$[A-Z]+(?!\w)/$val/;
			$recurse = 1 if ($temp =~ /\$/);
			push @out, $temp;
			if ($var =~ /^\$(?:FIRST|SECOND|THIRD|FOURTH|FIFTH)$/ && $val =~ /^\d|^[IV]+$/)
			{
				my $temp2 = $abbrev;
				my $safe = quotemeta $var;
				$temp2 =~ s/$safe([^.]|$)/$val.$1/;
				push @out, $temp2;
			}
		}
	}
	if ($recurse)
	{
		my @temps;
		foreach my $abbrev (@out)
		{
			my @adds = expand_abbrev_vars($abbrev);
			push @temps, @adds;
		}
		@out = @temps;
	}
	return @out;
}

sub get_order
{
	my @out;
	open FILE, '<:utf8', "$dir/$lang/data.txt";
	while (<FILE>)
	{
		next unless (/^=/);
		s/[\r\n]+$//;
		$_ = NFC(NFD($_));
		s/^=//;
		is_valid_osis($_);
		push @out, {osis => $_, testament => $valid_osises{$_}};
		$abbrevs{$_}->{$_} = 1;
		$raw_abbrevs{$_}->{$_} = 1;
	}
	close FILE;
	return @out;
}

sub get_vars
{
	my %out;
	open FILE, '<:utf8', "$dir/$lang/data.txt";
	while (<FILE>)
	{
		next unless (/^\$/);
		s/[\r\n]+$//;
		$_ = NFC(NFD($_));
		my ($key, @values) = split /\t/;
		die "No values for $key" unless (@values);
		$out{$key} = [@values];
	}
	close FILE;
	
	foreach my $char (@{$out{'$ALLOWED_CHARACTERS'}})
	{
		my $check = quotemeta $char;
		$valid_characters =~ s/\]$/$char]/ unless ($valid_characters =~ /$check/);
	}
	$letters = get_pre_book_characters($out{'$UNICODE_BLOCK'}, '');
	$out{'$PRE_BOOK_ALLOWED_CHARACTERS'} = ["[^\\p{L}]"] unless (exists $out{'$PRE_BOOK_ALLOWED_CHARACTERS'});
	$out{'$POST_BOOK_ALLOWED_CHARACTERS'} = [$valid_characters] unless (exists $out{'$POST_BOOK_ALLOWED_CHARACTERS'});
	$out{'$PRE_PASSAGE_ALLOWED_CHARACTERS'} = [get_pre_passage_characters($out{'$PRE_BOOK_ALLOWED_CHARACTERS'})] unless (exists $out{'$PRE_PASSAGE_ALLOWED_CHARACTERS'});
	$out{'$LANG'} = [$lang];
	$out{'$LANG_ISOS'} = [$lang] unless (exists $out{'$LANG_ISOS'});

	return %out;
}

sub get_pre_passage_characters
{
	my $pattern = join '|', @{$_[0]};
	if ($pattern eq "[^\\p{L}]")
	{
		$pattern = "[^\\x1e\\x1f\\p{L}\\p{N}]";
	}
	elsif ($pattern =~ /^\[\^[^\]]+?\]$/)
	{
		$pattern =~ s/`//g;
		$pattern =~ s/\\x1[ef]|0-9|\\d|A-Z|a-z//g;
		$pattern =~ s/\[\^/[^\\x1e\\x1f\\dA-Za-z/;
	}
	elsif ($pattern eq '\d|\b')
	{
		$pattern = '[^\w\x1f\x1e]';
	}
	else
	{
		die "Unknown pre_passage pattern: $pattern";
	}
	return $pattern;
}

sub get_pre_book_characters
{
	my ($unicodes_ref) = @_;
	die "No \$UNICODE_BLOCK is set" unless (ref $unicodes_ref);
	my @blocks = get_unicode_blocks($unicodes_ref);
	my @letters = get_letters(@blocks);
	my @out;
	foreach my $ref (@letters)
	{
		my ($start, $end) = @{$ref};
		push @out, ($end eq $start) ? "$start" : 
		"$start-$end";
	}
	my $out = join '', @out;
	$out =~ s/([\x80-\x{ffff}])/$1`/g;
	return "[^$out]";
}

sub get_letters
{
	my %out;
	open FILE, 'letters/letters.txt';
	while (<FILE>)
	{
		next unless (/^\\u/);
		s/[\r\n]+$//;
		s/\\u//g;
		s/\s*#.+$//;
		s/\s+//g;
		my ($start, $end) = split /-/;
		$end = $start unless ($end);
		($start, $end) = (hex($start), hex($end));
		foreach my $ref (@_)
		{
			my ($start_range, $end_range) = @{$ref};
			if ($end >= $start_range && $start <= $end_range)
			{
				for my $i ($start..$end)
				{
					next unless ($i >= $start_range && $i <= $end_range);
					$out{"$i"} = 1;
				}
			}
		}
	}
	close FILE;
	my $prev = -2;
	my @out;
	foreach my $pos (sort { $a <=> $b } keys %out)
	{
		if ($pos == $prev + 1)
		{
			$out[-1]->[1] = chr $pos;
		}
		else
		{
			push @out, [chr $pos, chr $pos];
		}
		$prev = $pos;
	}
	return @out;
}

sub get_unicode_blocks
{
	my ($unicodes_ref) = @_;
	my $unicode = join '|', @{$unicodes_ref};
	$unicode .= '|Basic_Latin' unless ($unicode =~ /Basic_Latin/);
	my @out;
	open FILE, 'letters/blocks.txt';
	while (<FILE>)
	{
		next unless (/^\w/);
		s/[\r\n]+$//;
		my ($block, $range) = split /\t/;
		next unless ($block =~ /$unicode/);
		$range =~ s/\\u//g;
		my ($start, $end) = split /-/, $range;
		push @out, [hex $start, hex $end];
	}
	close FILE;
	return @out;
}

sub expand_abbrev
{
	my ($abbrev) = @_;
	return ($abbrev) unless ($abbrev =~ /[\[\(?\|\\]/);
	$abbrev =~ s/(<!\\)\./\\./g;
	my @chars = split //, $abbrev;
	my @outs = ('');
	while (@chars)
	{
		my $char = shift @chars;
		my $is_optional = 0;
		my @nexts;
		if ($char eq '[')
		{
			my @nexts;
			while (@chars)
			{
				my $next = shift @chars;
				if ($next eq ']')
				{
					last;
				}
				elsif ($next eq '\\')
				{
					next;
				}
				else
				{
					my $accents = handle_accent($next);
					$accents =~ s/^\[|\]$//g;
					foreach my $accent (split //, $accents)
					{
						push @nexts, $accent;
					}
				}
			}
			($is_optional, @chars) = is_next_char_optional(@chars);
			push @nexts, '' if ($is_optional);
			my @temps;
			foreach my $out (@outs)
			{
				my %alreadys;
				foreach my $next (@nexts)
				{
					next if (exists $alreadys{$next});
					push @temps, "$out$next";
					$alreadys{$next} = 1;
				}
			}
			@outs = @temps;
		}
		elsif ($char eq '(')
		{
			my @nexts;
			while (@chars)
			{
				my $next = shift @chars;
				if (!@nexts && $next eq '?' && $chars[0] eq ':')
				{
					die "'(?:' in parentheses; replace with just '('";
					shift @chars;
					next;
				}
				if ($next eq ')')
				{
					last;
				}
				elsif ($next eq '\\')
				{
					push @nexts, $next;
					push @nexts, shift(@chars);
				}
				else
				{
					push @nexts, $next;
				}
			}
			@nexts = expand_abbrev(join('', @nexts));
			($is_optional, @chars) = is_next_char_optional(@chars);
			push @nexts, '' if ($is_optional);
			my @temps;
			foreach my $out (@outs)
			{
				foreach my $next (@nexts)
				{
					push @temps, "$out$next";
				}
			}
			@outs = @temps;
		}
		elsif ($char eq '|')
		{
			push @outs, expand_abbrev(join('', @chars));
			return @outs;
		}
		else
		{
			my @temps;
			# Just use the next character
			if ($char eq '\\')
			{
				$char = shift(@chars);
			}
			($is_optional, @chars) = is_next_char_optional(@chars);
			foreach my $out (@outs)
			{
				push @temps, "$out$char";
				push @temps, $out if ($is_optional);
			}
			@outs = @temps;
		}
	}
	if (join('', @outs) =~ /[\[\]]/)
	{
		print "Unexpected char: ";
		print Dumper(\@outs);
		exit;
	}
	return @outs;
}

sub is_next_char_optional
{
	my @chars = @_;
	return (0, @chars) unless (@chars);
	my $is_optional = 0;
	if ($chars[0] eq '?')
	{
		shift @chars;
		$is_optional = 1;
	}
	return ($is_optional, @chars);
}

sub handle_accents
{
	my ($text) = @_;
	my @chars = split //, $text;
	my @texts;
	my $context = '';
	while (@chars)
	{
		my $char = shift @chars;
		if ($char =~ /^[\x80-\x{ffff}]$/)
		{
			# Don't turn it into a class later if it's already in one
			if (@chars && $chars[0] eq '`')
			{
				push @texts, $char;
				push @texts, shift @chars;
				next;
			}
			$char = handle_accent($char);
			$char =~ s/^\[|\]$//g if ($context eq '[');
		}
		elsif ($context eq '[' && $char eq "'")
		{
			push @texts, "\x{2019}'";
			$char = '`';
		}
		elsif (@chars && $chars[0] eq '`')
		{
			push @texts, $char;
			push @texts, shift @chars;
			next;
		}
		elsif ($char eq '[' && !(@texts && $texts[-1] eq '\\'))
		{
			$context = '[';
		}
		elsif ($char eq ']' && !(@texts && $texts[-1] eq '\\'))
		{
			$context = '';
		}
		push @texts, $char;

	}
	$text = join '', @texts;
	#exit;
	#$text =~ s/([\x80-\x{ffff}])(?!`)/handle_accent($1)/ge;
	$text =~ s/'(?!`)/[\x{2019}']/g;
	$text =~ s/\x{2c8}(?!`)/[\x{2c8}']/g unless (exists $vars{'$COLLAPSE_COMBINING_CHARACTERS'} && $vars{'$COLLAPSE_COMBINING_CHARACTERS'}->[0] eq 'false');
	$text =~ s/([\x80-\x{ffff}])`/$1/g;
	$text =~ s/[\x{2b9}\x{374}]/['\x{2019}\x{384}\x{374}\x{2b9}]/g;
	$text =~ s/([\x{300}\x{370}]-)\['\x{2019}\x{384}\x{374}\x{2b9}\](\x{376})/$1\x{374}$2/;
	#$text =~ s/\.$//;
	$text =~ s/\.(?!`)/\\.?/g;
	$text =~ s/\.`/\\./g;
	$text =~ s/ `/\x{2009}/g;
	$text =~ s/'`/'/g;
	return $text;
}

sub remove_exclamations
{
	my ($text) = @_;
	($text) = split /!/, $text if ($text =~ /!/);
	return $text;
}

sub handle_accent
{
	my ($char) = @_;
	return $char if (exists $vars{'$COLLAPSE_COMBINING_CHARACTERS'} && $vars{'$COLLAPSE_COMBINING_CHARACTERS'}->[0] eq 'false');
	my $alt = NFD($char);
	$alt =~ s/\pM//g; # remove combining characters
	$alt = NFC($alt);
	if ($char ne $alt && length $alt > 0 && $alt =~ /[^\s\d]/)
	{
		return "[$char$alt]";
	}
	return $char;
}

sub is_valid_osis
{
	my ($osis) = @_;
	foreach my $part (split /,/, $osis)
	{
		die "Invalid OSIS: $osis ($part)" unless (exists $valid_osises{$part});
	}
}

sub make_valid_osises
{
	my %out;
	my $type = 'o';
	foreach my $osis (@_)
	{
		$type = 'n' if ($osis eq 'Matt');
		$type = 'a' if ($osis eq 'Tob');
		$out{$osis} = $type;
	}
	return %out;
}

sub uc_normalize
{
	my ($text) = @_;
	return NFC(uc(NFD($text)));
}

sub get_file_contents
{
	open FILE, "<:utf8", $_[0] or die "Couldn't open $_[0]: $!";
	my $out = join '', <FILE>;
	close FILE;
	return $out;
}