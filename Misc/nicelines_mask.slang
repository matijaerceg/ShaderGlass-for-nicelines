#version 450

// === PASS 1: SHADOW MASK ===
// This pass handles: pixel swap mode, triad phosphor mask
// Input: fully processed scanline image from pass 0

// === SHADOW MASK PARAMETERS ===
#pragma parameter SUBPIXEL_NOISE "SHADOW MASK Off/Swap/Triad" 2.0 0.0 2.0 1.0
#pragma parameter SHADOW_STRENGTH "Shadow Mask STRENGTH (1-3)" 2.0 1.0 3.0 1.0
#pragma parameter SHIMMER_NOISE "Shimmering NOISE Effect (Requires Shadow Mask Effect ON)" 0.0 0.0 1.0 1.0

// === TRIAD PARAMETERS ===
#pragma parameter PHOSPHOR_WIDTH "TRIAD Phosphor Width (px)" 1.0 1.0 20.0 1.0
#pragma parameter TRIAD_HEIGHT "TRIAD Height (px)" 1.0 1.0 20.0 1.0
#pragma parameter SPILLOVER_MODE "TRIAD Spillover (Linear/Curved)" 0.0 0.0 1.0 1.0
#pragma parameter CURVE_PRIMARY "TRIAD Curve PRIMARY (0=linear, -=concave, +=convex)" 0.0 -3.0 3.0 0.1
#pragma parameter CURVE_SECONDARY "TRIAD Curve SECONDARY (0=linear, -=concave, +=convex)" 0.0 -3.0 3.0 0.1
#pragma parameter CURVE_TERTIARY "TRIAD Curve TERTIARY (0=linear, -=concave, +=convex)" 0.0 -3.0 3.0 0.1

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float SUBPIXEL_NOISE;
    float SHADOW_STRENGTH;
    float SHIMMER_NOISE;
    float PHOSPHOR_WIDTH;
    float TRIAD_HEIGHT;
    float SPILLOVER_MODE;
    float CURVE_PRIMARY;
    float CURVE_SECONDARY;
    float CURVE_TERTIARY;
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
layout(set = 0, binding = 2) uniform sampler2D Source;  // Pass 0 output (scanlines)

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

