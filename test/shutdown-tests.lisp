(fiasco:define-test-package #:mahogany-tests/shutdown
  (:use #:mahogany))

(in-package #:mahogany-tests/shutdown)

;; SBCL's default SIGTERM handler calls EXIT, which unwinds the Lisp stack from
;; wherever the signal arrived. When that is inside wl_signal_emit_mutable (an
;; output's frame signal fires every vblank), the emission's two marker links
;; stay in the signal's listener list, and destroying the output during the
;; cleanup asserts in wlr_output_finish. Mahogany's own handler only asks
;; the event loop to stop, so the cleanup starts after wl_display_run returns.

(fiasco:deftest sigterm-asks-running-event-loop-to-stop ()
  (let ((calls '()))
    (cl-mock:dflet ((mahogany::%request-event-loop-stop (server)
                      (push server calls)))
      (let ((mahogany::*event-loop-running* t))
        (mahogany::%handle-sigterm :the-server)))
    (is (equal '(:the-server) calls))))

(fiasco:deftest sigterm-outside-event-loop-does-nothing ()
  ;; Before the loop runs the handler is not installed; during the cleanup a
  ;; second SIGTERM must not touch a display that is being destroyed.
  (let ((calls '()))
    (cl-mock:dflet ((mahogany::%request-event-loop-stop (server)
                      (push server calls)))
      (let ((mahogany::*event-loop-running* nil))
        (finishes (mahogany::%handle-sigterm :the-server))))
    (is (null calls))))

;; SIGINT and SIGHUP stop the compositor too. Without a handler of our own,
;; SIGINT signals SB-SYS:INTERACTIVE-INTERRUPT, which unwinds out of
;; wl_display_run like SBCL's SIGTERM handler did, and SIGHUP kills the
;; process with no cleanup at all. So all three get the same handler.

(fiasco:deftest shutdown-signals-are-term-int-hup ()
  (is (equal (list sb-unix:sigterm sb-unix:sigint sb-unix:sighup)
             mahogany::*shutdown-signals*)))

(fiasco:deftest installing-takes-over-every-shutdown-signal ()
  (let ((installed '()))
    (cl-mock:dflet ((mahogany::%enable-shutdown-interrupt (signal server)
                      (push (list signal server) installed)))
      (let ((mahogany::*event-loop-running* nil))
        (mahogany::%install-shutdown-signal-handlers :the-server)
        (is (eq t mahogany::*event-loop-running*))))
    (is (equal (list (list sb-unix:sigterm :the-server)
                     (list sb-unix:sigint :the-server)
                     (list sb-unix:sighup :the-server))
               (reverse installed)))))
