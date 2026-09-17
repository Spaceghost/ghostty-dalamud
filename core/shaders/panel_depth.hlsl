// World panels behind game geometry: the pixel shader that replaces Dalamud's
// ImGui pixel shader while a world panel is drawn (core/depthpass.nelua).
//
// ImGui vertices are 2D, so the panel's depth is not in them. Each pixel's
// camera ray is intersected with the panel's surface instead (a plane, or a
// slice of a cylinder when the panel is curved; world_point in core/world.nelua)
// and compared with the game's reversed-Z scene depth. Four comparison taps
// around the pixel (percentage-closer filtering) give covered edges the same
// pixel-wide antialiasing the game's own edges have, and turn a dithered fade
// into a smooth one. Every degenerate case draws the plain ImGui colour: a
// mistake shows a panel, it never hides one. world_panel_ray_depth in
// core/world.nelua mirrors the ray maths for the host tests.
//
// Compiled into panel_depth.dxbc (committed) by tools/build-shaders.lua.

struct PS_INPUT { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; }; // Dalamud's imgui VS output

Texture2D FontTexture : register(t0);
SamplerState FontSampler : register(s0);
Texture2D<float> SceneDepth : register(t1);           // the game's depth, reversed Z, infinite far plane
SamplerComparisonState SceneCompare : register(s1);  // linear, GREATER_EQUAL (visible where the panel is nearer), clamp

cbuffer PanelDepth : register(b0) {
  float4 inv0, inv1, inv2, inv3; // rows of inverse(view-projection) with the camera at the origin (row vectors)
  float4 bas0, bas1, bas2;       // rows of inverse([R F U]): offset -> (lateral, forward, dv); bas0.w = half arc length, yalms
  float4 centre;                 // panel centre minus camera (xyz); curve radius in yalms (w, <= 0.01 = flat)
  float4 view;                   // viewport width, height; depth texels per pixel x, y
  float4 test;                   // near plane, base tolerance (yalms), edge width (pixels), strength (0 = no test, < 0 = show it)
  float4 depth;                  // depth texture allocated width, height; rendered width, height
};

// One comparison `off` pixels from the centre: the panel's depth is carried
// along its screen slope to the tap, then pulled nearer by the tolerance.
float tap(float2 pos, float2 off, float t, float dtdx, float dtdy, float tol) {
  float ref = test.x / max(t + dtdx * off.x + dtdy * off.y - tol, 1e-3);
  float2 uv = clamp((pos + off) * view.zw, 0.5, depth.zw - 0.5) / depth.xy;
  return SceneDepth.SampleCmpLevelZero(SceneCompare, uv, ref);
}

float4 main(PS_INPUT i) : SV_Target {
  float4 c = i.col * FontTexture.Sample(FontSampler, i.uv);

  // No early returns: the slope below needs t from every pixel of the 2x2
  // quad, so each degenerate case clears `valid` instead.

  // the pixel's ray: its point on the near plane (ndc z = 1 in reversed Z),
  // scaled so that clip w (view depth) is 1 at t = 1 along it
  float2 ndc = float2(i.pos.x / view.x * 2.0 - 1.0, 1.0 - i.pos.y / view.y * 2.0);
  float4 h = ndc.x * inv0 + ndc.y * inv1 + inv2 + inv3;
  float hw = h.w * test.x;
  bool ray_ok = abs(hw) >= 1e-6;
  float3 d = h.xyz / (ray_ok ? hw : 1.0);

  // into panel coordinates; dv is free along the extrusion, so only lateral/forward matter
  float3 o = -centre.xyz;
  float2 lo = float2(dot(bas0.xyz, o), dot(bas1.xyz, o));
  float2 ld = float2(dot(bas0.xyz, d), dot(bas1.xyz, d));
  float r = centre.w;

  // flat: the plane forward = 0
  bool flat_ok = abs(ld.y) >= 1e-9;
  float t_flat = -lo.y / (flat_ok ? ld.y : 1.0);

  // curved: circle lateral^2 + (forward - r)^2 = r^2; the panel is the half with forward < r
  float oy = lo.y - r;
  float qa = dot(ld, ld);
  float qb = 2.0 * (lo.x * ld.x + oy * ld.y);
  float qc = lo.x * lo.x + oy * oy - r * r;
  float disc = qb * qb - 4.0 * qa * qc;
  bool curve_ok = qa >= 1e-12 && disc >= 0.0;
  float s = sqrt(max(disc, 0.0));
  float qa2 = 2.0 * (curve_ok ? qa : 1.0);
  float t0 = (-qb - s) / qa2;
  float2 p0 = lo + t0 * ld;
  // the nearer hit only when it lies on the panel's arc
  bool near_hit = t0 > 0.0 && p0.y < r && abs(r * atan2(p0.x, r - p0.y)) <= bas0.w;
  float t_curve = near_hit ? t0 : (-qb + s) / qa2;

  bool curved = r > 0.01;
  float t = curved ? t_curve : t_flat;
  bool valid = ray_ok && (curved ? curve_ok : flat_ok) && t > 0.0;

  // How fast the panel's depth changes across pixels. The taps follow it, and
  // the tolerance grows with it: at grazing angles, or with depth rendered at
  // a lower resolution, one texel of misalignment is worth more depth.
  float dtdx = ddx(t);
  float dtdy = ddy(t);
  float slope = abs(dtdx) + abs(dtdy);
  float tol = test.y + 0.001 * t + slope * (0.5 / max(min(view.z, view.w), 1e-3) + 0.5);

  if (test.w < 0.0) {
    // `/term depth show`: red where the scene is in front of the panel, green
    // where the panel is in front, blue where the pixel has no ray
    float scene = SceneDepth.Load(int3(min(i.pos.xy * view.zw, depth.zw - 1.0), 0));
    float scene_w = test.x / max(scene, 1e-6);
    float4 show = valid ? float4(saturate((t - scene_w) * 4.0), saturate((scene_w - t) * 4.0), 0.0, 0.6)
                        : float4(0.0, 0.0, 1.0, 0.6);
    return c.a > 0.0 ? show : float4(0.0, 0.0, 0.0, 0.0);
  }

  // rotated grid, scaled by the edge width: about 1.5 px of blend at width 1
  float e = test.z;
  float visible = 0.25 * (tap(i.pos.xy, float2(0.25, 0.75) * e, t, dtdx, dtdy, tol)
                        + tap(i.pos.xy, float2(-0.75, 0.25) * e, t, dtdx, dtdy, tol)
                        + tap(i.pos.xy, float2(-0.25, -0.75) * e, t, dtdx, dtdy, tol)
                        + tap(i.pos.xy, float2(0.75, -0.25) * e, t, dtdx, dtdy, tol));
  float strength = valid ? saturate(test.w) : 0.0;
  c.a *= lerp(1.0, visible, strength);
  return c;
}
