$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$project = Get-Content -LiteralPath (Join-Path $root 'lara.xcodeproj/project.pbxproj') -Raw -Encoding UTF8
$imguiRoot = Join-Path $root 'lara/third_party/imgui'
$pinnedCommit = '59db6ceeb15ea7b685c2564a7bc889fd5ba7eef9'

$pinnedFiles = [ordered]@{
    'imgui.h' = 'bd9351d64c51cf89587ef75ab79b76ca3171d3715b1fb764ac610b660c973a51'
    'imconfig.h' = 'fb8e32b9af9aa7dad5ec5c5bc862537f5624cb39a814e6d3b36b4629a50b6599'
    'imgui_internal.h' = '9234d6b459d1976870e29d8cbd505bb9b41728af107d03219c1454248ab717f8'
    'imstb_rectpack.h' = 'bb53504995e983d54b1ae06ea727f0b39647e5e205b4bf7da01343953974951c'
    'imstb_textedit.h' = '24a8db00354af8f4057417841635a1b6dfd8986f1608336fe6f10d6fd9769aaa'
    'imstb_truetype.h' = '37aa1d602706262bf94da2f83efaa8175ebc2202ede13da96b692fbcf8b4427b'
    'imgui.cpp' = '859ae782e8485e2927155a263cf2430a14b1d43078b223d2e9995f69bb31185c'
    'imgui_draw.cpp' = '27c33995dc29a5de21705a45f037c473837709363b44ded8c1217ff982aad903'
    'imgui_tables.cpp' = '22a64f848d0c047823f492941ffe4a22aeaea71440c74736f4fbf7a2b6a9dc4f'
    'imgui_widgets.cpp' = '32d89fe88d2e3b19c2e4b713c8df2b0bbbefd116a49f36818ee2726703e6e6de'
    'LICENSE.txt' = '55e058cc5899e6077a819ad1005d6d1f4528f65ae100795c9692f9fa6525a8ce'
    'backends/imgui_impl_metal.h' = '118e7c5f13c85b2af32d76139f6eb08a0d8dc0f97d42f8b85c9d401d8d288ec9'
    'backends/imgui_impl_metal.mm' = '792761402be6d638b42dd95afb17033aeabbfe4ec523a961d325fa581c4ce925'
}
foreach ($entry in $pinnedFiles.GetEnumerator()) {
    $path = Join-Path $imguiRoot $entry.Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "FAIL: missing vendored ImGui file $($entry.Key)" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "FAIL: ImGui snapshot drift in $($entry.Key): $actual" }
}

$imgui = Get-Content -LiteralPath (Join-Path $imguiRoot 'imgui.h') -Raw -Encoding UTF8
$imconfig = Get-Content -LiteralPath (Join-Path $imguiRoot 'imconfig.h') -Raw -Encoding UTF8
$backend = Get-Content -LiteralPath (Join-Path $imguiRoot 'backends/imgui_impl_metal.mm') -Raw -Encoding UTF8
if ($imgui -notmatch '#define IMGUI_VERSION\s+"1\.92\.5 WIP"' -or
    $imgui -notmatch '#define IMGUI_VERSION_NUM\s+19243') {
    throw 'FAIL: vendored Dear ImGui version is not the pinned 1.92.5 WIP snapshot'
}
if ($imgui -match 'DragDropTargetRect(Rounding|LineThickness|ExpansionSize)|ImGuiCol_DragDropTargetBg') {
    throw 'FAIL: post-59db6cee drag-drop style fields inflate ImGuiStyle beyond AX ABI 0x4ec'
}
if ($imconfig -match '(?m)^\s*#define\s+(IMGUI_USE_WCHAR32|IMGUI_DISABLE_OBSOLETE_FUNCTIONS|ImDrawIdx|ImTextureID)\b') {
    throw 'FAIL: vendored ImGui ABI configuration is not the upstream default used by AX'
}
if ($imgui -notmatch 'typedef unsigned short ImDrawIdx' -or
    $imgui -notmatch 'struct ImDrawVert[\s\S]{0,180}ImVec2\s+pos;[\s\S]{0,80}ImVec2\s+uv;[\s\S]{0,80}ImU32\s+col;') {
    throw 'FAIL: ImDraw index/vertex declaration drifted'
}
foreach ($pattern in @(
    'sourceRGBBlendFactor = MTLBlendFactorSourceAlpha',
    'destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha',
    'sourceAlphaBlendFactor = MTLBlendFactorOne',
    'destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha',
    'setScissorRect:scissorRect',
    'offsetof\(ImDrawVert, pos\)',
    'offsetof\(ImDrawVert, uv\)',
    'offsetof\(ImDrawVert, col\)',
    'ImGui_ImplMetal_UpdateTexture'
)) {
    if ($backend -notmatch $pattern) { throw "FAIL: Metal backend contract missing: $pattern" }
}

