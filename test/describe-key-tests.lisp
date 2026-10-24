(fiasco:define-test-package #:mahogany-tests/describe-key
  (:use #:mahogany/keyboard))

(in-package #:mahogany-tests/describe-key)

(defmacro with-stubs ((&rest stubs) &body body)
  "Temporarily replace global functions. Each stub is (NAME LAMBDA-LIST . BODY)."
  (let ((saved (loop :for s :in stubs :collect (gensym (symbol-name (car s))))))
    `(let ,(loop :for s :in stubs :for g :in saved
                 :collect `(,g (fdefinition ',(car s))))
       (unwind-protect
            (progn
              ,@(loop :for (name args . fbody) :in stubs
                      :collect `(setf (fdefinition ',name) (lambda ,args ,@fbody)))
              ,@body)
         ,@(loop :for s :in stubs :for g :in saved
                 :collect `(setf (fdefinition ',(car s)) ,g))))))

(defun keys (&rest descs)
  (mapcar #'kbd descs))

(fiasco:deftest describe-message-names-the-command-and-its-doc ()
  (let ((msg (mahogany::%describe-key-message (keys "C-t" "h" "k")
                                              #'mahogany::describe-key)))
    (is (eql 0 (search "C-t h k runs describe-key" msg)))
    (is (search "Show what the next key sequence pressed is bound to" msg))))

(fiasco:deftest describe-message-unbound ()
  (is (string= "C-t z is not bound."
               (mahogany::%describe-key-message (keys "C-t" "z") nil))))

(fiasco:deftest describe-message-pass-through ()
  (is (string= "C-t C-t is passed to the focused window."
               (mahogany::%describe-key-message (keys "C-t" "C-t") :pass-through))))

(fiasco:deftest root-map-h-k-is-describe-key ()
  (let ((state (make-key-state (list mahogany::*root-map*))))
    (is (equal '(t nil) (multiple-value-list (key-state-advance (kbd "h") state))))
    (is (equal (list t #'mahogany::describe-key)
               (multiple-value-list (key-state-advance (kbd "k") state))))))

(defun run-keys-describing (kmaps descs)
  "Press DESCS through CHECK-AND-RUN-KEYBINDING with describe mode on.
Returns (values consumed-list messages executed-commands describe-flag)."
  (let ((messages '())
        (executed '())
        (consumed '())
        (state (make-key-state kmaps)))
    (with-stubs ((mahogany::state-ungrab-seat (s) (declare (ignore s)))
                 (mahogany::state-grab-seat (s) (declare (ignore s)))
                 (mahogany::server-keystate-reset (s) (declare (ignore s)))
                 (mahogany::toast-message (s text &rest r)
                   (declare (ignore s r)) (push text messages))
                 (mahogany::execute-command (cmd seq seat)
                   (declare (ignore seq seat)) (push cmd executed)))
      (setf mahogany::*describe-next-key* t)
      (unwind-protect
           (progn
             (dolist (d descs)
               (push (mahogany::check-and-run-keybinding (kbd d) nil state) consumed))
             (values (nreverse consumed) messages executed mahogany::*describe-next-key*))
        (setf mahogany::*describe-next-key* nil)))))

(fiasco:deftest describing-a-bound-sequence-does-not-run-it ()
  (let ((map (define-kmap (kbd "C-t") (define-kmap (kbd "n") #'mahogany::next-view))))
    (multiple-value-bind (consumed messages executed flag)
        (run-keys-describing (list map) '("C-t" "n"))
      (is (equal '(t t) consumed))
      (is (null executed))
      (is (null flag))
      (is (= 1 (length messages)))
      (is (eql 0 (search "C-t n runs next-view" (first messages)))))))

(fiasco:deftest describing-an-undefined-sequence ()
  (let ((map (define-kmap (kbd "C-t") (define-kmap (kbd "n") #'mahogany::next-view))))
    (multiple-value-bind (consumed messages executed flag)
        (run-keys-describing (list map) '("C-t" "z"))
      (is (equal '(t t) consumed))
      (is (null executed))
      (is (null flag))
      (is (equal '("C-t z is not bound.") messages)))))

(fiasco:deftest describing-an-unbound-top-level-key-consumes-it ()
  (multiple-value-bind (consumed messages executed flag)
      (run-keys-describing (list (define-kmap)) '("a"))
    (is (equal '(t) consumed))
    (is (null executed))
    (is (null flag))
    (is (equal '("a is not bound.") messages))))

(fiasco:deftest describe-mode-off-still-runs-commands ()
  (let ((map (define-kmap (kbd "C-t") (define-kmap (kbd "n") #'mahogany::next-view)))
        (executed '()))
    (with-stubs ((mahogany::state-ungrab-seat (s) (declare (ignore s)))
                 (mahogany::state-grab-seat (s) (declare (ignore s)))
                 (mahogany::server-keystate-reset (s) (declare (ignore s)))
                 (mahogany::execute-command (cmd seq seat)
                   (declare (ignore seq seat)) (push cmd executed)))
      (setf mahogany::*describe-next-key* nil)
      (let ((state (make-key-state (list map))))
        (mahogany::check-and-run-keybinding (kbd "C-t") nil state)
        (mahogany::check-and-run-keybinding (kbd "n") nil state)))
    (is (equal (list #'mahogany::next-view) executed))))
