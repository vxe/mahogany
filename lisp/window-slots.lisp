(in-package #:mahogany)

;;; Window slots: permanent virtual outputs REC-1 .. REC-n, each showing one
;;; window (see heart/src/mirror.c). They are created once, after the init
;;; file is loaded and before the server starts, so the count is a startup
;;; setting: changing it needs a restart.
;;;
;;; Each slot has a fill policy (*window-slot-policies*, S3-1):
;;;   (:rule "app-id")                  the window with that app_id goes in
;;;                                     when it maps, if the slot is empty
;;;   (:follow-focus :deny ("app" ...)) the slot shows whichever window
;;;                                     Mahogany focuses; focusing a denied
;;;                                     app keeps the previous window
;;;   NIL                               nothing automatic
;;; Slots are not exclusive: one window can be in several at once (Emacs in
;;; REC-1 by rule and in REC-3 because it has focus).
;;;
;;; Environment overrides (handy for test runs):
;;;   MAHOGANY_WINDOW_SLOTS=n          slot count; 0 turns slots off
;;;   MAHOGANY_WINDOW_SLOT_APPS=a,b    app-id rules, replacing *window-slot-app-ids*
;;;                                    (*window-slot-policies* still applies)

(alexandria:define-constant +max-window-slots+ 16)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %string-list-p (thing)
    (and (listp thing) (every #'stringp thing)))

  (defun %window-slot-policy-p (thing)
    "True if THING is one slot's fill policy: NIL, (:rule APP-ID) or
(:follow-focus [:deny APP-IDS])."
    (or (null thing)
        (and (alexandria:proper-list-p thing)
             (case (first thing)
               (:rule (and (= (length thing) 2) (stringp (second thing))))
               (:follow-focus
                (let ((options (rest thing)))
                  (or (null options)
                      (and (= (length options) 2)
                           (eq (first options) :deny)
                           (alexandria:proper-list-p (second options))
                           (%string-list-p (second options))))))
               (t nil)))))

  (defun %window-slot-policies-p (thing)
    (and (alexandria:proper-list-p thing)
         (<= (length thing) 16)
         (every #'%window-slot-policy-p thing))))

(config-system:defconfig *window-slot-count* 0
  (integer 0 16)
  "How many window slots (virtual outputs REC-1 .. REC-n) to create at
startup. 0 means none. Overridden by the MAHOGANY_WINDOW_SLOTS environment
variable. Read once at startup.")

(config-system:defconfig *window-slot-app-ids* nil
  (satisfies %string-list-p)
  "App ids put into slots automatically: a window whose app_id is the Nth
entry goes into REC-N when it maps, if REC-N is empty. Naming N apps implies
at least N slots. Overridden by MAHOGANY_WINDOW_SLOT_APPS (comma separated).
Shorthand for (:rule APP-ID) entries of *window-slot-policies*.")

(config-system:defconfig *window-slot-policies* nil
  (satisfies %window-slot-policies-p)
  "Fill policy of each window slot, by index (REC-1 first). An entry is
NIL (then *window-slot-app-ids* decides, if it names an app for that slot),
(:rule \"app-id\") (the window with that app_id goes in when it maps, if the
slot is empty), or (:follow-focus :deny (\"app-id\" ...)) (the slot shows
whichever window Mahogany focuses; focusing a denied app keeps the previous
window). A window can be in several slots at once. Naming N policies implies
at least N slots. Read once at startup.")

(config-system:defconfig *window-slot-mode* '(1920 1080 50)
  list
  "Width, height and refresh rate (Hz) of every window slot, as a list.
The refresh rate only matters while there is no real output to follow.")

(defun %parse-window-slot-count (string)
  "The slot count in STRING, or NIL if STRING is not a valid count."
  (let ((n (and string (ignore-errors (parse-integer string)))))
    (when (and n (<= 0 n +max-window-slots+))
      n)))

(defun %split-app-ids (string)
  (remove "" (uiop:split-string string :separator ",") :test #'string=))

(defun window-slot-settings (&key (count *window-slot-count*)
                               (app-ids *window-slot-app-ids*)
                               (policies *window-slot-policies*)
                               (env-count (uiop:getenv "MAHOGANY_WINDOW_SLOTS"))
                               (env-apps (uiop:getenv "MAHOGANY_WINDOW_SLOT_APPS")))
  "Resolve the window slot settings. Returns (values count app-ids policies).
ENV-COUNT and ENV-APPS (strings, normally from the environment) override
COUNT and APP-IDS. An invalid ENV-COUNT is ignored; an explicit 0 turns
slots off; otherwise there is at least one slot per app id and per entry of
POLICIES. The third value has one policy per slot: the entry of POLICIES at
that index if non-NIL, else (:rule APP-ID) for the app id at that index,
else NIL."
  (let ((env-n (%parse-window-slot-count env-count)))
    (when (and env-count (not env-n))
      (log-string :warn "Ignoring MAHOGANY_WINDOW_SLOTS=~S: not an integer in 0..~A"
                  env-count +max-window-slots+))
    (when (eql env-n 0)
      (return-from window-slot-settings (values 0 nil nil)))
    (let* ((apps (if env-apps (%split-app-ids env-apps) app-ids))
           (n (min +max-window-slots+
                   (max (or env-n count) (length apps) (length policies))))
           (apps (subseq apps 0 (min n (length apps)))))
      (values n
              apps
              (loop for index below n
                    collect (or (nth index policies)
                                (alexandria:when-let ((app-id (nth index apps)))
                                  (list :rule app-id))))))))

(defun %apply-window-slot-policies (server policies)
  "Hand each slot's fill policy in POLICIES (one entry per slot, REC-1
first) to the C side of SERVER."
  (loop for policy in policies
        for index from 0
        do (ecase (first policy)
             ((nil))
             (:rule
              (hrt:window-slot-set-rule server index (second policy)))
             (:follow-focus
              (hrt:window-slot-set-follow-focus server index t)
              (dolist (app-id (getf (rest policy) :deny))
                (hrt:window-slot-deny-app-id server index app-id))))))

(defun window-slots-init (state)
  "Create the window slots for STATE's server from the settings. Call after
the init file is loaded and before the server starts."
  (declare (type mahogany-state state))
  (multiple-value-bind (count app-ids policies) (window-slot-settings)
    (declare (ignore app-ids))
    (when (plusp count)
      (destructuring-bind (&optional (width 1920) (height 1080) (refresh 50))
          *window-slot-mode*
        (let ((server (state-server state)))
          (cond
            ((not (hrt:window-slots-create server count width height
                                           (round (* refresh 1000))))
             (log-string :error "Could not create ~A window slot~:P" count))
            (t
             (%apply-window-slot-policies server policies)
             (log-string :info "Window slots: ~{~A~^, ~} (policies: ~S)"
                         (loop for i below (hrt:window-slot-count server)
                               collect (hrt:window-slot-name server i))
                         policies))))))))
