;;;; lifegame.lisp -- 20,000 x 20,000 Conway's Game of Life
;;;;
;;;; 汎用の GPU 操作は wgpu.lisp、盤面のレイアウトと RLE 読み込みは rle.lisp。
;;;; このファイルが持つのは Life 固有のものだけ。
;;;;   - GPU バッファと pipeline の構成、BindGroup の配線
;;;;   - uniform 48 バイトの中身（WGSL の Params と1対1）
;;;;   - 8世代バッチと SPARSE/DENSE の更新手順
;;;;   - デジタル時計のローカル時刻同期
;;;;   - SDL のイベントループと表示
;;;;
;;;; 汎用側の関数は wgpu: を付けて呼ぶ。どこが境界かをコード上で見分けるため。
(declaim (optimize (speed 3) (safety 0) (debug 0)))
;; スレッド実行に使うBordeaux Threadsだけをアプリ側で読み込む。
;; SDL2連携とDawnの選択は、後で読み込む共通システムが担当する。
(defparameter *lifegame-bootstrap-source-directory*
  (uiop:pathname-directory-pathname
   (or *load-truename* *compile-file-truename*)))
(ql:quickload :bordeaux-threads)
(defpackage :lifegame
  (:use :cl)
  (:export :main))
(in-package :lifegame)
(defparameter *source-directory*
  cl-user::*lifegame-bootstrap-source-directory*)
;;; -------------------- 盤面とタイルの寸法 --------------------
;; この版の rle.lisp は寸法定数を定義せず、ここで定義された値を使う。
;; rle.lisp の読み込みと +grid-bytes+ の評価より前に定義する。
(defconstant +grid-width+ 20000)
(defconstant +grid-height+ 20000)
(defconstant +words-per-row+ (ceiling +grid-width+ 32))
(defconstant +word-count+ (* +words-per-row+ +grid-height+))
(defconstant +tile-core-words+ 4)
(defconstant +tile-core-rows+ 128)
(defconstant +tile-columns+ (ceiling +words-per-row+ +tile-core-words+))
(defconstant +tile-rows+ (ceiling +grid-height+ +tile-core-rows+))
(defconstant +tile-count+ (* +tile-columns+ +tile-rows+))
;; GPU共通層はASDFシステムとして読み込み、Life固有のRLE処理は
;; このディレクトリを基準に直接読み込む。
(push (truename "../../") asdf:*central-registry*)
(asdf:load-system :wgpu)
(load (merge-pathnames "rle.lisp" cl-user::*lifegame-bootstrap-source-directory*))
;; SDLウィンドウをWebGPU Surfaceへ接続する補助システム。
(asdf:load-system :wgpu/sdl2)
;; 以降の定義をLIFEGAMEパッケージへ置く。
(in-package :lifegame)
;;; -------------------- 表示・更新・時計の定数 --------------------
(defconstant +max-steps-per-frame+ 256)
(defconstant +sync-steps-per-batch+ 1024)
(defconstant +min-zoom-level+ -14)
(defconstant +max-zoom-level+ 19)
(defconstant +initial-zoom-level+ 16)
;; このLife時計は11,520世代で表示が1分進む。
(defconstant +clock-generations-per-minute+ 11520)
(defconstant +clock-generations-per-second+ (/ +clock-generations-per-minute+ 60))
(defconstant +clock-snapshot-minutes+ 10)
(defconstant +clock-snapshot-interval+
  (* +clock-generations-per-minute+ +clock-snapshot-minutes+))
(defconstant +clock-snapshot-base-generation+ 24883200)
(defconstant +clock-generations-per-day+ (* 24 60 +clock-generations-per-minute+))
(defconstant +clock-display-lag-generations+ +clock-generations-per-minute+)
(defconstant +clock-correction-seconds+ 300)
(defparameter *clock-url*
  "https://gist.githubusercontent.com/anonymous/9d7468755dd76a35d93beeb5c0a5bdcf/raw/3295717faf24e8911048bcb69d4b6c8505d24330/gistfile1.txt")
(defparameter *clock-path* (merge-pathnames "clock-ampm.rle" *source-directory*))
(defparameter *clock-snapshot-directory*
  (merge-pathnames "clock-snapshot-ampm/" *source-directory*))
;; WGSLコンパイル診断の出力先。ログ処理はGPU共通層が担当する。
(defparameter *shader-compile-log-path*
  (merge-pathnames "lifegame-shader-compile.log" *source-directory*))
;;; -------------------- Life 固有の GPU レイアウト --------------------
;;; ここの4定数と shader.wgsl の Params / binding 番号が対になっている。
(defconstant +uniform-bytes+ 48)
(defconstant +grid-bytes+ (* +word-count+ 4))
(defconstant +tile-buffer-bytes+ (* +tile-count+ 4))
(defconstant +indirect-bytes+ 12)
;; 画面全体を覆う三角形1枚。vs_main が3頂点を生成する。
(defconstant +fullscreen-vertex-count+ 3)
(defstruct life-state
  "GPU上に確保したLife用資源の一覧。
   cells[0] と cells[1] が「現在」と「次世代」を交互に担当する。
   current が 0 なら cells[0] が入力で、1回進めると 1 になり役割が入れ替わる。
   tile-flags / active-tiles / indirect-args も面と同じ番号にそろえてある。
   GPUハンドルはcontextが所有してrelease-contextで解放する。この構造体は
   各ハンドルの役割と、GPU資源ではない現在面番号currentを保持する。"
  (shader-module (cffi:null-pointer))
  (render-pipeline (cffi:null-pointer))
  (step-one-pipeline (cffi:null-pointer))
  (step-eight-pipeline (cffi:null-pointer))
  (clear-pipeline (cffi:null-pointer))
  (uniforms (cffi:null-pointer))
  (cells (vector nil nil))
  (tile-flags (vector nil nil))
  (active-tiles (vector nil nil))
  (indirect-args (vector nil nil))
  (render-groups (vector nil nil))
  (step-one-groups (vector nil nil))
  (step-eight-groups (vector nil nil))
  (clear-groups (vector nil nil))
  (current 0))
