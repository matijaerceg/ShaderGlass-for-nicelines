#version 450

// === PARAMETERS ===
#pragma parameter SCANLINE_MODE "Mode (0=224p, 1=240p, 2=Manual)" 0.0 0.0 2.0 1.0
#pragma parameter MANUAL_LINES "Manual Scanline Count" 240.0 120.0 480.0 10.0
#pragma parameter AUTO_LINES "Auto Adjust Num Scanlines for Resolution" 0.0 0.0 1.0 1.0
#pragma parameter BLUR_OFFSET "Downscaling Resolution" 0.04 -0.04 0.12 0.01
#pragma parameter BASE_WIDTH "Scanline Thickness Baseline" 0.3 0.2 0.8 0.05
#pragma parameter MIN_WIDTH "Scanline Thickness Min (dark)" 0.5 0.1 0.5 0.05
#pragma parameter MAX_WIDTH "Scanline Thickness Max (bright)" 1.0 0.7 1.0 0.05
#pragma parameter VERTICAL_SOFT "Vertical Softening" 0.0 0.0 1.0 1.0
#pragma parameter VERTICAL_AMOUNT "Vertical Softening Amount" 0.5 0.0 1.0 0.05
#pragma parameter H_BLUR "Horizontal Blur" 1.0 0.0 4.0 0.1
#pragma parameter COMPARE_MODE "Half/Half" 0.0 0.0 1.0 1.0
#pragma parameter DEBUG_INFO "Debug Info" 0.0 0.0 1.0 1.0

// === TRIAD PHOSPHOR PARAMETERS ===
#pragma parameter TRIAD_MODE "Pixel Mode (0=Off, 1=Collapse, 2=Lottes, 3=Noise)" 1.0 0.0 3.0 1.0
#pragma parameter TRIAD_BOOST "Collapse: Brightness Boost" 3.3 2.5 4.5 0.1
#pragma parameter TRIAD_HEIGHT "Triad Cell Height (pixels)" 1.0 1.0 16.0 1.0
#pragma parameter TRIAD_OFFSET "Zigzag Offset Amount" 0.0 0.0 1.0 0.1
#pragma parameter TRIAD_DARK "Lottes: Non-lit Phosphor Darkness" 0.5 0.0 1.0 0.05

// === SUBPIXEL NOISE PARAMETERS (Mode 3) ===
#pragma parameter NOISE_ZIGZAG_AMP "Noise: Vertical Zigzag Amplitude" 1.0 0.0 4.0 0.25
#pragma parameter NOISE_ZIGZAG_PITCH "Noise: Zigzag Pitch (pixels)" 6.0 2.0 24.0 1.0
#pragma parameter NOISE_ZIGZAG_HARMONICS "Noise: Zigzag Complexity" 0.5 0.0 1.0 0.1
#pragma parameter NOISE_SWAP_RANGE "Noise: Horizontal Swap Range" 2.0 0.0 8.0 1.0
#pragma parameter NOISE_SWAP_PHASE "Noise: Swap Pattern Height" 4.0 1.0 16.0 1.0
#pragma parameter NOISE_DIAGONAL "Noise: Diagonal Shear" 0.0 0.0 2.0 0.25
#pragma parameter NOISE_SEED "Noise: Pattern Seed" 0.0 0.0 99.0 1.0

layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float SCANLINE_MODE;
    float MANUAL_LINES;
    float AUTO_LINES;
    float BLUR_OFFSET;
    float BASE_WIDTH;
    float MIN_WIDTH;
    float MAX_WIDTH;
    float VERTICAL_SOFT;
    float VERTICAL_AMOUNT;
    float H_BLUR;
    float COMPARE_MODE;
    float DEBUG_INFO;
    float TRIAD_MODE;
    float TRIAD_BOOST;
    float TRIAD_HEIGHT;
    float TRIAD_OFFSET;
    float TRIAD_DARK;
    float NOISE_ZIGZAG_AMP;
    float NOISE_ZIGZAG_PITCH;
    float NOISE_ZIGZAG_HARMONICS;
    float NOISE_SWAP_RANGE;
    float NOISE_SWAP_PHASE;
    float NOISE_DIAGONAL;
    float NOISE_SEED;
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

