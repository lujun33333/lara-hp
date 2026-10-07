#include "../lara/overlay/CoreSetHostedInputCalibration.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

using namespace CoreSetHostedInputCalibration;

#define CHECK(expression) do { \
    if (!(expression)) { \
        std::fprintf(stderr, "calibration test failed at line %d: %s\n", __LINE__, #expression); \
        std::exit(1); \
    } \
} while (false)

static PairedSample point(double rawX, double rawY, double fixedX, double fixedY,
                          double time, std::uint32_t index = 1,
                          Phase phase = Phase::Began,
                          std::uint32_t activeCount = 1) {
    return {{index, phase, time, rawX, rawY, activeCount},
            time + 0.005, phase, fixedX, fixedY};
}

static std::vector<PairedSample> normalizedTraining() {
    return {point(0.1, 0.1, 100, 200, 1),
            point(0.9, 0.1, 900, 200, 2),
            point(0.1, 0.9, 100, 1800, 3)};
}

static std::vector<PairedSample> normalizedHoldout() {
    return {point(0.05, 0.5, 50, 1000, 4),
            point(0.95, 0.5, 950, 1000, 5),
            point(0.5, 0.05, 500, 100, 6),
            point(0.5, 0.95, 500, 1900, 7)};
}

static void expectPoint(const AffineCalibration &calibration,
                        SurfaceIdentity identity, double rawX, double rawY,
                        double expectedX, double expectedY) {
    double x = -1, y = -1;
    CHECK(calibration.map(rawX, rawY, identity, &x, &y));
    CHECK(std::fabs(x - expectedX) < 1e-7);
    CHECK(std::fabs(y - expectedY) < 1e-7);
}

static void testNormalizedAndIdentity() {
    const SurfaceIdentity identity = {1000, 2000, 12};
    AffineCalibration calibration;
    CHECK(calibration.fit(normalizedTraining(), normalizedHoldout(), identity));
    CHECK(calibration.valid(identity));
    expectPoint(calibration, identity, 0.35, 0.42, 350, 840);
    double x = 12, y = 34;
    CHECK(!calibration.map(0.35, 0.42, {1001, 2000, 12}, &x, &y));
    CHECK(!calibration.map(0.35, 0.42, {1000, 2000, 13}, &x, &y));
    CHECK(x == 12 && y == 34);
    CHECK(!calibration.map(1.0, 0.5, identity, &x, &y));
    CHECK(!calibration.map(-0.01, 0.5, identity, &x, &y));
    CHECK(!calibration.map(0.5, 0.5, identity, nullptr, &y));
    CHECK(!calibration.map(0.5, 0.5, identity, &x, &x));
    calibration.reset();
    CHECK(!calibration.valid(identity));
}

static void testPointAndFlippedAxes() {
    const SurfaceIdentity identity = {1000, 2000, 20};
    const auto training = normalizedTraining();
    const auto heldout = normalizedHoldout();

    auto pointTraining = training;
    auto pointHoldout = heldout;
    for (auto &sample : pointTraining) {
        sample.raw.x = sample.fixedX;
        sample.raw.y = sample.fixedY;
    }
    for (auto &sample : pointHoldout) {
        sample.raw.x = sample.fixedX;
        sample.raw.y = sample.fixedY;
    }
    AffineCalibration pointCalibration;
    CHECK(pointCalibration.fit(pointTraining, pointHoldout, identity));
    expectPoint(pointCalibration, identity, 400, 700, 400, 700);

    auto flipTraining = training;
    auto flipHoldout = heldout;
    for (auto &sample : flipTraining) {
        sample.fixedX = 1000 * (1 - sample.raw.x);
        sample.fixedY = 2000 * (1 - sample.raw.y);
    }
    for (auto &sample : flipHoldout) {
        sample.fixedX = 1000 * (1 - sample.raw.x);
        sample.fixedY = 2000 * (1 - sample.raw.y);
    }
    AffineCalibration flipCalibration;
    CHECK(flipCalibration.fit(flipTraining, flipHoldout, identity));
    expectPoint(flipCalibration, identity, 0.3, 0.7, 700, 600);
}

