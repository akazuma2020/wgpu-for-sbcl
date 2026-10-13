;;;; Common Lisp向けWebGPU環境のASDF定義。
;;;;
;;;; :wgpu/packagesは公開パッケージ、:wgpuはGPU共通層、:wgpu/sdl2は
;;;; SDL2連携、:wgpu/three-compatはThree.js互換の純粋計算を読み込む。
;;;; アプリは必要な層だけに依存し、不要なDLL読込みを避ける。
;;;; これを一番先に読むことで、以降どのファイルが先にコンパイルされても
;;;; パッケージ自体はすでに存在している状態になる。

(defsystem "wgpu/packages"
  :description "wgpu / bridge-sdl2 / three-compat のパッケージ定義のみ"
  :components
  ((:file "packages")))

(defsystem "wgpu"
  :description "wgpu-native / Dawn 共通の Lisp 側ラッパ"
  :depends-on ("wgpu/packages" :cffi)
  :components
  ((:file "wgpu")))

(defsystem "wgpu/sdl2"
  :description "SDL2 を使う利用側のための Surface 作成補助"
  :depends-on ("wgpu/packages" :sdl2 :sdl2-image)
  :components
  ((:file "bridge-sdl2")))

(defsystem "wgpu/three-compat"
  :description "Three.js が提供していた機能を代替する純粋関数群"
  :depends-on ("wgpu/packages")
  :components
  ((:file "three-compat")))


