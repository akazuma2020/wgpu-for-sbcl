;;;; Dawn / wgpu-nativeに共通するCommon Lisp API。
;;;;
;;;; GPU初期化、資源生成、転送、命令記録、submit、readbackを担当する。
;;;; ウィンドウシステムとアプリ固有状態には依存せず、ネイティブハンドルは
;;;; 呼び出し側から受け取る。生成したGPU資源はcontextが追跡し、解放する。
;;;;
;;;; CFFI構造体と数値タグはbridge/bridge_dawn.cとのABIである。フィールドの
;;;; 順序・幅・アラインメント・タグ値を変更するときはC側も同時に変更する。

(in-package :wgpu)
(defparameter *wgpu-root-directory* (asdf:system-source-directory :wgpu))
(defun bridge-library-path (relative-name)
  "RELATIVE-NAME（例: \"bridge/bridge_dawn.dll\"）を、wgpu.asd の場所基準の絶対パス文字列にする。"
  (uiop:native-namestring (merge-pathnames relative-name *wgpu-root-directory*)))

(defparameter *windows-platform-p* (uiop:os-windows-p))
(setf (uiop:getenv "RUST_BACKTRACE") "full")
(defparameter *wgpu-impl*
  (let ((requested (uiop:getenv "WGPU_IMPL")))
    (cond
      ((or (null requested) (string= requested ""))
       (if *windows-platform-p* "dawn" "wgpu-native"))
      ((string-equal requested "dawn") "dawn")
      ((or (string-equal requested "native")
           (string-equal requested "wgpu-native"))
       "wgpu-native")
      (t (error "Unknown WGPU_IMPL: ~S (use dawn or native)" requested)))))
(when (and (not *windows-platform-p*) (string= *wgpu-impl* "dawn"))
  (error "WGPU_IMPL=dawn is configured only for Windows in this file"))
(if *windows-platform-p*
    (cond
      ((string= *wgpu-impl* "dawn")
       ;; プロジェクト内のbridgeだけはASDFシステムの場所を基準に読み込む。
       (cffi:load-foreign-library "webgpu_dawn.dll")
       (cffi:load-foreign-library (bridge-library-path "bridge/bridge_dawn.dll")))

      ((string= *wgpu-impl* "wgpu-native")
       (cffi:load-foreign-library "wgpu_native.dll")
       (cffi:load-foreign-library (bridge-library-path "bridge/bridge.dll"))))

    (progn
      ;; WSLのD3D12用ライブラリがあれば、GPU本体より先に読む。
      (dolist (path '("/usr/lib/wsl/lib/libd3d12core.so"
                      "/usr/lib/wsl/lib/libd3d12.so"))
        (when (probe-file path)
          (cffi:load-foreign-library path)))
      ;; Linuxでは今までどおりwgpu-nativeを使う。
      (cffi:load-foreign-library "libwgpu_native.so")
      (cffi:load-foreign-library (bridge-library-path "bridge/bridge.so"))))

;;; -------------------- bridge.c と共有する定数・構造体 --------------------
;;; bridge.h は廃止し、C側の定義は bridge.c の先頭に直接置いてある。
;;; ヘッダで縛れなくなった分、ここと bridge.c の並び・値の一致が唯一の取り決め。
;;; どちらかを変えたら必ず両方を直すこと。
(cffi:defcstruct compute-command
  ;; この並びはbridge.cのWGPUBridgeComputeCommandと同じにする。
  ;; opcodeは命令の種類。残りのfieldは命令に必要な値を入れる箱。
  (opcode :uint32)
  (x :uint32)
  (y :uint32)
  (z :uint32)
  (offset :uint64)
  (size :uint64)
  (object :pointer)
  (argument :pointer)
  (destination-offset :uint64))
(cffi:defcstruct bind-group-entry
  (binding :uint32)
  (kind :uint32)
  (offset :uint64)
  (size :uint64)
  (resource :pointer))
(cffi:defcstruct vertex-attribute
  (format :uint32)
  (reserved :uint32)
  (offset :uint64)
  (shader-location :uint32)
  (reserved2 :uint32))
(cffi:defcstruct texture-copy
  (source :pointer)
  (source-mip-level :uint32)
  (source-x :uint32)
  (source-y :uint32)
  (source-z :uint32)
  (destination :pointer)
  (destination-mip-level :uint32)
  (destination-x :uint32)
  (destination-y :uint32)
  (destination-z :uint32)
  (width :uint32)
  (height :uint32)
  (depth-or-array-layers :uint32))
(cffi:defcstruct texture-to-buffer-copy
  (source :pointer)
  (source-mip-level :uint32)
  (source-x :uint32)
  (source-y :uint32)
  (source-z :uint32)
  (destination-buffer :pointer)
  (destination-offset :uint64)
  (destination-bytes-per-row :uint32)
  (destination-rows-per-image :uint32)
  (width :uint32)
  (height :uint32)
  (depth-or-array-layers :uint32))
;; bridge.cのWGPUBridgeComputeOpcodeと同じ番号。
(defconstant +clear-buffer+ 1)
(defconstant +begin-pass+ 2)
(defconstant +set-pipeline+ 3)
(defconstant +set-bind-group+ 4)
(defconstant +dispatch+ 5)
(defconstant +dispatch-indirect+ 6)
(defconstant +end-pass+ 7)
(defconstant +copy-buffer+ 8)
;; 描画命令はCompute命令と別のリストで渡す。同じ構造体を再利用する。
(defconstant +render-set-pipeline+ 1)
(defconstant +render-set-bind-group+ 2)
(defconstant +render-set-vertex-buffer+ 3)
(defconstant +render-set-index-buffer+ 4)
(defconstant +render-draw+ 5)
(defconstant +render-draw-indexed+ 6)
;; bridge.cのWGPUBridgeBufferUsageKindと同じ番号。実際のbit値はCから取得する。
(defconstant +usage-uniform+ 0)
(defconstant +usage-storage+ 1)
(defconstant +usage-copy-dst+ 2)
(defconstant +usage-copy-src+ 3)
(defconstant +usage-indirect+ 4)
(defconstant +usage-map-read+ 5)
(defconstant +usage-vertex+ 6)
(defconstant +usage-index+ 7)
;; bridge.cのWGPUBridgeObjectKindと同じ番号。
(defconstant +object-buffer+ 1)
(defconstant +object-bind-group+ 2)
(defconstant +object-bind-group-layout+ 3)
(defconstant +object-compute-pipeline+ 4)
(defconstant +object-render-pipeline+ 5)
(defconstant +object-shader-module+ 6)
(defconstant +object-queue+ 7)
(defconstant +object-device+ 8)
(defconstant +object-adapter+ 9)
(defconstant +object-surface+ 10)
(defconstant +object-instance+ 11)
(defconstant +object-texture+ 12)
(defconstant +object-texture-view+ 13)
(defconstant +object-sampler+ 14)
(defconstant +object-encoder+ 15)
;; bridge.cのWGPUBridgeBackendKindと同じ番号。
(defconstant +backend-all+ 0)
(defconstant +backend-vulkan+ 1)
(defconstant +backend-d3d12+ 2)
(defconstant +backend-metal+ 3)
(defconstant +backend-gl+ 4)
(defconstant +texture-usage-texture-binding+ 0)
(defconstant +texture-usage-render-attachment+ 1)
(defconstant +texture-usage-copy-dst+ 2)
(defconstant +texture-usage-copy-src+ 3)
(defconstant +texture-usage-storage-binding+ 4)
(defconstant +bind-entry-buffer+ 0)
(defconstant +bind-entry-sampler+ 1)
(defconstant +bind-entry-texture-view+ 2)
;;; -------------------- bridge の関数宣言 --------------------
;;; 1. 環境の用意
(cffi:defcfun ("WGPU_CreateInstance" %create-instance) :pointer
  (allow-noncompliant :int) (backends :uint32))
