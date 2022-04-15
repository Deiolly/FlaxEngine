// Copyright (c) 2012-2022 Wojciech Figat. All rights reserved.

#include "./Flax/Common.hlsl"
#include "./Flax/Collisions.hlsl"

#define GLOBAL_SDF_RASTERIZE_CHUNK_SIZE 32
#define GLOBAL_SDF_RASTERIZE_CHUNK_MARGIN 4
#define GLOBAL_SDF_MIP_FLOODS 5
#define GLOBAL_SDF_WORLD_SIZE 60000.0f

// Global SDF data for a constant buffer
struct GlobalSDFData
{
	float4 CascadePosDistance[4];
	float4 CascadeVoxelSize;
	float3 Padding;
	float Resolution;
};

// Global SDF ray trace settings.
struct GlobalSDFTrace
{
	float3 WorldPosition;
	float MinDistance;
	float3 WorldDirection;
	float MaxDistance;
	float StepScale;
	bool NeedsHitNormal;

	void Init(float3 worldPosition, float3 worldDirection, float minDistance, float maxDistance, float stepScale = 1.0f)
	{
		WorldPosition = worldPosition;
		WorldDirection = worldDirection;
		MinDistance = minDistance;
		MaxDistance = maxDistance;
		StepScale = stepScale;
		NeedsHitNormal = false;
	}
};

// Global SDF ray trace hit information.
struct GlobalSDFHit
{
	float3 HitNormal;
	float HitTime;
	uint HitCascade;
	uint StepsCount;
	
	bool IsHit()
	{
		return HitTime >= 0.0f;
	}

	float3 GetHitPosition(const GlobalSDFTrace trace)
	{
		return trace.WorldPosition + trace.WorldDirection * HitTime;
	}
};

// Samples the Global SDF and returns the distance to the closest surface (in world units) at the given world location.
float SampleGlobalSDF(const GlobalSDFData data, Texture3D<float> tex[4], float3 worldPosition)
{
	float distance = data.CascadePosDistance[3].w * 2.0f;
	if (distance <= 0.0f)
		return GLOBAL_SDF_WORLD_SIZE;
	UNROLL
	for (uint cascade = 0; cascade < 4; cascade++)
	{
		float4 cascadePosDistance = data.CascadePosDistance[cascade];
		float cascadeMaxDistance = cascadePosDistance.w * 2;
		float3 posInCascade = worldPosition - cascadePosDistance.xyz;
		float3 cascadeUV = posInCascade / cascadeMaxDistance + 0.5f;
		float cascadeDistance = tex[cascade].SampleLevel(SamplerLinearClamp, cascadeUV, 0);
		if (cascadeDistance < 1.0f && !any(cascadeUV < 0) && !any(cascadeUV > 1))
		{
			distance = cascadeDistance * cascadeMaxDistance;
			break;
		}
	}
	return distance;
}

// Samples the Global SDF and returns the gradient vector (derivative) at the given world location. Normalize it to get normal vector.
float3 SampleGlobalSDFGradient(const GlobalSDFData data, Texture3D<float> tex[4], float3 worldPosition, out float distance)
{
	float3 gradient = float3(0, 0.00001f, 0);
	distance = GLOBAL_SDF_WORLD_SIZE;
	if (data.CascadePosDistance[3].w <= 0.0f)
		return gradient;
	UNROLL
	for (uint cascade = 0; cascade < 4; cascade++)
	{
		float4 cascadePosDistance = data.CascadePosDistance[cascade];
		float cascadeMaxDistance = cascadePosDistance.w * 2;
		float3 posInCascade = worldPosition - cascadePosDistance.xyz;
		float3 cascadeUV = posInCascade / cascadeMaxDistance + 0.5f;
		float cascadeDistance = tex[cascade].SampleLevel(SamplerLinearClamp, cascadeUV, 0);
		if (cascadeDistance < 0.9f && !any(cascadeUV < 0) && !any(cascadeUV > 1))
		{
			float texelOffset = 1.0f / data.Resolution;
			float xp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x + texelOffset, cascadeUV.y, cascadeUV.z), 0).x;
			float xn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x - texelOffset, cascadeUV.y, cascadeUV.z), 0).x;
			float yp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y + texelOffset, cascadeUV.z), 0).x;
			float yn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y - texelOffset, cascadeUV.z), 0).x;
			float zp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y, cascadeUV.z + texelOffset), 0).x;
			float zn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y, cascadeUV.z - texelOffset), 0).x;
			gradient = float3(xp - xn, yp - yn, zp - zn) * cascadeMaxDistance;
			distance = cascadeDistance * cascadeMaxDistance;
			break;
		}
	}
	return gradient;
}

