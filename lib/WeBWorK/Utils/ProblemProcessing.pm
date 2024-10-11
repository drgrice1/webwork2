################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2024 The WeBWorK Project, https://github.com/openwebwork
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

package WeBWorK::Utils::ProblemProcessing;
use Mojo::Base 'Exporter', -signatures, -async_await;

=head1 NAME

WeBWorK::Utils::ProblemProcessing - contains subroutines for generating output
for the problem pages, especially those generated by Problem.pm.

=cut

use Mojo::JSON qw(encode_json);
use Email::Stuffer;
use Try::Tiny;
use Mojo::JSON qw(encode_json decode_json);

use WeBWorK::Debug;
use WeBWorK::Utils qw(encodeAnswers createEmailSenderTransportSMTP);
use WeBWorK::Utils::DateTime qw(before after);
use WeBWorK::Utils::JITAR qw(jitar_id_to_seq jitar_problem_adjusted_status);
use WeBWorK::Utils::Logs qw(writeLog writeCourseLog);
use WeBWorK::Authen::LTIAdvanced::SubmitGrade;
use WeBWorK::Authen::LTIAdvantage::SubmitGrade;
use Caliper::Sensor;
use Caliper::Entity;

our @EXPORT_OK = qw(
	process_and_log_answer
	compute_reduced_score
	compute_unreduced_score
	create_ans_str_from_responses
	jitar_send_warning_email
);