// === 7-SEGMENT LCD DEBUG DISPLAY ===
// Segment layout:  AAA
//                 F   B
//                  GGG
//                 E   C
//                  DDD
// Bits: 0bGFEDCBA

const int SEG[10] = int[10](0x3F,0x06,0x5B,0x4F,0x66,0x6D,0x7D,0x07,0x7F,0x6F);

float segH(vec2 p, float y) {
    return (abs(p.y - y) < 0.09 && abs(p.x - 0.5) < 0.35) ? 1.0 : 0.0;
}
float segV(vec2 p, float x, float y0, float y1) {
    float yc = (y0 + y1) * 0.5;
    return (abs(p.x - x) < 0.09 && abs(p.y - yc) < (y1 - y0) * 0.5 - 0.02) ? 1.0 : 0.0;
}

float draw7Seg(vec2 p, int d) {
    if(d < 0 || d > 9) return 0.0;
    int s = SEG[d];
    float r = 0.0;
    if((s & 1) != 0) r = max(r, segH(p, 0.92));      // A
    if((s & 2) != 0) r = max(r, segV(p, 0.88, 0.54, 0.88)); // B
    if((s & 4) != 0) r = max(r, segV(p, 0.88, 0.12, 0.46)); // C
    if((s & 8) != 0) r = max(r, segH(p, 0.08));      // D
    if((s & 16) != 0) r = max(r, segV(p, 0.12, 0.12, 0.46)); // E
    if((s & 32) != 0) r = max(r, segV(p, 0.12, 0.54, 0.88)); // F
    if((s & 64) != 0) r = max(r, segH(p, 0.50));     // G
    return r;
}

float renderNum(float val, vec2 px, vec2 pos, float w, float h, int digits) {
    int v = int(abs(val) + 0.5);
    float r = 0.0;
    for(int i = 0; i < digits; i++) {
        vec2 dp = pos + vec2(float(digits - 1 - i) * w * 1.15, 0.0);
        vec2 p = (px - dp) / vec2(w, h);
        p.y = 1.0 - p.y; // Flip Y coordinate
        if(p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
            int div = 1;
            for(int j = 0; j < i; j++) { div *= 10; }
            int digit = (v / div) % 10;
            if(i == 0 || v >= div) r = max(r, draw7Seg(p, digit));
        }
    }
    return r;
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
    // This eliminates the hard edge that causes color banding
    float blendZone = 0.1; // 10% blend zone
    float blend = smoothstep(baseWidth - blendZone * baseWidth, baseWidth + blendZone * baseWidth, maxColorChannel);
    
    return mix(darkWidth, brightWidth, blend);
}

