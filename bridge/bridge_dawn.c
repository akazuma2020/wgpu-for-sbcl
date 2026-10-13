/*
 * Common Lisp向けWebGPUネイティブブリッジ。
 *
 * Dawn / wgpu-nativeのAPIを小さなC ABIとして公開し、環境初期化、資源生成、
 * Compute/Render命令列のencode、submit、present、readbackを担当する。
 * ウィンドウ生成、イベント処理、アプリ固有の意味はLisp側に置く。
 *
 * 公開構造体と数値タグはwgpu.lispのCFFI定義と一致させる。ここで生成した
 * 所有対象は、個別関数が消費すると明記しない限りWGPU_Releaseで解放する。
 */

#include <dawn/webgpu.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Lisp/CFFIから呼ぶ関数をWindows DLLのexport tableへ公開する。 */
#if defined(_WIN32) && !defined(WGPU_BRIDGE_STATIC)
#define BRIDGE_API __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define BRIDGE_API __attribute__((visibility("default")))
#else
#define BRIDGE_API
#endif
/* -------------------- command batch -------------------- */
typedef enum {
    WGPU_BRIDGE_COMPUTE_CLEAR_BUFFER = 1,
    WGPU_BRIDGE_COMPUTE_BEGIN_PASS = 2,
    WGPU_BRIDGE_COMPUTE_SET_PIPELINE = 3,
    WGPU_BRIDGE_COMPUTE_SET_BIND_GROUP = 4,
    WGPU_BRIDGE_COMPUTE_DISPATCH = 5,
    WGPU_BRIDGE_COMPUTE_DISPATCH_INDIRECT = 6,
    WGPU_BRIDGE_COMPUTE_END_PASS = 7,
    WGPU_BRIDGE_COMPUTE_COPY_BUFFER = 8
} WGPUBridgeComputeOpcode;
/*
 * object   : 命令の主対象（buffer / pipeline / bind group）
 * argument : COPY_BUFFER のコピー先
 * offset   : object 側のバイト位置、destination_offset : argument 側のバイト位置
 */
typedef struct {
    uint32_t opcode;
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint64_t offset;
    uint64_t size;
    void *object;
    void *argument;
    uint64_t destination_offset;
} WGPUBridgeComputeCommand;
/* -------------------- bind group -------------------- */
#define WGPU_BRIDGE_MAX_BIND_ENTRIES 16u

typedef struct {
    uint32_t binding;
    uint32_t kind;
    uint64_t offset;
    uint64_t size;
    void *resource;
} WGPUBridgeBindGroupEntry;
/*
 * 頂点属性を複数まとめて渡すための構造体。
 * reserved / reserved2 は、WGPUBridgeBindGroupEntry の offset と同じ
 * 考え方で、64bit の offset を8バイト境界に置くための明示的な空き。
 * Lisp側の vertex-attribute defcstruct と並びを一致させること。
 */
typedef struct {
    uint32_t format;
    uint32_t reserved;
    uint64_t offset;
    uint32_t shader_location;
    uint32_t reserved2;
} WGPUBridgeVertexAttribute;

typedef struct {
    void *source;
    uint32_t source_mip_level;
    uint32_t source_x;
    uint32_t source_y;
    uint32_t source_z;
    void *destination;
    uint32_t destination_mip_level;
    uint32_t destination_x;
    uint32_t destination_y;
    uint32_t destination_z;
    uint32_t width;
    uint32_t height;
    uint32_t depth_or_array_layers;
} WGPUBridgeTextureCopy;

typedef struct {
    void *source;
    uint32_t source_mip_level;
    uint32_t source_x;
    uint32_t source_y;
    uint32_t source_z;
    void *destination_buffer;
    uint64_t destination_offset;
    uint32_t destination_bytes_per_row;
    uint32_t destination_rows_per_image;
    uint32_t width;
    uint32_t height;
    uint32_t depth_or_array_layers;
} WGPUBridgeTextureToBufferCopy;
/* -------------------- 種類タグ -------------------- */
typedef enum {
    WGPU_BRIDGE_USAGE_UNIFORM = 0,
    WGPU_BRIDGE_USAGE_STORAGE = 1,
    WGPU_BRIDGE_USAGE_COPY_DST = 2,
    WGPU_BRIDGE_USAGE_COPY_SRC = 3,
    WGPU_BRIDGE_USAGE_INDIRECT = 4,
    WGPU_BRIDGE_USAGE_MAP_READ = 5,
    WGPU_BRIDGE_USAGE_VERTEX = 6,
    WGPU_BRIDGE_USAGE_INDEX = 7
} WGPUBridgeBufferUsageKind;
typedef enum {
    WGPU_BRIDGE_OBJECT_BUFFER = 1,
    WGPU_BRIDGE_OBJECT_BIND_GROUP = 2,
    WGPU_BRIDGE_OBJECT_BIND_GROUP_LAYOUT = 3,
    WGPU_BRIDGE_OBJECT_COMPUTE_PIPELINE = 4,
    WGPU_BRIDGE_OBJECT_RENDER_PIPELINE = 5,
    WGPU_BRIDGE_OBJECT_SHADER_MODULE = 6,
    WGPU_BRIDGE_OBJECT_QUEUE = 7,
    WGPU_BRIDGE_OBJECT_DEVICE = 8,
    WGPU_BRIDGE_OBJECT_ADAPTER = 9,
    WGPU_BRIDGE_OBJECT_SURFACE = 10,
    WGPU_BRIDGE_OBJECT_INSTANCE = 11,
    
    WGPU_BRIDGE_OBJECT_TEXTURE = 12,
    WGPU_BRIDGE_OBJECT_TEXTURE_VIEW = 13,
    
    WGPU_BRIDGE_OBJECT_SAMPLER = 14,
    WGPU_BRIDGE_OBJECT_ENCODER = 15
} WGPUBridgeObjectKind;
/*
 * バックエンド種別。Lisp からは番号で指定し、実際の bit 値はここで引く。
 * usage flag と同じ方針で、wgpu-native の版が変わってもずれない。
 */
typedef enum {
    WGPU_BRIDGE_BACKEND_ALL = 0,
    WGPU_BRIDGE_BACKEND_VULKAN = 1,
    WGPU_BRIDGE_BACKEND_D3D12 = 2,
    WGPU_BRIDGE_BACKEND_METAL = 3,
    WGPU_BRIDGE_BACKEND_GL = 4
} WGPUBridgeBackendKind;
/*
 * 種類ごとに専用のenumを用意し、対応する変換関数もそれぞれ別に用意する。
 */
typedef enum {
    WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32 = 1,
    WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X2 = 2,
    WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X3 = 3,
    WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X4 = 4,
    WGPU_BRIDGE_VERTEX_FORMAT_UINT32 = 5
} WGPUBridgeVertexFormatKind;
typedef enum {
    WGPU_BRIDGE_STEP_MODE_VERTEX = 1,
    WGPU_BRIDGE_STEP_MODE_INSTANCE = 2
} WGPUBridgeVertexStepModeKind;
typedef enum {
    WGPU_BRIDGE_CULL_MODE_NONE = 1,
    WGPU_BRIDGE_CULL_MODE_FRONT = 2,
    WGPU_BRIDGE_CULL_MODE_BACK = 3
} WGPUBridgeCullModeKind;
typedef enum {
    WGPU_BRIDGE_INDEX_FORMAT_UINT16 = 1,
    WGPU_BRIDGE_INDEX_FORMAT_UINT32 = 2
} WGPUBridgeIndexFormatKind;
typedef enum {
    WGPU_BRIDGE_TOPOLOGY_TRIANGLE_LIST = 1,
    WGPU_BRIDGE_TOPOLOGY_TRIANGLE_STRIP = 2,
    WGPU_BRIDGE_TOPOLOGY_LINE_LIST = 3,
    WGPU_BRIDGE_TOPOLOGY_LINE_STRIP = 4,
    WGPU_BRIDGE_TOPOLOGY_POINT_LIST = 5
} WGPUBridgeTopologyKind;

typedef enum {
    WGPU_BRIDGE_TEXTURE_USAGE_TEXTURE_BINDING = 0,
    WGPU_BRIDGE_TEXTURE_USAGE_RENDER_ATTACHMENT = 1,
    WGPU_BRIDGE_TEXTURE_USAGE_COPY_DST = 2,
    WGPU_BRIDGE_TEXTURE_USAGE_COPY_SRC = 3,
    WGPU_BRIDGE_TEXTURE_USAGE_STORAGE_BINDING = 4
} WGPUBridgeTextureUsageKind;

typedef enum {
    WGPU_BRIDGE_TEXTURE_FORMAT_BGRA8_UNORM = 0,
    WGPU_BRIDGE_TEXTURE_FORMAT_RGBA8_UNORM = 1,
    WGPU_BRIDGE_TEXTURE_FORMAT_RGBA8_UNORM_SRGB = 2,
    WGPU_BRIDGE_TEXTURE_FORMAT_RGBA32_FLOAT = 3,
    WGPU_BRIDGE_TEXTURE_FORMAT_R8_UNORM = 4,
    WGPU_BRIDGE_TEXTURE_FORMAT_DEPTH24_PLUS = 5
} WGPUBridgeTextureFormatKind;

typedef enum {
    WGPU_BRIDGE_VIEW_DIMENSION_2D = 0,
    WGPU_BRIDGE_VIEW_DIMENSION_2D_ARRAY = 1,
    WGPU_BRIDGE_VIEW_DIMENSION_CUBE = 2,
    WGPU_BRIDGE_VIEW_DIMENSION_CUBE_ARRAY = 3
} WGPUBridgeViewDimensionKind;

typedef enum {
    WGPU_BRIDGE_FILTER_NEAREST = 0,
    WGPU_BRIDGE_FILTER_LINEAR = 1
} WGPUBridgeFilterModeKind;

typedef enum {
    WGPU_BRIDGE_ADDRESS_CLAMP_TO_EDGE = 0,
    WGPU_BRIDGE_ADDRESS_REPEAT = 1,
    WGPU_BRIDGE_ADDRESS_MIRROR_REPEAT = 2
} WGPUBridgeAddressModeKind;

typedef enum {
    WGPU_BRIDGE_LOAD_OP_CLEAR = 0,
    WGPU_BRIDGE_LOAD_OP_LOAD = 1
} WGPUBridgeLoadOpKind;

