(in-package #:mahogany)

;;; Window slots: permanent virtual outputs REC-1 .. REC-n, each showing one
;;; window (see heart/src/mirror.c). They are created once, after the init
;;; file is loaded and before the server starts, so the count is a startup
;;; setting: changing it needs a restart.
;;;
;;; Environment overrides (handy for test runs):
;;;   MAHOGANY_WINDOW_SLOTS=n          slot count; 0 turns slots off
;;;   MAHOGANY_WINDOW_SLOT_APPS=a,b    app-id rules, replacing *window-slot-app-ids*

(alexandria:define-constant +max-window-slots+ 16)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %string-list-p (thing)
    (and (listp thing) (every #'stringp thing))))

(config-system:defconfig *window-slot-count* 0
  (integer 0 16)
  "How many window slots (virtual outputs REC-1 .. REC-n) to create at
startup. 0 means none. Overridden by the MAHOGANY_WINDOW_SLOTS environment
variable. Read once at startup.")

(config-system:defconfig *window-slot-app-ids* nil
  (satisfies %string-list-p)
  "App ids put into slots automatically: a window whose app_id is the Nth
entry goes into REC-N when it maps, if REC-N is empty. Naming N apps implies
at least N slots. Overridden by MAHOGANY_WINDOW_SLOT_APPS (comma separated).")

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
                               (env-count (uiop:getenv "MAHOGANY_WINDOW_SLOTS"))
                               (env-apps (uiop:getenv "MAHOGANY_WINDOW_SLOT_APPS")))
  "Resolve the window slot settings. Returns (values count app-ids).
ENV-COUNT and ENV-APPS (strings, normally from the environment) override
COUNT and APP-IDS. An invalid ENV-COUNT is ignored; an explicit 0 turns
slots off; otherwise there is at least one slot per app id."
  (let ((env-n (%parse-window-slot-count env-count)))
    (when (and env-count (not env-n))
      (log-string :warn "Ignoring MAHOGANY_WINDOW_SLOTS=~S: not an integer in 0..~A"
                  env-count +max-window-slots+))
    (when (eql env-n 0)
      (return-from window-slot-settings (values 0 nil)))
    (let* ((apps (if env-apps (%split-app-ids env-apps) app-ids))
           (n (min +max-window-slots+ (max (or env-n count) (length apps)))))
      (values n (subseq apps 0 (min n (length apps)))))))

(defun window-slots-init (state)
  "Create the window slots for STATE's server from the settings. Call after
the init file is loaded and before the server starts."
  (declare (type mahogany-state state))
  (multiple-value-bind (count app-ids) (window-slot-settings)
    (when (plusp count)
      (destructuring-bind (&optional (width 1920) (height 1080) (refresh 50))
          *window-slot-mode*
        (let ((server (state-server state)))
          (cond
            ((not (hrt:window-slots-create server count width height
                                           (round (* refresh 1000))))
             (log-string :error "Could not create ~A window slot~:P" count))
            (t
             (loop for app-id in app-ids
                   for index from 0
                   do (hrt:window-slot-set-rule server index app-id))
             (log-string :info "Window slots: ~{~A~^, ~} (rules: ~S)"
                         (loop for i below (hrt:window-slot-count server)
                               collect (hrt:window-slot-name server i))
                         app-ids))))))))
