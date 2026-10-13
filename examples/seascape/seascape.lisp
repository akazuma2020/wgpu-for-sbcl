;;;; seascape.lisp -- 海の映像を表示する小さなプログラム。
;;;; wgpu.lisp と bridge のプログラムは書き換えず、そのまま使う。
;;;; このファイル、wgpu.lisp、seascape.wgsl を同じ場所に置く。
;;;; GPUの実装はwgpu.lispが決める。Windowsでは通常Dawnを使う。
;; 修正箇所（2026-10-07・パッケージ管理のASDF対応）: wgpu.lisp /
;; bridge-sdl2.lisp の読み込みを (load ...) から (asdf:load-system ...) へ
;; 変更した。wgpu.asdがwgpu/packages・wgpu・wgpu/sdl2の3システムを定義して
;; いるため、DLLの存在確認・PATH設定・(ql:quickload :sdl2)等の副作用は
;; 従来どおり読み込み時に自動的に走る。:bordeaux-threadsはSDL2固有ではなく
;; スレッド用途のため、従来どおりここで個別にquickloadする。
(defparameter *seascape-directory*
  (uiop:pathname-directory-pathname (or *load-truename* *compile-file-truename*)))

(push (truename "../../") asdf:*central-registry*)
(asdf:load-system :wgpu)
(asdf:load-system :wgpu/sdl2)
(ql:quickload :bordeaux-threads)
(defpackage :seascape
  (:use :cl)
  (:export :main :run-main-thread :*main-thread*))
(in-package :seascape)
(defparameter *window-width* 1200)
(defparameter *window-height* 400)
;; (defparameter *present-mode* :immediate)
(defparameter *present-mode* :fifo)
(defparameter *main-thread* nil)
;; 修正箇所（2026-10-07）: シェーダーのコンパイルメッセージをログファイルへ
;; 出力する処理は、wgpu:log-compile-messages（汎用関数、wgpu.lisp側）へ
;; 移した。ここではログの出力先パスだけを決める（アプリ固有の知識）。
(defparameter *shader-compile-log-path*
  (merge-pathnames "seascape-shader-compile.log" cl-user::*seascape-directory*))
(defun write-uniforms (context buffer width height elapsed)
  ;; 修正箇所: 実際のseascape.wgsl側のstruct Uniformsを確認したところ、
  ;;   struct Uniforms {
  ;;       iResolution: vec2f,
  ;;       iTime: f32,
  ;;       _padding: f32,
  ;;   };
  ;; という定義で、iResolutionはvec2<f32>（width/heightの組）だった。
  ;; wgpu:vec2f型を使うことで、以前+paddingで手計算していた末尾4バイトの
  ;; 空きが自動的に挿入されるようになった（vec2f=アラインメント8・サイズ8、
  ;; floatが続くと合計12バイトになり、構造体全体のアラインメント8の倍数
  ;; である16バイトへ自動的に切り上げられる）。
  (wgpu:write-uniform-fields
   context buffer
   (wgpu:vec2f (float width 1.0f0) (float height 1.0f0)) :vec2f  ; iResolution
   (float elapsed 1.0f0)                                 :float))  ; iTime
