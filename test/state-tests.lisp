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

;; A window that maps while there are zero outputs has no frame to go into.
;; The group must keep it as a hidden view, so that it is put into a frame as
;; soon as an output comes back instead of being left untiled forever.

(defmacro with-zero-output-stubs (() &body body)
  "Stub the foreign calls made while mapping a view and adding an output."
  `(mahogany/test/util:with-stubbed-functions
       ((hrt::hrt-view-set-hidden (view hidden))
        (hrt::hrt-view-set-size (view width height))
        (hrt::hrt-view-set-relative (view x y))
        (hrt::%commit-view-transaction ())
        (hrt::border-box-create (layer style x y width height) (cffi:null-pointer))
        (hrt:border-box-set-style (box style))
        (hrt:hrt-border-box-set-relative (box x y))
        (hrt:hrt-border-box-set-enabled (box enabled))
        (hrt:hrt-border-box-destroy (box))
        (hrt:hrt-border-box-set-size (box width height))
        (hrt:hrt-border-box-lower-to-bottom (box))
        (hrt:hrt-border-box-raise-to-top (box))
        (hrt:output-position (output) (values 0 0))
        (hrt:output-resolution (output) (values 1920 1080)))
     ,@body))

(defun %make-group-without-outputs ()
  (mahogany::%make-mahogany-group
   "test" 1 (cffi:null-pointer)
   (make-instance 'mahogany/tree:layer-container
                  :hrt-layer (cffi:null-pointer))))

(defun %make-view-in-group (group)
  (let ((view (mahogany/test/util:make-mock-view (cffi:null-pointer))))
    (push view (mahogany::mahogany-group-views group))
    view))

(defun %add-mock-output (group)
  (mahogany::group-add-output
   group
   (make-instance 'mahogany/tree:output-container
                  :output (mahogany/test/util:make-mock-output))))

(fiasco:deftest view-mapped-without-outputs-is-kept-hidden ()
  (with-zero-output-stubs ()
    (let* ((group (%make-group-without-outputs))
           (view (%make-view-in-group group)))
      (is (null (mahogany::mahogany-group-current-frame group)))
      (finishes (mahogany::group-map-view group view))
      (is (ring-list:contains-item (mahogany::mahogany-group-hidden-views group)
                                   view)))))

(fiasco:deftest view-mapped-without-outputs-is-tiled-when-output-added ()
  (with-zero-output-stubs ()
    (let* ((group (%make-group-without-outputs))
           (view (%make-view-in-group group)))
      (mahogany::group-map-view group view)
      (%add-mock-output group)
      (let ((frame (mahogany::mahogany-group-current-frame group)))
        (is (typep frame 'mahogany/tree:view-frame))
        (is (eq view (mahogany/tree:frame-surface frame)))
        (is (= 0 (ring-list:ring-list-size
                  (mahogany::mahogany-group-hidden-views group))))))))

(fiasco:deftest newest-view-mapped-without-outputs-is-tiled-first ()
  ;; FIRST was in a frame when the output went away, so removing the output
  ;; hid it. SECOND mapped afterwards, with zero outputs. When an output comes
  ;; back, the window the user opened last is the one shown.
  (with-zero-output-stubs ()
    (let* ((group (%make-group-without-outputs))
           (first-view (%make-view-in-group group))
           (second-view (%make-view-in-group group))
           (hidden (mahogany::mahogany-group-hidden-views group)))
      (mahogany::%add-hidden hidden first-view)
      (mahogany::group-map-view group second-view)
      (%add-mock-output group)
      (let ((frame (mahogany::mahogany-group-current-frame group)))
        (is (eq second-view (mahogany/tree:frame-surface frame)))
        (is (ring-list:contains-item hidden first-view))
        (is (not (ring-list:contains-item hidden second-view)))))))

(fiasco:deftest view-unmapped-without-outputs-is-forgotten ()
  ;; A window that maps and unmaps again while there are zero outputs must
  ;; not be put into a frame when an output comes back.
  (with-zero-output-stubs ()
    (let* ((group (%make-group-without-outputs))
           (view (%make-view-in-group group)))
      (mahogany::group-map-view group view)
      (mahogany::group-unmap-view group view)
      (is (not (ring-list:contains-item
                (mahogany::mahogany-group-hidden-views group) view)))
      (%add-mock-output group)
      (is (null (mahogany/tree:frame-surface
                 (mahogany::mahogany-group-current-frame group)))))))

;; The prefix key grabs the seat (STATE-GRAB-SEAT) and the next key releases
;; it (STATE-UNGRAB-SEAT); both also move the focus mark off and back onto the
;; current frame. With zero outputs there is no current frame, and marking NIL
;; has no method, which killed the compositor. The seat calls themselves are
;; inlined foreign calls, so the frame part is tested through the two helpers
;; the grab functions use.

(fiasco:deftest unfocus-current-frame-without-frame ()
  ;; No frame: nothing to unmark, and the seat is not touched.
  (let ((state (mahogany::make-mahogany-state)))
    (is (null (mahogany::state-%current-frame state)))
    (finishes (mahogany::%unfocus-current-frame state (cffi:null-pointer)))))

(fiasco:deftest focus-current-frame-without-frame ()
  (let ((state (mahogany::make-mahogany-state)))
    (is (null (mahogany::state-%current-frame state)))
    (finishes (mahogany::%focus-current-frame state (cffi:null-pointer)))))

(fiasco:deftest unfocus-and-focus-current-frame-with-frame ()
  ;; With a frame, the helpers still move the focus mark.
  (let ((state (mahogany::make-mahogany-state))
        (frame (make-instance 'mahogany/tree:frame :x 0 :y 0 :width 100 :height 100)))
    (setf (mahogany::state-%current-frame state) frame)
    (mahogany::%focus-current-frame state (cffi:null-pointer))
    (is (mahogany/tree::frame-focused frame))
    (mahogany::%unfocus-current-frame state (cffi:null-pointer))
    (is (not (mahogany/tree::frame-focused frame)))
    (mahogany::%focus-current-frame state (cffi:null-pointer))
    (is (mahogany/tree::frame-focused frame))))
