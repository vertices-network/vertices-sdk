#![no_std]
#![forbid(unsafe_code)]

//! Protocol primitives for a versioned Vertices observation envelope.
//!
//! The only signed envelope encoding in v1 is the deterministic CBOR emitted
//! by [`Observation::signing_bytes`]. Payload bytes are deliberately outside
//! this encoding; their SHA-256 digest and a versioned codec identifier are
//! committed by the envelope instead.

use sha2::{Digest, Sha256};

pub const DOMAIN_SEPARATOR: &[u8] = b"vertices.network/observation/v1";
pub const ENVELOPE_VERSION_V1: u8 = 1;
pub const ED25519_SIGNATURE_LEN: usize = 64;
pub const MAX_SIGNING_BYTES: usize = 192;
pub const MAX_ENVELOPE_BYTES: usize = MAX_SIGNING_BYTES + 80;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    BufferTooSmall,
    MetadataUriTooLong,
    EmptyPayload,
    SequenceZero,
    TimestampZero,
    MalformedCbor,
    NonCanonicalCbor,
    UnsupportedEnvelopeVersion,
    InvalidEnvelope,
}

/// Identifies a deterministic payload encoding owned by the application.
/// `0` is reserved for opaque immutable bytes; decoders must not re-encode it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PayloadCodec {
    pub id: u16,
    pub version: u16,
}

/// A fixed-capacity observation. `URI` is the maximum metadata URI length.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Observation<const URI: usize> {
    pub signed: SignedObservation,
    metadata_uri: [u8; URI],
    metadata_uri_len: usize,
}

/// A received signed envelope. Unlike [`Observation`], it does not require
/// payload or metadata URI bytes that are unavailable to an independent verifier.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SignedObservation {
    pub device_id: [u8; 16],
    pub sequence: u64,
    pub timestamp: u64,
    pub payload_hash: [u8; 32],
    pub payload_codec: PayloadCodec,
    pub metadata_uri_hash: [u8; 32],
    pub signature: [u8; ED25519_SIGNATURE_LEN],
}

impl SignedObservation {
    /// Parses the supplied canonical v1 CBOR envelope without constructing one.
    pub fn from_canonical_cbor(input: &[u8]) -> Result<Self, Error> {
        let mut reader = Reader::new(input);
        if reader.map()? != 9 {
            return Err(Error::InvalidEnvelope);
        }
        reader.key(0)?;
        if reader.uint()? != ENVELOPE_VERSION_V1 as u64 {
            return Err(Error::UnsupportedEnvelopeVersion);
        }
        reader.key(1)?;
        let device_id = reader.bytes()?;
        reader.key(2)?;
        let sequence = reader.uint()?;
        reader.key(3)?;
        let timestamp = reader.uint()?;
        reader.key(4)?;
        let payload_hash = reader.bytes()?;
        reader.key(5)?;
        let id = u16::try_from(reader.uint()?).map_err(|_| Error::InvalidEnvelope)?;
        reader.key(6)?;
        let version = u16::try_from(reader.uint()?).map_err(|_| Error::InvalidEnvelope)?;
        reader.key(7)?;
        let metadata_uri_hash = reader.bytes()?;
        reader.key(8)?;
        let signature = reader.bytes()?;
        if !reader.finished() {
            return Err(Error::InvalidEnvelope);
        }
        if sequence == 0 {
            return Err(Error::SequenceZero);
        }
        if timestamp == 0 {
            return Err(Error::TimestampZero);
        }
        Ok(Self {
            device_id,
            sequence,
            timestamp,
            payload_hash,
            payload_codec: PayloadCodec { id, version },
            metadata_uri_hash,
            signature,
        })
    }

    /// Writes the exact domain-separated bytes covered by the Ed25519 signature.
    pub fn signing_bytes(&self, out: &mut [u8]) -> Result<usize, Error> {
        let mut writer = Writer::new(out);
        writer.bytes(DOMAIN_SEPARATOR)?;
        writer.byte(0)?;
        self.encode_signing_cbor(&mut writer)?;
        Ok(writer.len())
    }

