#import bevy_render::globals    Globals
#import bevy_render::view       View

#import bevy_gaussian_splatting::spherical_harmonics    spherical_harmonics_lookup


struct GaussianInput {
    @location(0) rotation: vec4<f32>,
    @location(1) position: vec4<f32>,
    @location(2) scale_opacity: vec4<f32>,
    sh: array<f32, #{MAX_SH_COEFF_COUNT}>,
};

struct GaussianOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) color: vec4<f32>,
    @location(1) @interpolate(flat) conic: vec3<f32>,
    @location(2) @interpolate(linear) uv: vec2<f32>,
    @location(3) @interpolate(linear) major_minor: vec2<f32>,
};

struct GaussianUniforms {
    global_transform: mat4x4<f32>,
    global_scale: f32,
};

struct DrawIndirect {
    vertex_count: u32,
    instance_count: atomic<u32>,
    base_vertex: u32,
    base_instance: u32,
}
struct SortingGlobal {
    status_counters: array<array<atomic<u32>, #{RADIX_BASE}>, #{MAX_TILE_COUNT_C}>,
    digit_histogram: array<array<atomic<u32>, #{RADIX_BASE}>, #{RADIX_DIGIT_PLACES}>,
    draw_indirect: DrawIndirect,
    assignment_counter: atomic<u32>,
}
struct Entry {
    key: u32,
    value: u32,
}


@group(0) @binding(0) var<uniform> view: View;
@group(0) @binding(1) var<uniform> globals: Globals;

@group(1) @binding(0) var<uniform> uniforms: GaussianUniforms;

@group(2) @binding(0) var<storage, read> points: array<GaussianInput>;

@group(3) @binding(0) var<uniform> sorting_pass_index: u32;
@group(3) @binding(1) var<storage, read_write> sorting: SortingGlobal;
@group(3) @binding(2) var<storage, read_write> input_entries: array<Entry>;
@group(3) @binding(3) var<storage, read_write> output_entries: array<Entry>;
@group(3) @binding(4) var<storage, read> sorted_entries: array<Entry>;

struct SortingSharedA {
    digit_histogram: array<array<atomic<u32>, #{RADIX_BASE}>, #{RADIX_DIGIT_PLACES}>,
}
var<workgroup> sorting_shared_a: SortingSharedA;

