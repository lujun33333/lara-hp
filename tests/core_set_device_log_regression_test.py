from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[opening + 1:index]
    raise AssertionError(signature)


def test_hosted_draw_is_event_driven_and_empty_metal_frames_pause():
    lifecycle = read("lara/overlay/CoreSetHUDLifecycle.h")
    metal = read("lara/overlay/CoreSetMetalRenderAdapter.mm")
    assert "foreground && metalAvailable && !crossApplicationHosted" in lifecycle
    assert "_hasVisibleCommands = frame.commands.count > 0" in metal
    assert "_metalView.paused = !_visible || !_hasVisibleCommands" in metal
    assert "_hasVisibleCommands = NO" in body(metal, "- (void)clear")


def test_remote_call_log_storm_does_not_publish_every_low_level_line():
    logger = read("lara/classes/Logger.swift")
    utils = read("lara/kexploit/utils.m")
    append = body(logger, "private func appendtofile(")
    for noisy in ("(rc) signState:", "(rc) 返回异常:", "(pac) remotepac:"):
        assert noisy in logger
    assert "self.logs.count > 2_000" in logger
    assert "synchronize()" not in append
    assert "pthread_mutex_lock(&utils_log_throttle_lock)" in utils
    assert "utils_should_emit_throttled(&last_log)" in utils


def test_target_reconnects_are_coalesced_and_probe_rate_is_bounded():
    session = read("lara/overlay/CoreSetReadSession.mm")
    assert "now - CSCachedKernelTargetAt <= 1.0" in session
    for consumer in (
        "CoreSetPlayerConsumer.swift", "CoreSetMaterialConsumer.swift",
        "CoreSetRadarConsumer.swift", "CoreSetAimPreviewConsumer.swift",
        "CoreSetAimConsumer.swift",
    ):
        source = read(f"lara/views/app/{consumer}")
        assert "withTimeInterval: 2" in source, consumer


def test_host_palette_comparison_and_close_state_are_stable():
    menu = read("lara/views/app/CoreSetMenuViewController.swift")
    coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
    close = body(menu, "@objc private func closeMenu()")
    request_start = menu.index("func requestMenuVisibility(")
    request_end = menu.index("func suspendMenuHostConsumer", request_start)
    request = menu[request_start:request_end]
    matches = body(coordinator, "private func matches(_ state: State, generation:")
    assert "self.isClosing = false" in close
    assert "self?.isClosing = false" in request
    assert "epsilon = CGFloat(1.0 / 255.0)" in matches
    assert ".isEqual(" not in matches


def test_level_actor_array_has_hash_bound_target_fallback():
    snapshot = read("lara/overlay/CoreSetPlayerSnapshot.mm")
    helper = body(snapshot, "static bool CSReadTargetFallbackPlayerState(")
    for gate in (
        "actorClass != expectedClass", "actor + 0xb78", "actor + 0x3be0",
        "actor + 0x1060", "actor + 0x1068", "actor + 0x260",
        "actor + 0x658", "actor + 0xb94",
    ):
        assert gate in helper
    assert "actorArraySource == CSActorArraySource::levelFallback" in snapshot
    assert "coreAccepted + targetFallbackAccepted == 0" in snapshot
