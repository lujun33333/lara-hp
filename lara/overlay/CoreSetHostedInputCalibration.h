#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

// Pure C++ calibration for a raw digitizer point paired with a real foreground
// UITouch point. The caller owns event parsing, clock conversion, and conversion
// of the UITouch location into the screen's fixed portrait coordinate space.
namespace CoreSetHostedInputCalibration {

enum class Phase { Began, Moved, Ended, Cancelled };

struct SurfaceIdentity {
    double width;
    double height;
    // The host must advance this for device, screen, or session changes, even
    // when width and height happen to remain equal.
    std::uint64_t generation;
};

struct RawContact {
    std::uint32_t index;
    Phase phase;
    double timestampSeconds;
    double x;
    double y;
    std::uint32_t activeCount;
};

struct PairedSample {
    RawContact raw;
    double touchTimestampSeconds;
    Phase touchPhase;
    double fixedX;
    double fixedY;
};

inline bool validSurface(SurfaceIdentity identity) {
    return std::isfinite(identity.width) && std::isfinite(identity.height) &&
           identity.width > 0.0 && identity.height > 0.0 &&
           identity.width <= 10000.0 && identity.height <= 10000.0 &&
           identity.generation != 0;
}

inline bool sameSurface(SurfaceIdentity left, SurfaceIdentity right) {
    return left.width == right.width && left.height == right.height &&
           left.generation == right.generation;
}

inline bool finitePair(const PairedSample &sample) {
    return std::isfinite(sample.raw.timestampSeconds) &&
           std::isfinite(sample.touchTimestampSeconds) &&
           std::isfinite(sample.raw.x) && std::isfinite(sample.raw.y) &&
           std::isfinite(sample.fixedX) && std::isfinite(sample.fixedY) &&
           sample.raw.timestampSeconds >= 0.0 &&
           sample.touchTimestampSeconds >= 0.0;
}

class PairRecorder {
public:
    explicit PairRecorder(double maxSkewSeconds = 0.04,
                          double maxGapSeconds = 1.0)
        : maxSkew_(maxSkewSeconds), maxGap_(maxGapSeconds) {}

    bool add(const PairedSample &sample) {
        if (!std::isfinite(maxSkew_) || !std::isfinite(maxGap_) ||
            maxSkew_ <= 0.0 || maxGap_ <= 0.0 || !finitePair(sample) ||
            std::fabs(sample.raw.timestampSeconds - sample.touchTimestampSeconds) > maxSkew_ ||
            sample.raw.phase != sample.touchPhase ||
            sample.raw.activeCount > 1 || sample.raw.phase == Phase::Cancelled ||
            (havePrevious_ && (sample.raw.timestampSeconds <= previousRawTime_ ||
                              sample.touchTimestampSeconds <= previousTouchTime_))) {
            reset();
            return false;
        }

        if (sample.raw.phase == Phase::Began) {
            if (active_ || sample.raw.activeCount != 1) {
                reset();
                return false;
            }
            active_ = true;
            activeIndex_ = sample.raw.index;
        } else if (sample.raw.phase == Phase::Moved || sample.raw.phase == Phase::Ended) {
            if (!active_ || sample.raw.index != activeIndex_ ||
                (sample.raw.phase == Phase::Moved && sample.raw.activeCount != 1) ||
                sample.raw.timestampSeconds - previousRawTime_ > maxGap_) {
                reset();
                return false;
            }
        } else {
            reset();
            return false;
        }

        if (sample.raw.phase == Phase::Began || sample.raw.phase == Phase::Moved) {
            if (samples_.size() >= 256) {
                reset();
                return false;
            }
            samples_.push_back(sample);
        }
        if (sample.raw.phase == Phase::Ended) active_ = false;
        previousRawTime_ = sample.raw.timestampSeconds;
        previousTouchTime_ = sample.touchTimestampSeconds;
        havePrevious_ = true;
        return true;
    }

    const std::vector<PairedSample> &samples() const { return samples_; }

