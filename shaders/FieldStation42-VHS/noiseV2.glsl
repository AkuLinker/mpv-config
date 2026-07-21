//!HOOK MAIN
//!BIND HOOKED
//!DESC FieldStation42 Tape Noise v1.1

#define INTENSITY 0.005

float hash(vec2 p)
{
    p = fract(p * vec2(443.897,441.423));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

vec4 hook()
{
    vec2 uv = HOOKED_pos;
    vec4 color = HOOKED_tex(uv);

    float grain = hash(uv * HOOKED_size * 0.75 + frame);
    grain = (grain - 0.5) * 2.0;

    float luma = dot(color.rgb, vec3(0.299,0.587,0.114));
    // FIX: pow() with a fractional exponent (1.4) on a negative base is
    // undefined in GLSL and produces NaN. luma can exceed 1.0 (bright/
    // white pixels pushed over range by earlier shaders or color-range
    // decoding), which made (1.0 - luma) negative and blew this pixel
    // up into a NaN — visible as random-colored (usually green) dots,
    // concentrated exactly on bright areas. Clamp before pow() so it
    // never sees a negative base.
    float strength = INTENSITY * pow(clamp(1.0 - luma, 0.0, 1.0), 1.4);

    // NOTE: the original file computed r/g/b weights (0.85/0.90 for
    // g/b) but then never used them — it added the same grain value
    // to all three channels. That's harmless on its own (still neutral
    // gray noise), but this version actually applies the weights, so
    // the grain has a very slight built-in tilt instead of relying
    // entirely on whatever happens to sit downstream in the shader
    // chain (e.g. crt.glsl's phosphor mask).
    vec3 weighted = vec3(1.0, 0.85, 0.90) * grain;

    color.rgb += weighted * strength;
    return color;
}
