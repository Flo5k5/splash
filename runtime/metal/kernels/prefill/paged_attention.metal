#include "metal/kernels/common/paged_attention_tile.h"

// Prefill runs the shared device-operand page loop
// (splash_paged_attention_tile) over eight query rows of one KV head.

// Prefill split: KV heads (and each one's tile parts,
// splash_attention_tile_part) vary first, then query tiles, then history
// splits.
template <uint KVHeads, uint QueryHeadsPerKVHead, uint Parts, typename CacheElement>
inline void splash_prefill_attention_split_phase(
    device bfloat *queries, device float *partials,
    device float *statistics, device const SplashKvPage *page_table,
    constant SplashPrefillAttentionParams &params,
    threadgroup float *scores, threadgroup bfloat *probabilities,
    threadgroup float *row_max, threadgroup float *row_sum,
    threadgroup float *previous_scale, threadgroup atomic_uint *rescale, uint3 group,
    uint thread_index) {
  const uint split = group.z;
  const uint kv_head = group.x / Parts;
  const SplashAttentionTile tile =
      splash_attention_tile_part<QueryHeadsPerKVHead, SPLASH_PREFILL_ATTENTION_TILE_ROWS, Parts>(
          splash_prefill_attention_tile<KVHeads, QueryHeadsPerKVHead>(params, kv_head, group.y),
          group.x % Parts, params.split_count);
  if (!tile.active || split >= tile.splits)
    return;
  splash_paged_attention_tile<KVHeads, QueryHeadsPerKVHead,
                              SPLASH_PREFILL_ATTENTION_TILE_ROWS / Parts, CacheElement>(
      queries + tile.offset, page_table, params.kv, kv_head, tile.first_position,
      tile.active_rows, tile.splits, split, partials, statistics,
      tile.first_slot + split, scores, probabilities, row_max, row_sum,
      previous_scale, rescale, thread_index);
}

// Each fused row of the whole tile reduces the splits of its part's slots.
template <uint KVHeads, uint QueryHeadsPerKVHead, uint Parts>
inline void splash_prefill_attention_reduce_phase(
    device const float *partials, device const float *statistics,
    device bfloat *output,
    constant SplashPrefillAttentionParams &params, uint3 group,
    uint thread_index, threadgroup float *weights,
    threadgroup float *group_values) {
  constexpr ushort M = SPLASH_PREFILL_ATTENTION_TILE_ROWS * QueryHeadsPerKVHead;
  constexpr ushort PartM = M / Parts;
  constexpr ushort D = SplashKvHeadDimension;
  const uint fused_row = group.y;
  const SplashAttentionTile whole =
      splash_prefill_attention_tile<KVHeads, QueryHeadsPerKVHead>(params, group.x, group.z);
  if (!whole.active || fused_row >= M || thread_index >= D)
    return;
  const SplashAttentionTile tile =
      splash_attention_tile_part<QueryHeadsPerKVHead, SPLASH_PREFILL_ATTENTION_TILE_ROWS, Parts>(
          whole, fused_row / PartM, params.split_count);
  if (!tile.active) {
    output[whole.offset + ulong(fused_row) * D + thread_index] = bfloat(0.0f);
    return;
  }
  splash_attention_reduce_row<QueryHeadsPerKVHead,
                              SPLASH_PREFILL_ATTENTION_TILE_ROWS / Parts>(
      partials, statistics, output + tile.offset, tile.first_position,
      tile.active_rows, tile.splits, tile.first_slot, fused_row % PartM, thread_index,
      weights, group_values);
}

#define PAGED_PREFILL_SPLIT(Name, Heads, Group, Parts, CacheElement)           \
  kernel void Name(                                                            \
      device bfloat *queries [[buffer(0)]],                                    \
      device float *partials [[buffer(1)]],                                    \
      device float *statistics [[buffer(2)]],                                  \
      device const SplashKvPage *page_table [[buffer(3)]],                     \
      constant SplashPrefillAttentionParams &params [[buffer(4)]],             \
      uint3 group [[threadgroup_position_in_grid]],                            \
      uint thread_index [[thread_index_in_threadgroup]]) {                     \
    constexpr uint M = Group * SPLASH_PREFILL_ATTENTION_TILE_ROWS / Parts;     \
    constexpr uint N = SplashKvPageTokens;                                     \
    alignas(16) threadgroup float scores[M * N];                               \
    alignas(16) threadgroup bfloat probabilities[M * N];                       \
    threadgroup float row_max[M];                                              \
    threadgroup float row_sum[M];                                              \
    threadgroup float previous_scale[M];                                       \
    threadgroup atomic_uint rescale;                                           \
    splash_prefill_attention_split_phase<Heads, Group, Parts, CacheElement>(   \
        queries, partials, statistics, page_table, params, scores,             \
        probabilities, row_max, row_sum, previous_scale, &rescale, group,      \
        thread_index);                                                         \
  }

PAGED_PREFILL_SPLIT(prefill_attention_q8_split, 4, 6, SPLASH_ATTENTION_TILE_PARTS(6u), int8_t)
PAGED_PREFILL_SPLIT(prefill_attention_q8_split_kv2_g8, 2, 8, SPLASH_ATTENTION_TILE_PARTS(8u), int8_t)
PAGED_PREFILL_SPLIT(prefill_attention_q8_split_kv2_g16, 2, 16, SPLASH_ATTENTION_TILE_PARTS(16u), int8_t)
// BF16 shares the page loop and reduction, without quantization scales.
PAGED_PREFILL_SPLIT(prefill_attention_bf16_split, 4, 6, SPLASH_ATTENTION_TILE_PARTS(6u), bfloat)
PAGED_PREFILL_SPLIT(prefill_attention_bf16_split_kv2_g8, 2, 8, SPLASH_ATTENTION_TILE_PARTS(8u), bfloat)
PAGED_PREFILL_SPLIT(prefill_attention_bf16_split_kv2_g16, 2, 16, SPLASH_ATTENTION_TILE_PARTS(16u), bfloat)
#undef PAGED_PREFILL_SPLIT

#define PAGED_PREFILL_REDUCE(Name, Heads, Group, Parts)                        \
  kernel void Name(                                                            \
      device const float *partials [[buffer(0)]],                              \
      device const float *statistics [[buffer(1)]],                            \
      device bfloat *output [[buffer(2)]],                                     \
      constant SplashPrefillAttentionParams &params [[buffer(3)]],             \
      uint3 group [[threadgroup_position_in_grid]],                            \
      uint thread_index [[thread_index_in_threadgroup]]) {                     \
    threadgroup float weights[SplashPrefillMaximumSplits];                     \
    threadgroup float group_values[8];                                         \
    splash_prefill_attention_reduce_phase<Heads, Group, Parts>(                \
        partials, statistics, output, params, group, thread_index, weights,    \
        group_values);                                                         \
  }
PAGED_PREFILL_REDUCE(prefill_attention_reduce, 4, 6, SPLASH_ATTENTION_TILE_PARTS(6u))
PAGED_PREFILL_REDUCE(prefill_attention_reduce_kv2_g8, 2, 8, SPLASH_ATTENTION_TILE_PARTS(8u))
PAGED_PREFILL_REDUCE(prefill_attention_reduce_kv2_g16, 2, 16, SPLASH_ATTENTION_TILE_PARTS(16u))
#undef PAGED_PREFILL_REDUCE