# Performs functions of processing and recording the answer given in the page.
# Returns the appropriate scoreRecordedMessage.
# Note that $c must be a WeBWorK::ContentGenerator object whose associated route is parented by the set_list route.
# In addition $c must have the neccessary hash data values set for this method.
# Those are 'will', 'problem', 'pg', and 'set'.
async sub process_and_log_answer ($c) {
	my $ce            = $c->ce;
	my $db            = $c->db;
	my $effectiveUser = $c->param('effectiveUser');
	my $authz         = $c->authz;

	my %will          = %{ $c->{will} };
	my $submitAnswers = $c->{submitAnswers};
	my $problem       = $c->{problem};
	my $pg            = $c->{pg};
	my $set           = $c->{set};
	my $courseID      = $c->stash('courseID');

	# logging student answers
	my $pureProblem = $db->getUserProblem($problem->user_id, $problem->set_id, $problem->problem_id);
	my $answer_log  = $ce->{courseFiles}{logs}{answer_log};

	# Transfer persistent problem data from the PERSISTENCE_HASH:
	# - Get keys to update first, to avoid extra work when no updates
	#   are needed. When none, we avoid the need to decode/encode JSON,
	#   or to save the pureProblem.
	# - We are assuming that there is no need to DELETE old
	#   persistent data if the hash is empty, even if in
	#   potential there may be some data already in the database.
	if (defined($pureProblem)) {
		my @persistent_data_keys = keys %{ $pg->{PERSISTENCE_HASH_UPDATED} };
		if (@persistent_data_keys) {
			my $json_data = decode_json($pureProblem->{problem_data} || '{}');
			for my $key (@persistent_data_keys) {
				$json_data->{$key} = $pg->{PERSISTENCE_HASH}{$key};
			}
			$pureProblem->problem_data(encode_json($json_data));
			if (!$submitAnswers) {    # would not be saved below
				$db->putUserProblem($pureProblem);
			}
		}
	}

	my ($encoded_last_answer_string, $scores2, $answer_types_string);
	my $scoreRecordedMessage = '';

	if (defined($answer_log) && defined($pureProblem) && $submitAnswers) {
		my $past_answers_string;
		($past_answers_string, $encoded_last_answer_string, $scores2, $answer_types_string) =
			create_ans_str_from_responses($c->{formFields}, $pg, $pureProblem->flags =~ /:needs_grading/);

		if (!$authz->hasPermissions($effectiveUser, 'dont_log_past_answers')) {
			# Use the time the submission processing began, but must convert the
			# floating point value from Time::HiRes to an integer for use below.
			# Truncate toward 0 intentionally, so the integer value set is never
			# larger than the original floating point value.
			my $timestamp = int($c->submitTime);

			# store in answer_log
			writeCourseLog(
				$ce,
				'answer_log',
				join('',
					'|', $problem->user_id, '|',  $problem->set_id, '|',  $problem->problem_id,
					'|', $scores2,          "\t", $timestamp,       "\t", $past_answers_string,
				),
				$timestamp
			);

			# add to PastAnswer db
			my $pastAnswer = $db->newPastAnswer();
			$pastAnswer->user_id($problem->user_id);
			$pastAnswer->set_id($problem->set_id);
			$pastAnswer->problem_id($problem->problem_id);
			$pastAnswer->timestamp($timestamp);
			$pastAnswer->scores($scores2);
			$pastAnswer->answer_string($past_answers_string);
			$pastAnswer->source_file($problem->source_file);
			$pastAnswer->problem_seed($problem->problem_seed);
			$db->addPastAnswer($pastAnswer);
		}
	}

	# Process any writing of external data
	process_external_data($c);

	# this stores previous answers to the problem to provide "sticky answers"
	if ($submitAnswers) {
		if (defined $pureProblem) {
			# store answers in DB for sticky answers
			my %answersToStore;

			# store last answer to database for use in "sticky" answers
			$problem->last_answer($encoded_last_answer_string);
			$pureProblem->last_answer($encoded_last_answer_string);

			# store state in DB if it makes sense
			if ($will{recordAnswers}) {
				my $score =
					compute_reduced_score($ce, $problem, $set, $pg->{state}{recorded_score}, $c->submitTime);
				$problem->status($score) if $score > $problem->status;

				$problem->sub_status($problem->status)
					if (!$c->ce->{pg}{ansEvalDefaults}{enableReducedScoring}
						|| !$set->enable_reduced_scoring
						|| before($set->reduced_scoring_date, $c->submitTime));

				$problem->attempted(1);
				$problem->num_correct($pg->{state}{num_of_correct_ans});
				$problem->num_incorrect($pg->{state}{num_of_incorrect_ans});

				$pureProblem->status($problem->status);
				$pureProblem->sub_status($problem->sub_status);
				$pureProblem->attempted(1);
				$pureProblem->num_correct($pg->{state}{num_of_correct_ans});
				$pureProblem->num_incorrect($pg->{state}{num_of_incorrect_ans});

				# Add flags which are really a comma separated list of answer types.
				$pureProblem->flags($answer_types_string);

				if ($db->putUserProblem($pureProblem)) {
					$scoreRecordedMessage = $c->maketext('Your score was recorded.');
				} else {
					$scoreRecordedMessage = $c->maketext('Your score was not recorded because there was a failure '
							. 'in storing the problem record to the database.');
				}
				# write to the transaction log, just to make sure
				writeLog($ce, 'transaction',
					$problem->problem_id . "\t"
						. $problem->set_id . "\t"
						. $problem->user_id . "\t"
						. $problem->source_file . "\t"
						. $problem->value . "\t"
						. $problem->max_attempts . "\t"
						. $problem->problem_seed . "\t"
						. $pureProblem->status . "\t"
						. $pureProblem->attempted . "\t"
						. $pureProblem->last_answer . "\t"
						. $pureProblem->num_correct . "\t"
						. $pureProblem->num_incorrect);

				if ($ce->{caliper}{enabled}
					&& defined($answer_log)
					&& !$authz->hasPermissions($effectiveUser, 'dont_log_past_answers'))
				{
					my $caliper_sensor = Caliper::Sensor->new($ce);
					my $startTime      = $c->param('startTime');
					my $endTime        = time();

					my $completed_question_event = {
						type    => 'AssessmentItemEvent',
						action  => 'Completed',
						profile => 'AssessmentProfile',
						object  => Caliper::Entity::problem_user(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg
						),
						generated => Caliper::Entity::answer(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg,
							$startTime,
							$endTime
						),
					};
					my $submitted_set_event = {
						type      => 'AssessmentEvent',
						action    => 'Submitted',
						profile   => 'AssessmentProfile',
						object    => Caliper::Entity::problem_set($ce, $db, $problem->set_id()),
						generated => Caliper::Entity::problem_set_attempt(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->user_id(),
							$startTime,
							$endTime
						),
					};
					my $tool_use_event = {
						type    => 'ToolUseEvent',
						action  => 'Used',
						profile => 'ToolUseProfile',
						object  => Caliper::Entity::webwork_app(),
					};
					$caliper_sensor->sendEvents($c,
						[ $completed_question_event, $submitted_set_event, $tool_use_event ]);

					# reset start time
					$c->param('startTime', '');
				}

				# Messages about passing the score back to the LMS
				if ($ce->{LTIGradeMode}) {
					my $LMSname        = $ce->{LTI}{ $ce->{LTIVersion} }{LMS_name};
					my $LTIGradeResult = -1;
					if ($ce->{LTIGradeOnSubmit}) {
						$LTIGradeResult = 0;
						my $grader = $ce->{LTI}{ $ce->{LTIVersion} }{grader}->new($c);
						if ($ce->{LTIGradeMode} eq 'course') {
							$LTIGradeResult = await $grader->submit_course_grade($problem->user_id);
						} elsif ($ce->{LTIGradeMode} eq 'homework') {
							$LTIGradeResult = await $grader->submit_set_grade($problem->user_id, $problem->set_id);
						}
						if ($LTIGradeResult == 0) {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was not successfully sent to [_1].', $LMSname);
						} elsif ($LTIGradeResult > 0) {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was successfully sent to [_1].', $LMSname);
						}
					} elsif ($ce->{LTIMassUpdateInterval} > 0) {
						$scoreRecordedMessage .= $c->tag('br');
						if ($ce->{LTIMassUpdateInterval} < 120) {
							$scoreRecordedMessage .= $c->maketext('Scores are sent to [_1] every [quant,_2,second].',
								$LMSname, $ce->{LTIMassUpdateInterval});
						} elsif ($ce->{LTIMassUpdateInterval} < 7200) {
							$scoreRecordedMessage .= $c->maketext('Scores are sent to [_1] every [quant,_2,minute].',
								$LMSname, int($ce->{LTIMassUpdateInterval} / 60 + 0.99));
						} else {
							$scoreRecordedMessage .= $c->maketext('Scores are sent to [_1] every [quant,_2,hour].',
								$LMSname, int($ce->{LTIMassUpdateInterval} / 3600 + 0.9999));
						}
					}
				}
			} else {
				# The "sticky" answers get saved here when $will{recordAnswers} is false
				$db->putUserProblem($pureProblem);
				if (before($set->open_date, $c->submitTime) || after($set->due_date, $c->submitTime)) {
					$scoreRecordedMessage .=
						$c->maketext('Your score was not recorded because this homework set is closed.');
				} else {
					$scoreRecordedMessage .= $c->maketext('Your score was not recorded.');
				}
			}
		} else {
			$scoreRecordedMessage =
				$c->maketext('Your score was not recorded because this problem has not been assigned to you.');
		}
	}

	$c->{scoreRecordedMessage} = $scoreRecordedMessage;
	return $scoreRecordedMessage;
}

