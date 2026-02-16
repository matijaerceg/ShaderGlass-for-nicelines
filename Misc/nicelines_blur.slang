#version 450
// nicelines v18 (2026-02-14)

// === PASS 0: HORIZONTAL SMEAR ===
// This pass handles: horizontal smear only (no pre-blur/downscale)
// Output: smeared image in linear space (float framebuffer)

// === PARAMETERS ===
#pragma parameter H_BLUR "SMEAR: RGB / S-Video / Composite" 1.0 0.0 2.0 1.0

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float H_BLUR;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

float SrgbToLinear(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

vec3 SrgbToLinear3(vec3 c) {
    return vec3(SrgbToLinear(c.r), SrgbToLinear(c.g), SrgbToLinear(c.b));
}

vec3 sampleLinear(vec2 uv) {
    return SrgbToLinear3(texture(Source, clamp(uv, vec2(0.0), vec2(1.0))).rgb);
}

float getSmearAmount() {
    int mode = int(global.H_BLUR + 0.5);
    if(mode <= 0) {
        return 0.0;
    } else if(mode == 1) {
        return 4.0;
    }
    return 8.0;
}

float getOutputResolutionSmearScale() {
    const float referenceWidth = 3840.0;
    return min(1.0, global.OutputSize.x / referenceWidth);
}

vec3 sampleHBlurBox5(vec2 uv, float hBlur) {
    if(hBlur <= 0.001) return sampleLinear(uv);

    float pixelSize = 1.0 / global.OutputSize.x;
    float smearScale = getOutputResolutionSmearScale();
    float stepSize = hBlur * pixelSize * 0.5 * smearScale;
    vec3 c0 = sampleLinear(vec2(uv.x - 2.0 * stepSize, uv.y));
    vec3 c1 = sampleLinear(vec2(uv.x - stepSize, uv.y));
    vec3 c2 = sampleLinear(uv);
    vec3 c3 = sampleLinear(vec2(uv.x + stepSize, uv.y));
    vec3 c4 = sampleLinear(vec2(uv.x + 2.0 * stepSize, uv.y));
    return (c0 + c1 + c2 + c3 + c4) * 0.2;
}

void main() {
    float smear = getSmearAmount();
    vec3 color = sampleHBlurBox5(vTexCoord, smear);

    FragColor = vec4(color, 1.0);
}
