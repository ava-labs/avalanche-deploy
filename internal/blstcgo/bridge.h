#pragma once
#include <stddef.h>
#include <stdint.h>

/* Validate a 32-byte big-endian BLS12-381 scalar. Returns 1 if valid. */
int  bls_sk_valid(const uint8_t *sk_bytes);

/* Derive the 48-byte compressed G1 public key from a 32-byte secret key. */
void bls_public_key(uint8_t *out48, const uint8_t *sk_bytes);

/* Hash msg to G2 and sign it; write 96-byte compressed signature to out96. */
void bls_sign(uint8_t *out96, const uint8_t *sk_bytes,
              const uint8_t *msg, size_t msg_len,
              const uint8_t *dst, size_t dst_len);

/* HKDF-based key derivation (BLS key gen spec). ikm must be >= 32 bytes.
   Writes a valid 32-byte scalar (guaranteed < curve order r) to sk_out32. */
void bls_keygen(uint8_t *sk_out32, const uint8_t *ikm, size_t ikm_len);
