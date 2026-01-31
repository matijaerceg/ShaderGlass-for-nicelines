#version 450

// === PARAMETERS ===
#pragma parameter COMPARE_MODE "[v26] Half Screen COMPARE" 0.0 0.0 1.0 1.0
#pragma parameter SCANLINE_MODE "SCANLINES MODE (224p / 240p / Manual)" 0.0 0.0 2.0 1.0
#pragma parameter MANUAL_LINES "MANUAL Mode: Number of Scanlines" 360.0 120.0 480.0 5.0
#pragma parameter FINETUNE_LINES "FINETUNE Number of Scanlines" 0.0 -5.0 5.0 1.0
#pragma parameter AUTO_LINES "ROUND Number of Scanlines to Nearest Multiple of Resolution (Recommend OFF for 2D games, ON for 3D;)" 0.0 0.0 1.0 1.0
#pragma parameter BLUR_OFFSET "DOWNSCALING Prepass (Lower = Softer)" 0.04 -0.04 0.12 0.01
#pragma parameter H_BLUR "HORIZONTAL BLUR (worn out tube look)" 1.0 0.0 8.0 0.1

// === SUBPIXEL NOISE PARAMETERS ===
#pragma parameter SUBPIXEL_NOISE "SHADOW MASK Off/Swap/Triad" 1.0 0.0 2.0 1.0
#pragma parameter SHADOW_STRENGTH "Shadow Mask STRENGTH (1-3)" 2.0 1.0 3.0 1.0
#pragma parameter SHIMMER_NOISE "Shimmering NOISE Effect (Requires Shadow Mask Effect ON)" 0.0 0.0 1.0 1.0

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
    float SUBPIXEL_NOISE;
    float SHADOW_STRENGTH;
    float SHIMMER_NOISE;
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
    
    // Pixels per scanline (for subpixel noise phase calculation)
    float pixelsPerScanline = global.OutputSize.y / targetLines;
    
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
    
    // === SUBPIXEL NOISE: Calculate displaced sample position ===
    vec2 px = vTexCoord * global.OutputSize.xy;
    vec2 srcPx = px;
    
    // Mode selection: 0=off, 1=swap, 2=triad
    int shadowMode = int(global.SUBPIXEL_NOISE + 0.5);
    
    if(shadowMode == 1) {
        // Mode 1: Original horizontal swap shadow mask
        // Seed: random each frame if shimmer enabled, otherwise fixed
        float seed = (global.SHIMMER_NOISE > 0.5) ? float(global.FrameCount) : 0.0;
        
        // --- HORIZONTAL SWAP ---
        // Swap range directly from strength setting (1, 2, or 3)
        float swapRange = global.SHADOW_STRENGTH;
        if(swapRange > 0.5) {
            // Phase height is a factor of scanline pitch, rounded to integer fat-pixels (locked at 0.8)
            float phaseH = max(1.0, floor(pixelsPerScanline * 0.8 + 0.5));
            
            float groupWidth = swapRange * 2.0;
            float groupIdx = floor(px.x / groupWidth);
            float withinGroup = mod(px.x, groupWidth);
            
            float rowPhase = floor(px.y / phaseH);
            
            float swapOffset = 0.0;
            if(mod(rowPhase, 2.0) < 1.0) {
                swapOffset = groupWidth - 1.0 - 2.0 * withinGroup;
            } else {
                swapOffset = mod(withinGroup + swapRange, groupWidth) - withinGroup;
            }
            
            float chaos = sin((groupIdx + rowPhase) * 2.718 + seed) * swapRange * 0.5;
            swapOffset += chaos;
            
            srcPx.x += swapOffset;
        }
    }
    
    // Convert displaced pixel position to UV
    vec2 displacedUV = srcPx / global.OutputSize.xy;
    displacedUV = clamp(displacedUV, vec2(0.0), vec2(1.0));
    
    // Calculate scanline position for displaced UV (CENTER-ANCHORED)
    float distFromCenter = displacedUV.y - 0.5;
    float scanlineOffset = distFromCenter * targetLines;
    float scanlinePos = scanlineOffset;
    float scanlineIndex = floor(scanlinePos);
    
    // Sample at scanline center
    float sampleScanlinePos = scanlineIndex + 0.5;
    float sampleDistFromCenter = sampleScanlinePos / targetLines;
    vec2 sampleUV = vec2(displacedUV.x, clamp(0.5 + sampleDistFromCenter, 0.0, 1.0));
    
    float withinScanline = fract(scanlinePos);
    
    // Sample source with blur
    vec3 color = sampleWithBlur(sampleUV, effectiveScale);
    color = SrgbToLinear3(color);
    
    // Calculate scanline width and energy-preserved color
    float scanlineWidth = calcScanlineWidth(color, baseWidth, minWidth, maxWidth);
    vec3 outputColor = clamp(color / scanlineWidth, 0.0, 1.0);
    
    // Scanline mask with soft edges
    float scanlineMask = 1.0;
    vec3 finalColor;
    float halfGap = (1.0 - scanlineWidth) * 0.5;
    
    scanlineMask = smoothstep(halfGap - edgeSoftness, halfGap + edgeSoftness, withinScanline) *
                   smoothstep(1.0 - halfGap + edgeSoftness, 1.0 - halfGap - edgeSoftness, withinScanline);
    
    finalColor = outputColor * scanlineMask;
    
    // Horizontal blur on final output (cheap 5-tap tent filter)
    if(global.H_BLUR > 0.001) {
        float pixelSize = 1.0 / global.OutputSize.x;
        float blurRadius = global.H_BLUR * pixelSize;
        
        vec2 uvL1 = vec2(displacedUV.x - blurRadius * 0.5, sampleUV.y);
        vec2 uvL2 = vec2(displacedUV.x - blurRadius, sampleUV.y);
        vec2 uvR1 = vec2(displacedUV.x + blurRadius * 0.5, sampleUV.y);
        vec2 uvR2 = vec2(displacedUV.x + blurRadius, sampleUV.y);
        
        vec3 srcL1 = SrgbToLinear3(sampleWithBlur(uvL1, effectiveScale));
        vec3 srcL2 = SrgbToLinear3(sampleWithBlur(uvL2, effectiveScale));
        vec3 srcR1 = SrgbToLinear3(sampleWithBlur(uvR1, effectiveScale));
        vec3 srcR2 = SrgbToLinear3(sampleWithBlur(uvR2, effectiveScale));
        
        float wL1 = calcScanlineWidth(srcL1, baseWidth, minWidth, maxWidth);
        float wL2 = calcScanlineWidth(srcL2, baseWidth, minWidth, maxWidth);
        float wR1 = calcScanlineWidth(srcR1, baseWidth, minWidth, maxWidth);
        float wR2 = calcScanlineWidth(srcR2, baseWidth, minWidth, maxWidth);
        
        vec3 cL1 = clamp(srcL1 / wL1, 0.0, 1.0) * scanlineMask;
        vec3 cL2 = clamp(srcL2 / wL2, 0.0, 1.0) * scanlineMask;
        vec3 cR1 = clamp(srcR1 / wR1, 0.0, 1.0) * scanlineMask;
        vec3 cR2 = clamp(srcR2 / wR2, 0.0, 1.0) * scanlineMask;
        
        finalColor = (cL2 * 0.1 + cL1 * 0.2 + finalColor * 0.4 + cR1 * 0.2 + cR2 * 0.1);
    }
    
    // Compare mode divider line
    if(global.COMPARE_MODE > 0.5 && abs(vTexCoord.x - 0.5) < 0.002) {
        finalColor = vec3(0.0);
    }

    // === MODE 2: TRIAD-BASED SHADOW MASK (APPLIED LAST) ===
    // 3x1 output pixels form one triad, containing three 1x1 phosphors (left/middle/right)
    if(shadowMode == 2) {
        // Which triad are we in, and which phosphor within it?
        float triadIdx = floor(px.x / 3.0);
        int phosphorIdx = int(mod(px.x, 3.0));  // 0=left, 1=middle, 2=right
        
        // Sample the source at the CENTER of this triad (all pixels in triad use same color)
        float triadCenterX = (triadIdx * 3.0 + 1.5) / global.OutputSize.x;
        vec2 triadCenterUV = vec2(triadCenterX, sampleUV.y);
        
        // Get the color at triad center, processed through scanlines
        vec3 triadColor = SrgbToLinear3(sampleWithBlur(triadCenterUV, effectiveScale));
        float triadWidth = calcScanlineWidth(triadColor, baseWidth, minWidth, maxWidth);
        vec3 triadOutput = clamp(triadColor / triadWidth, 0.0, 1.0) * scanlineMask;
        
        // Apply brightness boost to triad color
        triadOutput *= 1.1;
        
        // Total energy is 3x the color (spreading across 3 phosphors)
        float totalRed = triadOutput.r * 3.0;
        float totalGreen = triadOutput.g * 3.0;
        float totalBlue = triadOutput.b * 3.0;
        
        // Distribute RED: left first, then right, then middle
        float redLeft = min(totalRed, 1.0);
        float redRemaining = max(totalRed - 1.0, 0.0);
        float redRight = min(redRemaining, 1.0);
        redRemaining = max(redRemaining - 1.0, 0.0);
        float redMiddle = min(redRemaining, 1.0);
        
        // Distribute GREEN: middle first, then left, then right
        float greenMiddle = min(totalGreen, 1.0);
        float greenRemaining = max(totalGreen - 1.0, 0.0);
        float greenLeft = min(greenRemaining, 1.0);
        greenRemaining = max(greenRemaining - 1.0, 0.0);
        float greenRight = min(greenRemaining, 1.0);
        
        // Distribute BLUE: right first, then middle, then left
        float blueRight = min(totalBlue, 1.0);
        float blueRemaining = max(totalBlue - 1.0, 0.0);
        float blueMiddle = min(blueRemaining, 1.0);
        blueRemaining = max(blueRemaining - 1.0, 0.0);
        float blueLeft = min(blueRemaining, 1.0);
        
        // Select the color values for this phosphor
        if(phosphorIdx == 0) {
            // Left phosphor
            finalColor = vec3(redLeft, greenLeft, blueLeft);
        } else if(phosphorIdx == 1) {
            // Middle phosphor
            finalColor = vec3(redMiddle, greenMiddle, blueMiddle);
        } else {
            // Right phosphor
            finalColor = vec3(redRight, greenRight, blueRight);
        }
    } else {
        // Apply brightness boost for non-triad modes (moved here to avoid double-apply)
        finalColor *= 1.1;
    }

    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}