;; バックエンド選択。実際のbit値はCから取得する。usage flagと同じ方針。
(cffi:defcfun ("WGPU_BackendFlag" %backend-flag) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_InitSurfaceWin32" %init-surface-win32) :pointer
  (instance :pointer) (hinstance :pointer) (hwnd :pointer))
(cffi:defcfun ("WGPU_InitSurfaceX11" %init-surface-x11) :pointer
  (instance :pointer) (display :pointer) (window :uint64))
(cffi:defcfun ("WGPU_InitSurfaceWayland" %init-surface-wayland) :pointer
  (instance :pointer) (display :pointer) (surface :pointer))
(cffi:defcfun ("WGPU_RequestAdapter" %request-adapter) :pointer
  (instance :pointer) (surface :pointer) (reject-cpu :int) (backend :uint32))
(cffi:defcfun ("WGPU_RequestDevice" %request-device) :pointer
  (instance :pointer) (adapter :pointer) (require-float32-filterable :uint32))
(cffi:defcfun ("WGPU_SurfaceSupportsImmediate" %surface-supports-immediate) :int
  (surface :pointer) (adapter :pointer))
(cffi:defcfun ("WGPU_SurfaceSupportsMailbox" %surface-supports-mailbox) :int
  (surface :pointer) (adapter :pointer))
(cffi:defcfun ("WGPU_SurfacePreferredFormat" %surface-preferred-format) :uint32
  (surface :pointer) (adapter :pointer))
(cffi:defcfun ("WGPU_ConfigureSurface" %configure-surface) :int
  (device :pointer) (surface :pointer) (width :uint32) (height :uint32)
  (texture-format :uint32) (present-mode :uint32))
;;; 2. 資源の生成
(cffi:defcfun ("WGPU_BufferUsageFlag" %buffer-usage-flag) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_CreateShaderModule" %create-shader-module) :pointer
  (device :pointer) (code :string))
(cffi:defcfun ("WGPU_CreateComputePipeline" %create-compute-pipeline) :pointer
  (device :pointer) (module :pointer) (entry-point :string))
(cffi:defcfun ("WGPU_CreateRenderPipeline" %create-render-pipeline) :pointer
  (device :pointer) (module :pointer) (vertex-entry :string)
  (fragment-entry :string) (texture-format :uint32))
(cffi:defcfun ("WGPU_CreateRenderPipelinesAsync" %create-render-pipelines-async) :int
  (instance :pointer) (device :pointer)
  (modules :pointer) (texture-formats :pointer)
  (count :uint32) (out-pipelines :pointer)
  (idle-callback :pointer))
(cffi:defcfun ("WGPU_VertexFormat" %vertex-format) :uint32 (kind :uint32))
(cffi:defcfun ("WGPU_VertexStepMode" %vertex-step-mode) :uint32 (kind :uint32))
(cffi:defcfun ("WGPU_CullMode" %cull-mode) :uint32 (kind :uint32))
(cffi:defcfun ("WGPU_IndexFormat" %index-format) :uint32 (kind :uint32))
(cffi:defcfun ("WGPU_PrimitiveTopology" %primitive-topology) :uint32 (kind :uint32))
(cffi:defcfun ("WGPU_CreateVertexRenderPipeline" %create-vertex-render-pipeline) :pointer
  (device :pointer) (module :pointer) (vertex-entry :string)
  (fragment-entry :string) (texture-format :uint32) (sample-count :uint32)
  (vertex-stride :uint64) (step-mode :uint32)
  (attributes :pointer) (attribute-count :uint32)
  (topology :uint32) (cull-mode :uint32)
  (depth-enabled :uint32) (blend-enabled :uint32))
(cffi:defcfun ("WGPU_CreateBuffer" %create-buffer) :pointer
  (device :pointer) (usage :uint32) (size :uint64))
(cffi:defcfun ("WGPU_GetComputeBindGroupLayout" %compute-bind-group-layout) :pointer
  (pipeline :pointer) (group-index :uint32))
(cffi:defcfun ("WGPU_GetRenderBindGroupLayout" %render-bind-group-layout) :pointer
  (pipeline :pointer) (group-index :uint32))
(cffi:defcfun ("WGPU_CreateBindGroup" %create-bind-group) :pointer
  (device :pointer) (layout :pointer) (entries :pointer) (entry-count :uint32))
(cffi:defcfun ("WGPU_CreateColorAttachmentTexture" %create-color-attachment-texture) :pointer
  (device :pointer) (width :uint32) (height :uint32)
  (format :uint32) (sample-count :uint32))
(cffi:defcfun ("WGPU_CreateDepthTexture" %create-depth-texture) :pointer
  (device :pointer) (width :uint32) (height :uint32) (sample-count :uint32))
(cffi:defcfun ("WGPU_CreateTextureView" %create-texture-view) :pointer
  (texture :pointer))
(cffi:defcfun ("WGPU_Release" %release) :void
  (kind :uint32) (handle :pointer))
(cffi:defcfun ("WGPU_TextureUsageFlag" %texture-usage-flag) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_TextureFormat" %texture-format) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_ViewDimension" %view-dimension) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_FilterMode" %filter-mode) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_AddressMode" %address-mode) :uint32
  (kind :uint32))
(cffi:defcfun ("WGPU_CreateTexture" %create-texture) :pointer
  (device :pointer)
  (width :uint32) (height :uint32) (depth-or-array-layers :uint32)
  (format :uint32) (usage :uint32)
  (mip-level-count :uint32) (sample-count :uint32))
(cffi:defcfun ("WGPU_CreateTextureViewEx" %create-texture-view-ex) :pointer
  (texture :pointer) (format :uint32) (dimension :uint32)
  (base-mip-level :uint32) (mip-level-count :uint32)
  (base-array-layer :uint32) (array-layer-count :uint32))
(cffi:defcfun ("WGPU_CreateSampler" %create-sampler) :pointer
  (device :pointer)
  (address-mode-u :uint32) (address-mode-v :uint32) (address-mode-w :uint32)
  (mag-filter :uint32) (min-filter :uint32) (mipmap-filter :uint32))
(cffi:defcfun ("WGPU_CreateCommandEncoder" %create-command-encoder) :pointer
  (device :pointer))
;;; 3. 命令の実行
(cffi:defcfun ("WGPU_RunComputeCommands" %run-compute-commands) :int
  (device :pointer) (queue :pointer)
  (commands :pointer) (command-count :uint32) (wait :uint32))
(cffi:defcfun ("WGPU_EncodeCopyTextureToTexture" %encode-copy-texture-to-texture) :int
  (encoder :pointer) (copy :pointer))
(cffi:defcfun ("WGPU_EncodeCopyTextureToBuffer" %encode-copy-texture-to-buffer) :int
  (encoder :pointer) (copy :pointer))
(cffi:defcfun ("WGPU_EncodeRenderPassToView" %encode-render-pass-to-view) :int
  (encoder :pointer) (color-view :pointer)
  (load-op :uint32)
  (clear-r :double) (clear-g :double) (clear-b :double) (clear-a :double)
  (depth-view :pointer)
  (render-commands :pointer) (render-count :uint32))
