#version 450
// nicelines v11 (2026-02-14)

// === PASS 4: HALATION BLUR + FINAL OUTPUT ===
// Input A (Source): extracted highlights from pass 3 (linear)
// Input B (Mask):   base masked image from pass 2 (linear, via alias)
// Output: final image in sRGB

#pragma parameter CURVATURE "CURVATURE" 0.0 0.0 1.0 1.0

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float CURVATURE;
} global;

// === VERTEX STAGE ===
#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

// === FRAGMENT STAGE ===
#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;  // Pass 3 output (extracted highlights)
layout(set = 0, binding = 3) uniform sampler2D Mask;    // Pass 2 output alias

float LinearToSrgb(float c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

vec3 LinearToSrgb3(vec3 c) {
    return vec3(LinearToSrgb(c.r), LinearToSrgb(c.g), LinearToSrgb(c.b));
}

vec2 applyCurvature(vec2 uv, float amount) {
    vec2 p = uv * 2.0 - 1.0;
    float aspect = global.OutputSize.x / max(global.OutputSize.y, 1.0);
    p.x *= aspect;

    float r2 = dot(p, p);
    p *= (1.0 + amount * r2);

    p.x /= aspect;
    return p * 0.5 + 0.5;
}

vec2 snapUvToRes(vec2 uv, float resScale) {
    if(resScale >= 0.999) {
        return clamp(uv, vec2(0.0), vec2(1.0));
    }

    vec2 targetSize = max(vec2(1.0), floor(global.OutputSize.xy * resScale + 0.5));
    vec2 snappedPx = floor(clamp(uv, vec2(0.0), vec2(1.0)) * targetSize) + 0.5;
    return clamp(snappedPx / targetSize, vec2(0.0), vec2(1.0));
}

vec3 sampleTexturePoint(sampler2D tex, vec2 uv) {
    return texture(tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

vec3 sampleTextureBilinear(sampler2D tex, vec2 uv) {
    vec2 texSize = max(global.OutputSize.xy, vec2(1.0));
    vec2 clampedUV = clamp(uv, vec2(0.0), vec2(1.0));
    vec2 px = clampedUV * texSize - vec2(0.5);
    vec2 i0 = floor(px);
    vec2 fracPart = fract(px);

    vec2 uv00 = (i0 + vec2(0.5, 0.5)) / texSize;
    vec2 uv10 = (i0 + vec2(1.5, 0.5)) / texSize;
    vec2 uv01 = (i0 + vec2(0.5, 1.5)) / texSize;
    vec2 uv11 = (i0 + vec2(1.5, 1.5)) / texSize;

    vec3 c00 = sampleTexturePoint(tex, uv00);
    vec3 c10 = sampleTexturePoint(tex, uv10);
    vec3 c01 = sampleTexturePoint(tex, uv01);
    vec3 c11 = sampleTexturePoint(tex, uv11);

    vec3 cx0 = mix(c00, c10, fracPart.x);
    vec3 cx1 = mix(c01, c11, fracPart.x);
    return mix(cx0, cx1, fracPart.y);
}

vec3 sampleTexture3Tap(sampler2D tex, vec2 uv) {
    vec2 texel = 1.0 / max(global.OutputSize.xy, vec2(1.0));
    vec3 center = sampleTextureBilinear(tex, uv) * 0.5;
    vec3 left   = sampleTextureBilinear(tex, uv + vec2(-0.5, 0.0) * texel) * 0.25;
    vec3 right  = sampleTextureBilinear(tex, uv + vec2( 0.5, 0.0) * texel) * 0.25;
    return center + left + right;
}

vec3 sampleHighlightAt(vec2 uv, float resScale) {
    vec2 sampledUV = snapUvToRes(uv, resScale);
    return sampleTexture3Tap(Source, sampledUV);
}

// Heavier true convolution blur on a 5x5 kernel.
vec3 blurHighlightsGaussian(vec2 uv, float radiusPx, vec2 texel, float resScale) {
    // Radius maps to sampling step; keeps response smooth as slider changes.
    float stepPx = max(0.35, radiusPx * 0.5);
    vec3 sum = vec3(0.0);
    float sumW = 0.0;

    for(int y = -2; y <= 2; y++) {
        for(int x = -2; x <= 2; x++) {
            vec2 offset = vec2(float(x), float(y));
            float d2 = dot(offset, offset);
            float w = exp(-d2 * 0.5);
            vec2 tapUV = uv + offset * stepPx * texel;
            sum += sampleHighlightAt(tapUV, resScale) * w;
            sumW += w;
        }
    }
    return sum / sumW;
}

vec3 blurHighlightsTent3x3(vec2 uv, float radiusPx, vec2 texel, float resScale) {
    float stepPx = max(0.5, radiusPx * 0.35);
    vec2 d = texel * stepPx;

    vec3 c00 = sampleHighlightAt(uv + vec2(-d.x, -d.y), resScale);
    vec3 c10 = sampleHighlightAt(uv + vec2( 0.0, -d.y), resScale);
    vec3 c20 = sampleHighlightAt(uv + vec2( d.x, -d.y), resScale);

    vec3 c01 = sampleHighlightAt(uv + vec2(-d.x,  0.0), resScale);
    vec3 c11 = sampleHighlightAt(uv, resScale);
    vec3 c21 = sampleHighlightAt(uv + vec2( d.x,  0.0), resScale);

    vec3 c02 = sampleHighlightAt(uv + vec2(-d.x,  d.y), resScale);
    vec3 c12 = sampleHighlightAt(uv + vec2( 0.0,  d.y), resScale);
    vec3 c22 = sampleHighlightAt(uv + vec2( d.x,  d.y), resScale);

    return (c00 + 2.0 * c10 + c20 +
            2.0 * c01 + 4.0 * c11 + 2.0 * c21 +
            c02 + 2.0 * c12 + c22) * (1.0 / 16.0);
}

vec3 blurHighlightsFast9(vec2 uv, float radiusPx, vec2 texel, float resScale) {
    float stepPx = max(0.75, radiusPx * 0.45);
    vec2 d = texel * stepPx;

    vec3 center = sampleHighlightAt(uv, resScale) * 0.32;
    vec3 axes = (sampleHighlightAt(uv + vec2( d.x, 0.0), resScale) +
                 sampleHighlightAt(uv + vec2(-d.x, 0.0), resScale) +
                 sampleHighlightAt(uv + vec2(0.0,  d.y), resScale) +
                 sampleHighlightAt(uv + vec2(0.0, -d.y), resScale)) * 0.11;
    vec3 diagonals = (sampleHighlightAt(uv + vec2( d.x,  d.y), resScale) +
                      sampleHighlightAt(uv + vec2(-d.x,  d.y), resScale) +
                      sampleHighlightAt(uv + vec2( d.x, -d.y), resScale) +
                      sampleHighlightAt(uv + vec2(-d.x, -d.y), resScale)) * 0.06;

    return center + axes + diagonals;
}

void main() {
    const float CURVATURE_AMOUNT = 0.02;
    bool curveEnabled = (global.CURVATURE >= 0.5);
    vec2 maskUV = curveEnabled ? applyCurvature(vTexCoord, CURVATURE_AMOUNT) : vTexCoord;
    bool insideCurve = all(greaterThanEqual(maskUV, vec2(0.0))) && all(lessThanEqual(maskUV, vec2(1.0)));
    if(curveEnabled && !insideCurve) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    maskUV = clamp(maskUV, vec2(0.0), vec2(1.0));

    const float amount = 0.48;
    const float radius = 12.0;

    if(amount <= 0.0001 || radius <= 0.0001) {
        vec3 baseLinearBypass = sampleTexture3Tap(Mask, maskUV);
        FragColor = vec4(LinearToSrgb3(baseLinearBypass), 1.0);
        return;
    }

    vec3 baseLinear = sampleTexture3Tap(Mask, maskUV);

    const int HALATION_MODE_LOCKED = 1;   // Balanced
    const int HALATION_BLEND_LOCKED = 1;  // Brighter
    const float HALATION_RES_SCALE_LOCKED = 1.0;   // Full
    const float HALATION_RANGE_SCALE_LOCKED = 1.8; // Far

    vec2 texel = 1.0 / global.OutputSize.xy;
    float resScale = HALATION_RES_SCALE_LOCKED;
    float rangeScale = HALATION_RANGE_SCALE_LOCKED;
    float radiusScaled = radius * rangeScale;

    int mode = HALATION_MODE_LOCKED;
    vec3 halation;
    if(mode <= 0) {
        vec3 blurTight = blurHighlightsGaussian(maskUV, radiusScaled, texel, resScale);
        vec3 blurWide = blurHighlightsGaussian(maskUV, radiusScaled * 1.8, texel, resScale);
        halation = blurTight * 0.7 + blurWide * 0.3;
    } else if(mode == 1) {
        vec3 blurTight = blurHighlightsGaussian(maskUV, radiusScaled * 0.85, texel, resScale);
        vec3 blurWide = blurHighlightsTent3x3(maskUV, radiusScaled * 1.35, texel, resScale);
        halation = blurTight * 0.75 + blurWide * 0.25;
    } else {
        halation = blurHighlightsFast9(maskUV, radiusScaled * 1.1, texel, resScale);
    }

    vec3 halationLayer = halation * amount;
    int blendMode = HALATION_BLEND_LOCKED;
    vec3 outLinear;
    if(blendMode <= 0) {
        outLinear = baseLinear + halationLayer;
    } else {
        outLinear = max(baseLinear, halationLayer);
    }

    FragColor = vec4(LinearToSrgb3(outLinear), 1.0);
}