;;; -------------------- BindGroup の配線 --------------------
;;; binding 番号は shader.wgsl の @group(0) @binding(n) と対応する。
;; wgpu:bindingsにはbinding番号とバッファを交互に渡す。バッファ範囲は
;; Cブリッジが資源から取得するため、ここではバイト数を指定しない。
(defun step-bindings (state current)
  "step_one / step_eight の binding 0〜6。CURRENT が入力面、その逆が出力面。"
  (let ((next (logxor current 1)))
    (wgpu:bindings
     0 (life-state-uniforms state)
     1 (aref (life-state-cells state) current)
     2 (aref (life-state-cells state) next)
     3 (aref (life-state-active-tiles state) current)
     4 (aref (life-state-tile-flags state) next)
     5 (aref (life-state-active-tiles state) next)
     6 (aref (life-state-indirect-args state) next))))
(defun clear-bindings (state index)
  "clear_tiles が使う uniform、消去先 cells、候補一覧だけを配線する。
   binding 1（cells_in）は clear_tiles では使わないため欠番のままでよい。
   wgpu:bindings は番号を明示するので、連番でなくても問題なく使える。"
  (wgpu:bindings
   0 (life-state-uniforms state)
   2 (aref (life-state-cells state) index)
   3 (aref (life-state-active-tiles state) index)))
(defun render-bindings (state index)
  "描画 shader は画面設定と現在のセル面だけを読む。"
  (wgpu:bindings
   0 (life-state-uniforms state)
   1 (aref (life-state-cells state) index)))
;;; -------------------- GPU 資源の生成 --------------------
;; 生成した資源はcontextへ登録され、release-contextでまとめて解放される。
(defun create-life-pipelines (context state shader)
  "1個の WGSL から、3本の計算 pipeline と1本の描画 pipeline を作る。"
  (let ((module (wgpu:create-shader-module context shader)))
    (setf (life-state-shader-module state) module)
    ;; Pipeline作成前にWGSLの診断を記録し、メッセージがあれば
    ;; ログファイルとコンソールの両方へ出す。
    (let ((messages (wgpu:log-compile-messages
                     context module "shader.wgsl" *shader-compile-log-path*)))
      (when (and messages (plusp (length messages)))
        (format t "~&[lifegame] shader compilation messages (see ~A):~%~A"
                *shader-compile-log-path* messages)
        (finish-output)))
    (setf (life-state-step-one-pipeline state)
          (wgpu:create-compute-pipeline context module "step_one"))
    (setf (life-state-step-eight-pipeline state)
          (wgpu:create-compute-pipeline context module "step_eight"))
    (setf (life-state-clear-pipeline state)
          (wgpu:create-compute-pipeline context module "clear_tiles"))
    (setf (life-state-render-pipeline state)
          (wgpu:create-render-pipeline context module "vs_main" "fs_main"))))
(defun create-life-buffers (context state)
  "uniform 1個と、面ごとに2個ずつの buffer を作る。"
  (let ((uniform-usage (wgpu:usage-flags wgpu:+usage-uniform+ wgpu:+usage-copy-dst+))
        (storage-usage (wgpu:usage-flags wgpu:+usage-storage+ wgpu:+usage-copy-dst+))
        (indirect-usage (wgpu:usage-flags wgpu:+usage-storage+ wgpu:+usage-copy-dst+
                                          wgpu:+usage-indirect+)))
    (setf (life-state-uniforms state)
          (wgpu:create-buffer context uniform-usage +uniform-bytes+
                              "Create uniform buffer"))
    (dotimes (i 2)
      ;; cells は各約47.7MiB。入力と出力を交換するので2枚必要。
      (setf (aref (life-state-cells state) i)
            (wgpu:create-buffer context storage-usage +grid-bytes+
                                "Create cell buffer"))
      ;; flags は重複防止、active-tiles は候補番号、indirect-args は候補数。
      (setf (aref (life-state-tile-flags state) i)
            (wgpu:create-buffer context storage-usage +tile-buffer-bytes+
                                "Create tile flag buffer"))
      (setf (aref (life-state-active-tiles state) i)
            (wgpu:create-buffer context storage-usage +tile-buffer-bytes+
                                "Create active tile buffer"))
      (setf (aref (life-state-indirect-args state) i)
            (wgpu:create-buffer context indirect-usage +indirect-bytes+
                                "Create indirect buffer")))))
