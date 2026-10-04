(fiasco:define-test-package #:mahogany-tests/state
  (:use #:mahogany))

(in-package #:mahogany-tests/state)

;; When the session is switched away (VT switch), the DRM backend destroys
;; every output, so groups are left without a current frame. A client can still
;; map or unmap a window in that state; both paths refresh focus through
;; %CUR-FRAME-SET-FROM-GROUP, which must not try to focus a frame that does
;; not exist.

(fiasco:deftest mark-frame-focused-rejects-no-frame ()
  ;; This is the error that killed the compositor: focusing NIL has no method.
  (signals error (mahogany/tree:mark-frame-focused nil (cffi:null-pointer))))

(fiasco:deftest cur-frame-set-from-group-without-frame ()
  ;; No frame means there is nothing to focus, so the seat (a foreign object,
  ;; unavailable in the test image) must not even be looked up.
  (let ((state (mahogany::make-mahogany-state))
        (group (mahogany::%make-mahogany-group
                "test" 1 (cffi:null-pointer)
                (make-instance 'mahogany/tree:layer-container
                               :hrt-layer (cffi:null-pointer)))))
    (is (null (mahogany::mahogany-group-current-frame group)))
    (finishes (mahogany::%cur-frame-set-from-group state group))
    (is (null (mahogany::state-%current-frame state)))))