typedef enum {
    WGPU_BRIDGE_BIND_ENTRY_BUFFER = 0,
    WGPU_BRIDGE_BIND_ENTRY_SAMPLER = 1,
    WGPU_BRIDGE_BIND_ENTRY_TEXTURE_VIEW = 2
} WGPUBridgeBindEntryKind;
/* -------------------- 非同期要求の待ち合わせ -------------------- */

#if defined(_WIN32)
#include <windows.h>
/* WindowsではLONG型をInterlocked系関数でそのまま同期フラグとして使う。 */
typedef volatile LONG BridgeAtomicBool;
static bool atomic_load_flag(BridgeAtomicBool *value)
{
    /* 値を変えずに現在値だけを読み出す。0と比較して置き換える形で読む。 */
    return InterlockedCompareExchange(value, 0, 0) != 0;
}
static void atomic_store_flag(BridgeAtomicBool *value, bool state)
{
    InterlockedExchange(value, state ? 1 : 0);
}

static void bridge_sleep_one_ms(void)
{
    Sleep(1);
}
#else
#include <stdatomic.h>
#include <time.h>
/* Linux等はC11標準のatomic_boolをそのまま同期フラグとして使う。 */
typedef atomic_bool BridgeAtomicBool;
static bool atomic_load_flag(BridgeAtomicBool *value)
{
    return atomic_load(value);
}
static void atomic_store_flag(BridgeAtomicBool *value, bool state)
{
    atomic_store(value, state);
}

static void bridge_sleep_one_ms(void)
{
    struct timespec duration = { .tv_sec = 0, .tv_nsec = 1000000L };
    nanosleep(&duration, NULL);
}
#endif
typedef struct { WGPUAdapter adapter; BridgeAtomicBool done; } AdapterRequest;
typedef struct { WGPUDevice device; BridgeAtomicBool done; } DeviceRequest;
static WGPUStringView sv(const char *text)
{
    /* WebGPUの文字列は、先頭アドレスだけでなく長さも一緒に渡す。 */
    WGPUStringView result = { .data = text, .length = strlen(text) };
    return result;
}
static void adapter_callback(WGPURequestAdapterStatus status, WGPUAdapter adapter,
                             WGPUStringView message, void *userdata1, void *userdata2)
{
    /* GPU探しが終わったときwgpu-nativeから呼ばれる。doneを最後にtrueにする。 */
    AdapterRequest *request = userdata1;
    (void)message; (void)userdata2;
    if (status == WGPURequestAdapterStatus_Success) request->adapter = adapter;
    atomic_store_flag(&request->done, true);
}
static void device_callback(WGPURequestDeviceStatus status, WGPUDevice device,
                            WGPUStringView message, void *userdata1, void *userdata2)
{
    /* Device作成完了の通知。atomic変数なので別スレッドから安全に読み書きできる。 */
    DeviceRequest *request = userdata1;
    (void)userdata2;
    if (status == WGPURequestDeviceStatus_Success) {
        request->device = device;
    } else {
        /* Dawn migration: show the actual device request failure. */
        fprintf(stderr, "[dawn] RequestDevice status=%d: %.*s\n",
                (int)status,
                message.data ? (int)message.length : 0,
                message.data ? message.data : "");
    }
    atomic_store_flag(&request->done, true);
}

static void uncaptured_error_callback(WGPUDevice const *device, WGPUErrorType type,
                                      WGPUStringView message,
                                      void *userdata1, void *userdata2)
{
    (void)device; (void)userdata1; (void)userdata2;
    fprintf(stderr, "[wgpu] Uncaptured device error type=%d: %.*s\n",
            (int)type,
            message.data ? (int)message.length : 0,
            message.data ? message.data : "");
    fflush(stderr);
}
/* -------------------- 1. 環境の用意 -------------------- */
BRIDGE_API uint32_t WGPU_BackendFlag(uint32_t kind)
{
    /* Dawn migration: retain the Lisp-facing backend kind numbers. */
    switch ((WGPUBridgeBackendKind)kind) {
    case WGPU_BRIDGE_BACKEND_VULKAN: return WGPUBackendType_Vulkan;
    case WGPU_BRIDGE_BACKEND_D3D12:  return WGPUBackendType_D3D12;
    case WGPU_BRIDGE_BACKEND_METAL:  return WGPUBackendType_Metal;
    case WGPU_BRIDGE_BACKEND_GL:     return WGPUBackendType_OpenGL;
    default:                         return WGPUBackendType_D3D12;
    }
}
BRIDGE_API WGPUInstance WGPU_CreateInstance(int allow_noncompliant, uint32_t backends)
{
    /* Dawn migration: WGPUInstanceExtras is specific to wgpu-native. */
    (void)allow_noncompliant;
    (void)backends;
    WGPUInstanceDescriptor descriptor = WGPU_INSTANCE_DESCRIPTOR_INIT;
    return wgpuCreateInstance(&descriptor);
}

BRIDGE_API WGPUSurface WGPU_InitSurfaceWin32(WGPUInstance instance,
                                             void *hinstance, void *hwnd)
{
    /*
     * Windows用。HINSTANCEはGetModuleHandle(NULL)等で取得したプロセスの
     * インスタンスハンドル、HWNDはウィンドウハンドル。どちらも呼び出し側が
     * 保持しているものをそのまま渡せばよい。
     */
    if (!instance || !hwnd) return NULL;
    WGPUSurfaceSourceWindowsHWND source = {
        .chain = { .sType = WGPUSType_SurfaceSourceWindowsHWND },
        .hinstance = hinstance,
        .hwnd = hwnd
    };
    WGPUSurfaceDescriptor descriptor = { .nextInChain = &source.chain };
    return wgpuInstanceCreateSurface(instance, &descriptor);
}
BRIDGE_API WGPUSurface WGPU_InitSurfaceX11(WGPUInstance instance,
                                           void *display, uint64_t window)
{
    /*
     * X11用。displayはXOpenDisplay等で得たDisplay*、windowはXlibの
     * Window型（実体は符号なし整数のID）。
     */
    if (!instance || !display) return NULL;
    WGPUSurfaceSourceXlibWindow source = {
        .chain = { .sType = WGPUSType_SurfaceSourceXlibWindow },
        .display = display,
        .window = window
    };
    WGPUSurfaceDescriptor descriptor = { .nextInChain = &source.chain };
    return wgpuInstanceCreateSurface(instance, &descriptor);
}
BRIDGE_API WGPUSurface WGPU_InitSurfaceWayland(WGPUInstance instance,
                                               void *display, void *surface)
{
    /* Wayland用。displayはwl_display*、surfaceはwl_surface*。 */
    if (!instance || !display || !surface) return NULL;
    WGPUSurfaceSourceWaylandSurface source = {
        .chain = { .sType = WGPUSType_SurfaceSourceWaylandSurface },
        .display = display,
        .surface = surface
    };
    WGPUSurfaceDescriptor descriptor = { .nextInChain = &source.chain };
    return wgpuInstanceCreateSurface(instance, &descriptor);
}
BRIDGE_API WGPUAdapter WGPU_RequestAdapter(WGPUInstance instance, WGPUSurface surface,
                                           int reject_cpu, uint32_t backend)
{
    /*
     * surface に NULL を渡せば、ウィンドウなしの compute 専用でも使える。
     * 戻った adapter は呼び出し側が保持し、最後に WGPU_Release で返す。
     * BACKEND は WGPUBridgeBackendKind の番号。+backend-all+（0）が
     * 渡されたときは、既存アプリの動作を変えないよう D3D12 を既定にする。
     */
    if (!instance) return NULL;
    AdapterRequest request = {0};
    WGPURequestAdapterOptions options = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    options.compatibleSurface = surface;
    options.powerPreference = WGPUPowerPreference_HighPerformance;
    options.backendType = (backend == WGPU_BRIDGE_BACKEND_ALL)
        ? WGPUBackendType_D3D12
        : (WGPUBackendType)WGPU_BackendFlag(backend);
    WGPURequestAdapterCallbackInfo info = {
        .callback = adapter_callback, .userdata1 = &request,
        .mode = WGPUCallbackMode_AllowSpontaneous
    };
    wgpuInstanceRequestAdapter(instance, &options, info);
    
    while (!atomic_load_flag(&request.done)) {
        wgpuInstanceProcessEvents(instance);
        bridge_sleep_one_ms();
    }
    if (!request.adapter) return NULL;
    /* 選ばれたGPU名をログへ出し、CPUだけで動く遅いsoftware adapterは拒否する。 */
    WGPUAdapterInfo adapter_info = {0};
    if (wgpuAdapterGetInfo(request.adapter, &adapter_info) == WGPUStatus_Success) {
        const char *kind = adapter_info.adapterType == WGPUAdapterType_CPU ? "CPU" :
            adapter_info.adapterType == WGPUAdapterType_IntegratedGPU ? "IntegratedGPU" :
            adapter_info.adapterType == WGPUAdapterType_DiscreteGPU ? "DiscreteGPU" : "Unknown";
        /* backendType: 1=Null 2=WebGPU 3=D3D11 4=D3D12 5=Metal 6=Vulkan 7=OpenGL */
        fprintf(stderr, "[wgpu] adapter=%.*s backend=%d type=%s\n",
                (int)adapter_info.device.length, adapter_info.device.data,
                adapter_info.backendType, kind);
        bool software = adapter_info.adapterType == WGPUAdapterType_CPU;
        wgpuAdapterInfoFreeMembers(adapter_info);
        if (reject_cpu && software) {
            fprintf(stderr, "[wgpu] CPU adapter refused; hardware GPU is required.\n");
            wgpuAdapterRelease(request.adapter);
            return NULL;
        }
    }
    return request.adapter;
}
BRIDGE_API WGPUDevice WGPU_RequestDevice(WGPUInstance instance, WGPUAdapter adapter,
                                         uint32_t require_float32_filterable)
{
    
    if (!instance || !adapter) return NULL;
    DeviceRequest request = {0};
    WGPUDeviceDescriptor descriptor = {0};
    
    descriptor.uncapturedErrorCallbackInfo.callback = uncaptured_error_callback;
    WGPUFeatureName features[1];
    uint32_t feature_count = 0;
    if (require_float32_filterable) {
        features[feature_count++] = WGPUFeatureName_Float32Filterable;
    }
    descriptor.requiredFeatureCount = feature_count;
    descriptor.requiredFeatures = feature_count ? features : NULL;
    WGPURequestDeviceCallbackInfo info = {
        .callback = device_callback, .userdata1 = &request,
        .mode = WGPUCallbackMode_AllowSpontaneous
    };
    wgpuAdapterRequestDevice(adapter, &descriptor, info);
    
    while (!atomic_load_flag(&request.done)) {
        wgpuInstanceProcessEvents(instance);
        bridge_sleep_one_ms();
    }
    return request.device;
}
BRIDGE_API int WGPU_SurfaceSupportsImmediate(WGPUSurface surface, WGPUAdapter adapter)
{
    /*
     * Surfaceごとに利用可能な表示方式は異なる。FIFOは必須だがImmediateは任意。
     * 対応状況の記憶は Lisp 側が持つ。C側には状態を残さない。
     */
    if (!surface || !adapter) return 0;
    bool supported = false;
    WGPUSurfaceCapabilities capabilities = {0};
    if (wgpuSurfaceGetCapabilities(surface, adapter, &capabilities) == WGPUStatus_Success) {
        for (size_t i = 0; i < capabilities.presentModeCount; i++) {
            if (capabilities.presentModes[i] == WGPUPresentMode_Immediate) {
                supported = true;
                break;
            }
        }
        wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    }
    return supported ? 1 : 0;
}

