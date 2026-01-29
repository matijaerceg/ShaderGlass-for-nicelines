#version 450

// === PARAMETERS ===
#pragma parameter TARGET_LINES "Scanlines (224/240/manual)" 240.0 224.0 480.0 16.0
#pragma parameter MANUAL_LINES "Manual Scanline Count" 240.0 120.0 480.0 1.0
#pragma parameter AUTO_LINES "Auto Adjust Num Scanlines for Resolution" 0.0 0.0 1.0 1.0
#pragma parameter SCANLINE_FINETUNE "Scanline Count Finetune" 0.0 -40.0 40.0 1.0
#pragma parameter SCANLINE_PHASE "Scanline Vertical Offset" 0.0 -1.0 1.0 0.01
#pragma parameter BLUR_OFFSET "Downscaling Resolution" 0.06 -0.3 0.8 0.02
#pragma parameter BASE_WIDTH "Base Scanline Width" 0.3 0.2 0.8 0.05
#pragma parameter MIN_WIDTH "Min Width (dark pixels)" 0.5 0.1 0.5 0.05
#pragma parameter MAX_WIDTH "Max Width (bright pixels)" 1.0 0.7 1.0 0.05
#pragma parameter VERTICAL_SOFT "Vertical Softening" 1.0 0.0 1.0 1.0
#pragma parameter VERTICAL_AMOUNT "Vertical Softening Amount" 0.5 0.0 1.0 0.05
#pragma parameter H_BLUR "Horizontal Blur" 1.0 0.0 4.0 0.1
#pragma parameter COMPARE_MODE "Half/Half" 0.0 0.0 1.0 1.0
#pragma parameter PIXEL_WIZARD "Pixel Counting Wizard" 0.0 0.0 1.0 1.0