foreach ($pattern in @(
    'static_assert\(sizeof\(ImGuiIO\) == 0xbd8 && sizeof\(ImGuiStyle\) == 0x4ec',
    'offsetof\(ImDrawVert,pos\) == 0',
    'offsetof\(ImDrawVert,uv\) == 8',
    'offsetof\(ImDrawVert,col\) == 0x10',
    'sizeof\(ImDrawIdx\) == 2 && sizeof\(ImTextureID\) == 8',
    'ImGui_ImplMetal_Init\(_device\)',
    'AddFontFromFileTTF\(fontPath\.fileSystemRepresentation,18\.0f,nullptr',
    'GetGlyphRangesDefault\(\)',
    'io\.DisplayFramebufferScale=ImVec2',
    'io\.DeltaTime=kAXImGuiDeltaTime',
    'ImGui::NewFrame\(\)',
    'ImGui::Render\(\)',
    'ImGui_ImplMetal_RenderDrawData\(ImGui::GetDrawData\(\),command,encoder\)',
    'submitCommands:\(const AXHUDRenderCommands \*\)commands',
    'submitCommands:&frame\.commands',
    'ax_build_render_commands\(latest, latestCount, current_wz_config\(\)',
    'for \(const AXHUDRenderCommand &command : \*_commands\)',
    'buildDirectDrawList:\(ImDrawList \*\)drawList',
    'drawList->PushClipRect',
    'drawList->PathStroke',
    'drawList->PathArcTo',
    'drawList->AddLine',
    'drawList->AddRect',
    'drawList->AddCircleFilled',
    'drawList->AddCircle',
    'drawList->AddText',
    'drawList->AddImageRounded'
)) {
    if ($source -notmatch $pattern) { throw "FAIL: foreground ImGui contract missing: $pattern" }
}
if ($source -match 'textureForCommand|setVertexBytes:vertices|drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6|CGPathApply|for \(CALayer \*layer in _commands\)|appendShapeLayer') {
    throw 'FAIL: legacy per-layer CoreGraphics/CGPath foreground renderer remains'
}
if (($project | Select-String -Pattern '\$\(SRCROOT\)/lara/third_party/imgui' -AllMatches).Matches.Count -ne 2) {
    throw 'FAIL: Debug/Release ImGui header search paths are not both present'
}
if ($project -notmatch 'PBXFileSystemSynchronizedRootGroup[\s\S]{0,300}path = lara;' -or
    $project -notmatch 'membershipExceptions = \([\s\S]{0,500}third_party/imgui/LICENSE\.txt' -or
    $project -match 'membershipExceptions = \([\s\S]{0,500}third_party/imgui/(imgui|imconfig|imstb|backends)') {
    throw 'FAIL: vendored ImGui sources are not covered by the synchronized lara source group'
}

Write-Output "PASS: pinned ImGui 1.92.5 WIP snapshot $pinnedCommit, ABI/layout and Metal draw-data contracts"