static void testBadGeometryAndHeldout() {
    const SurfaceIdentity identity = {1000, 2000, 1};
    AffineCalibration calibration;
    auto collinear = normalizedTraining();
    collinear[2].raw.x = 0.5;
    collinear[2].raw.y = 0.1;
    CHECK(!calibration.fit(collinear, normalizedHoldout(), identity));
    CHECK(!calibration.valid(identity));

    auto nearlyCollinear = normalizedTraining();
    nearlyCollinear[2].raw.x = 0.5;
    nearlyCollinear[2].raw.y = 0.100001;
    CHECK(!calibration.fit(nearlyCollinear, normalizedHoldout(), identity));

    auto wrong = normalizedHoldout();
    wrong[0].fixedX += 30;
    CHECK(!calibration.fit(normalizedTraining(), wrong, identity));

    auto noBottom = normalizedHoldout();
    noBottom[3].fixedY = 1000;
    noBottom[3].raw.y = 0.5;
    CHECK(!calibration.fit(normalizedTraining(), noBottom, identity));

    auto reused = normalizedHoldout();
    reused[0].raw.timestampSeconds = normalizedTraining()[0].raw.timestampSeconds;
    CHECK(!calibration.fit(normalizedTraining(), reused, identity));
    reused = normalizedHoldout();
    reused[1].raw.timestampSeconds = reused[0].raw.timestampSeconds;
    CHECK(!calibration.fit(normalizedTraining(), reused, identity));

    CHECK(!calibration.fit(normalizedTraining(), normalizedHoldout(), {1000, 2000, 0}));
}

static void testNonfiniteAndBounds() {
    const SurfaceIdentity identity = {1000, 2000, 2};
    const double nan = std::numeric_limits<double>::quiet_NaN();
    auto bad = normalizedTraining();
    bad[0].raw.x = nan;
    AffineCalibration calibration;
    CHECK(!calibration.fit(bad, normalizedHoldout(), identity));
    bad = normalizedTraining();
    bad[1].fixedY = nan;
    CHECK(!calibration.fit(bad, normalizedHoldout(), identity));
    CHECK(calibration.fit(normalizedTraining(), normalizedHoldout(), identity));
    double x = 5, y = 7;
    CHECK(!calibration.map(nan, 0.4, identity, &x, &y));
    CHECK(x == 5 && y == 7);
    CHECK(!calibration.map(0.4, nan, identity, &x, &y));
    CHECK(!calibration.map(0.4, 2.0, identity, &x, &y));
}

static void testPairRecorder() {
    PairRecorder recorder;
    CHECK(recorder.add(point(0.1, 0.1, 100, 200, 1, 7)));
    CHECK(recorder.add(point(0.2, 0.2, 200, 400, 1.1, 7, Phase::Moved)));
    CHECK(recorder.add(point(0.2, 0.2, 200, 400, 1.2, 7, Phase::Ended, 0)));
    CHECK(recorder.samples().size() == 2);
    CHECK(recorder.add(point(0.3, 0.3, 300, 600, 2, 9)));
    CHECK(recorder.samples().size() == 3);
    CHECK(!recorder.add(point(0.4, 0.4, 400, 800, 2, 9, Phase::Moved)));
    CHECK(recorder.samples().empty());

    CHECK(recorder.add(point(0.1, 0.1, 100, 200, 3, 1)));
    CHECK(!recorder.add(point(0.2, 0.2, 200, 400, 3.1, 2, Phase::Moved)));
    CHECK(recorder.samples().empty());
    CHECK(recorder.add(point(0.1, 0.1, 100, 200, 4, 1)));
    CHECK(!recorder.add(point(0.2, 0.2, 200, 400, 4.1, 1, Phase::Moved, 2)));
    CHECK(recorder.samples().empty());
    CHECK(recorder.add(point(0.1, 0.1, 100, 200, 5, 1)));
    CHECK(!recorder.add(point(0.2, 0.2, 200, 400, 5.1, 1, Phase::Cancelled)));
    CHECK(recorder.samples().empty());
    auto skewed = point(0.1, 0.1, 100, 200, 6, 1);
    skewed.touchTimestampSeconds += 0.1;
    CHECK(!recorder.add(skewed));
    CHECK(recorder.samples().empty());
    auto wrongPhase = point(0.1, 0.1, 100, 200, 6.5, 1);
    wrongPhase.touchPhase = Phase::Moved;
    CHECK(!recorder.add(wrongPhase));
    CHECK(recorder.samples().empty());
    CHECK(recorder.add(point(0.1, 0.1, 100, 200, 7, 1)));
    CHECK(!recorder.add(point(0.2, 0.2, 200, 400, 8.2, 1, Phase::Moved)));
    CHECK(recorder.samples().empty());
}

int main() {
    testNormalizedAndIdentity();
    testPointAndFlippedAxes();
    testBadGeometryAndHeldout();
    testNonfiniteAndBounds();
    testPairRecorder();
    std::puts("CoreSet hosted input calibration tests passed");
    return 0;
}