BRIDGE_API int WGPU_SurfaceSupportsMailbox(WGPUSurface surface, WGPUAdapter adapter)
{
    if (!surface || !adapter) return 0;
    bool supported = false;
    WGPUSurfaceCapabilities capabilities = {0};
    if (wgpuSurfaceGetCapabilities(surface, adapter, &capabilities) == WGPUStatus_Success) {
        for (size_t i = 0; i < capabilities.presentModeCount; i++) {
            if (capabilities.presentModes[i] == WGPUPresentMode_Mailbox) {
                supported = true;
                break;
            }
        }
        wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    }
    return supported ? 1 : 0;
}

BRIDGE_API uint32_t WGPU_SurfacePreferredFormat(WGPUSurface surface, WGPUAdapter adapter)
{
    if (!surface || !adapter) return 0;
    uint32_t result = 0;
    WGPUSurfaceCapabilities capabilities = {0};
    if (wgpuSurfaceGetCapabilities(surface, adapter, &capabilities) == WGPUStatus_Success) {
        for (size_t i = 0; i < capabilities.formatCount; i++) {
            WGPUTextureFormat candidate = capabilities.formats[i];
            if (candidate == WGPUTextureFormat_BGRA8Unorm ||
                candidate == WGPUTextureFormat_RGBA8Unorm) {
                result = (uint32_t)candidate;
                break;
            }
        }
        wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    }
    return result;
}

BRIDGE_API int WGPU_ConfigureSurface(WGPUDevice device, WGPUSurface surface,
                                     uint32_t width, uint32_t height,
                                     uint32_t texture_format, uint32_t present_mode)
{
    /*
     * ウィンドウの大きさに合わせ、表示用画像の交換列（swapchain相当）を設定する。
     * Fifoは垂直同期に合わせて順番に表示し、画面の途中で絵が切れるのを防ぐ。
     * Immediateは垂直同期を待たない。Mailboxは1フレーム分のキューで、新しい
     * フレームが完了すると古い未表示フレームを即座に置き換える（ティアリング
     * なし・低レイテンシ）。対応可否の判定は呼び出し側の責任とする。
     */
    if (!device || !surface || !width || !height) return -1;
    WGPUPresentMode mode;
    switch (present_mode) {
    case 1:  mode = WGPUPresentMode_Immediate; break;
    case 2:  mode = WGPUPresentMode_Mailbox;   break;
    default: mode = WGPUPresentMode_Fifo;      break;
    }
    WGPUSurfaceConfiguration config = {
        .device = device,
        .format = texture_format ? (WGPUTextureFormat)texture_format
                                 : WGPUTextureFormat_BGRA8Unorm,
        .usage = WGPUTextureUsage_RenderAttachment,
        .presentMode = mode,
        .width = width,
        .height = height,
        .alphaMode = WGPUCompositeAlphaMode_Opaque
    };
    wgpuSurfaceConfigure(surface, &config);
    return 0;
}
/* -------------------- 2. 資源の生成 -------------------- */
BRIDGE_API uint32_t WGPU_BufferUsageFlag(uint32_t kind)
{
    /*
     * usage は「何に使ってよいメモリか」を表す許可証。
     * 数値そのものを Lisp 側へ書き写すと wgpu-native の版差でずれるため、
     * 実際の enum 値をここから引けるようにする。Lisp はORで組み合わせる。
     */
    switch ((WGPUBridgeBufferUsageKind)kind) {
    case WGPU_BRIDGE_USAGE_UNIFORM:  return (uint32_t)WGPUBufferUsage_Uniform;
    case WGPU_BRIDGE_USAGE_STORAGE:  return (uint32_t)WGPUBufferUsage_Storage;
    case WGPU_BRIDGE_USAGE_COPY_DST: return (uint32_t)WGPUBufferUsage_CopyDst;
    case WGPU_BRIDGE_USAGE_COPY_SRC: return (uint32_t)WGPUBufferUsage_CopySrc;
    case WGPU_BRIDGE_USAGE_INDIRECT: return (uint32_t)WGPUBufferUsage_Indirect;
    case WGPU_BRIDGE_USAGE_MAP_READ: return (uint32_t)WGPUBufferUsage_MapRead;
    case WGPU_BRIDGE_USAGE_VERTEX:   return (uint32_t)WGPUBufferUsage_Vertex;
    case WGPU_BRIDGE_USAGE_INDEX:    return (uint32_t)WGPUBufferUsage_Index;
    default: return 0u;
    }
}
BRIDGE_API uint32_t WGPU_TextureFormatBGRA8Unorm(void)
{
    return (uint32_t)WGPUTextureFormat_BGRA8Unorm;
}

BRIDGE_API uint32_t WGPU_TextureUsageFlag(uint32_t kind)
{
    switch ((WGPUBridgeTextureUsageKind)kind) {
    case WGPU_BRIDGE_TEXTURE_USAGE_TEXTURE_BINDING:
        return (uint32_t)WGPUTextureUsage_TextureBinding;
    case WGPU_BRIDGE_TEXTURE_USAGE_RENDER_ATTACHMENT:
        return (uint32_t)WGPUTextureUsage_RenderAttachment;
    case WGPU_BRIDGE_TEXTURE_USAGE_COPY_DST:
        return (uint32_t)WGPUTextureUsage_CopyDst;
    case WGPU_BRIDGE_TEXTURE_USAGE_COPY_SRC:
        return (uint32_t)WGPUTextureUsage_CopySrc;
    case WGPU_BRIDGE_TEXTURE_USAGE_STORAGE_BINDING:
        return (uint32_t)WGPUTextureUsage_StorageBinding;
    default: return 0u;
    }
}

BRIDGE_API uint32_t WGPU_TextureFormat(uint32_t kind)
{
    switch ((WGPUBridgeTextureFormatKind)kind) {
    case WGPU_BRIDGE_TEXTURE_FORMAT_BGRA8_UNORM:
        return (uint32_t)WGPUTextureFormat_BGRA8Unorm;
    case WGPU_BRIDGE_TEXTURE_FORMAT_RGBA8_UNORM:
        return (uint32_t)WGPUTextureFormat_RGBA8Unorm;
    case WGPU_BRIDGE_TEXTURE_FORMAT_RGBA8_UNORM_SRGB:
        return (uint32_t)WGPUTextureFormat_RGBA8UnormSrgb;
    case WGPU_BRIDGE_TEXTURE_FORMAT_RGBA32_FLOAT:
        return (uint32_t)WGPUTextureFormat_RGBA32Float;
    case WGPU_BRIDGE_TEXTURE_FORMAT_R8_UNORM:
        return (uint32_t)WGPUTextureFormat_R8Unorm;
    case WGPU_BRIDGE_TEXTURE_FORMAT_DEPTH24_PLUS:
        return (uint32_t)WGPUTextureFormat_Depth24Plus;
    default: return (uint32_t)WGPUTextureFormat_BGRA8Unorm;
    }
}

BRIDGE_API uint32_t WGPU_ViewDimension(uint32_t kind)
{
    switch ((WGPUBridgeViewDimensionKind)kind) {
    case WGPU_BRIDGE_VIEW_DIMENSION_2D:        return (uint32_t)WGPUTextureViewDimension_2D;
    case WGPU_BRIDGE_VIEW_DIMENSION_2D_ARRAY:  return (uint32_t)WGPUTextureViewDimension_2DArray;
    case WGPU_BRIDGE_VIEW_DIMENSION_CUBE:      return (uint32_t)WGPUTextureViewDimension_Cube;
    case WGPU_BRIDGE_VIEW_DIMENSION_CUBE_ARRAY:
        return (uint32_t)WGPUTextureViewDimension_CubeArray;
    default: return (uint32_t)WGPUTextureViewDimension_2D;
    }
}

BRIDGE_API uint32_t WGPU_FilterMode(uint32_t kind)
{
    switch ((WGPUBridgeFilterModeKind)kind) {
    case WGPU_BRIDGE_FILTER_NEAREST: return (uint32_t)WGPUFilterMode_Nearest;
    case WGPU_BRIDGE_FILTER_LINEAR:  return (uint32_t)WGPUFilterMode_Linear;
    default: return (uint32_t)WGPUFilterMode_Linear;
    }
}

