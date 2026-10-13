(in-package :solar-tour)

(defstruct warp-blur
  planet-pipeline planet-bind ring-pipeline ring-bind
  horizontal-pipeline composite-pipeline sampler
  (width 0) (height 0) texture view intermediate intermediate-view depth depth-view
  horizontal-bind composite-bind)

(defun init-warp-blur (context module resources)
  (let* ((attributes (list (list (wgpu:vertex-format :float32x3) 0 0)
                           (list (wgpu:vertex-format :float32x3) 12 1)
                           (list (wgpu:vertex-format :float32x2) 24 2)))
         (planet (startup-step (wgpu:create-vertex-render-pipeline
                  context module "planetVS" "planetFS" :sample-count 1
                  :vertex-stride 32 :attributes attributes
                  :cull-mode (wgpu:cull-mode :back) :depth-enabled t)))
         (ring (startup-step (wgpu:create-vertex-render-pipeline
                context module "ringVS" "ringFS" :sample-count 1
                :vertex-stride 32 :attributes attributes
                :depth-enabled t :blend-enabled t)))
         (blur-module (wgpu:create-shader-module context
                        (uiop:read-file-string (merge-pathnames "warp-blur.wgsl"
                                                   cl-user::*solar-tour-directory*))))
         (log (wgpu:log-compile-messages context blur-module "warp-blur.wgsl"
                 (merge-pathnames "warp-blur-compile.log" cl-user::*solar-tour-directory*)))
         (quad (list (list (wgpu:vertex-format :float32x2) 0 0))))
    (when (and log (search "[error]" log)) (error "Warp blur shader: ~A" log))
    (setf (tour-resources-blur resources)
          (make-warp-blur
           :planet-pipeline planet :ring-pipeline ring
           :planet-bind (wgpu:create-render-bind-group context planet
                          (wgpu:bindings 0 (tour-resources-uniform resources)) "Blur bodies")
           :ring-bind (wgpu:create-render-bind-group context ring
                        (wgpu:bindings 0 (tour-resources-uniform resources)) "Blur rings")
           :horizontal-pipeline (startup-step (wgpu:create-vertex-render-pipeline
                context blur-module "blurVS" "horizontalFS" :sample-count 1
                :vertex-stride 8 :attributes quad :depth-enabled nil))
           :composite-pipeline (startup-step (wgpu:create-vertex-render-pipeline
                context blur-module "blurVS" "compositeFS" :sample-count 4
                :vertex-stride 8 :attributes quad :depth-enabled t :blend-enabled t))
           :sampler (wgpu:create-sampler context)))
    resources))

(defun blur-release (context kind handle)
  (when handle
    (wgpu:release-object kind handle)
    (let* ((items (wgpu::context-tracked-resources context))
           (at (position-if (lambda (item) (and (= (car item) kind)
                                 (cffi:pointer-eq (cdr item) handle))) items)))
      (when at
        (setf (aref items at) (aref items (1- (length items))))
        (decf (fill-pointer items))))))

(defun ensure-blur-targets (context resources width height)
  (let ((b (tour-resources-blur resources)))
    (unless (and (= width (warp-blur-width b)) (= height (warp-blur-height b)))
      (blur-release context wgpu:+object-bind-group+ (warp-blur-horizontal-bind b))
      (blur-release context wgpu:+object-bind-group+ (warp-blur-composite-bind b))
      (blur-release context wgpu:+object-texture-view+ (warp-blur-view b))
      (blur-release context wgpu:+object-texture-view+ (warp-blur-intermediate-view b))
      (blur-release context wgpu:+object-texture+ (warp-blur-texture b))
      (blur-release context wgpu:+object-texture+ (warp-blur-intermediate b))
      (blur-release context wgpu:+object-texture-view+ (warp-blur-depth-view b))
      (blur-release context wgpu:+object-texture+ (warp-blur-depth b))
      (let ((usage (wgpu:texture-usage-flags wgpu:+texture-usage-texture-binding+
                                           wgpu:+texture-usage-render-attachment+)))
        (setf (warp-blur-texture b) (wgpu:create-texture context width height
                                      (wgpu:texture-format :bgra8-unorm) usage)
              (warp-blur-intermediate b) (wgpu:create-texture context width height
                                      (wgpu:texture-format :bgra8-unorm) usage)))
      (setf (warp-blur-view b) (wgpu:create-texture-view-ex context (warp-blur-texture b))
            (warp-blur-intermediate-view b) (wgpu:create-texture-view-ex context (warp-blur-intermediate b))
            (warp-blur-depth b) (wgpu:create-texture context width height
                                  (wgpu:texture-format :depth24-plus)
                                  (wgpu:texture-usage-flags wgpu:+texture-usage-render-attachment+))
            (warp-blur-depth-view b) (wgpu:create-texture-view-ex context (warp-blur-depth b))
            (warp-blur-width b) width (warp-blur-height b) height)
      (flet ((bind (pipeline view)
               (wgpu:create-render-bind-group context pipeline
                 (wgpu:bindings 0 (tour-resources-uniform resources)
                                1 (wgpu:texture-binding view)
                                2 (wgpu:sampler-binding (warp-blur-sampler b))) "Warp blur")))
        (setf (warp-blur-horizontal-bind b) (bind (warp-blur-horizontal-pipeline b) (warp-blur-view b))
              (warp-blur-composite-bind b) (bind (warp-blur-composite-pipeline b) (warp-blur-intermediate-view b)))))))

(defun emit-blur-quad (draws resources pipeline bind)
  (wgpu:emit draws wgpu:+render-set-pipeline+ :object pipeline)
  (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0 :object bind)
  (wgpu:emit draws wgpu:+render-set-vertex-buffer+ :x 0 :object (tour-resources-warp-buffer resources))
  (wgpu:emit draws wgpu:+render-draw+ :x 3 :y 1))

(defun render-blurred-bodies (context resources width height)
  (ensure-blur-targets context resources width height)
  (let ((b (tour-resources-blur resources)) (encoder (wgpu:create-command-encoder context)))
    (wgpu:with-command-list (draws)
      (emit-tour-bodies draws resources t)
      (wgpu:with-native-commands (ptr count draws)
        (wgpu:encode-render-pass-to-view encoder (warp-blur-view b) ptr count
          :depth-view (warp-blur-depth-view b))))
    (wgpu:with-command-list (draws)
      (emit-blur-quad draws resources (warp-blur-horizontal-pipeline b) (warp-blur-horizontal-bind b))
      (wgpu:with-native-commands (ptr count draws)
        (wgpu:encode-render-pass-to-view encoder (warp-blur-intermediate-view b) ptr count)))
    (wgpu:submit-encoder context encoder)))
