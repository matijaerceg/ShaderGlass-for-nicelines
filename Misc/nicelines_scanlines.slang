#version 450

// === PASS 0: SCANLINES + BLUR ===
// This pass handles: downscale blur, H_BLUR, scanline simulation
// Output: fully processed scanline image (linear space)

// === PARAMETERS ===
#pragma parameter COMPARE_MODE "[v27] Half Screen COMPARE" 0.0 0.0 1.0 1.0
#pragma parameter SCANLINE_MODE "SCANLINES MODE (224p / 240p / Manual)" 0.0 0.0 2.0 1.0
#pragma parameter MANUAL_LINES "MANUAL Mode: Number of Scanlines" 360.0 120.0 480.0 5.0
#pragma parameter FINETUNE_LINES "FINETUNE Number of Scanlines" 0.0 -5.0 5.0 1.0
#pragma parameter AUTO_LINES "ROUND Number of Scanlines to Nearest Multiple of Resolution (Recommend OFF for 2D games, ON for 3D;)" 0.0 0.0 1.0 1.0
#pragma parameter BLUR_OFFSET "DOWNSCALING Prepass (Lower = Softer)" 0.04 -0.04 0.12 0.01
#pragma parameter H_BLUR "HORIZONTAL BLUR (worn out tube look)" 1.0 0.0 8.0 0.1

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float COMPARE_MODE;
    float SCANLINE_MODE;
    float MANUAL_LINES;
    float FINETUNE_LINES;
    float AUTO_LINES;
    float BLUR_OFFSET;
    float H_BLUR;
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
layout(set = 0, binding = 2) uniform sampler2D Source;

// sRGB conversion
float SrgbToLinear(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float LinearToSrgb(float c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0/2.4) - 0.055;
}

vec3 SrgbToLinear3(vec3 c) {
    return vec3(SrgbToLinear(c.r), SrgbToLinear(c.g), SrgbToLinear(c.b));
}

vec3 LinearToSrgb3(vec3 c) {
    return vec3(LinearToSrgb(c.r), LinearToSrgb(c.g), LinearToSrgb(c.b));
}

// Calculate scanline width for a given color
float calcScanlineWidth(vec3 color, float baseWidth, float minWidth, float maxWidth) {
    float maxColorChannel = max(max(color.r, color.g), color.b);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    
    // Dark path: interpolate minWidth → baseWidth based on luma
    float t = clamp(luma / baseWidth, 0.0, 1.0);
    float darkWidth = mix(minWidth, baseWidth, t);
    
    // Bright path: width follows max channel
    float brightWidth = clamp(maxColorChannel, baseWidth, maxWidth);
    
    // Smooth blend between dark and bright paths around baseWidth threshold
    float blendZone = 0.1;
    float blend = smoothstep(baseWidth - blendZone * baseWidth, baseWidth + blendZone * baseWidth, maxColorChannel);
    
    return mix(darkWidth, brightWidth, blend);
}

// Sample source with optional blur
vec3 sampleWithBlur(vec2 uv, float effectiveScale) {
    vec3 color;
    if(effectiveScale < 0.999) {
        float blurRadius = (1.0 / effectiveScale - 1.0) * 0.5;
        vec2 texelSize = 1.0 / global.SourceSize.xy;
        vec2 radius = texelSize * blurRadius;
        
        // 9-tap box filter for area averaging
        vec3 sum = vec3(0.0);
        sum += texture(Source, uv + vec2(-radius.x, -radius.y)).rgb;
        sum += texture(Source, uv + vec2(      0.0, -radius.y)).rgb;
        sum += texture(Source, uv + vec2( radius.x, -radius.y)).rgb;
        sum += texture(Source, uv + vec2(-radius.x,       0.0)).rgb;
        sum += texture(Source, uv).rgb;
        sum += texture(Source, uv + vec2( radius.x,       0.0)).rgb;
        sum += texture(Source, uv + vec2(-radius.x,  radius.y)).rgb;
        sum += texture(Source, uv + vec2(      0.0,  radius.y)).rgb;
        sum += texture(Source, uv + vec2( radius.x,  radius.y)).rgb;
        color = sum / 9.0;
    } else {
        color = texture(Source, uv).rgb;
    }
    return color;
}

