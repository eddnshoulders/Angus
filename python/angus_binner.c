#include <stddef.h>
#include <stdint.h>

size_t angus_bin_words(const uint32_t *words,
                       size_t word_count,
                       uint64_t *sum_bins,
                       uint32_t *count_bins,
                       size_t n_bins)
{
    size_t valid = 0;
    size_t samples = word_count / 2;

    for (size_t i = 0; i < samples; ++i) {
        uint32_t tdc = words[(2 * i) + 0];
        if (tdc >= n_bins) {
            continue;
        }

        uint32_t word1 = words[(2 * i) + 1];
        uint32_t pressure = (word1 >> 4) & 0x0FFFu;
        sum_bins[tdc] += (uint64_t)pressure;
        count_bins[tdc] += 1u;
        valid += 1;
    }

    return valid;
}

void angus_pack_average(const uint64_t *sum_bins,
                        const uint32_t *count_bins,
                        uint32_t *out_words,
                        size_t n_bins)
{
    for (size_t i = 0; i < n_bins; ++i) {
        uint32_t pressure = 0;
        uint32_t count = count_bins[i];

        if (count != 0u) {
            uint64_t rounded = sum_bins[i] + ((uint64_t)count / 2u);
            uint64_t avg = rounded / (uint64_t)count;
            pressure = avg > 0x0FFFu ? 0x0FFFu : (uint32_t)avg;
        }

        out_words[(2 * i) + 0] = (uint32_t)i;
        out_words[(2 * i) + 1] = pressure << 4;
    }
}
