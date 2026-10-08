#include "../lara/overlay/CoreSetPlayerProjection.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using namespace CoreSet;
    Point origin = {}, endpoint = {};
    assert(referencePlayerRay(844, 390, 2, {400, 100}, &origin, &endpoint));
    assert(origin.x == 422 && origin.y == 5 && endpoint.x == 400 && endpoint.y == 70);
    assert(referencePlayerRay(844, 390, 3, {400, 100}, &origin, &endpoint));
    assert(std::fabs(origin.y - 10.0 / 3) < 1e-12 && endpoint.y == 70);
    assert(referencePlayerRay(844, 390, 2.60869565, {400, 100}, &origin, &endpoint));
    assert(std::fabs(origin.y * 2.60869565 - 10) < 1e-12);
    assert(referencePlayerRay(844, 390, 2, {400, 5}, &origin, &endpoint) && endpoint.y == -25);
    assert(!referencePlayerRay(844, 390, 0, {400, 100}, &origin, &endpoint));
    assert(origin.x == 0 && endpoint.y == 0);
    assert(!referencePlayerRay(844, 390, 9, {400, 100}, &origin, &endpoint));
    assert(!referencePlayerRay(844, 1, 2, {400, 0}, &origin, &endpoint));
    assert(!referencePlayerRay(844, 390, 2, {-1, 100}, &origin, &endpoint));
    assert(!referencePlayerRay(844, 390, 2, {400, std::numeric_limits<double>::quiet_NaN()}, &origin, &endpoint));
    assert(!referencePlayerRay(844, 390, 2, {400, 100}, nullptr, &endpoint));
    std::puts("PASS: production ray conversion, native scale, top origin, head endpoint and invalid input rejection");
}
