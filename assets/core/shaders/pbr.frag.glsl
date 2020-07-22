#version 450
#extension GL_GOOGLE_include_directive : enable

#include "library/lighting.glsl"
#include "library/pbr.glsl"
#include "library/common.glsl"
#include "clustered/frustum.glsl"

layout(set = 2, binding = 0) uniform Material {
    vec4 color;
    // (metallic, roughness, metallic_amount, roughness_amount)
    vec4 pbr_info;
};

layout(set = 2, binding = 1) uniform sampler tex_sampler;
layout(set = 2, binding = 2) uniform sampler brdf_sampler;
layout(set = 2, binding = 3) uniform texture2D main_map;
layout(set = 2, binding = 4) uniform texture2D normal_map;
layout(set = 2, binding = 5) uniform texture2D metallic_roughness_map;

layout(set = 3, binding = 0) uniform textureCube irradiance_cube_map;
layout(set = 3, binding = 1) uniform textureCube spec_cube_map;
layout(set = 3, binding = 2) uniform texture2D spec_brdf_map;

layout(set = 1, binding = 2) readonly buffer Frustums {
    Frustum frustums[];
};

layout(set = 1, binding = 3) readonly buffer GlobalIndices {
    LightIndexSet light_index_list[];
};

layout(location = 0) in vec2 i_uv;
layout(location = 1) in vec3 i_normal;
layout(location = 2) in vec3 i_position;
layout(location = 3) in vec3 i_tangent;
layout(location = 4) in float i_tbn_handedness;
layout(location = 5) in vec4 i_clip_position;
layout(location = 6) in vec4 i_view_position;
layout(location = 0) out vec4 outColor;

const float roughnessRescale = 1.0;
const float specularIntensity = 0.0;

const float PI = 3.14159265358979323;

vec3 Uncharted2ToneMapping(vec3 color)
{
	float A = 0.15;
	float B = 0.50;
	float C = 0.10;
	float D = 0.20;
	float E = 0.02;
	float F = 0.30;
	float W = 11.2;
	float exposure = 2.;
	color *= exposure;
	color = ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
	float white = ((W * (A * W + C * B) + D * E) / (W * (A * W + B) + D * F)) - E / F;
	color /= white;
	color = pow(color, vec3(1. / 1.2));
	return color;
}

float DistributionGGX(vec3 N, vec3 H, float roughness)
{
    float a      = roughness*roughness;
    float a2     = a*a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;
	
    float num   = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
	
    return num / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;

    float num   = NdotV;
    float denom = NdotV * (1.0 - k) + k;
	
    return num / denom;
}
float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2  = GeometrySchlickGGX(NdotV, roughness);
    float ggx1  = GeometrySchlickGGX(NdotL, roughness);
	
    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}   

vec3 get_clip_position() {
    return i_clip_position.xyz / i_clip_position.w;
}

// TODO: Pass view position and clip position in via a parameter so we can share this code with other shaders
// in lighting.glsl
uvec3 compute_froxel() {
    // normalize clip position to 0-1 in xy
    vec2 scale = get_clip_position().xy * 0.5 + 0.5;
    vec2 frustum_raw = scale * vec2(cluster_count.xy);
    uvec2 frustum_xy = uvec2(floor(frustum_raw));
    float depth = i_view_position.z;
    uint depth_frustum = uint(floor((depth / light_num.w) * cluster_count.z)); // light_num.w is the max depth.
    return uvec3(frustum_xy, min(depth_frustum, cluster_count.z - 1));
}

