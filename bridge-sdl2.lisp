;;;; SDL2を利用するアプリ向けのウィンドウ・画像補助。
;;;;
;;;; SDL_WindowからOS固有ハンドルと表示寸法を取得し、修飾キー状態と
;;;; RGBA8画像読込みを提供する。GPU初期化はwgpu.lispに委ねる。
;;;; SDL_SysWMinfoのFFI配置は64bit環境を前提とする。
(ql:quickload :sdl2)
(ql:quickload :sdl2-image)
(in-package :bridge-sdl2)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (cffi:define-foreign-library bridge-sdl2-lib
    (:windows "SDL2.dll")
    (:unix (:or "libSDL2-2.0.so.0" "libSDL2.so"))))
(cffi:use-foreign-library bridge-sdl2-lib)
;; SDL_GetVersionは実行時のSDL2.dllが自身の版を答える関数（コンパイル時の
;; 定数を使うSDL_VERSIONマクロと違い、FFI経由でもそのまま呼べる）。
(cffi:defcfun ("SDL_GetVersion" %sdl-get-version :library bridge-sdl2-lib) :void
  (version :pointer))
;; SDL_boolはC enumでABI上intと同じなので:intで受ける。
(cffi:defcfun ("SDL_GetWindowWMInfo" %sdl-get-window-wm-info
                                     :library bridge-sdl2-lib)
    :int
  (window :pointer) (info :pointer))
(cffi:defcfun ("SDL_GetWindowSize" %logical-window-size :library bridge-sdl2-lib)
    :void
  (window :pointer) (logical-width :pointer) (logical-height :pointer))
(defun logical-window-size (window)
  "SDLのマウス入力と同じ座標系のウィンドウサイズを返す。"
  (cffi:with-foreign-objects ((logical-width :int) (logical-height :int))
    (%logical-window-size (autowrap:ptr window) logical-width logical-height)
    (values (cffi:mem-ref logical-width :int)
            (cffi:mem-ref logical-height :int))))
(cffi:defcfun ("SDL_GetWindowSizeInPixels" %window-pixel-size :library bridge-sdl2-lib)
    :void
  (window :pointer) (pixel-width :pointer) (pixel-height :pointer))
(defun window-pixel-size (window)
  "SDLのウィンドウ座標ではなく、描画先の実ピクセル数を返す。"
  (cffi:with-foreign-objects ((pixel-width :int) (pixel-height :int))
    (%window-pixel-size (autowrap:ptr window) pixel-width pixel-height)
    (values (cffi:mem-ref pixel-width :int)
            (cffi:mem-ref pixel-height :int))))
;; SDL2のKeymodは左右のShift/Control/GUI(Meta)をビットで返す。
;; #x0cc3はShift(左右)・Control(左右)・GUI(左右)に対応するビットのOR。
(cffi:defcfun ("SDL_GetModState" %sdl-get-mod-state :library bridge-sdl2-lib)
    :uint16)
