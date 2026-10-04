(in-package #:hrt)

;;; Window slots (heart/src/mirror.c, heart/include/hrt/hrt_window_slots.h).
;;;
;;; Declared by hand: hrt_window_slots.h is not in cffi/hrt-bindings.yml yet
;;; because cl-bindgen was not available when it was added. When the bindings
;;; are next regenerated, add the header to the yml and drop these.

(cffi:defcfun ("hrt_window_slots_create" window-slots-create) :bool
  "Create COUNT permanent window slots (REC-1 .. REC-COUNT). Call once,
before the server starts."
  (server :pointer)
  (count :int)
  (width :int)
  (height :int)
  (refresh-mhz :int))

(cffi:defcfun ("hrt_window_slot_count" window-slot-count) :int
  (server :pointer))

(cffi:defcfun ("hrt_window_slot_name" window-slot-name) :string
  "The output name of slot INDEX (0-based), e.g. \"REC-1\", or NIL."
  (server :pointer)
  (index :int))

(cffi:defcfun ("hrt_window_slot_assign" %window-slot-assign) :bool
  (server :pointer)
  (index :int)
  (view :pointer))

(defun window-slot-assign (server index view)
  "Show VIEW (a mapped hrt view) in slot INDEX. Returns T on success."
  (declare (type view view))
  (%window-slot-assign server index (view-hrt-view view)))

(cffi:defcfun ("hrt_window_slot_unassign" window-slot-unassign) :void
  (server :pointer)
  (index :int))

(cffi:defcfun ("hrt_window_slot_find_view" %window-slot-find-view) :int
  (server :pointer)
  (view :pointer))

(defun window-slot-find-view (server view)
  "The index of the slot showing VIEW, or NIL."
  (declare (type view view))
  (let ((index (%window-slot-find-view server (view-hrt-view view))))
    (when (>= index 0) index)))

(cffi:defcfun ("hrt_window_slot_set_rule" window-slot-set-rule) :bool
  "Put windows whose app_id is APP-ID into slot INDEX when they map
(NIL clears the rule)."
  (server :pointer)
  (index :int)
  (app-id :string))

(cffi:defcfun ("hrt_window_slot_ticks" window-slot-ticks) :long
  (server :pointer)
  (index :int))
