;;;; Three.js webgpu_compute_birds
;;;; 修正箇所: 「three.core.js」という原典ライブラリ内部のファイル名への
;;;; 言及は、移植作業の経緯（どのソースを参照したか）を示すだけの情報で、
;;;; 挙動そのものの説明にはなっていなかった。Skyの分割詳細（面の数・
;;;; 分割順）は実際の挙動として three-compat:icosahedron-geometry の
;;;; docstring に書いてある
;;;; ため、ここでは「どんな形状を再現するか」だけを簡潔に述べる。
;;;; Skyは正二十面体（icosahedron）を分割して球に近づけた形状。
;;;; DawnのBridgeとFFIは既存の正常動作する版を使う。
;; 修正箇所: SDL2ランタイムDLLの場所確認・PATH設定・(ql:quickload :sdl2)は
;; bridge-sdl2.lisp側へ集約した（seascape.lisp/lifegame.lispと一字一句
;; 同じ内容だったため）。:bordeaux-threadsはSDL2固有ではなくスレッド用途
;; のため、従来どおりここで個別にquickloadする。
(defparameter *birds-directory*
  (uiop:pathname-directory-pathname (or *load-truename* *compile-file-truename*)))
;; 修正箇所（2026-10-07・パッケージ管理のASDF対応）: wgpu.lisp /
;; bridge-sdl2.lisp / three-compat.lisp の読み込みを (load ...) から
;; (asdf:load-system ...) へ変更した。
;; 修正箇所: create-contextがSDL2の生ウィンドウからWin32/X11/Waylandの
;; ハンドルを取り出す処理を失ったため、SDL2側でそれを行う補助システム
;; （wgpu/sdl2）を読み込む。wgpu自体はSDL2非依存のまま変更していない。
;; icosahedron-geometry / orbit-position / look-at-basis /
;; raycaster-ray-from-camera / +tan-half-fov+は、Three.js側の機能
;; （IcosahedronGeometry・OrbitControlsの球面変換・Matrix4.lookAt相当の
;; 基底ベクトル抽出・Raycaster）を代替する、birds固有の状態に依存しない
;; 純粋関数だったため、wgpu/three-compatへ切り出してある。1つのThree.js
;; 操作に1つの関数が対応するよう、以前のcamera-frame（球面変換と基底抽出を
;; 1関数でまとめていた）はorbit-position/look-at-basisの2関数へ分割した。
(push (truename "../../") asdf:*central-registry*)
(asdf:load-system :wgpu)
(asdf:load-system :wgpu/sdl2)
(asdf:load-system :wgpu/three-compat)
(ql:quickload :bordeaux-threads)
(defpackage :birds
  (:use :cl)
  (:export :main :run-main-thread :*main-thread*))
(in-package :birds)
(defparameter *window-width* 1200)
(defparameter *window-height* 700)
(defparameter *present-mode* :fifo)
(defparameter *main-thread* nil)
(defparameter *bird-count* 8192)
(defconstant +uniform-size+ 96)
(defconstant +bird-stride+ 16)
(defconstant +phase-stride+ 4)
(defconstant +vertices-per-bird+ 9)
(defconstant +workgroup-size+ 64)
(defconstant +bounds+ 800.0f0)
;; REPLから変更する値。毎フレーム読み取り、Uniformとタイトルに同じ値を使う。
(defparameter *separation* 15.0f0)
(defparameter *alignment* 20.0f0)
(defparameter *cohesion* 20.0f0)
;; 新設（2026-10-07）: シェーダーのコンパイルメッセージをログファイルへ
;; 出力する際のパス。ログ出力の実処理自体はwgpu:log-compile-messages
;; （汎用関数、wgpu.lisp側）が行い、ここではパスだけを決める。
(defparameter *shader-compile-log-path*
  (merge-pathnames "birds-shader-compile.log" cl-user::*birds-directory*))
