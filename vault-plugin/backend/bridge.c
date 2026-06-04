#include "blst_src/blst.h"
#include "bridge.h"

void bls_keygen(uint8_t *sk_out32, const uint8_t *ikm, size_t ikm_len) {
    blst_scalar sk;
    blst_keygen(&sk, ikm, ikm_len, NULL, 0);
    blst_bendian_from_scalar(sk_out32, &sk);
}

void bls_public_key(uint8_t *out48, const uint8_t *sk_bytes) {
    blst_scalar sk;
    blst_scalar_from_bendian(&sk, sk_bytes);
    blst_p1 pk_jac;
    blst_sk_to_pk_in_g1(&pk_jac, &sk);
    blst_p1_affine pk_aff;
    blst_p1_to_affine(&pk_aff, &pk_jac);
    blst_p1_affine_compress(out48, &pk_aff);
}

void bls_sign(uint8_t *out96, const uint8_t *sk_bytes,
              const uint8_t *msg, size_t msg_len,
              const uint8_t *dst, size_t dst_len) {
    blst_scalar sk;
    blst_scalar_from_bendian(&sk, sk_bytes);
    blst_p2 hash_jac;
    blst_hash_to_g2(&hash_jac, msg, msg_len, dst, dst_len, NULL, 0);
    blst_p2 sig_jac;
    blst_sign_pk_in_g1(&sig_jac, &hash_jac, &sk);
    blst_p2_affine sig_aff;
    blst_p2_to_affine(&sig_aff, &sig_jac);
    blst_p2_affine_compress(out96, &sig_aff);
}
