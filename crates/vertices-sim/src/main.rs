use vertices_core::{MAX_ENVELOPE_BYTES, MAX_SIGNING_BYTES, ObservationBuilder, PayloadCodec};
use vertices_crypto::software::SoftwareEd25519Signer;
use vertices_crypto::{Ed25519Signer, sign_observation};

fn main() {
    // A deterministic desktop identity is intentional: it makes protocol
    // vectors repeatable. Real devices receive hardware-backed keys.
    let signer = SoftwareEd25519Signer::from_seed([0x42; 32]);
    let builder = ObservationBuilder::<96>::new(
        *b"vertices-device1",
        1,
        1_725_000_000,
        b"temperature-celsius=21.5",
        PayloadCodec { id: 1, version: 1 },
        b"ipfs://bafy-vertices-reference-example",
    )
    .expect("static observation is valid");
    let observation = sign_observation(&signer, builder).expect("software signing succeeds");

    let mut signing_bytes = [0; MAX_SIGNING_BYTES];
    let signing_len = observation
        .signing_bytes(&mut signing_bytes)
        .expect("fixed buffer fits");
    signer
        .verify(&signing_bytes[..signing_len], &observation.signed.signature)
        .expect("signature verifies");

    let mut envelope = [0; MAX_ENVELOPE_BYTES];
    let envelope_len = observation
        .encode_cbor(&mut envelope)
        .expect("fixed buffer fits");
    let content_hash = observation.content_hash().expect("hashable envelope");

    println!("Vertices reference observation");
    println!("device_id: 0x{}", hex::encode(observation.signed.device_id));
    println!("ed25519_public_key: 0x{}", hex::encode(signer.public_key()));
    println!("sequence: {}", observation.signed.sequence);
    println!("timestamp: {}", observation.signed.timestamp);
    println!(
        "metadata_uri: {}",
        core::str::from_utf8(observation.metadata_uri()).unwrap()
    );
    println!("signature: 0x{}", hex::encode(observation.signed.signature));
    println!(
        "canonical_cbor: 0x{}",
        hex::encode(&envelope[..envelope_len])
    );
    println!("content_hash: 0x{}", hex::encode(content_hash));
    println!("verified: ed25519 signature over domain-separated deterministic CBOR");
}