void main() {
    vec2 px = vTexCoord * global.OutputSize.xy;
    
    // Mode selection: 0=off, 1=swap, 2=triad
    int shadowMode = int(global.SUBPIXEL_NOISE + 0.5);
    
    // === MODE 0: No shadow mask - passthrough ===
    if(shadowMode == 0) {
        FragColor = texture(Source, vTexCoord);
        return;
    }
    
    // === MODE 1: Pixel swap shadow mask ===
    if(shadowMode == 1) {
        // Seed: random each frame if shimmer enabled, otherwise fixed
        float seed = (global.SHIMMER_NOISE > 0.5) ? float(global.FrameCount) : 0.0;
        
        // Swap range directly from strength setting (1, 2, or 3)
        float swapRange = global.SHADOW_STRENGTH;
        
        // Calculate pixels per scanline (approximate from source/output ratio)
        float pixelsPerScanline = global.OutputSize.y / global.SourceSize.y;
        
        vec2 srcPx = px;
        
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
        
        // Convert displaced pixel position to UV and sample
        vec2 displacedUV = srcPx / global.OutputSize.xy;
        displacedUV = clamp(displacedUV, vec2(0.0), vec2(1.0));
        
        FragColor = texture(Source, displacedUV);
        return;
    }
    
    // === MODE 2: Triad-based shadow mask ===
    float phosphorW = global.PHOSPHOR_WIDTH;
    float triadW = phosphorW * 3.0;  // Total triad width = 3 phosphors
    float triadH = global.TRIAD_HEIGHT;
    
    // Which triad column are we in?
    float triadIdxX = floor(px.x / triadW);
    float withinTriadX = mod(px.x, triadW);
    int phosphorIdx = int(floor(withinTriadX / phosphorW));  // 0=left, 1=middle, 2=right
    phosphorIdx = min(phosphorIdx, 2);  // Clamp to valid range
    
    // Vertical zigzag offset for alternating columns (when triad height > 1)
    // Offset = ceil(triadH / 2) for odd columns
    float zigzagOffset = 0.0;
    if(triadH > 1.0 && mod(triadIdxX, 2.0) >= 1.0) {
        zigzagOffset = ceil(triadH / 2.0);
    }
    
    // Apply zigzag to Y position before calculating triad row
    float adjustedPxY = px.y - zigzagOffset;
    float triadIdxY = floor(adjustedPxY / triadH);
    
    // === AREA SAMPLING: Integrate the ENTIRE triad footprint ===
    // Sample the already-processed scanline image from pass 0
    // Triad bounds in output pixel space (with zigzag applied)
    float triadLeftPx = triadIdxX * triadW;
    float triadTopPx = triadIdxY * triadH + zigzagOffset;
    
    // Sample grid: one sample per output pixel in the triad
    int samplesX = max(int(triadW), 1);
    int samplesY = max(int(triadH), 1);
    
    vec3 totalEnergy = vec3(0.0);
    float sampleCount = 0.0;
    
    for(int sy = 0; sy < samplesY; sy++) {
        for(int sx = 0; sx < samplesX; sx++) {
            // Output pixel position (center of each pixel in the triad)
            float samplePxX = triadLeftPx + float(sx) + 0.5;
            float samplePxY = triadTopPx + float(sy) + 0.5;
            
            // Convert to UV
            vec2 sampleUV = vec2(samplePxX, samplePxY) / global.OutputSize.xy;
            sampleUV = clamp(sampleUV, vec2(0.0), vec2(1.0));
            
            // Sample the already-processed scanline image (pass 0 output)
            vec3 sampleColor = SrgbToLinear3(texture(Source, sampleUV).rgb);
            
            totalEnergy += sampleColor;
            sampleCount += 1.0;
        }
    }
    
    // Average processed color in the triad area
    vec3 avgColor = totalEnergy / sampleCount;
    
    // Total energy to distribute across 3 phosphors (multiply by 3)
    float totalRed = avgColor.r * 3.0;
    float totalGreen = avgColor.g * 3.0;
    float totalBlue = avgColor.b * 3.0;
    
    // Spillover distribution
    float redLeft, redMiddle, redRight;
    float greenLeft, greenMiddle, greenRight;
    float blueLeft, blueMiddle, blueRight;
    
    if(global.SPILLOVER_MODE < 0.5) {
        // === LINEAR SPILLOVER ===
        // Distribute RED: left first, then right, then middle
        redLeft = min(totalRed, 1.0);
        float redRemaining = max(totalRed - 1.0, 0.0);
        redRight = min(redRemaining, 1.0);
        redRemaining = max(redRemaining - 1.0, 0.0);
        redMiddle = min(redRemaining, 1.0);
        
        // Distribute GREEN: middle first, then left, then right
        greenMiddle = min(totalGreen, 1.0);
        float greenRemaining = max(totalGreen - 1.0, 0.0);
        greenLeft = min(greenRemaining, 1.0);
        greenRemaining = max(greenRemaining - 1.0, 0.0);
        greenRight = min(greenRemaining, 1.0);
        
        // Distribute BLUE: right first, then middle, then left
        blueRight = min(totalBlue, 1.0);
        float blueRemaining = max(totalBlue - 1.0, 0.0);
        blueMiddle = min(blueRemaining, 1.0);
        blueRemaining = max(blueRemaining - 1.0, 0.0);
        blueLeft = min(blueRemaining, 1.0);
    } else {
        // === CURVED SPILLOVER ===
        // Each tier has its own curve: slider 0 = linear, negative = concave, positive = convex
        // Exponent = 2^slider: -1 → 0.5 (concave), 0 → 1 (linear), +1 → 2 (convex)
        float expPrimary = pow(2.0, global.CURVE_PRIMARY);
        float expSecondary = pow(2.0, global.CURVE_SECONDARY);
        float expTertiary = pow(2.0, global.CURVE_TERTIARY);
        
        // RED: primary=left, secondary=right, tertiary=middle
        float rNorm = totalRed / 3.0;  // Normalize to 0-1 range
        redLeft = pow(clamp(rNorm, 0.0, 1.0), expPrimary);
        redRight = pow(clamp(rNorm, 0.0, 1.0), expSecondary);
        redMiddle = pow(clamp(rNorm, 0.0, 1.0), expTertiary);
        
        // GREEN: primary=middle, secondary=left, tertiary=right
        float gNorm = totalGreen / 3.0;
        greenMiddle = pow(clamp(gNorm, 0.0, 1.0), expPrimary);
        greenLeft = pow(clamp(gNorm, 0.0, 1.0), expSecondary);
        greenRight = pow(clamp(gNorm, 0.0, 1.0), expTertiary);
        
        // BLUE: primary=right, secondary=middle, tertiary=left
        float bNorm = totalBlue / 3.0;
        blueRight = pow(clamp(bNorm, 0.0, 1.0), expPrimary);
        blueMiddle = pow(clamp(bNorm, 0.0, 1.0), expSecondary);
        blueLeft = pow(clamp(bNorm, 0.0, 1.0), expTertiary);
    }
    
    // Select the color values for this phosphor
    vec3 finalColor;
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

    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}