(defun draw-frame (context pipeline bind-group width height)
  ;; 修正箇所: wgpu:run-frame（MSAAも深度も持たない単純な描画専用の関数）が
  ;; 廃止されたため、birds.lispと同じwgpu:run-render-command-frameを使う形に
  ;; 書き換えた。描画命令（pipelineの設定・bind-groupの設定・draw）は
  ;; 自分でcommand listへ積む。
  ;; 修正箇所: wgpu.lispのrun-render-command-frameから:sample-count/
  ;; :depth-enabledキーワードが廃止され、:render-targetに統合された。
  ;; seascapeはMSAAも深度も使わないため、:render-targetを省略する
  ;; （既定値のNILがSurfaceへ直接描く経路を選ぶ）。以前ここで
  ;; :sample-count 1 :depth-enabled nil を渡していたのは、
  ;; 「Unknown &KEY argument」エラーの原因だったため削除した。
  ;; width/heightはCの関数がswapchainのサイズとして必要とするため、
  ;; 新たに引数として受け取るようにした（run-frameでは不要だった）。
  (wgpu:with-command-list (commands)
    (wgpu:with-command-list (draws)
      (wgpu:emit draws wgpu:+render-set-pipeline+ :object pipeline)
      (wgpu:emit draws wgpu:+render-set-bind-group+ :x 0 :object bind-group)
      (wgpu:emit draws wgpu:+render-draw+ :x 3 :y 1)
      (wgpu:run-render-command-frame
       context commands draws width height
       :clear-color '(0.0d0 0.0d0 0.0d0 1.0d0)))))
;; 修正箇所: 資源を作る手順をmain本体から切り出した専用関数。
;; GPU資源（buffer/pipeline/shader-module/bind-group）はすべて
;; wgpu:create-*経由でcontextへ自動登録されるため、main側で1つずつ
;; 変数に持たせて最後に解放する処理が不要になった。
(defun init-seascape (context shader)
  "GPU資源一式を作って values で返す。"
  (let* ((module (wgpu:create-shader-module context shader)))
    ;; 修正箇所（2026-10-07）: shader-module作成の直後、pipeline作成より前に
    ;; コンパイルメッセージを確認する。原典のgetCompilationInfoは、WGSLの
    ;; コンパイルが終わった時点で呼べるAPIであり、pipeline作成の成否とは
    ;; 独立しているため、ここが最も早いタイミングになる。
    ;; 修正箇所: ログ出力処理そのものはwgpu:log-compile-messages（汎用関数、
    ;; wgpu.lisp側）へ渡すだけ。戻り値（メッセージ文字列）が空でなければ、
    ;; 見落とし防止のためコンソールへも出す（この判断はアプリ側の責務）。
    (let ((messages (wgpu:log-compile-messages
                     context module "seascape.wgsl" *shader-compile-log-path*)))
      (when (and messages (plusp (length messages)))
        (format t "~&[seascape] shader compilation messages (see ~A):~%~A"
                *shader-compile-log-path* messages)
        (finish-output)))
    (let* ((pipeline (wgpu:create-render-pipeline context module "vsMain" "fsMain"))
           (uniform
            (wgpu:create-buffer
             context
             (wgpu:usage-flags wgpu:+usage-uniform+ wgpu:+usage-copy-dst+)
             16 "Seascape uniform"))
           ;; 修正箇所: layoutの取得→作成→解放の3行を、
           ;; wgpu:create-render-bind-group の1行にまとめた。
           ;; サイズ(16)も省略でき、C側がバッファに問い合わせる。
           (bind-group
            (wgpu:create-render-bind-group
             context pipeline (wgpu:bindings 0 uniform)
             "Seascape bind group")))
      (values pipeline uniform bind-group))))
(defun main (&key (present-mode *present-mode*))
  (let ((shader (uiop:read-file-string
                 (merge-pathnames "seascape.wgsl" cl-user::*seascape-directory*))))
    (sdl2:with-init (:video)
      (sdl2:with-window (window :title "Seascape WebGPU"
                                :w *window-width* :h *window-height*
                                :flags '(:resizable))
        ;; 修正箇所: 以前はcontext以下4個の資源用変数をすべてnilで
        ;; 宣言し、progn内でsetfして、unwind-protectの後半で4個の
        ;; when式による手作業の解放処理を書いていた。GPU資源は
        ;; init-seascapeへ切り出し、解放は(wgpu:release-context context)
        ;; の1行だけになった。
        (let ((context nil)
              (pipeline nil)
              (uniform nil)
              (bind-group nil)
              (width *window-width*)
              (height *window-height*)
              (start-time (get-internal-real-time)))
          (unwind-protect
            (progn
              ;; 修正箇所: 「SDL2のウィンドウハンドル取得」と
              ;; 「wgpu:create-contextによるGPU初期化」の2処理を、
              ;; 呼び出し側で明確に分離した。
              ;; bridge-sdl2:get-window-system（bridge-sdl2.lisp）は
              ;; OSごとのハンドルをplistとして返すだけで、GPU初期化は
              ;; 行わない。wgpu:create-contextがWINDOW-SYSTEMを1個の
              ;; 位置引数として受け取る形になったため、ここで直接渡して
              ;; GPU初期化を行う。
              (setf context (wgpu:create-context (bridge-sdl2:get-window-system window)))
              (multiple-value-setq (pipeline uniform bind-group)
                (init-seascape context shader))
              (setf present-mode
                    (wgpu:configure-surface context width height present-mode))
              (setf start-time (get-internal-real-time))
              (sdl2:with-event-loop (:method :poll)
                (:quit () t)
                (:keydown
                 (:keysym keysym :repeat repeat)
                 (when (and (zerop repeat)
                            (sdl2:scancode=
                             (sdl2:scancode-value keysym) :scancode-escape))
                   (sdl2:push-event :quit)))
                (:windowevent
                 (:event event :data1 w :data2 h)
                 (when (or (= event sdl2-ffi:+sdl-windowevent-resized+)
                           (= event sdl2-ffi:+sdl-windowevent-size-changed+))
                   (setf width w)
                   (setf height h)
                   (when (and (plusp width) (plusp height))
                     (setf present-mode
                           (wgpu:configure-surface
                            context width height present-mode)))))
                (:idle
                 ()
                 (when (and (plusp width) (plusp height))
                   (write-uniforms
                    context uniform width height
                    (/ (- (get-internal-real-time) start-time)
                       (float internal-time-units-per-second 1.0f0)))
                   (let ((result (draw-frame context pipeline bind-group width height)))
                     (when (minusp result)
                       (error "Seascape draw failed"))
                     (when (= result 1)
                       (setf present-mode
                             (wgpu:configure-surface
                              context width height present-mode))))))))
            ;; 修正箇所: 以前はbind-group/uniform/pipeline/moduleをそれぞれ
            ;; whenで解放する4行を書いていた。release-contextの1回呼び出しで
            ;; 登録済みの資源がすべて正しい順序で解放される。
            (wgpu:release-context context)))))))
(defun run-main-thread ()
  ;; 修正箇所: 描画を別のスレッドで動かし、REPLを使えるようにする。
  (setf *main-thread*
        (bt:make-thread #'main :name "SDL2-WGPU-Seascape")))
(run-main-thread)
