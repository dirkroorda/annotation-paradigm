#!/usr/bin/perl

use utf8;
use strict;
use warnings;
no warnings "uninitialized";
no strict "refs";
use Time::HiRes qw (gettimeofday time tv_interval);

use DBI;

binmode(STDERR, ":utf8");
binmode(STDOUT, ":utf8");

=head2 test

if test == 2, use testdata
if test == 1, use limited database data, only verse 1
if test == 0, run on full data

=cut

my ($test, $verbose, $fileout, $resultout, $maxiter, $windowsize, $commonality, $inputxml) = @ARGV;

my %database = (
	db => 'jude',
	usr => 'root',
	pwd => 'dipre207',
);

my %time = ();
my %timenest = ();

my $infopath;
my $resultpath;

my %data = ();
my %testdata = (
	A => ['aap', 'noot', 'mies', 'wim', 'karel', 'noot', 'gijs'],
	B => ['aap', 'no1t', 'mies', 'wim', 'karel', 'no2t', 'gijs'],
	C => ['aap', 'no1t', 'mies', 'wim', 'karel', 'no2t', 'gijs'],
	D => ['aap', 'no1t', 'mies', 'wim', 'karel', 'no2t', 'gijs'],
	E => ['aap', 'no2t', 'mies', 'no1t', 'karel', 'no2t', 'gijs'],
	F => ['aap', 'noot', 'mies', 'no1t', 'karel', 'no2t', 'gijs'],
);

my %cumclassesi = ();
my $newtokenindex = 0;
my $newclassindex = 0;

