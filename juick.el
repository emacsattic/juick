;;; juick.el --- improvement reading juick@juick.com

;; Copyright (C) 2009  mad
;; Copyright (C) 2009  vyazovoi

;; Author: mad <owner.mad.epa@gmail.com>
;; Keywords: juick
;; Version: 0.2

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Markup message recivied from juick@juick.com and some usefull keybindings.

;;; Installing:

;; 1. Put juick.el to you load-path
;; 2. put this to your init file:

;; (require 'juick)

;; and any useful settings

;; (setq juick-tag-subscribed '("linux" "juick" "jabber" "emacs" "vim"))
;; (setq juick-auto-subscribe-list '("linux" "emacs" "vim" "juick" "ugnich"))
;; (juick-auto-update t)

;;; Default bind:

;; u - unsubscribe message/user
;; s - subscribe message/user
;; d - delete message
;; b - bookmark message/user
;; p - make private message with user
;; g - open browser with id/user
;; C-cjb - `juick-bookmark-list'

;;; Code:

(require 'button)
(require 'browse-url)
(require 'epg)
(require 'epa)

;; XXX: if jabber load through `jabber-autloads'
(require 'jabber-chatbuffer)
(require 'jabber-ibb)
(require 'jabber-geoloc)
(require 'jabber-tune)
(require 'jabber-moods)

(require 'google-maps)

(defgroup juick-faces nil "Faces for displaying Juick msg"
  :group 'juick)

(defface juick-id-face
  '((t (:weight bold)))
  "face for displaying id"
  :group 'juick-faces)

(defface juick-user-name-face
  '((t (:foreground "blue" :weight bold :slant normal)))
  "face for displaying user name"
  :group 'juick-faces)

(defface juick-tag-face
  '((t (:foreground "red4" :slant italic)))
  "face for displaying tags"
  :group 'juick-faces)

(defface juick-bold-face
  '((t (:weight bold :slant normal)))
  "face for displaying bold text"
  :group 'juick-faces)

(defface juick-italic-face
  '((t (:slant italic)))
  "face for displaying italic text"
  :group 'juick-faces)

(defface juick-underline-face
  '((t (:underline t :slant normal)))
  "face for displaying underline text"
  :group 'juick-faces)

(defvar juick-reply-id-add-plus nil
  "Set to t then id inserted with + (e.g NNNN+).

Useful for people more reading instead writing")

(defvar juick-overlays nil)

(defvar juick-bot-jid "juick@juick.com")

(defvar juick-image-buffer "*juick-avatar-dir*")

(defvar juick-point-last-message nil)

(defvar juick-avatar-internal-stack nil
  "Internal var")

(defvar juick-avatar-update-day 4
  "Update (download) avatar after `juick-avatar-update-day'")

(defvar juick-icon-mode t
  "This mode display avatar in buffer chat")

(defvar juick-use-pgp nil
  "Trying decrypt all armored messages")

(defvar juick-icon-hight nil
  "If t then show 96x96 avatars")

(defvar juick-tag-subscribed '()
  "List subscribed tags")

(defvar juick-auto-subscribe-list nil
  "This list contained tag or username for auto subscribe")

(defvar juick-bookmark-file (expand-file-name "~/.emacs.d/.juick-bkm"))

(defvar juick-bookmarks '())

(defvar juick-api-aftermid nil)

(defvar juick-timer-interval 120)
(defvar juick-timer nil)

(defvar juick-tmp-dir
  (expand-file-name (concat "juick-images-" (user-login-name))
                    temporary-file-directory))

(if (not (file-directory-p juick-tmp-dir))
    (make-directory juick-tmp-dir))

;; from http://juick.com/help/
(defvar juick-id-regex "\\(#[0-9]+\\(/[0-9]+\\)?\\)")
(defvar juick-user-name-regex "[^0-9A-Za-z\\.]\\(@[0-9A-Za-z@\\.\\-]+\\)")
(defvar juick-tag-regex "\\(\\*[^ \n]+\\)")
(defvar juick-bold-regex "[\n ]\\(\\*[^\n]+*\\*\\)[\n ]")
(defvar juick-italic-regex "[\n ]\\(/[^\n]+/\\)[\n ]")
(defvar juick-underline-regex "[\n ]\\(\_[^\n]+\_\\)[\n ]")

(defun juick-markup-chat (from buffer text proposed-alert &optional force)
  "Markup  message from `juick-bot-jid'.

Where FROM is jid sender, BUFFER is buffer with message TEXT

Use FORCE to markup any buffer"
  (if (or force (string-match juick-bot-jid from))
      (save-excursion
        (set-buffer buffer)
        (when (null force)
          (condition-case nil
              (jabber-truncate-top)
            (wrong-number-of-arguments
             (jabber-truncate-top buffer)))
          (setq juick-point-last-message
                (re-search-backward "\\[[0-9]+:[0-9]+\\].*>" nil t)))
        (when juick-use-pgp
          (juick-decrypt-pgp (point) (point-max)))
        (juick-markup-user-name)
        (juick-markup-id)
        (juick-markup-tag)
        (juick-markup-bold)
        (juick-markup-italic)
        (juick-markup-underline)
        (when (and juick-icon-mode window-system)
          (clear-image-cache)
          (juick-avatar-insert)))))

(add-hook 'jabber-alert-message-hooks 'juick-markup-chat)

(defun juick-decrypt-pgp (start end)
  "Decrypt OpenPGP armors in the current region between START adn EDN.

Based of `epa-decrypt-armor-in-region' from epa.el packages"
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      (goto-char start)
      (let (armor-start armor-end)
        (loop (re-search-forward "-----BEGIN PGP MESSAGE-----$" nil t)
          (setq armor-start (match-beginning 0)
                armor-end (re-search-forward "^-----END PGP MESSAGE-----$"
                                             nil t))
          (unless armor-end
            (return))
          (goto-char armor-start)
          (let ((context (epg-make-context 'OpenPGP))
                (inhibit-read-only t)
                plain)
            (goto-char armor-end)
            (setq plain (decode-coding-string
                         (epg-decrypt-string context (buffer-substring start end))
                         'utf-8))
            (delete-region armor-start armor-end)
            (goto-char armor-start)
            (insert plain)))))))

(defun juick-avatar-insert ()
  (goto-char (or juick-point-last-message (point-min)))
  (setq juick-avatar-internal-stack nil)
  (let ((inhibit-read-only t))
    (while (re-search-forward "\\(by @\\|> @\\|^@\\)\\([0-9A-Za-z@\\.\\-]+\\):" nil t)
      (let* ((icon-string "\n ")
             (name (match-string-no-properties 2))
             (fake-png (concat juick-tmp-dir "/" name ".png")))
        (goto-char (match-beginning 0))
        (juick-avatar-download name)
        (set-text-properties
         1 2 `(display
               (image :type png
                      :file ,fake-png))
         icon-string)
        (re-search-forward "@" nil t)
        (goto-char (- (point) 1))
        (insert (concat icon-string " "))
        (re-search-forward ":" nil t)))))

(defun juick-avatar-download (name)
  "Download avatar from juick.com"
  (if (or (assoc-string name juick-avatar-internal-stack)
          (and (file-exists-p (concat juick-tmp-dir "/" name ".png"))
               (< (time-to-number-of-days
                   (time-subtract (current-time)
                                  (nth 5 (file-attributes (concat juick-tmp-dir "/" name ".png")))))
                  juick-avatar-update-day)))
      nil
    (let ((avatar-url (concat "http://juick.com/" name "/"))
          (url-request-method "GET"))
      (push name juick-avatar-internal-stack)
      (url-retrieve avatar-url
                    '(lambda (status name)
                       (let ((result-buffer (current-buffer)))
                         (goto-char (point-min))
                         (when (re-search-forward "http://i.juick.com/a/[0-9]+\.png" nil t)
                           (juick-avatar-download-and-save (match-string 0) name)
                           (kill-buffer result-buffer))))
                    (list name)))))

(defun juick-avatar-download-and-save (link name)
  "Extract image frim LINK and save it with NAME in
`juick-tmp-dir'"
  (let* ((filename (substring link (string-match "[0-9]+" link)))
         (avatar-url (concat "http://i.juick.com/" (if juick-icon-hight "a" "as") "/" filename))
         (url-request-method "GET"))
    (url-retrieve avatar-url
                  '(lambda (status name)
                     (let ((result-buffer (current-buffer))
                           (buffer-file-coding-system 'binary)
                           (file-coding-system 'binary)
                           (coding-system-for-write 'binary))
                       (delete-region (point-min) (re-search-forward "\n\n" nil t))
                       (write-region (point-min) (point-max) (concat juick-tmp-dir "/" name ".png"))
                       (kill-buffer (current-buffer))
                       (kill-buffer result-buffer)))
                  (list name))))

(defun juick-auto-update ()
  (interactive)
  (if juick-timer
      (progn
        (cancel-timer juick-timer)
        (setq juick-timer nil)
        (message "auto update deactivated"))
    (setq juick-timer
          (run-at-time "0 sec"
                       juick-timer-interval
                       #'juick-api-last-message))
    (message "auto update activated")))

(defun juick-api-request (juick-stanza type callback)
  "Make and process juick stanza
\(http://juick.com/help/api/xmpp/)"
  (let ((completions
         (mapcar (lambda (c)
                   (cons
                    (jabber-connection-bare-jid c)
                    c))
                 jabber-connections))
        (current-connection
         ;; if the buffer is associated with a connection, use it
         (when (and jabber-buffer-connection
                    (memq jabber-buffer-connection jabber-connections))
           (jabber-connection-bare-jid jabber-buffer-connection))))
    (if (not current-connection)
        ;; then use all accounts where exists juick@juick.com
        (dolist (jc jabber-connections)
          (if (member-if (lambda (x)
                           (string-match (symbol-name x)  juick-bot-jid))
                         (plist-get (fsm-get-state-data jc) :roster))
              (jabber-send-iq jc juick-bot-jid type juick-stanza
                              callback nil
                              ;; this error code='404' (last message not found)
                              nil nil)))
      ;; else use current connection
      (jabber-send-iq (cdr (assoc current-connection completions))
                      juick-bot-jid type juick-stanza
                      callback nil
                      ;; this error code='404' (last message not found)
                      nil nil))))

(defun juick-api-unsubscribe (id)
  "Unsubscribe to message with ID."
  (juick-api-request `(subscriptions ((xmlns . "http://juick.com/subscriptions#messages")
                              (action . "unsubscribe")
                              (mid . ,id))) "set" nil)
  (message "Unsubscribing to %s" id))

(defun juick-api-subscribe (id)
  "Subscribe to message with ID.

Recieving full new message."
  (juick-api-request `(subscriptions ((xmlns . "http://juick.com/subscriptions#messages")
                              (action . "subscribe")
                              (mid . ,id))) "set" nil)
  (message "Subscribing to %s" id))

(defun juick-api-last-message ()
  "Recieving last ten message after `juick-api-aftermid'"
  (juick-api-request `(query ((xmlns . "http://juick.com/query#messages")
                              ,(if juick-api-aftermid `(aftermid . ,juick-api-aftermid))))
                     "get" 'juick-api-last-message-cb))

(defun juick-api-last-message-cb (jc xml-data closure-data)
  "Checking `juick-auto-subscribe-list' and `juick-tag-subscribed'
in a match, if match send fake message himself"
  (let ((juick-query (jabber-xml-get-children
                      (car (jabber-xml-get-children xml-data 'query))
                      'juick))
        (first-message t)) ;; XXX: i dont know how break out of dolist
    (dolist (x juick-query)
      (if (> (string-to-number (jabber-xml-get-attribute x 'mid))
             (string-to-number (or juick-api-aftermid "0")))
          (setq juick-api-aftermid (jabber-xml-get-attribute x 'mid)))
      (setq first-message t)
      ;; Message with uname auto subscribe
      (when (assoc-string (jabber-xml-get-attribute x 'uname)
                          juick-auto-subscribe-list)
        (juick-api-subscribe (jabber-xml-get-attribute x 'mid)))
      (dolist (tag (jabber-xml-get-children x 'tag))
        ;; Message with tag auto subscribe
        (when (assoc-string (car (jabber-xml-node-children tag))
                            juick-auto-subscribe-list)
          (juick-api-subscribe (jabber-xml-get-attribute x 'mid)))
        (when (and first-message (assoc-string
                                  (car (jabber-xml-node-children tag))
                                  juick-tag-subscribed))
          ;; make fake incomning message
          (setq first-message nil)
          (jabber-process-chat
           jc
           `(message
             ((from . ,juick-bot-jid))
             (body nil ,(concat
                         "@"
                         (jabber-xml-get-attribute x 'uname)
                         ": "
                         (mapconcat
                          (lambda (tag)
                            (concat "*" (car (jabber-xml-node-children tag))))
                          (jabber-xml-get-children x 'tag)
                          " ")
                         "\n"
                         (car (jabber-xml-node-children
                               (car (jabber-xml-get-children x 'body))))
                         "\n#" (jabber-xml-get-attribute x 'mid)
                         " (" (or (jabber-xml-get-attribute x 'replies) "0") " replies)"
                         " (S)")))))))))

(defvar juick-bookmark-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map "q" 'juick-find-buffer)
    (define-key map "d" 'juick-bookmark-remove)
    (define-key map "\C-k" 'juick-bookmark-remove)
    map)
  "Keymap for `juick-bookmark-mode'.")

(defun juick-bookmark-list (&optional force)
  (interactive)
  (let ((tmp-pos juick-point-last-message))
    (setq juick-point-last-message nil)
    (when (null force)
      (split-window-vertically -10)
      (windmove-down)
      (switch-to-buffer "*juick-bookmark*"))
    (toggle-read-only -1)
    (delete-region (point-min) (point-max))
    (dolist (x juick-bookmarks)
      (insert (concat (car x) " " (cdr x) "\n")))
    (goto-char (point-min))
    (toggle-read-only)
    (juick-markup-chat juick-bot-jid (current-buffer) nil nil t)
    (setq juick-point-last-message tmp-pos)
    (juick-bookmark-mode)))

(defun juick-bookmark-save ()
  (interactive)
  (save-excursion
    (find-file juick-bookmark-file)
    (delete-region (point-min) (point-max))
    (insert ";; -*- mode:emacs-lisp; coding: utf-8-emacs; -*-\n\n")
    (insert "(setq juick-bookmarks '")
    (insert (prin1-to-string juick-bookmarks))
    (insert ")")
    (write-file juick-bookmark-file)
    (kill-buffer (current-buffer))))

(defun juick-bookmark-add (id desc)
  (interactive)
  (when (not desc)
    (setq desc (read-string (concat "Type description for " id ": "))))
  (push `(,id . ,desc) juick-bookmarks)
  (juick-bookmark-save))

(defun juick-bookmark-remove ()
  (interactive)
  (save-excursion
    (beginning-of-line)
    (when (or (looking-at "#[0-9]+\\(/[0-9]+\\)?")
              (looking-at "@[0-9A-Za-z@\.\-]+"))
      (setq juick-bookmarks
            (remove-if
             '(lambda (x)
                (if (string-match-p (car x) (match-string-no-properties 0))
                    t)) juick-bookmarks))
      (juick-bookmark-save)
      (juick-bookmark-list t))))

(define-derived-mode juick-bookmark-mode text-mode
  "juick bookmark mode"
  "Major mode for getting bookmark")

(define-key jabber-chat-mode-map "\C-cjb" 'juick-bookmark-list)

(define-key jabber-chat-mode-map "g" 'juick-go-url)
(define-key jabber-chat-mode-map "п" 'juick-go-url)
(define-key jabber-chat-mode-map [mouse-1] 'juick-go-url)

(define-key jabber-chat-mode-map "b" 'juick-go-bookmark)
(define-key jabber-chat-mode-map "и" 'juick-go-bookmark)

(define-key jabber-chat-mode-map "s" 'juick-go-subscribe)
(define-key jabber-chat-mode-map "ы" 'juick-go-subscribe)

(define-key jabber-chat-mode-map "u" 'juick-go-unsubscribe)
(define-key jabber-chat-mode-map "г" 'juick-go-unsubscribe)

(define-key jabber-chat-mode-map "d" 'juick-go-delete)
(define-key jabber-chat-mode-map "в" 'juick-go-delete)

(define-key jabber-chat-mode-map "p" 'juick-go-private)
(define-key jabber-chat-mode-map "з" 'juick-go-private)

(define-key jabber-chat-mode-map "a" 'juick-add-tag)
(define-key jabber-chat-mode-map "r" 'juick-remove-tag)

(define-key jabber-chat-mode-map "\M-p" 'juick-go-to-post-back)
(define-key jabber-chat-mode-map "\M-n" 'juick-go-to-post-forward)

(defun juick-remove-tag ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (thing-at-point-looking-at "\\(\\*[^ \n]+\\)"))
      (save-excursion
        (let ((tag (match-string-no-properties 1))
              (id (if (re-search-forward "^#[0-9]+\\(/[0-9]+\\)?" nil)
                      (match-string-no-properties 0))))
          (when (and id tag)
            (message (concat "Tag " tag " (" id ")" " deleted"))
            (juick-send-message juick-bot-jid (concat id " " tag)))))
    (self-insert-command 1)))

(defun juick-add-tag ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (thing-at-point-looking-at "#\\([0-9]+\\)"))
      (let ((id (match-string-no-properties 0))
            (tag (read-string "Type tag: ")))
        (when (and id tag)
          (message (concat "Tag " tag " (" id ")" " added"))
          (juick-send-message juick-bot-jid
                              (concat id (if (string-match "^\\*" tag) " " " *") tag))))
    (self-insert-command 1)))

(defun juick-go-url ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (or (thing-at-point-looking-at juick-id-regex)
               (thing-at-point-looking-at juick-user-name-regex)))
      (let* ((part-of-url (match-string-no-properties 1))
             (part-of-url (replace-in-string part-of-url "@\\|#" ""))
             (part-of-url (replace-in-string part-of-url "/" "#")))
        (message part-of-url)
        (browse-url (concat "http://juick.com/" part-of-url)))
    (unless (string= last-command "mouse-drag-region")
      (self-insert-command 1))))

(defun juick-go-bookmark ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (or (thing-at-point-looking-at "#[0-9]+")
                   (thing-at-point-looking-at "@[0-9A-Za-z@\.\-]+")))
               (juick-bookmark-add (match-string-no-properties 0) nil)
             (self-insert-command 1)))

(defun juick-go-subscribe ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (or (thing-at-point-looking-at "#\\([0-9]+\\)")
               (thing-at-point-looking-at "@[0-9A-Za-z@\.\-]+")))
      (if (match-string 1)
          (juick-api-subscribe (match-string-no-properties 1))
        (juick-send-message juick-bot-jid
                            (concat "S " (match-string-no-properties 0))))
    (self-insert-command 1)))

(defun juick-go-unsubscribe ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (or (thing-at-point-looking-at "#\\([0-9]+\\)")
               (thing-at-point-looking-at "@[0-9A-Za-z@\.\-]+")))
      (if (match-string 1)
          (juick-api-unsubscribe (match-string-no-properties 1))
        (juick-send-message juick-bot-jid
                            (concat "U " (match-string-no-properties 0))))
    (self-insert-command 1)))

(defun juick-go-delete ()
     (interactive)
     (if (and (equal (get-text-property (point) 'read-only) t)
              (thing-at-point-looking-at "#[0-9]+\\(/[0-9]+\\)?"))
         (juick-send-message juick-bot-jid
                             (concat "D " (match-string-no-properties 0)))
       (self-insert-command 1)))

(defun juick-go-private ()
  (interactive)
  (if (and (equal (get-text-property (point) 'read-only) t)
           (thing-at-point-looking-at "@[0-9A-Za-z@\.\-]+"))
      (progn
        (goto-char (point-max))
        (delete-region jabber-point-insert (point-max))
        (insert (concat "PM " (match-string-no-properties 0) " ")))
    (self-insert-command 1)))

(defun juick-go-to-post-back ()
  (interactive)
  (re-search-backward "@[a-z0-9]+:$" nil t))

(defun juick-go-to-post-forward ()
  (interactive)
  (re-search-forward "@[a-z0-9]+:$" nil t))

(defun juick-send-message (to text)
  "Send TEXT to TO imediately"
  (interactive)
  (save-excursion
    (let* ((current-connection
            ;; if the buffer is associated with a connection, use it
            (when (and jabber-buffer-connection
                       (memq jabber-buffer-connection jabber-connections))
              (jabber-connection-bare-jid jabber-buffer-connection)))
           (buffer (jabber-chat-create-buffer (jabber-read-account) to)))
      (set-buffer buffer)
      (goto-char (point-max))
      (delete-region jabber-point-insert (point-max))
      (insert text)
      (jabber-chat-buffer-send))))

(defun juick-markup-user-name ()
  "Markup user-name matched by regex `juick-regex-user-name'"
  (goto-char (or juick-point-last-message (point-min)))
  (while (re-search-forward juick-user-name-regex nil t)
    (when (match-string 1)
      (juick-add-overlay (match-beginning 1) (match-end 1)
                         'juick-user-name-face)
      (make-button (match-beginning 1) (match-end 1)
                   'action 'juick-insert-user-name))))

(defun juick-markup-id ()
  "Markup id matched by regex `juick-regex-id'"
  (goto-char (or juick-point-last-message (point-min)))
  (while (re-search-forward juick-id-regex nil t)
    (when (match-string 1)
      (juick-add-overlay (match-beginning 1) (match-end 1)
                         'juick-id-face)
      (make-button (match-beginning 1) (match-end 1)
                   'action 'juick-insert-id))))

(defun juick-markup-tag ()
  "Markup tag matched by regex `juick-regex-tag'"
  (goto-char (or juick-point-last-message (point-min)))
  ;;; FIXME: I dont know how to recognize a tag point
  (while (re-search-forward (concat juick-user-name-regex  "\: ") nil t)
    ;;(goto-char (+ (point) (length (match-string 1))))
    (let ((count-tag 0))
      (while (and (looking-at "\\*")
                  (<= count-tag 5))
        (let ((beg-tag (point))
              (end-tag (- (re-search-forward "[\n ]" nil t) 1)))
          (juick-add-overlay beg-tag end-tag 'juick-tag-face)
          (make-button beg-tag end-tag 'action 'juick-find-tag))
        (setq count-tag (+ count-tag 1))))))

(defun juick-markup-italic ()
  (goto-char (or juick-point-last-message (point-min)))
  (while (re-search-forward juick-italic-regex nil t)
    (juick-add-overlay (match-beginning 1) (match-end 1)
                       'juick-italic-face)
    (goto-char (- (point) 1))))

(defun juick-markup-bold ()
  (goto-char (or juick-point-last-message (point-min)))
  (while (re-search-forward juick-bold-regex nil t)
    (juick-add-overlay (match-beginning 1) (match-end 1)
                       'juick-bold-face)
    (goto-char (- (point) 1))))

(defun juick-markup-underline ()
  (goto-char (or juick-point-last-message (point-min)))
  (while (re-search-forward juick-underline-regex nil t)
    (juick-add-overlay (match-beginning 1) (match-end 1)
                       'juick-underline-face)
    (goto-char (- (point) 1))))

;;; XXX: maybe merge?
(defun juick-insert-user-name (button)
  "Inserting reply id in conversation buffer"
  (let ((user-name (buffer-substring-no-properties
                    (overlay-start button)
                    (- (re-search-forward "[\n :]" nil t) 1))))
    (when (string-match-p (jabber-chat-get-buffer juick-bot-jid)
                          (buffer-name))
      (message "Mark set")
      (push-mark))
    (juick-find-buffer)
    (goto-char (point-max))
    (insert (concat user-name " ")))
  (recenter 10))

(defun juick-insert-id (button)
  "Inserting reply id in conversation buffer"
  (let ((id (buffer-substring-no-properties
             (overlay-start button)
             (- (re-search-forward "[\n ]" nil t) 1))))
    (when (string-match-p (jabber-chat-get-buffer juick-bot-jid)
                          (buffer-name))
      (message "Mark set")
      (push-mark))
    (juick-find-buffer)
    (goto-char (point-max))
    ;; usually #NNNN supposed #NNNN+
    (if (string-match "/" id)
        (insert (concat id " "))
          (insert (concat id (if juick-reply-id-add-plus "+" " ")))))
  (recenter 10))

(defun juick-find-tag (button)
  "Retrive 10 message this tag"
  (save-excursion
    (let ((tag (buffer-substring-no-properties
                (overlay-start button)
                (re-search-forward "\\([\n ]\\|$\\)" nil t))))
      (juick-find-buffer)
      (delete-region jabber-point-insert (point-max))
      (goto-char (point-max))
      (insert tag)))
  (jabber-chat-buffer-send))

(defun juick-find-buffer ()
  "Find buffer with `juick-bot-jid'"
  (interactive)
  (when (not (string-match (jabber-chat-get-buffer juick-bot-jid)
                           (buffer-name)))
    (delete-window)
    (let ((juick-window (get-window-with-predicate
                         (lambda (w)
                           (string-match (jabber-chat-get-buffer juick-bot-jid)
                                         (buffer-name (window-buffer w)))))))
      (if juick-window
          (select-window juick-window)
        ;; XXX: if nil open last juick@juick buffer
        (jabber-chat-with nil juick-bot-jid)))))

(defadvice jabber-chat-with (around jabber-chat-with-around-advice
                                    (jc jid &optional other-window) activate)
  "Used for markup history buffer"
  ad-do-it
  ;; FIXME: this activate ever when open buffer with juick@juick.com,
  ;; maybe adviced `jabber-chat-insert-backlog-entry' instead
  ;; `jabber-chat-with'.
  (when (string-match-p juick-bot-jid jid)
    (save-excursion
      (goto-char (point-min))
      (setq juick-point-last-message (point-min))
      (juick-markup-chat juick-bot-jid (current-buffer) nil nil t)
      (setq juick-point-last-message (point-max)))))

(defadvice jabber-chat-send (around jabber-chat-send-around-advice
                                    (jc body) activate)
  "Check and correct juick command"
  (if (string-match juick-bot-jid jabber-chatting-with)
      (let* ((body (cond
                    ((string= "№" body)
                     "#")
                    ((string= "№+" body)
                     "#+")
                    ((string= "РУДЗ" body)
                     "HELP")
                    ((string= "help" body)
                     "HELP")
                    ((string= "d l" body)
                     "D L")
                    (t
                     body))))
        ad-do-it)
    ad-do-it))

(defun juick-next-button ()
  "move point to next button"
  (interactive)
  (if (next-button (point))
      (goto-char (overlay-start (next-button (point))))
    (progn
      (goto-char (point-max))
      (message "button not found"))))

(defun juick-add-overlay (begin end faces)
  (let ((overlay (make-overlay begin end)))
    (overlay-put overlay 'face faces)
    (push overlay juick-overlays)))

(defun juick-delete-overlays ()
  (dolist (overlay juick-overlays)
    (delete-overlay overlay))
  (setq juick-overlays nil))

(if (file-exists-p juick-bookmark-file)
    (load-file juick-bookmark-file))

(provide 'juick)
;;; juick.el ends here
