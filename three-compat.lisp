;;;; Three.jsの一部に対応する、状態を持たない数値計算。
;;;;
;;;; icosphere生成、ベクトル演算、orbitカメラ、look-at基底、画面座標からの
;;;; ray生成を提供する。関数は入力を変更せず、新しい値または多値を返す。

(in-package :three-compat)
(defconstant +tan-half-fov+ 0.46630767f0)
(defun vector3-lerp (a b fraction)
  "Vector3.lerp(v, alpha) に対応する非破壊版。
   A・B（3要素配列）をFRACTIONで直線補間した新しい3要素配列を返す
   （正規化はしない）。AをBへ書き換えて返すThree.js版とは異なり、
   Aは変更せず新しい配列を返す点に注意。"
  (let ((result (make-array 3)))
    (dotimes (axis 3 result)
      (setf (aref result axis)
            (+ (aref a axis)
               (* (- (aref b axis) (aref a axis)) fraction))))))
(defun vector3-normalized (point)
  "Vector3.normalize() に対応する非破壊版。
   POINT（3要素配列）を原点からの距離1へ正規化した値を
   多値 (x y z) で返す。POINT自体は変更しない。"
  (let* ((x (aref point 0))
         (y (aref point 1))
         (z (aref point 2))
         (length (sqrt (+ (* x x) (* y y) (* z z)))))
    (values (float (/ x length) 1.0f0)
            (float (/ y length) 1.0f0)
            (float (/ z length) 1.0f0))))
