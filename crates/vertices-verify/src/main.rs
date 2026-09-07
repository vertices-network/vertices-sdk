use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use std::collections::BTreeMap;
use vertices_core::{MAX_SIGNING_BYTES, SignedObservation, sha256};

struct Arguments {
    public_key: [u8; 32],
    canonical_cbor: Vec<u8>,
    metadata_uri: String,
    event_device_id: [u8; 16],
    event_content_hash: [u8; 32],
    event_sequence: u64,
    event_timestamp: u64,
    event_signature: [u8; 64],
}

fn decode_hex<const N: usize>(value: &str, name: &str) -> Result<[u8; N], String> {
    let decoded = hex::decode(value.strip_prefix("0x").unwrap_or(value))
        .map_err(|_| format!("{name} must be hexadecimal"))?;
    decoded
        .try_into()
        .map_err(|_: Vec<u8>| format!("{name} must be {N} bytes"))
}

fn parse_arguments() -> Result<Arguments, String> {
    let values: Vec<String> = std::env::args().skip(1).collect();
    if values.len() != 16
        || values
            .iter()
            .step_by(2)
            .any(|value| !value.starts_with("--"))
    {
        return Err("usage: vertices-verify --public-key <hex> --canonical-cbor <hex> --metadata-uri <uri> --event-device-id <hex> --event-content-hash <hex> --event-sequence <uint64> --event-timestamp <uint64> --event-signature <hex>".to_owned());
    }
    let options: BTreeMap<&str, &str> = values
        .chunks_exact(2)
        .map(|pair| (pair[0].as_str(), pair[1].as_str()))
        .collect();
    let required = |name| {
        options
            .get(name)
            .copied()
            .ok_or_else(|| format!("missing {name}"))
    };
    let cbor = required("--canonical-cbor")?;
    Ok(Arguments {
        public_key: decode_hex(required("--public-key")?, "public key")?,
        canonical_cbor: hex::decode(cbor.strip_prefix("0x").unwrap_or(cbor))
            .map_err(|_| "canonical CBOR must be hexadecimal".to_owned())?,
        metadata_uri: required("--metadata-uri")?.to_owned(),
        event_device_id: decode_hex(required("--event-device-id")?, "event device ID")?,
        event_content_hash: decode_hex(required("--event-content-hash")?, "event content hash")?,
        event_sequence: required("--event-sequence")?
            .parse()
            .map_err(|_| "event sequence must be a uint64".to_owned())?,
        event_timestamp: required("--event-timestamp")?
            .parse()
            .map_err(|_| "event timestamp must be a uint64".to_owned())?,
        event_signature: decode_hex(required("--event-signature")?, "event signature")?,
    })
}

fn verify(arguments: Arguments) -> Result<(), String> {
    let envelope = SignedObservation::from_canonical_cbor(&arguments.canonical_cbor)
        .map_err(|error| format!("invalid canonical envelope: {error:?}"))?;
    if sha256(arguments.metadata_uri.as_bytes()) != envelope.metadata_uri_hash {
        return Err("metadata URI does not match the signed metadata_uri_hash".to_owned());
    }
    let key = VerifyingKey::from_bytes(&arguments.public_key)
        .map_err(|_| "invalid Ed25519 public key".to_owned())?;
    let mut message = [0; MAX_SIGNING_BYTES];
    let length = envelope
        .signing_bytes(&mut message)
        .map_err(|error| format!("could not reconstruct signing bytes: {error:?}"))?;
    key.verify(
        &message[..length],
        &Signature::from_bytes(&envelope.signature),
    )
    .map_err(|_| "Ed25519 signature is invalid".to_owned())?;
    let content_hash = envelope
        .content_hash()
        .map_err(|error| format!("could not hash envelope: {error:?}"))?;
    if arguments.event_device_id != envelope.device_id {
        return Err("event device ID does not match the signed envelope".to_owned());
    }
    if arguments.event_content_hash != content_hash {
        return Err("event content hash does not match the envelope".to_owned());
    }
    if arguments.event_sequence != envelope.sequence {
        return Err("event sequence does not match the signed envelope".to_owned());
    }
    if arguments.event_timestamp != envelope.timestamp {
        return Err("event timestamp does not match the signed envelope".to_owned());
    }
    if arguments.event_signature != envelope.signature {
        return Err("event signature does not match the signed envelope".to_owned());
    }
    println!(
        "verified: device_id=0x{} content_hash=0x{} sequence={} timestamp={}",
        hex::encode(envelope.device_id),
        hex::encode(content_hash),
        envelope.sequence,
        envelope.timestamp
    );
    Ok(())
}

fn main() {
    if let Err(error) = parse_arguments().and_then(verify) {
        eprintln!("verification failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ENVELOPE: &str = "a90001015076657274696365732d646576696365310201031a66d1694004582005aa0132074d31fb33a8e10f4573da805f873e60f9deded3ab39f91bc44d76b805010601075820eaecd533d0b2c3810045a547b4c0ac896111e855788db015fcb6f04be55069d10858408f2b50a67bcac8fe13d27101722f698974c6478628e3747f5a579bbaed8093d1409cb03070f038bf64eb3899b9822fcad2dcd5e8b3a805a8af6048718efb6a0d";
    #[test]
    fn verifies_simulator_vector() {
        verify(Arguments { public_key: decode_hex("2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12", "key").unwrap(), canonical_cbor: hex::decode(ENVELOPE).unwrap(), metadata_uri: "ipfs://bafy-vertices-reference-example".to_owned(), event_device_id: *b"vertices-device1", event_content_hash: decode_hex("f86f51995759f851695766509a5b699dc67ff68ef1188d1f9b54747b0f474aca", "hash").unwrap(), event_sequence: 1, event_timestamp: 1_725_000_000, event_signature: decode_hex("8f2b50a67bcac8fe13d27101722f698974c6478628e3747f5a579bbaed8093d1409cb03070f038bf64eb3899b9822fcad2dcd5e8b3a805a8af6048718efb6a0d", "signature").unwrap() }).unwrap();
    }
}