    pub fn encode_cbor(&self, out: &mut [u8]) -> Result<usize, Error> {
        let mut writer = Writer::new(out);
        writer.map(9)?;
        writer.uint(0)?;
        writer.uint(ENVELOPE_VERSION_V1 as u64)?;
        writer.uint(1)?;
        writer.bytes(&self.device_id)?;
        writer.uint(2)?;
        writer.uint(self.sequence)?;
        writer.uint(3)?;
        writer.uint(self.timestamp)?;
        writer.uint(4)?;
        writer.bytes(&self.payload_hash)?;
        writer.uint(5)?;
        writer.uint(self.payload_codec.id as u64)?;
        writer.uint(6)?;
        writer.uint(self.payload_codec.version as u64)?;
        writer.uint(7)?;
        writer.bytes(&self.metadata_uri_hash)?;
        writer.uint(8)?;
        writer.bytes(&self.signature)?;
        Ok(writer.len())
    }

    pub fn content_hash(&self) -> Result<[u8; 32], Error> {
        let mut bytes = [0; MAX_ENVELOPE_BYTES];
        let len = self.encode_cbor(&mut bytes)?;
        Ok(sha256(&bytes[..len]))
    }

    fn encode_signing_cbor(&self, writer: &mut Writer<'_>) -> Result<(), Error> {
        writer.map(8)?;
        writer.uint(0)?;
        writer.uint(ENVELOPE_VERSION_V1 as u64)?;
        writer.uint(1)?;
        writer.bytes(&self.device_id)?;
        writer.uint(2)?;
        writer.uint(self.sequence)?;
        writer.uint(3)?;
        writer.uint(self.timestamp)?;
        writer.uint(4)?;
        writer.bytes(&self.payload_hash)?;
        writer.uint(5)?;
        writer.uint(self.payload_codec.id as u64)?;
        writer.uint(6)?;
        writer.uint(self.payload_codec.version as u64)?;
        writer.uint(7)?;
        writer.bytes(&self.metadata_uri_hash)?;
        Ok(())
    }
}

pub struct ObservationBuilder<const URI: usize> {
    device_id: [u8; 16],
    sequence: u64,
    timestamp: u64,
    payload_hash: [u8; 32],
    payload_codec: PayloadCodec,
    metadata_uri: [u8; URI],
    metadata_uri_len: usize,
}

impl<const URI: usize> ObservationBuilder<URI> {
    pub fn new(
        device_id: [u8; 16],
        sequence: u64,
        timestamp: u64,
        payload: &[u8],
        payload_codec: PayloadCodec,
        metadata_uri: &[u8],
    ) -> Result<Self, Error> {
        if sequence == 0 {
            return Err(Error::SequenceZero);
        }
        if timestamp == 0 {
            return Err(Error::TimestampZero);
        }
        if payload.is_empty() {
            return Err(Error::EmptyPayload);
        }
        if metadata_uri.len() > URI {
            return Err(Error::MetadataUriTooLong);
        }

        let mut uri = [0; URI];
        uri[..metadata_uri.len()].copy_from_slice(metadata_uri);
        Ok(Self {
            device_id,
            sequence,
            timestamp,
            payload_hash: sha256(payload),
            payload_codec,
            metadata_uri: uri,
            metadata_uri_len: metadata_uri.len(),
        })
    }

    pub fn build(self, signature: [u8; ED25519_SIGNATURE_LEN]) -> Observation<URI> {
        Observation {
            signed: self.signed_observation(signature),
            metadata_uri: self.metadata_uri,
            metadata_uri_len: self.metadata_uri_len,
        }
    }

    /// Bytes to be signed, including domain separation.
    pub fn signing_bytes(&self, out: &mut [u8]) -> Result<usize, Error> {
        self.signed_observation([0; ED25519_SIGNATURE_LEN])
            .signing_bytes(out)
    }