    void reset() {
        samples_.clear();
        active_ = false;
        havePrevious_ = false;
        activeIndex_ = 0;
        previousRawTime_ = 0.0;
        previousTouchTime_ = 0.0;
    }

private:
    double maxSkew_;
    double maxGap_;
    std::vector<PairedSample> samples_;
    bool active_ = false;
    bool havePrevious_ = false;
    std::uint32_t activeIndex_ = 0;
    double previousRawTime_ = 0.0;
    double previousTouchTime_ = 0.0;
};

// Solve a 3x3 system with partial pivoting. Inputs are normalized before this
// call, so the absolute pivot floor is meaningful for both point and 0..1 raw
// coordinate sources.
inline bool solve3x3(const double matrix[3][3], const double rhs[3], double out[3]) {
    double rows[3][4] = {};
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) rows[row][column] = matrix[row][column];
        rows[row][3] = rhs[row];
    }
    for (int column = 0; column < 3; ++column) {
        int pivot = column;
        for (int row = column + 1; row < 3; ++row) {
            if (std::fabs(rows[row][column]) > std::fabs(rows[pivot][column])) pivot = row;
        }
        if (std::fabs(rows[pivot][column]) < 1e-10) return false;
        if (pivot != column) {
            for (int item = column; item < 4; ++item) {
                const double value = rows[column][item];
                rows[column][item] = rows[pivot][item];
                rows[pivot][item] = value;
            }
        }
        const double divisor = rows[column][column];
        for (int item = column; item < 4; ++item) rows[column][item] /= divisor;
        for (int row = 0; row < 3; ++row) {
            if (row == column) continue;
            const double factor = rows[row][column];
            for (int item = column; item < 4; ++item) rows[row][item] -= factor * rows[column][item];
        }
    }
    for (int row = 0; row < 3; ++row) {
        out[row] = rows[row][3];
        if (!std::isfinite(out[row])) return false;
    }
    return true;
}

class AffineCalibration {
public:
    bool fit(const std::vector<PairedSample> &training,
             const std::vector<PairedSample> &heldout,
             SurfaceIdentity identity) {
        reset();
        if (!validSurface(identity) || training.size() < 3 || heldout.size() < 4 ||
            training.size() > 256 || heldout.size() > 256) return false;

        double meanX = 0.0, meanY = 0.0;
        for (const auto &sample : training) {
            if (!validPoint(sample, identity)) return false;
            meanX += sample.raw.x;
            meanY += sample.raw.y;
        }
        meanX /= static_cast<double>(training.size());
        meanY /= static_cast<double>(training.size());
        if (!std::isfinite(meanX) || !std::isfinite(meanY)) return false;

        double xx = 0.0, xy = 0.0, yy = 0.0;
        for (const auto &sample : training) {
            const double dx = sample.raw.x - meanX;
            const double dy = sample.raw.y - meanY;
            xx += dx * dx;
            xy += dx * dy;
            yy += dy * dy;
        }
        const double trace = xx + yy;
        const double discriminant = std::hypot(xx - yy, 2.0 * xy);
        const double lambdaMax = (trace + discriminant) * 0.5;
        const double lambdaMin = (trace - discriminant) * 0.5;
        if (!std::isfinite(lambdaMax) || !std::isfinite(lambdaMin) ||
            lambdaMax <= 0.0 || lambdaMin / lambdaMax < 1e-4) return false;
        const double scale = std::sqrt(trace / static_cast<double>(training.size()));
        if (!std::isfinite(scale) || scale <= 0.0) return false;

        double matrix[3][3] = {};
        double xRhs[3] = {}, yRhs[3] = {};
        for (const auto &sample : training) {
            const double basis[3] = {1.0, (sample.raw.x - meanX) / scale,
                                     (sample.raw.y - meanY) / scale};
            for (int row = 0; row < 3; ++row) {
                xRhs[row] += basis[row] * sample.fixedX;
                yRhs[row] += basis[row] * sample.fixedY;
                for (int column = 0; column < 3; ++column)
                    matrix[row][column] += basis[row] * basis[column];
            }
        }
        double ax[3] = {}, ay[3] = {};
        if (!solve3x3(matrix, xRhs, ax) || !solve3x3(matrix, yRhs, ay)) return false;

        bool edgeLeft = false, edgeRight = false, edgeTop = false, edgeBottom = false;
        double trainSquaredError = 0.0, holdSquaredError = 0.0;
        for (const auto &sample : training) {
            const double error = residual(sample, meanX, meanY, scale, ax, ay);
            if (!std::isfinite(error) || error > 6.0) return false;
            trainSquaredError += error * error;
        }
        if (std::sqrt(trainSquaredError / training.size()) > 4.0) return false;

        for (std::size_t heldoutIndex = 0; heldoutIndex < heldout.size(); ++heldoutIndex) {
            const auto &sample = heldout[heldoutIndex];
            if (!validPoint(sample, identity)) return false;
            for (const auto &known : training) {
                // A held-out sample must be a separate physical observation.
                if (sample.raw.index == known.raw.index &&
                    std::fabs(sample.raw.timestampSeconds - known.raw.timestampSeconds) < 1e-6)
                    return false;
            }
            for (std::size_t earlier = 0; earlier < heldoutIndex; ++earlier) {
                const auto &known = heldout[earlier];
                if (sample.raw.index == known.raw.index &&
                    std::fabs(sample.raw.timestampSeconds - known.raw.timestampSeconds) < 1e-6)
                    return false;
            }
            edgeLeft |= sample.fixedX <= identity.width * 0.15;
            edgeRight |= sample.fixedX >= identity.width * 0.85;
            edgeTop |= sample.fixedY <= identity.height * 0.15;
            edgeBottom |= sample.fixedY >= identity.height * 0.85;
            const double error = residual(sample, meanX, meanY, scale, ax, ay);
            if (!std::isfinite(error) || error > 8.0) return false;
            holdSquaredError += error * error;
        }
        if (!edgeLeft || !edgeRight || !edgeTop || !edgeBottom ||
            std::sqrt(holdSquaredError / heldout.size()) > 5.0) return false;

        identity_ = identity;
        meanX_ = meanX;
        meanY_ = meanY;
        scale_ = scale;
        for (int component = 0; component < 3; ++component) {
            ax_[component] = ax[component];
            ay_[component] = ay[component];
        }
        fitted_ = true;
        return true;
    }