(defun icosahedron-geometry (detail)
  "THREE.IcosahedronGeometry(1, DETAIL) に対応。
   半径1の正二十面体をDETAIL段階で分割し、球に近づけた頂点・インデックス
   配列を多値 (vertex-data index-data) で返す。"
  (let* ((golden (/ (+ 1.0d0 (sqrt 5.0d0)) 2.0d0))
         (vertices
          (vector (vector -1.0d0 golden 0.0d0)
                  (vector 1.0d0 golden 0.0d0)
                  (vector -1.0d0 (- golden) 0.0d0)
                  (vector 1.0d0 (- golden) 0.0d0)
                  (vector 0.0d0 -1.0d0 golden)
                  (vector 0.0d0 1.0d0 golden)
                  (vector 0.0d0 -1.0d0 (- golden))
                  (vector 0.0d0 1.0d0 (- golden))
                  (vector golden 0.0d0 -1.0d0)
                  (vector golden 0.0d0 1.0d0)
                  (vector (- golden) 0.0d0 -1.0d0)
                  (vector (- golden) 0.0d0 1.0d0)))
         (faces
          '((0 11 5) (0 5 1) (0 1 7) (0 7 10) (0 10 11)
            (1 5 9) (5 11 4) (11 10 2) (10 7 6) (7 1 8)
            (3 9 4) (3 4 2) (3 2 6) (3 6 8) (3 8 9)
            (4 9 5) (2 4 11) (6 2 10) (8 6 7) (9 8 1)))
         (cols (1+ detail))
         (vertex-count (* 20 cols cols 3))
         (vertex-data (make-array (* vertex-count 3) :element-type 'single-float))
         (index-data (make-array vertex-count :element-type '(unsigned-byte 32)))
         (next-vertex 0))
    (labels ((emit-vertex! (point)
               (multiple-value-bind (x y z) (vector3-normalized point)
                 (let ((base (* next-vertex 3)))
                   (setf (aref vertex-data base) x)
                   (setf (aref vertex-data (+ base 1)) y)
                   (setf (aref vertex-data (+ base 2)) z)
                   (setf (aref index-data next-vertex) next-vertex)
                   (incf next-vertex)))))
      (dolist (face faces)
        (destructuring-bind (a-index b-index c-index) face
          (let* ((a (aref vertices a-index))
                 (b (aref vertices b-index))
                 (c (aref vertices c-index))
                 (grid (make-array (1+ cols))))
            ;; 原典のsubdivideFaceは、各面をdetail+1列へ一度だけ分割する。
            (dotimes (i (1+ cols))
              (let* ((rows (- cols i))
                     (aj (vector3-lerp a c (/ i cols)))
                     (bj (vector3-lerp b c (/ i cols)))
                     (row (make-array (1+ rows))))
                (dotimes (j (1+ rows))
                  (setf (aref row j)
                        (if (and (zerop j) (= i cols))
                            aj
                            (vector3-lerp aj bj (/ j rows)))))
                (setf (aref grid i) row)))
            ;; 三角形の頂点順も原典と同じ。Bridgeは連番Indexで描く。
            (dotimes (i cols)
              (dotimes (j (1- (* 2 (- cols i))))
                (let ((k (floor j 2)))
                  (if (evenp j)
                      (progn
                        (emit-vertex! (aref (aref grid i) (1+ k)))
                        (emit-vertex! (aref (aref grid (1+ i)) k))
                        (emit-vertex! (aref (aref grid i) k)))
                      (progn
                        (emit-vertex! (aref (aref grid i) (1+ k)))
                        (emit-vertex! (aref (aref grid (1+ i)) (1+ k)))
                        (emit-vertex! (aref (aref grid (1+ i)) k))))))))))
      (unless (= next-vertex vertex-count)
        (error "Sky vertex count mismatch: ~D instead of ~D"
               next-vertex vertex-count))
      (values vertex-data index-data))))
(defun orbit-position (yaw pitch distance)
  "OrbitControls内部の球面座標→直交座標変換に対応。
   ヨー・ピッチ・距離から、原点を中心とした球面上のカメラ位置を
   多値 (x y z) で返す。"
  (let* ((cos-yaw (cos yaw))
         (sin-yaw (sin yaw))
         (cos-pitch (cos pitch))
         (sin-pitch (sin pitch)))
    (values (* distance sin-yaw cos-pitch)
            (* distance sin-pitch)
            (* distance cos-yaw cos-pitch))))
(defun look-at-basis (eye-x eye-y eye-z)
  "Matrix4.lookAt(eye, target, up) 相当。TARGETは常に原点として、
   EYE（カメラ位置）から原点を見るときの右・上・前の基底ベクトルを
   多値 (right-x right-y right-z up-x up-y up-z forward-x forward-y forward-z)
   で返す。"
  (let* ((forward-length (sqrt (+ (* eye-x eye-x) (* eye-y eye-y) (* eye-z eye-z))))
         (forward-x (/ (- eye-x) forward-length))
         (forward-y (/ (- eye-y) forward-length))
         (forward-z (/ (- eye-z) forward-length))
         (right-length (sqrt (+ (* forward-z forward-z) (* forward-x forward-x))))
         (right-x (/ (- forward-z) right-length))
         (right-z (/ forward-x right-length))
         (up-x (* (- right-z) forward-y))
         (up-y (- (* right-z forward-x) (* right-x forward-z)))
         (up-z (* right-x forward-y)))
    (values right-x 0.0f0 right-z
            up-x up-y up-z
            forward-x forward-y forward-z)))
(defun raycaster-ray-from-camera (pointer-x pointer-y width height yaw pitch distance
                                  target-x target-y target-z)
  "Raycaster.setFromCamera(coords, camera) に対応する非破壊版
   （raycasterインスタンスの状態は持たず、計算結果を多値で返す）。
   画面上のポインター位置から、移動後のカメラに対応するワールド空間Rayを
   多値 (origin-x origin-y origin-z direction-x direction-y direction-z) で返す。"
  (multiple-value-bind (camera-x camera-y camera-z)
      (orbit-position yaw pitch distance)
    (multiple-value-bind (right-x right-y right-z
                          up-x up-y up-z
                          forward-x forward-y forward-z)
        (look-at-basis camera-x camera-y camera-z)
      (let* ((aspect (/ width (float height 1.0f0)))
             (local-x (* pointer-x +tan-half-fov+ aspect))
             (local-y (* pointer-y +tan-half-fov+))
             (world-x (+ (* right-x local-x) (* up-x local-y) forward-x))
             (world-y (+ (* right-y local-x) (* up-y local-y) forward-y))
             (world-z (+ (* right-z local-x) (* up-z local-y) forward-z))
             (ray-length (sqrt (+ (* world-x world-x)
                                  (* world-y world-y)
                                  (* world-z world-z)))))
        ;; パンした注視点をRayの始点にも反映する。
        (values (+ camera-x target-x) (+ camera-y target-y) (+ camera-z target-z)
                (/ world-x ray-length) (/ world-y ray-length) (/ world-z ray-length))))))