;; 修正箇所: SDL_GetWindowSize / SDL_GetWindowSizeInPixels / SDL_GetModState
;; を使うlogical-window-size / window-pixel-size / modifier-key-pressed-pは、
;; 同じSDL2.dllを指す別名のdefine-foreign-library（birds-sdl2）を自分用に
;; もう1本定義していた。bridge-sdl2.lisp側に統合したので、ここでは
;; bridge-sdl2:を付けて呼ぶだけでよい。
(defun update-window-title (window fps separation alignment cohesion)
  "FPSとGPUへ渡した3値を、約1秒ごとに同じタイトルへ表示する。"
  (sdl2:set-window-title
   window
   (format nil "Compute Birds | FPS: ~,1F | sep: ~,3F | ali: ~,3F | coh: ~,3F"
           fps separation alignment cohesion)))
(defun random-range (minimum maximum)
  (+ minimum (* (random 1.0f0) (- maximum minimum))))
(defun make-initial-positions ()
  (let ((data (make-array (* *bird-count* 4) :element-type 'single-float))
        (half-bounds (/ +bounds+ 2.0f0)))
    (dotimes (index *bird-count* data)
      (let ((base (* index 4)))
        (setf (aref data base      ) (random-range (- half-bounds) half-bounds))
        (setf (aref data (+ base 1)) (random-range (- half-bounds) half-bounds))
        (setf (aref data (+ base 2)) (random-range (- half-bounds) half-bounds))
        (setf (aref data (+ base 3)) 0.0f0)))))
(defun make-initial-velocities ()
  (let ((data (make-array (* *bird-count* 4) :element-type 'single-float)))
    (dotimes (index *bird-count* data)
      (let ((base (* index 4)))
        (setf (aref data base      ) (random-range -5.0f0 5.0f0))
        (setf (aref data (+ base 1)) (random-range -5.0f0 5.0f0))
        (setf (aref data (+ base 2)) (random-range -5.0f0 5.0f0))
        (setf (aref data (+ base 3)) 0.0f0)))))
(defun make-initial-phases ()
  (make-array *bird-count* :element-type 'single-float :initial-element 1.0f0))
(defun make-bird-vertices ()
  "原典のBirdGeometryと同じ9頂点をCPU側で作り、0.2倍して返す。"
  ;; 胴体・左翼・右翼を3頂点ずつ並べる。頂点4と7はGPU側で羽ばたかせる。
  ;; wings-spanは原典のwingsSpan = 20に対応する。
  (let* ((wings-span 20.0f0)
         (coordinates
          (vector
           ;; Body
           0.0f0 0.0f0 -20.0f0
           0.0f0 -8.0f0 10.0f0
           0.0f0 0.0f0 30.0f0
           ;; Left Wing
           0.0f0 0.0f0 -15.0f0
           (- wings-span) 0.0f0 5.0f0
           0.0f0 0.0f0 15.0f0
           ;; Right Wing
           0.0f0 0.0f0 15.0f0
           wings-span 0.0f0 5.0f0
           0.0f0 0.0f0 -15.0f0))
         (result (make-array (* +vertices-per-bird+ 3)
                             :element-type 'single-float)))
    (dotimes (i (length result) result)
      (setf (aref result i) (* (aref coordinates i) 0.2f0)))))
;; 修正箇所: 4つのbind-group関数はいずれも「layoutを取得する→
;; create-bind-groupを呼ぶ→layoutを解放する」という同じ3行を
;; 繰り返していた。wgpu:create-compute-bind-group /
;; wgpu:create-render-bind-group にまとめたので、各関数は1行になる。
;; さらに wgpu:bindings で「番号、バッファ、番号、バッファ...」という
;; 平らな並びに書き換えた。
(defun make-sky-bind-group (context pipeline uniform)
  "Connect the camera uniform to the sky pipeline."
  (wgpu:create-render-bind-group
   context pipeline (wgpu:bindings 0 uniform) "Sky bind group"))
(defun write-uniforms (context buffer pixel-width pixel-height delta-time now
                       pointer-x pointer-y camera-yaw camera-pitch camera-distance
                       target-x target-y target-z
                       separation alignment cohesion)
  (multiple-value-bind (camera-x camera-y camera-z ray-x ray-y ray-z)
      (three-compat:raycaster-ray-from-camera pointer-x pointer-y pixel-width pixel-height
                   camera-yaw camera-pitch camera-distance
                   target-x target-y target-z)
    ;; 修正箇所: wgpu:vec3f/vec2f型の導入により、WGSL側（birds.wgsl）の
    ;; struct Paramsが実際に使っているrayOrigin/rayDirection/cameraTarget
    ;; （vec3f）とresolution（vec2f）を、そのままvec3f/vec2fとして渡せる
    ;; ようになった。アラインメント（_pad0〜_pad3相当）はwrite-uniform-fields
    ;; が型のアラインメント表から自動計算するため、+padding+の手書きが
    ;; 不要になった。
    ;; 検証: birds.wgsl の struct Params を実際に確認し、各フィールドの
    ;; オフセットが以前の手書きレイアウト（+padding+で明示していたもの）と
    ;; 完全に一致することをシミュレーションで確認済み（合計96バイト）。
    (wgpu:write-uniform-fields
     context buffer
     (min delta-time 1.0f0)                  :float   ; deltaTime
     separation                              :float   ; separation
     alignment                               :float   ; alignment
     cohesion                                :float   ; cohesion
     (wgpu:vec3f camera-x camera-y camera-z) :vec3f   ; rayOrigin
     (wgpu:vec3f ray-x ray-y ray-z)          :vec3f   ; rayDirection
     ;; 投影とポインターRayは描画ピクセルの縦横比を共有する。
     (wgpu:vec2f (float pixel-width 1.0f0)
                 (float pixel-height 1.0f0)) :vec2f   ; resolution
     (float now 1.0f0)                       :float   ; now
     *bird-count*                            :uint32  ; birdCount
     camera-yaw                              :float   ; cameraYaw
     camera-pitch                            :float   ; cameraPitch
     camera-distance                         :float   ; cameraDistance
     (wgpu:vec3f target-x target-y target-z) :vec3f))) ; cameraTarget
(defun make-velocity-bind-group (context pipeline uniform positions velocities)
  (wgpu:create-compute-bind-group
   context pipeline
   (wgpu:bindings 0 uniform 1 positions 2 velocities)
   "Birds velocity bind group"))
(defun make-position-bind-group (context pipeline uniform positions velocities phases)
  (wgpu:create-compute-bind-group
   context pipeline
   (wgpu:bindings 0 uniform 1 positions 2 velocities 3 phases)
   "Birds position bind group"))
(defun make-render-bind-group (context pipeline uniform positions velocities phases)
  (wgpu:create-render-bind-group
   context pipeline
   (wgpu:bindings 0 uniform 4 positions 5 velocities 6 phases)
   "Birds render bind group"))
(defun draw-frame (context velocity-pipeline velocity-bind-group
                   position-pipeline position-bind-group
                   sky-pipeline sky-bind-group sky-vertex-buffer sky-index-buffer
                   sky-index-count bird-pipeline bird-bind-group
                   bird-vertex-buffer render-target width height)
  "Run the two compute steps, draw the sky, and then draw all birds.
   MSAA色テクスチャ・深度テクスチャをrun-render-command-frameの内部で
   毎フレーム作成・解放するのをやめたため、呼び出し側（main）が
   wgpu:create-render-target / wgpu:resize-render-targetで保持する
   RENDER-TARGETを受け取り、:render-targetで渡す。"
  ;; 修正箇所: with-command-list から容量数値(8, 10)を削除した。
  ;; 命令はLisp側で自動的に伸びるので、個数を手で数える必要がなくなった。
  ;; begin-pass/end-passの対はwith-compute-passで自動化した。
  (wgpu:with-command-list (commands)
    (wgpu:with-compute-pass (commands)
      (wgpu:emit commands wgpu:+set-pipeline+ :object velocity-pipeline)
      (wgpu:emit commands wgpu:+set-bind-group+ :x 0 :object velocity-bind-group)
      (wgpu:emit commands wgpu:+dispatch+
                 :x (ceiling *bird-count* +workgroup-size+) :y 1 :z 1)
      (wgpu:emit commands wgpu:+set-pipeline+ :object position-pipeline)
      (wgpu:emit commands wgpu:+set-bind-group+ :x 0 :object position-bind-group)
      (wgpu:emit commands wgpu:+dispatch+
                 :x (ceiling *bird-count* +workgroup-size+) :y 1 :z 1))
    ;; Skyと鳥の順序・個数はアプリ側で決める。C側は命令を順に渡すだけ。
    (wgpu:with-command-list (draws)
      (wgpu:emit draws wgpu:+render-set-pipeline+ :object sky-pipeline)
      (wgpu:emit draws wgpu:+render-set-bind-group+
                 :x 0 :object sky-bind-group)
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+
                 :x 0 :object sky-vertex-buffer)
      (wgpu:emit draws wgpu:+render-set-index-buffer+
                 :x (wgpu:index-format :uint32) :object sky-index-buffer)
      (wgpu:emit draws wgpu:+render-draw-indexed+
                 :x sky-index-count :y 1)
      (wgpu:emit draws wgpu:+render-set-pipeline+ :object bird-pipeline)
      (wgpu:emit draws wgpu:+render-set-bind-group+
                 :x 0 :object bird-bind-group)
      (wgpu:emit draws wgpu:+render-set-vertex-buffer+
                 :x 0 :object bird-vertex-buffer)
      (wgpu:emit draws wgpu:+render-draw+
                 :x +vertices-per-bird+ :y *bird-count*)
      (wgpu:run-render-command-frame
       context commands draws width height :render-target render-target
       :clear-color '(0.0d0 0.0d0 0.0d0 1.0d0)))))
(defun main (&key (present-mode *present-mode*))
  (let ((shader (uiop:read-file-string
                 (merge-pathnames "birds.wgsl"
                                  cl-user::*birds-directory*))))
    ;; WindowsではSDLの入力座標をDPIスケールされた論理座標にする。
    ;; SDLの初期化前に指定し、他の環境では従来の設定を変えない。
    (when (uiop:os-windows-p)
      (setf (uiop:getenv "SDL_WINDOWS_DPI_SCALING") "1"))
    (sdl2:with-init (:video)
      (sdl2:with-window (window :title "Compute Birds | FPS: 0.0 | sep: 15.000 | ali: 20.000 | coh: 20.000"
                                :w *window-width* :h *window-height*
                                :flags '(:resizable :allow-highdpi))
        ;; 修正箇所: 以前はcontext以下17個の資源用変数をすべてnilで
        ;; 宣言し、progn内でsetfして、unwind-protectの後半で
        ;; dolist/removeによる手作業の解放処理（約15行）を書いていた。
        ;; wgpu.lisp側でcreate-buffer等が資源をcontextへ自動登録する
        ;; ようになったため、資源用の変数はlet*でその場で実際の値に
        ;; 初期化でき、解放は(wgpu:release-context context)の1行だけで
        ;; 済むようになった。nilで宣言しておく必要が残るのはcontext
        ;; 自身だけ（create-contextより前の失敗に備えるため）。
        ;; 修正箇所: render-targetも、context同様に失敗時の解放に備えて
        ;; ここでnil宣言しておく。MSAA色テクスチャ・深度テクスチャは
        ;; サイズ変更のたびに作り直すため、tracked-resourcesには入らず、
        ;; この変数で明示的に持ち回す。
        (let ((context nil) (render-target nil))
          (unwind-protect
            ;; 原典のdetail=6は7列分割。980面・2940頂点を一度だけ転送。
            (multiple-value-bind (sky-vertices sky-indices) (three-compat:icosahedron-geometry 6)
              (let* ((sky-vertex-size (* (length sky-vertices) 4))
                     (sky-index-size (* (length sky-indices) 4))
                     (sky-index-count (length sky-indices))
                     ;; 形状は一度だけCPUで作り、頂点バッファへ転送する。
                     ;; 毎フレーム変化するのはGPU側の鳥の位置・羽ばたきだけ。
                     (bird-vertices (make-bird-vertices))
                     (bird-vertex-size (* (length bird-vertices) 4))
                     (state-size (* *bird-count* +bird-stride+))
                     (phase-size (* *bird-count* +phase-stride+))
                     (module (progn
                               ;; 修正箇所: 「SDL2のウィンドウハンドル取得」と
                               ;; 「wgpu:create-contextによるGPU初期化」の2処理を、
                               ;; 呼び出し側で明確に分離した。
                               ;; bridge-sdl2:get-window-system（bridge-sdl2.lisp）は
                               ;; OSごとのハンドルをplistとして返すだけで、
                               ;; GPU初期化は行わない。wgpu:create-contextが
                               ;; WINDOW-SYSTEMを1個の位置引数として受け取る形に
                               ;; なったため、ここで直接渡してGPU初期化を行う。
                               (setf context (wgpu:create-context (bridge-sdl2:get-window-system window)))
                               ;; 修正箇所（2026-10-07）: shader-module作成の直後に
                               ;; コンパイルメッセージを確認する。原典の
                               ;; getCompilationInfoは、WGSLのコンパイルが終わった
                               ;; 時点で呼べるAPIであり、pipeline作成の成否とは
                               ;; 独立しているため、ここが最も早いタイミングになる。
                               ;; ログ出力処理自体はwgpu:log-compile-messages
                               ;; （汎用関数、wgpu.lisp側）へ渡すだけ。戻り値
                               ;; （メッセージ文字列）が空でなければ、見落とし
                               ;; 防止のためコンソールへも出す（アプリ側の判断）。
                               (let* ((m (wgpu:create-shader-module context shader))
                                      (messages (wgpu:log-compile-messages
                                                 context m "birds.wgsl"
                                                 *shader-compile-log-path*)))
                                 (when (and messages (plusp (length messages)))
                                   (format t "~&[birds] shader compilation messages (see ~A):~%~A"
                                           *shader-compile-log-path* messages)
                                   (finish-output))
                                 m)))
                     (velocity-pipeline
                      (wgpu:create-compute-pipeline context module "computeVelocity"))
                     (position-pipeline
                      (wgpu:create-compute-pipeline context module "computePosition"))
                     ;; :attributes に頂点属性のリストを渡す形。
                     ;; 位置(vec3f)だけを1個、shader-location 0 で使う。
                     ;; cull-mode はキーワードで指定する。
                     (sky-pipeline
                      (wgpu:create-vertex-render-pipeline
                       context module "skyVS" "skyFS" :sample-count 4
                       :vertex-stride 12
                       :attributes (list (list (wgpu:vertex-format :float32x3) 0 0))
                       :cull-mode (wgpu:cull-mode :front)))
                     (bird-pipeline
                      (wgpu:create-vertex-render-pipeline
                       context module "birdVS" "birdFS" :sample-count 4
                       :vertex-stride 12
                       :attributes (list (list (wgpu:vertex-format :float32x3) 0 0))
                       :cull-mode (wgpu:cull-mode :none)))
                     (uniform
                      (wgpu:create-buffer
                       context
                       (wgpu:usage-flags wgpu:+usage-uniform+ wgpu:+usage-copy-dst+)
                       +uniform-size+ "Birds uniform"))
                     ;; 修正箇所: create-buffer + write-bytes の2行を、
                     ;; 初期値付きバッファを1回で作る
                     ;; wgpu:create-buffer-with-data にまとめた。
                     (positions
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-storage+ wgpu:+usage-copy-dst+)
                       (make-initial-positions) state-size "Bird positions"))
                     (velocities
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-storage+ wgpu:+usage-copy-dst+)
                       (make-initial-velocities) state-size "Bird velocities"))
                     (phases
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-storage+ wgpu:+usage-copy-dst+)
                       (make-initial-phases) phase-size "Bird phases"))
                     (velocity-bind-group
                      (make-velocity-bind-group
                       context velocity-pipeline uniform positions velocities))
                     (position-bind-group
                      (make-position-bind-group
                       context position-pipeline uniform positions velocities phases))
                     (sky-bind-group (make-sky-bind-group context sky-pipeline uniform))
                     (bird-bind-group
                      (make-render-bind-group
                       context bird-pipeline uniform positions velocities phases))
                     (sky-vertex-buffer
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-vertex+ wgpu:+usage-copy-dst+)
                       sky-vertices sky-vertex-size "Sky vertices"))
                     (sky-index-buffer
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-index+ wgpu:+usage-copy-dst+)
                       sky-indices sky-index-size "Sky indices"))
                     (bird-vertex-buffer
                      (wgpu:create-buffer-with-data
                       context
                       (wgpu:usage-flags wgpu:+usage-vertex+ wgpu:+usage-copy-dst+)
                       bird-vertices bird-vertex-size "Bird vertices"))
                     ;; ここから先はGPU資源ではなく、イベントループ内で
                     ;; setfされる普通のプログラム状態。
                     ;; width/heightはSDLのマウス入力用の論理サイズ。
                     (width *window-width*)
                     (height *window-height*)
                     ;; Surfaceのサイズは別に実ピクセルで保持する。
                     (pixel-width 0)
                     (pixel-height 0)
                     (fps-start (get-internal-real-time))
                     (fps-frames 0)
                     (fps-value 0.0f0)
                     (frame-separation *separation*)
                     (frame-alignment *alignment*)
                     (frame-cohesion *cohesion*)
                     (pointer-x 0.0f0)
                     (pointer-y 0.0f0)
                     ;; 公式OrbitControlsの初期状態と同じく、原点を距離1000から見る。
                     (camera-yaw 0.0f0)
                     (camera-pitch 0.0f0)
                     (camera-distance 1000.0f0)
                     (target-x 0.0f0)
                     (target-y 0.0f0)
                     (target-z 0.0f0)
                     (drag-mode nil)
                     (drag-button nil)
                     (quit nil)
                     (last-mouse-x 0)
                     (last-mouse-y 0)
                     (last-time (get-internal-real-time)))
                (progn
                  (multiple-value-setq (width height) (bridge-sdl2:logical-window-size window))
                  (multiple-value-setq (pixel-width pixel-height)
                    (bridge-sdl2:window-pixel-size window))
                  (when (and (plusp pixel-width) (plusp pixel-height))
                    (setf present-mode
                          (wgpu:configure-surface
                           context pixel-width pixel-height present-mode))
                    ;; 修正箇所: MSAA色テクスチャ・深度テクスチャを
                    ;; ここで1回だけ作る。以前はrun-render-command-frame内部で
                    ;; 毎フレーム作成・解放していたが、サイズが変わらない限り
                    ;; 作り直す必要はない。sample-count 4・depth-enabled tは、
                    ;; sky-pipeline/bird-pipelineが使ってきた値と同じにしてある。
                    (setf render-target
                          (wgpu:create-render-target
                           context pixel-width pixel-height
                           :sample-count 4 :depth-enabled t)))
                  (setf last-time (get-internal-real-time))
                  (setf fps-start last-time)
                  (update-window-title window fps-value
                                       frame-separation frame-alignment frame-cohesion)
                  ;; 1フレームごとに入力を処理してから、描画を1回行う。
                  (loop until quit do
                    (block drain-events
                      (sdl2:with-event-loop (:method :poll)
                        (:quit ()
                               ;; 終了イベント後は描画せずループを抜ける。
                               (setf quit t)
                               t)
                        (:mousebuttondown (:button button :x x :y y)
                                          ;; 原典: 左は回転、右はパン。修飾キーで両者を入れ替える。
                                          ;; 中ボタンは修飾キーに関係なくズームする。
                                          (unless drag-mode
                                            (setf drag-mode
                                                  (case button
                                                    (1 (if (bridge-sdl2:modifier-key-pressed-p) :pan :rotate))
                                                    (2 :dolly)
                                                    (3 (if (bridge-sdl2:modifier-key-pressed-p) :rotate :pan))))
                                            (when drag-mode
                                              (setf drag-button button)
                                              (setf last-mouse-x x last-mouse-y y))))
                        (:mousebuttonup (:button button :x x :y y)
                                        (declare (ignore x y))
                                        ;; 操作中ではないボタンを離してもドラッグを解除しない。
                                        (when (eql button drag-button)
                                          (setf drag-mode nil drag-button nil)))
                        (:mousewheel (:y wheel-y)
                                     ;; 原典はドラッグ中のホイール操作を受け付けない。
                                     ;; SDLの整数刻みとDOMのdeltaYは同一単位ではない。
                                     (when (null drag-mode)
                                       (setf camera-distance
                                             (max 0.001f0
                                                  (* camera-distance (expt 0.95f0 wheel-y))))))
                        (:mousemotion (:x x :y y)
                                      (when (and drag-mode (plusp height))
                                        (let ((dx (- x last-mouse-x)) (dy (- y last-mouse-y)))
                                          (case drag-mode
                                            (:rotate
                                             ;; 原典の角度式は画面の「幅」でなく「高さ」で割る。
                                             (decf camera-yaw
                                                   (* 2.0f0 (float pi 1.0f0) (/ dx height)))
                                             (incf camera-pitch
                                                   (* 2.0f0 (float pi 1.0f0) (/ dy height)))
                                             (let ((limit (- (/ (float pi 1.0f0) 2.0f0)
                                                             0.000001f0)))
                                               (setf camera-pitch
                                                     (max (- limit) (min limit camera-pitch)))))
                                            (:pan
                                             ;; 画面高とFOVから1pxのワールド移動量を求める。
                                             ;; 修正箇所: 以前は1関数（camera-frame）で
                                             ;; カメラ位置と基底ベクトルを同時に得ていたが、
                                             ;; 「球面座標→直交座標変換」(orbit-position)と
                                             ;; 「基底ベクトル抽出」(look-at-basis)の2段階へ
                                             ;; 分割した。このpan処理は基底ベクトルのみ使う。
                                             (multiple-value-bind (cx cy cz)
                                                 (three-compat:orbit-position
                                                  camera-yaw camera-pitch camera-distance)
                                               (multiple-value-bind (rx ry rz ux uy uz)
                                                   (three-compat:look-at-basis cx cy cz)
                                                 (let ((step (/ (* 2.0f0 camera-distance three-compat:+tan-half-fov+)
                                                                height)))
                                                   (incf target-x (* step (- (* dy ux) (* dx rx))))
                                                   (incf target-y (* step (- (* dy uy) (* dx ry))))
                                                   (incf target-z (* step (- (* dy uz) (* dx rz))))))))
                                            (:dolly
                                             ;; 中ドラッグも原典の0.95^(|deltaY|*0.01)を使う。
                                             (setf camera-distance
                                                   (max 0.001f0
                                                        (* camera-distance
                                                           (expt 0.95f0 (/ (- dy) 100.0f0)))))))))
                                      (setf last-mouse-x x last-mouse-y y)
                                      ;; Source stores pointer coordinates in normalized device coordinates.
                                      (setf pointer-x
                                            (- (* (/ (float x 1.0f0) (float width 1.0f0)) 2.0f0)
                                               1.0f0))
                                      (setf pointer-y
                                            (- 1.0f0
                                               (* (/ (float y 1.0f0) (float height 1.0f0)) 2.0f0))))
                        (:windowevent (:event event :data1 w :data2 h)
                                      (when (or (= event sdl2-ffi:+sdl-windowevent-resized+)
                                                (= event sdl2-ffi:+sdl-windowevent-size-changed+))
                                        ;; 論理サイズだけ更新し、描画サイズはイベント処理後に取得する。
                                        (setf width w height h)))
                        (:idle ()
                               ;; キューが空なら入力処理を終えて描画へ進む。
                               (return-from drain-events nil))))
                    (unless quit
                      ;; イベント処理後に、論理サイズと描画ピクセル数を調べる。
                      (multiple-value-setq (width height)
                        (bridge-sdl2:logical-window-size window))
                      (multiple-value-bind (new-width new-height)
                          (bridge-sdl2:window-pixel-size window)
                        (when (and (plusp new-width) (plusp new-height)
                                   (or (/= new-width pixel-width)
                                       (/= new-height pixel-height)))
                          (setf pixel-width new-width pixel-height new-height)
                          (setf present-mode
                                (wgpu:configure-surface
                                 context pixel-width pixel-height present-mode))
                          ;; 修正箇所: Surfaceと同じタイミングでMSAA色テクスチャ・
                          ;; 深度テクスチャも新しいサイズへ作り直す。
                          (setf render-target
                                (wgpu:resize-render-target
                                 context render-target pixel-width pixel-height))))
                      (when (and (plusp width) (plusp height)
                                 (plusp pixel-width) (plusp pixel-height))
                        (let* ((now (get-internal-real-time))
                               (delta-time
                                (/ (- now last-time)
                                   (float internal-time-units-per-second 1.0f0)))
                               (now-ms
                                (* 1000.0f0
                                   (/ now
                                      (float internal-time-units-per-second 1.0f0)))))
                          (setf last-time now)
                          ;; このフレームに使う値を一度だけ取り出す。
                          (setf frame-separation (float *separation* 1.0f0))
                          (setf frame-alignment (float *alignment* 1.0f0))
                          (setf frame-cohesion (float *cohesion* 1.0f0))
                          (write-uniforms
                           context uniform pixel-width pixel-height delta-time now-ms
                           pointer-x pointer-y camera-yaw camera-pitch camera-distance
                           target-x target-y target-z
                           frame-separation frame-alignment frame-cohesion)
                          (let ((result
                                 (draw-frame
                                  context velocity-pipeline velocity-bind-group
                                  position-pipeline position-bind-group
                                  sky-pipeline sky-bind-group
                                  sky-vertex-buffer sky-index-buffer sky-index-count
                                  bird-pipeline bird-bind-group bird-vertex-buffer
                                  render-target pixel-width pixel-height)))
                            (when (minusp result)
                              (error "Birds draw failed"))
                            (when (= result 1)
                              (setf present-mode
                                    (wgpu:configure-surface
                                     context pixel-width pixel-height present-mode)))
                            ;; 描画できたフレームだけ数え、約1秒の実時間でFPSを計算する。
                            (when (= result 0)
                              (incf fps-frames))
                            (let ((elapsed (- (get-internal-real-time) fps-start)))
                              (when (>= elapsed internal-time-units-per-second)
                                (setf fps-value
                                      (/ (* fps-frames internal-time-units-per-second)
                                         (float elapsed 1.0f0)))
                                (setf fps-frames 0)
                                (setf fps-start (get-internal-real-time))
                                (update-window-title
                                 window fps-value frame-separation
                                 frame-alignment frame-cohesion)))
                            ;; Source executes pointer.y = 10 after renderer.render().
                            (setf pointer-y 10.0f0)))))))))
            ;; 修正箇所: render-targetはcontextのtracked-resourcesに
            ;; 入っていないため、release-contextより前に明示的に解放する。
            (progn
              (wgpu:release-render-target render-target)
              (wgpu:release-context context))))))))
(defun run-main-thread ()
  (setf *main-thread*
        (bt:make-thread #'main :name "SDL2-Dawn-Compute-Birds")))
(run-main-thread)