// Sample source with optional H_BLUR applied (5-tap tent filter)
vec3 sampleWithHBlur(vec2 uv, float effectiveScale, float hBlur) {
    if(hBlur > 0.001) {
        float pixelSize = 1.0 / global.OutputSize.x;
        float blurRadius = hBlur * pixelSize;
        
        vec3 cC = SrgbToLinear3(sampleWithBlur(uv, effectiveScale));
        vec3 cL1 = SrgbToLinear3(sampleWithBlur(vec2(uv.x - blurRadius * 0.5, uv.y), effectiveScale));
        vec3 cL2 = SrgbToLinear3(sampleWithBlur(vec2(uv.x - blurRadius, uv.y), effectiveScale));
        vec3 cR1 = SrgbToLinear3(sampleWithBlur(vec2(uv.x + blurRadius * 0.5, uv.y), effectiveScale));
        vec3 cR2 = SrgbToLinear3(sampleWithBlur(vec2(uv.x + blurRadius, uv.y), effectiveScale));
        
        return cL2 * 0.1 + cL1 * 0.2 + cC * 0.4 + cR1 * 0.2 + cR2 * 0.1;
    } else {
        return SrgbToLinear3(sampleWithBlur(uv, effectiveScale));
    }
}

void main() {
    float baseWidth = 0.3;   // Hardcoded thickness baseline
    float minWidth = 0.5;    // Hardcoded thickness min
    float maxWidth = 1.0;    // Hardcoded thickness max
    
    // Determine target scanline count based on mode
    float targetLines;
    int mode = int(global.SCANLINE_MODE + 0.5);
    if(mode == 0) {
        targetLines = 224.0;
    } else if(mode == 1) {
        targetLines = 240.0;
    } else {
        targetLines = global.MANUAL_LINES;
    }
    
    // Apply finetune adjustment
    targetLines += global.FINETUNE_LINES;
    
    // Auto-fit: find nearest factor of output height to target
    if(global.AUTO_LINES > 0.5) {
        float outputHeight = global.OutputSize.y;
        float idealPixelsPerLine = outputHeight / targetLines;
        float pixelsPerLine = max(1.0, round(idealPixelsPerLine));
        targetLines = outputHeight / pixelsPerLine;
    }
    
    // Source blur settings
    float baselineScale = targetLines / global.SourceSize.y;
    float effectiveScale = clamp(baselineScale + global.BLUR_OFFSET, 0.02, 1.0);
    
    // Edge softness calculation (hardcoded to full softening)
    float baseEdgeSoftness = 0.05;
    float curvedAmount = pow(1.0, 2.5);  // VERTICAL_AMOUNT = 1.0
    float edgeSoftness = baseEdgeSoftness + curvedAmount * 0.25;
    
    // Compare mode: right half shows original
    if(global.COMPARE_MODE > 0.5 && vTexCoord.x > 0.5) {
        vec3 color = texture(Source, vTexCoord).rgb;
        FragColor = vec4(color, 1.0);
        return;
    }
    
    vec2 px = vTexCoord * global.OutputSize.xy;
    
    // Calculate scanline position (CENTER-ANCHORED)
    float distFromCenter = vTexCoord.y - 0.5;
    float scanlineOffset = distFromCenter * targetLines;
    float scanlinePos = scanlineOffset;
    float scanlineIndex = floor(scanlinePos);
    
    // Sample at scanline center
    float sampleScanlinePos = scanlineIndex + 0.5;
    float sampleDistFromCenter = sampleScanlinePos / targetLines;
    vec2 sampleUV = vec2(vTexCoord.x, clamp(0.5 + sampleDistFromCenter, 0.0, 1.0));
    
    float withinScanline = fract(scanlinePos);
    
    // Sample source with horizontal blur
    vec3 color = sampleWithHBlur(sampleUV, effectiveScale, global.H_BLUR);
    
    // Calculate scanline width and energy-preserved color
    float scanlineWidth = calcScanlineWidth(color, baseWidth, minWidth, maxWidth);
    vec3 outputColor = clamp(color / scanlineWidth, 0.0, 1.0);
    
    // Scanline mask with soft edges
    float halfGap = (1.0 - scanlineWidth) * 0.5;
    float scanlineMask = smoothstep(halfGap - edgeSoftness, halfGap + edgeSoftness, withinScanline) *
                         smoothstep(1.0 - halfGap + edgeSoftness, 1.0 - halfGap - edgeSoftness, withinScanline);
    
    vec3 finalColor = outputColor * scanlineMask;
    
    // Apply brightness boost
    finalColor *= 1.1;
    
    // Compare mode divider line
    if(global.COMPARE_MODE > 0.5 && abs(vTexCoord.x - 0.5) < 0.002) {
        finalColor = vec3(0.0);
    }

    // Output in linear space (sRGB conversion happens in mask pass or if mask is off)
    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}