@compute @workgroup_size(#{RADIX_BASE}, #{RADIX_DIGIT_PLACES})
fn radix_sort_a(
    @builtin(local_invocation_id) gl_LocalInvocationID: vec3<u32>,
    @builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>,
) {
    sorting_shared_a.digit_histogram[gl_LocalInvocationID.y][gl_LocalInvocationID.x] = 0u;
    workgroupBarrier();

    let thread_index = gl_GlobalInvocationID.x * #{RADIX_DIGIT_PLACES}u + gl_GlobalInvocationID.y;
    let start_entry_index = thread_index * #{ENTRIES_PER_INVOCATION_A}u;
    let end_entry_index = start_entry_index + #{ENTRIES_PER_INVOCATION_A}u;
    for(var entry_index = start_entry_index; entry_index < end_entry_index; entry_index += 1u) {
        if(entry_index >= arrayLength(&points)) {
            continue;
        }
        var key: u32 = 0xFFFFFFFFu; // Stream compaction for frustum culling
        let clip_space_pos = world_to_clip(points[entry_index].position.xyz);
        if(in_frustum(clip_space_pos.xyz)) {
            // key = bitcast<u32>(clip_space_pos.z);
            key = u32(clip_space_pos.z * 0xFFFF.0) << 16u;
            key |= u32((clip_space_pos.x * 0.5 + 0.5) * 0xFF.0) << 8u;
            key |= u32((clip_space_pos.y * 0.5 + 0.5) * 0xFF.0);
        }
        output_entries[entry_index].key = key;
        output_entries[entry_index].value = entry_index;
        for(var shift = 0u; shift < #{RADIX_DIGIT_PLACES}u; shift += 1u) {
            let digit = (key >> (shift * #{RADIX_BITS_PER_DIGIT}u)) & (#{RADIX_BASE}u - 1u);
            atomicAdd(&sorting_shared_a.digit_histogram[shift][digit], 1u);
        }
    }
    workgroupBarrier();

    atomicAdd(&sorting.digit_histogram[gl_LocalInvocationID.y][gl_LocalInvocationID.x], sorting_shared_a.digit_histogram[gl_LocalInvocationID.y][gl_LocalInvocationID.x]);
}

@compute @workgroup_size(1)
fn radix_sort_b(
    @builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>,
) {
    var sum = 0u;
    for(var digit = 0u; digit < #{RADIX_BASE}u; digit += 1u) {
        let tmp = sorting.digit_histogram[gl_GlobalInvocationID.y][digit];
        sorting.digit_histogram[gl_GlobalInvocationID.y][digit] = sum;
        sum += tmp;
    }
}

struct SortingSharedC {
    entries: array<atomic<u32>, #{WORKGROUP_ENTRIES_C}>,
    gather_sources: array<atomic<u32>, #{WORKGROUP_ENTRIES_C}>,
    scan: array<atomic<u32>, #{WORKGROUP_INVOCATIONS_C}>,
    total: u32,
}
var<workgroup> sorting_shared_c: SortingSharedC;

const NUM_BANKS: u32 = 16u;
const LOG_NUM_BANKS: u32 = 4u;
fn conflict_free_offset(n: u32) -> u32 {
    return 0u; // n >> NUM_BANKS + n >> (2u * LOG_NUM_BANKS);
}

fn exclusive_scan(local_invocation_index: u32, value: u32) -> u32 {
    sorting_shared_c.scan[local_invocation_index + conflict_free_offset(local_invocation_index)] = value;

    var offset = 1u;
    for (var d = #{WORKGROUP_INVOCATIONS_C}u >> 1u; d > 0u; d >>= 1u) {
        workgroupBarrier();
        if(local_invocation_index < d) {
            var ai = offset * (2u * local_invocation_index + 1u) - 1u;
            var bi = offset * (2u * local_invocation_index + 2u) - 1u;
            ai += conflict_free_offset(ai);
            bi += conflict_free_offset(bi);
            sorting_shared_c.scan[bi] += sorting_shared_c.scan[ai];
        }

        offset <<= 1u;
    }

    if (local_invocation_index == 0u) {
      var i = #{WORKGROUP_INVOCATIONS_C}u - 1u;
      i += conflict_free_offset(i);
      sorting_shared_c.total = sorting_shared_c.scan[i];
      sorting_shared_c.scan[i] = 0u;
    }

    for (var d = 1u; d < #{WORKGROUP_INVOCATIONS_C}u; d <<= 1u) {
        workgroupBarrier();
        offset >>= 1u;
        if(local_invocation_index < d) {
            var ai = offset * (2u * local_invocation_index + 1u) - 1u;
            var bi = offset * (2u * local_invocation_index + 2u) - 1u;
            ai += conflict_free_offset(ai);
            bi += conflict_free_offset(bi);
            let t = sorting_shared_c.scan[ai];
            sorting_shared_c.scan[ai] = sorting_shared_c.scan[bi];
            sorting_shared_c.scan[bi] += t;
        }
    }

    workgroupBarrier();
    return sorting_shared_c.scan[local_invocation_index + conflict_free_offset(local_invocation_index)];
}

@compute @workgroup_size(#{WORKGROUP_INVOCATIONS_C})
fn radix_sort_c(
    @builtin(local_invocation_id) gl_LocalInvocationID: vec3<u32>,
    @builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>,
) {
    // Draw an assignment number
    if(gl_LocalInvocationID.x == 0u) {
        sorting_shared_c.entries[0] = atomicAdd(&sorting.assignment_counter, 1u);
    }

    // Reset histogram
    sorting_shared_c.scan[gl_LocalInvocationID.x + conflict_free_offset(gl_LocalInvocationID.x)] = 0u;
    workgroupBarrier();

    let assignment = sorting_shared_c.entries[0];
    let global_entry_offset = assignment * #{WORKGROUP_ENTRIES_C}u;
    // TODO: Specialize end shader
    if(gl_LocalInvocationID.x == 0u && assignment * #{WORKGROUP_ENTRIES_C}u + #{WORKGROUP_ENTRIES_C}u >= arrayLength(&points)) {
        // Last workgroup resets the assignment number for the next pass
        sorting.assignment_counter = 0u;
    }

    // Load keys from global memory into registers and rank them
    var keys: array<u32, #{ENTRIES_PER_INVOCATION_C}>;
    var ranks: array<u32, #{ENTRIES_PER_INVOCATION_C}>;
    for(var entry_index = 0u; entry_index < #{ENTRIES_PER_INVOCATION_C}u; entry_index += 1u) {
        keys[entry_index] = input_entries[global_entry_offset + #{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x][0];
        let digit = (keys[entry_index] >> (sorting_pass_index * #{RADIX_BITS_PER_DIGIT}u)) & (#{RADIX_BASE}u - 1u);
        // TODO: Implement warp-level multi-split (WLMS) once WebGPU supports subgroup operations
        ranks[entry_index] = atomicAdd(&sorting_shared_c.scan[digit + conflict_free_offset(digit)], 1u);
    }
    workgroupBarrier();

    // Cumulate histogram
    let local_digit_count = sorting_shared_c.scan[gl_LocalInvocationID.x + conflict_free_offset(gl_LocalInvocationID.x)];
    let local_digit_offset = exclusive_scan(gl_LocalInvocationID.x, local_digit_count);
    sorting_shared_c.scan[gl_LocalInvocationID.x + conflict_free_offset(gl_LocalInvocationID.x)] = local_digit_offset;

    // Chained decoupling lookback
    atomicStore(&sorting.status_counters[assignment][gl_LocalInvocationID.x], 0x40000000u | local_digit_count);
    var global_digit_count = 0u;
    var previous_tile = assignment;
    while true {
        if(previous_tile == 0u) {
            global_digit_count += sorting.digit_histogram[sorting_pass_index][gl_LocalInvocationID.x];
            break;
        }
        previous_tile -= 1u;
        var status_counter = 0u;
        while((status_counter & 0xC0000000u) == 0u) {
            status_counter = atomicLoad(&sorting.status_counters[previous_tile][gl_LocalInvocationID.x]);
        }
        global_digit_count += status_counter & 0x3FFFFFFFu;
        if((status_counter & 0x80000000u) != 0u) {
            break;
        }
    }
    atomicStore(&sorting.status_counters[assignment][gl_LocalInvocationID.x], 0x80000000u | (global_digit_count + local_digit_count));
    if(sorting_pass_index == #{RADIX_DIGIT_PLACES}u - 1u && gl_LocalInvocationID.x == #{WORKGROUP_INVOCATIONS_C}u - 2u && global_entry_offset + #{WORKGROUP_ENTRIES_C}u >= arrayLength(&points)) {
        sorting.draw_indirect.vertex_count = 4u;
        sorting.draw_indirect.instance_count = global_digit_count + local_digit_count;
    }

    // Scatter keys inside shared memory
    for(var entry_index = 0u; entry_index < #{ENTRIES_PER_INVOCATION_C}u; entry_index += 1u) {
        let key = keys[entry_index];
        let digit = (key >> (sorting_pass_index * #{RADIX_BITS_PER_DIGIT}u)) & (#{RADIX_BASE}u - 1u);
        ranks[entry_index] += sorting_shared_c.scan[digit + conflict_free_offset(digit)];
        sorting_shared_c.entries[ranks[entry_index]] = key;
    }
    workgroupBarrier();

    // Add global offset
    sorting_shared_c.scan[gl_LocalInvocationID.x + conflict_free_offset(gl_LocalInvocationID.x)] = global_digit_count - local_digit_offset;
    workgroupBarrier();

    // Store keys from shared memory into global memory
    for(var entry_index = 0u; entry_index < #{ENTRIES_PER_INVOCATION_C}u; entry_index += 1u) {
        let key = sorting_shared_c.entries[#{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x];
        let digit = (key >> (sorting_pass_index * #{RADIX_BITS_PER_DIGIT}u)) & (#{RADIX_BASE}u - 1u);
        keys[entry_index] = digit;
        output_entries[sorting_shared_c.scan[digit + conflict_free_offset(digit)] + #{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x][0] = key;
    }
    workgroupBarrier();

    // Load values from global memory and scatter them inside shared memory
    for(var entry_index = 0u; entry_index < #{ENTRIES_PER_INVOCATION_C}u; entry_index += 1u) {
        let value = input_entries[global_entry_offset + #{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x][1];
        sorting_shared_c.entries[ranks[entry_index]] = value;
    }
    workgroupBarrier();

    // Store values from shared memory into global memory
    for(var entry_index = 0u; entry_index < #{ENTRIES_PER_INVOCATION_C}u; entry_index += 1u) {
        let value = sorting_shared_c.entries[#{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x];
        let digit = keys[entry_index];
        output_entries[sorting_shared_c.scan[digit + conflict_free_offset(digit)] + #{WORKGROUP_INVOCATIONS_C}u * entry_index + gl_LocalInvocationID.x][1] = value;
    }
}

@compute @workgroup_size(#{TEMPORAL_SORT_WINDOW_SIZE})
fn temporal_sort_flip(
    @builtin(local_invocation_id) gl_LocalInvocationID: vec3<u32>,
    @builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>,
) {
    // let start_index = gl_GlobalInvocationID.x * #{TEMPORAL_SORT_WINDOW_SIZE}u;
    // let end_index = start_index + #{TEMPORAL_SORT_WINDOW_SIZE}u;
}

@compute @workgroup_size(#{TEMPORAL_SORT_WINDOW_SIZE})
fn temporal_sort_flop(
    @builtin(local_invocation_id) gl_LocalInvocationID: vec3<u32>,
    @builtin(global_invocation_id) gl_GlobalInvocationID: vec3<u32>,
) {
    // // TODO: pad sorting buffers to 1.5 window size
    // let start_index = gl_GlobalInvocationID.x * #{TEMPORAL_SORT_WINDOW_SIZE}u + #{TEMPORAL_SORT_WINDOW_SIZE}u / 2u;
    // let end_index = start_index + #{TEMPORAL_SORT_WINDOW_SIZE}u;

    // // pair sort entries in window size
    // for (var i = start_index; i < end_index; i += 2u) {
    //     let pos_a = points[input_entries[i][0]].position.xyz;
    //     let depth_a = world_to_clip(pos_a).z;
    // }
}




// https://github.com/cvlab-epfl/gaussian-splatting-web/blob/905b3c0fb8961e42c79ef97e64609e82383ca1c2/src/shaders.ts#L185
// TODO: precompute
fn compute_cov3d(scale: vec3<f32>, rotation: vec4<f32>) -> array<f32, 6> {
    let S = scale * uniforms.global_scale;

    let r = rotation.x;
    let x = rotation.y;
    let y = rotation.z;
    let z = rotation.w;

    let R = mat3x3<f32>(
        1.0 - 2.0 * (y * y + z * z),
        2.0 * (x * y - r * z),
        2.0 * (x * z + r * y),

        2.0 * (x * y + r * z),
        1.0 - 2.0 * (x * x + z * z),
        2.0 * (y * z - r * x),

        2.0 * (x * z - r * y),
        2.0 * (y * z + r * x),
        1.0 - 2.0 * (x * x + y * y),
    );

    let M = mat3x3<f32>(
        S[0] * R.x,
        S[1] * R.y,
        S[2] * R.z,
    );

    let Sigma = transpose(M) * M;

    return array<f32, 6>(
        Sigma[0][0],
        Sigma[0][1],
        Sigma[0][2],
        Sigma[1][1],
        Sigma[1][2],
        Sigma[2][2],
    );
}

fn compute_cov2d(position: vec3<f32>, scale: vec3<f32>, rotation: vec4<f32>) -> vec3<f32> {
    let cov3d = compute_cov3d(scale, rotation);
    let Vrk = mat3x3(
        cov3d[0], cov3d[1], cov3d[2],
        cov3d[1], cov3d[3], cov3d[4],
        cov3d[2], cov3d[4], cov3d[5],
    );

    var t = view.inverse_view * vec4<f32>(position, 1.0);

#ifdef USE_AABB
    let focal_x = view.viewport.z / (2.0 * view.projection[0][0]);
    let focal_y = view.viewport.w / (2.0 * view.projection[1][1]);
#endif

#ifdef USE_OBB
    let focal_x = view.viewport.z / (2.0 * view.inverse_projection[0][0]);
    let focal_y = view.viewport.w / (2.0 * view.inverse_projection[1][1]);
#endif

    let limx = 1.3 * 0.5 * view.viewport.z / focal_x;
    let limy = 1.3 * 0.5 * view.viewport.w / focal_y;
    let txtz = t.x / t.z;
    let tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;

    let J = mat3x3(
        focal_x / t.z,
        0.0,
        -(focal_x * t.x) / (t.z * t.z),

        0.0,
        focal_y / t.z,
        -(focal_y * t.y) / (t.z * t.z),

        0.0, 0.0, 0.0,
    );

#ifdef USE_AABB
    let W = transpose(
        mat3x3<f32>(
            view.projection.x.xyz,
            view.projection.y.xyz,
            view.projection.z.xyz,
        )
    );
#endif

#ifdef USE_OBB
    let W = transpose(
        mat3x3<f32>(
            view.projection.x.xyz,
            view.projection.y.xyz,
            view.projection.z.xyz,
        )
    );
#endif

    let T = W * J;

    var cov = transpose(T) * transpose(Vrk) * T;
    // cov[0][0] += 0.3f;
    // cov[1][1] += 0.3f;

    return vec3<f32>(cov[0][0], cov[0][1], cov[1][1]);
}


fn world_to_clip(world_pos: vec3<f32>) -> vec4<f32> {
    let homogenous_pos = view.projection * view.inverse_view * vec4<f32>(world_pos, 1.0);
    return homogenous_pos / (homogenous_pos.w + 0.000000001);
}

fn in_frustum(clip_space_pos: vec3<f32>) -> bool {
    return abs(clip_space_pos.x) < 1.1
        && abs(clip_space_pos.y) < 1.1
        && abs(clip_space_pos.z - 0.5) < 0.5;
}


fn get_bounding_box_corner(
    cov2d: vec3<f32>,
    direction: vec2<f32>,
) -> vec4<f32> {
    // return vec4<f32>(offset, uv);

    let det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    let mid = 0.5 * (cov2d.x + cov2d.z);
    let lambda1 = mid + sqrt(max(0.1, mid * mid - det));
    let lambda2 = mid - sqrt(max(0.1, mid * mid - det));
    let x_axis_length = sqrt(lambda1);
    let y_axis_length = sqrt(lambda2);

    // let det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    // let mid = 0.5 * (cov2d.x + cov2d.z);
    // var discriminant = max(0.0, mid * mid - det);

    // let lambda1 = mid + sqrt(discriminant);
    // let lambda2 = mid - sqrt(discriminant);
    // let x_axis_length = sqrt(lambda1);
    // let y_axis_length = sqrt(lambda2);


#ifdef USE_AABB
    // creates a square AABB (inefficient fragment usage)
    let radius_px = 3.5 * max(x_axis_length, y_axis_length);
    let radius_ndc = vec2<f32>(
        radius_px / view.viewport.z,
        radius_px / view.viewport.w,
    );

    return vec4<f32>(
        2.0 * radius_ndc * direction,
        radius_px * direction,
    );
#endif

#ifdef USE_OBB
    // TODO: shouldn't require 3.5 stdevs
    let bounds = vec2<f32>(
        x_axis_length,
        y_axis_length,
    );

    // bounding box is aligned to the eigenvectors with proper width/height
    // collapse unstable eigenvectors to circle
    let threshold = 0.1;
    if (abs(lambda1 - lambda2) < threshold) {
        let circle = direction * max(x_axis_length, y_axis_length);
        return vec4<f32>(
            circle / view.viewport.zw,
            circle
        );
    }

    let eigvec1 = normalize(vec2<f32>(
        cov2d.y,
        lambda1 - cov2d.x
    ));
    let eigvec2 = vec2<f32>(
        -eigvec1.y,
        eigvec1.x
    );
    let rotation_matrix = mat2x2(
        eigvec1.x, eigvec2.x,
        eigvec1.y, eigvec2.y
    );

    let scaled_vertex = direction * bounds;

    return vec4<f32>(
        (scaled_vertex / view.viewport.z) * rotation_matrix,
        scaled_vertex
    );
#endif
}


@vertex
fn vs_points(
    @builtin(instance_index) instance_index: u32,
    @builtin(vertex_index) vertex_index: u32,
) -> GaussianOutput {
    var output: GaussianOutput;
    let splat_index = instance_index;
    // let splat_index = sorted_entries[instance_index][1];

    // let discard_quad = sorted_entries[instance_index][0] == 0xFFFFFFFFu;
    // if (discard_quad) {
    //     output.color = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    //     return output;
    // }

    let point = points[splat_index];
    let transformed_position = (uniforms.global_transform * point.position).xyz;

    let projected_position = world_to_clip(transformed_position);
    if (!in_frustum(projected_position.xyz)) {
        output.color = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        return output;
    }

    var quad_vertices = array<vec2<f32>, 4>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>( 1.0, -1.0),
        vec2<f32>( 1.0,  1.0),
    );

    let quad_index = vertex_index % 4u;
    let quad_offset = quad_vertices[quad_index];

    let ray_direction = normalize(transformed_position - view.world_position);
    output.color = vec4<f32>(
        spherical_harmonics_lookup(ray_direction, point.sh),
        point.scale_opacity.a
    );

    let cov2d = compute_cov2d(transformed_position, point.scale_opacity.rgb, point.rotation);

    // TODO: remove conic when OBB is used
    let det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    let det_inv = 1.0 / det;
    let conic = vec3<f32>(
        cov2d.z * det_inv,
        -cov2d.y * det_inv,
        cov2d.x * det_inv
    );
    output.conic = conic;

    let bb = get_bounding_box_corner(
        cov2d,
        quad_offset,
    );

    output.uv = (quad_offset + vec2<f32>(1.0)) * 0.5;
    output.major_minor = bb.zw;
    output.position = vec4<f32>(
        projected_position.xy + bb.xy,
        projected_position.zw
    );

    return output;
}

@fragment
fn fs_main(input: GaussianOutput) -> @location(0) vec4<f32> {
    // TODO: draw gaussian without conic (OBB)

#ifdef USE_AABB
    let d = -input.major_minor;
    let conic = input.conic;
    let power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;

    if (power > 0.0) {
        discard;
    }
#endif

#ifdef USE_OBB
    let norm_uv = input.uv * 2.0 - 1.0;
    let sigma = 1.0 / 3.5;
    let sigma_squared = sigma * sigma;
    let distance_squared = dot(norm_uv, norm_uv);

    let power = -distance_squared / (2.0 * sigma_squared);

    if (distance_squared > 3.5 * 3.5) {
        discard;
    }
#endif

#ifdef VISUALIZE_BOUNDING_BOX
    let uv = input.uv;
    let edge_width = 0.08;
    if (
        (uv.x < edge_width || uv.x > 1.0 - edge_width) ||
        (uv.y < edge_width || uv.y > 1.0 - edge_width)
    ) {
        return vec4<f32>(0.3, 1.0, 0.1, 1.0);
    }
#endif

    let alpha = exp(power);
    let final_alpha = alpha * input.color.a;
    return vec4<f32>(
        input.color.rgb * final_alpha,
        final_alpha,
    );
}
