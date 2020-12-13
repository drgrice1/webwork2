/***********************************************************
 *
 * Javascript for gateway tests.
 *
 * This file includes the routines allowing navigation
 * within gateway tests, manages the timer, and posts
 * alerts when test time is winding up.
 *
 * The timer code relies on the existence of data attributes for
 * the gwTimer div created by GatewayQuiz.pm
 *
 ***********************************************************/

$(function() {
	// Gateway timer
	var timerDiv = $('#gwTimer'); // The timer div element
	var timeDelta; // The difference between the browser time and the server time
	var serverDueTime; // The time the test is due
	var timerUpdateInterval;
	var alertCheckInterval;

	// Initializing the time variables and start the timer.
	function runtimer() {
		if (!timerDiv.length) return;

		var dateNow = new Date();
		var browserTime = Math.round(dateNow.getTime() / 1000);
		serverDueTime = timerDiv.data('server-due-time');
		timeDelta = browserTime - timerDiv.data('server-time');

		var remainingTime = serverDueTime - browserTime + timeDelta;

		if (!timerDiv.data('acting')) {
			if (remainingTime < 5)
				// Submit the test if time is expired.
				document.gwquiz.submitAnswers.click();
			else
				// Start the alert check routine
				alertCheckInterval = setInterval(checkAlert, 5000);
		}

		// Start the timer
		if (remainingTime >= 0) {
			timerDiv.text("Remaining time: " + formatTime(remainingTime));
			timerUpdateInterval = setInterval(updateTimer, 1000);
		} else {
			timerDiv.text("Remaining time: 00:00:00");
		}
	}

	// Update the timer
	function updateTimer() {
		var dateNow = new Date();
		var browserTime = Math.round(dateNow.getTime() / 1000);
		var remainingTime = serverDueTime - browserTime + timeDelta;
		if (remainingTime >= 0) {
			timerDiv.text("Remaining time: " + formatTime(remainingTime));
		} else {
			timerDiv.text("Remaining time: 00:00:00");
			clearInterval(timerUpdateInterval);
		}
	}

	function alertDialog(message) {
		// If a previous dialog is still open, then close it first.
		if (alertDialog.msgDialog) alertDialog.msgDialog.modal("hide");
		alertDialog.msgDialog = $('<div class="modal quiz-alert-dialog" tabindex="-1" data-keyboard="true" role="dialog" aria-label="quiz alert dialog">' +
			'<div class="modal-header">' +
			'<button type="button" class="close" data-dismiss="modal" aria-label="close">' +
			'<span aria-hidden="true">&times;</span>' +
			'</button>' +
			'<h3>Test Time Notification</h3>' +
			'</div>' +
			'<div class="modal-body">' + message + '</div>' +
			'<div class="modal-footer"><button type="button" class="btn" data-dismiss="modal" aria-hidden="true">Ok</button></div>' +
			'</div>');
		alertDialog.msgDialog.on('hidden', function() { alertDialog.msgDialog.remove(); delete alertDialog.msgDialog; })
		alertDialog.msgDialog.modal('show');
	}

	// Check to see if we should put up a low time alert.  This also submits the test if
	// time is expired.
	function checkAlert() {
		var dateNow = new Date();
		var browserTime = Math.round(dateNow.getTime() / 1000);
		var timeRemaining = serverDueTime - browserTime + timeDelta;

		if (timeRemaining <= -5) {
			// If a dialog is still open, then close it first or it prevents the form from
			// being submitted.
			if (alertDialog.msgDialog) {
				alertDialog.msgDialog.modal("hide");
				delete alertDialog.msgDialog;
			}
			document.gwquiz.submitAnswers.click();
			clearInterval(alertCheckInterval);
		} else if (timeRemaining <= 0 && timeRemaining > -5) {
			alertDialog('You are out of time!<br>Press "Grade Test" now!');
		} else if (timeRemaining <= 45 && timeRemaining > 40) {
			alertDialog('You have less than 45 seconds left!<br>Press "Grade Test" soon!');
		} else if (timeRemaining <= 90 && timeRemaining > 85) {
			alertDialog("You have less than 90 seconds left to complete<br>" +
				"this assignment. You should finish it soon!");
		}
	}

	// Convert seconds to hh:mm:ss format
	function formatTime(t) {
		// Don't deal with negative times.
		if (t < 0) t = 0;
		var date = new Date(0);
		date.setSeconds(t);
		return date.toISOString().substr(11, 8);
	}

	// Start the test timer.
	setTimeout(runtimer, 500);

	// Scroll to a problem when the problem number link is clicked.
	$(".problem-jump-link").click(
		function(e) {
			var ref = $(this).data("problem-number");
			if (ref) {
				var pn = ref - 1; // we start anchors at 1, not zero
				$('html, body').animate({ scrollTop: $("#prob" + pn).offset().top }, 500);
				$("#prob" + pn).attr('tabIndex', -1).focus();
			}
			e.preventDefault() // Prevent the link from being followed.
		}
	);
});

$(window).on("load", function() {
	// Show achievements if any.
	$('#achievementModal').modal('show');
	// Clear the achievements after 8 seconds.
	setTimeout(function() { $('#achievementModal').modal('hide'); }, 8000);
});