BRIDGE_API uint32_t WGPU_AddressMode(uint32_t kind)
{
    switch ((WGPUBridgeAddressModeKind)kind) {
    case WGPU_BRIDGE_ADDRESS_CLAMP_TO_EDGE: return (uint32_t)WGPUAddressMode_ClampToEdge;
    case WGPU_BRIDGE_ADDRESS_REPEAT:        return (uint32_t)WGPUAddressMode_Repeat;
    case WGPU_BRIDGE_ADDRESS_MIRROR_REPEAT: return (uint32_t)WGPUAddressMode_MirrorRepeat;
    default: return (uint32_t)WGPUAddressMode_ClampToEdge;
    }
}
BRIDGE_API WGPUShaderModule WGPU_CreateShaderModule(WGPUDevice device, const char *code)
{
    /* WGSLの文字列を、GPUがpipeline作成に使えるShaderModuleへ変換する。 */
    if (!device || !code) return NULL;
    WGPUShaderSourceWGSL wgsl = {
        .chain = { .sType = WGPUSType_ShaderSourceWGSL },
        .code = { .data = code, .length = strlen(code) }
    };
    WGPUShaderModuleDescriptor descriptor = { .nextInChain = &wgsl.chain };
    return wgpuDeviceCreateShaderModule(device, &descriptor);
}
BRIDGE_API WGPUComputePipeline WGPU_CreateComputePipeline(WGPUDevice device,
                                                          WGPUShaderModule module,
                                                          const char *entry_point)
{
    /* entry_pointはWGSL内で開始する関数名。どの名前でも同じ手順で作れる。 */
    if (!device || !module || !entry_point) return NULL;
    WGPUComputePipelineDescriptor descriptor = {0};
    descriptor.compute.module = module;
    descriptor.compute.entryPoint = sv(entry_point);
    return wgpuDeviceCreateComputePipeline(device, &descriptor);
}
BRIDGE_API WGPURenderPipeline WGPU_CreateRenderPipeline(WGPUDevice device,
                                                        WGPUShaderModule module,
                                                        const char *vertex_entry,
                                                        const char *fragment_entry,
                                                        uint32_t texture_format)
{
    /*
     * 描画pipelineは、頂点処理と色処理を1本につなぐ。
     * entry point名と出力formatを引数にしたので、Life以外の描画でも使える。
     * BGRA8Unormは青・緑・赤・透明度を各8ビットで持つ一般的な画面形式。
     * この関数は頂点バッファを使わない全画面三角形描画専用で、
     * seascape/lifegame が使う。頂点バッファが要る描画は
     * WGPU_CreateVertexRenderPipeline を使うこと。
     */
    if (!device || !module || !vertex_entry || !fragment_entry) return NULL;
    WGPUColorTargetState target = {
        .format = texture_format ? (WGPUTextureFormat)texture_format
                                 : WGPUTextureFormat_BGRA8Unorm,
        .writeMask = WGPUColorWriteMask_All
    };
    WGPUFragmentState fragment = {
        .module = module,
        .entryPoint = sv(fragment_entry),
        .targetCount = 1,
        .targets = &target
    };
    WGPURenderPipelineDescriptor descriptor = {0};
    descriptor.vertex.module = module;
    descriptor.vertex.entryPoint = sv(vertex_entry);
    descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    descriptor.multisample.count = 1;
    descriptor.multisample.mask = 0xffffffffu;
    descriptor.fragment = &fragment;
    return wgpuDeviceCreateRenderPipeline(device, &descriptor);
}

#define WGPU_BRIDGE_MAX_ASYNC_PIPELINES 8u
typedef struct {
    BridgeAtomicBool done;
    WGPURenderPipeline pipeline;
    WGPUCreatePipelineAsyncStatus status;
} PipelineAsyncRequest;
static void render_pipeline_async_callback(WGPUCreatePipelineAsyncStatus status,
                                           WGPURenderPipeline pipeline,
                                           WGPUStringView message,
                                           void *userdata1, void *userdata2)
{
    /* 非同期のpipeline作成が終わったときに呼ばれる。結果を要求の構造体へ
       書いてから、最後にdoneをtrueにする（待っている側がdoneを見て読む）。 */
    PipelineAsyncRequest *request = userdata1;
    (void)userdata2;
    request->status = status;
    request->pipeline = pipeline;
    if (status != WGPUCreatePipelineAsyncStatus_Success) {
        fprintf(stderr, "[wgpu] CreateRenderPipelineAsync status=%d: %.*s\n",
                (int)status,
                message.data ? (int)message.length : 0,
                message.data ? message.data : "");
        fflush(stderr);
    }
    atomic_store_flag(&request->done, true);
}
/*
 * 全画面三角形用のrender pipelineを、COUNT本ぶん非同期に作る。
 * WGPU_CreateRenderPipeline（同期版）と同じ用途・同じ設定で、
 * vertex_entry は "fullscreen_vertex"、fragment_entry は "main" に固定する。
 * 全てのコールバックが来るまで待ってから戻る。
 * 戻り値: 0=全部成功、-1=1本でも失敗（失敗したものは out_pipelines が NULL）。
 *
 * idle_callback: NULLでなければ、待ちループの1周ごと（約1ミリ秒ごと）に、
 * この関数を呼んだスレッド自身から呼ばれる。待ちが数十秒に及ぶとき、呼び出し側が
 * ウィンドウのイベント処理などを続けられるようにするための口（例: Windowsで、
 * 約5秒メッセージを処理しないと「応答なし」になるのを避ける）。このファイルは
 * ウィンドウライブラリへ依存しない方針なので、何を呼ぶかは呼び出し側が決める。
 * 呼ばれた関数の中で、この関数やDawnの関数を呼んではならない。
 */
typedef void (*WGPUBridgeIdleCallback)(void);
BRIDGE_API int WGPU_CreateRenderPipelinesAsync(
    WGPUInstance instance, WGPUDevice device,
    const WGPUShaderModule *modules, const uint32_t *texture_formats,
    uint32_t count, WGPURenderPipeline *out_pipelines,
    WGPUBridgeIdleCallback idle_callback)
{
    if (!instance || !device || !modules || !texture_formats || !out_pipelines ||
        !count || count > WGPU_BRIDGE_MAX_ASYNC_PIPELINES) return -1;
    PipelineAsyncRequest requests[WGPU_BRIDGE_MAX_ASYNC_PIPELINES] = {0};
    WGPUColorTargetState targets[WGPU_BRIDGE_MAX_ASYNC_PIPELINES];
    WGPUFragmentState fragments[WGPU_BRIDGE_MAX_ASYNC_PIPELINES];
    WGPURenderPipelineDescriptor descriptors[WGPU_BRIDGE_MAX_ASYNC_PIPELINES];
    int result = 0;
    for (uint32_t i = 0; i < count; i++) {
        out_pipelines[i] = NULL;
        if (!modules[i]) {
            result = -1;
            atomic_store_flag(&requests[i].done, true);
            continue;
        }
        memset(&targets[i], 0, sizeof targets[i]);
        targets[i].format = texture_formats[i] ? (WGPUTextureFormat)texture_formats[i]
                                               : WGPUTextureFormat_BGRA8Unorm;
        targets[i].writeMask = WGPUColorWriteMask_All;
        memset(&fragments[i], 0, sizeof fragments[i]);
        fragments[i].module = modules[i];
        fragments[i].entryPoint = sv("main");
        fragments[i].targetCount = 1;
        fragments[i].targets = &targets[i];
        memset(&descriptors[i], 0, sizeof descriptors[i]);
        descriptors[i].vertex.module = modules[i];
        descriptors[i].vertex.entryPoint = sv("fullscreen_vertex");
        descriptors[i].primitive.topology = WGPUPrimitiveTopology_TriangleList;
        descriptors[i].multisample.count = 1;
        descriptors[i].multisample.mask = 0xffffffffu;
        descriptors[i].fragment = &fragments[i];
    }
    /* 先に全部を依頼する。ここでは待たない。 */
    for (uint32_t i = 0; i < count; i++) {
        if (atomic_load_flag(&requests[i].done)) continue;  /* moduleがNULLだった分 */
        WGPUCreateRenderPipelineAsyncCallbackInfo info =
            WGPU_CREATE_RENDER_PIPELINE_ASYNC_CALLBACK_INFO_INIT;
        info.mode = WGPUCallbackMode_AllowSpontaneous;
        info.callback = render_pipeline_async_callback;
        info.userdata1 = &requests[i];
        wgpuDeviceCreateRenderPipelineAsync(device, &descriptors[i], info);
    }
    /* 全部のコールバックが来るまで、イベントをポンプしながら待つ。 */
    for (;;) {
        bool all_done = true;
        for (uint32_t i = 0; i < count; i++) {
            if (!atomic_load_flag(&requests[i].done)) { all_done = false; break; }
        }
        if (all_done) break;
        wgpuInstanceProcessEvents(instance);
        bridge_sleep_one_ms();
        if (idle_callback) idle_callback();
    }
    for (uint32_t i = 0; i < count; i++) {
        if (requests[i].status == WGPUCreatePipelineAsyncStatus_Success &&
            requests[i].pipeline) {
            out_pipelines[i] = requests[i].pipeline;
        } else {
            result = -1;
        }
    }
    return result;
}
BRIDGE_API uint32_t WGPU_VertexFormat(uint32_t kind)
{
    switch ((WGPUBridgeVertexFormatKind)kind) {
    case WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32:   return (uint32_t)WGPUVertexFormat_Float32;
    case WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X2: return (uint32_t)WGPUVertexFormat_Float32x2;
    case WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X3: return (uint32_t)WGPUVertexFormat_Float32x3;
    case WGPU_BRIDGE_VERTEX_FORMAT_FLOAT32X4: return (uint32_t)WGPUVertexFormat_Float32x4;
    case WGPU_BRIDGE_VERTEX_FORMAT_UINT32:    return (uint32_t)WGPUVertexFormat_Uint32;
    default: return (uint32_t)WGPUVertexFormat_Float32x3;
    }
}
BRIDGE_API uint32_t WGPU_VertexStepMode(uint32_t kind)
{
    switch ((WGPUBridgeVertexStepModeKind)kind) {
    case WGPU_BRIDGE_STEP_MODE_VERTEX:   return (uint32_t)WGPUVertexStepMode_Vertex;
    case WGPU_BRIDGE_STEP_MODE_INSTANCE: return (uint32_t)WGPUVertexStepMode_Instance;
    default: return (uint32_t)WGPUVertexStepMode_Vertex;
    }
}
BRIDGE_API uint32_t WGPU_CullMode(uint32_t kind)
{
    switch ((WGPUBridgeCullModeKind)kind) {
    case WGPU_BRIDGE_CULL_MODE_NONE:  return (uint32_t)WGPUCullMode_None;
    case WGPU_BRIDGE_CULL_MODE_FRONT: return (uint32_t)WGPUCullMode_Front;
    case WGPU_BRIDGE_CULL_MODE_BACK:  return (uint32_t)WGPUCullMode_Back;
    default: return (uint32_t)WGPUCullMode_None;
    }
}
BRIDGE_API uint32_t WGPU_IndexFormat(uint32_t kind)
{
    switch ((WGPUBridgeIndexFormatKind)kind) {
    case WGPU_BRIDGE_INDEX_FORMAT_UINT16: return (uint32_t)WGPUIndexFormat_Uint16;
    case WGPU_BRIDGE_INDEX_FORMAT_UINT32: return (uint32_t)WGPUIndexFormat_Uint32;
    default: return (uint32_t)WGPUIndexFormat_Uint32;
    }
}
BRIDGE_API uint32_t WGPU_PrimitiveTopology(uint32_t kind)
{
    switch ((WGPUBridgeTopologyKind)kind) {
    case WGPU_BRIDGE_TOPOLOGY_TRIANGLE_LIST:  return (uint32_t)WGPUPrimitiveTopology_TriangleList;
    case WGPU_BRIDGE_TOPOLOGY_TRIANGLE_STRIP: return (uint32_t)WGPUPrimitiveTopology_TriangleStrip;
    case WGPU_BRIDGE_TOPOLOGY_LINE_LIST:      return (uint32_t)WGPUPrimitiveTopology_LineList;
    case WGPU_BRIDGE_TOPOLOGY_LINE_STRIP:     return (uint32_t)WGPUPrimitiveTopology_LineStrip;
    case WGPU_BRIDGE_TOPOLOGY_POINT_LIST:     return (uint32_t)WGPUPrimitiveTopology_PointList;
    default: return (uint32_t)WGPUPrimitiveTopology_TriangleList;
    }
}

