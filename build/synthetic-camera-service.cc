#include <cerrno>
#include <memory>
#include <android-base/properties.h>
#include <android/hardware/camera/provider/2.4/ICameraProvider.h>
#include <hidl/HidlTransportSupport.h>
#include <log/log.h>
#include <ui/GraphicBufferMapper.h>
#include "EmulatedFakeCamera3.h"
#include "CameraDevice_3_2.h"

using namespace android;
using namespace android::hardware;
using namespace android::hardware::camera;
using CameraStatus = common::V1_0::Status;
using common::V1_0::helper::CameraModule;
using provider::V2_4::ICameraProvider;
using provider::V2_4::ICameraProviderCallback;

camera_module_t module{};
std::unique_ptr<EmulatedFakeCamera3> synthetic;

struct Provider : ICameraProvider {
    sp<device::V3_2::implementation::CameraDevice> cameraDevice;

    explicit Provider(sp<CameraModule> m) {
        if (!m) return;
        SortedVector<std::pair<std::string, std::string>> names;
        names.add({"0", "device@3.2/legacy/0"});
        cameraDevice = new device::V3_2::implementation::CameraDevice(m, "0", names);
    }
    Return<CameraStatus> setCallback(const sp<ICameraProviderCallback>& cb) override {
        if (!cb) return CameraStatus::ILLEGAL_ARGUMENT;
        if (!cameraDevice) return CameraStatus::OK;
        auto result = cb->torchModeStatusChange("device@3.2/legacy/0", common::V1_0::TorchModeStatus::NOT_AVAILABLE);
        return result.isOk() ? CameraStatus::OK : CameraStatus::INTERNAL_ERROR;
    }
    Return<void> getVendorTags(getVendorTags_cb cb) override { cb(CameraStatus::OK, {}); return Void(); }
    Return<void> getCameraIdList(getCameraIdList_cb cb) override {
        if (cameraDevice) cb(CameraStatus::OK, {"device@3.2/legacy/0"});
        else cb(CameraStatus::OK, {});
        return Void();
    }
    Return<void> isSetTorchModeSupported(isSetTorchModeSupported_cb cb) override {
        cb(CameraStatus::OK, false); return Void();
    }
    Return<void> getCameraDeviceInterface_V1_x(const hidl_string&, getCameraDeviceInterface_V1_x_cb cb) override {
        cb(CameraStatus::OPERATION_NOT_SUPPORTED, nullptr); return Void();
    }
    Return<void> getCameraDeviceInterface_V3_x(const hidl_string& name, getCameraDeviceInterface_V3_x_cb cb) override {
        if (!cameraDevice || name != "device@3.2/legacy/0") cb(CameraStatus::ILLEGAL_ARGUMENT, nullptr);
        else if (cameraDevice->isInitFailed()) cb(CameraStatus::INTERNAL_ERROR, nullptr);
        else cb(CameraStatus::OK, cameraDevice->getInterface());
        return Void();
    }
};

int main() {
    hw_module_methods_t methods{};
    methods.open = [](const hw_module_t*, const char* name, hw_device_t** out) -> int {
        if (!out) return -EINVAL;
        *out = nullptr;
        if (!name || std::string(name) != "0") return -EINVAL;
        return synthetic->connectCamera(out);
    };
    module.common.tag = HARDWARE_MODULE_TAG;
    module.common.module_api_version = CAMERA_MODULE_API_VERSION_2_4;
    module.common.hal_api_version = HARDWARE_HAL_API_VERSION;
    module.common.id = CAMERA_HARDWARE_MODULE_ID;
    module.common.name = "Redroid synthetic camera";
    module.common.author = "AOSP";
    module.common.methods = &methods;
    module.get_number_of_cameras = []() { return 1; };
    module.get_camera_info = [](int id, camera_info* info) -> int {
        if (id != 0 || !info) return -EINVAL;
        *info = {};
        int result = synthetic->getCameraInfo(info);
        info->resource_cost = 50;
        return result;
    };
    module.set_callbacks = [](const camera_module_callbacks_t*) { return 0; };
    sp<CameraModule> cameraModule;
    if (base::GetBoolProperty("ro.redroid.camera", false)) {
        synthetic = std::make_unique<EmulatedFakeCamera3>(0, true, &module.common, &GraphicBufferMapper::get());
        if (synthetic->Initialize() != OK) return 1;
        cameraModule = new CameraModule(&module);
        if (cameraModule->init() != OK) return 1;
    }
    configureRpcThreadpool(4, true);
    sp<Provider> provider = new Provider(cameraModule);
    if (provider->registerAsService("legacy/0") != OK) return 1;
    ALOGI("Redroid synthetic camera ready");
    joinRpcThreadpool();
    return 1;
}
