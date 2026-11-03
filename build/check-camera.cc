// Run as guest root after building; exercises Camera2 and the real YUV buffer path.
#include <camera/NdkCameraManager.h>
#include <media/NdkImageReader.h>
#include <android/binder_process.h>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>

struct Frames {
    std::mutex mutex;
    std::condition_variable changed;
    int count = 0;
    bool varied = false;
    bool jpeg = false;
};

void onImage(void* context, AImageReader* reader) {
    AImage* image = nullptr;
    if (AImageReader_acquireLatestImage(reader, &image) != AMEDIA_OK) return;
    uint8_t* data = nullptr;
    int length = 0, stride = 0, width = 0, height = 0;
    auto& frames = *static_cast<Frames*>(context);
    assert(AImage_getPlaneData(image, 0, &data, &length) == AMEDIA_OK);
    int minimum = 255, maximum = 0;
    if (frames.jpeg) {
        assert(length > 4 && data[0] == 0xff && data[1] == 0xd8);
        assert(data[length - 2] == 0xff && data[length - 1] == 0xd9);
        minimum = 0;
        maximum = 255;
        std::fprintf(stderr, "JPEG bytes: %d\n", length);
    } else {
        assert(AImage_getPlaneRowStride(image, 0, &stride) == AMEDIA_OK);
        assert(AImage_getWidth(image, &width) == AMEDIA_OK);
        assert(AImage_getHeight(image, &height) == AMEDIA_OK);
        for (int y = 0; y < height; y += 16) {
            for (int x = 0; x < width; x += 16) {
                int index = y * stride + x;
                assert(index < length);
                minimum = std::min(minimum, int(data[index]));
                maximum = std::max(maximum, int(data[index]));
            }
        }
    }
    AImage_delete(image);
    std::lock_guard<std::mutex> lock(frames.mutex);
    if (frames.count == 0 && !frames.jpeg) std::fprintf(stderr, "YUV luma range: %d..%d\n", minimum, maximum);
    ++frames.count;
    frames.varied |= maximum - minimum > 32;
    frames.changed.notify_one();
}

int main(int argc, char** argv) {
    assert(argc == 1 || (argc == 2 && std::strcmp(argv[1], "jpeg") == 0));
    const bool jpeg = argc == 2;
    ABinderProcess_startThreadPool();
    ACameraManager* manager = ACameraManager_create();
    assert(manager);
    ACameraIdList* ids = nullptr;
    assert(ACameraManager_getCameraIdList(manager, &ids) == ACAMERA_OK);
    assert(ids && ids->numCameras == 1);
    ACameraDevice* device = nullptr;
    ACameraDevice_StateCallbacks deviceCallbacks{};
    deviceCallbacks.onDisconnected = [](void*, ACameraDevice*) { assert(false && "camera disconnected"); };
    deviceCallbacks.onError = [](void*, ACameraDevice*, int) { assert(false && "camera device error"); };
    assert(ACameraManager_openCamera(manager, ids->cameraIds[0], &deviceCallbacks, &device) == ACAMERA_OK);

    Frames frames;
    frames.jpeg = jpeg;
    AImageReader* reader = nullptr;
    assert(AImageReader_new(jpeg ? 1920 : 640, jpeg ? 1080 : 480,
                           jpeg ? AIMAGE_FORMAT_JPEG : AIMAGE_FORMAT_YUV_420_888, 4, &reader) == AMEDIA_OK);
    AImageReader_ImageListener listener{&frames, onImage};
    assert(AImageReader_setImageListener(reader, &listener) == AMEDIA_OK);
    ANativeWindow* window = nullptr;
    assert(AImageReader_getWindow(reader, &window) == AMEDIA_OK);
    ACaptureSessionOutputContainer* outputs = nullptr;
    ACaptureSessionOutput* output = nullptr;
    ACameraOutputTarget* target = nullptr;
    assert(ACaptureSessionOutputContainer_create(&outputs) == ACAMERA_OK);
    assert(ACaptureSessionOutput_create(window, &output) == ACAMERA_OK);
    assert(ACaptureSessionOutputContainer_add(outputs, output) == ACAMERA_OK);
    assert(ACameraOutputTarget_create(window, &target) == ACAMERA_OK);
    ACaptureRequest* request = nullptr;
    assert(ACameraDevice_createCaptureRequest(device, jpeg ? TEMPLATE_STILL_CAPTURE : TEMPLATE_PREVIEW,
                                            &request) == ACAMERA_OK);
    assert(ACaptureRequest_addTarget(request, target) == ACAMERA_OK);
    ACameraCaptureSession_stateCallbacks sessionCallbacks{};
    sessionCallbacks.onClosed = [](void*, ACameraCaptureSession*) {};
    sessionCallbacks.onReady = [](void*, ACameraCaptureSession*) {};
    sessionCallbacks.onActive = [](void*, ACameraCaptureSession*) {};
    ACameraCaptureSession* session = nullptr;
    assert(ACameraDevice_createCaptureSession(device, outputs, &sessionCallbacks, &session) == ACAMERA_OK);
    if (jpeg) assert(ACameraCaptureSession_capture(session, nullptr, 1, &request, nullptr) == ACAMERA_OK);
    else assert(ACameraCaptureSession_setRepeatingRequest(session, nullptr, 1, &request, nullptr) == ACAMERA_OK);
    {
        std::unique_lock<std::mutex> lock(frames.mutex);
        bool ready = frames.changed.wait_for(lock, std::chrono::seconds(10),
                                            [&] { return frames.count >= (jpeg ? 1 : 3) && frames.varied; });
        std::fprintf(stderr, "Frames: %d, varied: %d\n", frames.count, frames.varied);
        assert(ready);
    }
    if (!jpeg) assert(ACameraCaptureSession_stopRepeating(session) == ACAMERA_OK);
    ACameraCaptureSession_close(session);
    assert(ACameraDevice_close(device) == ACAMERA_OK);
    ACaptureRequest_free(request);
    ACameraOutputTarget_free(target);
    ACaptureSessionOutput_free(output);
    ACaptureSessionOutputContainer_free(outputs);
    AImageReader_delete(reader);
    ACameraManager_deleteCameraIdList(ids);
    ACameraManager_delete(manager);
    std::puts(jpeg ? "Camera2 JPEG and shutdown: ok" : "Camera2 YUV frames and shutdown: ok");
}
