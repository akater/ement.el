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
    (define-key map (kbd "<backtab>") #'ement-room-goto-prev)
    (define-key map (kbd "TAB") #'ement-room-goto-next)
    (define-key map [remap scroll-down-command] #'ement-room-scroll-down-command)
    (define-key map [remap mwheel-scroll] #'ement-room-mwheel-scroll)
    map)
  "Keymap for Ement room buffers.")

;;;; Customization

(defgroup ement-room nil
  "Options for room buffers."
  :group 'ement)

(defcustom ement-room-buffer-name-prefix "*Ement Room: "
  "Prefix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-buffer-name-suffix "*"
  "Suffix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-message-format-spec "%B%R%t"
  "Format messages according to this spec.
It may contain these specifiers:

  %L  End of left margin
  %R  Start of right margin

  %b  Message body (plain-text)
  %B  Message body (formatted if available)
  %i  Event ID
  %s  Sender ID
  %S  Sender display name
  %t  Event timestamp, formatted according to
      `ement-room-timestamp-format'
  %y  Event type

Note that margin sizes must be set manually with
`ement-room-left-margin-width' and
`ement-room-right-margin-width'."
  :type 'string)

(defcustom ement-room-retro-messages-number 30
  "Number of messages to retrieve when loading earlier messages."
  :type 'integer)

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

(defcustom ement-room-timestamp-header-delta 600
  "Show timestamp header where events are at least this many seconds apart."
  :type 'integer)

;;;;; Faces

(defface ement-room-membership
  '((t (:inherit font-lock-comment-face)))
  "Membership events (join/part).")

(defface ement-room-timestamp
  '((t (:inherit font-lock-comment-face)))
  "Event timestamps.")

(defface ement-room-user
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Usernames.")

(defface ement-room-self
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Own username.")

(defface ement-room-self-message
  '((t (:inherit font-lock-variable-name-face)))
  "Own messages.")

(defface ement-room-timestamp-header
  '((t (:inherit header-line :weight bold)))
  "Timestamp headers.")

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

(defvar ement-default-sync-filter)
(defun ement-room-retro (session room number &optional buffer)
  ;; FIXME: Naming things is hard.
  ;; SPEC: <https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-rooms-roomid-messages>.
  "Retrieve NUMBER older messages in ROOM on SESSION."
  (interactive (list ement-session ement-room
                     (if current-prefix-arg
                         (read-number "Number of messages: ")
                       ement-room-retro-messages-number)
                     (current-buffer)))
  (unless ement-room-retro-loading
    (pcase-let* (((cl-struct ement-session server token) session)
                 ((cl-struct ement-room id prev-batch) room)
                 (endpoint (format "rooms/%s/messages" (url-hexify-string id)))
                 (filter ;; (cl-copy-list ement-default-sync-filter)
                  '((room (timeline (lazy_load_members . t)
                                    (include_redundant_members . t))))
                  ))
      ;; (setf (alist-get 'include_redundant_members
      ;;                  (alist-get 'state
      ;;                             (alist-get 'room filter)))
      ;;       t
      ;;       (alist-get 'include_redundant_members
      ;;                  (alist-get 'timeline
      ;;                             (alist-get 'room filter)))
      ;;       t)
      (ement-api server token endpoint
        (apply-partially #'ement-room-retro-callback room)
        :timeout 5
        :params (list (list "from" prev-batch)
                      (list "dir" "b")
                      (list "limit" (number-to-string number))
                      (list "filter" (json-encode filter)))
        :else (lambda (&rest args)
                (signal 'ement-api-error
                        (format "Ement: loading earlier messages failed (%S)" args)))
        :finally (when buffer
                   (lambda ()
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (setf ement-room-retro-loading nil))))))
      (setf ement-room-retro-loading t))))

(declare-function ement--make-event "ement.el")
(defun ement-room-retro-callback (room data)
  "Push new DATA to ROOM on SESSION and add events to room buffer."
  (pcase-let* (((cl-struct ement-room) room)
	       ((map _start end state chunk) data)
	       (buffer (cl-loop for buffer in (buffer-list)
				when (equal room (buffer-local-value 'ement-room buffer))
				return buffer))
               (window) (point-node) (orig-first-node))
    ;; FIXME: These are pushed onto the front of the lists.  Doesn't
    ;; really matter, but maybe better to put them at the other end.

    ;; NOTE: It appears that, contrary to the spec, the state
    ;; parameter is always missing, and the events it should have are
    ;; actually in the chunk parameter.  Commenting this out for now.
    (cl-loop for event across state
             ;; FIXME: Need to use make-event
             do (push event (ement-room-state room)))
    (cl-loop for event across-ref chunk
             ;; NOTE: This uses across-ref and setf as an optimization so the chunk vector can be
             ;; reused to insert the events into the buffer (otherwise, it would have to push the
             ;; events to the timeline* slot first and then move them to the timeslot afterward).
	     do (setf event (ement--make-event event))
             (ement-debug "Pushing chunk event" event)
	     (push event (ement-room-timeline room)))
    ;; Append apparent RoomStateEvents to the state slot as well.
    ;; MAYBE: Don't also push them to the timeline slot.
    (cl-loop for event across chunk
             unless (equal "m.room.message" (ement-event-type event))
	     do (display-warning 'ement "Non-message event in chunk: %S" event)
             and collect event into state-events
             finally do (setf (ement-room-state room)
                              (append (ement-room-state room)
                                      (nreverse state-events))))
    (when buffer
      (with-current-buffer buffer
        (setf window (get-buffer-window buffer)
              point-node (when window
                           (with-selected-window window
                             (ewoc-locate ement-ewoc (window-start))))
              orig-first-node (ewoc-nth ement-ewoc 0))
	(cl-loop for event across chunk
                 do (ement-room--insert-event event))
        ;; Insert timestamp headers up to the original first node.
        (ement-room--insert-ts-headers nil orig-first-node)
        (with-selected-window (get-buffer-window buffer)
          (set-window-start nil (ewoc-location point-node))
          ;; FIXME: Experiment with this.
          (forward-line -1))
        (setf (ement-room-prev-batch room) end)))))

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

(defun ement-room-send-message ()
  "Send message in current buffer's room."
  (interactive)
  (cl-assert ement-room) (cl-assert ement-session)
  (let ((body (read-string "Send message: ")))
    (unless (string-empty-p body)
      (pcase-let* (((cl-struct ement-session server token) ement-session)
                   ((cl-struct ement-room id) ement-room)
                   (endpoint (format "rooms/%s/send/%s/%s" (url-hexify-string id)
				     "m.room.message" (cl-incf (ement-session-transaction-id ement-session))))
		   (json-string (json-encode (ement-alist "msgtype" "m.text"
							  "body" body))))
        (ement-api server token endpoint
          (lambda (&rest args)
            (message "SEND MESSAGE CALLBACK: %S" args))
	  :data json-string
          :method 'put)))))

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
  "Return a buffer named NAME showing ROOM's events on SESSION."
  (or (get-buffer name)
      (with-current-buffer (get-buffer-create name)
        (ement-room-mode)
        ;; FIXME: Move visual-line-mode to a hook.
        (visual-line-mode 1)
        (setf ement-session session
              ement-room room)
        (mapc #'ement-room--insert-event (ement-room-timeline room))
        (mapc #'ement-room--insert-event (ement-room-timeline* room))
        ;; Move new events to main list.
        (setf (ement-room-timeline room) (append (ement-room-timeline* room) (ement-room-timeline room))
              (ement-room-timeline* room) nil)
        ;; Insert timestamp headers.
        (ement-room--insert-ts-headers)
        ;; Return the buffer!
        (current-buffer))))

(defun ement-room--user-display-name (user room)
  "Return the displayname for USER in ROOM."
  ;; SPEC: <https://matrix.org/docs/spec/client_server/r0.6.1#calculating-the-display-name-for-a-user>.
  (if-let ((member-state-event (cl-loop for event in (ement-room-state room)
                                        when (and (equal "m.room.member" (ement-event-type event))
                                                  (equal user (ement-event-sender event)))
                                        return event)))
      (or (alist-get 'displayname (ement-event-content member-state-event))
          ;; FIXME: Add step 3 of the spec.  For now we skip to step 4.
          ;; No displayname given: use raw user ID.
          (ement-user-id user))
    ;; No membership state event: use pre-calculated displayname or ID.
    (or (ement-user-displayname user)
        (ement-user-id user))))

;;;;; EWOC

(defun ement-room--ewoc-next-matching (ewoc node pred)
  "Return the next node in EWOC after NODE that matches PRED."
  ;; MAYBE: Make the next/prev fn an arg.
  (cl-loop do (setf node (ewoc-next ewoc node))
           until (or (null node)
                     (funcall pred (ewoc-data node)))
           finally return node))

(defun ement-room--insert-ts-headers (&optional start-node end-node)
  "Insert timestamp headers into current buffer's `ement-ewoc' between START-NODE and END-NODE.
START-NODE and END-NODE default to the first and last nodes in
the buffer."
  (let* ((ewoc ement-ewoc)
         (end-pos (ewoc-location (or end-node
                                     (ewoc-nth ewoc -1))))
         (node-b (or start-node (ewoc-nth ewoc 0)))
         node-a)
    (while (and (setf node-a (ement-room--ewoc-next-matching ewoc node-b #'ement-event-p)
                      node-b (when node-a
                               (ement-room--ewoc-next-matching ewoc node-a #'ement-event-p)))
                (not (or (>= (ewoc-location node-a) end-pos)
                         (>= (ewoc-location node-b) end-pos))))
      ;; NOTE: Matrix timestamps are in milliseconds.
      (let* ((a-ts (/ (ement-event-origin-server-ts (ewoc-data node-a)) 1000))
             (b-ts (/ (ement-event-origin-server-ts (ewoc-data node-b)) 1000))
             (diff-seconds (- b-ts a-ts)))
        (when (and (>= diff-seconds ement-room-timestamp-header-delta)
                   (not (when-let ((node-after-a (ewoc-next ewoc node-a)))
                          (pcase (ewoc-data node-after-a)
                            (`(ts) t)))))
          (ewoc-enter-after ewoc node-a
                            (list 'ts b-ts)))))))

(defun ement-room--insert-event (event)
  "Insert EVENT into current buffer."
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
                     (ewoc-enter-after ewoc node-before event)))
    ;; Insert sender where necessary.
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
            (ewoc-enter-before ewoc next-node (ement-event-sender (ewoc-data next-node)))))))))

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
     (insert "\n" (propertize (format-time-string " %H:%M\n" ts)
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
  (pcase (ement-event-type event)
    ("m.room.message" (ement-room--format-message event))
    ("m.room.member"
     (widget-create 'ement-room-membership
                    :button-face 'ement-room-membership
                    :value (list (alist-get 'membership (ement-event-content event))))
     "")
    (_ (format "[sender:%s type:%s]"
               (ement-user-id (ement-event-sender event))
               (ement-event-type event)))))

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
                            (list :inherit 'default
                                  :foreground (or (ement-user-color sender)
                                                  (setf (ement-user-color sender)
                                                        (ement-room--user-color sender)))))
                           (t 'default))))
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
                             ((map body) content)
                             (body-face (body-face)))
                          (add-face-text-property 0 (length body) body-face 'append body)
                          body))
                    (?B (pcase-let*
                            (((cl-struct ement-event content sender) event)
                             ((map body ('format content-format) ('formatted_body formatted-body)) content)
                             (body-face (body-face))
                             (body (if (not formatted-body)
                                       body
                                     (pcase content-format
                                       ("org.matrix.custom.html"
                                        (save-match-data
                                          (ement-room--render-html formatted-body)))
                                       (_ (format "[unknown body format: %s] %s"
                                                  content-format body))))))
                          (add-face-text-property 0 (length body) body-face 'append body)
                          body))
                    (?i (ement-event-id event))
                    (?s (propertize (ement-user-id (ement-event-sender event))
                                    'face 'ement-room-user))
                    (?S (ement-room--format-user (ement-event-sender event) ement-room))
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
                   (val (funcall fn event)))
              (unless val
                (error "Event has no value for spec %s: %S" spec event))
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
      (cl-letf (((symbol-function 'shr-fill-line) #'ignore))
        (shr-insert-document
         (libxml-parse-html-region (point-min) (point-max)))))
    (string-trim (buffer-substring (point) (point-max)))))

(cl-defun ement-room--format-user (user &optional (room ement-room))
  "Format `ement-user' USER for ROOM.
ROOM defaults to the value of `ement-room'."
  (let ((face (if (equal (ement-user-id user)
                         (ement-user-id (ement-session-user ement-session)))
                  'ement-room-self
                (if ement-room-prism
                    `(:inherit ement-room-user :foreground ,(or (ement-user-color user)
                                                                (setf (ement-user-color user)
                                                                      (ement-room--user-color user))))
                  'ement-room-user))))
    ;; FIXME: If a membership state event has not yet been received, this
    ;; sets the display name in the room to the user ID, and that prevents
    ;; the display name from being used if the state event arrives later.
    (propertize (or (gethash room (ement-user-room-display-names user))
		    (puthash room (ement-room--user-display-name user room)
                             (ement-user-room-display-names user)))
		'face face
                'help-echo #'ement-room--user-help-echo)))

(defun ement-room--user-help-echo (window _object pos)
  "Return user ID string for POS in WINDOW.
For use as a `help-echo' function on `ement-user' headings."
  (with-selected-window window
    (ement-user-id (ewoc-data (ewoc-locate ement-ewoc pos)))))

(defun ement-room--user-color (user)
  "Return a color in which to display USER's messages."
  (cl-labels ((relative-luminance
               ;; Copy of `rainbow-color-luminance', except it doesn't divide by 256,
               ;; which appears to be the wrong thing to do, because with that removed,
               ;; the relative luminance of black to white is the correct ratio of
               ;; 21.0.  Also see <https://en.wikipedia.org/wiki/Relative_luminance>
               ;; and <https://www.w3.org/TR/WCAG20/#relativeluminancedef>.
               (r g b) (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b)))
              (contrast-ratio
               (a b) (pcase-let* ((`(,_ah ,_as ,av) (apply #'color-rgb-to-hsv a))
                                  (`(,_bh ,_bs ,bv) (apply #'color-rgb-to-hsv b))
                                  (lighter-luminance (apply #'relative-luminance (if (> av bv) a b)))
                                  (darker-luminance (apply #'relative-luminance (if (> av bv) b a))))
                       (/ (+ 0.05 lighter-luminance)
                          (+ 0.05 darker-luminance)))))
    (let* ((id (ement-user-id user))
           (id-hash (float (abs (sxhash id))))
           ;; TODO: Wrap-around the value to get the color I want.
           (ratio (/ id-hash (float most-positive-fixnum)))
           (color-num (round (* (* 255 255 255) ratio)))
           (color-rgb (list (/ (float (logand color-num 255)) 255)
                            (/ (float (lsh (logand color-num 65280) -8)) 255)
                            (/ (float (lsh (logand color-num 16711680) -16)) 255)))
           (background-rgb (color-name-to-rgb (face-background 'default)))
           (contrast-ratio (contrast-ratio color-rgb background-rgb)))
      (if (< contrast-ratio 3)
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

(define-widget 'ement-room-membership 'item
  "Widget for membership events."
  :format "%{ %v %}"
  :sample-face 'ement-room-membership)

;;;; Footer

(provide 'ement-room)

;;; ement-room.el ends here