    fn signed_observation(&self, signature: [u8; ED25519_SIGNATURE_LEN]) -> SignedObservation {
        SignedObservation {
            device_id: self.device_id,
            sequence: self.sequence,
            timestamp: self.timestamp,
            payload_hash: self.payload_hash,
            payload_codec: self.payload_codec,
            metadata_uri_hash: sha256(&self.metadata_uri[..self.metadata_uri_len]),
            signature,
        }
    }
}

impl<const URI: usize> Observation<URI> {
    pub fn metadata_uri(&self) -> &[u8] {
        &self.metadata_uri[..self.metadata_uri_len]
    }

    pub fn signing_bytes(&self, out: &mut [u8]) -> Result<usize, Error> {
        self.signed.signing_bytes(out)
    }

    /// Deterministic CBOR containing the signature. This is the public,
    /// transportable envelope whose SHA-256 value becomes the commitment.
    pub fn encode_cbor(&self, out: &mut [u8]) -> Result<usize, Error> {
        self.signed.encode_cbor(out)
    }

    pub fn content_hash(&self) -> Result<[u8; 32], Error> {
        self.signed.content_hash()
    }
}

pub fn sha256(input: &[u8]) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(input);
    hash.finalize().into()
}

struct Writer<'a> {
    bytes: &'a mut [u8],
    len: usize,
}
impl<'a> Writer<'a> {
    fn new(bytes: &'a mut [u8]) -> Self {
        Self { bytes, len: 0 }
    }
    fn len(&self) -> usize {
        self.len
    }
    fn byte(&mut self, value: u8) -> Result<(), Error> {
        if self.len == self.bytes.len() {
            return Err(Error::BufferTooSmall);
        }
        self.bytes[self.len] = value;
        self.len += 1;
        Ok(())
    }
    fn bytes(&mut self, value: &[u8]) -> Result<(), Error> {
        self.major(2, value.len() as u64)?;
        if self.bytes.len() - self.len < value.len() {
            return Err(Error::BufferTooSmall);
        }
        self.bytes[self.len..self.len + value.len()].copy_from_slice(value);
        self.len += value.len();
        Ok(())
    }
    fn uint(&mut self, value: u64) -> Result<(), Error> {
        self.major(0, value)
    }
    fn map(&mut self, len: u64) -> Result<(), Error> {
        self.major(5, len)
    }
    fn major(&mut self, major: u8, value: u64) -> Result<(), Error> {
        let prefix = major << 5;
        if value < 24 {
            self.byte(prefix | value as u8)
        } else if value <= u8::MAX as u64 {
            self.byte(prefix | 24)?;
            self.byte(value as u8)
        } else if value <= u16::MAX as u64 {
            self.byte(prefix | 25)?;
            for b in (value as u16).to_be_bytes() {
                self.byte(b)?;
            }
            Ok(())
        } else if value <= u32::MAX as u64 {
            self.byte(prefix | 26)?;
            for b in (value as u32).to_be_bytes() {
                self.byte(b)?;
            }
            Ok(())
        } else {
            self.byte(prefix | 27)?;
            for b in value.to_be_bytes() {
                self.byte(b)?;
            }
            Ok(())
        }
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn finished(&self) -> bool {
        self.offset == self.bytes.len()
    }

    fn uint(&mut self) -> Result<u64, Error> {
        self.major(0)
    }

    fn map(&mut self) -> Result<u64, Error> {
        self.major(5)
    }

    fn key(&mut self, expected: u64) -> Result<(), Error> {
        if self.uint()? == expected {
            Ok(())
        } else {
            Err(Error::InvalidEnvelope)
        }
    }

    fn bytes<const N: usize>(&mut self) -> Result<[u8; N], Error> {
        if self.major(2)? != N as u64 {
            return Err(Error::InvalidEnvelope);
        }
        let end = self.offset.checked_add(N).ok_or(Error::MalformedCbor)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(Error::MalformedCbor)?;
        self.offset = end;
        value.try_into().map_err(|_| Error::InvalidEnvelope)
    }

    fn major(&mut self, expected: u8) -> Result<u64, Error> {
        let initial = *self.bytes.get(self.offset).ok_or(Error::MalformedCbor)?;
        self.offset += 1;
        if initial >> 5 != expected {
            return Err(Error::InvalidEnvelope);
        }
        let additional = initial & 0x1f;
        if additional < 24 {
            return Ok(additional as u64);
        }
        let width = match additional {
            24 => 1,
            25 => 2,
            26 => 4,
            27 => 8,
            _ => return Err(Error::MalformedCbor),
        };
        let end = self.offset.checked_add(width).ok_or(Error::MalformedCbor)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(Error::MalformedCbor)?;
        self.offset = end;
        let number = match width {
            1 => value[0] as u64,
            2 => u16::from_be_bytes(value.try_into().map_err(|_| Error::MalformedCbor)?) as u64,
            4 => u32::from_be_bytes(value.try_into().map_err(|_| Error::MalformedCbor)?) as u64,
            8 => u64::from_be_bytes(value.try_into().map_err(|_| Error::MalformedCbor)?),
            _ => return Err(Error::MalformedCbor),
        };
        if number < 24
            || (width == 2 && number <= u8::MAX as u64)
            || (width == 4 && number <= u16::MAX as u64)
            || (width == 8 && number <= u32::MAX as u64)
        {
            return Err(Error::NonCanonicalCbor);
        }
        Ok(number)
    }
}

#[cfg(test)]
extern crate std;

#[cfg(test)]
mod tests {
    use super::*;

