#version 450

// base 

struct Camera {
    vec3 origin; // 0
    vec3 lower_left_corner; //4
    vec3 horizontal; // 8
    vec3 vertical; // 12
    vec3 u; // 16
    vec3 v; // 20
    float lens_radius;
};

struct Attribute3d {
    vec3 a;
    vec3 b;
    vec3 c;
};

struct Attribute2d {
    vec2 a;
    vec2 b;
    vec2 c;
};

#define LAMBERTIAN 0
#define DIFFUSE_LIGHT 1

#define SIDE_FRONT 0
#define SIDE_BACK 1
#define SIDE_DOUBLE 2

struct Material {
    float kind;
    float side;
    vec3 color;
};

struct Triangle {
    Attribute3d position;
    Attribute3d normal;
    Attribute2d uv;
    Material material;
};

struct Ray {
    vec3 origin;
    vec3 dir;
};

struct HitRecord {
    vec3 p;
    vec3 normal;
    float t;
    float u;
    float v;
    bool front_face;
};

vec3 at(Ray r, float t) {
    return r.origin + r.dir * t;
}

void set_front_face_and_normal(in out HitRecord rec, bool front_face, vec3 outward_normal) {
    rec.front_face = front_face;
    rec.normal = rec.front_face ? outward_normal : -outward_normal;
}

// layout

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

layout(std140, set = 0, binding = 0) uniform Config {
    float image_width;       // 0
    float image_height;      // 1
    float samples_per_pixel; // 2
    float max_depth;         // 3
    Camera camera;           // 4
    vec3 background;         // 4 + 24
};

layout(std140, set = 0, binding = 1) buffer ColorBuffer {
    vec4 colorBuffer[];
};

layout(std140, set = 0, binding = 2) buffer PrimitiveBuffer {
    Triangle triangles[];
};

layout(set = 0, binding = 3) buffer RandomBuffer {
    float randomData[];
};

layout(constant_id = 0) const uint primitive_count = 0;
layout(constant_id = 1) const uint random_count = 0;

// functions

float rand(vec2 co){
    float s = sin(dot(co, vec2(23.98123, 76.3849)));
    uint i = uint((s < 0.0 ? s + 1.0 : s) * 10000000.0);
    i = i % random_count;
    return randomData[i];
}


float random_in_range(vec2 co, float from, float to) {
    return from + (to - from) * rand(co); 
}

vec3 random_in_unit_disc(vec2 co) {
    vec3 p = vec3(0);
    for (int i = 0; i < 100; i++) {
        float r1 = random_in_range(vec2(co), -1.0, 1.0);
        float r2 = random_in_range(vec2(r1), -1.0, 1.0);
        p = vec3(r1, r2, 0.0);
        if (length(p) < 1.0) {
            return p;
        }
    }
    return normalize(p);
}

vec3 random_in_unit_sphere(vec2 co) {
    vec3 p = vec3(0);
    for (int i = 0; i < 100; i++) {
        float r1 = random_in_range(vec2(co), -1.0, 1.0);
        float r2 = random_in_range(vec2(r1), -1.0, 1.0);
        float r3 = random_in_range(vec2(r2), -1.0, 1.0);
        p = vec3(r1, r2, r3);
        if (length(p) < 1.0) {
            return p;
        }
    }
    return normalize(p);
}

bool near_zero(vec3 v) {
    float s = 1e-8;
    return abs(v.x) < s && abs(v.y)  < s && abs(v.z) < s;
}

bool hit_triangle(in Triangle tr, Ray r, float t_min, float t_max, in out HitRecord rec) {
    vec3 a = tr.position.a;
    vec3 b = tr.position.b;
    vec3 c = tr.position.c;

    vec3 na = tr.normal.a;
    vec3 nb = tr.normal.b;
    vec3 nc = tr.normal.c;

    vec2 ta = tr.uv.a;
    vec2 tb = tr.uv.b;
    vec2 tc = tr.uv.c;

    vec3 e1 = b - a;
    vec3 e2 = c - a;
    vec3 x = cross(r.dir, e2);
    float d = dot(e1, x);
    float eps = 1e-6;

    if (d > -eps && d < eps) {
        return false;
    }

    float f = 1.0 / d;
    vec3 s = r.origin - a;
    vec3 y = cross(s, e1);
    float t = f * dot(e2, y);

    if (t < t_min || t_max < t) {
        return false;
    }

    float u = f * dot(s, x);
    if (u < 0.0 || u > 1.0) {
        return false;
    }

    float v = f * dot(r.dir, y);
    if (v < 0.0 || v > 1.0 || u + v > 1.0) {
        return false;
    }

    float w = 1.0 - u - v;
    vec3 face_normal = normalize(cross(b - a, c - a));

    rec.t = t;
    rec.p = at(r, rec.t);
    vec3 outward_normal = na * w + nb * u + nc * v;
    bool front_face = dot(r.dir, face_normal) < 0.0;
    set_front_face_and_normal(rec, front_face, outward_normal);
    vec2 uv = ta * w + tb * u + tc * v;
    rec.u = uv.x;
    rec.v = uv.y;

    return true;
}

