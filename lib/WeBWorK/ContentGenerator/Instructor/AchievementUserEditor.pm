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

package WeBWorK::ContentGenerator::Instructor::AchievementUserEditor;
use parent qw(WeBWorK::ContentGenerator::Instructor);

=head1 NAME

WeBWorK::ContentGenerator::Instructor::AchievementUserEditor - List and edit the
users assigned to an achievement.

=cut

use strict;
use warnings;

sub initialize {
	my ($self)        = @_;
	my $r             = $self->r;
	my $urlpath       = $r->urlpath;
	my $authz         = $r->authz;
	my $db            = $r->db;
	my $achievementID = $urlpath->arg('achievementID');
	my $user          = $r->param('user');

	# Make sure this is defined for the template.
	$r->stash->{userRecords} = [];

	# Check permissions
	return unless $authz->hasPermissions($user, 'edit_achievements');

	my @all_users     = $db->listUsers;
	my %selectedUsers = map { $_ => 1 } $r->param('selected');

	my $doAssignToSelected = 0;

	#Check and see if we need to assign or unassign things
	if (defined $r->param('assignToAll')) {
		$self->addmessage($r->tag(
			'p',
			class => 'alert alert-success p-1 mb-0',
			$r->maketext('Achievement has been assigned to all users.')
		));
		%selectedUsers      = map { $_ => 1 } @all_users;
		$doAssignToSelected = 1;
	} elsif (defined $r->param('unassignFromAll')
		&& defined($r->param('unassignFromAllSafety'))
		&& $r->param('unassignFromAllSafety') == 1)
	{
		%selectedUsers = ();
		$self->addmessage($r->tag(
			'p',
			class => 'alert alert-danger p-1 mb-0',
			$r->maketext('Achievement has been unassigned to all students.')
		));
		$doAssignToSelected = 1;
	} elsif (defined $r->param('assignToSelected')) {
		$self->addmessage($r->tag(
			'p',
			class => 'alert alert-success p-1 mb-0',
			$r->maketext('Achievement has been assigned to selected users.')
		));
		$doAssignToSelected = 1;
	} elsif (defined $r->param('unassignFromAll')) {
		# no action taken
		$self->addmessage($r->tag('p', class => 'alert alert-danger p-1 mb-0', $r->maketext('No action taken')));
	}

	#do actual assignment and unassignment
	if ($doAssignToSelected) {

		my %achievementUsers = map { $_ => 1 } $db->listAchievementUsers($achievementID);
		foreach my $selectedUser (@all_users) {
			if (exists $selectedUsers{$selectedUser} && $achievementUsers{$selectedUser}) {
				# update existing user data (in case fields were changed)
				my $userAchievement = $db->getUserAchievement($selectedUser, $achievementID);

				my $updatedEarned = $r->param("$selectedUser.earned") ? 1 : 0;
				my $earned        = $userAchievement->earned          ? 1 : 0;
				if ($updatedEarned != $earned) {

					$userAchievement->earned($updatedEarned);
					my $globalUserAchievement = $db->getGlobalUserAchievement($selectedUser);
					my $achievement           = $db->getAchievement($achievementID);

					my $points        = $achievement->points                       || 0;
					my $initialpoints = $globalUserAchievement->achievement_points || 0;
					#add the correct number of points if we
					# are saying that the user now earned the
					# achievement, or remove them otherwise
					if ($updatedEarned) {

						$globalUserAchievement->achievement_points($initialpoints + $points);
					} else {
						$globalUserAchievement->achievement_points($initialpoints - $points);
					}

					$db->putGlobalUserAchievement($globalUserAchievement);
				}

				$userAchievement->counter($r->param("$selectedUser.counter"));
				$db->putUserAchievement($userAchievement);

			} elsif (exists $selectedUsers{$selectedUser}) {
				# add users that dont exist
				my $userAchievement = $db->newUserAchievement();
				$userAchievement->user_id($selectedUser);
				$userAchievement->achievement_id($achievementID);
				$db->addUserAchievement($userAchievement);

				#If they dont have global achievement data, then add that too
				if (not $db->existsGlobalUserAchievement($selectedUser)) {
					my $globalUserAchievement = $db->newGlobalUserAchievement();
					$globalUserAchievement->user_id($selectedUser);
					$db->addGlobalUserAchievement($globalUserAchievement);
				}

			} else {
				# delete users who are not selected
				# but dont delete users who dont exist
				next unless $achievementUsers{$selectedUser};
				$db->deleteUserAchievement($selectedUser, $achievementID);
			}
		}
	}

	my @userRecords;
	for my $currentUser (@all_users) {
		my $userObj = $r->db->getUser($currentUser);
		die "Unable to find user object for $currentUser. " unless $userObj;
		push(@userRecords, $userObj);
	}
	@userRecords =
		sort { (lc($a->section) cmp lc($b->section)) || (lc($a->last_name) cmp lc($b->last_name)) } @userRecords;

	$r->stash->{userRecords} = \@userRecords;

	return;
}

1;
