#include "CoreSetHostedHitOwnership.h"

#include <cassert>
#include <limits>

using coreset_hosted_hit::Bounds;
using coreset_hosted_hit::Owner;
using coreset_hosted_hit::ownerAtPoint;

int main() {
    const Bounds floating{900, 190, 952, 242, true};
    const Bounds panel{146, 8, 810, 432, true};
    const Bounds disabledFloating{900, 190, 952, 242, false};
    const Bounds overlappingPanel{880, 160, 955, 260, true};
    const Bounds disabledPanel{146, 8, 810, 432, false};

    assert(ownerAtPoint(floating, panel, 300, 200) == Owner::Panel);
    assert(ownerAtPoint(floating, panel, 926, 220) == Owner::Floating);
    assert(ownerAtPoint(floating, panel, 20, 20) == Owner::None);
    assert(ownerAtPoint(floating, overlappingPanel, 926, 220) == Owner::Floating);
    assert(ownerAtPoint(disabledFloating, overlappingPanel, 926, 220) == Owner::Panel);
    assert(ownerAtPoint(floating, disabledPanel, 300, 200) == Owner::None);
    assert(ownerAtPoint(floating, panel, 900, 190) == Owner::Floating);
    assert(ownerAtPoint(floating, panel,
                        std::numeric_limits<double>::quiet_NaN(), 220) == Owner::None);
    return 0;
}