BRIDGE_API WGPURenderPipeline WGPU_CreateVertexRenderPipeline(
    WGPUDevice device, WGPUShaderModule module,
    const char *vertex_entry, const char *fragment_entry,
    uint32_t texture_format, uint32_t sample_count,
    uint64_t vertex_stride, uint32_t step_mode,
    const WGPUBridgeVertexAttribute *attributes, uint32_t attribute_count,
    uint32_t topology, uint32_t cull_mode,
    uint32_t depth_enabled, uint32_t blend_enabled)
{
    if (!device || !module || !vertex_entry || !fragment_entry) return NULL;
    if (!vertex_stride || !attributes || !attribute_count ||
        attribute_count > WGPU_BRIDGE_MAX_BIND_ENTRIES) return NULL;
    WGPUBlendState blend = {
        .color = { .operation = WGPUBlendOperation_Add,
                  .srcFactor = WGPUBlendFactor_SrcAlpha,
                  .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha },
        .alpha = { .operation = WGPUBlendOperation_Add,
                  .srcFactor = WGPUBlendFactor_One,
                  .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha }
    };
    WGPUColorTargetState target = {
        .format = texture_format ? (WGPUTextureFormat)texture_format
                                 : WGPUTextureFormat_BGRA8Unorm,
        .writeMask = WGPUColorWriteMask_All,
        .blend = blend_enabled ? &blend : NULL
    };
    WGPUFragmentState fragment = {
        .module = module,
        .entryPoint = sv(fragment_entry),
        .targetCount = 1,
        .targets = &target
    };
    WGPUDepthStencilState depth = {
        .format = WGPUTextureFormat_Depth24Plus,
        .depthWriteEnabled = WGPUOptionalBool_True,
        /* Material.depthFunc defaults to LessEqualDepth in three.core.js. */
        .depthCompare = WGPUCompareFunction_LessEqual,
        .stencilFront = { .compare = WGPUCompareFunction_Always,
                          .failOp = WGPUStencilOperation_Keep,
                          .depthFailOp = WGPUStencilOperation_Keep,
                          .passOp = WGPUStencilOperation_Keep },
        .stencilBack = { .compare = WGPUCompareFunction_Always,
                         .failOp = WGPUStencilOperation_Keep,
                         .depthFailOp = WGPUStencilOperation_Keep,
                         .passOp = WGPUStencilOperation_Keep },
        .stencilReadMask = 0xffffffffu,
        .stencilWriteMask = 0xffffffffu,
        .depthBias = 0,
        .depthBiasSlopeScale = 0.0f,
        .depthBiasClamp = 0.0f
    };
    /* attribute_count は WGPU_BRIDGE_MAX_BIND_ENTRIES 以下であることを確認済み。 */
    WGPUVertexAttribute native_attributes[WGPU_BRIDGE_MAX_BIND_ENTRIES];
    for (uint32_t i = 0; i < attribute_count; i++) {
        native_attributes[i].format = (WGPUVertexFormat)attributes[i].format;
        native_attributes[i].offset = attributes[i].offset;
        native_attributes[i].shaderLocation = attributes[i].shader_location;
    }
    WGPUVertexBufferLayout layout = {
        .arrayStride = vertex_stride,
        .stepMode = (WGPUVertexStepMode)step_mode,
        .attributeCount = attribute_count,
        .attributes = native_attributes
    };
    WGPURenderPipelineDescriptor descriptor = {0};
    descriptor.vertex.module = module;
    descriptor.vertex.bufferCount = 1;
    descriptor.vertex.buffers = &layout;
    descriptor.vertex.entryPoint = sv(vertex_entry);
    descriptor.primitive.topology =
        (WGPUPrimitiveTopology)(topology ? topology : WGPUPrimitiveTopology_TriangleList);
    descriptor.primitive.frontFace = WGPUFrontFace_CCW;
    descriptor.primitive.cullMode = (WGPUCullMode)cull_mode;
    if (depth_enabled) descriptor.depthStencil = &depth;
    descriptor.multisample.count = sample_count ? sample_count : 1;
    descriptor.multisample.mask = 0xffffffffu;
    descriptor.fragment = &fragment;
    return wgpuDeviceCreateRenderPipeline(device, &descriptor);
}
BRIDGE_API WGPUBuffer WGPU_CreateBuffer(WGPUDevice device, uint32_t usage, uint64_t size)
{
    /* usageはWGPU_BufferUsageFlagで得た値のOR。sizeはバイト数。 */
    if (!device || !size) return NULL;
    WGPUBufferDescriptor descriptor = { .usage = (WGPUBufferUsage)usage, .size = size };
    return wgpuDeviceCreateBuffer(device, &descriptor);
}
BRIDGE_API WGPUBindGroupLayout WGPU_GetComputeBindGroupLayout(WGPUComputePipeline pipeline,
                                                              uint32_t group_index)
{
    if (!pipeline) return NULL;
    return wgpuComputePipelineGetBindGroupLayout(pipeline, group_index);
}
BRIDGE_API WGPUBindGroupLayout WGPU_GetRenderBindGroupLayout(WGPURenderPipeline pipeline,
                                                             uint32_t group_index)
{
    if (!pipeline) return NULL;
    return wgpuRenderPipelineGetBindGroupLayout(pipeline, group_index);
}
BRIDGE_API WGPUBindGroup WGPU_CreateBindGroup(WGPUDevice device,
                                              WGPUBindGroupLayout layout,
                                              const WGPUBridgeBindGroupEntry *entries,
                                              uint32_t entry_count)
{
    
    if (!device || !layout || !entries || !entry_count ||
        entry_count > WGPU_BRIDGE_MAX_BIND_ENTRIES) return NULL;
    WGPUBindGroupEntry native[WGPU_BRIDGE_MAX_BIND_ENTRIES] = {0};
    for (uint32_t i = 0; i < entry_count; i++) {
        if (!entries[i].resource) return NULL;
        native[i].binding = entries[i].binding;
        switch ((WGPUBridgeBindEntryKind)entries[i].kind) {
        case WGPU_BRIDGE_BIND_ENTRY_SAMPLER:
            /* サンプラーを差す。offset/sizeは使わない。 */
            native[i].sampler = (WGPUSampler)entries[i].resource;
            break;
        case WGPU_BRIDGE_BIND_ENTRY_TEXTURE_VIEW:
            /* テクスチャビューを差す。offset/sizeは使わない。 */
            native[i].textureView = (WGPUTextureView)entries[i].resource;
            break;
        case WGPU_BRIDGE_BIND_ENTRY_BUFFER:
        default: {
            uint64_t size = entries[i].size;
            if (!size) {
                size = wgpuBufferGetSize((WGPUBuffer)entries[i].resource);
                if (!size) return NULL;
            }
            native[i].buffer = (WGPUBuffer)entries[i].resource;
            native[i].offset = entries[i].offset;
            native[i].size = size;
            break;
        }
        }
    }
    WGPUBindGroupDescriptor descriptor = {
        .layout = layout, .entryCount = entry_count, .entries = native
    };
    return wgpuDeviceCreateBindGroup(device, &descriptor);
}

BRIDGE_API WGPUTexture WGPU_CreateTexture(
    WGPUDevice device, uint32_t width, uint32_t height, uint32_t depth_or_array_layers,
    uint32_t format, uint32_t usage, uint32_t mip_level_count, uint32_t sample_count)
{
    if (!device || !width || !height || !depth_or_array_layers ||
        !mip_level_count || !sample_count) return NULL;
    WGPUTextureDescriptor descriptor = {0};
    descriptor.usage = (WGPUTextureUsage)usage;
    descriptor.dimension = WGPUTextureDimension_2D;
    descriptor.size.width = width;
    descriptor.size.height = height;
    descriptor.size.depthOrArrayLayers = depth_or_array_layers;
    descriptor.format = (WGPUTextureFormat)format;
    descriptor.mipLevelCount = mip_level_count;
    descriptor.sampleCount = sample_count;
    return wgpuDeviceCreateTexture(device, &descriptor);
}

BRIDGE_API WGPUTextureView WGPU_CreateTextureViewEx(
    WGPUTexture texture, uint32_t format, uint32_t dimension,
    uint32_t base_mip_level, uint32_t mip_level_count,
    uint32_t base_array_layer, uint32_t array_layer_count)
{
    if (!texture) return NULL;
    WGPUTextureViewDescriptor descriptor = {0};
    descriptor.format = (WGPUTextureFormat)format;
    descriptor.dimension = (WGPUTextureViewDimension)dimension;
    descriptor.baseMipLevel = base_mip_level;
    descriptor.mipLevelCount = mip_level_count ? mip_level_count
                                               : WGPU_MIP_LEVEL_COUNT_UNDEFINED;
    descriptor.baseArrayLayer = base_array_layer;
    descriptor.arrayLayerCount = array_layer_count ? array_layer_count
                                                   : WGPU_ARRAY_LAYER_COUNT_UNDEFINED;
    return wgpuTextureCreateView(texture, &descriptor);
}