# Determines if a set is in the reduced scoring period, and if so returns the reduced score.
# Otherwise it returns the unadjusted score.
sub compute_reduced_score ($ce, $problem, $set, $score, $submitTime) {
	# If no adjustments need to be applied, return the full score.
	if (!$ce->{pg}{ansEvalDefaults}{enableReducedScoring}
		|| !$set->enable_reduced_scoring
		|| !$set->reduced_scoring_date
		|| $set->reduced_scoring_date == $set->due_date
		|| before($set->reduced_scoring_date, $submitTime)
		|| $score <= $problem->sub_status)
	{
		return $score;
	}

	# Return the reduced score.
	return $problem->sub_status + $ce->{pg}{ansEvalDefaults}{reducedScoringValue} * ($score - $problem->sub_status);
}

# Compute the "unreduced" score for a problem.
# If reduced scoring is enabled for the set and the sub_status is less than the status, then the status is the
# reduced score.  In that case compute and return the unreduced score that resulted in that reduced score.
sub compute_unreduced_score ($ce, $problem, $set) {
	if ($set->enable_reduced_scoring
		&& $ce->{pg}{ansEvalDefaults}{reducedScoringValue}
		&& defined $problem->sub_status
		&& $problem->sub_status < $problem->status)
	{
		# Note that if the status has been modified by an instructor using a problem grader or an achivement, then the
		# computed unreduced score can be greater than one.  So make sure to cap the score.
		my $unreducedScore =
			($problem->status - $problem->sub_status) / $ce->{pg}{ansEvalDefaults}{reducedScoringValue} +
			$problem->sub_status;
		return $unreducedScore > 1 ? 1 : $unreducedScore;
	}
	return $problem->status;
}

