;;; ement-room.el --- Ement room buffers             -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; EWOC is a great library.  If I had known about it and learned it
;; sooner, it would have saved me a lot of time in other projects.
;; I'm glad I decided to try it for this one.

;;; Code:

;;;; Debugging

(eval-and-compile
  (setq-local warning-minimum-log-level nil)
  (setq-local warning-minimum-log-level :debug))

;;;; Requirements

(require 'color)
(require 'ewoc)
(require 'shr)
(require 'subr-x)

(require 'ement-api)
(require 'ement-macros)
(require 'ement-structs)

;;;; Variables

(defvar-local ement-ewoc nil
  "EWOC for Ement room buffers.")

(defvar-local ement-room nil
  "Ement room for current buffer.")

(defvar-local ement-session nil
  "Ement session for current buffer.")

(defvar-local ement-room-retro-loading nil
  "Non-nil when earlier messages are being loaded.
Used to avoid overlapping requests.")

(defvar-local ement-room-replying-to-event nil
  "When non-nil, the user is replying to this event.
Used by `ement-room-send-message'.")

(defvar-local ement-room-replying-to-overlay nil
  "Used by ement-room-send-reply.")

(declare-function ement-view-room "ement.el")
(declare-function ement-list-rooms "ement.el")
(defvar ement-room-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ement-room-sync)
    (define-key map (kbd "r") #'ement-view-room)
    (define-key map (kbd "R") #'ement-list-rooms)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "v") #'ement-room-view-event)
    (define-key map (kbd "RET") #'ement-room-send-message)
    (define-key map (kbd "S-<return>") #'ement-room-send-reply)
    (define-key map (kbd "<backtab>") #'ement-room-goto-prev)
    (define-key map (kbd "TAB") #'ement-room-goto-next)
    (define-key map [remap scroll-down-command] #'ement-room-scroll-down-command)
    (define-key map [remap mwheel-scroll] #'ement-room-mwheel-scroll)
    map)
  "Keymap for Ement room buffers.")

(defvar ement-room-sender-in-left-margin nil
  "Non-nil when sender is displayed in the left margin.
In that case, sender names are aligned to the margin edge.")

(defvar ement-room-messages-filter
  '((lazy_load_members . t))
  ;; NOTE: The confusing differences between what /sync and /messages
  ;; expect.  See <https://github.com/matrix-org/matrix-doc/issues/706>.
  "Default RoomEventFilter for /messages requests.")

(defvar ement-room-typing-timer nil
  "Timer used to send notifications while typing.")

;; Variables from other files.
(defvar ement-sessions)

;;;; Customization

(defgroup ement-room nil
  "Options for room buffers."
  :group 'ement)

;;;;; Faces

(defface ement-room-name
  '((t (:inherit font-lock-function-name-face)))
  "Room name shown in header line.")

(defface ement-room-membership
  '((t (:inherit font-lock-comment-face)))
  "Membership events (join/part).")

(defface ement-room-reactions
  '((t (:inherit font-lock-comment-face :height 0.9)))
  "Reactions to messages (including the user count).")

(defface ement-room-reactions-key
  '((t (:inherit ement-room-reactions :height 1.5)))
  "Reactions to messages (the key, i.e. the emoji part).
Uses a separate face to allow the key to be shown at a different
size, because in some fonts, emojis are too small relative to
normal text.")

(defface ement-room-timestamp
  '((t (:inherit font-lock-comment-face)))
  "Event timestamps.")

(defface ement-room-user
  '((t (:inherit font-lock-function-name-face :weight bold :overline t)))
  "Usernames.")

(defface ement-room-self
  '((t (:inherit (font-lock-variable-name-face ement-room-user) :weight bold)))
  "Own username.")

(defface ement-room-message
  '((t (:inherit default)))
  "Message bodies.")

(defface ement-room-self-message
  '((t (:inherit (font-lock-variable-name-face ement-room-message))))
  "Oneself's message bodies.")

(defface ement-room-timestamp-header
  '((t (:inherit header-line :weight bold :height 1.1)))
  "Timestamp headers.")

(defface ement-room-mention
  '((t (:inherit highlight)))
  "Messages that mention the local user.")

;;;;; Options

(defcustom ement-room-header-line-format
  ;; TODO: Show in new screenshots.
  '(:eval (concat " " (propertize (ement-room-display-name ement-room)
                                  'face 'ement-room-name)
                  ": " (propertize (ement-room-topic ement-room)
                                   ;; Also set help-echo in case the topic is too wide to fit.
                                   'help-echo (ement-room-topic ement-room))))
  "Header line format for room buffers.
See Info node `(elisp)Header lines'."
  :type 'sexp)
(put 'ement-room-header-line-format 'risky-local-variable t)

(defcustom ement-room-buffer-name-prefix "*Ement Room: "
  "Prefix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-buffer-name-suffix "*"
  "Suffix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-timestamp-format "%H:%M:%S"
  "Format string for event timestamps.
See function `format-time-string'."
  :type '(choice (const "%H:%M:%S")
                 (const "%Y-%m-%d %H:%M:%S")
                 string))

(defcustom ement-room-left-margin-width 0
  "Width of left margin in room buffers."
  :type 'integer)

(defcustom ement-room-right-margin-width (length ement-room-timestamp-format)
  "Width of right margin in room buffers."
  :type 'integer)

(defcustom ement-room-sender-headers t
  "Show sender headers.
Automatically set by setting `ement-room-message-format-spec',
but may be overridden manually."
  :type 'boolean)

(defcustom ement-room-message-format-spec "%B%r%R%t"
  "Format messages according to this spec.
It may contain these specifiers:

  %L  End of left margin
  %R  Start of right margin

  %b  Message body (plain-text)
  %B  Message body (formatted if available)
  %i  Event ID
  %r  Reactions
  %s  Sender ID
  %S  Sender display name
  %t  Event timestamp, formatted according to
      `ement-room-timestamp-format'
  %y  Event type

Note that margin sizes must be set manually with
`ement-room-left-margin-width' and
`ement-room-right-margin-width'."
  :type '(choice (const :tag "IRCy" "%S%L%B%r%R%t")
                 (const :tag "Elemental" "%B%r%R%t")
                 (string :tag "Custom format"))
  :set (lambda (option value)
         (set-default option value)
         (pcase value
           ;; Try to set the margin widths smartly.
           ("%B%r%R%t" ;; "Elemental"
            (setf ement-room-left-margin-width 0
                  ement-room-right-margin-width 8
                  ement-room-sender-headers t))
           ("%S%L%B%r%R%t" ;; "IRCy"
            (setf ement-room-left-margin-width 12
                  ement-room-right-margin-width 8
                  ement-room-sender-headers nil
                  ement-room-sender-in-left-margin t))
           (_ (setf ement-room-left-margin-width
                    (if (string-match-p "%L" value)
                        12 0)
                    ement-room-right-margin-width
                    (if (string-match-p "%R" value)
                        8 0)
                    ement-room-sender-headers
                    (if (string-match-p "%S" value)
                        nil t)
                    ement-room-sender-in-left-margin
                    (if (string-match-p (rx (1+ anything) "%S" (1+ anything) "%L") value)
                        nil t))
              (message "Ement: When using custom message format, setting margin widths may be necessary")))
         (when ement-room-sender-in-left-margin
           ;; HACK: Disable overline on sender face.
           (set-face-attribute 'ement-room-user nil :overline nil))
         (when (and (bound-and-true-p ement-sessions) (car ement-sessions))
           ;; Only display when a session is connected (not sure why `bound-and-true-p'
           ;; is required to avoid compilation warnings).
           (message "Ement: Kill and reopen room buffers to display in new format")))
  :set-after '(ement-room-left-margin-width ement-room-right-margin-width
                                            ement-room-sender-headers)
  ;; This file must be loaded before calling the setter to define the
  ;; `ement-room-user' face used in it.
  :require 'ement-room)

(defcustom ement-room-retro-messages-number 30
  "Number of messages to retrieve when loading earlier messages."
  :type 'integer)

(defcustom ement-room-timestamp-header-format " %H:%M "
  "Format string for timestamp headers where date is unchanged.
See function `format-time-string'.  If this string ends in a
newline, its background color will extend to the end of the
line."
  :type '(choice (const :tag "Time-only" " %H:%M ")
                 (const :tag "Always show date" " %Y-%m-%d %H:%M ")
                 string))

(defcustom ement-room-timestamp-header-with-date-format " %Y-%m-%d (%A) %H:%M\n"
  ;; FIXME: In Emacs 27+, maybe use :extend t instead of adding a newline.
  "Format string for timestamp headers where date changes.
See function `format-time-string'.  If this string ends in a
newline, its background color will extend to the end of the
line."
  :type '(choice (const " %Y-%m-%d (%A) %H:%M\n")
                 string))

(defcustom ement-room-prism 'name
  "Display users' names and messages in unique colors."
  :type '(choice (const :tag "Name only" name)
                 (const :tag "Name and message" both)
                 (const :tag "Neither" nil)))

(defcustom ement-room-username-display-property '(raise -0.25)
  "Display property applied to username strings.
See Info node `(elisp)Other Display Specs'."
  :type '(choice (list :tag "Raise" (const raise :tag "Raise") (number :tag "Factor"))
		 (list :tag "Height" (const height)
		       (choice (list :tag "Larger" (const + :tag "Larger") (number :tag "Steps"))
			       (list :tag "Smaller" (const - :tag "Smaller") (number :tag "Steps"))
			       (number :tag "Factor")
			       (function :tag "Function")
			       (sexp :tag "Form"))) ))

(defcustom ement-room-event-separator-display-property '(space :ascent 50)
  "Display property applied to invisible space string after events.
Allows visual separation between events without, e.g. inserting
newlines.

See Info node `(elisp)Specified Space'."
  :type 'sexp)

(defcustom ement-room-timestamp-header-delta 600
  "Show timestamp header where events are at least this many seconds apart."
  :type 'integer)

(defcustom ement-room-send-typing t
  "Send typing notifications to the server while typing a message."
  :type 'boolean)

;;;; Bookmark support

;; Especially useful with Burly: <https://github.com/alphapapa/burly.el>

(require 'bookmark)

(defun ement-room-bookmark-make-record ()
  "Return a bookmark record for the current `ement-room' buffer."
  (pcase-let* (((cl-struct ement-room (id room-id) canonical-alias display-name) ement-room)
               ((cl-struct ement-session user) ement-session)
               ((cl-struct ement-user (id session-id)) user))
    ;; MAYBE: Support bookmarking specific events in a room.
    (list (concat "Ement room: " display-name " (" canonical-alias ")")
          (cons 'session-id session-id)
          (cons 'room-id room-id)
          (cons 'handler #'ement-room-bookmark-handler))))

(defun ement-room-bookmark-handler (bookmark)
  "Show Ement room buffer for BOOKMARK."
  (pcase-let* ((`(,_name . ,(map session-id room-id)) bookmark))
    (unless (cl-loop for session in ement-sessions
                     thereis (equal session-id (ement-user-id (ement-session-user session))))
      ;; MAYBE: Automatically connect.
      (user-error "Session %s not connected: call `ement-connect' first" session-id))
    ;; FIXME: Support multiple sessions.
    (let ((room (cl-loop for room in (ement-session-rooms (car ement-sessions))
                         when (equal room-id (ement-room-id room))
                         return room)))
      (cl-assert room)
      (ement-view-room (car ement-sessions) room))))

;;;; Commands

(defun ement-room-goto-prev (num)
  "Goto the NUM'th previous message in buffer."
  (interactive "p")
  (ewoc-goto-prev ement-ewoc num))

(defun ement-room-goto-next (num)
  "Goto the NUM'th next message in buffer."
  (interactive "p")
  (ewoc-goto-next ement-ewoc num))

(defun ement-room-scroll-down-command ()
  "Scroll down, and load NUMBER earlier messages when at top."
  (interactive)
  (condition-case _err
      (scroll-down nil)
    (beginning-of-buffer
     (when (call-interactively #'ement-room-retro)
       (message "Loading earlier messages...")))))

(defun ement-room-mwheel-scroll (event)
  "Scroll according to EVENT, loading earlier messages when at top."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (condition-case _err
        (mwheel-scroll event)
      (beginning-of-buffer
       (when (call-interactively #'ement-room-retro)
         (message "Loading earlier messages..."))))))

(defun ement-room-retro (session room number &optional buffer)
  ;; FIXME: Naming things is hard.
  "Retrieve NUMBER older messages in ROOM on SESSION."
  (interactive (list ement-session ement-room
                     (if current-prefix-arg
                         (read-number "Number of messages: ")
                       ement-room-retro-messages-number)
                     (current-buffer)))
  (unless ement-room-retro-loading
    (pcase-let* (((cl-struct ement-session server token) session)
                 ((cl-struct ement-room id prev-batch) room)
                 (endpoint (format "rooms/%s/messages" (url-hexify-string id))))
      (ement-api server token endpoint
        (apply-partially #'ement-room-retro-callback room)
        :timeout 5
        :params (list (list "from" prev-batch)
                      (list "dir" "b")
                      (list "limit" (number-to-string number))
                      (list "filter" (json-encode ement-room-messages-filter)))
        :else (lambda (&rest args)
                (when buffer
                  (with-current-buffer buffer
                    (setf ement-room-retro-loading nil)))
                (signal 'error (format "Ement: loading earlier messages failed (%S)" args))))
      (setf ement-room-retro-loading t))))

(defun ement-room--insert-events (events &optional retro)
  "Insert EVENTS into current buffer.
Calls `ement-room--insert-event' for each event and inserts
timestamp headers into appropriate places while maintaining
point's position.  If RETRO is non-nil, assume EVENTS are earlier
than any existing events, and only insert timestamp headers up to
the previously oldest event."
  (let (buffer-window point-node orig-first-node)
    (when (get-buffer-window (current-buffer))
      ;; HACK: See below.
      (setf buffer-window (get-buffer-window (current-buffer))))
    (when (and buffer-window retro)
      (setf point-node (ewoc-locate ement-ewoc (window-start buffer-window))
            orig-first-node (ewoc-nth ement-ewoc 0)))
    (save-window-excursion
      ;; NOTE: When inserting some events, seemingly only replies, if a different buffer's
      ;; window is selected, and this buffer's window-point is at the bottom, the formatted
      ;; events may be inserted into the wrong place in the buffer, even though they are
      ;; inserted into the EWOC at the right place.  We work around this by selecting the
      ;; buffer's window while inserting events, if it has one.  (I don't know if this is a bug
      ;; in EWOC or in this file somewhere.  But this has been particularly nasty to debug.)
      (when buffer-window
        (select-window buffer-window))
      (cl-loop for event being the elements of events
               ;; TODO: This should be done in a unified interface.
               ;; HACK: Only insert certain types of events.
               when (pcase (ement-event-type event)
                      ("m.reaction" nil)
                      (_ t))
               do (ement-room--insert-event event)))
    ;; Since events can be received in any order, we have to check the whole buffer
    ;; for where to insert new timestamp headers.  (Avoiding that would require
    ;; getting a list of newly inserted nodes and checking each one instead of every
    ;; node in the buffer.  Doing that now would probably be premature optimization,
    ;; though it will likely be necessary if users keep buffers open for busy rooms
    ;; for a long time, as the time to do this in each buffer will increase with the
    ;; number of events.  At least we only do it once per batch of events.)
    (ement-room--insert-ts-headers nil (when retro orig-first-node))
    (when (and buffer-window retro)
      (with-selected-window buffer-window
        (set-window-start nil (ewoc-location point-node))
        ;; TODO: Experiment with this.
        (forward-line -1)))))

(declare-function ement--make-event "ement.el")
(defun ement-room-retro-callback (room data)
  "Push new DATA to ROOM on SESSION and add events to room buffer."
  (pcase-let* (((cl-struct ement-room local) room)
	       ((map _start end chunk state) data)
               ((map buffer) local))
    ;; Put the newly retrieved events at the end of the slots, because they should be
    ;; older events.  But reverse them first, because we're using "dir=b", which the
    ;; spec says causes the events to be returned in reverse-chronological order, and we
    ;; want to process them oldest-first (important because a membership event having a
    ;; user's displayname should be older than a message event sent by the user).
    ;; NOTE: The CHUNK is a vector!  And state should be too, right...?
    (setf chunk (nreverse chunk)
          state (nreverse state))
    (cl-loop for event across-ref state
	     do (setf event (ement--make-event event))
             finally do (setf (ement-room-state room)
                              (append (ement-room-state room) (append state nil))))
    (cl-loop for event across-ref chunk
	     do (setf event (ement--make-event event))
             finally do (setf (ement-room-timeline room)
                              ;; Convert chunk to a list before appending to slot.
                              (append (ement-room-timeline room) (append chunk nil))))
    (when buffer
      (with-current-buffer buffer
        (ement-room--insert-events chunk 'retro)
        (ement-room--process-events chunk)
        (setf (ement-room-prev-batch room) end
              ement-room-retro-loading nil)))))

;; FIXME: What is the best way to do this, with ement--sync being in another file?
(declare-function ement--sync "ement.el")
(defun ement-room-sync (session)
  "Sync SESSION (interactively, current buffer's)."
  (interactive (list ement-session))
  (ement--sync session))

(defun ement-room-view-event (event)
  "Pop up buffer showing details of EVENT (interactively, the one at point)."
  (interactive (list (ewoc-data (ewoc-locate ement-ewoc))))
  (require 'pp)
  (let* ((buffer-name (format "*Ement event: %s*" (ement-event-id event)))
         (event (ement-alist :id (ement-event-id event)
                             :sender (ement-user-id (ement-event-sender event))
                             :content (ement-event-content event)
                             :origin-server-ts (ement-event-origin-server-ts event)
                             :type (ement-event-type event)
                             :unsigned (ement-event-unsigned event))))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (pp event (current-buffer))
      (view-mode)
      (pop-to-buffer (current-buffer)))))

(cl-defun ement-room-send-message (&key (prompt "Send message: "))
  "Send message in current buffer's room."
  (interactive)
  (cl-assert ement-room) (cl-assert ement-session)
  (unwind-protect
      (progn
        (when ement-room-send-typing
          (setf ement-room-typing-timer (run-at-time nil 20 #'ement-room--send-typing ement-session ement-room)))
        (let ((body (read-string prompt)))
          (unless (string-empty-p body)
            (pcase-let* (((cl-struct ement-session server token) ement-session)
                         ((cl-struct ement-room id) ement-room)
                         (endpoint (format "rooms/%s/send/%s/%s" (url-hexify-string id)
                                           "m.room.message" (cl-incf (ement-session-transaction-id ement-session))))
                         (data (ement-alist "msgtype" "m.text"
                                            "body" body)))
              (when ement-room-replying-to-event
                (setf data (ement-room--add-reply data ement-room-replying-to-event)))
              (ement-api server token endpoint
                (lambda (&rest args)
                  (message "SEND MESSAGE CALLBACK: %S" args))
                :data (json-encode data)
                :method 'put)))))
    (when ement-room-send-typing
      (when ement-room-typing-timer
        (cancel-timer ement-room-typing-timer)
        (setf ement-room-typing-timer nil))
      ;; Cancel typing notifications after sending a message.  (The
      ;; spec doesn't say whether this is needed, but it seems to be.)
      (ement-room--send-typing ement-session ement-room :typing nil))))

(cl-defun ement-room--send-typing (session room &key (typing t))
  "Send a typing notification for ROOM on SESSION."
  (pcase-let* (((cl-struct ement-session server token user) session)
               ((cl-struct ement-user (id user-id)) user)
               ((cl-struct ement-room (id room-id)) room)
               (endpoint (format "rooms/%s/typing/%s"
                                 (url-hexify-string room-id) (url-hexify-string user-id)))
               (data (ement-alist "typing" typing "timeout" 15000)))
    (ement-api server token endpoint
      #'ignore ;; We don't really care about the response, I think.
      :data (json-encode data)
      :method 'put)))

(defun ement-room-send-reply ()
  "Send a reply to event at point."
  (interactive)
  (let* ((node (ewoc-locate ement-ewoc))
         (event (ewoc-data node)))
    (unless (and (ement-event-p event)
                 (ement-event-id event))
      (user-error "No event at point"))
    (unwind-protect
        (progn
          (setf ement-room-replying-to-event event
                ement-room-replying-to-overlay
                (make-overlay (ewoc-location node)
                              ;; NOTE: It doesn't seem possible to get the end position of
                              ;; a node, so if there is no next node, we use point-max.
                              ;; But this might break if we were to use an EWOC footer.
                              (if (ewoc-next ement-ewoc node)
                                  (ewoc-location (ewoc-next ement-ewoc node))
                                (point-max))))
          (overlay-put ement-room-replying-to-overlay 'face 'highlight)
          (ement-room-send-message :prompt "Send reply: "))
      (when ement-room-replying-to-overlay
        (delete-overlay ement-room-replying-to-overlay))
      (setf ement-room-replying-to-event nil
            ement-room-replying-to-overlay nil))))

(defun ement-room--add-reply (data replying-to-event)
  "Return DATA adding reply data for EVENT in current buffer's room.
DATA is an unsent message event's data alist."
  ;; SPEC: <https://matrix.org/docs/spec/client_server/r0.6.1#id351> "13.2.2.6.1  Rich replies"
  ;; FIXME: Rename DATA.
  (pcase-let* (((cl-struct ement-event (id replying-to-event-id)
                           content (sender replying-to-sender))
                replying-to-event)
               ((cl-struct ement-user (id replying-to-sender-id)) replying-to-sender)
               ((map ('body replying-to-body) ('formatted_body replying-to-formatted-body)) content)
               (replying-to-sender-name (ement-room--user-display-name replying-to-sender ement-room))
               (quote-string (format "> <%s> %s\n\n" replying-to-sender-name replying-to-body))
               (reply-body (alist-get "body" data nil nil #'string=))
               (reply-body-with-quote (concat quote-string reply-body))
               (reply-formatted-body-with-quote
                (format "<mx-reply>
  <blockquote>
    <a href=\"https://matrix.to/#/%s/%s\">In reply to</a>
    <a href=\"https://matrix.to/#/%s\">%s</a>
    <br />
    %s
  </blockquote>
</mx-reply>
%s"
                        (ement-room-id ement-room) replying-to-event-id replying-to-sender-id replying-to-sender-name
                        ;; TODO: Encode HTML special characters.  Not as straightforward in Emacs as one
                        ;; might hope: there's `web-mode-html-entities' and `org-entities'.  See also
                        ;; <https://emacs.stackexchange.com/questions/8166/encode-non-html-characters-to-html-equivalent>.
                        (or replying-to-formatted-body replying-to-body)
                        reply-body)))
    ;; NOTE: map-elt doesn't work with string keys, so we use `alist-get'.
    (setf (alist-get "body" data nil nil #'string=) reply-body-with-quote
          (alist-get "formatted_body" data nil nil #'string=) reply-formatted-body-with-quote
          data (append (ement-alist "m.relates_to" (ement-alist "m.in_reply_to"
                                                                (ement-alist "event_id" replying-to-event-id))
                                    "format" "org.matrix.custom.html")
                       data))
    data))

;;;; Functions

(define-derived-mode ement-room-mode fundamental-mode "Ement Room"
  "Major mode for Ement room buffers.
This mode initializes a buffer to be used for showing events in
an Ement room.  It kills all local variables, removes overlays,
and erases the buffer."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays)
  (setf buffer-read-only t
        left-margin-width ement-room-left-margin-width
        right-margin-width ement-room-right-margin-width
        ;; TODO: Use EWOC header/footer for, e.g. typing messages.
        ement-ewoc (ewoc-create #'ement-room--pp-thing)))

(defun ement-room--buffer (session room name)
  "Return buffer named NAME showing ROOM's events on SESSION.
If ROOM has no buffer, one is made and stored in the room's local
data slot."
  (or (map-elt (ement-room-local room) 'buffer)
      (let ((new-buffer (get-buffer-create name)))
        (with-current-buffer new-buffer
          (ement-room-mode)
          (setf header-line-format 'ement-room-header-line-format)
          ;; FIXME: Move visual-line-mode to a hook.
          (visual-line-mode 1)
          (setf ement-session session
                ement-room room)
          ;; Track buffer in room's slot.
          (setf (map-elt (ement-room-local ement-room) 'buffer) (current-buffer))
          (add-hook 'kill-buffer-hook
                    (lambda ()
                      (setf (map-elt (ement-room-local ement-room) 'buffer) nil))
                    nil 'local)
          (setq-local bookmark-make-record-function #'ement-room-bookmark-make-record)
          ;; TODO: Some code is duplicated here and in `ement--update-room-buffers'.
          ;; Move new events to the main timeline slot first, because some events can
          ;; refer to other events, and we want them to be found in the timeline slot.
          (setf (ement-room-timeline ement-room) (append (ement-room-timeline* ement-room)
                                                         (ement-room-timeline ement-room))
                (ement-room-timeline* room) nil)
          ;; We don't use `ement-room--insert-events' to avoid extra
          ;; calls to `ement-room--insert-ts-headers'.
          ;; TODO: Unify these event-insertion calls.  Probably use `ement-room--insert-events' here.
          (mapc #'ement-room--insert-event (ement-room-timeline room))
          (ement-room--process-events (ement-room-timeline room))
          (ement-room--insert-ts-headers))
        ;; Return the buffer!
        new-buffer)))

(defun ement-room--user-display-name (user room)
  "Return the displayname for USER in ROOM."
  ;; SPEC: <https://matrix.org/docs/spec/client_server/r0.6.1#calculating-the-display-name-for-a-user>.
  ;; FIXME: Add step 3 of the spec.  For now we skip to step 4.

  ;; NOTE: Both state and timeline events must be searched.  (A helpful user
  ;; in #matrix-dev:matrix.org, Michael (t3chguy), clarified this for me).
  (if-let ((cached-name (gethash room (ement-user-room-display-names user))))
      cached-name
    ;; Put timeline events before state events, because IIUC they should be more recent.
    (if-let* ((displayname (or (cl-loop for event in (ement-room-timeline room)
                                        when (and (equal "m.room.member" (ement-event-type event))
                                                  (equal user (ement-event-sender event))
                                                  (alist-get 'displayname (ement-event-content event)))
                                        return (alist-get 'displayname (ement-event-content event)))
                               (cl-loop for event in (ement-room-state room)
                                        when (and (equal "m.room.member" (ement-event-type event))
                                                  (equal user (ement-event-sender event))
                                                  (alist-get 'displayname (ement-event-content event)))
                                        return (alist-get 'displayname (ement-event-content event)))))
              (calculated-name displayname))
        (puthash room calculated-name (ement-user-room-display-names user))
      ;; No membership state event: use pre-calculated displayname or ID.
      (or (ement-user-displayname user)
          (ement-user-id user)))))

(defun ement-room--event-data (id)
  "Return event struct for event ID in current buffer."
  ;; Search from bottom, most likely to be faster.
  (cl-loop with node = (ewoc-nth ement-ewoc -1)
           while node
           for data = (ewoc-data node)
           when (and (ement-event-p data)
                     (equal id (ement-event-id data)))
           return data
           do (setf node (ewoc-prev ement-ewoc node))))

;;;;; Events

;; Functions to handle types of events.

;; NOTE: At the moment, this only handles "m.typing" ephemeral events.  Message
;; events are handled elsewhere.  A better framework should be designed...
;; TODO: Define other handlers this way.

;; MAYBE: Should we intern these functions?  That means every event
;; handled has to concat and intern.  Should we use lambdas in an
;; alist or hash-table instead?  For now let's use an alist.

(defvar ement-users)

(defvar ement-room-event-fns nil
  "Alist mapping event types to functions which process an event of each type in the room's buffer.")

(defmacro ement-room-defevent (type &rest body)
  "Define an event handling function for events of TYPE.
Around the BODY, the variable `event' is bound to the event being
processed.  The function is called in the room's buffer.  Adds
function to `ement-room-event-fns', which see."
  (declare (indent defun))
  `(setf (alist-get ,type ement-room-event-fns nil nil #'string=)
         (lambda (event)
           ,(concat "`ement-room' handler function for " type " events.")
           ,@body)))

(ement-room-defevent "m.reaction"
  (pcase-let* (((cl-struct ement-event content) event)
               ((map ('m.relates_to relates-to)) content)
               ((map ('event_id related-id) ('rel_type rel-type) _key) relates-to))
    ;; TODO: Handle other rel_types?
    (pcase rel-type
      ("m.annotation"
       ;; Look for related event in timeline.
       (if-let ((related-event (cl-loop for event in (ement-room-timeline ement-room)
                                        when (equal related-id (ement-event-id event))
                                        return event)))
           ;; Found related event: add reaction to local slot and invalidate node.
           (progn
             ;; Every time a room buffer is made, these reaction events are processed again, so we use pushnew to
             ;; avoid duplicates.  (In the future, as event-processing is refactored, this may not be necessary.)
             (cl-pushnew event (map-elt (ement-event-local related-event) 'reactions))
             (ewoc-invalidate ement-ewoc (ement-room--ewoc-last-matching
                                          (lambda (data)
                                            (and (ement-event-p data)
                                                 (equal related-id (ement-event-id data)))))))
         ;; No known related event: discard.
         ;; TODO: Is this the correct thing to do?
         nil)))))

(ement-room-defevent "m.typing"
  (pcase-let* (((cl-struct ement-session user) ement-session)
               ((cl-struct ement-user (id local-user-id)) user)
               ((cl-struct ement-event content) event)
               ((map ('user_ids user-ids)) content)
               (usernames) (footer))
    (setf user-ids (delete local-user-id user-ids))
    (if (zerop (length user-ids))
        (setf footer "")
      (setf usernames (cl-loop for id across user-ids
                               for user = (gethash id ement-users)
                               if user
                               collect (ement-room--user-display-name user ement-room)
                               else collect id)
            footer (propertize (concat "Typing: " (string-join usernames ", "))
                               'face 'font-lock-comment-face)))
    (ewoc-set-hf ement-ewoc "" footer)))

(defun ement-room--process-events (events)
  "Process EVENTS in current buffer.
Uses handlers defined in `ement-room-event-fns'.  The current
buffer should be a room's buffer."
  (cl-loop for event being the elements of events  ;; EVENTS may be a list or array.
           for handler = (alist-get (ement-event-type event) ement-room-event-fns nil nil #'string=)
           when handler
           do (funcall handler event)))

;;;;; EWOC

(defun ement-room--ewoc-next-matching (ewoc node pred)
  "Return the next node in EWOC after NODE that matches PRED."
  ;; MAYBE: Make the next/prev fn an arg.
  (cl-loop do (setf node (ewoc-next ewoc node))
           until (or (null node)
                     (funcall pred (ewoc-data node)))
           finally return node))

(defun ement-room--ewoc-last-matching (predicate)
  "Return the last node in current buffer's EWOC matching PREDICATE.
PREDICATE is called with node's data.  Searches backward from
last node."
  ;; Intended to be like `ewoc-collect', but returning as soon as a match is found.
  (cl-loop with node = (ewoc-nth ement-ewoc -1)
           while node
           when (funcall predicate (ewoc-data node))
           return node
           do (setf node (ewoc-prev ement-ewoc node))))

(defun ement-room--insert-ts-headers (&optional start-node end-node)
  "Insert timestamp headers into current buffer's `ement-ewoc'.
Inserts headers between START-NODE and END-NODE, which default to
the first and last nodes in the buffer, respectively."
  (let* ((ewoc ement-ewoc)
         (end-pos (ewoc-location (or end-node
                                     (ewoc-nth ewoc -1))))
         (node-b (or start-node (ewoc-nth ewoc 0)))
         node-a)
    ;; On the first loop iteration, node-a is set to the first matching
    ;; node after node-b; then its set to the first node after node-a.
    (while (and (setf node-a (ement-room--ewoc-next-matching ewoc (or node-a node-b) #'ement-event-p)
                      node-b (when node-a
                               (ement-room--ewoc-next-matching ewoc node-a #'ement-event-p)))
                (not (or (>= (ewoc-location node-a) end-pos)
                         (>= (ewoc-location node-b) end-pos))))
      (cl-labels ((format-event
                   (event) (format "TS:%S (%s)  Sender:%s  Message:%S"
                                   (/ (ement-event-origin-server-ts (ewoc-data event)) 1000)
                                   (format-time-string "%Y-%m-%d %H:%M:%S"
                                                       (/ (ement-event-origin-server-ts (ewoc-data event)) 1000))
                                   (ement-user-id (ement-event-sender (ewoc-data event)))
                                   (when (alist-get 'body (ement-event-content (ewoc-data event)))
                                     (substring-no-properties
                                      (truncate-string-to-width (alist-get 'body (ement-event-content (ewoc-data event))) 20))))))
        (ement-debug "Comparing event timestamps:"
                     (list 'A (format-event node-a))
                     (list 'B (format-event node-b))))
      ;; NOTE: Matrix timestamps are in milliseconds.
      (let* ((a-ts (/ (ement-event-origin-server-ts (ewoc-data node-a)) 1000))
             (b-ts (/ (ement-event-origin-server-ts (ewoc-data node-b)) 1000))
             (diff-seconds (- b-ts a-ts))
             (ement-room-timestamp-header-format ement-room-timestamp-header-format))
        (when (and (>= diff-seconds ement-room-timestamp-header-delta)
                   (not (when-let ((node-after-a (ewoc-next ewoc node-a)))
                          (pcase (ewoc-data node-after-a)
                            (`(ts . ,_) t)))))
          (unless (equal (time-to-days a-ts) (time-to-days b-ts))
            ;; Different date: bind format to print date.
            (setf ement-room-timestamp-header-format ement-room-timestamp-header-with-date-format))
          (ewoc-enter-after ewoc node-a (list 'ts b-ts)))))))

(defun ement-room--insert-event (event)
  "Insert EVENT into current buffer."
  (cl-labels ((format-event
               (event) (format "TS:%S (%s)  Sender:%s  Message:%S"
                               (/ (ement-event-origin-server-ts event) 1000)
                               (format-time-string "%Y-%m-%d %H:%M:%S"
                                                   (/ (ement-event-origin-server-ts event) 1000))
                               (ement-user-id (ement-event-sender event))
                               (when (alist-get 'body (ement-event-content event))
                                 (substring-no-properties
                                  (truncate-string-to-width (alist-get 'body (ement-event-content event)) 20))))))
    (ement-debug "INSERTING NEW EVENT: " (format-event event))
    (let* ((ewoc ement-ewoc)
           (event< (lambda (a b)
                     "Return non-nil if event A's timestamp is before B's."
                     (< (ement-event-origin-server-ts a)
                        (ement-event-origin-server-ts b))))
           (node-before (ement-room--ewoc-node-before ewoc event event< :pred #'ement-event-p))
           new-node)
      (setf new-node (if (not node-before)
                         (progn
                           (ement-debug "No event before it: add first.")
                           (if-let ((first-node (ewoc-nth ewoc 0)))
                               (progn
                                 (ement-debug "EWOC not empty.")
                                 (if (and (ement-user-p (ewoc-data first-node))
                                          (equal (ement-event-sender event)
                                                 (ewoc-data first-node)))
                                     (progn
                                       (ement-debug "First node is header for this sender: insert after it, instead.")
                                       (setf node-before first-node)
                                       (ewoc-enter-after ewoc first-node event))
                                   (ement-debug "First node is not header for this sender: insert first.")
                                   (ewoc-enter-first ewoc event)))
                             (ement-debug "EWOC empty: add first.")
                             (ewoc-enter-first ewoc event)))
                       (ement-debug "Found event before new event: insert after it.")
                       (when-let ((next-node (ewoc-next ewoc node-before)))
                         (when (and (ement-user-p (ewoc-data next-node))
                                    (equal (ement-event-sender event)
                                           (ewoc-data next-node)))
                           (ement-debug "Next node is header for this sender: insert after it, instead.")
                           (setf node-before next-node)))
                       (ement-debug "Inserting after event: " (format-event (ewoc-data node-before)))
                       (ewoc-enter-after ewoc node-before event)))
      ;; Insert sender where necessary.
      (when ement-room-sender-headers
        ;; TODO: Do this more flexibly.
        (if (not node-before)
            (progn
              (ement-debug "No event before: Add sender before new node.")
              (ewoc-enter-before ewoc new-node (ement-event-sender event)))
          (ement-debug "Event before: compare sender.")
          (if (equal (ement-event-sender event)
                     (pcase-exhaustive (ewoc-data node-before)
                       ((pred ement-event-p)
                        (ement-event-sender (ewoc-data node-before)))
                       ((pred ement-user-p)
                        (ewoc-data node-before))
                       (`(ts ,(pred numberp))
                        ;; Timestamp header.
                        (when-let ((node-before-ts (ewoc-prev ewoc node-before)))
                          ;; FIXME: Well this is ugly.  Make a filter predicate or something.
                          (pcase-exhaustive (ewoc-data node-before-ts)
                            ((pred ement-event-p)
                             (ement-event-sender (ewoc-data node-before)))
                            ((pred ement-user-p)
                             (ewoc-data node-before)))))))
              (ement-debug "Same sender.")
            (ement-debug "Different sender: insert new sender node.")
            (ewoc-enter-before ewoc new-node (ement-event-sender event))
            (when-let* ((next-node (ewoc-next ewoc new-node)))
              (when (ement-event-p (ewoc-data next-node))
                (ement-debug "Event after from different sender: insert its sender before it.")
                (ewoc-enter-before ewoc next-node (ement-event-sender (ewoc-data next-node)))))))))))

(cl-defun ement-room--ewoc-node-before (ewoc data <-fn
                                             &key (from 'last) (pred #'identity))
  "Return node in EWOC that matches PRED and belongs before DATA according to COMPARATOR."
  (cl-assert (member from '(first last)))
  (if (null (ewoc-nth ewoc 0))
      (ement-debug "EWOC is empty: returning nil.")
    (ement-debug "EWOC has data: add at appropriate place.")
    (cl-labels ((next-matching
                 (ewoc node next-fn pred) (cl-loop do (setf node (funcall next-fn ewoc node))
                                                   until (or (null node)
                                                             (funcall pred (ewoc-data node)))
                                                   finally return node)))
      (let* ((next-fn (pcase from ('first #'ewoc-next) ('last #'ewoc-prev)))
             (start-node (ewoc-nth ewoc (pcase from ('first 0) ('last -1)))))
        (unless (funcall pred (ewoc-data start-node))
          (setf start-node (next-matching ewoc start-node next-fn pred)))
        (if (funcall <-fn (ewoc-data start-node) data)
            (progn
              (ement-debug "New data goes before start node.")
              start-node)
          (ement-debug "New data goes after start node: find node before new data.")
          (let ((compare-node start-node))
            (cl-loop while (setf compare-node (next-matching ewoc compare-node next-fn pred))
                     until (funcall <-fn (ewoc-data compare-node) data)
                     finally return (if compare-node
                                        (progn
                                          (ement-debug "Found place: enter there.")
                                          compare-node)
                                      (ement-debug "Reached end of collection: insert there.")
                                      (pcase from
                                        ('first (ewoc-nth ewoc -1))
                                        ('last nil))))))))))

;;;;; Formatting

(defun ement-room--pp-thing (thing)
  "Pretty-print THING.
To be used as the pretty-printer for `ewoc-create'.  THING may be
an `ement-event' or `ement-user' struct, or a list like `(ts
TIMESTAMP)', where TIMESTAMP is a Unix timestamp number of
seconds."
  (pcase-exhaustive thing
    ((pred ement-event-p)
     (insert "" (ement-room--format-event thing)))
    ((pred ement-user-p)
     (insert (propertize (ement-room--format-user thing)
                         'display ement-room-username-display-property)))
    (`(ts ,(and (pred numberp) ts)) ;; Insert a date header.
     (insert
      (if (equal ement-room-timestamp-header-format ement-room-timestamp-header-with-date-format)
          ;; HACK: Rather than using another variable, compare the format strings to
          ;; determine whether the date is changing: if so, add a newline before the header.
          "\n"
        "")
      (propertize (format-time-string ement-room-timestamp-header-format ts)
                  'face 'ement-room-timestamp-header)))))

;; (defun ement-room--format-event (event)
;;   "Format `ement-event' EVENT."
;;   (pcase-let* (((cl-struct ement-event sender type content origin-server-ts) event)
;;                ((map body format ('formatted_body formatted-body)) content)
;;                (ts (/ origin-server-ts 1000)) ; Matrix timestamps are in milliseconds.
;;                (body (if (not formatted-body)
;;                          body
;;                        (pcase format
;;                          ("org.matrix.custom.html"
;;                           (ement-room--render-html formatted-body))
;;                          (_ (format "[unknown formatted-body format: %s] %s" format body)))))
;;                (timestamp (propertize
;;                            " " 'display `((margin left-margin)
;;                                           ,(propertize (format-time-string ement-room-timestamp-format ts)
;;                                                        'face 'ement-room-timestamp))))
;;                (body-face (pcase type
;;                             ("m.room.member" 'ement-room-membership)
;;                             (_ (if (equal (ement-user-id sender)
;;                                           (ement-user-id (ement-session-user ement-session)))
;; 				   'ement-room-self-message 'default))))
;;                (string (pcase type
;;                          ("m.room.message" body)
;;                          ("m.room.member" "")
;;                          (_ (format "[unknown event-type: %s] %s" type body)))))
;;     (add-face-text-property 0 (length body) body-face 'append body)
;;     (prog1 (concat timestamp string)
;;       ;; Hacky or elegant?  We return the string, but for certain event
;;       ;; types, we also insert a widget (this function is called by
;;       ;; EWOC with point at the insertion position).  Seems to work...
;;       (pcase type
;;         ("m.room.member"
;;          (widget-create 'ement-room-membership
;; 			:button-face 'ement-room-membership
;;                         :value (list (alist-get 'membership content))))))))

(defun ement-room--format-event (event)
  "Return EVENT formatted according to `ement-room-message-format-spec'."
  (concat (pcase (ement-event-type event)
            ("m.room.message" (ement-room--format-message event))
            ("m.room.member"
             (widget-create 'ement-room-membership
                            :button-face 'ement-room-membership
                            :value event)
             "")
            ("m.reaction"
             ;; Handled by defevent-based handler.
             "")
            (_ (propertize (format "[sender:%s type:%s]"
                                   (ement-user-id (ement-event-sender event))
                                   (ement-event-type event))
                           'help-echo (format "%S" event))))
          (propertize " "
                      'display ement-room-event-separator-display-property)))



(defun ement-room--format-reactions (event)
  "Return formatted reactions to EVENT."
  ;; TODO: Like other events, pop to a buffer showing the raw reaction events when a key is pressed.
  (if-let ((reactions (map-elt (ement-event-local event) 'reactions)))
      (cl-labels ((format-reaction
                   (ks) (pcase-let* ((`(,key . ,senders) ks)
                                     (key (propertize key 'face 'ement-room-reactions-key))
                                     (count (propertize (format "(%s)" (length senders))
                                                        'face 'ement-room-reactions)))
                          (propertize (concat key " " count)
                                      'help-echo (lambda (_window buffer _pos)
                                                   (senders-names senders (buffer-local-value 'ement-room buffer))))))
                  (senders-names
                   (senders room) (cl-loop for sender in senders
                                           collect (ement-room--user-display-name sender room)
                                           into names
                                           finally return (string-join names ", "))))
        (cl-loop with keys-senders
                 for reaction in reactions
                 for key = (map-nested-elt (ement-event-content reaction) '(m.relates_to key))
                 for sender = (ement-event-sender reaction)
                 do (push sender (alist-get key keys-senders nil nil #'string=))
                 finally return (concat "\n  " (string-join (mapcar #'format-reaction keys-senders) "  "))))
    ""))

(cl-defun ement-room--format-message (event &optional (format ement-room-message-format-spec))
  "Return EVENT formatted according to FORMAT.
Format defaults to `ement-room-message-format-spec', which see."
  (cl-macrolet ((defspecs (&rest specs)
                  `(list ,@(cl-loop for (char form) in specs
                                    collect `(cons ,char (lambda (event) ,form)))))
                (body-face
                 () `(cond ((equal (ement-user-id sender)
                                   (ement-user-id (ement-session-user ement-session)))
                            'ement-room-self-message)
                           ((eq 'both ement-room-prism)
                            (list :inherit (if (ement-room--event-mentions-user event (ement-session-user ement-session))
                                               'ement-room-mention
                                             'ement-room-message)
                                  :foreground (or (ement-user-color sender)
                                                  (setf (ement-user-color sender)
                                                        (ement-room--user-color sender)))))
                           (t (if (ement-room--event-mentions-user event (ement-session-user ement-session))
                                  'ement-room-mention
                                'ement-room-message)))))
    (let* ((room-buffer (current-buffer))
           (margin-p)
           (specs (defspecs
                    ;; NOTE: When adding specs, also add them to docstring
                    ;; for `ement-room-message-format-spec'.
                    (?L (progn (ignore event) (setf margin-p t) (propertize " " 'left-margin-end t)))
                    (?R (progn (ignore event) (setf margin-p t) (propertize " " 'right-margin-start t)))
                    ;; HACK: Reads `ement-session' from current buffer.
                    (?b (pcase-let*
                            (((cl-struct ement-event content sender) event)
                             ((map body) content))
                          (propertize body 'face (body-face))))
                    (?B (pcase-let*
                            (((cl-struct ement-event content sender) event)
                             ((map body ('format content-format) ('formatted_body formatted-body)) content)
                             (body (if (not formatted-body)
                                       ;; Copy the string so as not to add face properties to the one in the struct.
                                       (copy-sequence body)
                                     (pcase content-format
                                       ("org.matrix.custom.html"
                                        (save-match-data
                                          (ement-room--render-html formatted-body)))
                                       (_ (format "[unknown body format: %s] %s"
                                                  content-format body))))))
                          (add-face-text-property 0 (length body) (body-face) 'append body)
                          body))
                    (?i (ement-event-id event))
                    (?s (propertize (ement-user-id (ement-event-sender event))
                                    'face 'ement-room-user))
                    (?S (let ((sender (ement-room--format-user (ement-event-sender event) ement-room)))
                          (when (and ement-room-sender-in-left-margin
                                     (< (string-width sender) ement-room-left-margin-width))
                            ;; Using :align-to or :width space display properties doesn't
                            ;; seem to have any effect in the margin, so we make a string.
                            (setf sender (concat (make-string (- ement-room-left-margin-width (string-width sender))
                                                              ? )
                                                 sender)))
                          ;; NOTE: I'd like to add a help-echo function to display the sender ID, but the Emacs
                          ;; manual says that there is currently no way to make text in the margins mouse-sensitive.
                          ;; So `ement-room--format-user' returns a string propertized with `help-echo' as a string.
                          sender))
                    (?r (ement-room--format-reactions event))
                    (?t (propertize (format-time-string ement-room-timestamp-format
                                                        ;; Timestamps are in milliseconds.
                                                        (/ (ement-event-origin-server-ts event) 1000))
                                    'face 'ement-room-timestamp
                                    'help-echo (format-time-string
                                                "%Y-%m-%d %H:%M:%S" (/ (ement-event-origin-server-ts event) 1000))))
                    (?y (ement-event-type event)))))
      ;; Copied from `format-spec'.
      (with-temp-buffer
        ;; Pretend this is a room buffer.
        (setf ement-session (buffer-local-value 'ement-session room-buffer)
              ement-room (buffer-local-value 'ement-room room-buffer))
        (insert format)
        (goto-char (point-min))
        (while (search-forward "%" nil t)
          (cond
           ;; Quoted percent sign.
           ((eq (char-after) ?%)
            (delete-char 1))
           ;; Valid format spec.
           ((looking-at "\\([-0-9.]*\\)\\([a-zA-Z]\\)")
            (let* ((num (match-string 1))
                   (spec (string-to-char (match-string 2)))
                   (fn (or (alist-get spec specs)
                           (error "Invalid format character: `%%%c'" spec)))
                   (val (or (funcall fn event)
                            (let ((print-level 1))
                              (propertize (format "[Event has no value for spec \"?%s\"]" (char-to-string spec))
                                          'face 'font-lock-comment-face
                                          'help-echo (format "%S" event))))))
              ;; (setq val (cdr val))
              ;; Pad result to desired length.
              (let ((text (format (concat "%" num "s") val)))
                ;; Insert first, to preserve text properties.
                ;; (insert-and-inherit text)
                ;; ;;  Delete the specifier body.
                ;; (delete-region (+ (match-beginning 0) (string-width text))
                ;;                (+ (match-end 0) (string-width text)))
                ;; ;; Delete the percent sign.
                ;; (delete-region (1- (match-beginning 0)) (match-beginning 0))

                ;; NOTE: Actually, delete the specifier first, because it seems that if
                ;; `text' is multiline, the specifier body does not get deleted that way.
                ;; (Not sure if preserving the text properties is needed for this use case.
                ;; Leaving the old code commented in case there's a better solution.)
                (delete-region (1- (match-beginning 0)) (match-end 0))
                (insert text))))
           ;; Signal an error on bogus format strings.
           (t
            (error "Invalid format string"))))
        ;; Propertize margin text.
        (when margin-p
          (when-let ((left-margin-end (next-single-property-change (point-min) 'left-margin-end)))
            (goto-char left-margin-end)
            (delete-char 1)
            (put-text-property (point-min) (point)
                               'display `((margin left-margin)
                                          ,(buffer-substring (point-min) (point)))))
          (when-let ((right-margin-start (next-single-property-change (point-min) 'right-margin-start)))
            (goto-char right-margin-start)
            (delete-char 1)
            (let ((string (buffer-substring (point) (point-max))))
              ;; Relocate its text to the beginning so it won't be
              ;; displayed at the last line of wrapped messages.
              (delete-region (point) (point-max))
              (goto-char (point-min))
              (insert-and-inherit
               (propertize " "
                           'display `((margin right-margin) ,string))))))
        (buffer-string)))))

(defun ement-room--render-html (string)
  "Return rendered version of HTML STRING.
HTML is rendered to Emacs text using `shr-insert-document'."
  (with-temp-buffer
    (insert string)
    (save-excursion
      ;; NOTE: We workaround `shr`'s not indenting the blockquote properly (it
      ;; doesn't seem to compensate for the margin).  I don't know exactly how
      ;; `shr-tag-blockquote' and `shr-mark-fill' and `shr-fill-line' and
      ;; `shr-indentation' work together, but through trial-and-error, this
      ;; seems to work.  It even seems to work properly when a window is
      ;; resized (i.e. the wrapping is adjusted automatically by redisplay
      ;; rather than requiring the message to be re-rendered to HTML).
      (let ((old-fn (symbol-function 'shr-tag-blockquote))) ;; Bind to a var to avoid unknown-function linting errors.
        (cl-letf (((symbol-function 'shr-fill-line) #'ignore)
                  ((symbol-function 'shr-tag-blockquote)
                   (lambda (dom)
                     (let ((beg (point-marker)))
                       (funcall old-fn dom)
                       (add-text-properties beg (point-max)
                                            '(wrap-prefix "    "
                                                          line-prefix "    "))))))
          (shr-insert-document
           (libxml-parse-html-region (point-min) (point-max))))))
    (string-trim (buffer-substring (point) (point-max)))))

(cl-defun ement-room--format-user (user &optional (room ement-room))
  "Format `ement-user' USER for ROOM.
ROOM defaults to the value of `ement-room'."
  (let ((face (cond ((equal (ement-user-id (ement-session-user ement-session))
                            (ement-user-id user))
                     'ement-room-self)
                    (ement-room-prism
                     `(:inherit ement-room-user :foreground ,(or (ement-user-color user)
                                                                 (setf (ement-user-color user)
                                                                       (ement-room--user-color user)))))
                    (t 'ement-room-user))))
    ;; FIXME: If a membership state event has not yet been received, this
    ;; sets the display name in the room to the user ID, and that prevents
    ;; the display name from being used if the state event arrives later.
    (propertize (ement-room--user-display-name user room)
                'face face
                'help-echo (ement-user-id user))))

(defun ement-room--event-mentions-user (event user)
  "Return non-nil if EVENT mentions USER."
  (pcase-let* (((cl-struct ement-event content) event)
               ((map body formatted_body) content)
               (body (or formatted_body body)))
    ;; FIXME: `ement-room--user-display-name' may not be returning the
    ;; right result for the local user, so test the displayname slot too.
    ;; HACK: So we use the username slot, which was created just for this, for now.
    (or (string-match-p (regexp-quote (ement-user-username user))
                        body)
        (string-match-p (regexp-quote (ement-room--user-display-name user ement-room))
                        body)
        (string-match-p (regexp-quote (ement-user-id user))
                        body))))

;; NOTE: This function is not useful when displaynames are shown in the margin, because
;; margins are not mouse-interactive in Emacs, therefore the help-echo function is called
;; with the string and the position in the string, which leaves the buffer position
;; unknown.  So we have to set the help-echo to a string rather than a function.  But the
;; function may be useful in the future, so leaving it commented for now.

;; (defun ement-room--user-help-echo (window _object pos)
;;   "Return user ID string for POS in WINDOW.
;; For use as a `help-echo' function on `ement-user' headings."
;;   (let ((data (with-selected-window window
;;                 (ewoc-data (ewoc-locate ement-ewoc pos)))))
;;     (cl-typecase data
;;       (ement-event (ement-user-id (ement-event-sender data)))
;;       (ement-user (ement-user-id data)))))

(defun ement-room--user-color (user)
  "Return a color in which to display USER's messages."
  (cl-labels ((relative-luminance
               ;; Copy of `modus-themes-wcag-formula', an elegant
               ;; implementation by Protesilaos Stavrou.  Also see
               ;; <https://en.wikipedia.org/wiki/Relative_luminance> and
               ;; <https://www.w3.org/TR/WCAG20/#relativeluminancedef>.
               (rgb) (cl-loop for k in '(0.2126 0.7152 0.0722)
                              for x in rgb
                              sum (* k (if (<= x 0.03928)
                                           (/ x 12.92)
                                         (expt (/ (+ x 0.055) 1.055) 2.4)))))
              (contrast-ratio
               ;; Copy of `modus-themes-contrast'; see above.
               (a b) (let ((ct (/ (+ (relative-luminance a) 0.05)
                                  (+ (relative-luminance b) 0.05))))
                       (max ct (/ ct)))))
    (let* ((id (ement-user-id user))
           (id-hash (float (abs (sxhash id))))
           ;; TODO: Wrap-around the value to get the color I want.
           (ratio (/ id-hash (float most-positive-fixnum)))
           (color-num (round (* (* 255 255 255) ratio)))
           (color-rgb (list (/ (float (logand color-num 255)) 255)
                            (/ (float (lsh (logand color-num 65280) -8)) 255)
                            (/ (float (lsh (logand color-num 16711680) -16)) 255)))
           (background-rgb (color-name-to-rgb (face-background 'default))))
      (if (< (contrast-ratio color-rgb background-rgb) 3)
          (progn
            ;; Contrast ratio too low: I don't know the best way to fix this,
            ;; but using the complement seems to produce decent results.
            ;; FIXME: Calculate and apply an adjustment instead.
            (apply #'color-rgb-to-hex
                   (append (color-complement (apply #'color-rgb-to-hex
                                                    (append color-rgb (list 2))))
                           (list 2))))
        (apply #'color-rgb-to-hex (append color-rgb (list 2)))))))

;;;;; Widgets

(require 'widget)

(defun ement-room--membership-help-echo (window _object pos)
  "Return membership event string for POS in WINDOW.
For use as a `help-echo' function on `ement-user' headings."
  (with-selected-window window
    (format "%S" (ement-event-content (ewoc-data (ewoc-locate ement-ewoc pos))))))

;; (defun ement-room--membership-help-echo (widget)
;;   "Return membership event string for WIDGET."
;;   (format "%S" (ement-event-content (widget-value widget))))

(define-widget 'ement-room-membership 'item
  "Widget for membership events."
  :format "%{ %v %}"
  :sample-face 'ement-room-membership
  ;; FIXME: Using the :help-echo property on the widget doesn't seem to work, seemingly something to do with the widget
  ;; hierarchy (using `widget-forward' says "No buttons or fields found"), so we use 'help-echo on the string for now.
  ;;  :help-echo #'ement-room--membership-help-echo
  :value-create (lambda (widget)
                  (pcase-let* ((event (widget-value widget))
                               ((cl-struct ement-event sender content) event)
                               ((map membership) content)
                               (displayname (ement-room--user-display-name sender ement-room))
                               (string (concat membership " (" displayname ")")))
                    (insert (propertize string
                                        'help-echo #'ement-room--membership-help-echo)))))

;;;; Footer

(provide 'ement-room)

;;; ement-room.el ends here
