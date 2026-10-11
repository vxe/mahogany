(fiasco:define-test-package #:mahogany-tests/heart/output
  (:local-nicknames (#:alex #:alexandria))
  (:use #:mahogany/wm-interface
        #:mahogany/test/util))

(in-package #:mahogany-tests/heart/output)

(defmacro define-output-config-merge-test (name default override expected)
  (let ((def-symb (gensym "default"))
        (override-symb (gensym "override"))
        (expected-symb (gensym "expected")))
    `(fiasco:deftest ,name ()
       (let ((,def-symb (hrt:make-output-config ,@default))
             (,override-symb (hrt:make-output-config ,@override))
             (,expected-symb (hrt:make-output-config ,@expected)))
         (let ((result (hrt:output-config-merge ,def-symb ,override-symb)))
           (is (hrt::output-config= result ,expected-symb)))))))

(define-output-config-merge-test output-config-merge-handles-mode
	(:scale 2
     :refresh-rate 60
     :custom-mode t
     :dimensions (cons 600 600)
     :position (cons 20 20))
  (:scale 1
   :dimensions (cons 1080 960)
   :refresh-rate 90)
  (:scale 1
   :dimensions (cons 1080 960)
   :refresh-rate 90
   :custom-mode nil
   :position (cons 20 20)))

(define-output-config-merge-test output-config-merge-basic
    (:scale 1)
  (:scale 2)
  (:scale 2))

(define-output-config-merge-test output-config-merge-enabled
    (:enabled t)
  (:enabled nil)
  (:enabled nil))

(defun %panel-50hz-modeline ()
  (hrt:make-modeline :clock 165170
                     :hdisplay 1920 :hsync-start 1968 :hsync-end 2000 :htotal 2220
                     :vdisplay 1080 :vsync-start 1083 :vsync-end 1089 :vtotal 1488
                     :flags #x9))

(define-output-config-merge-test output-config-merge-override-modeline-replaces-mode
    (:dimensions (cons 600 600)
     :refresh-rate 60
     :custom-mode t)
  (:dimensions (cons 1920 1080)
   :modeline (%panel-50hz-modeline))
  (:dimensions (cons 1920 1080)
   :modeline (%panel-50hz-modeline)))

(define-output-config-merge-test output-config-merge-keeps-base-modeline
    (:dimensions (cons 1920 1080)
     :modeline (%panel-50hz-modeline))
  (:scale 2)
  (:scale 2
   :dimensions (cons 1920 1080)
   :modeline (%panel-50hz-modeline)))

(define-output-config-merge-test output-config-merge-override-mode-drops-modeline
    (:dimensions (cons 1920 1080)
     :modeline (%panel-50hz-modeline))
  (:dimensions (cons 1280 720)
   :refresh-rate 60)
  (:dimensions (cons 1280 720)
   :refresh-rate 60))

(fiasco:deftest output-config=-compares-modeline ()
  (let ((with (hrt:make-output-config :dimensions (cons 1920 1080)
                                      :modeline (%panel-50hz-modeline)))
        (with-2 (hrt:make-output-config :dimensions (cons 1920 1080)
                                        :modeline (%panel-50hz-modeline)))
        (without (hrt:make-output-config :dimensions (cons 1920 1080))))
    (is (hrt:output-config= with with-2))
    (is (not (hrt:output-config= with without)))))
