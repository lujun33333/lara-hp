#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>

namespace CoreSet {
struct Vec3 { float x, y, z; };
struct Camera { Vec3 location; float pad0[3]; Vec3 rotation; float pad1[3]; float fov; };
struct Point { double x, y; };
struct Transform {
    float rotation[4];
    Vec3 translation;
    float pad0;
    Vec3 scale;
    float pad1;
};
static_assert(sizeof(Camera) == 0x34, "MinimalViewInfo prefix size");
static_assert(sizeof(Transform) == 0x30, "FTransform prefix size");

inline bool transformPoint(const Transform &component, Vec3 local, Vec3 *world) {
    if (!world) return false;
    const float *q = component.rotation;
    double norm = (double)q[0] * q[0] + (double)q[1] * q[1] +
                  (double)q[2] * q[2] + (double)q[3] * q[3];
    if (!std::isfinite(norm) || norm < 0.5 || norm > 1.5) return false;
    const double x = local.x * component.scale.x;
    const double y = local.y * component.scale.y;
    const double z = local.z * component.scale.z;
    const double tx = 2.0 * ((double)q[1] * z - (double)q[2] * y);
    const double ty = 2.0 * ((double)q[2] * x - (double)q[0] * z);
    const double tz = 2.0 * ((double)q[0] * y - (double)q[1] * x);
    const double wx = x + q[3] * tx + ((double)q[1] * tz - (double)q[2] * ty) + component.translation.x;
    const double wy = y + q[3] * ty + ((double)q[2] * tx - (double)q[0] * tz) + component.translation.y;
    const double wz = z + q[3] * tz + ((double)q[0] * ty - (double)q[1] * tx) + component.translation.z;
    if (!std::isfinite(wx) || !std::isfinite(wy) || !std::isfinite(wz) ||
        std::fabs(wx) > 1.0e9 || std::fabs(wy) > 1.0e9 || std::fabs(wz) > 1.0e9) return false;
    *world = {(float)wx, (float)wy, (float)wz};
    return true;
}

inline void decodePositionBlock(uint8_t (&block)[0x30], uint32_t key) {
    for (size_t index = 0; index < sizeof(block); index += sizeof(uint32_t)) {
        uint32_t word = 0;
        std::memcpy(&word, block + index, sizeof(word));
        word ^= key;
        std::memcpy(block + index, &word, sizeof(word));
    }
}

inline bool project(const Camera &camera, Vec3 point,
                    double width, double height, Point *screen) {
    if (!screen || !std::isfinite(width) || !std::isfinite(height) ||
        width <= 0 || height <= 0 || !std::isfinite(camera.fov) ||
        camera.fov <= 1 || camera.fov >= 170) return false;
    constexpr double degrees = 0.017453292519943295;
    double pitch = camera.rotation.x * degrees;
    double yaw = camera.rotation.y * degrees;
    double roll = camera.rotation.z * degrees;
    double sp = std::sin(pitch), cp = std::cos(pitch);
    double sy = std::sin(yaw), cy = std::cos(yaw);
    double sr = std::sin(roll), cr = std::cos(roll);
    double dx = point.x - camera.location.x;
    double dy = point.y - camera.location.y;
    double dz = point.z - camera.location.z;
    double depth = dx * cp * cy + dy * cp * sy + dz * sp;
    if (!std::isfinite(depth) || depth <= 1) return false;
    double right = dx * (sr * sp * cy - cr * sy) +
                   dy * (sr * sp * sy + cr * cy) - dz * sr * cp;
    double up = dx * (sr * sy - cr * sp * cy) +
                dy * (sr * cy - cr * sp * sy) + dz * cr * cp;
    double focal = (width / 2.0) / std::tan(camera.fov * degrees / 2.0);
    double x = width / 2.0 + focal * right / depth;
    double y = height / 2.0 - focal * up / depth;
    if (!std::isfinite(x) || !std::isfinite(y)) return false;
    *screen = {x, y};
    return true;
}

// Core's off-screen branch clamps negative/near depth to one instead of
// discarding it, then intersects the resulting direction with the canvas edge.
inline bool projectForIndicator(const Camera &camera, Vec3 point,
                                double width, double height, Point *screen) {
    if (!screen || !std::isfinite(width) || !std::isfinite(height) ||
        width <= 0 || height <= 0 || !std::isfinite(camera.fov) ||
        camera.fov <= 1 || camera.fov >= 170) return false;
    constexpr double degrees = 0.017453292519943295;
    const double pitch = camera.rotation.x * degrees, yaw = camera.rotation.y * degrees;
    const double roll = camera.rotation.z * degrees;
    const double sp = std::sin(pitch), cp = std::cos(pitch);
    const double sy = std::sin(yaw), cy = std::cos(yaw);
    const double sr = std::sin(roll), cr = std::cos(roll);
    const double dx = point.x - camera.location.x;
    const double dy = point.y - camera.location.y;
    const double dz = point.z - camera.location.z;
    const double depth = dx * cp * cy + dy * cp * sy + dz * sp;
    const double right = dx * (sr * sp * cy - cr * sy) +
                         dy * (sr * sp * sy + cr * cy) - dz * sr * cp;
    const double up = dx * (sr * sy - cr * sp * cy) +
                      dy * (sr * cy - cr * sp * sy) + dz * cr * cp;
    const double focal = (width / 2.0) / std::tan(camera.fov * degrees / 2.0);
    const double clampedDepth = depth < 1.0 ? 1.0 : depth;
    const double x = width / 2.0 + focal * right / clampedDepth;
    const double y = height / 2.0 - focal * up / clampedDepth;
    if (!std::isfinite(x) || !std::isfinite(y) || std::fabs(x) > 1.0e12 ||
        std::fabs(y) > 1.0e12) return false;
    *screen = {x, y};
    return true;
}

inline bool radarPoint(Point cameraMinusActor, double cameraYawDegrees,
                       double radius, double detectionDistance, Point center, Point *out) {
    if (!out || !std::isfinite(cameraMinusActor.x) || !std::isfinite(cameraMinusActor.y) ||
        !std::isfinite(cameraYawDegrees) || !std::isfinite(radius) ||
        !std::isfinite(detectionDistance) || !std::isfinite(center.x) ||
        !std::isfinite(center.y) || radius < 1 || radius > 300 ||
        detectionDistance < 1 || detectionDistance > 1000) return false;
    constexpr double degrees = 0.017453292519943295;
    const double yaw = (cameraYawDegrees - 90.0) * degrees;
    const double scale = radius / (detectionDistance * 100.0);
    const double dx = cameraMinusActor.x * scale, dy = cameraMinusActor.y * scale;
    double x = std::cos(yaw) * dx + std::sin(yaw) * dy;
    double y = std::cos(yaw) * dy - std::sin(yaw) * dx;
    const double length = std::hypot(x, y);
    if (!std::isfinite(length)) return false;
    if (length > radius && length > 0) { x *= radius / length; y *= radius / length; }
    x += center.x; y += center.y;
    if (!std::isfinite(x) || !std::isfinite(y)) return false;
    *out = {x, y};
    return true;
}
// Core layoutSubviews uses UIScreen.nativeScale to form drawable pixels;
// dc75c..dc780 starts at (pixelWidth/2,10) and ends 30*nativeScale above the
// top anchor. Convert this verified fallback geometry to our canvas points.
inline bool referencePlayerRay(double width, double height, double nativeScale,
                                Point head, Point *origin, Point *endpoint) {
    if (!origin || !endpoint) return false;
    *origin = {0, 0}; *endpoint = {0, 0};
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 ||
        !std::isfinite(nativeScale) || nativeScale <= 0 || nativeScale > 8 ||
        !std::isfinite(head.x) || !std::isfinite(head.y) ||
        head.x < 0 || head.x > width || head.y < 0 || head.y > height ||
        10.0 / nativeScale > height) return false;
    *origin = {width / 2.0, 10.0 / nativeScale};
    *endpoint = {head.x, head.y - 30.0};
    return true;
}

} // namespace CoreSet