static bool filter_mode_matches_mipmap_filter_mode(void)
{
    return (int)WGPUMipmapFilterMode_Nearest == (int)WGPUFilterMode_Nearest &&
           (int)WGPUMipmapFilterMode_Linear == (int)WGPUFilterMode_Linear;
}
BRIDGE_API WGPUSampler WGPU_CreateSampler(
    WGPUDevice device,
    uint32_t address_mode_u, uint32_t address_mode_v, uint32_t address_mode_w,
    uint32_t mag_filter, uint32_t min_filter, uint32_t mipmap_filter)
{
    if (!device) return NULL;
    /*
     * WGPUSamplerDescriptor.mipmapFilter の型は WGPUMipmapFilterMode で
     * あり、magFilter/minFilter が使う WGPUFilterMode とは別の列挙型
     * （webgpu-headers公式ドキュメントで確認済み）。呼び出し側は
     * WGPU_FilterModeで変換した値をmipmap_filterにも渡してくる前提のため、
     * 両者の実際の整数値が一致しているかをここで検証する。食い違っていれば
     * NULLを返し、呼び出し側のrequire-handleがエラーにする（無言で誤った
     * フィルタを設定しない）。
     */
    if (!filter_mode_matches_mipmap_filter_mode()) {
        fprintf(stderr,
                "[wgpu] WGPUFilterMode と WGPUMipmapFilterMode の値が一致しません。"
                "WGPU_CreateSampler の実装を見直してください。\n");
        return NULL;
    }
    WGPUSamplerDescriptor descriptor = {0};
    descriptor.addressModeU = (WGPUAddressMode)address_mode_u;
    descriptor.addressModeV = (WGPUAddressMode)address_mode_v;
    descriptor.addressModeW = (WGPUAddressMode)address_mode_w;
    descriptor.magFilter = (WGPUFilterMode)mag_filter;
    descriptor.minFilter = (WGPUFilterMode)min_filter;
    descriptor.mipmapFilter = (WGPUMipmapFilterMode)mipmap_filter;
    /* lodMaxClampを0のままにすると、mipmapのレベル0しかサンプルできなく
       なってしまう（GPUの既定動作ではなく、このdescriptorの初期化による
       事故を防ぐため、spec既定値と同じ0〜32を明示する）。 */
    descriptor.lodMinClamp = 0.0f;
    descriptor.lodMaxClamp = 32.0f;
    descriptor.compare = WGPUCompareFunction_Undefined;
    descriptor.maxAnisotropy = 1;
    return wgpuDeviceCreateSampler(device, &descriptor);
}

BRIDGE_API WGPUCommandEncoder WGPU_CreateCommandEncoder(WGPUDevice device)
{
    if (!device) return NULL;
    return wgpuDeviceCreateCommandEncoder(device, NULL);
}

BRIDGE_API WGPUTexture WGPU_CreateColorAttachmentTexture(
    WGPUDevice device, uint32_t width, uint32_t height,
    uint32_t format, uint32_t sample_count)
{
    /* MSAA用の色テクスチャ。formatが0のときはSurfaceと同じBGRA8Unormにする。 */
    if (!device || !width || !height || !sample_count) return NULL;
    WGPUTextureDescriptor descriptor = {0};
    descriptor.usage = WGPUTextureUsage_RenderAttachment;
    descriptor.dimension = WGPUTextureDimension_2D;
    descriptor.size.width = width;
    descriptor.size.height = height;
    descriptor.size.depthOrArrayLayers = 1;
    descriptor.format = format ? (WGPUTextureFormat)format : WGPUTextureFormat_BGRA8Unorm;
    descriptor.mipLevelCount = 1;
    descriptor.sampleCount = sample_count;
    return wgpuDeviceCreateTexture(device, &descriptor);
}
BRIDGE_API WGPUTexture WGPU_CreateDepthTexture(
    WGPUDevice device, uint32_t width, uint32_t height, uint32_t sample_count)
{
    /* 深度テクスチャ。formatはWGPU_RunRenderCommandFrameの既存実装と同じDepth24Plus固定。 */
    if (!device || !width || !height || !sample_count) return NULL;
    WGPUTextureDescriptor descriptor = {0};
    descriptor.usage = WGPUTextureUsage_RenderAttachment;
    descriptor.dimension = WGPUTextureDimension_2D;
    descriptor.size.width = width;
    descriptor.size.height = height;
    descriptor.size.depthOrArrayLayers = 1;
    descriptor.format = WGPUTextureFormat_Depth24Plus;
    descriptor.mipLevelCount = 1;
    descriptor.sampleCount = sample_count;
    return wgpuDeviceCreateTexture(device, &descriptor);
}
BRIDGE_API WGPUTextureView WGPU_CreateTextureView(WGPUTexture texture)
{
    /* 色・深度の両方で使う共通のview作成。用途ごとに関数を分ける理由がないため1本。 */
    if (!texture) return NULL;
    return wgpuTextureCreateView(texture, NULL);
}
BRIDGE_API void WGPU_Release(uint32_t kind, void *handle)
{
    /*
     * 解放関数を1本にまとめ、Lisp側のdefcfunを種類ごとに並べなくて済むようにする。
     * NULLは無視するので、初期化途中で失敗した資源もまとめて渡せる。
     */
    if (!handle) return;
    switch ((WGPUBridgeObjectKind)kind) {
    case WGPU_BRIDGE_OBJECT_BUFFER:
        wgpuBufferRelease((WGPUBuffer)handle); break;
    case WGPU_BRIDGE_OBJECT_BIND_GROUP:
        wgpuBindGroupRelease((WGPUBindGroup)handle); break;
    case WGPU_BRIDGE_OBJECT_BIND_GROUP_LAYOUT:
        wgpuBindGroupLayoutRelease((WGPUBindGroupLayout)handle); break;
    case WGPU_BRIDGE_OBJECT_COMPUTE_PIPELINE:
        wgpuComputePipelineRelease((WGPUComputePipeline)handle); break;
    case WGPU_BRIDGE_OBJECT_RENDER_PIPELINE:
        wgpuRenderPipelineRelease((WGPURenderPipeline)handle); break;
    case WGPU_BRIDGE_OBJECT_SHADER_MODULE:
        wgpuShaderModuleRelease((WGPUShaderModule)handle); break;
    case WGPU_BRIDGE_OBJECT_QUEUE:
        wgpuQueueRelease((WGPUQueue)handle); break;
    case WGPU_BRIDGE_OBJECT_DEVICE:
        wgpuDeviceRelease((WGPUDevice)handle); break;
    case WGPU_BRIDGE_OBJECT_ADAPTER:
        wgpuAdapterRelease((WGPUAdapter)handle); break;
    case WGPU_BRIDGE_OBJECT_SURFACE:
        wgpuSurfaceRelease((WGPUSurface)handle); break;
    case WGPU_BRIDGE_OBJECT_INSTANCE:
        wgpuInstanceRelease((WGPUInstance)handle); break;
    
    case WGPU_BRIDGE_OBJECT_TEXTURE:
        wgpuTextureRelease((WGPUTexture)handle); break;
    case WGPU_BRIDGE_OBJECT_TEXTURE_VIEW:
        wgpuTextureViewRelease((WGPUTextureView)handle); break;
    
    case WGPU_BRIDGE_OBJECT_SAMPLER:
        wgpuSamplerRelease((WGPUSampler)handle); break;
    case WGPU_BRIDGE_OBJECT_ENCODER:
        wgpuCommandEncoderRelease((WGPUCommandEncoder)handle); break;
    default:
        break;
    }
}
/* -------------------- 3. 命令の実行 -------------------- */
/*
 * Lispからwgpu-nativeを1命令ずつ呼ぶと、LispとCを何度も往復する。
 * そこで、Lispは「やることリスト」だけを作り、Cがまとめて実行する。
 * この仕組みはLife専用ではなく、どのCompute実験でも使える。
 */
