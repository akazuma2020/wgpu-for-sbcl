// Browser control layer using three.js + TSL for the SPARSE-mode Life
// algorithm (8-generation batching, candidate-tile indirect dispatch).
// Counterpart to test_chrome.js (raw WebGPU), reproducing bridge.c and
// lifegame.lisp's clock-snapshot initialization and local-time
// synchronization logic, in addition to the Life algorithm itself.
//
// 【今回の追加1】1世代だけ進めるstep_one相当のロジック
// 原典test_chrome.js / shader.wgslのstep_one(共有メモリ・haloを使わず、
// grid_wordで直接9近傍を読む単純な1世代更新)をTSLへ移植した。
// これにより、advanceLife/synchronizeClock/frameでの世代数調整は
// BATCH_STEPS(8)の倍数に丸める必要がなくなり、原典と同じく
// 「8世代バッチ + 端数は1世代ずつ」という組み合わせで正確な世代数を
// 扱えるようになった。
//
// 【今回の再追加】カメラを引いたとき(縮小表示)のドット補完
// (rangeHasLife、原典shader.wgslのfs_main/range_has_life相当)を、
// 今回は生WGSL(tsl.wgslFn)で実装し直した。
// 前回のTSLネイティブ実装(ネストしたforループ+If()+.toVar()蓄積)は、
// 画面が枠線の色一色で塗りつぶされる重大な退行を引き起こした。
// これは別件(v5のanyAliveLocal問題、tsl_localindex_in_loop_test.html)
// で確認済みの「TSLのJS側ループ展開+.toVar()蓄積」に起因する未知の
// バグと同種の可能性が高いと判断し、今回はTSLのノードグラフを経由
// しない生WGSL関数(本物のWGSL for/if/returnで実行時に早期終了する)
// として書き直すことで、この既知の問題領域を迂回した。
// ストレージバッファの読み込みには、原典mark_next_candidates(生WGSL)
// と同じ考え方で、wordsNodeをそのまま渡している(fs_main文脈では
// .assign()を一度も呼ばないため、TSL側で自動的にread専用の
// bindingとして生成されるはずという前提に基づく。未検証)。
// 1世代処理(sparseStepOne)は今回のロールバック/再追加と無関係なため、
// 変更していない。
//
// 色空間の補正:
// three.jsのWebGPURendererは既定で、colorNodeの出力値を「リニア
// 色空間」として扱い、画面出力時にsRGBへのガンマ補正を自動的にかける。
// 原典shader.wgslは生のWebGPU APIで最終ピクセル値をそのまま返すため、
// renderer.outputColorSpace = THREE.LinearSRGBColorSpace でこの
// 自動変換をスキップする。
const canvas = document.querySelector('#life');
const loading = document.querySelector('#loading');
const loadingTitle = document.querySelector('#loading-title');
const loadingDetail = document.querySelector('#loading-detail');
const hud = document.querySelector('#hud');
const statsElement = document.querySelector('#stats');
const messageElement = document.querySelector('#message');
const controls = document.querySelector('#controls');
const pauseButton = document.querySelector('#pause');
const stepButton = document.querySelector('#step');
const fullButton = document.querySelector('#full');
const resetButton = document.querySelector('#reset');
function setLoading(title, detail = '') {
  loadingTitle.textContent = title;
  loadingDetail.textContent = detail;
}
function setMessage(message) {
  messageElement.textContent = message;
}
function formatInteger(value) {
  return Math.trunc(value).toLocaleString('en-US');
}
const SPEED_LEVELS = Object.freeze([
  1, 2, 3, 4, 5,
  10, 20, 30, 40, 50, 60, 70, 80, 90, 100,
  110, 120, 130, 140, 150, 160, 170, 180, 190, 192, 200,
  210, 220, 230, 240, 250, 260, 270, 280, 290, 300,
  400, 500, 600, 700, 800, 900, 1000,
  1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000,
  3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000,
]);
const MAX_STEPS_PER_FRAME = 256;
const SYNC_STEPS_PER_BATCH = 1024;
// -------------------- 時計関連の定数（原典test_chrome.jsと完全に同じ値） --------------------
const CLOCK_GENERATIONS_PER_SECOND = 192;
const CLOCK_SNAPSHOT_INTERVAL = 115_200;
const CLOCK_SNAPSHOT_BASE_GENERATION = 24_883_200;
const CLOCK_GENERATIONS_PER_DAY = 24 * 60 * 60 * CLOCK_GENERATIONS_PER_SECOND;
const CLOCK_DISPLAY_LAG_GENERATIONS = 11_520;
const CLOCK_CORRECTION_MS = 300_000;
function showError(err) {
  console.error(err);
  loading.hidden = false;
  canvas.classList.add('waiting');
  hud.hidden = true;
  controls.hidden = true;
  setLoading('エラーが発生しました', (err && err.stack) ? err.stack : String(err));
}
// -------------------- 時計関連のヘルパー関数（原典をそのまま移植） --------------------
function zoomForLevel(level) {
  return Math.min(64, Math.max(0.05, 1.25 ** level));
}
function snapshotInfo(date) {
  const hour = date.getHours();
  const snapshotMinute = Math.floor(date.getMinutes() / 10) * 10;
  const snapshotIndex = hour * 6 + snapshotMinute / 10;
  const generation = CLOCK_SNAPSHOT_BASE_GENERATION + snapshotIndex * CLOCK_SNAPSHOT_INTERVAL;
  // 現在のepoch時刻から端数だけを引く。夏時間切替付近でも「直前10分」を保つ。
  const elapsedMs = (
    (date.getMinutes() % 10) * 60 + date.getSeconds()
  ) * 1000 + date.getMilliseconds();
  const hh = String(hour).padStart(2, '0');
  const mm = String(snapshotMinute).padStart(2, '0');
  return {
    url: `clock-snapshot-ampm/clock-${hh}-${mm}.rle`,
    generation,
    originWallMs: date.getTime() - elapsedMs,
  };
}
async function fetchText(url, description) {
  const response = await fetch(url, { cache: 'no-cache' });
  if (!response.ok) {
    throw new Error(`${description}の取得に失敗しました (${response.status} ${response.statusText}): ${url}`);
  }
  return response.text();
}
function validateSnapshotGeneration(text, expectedGeneration, sourceName) {
  const match = text.match(/^#C Generation=(\d+)\b.*$/m);
  if (!match) throw new Error(`スナップショットにGenerationコメントがありません: ${sourceName}`);
  const actual = Number(match[1]);
  if (actual !== expectedGeneration) {
    throw new Error(`スナップショット世代が違います: expected ${expectedGeneration}, got ${actual}`);
  }
}
function localGenerationAt(date) {
  const seconds = date.getHours() * 3600 + date.getMinutes() * 60 + date.getSeconds();
  return CLOCK_SNAPSHOT_BASE_GENERATION
    + seconds * CLOCK_GENERATIONS_PER_SECOND
    + CLOCK_DISPLAY_LAG_GENERATIONS;
}
function positiveModulo(value, modulus) {
  return ((value % modulus) + modulus) % modulus;
}
function clockGenerationDifference(target, current) {
  const difference = positiveModulo(target - current, CLOCK_GENERATIONS_PER_DAY);
  return difference > CLOCK_GENERATIONS_PER_DAY / 2
    ? difference - CLOCK_GENERATIONS_PER_DAY
    : difference;
}
async function main() {
  const THREE = await import('three');
  const { WebGPURenderer, StorageBufferAttribute, MeshBasicNodeMaterial } = await import('three/webgpu');
  const tsl = await import('three/tsl');
  // ================================================================
  // 共通定数（原典test_chrome.jsと完全に同じ値）
  // ================================================================
  const GRID_WIDTH = 20000;
  const GRID_HEIGHT = 20000;
  const WORDS_PER_ROW = Math.ceil(GRID_WIDTH / 32); // 625
  const CORE_WORDS = 4;
  const CORE_ROWS = 128;
  const BATCH_STEPS = 8;
  const TILE_WORDS = CORE_WORDS + 2;        // 6
  const TILE_ROWS = CORE_ROWS + BATCH_STEPS * 2; // 144（workgroup内の共有メモリタイル高さ、haloを含む）
  const TILE_SIZE = TILE_WORDS * TILE_ROWS;  // 864
  const WORKGROUP_THREADS = 64;
  const TILE_ITERATIONS = Math.ceil(TILE_SIZE / WORKGROUP_THREADS); // 14
  const CORE_SIZE = CORE_WORDS * CORE_ROWS;  // 512
  const CORE_ITERATIONS = Math.ceil(CORE_SIZE / WORKGROUP_THREADS); // 8（割り切れる）
  // 修正箇所/注記: 原典と同じくMath.ceilでタイル数を求める。
  // TILE_ROWS_COUNT(157)は、上のTILE_ROWS(144, 共有メモリタイル高さ)
  // とは全く別の意味（グリッド全体を何行のタイルで覆うか）。
  const TILE_COLUMNS = Math.ceil(WORDS_PER_ROW / CORE_WORDS); // 157
  const TILE_ROWS_COUNT = Math.ceil(GRID_HEIGHT / CORE_ROWS); // 157
  const TOTAL_TILES = TILE_COLUMNS * TILE_ROWS_COUNT;         // 24,649
  const WORD_COUNT = WORDS_PER_ROW * GRID_HEIGHT;             // 12,500,000
  const MIN_ZOOM_LEVEL = -14;
  const MAX_ZOOM_LEVEL = 19;
  const INITIAL_ZOOM_LEVEL = 16;
  // ================================================================
  // RLEパース（原典parseRleをそのまま移植、定数名のみ本実装に合わせる）
  // ================================================================
  function parseRle(text) {
    const lines = text.split(/\r?\n/);
    let width = null;
    let height = null;
    const bodyLines = [];
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed === '' || trimmed.startsWith('#')) continue;
      if (width === null) {
        const match = trimmed.match(/x\s*=\s*(\d+)\s*,\s*y\s*=\s*(\d+)/i);
        if (match) {
          width = Number(match[1]);
          height = Number(match[2]);
          continue;
        }
      }
      bodyLines.push(trimmed);
    }
    if (width === null || height === null) throw new Error('RLE headerがありません。');
    if (width > GRID_WIDTH || height > GRID_HEIGHT) {
      throw new Error(`RLE ${width}x${height} は ${GRID_WIDTH}x${GRID_HEIGHT} の盤面に収まりません。`);
    }
    const words = new Uint32Array(WORD_COUNT);
    const occupied = new Uint8Array(TOTAL_TILES);
    const offsetX = Math.floor((GRID_WIDTH - width) / 2);
    const offsetY = Math.floor((GRID_HEIGHT - height) / 2);
    const body = bodyLines.join('');
    let x = 0;
    let y = 0;
    let run = 0;
    let liveCount = 0;
    const takeRun = () => {
      const count = run === 0 ? 1 : run;
      run = 0;
      return count;
    };
    for (let index = 0; index < body.length; index += 1) {
      const character = body[index];
      const code = body.charCodeAt(index);
      if (code >= 48 && code <= 57) {
        run = run * 10 + code - 48;
        continue;
      }
      if (character === 'b' || character === 'B' || character === 'o' || character === 'O') {
        const count = takeRun();
        if (x + count > width || y >= height) {
          throw new Error(`RLE bodyが宣言寸法を超えました: (${x}, ${y})`);
        }
        if (character === 'o' || character === 'O') {
          for (let cell = 0; cell < count; cell += 1) {
            const gridX = offsetX + x + cell;
            const gridY = offsetY + y;
            const wordX = gridX >>> 5;
            words[gridY * WORDS_PER_ROW + wordX] |= (1 << (gridX & 31)) >>> 0;
            const tileX = Math.floor(wordX / CORE_WORDS);
            const tileY = Math.floor(gridY / CORE_ROWS);
            occupied[tileY * TILE_COLUMNS + tileX] = 1;
          }
          liveCount += count;
        }
        x += count;
        continue;
      }
      if (character === '$') {
        y += takeRun();
        x = 0;
        if (y > height) throw new Error('RLE bodyが宣言された高さを超えました。');
        continue;
      }
      if (character === '!') break;
      if (!/\s/.test(character)) throw new Error(`不正なRLE文字: ${JSON.stringify(character)}`);
    }
    const candidates = new Uint8Array(TOTAL_TILES);
    for (let tile = 0; tile < TOTAL_TILES; tile += 1) {
      if (occupied[tile] === 0) continue;
      const tileX = tile % TILE_COLUMNS;
      const tileY = Math.floor(tile / TILE_COLUMNS);
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          const nextX = tileX + dx;
          const nextY = tileY + dy;
          if (nextX >= 0 && nextX < TILE_COLUMNS && nextY >= 0 && nextY < TILE_ROWS_COUNT) {
            candidates[nextY * TILE_COLUMNS + nextX] = 1;
          }
        }
      }
    }
    let tileCount = 0;
    for (const candidate of candidates) tileCount += candidate;
    const tiles = new Uint32Array(tileCount);
    let tileOutput = 0;
    for (let tile = 0; tile < TOTAL_TILES; tile += 1) {
      if (candidates[tile]) tiles[tileOutput++] = tile;
    }
    return { words, tiles, liveCount, width, height };
  }
  // ================================================================
  // 起動シーケンス: 時計スナップショットの読み込み（原典main()を移植）
  // ================================================================
  setLoading('three.js + TSL を初期化しています', '時計スナップショットを読み込みます。');
  const syncToLocalTime = new URLSearchParams(location.search).get('sync') !== '0';
  const startupDate = new Date();
  const source = syncToLocalTime
    ? snapshotInfo(startupDate)
    : { url: 'clock-ampm.rle', generation: 0, originWallMs: startupDate.getTime() };
  let speed = syncToLocalTime ? CLOCK_GENERATIONS_PER_SECOND : 50;
  const initialGeneration = source.generation;
  let generation = source.generation;
  let syncOriginGeneration = source.generation;
  let syncOriginWallMs = source.originWallMs;
  const sourceName = source.url.split('/').at(-1);
  setLoading('ファイルを読み込んでいます', `${sourceName}`);
  const rleText = await fetchText(source.url, '時計RLE').catch((error) => {
    if (syncToLocalTime) {
      throw new Error(`${error.message}\nclock-snapshot-ampm/をtest_three.htmlと同じ場所へ展開してください。`);
    }
    throw error;
  });
  if (syncToLocalTime) validateSnapshotGeneration(rleText, source.generation, source.url);
  setLoading('RLEを展開しています', `${GRID_WIDTH} x ${GRID_HEIGHT} のビット盤面を作成中です。`);
  await new Promise(requestAnimationFrame);
  const parsed = parseRle(rleText);
  const initialWords = parsed.words;
  const initialTiles = parsed.tiles;
  setLoading(
    'WebGPUを初期化しています',
    `${parsed.width} x ${parsed.height}, ${formatInteger(parsed.liveCount)} live cells, ${formatInteger(parsed.tiles.length)} active tiles`,
  );
  await new Promise(requestAnimationFrame);
  // ================================================================
  // レンダラーの初期化
  // ================================================================
  const renderer = new WebGPURenderer({ canvas, antialias: false });
  renderer.setClearColor(new THREE.Color(0.008, 0.011, 0.015), 1.0);
  renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
  renderer.toneMapping = THREE.NoToneMapping;
  await renderer.init();
  const backend = renderer.backend;
  const device = backend.device;
  const queue = device.queue;
  const uncapturedErrors = [];
  device.addEventListener('uncapturederror', (event) => {
    uncapturedErrors.push(event.error.message);
    console.error('[uncapturederror]', event.error.message);
  });
  // ================================================================
  // 共通ロジック: gridWord・lifeWord（検証済み、bitAnd等を使用）
  // ================================================================
  function gridWord(wordsNode, wordX, y) {
    const outOfRange = wordX.lessThan(tsl.int(0))
      .or(y.lessThan(tsl.int(0)))
      .or(wordX.greaterThanEqual(tsl.int(WORDS_PER_ROW)))
      .or(y.greaterThanEqual(tsl.int(GRID_HEIGHT)));
    const index = tsl.uint(y).mul(tsl.uint(WORDS_PER_ROW)).add(tsl.uint(wordX));
    return tsl.select(outOfRange, tsl.uint(0), wordsNode.element(index));
  }
  function lifeWord(al, ac, ar, ml, mc, mr, bl, bc, br) {
    const n0 = tsl.bitOr(ac.shiftLeft(tsl.uint(1)), al.shiftRight(tsl.uint(31)));
    const n1 = ac;
    const n2 = tsl.bitOr(ac.shiftRight(tsl.uint(1)), ar.shiftLeft(tsl.uint(31)));
    const n3 = tsl.bitOr(mc.shiftLeft(tsl.uint(1)), ml.shiftRight(tsl.uint(31)));
    const n4 = tsl.bitOr(mc.shiftRight(tsl.uint(1)), mr.shiftLeft(tsl.uint(31)));
    const n5 = tsl.bitOr(bc.shiftLeft(tsl.uint(1)), bl.shiftRight(tsl.uint(31)));
    const n6 = bc;
    const n7 = tsl.bitOr(bc.shiftRight(tsl.uint(1)), br.shiftLeft(tsl.uint(31)));
    const neighbours = [n0, n1, n2, n3, n4, n5, n6, n7];
    const ones = tsl.uint(0).toVar();
    const twos = tsl.uint(0).toVar();
    const fours = tsl.uint(0).toVar();
    const eights = tsl.uint(0).toVar();
    for (const neighbour of neighbours) {
      const carry1 = tsl.bitAnd(ones, neighbour).toVar();
      ones.assign(tsl.bitXor(ones, neighbour));
      const carry2 = tsl.bitAnd(twos, carry1).toVar();
      twos.assign(tsl.bitXor(twos, carry1));
      const carry3 = tsl.bitAnd(fours, carry2).toVar();
      fours.assign(tsl.bitXor(fours, carry2));
      eights.assign(tsl.bitXor(eights, carry3));
    }
    const highClear = tsl.bitNot(tsl.bitOr(fours, eights));
    const exactlyTwo = tsl.bitAnd(tsl.bitAnd(tsl.bitNot(ones), twos), highClear);
    const exactlyThree = tsl.bitAnd(tsl.bitAnd(ones, twos), highClear);
    return tsl.bitOr(exactlyThree, tsl.bitAnd(mc, exactlyTwo));
  }
  // ================================================================
  // バッファ一式
  // ================================================================
  const bufB1 = new StorageBufferAttribute(new Uint32Array(initialWords), 1);
  const bufB2 = new StorageBufferAttribute(new Uint32Array(WORD_COUNT), 1);
  const nodeB1 = tsl.storage(bufB1, 'uint', WORD_COUNT);
  const nodeB2 = tsl.storage(bufB2, 'uint', WORD_COUNT);
  const activeTilesAttr1 = new StorageBufferAttribute(new Uint32Array(TOTAL_TILES), 1);
  const activeTilesAttr2 = new StorageBufferAttribute(new Uint32Array(TOTAL_TILES), 1);
  const activeTilesNode1 = tsl.storage(activeTilesAttr1, 'uint', TOTAL_TILES);
  const activeTilesNode2 = tsl.storage(activeTilesAttr2, 'uint', TOTAL_TILES);
  const tileAliveAttr1 = new StorageBufferAttribute(new Uint32Array(TOTAL_TILES), 1);
  const tileAliveAttr2 = new StorageBufferAttribute(new Uint32Array(TOTAL_TILES), 1);
  const tileAliveNode1 = tsl.storage(tileAliveAttr1, 'uint', TOTAL_TILES);
  const tileAliveNode2 = tsl.storage(tileAliveAttr2, 'uint', TOTAL_TILES);
  // ================================================================
  // TSL: sparseStep（Life本体 + 生存判定、atomicOr回避策使用）
  // 8世代をまとめて進める(原典shader.wgslのstep_eight相当)。
  // ================================================================
  function makeSparseStepNode(wordsIn, wordsOut, activeTilesIn, tileAliveOut) {
    const tileA = tsl.workgroupArray('uint', TILE_SIZE).setName('lifeTileA');
    const tileB = tsl.workgroupArray('uint', TILE_SIZE).setName('lifeTileB');
    const anyAliveShared = tsl.workgroupArray('uint', 1).toAtomic().setName('anyAliveShared');
    return tsl.Fn(() => {
      const localIndex = tsl.invocationLocalIndex;
      const workgroupId = tsl.instanceIndex.sub(localIndex).div(tsl.uint(WORKGROUP_THREADS));
      const tileIndex = activeTilesIn.element(workgroupId);
      const tileX = tileIndex.mod(tsl.uint(TILE_COLUMNS));
      const tileY = tileIndex.div(tsl.uint(TILE_COLUMNS));
      const baseWord = tsl.int(tileX.mul(tsl.uint(CORE_WORDS)));
      const baseY = tsl.int(tileY.mul(tsl.uint(CORE_ROWS)));
      tsl.If(localIndex.equal(tsl.uint(0)), () => {
        tsl.atomicStore(anyAliveShared.element(tsl.uint(0)), tsl.uint(0));
      });
      tsl.workgroupBarrier();
      for (let iteration = 0; iteration < TILE_ITERATIONS; iteration++) {
        const index = localIndex.add(tsl.uint(iteration * WORKGROUP_THREADS));
        tsl.If(index.lessThan(tsl.uint(TILE_SIZE)), () => {
          const tx = index.mod(tsl.uint(TILE_WORDS));
          const ty = index.div(tsl.uint(TILE_WORDS));
          const value = gridWord(wordsIn,
            baseWord.add(tsl.int(tx)).sub(tsl.int(1)),
            baseY.add(tsl.int(ty)).sub(tsl.int(BATCH_STEPS)));
          tileA.element(index).assign(value);
        });
      }
      tsl.workgroupBarrier();
      for (let generationStep = 0; generationStep < BATCH_STEPS; generationStep++) {
        const source = (generationStep % 2 === 0) ? tileA : tileB;
        const dest = (generationStep % 2 === 0) ? tileB : tileA;
        for (let iteration = 0; iteration < TILE_ITERATIONS; iteration++) {
          const index = localIndex.add(tsl.uint(iteration * WORKGROUP_THREADS));
          tsl.If(index.lessThan(tsl.uint(TILE_SIZE)), () => {
            const tx = index.mod(tsl.uint(TILE_WORDS));
            const ty = index.div(tsl.uint(TILE_WORDS));
            const left = tsl.select(tx.greaterThan(tsl.uint(0)), index.sub(tsl.uint(1)), index);
            const right = tsl.select(tx.add(tsl.uint(1)).lessThan(tsl.uint(TILE_WORDS)), index.add(tsl.uint(1)), index);
            const above = tsl.select(ty.greaterThan(tsl.uint(0)), index.sub(tsl.uint(TILE_WORDS)), index);
            const below = tsl.select(ty.add(tsl.uint(1)).lessThan(tsl.uint(TILE_ROWS)), index.add(tsl.uint(TILE_WORDS)), index);
            const aboveLeft = tsl.select(tx.greaterThan(tsl.uint(0)).and(ty.greaterThan(tsl.uint(0))), above.sub(tsl.uint(1)), above);
            const aboveRight = tsl.select(tx.add(tsl.uint(1)).lessThan(tsl.uint(TILE_WORDS)).and(ty.greaterThan(tsl.uint(0))), above.add(tsl.uint(1)), above);
            const belowLeft = tsl.select(tx.greaterThan(tsl.uint(0)).and(ty.add(tsl.uint(1)).lessThan(tsl.uint(TILE_ROWS))), below.sub(tsl.uint(1)), below);
            const belowRight = tsl.select(tx.add(tsl.uint(1)).lessThan(tsl.uint(TILE_WORDS)).and(ty.add(tsl.uint(1)).lessThan(tsl.uint(TILE_ROWS))), below.add(tsl.uint(1)), below);
            const globalWord = baseWord.add(tsl.int(tx)).sub(tsl.int(1));
            const globalY = baseY.add(tsl.int(ty)).sub(tsl.int(BATCH_STEPS));
            const inGrid = globalWord.greaterThanEqual(tsl.int(0))
              .and(globalY.greaterThanEqual(tsl.int(0)))
              .and(globalWord.lessThan(tsl.int(WORDS_PER_ROW)))
              .and(globalY.lessThan(tsl.int(GRID_HEIGHT)));
            const next = tsl.uint(0).toVar();
            tsl.If(inGrid, () => {
              next.assign(lifeWord(
                source.element(aboveLeft), source.element(above), source.element(aboveRight),
                source.element(left), source.element(index), source.element(right),
                source.element(belowLeft), source.element(below), source.element(belowRight),
              ));
            });
            dest.element(index).assign(next);
          });
        }
        tsl.workgroupBarrier();
      }
      for (let iteration = 0; iteration < CORE_ITERATIONS; iteration++) {
        const index = localIndex.add(tsl.uint(iteration * WORKGROUP_THREADS));
        const coreX = index.mod(tsl.uint(CORE_WORDS));
        const coreY = index.div(tsl.uint(CORE_WORDS));
        const tileIdxInTile = coreY.add(tsl.uint(BATCH_STEPS)).mul(tsl.uint(TILE_WORDS)).add(coreX).add(tsl.uint(1));
        const value = tileA.element(tileIdxInTile);
        const globalWordOut = tsl.uint(baseWord).add(coreX);
        const globalYOut = tsl.uint(baseY).add(coreY);
        const inOutputRange = globalWordOut.lessThan(tsl.uint(WORDS_PER_ROW))
          .and(globalYOut.lessThan(tsl.uint(GRID_HEIGHT)));
        tsl.If(inOutputRange, () => {
          wordsOut.element(globalYOut.mul(tsl.uint(WORDS_PER_ROW)).add(globalWordOut)).assign(value);
        });
        tsl.atomicOr(anyAliveShared.element(tsl.uint(0)), value);
      }
      tsl.workgroupBarrier();
      tsl.If(localIndex.equal(tsl.uint(0)), () => {
        const finalAlive = tsl.atomicLoad(anyAliveShared.element(tsl.uint(0)));
        tileAliveOut.element(workgroupId).assign(tsl.select(finalAlive.notEqual(tsl.uint(0)), tsl.uint(1), tsl.uint(0)));
      });
    })().compute([TOTAL_TILES], [WORKGROUP_THREADS]);
  }
  // ================================================================
  // 【今回の追加】TSL: sparseStepOne（Life本体 + 生存判定、1世代のみ）
  // 原典shader.wgslのstep_one相当。共有メモリのtile_a/tile_bやhaloは使わず、
  // 各セルを直接gridWord経由で9近傍読み込みして1世代だけ計算する。
  // ================================================================
  function makeSparseStepOneNode(wordsIn, wordsOut, activeTilesIn, tileAliveOut) {
    const anyAliveShared = tsl.workgroupArray('uint', 1).toAtomic().setName('anyAliveSharedOne');
    return tsl.Fn(() => {
      const localIndex = tsl.invocationLocalIndex;
      const workgroupId = tsl.instanceIndex.sub(localIndex).div(tsl.uint(WORKGROUP_THREADS));
      const tileIndex = activeTilesIn.element(workgroupId);
      const tileX = tileIndex.mod(tsl.uint(TILE_COLUMNS));
      const tileY = tileIndex.div(tsl.uint(TILE_COLUMNS));
      const baseWord = tsl.int(tileX.mul(tsl.uint(CORE_WORDS)));
      const baseY = tsl.int(tileY.mul(tsl.uint(CORE_ROWS)));
      tsl.If(localIndex.equal(tsl.uint(0)), () => {
        tsl.atomicStore(anyAliveShared.element(tsl.uint(0)), tsl.uint(0));
      });
      tsl.workgroupBarrier();
      for (let iteration = 0; iteration < CORE_ITERATIONS; iteration++) {
        const index = localIndex.add(tsl.uint(iteration * WORKGROUP_THREADS));
        const coreX = index.mod(tsl.uint(CORE_WORDS));
        const coreY = index.div(tsl.uint(CORE_WORDS));
        const wordX = baseWord.add(tsl.int(coreX));
        const y = baseY.add(tsl.int(coreY));
        const globalWordOut = tsl.uint(wordX);
        const globalYOut = tsl.uint(y);
        const inOutputRange = globalWordOut.lessThan(tsl.uint(WORDS_PER_ROW))
          .and(globalYOut.lessThan(tsl.uint(GRID_HEIGHT)));
        tsl.If(inOutputRange, () => {
          const next = lifeWord(
            gridWord(wordsIn, wordX.sub(tsl.int(1)), y.sub(tsl.int(1))),
            gridWord(wordsIn, wordX, y.sub(tsl.int(1))),
            gridWord(wordsIn, wordX.add(tsl.int(1)), y.sub(tsl.int(1))),
            gridWord(wordsIn, wordX.sub(tsl.int(1)), y),
            gridWord(wordsIn, wordX, y),
            gridWord(wordsIn, wordX.add(tsl.int(1)), y),
            gridWord(wordsIn, wordX.sub(tsl.int(1)), y.add(tsl.int(1))),
            gridWord(wordsIn, wordX, y.add(tsl.int(1))),
            gridWord(wordsIn, wordX.add(tsl.int(1)), y.add(tsl.int(1))),
          );
          wordsOut.element(globalYOut.mul(tsl.uint(WORDS_PER_ROW)).add(globalWordOut)).assign(next);
          tsl.atomicOr(anyAliveShared.element(tsl.uint(0)), next);
        });
      }
      tsl.workgroupBarrier();
      tsl.If(localIndex.equal(tsl.uint(0)), () => {
        const finalAlive = tsl.atomicLoad(anyAliveShared.element(tsl.uint(0)));
        tileAliveOut.element(workgroupId).assign(tsl.select(finalAlive.notEqual(tsl.uint(0)), tsl.uint(1), tsl.uint(0)));
      });
    })().compute([TOTAL_TILES], [WORKGROUP_THREADS]);
  }
  const sparseStep_1to2 = makeSparseStepNode(nodeB1, nodeB2, activeTilesNode1, tileAliveNode2);
  const sparseStep_2to1 = makeSparseStepNode(nodeB2, nodeB1, activeTilesNode2, tileAliveNode1);
  const sparseStepOne_1to2 = makeSparseStepOneNode(nodeB1, nodeB2, activeTilesNode1, tileAliveNode2);
  const sparseStepOne_2to1 = makeSparseStepOneNode(nodeB2, nodeB1, activeTilesNode2, tileAliveNode1);
  // -------------------- backend.dataへの登録フェーズ --------------------
  renderer.compute(sparseStep_1to2);
  renderer.compute(sparseStep_2to1);
  renderer.compute(sparseStepOne_1to2);
  renderer.compute(sparseStepOne_2to1);
  await renderer.getArrayBufferAsync(bufB1);
  const rawBufB1 = backend.data.get(bufB1).buffer;
  const rawBufB2 = backend.data.get(bufB2).buffer;
  const rawActiveTiles1 = backend.data.get(activeTilesAttr1).buffer;
  const rawActiveTiles2 = backend.data.get(activeTilesAttr2).buffer;
  const rawTileAlive1 = backend.data.get(tileAliveAttr1).buffer;
  const rawTileAlive2 = backend.data.get(tileAliveAttr2).buffer;
  // -------------------- 初期値: RLEからパースした時計パターンを設定 --------------------
  function uploadInitialState() {
    queue.writeBuffer(rawBufB1, 0, initialWords);
    queue.writeBuffer(rawBufB2, 0, new Uint32Array(WORD_COUNT));
    if (initialTiles.length > 0) {
      queue.writeBuffer(rawActiveTiles1, 0, initialTiles);
    }
    queue.writeBuffer(rawActiveTiles2, 0, new Uint32Array(TOTAL_TILES));
    queue.writeBuffer(rawTileAlive1, 0, new Uint32Array(TOTAL_TILES));
    queue.writeBuffer(rawTileAlive2, 0, new Uint32Array(TOTAL_TILES));
  }
  uploadInitialState();
  // -------------------- 生WGSL: mark_next_candidates + clear --------------------
  const flagsBuffer = device.createBuffer({ size: TOTAL_TILES * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  queue.writeBuffer(flagsBuffer, 0, new Uint32Array(TOTAL_TILES));
  const counterBuffer1 = device.createBuffer({ size: 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC });
  const counterBuffer2 = device.createBuffer({ size: 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC });
  queue.writeBuffer(counterBuffer1, 0, new Uint32Array([initialTiles.length]));
  queue.writeBuffer(counterBuffer2, 0, new Uint32Array([0]));
  await queue.onSubmittedWorkDone();
  const markShaderCode = `
    struct Params { tile_columns: u32, tile_rows: u32, _pad0: u32, _pad1: u32, };
    @group(0) @binding(0) var<uniform> params: Params;
    @group(0) @binding(1) var<storage, read> active_tiles_in: array<u32>;
    @group(0) @binding(2) var<storage, read> tile_alive_in: array<u32>;
    @group(0) @binding(3) var<storage, read_write> next_flags: array<atomic<u32>>;
    @group(0) @binding(4) var<storage, read_write> next_active_tiles: array<u32>;
    @group(0) @binding(5) var<storage, read_write> next_indirect: array<atomic<u32>>;
    fn mark_next_candidates(tile_index: u32) {
      let columns = params.tile_columns;
      let rows = params.tile_rows;
      let tile_x = i32(tile_index % columns);
      let tile_y = i32(tile_index / columns);
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          let x = tile_x + dx;
          let y = tile_y + dy;
          if (x >= 0 && y >= 0 && x < i32(columns) && y < i32(rows)) {
            let tile = u32(y) * columns + u32(x);
            if (atomicExchange(&next_flags[tile], 1u) == 0u) {
              let slot = atomicAdd(&next_indirect[0], 1u);
              next_active_tiles[slot] = tile;
            }
          }
        }
      }
    }
    @compute @workgroup_size(1)
    fn main(@builtin(workgroup_id) wgid: vec3<u32>) {
      let tile_index = active_tiles_in[wgid.x];
      if (tile_alive_in[wgid.x] != 0u) {
        mark_next_candidates(tile_index);
      }
    }
  `;
  const markModule = device.createShaderModule({ code: markShaderCode });
  const markPipeline = device.createComputePipeline({ layout: 'auto', compute: { module: markModule, entryPoint: 'main' } });
  const paramsBuffer = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  queue.writeBuffer(paramsBuffer, 0, new Uint32Array([TILE_COLUMNS, TILE_ROWS_COUNT, 0, 0]));
  const clearShaderCode = `
    @group(0) @binding(0) var<storage, read_write> flags: array<atomic<u32>>;
    @group(0) @binding(1) var<storage, read_write> next_counter: array<atomic<u32>>;
    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3<u32>) {
      if (id.x < ${TOTAL_TILES}u) {
        atomicStore(&flags[id.x], 0u);
      }
      if (id.x == 0u) { atomicStore(&next_counter[0], 0u); }
    }
  `;
  const clearModule = device.createShaderModule({ code: clearShaderCode });
  const clearPipeline = device.createComputePipeline({ layout: 'auto', compute: { module: clearModule, entryPoint: 'main' } });
  const clearWorkgroups = Math.ceil(TOTAL_TILES / 64);
  const rawIndirectBuffer = device.createBuffer({
    size: 12, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_DST,
  });
  queue.writeBuffer(rawIndirectBuffer, 4, new Uint32Array([1, 1]));
  // ================================================================
  // カメラ（ズーム・パン）: tsl.uniform()で動的な値をシェーダーへ渡す
  // ================================================================
  let zoomLevel = INITIAL_ZOOM_LEVEL;
  let zoomValue = zoomForLevel(zoomLevel);
  let pixelRatio = Math.max(1, window.devicePixelRatio || 1);
  function shaderZoomValue(zoom = zoomValue) {
    return zoom / pixelRatio;
  }
  const cameraZoom = tsl.uniform(shaderZoomValue());
  const cameraCenterX = tsl.uniform(GRID_WIDTH / 2);
  const cameraCenterY = tsl.uniform(GRID_HEIGHT / 2);
  // ================================================================
  // 【今回の再追加】縮小表示時のドット補完（生WGSLで実装）
  // 1ピクセルに複数セルが対応する縮小表示(zoom>=1.0)では、ピクセル中心の
  // 1セルだけを見ると細い配線やパターンが消えてしまう。
  // rangeHasLifeは、1ピクセルが覆うセル範囲(zoom*0.5の半幅)をword単位で
  // OR束ねし、範囲内にどれか1個でも生セルがあれば trueを返す。
  // 本物のWGSL for文で実行時に早期return(break)するため、原典
  // shader.wgslのrange_has_lifeと同じ制御フローになる(TSL版で必要
  // だった「264回イテレーションすべてに条件判定を付与する」という
  // 回避策は不要)。
  // 【簡略化した点】GRID_WIDTH(20000)はWORDS_PER_ROW*32にちょうど
  // 割り切れる(625*32=20000)ため、x0/x1をGRID_WIDTH内にclampすれば
  // firstWord/lastWordは必ずWORDS_PER_ROW未満になる。そのため原典に
  // あった「word列が範囲外かどうか」の追加チェックは不要と判断し、
  // 省略している。
  // ================================================================
  const rangeHasLifeWgsl = tsl.wgslFn(`
    fn rangeHasLife(wordsBuffer: ptr<storage, array<u32>, read>, worldX: f32, worldY: f32, zoomVal: f32) -> bool {
      let gridWidthMax = ${GRID_WIDTH - 1};
      let gridHeightMax = ${GRID_HEIGHT - 1};
      let wordsPerRow = ${WORDS_PER_ROW}u;
      let halfSpan = zoomVal * 0.5;
      let x0 = clamp(i32(floor(worldX - halfSpan)), 0, gridWidthMax);
      let x1 = clamp(i32(floor(worldX + halfSpan)), 0, gridWidthMax);
      let y0 = clamp(i32(floor(worldY - halfSpan)), 0, gridHeightMax);
      let y1 = clamp(i32(floor(worldY + halfSpan)), 0, gridHeightMax);
      if (x0 > x1 || y0 > y1) { return false; }
      let firstWord = u32(x0) >> 5u;
      let lastWord = u32(x1) >> 5u;
      let firstBit = u32(x0) & 31u;
      let lastBit = u32(x1) & 31u;
      var firstMask = 0xffffffffu << firstBit;
      var lastMask = 0xffffffffu;
      if (lastBit != 31u) { lastMask = (1u << (lastBit + 1u)) - 1u; }
      for (var row = u32(y0); row <= u32(y1); row = row + 1u) {
        for (var w = firstWord; w <= lastWord; w = w + 1u) {
          var mask = 0xffffffffu;
          if (w == firstWord) { mask = mask & firstMask; }
          if (w == lastWord) { mask = mask & lastMask; }
          let index = row * wordsPerRow + w;
          if ((wordsBuffer[index] & mask) != 0u) { return true; }
        }
      }
      return false;
    }
  `);
  // ================================================================
  // 描画（配色は shader.wgsl 原典の fs_main 関数と同じ値にする）
  // ================================================================
  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  const geometry = new THREE.PlaneGeometry(2, 2);
  function makeMaterial(wordsNode) {
    const material = new MeshBasicNodeMaterial();
    material.toneMapped = false;
    material.colorNode = tsl.Fn(() => {
      const uvNode = tsl.uv();
      const screenWidth = tsl.float(window.innerWidth);
      const screenHeight = tsl.float(window.innerHeight);
      const px = uvNode.x.mul(screenWidth);
      const py = tsl.float(1.0).sub(uvNode.y).mul(screenHeight);
      const worldX = cameraCenterX.add(px.sub(screenWidth.mul(0.5)).mul(cameraZoom));
      const worldY = cameraCenterY.add(py.sub(screenHeight.mul(0.5)).mul(cameraZoom));
      const zoom = cameraZoom;
      const halfZoom = zoom.mul(0.5);
      const minBorderWidth = tsl.float(0.025);
      const borderWidth = tsl.select(halfZoom.greaterThan(minBorderWidth), halfZoom, minBorderWidth);
      const negBorderWidth = borderWidth.mul(-1);
      function withinAbs(value, width) {
        return value.lessThanEqual(width).and(value.greaterThanEqual(width.mul(-1)));
      }
      const worldYFromBottom = worldY.sub(tsl.float(GRID_HEIGHT));
      const worldXFromRight = worldX.sub(tsl.float(GRID_WIDTH));
      const alongHorizontalEdge = worldX.greaterThanEqual(negBorderWidth)
        .and(worldX.lessThanEqual(tsl.float(GRID_WIDTH).add(borderWidth)))
        .and(
          withinAbs(worldY, borderWidth)
            .or(withinAbs(worldYFromBottom, borderWidth))
        );
      const alongVerticalEdge = worldY.greaterThanEqual(negBorderWidth)
        .and(worldY.lessThanEqual(tsl.float(GRID_HEIGHT).add(borderWidth)))
        .and(
          withinAbs(worldX, borderWidth)
            .or(withinAbs(worldXFromRight, borderWidth))
        );
      const onBorder = alongHorizontalEdge.or(alongVerticalEdge);
      const borderColor = tsl.vec3(0.08, 0.43, 1.00);
      const outside = worldX.lessThan(tsl.float(0.0)).or(worldY.lessThan(tsl.float(0.0)))
        .or(worldX.greaterThanEqual(tsl.float(GRID_WIDTH))).or(worldY.greaterThanEqual(tsl.float(GRID_HEIGHT)));
      const outsideColor = tsl.vec3(0.008, 0.011, 0.015);
      // 単一セル判定(zoom<1.0、拡大表示用。原典fs_mainのzoom<1.0分岐と同じ)
      const gx = tsl.int(worldX);
      const gy = tsl.int(worldY);
      const singleWordX = gx.div(tsl.int(32));
      const bit = tsl.uint(gx).mod(tsl.uint(32));
      const singleWord = gridWord(wordsNode, singleWordX, gy);
      const singleCellAlive = tsl.bitAnd(singleWord.shiftRight(bit), tsl.uint(1)).equal(tsl.uint(1));
      // 【今回の再追加】縮小表示用のドット補完(zoom>=1.0、生WGSL版rangeHasLife)。
      // tsl.If()/tsl.Else()は使わず、ファイル内で実績のあるselect()で
      // 分岐する(TSLの制御フロー起因のバグを避けるため)。
      const rangeAlive = rangeHasLifeWgsl({ wordsBuffer: wordsNode, worldX: worldX, worldY: worldY, zoomVal: zoom });
      const alive = tsl.select(zoom.greaterThanEqual(tsl.float(1.0)), rangeAlive, singleCellAlive);
      const liveColor = tsl.vec3(0.78, 0.81, 0.84);
      const backgroundColor = tsl.vec3(0.012, 0.020, 0.027);
      const insideColor = tsl.select(alive, liveColor, backgroundColor);
      return tsl.select(onBorder, borderColor, tsl.select(outside, outsideColor, insideColor));
    })();
    return material;
  }
  const materialA = makeMaterial(nodeB1);
  const materialB = makeMaterial(nodeB2);
  const mesh = new THREE.Mesh(geometry, materialA);
  scene.add(mesh);
  // ================================================================
  // 1ステップ実行（ハイブリッドindirect dispatch）
  // レンダリングは行わない(原典advanceLifeと同じく計算のみ)。
  // useSingleStep=trueならsparseStepOne(1世代)、falseならsparseStep(8世代)を使う。
  // ================================================================
  let usingB1 = true;
  async function runOneStep(useSingleStep = false) {
    const stepNode = useSingleStep
      ? (usingB1 ? sparseStepOne_1to2 : sparseStepOne_2to1)
      : (usingB1 ? sparseStep_1to2 : sparseStep_2to1);
    const curActiveTilesBuf = usingB1 ? rawActiveTiles1 : rawActiveTiles2;
    const nextActiveTilesBuf = usingB1 ? rawActiveTiles2 : rawActiveTiles1;
    const curWordsBuf = usingB1 ? rawBufB1 : rawBufB2;
    const nextWordsBuf = usingB1 ? rawBufB2 : rawBufB1;
    const curTileAliveOutBuf = usingB1 ? rawTileAlive2 : rawTileAlive1;
    const curCounterBuf = usingB1 ? counterBuffer1 : counterBuffer2;
    const nextCounterBuf = usingB1 ? counterBuffer2 : counterBuffer1;
    {
      const clearBindGroup = device.createBindGroup({
        layout: clearPipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: { buffer: flagsBuffer } },
          { binding: 1, resource: { buffer: nextCounterBuf } },
        ],
      });
      const enc = device.createCommandEncoder();
      const pass = enc.beginComputePass();
      pass.setPipeline(clearPipeline);
      pass.setBindGroup(0, clearBindGroup);
      pass.dispatchWorkgroups(clearWorkgroups);
      pass.end();
      queue.submit([enc.finish()]);
    }
    {
      const enc = device.createCommandEncoder();
      enc.copyBufferToBuffer(curCounterBuf, 0, rawIndirectBuffer, 0, 4);
      queue.submit([enc.finish()]);
    }
    const nodeData = backend.data.get(stepNode);
    const pipeline = nodeData.currentPipeline;
    const entries = [
      { binding: 0, resource: { buffer: curActiveTilesBuf } },
      { binding: 1, resource: { buffer: curWordsBuf } },
      { binding: 2, resource: { buffer: nextWordsBuf } },
      { binding: 3, resource: { buffer: curTileAliveOutBuf } },
    ];
    const bindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries });
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroupsIndirect(rawIndirectBuffer, 0);
    pass.end();
    queue.submit([encoder.finish()]);
    const markBindGroup = device.createBindGroup({
      layout: markPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: paramsBuffer } },
        { binding: 1, resource: { buffer: curActiveTilesBuf } },
        { binding: 2, resource: { buffer: curTileAliveOutBuf } },
        { binding: 3, resource: { buffer: flagsBuffer } },
        { binding: 4, resource: { buffer: nextActiveTilesBuf } },
        { binding: 5, resource: { buffer: nextCounterBuf } },
      ],
    });
    const markEncoder = device.createCommandEncoder();
    const markPass = markEncoder.beginComputePass();
    markPass.setPipeline(markPipeline);
    markPass.setBindGroup(0, markBindGroup);
    markPass.dispatchWorkgroupsIndirect(rawIndirectBuffer, 0);
    markPass.end();
    queue.submit([markEncoder.finish()]);
    usingB1 = !usingB1;
  }
  // 【今回の修正】原典advanceLifeと同じく「8世代バッチ + 端数は1世代ずつ」で
  // 正確にgenerations世代だけ進める。以前はBATCH_STEPS(8)の倍数にしか
  // 進められなかったが、sparseStepOneの追加によりその丸めが不要になった。
  async function advanceLife(generations, waitForCompletion = false) {
    let remaining = generations;
    while (remaining > 0) {
      const useSingleStep = remaining < BATCH_STEPS;
      await runOneStep(useSingleStep);
      remaining -= useSingleStep ? 1 : BATCH_STEPS;
    }
    if (waitForCompletion) await queue.onSubmittedWorkDone();
    return generations;
  }
  async function readCounterValue(buf) {
    const staging = device.createBuffer({ size: 4, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    const enc = device.createCommandEncoder();
    enc.copyBufferToBuffer(buf, 0, staging, 0, 4);
    queue.submit([enc.finish()]);
    await staging.mapAsync(GPUMapMode.READ);
    const value = new Uint32Array(staging.getMappedRange().slice(0))[0];
    staging.unmap();
    staging.destroy();
    return value;
  }
  // ================================================================
  // ローカル時刻への同期（原典synchronizeClockを移植）
  // ================================================================
  async function synchronizeClock() {
    let lastReport = 0;
    for (;;) {
      const wallSeconds = Math.floor((Date.now() - syncOriginWallMs) / 1000);
      const target = syncOriginGeneration
        + wallSeconds * CLOCK_GENERATIONS_PER_SECOND
        + CLOCK_DISPLAY_LAG_GENERATIONS;
      const remaining = target - generation;
      if (remaining <= 0) break;
      const batch = Math.min(SYNC_STEPS_PER_BATCH, remaining);
      const advanced = await advanceLife(batch, true);
      generation += advanced;
      const now = performance.now();
      if (now - lastReport >= 100 || remaining <= batch) {
        lastReport = now;
        const complete = generation - syncOriginGeneration;
        const total = Math.max(1, target - syncOriginGeneration);
        setLoading(
          'ローカル時刻へ同期しています',
          `${formatInteger(complete)} / ${formatInteger(total)} generations (${(100 * complete / total).toFixed(1)}%)`,
        );
        await new Promise(requestAnimationFrame);
      }
    }
  }
  if (syncToLocalTime) await synchronizeClock();
  // ================================================================
  // 状態管理（画面表示・カメラ操作・ボタン類）
  // ================================================================
  let cssWidth = window.innerWidth;
  let cssHeight = window.innerHeight;
  let paused = false;
  let singleStep = 0;
  let accumulator = 0;
  let nextClockCorrectionMs = syncToLocalTime ? Date.now() + CLOCK_CORRECTION_MS : null;
  let running = true;
  function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    pixelRatio = Math.max(1, window.devicePixelRatio || 1);
    cssWidth = Math.max(1, rect.width);
    cssHeight = Math.max(1, rect.height);
    renderer.setPixelRatio(pixelRatio);
    renderer.setSize(cssWidth, cssHeight);
    cameraZoom.value = shaderZoomValue();
  }
  new ResizeObserver(resizeCanvas).observe(canvas);
  window.addEventListener('resize', resizeCanvas);
  resizeCanvas();
  function fullViewZoomLevel() {
    const requiredZoom = 1.04 * Math.max(GRID_WIDTH / cssWidth, GRID_HEIGHT / cssHeight);
    for (let level = MIN_ZOOM_LEVEL; level <= MAX_ZOOM_LEVEL; level++) {
      if (zoomForLevel(level) >= requiredZoom) return level;
    }
    return MAX_ZOOM_LEVEL;
  }
  function fullView() {
    zoomLevel = fullViewZoomLevel();
    zoomValue = zoomForLevel(zoomLevel);
    cameraZoom.value = shaderZoomValue();
    cameraCenterX.value = GRID_WIDTH / 2;
    cameraCenterY.value = GRID_HEIGHT / 2;
  }
  async function resetGrid() {
    uploadInitialState();
    queue.writeBuffer(counterBuffer1, 0, new Uint32Array([initialTiles.length]));
    queue.writeBuffer(counterBuffer2, 0, new Uint32Array([0]));
    await queue.onSubmittedWorkDone();
    usingB1 = true;
    generation = initialGeneration;
    accumulator = 0;
    singleStep = 0;
    paused = true;
    pauseButton.textContent = 'Run';
    resetStats();
    setMessage(`${sourceName} の初期状態へ戻しました。`);
  }
  function changeSpeed(direction) {
    if (direction > 0) {
      speed = SPEED_LEVELS.find((value) => value > speed) ?? SPEED_LEVELS.at(-1);
    } else {
      speed = SPEED_LEVELS.findLast((value) => value < speed) ?? SPEED_LEVELS[0];
    }
    setMessage(`target ${speed} gen/s`);
  }
  function togglePause() {
    paused = !paused;
    pauseButton.textContent = paused ? 'Run' : 'Pause';
  }
  let dragging = false;
  let lastMouseX = 0;
  let lastMouseY = 0;
  canvas.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    dragging = true;
    canvas.classList.add('dragging');
    canvas.setPointerCapture(event.pointerId);
    lastMouseX = event.clientX;
    lastMouseY = event.clientY;
  });
  canvas.addEventListener('pointerup', (event) => {
    dragging = false;
    canvas.classList.remove('dragging');
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
  });
  canvas.addEventListener('pointercancel', () => {
    dragging = false;
    canvas.classList.remove('dragging');
  });
  canvas.addEventListener('pointermove', (event) => {
    if (!dragging) return;
    const dx = event.clientX - lastMouseX;
    const dy = event.clientY - lastMouseY;
    lastMouseX = event.clientX;
    lastMouseY = event.clientY;
    const renderZoom = shaderZoomValue();
    cameraCenterX.value -= dx * renderZoom;
    cameraCenterY.value -= dy * renderZoom;
  });
  canvas.addEventListener('wheel', (event) => {
    event.preventDefault();
    if (event.deltaY === 0) return;
    const rect = canvas.getBoundingClientRect();
    const mouseX = event.clientX - rect.left;
    const mouseY = event.clientY - rect.top;
    const currentShaderZoom = shaderZoomValue();
    const worldXBefore = cameraCenterX.value + (mouseX - cssWidth / 2) * currentShaderZoom;
    const worldYBefore = cameraCenterY.value + (mouseY - cssHeight / 2) * currentShaderZoom;
    const direction = event.deltaY < 0 ? -1 : 1;
    zoomLevel = Math.max(MIN_ZOOM_LEVEL, Math.min(MAX_ZOOM_LEVEL, zoomLevel + direction));
    zoomValue = zoomForLevel(zoomLevel);
    const newShaderZoom = shaderZoomValue();
    cameraZoom.value = newShaderZoom;
    cameraCenterX.value = worldXBefore - (mouseX - cssWidth / 2) * newShaderZoom;
    cameraCenterY.value = worldYBefore - (mouseY - cssHeight / 2) * newShaderZoom;
  }, { passive: false });
  window.addEventListener('keydown', (event) => {
    if (event.repeat) return;
    if (['Space', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.code)) event.preventDefault();
    switch (event.code) {
      case 'Escape':
        running = false;
        paused = true;
        setMessage('停止しました。再開するにはページを再読み込みしてください。');
        break;
      case 'Space': togglePause(); break;
      case 'ArrowRight': paused = true; pauseButton.textContent = 'Run'; singleStep += 1; break;
      case 'ArrowUp': changeSpeed(1); break;
      case 'ArrowDown': changeSpeed(-1); break;
      case 'KeyF': fullView(); break;
      case 'KeyR': void resetGrid(); break;
      default: break;
    }
  });
  pauseButton.addEventListener('click', togglePause);
  stepButton.addEventListener('click', () => { paused = true; pauseButton.textContent = 'Run'; singleStep += 1; });
  fullButton.addEventListener('click', fullView);
  resetButton.addEventListener('click', () => void resetGrid());
  // ================================================================
  // メインループ（原典test_chrome.jsのframe関数・HUDフォーマットに準拠）
  // ================================================================
  let lastCandidateCount = initialTiles.length;
  let lastFrameTime = performance.now();
  let statsStart = performance.now();
  let statsGeneration = generation;
  let statsFrameCount = 0;
  let measuredSpeed = 0;
  let measuredFps = 0;
  let lastHudTime = 0;
  function resetStats(now = performance.now()) {
    statsStart = now;
    statsGeneration = generation;
    statsFrameCount = 0;
    measuredSpeed = 0;
    measuredFps = 0;
  }
  function updateHud(now) {
    if (now - lastHudTime < 250) return;
    lastHudTime = now;
    // 修正箇所/注記: 原典は speed===192(CLOCK_GENERATIONS_PER_SECOND)の
    // 時だけ"*192*"という特別な表示にする。その仕様をそのまま踏襲する。
    const target = speed === CLOCK_GENERATIONS_PER_SECOND ? '*192*' : speed.toFixed(1);
    const mode = 'SPARSE';
    const runState = paused ? 'PAUSE' : 'RUN';
    const title = `Life 20000\u00B2 | ${mode} | gen ${formatInteger(generation)} | ${runState} | ` +
      `target ${target} gen/s | actual ${measuredSpeed.toFixed(1)} gen/s | ${measuredFps.toFixed(1)} fps | ` +
      `zoom ${zoomValue.toFixed(1)} cell/px`;
    document.title = title;
    statsElement.textContent = title;
    if (uncapturedErrors.length) {
      messageElement.textContent = `[警告] ${uncapturedErrors[uncapturedErrors.length - 1]}`;
    }
  }
  async function frame(now) {
    if (!running) return;
    try {
      const rawDelta = (now - lastFrameTime) / 1000;
      const delta = Math.min(0.25, Math.max(0, rawDelta));
      lastFrameTime = now;
      if (!paused) accumulator += delta * speed;
      // 修正箇所/注記: 原典のframe関数内、定期的な時刻補正ロジックを
      // そのまま踏襲する。speedがCLOCK_GENERATIONS_PER_SECOND(192)の
      // ときだけ、CLOCK_CORRECTION_MSごとにローカル時刻とのズレを補正する。
      if (nextClockCorrectionMs !== null
          && speed === CLOCK_GENERATIONS_PER_SECOND
          && Date.now() >= nextClockCorrectionMs) {
        const target = localGenerationAt(new Date());
        const difference = clockGenerationDifference(target, generation);
        accumulator = difference;
        nextClockCorrectionMs = Date.now() + CLOCK_CORRECTION_MS;
        const direction = difference < 0 ? 'ahead' : 'behind/on time';
        setMessage(`Clock correction: ${direction} by ${formatInteger(Math.abs(difference))} generations.`);
      }
      const automatic = paused ? 0 : Math.max(0, Math.floor(accumulator));
      const wanted = automatic + singleStep;
      const steps = Math.min(MAX_STEPS_PER_FRAME, wanted);
      if (steps > 0) {
        // 【今回の修正】sparseStepOneの追加により、BATCH_STEPSの倍数へ
        // 丸めずにsteps世代をそのまま正確に進められるようになった。
        await advanceLife(steps, false);
        const automaticUsed = Math.min(automatic, steps);
        const singleUsed = Math.min(singleStep, steps - automaticUsed);
        accumulator -= automaticUsed;
        singleStep -= singleUsed;
        generation += steps;
        statsFrameCount++;
        mesh.material = usingB1 ? materialA : materialB;
      }
      renderer.render(scene, camera);
      const statsElapsed = (now - statsStart) / 1000;
      if (statsElapsed >= 1.0) {
        measuredSpeed = (generation - statsGeneration) / statsElapsed;
        measuredFps = statsFrameCount / statsElapsed;
        statsStart = now;
        statsGeneration = generation;
        statsFrameCount = 0;
        const counterBuf = usingB1 ? counterBuffer1 : counterBuffer2;
        lastCandidateCount = await readCounterValue(counterBuf);
      }
      updateHud(now);
      requestAnimationFrame((t) => frame(t).catch(showError));
    } catch (err) {
      running = false;
      showError(err);
    }
  }
  loading.hidden = true;
  canvas.classList.remove('waiting');
  hud.hidden = false;
  controls.hidden = false;
  resetStats();
  lastFrameTime = performance.now();
  setMessage(syncToLocalTime
    ? `Local-time synchronization complete at generation ${formatInteger(generation)}.`
    : `${sourceName} を同期なしで読み込みました。`);
  requestAnimationFrame((t) => frame(t).catch(showError));
  window.addEventListener('resize', () => {
    renderer.setSize(window.innerWidth, window.innerHeight);
  });
}
main().catch(showError);
