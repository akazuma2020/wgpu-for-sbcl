;;;; Common Lisp向けWebGPU環境の公開パッケージ。
;;;;
;;;; パッケージを実装より先に定義し、ASDFの各サブシステムで同じ公開APIを使う。
;;;; CFFIの内部関数や実装詳細はexportせず、利用側にはLispのラッパを公開する。

(defpackage :bridge-sdl2
  (:use :cl)
  (:export :get-window-system
           :logical-window-size :window-pixel-size
           :modifier-key-pressed-p
           :load-image-rgba8))

(defpackage :three-compat
  (:use :cl)
  (:export :+tan-half-fov+
           :icosahedron-geometry
           :vector3-lerp :vector3-normalized
           :orbit-position :look-at-basis
           :raycaster-ray-from-camera))

(defpackage :wgpu
  (:use :cl)
  (:export
   ;; context
   #:context #:context-p #:create-context #:release-context
   #:init-surface-win32 #:init-surface-x11 #:init-surface-wayland
   #:context-instance #:context-surface #:context-adapter
   #:context-device #:context-queue
   #:context-present-mode #:context-immediate-supported #:context-mailbox-supported
   #:context-configured
   #:configure-surface #:toggle-present-mode
   #:surface-preferred-format
   ;; 資源生成
   #:require-handle #:usage-flags #:create-buffer
   #:create-shader-module #:create-compute-pipeline #:create-render-pipeline
   #:create-render-pipelines-async
   #:create-vertex-render-pipeline #:run-render-command-frame
   #:+render-set-pipeline+ #:+render-set-bind-group+
   #:+render-set-vertex-buffer+ #:+render-set-index-buffer+
   #:+render-draw+ #:+render-draw-indexed+
   #:vertex-format #:vertex-step-mode #:cull-mode #:index-format
   #:primitive-topology
   #:compute-bind-group-layout #:render-bind-group-layout
   #:create-bind-group #:release-object
   #:create-compute-bind-group #:create-render-bind-group
   #:bindings
   #:texture-binding #:sampler-binding
   #:create-buffer-with-data
   #:create-texture #:create-texture-view-ex #:create-sampler
   #:texture-usage-flags #:texture-format #:view-dimension
   #:filter-mode #:address-mode #:load-op
   #:create-command-encoder #:submit-encoder
   #:encode-copy-texture-to-texture #:encode-render-pass-to-view
   #:encode-copy-texture-to-buffer
   ;; 転送
   #:write-buffer #:write-bytes #:read-buffer #:clear-bytes #:write-fields #:+padding+
   #:get-shader-compilation-messages #:log-compile-messages
   #:write-uniform-fields
   #:write-texture
   #:vec2f #:vec3f #:vec4f #:vec2f-x #:vec2f-y
   #:vec3f-x #:vec3f-y #:vec3f-z #:vec4f-x #:vec4f-y #:vec4f-z #:vec4f-w
   #:vec2u #:vec3u #:vec4u #:vec2u-x #:vec2u-y
   #:vec3u-x #:vec3u-y #:vec3u-z #:vec4u-x #:vec4u-y #:vec4u-z #:vec4u-w
   ;; command list
   #:command-list #:with-command-list #:emit #:command-list-count
   #:with-compute-pass
   #:with-native-commands
   #:run
   ;; opcode / usage / object 種別
   #:+clear-buffer+ #:+begin-pass+ #:+set-pipeline+ #:+set-bind-group+
   #:+dispatch+ #:+dispatch-indirect+ #:+end-pass+ #:+copy-buffer+
   #:+usage-uniform+ #:+usage-storage+ #:+usage-copy-dst+ #:+usage-copy-src+
   #:+usage-indirect+ #:+usage-map-read+ #:+usage-vertex+ #:+usage-index+
   #:+object-buffer+ #:+object-bind-group+ #:+object-bind-group-layout+
   #:+object-compute-pipeline+ #:+object-render-pipeline+
   #:+object-shader-module+ #:+object-queue+ #:+object-device+
   #:+object-adapter+ #:+object-surface+ #:+object-instance+
   #:+object-texture+ #:+object-texture-view+
   #:+object-sampler+ #:+object-encoder+
   #:+texture-usage-texture-binding+ #:+texture-usage-render-attachment+
   #:+texture-usage-copy-dst+ #:+texture-usage-copy-src+
   #:+texture-usage-storage-binding+
   #:render-target #:render-target-p
   #:create-render-target #:resize-render-target #:release-render-target
   #:render-target-color-view #:render-target-depth-view
   #:render-target-width #:render-target-height
   ;; 実行環境とバックエンド選択
   #:*windows-platform-p* #:*wgpu-impl*
   #:+backend-all+ #:+backend-vulkan+ #:+backend-d3d12+
   #:+backend-metal+ #:+backend-gl+))

