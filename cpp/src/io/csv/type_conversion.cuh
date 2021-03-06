/*
 * Copyright (c) 2017-2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef CONVERSION_FUNCTIONS_CUH
#define CONVERSION_FUNCTIONS_CUH

#include "datetime_parser.cuh"
#include "utilities/wrapper_types.hpp"
#include <cuda_runtime_api.h>

/**---------------------------------------------------------------------------*
 * @brief Checks whether the given character is a whitespace character.
 * 
 * @param[in] ch The character to check
 * 
 * @return True if the input is whitespace, False otherwise
 *---------------------------------------------------------------------------**/
__inline__ __device__ bool isWhitespace(char ch) {
  return ch == '\t' || ch == ' ';
}

/**---------------------------------------------------------------------------*
 * @brief Scans a character stream within a range, and adjusts the start and end
 * indices of the range to ignore whitespace and quotation characters.
 * 
 * @param[in] data The character stream to scan
 * @param[in,out] start The start index to adjust
 * @param[in,out] end The end index to adjust
 * @param[in] quotechar The character used to denote quotes
 * 
 * @return Adjusted or unchanged start_idx and end_idx
 *---------------------------------------------------------------------------**/
__device__ void adjustForWhitespaceAndQuotes(const char* data, long* start,
                                             long* end, char quotechar = '\0') {
  while ((*start <= *end) &&
         (isWhitespace(data[*start]) || data[*start] == quotechar)) {
    (*start)++;
  }
  while ((*start < *end) &&
         (isWhitespace(data[*end]) || data[*end] == quotechar)) {
    (*end)--;
  }
}

/**---------------------------------------------------------------------------*
 * @brief Checks the given value is a user-defined boolean by checking against
 * a list of user-defined boolean values.
 * 
 * @tparam[in] value The value to check
 * @param[in] bool_values The list of user-defined boolean values against
 * @param[in] count The number of boolean values to check
 * 
 * @return True if the value is in the list, False otherwise
 *---------------------------------------------------------------------------**/
template <typename T>
__host__ __device__ bool isBooleanValue(T value, int32_t* bool_values,
                                        int32_t count) {
  for (int32_t i = 0; i < count; ++i) {
    if (static_cast<int32_t>(value) == bool_values[i]) {
      return true;
    }
  }
  return false;
}

/**---------------------------------------------------------------------------*
 * @brief Computes a 32-bit hash when given a byte stream and range.
 * 
 * MurmurHash3_32 implementation from
 * https://github.com/aappleby/smhasher/blob/master/src/MurmurHash3.cpp
 *
 * MurmurHash3 was written by Austin Appleby, and is placed in the public
 * domain. The author hereby disclaims copyright to this source code.
 * Note - The x86 and x64 versions do _not_ produce the same results, as the
 * algorithms are optimized for their respective platforms. You can still
 * compile and run any of them on any platform, but your performance with the
 * non-native version will be less than optimal.
 * 
 * This is a modified version of what is used for hash-join. The change is at
 * accept a char * key and range (start and end) so that the large raw CSV data
 * pointer could be used
 * 
 * @param[in] key The input data to hash
 * @param[in] start The start index of the input data
 * @param[in] end The end index of the input data
 * @param[in] seed An initialization value
 * 
 * @return The hash value
 *---------------------------------------------------------------------------**/
__host__ __device__ int32_t convertStrToHash(const char* key, long start,
                                             long end, uint32_t seed) {

  auto getblock32 = [] __host__ __device__ (const uint32_t* p,
                                            int i) -> uint32_t {
    // Individual byte reads for possible unaligned accesses
    auto q = (const uint8_t*)(p + i);
    return q[0] | (q[1] << 8) | (q[2] << 16) | (q[3] << 24);
  };

  auto rotl32 = [] __host__ __device__ (uint32_t x, int8_t r) -> uint32_t {
    return (x << r) | (x >> (32 - r));
  };

  auto fmix32 = [] __host__ __device__ (uint32_t h) -> uint32_t {
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
  };

  const int len = (end - start);
  const uint8_t* const data = (const uint8_t*)(key + start);
  const int nblocks = len / 4;
  uint32_t h1 = seed;
  constexpr uint32_t c1 = 0xcc9e2d51;
  constexpr uint32_t c2 = 0x1b873593;
  //----------
  // body
  const uint32_t* const blocks = (const uint32_t*)(data + nblocks * 4);
  for (int i = -nblocks; i; i++) {
    uint32_t k1 = getblock32(blocks, i);
    k1 *= c1;
    k1 = rotl32(k1, 15);
    k1 *= c2;
    h1 ^= k1;
    h1 = rotl32(h1, 13);
    h1 = h1 * 5 + 0xe6546b64;
  }
  //----------
  // tail
  const uint8_t* tail = (const uint8_t*)(data + nblocks * 4);
  uint32_t k1 = 0;
  switch (len & 3) {
    case 3:
      k1 ^= tail[2] << 16;
    case 2:
      k1 ^= tail[1] << 8;
    case 1:
      k1 ^= tail[0];
      k1 *= c1;
      k1 = rotl32(k1, 15);
      k1 *= c2;
      h1 ^= k1;
  };
  //----------
  // finalization
  h1 ^= len;
  h1 = fmix32(h1);
  return h1;
}

