(in-package :cl-async)

(defun event-handler (error event-cb &key socket catch-errors)
  "Called when an event (error, mainly) occurs."
  ;; here we check if errno is actually an event/error object passed in
  ;; directly. if so, we kindly forward it along to the event-cb.
  (let* ((errno (when (numberp error) error))
         (event (unless (numberp error) error))
         (errstr (when errno (error-str errno))))
    (macrolet ((do-handle (catch-p)
                 `(unwind-protect
                       (cond
                         ;; if we passed in an event, do nothing
                         (event nil)
                         ((= errno (uv:errval :etimedout))
                          (setf event (make-instance 'tcp-timeout :socket socket :code errno :msg "connection timed out")))
                         ((= errno (uv:errval :econnreset))
                          (setf event (make-instance 'tcp-reset :socket socket :code errno :msg "connection reset")))
                         ((= errno (uv:errval :econnrefused))
                          (setf event (make-instance 'tcp-refused :socket socket :code errno :msg "connection refused")))
                         ((= errno (uv:errval :eof))
                          (setf event (make-instance 'tcp-eof :socket socket)))
                         ((= errno (uv:errval :eai-noname))
                          (setf event (make-instance 'dns-error :code errno :msg "DNS lookup fail")))
                         ((= errno (uv:errval :efault))
                          (setf event (make-instance 'event-error :code errno :msg "bad address in system call argument")))
                         (t
                          (setf event (make-instance 'event-error :code errno :msg errstr))))
                    (when event
                      (unwind-protect
                           (when event-cb
                             ,(if catch-p
                                  '(run-event-cb event-cb event)
                                  '(funcall event-cb event)))
                        ;; if the app closed the socket in the event cb (perfectly fine),
                        ;; make sure we don't trigger an error trying to close it again.
                        (handler-case (and socket (close-socket socket :force t))
                          (socket-closed () nil)))))))
      (if catch-errors
          (catch-app-errors event-cb (do-handle t))
          (do-handle nil)))))

(defun add-event-loop-exit-callback (fn)
  "Add a function to be run when the event loop exits."
  (push fn (event-base-exit-functions *event-base*)))

(defun process-event-loop-exit-callbacks ()
  "run and clear out all event loop exit functions."
  (dolist (fn (event-base-exit-functions *event-base*))
    (funcall fn))
  (setf (event-base-exit-functions *event-base*) nil))

(defun check-event-loop-running ()
  (unless (and *event-base* (event-base-c *event-base*))
    (error "Event loop not running. Start with function start-event-loop.")))

(defgeneric ref (handle)
  (:documentation
    "Reference a libuv handle object (uv_ref)"))

(defgeneric unref (handle)
  (:documentation
    "Unreference a libuv handle object (uv_unref)"))

(defun stats ()
  "Return statistics about the current event loop."
  (list :open-dns-queries (event-base-dns-ref-count *event-base*)
        :fn-registry-count (hash-table-count *function-registry*)
        :data-registry-count (hash-table-count *data-registry*)
        :incoming-tcp-connections (event-base-num-connections-in *event-base*)
        :outgoing-tcp-connections (event-base-num-connections-out *event-base*)))

(define-c-callback walk-cb :void ((handle :pointer) (arg :pointer))
  "Called when we're walking the loop."
  (declare (ignore arg))
  (format t "handle: ~s (~a)~%" (uv:handle-type handle) handle)
  (force-output))

(defun dump-event-loop-status ()
  "Return the status of the event loop. Really a debug function more than
   anything else."
  (check-event-loop-running)
  (uv:uv-walk (event-base-c *event-base*) (cffi:callback walk-cb) (cffi:null-pointer)))

(defvar *event-base-registry* (make-hash-table :test 'eq)
  "Holds ID -> event-base lookups for every active event loop. Mainly used when
   grabbing the threading context for a particular event loop.")

(defvar *event-base-registry-lock* (bt:make-lock)
  "Locks the event-base registry.")

(define-c-callback loop-exit-walk-cb :void ((handle :pointer) (arg :pointer))
  "Called when we want to close the loop AND IT WONT CLOSE. So we walk each
   handle and close them."
  (declare (ignore arg))
  (case (uv:handle-type handle)
    (:tcp (let* ((data (deref-data-from-pointer handle))
                 (socket/server (if (listp data)
                                    (getf data :socket)
                                    data)))
            (cond ((null data)
                   ;; this may happen, for example, when tcp-connect
                   ;; fails somewhere in the middle due to a bug
                   (warn "a tcp handle without corresponding object detected")
                   (do-close-tcp handle :force t))
                  ((typep socket/server 'tcp-server)
                   (unless (tcp-server-closed socket/server)
                     (close-tcp-server socket/server)))
                  ((not (socket-closed-p socket/server))
                   (close-socket socket/server :force t)))))
    (:timer (let ((event (deref-data-from-pointer handle)))
              (unless (event-freed-p event)
                (free-event event))))
    (:async (let ((notifier (deref-data-from-pointer handle)))
              (unless (notifier-freed-p notifier)
                (free-notifier notifier))))))

(defun do-close-loop (evloop &optional (loops 0))
  "Close an event loop by looping over its open handles, closing them, rinsing
   and repeating until uv-loop-close returns 0."
  (process-event-loop-exit-callbacks)
  (let ((res (uv:uv-loop-close evloop)))
    (unless (zerop res)
      (uv:uv-stop evloop)
      (uv:uv-walk evloop (cffi:callback loop-exit-walk-cb) (cffi:null-pointer))
      (uv:uv-run evloop (cffi:foreign-enum-value 'uv:uv-run-mode :+uv-run-default+))
      (uv:uv-run evloop (cffi:foreign-enum-value 'uv:uv-run-mode :+uv-run-default+))
      (do-close-loop evloop (1+ loops)))))

(defun start-event-loop (start-fn &key default-event-cb (catch-app-errors nil catch-app-errors-supplied-p))
  "Simple wrapper function that starts an event loop which runs the given
   callback, most likely to init your server/client."
  (when *event-base*
    (error "Event loop already started. Please wait for it to exit."))
  (cffi:with-foreign-object (loop :unsigned-char (uv:uv-loop-size))
    (uv:uv-loop-init loop)
    ;; note the binding of these variable via (let), which means they are thread-
    ;; local... so this function can be called in different threads, and the bound
    ;; variables won't interfere with each other.
    (let* ((*event-base* (apply #'make-instance
                                (append
                                  (list 'event-base
                                        :c loop
                                        :id *event-base-next-id*)
                                  (when catch-app-errors-supplied-p
                                    (list :catch-app-errors catch-app-errors))
                                  (when (functionp default-event-cb)
                                    (list :default-event-handler default-event-cb)))))
           (*buffer-writes* *buffer-writes*)
           (*buffer-size* *buffer-size*)
           (*output-buffer* (static-vectors:make-static-vector *buffer-size* :element-type 'octet))
           (*input-buffer* (static-vectors:make-static-vector *buffer-size* :element-type 'octet))
           (*data-registry* (event-base-data-registry *event-base*))
           (*function-registry* (event-base-function-registry *event-base*))
           (callbacks nil))
      (incf *event-base-next-id*)
      (delay start-fn)
      ;; this is the once instance where we assign callbacks to an event loop object
      ;; instead of a data-pointer since the callbacks don't take any void* args,
      ;; meaning we have to dereference from the global (event-base-c *event-base*) object.
      (save-callbacks (event-base-c *event-base*) callbacks)
      (bt:with-lock-held (*event-base-registry-lock*)
        (setf (gethash (event-base-id *event-base*) *event-base-registry*) *event-base*))
      (unwind-protect
        (progn
          ;; this will block until all events are processed
          (uv:uv-run (event-base-c *event-base*) (cffi:foreign-enum-value 'uv:uv-run-mode :+uv-run-default+)))
        ;; cleanup
        (do-close-loop (event-base-c *event-base*))
        (static-vectors:free-static-vector *output-buffer*)
        (static-vectors:free-static-vector *input-buffer*)
        (free-pointer-data (event-base-c *event-base*) :preserve-pointer t)
        (bt:with-lock-held (*event-base-registry-lock*)
          (remhash (event-base-id *event-base*) *event-base-registry*))
        (setf *event-base* nil)))))

(defmacro with-event-loop ((&key default-event-cb (catch-app-errors nil catch-app-errors-supplied-p))
                           &body body)
  "Makes starting an event loop a tad less annoying. I really couldn't take
   typing out `(start-event-loop (lambda () ...) ...) every time. Example:

     (with-event-loop (:catch-app-errors t)
       (do-something-one-does-when-an-event-loop-is-running))

   See how nice that is?"
  (append
    `(as:start-event-loop (lambda () ,@body)
       :default-event-cb ,default-event-cb)
    (when catch-app-errors-supplied-p
      `(:catch-app-errors ,catch-app-errors))))

(defun exit-event-loop ()
  "Exit the event loop if running."
  (let ((evloop (event-base-c *event-base*)))
    (when evloop
      (uv:uv-stop evloop))))
