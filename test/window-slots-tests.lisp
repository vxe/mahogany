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