BRIDGE_API int WGPU_EncodeComputeCommands(
    WGPUCommandEncoder encoder,
    const WGPUBridgeComputeCommand *commands,
    uint32_t command_count)
{
    if (!encoder || (!commands && command_count)) return -1;
    WGPUComputePassEncoder pass = NULL;
    for (uint32_t i = 0; i < command_count; i++) {
        const WGPUBridgeComputeCommand *command = &commands[i];
        switch ((WGPUBridgeComputeOpcode)command->opcode) {
        case WGPU_BRIDGE_COMPUTE_CLEAR_BUFFER:
            if (pass || !command->object || !command->size) goto fail;
            wgpuCommandEncoderClearBuffer(
                encoder, (WGPUBuffer)command->object,
                command->offset, command->size);
            break;
        case WGPU_BRIDGE_COMPUTE_BEGIN_PASS:
            if (pass) goto fail;
            pass = wgpuCommandEncoderBeginComputePass(encoder, NULL);
            if (!pass) goto fail;
            break;
        case WGPU_BRIDGE_COMPUTE_SET_PIPELINE:
            if (!pass || !command->object) goto fail;
            wgpuComputePassEncoderSetPipeline(
                pass, (WGPUComputePipeline)command->object);
            break;
        case WGPU_BRIDGE_COMPUTE_SET_BIND_GROUP:
            if (!pass || !command->object) goto fail;
            wgpuComputePassEncoderSetBindGroup(
                pass, command->x, (WGPUBindGroup)command->object, 0, NULL);
            break;
        case WGPU_BRIDGE_COMPUTE_DISPATCH:
            if (!pass || !command->x || !command->y || !command->z) goto fail;
            wgpuComputePassEncoderDispatchWorkgroups(
                pass, command->x, command->y, command->z);
            break;
        case WGPU_BRIDGE_COMPUTE_DISPATCH_INDIRECT:
            if (!pass || !command->object) goto fail;
            wgpuComputePassEncoderDispatchWorkgroupsIndirect(
                pass, (WGPUBuffer)command->object, command->offset);
            break;
        case WGPU_BRIDGE_COMPUTE_COPY_BUFFER:
            wgpuCommandEncoderCopyBufferToBuffer(
                encoder, (WGPUBuffer)command->object, command->offset,
                (WGPUBuffer)command->argument, command->destination_offset,
                command->size);
            break;
        case WGPU_BRIDGE_COMPUTE_END_PASS:
            if (!pass) goto fail;
            wgpuComputePassEncoderEnd(pass);
            wgpuComputePassEncoderRelease(pass);
            pass = NULL;
            break;
        default:
            goto fail;
        }
    }
    if (pass) goto fail;
    return 0;
fail:
    if (pass) wgpuComputePassEncoderRelease(pass);
    return -1;
}
typedef struct {
    BridgeAtomicBool done;
    WGPUQueueWorkDoneStatus status;
} SubmitRequest;
static void submit_callback(WGPUQueueWorkDoneStatus status, WGPUStringView message,
                            void *userdata1, void *userdata2)
{
    /* Dawn migration: callback includes a message in this generated header. */
    SubmitRequest *request = userdata1;
    (void)message; (void)userdata2;
    request->status = status;
    atomic_store_flag(&request->done, true);
}
static int submit_encoder(WGPUDevice device, WGPUQueue queue,
                          WGPUCommandEncoder encoder, bool wait)
{
    WGPUCommandBuffer command = wgpuCommandEncoderFinish(encoder, NULL);
    if (!command) return -1;
    wgpuQueueSubmit(queue, 1, &command);
    wgpuCommandBufferRelease(command);
    if (wait) {
        /* Dawn migration: register after submit to cover this submission. */
        SubmitRequest request = {0};
        WGPUQueueWorkDoneCallbackInfo info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        info.mode = WGPUCallbackMode_AllowSpontaneous;
        info.callback = submit_callback;
        info.userdata1 = &request;
        wgpuQueueOnSubmittedWorkDone(queue, info);
        
        while (!atomic_load_flag(&request.done)) {
            wgpuDeviceTick(device);
            bridge_sleep_one_ms();
        }
        return request.status == WGPUQueueWorkDoneStatus_Success ? 0 : -1;
    }
    return 0;
}
BRIDGE_API int WGPU_RunComputeCommands(
    WGPUDevice device, WGPUQueue queue,
    const WGPUBridgeComputeCommand *commands,
    uint32_t command_count, uint32_t wait)
{
    if (!device || !queue || (!commands && command_count)) return -1;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) return -1;
    int result = WGPU_EncodeComputeCommands(encoder, commands, command_count);
    if (result == 0) result = submit_encoder(device, queue, encoder, wait != 0);
    wgpuCommandEncoderRelease(encoder);
    return result;
}
/* Draw instructions use the existing 56-byte command record, but a separate
 * opcode namespace. The caller supplies every pipeline, buffer and draw count.
 * x: slot or count, y: instance count, z: first vertex/index.
 * offset: byte offset or first instance, size: byte length (0 = whole buffer).
 * destination_offset: signed base vertex for indexed draws.
 */
enum {
    WGPU_BRIDGE_RENDER_SET_PIPELINE = 1,
    WGPU_BRIDGE_RENDER_SET_BIND_GROUP = 2,
    WGPU_BRIDGE_RENDER_SET_VERTEX_BUFFER = 3,
    WGPU_BRIDGE_RENDER_SET_INDEX_BUFFER = 4,
    WGPU_BRIDGE_RENDER_DRAW = 5,
    WGPU_BRIDGE_RENDER_DRAW_INDEXED = 6
};
static int WGPU_EncodeRenderCommands(
    WGPURenderPassEncoder pass, const WGPUBridgeComputeCommand *commands,
    uint32_t count)
{
    for (uint32_t i = 0; i < count; ++i) {
        const WGPUBridgeComputeCommand *cmd = &commands[i];
        switch (cmd->opcode) {
        case WGPU_BRIDGE_RENDER_SET_PIPELINE:
            if (!cmd->object) return -1;
            wgpuRenderPassEncoderSetPipeline(pass, (WGPURenderPipeline)cmd->object);
            break;
        case WGPU_BRIDGE_RENDER_SET_BIND_GROUP:
            if (!cmd->object) return -1;
            wgpuRenderPassEncoderSetBindGroup(pass, cmd->x,
                                              (WGPUBindGroup)cmd->object, 0, NULL);
            break;
        case WGPU_BRIDGE_RENDER_SET_VERTEX_BUFFER:
            if (!cmd->object) return -1;
            wgpuRenderPassEncoderSetVertexBuffer(pass, cmd->x,
                (WGPUBuffer)cmd->object, cmd->offset,
                cmd->size ? cmd->size : WGPU_WHOLE_SIZE);
            break;
        case WGPU_BRIDGE_RENDER_SET_INDEX_BUFFER:
            if (!cmd->object) return -1;
            wgpuRenderPassEncoderSetIndexBuffer(pass, (WGPUBuffer)cmd->object,
                (WGPUIndexFormat)cmd->x, cmd->offset,
                cmd->size ? cmd->size : WGPU_WHOLE_SIZE);
            break;
        case WGPU_BRIDGE_RENDER_DRAW:
            wgpuRenderPassEncoderDraw(pass, cmd->x, cmd->y, cmd->z,
                                      (uint32_t)cmd->offset);
            break;
        case WGPU_BRIDGE_RENDER_DRAW_INDEXED:
            wgpuRenderPassEncoderDrawIndexed(pass, cmd->x, cmd->y, cmd->z,
                (int32_t)(uint32_t)cmd->destination_offset, (uint32_t)cmd->offset);
            break;
        default:
            return -1;
        }
    }
    return 0;
}

BRIDGE_API int WGPU_RunRenderCommandFrame(
    WGPUDevice device, WGPUQueue queue, WGPUSurface surface,
    const WGPUBridgeComputeCommand *commands, uint32_t command_count,
    const WGPUBridgeComputeCommand *render_commands, uint32_t render_count,
    uint32_t width, uint32_t height,
    WGPUTextureView msaa_view, WGPUTextureView depth_view,
    double clear_r, double clear_g, double clear_b, double clear_a)
{
    WGPUTextureView surface_view = NULL;
    WGPUCommandEncoder encoder = NULL;
    WGPURenderPassEncoder pass = NULL;
    bool use_msaa = (msaa_view != NULL);
    bool depth_enabled = (depth_view != NULL);
    if (!device || !queue || !surface || (!commands && command_count) ||
        (!render_commands && render_count)) return -1;
    if (!width || !height) return 1;
    WGPUSurfaceTexture surface_texture = WGPU_SURFACE_TEXTURE_INIT;
    wgpuSurfaceGetCurrentTexture(surface, &surface_texture);
    if (surface_texture.status == WGPUSurfaceGetCurrentTextureStatus_Timeout ||
        surface_texture.status == WGPUSurfaceGetCurrentTextureStatus_Outdated ||
        surface_texture.status == WGPUSurfaceGetCurrentTextureStatus_Lost) {
        if (surface_texture.texture) wgpuTextureRelease(surface_texture.texture);
        return 1;
    }
    if (!surface_texture.texture) return -1;
    surface_view = wgpuTextureCreateView(surface_texture.texture, NULL);
    if (!surface_view) goto fail_render_frame;
    encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) goto fail_render_frame;
    if (WGPU_EncodeComputeCommands(encoder, commands, command_count) < 0)
        goto fail_render_frame;
    WGPURenderPassColorAttachment color = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    if (use_msaa) {
        color.view = msaa_view;
        color.resolveTarget = surface_view;
        color.storeOp = WGPUStoreOp_Discard;
    } else {
        color.view = surface_view;
        color.resolveTarget = NULL;
        color.storeOp = WGPUStoreOp_Store;
    }
    color.loadOp = WGPULoadOp_Clear;
    color.clearValue = (WGPUColor){clear_r, clear_g, clear_b, clear_a};
    WGPURenderPassDepthStencilAttachment depth_attachment = {0};
    if (depth_enabled) {
        depth_attachment.view = depth_view;
        depth_attachment.depthLoadOp = WGPULoadOp_Clear;
        depth_attachment.depthStoreOp = WGPUStoreOp_Discard;
        depth_attachment.depthClearValue = 1.0f;
        depth_attachment.depthReadOnly = false;
        depth_attachment.stencilLoadOp = WGPULoadOp_Undefined;
        depth_attachment.stencilStoreOp = WGPUStoreOp_Undefined;
        depth_attachment.stencilReadOnly = true;
    }
    WGPURenderPassDescriptor descriptor = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    descriptor.colorAttachmentCount = 1;
    descriptor.colorAttachments = &color;
    descriptor.depthStencilAttachment = depth_enabled ? &depth_attachment : NULL;
    pass = wgpuCommandEncoderBeginRenderPass(encoder, &descriptor);
    if (!pass) goto fail_render_frame;
    /* Execute the caller's drawing instructions in exactly the given order. */
    if (WGPU_EncodeRenderCommands(pass, render_commands, render_count) < 0)
        goto fail_render_frame;
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    pass = NULL;
    if (submit_encoder(device, queue, encoder, false) < 0)
        goto fail_render_frame;
    wgpuSurfacePresent(surface);
    wgpuCommandEncoderRelease(encoder);
    wgpuTextureViewRelease(surface_view);
    /* msaa_view / depth_view は呼び出し側が持ち回る資源なのでここでは解放しない。 */
    wgpuTextureRelease(surface_texture.texture);
    return 0;
fail_render_frame:
    if (pass) wgpuRenderPassEncoderRelease(pass);
    if (encoder) wgpuCommandEncoderRelease(encoder);
    if (surface_view) wgpuTextureViewRelease(surface_view);
    if (surface_texture.texture) wgpuTextureRelease(surface_texture.texture);
    return -1;
}