sub readsourcesql {
	timestamp('read', 1);
	my $good = 1;
	for (1) {
		if (!$test and defined $inputxml) {
			print STDERR "Reading the sources from the filesystem ...\n";
			if (!opendir(IX, $inputxml)) {
				print STDERR "Cannot read directory [$inputxml]\n";
				$good = 0;
				next;
			}
			my @items = readdir IX;
			closedir IX;
			for my $item (@items) {
				if (substr($item, 0, 1) eq '.') {
					next;
				}
				my $fpath = "$inputxml/$item";
				if (!-f $fpath) {
					print STDERR "Not a file: [$fpath]\n";
					next;
				}
				if (!open(XF, "<:encoding(UTF-8)", $fpath)) {
					print STDERR "Can't read file [$fpath]\n";
					$good = 0;
					next;
				}
				print STDERR "\r\t$item\n";
				my $filetext;
				{local $/; $filetext = <XF>;}
				close XF;
				$data{$item} = xmltransform(\$filetext);
			}
			print STDERR "\r", ' ' x 80, "\r";
			next;
		}
		if ($test == 2) {
			%data = %testdata;
			print STDERR "Reading the sources: test data\n";
			next;
		}
		print STDERR "Reading the sources from the database ...\n";

		my $where = '';
		if ($test == 1) {
			$where = ' where word.word_number < 10 ';
			print STDERR "Test mode: first 10 words\n";
		}
		my $rows = sql("
	select
		word.glyphs, word.word_number, source.name
	from
		word
	inner join
		source
	on
		word.source_id = source.id
	$where
	");
		if (!$rows) {
			$good = 0;
			next;
		}

		while (my @row = &$rows()) {
			my ($glyphs, $wordnumber, $source) = @row;
			if ($glyphs =~ m/^[ ·]*$/) {
				next;
			}
			push @{$data{$source}}, $glyphs;
		}
		print STDERR "\n";
	}
	writeindex('Data', 'dat', '0', \%data, 0);
	print STDERR elapsed('read');
	return $good;
}

sub contextanalysis {
	my $iteration = 0;
	my $datain = \%data;
	my $dataout = {};

	print STDERR "Context analysis ... \n";

	while (++$iteration <= $maxiter) {
		timestamp('iter', 1);
		$dataout = {};
		my $changes = iteration($iteration, $datain, $dataout);
		printf STDERR "%d changes in iteration %d (of max %d)\n", $changes, $iteration, $maxiter;
		if ($changes) {
			$datain = $dataout;
			writeindex('Data', 'dat', $iteration, $datain, 0);
			print STDERR elapsed('iter');
		}
		else {
			print STDERR elapsed('iter');
			last;
		}
	}

	timestamp('final', 1);
	writeindex('Data', 'dat', 'final', $datain, 1);

# resolve references to classes in %cumclassesi the newly found classes with %cumclassesi
# assumption
# if all classes < i have been resolved, then resolving i takes just one step

	print STDERR "Computing final classes ...\n";
	for (my $i = 1; $i <= $newclassindex; $i++) {
		my $words = $cumclassesi{$i};
		my %newwords = ();
		for my $word (keys %$words) {
			my ($num) = $word =~ m/^#([0-9]+)$/;
			if (defined $num) {
				my $rwords = $cumclassesi{$num};  
				for my $rword (keys %{$cumclassesi{$num}}) {
					$newwords{$rword} = 1;
				}
			}
			else {
				$newwords{$word} = 1;
			}
		}
		$cumclassesi{$i} = \%newwords;
	}

# strip unused classes
# first gather the used classes

	my %usedclasses = ();
	for my $src (keys %$datain) {
		my $words = $datain->{$src};
		for my $word (@$words) {
			my ($num) = $word =~ m/^#([0-9]+)$/;
			if (defined $num) {
				$usedclasses{$num} = 1;
			}
		}
	}
	my $nuclasses = scalar keys %usedclasses;
	printf STDERR "\t%d classes in the result (%d weeded out of total %d)\n", $nuclasses, $newclassindex - $nuclasses, $newclassindex;

# now weed out the unused classes and stringify the used ones

	for (my $i = 1; $i <= $newclassindex; $i++) {
		if (!exists $usedclasses{$i}) {
			delete $cumclassesi{$i};
		}
		else {
			$cumclassesi{$i} = join " ", sort keys %{$cumclassesi{$i}};
		}
	}

	writeindex('Final Classes', 'cls', 'final', \%cumclassesi, 1, 2, 0);
	writeindex('Final Classes x', 'clx', 'final', \%cumclassesi, 1, 2, 1);
	print STDERR elapsed('final');
}

sub iteration {
	my ($iteration, $datain, $dataout) = @_;

	printf STDERR "\tcomputing contexts ... \n";
	timestamp('contexts', 2);
	my ($contexts, $contextsi) = computecontexts($iteration, $datain);
	printf STDERR "\t%d contexts%s\n", scalar(keys(%$contexts)), ' ' x 30;
	print STDERR elapsed('contexts');

	printf STDERR "\tanalysing contexts ... \n";
	timestamp('analysis', 2);
	my $classes = analysecontexts($iteration, $contexts, $contextsi);
	printf STDERR "\t%d words assigned to a class%s\n", scalar(keys(%$classes)), ' ' x 30;
	print STDERR elapsed('analysis');

	my $changes = scalar(keys(%$classes));
	if ($changes) {
		printf STDERR "\tapplying classes ... ";
		timestamp('apply', 2);
		my $applied = applyclasses($datain, $classes, $dataout);
		printf STDERR "%d words replaced by its class\n", $applied;
		print STDERR elapsed('apply');
	}
	return $changes;
}

sub computecontexts {
	my ($iteration, $datain) = @_;

	my %contexts = ();
	my %contextsi = ();
	for my $src (sort keys %$datain) {
		printf STDERR "\r\t%s      ", $src;
		my $text = $datain->{$src};

		for (my $pos = 0; $pos < $windowsize; $pos++) {
			for (my $i = 0; $i <= $#$text - $windowsize + 1; $i++) {
				my $contextword = $text->[$i + $pos];
				my $context = '|'.join('|', @$text[$i .. $i + $pos - 1], '*', @$text[$i + $pos + 1 .. $i + $windowsize - 1]).'|';
				$contexts{$context}->{$contextword}++;
				$contextsi{$contextword}->{$context}++;
			}
		}
	}
	print STDERR "\r", ' ' x 80, "\r";
	writecontext('Contexts', 'con', $iteration, \%contexts, 0);
	return (\%contexts, \%contextsi);
}

=head2 doc

if we have a bunch of words that share a common context, how do we decide that we shall identify those words?
The idea is that if two words have very different context sets, we will not identify them, even if they share one context.

So how do we compute the context similarity of a bunch of words? Without doing a pairwise comparison of all words in the bunch?

NB: contexts have a weight for each word they are context of. The weight is the number of times the word occurs in that context.

Let us write this: weight(word, context)
Now define 

	weight(word) = SUM{c context of word} weight(word, c)

And
	bulkweight(Words) = SUM{w Words} weight(w)

And
	leanweight(Words) = SUM{w in Words}{c in C(w)} weight(w,c)

The lean weight is 

Suppose we have 

	w1 in Ca:2,  Cb:16, Cc:8, Cd:0
	w2 in Ca:10, Cb:4,  Cc:0, Cd:30

compute the weight of w1 in shared contexts (a and b): 18 and the total weight of w1 is 26
compute the weight of w2 in shared contexts (a and b): 14 and the total weight of w4 is 44

So w1 occurs more than 50% in shared contexts, but w2 in less than fifty percent.
It is rather safe to identify w1 in with the group, but rather unsafe to identify w2 with the group.

suppose we add

	w3 in Ca:1, Cb:1,  Cc:10, Cd:100

compute the weight of w3 in shared contexts (a and b): 2 and the total weight of w3 is 112

Let us try this rule:

Suppose we have a context in which w1, w2, w3 occur.
We might want to identify w1, w2, and w3, but not necessarily.
It depends on their context situation.
General rule: if the contexts of a wi are close enough to the intersection of the contexts of all the wj,
then wi is in. Otherwise it is out.
Close enough means: the weighted contexts of wi that are in the intersection divided by the total weighted contexts of wi should
be larger than a given threshold: the commonality threshold.

=cut


sub analysecontexts {
	my ($iteration, $contexts, $contextsi) = @_;

	my $analysepath = sprintf $infopath, 'ana', $iteration;
	if ($verbose) {
		if (!open(AI, ">:encoding(UTF-8)", $analysepath)) {
			print STDERR "Cannot write file [$analysepath]\n";
			return 0;
		}
	}

	my %identifications = ();
	my %identificationi = ();
	my $ncontexts = scalar keys %$contexts;
	my %contextdistribution = ();
	for my $context (sort keys %$contexts) {
		my $wordinfo = $contexts->{$context};
		my @words = sort keys %$wordinfo;
		$contextdistribution{scalar(@words)}++;
		if (scalar(@words) < 2) {
			next;
		}

# compute the intersection of all contexts of the words found

		printf STDERR "\r\t%s      ", $context;
		
		if ($verbose) {
			printf AI "CONTEXT = %s\n", $context;
			printf AI "\tWORDS = %s\n", join(' ', @words);
		}
		my %intersection = ();
		my $first = 1;
		for my $word (@words) {
			my $wordcontexts = $contextsi->{$word};
			if ($first) {
				for my $c (keys %$wordcontexts) {
					$intersection{$c} = 1;
				}
				$first = 0;
			}
			else {
				for my $c (keys(%intersection), keys(%$wordcontexts)) {
					$intersection{$c} *= $wordcontexts->{$c};
					if (!$intersection{$c}) {
						delete $intersection{$c};
					}
				}
			}
		}
		if ($verbose) {
			for my $c (sort keys %intersection) {
				printf AI "\tINTERSECTION = %s\n", $c;
			}
		}
		my @tobeidentified = ();
		for my $word (keys %$wordinfo) {
#			only identify a word if it has enough commonality
#			i.e. the ratio of its context weight in the intersection and its total context weight
#			should be greater than the commonality threshold
			my $wordcontexts = $contextsi->{$word};
			my $commonweight = 0;
			my $totalweight = 0;
			for my $c (keys %$wordcontexts) {
				my $cweight = $wordcontexts->{$c};
				$totalweight += $cweight;
				if ($intersection{$c}) {
					$commonweight += $cweight;
				}
			}
			my $thiscommonality = $commonweight / $totalweight;
			my $msg;
			if ($thiscommonality < $commonality) {
				$msg = 'OUT';
			}
			else {
				$msg = 'IN';
				push @tobeidentified, $word;
			}
			if ($verbose) {
				printf AI "\t\tWORD %-12s has CW = %4d; TW = %4d; CMN = %.1f => %3s\n", $word, $commonweight, $totalweight, $thiscommonality, $msg;
			}
		}
		if ($verbose) {
			my $rep = (scalar(@tobeidentified) < 2)?'NO IDENTIFICATIONS':sprintf('%2d IDENTIFICATIONS', scalar(@tobeidentified));
			print AI "\t", $rep, "\n";
		}
		if (scalar(@tobeidentified) < 2) {
			next;
		}

		my $newtoken = sprintf "!%d", ++$newtokenindex;
		for my $word (@tobeidentified) {
			$identifications{$word}->{$newtoken} = 1;
			$identificationi{$newtoken}->{$word} = 1;
		}
	}
	print STDERR "\r", ' ' x 80, "\r";
	for my $n (sort {$a <=> $b} keys %contextdistribution) {
		my $ncontexts = $contextdistribution{$n};
		printf STDERR "\t\t%6d contexts with %d words\n", $ncontexts, $n;
	}
	if ($verbose) {
		close AI;
	}

=head2 doc

identifications are instructions to identify certain words
an identification instruction has the following form

word token, token, token, ...

Words that share a token, should be identified, together they form a class.

At the end of an iteration, words are replaced by their class numbers

=cut

	writeindex('Identifications', 'ident', $iteration, \%identifications, 0);
	my %classes = ();
	my %classesi = ();
	for my $word (keys %identifications) {
		my $thisclass = $classes{$word};
		if (!defined $thisclass) {
			$thisclass = ++$newclassindex;
			$classes{$word} = $thisclass;
			$cumclassesi{$thisclass}->{$word} = 1;
		}
		for my $token (keys %{$identifications{$word}}) {
			for my $wordr (keys %{$identificationi{$token}}) {
				$classes{$wordr} = $thisclass;
				$cumclassesi{$thisclass}->{$wordr} = 1;
				$classesi{$thisclass}->{$wordr} = 1;
			}
		}
	}

	writeindex('Classes', 'cls', $iteration, \%classesi, 0, 1);
	return \%classes;
}

sub applyclasses {
	my ($datain, $classes, $dataout) = @_;
	my $applied = 0;
	for my $src (keys %$datain) {
		my $text = $datain->{$src};
		for my $word (@$text) {
			my $class = $classes->{$word};
			my $classrep;
			if (!defined $class) {
				$classrep = $word;
			}
			else {
				$classrep = sprintf "#%d", $class;
				$applied++;
			}
			push @{$dataout->{$src}}, $classrep;
		}
	}
	return $applied;
}

sub writeindex {
	my ($kind, $acro, $iteration, $info, $isresult, $sortnumeric, $nokeys) = @_;
	my $infoiterpath;
	if ($isresult) {
		$infoiterpath = sprintf $resultpath, $acro, $iteration;
	}
	else {
		$infoiterpath = sprintf $infopath, $acro, $iteration;
	}
	printf STDERR "\twriting %s to %s (%s)-file\n", $kind, ($isresult?'result':'intermediate'), $acro;
	if (!open(CI, ">:encoding(UTF-8)", $infoiterpath)) {
		print STDERR "Cannot write file [$infoiterpath]\n";
		return 0;
	}
#	print CI "$kind\n";
	my @keys;
	if ($sortnumeric == 2) {
		@keys = sort {$info->{$a} cmp $info->{$b}} keys %$info;
	}
	elsif ($sortnumeric == 2) {
		@keys = sort {$a <=> $b} keys %$info;
	}
	else {
		@keys = sort keys %$info;
	}
	my $fmtstr;
	if ($nokeys) {
		$fmtstr = "%s%s\n";
	}
	else {
		$fmtstr = "%-10s: %s\n";
	}
	for my $key (@keys) {
		my $keyrep;
		if ($nokeys) {
			$keyrep = '';
		}
		else {
			$keyrep = $key;
		}
		my $value = $info->{$key};
		if (ref $value eq 'HASH') {
			printf CI $fmtstr, $keyrep, join(" ", sort keys %$value);
		}
		elsif (ref $value eq 'ARRAY') {
			printf CI $fmtstr, $keyrep, join(" ", @$value);
		}
		else {
			printf CI $fmtstr, $keyrep, $value;
		}
	}
	close CI;
}

sub writecontext {
	my ($kind, $acro, $iteration, $info, $isresult) = @_;
	my $infoiterpath;
	if ($isresult) {
		$infoiterpath = sprintf $resultpath, $acro, $iteration;
	}
	else {
		$infoiterpath = sprintf $infopath, $acro, $iteration;
	}
	if (!open(CI, ">:encoding(UTF-8)", $infoiterpath)) {
		print STDERR "Cannot write file [$infoiterpath]\n";
		return 0;
	}
	print CI "$kind\n";
	for my $key (sort keys %$info) {
		my $value = $info->{$key};
		if (scalar(keys(%$value)) < 2) {
			next;
		}
		print CI "$key\n";
		for my $word (sort keys %$value) {
			printf CI "\t%s x %d\n", $word, $value->{$word};
		}
	}
	close CI;
}

sub sql {
	my $sql = shift;
	my $dbh = DBI->connect("DBI:mysql:$database{db}",$database{usr},$database{pwd});
	$dbh->{'mysql_enable_utf8'}=1;
	if (!$dbh) {
		print STDERR "Cannot connect to mysql database $database{db}\n";
		return 0;
	}
	my $sth = $dbh->prepare($sql);
	if (!$sth->execute) {
		print STDERR "Cannot execute query [$sql]\n";
		return 0;
	}
	return sub {
		my @row = $sth->fetchrow_array();
		return @row;
	};
}

sub xmltransform {
	my $textref = shift;
	$$textref =~ s/<[^>]+>/ /sg;
	my @words = split /[.,:;"'|\/\\?!#*()_+=^{}\%\[\&\]\@\n\r\$\t -]+/, $$textref;
	for (@words) {
		$_ = lc($_);
	}
	return \@words;
}

sub timestamp {
	my $mark = shift;
	my $nest = shift;
	@{$time{$mark}} = gettimeofday();
	$timenest{$mark} = $nest;
}

sub elapsed {
	my $mark = shift;
	my $elapsed = tv_interval($time{$mark});
	my $seconds = $elapsed;
	my $minutes;
	my $hours;
	if ($seconds > 60) {
		$seconds = int($seconds + 0.5);
		$minutes = int($seconds / 60);
		$seconds = $seconds % 60;
	}
	if ($minutes > 60) {
		$hours = int($minutes / 60);
		$minutes = $minutes % 60;
	}
	my $resultstring = '';
	if (defined $hours) {
		$resultstring .= sprintf "%d h", $hours;
	}
	if (defined $minutes) {
		$resultstring .= sprintf "%d m", $minutes;
	}
	if ($seconds == int($seconds)) {
		$resultstring .= sprintf "%d s", $seconds;
	}
	else {
		$resultstring .= sprintf "%.2f s", $seconds;
	}
	return
		('-' x 80)
	.	$mark
	.	('─' x (20 - length($mark)))
	.	('─' x (40 - $timenest{$mark} * 8))
	.	('─' x (10 - length($resultstring)))
	.	$resultstring
	.	"\n";
}

sub dummy {
	1;
}

sub initialize {
	my $testrep;
	if ($test == 2) {
		$testrep = '-test';
	}
	elsif ($test == 1) {
		$testrep = '-limited';
	}
	else {
		if (defined $inputxml) {
			($testrep) = $inputxml =~ m/([^\/]+)$/;
			$testrep = '-'.$testrep;
		}
		else {
			$testrep = '';
		}
	}

	$infopath = sprintf "%s%s-info-max%d-win%d-comm%.1f-%%s-%%d.txt", $fileout, $testrep, $maxiter, $windowsize, $commonality;
	$resultpath = sprintf "%s%s-max%d-win%d-comm%.1f-%%s-%%s.txt", $resultout, $testrep, $maxiter, $windowsize, $commonality;
}

sub main {
	timestamp('program', 0);
	my $good = 1;
	for (1) {
		initialize();
		if (!readsourcesql()) {
			$good = 0;
			next;
		}
		contextanalysis();
	}
	print STDERR elapsed('program');
	return $good;
}

exit !main();
