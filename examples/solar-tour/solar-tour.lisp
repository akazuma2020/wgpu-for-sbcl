;;;; solar-tour.lisp -- 戦闘のない映画的な太陽系ツアー。

(defparameter *solar-tour-directory*
  (uiop:pathname-directory-pathname (or *load-truename* *compile-file-truename*)))

(pushnew (truename (merge-pathnames "../../" *solar-tour-directory*))
         asdf:*central-registry* :test #'equal)
(asdf:load-system :wgpu)
(asdf:load-system :wgpu/sdl2)
(ql:quickload :bordeaux-threads)

(defpackage :solar-tour
  (:use :cl)
  (:export :main :run-main-thread :*main-thread* :*spot-duration* :*warp-duration*))
(in-package :solar-tour)

(defparameter *window-width* 800)
(defparameter *window-height* 600)
(defparameter *present-mode* :fifo)
(defparameter *show-orbit* nil)
(defparameter *top-view* nil)
(defparameter *spot-duration* 180.0f0)
(defparameter *warp-duration* 6.0f0)
(defparameter *frame-warp* 0.0f0)
(defparameter *main-thread* nil)
(defparameter *destinations*
  #("SUN" "MERCURY" "VENUS" "EARTH" "MOON"
    "MARS" "JUPITER" "SATURN" "URANUS" "NEPTUNE"))
(defconstant +uniform-size+ 64)

(defparameter *shader-compile-log-path*
  (merge-pathnames "solar-tour-shader-compile.log" cl-user::*solar-tour-directory*))

(defun scancode-is (keysym name)
  (sdl2:scancode= (sdl2:scancode-value keysym) name))

(defun key-down-p (keys key)
  (gethash key keys nil))

(defun clampf (value low high)
  (max low (min high value)))

