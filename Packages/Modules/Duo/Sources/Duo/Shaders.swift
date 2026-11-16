// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-FileCopyrightText: 2026 fx-xf
// SPDX-License-Identifier: GPL-3.0-only
//
// Adapted from fx-xf/duo (MIT), see THIRD-PARTY-NOTICES.md.

/// Metal Shading Language source, compiled at launch with
/// `MTLDevice.makeLibrary(source:options:)` so the app builds without the
/// offline Metal toolchain.
///
/// The desktop is treated as a flat panel hinged along the bottom edge of the
/// screen, tilting away from a viewer who stays put — so it settles downward as
/// the lid comes down, leaving black above it. Frosting and dimming grow with
/// the gap between the panel and the screen, after the frosted-glass model of
/// elijah-semyonov/DuoLikeAnimation (MIT).
enum Shaders {
  static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;        // desktop and screen, in pixels
        float eye;          // eye to the screen plane, pixels
        float tilt;         // radians the panel has tilted away from the viewer
        float blurSpread;   // blur radius per pixel of panel-to-screen gap
        float darkening;    // light lost per pixel of blur radius
        float corner;       // radius of the panel's rounded top corners, pixels
        float maxLod;
        float motion;       // 0 desktop still on the screen, 1 anchored in space
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut foldVertex(uint vid [[vertex_id]])
    {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static float grain(float2 p)
    {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    /// Signed distance off the panel, measured in panel coordinates: x across it,
    /// y up from the hinge. Negative inside. The top corners are rounded like the
    /// display's own; the hinge edge stays square, as the panel does.
    static float panelEdge(float2 panel, float2 size, float r)
    {
        float2 q = float2(min(panel.x, size.x - panel.x), size.y - panel.y);
        float2 k = float2(r) - q;
        return length(max(k, 0.0)) + min(max(k.x, k.y), 0.0) - r;
    }

    fragment float4 foldFragment(VOut in [[stage_in]],
                                 texture2d<float> desktop [[texture(0)]],
                                 constant Uniforms &U [[buffer(0)]])
    {
        constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_zero);
        const float4 black = float4(0.0, 0.0, 0.0, 1.0);

        float2 p = in.uv * U.size;
        float u = U.size.y - p.y;                       // height above the hinge
        float2 center = U.size * 0.5;
        float3 eye = float3(center.x, center.y, U.eye);

        // Glass → start plane distance with the true tilt: drives
        // blur and darkening. The eye stays fixed in the world and the desktop in the
        // start plane; the lid lowers by `tilt` around the hinge.
        float st = sin(U.tilt);
        float ct = cos(U.tilt);
        float denom = U.eye - u * st;
        if (denom <= 1e-4) return black;
        float t = U.eye / denom;
        float3 glass = float3(p.x, u * ct, u * st);
        float gap = abs(t - 1.0) * length(glass - eye);

        // Where to sample: with `motion` = 0 the desktop stays still on the screen;
        // with 1 it stays anchored in space (and stretches, because the glass foreshortens).
        float gt = U.tilt * U.motion;
        float gs = sin(gt);
        float gc = cos(gt);
        float gdenom = U.eye - u * gs;
        if (gdenom <= 1e-4) return black;
        float gtt = U.eye / gdenom;
        float2 panel = float2(center.x + gtt * (p.x - center.x), center.y + gtt * (u * gc - center.y));
        float2 uv = float2(panel.x, U.size.y - panel.y) / U.size;

        float dist = panelEdge(panel, U.size, U.corner);
        float mask = saturate(0.5 - dist / max(fwidth(dist), 1e-3));
        if (mask <= 0.0) return black;

        // Frosted glass: the farther the panel has fallen from the screen, the
        // wider it scatters and the more light it swallows.
        float radius = U.blurSpread * gap;
        float attenuation = max(1.0 - U.darkening * radius, 0.0);

        // Far end of the panel is minified as well; keep it off the texel grid.
        float2 texels = fwidth(uv) * U.size;
        float minLod = clamp(log2(max(max(texels.x, texels.y), 1.0)), 0.0, U.maxLod);

        if (radius < 0.5) {
            float3 c = desktop.sample(smp, uv, level(minLod)).rgb;
            return float4(c * attenuation * mask, 1.0);
        }

        // Vogel disk across the panel, rotated per pixel so banding turns into
        // frost grain. Each tap reads a mip level matched to the tap spacing,
        // which keeps a wide kernel smooth on a laptop-sized panel.
        int taps = clamp(int(radius), 6, 16);
        float lod = clamp(max(log2(radius / sqrt(float(taps))), minLod), 0.0, U.maxLod);
        float rotation = grain(p) * 6.28318530718;
        float3 sum = float3(0.0);
        for (int i = 0; i < taps; ++i) {
            float r = radius * sqrt((float(i) + 0.5) / float(taps));
            float a = float(i) * 2.39996322973 + rotation;
            float2 at = panel + r * float2(cos(a), sin(a));
            float2 tuv = float2(at.x, U.size.y - at.y) / U.size;
            sum += desktop.sample(smp, tuv, level(lod)).rgb * saturate(0.5 - panelEdge(at, U.size, U.corner));
        }
        return float4(sum / float(taps) * attenuation, 1.0);
    }
    """
}
