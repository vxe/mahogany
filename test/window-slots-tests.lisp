(fiasco:define-test-package #:mahogany-tests/window-slots
  (:local-nicknames (#:mh #:mahogany)))

(in-package #:mahogany-tests/window-slots)

;; WINDOW-SLOT-SETTINGS resolves the slot count and the app-id rules from the
;; config variables, overridden by the environment
;; (MAHOGANY_WINDOW_SLOTS / MAHOGANY_WINDOW_SLOT_APPS). It returns
;; (values count app-ids).

(defmacro is-settings ((expected-count expected-apps) &rest args)
  `(multiple-value-bind (count apps) (mh::window-slot-settings ,@args)
     (fiasco:is (eql ,expected-count count))
     (fiasco:is (equal ,expected-apps apps))))

(fiasco:deftest window-slot-settings-default-is-off ()
  (is-settings (0 nil)))

(fiasco:deftest window-slot-settings-uses-config ()
  (is-settings (3 '("emacs")) :count 3 :app-ids '("emacs")))

(fiasco:deftest window-slot-settings-env-count-overrides-config ()
  (is-settings (2 nil) :count 3 :env-count "2"))

(fiasco:deftest window-slot-settings-env-count-zero-turns-slots-off ()
  (is-settings (0 nil) :count 3 :env-count "0"))

(fiasco:deftest window-slot-settings-bad-env-count-falls-back-to-config ()
  (is-settings (3 nil) :count 3 :env-count "three")
  (is-settings (3 nil) :count 3 :env-count "-1")
  (is-settings (3 nil) :count 3 :env-count "99")
  (is-settings (3 nil) :count 3 :env-count ""))

(fiasco:deftest window-slot-settings-env-apps-override-config-apps ()
  (is-settings (2 '("foot" "emacs"))
               :count 2 :app-ids '("firefox") :env-apps "foot,emacs"))

(fiasco:deftest window-slot-settings-env-apps-drop-empty-entries ()
  (is-settings (2 '("a" "b")) :env-apps ",a,,b,"))

(fiasco:deftest window-slot-settings-one-slot-per-app-at-least ()
  ;; Like the spike's MH_SPIKE_MIRROR=a,b: naming apps implies their slots.
  (is-settings (2 '("a" "b")) :env-apps "a,b")
  (is-settings (4 '("a" "b")) :count 4 :app-ids '("a" "b")))

(fiasco:deftest window-slot-settings-explicit-zero-wins-over-apps ()
  ;; An explicit 0 in the environment is the off switch.
  (is-settings (0 nil) :env-count "0" :env-apps "a,b"))

(fiasco:deftest window-slot-count-config-rejects-bad-values ()
  (fiasco:signals config-system:invalid-datum-error
    (config-system:set-config mh::*window-slot-count* -1))
  (fiasco:signals config-system:invalid-datum-error
    (config-system:set-config mh::*window-slot-count* 17)))

(fiasco:deftest window-slot-app-ids-config-rejects-non-strings ()
  (fiasco:signals config-system:invalid-datum-error
    (config-system:set-config mh::*window-slot-app-ids* '(emacs))))

;; S3-1: per-slot fill policies, the third value of WINDOW-SLOT-SETTINGS.
;; One entry per slot: (:rule APP-ID), (:follow-focus :deny APP-IDS) or NIL.
;; *window-slot-policies* overrides *window-slot-app-ids* per index, so the
;; old app-id list keeps working unchanged.

(defmacro is-policies (expected &rest args)
  `(fiasco:is (equal ,expected (nth-value 2 (mh::window-slot-settings ,@args)))))

(fiasco:deftest window-slot-policies-default-from-app-ids ()
  (is-policies '((:rule "emacs") (:rule "stream-term"))
               :app-ids '("emacs" "stream-term") :policies nil)
  (is-policies '((:rule "emacs") nil nil)
               :count 3 :app-ids '("emacs") :policies nil)
  (is-policies '() :policies nil))

(fiasco:deftest window-slot-policies-override-app-ids-per-index ()
  (is-policies '((:rule "emacs") (:rule "stream-term")
                 (:follow-focus :deny ("com.obsproject.Studio")))
               :app-ids '("emacs" "stream-term")
               :policies '(nil nil (:follow-focus :deny ("com.obsproject.Studio"))))
  (is-policies '((:rule "foot") (:rule "stream-term"))
               :app-ids '("emacs" "stream-term")
               :policies '((:rule "foot"))))

(fiasco:deftest window-slot-policies-imply-slots ()
  (is-settings (3 '("emacs"))
               :app-ids '("emacs") :policies '(nil nil (:follow-focus))))

(fiasco:deftest window-slot-policies-apply-to-env-apps ()
  (is-policies '((:rule "a") (:follow-focus))
               :env-apps "a,b" :policies '(nil (:follow-focus))))

(fiasco:deftest window-slot-policies-env-zero-turns-everything-off ()
  (is-settings (0 nil) :env-count "0" :policies '((:follow-focus)))
  (is-policies nil :env-count "0" :policies '((:follow-focus))))

(fiasco:deftest window-slot-policies-config-rejects-bad-policies ()
  (dolist (bad '(((:bogus))
                 ((:rule))
                 ((:rule emacs))
                 ((:rule "a" "b"))
                 ((:follow-focus :deny (emacs)))
                 ((:follow-focus :allow ("a")))
                 ((:follow-focus :deny "a"))
                 (:rule "emacs")
                 "emacs"))
    (fiasco:signals config-system:invalid-datum-error
      (config-system:set-config mh::*window-slot-policies* bad))))

(fiasco:deftest window-slot-policies-config-accepts-good-policies ()
  (let ((old mh::*window-slot-policies*))
    (unwind-protect
         (fiasco:finishes
           (config-system:set-config mh::*window-slot-policies*
                                     '(nil (:rule "emacs") (:follow-focus)
                                       (:follow-focus :deny ("a" "b")))))
      (config-system:set-config mh::*window-slot-policies* old))))

(defun %policy-calls (policies)
  "Apply POLICIES to the fake server :SERVER with the C setters replaced;
return the calls made, oldest first."
  (let ((calls '()))
    (cl-mock:dflet ((hrt::window-slot-set-rule (server index app-id)
                      (push (list :rule server index app-id) calls)
                      t)
                    (hrt::window-slot-set-follow-focus (server index follow)
                      (push (list :follow server index follow) calls)
                      t)
                    (hrt::window-slot-deny-app-id (server index app-id)
                      (push (list :deny server index app-id) calls)
                      t))
      (mh::%apply-window-slot-policies :server policies))
    (nreverse calls)))

(fiasco:deftest window-slot-rule-policies-set-the-c-rules ()
  ;; The same C calls the app-id list made before policies existed:
  (fiasco:is (equal '((:rule :server 0 "emacs") (:rule :server 1 "stream-term"))
                    (%policy-calls '((:rule "emacs") (:rule "stream-term"))))))

(fiasco:deftest window-slot-follow-focus-policy-sets-follow-and-deny-list ()
  (fiasco:is (equal '((:rule :server 0 "emacs")
                      (:follow :server 2 t)
                      (:deny :server 2 "com.obsproject.Studio")
                      (:deny :server 2 "org.keepassxc.KeePassXC"))
                    (%policy-calls
                     '((:rule "emacs") nil
                       (:follow-focus :deny ("com.obsproject.Studio"
                                             "org.keepassxc.KeePassXC")))))))

(fiasco:deftest window-slot-follow-focus-without-deny-list ()
  (fiasco:is (equal '((:follow :server 0 t))
                    (%policy-calls '((:follow-focus))))))