/**---------------------------------------------------------------------------*
 * @brief Structure for holding various options used when parsing and
 * converting CSV data to cuDF data type values.
 *---------------------------------------------------------------------------**/
struct ParseOptions {
  char delimiter;
  char terminator;
  char quotechar;
  char decimal;
  char thousands;
  char comment;
  bool keepquotes;
  bool doublequote;
  bool dayfirst;
  bool skipblanklines;
  int32_t* trueValues;
  int32_t* falseValues;
  int32_t trueValuesCount;
  int32_t falseValuesCount;
  bool multi_delimiter;
};

/**---------------------------------------------------------------------------*
 * @brief Default function for extracting a data value from a character string.
 * Handles all arithmetic data types; other data types are handled in
 * specialized template functions.
 *
 * @param[in] data The character string for parse
 * @param[in] start The index within data to start parsing from
 * @param[in] end The end index within data to end parsing
 * @param[in] opts The various parsing behavior options and settings
 *
 * @return The parsed and converted value
 *---------------------------------------------------------------------------**/
template <typename T>
__host__ __device__ T convertStrToValue(const char* data, long start, long end,
                                        const ParseOptions& opts) {
  T value = 0;

  // Handle negative values if necessary
  int32_t sign = 1;
  if (data[start] == '-') {
    sign = -1;
    start++;
  }

  // Handle the whole part of the number
  long index = start;
  while (index <= end) {
    if (data[index] == opts.decimal) {
      ++index;
      break;
    } else if (data[index] == 'e' || data[index] == 'E') {
      break;
    } else if (data[index] != opts.thousands) {
      value *= 10;
      value += data[index] - '0';
    }
    ++index;
  }

  if (std::is_floating_point<T>::value) {
    // Handle fractional part of the number if necessary
    int32_t divisor = 1;
    while (index <= end) {
      if (data[index] == 'e' || data[index] == 'E') {
        ++index;
        break;
      } else if (data[index] != opts.thousands) {
        value *= 10;
        value += data[index] - '0';
        divisor *= 10;
      }
      ++index;
    }

    // Handle exponential part of the number if necessary
    int32_t exponent = 0;
    while (index <= end) {
      if (data[index] == '-') {
        ++index;
        exponent = (data[index] - '0') * -1;
      } else {
        exponent *= 10;
        exponent += data[index] - '0';
      }
      ++index;
    }

    if (divisor > 1) {
      value /= divisor;
    }
    if (exponent != 0) {
      value *= exp10f(exponent);
    }
  }

  return value * sign;
}

template <>
__host__ __device__ cudf::date32 convertStrToValue<cudf::date32>(
    const char* data, long start, long end, const ParseOptions& opts) {
  return cudf::date32{parseDateFormat(data, start, end, opts.dayfirst)};
}

template <>
__host__ __device__ cudf::date64 convertStrToValue<cudf::date64>(
    const char* data, long start, long end, const ParseOptions& opts) {
  return cudf::date64{parseDateTimeFormat(data, start, end, opts.dayfirst)};
}

template <>
__host__ __device__ cudf::category convertStrToValue<cudf::category>(
    const char* data, long start, long end, const ParseOptions& opts) {
  constexpr int32_t HASH_SEED = 33;
  return cudf::category{convertStrToHash(data, start, end + 1, HASH_SEED)};
}

template <>
__host__ __device__ cudf::timestamp convertStrToValue<cudf::timestamp>(
    const char* data, long start, long end, const ParseOptions& opts) {
  return cudf::timestamp{convertStrToValue<int64_t>(data, start, end, opts)};
}

#endif