bool material_scatter(in Material material, Ray r, in out HitRecord rec, out vec3 attenuation, out Ray scattered) {
    if (int(material.kind) == LAMBERTIAN) {
        vec3 scatter_direction = rec.normal + normalize(random_in_unit_sphere(r.dir.xy));

        if (near_zero(scatter_direction)) {
            scatter_direction = rec.normal;
        }

        scattered = Ray(rec.p, scatter_direction);
        attenuation = material.color;
        return true;
    }

    return false;
}

vec3 material_emit(in Material material, in HitRecord rec) {
    if (int(material.kind) == DIFFUSE_LIGHT) {
        bool should_emit = false;
        switch (int(material.side)) {
            case SIDE_FRONT:
                should_emit = rec.front_face;
                break;
            case SIDE_BACK:
                should_emit = !rec.front_face;
                break;
            case SIDE_DOUBLE:
                should_emit = true;
                break;
        }

        if (should_emit) {
            return material.color;
        }
    }

    return vec3(0.0, 0.0, 0.0);
}

vec3 ray_color(in Ray r) {
    Ray current_ray = r;
    vec3 current_attenuation = vec3(1.0, 1.0, 1.0);
    float depth = max_depth;

    while (depth > 0.0) {
        bool has_collision = false;
        bool has_scatter = false;
        vec3 attenuation = vec3(0);
        vec3 emitted = vec3(0);
        Ray scattered = Ray(vec3(0), vec3(0));
        HitRecord rec = HitRecord(
            vec3(0),
            vec3(0),
            0.0,
            0.0,
            0.0,
            false
        );

        float t_min = 0.001;
        float t_max = 1000000.0;

        // find first collided object
        for (int i = 0; i < primitive_count; i++) {
            Triangle triangle = triangles[i];

            if (hit_triangle(triangle, current_ray, t_min, t_max, rec)) {
                has_collision = true;
                has_scatter = material_scatter(
                    triangle.material,
                    current_ray,
                    rec,
                    attenuation,
                    scattered
                );
                emitted = material_emit(
                    triangle.material,
                    rec
                );
                current_ray = scattered;
                t_max = rec.t;
                break;
            }
        }

        // process scattered ray
        if (has_collision) {
            depth -= 1.0;

            if (!has_scatter) {
                return current_attenuation * emitted;
            } else {
                current_attenuation = (current_attenuation * attenuation) + emitted;
            }
        } else {
            return current_attenuation * background;
        }
    }

    // maximim depth
    return vec3(0.0, 0.0, 0.0);
}

Ray camera_get_ray(vec2 st) {
    vec3 rd = random_in_unit_disc(st) * camera.lens_radius;
    vec3 offset = camera.u * rd.x + camera.v * rd.y;

    return Ray(
        camera.origin + offset,
        camera.lower_left_corner + st.x * camera.horizontal + st.y * camera.vertical - offset
    );
}

// main

void main() {
    uint idx = gl_GlobalInvocationID.x;

    // calculate uv
    uint x = idx % uint(image_width);
    uint y = (idx - x) / uint(image_width);

    // calculate color
    vec3 pixel_color = vec3(0);

    // antialiasing
    for (int i = 0; i < int(samples_per_pixel); i++) {
        float dp = float(i) / samples_per_pixel;

        float r1 = rand(vec2(dp));
        float r2 = rand(vec2(r1));

        float u = (float(x) + r1) / (image_width - 1);
        float vv = (float(y) + r2) / (image_height - 1);
        float v = 1.0 - vv;

        vec2 uv = vec2(u, v);

        Ray ray = camera_get_ray(uv);

        pixel_color += ray_color(ray);
    }

    pixel_color /= float(samples_per_pixel);

    // float u = (float(x)) / (image_width - 1);
    // float vv = (float(y)) / (image_height - 1);
    // float v = 1.0 - vv;

    // vec2 uv = vec2(u, v);
    // Ray ray = camera_get_ray(uv);

    colorBuffer[idx] = vec4(pixel_color, 1.0);
}