// TODO: Point-lights?
void main() {

    // Debug froxel code:
    // TODO: Perhaps move this into it's own shader that we can render for debugging?
    // uint z = compute_froxel().z;
    // for (int x = 0; x < cluster_count.x; ++x) {
    //     for (int y = 0; y < cluster_count.y; ++y) {
    //         uint frustum_index = get_frustum_list_index(uvec2(x, y), cluster_count.xy);
    //         Frustum frustum = frustums[frustum_index];
    //         if (contains_point(frustum, i_view_position.xyz)) {
    //             uint total_count = light_index_list[get_cluster_list_index(uvec3(x, y, z), cluster_count.xyz)].count;
    //             vec4 color_dif = vec4(vec3(x, y, z) / vec3(cluster_count.xy - 1, 3), 1.0); 
    //             // Lerps between black and blue depending on the total number of lights in this "froxel".
    //             // Good for measuring how "complex" the lighting is in a given scene.
    //             outColor = vec4(mix(vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 1.0), float(total_count) / MAX_LIGHTS), 1.0);
    //             return;
    //         } else {
    //         }
    //     }
    // }
    // return;

    vec3 main_color = texture(sampler2D(main_map, tex_sampler), i_uv).rgb * color.rgb;
    
    vec2 metallic_roughness = texture(sampler2D(metallic_roughness_map, tex_sampler), i_uv).xy;
    float metallic = mix(metallic_roughness.x, pbr_info.x, pbr_info.z);
    float roughness = mix(metallic_roughness.y, pbr_info.y, pbr_info.w);
    
    vec3 normal = texture(sampler2D(normal_map, tex_sampler), i_uv).rgb;
    normal = normal * 2.0 - 1.0;
    vec3 V = normalize(camera_pos.xyz - i_position.xyz);
    vec3 N = normalize(i_normal);
    vec3 T = normalize(i_tangent);
    vec3 B = cross(N, T) * i_tbn_handedness;
    mat3 TBN = mat3(T, B, N);
    N = TBN * normalize(normal);
    
    vec3 R = reflect(V, N);

    vec3 ambient_irradiance = texture(samplerCube(irradiance_cube_map, tex_sampler), N).rgb;
    
    // Convert irradiance to radiance
    ambient_irradiance = (ambient_irradiance / 3.145) * 1.0; // 1.0 is enviroment scale

    // calculate reflectance at normal incidence; if dia-electric (like plastic) use F0 
    // of 0.04 and if it's a metal, use the albedo color as F0 (metallic workflow)
    vec3 F0 = vec3(0.04); 
    F0 = mix(F0, main_color.rgb, metallic);

    // ambient lighting (we now use IBL as the ambient term)
    vec3 F = fresnelSchlickRoughness(max(dot(N, V), 0.0), F0, roughness);
    
    vec3 kS = F;
    vec3 kD = 1.0 - kS;
    kD *= 1.0 - metallic;
    vec3 diffuse = ambient_irradiance * main_color.rgb;
    
    vec3 prefilteredColor = textureLod(samplerCube(spec_cube_map, tex_sampler), R, roughness * MAX_SPEC_LOD).rgb;
    vec2 brdf  = texture(sampler2D(spec_brdf_map, brdf_sampler), vec2(max(dot(N, V), 0), 1.0 - roughness)).rg;
    vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);

    vec3 ambient = (kD * diffuse + specular);

    // Directional Lighting
    vec3 light_acc = vec3(0.0);
    for (int i=0; i < int(light_num.x) && i < MAX_LIGHTS; ++i) {

        DirectionalLight light = directional_lights[i];
        // calculate per-light radiance
        vec3 L = normalize(light.direction.xyz);
        vec3 H = normalize(V + L);
        vec3 radiance = light.color.xyz * light.color.w; // w is intensity       
        
        // cook-torrance brdf
        float NDF = DistributionGGX(N, H, roughness);        
        float G   = GeometrySmith(N, V, L, roughness);      
        vec3 F    = fresnelSchlick(max(dot(H, V), 0.0), F0);       
        
        vec3 kS = F;
        vec3 kD = vec3(1.0) - kS;
        kD *= 1.0 - metallic;	  
        
        vec3 numerator    = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        vec3 specular     = numerator / max(denominator, 0.001);  
            
        // add to outgoing radiance Lo
        float NdotL = max(dot(N, L), 0.0);                
        light_acc += (kD * main_color / PI + specular) * radiance * NdotL; 
    }

    // Point Lighting
    uvec3 froxel = compute_froxel();
    uint froxel_index = get_cluster_list_index(froxel, cluster_count.xyz);
    uint count = light_index_list[froxel_index].count; // Total number of lights in a froxel maxes out at 128.
    for (uint l = 0; l < count; ++l) {
        PointLight light = point_lights[light_index_list[froxel_index].indices[l]];
        // calculate per-light radiance
        vec3 L = light.position.xyz - i_position.xyz;
        const float dist2 = dot(L, L);
	    const float range2 = light.attenuation.x * light.attenuation.x;

        if (dist2 < range2)
	    {
            vec3 Lunnormalized = L;
            float dist = sqrt(dist2);
            L /= dist;

            vec3 H = normalize(V + L);

            vec3 radiance = light.color.xyz * light.color.w; // w is intensity
            
            // cook-torrance brdf
            float NDF = DistributionGGX(N, H, roughness);        
            float G   = GeometrySmith(N, V, L, roughness);      
            vec3 F    = fresnelSchlick(max(dot(H, V), 0.0), F0);  

            vec3 kS = F;
            vec3 kD = vec3(1.0) - kS;
            kD *= 1.0 - metallic;	  

            vec3 numerator    = NDF * G * F;
            float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
            vec3 specular     = numerator / max(denominator, 0.001);  

            float att = saturate(1.0 - (dist2 / range2));
            float attenuation = att * att;
            radiance *= attenuation;

            // add to outgoing radiance Lo
            float NdotL = max(dot(N, L), 0.0);                
            light_acc += (kD * main_color / PI + specular) * radiance * NdotL; 
        }     
    }

    vec3 color = ambient + light_acc; //Uncharted2ToneMapping(ambient + light_acc);

    outColor = vec4(color, 1.0);
}