(cffi:defcfun ("WGPU_EncodeWriteTexture" %encode-write-texture) :int
  (queue :pointer) (texture :pointer)
  (mip-level :uint32) (origin-x :uint32) (origin-y :uint32) (origin-z :uint32)
  (data :pointer) (data-size :uint64)
  (bytes-per-row :uint32) (rows-per-image :uint32)
  (width :uint32) (height :uint32) (depth-or-array-layers :uint32))
(cffi:defcfun ("WGPU_SubmitEncoder" %submit-encoder) :int
  (device :pointer) (queue :pointer) (encoder :pointer) (wait :uint32))
(cffi:defcfun ("WGPU_RunRenderCommandFrame" %run-render-command-frame) :int
  (device :pointer) (queue :pointer) (surface :pointer)
  (commands :pointer) (command-count :uint32)
  (render-commands :pointer) (render-count :uint32)
  (width :uint32) (height :uint32)
  (msaa-view :pointer) (depth-view :pointer)
  (clear-r :double) (clear-g :double) (clear-b :double) (clear-a :double))
(cffi:defcfun ("WGPU_ReadBuffer" %read-buffer) :int
  (instance :pointer) (device :pointer) (staging :pointer)
  (offset :uint64) (size :uint64) (out-bytes :pointer))
(cffi:defcfun ("WGPU_GetShaderCompilationMessages" %get-shader-compilation-messages) :int
  (instance :pointer) (device :pointer) (module :pointer)
  (shader-name :string)
  (out-buffer :pointer) (out-buffer-size :uint32))
;;; wgpu-native を直接呼ぶもの
(cffi:defcfun ("wgpuDeviceGetQueue" %get-queue) :pointer (device :pointer))
(cffi:defcfun ("wgpuSurfaceUnconfigure" %unconfigure-surface) :void (surface :pointer))
(cffi:defcfun ("wgpuQueueWriteBuffer" %queue-write-buffer) :void
  (queue :pointer) (buffer :pointer) (buffer-offset :uint64)
  (data :pointer) (size :size))
;;; -------------------- 小さな共通処理 --------------------
(defun require-handle (handle description)
  "NULL ならエラーにして、失敗箇所を呼び出し側の言葉で知らせる。"
  (when (cffi:null-pointer-p handle)
    (error "~A failed" description))
  handle)