// Ray traces the Global SDF.
GlobalSDFHit RayTraceGlobalSDF(const GlobalSDFData data, Texture3D<float> tex[4], Texture3D<float> mips[4], const GlobalSDFTrace trace)
{
	GlobalSDFHit hit = (GlobalSDFHit)0;
	hit.HitTime = -1.0f;
	float chunkSizeDistance = (float)GLOBAL_SDF_RASTERIZE_CHUNK_SIZE / data.Resolution; // Size of the chunk in SDF distance (0-1)
	float chunkMarginDistance = (float)GLOBAL_SDF_RASTERIZE_CHUNK_MARGIN / data.Resolution; // Size of the chunk margin in SDF distance (0-1)
	float nextIntersectionStart = 0.0f;
	float traceMaxDistance = min(trace.MaxDistance, data.CascadePosDistance[3].w * 2);
	float3 traceEndPosition = trace.WorldPosition + trace.WorldDirection * traceMaxDistance;
	UNROLL
	for (uint cascade = 0; cascade < 4 && hit.HitTime < 0.0f; cascade++)
	{
		float4 cascadePosDistance = data.CascadePosDistance[cascade];
		float cascadeMaxDistance = cascadePosDistance.w * 2;
		float voxelSize = data.CascadeVoxelSize[cascade];
		float voxelExtent = voxelSize * 0.5f;
		float cascadeMinStep = voxelSize;

		// Hit the cascade bounds to find the intersection points
		float2 intersections = LineHitBox(trace.WorldPosition, traceEndPosition, cascadePosDistance.xyz - cascadePosDistance.www, cascadePosDistance.xyz + cascadePosDistance.www);
		intersections.xy *= traceMaxDistance;
		intersections.x = max(intersections.x, nextIntersectionStart);
		if (intersections.x >= intersections.y)
			break;

		// Skip the current cascade tracing on the next cascade
		nextIntersectionStart = intersections.y;

		// Walk over the cascade SDF
		uint step = 0;
		float stepTime = intersections.x;
		LOOP
		for (; step < 250 && stepTime < intersections.y; step++)
		{
			float3 stepPosition = trace.WorldPosition + trace.WorldDirection * stepTime;

			// Sample SDF
			float3 posInCascade = stepPosition - cascadePosDistance.xyz;
			float3 cascadeUV = posInCascade / cascadeMaxDistance + 0.5f;
			float stepDistance = mips[cascade].SampleLevel(SamplerLinearClamp, cascadeUV, 0);
			if (stepDistance < chunkSizeDistance)
			{
				float stepDistanceTex = tex[cascade].SampleLevel(SamplerLinearClamp, cascadeUV, 0);
				if (stepDistanceTex < chunkMarginDistance * 2)
				{
					stepDistance = stepDistanceTex;
				}
			}
			else
			{
				// Assume no SDF nearby so perform a jump
				stepDistance = chunkSizeDistance;
			}
			stepDistance *= cascadeMaxDistance;

			// Detect surface hit
			float minSurfaceThickness = voxelExtent * saturate(stepTime / (voxelExtent * 2.0f));
			if (stepDistance < minSurfaceThickness)
			{
				// Surface hit
				hit.HitTime = max(stepTime + stepDistance - minSurfaceThickness, 0.0f);
				hit.HitCascade = cascade;
				if (trace.NeedsHitNormal)
				{
					// Calculate hit normal from SDF gradient
					float texelOffset = 1.0f / data.Resolution;
					float xp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x + texelOffset, cascadeUV.y, cascadeUV.z), 0).x;
					float xn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x - texelOffset, cascadeUV.y, cascadeUV.z), 0).x;
					float yp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y + texelOffset, cascadeUV.z), 0).x;
					float yn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y - texelOffset, cascadeUV.z), 0).x;
					float zp = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y, cascadeUV.z + texelOffset), 0).x;
					float zn = tex[cascade].SampleLevel(SamplerLinearClamp, float3(cascadeUV.x, cascadeUV.y, cascadeUV.z - texelOffset), 0).x;
					hit.HitNormal = normalize(float3(xp - xn, yp - yn, zp - zn));
				}
				break;
			}

			// Move forward
			stepTime += max(stepDistance * trace.StepScale, cascadeMinStep);
		}
		hit.StepsCount += step;
	}
	return hit;
}