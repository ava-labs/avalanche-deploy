#pragma once
#include <stddef.h>
#include <stdint.h>

void bls_keygen(uint8_t *sk_out32, const uint8_t *ikm, size_t ikm_len);
void bls_public_key(uint8_t *out48, const uint8_t *sk_bytes);
void bls_sign(uint8_t *out96, const uint8_t *sk_bytes,
              const uint8_t *msg, size_t msg_len,
              const uint8_t *dst, size_t dst_len);
