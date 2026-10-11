(in-package #:hrt)

;; Hand-written bindings for the output modeline setters in
;; heart/include/hrt/hrt_output.h. They are kept out of the generated
;; hrt-bindings.lisp so that file can still be regenerated from the
;; headers as is. The modeline lives in a C side table keyed by the
;; config's address, so struct hrt_output_config keeps its layout.

(cffi:defcfun ("hrt_output_config_set_modeline" hrt-output-config-set-modeline) :void
  (config (:pointer (:struct hrt-output-config)))
  (clock-khz :int)
  (hdisplay :int)
  (hsync-start :int)
  (hsync-end :int)
  (htotal :int)
  (vdisplay :int)
  (vsync-start :int)
  (vsync-end :int)
  (vtotal :int)
  (flags :uint32))

(cffi:defcfun ("hrt_output_config_clear_modeline" hrt-output-config-clear-modeline) :void
  (config (:pointer (:struct hrt-output-config))))
