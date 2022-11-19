################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2022 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::ContentGenerator::Instructor::ShowAnswers;
use parent qw(WeBWorK::ContentGenerator::Instructor);

=head1 NAME

WeBWorK::ContentGenerator::Instructor::ShowAnswers.pm  -- display past answers of students

=cut

use strict;
use warnings;

use Future::AsyncAwait;
use Text::CSV;
use Mojo::File;

use WeBWorK::Utils qw(sortByName jitar_id_to_seq);
use WeBWorK::Utils::Rendering qw(renderPG);

use constant PAST_ANSWERS_FILENAME => 'past_answers';

async sub initialize {
	my $self    = shift;
	my $r       = $self->r;
	my $urlpath = $r->urlpath;
	my $db      = $r->db;
	my $ce      = $r->ce;
	my $authz   = $r->authz;
	my $user    = $r->param('user');

	my $selectedSets     = [ $r->param('selected_sets') ]     // [];
	my $selectedProblems = [ $r->param('selected_problems') ] // [];

	unless ($authz->hasPermissions($user, "view_answers")) {
		$self->addbadmessage("You aren't authorized to view past answers");
		return;
	}

	# The stop acting button doesn't perform a submit action and so
	# these extra parameters are passed so that if an instructor stops
	# acting the current studentID, setID and problemID will be maintained

	my $extraStopActingParams;
	$extraStopActingParams->{selected_users}    = $r->param('selected_users');
	$extraStopActingParams->{selected_sets}     = $r->param('selected_sets');
	$extraStopActingParams->{selected_problems} = $r->param('selected_problems');
	$r->{extraStopActingParams}                 = $extraStopActingParams;

	my $selectedUsers = [ $r->param('selected_users') ] // [];

	my $instructor = $authz->hasPermissions($user, "access_instructor_tools");

	# If not instructor then force table to use current user-id
	if (!$instructor) {
		$selectedUsers = [$user];
	}

	return unless $selectedUsers && $selectedSets && $selectedProblems;

	my %records;
	my %prettyProblemNumbers;
	my %answerTypes;

	foreach my $studentUser (@$selectedUsers) {
		my @sets;

		# search for selected sets assigned to students
		my @allSets = $db->listUserSets($studentUser);
		foreach my $setName (@allSets) {
			my $set = $db->getMergedSet($studentUser, $setName);
			if (defined($set->assignment_type) && $set->assignment_type =~ /gateway/) {
				my @versions = $db->listSetVersions($studentUser, $setName);
				foreach my $version (@versions) {
					if (grep {/^$setName,v$version$/} @$selectedSets) {
						$set = $db->getUserSet($studentUser, "$setName,v$version");
						push(@sets, $set);
					}
				}
			} elsif (grep {/^$setName$/} @$selectedSets) {
				push(@sets, $set);
			}

		}

		next unless @sets;

		foreach my $setRecord (@sets) {
			my @problemNumbers;
			my $setName    = $setRecord->set_id;
			my $isJitarSet = (defined($setRecord->assignment_type) && $setRecord->assignment_type eq 'jitar') ? 1 : 0;

			# search for matching problems
			my @allProblems = $db->listUserProblems($studentUser, $setName);
			next unless @allProblems;
			foreach my $problemNumber (@allProblems) {
				my $prettyProblemNumber = $problemNumber;
				if ($isJitarSet) {
					$prettyProblemNumber = join('.', jitar_id_to_seq($problemNumber));
				}
				$prettyProblemNumbers{$setName}{$problemNumber} = $prettyProblemNumber;

				if (grep {/^$prettyProblemNumber$/} @$selectedProblems) {
					push(@problemNumbers, $problemNumber);
				}
			}

			next unless @problemNumbers;

			foreach my $problemNumber (@problemNumbers) {
				my @pastAnswerIDs = $db->listProblemPastAnswers($studentUser, $setName, $problemNumber);

				if (!defined($answerTypes{$setName}{$problemNumber})) {
					#set up a silly problem to figure out what type the answers are
					#(why isn't this stored somewhere)
					my $unversionedSetName = $setName;
					$unversionedSetName =~ s/,v[0-9]*$//;
					my $displayMode = $self->{displayMode};
					my $formFields  = { WeBWorK::Form->new_from_paramable($r)->Vars };
					my $set         = $db->getMergedSet($studentUser, $unversionedSetName);
					my $problem     = $db->getMergedProblem($studentUser, $unversionedSetName, $problemNumber);
					my $userobj     = $db->getUser($studentUser);
					#if these things dont exist then the problem doesnt exist and past answers dont make sense
					next unless defined($set) && defined($problem) && defined($userobj);

					my $gProblem = $db->getGlobalProblem($unversionedSetName, $problemNumber);

					my $pg = await renderPG(
						$r, $userobj, $set, $problem,
						$set->psvn,
						$formFields,
						{    # translation options
							displayMode              => 'plainText',
							showHints                => 0,
							showSolutions            => 0,
							refreshMath2img          => 0,
							processAnswers           => 1,
							permissionLevel          => $db->getPermissionLevel($studentUser)->permission,
							effectivePermissionLevel => $db->getPermissionLevel($studentUser)->permission,
						},
					);

					# check to see what type the answers are.  right now it only checks for essay but could do more
					my %answerHash = %{ $pg->{answers} };
					my @answerTypes;

					foreach (sortByName(undef, keys %answerHash)) {
						push(@answerTypes, defined($answerHash{$_}->{type}) ? $answerHash{$_}->{type} : 'undefined');
					}

					$answerTypes{$setName}{$problemNumber} = [@answerTypes];
				}

				my @pastAnswers = $db->getPastAnswers(\@pastAnswerIDs);

				foreach my $pastAnswer (@pastAnswers) {
					my $answerID = $pastAnswer->answer_id;
					my $answers  = $pastAnswer->answer_string;
					my $scores   = $pastAnswer->scores;
					my $time     = $pastAnswer->timestamp;
					my @scores   = split(//,   $scores);
					my @answers  = split(/\t/, $answers);

					$records{$studentUser}{$setName}{$problemNumber}{$answerID} = {
						time        => $time,
						answers     => [@answers],
						answerTypes => $answerTypes{$setName}{$problemNumber},
						scores      => [@scores],
						comment     => $pastAnswer->comment_string // ''
					};

				}

			}
		}
	}

	$self->{records}              = \%records;
	$self->{prettyProblemNumbers} = \%prettyProblemNumbers;

	# Prepare a csv if we are an instructor
	if ($instructor && $r->param('createCSV')) {
		my $filename     = PAST_ANSWERS_FILENAME;
		my $scoringDir   = $ce->{courseDirs}->{scoring};
		my $fullFilename = "${scoringDir}/${filename}.csv";
		if (-e $fullFilename) {
			my $i = 1;
			while (-e "${scoringDir}/${filename}_bak$i.csv") { $i++; }    #don't overwrite existing backups
			my $bakFileName = "${scoringDir}/${filename}_bak$i.csv";
			rename $fullFilename, $bakFileName or warn "Unable to rename $filename to $bakFileName";
		}

		$filename .= '.csv';

		if (my $fh = Mojo::File->new($fullFilename)->open('>:encoding(UTF-8)')) {

			my $csv = Text::CSV->new({ "eol" => "\n" });
			my @columns;

			$columns[0] = $r->maketext('User ID');
			$columns[1] = $r->maketext('Set ID');
			$columns[2] = $r->maketext('Problem Number');
			$columns[3] = $r->maketext('Timestamp');
			$columns[4] = $r->maketext('Scores');
			$columns[5] = $r->maketext('Answers');
			$columns[6] = $r->maketext('Comment');

			$csv->print($fh, \@columns);

			foreach my $studentID (sort keys %records) {
				$columns[0] = $studentID;
				foreach my $setID (sort keys %{ $records{$studentID} }) {
					$columns[1] = $setID;
					foreach my $probNum (sort { $a <=> $b } keys %{ $records{$studentID}{$setID} }) {
						$columns[2] = $prettyProblemNumbers{$setID}{$probNum};
						foreach my $answerID (sort { $a <=> $b } keys %{ $records{$studentID}{$setID}{$probNum} }) {
							my %record = %{ $records{$studentID}{$setID}{$probNum}{$answerID} };

							$columns[3] = $self->formatDateTime($record{time});
							$columns[4] = join(',',  @{ $record{scores} });
							$columns[5] = join("\t", @{ $record{answers} });
							$columns[6] = $record{comment};

							$csv->print($fh, \@columns);
						}
					}
				}
			}

			$fh->close;
		} else {
			$r->log->warn("Unable to open $fullFilename for writing");
		}
	}

	return;
}

sub getInstructorData {
	my $self = shift;
	my $r    = $self->r;
	my $db   = $r->db;
	my $ce   = $r->ce;
	my $user = $r->param('user');

	# Get all users except the set level proctors, and restrict to the sections or recitations that are allowed for
	# the user if such restrictions are defined.
	my @users = $db->getUsersWhere({
		user_id => { not_like => 'set_id:%' },
		$ce->{viewable_sections}{$user} || $ce->{viewable_recitations}{$user}
		? (
			-or => [
				$ce->{viewable_sections}{$user}    ? (section    => $ce->{viewable_sections}{$user})    : (),
				$ce->{viewable_recitations}{$user} ? (recitation => $ce->{viewable_recitations}{$user}) : ()
			]
			)
		: ()
	});

	my @GlobalSets = $db->getGlobalSetsWhere({}, 'set_id');

	my @expandedGlobalSetIDs;

	# Process global sets, and find the maximum number of versions for all users for each gateway set.
	for my $globalSet (@GlobalSets) {
		my $setName = $globalSet->set_id;
		if ($globalSet->assignment_type && $globalSet->assignment_type =~ /gateway/) {
			my $maxVersions = 0;
			for my $user (@users) {
				my $versions = $db->countSetVersions($user->user_id, $setName);
				$maxVersions = $versions if ($versions > $maxVersions);
			}
			if ($maxVersions) {
				for (my $i = 1; $i <= $maxVersions; $i++) {
					push @expandedGlobalSetIDs, "$setName,v$i";
				}
			}
		} else {
			push @expandedGlobalSetIDs, $setName;
		}
	}

	@expandedGlobalSetIDs = sort @expandedGlobalSetIDs;

	my %all_problems;

	# Determine which problems to show.
	for my $globalSet (@GlobalSets) {
		my @problems = $db->listGlobalProblems($globalSet->set_id);
		if ($globalSet->assignment_type && $globalSet->assignment_type eq 'jitar') {
			@problems = map { join('.', jitar_id_to_seq($_)) } @problems;
		}

		@all_problems{@problems} = (1) x @problems;
	}

	return (
		users                => \@users,
		expandedGlobalSetIDs => \@expandedGlobalSetIDs,
		globalProblemIDs     => [ sort prob_id_sort keys %all_problems ],
		filename             => PAST_ANSWERS_FILENAME . '.csv'
	);
}

sub byData {
	my ($A, $B) = ($a, $b);
	$A =~ s/\|[01]*\t([^\t]+)\t.*/|$1/;    # remove answers and correct/incorrect status
	$B =~ s/\|[01]*\t([^\t]+)\t.*/|$1/;
	return $A cmp $B;
}

# sorts problem ID's so that all just-in-time like ids are at the bottom
# of the list in order and other problems
sub prob_id_sort {

	my @seqa = split(/\./, $a);
	my @seqb = split(/\./, $b);

	# go through problem number sequence
	for (my $i = 0; $i <= $#seqa; $i++) {
		# if at some point two numbers are different return the comparison.
		# e.g. 2.1.3 vs 1.2.6
		if ($seqa[$i] != $seqb[$i]) {
			return $seqa[$i] <=> $seqb[$i];
		}

		# if all of the values are equal but b is shorter then it comes first
		# i.e. 2.1.3 vs 2.1
		if ($i == $#seqb) {
			return 1;
		}
	}

	# if all of the values are equal and a and b are the same length then equal
	# otherwise a was shorter than b so a comes first.
	if ($#seqa == $#seqb) {
		return 0;
	} else {
		return -1;
	}
}

1;