    bool map(double rawX, double rawY, SurfaceIdentity identity,
             double *fixedX, double *fixedY) const {
        if (!fixedX || !fixedY || fixedX == fixedY || !valid(identity) ||
            !std::isfinite(rawX) || !std::isfinite(rawY)) return false;
        const double nx = (rawX - meanX_) / scale_;
        const double ny = (rawY - meanY_) / scale_;
        const double x = ax_[0] + ax_[1] * nx + ax_[2] * ny;
        const double y = ay_[0] + ay_[1] * nx + ay_[2] * ny;
        if (!std::isfinite(x) || !std::isfinite(y) ||
            x < 0.0 || x >= identity.width || y < 0.0 || y >= identity.height)
            return false;
        *fixedX = x;
        *fixedY = y;
        return true;
    }

    bool valid(SurfaceIdentity identity) const {
        return fitted_ && validSurface(identity) && sameSurface(identity_, identity);
    }

    void reset() {
        fitted_ = false;
        identity_ = {0.0, 0.0, 0};
        meanX_ = meanY_ = 0.0;
        scale_ = 0.0;
        for (int component = 0; component < 3; ++component) ax_[component] = ay_[component] = 0.0;
    }

private:
    static bool validPoint(const PairedSample &sample, SurfaceIdentity identity) {
        return finitePair(sample) && sample.raw.activeCount == 1 &&
               sample.raw.phase == sample.touchPhase &&
               std::fabs(sample.raw.timestampSeconds - sample.touchTimestampSeconds) <= 0.04 &&
               (sample.raw.phase == Phase::Began || sample.raw.phase == Phase::Moved) &&
               sample.fixedX >= 0.0 && sample.fixedX < identity.width &&
               sample.fixedY >= 0.0 && sample.fixedY < identity.height;
    }

    static double residual(const PairedSample &sample, double meanX, double meanY,
                           double scale, const double ax[3], const double ay[3]) {
        const double nx = (sample.raw.x - meanX) / scale;
        const double ny = (sample.raw.y - meanY) / scale;
        const double x = ax[0] + ax[1] * nx + ax[2] * ny;
        const double y = ay[0] + ay[1] * nx + ay[2] * ny;
        return std::hypot(x - sample.fixedX, y - sample.fixedY);
    }

    bool fitted_ = false;
    SurfaceIdentity identity_ = {0.0, 0.0, 0};
    double meanX_ = 0.0, meanY_ = 0.0, scale_ = 0.0;
    double ax_[3] = {}, ay_[3] = {};
};

} // namespace CoreSetHostedInputCalibration
