"""iOS 26 SPTM patchfinder/fetch wiring; source-only until macOS CI runs the fixture."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class SPTMTransportContract(unittest.TestCase):
    def test_xpf_uses_sptm_abi_and_exact_layout(self) -> None:
        lara = read("lara/headers/xpf.h")
        vendor = read("vendor/XPF/src/xpf.h")
        declaration = (
            "int xpf_start_with_kernel_path(const char *kernelPath, "
            "const char *optSptmPath, const char *optTxmPath);"
        )
        for source in (lara, vendor):
            self.assertIn(declaration, source)
            self.assertIn("offsetof(XPF, firstItem) == 0x1a8", source)
            self.assertIn("offsetof(XPF, ignoreBaseSet) == 0x1b0", source)
            self.assertIn("sizeof(XPF) == 0x1b8", source)
        self.assertEqual(
            lara[lara.index("typedef struct s_XPF {"):lara.index("} XPF;")],
            vendor[vendor.index("typedef struct s_XPF {"):vendor.index("} XPF;")],
        )

    def test_upstream_sptm_finders_are_registered_and_selected(self) -> None:
        xpf = read("vendor/XPF/src/xpf.c")
        sptm = read("vendor/XPF/src/sptm_txm.c")
        for marker in (
            "gTranslationSPTMSet", "gPhysmapSPTMSet_18_4_Up",
            '"kernelSymbol.libsptm_papt_ranges"',
            '"kernelSymbol.libsptm_n_papt_ranges"',
        ):
            self.assertIn(marker, xpf)
        self.assertIn("xpf_sptm_txm_init()", xpf)
        self.assertLess(xpf.index("xpf_sptm_txm_init()"), xpf.index("xpf_common_init()"))
        for marker in (
            "static uint64_t xpf_find_cpu_ttep", "xpf_find_libsptm_init_str_reference",
            'xpf_item_register("kernelSymbol.libsptm_papt_ranges"',
            'xpf_item_register("kernelSymbol.libsptm_n_papt_ranges"',
        ):
            self.assertIn(marker, sptm)

    def test_kernel_and_sptm_are_fetched_from_one_remote_zip(self) -> None:
        partial = read("lara/kexploit/Partial.m")
        offsets = read("lara/kexploit/offsets.m")
        self.assertIn("kc_fetch_firmware_images_by_range", partial)
        self.assertIn("CoreSetRangeVerifiedPartial *zip =", partial)
        self.assertIn("[[CoreSetRangeVerifiedPartial alloc] initWithURL:url error:&error]", partial)
        self.assertIn("kc_pick_kernelcache_entry(files)", partial)
        self.assertIn("kc_pick_sptm_entry(files)", partial)
        self.assertIn("Both payloads must belong to the same central-directory snapshot", partial)
        self.assertIn("kc_fetch_firmware_images_by_range(outpath", offsets)
        self.assertIn('SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0")', offsets)
        self.assertIn("kcpath.UTF8String, sptm.UTF8String, NULL", offsets)
        self.assertIn('firmware_identity_value("kern.osversion")', offsets)
        self.assertIn('firmware_identity_value("hw.machine")', offsets)
        self.assertIn("firmware_cache_identity_matches(defaults)", offsets)

    def test_iphone_cdn_range_capability_uses_real_get_not_head_header(self) -> None:
        partial = read("lara/kexploit/Partial.m")
        for marker in (
            'request.HTTPMethod = @"GET"',
            'setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"',
            "timeoutInterval:120.0",
            'setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"',
            'http.statusCode != 206',
            'valueForHTTPHeaderField:@"Content-Range"',
            'sscanf(contentRange.UTF8String, "bytes %llu-%llu/%llu%c"',
            'data.length != 1',
            'total > (64ULL << 30)',
            'setValue:@((NSUInteger)self.coreRangeTotal) forKey:@"_size"',
        ):
            self.assertIn(marker, partial)
        self.assertNotIn('HTTPMethod = @"HEAD"', partial)

    def test_every_range_chunk_is_bound_to_one_remote_asset_version(self) -> None:
        partial = read("lara/kexploit/Partial.m")
        request = partial.split("- (NSData *)_makeSynchronousRequest", 1)[1].split(
            "- (NSError *)_getMetadata", 1
        )[0]
        for marker in (
            'valueForHTTPHeaderField:@"Range"',
            "verifiedRequest.timeoutInterval = 120.0",
            'setValue:self.coreRangeValidator forHTTPHeaderField:@"If-Range"',
            'valueForHTTPHeaderField:@"ETag"',
            'hasPrefix:@"W/"',
            'valueForHTTPHeaderField:@"Last-Modified"',
            "actualFirst != requestedFirst || actualLast != requestedLast",
            "(unsigned long long)data.length != expectedLength",
            "self.coreRangeTotal != total",
            "![self.coreRangeValidator isEqualToString:validator]",
            '@"Range response has no safe resume validator"',
            '@"Remote asset size changed during range transfer"',
            '@"Remote asset validator changed during range transfer"',
        ):
            self.assertIn(marker, request)

    def test_23a341_uses_hash_pinned_apple_restore_url_without_appledb(self) -> None:
        partial = read("lara/kexploit/Partial.m")
        workflow = read(".github/workflows/build.yml")
        pieces = (
            "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-41023/",
            "5740BA6D-F4D8-4825-B5BE-CB70E3CF8B79/",
            "iPhone17,2_26.0_23A341_Restore.ipsw",
        )
        for piece in pieces:
            self.assertIn(piece, partial)
            self.assertIn(piece, workflow)
        self.assertIn('[build isEqualToString:@"23A341"]', partial)
        self.assertIn('[machine isEqualToString:@"iPhone17,2"]', partial)
        self.assertLess(partial.index("kIPhone172Build23A341IPSW.UTF8String"),
                        partial.index("NSString *endpoint ="))

    def test_im4p_validator_accepts_der_83_and_84_length_forms(self) -> None:
        partial = read("lara/kexploit/Partial.m")
        self.assertIn("const NSUInteger lengthOctets = bytes[1] & 0x7f", partial)
        self.assertIn("lengthOctets == 0 || lengthOctets > 4", partial)
        self.assertIn("contentLength != data.length - contentOffset", partial)
        self.assertIn('memcmp(bytes + contentOffset + 2, "IM4P", 4) == 0', partial)
        self.assertNotIn("bytes[1] == 0x84", partial)
        # Exact fixture prefixes: kernelcache uses DER 0x84, SPTM uses 0x83.
        kernel = bytes.fromhex("30 84 01 4D 30 81 16 04 49 4D 34 50")
        sptm = bytes.fromhex("30 83 02 C5 DE 16 04 49 4D 34 50")
        self.assertEqual(kernel[1] & 0x7F, 4)
        self.assertEqual(sptm[1] & 0x7F, 3)

    def test_xpf_cleanup_releases_optional_images_and_sections(self) -> None:
        xpf = read("vendor/XPF/src/xpf.c")
        for marker in (
            "pfsec_free(gXPF.sptmTextSection)",
            "pfsec_free(gXPF.sptmStringSection)",
            "fat_free(gXPF.sptmContainer)",
            "free(gXPF.decompressedSptm)",
            "pfsec_free(gXPF.txmTextSection)",
            "fat_free(gXPF.txmContainer)",
            "free(gXPF.decompressedTxm)",
        ):
            self.assertIn(marker, xpf)

    def test_ci_runs_hash_pinned_23a341_finder_probe(self) -> None:
        workflow = read(".github/workflows/build.yml")
        probe = read("tools/xpf_ios26_probe.c")
        self.assertIn("validate iOS 26 SPTM patchfinder", workflow)
        self.assertIn("20626b2ffd1f3e72615e2d9f5e7a794de3dff43c8c10ca944ddfa6f0af7b2dd0", workflow)
        self.assertIn("26febcbc7b2d20b691ad0d782666b2ea840081953c150f918cc763b603525314", workflow)
        for item in (
            "kernelSymbol.cpu_ttep", "kernelSymbol.gPhysBase",
            "kernelSymbol.libsptm_papt_ranges", "kernelConstant.T1SZ_BOOT",
        ):
            self.assertIn(item, probe)
        for expected in (
            "0xfffffff007004000ULL", "0xfffffff027004000ULL",
            "0xfffffff007cace30ULL", "0xfffffff007cace38ULL",
            "0x0000007000000000ULL", "0x40ULL",
        ):
            self.assertIn(expected, probe)

    def test_runtime_consumes_xpf_papt_values_through_checked_reads(self) -> None:
        items = read("lara/kexploit/xpfitems.m")
        offsets = read("lara/kexploit/offsets.m")
        transport = read("lara/overlay/CoreSetKernelMappedReadTransport.mm")
        darksword = read("lara/kexploit/darksword.m")
        for item in (
            '"kernelConstant.ARM_TT_L1_INDEX_MASK"',
            '"kernelStruct.vm_map.pmap"',
            '"kernelSymbol.libsptm_n_papt_ranges"',
            '"kernelSymbol.libsptm_papt_ranges"',
        ):
            self.assertIn(item, items)
        self.assertIn("gxpf_libsptm_papt_ranges - gXPF.kernelBase", offsets)
        self.assertIn("gxpf_libsptm_n_papt_ranges - gXPF.kernelBase", offsets)
        self.assertIn("CSSPTMPAPTEntry", transport)
        self.assertIn("_targetTTEPIsPhysical", transport)
        self.assertIn("physicalAddressForUserAddressLocked", transport)
        self.assertNotIn("vmmapremotepagereadonly", transport)
        self.assertIn("bool ds_kreadbuf_checked", darksword)
        self.assertIn("read_data_length == (socklen_t)size", darksword)


if __name__ == "__main__":
    unittest.main()