BRIDGE_API int WGPU_EncodeCopyTextureToTexture(
    WGPUCommandEncoder encoder, const WGPUBridgeTextureCopy *copy)
{
    if (!encoder || !copy || !copy->source || !copy->destination) return -1;
    WGPUTexelCopyTextureInfo source = {0};
    source.texture = (WGPUTexture)copy->source;
    source.mipLevel = copy->source_mip_level;
    source.origin.x = copy->source_x;
    source.origin.y = copy->source_y;
    source.origin.z = copy->source_z;
    WGPUTexelCopyTextureInfo destination = {0};
    destination.texture = (WGPUTexture)copy->destination;
    destination.mipLevel = copy->destination_mip_level;
    destination.origin.x = copy->destination_x;
    destination.origin.y = copy->destination_y;
    destination.origin.z = copy->destination_z;
    WGPUExtent3D size = {0};
    size.width = copy->width;
    size.height = copy->height;
    size.depthOrArrayLayers = copy->depth_or_array_layers;
    wgpuCommandEncoderCopyTextureToTexture(encoder, &source, &destination, &size);
    return 0;
}

BRIDGE_API int WGPU_EncodeCopyTextureToBuffer(
    WGPUCommandEncoder encoder, const WGPUBridgeTextureToBufferCopy *copy)
{
    if (!encoder || !copy || !copy->source || !copy->destination_buffer) return -1;
    WGPUTexelCopyTextureInfo source = {0};
    source.texture = (WGPUTexture)copy->source;
    source.mipLevel = copy->source_mip_level;
    source.origin.x = copy->source_x;
    source.origin.y = copy->source_y;
    source.origin.z = copy->source_z;
    WGPUTexelCopyBufferInfo destination = {0};
    destination.buffer = (WGPUBuffer)copy->destination_buffer;
    destination.layout.offset = copy->destination_offset;
    destination.layout.bytesPerRow = copy->destination_bytes_per_row;
    destination.layout.rowsPerImage = copy->destination_rows_per_image;
    WGPUExtent3D size = {0};
    size.width = copy->width;
    size.height = copy->height;
    size.depthOrArrayLayers = copy->depth_or_array_layers;
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &destination, &size);
    return 0;
}

BRIDGE_API int WGPU_EncodeRenderPassToView(
    WGPUCommandEncoder encoder, WGPUTextureView color_view,
    uint32_t load_op,
    double clear_r, double clear_g, double clear_b, double clear_a,
    WGPUTextureView depth_view,
    const WGPUBridgeComputeCommand *render_commands, uint32_t render_count)
{
    if (!encoder || !color_view || (!render_commands && render_count)) return -1;
    bool depth_enabled = (depth_view != NULL);
    WGPULoadOp op = (load_op == WGPU_BRIDGE_LOAD_OP_LOAD) ? WGPULoadOp_Load
                                                           : WGPULoadOp_Clear;
    WGPURenderPassColorAttachment color = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    color.view = color_view;
    color.resolveTarget = NULL;
    color.loadOp = op;
    color.storeOp = WGPUStoreOp_Store;
    color.clearValue = (WGPUColor){clear_r, clear_g, clear_b, clear_a};
    WGPURenderPassDepthStencilAttachment depth_attachment = {0};
    if (depth_enabled) {
        depth_attachment.view = depth_view;
        depth_attachment.depthLoadOp = op;
        depth_attachment.depthStoreOp = WGPUStoreOp_Store;
        depth_attachment.depthClearValue = 1.0f;
        depth_attachment.depthReadOnly = false;
        depth_attachment.stencilLoadOp = WGPULoadOp_Undefined;
        depth_attachment.stencilStoreOp = WGPUStoreOp_Undefined;
        depth_attachment.stencilReadOnly = true;
    }
    WGPURenderPassDescriptor descriptor = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    descriptor.colorAttachmentCount = 1;
    descriptor.colorAttachments = &color;
    descriptor.depthStencilAttachment = depth_enabled ? &depth_attachment : NULL;
    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(encoder, &descriptor);
    if (!pass) return -1;
    if (WGPU_EncodeRenderCommands(pass, render_commands, render_count) < 0) {
        wgpuRenderPassEncoderRelease(pass);
        return -1;
    }
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    return 0;
}

BRIDGE_API int WGPU_EncodeWriteTexture(
    WGPUQueue queue, WGPUTexture texture,
    uint32_t mip_level, uint32_t origin_x, uint32_t origin_y, uint32_t origin_z,
    const void *data, uint64_t data_size,
    uint32_t bytes_per_row, uint32_t rows_per_image,
    uint32_t width, uint32_t height, uint32_t depth_or_array_layers)
{
    if (!queue || !texture || !data || !data_size || !width || !height ||
        !depth_or_array_layers) return -1;
    WGPUTexelCopyTextureInfo destination = {0};
    destination.texture = texture;
    destination.mipLevel = mip_level;
    destination.origin.x = origin_x;
    destination.origin.y = origin_y;
    destination.origin.z = origin_z;
    WGPUTexelCopyBufferLayout layout = {0};
    layout.offset = 0;
    layout.bytesPerRow = bytes_per_row;
    layout.rowsPerImage = rows_per_image;
    WGPUExtent3D size = {0};
    size.width = width;
    size.height = height;
    size.depthOrArrayLayers = depth_or_array_layers;
    wgpuQueueWriteTexture(queue, &destination, data, (size_t)data_size, &layout, &size);
    return 0;
}

BRIDGE_API int WGPU_SubmitEncoder(
    WGPUDevice device, WGPUQueue queue, WGPUCommandEncoder encoder, uint32_t wait)
{
    if (!device || !queue || !encoder) return -1;
    int result = submit_encoder(device, queue, encoder, wait != 0);
    wgpuCommandEncoderRelease(encoder);
    return result;
}
/* -------------------- 4. 結果の読み戻し -------------------- */
typedef struct { BridgeAtomicBool done; WGPUMapAsyncStatus status; } MapRequest;
static void map_callback(WGPUMapAsyncStatus status, WGPUStringView message,
                         void *userdata1, void *userdata2)
{
    /* GPUバッファをCPUから読める状態へする非同期処理の完了通知。 */
    MapRequest *request = userdata1;
    (void)message; (void)userdata2;
    request->status = status;
    atomic_store_flag(&request->done, true);
}
BRIDGE_API int WGPU_ReadBuffer(WGPUInstance instance, WGPUDevice device, WGPUBuffer staging,
                               uint64_t offset, uint64_t size, void *out_bytes)
{
    
    if (!instance || !device || !staging || !size || !out_bytes) return -1;
    MapRequest request = {0};
    WGPUBufferMapCallbackInfo info = {
        .mode = WGPUCallbackMode_AllowSpontaneous,
        .callback = map_callback, .userdata1 = &request
    };
    wgpuBufferMapAsync(staging, WGPUMapMode_Read, offset, size, info);
    while (!atomic_load_flag(&request.done)) {
        
        wgpuDeviceTick(device);
        wgpuInstanceProcessEvents(instance);
        bridge_sleep_one_ms();
    }
    if (request.status != WGPUMapAsyncStatus_Success) return -1;
    const void *mapped = wgpuBufferGetConstMappedRange(staging, offset, size);
    if (!mapped) return -1;
    memcpy(out_bytes, mapped, (size_t)size);
    wgpuBufferUnmap(staging);
    return 0;
}


typedef struct {
    BridgeAtomicBool done;
    WGPUCompilationInfoRequestStatus status;
    char *out_buffer;
    uint32_t out_buffer_size;
    uint32_t written;
    
    const char *shader_name;
} CompilationInfoRequest;

static const char *compilation_message_type_name(WGPUCompilationMessageType type)
{
    switch (type) {
    case WGPUCompilationMessageType_Error:   return "error";
    case WGPUCompilationMessageType_Warning: return "warning";
    case WGPUCompilationMessageType_Info:    return "info";
    default:                                return "unknown";
    }
}

static void compilation_info_callback(WGPUCompilationInfoRequestStatus status,
                                       WGPUCompilationInfo const *compilation_info,
                                       void *userdata1, void *userdata2)
{
    /* シェーダーのコンパイルが終わったときにwgpu-nativeから呼ばれる。
       メッセージを1件ずつ、人が読めるテキスト1行に整形してバッファへ足す。 */
    CompilationInfoRequest *request = userdata1;
    (void)userdata2;
    request->status = status;
    uint32_t pos = 0;
    if (compilation_info) {
        for (size_t i = 0; i < compilation_info->messageCount; i++) {
            const WGPUCompilationMessage *message = &compilation_info->messages[i];
            uint32_t remaining =
                (pos < request->out_buffer_size) ? (request->out_buffer_size - pos) : 0;
            
            int written = snprintf(
                request->out_buffer + pos, remaining,
                "%s:%llu:%llu: [%s] %.*s\n",
                request->shader_name ? request->shader_name : "shader",
                (unsigned long long)message->lineNum,
                (unsigned long long)message->linePos,
                compilation_message_type_name(message->type),
                (int)message->message.length,
                message->message.data ? message->message.data : "");
            if (written < 0) break;
            pos += (uint32_t)written;
            if (pos >= request->out_buffer_size) {
                /* バッファが尽きた。ここで安全に打ち切る。 */
                pos = request->out_buffer_size > 0 ? request->out_buffer_size - 1 : 0;
                break;
            }
        }
    }
    if (request->out_buffer_size > 0) {
        request->out_buffer[pos] = '\0';
    }
    request->written = pos;
    atomic_store_flag(&request->done, true);
}

BRIDGE_API int WGPU_GetShaderCompilationMessages(
    WGPUInstance instance, WGPUDevice device, WGPUShaderModule module,
    const char *shader_name,
    char *out_buffer, uint32_t out_buffer_size)
{
    
    if (!instance || !device || !module || !out_buffer || !out_buffer_size) return -1;
    CompilationInfoRequest request = {0};
    request.out_buffer = out_buffer;
    request.out_buffer_size = out_buffer_size;
    request.shader_name = shader_name;
    WGPUCompilationInfoCallbackInfo info = {0};
    info.mode = WGPUCallbackMode_AllowSpontaneous;
    info.callback = compilation_info_callback;
    info.userdata1 = &request;
    wgpuShaderModuleGetCompilationInfo(module, info);
    while (!atomic_load_flag(&request.done)) {
        
        wgpuDeviceTick(device);
        wgpuInstanceProcessEvents(instance);
        bridge_sleep_one_ms();
    }
    if (request.status != WGPUCompilationInfoRequestStatus_Success) return -1;
    return (int)request.written;
}