    const SIMULATOR_ENVELOPE: &str = "a90001015076657274696365732d646576696365310201031a66d1694004582005aa0132074d31fb33a8e10f4573da805f873e60f9deded3ab39f91bc44d76b805010601075820eaecd533d0b2c3810045a547b4c0ac896111e855788db015fcb6f04be55069d10858402aa0d139dbad136162e7c21ce15623792b0f67cb1df08d233a5f4fb2bfd4588082f2e441a4d8602307400b5bfb6e71938d025658e04fdb1a4251e32b7e7a4300";
    #[test]
    fn deterministic_envelope_is_stable() {
        let builder = ObservationBuilder::<96>::new(
            *b"vertices-device1",
            1,
            1_725_000_000,
            b"21.5C",
            PayloadCodec { id: 1, version: 1 },
            b"ipfs://bafy-example",
        )
        .unwrap();
        let mut signing = [0; MAX_SIGNING_BYTES];
        let signing_len = builder.signing_bytes(&mut signing).unwrap();
        let observation = builder.build([7; ED25519_SIGNATURE_LEN]);
        let mut envelope = [0; MAX_ENVELOPE_BYTES];
        let envelope_len = observation.encode_cbor(&mut envelope).unwrap();
        assert_eq!(signing_len, 137);
        assert_eq!(envelope_len, 170);
        assert_eq!(observation.metadata_uri(), b"ipfs://bafy-example");
        assert_eq!(
            observation.content_hash().unwrap(),
            sha256(&envelope[..envelope_len])
        );
    }

    #[test]
    fn parses_and_reencodes_the_simulator_envelope() {
        let input = hex::decode(SIMULATOR_ENVELOPE).unwrap();
        let signed = SignedObservation::from_canonical_cbor(&input).unwrap();
        let mut encoded = [0; MAX_ENVELOPE_BYTES];
        let len = signed.encode_cbor(&mut encoded).unwrap();
        assert_eq!(&encoded[..len], input);
        assert_eq!(signed.device_id, *b"vertices-device1");
    }

    #[test]
    fn rejects_noncanonical_cbor() {
        let mut input = hex::decode(SIMULATOR_ENVELOPE).unwrap();
        input.splice(1..2, [0x18, 0x00]);
        assert_eq!(
            SignedObservation::from_canonical_cbor(&input),
            Err(Error::NonCanonicalCbor)
        );
    }
}