(defun create-life-bind-groups (context state)
  "4種類の pipeline それぞれについて、面0/面1用の BindGroup を作る。
   BindGroup生成関数がpipelineからlayoutを取得し、検査後に解放する。
   自動生成layoutはpipeline固有なので、step_oneとstep_eightはそれぞれ
   自身のpipelineからBindGroupを作る。"
  (dotimes (i 2)
    (setf (aref (life-state-step-one-groups state) i)
          (wgpu:create-compute-bind-group
           context (life-state-step-one-pipeline state) (step-bindings state i)
           "Create step_one bind group"))
    (setf (aref (life-state-step-eight-groups state) i)
          (wgpu:create-compute-bind-group
           context (life-state-step-eight-pipeline state) (step-bindings state i)
           "Create step_eight bind group"))
    (setf (aref (life-state-clear-groups state) i)
          (wgpu:create-compute-bind-group
           context (life-state-clear-pipeline state) (clear-bindings state i)
           "Create clear bind group"))
    (setf (aref (life-state-render-groups state) i)
          (wgpu:create-render-bind-group
           context (life-state-render-pipeline state) (render-bindings state i)
           "Create render bind group"))))
;;; -------------------- uniform と初期化データの転送 --------------------
(defun write-uniforms (context state width height center-x center-y zoom sparse-mode)
  "shader が毎フレーム読む値を送る。
   この48バイトの並びが WGSL の Params と一致していることが唯一の約束。
   Paramsはscreen、camera、gridの3つのvec4で構成される。Lisp側も
   vec4f/vec4uを1対1で渡し、各フィールドを16バイト境界へ配置する。"
  (wgpu:write-uniform-fields
   context (life-state-uniforms state)
   (wgpu:vec4f width height zoom 0.0f0) :vec4f                                           ; screen
   (wgpu:vec4f center-x center-y 0.0f0 0.0f0) :vec4f                                     ; camera
   (wgpu:vec4u +grid-width+ +grid-height+ +words-per-row+ (if sparse-mode 1 0)) :vec4u)) ; grid
;; test_chrome.jsのresetGridのうち、GPU上のセル、候補タイル、
;; 間接dispatch引数、現在面を初期化する部分に対応する。世代数、経過時間、
;; 停止状態、統計値に対応するLisp変数はRキーハンドラが初期化する。
(defun reset-life-buffers (context state initial-words active-tiles)
  "最初の盤面と候補タイルを、GPU の2面へ同じように入れ直す。"
  (let ((count (length active-tiles)))
    (cffi:with-foreign-object (indirect :uint32 3)
      ;; indirect[0] は実行する workgroup 数。y, z は 1 固定。
      (setf (cffi:mem-aref indirect :uint32 0) count)
      (setf (cffi:mem-aref indirect :uint32 1) 1)
      (setf (cffi:mem-aref indirect :uint32 2) 1)
      (dotimes (i 2)
        (wgpu:write-bytes context (aref (life-state-cells state) i)
                          initial-words +grid-bytes+)
        (wgpu:write-buffer context (aref (life-state-indirect-args state) i)
                           indirect +indirect-bytes+)))
    (when (plusp count)
      (dotimes (i 2)
        (wgpu:write-bytes context (aref (life-state-active-tiles state) i)
                          active-tiles (* count 4)))))
  (setf (life-state-current state) 0))
(defun init-life (context shader initial-words initial-active-tiles)
  "Life 固有の GPU 構成を組み立て、初期盤面を流し込む。
   生成途中でエラーになった資源もcontextが所有しているため、呼び出し元の
   unwind-protectがrelease-contextでまとめて解放する。"
  (let ((state (make-life-state)))
    (create-life-pipelines context state shader)
    (create-life-buffers context state)
    (create-life-bind-groups context state)
    (reset-life-buffers context state initial-words initial-active-tiles)
    state))
;;; -------------------- 更新手順を command list へ書く --------------------
;; command-listは必要に応じて伸びるため、命令数の事前計算は行わない。
;; encode-life-stepが1バッチを記録し、fill-life-commandsが要求世代数まで
;; バッチを繰り返す。
(defun encode-life-step (list state current batch sparse-mode)
  "CURRENT面からの1バッチ（batch=8なら8世代、batch=1なら1世代）ぶんの
   命令をcommand listへ積み、出力先の面番号（NEXT）を返す。
   test_chrome.jsのencodeStepに対応する。"
  (let* ((next (logxor current 1))
         (pipeline (if (= batch 8)
                       (life-state-step-eight-pipeline state)
                       (life-state-step-one-pipeline state)))
         (groups (if (= batch 8)
                     (life-state-step-eight-groups state)
                     (life-state-step-one-groups state))))
    ;; 次に使う面へ残っている古い印を消す。
    (wgpu:emit list wgpu:+clear-buffer+
               :object (aref (life-state-tile-flags state) next)
               :size +tile-buffer-bytes+)
    ;; SPARSE では、前回使った tile だけを先に空にする。
    ;; begin-pass/end-passの対はwith-compute-passで自動化した。
    (when sparse-mode
      (wgpu:with-compute-pass (list)
        (wgpu:emit list wgpu:+set-pipeline+
                   :object (life-state-clear-pipeline state))
        (wgpu:emit list wgpu:+set-bind-group+
                   :object (aref (life-state-clear-groups state) next))
        (wgpu:emit list wgpu:+dispatch-indirect+
                   :object (aref (life-state-indirect-args state) next))))
    ;; 次の候補数を0へ戻してから Life を計算する。
    (wgpu:emit list wgpu:+clear-buffer+
               :object (aref (life-state-indirect-args state) next)
               :size 4)
    (wgpu:with-compute-pass (list)
      (wgpu:emit list wgpu:+set-pipeline+ :object pipeline)
      (wgpu:emit list wgpu:+set-bind-group+ :object (aref groups current))
      (if sparse-mode
          (wgpu:emit list wgpu:+dispatch-indirect+
                     :object (aref (life-state-indirect-args state) current))
          (wgpu:emit list wgpu:+dispatch+ :x +tile-count+ :y 1 :z 1)))
    next))