(defmacro startup-step (&body body)
  `(progn
     (sdl2:pump-events)
     (prog1 (progn ,@body)
       (sdl2:pump-events))))

(defstruct tour-resources
  uniform blur
  space-pipeline space-bind-group
  star-pipeline star-bind-group star-buffer star-count
  orbit-pipeline orbit-bind-group
  planet-pipeline planet-bind-group planet-vertex-buffer planet-index-buffer planet-index-count
  ring-pipeline ring-bind-group ring-vertex-buffer ring-index-buffer ring-index-count
  warp-pipeline warp-bind-group warp-buffer warp-count)

;; These functions are defined on opposite sides of the optional blur module load.
(declaim (ftype function init-warp-blur emit-tour-bodies))

(defun make-uv-sphere-mesh (&key (slices 64) (stacks 32))
  "Create an indexed unit sphere with position, normal and UV per vertex."
  (let* ((columns (1+ slices))
         (vertex-count (* (1+ stacks) columns))
         (vertices (make-array (* vertex-count 8) :element-type 'single-float))
         (indices (make-array (* stacks slices 6) :element-type '(unsigned-byte 32)))
         (vi 0)
         (ii 0))
    (loop for stack from 0 to stacks do
      (let* ((v (/ (float stack 1.0f0) stacks))
             (theta (* (float pi 1.0f0) v))
             (y (cos theta))
             (ring (sin theta)))
        (loop for slice from 0 to slices do
          (let* ((u (/ (float slice 1.0f0) slices))
                 (phi (* 2.0f0 (float pi 1.0f0) u))
                 (x (* ring (cos phi)))
                 (z (* ring (sin phi))))
            (dolist (value (list x y z x y z u v))
              (setf (aref vertices vi) (float value 1.0f0))
              (incf vi))))))
    (dotimes (stack stacks)
      (dotimes (slice slices)
        (let* ((a (+ (* stack columns) slice))
               (b (1+ a))
               (c (+ a columns))
               (d (1+ c)))
          ;; The projection looks along +Z, while the pipeline uses CCW front
          ;; faces. Reverse the sphere winding so the near hemisphere survives
          ;; back-face culling; normals remain outward for solar lighting.
          (dolist (index (list a c b b c d))
            (setf (aref indices ii) index)
            (incf ii)))))
    (values vertices indices)))

(defun make-ring-mesh (&optional (segments 192))
  "Create a unit annulus. The shader scales and tilts it around Saturn."
  (let ((vertices (make-array (* (1+ segments) 2 8) :element-type 'single-float))
        (indices (make-array (* segments 6) :element-type '(unsigned-byte 32)))
        (vi 0)
        (ii 0))
    (loop for segment from 0 to segments do
      (let* ((fraction (/ (float segment 1.0f0) segments))
             (angle (* fraction 2.0f0 (float pi 1.0f0)))
             (x (cos angle))
             (z (sin angle)))
        ;; NASA/NSSDCによる土星赤道半径に対する主環の比率。
        ;; C環内端は1.239倍、A環外端は2.270倍。
        (dolist (radius '(1.239f0 2.270f0))
          (dolist (value (list (* x radius) 0.0f0 (* z radius)
                               0.0f0 1.0f0 0.0f0
                               (/ (- radius 1.239f0) 1.031f0) fraction))
            (setf (aref vertices vi) (float value 1.0f0))
            (incf vi)))))
    (dotimes (segment segments)
      (let ((a (* segment 2))
            (b (1+ (* segment 2)))
            (c (+ 2 (* segment 2)))
            (d (+ 3 (* segment 2))))
        (dolist (index (list a b c b d c))
          (setf (aref indices ii) index)
          (incf ii))))
    (values vertices indices)))

(defun make-star-mesh (&optional (star-count 28800))
  "Create fixed stars plus a second catalogue emitted from the warp centre.
A negative size marks the otherwise identical emitted copy in the shader."
  (let* ((segments 12)
         (vertices (make-array (* star-count 2 segments 3 7)
                               :element-type 'single-float))
        (seed #x6d2b79f5)
        (offset 0))
    (labels ((random-unit ()
               (setf seed (ldb (byte 32 0) (+ (* seed 1664525) 1013904223)))
               (/ (float seed 1.0d0) 4294967296.0d0))
             (put (value)
               (setf (aref vertices offset) (float value 1.0f0))
               (incf offset))
             (emit (x y z corner-x corner-y size temperature)
               (put x) (put y) (put z)
               (put corner-x) (put corner-y)
               (put size) (put temperature)))
      (dotimes (star star-count)
        (declare (ignorable star))
        (let* ((band-star-p (< (random-unit) 0.62d0))
               (angle (* 2.0d0 pi (random-unit)))
               ;; 星表の約62%を広く傾いた大円に沿って配置する。
               ;; 緯度を三角分布にし、帯の境界を目立たせず天の川に星を増やす。
               (latitude-y (if band-star-p
                               (* 0.22d0 (- (random-unit) (random-unit)))
                               (- (* 2.0d0 (random-unit)) 1.0d0)))
               (radial (sqrt (max 0.0d0 (- 1.0d0 (* latitude-y latitude-y)))))
               (base-x (* radial (cos angle)))
               (base-z (* radial (sin angle)))
               (tilt 0.55d0)
               (x (- (* (cos tilt) base-x) (* (sin tilt) latitude-y)))
               (y (+ (* (sin tilt) base-x) (* (cos tilt) latitude-y)))
               (z base-z)
               (size-roll (random-unit))
               ;; 大半の星は意図的に画素未満の暗さにする。
               ;; 一部を見える明るさにし、ごく少数だけ柔らかな光輪を付ける。
               (size (cond ((< size-roll 0.805d0)
                            (+ 0.58d0 (* 0.62d0 (random-unit))))
                           ((< size-roll 0.985d0)
                            (+ 1.20d0 (* 1.15d0 (random-unit))))
                           (t
                            (+ 2.75d0 (* 3.35d0
                                         (expt (random-unit) 0.55d0))))))
               (temperature (random-unit)))
          ;; 正のサイズは固定された星空。負のサイズは消失点から現れるワープ星で、
          ;; 固定星表を内側へ引き伸ばしたものではない。
          (dolist (signed-size (list size (- size)))
            (dotimes (segment segments)
              (let* ((angle0 (* 2.0d0 pi (/ segment segments)))
                     (angle1 (* 2.0d0 pi (/ (1+ segment) segments))))
                (emit x y z 0.0f0 0.0f0 signed-size temperature)
                (emit x y z (cos angle0) (sin angle0) signed-size temperature)
                (emit x y z (cos angle1) (sin angle1) signed-size temperature)))))))
    vertices))

(defun warp-envelope (scene-time)
  (if (< scene-time *spot-duration*)
      0.0f0
      (let ((phase (clampf (/ (- scene-time *spot-duration*)
                              *warp-duration*)
                           0.0f0 1.0f0)))
        (sin (* (float pi 1.0f0) phase)))))

(defun update-title (window destination scene-time paused fps)
  (let* ((warping-p (>= scene-time *spot-duration*))
         (remaining (max 0 (ceiling (- *spot-duration* scene-time))))
         (status (if warping-p "WARPING"
                     (format nil "~D s to warp" remaining))))
    (sdl2:set-window-title
     window
     (format nil "Solar System Tour | ~A | ~A | ~,0F fps"
             (aref *destinations* destination)
             (if paused "PAUSED" status)
             fps))))

(defun write-uniforms (context uniform width height elapsed scene-time warp
                       destination yaw pitch roll thrust progress warp-phase
                       random-seed)
  (setf *frame-warp* warp)
  (wgpu:write-uniform-fields
   context uniform
   (wgpu:vec2f (float width 1.0f0) (float height 1.0f0)) :vec2f
   (float elapsed 1.0f0)                                  :float
   (float scene-time 1.0f0)                               :float
   (float warp 1.0f0)                                     :float
   destination                                            :uint32
   (float yaw 1.0f0)                                      :float
   (float pitch 1.0f0)                                    :float
   (float roll 1.0f0)                                     :float
   (float thrust 1.0f0)                                   :float
   (float progress 1.0f0)                                 :float
   (float warp-phase 1.0f0)                               :float
   (float random-seed 1.0f0)                              :float
   (if *show-orbit* 1 0)                                  :uint32
   (if *top-view* 1 0)                                    :uint32))

(defun init-tour (context shader)
  (let* ((module (startup-step (wgpu:create-shader-module context shader)))
         (messages (wgpu:log-compile-messages
                    context module "solar-tour.wgsl" *shader-compile-log-path*)))
    (when (and messages (plusp (length messages)))
      (format t "~&[solar-tour] shader messages (see ~A):~%~A"
              *shader-compile-log-path* messages)
      (finish-output))
    (multiple-value-bind (planet-vertices planet-indices) (make-uv-sphere-mesh)
      (multiple-value-bind (ring-vertices ring-indices) (make-ring-mesh)
        (let* ((stars (make-star-mesh))
               (uniform (wgpu:create-buffer
                         context
                         (wgpu:usage-flags wgpu:+usage-uniform+ wgpu:+usage-copy-dst+)
                         +uniform-size+ "Solar tour uniforms"))
               (mesh-attributes
                (list (list (wgpu:vertex-format :float32x3) 0 0)
                      (list (wgpu:vertex-format :float32x3) 12 1)
                      (list (wgpu:vertex-format :float32x2) 24 2)))
               (space-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "spaceVS" "spaceFS"
                 :sample-count 4 :vertex-stride 8
                 :attributes
                 (list (list (wgpu:vertex-format :float32x2) 0 0))
                 :cull-mode (wgpu:cull-mode :none)
                 :depth-enabled t)))
               (star-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "starVS" "starFS"
                 :sample-count 4 :vertex-stride 28
                 :attributes
                 (list (list (wgpu:vertex-format :float32x3) 0 0)
                       (list (wgpu:vertex-format :float32x2) 12 1)
                       (list (wgpu:vertex-format :float32) 20 2)
                       (list (wgpu:vertex-format :float32) 24 3))
                 :cull-mode (wgpu:cull-mode :none)
                 ;; Background stays on the far plane so even the very distant
                 ;; Moon-scene Earth orbit can pass the depth test.
                 :depth-enabled t :blend-enabled t)))
               (orbit-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "orbitVS" "orbitFS"
                 :sample-count 4 :vertex-stride 8
                 :attributes (list (list (wgpu:vertex-format :float32x2) 0 0))
                 :cull-mode (wgpu:cull-mode :none)
                 :depth-enabled t :blend-enabled t)))
               (planet-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "planetVS" "planetFS"
                 :sample-count 4 :vertex-stride 32 :attributes mesh-attributes
                 :cull-mode (wgpu:cull-mode :back)
                 :depth-enabled t)))
               (ring-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "ringVS" "ringFS"
                 :sample-count 4 :vertex-stride 32 :attributes mesh-attributes
                 :cull-mode (wgpu:cull-mode :none)
                 :depth-enabled t :blend-enabled t)))
               (warp-pipeline
                (startup-step (wgpu:create-vertex-render-pipeline
                 context module "warpVS" "warpFS"
                 :sample-count 4 :vertex-stride 8
                 :attributes
                 (list (list (wgpu:vertex-format :float32x2) 0 0))
                 :cull-mode (wgpu:cull-mode :none)
                 :depth-enabled t :blend-enabled t)))
               (buffer-usage
                (wgpu:usage-flags wgpu:+usage-vertex+ wgpu:+usage-copy-dst+))
               (index-usage
                (wgpu:usage-flags wgpu:+usage-index+ wgpu:+usage-copy-dst+)))
          (init-warp-blur context module (make-tour-resources
           :uniform uniform
           :space-pipeline space-pipeline
           :space-bind-group
           (wgpu:create-render-bind-group
            context space-pipeline (wgpu:bindings 0 uniform) "Space background bind group")
           :star-pipeline star-pipeline
           :star-bind-group
           (wgpu:create-render-bind-group
            context star-pipeline (wgpu:bindings 0 uniform) "Star bind group")
           :star-buffer
           (wgpu:create-buffer-with-data
            context buffer-usage stars (* 4 (length stars)) "Irregular star field")
           :star-count (/ (length stars) 7)
           :orbit-pipeline orbit-pipeline
           :orbit-bind-group
           (wgpu:create-render-bind-group
            context orbit-pipeline (wgpu:bindings 0 uniform) "Orbit bind group")
           :planet-pipeline planet-pipeline
           :planet-bind-group
           (wgpu:create-render-bind-group
            context planet-pipeline (wgpu:bindings 0 uniform) "Planet bind group")
           :planet-vertex-buffer
           (wgpu:create-buffer-with-data
            context buffer-usage planet-vertices (* 4 (length planet-vertices))
            "Planet sphere vertices")
           :planet-index-buffer
           (wgpu:create-buffer-with-data
            context index-usage planet-indices (* 4 (length planet-indices))
            "Planet sphere indices")
           :planet-index-count (length planet-indices)
           :ring-pipeline ring-pipeline
           :ring-bind-group
           (wgpu:create-render-bind-group
            context ring-pipeline (wgpu:bindings 0 uniform) "Saturn ring bind group")
           :ring-vertex-buffer
           (wgpu:create-buffer-with-data
            context buffer-usage ring-vertices (* 4 (length ring-vertices))
            "Saturn ring vertices")
           :ring-index-buffer
           (wgpu:create-buffer-with-data
            context index-usage ring-indices (* 4 (length ring-indices))
            "Saturn ring indices")
           :ring-index-count (length ring-indices)
           :warp-pipeline warp-pipeline
           :warp-bind-group
           (wgpu:create-render-bind-group
            context warp-pipeline (wgpu:bindings 0 uniform) "Warp overlay bind group")
           :warp-buffer
           (let ((triangle (make-array 6 :element-type 'single-float
                                       :initial-contents
                                       '(-1.0f0 -1.0f0 3.0f0 -1.0f0 -1.0f0 3.0f0))))
             (wgpu:create-buffer-with-data
              context buffer-usage triangle (* 4 (length triangle))
              "Warp fullscreen triangle"))
           :warp-count 3)))))))

(load (merge-pathnames "warp-blur.lisp" cl-user::*solar-tour-directory*))

(defun emit-tour-bodies (draws resources &optional offscreen)
      (wgpu:emit draws wgpu:+render-set-pipeline+
                 :object (if offscreen (warp-blur-planet-pipeline (tour-resources-blur resources)) (tour-resources-planet-pipeline resources)))
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                 :object (if offscreen (warp-blur-planet-bind (tour-resources-blur resources)) (tour-resources-planet-bind-group resources)))
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                 :object (tour-resources-planet-vertex-buffer resources))
      (wgpu:emit draws wgpu:+render-set-index-buffer+
                 :x (wgpu:index-format :uint32)
                 :object (tour-resources-planet-index-buffer resources))
      ;; 0:目的地、1:衛星0、2:太陽、3:月の場面の地球、4～6:衛星1～3。
      ;; 使用しない衛星スロットはシェーダーでクリップする。
      (wgpu:emit draws wgpu:+render-draw-indexed+
                 :x (tour-resources-planet-index-count resources) :y 7)

      (wgpu:emit draws wgpu:+render-set-pipeline+
                 :object (if offscreen (warp-blur-ring-pipeline (tour-resources-blur resources)) (tour-resources-ring-pipeline resources)))
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                 :object (if offscreen (warp-blur-ring-bind (tour-resources-blur resources)) (tour-resources-ring-bind-group resources)))
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                 :object (tour-resources-ring-vertex-buffer resources))
      (wgpu:emit draws wgpu:+render-set-index-buffer+
                 :x (wgpu:index-format :uint32)
                 :object (tour-resources-ring-index-buffer resources))
      (wgpu:emit draws wgpu:+render-draw-indexed+
                 :x (tour-resources-ring-index-count resources) :y 1)

)

(defun draw-frame (context resources render-target width height)
  (when (> *frame-warp* 0.001f0) (render-blurred-bodies context resources width height))
  (wgpu:with-command-list (computes)
    (wgpu:with-command-list (draws)
      ;; 個々の星の間を銀河の淡い光で埋める。
      ;; 最終ワープ幕と全画面三角形を共有し、最遠面へ描いて全シーン物体の後ろに置く。
      (wgpu:emit draws wgpu:+render-set-pipeline+
                 :object (tour-resources-space-pipeline resources))
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                 :object (tour-resources-space-bind-group resources))
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                 :object (tour-resources-warp-buffer resources))
      (wgpu:emit draws wgpu:+render-draw+
                 :x (tour-resources-warp-count resources) :y 1)

      ;; 後から描く不透明物体がアルファ合成された星の層を上書きする。
      (wgpu:emit draws wgpu:+render-set-pipeline+
                 :object (tour-resources-star-pipeline resources))
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                 :object (tour-resources-star-bind-group resources))
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                 :object (tour-resources-star-buffer resources))
      (wgpu:emit draws wgpu:+render-draw+
                 :x (tour-resources-star-count resources) :y 1)

      (when (or *show-orbit* *top-view*)
        (wgpu:emit draws wgpu:+render-set-pipeline+
                   :object (tour-resources-orbit-pipeline resources))
        (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                   :object (tour-resources-orbit-bind-group resources))
        (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                   :object (tour-resources-star-buffer resources))
        ;; Second track is Earth's heliocentric orbit in the Moon scene.
        ;; The shader discards this track in other scenes.
        (wgpu:emit draws wgpu:+render-draw+ :x (* 2 512 6) :y 1))

      (if (> *frame-warp* 0.001f0)
          (let ((b (tour-resources-blur resources)))
            (emit-blur-quad draws resources (warp-blur-composite-pipeline b) (warp-blur-composite-bind b)))
          (emit-tour-bodies draws resources))

      ;; 遷移幕を最後に描く。中央の白幕で目的地の切り替えを覆い、
      ;; 1フレームだけ位置が飛んで見える現象を防ぐ。
      (wgpu:emit draws wgpu:+render-set-pipeline+
                 :object (tour-resources-warp-pipeline resources))
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0
                 :object (tour-resources-warp-bind-group resources))
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0
                 :object (tour-resources-warp-buffer resources))
      (wgpu:emit draws wgpu:+render-draw+
                 :x (tour-resources-warp-count resources) :y 1)
      (wgpu:run-render-command-frame
       context computes draws width height :render-target render-target
       :clear-color '(0.0004d0 0.0008d0 0.003d0 1.0d0)))))

(defun main (&key (present-mode *present-mode*) (initial-destination 0))
  (check-type initial-destination (integer 0 9))
  (let* ((*show-orbit* nil)
         (*top-view* nil)
         (shader-path
           (merge-pathnames "solar-tour.wgsl" cl-user::*solar-tour-directory*))
         (shader (uiop:read-file-string shader-path)))
    (format t "~&[solar-tour] WGSL: ~A~%" (truename shader-path))
    (when (uiop:os-windows-p)
      (setf (uiop:getenv "SDL_WINDOWS_DPI_SCALING") "1"))
    (sdl2:with-init (:video)
      (sdl2:with-window (window :title "Solar System Tour | 起動中"
                                :w *window-width* :h *window-height*
                                :flags '(:resizable :allow-highdpi))
        (let ((context nil) (render-target nil))
          (unwind-protect
               (progn
                 (setf context
                       (wgpu:create-context
                        (bridge-sdl2:get-window-system window)))
                 (let ((resources (init-tour context shader)))
                   (let ((width *window-width*)
                         (height *window-height*)
                         (tour-time (* initial-destination
                                       (+ *spot-duration* *warp-duration*)))
                         (elapsed 0.0d0)
                         (random-seed
                           (float
                            (+ (mod (get-universal-time) 65536)
                               (/ (mod (get-internal-real-time)
                                       internal-time-units-per-second)
                                  (float internal-time-units-per-second 1.0d0)))
                            1.0f0))
                         (yaw 0.0f0)
                         (pitch -0.08f0)
                         (roll 0.0f0)
                         (yaw-velocity 0.0f0)
                         (pitch-velocity 0.0f0)
                         (roll-velocity 0.0f0)
                         (warp-start-progress 0.0f0)
                         (paused nil)
                         (quit nil)
                         (keys (make-hash-table :test #'eq))
                         (dragging nil)
                         (last-mouse-x 0)
                         (last-mouse-y 0)
                         (last-time (get-internal-real-time))
                         (title-time 0.0d0)
                         (fps-time 0.0d0)
                         (fps-frames 0)
                         (fps 0.0f0))
                     (multiple-value-setq (width height)
                       (bridge-sdl2:window-pixel-size window))
                     (setf present-mode
                           (wgpu:configure-surface context width height present-mode))
                     (setf render-target
                           (wgpu:create-render-target
                            context width height :sample-count 4 :depth-enabled t))
                     (update-title window initial-destination 0.0f0 paused fps)
                     (loop until quit do
                       (block drain-events
                         (sdl2:with-event-loop (:method :poll)
                           (:quit () (setf quit t) t)
                           (:windowevent (:event event)
                             (when (or (= event sdl2-ffi:+sdl-windowevent-resized+)
                                       (= event sdl2-ffi:+sdl-windowevent-size-changed+))
                               (multiple-value-setq (width height)
                                 (bridge-sdl2:window-pixel-size window))
                               (when (and (plusp width) (plusp height))
                                 (setf present-mode
                                       (wgpu:configure-surface
                                        context width height present-mode))
                                 (setf render-target
                                       (wgpu:resize-render-target
                                        context render-target width height)))))
                           (:mousebuttondown (:button button :x x :y y)
                             (when (= button sdl2-ffi:+sdl-button-left+)
                               (setf dragging t last-mouse-x x last-mouse-y y)))
                           (:mousebuttonup (:button button)
                             (when (= button sdl2-ffi:+sdl-button-left+)
                               (setf dragging nil)))
                           (:mousemotion (:x x :y y)
                             (when dragging
                               (let ((dx (- x last-mouse-x))
                                     (dy (- y last-mouse-y)))
                                 ;; 1画素の遊びでセンサーやノイズによる揺れを防ぎ、
                                 ;; 大きな動きだけ角速度へ加える。
                                 (when (> (abs dx) 1)
                                   (incf yaw-velocity (* 0.055f0 dx)))
                                 (when (> (abs dy) 1)
                                   (incf pitch-velocity (* 0.045f0 dy))))
                               (setf last-mouse-x x last-mouse-y y)))
                           (:keydown (:keysym keysym :repeat repeat)
                             (cond
                               ((scancode-is keysym :scancode-escape)
                                (setf quit t))
                               ((and (zerop repeat)
                                     (scancode-is keysym :scancode-space))
                                (setf paused (not paused)))
                               ((and (zerop repeat)
                                     (scancode-is keysym :scancode-n))
                                (let* ((cycle (+ *spot-duration* *warp-duration*))
                                       (segment (floor tour-time cycle))
                                       (scene-time (mod tour-time cycle)))
                                  (setf tour-time
                                        (+ (* cycle
                                              (if (< scene-time *spot-duration*)
                                                  segment
                                                  (1+ segment)))
                                           *spot-duration*))))
                               ((and (zerop repeat)
                                     (scancode-is keysym :scancode-o))
                                (setf *show-orbit* (not *show-orbit*)))
                               ((and (zerop repeat)
                                     (scancode-is keysym :scancode-t))
                                (setf *top-view* (not *top-view*)))
                               ((and (zerop repeat)
                                     (scancode-is keysym :scancode-v))
                                (setf present-mode
                                      (wgpu:toggle-present-mode context width height)))
                               ((scancode-is keysym :scancode-w) (setf (gethash :w keys) t))
                               ((scancode-is keysym :scancode-s) (setf (gethash :s keys) t))
                               ((scancode-is keysym :scancode-a) (setf (gethash :a keys) t))
                               ((scancode-is keysym :scancode-d) (setf (gethash :d keys) t))
                               ((scancode-is keysym :scancode-q) (setf (gethash :q keys) t))
                               ((scancode-is keysym :scancode-e) (setf (gethash :e keys) t))
                               ((or (scancode-is keysym :scancode-lshift)
                                    (scancode-is keysym :scancode-rshift))
                                (setf (gethash :boost keys) t))))
                           (:keyup (:keysym keysym)
                             (cond
                               ((scancode-is keysym :scancode-w) (setf (gethash :w keys) nil))
                               ((scancode-is keysym :scancode-s) (setf (gethash :s keys) nil))
                               ((scancode-is keysym :scancode-a) (setf (gethash :a keys) nil))
                               ((scancode-is keysym :scancode-d) (setf (gethash :d keys) nil))
                               ((scancode-is keysym :scancode-q) (setf (gethash :q keys) nil))
                               ((scancode-is keysym :scancode-e) (setf (gethash :e keys) nil))
                               ((or (scancode-is keysym :scancode-lshift)
                                    (scancode-is keysym :scancode-rshift))
                                (setf (gethash :boost keys) nil))))
                           (:idle () (return-from drain-events))))
                       (unless quit
                         (let* ((now (get-internal-real-time))
                                (dt (min 0.05d0
                                         (/ (- now last-time)
                                            (float internal-time-units-per-second 1.0d0))))
                                (cycle (+ *spot-duration* *warp-duration*)))
                           (setf last-time now)
                           (incf elapsed dt)
                           (unless paused (incf tour-time dt))
                           (let* ((dtf (float dt 1.0f0))
                                  (acceleration (* dtf 3.4f0))
                                  (damping (expt 0.028f0 dtf)))
                             (when (key-down-p keys :a) (incf yaw-velocity acceleration))
                             (when (key-down-p keys :d) (decf yaw-velocity acceleration))
                             (when (key-down-p keys :w) (decf pitch-velocity acceleration))
                             (when (key-down-p keys :s) (incf pitch-velocity acceleration))
                             (when (key-down-p keys :q) (decf roll-velocity (* 1.15f0 acceleration)))
                             (when (key-down-p keys :e) (incf roll-velocity (* 1.15f0 acceleration)))
                             (setf yaw-velocity
                                   (* damping (clampf yaw-velocity -1.15f0 1.15f0)))
                             (setf pitch-velocity
                                   (* damping (clampf pitch-velocity -0.92f0 0.92f0)))
                             (setf roll-velocity
                                   (* damping (clampf roll-velocity -1.35f0 1.35f0)))
                             ;; 角度の不感帯を設ける。入力を離した後は短く惰性で進み、
                             ;; 微小なずれが蓄積せずに静止する。
                             (unless (or (key-down-p keys :a) (key-down-p keys :d))
                               (when (< (abs yaw-velocity) 0.012f0)
                                 (setf yaw-velocity 0.0f0)))
                             (unless (or (key-down-p keys :w) (key-down-p keys :s))
                               (when (< (abs pitch-velocity) 0.012f0)
                                 (setf pitch-velocity 0.0f0)))
                             (incf yaw (* yaw-velocity dtf))
                             (incf pitch (* pitch-velocity dtf))
                             (incf roll (* roll-velocity dtf))
                             (unless (or (key-down-p keys :q) (key-down-p keys :e))
                               (setf roll (* roll (expt 0.16f0 dtf))))
                             (let ((clamped-pitch (clampf pitch -0.55f0 0.55f0)))
                               (unless (= clamped-pitch pitch)
                                 (setf pitch-velocity 0.0f0))
                               (setf pitch clamped-pitch)))
                           (let* ((scene-time (float (mod tour-time cycle) 1.0f0))
                                  (base-destination
                                   (mod (floor tour-time cycle)
                                        (length *destinations*)))
                                  (warp-phase
                                   (if (< scene-time *spot-duration*) 0.0f0
                                       (clampf (/ (- scene-time *spot-duration*)
                                                   *warp-duration*)
                                               0.0f0 1.0f0)))
                                  (destination
                                   (if (>= warp-phase 0.5f0)
                                       (mod (1+ base-destination)
                                            (length *destinations*))
                                       base-destination))
                                  ;; 描画上の目的地は白幕の中央で切り替わるが、
                                  ;; 表示名はワープ開始時点で次の場面へ更新する。
                                  (title-destination
                                   (if (>= scene-time *spot-duration*)
                                       (mod (1+ base-destination)
                                            (length *destinations*))
                                       base-destination))
                                  (warp (warp-envelope scene-time))
                                  ;; ワープ前半は現在の天体を最終位置に保つ。
                                  ;; 白幕の下で進行度0の次の天体を表示する。
                                  (progress
                                   (if (< scene-time *spot-duration*)
                                       (setf warp-start-progress
                                             (clampf (/ scene-time *spot-duration*)
                                                     0.0f0 1.0f0))
                                       (if (< warp-phase 0.5f0)
                                           warp-start-progress
                                           0.0f0)))
                                  ;; 船は常に巡航する。Shiftキーで停止状態から動かすのではなく、
                                  ;; 巡航速度をブーストへ上げる。
                                  (thrust (if (key-down-p keys :boost) 1.0f0 0.62f0)))
                             (when (and (plusp width) (plusp height))
                               (write-uniforms context
                                               (tour-resources-uniform resources)
                                               width height elapsed
                                               scene-time warp destination yaw pitch roll
                                               thrust progress warp-phase random-seed)
                               (let ((result (draw-frame context resources render-target
                                                         width height)))
                                 (when (minusp result)
                                   (error "Solar tour draw failed"))
                                 (when (= result 1)
                                   (setf present-mode
                                         (wgpu:configure-surface
                                          context width height present-mode)))))
                             (incf fps-frames)
                             (incf fps-time dt)
                             (incf title-time dt)
                             (when (>= fps-time 1.0d0)
                               (setf fps (float (/ fps-frames fps-time) 1.0f0))
                               (setf fps-frames 0 fps-time 0.0d0))
                             (when (>= title-time 0.25d0)
                               (update-title window title-destination scene-time paused fps)
                               (setf title-time 0.0d0))))))))))
            (wgpu:release-render-target render-target)
            (when context (wgpu:release-context context)))))))

(defun run-main-thread ()
  (setf *main-thread*
        (bt:make-thread #'main :name "SDL2-WGPU-Solar-Tour")))

(unless (and (boundp 'cl-user::*solar-tour-no-autostart*)
             (symbol-value 'cl-user::*solar-tour-no-autostart*))
  (run-main-thread))