(defun modifier-key-pressed-p ()
  "Shift・Control・GUI(Meta)のいずれかが押されているか調べる。
   利用側で修飾キー併用操作（例: ドラッグ操作の種類切り替え）を
   判定する際に使う汎用関数。"
  (not (zerop (logand (%sdl-get-mod-state) #x0cc3))))
;; SDL_SYSWM_TYPE の値。公式ヘッダ（SDL_syswm.h）のenum定義
;;   SDL_SYSWM_UNKNOWN, SDL_SYSWM_WINDOWS, SDL_SYSWM_X11, SDL_SYSWM_DIRECTFB,
;;   SDL_SYSWM_COCOA, SDL_SYSWM_UIKIT, SDL_SYSWM_WAYLAND, ...
;; の並び順そのまま（0始まり）。
(defconstant +syswm-windows+ 1)
(defconstant +syswm-x11+ 2)
(defconstant +syswm-wayland+ 6)
;; SDL_SysWMinfo の実体を書き込む領域の大きさと、unionが始まるオフセット。
;; 上記コメントのとおり、header部8バイト+union 64バイト=72バイトとした。
(defconstant +syswm-info-size+ 72)
(defconstant +syswm-union-offset+ 8)
(defun query-window-platform-handles (window-pointer)
  "SDL_Windowの生ポインタから、SDL_GetWindowWMInfoで実際のOSハンドルを取り出す。
   戻り値は (values subsystem-keyword handle1 handle2)。
     :win32   の場合 (hinstance hwnd)
     :x11     の場合 (display window)
     :wayland の場合 (display surface)"
  (cffi:with-foreign-object (info :uint8 +syswm-info-size+)
    ;; 構造体全体を一度ゼロクリアしてから、version/subsystemを書く。
    ;; unionの未使用領域にゴミが残らないようにするため。
    (dotimes (i +syswm-info-size+)
      (setf (cffi:mem-aref info :uint8 i) 0))
    ;; versionはSDL_SysWMinfoの先頭3バイト(major/minor/patch)と並びが同じ。
    (%sdl-get-version info)
    (unless (plusp (%sdl-get-window-wm-info window-pointer info))
      (error "SDL_GetWindowWMInfo failed"))
    (let ((subsystem (cffi:mem-ref info :int32 4)))
      (cond
        ((= subsystem +syswm-windows+)
         (values :win32
                 (cffi:mem-ref info :pointer (+ +syswm-union-offset+ 16))  ; hinstance
                 (cffi:mem-ref info :pointer (+ +syswm-union-offset+ 0)))) ; hwnd
        ((= subsystem +syswm-x11+)
         (values :x11
                 (cffi:mem-ref info :pointer (+ +syswm-union-offset+ 0))  ; display
                 (cffi:mem-ref info :uint64  (+ +syswm-union-offset+ 8)))) ; window(XID)
        ((= subsystem +syswm-wayland+)
         (values :wayland
                 (cffi:mem-ref info :pointer (+ +syswm-union-offset+ 0))  ; display
                 (cffi:mem-ref info :pointer (+ +syswm-union-offset+ 8)))) ; surface
        (t (error "Unsupported SDL subsystem: ~D" subsystem))))))
(defun get-window-system (window)
  "WINDOWはcl-sdl2のwindowオブジェクト（sdl2:with-window等が返すもの）。
   内部でSDL_GetWindowWMInfoを呼び、実OSに応じて
   (:win32-hinstance ... :win32-hwnd ...) / (:x11-display ... :x11-window ...) /
   (:wayland-display ... :wayland-surface ...) のいずれかのplistを返す。
   戻り値はwgpu:create-contextへ (wgpu:create-context (get-window-system window))
   としてそのまま渡せる形になっている。GPU初期化（wgpu:create-contextの
   呼び出し）は行わない。"
  (multiple-value-bind (subsystem handle1 handle2)
      (query-window-platform-handles (autowrap:ptr window))
    (ecase subsystem
      (:win32 (list :win32-hinstance handle1 :win32-hwnd handle2))
      (:x11 (list :x11-display handle1 :x11-window handle2))
      (:wayland (list :wayland-display handle1 :wayland-surface handle2)))))
(cffi:defcfun ("SDL_ConvertSurfaceFormat" %convert-surface-format
                                          :library bridge-sdl2-lib) :pointer
  (surface :pointer) (pixel-format :uint32) (flags :uint32))
;; SDL_PIXELFORMAT_RGBA32は、SDL_pixels.hでエンディアンに応じて
;; SDL_PIXELFORMAT_RGBA8888（リトルエンディアン環境）またはABGR8888
;; （ビッグエンディアン環境）に展開されるマクロだが、値そのもの
;; （0x16762004）は公式ヘッダのビルド時定数としてどちらの環境でも
;; 同一である（マクロはどちらに展開するかを選ぶだけで、選んだ後の
;; 列挙値自体はリトルエンディアン環境の値に固定されている）。
;; 開発環境はWindows x64（リトルエンディアン）のため、この値を
;; 直接使ってよい。
(defconstant +sdl-pixelformat-rgba32+ #x16762004)
;; SDL_ConvertSurfaceFormatが返す生ポインタは、cl-sdl2のsurface-width等の
;; アクセサ（autowrap:wrapperを前提とする可能性がある）に直接渡すと
;; 不整合が起きる恐れがあるため、ここだけはSDL_Surfaceの構造体レイアウト
;; （SDL2公式Wiki「SDL2/SDL_Surface」のフィールド定義順序: flags/format/
;; w/h/pitch/pixels と、x64でのポインタアラインメント規則から導出:
;; flags=0、format=8（ポインタの8バイト境界で4バイトのパディング挿入）、
;; w=16、h=20、pitch=24、pixels=32（再びポインタの8バイト境界で
;; 4バイトのパディング挿入））を手で読む。
(defun converted-surface-width (surface) (cffi:mem-ref surface :int32 16))
(defun converted-surface-height (surface) (cffi:mem-ref surface :int32 20))
(defun converted-surface-pitch (surface) (cffi:mem-ref surface :int32 24))
(defun converted-surface-pixels (surface) (cffi:mem-ref surface :pointer 32))
(cffi:defcfun ("SDL_FreeSurface" %free-converted-surface :library bridge-sdl2-lib) :void
  (surface :pointer))
(defun load-image-rgba8 (path)
  "PATHの画像ファイル（PNG/JPEG等、SDL2_imageが対応する形式）を読み込み、
   RGBA8（1ピクセル4バイト、パディングなしで詰めた状態）のバイト列へ
   変換して返す。戻り値は (values byte-vector width height)。
   byte-vectorは (unsigned-byte 8) の単純ベクタで、
   wgpu:write-textureへそのまま渡せる形になっている。
   画像のデコードに失敗した場合はエラーを投げる。"
  (let ((loaded (sdl2-image:load-image (namestring path))))
    (unwind-protect
         ;; loadedはcl-sdl2-imageが返すautowrap:wrapper。生ポインタへ
         ;; 変換してからSDL_ConvertSurfaceFormatへ渡す。
         (let ((converted (%convert-surface-format
                            (autowrap:ptr loaded) +sdl-pixelformat-rgba32+ 0)))
           (when (cffi:null-pointer-p converted)
             (error "SDL_ConvertSurfaceFormat failed for ~A" path))
           (unwind-protect
                (let* ((width (converted-surface-width converted))
                       (height (converted-surface-height converted))
                       (pitch (converted-surface-pitch converted))
                       (pixels (converted-surface-pixels converted))
                       (bytes-per-row (* width 4))
                       (result (make-array (* bytes-per-row height)
                                           :element-type '(unsigned-byte 8))))
                  ;; pitchは変換後のサーフェスでも詰め物（パディング）を
                  ;; 含む場合があるため、行ごとにbytes-per-rowぶんだけ
                  ;; コピーし、詰め物は捨てる。write-textureへ渡す
                  ;; バイト列はパディングなしの密な並びに統一する。
                  (dotimes (y height)
                    (let ((source-offset (* y pitch))
                          (dest-offset (* y bytes-per-row)))
                      (dotimes (i bytes-per-row)
                        (setf (aref result (+ dest-offset i))
                              (cffi:mem-ref pixels :uint8 (+ source-offset i))))))
                  (values result width height))
             (%free-converted-surface converted)))
      (sdl2:free-surface loaded))))