# create answer string from responses hash
# ($past_answers_string, $encoded_last_answer_string, $scores_string, $answer_types_string)
#     = create_ans_str_from_responses($formFields, $pg)
#
# input: $formFields     - a hash containing the form field input data for the submission.
#        $pg             - a 'WeBWorK::PG' object.
#        $needed_grading - a boolean value that indicates that this problem previously needed grading
#                          (only matters for problems with essay questions).
# output: (str, str, str, str)
#
# The extra persistence objects do need to be included in problem->last_answer
# in order to keep those objects persistent -- as long as RECORD_FORM_ANSWER
# is used to preserve objects by piggy backing on the persistence mechanism for answers.
sub create_ans_str_from_responses ($formFields, $pg, $needed_grading = 0) {
	my $scores_string = '';
	my @answerTypes;
	my $needsGrading = '';
	my %answers_to_store;
	my @past_answers_order;
	my @last_answer_order;

	my %pg_answers_hash = %{ $pg->{PG_ANSWERS_HASH} };
	for my $ans_id (@{ $pg->{flags}{ANSWER_ENTRY_ORDER} // [] }) {
		$scores_string .= ($pg_answers_hash{$ans_id}{rh_ans}{score} // 0) >= 1 ? '1' : '0';
		push @answerTypes, $pg_answers_hash{$ans_id}{rh_ans}{type} // '';
		for my $response_id (@{ $pg_answers_hash{$ans_id}{response_obj}{response_order} }) {
			$answers_to_store{$response_id} = $formFields->{$response_id};
			push @past_answers_order, $response_id;
			push @last_answer_order,  $response_id;

			# Determine if this is an essay answer that needs to be graded.
			if (
				$answerTypes[-1] eq 'essay'
				&& (defined $formFields->{$response_id} && $formFields->{$response_id} ne '')
				&& (
					$needed_grading
					|| (!defined $formFields->{"previous_${response_id}"}
						|| $formFields->{"previous_${response_id}"} ne $formFields->{$response_id})
				)
				)
			{
				$needsGrading = ':needs_grading';
			}
		}
	}

	# KEPT_EXTRA_ANSWERS needs to be stored in last_answer in order to preserve persistence items.
	# The persistence items do not need to be stored in past_answers_string.
	# Don't add _ext_data items.  Those are stored elsewhere.
	for my $entry_id (@{ $pg->{flags}{KEPT_EXTRA_ANSWERS} }) {
		next if exists($answers_to_store{$entry_id}) || $entry_id =~ /^_ext_data/;
		$answers_to_store{$entry_id} = $formFields->{$entry_id};
		push @last_answer_order, $entry_id;
	}

	my $past_answers_string = join(
		"\t",
		map {
			ref($answers_to_store{$_}) eq 'ARRAY'
				? join('&#9070;', @{ $answers_to_store{$_} })
				: ($answers_to_store{$_} // '')
		} @past_answers_order
	);

	my $encoded_last_answer_string = encodeAnswers(\%answers_to_store, \@last_answer_order);
	# past_answers_string is stored in past_answer table.
	# encoded_last_answer_string is used in `last_answer` entry of the problem_user table.
	return ($past_answers_string, $encoded_last_answer_string, $scores_string, join(',', @answerTypes) . $needsGrading);
}

# If you provide this subroutine with a userProblem it will notify the instructors of the course that the student has
# finished the problem, and its children, and did not get 100%.
# Note that $c must be a WeBWorK::ContentGenerator object whose associated route is parented by the set_list route.
sub jitar_send_warning_email ($c, $userProblem) {
	my $ce        = $c->ce;
	my $db        = $c->db;
	my $authz     = $c->authz;
	my $courseID  = $c->stash('courseID');
	my $userID    = $userProblem->user_id;
	my $setID     = $userProblem->set_id;
	my $problemID = $userProblem->problem_id;

	my $status = jitar_problem_adjusted_status($userProblem, $c->db);
	$status = eval { sprintf('%.0f%%', $status * 100) };    # round to whole number

	my $user = $db->getUser($userID);

	debug("Couldn't get user $userID from database") unless $user;

	my $emailableURL =
		$c->systemLink($c->url_for, params => { effectiveUser => $userID }, use_abs_url => 1, authen => 0);

	my @recipients = $c->fetchEmailRecipients('score_sets', $user);
	# send to all users with permission to score_sets and an email address

	my $sender;
	if ($user->email_address) {
		$sender = $user->rfc822_mailbox;
	} elsif ($user->full_name) {
		$sender = $user->full_name;
	} else {
		$sender = $userID;
	}

	$problemID = join('.', jitar_id_to_seq($problemID));

	my %subject_map = (
		'c' => $courseID,
		'u' => $userID,
		's' => $setID,
		'p' => $problemID,
		'x' => $user->section,
		'r' => $user->recitation,
		'%' => '%',
	);
	my $chars   = join('', keys %subject_map);
	my $subject = $ce->{mail}{feedbackSubjectFormat}
		|| 'WeBWorK question from %c: %u set %s/prob %p';    # default if not entered
	$subject =~ s/%([$chars])/defined $subject_map{$1} ? $subject_map{$1} : ""/eg;

	my $full_name     = $user->full_name;
	my $email_address = $user->email_address;
	my $student_id    = $user->student_id;
	my $section       = $user->section;
	my $recitation    = $user->recitation;
	my $comment       = $user->comment;

	# print message
	my $msg = qq/
This  message was automatically generated by WeBWorK.

User $full_name ($userID) has not sucessfully completed the review for problem $problemID in set $setID.
Their final adjusted score on the problem is $status.

Click this link to visit the problem: $emailableURL

User ID:    $userID
Name:       $full_name
Email:      $email_address
Student ID: $student_id
Section:    $section
Recitation: $recitation
Comment:    $comment
/;

	my $email = Email::Stuffer->to(join(',', @recipients))->subject($subject)->text_body($msg);
	if ($ce->{jitar_sender_email}) {
		$email->from("$full_name <$ce->{jitar_sender_email}>")->reply_to($sender);
	} else {
		$email->from($sender);
	}

	# Extra headers
	$email->header('X-WeBWorK-Course: ', $courseID) if defined $courseID;
	if ($user) {
		$email->header('X-WeBWorK-User: ',       $user->user_id);
		$email->header('X-WeBWorK-Section: ',    $user->section);
		$email->header('X-WeBWorK-Recitation: ', $user->recitation);
	}
	$email->header('X-WeBWorK-Set: ',     $setID)     if defined $setID;
	$email->header('X-WeBWorK-Problem: ', $problemID) if defined $problemID;

	# $ce->{mail}{set_return_path} is the address used to report returned email if defined and non empty.  It is an
	# argument used in sendmail() (aka Email::Stuffer::send_or_die).  For arcane historical reasons sendmail actually
	# sets the field "MAIL FROM" and the smtp server then uses that to set "Return-Path".
	# references:
	#  https://stackoverflow.com/questions/1235534/what-is-the-behavior-difference-between-return-path-reply-to-and-from
	#  https://metacpan.org/pod/Email::Sender::Manual::QuickStart#envelope-information
	try {
		$email->send_or_die({
			transport => createEmailSenderTransportSMTP($ce),
			$ce->{mail}{set_return_path} ? (from => $ce->{mail}{set_return_path}) : ()
		});
		debug('Successfully sent JITAR alert message');
	} catch {
		$c->log->error('Failed to send JITAR alert message: ' . (ref($_) ? $_->message : $_));
	};

	return '';
}

# If a problem uses external data, save it to the database.
sub process_external_data {
	my $c       = shift;
	my $db      = $c->db;
	my $pg      = $c->{pg};
	my $problem = $c->{problem};

	return unless $c->{submitAnswers};

	# Find the _ext_data answers.  If there aren't any, then return.
	my @ext_data = grep {/^_ext_data/} @{ $pg->{flags}{KEPT_EXTRA_ANSWERS} };
	return unless @ext_data;

	my $user_set  = $db->getUserSet($problem->user_id, $problem->set_id);
	my $json_data = decode_json($user_set->{external_data} || '{}');

	for (@ext_data) {
		my ($t, $ans_name, $key) = split(/:/, $_);

		next if $pg->{PG_ANSWERS_HASH}{$ans_name}{rh_ans}{score} == 0;

		$json_data->{$key} = $pg->{PG_ANSWERS_HASH}{$ans_name}{rh_ans}{student_value};
	}

	$user_set->external_data(encode_json($json_data));
	$db->putUserSet($user_set);

	return;
}

1;