(defun fill-life-commands (list state steps sparse-mode)
  "Life の更新手順を command list へ積み、次の面番号を返す。
   STEPSが尽きるまでencode-life-stepを繰り返し呼ぶ外側ループ。
   test_chrome.jsのadvanceLife/drawLife内のwhileループに対応する。"
  (let ((current (life-state-current state)))
    (loop while (plusp steps)
      for batch = (if (>= steps 8) 8 1)
      do
      (setf current (encode-life-step list state current batch sparse-mode))
      (decf steps batch))
    current))
(defmacro with-life-commands ((list-var next-var state steps sparse-mode) &body body)
  "Life の更新命令を積み、BODY を評価する。
   BODY が 0（成功）を返したときだけ面番号を進める。それ以外はロールバック。
   面の取り違えは目に見える形で壊れないため、ここだけは慎重に扱う。
   命令リストは自動的に伸びるため、必要な容量を事前計算しない。"
  (let ((state-sym (gensym "STATE"))
        (steps-sym (gensym "STEPS"))
        (sparse-sym (gensym "SPARSE"))
        (result-sym (gensym "RESULT")))
    `(let ((,state-sym ,state)
           (,steps-sym ,steps)
           (,sparse-sym ,sparse-mode))
       (wgpu:with-command-list (,list-var)
         (let ((,next-var (fill-life-commands ,list-var ,state-sym
                                              ,steps-sym ,sparse-sym)))
           (let ((,result-sym (progn ,@body)))
             (when (zerop ,result-sym)
               (setf (life-state-current ,state-sym) ,next-var))
             ,result-sym))))))
(defun advance-life (context state steps sparse-mode)
  "描画せずに STEPS 世代進める。起動時の早送りで使う。
   カメラと画面サイズは描画しないので0でよい。"
  (write-uniforms context state 0.0f0 0.0f0 0.0f0 0.0f0 0.0f0 sparse-mode)
  ;; next は with-life-commands が面番号の更新に使う。ここでは参照しない。
  (with-life-commands (list next state steps sparse-mode)
    (progn next)
    (wgpu:run context list :wait t)))
(defun draw-life (context state width height center-x center-y zoom steps sparse-mode)
  "Life を進め、その結果を1フレーム描いて画面へ出す。
   Compute命令と描画命令を別々のcommand-listへ記録し、
   wgpu:run-render-command-frameへまとめて渡す。MSAAと深度は使わず、
   render-targetを省略してSurfaceへ直接描画する。"
  (write-uniforms context state width height center-x center-y zoom sparse-mode)
  (let ((result
         (with-life-commands (list next state steps sparse-mode)
           (wgpu:with-command-list (draws)
             (wgpu:emit draws wgpu:+render-set-pipeline+
                        :object (life-state-render-pipeline state))
             (wgpu:emit draws wgpu:+render-set-bind-group+
                        :x 0 :object (aref (life-state-render-groups state) next))
             (wgpu:emit draws wgpu:+render-draw+
                        :x +fullscreen-vertex-count+ :y 1)
             (wgpu:run-render-command-frame
              context list draws (truncate width) (truncate height)
              :clear-color '(0.008d0 0.011d0 0.015d0 1.0d0))))))
    ;; Surface が古くなったときは、次のフレームに備えて設定し直す。
    (when (= result 1)
      (wgpu:configure-surface context (truncate width) (truncate height)
                              (wgpu:context-present-mode context)))
    result))
;;; -------------------- 実行時設定 --------------------
(defparameter *window-title* "WGPU Life 20000 x 20000")
(defparameter *window-width* 1200)
(defparameter *window-height* 800)
(defparameter *window-x* 80)
(defparameter *window-y* 80)
(defparameter *speed-levels*
  #(1.0d0 2.0d0 3.0d0 4.0d0 5.0d0
    10.0d0 20.0d0 30.0d0 40.0d0 50.0d0 60.0d0 70.0d0 80.0d0 90.0d0 100.0d0
    110.0d0 120.0d0 130.0d0 140.0d0 150.0d0 160.0d0 170.0d0 180.0d0 190.0d0
    192.0d0 200.0d0
    300.0d0 400.0d0 500.0d0 600.0d0 700.0d0 800.0d0 900.0d0 1000.0d0
    1100.0d0 1200.0d0 1300.0d0 1400.0d0 1500.0d0 1600.0d0 1700.0d0 1800.0d0
    1900.0d0 2000.0d0
    2100.0d0 2200.0d0 2300.0d0 2400.0d0 2500.0d0 2600.0d0 2700.0d0 2800.0d0
    2900.0d0 3000.0d0
    4000.0d0 5000.0d0 6000.0d0 7000.0d0 8000.0d0 9000.0d0 10000.0d0))
(defparameter *initial-speed* 50.0d0)
(defparameter *sparse-mode* t)
;; DawnではIMMEDIATEを初期選択する。
;; VキーでFIFO/IMMEDIATE/MAILBOXを順に切り替える。Windows以外はFIFO。
(defparameter *present-mode*
  (if (and (uiop:os-windows-p) (string= wgpu:*wgpu-impl* "dawn"))
      :immediate :fifo))
(defparameter *sync-to-local-time* t)
;; Vキーで切り替えるpresent modeの順序。
(defparameter *present-mode-cycle* '(:fifo :immediate :mailbox))
(defun next-present-mode (current)
  "CURRENTの次のモードを*present-mode-cycle*の順で返す。"
  (let ((position (position current *present-mode-cycle*)))
    (nth (mod (1+ (or position 0)) (length *present-mode-cycle*))
         *present-mode-cycle*)))
;;; -------------------- RLE と時計スナップショット --------------------
(defun ensure-clock-rle ()
  "リンク先の時計 RLE を一度だけ取得する。"
  (unless (probe-file *clock-path*)
    (let ((temporary (merge-pathnames "clock.rle.download" *source-directory*)))
      (format t "~&Downloading the digital clock RLE...~%  ~A~%" *clock-url*)
      (handler-case
          (progn
            (uiop:run-program
             (list "curl" "-L" "--fail" "--silent" "--show-error"
                   "--output" (namestring temporary) *clock-url*)
             :output *standard-output* :error-output *error-output*)
            (rename-file temporary *clock-path*))
        (error (condition)
          (when (probe-file temporary)
            (delete-file temporary))
          (error "Clock RLE download failed: ~A~%Save the linked RLE as ~A"
                 condition (namestring *clock-path*))))))
  *clock-path*)
;; test_chrome.jsのvalidateSnapshotGenerationが読むGenerationコメントを、
;; ファイルから取り出す。期待値との比較はclock-snapshot-infoが行う。
(defun read-snapshot-generation-comment (pathname)
  "Hashlife スナップショットに記録された世代数を読む。"
  (with-open-file (input pathname :direction :input)
    (loop for line = (read-line input nil nil)
      while line
      for marker = (search "#C Generation=" line)
      when marker do
      (return
        (parse-integer line
                       :start (+ marker (length "#C Generation="))
                       :junk-allowed t))
      finally
      (error "Snapshot has no Generation comment: ~A" pathname))))
(defun clock-snapshot-info (universal-time)
  "直前の10分スナップショットの pathname、世代数、基準時刻を返す。
   test_chrome.jsのsnapshotInfoとvalidateSnapshotGenerationに対応する。"
  ;; timezone を指定しない decode-universal-time は OS 設定のローカル時刻を返す。
  (multiple-value-bind (second minute hour) (decode-universal-time universal-time)
    (let* ((snapshot-minute (* (floor minute +clock-snapshot-minutes+)
                               +clock-snapshot-minutes+))
           (snapshot-index (+ (* hour (/ 60 +clock-snapshot-minutes+))
                              (/ snapshot-minute +clock-snapshot-minutes+)))
           (expected-generation (+ +clock-snapshot-base-generation+
                                   (* snapshot-index +clock-snapshot-interval+)))
           (snapshot-time (- universal-time second
                             (* 60 (mod minute +clock-snapshot-minutes+))))
           (pathname (merge-pathnames
                      (format nil "clock-~2,'0D-~2,'0D.rle" hour snapshot-minute)
                      *clock-snapshot-directory*)))
      (unless (probe-file pathname)
        (error "Clock snapshot is missing: ~A~%Unzip clock-snapshot.zip first."
               pathname))
      (let ((actual-generation (read-snapshot-generation-comment pathname)))
        (unless (= actual-generation expected-generation)
          (error "Wrong clock snapshot generation in ~A: expected ~:D, got ~:D"
                 pathname expected-generation actual-generation)))
      (list pathname expected-generation snapshot-time))))
(defun clock-target-generation (wall-time origin-time origin-generation)
  "起動同期の目標世代。日付をまたいでも 0 へ戻らないよう累積で数える。"
  (+ origin-generation
     (* (- wall-time origin-time) +clock-generations-per-second+)
     +clock-display-lag-generations+))
(defun local-generation-at (universal-time)
  "ローカル時刻に対応する世代の位相を返す。"
  (multiple-value-bind (second minute hour) (decode-universal-time universal-time)
    (+ +clock-snapshot-base-generation+
       (* (+ second (* 60 (+ minute (* 60 hour)))) +clock-generations-per-second+)
       +clock-display-lag-generations+)))
(defun clock-generation-difference (target current)
  "24時間の輪の上で、TARGET - CURRENT の最短の符号付き差を返す。"
  (let ((difference (mod (- target current) +clock-generations-per-day+))
        (half-day (/ +clock-generations-per-day+ 2)))
    (if (> difference half-day)
        (- difference +clock-generations-per-day+)
        difference)))
;;; -------------------- UI の小さな補助関数 --------------------
(defun zoom-for-level (level)
  (min 64.0f0 (max 0.05f0 (expt 1.25f0 level))))
(defun full-view-zoom-level (width height)
  (let ((required-zoom (* 1.04f0 (max (/ (float +grid-width+ 1.0f0) width)
                                      (/ (float +grid-height+ 1.0f0) height)))))
    (loop for level from +min-zoom-level+ to +max-zoom-level+
      when (>= (zoom-for-level level) required-zoom)
      return level
      finally (return +max-zoom-level+))))
(defun scancode-is (keysym code)
  (sdl2:scancode= (sdl2:scancode-value keysym) code))
(defun next-speed-level (speed)
  (or (find-if (lambda (level) (> level speed)) *speed-levels*)
      (aref *speed-levels* (1- (length *speed-levels*)))))
(defun previous-speed-level (speed)
  (or (find-if (lambda (level) (< level speed)) *speed-levels* :from-end t)
      (aref *speed-levels* 0)))
;; タイトルバーに表示するpresent mode名。
(defparameter *present-mode-labels*
  '((:fifo . "FIFO") (:immediate . "IMMEDIATE") (:mailbox . "MAILBOX")))
(defun present-mode-label (present-mode)
  (or (cdr (assoc present-mode *present-mode-labels*)) "FIFO"))
;;; -------------------- SDL イベントループ --------------------
(defun main (&key frame-limit (sync-to-local-time *sync-to-local-time*)
               (present-mode *present-mode*))
  (let* ((startup-time (get-universal-time))
         ;; 時刻同期時は直前の10分のRLE、同期無効時は初期RLEを読む。
         (source-info (if sync-to-local-time
                          (clock-snapshot-info startup-time)
                          (list (ensure-clock-rle) 0 startup-time)))
         (source-path (first source-info))
         (initial-generation (second source-info))
         (initial-sync-time (third source-info)))
    (multiple-value-bind (initial-words population pattern-width pattern-height
                          initial-active-tiles)
        (parse-rle-into-grid source-path)
      (format t "~&Clock loaded from ~A: ~Dx~D, ~:D live cells, generation ~:D, ~
                 grid ~Dx~D (~,1F MiB x 2).~%"
              (file-namestring source-path) pattern-width pattern-height population
              initial-generation +grid-width+ +grid-height+
              (/ +grid-bytes+ 1048576.0))
      (let ((shader (uiop:read-file-string
                     (merge-pathnames "shader.wgsl" *source-directory*))))
        (sdl2:with-init (:video)
          ;; with-window を抜けると SDL ウィンドウは自動的に片付けられる。
          (sdl2:with-window (window :title *window-title*
                                    :w *window-width* :h *window-height*
                                    :x *window-x* :y *window-y*
                             ;; 同期中の未完成な時計を見せないよう最初は隠す。
                                    :flags '(:hidden :resizable))
            ;; contextは全GPU資源を所有し、unwind-protectの後半でまとめて解放する。
            (let ((context nil)
                  (state nil)
                  ;; camera の単位はセル座標。center は画面中央に見せたい盤面位置。
                  (width *window-width*)
                  (height *window-height*)
                  (center-x (/ +grid-width+ 2.0f0))
                  (center-y (/ +grid-height+ 2.0f0))
                  (zoom-level +initial-zoom-level+)
                  (zoom (zoom-for-level +initial-zoom-level+))
                  (mouse-x 0.0f0)
                  (mouse-y 0.0f0)
                  (dragging nil)
                  ;; single-step は Right キーで予約された「あと何世代進めるか」。
                  (paused nil)
                  (single-step 0)
                  (observed-sparse-mode *sparse-mode*)
                  ;; accumulator は「進める時刻になったがまだ実行していない世代数」。
                  (speed (if sync-to-local-time
                             (float +clock-generations-per-second+ 1.0d0)
                             *initial-speed*))
                  (generation initial-generation)
                  (accumulator 0.0d0)
                  (syncing sync-to-local-time)
                  (sync-origin-time initial-sync-time)
                  (sync-origin-generation initial-generation)
                  (last-sync-report 0)
                  (next-clock-correction-time nil)
                  (last-time (get-internal-real-time))
                  (stats-start (get-internal-real-time))
                  (stats-generation 0)
                  (stats-frame-count 0)
                  (measured-speed 0.0d0)
                  (measured-fps 0.0d0)
                  (last-title 0)
                  (frames 0))
              (unwind-protect
                (progn
                     ;;; ---------- GPU を初期化する ----------
                  ;; SDLウィンドウからOS固有ハンドルを取得し、GPU contextを作る。
                  (setf context (wgpu:create-context (bridge-sdl2:get-window-system window)))
                  (setf state (init-life context shader initial-words
                                         initial-active-tiles))
                  (setf present-mode
                        (wgpu:configure-surface context width height present-mode))
                  (setf last-time (get-internal-real-time))
                  (setf stats-start last-time)
                  ;; 同期しない起動方法は、テストや初期盤面の確認に使う。
                  (unless syncing (sdl2:show-window window))
                     ;;; ---------- 入力と毎フレーム処理 ----------
                  ;; poll 方式はイベントがなくても :idle を繰り返す。そこで計算と描画。
                  (sdl2:with-event-loop (:method :poll)
                    (:quit () t)
                    (:windowevent (:event event :data1 d1 :data2 d2)
                                  ;; リサイズ後の幅・高さを Surface へ伝え、描画先を作り直す。
                                  (when (or (= event sdl2-ffi:+sdl-windowevent-resized+)
                                            (= event sdl2-ffi:+sdl-windowevent-size-changed+))
                                    (setf width d1)
                                    (setf height d2)
                                    (when (and (plusp d1) (plusp d2))
                                      (setf present-mode
                                            (wgpu:configure-surface context d1 d2 present-mode)))))
                    (:mousemotion (:x x :y y :xrel xrel :yrel yrel)
                                  (setf mouse-x (float x 1.0f0))
                                  (setf mouse-y (float y 1.0f0))
                                  (when dragging
                                    ;; 右へ動かしたらカメラを左へ。盤面をつかむ操作感になる。
                                    (decf center-x (* (float xrel 1.0f0) zoom))
                                    (decf center-y (* (float yrel 1.0f0) zoom))))
                    (:mousebuttondown (:button button)
                                      (when (= button sdl2-ffi:+sdl-button-left+)
                                        (setf dragging t)))
                    (:mousebuttonup (:button button)
                                    (when (= button sdl2-ffi:+sdl-button-left+)
                                      (setf dragging nil)))
                    (:mousewheel (:y wheel-y)
                                 (when (and (plusp width) (plusp height) (/= wheel-y 0))
                                   ;; zoom 前にカーソル下の盤面座標を記録し、zoom 後も同じ場所が
                                   ;; カーソル下に来るよう center を逆算する。
                                   (let* ((world-x (+ center-x (* (- mouse-x (/ width 2.0f0)) zoom)))
                                          (world-y (+ center-y (* (- mouse-y (/ height 2.0f0)) zoom)))
                                          (new-level (min +max-zoom-level+
                                                          (max +min-zoom-level+
                                                               (+ zoom-level
                                                                  (if (plusp wheel-y) -1 1)))))
                                          (new-zoom (zoom-for-level new-level)))
                                     (setf center-x (- world-x (* (- mouse-x (/ width 2.0f0))
                                                                  new-zoom)))
                                     (setf center-y (- world-y (* (- mouse-y (/ height 2.0f0))
                                                                  new-zoom)))
                                     (setf zoom-level new-level)
                                     (setf zoom new-zoom))))
                    (:keydown (:keysym keysym :repeat repeat)
                              ;; 押しっぱなしの自動リピートは無視し、1回押すごとに1段だけ。
                              (when (zerop repeat)
                                (cond
                                  ((scancode-is keysym :scancode-escape)
                                   (sdl2:push-event :quit))
                                  ((scancode-is keysym :scancode-space)
                                   (setf paused (not paused)))
                                  ((scancode-is keysym :scancode-right)
                                   (setf paused t)
                                   (incf single-step))
                                  ((scancode-is keysym :scancode-up)
                                   (setf speed (next-speed-level speed)))
                                  ((scancode-is keysym :scancode-down)
                                   (setf speed (previous-speed-level speed)))
                                  ((scancode-is keysym :scancode-v)
                                   ;; FIFO→IMMEDIATE→MAILBOXの順に切り替える。
                                   ;; 非対応の環境ではconfigure-surfaceがFIFOを選ぶ。
                                   (setf present-mode
                                         (wgpu:configure-surface
                                          context width height
                                          (next-present-mode present-mode)))
                                   ;; 切替前後の値を同じ測定区間へ混ぜない。
                                   (setf stats-start (get-internal-real-time))
                                   (setf stats-generation generation)
                                   (setf stats-frame-count 0)
                                   (setf measured-speed 0.0d0)
                                   (setf measured-fps 0.0d0))
                                  ((scancode-is keysym :scancode-f)
                                   (when (and (plusp width) (plusp height))
                                     (let ((new-level (full-view-zoom-level width height)))
                                       (setf center-x (/ +grid-width+ 2.0f0))
                                       (setf center-y (/ +grid-height+ 2.0f0))
                                       (setf zoom-level new-level)
                                       (setf zoom (zoom-for-level new-level)))))
                                  ((scancode-is keysym :scancode-r)
                                   (reset-life-buffers context state initial-words
                                                        initial-active-tiles)
                                   (setf generation initial-generation)
                                   (setf accumulator 0.0d0)
                                   (setf paused t)
                                   (setf stats-start (get-internal-real-time))
                                   (setf stats-generation initial-generation)
                                   (setf stats-frame-count 0)
                                   (setf measured-speed 0.0d0)
                                   (setf measured-fps 0.0d0)))))
                    (:idle ()
                           ;; now - last-timeを前フレームからの経過秒数として使う。
                           ;; 長い停止後に大量計算しないよう、1回分は最大0.25秒に丸める。
                           (let* ((now (get-internal-real-time))
                                  ;; この :idle が始まった時点で同期中かを覚えておく。
                                  ;; 同期完了と同じ回に通常時間も足すと経過を2回数える。
                                  (syncing-at-frame-start syncing)
                                  (raw-delta (/ (- now last-time)
                                                (float internal-time-units-per-second 1.0d0)))
                                  (delta (min 0.25d0 raw-delta)))
                             (setf last-time now)
                             (unless (eql observed-sparse-mode *sparse-mode*)
                               ;; REPL からモードが変わった場合、2モードの測定値を混ぜない。
                               (setf observed-sparse-mode *sparse-mode*)
                               (setf stats-start now)
                               (setf stats-generation generation)
                               (setf stats-frame-count 0)
                               (setf measured-speed 0.0d0)
                               (setf measured-fps 0.0d0))
                             ;; 同期中は画面を借りず、世代更新だけを GPU へ頼む。
                             ;; SPARSE は生きている周辺だけ計算するので同期に最も向く。
                             (when syncing
                               (let* ((wall-now (get-universal-time))
                                      (target (clock-target-generation
                                               wall-now sync-origin-time
                                               sync-origin-generation))
                                      (remaining (- target generation)))
                                 (if (plusp remaining)
                                     (let ((batch (min +sync-steps-per-batch+ remaining)))
                                       (when (minusp (advance-life context state batch t))
                                         (error "Local-time synchronization compute failed"))
                                       (incf generation batch)
                                       ;; 進捗は1秒に1回だけ表示し、端末を流しすぎない。
                                       (when (>= (- now last-sync-report)
                                                 internal-time-units-per-second)
                                         (setf last-sync-report now)
                                         (let ((completed (- generation sync-origin-generation))
                                               (total (- target sync-origin-generation)))
                                           (format t "~&Synchronizing: ~:D / ~:D generations ~
                                                    (~,1F%)~%"
                                                   completed total
                                                   (if (plusp total)
                                                       (* 100.0d0 (/ completed total))
                                                       100.0d0))
                                           (finish-output))))
                                     (progn
                                       ;; ここまで画面は一度も present していない。
                                       ;; 時刻が合ってから初めてウィンドウを見せる。
                                       (setf syncing nil)
                                       (setf accumulator 0.0d0)
                                       (setf last-time now)
                                       (setf stats-start now)
                                       (setf stats-generation generation)
                                       (setf stats-frame-count 0)
                                       (setf next-clock-correction-time
                                             (+ wall-now +clock-correction-seconds+))
                                       (sdl2:show-window window)
                                       (format t "~&Local-time synchronization complete ~
                                                at generation ~:D.~%"
                                                generation)
                                       (finish-output)))))
                             ;; 例: 0.02秒 x 192 gen/s = 3.84世代を accumulator へ足す。
                             ;; 同期中は advance-life が直接進めるので、ここへは足さない。
                             (unless (or paused syncing-at-frame-start)
                               (incf accumulator (* delta speed)))
                             ;; 192 gen/s で動いている時計は、5分ごとに OS 時刻と比べ直す。
                             ;; 遅れは正、進みすぎは負として accumulator へ入れる。
                             (when (and sync-to-local-time
                                        (not syncing)
                                        next-clock-correction-time
                                        (= speed (float +clock-generations-per-second+ 1.0d0)))
                               (let ((wall-now (get-universal-time)))
                                 (when (>= wall-now next-clock-correction-time)
                                   (let* ((target (local-generation-at wall-now))
                                          (difference (clock-generation-difference
                                                       target generation)))
                                     (setf accumulator (float difference 1.0d0))
                                     (setf next-clock-correction-time
                                           (+ wall-now +clock-correction-seconds+))
                                     (format t "~&Clock correction: ~:[ahead~;behind/on time~] ~
                                              by ~:D generations.~%"
                                             (not (minusp difference)) (abs difference))
                                     (finish-output)))))
                             (let* ((automatic (if (or paused syncing-at-frame-start)
                                                   0
                                                   ;; accumulator が負なら時計が進みすぎ。
                                                   ;; 0世代だけ進めて実時間の追いつきを待つ。
                                                   (max 0 (floor accumulator))))
                                    (wanted (+ automatic single-step))
                                    (steps (min +max-steps-per-frame+ wanted))
                                    (automatic-used (min automatic steps))
                                    (single-used (min single-step (- steps automatic-used))))
                               ;; 最小化中は幅や高さが0になる場合があるので描画を休む。
                               (when (and (not syncing) (plusp width) (plusp height))
                                 (let ((result
                                        (draw-life context state
                                                   (float width 1.0f0) (float height 1.0f0)
                                                   (float center-x 1.0f0)
                                                   (float center-y 1.0f0)
                                                   (float zoom 1.0f0) steps *sparse-mode*)))
                                   (when (minusp result) (error "Compute/draw frame failed"))
                                   (when (zerop result)
                                     ;; 成功した世代だけ予約数と表示世代から差し引く。
                                     (decf accumulator automatic-used)
                                     (decf single-step single-used)
                                     (incf generation steps)
                                     (incf frames)
                                     (incf stats-frame-count)))))
                             ;; 約1秒ごとに、進んだ世代数と描いたフレーム数で測定する。
                             (let ((stats-elapsed
                                    (/ (- now stats-start)
                                       (float internal-time-units-per-second 1.0d0))))
                               (when (>= stats-elapsed 1.0d0)
                                 (setf measured-speed (/ (- generation stats-generation)
                                                         stats-elapsed))
                                 (setf measured-fps (/ stats-frame-count stats-elapsed))
                                 (setf stats-start now)
                                 (setf stats-generation generation)
                                 (setf stats-frame-count 0)))
                             ;; タイトル更新は毎秒4回までにして無駄を減らす。
                             (when (> (- now last-title) (/ internal-time-units-per-second 4))
                               (setf last-title now)
                               (sdl2:set-window-title
                                window
                                (format nil "Life 20000^2 | ~:[DENSE~;SPARSE~] | ~A | gen ~:D ~
                                           | ~:[RUN~;PAUSE~] | target ~A gen/s ~
                                           | actual ~,1F gen/s | ~,1F fps | zoom ~,1F cell/px"
                                        *sparse-mode*
                                        (present-mode-label present-mode)
                                        generation paused
                                        (if (= speed 192.0d0)
                                            "*192*"
                                            (format nil "~,1F" speed))
                                        measured-speed measured-fps zoom)))
                             (when (and frame-limit (>= frames frame-limit))
                               (sdl2:push-event :quit))
                             ;; イベントループの最後に1ms休んでCPUの占有を抑える。
                             (sdl2:delay 1)))))
                ;;; ---------- 終了時の後片付け ----------
                ;; unwind-protect の後半なので、途中でエラーが起きてもここは実行される。
                ;; contextが追跡するLife固有資源とDawn環境を正しい順序で解放する。
                (wgpu:release-context context)))))))))
(defparameter *main-thread* nil)
(defun run-main-thread () (setf *main-thread* (bt:make-thread #'main :name "SDL2-WGPU-Life")))
(run-main-thread)
;; (when *auto-start*
;;   ;; LIFEGAME_NO_AUTOSTART=1ならロードだけ行い、手動でmainを呼べる。
;;   (run-main-thread))