// === UBO ===
layout(std140, set = 0, binding = 0) uniform UBO {
    mat4 MVP;
    vec4 SourceSize;
    vec4 OriginalSize;
    vec4 OutputSize;
    uint FrameCount;
    float TARGET_LINES;
    float MANUAL_LINES;
    float AUTO_LINES;
    float SCANLINE_FINETUNE;
    float SCANLINE_PHASE;
    float BLUR_OFFSET;
    float BASE_WIDTH;
    float MIN_WIDTH;
    float MAX_WIDTH;
    float VERTICAL_SOFT;
    float VERTICAL_AMOUNT;
    float H_BLUR;
    float COMPARE_MODE;
    float PIXEL_WIZARD;
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
            int div = 1; for(int j = 0; j < i; j++) div *= 10;
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
void main() {
    // === PIXEL COUNTING WIZARD MODE ===
    if(global.PIXEL_WIZARD > 0.5) {
        // === AUTO-DETECT SCANLINE PITCH ===
        // 1. Sample 16 columns from center 80% of image
        // 2. For each column, test pitches 3-12 pixels and find best correlation
        // 3. Histogram votes to find mode = detected pitch
        // 4. scanlineCount = sourceHeight / detectedPitch
        
        float texelY = 1.0 / global.SourceSize.y;
        
        // Histogram for pitch votes (indices 0-9 represent pitches 3-12)
        float histogram[10];
        for(int i = 0; i < 10; i++) histogram[i] = 0.0;
        
        // Sample 16 columns from center 80% (10% to 90%)
        const int NUM_COLUMNS = 16;
        for(int col = 0; col < NUM_COLUMNS; col++) {
            float xPos = 0.1 + (float(col) + 0.5) / float(NUM_COLUMNS) * 0.8;
            
            // Test pitches 3-12 pixels
            float bestCorr = -99999.0;
            int bestPitch = 3;
            
            for(int p = 3; p <= 12; p++) {
                float corr = 0.0;
                
                // Sum correlation over many Y positions (center 60% of image)
                // Sample every other pixel to reduce computation
                int numSamples = 0;
                for(int y = int(global.SourceSize.y * 0.2); y < int(global.SourceSize.y * 0.8) - p; y += 2) {
                    float yUV = (float(y) + 0.5) * texelY;
                    float yUV_offset = (float(y + p) + 0.5) * texelY;
                    
                    // 3-tap vertical pre-blur (0.25, 0.5, 0.25) for both samples
                    vec3 c0 = texture(Source, vec2(xPos, yUV - texelY)).rgb * 0.25 +
                              texture(Source, vec2(xPos, yUV)).rgb * 0.5 +
                              texture(Source, vec2(xPos, yUV + texelY)).rgb * 0.25;
                    
                    vec3 c1 = texture(Source, vec2(xPos, yUV_offset - texelY)).rgb * 0.25 +
                              texture(Source, vec2(xPos, yUV_offset)).rgb * 0.5 +
                              texture(Source, vec2(xPos, yUV_offset + texelY)).rgb * 0.25;
                    
                    // Correlation: high when colors match (1.0 - distance)
                    corr += 1.0 - length(c0 - c1);
                    numSamples++;
                }
                
                // Normalize by number of samples
                corr /= float(max(numSamples, 1));
                
                if(corr > bestCorr) {
                    bestCorr = corr;
                    bestPitch = p;
                }
            }
            
            // Vote for this pitch
            histogram[bestPitch - 3] += 1.0;
        }
        
        // Find mode (most voted pitch)
        float maxVotes = 0.0;
        int detectedPitch = 3;
        for(int i = 0; i < 10; i++) {
            if(histogram[i] > maxVotes) {
                maxVotes = histogram[i];
                detectedPitch = i + 3;
            }
        }
        
        // Calculate scanline count from detected pitch
        float detectedCount = global.SourceSize.y / float(detectedPitch);
        
        // === DISPLAY ===
        vec2 px = vTexCoord * global.OutputSize.xy;
        
        // Display detected values at top of screen
        if(px.y < 120.0) {
            vec3 debugColor = vec3(0.0);
            
            float digitH = 24.0;
            float digitW = digitH * 0.6;
            float text = 0.0;
            
            // Row 1: Detected scanline count
            text += renderNum(detectedCount, px, vec2(10.0, 10.0), digitW, digitH, 4);
            // Row 2: Detected pitch (in pixels)
            text += renderNum(float(detectedPitch), px, vec2(10.0, 45.0), digitW, digitH, 2);
            // Row 3: Confidence (max votes / total columns)
            text += renderNum(maxVotes / float(NUM_COLUMNS) * 100.0, px, vec2(10.0, 80.0), digitW, digitH, 3);
            
            debugColor = mix(debugColor, vec3(0.0, 1.0, 0.5), text);
            FragColor = vec4(debugColor, 1.0);
            return;
        }
        
        // Show dimmed source with pitch visualization for rest of screen
        vec3 srcColor = texture(Source, vTexCoord).rgb * 0.6;
        
        // Draw horizontal lines at detected pitch intervals
        float srcY = vTexCoord.y * global.SourceSize.y;
        if(mod(srcY, float(detectedPitch)) < 1.0) {
            srcColor = mix(srcColor, vec3(0.0, 1.0, 0.5), 0.5);
        }
        
        FragColor = vec4(srcColor, 1.0);
        return;
    }
    
    // === NORMAL MODE: Scanline processing ===
    float baseWidth = global.BASE_WIDTH;
    float minWidth = global.MIN_WIDTH;
    float maxWidth = global.MAX_WIDTH;
    
    // Determine target scanline count
    float targetLines;
    if(global.TARGET_LINES == 224.0 || global.TARGET_LINES == 240.0) {
        // Preset mode (224 or 240)
        targetLines = global.TARGET_LINES;
    } else {
        // Manual mode (user sets MANUAL_LINES slider)
        targetLines = global.MANUAL_LINES;
    }
    
    // Auto-fit: find nearest factor of output height to target
    if(global.AUTO_LINES > 0.5) {
        float outputHeight = global.OutputSize.y;
        float idealPixelsPerLine = outputHeight / targetLines;
        float pixelsPerLine = max(1.0, round(idealPixelsPerLine));
        targetLines = outputHeight / pixelsPerLine;
    }
    
    // Apply scanline finetune offset (after auto-fit)
    targetLines = max(60.0, targetLines + global.SCANLINE_FINETUNE);
    
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
    float scanlinePos = scanlineOffset + global.SCANLINE_PHASE;
    float scanlineIndex = floor(scanlinePos);
    
    // Sample at scanline center (center-anchored)
    float sampleScanlinePos = scanlineIndex + 0.5;
    float sampleDistFromCenter = (sampleScanlinePos - global.SCANLINE_PHASE) / targetLines;
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
    
    // Edge softness calculation
    float pixelsPerScanline = global.OutputSize.y / targetLines;
    float baseEdgeSoftness = 0.5 / pixelsPerScanline;
    
    // Vertical softening: increase edge softness for softer/glowier scanlines
    float edgeSoftness = baseEdgeSoftness;
    if(global.VERTICAL_SOFT > 0.5) {
        // Exponential curve: pow(x, 2.5) makes slider less sensitive at low values
        // 0.1 -> 0.003, 0.3 -> 0.05, 0.5 -> 0.18, 0.7 -> 0.41, 1.0 -> 1.0
        float curvedAmount = pow(global.VERTICAL_AMOUNT, 2.5);
        float extraSoftness = curvedAmount * (4.0 / pixelsPerScanline);
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
    
    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}
        vec2 px = vTexCoord * global.OutputSize.xy;
        vec3 debugColor = vec3(0.0);
        
        // Current grid settings
        float phase = global.SCANLINE_PHASE;
        float zoomFactor = global.DETECT_ZOOM / 100.0;
        float zoomSize = 1.0 / zoomFactor;
        
        // Vertical anchor: 0=bottom, 1=middle, 2=top
        // Maps to source Y coordinate: 0->1.0 (bottom), 1->0.5 (middle), 2->0.0 (top)
        float anchorY = 1.0 - global.DETECT_ANCHOR * 0.5;
        
        // Three panel layout
        float panelWidth = 1.0 / 3.0;
        
        // Compute zoomed source coordinates (same for all panels)
        // Account for aspect ratio: each panel is 1/3 screen width but full height
        float panelAspect = (global.OutputSize.x * panelWidth) / global.OutputSize.y;
        float sourceAspect = global.SourceSize.x / global.SourceSize.y;
        
        float panelX, panelY;
        if(vTexCoord.x < panelWidth) {
            panelX = vTexCoord.x / panelWidth;
        } else if(vTexCoord.x < panelWidth * 2.0) {
            panelX = (vTexCoord.x - panelWidth) / panelWidth;
        } else {
            panelX = (vTexCoord.x - panelWidth * 2.0) / panelWidth;
        }
        panelY = vTexCoord.y;
        
        // All panels zoom to anchor position
        // Only pillarbox if needed (horizontal black bars) - NO letterbox to maximize visible rows
        float srcX, srcY;
        bool inBlackBars = false;
        
        if(panelAspect > sourceAspect) {
            // Panel is wider than source - pillarbox (black bars on sides)
            float visibleWidth = sourceAspect / panelAspect;
            float xOffset = (1.0 - visibleWidth) * 0.5;
            float normalizedX = (panelX - xOffset) / visibleWidth;
            if(panelX < xOffset || panelX > 1.0 - xOffset) inBlackBars = true;
            srcX = clamp(0.5 + (normalizedX - 0.5) * zoomSize, 0.0, 1.0);
        } else {
            // Panel is narrower or same - stretch X to fill (slight stretch OK for debug)
            srcX = clamp(0.5 + (panelX - 0.5) * zoomSize, 0.0, 1.0);
        }
        // Always use full vertical range - maximize visible scanlines for debugging
        srcY = clamp(anchorY + (panelY - 0.5) * zoomSize, 0.0, 1.0);
        
        vec2 srcUV = vec2(srcX, srcY);
        
        // Track which panel we're in for line drawing
        int panelIndex = (vTexCoord.x < panelWidth) ? 0 : ((vTexCoord.x < panelWidth * 2.0) ? 1 : 2);
        
        if(panelIndex == 0) {
            // === LEFT PANEL: Enhanced row visibility ===
            if(inBlackBars) {
                debugColor = vec3(0.0);
            } else {
            // Sample across inner 50% of X to avoid edge artifacts, compute min/max to enhance contrast
            const int NUM_SAMPLES = 32;
            float minLuma = 1.0;
            float maxLuma = 0.0;
            float avgLuma = 0.0;
            
            for(int i = 0; i < NUM_SAMPLES; i++) {
                // Sample from inner 50% (0.25 to 0.75)
                float xPos = 0.25 + (float(i) + 0.5) / float(NUM_SAMPLES) * 0.5;
                vec3 col = texture(Source, vec2(xPos, srcY)).rgb;
                float luma = dot(col, vec3(0.299, 0.587, 0.114));
                avgLuma += luma;
                minLuma = min(minLuma, luma);
                maxLuma = max(maxLuma, luma);
            }
            avgLuma /= float(NUM_SAMPLES);
            
            // Stretch contrast: remap avgLuma from [minLuma, maxLuma] to [0, 1]
            // But use a wider neighborhood for min/max to avoid single-row artifacts
            float texelY = 1.0 / global.SourceSize.y;
            float neighborMin = minLuma;
            float neighborMax = maxLuma;
            
            // Sample a few rows above and below to get local min/max
            for(int row = -3; row <= 3; row++) {
                if(row == 0) continue;
                float sampleY = srcY + float(row) * texelY * 2.0;
                for(int i = 0; i < 4; i++) {
                    float xPos = (float(i) + 0.5) / 4.0;
                    vec3 col = texture(Source, vec2(xPos, sampleY)).rgb;
                    float luma = dot(col, vec3(0.299, 0.587, 0.114));
                    neighborMin = min(neighborMin, luma);
                    neighborMax = max(neighborMax, luma);
                }
            }
            
            // Apply local contrast stretch
            float range = neighborMax - neighborMin;
            float enhanced = (range > 0.01) ? (avgLuma - neighborMin) / range : avgLuma;
            debugColor = vec3(enhanced);
            }
        }
        else if(panelIndex == 1) {
            // === MIDDLE PANEL: Zoomed source ===
            if(inBlackBars) {
                debugColor = vec3(0.0);
            } else {
                debugColor = texture(Source, srcUV).rgb;
            }
        }
        else {
            // === RIGHT PANEL: Final scanline output (matches main effect exactly) ===
            if(inBlackBars) {
                debugColor = vec3(0.0);
            } else {
            // Center-anchored scanline calculation (same as main effect)
            float detectDistFromCenter = srcY - 0.5;
            float detectScanlineOffset = detectDistFromCenter * targetLines;
            float detectBaseScanlinePos = detectScanlineOffset + phase;
            float detectScanlineIndex = floor(detectBaseScanlinePos);
            
            // Sample at scanline center (center-anchored, same as main effect)
            float detectSamplePos = detectScanlineIndex + 0.5;
            float detectSampleDistFromCenter = (detectSamplePos - phase) / targetLines;
            vec2 detectSampleUV = vec2(srcX, clamp(0.5 + detectSampleDistFromCenter, 0.0, 1.0));
            
            // Compute effective source scale
            float detectBaselineScale = targetLines / global.SourceSize.y;
            float detectEffectiveScale = clamp(detectBaselineScale + global.BLUR_OFFSET, 0.02, 1.0);
            
            vec3 srcColor;
            if(detectEffectiveScale < 0.999) {
                float detectBlurRadius = (1.0 / detectEffectiveScale - 1.0) * 0.5;
                vec2 texelSize = 1.0 / global.SourceSize.xy;
                vec2 radius = texelSize * detectBlurRadius;
                vec3 sum = vec3(0.0);
                sum += texture(Source, detectSampleUV + vec2(-radius.x, -radius.y)).rgb;
                sum += texture(Source, detectSampleUV + vec2(0.0, -radius.y)).rgb;
                sum += texture(Source, detectSampleUV + vec2(radius.x, -radius.y)).rgb;
                sum += texture(Source, detectSampleUV + vec2(-radius.x, 0.0)).rgb;
                sum += texture(Source, detectSampleUV).rgb;
                sum += texture(Source, detectSampleUV + vec2(radius.x, 0.0)).rgb;
                sum += texture(Source, detectSampleUV + vec2(-radius.x, radius.y)).rgb;
                sum += texture(Source, detectSampleUV + vec2(0.0, radius.y)).rgb;
                sum += texture(Source, detectSampleUV + vec2(radius.x, radius.y)).rgb;
                srcColor = SrgbToLinear3(sum / 9.0);
            } else {
                srcColor = SrgbToLinear3(texture(Source, detectSampleUV).rgb);
            }
            
            // Calculate scanline width and energy-preserved color (same as main effect)
            float detectWidth = calcScanlineWidth(srcColor, baseWidth, minWidth, maxWidth);
            vec3 detectOutputColor = clamp(srcColor / detectWidth, 0.0, 1.0);
            
            // Scanline mask using same formula as main effect
            float detectWithinScanline = fract(detectBaseScanlinePos); // No burn-in in detect mode
            float detectHalfGap = (1.0 - detectWidth) * 0.5;
            
            // Edge softness calculation (same as main effect)
            float detectPixelsPerScanline = global.OutputSize.y / targetLines;
            float detectBaseEdgeSoftness = 0.5 / detectPixelsPerScanline;
            float detectEdgeSoftness = detectBaseEdgeSoftness;
            if(global.VERTICAL_SOFT > 0.5) {
                float curvedAmount = pow(global.VERTICAL_AMOUNT, 2.5);
                float extraSoftness = curvedAmount * (4.0 / detectPixelsPerScanline);
                detectEdgeSoftness = detectBaseEdgeSoftness + extraSoftness;
            }
            
            float detectMask = smoothstep(detectHalfGap - detectEdgeSoftness, detectHalfGap + detectEdgeSoftness, detectWithinScanline) *
                               smoothstep(1.0 - detectHalfGap + detectEdgeSoftness, 1.0 - detectHalfGap - detectEdgeSoftness, detectWithinScanline);
            
            vec3 detectFinalColor = detectOutputColor * detectMask;
            
            // Apply H_BLUR to match main effect
            if(global.H_BLUR > 0.001) {
                float detectPixelSize = 1.0 / global.OutputSize.x;
                float detectBlurRad = global.H_BLUR * detectPixelSize;
                
                // Sample neighbors at same scanline Y
                vec2 duvL1 = vec2(srcX - detectBlurRad * 0.5 / zoomSize, detectSampleUV.y);
                vec2 duvL2 = vec2(srcX - detectBlurRad / zoomSize, detectSampleUV.y);
                vec2 duvR1 = vec2(srcX + detectBlurRad * 0.5 / zoomSize, detectSampleUV.y);
                vec2 duvR2 = vec2(srcX + detectBlurRad / zoomSize, detectSampleUV.y);
                
                vec3 dsrcL1 = SrgbToLinear3(texture(Source, duvL1).rgb);
                vec3 dsrcL2 = SrgbToLinear3(texture(Source, duvL2).rgb);
                vec3 dsrcR1 = SrgbToLinear3(texture(Source, duvR1).rgb);
                vec3 dsrcR2 = SrgbToLinear3(texture(Source, duvR2).rgb);
                
                float dwL1 = calcScanlineWidth(dsrcL1, baseWidth, minWidth, maxWidth);
                float dwL2 = calcScanlineWidth(dsrcL2, baseWidth, minWidth, maxWidth);
                float dwR1 = calcScanlineWidth(dsrcR1, baseWidth, minWidth, maxWidth);
                float dwR2 = calcScanlineWidth(dsrcR2, baseWidth, minWidth, maxWidth);
                
                vec3 dcL1 = clamp(dsrcL1 / dwL1, 0.0, 1.0) * detectMask;
                vec3 dcL2 = clamp(dsrcL2 / dwL2, 0.0, 1.0) * detectMask;
                vec3 dcR1 = clamp(dsrcR1 / dwR1, 0.0, 1.0) * detectMask;
                vec3 dcR2 = clamp(dsrcR2 / dwR2, 0.0, 1.0) * detectMask;
                
                detectFinalColor = (dcL2 * 0.1 + dcL1 * 0.2 + detectFinalColor * 0.4 + dcR1 * 0.2 + dcR2 * 0.1);
            }
            
            debugColor = LinearToSrgb3(detectFinalColor);
            }
        }
        
        // === DRAW ROW BOUNDARY LINES (left and middle panels only) ===
        // Lines are exactly 1 output pixel, drawn at the very end
        // Uses CENTER-ANCHORED system: boundary 0 is at screen center when phase=0
        if(panelIndex < 2) {
            // Visible Y range in source coordinates (based on current anchor position)
            float minVisibleY = anchorY - 0.5 * zoomSize;
            float maxVisibleY = anchorY + 0.5 * zoomSize;
            
            // Convert to scanline boundaries (center-anchored)
            // At srcY, scanlinePos = (srcY - 0.5) * targetLines + phase
            // Boundary N is where scanlinePos = N, so srcY = 0.5 + (N - phase) / targetLines
            float minBoundary = (minVisibleY - 0.5) * targetLines + phase;
            float maxBoundary = (maxVisibleY - 0.5) * targetLines + phase;
            
            int firstBoundary = int(floor(minBoundary));
            int lastBoundary = int(ceil(maxBoundary));
            
            // Current pixel's Y range in panel coordinates (0-1)
            float pixelSize = 1.0 / global.OutputSize.y;
            float pixelTop = panelY - pixelSize * 0.5;
            float pixelBottom = panelY + pixelSize * 0.5;
            
            // Check each boundary
            for(int boundaryIdx = firstBoundary; boundaryIdx <= lastBoundary + 1; boundaryIdx++) {
                // Y position of this boundary in source UV (center-anchored)
                float boundaryY = 0.5 + (float(boundaryIdx) - phase) / targetLines;
                
                // Convert to panel Y coordinate (relative to current anchor)
                float panelBoundaryY = (boundaryY - anchorY) / zoomSize + 0.5;
                
                // Check if boundary falls within this pixel's range
                if(panelBoundaryY >= pixelTop && panelBoundaryY < pixelBottom) {
                    // Red for boundaries 0 and 1 (edges of the anchor row at screen center)
                    bool isAnchorBoundary = (boundaryIdx == 0 || boundaryIdx == 1);
                    if(isAnchorBoundary) {
                        debugColor = vec3(1.0, 0.15, 0.1); // Red
                    } else {
                        debugColor = vec3(1.0, 1.0, 1.0); // White
                    }
                }
            }
        }
        
        // === INFO OVERLAY (top-left corner) ===
        float digitH = max(18.0, global.OutputSize.y / 32.0);
        float digitW = digitH * 0.6;
        float margin = 12.0;
        float rowH = digitH * 1.35;
        
        float text = 0.0;
        
        // Row 0: Row count (targetLines)
        text += renderNum(targetLines, px, vec2(margin, margin), digitW, digitH, 3);
        
        // Row 1: Phase (0-99) with sign indicator
        float phaseDisplayX = margin;
        // Draw minus sign if negative
        bool showMinus = (phase < 0.0);
        if(showMinus) {
            // Simple minus sign: horizontal bar
            vec2 minusPos = vec2(margin, margin + rowH + digitH * 0.4);
            if(px.x > minusPos.x && px.x < minusPos.x + digitW * 0.5 &&
               px.y > minusPos.y && px.y < minusPos.y + digitH * 0.15) {
                text = 1.0;
            }
            phaseDisplayX = margin + digitW * 0.6;
        }
        text += renderNum(abs(phase) * 100.0, px, vec2(phaseDisplayX, margin + rowH), digitW, digitH, 2);
        
        // Background box
        float boxW = digitW * 4.5;
        float boxH = rowH * 2.3;
        if(px.x < boxW && px.y < boxH) {
            debugColor = debugColor * 0.2;
        }
        
        // Text color (green LCD style)
        debugColor = mix(debugColor, vec3(0.0, 1.0, 0.5), text);
        
        // Reminder: disable auto-fit (bottom of screen)
        // Draw "NO AUTO" warning if AUTO_LINES is on
        if(global.AUTO_LINES > 0.5) {
            float warnY = global.OutputSize.y - margin - digitH;
            float warnText = 0.0;
            // Show "0" to indicate auto should be off (simple indicator)
            warnText += renderNum(0.0, px, vec2(margin, warnY), digitW, digitH, 1);
            if(px.x < digitW * 2.0 && px.y > warnY - 4.0 && px.y < warnY + digitH + 4.0) {
                debugColor = debugColor * 0.2;
            }
            debugColor = mix(debugColor, vec3(1.0, 0.3, 0.2), warnText); // Red warning
        }
        
        // Panel divider lines
        float dividerWidth = 2.0;
        if(abs(vTexCoord.x - panelWidth) * global.OutputSize.x < dividerWidth ||
           abs(vTexCoord.x - panelWidth * 2.0) * global.OutputSize.x < dividerWidth) {
            debugColor = vec3(0.3, 0.3, 0.3);
        }
        
        FragColor = vec4(debugColor, 1.0);
        return;
    }
    
    // Debug info overlay (7-segment LCD style)
    if(global.DEBUG_INFO > 0.5) {
        vec2 px = vTexCoord * global.OutputSize.xy;
        float digitH = max(20.0, global.OutputSize.y / 30.0);
        float digitW = digitH * 0.6;
        float margin = 10.0;
        float row = digitH * 1.4;
        
        float text = 0.0;
        
        // Row 0: Input width x height
        text += renderNum(global.SourceSize.x, px, vec2(margin, margin), digitW, digitH, 4);
        text += renderNum(global.SourceSize.y, px, vec2(margin + digitW * 5.5, margin), digitW, digitH, 4);
        
        // Row 1: Output width x height  
        text += renderNum(global.OutputSize.x, px, vec2(margin, margin + row), digitW, digitH, 4);
        text += renderNum(global.OutputSize.y, px, vec2(margin + digitW * 5.5, margin + row), digitW, digitH, 4);
        
        // Row 2: Scanlines
        text += renderNum(targetLines, px, vec2(margin, margin + row * 2.0), digitW, digitH, 3);
        
        // Row 3: Scale %
        text += renderNum(effectiveScale * 100.0, px, vec2(margin, margin + row * 3.0), digitW, digitH, 3);
        
        // Background
        float boxW = digitW * 10.5;
        float boxH = row * 4.0 + margin;
        if(px.x < boxW && px.y < boxH) finalColor = finalColor * 0.2;
        
        // Text color (green LCD style)
        finalColor = mix(finalColor, vec3(0.0, 1.0, 0.5), text);
    }
    
    FragColor = vec4(LinearToSrgb3(finalColor), 1.0);
}