void main() {
    // === PIXEL COUNTING WIZARD MODE ===
    // Shows source dimensions to help manually count scanlines
    if(global.DEBUG_INFO > 0.5) {
        vec2 px = vTexCoord * global.OutputSize.xy;
        
        // Display source dimensions at top of screen
        if(px.y < 80.0) {
            vec3 debugColor = vec3(0.0);
            
            float digitH = 24.0;
            float digitW = digitH * 0.6;
            float text = 0.0;
            
            // Row 1: Source height (pixels)
            text += renderNum(global.SourceSize.y, px, vec2(10.0, 10.0), digitW, digitH, 4);
            // Row 2: Source width (pixels)
            text += renderNum(global.SourceSize.x, px, vec2(10.0, 45.0), digitW, digitH, 4);
            
            debugColor = mix(debugColor, vec3(0.0, 1.0, 0.5), text);
            FragColor = vec4(debugColor, 1.0);
            return;
        }
        
        // Show source image (useful for manual pixel counting)
        vec3 srcColor = texture(Source, vTexCoord).rgb;
        FragColor = vec4(srcColor, 1.0);
        return;
    }
    
    // === NORMAL MODE: Scanline processing ===
    float baseWidth = global.BASE_WIDTH;
    float minWidth = global.MIN_WIDTH;
    float maxWidth = global.MAX_WIDTH;
    
    // Determine target scanline count based on mode
    // Mode 0 = 224p, Mode 1 = 240p, Mode 2 = Manual
    float targetLines;
    int mode = int(global.SCANLINE_MODE + 0.5);
    if(mode == 0) {
        targetLines = 224.0;
    } else if(mode == 1) {
        targetLines = 240.0;
    } else {
        // Manual mode (mode == 2): use MANUAL_LINES slider
        targetLines = global.MANUAL_LINES;
    }
    
    // Auto-fit: find nearest factor of output height to target
    if(global.AUTO_LINES > 0.5) {
        float outputHeight = global.OutputSize.y;
        float idealPixelsPerLine = outputHeight / targetLines;
        float pixelsPerLine = max(1.0, round(idealPixelsPerLine));
        targetLines = outputHeight / pixelsPerLine;
    }
    
    // Compare mode: right half shows original
    if(global.COMPARE_MODE > 0.5 && vTexCoord.x > 0.5) {
        vec3 color = texture(Source, vTexCoord).rgb;
        FragColor = vec4(color, 1.0);
        return;
    }
    
    // Calculate scanline position (CENTER-ANCHORED)
    // This ensures adjusting targetLines expands/contracts from screen center
    float distFromCenter = vTexCoord.y - 0.5; // -0.5 to +0.5
    float scanlineOffset = distFromCenter * targetLines; // scanlines from center
    float scanlinePos = scanlineOffset;
    float scanlineIndex = floor(scanlinePos);
    
    // Sample at scanline center (center-anchored)
    float sampleScanlinePos = scanlineIndex + 0.5;
    float sampleDistFromCenter = sampleScanlinePos / targetLines;
    vec2 sampleUV = vec2(vTexCoord.x, clamp(0.5 + sampleDistFromCenter, 0.0, 1.0));
    
    float withinScanline = fract(scanlinePos);
    
    vec3 color;
    
    // Source blur: baseline matches target resolution, offset adjusts from there
    // Baseline scale = targetLines / sourceHeight (e.g., 240/1080 = 0.222)
    // Offset 0 = baseline blur, positive = sharper, negative = blurrier
    float baselineScale = targetLines / global.SourceSize.y;
    float effectiveScale = clamp(baselineScale + global.BLUR_OFFSET, 0.02, 1.0);
    
    if(effectiveScale < 0.999) {
        // Calculate blur radius based on effective scale
        float blurRadius = (1.0 / effectiveScale - 1.0) * 0.5;
        vec2 texelSize = 1.0 / global.SourceSize.xy;
        vec2 radius = texelSize * blurRadius;
        
        // 9-tap box filter for area averaging
        vec3 sum = vec3(0.0);
        sum += texture(Source, sampleUV + vec2(-radius.x, -radius.y)).rgb;
        sum += texture(Source, sampleUV + vec2(      0.0, -radius.y)).rgb;
        sum += texture(Source, sampleUV + vec2( radius.x, -radius.y)).rgb;
        sum += texture(Source, sampleUV + vec2(-radius.x,       0.0)).rgb;
        sum += texture(Source, sampleUV).rgb;
        sum += texture(Source, sampleUV + vec2( radius.x,       0.0)).rgb;
        sum += texture(Source, sampleUV + vec2(-radius.x,  radius.y)).rgb;
        sum += texture(Source, sampleUV + vec2(      0.0,  radius.y)).rgb;
        sum += texture(Source, sampleUV + vec2( radius.x,  radius.y)).rgb;
        color = sum / 9.0;
    } else {
        color = texture(Source, sampleUV).rgb;
    }
    
    color = SrgbToLinear3(color);
    
    // Calculate scanline width and energy-preserved color
    float scanlineWidth = calcScanlineWidth(color, baseWidth, minWidth, maxWidth);
    vec3 outputColor = color / scanlineWidth;
    outputColor = clamp(outputColor, 0.0, 1.0);
    
    // Pixel offset in UV space (for H_BLUR)
    float pixelSize = 1.0 / global.OutputSize.x;
    
    // Scanline mask (centered)
    float halfGap = (1.0 - scanlineWidth) * 0.5;
    
    // Edge softness calculation (resolution-independent, works in scanline-normalized space)
    // Base softness is a fraction of scanline height (0.05 = 5% of one scanline)
    float baseEdgeSoftness = 0.05;
    
    // Vertical softening: increase edge softness for softer/glowier scanlines
    float edgeSoftness = baseEdgeSoftness;
    if(global.VERTICAL_SOFT > 0.5) {
        // Exponential curve: pow(x, 2.5) makes slider less sensitive at low values
        float curvedAmount = pow(global.VERTICAL_AMOUNT, 2.5);
        // Extra softness up to ~25% of scanline height at max
        float extraSoftness = curvedAmount * 0.25;
        edgeSoftness = baseEdgeSoftness + extraSoftness;
    }
    
    float scanlineMask = smoothstep(halfGap - edgeSoftness, halfGap + edgeSoftness, withinScanline) *
                         smoothstep(1.0 - halfGap + edgeSoftness, 1.0 - halfGap - edgeSoftness, withinScanline);
    
    vec3 finalColor = outputColor * scanlineMask;
    
    // Horizontal blur on final output (cheap 5-tap tent filter)
    if(global.H_BLUR > 0.001) {
        float blurRadius = global.H_BLUR * pixelSize;
        
        // Sample positions for blur
        vec2 uvL1 = vec2(vTexCoord.x - blurRadius * 0.5, sampleUV.y);
        vec2 uvL2 = vec2(vTexCoord.x - blurRadius, sampleUV.y);
        vec2 uvR1 = vec2(vTexCoord.x + blurRadius * 0.5, sampleUV.y);
        vec2 uvR2 = vec2(vTexCoord.x + blurRadius, sampleUV.y);
        
        // Sample neighbors (with same blur if active)
        vec3 srcL1, srcL2, srcR1, srcR2;
        
        if(effectiveScale < 0.999) {
            // Apply same blur to neighbor samples
            float dsBlurRadius = (1.0 / effectiveScale - 1.0) * 0.5;
            vec2 texelSize = 1.0 / global.SourceSize.xy;
            vec2 dsRadius = texelSize * dsBlurRadius;
            
            // 9-tap for L1
            vec3 sum = vec3(0.0);
            sum += texture(Source, uvL1 + vec2(-dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvL1 + vec2(0.0, -dsRadius.y)).rgb;
            sum += texture(Source, uvL1 + vec2(dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvL1 + vec2(-dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvL1).rgb;
            sum += texture(Source, uvL1 + vec2(dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvL1 + vec2(-dsRadius.x, dsRadius.y)).rgb;
            sum += texture(Source, uvL1 + vec2(0.0, dsRadius.y)).rgb;
            sum += texture(Source, uvL1 + vec2(dsRadius.x, dsRadius.y)).rgb;
            srcL1 = SrgbToLinear3(sum / 9.0);
            
            // 9-tap for L2
            sum = vec3(0.0);
            sum += texture(Source, uvL2 + vec2(-dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvL2 + vec2(0.0, -dsRadius.y)).rgb;
            sum += texture(Source, uvL2 + vec2(dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvL2 + vec2(-dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvL2).rgb;
            sum += texture(Source, uvL2 + vec2(dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvL2 + vec2(-dsRadius.x, dsRadius.y)).rgb;
            sum += texture(Source, uvL2 + vec2(0.0, dsRadius.y)).rgb;
            sum += texture(Source, uvL2 + vec2(dsRadius.x, dsRadius.y)).rgb;
            srcL2 = SrgbToLinear3(sum / 9.0);
            
            // 9-tap for R1
            sum = vec3(0.0);
            sum += texture(Source, uvR1 + vec2(-dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvR1 + vec2(0.0, -dsRadius.y)).rgb;
            sum += texture(Source, uvR1 + vec2(dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvR1 + vec2(-dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvR1).rgb;
            sum += texture(Source, uvR1 + vec2(dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvR1 + vec2(-dsRadius.x, dsRadius.y)).rgb;
            sum += texture(Source, uvR1 + vec2(0.0, dsRadius.y)).rgb;
            sum += texture(Source, uvR1 + vec2(dsRadius.x, dsRadius.y)).rgb;
            srcR1 = SrgbToLinear3(sum / 9.0);
            
            // 9-tap for R2
            sum = vec3(0.0);
            sum += texture(Source, uvR2 + vec2(-dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvR2 + vec2(0.0, -dsRadius.y)).rgb;
            sum += texture(Source, uvR2 + vec2(dsRadius.x, -dsRadius.y)).rgb;
            sum += texture(Source, uvR2 + vec2(-dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvR2).rgb;
            sum += texture(Source, uvR2 + vec2(dsRadius.x, 0.0)).rgb;
            sum += texture(Source, uvR2 + vec2(-dsRadius.x, dsRadius.y)).rgb;
            sum += texture(Source, uvR2 + vec2(0.0, dsRadius.y)).rgb;
            sum += texture(Source, uvR2 + vec2(dsRadius.x, dsRadius.y)).rgb;
            srcR2 = SrgbToLinear3(sum / 9.0);
        } else {
            srcL1 = SrgbToLinear3(texture(Source, uvL1).rgb);
            srcL2 = SrgbToLinear3(texture(Source, uvL2).rgb);
            srcR1 = SrgbToLinear3(texture(Source, uvR1).rgb);
            srcR2 = SrgbToLinear3(texture(Source, uvR2).rgb);
        }
        
        // Apply same scanline mask to neighbors and blend
        float wL1 = calcScanlineWidth(srcL1, baseWidth, minWidth, maxWidth);
        float wL2 = calcScanlineWidth(srcL2, baseWidth, minWidth, maxWidth);
        float wR1 = calcScanlineWidth(srcR1, baseWidth, minWidth, maxWidth);
        float wR2 = calcScanlineWidth(srcR2, baseWidth, minWidth, maxWidth);
        
        vec3 cL1 = clamp(srcL1 / wL1, 0.0, 1.0) * scanlineMask;
        vec3 cL2 = clamp(srcL2 / wL2, 0.0, 1.0) * scanlineMask;
        vec3 cR1 = clamp(srcR1 / wR1, 0.0, 1.0) * scanlineMask;
        vec3 cR2 = clamp(srcR2 / wR2, 0.0, 1.0) * scanlineMask;
        
        // Tent filter weights: 1-2-4-2-1 = 10 total
        finalColor = (cL2 * 0.1 + cL1 * 0.2 + finalColor * 0.4 + cR1 * 0.2 + cR2 * 0.1);
    }
    
    // Compare mode divider line
    if(global.COMPARE_MODE > 0.5 && abs(vTexCoord.x - 0.5) < 0.002) {
        finalColor = vec3(0.0);
    }

    // === PHOSPHOR TRIAD MODES ===
    // 0 = off, 1 = spatial collapse (energy-conserving), 2 = Lottes slot mask (arcade)
    if(global.TRIAD_MODE > 0.1) {
        vec2 px = vTexCoord * global.OutputSize.xy;
        
        // Determine which phosphor (R=0, G=1, B=2) based on x position
        int rgbIndex = int(mod(floor(px.x), 3.0));
        
        vec3 triadColor = vec3(0.0);
        
        if(abs(global.TRIAD_MODE - 1.0) < 0.1) {
            // === COLLAPSE MODE ===
            // Each phosphor only emits its channel, boosted to maintain brightness.
            // Overflow from clipping redistributes to adjacent phosphors.
            //
            // Boost > 3.0 compensates for perceptual effects:
            // - Spatial averaging isn't perfect at typical viewing distances
            // - High local contrast makes areas appear darker (contrast masking)
            // - 3.0 = mathematically correct, 3.3+ = perceptually matched
            
            float boost = global.TRIAD_BOOST;
            
            for(int ch = 0; ch < 3; ch++) {
                float c = finalColor[ch];
                float totalEnergy = c * boost;
                
                if(rgbIndex == ch) {
                    triadColor[ch] = min(totalEnergy, 1.0);
                } else {
                    float overflow = max(0.0, totalEnergy - 1.0);
                    triadColor[ch] = overflow * 0.5;
                }
            }
            
        } else if(abs(global.TRIAD_MODE - 2.0) < 0.1) {
            // === LOTTES SLOT MASK (ARCADE MODE) ===
            // Pattern: 6 pixels wide (2 triads), 4 pixels tall
            // Bottom 1/4 of each cell is always dark (the "slot")
            
            float dark = global.TRIAD_DARK;
            float triadH = max(1.0, global.TRIAD_HEIGHT);
            
            // Triad column (each triad is 3 pixels wide)
            int triadCol = int(floor(px.x / 3.0));
            
            // Zigzag offset for alternate triads
            float yOffset = 0.0;
            if(mod(float(triadCol), 2.0) >= 1.0) {
                yOffset = triadH * global.TRIAD_OFFSET;
            }
            
            float adjustedY = px.y + yOffset;
            
            // Vertical position within cell (0.0 to 1.0)
            float cellY = fract(adjustedY / triadH);
            
            // Normalization: compensates for dark areas
            // 1/4 of cell is dark, 3/4 is lit with 1 of 3 channels
            float litFraction = 0.75;  // 3/4 of cell height is lit
            float channelFraction = 1.0 / 3.0;  // each channel covers 1/3 width
            float darkContrib = 0.25 * dark;  // dark row contribution
            float litContrib = 0.75 * channelFraction;  // lit phosphor contribution
            float boost = 1.0 / (darkContrib + litContrib);
            
            // Base dark color
            vec3 colD = finalColor * dark;
            
            // Start with dark color everywhere
            triadColor = colD * boost;
            
            // Only light up phosphors in top 3/4 of cell
            if(cellY < 0.75) {
                // Apply RGB phosphor pattern based on horizontal position
                if(rgbIndex == 0) {
                    triadColor.r = finalColor.r * boost;
                } else if(rgbIndex == 1) {
                    triadColor.g = finalColor.g * boost;
                } else {
                    triadColor.b = finalColor.b * boost;
                }
            }
            
            triadColor = clamp(triadColor, 0.0, 1.0);
            
        } else if(abs(global.TRIAD_MODE - 3.0) < 0.1) {
            // === SUBPIXEL NOISE MODE ===
            // Creates texture by displacing pixels without changing colors.
            // All original pixels remain - just rearranged for visual texture.
            
            vec2 srcPx = px;  // Source pixel to sample from
            float seed = global.NOISE_SEED;
            
            // --- VERTICAL ZIGZAG ---
            // Primary sine wave + harmonics for complex zigzag pattern
            if(global.NOISE_ZIGZAG_AMP > 0.01) {
                float pitch = max(2.0, global.NOISE_ZIGZAG_PITCH);
                float phase = px.x * 6.28318 / pitch;
                
                // Base zigzag (sine wave)
                float zigzag = sin(phase + seed);
                
                // Add harmonics for more interesting pattern
                float harm = global.NOISE_ZIGZAG_HARMONICS;
                if(harm > 0.01) {
                    zigzag += harm * 0.5 * sin(phase * 2.0 + seed * 1.7);
                    zigzag += harm * 0.3 * sin(phase * 3.0 + seed * 2.3);
                    zigzag += harm * 0.2 * sin(phase * 5.0 + seed * 3.1);
                    zigzag /= (1.0 + harm);  // Normalize
                }
                
                srcPx.y += zigzag * global.NOISE_ZIGZAG_AMP;
            }
            
            // --- HORIZONTAL SWAP ---
            // Deterministic pixel permutation that varies by row
            if(global.NOISE_SWAP_RANGE > 0.5) {
                float swapRange = global.NOISE_SWAP_RANGE;
                float phaseH = max(1.0, global.NOISE_SWAP_PHASE);
                
                // Which swap group are we in? (groups of swapRange*2 pixels)
                float groupWidth = swapRange * 2.0;
                float groupIdx = floor(px.x / groupWidth);
                float withinGroup = mod(px.x, groupWidth);
                
                // Row-dependent phase shift (pattern changes vertically)
                float rowPhase = floor(px.y / phaseH);
                float rowOffset = mod(rowPhase + seed, 3.0);
                
                // Swap pattern: reverse pixel order within group, with row variation
                float swapOffset = 0.0;
                if(mod(rowPhase, 2.0) < 1.0) {
                    // Even rows: mirror within group
                    swapOffset = groupWidth - 1.0 - 2.0 * withinGroup;
                } else {
                    // Odd rows: shift by half group
                    swapOffset = mod(withinGroup + swapRange, groupWidth) - withinGroup;
                }
                
                // Additional chaos based on position
                float chaos = sin((groupIdx + rowPhase) * 2.718 + seed) * swapRange * 0.5;
                swapOffset += chaos;
                
                srcPx.x += swapOffset;
            }
            
            // --- DIAGONAL SHEAR ---
            // Adds angular displacement based on position
            if(global.NOISE_DIAGONAL > 0.01) {
                float diag = global.NOISE_DIAGONAL;
                // Shear direction alternates in blocks
                float blockSize = 8.0;
                float blockX = floor(px.x / blockSize);
                float blockY = floor(px.y / blockSize);
                float shearDir = mod(blockX + blockY + seed, 2.0) < 1.0 ? 1.0 : -1.0;
                
                srcPx.x += shearDir * diag * mod(px.y, blockSize) / blockSize;
                srcPx.y += shearDir * diag * mod(px.x, blockSize) / blockSize * 0.5;
            }
            
            // --- SAMPLE FROM DISPLACED POSITION ---
            // Convert back to UV and sample the pre-triad finalColor
            // We need to recalculate the scanline output for the displaced position
            vec2 displacedUV = srcPx / global.OutputSize.xy;
            displacedUV = clamp(displacedUV, vec2(0.0), vec2(1.0));
            
            // Recalculate scanline for displaced position
            float dispDistFromCenter = displacedUV.y - 0.5;
            float dispScanlineOffset = dispDistFromCenter * targetLines;
            float dispScanlinePos = dispScanlineOffset;
            float dispScanlineIndex = floor(dispScanlinePos);
            float dispWithinScanline = fract(dispScanlinePos);
            
            float dispSampleScanlinePos = dispScanlineIndex + 0.5;
            float dispSampleDistFromCenter = dispSampleScanlinePos / targetLines;
            vec2 dispSampleUV = vec2(displacedUV.x, clamp(0.5 + dispSampleDistFromCenter, 0.0, 1.0));
            
            // Sample source
            vec3 dispColor = SrgbToLinear3(texture(Source, dispSampleUV).rgb);
            
            // Apply scanline width and mask
            float dispScanlineWidth = calcScanlineWidth(dispColor, baseWidth, minWidth, maxWidth);
            vec3 dispOutputColor = clamp(dispColor / dispScanlineWidth, 0.0, 1.0);
            
            float dispHalfGap = (1.0 - dispScanlineWidth) * 0.5;
            float dispMask = smoothstep(dispHalfGap - edgeSoftness, dispHalfGap + edgeSoftness, dispWithinScanline) *
                             smoothstep(1.0 - dispHalfGap + edgeSoftness, 1.0 - dispHalfGap - edgeSoftness, dispWithinScanline);
            
            triadColor = dispOutputColor * dispMask;
            
        } else {
            triadColor = finalColor;
        }
        
        finalColor = triadColor;
    }

    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}