(defun usage-flags (&rest kinds)
  "usage種別のリストを、wgpu-nativeの実際のbit値のORへ変換する。
   bit値をLispへ書き写さないので、wgpu-nativeの版が変わってもずれない。"
  (reduce #'logior (mapcar (lambda (kind) (%buffer-usage-flag kind)) kinds)))
(defun release-object (kind handle)
  "GPU資源を1個解放する。NULLは無視されるので初期化途中の資源にも使える。"
  (when handle
    (%release kind handle)))
(defun texture-usage-flags (&rest kinds)
  "テクスチャusage種別のリストを、実際のbit値のORへ変換する。usage-flagsと同じ方針。"
  (reduce #'logior (mapcar (lambda (kind) (%texture-usage-flag kind)) kinds)))
(defun texture-format (keyword)
  "テクスチャ形式のキーワードを、実際のWGPUTextureFormat値へ変換する。"
  (%texture-format (ecase keyword
                     (:bgra8-unorm 0) (:rgba8-unorm 1)
                     (:rgba8-unorm-srgb 2) (:rgba32-float 3)
                     (:r8-unorm 4) (:depth24-plus 5))))
(defun view-dimension (keyword)
  "テクスチャビューの次元キーワードを変換する。"
  (%view-dimension (ecase keyword
                     (:2d 0) (:2d-array 1) (:cube 2) (:cube-array 3))))
(defun filter-mode (keyword)
  "サンプラーのフィルタ種別キーワードを変換する。"
  (%filter-mode (ecase keyword (:nearest 0) (:linear 1))))
(defun address-mode (keyword)
  "サンプラーのアドレスモードキーワードを変換する。"
  (%address-mode (ecase keyword
                   (:clamp-to-edge 0) (:repeat 1) (:mirror-repeat 2))))
(defun load-op (keyword)
  "オフスクリーン描画のロード方法キーワードを変換する。C側との往復がない
   単純な対応なのでCには問い合わせず、ここで直接変換する。"
  (ecase keyword (:clear 0) (:load 1)))
(defstruct (vec2f (:constructor vec2f (x y))) x y)
(defstruct (vec3f (:constructor vec3f (x y z))) x y z)
(defstruct (vec4f (:constructor vec4f (x y z w))) x y z w)
(defstruct (vec2u (:constructor vec2u (x y))) x y)
(defstruct (vec3u (:constructor vec3u (x y z))) x y z)
(defstruct (vec4u (:constructor vec4u (x y z w))) x y z w)
(defparameter *gpu-type-layout*
  '((:float  . (4  . 4))
    (:uint32 . (4  . 4))
    (:vec2f  . (8  . 8))
    (:vec2u  . (8  . 8))
    (:vec3f  . (16 . 12))
    (:vec3u  . (16 . 12))
    (:vec4f  . (16 . 16))
    (:vec4u  . (16 . 16))))
(defun gpu-type-alignment (type)
  (car (or (cdr (assoc type *gpu-type-layout*))
           (error "Unknown GPU type: ~S" type))))
(defun gpu-type-size (type)
  (cdr (or (cdr (assoc type *gpu-type-layout*))
           (error "Unknown GPU type: ~S" type))))
(defun round-up (value alignment)
  "VALUEをALIGNMENTの倍数へ切り上げる。WGSLのオフセット計算そのもの。"
  (* alignment (ceiling value alignment)))
;;; -------------------- context --------------------
(defstruct context
  "InstanceからQueueまでのGPU環境と、そこから生成した資源を保持する。
   TRACKED-RESOURCESはRELEASE-CONTEXTが解放する(種類 . ハンドル)の列。
   PRESENT MODEの対応状況は作成時に調べ、Surface再設定時に再利用する。"
  (instance (cffi:null-pointer))
  (surface (cffi:null-pointer))
  (adapter (cffi:null-pointer))
  (device (cffi:null-pointer))
  (queue (cffi:null-pointer))
  (immediate-supported nil)
  (mailbox-supported nil)
  (present-mode :fifo)
  (configured nil)
  (tracked-resources (make-array 0 :adjustable t :fill-pointer 0)))
(defun track-resource (context kind handle)
  "作成した資源をCONTEXTに登録し、そのままHANDLEを返す。
   release-context がここへ登録された資源をまとめて解放する。"
  (vector-push-extend (cons kind handle) (context-tracked-resources context))
  handle)
(defparameter *tracked-release-order*
  (list +object-bind-group+ +object-sampler+ +object-texture-view+
        +object-texture+ +object-buffer+
        +object-compute-pipeline+ +object-render-pipeline+
        +object-shader-module+))
(defun release-context (context)
  "追跡資源を依存順に解放してから、QueueからInstanceまでを解放する。
   初期化途中のCONTEXTにも使用できる。"
  (when context
    (dolist (kind *tracked-release-order*)
      (loop for entry across (context-tracked-resources context)
            when (= (car entry) kind)
              do (release-object kind (cdr entry))))
    (setf (fill-pointer (context-tracked-resources context)) 0)
    (when (context-configured context)
      (%unconfigure-surface (context-surface context))
      (setf (context-configured context) nil))
    (release-object +object-queue+ (context-queue context))
    (release-object +object-device+ (context-device context))
    (release-object +object-adapter+ (context-adapter context))
    (release-object +object-surface+ (context-surface context))
    (release-object +object-instance+ (context-instance context))))
(defun init-surface-win32 (instance hinstance hwnd)
  "Windows用のSurfaceを作る。HINSTANCEはGetModuleHandle(NULL)等で得た
   プロセスのインスタンスハンドル、HWNDはウィンドウハンドル。"
  (%init-surface-win32 instance hinstance hwnd))
(defun init-surface-x11 (instance display window)
  "X11用のSurfaceを作る。DISPLAYはXOpenDisplay等で得たDisplay*、
   WINDOWはXlibのWindow型（符号なし整数のID）。"
  (%init-surface-x11 instance display window))
(defun init-surface-wayland (instance display surface)
  "Wayland用のSurfaceを作る。DISPLAYはwl_display*、SURFACEはwl_surface*。"
  (%init-surface-wayland instance display surface))
(defun create-context (window-system &key (reject-cpu t) (allow-noncompliant t)
                                          (backend +backend-all+)
                                          (require-float32-filterable nil))
  "Instance → Surface → Adapter → Device → Queue をまとめて用意する。
   WINDOW-SYSTEM は、利用側のOS・ウィンドウイングライブラリに応じて
   次のいずれか一組のキーワード引数だけを含むplist。
     Windows : :win32-hwnd（必須）:win32-hinstance（省略可、NULLでよい）
     X11     : :x11-display :x11-window
     Wayland : :wayland-display :wayland-surface
   （例: SDL2利用時は (bridge-sdl2:get-window-system window) の戻り値を
   そのままこの引数へ渡せる。）
   ここでウィンドウライブラリの型を要求しないことで、このファイルを
   SDL2 に限らず任意のウィンドウイングライブラリから使える状態に保つ。
   BACKEND は +backend-d3d12+ / +backend-vulkan+ などの種別番号。
   既定の +backend-all+ を渡した場合、Adapter 探索は D3D12 を対象にする。
   REQUIRE-FLOAT32-FILTERABLE を真にすると、RGBA32F/RG32F/R32Fテクスチャを
   filteringサンプラーでサンプルできるようDeviceへ要求する
   （WebGPU標準のoptional feature float32-filterable）。
   途中で失敗した場合は、作成済みの資源だけを解放してからエラーを投げる。"
  (destructuring-bind (&key win32-hwnd (win32-hinstance (cffi:null-pointer))
                            x11-display (x11-window 0)
                            wayland-display wayland-surface)
      window-system
    (unless (or win32-hwnd x11-display wayland-surface)
      (error "create-context needs a native window handle in window-system: ~
              pass :win32-hwnd, :x11-display+:x11-window, ~
              or :wayland-display+:wayland-surface"))
    (let ((context (make-context)))
      (handler-case
          (progn
            (setf (context-instance context)
                  ;; backend を指定して Instance を作る。
                  (require-handle (%create-instance (if allow-noncompliant 1 0)
                                                    (%backend-flag backend))
                                  "Create instance"))
            (setf (context-surface context)
                  (require-handle
                   (cond
                     (win32-hwnd (init-surface-win32 (context-instance context)
                                                      win32-hinstance win32-hwnd))
                     (x11-display (init-surface-x11 (context-instance context)
                                                     x11-display x11-window))
                     (wayland-surface (init-surface-wayland (context-instance context)
                                                             wayland-display
                                                             wayland-surface)))
                   "Create surface"))
            (setf (context-adapter context)
                  (require-handle (%request-adapter (context-instance context)
                                                    (context-surface context)
                                                    (if reject-cpu 1 0)
                                                    backend)
                                  "Request adapter"))
            (setf (context-device context)
                  (require-handle (%request-device (context-instance context)
                                                    (context-adapter context)
                                                    (if require-float32-filterable 1 0))
                                  "Request device"))
            (setf (context-queue context)
                  (require-handle (%get-queue (context-device context)) "Get queue"))
            (setf (context-immediate-supported context)
                  (plusp (%surface-supports-immediate (context-surface context)
                                                      (context-adapter context))))
            (setf (context-mailbox-supported context)
                  (plusp (%surface-supports-mailbox (context-surface context)
                                                    (context-adapter context))))
            context)
        (error (condition)
          (release-context context)
          (error condition))))))
(defparameter *present-mode-numbers*
  '((:fifo . 0) (:immediate . 1) (:mailbox . 2)))
(defun present-mode-number (keyword)
  (cdr (or (assoc keyword *present-mode-numbers*)
           (error "Unknown present mode: ~S" keyword))))
(defun present-mode-supported-p (context present-mode)
  "CONTEXTのSurfaceがPRESENT-MODEに対応しているかを返す。:fifoは
   WebGPU仕様上必須のため常にT。:immediate/:mailboxはcreate-context時に
   調べた対応状況を参照する。"
  (ecase present-mode
    (:fifo t)
    (:immediate (context-immediate-supported context))
    (:mailbox (context-mailbox-supported context))))
(defun configure-surface (context width height present-mode &key (texture-format 0))
  "ウィンドウの大きさに合わせて表示先を設定し、実際に選ばれたモードを返す。
   PRESENT-MODEは :fifo / :immediate / :mailbox のいずれか。
    TEXTURE-FORMATは表示形式で、省略時はBGRA8Unorm。
    :immediateまたは:mailboxが使えない場合は:fifoへフォールバックする。"
  (unless (member present-mode '(:fifo :immediate :mailbox))
    (error "Unknown present mode: ~S" present-mode))
  (let* ((supported (present-mode-supported-p context present-mode))
         (fell-back (and (not (eq present-mode :fifo)) (not supported)))
         (selected (if fell-back :fifo present-mode)))
    (when (minusp (%configure-surface (context-device context)
                                      (context-surface context)
                                      width height texture-format
                                      (present-mode-number selected)))
      (error "Configure surface failed"))
    (setf (context-configured context) t)
    (when fell-back
      (format t "~&~A present mode is unavailable; using FIFO.~%"
              (string-capitalize (symbol-name present-mode)))
      (finish-output))
    (setf (context-present-mode context) selected)
    selected))
(defun surface-preferred-format (context)
  (let ((value (%surface-preferred-format (context-surface context)
                                          (context-adapter context))))
    (if (zerop value)
        (texture-format :bgra8-unorm)
        value)))
(defun toggle-present-mode (context width height)
  "FIFOとImmediateを切り替え、実際に選ばれたモードを返す。
   MailboxはCONFIGURE-SURFACEへ直接指定する。"
  (configure-surface context width height
                     (if (eq (context-present-mode context) :fifo)
                         :immediate
                         :fifo)))
(defun create-buffer (context usage size description)
  (track-resource
   context +object-buffer+
   (require-handle (%create-buffer (context-device context) usage size) description)))
(defun create-shader-module (context code)
  (track-resource
   context +object-shader-module+
   (require-handle (%create-shader-module (context-device context) code)
                   "Create shader module")))
(defun create-compute-pipeline (context module entry-point)
  (track-resource
   context +object-compute-pipeline+
   (require-handle (%create-compute-pipeline (context-device context) module entry-point)
                   (format nil "Create compute pipeline ~A" entry-point))))
(defun create-render-pipeline (context module vertex-entry fragment-entry
                               &key (texture-format 0))
  (track-resource
   context +object-render-pipeline+
   (require-handle (%create-render-pipeline (context-device context) module
                                            vertex-entry fragment-entry texture-format)
                   "Create render pipeline")))
(defun create-render-pipelines-async (context modules texture-formats
                                      &key (idle-callback (cffi:null-pointer)))
  (let ((count (length modules)))
    (unless (= count (length texture-formats))
      (error "modules and texture-formats must have the same length"))
    (cffi:with-foreign-objects ((module-array :pointer count)
                                (format-array :uint32 count)
                                (pipeline-array :pointer count))
      (loop for module in modules
            for texture-format in texture-formats
            for index from 0
            do (setf (cffi:mem-aref module-array :pointer index) module)
               (setf (cffi:mem-aref format-array :uint32 index) texture-format)
               (setf (cffi:mem-aref pipeline-array :pointer index) (cffi:null-pointer)))
      (let ((result (%create-render-pipelines-async
                     (context-instance context) (context-device context)
                     module-array format-array count pipeline-array idle-callback))
            (pipelines (loop for index from 0 below count
                             collect (cffi:mem-aref pipeline-array :pointer index))))
        (when (minusp result)
          (dolist (pipeline pipelines)
            (unless (cffi:null-pointer-p pipeline)
              (release-object +object-render-pipeline+ pipeline)))
          (error "Create render pipelines (async) failed"))
        (dolist (pipeline pipelines)
          (track-resource context +object-render-pipeline+ pipeline))
        pipelines))))
(defun vertex-format (keyword)
  "頂点属性の型キーワードを、実際のDawnのVertexFormat値へ変換する。"
  (%vertex-format (ecase keyword
                    (:float32 1) (:float32x2 2) (:float32x3 3)
                    (:float32x4 4) (:uint32 5))))
(defun vertex-step-mode (keyword)
  "頂点バッファの進み方（:vertexは頂点ごと、:instanceはインスタンスごと）を変換する。"
  (%vertex-step-mode (ecase keyword (:vertex 1) (:instance 2))))
(defun cull-mode (keyword)
  "描画時に間引く面のキーワードを、実際のDawnのCullMode値へ変換する。"
  (%cull-mode (ecase keyword (:none 1) (:front 2) (:back 3))))
(defun index-format (keyword)
  "インデックスバッファの要素サイズのキーワードを変換する。"
  (%index-format (ecase keyword (:uint16 1) (:uint32 2))))
(defun primitive-topology (keyword)
  "頂点をどう三角形・線・点へ組み立てるかのキーワードを変換する。"
  (%primitive-topology (ecase keyword
                         (:triangle-list 1) (:triangle-strip 2)
                         (:line-list 3) (:line-strip 4) (:point-list 5))))
(defun fill-vertex-attribute (native index format offset shader-location)
  "頂点属性1個ぶんをネイティブ配列へ書く。formatは既にvertex-formatで
   変換済みの実際の値を渡すこと。"
  (let ((entry (cffi:mem-aptr native '(:struct vertex-attribute) index)))
    (macrolet ((field (name)
                 `(cffi:foreign-slot-value entry '(:struct vertex-attribute) ,name)))
      (setf (field 'format) format)
      (setf (field 'reserved) 0)
      (setf (field 'offset) offset)
      (setf (field 'shader-location) shader-location)
      (setf (field 'reserved2) 0))))
(defun create-vertex-render-pipeline
    (context module vertex-entry fragment-entry
     &key (texture-format 0) (sample-count 4) vertex-stride
          (step-mode (vertex-step-mode :vertex))
          attributes
          (topology (primitive-topology :triangle-list))
          (cull-mode (cull-mode :none))
          (depth-enabled t) (blend-enabled nil))
  "頂点の形式・幅・間引き方法を利用側から受け取り、描画設定を作る。
   ATTRIBUTES は (format offset shader-location) のリスト。formatは
   vertex-format で変換済みの値を渡す。複数の属性（位置・法線・UV等）を
   まとめて渡せる。
    TOPOLOGY、CULL-MODE、DEPTH-ENABLED、BLEND-ENABLEDもここで指定する。"
  (unless (and vertex-stride (plusp vertex-stride) attributes)
    (error "Vertex stride and at least one attribute are required"))
  (let ((count (length attributes)))
    (cffi:with-foreign-object (native '(:struct vertex-attribute) count)
      (loop for (format offset shader-location) in attributes
            for index from 0
            do (fill-vertex-attribute native index format offset shader-location))
      (track-resource
       context +object-render-pipeline+
       (require-handle
        (%create-vertex-render-pipeline
         (context-device context) module vertex-entry fragment-entry
         texture-format sample-count vertex-stride step-mode
         native count topology cull-mode
         (if depth-enabled 1 0) (if blend-enabled 1 0))
        "Create vertex render pipeline")))))
(defun compute-bind-group-layout (pipeline &optional (group-index 0))
  (%compute-bind-group-layout pipeline group-index))
(defun render-bind-group-layout (pipeline &optional (group-index 0))
  (%render-bind-group-layout pipeline group-index))
(defun set-bind-entry (entries index binding kind resource &optional (offset 0) (size 0))
  "BindGroup entryを1個書く。bindingはWGSLの@binding(n)に対応する。"
  (let ((entry (cffi:mem-aptr entries '(:struct bind-group-entry) index)))
    (macrolet ((field (name)
                 `(cffi:foreign-slot-value entry '(:struct bind-group-entry) ,name)))
      (setf (field 'binding) binding)
      (setf (field 'kind) kind)
      (setf (field 'offset) offset)
      (setf (field 'size) size)
      (setf (field 'resource) resource))))
(defun bindings (&rest pairs)
  "PAIRS は (binding buffer binding buffer ...) の平らな並び。
   2個ずつ組にして (binding buffer) のリストへ変換する。
   BUFFERの代わりに (wgpu:texture-binding view) や
   (wgpu:sampler-binding samp) を渡すと、そのbindingはテクスチャビュー・
   サンプラーとして扱われる（下記create-bind-group参照）。
   create-bind-group / create-compute-bind-group / create-render-bind-group
   へそのまま渡せる形になる。"
  (loop for (binding payload) on pairs by #'cddr
        collect (list binding payload)))
(defun texture-binding (view)
  "bindingsの中で、VIEWをテクスチャビューとして差すことを示す目印。"
  (list +bind-entry-texture-view+ view))
(defun sampler-binding (sampler)
  "bindingsの中で、SAMPLERをサンプラーとして差すことを示す目印。"
  (list +bind-entry-sampler+ sampler))
(defun create-bind-group (context layout bindings description &optional (group-index 0))
  "BINDINGSの各要素は次のいずれか:
     (binding buffer)                  -- buffer binding（size省略）
     (binding buffer size)             -- buffer binding
     (binding (texture-binding view))  -- texture view binding
     (binding (sampler-binding samp))  -- sampler binding
   sizeを省略するか0を渡すと、C側がバッファの実サイズを使用する。
   GROUP-INDEXは省略可（既定0）。turn-n-burn等、group 1（channels）用の
   BindGroupを作る場面で、group-indexを明示的に指定するために使う。
   どのbindingに何を差すかは利用側が決め、ここは表をそのまま渡すだけにする。"
  (declare (ignore group-index))
  (let ((count (length bindings)))
    (cffi:with-foreign-object (entries '(:struct bind-group-entry) count)
      (loop for binding-spec in bindings
            for index from 0
            do (destructuring-bind (binding payload &optional (size 0)) binding-spec
                 (etypecase payload
                   (cons
                    ;; (texture-binding view) または (sampler-binding samp)
                    (destructuring-bind (kind resource) payload
                      (set-bind-entry entries index binding kind resource)))
                   (t
                    (set-bind-entry entries index binding +bind-entry-buffer+
                                    payload 0 size)))))
      (track-resource
       context +object-bind-group+
       (require-handle (%create-bind-group (context-device context) layout entries count)
                       description)))))
(defun create-compute-bind-group (context pipeline bindings description
                                  &optional (group-index 0))
  "PIPELINE（compute pipeline）から BindGroupLayout を取得し、BindGroup を
   作って Layout は使い終わったら解放する。BINDINGSはcreate-bind-groupと
   同じ形式。"
  (let ((layout (compute-bind-group-layout pipeline group-index)))
    (unwind-protect
         (create-bind-group context layout bindings description)
      (release-object +object-bind-group-layout+ layout))))
(defun create-render-bind-group (context pipeline bindings description
                                 &optional (group-index 0))
  "PIPELINE（render pipeline）を使う点だけが create-compute-bind-group と違う。
   GROUP-INDEXは省略可（既定0）。turn-n-burn等、group 1（channels）用の
   BindGroupを作る場面で、group-indexを明示的に指定する。"
  (let ((layout (render-bind-group-layout pipeline group-index)))
    (unwind-protect
         (create-bind-group context layout bindings description)
      (release-object +object-bind-group-layout+ layout))))
(defun create-texture (context width height format usage
                       &key (depth-or-array-layers 1) (mip-level-count 1)
                            (sample-count 1))
  (track-resource
   context +object-texture+
   (require-handle (%create-texture (context-device context)
                                    width height depth-or-array-layers
                                    format usage mip-level-count sample-count)
                   "Create texture")))
(defun create-texture-view-ex (context texture
                               &key (format 0) (dimension (view-dimension :2d))
                                    (base-mip-level 0) (mip-level-count 0)
                                    (base-array-layer 0) (array-layer-count 0))
  (track-resource
   context +object-texture-view+
   (require-handle (%create-texture-view-ex texture format dimension
                                            base-mip-level mip-level-count
                                            base-array-layer array-layer-count)
                   "Create texture view (ex)")))
(defun create-sampler (context &key (address-mode-u (address-mode :clamp-to-edge))
                                     (address-mode-v (address-mode :clamp-to-edge))
                                     (address-mode-w (address-mode :clamp-to-edge))
                                     (mag-filter (filter-mode :linear))
                                     (min-filter (filter-mode :linear))
                                     (mipmap-filter (filter-mode :linear)))
  (track-resource
   context +object-sampler+
   (require-handle (%create-sampler (context-device context)
                                    address-mode-u address-mode-v address-mode-w
                                    mag-filter min-filter mipmap-filter)
                   "Create sampler")))
(defun create-command-encoder (context)
  (require-handle (%create-command-encoder (context-device context))
                  "Create command encoder"))
;;; -------------------- CPU と GPU の間の転送 --------------------
(defconstant +padding+ :padding
  "write-fields で「値を書かず、型のサイズぶんだけ空けたい」ときに、
   値の位置へ渡す目印。実際のGPU側の型（:float 等）と組にして使う。
    例: wgpu:+padding+ :float は、float 1個ぶん(4バイト)の空きを表す。
    WRITE-UNIFORM-FIELDSの自動アラインメントとは別に、意図的な空きを表す。"
  )
(defun clear-bytes (pointer byte-count)
  "POINTERからBYTE-COUNTバイトをゼロにする。"
  ;; Uniformの余白も含めて初期化する。
  (dotimes (index byte-count)
    (setf (cffi:mem-aref pointer :uint8 index) 0)))
(defun write-scalar-or-vector (pointer offset value type)
  (ecase type
    (:float (setf (cffi:mem-ref pointer :float offset) value))
    (:uint32 (setf (cffi:mem-ref pointer :uint32 offset) value))
    (:vec2f
     (setf (cffi:mem-ref pointer :float offset) (vec2f-x value))
     (setf (cffi:mem-ref pointer :float (+ offset 4)) (vec2f-y value)))
    (:vec2u
     (setf (cffi:mem-ref pointer :uint32 offset) (vec2u-x value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 4)) (vec2u-y value)))
    (:vec3f
     (setf (cffi:mem-ref pointer :float offset) (vec3f-x value))
     (setf (cffi:mem-ref pointer :float (+ offset 4)) (vec3f-y value))
     (setf (cffi:mem-ref pointer :float (+ offset 8)) (vec3f-z value)))
    (:vec3u
     (setf (cffi:mem-ref pointer :uint32 offset) (vec3u-x value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 4)) (vec3u-y value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 8)) (vec3u-z value)))
    (:vec4f
     (setf (cffi:mem-ref pointer :float offset) (vec4f-x value))
     (setf (cffi:mem-ref pointer :float (+ offset 4)) (vec4f-y value))
     (setf (cffi:mem-ref pointer :float (+ offset 8)) (vec4f-z value))
     (setf (cffi:mem-ref pointer :float (+ offset 12)) (vec4f-w value)))
    (:vec4u
     (setf (cffi:mem-ref pointer :uint32 offset) (vec4u-x value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 4)) (vec4u-y value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 8)) (vec4u-z value))
     (setf (cffi:mem-ref pointer :uint32 (+ offset 12)) (vec4u-w value)))))
(defun write-fields (pointer byte-count &rest fields)
  "値・型の組を先頭から書く。値が +padding+ のときは、その型のサイズぶんだけ
   何も書かずに空けておく（clear-bytes 済みなので中身は0のまま残る）。
   空きのバイト数も、他のフィールドと同じく型のサイズから自動的に
    決まる。ベクトル値は対応する構造体と型キーワード（:vec3f等）で渡し、
    x/y/z/wの順に書き込む。"
  (unless (evenp (length fields))
    (error "write-fields: 値と型を対で指定してください"))
  ;; 書き始める前に、型から求めた合計バイト数が領域と一致するか検査する。
  ;; 値は使わないので、destructuring の1番目を nil にして束縛を省く。
  (let ((total-size 0))
    (loop for (nil type) on fields by #'cddr do
      (incf total-size (gpu-type-size type)))
    (unless (= total-size byte-count)
      (error "write-fields: 配置は~Dバイト、領域は~Dバイトです"
             total-size byte-count)))
  ;; 検査後に全領域をゼロにするので、+padding+ の部分もゼロのまま残る。
  (clear-bytes pointer byte-count)
  (let ((offset 0))
    (loop for (value type) on fields by #'cddr do
      (unless (eq value +padding+)
        (write-scalar-or-vector pointer offset value type))
      (incf offset (gpu-type-size type)))))
(defun write-buffer (context buffer data-pointer size &key (offset 0))
  "CPU側のメモリをGPUバッファへ書く。"
  (%queue-write-buffer (context-queue context) buffer offset data-pointer size))
(defmacro write-uniform-fields (context buffer &rest fields)
  "CONTEXT の GPU バッファ BUFFER へ、FIELDS（値 型 値 型... の交互リスト）
   の内容を、WGSLのアラインメント規則に沿って自動的にオフセットを
   計算しながら書き込み、そのまま転送まで行う。
   FIELDS の型キーワードはマクロ展開時にリテラルとして読めること
   （変数経由の型指定はできない）。vec2f/vec3f/vec4f/vec2u/vec3u/vec4u
   型も指定できる。"
  (let* ((types (loop for (nil type) on fields by #'cddr collect type))
         (offsets nil)
         (cursor 0)
         (max-alignment 4))
    (dolist (type types)
      (let ((alignment (gpu-type-alignment type)))
        (setf cursor (round-up cursor alignment))
        (push cursor offsets)
        (incf cursor (gpu-type-size type))
        (setf max-alignment (max max-alignment alignment))))
    (setf offsets (nreverse offsets))
    (let ((byte-count (round-up cursor max-alignment))
          (pointer (gensym "UNIFORM-DATA")))
      `(cffi:with-foreign-object (,pointer :uint8 ,byte-count)
         (clear-bytes ,pointer ,byte-count)
         ,@(loop for (value type) on fields by #'cddr
                 for offset in offsets
                 unless (eq value '+padding+)
                   collect `(write-scalar-or-vector ,pointer ,offset ,value ,(intern (symbol-name type) :keyword)))
         (write-buffer ,context ,buffer ,pointer ,byte-count)))))
(defun write-bytes (context buffer vector size &key (offset 0))
  "特殊化ベクタの中身をそのままGPUバッファへ書く。
   SIZE はバイト数。要素型からの自動計算はしない。呼び出し側が明示すること。"
  (cffi:with-pointer-to-vector-data (pointer vector)
    (write-buffer context buffer pointer size :offset offset)))
(defun create-buffer-with-data (context usage vector size description)
  "CREATE-BUFFER でバッファを作り、続けて VECTOR の中身を SIZE バイトぶん
   書き込む。戻り値はバッファのハンドル。"
  (let ((buffer (create-buffer context usage size description)))
    (write-bytes context buffer vector size)
    buffer))
(defun read-buffer (context staging size out-pointer &key (offset 0))
  "MapRead用バッファの内容をCPU側のメモリへ写す。0で成功。"
  (%read-buffer (context-instance context) (context-device context)
                staging offset size out-pointer))
(defconstant +shader-compilation-buffer-size+ 16384)
(defun get-shader-compilation-messages (context module shader-name)
  "MODULEのコンパイルで出たエラー・警告・情報を、1件1行
   （SHADER-NAME:行番号:列番号: [種別] 本文 の形式）として連結した文字列で返す。
   1件も無ければ空文字列。取得できなければNIL。"
  (cffi:with-foreign-object (buffer :uint8 +shader-compilation-buffer-size+)
    (let ((written (%get-shader-compilation-messages
                    (context-instance context) (context-device context) module
                    shader-name
                    buffer +shader-compilation-buffer-size+)))
      (when (>= written 0)
        (cffi:foreign-string-to-lisp buffer :count written :encoding :utf-8)))))
(defun log-compile-messages (context module shader-name log-path
                              &key (if-exists :supersede))
  "MODULEのコンパイルで出たメッセージを、LOG-PATHへ書く。
   SHADER-NAMEはログの各行で使う表示名（例: \"seascape.wgsl\"）。
   LOG-PATHは呼び出し側が組み立てた完全なパス。
   IF-EXISTSは:supersede（既定、新規作成/上書き）か:append（追記）。
   戻り値はget-shader-compilation-messagesと同じ
   （メッセージ文字列。1件も無ければ空文字列。取得できなければNIL）。"
  (let ((messages (get-shader-compilation-messages context module shader-name)))
    (with-open-file (stream log-path
                            :direction :output
                            :if-exists if-exists
                            :if-does-not-exist :create)
      ;; 追記のときも、今回の取得が何時だったか分かるよう、
      ;; 呼ぶたびに必ずタイムスタンプ1行を先頭に書く。
      (multiple-value-bind (second minute hour date month year)
          (get-decoded-time)
        (format stream "~&~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D~%"
                year month date hour minute second))
      (write-string (or messages "") stream)
      (terpri stream))
    messages))
(defun write-texture (context texture data-pointer data-size
                      width height
                      &key (mip-level 0) (origin-x 0) (origin-y 0) (origin-z 0)
                           (bytes-per-row 0) (rows-per-image 0)
                           (depth-or-array-layers 1))
  (let ((effective-rows-per-image (if (zerop rows-per-image) height rows-per-image)))
    (when (minusp (%encode-write-texture (context-queue context) texture
                                         mip-level origin-x origin-y origin-z
                                         data-pointer data-size
                                         bytes-per-row effective-rows-per-image
                                         width height depth-or-array-layers))
      (error "Write texture failed"))))
(defun encode-copy-texture-to-texture
    (encoder source source-mip source-x source-y source-z
     destination destination-mip destination-x destination-y destination-z
     width height depth-or-array-layers)
  (cffi:with-foreign-object (copy '(:struct texture-copy))
    (macrolet ((field (name) `(cffi:foreign-slot-value copy '(:struct texture-copy) ,name)))
      (setf (field 'source) source)
      (setf (field 'source-mip-level) source-mip)
      (setf (field 'source-x) source-x)
      (setf (field 'source-y) source-y)
      (setf (field 'source-z) source-z)
      (setf (field 'destination) destination)
      (setf (field 'destination-mip-level) destination-mip)
      (setf (field 'destination-x) destination-x)
      (setf (field 'destination-y) destination-y)
      (setf (field 'destination-z) destination-z)
      (setf (field 'width) width)
      (setf (field 'height) height)
      (setf (field 'depth-or-array-layers) depth-or-array-layers))
    (when (minusp (%encode-copy-texture-to-texture encoder copy))
      (error "Encode copy texture to texture failed"))))
(defun encode-copy-texture-to-buffer
    (encoder source source-mip source-x source-y source-z
     destination-buffer destination-offset
     destination-bytes-per-row destination-rows-per-image
     width height depth-or-array-layers)
  (cffi:with-foreign-object (copy '(:struct texture-to-buffer-copy))
    (macrolet ((field (name)
                 `(cffi:foreign-slot-value copy '(:struct texture-to-buffer-copy) ,name)))
      (setf (field 'source) source)
      (setf (field 'source-mip-level) source-mip)
      (setf (field 'source-x) source-x)
      (setf (field 'source-y) source-y)
      (setf (field 'source-z) source-z)
      (setf (field 'destination-buffer) destination-buffer)
      (setf (field 'destination-offset) destination-offset)
      (setf (field 'destination-bytes-per-row) destination-bytes-per-row)
      (setf (field 'destination-rows-per-image) destination-rows-per-image)
      (setf (field 'width) width)
      (setf (field 'height) height)
      (setf (field 'depth-or-array-layers) depth-or-array-layers))
    (when (minusp (%encode-copy-texture-to-buffer encoder copy))
      (error "Encode copy texture to buffer failed"))))
(defun encode-render-pass-to-view (encoder color-view render-commands render-count
                                   &key (load-op (load-op :clear))
                                        (clear-r 0.0d0) (clear-g 0.0d0)
                                        (clear-b 0.0d0) (clear-a 0.0d0)
                                        (depth-view (cffi:null-pointer)))
  (when (minusp (%encode-render-pass-to-view encoder color-view load-op
                                             clear-r clear-g clear-b clear-a
                                             depth-view render-commands render-count))
    (error "Encode render pass to view failed")))
(defun submit-encoder (context encoder &key (wait nil))
  (when (minusp (%submit-encoder (context-device context) (context-queue context)
                                 encoder (if wait 1 0)))
    (error "Submit encoder failed")))
(defstruct command-list
  "compute 命令を積むビルダ。ENTRIES は emit が積んだ命令を、命令1個に
   つき9要素のベクタとして集めた可変長ベクタ。"
  (entries (make-array 0 :adjustable t :fill-pointer 0)))
(defun command-list-count (list)
  "積んだ命令の個数。"
  (length (command-list-entries list)))
(defun emit (list opcode &key (x 0) (y 0) (z 0) (offset 0) (size 0)
                              (object (cffi:null-pointer))
                              (argument (cffi:null-pointer))
                              (destination-offset 0))
  "命令を1個積む。容量は自動的に伸びるので、利用側が事前に個数を
   数える必要はない。使わないfieldには0かNULLを渡せばよい。"
  (vector-push-extend
   (vector opcode x y z offset size object argument destination-offset)
   (command-list-entries list))
  list)
(defmacro with-command-list ((var) &body body)
  "VARへ自動拡張する空のCOMMAND-LISTを束縛する。"
  `(let ((,var (make-command-list)))
     ,@body))
(defmacro with-compute-pass ((list) &body body)
  "BEGIN_PASS と END_PASS の対を自動で挟む。
   BODY内ではLISTへEMITを呼び、passの開始と終了はこのマクロに任せる。"
  `(progn
     (emit ,list +begin-pass+)
     ,@body
     (emit ,list +end-pass+)))
(defun fill-native-command (native index entry)
  "1個ぶんのLisp側命令（ENTRY、emitが作った9要素ベクタ）を、Cの
   compute-command配列のINDEX番目へ書く。"
  (let ((command (cffi:mem-aptr native '(:struct compute-command) index)))
    (macrolet ((field (name)
                 `(cffi:foreign-slot-value command '(:struct compute-command) ,name)))
      (setf (field 'opcode) (aref entry 0))
      (setf (field 'x) (aref entry 1))
      (setf (field 'y) (aref entry 2))
      (setf (field 'z) (aref entry 3))
      (setf (field 'offset) (aref entry 4))
      (setf (field 'size) (aref entry 5))
      (setf (field 'object) (aref entry 6))
      (setf (field 'argument) (aref entry 7))
      (setf (field 'destination-offset) (aref entry 8)))))
(defmacro with-native-commands ((pointer-var count-var list) &body body)
  "LIST に積んだ命令を、その場でCの配列へ一括変換し、POINTER-VAR と
   COUNT-VAR へ束縛して BODY を評価する。命令が0個のときは NULL
   ポインタと 0 を渡す。確保は stack 上なので、BODY を抜けると
   自動的に解放される。run系の関数だけが内部でこのマクロを使う。"
  (let ((entries (gensym "ENTRIES")) (n (gensym "N")) (i (gensym "I")))
    `(let* ((,entries (command-list-entries ,list))
            (,n (length ,entries)))
       (if (zerop ,n)
           (let ((,pointer-var (cffi:null-pointer)) (,count-var 0))
             ,@body)
           (cffi:with-foreign-object (,pointer-var '(:struct compute-command) ,n)
             (dotimes (,i ,n)
               (fill-native-command ,pointer-var ,i (aref ,entries ,i)))
             (let ((,count-var ,n))
               ,@body))))))
(defun run (context list &key (wait t))
  "積んだ命令を submit する。0で成功、負で失敗。"
  (with-native-commands (pointer count list)
    (%run-compute-commands (context-device context) (context-queue context)
                           pointer count (if wait 1 0))))
(defstruct render-target
  "MSAA用の色テクスチャと深度テクスチャの組。使わない方はNILのままになる。"
  (color-texture nil)
  (color-view nil)
  (depth-texture nil)
  (depth-view nil)
  (width 0)
  (height 0)
  (sample-count 1)
  (depth-enabled nil))
(defun release-render-target (target)
  "保持しているテクスチャとviewを解放する。TARGETがNILなら何もしない。"
  (when target
    (when (render-target-color-view target)
      (release-object +object-texture-view+ (render-target-color-view target)))
    (when (render-target-color-texture target)
      (release-object +object-texture+ (render-target-color-texture target)))
    (when (render-target-depth-view target)
      (release-object +object-texture-view+ (render-target-depth-view target)))
    (when (render-target-depth-texture target)
      (release-object +object-texture+ (render-target-depth-texture target)))))
(defun create-render-target (context width height &key (sample-count 1) (depth-enabled nil))
  "WIDTH x HEIGHT の MSAA色テクスチャ（SAMPLE-COUNTが1より大きいときのみ）と
   深度テクスチャ（DEPTH-ENABLEDが真のときのみ）を作る。
   どちらも不要（sample-count=1 かつ depth-enabled=NIL）なら中身が
   全部NILのrender-targetを返し、run-render-command-frame はSurfaceへ
   直接描く経路を通る。"
  (let ((color-texture nil) (color-view nil) (depth-texture nil) (depth-view nil))
    (when (> sample-count 1)
      (setf color-texture
            (require-handle (%create-color-attachment-texture
                              (context-device context) width height 0 sample-count)
                             "Create MSAA color texture"))
      (setf color-view
            (require-handle (%create-texture-view color-texture)
                             "Create MSAA color texture view")))
    (when depth-enabled
      (setf depth-texture
            (require-handle (%create-depth-texture
                              (context-device context) width height sample-count)
                             "Create depth texture"))
      (setf depth-view
            (require-handle (%create-texture-view depth-texture)
                             "Create depth texture view")))
    (make-render-target
     :color-texture color-texture :color-view color-view
     :depth-texture depth-texture :depth-view depth-view
     :width width :height height
     :sample-count sample-count :depth-enabled depth-enabled)))
(defun resize-render-target (context target width height)
  "WIDTH/HEIGHT が TARGET 作成時と変わっていれば、古いテクスチャを解放して
   同じ SAMPLE-COUNT・DEPTH-ENABLED で作り直す。変わっていなければ
   TARGET をそのまま返す。TARGET が NIL のときは何もせず NIL を返す
   （render-target を使わないアプリでも安全に呼べる）。"
  (cond
    ((null target) nil)
    ((and (= width (render-target-width target))
          (= height (render-target-height target)))
     target)
    (t
     (let ((sample-count (render-target-sample-count target))
           (depth-enabled (render-target-depth-enabled target)))
       (release-render-target target)
       (create-render-target context width height
                              :sample-count sample-count
                              :depth-enabled depth-enabled)))))
(defun run-render-command-frame
    (context compute-list render-list width height
     &key render-target
          (clear-color '(0.0d0 0.0d0 0.0d0 1.0d0)))
  "Computeの後、利用側が積んだ描画命令を順に実行して表示する。
   RENDER-TARGETがNILなら、Surfaceへ直接描く（MSAAなし・深度なし）。
   RENDER-TARGETを渡すと、その中のcolor-view（あれば）へMSAA描画して
   Surfaceへresolveし、depth-view（あれば）を深度バッファとして使う。"
  (destructuring-bind (red green blue alpha) clear-color
    (with-native-commands (compute-pointer compute-count compute-list)
      (with-native-commands (render-pointer render-count render-list)
        (%run-render-command-frame
         (context-device context) (context-queue context) (context-surface context)
         compute-pointer compute-count
         render-pointer render-count
         width height
         (or (and render-target (render-target-color-view render-target))
             (cffi:null-pointer))
         (or (and render-target (render-target-depth-view render-target))
             (cffi:null-pointer))
         red green blue alpha)))))
